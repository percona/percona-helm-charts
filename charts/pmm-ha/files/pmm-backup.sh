#!/bin/sh
set -eu

# fd 9 = original stdout, so dry-run previews reach the operator when stdout is redirected.
exec 9>&1

# PMM-HA Backup / Restore / List orchestrator (subcommand required, DN-02).
# Engines: pg_dump/pg_restore, clickhouse-backup, vmbackup/vmrestore, /srv tar; --target s3|shared.
# Shells: BusyBox ash, dash, bash (traps: DN-22). Rationale: docs/pmm-backup-design-notes.md.

################################################################################
# 1. Defaults + argument parsing
################################################################################

# ---- Common configuration -----------------------------------------------------
NAMESPACE="${NAMESPACE:-demo}"
# UTC: the id is the retention clock and is read from other clusters/timezones.
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP_ID=""            # backup: group id (auto if omitted)
                        # restore: <ts> | backup_<ts> | latest
BACKUP_DIR="${BACKUP_DIR:-/backups}"
# This install's logs/ and .staging/; the chart nests it under <namespace>/<release> in shared
# mode so installs on one volume stay apart. Unset = BACKUP_DIR (re-derived after -d).
_STATE_DIR_FROM_ENV="${STATE_DIR:-}"
STATE_DIR="${STATE_DIR:-${BACKUP_DIR}}"
METRICS_DIR="${METRICS_DIR:-${STATE_DIR}/.metrics}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN=false
LOG_FILE=""
_LOGDIR_FELL_BACK=""    # set when LOG_FILE fell back to /tmp
COMMAND=""

# s3: object storage, no pod mounts; shared: RWX volume mounted at SHARED_MOUNT_PATH.
BACKUP_TARGET="${BACKUP_TARGET:-s3}"
# --release tie-break; empty = "exactly one install" (DN-33).
TARGET_RELEASE="${TARGET_RELEASE:-}"
# Must match the chart's centralBackupStorage mount path.
SHARED_MOUNT_PATH="${SHARED_MOUNT_PATH:-/central}"
# <namespace>/<release> under the shared mount (S3_PREFIX counterpart); empty = flat layout.
SHARED_SUBPATH=$(echo "${SHARED_SUBPATH:-}" | sed 's|^/||; s|/$||')

# S3 settings (target=s3)
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
# Empty = resolved after parsing to "<namespace>/pmm-ha", matching the chart's pmm.backupS3Root.
S3_PREFIX=$(echo "${S3_PREFIX:-}" | sed 's|^/||; s|/$||')
# Configured via RCLONE_CONFIG_<NAME>_* env vars.
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"
# rcat streams cap one object at 10,000 parts x chunk (default 5M = 48.8 GiB); 16M = 156 GiB,
# at ~4 x chunk of buffer memory.
S3_STREAM_CHUNK="16M"
# Derived from BACKUP_TARGET after parsing.
S3_ENABLED=false

# Timeouts (s), applied via `timeout`, never --request-timeout (DN-27).
# Non-positive-integer values are clamped to the default (reported by preflight_checks).
NUMERIC_ENV_CLAMPED=""
numeric_env() {   # <VAR-NAME> <default>
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

# Kubernetes label selectors
LABEL_PG_PRIMARY="postgres-operator.crunchydata.com/role=primary"
LABEL_CH_POD="clickhouse.altinity.com/chi"
# vm_role_selector appends the tier name.
LABEL_VM_NAME_KEY="app.kubernetes.io/name"
# All PMM server replicas.
LABEL_PMM_SERVER="app.kubernetes.io/component=pmm-server"
LABEL_BACKUP_TOOLS="app.kubernetes.io/component=backup-tools"
LABEL_PMM_CLIENT="app.kubernetes.io/component=pmm-client"
# All PG instances, not just the primary: Patroni may fail over mid-run.
LABEL_PG_INSTANCE="postgres-operator.crunchydata.com/instance"
# Owner keys: each operator stamps its pods with the owning CR's name.
LABEL_PG_CLUSTER="postgres-operator.crunchydata.com/cluster"
LABEL_INSTANCE="app.kubernetes.io/instance"

# Owning CR names, resolved once by resolve_component_scope; empty = unscoped type match.
# Not derived from RELEASE_NAME: CR names differ from it, and it is the source release.
SCOPE_PG_CLUSTER=""
SCOPE_CH_CHI=""
SCOPE_VM_CLUSTER=""
SCOPE_PMM_INSTANCE=""
# Cached so destructive paths never re-resolve mid-restore.
SCOPE_PMM_STS=""
SCOPE_RESOLVED="false"

# Hold annotation, plus an owner annotation so the EXIT trap strips only our own holds.
DISRUPTION_ANNOTATION="karpenter.sh/do-not-disrupt"
DISRUPTION_OWNER_ANNOTATION="pmm.percona.com/disruption-hold"
# Escaped by hand: `${var//./\\.}` is a bashism.
DISRUPTION_JSONPATH='{.metadata.annotations.karpenter\.sh/do-not-disrupt}|{.metadata.annotations.pmm\.percona\.com/disruption-hold}'

# The ONLY place a pod selector is built, so the install scope applies everywhere.
comp_pod_selector() {
    case "$1" in
        postgresql)      printf '%s%s' "${LABEL_PG_PRIMARY}" "${SCOPE_PG_CLUSTER:+,${LABEL_PG_CLUSTER}=${SCOPE_PG_CLUSTER}}" ;;
        # LABEL_CH_POD is a bare key; the scope turns it into an equality.
        clickhouse)      printf '%s%s' "${LABEL_CH_POD}" "${SCOPE_CH_CHI:+=${SCOPE_CH_CHI}}" ;;
        victoriametrics) vm_role_selector vmstorage ;;
        pmm-server)      printf '%s%s' "${LABEL_PMM_SERVER}" "${SCOPE_PMM_INSTANCE:+,${LABEL_INSTANCE}=${SCOPE_PMM_INSTANCE}}" ;;
        *) return 1 ;;
    esac
}

# Scoped for all tiers: restore deletes vmselect/vminsert pods.
vm_role_selector() {   # <vmstorage|vmselect|vminsert>
    printf '%s=%s%s' "${LABEL_VM_NAME_KEY}" "$1" "${SCOPE_VM_CLUSTER:+,${LABEL_INSTANCE}=${SCOPE_VM_CLUSTER}}"
}

pg_all_selector() {
    printf '%s%s' "${LABEL_PG_INSTANCE}" "${SCOPE_PG_CLUSTER:+,${LABEL_PG_CLUSTER}=${SCOPE_PG_CLUSTER}}"
}

# pmm-client pods are chart-rendered, so they carry the release as instance label.
pmm_client_selector() {
    printf '%s%s' "${LABEL_PMM_CLIENT}" "${SCOPE_PMM_INSTANCE:+,${LABEL_INSTANCE}=${SCOPE_PMM_INSTANCE}}"
}

# Exactly one pod or refuse (e.g. two primaries mid-failover). Logs to fd 9: called inside $( ).
one_pod() {   # <tag> <what> <selector>
    _op_tag="$1"; _op_what="$2"; _op_sel="$3"
    _op_names=$(kubectl get pods -n "${NAMESPACE}" -l "${_op_sel}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
    # shellcheck disable=SC2086
    set -- ${_op_names}
    if [ $# -eq 1 ]; then printf '%s' "$1"; return 0; fi
    if [ $# -eq 0 ]; then
        log "ERROR" "[${_op_tag}] No ${_op_what} found in ${NAMESPACE} (selector: ${_op_sel})" >&9
        return 1
    fi
    log "ERROR" "[${_op_tag}] Refusing to guess: ${NAMESPACE} holds $# ${_op_what}s ($*) matching ${_op_sel}." >&9
    log "ERROR" "[${_op_tag}] Re-run with --release <name>, or retry once a failover has settled." >&9
    return 2
}

CH_SECRET_NAME="${CH_SECRET_NAME:-pmm-secret}"

# Empty until computed, so an early trap can call release_locks harmlessly.
LOCK_COMPONENTS=""
# Pods we annotated, so the EXIT trap strips only those.
DISRUPTION_HELD_PODS=""
# The backup id every path builder defaults to (see backup_id_default).
CURRENT_ID=""
# First --<component> flag disables the others; later flags combine.
EXPLICIT_SELECTION=false
ENC_KEY_REQUESTED=false   # restore --encryption-key given by name
LIST_ONLY=false
LIST_ID=""

# ---- Backup configuration -------------------------------------------------------
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"

BACKUP_POSTGRESQL="${BACKUP_POSTGRESQL:-true}"
BACKUP_CLICKHOUSE="${BACKUP_CLICKHOUSE:-true}"
BACKUP_VICTORIAMETRICS="${BACKUP_VICTORIAMETRICS:-true}"
BACKUP_PMM_SERVER="${BACKUP_PMM_SERVER:-true}"
# Captured with PostgreSQL; --skip-encryption-key turns it off.
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-true}"

CH_BACKUP_TYPE="${CH_BACKUP_TYPE:-full}"
# Max seconds for create/upload (polled).
CH_CREATE_TIMEOUT="${CH_CREATE_TIMEOUT:-300}"
numeric_env CH_CREATE_TIMEOUT 300

PMM_SRV_PATH="${PMM_SRV_PATH:-/srv}"

# Concurrent mode (--backup-id with one component); computed after parsing.
COMPONENT_SUFFIX=""

# ---- Component results ----------------------------------------------------------------
# One in-memory JSON object keyed by component, source of manifest/summary/metrics (DN-38).
RESULTS_JSON='{}'

# Pre-initialised for `set -u`.
CH_BACKUP_BASE=""          # incremental base (empty = full)
CH_SHARED_TAR=""
CH_LOCATION_OVERRIDE=""    # sidecar wrote outside this run's root (DN-12)

result_set() {   # <component> <jq-args...>
    _rs_c="$1"; shift
    # Never returns non-zero (set -e); unbuildable results are recorded FAILED, not dropped (DN-38).
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

result_get() {   # <component> <field> [default]
    _rg_v=$(printf '%s' "${RESULTS_JSON}" | jq -r --arg c "$1" --arg f "$2" '.[$c][$f] // empty' 2>/dev/null || true)
    if [ -n "${_rg_v}" ]; then printf '%s' "${_rg_v}"; else printf '%s' "${3:-}"; fi
}

result_ok() { [ "$(result_get "$1" status)" = "success" ]; }

# "<key>:<bytes> ..." -> JSON object (DN-16).
# jq -n --arg, not printf | jq -R: empty input yields no output.
sizes_to_json() {
    jq -n --arg s "${1:-}" '$s | split(" ") | map(select(length > 0)) | map(. / ":")
        | map({key: .[0], value: (.[1] | tonumber)}) | from_entries'
}

# ---- Restore configuration ------------------------------------------------------
# Consent only; never disables a safety check (DN-44).
ASSUME_YES=false
# Empty = per-subcommand default: restore parallel, backup sequential (system is live).
PARALLEL=""

# rclone provider: AWS | Minio | Ceph | Other
S3_PROVIDER="${S3_PROVIDER:-AWS}"
# VM-only S3 overrides (DN-28); empty = same as everything else.
VM_S3_ENDPOINT="${VM_S3_ENDPOINT:-}"
# Needed by the vmrestore temp pod this script renders.
VM_S3_REGION="${VM_S3_REGION:-}"
VM_S3_SECRET_NAME="${VM_S3_SECRET_NAME:-}"
VM_S3_SECRET_ACCESS_KEY_KEY="${VM_S3_SECRET_ACCESS_KEY_KEY:-access-key}"
VM_S3_SECRET_SECRET_KEY_KEY="${VM_S3_SECRET_SECRET_KEY_KEY:-secret-key}"
# Static S3 creds for temp pods; leave empty on AWS with IRSA.
S3_SECRET_NAME="${S3_SECRET_NAME:-}"
S3_SECRET_ACCESS_KEY_KEY="${S3_SECRET_ACCESS_KEY_KEY:-access-key}"
S3_SECRET_SECRET_KEY_KEY="${S3_SECRET_SECRET_KEY_KEY:-secret-key}"
# Empty unless the chart created an IRSA SA; else temp pods use the namespace default SA.
S3_SERVICE_ACCOUNT="${S3_SERVICE_ACCOUNT:-}"
# An explicit SA is honored even alongside static keys.
S3_SA_EXPLICIT=false

# Default: restore everything the manifest marks 'success'.
RESTORE_POSTGRESQL="${RESTORE_POSTGRESQL:-false}"
RESTORE_CLICKHOUSE="${RESTORE_CLICKHOUSE:-false}"
RESTORE_VICTORIAMETRICS="${RESTORE_VICTORIAMETRICS:-false}"
RESTORE_PMM_SERVER="${RESTORE_PMM_SERVER:-false}"
RESTORE_ENCRYPTION_KEY="${RESTORE_ENCRYPTION_KEY:-false}"
# Applied after the manifest-driven defaults.
SKIP_POSTGRESQL=false; SKIP_CLICKHOUSE=false; SKIP_VICTORIAMETRICS=false; SKIP_PMM_SERVER=false; SKIP_ENCRYPTION_KEY=false

# Pre-flight list-remote budget; the gate fails closed, so 30s is too tight.
CH_LIST_TIMEOUT="${CH_LIST_TIMEOUT:-120}"
numeric_env CH_LIST_TIMEOUT 120

# Set by the chart from victoriaMetrics.vmstorage.backup.restoreImage.
VMRESTORE_IMAGE="${VMRESTORE_IMAGE:-}"
# vmstorage readiness after a restore: a large tier loads its index for minutes.
VM_READY_TIMEOUT="${VM_READY_TIMEOUT:-1800}"
numeric_env VM_READY_TIMEOUT 1800
VM_STORAGE_PVC_PREFIX="${VM_STORAGE_PVC_PREFIX:-vmstorage-db-}"
# Override only; default is read from the StatefulSet (DN-39).
PMM_STORAGE_PVC_PREFIX="${PMM_STORAGE_PVC_PREFIX:-}"
# Cached: one API read per run.
PMM_STORAGE_PVC_PREFIX_RESOLVED=""

# Shared mode only; auto-detected if unset.
CENTRAL_BACKUP_PVC="${CENTRAL_BACKUP_PVC:-}"

# Restore runtime state, pre-initialised for `set -u`.
BACKUP_NAME=""             # backup_<timestamp>
MANIFEST_FILE=""           # local temp copy of manifest.json
MF_STATUS="" ; MF_TARGET="" ; MF_CREATED=""
MF_PG_STATUS="" ; MF_PG_DBS=""
MF_CH_STATUS="" ; MF_CH_NAME=""
# Recorded CH location; empty falls back to this run's root (DN-43).
MF_CH_S3_BUCKET="" ; MF_CH_S3_PATH=""
MF_VM_STATUS="" ; MF_PMM_STATUS="" ; MF_ENC_STATUS=""
PMM_SAVED_REPLICAS="" ; PMM_STATEFULSET_NAME=""
# Rendered into temp restore pods; set in the restore dispatch.
TEMP_POD_S3_KEYS_ENV="" ; TEMP_POD_VM_S3_KEYS_ENV="" ; TEMP_POD_SA_LINE=""
# Temp pod resources as JSON. Not set via ${VAR:-{...}}: a `}` closes the expansion.
# Fallback = the chart's restorePodResources; limits too, or a quota requiring them rejects the pod.
TEMP_POD_RESOURCES="${TEMP_POD_RESOURCES:-}"
if [ -z "${TEMP_POD_RESOURCES}" ]; then
    TEMP_POD_RESOURCES='{"requests":{"cpu":"100m","memory":"256Mi"},"limits":{"cpu":"2","memory":"2Gi"}}'
fi
# A file, not a variable: parallel restores run in subshells. Gates restore_cleanup's sweep.
TEMP_PODS_MARKER=""
RUN_CHILD_PIDS=""   # parallel backup/restore children while they run; the INT/TERM traps stop them
PG_STAGE_MARKER=""   # "<pod> <file>" per staged dump, for restore_cleanup
RESTORE_START_TIME=0
ENCRYPTION_KEY_OK=false ; POSTGRESQL_OK=false ; CLICKHOUSE_OK=false
VICTORIAMETRICS_OK=false ; PMM_SERVER_OK=false

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
  --release NAME            Which install to act on, when the namespace holds more than one.
                            Only needed then: the default rule is "exactly one match, or
                            refuse" - restore overwrites what it resolves, so it never guesses.
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
  --shared-source-path PATH Subdirectory of the shared mount to read/write (default:
                            <namespace>/<release>, matching what the chart projects).
                            The shared-target twin of --s3-prefix: point it at ANOTHER
                            install's subpath to restore that install's backup (DR).
  --shared-mount-path PATH  Mount path of the shared volume in the pods (default: /central)
  --ch-secret NAME          Kubernetes secret for CH credentials (default: pmm-secret)

Component selection (combinable, e.g. --postgresql --clickhouse):
  Default: backup = all components; restore = everything the manifest marks 'success'.
  --postgresql  --clickhouse  --victoriametrics  --pmm-server  --encryption-key (restore only)
  --skip-postgresql  --skip-clickhouse  --skip-victoriametrics  --skip-pmm-server
  --skip-encryption-key     backup: skip the PMM encryption key (captured with PostgreSQL
                            by default); restore: do not restore it
                            Restore applies the key with PostgreSQL; without a PostgreSQL
                            restore it is applied only with --encryption-key.

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
  STATE_DIR                 This install's logs/ and .staging/ (default: BACKUP_DIR; the chart
                            sets <mount>/<namespace>/<release> in shared mode)
  BACKUP_RETENTION          Retention in days (default: 7)
  METRICS_DIR               Directory for Prometheus .prom metrics files
                            (default: STATE_DIR/.metrics)
  KUBECTL_EXEC_TIMEOUT      Max wait for pods to start/stop (default: 600). Data transfers have no
                            wall clock (only a scheduled Job's activeDeadlineSeconds bounds them)
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
  CH_LIST_TIMEOUT           Budget for the restore pre-flight 'list remote' (default: 120)
  PMM_SRV_PATH              Path archived from each PMM server pod (default: /srv)
  PMM_SERVER_REPLICAS       Fallback PMM replica count on restore scale-up (default: 3)
  VMRESTORE_IMAGE           vmrestore image (the chart sets it from
                            victoriaMetrics.vmstorage.backup.restoreImage). Unset = the
                            restore refuses rather than guess a tag.
  VM_READY_TIMEOUT          Seconds to wait for vmstorage to be Ready after a restore (default: 1800)
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
  Backups write METRICS_DIR/backup/<component>.prom, one file per component the run
  covered; restores write restore_metrics.prom. The backup-tools pod serves them over one
  HTTP listener on port 9091 ('component' is a label), which vmagent scrapes as one job.

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

# Reject a flag for the wrong subcommand; 'list' accepts all. <op(s)> <flag>
flag_requires() {
    _fr_ok=false
    case " $1 " in *" ${COMMAND} "*) _fr_ok=true ;; esac
    if [ "${_fr_ok}" = "true" ] || [ "${COMMAND}" = "list" ]; then
        _fr_ok=true
    elif [ "${COMMAND}" = "prune" ] && [ "$1" = "backup" ]; then
        # prune takes the backup flag set (DN-40).
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
# Every per-component loop reads this table (DN-45). Columns:
# key:flag:label:BACKUP_*:RESTORE_*:SKIP_*:MF_*:*_OK:sel|nosel (nosel = not selectable on backup)
COMPONENTS="postgresql:postgresql:PostgreSQL:BACKUP_POSTGRESQL:RESTORE_POSTGRESQL:SKIP_POSTGRESQL:MF_PG_STATUS:POSTGRESQL_OK:sel
clickhouse:clickhouse:ClickHouse:BACKUP_CLICKHOUSE:RESTORE_CLICKHOUSE:SKIP_CLICKHOUSE:MF_CH_STATUS:CLICKHOUSE_OK:sel
victoriametrics:victoriametrics:VictoriaMetrics:BACKUP_VICTORIAMETRICS:RESTORE_VICTORIAMETRICS:SKIP_VICTORIAMETRICS:MF_VM_STATUS:VICTORIAMETRICS_OK:sel
pmm-server:pmm-server:PMMServer:BACKUP_PMM_SERVER:RESTORE_PMM_SERVER:SKIP_PMM_SERVER:MF_PMM_STATUS:PMM_SERVER_OK:sel
encryption:encryption-key:EncryptionKey:BACKUP_ENCRYPTION_KEY:RESTORE_ENCRYPTION_KEY:SKIP_ENCRYPTION_KEY:MF_ENC_STATUS:ENCRYPTION_KEY_OK:nosel"

# "Full scope" for latest (DN-14) and the retention guard (DN-40).
CORE_COMPONENTS="postgresql clickhouse victoriametrics pmm-server"

comp_col() {   # <key-or-flag> <column>
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
        [ "$1" = "${_cc_want}" ] || [ "$2" = "${_cc_want}" ] || continue
        eval "printf '%s' \"\${${_cc_n}}\""
        return 0
    done
    return 1
}
comp_label() { comp_col "$1" 3; }
comp_bvar()  { comp_col "$1" 4; }
comp_rvar()  { comp_col "$1" 5; }
comp_okvar() { comp_col "$1" 8; }

comp_val() {   # <key> <column>: value of the named variable
    _cv_n=$(comp_col "$1" "$2") || return 1
    [ -n "${_cv_n}" ] || return 1
    eval "printf '%s' \"\${${_cv_n}}\""
}
# Selected for this operation? <key> <column>
comp_on() { [ "$(comp_val "$1" "$2" 2>/dev/null)" = "true" ]; }

# First explicit selection turns every other component off.
select_component() {
    _sc_want="$1" _sc_row="" _sc_key="" _sc_var=""
    for _sc_row in ${COMPONENTS}; do
        _sc_key="${_sc_row%%:*}"
        if [ "${COMMAND}" = "restore" ]; then
            _sc_var=$(comp_rvar "${_sc_key}")
        else
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

# Restore records SKIP_* (applied after manifest defaults); backup turns it off directly.
skip_component() {
    if [ "${COMMAND}" = "restore" ]; then _kc_var=$(comp_col "$1" 6) || return 0
    else _kc_var=$(comp_bvar "$1") || return 0; fi
    [ -n "${_kc_var}" ] || return 0
    if [ "${COMMAND}" = "restore" ]; then eval "${_kc_var}=true"; else eval "${_kc_var}=false"; fi
    return 0
}

# Clear error instead of a `set -u` "unbound variable" abort.
require_value() {   # <flag> <count-of-remaining-args>
    [ "$2" -ge 2 ] && return 0
    echo "Error: $1 requires a value" >&2
    echo "Use --help for usage information." >&2
    exit 1
}

parse_args() {
    while [ $# -gt 0 ]; do
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
            --release)
                require_value "$1" $#; TARGET_RELEASE="$2"; shift
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
            --shared-source-path)
                require_value "$1" $#; SHARED_SUBPATH=$(echo "$2" | sed 's|^/||; s|/$||'); shift
                ;;
            --ch-secret)
                require_value "$1" $#; CH_SECRET_NAME="$2"; shift
                ;;
            # First explicit selection disables the others; later ones combine.
            --postgresql|--clickhouse|--victoriametrics|--pmm-server)
                select_component "${1#--}"
                ;;
            --encryption-key)
                flag_requires restore "$1"
                select_component encryption-key
                ENC_KEY_REQUESTED=true
                ;;
            --skip-postgresql|--skip-clickhouse|--skip-victoriametrics|--skip-pmm-server)
                skip_component "${1#--skip-}"
                ;;
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
            # Alias for the 'list' subcommand, in any mode.
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

    # Print once, then best-effort append to the log file.
    echo "${line}"
    if ! { echo "${line}" >> "${LOG_FILE}"; } 2>/dev/null; then
        if [ "${LOG_FILE_WARNING_SHOWN:-}" != "true" ]; then
            echo "[${timestamp}] [WARN] Unable to write to log file: ${LOG_FILE}"
            export LOG_FILE_WARNING_SHOWN=true
        fi
    fi
}

# Restore log, UTC like every timestamp here; falls back to /tmp.
init_log() {
    _il_ts=$(date -u +%Y%m%d-%H%M%S)
    LOG_FILE="${STATE_DIR}/logs/restore_${_il_ts}.log"
    # touch, not ': >>': a redirect failure on a special builtin kills the shell.
    if ! share_mkdir "${STATE_DIR}/logs" || ! touch "${LOG_FILE}" 2>/dev/null; then
        LOG_FILE="/tmp/restore_${_il_ts}.log"
        touch "${LOG_FILE}" 2>/dev/null || true
    fi
}

# Stream stdin (command output) to the log + stderr.
append_to_log() { tee -a "${LOG_FILE}" >&2 2>/dev/null || cat >&2; }

# timeout <secs>; 0 = no wall clock (data-path execs, bounded by the Job deadline).
_bounded() {
    _bd_t="$1"; shift
    if [ "${_bd_t}" = "0" ]; then "$@"; else timeout "${_bd_t}" "$@"; fi
}

# The rc a pod script printed as "<key>=<rc>" on stdin; empty when missing. kubectl exits 1 for its
# own failures too (dropped stream, "Unable to connect"), so a command's rc 1 is read from here.
marker_rc() { sed -n "s/^$1=\([0-9][0-9]*\)\$/\1/p" | tail -n 1; }

# pod_sh <tag> <pod> <container|-> <timeout> <script> [args...]
# One script text is both previewed and run; values are positional args (DN-17). 0 in dry run.
pod_sh() {
    _ps_tag="$1" _ps_pod="$2" _ps_ctr="$3" _ps_to="$4" _ps_script="$5"; shift 5
    if [ "${DRY_RUN}" = "true" ]; then
        # fd 9: see the 'exec 9>&1' note.
        log "INFO" "[${_ps_tag}] [DRY RUN] kubectl exec ${_ps_pod}$([ "${_ps_ctr}" = "-" ] || echo " -c ${_ps_ctr}") -- sh -c '${_ps_script}'" >&9
        [ $# -gt 0 ] && log "INFO" "[${_ps_tag}] [DRY RUN]   with: $*" >&9
        return 0
    fi
    if [ "${_ps_ctr}" = "-" ] || [ -z "${_ps_ctr}" ]; then
        _bounded "${_ps_to}" kubectl exec -n "${NAMESPACE}" "${_ps_pod}" -- sh -c "${_ps_script}" sh "$@"
    else
        _bounded "${_ps_to}" kubectl exec -n "${NAMESPACE}" "${_ps_pod}" -c "${_ps_ctr}" -- sh -c "${_ps_script}" sh "$@"
    fi
}

# pod_exec <tag> <pod> <container|-> <timeout> <command> [args...]
# Like pod_sh but no shell in the pod: argv goes straight to the binary (DN-46).
pod_exec() {
    _pe_tag="$1" _pe_pod="$2" _pe_ctr="$3" _pe_to="$4"; shift 4
    if [ "${DRY_RUN}" = "true" ]; then
        # fd 9: see the 'exec 9>&1' note.
        log "INFO" "[${_pe_tag}] [DRY RUN] kubectl exec ${_pe_pod}$([ "${_pe_ctr}" = "-" ] || echo " -c ${_pe_ctr}") -- $*" >&9
        return 0
    fi
    if [ "${_pe_ctr}" = "-" ] || [ -z "${_pe_ctr}" ]; then
        _bounded "${_pe_to}" kubectl exec -n "${NAMESPACE}" "${_pe_pod}" -- "$@"
    else
        _bounded "${_pe_to}" kubectl exec -n "${NAMESPACE}" "${_pe_pod}" -c "${_pe_ctr}" -- "$@"
    fi
}

# Bytes as human-readable (1234567 -> 1.2MB).
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i=1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i]; else printf "%.1f%s", b, u[i]
    }'
}

# sha256 of a file, or empty when no tool is present.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    fi
    # Always rc 0: callers assign it bare under set -e; no hash = empty output.
    return 0
}

# jq builds the manifest; checked by running it (DN-22, DN-26).
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
# 3+4. Layout + storage access
################################################################################

# ---- Layout -------------------------------------------------------------------------
#   <root>/latest                  newest backup id
#   <root>/manifests/<id>.json     per-run index
#   <root>/<component>/<id>/...    component data
# Namespace leads <root> on both targets (DN-08); a backup is a correlation (DN-06).
# Views: path (this process), display (s3:// URI), inpod (component pods) (DN-05).
backup_root() {   # [view]
    if [ "${S3_ENABLED}" = "true" ]; then
        case "${1:-path}" in
            display) echo "s3://${S3_BUCKET}/${S3_PREFIX}" ;;
            *)       echo "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}" ;;
        esac
    else
        case "${1:-path}" in
            inpod) echo "${SHARED_MOUNT_PATH}${SHARED_SUBPATH:+/${SHARED_SUBPATH}}" ;;
            *)     echo "${BACKUP_DIR}${SHARED_SUBPATH:+/${SHARED_SUBPATH}}" ;;
        esac
    fi
}
backup_root_display() { backup_root display; }

