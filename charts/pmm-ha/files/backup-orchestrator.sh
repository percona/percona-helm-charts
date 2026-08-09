#!/bin/sh
set -eu

################################################################################
# PMM-HA Unified Backup Orchestrator
# 
# This script orchestrates backups across all PMM-HA components using their
# native backup tools:
# - PostgreSQL: pg_dump (logical, portable custom-format dump per database)
# - ClickHouse: clickhouse-backup (Altinity tool)
# - VictoriaMetrics: vmbackup (VictoriaMetrics utility)
#
# Shell: uses `local` and other common extensions beyond strict POSIX sh. Supported
# shells: BusyBox ash (the backup-tools image), dash, and bash — all implement these.
################################################################################

# Show help function
show_help() {
    cat <<EOF
PMM-HA Unified Backup Orchestrator

This script uses NATIVE backup tools from each operator:
  - PostgreSQL: pg_dump (logical custom-format dump of each application database)
  - ClickHouse: clickhouse-backup via system.backup_actions API
  - VictoriaMetrics: vmbackup (incremental)
  - PMM Server: gzip-compressed tar of /srv from each PMM server pod

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  backup                    (default) Back up the selected components.
  list [BACKUP_ID]          List backups, or — given a BACKUP_ID — show every file/location
                            that belongs to that one backup, read from its manifest.json.
                            Requires the same --s3-bucket / --s3-prefix / --namespace as the
                            backup (in s3 mode it lists via the pmm-backup sidecar's rclone).

Options:
  -h, --help                Show this help message
  -v, --verbose             Show detailed backup tool output
  --dry-run                 Show commands that would be executed without running them
  -n, --namespace NS        Kubernetes namespace (default: demo)
  -d, --backup-dir DIR      Backup directory for logs/metadata (default: /backups)
  -r, --retention DAYS      Number of days to retain backups (default: 7)
  --backup-id ID            Shared backup identifier for grouping concurrent runs.
                            When set, all processes use the same backup directory.
                            If omitted, a timestamp is auto-generated.

  Component Selection (combinable, e.g. --postgresql --clickhouse):
  --postgresql              Include PostgreSQL in backup
  --clickhouse              Include ClickHouse in backup
  --victoriametrics         Include VictoriaMetrics in backup
  --pmm-server              Include PMM server /srv archive in backup
  --skip-postgresql         Skip PostgreSQL backup
  --skip-clickhouse         Skip ClickHouse backup
  --skip-victoriametrics    Skip VictoriaMetrics backup
  --skip-pmm-server         Skip PMM server /srv backup
  --skip-encryption-key     Skip the PMM encryption key (captured with PostgreSQL by default)

  PostgreSQL: logical pg_dump of all application databases (no options needed).

  ClickHouse Options:
  --ch-backup-type TYPE     Backup type: full or incremental (default: full)
  --ch-secret NAME          Kubernetes secret for CH credentials (default: pmm-secret)

  Target / S3 Options:
  --target {s3|shared}      Where backups land (default: s3). 'shared' = a mounted RWX/NFS
                            volume; 's3' = each component uploads to the bucket.
  --s3-bucket BUCKET        S3 bucket name (required for --target s3)
  --s3-endpoint URL         S3 endpoint (leave empty for AWS)
  --s3-region REGION        S3 region (default: us-east-1)
  --s3-prefix PREFIX        Key namespace under the bucket (default: pmm-ha). PMM/VM/manifest
                            land under s3://<bucket>/<prefix>/backups/<id>/...
  --shared-mount-path PATH  Mount path of the shared volume in the pods (default: /central)

Examples:
  # Full backup with default settings
  $0 --namespace demo

  # PostgreSQL only (pg_dump of all app databases)
  $0 --namespace demo --postgresql

  # Backup PostgreSQL and ClickHouse only
  $0 --namespace demo --postgresql --clickhouse

  # Run all three components concurrently (grouped by backup-id)
  BACKUP_ID=\$(date +%Y%m%d-%H%M%S)
  $0 --namespace demo --postgresql      --backup-id \$BACKUP_ID &
  $0 --namespace demo --clickhouse      --backup-id \$BACKUP_ID &
  $0 --namespace demo --victoriametrics --backup-id \$BACKUP_ID &
  wait

  # Backup all components with S3
  $0 --namespace demo --s3-bucket pmm-backups

  # Backup to custom directory with 14-day retention
  $0 --namespace demo --backup-dir /srv/backup --retention 14

  # Skip VictoriaMetrics (faster backup)
  $0 --namespace demo --skip-victoriametrics

  # Back up only the PMM server /srv directory (all PMM pods)
  $0 --namespace demo --pmm-server

  # List all backups in the bucket (newest manifests), marking the 'latest' pointer
  $0 list --namespace demo --s3-bucket my-bucket --s3-prefix pmm-ha

  # Show every file/location belonging to one backup (reads its manifest.json)
  $0 list backup_20260610-120000 --namespace demo --s3-bucket my-bucket

Environment Variables:
  AWS_ACCESS_KEY_ID         S3 access key (for S3 backups)
  AWS_SECRET_ACCESS_KEY     S3 secret key (for S3 backups)
  BACKUP_DIR                Backup directory (default: /backups)
  BACKUP_RETENTION          Retention in days (default: 7)
  METRICS_DIR               Directory for Prometheus .prom metrics files
                            (default: /backups/.metrics)
  KUBECTL_EXEC_TIMEOUT      Timeout for backup commands via 'timeout' wrapper (default: 600)
  KUBECTL_STATUS_TIMEOUT    Timeout for status queries via 'timeout' wrapper (default: 30)
  CH_SECRET_NAME            Kubernetes secret for ClickHouse credentials (default: pmm-secret)
  CH_CREATE_TIMEOUT         Max seconds to wait for ClickHouse backup creation (default: 300)
  CH_UPLOAD_TIMEOUT         Max seconds to wait for ClickHouse S3 upload (default: 600)
  PMM_SRV_PATH              Path archived from each PMM server pod (default: /srv)

Concurrency:
  Per-component locking allows running separate component backups in parallel.
  Each component has its own lock file (.backup_postgresql.lock, etc.).
  Two runs of the same component will block; different components run concurrently.
  Use --backup-id to group concurrent runs into the same backup directory.

Manifest & Catalog (both modes):
  In shared mode every component lands under <central>/backup_<id>/. In s3 mode PG (pg_dump),
  PMM /srv and VictoriaMetrics land under backups/<id>/, while ClickHouse keeps its own native
  clickhouse-backup remote layout (addressed by backup name) — so there isn't always one folder
  holding everything. Either way, every run writes ONE index that ties the pieces together:
    s3 mode     -> s3://<bucket>/<prefix>/backups/<id>/manifest.json   + .../backups/latest
    shared mode -> <central>/backup_<id>/manifest.json                 + <central>/latest
  'latest' is a small text file holding the newest backup id (same mechanism in both modes).
  Use '$0 list' / '$0 list <id>' to read them. Restore drives each engine by the coordinates
  the manifest records (PG dump databases, CH backup name, VM/PMM object paths).

Metrics:
  After each run, Prometheus-format metrics are written to METRICS_DIR:
    postgresql_metrics.prom, clickhouse_metrics.prom, victoriametrics_metrics.prom,
    pmm-server_metrics.prom
  These are served over HTTP by netcat listeners on ports 9091-9094 in the
  backup-tools pod and scraped by vmagent for monitoring and alerting.

Prerequisites:
  - kubectl configured with access to the target cluster
  - timeout command (coreutils) available in PATH
  - PostgreSQL: pg_dump/pg_restore available in the PG pod (default in Percona PG images)
  - ClickHouse: clickhouse-backup sidecar running (system.backup_actions table)
  - VictoriaMetrics: vmbackup sidecar container in vmstorage pods
  - PMM Server: tar/gzip available in the PMM server container (default in PMM images)

EOF
    exit 0
}

# Default configuration
NAMESPACE="${NAMESPACE:-demo}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_ID=""
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
VERBOSE="${VERBOSE:-false}"
METRICS_DIR="${METRICS_DIR:-/backups/.metrics}"

DRY_RUN=false

# Component flags (default: all enabled)
BACKUP_POSTGRESQL="${BACKUP_POSTGRESQL:-true}"
BACKUP_CLICKHOUSE="${BACKUP_CLICKHOUSE:-true}"
BACKUP_VICTORIAMETRICS="${BACKUP_VICTORIAMETRICS:-true}"
BACKUP_PMM_SERVER="${BACKUP_PMM_SERVER:-true}"
# Encryption key is captured alongside PostgreSQL (it's the PG encryption key); --skip-encryption-key
# turns it off. (Restore selects it independently via --encryption-key.)
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-true}"

