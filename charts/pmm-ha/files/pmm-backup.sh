#!/bin/sh
set -eu

################################################################################
# PMM-HA Backup / Restore / List — one orchestrator (PMM-13858)
#
# This file replaces the former backup-orchestrator.sh, restore-orchestrator.sh and the
# sourced backup-layout.sh. The two orchestrators duplicated eleven functions (logging, locking,
# S3 primitives, manifest access, list, metrics plumbing) and the copies drifted — every
# significant regression in the retention work came from one copy being updated and its
# twin forgotten. One file removes the drift surface, and with it the source-time
# contract backup-layout.sh required its callers to satisfy.
#
# Subcommands (one is REQUIRED — there is deliberately no default, see section 11):
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
# Engines: PostgreSQL pg_dump/pg_restore, ClickHouse clickhouse-backup (via the
# system.backup_actions API; restore_remote on restore), VictoriaMetrics
# vmbackup/vmrestore, PMM server /srv tar. Restore is manifest-driven. Both operations
# support --target s3 (object storage) and --target shared (mounted RWX/NFS volume).
#
# Shell: uses `local` and other common extensions beyond strict POSIX sh. Supported
# shells: BusyBox ash (the backup-tools image), dash, and bash — all implement these.
################################################################################

################################################################################
# 1. Defaults + argument parsing
################################################################################

# ---- Common configuration -----------------------------------------------------
NAMESPACE="${NAMESPACE:-demo}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_ID=""            # backup: shared id grouping concurrent runs (auto if omitted)
                        # restore: <timestamp> | backup_<timestamp> | latest
BACKUP_DIR="${BACKUP_DIR:-/backups}"   # logs/metadata; the central mount in shared mode
METRICS_DIR="${METRICS_DIR:-/backups/.metrics}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN=false
LOG_FILE=""             # set per operation before the first log() call (see dispatch)

# Backup target mode (where backups land / where a restore reads from):
#   s3     - each component writes to / reads from object storage (vmbackup +
#            clickhouse-backup native; PG dumps and /srv stream through the rclone
#            pmm-backup sidecar). No pod mounts.
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
# Left EMPTY when nothing supplied it, and resolved after parsing (see section 11) to
# "<namespace>/pmm-ha" — the same root the chart's pmm.backupS3Root helper composes and
# projects as S3_PREFIX. The old fallback was a bare "pmm-ha", so any run that did not
# inherit the pod env (a laptop, an ad-hoc pod, the documented cross-namespace restore)
# silently addressed a DIFFERENT root from the one the install writes to, and reported
# "no backups" for a bucket that was full — which during an incident reads as data loss.
S3_PREFIX=$(echo "${S3_PREFIX:-}" | sed 's|^/||; s|/$||')
# rclone remote name; its config is supplied via RCLONE_CONFIG_<NAME>_* env vars
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"
# Derived from BACKUP_TARGET after parsing; kept for the per-tool S3 branches.
S3_ENABLED=false

# Timeout settings (in seconds) for kubectl commands.
# NOTE: We use the `timeout` command wrapper instead of kubectl's --request-timeout
# flag because --request-timeout breaks kubectl's in-cluster API server discovery
# when running inside a pod (kubectl falls back to localhost:8080 instead of using
# the ServiceAccount token). Discovered during in-cluster testing on kubectl v1.35.
KUBECTL_EXEC_TIMEOUT="${KUBECTL_EXEC_TIMEOUT:-600}"
KUBECTL_STATUS_TIMEOUT="${KUBECTL_STATUS_TIMEOUT:-30}"

# Kubernetes label selectors (one definition for both operations)
LABEL_PG_PRIMARY="postgres-operator.crunchydata.com/role=primary"
LABEL_CH_POD="clickhouse.altinity.com/chi"
LABEL_VM_STORAGE="app.kubernetes.io/name=vmstorage"
# PMM server pods (HA StatefulSet); selector discovers all replicas (1, 3, 5, ...)
LABEL_PMM_SERVER="app.kubernetes.io/component=pmm-server"
LABEL_BACKUP_TOOLS="app.kubernetes.io/component=backup-tools"

# ClickHouse credentials secret (both operations)
CH_SECRET_NAME="${CH_SECRET_NAME:-pmm-secret}"

# Component locks held by the running operation (see acquire_locks). Empty until an
# operation computes its list, so an early trap can call release_locks harmlessly.
LOCK_COMPONENTS=""
# Cached S3 client pod (the pmm-backup rclone sidecar, or restore's temp client pod).
S3_CLIENT_POD=""
# True when S3_CLIENT_POD is the restore's DEDICATED pod. That pod carries no
# ${LABEL_PMM_SERVER} label, so pick_s3_client_pod cannot re-find it: any code that
# invalidates the cache must not do so while it is in use (see invalidate_s3_client_pod).
S3_CLIENT_POD_PINNED=false
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
CH_UPLOAD_TIMEOUT="${CH_UPLOAD_TIMEOUT:-600}"

# PMM server (/srv) settings: path inside the PMM server pod to archive
PMM_SRV_PATH="${PMM_SRV_PATH:-/srv}"

# Per-component suffix for concurrent mode (--backup-id with a single component);
# computed after parsing.
COMPONENT_SUFFIX=""

# Global backup state tracking (for the manifest and summary)
PG_BACKUP_SUCCESS=false
CH_BACKUP_SUCCESS=false
CH_BACKUP_NAME=""
VM_BACKUP_SUCCESS=false
PMM_BACKUP_SUCCESS=false

# Per-component metadata for final summary
PG_DUMP_DBS=""
PG_BACKUP_SIZE=""
PG_BACKUP_SIZE_BYTES=0
PG_BACKUP_DURATION=""
PG_BACKUP_LOCATION=""
CH_BACKUP_SIZE=""
CH_BACKUP_SIZE_BYTES=0
CH_BACKUP_DURATION=""
CH_BACKUP_LOCATION=""
VM_BACKUP_POD_COUNT=0
VM_BACKUP_TOTAL_BYTES=0
VM_BACKUP_DURATION=""
PMM_BACKUP_POD_COUNT=0
PMM_BACKUP_TOTAL_BYTES=0
PMM_BACKUP_DURATION=""
PMM_BACKUP_OBJECTS=""   # per-pod landed refs (s3:// URIs or shared paths) for the manifest
VM_BACKUP_OBJECTS=""    # per-pod vmbackup dst refs (s3:// URIs or shared paths) for the manifest
ENCRYPTION_KEY_LOCATION=""

# ---- Restore configuration ------------------------------------------------------
FORCE=false
PARALLEL=true

# rclone provider profile for the temp S3 client pod: AWS | Minio | Ceph | Other
S3_PROVIDER="${S3_PROVIDER:-AWS}"
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

# VictoriaMetrics restore (auto-detected from the vmstorage pod if unset)
VMRESTORE_IMAGE="${VMRESTORE_IMAGE:-}"
VM_STORAGE_PVC_PREFIX="${VM_STORAGE_PVC_PREFIX:-vmstorage-db-}"

# Central backup PVC (shared mode only; auto-detected from backup-tools pod if unset)
CENTRAL_BACKUP_PVC="${CENTRAL_BACKUP_PVC:-}"

# Dedicated rclone client pod for s3 restores. The pmm-backup sidecar rides on the PMM
# pods, which the restore scales to 0 BEFORE restoring components — so ordinal mapping
# (VM/PMM source lookup) and PG dump streaming would lose their S3 client exactly when
# they need it (and a re-run after a failed restore starts with PMM already down).
# Same image/env as the chart's sidecar, IRSA SA for creds; the container is deliberately
# named 'pmm-backup' so every exec call site works unchanged.
S3_CLIENT_IMAGE="${S3_CLIENT_IMAGE:-docker.io/rclone/rclone:1.74.3}"
RESTORE_CLIENT_POD="restore-s3-client-$$"

# Restore runtime state initialised up front: the script runs under `set -u`, so anything
# read before its first assignment aborts the run.
BACKUP_NAME=""             # backup_<timestamp>
MANIFEST_FILE=""           # local temp copy of manifest.json
MF_STATUS="" ; MF_TARGET="" ; MF_CREATED=""
MF_PG_STATUS="" ; MF_PG_DBS=""
MF_CH_STATUS="" ; MF_CH_NAME=""
MF_VM_STATUS="" ; MF_PMM_STATUS="" ; MF_ENC_STATUS=""
PMM_SAVED_REPLICAS="" ; PMM_STATEFULSET_NAME=""
# Rendered into every temp restore pod; assigned for real in the restore dispatch branch.
# Initialised here because the whole point of this block is that `set -u` aborts on any
# read-before-assignment, and these two are dereferenced bare by render_rclone_s3_env,
# create_s3_client_pod, create_vm_restore_pod, create_pmm_restore_pod and
# validate_restore_targets.
TEMP_POD_S3_KEYS_ENV="" ; TEMP_POD_SA_LINE=""
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

Commands (one is REQUIRED — there is no default operation):
  backup                    Back up the selected components.
  restore                   Restore the selected components from a backup (manifest-driven).
                            Scales PMM down first, brings it up last; refuses to run
                            non-interactively without --force.
  list [BACKUP_ID]          List backups, or — given a BACKUP_ID — show every file/location
                            that belongs to that one backup, read from its manifest.json.
                            Requires the same --s3-bucket / --s3-prefix / --namespace as the
                            backup (in s3 mode it lists via the pmm-backup sidecar's rclone).

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

Restore options:
  --list                    Alias for the 'list' subcommand (list all backups) and exit
  --parallel | --sequential Restore DB components in parallel (default) or one by one
  --force                   Skip the confirmation prompt (required with no TTY)
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

  # Run components concurrently (grouped by backup-id)
  BACKUP_ID=\$(date +%Y%m%d-%H%M%S)
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
  CH_SECRET_NAME            Kubernetes secret for ClickHouse credentials (default: pmm-secret)
  CH_CREATE_TIMEOUT         Max seconds to wait for ClickHouse backup creation (default: 300)
  CH_UPLOAD_TIMEOUT         Max seconds to wait for ClickHouse S3 upload (default: 600)
  CH_LIST_TIMEOUT           Budget for the restore pre-flight 'list remote' (default: 120)
  PMM_SRV_PATH              Path archived from each PMM server pod (default: /srv)
  PMM_SERVER_REPLICAS       Fallback PMM replica count on restore scale-up (default: 3)
  S3_CLIENT_IMAGE           Image for the restore's temp rclone client pod
  VMRESTORE_IMAGE           vmrestore image override (default: auto-detected from the pod)
  CENTRAL_BACKUP_PVC        Central backup PVC name (shared-mode restore; auto-detected)

Concurrency:
  Per-component locking (.backup_<component>.lock under the backup dir) lets separate
  component backups run in parallel, and stops a backup and a restore of the same
  component from overlapping. Use --backup-id to group concurrent backup runs into the
  same backup.

Manifest & Catalog (both modes):
  Components land under <component>/<id>/ — there isn't always one folder holding
  everything. Every run writes ONE index that ties the pieces together:
    s3 mode     -> s3://<bucket>/<prefix>/manifests/<id>.json   + .../latest
    shared mode -> <central>/manifests/<id>.json                + <central>/latest
  'latest' is a small text file holding the newest complete full-scope backup id.
  Use '$0 list' / '$0 list <id>' to read them. Restore drives each engine by the
  coordinates the manifest records (PG dump databases, CH backup name, VM/PMM paths).

Metrics:
  Backups write per-component metrics to METRICS_DIR (postgresql_metrics.prom,
  clickhouse_metrics.prom, victoriametrics_metrics.prom, pmm-server_metrics.prom);
  restores write restore_metrics.prom. These are served over HTTP by netcat listeners
  on ports 9091-9094 in the backup-tools pod and scraped by vmagent.

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
    if [ "${COMMAND}" != "$1" ] && [ "${COMMAND}" != "list" ]; then
        echo "Error: Unknown option: $2"
        echo "Use --help for usage information"
        exit 1
    fi
}

# Parse command-line arguments (after the subcommand has been consumed by the dispatch
# block at the bottom of this file, which also sets COMMAND before this runs).
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
                NAMESPACE="$2"; shift
                ;;
            -d|--backup-dir)
                BACKUP_DIR="$2"; shift
                ;;
            --backup-id)
                BACKUP_ID="$2"; shift
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --target)
                BACKUP_TARGET="$2"; shift
                ;;
            --shared-mount-path)
                SHARED_MOUNT_PATH="$2"; shift
                ;;
            --s3-bucket)
                S3_BUCKET="$2"; shift
                ;;
            --s3-endpoint)
                S3_ENDPOINT="$2"; shift
                ;;
            --s3-region)
                S3_REGION="$2"; shift
                ;;
            --s3-prefix)
                S3_PREFIX=$(echo "$2" | sed 's|^/||; s|/$||'); shift
                ;;
            --ch-secret)
                CH_SECRET_NAME="$2"; shift
                ;;
            # First explicit component selection disables the others (default is all-on
            # for backup / manifest-driven for restore); additional --<component> flags
            # then combine. Same semantics both operations, different flag sets.
            --postgresql)
                if [ "${COMMAND}" = "restore" ]; then
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false; RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }
                    RESTORE_POSTGRESQL=true
                else
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_CLICKHOUSE=false; BACKUP_VICTORIAMETRICS=false; BACKUP_PMM_SERVER=false; EXPLICIT_SELECTION=true; }
                    BACKUP_POSTGRESQL=true
                fi
                ;;
            --clickhouse)
                if [ "${COMMAND}" = "restore" ]; then
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_VICTORIAMETRICS=false; RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }
                    RESTORE_CLICKHOUSE=true
                else
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_POSTGRESQL=false; BACKUP_VICTORIAMETRICS=false; BACKUP_PMM_SERVER=false; EXPLICIT_SELECTION=true; }
                    BACKUP_CLICKHOUSE=true
                fi
                ;;
            --victoriametrics)
                if [ "${COMMAND}" = "restore" ]; then
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }
                    RESTORE_VICTORIAMETRICS=true
                else
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_POSTGRESQL=false; BACKUP_CLICKHOUSE=false; BACKUP_PMM_SERVER=false; EXPLICIT_SELECTION=true; }
                    BACKUP_VICTORIAMETRICS=true
                fi
                ;;
            --pmm-server)
                if [ "${COMMAND}" = "restore" ]; then
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }
                    RESTORE_PMM_SERVER=true
                else
                    [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_POSTGRESQL=false; BACKUP_CLICKHOUSE=false; BACKUP_VICTORIAMETRICS=false; EXPLICIT_SELECTION=true; }
                    BACKUP_PMM_SERVER=true
                fi
                ;;
            --encryption-key)
                flag_requires restore "$1"
                [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false; RESTORE_PMM_SERVER=false; EXPLICIT_SELECTION=true; }
                RESTORE_ENCRYPTION_KEY=true
                ;;
            --skip-postgresql)
                if [ "${COMMAND}" = "restore" ]; then SKIP_POSTGRESQL=true; else BACKUP_POSTGRESQL=false; fi
                ;;
            --skip-clickhouse)
                if [ "${COMMAND}" = "restore" ]; then SKIP_CLICKHOUSE=true; else BACKUP_CLICKHOUSE=false; fi
                ;;
            --skip-victoriametrics)
                if [ "${COMMAND}" = "restore" ]; then SKIP_VICTORIAMETRICS=true; else BACKUP_VICTORIAMETRICS=false; fi
                ;;
            --skip-pmm-server)
                if [ "${COMMAND}" = "restore" ]; then SKIP_PMM_SERVER=true; else BACKUP_PMM_SERVER=false; fi
                ;;
            --skip-encryption-key)
                if [ "${COMMAND}" = "restore" ]; then SKIP_ENCRYPTION_KEY=true; else BACKUP_ENCRYPTION_KEY=false; fi
                ;;
            # ---- backup-only ----
            -r|--retention)
                flag_requires backup "$1"
                BACKUP_RETENTION="$2"; shift
                ;;
            --ch-backup-type)
                flag_requires backup "$1"
                CH_BACKUP_TYPE="$2"; shift
                ;;
            # Alias for the 'list' subcommand, in any mode — the help documents it as one,
            # so gating it to `restore` made the documented bare form error out.
            --list)
                LIST_ONLY=true
                ;;
            # ---- restore-only ----
            --parallel)
                flag_requires restore "$1"
                PARALLEL=true
                ;;
            --sequential)
                flag_requires restore "$1"
                PARALLEL=false
                ;;
            --s3-provider)
                flag_requires restore "$1"
                S3_PROVIDER="$2"; shift
                ;;
            --s3-secret)
                flag_requires restore "$1"
                S3_SECRET_NAME="$2"; shift
                ;;
            --s3-service-account)
                flag_requires restore "$1"
                S3_SERVICE_ACCOUNT="$2"; S3_SA_EXPLICIT=true; shift
                ;;
            --force)
                flag_requires restore "$1"
                FORCE=true
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
init_log() {
    LOG_FILE="${BACKUP_DIR}/logs/restore_$(date +%Y%m%d-%H%M%S).log"
    if ! mkdir -p "${BACKUP_DIR}/logs" 2>/dev/null || ! : >>"${LOG_FILE}" 2>/dev/null; then
        LOG_FILE="/tmp/restore_$(date +%Y%m%d-%H%M%S).log"
        : >>"${LOG_FILE}" 2>/dev/null || true
    fi
}

# Stream stdin (command output) to the log + stderr.
append_to_log() { tee -a "${LOG_FILE}" >&2 2>/dev/null || cat >&2; }

# Format a byte count as a human-readable string (e.g. 1234567 -> "1.2MB").
# Single source of truth for size formatting across all components.
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i=1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i]; else printf "%.1f%s", b, u[i]
    }'
}

# jq is a hard requirement: manifest generation/merging/parsing and the encryption-key
# export all use it. Try to self-install on Alpine (backup-tools image); callers decide
# how to fail when it cannot be provided.
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq >/dev/null 2>&1 || true
    fi
    command -v jq >/dev/null 2>&1
}

################################################################################
# 3+4. Layout + storage access (formerly the sourced backup-layout.sh)
################################################################################

# One definition of where a backup lives and how to read/write it, for BOTH
# operations. This used to be a separate sourced file with an unenforced
# pre-source contract (callers had to define the S3 settings and five primitives
# first); merging the orchestrators deleted the contract.