# <root>/<component>/<id>. An empty id would mean every backup, so it fails loudly.
comp_at() {   # <view> <component> [id]
    _ca_id="${3:-$(backup_id_default)}"
    [ -n "${_ca_id}" ] || { echo "BUG: backup id not yet known at path construction" >&2; return 1; }
    echo "$(backup_root "$1")/$2/${_ca_id}"
}
comp_path()    { comp_at path    "$1" "${2:-}"; }
comp_display() { comp_at display "$1" "${2:-}"; }
comp_inpod()   { comp_at inpod   "$1" "${2:-}"; }
# Names of every <kind> matching <selector>; rc != 0 = lookup failed, not 'none'.
resolve_one_names() {   # <kind> [selector]
    if [ -n "${2:-}" ]; then
        kubectl get "$1" -n "${NAMESPACE}" -l "$2" \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null
    else
        kubectl get "$1" -n "${NAMESPACE}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null
    fi
}

# The ONE matching name, else rc 1 none / 2 several / 3 lookup failed. Logs to fd 9.
resolve_one() {   # <tag> <what> <kind> [label-selector]
    _ro_tag="$1"; _ro_what="$2"; _ro_kind="$3"; _ro_base="${4:-}"
    _ro_sel="${_ro_base}"
    if [ -n "${TARGET_RELEASE}" ]; then
        if [ -n "${_ro_sel}" ]; then
            _ro_sel="${_ro_sel},${LABEL_INSTANCE}=${TARGET_RELEASE}"
        else
            _ro_sel="${LABEL_INSTANCE}=${TARGET_RELEASE}"
        fi
    fi
    _ro_rc=0
    _ro_names=$(resolve_one_names "${_ro_kind}" "${_ro_sel}") || _ro_rc=$?
    if [ "${_ro_rc}" -ne 0 ]; then
        log "ERROR" "[${_ro_tag}] Could NOT look up ${_ro_what}s in ${NAMESPACE} (kubectl rc ${_ro_rc})." >&9
        log "ERROR" "[${_ro_tag}] Usually RBAC (the ServiceAccount needs get/list on ${_ro_kind}), a missing CRD, or an apiserver timeout." >&9
        log "ERROR" "[${_ro_tag}] NOT treating it as 'none exist': the pod selector built from this would then match EVERY install in the namespace." >&9
        return 3
    fi
    # shellcheck disable=SC2086
    set -- ${_ro_names}
    if [ $# -eq 1 ]; then printf '%s' "$1"; return 0; fi
    # Distinct rc, not a global: callers run this in $( ).
    if [ $# -eq 0 ]; then
        if [ -n "${TARGET_RELEASE}" ]; then
            # Unlabelled objects from an older chart must not read as absent.
            _ro_any=$(resolve_one_names "${_ro_kind}" "${_ro_base}") || _ro_any=""
            if [ -n "${_ro_any}" ]; then
                log "ERROR" "[${_ro_tag}] No ${_ro_what} here carries ${LABEL_INSTANCE}=${TARGET_RELEASE}, but ${NAMESPACE} does hold: ${_ro_any}" >&9
                log "ERROR" "[${_ro_tag}] --release cannot tell those apart, and continuing would match EVERY install in the namespace." >&9
                log "ERROR" "[${_ro_tag}] They predate the label — run 'helm upgrade' on that release first, then retry." >&9
                return 3
            fi
        fi
        log "ERROR" "[${_ro_tag}] No ${_ro_what} found in namespace ${NAMESPACE}${TARGET_RELEASE:+ for release ${TARGET_RELEASE}}" >&9
        return 1
    fi
    log "ERROR" "[${_ro_tag}] Refusing to guess: ${NAMESPACE} holds $# ${_ro_what}s ($*)." >&9
    log "ERROR" "[${_ro_tag}] Restore scales this down and overwrites it, so the choice must be explicit." >&9
    log "ERROR" "[${_ro_tag}] Re-run with --release <name>." >&9
    return 2
}

# Selected for this operation and, if narrowed, one of the named components.
scope_wants() {   # <component> <column> <only-list-or-empty>
    if [ -n "$3" ]; then
        case " $3 " in *" $1 "*) ;; *) return 1 ;; esac
    fi
    comp_on "$1" "$2"
}

# Resolve each component's owner once. Ambiguity is fatal; absence is left to the component.
# <col>: 4 = backup, 5 = restore.
resolve_component_scope() {   # <selected-column> [only-these-components]
    [ "${SCOPE_RESOLVED}" = "true" ] && return 0
    _rcs_col="${1:-4}"
    _rcs_only="${2:-}"
    _rcs_fail=0 _rcs_n="" _rcs_rc=0

    if scope_wants postgresql "${_rcs_col}" "${_rcs_only}"; then
        _rcs_rc=0; _rcs_n=$(resolve_one PostgreSQL "PostgreSQL cluster" perconapgcluster) || _rcs_rc=$?
        if [ "${_rcs_rc}" -ge 2 ]; then _rcs_fail=1; fi
        SCOPE_PG_CLUSTER="${_rcs_n}"
    fi
    if scope_wants clickhouse "${_rcs_col}" "${_rcs_only}"; then
        _rcs_rc=0; _rcs_n=$(resolve_one ClickHouse "ClickHouseInstallation" chi) || _rcs_rc=$?
        if [ "${_rcs_rc}" -ge 2 ]; then _rcs_fail=1; fi
        SCOPE_CH_CHI="${_rcs_n}"
    fi
    if scope_wants victoriametrics "${_rcs_col}" "${_rcs_only}"; then
        _rcs_rc=0; _rcs_n=$(resolve_one VictoriaMetrics "VMCluster" vmcluster) || _rcs_rc=$?
        if [ "${_rcs_rc}" -ge 2 ]; then _rcs_fail=1; fi
        SCOPE_VM_CLUSTER="${_rcs_n}"
    fi
    # Restore always resolves PMM: every restore scales it and resets client agents.
    if [ "${_rcs_col}" = "5" ] || scope_wants pmm-server "${_rcs_col}" "${_rcs_only}"; then
        _rcs_rc=0; SCOPE_PMM_STS=$(resolve_one PMM "PMM Server StatefulSet" statefulset "${LABEL_PMM_SERVER}") || _rcs_rc=$?
        if [ "${_rcs_rc}" -ge 2 ]; then _rcs_fail=1; fi
        if [ -n "${SCOPE_PMM_STS}" ]; then
            # Escaped dots, not ['key']: jsonpath reads '/' in brackets as a separator.
            SCOPE_PMM_INSTANCE=$(kubectl get statefulset "${SCOPE_PMM_STS}" -n "${NAMESPACE}" \
                -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || true)
            if [ -z "${SCOPE_PMM_INSTANCE}" ]; then
                log "WARN" "[Scope] StatefulSet ${SCOPE_PMM_STS} carries no ${LABEL_INSTANCE} label; PMM pod lookups stay unscoped"
            fi
        fi
    fi

    if [ "${_rcs_fail}" -ne 0 ]; then
        log "ERROR" "[Scope] Refusing to continue: this namespace holds more than one install of a selected component,"
        log "ERROR" "[Scope] or its owner could not be looked up at all (see above)."
        log "ERROR" "[Scope] Name the one to operate on with --release <name>, or fix the RBAC the message names."
        return 1
    fi
    SCOPE_RESOLVED="true"
    log "INFO" "[Scope] Install scope:${SCOPE_PG_CLUSTER:+ postgresql=${SCOPE_PG_CLUSTER}}${SCOPE_CH_CHI:+ clickhouse=${SCOPE_CH_CHI}}${SCOPE_VM_CLUSTER:+ victoriametrics=${SCOPE_VM_CLUSTER}}${SCOPE_PMM_INSTANCE:+ pmm-server=${SCOPE_PMM_INSTANCE}}"
    return 0
}

# Real write probe, not [ -w ]: root and NFS squash make -w lie.
dir_writable() {   # <dir>
    [ -d "$1" ] || return 1
    _dw_probe="$1/.pmm-write-probe.$$"
    # touch, not ': >': see init_log.
    if touch "${_dw_probe}" 2>/dev/null; then rm -f "${_dw_probe}" 2>/dev/null || true; return 0; fi
    return 1
}

# mkdir -p, then 2777 on the levels it created: the writers run as different uids (PMM 1000,
# ClickHouse 101, VM and the tools 65534) and fsGroup re-owns the volume to whichever pod mounted it
# last, so no group fits. Existing directories are left alone. Best-effort.
share_mkdir() {   # <dir>
    _sm_new="" _sm_p="$1"
    while [ ! -d "${_sm_p}" ] && [ "${_sm_p}" != "/" ] && [ "${_sm_p}" != "." ]; do
        _sm_new="${_sm_p}
${_sm_new}"
        _sm_p=$(dirname "${_sm_p}")
    done
    mkdir -p "$1" 2>/dev/null || return 1
    printf '%s' "${_sm_new}" | while IFS= read -r _sm_d; do
        [ -z "${_sm_d}" ] || chmod 2777 "${_sm_d}" 2>/dev/null || true
    done
    return 0
}

manifest_path()    { echo "$(backup_root)/manifests/${1:-$(backup_id_default)}.json"; }
manifest_display() { echo "$(backup_root_display)/manifests/${1:-$(backup_id_default)}.json"; }
manifests_dir()    { echo "$(backup_root)/manifests"; }
latest_path()      { echo "$(backup_root)/latest"; }
# Bucket-relative key (clickhouse-backup S3_PATH), not an rclone spec.
clickhouse_remote_key() { echo "${S3_PREFIX}/clickhouse"; }

# Restore coordinates: the manifest's, else this run's root (DN-43). Shared with preflight.
ch_restore_bucket() { if [ -n "${MF_CH_S3_BUCKET}" ]; then printf '%s' "${MF_CH_S3_BUCKET}"; else printf '%s' "${S3_BUCKET}"; fi; }
ch_restore_path()   { if [ -n "${MF_CH_S3_PATH}" ]; then printf '%s' "${MF_CH_S3_PATH}"; else clickhouse_remote_key; fi; }

# Location recorded in the manifest: s3 URI, or the in-pod path in shared mode.
comp_location() { if [ "${S3_ENABLED}" = "true" ]; then comp_display "$1"; else comp_inpod "$1"; fi; }

# On-storage contract version (DN-41); bump only for changes older readers mis-handle.
MANIFEST_SCHEMA=1

# Schema from JSON on stdin (default 1); rc 1 if not an integer.
manifest_schema_of() {
    _mso=$(jq -r 'if has("schema") then (.schema | tostring) else "1" end' 2>/dev/null) || return 1
    case "${_mso}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "${_mso}"
}

# Every component with a <component>/<id>/ path; names match manifest keys.
BACKUP_COMPONENTS="postgresql clickhouse victoriametrics pmm-server encryption"

# Local staging; never a comp_path, which may be an rclone spec (DN-25).
staging_dir() { echo "${STATE_DIR}/.staging/$(backup_id_default)/$1"; }

# ---- Storage access -----------------------------------------------------------------
# The only code that knows s3 from shared. rc != 0 = could not; no trailing pipes (DN-03).
store_read() {
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone cat "$1"
    else cat "$1"; fi
}
# Byte range, idle-bounded only. dd, not tail -c +N: BusyBox tail fails past ~2.5 GB.
store_read_range() {   # <uri> <offset> <count>
    if [ "${S3_ENABLED}" = "true" ]; then _rclone_stream cat --offset "$2" --count "$3" "$1"
    else dd if="$1" bs=1M iflag=skip_bytes,count_bytes skip="$2" count="$3" 2>/dev/null; fi
}
store_write() {  # <path> <- stdin
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone_rcat "$1"; return; fi
    share_mkdir "$(dirname "$1")" || return 1
    # temp + rename: a failed write (ENOSPC) must not leave a truncated object behind.
    { cat > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"; } || { rm -f "$1.tmp.$$"; return 1; }
}
# Like store_write, but the mode is set before any content is written.
store_write_private() {
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone_rcat "$1"; else
        share_mkdir "$(dirname "$1")" || return 1
        # touch, not ': >': see init_log.
        touch "$1" || return 1
        # 0640 in shared mode: a peer DR namespace shares only gid 0.
        if [ "${BACKUP_TARGET}" = "shared" ]; then
            chmod 640 "$1" || return 1
        else
            chmod 600 "$1" || return 1
        fi
        cat > "$1"
    fi
}
# <mode> all|files|dirs. Empty + rc 0 = nothing there; rc != 0 = could not look (DN-04).
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

# Byte count; rc != 0 = could not look. No trailing pipe (DN-03, DN-15).
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
# Deletes treat absent as success, so retention can retry partial purges.
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
        s3_rclone_deletefile "$1" >> "${LOG_FILE}" 2>&1 && return 0
        store_absent "$1"
    else
        rm -f "$1" >> "${LOG_FILE}" 2>&1
    fi
}
# Absence must be positively established; full listing, since dirs count (DN-04).
store_absent() {
    _sa_out=$(store_list "$(dirname "$1")" 2>/dev/null) || return 1
    ! printf '%s\n' "${_sa_out}" | sed 's:/$::' | grep -Fxq "$(basename "$1")"
}

# ---- Catalog ------------------------------------------------------------------------
# Single source for which backups exist, for retention, list and restore.
catalog_ids() {
    _ci_raw=$(store_list_files "$(manifests_dir)") || return $?
    printf '%s\n' "${_ci_raw}" | sed -n 's/\.json$//p' | grep -v '^$' | sort || true
}
# Per-run manifest cache. Only successful reads are cached (DN-03); writers must drop.
CATALOG_CACHE_DIR=""

# Sanitised file name: ids come from bucket listings (DN-17).
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

# Must be called by anything that writes a manifest.
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

# The id path builders default to; set once per operation, empty until then.
backup_id_default() { echo "${CURRENT_ID}"; }

################################################################################
# 5. Kubernetes primitives (S3 access, waiters, locks)
################################################################################

# S3 access is local rclone with the pod's own credentials (DN-26).
# Every rclone call has idle/connect bounds; metadata/read/delete ops also a wall clock.
# numeric_env falls back to the default for non-positive-integer values.
RCLONE_IO_TIMEOUT="${RCLONE_IO_TIMEOUT:-60}"           # rclone --timeout: idle IO per attempt
numeric_env RCLONE_IO_TIMEOUT 60
RCLONE_CONNECT_TIMEOUT="${RCLONE_CONNECT_TIMEOUT:-15}" # rclone --contimeout
numeric_env RCLONE_CONNECT_TIMEOUT 15
RCLONE_TIMEOUT="${RCLONE_TIMEOUT:-${KUBECTL_STATUS_TIMEOUT}}"  # wall clock: cat/lsf/size/deletefile
# Falls back to the documented default, KUBECTL_STATUS_TIMEOUT.
numeric_env RCLONE_TIMEOUT "${KUBECTL_STATUS_TIMEOUT}"
RCLONE_PURGE_TIMEOUT="${RCLONE_PURGE_TIMEOUT:-300}"    # wall clock: one recursive prefix delete
numeric_env RCLONE_PURGE_TIMEOUT 300
# Streams get a long idle bound: pg_dump can be silent for minutes and rcat cannot retry.
RCLONE_STREAM_IO_TIMEOUT="${RCLONE_STREAM_IO_TIMEOUT:-300}"
numeric_env RCLONE_STREAM_IO_TIMEOUT 300

# --config "": remotes come from env; avoids a 'Config file not found' NOTICE.
# Streams: connect + stream idle bound, no wall clock.
_rclone_stream() {
    rclone --config "" --contimeout "${RCLONE_CONNECT_TIMEOUT}s" --timeout "${RCLONE_STREAM_IO_TIMEOUT}s" "$@"
}
# rclone with idle bounds AND a wall clock: _rclone_bounded <seconds> <rclone args...>
_rclone_bounded() {
    _rb_t="$1"; shift
    timeout "${_rb_t}" rclone --config "" --contimeout "${RCLONE_CONNECT_TIMEOUT}s" --timeout "${RCLONE_IO_TIMEOUT}s" "$@"
}

# rclone read ops (cat/lsf/size).
s3_rclone() {
    _rclone_bounded "${RCLONE_TIMEOUT}" "$@"
}

# Pipe stdin into an object; no wall clock (see _rclone_stream).
s3_rclone_rcat() {
    _rclone_stream rcat --s3-no-check-bucket --s3-chunk-size "${S3_STREAM_CHUNK}" "$1"
}

# DESTRUCTIVE prefix delete, kept apart from read-only s3_rclone. Benign AccessDenied (DN-31).
s3_rclone_purge() {
    _rclone_bounded "${RCLONE_PURGE_TIMEOUT}" purge --s3-no-check-bucket "$1"
}

# Single-object delete.
s3_rclone_deletefile() {
    _rclone_bounded "${RCLONE_TIMEOUT}" deletefile --s3-no-check-bucket "$1"
}

# VM endpoint override, else shared; empty = no flag (AWS).
vm_s3_endpoint() {
    if [ -n "${VM_S3_ENDPOINT}" ]; then printf '%s' "${VM_S3_ENDPOINT}"; else printf '%s' "${S3_ENDPOINT}"; fi
}

# VM region override, else shared.
vm_s3_region() {
    if [ -n "${VM_S3_REGION}" ]; then printf '%s' "${VM_S3_REGION}"; else printf '%s' "${S3_REGION}"; fi
}

# VM static-credential env, else central; secret name and key names move together.
render_temp_pod_vm_s3_keys_env() {
    if [ -n "${VM_S3_SECRET_NAME}" ]; then
        printf '%s' "
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: ${VM_S3_SECRET_NAME}, key: ${VM_S3_SECRET_ACCESS_KEY_KEY} } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: ${VM_S3_SECRET_NAME}, key: ${VM_S3_SECRET_SECRET_KEY_KEY} } }"
        return 0
    fi
    render_temp_pod_s3_keys_env
}

# Endpoint flag or nothing; a function so the empty case returns 0 under set -e.
vm_endpoint_arg() {
    _vef=$(vm_s3_endpoint)
    [ -n "${_vef}" ] && printf '%s' "-customS3Endpoint=${_vef}"
    return 0
}

# Tri-state for a namespaced object; stderr separates NotFound from Forbidden/5xx.
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
    # $4 "soft": timeout logs WARN, not ERROR.
    local ns="$1" selector="$2" max_wait="${3:-${KUBECTL_EXEC_TIMEOUT}}" severity="${4:-}" elapsed=0 count out krc
    while [ $elapsed -lt $max_wait ]; do
        # A failed kubectl get must not read as "all pods gone".
        out=$(kubectl get pods -n "${ns}" -l "${selector}" --no-headers 2>/dev/null); krc=$?
        if [ ${krc} -ne 0 ]; then
            [ "${VERBOSE}" = "true" ] && log "INFO" "kubectl get pods failed (rc=${krc}, ${selector}); not assuming gone, retrying..."
            sleep 5; elapsed=$((elapsed + 5)); continue
        fi
        # || true: grep -c exits 1 on a zero count.
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

# Wait until old pods (by UID: StatefulSet names are reused) are gone and <expected> are Ready (DN-29).
#   wait_for_pods_replaced <ns> <selector> <old-uids> <expected> [timeout]
wait_for_pods_replaced() {
    local ns="$1" selector="$2" old_uids="$3" expected="$4" max_wait="${5:-${KUBECTL_EXEC_TIMEOUT}}"
    local elapsed=0 uids ready survivors _n
    while [ $elapsed -lt $max_wait ]; do
        # A failed listing must not count as "replaced" (DN-03).
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
# Lock management — per-component Leases shared by backup and restore
# Cluster-scoped Leases, not local lockdirs: runs may not share a host (DN-37).
LOCK_LEASE_SECONDS="${LOCK_LEASE_SECONDS:-900}"
numeric_env LOCK_LEASE_SECONDS 900
LOCK_RENEW_SECONDS="${LOCK_RENEW_SECONDS:-60}"
numeric_env LOCK_RENEW_SECONDS 60
LOCK_HOLDER="${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}-$$"
# application_name of this run's pg sessions (pg_end_tagged).
PG_APPNAME="pmm-backup:${LOCK_HOLDER}"
LOCK_RENEWER_PID=""

# DNS-1123-safe lease name, one per component per install (sanitising can only over-lock).
lease_name() {
    _lnm_owner=""
    case "$1" in
        postgresql)      _lnm_owner="${SCOPE_PG_CLUSTER}" ;;
        clickhouse)      _lnm_owner="${SCOPE_CH_CHI}" ;;
        victoriametrics) _lnm_owner="${SCOPE_VM_CLUSTER}" ;;
        pmm-server)      _lnm_owner="${SCOPE_PMM_STS}" ;;
    esac
    _lnm=$(printf 'pmm-backup-%s%s' "$1" "${_lnm_owner:+-${_lnm_owner}}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')
    _lnm=$(printf '%.63s' "${_lnm}")
    printf '%s' "${_lnm}" | sed 's/[^a-z0-9]*$//'
}
# MicroTime, which is what Lease.spec.renewTime is.
lease_now() { date -u +%Y-%m-%dT%H:%M:%S.000000Z; }

# Epoch for a UTC calendar time, arithmetically: date cannot portably parse UTC (DN-37).
# epoch_utc <YYYY> <MM> <DD> <hh> <mm> <ss>
epoch_utc() {
    # Strip one leading zero: arithmetic reads 08 as octal.
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

    # days_from_civil (Hinnant), March-based year.
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

# Epoch for an RFC3339 UTC timestamp; non-Z offsets fail (unparseable = cannot tell).
epoch_from_rfc3339() {
    _efr=$(printf '%s' "${1:-}" | sed 's/\..*$//; s/Z$//; s/T/ /')
    case "${_efr}" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2046
    set -- $(printf '%s' "${_efr}" | tr -- '-:' '  ')
    epoch_utc "$1" "$2" "$3" "$4" "$5" "$6"
}

# 0 = expired, 1 = live, 2 = cannot tell (never treat as expired).
lease_expired() {   # <renewTime> <durationSeconds>
    _le_t=$(epoch_from_rfc3339 "$1") || return 2
    case "${_le_t}" in ''|*[!0-9]*) return 2 ;; esac
    case "${2:-}" in ''|*[!0-9]*) return 2 ;; esac
    [ $(( $(date +%s) - _le_t )) -gt "$2" ]
}

# Lease body; resourceVersion set only for a guarded replace.
#   lease_manifest <name> <duration> <locked-component-or-empty> <resource-version-or-empty>
lease_manifest() {
    printf 'apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata:\n  name: %s\n' "$1"
    [ -n "${4:-}" ] && printf '  resourceVersion: "%s"\n' "$4"
    printf '  labels:\n    app.kubernetes.io/component: pmm-backup-lock\n'
    [ -n "${3:-}" ] && printf '    pmm.percona.com/locked-component: %s\n' "$3"
    printf 'spec:\n  holderIdentity: %s\n  leaseDurationSeconds: %s\n  acquireTime: %s\n  renewTime: %s\n' \
        "${LOCK_HOLDER}" "$2" "$(lease_now)" "$(lease_now)"
}

# One Lease acquisition attempt, shared by component and manifest locks (DN-46).
# 0 acquired, 1 held (LEASE_STATE live|unknown|norv), 2 attempt failed, 3 lost takeover race.
LEASE_ERR="" ; LEASE_HOLDER="" ; LEASE_RENEW="" ; LEASE_STATE=""
lease_try_acquire() {   # <lease-name> <duration-seconds> [locked-component]
    _lta_n="$1" _lta_d="$2" _lta_c="${3:-}" _lta_rc=0 _lta_state="" _lta_rv="" _lta_dur=""
    _lta_body=""
    LEASE_ERR=""; LEASE_HOLDER=""; LEASE_RENEW=""; LEASE_STATE=""
    # Heredoc, not a pipe: avoids SIGPIPE noise when kubectl exits early.
    _lta_body=$(lease_manifest "${_lta_n}" "${_lta_d}" "${_lta_c}" "")
    # create, never apply: AlreadyExists is the contention signal.
    LEASE_ERR=$(kubectl create -f - -n "${NAMESPACE}" 2>&1 >/dev/null <<EOF
${_lta_body}
EOF
    ) || _lta_rc=$?
    if [ "${_lta_rc}" -eq 0 ]; then LEASE_ERR=""; return 0; fi
    case "${LEASE_ERR}" in
        *AlreadyExists*|*"already exists"*) ;;
        *) return 2 ;;
    esac
    # One read so holder, renewTime and resourceVersion are from one generation.
    _lta_state=$(kubectl get lease "${_lta_n}" -n "${NAMESPACE}" \
        -o jsonpath='{.metadata.resourceVersion}{"\t"}{.spec.holderIdentity}{"\t"}{.spec.renewTime}{"\t"}{.spec.leaseDurationSeconds}' 2>/dev/null || true)
    _lta_rv=$(printf '%s' "${_lta_state}" | cut -f1)
    LEASE_HOLDER=$(printf '%s' "${_lta_state}" | cut -f2)
    LEASE_RENEW=$(printf '%s' "${_lta_state}" | cut -f3)
    _lta_dur=$(printf '%s' "${_lta_state}" | cut -f4)
    : "${_lta_dur:=${_lta_d}}"
    _lta_rc=0; lease_expired "${LEASE_RENEW}" "${_lta_dur}" || _lta_rc=$?
    if [ "${_lta_rc}" -ne 0 ]; then
        [ "${_lta_rc}" -eq 2 ] && LEASE_STATE=unknown || LEASE_STATE=live
        return 1
    fi
    if [ -z "${_lta_rv}" ]; then LEASE_STATE=norv; return 1; fi
    # replace with observed resourceVersion: only one takeover wins (409 for the loser).
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
        2)
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
    # Only the owner may release.
    local holder
    holder=$(kubectl get lease "${lease}" -n "${NAMESPACE}" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
    if [ "${holder}" = "${LOCK_HOLDER}" ]; then
        kubectl delete lease "${lease}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    fi
    return 0
}

# Keeps held leases fresh; exits when the parent dies or after LOCK_RENEWER_MAX_SECONDS (DN-37).
LOCK_RENEWER_MAX_SECONDS="${LOCK_RENEWER_MAX_SECONDS:-86400}"
# A 0 here would stop the renewer on its first turn.
numeric_env LOCK_RENEWER_MAX_SECONDS 86400

start_lock_renewer() {
    [ -n "${LOCK_COMPONENTS}" ] || return 0
    # $$ captured outside: inside a subshell it is not the parent on every shell.
    local _lr_parent=$$
    (
        trap - EXIT INT TERM
        _lr_elapsed=0
        while :; do
            sleep "${LOCK_RENEW_SECONDS}"
            _lr_elapsed=$((_lr_elapsed + LOCK_RENEW_SECONDS))
            kill -0 "${_lr_parent}" 2>/dev/null || exit 0
            if [ "${_lr_elapsed}" -ge "${LOCK_RENEWER_MAX_SECONDS}" ]; then
                exit 0
            fi
            for _rc in ${LOCK_COMPONENTS}; do
                kubectl patch lease "$(lease_name "${_rc}")" -n "${NAMESPACE}" --type=merge \
                    -p "{\"spec\":{\"renewTime\":\"$(lease_now)\"}}" >/dev/null 2>&1 || true
            done
        done
    # Close fd 9 too: an orphaned sleep would otherwise hold the caller's stdout pipe open.
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

# Lock order MUST be alphabetical to avoid deadlocks between runs.
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

# Acquire/release every lock in LOCK_COMPONENTS.
acquire_locks() {
    local _c
    for _c in ${LOCK_COMPONENTS}; do acquire_component_lock "${_c}"; done
    start_lock_renewer
    return 0
}

release_locks() {
    local _c
    # Killed runs' remote pg_dump/pg_restore outlive their kubectl exec.
    case " ${LOCK_COMPONENTS} " in *" postgresql "*) [ "${DRY_RUN}" = "true" ] || pg_end_own_sessions ;; esac
    catalog_cache_clear
    stop_lock_renewer
    unprotect_operand_pods
    for _c in ${LOCK_COMPONENTS}; do release_component_lock "${_c}"; done
    return 0
}

# Retention must not purge an id a restore is reading: every restore holds the pmm-server lock.
# Resolves PMM whatever --<component> flags say; RETENTION_LOCK_WHY says why it could not lock.
RETENTION_LOCK_WHY=""
retention_lock() {
    RETENTION_LOCK_WHY=""
    [ "${DRY_RUN}" = "true" ] && return 0
    case " ${LOCK_COMPONENTS} " in *" pmm-server "*) return 0 ;; esac
    _rtl_rc=0
    [ -n "${SCOPE_PMM_STS}" ] || SCOPE_PMM_STS=$(resolve_one PMM "PMM Server StatefulSet" statefulset "${LABEL_PMM_SERVER}") || _rtl_rc=$?
    # rc 1 = no PMM StatefulSet: a restore resolves the same empty owner, so the lease still matches.
    if [ "${_rtl_rc}" -gt 1 ]; then
        RETENTION_LOCK_WHY="the PMM StatefulSet could not be resolved (see above)"; return 1
    fi
    _rtl_rc=0
    lease_try_acquire "$(lease_name pmm-server)" "${LOCK_LEASE_SECONDS}" pmm-server || _rtl_rc=$?
    case "${_rtl_rc}" in
        0) [ -z "${LEASE_HOLDER}" ] || log "WARN" "Took over the expired pmm-server lock (was held by '${LEASE_HOLDER}', last renewed ${LEASE_RENEW:-never})" ;;
        1) RETENTION_LOCK_WHY="the pmm-server lock is held by ${LEASE_HOLDER:-unknown} (another backup, or a restore that may be reading an old backup)"; return 1 ;;
        *) RETENTION_LOCK_WHY="the pmm-server lock could not be taken: ${LEASE_ERR:-lost a takeover race}"; return 1 ;;
    esac
    LOCK_COMPONENTS="${LOCK_COMPONENTS} pmm-server"
    stop_lock_renewer
    start_lock_renewer
}