# PostgreSQL: logical dump (pg_dump). Application databases are auto-discovered; no
# stanza/repo/retention knobs needed.

# ClickHouse settings
CH_BACKUP_TYPE="${CH_BACKUP_TYPE:-full}"
CH_SECRET_NAME="${CH_SECRET_NAME:-pmm-secret}"
# Max seconds to wait for clickhouse-backup create/upload to finish (polled async)
CH_CREATE_TIMEOUT="${CH_CREATE_TIMEOUT:-300}"
CH_UPLOAD_TIMEOUT="${CH_UPLOAD_TIMEOUT:-600}"

# PMM server (/srv) settings
# Path inside the PMM server pod to archive (full /srv: config, grafana, certs, etc.)
PMM_SRV_PATH="${PMM_SRV_PATH:-/srv}"

# Backup target mode (where backups land):
#   s3     - each component writes to object storage (vmbackup + clickhouse-backup native;
#            PG pg_dump and /srv stream through the rclone pmm-backup sidecar). No pod mounts.
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
# Prefix (key namespace) under the bucket: s3://<bucket>/<S3_PREFIX>/backups/<id>/...
S3_PREFIX=$(echo "${S3_PREFIX:-pmm-ha}" | sed 's|^/||; s|/$||')
# rclone remote name; its config is supplied via RCLONE_CONFIG_<NAME>_* env vars
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"

# Derived from BACKUP_TARGET; kept for the per-tool S3 branches (vmbackup/clickhouse-backup).
S3_ENABLED=false
# Central storage as seen by the ORCHESTRATOR (backup-tools mount of the shared RWX volume).
# In shared mode components write to ${SHARED_MOUNT_PATH} in their own pods; backup-tools
# reads/verifies the same files here and writes the manifest/encryption key. Same PVC.
# Resolved AFTER argument parsing (it must track --backup-dir); only the raw env is read here.
_CENTRAL_BACKUP_PATH_ENV="${CENTRAL_BACKUP_PATH:-}"
CENTRAL_BACKUP_PATH=""

# Timeout settings (in seconds) for kubectl commands.
# NOTE: We use the `timeout` command wrapper instead of kubectl's --request-timeout
# flag because --request-timeout breaks kubectl's in-cluster API server discovery
# when running inside a pod (kubectl falls back to localhost:8080 instead of using
# the ServiceAccount token). Discovered during in-cluster testing on kubectl v1.35.
KUBECTL_EXEC_TIMEOUT="${KUBECTL_EXEC_TIMEOUT:-600}"
KUBECTL_STATUS_TIMEOUT="${KUBECTL_STATUS_TIMEOUT:-30}"

# Kubernetes label selectors (centralized for consistency)
LABEL_PG_PRIMARY="postgres-operator.crunchydata.com/role=primary"
LABEL_CH_POD="clickhouse.altinity.com/chi"
LABEL_VM_STORAGE="app.kubernetes.io/name=vmstorage"
# PMM server pods (HA StatefulSet); selector discovers all replicas (1, 3, 5, ...)
LABEL_PMM_SERVER="app.kubernetes.io/component=pmm-server"