# ---- Layout -------------------------------------------------------------------------
#   <root>/latest                          newest backup id
#   <root>/manifests/<id>.json             per-run index
#   <root>/<component>/<id>/...            component data
#
# Every component sits at the same depth in the same shape, ClickHouse included. The
# namespace leads <root> so two installs on one cluster cannot share it by default —
# retention deletes by age under a root and cannot tell whose backup an id is.
#
# THREE views, because the same location is addressed three different ways and confusing
# them has already caused a bug (a check that stat'ed the orchestrator's mount for a file
# the ClickHouse pod reads through a different one):
#   *_path     what THIS process passes to rclone / opens directly
#   *_display  human-readable, for logs and the manifest (s3://… not remote:…)
#   *_inpod    what a COMPONENT pod sees — identical on s3; the shared volume is mounted at
#              SHARED_MOUNT_PATH inside pods and at BACKUP_DIR here
#
# A backup is a correlation across component paths sharing an id, NOT a directory. Retention
# must therefore delete every component path for an id or none — the structure no longer
# enforces atomicity by itself.
backup_root() {
    if [ "${S3_ENABLED}" = "true" ]; then echo "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}"
    else echo "${BACKUP_DIR}"; fi
}
backup_root_display() {
    if [ "${S3_ENABLED}" = "true" ]; then echo "s3://${S3_BUCKET}/${S3_PREFIX}"
    else echo "${BACKUP_DIR}"; fi
}
backup_root_inpod() {
    if [ "${S3_ENABLED}" = "true" ]; then echo "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}"
    else echo "${SHARED_MOUNT_PATH}"; fi
}
# An empty id would resolve to the component ROOT (every backup), so callers that ask for a
# path before the id is known must fail rather than silently read one level too high.
_require_id() { [ -n "$1" ] || { echo "BUG: backup id not yet known at path construction" >&2; return 1; }; echo "$1"; }
comp_path() {
    _cp_id=$(_require_id "${2:-$(backup_id_default)}") || return 1
    echo "$(backup_root)/$1/${_cp_id}"
}
comp_display() { echo "$(backup_root_display)/$1/${2:-$(backup_id_default)}"; }
comp_inpod()   { echo "$(backup_root_inpod)/$1/${2:-$(backup_id_default)}"; }
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
# must NOT conflate with "the data is absent" — retention deletes on that distinction and a
# fail-closed pre-restore gate refuses on it.
#
# Consequently NO function here may end in a pipe. A pipeline reports its LAST element's
# status, so `rclone lsf … | sed` returns sed's success even when rclone failed — which is
# how a retention sweep came to read a failed listing as "no backups" and a validation gate
# came to report "your backup is missing" for an unreachable sidecar. Output is captured
# first, then transformed, so the original status survives.
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
# Empty output with rc 0 means "nothing there"; rc non-zero means "could not look".
store_list() {
    _sl_out=""
    if [ "${S3_ENABLED}" = "true" ]; then
        _sl_out=$(s3_rclone lsf "$1/") || return $?
    else
        [ -d "$1" ] || return 0
        # An unreadable directory (EACCES after an fsGroup change, NFS squash, root-owned dir
        # from an older chart) must NOT read as "nothing there" — that is the conflation this
        # file's contract forbids. Only a readable-but-empty directory is success-with-nothing.
        [ -r "$1" ] || return 1
        _sl_out=$(ls -1 "$1" 2>/dev/null) || true
    fi
    [ -n "${_sl_out}" ] && printf '%s\n' "${_sl_out}"
    return 0
}
store_list_files() {
    _slf_out=""
    if [ "${S3_ENABLED}" = "true" ]; then
        _slf_out=$(s3_rclone lsf --files-only "$1/") || return $?
    else
        [ -d "$1" ] || return 0
        [ -r "$1" ] || return 1
        _slf_out=$(ls -1p "$1" 2>/dev/null) || true
        _slf_out=$(printf '%s\n' "${_slf_out}" | grep -v '/$' || true)
    fi
    [ -n "${_slf_out}" ] && printf '%s\n' "${_slf_out}"
    return 0
}
store_list_dirs() {
    _sld_out=""
    if [ "${S3_ENABLED}" = "true" ]; then
        _sld_out=$(s3_rclone lsf --dirs-only "$1/") || return $?
        _sld_out=$(printf '%s\n' "${_sld_out}" | sed 's:/$::' || true)
    else
        [ -d "$1" ] || return 0
        [ -r "$1" ] || return 1
        _sld_out=$(ls -1p "$1" 2>/dev/null) || true
        _sld_out=$(printf '%s\n' "${_sld_out}" | sed -n 's:/$::p' || true)
    fi
    [ -n "${_sld_out}" ] && printf '%s\n' "${_sld_out}"
    return 0
}
# Byte count on stdout; rc non-zero = could not look (callers rely on that to tell
# "empty/absent" from "unknown").
store_bytes() {
    _sb_out=""
    if [ "${S3_ENABLED}" = "true" ]; then
        _sb_out=$(s3_rclone size --s3-no-check-bucket --json "$1" 2>/dev/null) || return $?
        printf '%s' "${_sb_out}" | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p'
    else
        [ -f "$1" ] || { echo 0; return 0; }
        _sb_out=$(wc -c < "$1" 2>/dev/null) || return $?
        printf '%s' "${_sb_out}" | tr -dc '0-9'
    fi
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
# A failed delete is forgivable ONLY if the thing is provably gone. A plain existence probe
# was wrong here (and the two-state helper that did it has been deleted rather than left as
# a trap): "not found" and "could not look" are indistinguishable in its exit status, so
# unreachable storage read as "already deleted" and a sweep that deleted nothing reported
# success and then removed the manifest. Here absence must be POSITIVELY established: a
# listing that succeeds and does not contain the entry. Anything else is a failure.
#
# store_list, NOT store_list_files: the delete target is a PREFIX for store_delete_prefix and
# an object for store_delete_object, and a files-only listing can never contain a surviving
# DIRECTORY. That made every failed purge of <component>/<id>/ report "provably gone", so
# retention counted no component failure and deleted the manifest — leaving component data
# with no index, invisible to list, restore and every later sweep. That is exactly the
# atomicity rule the retention section says it enforces, defeated by the probe underneath it.
# rclone marks directories with a trailing '/', which is stripped before comparing (the shared
# branch's `ls -1` already yields bare names).
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
catalog_manifest() { store_read "$(manifest_path "$1")" 2>/dev/null; }
catalog_latest() {
    _cl_raw=$(store_read "$(latest_path)" 2>/dev/null) || return $?
    printf '%s' "${_cl_raw}" | tr -d '[:space:]'
}

# The id the layout's path builders assume when no explicit one is passed: THE backup this
# process is working on. Each operation sets CURRENT_ID exactly once — backup/list at
# dispatch (backup_<TIMESTAMP>), restore in load_manifest once 'latest' is resolved and the
# manifest is read — and this layer never asks which operation is running.
#
# It used to branch on ${COMMAND}, which put subcommand knowledge in the lowest layer of the
# file: pure path arithmetic that ~40 call sites depend on. Only comp_path is guarded by
# _require_id, so a future default-id caller in the wrong mode would have silently resolved
# to a freshly minted backup_<now> that exists nowhere. One variable, set once, removes the
# question. Empty until set, which _require_id turns into a loud failure rather than a
# silent read one level too high.
backup_id_default() { echo "${CURRENT_ID}"; }

################################################################################
# 5. Kubernetes primitives (S3 client execs, waiters, locks)
################################################################################

# The orchestrator has no S3 client of its own; it borrows the pmm-backup rclone sidecar
# (rclone + IRSA + RCLONE_CONFIG_S3_* all live there). Find a PMM pod that has it.
#
# Resolves into S3_CLIENT_POD (the cache) and echoes it. CALL IT AS A STATEMENT and read
# ${S3_CLIENT_POD}: `pod=$(pick_s3_client_pod)` runs it in a SUBSHELL, so the cache
# assignment dies with that subshell — which is how every S3 op came to re-run full
# discovery (one `get pods` plus one `get pod` per PMM pod) while the stale-cache retries
# reset a variable that had never been set.
#
# That alone is not enough, because the store_* wrappers call s3_rclone inside $(...) too.
# So each operation RESOLVES ONCE up front, in the main shell (see resolve_s3_client_pod):
# every later subshell then inherits a populated S3_CLIENT_POD and returns here immediately
# without touching the API server. On restore the pod is assigned directly by
# create_s3_client_pod and pinned.
pick_s3_client_pod() {
    if [ -n "${S3_CLIENT_POD}" ]; then echo "${S3_CLIENT_POD}"; return 0; fi
    local pods p
    pods=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for p in ${pods}; do
        if kubectl get pod -n "${NAMESPACE}" "${p}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q "pmm-backup"; then
            S3_CLIENT_POD="${p}"; echo "${p}"; return 0
        fi
    done
    return 1
}

# Resolve the client pod ONCE per operation, in the main shell, so that every later call —
# including the many that run inside command substitutions — inherits it instead of
# re-discovering. Best-effort: callers that genuinely need a client pod report their own
# error, and on restore the dedicated pod is already set and pinned.
resolve_s3_client_pod() {
    [ "${S3_ENABLED}" = "true" ] || return 0
    [ -n "${S3_CLIENT_POD}" ] && return 0
    pick_s3_client_pod >/dev/null 2>&1 || true
    return 0
}

# Drop the cached client pod so the next call re-resolves. Returns non-zero — meaning
# "do not retry" — when the pod is PINNED.
#
# This guard is essential on the restore path: create_s3_client_pod starts a dedicated
# rclone pod precisely because the pmm-backup sidecars ride on the PMM pods that the restore
# is about to scale to 0, and that pod is not label-discoverable. Without the guard, one
# benign non-zero rclone exit (a missing object, an exec blip) would clear the cache and
# re-bind a PMM pod — which scale_down_pmm then deletes, breaking every later S3 read with
# PMM already at 0 replicas. Note load_manifest and restore_encryption_key call store_read
# with a REDIRECTION rather than $(...), so they run in the main shell and such a swap
# would persist for the whole run.
invalidate_s3_client_pod() {
    [ "${S3_CLIENT_POD_PINNED}" = "true" ] && return 1
    S3_CLIENT_POD=""
    return 0
}

# rclone read ops (cat/lsf/size) inside the pmm-backup sidecar.
s3_rclone() {
    pick_s3_client_pod >/dev/null || return 1
    if timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- rclone "$@"; then
        return 0
    fi
    # A cached pod can go stale, so reads carry the same one-shot re-resolve the destructive
    # primitives have: a retention sweep runs for minutes and Karpenter replaces PMM pods
    # routinely, and without this a dead client pod would fail every remaining read for the
    # rest of the run. Safe here precisely because these ops carry no stdin — unlike
    # s3_rclone_rcat, whose input is already consumed. A pinned (restore) pod is never
    # swapped: there the first failure is the answer.
    invalidate_s3_client_pod || return 1
    pick_s3_client_pod >/dev/null || return 1
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- rclone "$@"
}

# Pipe stdin into an object via rclone rcat (used to write manifest.json / latest pointer).
# Deliberately NO stale-pod retry: this streams stdin, which is consumed by the first
# attempt and cannot be replayed — a retry would upload a truncated object.
s3_rclone_rcat() {
    pick_s3_client_pod >/dev/null || return 1
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- \
        rclone rcat --s3-no-check-bucket "$1"
}

# DESTRUCTIVE: recursively delete an S3 prefix. Separate from s3_rclone(), which is
# documented read-only — widening that helper to cover deletes would make every future call
# site a potential data-loss path. KUBECTL_EXEC_TIMEOUT because purging one backup means
# deleting thousands of VictoriaMetrics objects.
#
# Expect a benign, alarming-looking line in the log on every purge:
#   ERROR : ... Failed to read versioning status, assuming unversioned: ... AccessDenied
# rclone probes bucket versioning to pick a delete strategy; the backup credentials
# intentionally do not grant s3:GetBucketVersioning, so the probe 403s, rclone falls back to
# unversioned deletes and the purge succeeds. Callers send both streams to the log file, so
# it never reaches the operator's console — do not "fix" it by widening the IAM policy.
# Single-object delete, as a primitive next to purge so both carry the stale-client-pod
# retry. store_delete_object calls this rather than exec'ing kubectl itself.
s3_rclone_deletefile() {
    pick_s3_client_pod >/dev/null || return 1
    if timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- \
        rclone deletefile --s3-no-check-bucket "$1"; then
        return 0
    fi
    invalidate_s3_client_pod || return 1
    pick_s3_client_pod >/dev/null || return 1
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- \
        rclone deletefile --s3-no-check-bucket "$1"
}

s3_rclone_purge() {
    pick_s3_client_pod >/dev/null || return 1
    if timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- \
        rclone purge --s3-no-check-bucket "$1"; then
        return 0
    fi
    # pick_s3_client_pod caches the pod name and never revalidates it. The sweep is the first
    # caller to make many sequential execs over many minutes, so it is the first that can
    # outlive its client pod (Karpenter replaces PMM pods routinely). A stale cache would fail
    # every remaining purge with "pod not found" and retention would silently never advance.
    invalidate_s3_client_pod || return 1
    pick_s3_client_pod >/dev/null || return 1
    timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${S3_CLIENT_POD}" -c pmm-backup -- \
        rclone purge --s3-no-check-bucket "$1"
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
        count=$(printf '%s\n' "${out}" | grep -c '[^[:space:]]')
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
# Lock management — per-component mkdir locks shared by BOTH operations (same names
# as always: ${BACKUP_DIR}/.backup_<component>.lock), so a backup and a restore of
# the same component exclude each other, while different components run concurrently.
################################################################################

acquire_component_lock() {
    local component=$1
    # NOTE: busybox ash expands every initializer of one 'local' line BEFORE assigning,
    # so ${component} must not be referenced on the same line it is set — use ${1}.
    local lock_dir="${BACKUP_DIR}/.backup_${1}.lock"

    # mkdir is atomic: only one process can succeed; all others get EEXIST
    if mkdir "${lock_dir}" 2>/dev/null; then
        echo $$ > "${lock_dir}/pid"
        log "INFO" "Acquired ${component} lock (PID $$)"
        return 0
    fi

    # Lock dir exists -- check if the holder is still alive
    local existing_pid
    existing_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
    if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
        log "ERROR" "Another backup/restore holds the ${component} lock (PID: ${existing_pid}); aborting"
        exit 1
    fi

    # Holder is gone -- stale lock
    log "WARN" "Stale ${component} lock found (PID: ${existing_pid}), removing"
    rm -rf "${lock_dir}"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
        log "ERROR" "Cannot acquire ${component} lock (lost race to another process)"
        exit 1
    fi
    echo $$ > "${lock_dir}/pid"
    log "INFO" "Acquired ${component} lock (PID $$, stale recovered)"
}

release_component_lock() {
    local lock_dir="${BACKUP_DIR}/.backup_${1}.lock"
    # Only the owner may release: the EXIT trap is installed before acquire_locks, so a run
    # that aborts because ANOTHER process holds the lock must not delete that live lock.
    [ "$(cat "${lock_dir}/pid" 2>/dev/null || echo "")" = "$$" ] && rm -rf "${lock_dir}" 2>/dev/null || true
}

# Acquire/release every lock in LOCK_COMPONENTS. Each operation builds its own list —
# in alphabetical order, to prevent deadlocks between concurrent runs — before calling
# these (see cmd_backup / cmd_restore); the traps re-use the same list.
acquire_locks() {
    local _c
    for _c in ${LOCK_COMPONENTS}; do acquire_component_lock "${_c}"; done
    return 0
}

release_locks() {
    local _c
    for _c in ${LOCK_COMPONENTS}; do release_component_lock "${_c}"; done
    return 0
}

################################################################################
# 6. Catalog — manifest write/read, id ownership/age, list
################################################################################

# Which namespace produced a backup, read from its own manifest, or empty when that cannot
# be established. Every manifest records `namespace` (see write_manifest), so ownership is a
# fact recorded in the data rather than something the sweep has to infer from configuration.
#
# This exists because installs can legitimately SHARE a prefix: the chart documents running
# several instances against one bucket and pointing a DR target at production's bucket on
# purpose, and an operator can always point --s3-prefix at another install's root. (The
# default is now <namespace>/pmm-ha, which makes an ACCIDENTAL collision unlikely — but a
# deliberate or mis-set one still reaches here.) Age-based pruning cannot tell whose backup an id
# is, so on a shared prefix one install would delete another's — irreversibly, on a bucket
# with no versioning. Documenting "make the prefix unique" does not protect an operator who
# never reads values.yaml; refusing to delete another namespace's backup does.
backup_id_owner() {
    _bio_json=$(store_read "$(manifest_path "$1")" 2>/dev/null) || return 1
    [ -n "${_bio_json}" ] || return 1
    printf '%s' "${_bio_json}" | jq -r '.namespace // empty' 2>/dev/null
}

# Epoch seconds for the timestamp embedded in a backup id (backup_YYYYMMDD-HHMMSS), or
# empty when it cannot be parsed. Parsing the NAME rather than reading S3 object mtimes is
# deliberate: the name is the backup's identity and never changes, while mtimes shift on
# any re-upload or copy — and it makes retention testable without waiting days, since a
# backdated id can simply be created.
#
# Two implementations because both shells are supported: busybox date takes an explicit
# input format via -D, GNU date has no -D but accepts an ISO-ish string. An id that
# neither can parse yields empty, and callers must then SKIP it rather than guess.
#
# The shape is anchored FIRST, before either date call, for two reasons. busybox
# `date -D "%Y%m%d-%H%M%S"` happily parses "20260821-103000-preupgrade" (trailing garbage is
# ignored) while GNU date rejects it — so without this the same bucket gets opposite
# retention decisions depending on which image runs the sweep, and on busybox a
# deliberately-named id like backup_<ts>-preupgrade would be DELETED despite the documented
# promise that unparseable ids are only ever skipped. --backup-id permits any
# [A-Za-z0-9_-] string, so suffixed ids are a realistic bucket resident, not a hypothetical.
backup_id_epoch() {
    _bid_ts="${1#backup_}"
    case "${_bid_ts}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    date -D "%Y%m%d-%H%M%S" -d "${_bid_ts}" +%s 2>/dev/null && return 0
    _bid_iso=$(echo "${_bid_ts}" | sed 's/^\(....\)\(..\)\(..\)-\(..\)\(..\)\(..\)$/\1-\2-\3 \4:\5:\6/')
    date -d "${_bid_iso}" +%s 2>/dev/null
}

# Build the per-run manifest and write it (+ a 'latest' pointer) next to the PMM/VM data.
# Best-effort: never aborts the run. $1=overall status (complete|partial), $2=encryption status.
write_manifest() {
    _overall="$1"
    _enc_status="${2:-skipped}"
    _created=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # Assemble the components object (only the components that were selected this run).
    # Built with jq (a hard preflight requirement): values are properly escaped, and the
    # scripts no longer depend on any hand-maintained indentation contract.
    _comps='{}'
    if [ "${BACKUP_POSTGRESQL}" = "true" ]; then
        _st="failed"; [ "${PG_BACKUP_SUCCESS}" = "true" ] && _st="success"
        _comps=$(printf '%s' "${_comps}" | jq \
            --arg st "${_st}" --arg dbs "${PG_DUMP_DBS}" --arg loc "${PG_BACKUP_LOCATION}" \
            '. + {postgresql: {status: $st, engine: "pg_dump", databases: $dbs, location: $loc,
                  restore: "(per db) pg_restore --clean --if-exists -U postgres -d <db> <db>.dump"}}')
    fi
    if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
        _st="failed"; [ "${CH_BACKUP_SUCCESS}" = "true" ] && _st="success"
        local _ch_restore
        if [ "${BACKUP_TARGET}" = "shared" ]; then
            _ch_restore="(in CH pod) tar -xzf ${CH_BACKUP_LOCATION} -C /var/lib/clickhouse/backup && clickhouse-backup restore ${CH_BACKUP_NAME}"
        else
            _ch_restore="clickhouse-backup restore_remote ${CH_BACKUP_NAME}"
        fi
        _comps=$(printf '%s' "${_comps}" | jq \
            --arg st "${_st}" --arg name "${CH_BACKUP_NAME}" --arg loc "${CH_BACKUP_LOCATION}" --arg restore "${_ch_restore}" \
            '. + {clickhouse: {status: $st, engine: "clickhouse-backup", name: $name, location: $loc, restore: $restore}}')
    fi
    if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
        _st="failed"; [ "${VM_BACKUP_SUCCESS}" = "true" ] && _st="success"
        _comps=$(printf '%s' "${_comps}" | jq \
            --arg st "${_st}" --arg objs "${VM_BACKUP_OBJECTS}" \
            '. + {victoriametrics: {status: $st, engine: "vmbackup",
                  objects: ($objs | split(" ") | map(select(length > 0)))}}')
    fi
    if [ "${BACKUP_PMM_SERVER}" = "true" ]; then
        _st="failed"; [ "${PMM_BACKUP_SUCCESS}" = "true" ] && _st="success"
        _comps=$(printf '%s' "${_comps}" | jq \
            --arg st "${_st}" --arg objs "${PMM_BACKUP_OBJECTS}" \
            '. + {"pmm-server": {status: $st, engine: "tar+rclone",
                  objects: ($objs | split(" ") | map(select(length > 0)))}}')
    fi
    if [ "${BACKUP_POSTGRESQL}" = "true" ] && [ "${BACKUP_ENCRYPTION_KEY}" = "true" ]; then
        _comps=$(printf '%s' "${_comps}" | jq \
            --arg st "${_enc_status}" --arg loc "${ENCRYPTION_KEY_LOCATION}" \
            '. + {encryption: {status: $st, location: $loc}}')
    fi

    # This run's own manifest (merge with any concurrent run's happens below, under lock).
    _manifest=$(jq -n \
        --arg backup_id "$(backup_id_default)" --arg ts "${TIMESTAMP}" --arg created "${_created}" \
        --arg ns "${NAMESPACE}" --arg target "${BACKUP_TARGET}" --arg bucket "${S3_BUCKET}" \
        --arg prefix "${S3_PREFIX}" --arg status "${_overall}" --argjson comps "${_comps}" \
        '{backup_id: $backup_id, timestamp: $ts, created: $created, namespace: $ns,
          target: $target, bucket: $bucket, prefix: $prefix, status: $status, components: $comps}')

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[Manifest] [DRY RUN] Would write $(manifest_display) (+ latest pointer)"
        return 0
    fi

    # Concurrent-mode merge: with --backup-id, one process per component (the documented
    # workflow) each writes the SAME manifests/<id>.json — without a merge the last
    # finisher erases the other components from the index and restore can't find them.
    # Carry over component entries from an existing manifest that this run does not own;
    # writers share the backup-tools pod, so a local mkdir-lock serializes read-merge-write.
    _mlock="${BACKUP_DIR}/.manifest_backup_${TIMESTAMP}.lock"
    _mlock_held=false
    _i=0
    while ! mkdir "${_mlock}" 2>/dev/null; do
        _i=$((_i + 1))
        if [ ${_i} -ge 60 ]; then log "WARN" "[Manifest] Manifest lock busy for 60s; writing without merge protection"; break; fi
        sleep 1
    done
    [ ${_i} -lt 60 ] && _mlock_held=true

    # The read's STATUS decides what an empty result means. `|| true` conflated "could not
    # read it" with "there is no manifest yet", so a single timed-out rclone cat (a PMM pod
    # being replaced mid-run is enough) made the LAST finisher of the documented concurrent
    # workflow overwrite the shared manifest with only its own component — erasing its
    # siblings from the restore index while their data sat in the bucket, unreferenced.
    # A failed read is only forgiven when absence can be POSITIVELY established, the same
    # rule the delete path uses; otherwise this run refuses to write rather than clobber.
    _read_rc=0
    _existing=$(store_read "$(manifest_path)" 2>/dev/null) || _read_rc=$?
    if [ "${_read_rc}" -ne 0 ]; then
        if store_absent "$(manifest_path)"; then
            _existing=""   # genuinely not there yet: this is the first writer for this id
        else
            log "ERROR" "[Manifest] Could not read the existing $(manifest_display) (rc ${_read_rc}), and could not prove it is absent"
            log "ERROR" "[Manifest]   Refusing to overwrite it: a concurrent component run's entries would be erased from the restore index."
            [ "${_mlock_held}" = "true" ] && rmdir "${_mlock}" 2>/dev/null || true
            return 1
        fi
    fi
    if [ -n "${_existing}" ]; then
        # Existing components lose to this run's on conflict; any failed component in the
        # merged set makes the whole backup partial.
        _merged=$(jq -n --argjson new "${_manifest}" --argjson old "${_existing}" '
            $new
            | .components = (($old.components // {}) + $new.components)
            | .status = (if $new.status == "partial"
                            or ([.components[] | .status // ""] | index("failed"))
                         then "partial" else "complete" end)' 2>/dev/null || true)
        if [ -n "${_merged}" ]; then
            [ "${_merged}" != "${_manifest}" ] && log "INFO" "[Manifest] Merged component entries from a concurrent run of this backup id"
            _manifest="${_merged}"
        else
            log "WARN" "[Manifest] Existing manifest is not valid JSON; overwriting it"
        fi
    fi

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
        [ "${_mlock_held}" = "true" ] && rmdir "${_mlock}" 2>/dev/null || true
        return 1
    fi
    [ "${_mlock_held}" = "true" ] && rmdir "${_mlock}" 2>/dev/null || true
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
        [ "${S3_ENABLED}" = "true" ] && log "ERROR" "  Looked at $(manifest_display) (need a reachable pmm-backup sidecar + --s3-bucket)"
        [ "${S3_ENABLED}" = "true" ] || log "ERROR" "  Looked at $(manifest_path)"
        return 1
    fi

    # A corrupt/truncated manifest must be a hard error, not a fleet of silently-empty
    # MF_* fields that read as "nothing to restore".
    if ! jq -e . "${MANIFEST_FILE}" >/dev/null 2>&1; then
        log "ERROR" "Manifest for ${BACKUP_NAME} is not valid JSON (corrupt or truncated); refusing to plan a restore from it"
        return 1
    fi

    MF_STATUS=$(manifest_top status); MF_TARGET=$(manifest_top target); MF_CREATED=$(manifest_top created)
    MF_PG_STATUS=$(mf_field postgresql status); MF_PG_DBS=$(mf_field postgresql databases)
    MF_CH_STATUS=$(mf_field clickhouse status);      MF_CH_NAME=$(mf_field clickhouse name)
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

    log "INFO" "Backup ${BACKUP_NAME}: status=${MF_STATUS:-?} target=${MF_TARGET:-?} created=${MF_CREATED:-?}"
    if [ -n "${MF_TARGET}" ] && [ "${MF_TARGET}" != "${BACKUP_TARGET}" ]; then
        log "WARN" "Manifest target '${MF_TARGET}' != --target '${BACKUP_TARGET}'. Restore uses --target ${BACKUP_TARGET}; pass --target ${MF_TARGET} if that's wrong."
    fi
    return 0
}

# 'list' command: enumerate backups, or show one backup's per-component summary + files.
cmd_list() {
    _want="${1:-}"
    ensure_jq || { echo "Error: jq is required for 'list' (Alpine: apk add jq; Debian: apt-get install jq)"; exit 1; }
    # (--target s3 without a bucket is already rejected for every subcommand at dispatch.)

    # Accept a bare timestamp as well as backup_<timestamp>, exactly as --backup-id does on
    # the restore path. Without this the two subcommands disagreed about what a backup id
    # is: `restore --backup-id 20260610-124515` worked while `list 20260610-124515` said
    # there was no such backup.
    case "${_want}" in
        ''|backup_*) ;;
        *) _want="backup_${_want}" ;;
    esac

    resolve_s3_client_pod

    # One implementation for both targets. It used to be two, and they had drifted: the
    # shared-mode branch printed a bare `ls` of directory names while s3 printed a
    # status/components table. Same catalog, same output now — the only difference is the
    # root, which the read helpers absorb.
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
            echo "  Check --s3-bucket/--s3-prefix, credentials, and that a pmm-backup sidecar is reachable."
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

preflight_checks() {   # <backup|restore>
    local _pf_mode="${1:-backup}"
    log "INFO" "Running pre-flight checks..."
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
        log "ERROR" "jq is required (manifest generation/merging + secret export) but is not available"
        log "ERROR" "Install jq in the backup image (Alpine: apk add jq; Debian: apt-get install jq)"
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
        if [ "${BACKUP_POSTGRESQL}" = "true" ]; then
            if ! kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PG_PRIMARY}" --no-headers 2>/dev/null | grep -q .; then
                log "WARN" "[PostgreSQL] No primary pod found (label: ${LABEL_PG_PRIMARY})"
                checks_passed=false
            fi
        fi

        if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
            if ! kubectl get pods -n "${NAMESPACE}" -l "${LABEL_CH_POD}" --no-headers 2>/dev/null | grep -q .; then
                log "WARN" "[ClickHouse] No pods found (label: ${LABEL_CH_POD})"
                checks_passed=false
            fi
        fi

        if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
            if ! kubectl get pods -n "${NAMESPACE}" -l "${LABEL_VM_STORAGE}" --no-headers 2>/dev/null | grep -q .; then
                log "WARN" "[VictoriaMetrics] No vmstorage pods found (label: ${LABEL_VM_STORAGE})"
                checks_passed=false
            fi
        fi

        if [ "${BACKUP_PMM_SERVER}" = "true" ]; then
            if ! kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" --no-headers 2>/dev/null | grep -q .; then
                log "WARN" "[PMMServer] No PMM server pods found (label: ${LABEL_PMM_SERVER})"
                checks_passed=false
            fi
        fi
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
    log "INFO" "[PostgreSQL] Databases: $(echo ${dbs} | tr '\n' ' ')"

    if [ "${DRY_RUN}" = "true" ]; then
        local db
        for db in ${dbs}; do
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                log "INFO" "[PostgreSQL] [DRY RUN] pg_dump -Fc ${db} | rclone rcat $(comp_display postgresql)/${db}.dump"
            else
                log "INFO" "[PostgreSQL] [DRY RUN] pg_dump -Fc ${db} > $(comp_inpod postgresql)/${db}.dump"
            fi
        done
        PG_BACKUP_SUCCESS=true
        return 0
    fi

    local total_bytes=0 ok_count=0 db_count=0 dumped="" db size_b
    for db in ${dbs}; do
        db_count=$((db_count + 1)); size_b=0
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            local s3_uri="$(comp_path postgresql)/${db}.dump"
            local pmm_pod; pick_s3_client_pod >/dev/null || { log "ERROR" "[PostgreSQL] No pmm-backup sidecar to stream the dump to S3"; return 1; }
            pmm_pod="${S3_CLIENT_POD}"
            log "INFO" "[PostgreSQL] Dumping ${db} -> S3..."
            # pg_dump (custom format) in the PG pod, piped to rclone rcat in the sidecar.
            # POSIX sh has no pipefail, so the if-condition only sees rclone's status:
            # capture pg_dump's exit through a rc file so a dump that dies mid-stream
            # cannot be masked by a successful upload of the truncated bytes.
            local dump_rc_file="/tmp/.pgdump_rc_$$" dump_rc
            rm -f "${dump_rc_file}" 2>/dev/null || true
            if { timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
                    pg_dump -U postgres -Fc -d "${db}" 2>>"${LOG_FILE}"
                 echo $? > "${dump_rc_file}"; } \
                | timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${pmm_pod}" -c pmm-backup -- \
                  rclone rcat --s3-no-check-bucket "${s3_uri}" >>"${LOG_FILE}" 2>&1; then
                dump_rc=$(cat "${dump_rc_file}" 2>/dev/null || echo 1); rm -f "${dump_rc_file}" 2>/dev/null || true
                if [ "${dump_rc}" != "0" ]; then
                    log "ERROR" "[PostgreSQL] pg_dump failed for ${db} (exit ${dump_rc}); removing truncated S3 object"
                    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pmm_pod}" -c pmm-backup -- \
                        rclone deletefile --s3-no-check-bucket "${s3_uri}" >>"${LOG_FILE}" 2>&1 || true
                    continue
                fi
                size_b=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pmm_pod}" -c pmm-backup -- \
                    rclone size --s3-no-check-bucket --json "${s3_uri}" 2>/dev/null | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p')
            else
                rm -f "${dump_rc_file}" 2>/dev/null || true
                log "ERROR" "[PostgreSQL] Dump/upload failed for ${db}"; continue
            fi
        else
            local dest_dir="$(comp_path postgresql)"; mkdir -p "${dest_dir}"
            local dump_file="${dest_dir}/${db}.dump"
            log "INFO" "[PostgreSQL] Dumping ${db} -> ${dump_file}..."
            # pg_dump in the PG pod streamed onto the central volume (orchestrator's mount).
            if timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pg_pod}" -c database -- \
                pg_dump -U postgres -Fc -d "${db}" 2>>"${LOG_FILE}" > "${dump_file}"; then
                size_b=$(wc -c < "${dump_file}" 2>/dev/null | tr -d ' ')
            else
                log "ERROR" "[PostgreSQL] Dump failed for ${db}"; rm -f "${dump_file}"; continue
            fi
        fi
        : "${size_b:=0}"
        if ! [ "${size_b}" -gt 0 ] 2>/dev/null; then
            log "ERROR" "[PostgreSQL] ${db}: dump empty/missing at destination — treating as failed"; continue
        fi
        log "INFO" "[PostgreSQL] ✓ ${db} dumped ($(human_bytes ${size_b}))"
        total_bytes=$((total_bytes + size_b)); ok_count=$((ok_count + 1)); dumped="${dumped} ${db}"
    done

    if [ ${ok_count} -eq 0 ]; then log "ERROR" "[PostgreSQL] ✗ All database dumps failed"; return 1; fi

    # Record metadata for the manifest/summary regardless of full/partial.
    PG_DUMP_DBS="$(echo ${dumped} | xargs)"
    PG_BACKUP_SIZE_BYTES="${total_bytes}"
    PG_BACKUP_SIZE="$(human_bytes ${total_bytes})"
    PG_BACKUP_DURATION="$(($(date +%s) - start_time))"
    if [ "${BACKUP_TARGET}" = "s3" ]; then
        PG_BACKUP_LOCATION="$(comp_display postgresql)/"
    else
        PG_BACKUP_LOCATION="$(comp_inpod postgresql)/"
    fi

    # All-or-nothing: a partial dump set can't restore the full cluster, so only mark success
    # when every database dumped — consistent with ClickHouse/VM/PMM. cmd_backup then records a
    # partial run as failed (the run returns 0 so the other components still get their summary).
    if [ ${ok_count} -lt ${db_count} ]; then
        log "WARN" "[PostgreSQL] Partial: ${ok_count}/${db_count} databases dumped — marking failed (a backup must be complete to restore safely)"
    else
        PG_BACKUP_SUCCESS=true
        log "INFO" "[PostgreSQL] ✓ Completed: ${ok_count} db(s), ${PG_BACKUP_SIZE}, ${PG_BACKUP_DURATION}s"
    fi
    return 0
}