# Hold Karpenter consolidation off the PG/CH pods this run execs into (best-effort).
# <selected-column>: 4 backup, 5 restore; must match resolve_component_scope.
protect_operand_pods() {   # <selected-column>
    local _sel _pod _pair _held _owner _pop_c _pop_col="${1:-4}"
    [ "${DRY_RUN}" = "true" ] && return 0
    for _pop_c in postgresql clickhouse; do
        comp_on "${_pop_c}" "${_pop_col}" || continue
        if [ "${_pop_c}" = "postgresql" ]; then _sel=$(pg_all_selector); else _sel=$(comp_pod_selector clickhouse); fi
        for _pod in $(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl get pods -n "${NAMESPACE}" -l "${_sel}" \
                        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
            # A hold without our owner annotation is someone else's: leave it.
            _pair=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl get pod "${_pod}" -n "${NAMESPACE}" \
                      -o jsonpath="${DISRUPTION_JSONPATH}" 2>/dev/null || true)
            _held=${_pair%%|*}
            _owner=${_pair#*|}
            if [ -n "${_held}" ] && [ -z "${_owner}" ]; then
                log "INFO" "[Disruption] ${_pod} already holds ${DISRUPTION_ANNOTATION} from elsewhere — leaving it untouched"
                continue
            fi
            timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl annotate pod "${_pod}" -n "${NAMESPACE}" --overwrite \
                "${DISRUPTION_ANNOTATION}=true" "${DISRUPTION_OWNER_ANNOTATION}=${LOCK_HOLDER}" >/dev/null 2>&1 \
                && DISRUPTION_HELD_PODS="${DISRUPTION_HELD_PODS} ${_pod}" \
                || log "WARN" "[Disruption] could not hold consolidation off ${_pod} (continuing; an eviction mid-run may fail this operation)"
        done
    done
    [ -n "${DISRUPTION_HELD_PODS}" ] && log "INFO" "[Disruption] Consolidation held off:${DISRUPTION_HELD_PODS}"
    return 0
}

# Strip only the holds this run placed; idempotent.
unprotect_operand_pods() {
    local _pod
    [ -n "${DISRUPTION_HELD_PODS}" ] || return 0
    for _pod in ${DISRUPTION_HELD_PODS}; do
        timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl annotate pod "${_pod}" -n "${NAMESPACE}" \
            "${DISRUPTION_ANNOTATION}-" "${DISRUPTION_OWNER_ANNOTATION}-" >/dev/null 2>&1 || true
    done
    DISRUPTION_HELD_PODS=""
    return 0
}

################################################################################
# 6. Catalog — manifest write/read, id ownership/age, list
################################################################################

# Namespace that produced a backup, from its manifest (DN-08).
backup_id_owner() {
    # catalog_manifest shares the cache with the chain/purge passes.
    _bio_json=$(catalog_manifest "$1") || return 1
    [ -n "${_bio_json}" ] || return 1
    printf '%s' "${_bio_json}" | jq -r '.namespace // empty' 2>/dev/null
}

# <id> without its optional backup_ prefix.
backup_id_bare() { printf '%s' "${1#backup_}"; }

# Epoch for a backup id's UTC timestamp, or non-zero: callers must skip the id (DN-07).
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

manifest_release_lease() {   # <held true|false> <lease-name>
    [ "$1" = "true" ] || return 0
    kubectl delete lease "$2" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
    return 0
}

# Merge with an existing manifests/<id>.json so concurrent runs keep siblings (DN-13).
# Result in MANIFEST_MERGED (log() uses stdout). rc 1 = refuse to write.
MANIFEST_MERGED=""
manifest_merge_existing() {   # <new-manifest-json> <lease-held> <lease-name>
    _mme_new="$1" _mme_held="$2" _mme_lease="$3" _mme_existing="" _mme_rc=0 _mme_merged=""
    MANIFEST_MERGED="${_mme_new}"

    # A failed read is forgiven only when absence is positively established.
    _mme_existing=$(store_read "$(manifest_path)" 2>/dev/null) || _mme_rc=$?
    if [ "${_mme_rc}" -ne 0 ]; then
        if store_absent "$(manifest_path)"; then
            _mme_existing=""
        else
            log "ERROR" "[Manifest] Could not read the existing $(manifest_display) (rc ${_mme_rc}), and could not prove it is absent"
            log "ERROR" "[Manifest]   Refusing to overwrite it: a concurrent component run's entries would be erased from the restore index."
            manifest_release_lease "${_mme_held}" "${_mme_lease}"
            return 1
        fi
    fi
    [ -n "${_mme_existing}" ] || return 0

    # Distinguish invalid JSON from valid JSON of an unexpected shape.
    if ! printf '%s' "${_mme_existing}" | jq -e . >/dev/null 2>&1; then
        log "WARN" "[Manifest] The existing $(manifest_display) is not valid JSON; overwriting it"
        return 0
    fi
    # This run's components win; any failed component makes it partial.
    _mme_merged=$(jq -n --argjson new "${_mme_new}" --argjson old "${_mme_existing}" '
        $new
        | .components = (($old.components // {}) + $new.components)
        # A sweep that marked it may already have deleted some of it.
        | .status = (if $old.status == "pruning" then "pruning"
                     elif $new.status == "partial"
                        or ([.components[] | .status // ""] | index("failed"))
                     then "partial" else "complete" end)' 2>/dev/null || true)
    if [ -n "${_mme_merged}" ]; then
        [ "${_mme_merged}" != "${_mme_new}" ] && log "INFO" "[Manifest] Merged component entries from a concurrent run of this backup id"
        MANIFEST_MERGED="${_mme_merged}"
        return 0
    fi
    # Only a shared --backup-id can have a sibling an overwrite would erase.
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

    # Encryption has no result entry on failure, so record its status explicitly.
    _comps="${RESULTS_JSON}"
    case "${_enc_status}" in
        skipped) ;;
        *)
            if [ "$(printf '%s' "${_comps}" | jq -r 'has("encryption")' 2>/dev/null || echo true)" != "true" ]; then
                _comps=$(printf '%s' "${_comps}" \
                    | jq --arg s "${_enc_status}" '. + {encryption: {status: $s}}' 2>/dev/null) \
                    || _comps="${RESULTS_JSON}"
                [ -n "${_comps}" ] || _comps="${RESULTS_JSON}"
            fi ;;
    esac

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

    # Merge lease for the concurrent --backup-id workflow (DN-13); bounded best effort.
    _mlease=$(lease_name "manifest-${TIMESTAMP}")
    _mlock_held=false
    _mlock_blocked=false
    _i=0
    while [ ${_i} -lt 60 ]; do
        # Permanent failure (rc 2): give up now rather than sleeping out the window.
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

    # Refuse an unmerged write only with a shared --backup-id (DN-13).
    if [ "${_mlock_held}" != "true" ] && [ -n "${BACKUP_ID}" ]; then
        log "ERROR" "[Manifest] Could not take the merge lease, and this run shares backup id '${BACKUP_ID}' with other component runs."
        log "ERROR" "[Manifest]   Writing the manifest unmerged could erase a sibling component's entry from the restore index,"
        log "ERROR" "[Manifest]   so this component is reported FAILED instead. Its data IS uploaded; re-run just this component"
        log "ERROR" "[Manifest]   once the lease is available (check RBAC on coordination.k8s.io/leases and the apiserver)."
        return 1
    fi

    manifest_merge_existing "${_manifest}" "${_mlock_held}" "${_mlease}" || return 1
    _manifest="${MANIFEST_MERGED}"

    # Only a complete full-scope backup moves latest (DN-14).
    _move_latest=$(printf '%s\n' "${_manifest}" | jq -r '
        (.status == "complete") and (.components
            | has("postgresql") and has("clickhouse")
              and has("victoriametrics") and has("pmm-server"))' 2>/dev/null || echo false)

    if printf '%s\n' "${_manifest}" | store_write "$(manifest_path)"; then
        log "INFO" "[Manifest] Wrote $(manifest_display)"
        if [ "${_move_latest}" != "true" ]; then
            log "INFO" "[Manifest] latest pointer NOT moved (run is not a complete full-scope backup)"
        elif printf '%s\n' "backup_${TIMESTAMP}" | store_write "$(latest_path)"; then
            log "INFO" "[Manifest] Updated latest -> backup_${TIMESTAMP}"
        else
            log "ERROR" "[Manifest] Could not update the latest pointer; it still names the previous backup"
            manifest_release_lease "${_mlock_held}" "${_mlease}"
            return 2
        fi
    else
        # Hard failure: the manifest is the restore index.
        log "ERROR" "[Manifest] Failed to write the manifest to $(manifest_display)"
        manifest_release_lease "${_mlock_held}" "${_mlease}"
        return 1
    fi
    manifest_release_lease "${_mlock_held}" "${_mlease}"
    return 0
}

# Render a manifest (stdin) as a per-component summary.
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

# Top-level field of the loaded manifest.
manifest_top() { manifest_field "$1" < "${MANIFEST_FILE}"; }

# Component nested scalar field of the loaded manifest: mf_field <component> <key>
mf_field() { jq -r --arg c "$1" --arg k "$2" '.components[$c][$k] // empty' "${MANIFEST_FILE}" 2>/dev/null; }

# The loaded manifest is still what the store holds (an unreadable store counts as changed).
restore_manifest_unchanged() {
    [ "$(store_read "$(manifest_path)" 2>/dev/null)" = "$(cat "${MANIFEST_FILE}" 2>/dev/null)" ]
}

# A backup's time: its timestamp id, else its manifest's `created` (custom ids).
backup_epoch() {   # <id>
    backup_id_epoch "$1" 2>/dev/null && return 0
    epoch_from_rfc3339 "$(catalog_manifest "$1" 2>/dev/null | jq -r '.created // empty' 2>/dev/null)"
}

# latest skips partial backups (DN-14); refuse only when a newer COMPLETE run skipped it.
latest_staleness_guard() {   # <resolved-id>
    _ls_id="$1"
    if ! _ls_epoch=$(backup_epoch "${_ls_id}"); then
        log "WARN" "'latest' resolves to ${_ls_id}, whose age cannot be read; staleness not checked"
        return 0
    fi
    log "INFO" "'latest' resolves to ${_ls_id}, $(( ( $(date +%s) - _ls_epoch ) / 86400 )) day(s) old"

    # "<epoch> <id>" of each newer backup; failed/partial runs are meant to leave latest put.
    _ls_cands="" _ls_failed=0 _ls_hit=""
    set -f
    for _ls_c in $(catalog_ids 2>/dev/null); do
        [ "${_ls_c}" != "${_ls_id}" ] || continue
        _ls_ce=$(backup_epoch "${_ls_c}") || continue
        [ "${_ls_ce}" -le "${_ls_epoch}" ] || _ls_cands="${_ls_cands}${_ls_ce} ${_ls_c}
"
    done
    # Newest first: a frozen schedule shows at once; only the all-failed case reads every one.
    for _ls_c in $(printf '%s' "${_ls_cands}" | sort -rn | cut -d' ' -f2); do
        if [ "$(catalog_manifest "${_ls_c}" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" = "complete" ]; then
            _ls_hit="${_ls_c}"; break
        fi
        _ls_failed=$((_ls_failed + 1))
    done
    set +f
    [ "${_ls_failed}" -eq 0 ] || log "WARN" "${_ls_failed} newer backup(s) failed or are partial; 'latest' stays on the last complete one"
    [ -n "${_ls_hit}" ] || return 0

    log "WARN" "A newer complete backup (${_ls_hit}) exists that 'latest' did not advance onto."
    log "WARN" "The pointer only moves onto a complete, full-scope backup (all of: ${CORE_COMPONENTS})."
    log "WARN" "This usually means schedule.components is set to a partial scope, in which case"
    log "WARN" "no scheduled run will ever move it again and 'latest' will keep ageing."
    # Not overridable by --yes: every non-interactive restore passes it, so it would never stop.
    log "ERROR" "Refusing to restore a stale 'latest'. Pick the backup explicitly:"
    log "ERROR" "  $(basename "$0") list    then    restore --backup-id ${_ls_id} (or ${_ls_hit}) --yes"
    return 1
}

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
    # Gate after resolving, before anything reads by it: 'latest' is bucket-controlled and reaches sh -c.
    case "${id}" in
        *[!A-Za-z0-9_-]*)
            log "ERROR" "Refusing backup id '${id}': allowed characters are A-Z a-z 0-9 _ - (resolved from ${BACKUP_ID})"
            return 1 ;;
    esac
    if [ "${BACKUP_ID}" = "latest" ]; then
        # Cached so a custom id's manifest is read once; restore_cleanup clears it.
        catalog_cache_init
        latest_staleness_guard "${id}" || return 1
    fi
    case "${id}" in backup_*) BACKUP_NAME="${id}" ;; *) BACKUP_NAME="backup_${id}" ;; esac
    CURRENT_ID="${BACKUP_NAME}"

    MANIFEST_FILE=$(mktemp /tmp/restore_manifest.XXXXXX 2>/dev/null || echo "/tmp/restore_manifest.$$")
    store_read "$(manifest_path)" > "${MANIFEST_FILE}" 2>/dev/null || true
    if [ ! -s "${MANIFEST_FILE}" ]; then
        log "ERROR" "No manifest for ${BACKUP_NAME} (target=${BACKUP_TARGET})."
        [ "${S3_ENABLED}" = "true" ] && log "ERROR" "  Looked at $(manifest_display) (check --s3-bucket/--s3-prefix and this pod's S3 credentials)"
        [ "${S3_ENABLED}" = "true" ] || log "ERROR" "  Looked at $(manifest_path)"
        return 1
    fi

    # Corrupt manifest is a hard error, not empty MF_* fields.
    if ! jq -e . "${MANIFEST_FILE}" >/dev/null 2>&1; then
        log "ERROR" "Manifest for ${BACKUP_NAME} is not valid JSON (corrupt or truncated); refusing to plan a restore from it"
        return 1
    fi

    # Refuse manifests from a newer writer (DN-41).
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
    if [ "${MF_STATUS}" = "pruning" ]; then
        log "ERROR" "${BACKUP_NAME} is being removed by retention (or a removal stopped part-way); its data may be incomplete. Pick another backup."
        return 1
    fi
    MF_PG_STATUS=$(mf_field postgresql status); MF_PG_DBS=$(mf_field postgresql databases)
    MF_CH_STATUS=$(mf_field clickhouse status);      MF_CH_NAME=$(mf_field clickhouse name)
    MF_CH_S3_BUCKET=$(mf_field clickhouse s3_bucket); MF_CH_S3_PATH=$(mf_field clickhouse s3_path)
    MF_VM_STATUS=$(mf_field victoriametrics status)
    MF_PMM_STATUS=$(mf_field pmm-server status)
    MF_ENC_STATUS=$(mf_field encryption status)

    # Manifest-controlled and reaches sh -c in the CH pod; empty = no ClickHouse.
    if [ -n "${MF_CH_NAME}" ]; then
        case "${MF_CH_NAME}" in
            *[!A-Za-z0-9_.-]*)
                log "ERROR" "Manifest records an unusable ClickHouse backup name '${MF_CH_NAME}' (allowed: A-Z a-z 0-9 _ . -); refusing to plan a restore from it"
                return 1 ;;
        esac
    fi

    # Names are space-joined, so whitespace can't be checked here; backup_postgresql refuses it.
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
    # Accept a bare timestamp, like --backup-id.
    case "${_want}" in
        ''|backup_*) ;;
        *) _want="backup_${_want}" ;;
    esac

    if [ -z "${_want}" ]; then
        echo "Backups in $(backup_root_display)/"
        echo ""
        _latest=$(catalog_latest || true)
        # Keep rc: "could not read" must differ from "empty".
        _ids_rc=0
        _ids=$(catalog_ids) || _ids_rc=$?
        if [ "${_ids_rc}" -ne 0 ]; then
            echo "  (could not READ the catalog at $(manifests_dir)/ — this is NOT the same as 'no backups')"
            echo "  Check --s3-bucket/--s3-prefix and this pod's S3 credentials (RCLONE_CONFIG_S3_* / AWS_* / the SA credential chain)."
            return 2
        fi
        if [ -z "${_ids}" ]; then echo "  (none found — the catalog is readable and empty)"; return 0; fi
        printf '  %-30s %-9s %s\n' "BACKUP ID" "STATUS" "COMPONENTS"
        for _id in ${_ids}; do
            _mj=$(catalog_manifest "${_id}" || true)
            if [ -n "${_mj}" ]; then
                _st=$(printf '%s\n' "${_mj}" | jq -r '.status // "?"' 2>/dev/null || echo "?")
                _cs=$(printf '%s\n' "${_mj}" | jq -r '.components | keys_unsorted | join(",")' 2>/dev/null || echo "-")
                # Flag manifests this version can't read (DN-41).
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
    # Reported here: clamped before log() existed (see numeric_env).
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

    # s3 mode reaches the bucket only via rclone.
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

    # Backup only; restore has validate_restore_targets.
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
# PostgreSQL Backup - pg_dump -Fc, one file per database (no pgBackRest)
################################################################################

# End pg_dump/pg_restore sessions by tag: own = this run, stale = other pmm-backup:* runs.
# Killed execs leave remote sessions holding locks. "stale" is safe only under the PG lock.
pg_end_tagged() {   # <pod> own|stale ; prints how many sessions were ended
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "$1" -c database -- \
        psql -U postgres -tA -v ON_ERROR_STOP=1 -v tag="${PG_APPNAME}" -v mode="$2" -f - 2>>"${LOG_FILE}" <<'SQL'
SELECT count(*) FILTER (WHERE pg_terminate_backend(pid, 5000)) FROM pg_stat_activity
 WHERE pid <> pg_backend_pid() AND CASE :'mode'
   WHEN 'own' THEN application_name = left(:'tag', 63)
   ELSE application_name LIKE 'pmm-backup:%' AND application_name <> left(:'tag', 63) END;
SQL
}
pg_end_own_sessions() {
    _peo_pod=$(one_pod PostgreSQL "primary pod" "$(comp_pod_selector postgresql)" 2>/dev/null) || return 0
    _peo_n=$(pg_end_tagged "${_peo_pod}" own 2>/dev/null) || return 0
    [ "${_peo_n:-0}" = "0" ] || log "INFO" "[PostgreSQL] Ended ${_peo_n} session(s) of this run left by an interrupted exec"
    return 0
}

backup_postgresql() {
    log "INFO" "[PostgreSQL] === Starting Backup (pg_dump) ==="
    local start_time=$(date +%s)

    local pg_pod _stale=""
    pg_pod=$(one_pod PostgreSQL "primary pod" "$(comp_pod_selector postgresql)") || return 1
    if [ "${DRY_RUN}" != "true" ] && _stale=$(pg_end_tagged "${pg_pod}" stale); then
        [ "${_stale:-0}" = "0" ] || log "WARN" "[PostgreSQL] Ended ${_stale} pg_dump/pg_restore session(s) left by an earlier, killed run"
    fi

    # All app databases except templates and 'postgres'.
    local dbs
    dbs=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
        psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datname <> 'postgres';" 2>/dev/null | tr -d '\r')
    if [ -z "${dbs}" ]; then
        log "ERROR" "[PostgreSQL] No application databases found to dump"
        return 1
    fi
    # Refuse names the manifest/restore can't round-trip (whitespace, ':'); checked per line.
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
        # pg_dump streams through this process (DN-26). No pipefail: pg_dump rc via a file.
        local dump_rc_file="/tmp/.pgdump_rc_$$" dump_rc
        rm -f "${dump_rc_file}" 2>/dev/null || true
        if { kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
                env PGAPPNAME="${PG_APPNAME}" pg_dump -U postgres -Fc -d "${db}" 2>>"${LOG_FILE}"
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

    # Partial dump set = failed (DN-21); return 0 so other components still run.
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
          restore: "(per db) DROP + CREATE DATABASE <db> (same owner), then pg_restore -U postgres -d <db> <db>.dump"}'
    [ "${pg_status}" = "success" ] && \
        log "INFO" "[PostgreSQL] ✓ Completed: ${ok_count} db(s), $(human_bytes ${total_bytes}), $(result_get postgresql duration)s"
    return 0
}

################################################################################
# ClickHouse Backup - Using clickhouse-backup API (system.backup_actions)
################################################################################

# ---- ClickHouse session state (resolved once per run) ----
CH_POD=""
CH_USER=""
CH_PASS=""

ch_resolve_pod() {
    CH_POD=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector clickhouse)" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "${CH_POD}" ]; then
        log "ERROR" "[ClickHouse] No pods found in namespace: ${NAMESPACE}"
        log "ERROR" "[ClickHouse] Check that the operator is running: kubectl get pods -n ${NAMESPACE}"
        return 1
    fi
    log "INFO" "[ClickHouse] Using pod: ${CH_POD}"
    return 0
}

# Fetch, then decode: base64 exits 0 on empty input. Alpine base64 needs -d.
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

# Password via stdin, never argv (DN-23).
ch_query() {
    printf '%s' "${CH_PASS}" | timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${CH_POD}" -c clickhouse -- \
        sh -c 'CLICKHOUSE_PASSWORD=$(cat); export CLICKHOUSE_PASSWORD; exec clickhouse-client --user="$1" --query="$2"' sh "${CH_USER}" "$1"
}