# Global backup state tracking (for the manifest and summary)
PG_BACKUP_SUCCESS=false
CH_BACKUP_SUCCESS=false
CH_BACKUP_NAME=""
VM_BACKUP_SUCCESS=false
PMM_BACKUP_SUCCESS=false
ENCRYPTION_KEY_BACKUP_SUCCESS=false

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

# Track whether explicit component selection was made
EXPLICIT_SELECTION=false

# Optional leading subcommand: 'backup' (default) or 'list'. For 'list', the next
# non-flag token (if any) is the BACKUP_ID to inspect. Everything else is flags,
# parsed by the loop below (so list reuses --s3-bucket/--s3-prefix/--namespace/etc.).
COMMAND="backup"
LIST_ID=""
if [ $# -gt 0 ]; then
    case "$1" in
        backup|list) COMMAND="$1"; shift ;;
    esac
fi
if [ "${COMMAND}" = "list" ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    LIST_ID="$1"; shift
fi

# Parse command-line arguments
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -d|--backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        -r|--retention)
            BACKUP_RETENTION="$2"
            shift 2
            ;;
        # First explicit component selection disables the others (default is all-on);
        # additional --<component> flags then combine. Mirrors restore-orchestrator.sh.
        --postgresql) [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_CLICKHOUSE=false; BACKUP_VICTORIAMETRICS=false; BACKUP_PMM_SERVER=false; EXPLICIT_SELECTION=true; }; BACKUP_POSTGRESQL=true; shift ;;
        --clickhouse) [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_POSTGRESQL=false; BACKUP_VICTORIAMETRICS=false; BACKUP_PMM_SERVER=false; EXPLICIT_SELECTION=true; }; BACKUP_CLICKHOUSE=true; shift ;;
        --victoriametrics) [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_POSTGRESQL=false; BACKUP_CLICKHOUSE=false; BACKUP_PMM_SERVER=false; EXPLICIT_SELECTION=true; }; BACKUP_VICTORIAMETRICS=true; shift ;;
        --pmm-server) [ "${EXPLICIT_SELECTION}" = "false" ] && { BACKUP_POSTGRESQL=false; BACKUP_CLICKHOUSE=false; BACKUP_VICTORIAMETRICS=false; EXPLICIT_SELECTION=true; }; BACKUP_PMM_SERVER=true; shift ;;
        --skip-postgresql)
            BACKUP_POSTGRESQL=false
            shift
            ;;
        --skip-clickhouse)
            BACKUP_CLICKHOUSE=false
            shift
            ;;
        --skip-victoriametrics)
            BACKUP_VICTORIAMETRICS=false
            shift
            ;;
        --skip-pmm-server)
            BACKUP_PMM_SERVER=false
            shift
            ;;
        --skip-encryption-key)
            BACKUP_ENCRYPTION_KEY=false
            shift
            ;;
        --ch-backup-type)
            CH_BACKUP_TYPE="$2"
            shift 2
            ;;
        --ch-secret)
            CH_SECRET_NAME="$2"
            shift 2
            ;;
        --target)
            BACKUP_TARGET="$2"
            shift 2
            ;;
        --shared-mount-path)
            SHARED_MOUNT_PATH="$2"
            shift 2
            ;;
        --s3-bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        --s3-endpoint)
            S3_ENDPOINT="$2"
            shift 2
            ;;
        --s3-region)
            S3_REGION="$2"
            shift 2
            ;;
        --s3-prefix)
            S3_PREFIX=$(echo "$2" | sed 's|^/||; s|/$||')
            shift 2
            ;;
        --backup-id)
            BACKUP_ID="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate backup types
case "${CH_BACKUP_TYPE}" in
    full|incremental) ;;
    *) echo "Error: Invalid --ch-backup-type: ${CH_BACKUP_TYPE} (must be: full, incremental)"; exit 1 ;;
esac

# Validate retention is a non-negative integer (it flows unquoted into find -mtime +N)
case "${BACKUP_RETENTION}" in
    ''|*[!0-9]*) echo "Error: Invalid --retention: '${BACKUP_RETENTION}' (must be a non-negative integer)"; exit 1 ;;
esac

# Validate backup target + derive per-tool S3 flag
case "${BACKUP_TARGET}" in
    s3)
        S3_ENABLED=true
        [ -n "${S3_BUCKET}" ] || { echo "Error: --target s3 requires --s3-bucket (or S3_BUCKET)"; exit 1; }
        ;;
    shared)
        S3_ENABLED=false
        ;;
    *)
        echo "Error: Invalid --target: '${BACKUP_TARGET}' (must be: s3, shared)"; exit 1 ;;
esac

# If --backup-id was provided, validate and use it as the timestamp/identifier.
# It flows into filesystem paths, backup names, and a ClickHouse SQL string
# literal, so restrict it to a safe charset.
if [ -n "${BACKUP_ID}" ]; then
    case "${BACKUP_ID}" in
        *[!A-Za-z0-9_-]*)
            echo "Error: Invalid --backup-id: '${BACKUP_ID}' (allowed characters: A-Z a-z 0-9 _ -)"
            exit 1
            ;;
    esac
    TIMESTAMP="${BACKUP_ID}"
fi

