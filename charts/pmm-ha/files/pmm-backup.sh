#!/bin/sh
set -eu

# fd 9 duplicates the ORIGINAL stdout, for output that must reach the operator even when the
# current command's stdout is redirected. pod_sh/pod_exec write their --dry-run preview there:
# their call sites redirect tool output into the log file, which otherwise swallows the one line
# the reviewer is there to read.
exec 9>&1

################################################################################
# PMM-HA Backup / Restore / List — one orchestrator
#
# Subcommands (one is REQUIRED — there is deliberately no default; see DN-02):
#   pmm-backup.sh backup  [OPTIONS]                          back up components
#   pmm-backup.sh restore --backup-id <id|latest> [OPTIONS]  restore from a backup
#   pmm-backup.sh list    [BACKUP_ID]                        list / inspect backups
#
# Section order — one concern per section, each depending only on the ones above:
#   1 Defaults + argument parsing      6 Catalog (manifest, ids, latest, list)
#   2 Logging                          7 Backup components
#   3+4 Layout + storage access        8 Restore components
#   5 Kubernetes primitives            9 Retention
#                                     10 Metrics
#                                     11 Subcommand dispatch
#
# Engines: PostgreSQL pg_dump/pg_restore, ClickHouse clickhouse-backup (system.backup_actions
# API; restore_remote on restore), VictoriaMetrics vmbackup/vmrestore, PMM server /srv tar.
# Restore is manifest-driven. Both operations support --target s3 and --target shared.
#
# Shell: uses `local` and other common extensions beyond strict POSIX sh. Supported shells:
# BusyBox ash (the backup-tools image), dash and bash. Portability traps that have actually
# shipped are catalogued in DN-22 — read it before adding shell cleverness.
#
# WHY things are shaped the way they are: docs/pmm-backup-design-notes.md (DN-01..DN-44).
# Comments here state the RULE; the notes carry the incident that forced it. Most exist because
# the obvious alternative was tried and lost data — read the note before undoing a constraint.
################################################################################

################################################################################
# 1. Defaults + argument parsing
################################################################################

# ---- Common configuration -----------------------------------------------------
NAMESPACE="${NAMESPACE:-demo}"
# UTC, deliberately. The id is the retention clock (backup_id_epoch converts it back) and it
# is written into a bucket that a CronJob pod, an operator's laptop and a DR cluster all read —
# a local-time id means those three disagree about how old a backup is by their offset, and the
# same bucket can then hold ids that sort out of order. Everything else this file stamps
# (lease_now, the manifest's `created`) is already UTC; this makes the set consistent.
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP_ID=""            # backup: shared id grouping concurrent runs (auto if omitted)
                        # restore: <timestamp> | backup_<timestamp> | latest
BACKUP_DIR="${BACKUP_DIR:-/backups}"   # logs/metadata; the central mount in shared mode
METRICS_DIR="${METRICS_DIR:-/backups/.metrics}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN=false
LOG_FILE=""             # set per operation before the first log() call (see dispatch)
COMMAND=""              # backup | restore | list — set by the dispatcher in main()

# Backup target mode (where backups land / where a restore reads from):
#   s3     - each component writes to / reads from object storage (vmbackup and
#            clickhouse-backup natively; /srv via the pmm-backup sidecar's own rclone, in
#            the PMM pod; PG dumps through this pod's local rclone). No pod mounts.
#   shared - a user-provided RWX/NFS volume is mounted into the component pods at
#            ${SHARED_MOUNT_PATH}; components land via in-pod local copy / direct write.
BACKUP_TARGET="${BACKUP_TARGET:-s3}"
# Where the RWX/NFS central volume is mounted INSIDE the component pods (shared mode).
# Must match the chart's centralBackupStorage mount path.
SHARED_MOUNT_PATH="${SHARED_MOUNT_PATH:-/central}"

# S3 settings (target=s3)
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
# Prefix (key namespace) under the bucket: s3://<bucket>/<S3_PREFIX>/<component>/<id>/...
#
# Left EMPTY when nothing supplied it, and resolved after parsing to "<namespace>/pmm-ha" —
# the same root the chart's pmm.backupS3Root helper composes. The old fallback was a bare
# "pmm-ha", so any run that did not inherit the pod env addressed a DIFFERENT root from the
# one the install writes to and reported "no backups" for a full bucket.
S3_PREFIX=$(echo "${S3_PREFIX:-}" | sed 's|^/||; s|/$||')
# rclone remote name; its config is supplied via RCLONE_CONFIG_<NAME>_* env vars
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"
# Derived from BACKUP_TARGET after parsing; kept for the per-tool S3 branches.
S3_ENABLED=false

# Timeouts (seconds). Wrapped with `timeout`, never kubectl --request-timeout, which breaks
# in-cluster apiserver discovery (DN-27).
#
# RULE: every numeric knob is clamped to its default unless it is a positive integer. A
# non-numeric value does not merely misbehave — `[ 0 -lt 5m ]` exits 2, which `if` reads as
# FALSE, so the guard it was meant to arm is silently skipped. Clamping happens at load time,
# before log() exists, so what was clamped is accumulated here and reported by preflight_checks.
# numeric_env <VAR-NAME> <default>
NUMERIC_ENV_CLAMPED=""
numeric_env() {
    # Initialised before the eval: if the eval ever failed, the read below would be an unset
    # variable under `set -u` — which aborts the script at load time, before any log exists.
    _ne_v=""
    eval "_ne_v=\${$1}"
    case "${_ne_v}" in
        ''|*[!0-9]*|0)
            NUMERIC_ENV_CLAMPED="${NUMERIC_ENV_CLAMPED}${NUMERIC_ENV_CLAMPED:+; }$1='${_ne_v}' -> $2"
            eval "$1=$2" ;;
    esac
    unset _ne_v
}

KUBECTL_EXEC_TIMEOUT="${KUBECTL_EXEC_TIMEOUT:-600}"
numeric_env KUBECTL_EXEC_TIMEOUT 600
KUBECTL_STATUS_TIMEOUT="${KUBECTL_STATUS_TIMEOUT:-30}"
numeric_env KUBECTL_STATUS_TIMEOUT 30

# Kubernetes label selectors (one definition for both operations)
LABEL_PG_PRIMARY="postgres-operator.crunchydata.com/role=primary"
LABEL_CH_POD="clickhouse.altinity.com/chi"
LABEL_VM_STORAGE="app.kubernetes.io/name=vmstorage"
# PMM server pods (HA StatefulSet); selector discovers all replicas (1, 3, 5, ...)
LABEL_PMM_SERVER="app.kubernetes.io/component=pmm-server"
LABEL_BACKUP_TOOLS="app.kubernetes.io/component=backup-tools"

# The selector that finds a component's pods, by component key. Lets the generic per-component
# loops (pre-flight discovery, the restore gate) reach the right pods without a branch each.
comp_pod_selector() {
    case "$1" in
        postgresql)      printf '%s' "${LABEL_PG_PRIMARY}" ;;
        clickhouse)      printf '%s' "${LABEL_CH_POD}" ;;
        victoriametrics) printf '%s' "${LABEL_VM_STORAGE}" ;;
        pmm-server)      printf '%s' "${LABEL_PMM_SERVER}" ;;
        *) return 1 ;;
    esac
}

# ClickHouse credentials secret (both operations)
CH_SECRET_NAME="${CH_SECRET_NAME:-pmm-secret}"

# Component locks held by the running operation (see acquire_locks). Empty until an
# operation computes its list, so an early trap can call release_locks harmlessly.
LOCK_COMPONENTS=""
# (There is no S3 client pod any more: rclone runs in THIS pod. See section 5.)
# THE backup this process is working on — the id every path builder defaults to. Set once
# per operation (backup/list at dispatch, restore in load_manifest); see backup_id_default.
CURRENT_ID=""
# Track whether explicit component selection was made (first --<component> flag
# disables the others; later flags combine — same semantics both operations).
EXPLICIT_SELECTION=false
LIST_ONLY=false
LIST_ID=""              # backup id to inspect via the 'list' subcommand

# ---- Backup configuration -------------------------------------------------------
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"

# Component flags (default: all enabled)
BACKUP_POSTGRESQL="${BACKUP_POSTGRESQL:-true}"
BACKUP_CLICKHOUSE="${BACKUP_CLICKHOUSE:-true}"
BACKUP_VICTORIAMETRICS="${BACKUP_VICTORIAMETRICS:-true}"
BACKUP_PMM_SERVER="${BACKUP_PMM_SERVER:-true}"
# Encryption key is captured alongside PostgreSQL (it's the PG encryption key);
# --skip-encryption-key turns it off. (Restore selects it independently via --encryption-key.)
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-true}"

# PostgreSQL: logical dump (pg_dump). Application databases are auto-discovered; no
# stanza/repo/retention knobs needed.

# ClickHouse settings
CH_BACKUP_TYPE="${CH_BACKUP_TYPE:-full}"
# Max seconds to wait for clickhouse-backup create/upload to finish (polled async)
CH_CREATE_TIMEOUT="${CH_CREATE_TIMEOUT:-300}"
numeric_env CH_CREATE_TIMEOUT 300
CH_UPLOAD_TIMEOUT="${CH_UPLOAD_TIMEOUT:-600}"
numeric_env CH_UPLOAD_TIMEOUT 600

# PMM server (/srv) settings: path inside the PMM server pod to archive
PMM_SRV_PATH="${PMM_SRV_PATH:-/srv}"

# Per-component suffix for concurrent mode (--backup-id with a single component);
# computed after parsing.
COMPONENT_SUFFIX=""

# ---- Component results ----------------------------------------------------------------
# Every component's outcome as ONE JSON object keyed by component name; the manifest, the run
# summary and the metrics all read from here, and only components that actually ran appear.
# In memory, never fragment files on disk — the manifest IS the restore index, and a filesystem
# round-trip would add a way for a successful component to vanish from it (DN-38).
RESULTS_JSON='{}'

# ClickHouse state only some paths assign. Initialised here because under `set -u` a variable
# set on one branch and read on another aborts the run — after every component has uploaded and
# before the manifest is written, i.e. orphaned data. The lint enforces this file-wide.
CH_BACKUP_BASE=""          # the remote backup an incremental was diffed against (empty = full)
CH_SHARED_TAR=""           # shared mode: the tarball the CH backup was archived to
CH_LOCATION_OVERRIDE=""    # set when the sidecar writes outside this run's root (DN-12)

# result_set <component> <jq-args...> — jq builds the object, so every value is escaped and the
# script depends on no hand-maintained JSON formatting.
result_set() {
    _rs_c="$1"; shift
    # NEVER returns non-zero: every call site is a bare statement, so a failure here would
    # abort the run under `set -e` — after the data is uploaded and before the index is written.
    # A component that cannot be described is recorded FAILED rather than dropped, because a
    # dropped entry is indistinguishable from one that was never selected. stderr is re-captured
    # by a second jq only on the error path rather than redirected into ${LOG_FILE}: a low-level
    # helper every component calls must not depend on a global file handle. (DN-38)
    _rs_obj=$(jq -n "$@" 2>/dev/null) || _rs_obj=""
    if [ -z "${_rs_obj}" ]; then
        _rs_err=$(jq -n "$@" 2>&1 >/dev/null || true)
        log "ERROR" "[${_rs_c}] could not build its result object (${_rs_err}); recording it as FAILED with no detail"
        _rs_obj='{"status":"failed","detail":"result object could not be built (see the log)"}'
    fi
    _rs_new=$(printf '%s' "${RESULTS_JSON}" \
        | jq --arg c "${_rs_c}" --argjson o "${_rs_obj}" '. + {($c): $o}' 2>/dev/null) || _rs_new=""
    if [ -n "${_rs_new}" ]; then
        RESULTS_JSON="${_rs_new}"
    else
        log "ERROR" "[${_rs_c}] could not be merged into this run's results; it will be MISSING from the manifest"
    fi
    return 0
}

# result_get <component> <field> [default] — for the summary and the metrics writer.
result_get() {
    _rg_v=$(printf '%s' "${RESULTS_JSON}" | jq -r --arg c "$1" --arg f "$2" '.[$c][$f] // empty' 2>/dev/null || true)
    if [ -n "${_rg_v}" ]; then printf '%s' "${_rg_v}"; else printf '%s' "${3:-}"; fi
}

# Did this component report success? One definition, used by the counters, the summary, the
# metrics and the manifest's overall status.
result_ok() { [ "$(result_get "$1" status)" = "success" ]; }

# Per-object SIZE census helper: turns "<key>:<bytes> ..." pairs into a JSON object. Keys are
# database and pod names, neither of which can contain ':' or a space. See DN-16 for why sizes
# are recorded and why bulk objects deliberately get no content hash.
# `jq -n --arg`, NOT `printf | jq -R`: raw-input jq reads LINES, so empty input yields zero
# lines and NO OUTPUT AT ALL. That empty string then reached --argjson in result_set, which
# rejects it — so a component with no per-object sizes (any component that failed for every
# pod) lost its entry in the manifest entirely instead of being recorded as failed.
sizes_to_json() {
    jq -n --arg s "${1:-}" '$s | split(" ") | map(select(length > 0)) | map(. / ":")
        | map({key: .[0], value: (.[1] | tonumber)}) | from_entries'
}

# ---- Restore configuration ------------------------------------------------------
# CONSENT to a destructive restore — nothing more (DN-44). Deliberately NOT a "skip the safety
# checks" flag: every non-interactive run must pass it, so anything it disabled would be
# disabled for ALL automation, which is where restores actually run.
ASSUME_YES=false
# EMPTY means "use this subcommand's default", which differs on purpose:
#   restore  -> parallel. PMM is scaled to 0, nothing is serving, only RTO matters.
#   backup   -> sequential. The system is LIVE, and vmbackup already runs unthrottled
#               (-maxBytesPerSecond=0), so stealing I/O from the thing being monitored is a
#               real cost that the operator should opt into rather than inherit.
# --parallel / --sequential set it explicitly for either operation.
PARALLEL=""

# rclone provider profile for the temp S3 client pod: AWS | Minio | Ceph | Other
S3_PROVIDER="${S3_PROVIDER:-AWS}"
# VictoriaMetrics may legitimately live on a different S3 endpoint than the rest
# (victoriaMetrics.vmstorage.backup.s3.endpoint). vmbackup/vmrestore take it only as the
# -customS3Endpoint flag, which this script builds — the chart used to render it as an
# AWS_ENDPOINT env var on the vmbackup sidecar, which no tool reads, so the override was
# silently ignored. Empty means "same endpoint as everything else".
VM_S3_ENDPOINT="${VM_S3_ENDPOINT:-}"
# Static S3 credentials (k8s Secret) for the temp pods (vmrestore + s3 client). Required on
# non-AWS S3-compatible storage; on AWS with IRSA leave empty (SA credential chain).
S3_SECRET_NAME="${S3_SECRET_NAME:-}"
S3_SECRET_ACCESS_KEY_KEY="${S3_SECRET_ACCESS_KEY_KEY:-access-key}"
S3_SECRET_SECRET_KEY_KEY="${S3_SECRET_SECRET_KEY_KEY:-secret-key}"
# SA the s3 temp pods run as, so their tools get S3 creds via IRSA. Empty by default: the chart
# projects S3_SERVICE_ACCOUNT only when it actually creates that SA (IRSA configured). With no
# IRSA (ambient node creds / static keys) this stays empty and temp pods use the namespace default
# SA — hardcoding "pmm-ha-backup-s3" here would point them at a non-existent SA. Override with
# --s3-service-account for manual runs.
S3_SERVICE_ACCOUNT="${S3_SERVICE_ACCOUNT:-}"
# Whether --s3-service-account was passed explicitly (vs. the default above). An explicitly
# requested SA is honored even alongside static keys (e.g. an SA carrying imagePullSecrets);
# the default name is only assumed on the IRSA path, where the chart actually creates it.
S3_SA_EXPLICIT=false

# Component flags (default: restore everything the manifest marks 'success')
RESTORE_POSTGRESQL="${RESTORE_POSTGRESQL:-false}"
RESTORE_CLICKHOUSE="${RESTORE_CLICKHOUSE:-false}"
RESTORE_VICTORIAMETRICS="${RESTORE_VICTORIAMETRICS:-false}"
RESTORE_PMM_SERVER="${RESTORE_PMM_SERVER:-false}"
RESTORE_ENCRYPTION_KEY="${RESTORE_ENCRYPTION_KEY:-false}"
# --skip-<component> markers, applied after the manifest-driven defaults.
SKIP_POSTGRESQL=false; SKIP_CLICKHOUSE=false; SKIP_VICTORIAMETRICS=false; SKIP_PMM_SERVER=false; SKIP_ENCRYPTION_KEY=false

# Pre-flight `clickhouse-backup list remote` budget. Between the two kubectl budgets on
# purpose: the 30s status budget is too tight once a bucket holds weeks of backups (and this
# gate fails closed, so a timeout would refuse a good restore), while the 600s exec budget
# would stall even a --dry-run for ten silent minutes against a wedged sidecar.
CH_LIST_TIMEOUT="${CH_LIST_TIMEOUT:-120}"
numeric_env CH_LIST_TIMEOUT 120

# VictoriaMetrics restore (auto-detected from the vmstorage pod if unset)
VMRESTORE_IMAGE="${VMRESTORE_IMAGE:-}"
VM_STORAGE_PVC_PREFIX="${VM_STORAGE_PVC_PREFIX:-vmstorage-db-}"
# PMM /srv PVC prefix — an OVERRIDE, not the source of truth. Empty by default: the name is
# derived from the live StatefulSet's volumeClaimTemplate instead (see pmm_storage_pvc_prefix).
#
# Defaulting it to the chart's `storage.name` is a fact about the CHART, not about the cluster:
# any install that sets `storage.name` then restores /srv by mounting a PVC that does not exist,
# and the temp pod hangs Pending until the 300s wait expires — after scale_down_pmm, on the
# wrong side of the point of no return. The StatefulSet owns the name; this file reads it.
# See DN-39.
PMM_STORAGE_PVC_PREFIX="${PMM_STORAGE_PVC_PREFIX:-}"
# Cache for the derived value, so the resolution costs one API read per run rather than one per
# ordinal. Resolved in the parent (the pre-flight gate) before restore_pmm_server needs it.
PMM_STORAGE_PVC_PREFIX_RESOLVED=""

# Central backup PVC (shared mode only; auto-detected from backup-tools pod if unset)
CENTRAL_BACKUP_PVC="${CENTRAL_BACKUP_PVC:-}"

# Restore runtime state initialised up front: the script runs under `set -u`, so anything
# read before its first assignment aborts the run.
BACKUP_NAME=""             # backup_<timestamp>
MANIFEST_FILE=""           # local temp copy of manifest.json
MF_STATUS="" ; MF_TARGET="" ; MF_CREATED=""
MF_PG_STATUS="" ; MF_PG_DBS=""
MF_CH_STATUS="" ; MF_CH_NAME=""
# Where this backup's ClickHouse data actually is, as the manifest recorded it. Empty for a
# backup taken before those fields existed, or in shared mode; ch_restore_bucket/ch_restore_path
# fall back to this run's own root there, which is what those older backups relied on. DN-43.
MF_CH_S3_BUCKET="" ; MF_CH_S3_PATH=""
MF_VM_STATUS="" ; MF_PMM_STATUS="" ; MF_ENC_STATUS=""
PMM_SAVED_REPLICAS="" ; PMM_STATEFULSET_NAME=""
# Rendered into every temp restore pod; assigned for real in the restore dispatch branch.
# Initialised here because the whole point of this block is that `set -u` aborts on any
# read-before-assignment, and these two are dereferenced bare by render_rclone_s3_env,
# create_vm_restore_pod, create_pmm_restore_pod and validate_restore_targets.
TEMP_POD_S3_KEYS_ENV="" ; TEMP_POD_SA_LINE=""
# Proof that THIS run created a temp mounter pod. restore_cleanup's label-wide sweep is gated
# on it, so an aborted run cannot delete a DIFFERENT run's live pod.
#
# A FILE, not a variable. In the default --parallel mode each component restore runs in
# `( ... ) &`, so a variable set by create_vm_restore_pod is set in a subshell and is invisible
# to the parent that runs restore_cleanup — the gate would then skip the sweep for exactly the
# pods it exists to clean up (VictoriaMetrics', which are the ones holding the RWO
# vmstorage-db PVCs), and a Ctrl-C would leave one attached and wedge vmstorage on Multi-Attach
# at scale-up. The path is chosen in the parent before any fork, so every subshell inherits the
# same path and writes to the same file.
TEMP_PODS_MARKER=""
RESTORE_START_TIME=0
ENCRYPTION_KEY_OK=false ; POSTGRESQL_OK=false ; CLICKHOUSE_OK=false
VICTORIAMETRICS_OK=false ; PMM_SERVER_OK=false

# Show help function
show_help() {
    cat <<EOF
PMM-HA Backup / Restore Orchestrator

One tool, three subcommands. It uses NATIVE tools from each operator:
  - PostgreSQL: pg_dump / pg_restore (logical custom-format dump of each application database)
  - ClickHouse: clickhouse-backup via system.backup_actions API (restore: restore_remote)
  - VictoriaMetrics: vmbackup (incremental) / vmrestore
  - PMM Server: gzip-compressed tar of /srv from each PMM server pod

Usage: $0 backup [OPTIONS]
       $0 restore --backup-id <id|latest> [OPTIONS]
       $0 list [BACKUP_ID] [OPTIONS]
       $0 prune [OPTIONS]

Commands (one is REQUIRED — there is no default operation):
  backup                    Back up the selected components.
  restore                   Restore the selected components from a backup (manifest-driven).
                            Scales PMM down first, brings it up last; refuses to run
                            non-interactively without --yes.
  prune                     Run the retention sweep on its own, deleting nothing else.
                            'backup' also sweeps when it finishes; this is the same sweep
                            with its own trigger, for installs that want retention to keep
                            working while backups are being fixed. It refuses to delete
                            unless a retained backup is still marked 'complete'.
  list [BACKUP_ID]          List backups, or — given a BACKUP_ID — show every file/location
                            that belongs to that one backup, read from its manifest.json.
                            Requires the same --s3-bucket / --s3-prefix / --namespace as the
                            backup (in s3 mode it reads the bucket with this pod's rclone).

Common options:
  -h, --help                Show this help message
  -v, --verbose             Show detailed backup/restore tool output
  --dry-run                 Show commands that would be executed without running them
  -n, --namespace NS        Kubernetes namespace (default: demo)
  -d, --backup-dir DIR      Backup directory for logs/metadata; the central mount in
                            shared mode (default: /backups)
  --backup-id ID            backup: shared identifier for grouping concurrent runs (a
                            timestamp is auto-generated if omitted).
                            restore: the backup to restore — <timestamp>,
                            backup_<timestamp>, or 'latest'.
  --target {s3|shared}      Where backups land / are read from (default: s3). 'shared' = a
                            mounted RWX/NFS volume; 's3' = object storage.
  --s3-bucket BUCKET        S3 bucket name (required for --target s3)
  --s3-endpoint URL         S3 endpoint (leave empty for AWS; also passed to
                            vmbackup/vmrestore as -customS3Endpoint)
  --s3-region REGION        S3 region (default: us-east-1)
  --s3-prefix PREFIX        Key namespace under the bucket (default: <namespace>/pmm-ha,
                            matching what the chart projects). Components
                            land under <prefix>/<component>/<id>/...
  --shared-mount-path PATH  Mount path of the shared volume in the pods (default: /central)
  --ch-secret NAME          Kubernetes secret for CH credentials (default: pmm-secret)

Component selection (combinable, e.g. --postgresql --clickhouse):
  Default: backup = all components; restore = everything the manifest marks 'success'.
  --postgresql  --clickhouse  --victoriametrics  --pmm-server  --encryption-key (restore only)
  --skip-postgresql  --skip-clickhouse  --skip-victoriametrics  --skip-pmm-server
  --skip-encryption-key     backup: skip the PMM encryption key (captured with PostgreSQL
                            by default); restore: do not restore it

Backup options:
  -r, --retention DAYS      Number of days to retain backups (default: 7)
  --ch-backup-type TYPE     ClickHouse backup type: full or incremental (default: full)

Concurrency (backup and restore):
  --parallel | --sequential Run the components concurrently, or one at a time.
                            Defaults differ on purpose: RESTORE is parallel (PMM is scaled
                            to 0, nothing is serving, only recovery time matters) and BACKUP
                            is sequential (the system is live, and vmbackup runs unthrottled,
                            so a backup that competes with itself for node bandwidth is a
                            cost you should opt into). On a parallel backup the slowest
                            component sets the wall clock and the log lines interleave.

Restore options:
  --list                    Alias for the 'list' subcommand (list all backups) and exit
  -y, --yes                 Confirm the destructive restore without prompting. Required
                            for any non-interactive run (no TTY). It answers the prompt
                            and nothing else — it never disables a safety check; each of
                            those has its own narrow flag, e.g. --skip-encryption-key.
  --force                   Deprecated alias for --yes.
  --s3-provider NAME        rclone provider for the temp S3 client: AWS (default),
                            Minio, Ceph, Other
  --s3-secret NAME          k8s Secret holding static S3 creds for the temp pods
                            (keys: access-key/secret-key; override via
                            S3_SECRET_ACCESS_KEY_KEY / S3_SECRET_SECRET_KEY_KEY).
                            Required on non-AWS storage; on AWS+IRSA leave unset
  --s3-service-account NAME IRSA-annotated SA for the temp restore pods (the chart
                            projects the default when IRSA is configured). Ignored when
                            --s3-secret is set unless passed explicitly.

Examples:
  # Full backup with default settings
  $0 backup --namespace demo --s3-bucket pmm-backups

  # PostgreSQL only (pg_dump of all app databases)
  $0 backup --namespace demo --postgresql

  # All components at once, in ONE process (one manifest writer, one summary, one log)
  $0 backup --namespace demo --parallel

  # Run components concurrently (grouped by backup-id).
  # date -u, because an auto-generated id is UTC and retention ages any id as UTC.
  BACKUP_ID=\$(date -u +%Y%m%d-%H%M%S)
  $0 backup --namespace demo --postgresql      --backup-id \$BACKUP_ID &
  $0 backup --namespace demo --clickhouse      --backup-id \$BACKUP_ID &
  $0 backup --namespace demo --victoriametrics --backup-id \$BACKUP_ID &
  wait

  # List all backups in the bucket (newest manifests), marking the 'latest' pointer
  $0 list --namespace demo --s3-bucket my-bucket --s3-prefix demo/pmm-ha

  # Show every file/location belonging to one backup (reads its manifest.json)
  $0 list backup_20260610-120000 --namespace demo --s3-bucket my-bucket

  # Restore the newest complete backup from S3, everything the manifest holds
  $0 restore --target s3 --s3-bucket my-bucket --backup-id latest

  # Preview a shared-volume restore without VictoriaMetrics
  $0 restore --target shared --backup-id latest --skip-victoriametrics --dry-run

Environment Variables:
  AWS_ACCESS_KEY_ID         S3 access key (for S3 backups)
  AWS_SECRET_ACCESS_KEY     S3 secret key (for S3 backups)
  BACKUP_DIR                Backup directory (default: /backups)
  BACKUP_RETENTION          Retention in days (default: 7)
  METRICS_DIR               Directory for Prometheus .prom metrics files
                            (default: /backups/.metrics)
  KUBECTL_EXEC_TIMEOUT      Timeout for backup/restore commands via 'timeout' (default: 600)
  KUBECTL_STATUS_TIMEOUT    Timeout for status queries via 'timeout' (default: 30)
  RCLONE_TIMEOUT            Wall clock for one rclone read/delete (default: KUBECTL_STATUS_TIMEOUT)
  RCLONE_PURGE_TIMEOUT      Wall clock for one recursive rclone purge (default: 300)
  RCLONE_IO_TIMEOUT         rclone --timeout for metadata reads/deletes (default: 60)
  RCLONE_STREAM_IO_TIMEOUT  rclone --timeout for uploads streamed through this process (default: 300)
  RCLONE_CONNECT_TIMEOUT    rclone --contimeout (default: 15)
  LOCK_LEASE_SECONDS        Component lock lease duration (default: 900)
  LOCK_RENEW_SECONDS        How often a held lease is renewed (default: 60)
  LOCK_RENEWER_MAX_SECONDS  Backstop lifetime for the lease renewer (default: 86400)
  CH_SECRET_NAME            Kubernetes secret for ClickHouse credentials (default: pmm-secret)
  CH_CREATE_TIMEOUT         Max seconds to wait for ClickHouse backup creation (default: 300)
  CH_UPLOAD_TIMEOUT         Max seconds to wait for ClickHouse S3 upload (default: 600)
  CH_LIST_TIMEOUT           Budget for the restore pre-flight 'list remote' (default: 120)
  PMM_SRV_PATH              Path archived from each PMM server pod (default: /srv)
  PMM_SERVER_REPLICAS       Fallback PMM replica count on restore scale-up (default: 3)
  VMRESTORE_IMAGE           vmrestore image override. Default: the vmstorage pod's own
                            vmrestore sidecar image, so it matches the version that
                            wrote the backup. There is no fallback beyond these two:
                            the restore refuses rather than guess a tag.
  VM_STORAGE_PVC_PREFIX     vmstorage PVC name prefix (default: vmstorage-db-)
  PMM_STORAGE_PVC_PREFIX    PMM /srv PVC name prefix. Default: read from the PMM
                            StatefulSet's volumeClaimTemplate, so it follows
                            storage.name automatically. Set only to override that.
  PMM_RESTORE_IMAGE         Image for the temp pod that restores /srv. Default: read
                            from the PMM StatefulSet (the pmm-backup sidecar in s3
                            mode, since it carries rclone). Needs tar, plus rclone
                            for --target s3. Refused rather than guessed if unreadable.
  CENTRAL_BACKUP_PVC        Central backup PVC name (shared-mode restore; auto-detected)

Concurrency:
  Per-component locking via coordination.k8s.io Leases in the namespace
  (pmm-backup-<component>) lets separate component backups run in parallel while stopping a
  backup and a restore of the same component from overlapping — across every client with
  kubectl access, not just processes that share a filesystem.

  TWO ways to run components concurrently, and they are not equivalent:
    --parallel            ONE process, all selected components at once. One manifest writer,
                          one metrics file, one summary. Prefer this.
    --backup-id <id>      SEPARATE processes sharing an id, e.g. one per component on
                          different machines. Each writes the same manifests/<id>.json, so
                          they merge it under a Lease — and if that lease cannot be taken, a
                          component is reported FAILED even though its data uploaded. Use it
                          only when the runs genuinely cannot be one process.

Consistency:
  Each component is captured independently, so a backup id is a CORRELATION of
  per-component snapshots taken at slightly different times — not a cluster-wide
  point-in-time. Each component is internally consistent (pg_dump is a single
  transaction snapshot, vmbackup snapshots, clickhouse-backup freezes); they are not
  consistent WITH EACH OTHER. The manifest records this as 'consistency: per-component'.

Manifest & Catalog (both modes):
  Components land under <component>/<id>/ — there isn't always one folder holding
  everything. Every run writes ONE index that ties the pieces together:
    s3 mode     -> s3://<bucket>/<prefix>/manifests/<id>.json   + .../latest
    shared mode -> <central>/manifests/<id>.json                + <central>/latest
  'latest' is a small text file holding the newest complete full-scope backup id.
  Use '$0 list' / '$0 list <id>' to read them. Restore drives each engine by the
  coordinates the manifest records (PG dump databases, CH backup name, VM/PMM paths).

Metrics:
  Backups write METRICS_DIR/backup_metrics.prom, restores write restore_metrics.prom.
  Every component appears in one file, distinguished by a 'component' LABEL rather than
  by file or port. The backup-tools pod serves every .prom in that directory over a
  single HTTP listener on port 9091, which vmagent scrapes as one job.

Prerequisites:
  - kubectl configured with access to the target cluster
  - timeout command (coreutils) and jq available in PATH
  - PostgreSQL: pg_dump/pg_restore available in the PG pod (default in Percona PG images)
  - ClickHouse: clickhouse-backup sidecar running (system.backup_actions table)
  - VictoriaMetrics: vmbackup sidecar container in vmstorage pods
  - PMM Server: tar/gzip available in the PMM server container (default in PMM images)

EOF
    exit 0
}

# Reject an operation-specific flag used with the wrong subcommand: both parents rejected
# the other tool's flags as unknown, and a typo'd restore flag silently accepted by a
# backup run would be worse than an error. 'list' accepts both sets (each parent's list
# reused its own full parser; the union keeps both shims' documented list invocations
# working). $1 = operation the flag belongs to, $2 = the flag itself.
flag_requires() {
    _fr_ok=false
    # $1 may name MORE THAN ONE subcommand ("backup restore"), for a flag both sides accept.
    case " $1 " in *" ${COMMAND} "*) _fr_ok=true ;; esac
    if [ "${_fr_ok}" = "true" ] || [ "${COMMAND}" = "list" ]; then
        _fr_ok=true
    elif [ "${COMMAND}" = "prune" ] && [ "$1" = "backup" ]; then
        # 'prune' is the backup side's retention half on its own entry point (DN-40), so it
        # takes the backup flag set — --retention above all, which is the one knob it needs.
        _fr_ok=true
    fi
    if [ "${_fr_ok}" != "true" ]; then
        echo "Error: Unknown option: $2"
        echo "Use --help for usage information"
        exit 1
    fi
    return 0
}

# ---- Component selection tables -------------------------------------------------------
# THE component table. Every per-component loop in this file reads it — selection, skipping,
# pre-flight discovery, lock lists, the backup run, the restore defaults, the restore verdict
# and the summaries. Adding a component is a row here plus its backup_/restore_ function.
# Handling one in the backup arm and forgetting it in the restore arm is what this prevents,
# and that failure is invisible because the missing case simply never fires. See DN-45.
#
# Colon-separated columns:
#   1 key      manifest key, path segment and metric label
#   2 flag     CLI stem: --<flag> and --skip-<flag>
#   3 label    log tag, e.g. [PostgreSQL]
#   4 bvar     BACKUP_*  selection variable
#   5 rvar     RESTORE_* selection variable
#   6 skipvar  SKIP_*    marker (restore; applied after the manifest defaults)
#   7 mfvar    MF_*      status this backup recorded for the component
#   8 okvar    *_OK      restore outcome
#   9 sel      'sel' if --<flag> selects it on the BACKUP side, 'nosel' if not
#
# The encryption key is 'nosel': on the backup side it is captured with PostgreSQL rather than
# chosen on its own, so it must not take part in "the first explicit --<component> turns the
# others off". --skip-encryption-key still turns it off, which is why it has a bvar at all.
COMPONENTS="postgresql:postgresql:PostgreSQL:BACKUP_POSTGRESQL:RESTORE_POSTGRESQL:SKIP_POSTGRESQL:MF_PG_STATUS:POSTGRESQL_OK:sel
clickhouse:clickhouse:ClickHouse:BACKUP_CLICKHOUSE:RESTORE_CLICKHOUSE:SKIP_CLICKHOUSE:MF_CH_STATUS:CLICKHOUSE_OK:sel
victoriametrics:victoriametrics:VictoriaMetrics:BACKUP_VICTORIAMETRICS:RESTORE_VICTORIAMETRICS:SKIP_VICTORIAMETRICS:MF_VM_STATUS:VICTORIAMETRICS_OK:sel
pmm-server:pmm-server:PMMServer:BACKUP_PMM_SERVER:RESTORE_PMM_SERVER:SKIP_PMM_SERVER:MF_PMM_STATUS:PMM_SERVER_OK:sel
encryption:encryption-key:EncryptionKey:BACKUP_ENCRYPTION_KEY:RESTORE_ENCRYPTION_KEY:SKIP_ENCRYPTION_KEY:MF_ENC_STATUS:ENCRYPTION_KEY_OK:nosel"

# The four components that own a <component>/<id>/ data path. This is what "full scope" means:
# 'latest' only advances onto a backup holding all four (DN-14) and the retention sweep's
# survivor guard tests the same predicate (DN-40). The encryption key rides with PostgreSQL.
CORE_COMPONENTS="postgresql clickhouse victoriametrics pmm-server"

# comp_col <key-or-flag> <column> — one column of the row matching either identifier. Both are
# accepted because the CLI knows a component by its flag and everything else by its key, and
# they differ for the encryption key.
comp_col() {
    _cc_want="$1" _cc_n="$2" _cc_row=""
    for _cc_row in ${COMPONENTS}; do
        case "${_cc_row}" in
            "${_cc_want}":*|*:"${_cc_want}":*) ;;
            *) continue ;;
        esac
        _cc_ifs="${IFS}"; IFS=:
        # shellcheck disable=SC2086
        set -- ${_cc_row}
        IFS="${_cc_ifs}"
        # Match on the two identifier columns only — a later column could otherwise collide.
        [ "$1" = "${_cc_want}" ] || [ "$2" = "${_cc_want}" ] || continue
        eval "printf '%s' \"\${${_cc_n}}\""
        return 0
    done
    return 1
}
comp_key()   { comp_col "$1" 1; }
comp_label() { comp_col "$1" 3; }
comp_bvar()  { comp_col "$1" 4; }
comp_rvar()  { comp_col "$1" 5; }
comp_mfvar() { comp_col "$1" 7; }
comp_okvar() { comp_col "$1" 8; }

# Value of the variable named in one column, e.g. comp_val postgresql 4 -> "$BACKUP_POSTGRESQL".
comp_val() {
    _cv_n=$(comp_col "$1" "$2") || return 1
    [ -n "${_cv_n}" ] || return 1
    eval "printf '%s' \"\${${_cv_n}}\""
}
# Is this component selected for the current operation? <key> <column>
comp_on() { [ "$(comp_val "$1" "$2" 2>/dev/null)" = "true" ]; }

# Turn ON one component. On the first explicit selection every other component is turned OFF,
# so `--clickhouse` means "only ClickHouse" while `--clickhouse --postgresql` means both.
# EXPLICIT_SELECTION is read before it is set, so the first call is the one that clears.
select_component() {
    _sc_want="$1" _sc_row="" _sc_key="" _sc_var=""
    for _sc_row in ${COMPONENTS}; do
        _sc_key="${_sc_row%%:*}"
        if [ "${COMMAND}" = "restore" ]; then
            _sc_var=$(comp_rvar "${_sc_key}")
        else
            # 'nosel' components are not selectable on the backup side (see the table).
            [ "$(comp_col "${_sc_key}" 9)" = "sel" ] || continue
            _sc_var=$(comp_bvar "${_sc_key}")
        fi
        [ -n "${_sc_var}" ] || continue
        if [ "${_sc_key}" = "${_sc_want}" ] || [ "$(comp_col "${_sc_key}" 2)" = "${_sc_want}" ]; then
            eval "${_sc_var}=true"
        elif [ "${EXPLICIT_SELECTION}" = "false" ]; then
            eval "${_sc_var}=false"
        fi
    done
    EXPLICIT_SELECTION=true
}

# Turn OFF one component. On backup that is immediate; on restore it records a SKIP_* marker,
# because the restore's defaults are not known until the manifest has been read (see
# select_default_components, which applies these last so they beat both the manifest defaults
# and an explicit selection).
skip_component() {
    if [ "${COMMAND}" = "restore" ]; then _kc_var=$(comp_col "$1" 6) || return 0
    else _kc_var=$(comp_bvar "$1") || return 0; fi
    [ -n "${_kc_var}" ] || return 0
    if [ "${COMMAND}" = "restore" ]; then eval "${_kc_var}=true"; else eval "${_kc_var}=false"; fi
    return 0
}

# Parse command-line arguments (after the subcommand has been consumed by the dispatch
# block at the bottom of this file, which also sets COMMAND before this runs).
# A value-taking flag whose value is missing. Without this, `"$2"` is an unset-variable read
# under `set -u`, so the operator got `pmm-backup.sh: line 546: $2: unbound variable` — a line
# number instead of the flag name, no "Use --help", and rc 2 rather than the file's own rc 1.
# A truncated CronJob argument list produces exactly this.
require_value() {   # <flag> <count-of-remaining-args>
    [ "$2" -ge 2 ] && return 0
    echo "Error: $1 requires a value" >&2
    echo "Use --help for usage information." >&2
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
        # Every branch below that consumes a value calls require_value "$1" $# first, so the
        # missing-value diagnostic is uniform and cannot be forgotten per-flag.
        case "$1" in
            -h|--help)
                show_help
                ;;
            -v|--verbose)
                VERBOSE=true
                ;;
            -n|--namespace)
                require_value "$1" $#; NAMESPACE="$2"; shift
                ;;
            -d|--backup-dir)
                require_value "$1" $#; BACKUP_DIR="$2"; shift
                ;;
            --backup-id)
                require_value "$1" $#; BACKUP_ID="$2"; shift
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --target)
                require_value "$1" $#; BACKUP_TARGET="$2"; shift
                ;;
            --shared-mount-path)
                require_value "$1" $#; SHARED_MOUNT_PATH="$2"; shift
                ;;
            --s3-bucket)
                require_value "$1" $#; S3_BUCKET="$2"; shift
                ;;
            --s3-endpoint)
                require_value "$1" $#; S3_ENDPOINT="$2"; shift
                ;;
            --s3-region)
                require_value "$1" $#; S3_REGION="$2"; shift
                ;;
            --s3-prefix)
                require_value "$1" $#; S3_PREFIX=$(echo "$2" | sed 's|^/||; s|/$||'); shift
                ;;
            --ch-secret)
                require_value "$1" $#; CH_SECRET_NAME="$2"; shift
                ;;
            # First explicit component selection disables the others; later ones combine.
            # Same semantics both operations — see COMPONENT_SELECT_FLAGS.
            --postgresql|--clickhouse|--victoriametrics|--pmm-server)
                select_component "${1#--}"
                ;;
            --encryption-key)
                flag_requires restore "$1"
                select_component encryption-key
                ;;
            --skip-postgresql|--skip-clickhouse|--skip-victoriametrics|--skip-pmm-server)
                skip_component "${1#--skip-}"
                ;;
            # backup: skip capturing the PMM encryption key (it rides with PostgreSQL);
            # restore: do not restore it.
            --skip-encryption-key)
                skip_component encryption-key
                ;;
            # ---- backup-only ----
            -r|--retention)
                flag_requires backup "$1"
                require_value "$1" $#; BACKUP_RETENTION="$2"; shift
                ;;
            --ch-backup-type)
                flag_requires backup "$1"
                require_value "$1" $#; CH_BACKUP_TYPE="$2"; shift
                ;;
            # Alias for the 'list' subcommand, in any mode — the help documents it as one,
            # so gating it to `restore` made the documented bare form error out.
            --list)
                LIST_ONLY=true
                ;;
            # ---- restore-only ----
            --parallel)
                flag_requires "backup restore" "$1"
                PARALLEL=true
                ;;
            --sequential)
                flag_requires "backup restore" "$1"
                PARALLEL=false
                ;;
            --s3-provider)
                flag_requires restore "$1"
                require_value "$1" $#; S3_PROVIDER="$2"; shift
                ;;
            --s3-secret)
                flag_requires restore "$1"
                require_value "$1" $#; S3_SECRET_NAME="$2"; shift
                ;;
            --s3-service-account)
                flag_requires restore "$1"
                require_value "$1" $#; S3_SERVICE_ACCOUNT="$2"; S3_SA_EXPLICIT=true; shift
                ;;
            -y|--yes|--force)
                flag_requires restore "$1"
                ASSUME_YES=true
                ;;
            *)
                echo "Error: Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
        shift
    done
    return 0
}

################################################################################
# 2. Logging
################################################################################

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${timestamp}] [${level}] ${message}"

    # Print to stdout exactly once, then best-effort append to the log file.
    # (The old `tee` form double-printed when the log file was unwritable, e.g. in
    # dry-run before the logs dir exists, because tee still wrote stdout then failed.)
    echo "${line}"
    if ! { echo "${line}" >> "${LOG_FILE}"; } 2>/dev/null; then
        if [ "${LOG_FILE_WARNING_SHOWN:-}" != "true" ]; then
            echo "[${timestamp}] [WARN] Unable to write to log file: ${LOG_FILE}"
            export LOG_FILE_WARNING_SHOWN=true
        fi
    fi
}

# Restore runs use their own log file name (and can fall back to /tmp when the
# central volume is unavailable); backup runs derive LOG_FILE at dispatch time.
#
# `date -u`, like every other timestamp this file mints. The backup and prune logs are named from
# ${TIMESTAMP}, which is UTC, and they land in THIS directory — so a local-time restore name meant
# one log series in two zones: `ls logs/` sorted DR drills into the wrong place relative to the
# backups they were restoring, by the container's offset. Same argument as the backup id (see the
# TIMESTAMP note at the top of this file).
init_log() {
    _il_ts=$(date -u +%Y%m%d-%H%M%S)
    LOG_FILE="${BACKUP_DIR}/logs/restore_${_il_ts}.log"
    if ! mkdir -p "${BACKUP_DIR}/logs" 2>/dev/null || ! : >>"${LOG_FILE}" 2>/dev/null; then
        LOG_FILE="/tmp/restore_${_il_ts}.log"
        : >>"${LOG_FILE}" 2>/dev/null || true
    fi
}

# Stream stdin (command output) to the log + stderr.
append_to_log() { tee -a "${LOG_FILE}" >&2 2>/dev/null || cat >&2; }

# Run a shell snippet inside a pod, or — in dry run — print the snippet that WOULD run.
#
# The script text is supplied ONCE and is both what gets logged and what gets executed, so the
# preview cannot drift from the run. --dry-run is the documented review gate for retention, and
# a preview that renders a different command than the one that executes is not a gate.
#
# Values are passed as POSITIONAL ARGUMENTS ("$1", "$2", ...), never interpolated into the
# script, so no value can alter what runs (DN-17).
#
# Usage: pod_sh <tag> <pod> <container|-> <timeout> <script> [args...]
# Returns the command's status; 0 in dry run (the caller's success path is what a real run takes).
pod_sh() {
    _ps_tag="$1" _ps_pod="$2" _ps_ctr="$3" _ps_to="$4" _ps_script="$5"; shift 5
    if [ "${DRY_RUN}" = "true" ]; then
        # To fd 9, not plain stdout: see the `exec 9>&1` note at the top of this file.
        log "INFO" "[${_ps_tag}] [DRY RUN] kubectl exec ${_ps_pod}$([ "${_ps_ctr}" = "-" ] || echo " -c ${_ps_ctr}") -- sh -c '${_ps_script}'" >&9
        [ $# -gt 0 ] && log "INFO" "[${_ps_tag}] [DRY RUN]   with: $*" >&9
        return 0
    fi
    if [ "${_ps_ctr}" = "-" ] || [ -z "${_ps_ctr}" ]; then
        timeout "${_ps_to}" kubectl exec -n "${NAMESPACE}" "${_ps_pod}" -- sh -c "${_ps_script}" sh "$@"
    else
        timeout "${_ps_to}" kubectl exec -n "${NAMESPACE}" "${_ps_pod}" -c "${_ps_ctr}" -- sh -c "${_ps_script}" sh "$@"
    fi
}

# Same contract as pod_sh, but WITHOUT a shell in the pod: argv goes straight to the container.
# That is what vmbackup / vmrestore / clickhouse-backup need — binaries with flags, not shell
# snippets — and no value is ever interpreted, so nothing needs quoting-proofing.
#
# The command is supplied ONCE and is both what gets previewed and what gets run (DN-46).
#
#   pod_exec <tag> <pod> <container|-> <timeout> <command> [args...]
# Returns the command's status; 0 in dry run (the caller's success path is what a real run takes).
pod_exec() {
    _pe_tag="$1" _pe_pod="$2" _pe_ctr="$3" _pe_to="$4"; shift 4
    if [ "${DRY_RUN}" = "true" ]; then
        # To fd 9, not plain stdout: see the `exec 9>&1` note at the top of this file.
        log "INFO" "[${_pe_tag}] [DRY RUN] kubectl exec ${_pe_pod}$([ "${_pe_ctr}" = "-" ] || echo " -c ${_pe_ctr}") -- $*" >&9
        return 0
    fi
    if [ "${_pe_ctr}" = "-" ] || [ -z "${_pe_ctr}" ]; then
        timeout "${_pe_to}" kubectl exec -n "${NAMESPACE}" "${_pe_pod}" -- "$@"
    else
        timeout "${_pe_to}" kubectl exec -n "${NAMESPACE}" "${_pe_pod}" -c "${_pe_ctr}" -- "$@"
    fi
}

# Format a byte count as a human-readable string (e.g. 1234567 -> "1.2MB").
# Single source of truth for size formatting across all components.
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i=1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i]; else printf "%.1f%s", b, u[i]
    }'
}

# sha256 of a file, or EMPTY when neither tool is present. Two spellings because the tool
# differs by image: coreutils ships sha256sum, BusyBox and macOS ship shasum. The caller decides
# what "no hash available" means — the backup records "N/A", the restore skips verification.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    fi
    # Always rc 0: callers assign this bare (`x=$(sha256_of f)`), where a non-zero status
    # aborts under `set -e`. "No hash" is signalled by EMPTY output, not by a return code.
    return 0
}

# jq is a hard requirement: it builds the manifest, which IS the restore index. Provided by
# the chart's backup-tools container at start-up, never installed mid-backup (see DN-26).
#
# Checked by RUNNING it, not by `command -v`: a binary can be on PATH and still be unusable
# (see DN-22).
ensure_jq() {
    command -v jq >/dev/null 2>&1 || return 1
    jq --version >/dev/null 2>&1
}

# Same, for rclone in s3 mode: it is this process's only way to reach the bucket.
ensure_rclone() {
    command -v rclone >/dev/null 2>&1 || return 1
    rclone version >/dev/null 2>&1
}

################################################################################
# 3+4. Layout + storage access (formerly the sourced backup-layout.sh)
################################################################################

# One definition of where a backup lives and how to read/write it, for BOTH operations. It was
# a separate sourced file with an unenforced pre-source contract; merging deleted the contract
# (DN-01).

# ---- Layout -------------------------------------------------------------------------
#   <root>/latest                  newest backup id
#   <root>/manifests/<id>.json     per-run index
#   <root>/<component>/<id>/...    component data
#
# Every component sits at the same depth in the same shape, ClickHouse included, and the
# namespace leads <root> so two installs cannot share it by default (DN-08).
#
# A backup is a correlation across component paths sharing an id, NOT a directory: atomicity is
# retention's job, not the layout's (DN-06).
#
# THREE VIEWS of one location (DN-05), across TWO targets:
#   path     what THIS process reads and writes through the store_* layer
#   display  what a human or an external tool sees (the s3:// URI)
#   inpod    what a COMPONENT POD sees (the shared mount; the same rclone spec on s3)
# Six near-identical functions expressed that one choice twice. It is made here, once.
backup_root() {   # [view]
    if [ "${S3_ENABLED}" = "true" ]; then
        case "${1:-path}" in
            display) echo "s3://${S3_BUCKET}/${S3_PREFIX}" ;;
            *)       echo "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}" ;;
        esac
    else
        case "${1:-path}" in
            inpod) echo "${SHARED_MOUNT_PATH}" ;;
            *)     echo "${BACKUP_DIR}" ;;
        esac
    fi
}
backup_root_display() { backup_root display; }
backup_root_inpod()   { backup_root inpod; }

# <root>/<component>/<id>, in one of the three views.
#
# An empty id resolves to the component ROOT — every backup of that component — so a caller
# that asks before the id is known must fail loudly. These are NOT merely read-only views:
# comp_inpod is what the ClickHouse backup tars into and what vm_dst_for_pod turns into
# vmbackup's fs:// destination, so an unset id there writes on top of every other backup.
comp_at() {   # <view> <component> [id]
    _ca_id="${3:-$(backup_id_default)}"
    [ -n "${_ca_id}" ] || { echo "BUG: backup id not yet known at path construction" >&2; return 1; }
    echo "$(backup_root "$1")/$2/${_ca_id}"
}
comp_path()    { comp_at path    "$1" "${2:-}"; }
comp_display() { comp_at display "$1" "${2:-}"; }
comp_inpod()   { comp_at inpod   "$1" "${2:-}"; }
manifest_path()    { echo "$(backup_root)/manifests/${1:-$(backup_id_default)}.json"; }
manifest_display() { echo "$(backup_root_display)/manifests/${1:-$(backup_id_default)}.json"; }
manifests_dir()    { echo "$(backup_root)/manifests"; }
latest_path()      { echo "$(backup_root)/latest"; }
# ClickHouse's remote root. clickhouse-backup owns the directory BELOW this (it creates
# <root>/clickhouse/<name>/ itself), but the root belongs here like every other component's —
# it was previously a hardcoded "${S3_PREFIX}/clickhouse" repeated at four call sites across
# both scripts, which is how backup came to write one place and restore to read another.
# Note this is the bucket-relative KEY, not an rclone remote spec: clickhouse-backup takes it
# as S3_PATH.
clickhouse_remote_key() { echo "${S3_PREFIX}/clickhouse"; }

# Where a RESTORE should look for ClickHouse: the coordinates the backup recorded, falling back
# to this run's own root for a manifest written before they existed (DN-43).
#
# ONE definition, used by both restore_clickhouse and the pre-flight gate. They already had to
# agree — DN-33 records what happened when they did not — and "agree" is cheaper to guarantee
# with a shared function than with a comment asking two call sites to stay in step.
ch_restore_bucket() { if [ -n "${MF_CH_S3_BUCKET}" ]; then printf '%s' "${MF_CH_S3_BUCKET}"; else printf '%s' "${S3_BUCKET}"; fi; }
ch_restore_path()   { if [ -n "${MF_CH_S3_PATH}" ]; then printf '%s' "${MF_CH_S3_PATH}"; else clickhouse_remote_key; fi; }

# The location string RECORDED IN THE MANIFEST and shown in summaries: the s3 URI, or — in
# shared mode — the path as a component POD sees it, which is the useful coordinate for anyone
# looking at the data from inside the cluster. Four components were branching for this.
comp_location() { if [ "${S3_ENABLED}" = "true" ]; then comp_display "$1"; else comp_inpod "$1"; fi; }

# The manifest is this tool's ON-STORAGE CONTRACT: written into a bucket that outlives any one
# install and read back by whatever version is running at DR time — routinely an OLDER one, since
# a DR cluster is restored from a chart release predating the bucket's newest backups (DN-41).
#
# Bump ONLY for a change an older reader would MIS-HANDLE: data moved somewhere it cannot derive,
# a field whose meaning changed, a component removed. A new OPTIONAL field is not a bump — older
# readers `// empty` past what they do not know. Absent means 1.
MANIFEST_SCHEMA=1

# Read a manifest's schema (JSON on stdin), defaulting to 1. Prints nothing and returns 1 when
# the value is not a plain integer — a manifest whose version cannot be read is one whose
# meaning cannot be trusted, and every caller treats that as "newer" rather than guessing.
manifest_schema_of() {
    _mso=$(jq -r 'if has("schema") then (.schema | tostring) else "1" end' 2>/dev/null) || return 1
    case "${_mso}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "${_mso}"
}

# Every component owning a <component>/<id>/ path. Retention iterates this, `list` prints it
# and restore validates it — a component missing here is one nothing prunes and nothing
# checks. Names are exactly the manifest's component keys, so there is one name per component
# in the path, the manifest and the --skip-<component> flags.
BACKUP_COMPONENTS="postgresql clickhouse victoriametrics pmm-server encryption"

# Local scratch for components that must build a file before it can be stored (the exported
# encryption key). Deliberately NOT a comp_path: on s3 that is an rclone remote spec, and
# mkdir'ing it created a directory literally named "s3:<bucket>/…" on the container's
# writable layer, off-volume and unreaped.
staging_dir() { echo "${BACKUP_DIR}/.staging/$(backup_id_default)/$1"; }

# ---- Storage access -----------------------------------------------------------------
# The ONLY code that knows s3 from shared. Everything else builds paths and calls these.
#
# CONTRACT: rc 0 = the operation happened. Non-zero means "could not do it", which callers
# must NOT conflate with "the data is absent". Consequently NO function here may end in a
# pipe. Both rules are load-bearing for retention and the restore gate — see DN-03.
store_read() {
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone cat "$1"
    else cat "$1"; fi
}
store_write() {  # <path> <- stdin
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone_rcat "$1"
    else mkdir -p "$(dirname "$1")" && cat > "$1"; fi
}
# Same, for secrets. `cat >` creates 0644 under the default umask, so the PG encryption key —
# which decrypts the database — was landing world-readable on a central RWX volume that every
# component pod mounts. The mode is set BEFORE the content is written so there is no window in
# which the file exists readable. On s3 the object's ACL comes from the bucket, not a file
# mode, so there is nothing extra to do there.
store_write_private() {
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone_rcat "$1"; else
        mkdir -p "$(dirname "$1")" || return 1
        : > "$1" || return 1
        chmod 600 "$1" || return 1
        cat > "$1"
    fi
}
# List a location. CONTRACT: empty output with rc 0 means "nothing there"; a non-zero rc means
# "could not look". An unreadable directory (EACCES after an fsGroup change, NFS squash, a
# root-owned dir from an older chart) must NOT read as empty — that conflation is what let a
# failed purge report "provably gone" while the manifest was deleted anyway (DN-04).
# <mode> is all | files | dirs. rclone marks directories with a trailing '/', stripped here.
store_list_at() {   # <mode> <path>
    _sla_out=""
    if [ "${S3_ENABLED}" = "true" ]; then
        case "$1" in
            files) _sla_out=$(s3_rclone lsf --files-only "$2/") || return $? ;;
            dirs)  _sla_out=$(s3_rclone lsf --dirs-only "$2/") || return $?
                   _sla_out=$(printf '%s\n' "${_sla_out}" | sed 's:/$::') ;;
            *)     _sla_out=$(s3_rclone lsf "$2/") || return $? ;;
        esac
    else
        [ -d "$2" ] || return 0
        [ -r "$2" ] || return 1
        case "$1" in
            files) _sla_out=$(ls -1p "$2" 2>/dev/null | grep -v '/$' || true) ;;
            dirs)  _sla_out=$(ls -1p "$2" 2>/dev/null | sed -n 's:/$::p' || true) ;;
            *)     _sla_out=$(ls -1 "$2" 2>/dev/null || true) ;;
        esac
    fi
    [ -n "${_sla_out}" ] && printf '%s\n' "${_sla_out}"
    return 0
}
store_list()       { store_list_at all   "$1"; }
store_list_files() { store_list_at files "$1"; }
store_list_dirs()  { store_list_at dirs  "$1"; }

# Byte count on stdout; rc non-zero = could not look, which is how callers tell "empty/absent"
# from "unknown".
#
# Does NOT end in a pipe, per this section's contract: ending in `printf | sed` takes the rc from
# the PARSER, so a successful read the parser could not understand returned rc 0 with EMPTY
# output — which s3_object_state then read as "absent" rather than "the check failed", the
# fail-open direction the restore gate exists to prevent (DN-03, DN-15).
#
# An unparseable read is rc 1. A legitimate "0" is rc 0 with "0": `rclone size` on a missing path
# exits 0 printing {"count":0,"bytes":0}, and telling those apart is s3_object_state's job.
store_bytes() {
    _sb_out="" _sb_n=""
    if [ "${S3_ENABLED}" = "true" ]; then
        _sb_out=$(s3_rclone size --s3-no-check-bucket --json "$1" 2>/dev/null) || return $?
        _sb_n=$(printf '%s' "${_sb_out}" | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p')
    else
        [ -f "$1" ] || { echo 0; return 0; }
        _sb_out=$(wc -c < "$1" 2>/dev/null) || return $?
        _sb_n=$(printf '%s' "${_sb_out}" | tr -dc '0-9')
    fi
    [ -n "${_sb_n}" ] || return 1
    printf '%s' "${_sb_n}"
    return 0
}
# Both deletes treat ABSENT as success: retention retries ids whose purge partially failed,
# so a second attempt must not fail on what the first already removed. rclone purge and
# deletefile both tolerate a missing path, so no separate existence probe is issued — one
# round-trip per delete instead of two, which matters when a sweep does dozens.
store_delete_prefix() {
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone_purge "$1" >> "${LOG_FILE}" 2>&1 && return 0
        store_absent "$1"
    else
        rm -rf "$1" >> "${LOG_FILE}" 2>&1
    fi
}
store_delete_object() {
    if [ "${S3_ENABLED}" = "true" ]; then
        # Via the s3_rclone_deletefile primitive, NOT a hand-rolled kubectl exec: that
        # primitive carries the stale-client-pod retry, and a long sweep is exactly when the
        # cached PMM pod gets replaced. It also keeps kubectl/NAMESPACE/container knowledge in
        # the caller's primitives rather than in this layer.
        s3_rclone_deletefile "$1" >> "${LOG_FILE}" 2>&1 && return 0
        store_absent "$1"
    else
        rm -f "$1" >> "${LOG_FILE}" 2>&1
    fi
}
# A failed delete is forgivable ONLY if absence is POSITIVELY established: a listing that
# succeeds and does not contain the entry. store_list, NOT store_list_files — a files-only
# listing can never contain a surviving DIRECTORY. See DN-04 for what that cost.
# rclone marks directories with a trailing '/', stripped before comparing.
store_absent() {
    _sa_out=$(store_list "$(dirname "$1")" 2>/dev/null) || return 1
    ! printf '%s\n' "${_sa_out}" | sed 's:/$::' | grep -Fxq "$(basename "$1")"
}

# ---- Catalog ------------------------------------------------------------------------
# The single way to answer "which backups exist", "what is in one", "which is latest" — for
# either target. Retention, `list` and restore all go through these, so the destructive path
# and the read-only paths cannot disagree about what a backup id is.
catalog_ids() {
    _ci_raw=$(store_list_files "$(manifests_dir)") || return $?
    printf '%s\n' "${_ci_raw}" | sed -n 's/\.json$//p' | grep -v '^$' | sort || true
}
# Per-run cache for manifest reads. A retention sweep reads the SAME manifest three times per
# deletion candidate (the ownership proof, the chain pass, the component list), each a separate
# rclone process and S3 round-trip — ~90 spawns on a 30-day catalog before the first delete, all
# inside the lock window and all charged to the S3_PRUNE_MAX_SECONDS budget.
#
# Only SUCCESSFUL, non-empty reads are cached: a failure must stay a failure that the next
# caller can retry, because "could not read" drives fail-closed decisions (DN-03). And any
# writer of a manifest must drop its entry — see catalog_cache_drop.
CATALOG_CACHE_DIR=""

# A cache file name that cannot escape the cache dir. Ids come from bucket listings, so they may
# contain '/' and worse; the same reason comp_path charset-gates them (DN-17).
catalog_cache_file() {
    [ -n "${CATALOG_CACHE_DIR}" ] || return 1
    printf '%s/%s' "${CATALOG_CACHE_DIR}" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g')"
}

catalog_cache_init() {
    [ -z "${CATALOG_CACHE_DIR}" ] || return 0
    CATALOG_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pmm-backup-catalog.XXXXXX" 2>/dev/null) || CATALOG_CACHE_DIR=""
    return 0
}

catalog_cache_clear() {
    [ -n "${CATALOG_CACHE_DIR}" ] || return 0
    rm -rf "${CATALOG_CACHE_DIR}" 2>/dev/null || true
    CATALOG_CACHE_DIR=""
    return 0
}

# Invalidate one id. MUST be called by anything that writes a manifest, or a later read in the
# same run gets the pre-write content — retention's chain-pinned branch rewrites a manifest
# mid-sweep, so this is not hypothetical.
catalog_cache_drop() {
    _ccd_f=$(catalog_cache_file "$1" 2>/dev/null) || return 0
    [ -n "${_ccd_f}" ] && rm -f "${_ccd_f}" 2>/dev/null
    return 0
}

catalog_manifest() {
    _cm_f=$(catalog_cache_file "$1" 2>/dev/null) || _cm_f=""
    if [ -n "${_cm_f}" ] && [ -s "${_cm_f}" ]; then
        cat "${_cm_f}"
        return 0
    fi
    _cm_out=$(store_read "$(manifest_path "$1")" 2>/dev/null) || return $?
    [ -n "${_cm_out}" ] || return 1
    if [ -n "${_cm_f}" ]; then
        printf '%s' "${_cm_out}" > "${_cm_f}" 2>/dev/null || true
    fi
    printf '%s' "${_cm_out}"
    return 0
}
catalog_latest() {
    _cl_raw=$(store_read "$(latest_path)" 2>/dev/null) || return $?
    printf '%s' "${_cl_raw}" | tr -d '[:space:]'
}

# The id every path builder defaults to: THE backup this process is working on. Set exactly
# once per operation (backup/list at dispatch, restore in load_manifest). It deliberately does
# NOT branch on ${COMMAND} — that put subcommand knowledge in the file's lowest layer, where
# ~40 call sites depend on pure path arithmetic. Empty until set, which _require_id turns into
# a loud failure rather than a silent read one level too high.
backup_id_default() { echo "${CURRENT_ID}"; }

################################################################################
# 5. Kubernetes primitives (S3 access, waiters, locks)
################################################################################

# S3 access is LOCAL: the backup-tools container installs rclone and jq at start-up and the pod
# carries its own S3 credentials (RCLONE_CONFIG_S3_* + AWS_* / the SA credential chain).
# Everything below is a thin wrapper over it.
#
# DN-26 records why, and which payloads deliberately still go pod -> destination directly
# rather than through this process.

# Every rclone call is BOUNDED, two independent ways. An endpoint that accepts the connection
# and then never answers (a throttled bucket, a wedged MinIO/Ceph) otherwise blocks for rclone's
# own defaults — 5m idle x 3 retries — which hung `list`, stalled the restore pre-flight, and
# made S3_PRUNE_MAX_SECONDS unenforceable (it is only checked BETWEEN ids, never inside a purge).
#
#   1. rclone's own idle/connect timeouts, on every call including the streaming ones: they
#      bound a stalled transfer without killing one that is still moving data.
#   2. a hard `timeout` wall clock on metadata, read and delete ops, which are expected to be
#      quick. Deliberately NOT on rcat, which carries multi-gigabyte pg_dump streams.
# Each falls back to its default if not a positive integer — `timeout abc` just fails and
# `--timeout 0s` means "no timeout" to rclone, so a typo must not silently disable a bound.
RCLONE_IO_TIMEOUT="${RCLONE_IO_TIMEOUT:-60}"           # rclone --timeout: idle IO per attempt
numeric_env RCLONE_IO_TIMEOUT 60
RCLONE_CONNECT_TIMEOUT="${RCLONE_CONNECT_TIMEOUT:-15}" # rclone --contimeout
numeric_env RCLONE_CONNECT_TIMEOUT 15
RCLONE_TIMEOUT="${RCLONE_TIMEOUT:-${KUBECTL_STATUS_TIMEOUT}}"  # wall clock: cat/lsf/size/deletefile
# The clamp falls back to the DOCUMENTED default, not to a second hardcoded number. With a
# literal 30 here, `RCLONE_TIMEOUT=5m` on an install that raised KUBECTL_STATUS_TIMEOUT to 120
# silently reverted rclone to 30s while --help promised it followed the status timeout — the same
# two-artifacts-own-one-value drift DN-39 records. KUBECTL_STATUS_TIMEOUT is itself already
# clamped above, so it is guaranteed to be a usable number by the time it is used as the default.
numeric_env RCLONE_TIMEOUT "${KUBECTL_STATUS_TIMEOUT}"
RCLONE_PURGE_TIMEOUT="${RCLONE_PURGE_TIMEOUT:-300}"    # wall clock: one recursive prefix delete
numeric_env RCLONE_PURGE_TIMEOUT 300
# Idle bound for the STREAMING op, deliberately rclone's own default rather than the tight
# metadata one. ${RCLONE_IO_TIMEOUT} on a stream is the same mistake as a wall clock, just
# quieter: `pg_dump -Fc` piped into rcat can legitimately emit nothing for minutes while it
# waits on an ACCESS SHARE lock or scans a large index, and rclone would then close an upload
# it cannot rewind stdin to retry — so a healthy dump is deleted as truncated and PostgreSQL
# is recorded failed.
RCLONE_STREAM_IO_TIMEOUT="${RCLONE_STREAM_IO_TIMEOUT:-300}"
numeric_env RCLONE_STREAM_IO_TIMEOUT 300

# rclone for a STREAM: connect bound plus the generous stream idle bound, and no wall clock —
# a wall clock here kills a healthy backup of a large database.
_rclone_stream() {
    rclone --contimeout "${RCLONE_CONNECT_TIMEOUT}s" --timeout "${RCLONE_STREAM_IO_TIMEOUT}s" "$@"
}
# rclone with idle bounds AND a wall clock: _rclone_bounded <seconds> <rclone args...>
_rclone_bounded() {
    _rb_t="$1"; shift
    timeout "${_rb_t}" rclone --contimeout "${RCLONE_CONNECT_TIMEOUT}s" --timeout "${RCLONE_IO_TIMEOUT}s" "$@"
}

# rclone read ops (cat/lsf/size). No retry loop: a local process either runs or does not.
s3_rclone() {
    _rclone_bounded "${RCLONE_TIMEOUT}" "$@"
}

# Pipe stdin into an object (manifest.json, the 'latest' pointer, pg_dump streams). No wall
# clock and a generous idle bound — see _rclone_stream for why both matter here.
s3_rclone_rcat() {
    _rclone_stream rcat --s3-no-check-bucket "$1"
}

# DESTRUCTIVE: recursively delete an S3 prefix. Kept separate from s3_rclone(), which is
# documented read-only — widening that helper would make every future call site a potential
# data-loss path. Expect a benign AccessDenied on a versioning probe in the log (DN-31).
# Bounded per call, which is what makes the sweep's S3_PRUNE_MAX_SECONDS budget meaningful:
# the budget is checked between ids, so one unbounded purge could blow it on its own.
s3_rclone_purge() {
    _rclone_bounded "${RCLONE_PURGE_TIMEOUT}" purge --s3-no-check-bucket "$1"
}

# Single-object delete, a primitive next to purge so store_delete_object never has to know
# how S3 is reached.
s3_rclone_deletefile() {
    _rclone_bounded "${RCLONE_TIMEOUT}" deletefile --s3-no-check-bucket "$1"
}

# The endpoint vmbackup/vmrestore should use: the VictoriaMetrics-specific override if the
# chart projected one, else the shared endpoint. Empty output means "pass no flag" (AWS).
vm_s3_endpoint() {
    if [ -n "${VM_S3_ENDPOINT}" ]; then printf '%s' "${VM_S3_ENDPOINT}"; else printf '%s' "${S3_ENDPOINT}"; fi
}

# vmbackup/vmrestore take the custom endpoint as a FLAG, not an env var. Expands to nothing on
# plain AWS, which is the default case and not an error — hence a function rather than the
# `[ -n x ] && y` one-liner it replaces, which returns 1 when the test fails and aborts under
# `set -e` wherever errexit is not suppressed.
vm_endpoint_arg() {
    _vef=$(vm_s3_endpoint)
    [ -n "${_vef}" ] && printf '%s' "-customS3Endpoint=${_vef}"
    return 0
}

# Same tri-state for a namespaced Kubernetes object. kubectl exits non-zero for Forbidden,
# apiserver 5xx and timeouts just as it does for NotFound, so the stderr text is what
# separates "absent" from "could not check" — relevant for the documented cross-namespace
# restore, where a namespaced Role yields 403 for an object that exists.
k8s_object_state() {
    local kind="$1" name="$2" err rc=0
    err=$(kubectl get "${kind}" "${name}" -n "${NAMESPACE}" 2>&1 >/dev/null) || rc=$?
    [ "${rc}" -eq 0 ] && return 0
    case "${err}" in
        *NotFound*|*"not found"*) return 1 ;;
        *) return 2 ;;
    esac
}

################################################################################
# Generic waiters
################################################################################
wait_for_pods_gone() {
    # $4 (optional) "soft": timeout is tolerated by the caller — log WARN, not ERROR.
    local ns="$1" selector="$2" max_wait="${3:-${KUBECTL_EXEC_TIMEOUT}}" severity="${4:-}" elapsed=0 count out krc
    while [ $elapsed -lt $max_wait ]; do
        # Separate kubectl's exit status from its output. Piping straight into `wc -l` means a
        # failed `kubectl get` (transient apiserver 5xx / network blip) yields 0 lines and would
        # be read as "all pods gone" — letting the restore write DBs while PMM is still Running,
        # or tear down vmstorage prematurely. Only a SUCCESSFUL empty listing counts as gone.
        out=$(kubectl get pods -n "${ns}" -l "${selector}" --no-headers 2>/dev/null); krc=$?
        if [ ${krc} -ne 0 ]; then
            [ "${VERBOSE}" = "true" ] && log "INFO" "kubectl get pods failed (rc=${krc}, ${selector}); not assuming gone, retrying..."
            sleep 5; elapsed=$((elapsed + 5)); continue
        fi
        # `|| true`: grep -c EXITS 1 when the count is zero, which is the SUCCESS case here.
        # Without it the assignment returns non-zero and, in any call context where errexit is
        # not suppressed, the run dies silently the moment the pods are actually gone — no
        # "All pods gone", no ERROR, nothing in the log, with PMM already scaled to 0. It only
        # survived because all three current callers happen to sit behind `||` / `if !`.
        # wait_for_pods_ready and vm_src_ordinal_count already do this.
        count=$(printf '%s\n' "${out}" | grep -c '[^[:space:]]' || true)
        : "${count:=0}"
        if [ "${count}" -eq 0 ]; then log "INFO" "All pods gone (selector: ${selector})"; return 0; fi
        [ "${VERBOSE}" = "true" ] && log "INFO" "Waiting for ${count} pod(s) to terminate (${selector}, ${elapsed}/${max_wait}s)..."
        sleep 5; elapsed=$((elapsed + 5))
    done
    if [ "${severity}" = "soft" ]; then
        log "WARN" "Pods still terminating after ${max_wait}s (selector: ${selector})"
    else
        log "ERROR" "Timed out waiting for pods to terminate (selector: ${selector}, ${max_wait}s)"
    fi
    return 1
}

wait_for_pods_ready() {
    local ns="$1" selector="$2" expected="$3" max_wait="${4:-${KUBECTL_EXEC_TIMEOUT}}" elapsed=0 ready
    while [ $elapsed -lt $max_wait ]; do
        ready=$(kubectl get pods -n "${ns}" -l "${selector}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
        : "${ready:=0}"
        if [ "${ready}" -ge "${expected}" ] 2>/dev/null; then log "INFO" "${ready}/${expected} pod(s) ready (${selector})"; return 0; fi
        [ "${VERBOSE}" = "true" ] && log "INFO" "Waiting for pods ready: ${ready}/${expected} (${selector}, ${elapsed}/${max_wait}s)..."
        sleep 5; elapsed=$((elapsed + 5))
    done
    log "ERROR" "Timed out waiting for pods ready (selector: ${selector}, ${max_wait}s)"; return 1
}

# Wait until a set of pods has actually been REPLACED, not merely until "enough report Ready".
# A Terminating pod keeps Ready=True for its whole grace period, so after `kubectl delete pod -l`
# the plain readiness count is satisfied by the very pods being deleted. Requires: none of the
# pre-delete pods still exist, AND `expected` of the ones that do are Ready.
#
# Identity is the pod UID, NOT the name: vmselect is a StatefulSet, so the replacement carries
# the SAME name and a name comparison could never see the old set drain (DN-29).
#   wait_for_pods_replaced <ns> <selector> <old-uids> <expected> [timeout]
wait_for_pods_replaced() {
    local ns="$1" selector="$2" old_uids="$3" expected="$4" max_wait="${5:-${KUBECTL_EXEC_TIMEOUT}}"
    local elapsed=0 uids ready survivors _n
    while [ $elapsed -lt $max_wait ]; do
        # kubectl's STATUS decides what an empty result means. `|| true` conflates "could not
        # look" with "the old pods are gone", so a transient apiserver 5xx would make survivors
        # 0 while the readiness count below still saw the OLD pods as Ready — the bounce would
        # report success with vmselect still serving the pre-restore view (DN-03, DN-29).
        local _krc=0
        uids=$(kubectl get pods -n "${ns}" -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null) || _krc=$?
        if [ "${_krc}" -ne 0 ]; then
            [ "${VERBOSE}" = "true" ] && log "INFO" "kubectl get pods failed (rc=${_krc}, ${selector}); not assuming replaced, retrying..."
            sleep 5; elapsed=$((elapsed + 5)); continue
        fi
        survivors=0
        for _n in ${old_uids}; do
            printf '%s\n' "${uids}" | grep -Fxq "${_n}" && survivors=$((survivors + 1))
        done
        if [ "${survivors}" -eq 0 ]; then
            ready=$(kubectl get pods -n "${ns}" -l "${selector}" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
            : "${ready:=0}"
            if [ "${ready}" -ge "${expected}" ] 2>/dev/null; then
                log "INFO" "${ready}/${expected} replacement pod(s) ready (${selector})"; return 0
            fi
        fi
        [ "${VERBOSE}" = "true" ] && log "INFO" "Waiting for replacement pods (${selector}: ${survivors} old still present, ${elapsed}/${max_wait}s)..."
        sleep 5; elapsed=$((elapsed + 5))
    done
    log "ERROR" "Timed out waiting for pods to be replaced (selector: ${selector}, ${max_wait}s)"; return 1
}

wait_for_pod_ready_by_name() {
    local ns="$1" name="$2" max_wait="${3:-${KUBECTL_EXEC_TIMEOUT}}" elapsed=0 ready
    while [ $elapsed -lt $max_wait ]; do
        ready=$(kubectl get pod -n "${ns}" "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [ "${ready}" = "True" ]; then log "INFO" "Pod ${name} is ready"; return 0; fi
        [ "${VERBOSE}" = "true" ] && log "INFO" "Waiting for pod ${name} ready (${elapsed}/${max_wait}s)..."
        sleep 5; elapsed=$((elapsed + 5))
    done
    log "ERROR" "Timed out waiting for pod ${name} ready (${max_wait}s)"; return 1
}

wait_for_pod_gone_by_name() {
    local ns="$1" name="$2" max_wait="${3:-120}" elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        kubectl get pod -n "${ns}" "${name}" >/dev/null 2>&1 || return 0
        sleep 5; elapsed=$((elapsed + 5))
    done
    log "WARN" "Pod ${name} did not terminate in ${max_wait}s; forcing delete"
    kubectl delete pod "${name}" -n "${ns}" --grace-period=0 --force --wait=false 2>&1 | append_to_log || true
    sleep 10
    kubectl get pod -n "${ns}" "${name}" >/dev/null 2>&1 && return 1 || return 0
}

################################################################################
# Lock management — per-component Leases shared by BOTH operations, so a backup and a
# restore of the same component exclude each other while different components run
# concurrently.
################################################################################

# Locks are CLUSTER-scoped, held as coordination.k8s.io Leases in the namespace, because the
# thing being protected — a database in the cluster — is shared by everything with kubectl
# access. A local lockdir plus `kill -0 <pid>` only excludes processes sharing a filesystem AND
# a PID namespace, so a restore from a laptop and the CronJob's backup could write the same
# database concurrently. A Lease makes creation atomic (AlreadyExists is the contention signal)
# and puts expiry in the object rather than in a guess about a PID. (DN-37)
LOCK_LEASE_SECONDS="${LOCK_LEASE_SECONDS:-900}"
numeric_env LOCK_LEASE_SECONDS 900
LOCK_RENEW_SECONDS="${LOCK_RENEW_SECONDS:-60}"
numeric_env LOCK_RENEW_SECONDS 60
LOCK_HOLDER="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}-$$"
LOCK_RENEWER_PID=""

# Lease names are Kubernetes object names (DNS-1123 subdomain: lowercase alphanumerics, '-'
# and '.', starting and ending alphanumeric). The component names are already compliant, but
# write_manifest's lease embeds TIMESTAMP, which --backup-id may set to anything in
# [A-Za-z0-9_-]: an uppercase letter or an underscore made the apiserver reject the create as
# Invalid rather than AlreadyExists, so the merge lock could never be held and the shared
# manifest was written unprotected — in exactly the multi-process workflow the merge exists
# for. Sanitising can only ever MERGE two names into one, which over-locks (safe); it can
# never split one lock into two.
lease_name() {
    _lnm=$(printf 'pmm-backup-%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')
    _lnm=$(printf '%.63s' "${_lnm}")
    printf '%s' "${_lnm}" | sed 's/[^a-z0-9]*$//'
}
# MicroTime, which is what Lease.spec.renewTime is.
lease_now() { date -u +%Y-%m-%dT%H:%M:%S.000000Z; }

# Epoch seconds for a UTC calendar time, computed ARITHMETICALLY — no `date` parsing at all.
#
# Every timestamp this file produces is UTC, but no `date` implementation has a portable way to
# say "this string is UTC": GNU and BusyBox both read it in the container's LOCAL zone, and
# neither form exists on BSD/macOS at all. The consequences are not cosmetic — east of UTC a
# fresh lease reads as expired and a LIVE lock gets stolen, west of UTC no lease ever expires,
# and on macOS both helpers returned empty so retention skipped every backup. (DN-37)
#
# days_from_civil (Howard Hinnant): calendar date -> days since 1970-01-01, integer only.
# Callers shape-check the input; years before 1970 are rejected rather than handled.
# epoch_utc <YYYY> <MM> <DD> <hh> <mm> <ss>
epoch_utc() {
    # Strip ONE leading zero per field: shell arithmetic reads a leading zero as octal, so
    # $((08)) is a fatal "value too great for base" rather than 8. Fields are fixed width, so
    # one strip is enough ("00" -> "0", "08" -> "8", "12" -> "12").
    _eu_y="$1"; _eu_mo="${2#0}"; _eu_d="${3#0}"
    _eu_h="${4#0}"; _eu_mi="${5#0}"; _eu_s="${6#0}"
    [ -n "${_eu_mo}" ] || _eu_mo=0; [ -n "${_eu_d}" ] || _eu_d=0
    [ -n "${_eu_h}" ] || _eu_h=0; [ -n "${_eu_mi}" ] || _eu_mi=0; [ -n "${_eu_s}" ] || _eu_s=0
    case "${_eu_y}${_eu_mo}${_eu_d}${_eu_h}${_eu_mi}${_eu_s}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${_eu_y}" -ge 1970 ] || return 1
    [ "${_eu_mo}" -ge 1 ] && [ "${_eu_mo}" -le 12 ] || return 1
    [ "${_eu_d}" -ge 1 ] && [ "${_eu_d}" -le 31 ] || return 1
    [ "${_eu_h}" -le 23 ] && [ "${_eu_mi}" -le 59 ] && [ "${_eu_s}" -le 60 ] || return 1

    # March-based year: Jan/Feb belong to the previous year, which puts the leap day last and
    # makes the day-of-year polynomial below exact.
    _eu_yy="${_eu_y}"
    if [ "${_eu_mo}" -le 2 ]; then
        _eu_yy=$((_eu_yy - 1)); _eu_mp=$((_eu_mo + 9))
    else
        _eu_mp=$((_eu_mo - 3))
    fi
    _eu_era=$((_eu_yy / 400))
    _eu_yoe=$((_eu_yy - _eu_era * 400))
    _eu_doy=$(( (153 * _eu_mp + 2) / 5 + _eu_d - 1 ))
    _eu_doe=$(( _eu_yoe * 365 + _eu_yoe / 4 - _eu_yoe / 100 + _eu_doy ))
    _eu_days=$(( _eu_era * 146097 + _eu_doe - 719468 ))
    printf '%s\n' "$(( _eu_days * 86400 + _eu_h * 3600 + _eu_mi * 60 + _eu_s ))"
}

# Epoch for an RFC3339 UTC timestamp, or non-zero. Anything carrying an explicit non-Z offset
# fails the shape check and is reported as unparseable, which lease_expired turns into "cannot
# tell" — the safe direction, since a lock we cannot age must not be stolen.
epoch_from_rfc3339() {
    _efr=$(printf '%s' "${1:-}" | sed 's/\..*$//; s/Z$//; s/T/ /')
    case "${_efr}" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    # Deliberate word splitting into the six fields; digits cannot glob, so `set -f` state is
    # irrelevant here.
    # shellcheck disable=SC2046
    set -- $(printf '%s' "${_efr}" | tr -- '-:' '  ')
    epoch_utc "$1" "$2" "$3" "$4" "$5" "$6"
}

# Has a lease expired? 0 = expired (safe to take over), 1 = still live, 2 = cannot tell.
# Cannot-tell must NOT read as expired: stealing a live lock lets two runs write one database.
lease_expired() {   # <renewTime> <durationSeconds>
    _le_t=$(epoch_from_rfc3339 "$1") || return 2
    case "${_le_t}" in ''|*[!0-9]*) return 2 ;; esac
    case "${2:-}" in ''|*[!0-9]*) return 2 ;; esac
    [ $(( $(date +%s) - _le_t )) -gt "$2" ]
}

# The body of a Lease object. Identical for a create and for a resourceVersion-guarded replace
# — the only difference is that one line, which is what makes a takeover exclusive.
#   lease_manifest <name> <duration> <locked-component-or-empty> <resource-version-or-empty>
lease_manifest() {
    printf 'apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: %s\n' "$1"
    [ -n "${4:-}" ] && printf '  resourceVersion: "%s"\n' "$4"
    printf '  labels:\n    app.kubernetes.io/component: pmm-backup-lock\n'
    [ -n "${3:-}" ] && printf '    pmm.percona.com/locked-component: %s\n' "$3"
    printf 'spec:\n  holderIdentity: %s\n  leaseDurationSeconds: %s\n  acquireTime: %s\n  renewTime: %s\n' \
        "${LOCK_HOLDER}" "$2" "$(lease_now)" "$(lease_now)"
}

# ONE attempt to take a Lease, shared by the component locks and write_manifest's merge lease —
# a primitive where a divergence between two copies means two runs writing one database (DN-46).
#
# Returns:
#   0  acquired: created it, or took over one that had demonstrably expired
#   1  NOT acquired; LEASE_STATE says why (see below) — never steal on this
#   2  the attempt itself failed (RBAC, unreachable apiserver). NOT "the lock is free"
#   3  lost the takeover race: someone else took it, or its holder renewed it
#
# LEASE_STATE is 'live' (a real holder), 'unknown' (expiry could not be determined) or 'norv'
# (looks expired, but its resourceVersion could not be read, so no exclusive takeover is
# possible). LEASE_ERR/LEASE_HOLDER/LEASE_RENEW carry the detail for the caller's message.
LEASE_ERR="" ; LEASE_HOLDER="" ; LEASE_RENEW="" ; LEASE_STATE=""
lease_try_acquire() {   # <lease-name> <duration-seconds> [locked-component]
    _lta_n="$1" _lta_d="$2" _lta_c="${3:-}" _lta_rc=0 _lta_state="" _lta_rv="" _lta_dur=""
    _lta_body=""
    LEASE_ERR=""; LEASE_HOLDER=""; LEASE_RENEW=""; LEASE_STATE=""
    # Rendered into a variable and fed by HERE-DOC, never piped into kubectl. A pipe adds an
    # EPIPE surface the heredoc does not have: kubectl can exit before draining stdin (a
    # validation error, a bad --namespace), and the writer then dies of SIGPIPE printing
    # "write error: Broken pipe" onto the OPERATOR'S stderr — outside the 2>&1 that captures
    # kubectl's own, so it is noise nothing can suppress or attribute.
    _lta_body=$(lease_manifest "${_lta_n}" "${_lta_d}" "${_lta_c}" "")
    # Creation is the atomic operation: exactly one caller can succeed and everyone else gets
    # AlreadyExists. `create`, never `apply` — apply would happily take over a live lock.
    LEASE_ERR=$(kubectl create -f - -n "${NAMESPACE}" 2>&1 >/dev/null <<EOF
${_lta_body}
EOF
    ) || _lta_rc=$?
    if [ "${_lta_rc}" -eq 0 ]; then LEASE_ERR=""; return 0; fi
    case "${LEASE_ERR}" in
        *AlreadyExists*|*"already exists"*) ;;
        *) return 2 ;;
    esac
    # Held. ONE read, not three: separate `kubectl get`s could observe three generations of the
    # object, so the holder reported would not be the holder whose renewTime was judged. The
    # resourceVersion read here is what makes the takeover below exclusive.
    _lta_state=$(kubectl get lease "${_lta_n}" -n "${NAMESPACE}" \
        -o jsonpath='{.metadata.resourceVersion}{"\t"}{.spec.holderIdentity}{"\t"}{.spec.renewTime}{"\t"}{.spec.leaseDurationSeconds}' 2>/dev/null || true)
    _lta_rv=$(printf '%s' "${_lta_state}" | cut -f1)
    LEASE_HOLDER=$(printf '%s' "${_lta_state}" | cut -f2)
    LEASE_RENEW=$(printf '%s' "${_lta_state}" | cut -f3)
    _lta_dur=$(printf '%s' "${_lta_state}" | cut -f4)
    : "${_lta_dur:=${_lta_d}}"
    _lta_rc=0; lease_expired "${LEASE_RENEW}" "${_lta_dur}" || _lta_rc=$?
    if [ "${_lta_rc}" -ne 0 ]; then
        # 2 = cannot tell. A lock we cannot age must never be stolen.
        [ "${_lta_rc}" -eq 2 ] && LEASE_STATE=unknown || LEASE_STATE=live
        return 1
    fi
    if [ -z "${_lta_rv}" ]; then LEASE_STATE=norv; return 1; fi
    # `replace` with the OBSERVED resourceVersion is optimistic concurrency: exactly one writer
    # wins, the loser gets 409. `patch --type=merge` cannot express the precondition, so it
    # always won — two runs could both judge the lease expired, both "take over", and both go
    # on to write the same database.
    _lta_body=$(lease_manifest "${_lta_n}" "${_lta_d}" "${_lta_c}" "${_lta_rv}")
    LEASE_ERR=$(kubectl replace -f - -n "${NAMESPACE}" 2>&1 >/dev/null <<EOF
${_lta_body}
EOF
    ) || return 3
    LEASE_ERR=""
    return 0
}

acquire_component_lock() {
    local component="$1" lease rc=0
    lease=$(lease_name "$1")
    lease_try_acquire "${lease}" "${LOCK_LEASE_SECONDS}" "${component}" || rc=$?
    case "${rc}" in
        0)  if [ -n "${LEASE_HOLDER}" ]; then
                log "WARN" "Took over the expired ${component} lock (was held by '${LEASE_HOLDER}', last renewed ${LEASE_RENEW:-never})"
            else
                log "INFO" "Acquired ${component} lock (lease ${lease}, holder ${LOCK_HOLDER})"
            fi
            return 0 ;;
        2)  # RBAC, an unreachable apiserver — NOT "the lock is free".
            log "ERROR" "Cannot acquire the ${component} lock: ${LEASE_ERR}"
            log "ERROR" "  The backup ServiceAccount needs get/list/create/update/patch/delete on coordination.k8s.io/leases." ;;
        3)  log "ERROR" "Lost the race to take over the ${component} lock (someone else took it, or its holder renewed it, after we read it)" ;;
        *)  case "${LEASE_STATE}" in
                unknown) log "ERROR" "The ${component} lock is held by '${LEASE_HOLDER:-unknown}' and its expiry could not be determined (renewTime '${LEASE_RENEW:-none}'); refusing to steal it" ;;
                norv)    log "ERROR" "The ${component} lock is held by '${LEASE_HOLDER:-unknown}' and looks expired, but its resourceVersion could not be read; refusing an unguarded takeover" ;;
                *)       log "ERROR" "Another backup/restore holds the ${component} lock (holder: ${LEASE_HOLDER:-unknown}, renewed ${LEASE_RENEW:-never}); aborting" ;;
            esac ;;
    esac
    exit 1
}

release_component_lock() {
    local lease; lease=$(lease_name "$1")
    # Only the owner may release: the EXIT trap is installed before acquire_locks, so a run that
    # aborted BECAUSE someone else holds the lock must not delete that live lock.
    local holder
    holder=$(kubectl get lease "${lease}" -n "${NAMESPACE}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
    if [ "${holder}" = "${LOCK_HOLDER}" ]; then
        kubectl delete lease "${lease}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    fi
    return 0
}

# Keep every held lease fresh while the operation runs, or a long backup outlives its own lease
# and another run legitimately takes it over mid-flight.
#
# The renewer MUST NOT outlive the orchestrator. cron-backup.sh detaches this script with setsid
# inside a long-lived pod, so a SIGKILL never runs the EXIT trap — and a renewer left behind kept
# the leases alive for the life of the POD, wedging every later backup and restore until someone
# deleted the Leases by hand. Two independent guards, because this takes the whole schedule out:
#   1. the parent-liveness check below, which is what normally stops it;
#   2. LOCK_RENEWER_MAX_SECONDS, a backstop for a parent PID recycled by an unrelated process.
LOCK_RENEWER_MAX_SECONDS="${LOCK_RENEWER_MAX_SECONDS:-86400}"
# `|0` like every other clamp: 0 makes the renewer's `[ elapsed -ge 0 ]` true on its first turn,
# so it exits immediately and the component Leases age out while the run is still writing.
numeric_env LOCK_RENEWER_MAX_SECONDS 86400

start_lock_renewer() {
    [ -n "${LOCK_COMPONENTS}" ] || return 0
    # Captured OUT here: `$$` inside the subshell still expands to the invoking shell's pid in
    # POSIX sh, so reading it inside would not identify the parent on every shell.
    local _lr_parent=$$
    (
        trap - EXIT INT TERM
        _lr_elapsed=0
        while :; do
            sleep "${LOCK_RENEW_SECONDS}"
            _lr_elapsed=$((_lr_elapsed + LOCK_RENEW_SECONDS))
            # The orchestrator is gone: stop renewing so the leases age out and the next run
            # can take them over. Doing nothing here is what wedged the schedule.
            kill -0 "${_lr_parent}" 2>/dev/null || exit 0
            if [ "${_lr_elapsed}" -ge "${LOCK_RENEWER_MAX_SECONDS}" ]; then
                exit 0
            fi
            for _rc in ${LOCK_COMPONENTS}; do
                kubectl patch lease "$(lease_name "${_rc}")" -n "${NAMESPACE}" --type=merge \
                    -p "{\"spec\":{\"renewTime\":\"$(lease_now)\"}}" >/dev/null 2>&1 || true
            done
        done
    # Every inherited write end of the caller's stdout is dropped here — stdout, stderr AND
    # fd 9 (the duplicate opened at the top of this file). Not cosmetic: the renewer emits
    # nothing, but stop_lock_renewer's `kill` reaches the SUBSHELL, not the `sleep` it is
    # blocked in, and that orphaned `sleep` inherits these descriptors. It kept the caller's
    # stdout open, so `pmm-backup.sh ... | tee` (or a piped `kubectl exec`) appeared to hang for
    # up to ${LOCK_RENEW_SECONDS} AFTER the run had printed its summary and exited. Closing
    # only 1 and 2 is not enough — fd 9 alone holds the pipe.
    ) >/dev/null 2>&1 9>&- &
    LOCK_RENEWER_PID=$!
    return 0
}

stop_lock_renewer() {
    [ -n "${LOCK_RENEWER_PID}" ] || return 0
    kill "${LOCK_RENEWER_PID}" 2>/dev/null || true
    LOCK_RENEWER_PID=""
    return 0
}

# The components an operation must lock, from the selection variable in <column> (4 = backup,
# 5 = restore).
#
# LOCK_ORDER is ALPHABETICAL and that is load-bearing, not tidiness: two runs locking
# overlapping sets must take them in the SAME order or they deadlock on each other. It is
# spelled out here rather than reusing CORE_COMPONENTS, which is in pipeline order.
# The encryption key is deliberately absent — it is a Secret, not a database, and no two runs
# contend for it.
LOCK_ORDER="clickhouse pmm-server postgresql victoriametrics"

# The selected components' human labels, space-prefixed, for one summary line.
selected_labels() {
    _sl_c="" _sl_out=""
    for _sl_c in ${CORE_COMPONENTS}; do
        comp_on "${_sl_c}" "$1" && _sl_out="${_sl_out} $(comp_label "${_sl_c}")"
    done
    printf '%s' "${_sl_out}"
}
lock_list() {
    _ll_c="" _ll_out=""
    for _ll_c in ${LOCK_ORDER}; do
        comp_on "${_ll_c}" "$1" && _ll_out="${_ll_out} ${_ll_c}"
    done
    printf '%s' "${_ll_out}"
}

# Acquire/release every lock in LOCK_COMPONENTS. Each operation builds its own list — in
# alphabetical order, to prevent deadlocks between concurrent runs — before calling these.
acquire_locks() {
    local _c
    for _c in ${LOCK_COMPONENTS}; do acquire_component_lock "${_c}"; done
    start_lock_renewer
    return 0
}

release_locks() {
    local _c
    catalog_cache_clear
    stop_lock_renewer
    for _c in ${LOCK_COMPONENTS}; do release_component_lock "${_c}"; done
    return 0
}

################################################################################
# 6. Catalog — manifest write/read, id ownership/age, list
################################################################################

# Which namespace produced a backup, read from its own manifest, or empty when that cannot be
# established. Ownership is a fact recorded in the data, not inferred from configuration:
# installs can legitimately share a prefix, and age-based pruning cannot tell whose backup an
# id is. See DN-08.
backup_id_owner() {
    # Via catalog_manifest, not store_read: it is the same object the chain pass and the purge
    # loop read, so sharing the cache turns three fetches per candidate into one.
    _bio_json=$(catalog_manifest "$1") || return 1
    [ -n "${_bio_json}" ] || return 1
    printf '%s' "${_bio_json}" | jq -r '.namespace // empty' 2>/dev/null
}

# Epoch seconds for the timestamp embedded in a backup id (backup_YYYYMMDD-HHMMSS), or
# non-zero when it cannot be parsed. Callers must then SKIP the id rather than guess.
#
# The shape is anchored before any conversion, and the result is shape-checked before it is
# ever compared. Both matter, and both are load-bearing for retention — see DN-07.
#
# The id is UTC (TIMESTAMP is generated with `date -u`), so it is converted as UTC — via
# epoch_utc rather than `date`, which has no portable way to parse a string as UTC and does
# not accept either -D or -d at all on BSD/macOS.
backup_id_epoch() {
    _bid_ts="${1#backup_}"
    case "${_bid_ts}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    _bid_f=$(printf '%s' "${_bid_ts}" | sed 's/^\(....\)\(..\)\(..\)-\(..\)\(..\)\(..\)$/\1 \2 \3 \4 \5 \6/')
    # shellcheck disable=SC2086
    set -- ${_bid_f}
    epoch_utc "$1" "$2" "$3" "$4" "$5" "$6"
}

# Build the per-run manifest and write it (+ a 'latest' pointer) next to the PMM/VM data.
# Best-effort: never aborts the run. $1=overall status (complete|partial), $2=encryption status.
# Release the merge lease if this run holds it. Four identical copies of this line sat on
# write_manifest's four exit paths, which is how one comes to be forgotten on a new one.
manifest_release_lease() {   # <held true|false> <lease-name>
    [ "$1" = "true" ] || return 0
    kubectl delete lease "$2" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    return 0
}

# Merge this run's manifest with whatever is already at manifests/<id>.json, so the documented
# concurrent workflow (one process per component, one shared --backup-id) does not have its
# last finisher erase the siblings from the restore index (DN-13).
#
# The result comes back in MANIFEST_MERGED rather than on stdout, because this function LOGS and
# log() writes to stdout — printing the JSON there would interleave the two.
# rc 1 = refuse to write; the caller reports the component failed with its data still uploaded.
MANIFEST_MERGED=""
manifest_merge_existing() {   # <new-manifest-json> <lease-held> <lease-name>
    _mme_new="$1" _mme_held="$2" _mme_lease="$3" _mme_existing="" _mme_rc=0 _mme_merged=""
    MANIFEST_MERGED="${_mme_new}"

    # The read's STATUS decides what an empty result means. `|| true` conflated "could not read
    # it" with "there is no manifest yet", so one timed-out rclone cat made the last finisher
    # overwrite the shared manifest with only its own component. A failed read is forgiven only
    # when absence is POSITIVELY established — the same rule the delete path uses.
    _mme_existing=$(store_read "$(manifest_path)" 2>/dev/null) || _mme_rc=$?
    if [ "${_mme_rc}" -ne 0 ]; then
        if store_absent "$(manifest_path)"; then
            _mme_existing=""   # genuinely not there yet: this is the first writer for this id
        else
            log "ERROR" "[Manifest] Could not read the existing $(manifest_display) (rc ${_mme_rc}), and could not prove it is absent"
            log "ERROR" "[Manifest]   Refusing to overwrite it: a concurrent component run's entries would be erased from the restore index."
            manifest_release_lease "${_mme_held}" "${_mme_lease}"
            return 1
        fi
    fi
    [ -n "${_mme_existing}" ] || return 0

    # Two DIFFERENT failures used to collapse into one empty result: --argjson rejecting content
    # that is not JSON at all, and the filter erroring on content that IS valid JSON but shaped
    # unexpectedly (a .components that is a string, component values that are not objects). Both
    # took the "not valid JSON; overwriting it" arm — which in the concurrent workflow erases a
    # sibling's entry — and told the operator the wrong cause. Establish which it is first.
    if ! printf '%s' "${_mme_existing}" | jq -e . >/dev/null 2>&1; then
        log "WARN" "[Manifest] The existing $(manifest_display) is not valid JSON; overwriting it"
        return 0
    fi
    # Existing components lose to this run's on conflict; any failed component in the merged set
    # makes the whole backup partial.
    _mme_merged=$(jq -n --argjson new "${_mme_new}" --argjson old "${_mme_existing}" '
        $new
        | .components = (($old.components // {}) + $new.components)
        | .status = (if $new.status == "partial"
                        or ([.components[] | .status // ""] | index("failed"))
                     then "partial" else "complete" end)' 2>/dev/null || true)
    if [ -n "${_mme_merged}" ]; then
        [ "${_mme_merged}" != "${_mme_new}" ] && log "INFO" "[Manifest] Merged component entries from a concurrent run of this backup id"
        MANIFEST_MERGED="${_mme_merged}"
        return 0
    fi
    # Valid JSON the merge could not process. Overwriting would drop whatever components it
    # holds. Same scoping rule as the lease refusal: only a run sharing an explicit --backup-id
    # can have a SIBLING whose entries an overwrite would erase. A solo run owns an id nobody
    # else is writing, so what is there is a leftover from an earlier attempt at the same id —
    # refusing there would strand a backup whose data is already uploaded.
    if [ -n "${BACKUP_ID}" ]; then
        log "ERROR" "[Manifest] The existing $(manifest_display) is valid JSON but could not be merged"
        log "ERROR" "[Manifest]   (unexpected shape — .components is expected to be an object of objects),"
        log "ERROR" "[Manifest]   and this run shares backup id '${BACKUP_ID}' with other component runs."
        log "ERROR" "[Manifest]   Refusing to overwrite it: that would erase whichever components it does list."
        manifest_release_lease "${_mme_held}" "${_mme_lease}"
        return 1
    fi
    log "WARN" "[Manifest] The existing $(manifest_display) is valid JSON but could not be merged (unexpected shape); overwriting it"
    log "WARN" "[Manifest]   Safe here: this run's id is its own, so nothing else is writing that object."
    return 0
}

write_manifest() {
    _overall="$1"
    _enc_status="${2:-skipped}"
    _created=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # The components object is simply this run's results — every component that ran wrote its
    # own entry (DN-38), so there is nothing to re-derive.
    #
    # The encryption key is the exception: backup_encryption_key calls result_set only on
    # SUCCESS, so a failed or unconfigured export leaves no entry — making a backup whose key
    # export FAILED indistinguishable in the index from one taken where encryption is not
    # configured at all, and losing the only signal that this run's dumps will not decrypt
    # after a DR. ${_enc_status} is that outcome.
    _comps="${RESULTS_JSON}"
    case "${_enc_status}" in
        skipped) ;;   # --skip-encryption-key or PG not selected: genuinely nothing to record
        *)
            if [ "$(printf '%s' "${_comps}" | jq -r 'has("encryption")' 2>/dev/null || echo true)" != "true" ]; then
                _comps=$(printf '%s' "${_comps}" \
                    | jq --arg s "${_enc_status}" '. + {encryption: {status: $s}}' 2>/dev/null) \
                    || _comps="${RESULTS_JSON}"
                [ -n "${_comps}" ] || _comps="${RESULTS_JSON}"
            fi ;;
    esac

    # This run's own manifest (merge with any concurrent run's happens below, under lock).
    # Guarded like every other jq call in this file: a bare assignment returns jq's status, and
    # in any call context where errexit is not suppressed that ends the run HERE — after every
    # component has uploaded and before the index exists, which is the orphaned-backup failure
    # this whole file is arranged to prevent. Today's `if ! write_manifest` call site happens to
    # suppress errexit, so this is a latch on a door that is currently shut.
    _manifest=$(jq -n \
        --argjson schema "${MANIFEST_SCHEMA}" \
        --arg backup_id "$(backup_id_default)" --arg ts "${TIMESTAMP}" --arg created "${_created}" \
        --arg ns "${NAMESPACE}" --arg target "${BACKUP_TARGET}" --arg bucket "${S3_BUCKET}" \
        --arg prefix "${S3_PREFIX}" --arg status "${_overall}" --argjson comps "${_comps}" \
        '{schema: $schema,
          backup_id: $backup_id, timestamp: $ts, created: $created, namespace: $ns,
          target: $target, bucket: $bucket, prefix: $prefix, status: $status,
          consistency: "per-component",
          consistency_note: "Each component is captured independently, at a different moment, and in the documented concurrent workflow by a different process. There is NO cluster-wide point-in-time: components are individually consistent, not consistent with each other. Sizing an RPO from this must use the id timestamp plus the run duration.",
          components: $comps}' 2>/dev/null) || _manifest=""
    if [ -z "${_manifest}" ]; then
        log "ERROR" "[Manifest] Could not BUILD the manifest for this run (jq failed on the component results)."
        log "ERROR" "[Manifest]   The component data is in the bucket but has no index: it is invisible to 'list',"
        log "ERROR" "[Manifest]   unresolvable by restore and unreclaimed by retention. Treating the run as failed."
        return 1
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[Manifest] [DRY RUN] Would write $(manifest_display) (+ latest pointer)"
        return 0
    fi

    # Concurrent-mode merge: with --backup-id, one process per component writes the SAME
    # manifests/<id>.json, and without a merge the last finisher erases the others from the
    # index (DN-13). Serialised with a Lease, not a local lock — the writers are separate
    # PROCESSES that do not necessarily share a filesystem (a laptop and the pod do not).
    #
    # Best effort with a bound: if the lease cannot be taken in the window the write goes ahead
    # unmerged rather than failing a backup whose data is already uploaded. What actually
    # protects a sibling's entries is the positively-established-absence check below.
    _mlease=$(lease_name "manifest-${TIMESTAMP}")
    _mlock_held=false
    _mlock_blocked=false   # a permanent condition was reported and already logged
    _i=0
    while [ ${_i} -lt 60 ]; do
        # Same primitive the component locks use, so the merge lease cannot drift away from it.
        # A permanent condition (missing RBAC on leases, an unreachable apiserver, a name the
        # apiserver rejects) is reported and gives up immediately: swallowing it made every
        # concurrent component run sleep out the full 60s and then write the shared manifest
        # with no merge protection and nothing in the log to say why.
        _mlock_rc=0
        lease_try_acquire "${_mlease}" 120 || _mlock_rc=$?
        if [ "${_mlock_rc}" -eq 0 ]; then _mlock_held=true; break; fi
        if [ "${_mlock_rc}" -eq 2 ]; then
            log "WARN" "[Manifest] Cannot take the merge lease '${_mlease}': ${LEASE_ERR}"
            log "WARN" "[Manifest]   Retrying for 60s would not change this, so the manifest is written WITHOUT merge protection."
            log "WARN" "[Manifest]   The backup ServiceAccount needs get/create/update/patch/delete on coordination.k8s.io/leases."
            _mlock_blocked=true; break
        fi
        _i=$((_i + 1))
        sleep 1
    done
    if [ "${_mlock_held}" != "true" ] && [ "${_mlock_blocked}" != "true" ]; then
        log "WARN" "[Manifest] Merge lease busy for 60s; writing without merge protection"
    fi

    # Refuse only where the race is REAL. It needs a sibling, and a sibling only exists when an
    # explicit --backup-id is shared. A run with an auto-generated id owns a timestamp nobody
    # else is writing, so an unmerged write there is safe and must stay allowed — failing it
    # would turn every ordinary backup into an orphan with no index whenever the apiserver is
    # unreachable, which is what usually costs us the lease. (DN-13)
    if [ "${_mlock_held}" != "true" ] && [ -n "${BACKUP_ID}" ]; then
        log "ERROR" "[Manifest] Could not take the merge lease, and this run shares backup id '${BACKUP_ID}' with other component runs."
        log "ERROR" "[Manifest]   Writing the manifest unmerged could erase a sibling component's entry from the restore index,"
        log "ERROR" "[Manifest]   so this component is reported FAILED instead. Its data IS uploaded; re-run just this component"
        log "ERROR" "[Manifest]   once the lease is available (check RBAC on coordination.k8s.io/leases and the apiserver)."
        return 1
    fi

    manifest_merge_existing "${_manifest}" "${_mlock_held}" "${_mlease}" || return 1
    _manifest="${MANIFEST_MERGED}"

    # 'latest' is the DR pointer: restore's --backup-id latest follows it blindly, so only a
    # COMPLETE, FULL-SCOPE backup (all four core components succeeded, judged on the MERGED
    # manifest) may move it. A single-component run (e.g. an ad-hoc ClickHouse incremental)
    # must not — restoring 'latest' would then silently restore just that one component.
    _move_latest=$(printf '%s\n' "${_manifest}" | jq -r '
        (.status == "complete") and (.components
            | has("postgresql") and has("clickhouse")
              and has("victoriametrics") and has("pmm-server"))' 2>/dev/null || echo false)

    # One path for both targets: store_write knows how to reach either, and creates the
    # parent directory itself when that target is a filesystem.
    if printf '%s\n' "${_manifest}" | store_write "$(manifest_path)"; then
        log "INFO" "[Manifest] Wrote $(manifest_display)"
        if [ "${_move_latest}" != "true" ]; then
            log "INFO" "[Manifest] latest pointer NOT moved (run is not a complete full-scope backup)"
        elif printf '%s\n' "backup_${TIMESTAMP}" | store_write "$(latest_path)"; then
            log "INFO" "[Manifest] Updated latest -> backup_${TIMESTAMP}"
        else
            log "WARN" "[Manifest] Could not update latest pointer"
        fi
    else
        # Hard failure, not a warning: the manifest IS the restore index. Component data with
        # no manifests/<id>.json is invisible to `list`, unresolvable by restore and unseen by
        # retention — cmd_backup treats a non-zero return here as a failed backup.
        log "ERROR" "[Manifest] Failed to write the manifest to $(manifest_display)"
        manifest_release_lease "${_mlock_held}" "${_mlease}"
        return 1
    fi
    manifest_release_lease "${_mlock_held}" "${_mlease}"
    return 0
}

# Render a manifest.json (on stdin) as a clean per-component summary: each component's
# status + where it lives + (for PG/CH) the restore command. Surfaces PostgreSQL and
# every component from the manifest, all of which now share one <component>/<id>/ shape.
print_manifest_summary() {
    jq -r '
        .components | to_entries[]
        | .key as $c | .value as $v
        | ( [ $c, ($v.status // "?"),
              (if $c == "postgresql" and ($v.databases // "") != ""
                 then "db: " + $v.databases + (if ($v.location // "") != "" then "  " + $v.location else "" end)
               elif (($v.objects // []) | length) > 0
                 then (($v.objects | length | tostring) + " object(s)" + (if ($v.location // "") != "" then "  " + $v.location else "" end))
               elif ($v.location // "") != "" then $v.location
               elif ($v.name // "") != "" then $v.name
               else "" end) ] | @tsv ),
          ( if ($v.restore // "") != "" then (["", "", "restore: " + $v.restore] | @tsv) else empty end )
    ' 2>/dev/null | awk -F'\t' '{ printf "  %-16s %-9s %s\n", $1, $2, $3 }'
}

# Extract a top-level scalar string field from a manifest on stdin.
manifest_field() {
    jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

# Top-level scalar field of the LOADED manifest (restore path) — same accessor as
# manifest_field, pointed at ${MANIFEST_FILE}.
manifest_top() { manifest_field "$1" < "${MANIFEST_FILE}"; }

# Component nested scalar field of the loaded manifest: mf_field <component> <key>
mf_field() { jq -r --arg c "$1" --arg k "$2" '.components[$c][$k] // empty' "${MANIFEST_FILE}" 2>/dev/null; }

# Resolve BACKUP_ID (incl. 'latest') -> BACKUP_NAME, fetch + parse manifest.json.
load_manifest() {
    if [ -z "${BACKUP_ID}" ]; then
        log "ERROR" "Missing --backup-id (e.g. 20260610-124515 or 'latest')"
        return 1
    fi
    local id="${BACKUP_ID}"
    if [ "${id}" = "latest" ]; then
        id=$(catalog_latest || true)
        if [ -z "${id}" ]; then log "ERROR" "Could not resolve 'latest' pointer (target=${BACKUP_TARGET})"; return 1; fi
        log "INFO" "Resolved 'latest' -> ${id}"
    fi
    # Same charset as --backup-id, applied AFTER resolution because 'latest' makes this id
    # bucket-controlled rather than operator-controlled: it is read from an object any
    # writer to the prefix can create, and it flows into single-quoted `sh -c` strings run
    # inside the ClickHouse pod and a root-privileged temp pod. Refuse rather than
    # interpolate.
    case "${id}" in
        *[!A-Za-z0-9_-]*)
            log "ERROR" "Refusing backup id '${id}': allowed characters are A-Z a-z 0-9 _ - (resolved from ${BACKUP_ID})"
            return 1 ;;
    esac
    case "${id}" in backup_*) BACKUP_NAME="${id}" ;; *) BACKUP_NAME="backup_${id}" ;; esac
    # The id is now known: every path builder from here on resolves against it.
    CURRENT_ID="${BACKUP_NAME}"

    MANIFEST_FILE=$(mktemp /tmp/restore_manifest.XXXXXX 2>/dev/null || echo "/tmp/restore_manifest.$$")
    store_read "$(manifest_path)" > "${MANIFEST_FILE}" 2>/dev/null || true
    if [ ! -s "${MANIFEST_FILE}" ]; then
        log "ERROR" "No manifest for ${BACKUP_NAME} (target=${BACKUP_TARGET})."
        [ "${S3_ENABLED}" = "true" ] && log "ERROR" "  Looked at $(manifest_display) (check --s3-bucket/--s3-prefix and this pod's S3 credentials)"
        [ "${S3_ENABLED}" = "true" ] || log "ERROR" "  Looked at $(manifest_path)"
        return 1
    fi

    # A corrupt/truncated manifest must be a hard error, not a fleet of silently-empty
    # MF_* fields that read as "nothing to restore".
    if ! jq -e . "${MANIFEST_FILE}" >/dev/null 2>&1; then
        log "ERROR" "Manifest for ${BACKUP_NAME} is not valid JSON (corrupt or truncated); refusing to plan a restore from it"
        return 1
    fi

    # A manifest from a NEWER writer may place data where this version cannot look, or attach a
    # meaning to a field this version reads differently — and a restore acts on what it reads
    # while PMM is scaled to 0. Refuse, and say which version is needed: upgrading the chart is
    # a cheap fix, a restore that silently skipped a component is not. See DN-41.
    local _mf_schema=""
    _mf_schema=$(manifest_schema_of < "${MANIFEST_FILE}") || _mf_schema=""
    if [ -z "${_mf_schema}" ]; then
        log "ERROR" "Manifest for ${BACKUP_NAME} declares an unreadable 'schema'; refusing to plan a restore from a format this version cannot confirm it understands"
        return 1
    fi
    if [ "${_mf_schema}" -gt "${MANIFEST_SCHEMA}" ]; then
        log "ERROR" "Manifest for ${BACKUP_NAME} is schema v${_mf_schema}; this pmm-backup.sh understands v${MANIFEST_SCHEMA}."
        log "ERROR" "  It was written by a newer chart release. Restore it with that release's pmm-backup.sh —"
        log "ERROR" "  this one could misread where a component's data lives and report a partial restore as complete."
        return 1
    fi

    MF_STATUS=$(manifest_top status); MF_TARGET=$(manifest_top target); MF_CREATED=$(manifest_top created)
    MF_PG_STATUS=$(mf_field postgresql status); MF_PG_DBS=$(mf_field postgresql databases)
    MF_CH_STATUS=$(mf_field clickhouse status);      MF_CH_NAME=$(mf_field clickhouse name)
    MF_CH_S3_BUCKET=$(mf_field clickhouse s3_bucket); MF_CH_S3_PATH=$(mf_field clickhouse s3_path)
    MF_VM_STATUS=$(mf_field victoriametrics status)
    MF_PMM_STATUS=$(mf_field pmm-server status)
    MF_ENC_STATUS=$(mf_field encryption status)

    # The ClickHouse backup name is manifest-controlled and reaches `sh -c` inside the CH pod
    # (shared-mode untar + restore), so it gets the same treatment as the id. Dots are
    # allowed because clickhouse-backup names may carry them; empty is legitimate (no
    # ClickHouse in this backup) and is caught later by the per-component checks.
    if [ -n "${MF_CH_NAME}" ]; then
        case "${MF_CH_NAME}" in
            *[!A-Za-z0-9_.-]*)
                log "ERROR" "Manifest records an unusable ClickHouse backup name '${MF_CH_NAME}' (allowed: A-Z a-z 0-9 _ . -); refusing to plan a restore from it"
                return 1 ;;
        esac
    fi

    # Database names are stored space-JOINED and word-SPLIT again by the pre-flight and the
    # restore, so this field cannot express a name that contains whitespace: a separator space
    # and an in-name space are the same byte. This gate therefore checks only what it can —
    # that no OTHER unexpected character is present — and the whitespace case is prevented at
    # the source instead, in backup_postgresql, which refuses to create a backup it could not
    # address on the way back. Do not extend the message to claim more than this checks.
    if [ -n "${MF_PG_DBS}" ]; then
        case "${MF_PG_DBS}" in
            *[!A-Za-z0-9_.\ -]*)
                log "ERROR" "Manifest records unusable PostgreSQL database name(s) '${MF_PG_DBS}'"
                log "ERROR" "  Allowed: A-Z a-z 0-9 _ . - plus the spaces that separate names."
                log "ERROR" "  Restore the dumps by hand with pg_restore against ${BACKUP_NAME}'s postgresql/ prefix."
                return 1 ;;
        esac
    fi

    log "INFO" "Backup ${BACKUP_NAME}: status=${MF_STATUS:-?} target=${MF_TARGET:-?} created=${MF_CREATED:-?}"
    if [ -n "${MF_TARGET}" ] && [ "${MF_TARGET}" != "${BACKUP_TARGET}" ]; then
        log "WARN" "Manifest target '${MF_TARGET}' != --target '${BACKUP_TARGET}'. Restore uses --target ${BACKUP_TARGET}; pass --target ${MF_TARGET} if that's wrong."
    fi
    return 0
}

# 'list' command: enumerate backups, or show one backup's per-component summary + files.
cmd_list() {
    _want="${1:-}"
    ensure_jq || { echo "Error: jq is required for 'list' but is not on PATH (the chart's backup-tools container installs it at start-up: kubectl logs deploy/<release>-backup-tools)"; exit 1; }
    # (--target s3 without a bucket is already rejected for every subcommand at dispatch.)

    # Accept a bare timestamp as well as backup_<timestamp>, exactly as --backup-id does on
    # the restore path. Without this the two subcommands disagreed about what a backup id
    # is: `restore --backup-id 20260610-124515` worked while `list 20260610-124515` said
    # there was no such backup.
    case "${_want}" in
        ''|backup_*) ;;
        *) _want="backup_${_want}" ;;
    esac

    # ONE implementation for both targets: same catalog, same output, the read helpers absorb
    # the difference in root. Two copies had already drifted into two different formats.
    if [ -z "${_want}" ]; then
        echo "Backups in $(backup_root_display)/"
        echo ""
        # || true: a missing/unreadable pointer must print the message below, not abort the
        # script. Under `set -eu` an unguarded assignment from a failing command exits.
        _latest=$(catalog_latest || true)
        # The catalog read's STATUS is kept, not discarded with `|| true`: "I could not look"
        # and "there is nothing here" must not print the same line. During an incident — S3
        # unreachable, sidecar evicted, IAM broken — a conflated message reads as data loss,
        # and this is the same distinction the storage layer's contract mandates for the
        # destructive paths. rc is captured, so `set -e` cannot abort here either.
        _ids_rc=0
        _ids=$(catalog_ids) || _ids_rc=$?
        if [ "${_ids_rc}" -ne 0 ]; then
            echo "  (could not READ the catalog at $(manifests_dir)/ — this is NOT the same as 'no backups')"
            echo "  Check --s3-bucket/--s3-prefix and this pod's S3 credentials (RCLONE_CONFIG_S3_* / AWS_* / the SA credential chain)."
            # Non-zero EXIT too, not just a non-zero message: a wrapper or monitoring probe
            # that gates on the status would otherwise read a total read failure as a
            # successful, empty catalog — the same conflation the storage contract forbids.
            return 2
        fi
        if [ -z "${_ids}" ]; then echo "  (none found — the catalog is readable and empty)"; return 0; fi
        printf '  %-30s %-9s %s\n' "BACKUP ID" "STATUS" "COMPONENTS"
        for _id in ${_ids}; do
            _mj=$(catalog_manifest "${_id}" || true)
            if [ -n "${_mj}" ]; then
                _st=$(printf '%s\n' "${_mj}" | jq -r '.status // "?"' 2>/dev/null || echo "?")
                _cs=$(printf '%s\n' "${_mj}" | jq -r '.components | keys_unsorted | join(",")' 2>/dev/null || echo "-")
                # Surface a manifest this version cannot fully read, rather than printing a row
                # that looks ordinary: restore will refuse this id and retention will defer it,
                # and an operator picking a backup during an incident needs to know that BEFORE
                # they try it. See DN-41.
                _sv=$(printf '%s\n' "${_mj}" | manifest_schema_of) || _sv=""
                if [ -z "${_sv}" ] || [ "${_sv}" -gt "${MANIFEST_SCHEMA}" ]; then
                    _st="v${_sv:-?}-too-new"
                fi
            else
                _st="no-manifest"; _cs="-"
            fi
            _mark=""; [ "${_id}" = "${_latest}" ] && _mark=" *latest"
            printf '  %-30s %-9s %s%s\n' "${_id}" "${_st:-?}" "${_cs:--}" "${_mark}"
        done
        echo ""
        echo "  * latest -> ${_latest:-<unset>}"
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            echo "  Inspect one:  $(basename "$0") list <BACKUP ID> --target s3 --s3-bucket ${S3_BUCKET} --s3-prefix ${S3_PREFIX}"
        else
            echo "  Inspect one:  $(basename "$0") list <BACKUP ID> --target shared --backup-dir ${BACKUP_DIR}"
        fi
    else
        _mj=$(catalog_manifest "${_want}" || true)
        if [ -z "${_mj}" ]; then
            echo "  (no manifest at $(manifest_display "${_want}"))"
            return 0
        fi
        echo "=== ${_want}  (status: $(echo "${_mj}" | manifest_field status), target: $(echo "${_mj}" | manifest_field target), $(echo "${_mj}" | manifest_field created)) ==="
        echo ""
        printf '  %-16s %-9s %s\n' "COMPONENT" "STATUS" "LOCATION / RESTORE"
        echo "${_mj}" | print_manifest_summary
        echo ""
        echo "  Component paths under $(backup_root_display)/:"
        for _c in ${BACKUP_COMPONENTS}; do
            _objs=$(store_list "$(comp_path "${_c}" "${_want}")" 2>/dev/null || true)
            if [ -n "${_objs}" ]; then
                printf '    %-16s %s\n' "${_c}/" "$(printf '%s' "${_objs}" | tr '\n' ' ')"
            else
                printf '    %-16s %s\n' "${_c}/" "(absent)"
            fi
        done
    fi
}

################################################################################
# 7. Backup — pre-flight + one function per component
################################################################################

preflight_checks() {   # <backup|restore|prune>
    local _pf_mode="${1:-backup}"
    log "INFO" "Running pre-flight checks..."
    # Reported here rather than at load time: these are clamped before log() exists (see
    # numeric_env), and a typo'd timeout that silently reverts to a default is exactly the kind
    # of thing an operator needs told.
    if [ -n "${NUMERIC_ENV_CLAMPED}" ]; then
        log "WARN" "Ignoring non-numeric setting(s), using defaults: ${NUMERIC_ENV_CLAMPED}"
    fi
    local checks_passed=true

    if ! command -v kubectl >/dev/null 2>&1; then
        log "ERROR" "kubectl is not installed or not in PATH"
        return 1
    fi

    if ! command -v timeout >/dev/null 2>&1; then
        log "ERROR" "timeout command is not available (install coreutils)"
        return 1
    fi

    if ! ensure_jq; then
        log "ERROR" "jq is required (manifest generation/merging + secret export) but is not on PATH"
        log "ERROR" "  The chart's backup-tools container installs it in its own start-up script, and its readinessProbe"
        log "ERROR" "  fails until it runs — so the reason is in the CONTAINER log, not in an init container's status:"
        log "ERROR" "    kubectl logs deploy/<release>-backup-tools -n ${NAMESPACE}"
        log "ERROR" "  In an air-gapped or egress-restricted cluster, point centralBackupStorage.tools.image at an"
        log "ERROR" "  image that already ships jq and rclone, or give the pod an Alpine repository mirror."
        return 1
    fi

    # In s3 mode rclone is how this process reaches the bucket at all: the catalog, the
    # manifest, the 'latest' pointer and every retention delete go through it. Fail here,
    # loudly, rather than at the first store_* call halfway through an operation.
    if [ "${S3_ENABLED}" = "true" ] && ! ensure_rclone; then
        log "ERROR" "rclone is required for --target s3 but is not on PATH"
        log "ERROR" "  The chart's backup-tools container installs it in its own start-up script, and its readinessProbe"
        log "ERROR" "  fails until it runs — so the reason is in the CONTAINER log, not in an init container's status:"
        log "ERROR" "    kubectl logs deploy/<release>-backup-tools -n ${NAMESPACE}"
        log "ERROR" "  In an air-gapped or egress-restricted cluster, point centralBackupStorage.tools.image at an"
        log "ERROR" "  image that already ships jq and rclone, or give the pod an Alpine repository mirror."
        return 1
    fi

    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log "ERROR" "Cannot reach cluster or namespace '${NAMESPACE}' does not exist"
        log "ERROR" "Check your kubeconfig/KUBECONFIG or ServiceAccount permissions"
        return 1
    fi

    # Per-component pod discovery warnings are a backup-side concern: restore has
    # its own fail-closed validate_restore_targets gate, which checks far more
    # than discovery and errors instead of warning. Taken as an ARGUMENT rather than read
    # from ${COMMAND}: the caller already knows which operation it is, and a shared helper
    # reaching for the dispatcher's global is how mode leaks back into the lower layers.
    if [ "${_pf_mode}" = "backup" ]; then
        local _pf_c="" _pf_sel=""
        for _pf_c in ${CORE_COMPONENTS}; do
            comp_on "${_pf_c}" 4 || continue
            _pf_sel=$(comp_pod_selector "${_pf_c}") || continue
            if ! kubectl get pods -n "${NAMESPACE}" -l "${_pf_sel}" --no-headers 2>/dev/null | grep -q .; then
                log "WARN" "[$(comp_label "${_pf_c}")] No pods found (label: ${_pf_sel})"
                checks_passed=false
            fi
        done
    fi

    if [ "${checks_passed}" = "true" ]; then
        log "INFO" "Pre-flight checks passed"
    else
        log "WARN" "Some pre-flight checks failed; backup will proceed but may have failures"
    fi
    return 0
}

################################################################################
# PostgreSQL Backup - logical dump (pg_dump). One portable custom-format file per
# database under postgresql/<id>/, alongside the other components. No
# pgBackRest repo / stanza / operator CR — restores into any namespace with
# pg_restore. (The operator keeps its own local repo1 for replica/HA; we don't use it.)
################################################################################

backup_postgresql() {
    log "INFO" "[PostgreSQL] === Starting Backup (pg_dump) ==="
    local start_time=$(date +%s)

    local pg_pod
    pg_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PG_PRIMARY}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "${pg_pod}" ]; then
        log "ERROR" "[PostgreSQL] Primary pod not found (label: ${LABEL_PG_PRIMARY})"
        return 1
    fi

    # Application databases to dump: everything except templates and the empty 'postgres'
    # maintenance db. pg_dump uses local peer auth as the postgres superuser.
    local dbs
    dbs=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
        psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres';" 2>/dev/null | tr -d '\r')
    if [ -z "${dbs}" ]; then
        log "ERROR" "[PostgreSQL] No application databases found to dump"
        return 1
    fi
    # A name this pipeline cannot round-trip must not become a backup at all. The dump filename,
    # the space-joined `databases` manifest field, sizes_to_json's "<name>:<bytes>" pairs and the
    # restore's `for db in ${MF_PG_DBS}` all assume one name per word — so a database whose name
    # contains whitespace (or ':' , or anything outside the set below) would back up cleanly and
    # then be unrestorable, which is the worst possible time to find out. Refuse up front.
    # Checked one name PER LINE, not against the joined string: the whole point is to catch a
    # name that CONTAINS whitespace, and in a space-joined string that is indistinguishable from
    # a separator. Here-doc rather than a pipe so the result survives the loop.
    local _pgdb="" _pg_badname=""
    while IFS= read -r _pgdb; do
        [ -n "${_pgdb}" ] || continue
        case "${_pgdb}" in
            *[!A-Za-z0-9_.-]*) _pg_badname="${_pgdb}"; break ;;
        esac
    done <<EOF
${dbs}
EOF
    if [ -n "${_pg_badname}" ]; then
        log "ERROR" "[PostgreSQL] Database '${_pg_badname}' has a name this backup format cannot round-trip."
        log "ERROR" "[PostgreSQL]   Allowed: A-Z a-z 0-9 _ . - — no whitespace and no ':'. The manifest stores the"
        log "ERROR" "[PostgreSQL]   database list space-joined and the restore splits it again, and sizes_to_json"
        log "ERROR" "[PostgreSQL]   keys on '<name>:<bytes>', so this backup would restore to the wrong names or"
        log "ERROR" "[PostgreSQL]   not at all. Refusing now rather than at restore time. Dump it with pg_dump."
        return 1
    fi
    log "INFO" "[PostgreSQL] Databases: $(echo ${dbs} | tr '\n' ' ')"

    if [ "${DRY_RUN}" = "true" ]; then
        local db
        for db in ${dbs}; do
            log "INFO" "[PostgreSQL] [DRY RUN] pg_dump -Fc ${db} | store_write $(comp_display postgresql)/${db}.dump"
        done
        result_set postgresql --arg status "success" --arg engine "pg_dump" \
            --arg databases "$(echo ${dbs} | xargs)" --arg location "$(comp_location postgresql)/" \
            '{status: $status, engine: $engine, databases: $databases, location: $location,
              bytes: 0, duration: 0, files: {}}'
        return 0
    fi

    local total_bytes=0 ok_count=0 db_count=0 dumped="" db size_b pg_file_sizes=""
    for db in ${dbs}; do
        db_count=$((db_count + 1)); size_b=0
        local dump_dest="$(comp_path postgresql)/${db}.dump"
        log "INFO" "[PostgreSQL] Dumping ${db} -> $(comp_display postgresql)/${db}.dump..."
        # ONE arm for both targets: store_write, store_bytes and store_delete_object each reach
        # either. Two near-identical arms is the shape that lets a fix land on one target only.
        # pg_dump is the one payload that legitimately passes through this process — it cannot
        # write S3 and the PG pod has no rclone (DN-26).
        #
        # POSIX sh has no pipefail, so the if-condition only sees the writer's status: pg_dump's
        # exit is captured through an rc file so a dump that dies mid-stream cannot be masked by
        # a successful write of the truncated bytes.
        local dump_rc_file="/tmp/.pgdump_rc_$$" dump_rc
        rm -f "${dump_rc_file}" 2>/dev/null || true
        if { timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
                pg_dump -U postgres -Fc -d "${db}" 2>>"${LOG_FILE}"
             echo $? > "${dump_rc_file}"; } \
            | store_write "${dump_dest}" >>"${LOG_FILE}" 2>&1; then
            dump_rc=$(cat "${dump_rc_file}" 2>/dev/null || echo 1); rm -f "${dump_rc_file}" 2>/dev/null || true
            if [ "${dump_rc}" != "0" ]; then
                log "ERROR" "[PostgreSQL] pg_dump failed for ${db} (exit ${dump_rc}); removing the truncated object"
                store_delete_object "${dump_dest}" || true
                continue
            fi
            size_b=$(store_bytes "${dump_dest}" 2>/dev/null || echo 0)
        else
            rm -f "${dump_rc_file}" 2>/dev/null || true
            log "ERROR" "[PostgreSQL] Dump/write failed for ${db}"; continue
        fi
        : "${size_b:=0}"
        if ! [ "${size_b}" -gt 0 ] 2>/dev/null; then
            log "ERROR" "[PostgreSQL] ${db}: dump empty/missing at destination — treating as failed"; continue
        fi
        log "INFO" "[PostgreSQL] ✓ ${db} dumped ($(human_bytes ${size_b}))"
        total_bytes=$((total_bytes + size_b)); ok_count=$((ok_count + 1)); dumped="${dumped} ${db}"
        pg_file_sizes="${pg_file_sizes} ${db}:${size_b}"
    done

    if [ ${ok_count} -eq 0 ]; then log "ERROR" "[PostgreSQL] ✗ All database dumps failed"; return 1; fi

    # All-or-nothing: a partial dump set cannot restore the cluster, so only a full set counts
    # as success — consistent with the other components (DN-21). The function still returns 0 so
    # the remaining components run and get their summary.
    local pg_status="failed"
    if [ ${ok_count} -lt ${db_count} ]; then
        log "WARN" "[PostgreSQL] Partial: ${ok_count}/${db_count} databases dumped — marking failed (a backup must be complete to restore safely)"
    else
        pg_status="success"
    fi
    result_set postgresql \
        --arg status "${pg_status}" --arg engine "pg_dump" \
        --arg databases "$(echo ${dumped} | xargs)" \
        --arg location "$(comp_location postgresql)/" \
        --argjson bytes "${total_bytes}" \
        --argjson duration "$(($(date +%s) - start_time))" \
        --argjson files "$(sizes_to_json "${pg_file_sizes}")" \
        '{status: $status, engine: $engine, databases: $databases, location: $location,
          bytes: $bytes, duration: $duration, files: $files,
          restore: "(per db) pg_restore --clean --if-exists -U postgres -d <db> <db>.dump"}'
    [ "${pg_status}" = "success" ] && \
        log "INFO" "[PostgreSQL] ✓ Completed: ${ok_count} db(s), $(human_bytes ${total_bytes}), $(result_get postgresql duration)s"
    return 0
}

################################################################################
# ClickHouse Backup - Using clickhouse-backup API (system.backup_actions)
################################################################################

# ---- ClickHouse session state --------------------------------------------------------
# Resolved once per run and read by every ch_* helper below. Globals rather than a closure:
# ch_query used to be DEFINED INSIDE backup_clickhouse and capture its locals by dynamic
# scoping, so it outlived the call with stale expectations and could not be reached from
# anywhere else — which is why the restore path and the pre-flight gate each grew their own
# hand-rolled `kubectl exec` instead of calling it.
CH_POD=""
CH_USER=""
CH_PASS=""

# The pod that runs clickhouse-client and hosts the clickhouse-backup sidecar.
ch_resolve_pod() {
    CH_POD=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_CH_POD}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "${CH_POD}" ]; then
        log "ERROR" "[ClickHouse] No pods found in namespace: ${NAMESPACE}"
        log "ERROR" "[ClickHouse] Check that the operator is running: kubectl get pods -n ${NAMESPACE}"
        return 1
    fi
    log "INFO" "[ClickHouse] Using pod: ${CH_POD}"
    return 0
}

# Credentials from the secret. Fetch first, THEN decode: in a `kubectl | base64` pipeline the
# `||` fallback keys off base64's status (0 even on empty stdin), so a failed kubectl silently
# yielded "" instead of the intended default and was misdiagnosed as a missing sidecar.
# (Alpine's base64 takes -d, not --decode.)
ch_resolve_credentials() {
    _crc_u=$(kubectl get secret "${CH_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.PMM_CLICKHOUSE_USER}' 2>>"${LOG_FILE}" || true)
    _crc_p=$(kubectl get secret "${CH_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.PMM_CLICKHOUSE_PASSWORD}' 2>>"${LOG_FILE}" || true)
    if [ -n "${_crc_u}" ]; then
        CH_USER=$(printf '%s' "${_crc_u}" | base64 -d 2>/dev/null || echo "chuser")
    else
        log "WARN" "[ClickHouse] Could not read PMM_CLICKHOUSE_USER from secret ${CH_SECRET_NAME}; using default 'chuser'"
        CH_USER="chuser"
    fi
    if [ -n "${_crc_p}" ]; then
        CH_PASS=$(printf '%s' "${_crc_p}" | base64 -d 2>/dev/null || echo "")
    else
        log "WARN" "[ClickHouse] Could not read PMM_CLICKHOUSE_PASSWORD from secret ${CH_SECRET_NAME}; using empty password"
        CH_PASS=""
    fi
    return 0
}

# One query. The password goes through STDIN into CLICKHOUSE_PASSWORD inside the pod, never on
# the clickhouse-client argv, so it cannot leak through `ps` in the CH pod or the apiserver's
# exec audit log — this runs dozens of times per backup. The query text is not secret.
ch_query() {
    printf '%s' "${CH_PASS}" | timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${CH_POD}" -c clickhouse -- \
        sh -c 'CLICKHOUSE_PASSWORD=$(cat); export CLICKHOUSE_PASSWORD; exec clickhouse-client --user="$1" --query="$2"' sh "${CH_USER}" "$1"
}

# system.backup_actions exists only when the clickhouse-backup sidecar is running.
ch_has_backup_api() {
    # Split declaration from assignment: `local x=$(...)` takes $? from `local` (always 0) and
    # would mask the exec's real status.
    _chapi_out="" _chapi_rc=0
    _chapi_out=$(ch_query "SELECT count() FROM system.tables WHERE database='system' AND name='backup_actions'" 2>&1) || _chapi_rc=$?
    if [ "${VERBOSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Table check output: ${_chapi_out} (exit ${_chapi_rc})"
    fi
    if printf '%s' "${_chapi_out}" | grep -q "^1$"; then
        log "INFO" "[ClickHouse] clickhouse-backup API detected (system.backup_actions exists)"
        return 0
    fi
    log "ERROR" "[ClickHouse] clickhouse-backup API not available (system.backup_actions not found)"
    log "ERROR" "[ClickHouse] The clickhouse-backup sidecar container is not running."
    log "INFO"  "[ClickHouse] To enable it, add the sidecar to the ClickHouse pods in the Helm chart:"
    log "INFO"  "[ClickHouse]   https://github.com/Altinity/clickhouse-backup/blob/master/Examples.md#how-to-use-clickhouse-backup-in-kubernetes"
    return 1
}

# One field of the newest system.backup_actions row for <command>, restricted to rows started
# after <since>.  ch_action_field <field> <command> <since>
ch_action_field() {
    ch_query "SELECT $1 FROM system.backup_actions WHERE command='$2' AND toUnixTimestamp(start) > $3 ORDER BY start DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null
}

# Enqueue ONE clickhouse-backup action and wait for it; 'create' and 'upload' were one loop
# written twice (DN-46).
#
# The `since` fence is not optional: the command string is the poll key, and a rerun with the
# same --backup-id produces a byte-identical command — so without it the poll matches a stale
# 'success' row from the earlier attempt and reports success having created nothing.
#
#   ch_run_action <command> <timeout-seconds> <poll-interval> <what>
# Returns 0 on success; 1 on enqueue failure, a reported error, or timeout (all logged).
ch_run_action() {
    _cra_cmd="$1" _cra_to="$2" _cra_iv="$3" _cra_what="$4" _cra_since="" _cra_el=0 _cra_st=""
    _cra_since=$(ch_query "SELECT ifNull(toUnixTimestamp(max(start)),0) FROM system.backup_actions WHERE command='${_cra_cmd}' FORMAT TabSeparatedRaw" 2>/dev/null | tr -dc '0-9')
    [ -n "${_cra_since}" ] || _cra_since=0
    if ! ch_query "INSERT INTO system.backup_actions(command) VALUES('${_cra_cmd}')" >> "${LOG_FILE}" 2>&1; then
        log "ERROR" "[ClickHouse] Failed to enqueue ${_cra_what} (clickhouse-client exec failed)"
        return 1
    fi
    log "INFO" "[ClickHouse] Waiting for ${_cra_what} to complete..."
    while [ "${_cra_el}" -lt "${_cra_to}" ]; do
        _cra_st=$(ch_action_field status "${_cra_cmd}" "${_cra_since}")
        [ "${VERBOSE}" = "true" ] && log "INFO" "[ClickHouse] ${_cra_what} status: ${_cra_st}"
        case "${_cra_st}" in
            # This function owns the "Waiting for ..." line above, so it owns the matching
            # completion. Without it an upload that takes minutes ended with no marker at all —
            # the log went straight from "Waiting for S3 upload" to "Deleting the local backup".
            success) log "INFO" "[ClickHouse] ✓ ${_cra_what} completed"; return 0 ;;
            error)
                log "ERROR" "[ClickHouse] ${_cra_what} failed: $(ch_action_field error "${_cra_cmd}" "${_cra_since}")"
                return 1 ;;
        esac
        sleep "${_cra_iv}"
        _cra_el=$((_cra_el + _cra_iv))
    done
    log "ERROR" "[ClickHouse] ${_cra_what} timed out after ${_cra_to} seconds"
    return 1
}

# Where the upload will land. clickhouse-backup writes to the S3_BUCKET/S3_PATH baked into the
# sidecar's env, which this script does not control — so read it, and reconcile.
# Sets CH_WANT_PATH, CH_CFG_BUCKET and any --env overrides appended to CH_UPLOAD_EXTRA.
# See DN-11 and DN-12.
CH_CFG_BUCKET="" ; CH_WANT_PATH="" ; CH_UPLOAD_EXTRA=""
ch_resolve_destination() {
    CH_CFG_BUCKET=""; CH_UPLOAD_EXTRA=""
    CH_WANT_PATH=$(clickhouse_remote_key)
    [ "${S3_ENABLED}" = "true" ] || return 0
    _crd_path=""
    CH_CFG_BUCKET=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${CH_POD}" -c clickhouse-backup -- \
        printenv S3_BUCKET 2>/dev/null | tr -d '\r' || true)
    _crd_path=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${CH_POD}" -c clickhouse-backup -- \
        printenv S3_PATH 2>/dev/null | tr -d '\r' || true)
    if [ -z "${_crd_path}" ]; then
        # Cannot tell where it would write, so state the destination explicitly rather than
        # hoping the sidecar agrees.
        log "WARN" "[ClickHouse] Could not read the sidecar's S3_PATH; pinning the upload to ${CH_WANT_PATH}"
        CH_UPLOAD_EXTRA=" --env S3_BUCKET=${S3_BUCKET} --env S3_PATH=${CH_WANT_PATH}"
    elif [ "${CH_CFG_BUCKET}" = "${S3_BUCKET}" ] && [ "${_crd_path}" = "${CH_WANT_PATH}" ]; then
        :   # already writing where this run expects
    else
        # Either a deliberate per-component override or a pod that has not rolled since the
        # prefix changed, and this script cannot tell which — so honour the sidecar (never
        # silently discard configuration) and make the consequence explicit.
        log "WARN" "[ClickHouse] Sidecar writes to s3://${CH_CFG_BUCKET}/${_crd_path}, not this run's ${S3_BUCKET}/${CH_WANT_PATH}"
        log "WARN" "[ClickHouse]   Honouring the sidecar and RECORDING that destination in the manifest, so the restore reads it back from there."
        log "WARN" "[ClickHouse]   Retention only reclaims storage under this run's own root, so that prefix is NOT pruned by this tool — give it its own lifecycle policy. If instead the pods have simply not rolled since the prefix changed, re-run after they have."
        CH_WANT_PATH="${_crd_path}"
        CH_LOCATION_OVERRIDE="s3://${CH_CFG_BUCKET}/${_crd_path}"
    fi
    return 0
}

# The base an incremental should diff against: the newest REMOTE backup. location='remote' is
# required, not cosmetic — the base must exist in the remote, and system.backup_list also
# carries local-only rows (DN-10). Prints the name, or nothing for a full upload.
ch_incremental_base() {
    _cib=$(ch_query "SELECT name FROM system.backup_list WHERE name LIKE 'backup_%' AND location='remote' ORDER BY created DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || true)
    # Bucket-derived, so charset-gated like every other store-derived name (DN-17): this is
    # spliced UNQUOTED into the action string AND into the single-quoted SQL literal the sidecar
    # runs. A space is a legal S3 key character, so `backup_a --env S3_ENDPOINT=http://evil`
    # injects flags with no SQL breakout at all; an apostrophe closes the literal outright.
    # Falling back to a full upload costs bandwidth, never correctness.
    case "${_cib}" in
        *[!A-Za-z0-9_.-]*)
            # To fd 9: this function's STDOUT is the value, and the caller captures it. A plain
            # log() here is swallowed into that capture — and worse, becomes the "base" the
            # upload is then diffed against, inverting the gate into the injection it exists to
            # prevent. Same rule as resolved_or_override; fd 9 keeps the warning on the console
            # and in the log file without contaminating the return value.
            log "WARN" "[ClickHouse] Ignoring remote backup name '${_cib}': it has characters outside A-Z a-z 0-9 _ . - and would be interpolated into the upload command" >&9
            log "WARN" "[ClickHouse]   Falling back to a FULL upload for this run." >&9
            return 0 ;;
    esac
    printf '%s' "${_cib}"
}

backup_clickhouse() {
    log "INFO" "[ClickHouse] === Starting Backup ==="

    # Shared mode only: the tarball's destination directory, which THIS process creates. In s3
    # mode clickhouse-backup uploads to the bucket itself and there is nothing local to make —
    # mkdir'ing comp_path there produced a directory literally named "s3:<bucket>/..." on the
    # container's writable layer.
    if [ "${S3_ENABLED}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
        mkdir -p "$(comp_path clickhouse)"
    fi

    ch_resolve_pod || return 1
    ch_resolve_credentials
    ch_has_backup_api || return 1

    # Named backup_<ts>, so ClickHouse lands at <root>/clickhouse/backup_<ts>/ — the same shape
    # as every other component, which is what lets the generic retention sweep see it. That is
    # not the same as ClickHouse retention being correct; see DN-09.
    local backup_name="backup_${TIMESTAMP}"
    local ch_create_cmd="create ${backup_name}"

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[ClickHouse] [DRY RUN] pod ${CH_POD}, backup ${backup_name}, type ${CH_BACKUP_TYPE}:"
        log "INFO" "[ClickHouse] [DRY RUN]   INSERT INTO system.backup_actions(command) VALUES('${ch_create_cmd}')"
        log "INFO" "[ClickHouse] [DRY RUN]   (poll until status=success, timeout ${CH_CREATE_TIMEOUT}s)"
        if [ "${S3_ENABLED}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN]   INSERT ... VALUES('upload ${backup_name}')   (timeout ${CH_UPLOAD_TIMEOUT}s)"
            log "INFO" "[ClickHouse] [DRY RUN]   INSERT ... VALUES('delete local ${backup_name}')"
        fi
        result_set clickhouse --arg status "success" --arg engine "clickhouse-backup" \
            --arg name "${backup_name}" --arg base "" \
            '{status: $status, engine: $engine, name: $name, base: $base,
              location: "(dry run)", size: "0B", bytes: 0, duration: 0}'
        return 0
    fi

    local start_time=$(date +%s)

    # Build the upload command BEFORE creating, so a bad incremental base is caught early.
    # For regular (non-embedded) backups the diff happens at UPLOAD time — `create` is always a
    # full local hardlink snapshot, and --diff-from-remote applies only to embedded/object-disk
    # backups. Flags must also precede the positional <backup_name>. Verified on 2.8.0.
    ch_resolve_destination
    local ch_upload_cmd="upload${CH_UPLOAD_EXTRA}"
    if [ "${CH_BACKUP_TYPE}" = "incremental" ]; then
        local prev_backup; prev_backup=$(ch_incremental_base)
        if [ -n "${prev_backup}" ]; then
            ch_upload_cmd="${ch_upload_cmd} --diff-from-remote=${prev_backup}"
            # Recorded in the manifest: this backup is NOT independently restorable, and the
            # retention sweep must keep ${prev_backup} alive (see the chain guard in section 9).
            CH_BACKUP_BASE="${prev_backup}"
            log "INFO" "[ClickHouse] Incremental upload based on: ${prev_backup}"
            log "WARN" "[ClickHouse] This backup DEPENDS on ${prev_backup}; retention keeps that chain alive, so an incremental's ancestors are not reclaimed on schedule"
        else
            log "WARN" "[ClickHouse] No previous remote backup for an incremental; falling back to full"
        fi
    fi
    ch_upload_cmd="${ch_upload_cmd} ${backup_name}"

    log "INFO" "[ClickHouse] Creating backup: ${backup_name} (type: ${CH_BACKUP_TYPE})"
    ch_run_action "${ch_create_cmd}" "${CH_CREATE_TIMEOUT}" 5 "backup creation" || return 1

    # Duration measures the CREATE, which is the phase this component controls; the upload that
    # follows is bounded separately by CH_UPLOAD_TIMEOUT.
    local duration=$(($(date +%s) - start_time))

    # Size: LIMIT 1 and shape-checked before use. system.backup_list can hold MORE THAN ONE row
    # for a name — a retry with the same --backup-id leaves the earlier attempt's remote row
    # while `create` has just added a local one — and a two-line result made
    # `--argjson bytes "123\n456"` invalid JSON, which recorded a ClickHouse backup that is
    # safely in the bucket as FAILED.
    local backup_size backup_size_bytes
    backup_size=$(ch_query "SELECT formatReadableSize(size) FROM system.backup_list WHERE name='${backup_name}' ORDER BY location LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || echo "unknown")
    backup_size_bytes=$(ch_query "SELECT size FROM system.backup_list WHERE name='${backup_name}' ORDER BY location LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || echo "0")
    # Anything that is not a plain integer becomes 0 rather than reaching --argjson: this value
    # is the only thing between a good backup and a failed manifest entry.
    case "${backup_size_bytes}" in
        ''|*[!0-9]*) log "WARN" "[ClickHouse] Could not read a usable size for ${backup_name} ('${backup_size_bytes}'); recording 0 bytes"
                     backup_size_bytes=0 ;;
    esac
    [ -n "${backup_size}" ] || backup_size="unknown"
    log "INFO" "[ClickHouse]   ${backup_name}: ${backup_size}, created in ${duration}s"
    log "INFO" "[ClickHouse]   Local: ${CH_POD}:/var/lib/clickhouse/backup/${backup_name} (hardlinks)"

    if [ "${S3_ENABLED}" = "true" ]; then
        log "INFO" "[ClickHouse] Uploading backup to S3..."
        ch_run_action "${ch_upload_cmd}" "${CH_UPLOAD_TIMEOUT}" 10 "S3 upload" || return 1
        log "INFO" "[ClickHouse] Deleting the local backup after upload..."
        ch_query "INSERT INTO system.backup_actions(command) VALUES('delete local ${backup_name}')" >> "${LOG_FILE}" 2>&1
    elif [ "${BACKUP_TARGET}" = "shared" ]; then
        ch_archive_to_shared "${backup_name}" || return 1
    fi

    if [ "${VERBOSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Listing all backups:"
        ch_query "SELECT name, created, location, desc FROM system.backup_list ORDER BY created DESC LIMIT 10 FORMAT PrettyCompactMonoBlock" 2>&1 | tee -a "${LOG_FILE}"
    fi

    log "INFO" "[ClickHouse] Backup completed successfully"
    ch_record_result "${backup_name}" "${backup_size}" "${backup_size_bytes}" "${duration}"
    return 0
}

# Shared mode: clickhouse-backup has no filesystem remote, so archive the freeze backup to the
# mounted RWX volume from inside the sidecar (it has both the data volume with the hardlinks
# AND the central mount). tar dereferences the hardlinks.
ch_archive_to_shared() {   # <backup-name>
    local backup_name="$1" ch_shared_dir ch_tar_bytes
    ch_shared_dir="$(comp_inpod clickhouse)"
    CH_SHARED_TAR="${ch_shared_dir}/${backup_name}.tar.gz"
    log "INFO" "[ClickHouse] Archiving backup to the shared volume: ${CH_SHARED_TAR}"
    if ! pod_sh ClickHouse "${CH_POD}" clickhouse-backup "${KUBECTL_EXEC_TIMEOUT}" \
        'mkdir -p "$1" && tar -czf "$2" -C /var/lib/clickhouse/backup "$3"' \
        "${ch_shared_dir}" "${CH_SHARED_TAR}" "${backup_name}" >> "${LOG_FILE}" 2>&1; then
        log "ERROR" "[ClickHouse] Failed to archive the backup to the shared volume"
        return 1
    fi
    ch_tar_bytes=$(pod_sh ClickHouse "${CH_POD}" clickhouse-backup "${KUBECTL_STATUS_TIMEOUT}" \
        'wc -c < "$1"' "${CH_SHARED_TAR}" 2>/dev/null | tr -d ' ')
    : "${ch_tar_bytes:=0}"
    if ! [ "${ch_tar_bytes}" -gt 0 ] 2>/dev/null; then
        log "ERROR" "[ClickHouse] Shared archive missing or empty at ${CH_SHARED_TAR}"
        return 1
    fi
    log "INFO" "[ClickHouse] ✓ Archived to the shared volume ($(human_bytes "${ch_tar_bytes}"))"
    log "INFO" "[ClickHouse] Deleting the local backup after archiving..."
    ch_query "INSERT INTO system.backup_actions(command) VALUES('delete local ${backup_name}')" >> "${LOG_FILE}" 2>&1
    return 0
}

# The manifest entry. `location` is a sentence for a human; s3_bucket/s3_path are the
# COORDINATES restore, the pre-flight gate and retention address the backup by. Recording only
# the sentence is what left an honoured sidecar override readable by a person and unusable by
# every code path — DN-43. Both are always recorded, override or not, so a reader never has to
# infer "no override means recompute it from my own settings".
ch_record_result() {   # <name> <size-human> <size-bytes> <duration>
    local backup_name="$1" size_h="$2" size_b="$3" duration="$4"
    local ch_location="" ch_restore="" ch_mf_bucket="" ch_mf_path=""
    if [ "${BACKUP_TARGET}" = "shared" ]; then
        ch_location="${CH_SHARED_TAR}"
        ch_restore="(in the CH pod) tar -xzf ${ch_location} -C /var/lib/clickhouse/backup && clickhouse-backup restore ${backup_name}"
    else
        ch_mf_path="${CH_WANT_PATH}"
        if [ -n "${CH_LOCATION_OVERRIDE}" ]; then
            ch_location="clickhouse-backup S3 remote: ${backup_name} at ${CH_LOCATION_OVERRIDE}"
            ch_mf_bucket="${CH_CFG_BUCKET}"
        else
            ch_location="clickhouse-backup S3 remote: ${backup_name}"
            ch_mf_bucket="${S3_BUCKET}"
        fi
        ch_restore="clickhouse-backup restore_remote --env S3_BUCKET=${ch_mf_bucket} --env S3_PATH=${ch_mf_path} ${backup_name}"
    fi
    result_set clickhouse \
        --arg status "success" --arg engine "clickhouse-backup" \
        --arg name "${backup_name}" --arg base "${CH_BACKUP_BASE}" \
        --arg location "${ch_location}" --arg restore "${ch_restore}" \
        --arg s3_bucket "${ch_mf_bucket}" --arg s3_path "${ch_mf_path}" \
        --arg size "${size_h}" \
        --argjson bytes "${size_b}" --argjson duration "${duration}" \
        '{status: $status, engine: $engine, name: $name, base: $base, location: $location,
          s3_bucket: $s3_bucket, s3_path: $s3_path,
          size: $size, bytes: $bytes, duration: $duration, restore: $restore}'
}

################################################################################
# VictoriaMetrics Backup - Using vmbackup
################################################################################

# vmbackup's -dst for one pod. A genuine scheme difference (vmbackup takes s3:// or fs://), so
# it is resolved in ONE place and used by both the dry-run preview and the real invocation —
# the two used to build it separately, which is how a preview comes to show a path the run does
# not use. fs:// is what the vmstorage POD sees, hence comp_inpod.
vm_dst_for_pod() {   # <pod> <backup-name>
    if [ "${S3_ENABLED}" = "true" ]; then echo "$(comp_display victoriametrics)/$1/$2"
    else echo "fs://$(comp_inpod victoriametrics)/$1/$2"; fi
}

backup_victoriametrics() {
    log "INFO" "[VictoriaMetrics] === Starting Backup ==="
    local vm_start_time=$(date +%s)
    local vm_total_bytes=0 vm_objects=""

    # Non-AWS S3-compatible storage: vmbackup does not read endpoint env vars — the custom
    # endpoint must be passed as a flag (expands to nothing for AWS S3). Computed once here
    # and reused by both the dry-run log and the per-pod exec below.
    local vm_endpoint_flag=""; vm_endpoint_flag=$(vm_endpoint_arg)

    # Get list of vmstorage pods
    local vmstorage_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -l "${LABEL_VM_STORAGE}" \
        -o jsonpath='{.items[*].metadata.name}')
    
    if [ -z "${vmstorage_pods}" ]; then
        log "ERROR" "[VictoriaMetrics] No vmstorage pods found in namespace: ${NAMESPACE}"
        log "ERROR" "[VictoriaMetrics] Check if cluster is running: kubectl get vmcluster -n ${NAMESPACE}"
        return 1
    fi
    
    log "INFO" "[VictoriaMetrics] Found vmstorage pods: ${vmstorage_pods}"

    local pod_count=0
    local success_count=0
    local failed_pods=""

    # Backup each vmstorage pod
    for pod in ${vmstorage_pods}; do
        pod_count=$((pod_count + 1))
        log "INFO" "[VictoriaMetrics] Processing vmstorage pod ${pod_count}: ${pod}"
        
        # Check if vmbackup sidecar container exists
        local has_vmbackup_sidecar=false
        if kubectl get pod -n "${NAMESPACE}" "${pod}" \
            -o jsonpath='{.spec.containers[*].name}' | grep -q "vmbackup"; then
            has_vmbackup_sidecar=true
            log "INFO" "[VictoriaMetrics] vmbackup sidecar detected in ${pod}"
        else
            log "WARN" "[VictoriaMetrics] vmbackup sidecar not found in ${pod}, skipping"
            log "INFO" "[VictoriaMetrics] To enable: Set victoriaMetrics.vmstorage.backup.enabled=true in Helm values"
            failed_pods="${failed_pods} ${pod}"
            continue
        fi
        
        # Create backup using vmbackup sidecar with snapshot API
        local backup_name="vm_backup_${TIMESTAMP}"
        
        # vmbackup writes to its destination itself and writes backup_complete.ignore there as
        # its final step, so the completion marker is structurally guaranteed — there is no copy
        # step that could drop it.
        local backup_dst="$(vm_dst_for_pod "${pod}" "${backup_name}")"
        log "INFO" "[VictoriaMetrics] Creating backup ${backup_name} -> ${backup_dst}"
        
        # Execute vmbackup in the sidecar container using snapshot API
        # Through pod_exec, so --dry-run prints exactly this argv and runs nothing.
        local vm_output
        local vm_exit_code
        set +e
        vm_output=$(pod_exec VictoriaMetrics "${pod}" vmbackup "${KUBECTL_EXEC_TIMEOUT}" \
            /vmbackup-prod \
            -snapshot.createURL=http://localhost:8482/snapshot/create \
            -snapshot.deleteURL=http://localhost:8482/snapshot/delete \
            -storageDataPath=/vmstorage-data \
            -dst="${backup_dst}" \
            ${vm_endpoint_flag} \
            -concurrency=10 \
            -maxBytesPerSecond=0 2>&1)
        vm_exit_code=$?
        set -e
        
        if [ "${VERBOSE}" = "true" ]; then
            echo "${vm_output}" | tee -a "${LOG_FILE}"
        else
            echo "${vm_output}" >> "${LOG_FILE}"
        fi
        
        if [ $vm_exit_code -eq 0 ]; then
            if [ "${DRY_RUN}" = "true" ]; then
                # pod_exec only printed the argv. Count it as planned so the preview reports the
                # scope a real run would have, and skip the byte accounting there is none of.
                vm_objects="${vm_objects} ${backup_dst#fs://}"
                success_count=$((success_count + 1))
                continue
            fi
            log "INFO" "[VictoriaMetrics] ✓ Completed: ${backup_name}"
            log "INFO" "[VictoriaMetrics] Location: ${backup_dst}"
            # Record the landed ref (strip vmbackup's fs:// / s3:// scheme noise to a plain URI)
            vm_objects="${vm_objects} ${backup_dst#fs://}"
            success_count=$((success_count + 1))
            # Extract bytes backed up from vmbackup output (e.g. "backed up 826325077 bytes")
            local pod_bytes
            pod_bytes=$(echo "${vm_output}" | grep -o 'backed up [0-9]* bytes' | grep -o '[0-9]*' || true)
            : "${pod_bytes:=0}"
            if [ "${pod_bytes}" -gt 0 ] 2>/dev/null; then
                vm_total_bytes=$((vm_total_bytes + pod_bytes))
            fi
        else
            log "ERROR" "[VictoriaMetrics] Backup creation failed for ${pod}"
            failed_pods="${failed_pods} ${pod}"
        fi
    done
    
    local vm_status="failed"
    if [ ${success_count} -eq 0 ]; then
        log "ERROR" "[VictoriaMetrics] ✗ Backup failed for all pods"
        log "ERROR" "[VictoriaMetrics] Failed pods:${failed_pods}"
    elif [ ${success_count} -lt ${pod_count} ]; then
        log "WARN" "[VictoriaMetrics] ⚠ Backup partially completed: ${success_count}/${pod_count} pods — partial is failure (DN-21)"
        log "WARN" "[VictoriaMetrics] Failed pods:${failed_pods}"
    else
        vm_status="success"
        log "INFO" "[VictoriaMetrics] Backup completed successfully"
    fi
    result_set victoriametrics \
        --arg status "${vm_status}" --arg engine "vmbackup" \
        --arg location "$(comp_location victoriametrics)/<pod>/" \
        --arg objs "${vm_objects}" \
        --argjson pods "${success_count}" \
        --argjson bytes "${vm_total_bytes}" \
        --argjson duration "$(($(date +%s) - vm_start_time))" \
        '{status: $status, engine: $engine, location: $location, pods: $pods,
          bytes: $bytes, duration: $duration,
          objects: ($objs | split(" ") | map(select(length > 0)))}'
    [ ${success_count} -eq 0 ] && return 1
    return 0
}

################################################################################
# PMM Server Backup - Archive /srv from each PMM server pod
################################################################################

backup_pmm_server() {
    log "INFO" "[PMMServer] === Starting Backup ==="
    local pmm_start_time=$(date +%s)
    local pmm_total_bytes=0 pmm_objects="" pmm_file_sizes=""

    # Discover all PMM server pods (HA StatefulSet: 1, 3, 5, ... replicas)
    local pmm_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -l "${LABEL_PMM_SERVER}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    if [ -z "${pmm_pods}" ]; then
        log "ERROR" "[PMMServer] No PMM server pods found in namespace: ${NAMESPACE}"
        log "ERROR" "[PMMServer] Check label: ${LABEL_PMM_SERVER}"
        return 1
    fi

    log "INFO" "[PMMServer] Found PMM server pods: ${pmm_pods}"

    # Archive each top-level entry of /srv as its OWN member (cd /srv; tar ... $(ls -A ...)),
    # NOT '/srv' itself and NOT the './' dir entry, and skip the ext4 'lost+found'. If the
    # archive contains a directory entry for the /srv mount point, restore makes tar chmod/utime
    # that root-owned mount point as a non-root user -> "Operation not permitted" -> tar exit 2.
    # Listing the contents explicitly (no '.' member) lets restore extract straight into /srv.

    local pod_count=0
    local success_count=0
    local failed_pods=""

    for pod in ${pmm_pods}; do
        pod_count=$((pod_count + 1))
        log "INFO" "[PMMServer] Archiving ${PMM_SRV_PATH} from pod ${pod_count}: ${pod}"

        # Land the /srv archive at the target — bytes go pod->dest directly (no API-server
        # stream). s3: the pmm-backup sidecar tars and rclone-rcats to S3. shared: in-pod
        # tar to the mounted central volume (${SHARED_MOUNT_PATH}).
        local s3_uri="$(comp_path pmm-server)/${pod}/srv.tar.gz"
        local shared_file="$(comp_inpod pmm-server)/${pod}/srv.tar.gz"
        # The same object as the two above, in the view THIS process addresses (DN-05): the
        # rclone remote spec on s3, the orchestrator's own mount on shared. That is what the
        # store_* layer takes, so the verification below is one code path for both targets.
        local dest="$(comp_path pmm-server)/${pod}/srv.tar.gz"
        local pmm_exit size_b size_h

        # Each arm's script text is passed to pod_sh once, so the dry-run preview IS the command.
        # Both archive each top-level entry of /srv as its own member and skip lost+found (DN-30).
        set +e
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            # In the pmm-backup sidecar, which has rclone: bytes go pod -> S3 directly.
            pod_sh PMMServer "${pod}" pmm-backup "${KUBECTL_EXEC_TIMEOUT}" \
                'set -o pipefail; cd "$1" && tar -czf - --exclude=lost+found $(ls -A | grep -vxF lost+found) | rclone rcat --s3-no-check-bucket "$2"' \
                "${PMM_SRV_PATH}" "${s3_uri}" >> "${LOG_FILE}" 2>&1
            pmm_exit=$?
        else
            pod_sh PMMServer "${pod}" - "${KUBECTL_EXEC_TIMEOUT}" \
                'mkdir -p "$1" && cd "$2" && tar -czf "$3" --exclude=lost+found $(ls -A | grep -vxF lost+found)' \
                "$(comp_inpod pmm-server)/${pod}" "${PMM_SRV_PATH}" "${shared_file}" >> "${LOG_FILE}" 2>&1
            pmm_exit=$?
        fi
        set -e
        if [ "${DRY_RUN}" = "true" ]; then success_count=$((success_count + 1)); continue; fi

        # tar: 0=ok, 1=files changed/unreadable while reading (warn); >=2 fatal; 124=timeout
        if [ ${pmm_exit} -eq 0 ] || [ ${pmm_exit} -eq 1 ]; then
            [ ${pmm_exit} -eq 1 ] && log "WARN" "[PMMServer] ${pod}: tar warnings (files changed/unreadable while archiving)"

            # Verify the archive landed, and read its size from the DESTINATION — through the
            # storage layer for both targets, so neither the size parse nor the
            # absent-is-success delete rule exists in a second copy (DN-26).
            size_b=$(store_bytes "${dest}" 2>/dev/null || echo 0)
            : "${size_b:=0}"

            if ! [ "${size_b}" -gt 0 ] 2>/dev/null; then
                log "ERROR" "[PMMServer] ${pod}: archive missing/empty at destination after upload — treating as failed"
                store_delete_object "${dest}" >/dev/null 2>&1 || true
                failed_pods="${failed_pods} ${pod}"
                continue
            fi

            size_h=$(human_bytes "${size_b}")
            log "INFO" "[PMMServer] ✓ ${pod}: ${PMM_SRV_PATH} archived (${size_h})"
            success_count=$((success_count + 1))
            pmm_total_bytes=$((pmm_total_bytes + size_b))
            # Keyed by POD name, which is also the <component>/<id>/<pod>/ subdirectory the
            # restore resolves by ordinal — so the gate can match expected to actual per ordinal.
            pmm_file_sizes="${pmm_file_sizes} ${pod}:${size_b}"
            pmm_objects="${pmm_objects} $(comp_location pmm-server)/${pod}/srv.tar.gz"
        else
            log "ERROR" "[PMMServer] Backup failed for ${pod} (exit code: ${pmm_exit})"
            [ ${pmm_exit} -eq 124 ] && log "ERROR" "[PMMServer]   Timed out after ${KUBECTL_EXEC_TIMEOUT}s (raise KUBECTL_EXEC_TIMEOUT)"
            # Remove the truncated object through the layer, same as above.
            store_delete_object "${dest}" >/dev/null 2>&1 || true
            failed_pods="${failed_pods} ${pod}"
        fi
    done

    local pmm_status="failed"
    if [ ${success_count} -eq 0 ]; then
        log "ERROR" "[PMMServer] ✗ Backup failed for all pods"
        log "ERROR" "[PMMServer] Failed pods:${failed_pods}"
    elif [ ${success_count} -lt ${pod_count} ]; then
        log "WARN" "[PMMServer] ⚠ Backup partially completed: ${success_count}/${pod_count} pods — partial is failure (DN-21)"
        log "WARN" "[PMMServer] Failed pods:${failed_pods}"
    else
        pmm_status="success"
        log "INFO" "[PMMServer] Backup completed successfully"
    fi
    result_set pmm-server \
        --arg status "${pmm_status}" --arg engine "tar+rclone" \
        --arg location "$(comp_location pmm-server)/<pod>/srv.tar.gz" \
        --arg objs "${pmm_objects}" \
        --argjson pods "${success_count}" \
        --argjson bytes "${pmm_total_bytes}" \
        --argjson duration "$(($(date +%s) - pmm_start_time))" \
        --argjson files "$(sizes_to_json "${pmm_file_sizes}")" \
        '{status: $status, engine: $engine, location: $location, pods: $pods,
          bytes: $bytes, duration: $duration, files: $files,
          objects: ($objs | split(" ") | map(select(length > 0)))}'
    [ ${success_count} -eq 0 ] && return 1
    return 0
}

################################################################################
# Backup PMM Encryption Key
################################################################################

backup_encryption_key() {
    log "INFO" "[EncryptionKey] === Starting Backup ==="
    
    local secret_name="pg-encryption-key"
    # Staged locally, then stored. comp_path is an rclone remote spec in s3 mode, so
    # mkdir'ing it created a directory literally named "s3:<bucket>/..." on the container's
    # writable layer and wrote the plaintext key Secret there — off the PVC and unreaped.
    local key_stage_dir="$(staging_dir encryption)"
    local key_file="${key_stage_dir}/pg-encryption-key.yaml"
    local key_dest="$(comp_path encryption)/pg-encryption-key.yaml"
    
    # Check if secret exists
    if ! kubectl get secret "${secret_name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        log "WARN" "[EncryptionKey] Secret not found: ${secret_name}"
        log "INFO" "[EncryptionKey] This is normal if PMM encryption is not configured"
        return 2  # Not an error, just not configured
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[EncryptionKey] [DRY RUN] Commands (secret: ${secret_name}):"
        log "INFO" "[EncryptionKey] [DRY RUN]   \$ kubectl get secret ${secret_name} -n ${NAMESPACE} -o json | \\"
        log "INFO" "[EncryptionKey] [DRY RUN]       jq 'del(.metadata.resourceVersion, .metadata.uid, ...)' > ${key_file}"
        log "INFO" "[EncryptionKey] [DRY RUN]   \$ chmod 600 ${key_file}"
        return 0
    fi

    # Local staging dir (never the destination — see key_stage_dir above)
    if ! mkdir -p "${key_stage_dir}"; then
        log "ERROR" "[EncryptionKey] Failed to create staging directory: ${key_stage_dir}"
        return 1
    fi
    
    log "INFO" "[EncryptionKey] Exporting secret to clean JSON"
    
    # jq is a preflight requirement, but re-check here (belt and braces: the export
    # below pipes through jq and must not silently produce an unusable key file).
    if ! ensure_jq; then
        log "ERROR" "[EncryptionKey] jq is required to export the secret but is not on PATH"
        log "ERROR" "[EncryptionKey]   The chart's backup-tools container installs it at start-up; see its log:"
        log "ERROR" "[EncryptionKey]   kubectl logs deploy/<release>-backup-tools -n ${NAMESPACE}"
        return 1
    fi
    
    # Export secret as JSON, strip server-side metadata that breaks portable restore
    # umask, not chmod-after: the destination helper documents "mode set BEFORE content" and
    # the staging path must honour the same invariant — this is the key that decrypts
    # PostgreSQL, on a volume every component pod mounts.
    if ! ( umask 077; kubectl get secret "${secret_name}" -n "${NAMESPACE}" -o json | \
        jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.namespace, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]) | if .metadata.annotations == {} then del(.metadata.annotations) else . end' \
        > "${key_file}" ); then
        # Reap the partial file. A redirection that failed PART WAY (apiserver 5xx mid-stream,
        # jq OOM) leaves a file that can already contain the base64 `data` block, and because
        # this marks the backup failed, cmd_backup skips cleanup_old_backups — so the .staging
        # `-mtime +1` sweep never runs and it sits there across repeated failures. In shared
        # mode BACKUP_DIR is the central RWX volume every component pod mounts. DN-24 promises
        # the staged copy is removed "including on failure"; the success and store-failure
        # paths below already do it.
        rm -f "${key_file}" 2>/dev/null || true
        log "ERROR" "[EncryptionKey] Failed to export secret"
        return 1
    fi
    if [ -s "${key_file}" ]; then
        
        # Set restrictive permissions
        chmod 600 "${key_file}"
        
        # Calculate checksum
        local checksum; checksum=$(sha256_of "${key_file}")
        [ -n "${checksum}" ] || checksum="N/A"
        # `printf '%.16s'`, not ${checksum:0:16}: substring expansion is a bash/ash-with-
        # bash-compat extension and a FATAL "Bad substitution" on dash, which this file
        # claims to support. It aborted the whole run right here — after every component had
        # uploaded but before write_manifest — leaving the data orphaned with no index. A
        # syntax check cannot catch it (`-n` never evaluates expansions), so it survived
        # every shell lint.
        local checksum_short
        checksum_short=$(printf '%.16s' "${checksum}")
        # Recorded in the manifest, not just logged. This is the one object small enough to hash
        # for free, and it is the object whose silent corruption is least recoverable: a restore
        # that applies a truncated key Secret leaves PostgreSQL undecryptable with no error.
        # restore_encryption_key re-hashes what it read and refuses on a mismatch.
        [ "${checksum}" = "N/A" ] && checksum=""

        local file_size=$(du -h "${key_file}" | cut -f1)
        log "INFO" "[EncryptionKey] Exported successfully (size: ${file_size}, sha256: ${checksum_short}...)"
        log "INFO" "[EncryptionKey] ✓ Local export completed"
        log "INFO" "[EncryptionKey]   Location: ${key_file}"
        log "INFO" "[EncryptionKey]   Checksum: ${checksum_short}..."

        # The staged export lives on the (ephemeral) backup-tools pod, so it must be stored at
        # the destination — one call for both targets now, since store_write knows how.
        # Without this the key is NOT with the backup and a DR restore cannot decrypt PG.
        local enc_dest_display="$(comp_display encryption)/pg-encryption-key.yaml"
            if store_write_private "${key_dest}" < "${key_file}"; then
                result_set encryption --arg status "success" --arg location "${enc_dest_display}" \
                    --arg sha "${checksum}" --argjson bytes "$(wc -c < "${key_file}" | tr -d ' ')" \
                    '{status: $status, location: $location, sha256: $sha, bytes: $bytes}'
                log "INFO" "[EncryptionKey]   Stored at ${enc_dest_display}"
                # Remove the staged plaintext copy immediately. It is the key that decrypts
                # the PG data, it lives outside every backup id (so no retention purge covers
                # it), and in shared mode BACKUP_DIR is the central volume — leaving it for a
                # later run's .staging sweep meant it sat readable for >=48h, and indefinitely
                # if subsequent runs kept failing before cleanup.
                rm -f "${key_file}" 2>/dev/null || true
            else
                # The staged copy is on this pod only — if the store failed, the key is not
                # with the backup and a DR restore cannot decrypt the PG data. Hard failure.
                # Reap the staged plaintext even on failure: the key is always recoverable
                # from the live Secret, so keeping it buys nothing — and cleanup_old_backups
                # (which sweeps .staging) does not run when the backup failed, so it would
                # otherwise sit on the volume indefinitely across repeated failures.
                rm -f "${key_file}" 2>/dev/null || true
                log "ERROR" "[EncryptionKey]   Staged export OK but storing it FAILED (S3 credentials / bucket reachable?)"
                log "ERROR" "[EncryptionKey]   The key is not in S3; a DR restore of this backup could not decrypt PostgreSQL data"
                return 1
            fi

        return 0
    else
        # Empty or missing after a "successful" export — same reasoning as above: whatever is
        # there is unusable, and it must not be left on the volume.
        rm -f "${key_file}" 2>/dev/null || true
        log "ERROR" "[EncryptionKey] Failed to export secret (the staged file is empty)"
        return 1
    fi
}

################################################################################
# 8. Restore — validation gate, scale down/up, one function per component
################################################################################

# Tri-state probes: 0 = present, 1 = genuinely absent/empty, 2 = the check itself failed.
# A fail-closed gate that conflates the last two refuses a good restore mid-incident. See DN-15.
#
# NB for s3_object_state: `rclone size` on a MISSING path exits 0 and prints
# {"count":0,"bytes":0}, so rc alone cannot tell absence from success — only rc>0 is
# unambiguously a check failure, and only then is the byte count meaningful.
s3_object_state() {
    local bytes rc=0
    bytes=$(store_bytes "$1" 2>/dev/null) || rc=$?
    [ "${rc}" -ne 0 ] && return 2
    [ "${bytes:-0}" -gt 0 ] 2>/dev/null
}

# Same three outcomes, comparing the object's ACTUAL size against what the manifest recorded:
#   0 = matches (or no expectation recorded)   1 = wrong size / absent   2 = could not look
# This is the check "is it bigger than zero" cannot make — see DN-16. One path for both
# targets: store_bytes absorbs the difference. The detail goes in a global because the return
# value is the tri-state; it is cleared on every call so a stale value cannot be misreported.
OBJECT_SIZE_DETAIL=""
object_size_state() {   # <path> <expected-bytes-or-empty>
    OBJECT_SIZE_DETAIL=""
    local expect="${2:-}" actual rc=0
    actual=$(store_bytes "$1" 2>/dev/null) || rc=$?
    [ "${rc}" -ne 0 ] && return 2
    case "${actual}" in ''|*[!0-9]*) return 2 ;; esac
    [ "${actual}" -gt 0 ] || return 1
    # A backup taken before sizes were manifested records no expectation. Fall back to the
    # non-empty test rather than inventing a mismatch and refusing a good restore.
    case "${expect}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${actual}" -eq "${expect}" ] && return 0
    OBJECT_SIZE_DETAIL="manifest recorded ${expect} bytes, destination holds ${actual} — truncated or overwritten"
    return 1
}

# Is the per-component parent directory of a backup readable at all? Returns 0 when the
# listing succeeds, non-zero when it does not. Without this, a single failed listing makes
# EVERY ordinal look absent and the gate refuses the restore while blaming the backup —
# so callers probe once here and skip their per-ordinal loop rather than reporting N lies.
# Covers both targets: s3 lists through the client pod, shared stats the mounted path.
backup_subdir_listable() {
    store_list_dirs "$(comp_path "$1")" >/dev/null 2>&1
}

# Report a tri-state result against a component, returning non-zero when the caller should
# set fail=1. Keeps the three-way wording identical everywhere instead of re-spelling it at
# a dozen call sites.
report_state() {
    local state="$1" comp="$2" what="$3" hint="${4:-}"
    case "${state}" in
        0) return 0 ;;
        1) log "ERROR" "[Preflight] ${comp}: ${what} missing or empty${hint:+ (${hint})}" ;;
        # The hint belongs here too: a blocked operator needs the escape hatch MORE when the
        # check failed than when the data is genuinely gone.
        *) log "ERROR" "[Preflight] ${comp}: could not check ${what} — the check itself failed; NOT treating this as 'backup absent'${hint:+ (${hint})}" ;;
    esac
    return 1
}

# Emit the rclone S3 env entries for a temp restore pod that reaches the bucket itself — today
# that is the /srv restore pod (the separate S3 client pod is gone: the orchestrator runs rclone
# in-process). Block style, 8-space indent to match the pod heredocs. Kept as a single source so
# a new RCLONE_CONFIG_S3_* knob (or the static-key env) lands in every such pod at once rather
# than being added to one heredoc and silently missed in another. Includes the optional custom
# endpoint and, when a secret is configured, ${TEMP_POD_S3_KEYS_ENV}.
render_rclone_s3_env() {
    printf '%s' "        - name: RCLONE_CONFIG_S3_TYPE
          value: \"s3\"
        - name: RCLONE_CONFIG_S3_PROVIDER
          value: \"${S3_PROVIDER}\"
        - name: RCLONE_CONFIG_S3_ENV_AUTH
          value: \"true\"
        - name: RCLONE_CONFIG_S3_REGION
          value: \"${S3_REGION}\"
        - name: RCLONE_CONFIG_S3_NO_CHECK_BUCKET
          value: \"true\""
    [ -n "${S3_ENDPOINT}" ] && printf '\n        - name: RCLONE_CONFIG_S3_ENDPOINT\n          value: \"%s\"' "${S3_ENDPOINT}"
    printf '%s' "${TEMP_POD_S3_KEYS_ENV}"
}

# The value of a resolve-once setting: the explicit override if there is one, else what the
# resolver cached. Non-zero when nothing has resolved it yet, so a missing resolve_* call is a
# loud failure rather than a silent empty string that fails pod admission later.
#
# NEVER logs, and neither may its callers: every call site is inside `$( )`, where a log line on
# stdout would be captured AS the value — producing a three-line claimName. That split (a
# resolver that may log, an accessor that may not) is why these come in pairs.
resolved_or_override() {   # <override> <resolved>
    if [ -n "$1" ]; then printf '%s' "$1"; return 0; fi
    [ -n "$2" ] || return 1
    printf '%s' "$2"
}

vmstorage_pvc_name() { echo "${VM_STORAGE_PVC_PREFIX}$1"; }

# The PMM /srv PVC name prefix, READ from the StatefulSet that owns the PVCs rather than assumed
# from the chart's default — a second copy of a chart value here drifts silently (DN-39). A
# StatefulSet names its per-ordinal PVCs <volumeClaimTemplate>-<sts>-<ordinal>, so the template's
# name IS the prefix; it is selected by MOUNT PATH (the one at ${PMM_SRV_PATH}), with position as
# the fallback.
#
# Resolved ONCE, in the parent, so the pre-flight gate and the restore agree by construction —
# resolving per call in a subshell let them differ, and the restore's fallback then mounted a PVC
# that does not exist with PMM already at 0. Anything that can log has to run here rather than in
# the accessor; see resolved_or_override.
resolve_pmm_storage_pvc_prefix() {   # <statefulset-name>
    [ -z "${PMM_STORAGE_PVC_PREFIX}" ] || return 0            # explicit override wins
    [ -z "${PMM_STORAGE_PVC_PREFIX_RESOLVED}" ] || return 0    # already resolved this run
    local _pspp_json="" _pspp_name=""
    _pspp_json=$(kubectl get statefulset "$1" -n "${NAMESPACE}" -o json 2>/dev/null) || _pspp_json=""
    if [ -n "${_pspp_json}" ]; then
        # The claim template whose volume is mounted at ${PMM_SRV_PATH} by any container, and
        # which really is a volumeClaimTemplate (a plain volume of the same name is not ours).
        _pspp_name=$(printf '%s' "${_pspp_json}" | jq -r --arg p "${PMM_SRV_PATH}" '
            [.spec.volumeClaimTemplates[]?.metadata.name] as $t
            | [.spec.template.spec.containers[]?.volumeMounts[]?
               | select(.mountPath == $p) | .name]
            | map(select(. as $n | $t | index($n))) | first // empty' 2>/dev/null) || _pspp_name=""
        if [ -z "${_pspp_name}" ]; then
            _pspp_name=$(printf '%s' "${_pspp_json}" \
                | jq -r '.spec.volumeClaimTemplates[0].metadata.name // empty' 2>/dev/null) || _pspp_name=""
        fi
    fi
    if [ -z "${_pspp_name}" ]; then
        # REFUSE rather than assume. Guessing 'pmm-storage' is how an install that sets
        # storage.name ends up mounting a PVC that was never created — and the symptom is a temp
        # pod stuck Pending until a 300s wait expires, on the wrong side of the point of no
        # return. The operator can still force it with PMM_STORAGE_PVC_PREFIX.
        log "ERROR" "PMM ${1}: could not read a volumeClaimTemplate name from the StatefulSet."
        log "ERROR" "  The /srv restore mounts PVCs BY NAME, so guessing one would fail after PMM is scaled to 0."
        log "ERROR" "  Check RBAC on statefulsets, or set PMM_STORAGE_PVC_PREFIX=<storage.name>- explicitly."
        return 1
    fi
    PMM_STORAGE_PVC_PREFIX_RESOLVED="${_pspp_name}-"
    log "INFO" "PMM ${1}: /srv PVC name prefix is '${PMM_STORAGE_PVC_PREFIX_RESOLVED}' (from the StatefulSet's volumeClaimTemplate)"
    return 0
}

# Pure accessor: safe inside `$( )` because it never logs and never calls out to the cluster.
# Returns non-zero if nothing has resolved the prefix yet, so a missing
# resolve_pmm_storage_pvc_prefix call is a loud failure rather than a silent wrong name.
pmm_storage_pvc_prefix() { resolved_or_override "${PMM_STORAGE_PVC_PREFIX}" "${PMM_STORAGE_PVC_PREFIX_RESOLVED}"; }

pmm_storage_pvc_name() {   # <statefulset-name> <ordinal>
    _pspn_pfx=$(pmm_storage_pvc_prefix "$1") || return 1
    printf '%s%s-%s' "${_pspn_pfx}" "$1" "$2"
}

# The /srv restore pod's image, READ from the StatefulSet that owns the PVCs — never a hardcoded
# default, which is a second copy of a chart value that drifts (DN-39). In s3 mode the pmm-backup
# sidecar's image is preferred: it is the one container guaranteed to carry rclone, and the
# pmm-server image ships none, so a guess would take the RWO /srv PVC and only then fail —
# past the point of no return (DN-15). The shared path only needs tar.
#
# Split resolver/accessor for the same reason as pmm_storage_pvc_prefix: only the resolver may log.
PMM_RESTORE_IMAGE="${PMM_RESTORE_IMAGE:-}"   # explicit override; empty = read it from the StatefulSet
PMM_RESTORE_IMAGE_RESOLVED=""
resolve_pmm_restore_image() {   # <statefulset-name>
    [ -z "${PMM_RESTORE_IMAGE}" ] || return 0           # explicit override wins
    [ -z "${PMM_RESTORE_IMAGE_RESOLVED}" ] || return 0  # already resolved this run
    local _pri=""
    if [ "${S3_ENABLED}" = "true" ]; then
        _pri=$(kubectl get statefulset "$1" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.template.spec.containers[?(@.name=="pmm-backup")].image}' 2>/dev/null || true)
    fi
    [ -n "${_pri}" ] || _pri=$(kubectl get statefulset "$1" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    if [ -z "${_pri}" ]; then
        log "ERROR" "PMM ${1}: could not read a container image from the StatefulSet, so the /srv restore pod has no image."
        log "ERROR" "  Refusing to guess one: a wrong image is a temp pod that takes the RWO /srv PVC and then fails."
        log "ERROR" "  Check RBAC on statefulsets, or set PMM_RESTORE_IMAGE to an image with tar (and rclone for --target s3)."
        return 1
    fi
    PMM_RESTORE_IMAGE_RESOLVED="${_pri}"
    log "INFO" "PMM ${1}: /srv restore pod image is '${_pri}'"
    return 0
}

# Pure accessor: safe inside `$( )` because it never logs and never reaches the cluster. Non-zero
# when nothing has resolved the image yet, so a missing resolve_pmm_restore_image call is a loud
# failure rather than an empty `image:` field that fails pod admission.
pmm_restore_image() { resolved_or_override "${PMM_RESTORE_IMAGE}" "${PMM_RESTORE_IMAGE_RESOLVED}"; }

# Find the central backup PVC (shared mode VM restore pod mounts it).
resolve_central_backup_pvc() {
    [ -n "${CENTRAL_BACKUP_PVC}" ] && return 0
    local bt_pod
    bt_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_BACKUP_TOOLS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${bt_pod}" ]; then
        CENTRAL_BACKUP_PVC=$(kubectl get pod -n "${NAMESPACE}" "${bt_pod}" -o jsonpath='{.spec.volumes[?(@.name=="central-backup-storage")].persistentVolumeClaim.claimName}' 2>/dev/null || true)
    fi
    if [ -z "${CENTRAL_BACKUP_PVC}" ]; then
        log "ERROR" "[VictoriaMetrics] Central backup PVC not found (set CENTRAL_BACKUP_PVC or run from backup-tools)"
        return 1
    fi
    return 0
}

# The vmrestore temp pod's image: the vmstorage pod's OWN vmrestore sidecar first (version-matched
# to the vmstorage that wrote the backup), then the explicit override.
#
# Deliberately NO ":latest" last resort: vmrestore reads vmstorage's on-disk format, so an
# unpinned tag can be releases ahead of the data and would be pulled during a DR. A guess also
# only moves the failure to a temp pod already holding the RWO vmstorage-db PVC (DN-39).
#
# Prints the image or nothing, and NEVER logs — every call site is inside `$( )`, where a log
# line would be captured AS the image name. The caller reports the failure.
get_vmrestore_image() {
    local pod="$1" img
    img=$(kubectl get pod -n "${NAMESPACE}" "${pod}" -o jsonpath='{.spec.containers[?(@.name=="vmrestore")].image}' 2>/dev/null || true)
    [ -n "${img}" ] && { echo "${img}"; return 0; }
    [ -n "${VMRESTORE_IMAGE}" ] && { echo "${VMRESTORE_IMAGE}"; return 0; }
    return 1
}

# After the manifest is loaded, turn on every component the manifest has (unless
# the user explicitly selected a subset).
# Restore order: the encryption key first (nothing decrypts without it), then the three data
# stores — which may run concurrently — and PMM /srv last, so PMM boots against everything
# already in place.
RESTORE_COMPONENTS="encryption postgresql clickhouse victoriametrics pmm-server"
RESTORE_DB_COMPONENTS="postgresql clickhouse victoriametrics"

# Does this backup actually carry the component, per its manifest?
restore_has() { [ "$(comp_val "$1" 7 2>/dev/null)" = "success" ]; }
# Is the component both selected AND present in the backup? This is the ONE predicate that
# decides whether a component restore runs, and every gate below reads it — so "selected but
# not in this backup" can never be confused with "it worked".
restore_do() { comp_on "$1" 5 && restore_has "$1"; }
# Mark a component's outcome: restore_ok <key> <true|false>
restore_ok_set() { eval "$(comp_okvar "$1")=$2"; }
restore_ok()     { [ "$(comp_val "$1" 8)" = "true" ]; }

# "PG=true(success) CH=false(absent) ..." for the one plan line an operator reads.
restore_plan_line() {
    _rpl_c="" _rpl_out="" _rpl_st=""
    for _rpl_c in ${RESTORE_COMPONENTS}; do
        _rpl_st=$(comp_val "${_rpl_c}" 7)
        _rpl_out="${_rpl_out} ${_rpl_c}=$(comp_val "${_rpl_c}" 5)(${_rpl_st:-none})"
    done
    printf '%s' "${_rpl_out}"
}

select_default_components() {
    _sdc_row="" _sdc_key=""
    for _sdc_row in ${COMPONENTS}; do
        _sdc_key="${_sdc_row%%:*}"
        # Default (no explicit --<component>): restore everything the manifest marks 'success'.
        if [ "${EXPLICIT_SELECTION}" != "true" ] && [ "$(comp_val "${_sdc_key}" 7)" = "success" ]; then
            eval "$(comp_rvar "${_sdc_key}")=true"
        fi
        # --skip-<component> is applied last, so it beats both the manifest default and an
        # explicit selection.
        if [ "$(comp_val "${_sdc_key}" 6)" = "true" ]; then
            eval "$(comp_rvar "${_sdc_key}")=false"
        fi
    done
    return 0
}

# Credentials for the temp restore pods, proven while the cluster is still whole. A missing
# Secret or ServiceAccount is rejected at ADMISSION — i.e. after PMM is already scaled to 0.
validate_temp_pod_credentials() {
    local fail=0
    # vmrestore, /srv restore and the s3 client pod are all rendered with
    # TEMP_POD_SA_LINE + TEMP_POD_S3_KEYS_ENV. A missing Secret or ServiceAccount is
    # rejected at ADMISSION — i.e. after PMM is already down (see parse_args()).
    if [ "${S3_ENABLED}" = "true" ]; then
        local _st=0
        if [ -n "${S3_SECRET_NAME}" ]; then
            _st=0; k8s_object_state secret "${S3_SECRET_NAME}" || _st=$?
            if [ "${_st}" -eq 1 ]; then
                log "ERROR" "[Preflight] S3 secret '${S3_SECRET_NAME}' not found in ${NAMESPACE}; every temp restore pod would be rejected at admission"
                fail=1
            elif [ "${_st}" -ne 0 ]; then
                log "ERROR" "[Preflight] could not read secret '${S3_SECRET_NAME}' in ${NAMESPACE} (403/timeout?); NOT treating this as 'secret absent'"
                fail=1
            else
                # Keys are enumerated ONCE and matched exactly rather than addressed with
                # `jsonpath={.data.<key>}`: k8s allows dots in Secret keys and JSONPath reads a dot as a field
                # separator, so `aws.access.key` resolves to nothing and is reported missing while mounting
                # fine. `{{if $v}}` matters too — a key present but EMPTY would satisfy a name-only check and
                # every temp pod would then die on 403 after PMM is down.
                local _keys="" _krc=0 _key
                _keys=$(kubectl get secret "${S3_SECRET_NAME}" -n "${NAMESPACE}" \
                    -o 'go-template={{range $k, $v := .data}}{{if $v}}{{$k}}{{"\n"}}{{end}}{{end}}' 2>/dev/null) || _krc=$?
                if [ "${_krc}" -ne 0 ]; then
                    log "ERROR" "[Preflight] could not list keys of secret '${S3_SECRET_NAME}'; NOT treating this as 'keys absent'"
                    fail=1
                else
                    for _key in "${S3_SECRET_ACCESS_KEY_KEY}" "${S3_SECRET_SECRET_KEY_KEY}"; do
                        if ! printf '%s\n' "${_keys}" | grep -Fxq -e "${_key}"; then
                            log "ERROR" "[Preflight] S3 secret '${S3_SECRET_NAME}' has no non-empty key '${_key}'"
                            fail=1
                        fi
                    done
                fi
            fi
        fi
        if [ -n "${TEMP_POD_SA_LINE}" ]; then
            _st=0; k8s_object_state serviceaccount "${S3_SERVICE_ACCOUNT}" || _st=$?
            if [ "${_st}" -eq 1 ]; then
                log "ERROR" "[Preflight] ServiceAccount '${S3_SERVICE_ACCOUNT}' not found in ${NAMESPACE}; every temp restore pod would be rejected at admission"
                fail=1
            elif [ "${_st}" -ne 0 ]; then
                log "ERROR" "[Preflight] could not read ServiceAccount '${S3_SERVICE_ACCOUNT}' in ${NAMESPACE} (403 from a namespaced Role on a cross-namespace restore?); NOT treating this as 'SA absent'"
                fail=1
            fi
        fi
    fi
    return ${fail}
}

validate_restore_encryption() {
    local fail=0
    # Not overridable by consent. --yes answers the confirmation prompt and nothing else
    # (DN-44), so there is no flag an automated restore could carry that would quietly turn
    # this check off — which matters because automation is where restores actually run, and
    # because the only way past this gate should name what is being given up.
    # --skip-encryption-key is that explicit, narrow override.
    # One path, one probe: s3_object_state routes through store_bytes, which handles both
    # targets and preserves the could-not-look signal that `[ -s ]` cannot express.
    local _enc_path="$(comp_path encryption)/pg-encryption-key.yaml"
    _st=0; s3_object_state "${_enc_path}" || _st=$?
    report_state "${_st}" "encryption" "key ${_enc_path}" "--skip-encryption-key to drop it" || fail=1
    return ${fail}
}

validate_restore_postgresql() {
    local fail=0
    local _pgpod="" _db
    _pgpod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PG_PRIMARY}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${_pgpod}" ]; then
        log "ERROR" "[Preflight] postgresql: no primary pod matching '${LABEL_PG_PRIMARY}' (--skip-postgresql to drop it)"
        fail=1
    fi
    if [ -z "${MF_PG_DBS}" ]; then
        log "ERROR" "[Preflight] postgresql: manifest records no databases"
        fail=1
    else
        # One branch for both targets now: object_size_state routes through store_bytes,
        # which absorbs the s3/shared difference AND preserves the could-not-look signal
        # that the old `[ ! -s ]` arm could not express.
        local _exp=""
        for _db in ${MF_PG_DBS}; do
            _exp=$(jq -r --arg d "${_db}" '.components.postgresql.files[$d] // empty' "${MANIFEST_FILE}" 2>/dev/null || true)
            _st=0; object_size_state "$(comp_path postgresql)/${_db}.dump" "${_exp}" || _st=$?
            report_state "${_st}" "postgresql" "dump ${_db}.dump${OBJECT_SIZE_DETAIL:+ — ${OBJECT_SIZE_DETAIL}}" "--skip-postgresql to drop it" || fail=1
        done
    fi
    return ${fail}
}

validate_restore_clickhouse() {
    local fail=0
    local _chpod=""
    _chpod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_CH_POD}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${_chpod}" ]; then
        log "ERROR" "[Preflight] clickhouse: no pod matching '${LABEL_CH_POD}' (--skip-clickhouse to drop it)"
        fail=1
    elif [ -z "${MF_CH_NAME}" ]; then
        log "ERROR" "[Preflight] clickhouse: manifest records no backup name"
        fail=1
    elif [ "${S3_ENABLED}" = "true" ]; then
        # Mirror restore_clickhouse()'s --env overrides exactly, or this gate checks a different place
        # from the one the restore will read (DN-33). The listing's exit status is captured SEPARATELY
        # from the name match: piping into grep would report an unreachable sidecar as "backup not
        # found" and refuse a restore whose data is fine (DN-15).
        #
        # Its own timeout budget: `list remote` reads metadata for every remote backup, so 30s is too
        # tight on a populated bucket, while 600s would stall a --dry-run for ten silent minutes.
        local _ch_list="" _ch_rc=0
        log "INFO" "[Preflight] clickhouse: listing remote backups (can take a while on a populated bucket)..."
        _ch_list=$(timeout "${CH_LIST_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${_chpod}" -c clickhouse-backup -- \
            clickhouse-backup list remote \
            --env "S3_BUCKET=$(ch_restore_bucket)" --env "S3_PATH=$(ch_restore_path)" 2>/dev/null) || _ch_rc=$?
        if [ "${_ch_rc}" -ne 0 ]; then
            log "ERROR" "[Preflight] clickhouse: could not list remote backups (exit ${_ch_rc}); is the 'clickhouse-backup' sidecar running in ${_chpod}?"
            log "ERROR" "[Preflight]   Not treating this as 'backup absent' — the check itself failed. Fix the sidecar, or pass --skip-clickhouse."
            fail=1
        elif ! echo "${_ch_list}" | awk '{print $1}' | grep -Fxq "${MF_CH_NAME}"; then
            log "ERROR" "[Preflight] clickhouse: remote backup '${MF_CH_NAME}' not found under s3://$(ch_restore_bucket)/$(ch_restore_path)"
            log "ERROR" "[Preflight]   ClickHouse retention prunes independently of the central backups, so an older backup can outlive its ClickHouse half."
            log "ERROR" "[Preflight]   Restore a newer backup, or pass --skip-clickhouse to restore everything else without QAN data."
            fail=1
        fi
    # shared mode: restore_clickhouse() untars from SHARED_MOUNT_PATH *inside the CH pod*,
    # a different mount from the orchestrator's own BACKUP_DIR — checking the local path
    # would prove the wrong end. `sh -c '[ -s ]'` mirrors how the restore reads it, and
    # the exit status is split three ways for the same reason as the S3 branch: an RBAC
    # denial, an unready pod, a missing clickhouse-backup container or an image without
    # `test` must not be reported as "your tarball is gone".
    else
        # `test -s` as separate argv entries, NOT interpolated into `sh -c` (DN-17). `test` prints
        # nothing and returns 1 for false, while kubectl exec also returns 1 for its OWN failures —
        # they are told apart by stderr, which kubectl writes and `test` never does.
        local _cht_rc=0 _cht_err=""
        _cht_err=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${_chpod}" -c clickhouse-backup -- \
            test -s "$(comp_inpod clickhouse)/${MF_CH_NAME}.tar.gz" 2>&1 >/dev/null) || _cht_rc=$?
        if [ "${_cht_rc}" -eq 0 ]; then
            :
        elif [ "${_cht_rc}" -eq 1 ] && [ -z "${_cht_err}" ]; then
            report_state 1 "clickhouse" "$(comp_inpod clickhouse)/${MF_CH_NAME}.tar.gz inside ${_chpod}" "--skip-clickhouse to drop it" || fail=1
        else
            log "ERROR" "[Preflight] clickhouse: could not test the tarball inside ${_chpod} (rc ${_cht_rc}): ${_cht_err:-no stderr}"
            log "ERROR" "[Preflight]   NOT treating this as 'backup absent' — fix the pod/RBAC, or pass --skip-clickhouse."
            fail=1
        fi
    fi
    return ${fail}
}

validate_restore_victoriametrics() {
    local fail=0
    local _vmpods="" _vmcluster="" _vmtarget="" _vmsrc="" _p _ord="" _sub="" _vmname="" _vmimg=""
    _vmpods=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_VM_STORAGE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    _vmcluster=$(kubectl get vmcluster -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${_vmpods}" ]; then
        log "ERROR" "[Preflight] victoriametrics: no vmstorage pods matching '${LABEL_VM_STORAGE}' (--skip-victoriametrics to drop it)"
        fail=1
    fi
    if [ -z "${_vmcluster}" ]; then
        log "ERROR" "[Preflight] victoriametrics: no VMCluster resource; the restore could not scale it safely"
        fail=1
    fi
    # The temp pod's image, proven while the tier is still up. get_vmrestore_image no longer
    # guesses ":latest", so it can refuse — and discovering that inside the per-ordinal loop
    # means discovering it with vmstorage already at 0 replicas (DN-15).
    if [ -n "${_vmpods}" ]; then
        _vmimg=$(get_vmrestore_image "$(echo "${_vmpods}" | awk '{print $1}')") || _vmimg=""
        if [ -z "${_vmimg}" ]; then
            log "ERROR" "[Preflight] victoriametrics: no vmrestore image — the vmstorage pods have no 'vmrestore' container and VMRESTORE_IMAGE is unset."
            log "ERROR" "[Preflight]   Set victoriaMetrics.vmstorage.backup.restoreImage in the chart, or VMRESTORE_IMAGE=<image>; it must match the vmstorage version that wrote the backup."
            fail=1
        fi
    fi
    # Shard-count mismatch was already checked inside restore_victoriametrics(), but that
    # runs with PMM ALREADY DOWN. Hoisted here so it aborts while the cluster is intact.
    if [ -n "${_vmpods}" ]; then
        _vmtarget=$(echo "${_vmpods}" | wc -w | tr -d ' ')
        _vmsrc=$(vm_src_ordinal_count 2>/dev/null || echo "")
        if [ -n "${_vmsrc}" ] && [ "${_vmsrc}" -gt 0 ] 2>/dev/null && [ "${_vmsrc}" != "${_vmtarget}" ]; then
            log "ERROR" "[Preflight] victoriametrics: shard-count mismatch — backup has ${_vmsrc} vmstorage ordinal(s), target has ${_vmtarget}. Set vmstorage replicaCount to ${_vmsrc} and retry."
            fail=1
        else
            # vm_src_subdir_for_ord() is what vm_src_for_pod() resolves internally; calling
            # it directly gives the subdir needed to also inspect the directory's CONTENTS.
            _vmname="vm_backup_${BACKUP_NAME#backup_}"
            # Prove the parent listing works before reading anything into per-ordinal
            # absence (see backup_subdir_listable). The flag guards the loop instead of
            # blanking _vmpods: poisoning the pod list would silently mislead any check
            # added after this block into seeing zero pods.
            local _vm_skip=false
            if ! backup_subdir_listable victoriametrics; then
                report_state 2 "victoriametrics" "${BACKUP_NAME}/victoriametrics/" || fail=1
                _vm_skip=true
            fi
            if [ "${_vm_skip}" != "true" ]; then
            for _p in ${_vmpods}; do
                _ord="${_p##*-}"
                # Target side, same reasoning as the pmm-server block below: vmrestore's temp
                # pod mounts this PVC by name while vmstorage is scaled to 0, so a name that
                # does not resolve strands the run past the point of no return (DN-39).
                local _vpvc=""
                _vpvc=$(vmstorage_pvc_name "${_p}")
                _st=0; k8s_object_state persistentvolumeclaim "${_vpvc}" || _st=$?
                if [ "${_st}" -eq 1 ]; then
                    log "ERROR" "[Preflight] victoriametrics: PVC '${_vpvc}' does not exist, so the restore pod for ${_p} would never schedule (override with VM_STORAGE_PVC_PREFIX)"
                    fail=1
                elif [ "${_st}" -ne 0 ]; then
                    log "ERROR" "[Preflight] victoriametrics: could not check PVC '${_vpvc}' (403/timeout?); NOT treating this as 'PVC absent'"
                    fail=1
                fi
                _sub=$(vm_src_subdir_for_ord "${_ord}" 2>/dev/null || echo "")
                if [ -z "${_sub}" ]; then
                    log "ERROR" "[Preflight] victoriametrics: backup has no source directory for ordinal '${_ord}' (pod ${_p})"
                    fail=1
                    continue
                fi
                # A directory being LISTED is not the same as it holding data: vmrestore against an empty or
                # truncated vm_backup_<id>/ fails only once PMM is down. One listing per ordinal proves there
                # is something to restore, with the listing's own status captured first (DN-03).
                local _vmls="" _vmrc=0
                _vmls=$(store_list "$(comp_path victoriametrics)/${_sub}/${_vmname}" 2>/dev/null) || _vmrc=$?
                if [ "${_vmrc}" -ne 0 ]; then
                    report_state 2 "victoriametrics" "source for ordinal '${_ord}' (${_sub}/${_vmname})" "--skip-victoriametrics to drop it" || fail=1
                elif [ -z "${_vmls}" ]; then
                    report_state 1 "victoriametrics" "source for ordinal '${_ord}' (${_sub}/${_vmname})" "--skip-victoriametrics to drop it" || fail=1
                fi
            done
            fi
        fi
    fi
    return ${fail}
}

validate_restore_pmm_server() {
    local fail=0
    local _sts="" _replicas="" _i=0 _sub="" _pexp=""
    _sts=$(kubectl get statefulset -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${_sts}" ]; then
        log "ERROR" "[Preflight] pmm-server: no StatefulSet matching '${LABEL_PMM_SERVER}' (--skip-pmm-server to drop it)"
        fail=1
    else
        # THE resolver restore_pmm_server uses, so the ordinals checked here are exactly
        # the ordinals it will iterate. It used to be a third hand-rolled copy of the same
        # ladder, and the only one that checked the answer is a number.
        _replicas=$(pmm_replica_count "${_sts}")
        # Belt and braces: a non-numeric count would make the `-lt` below exit 2, the loop
        # body never run, and this gate report SUCCESS without validating a single ordinal.
        # A silent skip is worse than no gate. pmm_replica_count cannot return one, so this
        # only fires if that contract is ever broken.
        case "${_replicas}" in
            ''|*[!0-9]*)
                log "ERROR" "[Preflight] pmm-server: replica count '${_replicas}' is not a number; cannot determine which ordinals to validate"
                fail=1
                _replicas=0
                ;;
        esac
        # As for VictoriaMetrics: a failed parent listing must not read as "every ordinal
        # is missing", or a transient error refuses the restore and blames the backup.
        if [ "${_replicas}" -gt 0 ] && ! backup_subdir_listable pmm-server; then
            report_state 2 "pmm-server" "${BACKUP_NAME}/pmm-server/" || fail=1
            _replicas=0
        fi
        # Resolved HERE, in the parent, once — the accessor used inside the loop cannot log
        # and cannot reach the cluster, so this is the call that either establishes the
        # prefix for the whole run or fails the gate. Both this loop and restore_pmm_server
        # then read the SAME cached value, which is what makes the check below meaningful.
        if [ "${_replicas}" -gt 0 ] && ! resolve_pmm_storage_pvc_prefix "${_sts}"; then
            log "ERROR" "[Preflight] pmm-server: cannot determine the /srv PVC names (--skip-pmm-server to drop it)"
            fail=1
            _replicas=0
        fi
        # Same reasoning for the temp pod's image, and the same cached resolver
        # restore_pmm_server reads — so this proves the real thing rather than a lookalike.
        if [ "${_replicas}" -gt 0 ] && ! resolve_pmm_restore_image "${_sts}"; then
            log "ERROR" "[Preflight] pmm-server: cannot determine the /srv restore pod image (--skip-pmm-server to drop it)"
            fail=1
            _replicas=0
        fi
        while [ "${_i}" -lt "${_replicas}" ]; do
            # The TARGET side of the restore, proven while PMM is still up. The temp pod
            # mounts this PVC by name; a name that does not resolve leaves the pod Pending
            # until the 300s readiness wait gives up — with PMM already at 0 replicas, which
            # is precisely what this gate exists to prevent (DN-15, DN-39). Same cached
            # prefix restore_pmm_server will use, so this proves the real thing.
            local _ppvc=""
            _ppvc=$(pmm_storage_pvc_name "${_sts}" "${_i}") || { log "ERROR" "[Preflight] pmm-server: PVC name for ordinal ${_i} could not be built"; fail=1; break; }
            _st=0; k8s_object_state persistentvolumeclaim "${_ppvc}" || _st=$?
            if [ "${_st}" -eq 1 ]; then
                log "ERROR" "[Preflight] pmm-server: PVC '${_ppvc}' does not exist, so the ordinal ${_i} restore pod would never schedule"
                log "ERROR" "[Preflight]   The name comes from the StatefulSet's volumeClaimTemplate; override with PMM_STORAGE_PVC_PREFIX if that is wrong."
                fail=1
            elif [ "${_st}" -ne 0 ]; then
                log "ERROR" "[Preflight] pmm-server: could not check PVC '${_ppvc}' (403/timeout?); NOT treating this as 'PVC absent'"
                fail=1
            fi
            _sub=$(pmm_src_subdir_for_ord "${_i}" 2>/dev/null || echo "")
            if [ -z "${_sub}" ]; then
                # restore_pmm_server() only WARNs and skips here, so without this gate a
                # PMM replica silently keeps its pre-restore /srv while the run reports success.
                log "ERROR" "[Preflight] pmm-server: backup has no /srv directory for ordinal ${_i} (${_replicas} replica(s) expected)"
                fail=1
            else
                # Expected size is keyed by the SOURCE pod name, which is exactly the
                # subdirectory just resolved for this ordinal. One branch for both targets.
                _pexp=$(jq -r --arg p "${_sub}" '.components["pmm-server"].files[$p] // empty' "${MANIFEST_FILE}" 2>/dev/null || true)
                _st=0; object_size_state "$(comp_path pmm-server)/${_sub}/srv.tar.gz" "${_pexp}" || _st=$?
                report_state "${_st}" "pmm-server" "srv.tar.gz for ordinal ${_i} (${_sub})${OBJECT_SIZE_DETAIL:+ — ${OBJECT_SIZE_DETAIL}}" "--skip-pmm-server to drop it" || fail=1
            fi
            _i=$((_i + 1))
        done
    fi
    return ${fail}
}

# Pre-restore validation gate.
#
# Everything a SELECTED component needs is proven here, while the cluster is still whole:
# scale_down_pmm() is the point of no return. Fails CLOSED, does NOT short-circuit — an operator
# mid-incident needs every problem in one pass, not the first one — and names the
# --skip-<component> flag for each failure. See DN-15.
#
# One per-component gate each, dispatched off the component table, so a component cannot be
# added to the restore and silently left unvalidated.
validate_restore_targets() {
    local fail=0 _vrt_c="" _vrt_fn=""

    log "INFO" "Validating restore targets for ${BACKUP_NAME} (nothing has been changed yet)..."

    # No "checks skipped" degradation: the object checks used to run through a client pod that a
    # --dry-run against a scaled-down PMM did not have, so a dry run silently validated nothing.
    # rclone is local now — the checks either run, or preflight_checks already refused the run.
    validate_temp_pod_credentials || fail=1
    for _vrt_c in ${RESTORE_COMPONENTS}; do
        # Only what this restore will actually touch. A component that is selected but absent
        # from the backup is already a hard error in cmd_restore's explicit-selection gate.
        restore_do "${_vrt_c}" || continue
        _vrt_fn="validate_restore_$(printf '%s' "${_vrt_c}" | tr '-' '_')"
        "${_vrt_fn}" || fail=1
    done

    if [ "${fail}" -ne 0 ]; then
        log "ERROR" "Pre-restore validation FAILED. Nothing was changed; PMM is still running."
        return 1
    fi
    log "INFO" "Pre-restore validation passed — every selected component's source and target are present"
    return 0
}

# EXIT/INT/TERM handler: tear down the temp S3 client pod, then release owned locks.
restore_cleanup() {
    local _rc_sweep_ok=true
    # Sweep any temp mounter pods a signal (INT/TERM) may have interrupted mid-run. On normal
    # completion the per-ordinal loops already delete these, so this finds nothing; on an
    # interrupted run it prevents a leaked pod from holding an RWO data PVC (vmstorage-db /
    # pmm-storage), which would otherwise wedge the real pod on Multi-Attach at scale-up.
    #
    # ONLY if this run actually created one. The sweep is by LABEL, so an unconditional version
    # kills a DIFFERENT, live restore's pods mid-write: the EXIT trap is installed before
    # acquire_locks, so a second run aborting at the consent gate or on a held lock would run
    # this. TEMP_PODS_MARKER is the ownership proof, as the holder check is for release_locks.
    local _c
    if [ -n "${TEMP_PODS_MARKER}" ] && [ -e "${TEMP_PODS_MARKER}" ]; then
        _rc_sweep_ok=true
        for _c in vm-restore-temp pmm-srv-restore-temp; do
            kubectl delete pod -n "${NAMESPACE}" -l "app.kubernetes.io/component=${_c}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || _rc_sweep_ok=false
        done
        # The marker is consumed ONLY when the sweep actually issued its deletes. restore_cleanup
        # runs twice on a signal (the INT handler, then the EXIT trap), and that second pass is
        # the retry: if the first delete failed on an apiserver blip, dropping the marker
        # regardless left a temp pod attached to the RWO vmstorage-db PVC — which is the
        # Multi-Attach wedge this sweep exists to prevent.
        if [ "${_rc_sweep_ok}" = "true" ]; then
            [ -n "${TEMP_PODS_MARKER}" ] && rm -f "${TEMP_PODS_MARKER}" 2>/dev/null || true
        else
            log "WARN" "Temp-pod cleanup did not complete; keeping the marker so the next cleanup pass retries it"
        fi
    fi
    # The local copy of the manifest, reaped HERE rather than only on cmd_restore's two exit paths.
    # Every early `exit 1` between load_manifest and those paths — the explicit-selection gate, a
    # failed pre-flight, the non-interactive refusal, a failed key restore or scale-down — left one
    # behind, and a DR drill is exactly when an operator re-runs a restore repeatedly. The pod is
    # long-lived, so they accumulated. cmd_restore's own `rm -f` calls stay: they release it as soon
    # as it is genuinely done with, and a second rm is harmless.
    [ -n "${MANIFEST_FILE}" ] && rm -f "${MANIFEST_FILE}" 2>/dev/null || true
    release_locks
    return 0
}

################################################################################
# PMM scale down / up (restore happens with PMM down so nothing writes the DBs)
################################################################################
# The replica count PMM must be restored to: the live spec, else the count stashed on the prior
# scale-down (PMM already at 0 from an interrupted restore reads spec.replicas 0 and would never
# come back), else PMM_SERVER_REPLICAS.
#
# ONE resolver for all three callers, and it ALWAYS returns a number. A hand-edited
# `original-replicas=three` annotation otherwise reached `kubectl scale --replicas=three` and
# `while [ i -lt three ]`, which exits 2 — so the /srv loop body never ran and the component
# reported "No /srv archives found in backup".
pmm_replica_count() {   # <statefulset-name>
    _prc_n=$(kubectl get statefulset "$1" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    case "${_prc_n}" in ''|0|*[!0-9]*) _prc_n="" ;; esac
    if [ -z "${_prc_n}" ]; then
        _prc_n=$(kubectl get statefulset "$1" -n "${NAMESPACE}" \
            -o jsonpath="{.metadata.annotations['restore.pmm.percona.com/original-replicas']}" 2>/dev/null || echo "")
        case "${_prc_n}" in
            ''|0) _prc_n="" ;;
            *[!0-9]*)
                log "WARN" "PMM ${1}: the stashed original-replicas annotation ('${_prc_n}') is not a number; ignoring it" >&9
                _prc_n="" ;;
        esac
    fi
    if [ -z "${_prc_n}" ]; then
        # Report the fallback HERE, where it is actually known. A caller cannot infer it by
        # comparing the answer to PMM_SERVER_REPLICAS: an install that legitimately runs 3
        # replicas resolves to 3 from the live spec, and that comparison then warned "spec.replicas
        # is 0 and no stashed count" on every healthy restore — a false alarm in the one log an
        # operator reads during a DR.
        _prc_n="${PMM_SERVER_REPLICAS:-3}"
        case "${_prc_n}" in ''|*[!0-9]*) _prc_n=3 ;; esac   # PMM_SERVER_REPLICAS is env-supplied
        log "WARN" "PMM ${1}: neither spec.replicas nor a stashed count is usable; will restore to ${_prc_n} (override with PMM_SERVER_REPLICAS)" >&9
    fi
    printf '%s' "${_prc_n}"
}

scale_down_pmm() {
    PMM_STATEFULSET_NAME=$(kubectl get statefulset -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${PMM_STATEFULSET_NAME}" ]; then log "WARN" "PMM StatefulSet not found, skipping scale down"; return 0; fi
    # pmm_replica_count warns for itself when it has to fall back; do NOT try to detect that
    # here by comparing against PMM_SERVER_REPLICAS (see the note in the resolver).
    PMM_SAVED_REPLICAS=$(pmm_replica_count "${PMM_STATEFULSET_NAME}")
    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[DRY RUN] kubectl scale statefulset ${PMM_STATEFULSET_NAME} --replicas=0 (restore to: ${PMM_SAVED_REPLICAS})"
        return 0
    fi
    # Stash the count so an interrupted/re-run restore can recover the true original.
    kubectl annotate statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" "restore.pmm.percona.com/original-replicas=${PMM_SAVED_REPLICAS}" --overwrite >> "${LOG_FILE}" 2>&1 || true
    kubectl scale statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" --replicas=0 >> "${LOG_FILE}" 2>&1 || { log "ERROR" "Failed to scale down PMM"; return 1; }
    log "INFO" "Scaled down PMM ${PMM_STATEFULSET_NAME} to 0 (restore to ${PMM_SAVED_REPLICAS} on success)"
    wait_for_pods_gone "${NAMESPACE}" "${LABEL_PMM_SERVER}" || { log "ERROR" "PMM pods did not terminate"; return 1; }
    return 0
}

scale_up_pmm() {
    if [ -z "${PMM_STATEFULSET_NAME}" ] || [ -z "${PMM_SAVED_REPLICAS}" ]; then return 0; fi
    if [ "${DRY_RUN}" = "true" ]; then log "INFO" "[DRY RUN] kubectl scale statefulset ${PMM_STATEFULSET_NAME} --replicas=${PMM_SAVED_REPLICAS}"; return 0; fi
    kubectl scale statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" --replicas="${PMM_SAVED_REPLICAS}" >> "${LOG_FILE}" 2>&1 || { log "ERROR" "Failed to scale up PMM"; return 1; }
    log "INFO" "Scaled up PMM ${PMM_STATEFULSET_NAME} to ${PMM_SAVED_REPLICAS}; waiting for ready..."
    wait_for_pods_ready "${NAMESPACE}" "${LABEL_PMM_SERVER}" "${PMM_SAVED_REPLICAS}" || log "WARN" "PMM pods not ready in time (may still be starting)"
    return 0
}

################################################################################
# Encryption key (restored FIRST; restore aborts if it fails)
################################################################################
restore_encryption_key() {
    local tmp
    tmp=$(mktemp /tmp/enc.XXXXXX 2>/dev/null || echo "/tmp/enc.$$")
    store_read "$(comp_path encryption)/pg-encryption-key.yaml" > "${tmp}" 2>/dev/null || true
    if [ ! -s "${tmp}" ]; then log "ERROR" "[EncryptionKey] not found for ${BACKUP_NAME}"; rm -f "${tmp}"; return 1; fi
    # Verify against the sha256 the backup recorded, BEFORE the namespace rewrite below changes
    # the bytes. A truncated or corrupted key Secret applies cleanly and leaves PostgreSQL
    # undecryptable with no error anywhere — so this is the one place a content check is both
    # cheap and worth failing the run over. Older backups carry no sha256; those are skipped
    # rather than refused (no expectation is not a mismatch).
    local want_sha="" got_sha=""
    want_sha=$(mf_field encryption sha256)
    if [ -n "${want_sha}" ]; then
        got_sha=$(sha256_of "${tmp}")
        if [ -z "${got_sha}" ]; then
            log "WARN" "[EncryptionKey] No sha256 tool available; could not verify the key against the manifest's checksum"
        elif [ "${got_sha}" != "${want_sha}" ]; then
            log "ERROR" "[EncryptionKey] Checksum MISMATCH: manifest records $(printf '%.16s' "${want_sha}")..., read $(printf '%.16s' "${got_sha}")..."
            log "ERROR" "[EncryptionKey]   Refusing to apply a key that does not match the backup; restored PostgreSQL data would not decrypt."
            rm -f "${tmp}"; return 1
        else
            log "INFO" "[EncryptionKey] Checksum verified ($(printf '%.16s' "${got_sha}")...)"
        fi
    fi
    # THE gate: this is the only place store content is handed to the apiserver as a MANIFEST
    # rather than as data. Without it, anyone who can write the prefix could append a second
    # document — a privileged Pod, or a Secret overwriting any other in the namespace — and a
    # routine DR restore would create it, because `kubectl apply` runs as the backup SA.
    #
    # The sha256 above is NOT this control: its expected value comes from the same store-written
    # manifest, it is skipped when none is recorded, and it covers the pre-rewrite bytes.
    #
    # `-s` (slurp) is load-bearing. jq reads concatenated JSON as a STREAM and `-e` takes its
    # status from the LAST value, so an attacker object placed FIRST sails through an unslurped
    # `jq -e` (verified). Slurping makes it one array, so `length == 1` is the real check.
    if ! jq -e -s 'length == 1 and (.[0] | type == "object" and .kind == "Secret"
                   and .apiVersion == "v1" and .metadata.name == "pg-encryption-key")' \
                 "${tmp}" >/dev/null 2>&1; then
        log "ERROR" "[EncryptionKey] The stored key object is not a single v1 Secret named 'pg-encryption-key'."
        log "ERROR" "[EncryptionKey]   Refusing to apply it: this path creates whatever object the file describes,"
        log "ERROR" "[EncryptionKey]   so anything else here would be an object someone put in the backup store."
        rm -f "${tmp}"; return 1
    fi
    # The exported Secret carries the SOURCE namespace in its metadata, so applying it into a
    # different namespace fails ("the namespace from the object does not match"). Rewrite it to
    # the target namespace so the key is portable across namespaces (DR).
    #
    # With jq, not sed: the old `s/^\([ ]*\)namespace:[ ]*.*/` rewrote EVERY line that looked
    # like a namespace field anywhere in the file, which for an injected second object obligingly
    # retargeted it at the victim namespace too. jq changes exactly one field of the one object
    # the gate above just proved this is.
    # Also slurped, and explicitly `.[0]`: without it jq would map the filter over every value
    # in the stream and print them all, which is the second half of the same bypass.
    if ! jq -s --arg ns "${NAMESPACE}" '.[0] | .metadata.namespace = $ns' "${tmp}" > "${tmp}.ns" 2>/dev/null; then
        log "ERROR" "[EncryptionKey] Could not set the target namespace on the key Secret"
        rm -f "${tmp}" "${tmp}.ns"; return 1
    fi
    mv "${tmp}.ns" "${tmp}"
    if [ "${DRY_RUN}" = "true" ]; then log "INFO" "[EncryptionKey] [DRY RUN] kubectl apply -n ${NAMESPACE} -f <key from ${BACKUP_NAME}/encryption>"; rm -f "${tmp}"; return 0; fi
    if kubectl apply -f "${tmp}" -n "${NAMESPACE}" >> "${LOG_FILE}" 2>&1; then
        log "INFO" "[EncryptionKey] Restored"; rm -f "${tmp}"; return 0
    fi
    log "ERROR" "[EncryptionKey] kubectl apply failed"; rm -f "${tmp}"; return 1
}

################################################################################
# PostgreSQL — logical restore: stream each pg_dump back into the live primary via
# pg_restore --clean --if-exists (PMM is down, so nothing is writing). Works into
# any namespace/cluster; the target databases already exist (chart/operator create
# pmm-managed + grafana on deploy).
################################################################################
restore_postgresql() {
    local pg_pod dbs db rc fail=0
    pg_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PG_PRIMARY}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${pg_pod}" ]; then log "ERROR" "[PostgreSQL] Primary pod not found"; return 1; fi
    dbs="${MF_PG_DBS}"
    if [ -z "${dbs}" ]; then log "ERROR" "[PostgreSQL] No databases recorded in the manifest"; return 1; fi

    for db in ${dbs}; do
        if [ "${DRY_RUN}" = "true" ]; then
            log "INFO" "[PostgreSQL] [DRY RUN] store_read $(comp_display postgresql)/${db}.dump | pg_restore --clean --if-exists -d ${db} (in ${pg_pod})"
            continue
        fi
        rc=0
        log "INFO" "[PostgreSQL] Restoring database ${db} into ${pg_pod}..."
        local pr_out; pr_out=$(mktemp /tmp/pgrestore.XXXXXX 2>/dev/null || echo "/tmp/pgrestore.$$")
        local uri="$(comp_path postgresql)/${db}.dump"
        # Verify the dump exists and is non-empty BEFORE piping: the pipeline's status is
        # pg_restore's, so a missing object would otherwise surface only as an empty-input
        # pg_restore error indistinguishable from restore warnings. One arm for both targets.
        local dump_size
        dump_size=$(store_bytes "${uri}" 2>/dev/null || echo 0)
        if ! [ "${dump_size:-0}" -gt 0 ] 2>/dev/null; then
            log "ERROR" "[PostgreSQL] dump missing or empty: ${uri}"; fail=1; rm -f "${pr_out}"; continue
        fi
        store_read "${uri}" 2>>"${LOG_FILE}" \
            | timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${pg_pod}" -c database -- \
              pg_restore --clean --if-exists -U postgres -d "${db}" >"${pr_out}" 2>&1 || rc=$?
        cat "${pr_out}" >> "${LOG_FILE}" 2>/dev/null || true
        # pg_restore exits non-zero on warnings too (e.g. "does not exist, skipping" from --clean
        # on a fresh db) — but a non-zero exit WITH error lines is a real failure (empty input,
        # corrupt dump, permission errors) and must fail the restore, not warn-and-succeed.
        if [ ${rc} -eq 0 ]; then
            log "INFO" "[PostgreSQL] ✓ ${db} restored"
        elif grep -q 'error:' "${pr_out}" 2>/dev/null; then
            log "ERROR" "[PostgreSQL] ${db}: pg_restore FAILED (exit ${rc}); last errors:"
            grep 'error:' "${pr_out}" 2>/dev/null | tail -n 5 | append_to_log || true
            fail=1
        else
            log "WARN" "[PostgreSQL] ${db}: pg_restore exited ${rc} with warnings only (check the log)"
        fi
        rm -f "${pr_out}" 2>/dev/null || true
    done
    [ ${fail} -ne 0 ] && return 1
    log "INFO" "[PostgreSQL] Restore complete (${dbs})"
    return 0
}

################################################################################
# ClickHouse — restored in the LIVE clickhouse-backup sidecar (PMM is down):
#   s3     -> clickhouse-backup restore_remote --rm <name>   (downloads from S3)
#   shared -> untar <central>/<id>/clickhouse/<name>.tar.gz, then restore --rm
################################################################################
restore_clickhouse() {
    local ch_pod name
    ch_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_CH_POD}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${ch_pod}" ]; then log "ERROR" "[ClickHouse] No pod found"; return 1; fi
    name="${MF_CH_NAME}"
    if [ -z "${name}" ]; then log "ERROR" "[ClickHouse] No backup name in manifest"; return 1; fi

    # No separate dry-run block: pod_exec and pod_sh each print the command they would run, so
    # the preview cannot drift from the run (the old block spelled both out a second time).
    local rc=0
    if [ "${S3_ENABLED}" = "true" ]; then
        # clickhouse-backup has no "restore from <path>" argument — restore_remote <name> looks
        # the name up under the S3_BUCKET/S3_PATH baked into the sidecar's env at pod start. On
        # a cross-namespace/DR restore those point at the TARGET instance's own prefix, not at
        # the backup being restored, so they are redirected with the tool's own --env flag
        # ("override any environment variable via CLI parameter", verified on 2.8.0). IAM access
        # is bucket-wide already.
        log "INFO" "[ClickHouse] restore_remote --rm ${name} (from s3://$(ch_restore_bucket)/$(ch_restore_path), in ${ch_pod})..."
        pod_exec ClickHouse "${ch_pod}" clickhouse-backup "${KUBECTL_EXEC_TIMEOUT}" \
            clickhouse-backup restore_remote \
            --env "S3_BUCKET=$(ch_restore_bucket)" --env "S3_PATH=$(ch_restore_path)" \
            --rm "${name}" >>"${LOG_FILE}" 2>&1 || rc=$?
    else
        local tarball="$(comp_inpod clickhouse)/${name}.tar.gz"
        log "INFO" "[ClickHouse] untar ${tarball} + restore --rm ${name} (in ${ch_pod})..."
        # Tarball path and backup name as positional args, not interpolated: both are
        # manifest-derived (load_manifest charset-checks them), so this closes the same class
        # of hole as the pmm-server restore rather than relying on the gate alone.
        pod_sh ClickHouse "${ch_pod}" clickhouse-backup "${KUBECTL_EXEC_TIMEOUT}" \
            'mkdir -p /var/lib/clickhouse/backup && tar -xzf "$1" -C /var/lib/clickhouse/backup && clickhouse-backup restore --rm "$2"' \
            "${tarball}" "${name}" >>"${LOG_FILE}" 2>&1 || rc=$?
    fi
    if [ ${rc} -ne 0 ]; then log "ERROR" "[ClickHouse] restore failed (exit ${rc})"; return 1; fi
    [ "${DRY_RUN}" = "true" ] && return 0    # pod_exec/pod_sh only printed; nothing was restored
    log "INFO" "[ClickHouse] Restore complete"
    return 0
}

################################################################################
# VictoriaMetrics — per vmstorage pod, scale to 0 then run vmrestore in a temp pod
# that mounts the (released) vmstorage-db PVC.  -src is s3:// or fs://<central>.
################################################################################
# Static-cred env block for the temp pods (vmrestore + /srv restore) when a secret is
# configured; empty otherwise (IRSA / SA credential chain).
#
# A FUNCTION, not an inline assignment: the lines below are manifest CONTENT and must stay at
# 8/10 spaces however deeply the caller is nested. See DN-22; the unit tests pin the columns.
render_temp_pod_s3_keys_env() {
    [ -n "${S3_SECRET_NAME}" ] || return 0
    printf '%s' "
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: ${S3_SECRET_NAME}, key: ${S3_SECRET_ACCESS_KEY_KEY} } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: ${S3_SECRET_NAME}, key: ${S3_SECRET_SECRET_KEY_KEY} } }"
}

# ServiceAccount line for the temp pods, or empty. Same content-not-formatting rule: the two
# leading spaces put it at pod-spec level.
#
# The chart creates the default SA name only for IRSA (irsaRoleArn set); on the static-key path
# that SA does NOT exist, so assuming it would make every temp pod rejected at admission. Emit
# the line when either we are not using static keys (IRSA / SA credential-chain path), or the
# operator passed --s3-service-account explicitly (e.g. an SA carrying imagePullSecrets).
render_temp_pod_sa_line() {
    [ -n "${S3_SERVICE_ACCOUNT}" ] || return 0
    if [ -z "${S3_SECRET_NAME}" ] || [ "${S3_SA_EXPLICIT}" = "true" ]; then
        printf '%s' "  serviceAccountName: ${S3_SERVICE_ACCOUNT}"
    fi
}

# ONE creator for both temp restore pods: they differ in six values and shared every other line.
# Both hold an RWO data PVC while its owner is scaled to 0, so a fix applied to one and not the
# other strands a real volume and wedges the owner on Multi-Attach at scale-up (DN-46).
#
#   create_temp_restore_pod <pod> <pvc> <image> <role> <tag>
#
# <role> is 'vm' or 'pmm'; <tag> is the log prefix.
create_temp_restore_pod() {
    local restore_pod="$1" pvc="$2" image="$3" role="$4" tag="$5"
    local sa_line="" central_mount="" central_vol="" env_block="" apply_out
    local label="" ctr="" mount_path="" vol_name="" sec_ctx=""
    if [ "${role}" = "vm" ]; then
        label="vm-restore-temp"; ctr="vmrestore"; vol_name="vmstorage-db"; mount_path="/vmstorage-data"
        # No endpoint env: vmrestore does not read endpoint env vars, it takes
        # -customS3Endpoint as a flag.
        [ "${S3_ENABLED}" = "true" ] && env_block="      env:
        - name: AWS_REGION
          value: \"${S3_REGION}\"${TEMP_POD_S3_KEYS_ENV}"
    else
        label="pmm-srv-restore-temp"; ctr="srv-restore"; vol_name="pmm-storage"; mount_path="/srv"
        # Root, so it can replace any file in /srv and drop /srv/ha (DN-30).
        sec_ctx="  securityContext:
    runAsUser: 0
    fsGroup: 0"
        [ "${S3_ENABLED}" = "true" ] && env_block="      env:
$(render_rclone_s3_env)"
    fi
    if [ "${S3_ENABLED}" = "true" ]; then
        sa_line="${TEMP_POD_SA_LINE}"
    else
        central_mount="        - name: central-backup-storage
          mountPath: ${SHARED_MOUNT_PATH}
          readOnly: true"
        central_vol="    - name: central-backup-storage
      persistentVolumeClaim:
        claimName: ${CENTRAL_BACKUP_PVC}"
    fi
    clear_leftover_temp_pod "${restore_pod}" "${tag}"
    apply_out=$(mktemp /tmp/podapply.XXXXXX 2>/dev/null || echo "/tmp/podapply.$$")
    [ -n "${TEMP_PODS_MARKER}" ] && : > "${TEMP_PODS_MARKER}" || true
    # karpenter.sh/do-not-disrupt: this pod holds an RWO data PVC while its owner is scaled
    # down, and a consolidation eviction mid-restore truncates that ordinal's data. Harmless
    # outside Karpenter / EKS Auto Mode.
    if ! kubectl create -f - -n "${NAMESPACE}" >"${apply_out}" 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${restore_pod}
  labels:
    app.kubernetes.io/component: ${label}
  annotations:
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
${sa_line}
${sec_ctx}
  containers:
    - name: ${ctr}
      image: ${image}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
${env_block}
      volumeMounts:
        - name: ${vol_name}
          mountPath: ${mount_path}
${central_mount}
  volumes:
    - name: ${vol_name}
      persistentVolumeClaim:
        claimName: ${pvc}
${central_vol}
EOF
    then
        cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
        log "ERROR" "[${tag}] Failed to create restore pod ${restore_pod} (PVC: ${pvc})"; return 1
    fi
    cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
    wait_for_pod_ready_by_name "${NAMESPACE}" "${restore_pod}" 300 \
        || { log "ERROR" "[${tag}] Restore pod ${restore_pod} not ready"; return 1; }
    return 0
}

create_vm_restore_pod()  { create_temp_restore_pod "$1" "$2" "$3" vm  VictoriaMetrics; }

# Clear a leftover temp pod of the SAME NAME before creating one: a restore killed between
# create and delete (OOM, eviction, SIGKILL) leaves the pod behind, still holding the RWO data
# PVC. Delete-and-recreate, not `kubectl apply` — apply PATCHes the survivor, which needs a
# `patch` verb the backup Role does not grant and cannot work anyway, since almost every Pod
# field is immutable.
clear_leftover_temp_pod() {   # <pod-name> <log-tag>
    k8s_object_state pod "$1"
    case $? in
        0) log "WARN" "[$2] A temp pod named $1 is left over from an earlier run (it may still hold the data PVC); deleting it first"
           delete_temp_restore_pod "$1" ;;
        1) ;;   # not there: the normal case
        *) log "WARN" "[$2] Could not check whether a temp pod named $1 already exists; the create below will say so if it does" ;;
    esac
    return 0
}

# Deletes ANY temp restore pod (vm-restore-* and pmm-srv-restore-*): both paths share it,
# so the name must not imply otherwise — a VM-specific tweak here would silently leak a
# /srv pod still holding the RWO pmm-storage PVC and wedge PMM on Multi-Attach at scale-up.
delete_temp_restore_pod() {
    kubectl delete pod "$1" -n "${NAMESPACE}" --grace-period=10 --wait=false 2>&1 | append_to_log || true
    wait_for_pod_gone_by_name "${NAMESPACE}" "$1" 120 || true
}

# Backup subdir for a target ordinal, release-name independent (DN-18), charset-gated because
# the name is bucket-controlled and reaches a root pod's shell (DN-17).
#
# Returns rc 0 ALWAYS, printing the match or nothing: callers assign from this under `set -e`
# and then test for empty, so a non-zero return would abort the component instead.
src_subdir_for_ord() {   # <component> <ordinal>
    _ssfo_out=$(store_list_dirs "$(comp_path "$1")" 2>/dev/null) || _ssfo_out=""
    _ssfo_hit=""
    # Fed by a HERE-DOC, not a pipe: `while read` on the right of a pipe runs in a subshell, so
    # the match would not survive the loop. And read line-by-line rather than
    # `for c in $(...)` — that word-splits on IFS, so a key containing a space would arrive as
    # separate fragments and a fragment could pass the charset gate that the whole name fails.
    while IFS= read -r _ssfo_c; do
        [ -n "${_ssfo_c}" ] || continue
        case "${_ssfo_c}" in
            *[!A-Za-z0-9_.-]*)
                log "WARN" "[$1] Ignoring backup subdirectory '${_ssfo_c}': it contains characters outside A-Z a-z 0-9 _ . - and would be interpolated into a command run inside a pod"
                continue ;;
        esac
        # Literal suffix match, not `grep -E "\-${2}$"`: keeps the ordinal out of a regex too.
        case "${_ssfo_c}" in *-"$2") ;; *) continue ;; esac
        _ssfo_hit="${_ssfo_c}"; break
    done <<EOF
${_ssfo_out}
EOF
    [ -n "${_ssfo_hit}" ] && printf '%s\n' "${_ssfo_hit}"
    return 0
}

vm_src_subdir_for_ord() { src_subdir_for_ord victoriametrics "$1"; }

# Count vmstorage ordinals in the backup. Restoring an N-shard backup into a different number
# of target pods either drops source shards or fails after a full run, so this fails fast.
#
# The LISTING's status is preserved: `... | grep -c` took its status from grep, which exits 1
# on a zero count, so an empty or unlistable source made this return non-zero — an unguarded
# assignment under `set -e`, killing the component with nothing logged and PMM already at 0.
vm_src_ordinal_count() {
    _vsoc_out=$(store_list_dirs "$(comp_path victoriametrics)" 2>/dev/null) || return $?
    printf '%s\n' "${_vsoc_out}" | grep -c '[^[:space:]]' || true
}

vm_src_for_pod() {
    local pod="$1" name="vm_backup_${BACKUP_NAME#backup_}" ord sub
    ord="${pod##*-}"                        # trailing ordinal of the target vmstorage pod
    sub=$(vm_src_subdir_for_ord "${ord}")   # backup dir for that ordinal (source release name)
    # No silent fallback to the target pod's own name: an empty lookup means the S3/fs
    # listing failed (e.g. no rclone client) or the backup lacks this ordinal — restoring
    # from a guessed path produced a wasted full run once already. Caller must handle rc=1.
    [ -z "${sub}" ] && return 1
    # vmrestore's -src takes a scheme, so this is one of the few places the target genuinely
    # differs in more than access method: s3:// for the bucket, fs:// for the mounted volume
    # (as the vmstorage POD sees it, hence comp_inpod).
    if [ "${S3_ENABLED}" = "true" ]; then
        echo "$(comp_display victoriametrics)/${sub}/${name}"
    else
        echo "fs://$(comp_inpod victoriametrics)/${sub}/${name}"
    fi
}

restore_victoriametrics() {
    local vmstorage_pods vmcluster_name original_vminsert original_vmstorage first_vm_pod vmrestore_image
    local _vs_old=""
    vmstorage_pods=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_VM_STORAGE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${vmstorage_pods}" ]; then log "ERROR" "[VictoriaMetrics] No vmstorage pods found"; return 1; fi
    vmcluster_name=$(kubectl get vmcluster -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${vmcluster_name}" ]; then log "ERROR" "[VictoriaMetrics] No VMCluster found; cannot scale safely"; return 1; fi

    # Fail fast on a shard-count mismatch, BEFORE scaling anything down (VM restore is
    # ordinal-mapped: each target vmstorage pod restores from the backup dir with the matching
    # ordinal). A mismatch would either drop source shards (source>target) or waste a full run
    # and then fail (target>source). An empty src count = listing unavailable; the per-ordinal
    # loop still hard-fails, so don't block on it here.
    local vm_target_count vm_src_count
    vm_target_count=$(echo "${vmstorage_pods}" | wc -w | tr -d ' ')
    # Empty = the listing failed; the per-ordinal loop below still hard-fails, so don't
    # abort here (and never let a failed count kill the run under set -e).
    vm_src_count=$(vm_src_ordinal_count) || vm_src_count=""
    if [ -n "${vm_src_count}" ] && [ "${vm_src_count}" -gt 0 ] 2>/dev/null && [ "${vm_src_count}" != "${vm_target_count}" ]; then
        log "ERROR" "[VictoriaMetrics] Shard-count mismatch: backup has ${vm_src_count} vmstorage ordinal(s), target has ${vm_target_count}. Restore would drop or miss shards. Set the target vmstorage replicaCount to ${vm_src_count} to match the backup, then retry. Aborting before any scale-down."
        return 1
    fi
    original_vminsert=$(kubectl get vmcluster "${vmcluster_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.vminsert.replicaCount}' 2>/dev/null || echo "1")
    original_vmstorage=$(kubectl get vmcluster "${vmcluster_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.vmstorage.replicaCount}' 2>/dev/null || echo "1")
    # spec.replicaCount may be UNSET (operator default): kubectl then exits 0 with empty
    # output and the '|| echo 1' never fires — an empty value would render an invalid
    # scale-back patch ({"replicaCount":}) and leave the cluster at 0. Fall back to the
    # live vmstorage pod count / 1 for vminsert (same guard vmselect already has).
    [ -z "${original_vmstorage}" ] && original_vmstorage=$(echo "${vmstorage_pods}" | wc -w | tr -d ' ')
    [ -z "${original_vminsert}" ] && original_vminsert=1
    first_vm_pod=$(echo "${vmstorage_pods}" | awk '{print $1}')
    # Status captured explicitly: get_vmrestore_image can refuse now (it no longer guesses
    # ":latest"), and a bare assignment from a failing `$( )` aborts the whole run under `set -e`.
    # Normally already proven by the pre-flight gate; still checked here, before any scale-down.
    if ! vmrestore_image=$(get_vmrestore_image "${first_vm_pod}") || [ -z "${vmrestore_image}" ]; then
        log "ERROR" "[VictoriaMetrics] No vmrestore image: ${first_vm_pod} has no 'vmrestore' container and VMRESTORE_IMAGE is unset."
        log "ERROR" "[VictoriaMetrics]   Set victoriaMetrics.vmstorage.backup.restoreImage, or VMRESTORE_IMAGE=<image>. Aborting before any scale-down."
        return 1
    fi
    [ "${S3_ENABLED}" = "true" ] || resolve_central_backup_pvc || return 1

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[VictoriaMetrics] [DRY RUN] scale vminsert/vmstorage to 0 (vmcluster ${vmcluster_name})"
        local pod
        for pod in ${vmstorage_pods}; do
            log "INFO" "[VictoriaMetrics] [DRY RUN]   ${pod}: temp pod vmrestore -src=$(vm_src_for_pod "${pod}") -> $(vmstorage_pvc_name "${pod}")"
        done
        log "INFO" "[VictoriaMetrics] [DRY RUN] scale vmstorage->${original_vmstorage}, vminsert->${original_vminsert}"
        return 0
    fi

    log "INFO" "[VictoriaMetrics] Scaling vminsert+vmstorage to 0 (vmrestore needs exclusive PVC access)..."
    kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge \
        -p '{"spec":{"vminsert":{"replicaCount":0},"vmstorage":{"replicaCount":0}}}' 2>&1 | append_to_log || true
    # Soft wait: vminsert holds no PVCs — it is only scaled down to stop ingestion, and a
    # pod stuck Terminating cannot write once vmstorage (strict wait below) is gone.
    wait_for_pods_gone "${NAMESPACE}" "app.kubernetes.io/name=vminsert" 120 soft || log "WARN" "[VictoriaMetrics] vminsert not gone in time, continuing (non-blocking)"
    if ! wait_for_pods_gone "${NAMESPACE}" "${LABEL_VM_STORAGE}" 300; then
        log "ERROR" "[VictoriaMetrics] vmstorage did not terminate; restoring replica counts and aborting"
        kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"vmstorage":{"replicaCount":'${original_vmstorage}'},"vminsert":{"replicaCount":'${original_vminsert}'}}}' 2>&1 | append_to_log || true
        return 1
    fi

    local restored=0 planned=0 pod restore_pod pvc src rc exec_out
    # Non-AWS S3-compatible storage: endpoint must reach vmrestore as a flag (empty for AWS).
    local vm_endpoint_flag=""; vm_endpoint_flag=$(vm_endpoint_arg)
    for pod in ${vmstorage_pods}; do
        planned=$((planned + 1))
        restore_pod="vm-restore-${pod}"; pvc=$(vmstorage_pvc_name "${pod}")
        if ! src=$(vm_src_for_pod "${pod}") || [ -z "${src}" ]; then
            log "ERROR" "[VictoriaMetrics] No source dir for ordinal ${pod##*-} under ${BACKUP_NAME}/victoriametrics/ (S3 listing failed or backup lacks this ordinal)"
            continue
        fi
        log "INFO" "[VictoriaMetrics] Restoring ${pod} from ${src} via ${restore_pod}..."
        if ! create_vm_restore_pod "${restore_pod}" "${pvc}" "${vmrestore_image}"; then
            delete_temp_restore_pod "${restore_pod}"; continue
        fi
        timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -c vmrestore -- rm -f /vmstorage-data/flock.lock 2>/dev/null || true
        exec_out=$(mktemp /tmp/vmrestore.XXXXXX 2>/dev/null || echo "/tmp/vmrestore.$$"); rc=0
        # -loggerLevel=WARN silences vmrestore's per-part "downloading/deleting" info spam; its
        # full output still goes to the log FILE (not the console). On failure we surface the tail.
        timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -c vmrestore -- \
            /vmrestore-prod -src="${src}" -storageDataPath=/vmstorage-data ${vm_endpoint_flag} -concurrency=10 -loggerLevel=WARN >"${exec_out}" 2>&1 || rc=$?
        cat "${exec_out}" >> "${LOG_FILE}" 2>/dev/null || true
        delete_temp_restore_pod "${restore_pod}"
        if [ ${rc} -ne 0 ]; then
            log "ERROR" "[VictoriaMetrics] vmrestore failed on ${pod} (exit ${rc})"
            tail -n 20 "${exec_out}" 2>/dev/null | append_to_log || true
            rm -f "${exec_out}"; continue
        fi
        rm -f "${exec_out}"
        log "INFO" "[VictoriaMetrics] ✓ ${pod} restored"; restored=$((restored + 1))
    done

    log "INFO" "[VictoriaMetrics] Scaling vmstorage->${original_vmstorage}, vminsert->${original_vminsert}..."
    # Track scale-back health: masking it (WARN + || true) let a run report success with the VM
    # tier left at 0 replicas after a transient patch/readiness failure. vmstorage NOT coming back
    # is a component failure, checked at the final gate below.
    local vm_scaleback_ok=true
    kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"vmstorage":{"replicaCount":'${original_vmstorage}'}}}' 2>&1 | append_to_log || true
    wait_for_pods_ready "${NAMESPACE}" "${LABEL_VM_STORAGE}" "${original_vmstorage}" 300 || { log "ERROR" "[VictoriaMetrics] vmstorage did not return to ${original_vmstorage} ready replica(s) after restore"; vm_scaleback_ok=false; }
    kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"vminsert":{"replicaCount":'${original_vminsert}'}}}' 2>&1 | append_to_log || true

    # vmstorage came back with NEW pod IPs; vmselect holds persistent connections to the OLD IPs
    # (we bounce vminsert+vmstorage but not vmselect), which black-hole queries afterwards
    # ("cannot flush labelName to conn: write: connection timed out" / isPartial results in the UI).
    # Bounce vmselect so it re-resolves and reconnects to the live vmstorage nodes.
    local original_vmselect
    original_vmselect=$(kubectl get vmcluster "${vmcluster_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.vmselect.replicaCount}' 2>/dev/null || echo "1")
    [ -z "${original_vmselect}" ] && original_vmselect=1
    log "INFO" "[VictoriaMetrics] Bouncing vmselect to reconnect to the restored vmstorage nodes..."
    # Capture the names BEFORE deleting: a Terminating pod still reports Ready=True, so a plain
    # readiness wait here could be satisfied by the pods being deleted and return before a
    # single replacement had started — leaving vmselect serving from the old, pre-restore view
    # and reopening the isPartial window this bounce exists to close (DN-29).
    # A failed read here would yield an EMPTY old-set, which every later poll trivially
    # satisfies — disabling the guard entirely. Fall back to the plain readiness wait instead,
    # which is what this replaced and is still better than a wait that cannot fail.
    _vs_old=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=vmselect -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null) || _vs_old=""
    kubectl delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=vmselect 2>&1 | append_to_log || true
    if [ -n "${_vs_old}" ]; then
        wait_for_pods_replaced "${NAMESPACE}" "app.kubernetes.io/name=vmselect" "${_vs_old}" "${original_vmselect}" 180 \
            || log "WARN" "[VictoriaMetrics] vmselect not replaced/ready in time after bounce"
    else
        log "WARN" "[VictoriaMetrics] Could not read the pre-bounce vmselect pods; falling back to a plain readiness wait"
        wait_for_pods_ready "${NAMESPACE}" "app.kubernetes.io/name=vmselect" "${original_vmselect}" 180 \
            || log "WARN" "[VictoriaMetrics] vmselect not ready in time after bounce"
    fi

    if [ ${restored} -eq 0 ]; then log "ERROR" "[VictoriaMetrics] Restore failed: 0/${planned} pods"; return 1; fi
    # Partial is FAILURE, mirroring the backup side's fail-on-partial: a half-restored
    # vmstorage tier serves mixed-vintage data that automation must not read as success.
    if [ ${restored} -lt ${planned} ]; then
        log "ERROR" "[VictoriaMetrics] Partial restore: ${restored}/${planned} pods — treating as FAILED"
        return 1
    fi
    if [ "${vm_scaleback_ok}" != "true" ]; then
        log "ERROR" "[VictoriaMetrics] Data restored to ${restored}/${planned} pods, but the vmstorage tier did not come back to ${original_vmstorage} ready replica(s) — treating as FAILED (check vmstorage / scale it back up manually)."
        return 1
    fi
    log "INFO" "[VictoriaMetrics] Restore complete (${restored}/${planned} pods)"
    return 0
}

################################################################################
# PMM /srv — restored into each pmm-storage PVC via a TEMP pod while PMM is scaled to 0, so
# PMM comes up LAST against /srv and the restored DBs already in place. Ordinal-mapped like VM
# (DN-18); /srv/ha is dropped so PMM re-bootstraps its memberlist (DN-30).
################################################################################
# Backup's pmm-server subdir for a target ordinal (trailing -N), release-name independent.
# Charset-gated by src_subdir_for_ord — this is the value that reaches a root temp pod.
pmm_src_subdir_for_ord() { src_subdir_for_ord pmm-server "$1"; }

# Temp pod mounting a pmm-storage PVC at /srv (PMM is down, so the RWO PVC is free). Runs as
# root so it can replace any file and drop /srv/ha (DN-30). shared: also mounts the central
# volume. s3: runs the rclone image under the s3 SA with env-auth.
#
# Holds an RWO data PVC, so it opts out of consolidation-driven disruption (DN-19).
# On path traversal: no --no-absolute-filenames is passed because BusyBox tar has no such flag
# and does not need one — verified, see DN-17's neighbours in the review; both tar
# implementations strip '../' and a leading '/' by default.
create_pmm_restore_pod() { create_temp_restore_pod "$1" "$2" "$3" pmm PMMServer; }

restore_pmm_server() {
    # NB: all locals initialised — script runs under `set -u`, so a bare `local x` then `[ -z "$x" ]`
    # would abort with "parameter not set".
    local sts="" replicas="" image="" i ord pvc src_subdir restore_pod rc restored=0 count=0
    sts="${PMM_STATEFULSET_NAME:-}"
    if [ -z "${sts}" ]; then sts=$(kubectl get statefulset -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); fi
    if [ -z "${sts}" ]; then log "ERROR" "[PMMServer] PMM StatefulSet not found"; return 1; fi
    # scale_down_pmm's value if it ran (PMM is at 0 by now, so the live spec would read 0),
    # otherwise the shared resolver. Either way the result is guaranteed numeric.
    replicas="${PMM_SAVED_REPLICAS:-}"
    case "${replicas}" in ''|0|*[!0-9]*) replicas=$(pmm_replica_count "${sts}") ;; esac
    [ "${S3_ENABLED}" = "true" ] || resolve_central_backup_pvc || return 1

    # Both resolved in the parent, before the loop: the accessors inside it cannot log or query.
    # Normally no-ops, because validate_restore_targets already resolved both for this run — which
    # is what makes the gate's checks match what this function actually uses.
    resolve_pmm_storage_pvc_prefix "${sts}" || return 1
    resolve_pmm_restore_image "${sts}" || return 1
    image=$(pmm_restore_image) || { log "ERROR" "[PMMServer] no /srv restore pod image was resolved"; return 1; }
    i=0
    while [ "${i}" -lt "${replicas}" ]; do
        ord="${i}"; i=$((i + 1)); count=$((count + 1))
        # No failed-pod accumulator here, deliberately: ${count} is incremented and ${restored}
        # is not, so the partial-is-failure gate at the end already reports this ordinal. The
        # obvious `failed_pods` is `local` to the two BACKUP functions and does not exist here,
        # so appending to it aborts the run under `set -u` — right after scale_down_pmm.
        pvc=$(pmm_storage_pvc_name "${sts}" "${ord}") || { log "ERROR" "[PMMServer] ord ${ord}: could not build the PVC name"; continue; }
        src_subdir=$(pmm_src_subdir_for_ord "${ord}")
        if [ "${DRY_RUN}" = "true" ]; then
            log "INFO" "[PMMServer] [DRY RUN] ord ${ord}: temp pod mounts ${pvc} at /srv; extract pmm-server/${src_subdir:-<dir ending -${ord}>}/srv.tar.gz then drop /srv/ha"
            continue
        fi
        if [ -z "${src_subdir}" ]; then log "WARN" "[PMMServer] No backup /srv dir for ordinal ${ord}; skipping"; continue; fi
        restore_pod="pmm-srv-restore-${sts}-${ord}"
        if ! create_pmm_restore_pod "${restore_pod}" "${pvc}" "${image}"; then delete_temp_restore_pod "${restore_pod}"; continue; fi
        rc=0
        # The source path is passed as a POSITIONAL ARGUMENT to `sh -c`, never interpolated into
        # the script text. src_subdir_for_ord already refuses names outside [A-Za-z0-9_.-], so
        # this is defence in depth — but it is the cheap kind: the script body becomes a fixed
        # string, so no value can alter what runs, and it matches how the pre-flight gate
        # already tests the ClickHouse tarball. A shell is still needed for the pipe / the && .
        if [ "${S3_ENABLED}" = "true" ]; then
            local uri="$(comp_path pmm-server)/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from S3..."
            pod_sh PMMServer "${restore_pod}" - "${KUBECTL_EXEC_TIMEOUT}" \
                'rclone cat --s3-no-check-bucket "$1" | tar -xzf - -C /srv --no-same-owner && rm -rf /srv/ha' \
                "${uri}" >>"${LOG_FILE}" 2>&1 || rc=$?
        else
            local tb="$(comp_inpod pmm-server)/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from ${tb}..."
            pod_sh PMMServer "${restore_pod}" - "${KUBECTL_EXEC_TIMEOUT}" \
                'tar -xzf "$1" -C /srv --no-same-owner && rm -rf /srv/ha' \
                "${tb}" >>"${LOG_FILE}" 2>&1 || rc=$?
        fi
        delete_temp_restore_pod "${restore_pod}"
        if [ ${rc} -eq 0 ]; then log "INFO" "[PMMServer] ✓ ord ${ord} /srv restored (HA raft reset)"; restored=$((restored + 1)); else log "ERROR" "[PMMServer] /srv restore failed for ord ${ord} (exit ${rc})"; fi
    done
    [ "${DRY_RUN}" = "true" ] && return 0

    if [ ${count} -eq 0 ]; then log "WARN" "[PMMServer] No /srv archives found in backup"; return 1; fi
    if [ ${restored} -eq 0 ]; then log "ERROR" "[PMMServer] Restore failed: 0/${count}"; return 1; fi
    # Partial is FAILURE (mirrors backup's fail-on-partial): one replica booting with stale
    # /srv while the others got the restored one is an inconsistent HA cluster.
    if [ ${restored} -lt ${count} ]; then
        log "ERROR" "[PMMServer] Partial restore: ${restored}/${count} — treating as FAILED"
        return 1
    fi
    log "INFO" "[PMMServer] /srv restore complete (${restored}/${count}); PMM will load it on start"
    return 0
}

# One summary row per component, from the table. The encryption key reads "Yes/No" rather than
# "Yes/Failed" because a failed key aborts the run long before this point.
restore_summary_rows() {
    _rsr_c="" _rsr_state=""
    for _rsr_c in ${RESTORE_COMPONENTS}; do
        if ! comp_on "${_rsr_c}" 5; then _rsr_state="⊘ Skipped"
        elif restore_ok "${_rsr_c}"; then _rsr_state="✓ Yes"
        else _rsr_state="✗ Failed"; fi
        log "INFO" "$(printf '  - %-18s %s' "$(comp_label "${_rsr_c}"):" "${_rsr_state}")"
    done
    return 0
}

# Is this operation running its components concurrently? $1 is the SUBCOMMAND'S default, used
# when --parallel/--sequential were not given (see PARALLEL).
parallel_enabled() { [ "${PARALLEL:-$1}" = "true" ]; }

# One component restore in its own subshell: the EXIT trap is dropped so a child can never
# release the parent's locks, and the status goes to a file because a subshell cannot assign to
# its parent. Named at top level rather than inlined, so the `&` call site stays readable.
_restore_child() {   # <component-key> <tmpdir>
    trap - EXIT INT TERM
    if "restore_$(printf '%s' "$1" | tr '-' '_')"; then echo 0 > "$2/$1.rc"; else echo 1 > "$2/$1.rc"; fi
}

# The backup equivalent, and it has to carry MORE than a status code. A restore child reports
# one byte; a backup component produces a whole result object — sizes, durations, locations, the
# per-object file census — and result_set writes that into RESULTS_JSON, which a subshell cannot
# hand back to its parent. So the child serialises its own results and the parent merges them
# after `wait`, which is also what keeps record_backup_result (and the counters it updates) in
# the parent where they belong.
#
# RESULTS_JSON is reset first so the file holds exactly this component's entry and the merge
# below cannot resurrect a sibling's.
_backup_child() {   # <component-key> <tmpdir>
    trap - EXIT INT TERM
    _bch_c="$1" _bch_d="$2" _bch_rc=0
    RESULTS_JSON='{}'
    "backup_$(printf '%s' "${_bch_c}" | tr '-' '_')" || _bch_rc=$?
    # Results first, status last: the status file is what the parent treats as "this child got
    # far enough to report", so it must not exist before the results it refers to.
    printf '%s' "${RESULTS_JSON}" > "${_bch_d}/${_bch_c}.json"
    echo "${_bch_rc}" > "${_bch_d}/${_bch_c}.rc"
}

restore_verification() {
    log "INFO" "Verifying restore..."
    if [ "${RESTORE_POSTGRESQL}" = "true" ]; then
        local pg; pg=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PG_PRIMARY}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "${pg}" ]; then
            timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg}" -c database -- pg_isready -U postgres >> "${LOG_FILE}" 2>&1 \
                && log "INFO" "[PostgreSQL] Primary ready" || log "WARN" "[PostgreSQL] Primary not ready yet"
        fi
    fi
    # grep -c already prints 0 on no match (while exiting 1) — an '|| echo 0' fallback
    # would print a SECOND zero and split the log line. '|| true' only pacifies set -e.
    [ "${RESTORE_CLICKHOUSE}" = "true" ] && log "INFO" "[ClickHouse] $(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_CH_POD}" --no-headers 2>/dev/null | grep -c Running || true) pod(s) running"
    [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && log "INFO" "[VictoriaMetrics] $(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_VM_STORAGE}" --no-headers 2>/dev/null | wc -l | tr -d ' ') vmstorage pod(s)"
    [ "${RESTORE_PMM_SERVER}" = "true" ] && log "INFO" "[PMMServer] $(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" --no-headers 2>/dev/null | grep -c Running || true) PMM pod(s) running"
    return 0
}

################################################################################
# 9. Retention — delete every component path for ids older than BACKUP_RETENTION days,
# plus its manifest, on either target.
#
# Age comes from the id's own timestamp, not object mtimes (DN-07). A backup is a correlation,
# not a directory, so atomicity is this function's job: all of an id's components go or none
# do, and the manifest is deleted LAST (DN-06).
#
# A bug here destroys backups irreversibly — the guardrails and why each exists are in DN-08.
################################################################################
# These bound DESTRUCTION, so they must be usable numbers. Both are compared with `-ge` against
# a counter starting at zero, so a value of 0 breaks the purge loop before the first delete
# while still reporting success — retention stops for good and nothing says so (DN-40). ZERO is
# therefore rejected, not treated as "unlimited", which is the natural guess and the reason it
# must be refused. Leading zeros are stripped BEFORE the clamp: "00" survives a digits-only
# check and only becomes "0" once normalised.
S3_PRUNE_MAX_PER_RUN=$(echo "${S3_PRUNE_MAX_PER_RUN:-50}" | sed 's/^0*\([0-9]\)/\1/')
numeric_env S3_PRUNE_MAX_PER_RUN 50
# Set whenever the sweep declines to delete something it otherwise would have. A FLAG, not a
# return code: cleanup_old_backups is also called from cmd_backup, where a non-zero return would
# abort a run that has already succeeded. cmd_prune reports it; cmd_backup ignores it.
PRUNE_REFUSED=0

# Whole-sweep wall clock. The sweep also runs inside cmd_backup's lock window, under the
# CronJob's activeDeadlineSeconds, so an unbounded sweep gets the Job killed and leaves the next
# run blocked on locks this one still holds. Clamped like the cap above, zero included.
S3_PRUNE_MAX_SECONDS=$(echo "${S3_PRUNE_MAX_SECONDS:-900}" | sed 's/^0*\([0-9]\)/\1/')
numeric_env S3_PRUNE_MAX_SECONDS 900

# ---- ClickHouse incremental chains ---------------------------------------------------
# An incremental is a diff against an earlier REMOTE backup, so expiring a base breaks every
# incremental built on it, and the pre-restore gate does not catch it (DN-09). Returns the
# ClickHouse names a RETAINED backup still needs, transitively.
#
# Failing closed here is NARROW on purpose — a blanket failure turns ClickHouse retention off
# permanently behind one WARN, and the bucket grows without bound:
#   * unreadable manifest of a KEPT id  -> fatal (ERROR): which base it needs is unknowable, so
#                                          any expired ClickHouse backup might be it
#   * unreadable manifest of a PURGED id -> not our problem: the purge loop defers that id anyway
#   * a required name with no edge       -> its backup is already gone, so the chain is ALREADY
#                                          broken; treat it as a leaf rather than freezing
#                                          retention forever over damage already done
#
# $1 = all catalog ids, $2 = the ids about to be purged. Prints required names, one per line.
ch_chain_required_names() {
    _ccrn_expired=" $2 "
    _ccrn_edges=""      # "<name> <base-or-->" per line, for every id that carries ClickHouse
    _ccrn_req=""        # space-delimited set of required names
    _ccrn_id="" _ccrn_mf="" _ccrn_name="" _ccrn_base="" _ccrn_kept=""
    for _ccrn_id in $1; do
        case "${_ccrn_expired}" in
            *" ${_ccrn_id} "*) _ccrn_kept=false ;;
            *) _ccrn_kept=true ;;
        esac
        _ccrn_mf=$(catalog_manifest "${_ccrn_id}" 2>/dev/null) || _ccrn_mf=""
        if [ -z "${_ccrn_mf}" ] || ! printf '%s' "${_ccrn_mf}" | jq -e . >/dev/null 2>&1; then
            if [ "${_ccrn_kept}" = "true" ]; then
                log "ERROR" "[Retention] Cannot read the manifest of retained backup '${_ccrn_id}'; the ClickHouse incremental chain cannot be verified from it." >&9
                return 1
            fi
            # An expired id: the purge loop will refuse it on the same grounds. Not our problem.
            continue
        fi
        _ccrn_name=$(printf '%s' "${_ccrn_mf}" | jq -r '.components.clickhouse.name // empty' 2>/dev/null || true)
        [ -n "${_ccrn_name}" ] || continue          # no ClickHouse in this backup
        _ccrn_base=$(printf '%s' "${_ccrn_mf}" | jq -r '.components.clickhouse.base // empty' 2>/dev/null || true)
        _ccrn_edges="${_ccrn_edges}${_ccrn_name} ${_ccrn_base:--}
"
        # Anything NOT about to be purged is being kept, so whatever it needs must survive.
        [ "${_ccrn_kept}" = "true" ] && _ccrn_req="${_ccrn_req} ${_ccrn_name}"
    done
    [ -n "${_ccrn_edges}" ] || return 0             # no ClickHouse anywhere: nothing to protect

    # Transitive closure. `for` expands its list once, so newly discovered bases are picked up
    # on the next round; the round count is bounded by the number of edges so a cycle (which a
    # base being older makes impossible, but a hand-edited manifest could still produce)
    # terminates instead of spinning forever.
    _ccrn_rounds=$(printf '%s' "${_ccrn_edges}" | grep -c '[^[:space:]]' || true)
    : "${_ccrn_rounds:=0}"
    _ccrn_i=0
    while [ "${_ccrn_i}" -le "${_ccrn_rounds}" ]; do
        _ccrn_i=$((_ccrn_i + 1))
        _ccrn_added=0
        for _ccrn_n in ${_ccrn_req}; do
            _ccrn_b=$(printf '%s\n' "${_ccrn_edges}" | awk -v n="${_ccrn_n}" '$1==n {print $2; exit}')
            [ -n "${_ccrn_b}" ] || continue         # already reported below when it was added
            [ "${_ccrn_b}" = "-" ] && continue      # a full backup: the chain ends here
            # A base that no manifest in the catalog declares: that backup is already gone, so
            # whatever chain ran through it is already broken and no amount of deferring will
            # put it back. It is NOT added to the required set — requiring a name that does not
            # exist would pin every ClickHouse-carrying expired id forever, turning damage that
            # has already happened into a permanent halt of retention.
            if ! printf '%s\n' "${_ccrn_edges}" | awk -v n="${_ccrn_b}" '$1==n {f=1} END{exit !f}'; then
                log "WARN" "[Retention] ClickHouse backup '${_ccrn_n}' was diffed against '${_ccrn_b}', which no manifest under this prefix declares — that chain is already incomplete. Treating '${_ccrn_n}' as a chain end." >&9
                continue
            fi
            case " ${_ccrn_req} " in
                *" ${_ccrn_b} "*) ;;
                *) _ccrn_req="${_ccrn_req} ${_ccrn_b}"; _ccrn_added=1 ;;
            esac
        done
        [ "${_ccrn_added}" -eq 0 ] && break
    done
    printf '%s\n' ${_ccrn_req} | grep -v '^$' || true
    return 0
}

# The component keys this sweep will turn into delete paths. Keys come from the manifest, i.e.
# from the STORE, and each becomes a path handed to store_delete_prefix (`rm -rf` on shared,
# `rclone purge` on s3), so they are charset-gated like every other store-derived name (DN-17).
#
# Prints the validated keys; rc 1 if ANY key is unusable. The caller then defers the whole id
# rather than dropping one key — dropping it would leave that component's data unpurged while
# the manifest, the only record of what the backup held, was deleted anyway.
#
# Fed by a HERE-DOC, not a pipe: `while read` on the right of a pipe runs in a subshell, so
# neither the filtered list nor the warnings would survive it.
# Results in GLOBALS, not on stdout, so the caller must NOT wrap this in `$( )`. Returning the
# list on stdout meant the caller captured it in a command substitution — a subshell — where the
# rejected-key diagnostic was swallowed into the captured value instead of reaching the operator,
# and a global set here could never propagate back out. rc 1 = at least one key was rejected.
PRUNE_KEYS="" ; PRUNE_BAD_KEYS=""
prune_component_keys() {   # <manifest-json>
    _pck_raw=$(printf '%s' "$1" | jq -r '.components | keys[]' 2>/dev/null || true)
    _pck_k=""
    PRUNE_KEYS=""; PRUNE_BAD_KEYS=""
    while IFS= read -r _pck_k; do
        [ -n "${_pck_k}" ] || continue
        case "${_pck_k}" in
            *[!A-Za-z0-9_.-]*) PRUNE_BAD_KEYS="${PRUNE_BAD_KEYS}${PRUNE_BAD_KEYS:+, }'${_pck_k}'"; continue ;;
        esac
        PRUNE_KEYS="${PRUNE_KEYS}${_pck_k}
"
    done <<EOF
${_pck_raw}
EOF
    [ -z "${PRUNE_BAD_KEYS}" ]
}

# Why an expired id's ClickHouse data must survive this sweep, or nothing if it need not.
# Either reason means the same thing: purge everything else, keep clickhouse/ AND the manifest.
#   * a RETAINED backup was diffed against it (incremental chain), or
#   * its data sits outside this install's root because the sidecar's S3_PATH pointed elsewhere
#     and the backup honoured it (DN-12/DN-43) — not ours to reclaim, and deleting the manifest
#     would destroy the only record of where it is.
prune_ch_pin_reason() {   # <manifest-json> <ch-name> <ch-required-set>
    case "$3" in
        *" $2 "*) printf '%s' "it is still the base a retained backup was diffed against (incremental chain)"
                  return 0 ;;
    esac
    [ "${S3_ENABLED}" = "true" ] || return 0
    _pcpr_p=$(printf '%s' "$1" | jq -r '.components.clickhouse.s3_path // empty' 2>/dev/null || true)
    if [ -n "${_pcpr_p}" ] && [ "${_pcpr_p}" != "$(clickhouse_remote_key)" ]; then
        printf '%s' "its ClickHouse data is under '${_pcpr_p}', outside this install's root, so this sweep must not delete it or the record of where it is"
    fi
    return 0
}

# Rewrite a pinned id's manifest so the index stops advertising components that are gone.
# Written AFTER the purge: a manifest that under-reports what is still in the bucket strands
# those bytes, whereas one that briefly over-reports is corrected by the next run. The keys stay
# (as status "pruned"), which is what lets a later sweep finish the job once the chain
# releases the id.
prune_mark_pruned() {   # <id> <manifest-json> <why> <purged-components>
    _pmp=$(printf '%s' "$2" | jq --arg why "$3" \
        --argjson purged "$(printf '%s\n' "$4" | jq -R -s 'split("\n") | map(select(length > 0))')" '
        .status = "partial"
        | .retention_note = ("Retention pruned every component except ClickHouse, which is kept because " + $why + ". This backup id is no longer restorable as a whole.")
        | .components = (.components | with_entries(
            if (.key as $k | $purged | index($k))
            then .value = ((.value | del(.location) | del(.restore)) + {status: "pruned"})
            else . end))' 2>/dev/null || true)
    catalog_cache_drop "$1"
    if [ -n "${_pmp}" ] && printf '%s\n' "${_pmp}" | store_write "$(manifest_path "$1")"; then
        log "INFO" "[Retention] $1: manifest updated — the pruned components are marked 'pruned' so nothing tries to restore them"
    else
        log "WARN" "[Retention] $1: components purged but its manifest still lists them as restorable; the next run will retry the rewrite"
    fi
    return 0
}

# Deal with ONE expired id. Reports what it did through three counters rather than a return
# code, because "attempted", "purged" and "skipped" are independent: a chain-pinned id both
# deletes (so it consumes the destruction budget) and is kept (so it is not a purge).
PRUNE_ONE_ATTEMPTED=0 ; PRUNE_ONE_PURGED=0 ; PRUNE_ONE_SKIPPED=0
prune_purge_one() {   # <id> <ch-required-set>
    _ppo_id="$1" _ppo_req="$2"
    _ppo_mf="" _ppo_schema="" _ppo_comps="" _ppo_chname="" _ppo_why="" _ppo_keep=""
    _ppo_fail=0 _ppo_c=""
    PRUNE_ONE_ATTEMPTED=0; PRUNE_ONE_PURGED=0; PRUNE_ONE_SKIPPED=0

    # Read ONCE: this drives both the component list to purge and the ClickHouse chain check.
    # Read BEFORE anything is attempted, because a deferred id must not consume the run's
    # destruction budget.
    _ppo_mf=$(catalog_manifest "${_ppo_id}" 2>/dev/null || true)

    # A manifest from a NEWER writer may list components whose data this version cannot turn
    # into a delete path. Purging what it recognises and then deleting the manifest would
    # strand the rest, so defer and keep the manifest for a newer reader.
    if [ -n "${_ppo_mf}" ]; then
        _ppo_schema=$(printf '%s' "${_ppo_mf}" | manifest_schema_of) || _ppo_schema=""
        if [ -z "${_ppo_schema}" ] || [ "${_ppo_schema}" -gt "${MANIFEST_SCHEMA}" ]; then
            log "WARN" "[Retention] Deferring '${_ppo_id}': its manifest is schema v${_ppo_schema:-unreadable} and this version understands v${MANIFEST_SCHEMA}; refusing to delete a backup whose layout it may not fully know"
            PRUNE_ONE_SKIPPED=1; return 0
        fi
    fi

    if ! prune_component_keys "${_ppo_mf}"; then
        log "WARN" "[Retention] ${_ppo_id}: manifest component key(s) outside A-Z a-z 0-9 _ . - : ${PRUNE_BAD_KEYS}"
        log "WARN" "[Retention] Deferring '${_ppo_id}': a key this sweep will not turn into a delete path; keeping the manifest so nothing is stranded"
        PRUNE_ONE_SKIPPED=1; return 0
    fi
    _ppo_comps="${PRUNE_KEYS}"
    if [ -z "${_ppo_comps}" ]; then
        # The manifest was readable during the ownership check, so this is a transient read
        # error or a concurrent change. Falling back to a fixed component list would delete on
        # a GUESS about what this backup holds — including ClickHouse data, without being able
        # to see whether it is a chain base.
        log "WARN" "[Retention] Deferring '${_ppo_id}': its manifest could not be read now, so what it holds is unknown; refusing to delete on a guess"
        PRUNE_ONE_SKIPPED=1; return 0
    fi

    _ppo_chname=$(printf '%s' "${_ppo_mf}" | jq -r '.components.clickhouse.name // empty' 2>/dev/null || true)
    if [ -n "${_ppo_chname}" ]; then
        if [ "${_ppo_req}" = "__unverified__" ]; then
            log "WARN" "[Retention] Deferring '${_ppo_id}': it carries ClickHouse data and the incremental chain could not be verified"
            PRUNE_ONE_SKIPPED=1; return 0
        fi
        _ppo_why=$(prune_ch_pin_reason "${_ppo_mf}" "${_ppo_chname}" "${_ppo_req}")
    fi

    # A pin holds ONLY ClickHouse. Skipping the whole id meant an incremental chain — the
    # default once --ch-backup-type incremental is used, since each night's base is the
    # previous night — retained every expired id's PostgreSQL, VictoriaMetrics and /srv data
    # too, usually the bulk of the bytes, for backups nothing depends on.
    if [ -n "${_ppo_why}" ]; then
        _ppo_keep=$(printf '%s\n' "${_ppo_comps}" | grep -v '^clickhouse$' || true)
        if [ -z "${_ppo_keep}" ]; then
            log "WARN" "[Retention] Keeping '${_ppo_id}': ${_ppo_why}, and ClickHouse is all it holds."
            PRUNE_ONE_SKIPPED=1; return 0
        fi
        if [ "${DRY_RUN}" = "true" ]; then
            log "INFO" "[Retention] [DRY RUN] '${_ppo_id}': ClickHouse backup '${_ppo_chname}' is kept because ${_ppo_why}; clickhouse/ and the manifest stay. Would purge the rest:"
            for _ppo_c in ${_ppo_keep}; do
                log "INFO" "[Retention] [DRY RUN]   would purge $(comp_display "${_ppo_c}" "${_ppo_id}")"
            done
            PRUNE_ONE_SKIPPED=1; return 0
        fi
        log "WARN" "[Retention] '${_ppo_id}': ClickHouse backup '${_ppo_chname}' is kept because ${_ppo_why}, so clickhouse/ and the manifest stay. Purging the components nothing depends on ($(printf '%s' "${_ppo_keep}" | tr '\n' ' '))."
        # This branch DELETES, so it consumes the destruction budget like any other purge.
        # Counting it as skipped-only would let a bucket full of pinned ids issue unbounded
        # destructive calls while `attempted` never advanced.
        PRUNE_ONE_ATTEMPTED=1
        for _ppo_c in ${_ppo_keep}; do
            store_delete_prefix "$(comp_path "${_ppo_c}" "${_ppo_id}")" || _ppo_fail=$((_ppo_fail + 1))
        done
        if [ "${_ppo_fail}" -ne 0 ]; then
            log "WARN" "[Retention] ${_ppo_id}: ${_ppo_fail} component path(s) could not be purged; leaving the manifest as it is so the next run retries them"
        else
            prune_mark_pruned "${_ppo_id}" "${_ppo_mf}" "${_ppo_why}" "${_ppo_keep}"
        fi
        PRUNE_ONE_SKIPPED=1; return 0
    fi

    PRUNE_ONE_ATTEMPTED=1
    if [ "${DRY_RUN}" = "true" ]; then
        # The components THIS backup holds, not a fixed list — the preview has to match what a
        # real run would do, or the review gate is showing a plan that is not the plan.
        for _ppo_c in ${_ppo_comps}; do
            log "INFO" "[Retention] [DRY RUN] would purge $(comp_display "${_ppo_c}" "${_ppo_id}")"
        done
        log "INFO" "[Retention] [DRY RUN] would then delete $(manifest_display "${_ppo_id}")"
        PRUNE_ONE_PURGED=1; return 0
    fi

    # All of an id's components, then the manifest LAST — the manifest is the only record of
    # what this backup held, so losing it first strands whatever a failure left behind.
    log "INFO" "[Retention] Purging ${_ppo_id} ($(printf '%s' "${_ppo_comps}" | tr '\n' ' ')) ..."
    for _ppo_c in ${_ppo_comps}; do
        store_delete_prefix "$(comp_path "${_ppo_c}" "${_ppo_id}")" || _ppo_fail=$((_ppo_fail + 1))
    done
    if [ "${_ppo_fail}" -ne 0 ]; then
        log "WARN" "[Retention] ${_ppo_id}: ${_ppo_fail} component path(s) could not be purged — KEEPING the manifest so the next run retries this id rather than orphaning what is left"
    elif store_delete_object "$(manifest_path "${_ppo_id}")"; then
        PRUNE_ONE_PURGED=1
    else
        log "WARN" "[Retention] ${_ppo_id}: component data purged but the manifest remains; the next run will retry it"
    fi
    return 0
}

prune_expired_backups() {
    local ids cutoff now latest_id kept=0 expired=0 purged=0 attempted=0 skipped=0
    local id ts _owner="" _ret_cut_h="" list_rc=0 started

    if [ "${BACKUP_RETENTION}" -lt 1 ]; then
        PRUNE_REFUSED=1
        log "WARN" "[Retention] --retention ${BACKUP_RETENTION} would expire every backup including this run; refusing to prune S3"
        return 0
    fi

    # The sweep cannot tell whose backup an id is — it deletes by age under THIS prefix. Two
    # installs sharing a prefix would delete each other's backups, so say the prefix out loud
    # on every run: it is the one line that makes a misconfigured shared prefix visible in the
    # log before the deletes start.
    catalog_cache_init
    PRUNE_REFUSED=0
    log "INFO" "[Retention] Scope: $(backup_root_display)/ (must be unique per install — retention deletes by age and cannot tell whose backup an id is)"
    now=$(date +%s); started="${now}"
    # EXACTLY N days: the window --help, docs/pmm-backup.md and values.yaml all promise, and
    # the number an operator reads off --retention. This once subtracted N+1 to stay in step
    # with the `find -mtime +N` sweeps, which truncate to whole days and so fire at N+1; those
    # sweeps no longer touch backup data (see the note under the log reaper in
    # cleanup_old_backups), so all the extra day bought was every backup outliving its stated
    # retention by 24h.
    cutoff=$((now - BACKUP_RETENTION * 86400))
    # GNU/BusyBox spell "format this epoch" as -d @N, BSD/macOS as -r N. Cosmetic, but the
    # cutoff is the number an operator checks first when retention did something surprising.
    _ret_cut_h=$(date -u -d "@${cutoff}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || date -u -r "${cutoff}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || echo "epoch ${cutoff}")
    log "INFO" "[Retention] Pruning backups older than ${BACKUP_RETENTION}d (before ${_ret_cut_h}) under $(backup_root_display)/"

    # catalog_ids returns its own status (see the catalog helpers): a failed listing must not
    # read as "no backups", or the sweep silently stops pruning while logging that all is
    # well — the exact condition this whole feature exists to fix.
    ids=$(catalog_ids) || list_rc=$?
    if [ "${list_rc}" -ne 0 ]; then
        PRUNE_REFUSED=1
        log "WARN" "[Retention] Could not read the backup catalog (rc ${list_rc}) — skipping the sweep this run; NOT treating it as 'nothing to keep'"
        return 0
    fi
    if [ -z "${ids}" ]; then
        log "INFO" "[Retention] No backups in the catalog under $(backup_root_display)/"
        return 0
    fi

    # Never orphan the pointer: read it BEFORE deleting anything, and treat a FAILED read as
    # fail-closed. Piping into tr would hide rclone's status the same way the listing did,
    # and an unreadable pointer that looks like "no pointer" disables the protection exactly
    # when it is needed — producing the dangling 'latest' this function exists to avoid.
    local latest_rc=0 latest_raw=""
    latest_raw=$(catalog_latest) || latest_rc=$?
    if [ "${latest_rc}" -ne 0 ]; then
        # A read can fail simply because the pointer is not there. Distinguish by probing, capturing
        # the probe's OWN status: `lsf | grep -q .` takes the pipeline's status from grep, so a failed
        # probe looks identical to "no pointer" and silently disables this protection (DN-03).
        # Through the layer, so both targets work: the old shared arm used `[ -e ]`, which cannot tell
        # EACCES from ENOENT, and hardcoded rc 0 so the refuse-to-prune arm was dead code there.
        local probe_rc=0 probe_out=""
        probe_out=$(store_list_files "$(dirname "$(latest_path)")" 2>/dev/null) || probe_rc=$?
        if [ "${probe_rc}" -ne 0 ]; then
            PRUNE_REFUSED=1
        log "WARN" "[Retention] Could not read 'latest' (rc ${latest_rc}) and could not probe whether it exists (rc ${probe_rc}); refusing to prune rather than risk orphaning it"
            return 0
        fi
        if printf '%s\n' "${probe_out}" | grep -Fxq "latest"; then
            PRUNE_REFUSED=1
        log "WARN" "[Retention] 'latest' exists but could not be read (rc ${latest_rc}); refusing to prune rather than risk orphaning it"
            return 0
        fi
        log "INFO" "[Retention] No 'latest' pointer under $(backup_root_display)/"
    fi
    latest_id=$(printf '%s' "${latest_raw}" | tr -d '[:space:]')
    [ -n "${latest_id}" ] && log "INFO" "[Retention] 'latest' -> ${latest_id} (protected)"

    # First pass: classify only. Nothing is deleted until the whole set is understood, so
    # "this would delete everything" can be caught before the first destructive call.
    # `set -f` for the classification and purge loops: ids come from whatever is in the
    # bucket, not from the validated --backup-id charset, and S3 keys may contain * ? and [.
    # Unquoted expansion would glob those against the pod's CWD, injecting names that were
    # never in the bucket into the loop — and inflating the `skipped` counter that the
    # all-expired guard relies on.
    set -f
    local expired_ids="" kept_parseable=0 kept_complete=0 _kept_mf=""
    for id in ${ids}; do
        case "${id}" in
            backup_*) ;;
            *) log "INFO" "[Retention] Skipping '${id}' (not a backup_* id)"; skipped=$((skipped + 1)); continue ;;
        esac
        ts=$(backup_id_epoch "${id}" || true)
        # Emptiness is not enough: a `date` implementation that prints a diagnostic to stdout
        # yields a non-empty, non-numeric ts, and `[ "text" -ge N ]` exits 2 — which the `if`
        # below reads as false, classifying the backup EXPIRED and purging it. That directly
        # violates the documented promise that unparseable ids are only ever skipped, so the
        # shape is checked before it is ever compared.
        case "${ts}" in
            ''|*[!0-9]*)
                log "WARN" "[Retention] Skipping '${id}': cannot parse a usable timestamp from the id"
                skipped=$((skipped + 1)); continue ;;
        esac
        if [ "${ts}" -ge "${cutoff}" ]; then
            kept=$((kept + 1)); kept_parseable=$((kept_parseable + 1))
            # Is this survivor actually RESTORABLE? Counting ids proves only that objects
            # exist; the guard below has to know that at least one of them is a backup someone
            # could restore. See DN-40.
            #
            # Probed only ONCE, and only while the answer is still unknown. The read is not free
            # on the common path: with nothing expired the sweep returns before
            # ch_chain_required_names is ever reached, so the "it re-reads every id anyway"
            # justification does not hold there — and a 30-day catalog would have paid 30 cold
            # rclone spawns every night, inside cmd_backup's lock window, to answer a question
            # that one `true` settles.
            if [ "${kept_complete}" -eq 0 ]; then
            _kept_mf=$(catalog_manifest "${id}" 2>/dev/null || true)
            # FULL-SCOPE and complete, the same predicate that lets 'latest' advance (DN-14) —
            # not `.status == "complete"` alone. An ad-hoc single-component run (say
            # `--clickhouse --backup-id X`) is marked complete because everything it SELECTED
            # succeeded, so counting it as a survivor let the sweep delete every real
            # four-component backup and leave a ClickHouse-only id behind: a catalog that
            # satisfies the guard and restores nothing.
            if [ -n "${_kept_mf}" ] \
               && [ "$(printf '%s' "${_kept_mf}" | jq -r '
                     (.status == "complete") and (.components
                        | has("postgresql") and has("clickhouse")
                          and has("victoriametrics") and has("pmm-server"))' 2>/dev/null || echo false)" = "true" ]; then
                kept_complete=$((kept_complete + 1))
            fi
            fi
            continue
        fi
        if [ -n "${latest_id}" ] && [ "${id}" = "${latest_id}" ]; then
            log "WARN" "[Retention] '${id}' is past the cutoff but is what 'latest' points at — keeping it"
            kept=$((kept + 1)); kept_parseable=$((kept_parseable + 1))
            # 'latest' only ever advances onto a complete, full-scope backup (DN-14), so an id
            # kept for being 'latest' is by construction a restorable survivor.
            kept_complete=$((kept_complete + 1))
            continue
        fi
        # Ownership is checked only for deletion candidates, so the extra read is bounded by
        # what is about to be destroyed rather than by the size of the bucket. Fail CLOSED:
        # an unreadable or owner-less manifest means ownership cannot be established, and a
        # backup we cannot prove is ours is not ours to delete.
        _owner=$(backup_id_owner "${id}" || true)
        if [ -z "${_owner}" ]; then
            log "WARN" "[Retention] Skipping '${id}': cannot establish which namespace owns it (no readable manifest); refusing to delete a backup that cannot be proven ours"
            skipped=$((skipped + 1)); continue
        fi
        if [ "${_owner}" != "${NAMESPACE}" ]; then
            log "ERROR" "[Retention] Skipping '${id}': it belongs to namespace '${_owner}', not '${NAMESPACE}'."
            log "ERROR" "[Retention]   Prefix '${S3_PREFIX}' is shared with another PMM-HA install. Give each install its own centralBackupStorage.s3.prefix — a shared prefix means each install's retention would delete the others' backups."
            skipped=$((skipped + 1)); continue
        fi
        expired_ids="${expired_ids} ${id}"
        expired=$((expired + 1))
    done

    if [ "${expired}" -eq 0 ]; then
        set +f
        log "INFO" "[Retention] Nothing expired (${kept} kept, ${skipped} skipped)"
        return 0
    fi
    # The survivor test counts only KEPT PARSEABLE backups. `skipped` cannot stand in for a
    # survivor: it lumps together a stray non-backup prefix, an aborted backup_<junk> holding
    # nothing restorable, and a genuine backup with an odd id — so counting it meant one piece
    # of junk under backups/ disarmed the guard entirely, and a mass-expiry condition (clock
    # jump, retention mis-set, a backup_id_epoch regression) could purge every real backup
    # except the one 'latest' names.
    if [ "${kept_parseable}" -eq 0 ]; then
        set +f
        PRUNE_REFUSED=1
        log "ERROR" "[Retention] Refusing to prune: all ${expired} parseable backup(s) are past the cutoff, leaving no known-good backup (${skipped} unparseable entr(y|ies) do not count). Check --retention (${BACKUP_RETENTION}d) and the system clock."
        return 0
    fi
    # And at least one survivor must be RESTORABLE, not merely present. This is the guard that
    # lets the sweep run on its own judgement instead of on whether the calling run happened to
    # succeed — see DN-40. It is strictly stronger than the count above: a catalog full of
    # 'partial' ids passes `kept_parseable` and fails here, which is the correct answer, because
    # pruning down to a set of backups that cannot restore is the outcome retention exists to
    # avoid.
    if [ "${kept_complete}" -eq 0 ]; then
        set +f
        PRUNE_REFUSED=1
        log "ERROR" "[Retention] Refusing to prune: ${kept_parseable} backup(s) survive the cutoff but NONE is a complete FULL-SCOPE backup (all four components), so pruning would leave nothing restorable."
        log "ERROR" "[Retention]   Fix whatever is failing the backups first; nothing is deleted until one full-scope backup succeeds again."
        return 0
    fi

    # ClickHouse incremental chains, computed ONCE before any delete: an expired backup may
    # still be the base a RETAINED backup was diffed against. With no incrementals under this
    # root (the chart default is --ch-backup-type full) every backup is independent, no name is
    # required, and this changes nothing.
    local ch_required="" ch_required_sp=" " ch_chain_rc=0
    ch_required=$(ch_chain_required_names "${ids}" "${expired_ids}") || ch_chain_rc=$?
    if [ "${ch_chain_rc}" -ne 0 ]; then
        log "WARN" "[Retention] Could not establish the ClickHouse incremental chain: a RETAINED backup's manifest could not be read (see the ERROR above), so which base it needs is unknown."
        log "WARN" "[Retention]   DEFERRING every expired backup that carries ClickHouse data rather than risk breaking a chain. Other backups still prune normally."
        ch_required_sp="__unverified__"
    elif [ -n "${ch_required}" ]; then
        ch_required_sp=" $(printf '%s' "${ch_required}" | tr '\n' ' ') "
        log "INFO" "[Retention] ClickHouse backups still required by retained backups: ${ch_required_sp}"
    fi

    for id in ${expired_ids}; do
        # Cap ATTEMPTS, not successes. Counting only successes meant a systematic partial
        # failure (rclone exits non-zero having deleted many objects) let the loop issue
        # unlimited destructive calls while the counter never advanced — the opposite of a
        # bound on destruction.
        # The cap bounds destruction, so it does not apply to a dry run — truncating the
        # preview would defeat its purpose as the review gate: the reviewer is supposed to see
        # the WHOLE delete list, and a preview that stops at 50 of 400 shows 12% of it.
        if [ "${DRY_RUN}" != "true" ] && [ "${attempted}" -ge "${S3_PRUNE_MAX_PER_RUN}" ]; then
            log "WARN" "[Retention] Hit the per-run cap of ${S3_PRUNE_MAX_PER_RUN}; $((expired - attempted)) expired backup(s) left for the next run"
            break
        fi
        if [ "${DRY_RUN}" != "true" ] && [ $(( $(date +%s) - started )) -ge "${S3_PRUNE_MAX_SECONDS}" ]; then
            log "WARN" "[Retention] Sweep budget of ${S3_PRUNE_MAX_SECONDS}s reached; $((expired - attempted)) expired backup(s) left for the next run"
            break
        fi
        prune_purge_one "${id}" "${ch_required_sp}"
        attempted=$((attempted + PRUNE_ONE_ATTEMPTED))
        purged=$((purged + PRUNE_ONE_PURGED))
        skipped=$((skipped + PRUNE_ONE_SKIPPED))
    done

    set +f
    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[Retention] [DRY RUN] sweep would purge ${purged}, keep ${kept}, skip ${skipped} (real runs also stop at ${S3_PRUNE_MAX_PER_RUN} deletions or ${S3_PRUNE_MAX_SECONDS}s)"
    else
        log "INFO" "[Retention] Sweep: ${purged} purged (${attempted} attempted), ${kept} kept, ${skipped} skipped"
    fi
    return 0
}

cleanup_old_backups() {
    log "INFO" "=== Cleaning Up Old Backups ==="
    log "INFO" "Retention: ${BACKUP_RETENTION} days"

    if [ ! -d "${BACKUP_DIR}" ]; then
        log "WARN" "Backup directory ${BACKUP_DIR} does not exist"
        # The S3 sweep needs nothing from BACKUP_DIR, so it must not be gated on it: a
        # reviewer previewing the delete list from a laptop or an ad-hoc pod (where /backups
        # is absent) would otherwise see only this warning and conclude there is nothing to
        # purge — the review gate silently answering "nothing".
        prune_expired_backups
        return 0
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[DRY RUN] Cleanup commands:"
        log "INFO" "[DRY RUN]   \$ find ${BACKUP_DIR}/logs -maxdepth 1 -type f \\( -name 'backup_*.log' -o -name 'restore_*.log' -o -name 'prune_*.log' \\) -mtime +${BACKUP_RETENTION} -delete"
        if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN]   \$ kubectl exec ... -c clickhouse-backup -- clickhouse-backup clean --keep-local-older-than ${BACKUP_RETENTION}d"
        fi
        # The sweep prints the EXACT paths it would purge, not just the command shape. This is
        # the review gate for retention: a reviewer has to be able to see the real delete list
        # against real storage before any of it runs for the first time.
        prune_expired_backups
        log "INFO" "Cleanup completed (dry run)"
        return 0
    fi

    # Local staging (the encryption-key export before it is stored) is scratch, not backup
    # data: reap it by age so it cannot accumulate on the pod's volume. Nothing reads it after
    # the run that created it.
    find "${BACKUP_DIR}/.staging" -maxdepth 1 -type d -name "backup_*" -mtime +1 \
        -exec rm -rf {} \; >> "${LOG_FILE}" 2>&1 || true

    # Logs are the only backup-adjacent thing still reaped by `find`: they live at
    # ${BACKUP_DIR}/logs/ and are not part of a backup id's component set.
    # || true: this runs as a plain statement under set -e AFTER the backups succeeded — a
    # find hiccup (e.g. missing logs dir) must not abort the run before metrics/summary.
    # EVERY prefix this file writes. init_log writes restore runs as restore_<ts>.log and the
    # prune subcommand writes prune_<ts>.log into this same directory; when only backup_*.log
    # was matched, DR drills (which the runbook asks for) accumulated forever on a logs PVC
    # sized for logs alone in s3 mode — and a full volume then breaks the next backup's own log
    # and metrics writes. Adding a log prefix without adding it here recreates that.
    find "${BACKUP_DIR}/logs" -maxdepth 1 -type f \
        \( -name "backup_*.log" -o -name "restore_*.log" -o -name "prune_*.log" \) -mtime +${BACKUP_RETENTION} \
        -delete >> "${LOG_FILE}" 2>&1 || true

    # The former `find ${BACKUP_DIR} -type d -name 'backup_*'` sweeps are gone: since the
    # layout became <component>/<id>/, there are no backup_<id>/ directories at the root for
    # them to match, on either target. prune_expired_backups owns backup data now — one
    # code path, one definition of expiry, both targets. It also fixes the s3 case, where
    # nothing pruned the bucket at all: that was delegated to "an S3 lifecycle policy" the
    # chart cannot create and nobody was told to configure.
    prune_expired_backups

    log "INFO" "[PostgreSQL] pg_dump files pruned with the per-id retention sweep"

    # ClickHouse cleanup
    if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Cleaning up old backups..."
        local ch_pod=$(kubectl get pods -n "${NAMESPACE}" \
            -l "${LABEL_CH_POD}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [ -n "${ch_pod}" ]; then
            if timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
                command -v clickhouse-backup >/dev/null 2>&1; then
                if [ "${VERBOSE}" = "true" ]; then
                    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
                        clickhouse-backup clean --keep-local-older-than "${BACKUP_RETENTION}d" 2>&1 | tee -a "${LOG_FILE}" || true
                else
                    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
                        clickhouse-backup clean --keep-local-older-than "${BACKUP_RETENTION}d" >> "${LOG_FILE}" 2>&1 || true
                fi
            fi
        fi
    fi
    
    # VictoriaMetrics writes straight to its target (no local leftover to prune):
    #   s3     -> under victoriametrics/<id>/, so the retention sweep above reaps it
    #   shared -> old runs reaped from the central RWX by the BACKUP_DIR sweep above
    if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
        if [ "${S3_ENABLED}" = "true" ]; then
            log "INFO" "[VictoriaMetrics] S3 backups: pruned with the per-run S3 retention sweep"
        else
            log "INFO" "[VictoriaMetrics] Shared backups: pruned by the central RWX retention sweep"
        fi
    fi

    
    log "INFO" "Cleanup completed"
}

################################################################################
# 10. Metrics — backup writes per-component gauges, restore its own file
################################################################################

# This run's Prometheus metrics: EVERY component, ONE file, atomic via mv. The component is a
# LABEL, not a file name — one file per component made the component list part of the chart's
# serving contract (DN-42). Never fails the run (DN-32).
#
# $1 = the encryption key's status, for the same reason write_manifest takes it: a FAILED key
# export never reaches RESULTS_JSON, so deriving the component list from that alone would drop
# exactly the failure worth alerting on (DN-38).

# Did the retention sweep actually sweep? Its own family: a different question, a different
# subcommand, and a prune run has no components to borrow the component-labelled series from.
write_prune_metrics() {   # <rc>
    local rc="${1:-1}" timestamp
    timestamp=$(date +%s)
    local metrics_dir="${METRICS_DIR}"
    mkdir -p "${metrics_dir}" 2>/dev/null || return 0
    local tmp_file="${metrics_dir}/.prune_metrics.prom.tmp" target_file="${metrics_dir}/prune_metrics.prom"
    if ! { printf '%s\n' \
"# HELP pmm_ha_prune_last_success Whether the last retention sweep completed (1=yes, 0=no)" \
"# TYPE pmm_ha_prune_last_success gauge" \
"pmm_ha_prune_last_success{namespace=\"${NAMESPACE}\"} $( [ "${rc}" -eq 0 ] && echo 1 || echo 0 )" \
"# HELP pmm_ha_prune_last_timestamp_seconds Unix timestamp of the last retention sweep" \
"# TYPE pmm_ha_prune_last_timestamp_seconds gauge" \
"pmm_ha_prune_last_timestamp_seconds{namespace=\"${NAMESPACE}\"} ${timestamp}" > "${tmp_file}"; } 2>/dev/null
    then
        rm -f "${tmp_file}" 2>/dev/null || true; return 0
    fi
    mv "${tmp_file}" "${target_file}" 2>/dev/null || rm -f "${tmp_file}" 2>/dev/null || true
    return 0
}

write_backup_metrics() {
    local enc_status="${1:-skipped}"
    local timestamp=$(date +%s)

    local metrics_dir="${METRICS_DIR}"
    if ! mkdir -p "${metrics_dir}" 2>/dev/null; then
        log "WARN" "Metrics dir ${metrics_dir} is not writable; falling back to /tmp (these metrics will NOT be scraped)"
        metrics_dir="/tmp/.backup_metrics"
        mkdir -p "${metrics_dir}" 2>/dev/null || { log "WARN" "Could not write backup metrics anywhere; continuing"; return 0; }
    fi

    # One file per RUN SCOPE, holding SAMPLES ONLY — no HELP/TYPE. Two constraints meet here:
    #   * the concurrent workflow runs one process per component sharing a --backup-id, and each
    #     ends in this function; with one shared file they `mv` over each other and only the last
    #     finisher's component reaches Prometheus (write_manifest merges under a lease for the
    #     same reason, but a metrics writer cannot merge safely across processes);
    #   * the text format allows exactly ONE HELP/TYPE pair per family per exposition, so
    #     self-contained files cannot simply be concatenated — that fails the whole scrape.
    # So samples are split per scope and the listener supplies the single preamble. The chart
    # knows the family NAMES but nothing about the component list. (DN-42)
    local _m_scope="all"
    [ -n "${COMPONENT_SUFFIX}" ] && _m_scope="${COMPONENT_SUFFIX#_}"
    case "${_m_scope}" in *[!A-Za-z0-9_.-]*) _m_scope="all" ;; esac
    mkdir -p "${metrics_dir}/backup" 2>/dev/null || true
    local tmp_file="${metrics_dir}/backup/.${_m_scope}.prom.tmp"
    local target_file="${metrics_dir}/backup/${_m_scope}.prom"

    # One pass, four accumulators: the text format requires every sample of a metric family to
    # sit under a single HELP/TYPE pair, so the series are grouped by metric rather than emitted
    # component by component.
    local _m_ok="" _m_ts="" _m_dur="" _m_bytes="" _mc="" _mc_ok=""
    for _mc in $(printf '%s' "${RESULTS_JSON}" | jq -r 'keys[]' 2>/dev/null || true); do
        # Encryption is emitted by the explicit block below, which is the only one that knows
        # about the not_found case. Without this skip it is emitted TWICE with an identical
        # label set, and Prometheus drops the whole scrape as a duplicate sample.
        [ "${_mc}" = "encryption" ] && continue
        _mc_ok=$(result_ok "${_mc}" && echo 1 || echo 0)
        _m_ok="${_m_ok}pmm_ha_backup_last_success{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} ${_mc_ok}
"
        _m_ts="${_m_ts}pmm_ha_backup_last_timestamp_seconds{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} ${timestamp}
"
        _m_dur="${_m_dur}pmm_ha_backup_last_duration_seconds{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} $(result_get "${_mc}" duration 0)
"
        _m_bytes="${_m_bytes}pmm_ha_backup_last_size_bytes{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} $(result_get "${_mc}" bytes 0)
"
    done
    # The encryption key, unless it was never in scope. It has no size or duration of its own,
    # but whether it succeeded is exactly the thing a DR-readiness alert needs: without it, a
    # run whose key export failed — leaving that night's PostgreSQL dumps undecryptable — looked
    # identical in Prometheus to one taken on an install with no encryption configured.
    # `not_found` is the documented NORMAL state for an install with no PG encryption
    # configured (backup_encryption_key returns 2 and logs "This is normal"), so it belongs with
    # `skipped`, not with `failed`. Emitting 0 for it pages a DR-readiness alert permanently on
    # every such install — the mirror image of the false-green this metric exists to fix.
    if [ "${enc_status}" != "skipped" ] && [ "${enc_status}" != "not_found" ]; then
        [ "${enc_status}" = "success" ] && _mc_ok=1 || _mc_ok=0
        _m_ok="${_m_ok}pmm_ha_backup_last_success{component=\"encryption\",namespace=\"${NAMESPACE}\"} ${_mc_ok}
"
        _m_ts="${_m_ts}pmm_ha_backup_last_timestamp_seconds{component=\"encryption\",namespace=\"${NAMESPACE}\"} ${timestamp}
"
    fi

    if [ -z "${_m_ok}" ]; then
        log "WARN" "No component results to publish as metrics; leaving the previous file in place"
        return 0
    fi

    # Samples only — the HELP/TYPE preamble is emitted once by the listener (see above).
    if ! { printf '%s' "${_m_ok}${_m_ts}${_m_dur}${_m_bytes}" > "${tmp_file}"; } 2>/dev/null
    then
        log "WARN" "Could not write backup metrics to ${tmp_file}; continuing"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 0
    fi

    if mv "${tmp_file}" "${target_file}" 2>/dev/null; then
        log "INFO" "Metrics written to ${target_file}"
    else
        log "WARN" "Could not publish backup metrics to ${target_file}; continuing"
        rm -f "${tmp_file}" 2>/dev/null || true
    fi
    return 0
}

# Like the other two metric writers, this one NEVER fails the run (DN-32). Every call site is a
# plain command or the last of an `&&` list, so an unguarded write on a full or read-only
# ${METRICS_DIR} does not merely lose a metric — it kills the restore, and it is called after
# scale_down_pmm, so that abort lands with PMM at 0 and the components half done.
#
# The component LABEL VALUES are the manifest's component keys — "pmm-server", not "pmm_server",
# and "encryption", not "encryption_key" — so they match pmm_ha_backup_last_success. The two
# families are written by one tool into one directory and served by one listener, and spelling the
# same component two ways meant no dashboard or alert could filter or join across them (DN-42).
write_restore_metrics() {   # <in-progress> <phase> [last-success] [last-ts] [last-duration]
    local in_progress="$1" phase="$2" last_success="${3:-0}" last_ts="${4:-0}" last_dur="${5:-0}"
    # The per-component samples are READ FROM THE TABLE rather than passed in. They used to be
    # five more positional parameters — ten in all, addressed as "${10}" — which every in-flight
    # call site had to spell out as `0 0 0 0 0`, and which silently reported every component as
    # failed for the whole run. The *_OK variables are already the authority on each outcome.
    local _wrm_c="" _wrm_rows=""
    for _wrm_c in ${RESTORE_COMPONENTS}; do
        _wrm_rows="${_wrm_rows}pmm_ha_restore_component_success{namespace=\"${NAMESPACE}\",component=\"${_wrm_c}\"} $(restore_ok "${_wrm_c}" && echo 1 || echo 0)
"
    done
    local metrics_dir="${METRICS_DIR}"
    if ! mkdir -p "${metrics_dir}" 2>/dev/null; then
        metrics_dir="/tmp/.restore_metrics"; mkdir -p "${metrics_dir}" 2>/dev/null || return 0
    fi
    local tmp_file="${metrics_dir}/.restore_metrics.prom.tmp" target_file="${metrics_dir}/restore_metrics.prom"
    if ! { cat > "${tmp_file}" <<EOF
# HELP pmm_ha_restore_in_progress Whether a restore is currently running (1=yes, 0=no)
# TYPE pmm_ha_restore_in_progress gauge
pmm_ha_restore_in_progress{namespace="${NAMESPACE}"} ${in_progress}
# HELP pmm_ha_restore_phase Current restore phase (1 when active)
# TYPE pmm_ha_restore_phase gauge
pmm_ha_restore_phase{namespace="${NAMESPACE}",phase="${phase}"} 1
# HELP pmm_ha_restore_last_success Whether the last restore succeeded (1=yes, 0=no)
# TYPE pmm_ha_restore_last_success gauge
pmm_ha_restore_last_success{namespace="${NAMESPACE}"} ${last_success}
# HELP pmm_ha_restore_last_timestamp_seconds Unix time of last restore completion
# TYPE pmm_ha_restore_last_timestamp_seconds gauge
pmm_ha_restore_last_timestamp_seconds{namespace="${NAMESPACE}"} ${last_ts}
# HELP pmm_ha_restore_last_duration_seconds Last restore total duration in seconds
# TYPE pmm_ha_restore_last_duration_seconds gauge
pmm_ha_restore_last_duration_seconds{namespace="${NAMESPACE}"} ${last_dur}
# HELP pmm_ha_restore_component_success Per-component result (1=ok, 0=fail)
# TYPE pmm_ha_restore_component_success gauge
EOF
          printf '%s' "${_wrm_rows}" >> "${tmp_file}"
    } 2>/dev/null
    then
        rm -f "${tmp_file}" 2>/dev/null || true
        return 0
    fi
    mv "${tmp_file}" "${target_file}" 2>/dev/null || rm -f "${tmp_file}" 2>/dev/null || true
    return 0
}
################################################################################
# Main Orchestration
################################################################################

# One place decides what "this component was backed up" means. Gates on the success FLAG as
# well as the return code: multi-pod components return 0 on PARTIAL success but only set their
# flag on FULL success (DN-21).
#
# The counter assignments update cmd_backup's locals via sh's dynamic scoping — verified on
# bash, dash and BusyBox ash.
# One summary row per component, rendered from its result — so adding a component does not also
# mean adding a fifteen-line block to the summary. Top level, not nested inside cmd_backup: a
# function defined inside another outlives it with stale scope expectations (see DN-22's
# neighbours and the ch_query note).
summary_row() {   # <component> <padded-label>
    if [ -z "$(result_get "$1" status)" ]; then
        log "INFO" "  ⊘ $2 Skipped"; return 0
    fi
    if ! result_ok "$1"; then
        log "ERROR" "  ✗ $2 Failed"; return 0
    fi
    _sr_b=$(result_get "$1" bytes 0)
    _sr_size=$(result_get "$1" size "")
    if [ -z "${_sr_size}" ]; then
        if [ "${_sr_b}" -gt 0 ] 2>/dev/null; then _sr_size=$(human_bytes "${_sr_b}"); else _sr_size="unknown"; fi
    fi
    _sr_pods=$(result_get "$1" pods "")
    log "INFO" "  ✓ $2 OK | ${_sr_size} | $(result_get "$1" duration 0)s | $(result_get "$1" engine "?")${_sr_pods:+ (${_sr_pods} pods)}"
    _sr_loc=$(result_get "$1" location "")
    [ -n "${_sr_loc}" ] && log "INFO" "    Location:        ${_sr_loc}"
    _sr_dbs=$(result_get "$1" databases "")
    [ -n "${_sr_dbs}" ] && log "INFO" "    Databases:       ${_sr_dbs}"
    return 0
}

# Deliberately emits NO blank-line spacer: the caller owns spacing, because the two callers
# want different spacing. Sequentially a blank line after each component separates their
# narratives; in the parallel merge loop the same call would stack one blank line per component
# at the very end, which is what produced four in a row.
record_backup_result() {   # <label> <component> <rc>
    if [ "$3" -eq 0 ] && result_ok "$2"; then
        components_backed_up=$((components_backed_up + 1))
        return 0
    fi
    # A component that failed EARLY returns before reaching its own result_set, and an absent
    # entry is indistinguishable from "not selected" everywhere downstream: the summary printed
    # "⊘ Skipped", the manifest omitted it, and — worst — its .prom file was never rewritten, so
    # the PREVIOUS run's success kept being scraped and a total failure looked green (DN-38).
    #
    # Recorded HERE rather than at each early return: this is the one place every component's
    # outcome passes through, so the next component's error path cannot forget it.
    if [ -z "$(result_get "$2" status)" ]; then
        result_set "$2" --arg status "failed" \
            --arg detail "failed before it could record any detail (see the log)" \
            '{status: $status, detail: $detail, bytes: 0, duration: 0}'
    fi
    components_failed=$((components_failed + 1))
    all_success=false
    log "ERROR" "[$1] ✗ Backup failed"
    return 1
}


cmd_backup() {
    local backup_start_time=$(date +%s)
    
    # Create backup directory first
    echo "================================================================================"
    echo "PMM-HA Unified Backup Orchestrator"
    echo "================================================================================"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Namespace: ${NAMESPACE}"
    echo "Backup Directory: ${BACKUP_DIR}"
    echo ""
    
    if [ "${DRY_RUN}" = "true" ]; then
        echo "[DRY RUN] Showing commands that would be executed (no changes will be made)"
        echo ""
    fi

    if [ "${DRY_RUN}" != "true" ]; then
        if [ ! -d "${BACKUP_DIR}" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Creating backup directory: ${BACKUP_DIR}"
            if ! mkdir -p "${BACKUP_DIR}"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Failed to create backup directory: ${BACKUP_DIR}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Please check permissions or specify --backup-dir"
                exit 1
            fi
        fi

        if [ ! -w "${BACKUP_DIR}" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Backup directory is not writable: ${BACKUP_DIR}"
            exit 1
        fi

        mkdir -p "${BACKUP_DIR}/logs" 2>/dev/null || true

        # Acquire per-component locks (allows concurrent runs of different components).
        # EXIT just releases; INT/TERM must also EXIT — a bare `trap release_locks INT TERM`
        # releases the locks in ash/dash and then RESUMES the script (now running unlocked and
        # effectively unkillable by SIGTERM), so a new run could grab the freed locks and run the
        # same components concurrently. release_component_lock is ownership-checked, so the EXIT
        # trap re-running it after the signal handler's exit is harmless.
        LOCK_COMPONENTS=$(lock_list 4)
        trap release_locks EXIT
        trap 'release_locks; exit 130' INT
        trap 'release_locks; exit 143' TERM
        acquire_locks
    else
        # Dry-run also appends tool stderr to ${LOG_FILE}, and in POSIX sh a failed
        # redirect fails the command being redirected (first run on a fresh volume has
        # no logs/ dir yet). Create it, or fall back to /dev/null.
        mkdir -p "${BACKUP_DIR}/logs" 2>/dev/null || true
        [ -w "${BACKUP_DIR}/logs" ] || LOG_FILE="/dev/null"
        # A dry run takes no locks, but release_locks is also the reaper for the retention sweep's
        # manifest cache (catalog_cache_clear), and cleanup_old_backups runs the sweep in dry run
        # too — that is the documented review gate. Without this trap every `backup --dry-run` left
        # a /tmp/pmm-backup-catalog.XXXXXX behind in the backup-tools pod, which is long-lived, so
        # they accumulated one per preview. Harmless with LOCK_COMPONENTS empty: the release loop
        # has nothing to iterate and the renewer was never started.
        trap release_locks EXIT
    fi

    echo ""

    log "INFO" "Starting backup (${TIMESTAMP})"
    [ "${DRY_RUN}" != "true" ] && log "INFO" "Log file: ${LOG_FILE}"
    
    # Run pre-flight checks
    if ! preflight_checks backup; then
        exit 1
    fi
    log "INFO" "Namespace: ${NAMESPACE}"
    log "INFO" "Components:$(selected_labels 4)"
    log "INFO" ""
    
    # Create backup subdirectory
    # Nothing to pre-create: each component owns <component>/<id>/, and the catalog's
    # parent directory is created by store_write when the target is a filesystem. Doing it
    # here unconditionally made a literal "s3:<bucket>/…/manifests" directory on the
    # container's writable layer in s3 mode.
    
    # Track overall status
    local all_success=true
    local components_backed_up=0
    local components_failed=0
    local _comp_rc=0

    # One pass over the table: run each selected component, record its outcome. The function
    # name is derived from the key, so a new row needs no edit here.
    local _bc="" _btmp="" _bpids="" _bp="" _bres="" _bmerged=""
    for _bc in ${CORE_COMPONENTS}; do
        comp_on "${_bc}" 4 || log "INFO" "[$(comp_label "${_bc}")] ⊘ Backup skipped"
    done

    if parallel_enabled false && [ "${DRY_RUN}" != "true" ]; then
        # Concurrent, IN ONE PROCESS — not the multi-process --backup-id workflow. That matters:
        # there is still exactly one manifest writer and one metrics writer here, so none of
        # DN-13's merge-lease machinery is engaged and a component cannot be reported FAILED
        # because a sibling held the lease. The cost is an interleaved log.
        log "INFO" "Running components CONCURRENTLY (--parallel). The slowest component sets the"
        log "INFO" "  wall clock, and they compete for the same node bandwidth while PMM is live."
        _btmp=$(mktemp -d 2>/dev/null || echo "/tmp/.backup_$$"); mkdir -p "${_btmp}" 2>/dev/null || true
        for _bc in ${CORE_COMPONENTS}; do
            comp_on "${_bc}" 4 || continue
            _backup_child "${_bc}" "${_btmp}" &
            _bpids="${_bpids} $!"
        done
        # These children only, never a bare `wait` — that would also wait on the lock renewer's
        # infinite loop. tests/pmm-backup-lint.sh enforces it.
        for _bp in ${_bpids}; do
            wait "${_bp}" 2>/dev/null || true
        done
        # Merge in TABLE order, so the manifest, the summary and the metrics read the same
        # regardless of which component happened to finish first.
        for _bc in ${CORE_COMPONENTS}; do
            comp_on "${_bc}" 4 || continue
            _bres=$(cat "${_btmp}/${_bc}.json" 2>/dev/null || true)
            if [ -n "${_bres}" ]; then
                _bmerged=$(printf '%s' "${RESULTS_JSON}" \
                    | jq --argjson o "${_bres}" '. + $o' 2>/dev/null) || _bmerged=""
                [ -n "${_bmerged}" ] && RESULTS_JSON="${_bmerged}"
            fi
            # A child that died without writing its status (OOM-kill, an unwritable tmpdir)
            # counts as FAILED: the absence of a result is not a result. record_backup_result
            # then synthesises the missing entry, so it cannot read as "never selected".
            _comp_rc=$(cat "${_btmp}/${_bc}.rc" 2>/dev/null || echo 1)
            case "${_comp_rc}" in ''|*[!0-9]*) _comp_rc=1 ;; esac
            record_backup_result "$(comp_label "${_bc}")" "${_bc}" "${_comp_rc}" || true
        done
        log "INFO" ""
        rm -rf "${_btmp}" 2>/dev/null || true
    else
        for _bc in ${CORE_COMPONENTS}; do
            comp_on "${_bc}" 4 || continue
            if "backup_$(printf '%s' "${_bc}" | tr '-' '_')"; then _comp_rc=0; else _comp_rc=$?; fi
            record_backup_result "$(comp_label "${_bc}")" "${_bc}" "${_comp_rc}" || true
            log "INFO" ""
        done
    fi

    # Encryption Key Backup — the PG encryption key, captured with PostgreSQL (skip via
    # --skip-encryption-key).
    local encryption_status="skipped"
    if [ "${BACKUP_POSTGRESQL}" = "true" ] && [ "${BACKUP_ENCRYPTION_KEY}" = "true" ]; then
        # Capture return code explicitly: 0=success, 2=not found, 1=failed.
        # Cannot use if/elif pattern because $? after 'if cmd' reflects the
        # boolean result of the test, not the command's actual exit code.
        set +e
        backup_encryption_key
        local enc_rc=$?
        set -e
        if [ ${enc_rc} -eq 0 ]; then
            encryption_status="success"
        elif [ ${enc_rc} -eq 2 ]; then
            encryption_status="not_found"
        else
            encryption_status="failed"
            # Without the key the PG dumps in this run cannot be decrypted after a DR,
            # so a failed key backup makes the whole run partial (no .backup_complete).
            all_success=false
            log "ERROR" "[EncryptionKey] ✗ Backup failed — PG data from this run would be undecryptable in a DR restore"
        fi
        log "INFO" ""
    fi
    
    # No consolidation step: every component writes its payload to the final target from inside
    # the source pod (s3 = tool-native upload / rclone; shared = in-pod write to the mounted
    # ${SHARED_MOUNT_PATH} RWX volume). The only payload that passes through this process is
    # the PostgreSQL dump, which has nowhere else to go: pg_dump cannot write S3 and the PG pod
    # has no rclone. Everything else goes pod -> destination directly.

    # Write the per-run manifest + 'latest' pointer: the single index that ties together the
    # component locations (all under <component>/<id>/ now). This
    # 'latest' pointer is what `list` reads, in both s3 and shared mode.
    if ! write_manifest "$([ "${all_success}" = "true" ] && echo complete || echo partial)" "${encryption_status}"; then
        # The manifest is the restore index; without it this backup is undiscoverable/unrestorable.
        # Don't let a failed upload (|| true) be reported as a successful backup.
        all_success=false
        log "ERROR" "[Manifest] Failed to write manifest.json / update 'latest' — this backup is NOT restorable; marking the run failed."
    fi
    log "INFO" ""

    # Retention runs on the CATALOG's state, not on this run's outcome (DN-40). Gating it on
    # ${all_success} made "should anything be deleted?" a property of this process's luck: one
    # component failing every night meant the sweep never ran once, and the bill arrived as a
    # full bucket months later. The sweep is always invited and declines on its own evidence —
    # it refuses unless a retained backup is complete and full-scope, which is the actual safety
    # property rather than a proxy for it.
    cleanup_old_backups
    log "INFO" ""
    
    # Metrics for vmagent, straight from the results: every component in one file, one call.
    if [ "${DRY_RUN}" != "true" ]; then
        write_backup_metrics "${encryption_status}"
    fi

    # Compute total elapsed time
    local backup_end_time=$(date +%s)
    local total_elapsed=$((backup_end_time - backup_start_time))
    local total_min=$((total_elapsed / 60))
    local total_sec=$((total_elapsed % 60))
    if [ ${total_min} -gt 0 ]; then
        local total_duration_str="${total_min}m${total_sec}s"
    else
        local total_duration_str="${total_sec}s"
    fi
    
    # Final summary
    log "INFO" ""
    log "INFO" "================================================================================"
    log "INFO" "Backup Summary"
    log "INFO" "================================================================================"

    # One row per component, rendered from its result. Adding a component no longer means
    # adding a fifteen-line block here as well.
    #   <component> <label> <extra-field-renderer>
    summary_row postgresql      "PostgreSQL:     "
    summary_row clickhouse      "ClickHouse:     "
    summary_row victoriametrics "VictoriaMetrics:"
    summary_row pmm-server      "PMM Server:     "

    # The encryption key is captured with PostgreSQL rather than being a component of its own,
    # so its row is rendered separately from the four above.
    if [ "${encryption_status}" != "skipped" ]; then
        case "${encryption_status}" in
            success)   log "INFO" "  ✓ Encryption Key:  OK | Kubernetes Secret (sha256 $(printf '%.16s' "$(result_get encryption sha256 '')")...)" ;;
            not_found) log "INFO" "  ○ Encryption Key:  Not found (encryption not configured)" ;;
            *)         log "WARN" "  ⚠ Encryption Key:  Failed" ;;
        esac
    fi

    # Where this run landed (target-aware) + how to inspect it. Each component wrote directly
    # to the target from its own pod; the manifest is the single index tying them together.
    log "INFO" "--------------------------------------------------------------------------------"
    if [ "${BACKUP_TARGET}" = "s3" ]; then
        log "INFO" "Target:  s3 -> $(backup_root_display)/<component>/backup_${TIMESTAMP}/  (index: $(manifest_display) + 'latest')"
        log "INFO" "         Every component is under <component>/backup_${TIMESTAMP}/ (ClickHouse included)"
    else
        log "INFO" "Target:  shared -> $(backup_root_display)/<component>/backup_${TIMESTAMP}/  (index: $(manifest_display) + 'latest')"
        log "INFO" "         Every component is under <component>/backup_${TIMESTAMP}/ (ClickHouse included)"
    fi
    log "INFO" "         Inspect: $(basename "$0") list backup_${TIMESTAMP} --target ${BACKUP_TARGET}"

    log "INFO" "--------------------------------------------------------------------------------"
    # The encryption key is captured with PostgreSQL, not a standalone component — call it
    # out separately so the count matches the rows above (which list it on its own line).
    local enc_note=""
    [ "${encryption_status}" = "success" ] && enc_note=" + encryption key"
    if [ "${all_success}" = "true" ]; then
        log "INFO" "Overall: ✓ All backups completed successfully (${components_backed_up} components${enc_note})"
    else
        log "ERROR" "Overall: ✗ Backup failed (${components_backed_up} succeeded, ${components_failed} failed)"
    fi
    log "INFO" "Total duration: ${total_duration_str}"
    log "INFO" "================================================================================"

    if [ "${all_success}" != "true" ]; then
        exit 1
    fi
}

################################################################################
# Retention on its own entry point.
#
# The sweep is a SEPARATE JOB from taking a backup: it destroys rather than writes, and it has
# its own budget and its own reason to run (DN-40).
#
# It takes only the clickhouse lock, not the full set. Locks exist to stop two processes writing
# one DATABASE, and the only storage this deletes belongs to ids past the cutoff, which no
# in-flight backup can be writing — a running backup's id is the current timestamp. Taking them
# all would make a long backup fail the prune schedule for no protection in return. ClickHouse
# is the exception: cleanup_old_backups also execs `clickhouse-backup clean` into the live pod.
################################################################################
cmd_prune() {
    log "INFO" "================================================================================"
    log "INFO" "PMM-HA Retention Sweep"
    log "INFO" "================================================================================"
    log "INFO" "Namespace: ${NAMESPACE}  Target: ${BACKUP_TARGET}  Retention: ${BACKUP_RETENTION}d  Log: ${LOG_FILE}"

    if ! preflight_checks prune; then exit 1; fi

    # cleanup_old_backups does more than the S3 sweep: it also execs `clickhouse-backup clean
    # --keep-local-older-than` into the LIVE ClickHouse pod, which is a database-side
    # destructive operation. Running that unlocked while a backup holds the clickhouse Lease
    # and is mid create/upload puts two writers on the same sidecar, so the sweep takes the
    # same lock a backup would. Alphabetical order and the same release path as every other
    # operation, so a prune and a backup exclude each other exactly as two backups do.
    LOCK_COMPONENTS="clickhouse"
    trap release_locks EXIT
    trap 'release_locks; exit 130' INT
    trap 'release_locks; exit 143' TERM
    acquire_locks

    local _prune_rc=0
    cleanup_old_backups || _prune_rc=$?
    # A sweep that DECLINED to prune is not a success, even though it exited cleanly: that is
    # precisely the state that goes unnoticed for months while the bucket grows.
    [ "${PRUNE_REFUSED}" -eq 0 ] || _prune_rc=1

    # Report the OUTCOME, not merely that the process ran. A sweep that refuses to prune (no
    # full-scope survivor, an unverifiable ClickHouse chain, an unreadable catalog) returns 0
    # today, so its CronJob shows Succeeded forever while the bucket grows without bound —
    # which is verbatim the silent stoppage DN-40 exists to eliminate. The metric is what an
    # alert can actually key on.
    write_prune_metrics "${_prune_rc}"
    if [ "${_prune_rc}" -ne 0 ]; then
        log "ERROR" "Retention sweep did NOT prune (see the reason above). Reporting failure so this does not pass silently."
    else
        log "INFO" "Retention sweep finished"
    fi
    return "${_prune_rc}"
}

################################################################################
# Restore main flow
################################################################################

cmd_restore() {
    log "INFO" "================================================================================"
    log "INFO" "PMM-HA Restore Orchestrator"
    log "INFO" "================================================================================"
    log "INFO" "Namespace: ${NAMESPACE}  Target: ${BACKUP_TARGET}  Log: ${LOG_FILE}"

    if ! preflight_checks restore; then exit 1; fi

    # Traps installed before anything is created: the temp mounter pods the component
    # restores spawn hold RWO data PVCs, so an interrupted run must always reap them.
    # (There is no S3 client pod to bring up any more — rclone is local, so load_manifest
    # can read the manifest immediately instead of waiting on a pod to be scheduled.)
    if [ "${DRY_RUN}" != "true" ]; then
        # Decided before the traps and before any subshell forks: restore_cleanup reads it in
        # the parent, the component subshells write it. See TEMP_PODS_MARKER. Set ONCE — a
        # second assignment later would rebind the variable and orphan anything written against
        # the first path, invisible to restore_cleanup.
        [ -n "${TEMP_PODS_MARKER}" ] || {
            TEMP_PODS_MARKER=$(mktemp /tmp/pmm-temp-pods.XXXXXX 2>/dev/null || echo "/tmp/.pmm-temp-pods.$$")
            rm -f "${TEMP_PODS_MARKER}" 2>/dev/null || true
        }
    fi
    # EXIT just cleans up; INT/TERM must also EXIT, or ash/dash resumes the restore with its locks
    # released and temp pods deleted. restore_cleanup is idempotent. See DN-20.
    #
    # Installed for a DRY RUN too, which the marker block above deliberately is not: restore_cleanup
    # is also what reaps the local manifest copy, and load_manifest makes one on both paths — so a
    # dry run that stopped at the explicit-selection gate or a failed pre-flight used to leave it in
    # /tmp. Nothing else in the handler can act on a dry run: the temp-pod sweep is gated on
    # TEMP_PODS_MARKER, which stays empty above, and release_locks iterates LOCK_COMPONENTS, which a
    # dry run never fills.
    trap restore_cleanup EXIT
    trap 'restore_cleanup; exit 130' INT
    trap 'restore_cleanup; exit 143' TERM

    if ! load_manifest; then exit 1; fi
    select_default_components

    log "INFO" "Components:$(restore_plan_line)"

    # An explicitly requested component that this backup does not carry as 'success' is a hard
    # error BEFORE anything is touched: silently skipping it scaled PMM down/up and exited 0
    # without restoring the one thing the operator asked for.
    if [ "${EXPLICIT_SELECTION}" = "true" ]; then
        local _bad="" _rc="" _rst=""
        for _rc in ${RESTORE_COMPONENTS}; do
            comp_on "${_rc}" 5 || continue
            restore_has "${_rc}" && continue
            _rst=$(comp_val "${_rc}" 7)
            _bad="${_bad} ${_rc}(${_rst:-absent})"
        done
        if [ -n "${_bad}" ]; then
            log "ERROR" "Requested component(s) not marked 'success' in ${BACKUP_NAME}:${_bad}"
            log "ERROR" "Nothing was changed. Pick another backup (see 'list'), or use --skip-<component> to drop it."
            exit 1
        fi
    fi

    # Prove every selected component can actually be restored BEFORE the confirmation
    # prompt — asking an operator to approve a destructive run that is already doomed
    # wastes the one chance to abort cheaply.
    if ! validate_restore_targets; then exit 1; fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[DRY RUN] Showing commands only; nothing will change."
        log "INFO" "--------------------------------------------------------------------------------"
    fi

    if [ "${DRY_RUN}" != "true" ] && [ "${ASSUME_YES}" != "true" ]; then
        if [ -t 0 ]; then
            log "INFO" "Restore will scale PMM down, restore data, then scale PMM back up only if all succeed."
            printf 'Press Enter to continue or Ctrl+C to abort... '
            # EOF (Ctrl+D) must ABORT a destructive restore, not be read as consent.
            read -r _ || { echo; log "INFO" "Aborted (EOF at confirmation prompt)."; exit 1; }
        else
            log "ERROR" "Refusing a destructive restore non-interactively. Re-run with --yes."; exit 1
        fi
    fi

    if [ "${DRY_RUN}" != "true" ]; then
        # Locks shared with the backup path (same names, same alphabetical order).
        # pmm-server is unconditional: every restore scales PMM down/up regardless of
        # which components were selected.
        # The marker and the traps are already in place from the top of this function.
        # pmm-server is forced on top of the selection: every restore scales PMM down and up
        # regardless of which components were chosen.
        local _saved_pmm="${RESTORE_PMM_SERVER}"
        RESTORE_PMM_SERVER=true
        LOCK_COMPONENTS=$(lock_list 5)
        RESTORE_PMM_SERVER="${_saved_pmm}"
        acquire_locks
    fi
    RESTORE_START_TIME=$(date +%s)

    # 1. Encryption key first — abort if it fails (can't decrypt restored data otherwise).
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "encryption_key"
    if [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${MF_ENC_STATUS}" = "success" ]; then
        restore_encryption_key && ENCRYPTION_KEY_OK=true
    else
        [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && log "WARN" "Encryption key requested but not in this backup"
        ENCRYPTION_KEY_OK=true
    fi
    # Not overridable by consent (DN-44): --yes answers the prompt, it does not switch off
    # checks, so this gate holds for interactive and automated restores alike. Without that
    # split the run would print "Restore completed successfully" over PostgreSQL data that
    # cannot be decrypted. Aborting here is free: nothing has been scaled down or written yet.
    # --skip-encryption-key is the explicit, narrow override.
    if [ "${ENCRYPTION_KEY_OK}" != "true" ]; then
        log "ERROR" "Encryption key restore FAILED. Aborting before anything is changed (PMM is still running)."
        log "ERROR" "  Restored PostgreSQL data would not be decryptable without this key."
        log "ERROR" "  Fix the cause, or re-run with --skip-encryption-key to proceed deliberately without it."
        write_restore_metrics 0 "idle" 0 "$(date +%s)" 0; exit 1
    fi

    # 2. Scale PMM down FIRST so nothing writes the DBs during restore and the pmm-storage PVCs
    #    are free for the /srv restore. PMM is brought up LAST (after all data is restored), so it
    #    boots against the restored DBs + /srv instead of migrating a half-restored database.
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "scale_down_pmm"
    if ! scale_down_pmm; then log "ERROR" "Failed to scale down PMM; aborting."; write_restore_metrics 0 "idle" 0 "$(date +%s)" 0; exit 1; fi

    # 3. The three data stores (PMM is down).
    #
    # A component that is NOT part of this restore is marked OK, not failed. These flags feed
    # pmm_ha_restore_component_success directly, and left false they made `restore --clickhouse`
    # emit postgresql=0 — a DR-readiness alert firing over components nobody asked to restore.
    # Safe for the verdict, because every check below is guarded by restore_do: "nothing to do"
    # can never stand in for "it worked". A component that WAS requested and is not in the
    # backup still gets a WARN — that one case must not pass in silence.
    local tmpdir _rc=""
    tmpdir=$(mktemp -d 2>/dev/null || echo "/tmp/.restore_$$"); mkdir -p "${tmpdir}" 2>/dev/null || true
    for _rc in ${RESTORE_DB_COMPONENTS}; do
        restore_do "${_rc}" && continue
        comp_on "${_rc}" 5 && log "WARN" "$(comp_label "${_rc}") requested but not marked 'success' in this backup; not restoring it"
        restore_ok_set "${_rc}" true
    done

    if parallel_enabled true && [ "${DRY_RUN}" != "true" ]; then
        write_restore_metrics 1 "components"
        # Each component runs in its own subshell with the EXIT trap reset, so a child cannot
        # release the parent's locks; the status comes back through a file because a subshell
        # cannot assign to the parent.
        local _pids="" _p=""
        for _rc in ${RESTORE_DB_COMPONENTS}; do
            restore_do "${_rc}" || continue
            _restore_child "${_rc}" "${tmpdir}" &
            _pids="${_pids} $!"
        done
        # Wait for THESE children only. A bare `wait` also waits on the lock renewer's infinite
        # loop (see start_lock_renewer), which hung the restore with every component already
        # finished and PMM at 0. tests/pmm-backup-lint.sh enforces that no bare `wait` appears.
        for _p in ${_pids}; do
            wait "${_p}" 2>/dev/null || true
        done
        # A child that died without writing its rc file (OOM-kill, unwritable tmpdir) counts as
        # FAILED: absence of a result is not a result.
        for _rc in ${RESTORE_DB_COMPONENTS}; do
            restore_do "${_rc}" || continue
            [ "$(cat "${tmpdir}/${_rc}.rc" 2>/dev/null || echo 1)" = "0" ] && restore_ok_set "${_rc}" true
        done
    else
        for _rc in ${RESTORE_DB_COMPONENTS}; do
            restore_do "${_rc}" || continue
            [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "${_rc}"
            if "restore_$(printf '%s' "${_rc}" | tr '-' '_')"; then restore_ok_set "${_rc}" true; fi
        done
    fi
    rm -rf "${tmpdir}" 2>/dev/null || true

    # 4. PMM /srv into the (released) pmm-storage PVCs via temp pods — PMM still down.
    if restore_do pmm-server; then
        [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "pmm_server"
        restore_pmm_server && PMM_SERVER_OK=true
    else
        comp_on pmm-server 5 && log "WARN" "PMM /srv requested but not in this backup"
        PMM_SERVER_OK=true
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        scale_up_pmm
        log "INFO" "--------------------------------------------------------------------------------"
        log "INFO" "[DRY RUN] No changes were made. Remove --dry-run to execute."
        rm -f "${MANIFEST_FILE}" 2>/dev/null || true
        exit 0
    fi

    # 5. Verification + outcome.
    write_restore_metrics 1 "verification"
    restore_verification

    # Every component that was actually restored must have succeeded. Guarded by restore_do, so
    # a component that was never in scope cannot stand in for one that worked. The encryption
    # key is checked unguarded: it is restored first and aborts the run on failure, so this is
    # unreachable in practice — and it is exactly the check whose absence once let a --force run
    # report success over undecryptable data. ENCRYPTION_KEY_OK is true when the key was out of
    # scope, so it is a no-op then.
    local all_ok=true
    for _rc in ${RESTORE_COMPONENTS}; do
        [ "${_rc}" = "encryption" ] && continue
        restore_do "${_rc}" || continue
        restore_ok "${_rc}" || all_ok=false
    done
    [ "${ENCRYPTION_KEY_OK}" != "true" ] && all_ok=false

    local end_ts duration success=0
    end_ts=$(date +%s); duration=$((end_ts - RESTORE_START_TIME))
    [ "${all_ok}" = "true" ] && success=1
    rm -f "${MANIFEST_FILE}" 2>/dev/null || true

    if [ "${all_ok}" = "true" ]; then
        scale_up_pmm
        write_restore_metrics 0 "idle" "${success}" "${end_ts}" "${duration}"
        log "INFO" "==============================================================================="
        log "INFO" "PMM-HA Restore Summary"
        log "INFO" "==============================================================================="
        log "INFO" "Backup: ${BACKUP_NAME}   Namespace: ${NAMESPACE}   Target: ${BACKUP_TARGET}   Duration: ${duration}s"
        restore_summary_rows
        log "INFO" "Restore completed successfully in ${duration}s. PMM scaled back up to ${PMM_SAVED_REPLICAS:-unchanged}."
        log "INFO" "==============================================================================="
        exit 0
    else
        write_restore_metrics 0 "idle" "${success}" "${end_ts}" "${duration}"
        log "ERROR" "One or more restores failed. PMM left scaled DOWN. Fix and re-run, or scale up manually:"
        log "ERROR" "  kubectl scale statefulset ${PMM_STATEFULSET_NAME:-<pmm-sts>} -n ${NAMESPACE} --replicas=${PMM_SAVED_REPLICAS:-1}"
        exit 1
    fi
}

################################################################################
# 11. Subcommand dispatch
################################################################################

# The subcommand is REQUIRED — there is deliberately no default operation. Defaulting is a
# data-loss path, not a convenience: see DN-02.
#
# For 'list', the next non-flag token (if any) is the BACKUP_ID to inspect; everything else is
# flags, parsed by parse_args.
main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            backup|restore|list|prune) COMMAND="$1"; shift ;;
            # Accepted without a subcommand: help, and --list (the restore-era alias for 'list',
            # which parse_args also accepts after a subcommand).
            -h|--help) show_help ;;
            --list) COMMAND="list"; shift ;;
        esac
    fi
    if [ -z "${COMMAND}" ]; then
        echo "Error: a subcommand is required (there is no default operation)."
        echo ""
        echo "  $0 backup  [OPTIONS]                          Back up the selected components"
        echo "  $0 restore --backup-id <id|latest> [OPTIONS]  Restore from a backup"
        echo "  $0 list    [BACKUP_ID]                        List / inspect backups"
        echo "  $0 prune   [OPTIONS]                          Run the retention sweep only"
        echo ""
        echo "Use --help for full usage information."
        exit 1
    fi
    if [ "${COMMAND}" = "list" ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
        LIST_ID="$1"; shift
    fi

    parse_args "$@"

    # --list is the restore-era alias for the 'list' subcommand.
    [ "${LIST_ONLY}" = "true" ] && COMMAND="list"

    # Validate backup target + derive the per-tool S3 flag (every subcommand).
    case "${BACKUP_TARGET}" in
        s3)
            S3_ENABLED=true
            # No list exemption: without a bucket, list would query rclone path "s3:/pmm-ha/…"
            # (bucket "pmm-ha") and silently print "no backups" with exit 0 — during an
            # incident that reads as data loss instead of a missing flag.
            [ -n "${S3_BUCKET}" ] || { echo "Error: --target s3 requires --s3-bucket (or S3_BUCKET)"; exit 1; }
            ;;
        shared)
            S3_ENABLED=false
            ;;
        *)
            echo "Error: Invalid --target: '${BACKUP_TARGET}' (must be: s3, shared)"; exit 1 ;;
    esac

    # Resolve the S3 prefix now that --namespace and --s3-prefix have both been parsed. Matches
    # the chart's pmm.backupS3Root ("<namespace>/<prefix>"), so a flag-less run outside the
    # backup-tools pod looks where the install actually writes instead of one level up.
    # NAMESPACE is validated BEFORE it is used as the S3_PREFIX default below. It is a Kubernetes
    # namespace, i.e. a DNS-1123 label, so this rejects nothing that could actually exist — and it
    # is interpolated into the Prometheus exposition as namespace="${NAMESPACE}", where a quote
    # ends the label set and a newline forges additional samples.
    case "${NAMESPACE}" in
        ''|*[!a-z0-9.-]*)
            echo "Error: Invalid --namespace: '${NAMESPACE}' (a Kubernetes namespace is lowercase alphanumerics, '-' and '.')"
            exit 1 ;;
    esac

    if [ -z "${S3_PREFIX}" ]; then
        S3_PREFIX="${NAMESPACE}/pmm-ha"
    fi

    # The S3 settings, charset-gated like every store-derived name (DN-17) — "the operator can
    # only hurt himself" stops being true the moment a values.yaml is templated by anything but
    # a human. Each of these reaches an interpreter:
    #   S3_BUCKET, S3_PREFIX  -> spliced UNQUOTED into the clickhouse-backup action string, which
    #                            is then embedded in a single-quoted SQL literal and re-used as
    #                            that row's poll key. An apostrophe closes the literal; a space
    #                            injects an extra clickhouse-backup flag.
    #   S3_ENDPOINT/REGION/PROVIDER -> rendered into the temp pods' YAML as double-quoted
    #                            scalars, where a '"' ends the value and the rest becomes spec.
    # REFUSED, not sanitised: a silently rewritten bucket or prefix would address a different
    # root from the one the install writes to and report "no backups" for a full bucket.
    case "${S3_BUCKET}" in
        *[!A-Za-z0-9._-]*)
            echo "Error: Invalid --s3-bucket: '${S3_BUCKET}' (allowed characters: A-Z a-z 0-9 . _ -)"
            exit 1 ;;
    esac
    case "${S3_PREFIX}" in
        *[!A-Za-z0-9._/-]*)
            echo "Error: Invalid --s3-prefix: '${S3_PREFIX}' (allowed characters: A-Z a-z 0-9 . _ - and '/')"
            exit 1 ;;
    esac
    case "${S3_REGION}" in
        *[!A-Za-z0-9._-]*)
            echo "Error: Invalid --s3-region: '${S3_REGION}' (allowed characters: A-Z a-z 0-9 . _ -)"
            exit 1 ;;
    esac
    case "${S3_PROVIDER}" in
        *[!A-Za-z0-9]*)
            echo "Error: Invalid --s3-provider: '${S3_PROVIDER}' (an rclone provider name: AWS, Minio, Ceph, Other, ...)"
            exit 1 ;;
    esac
    case "${S3_ENDPOINT}" in
        *[!A-Za-z0-9:/._~%+?=\&-]*)
            echo "Error: Invalid --s3-endpoint: '${S3_ENDPOINT}' (a URL; quotes, spaces and shell metacharacters are refused)"
            exit 1 ;;
    esac

    # --backup-id charset, validated for EVERY subcommand rather than per-operation. It flows
    # into filesystem paths, ClickHouse backup names and a SQL string literal on the backup
    # side — and on the RESTORE side into single-quoted `sh -c` strings executed inside
    # component pods, which is the path that most needs the check and was the one skipping it
    # (the validation used to live in the backup+list branch only). load_manifest applies the
    # same rule to ids that arrive from the bucket via the 'latest' pointer.
    if [ -n "${BACKUP_ID}" ]; then
        case "${BACKUP_ID}" in
            *[!A-Za-z0-9_-]*)
                echo "Error: Invalid --backup-id: '${BACKUP_ID}' (allowed characters: A-Z a-z 0-9 _ -)"
                exit 1
                ;;
        esac
    fi

    if [ "${COMMAND}" = "restore" ]; then
        # Credential fragments spliced into every temp restore pod. Both are rendered by
        # functions (see their definitions) because their leading whitespace is YAML content,
        # not shell formatting, and the unit tests assert those columns.
        TEMP_POD_S3_KEYS_ENV=$(render_temp_pod_s3_keys_env)
        TEMP_POD_SA_LINE=$(render_temp_pod_sa_line)
        init_log
    else
        # backup + list: validations and derived state of the backup path.

        # Validate backup types
        case "${CH_BACKUP_TYPE}" in
            full|incremental) ;;
            *) echo "Error: Invalid --ch-backup-type: ${CH_BACKUP_TYPE} (must be: full, incremental)"; exit 1 ;;
        esac

        # Validate retention is a non-negative integer (it flows unquoted into find -mtime +N)
        case "${BACKUP_RETENTION}" in
            ''|*[!0-9]*) echo "Error: Invalid --retention: '${BACKUP_RETENTION}' (must be a non-negative integer)"; exit 1 ;;
        esac
        # Digit-only was sufficient while this value was only ever a string (find -mtime +N,
        # clickhouse-backup --keep-local-older-than Nd). The S3 sweep does arithmetic with it,
        # where a leading zero is an octal literal: "010" silently means 8 days (purging the 9th
        # and 10th day the operator asked to keep) and "08" is not valid octal at all — busybox
        # aborts the whole run with "arithmetic syntax error" after the backup already succeeded.
        # Normalise rather than reject, so existing values keep working.
        BACKUP_RETENTION=$(echo "${BACKUP_RETENTION}" | sed 's/^0*\([0-9]\)/\1/')

        # A validated --backup-id (see the charset check above) doubles as this run's identifier.
        [ -n "${BACKUP_ID}" ] && TIMESTAMP="${BACKUP_ID}"

        # Determine per-component suffix for concurrent mode (--backup-id with a single component)
        if [ -n "${BACKUP_ID}" ]; then
            _comp_count=0
            _comp_name=""
            for _comp_c in ${CORE_COMPONENTS}; do
                comp_on "${_comp_c}" 4 || continue
                _comp_count=$((_comp_count + 1)); _comp_name="${_comp_c}"
            done
            [ ${_comp_count} -eq 1 ] && COMPONENT_SUFFIX="_${_comp_name}"
        fi

        # A prune run writes its own log name. Naming it backup_<ts>.log would put a sweep that
        # took no backup into the backup log series an operator reads to answer "did last
        # night's backup run?", and the reaper in cleanup_old_backups matches on these
        # prefixes — a third prefix nothing matched is exactly how restore_*.log came to
        # accumulate forever on the logs PVC.
        if [ "${COMMAND}" = "prune" ]; then
            LOG_FILE="${BACKUP_DIR}/logs/prune_${TIMESTAMP}.log"
            mkdir -p "${BACKUP_DIR}/logs" 2>/dev/null || true
            [ -w "${BACKUP_DIR}/logs" ] || LOG_FILE="/tmp/prune_${TIMESTAMP}.log"
        elif [ "${COMMAND}" = "list" ]; then
            # 'list' is read-only and reports to stdout — cmd_list uses echo throughout and takes no
            # locks, so it has nothing to journal. It shared this branch with 'backup' and therefore
            # named its log file backup_<ts>.log: nothing writes to it today, but the first log()
            # call added to that path would drop `list` invocations into the very log series an
            # operator greps to answer "did last night's backup run?". That is the same collision
            # the separate prune_<ts>.log name above exists to avoid. Nothing is lost by discarding
            # it: log() echoes every line to stdout as well.
            LOG_FILE="/dev/null"
        else
            LOG_FILE="${BACKUP_DIR}/logs/backup_${TIMESTAMP}${COMPONENT_SUFFIX}.log"
        fi
        # TIMESTAMP is final here (--backup-id may have replaced it), so this run's id is too.
        CURRENT_ID="backup_${TIMESTAMP}"
    fi

    case "${COMMAND}" in
        list)
            # Propagate cmd_list's status: it returns non-zero when the catalog could not be
            # READ, and swallowing that here would put the conflation straight back.
            _list_rc=0
            cmd_list "${LIST_ID}" || _list_rc=$?
            exit "${_list_rc}"
            ;;
        restore)
            cmd_restore
            ;;
        prune)
            cmd_prune
            ;;
        *)
            cmd_backup
            ;;
    esac
}

# Sourcing this file must NOT run the dispatcher. Running at load is what made every function
# in here untestable — in a tool whose failure mode is an unrestorable backup, and whose own
# comments record three past regressions in pure functions a unit test would have caught.
# POSIX sh has no BASH_SOURCE, so the contract is explicit rather than magic: set
# PMM_BACKUP_LIB=1 to load the definitions only. tests/pmm-backup-unit.sh does exactly that.
[ "${PMM_BACKUP_LIB:-}" = "1" ] || main "$@"