# system.backup_actions exists only when the clickhouse-backup sidecar is running.
ch_has_backup_api() {
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

# ch_action_field <field> <command> <since>
ch_action_field() {
    ch_query "SELECT $1 FROM system.backup_actions WHERE command='$2' AND toUnixTimestamp(start) > $3 ORDER BY start DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null
}

# ch_run_action <command> <timeout-s> <poll-s> <what> (DN-46)
# The since-fence stops a rerun matching the previous attempt's success row.
ch_run_action() {
    _cra_cmd="$1" _cra_to="$2" _cra_iv="$3" _cra_what="$4" _cra_since="" _cra_el=0 _cra_st=""
    _cra_since=$(ch_query "SELECT ifNull(toUnixTimestamp(max(start)),0) FROM system.backup_actions WHERE command='${_cra_cmd}' FORMAT TabSeparatedRaw" 2>/dev/null | tr -dc '0-9')
    [ -n "${_cra_since}" ] || _cra_since=0
    if ! ch_query "INSERT INTO system.backup_actions(command) VALUES('${_cra_cmd}')" >> "${LOG_FILE}" 2>&1; then
        log "ERROR" "[ClickHouse] Failed to enqueue ${_cra_what} (clickhouse-client exec failed)"
        return 1
    fi
    log "INFO" "[ClickHouse] Waiting for ${_cra_what} to complete..."
    # timeout 0 = no wall clock; 30 empty polls = action lost.
    _cra_lost=0
    while [ "${_cra_to}" -eq 0 ] || [ "${_cra_el}" -lt "${_cra_to}" ]; do
        _cra_st=$(ch_action_field status "${_cra_cmd}" "${_cra_since}")
        [ "${VERBOSE}" = "true" ] && log "INFO" "[ClickHouse] ${_cra_what} status: ${_cra_st}"
        if [ -n "${_cra_st}" ]; then _cra_lost=0; else _cra_lost=$((_cra_lost + 1)); fi
        if [ "${_cra_lost}" -ge 30 ]; then
            log "ERROR" "[ClickHouse] ${_cra_what}: no status for 30 polls; the sidecar lost the action (restart?)"
            return 1
        fi
        case "${_cra_st}" in
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

# Reconcile upload destination with the sidecar's S3 env (DN-11, DN-12).
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
        log "WARN" "[ClickHouse] Could not read the sidecar's S3_PATH; pinning the upload to ${CH_WANT_PATH}"
        CH_UPLOAD_EXTRA=" --env S3_BUCKET=${S3_BUCKET} --env S3_PATH=${CH_WANT_PATH}"
    elif [ "${CH_CFG_BUCKET}" = "${S3_BUCKET}" ] && [ "${_crd_path}" = "${CH_WANT_PATH}" ]; then
        :
    else
        # Honour the sidecar's override and record it.
        log "WARN" "[ClickHouse] Sidecar writes to s3://${CH_CFG_BUCKET}/${_crd_path}, not this run's ${S3_BUCKET}/${CH_WANT_PATH}"
        log "WARN" "[ClickHouse]   Honouring the sidecar and RECORDING that destination in the manifest, so the restore reads it back from there."
        log "WARN" "[ClickHouse]   Retention only reclaims storage under this run's own root, so that prefix is NOT pruned by this tool — give it its own lifecycle policy. If instead the pods have simply not rolled since the prefix changed, re-run after they have."
        CH_WANT_PATH="${_crd_path}"
        CH_LOCATION_OVERRIDE="s3://${CH_CFG_BUCKET}/${_crd_path}"
    fi
    return 0
}

# Newest REMOTE backup as incremental base (DN-10); empty = full upload.
ch_incremental_base() {
    _cib=$(ch_query "SELECT name FROM system.backup_list WHERE name LIKE 'backup_%' AND location='remote' ORDER BY created DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || true)
    # Bucket-derived and spliced into the action string: charset-gate (DN-17).
    case "${_cib}" in
        *[!A-Za-z0-9_.-]*)
            # Log to fd 9: stdout is the return value.
            log "WARN" "[ClickHouse] Ignoring remote backup name '${_cib}': it has characters outside A-Z a-z 0-9 _ . - and would be interpolated into the upload command" >&9
            log "WARN" "[ClickHouse]   Falling back to a FULL upload for this run." >&9
            return 0 ;;
    esac
    printf '%s' "${_cib}"
}

backup_clickhouse() {
    log "INFO" "[ClickHouse] === Starting Backup ==="

    # Shared mode only; in s3 mode clickhouse-backup uploads itself.
    if [ "${S3_ENABLED}" != "true" ] && [ "${DRY_RUN}" != "true" ]; then
        share_mkdir "$(comp_path clickhouse)"
    fi

    ch_resolve_pod || return 1
    ch_resolve_credentials
    ch_has_backup_api || return 1

    # Same layout as other components; retention caveats in DN-09.
    local backup_name="backup_${TIMESTAMP}"
    local ch_create_cmd="create ${backup_name}"

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[ClickHouse] [DRY RUN] pod ${CH_POD}, backup ${backup_name}, type ${CH_BACKUP_TYPE}:"
        log "INFO" "[ClickHouse] [DRY RUN]   INSERT INTO system.backup_actions(command) VALUES('${ch_create_cmd}')"
        log "INFO" "[ClickHouse] [DRY RUN]   (poll until status=success, timeout ${CH_CREATE_TIMEOUT}s)"
        if [ "${S3_ENABLED}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN]   INSERT ... VALUES('upload ${backup_name}')   (no wall clock)"
            log "INFO" "[ClickHouse] [DRY RUN]   INSERT ... VALUES('delete local ${backup_name}')"
        fi
        result_set clickhouse --arg status "success" --arg engine "clickhouse-backup" \
            --arg name "${backup_name}" --arg base "" \
            '{status: $status, engine: $engine, name: $name, base: $base,
              location: "(dry run)", size: "0B", bytes: 0, duration: 0}'
        return 0
    fi

    local start_time=$(date +%s)

    # Incremental diff happens at upload; flags go before the name.
    ch_resolve_destination
    local ch_upload_cmd="upload${CH_UPLOAD_EXTRA}"
    if [ "${CH_BACKUP_TYPE}" = "incremental" ]; then
        local prev_backup; prev_backup=$(ch_incremental_base)
        if [ -n "${prev_backup}" ]; then
            ch_upload_cmd="${ch_upload_cmd} --diff-from-remote=${prev_backup}"
            # Not independently restorable; retention keeps the base alive.
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
    local create_s=$(($(date +%s) - start_time))

    # LIMIT 1: backup_list may hold local and remote rows for one name.
    local backup_size backup_size_bytes
    backup_size=$(ch_query "SELECT formatReadableSize(size) FROM system.backup_list WHERE name='${backup_name}' ORDER BY location LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || echo "unknown")
    backup_size_bytes=$(ch_query "SELECT size FROM system.backup_list WHERE name='${backup_name}' ORDER BY location LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || echo "0")
    case "${backup_size_bytes}" in
        ''|*[!0-9]*) log "WARN" "[ClickHouse] Could not read a usable size for ${backup_name} ('${backup_size_bytes}'); recording 0 bytes"
                     backup_size_bytes=0 ;;
    esac
    [ -n "${backup_size}" ] || backup_size="unknown"
    log "INFO" "[ClickHouse]   ${backup_name}: ${backup_size}, created in ${create_s}s"
    log "INFO" "[ClickHouse]   Local: ${CH_POD}:/var/lib/clickhouse/backup/${backup_name} (hardlinks)"

    if [ "${S3_ENABLED}" = "true" ]; then
        log "INFO" "[ClickHouse] Uploading backup to S3..."
        ch_run_action "${ch_upload_cmd}" 0 10 "S3 upload" || return 1
        log "INFO" "[ClickHouse] Deleting the local backup after upload..."
        ch_query "INSERT INTO system.backup_actions(command) VALUES('delete local ${backup_name}')" >> "${LOG_FILE}" 2>&1
    elif [ "${BACKUP_TARGET}" = "shared" ]; then
        ch_archive_to_shared "${backup_name}" || return 1
    fi

    if [ "${VERBOSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Listing all backups:"
        ch_query "SELECT name, created, location, desc FROM system.backup_list ORDER BY created DESC LIMIT 10 FORMAT PrettyCompactMonoBlock" 2>&1 | tee -a "${LOG_FILE}"
    fi

    # Create + upload/archive: the upload is most of the time.
    local duration=$(($(date +%s) - start_time))
    log "INFO" "[ClickHouse] Backup completed successfully in ${duration}s"
    ch_record_result "${backup_name}" "${backup_size}" "${backup_size_bytes}" "${duration}"
    return 0
}

# Shared mode: tar the freeze backup onto the RWX volume from inside the sidecar.
ch_archive_to_shared() {   # <backup-name>
    local backup_name="$1" ch_shared_dir ch_tar_bytes
    ch_shared_dir="$(comp_inpod clickhouse)"
    CH_SHARED_TAR="${ch_shared_dir}/${backup_name}.tar.gz"
    log "INFO" "[ClickHouse] Archiving backup to the shared volume: ${CH_SHARED_TAR}"
    # Test first: on NFS, BusyBox mkdir -p on an existing path gets EACCES at a root uid 101 cannot write.
    if ! pod_sh ClickHouse "${CH_POD}" clickhouse-backup 0 \
        '{ [ -d "$1" ] || mkdir -p "$1"; } && tar -czf "$2" -C /var/lib/clickhouse/backup "$3"' \
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

# s3_bucket/s3_path are always recorded for restore/retention (DN-43).
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

# vmbackup -dst for one pod; shared by dry run and real run.
vm_dst_for_pod() {   # <pod> <backup-name>
    if [ "${S3_ENABLED}" = "true" ]; then echo "$(comp_display victoriametrics)/$1/$2"
    else echo "fs://$(comp_inpod victoriametrics)/$1/$2"; fi
}

# <pod>'s path in the last complete backup, as -origin; empty if none.
vm_origin_for_pod() {   # <pod>
    _vo_id=$(catalog_latest 2>/dev/null) || return 0
    [ -n "${_vo_id}" ] && [ "${_vo_id}" != "${CURRENT_ID}" ] || return 0
    _vo_obj=$(catalog_manifest "${_vo_id}" 2>/dev/null | jq -r --arg p "/$1/" \
        'select(.components.victoriametrics.status == "success") | .components.victoriametrics.objects[]? | select(contains($p))' \
        2>/dev/null | head -n 1)
    [ -n "${_vo_obj}" ] || return 0
    # Store-derived, spliced into argv: charset- and prefix-gated (DN-17).
    if [ "${S3_ENABLED}" = "true" ]; then _vo_pre="$(comp_display victoriametrics "${_vo_id}")/$1/"
    else _vo_pre="$(comp_inpod victoriametrics "${_vo_id}")/$1/"; fi
    case "${_vo_obj}" in
        *[!A-Za-z0-9_./:-]*|*..*) log "WARN" "[VictoriaMetrics] ignoring origin with unexpected characters: ${_vo_obj}" >&9; return 0 ;;
        "${_vo_pre}"*) ;;
        *) log "WARN" "[VictoriaMetrics] ignoring origin outside ${_vo_pre}: ${_vo_obj}" >&9; return 0 ;;
    esac
    if [ "${S3_ENABLED}" = "true" ]; then printf '%s' "${_vo_obj}"; else printf 'fs://%s' "${_vo_obj}"; fi
}

backup_victoriametrics() {
    log "INFO" "[VictoriaMetrics] === Starting Backup ==="
    local vm_start_time=$(date +%s)
    local vm_total_bytes=0 vm_objects=""

    # vmbackup needs a custom endpoint as a flag (DN-28).
    local vm_endpoint_flag=""; vm_endpoint_flag=$(vm_endpoint_arg)

    local vmstorage_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -l "$(comp_pod_selector victoriametrics)" \
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

    for pod in ${vmstorage_pods}; do
        pod_count=$((pod_count + 1))
        log "INFO" "[VictoriaMetrics] Processing vmstorage pod ${pod_count}: ${pod}"
        
        if kubectl get pod -n "${NAMESPACE}" "${pod}" \
            -o jsonpath='{.spec.containers[*].name}' | grep -q "vmbackup"; then
            log "INFO" "[VictoriaMetrics] vmbackup sidecar detected in ${pod}"
        else
            log "WARN" "[VictoriaMetrics] vmbackup sidecar not found in ${pod}, skipping"
            log "INFO" "[VictoriaMetrics] To enable: Set victoriaMetrics.vmstorage.backup.enabled=true in Helm values"
            failed_pods="${failed_pods} ${pod}"
            continue
        fi
        
        local backup_name="vm_backup_${TIMESTAMP}"
        
        # vmbackup writes backup_complete.ignore itself as its last step.
        local backup_dst="$(vm_dst_for_pod "${pod}" "${backup_name}")"
        log "INFO" "[VictoriaMetrics] Creating backup ${backup_name} -> ${backup_dst}"
        local vm_origin="" vm_origin_flag=""
        vm_origin=$(vm_origin_for_pod "${pod}")
        if [ -n "${vm_origin}" ]; then
            vm_origin_flag="-origin=${vm_origin}"
            log "INFO" "[VictoriaMetrics]   unchanged parts are copied server-side from ${vm_origin}"
        fi

        # Every level 2777 from here (vmbackup's umask gives 0700); in-pod BusyBox mkdir -p fails on NFS.
        if [ "${BACKUP_TARGET}" = "shared" ] && [ "${DRY_RUN}" != "true" ]; then
            share_mkdir "$(comp_path victoriametrics)/${pod}/${backup_name}" || true
        fi
        
        # Via pod_exec so --dry-run prints the argv only.
        local vm_output
        local vm_exit_code
        set +e
        vm_output=$(pod_exec VictoriaMetrics "${pod}" vmbackup 0 \
            /vmbackup-prod \
            -snapshot.createURL=http://localhost:8482/snapshot/create \
            -snapshot.deleteURL=http://localhost:8482/snapshot/delete \
            -storageDataPath=/vmstorage-data \
            -dst="${backup_dst}" \
            ${vm_origin_flag} \
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
                # Dry run: count as planned.
                vm_objects="${vm_objects} ${backup_dst#fs://}"
                success_count=$((success_count + 1))
                continue
            fi
            log "INFO" "[VictoriaMetrics] ✓ Completed: ${backup_name}"
            log "INFO" "[VictoriaMetrics] Location: ${backup_dst}"
            # vmbackup's subdirs aren't group-readable; widen so peer namespaces can restore.
            if [ "${BACKUP_TARGET}" = "shared" ]; then
                _vm_tree="${backup_dst#fs://}"
                pod_sh VictoriaMetrics "${pod}" vmbackup 0 \
                    'chmod -R g+rX "$1" 2>/dev/null; find "$1" -type d -exec chmod g+s {} + 2>/dev/null; true' \
                    "${_vm_tree}" >/dev/null 2>&1 || true
            fi
            vm_objects="${vm_objects} ${backup_dst#fs://}"
            success_count=$((success_count + 1))
            local pod_bytes
            pod_bytes=$(echo "${vm_output}" | grep -o 'backed up [0-9]* bytes' | grep -o '[0-9]*' || true)
            : "${pod_bytes:=0}"
            if [ "${pod_bytes}" -gt 0 ] 2>/dev/null; then
                vm_total_bytes=$((vm_total_bytes + pod_bytes))
            fi
        else
            log "ERROR" "[VictoriaMetrics] Backup creation failed for ${pod} (vmbackup exit ${vm_exit_code})"
            # Surface the tail of vmbackup output. `if`, not `&&`: set -e at loop end.
            printf '%s\n' "${vm_output}" | tail -5 | while IFS= read -r _vm_err_line; do
                if [ -n "${_vm_err_line}" ]; then
                    log "ERROR" "[VictoriaMetrics]   ${_vm_err_line}"
                fi
            done || true
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

    local pmm_pods=$(kubectl get pods -n "${NAMESPACE}" \
        -l "$(comp_pod_selector pmm-server)" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    if [ -z "${pmm_pods}" ]; then
        log "ERROR" "[PMMServer] No PMM server pods found in namespace: ${NAMESPACE}"
        log "ERROR" "[PMMServer] Check label: $(comp_pod_selector pmm-server)"
        return 1
    fi

    log "INFO" "[PMMServer] Found PMM server pods: ${pmm_pods}"

    # Refuse up front if any pod is not Running or (shared) lacks the central mount: partial = failed.
    local _bad_pods="" _phase _mounts
    for pod in ${pmm_pods}; do
        _phase=$(kubectl get pod "${pod}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "${_phase}" != "Running" ]; then
            log "ERROR" "[PMMServer] ${pod} is ${_phase:-unknown}, not Running — its ${PMM_SRV_PATH} cannot be archived"
            _bad_pods="${_bad_pods} ${pod}"
            continue
        fi
        [ "${BACKUP_TARGET}" = "shared" ] || continue
        _mounts=$(kubectl get pod "${pod}" -n "${NAMESPACE}" \
                    -o jsonpath='{.spec.containers[*].volumeMounts[*].mountPath}' 2>/dev/null || true)
        case " ${_mounts} " in
            *" ${SHARED_MOUNT_PATH} "*) ;;
            *)  log "ERROR" "[PMMServer] ${pod} has no ${SHARED_MOUNT_PATH} mount, so an in-pod tar has nowhere to write"
                log "ERROR" "[PMMServer]   In shared mode every PMM pod mounts the central volume. A StatefulSet still"
                log "ERROR" "[PMMServer]   rolling out looks exactly like this — wait for .status.currentRevision to equal"
                log "ERROR" "[PMMServer]   .status.updateRevision (pods being Ready is not the same thing) and re-run."
                _bad_pods="${_bad_pods} ${pod}" ;;
        esac
    done
    if [ -n "${_bad_pods}" ]; then
        log "ERROR" "[PMMServer] ✗ Backup refused before it started — a partial /srv backup is a failed backup. Pods:${_bad_pods}"
        return 1
    fi

    local pod_count=0
    local success_count=0
    local failed_pods=""

    for pod in ${pmm_pods}; do
        pod_count=$((pod_count + 1))
        log "INFO" "[PMMServer] Archiving ${PMM_SRV_PATH} from pod ${pod_count}: ${pod}"

        local s3_uri="$(comp_path pmm-server)/${pod}/srv.tar.gz"
        local shared_file="$(comp_inpod pmm-server)/${pod}/srv.tar.gz"
        # Same object as seen by this process (DN-05).
        local dest="$(comp_path pmm-server)/${pod}/srv.tar.gz"
        local pmm_exit size_b size_h

        # Archive /srv entries as members, skip lost+found (DN-30).
        set +e
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            # pmm-backup sidecar has rclone.
            pod_sh PMMServer "${pod}" pmm-backup 0 \
                'set -o pipefail; cd "$1" && tar -czf - --exclude=lost+found $(ls -A | grep -vxF lost+found) | rclone rcat --s3-no-check-bucket --s3-chunk-size "$3" "$2"' \
                "${PMM_SRV_PATH}" "${s3_uri}" "${S3_STREAM_CHUNK}" >> "${LOG_FILE}" 2>&1
            pmm_exit=$?
        else
            # Created here, not by uid 1000 in the pod: retention (uid 65534) must be able to delete in it.
            [ "${DRY_RUN}" = "true" ] || share_mkdir "$(comp_path pmm-server)/${pod}" || true
            # tar's rc via TAR_RC: a cut exec stream also exits 1 but leaves a partial archive behind.
            _pmm_out=$(pod_sh PMMServer "${pod}" - 0 \
                '{ [ -d "$1" ] || mkdir -p "$1"; } && cd "$2" || exit 2; tar -czf "$3" --exclude=lost+found $(ls -A | grep -vxF lost+found); echo "TAR_RC=$?"' \
                "$(comp_inpod pmm-server)/${pod}" "${PMM_SRV_PATH}" "${shared_file}" 2>&1)
            pmm_exit=$?
            printf '%s\n' "${_pmm_out}" >> "${LOG_FILE}"
            _pmm_rc=$(printf '%s\n' "${_pmm_out}" | marker_rc TAR_RC)
            if [ -n "${_pmm_rc}" ]; then
                pmm_exit="${_pmm_rc}"
            elif [ "${DRY_RUN}" != "true" ]; then
                log "ERROR" "[PMMServer] ${pod}: no TAR_RC from the pod (kubectl exit ${pmm_exit}); the exec stream was cut, so the archive cannot be trusted"
                pmm_exit=255
            fi
        fi
        set -e
        if [ "${DRY_RUN}" = "true" ]; then success_count=$((success_count + 1)); continue; fi

        # tar: 0=ok, 1=files changed/unreadable while reading (warn); >=2 fatal; 124=timeout
        if [ "${pmm_exit}" -eq 0 ] || [ "${pmm_exit}" -eq 1 ]; then
            [ "${pmm_exit}" -eq 1 ] && log "WARN" "[PMMServer] ${pod}: tar warnings (files changed/unreadable while archiving)"

            # Size from the destination, via the store layer (DN-26).
            size_b=$(store_bytes "${dest}" 2>/dev/null || echo 0)
            : "${size_b:=0}"

            if ! [ "${size_b}" -gt 0 ] 2>/dev/null; then
                log "ERROR" "[PMMServer] ${pod}: archive missing or empty at ${dest} after the upload reported success — treating as failed"
                log "ERROR" "[PMMServer]   The tar ran but nothing landed: check the destination's credentials and write permissions (see ${LOG_FILE})."
                store_delete_object "${dest}" >/dev/null 2>&1 || true
                failed_pods="${failed_pods} ${pod}"
                continue
            fi

            size_h=$(human_bytes "${size_b}")
            log "INFO" "[PMMServer] ✓ ${pod}: ${PMM_SRV_PATH} archived (${size_h})"
            success_count=$((success_count + 1))
            pmm_total_bytes=$((pmm_total_bytes + size_b))
            # Keyed by pod name = per-ordinal subdir restore resolves.
            pmm_file_sizes="${pmm_file_sizes} ${pod}:${size_b}"
            pmm_objects="${pmm_objects} $(comp_location pmm-server)/${pod}/srv.tar.gz"
        else
            log "ERROR" "[PMMServer] Backup failed for ${pod} (exit code: ${pmm_exit})"
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
    # Stage locally: comp_path is an rclone remote spec in s3 mode, not a dir.
    local key_stage_dir="$(staging_dir encryption)"
    local key_file="${key_stage_dir}/pg-encryption-key.yaml"
    local key_dest="$(comp_path encryption)/pg-encryption-key.yaml"
    
    # Only NotFound means "not configured"; a failed lookup fails the backup.
    local _ek_state=0
    k8s_object_state secret "${secret_name}" || _ek_state=$?
    case "${_ek_state}" in
        0) ;;
        1)
            log "WARN" "[EncryptionKey] Secret not found: ${secret_name}"
            log "INFO" "[EncryptionKey] This is normal if PMM encryption is not configured"
            return 2 ;;  # Not an error, just not configured
        *)
            log "ERROR" "[EncryptionKey] Could not check Secret ${secret_name} (apiserver error or RBAC) — the key is NOT in this backup"
            return 1 ;;
    esac

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[EncryptionKey] [DRY RUN] Commands (secret: ${secret_name}):"
        log "INFO" "[EncryptionKey] [DRY RUN]   \$ kubectl get secret ${secret_name} -n ${NAMESPACE} -o json | \\"
        log "INFO" "[EncryptionKey] [DRY RUN]       jq 'del(.metadata.resourceVersion, .metadata.uid, ...)' > ${key_file}"
        log "INFO" "[EncryptionKey] [DRY RUN]   \$ chmod 600 ${key_file}"
        return 0
    fi

    if ! mkdir -p "${key_stage_dir}"; then
        log "ERROR" "[EncryptionKey] Failed to create staging directory: ${key_stage_dir}"
        return 1
    fi
    
    log "INFO" "[EncryptionKey] Exporting secret to clean JSON"
    
    if ! ensure_jq; then
        log "ERROR" "[EncryptionKey] jq is required to export the secret but is not on PATH"
        log "ERROR" "[EncryptionKey]   The chart's backup-tools container installs it at start-up; see its log:"
        log "ERROR" "[EncryptionKey]   kubectl logs deploy/<release>-backup-tools -n ${NAMESPACE}"
        return 1
    fi
    
    # umask, not chmod-after. 0640 in shared mode so a cross-namespace restore (gid 0) can read it.
    _ek_umask=077
    [ "${BACKUP_TARGET}" = "shared" ] && _ek_umask=027
    if ! ( umask "${_ek_umask}"; kubectl get secret "${secret_name}" -n "${NAMESPACE}" -o json | \
        jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.namespace, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]) | if .metadata.annotations == {} then del(.metadata.annotations) else . end' \
        > "${key_file}" ); then
        # Reap the partial file (DN-24).
        rm -f "${key_file}" 2>/dev/null || true
        log "ERROR" "[EncryptionKey] Failed to export secret"
        return 1
    fi
    if [ -s "${key_file}" ]; then
        
        chmod "$([ "${BACKUP_TARGET}" = "shared" ] && echo 640 || echo 600)" "${key_file}"
        
        local checksum; checksum=$(sha256_of "${key_file}")
        [ -n "${checksum}" ] || checksum="N/A"
        # printf '%.16s', not ${checksum:0:16}: fatal on dash.
        local checksum_short
        checksum_short=$(printf '%.16s' "${checksum}")
        # Recorded in the manifest; prepare_encryption_key verifies it.
        [ "${checksum}" = "N/A" ] && checksum=""

        local file_size=$(du -h "${key_file}" | cut -f1)
        log "INFO" "[EncryptionKey] Exported successfully (size: ${file_size}, sha256: ${checksum_short}...)"
        log "INFO" "[EncryptionKey] ✓ Local export completed"
        log "INFO" "[EncryptionKey]   Location: ${key_file}"
        log "INFO" "[EncryptionKey]   Checksum: ${checksum_short}..."

        # Must reach the destination, or a DR restore cannot decrypt PG.
        local enc_dest_display="$(comp_display encryption)/pg-encryption-key.yaml"
            if store_write_private "${key_dest}" < "${key_file}"; then
                result_set encryption --arg status "success" --arg location "${enc_dest_display}" \
                    --arg sha "${checksum}" --argjson bytes "$(wc -c < "${key_file}" | tr -d ' ')" \
                    '{status: $status, location: $location, sha256: $sha, bytes: $bytes}'
                log "INFO" "[EncryptionKey]   Stored at ${enc_dest_display}"
                # Reap the staged plaintext now (DN-24).
                rm -f "${key_file}" 2>/dev/null || true
            else
                # Hard failure; still reap the staged plaintext (DN-24).
                rm -f "${key_file}" 2>/dev/null || true
                log "ERROR" "[EncryptionKey]   Staged export OK but storing it FAILED (S3 credentials / bucket reachable?)"
                log "ERROR" "[EncryptionKey]   The key is not in S3; a DR restore of this backup could not decrypt PostgreSQL data"
                return 1
            fi

        return 0
    else
        rm -f "${key_file}" 2>/dev/null || true
        log "ERROR" "[EncryptionKey] Failed to export secret (the staged file is empty)"
        return 1
    fi
}

################################################################################
# 8. Restore — validation gate, scale down/up, one function per component
################################################################################

# Tri-state: 0 present, 1 absent/empty, 2 check failed (DN-15). rclone size on a missing path exits 0.
s3_object_state() {
    local bytes rc=0
    bytes=$(store_bytes "$1" 2>/dev/null) || rc=$?
    [ "${rc}" -ne 0 ] && return 2
    [ "${bytes:-0}" -gt 0 ] 2>/dev/null
}

# Tri-state size check vs manifest (DN-16); detail in OBJECT_SIZE_DETAIL.
OBJECT_SIZE_DETAIL=""
object_size_state() {   # <path> <expected-bytes-or-empty>
    OBJECT_SIZE_DETAIL=""
    local expect="${2:-}" actual rc=0
    actual=$(store_bytes "$1" 2>/dev/null) || rc=$?
    [ "${rc}" -ne 0 ] && return 2
    case "${actual}" in ''|*[!0-9]*) return 2 ;; esac
    [ "${actual}" -gt 0 ] || return 1
    # Older backups record no size: non-empty is enough.
    case "${expect}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${actual}" -eq "${expect}" ] && return 0
    OBJECT_SIZE_DETAIL="manifest recorded ${expect} bytes, destination holds ${actual} — truncated or overwritten"
    return 1
}

# Probe once so a failed listing is not reported as N absent ordinals.
backup_subdir_listable() {
    store_list_dirs "$(comp_path "$1")" >/dev/null 2>&1
}

# <state> <comp> <what> [hint]; non-zero means fail.
report_state() {
    local state="$1" comp="$2" what="$3" hint="${4:-}"
    case "${state}" in
        0) return 0 ;;
        1) log "ERROR" "[Preflight] ${comp}: ${what} missing or empty${hint:+ (${hint})}" ;;
        *) log "ERROR" "[Preflight] ${comp}: could not check ${what} — the check itself failed; NOT treating this as 'backup absent'${hint:+ (${hint})}" ;;
    esac
    return 1
}

# rclone S3 env block for temp restore pods (8-space indent); single source for all of them.
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
    # Single-quoted format: no backslash before the quotes, printf would emit it verbatim.
    [ -n "${S3_ENDPOINT}" ] && printf '\n        - name: RCLONE_CONFIG_S3_ENDPOINT\n          value: "%s"' "${S3_ENDPOINT}"
    printf '%s' "${TEMP_POD_S3_KEYS_ENV}"
}

# Override, else cached resolved value; must never log (callers use $( )).
resolved_or_override() {   # <override> <resolved>
    if [ -n "$1" ]; then printf '%s' "$1"; return 0; fi
    [ -n "$2" ] || return 1
    printf '%s' "$2"
}

vmstorage_pvc_name() { echo "${VM_STORAGE_PVC_PREFIX}$1"; }

# /srv PVC prefix = claim template mounted at PMM_SRV_PATH (DN-39). Resolve once, in the parent.
resolve_pmm_storage_pvc_prefix() {   # <statefulset-name>
    [ -z "${PMM_STORAGE_PVC_PREFIX}" ] || return 0            # explicit override wins
    [ -z "${PMM_STORAGE_PVC_PREFIX_RESOLVED}" ] || return 0    # already resolved this run
    local _pspp_json="" _pspp_name=""
    _pspp_json=$(kubectl get statefulset "$1" -n "${NAMESPACE}" -o json 2>/dev/null) || _pspp_json=""
    if [ -n "${_pspp_json}" ]; then
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
        # Refuse rather than guess: a wrong PVC fails after PMM is at 0.
        log "ERROR" "PMM ${1}: could not read a volumeClaimTemplate name from the StatefulSet."
        log "ERROR" "  The /srv restore mounts PVCs BY NAME, so guessing one would fail after PMM is scaled to 0."
        log "ERROR" "  Check RBAC on statefulsets, or set PMM_STORAGE_PVC_PREFIX=<storage.name>- explicitly."
        return 1
    fi
    PMM_STORAGE_PVC_PREFIX_RESOLVED="${_pspp_name}-"
    log "INFO" "PMM ${1}: /srv PVC name prefix is '${PMM_STORAGE_PVC_PREFIX_RESOLVED}' (from the StatefulSet's volumeClaimTemplate)"
    return 0
}

# Pure accessor, safe in $( ).
pmm_storage_pvc_prefix() { resolved_or_override "${PMM_STORAGE_PVC_PREFIX}" "${PMM_STORAGE_PVC_PREFIX_RESOLVED}"; }

pmm_storage_pvc_name() {   # <statefulset-name> <ordinal>
    _pspn_pfx=$(pmm_storage_pvc_prefix "$1") || return 1
    printf '%s%s-%s' "${_pspn_pfx}" "$1" "$2"
}

# /srv restore image from the StatefulSet (DN-39); s3 prefers pmm-backup (has rclone).
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

# Pure accessor, safe in $( ).
pmm_restore_image() { resolved_or_override "${PMM_RESTORE_IMAGE}" "${PMM_RESTORE_IMAGE_RESOLVED}"; }

# /srv restore pod identity from the StatefulSet template (DN-48); _DONE caches since "" is valid.
PMM_RESTORE_SEC_CTX=""
PMM_RESTORE_SCHED=""
PMM_RESTORE_SEC_CTX_DONE=""
resolve_pmm_restore_security_context() {   # <statefulset-name>
    [ -z "${PMM_RESTORE_SEC_CTX_DONE}" ] || return 0
    PMM_RESTORE_SEC_CTX=$(security_context_of statefulset "$1")
    PMM_RESTORE_SCHED=$(scheduling_of statefulset "$1")
    PMM_RESTORE_SEC_CTX_DONE=yes
    log "INFO" "PMM ${1}: /srv restore pod inherits scheduling:$(sched_oneline "${PMM_RESTORE_SCHED}")"
    if [ -n "${PMM_RESTORE_SEC_CTX}" ]; then
        log "INFO" "PMM ${1}: /srv restore pod takes the StatefulSet's own identity:$(sec_ctx_oneline "${PMM_RESTORE_SEC_CTX}")"
    else
        log "INFO" "PMM ${1}: StatefulSet sets no runAsUser/runAsGroup/fsGroup, so the /srv restore pod carries none either (the platform's SCC assigns them, or the image's user applies)"
    fi
    return 0
}

# Pure accessor; empty is valid.
pmm_restore_security_context() { printf '%s' "${PMM_RESTORE_SEC_CTX}"; }

# Central backup PVC for shared-mode temp pods.
resolve_central_backup_pvc() {   # [tag]
    _rcbp_tag="${1:-CentralVolume}"
    [ -n "${CENTRAL_BACKUP_PVC}" ] && return 0
    local bt_pod="" bt_sel=""
    # Prefer this release's pod; fall back to any (cross-namespace DR, DN-33).
    if [ -n "${RELEASE_NAME:-}" ]; then
        bt_sel="${LABEL_BACKUP_TOOLS},app.kubernetes.io/instance=${RELEASE_NAME}"
        bt_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${bt_sel}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [ -z "${bt_pod}" ]; then
        [ -z "${bt_sel}" ] || log "INFO" "No backup-tools pod for release '${RELEASE_NAME}' in ${NAMESPACE}; falling back to any backup-tools pod in the namespace"
        bt_pod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_BACKUP_TOOLS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [ -n "${bt_pod}" ]; then
        CENTRAL_BACKUP_PVC=$(kubectl get pod -n "${NAMESPACE}" "${bt_pod}" -o jsonpath='{.spec.volumes[?(@.name=="central-backup-storage")].persistentVolumeClaim.claimName}' 2>/dev/null || true)
    fi
    if [ -z "${CENTRAL_BACKUP_PVC}" ]; then
        # Direct nfs: volume has no claimName; temp pods can only mount a PVC.
        if [ -n "${bt_pod}" ] && [ -n "$(kubectl get pod -n "${NAMESPACE}" "${bt_pod}" -o jsonpath='{.spec.volumes[?(@.name=="central-backup-storage")].nfs.server}' 2>/dev/null || true)" ]; then
            log "ERROR" "[${_rcbp_tag}] The central backup volume is a direct NFS mount, not a PVC."
            log "ERROR" "  The temp restore pod can only mount a PersistentVolumeClaim, so this restore needs the"
            log "ERROR" "  shared volume exposed as one: create a PV/PVC for the same export and set"
            log "ERROR" "  centralBackupStorage.existingClaim pointed at its claim — or drop the"
            log "ERROR" "  components that need it (--skip-victoriametrics / --skip-pmm-server)."
            return 1
        fi
        log "ERROR" "[${_rcbp_tag}] Central backup PVC not found (set CENTRAL_BACKUP_PVC or run from backup-tools)"
        return 1
    fi
    return 0
}

# vmrestore image from the chart env. No :latest (DN-39). Never logs.
get_vmrestore_image() {
    [ -n "${VMRESTORE_IMAGE}" ] || return 1
    echo "${VMRESTORE_IMAGE}"
}

# Restore order: key first, data stores (may run concurrently), PMM /srv last.
RESTORE_COMPONENTS="encryption postgresql clickhouse victoriametrics pmm-server"
RESTORE_DB_COMPONENTS="postgresql clickhouse victoriametrics"

# Does this backup actually carry the component, per its manifest?
restore_has() { [ "$(comp_val "$1" 7 2>/dev/null)" = "success" ]; }
# Selected AND present in the backup: the one predicate gating a component restore.
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
        if [ "${EXPLICIT_SELECTION}" != "true" ] && [ "$(comp_val "${_sdc_key}" 7)" = "success" ]; then
            eval "$(comp_rvar "${_sdc_key}")=true"
        fi
        # --skip-* wins over everything.
        if [ "$(comp_val "${_sdc_key}" 6)" = "true" ]; then
            eval "$(comp_rvar "${_sdc_key}")=false"
        fi
    done
    return 0
}