# Determine per-component suffix for concurrent mode (--backup-id with a single component)
COMPONENT_SUFFIX=""
if [ -n "${BACKUP_ID}" ]; then
    _comp_count=0
    _comp_name=""
    [ "${BACKUP_POSTGRESQL}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="postgresql"
    [ "${BACKUP_CLICKHOUSE}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="clickhouse"
    [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="victoriametrics"
    [ "${BACKUP_PMM_SERVER}" = "true" ] && _comp_count=$((_comp_count+1)) && _comp_name="pmm-server"
    [ ${_comp_count} -eq 1 ] && COMPONENT_SUFFIX="_${_comp_name}"
fi

# Update derived variables
BACKUP_SUBDIR="${BACKUP_DIR}/backup_${TIMESTAMP}"
LOG_FILE="${BACKUP_DIR}/logs/backup_${TIMESTAMP}${COMPONENT_SUFFIX}.log"

# Resolve the central path now that --backup-dir is known. In shared mode it MUST equal
# BACKUP_DIR: the manifest/encryption key land under CENTRAL_BACKUP_PATH while PG dumps land
# under BACKUP_DIR, and restore-orchestrator.sh only ever reads BACKUP_DIR — a divergence
# silently splits one backup across two roots that restore can never reassemble.
CENTRAL_BACKUP_PATH=$(echo "${_CENTRAL_BACKUP_PATH_ENV:-${BACKUP_DIR}}" | sed 's|/$||')
if [ "${BACKUP_TARGET}" = "shared" ] && [ "${CENTRAL_BACKUP_PATH}" != "${BACKUP_DIR}" ]; then
    echo "Error: CENTRAL_BACKUP_PATH (${CENTRAL_BACKUP_PATH}) must equal the backup dir (${BACKUP_DIR}) in shared mode."
    echo "       Use --backup-dir to point the orchestrator at the central RWX mount instead."
    exit 1
fi

################################################################################
# Logging Functions
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

################################################################################
# Utility Functions
################################################################################

# Format a byte count as a human-readable string (e.g. 1234567 -> "1.2MB").
# Single source of truth for size formatting across all components.
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i=1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d%s", b, u[i]; else printf "%.1f%s", b, u[i]
    }'
}

# Write per-component Prometheus metrics to a .prom file (atomic via mv)
write_component_metrics() {
    local component=$1
    local success=$2
    local duration=$3
    local size_bytes=$4
    local timestamp=$(date +%s)

    mkdir -p "${METRICS_DIR}"

    local tmp_file="${METRICS_DIR}/.${component}_metrics.prom.tmp"
    local target_file="${METRICS_DIR}/${component}_metrics.prom"

    cat > "${tmp_file}" <<EOF
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

    mv "${tmp_file}" "${target_file}"
    log "INFO" "Metrics written to ${target_file}"
}

################################################################################
# Manifest / Catalog + S3 client (the per-run index that ties scattered pieces together)
################################################################################

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

# The orchestrator has no S3 client of its own; it borrows the pmm-backup rclone sidecar
# (rclone + IRSA + RCLONE_CONFIG_S3_* all live there). Find a PMM pod that has it.
S3_CLIENT_POD=""
pick_s3_client_pod() {
    if [ -n "${S3_CLIENT_POD}" ]; then echo "${S3_CLIENT_POD}"; return 0; fi
    _pods=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_PMM_SERVER}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for _p in ${_pods}; do
        if kubectl get pod -n "${NAMESPACE}" "${_p}" \
            -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -q "pmm-backup"; then
            S3_CLIENT_POD="${_p}"
            echo "${_p}"
            return 0
        fi
    done
    return 1
}

# Run rclone (read-only ops: cat/lsf/ls) inside the pmm-backup sidecar.
s3_rclone() {
    _pod=$(pick_s3_client_pod) || return 1
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${_pod}" -c pmm-backup -- rclone "$@"
}

# Pipe stdin into an object via rclone rcat (used to write manifest.json / latest pointer).
s3_rclone_rcat() {
    _pod=$(pick_s3_client_pod) || return 1
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -i -n "${NAMESPACE}" "${_pod}" -c pmm-backup -- \
        rclone rcat --s3-no-check-bucket "$1"
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
        --arg backup_id "backup_${TIMESTAMP}" --arg ts "${TIMESTAMP}" --arg created "${_created}" \
        --arg ns "${NAMESPACE}" --arg target "${BACKUP_TARGET}" --arg bucket "${S3_BUCKET}" \
        --arg prefix "${S3_PREFIX}" --arg status "${_overall}" --argjson comps "${_comps}" \
        '{backup_id: $backup_id, timestamp: $ts, created: $created, namespace: $ns,
          target: $target, bucket: $bucket, prefix: $prefix, status: $status, components: $comps}')

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[Manifest] [DRY RUN] Would write backups/backup_${TIMESTAMP}/manifest.json (+ latest pointer)"
        return 0
    fi

    # Concurrent-mode merge: with --backup-id, one process per component (the documented
    # workflow) each writes the SAME backups/<id>/manifest.json — without a merge the last
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

    if [ "${BACKUP_TARGET}" = "s3" ]; then
        _existing=$(s3_rclone cat "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/manifest.json" 2>/dev/null || true)
    else
        _existing=$(cat "${CENTRAL_BACKUP_PATH}/backup_${TIMESTAMP}/manifest.json" 2>/dev/null || true)
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

    if [ "${BACKUP_TARGET}" = "s3" ]; then
        _mpath="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/manifest.json"
        if printf '%s\n' "${_manifest}" | s3_rclone_rcat "${_mpath}"; then
            log "INFO" "[Manifest] Wrote s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/manifest.json"
            if [ "${_move_latest}" != "true" ]; then
                log "INFO" "[Manifest] latest pointer NOT moved (run is not a complete full-scope backup)"
            elif printf '%s\n' "backup_${TIMESTAMP}" | s3_rclone_rcat "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/latest"; then
                log "INFO" "[Manifest] Updated latest -> backup_${TIMESTAMP}"
            else
                log "WARN" "[Manifest] Could not update latest pointer"
            fi
        else
            log "WARN" "[Manifest] Failed to write manifest to S3 (no pmm-backup sidecar pod reachable?)"
        fi
    else
        _mdir="${CENTRAL_BACKUP_PATH}/backup_${TIMESTAMP}"
        mkdir -p "${_mdir}" 2>/dev/null || true
        if printf '%s\n' "${_manifest}" > "${_mdir}/manifest.json" 2>/dev/null; then
            if [ "${_move_latest}" = "true" ]; then
                printf '%s\n' "backup_${TIMESTAMP}" > "${CENTRAL_BACKUP_PATH}/latest" 2>/dev/null || true
            else
                log "INFO" "[Manifest] latest pointer NOT moved (run is not a complete full-scope backup)"
            fi
            log "INFO" "[Manifest] Wrote ${_mdir}/manifest.json"
        else
            log "WARN" "[Manifest] Could not write manifest to ${_mdir}"
        fi
    fi
    [ "${_mlock_held}" = "true" ] && rmdir "${_mlock}" 2>/dev/null || true
    return 0
}