################################################################################
# ClickHouse Backup - Using clickhouse-backup API (system.backup_actions)
################################################################################

backup_clickhouse() {
    log "INFO" "[ClickHouse] === Starting Backup ==="
    
    # Shared mode only: the tarball's destination directory, which this process creates.
    # In s3 mode clickhouse-backup uploads to the bucket itself and there is nothing local
    # to make — mkdir'ing comp_path there produced a directory literally named "s3:<bucket>/..."
    # on the container's writable layer.
    local ch_backup_dir=""
    if [ "${S3_ENABLED}" != "true" ]; then
        ch_backup_dir="$(comp_path clickhouse)"
        [ "${DRY_RUN}" != "true" ] && mkdir -p "${ch_backup_dir}"
    fi
    
    # Find a ClickHouse pod to run client commands
    local ch_pod=$(kubectl get pods -n "${NAMESPACE}" \
        -l "${LABEL_CH_POD}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "${ch_pod}" ]; then
        log "ERROR" "[ClickHouse] No pods found in namespace: ${NAMESPACE}"
        log "ERROR" "[ClickHouse] Check if operator is running: kubectl get pods -n ${NAMESPACE}"
        return 1
    fi
    
    log "INFO" "[ClickHouse] Using pod: ${ch_pod}"
    
    # Get ClickHouse credentials from secret
    # Note: Alpine uses 'base64 -d' not 'base64 --decode'
    # Fetch first, THEN decode: in a `kubectl | base64` pipeline the || fallback keys off
    # base64's status (0 even on empty stdin), so a failed kubectl silently yielded ""
    # instead of the intended default and misdiagnosed as a missing backup sidecar.
    local ch_user_b64 ch_pass_b64 ch_user ch_pass
    ch_user_b64=$(kubectl get secret "${CH_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.PMM_CLICKHOUSE_USER}' 2>>"${LOG_FILE}" || true)
    ch_pass_b64=$(kubectl get secret "${CH_SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.PMM_CLICKHOUSE_PASSWORD}' 2>>"${LOG_FILE}" || true)
    if [ -n "${ch_user_b64}" ]; then
        ch_user=$(printf '%s' "${ch_user_b64}" | base64 -d 2>/dev/null || echo "chuser")
    else
        log "WARN" "[ClickHouse] Could not read PMM_CLICKHOUSE_USER from secret ${CH_SECRET_NAME}; using default 'chuser'"
        ch_user="chuser"
    fi
    if [ -n "${ch_pass_b64}" ]; then
        ch_pass=$(printf '%s' "${ch_pass_b64}" | base64 -d 2>/dev/null || echo "")
    else
        log "WARN" "[ClickHouse] Could not read PMM_CLICKHOUSE_PASSWORD from secret ${CH_SECRET_NAME}; using empty password"
        ch_pass=""
    fi

    # Credentials are never logged. ch_query() centralizes the exec + client + creds + timeout
    # boilerplate; it reads ch_pod/ch_user/ch_pass from this function's scope (sh dynamic scoping).
    # The password is fed through STDIN into CLICKHOUSE_PASSWORD inside the pod — never on the
    # clickhouse-client argv — so it can't leak via `ps` in the CH pod or the apiserver's exec
    # audit log (ch_query runs dozens of times per backup). The query text is not secret.
    ch_query() {
        printf '%s' "${ch_pass}" | timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${ch_pod}" -c clickhouse -- \
            sh -c 'CLICKHOUSE_PASSWORD=$(cat); export CLICKHOUSE_PASSWORD; exec clickhouse-client --user="$1" --query="$2"' sh "${ch_user}" "$1"
    }

    # Check if system.backup_actions table exists (indicates clickhouse-backup sidecar is running)
    local has_backup_api=false
    # clickhouse-client requires --option=value format with equals sign
    # Split declaration from assignment: `local x=$(...)` would make $? reflect
    # `local` (always 0), masking the command's real exit code. The && / || guards
    # also keep a failed exec from tripping `set -e`.
    local table_check_output table_check_exit
    table_check_output=$(ch_query "SELECT count() FROM system.tables WHERE database='system' AND name='backup_actions'" 2>&1) && table_check_exit=0 || table_check_exit=$?
    
    if [ "${VERBOSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Table check output: ${table_check_output}"
        log "INFO" "[ClickHouse] Table check exit code: ${table_check_exit}"
    fi
    
    if echo "${table_check_output}" | grep -q "^1$"; then
        has_backup_api=true
        log "INFO" "[ClickHouse] clickhouse-backup API detected (system.backup_actions table exists)"
    elif [ "${VERBOSE}" = "true" ]; then
        log "WARN" "[ClickHouse] Table check result: ${table_check_output}"
    fi
    
    if [ "${has_backup_api}" != "true" ]; then
        log "ERROR" "[ClickHouse] clickhouse-backup API not available (system.backup_actions table not found)"
        log "ERROR" "[ClickHouse] The clickhouse-backup sidecar container is not running"
        log "INFO" "[ClickHouse] To enable, add clickhouse-backup sidecar to ClickHouse pods in Helm chart"
        log "INFO" "[ClickHouse] See: https://github.com/Altinity/clickhouse-backup/blob/master/Examples.md#how-to-use-clickhouse-backup-in-kubernetes"
        return 1
    fi

    # Named backup_<ts>, matching every other component's directory name. clickhouse-backup
    # creates <S3_PATH>/<name>/, and the chart points S3_PATH at <root>/clickhouse — so the
    # result lands at <root>/clickhouse/backup_<ts>/, the same shape as
    # <root>/postgresql/backup_<ts>/. The old pmm_backup_ prefix is what made ClickHouse look
    # like a different kind of thing when browsing the bucket.
    #
    # Side effect worth knowing: because ClickHouse now sits at a component path the generic
    # retention sweep understands, that sweep prunes it by age along with everything else. It
    # does NOT make ClickHouse retention fully correct — see the incremental-chain hazard in
    # Phase 3 — but ClickHouse is no longer pruned solely by its own count-based keepRemote.
    local backup_name="backup_${TIMESTAMP}"

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[ClickHouse] [DRY RUN] Commands (pod: ${ch_pod}, backup: ${backup_name}, type: ${CH_BACKUP_TYPE}):"
        log "INFO" "[ClickHouse] [DRY RUN]   \$ kubectl exec -n ${NAMESPACE} ${ch_pod} -c clickhouse -- \\"
        log "INFO" "[ClickHouse] [DRY RUN]       clickhouse-client --user=*** --password=*** \\"
        log "INFO" "[ClickHouse] [DRY RUN]       --query=\"INSERT INTO system.backup_actions(command) VALUES('create ${backup_name}')\""
        log "INFO" "[ClickHouse] [DRY RUN]   (poll system.backup_actions until status=success, timeout 300s)"
        if [ "${S3_ENABLED}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN]   \$ kubectl exec ... clickhouse-client ... \\"
            log "INFO" "[ClickHouse] [DRY RUN]       --query=\"INSERT INTO system.backup_actions(command) VALUES('upload ${backup_name}')\""
            log "INFO" "[ClickHouse] [DRY RUN]   (poll upload status, timeout 600s)"
            log "INFO" "[ClickHouse] [DRY RUN]   \$ kubectl exec ... clickhouse-client ... \\"
            log "INFO" "[ClickHouse] [DRY RUN]       --query=\"INSERT INTO system.backup_actions(command) VALUES('delete local ${backup_name}')\""
        fi
        CH_BACKUP_SUCCESS=true
        CH_BACKUP_NAME="${backup_name}"
        return 0
    fi

    # Use clickhouse-backup API (preferred - Altinity recommended approach)
    log "INFO" "[ClickHouse] Using clickhouse-backup API via system.backup_actions"

    local start_time=$(date +%s)

    # Step 1: Create backup via API.
    # Incremental note (verified against clickhouse-backup 2.8.0 CLI): for regular
    # (non-embedded) backups the diff happens at UPLOAD time — 'create' is always a full
    # local hardlink snapshot, and its --diff-from-remote flag only applies to
    # embedded/object-disk backups. Flags must also precede the positional <backup_name>.
    # So: plain 'create <name>' here; '--diff-from-remote' goes on the upload command.
    local ch_create_cmd="create ${backup_name}"
    # NB: no stray double spaces. The command string is the key used to poll
    # system.backup_actions for this run's status, so it has to be byte-identical between the
    # INSERT and the SELECT — an extra space from an empty variable would make the poll match
    # nothing and the step time out despite the upload succeeding.
    #
    # Where ClickHouse data goes is decided by the SIDECAR's own S3_BUCKET/S3_PATH, not by
    # this script. Those carry the documented per-component overrides
    # (clickhouse.backup.s3.bucket / .path), and by default the chart points them at
    # <root>/clickhouse so ClickHouse lands beside every other component.
    #
    # So: ask the sidecar where it will write, and only redirect when it is about to write
    # somewhere this run does not own. Guessing from "was --s3-prefix passed?" was wrong —
    # the CronJob always passes it, so a scheduled run silently overrode a deliberate
    # per-component override while a manual run honoured it: the same install writing
    # ClickHouse to two different roots depending on how it was invoked.
    local ch_cfg_bucket="" ch_cfg_path="" ch_want_path="$(clickhouse_remote_key)"
    local ch_upload_cmd="upload"
    if [ "${S3_ENABLED}" = "true" ]; then
        ch_cfg_bucket=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            printenv S3_BUCKET 2>/dev/null | tr -d '\r' || true)
        ch_cfg_path=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            printenv S3_PATH 2>/dev/null | tr -d '\r' || true)
        if [ -z "${ch_cfg_path}" ]; then
            # Cannot tell where it would write, so state the intended destination explicitly
            # rather than hoping the sidecar agrees.
            log "WARN" "[ClickHouse] Could not read the sidecar's S3_PATH; pinning the upload to ${ch_want_path}"
            ch_upload_cmd="${ch_upload_cmd} --env S3_BUCKET=${S3_BUCKET} --env S3_PATH=${ch_want_path}"
        elif [ "${ch_cfg_bucket}" = "${S3_BUCKET}" ] && [ "${ch_cfg_path}" = "${ch_want_path}" ]; then
            : # already writing where this run expects — no override needed
        else
            # The sidecar points somewhere else. That is either a deliberate per-component
            # override or a pod that has not rolled since the prefix changed, and this script
            # cannot tell which — so honour the sidecar (never silently discard configuration)
            # and make the consequence explicit instead of guessing.
            log "WARN" "[ClickHouse] Sidecar writes to s3://${ch_cfg_bucket}/${ch_cfg_path}, not this run's ${S3_BUCKET}/${ch_want_path}"
            log "WARN" "[ClickHouse]   Honouring the sidecar. If that is clickhouse.backup.s3.bucket/.path, note that retention and restore follow THIS run's root, so ClickHouse there is neither pruned nor restored automatically. If it is a stale pod, re-run after the ClickHouse pods have rolled."
            ch_want_path="${ch_cfg_path}"
            # Record the REAL destination so it is not lost: the manifest otherwise carries
            # only the backup name, leaving a "complete" backup whose ClickHouse half no
            # tooling can locate.
            CH_LOCATION_OVERRIDE="s3://${ch_cfg_bucket}/${ch_cfg_path}"
        fi
    fi
    if [ "${CH_BACKUP_TYPE}" = "incremental" ]; then
        # location='remote' is REQUIRED, not cosmetic: the flag is --diff-from-remote, so the
        # base must exist in the remote. system.backup_list also carries local-only rows, and
        # a failed upload leaves exactly that (the local copy is deleted only AFTER a
        # successful upload). Without the filter the next incremental picked that local-only
        # name, clickhouse-backup rejected the base, the upload failed and left another
        # local-only row — every subsequent incremental broken until someone manually
        # deleted local backups. Verified against the live cluster: `location` is a String
        # column holding 'local' / 'remote'.
        local prev_backup=$(ch_query "SELECT name FROM system.backup_list WHERE name LIKE 'backup_%' AND location='remote' ORDER BY created DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || true)
        if [ -n "${prev_backup}" ]; then
            ch_upload_cmd="${ch_upload_cmd} --diff-from-remote=${prev_backup}"
            log "INFO" "[ClickHouse] Incremental upload based on: ${prev_backup}"
        else
            log "WARN" "[ClickHouse] No previous backup found for incremental, falling back to full"
        fi
    fi
    ch_upload_cmd="${ch_upload_cmd} ${backup_name}"
    log "INFO" "[ClickHouse] Creating backup: ${backup_name} (type: ${CH_BACKUP_TYPE})"
    # Record the newest existing action time for THIS exact command before enqueuing, so the poll
    # below only reads the row this run creates. Without it, a rerun with the same --backup-id
    # (identical command string) matches a stale 'success' row from a prior attempt and reports
    # success without creating/uploading anything. Empty table → 0.
    local ch_create_since
    ch_create_since=$(ch_query "SELECT ifNull(toUnixTimestamp(max(start)),0) FROM system.backup_actions WHERE command='${ch_create_cmd}' FORMAT TabSeparatedRaw" 2>/dev/null | tr -dc '0-9')
    [ -n "${ch_create_since}" ] || ch_create_since=0
    if ! ch_query "INSERT INTO system.backup_actions(command) VALUES('${ch_create_cmd}')" >> "${LOG_FILE}" 2>&1; then
        log "ERROR" "[ClickHouse] Failed to enqueue backup create action (clickhouse-client exec failed)"
        return 1
    fi

    # Step 2: Wait for backup creation to complete
    log "INFO" "[ClickHouse] Waiting for backup creation to complete..."
    local max_wait=${CH_CREATE_TIMEOUT}  # configurable via CH_CREATE_TIMEOUT
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local status=$(ch_query "SELECT status FROM system.backup_actions WHERE command='${ch_create_cmd}' AND toUnixTimestamp(start) > ${ch_create_since} ORDER BY start DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null)

        if [ "${VERBOSE}" = "true" ]; then
            log "INFO" "[ClickHouse] Backup creation status: ${status}"
        fi

        if [ "${status}" = "success" ]; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            # Get backup size (human-readable and raw bytes)
            local backup_size=$(ch_query "SELECT formatReadableSize(size) FROM system.backup_list WHERE name='${backup_name}' FORMAT TabSeparatedRaw" 2>/dev/null || echo "unknown")
            local backup_size_bytes=$(ch_query "SELECT size FROM system.backup_list WHERE name='${backup_name}' FORMAT TabSeparatedRaw" 2>/dev/null || echo "0")

            log "INFO" "[ClickHouse] ✓ Completed: ${backup_name} (${backup_size}, ${duration}s)"
            log "INFO" "[ClickHouse]   Location: ${ch_pod}:/var/lib/clickhouse/backup/${backup_name} (hardlinks)"
            break
        elif [ "${status}" = "error" ]; then
            local error=$(ch_query "SELECT error FROM system.backup_actions WHERE command='${ch_create_cmd}' AND toUnixTimestamp(start) > ${ch_create_since} ORDER BY start DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null)
            log "ERROR" "[ClickHouse] Backup creation failed: ${error}"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $max_wait ]; then
        log "ERROR" "[ClickHouse] Backup creation timed out after ${max_wait} seconds"
        return 1
    fi

    # Step 3: Upload to S3 if enabled
    if [ "${S3_ENABLED}" = "true" ]; then
        log "INFO" "[ClickHouse] Uploading backup to S3..."
        local ch_upload_since
        ch_upload_since=$(ch_query "SELECT ifNull(toUnixTimestamp(max(start)),0) FROM system.backup_actions WHERE command='${ch_upload_cmd}' FORMAT TabSeparatedRaw" 2>/dev/null | tr -dc '0-9')
        [ -n "${ch_upload_since}" ] || ch_upload_since=0
        if ! ch_query "INSERT INTO system.backup_actions(command) VALUES('${ch_upload_cmd}')" >> "${LOG_FILE}" 2>&1; then
            log "ERROR" "[ClickHouse] Failed to enqueue backup upload action (clickhouse-client exec failed)"
            return 1
        fi

        # Wait for upload to complete
        log "INFO" "[ClickHouse] Waiting for S3 upload to complete..."
        elapsed=0
        max_wait=${CH_UPLOAD_TIMEOUT}  # configurable via CH_UPLOAD_TIMEOUT
        while [ $elapsed -lt $max_wait ]; do
            local upload_status=$(ch_query "SELECT status FROM system.backup_actions WHERE command='${ch_upload_cmd}' AND toUnixTimestamp(start) > ${ch_upload_since} ORDER BY start DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null)

            if [ "${VERBOSE}" = "true" ]; then
                log "INFO" "[ClickHouse] Upload status: ${upload_status}"
            fi

            if [ "${upload_status}" = "success" ]; then
                log "INFO" "[ClickHouse] S3 upload completed successfully"
                break
            elif [ "${upload_status}" = "error" ]; then
                local upload_error=$(ch_query "SELECT error FROM system.backup_actions WHERE command='${ch_upload_cmd}' AND toUnixTimestamp(start) > ${ch_upload_since} ORDER BY start DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null)
                log "ERROR" "[ClickHouse] S3 upload failed: ${upload_error}"
                return 1
            fi

            sleep 10
            elapsed=$((elapsed + 10))
        done

        if [ $elapsed -ge $max_wait ]; then
            log "ERROR" "[ClickHouse] S3 upload timed out after ${max_wait} seconds"
            return 1
        fi

        # Delete local backup after successful upload
        log "INFO" "[ClickHouse] Deleting local backup after S3 upload..."
        ch_query "INSERT INTO system.backup_actions(command) VALUES('delete local ${backup_name}')" >> "${LOG_FILE}" 2>&1
    elif [ "${BACKUP_TARGET}" = "shared" ]; then
        # clickhouse-backup has no filesystem remote, so archive the FREEZE backup to the
        # mounted RWX in-pod. Runs in the clickhouse-backup sidecar (it has both the data
        # volume with the hardlinks AND the central mount); tar dereferences the hardlinks.
        local ch_shared_dir="$(comp_inpod clickhouse)"
        CH_SHARED_TAR="${ch_shared_dir}/${backup_name}.tar.gz"
        log "INFO" "[ClickHouse] Archiving backup to shared volume: ${CH_SHARED_TAR}"
        if ! timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            sh -c "mkdir -p '${ch_shared_dir}' && tar -czf '${CH_SHARED_TAR}' -C /var/lib/clickhouse/backup '${backup_name}'" >> "${LOG_FILE}" 2>&1; then
            log "ERROR" "[ClickHouse] Failed to archive backup to shared volume"
            return 1
        fi
        # Verify the archive landed and is non-empty
        local ch_tar_bytes
        ch_tar_bytes=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            sh -c "wc -c < '${CH_SHARED_TAR}'" 2>/dev/null | tr -d ' ')
        : "${ch_tar_bytes:=0}"
        if ! [ "${ch_tar_bytes}" -gt 0 ] 2>/dev/null; then
            log "ERROR" "[ClickHouse] Shared archive missing/empty at ${CH_SHARED_TAR}"
            return 1
        fi
        log "INFO" "[ClickHouse] ✓ Archived to shared volume (${ch_tar_bytes} bytes)"
        # Delete local hardlink backup after archiving (keep the data PVC clean)
        log "INFO" "[ClickHouse] Deleting local backup after archiving..."
        ch_query "INSERT INTO system.backup_actions(command) VALUES('delete local ${backup_name}')" >> "${LOG_FILE}" 2>&1
    fi

    # List backups (only in verbose mode)
    if [ "${VERBOSE}" = "true" ]; then
        log "INFO" "[ClickHouse] Listing all backups:"
        ch_query "SELECT name, created, location, desc FROM system.backup_list ORDER BY created DESC LIMIT 10 FORMAT PrettyCompactMonoBlock" 2>&1 | tee -a "${LOG_FILE}"
    fi

    log "INFO" "[ClickHouse] Backup completed successfully"
    CH_BACKUP_SUCCESS=true
    CH_BACKUP_NAME="${backup_name}"
    CH_BACKUP_SIZE="${backup_size}"
    CH_BACKUP_SIZE_BYTES="${backup_size_bytes:-0}"
    CH_BACKUP_DURATION="${duration}"
    if [ "${BACKUP_TARGET}" = "shared" ]; then
        CH_BACKUP_LOCATION="${CH_SHARED_TAR:-}"
    elif [ -n "${CH_LOCATION_OVERRIDE:-}" ]; then
        # The sidecar was configured for somewhere other than this run's root and we honoured
        # it. Record WHERE, or the manifest reports a "complete" backup whose ClickHouse half
        # no tool can resolve (restore and retention both look under this run's root).
        CH_BACKUP_LOCATION="clickhouse-backup S3 remote: ${backup_name} at ${CH_LOCATION_OVERRIDE}"
    else
        # s3: the local hardlinks were deleted after upload; the backup lives in the
        # clickhouse-backup S3 remote, addressed by name (restore: restore_remote <name>).
        CH_BACKUP_LOCATION="clickhouse-backup S3 remote: ${backup_name}"
    fi
    return 0
}

################################################################################
# VictoriaMetrics Backup - Using vmbackup
################################################################################

backup_victoriametrics() {
    log "INFO" "[VictoriaMetrics] === Starting Backup ==="
    local vm_start_time=$(date +%s)
    local vm_total_bytes=0

    # Non-AWS S3-compatible storage: vmbackup does not read endpoint env vars — the custom
    # endpoint must be passed as a flag (expands to nothing for AWS S3). Computed once here
    # and reused by both the dry-run log and the per-pod exec below.
    local vm_endpoint_flag=""
    [ -n "${S3_ENDPOINT}" ] && vm_endpoint_flag="-customS3Endpoint=${S3_ENDPOINT}"

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

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[VictoriaMetrics] [DRY RUN] Commands per vmstorage pod:"
        for pod in ${vmstorage_pods}; do
            local backup_name="vm_backup_${TIMESTAMP}"
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                local backup_dst="$(comp_display victoriametrics)/${pod}/${backup_name}"
            else
                local backup_dst="fs://$(comp_inpod victoriametrics)/${pod}/${backup_name}"
            fi
            log "INFO" "[VictoriaMetrics] [DRY RUN]   -- ${pod}:"
            log "INFO" "[VictoriaMetrics] [DRY RUN]     \$ kubectl exec -n ${NAMESPACE} ${pod} -c vmbackup -- \\"
            log "INFO" "[VictoriaMetrics] [DRY RUN]         /vmbackup-prod \\"
            log "INFO" "[VictoriaMetrics] [DRY RUN]         -snapshot.createURL=http://localhost:8482/snapshot/create \\"
            log "INFO" "[VictoriaMetrics] [DRY RUN]         -snapshot.deleteURL=http://localhost:8482/snapshot/delete \\"
            log "INFO" "[VictoriaMetrics] [DRY RUN]         -storageDataPath=/vmstorage-data \\"
            log "INFO" "[VictoriaMetrics] [DRY RUN]         -dst=${backup_dst}${vm_endpoint_flag:+ ${vm_endpoint_flag}} -concurrency=10 -maxBytesPerSecond=0"
        done
        VM_BACKUP_SUCCESS=true
        return 0
    fi

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
        
        # Determine backup destination
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            # vmbackup writes directly to S3 (IRSA creds + AWS_REGION from the pod env) and
            # writes backup_complete.ignore at the dst as its final step — so the marker is
            # structurally guaranteed (no copy step to drop it; root-cause fix for the bug).
            local backup_dst="$(comp_display victoriametrics)/${pod}/${backup_name}"
            log "INFO" "[VictoriaMetrics] Creating backup to S3: ${backup_name}"
        else
            # shared mode: vmbackup writes to the mounted central volume
            local backup_dst="fs://$(comp_inpod victoriametrics)/${pod}/${backup_name}"
            log "INFO" "[VictoriaMetrics] Creating backup to shared volume: ${backup_name}"
        fi
        
        # Execute vmbackup in the sidecar container using snapshot API
        local vm_output
        local vm_exit_code
        set +e
        vm_output=$(timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c vmbackup -- \
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
            log "INFO" "[VictoriaMetrics] ✓ Completed: ${backup_name}"
            log "INFO" "[VictoriaMetrics] Location: ${backup_dst}"
            # Record the landed ref (strip vmbackup's fs:// / s3:// scheme noise to a plain URI)
            VM_BACKUP_OBJECTS="${VM_BACKUP_OBJECTS} ${backup_dst#fs://}"
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
    
    # Summary
    if [ ${success_count} -eq 0 ]; then
        log "ERROR" "[VictoriaMetrics] ✗ Backup failed for all pods"
        log "ERROR" "[VictoriaMetrics] Failed pods:${failed_pods}"
        return 1
    elif [ ${success_count} -lt ${pod_count} ]; then
        log "WARN" "[VictoriaMetrics] ⚠ Backup partially completed: ${success_count}/${pod_count} pods"
        log "WARN" "[VictoriaMetrics] Failed pods:${failed_pods}"
    else
        log "INFO" "[VictoriaMetrics] Backup completed successfully"
        VM_BACKUP_SUCCESS=true
    fi
    
    local vm_end_time=$(date +%s)
    VM_BACKUP_DURATION=$((vm_end_time - vm_start_time))
    VM_BACKUP_POD_COUNT=${success_count}
    VM_BACKUP_TOTAL_BYTES=${vm_total_bytes}
    
    return 0
}

################################################################################
# PMM Server Backup - Archive /srv from each PMM server pod
################################################################################

backup_pmm_server() {
    log "INFO" "[PMMServer] === Starting Backup ==="
    local pmm_start_time=$(date +%s)
    local pmm_total_bytes=0

    local pmm_backup_dir="$(comp_path pmm-server)"

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

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[PMMServer] [DRY RUN] (target=${BACKUP_TARGET}) Commands per PMM server pod:"
        for pod in ${pmm_pods}; do
            log "INFO" "[PMMServer] [DRY RUN]   -- ${pod}:"
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                log "INFO" "[PMMServer] [DRY RUN]     \$ kubectl exec -n ${NAMESPACE} ${pod} -c pmm-backup -- sh -c \\"
                log "INFO" "[PMMServer] [DRY RUN]         'cd ${PMM_SRV_PATH} && tar -czf - --exclude=lost+found \$(ls -A | grep -vxF lost+found) | rclone rcat $(comp_path pmm-server)/${pod}/srv.tar.gz'"
            else
                log "INFO" "[PMMServer] [DRY RUN]     \$ kubectl exec -n ${NAMESPACE} ${pod} -- sh -c \\"
                log "INFO" "[PMMServer] [DRY RUN]         'cd ${PMM_SRV_PATH} && tar -czf $(comp_inpod pmm-server)/${pod}/srv.tar.gz --exclude=lost+found \$(ls -A | grep -vxF lost+found)'"
            fi
        done
        PMM_BACKUP_SUCCESS=true
        return 0
    fi

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
        local pmm_exit size_b size_h

        set +e
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c pmm-backup -- \
                sh -c "set -o pipefail; cd '${PMM_SRV_PATH}' && tar -czf - --exclude=lost+found \$(ls -A | grep -vxF lost+found) | rclone rcat --s3-no-check-bucket '${s3_uri}'" \
                >> "${LOG_FILE}" 2>&1
            pmm_exit=$?
        else
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -- \
                sh -c "mkdir -p '$(comp_inpod pmm-server)/${pod}' && cd '${PMM_SRV_PATH}' && tar -czf '${shared_file}' --exclude=lost+found \$(ls -A | grep -vxF lost+found)" \
                >> "${LOG_FILE}" 2>&1
            pmm_exit=$?
        fi
        set -e

        # tar: 0=ok, 1=files changed/unreadable while reading (warn); >=2 fatal; 124=timeout
        if [ ${pmm_exit} -eq 0 ] || [ ${pmm_exit} -eq 1 ]; then
            [ ${pmm_exit} -eq 1 ] && log "WARN" "[PMMServer] ${pod}: tar warnings (files changed/unreadable while archiving)"

            # Verify the archive actually landed and read its size from the destination
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                size_b=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c pmm-backup -- \
                    rclone size --s3-no-check-bucket --json "${s3_uri}" 2>/dev/null | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p')
            else
                size_b=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -- \
                    sh -c "wc -c < '${shared_file}'" 2>/dev/null | tr -d ' ')
            fi
            : "${size_b:=0}"

            if ! [ "${size_b}" -gt 0 ] 2>/dev/null; then
                log "ERROR" "[PMMServer] ${pod}: archive missing/empty at destination after upload — treating as failed"
                [ "${BACKUP_TARGET}" = "s3" ] && timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c pmm-backup -- rclone delete --s3-no-check-bucket "${s3_uri}" >/dev/null 2>&1 || true
                failed_pods="${failed_pods} ${pod}"
                continue
            fi

            size_h=$(human_bytes "${size_b}")
            log "INFO" "[PMMServer] ✓ ${pod}: ${PMM_SRV_PATH} archived (${size_h})"
            success_count=$((success_count + 1))
            pmm_total_bytes=$((pmm_total_bytes + size_b))
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                PMM_BACKUP_OBJECTS="${PMM_BACKUP_OBJECTS} $(comp_display pmm-server)/${pod}/srv.tar.gz"
            else
                PMM_BACKUP_OBJECTS="${PMM_BACKUP_OBJECTS} ${shared_file}"
            fi
        else
            log "ERROR" "[PMMServer] Backup failed for ${pod} (exit code: ${pmm_exit})"
            [ ${pmm_exit} -eq 124 ] && log "ERROR" "[PMMServer]   Timed out after ${KUBECTL_EXEC_TIMEOUT}s (raise KUBECTL_EXEC_TIMEOUT)"
            [ "${BACKUP_TARGET}" = "s3" ] && timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c pmm-backup -- rclone delete --s3-no-check-bucket "${s3_uri}" >/dev/null 2>&1 || true
            failed_pods="${failed_pods} ${pod}"
        fi
    done

    # Summary
    if [ ${success_count} -eq 0 ]; then
        log "ERROR" "[PMMServer] ✗ Backup failed for all pods"
        log "ERROR" "[PMMServer] Failed pods:${failed_pods}"
        return 1
    elif [ ${success_count} -lt ${pod_count} ]; then
        log "WARN" "[PMMServer] ⚠ Backup partially completed: ${success_count}/${pod_count} pods"
        log "WARN" "[PMMServer] Failed pods:${failed_pods}"
    else
        log "INFO" "[PMMServer] Backup completed successfully"
        PMM_BACKUP_SUCCESS=true
    fi

    local pmm_end_time=$(date +%s)
    PMM_BACKUP_DURATION=$((pmm_end_time - pmm_start_time))
    PMM_BACKUP_POD_COUNT=${success_count}
    PMM_BACKUP_TOTAL_BYTES=${pmm_total_bytes}

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
        log "ERROR" "[EncryptionKey] jq is required to export the secret but is not available"
        log "ERROR" "[EncryptionKey] Install jq in the backup image (Alpine: apk add jq; Debian: apt-get install jq)"
        return 1
    fi
    
    # Export secret as JSON, strip server-side metadata that breaks portable restore
    # umask, not chmod-after: the destination helper documents "mode set BEFORE content" and
    # the staging path must honour the same invariant — this is the key that decrypts
    # PostgreSQL, on a volume every component pod mounts.
    if ! ( umask 077; kubectl get secret "${secret_name}" -n "${NAMESPACE}" -o json | \
        jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.namespace, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]) | if .metadata.annotations == {} then del(.metadata.annotations) else . end' \
        > "${key_file}" ); then
        log "ERROR" "[EncryptionKey] Failed to export secret"
        return 1
    fi
    if [ -s "${key_file}" ]; then
        
        # Set restrictive permissions
        chmod 600 "${key_file}"
        
        # Calculate checksum
        local checksum
        if command -v sha256sum >/dev/null 2>&1; then
            checksum=$(sha256sum "${key_file}" | cut -d' ' -f1)
        elif command -v shasum >/dev/null 2>&1; then
            checksum=$(shasum -a 256 "${key_file}" | cut -d' ' -f1)
        else
            checksum="N/A"
        fi
        # `printf '%.16s'`, not ${checksum:0:16}: substring expansion is a bash/ash-with-
        # bash-compat extension and a FATAL "Bad substitution" on dash, which this file
        # claims to support. It aborted the whole run right here — after every component had
        # uploaded but before write_manifest — leaving the data orphaned with no index. A
        # syntax check cannot catch it (`-n` never evaluates expansions), so it survived
        # every shell lint.
        local checksum_short
        checksum_short=$(printf '%.16s' "${checksum}")

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
                ENCRYPTION_KEY_LOCATION="${enc_dest_display}"
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
                log "ERROR" "[EncryptionKey]   Staged export OK but storing it FAILED (no pmm-backup sidecar pod reachable?)"
                log "ERROR" "[EncryptionKey]   The key is not in S3; a DR restore of this backup could not decrypt PostgreSQL data"
                return 1
            fi

        return 0
    else
        log "ERROR" "[EncryptionKey] Failed to export secret"
        return 1
    fi
}

################################################################################
# 8. Restore — validation gate, scale down/up, one function per component
################################################################################

# Tri-state probes. A fail-closed pre-restore gate must never report "your data is gone"
# when what actually happened is "I could not look" — an exec timeout, an evicted client
# pod or a 403 would otherwise refuse a restore mid-incident and send the operator hunting
# a backup problem that does not exist. Every check in validate_restore_targets() therefore
# distinguishes three outcomes rather than two:
#
#   0 = present     1 = genuinely absent/empty     2 = the check itself failed
#
# NB for s3_object_state: `rclone size` on a MISSING path exits 0 and prints
# {"count":0,"bytes":0}, so rc alone cannot tell absence from success — rc>0 is unambiguously
# a check failure, and only then is the byte count meaningful.
s3_object_state() {
    local bytes rc=0
    bytes=$(store_bytes "$1" 2>/dev/null) || rc=$?
    [ "${rc}" -ne 0 ] && return 2
    [ "${bytes:-0}" -gt 0 ] 2>/dev/null
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

# Emit the rclone S3 env entries shared by every temp restore pod (the s3 client pod and the
# /srv restore pod). Block style, 8-space indent to match the pod heredocs. Single source so
# a new RCLONE_CONFIG_S3_* knob (or the static-key env) lands in every temp pod at once,
# instead of being added to one heredoc and silently missed in the other. Includes the
# optional custom endpoint and, when a secret is configured, ${TEMP_POD_S3_KEYS_ENV}.
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

create_s3_client_pod() {
    [ "${S3_ENABLED}" = "true" ] || return 0
    log "INFO" "Starting temp S3 client pod ${RESTORE_CLIENT_POD} (rclone; survives PMM scale-down)..."
    local rclone_env
    rclone_env="$(render_rclone_s3_env)"
    if ! kubectl apply -f - -n "${NAMESPACE}" >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${RESTORE_CLIENT_POD}
  labels:
    app.kubernetes.io/component: restore-s3-client
  annotations:
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
${TEMP_POD_SA_LINE}
  containers:
    - name: pmm-backup
      image: ${S3_CLIENT_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      env:
${rclone_env}
EOF
    then
        log "ERROR" "Could not create S3 client pod ${RESTORE_CLIENT_POD}"; return 1
    fi
    wait_for_pod_ready_by_name "${NAMESPACE}" "${RESTORE_CLIENT_POD}" 120 || { log "ERROR" "S3 client pod not ready"; return 1; }
    S3_CLIENT_POD="${RESTORE_CLIENT_POD}"
    # Pin it: this pod is not label-discoverable, so no retry may swap it out.
    S3_CLIENT_POD_PINNED=true
    return 0
}
delete_s3_client_pod() {
    kubectl delete pod -n "${NAMESPACE}" "${RESTORE_CLIENT_POD}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

vmstorage_pvc_name() { echo "${VM_STORAGE_PVC_PREFIX}$1"; }

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

get_vmrestore_image() {
    local pod="$1" img
    img=$(kubectl get pod -n "${NAMESPACE}" "${pod}" -o jsonpath='{.spec.containers[?(@.name=="vmrestore")].image}' 2>/dev/null || true)
    [ -n "${img}" ] && { echo "${img}"; return 0; }
    [ -n "${VMRESTORE_IMAGE}" ] && { echo "${VMRESTORE_IMAGE}"; return 0; }
    echo "victoriametrics/vmrestore:latest"
}

# After the manifest is loaded, turn on every component the manifest has (unless
# the user explicitly selected a subset).
select_default_components() {
    # Default (no explicit --<component>): restore everything the manifest marks 'success'.
    if [ "${EXPLICIT_SELECTION}" != "true" ]; then
        [ "${MF_PG_STATUS}" = "success" ]  && RESTORE_POSTGRESQL=true
        [ "${MF_CH_STATUS}" = "success" ]  && RESTORE_CLICKHOUSE=true
        [ "${MF_VM_STATUS}" = "success" ]  && RESTORE_VICTORIAMETRICS=true
        [ "${MF_PMM_STATUS}" = "success" ] && RESTORE_PMM_SERVER=true
        [ "${MF_ENC_STATUS}" = "success" ] && RESTORE_ENCRYPTION_KEY=true
    fi
    # Apply --skip-<component> last, so it overrides both the defaults and explicit selection.
    [ "${SKIP_POSTGRESQL}" = "true" ]      && RESTORE_POSTGRESQL=false
    [ "${SKIP_CLICKHOUSE}" = "true" ]      && RESTORE_CLICKHOUSE=false
    [ "${SKIP_VICTORIAMETRICS}" = "true" ] && RESTORE_VICTORIAMETRICS=false
    [ "${SKIP_PMM_SERVER}" = "true" ]      && RESTORE_PMM_SERVER=false
    [ "${SKIP_ENCRYPTION_KEY}" = "true" ]  && RESTORE_ENCRYPTION_KEY=false
    return 0
}

################################################################################
# Pre-restore validation gate
#
# Everything a SELECTED component needs must be proven here, while the cluster is
# still whole. scale_down_pmm() is the point of no return: past it, a missing
# ClickHouse remote, an absent /srv tarball, a shard-count mismatch or a
# ServiceAccount that does not exist all surface half-way through a restore, with
# PMM already at 0 replicas and no automatic way back.
#
# Fails CLOSED — any selected component that cannot be validated aborts the run and
# names the --skip-<component> flag that would drop it deliberately. Checks are NOT
# short-circuited: every component is validated so one run reports every problem,
# rather than making the operator re-run to discover them one at a time.
################################################################################
validate_restore_targets() {
    local fail=0 s3_readable=true

    log "INFO" "Validating restore targets for ${BACKUP_NAME} (nothing has been changed yet)..."

    # In s3 mode the dedicated client pod is only created for real runs, so a --dry-run
    # against a scaled-down PMM has no rclone anywhere. Degrade to "checks skipped" with a
    # loud warning rather than reporting phantom failures.
    if [ "${S3_ENABLED}" = "true" ] && ! pick_s3_client_pod >/dev/null 2>&1; then
        s3_readable=false
        log "WARN" "[Preflight] No S3 client pod available; object-existence checks were SKIPPED (dry-run against a scaled-down PMM?)"
    fi

    # ---- Cross-cutting: temp-pod credentials -------------------------------------
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
                # Keys are enumerated ONCE and matched exactly, rather than addressed with
                # `jsonpath={.data.<key>}`: k8s allows dots in Secret keys (`[-._a-zA-Z0-9]+`)
                # and JSONPath reads a dot as a field separator, so `aws.access.key` would
                # resolve to nothing and be reported missing while mounting fine. `grep -e`
                # because a key may legitimately begin with '-'.
                #
                # `{{if $v}}` matters: a key present with an EMPTY value (truncated sealed
                # secret, `--from-literal=access-key=`) would otherwise satisfy a name-only
                # check, and every temp pod would then start with AWS_ACCESS_KEY_ID="" and
                # die on 403 *after* PMM is down. Only non-empty values count as present.
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

    # ---- Encryption key ----------------------------------------------------------
    # Deliberately NOT overridable with --force. --force is mandatory for every
    # non-interactive run (cmd_restore refuses without a TTY otherwise) and is what the
    # documented `kubectl exec ... --force` command uses, so honouring it here would
    # disable this check for all automation — and because ENCRYPTION_KEY_OK is excluded
    # from all_ok, the run would then print "Restore completed successfully" over data
    # that cannot be decrypted. --skip-encryption-key is the explicit, narrow override.
    if [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${MF_ENC_STATUS}" = "success" ]; then
        # One path, one probe: s3_object_state routes through store_bytes, which handles both
        # targets and preserves the could-not-look signal that `[ -s ]` cannot express.
        local _enc_path="$(comp_path encryption)/pg-encryption-key.yaml"
        if [ "${S3_ENABLED}" != "true" ] || [ "${s3_readable}" = "true" ]; then
            _st=0; s3_object_state "${_enc_path}" || _st=$?
            report_state "${_st}" "encryption" "key ${_enc_path}" "--skip-encryption-key to drop it" || fail=1
        fi
    fi

    # ---- PostgreSQL --------------------------------------------------------------
    if [ "${RESTORE_POSTGRESQL}" = "true" ] && [ "${MF_PG_STATUS}" = "success" ]; then
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
            for _db in ${MF_PG_DBS}; do
                if [ "${S3_ENABLED}" = "true" ]; then
                    if [ "${s3_readable}" = "true" ]; then
                        _st=0; s3_object_state "$(comp_path postgresql)/${_db}.dump" || _st=$?
                        report_state "${_st}" "postgresql" "dump ${_db}.dump" "--skip-postgresql to drop it" || fail=1
                    fi
                elif [ ! -s "$(comp_path postgresql)/${_db}.dump" ]; then
                    report_state 1 "postgresql" "dump $(comp_path postgresql)/${_db}.dump" "--skip-postgresql to drop it" || fail=1
                fi
            done
        fi
    fi

    # ---- ClickHouse --------------------------------------------------------------
    if [ "${RESTORE_CLICKHOUSE}" = "true" ] && [ "${MF_CH_STATUS}" = "success" ]; then
        local _chpod=""
        _chpod=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_CH_POD}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -z "${_chpod}" ]; then
            log "ERROR" "[Preflight] clickhouse: no pod matching '${LABEL_CH_POD}' (--skip-clickhouse to drop it)"
            fail=1
        elif [ -z "${MF_CH_NAME}" ]; then
            log "ERROR" "[Preflight] clickhouse: manifest records no backup name"
            fail=1
        elif [ "${S3_ENABLED}" = "true" ]; then
            # Mirror restore_clickhouse()'s --env overrides exactly: the sidecar's baked-in
            # S3_BUCKET/S3_PATH point at THIS instance's prefix, which is the wrong place to
            # look during a cross-namespace/DR restore from another instance's backup.
            #
            # The listing's exit status is captured SEPARATELY from the name match: piping
            # straight into grep would report an unreachable sidecar, a missing container or
            # an S3 timeout as "backup not found", blocking a restore whose data is fine.
            # This gate fails closed, so conflating "could not check" with "absent" turns
            # every transient error into a refused restore.
            #
            # --env placement verified on clickhouse-backup 2.8.0: trailing flags after the
            # positional `remote` ARE parsed (the tool logs "override S3_PATH=..." and honours
            # it), so this mirrors restore_clickhouse() rather than wrapping in `sh -c`, which
            # would add a quoting surface for no benefit.
            #
            # Its own budget: `list remote` reads metadata for every remote backup, so the 30s
            # status timeout is too tight on a populated bucket (and failing closed, a timeout
            # would refuse a fine restore) — while KUBECTL_EXEC_TIMEOUT's 600s would stall a
            # --dry-run for ten silent minutes against a wedged sidecar. Announce it first so
            # a slow listing looks like progress rather than a hang.
            local _ch_list="" _ch_rc=0
            log "INFO" "[Preflight] clickhouse: listing remote backups (can take a while on a populated bucket)..."
            _ch_list=$(timeout "${CH_LIST_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${_chpod}" -c clickhouse-backup -- \
                clickhouse-backup list remote \
                --env "S3_BUCKET=${S3_BUCKET}" --env "S3_PATH=$(clickhouse_remote_key)" 2>/dev/null) || _ch_rc=$?
            if [ "${_ch_rc}" -ne 0 ]; then
                log "ERROR" "[Preflight] clickhouse: could not list remote backups (exit ${_ch_rc}); is the 'clickhouse-backup' sidecar running in ${_chpod}?"
                log "ERROR" "[Preflight]   Not treating this as 'backup absent' — the check itself failed. Fix the sidecar, or pass --skip-clickhouse."
                fail=1
            elif ! echo "${_ch_list}" | awk '{print $1}' | grep -Fxq "${MF_CH_NAME}"; then
                log "ERROR" "[Preflight] clickhouse: remote backup '${MF_CH_NAME}' not found under s3://${S3_BUCKET}/$(clickhouse_remote_key)"
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
            # `test -s` as separate argv entries, NOT `sh -c "...'${var}'..."`: MF_CH_NAME and
            # BACKUP_NAME come from the backup's manifest and from --backup-id, so interpolating
            # them into a quoted shell string would let a value containing a single quote run
            # arbitrary commands inside the ClickHouse pod (and any value with spaces or globs
            # silently change what is tested).
            #
            # `test` prints nothing and returns 1 for false, while kubectl exec also returns 1
            # for its OWN failures (container missing, exec RBAC denied). They are told apart by
            # stderr: kubectl writes a diagnostic, `test` never does.
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
    fi

    # ---- VictoriaMetrics ---------------------------------------------------------
    if [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && [ "${MF_VM_STATUS}" = "success" ]; then
        local _vmpods="" _vmcluster="" _vmtarget="" _vmsrc="" _p _ord="" _sub="" _vmname=""
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
        # Shard-count mismatch was already checked inside restore_victoriametrics(), but that
        # runs with PMM ALREADY DOWN. Hoisted here so it aborts while the cluster is intact.
        if [ -n "${_vmpods}" ] && { [ "${S3_ENABLED}" != "true" ] || [ "${s3_readable}" = "true" ]; }; then
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
                    _sub=$(vm_src_subdir_for_ord "${_ord}" 2>/dev/null || echo "")
                    if [ -z "${_sub}" ]; then
                        log "ERROR" "[Preflight] victoriametrics: backup has no source directory for ordinal '${_ord}' (pod ${_p})"
                        fail=1
                        continue
                    fi
                    # A directory being LISTED is not the same as it holding data. vmrestore
                    # against an empty or truncated vm_backup_<id>/ fails only once PMM is
                    # already down — the exact failure this gate exists to prevent — so spend
                    # one listing per ordinal to prove there is something to restore.
                    # The listing's own status is captured before testing emptiness. Piping
                    # into `grep -q .` would take the pipeline's status from grep, so a failed
                    # listing (timeout, evicted client pod) would read as "source is empty" —
                    # blaming the backup for an infrastructure problem.
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
    fi

    # ---- PMM server /srv ---------------------------------------------------------
    if [ "${RESTORE_PMM_SERVER}" = "true" ] && [ "${MF_PMM_STATUS}" = "success" ]; then
        local _sts="" _replicas="" _i=0 _sub=""
        _sts=$(kubectl get statefulset -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -z "${_sts}" ]; then
            log "ERROR" "[Preflight] pmm-server: no StatefulSet matching '${LABEL_PMM_SERVER}' (--skip-pmm-server to drop it)"
            fail=1
        elif [ "${S3_ENABLED}" != "true" ] || [ "${s3_readable}" = "true" ]; then
            # Mirror restore_pmm_server()'s replica resolution so the ordinals checked here are
            # the ordinals it will actually iterate.
            _replicas=$(kubectl get statefulset "${_sts}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
            if [ -z "${_replicas}" ] || [ "${_replicas}" = "0" ]; then
                _replicas=$(kubectl get statefulset "${_sts}" -n "${NAMESPACE}" \
                    -o jsonpath="{.metadata.annotations['restore.pmm.percona.com/original-replicas']}" 2>/dev/null || echo "")
            fi
            [ -n "${_replicas}" ] && [ "${_replicas}" != "0" ] || _replicas="${PMM_SERVER_REPLICAS:-3}"
            # A non-numeric count (a hand-edited original-replicas annotation, say) would make
            # the `-lt` below exit 2, the loop body never run, and this gate report SUCCESS
            # without having validated a single ordinal. A silent skip is worse than no gate,
            # so refuse explicitly instead of inheriting shell semantics.
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
            while [ "${_i}" -lt "${_replicas}" ]; do
                _sub=$(pmm_src_subdir_for_ord "${_i}" 2>/dev/null || echo "")
                if [ -z "${_sub}" ]; then
                    # restore_pmm_server() only WARNs and skips here, so without this gate a
                    # PMM replica silently keeps its pre-restore /srv while the run reports success.
                    log "ERROR" "[Preflight] pmm-server: backup has no /srv directory for ordinal ${_i} (${_replicas} replica(s) expected)"
                    fail=1
                elif [ "${S3_ENABLED}" = "true" ]; then
                    _st=0; s3_object_state "$(comp_path pmm-server)/${_sub}/srv.tar.gz" || _st=$?
                    report_state "${_st}" "pmm-server" "srv.tar.gz for ordinal ${_i} (${_sub})" "--skip-pmm-server to drop it" || fail=1
                elif [ ! -s "$(comp_path pmm-server)/${_sub}/srv.tar.gz" ]; then
                    report_state 1 "pmm-server" "$(comp_path pmm-server)/${_sub}/srv.tar.gz" "--skip-pmm-server to drop it" || fail=1
                fi
                _i=$((_i + 1))
            done
        fi
    fi

    if [ "${fail}" -ne 0 ]; then
        log "ERROR" "Pre-restore validation FAILED. Nothing was changed; PMM is still running."
        return 1
    fi
    log "INFO" "Pre-restore validation passed — every selected component's source and target are present"
    return 0
}

# EXIT/INT/TERM handler: tear down the temp S3 client pod, then release owned locks.
restore_cleanup() {
    delete_s3_client_pod
    # Sweep any temp mounter pods a signal (INT/TERM) may have interrupted mid-run. On normal
    # completion the per-ordinal loops already delete these, so this finds nothing; on an
    # interrupted run it prevents a leaked pod from holding an RWO data PVC (vmstorage-db /
    # pmm-storage), which would otherwise wedge the real pod on Multi-Attach at scale-up.
    local _c
    for _c in vm-restore-temp pmm-srv-restore-temp; do
        kubectl delete pod -n "${NAMESPACE}" -l "app.kubernetes.io/component=${_c}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    done
    release_locks
    return 0
}

################################################################################
# PMM scale down / up (restore happens with PMM down so nothing writes the DBs)
################################################################################
scale_down_pmm() {
    PMM_STATEFULSET_NAME=$(kubectl get statefulset -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "${PMM_STATEFULSET_NAME}" ]; then log "WARN" "PMM StatefulSet not found, skipping scale down"; return 0; fi
    # Replica count to restore to. Prefer the live spec, but if PMM is already at 0 (e.g. an
    # interrupted earlier restore) spec.replicas reads 0 and we'd never bring it back — so fall
    # back to the count stashed on a prior scale-down, then to PMM_SERVER_REPLICAS (default 3).
    PMM_SAVED_REPLICAS=$(kubectl get statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    if [ -z "${PMM_SAVED_REPLICAS}" ] || [ "${PMM_SAVED_REPLICAS}" = "0" ]; then
        PMM_SAVED_REPLICAS=$(kubectl get statefulset "${PMM_STATEFULSET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.metadata.annotations['restore.pmm.percona.com/original-replicas']}" 2>/dev/null || echo "")
    fi
    if [ -z "${PMM_SAVED_REPLICAS}" ] || [ "${PMM_SAVED_REPLICAS}" = "0" ]; then
        PMM_SAVED_REPLICAS="${PMM_SERVER_REPLICAS:-3}"
        log "WARN" "PMM ${PMM_STATEFULSET_NAME} already at 0 replicas; will restore to ${PMM_SAVED_REPLICAS} (override with PMM_SERVER_REPLICAS)"
    fi
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
    # The exported Secret carries the SOURCE namespace in its metadata, so applying it into a
    # different namespace fails ("the namespace from the object does not match"). Rewrite it to
    # the target namespace so the key is portable across namespaces (DR). Handles JSON + YAML.
    sed -e 's/"namespace"[ ]*:[ ]*"[^"]*"/"namespace": "'"${NAMESPACE}"'"/' \
        -e 's/^\([ ]*\)namespace:[ ]*.*/\1namespace: '"${NAMESPACE}"'/' \
        "${tmp}" > "${tmp}.ns" 2>/dev/null && mv "${tmp}.ns" "${tmp}"
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
            if [ "${S3_ENABLED}" = "true" ]; then
                log "INFO" "[PostgreSQL] [DRY RUN] rclone cat $(comp_path postgresql)/${db}.dump | pg_restore --clean --if-exists -d ${db} (in ${pg_pod})"
            else
                log "INFO" "[PostgreSQL] [DRY RUN] pg_restore --clean --if-exists -d ${db} < $(comp_path postgresql)/${db}.dump (in ${pg_pod})"
            fi
            continue
        fi
        rc=0
        log "INFO" "[PostgreSQL] Restoring database ${db} into ${pg_pod}..."
        local pr_out; pr_out=$(mktemp /tmp/pgrestore.XXXXXX 2>/dev/null || echo "/tmp/pgrestore.$$")
        if [ "${S3_ENABLED}" = "true" ]; then
            local uri="$(comp_path postgresql)/${db}.dump"
            local s3pod; pick_s3_client_pod >/dev/null || { log "ERROR" "[PostgreSQL] No pmm-backup sidecar to read the dump"; rm -f "${pr_out}"; return 1; }
            s3pod="${S3_CLIENT_POD}"
            # Verify the dump object exists and is non-empty BEFORE piping: the pipeline's
            # status is pg_restore's, so a missing object would otherwise surface only as
            # an empty-input pg_restore error indistinguishable from restore warnings.
            local dump_size
            dump_size=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${s3pod}" -c pmm-backup -- \
                rclone size --s3-no-check-bucket --json "${uri}" 2>/dev/null | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p')
            if ! [ "${dump_size:-0}" -gt 0 ] 2>/dev/null; then
                log "ERROR" "[PostgreSQL] dump missing or empty in S3: ${uri}"; fail=1; rm -f "${pr_out}"; continue
            fi
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${s3pod}" -c pmm-backup -- rclone cat --s3-no-check-bucket "${uri}" 2>>"${LOG_FILE}" \
                | timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${pg_pod}" -c database -- \
                  pg_restore --clean --if-exists -U postgres -d "${db}" >"${pr_out}" 2>&1 || rc=$?
        else
            local dump="$(comp_path postgresql)/${db}.dump"
            if [ ! -s "${dump}" ]; then log "ERROR" "[PostgreSQL] dump not found: ${dump}"; fail=1; rm -f "${pr_out}"; continue; fi
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${pg_pod}" -c database -- \
                pg_restore --clean --if-exists -U postgres -d "${db}" < "${dump}" >"${pr_out}" 2>&1 || rc=$?
        fi
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

    if [ "${DRY_RUN}" = "true" ]; then
        if [ "${S3_ENABLED}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN] kubectl exec ${ch_pod} -c clickhouse-backup -- clickhouse-backup restore_remote --env S3_BUCKET=${S3_BUCKET} --env S3_PATH=$(clickhouse_remote_key) --rm ${name}"
        else
            log "INFO" "[ClickHouse] [DRY RUN] kubectl exec ${ch_pod} -c clickhouse-backup -- sh -c 'tar -xzf $(comp_inpod clickhouse)/${name}.tar.gz -C /var/lib/clickhouse/backup && clickhouse-backup restore --rm ${name}'"
        fi
        return 0
    fi

    local rc=0
    if [ "${S3_ENABLED}" = "true" ]; then
        # clickhouse-backup has no "restore from <path>" argument — restore_remote <name>
        # looks the name up under the S3_BUCKET/S3_PATH baked into the sidecar env at pod
        # start. For a cross-namespace/DR restore those point at the TARGET instance's own
        # prefix, not the backup being restored. Redirect via the tool's own --env flag
        # ("override any environment variable via CLI parameter", verified on 2.8.0) using
        # --s3-bucket/--s3-prefix (the source); IAM access is bucket-wide already.
        log "INFO" "[ClickHouse] restore_remote --rm ${name} (from s3://${S3_BUCKET}/$(clickhouse_remote_key), in ${ch_pod})..."
        timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            clickhouse-backup restore_remote \
            --env "S3_BUCKET=${S3_BUCKET}" --env "S3_PATH=$(clickhouse_remote_key)" \
            --rm "${name}" >>"${LOG_FILE}" 2>&1 || rc=$?
    else
        local tar="$(comp_inpod clickhouse)/${name}.tar.gz"
        log "INFO" "[ClickHouse] untar ${tar} + restore --rm ${name} (in ${ch_pod})..."
        timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            sh -c "mkdir -p /var/lib/clickhouse/backup && tar -xzf '${tar}' -C /var/lib/clickhouse/backup && clickhouse-backup restore --rm '${name}'" >>"${LOG_FILE}" 2>&1 || rc=$?
    fi
    if [ ${rc} -ne 0 ]; then log "ERROR" "[ClickHouse] restore failed (exit ${rc})"; return 1; fi
    log "INFO" "[ClickHouse] Restore complete"
    return 0
}

################################################################################
# VictoriaMetrics — per vmstorage pod, scale to 0 then run vmrestore in a temp pod
# that mounts the (released) vmstorage-db PVC.  -src is s3:// or fs://<central>.
################################################################################
create_vm_restore_pod() {
    local restore_pod="$1" pvc="$2" image="$3"
    local sa_line="" central_mount="" central_vol="" env_block="" apply_out
    if [ "${S3_ENABLED}" = "true" ]; then
        sa_line="${TEMP_POD_SA_LINE}"
        # NOTE: no endpoint env here — vmrestore does not read endpoint env vars; the
        # custom endpoint is passed to it as the -customS3Endpoint flag instead.
        env_block="      env:
        - name: AWS_REGION
          value: \"${S3_REGION}\"${TEMP_POD_S3_KEYS_ENV}"
    else
        central_mount="        - name: central-backup-storage
          mountPath: ${SHARED_MOUNT_PATH}
          readOnly: true"
        central_vol="    - name: central-backup-storage
      persistentVolumeClaim:
        claimName: ${CENTRAL_BACKUP_PVC}"
    fi
    apply_out=$(mktemp /tmp/vmapply.XXXXXX 2>/dev/null || echo "/tmp/vmapply.$$")
    if ! kubectl apply -f - -n "${NAMESPACE}" >"${apply_out}" 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${restore_pod}
  labels:
    app.kubernetes.io/component: vm-restore-temp
  annotations:
    # These temp pods hold an RWO data PVC (vmstorage-db / pmm-storage) while its owner is
    # scaled down; a consolidation eviction mid-restore truncates that ordinal's data and
    # fails the run. Opt out of consolidation-driven disruption (Karpenter / EKS Auto Mode;
    # harmless elsewhere) — the s3 client pod already did, these two did not.
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
${sa_line}
  containers:
    - name: vmrestore
      image: ${image}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
${env_block}
      volumeMounts:
        - name: vmstorage-db
          mountPath: /vmstorage-data
${central_mount}
  volumes:
    - name: vmstorage-db
      persistentVolumeClaim:
        claimName: ${pvc}
${central_vol}
EOF
    then
        cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
        log "ERROR" "[VictoriaMetrics] Failed to create restore pod ${restore_pod} (PVC: ${pvc})"; return 1
    fi
    cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
    wait_for_pod_ready_by_name "${NAMESPACE}" "${restore_pod}" 300 || { log "ERROR" "[VictoriaMetrics] Restore pod ${restore_pod} not ready"; return 1; }
    return 0
}

# Deletes ANY temp restore pod (vm-restore-* and pmm-srv-restore-*): both paths share it,
# so the name must not imply otherwise — a VM-specific tweak here would silently leak a
# /srv pod still holding the RWO pmm-storage PVC and wedge PMM on Multi-Attach at scale-up.
delete_temp_restore_pod() {
    kubectl delete pod "$1" -n "${NAMESPACE}" --grace-period=10 --wait=false 2>&1 | append_to_log || true
    wait_for_pod_gone_by_name "${NAMESPACE}" "$1" 120 || true
}

# The backup stores per-pod dirs named after the SOURCE vmstorage pods
# (vmstorage-<src-release>-vmcluster-N). When restoring into a different release/namespace
# the TARGET pods are named differently (e.g. vmstorage-pmm-dr-pmm-ha-vmcluster-N), so we
# can't splice the target name into the path. Map by ORDINAL instead: pick the backup dir
# whose trailing -N matches the target pod's ordinal. Falls back to the target name for a
# same-release restore (or if the listing is unavailable).
vm_src_subdir_for_ord() {
    local ord="$1"
    store_list_dirs "$(comp_path victoriametrics)" 2>/dev/null | grep -E "\-${ord}\$" | head -1
}

# Count vmstorage ordinals present in the backup (source). Used to fail fast on a shard-count
# mismatch with the target before anything is scaled down: restoring an N-shard backup into a
# different number of target pods either silently drops the extra source shards (source > target)
# or runs the whole restore then fails on a missing ordinal (target > source).
# Count, with the LISTING's status preserved: `store_list_dirs … | grep -c` took its status
# from grep, which exits 1 when the count is zero, so an empty or unlistable source made the
# function itself return non-zero. At the restore call site that is an unguarded assignment
# under `set -e`, so the component died on the spot with nothing logged and PMM already at 0.
# Output is captured first, then counted (the same rule the storage layer states).
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
    vmrestore_image=$(get_vmrestore_image "${first_vm_pod}")
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
    local vm_endpoint_flag=""
    [ -n "${S3_ENDPOINT}" ] && vm_endpoint_flag="-customS3Endpoint=${S3_ENDPOINT}"
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
    kubectl delete pod -n "${NAMESPACE}" -l app.kubernetes.io/name=vmselect 2>&1 | append_to_log || true
    wait_for_pods_ready "${NAMESPACE}" "app.kubernetes.io/name=vmselect" "${original_vmselect}" 180 || log "WARN" "[VictoriaMetrics] vmselect not ready in time after bounce"

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
# PMM /srv — restored into each pmm-storage PVC via a TEMP pod while PMM is scaled
# to 0 (PMM comes up LAST, booting with /srv + the restored DBs already in place).
# The pmm-storage dir is ordinal-mapped to the backup's pmm-server dirs, so it is
# release-name independent (like VM). The HA raft dir (/srv/ha) is dropped so PMM
# re-bootstraps its memberlist cleanly in the target cluster (the backed-up raft
# names the SOURCE members, which don't exist here).
#   shared -> temp pod mounts the central vol; in-pod tar
#   s3     -> temp pod runs rclone (IRSA via the s3 SA) piped into tar
################################################################################
# Backup's pmm-server subdir for a target ordinal (trailing -N), release-name independent.
pmm_src_subdir_for_ord() {
    local ord="$1"
    store_list_dirs "$(comp_path pmm-server)" 2>/dev/null | grep -E "\-${ord}\$" | head -1
}

# Temp pod mounting a pmm-storage PVC at /srv (PMM is down, so the RWO PVC is free).
# Runs as root so it can replace any file + drop /srv/ha. shared: also mounts the central vol.
# s3: runs the pmm-backup image (rclone) under the s3 SA with env-auth (IRSA).
create_pmm_restore_pod() {
    local restore_pod="$1" pvc="$2" image="$3" sa_line="" central_mount="" central_vol="" env_block="" apply_out
    if [ "${S3_ENABLED}" = "true" ]; then
        sa_line="${TEMP_POD_SA_LINE}"
        env_block="      env:
$(render_rclone_s3_env)"
    else
        central_mount="        - name: central-backup-storage
          mountPath: ${SHARED_MOUNT_PATH}
          readOnly: true"
        central_vol="    - name: central-backup-storage
      persistentVolumeClaim:
        claimName: ${CENTRAL_BACKUP_PVC}"
    fi
    apply_out=$(mktemp /tmp/pmmapply.XXXXXX 2>/dev/null || echo "/tmp/pmmapply.$$")
    if ! kubectl apply -f - -n "${NAMESPACE}" >"${apply_out}" 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${restore_pod}
  labels:
    app.kubernetes.io/component: pmm-srv-restore-temp
  annotations:
    # These temp pods hold an RWO data PVC (vmstorage-db / pmm-storage) while its owner is
    # scaled down; a consolidation eviction mid-restore truncates that ordinal's data and
    # fails the run. Opt out of consolidation-driven disruption (Karpenter / EKS Auto Mode;
    # harmless elsewhere) — the s3 client pod already did, these two did not.
    karpenter.sh/do-not-disrupt: "true"
spec:
  restartPolicy: Never
${sa_line}
  securityContext:
    runAsUser: 0
    fsGroup: 0
  containers:
    - name: srv-restore
      image: ${image}
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
${env_block}
      volumeMounts:
        - name: pmm-storage
          mountPath: /srv
${central_mount}
  volumes:
    - name: pmm-storage
      persistentVolumeClaim:
        claimName: ${pvc}
${central_vol}
EOF
    then
        cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
        log "ERROR" "[PMMServer] Failed to create restore pod ${restore_pod} (PVC: ${pvc})"; return 1
    fi
    cat "${apply_out}" | append_to_log; rm -f "${apply_out}"
    wait_for_pod_ready_by_name "${NAMESPACE}" "${restore_pod}" 300 || { log "ERROR" "[PMMServer] Restore pod ${restore_pod} not ready"; return 1; }
    return 0
}

restore_pmm_server() {
    # NB: all locals initialised — script runs under `set -u`, so a bare `local x` then `[ -z "$x" ]`
    # would abort with "parameter not set".
    local sts="" replicas="" image="" i ord pvc src_subdir restore_pod rc restored=0 count=0
    sts="${PMM_STATEFULSET_NAME:-}"
    if [ -z "${sts}" ]; then sts=$(kubectl get statefulset -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); fi
    if [ -z "${sts}" ]; then log "ERROR" "[PMMServer] PMM StatefulSet not found"; return 1; fi
    replicas="${PMM_SAVED_REPLICAS:-}"
    if [ -z "${replicas}" ] || [ "${replicas}" = "0" ]; then replicas=$(kubectl get statefulset "${sts}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo ""); fi
    if [ -z "${replicas}" ] || [ "${replicas}" = "0" ]; then replicas="${PMM_SERVER_REPLICAS:-3}"; fi
    [ "${S3_ENABLED}" = "true" ] || resolve_central_backup_pvc || return 1
    if [ "${S3_ENABLED}" = "true" ]; then
        image=$(kubectl get statefulset "${sts}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="pmm-backup")].image}' 2>/dev/null || true)
    fi
    if [ -z "${image}" ]; then image=$(kubectl get statefulset "${sts}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true); fi
    if [ -z "${image}" ]; then image="percona/pmm-server:3.7.0"; fi

    i=0
    while [ "${i}" -lt "${replicas}" ]; do
        ord="${i}"; i=$((i + 1)); count=$((count + 1))
        pvc="pmm-storage-${sts}-${ord}"
        src_subdir=$(pmm_src_subdir_for_ord "${ord}")
        if [ "${DRY_RUN}" = "true" ]; then
            log "INFO" "[PMMServer] [DRY RUN] ord ${ord}: temp pod mounts ${pvc} at /srv; extract pmm-server/${src_subdir:-<dir ending -${ord}>}/srv.tar.gz then drop /srv/ha"
            continue
        fi
        if [ -z "${src_subdir}" ]; then log "WARN" "[PMMServer] No backup /srv dir for ordinal ${ord}; skipping"; continue; fi
        restore_pod="pmm-srv-restore-${sts}-${ord}"
        if ! create_pmm_restore_pod "${restore_pod}" "${pvc}" "${image}"; then delete_temp_restore_pod "${restore_pod}"; continue; fi
        rc=0
        if [ "${S3_ENABLED}" = "true" ]; then
            local uri="$(comp_path pmm-server)/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from S3..."
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -- \
                sh -c "rclone cat --s3-no-check-bucket '${uri}' | tar -xzf - -C /srv --no-same-owner && rm -rf /srv/ha" >>"${LOG_FILE}" 2>&1 || rc=$?
        else
            local tb="$(comp_inpod pmm-server)/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from ${tb}..."
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -- \
                sh -c "tar -xzf '${tb}' -C /srv --no-same-owner && rm -rf /srv/ha" >>"${LOG_FILE}" 2>&1 || rc=$?
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
# 9. Retention — delete every component path for ids older than BACKUP_RETENTION days.
#
# Age comes from the id's own timestamp (see backup_id_epoch), not from object mtimes.
#
# SCOPE: every component path for an expired id — <component>/<id>/ for each entry in
# BACKUP_COMPONENTS — plus its manifest. Works on both targets.
#
# A backup is a correlation across component paths sharing an id, not a directory, so
# atomicity is this function's job rather than the layout's: all of an id's components go or
# none do. Two rules follow.
#   * The MANIFEST IS DELETED LAST. It is the only record of what the backup contained
#     (including the ClickHouse backup name), so removing it first would turn a retryable
#     partial delete into debris nothing can identify or finish cleaning.
#   * A partial failure keeps the manifest and reports the id as still present, so the next
#     run retries it instead of leaving orphaned component data behind an absent index.
#
# Guardrails, because a bug here destroys backups irreversibly (this bucket has no
# versioning, so there is no undo):
#   * retention 0 refuses THIS sweep — note the local find sweeps in cleanup_old_backups
#     still run with -mtime +0, so retention 0 remains destructive in shared mode; the
#     refusal here is not a global safety net
#   * the 'latest' pointer object is never deleted, and neither is the id it names, even
#     if that id is past the cutoff: a stale pointer is recoverable, a dangling one is not
#   * ids whose timestamp cannot be parsed are skipped and logged, never deleted — the
#     tool must not remove what it cannot identify
#   * a sweep that would delete EVERY backup is refused; that is a bug, not an intent
#   * deletions per sweep are capped, so a parsing regression can only ever destroy a
#     bounded amount before someone notices
################################################################################
S3_PRUNE_MAX_PER_RUN="${S3_PRUNE_MAX_PER_RUN:-50}"
# Same reasoning as BACKUP_RETENTION: this drives destruction, so it must be a usable
# number. `[ 3 -ge abc ]` returns 2 (not false), so a non-numeric value does not merely
# misbehave — it silently disables the cap entirely and the sweep purges everything it
# classified. Fall back to the default rather than aborting a run that already succeeded.
case "${S3_PRUNE_MAX_PER_RUN}" in
    ''|*[!0-9]*) S3_PRUNE_MAX_PER_RUN=50 ;;
    *) S3_PRUNE_MAX_PER_RUN=$(echo "${S3_PRUNE_MAX_PER_RUN}" | sed 's/^0*\([0-9]\)/\1/') ;;
esac
# Whole-sweep wall clock. Retention runs after a successful backup, inside cmd_backup's lock
# window, and the CronJob trigger has its own activeDeadlineSeconds — so an unbounded sweep
# (50 purges x KUBECTL_EXEC_TIMEOUT would be hours) gets the Job killed, reports the whole
# run failed, and leaves the next run blocked on locks this one still holds.
S3_PRUNE_MAX_SECONDS="${S3_PRUNE_MAX_SECONDS:-900}"
case "${S3_PRUNE_MAX_SECONDS}" in
    ''|*[!0-9]*) S3_PRUNE_MAX_SECONDS=900 ;;
esac

prune_expired_backups() {
    local ids cutoff now latest_id kept=0 expired=0 purged=0 attempted=0 skipped=0 id ts _owner="" _id_comps=""
    local list_rc=0 started

    if [ "${BACKUP_RETENTION}" -lt 1 ]; then
        log "WARN" "[Retention] --retention ${BACKUP_RETENTION} would expire every backup including this run; refusing to prune S3"
        return 0
    fi

    # The sweep cannot tell whose backup an id is — it deletes by age under THIS prefix. Two
    # installs sharing a prefix would delete each other's backups, so say the prefix out loud
    # on every run: it is the one line that makes a misconfigured shared prefix visible in the
    # log before the deletes start.
    log "INFO" "[Retention] Scope: $(backup_root_display)/ (must be unique per install — retention deletes by age and cannot tell whose backup an id is)"
    now=$(date +%s); started="${now}"
    # +1 day so one --retention N means the same window as the `find -mtime +N` sweeps in this
    # same function: -mtime truncates to whole days and matches age > N, i.e. it deletes at
    # N+1 days. Without this, "retain 1 day" purged yesterday's backup (and its manifest and
    # encryption key) at 25 hours while the local markers survived to 48.
    cutoff=$((now - (BACKUP_RETENTION + 1) * 86400))
    log "INFO" "[Retention] Pruning backups older than ${BACKUP_RETENTION}d (before $(date -d "@${cutoff}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "epoch ${cutoff}")) under $(backup_root_display)/"

    # catalog_ids returns its own status (see the catalog helpers): a failed listing must not
    # read as "no backups", or the sweep silently stops pruning while logging that all is
    # well — the exact condition this whole feature exists to fix.
    ids=$(catalog_ids) || list_rc=$?
    if [ "${list_rc}" -ne 0 ]; then
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
        # A read can also fail simply because the pointer is not there. Distinguish by asking
        # whether it exists at all — capturing the probe's OWN status, because
        # `lsf ... | grep -q .` would take the pipeline's status from grep and a failed probe
        # would look identical to "no pointer", silently disabling the protection this block
        # exists to provide. (Same defect the listing above documents; easy to reintroduce, so
        # both are written the same deliberate way.)
        # Through the layer, both targets. The old shared arm used `[ -e ]`, which cannot
        # distinguish EACCES from ENOENT, and hardcoded probe_rc=0 so the refuse-to-prune arm
        # below was dead code in shared mode.
        local probe_rc=0 probe_out=""
        probe_out=$(store_list_files "$(dirname "$(latest_path)")" 2>/dev/null) || probe_rc=$?
        if [ "${probe_rc}" -ne 0 ]; then
            log "WARN" "[Retention] Could not read 'latest' (rc ${latest_rc}) and could not probe whether it exists (rc ${probe_rc}); refusing to prune rather than risk orphaning it"
            return 0
        fi
        if printf '%s\n' "${probe_out}" | grep -Fxq "latest"; then
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
    local expired_ids="" kept_parseable=0
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
            kept=$((kept + 1)); kept_parseable=$((kept_parseable + 1)); continue
        fi
        if [ -n "${latest_id}" ] && [ "${id}" = "${latest_id}" ]; then
            log "WARN" "[Retention] '${id}' is past the cutoff but is what 'latest' points at — keeping it"
            kept=$((kept + 1)); kept_parseable=$((kept_parseable + 1)); continue
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
        log "ERROR" "[Retention] Refusing to prune: all ${expired} parseable backup(s) are past the cutoff, leaving no known-good backup (${skipped} unparseable entr(y|ies) do not count). Check --retention (${BACKUP_RETENTION}d) and the system clock."
        return 0
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
        attempted=$((attempted + 1))
        if [ "${DRY_RUN}" = "true" ]; then
            for _c in ${BACKUP_COMPONENTS}; do
                log "INFO" "[Retention] [DRY RUN] would purge $(comp_display "${_c}" "${id}")"
            done
            log "INFO" "[Retention] [DRY RUN] would then delete $(manifest_display "${id}")"
            purged=$((purged + 1))
            continue
        fi
        # All of an id's components, then the manifest LAST — the manifest is the only record
        # of what this backup held, so losing it first strands whatever the failure left.
        # Only the components this backup actually holds. Purging all five unconditionally
        # cost two failed execs plus a client-pod re-resolution per absent component, wrote a
        # scary rclone error per miss, and burned the sweep's time budget on nothing.
        _id_comps=$(catalog_manifest "${id}" 2>/dev/null | jq -r '.components | keys[]' 2>/dev/null || true)
        [ -n "${_id_comps}" ] || _id_comps="${BACKUP_COMPONENTS}"
        log "INFO" "[Retention] Purging ${id} ($(printf '%s' "${_id_comps}" | tr '\n' ' ')) ..."
        _comp_fail=0
        for _c in ${_id_comps}; do
            store_delete_prefix "$(comp_path "${_c}" "${id}")" || _comp_fail=$((_comp_fail + 1))
        done
        if [ "${_comp_fail}" -ne 0 ]; then
            log "WARN" "[Retention] ${id}: ${_comp_fail} component path(s) could not be purged — KEEPING the manifest so the next run retries this id rather than orphaning what is left"
        elif store_delete_object "$(manifest_path "${id}")"; then
            purged=$((purged + 1))
        else
            log "WARN" "[Retention] ${id}: component data purged but the manifest remains; the next run will retry it"
        fi
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
        log "INFO" "[DRY RUN]   \$ find ${BACKUP_DIR}/logs -maxdepth 1 -type f -name 'backup_*.log' -mtime +${BACKUP_RETENTION} -delete"
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
    find "${BACKUP_DIR}/logs" -maxdepth 1 -type f -name "backup_*.log" -mtime +${BACKUP_RETENTION} \
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

# Write per-component Prometheus metrics to a .prom file (atomic via mv).
#
# Never fails the run. This is called from cmd_backup as a plain statement under `set -e`,
# AFTER every component, the manifest and retention have already succeeded — so an
# unguarded mkdir/cat/mv turned a full, restorable backup into a run that died with no
# summary and a non-zero exit (a read-only or full metrics volume is enough; METRICS_DIR is
# not derived from --backup-dir, so it can be absent on an ad-hoc run). Reporting a good
# backup as failed is far worse than losing a gauge, and the restore-side writer already
# degrades this way.
write_component_metrics() {
    local component=$1
    local success=$2
    local duration=$3
    local size_bytes=$4
    local timestamp=$(date +%s)

    local metrics_dir="${METRICS_DIR}"
    if ! mkdir -p "${metrics_dir}" 2>/dev/null; then
        log "WARN" "Metrics dir ${metrics_dir} is not writable; falling back to /tmp (these metrics will NOT be scraped)"
        metrics_dir="/tmp/.backup_metrics"
        mkdir -p "${metrics_dir}" 2>/dev/null || { log "WARN" "Could not write ${component} metrics anywhere; continuing"; return 0; }
    fi

    local tmp_file="${metrics_dir}/.${component}_metrics.prom.tmp"
    local target_file="${metrics_dir}/${component}_metrics.prom"

    if ! cat > "${tmp_file}" <<EOF
# HELP pmm_ha_backup_last_success Whether the last backup succeeded (1=yes, 0=no)
# TYPE pmm_ha_backup_last_success gauge
pmm_ha_backup_last_success{component="${component}",namespace="${NAMESPACE}"} ${success}
# HELP pmm_ha_backup_last_timestamp_seconds Unix timestamp of backup completion
# TYPE pmm_ha_backup_last_timestamp_seconds gauge
pmm_ha_backup_last_timestamp_seconds{component="${component}",namespace="${NAMESPACE}"} ${timestamp}
# HELP pmm_ha_backup_last_duration_seconds Backup duration in seconds
# TYPE pmm_ha_backup_last_duration_seconds gauge
pmm_ha_backup_last_duration_seconds{component="${component}",namespace="${NAMESPACE}"} ${duration}
# HELP pmm_ha_backup_last_size_bytes Backup size in bytes
# TYPE pmm_ha_backup_last_size_bytes gauge
pmm_ha_backup_last_size_bytes{component="${component}",namespace="${NAMESPACE}"} ${size_bytes}
EOF
    then
        log "WARN" "Could not write ${component} metrics to ${tmp_file}; continuing"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 0
    fi

    if mv "${tmp_file}" "${target_file}" 2>/dev/null; then
        log "INFO" "Metrics written to ${target_file}"
    else
        log "WARN" "Could not publish ${component} metrics to ${target_file}; continuing"
        rm -f "${tmp_file}" 2>/dev/null || true
    fi
    return 0
}

write_restore_metrics() {
    local in_progress="$1" phase="$2" last_success="${3:-0}" last_ts="${4:-0}" last_dur="${5:-0}"
    local pg_ok="${6:-0}" ch_ok="${7:-0}" vm_ok="${8:-0}" enc_ok="${9:-0}" pmm_ok="${10:-0}"
    local metrics_dir="${METRICS_DIR}"
    if ! mkdir -p "${metrics_dir}" 2>/dev/null; then
        metrics_dir="/tmp/.restore_metrics"; mkdir -p "${metrics_dir}" 2>/dev/null || return 0
    fi
    local tmp_file="${metrics_dir}/.restore_metrics.prom.tmp" target_file="${metrics_dir}/restore_metrics.prom"
    cat > "${tmp_file}" <<EOF
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
pmm_ha_restore_component_success{namespace="${NAMESPACE}",component="postgresql"} ${pg_ok}
pmm_ha_restore_component_success{namespace="${NAMESPACE}",component="clickhouse"} ${ch_ok}
pmm_ha_restore_component_success{namespace="${NAMESPACE}",component="victoriametrics"} ${vm_ok}
pmm_ha_restore_component_success{namespace="${NAMESPACE}",component="pmm_server"} ${pmm_ok}
pmm_ha_restore_component_success{namespace="${NAMESPACE}",component="encryption_key"} ${enc_ok}
EOF
    mv "${tmp_file}" "${target_file}" 2>/dev/null || true
}
################################################################################
# Main Orchestration
################################################################################

# One place decides what "this component was backed up" means, keeping the counters, the
# overall verdict and the failure log in step instead of repeating the same fifteen lines
# per component. Gate on the success FLAG as well as the return code: multi-pod components
# (VM/PMM) return 0 on PARTIAL success but only set *_BACKUP_SUCCESS=true on FULL success,
# so a partial backup must not mark the run complete. Returns 0 when the component counts
# as backed up.
#
# The counter/verdict assignments update cmd_backup's locals, which sh's dynamic scoping
# makes the variables in scope here — the same mechanism ch_query relies on to read its
# caller's ch_pod/ch_user/ch_pass. Verified on bash, dash and BusyBox ash.
record_backup_result() {   # <label> <rc> <success-flag>
    if [ "$2" -eq 0 ] && [ "$3" = "true" ]; then
        components_backed_up=$((components_backed_up + 1))
        log "INFO" ""
        return 0
    fi
    components_failed=$((components_failed + 1))
    all_success=false
    log "ERROR" "[$1] ✗ Backup failed"
    log "INFO" ""
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
        LOCK_COMPONENTS=""
        [ "${BACKUP_CLICKHOUSE}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} clickhouse"
        [ "${BACKUP_PMM_SERVER}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} pmm-server"
        [ "${BACKUP_POSTGRESQL}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} postgresql"
        [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} victoriametrics"
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
    fi

    echo ""

    log "INFO" "Starting backup (${TIMESTAMP})"
    [ "${DRY_RUN}" != "true" ] && log "INFO" "Log file: ${LOG_FILE}"
    
    # Run pre-flight checks
    if ! preflight_checks backup; then
        exit 1
    fi
    # Resolve the S3 client pod once, here in the main shell, so the many store_* reads that
    # run inside command substitutions inherit it instead of re-discovering per call.
    resolve_s3_client_pod
    log "INFO" "Namespace: ${NAMESPACE}"
    [ "${BACKUP_POSTGRESQL}" = "true" ] && log "INFO" "Components: PostgreSQL"
    [ "${BACKUP_CLICKHOUSE}" = "true" ] && log "INFO" "Components: ClickHouse"
    [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && log "INFO" "Components: VictoriaMetrics"
    [ "${BACKUP_PMM_SERVER}" = "true" ] && log "INFO" "Components: PMM Server (/srv)"
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
    local pg_backed_up=false
    local ch_backed_up=false
    local vm_backed_up=false
    local pmm_backed_up=false
    local _comp_rc=0

    # PostgreSQL Backup
    if [ "${BACKUP_POSTGRESQL}" = "true" ]; then
        if backup_postgresql; then _comp_rc=0; else _comp_rc=$?; fi
        if record_backup_result "PostgreSQL" "${_comp_rc}" "${PG_BACKUP_SUCCESS}"; then pg_backed_up=true; fi
    else
        log "INFO" "[PostgreSQL] ⊘ Backup skipped"
    fi
    
    # ClickHouse Backup
    if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
        if backup_clickhouse; then _comp_rc=0; else _comp_rc=$?; fi
        if record_backup_result "ClickHouse" "${_comp_rc}" "${CH_BACKUP_SUCCESS}"; then ch_backed_up=true; fi
    else
        log "INFO" "[ClickHouse] ⊘ Backup skipped"
    fi
    
    # VictoriaMetrics Backup
    if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
        if backup_victoriametrics; then _comp_rc=0; else _comp_rc=$?; fi
        if record_backup_result "VictoriaMetrics" "${_comp_rc}" "${VM_BACKUP_SUCCESS}"; then vm_backed_up=true; fi
    else
        log "INFO" "[VictoriaMetrics] ⊘ Backup skipped"
    fi
    
    # PMM Server /srv Backup
    if [ "${BACKUP_PMM_SERVER}" = "true" ]; then
        if backup_pmm_server; then _comp_rc=0; else _comp_rc=$?; fi
        if record_backup_result "PMMServer" "${_comp_rc}" "${PMM_BACKUP_SUCCESS}"; then pmm_backed_up=true; fi
    else
        log "INFO" "[PMMServer] ⊘ Backup skipped"
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
    # ${SHARED_MOUNT_PATH} RWX volume). Bytes never stream through this orchestrator.

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

    # Prune old backups ONLY when this run fully succeeded. Running the age-based sweep after a
    # failed run (e.g. a component down for longer than the retention window) would keep deleting
    # older-than-N-days backups while producing no new good one — eroding retention toward zero
    # restorable backups. Skipping on failure preserves the last known-good backups.
    if [ "${all_success}" = "true" ]; then
        cleanup_old_backups
    else
        log "INFO" "=== Skipping retention cleanup: backup did not fully succeed (preserving existing backups) ==="
    fi
    log "INFO" ""
    
    # Write per-component metrics for vmagent scraping
    if [ "${DRY_RUN}" != "true" ]; then
        if [ "${BACKUP_POSTGRESQL}" = "true" ]; then
            write_component_metrics "postgresql" \
                "$([ "${pg_backed_up}" = "true" ] && echo 1 || echo 0)" \
                "${PG_BACKUP_DURATION:-0}" \
                "${PG_BACKUP_SIZE_BYTES:-0}"
        fi
        if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
            write_component_metrics "clickhouse" \
                "$([ "${ch_backed_up}" = "true" ] && echo 1 || echo 0)" \
                "${CH_BACKUP_DURATION:-0}" \
                "${CH_BACKUP_SIZE_BYTES:-0}"
        fi
        if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
            write_component_metrics "victoriametrics" \
                "$([ "${vm_backed_up}" = "true" ] && echo 1 || echo 0)" \
                "${VM_BACKUP_DURATION:-0}" \
                "${VM_BACKUP_TOTAL_BYTES:-0}"
        fi
        if [ "${BACKUP_PMM_SERVER}" = "true" ]; then
            write_component_metrics "pmm-server" \
                "$([ "${pmm_backed_up}" = "true" ] && echo 1 || echo 0)" \
                "${PMM_BACKUP_DURATION:-0}" \
                "${PMM_BACKUP_TOTAL_BYTES:-0}"
        fi
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
    
    # Human-readable totals for the summary (left empty when 0 so it shows 'unknown').
    local vm_size_str="" pmm_size_str=""
    [ "${VM_BACKUP_TOTAL_BYTES}" -gt 0 ] 2>/dev/null && vm_size_str="$(human_bytes "${VM_BACKUP_TOTAL_BYTES}")"
    [ "${PMM_BACKUP_TOTAL_BYTES}" -gt 0 ] 2>/dev/null && pmm_size_str="$(human_bytes "${PMM_BACKUP_TOTAL_BYTES}")"

    # Final Summary
    log "INFO" ""
    log "INFO" "================================================================================"
    log "INFO" "Backup Summary"
    log "INFO" "================================================================================"
    
    # PostgreSQL
    if [ "${BACKUP_POSTGRESQL}" = "true" ]; then
        if [ "${pg_backed_up}" = "true" ]; then
            log "INFO" "  ✓ PostgreSQL:      OK | ${PG_BACKUP_SIZE} | ${PG_BACKUP_DURATION}s | pg_dump (${PG_DUMP_DBS})"
            log "INFO" "    Location:        ${PG_BACKUP_LOCATION}"
        else
            log "ERROR" "  ✗ PostgreSQL:      Failed"
        fi
    else
        log "INFO" "  ⊘ PostgreSQL:      Skipped"
    fi
    
    # ClickHouse
    if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
        if [ "${ch_backed_up}" = "true" ]; then
            log "INFO" "  ✓ ClickHouse:      OK | ${CH_BACKUP_SIZE} | ${CH_BACKUP_DURATION}s | clickhouse-backup ${CH_BACKUP_TYPE}"
            log "INFO" "    Location:        ${CH_BACKUP_LOCATION}"
        else
            log "ERROR" "  ✗ ClickHouse:      Failed"
        fi
    else
        log "INFO" "  ⊘ ClickHouse:      Skipped"
    fi
    
    # VictoriaMetrics
    if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
        if [ "${vm_backed_up}" = "true" ]; then
            log "INFO" "  ✓ VictoriaMetrics: OK | ${vm_size_str:-unknown} total | ${VM_BACKUP_DURATION}s | vmbackup (${VM_BACKUP_POD_COUNT} pods)"
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                log "INFO" "    Location:        $(comp_display victoriametrics)/<pod>/"
            else
                log "INFO" "    Location:        $(comp_inpod victoriametrics)/<pod>/ (per pod, central RWX)"
            fi
        else
            log "ERROR" "  ✗ VictoriaMetrics: Failed"
        fi
    else
        log "INFO" "  ⊘ VictoriaMetrics: Skipped"
    fi

    # PMM Server /srv
    if [ "${BACKUP_PMM_SERVER}" = "true" ]; then
        if [ "${pmm_backed_up}" = "true" ]; then
            log "INFO" "  ✓ PMM Server:      OK | ${pmm_size_str:-unknown} total | ${PMM_BACKUP_DURATION}s | ${PMM_SRV_PATH} tar.gz (${PMM_BACKUP_POD_COUNT} pods)"
            if [ "${BACKUP_TARGET}" = "s3" ]; then
                log "INFO" "    Location:        $(comp_display pmm-server)/<pod>/srv.tar.gz"
            else
                log "INFO" "    Location:        $(comp_inpod pmm-server)/<pod>/srv.tar.gz (central RWX)"
            fi
        else
            log "ERROR" "  ✗ PMM Server:      Failed"
        fi
    else
        log "INFO" "  ⊘ PMM Server:      Skipped"
    fi

    # Encryption key (only shown when PostgreSQL is being backed up)
    if [ "${encryption_status}" != "skipped" ]; then
        if [ "${encryption_status}" = "success" ]; then
            log "INFO" "  ✓ Encryption Key:  OK | Kubernetes Secret"
        elif [ "${encryption_status}" = "not_found" ]; then
            log "INFO" "  ○ Encryption Key:  Not found (encryption not configured)"
        else
            log "WARN" "  ⚠ Encryption Key:  Failed (non-critical)"
        fi
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
# Restore main flow
################################################################################

cmd_restore() {
    log "INFO" "================================================================================"
    log "INFO" "PMM-HA Restore Orchestrator"
    log "INFO" "================================================================================"
    log "INFO" "Namespace: ${NAMESPACE}  Target: ${BACKUP_TARGET}  Log: ${LOG_FILE}"

    if ! preflight_checks restore; then exit 1; fi

    # s3 mode: bring up the dedicated rclone client pod BEFORE anything reads S3 — the
    # pmm-backup sidecar disappears with the PMM scale-down (and after a failed restore,
    # a re-run starts with PMM already at 0, so even load_manifest needs this).
    if [ "${S3_ENABLED}" = "true" ] && [ "${DRY_RUN}" != "true" ]; then
        # EXIT just cleans up; INT/TERM must also EXIT. A bare `trap restore_cleanup INT TERM`
        # runs the handler in ash/dash and then RESUMES the restore — now with its S3 client
        # pod deleted and every component lock released, so subsequent reads fail, temp pods
        # are killed mid-write into RWO PVCs, and a concurrent run can take the freed locks
        # and write the same databases. (The backup path already learned this; see cmd_backup.)
        # restore_cleanup is idempotent — pod deletes use --ignore-not-found and lock release
        # is ownership-checked — so the EXIT trap re-running it after the signal handler exits
        # is harmless.
        trap restore_cleanup EXIT
        trap 'restore_cleanup; exit 130' INT
        trap 'restore_cleanup; exit 143' TERM
        if ! create_s3_client_pod; then exit 1; fi
    fi

    if ! load_manifest; then exit 1; fi
    select_default_components

    log "INFO" "Components: PG=${RESTORE_POSTGRESQL}(${MF_PG_STATUS:-none}) CH=${RESTORE_CLICKHOUSE}(${MF_CH_STATUS:-none}) VM=${RESTORE_VICTORIAMETRICS}(${MF_VM_STATUS:-none}) PMM=${RESTORE_PMM_SERVER}(${MF_PMM_STATUS:-none}) Enc=${RESTORE_ENCRYPTION_KEY}(${MF_ENC_STATUS:-none})"

    # An explicitly requested component that this backup does not carry as 'success' is a
    # hard error BEFORE anything is touched: silently skipping it (old behavior) scaled PMM
    # down/up and exited 0 without restoring the one thing the user asked for.
    if [ "${EXPLICIT_SELECTION}" = "true" ]; then
        local _bad=""
        [ "${RESTORE_POSTGRESQL}" = "true" ]      && [ "${MF_PG_STATUS}" != "success" ]  && _bad="${_bad} postgresql(${MF_PG_STATUS:-absent})"
        [ "${RESTORE_CLICKHOUSE}" = "true" ]      && [ "${MF_CH_STATUS}" != "success" ]  && _bad="${_bad} clickhouse(${MF_CH_STATUS:-absent})"
        [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && [ "${MF_VM_STATUS}" != "success" ]  && _bad="${_bad} victoriametrics(${MF_VM_STATUS:-absent})"
        [ "${RESTORE_PMM_SERVER}" = "true" ]      && [ "${MF_PMM_STATUS}" != "success" ] && _bad="${_bad} pmm-server(${MF_PMM_STATUS:-absent})"
        [ "${RESTORE_ENCRYPTION_KEY}" = "true" ]  && [ "${MF_ENC_STATUS}" != "success" ] && _bad="${_bad} encryption(${MF_ENC_STATUS:-absent})"
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

    if [ "${DRY_RUN}" != "true" ] && [ "${FORCE}" != "true" ]; then
        if [ -t 0 ]; then
            log "INFO" "Restore will scale PMM down, restore data, then scale PMM back up only if all succeed."
            printf 'Press Enter to continue or Ctrl+C to abort... '
            # EOF (Ctrl+D) must ABORT a destructive restore, not be read as consent.
            read -r _ || { echo; log "INFO" "Aborted (EOF at confirmation prompt)."; exit 1; }
        else
            log "ERROR" "Refusing a destructive restore non-interactively. Re-run with --force."; exit 1
        fi
    fi

    if [ "${DRY_RUN}" != "true" ]; then
        # Locks shared with the backup path (same names, same alphabetical order).
        # pmm-server is unconditional: every restore scales PMM down/up regardless of
        # which components were selected.
        LOCK_COMPONENTS=""
        [ "${RESTORE_CLICKHOUSE}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} clickhouse"
        LOCK_COMPONENTS="${LOCK_COMPONENTS} pmm-server"
        [ "${RESTORE_POSTGRESQL}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} postgresql"
        [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && LOCK_COMPONENTS="${LOCK_COMPONENTS} victoriametrics"
        # As above: the signal handlers must EXIT, or ash/dash resumes the restore with the
        # locks already released and the temp pods already deleted.
        trap restore_cleanup EXIT
        trap 'restore_cleanup; exit 130' INT
        trap 'restore_cleanup; exit 143' TERM
        acquire_locks
    fi
    RESTORE_START_TIME=$(date +%s)

    # 1. Encryption key first — abort if it fails (can't decrypt restored data otherwise).
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "encryption_key" 0 0 0 0 0 0 0
    if [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${MF_ENC_STATUS}" = "success" ]; then
        restore_encryption_key && ENCRYPTION_KEY_OK=true
    else
        [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && log "WARN" "Encryption key requested but not in this backup"
        ENCRYPTION_KEY_OK=true
    fi
    # NOT overridable with --force. --force is mandatory for every non-interactive run (this
    # function refuses a destructive restore without a TTY otherwise) and is what the
    # documented `kubectl exec ... --force` command line uses, so honouring it here would
    # disable this gate for ALL automation — and since ENCRYPTION_KEY_OK was also missing
    # from the final all_ok, the run then printed "Restore completed successfully" and
    # exited 0 over PostgreSQL data that cannot be decrypted. Aborting here is free: nothing
    # has been scaled down or written yet. --skip-encryption-key remains the explicit,
    # narrow override, mirroring the pre-flight gate's reasoning.
    if [ "${ENCRYPTION_KEY_OK}" != "true" ]; then
        log "ERROR" "Encryption key restore FAILED. Aborting before anything is changed (PMM is still running)."
        log "ERROR" "  Restored PostgreSQL data would not be decryptable without this key."
        log "ERROR" "  Fix the cause, or re-run with --skip-encryption-key to proceed deliberately without it."
        write_restore_metrics 0 "idle" 0 "$(date +%s)" 0 0 0 0 0; exit 1
    fi

    # 2. Scale PMM down FIRST so nothing writes the DBs during restore and the pmm-storage PVCs
    #    are free for the /srv restore. PMM is brought up LAST (after all data is restored), so it
    #    boots against the restored DBs + /srv instead of migrating a half-restored database.
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "scale_down_pmm" 0 0 0 0 0 0 0
    if ! scale_down_pmm; then log "ERROR" "Failed to scale down PMM; aborting."; write_restore_metrics 0 "idle" 0 "$(date +%s)" 0 0 0 0 0; exit 1; fi

    # 3. DB components (PMM down).
    local pg_ret=0 ch_ret=0 vm_ret=0 tmpdir
    tmpdir=$(mktemp -d 2>/dev/null || echo "/tmp/.restore_$$"); mkdir -p "${tmpdir}" 2>/dev/null || true
    local do_pg=false do_ch=false do_vm=false
    [ "${RESTORE_POSTGRESQL}" = "true" ] && [ "${MF_PG_STATUS}" = "success" ] && do_pg=true
    [ "${RESTORE_CLICKHOUSE}" = "true" ] && [ "${MF_CH_STATUS}" = "success" ] && do_ch=true
    [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && [ "${MF_VM_STATUS}" = "success" ] && do_vm=true

    if [ "${PARALLEL}" = "true" ] && [ "${DRY_RUN}" != "true" ]; then
        write_restore_metrics 1 "components" 0 0 0 0 0 0 0
        # Reset the EXIT trap in each subshell so a child can't release locks; capture
        # status via if/else so set -e can't mask a failure as success.
        [ "${do_pg}" = "true" ] && ( trap - EXIT INT TERM; if restore_postgresql; then echo 0 > "${tmpdir}/pg_ret"; else echo 1 > "${tmpdir}/pg_ret"; fi ) &
        [ "${do_ch}" = "true" ] && ( trap - EXIT INT TERM; if restore_clickhouse; then echo 0 > "${tmpdir}/ch_ret"; else echo 1 > "${tmpdir}/ch_ret"; fi ) &
        [ "${do_vm}" = "true" ] && ( trap - EXIT INT TERM; if restore_victoriametrics; then echo 0 > "${tmpdir}/vm_ret"; else echo 1 > "${tmpdir}/vm_ret"; fi ) &
        wait
        # A subshell that died without writing its rc file (OOM-kill, unwritable tmpdir)
        # must count as FAILED — the old [ -f ] && guard silently defaulted it to success.
        [ "${do_pg}" = "true" ] && { pg_ret=$(cat "${tmpdir}/pg_ret" 2>/dev/null || echo 1); : "${pg_ret:=1}"; }
        [ "${do_ch}" = "true" ] && { ch_ret=$(cat "${tmpdir}/ch_ret" 2>/dev/null || echo 1); : "${ch_ret:=1}"; }
        [ "${do_vm}" = "true" ] && { vm_ret=$(cat "${tmpdir}/vm_ret" 2>/dev/null || echo 1); : "${vm_ret:=1}"; }
    else
        [ "${do_pg}" = "true" ] && { [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "postgresql" 0 0 0 0 0 0 0; restore_postgresql || pg_ret=1; }
        [ "${do_ch}" = "true" ] && { [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "clickhouse" 0 0 0 0 0 0 0; restore_clickhouse || ch_ret=1; }
        [ "${do_vm}" = "true" ] && { [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "victoriametrics" 0 0 0 0 0 0 0; restore_victoriametrics || vm_ret=1; }
    fi
    rm -rf "${tmpdir}" 2>/dev/null || true
    [ "${do_pg}" = "true" ] && [ $pg_ret -eq 0 ] && POSTGRESQL_OK=true
    [ "${do_ch}" = "true" ] && [ $ch_ret -eq 0 ] && CLICKHOUSE_OK=true
    [ "${do_vm}" = "true" ] && [ $vm_ret -eq 0 ] && VICTORIAMETRICS_OK=true

    # 4. PMM /srv into the (released) pmm-storage PVCs via temp pods — PMM still down.
    if [ "${RESTORE_PMM_SERVER}" = "true" ] && [ "${MF_PMM_STATUS}" = "success" ]; then
        [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "pmm_server" 0 0 0 0 0 0 0
        restore_pmm_server && PMM_SERVER_OK=true
    else
        [ "${RESTORE_PMM_SERVER}" = "true" ] && log "WARN" "PMM /srv requested but not in this backup"
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
    write_restore_metrics 1 "verification" 0 0 0 0 0 0 0
    restore_verification

    local all_ok=true
    [ "${do_pg}" = "true" ] && [ "${POSTGRESQL_OK}" != "true" ] && all_ok=false
    [ "${do_ch}" = "true" ] && [ "${CLICKHOUSE_OK}" != "true" ] && all_ok=false
    [ "${do_vm}" = "true" ] && [ "${VICTORIAMETRICS_OK}" != "true" ] && all_ok=false
    [ "${RESTORE_PMM_SERVER}" = "true" ] && [ "${MF_PMM_STATUS}" = "success" ] && [ "${PMM_SERVER_OK}" != "true" ] && all_ok=false
    # The key belongs in the verdict too. It is restored first and now aborts the run on
    # failure, so this is unreachable in practice — which is exactly why it is cheap
    # insurance: leaving it out is what let a --force run report success over undecryptable
    # data. ENCRYPTION_KEY_OK is true when the key was not selected, so this is a no-op then.
    [ "${ENCRYPTION_KEY_OK}" != "true" ] && all_ok=false

    local end_ts duration success=0
    end_ts=$(date +%s); duration=$((end_ts - RESTORE_START_TIME))
    [ "${all_ok}" = "true" ] && success=1
    local pg_ok=0 ch_ok=0 vm_ok=0 enc_ok=0 pmm_ok=0
    [ "${POSTGRESQL_OK}" = "true" ] && pg_ok=1; [ "${CLICKHOUSE_OK}" = "true" ] && ch_ok=1
    [ "${VICTORIAMETRICS_OK}" = "true" ] && vm_ok=1; [ "${ENCRYPTION_KEY_OK}" = "true" ] && enc_ok=1
    [ "${PMM_SERVER_OK}" = "true" ] && pmm_ok=1
    rm -f "${MANIFEST_FILE}" 2>/dev/null || true

    if [ "${all_ok}" = "true" ]; then
        scale_up_pmm
        write_restore_metrics 0 "idle" "${success}" "${end_ts}" "${duration}" "${pg_ok}" "${ch_ok}" "${vm_ok}" "${enc_ok}" "${pmm_ok}"
        log "INFO" "==============================================================================="
        log "INFO" "PMM-HA Restore Summary"
        log "INFO" "==============================================================================="
        log "INFO" "Backup: ${BACKUP_NAME}   Namespace: ${NAMESPACE}   Target: ${BACKUP_TARGET}   Duration: ${duration}s"
        log "INFO" "  - PostgreSQL:      $([ "${RESTORE_POSTGRESQL}" != "true" ] && echo '⊘ Skipped' || { [ "${POSTGRESQL_OK}" = "true" ] && echo '✓ Yes' || echo '✗ Failed'; })"
        log "INFO" "  - ClickHouse:      $([ "${RESTORE_CLICKHOUSE}" != "true" ] && echo '⊘ Skipped' || { [ "${CLICKHOUSE_OK}" = "true" ] && echo '✓ Yes' || echo '✗ Failed'; })"
        log "INFO" "  - VictoriaMetrics: $([ "${RESTORE_VICTORIAMETRICS}" != "true" ] && echo '⊘ Skipped' || { [ "${VICTORIAMETRICS_OK}" = "true" ] && echo '✓ Yes' || echo '✗ Failed'; })"
        log "INFO" "  - PMM Server /srv: $([ "${RESTORE_PMM_SERVER}" != "true" ] && echo '⊘ Skipped' || { [ "${PMM_SERVER_OK}" = "true" ] && echo '✓ Yes' || echo '✗ Failed'; })"
        log "INFO" "  - Encryption Key:  $([ "${ENCRYPTION_KEY_OK}" = "true" ] && echo '✓ Yes' || echo '⊘ No')"
        log "INFO" "Restore completed successfully in ${duration}s. PMM scaled back up to ${PMM_SAVED_REPLICAS:-unchanged}."
        log "INFO" "==============================================================================="
        exit 0
    else
        write_restore_metrics 0 "idle" "${success}" "${end_ts}" "${duration}" "${pg_ok}" "${ch_ok}" "${vm_ok}" "${enc_ok}" "${pmm_ok}"
        log "ERROR" "One or more restores failed. PMM left scaled DOWN. Fix and re-run, or scale up manually:"
        log "ERROR" "  kubectl scale statefulset ${PMM_STATEFULSET_NAME:-<pmm-sts>} -n ${NAMESPACE} --replicas=${PMM_SAVED_REPLICAS:-1}"
        exit 1
    fi
}

################################################################################
# 11. Subcommand dispatch
################################################################################

# The subcommand is REQUIRED — there is deliberately no default operation.
#
# Defaulting to 'backup' is a data-loss path, not a convenience: the two tools this file
# replaces disagreed about the default (backup-orchestrator.sh defaulted to backup,
# restore-orchestrator.sh to RESTORE), so a bare invocation carrying restore-shaped flags —
# `pmm-backup.sh --backup-id <id> --target s3 --s3-bucket B`, which is exactly what an
# operator with the old muscle memory types — parsed cleanly as a BACKUP and overwrote the
# very backup it was meant to restore, re-pointed 'latest' and then ran retention. Every
# flag in that line is valid for both operations, so nothing else can catch it. Name the
# operation.
#
# For 'list', the next non-flag token (if any) is the BACKUP_ID to inspect. Everything else
# is flags, parsed by parse_args (so list reuses --s3-bucket/--s3-prefix/--namespace/etc.).
COMMAND=""
if [ $# -gt 0 ]; then
    case "$1" in
        backup|restore|list) COMMAND="$1"; shift ;;
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
if [ -z "${S3_PREFIX}" ]; then
    S3_PREFIX="${NAMESPACE}/pmm-ha"
fi

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
    # Static-cred env block injected into every temp pod (vmrestore + s3 client + /srv
    # restore) when a secret is configured; empty otherwise (IRSA / SA credential chain).
    TEMP_POD_S3_KEYS_ENV=""
    if [ -n "${S3_SECRET_NAME}" ]; then
        TEMP_POD_S3_KEYS_ENV="
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: ${S3_SECRET_NAME}, key: ${S3_SECRET_ACCESS_KEY_KEY} } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: ${S3_SECRET_NAME}, key: ${S3_SECRET_SECRET_KEY_KEY} } }"
    fi
    # ServiceAccount line for the temp pods. The chart creates the DEFAULT SA name
    # (${S3_SERVICE_ACCOUNT}) only for IRSA (irsaRoleArn set); on the static-key path that SA
    # does NOT exist, so assuming it by default would make every temp pod rejected at
    # admission. Emit the line when either:
    #   - we are NOT using static keys (IRSA / SA credential-chain path — the default SA
    #     exists and carries the creds), or
    #   - the operator explicitly passed --s3-service-account, in which case honor it even
    #     with static keys (e.g. an SA that carries imagePullSecrets for the temp-pod images).
    # Static keys with no explicit SA deliberately omits the line (namespace default SA).
    TEMP_POD_SA_LINE=""
    if [ -n "${S3_SERVICE_ACCOUNT}" ] && { [ -z "${S3_SECRET_NAME}" ] || [ "${S3_SA_EXPLICIT}" = "true" ]; }; then
        TEMP_POD_SA_LINE="  serviceAccountName: ${S3_SERVICE_ACCOUNT}"
    fi
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
        [ "${BACKUP_POSTGRESQL}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="postgresql"
        [ "${BACKUP_CLICKHOUSE}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="clickhouse"
        [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="victoriametrics"
        [ "${BACKUP_PMM_SERVER}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="pmm-server"
        [ ${_comp_count} -eq 1 ] && COMPONENT_SUFFIX="_${_comp_name}"
    fi

    LOG_FILE="${BACKUP_DIR}/logs/backup_${TIMESTAMP}${COMPONENT_SUFFIX}.log"
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
    *)
        cmd_backup
        ;;
esac