# Default selection only: " <key>(<status>)" for each failed/pruned component not --skip'ed.
# Absent components (a scoped backup) carry no status and pass.
default_restore_gaps() {
    _drg_out="" _drg_k="" _drg_st=""
    [ "${EXPLICIT_SELECTION}" = "true" ] && return 0
    for _drg_k in ${RESTORE_COMPONENTS}; do
        _drg_st=$(comp_val "${_drg_k}" 7)
        case "${_drg_st}" in failed|pruned) comp_on "${_drg_k}" 6 || _drg_out="${_drg_out} ${_drg_k}(${_drg_st})" ;; esac
    done
    printf '%s' "${_drg_out}"
}

# The key must match the PostgreSQL data PMM runs on: it follows a PostgreSQL restore (as it is
# captured with one), and without one it is applied only when asked for by name.
scope_encryption_key() {
    if restore_do postgresql && [ "${SKIP_ENCRYPTION_KEY}" != "true" ] && restore_has encryption; then
        RESTORE_ENCRYPTION_KEY=true
    elif [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${ENC_KEY_REQUESTED}" != "true" ]; then
        RESTORE_ENCRYPTION_KEY=false
        log "WARN" "[EncryptionKey] Not restoring the encryption key: PostgreSQL is not being restored, and PMM must keep the key that matches the PostgreSQL data in place. Pass --encryption-key to replace it anyway."
    fi
    return 0
}

# Server-side dry-run of the real temp pod spec (DN-15); also scan for PodSecurity warn output.
validate_temp_pod_admission() {   # <role> <pvc> <image> <sec-ctx> <sched>
    local _vtpa_role="$1" _vtpa_pvc="$2" _vtpa_image="$3" _vtpa_sec="${4:-}" _vtpa_sched="${5:-}"
    local _vtpa_out _vtpa_rc=0 _vtpa_name="pmm-restore-admission-probe"
    _vtpa_out=$(render_temp_restore_pod "${_vtpa_name}" "${_vtpa_pvc}" "${_vtpa_image}" "${_vtpa_role}" \
                    "${_vtpa_sec}" "${_vtpa_sched}" \
                | kubectl create --dry-run=server -f - -n "${NAMESPACE}" 2>&1) || _vtpa_rc=$?
    if [ "${_vtpa_rc}" -ne 0 ]; then
        log "ERROR" "[Preflight] the ${_vtpa_role} restore pod would be REJECTED by this namespace; nothing has been changed"
        printf '%s\n' "${_vtpa_out}" | while IFS= read -r _vtpa_l; do
            if [ -n "${_vtpa_l}" ]; then log "ERROR" "[Preflight]   ${_vtpa_l}"; fi
        done || true
        return 1
    fi
    case "${_vtpa_out}" in
        *"would violate"*)
            log "ERROR" "[Preflight] the ${_vtpa_role} restore pod violates this namespace's pod-security policy"
            log "ERROR" "[Preflight]   It is only a WARNING today, so the create would succeed — but it will be denied"
            log "ERROR" "[Preflight]   the moment the namespace moves from 'warn' to 'enforce', mid-restore."
            printf '%s\n' "${_vtpa_out}" | while IFS= read -r _vtpa_l; do
                if [ -n "${_vtpa_l}" ]; then log "ERROR" "[Preflight]   ${_vtpa_l}"; fi
            done || true
            return 1 ;;
    esac
    log "INFO" "[Preflight] ${_vtpa_role} restore pod passes admission (quota, SCC/pod-security, webhooks)"
    return 0
}

# Run the real temp-pod spec once with `-version`, placed by the scheduler, before scale-down.
# Fails on an image that will not pull or run; unscheduled or evicted proves nothing, so it warns.
vm_image_pull_probe() {   # <image> <sec-ctx> <sched>
    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[Preflight] [DRY RUN] would run ${1} once to prove it pulls"; return 0
    fi
    _vipp_name="vm-image-probe" _vipp_rc=0 _vipp_st="" _vipp_t=0
    clear_leftover_temp_pod "${_vipp_name}" Preflight
    [ -n "${TEMP_PODS_MARKER}" ] && printf '%s\n' "${_vipp_name}" >> "${TEMP_PODS_MARKER}" 2>/dev/null || true
    _vipp_out=$(render_temp_restore_pod "${_vipp_name}" "" "$1" probe "$2" "$3" \
        | kubectl create -f - -n "${NAMESPACE}" 2>&1) || _vipp_rc=$?
    printf '%s\n' "${_vipp_out}" | append_to_log
    if [ "${_vipp_rc}" -ne 0 ]; then
        log "ERROR" "[Preflight] could not create the vmrestore image probe; nothing has been changed"; return 1
    fi
    # phase|pod reason|waiting reason|exit code|PodScheduled reason
    while [ "${_vipp_t}" -lt 300 ]; do
        _vipp_st=$(kubectl get pod -n "${NAMESPACE}" "${_vipp_name}" -o jsonpath='{.status.phase}|{.status.reason}|{.status.containerStatuses[0].state.waiting.reason}|{.status.containerStatuses[0].state.terminated.exitCode}|{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null) || _vipp_st=""
        case "${_vipp_st}" in
            Succeeded*|Failed*|*ErrImagePull*|*ImagePullBackOff*|*InvalidImageName*|*CreateContainer*) break ;;
        esac
        sleep 5; _vipp_t=$((_vipp_t + 5))
    done
    delete_temp_restore_pod "${_vipp_name}"
    case "${_vipp_st}" in
        Succeeded*) log "INFO" "[Preflight] vmrestore image ${1} pulls and runs"; return 0 ;;
        *ErrImagePull*|*ImagePullBackOff*|*InvalidImageName*|*CreateContainer*|Failed\|*\|*\|[1-9]*)
            log "ERROR" "[Preflight] the vmrestore image ${1} does not pull or run (${_vipp_st}); nothing has been changed"; return 1 ;;
        Failed*|*Unschedulable)
            log "WARN" "[Preflight] could not prove ${1} pulls (probe ${_vipp_st}: evicted or unschedulable); continuing"; return 0 ;;
    esac
    # Scheduled but not running after 300s: the real pods would wait the same pull, with PMM down.
    log "ERROR" "[Preflight] the vmrestore image ${1} did not start within 300s (${_vipp_st:-no status}); nothing has been changed"
    return 1
}

validate_temp_pod_credentials() {
    local fail=0
    # A missing Secret/SA is rejected at admission, after PMM is down.
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
                # Not jsonpath: Secret keys may contain dots. {{if $v}} rejects empty values.
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
    # --yes does not bypass this; only --skip-encryption-key (DN-44).
    local _enc_path="$(comp_path encryption)/pg-encryption-key.yaml"
    _st=0; s3_object_state "${_enc_path}" || _st=$?
    report_state "${_st}" "encryption" "key ${_enc_path}" "--skip-encryption-key to drop it" || fail=1
    return ${fail}
}

validate_restore_postgresql() {
    local fail=0
    local _pgpod="" _db
    _pgpod=$(one_pod PostgreSQL "primary pod" "$(comp_pod_selector postgresql)" || true)
    if [ -z "${_pgpod}" ]; then
        log "ERROR" "[Preflight] postgresql: no single primary pod matching '$(comp_pod_selector postgresql)' (--skip-postgresql to drop it)"
        fail=1
    fi
    if [ -z "${MF_PG_DBS}" ]; then
        log "ERROR" "[Preflight] postgresql: manifest records no databases"
        fail=1
    else
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
    _chpod=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector clickhouse)" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${_chpod}" ]; then
        log "ERROR" "[Preflight] clickhouse: no pod matching '$(comp_pod_selector clickhouse)' (--skip-clickhouse to drop it)"
        fail=1
    elif [ -z "${MF_CH_NAME}" ]; then
        log "ERROR" "[Preflight] clickhouse: manifest records no backup name"
        fail=1
    elif [ "${S3_ENABLED}" = "true" ]; then
        # Same --env as restore_clickhouse (DN-33); list rc checked apart from the match (DN-15).
        # Own timeout: `list remote` reads metadata of every remote backup.
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
    # shared mode: the tarball lives inside the CH pod, not in BACKUP_DIR.
    else
        # argv, not sh -c (DN-17); rc 1 with empty stderr means absent, else kubectl failed.
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
    _vmpods=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector victoriametrics)" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    # Scope's cached answer; live resolve only when unset (unit tests).
    _vmcluster="${SCOPE_VM_CLUSTER}"
    [ -n "${_vmcluster}" ] || _vmcluster=$(resolve_one VictoriaMetrics "VMCluster" vmcluster || true)
    if [ -z "${_vmpods}" ]; then
        log "ERROR" "[Preflight] victoriametrics: no vmstorage pods matching '$(comp_pod_selector victoriametrics)' (--skip-victoriametrics to drop it)"
        fail=1
    fi
    if [ -z "${_vmcluster}" ]; then
        log "ERROR" "[Preflight] victoriametrics: no VMCluster resource; the restore could not scale it safely"
        fail=1
    fi
    # Resolve the image while the tier is still up (DN-15).
    if [ -n "${_vmpods}" ]; then
        _vmimg=$(get_vmrestore_image) || _vmimg=""
        if [ -z "${_vmimg}" ]; then
            log "ERROR" "[Preflight] victoriametrics: no vmrestore image — VMRESTORE_IMAGE is unset."
            log "ERROR" "[Preflight]   Set victoriaMetrics.vmstorage.backup.restoreImage in the chart, or VMRESTORE_IMAGE=<image>; it must match the vmstorage version that wrote the backup."
            fail=1
        fi
        # Admission probe with the real spec before scale-down.
        if [ -n "${_vmimg}" ]; then
            local _vmprobe_pvc="" _vmprobe_p="" _vmprobe_sec="" _vmprobe_sched=""
            _vmprobe_p=$(echo "${_vmpods}" | awk '{print $1}')
            _vmprobe_pvc="${VM_STORAGE_PVC_PREFIX}${_vmprobe_p}"
            _vmprobe_sec=$(security_context_of pod "${_vmprobe_p}" vmstorage)
            _vmprobe_sched=$(scheduling_of pod "${_vmprobe_p}")
            validate_temp_pod_admission vm "${_vmprobe_pvc}" "${_vmimg}" "${_vmprobe_sec}" "${_vmprobe_sched}" || fail=1
            # No sidecar runs the image any more: prove it pulls while the tier is still up.
            [ "${fail}" -ne 0 ] || vm_image_pull_probe "${_vmimg}" "${_vmprobe_sec}" "${_vmprobe_sched}" || fail=1
        fi
    fi
    # Shard-count check hoisted here so it aborts with PMM still up.
    if [ -n "${_vmpods}" ]; then
        _vmtarget=$(echo "${_vmpods}" | wc -w | tr -d ' ')
        _vmsrc=$(vm_src_ordinal_count 2>/dev/null || echo "")
        if [ -n "${_vmsrc}" ] && [ "${_vmsrc}" -gt 0 ] 2>/dev/null && [ "${_vmsrc}" != "${_vmtarget}" ]; then
            log "ERROR" "[Preflight] victoriametrics: shard-count mismatch — backup has ${_vmsrc} vmstorage ordinal(s), target has ${_vmtarget}. Set vmstorage replicaCount to ${_vmsrc} and retry."
            fail=1
        else
            _vmname="vm_backup_${BACKUP_NAME#backup_}"
            # Prove the parent listing works before reading per-ordinal absence.
            local _vm_skip=false
            if ! backup_subdir_listable victoriametrics; then
                report_state 2 "victoriametrics" "${BACKUP_NAME}/victoriametrics/" || fail=1
                _vm_skip=true
            fi
            if [ "${_vm_skip}" != "true" ]; then
            for _p in ${_vmpods}; do
                _ord="${_p##*-}"
                # Target PVC must resolve before vmstorage is scaled to 0 (DN-39).
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
                # Listed is not populated: check each source dir holds data (DN-03).
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
    _sts="${SCOPE_PMM_STS}"
    [ -n "${_sts}" ] || _sts=$(resolve_one PMM "PMM Server StatefulSet" statefulset "${LABEL_PMM_SERVER}" || true)
    if [ -z "${_sts}" ]; then
        log "ERROR" "[Preflight] pmm-server: no StatefulSet matching '${LABEL_PMM_SERVER}' (--skip-pmm-server to drop it)"
        fail=1
    else
        _replicas=$(pmm_replica_count "${_sts}")
        # A non-numeric count would skip the loop and pass the gate silently.
        case "${_replicas}" in
            ''|*[!0-9]*)
                log "ERROR" "[Preflight] pmm-server: replica count '${_replicas}' is not a number; cannot determine which ordinals to validate"
                fail=1
                _replicas=0
                ;;
        esac
        if [ "${_replicas}" -gt 0 ] && ! backup_subdir_listable pmm-server; then
            report_state 2 "pmm-server" "${BACKUP_NAME}/pmm-server/" || fail=1
            _replicas=0
        fi
        # Resolved once here; restore_pmm_server reads the same cached value.
        if [ "${_replicas}" -gt 0 ] && ! resolve_pmm_storage_pvc_prefix "${_sts}"; then
            log "ERROR" "[Preflight] pmm-server: cannot determine the /srv PVC names (--skip-pmm-server to drop it)"
            fail=1
            _replicas=0
        fi
        if [ "${_replicas}" -gt 0 ] && ! resolve_pmm_restore_image "${_sts}"; then
            log "ERROR" "[Preflight] pmm-server: cannot determine the /srv restore pod image (--skip-pmm-server to drop it)"
            fail=1
            _replicas=0
        fi
        # Not a gate: empty is valid (DN-48); logs the identity before scale-down.
        if [ "${_replicas}" -gt 0 ]; then
            resolve_pmm_restore_security_context "${_sts}"
            local _pprobe="" _pimg=""
            _pprobe=$(pmm_storage_pvc_name "${_sts}" 0 2>/dev/null) || _pprobe=""
            # Resolved image, not the PMM_RESTORE_IMAGE override (empty on chart installs).
            _pimg=$(pmm_restore_image)
            if [ -n "${_pprobe}" ] && [ -n "${_pimg}" ]; then
                validate_temp_pod_admission pmm "${_pprobe}" "${_pimg}" \
                    "${PMM_RESTORE_SEC_CTX}" "${PMM_RESTORE_SCHED}" || fail=1
            fi
        fi
        while [ "${_i}" -lt "${_replicas}" ]; do
            # Target PVC must resolve while PMM is up (DN-15, DN-39).
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
                # restore_pmm_server only WARNs here; fail the gate instead.
                log "ERROR" "[Preflight] pmm-server: backup has no /srv directory for ordinal ${_i} (${_replicas} replica(s) expected)"
                fail=1
            else
                _pexp=$(jq -r --arg p "${_sub}" '.components["pmm-server"].files[$p] // empty' "${MANIFEST_FILE}" 2>/dev/null || true)
                _st=0; object_size_state "$(comp_path pmm-server)/${_sub}/srv.tar.gz" "${_pexp}" || _st=$?
                report_state "${_st}" "pmm-server" "srv.tar.gz for ordinal ${_i} (${_sub})${OBJECT_SIZE_DETAIL:+ — ${OBJECT_SIZE_DETAIL}}" "--skip-pmm-server to drop it" || fail=1
            fi
            _i=$((_i + 1))
        done
    fi
    return ${fail}
}

# Pre-restore gate: runs before scale_down_pmm, fails closed, reports all (DN-15).
validate_restore_targets() {
    local fail=0 _vrt_c="" _vrt_fn="" _vrt_st=0

    log "INFO" "Validating restore targets for ${BACKUP_NAME} (nothing has been changed yet)..."

    # Central backup PVC resolved before scale-down: temp pods and admission probes need it.
    if [ "${S3_ENABLED}" != "true" ] \
       && { restore_do victoriametrics || restore_do pmm-server; }; then
        if ! resolve_central_backup_pvc Preflight; then
            fail=1
        else
            # Admission does not check the PVC exists; a missing claim leaves the pod Pending.
            _vrt_st=0; k8s_object_state persistentvolumeclaim "${CENTRAL_BACKUP_PVC}" || _vrt_st=$?
            if [ "${_vrt_st}" -eq 1 ]; then
                log "ERROR" "[Preflight] central backup volume: PVC '${CENTRAL_BACKUP_PVC}' does not exist in ${NAMESPACE},"
                log "ERROR" "[Preflight]   so every temp restore pod would stay Pending — with PMM already scaled to 0."
                log "ERROR" "[Preflight]   Set CENTRAL_BACKUP_PVC, or run from a backup-tools pod that mounts the right claim."
                fail=1
            elif [ "${_vrt_st}" -ne 0 ]; then
                log "ERROR" "[Preflight] central backup volume: could not check PVC '${CENTRAL_BACKUP_PVC}' (403/timeout?); NOT treating this as 'absent'"
                fail=1
            fi
        fi
    fi
    validate_temp_pod_credentials || fail=1
    for _vrt_c in ${RESTORE_COMPONENTS}; do
        restore_do "${_vrt_c}" || continue
        _vrt_fn="validate_restore_$(printf '%s' "${_vrt_c}" | tr '-' '_')"
        "${_vrt_fn}" || fail=1
    done

    if [ "${fail}" -ne 0 ]; then
        # May run on the recovery path with PMM already at 0: report the real replica count.
        _vrt_live=$(kubectl get statefulset "${SCOPE_PMM_STS:-}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
        log "ERROR" "Pre-restore validation FAILED. This run changed nothing."
        case "${_vrt_live}" in
            ''|*[!0-9]*) ;;
            0) log "ERROR" "  PMM is at 0 replicas — an earlier run scaled it down and did not finish."
               log "ERROR" "  See \"Recovering from a restore that was killed part-way\" in docs/pmm-backup.md." ;;
            *) log "ERROR" "  PMM is still running (${_vrt_live} replica(s))." ;;
        esac
        return 1
    fi
    log "INFO" "Pre-restore validation passed — every selected component's source and target are present"
    return 0
}

# EXIT/INT/TERM handler: tear down the temp S3 client pod, then release owned locks.
restore_cleanup() {
    local _rc_sweep_ok=true
    # Delete only temp pods this run recorded (a leaked pod wedges the RWO PVC);
    # by label would hit a concurrent run's pods.
    local _tp
    if [ -n "${TEMP_PODS_MARKER}" ] && [ -e "${TEMP_PODS_MARKER}" ]; then
        _rc_sweep_ok=true
        while IFS= read -r _tp; do
            [ -n "${_tp}" ] || continue
            kubectl delete pod -n "${NAMESPACE}" "${_tp}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || _rc_sweep_ok=false
        done < "${TEMP_PODS_MARKER}"
        # Keep the marker on failure so the EXIT-trap pass retries.
        if [ "${_rc_sweep_ok}" = "true" ]; then
            [ -n "${TEMP_PODS_MARKER}" ] && rm -f "${TEMP_PODS_MARKER}" 2>/dev/null || true
        else
            log "WARN" "Temp-pod cleanup did not complete; keeping the marker so the next cleanup pass retries it"
        fi
    fi
    # Reap the manifest copy on every exit path.
    [ -n "${MANIFEST_FILE}" ] && rm -f "${MANIFEST_FILE}" 2>/dev/null || true
    # Remove a staged PG dump and decoded key left behind by a signal.
    if [ -n "${PG_STAGE_MARKER}" ] && [ -s "${PG_STAGE_MARKER}" ]; then
        _sp="" _sf=""
        while read -r _sp _sf; do
            timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${_sp}" -c database -- rm -f "${_sf}" >/dev/null 2>&1 || true
        done < "${PG_STAGE_MARKER}"
    fi
    [ -n "${PG_STAGE_MARKER}" ] && rm -f "${PG_STAGE_MARKER}" 2>/dev/null || true
    [ -n "${ENC_KEY_FILE}" ] && rm -f "${ENC_KEY_FILE}" 2>/dev/null || true
    release_locks
    return 0
}

################################################################################
# PMM scale down / up (restore happens with PMM down so nothing writes the DBs)
################################################################################
# Live spec, else the stashed annotation, else PMM_SERVER_REPLICAS; always a number.
pmm_replica_count() {   # <statefulset-name>
    _prc_n=$(kubectl get statefulset "$1" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    case "${_prc_n}" in ''|0|*[!0-9]*) _prc_n="" ;; esac
    if [ -z "${_prc_n}" ]; then
        # Escaped-dot jsonpath: the ['key'] form returns empty for keys containing '/'.
        _prc_n=$(kubectl get statefulset "$1" -n "${NAMESPACE}" \
            -o jsonpath='{.metadata.annotations.restore\.pmm\.percona\.com/original-replicas}' 2>/dev/null || echo "")
        case "${_prc_n}" in
            ''|0) _prc_n="" ;;
            *[!0-9]*)
                log "WARN" "PMM ${1}: the stashed original-replicas annotation ('${_prc_n}') is not a number; ignoring it" >&9
                _prc_n="" ;;
        esac
    fi
    if [ -z "${_prc_n}" ]; then
        # Warn here: callers cannot infer the fallback.
        _prc_n="${PMM_SERVER_REPLICAS:-3}"
        case "${_prc_n}" in ''|*[!0-9]*) _prc_n=3 ;; esac   # PMM_SERVER_REPLICAS is env-supplied
        log "WARN" "PMM ${1}: neither spec.replicas nor a stashed count is usable; will restore to ${_prc_n} (override with PMM_SERVER_REPLICAS)" >&9
    fi
    printf '%s' "${_prc_n}"
}

scale_down_pmm() {
    local _sdp_rc=0
    PMM_STATEFULSET_NAME="${SCOPE_PMM_STS}"
    if [ -z "${PMM_STATEFULSET_NAME}" ]; then
        PMM_STATEFULSET_NAME=$(resolve_one PMM "PMM Server StatefulSet" statefulset "${LABEL_PMM_SERVER}") || _sdp_rc=$?
    fi
    # Ambiguous (rc 2) is fatal; none is fine (data-tier-only restore).
    if [ "${_sdp_rc}" -eq 2 ]; then
        log "ERROR" "Refusing to restore: cannot tell which PMM StatefulSet to scale down (see above)."
        log "ERROR" "Re-run with --release <name>."
        return 1
    fi
    if [ -z "${PMM_STATEFULSET_NAME}" ]; then log "WARN" "PMM StatefulSet not found, skipping scale down"; return 0; fi
    PMM_SAVED_REPLICAS=$(pmm_replica_count "${PMM_STATEFULSET_NAME}")
    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[DRY RUN] kubectl scale statefulset ${PMM_STATEFULSET_NAME} --replicas=0 (restore to: ${PMM_SAVED_REPLICAS})"
        return 0
    fi
    # Stash the count so an interrupted/re-run restore can recover the true original.
    kubectl annotate statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" "restore.pmm.percona.com/original-replicas=${PMM_SAVED_REPLICAS}" --overwrite >> "${LOG_FILE}" 2>&1 || true
    kubectl scale statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" --replicas=0 >> "${LOG_FILE}" 2>&1 || { log "ERROR" "Failed to scale down PMM"; return 1; }
    log "INFO" "Scaled down PMM ${PMM_STATEFULSET_NAME} to 0 (restore to ${PMM_SAVED_REPLICAS} on success)"
    wait_for_pods_gone "${NAMESPACE}" "$(comp_pod_selector pmm-server)" || { log "ERROR" "PMM pods did not terminate"; return 1; }
    return 0
}

scale_up_pmm() {
    if [ -z "${PMM_STATEFULSET_NAME}" ] || [ -z "${PMM_SAVED_REPLICAS}" ]; then return 0; fi
    if [ "${DRY_RUN}" = "true" ]; then log "INFO" "[DRY RUN] kubectl scale statefulset ${PMM_STATEFULSET_NAME} --replicas=${PMM_SAVED_REPLICAS}"; return 0; fi
    kubectl scale statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" --replicas="${PMM_SAVED_REPLICAS}" >> "${LOG_FILE}" 2>&1 || { log "ERROR" "Failed to scale up PMM"; return 1; }
    log "INFO" "Scaled up PMM ${PMM_STATEFULSET_NAME} to ${PMM_SAVED_REPLICAS}; waiting for ready..."
    wait_for_pods_ready "${NAMESPACE}" "$(comp_pod_selector pmm-server)" "${PMM_SAVED_REPLICAS}" || log "WARN" "PMM pods not ready in time (may still be starting)"
    return 0
}

################################################################################
# Encryption key (verified FIRST, applied after scale-down; restore aborts if either fails)
################################################################################
# prepare verifies before scale-down; apply runs after and keeps the replaced key.
ENC_KEY_FILE=""
prepare_encryption_key() {
    local tmp
    tmp=$(mktemp /tmp/enc.XXXXXX 2>/dev/null || echo "/tmp/enc.$$")
    store_read "$(comp_path encryption)/pg-encryption-key.yaml" > "${tmp}" 2>/dev/null || true
    if [ ! -s "${tmp}" ]; then log "ERROR" "[EncryptionKey] not found for ${BACKUP_NAME}"; rm -f "${tmp}"; return 1; fi
    # Check the recorded sha256 before the namespace rewrite; older backups have none.
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
    # Security gate: store content becomes a manifest, so only a single v1 Secret is applied.
    # -s is load-bearing: unslurped jq -e checks only the LAST value of a stream.
    if ! jq -e -s 'length == 1 and (.[0] | type == "object" and .kind == "Secret"
                   and .apiVersion == "v1" and .metadata.name == "pg-encryption-key")' \
                 "${tmp}" >/dev/null 2>&1; then
        log "ERROR" "[EncryptionKey] The stored key object is not a single v1 Secret named 'pg-encryption-key'."
        log "ERROR" "[EncryptionKey]   Refusing to apply it: this path creates whatever object the file describes,"
        log "ERROR" "[EncryptionKey]   so anything else here would be an object someone put in the backup store."
        rm -f "${tmp}"; return 1
    fi
    # Retarget the namespace with jq on .[0] only; sed would also retarget injected objects.
    if ! jq -s --arg ns "${NAMESPACE}" '.[0] | .metadata.namespace = $ns' "${tmp}" > "${tmp}.ns" 2>/dev/null; then
        log "ERROR" "[EncryptionKey] Could not set the target namespace on the key Secret"
        rm -f "${tmp}" "${tmp}.ns"; return 1
    fi
    mv "${tmp}.ns" "${tmp}"
    ENC_KEY_FILE="${tmp}"
    log "INFO" "[EncryptionKey] Verified; it is applied after PMM is scaled down"
    return 0
}

apply_encryption_key() {
    local tmp="${ENC_KEY_FILE}" cur="" snap=""
    if [ "${DRY_RUN}" = "true" ]; then log "INFO" "[EncryptionKey] [DRY RUN] kubectl apply -n ${NAMESPACE} -f <key from ${BACKUP_NAME}/encryption>"; rm -f "${tmp}"; return 0; fi
    # Only NotFound means "no key to keep"; a failed lookup must not skip the snapshot below.
    local _ks=0; k8s_object_state secret pg-encryption-key || _ks=$?
    if [ "${_ks}" -eq 0 ]; then cur=$(kubectl get secret pg-encryption-key -n "${NAMESPACE}" -o json 2>>"${LOG_FILE}") || cur=""; fi
    if [ "${_ks}" -eq 2 ] || { [ "${_ks}" -eq 0 ] && [ -z "${cur}" ]; }; then
        log "ERROR" "[EncryptionKey] Could not read the current pg-encryption-key; not replacing it"; rm -f "${tmp}"; return 1
    fi
    if [ -n "${cur}" ] && [ "$(printf '%s' "${cur}" | jq -cS '.data' 2>/dev/null)" = "$(jq -cS '.data' "${tmp}" 2>/dev/null)" ]; then
        log "INFO" "[EncryptionKey] Unchanged (the target already holds this key)"; rm -f "${tmp}"; return 0
    fi
    # Keep the replaced key so PMM can still decrypt if the restore does not finish.
    if [ -n "${cur}" ]; then
        snap="pg-encryption-key-pre-restore-$(date -u +%Y%m%d-%H%M%S)"
        if ! printf '%s' "${cur}" | jq --arg n "${snap}" '{apiVersion, kind, type, data, metadata: {name: $n}}' \
                | kubectl create -n "${NAMESPACE}" -f - >> "${LOG_FILE}" 2>&1; then
            log "ERROR" "[EncryptionKey] Could not save the current key as Secret ${snap}; not replacing it"
            rm -f "${tmp}"; return 1
        fi
        log "INFO" "[EncryptionKey] Saved the replaced key as Secret ${snap}"
    fi
    if kubectl apply -f "${tmp}" -n "${NAMESPACE}" >> "${LOG_FILE}" 2>&1; then
        log "INFO" "[EncryptionKey] Restored"; rm -f "${tmp}"; return 0
    fi
    log "ERROR" "[EncryptionKey] kubectl apply failed"; rm -f "${tmp}"; return 1
}