# Render a manifest.json (on stdin) as a clean per-component summary: each component's
# status + where it lives + (for PG/CH) the restore command. Surfaces PostgreSQL and
# ClickHouse inline even though their data sits outside the backups/<id>/ tree.
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

# 'list' command: enumerate backups, or show one backup's per-component summary + files.
cmd_list() {
    _want="${1:-}"
    ensure_jq || { echo "Error: jq is required for 'list' (Alpine: apk add jq; Debian: apt-get install jq)"; exit 1; }

    if [ "${BACKUP_TARGET}" = "s3" ]; then
        [ -n "${S3_BUCKET}" ] || { echo "Error: 'list' (s3) requires --s3-bucket"; exit 1; }
        _base="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups"

        if [ -z "${_want}" ]; then
            echo "Backups in s3://${S3_BUCKET}/${S3_PREFIX}/backups/"
            echo ""
            _latest=$(s3_rclone cat "${_base}/latest" 2>/dev/null | tr -d '[:space:]' || true)
            _ids=$(s3_rclone lsf --dirs-only "${_base}/" 2>/dev/null | sed 's:/$::' | sort || true)
            if [ -z "${_ids}" ]; then echo "  (none found — bucket/prefix empty or sidecar unreachable)"; return 0; fi
            printf '  %-30s %-9s %s\n' "BACKUP ID" "STATUS" "COMPONENTS"
            for _id in ${_ids}; do
                _mj=$(s3_rclone cat "${_base}/${_id}/manifest.json" 2>/dev/null || true)
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
            echo "  Inspect one:  $(basename "$0") list <BACKUP ID> --s3-bucket ${S3_BUCKET} --s3-prefix ${S3_PREFIX}"
        else
            _mj=$(s3_rclone cat "${_base}/${_want}/manifest.json" 2>/dev/null || true)
            if [ -z "${_mj}" ]; then
                echo "  (no manifest at s3://${S3_BUCKET}/${S3_PREFIX}/backups/${_want}/manifest.json)"
                return 0
            fi
            echo "=== ${_want}  (status: $(echo "${_mj}" | manifest_field status), target: $(echo "${_mj}" | manifest_field target), $(echo "${_mj}" | manifest_field created)) ==="
            echo ""
            printf '  %-16s %-9s %s\n' "COMPONENT" "STATUS" "LOCATION / RESTORE"
            echo "${_mj}" | print_manifest_summary
            echo ""
            echo "  (ClickHouse & PostgreSQL live in their own native S3 layouts — shown above from the manifest)"
            echo ""
            echo "  Top-level under s3://${S3_BUCKET}/${S3_PREFIX}/backups/${_want}/:"
            _objs=$(s3_rclone lsf "${_base}/${_want}/" 2>/dev/null || true)
            if [ -n "${_objs}" ]; then echo "${_objs}" | sed 's/^/    /'; else echo "    (none)"; fi
        fi
    else
        _base="${CENTRAL_BACKUP_PATH}"
        if [ -z "${_want}" ]; then
            echo "Backups in ${_base}/"
            echo ""
            if ls -1 "${_base}" 2>/dev/null | grep -q '^backup_'; then
                ls -1 "${_base}" 2>/dev/null | grep '^backup_' | sed 's/^/  /'
            else
                echo "  (none found)"
            fi
            [ -f "${_base}/latest" ] && echo "" && echo "  latest -> $(cat "${_base}/latest" 2>/dev/null)"
        else
            if [ ! -f "${_base}/${_want}/manifest.json" ]; then
                echo "  (no manifest at ${_base}/${_want}/manifest.json)"
                return 0
            fi
            _mj=$(cat "${_base}/${_want}/manifest.json")
            echo "=== ${_want}  (status: $(echo "${_mj}" | manifest_field status), target: $(echo "${_mj}" | manifest_field target), $(echo "${_mj}" | manifest_field created)) ==="
            echo ""
            printf '  %-16s %-9s %s\n' "COMPONENT" "STATUS" "LOCATION / RESTORE"
            echo "${_mj}" | print_manifest_summary
            echo ""
            echo "  (All components — incl. PostgreSQL pg_dump — live under this dir; shown above from the manifest)"
            echo ""
            echo "  contents of ${_base}/${_want}/ (sizes):"
            du -sh "${_base}/${_want}"/* 2>/dev/null | sed 's|^|    |' || echo "    (none)"
        fi
    fi
}

################################################################################
# Lock Management (per-component locks for concurrent runs)
################################################################################

acquire_component_lock() {
    local component=$1
    local lock_dir="${BACKUP_DIR}/.backup_${component}.lock"

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
        log "ERROR" "Another ${component} backup is already running (PID: ${existing_pid})"
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
    # NOTE: busybox ash expands every initializer of one 'local' line BEFORE assigning,
    # so ${component} must not be referenced on the same line it is set — use ${1}.
    local lock_dir="${BACKUP_DIR}/.backup_${1}.lock"
    # Only the owner may release: the EXIT trap is installed before acquire_locks, so a run
    # that aborts because ANOTHER process holds the lock must not delete that live lock.
    [ "$(cat "${lock_dir}/pid" 2>/dev/null || echo "")" = "$$" ] && rm -rf "${lock_dir}" 2>/dev/null || true
}

acquire_locks() {
    # Acquire in alphabetical order to prevent deadlocks
    [ "${BACKUP_CLICKHOUSE}" = "true" ] && acquire_component_lock "clickhouse"
    [ "${BACKUP_PMM_SERVER}" = "true" ] && acquire_component_lock "pmm-server"
    [ "${BACKUP_POSTGRESQL}" = "true" ] && acquire_component_lock "postgresql"
    [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && acquire_component_lock "victoriametrics"
    return 0
}

release_locks() {
    [ "${BACKUP_CLICKHOUSE}" = "true" ] && release_component_lock "clickhouse"
    [ "${BACKUP_PMM_SERVER}" = "true" ] && release_component_lock "pmm-server"
    [ "${BACKUP_POSTGRESQL}" = "true" ] && release_component_lock "postgresql"
    [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && release_component_lock "victoriametrics"
    return 0
}

################################################################################
# Pre-flight Checks
################################################################################

preflight_checks() {
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

    if [ "${checks_passed}" = "true" ]; then
        log "INFO" "Pre-flight checks passed"
    else
        log "WARN" "Some pre-flight checks failed; backup will proceed but may have failures"
    fi
    return 0
}

################################################################################
# PostgreSQL Backup - logical dump (pg_dump). One portable custom-format file per
# database under backups/<id>/postgresql/, alongside the other components. No
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
                log "INFO" "[PostgreSQL] [DRY RUN] pg_dump -Fc ${db} | rclone rcat s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/postgresql/${db}.dump"
            else
                log "INFO" "[PostgreSQL] [DRY RUN] pg_dump -Fc ${db} > ${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/postgresql/${db}.dump"
            fi
        done
        PG_BACKUP_SUCCESS=true
        return 0
    fi

    local total_bytes=0 ok_count=0 db_count=0 dumped="" db size_b
    for db in ${dbs}; do
        db_count=$((db_count + 1)); size_b=0
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            local s3_uri="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/postgresql/${db}.dump"
            local pmm_pod; pmm_pod=$(pick_s3_client_pod) || { log "ERROR" "[PostgreSQL] No pmm-backup sidecar to stream the dump to S3"; return 1; }
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
            local dest_dir="${BACKUP_SUBDIR}/postgresql"; mkdir -p "${dest_dir}"
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
        PG_BACKUP_LOCATION="s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/postgresql/"
    else
        PG_BACKUP_LOCATION="${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/postgresql/"
    fi

    # All-or-nothing: a partial dump set can't restore the full cluster, so only mark success
    # when every database dumped — consistent with ClickHouse/VM/PMM. main() then records a
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
    
    local ch_backup_dir="${BACKUP_SUBDIR}/clickhouse"
    [ "${DRY_RUN}" != "true" ] && mkdir -p "${ch_backup_dir}"
    
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

    local backup_name="pmm_backup_${TIMESTAMP}"

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
    local ch_upload_cmd="upload ${backup_name}"
    if [ "${CH_BACKUP_TYPE}" = "incremental" ]; then
        local prev_backup=$(ch_query "SELECT name FROM system.backup_list WHERE name LIKE 'pmm_backup_%' ORDER BY created DESC LIMIT 1 FORMAT TabSeparatedRaw" 2>/dev/null || true)
        if [ -n "${prev_backup}" ]; then
            ch_upload_cmd="upload --diff-from-remote=${prev_backup} ${backup_name}"
            log "INFO" "[ClickHouse] Incremental upload based on: ${prev_backup}"
        else
            log "WARN" "[ClickHouse] No previous backup found for incremental, falling back to full"
        fi
    fi
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
        local ch_shared_dir="${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/clickhouse"
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
                local backup_dst="s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/victoriametrics/${pod}/${backup_name}"
            else
                local backup_dst="fs://${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/victoriametrics/${pod}/${backup_name}"
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
            local backup_dst="s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/victoriametrics/${pod}/${backup_name}"
            log "INFO" "[VictoriaMetrics] Creating backup to S3: ${backup_name}"
        else
            # shared mode: vmbackup writes to the mounted central volume
            local backup_dst="fs://${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/victoriametrics/${pod}/${backup_name}"
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

    local pmm_backup_dir="${BACKUP_SUBDIR}/pmm-server"

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
                log "INFO" "[PMMServer] [DRY RUN]         'cd ${PMM_SRV_PATH} && tar -czf - --exclude=lost+found \$(ls -A | grep -vxF lost+found) | rclone rcat ${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/pmm-server/${pod}/srv.tar.gz'"
            else
                log "INFO" "[PMMServer] [DRY RUN]     \$ kubectl exec -n ${NAMESPACE} ${pod} -- sh -c \\"
                log "INFO" "[PMMServer] [DRY RUN]         'cd ${PMM_SRV_PATH} && tar -czf ${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/pmm-server/${pod}/srv.tar.gz --exclude=lost+found \$(ls -A | grep -vxF lost+found)'"
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
        local s3_uri="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/pmm-server/${pod}/srv.tar.gz"
        local shared_file="${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/pmm-server/${pod}/srv.tar.gz"
        local pmm_exit size_b size_h

        set +e
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c pmm-backup -- \
                sh -c "set -o pipefail; cd '${PMM_SRV_PATH}' && tar -czf - --exclude=lost+found \$(ls -A | grep -vxF lost+found) | rclone rcat --s3-no-check-bucket '${s3_uri}'" \
                >> "${LOG_FILE}" 2>&1
            pmm_exit=$?
        else
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -- \
                sh -c "mkdir -p '${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/pmm-server/${pod}' && cd '${PMM_SRV_PATH}' && tar -czf '${shared_file}' --exclude=lost+found \$(ls -A | grep -vxF lost+found)" \
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
                PMM_BACKUP_OBJECTS="${PMM_BACKUP_OBJECTS} s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/pmm-server/${pod}/srv.tar.gz"
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
    local key_backup_dir="${BACKUP_SUBDIR}/encryption"
    local key_file="${key_backup_dir}/pg-encryption-key.yaml"
    
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
        ENCRYPTION_KEY_BACKUP_SUCCESS=true
        return 0
    fi

    # Create backup directory
    if ! mkdir -p "${key_backup_dir}"; then
        log "ERROR" "[EncryptionKey] Failed to create backup directory: ${key_backup_dir}"
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
    if ! kubectl get secret "${secret_name}" -n "${NAMESPACE}" -o json | \
        jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.namespace, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]) | if .metadata.annotations == {} then del(.metadata.annotations) else . end' \
        > "${key_file}"; then
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
        
        local file_size=$(du -h "${key_file}" | cut -f1)
        log "INFO" "[EncryptionKey] Exported successfully (size: ${file_size}, sha256: ${checksum:0:16}...)"
        log "INFO" "[EncryptionKey] ✓ Local export completed"
        log "INFO" "[EncryptionKey]   Location: ${key_file}"
        log "INFO" "[EncryptionKey]   Checksum: ${checksum:0:16}..."

        # In s3 mode the local export lives on the (ephemeral) backup-tools pod, so push the
        # key into the bucket next to the rest of this backup using the pmm-backup sidecar's
        # rclone (IRSA creds). Without this the key is NOT in S3 and would be lost on restart.
        if [ "${BACKUP_TARGET}" = "s3" ]; then
            local enc_s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/encryption/pg-encryption-key.yaml"
            if s3_rclone_rcat "${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/encryption/pg-encryption-key.yaml" < "${key_file}"; then
                ENCRYPTION_KEY_LOCATION="${enc_s3_uri}"
                log "INFO" "[EncryptionKey]   Uploaded to ${enc_s3_uri}"
            else
                # The local export lives on this (ephemeral) pod only — if the upload failed,
                # the key is NOT in the bucket and a DR restore cannot decrypt the PG data.
                # This must be a hard failure, not a success with a warning.
                log "ERROR" "[EncryptionKey]   Local export OK but S3 upload FAILED (no pmm-backup sidecar pod reachable?)"
                log "ERROR" "[EncryptionKey]   The key is not in S3; a DR restore of this backup could not decrypt PostgreSQL data"
                return 1
            fi
        else
            ENCRYPTION_KEY_LOCATION="${CENTRAL_BACKUP_PATH}/backup_${TIMESTAMP}/encryption/pg-encryption-key.yaml"
        fi

        ENCRYPTION_KEY_BACKUP_SUCCESS=true
        return 0
    else
        log "ERROR" "[EncryptionKey] Failed to export secret"
        return 1
    fi
}

################################################################################
# Cleanup Old Backups
################################################################################

cleanup_old_backups() {
    log "INFO" "=== Cleaning Up Old Backups ==="
    log "INFO" "Retention: ${BACKUP_RETENTION} days"

    if [ ! -d "${BACKUP_DIR}" ]; then
        log "WARN" "Backup directory ${BACKUP_DIR} does not exist"
        return 0
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "INFO" "[DRY RUN] Cleanup commands:"
        log "INFO" "[DRY RUN]   \$ find ${BACKUP_DIR} -maxdepth 1 -type d -name 'backup_*' -mtime +${BACKUP_RETENTION} -exec rm -rf {} \\;"
        log "INFO" "[DRY RUN]   \$ find ${BACKUP_DIR}/logs -maxdepth 1 -type f -name 'backup_*.log' -mtime +${BACKUP_RETENTION} -delete"
        if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
            log "INFO" "[ClickHouse] [DRY RUN]   \$ kubectl exec ... -c clickhouse-backup -- clickhouse-backup clean --keep-local-older-than ${BACKUP_RETENTION}d"
        fi
        if [ -n "${CENTRAL_BACKUP_PATH:-}" ] && [ -d "${CENTRAL_BACKUP_PATH}" ]; then
            log "INFO" "[DRY RUN]   \$ find ${CENTRAL_BACKUP_PATH} -maxdepth 1 -type d -name 'backup_*' -mtime +${BACKUP_RETENTION} -exec rm -rf {} \\;"
        fi
        log "INFO" "Cleanup completed (dry run)"
        return 0
    fi

    # Prune old per-run backup dirs from BACKUP_DIR (which IS the central RWX root in shared
    # mode, so this also reaps shared-mode payloads; in s3 mode it only holds the manifest +
    # local enc copy + markers, which are tiny).
    # || true: this runs as a plain statement under set -e AFTER the backups succeeded —
    # a find hiccup (e.g. missing logs dir) must not abort the run before metrics/summary.
    find "${BACKUP_DIR}" -maxdepth 1 -type d -name "backup_*" -mtime +${BACKUP_RETENTION} \
        -exec rm -rf {} \; >> "${LOG_FILE}" 2>&1 || true

    find "${BACKUP_DIR}/logs" -maxdepth 1 -type f -name "backup_*.log" -mtime +${BACKUP_RETENTION} \
        -delete >> "${LOG_FILE}" 2>&1 || true
    
    # PostgreSQL: pg_dump files live under backups/<id>/postgresql/, reaped with the
    # per-run retention sweep above (s3: by lifecycle policy on the bucket).
    log "INFO" "[PostgreSQL] pg_dump files pruned with the per-run retention sweep"

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
    #   s3     -> retention handled by S3 lifecycle policies
    #   shared -> old runs reaped from the central RWX by the BACKUP_DIR sweep above
    if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
        if [ "${S3_ENABLED}" = "true" ]; then
            log "INFO" "[VictoriaMetrics] S3 backups: managed by S3 lifecycle policies"
        else
            log "INFO" "[VictoriaMetrics] Shared backups: pruned by the central RWX retention sweep"
        fi
    fi

    # Central RWX prune (shared mode). Only needed when the central path differs from
    # BACKUP_DIR; otherwise the sweep above already covered it.
    if [ -n "${CENTRAL_BACKUP_PATH:-}" ] && [ -d "${CENTRAL_BACKUP_PATH}" ] && [ "${CENTRAL_BACKUP_PATH}" != "${BACKUP_DIR}" ]; then
        log "INFO" "Pruning old backups in central storage (${CENTRAL_BACKUP_PATH})..."
        find "${CENTRAL_BACKUP_PATH}" -maxdepth 1 -type d -name "backup_*" -mtime +${BACKUP_RETENTION} \
            -exec rm -rf {} \; >> "${LOG_FILE}" 2>&1 || true
        local remaining=$(find "${CENTRAL_BACKUP_PATH}" -maxdepth 1 -type d -name "backup_*" | wc -l)
        log "INFO" "  - Backups remaining in central storage: ${remaining}"
    fi
    
    log "INFO" "Cleanup completed"
}

################################################################################
# Main Orchestration
################################################################################

main() {
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
    if ! preflight_checks; then
        exit 1
    fi
    log "INFO" "Namespace: ${NAMESPACE}"
    [ "${BACKUP_POSTGRESQL}" = "true" ] && log "INFO" "Components: PostgreSQL"
    [ "${BACKUP_CLICKHOUSE}" = "true" ] && log "INFO" "Components: ClickHouse"
    [ "${BACKUP_VICTORIAMETRICS}" = "true" ] && log "INFO" "Components: VictoriaMetrics"
    [ "${BACKUP_PMM_SERVER}" = "true" ] && log "INFO" "Components: PMM Server (/srv)"
    log "INFO" ""
    
    # Create backup subdirectory
    [ "${DRY_RUN}" != "true" ] && mkdir -p "${BACKUP_SUBDIR}"
    
    # Track overall status
    local all_success=true
    local components_backed_up=0
    local components_failed=0
    local pg_backed_up=false
    local ch_backed_up=false
    local vm_backed_up=false
    local pmm_backed_up=false

    # PostgreSQL Backup
    if [ "${BACKUP_POSTGRESQL}" = "true" ]; then
        # Gate on the success flag, not just the return code: multi-target components
        # (VM/PMM) return 0 on PARTIAL success but only set *_BACKUP_SUCCESS=true on
        # FULL success — so a partial backup must not mark the run complete.
        if backup_postgresql && [ "${PG_BACKUP_SUCCESS}" = "true" ]; then
            pg_backed_up=true
            components_backed_up=$((components_backed_up + 1))
        else
            components_failed=$((components_failed + 1))
            all_success=false
            log "ERROR" "[PostgreSQL] ✗ Backup failed"
        fi
        log "INFO" ""
    else
        log "INFO" "[PostgreSQL] ⊘ Backup skipped"
    fi
    
    # ClickHouse Backup
    if [ "${BACKUP_CLICKHOUSE}" = "true" ]; then
        if backup_clickhouse && [ "${CH_BACKUP_SUCCESS}" = "true" ]; then
            ch_backed_up=true
            components_backed_up=$((components_backed_up + 1))
        else
            components_failed=$((components_failed + 1))
            all_success=false
            log "ERROR" "[ClickHouse] ✗ Backup failed"
        fi
        log "INFO" ""
    else
        log "INFO" "[ClickHouse] ⊘ Backup skipped"
    fi
    
    # VictoriaMetrics Backup
    if [ "${BACKUP_VICTORIAMETRICS}" = "true" ]; then
        if backup_victoriametrics && [ "${VM_BACKUP_SUCCESS}" = "true" ]; then
            vm_backed_up=true
            components_backed_up=$((components_backed_up + 1))
        else
            components_failed=$((components_failed + 1))
            all_success=false
            log "ERROR" "[VictoriaMetrics] ✗ Backup failed"
        fi
        log "INFO" ""
    else
        log "INFO" "[VictoriaMetrics] ⊘ Backup skipped"
    fi
    
    # PMM Server /srv Backup
    if [ "${BACKUP_PMM_SERVER}" = "true" ]; then
        if backup_pmm_server && [ "${PMM_BACKUP_SUCCESS}" = "true" ]; then
            pmm_backed_up=true
            components_backed_up=$((components_backed_up + 1))
        else
            components_failed=$((components_failed + 1))
            all_success=false
            log "ERROR" "[PMMServer] ✗ Backup failed"
        fi
        log "INFO" ""
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
    # component locations (PMM/VM under backups/<id>/, CH/PG in their own native layouts). This
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
                log "INFO" "    Location:        s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/victoriametrics/<pod>/"
            else
                log "INFO" "    Location:        ${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/victoriametrics/<pod>/ (per pod, central RWX)"
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
                log "INFO" "    Location:        s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/pmm-server/<pod>/srv.tar.gz"
            else
                log "INFO" "    Location:        ${SHARED_MOUNT_PATH}/backup_${TIMESTAMP}/pmm-server/<pod>/srv.tar.gz (central RWX)"
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
        log "INFO" "Target:  s3 -> s3://${S3_BUCKET}/${S3_PREFIX}/backups/backup_${TIMESTAMP}/  (manifest.json + 'latest')"
        log "INFO" "         ClickHouse uses its own native S3 layout (recorded in the manifest); PG/PMM/VM are under backups/<id>/"
    else
        local central_dir="${CENTRAL_BACKUP_PATH}/backup_${TIMESTAMP}"
        local detail="${central_dir}"
        [ -d "${central_dir}" ] && detail="${detail} ($(du -sh "${central_dir}" 2>/dev/null | cut -f1))"
        log "INFO" "Target:  shared -> ${detail}  (manifest.json + 'latest')"
        log "INFO" "         All components (incl. PostgreSQL pg_dump) under this dir"
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

# Dispatch: read-only 'list' command, or the default 'backup' run.
if [ "${COMMAND}" = "list" ]; then
    cmd_list "${LIST_ID}"
    exit 0
fi

# Execute main function
main "$@"