################################################################################
# PostgreSQL — logical restore: recreate each DB empty, then pg_restore its dump (PMM is down).
################################################################################
# Drop/recreate <db> from template0 keeping owner and grants (--clean leaves newer tables).
# template0: the operator seeds template1 with a pgbouncer schema the dump also creates.
pg_recreate_db() {   # <pod> <db>
    if ! timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "$1" -c database -- \
            psql -U postgres -v ON_ERROR_STOP=1 -v db="$2" -f - >>"${LOG_FILE}" 2>&1 <<'SQL'
SELECT pg_get_userbyid(datdba) AS owner, datacl IS NULL AS default_acl,
       coalesce((SELECT string_agg(format('GRANT %s ON DATABASE %I TO %s', a.privilege_type, datname,
                 CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END), '; ')
                 FROM aclexplode(datacl) a), 'SELECT 1') AS grants
  FROM pg_database WHERE datname = :'db' \gset
DROP DATABASE :"db" WITH (FORCE);
CREATE DATABASE :"db" OWNER :"owner" TEMPLATE template0;
\if :default_acl
\else
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
:grants;
\endif
SQL
    then
        log "ERROR" "[PostgreSQL] ${2}: could not drop and recreate the database"; return 1
    fi
}

# End other sessions on <db...> (an orphaned remote pg_dump blocks DROP); prints the count.
pg_end_sessions() {   # <pod> <db...>
    _pes_pod="$1"; shift
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${_pes_pod}" -c database -- \
        psql -U postgres -tA -v ON_ERROR_STOP=1 -v dbs="$*" -f - 2>>"${LOG_FILE}" <<'SQL'
SELECT count(*) FILTER (WHERE pg_terminate_backend(pid, 5000)) FROM pg_stat_activity
 WHERE datname = ANY (string_to_array(:'dbs', ' ')) AND pid <> pg_backend_pid();
SQL
}

# Stage dumps in chunks with short execs; one long exec -i stream breaks on large dumps.
PG_STAGE_DIR="${PG_STAGE_DIR:-/pgdata}"
PG_STAGE_CHUNK="${PG_STAGE_CHUNK:-67108864}"
numeric_env PG_STAGE_CHUNK 67108864
pg_free_bytes() {   # <pod>
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "$1" -c database -- \
        df -Pk "${PG_STAGE_DIR}" 2>>"${LOG_FILE}" | awk 'NR == 2 { printf "%.0f", $4 * 1024 }'
}
pg_stage_dump() {   # <pod> <uri> <stage-file> <expected-bytes>
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "$1" -c database -- \
        sh -c ': > "$1"' sh "$3" 2>>"${LOG_FILE}" || { log "ERROR" "[PostgreSQL] cannot create $1:$3"; return 1; }
    _psd_off=0
    while [ "${_psd_off}" -lt "$4" ]; do
        _psd_end=$((_psd_off + PG_STAGE_CHUNK))
        [ "${_psd_end}" -le "$4" ] || _psd_end="$4"
        _psd_try=1
        # Each chunk lands at its own offset and is checked by the file size, so a retry rewrites it.
        until store_read_range "$2" "${_psd_off}" "${PG_STAGE_CHUNK}" 2>>"${LOG_FILE}" \
                | kubectl exec -i -n "${NAMESPACE}" "$1" -c database -- sh -c \
                  'dd of="$1" bs=1M seek="$2" oflag=seek_bytes conv=notrunc status=none && [ "$(stat -c %s "$1")" -ge "$3" ]' \
                  sh "$3" "${_psd_off}" "${_psd_end}" 2>>"${LOG_FILE}"; do
            if [ "${_psd_try}" -ge 3 ]; then
                log "ERROR" "[PostgreSQL] staging $2 failed at byte ${_psd_off} after 3 attempts"; return 1
            fi
            _psd_try=$((_psd_try + 1)); log "WARN" "[PostgreSQL] staging chunk at byte ${_psd_off} failed; attempt ${_psd_try}/3"
        done
        _psd_off="${_psd_end}"
    done
    _psd_got=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "$1" -c database -- \
        stat -c %s "$3" 2>>"${LOG_FILE}") || _psd_got=""
    [ "${_psd_got}" = "$4" ] && return 0
    log "ERROR" "[PostgreSQL] staged ${_psd_got:-0} of $4 bytes of $2"; return 1
}

restore_postgresql() {
    local pg_pod dbs db rc fail=0
    pg_pod=$(one_pod PostgreSQL "primary pod" "$(comp_pod_selector postgresql)" || true)
    if [ -z "${pg_pod}" ]; then log "ERROR" "[PostgreSQL] Primary pod not resolved; refusing to restore"; return 1; fi
    dbs="${MF_PG_DBS}"
    if [ -z "${dbs}" ]; then log "ERROR" "[PostgreSQL] No databases recorded in the manifest"; return 1; fi
    if [ "${DRY_RUN}" != "true" ]; then
        local ended=""
        # shellcheck disable=SC2086
        if ended=$(pg_end_sessions "${pg_pod}" ${dbs}); then
            [ "${ended:-0}" = "0" ] || log "WARN" "[PostgreSQL] Ended ${ended} leftover session(s) on: ${dbs}"
        else
            log "ERROR" "[PostgreSQL] Could not end the sessions on ${dbs} (see the log); refusing to restore"; return 1
        fi
    fi

    for db in ${dbs}; do
        if [ "${DRY_RUN}" = "true" ]; then
            log "INFO" "[PostgreSQL] [DRY RUN] stage $(comp_display postgresql)/${db}.dump in ${pg_pod}:${PG_STAGE_DIR}, DROP + CREATE DATABASE ${db}, pg_restore -d ${db} <staged file>"
            continue
        fi
        rc=0
        log "INFO" "[PostgreSQL] Restoring database ${db} into ${pg_pod}..."
        local pr_out; pr_out=$(mktemp /tmp/pgrestore.XXXXXX 2>/dev/null || echo "/tmp/pgrestore.$$")
        local uri="$(comp_path postgresql)/${db}.dump"
        # Check the dump first: the pipeline status is pg_restore's.
        local dump_size
        dump_size=$(store_bytes "${uri}" 2>/dev/null || echo 0)
        if ! [ "${dump_size:-0}" -gt 0 ] 2>/dev/null; then
            log "ERROR" "[PostgreSQL] dump missing or empty: ${uri}"; fail=1; rm -f "${pr_out}"; continue
        fi
        # Everything that can fail without touching the database runs before the DROP.
        local free stage="${PG_STAGE_DIR}/pmm-restore-${db}.dump"
        [ -n "${PG_STAGE_MARKER}" ] && { printf '%s %s\n' "${pg_pod}" "${stage}" >> "${PG_STAGE_MARKER}"; } 2>/dev/null || true
        free=$(pg_free_bytes "${pg_pod}" || true)
        if [ -n "${free}" ] && [ "${free}" -lt "${dump_size}" ] 2>/dev/null; then
            log "ERROR" "[PostgreSQL] ${db}: ${PG_STAGE_DIR} in ${pg_pod} has $(human_bytes "${free}") free, the dump needs $(human_bytes "${dump_size}")"
            fail=1; rm -f "${pr_out}"; continue
        fi
        if ! pg_stage_dump "${pg_pod}" "${uri}" "${stage}" "${dump_size}" \
                || ! pg_recreate_db "${pg_pod}" "${db}"; then
            timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- rm -f "${stage}" >/dev/null 2>&1 || true
            fail=1; rm -f "${pr_out}"; continue
        fi
        kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
            sh -c 'env PGAPPNAME="$1" pg_restore -U postgres -d "$2" "$3"; echo "PG_RESTORE_RC=$?"' \
            sh "${PG_APPNAME}" "${db}" "${stage}" >"${pr_out}" 2>&1 || rc=$?
        cat "${pr_out}" >> "${LOG_FILE}" 2>/dev/null || true
        timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- rm -f "${stage}" >/dev/null 2>&1 \
            || log "WARN" "[PostgreSQL] could not remove ${pg_pod}:${stage}"
        # pg_restore's own rc; without the marker kubectl failed and the database is in an unknown state.
        _pgr_rc=$(marker_rc PG_RESTORE_RC < "${pr_out}")
        if [ -z "${_pgr_rc}" ]; then
            log "ERROR" "[PostgreSQL] ${db}: no PG_RESTORE_RC from the pod (kubectl exit ${rc}); pg_restore may not have run or finished"
            fail=1; rm -f "${pr_out}"; continue
        fi
        rc="${_pgr_rc}"
        # Non-zero with 'error:' lines is a real failure; rc 1 alone is warnings.
        if [ "${rc}" -eq 0 ]; then
            log "INFO" "[PostgreSQL] ✓ ${db} restored"
        elif grep -q 'error:' "${pr_out}" 2>/dev/null; then
            log "ERROR" "[PostgreSQL] ${db}: pg_restore FAILED (exit ${rc}); last errors:"
            grep 'error:' "${pr_out}" 2>/dev/null | tail -n 5 | append_to_log || true
            fail=1
        elif [ "${rc}" -eq 1 ]; then
            log "WARN" "[PostgreSQL] ${db}: pg_restore exited ${rc} with warnings only (check the log)"
        else
            # pg_restore killed (137) or crashed: the DB may be half-restored.
            log "ERROR" "[PostgreSQL] ${db}: pg_restore did not complete (exit ${rc})"
            fail=1
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
    ch_pod=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector clickhouse)" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${ch_pod}" ]; then log "ERROR" "[ClickHouse] No pod found"; return 1; fi
    name="${MF_CH_NAME}"
    if [ -z "${name}" ]; then log "ERROR" "[ClickHouse] No backup name in manifest"; return 1; fi

    local rc=0
    if [ "${S3_ENABLED}" = "true" ]; then
        # restore_remote reads S3_BUCKET/S3_PATH from env; --env redirects to the backup's prefix.
        log "INFO" "[ClickHouse] restore_remote --rm ${name} (from s3://$(ch_restore_bucket)/$(ch_restore_path), in ${ch_pod})..."
        pod_exec ClickHouse "${ch_pod}" clickhouse-backup 0 \
            clickhouse-backup restore_remote \
            --env "S3_BUCKET=$(ch_restore_bucket)" --env "S3_PATH=$(ch_restore_path)" \
            --rm "${name}" >>"${LOG_FILE}" 2>&1 || rc=$?
    else
        local tarball="$(comp_inpod clickhouse)/${name}.tar.gz"
        log "INFO" "[ClickHouse] untar ${tarball} + restore --rm ${name} (in ${ch_pod})..."
        # Positional args, not interpolated: both are manifest-derived.
        pod_sh ClickHouse "${ch_pod}" clickhouse-backup 0 \
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
# Static-cred env for temp pods when a secret is set; empty for IRSA.
# A function: indentation is manifest content (DN-22).
render_temp_pod_s3_keys_env() {
    [ -n "${S3_SECRET_NAME}" ] || return 0
    printf '%s' "
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: ${S3_SECRET_NAME}, key: ${S3_SECRET_ACCESS_KEY_KEY} } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: ${S3_SECRET_NAME}, key: ${S3_SECRET_SECRET_KEY_KEY} } }"
}

# The default SA exists only for IRSA; static keys skip it unless explicit.
render_temp_pod_sa_line() {
    [ -n "${S3_SERVICE_ACCOUNT}" ] || return 0
    if [ -z "${S3_SECRET_NAME}" ] || [ "${S3_SA_EXPLICIT}" = "true" ]; then
        printf '%s' "  serviceAccountName: ${S3_SERVICE_ACCOUNT}"
    fi
}

# runAsUser|runAsGroup|fsGroup|cRunAsUser|cRunAsGroup of a live workload (DN-39).
# '|' not space: read collapses whitespace and would shift empty fields.
read_security_context_fields() {   # <pod|statefulset> <name> [container-name]
    case "$1" in
        pod)         _rscf_p='{.spec' ;;
        statefulset) _rscf_p='{.spec.template.spec' ;;
        *) return 1 ;;
    esac
    # By name when given: vmstorage container order is an operator detail.
    if [ -n "${3:-}" ]; then _rscf_c="containers[?(@.name==\"$3\")]"; else _rscf_c="containers[0]"; fi
    # Container-level user/group override the pod's (DN-48); fsGroup is pod-only.
    _rscf_j="${_rscf_p}.securityContext.runAsUser}|${_rscf_p}.securityContext.runAsGroup}|${_rscf_p}.securityContext.fsGroup}"
    _rscf_j="${_rscf_j}|${_rscf_p}.${_rscf_c}.securityContext.runAsUser}|${_rscf_p}.${_rscf_c}.securityContext.runAsGroup}"
    kubectl get "$1" "$2" -n "${NAMESPACE}" -o jsonpath="${_rscf_j}" 2>/dev/null || true
}

# Digits only; anything else is dropped (DN-15).
_render_sec_ctx_field() {   # <key> <value>
    case "$2" in ''|*[!0-9]*) return 0 ;; esac
    printf '\n    %s: %s' "$1" "$2"
}

# securityContext block, or empty (valid, DN-48); the columns are data (DN-22).
render_temp_pod_security_context() {   # <runAsUser> <runAsGroup> <fsGroup>
    _rtpsc_out="$(_render_sec_ctx_field runAsUser "$1")$(_render_sec_ctx_field runAsGroup "$2")$(_render_sec_ctx_field fsGroup "$3")"
    [ -n "${_rtpsc_out}" ] || return 0
    # OnRootMismatch: the default Always walks every file and can outlast the 300s readiness wait.
    case "${_rtpsc_out}" in
        *"fsGroup:"*) _rtpsc_out="${_rtpsc_out}$(printf '\n    fsGroupChangePolicy: OnRootMismatch')" ;;
    esac
    printf '  securityContext:%s' "${_rtpsc_out}"
}

# Container hardening; a non-root identity also gets the rest of PSS "restricted".
render_temp_container_security_context() {   # <rendered-pod-sec-ctx>
    printf '      securityContext:\n        allowPrivilegeEscalation: false\n        seccompProfile:\n          type: RuntimeDefault'
    case "$1" in
        *"runAsUser: "[1-9]*) printf '\n        runAsNonRoot: true\n        capabilities:\n          drop: ["ALL"]' ;;
    esac
}

# Rendered block on one line, for logs only.
sec_ctx_oneline() {   # <rendered-block>
    printf '%s' "$1" | tr '\n' ' ' | sed 's/ *securityContext://' | tr -s ' '
}

# Read a workload's identity and render it (DN-46). here-doc, not pipe: read in a pipe runs in a subshell.
security_context_of() {   # <pod|statefulset> <name> [container-name]
    _sco_u="" ; _sco_g="" ; _sco_f="" ; _sco_cu="" ; _sco_cg=""
    IFS='|' read -r _sco_u _sco_g _sco_f _sco_cu _sco_cg <<EOF
$(read_security_context_fields "$1" "$2" "${3:-}")
EOF
    # Container over pod, as Kubernetes does. `if`, not `[ ] &&`: set -e.
    if [ -n "${_sco_cu}" ]; then _sco_u="${_sco_cu}"; fi
    if [ -n "${_sco_cg}" ]; then _sco_g="${_sco_cg}"; fi
    render_temp_pod_security_context "${_sco_u}" "${_sco_g}" "${_sco_f}"
}

# Temp pod scheduling copied from the live workload (DN-39): nodeSelector, tolerations,
# priorityClassName, imagePullSecrets as compact JSON. Not affinity: it targets pods scaled to 0.
scheduling_of() {   # <pod|statefulset> <name>
    case "$1" in
        pod)         _schof_sel='.spec' ;;
        statefulset) _schof_sel='.spec.template.spec' ;;
        *) return 1 ;;
    esac
    command -v jq >/dev/null 2>&1 || return 0
    _schof_spec=$(kubectl get "$1" "$2" -n "${NAMESPACE}" -o json 2>/dev/null | jq -c "${_schof_sel}" 2>/dev/null) || return 0
    [ -n "${_schof_spec}" ] && [ "${_schof_spec}" != "null" ] || return 0
    _schof_out=""
    for _schof_f in nodeSelector tolerations priorityClassName imagePullSecrets; do
        _schof_v=$(printf '%s' "${_schof_spec}" | jq -c --arg f "${_schof_f}" '.[$f] // empty' 2>/dev/null) || continue
        [ -n "${_schof_v}" ] || continue
        case "${_schof_v}" in ''|'null'|'{}'|'[]') continue ;; esac
        _schof_out="${_schof_out}$(printf '\n  %s: %s' "${_schof_f}" "${_schof_v}")"
    done
    [ -n "${_schof_out}" ] || return 0
    printf '%s' "${_schof_out#?}"
}

# One-line summary of scheduling_of, for the log.
sched_oneline() {   # <rendered-block>
    [ -n "$1" ] || { printf ' none (workload declares no nodeSelector/tolerations/pullSecrets)'; return 0; }
    printf '%s' "$1" | sed 's/^  //' | tr '\n' ' ' | sed 's/  */ /g; s/^/ /'
}

# The single temp restore pod spec, shared by the pre-flight probe and the real create.
# <role> vm|pmm; empty [sec-ctx] means none (DN-48).
render_temp_restore_pod() {   # <pod-name> <pvc> <image> <role> [sec-ctx] [sched]
    local restore_pod="$1" pvc="$2" image="$3" role="$4" sec_ctx="${5:-}" sched="${6:-}"
    local sa_line="" central_mount="" central_vol="" env_block=""
    local label="" ctr="" mount_path="" vol_name="" res_block="" ctr_sec="" mounts="" vols=""
    local pull="IfNotPresent" cmd='["sleep", "infinity"]'
    if [ "${role}" = "probe" ]; then
        # Image check only: Always makes the registry and pull secret answer even on a warm node.
        label="vm-image-probe"; ctr="vmrestore"; pull="Always"; cmd='["/vmrestore-prod", "-version"]'
    elif [ "${role}" = "vm" ]; then
        label="vm-restore-temp"; ctr="vmrestore"; vol_name="vmstorage-db"; mount_path="/vmstorage-data"
        # vmrestore takes the endpoint as a flag; region/keys are the VM-effective ones.
        [ "${S3_ENABLED}" = "true" ] && env_block="      env:
        - name: AWS_REGION
          value: \"$(vm_s3_region)\"${TEMP_POD_VM_S3_KEYS_ENV}"
    else
        label="pmm-srv-restore-temp"; ctr="srv-restore"; vol_name="pmm-storage"; mount_path="/srv"
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
    if [ "${role}" != "probe" ]; then
        mounts="      volumeMounts:
        - name: ${vol_name}
          mountPath: ${mount_path}
${central_mount}"
        vols="  volumes:
    - name: ${vol_name}
      persistentVolumeClaim:
        claimName: ${pvc}
${central_vol}"
    fi
    # Explicit resources: a ResourceQuota without LimitRange rejects pods lacking them.
    res_block="      resources: ${TEMP_POD_RESOURCES}"
    ctr_sec=$(render_temp_container_security_context "${sec_ctx}")
    cat <<EOF
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
${sched}
  containers:
    - name: ${ctr}
      image: ${image}
      imagePullPolicy: ${pull}
      command: ${cmd}
${ctr_sec}
${res_block}
${env_block}
${mounts}
${vols}
EOF
}

# One creator for both temp restore pods (DN-46).
create_temp_restore_pod() {
    local restore_pod="$1" pvc="$2" image="$3" role="$4" tag="$5" sec_ctx="${6:-}" sched="${7:-}"
    local apply_out

    clear_leftover_temp_pod "${restore_pod}" "${tag}"
    apply_out=$(mktemp /tmp/podapply.XXXXXX 2>/dev/null || echo "/tmp/podapply.$$")
    # Append the pod NAME before create: cleanup deletes by name, not label (concurrent runs).
    [ -n "${TEMP_PODS_MARKER}" ] && printf '%s\n' "${restore_pod}" >> "${TEMP_PODS_MARKER}" 2>/dev/null || true
    if ! render_temp_restore_pod "${restore_pod}" "${pvc}" "${image}" "${role}" "${sec_ctx}" "${sched}" \
            | kubectl create -f - -n "${NAMESPACE}" >"${apply_out}" 2>&1
    then
        cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
        log "ERROR" "[${tag}] Failed to create restore pod ${restore_pod} (PVC: ${pvc})"; return 1
    fi
    cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
    wait_for_pod_ready_by_name "${NAMESPACE}" "${restore_pod}" 300 \
        || { log "ERROR" "[${tag}] Restore pod ${restore_pod} not ready"; return 1; }
    return 0
}

create_vm_restore_pod()  { create_temp_restore_pod "$1" "$2" "$3" vm  VictoriaMetrics "${4:-}" "${5:-}"; }

# Delete-and-recreate a leftover same-name pod; apply cannot patch an immutable Pod.
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

# Deletes any temp restore pod, VM or /srv.
delete_temp_restore_pod() {
    kubectl delete pod "$1" -n "${NAMESPACE}" --grace-period=10 --wait=false 2>&1 | append_to_log || true
    wait_for_pod_gone_by_name "${NAMESPACE}" "$1" 120 || true
}

# Backup subdir for a target ordinal (DN-18), charset-gated (DN-17). Always rc 0 (set -e callers).
src_subdir_for_ord() {   # <component> <ordinal>
    _ssfo_out=$(store_list_dirs "$(comp_path "$1")" 2>/dev/null) || _ssfo_out=""
    _ssfo_hit=""
    # here-doc, not pipe (subshell); line-by-line, not for-in (word-splitting).
    while IFS= read -r _ssfo_c; do
        [ -n "${_ssfo_c}" ] || continue
        case "${_ssfo_c}" in
            *[!A-Za-z0-9_.-]*)
                log "WARN" "[$1] Ignoring backup subdirectory '${_ssfo_c}': it contains characters outside A-Z a-z 0-9 _ . - and would be interpolated into a command run inside a pod"
                continue ;;
        esac
    # Literal suffix match keeps the ordinal out of a regex.
        case "${_ssfo_c}" in *-"$2") ;; *) continue ;; esac
        _ssfo_hit="${_ssfo_c}"; break
    done <<EOF
${_ssfo_out}
EOF
    [ -n "${_ssfo_hit}" ] && printf '%s\n' "${_ssfo_hit}"
    return 0
}

vm_src_subdir_for_ord() { src_subdir_for_ord victoriametrics "$1"; }

# Count vmstorage ordinals in the backup; keeps the listing's status, not grep -c's.
vm_src_ordinal_count() {
    _vsoc_out=$(store_list_dirs "$(comp_path victoriametrics)" 2>/dev/null) || return $?
    printf '%s\n' "${_vsoc_out}" | grep -c '[^[:space:]]' || true
}

vm_src_for_pod() {
    local pod="$1" name="vm_backup_${BACKUP_NAME#backup_}" ord sub
    ord="${pod##*-}"                        # trailing ordinal of the target vmstorage pod
    sub=$(vm_src_subdir_for_ord "${ord}")   # backup dir for that ordinal (source release name)
    # No fallback to a guessed path: caller handles rc=1.
    [ -z "${sub}" ] && return 1
    # vmrestore -src needs a scheme: s3:// or fs:// as the vmstorage pod sees it.
    if [ "${S3_ENABLED}" = "true" ]; then
        echo "$(comp_display victoriametrics)/${sub}/${name}"
    else
        echo "fs://$(comp_inpod victoriametrics)/${sub}/${name}"
    fi
}

# Replica count to scale a VM tier back to; 0 is rejected like spec.replicas (DN-46, DN-50).
vm_original_replicas() {   # <spec-value> <live-pod-count> <floor>
    _vor_n="$1"
    case "${_vor_n}" in ''|0|*[!0-9]*) _vor_n="" ;; esac
    if [ -z "${_vor_n}" ]; then
        _vor_n="$2"
        case "${_vor_n}" in ''|0|*[!0-9]*) _vor_n="" ;; esac
    fi
    [ -n "${_vor_n}" ] || _vor_n="$3"
    printf '%s' "${_vor_n}"
}

# vmstorage <pod> refuses to start on vmrestore's restore-in-progress marker.
vm_pod_has_marker() {   # <pod>
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl logs -n "${NAMESPACE}" "$1" -c vmstorage --tail=50 2>/dev/null \
        | grep -q 'incomplete vmrestore run'
}

# vmstorage Ready within VM_READY_TIMEOUT (wall clock). Stops early on the marker, which never heals,
# or after 5 restarts (minutes of back-off); a single crash may heal on retry.
vm_wait_storage_ready() {   # <expected>
    _vws_end=$(( $(date +%s) + VM_READY_TIMEOUT ))
    while [ "$(date +%s)" -lt "${_vws_end}" ]; do
        _vws_st=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector victoriametrics)" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.containerStatuses[?(@.name=="vmstorage")].ready}{"|"}{.status.containerStatuses[?(@.name=="vmstorage")].restartCount}{"|"}{.status.containerStatuses[?(@.name=="vmstorage")].state.waiting.reason}{"\n"}{end}' 2>/dev/null) || _vws_st=""
        if [ "$(printf '%s\n' "${_vws_st}" | awk -F'|' '$2 == "true"' | wc -l | tr -d ' ')" -ge "$1" ]; then
            log "INFO" "[VictoriaMetrics] $1 vmstorage pod(s) ready"; return 0
        fi
        for _vws_l in $(printf '%s\n' "${_vws_st}" | awk -F'|' '$4 == "CrashLoopBackOff" {print $1 "|" $3}'); do
            _vws_p="${_vws_l%%|*}"; _vws_n="${_vws_l#*|}"
            if vm_pod_has_marker "${_vws_p}"; then
                log "ERROR" "[VictoriaMetrics] ${_vws_p} refuses to start on an incomplete restore; not waiting out VM_READY_TIMEOUT"; return 1
            fi
            if [ "${_vws_n:-0}" -ge 5 ] 2>/dev/null; then
                log "ERROR" "[VictoriaMetrics] ${_vws_p} has restarted ${_vws_n} times; not waiting out VM_READY_TIMEOUT"; return 1
            fi
        done
        sleep 5
    done
    return 1
}

# Explain a vmstorage refusing to start on vmrestore's restore-in-progress marker. Diagnostic only.
vm_report_incomplete_restore() {
    _vri_pod=""
    for _vri_p in $(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector victoriametrics)" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        if vm_pod_has_marker "${_vri_p}"; then _vri_pod="${_vri_p}"; break; fi
    done
    [ -n "${_vri_pod}" ] || return 0
    log "ERROR" "[VictoriaMetrics] ${_vri_pod} is refusing to start: an earlier vmrestore did not finish,"
    log "ERROR" "[VictoriaMetrics] so /vmstorage-data/restore-in-progress is still on its data volume(s)."
    log "ERROR" "[VictoriaMetrics] That directory holds a PARTIAL restore, which vmstorage will not serve."
    log "ERROR" "[VictoriaMetrics] Recover by re-running this restore once the original failure is fixed:"
    log "ERROR" "[VictoriaMetrics]   $(basename "$0") restore --backup-id ${BACKUP_NAME} --yes"
    log "ERROR" "[VictoriaMetrics] A successful vmrestore clears the marker and vmstorage starts normally."
}

restore_victoriametrics() {
    local vmstorage_pods vmcluster_name original_vminsert original_vmstorage first_vm_pod vmrestore_image
    local _vs_old="" vm_sec_ctx="" _vm_insert_live="" _vmi_old="" _vmi_inferred=false
    vmstorage_pods=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector victoriametrics)" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "${vmstorage_pods}" ]; then log "ERROR" "[VictoriaMetrics] No vmstorage pods found"; return 1; fi
    vmcluster_name="${SCOPE_VM_CLUSTER}"
    [ -n "${vmcluster_name}" ] || vmcluster_name=$(resolve_one VictoriaMetrics "VMCluster" vmcluster || true)
    if [ -z "${vmcluster_name}" ]; then log "ERROR" "[VictoriaMetrics] No VMCluster found; cannot scale safely"; return 1; fi

    # Fail fast on a shard-count mismatch, before any scale-down (ordinal-mapped).
    local vm_target_count vm_src_count
    vm_target_count=$(echo "${vmstorage_pods}" | wc -w | tr -d ' ')
    # Empty = listing failed; the per-ordinal loop still hard-fails.
    vm_src_count=$(vm_src_ordinal_count) || vm_src_count=""
    if [ -n "${vm_src_count}" ] && [ "${vm_src_count}" -gt 0 ] 2>/dev/null && [ "${vm_src_count}" != "${vm_target_count}" ]; then
        log "ERROR" "[VictoriaMetrics] Shard-count mismatch: backup has ${vm_src_count} vmstorage ordinal(s), target has ${vm_target_count}. Restore would drop or miss shards. Set the target vmstorage replicaCount to ${vm_src_count} to match the backup, then retry. Aborting before any scale-down."
        return 1
    fi
    original_vminsert=$(kubectl get vmcluster "${vmcluster_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.vminsert.replicaCount}' 2>/dev/null || echo "1")
    original_vmstorage=$(kubectl get vmcluster "${vmcluster_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.vmstorage.replicaCount}' 2>/dev/null || echo "1")
    # Unset or 0 replicaCount: fall back to the live count (vm_original_replicas).
    case "${original_vminsert}" in
        ''|0) _vmi_inferred=true
              log "WARN" "[VictoriaMetrics] vmcluster spec.vminsert.replicaCount is '${original_vminsert:-unset}' — refusing to treat that as the count to restore (it is exactly what an earlier restore whose scale-back failed leaves behind); using the live pod count or 1 instead" ;;
    esac
    case "${original_vmstorage}" in
        ''|0) log "WARN" "[VictoriaMetrics] vmcluster spec.vmstorage.replicaCount is '${original_vmstorage:-unset}' — same refusal as vminsert above; using the live pod count instead" ;;
    esac
    _vm_insert_live=$(kubectl get pods -n "${NAMESPACE}" -l "$(vm_role_selector vminsert)" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    original_vminsert=$(vm_original_replicas "${original_vminsert}" "${_vm_insert_live}" 1)
    original_vmstorage=$(vm_original_replicas "${original_vmstorage}" "${vm_target_count}" 1)
    first_vm_pod=$(echo "${vmstorage_pods}" | awk '{print $1}')
    # Explicit status: a failing $( ) assignment aborts under set -e.
    if ! vmrestore_image=$(get_vmrestore_image) || [ -z "${vmrestore_image}" ]; then
        log "ERROR" "[VictoriaMetrics] No vmrestore image: VMRESTORE_IMAGE is unset."
        log "ERROR" "[VictoriaMetrics]   Set victoriaMetrics.vmstorage.backup.restoreImage, or VMRESTORE_IMAGE=<image>. Aborting before any scale-down."
        return 1
    fi
    [ "${S3_ENABLED}" = "true" ] || resolve_central_backup_pvc VictoriaMetrics || return 1
    # Identity from a live vmstorage POD, not the STS: the pod carries assigned ids (DN-48).
    vm_sec_ctx=$(security_context_of pod "${first_vm_pod}" vmstorage)
    # Same source: the temp pod must schedule where the RWO PVC can bind.
    vm_sched=$(scheduling_of pod "${first_vm_pod}")
    log "INFO" "[VictoriaMetrics] Restore pods inherit scheduling:$(sched_oneline "${vm_sched}")"
    if [ -n "${vm_sec_ctx}" ]; then
        log "INFO" "[VictoriaMetrics] Restore pods take ${first_vm_pod}'s identity:$(sec_ctx_oneline "${vm_sec_ctx}")"
    else
        log "INFO" "[VictoriaMetrics] ${first_vm_pod} runs with no runAsUser/runAsGroup/fsGroup, so the restore pods carry none either"
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[VictoriaMetrics] [DRY RUN] scale vminsert/vmstorage to 0 (vmcluster ${vmcluster_name})"
        local pod
        for pod in ${vmstorage_pods}; do
            log "INFO" "[VictoriaMetrics] [DRY RUN]   ${pod}: temp pod vmrestore -src=$(vm_src_for_pod "${pod}") -> $(vmstorage_pvc_name "${pod}")"
        done
        log "INFO" "[VictoriaMetrics] [DRY RUN] scale vmstorage->${original_vmstorage}, vminsert->${original_vminsert}"
        return 0
    fi

    # vminsert UIDs before the patch, for the replacement check (DN-29).
    _vmi_old=$(kubectl get pods -n "${NAMESPACE}" -l "$(vm_role_selector vminsert)" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null) || _vmi_old=""

    log "INFO" "[VictoriaMetrics] Scaling vminsert+vmstorage to 0 (vmrestore needs exclusive PVC access)..."
    kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge \
        -p '{"spec":{"vminsert":{"replicaCount":0},"vmstorage":{"replicaCount":0}}}' 2>&1 | append_to_log || true
    # Soft wait: vminsert holds no PVCs.
    wait_for_pods_gone "${NAMESPACE}" "$(vm_role_selector vminsert)" 120 soft || log "WARN" "[VictoriaMetrics] vminsert not gone in time, continuing (non-blocking)"
    if ! wait_for_pods_gone "${NAMESPACE}" "$(comp_pod_selector victoriametrics)" 300; then
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
        if ! create_vm_restore_pod "${restore_pod}" "${pvc}" "${vmrestore_image}" "${vm_sec_ctx}" "${vm_sched}"; then
            delete_temp_restore_pod "${restore_pod}"; continue
        fi
        timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -c vmrestore -- rm -f /vmstorage-data/flock.lock 2>/dev/null || true
        exec_out=$(mktemp /tmp/vmrestore.XXXXXX 2>/dev/null || echo "/tmp/vmrestore.$$"); rc=0
        kubectl exec -n "${NAMESPACE}" "${restore_pod}" -c vmrestore -- \
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
    # Scale-back failure is a component failure, checked at the end.
    local vm_scaleback_ok=true
    kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"vmstorage":{"replicaCount":'${original_vmstorage}'}}}' 2>&1 | append_to_log || true
    vm_wait_storage_ready "${original_vmstorage}" || {
        log "ERROR" "[VictoriaMetrics] vmstorage did not return to ${original_vmstorage} ready replica(s) after restore (VM_READY_TIMEOUT=${VM_READY_TIMEOUT}s; raise it for a large tier)"
        vm_scaleback_ok=false
        vm_report_incomplete_restore
    }
    kubectl patch vmcluster "${vmcluster_name}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"vminsert":{"replicaCount":'${original_vminsert}'}}}' 2>&1 | append_to_log || true
    # Verify vminsert was REPLACED (DN-29, DN-50); an inferred count only warns.
    if [ -n "${_vmi_old}" ]; then
        wait_for_pods_replaced "${NAMESPACE}" "$(vm_role_selector vminsert)" "${_vmi_old}" "${original_vminsert}" 300 \
            || { log "ERROR" "[VictoriaMetrics] vminsert did not return to ${original_vminsert} ready replica(s) after restore"; vm_scaleback_ok=false; }
    elif [ "${_vmi_inferred}" != "true" ]; then
        wait_for_pods_ready "${NAMESPACE}" "$(vm_role_selector vminsert)" "${original_vminsert}" 300 \
            || { log "ERROR" "[VictoriaMetrics] vminsert did not reach ${original_vminsert} ready replica(s) after restore"; vm_scaleback_ok=false; }
    else
        wait_for_pods_ready "${NAMESPACE}" "$(vm_role_selector vminsert)" "${original_vminsert}" 300 \
            || log "WARN" "[VictoriaMetrics] vminsert did not reach ${original_vminsert} ready replica(s); it had none before this restore and the count was inferred, so this is reported rather than failed — check that ingestion is running"
    fi

    # Bounce vmselect: it holds connections to old vmstorage IPs (DN-29).
    local original_vmselect
    original_vmselect=$(kubectl get vmcluster "${vmcluster_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.vmselect.replicaCount}' 2>/dev/null || echo "1")
    [ -z "${original_vmselect}" ] && original_vmselect=1
    log "INFO" "[VictoriaMetrics] Bouncing vmselect to reconnect to the restored vmstorage nodes..."
    # UIDs before delete; empty set falls back to a plain readiness wait.
    _vs_old=$(kubectl get pods -n "${NAMESPACE}" -l "$(vm_role_selector vmselect)" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null) || _vs_old=""
    kubectl delete pod -n "${NAMESPACE}" -l "$(vm_role_selector vmselect)" 2>&1 | append_to_log || true
    if [ -n "${_vs_old}" ]; then
        wait_for_pods_replaced "${NAMESPACE}" "$(vm_role_selector vmselect)" "${_vs_old}" "${original_vmselect}" 180 \
            || log "WARN" "[VictoriaMetrics] vmselect not replaced/ready in time after bounce"
    else
        log "WARN" "[VictoriaMetrics] Could not read the pre-bounce vmselect pods; falling back to a plain readiness wait"
        wait_for_pods_ready "${NAMESPACE}" "$(vm_role_selector vmselect)" "${original_vmselect}" 180 \
            || log "WARN" "[VictoriaMetrics] vmselect not ready in time after bounce"
    fi

    if [ ${restored} -eq 0 ]; then log "ERROR" "[VictoriaMetrics] Restore failed: 0/${planned} pods"; return 1; fi
    # Partial is failure (DN-21).
    if [ ${restored} -lt ${planned} ]; then
        log "ERROR" "[VictoriaMetrics] Partial restore: ${restored}/${planned} pods — treating as FAILED"
        return 1
    fi
    if [ "${vm_scaleback_ok}" != "true" ]; then
        log "ERROR" "[VictoriaMetrics] Data restored to ${restored}/${planned} pods, but a tier did not come back (vmstorage -> ${original_vmstorage}, vminsert -> ${original_vminsert} ready replica(s)) — treating as FAILED. The errors above say which; scale it back up manually. Note vminsert at 0 means the data is intact but NOTHING IS BEING INGESTED."
        return 1
    fi
    log "INFO" "[VictoriaMetrics] Restore complete (${restored}/${planned} pods)"
    return 0
}

################################################################################
# PMM /srv: restored per ordinal via a temp pod while PMM is at 0 (DN-18, DN-30).
################################################################################
# Charset-gated by src_subdir_for_ord.
pmm_src_subdir_for_ord() { src_subdir_for_ord pmm-server "$1"; }

# Temp pod on a pmm-storage PVC, with the PMM STS identity, not root (DN-48, DN-19).
create_pmm_restore_pod() { create_temp_restore_pod "$1" "$2" "$3" pmm PMMServer "${4:-}" "${5:-}"; }

restore_pmm_server() {
    # All locals initialised: set -u.
    local sts="" replicas="" image="" sec_ctx="" i ord pvc src_subdir restore_pod rc restored=0 count=0
    local out=""
    sts="${PMM_STATEFULSET_NAME:-}"
    if [ -z "${sts}" ]; then sts="${SCOPE_PMM_STS}"; fi
    if [ -z "${sts}" ]; then sts=$(resolve_one PMM "PMM Server StatefulSet" statefulset "${LABEL_PMM_SERVER}" || true); fi
    if [ -z "${sts}" ]; then log "ERROR" "[PMMServer] PMM StatefulSet not found"; return 1; fi
    # scale_down_pmm's saved value, else the resolver; PMM is at 0 now.
    replicas="${PMM_SAVED_REPLICAS:-}"
    case "${replicas}" in ''|0|*[!0-9]*) replicas=$(pmm_replica_count "${sts}") ;; esac
    [ "${S3_ENABLED}" = "true" ] || resolve_central_backup_pvc PMMServer || return 1

    # Normally no-ops: the pre-flight already resolved these.
    resolve_pmm_storage_pvc_prefix "${sts}" || return 1
    resolve_pmm_restore_image "${sts}" || return 1
    image=$(pmm_restore_image) || { log "ERROR" "[PMMServer] no /srv restore pod image was resolved"; return 1; }
    resolve_pmm_restore_security_context "${sts}"
    sec_ctx=$(pmm_restore_security_context)
    i=0
    while [ "${i}" -lt "${replicas}" ]; do
        ord="${i}"; i=$((i + 1)); count=$((count + 1))
    # No failed-pod accumulator: count vs restored already reports it.
        pvc=$(pmm_storage_pvc_name "${sts}" "${ord}") || { log "ERROR" "[PMMServer] ord ${ord}: could not build the PVC name"; continue; }
        src_subdir=$(pmm_src_subdir_for_ord "${ord}")
        if [ "${DRY_RUN}" = "true" ]; then
            log "INFO" "[PMMServer] [DRY RUN] ord ${ord}: temp pod mounts ${pvc} at /srv; extract pmm-server/${src_subdir:-<dir ending -${ord}>}/srv.tar.gz then drop /srv/ha"
            continue
        fi
        if [ -z "${src_subdir}" ]; then log "WARN" "[PMMServer] No backup /srv dir for ordinal ${ord}; skipping"; continue; fi
        restore_pod="pmm-srv-restore-${sts}-${ord}"
        if ! create_pmm_restore_pod "${restore_pod}" "${pvc}" "${image}" "${sec_ctx}" "${PMM_RESTORE_SCHED}"; then delete_temp_restore_pod "${restore_pod}"; continue; fi
        rc=0
        out=$(mktemp /tmp/srvrestore.XXXXXX 2>/dev/null || echo "/tmp/srvrestore.$$")
        # Source path passed as $1 to sh -c, never interpolated.
        if [ "${S3_ENABLED}" = "true" ]; then
            # Clear /srv first (tar merges onto old files), but only after lsjson proves the
            # object readable from THIS pod (exit 3 = untouched, DN-51). grep exit 1 = empty /srv.
            local uri="$(comp_path pmm-server)/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from S3..."
            pod_sh PMMServer "${restore_pod}" - 0 \
                'set -o pipefail; rclone lsjson --s3-no-check-bucket "$1" >/dev/null || exit 3; cd /srv && { ls -A | { grep -vxF lost+found || [ $? -eq 1 ]; } | xargs -r rm -rf; } && rclone cat --s3-no-check-bucket "$1" | tar -xzf - -C /srv --no-same-owner && rm -rf /srv/ha' \
                "${uri}" >"${out}" 2>&1 || rc=$?
        else
            # Same order: probe, wipe, extract.
            local tb="$(comp_inpod pmm-server)/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from ${tb}..."
            pod_sh PMMServer "${restore_pod}" - 0 \
                '[ -r "$1" ] || exit 3; cd /srv && { ls -A | { grep -vxF lost+found || [ $? -eq 1 ]; } | xargs -r rm -rf; } && tar -xzf "$1" -C /srv --no-same-owner && rm -rf /srv/ha' \
                "${tb}" >"${out}" 2>&1 || rc=$?
        fi
        delete_temp_restore_pod "${restore_pod}"
        # Replay pod output via log so the console sees it (DN-51).
        if [ ${rc} -eq 0 ]; then
            cat "${out}" >>"${LOG_FILE}" 2>/dev/null || true
            rm -f "${out}"
            log "INFO" "[PMMServer] ✓ ord ${ord} /srv restored (HA raft reset)"
            restored=$((restored + 1))
        else
            if [ ${rc} -eq 3 ]; then
                log "ERROR" "[PMMServer] ord ${ord}: the backup could not be READ from the restore pod — /srv was left untouched"
                log "ERROR" "[PMMServer]   The pre-flight reads it from this pod; the restore pod carries its own"
                log "ERROR" "[PMMServer]   credentials and endpoint, so check those before the bucket."
            else
                log "ERROR" "[PMMServer] /srv restore failed for ord ${ord} (exit ${rc})"
            fi
            if [ -s "${out}" ]; then
                log "ERROR" "[PMMServer]   the restore pod said:"
                tail -n 20 "${out}" | while IFS= read -r _prs_l; do
                    if [ -n "${_prs_l}" ]; then log "ERROR" "[PMMServer]   ${_prs_l}"; fi
                done
            fi
            rm -f "${out}"
        fi
    done
    [ "${DRY_RUN}" = "true" ] && return 0

    if [ ${count} -eq 0 ]; then log "WARN" "[PMMServer] No /srv archives found in backup"; return 1; fi
    if [ ${restored} -eq 0 ]; then log "ERROR" "[PMMServer] Restore failed: 0/${count}"; return 1; fi
    # Partial is failure (DN-21).
    if [ ${restored} -lt ${count} ]; then
        log "ERROR" "[PMMServer] Partial restore: ${restored}/${count} — treating as FAILED"
        return 1
    fi
    log "INFO" "[PMMServer] /srv restore complete (${restored}/${count}); PMM will load it on start"
    return 0
}

# Reset pmm-ha-client agent ids after a cross-namespace restore so they re-register. Best-effort.
reset_pmm_client_agents() {
    [ "${DRY_RUN}" = "true" ] && return 0
    _rpca_pods=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl get pods -n "${NAMESPACE}" \
        -l "$(pmm_client_selector)" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    [ -n "${_rpca_pods}" ] || return 0

    _rpca_done=""
    for _rpca_p in ${_rpca_pods}; do
        if timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec "${_rpca_p}" -n "${NAMESPACE}" -c pmm-client -- \
                rm -f /usr/local/percona/pmm/config/pmm-agent.yaml >>"${LOG_FILE}" 2>&1; then
            timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl delete pod "${_rpca_p}" -n "${NAMESPACE}" \
                >>"${LOG_FILE}" 2>&1 || true
            _rpca_done="${_rpca_done} ${_rpca_p}"
        else
            log "WARN" "[PMMClient] could not reset ${_rpca_p}'s agent id; it will keep reporting 'No Agent with ID' until its config/pmm-agent.yaml is removed by hand"
        fi
    done
    if [ -n "${_rpca_done}" ]; then
        log "INFO" "[PMMClient] Agent identity reset so they re-register against the restored registry:${_rpca_done}"
    fi
    return 0
}

# Cross-namespace restore advisory: admin password, client agents, PG token. Silent otherwise.
cross_namespace_advisory() {
    _cna_src=$(backup_id_owner "${BACKUP_NAME}" 2>/dev/null || true)
    [ -n "${_cna_src}" ] || return 0
    [ "${_cna_src}" != "${NAMESPACE}" ] || return 0

    reset_pmm_client_agents

    log "WARN" "This was a cross-namespace restore (${_cna_src} -> ${NAMESPACE}). Three things need attention:"
    log "WARN" "  1) The admin password is now '${_cna_src}''s, not this namespace's. Until pmm-secret matches,"
    log "WARN" "     ${RELEASE_NAME:-<release>}-pmm-token-init cannot authenticate and PostgreSQL monitoring gets no token:"
    log "WARN" "       kubectl -n ${NAMESPACE} patch secret pmm-secret --type=merge \\"
    log "WARN" "         -p \"{\\\"data\\\":{\\\"PMM_ADMIN_PASSWORD\\\":\\\"\$(printf %s '<source-password>' | base64)\\\"}}\""
    log "WARN" "     Provisioning this namespace with the source's pmm-secret BEFORE installing avoids this entirely."
    log "WARN" "  2) The pmm-ha-client agents held ids the restored pmm-managed does not know, so their"
    log "WARN" "     identity was reset above and they will re-register on restart. That needs (1) to be"
    log "WARN" "     done first: until the password matches they cannot register and will crash-loop."
    log "WARN" "     Any client reported as not reset above needs it by hand:"
    log "WARN" "       kubectl -n ${NAMESPACE} exec <pod> -c pmm-client -- rm -f /usr/local/percona/pmm/config/pmm-agent.yaml"
    log "WARN" "       kubectl -n ${NAMESPACE} delete pod <pod>"
    log "WARN" "  3) The PostgreSQL operand's PMM_SERVER_TOKEN was minted against the registry this restore"
    log "WARN" "     just replaced, so it no longer authenticates and its pmm-client sidecars will restart."
    log "WARN" "     It cannot be re-minted from here - pmm-token-init is a completed Job, and a completed"
    log "WARN" "     Job does not re-run. Delete it and let Helm recreate it (a few seconds):"
    log "WARN" "       kubectl -n ${NAMESPACE} delete job -l app.kubernetes.io/component=pmm-token-init"
    log "WARN" "       helm upgrade ${RELEASE_NAME:-<release>} <chart> -n ${NAMESPACE} --reuse-values --wait=false"
    return 0
}

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

# $1 is the subcommand's default when --parallel/--sequential were not given.
parallel_enabled() { [ "${PARALLEL:-$1}" = "true" ]; }

# Background children ignore SIGINT (an async list in a non-interactive sh) and `trap - INT`
# cannot undo it, so the parent's INT/TERM traps stop them, and what they started, with TERM.
stop_tree() {   # <pid>  parent first, so it cannot move on to its next step
    _st_kids=$(pgrep -P "$1" 2>/dev/null || true)
    kill -TERM "$1" 2>/dev/null || true
    for _st_c in ${_st_kids}; do stop_tree "${_st_c}"; done
}
stop_children() {
    for _sc_p in ${RUN_CHILD_PIDS}; do stop_tree "${_sc_p}"; done
    RUN_CHILD_PIDS=""
}

# Restore child: EXIT trap dropped so it cannot release the parent's locks; rc via file.
_restore_child() {   # <component-key> <tmpdir>
    trap - EXIT INT TERM
    if "restore_$(printf '%s' "$1" | tr '-' '_')"; then echo 0 > "$2/$1.rc"; else echo 1 > "$2/$1.rc"; fi
}

# Backup child: serialises its RESULTS_JSON for the parent to merge after wait.
_backup_child() {   # <component-key> <tmpdir>
    trap - EXIT INT TERM
    _bch_c="$1" _bch_d="$2" _bch_rc=0
    RESULTS_JSON='{}'
    "backup_$(printf '%s' "${_bch_c}" | tr '-' '_')" || _bch_rc=$?
    # Results first, status last: the .rc file means results are complete.
    printf '%s' "${RESULTS_JSON}" > "${_bch_d}/${_bch_c}.json"
    echo "${_bch_rc}" > "${_bch_d}/${_bch_c}.rc"
}

restore_verification() {
    log "INFO" "Verifying restore..."
    if [ "${RESTORE_POSTGRESQL}" = "true" ]; then
        local pg; pg=$(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector postgresql)" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "${pg}" ]; then
            timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg}" -c database -- pg_isready -U postgres >> "${LOG_FILE}" 2>&1 \
                && log "INFO" "[PostgreSQL] Primary ready" || log "WARN" "[PostgreSQL] Primary not ready yet"
        fi
    fi
    # grep -c prints 0 itself; '|| true' only pacifies set -e.
    [ "${RESTORE_CLICKHOUSE}" = "true" ] && log "INFO" "[ClickHouse] $(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector clickhouse)" --no-headers 2>/dev/null | grep -c Running || true) pod(s) running"
    [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && log "INFO" "[VictoriaMetrics] $(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector victoriametrics)" --no-headers 2>/dev/null | wc -l | tr -d ' ') vmstorage pod(s)"
    [ "${RESTORE_PMM_SERVER}" = "true" ] && log "INFO" "[PMMServer] $(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector pmm-server)" --no-headers 2>/dev/null | grep -c Running || true) PMM pod(s) running"
    return 0
}

################################################################################
# 9. Retention: id-timestamp age (DN-07), all-or-nothing per id (DN-06), guardrails (DN-08).
################################################################################
# Destruction bounds: 0 is rejected, not 'unlimited' (DN-40); strip leading zeros first.
S3_PRUNE_MAX_PER_RUN=$(echo "${S3_PRUNE_MAX_PER_RUN:-50}" | sed 's/^0*\([0-9]\)/\1/')
numeric_env S3_PRUNE_MAX_PER_RUN 50
# Flag, not rc: cmd_backup must not fail on it; published via write_prune_metrics.
PRUNE_REFUSED=0

# Sweep wall clock, within the CronJob's activeDeadlineSeconds.
S3_PRUNE_MAX_SECONDS=$(echo "${S3_PRUNE_MAX_SECONDS:-900}" | sed 's/^0*\([0-9]\)/\1/')
numeric_env S3_PRUNE_MAX_SECONDS 900

# ---- ClickHouse incremental chains ----
# Names a retained backup still needs, transitively (DN-09). Fails only on an unreadable
# KEPT manifest. <all-ids> <purged-ids>
ch_chain_required_names() {
    _ccrn_expired=" $2 "
    _ccrn_edges=""      # "<name> <base-or-->" per line
    _ccrn_req=""
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
            continue
        fi
        _ccrn_name=$(printf '%s' "${_ccrn_mf}" | jq -r '.components.clickhouse.name // empty' 2>/dev/null || true)
        [ -n "${_ccrn_name}" ] || continue
        _ccrn_base=$(printf '%s' "${_ccrn_mf}" | jq -r '.components.clickhouse.base // empty' 2>/dev/null || true)
        _ccrn_edges="${_ccrn_edges}${_ccrn_name} ${_ccrn_base:--}
"
        [ "${_ccrn_kept}" = "true" ] && _ccrn_req="${_ccrn_req} ${_ccrn_name}"
    done
    [ -n "${_ccrn_edges}" ] || return 0

    # Rounds bounded by edge count so a hand-edited cyclic manifest still terminates.
    _ccrn_rounds=$(printf '%s' "${_ccrn_edges}" | grep -c '[^[:space:]]' || true)
    : "${_ccrn_rounds:=0}"
    _ccrn_i=0
    while [ "${_ccrn_i}" -le "${_ccrn_rounds}" ]; do
        _ccrn_i=$((_ccrn_i + 1))
        _ccrn_added=0
        for _ccrn_n in ${_ccrn_req}; do
            _ccrn_b=$(printf '%s\n' "${_ccrn_edges}" | awk -v n="${_ccrn_n}" '$1==n {print $2; exit}')
            [ -n "${_ccrn_b}" ] || continue
            [ "${_ccrn_b}" = "-" ] && continue      # full backup: chain ends
            # Undeclared base: chain already broken; treat as a chain end, not a permanent pin.
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

# Charset-gates manifest component keys before they become delete paths (DN-17).
# Results in globals; do NOT call in $( ). rc 1 = a key was rejected.
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

# Why an expired id's ClickHouse must survive (chain base, or outside our root: DN-12/DN-43).
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

# Written AFTER the purge; pruned keys stay (status "pruned") so a later sweep can finish (DN-09).
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

# Mark the manifest 'pruning' before any delete: a restore that validated this id then stops at its
# post-lock re-check, even when a delete below fails and the manifest is kept.
prune_mark_pruning() {   # <id> <manifest-json>
    # Computed first: a failed jq piped straight into store_write would blank the manifest.
    _pmpr=$(printf '%s' "$2" | jq -c '.status = "pruning"' 2>/dev/null) || return 1
    [ -n "${_pmpr}" ] || return 1
    catalog_cache_drop "$1"
    printf '%s\n' "${_pmpr}" | store_write "$(manifest_path "$1")"
}

# Counters, not rc: a chain-pinned id both deletes (budget) and is kept.
PRUNE_ONE_ATTEMPTED=0 ; PRUNE_ONE_PURGED=0 ; PRUNE_ONE_SKIPPED=0
prune_purge_one() {   # <id> <ch-required-set>
    _ppo_id="$1" _ppo_req="$2"
    _ppo_mf="" _ppo_schema="" _ppo_comps="" _ppo_chname="" _ppo_why="" _ppo_keep=""
    _ppo_fail=0 _ppo_c=""
    PRUNE_ONE_ATTEMPTED=0; PRUNE_ONE_PURGED=0; PRUNE_ONE_SKIPPED=0

    # Read before anything is attempted: a deferred id must not consume the budget.
    _ppo_mf=$(catalog_manifest "${_ppo_id}" 2>/dev/null || true)

    # Newer schema: defer and keep the manifest (DN-41).
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
        # Never fall back to a guessed component list.
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

    # A pin holds ONLY ClickHouse; the other components are purged (DN-09).
    if [ -n "${_ppo_why}" ]; then
        # Skip components an earlier sweep already pruned: re-purging them every run would spend
        # the per-run cap on ids that stay pinned for good.
        _ppo_keep=$(printf '%s' "${_ppo_mf}" | jq -r '.components | to_entries[]
            | select(.key != "clickhouse" and .value.status != "pruned") | .key' 2>/dev/null || true)
        if [ -z "${_ppo_keep}" ]; then
            log "INFO" "[Retention] Keeping '${_ppo_id}': ${_ppo_why}; nothing besides ClickHouse is left to purge."
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
        if ! prune_mark_pruning "${_ppo_id}" "${_ppo_mf}"; then
            log "WARN" "[Retention] Deferring '${_ppo_id}': could not mark its manifest 'pruning' before deleting"
            PRUNE_ONE_SKIPPED=1; return 0
        fi
        # This branch deletes, so it counts against the budget.
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
        for _ppo_c in ${_ppo_comps}; do
            log "INFO" "[Retention] [DRY RUN] would purge $(comp_display "${_ppo_c}" "${_ppo_id}")"
        done
        log "INFO" "[Retention] [DRY RUN] would then delete $(manifest_display "${_ppo_id}")"
        PRUNE_ONE_PURGED=1; return 0
    fi

    if ! prune_mark_pruning "${_ppo_id}" "${_ppo_mf}"; then
        log "WARN" "[Retention] Deferring '${_ppo_id}': could not mark its manifest 'pruning' before deleting"
        PRUNE_ONE_ATTEMPTED=0; PRUNE_ONE_SKIPPED=1; return 0
    fi
    # Manifest LAST: it is the only record of what the backup held.
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
        log "WARN" "[Retention] --retention ${BACKUP_RETENTION} would expire every backup including this run; refusing to prune $(backup_root_display)"
        return 0
    fi

    # Retention deletes by age under this prefix, so log the scope every run.
    catalog_cache_init
    PRUNE_REFUSED=0
    log "INFO" "[Retention] Scope: $(backup_root_display)/ (must be unique per install — retention deletes by age and cannot tell whose backup an id is)"
    now=$(date +%s); started="${now}"
    # Exactly N days, as documented.
    cutoff=$((now - BACKUP_RETENTION * 86400))
    # GNU/BusyBox: -d @N; BSD/macOS: -r N.
    _ret_cut_h=$(date -u -d "@${cutoff}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || date -u -r "${cutoff}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || echo "epoch ${cutoff}")
    log "INFO" "[Retention] Pruning backups older than ${BACKUP_RETENTION}d (before ${_ret_cut_h}) under $(backup_root_display)/"

    # A failed listing must not read as "no backups" (DN-03).
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

    # Read 'latest' before deleting; a failed read is fail-closed (DN-03).
    local latest_rc=0 latest_raw=""
    latest_raw=$(catalog_latest) || latest_rc=$?
    if [ "${latest_rc}" -ne 0 ]; then
        # Read may fail because it is absent; probe with its own status (DN-03).
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

    # Classify first, delete later. set -f: bucket ids may contain glob chars.
    set -f
    local expired_ids="" kept_parseable=0 kept_complete=0 _kept_mf=""
    for id in ${ids}; do
        case "${id}" in
            backup_*) ;;
            *) log "INFO" "[Retention] Skipping '${id}' (not a backup_* id)"; skipped=$((skipped + 1)); continue ;;
        esac
        ts=$(backup_id_epoch "${id}" || true)
        # Check the shape: a non-numeric ts would make -ge fail and purge the id.
        case "${ts}" in
            ''|*[!0-9]*)
                log "WARN" "[Retention] Skipping '${id}': cannot parse a usable timestamp from the id"
                skipped=$((skipped + 1)); continue ;;
        esac
        if [ "${ts}" -ge "${cutoff}" ]; then
            kept=$((kept + 1)); kept_parseable=$((kept_parseable + 1))
            # At least one survivor must be restorable (DN-40); probe only until one is found.
            if [ "${kept_complete}" -eq 0 ]; then
            _kept_mf=$(catalog_manifest "${id}" 2>/dev/null || true)
            # Full-scope and complete, same predicate as 'latest' (DN-14).
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
            # 'latest' is always complete and full-scope (DN-14).
            kept_complete=$((kept_complete + 1))
            continue
        fi
        # Ownership checked only for deletion candidates; fail closed.
        _owner=$(backup_id_owner "${id}" || true)
        if [ -z "${_owner}" ]; then
            log "WARN" "[Retention] Skipping '${id}': cannot establish which namespace owns it (no readable manifest); refusing to delete a backup that cannot be proven ours"
            skipped=$((skipped + 1)); continue
        fi
        if [ "${_owner}" != "${NAMESPACE}" ]; then
            log "ERROR" "[Retention] Skipping '${id}': it belongs to namespace '${_owner}', not '${NAMESPACE}'."
            if [ "${S3_ENABLED}" = "true" ]; then
                log "ERROR" "[Retention]   Prefix '${S3_PREFIX}' is shared with another PMM-HA install. Give each install its own centralBackupStorage.s3.prefix — a shared prefix means each install's retention would delete the others' backups."
            else
                log "ERROR" "[Retention]   Shared path '$(backup_root)' is shared with another PMM-HA install. Each install writes under its own <namespace>/<release> subpath by default; a run reading someone else's (--shared-source-path) must not prune it."
            fi
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
    # Only kept parseable ids count as survivors; skipped junk must not disarm the guard.
    if [ "${kept_parseable}" -eq 0 ]; then
        set +f
        PRUNE_REFUSED=1
        log "ERROR" "[Retention] Refusing to prune: all ${expired} parseable backup(s) are past the cutoff, leaving no known-good backup (${skipped} unparseable entr(y|ies) do not count). Check --retention (${BACKUP_RETENTION}d) and the system clock."
        return 0
    fi
    # And at least one survivor must be restorable (DN-40).
    if [ "${kept_complete}" -eq 0 ]; then
        set +f
        PRUNE_REFUSED=1
        log "ERROR" "[Retention] Refusing to prune: ${kept_parseable} backup(s) survive the cutoff but NONE is a complete FULL-SCOPE backup (all four components), so pruning would leave nothing restorable."
        log "ERROR" "[Retention]   Fix whatever is failing the backups first; nothing is deleted until one full-scope backup succeeds again."
        return 0
    fi

    # ClickHouse chains, computed once before any delete (DN-09).
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
        # Cap ATTEMPTS, not successes; no cap in dry run so the preview is complete.
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
        # The S3 sweep needs nothing from BACKUP_DIR.
        prune_expired_backups
        return 0
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[DRY RUN] Cleanup commands:"
        log "INFO" "[DRY RUN]   \$ find ${STATE_DIR}/logs -maxdepth 1 -type f \\( -name 'backup_*.log' -o -name 'restore_*.log' -o -name 'prune_*.log' \\) -mtime +${BACKUP_RETENTION} -delete"
        if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN]   \$ kubectl exec <each clickhouse pod> -c clickhouse-backup -- clickhouse-backup clean"
        fi
        # The sweep prints the exact paths it would purge.
        prune_expired_backups
        log "INFO" "Cleanup completed (dry run)"
        return 0
    fi

    # Staging is scratch (DN-24).
    find "${STATE_DIR}/.staging" -maxdepth 1 -type d -name "backup_*" -mtime +1 \
        -exec rm -rf {} \; >> "${LOG_FILE}" 2>&1 || true

    # Logs: match every prefix this file writes; || true so a find hiccup cannot abort.
    find "${STATE_DIR}/logs" -maxdepth 1 -type f \
        \( -name "backup_*.log" -o -name "restore_*.log" -o -name "prune_*.log" \) -mtime +${BACKUP_RETENTION} \
        -delete >> "${LOG_FILE}" 2>&1 || true

    # Backup data is pruned only by prune_expired_backups.
    prune_expired_backups

    log "INFO" "[PostgreSQL] pg_dump files pruned with the per-id retention sweep"

    # shadow/ cleanup on every replica; skipped after a failed ClickHouse backup (may still be freezing).
    if [ "${BACKUP_CLICKHOUSE}" = "true" ] && [ "${COMMAND}" = "backup" ] \
            && [ "$(result_get clickhouse status "")" != "success" ]; then
        log "INFO" "[ClickHouse] shadow/ cleanup skipped: this run's ClickHouse backup did not succeed"
    elif [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Cleaning shadow/ leftovers..."
        local ch_pod
        for ch_pod in $(kubectl get pods -n "${NAMESPACE}" -l "$(comp_pod_selector clickhouse)" \
                -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
                clickhouse-backup clean >> "${LOG_FILE}" 2>&1 \
                || log "WARN" "[ClickHouse] clickhouse-backup clean failed in ${ch_pod} (see the log)"
        done
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

# Retention sweep result; its own family.
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
    mkdir -p "${metrics_dir}/backup" 2>/dev/null || true

    # One samples-only file per component (DN-42): a run replaces exactly the components it
    # covered, so a partial or concurrent run neither duplicates nor drops another's series.
    local _mc="" _mc_ok="" _m_body="" _m_written=0
    for _mc in $(printf '%s' "${RESULTS_JSON}" | jq -r 'keys[]' 2>/dev/null || true); do
        # Encryption is emitted below; emitting it here too duplicates the series.
        [ "${_mc}" = "encryption" ] && continue
        case "${_mc}" in *[!A-Za-z0-9_.-]*) continue ;; esac
        _mc_ok=$(result_ok "${_mc}" && echo 1 || echo 0)
        _m_body="pmm_ha_backup_last_success{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} ${_mc_ok}
pmm_ha_backup_last_timestamp_seconds{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} ${timestamp}
pmm_ha_backup_last_duration_seconds{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} $(result_get "${_mc}" duration 0)
pmm_ha_backup_last_size_bytes{component=\"${_mc}\",namespace=\"${NAMESPACE}\"} $(result_get "${_mc}" bytes 0)
"
        publish_metrics_file "${metrics_dir}/backup/${_mc}.prom" "${_m_body}" && _m_written=$((_m_written + 1))
    done
    # not_found is normal (no PG encryption), so it is treated like skipped.
    if [ "${enc_status}" != "skipped" ] && [ "${enc_status}" != "not_found" ]; then
        [ "${enc_status}" = "success" ] && _mc_ok=1 || _mc_ok=0
        _m_body="pmm_ha_backup_last_success{component=\"encryption\",namespace=\"${NAMESPACE}\"} ${_mc_ok}
pmm_ha_backup_last_timestamp_seconds{component=\"encryption\",namespace=\"${NAMESPACE}\"} ${timestamp}
"
        publish_metrics_file "${metrics_dir}/backup/encryption.prom" "${_m_body}" && _m_written=$((_m_written + 1))
    fi

    if [ "${_m_written}" -eq 0 ]; then
        log "WARN" "No component results to publish as metrics; leaving the previous files in place"
        return 0
    fi
    # Pre-merge single-file layout: it would duplicate every series above.
    rm -f "${metrics_dir}/backup/all.prom" 2>/dev/null || true
    log "INFO" "Metrics written to ${metrics_dir}/backup/ (${_m_written} file(s))"
    return 0
}

# Atomic replace (temp + mv) so a scrape never reads half a file.
publish_metrics_file() {   # <target> <samples>
    if { printf '%s' "$2" > "$1.tmp"; } 2>/dev/null && mv "$1.tmp" "$1" 2>/dev/null; then
        return 0
    fi
    log "WARN" "Could not publish backup metrics to $1; continuing"
    rm -f "$1.tmp" 2>/dev/null || true
    return 1
}

# Never fails the run (DN-32). Labels use manifest component keys (DN-42).
write_restore_metrics() {   # <in-progress> <phase> [last-success] [last-ts] [last-duration]
    local in_progress="$1" phase="$2" last_success="${3:-0}" last_ts="${4:-0}" last_dur="${5:-0}"
    # Per-component samples come from restore_ok.
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

# One summary row per component.
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

# Gates on the flag too: multi-pod components return 0 on partial success (DN-21).
# Updates cmd_backup's counters via dynamic scoping. Emits no spacer; the caller owns spacing.
record_backup_result() {   # <label> <component> <rc>
    if [ "$3" -eq 0 ] && result_ok "$2"; then
        components_backed_up=$((components_backed_up + 1))
        return 0
    fi
    # Record early failures here so stale metrics are not scraped (DN-38).
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
            if ! share_mkdir "${BACKUP_DIR}"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Failed to create backup directory: ${BACKUP_DIR}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Please check permissions or specify --backup-dir"
                exit 1
            fi
        fi

        share_mkdir "${STATE_DIR}/logs" || true
        # STATE_DIR, not the mount root: csi-driver-nfs re-groups an RWX root to its last mounter's fsGroup.
        if [ ! -w "${STATE_DIR}" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Backup directory is not writable: ${STATE_DIR}"
            exit 1
        fi

        # INT/TERM must exit too: ash/dash would resume unlocked after the handler (DN-20).
        LOCK_COMPONENTS=$(lock_list 4)
        trap release_locks EXIT
        trap 'stop_children; release_locks; exit 130' INT
        trap 'stop_children; release_locks; exit 143' TERM
        # Before acquire_locks and protect_operand_pods: both use install-scoped selectors.
        if ! resolve_component_scope 4; then exit 1; fi
        acquire_locks
        # After the traps and the lock, so holds are always stripped and never touch a live run.
        protect_operand_pods 4
    else
        # Dry run still appends stderr to LOG_FILE; a failed redirect fails the command.
        share_mkdir "${STATE_DIR}/logs" || true
        dir_writable "${STATE_DIR}/logs" || LOG_FILE="/dev/null"
        # release_locks also reaps the retention sweep's catalog cache, which runs in dry run too.
        trap release_locks EXIT
    fi

    echo ""

    log "INFO" "Starting backup (${TIMESTAMP})"
    [ "${DRY_RUN}" != "true" ] && log "INFO" "Log file: ${LOG_FILE}"
    
    # Dry-run path resolves scope here; must precede preflight's pod discovery.
    if ! resolve_component_scope 4; then exit 1; fi
    if ! preflight_checks backup; then
        exit 1
    fi
    log "INFO" "Namespace: ${NAMESPACE}"
    log "INFO" "Components:$(selected_labels 4)"
    log "INFO" ""
    
    local all_success=true
    local components_backed_up=0
    local components_failed=0
    local _comp_rc=0

    local _bc="" _btmp="" _bpids="" _bp="" _bres="" _bmerged=""
    for _bc in ${CORE_COMPONENTS}; do
        comp_on "${_bc}" 4 || log "INFO" "[$(comp_label "${_bc}")] ⊘ Backup skipped"
    done

    if parallel_enabled false && [ "${DRY_RUN}" != "true" ]; then
        # One process: single manifest/metrics writer, no DN-13 merge lease involved.
        log "INFO" "Running components CONCURRENTLY (--parallel). The slowest component sets the"
        log "INFO" "  wall clock, and they compete for the same node bandwidth while PMM is live."
        _btmp=$(mktemp -d 2>/dev/null || echo "/tmp/.backup_$$"); mkdir -p "${_btmp}" 2>/dev/null || true
        for _bc in ${CORE_COMPONENTS}; do
            comp_on "${_bc}" 4 || continue
            _backup_child "${_bc}" "${_btmp}" &
            _bpids="${_bpids} $!"
        done
        RUN_CHILD_PIDS="${_bpids}"
        # Only these children: a bare wait hangs on the lock renewer (lint-enforced).
        for _bp in ${_bpids}; do
            wait "${_bp}" 2>/dev/null || true
        done
        RUN_CHILD_PIDS=""
        # Merge in table order for deterministic output.
        for _bc in ${CORE_COMPONENTS}; do
            comp_on "${_bc}" 4 || continue
            _bres=$(cat "${_btmp}/${_bc}.json" 2>/dev/null || true)
            if [ -n "${_bres}" ]; then
                _bmerged=$(printf '%s' "${RESULTS_JSON}" \
                    | jq --argjson o "${_bres}" '. + $o' 2>/dev/null) || _bmerged=""
                [ -n "${_bmerged}" ] && RESULTS_JSON="${_bmerged}"
            fi
            # A child that wrote no status counts as FAILED.
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

    # Encryption key, captured with PostgreSQL (--skip-encryption-key).
    local encryption_status="skipped"
    if [ "${BACKUP_POSTGRESQL}" = "true" ] && [ "${BACKUP_ENCRYPTION_KEY}" = "true" ]; then
        # 0=success, 2=not found, 1=failed; $? after 'if cmd' would lose the code.
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
            # Without the key this run's PG dumps are undecryptable: run is partial.
            all_success=false
            log "ERROR" "[EncryptionKey] ✗ Backup failed — PG data from this run would be undecryptable in a DR restore"
        fi
        log "INFO" ""
    fi
    
    # Per-run manifest + 'latest' pointer: the restore index.
    local _wm_rc=0
    write_manifest "$([ "${all_success}" = "true" ] && echo complete || echo partial)" "${encryption_status}" || _wm_rc=$?
    if [ ${_wm_rc} -eq 2 ]; then
        # Restorable by id, but 'latest' still names an older backup.
        all_success=false
        log "ERROR" "[Manifest] 'latest' was not moved onto backup_${TIMESTAMP}; marking the run failed. Restore this backup by its id, not 'latest'."
    elif [ ${_wm_rc} -ne 0 ]; then
        # Without the manifest the backup is unrestorable.
        all_success=false
        log "ERROR" "[Manifest] Failed to write manifest.json — this backup is NOT restorable; marking the run failed."
    fi
    log "INFO" ""

    # Retention runs on catalog state, not this run's outcome, and never fails the backup (DN-40).
    _bk_prune_rc=0
    if retention_lock; then
        cleanup_old_backups || _bk_prune_rc=$?
        [ "${PRUNE_REFUSED}" -eq 0 ] || _bk_prune_rc=1
    else
        _bk_prune_rc=1
        log "WARN" "Retention sweep deferred: ${RETENTION_LOCK_WHY}"
    fi
    write_prune_metrics "${_bk_prune_rc}"
    if [ "${_bk_prune_rc}" -ne 0 ]; then
        log "WARN" "Retention sweep did NOT prune (see the reason above); the backup itself is unaffected."
    fi
    log "INFO" ""
    
    if [ "${DRY_RUN}" != "true" ]; then
        write_backup_metrics "${encryption_status}"
    fi

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

    summary_row postgresql      "PostgreSQL:     "
    summary_row clickhouse      "ClickHouse:     "
    summary_row victoriametrics "VictoriaMetrics:"
    summary_row pmm-server      "PMM Server:     "

    # Encryption key is not a component; rendered separately.
    if [ "${encryption_status}" != "skipped" ]; then
        case "${encryption_status}" in
            success)   log "INFO" "  ✓ Encryption Key:  OK | Kubernetes Secret (sha256 $(printf '%.16s' "$(result_get encryption sha256 '')")...)" ;;
            not_found) log "INFO" "  ○ Encryption Key:  Not found (encryption not configured)" ;;
            *)         log "WARN" "  ⚠ Encryption Key:  Failed" ;;
        esac
    fi

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
# Retention sweep (DN-40). Takes the clickhouse lock (`clickhouse-backup clean` in the live pod)
# and the pmm-server lock, which every restore holds, so it never purges what a restore reads.
################################################################################
cmd_prune() {
    log "INFO" "================================================================================"
    log "INFO" "PMM-HA Retention Sweep"
    log "INFO" "================================================================================"
    log "INFO" "Namespace: ${NAMESPACE}  Target: ${BACKUP_TARGET}  Retention: ${BACKUP_RETENTION}d  Log: ${LOG_FILE}"

    # ClickHouse only: an unrelated second VMCluster/PostgresCluster must not fail the prune.
    if ! resolve_component_scope 4 clickhouse; then exit 1; fi
    # The lease needs its owner even when --skip-clickhouse/--postgresql left it unresolved.
    if [ -z "${SCOPE_CH_CHI}" ]; then
        _pr_rc=0; SCOPE_CH_CHI=$(resolve_one ClickHouse "ClickHouseInstallation" chi) || _pr_rc=$?
        [ "${_pr_rc}" -le 1 ] || exit 1
    fi
    if ! preflight_checks prune; then exit 1; fi

    LOCK_COMPONENTS="clickhouse"
    trap release_locks EXIT
    trap 'release_locks; exit 130' INT
    trap 'release_locks; exit 143' TERM
    acquire_locks
    if ! retention_lock; then
        log "ERROR" "Retention sweep refused: ${RETENTION_LOCK_WHY}"; exit 1
    fi

    local _prune_rc=0
    cleanup_old_backups || _prune_rc=$?
    # A declined sweep is a failure, not a silent success.
    [ "${PRUNE_REFUSED}" -eq 0 ] || _prune_rc=1

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

    # Traps go in before anything is created: temp pods hold RWO data PVCs (DN-19).
    if [ "${DRY_RUN}" != "true" ]; then
        # Set once, before subshells fork: restore_cleanup reads it in the parent.
        [ -n "${TEMP_PODS_MARKER}" ] || {
            TEMP_PODS_MARKER=$(mktemp /tmp/pmm-temp-pods.XXXXXX 2>/dev/null || echo "/tmp/.pmm-temp-pods.$$")
            rm -f "${TEMP_PODS_MARKER}" 2>/dev/null || true
        }
        [ -n "${PG_STAGE_MARKER}" ] || PG_STAGE_MARKER="${TEMP_PODS_MARKER}.pgstage"
    fi
    # INT/TERM must exit too (DN-20). Also set for dry run: it reaps the local manifest copy.
    trap restore_cleanup EXIT
    trap 'stop_children; restore_cleanup; exit 130' INT
    trap 'stop_children; restore_cleanup; exit 143' TERM

    if ! load_manifest; then exit 1; fi
    select_default_components
    scope_encryption_key

    log "INFO" "Components:$(restore_plan_line)"

    # Only after select_default_components, and before validate_restore_targets.
    if ! resolve_component_scope 5; then exit 1; fi

    # A requested component not marked 'success' is a hard error before anything changes.
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
    # The default selection refuses too, rather than restore the rest and report success (DN-21).
    local _gaps="" _g=""
    _gaps=$(default_restore_gaps)
    if [ -n "${_gaps}" ]; then
        log "ERROR" "${BACKUP_NAME} has component(s) that cannot be restored:${_gaps}"
        log "ERROR" "Nothing was changed. Restore the rest with$(for _g in ${_gaps}; do printf ' --skip-%s' "$(comp_col "${_g%%(*}" 2)"; done), or name the components to restore."
        exit 1
    fi

    # Validate before the confirmation prompt (DN-15).
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
        # pmm-server lock is forced: every restore scales PMM down/up.
        local _saved_pmm="${RESTORE_PMM_SERVER}"
        RESTORE_PMM_SERVER=true
        LOCK_COMPONENTS=$(lock_list 5)
        RESTORE_PMM_SERVER="${_saved_pmm}"
        acquire_locks
        # A sweep that held the pmm-server lock before us may have purged this id since it was validated.
        if ! restore_manifest_unchanged; then
            log "ERROR" "${BACKUP_NAME}'s manifest changed or could not be re-read since it was validated (a retention sweep?). Nothing has been changed; re-run the restore."
            exit 1
        fi
        # Exec'd PG/ClickHouse pods need the hold too; set in the parent before subshells fork.
        protect_operand_pods 5
    fi
    RESTORE_START_TIME=$(date +%s)

    # 1. Encryption key first — read and verified here, applied after scale-down (step 2).
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "encryption_key"
    local _enc_apply=false
    if [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${MF_ENC_STATUS}" = "success" ]; then
        prepare_encryption_key && ENCRYPTION_KEY_OK=true && _enc_apply=true
    else
        [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && log "WARN" "Encryption key requested but not in this backup"
        ENCRYPTION_KEY_OK=true
    fi
    # Not overridable by --yes (DN-44); --skip-encryption-key is the explicit override.
    if [ "${ENCRYPTION_KEY_OK}" != "true" ]; then
        log "ERROR" "Encryption key restore FAILED. Aborting before anything is changed (PMM is still running)."
        log "ERROR" "  Restored PostgreSQL data would not be decryptable without this key."
        log "ERROR" "  Fix the cause, or re-run with --skip-encryption-key to proceed deliberately without it."
        write_restore_metrics 0 "idle" 0 "$(date +%s)" 0; exit 1
    fi

    # 2. Scale PMM down first; it comes back up last, against restored data.
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "scale_down_pmm"
    if ! scale_down_pmm; then log "ERROR" "Failed to scale down PMM; aborting."; [ -n "${ENC_KEY_FILE}" ] && rm -f "${ENC_KEY_FILE}"; write_restore_metrics 0 "idle" 0 "$(date +%s)" 0; exit 1; fi
    if [ "${_enc_apply}" = "true" ] && ! apply_encryption_key; then
        # Nothing was written yet, so PMM goes back to serving instead of staying at 0.
        log "ERROR" "Encryption key could not be applied; aborting. No data was written, scaling PMM back up."
        scale_up_pmm || true
        write_restore_metrics 0 "idle" 0 "$(date +%s)" 0; exit 1
    fi

    # 3. The three data stores (PMM is down).
    # Unselected components count as OK so restore metrics do not alert on them.
    local tmpdir _rc=""
    tmpdir=$(mktemp -d 2>/dev/null || echo "/tmp/.restore_$$"); mkdir -p "${tmpdir}" 2>/dev/null || true
    for _rc in ${RESTORE_DB_COMPONENTS}; do
        restore_do "${_rc}" && continue
        comp_on "${_rc}" 5 && log "WARN" "$(comp_label "${_rc}") requested but not marked 'success' in this backup; not restoring it"
        restore_ok_set "${_rc}" true
    done

    if parallel_enabled true && [ "${DRY_RUN}" != "true" ]; then
        write_restore_metrics 1 "components"
        # Subshells reset the EXIT trap; status comes back via rc files.
        local _pids="" _p=""
        for _rc in ${RESTORE_DB_COMPONENTS}; do
            restore_do "${_rc}" || continue
            _restore_child "${_rc}" "${tmpdir}" &
            _pids="${_pids} $!"
        done
        RUN_CHILD_PIDS="${_pids}"
        # Only these children: a bare wait hangs on the lock renewer (lint-enforced).
        for _p in ${_pids}; do
            wait "${_p}" 2>/dev/null || true
        done
        RUN_CHILD_PIDS=""
        # A child that wrote no rc file counts as FAILED.
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

    # Only in-scope components count; the key check is unguarded on purpose.
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
        cross_namespace_advisory
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

# The subcommand is required; there is no default operation (DN-02).
main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            backup|restore|list|prune) COMMAND="$1"; shift ;;
            # --list: restore-era alias for 'list'.
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

    [ "${LIST_ONLY}" = "true" ] && COMMAND="list"

    case "${BACKUP_TARGET}" in
        s3)
            S3_ENABLED=true
            # Without a bucket, list would silently report "no backups".
            [ -n "${S3_BUCKET}" ] || { echo "Error: --target s3 requires --s3-bucket (or S3_BUCKET)"; exit 1; }
            ;;
        shared)
            S3_ENABLED=false
            # Shared volume: namespaces differ in uid but share gid 0, so stay group-writable.
            umask 0002
            ;;
        *)
            echo "Error: Invalid --target: '${BACKUP_TARGET}' (must be: s3, shared)"; exit 1 ;;
    esac

    # Namespace is spliced into metrics labels and the S3 prefix default.
    case "${NAMESPACE}" in
        ''|*[!a-z0-9.-]*)
            echo "Error: Invalid --namespace: '${NAMESPACE}' (a Kubernetes namespace is lowercase alphanumerics, '-' and '.')"
            exit 1 ;;
    esac

    if [ -z "${S3_PREFIX}" ]; then
        # Mirrors the chart's pmm.backupS3Root: <namespace>/<release>.
        S3_PREFIX="${NAMESPACE}/${TARGET_RELEASE:-pmm-ha}"
    fi
    if [ "${BACKUP_TARGET}" = "shared" ] && [ -z "${SHARED_SUBPATH}" ]; then
        SHARED_SUBPATH="${NAMESPACE}/${TARGET_RELEASE:-pmm-ha}"
    fi
    # -d moves logs/ and .staging/ unless STATE_DIR was set explicitly.
    [ -n "${_STATE_DIR_FROM_ENV}" ] || STATE_DIR="${BACKUP_DIR}"

    # Refuse (never sanitise) S3 settings: they reach SQL literals, CLI args and YAML (DN-17).
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

    # Every subcommand: the id reaches paths, SQL and in-pod sh -c strings.
    if [ -n "${BACKUP_ID}" ]; then
        case "${BACKUP_ID}" in
            *[!A-Za-z0-9_-]*)
                echo "Error: Invalid --backup-id: '${BACKUP_ID}' (allowed characters: A-Z a-z 0-9 _ -)"
                exit 1
                ;;
        esac
    fi

    if [ "${COMMAND}" = "restore" ]; then
        # Rendered by functions: their leading whitespace is YAML content.
        TEMP_POD_S3_KEYS_ENV=$(render_temp_pod_s3_keys_env)
        TEMP_POD_VM_S3_KEYS_ENV=$(render_temp_pod_vm_s3_keys_env)
        TEMP_POD_SA_LINE=$(render_temp_pod_sa_line)
        init_log
    else

        case "${CH_BACKUP_TYPE}" in
            full|incremental) ;;
            *) echo "Error: Invalid --ch-backup-type: ${CH_BACKUP_TYPE} (must be: full, incremental)"; exit 1 ;;
        esac

        # Flows unquoted into find -mtime +N.
        case "${BACKUP_RETENTION}" in
            ''|*[!0-9]*) echo "Error: Invalid --retention: '${BACKUP_RETENTION}' (must be a non-negative integer)"; exit 1 ;;
        esac
        # Strip leading zeros: arithmetic would read them as octal (DN-22).
        BACKUP_RETENTION=$(echo "${BACKUP_RETENTION}" | sed 's/^0*\([0-9]\)/\1/')

        # Strip a leading backup_ or paths become backup_backup_<ts>.
        [ -n "${BACKUP_ID}" ] && TIMESTAMP="$(backup_id_bare "${BACKUP_ID}")"

        # Single-component --backup-id gets a per-component suffix.
        if [ -n "${BACKUP_ID}" ]; then
            _comp_count=0
            _comp_name=""
            for _comp_c in ${CORE_COMPONENTS}; do
                comp_on "${_comp_c}" 4 || continue
                _comp_count=$((_comp_count + 1)); _comp_name="${_comp_c}"
            done
            [ ${_comp_count} -eq 1 ] && COMPONENT_SUFFIX="_${_comp_name}"
        fi

        # Separate prune_ prefix keeps backup logs clean; the reaper matches on it.
        if [ "${COMMAND}" = "prune" ]; then
            LOG_FILE="${STATE_DIR}/logs/prune_${TIMESTAMP}.log"
            share_mkdir "${STATE_DIR}/logs" || true
            dir_writable "${STATE_DIR}/logs" || LOG_FILE="/tmp/prune_${TIMESTAMP}.log"
        elif [ "${COMMAND}" = "list" ]; then
            # Read-only, prints to stdout; keep it out of the backup log series.
            LOG_FILE="/dev/null"
        else
            LOG_FILE="${STATE_DIR}/logs/backup_${TIMESTAMP}${COMPONENT_SUFFIX}.log"
            # Fall back to /tmp: an unwritable logs/ fails every >>LOG_FILE redirect.
            share_mkdir "${STATE_DIR}/logs" || true
            if ! dir_writable "${STATE_DIR}/logs"; then
                LOG_FILE="/tmp/backup_${TIMESTAMP}${COMPONENT_SUFFIX}.log"
                _LOGDIR_FELL_BACK="${STATE_DIR}/logs"
            fi
        fi
        CURRENT_ID="backup_${TIMESTAMP}"
    fi

    # Warn now, before component errors get blamed instead.
    if [ -n "${_LOGDIR_FELL_BACK}" ]; then
        log "WARN" "${_LOGDIR_FELL_BACK} is not writable; this run logs to ${LOG_FILE} instead."
        log "WARN" "  The log is inside this pod and is NOT on the backup volume: copy it out before the pod is replaced."
    fi

    case "${COMMAND}" in
        list)
            # Non-zero means the catalog could not be read.
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

# PMM_BACKUP_LIB=1 loads definitions only (used by tests/pmm-backup-unit.sh).
[ "${PMM_BACKUP_LIB:-}" = "1" ] || main "$@"
