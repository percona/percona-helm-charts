#!/bin/sh
set -eu

################################################################################
# PMM-HA Restore Orchestrator
#
# Restores PostgreSQL, ClickHouse, VictoriaMetrics, PMM server /srv, and the
# encryption key produced by backup-orchestrator.sh. It is MANIFEST-DRIVEN and
# supports the same two targets as the backup:
#
#   --target s3      each engine restores from object storage (PG pg_restore from the
#                    dump, clickhouse-backup restore_remote, vmrestore -src=s3://,
#                    /srv via the pmm-backup rclone sidecar).
#   --target shared  each engine restores from the mounted RWX/NFS central volume
#                    (PG pg_restore from the dump, in-pod untar, vmrestore -src=fs://, /srv tar).
#
# Discovery uses the per-run manifest.json (PG dump databases, CH backup name,
# component status) — never a local consolidated directory. Run from the
# backup-tools pod (or any host with kubectl access + the central mount for shared).
#
# Shell: uses `local` and other common extensions beyond strict POSIX sh. Supported
# shells: BusyBox ash (the backup-tools image), dash, and bash — all implement these.
################################################################################

# ---- Default configuration --------------------------------------------------
NAMESPACE="${NAMESPACE:-demo}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"          # where backup-tools mounts the central vol (shared) / writes logs
METRICS_DIR="${METRICS_DIR:-/backups/.metrics}"
BACKUP_ID=""                                  # <timestamp> | backup_<timestamp> | latest
LIST_ONLY=false
LIST_ID=""                                    # backup id to inspect via the 'list' subcommand
DRY_RUN=false
FORCE=false
VERBOSE="${VERBOSE:-false}"
PARALLEL=true

# Target mode (must match how the backup was taken).
BACKUP_TARGET="${BACKUP_TARGET:-s3}"          # s3 | shared
SHARED_MOUNT_PATH="${SHARED_MOUNT_PATH:-/central}"  # central vol path INSIDE component pods (shared)

# S3 settings (target=s3)
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX=$(echo "${S3_PREFIX:-pmm-ha}" | sed 's|^/||; s|/$||')
S3_REGION="${S3_REGION:-us-east-1}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
# rclone provider profile for the temp S3 client pod: AWS | Minio | Ceph | Other
S3_PROVIDER="${S3_PROVIDER:-AWS}"
# Static S3 credentials (k8s Secret) for the temp pods (vmrestore + s3 client). Required on
# non-AWS S3-compatible storage; on AWS with IRSA leave empty (SA credential chain).
S3_SECRET_NAME="${S3_SECRET_NAME:-}"
S3_SECRET_ACCESS_KEY_KEY="${S3_SECRET_ACCESS_KEY_KEY:-access-key}"
S3_SECRET_SECRET_KEY_KEY="${S3_SECRET_SECRET_KEY_KEY:-secret-key}"
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"
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
S3_ENABLED=false

# Component flags (default: restore everything the manifest marks 'success')
RESTORE_POSTGRESQL="${RESTORE_POSTGRESQL:-false}"
RESTORE_CLICKHOUSE="${RESTORE_CLICKHOUSE:-false}"
RESTORE_VICTORIAMETRICS="${RESTORE_VICTORIAMETRICS:-false}"
RESTORE_PMM_SERVER="${RESTORE_PMM_SERVER:-false}"
RESTORE_ENCRYPTION_KEY="${RESTORE_ENCRYPTION_KEY:-false}"
EXPLICIT_SELECTION=false
# --skip-<component> markers, applied after the manifest-driven defaults (mirrors backup's --skip-*).
SKIP_POSTGRESQL=false; SKIP_CLICKHOUSE=false; SKIP_VICTORIAMETRICS=false; SKIP_PMM_SERVER=false; SKIP_ENCRYPTION_KEY=false

# PostgreSQL: logical restore (pg_restore). Databases come from the manifest; no options.

# ClickHouse (credentials from secret; restore runs in the live clickhouse-backup sidecar)
CH_SECRET_NAME="${CH_SECRET_NAME:-pmm-secret}"

# Timeouts (timeout wrapper, not kubectl --request-timeout)
KUBECTL_EXEC_TIMEOUT="${KUBECTL_EXEC_TIMEOUT:-600}"
KUBECTL_STATUS_TIMEOUT="${KUBECTL_STATUS_TIMEOUT:-30}"

# VictoriaMetrics restore (auto-detected from the vmstorage pod if unset)
VMRESTORE_IMAGE="${VMRESTORE_IMAGE:-}"
VM_STORAGE_PVC_PREFIX="${VM_STORAGE_PVC_PREFIX:-vmstorage-db-}"

# Central backup PVC (shared mode only; auto-detected from backup-tools pod if unset)
CENTRAL_BACKUP_PVC="${CENTRAL_BACKUP_PVC:-}"

# Labels (must match the backup script / cluster)
LABEL_PG_PRIMARY="postgres-operator.crunchydata.com/role=primary"
LABEL_CH_POD="clickhouse.altinity.com/chi"
LABEL_VM_STORAGE="app.kubernetes.io/name=vmstorage"
LABEL_PMM_SERVER="app.kubernetes.io/component=pmm-server"
LABEL_BACKUP_TOOLS="app.kubernetes.io/component=backup-tools"

# Derived / state
S3_BASE=""                 # ${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups
BACKUP_NAME=""             # backup_<timestamp>
MANIFEST_FILE=""           # local temp copy of manifest.json
MF_STATUS="" ; MF_TARGET="" ; MF_CREATED=""
MF_PG_STATUS="" ; MF_PG_DBS=""
MF_CH_STATUS="" ; MF_CH_NAME=""
MF_VM_STATUS="" ; MF_PMM_STATUS="" ; MF_ENC_STATUS=""
PMM_SAVED_REPLICAS="" ; PMM_STATEFULSET_NAME=""
RESTORE_START_TIME=0
ENCRYPTION_KEY_OK=false ; POSTGRESQL_OK=false ; CLICKHOUSE_OK=false
VICTORIAMETRICS_OK=false ; PMM_SERVER_OK=false
S3_CLIENT_POD=""
LOG_FILE=""

################################################################################
# Logging
################################################################################
init_log() {
    LOG_FILE="${BACKUP_DIR}/logs/restore_$(date +%Y%m%d-%H%M%S).log"
    if ! mkdir -p "${BACKUP_DIR}/logs" 2>/dev/null || ! : >>"${LOG_FILE}" 2>/dev/null; then
        LOG_FILE="/tmp/restore_$(date +%Y%m%d-%H%M%S).log"
        : >>"${LOG_FILE}" 2>/dev/null || true
    fi
}

log() {
    local level="$1"; shift
    # Always to stderr so progress shows even when a subshell captures stdout.
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" | tee -a "${LOG_FILE}" >&2 2>/dev/null || \
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
}

# Stream stdin (command output) to the log + stderr.
append_to_log() { tee -a "${LOG_FILE}" >&2 2>/dev/null || cat >&2; }

################################################################################
# S3 client (borrows the pmm-backup rclone sidecar — rclone + IRSA live there)
################################################################################
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

# rclone read ops (cat/lsf) inside the pmm-backup sidecar.
s3_rclone() {
    local pod
    pod=$(pick_s3_client_pod) || return 1
    timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${pod}" -c pmm-backup -- rclone "$@"
}

# True when an S3 object exists AND is non-empty. Proving this before streaming matters
# because every consumer downstream (pg_restore, tar, vmrestore) reports a missing object
# as an empty-input error indistinguishable from a genuine data problem.
#
# NB: `rclone size` on a MISSING path exits 0 and prints {"count":0,"bytes":0}. A non-empty
# result string is therefore NOT proof of existence — the byte count itself must be tested,
# which is why this is a predicate rather than a bytes-returning helper.
s3_object_present() {
    local bytes
    bytes=$(s3_rclone size --s3-no-check-bucket --json "$1" 2>/dev/null \
        | sed -n 's/.*"bytes":[ ]*\([0-9][0-9]*\).*/\1/p')
    [ "${bytes:-0}" -gt 0 ] 2>/dev/null
}

# Dedicated rclone client pod for s3 restores. The pmm-backup sidecar rides on the PMM
# pods, which this orchestrator scales to 0 BEFORE restoring components — so ordinal
# mapping (VM/PMM source lookup) and PG dump streaming would lose their S3 client exactly
# when they need it (and a re-run after a failed restore starts with PMM already down).
# Same image/env as the chart's sidecar, IRSA SA for creds; the container is deliberately
# named 'pmm-backup' so every exec call site works unchanged.
S3_CLIENT_IMAGE="${S3_CLIENT_IMAGE:-docker.io/rclone/rclone:1.74.3}"
RESTORE_CLIENT_POD="restore-s3-client-$$"

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
    return 0
}
delete_s3_client_pod() {
    kubectl delete pod -n "${NAMESPACE}" "${RESTORE_CLIENT_POD}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

################################################################################
# Manifest loading + field extraction (the per-run index drives discovery)
################################################################################
# jq is a hard requirement for manifest parsing (same as the backup side, which also
# generates the manifest with jq). Try to self-install on Alpine (backup-tools image).
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq >/dev/null 2>&1 || true
    fi
    command -v jq >/dev/null 2>&1
}

# Top-level scalar field of the loaded manifest.
manifest_top() { jq -r --arg k "$1" '.[$k] // empty' "${MANIFEST_FILE}" 2>/dev/null; }

# Component nested scalar field: mf_field <component> <key>
mf_field() { jq -r --arg c "$1" --arg k "$2" '.components[$c][$k] // empty' "${MANIFEST_FILE}" 2>/dev/null; }

# Resolve BACKUP_ID (incl. 'latest') -> BACKUP_NAME, fetch + parse manifest.json.
load_manifest() {
    if [ -z "${BACKUP_ID}" ]; then
        log "ERROR" "Missing --backup-id (e.g. 20260610-124515 or 'latest')"
        return 1
    fi
    local id="${BACKUP_ID}"
    if [ "${id}" = "latest" ]; then
        if [ "${S3_ENABLED}" = "true" ]; then
            id=$(s3_rclone cat "${S3_BASE}/latest" 2>/dev/null | tr -d '[:space:]' || true)
        else
            id=$(cat "${BACKUP_DIR}/latest" 2>/dev/null | tr -d '[:space:]' || true)
        fi
        if [ -z "${id}" ]; then log "ERROR" "Could not resolve 'latest' pointer (target=${BACKUP_TARGET})"; return 1; fi
        log "INFO" "Resolved 'latest' -> ${id}"
    fi
    case "${id}" in backup_*) BACKUP_NAME="${id}" ;; *) BACKUP_NAME="backup_${id}" ;; esac

    MANIFEST_FILE=$(mktemp /tmp/restore_manifest.XXXXXX 2>/dev/null || echo "/tmp/restore_manifest.$$")
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone cat "${S3_BASE}/${BACKUP_NAME}/manifest.json" > "${MANIFEST_FILE}" 2>/dev/null || true
    else
        cat "${BACKUP_DIR}/${BACKUP_NAME}/manifest.json" > "${MANIFEST_FILE}" 2>/dev/null || true
    fi
    if [ ! -s "${MANIFEST_FILE}" ]; then
        log "ERROR" "No manifest for ${BACKUP_NAME} (target=${BACKUP_TARGET})."
        [ "${S3_ENABLED}" = "true" ] && log "ERROR" "  Looked at ${S3_BASE}/${BACKUP_NAME}/manifest.json (need a reachable pmm-backup sidecar + --s3-bucket)"
        [ "${S3_ENABLED}" = "true" ] || log "ERROR" "  Looked at ${BACKUP_DIR}/${BACKUP_NAME}/manifest.json"
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

    log "INFO" "Backup ${BACKUP_NAME}: status=${MF_STATUS:-?} target=${MF_TARGET:-?} created=${MF_CREATED:-?}"
    if [ -n "${MF_TARGET}" ] && [ "${MF_TARGET}" != "${BACKUP_TARGET}" ]; then
        log "WARN" "Manifest target '${MF_TARGET}' != --target '${BACKUP_TARGET}'. Restore uses --target ${BACKUP_TARGET}; pass --target ${MF_TARGET} if that's wrong."
    fi
    return 0
}

list_backups() {
    local base
    if [ "${S3_ENABLED}" = "true" ]; then
        base="${S3_BASE}"
        log "INFO" "Backups in s3://${S3_BUCKET}/${S3_PREFIX}/backups/:"
        local latest ids id st
        latest=$(s3_rclone cat "${base}/latest" 2>/dev/null | tr -d '[:space:]' || true)
        ids=$(s3_rclone lsf --dirs-only "${base}/" 2>/dev/null | sed 's:/$::' | sort || true)
        if [ -z "${ids}" ]; then log "INFO" "  (none found — empty bucket/prefix or sidecar unreachable)"; return 0; fi
        for id in ${ids}; do
            MANIFEST_FILE=$(mktemp /tmp/lm.XXXXXX 2>/dev/null || echo "/tmp/lm.$$")
            s3_rclone cat "${base}/${id}/manifest.json" > "${MANIFEST_FILE}" 2>/dev/null || true
            st=$([ -s "${MANIFEST_FILE}" ] && manifest_top status || echo "no-manifest")
            rm -f "${MANIFEST_FILE}"
            log "INFO" "  ${id}  [${st:-?}]$([ "${id}" = "${latest}" ] && echo '  *latest')"
        done
    else
        log "INFO" "Backups in ${BACKUP_DIR}/:"
        local d id st
        for d in $(find "${BACKUP_DIR}" -maxdepth 1 -type d -name "backup_*" 2>/dev/null | sort -r); do
            id=$(basename "${d}")
            MANIFEST_FILE="${d}/manifest.json"
            st=$([ -s "${MANIFEST_FILE}" ] && manifest_top status || echo "no-manifest")
            log "INFO" "  ${id}  [${st:-?}]  $(du -sh "${d}" 2>/dev/null | cut -f1)"
        done
        [ -f "${BACKUP_DIR}/latest" ] && log "INFO" "  latest -> $(cat "${BACKUP_DIR}/latest" 2>/dev/null)"
    fi
}

# `list` subcommand: no id -> list all backups; with an id -> inspect that backup's manifest
# (per-component status + coordinates + files). Mirrors backup-orchestrator.sh's `list [id]`.
cmd_list() {
    local want="${1:-}" name objs
    ensure_jq || { log "ERROR" "jq is required for 'list' (Alpine: apk add jq; Debian: apt-get install jq)"; return 1; }
    if [ -z "${want}" ]; then list_backups; return 0; fi
    case "${want}" in backup_*) name="${want}" ;; *) name="backup_${want}" ;; esac
    MANIFEST_FILE=$(mktemp /tmp/lm.XXXXXX 2>/dev/null || echo "/tmp/lm.$$")
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone cat "${S3_BASE}/${name}/manifest.json" > "${MANIFEST_FILE}" 2>/dev/null || true
    else
        cat "${BACKUP_DIR}/${name}/manifest.json" > "${MANIFEST_FILE}" 2>/dev/null || true
    fi
    if [ ! -s "${MANIFEST_FILE}" ]; then log "ERROR" "No manifest for ${name} (target=${BACKUP_TARGET})"; rm -f "${MANIFEST_FILE}"; return 1; fi
    printf '=== %s  (status: %s, target: %s, %s) ===\n' "${name}" "$(manifest_top status)" "$(manifest_top target)" "$(manifest_top created)"
    printf '  %-16s %-9s %s\n' "COMPONENT" "STATUS" "DETAIL"
    printf '  %-16s %-9s %s\n' "postgresql"      "$(mf_field postgresql status)"      "dbs: $(mf_field postgresql databases)"
    printf '  %-16s %-9s %s\n' "clickhouse"      "$(mf_field clickhouse status)"      "name: $(mf_field clickhouse name)"
    printf '  %-16s %-9s %s\n' "victoriametrics" "$(mf_field victoriametrics status)" ""
    printf '  %-16s %-9s %s\n' "pmm-server"      "$(mf_field pmm-server status)"      ""
    printf '  %-16s %-9s %s\n' "encryption"      "$(mf_field encryption status)"      ""
    if [ "${S3_ENABLED}" = "true" ]; then
        printf '\n  Objects under s3://%s/%s/backups/%s/:\n' "${S3_BUCKET}" "${S3_PREFIX}" "${name}"
        objs=$(s3_rclone lsf "${S3_BASE}/${name}/" 2>/dev/null || true)
        if [ -n "${objs}" ]; then echo "${objs}" | sed 's/^/    /'; else echo "    (none)"; fi
    else
        printf '\n  Contents of %s/%s/ (sizes):\n' "${BACKUP_DIR}" "${name}"
        du -sh "${BACKUP_DIR}/${name}"/* 2>/dev/null | sed 's|^|    |' || echo "    (none)"
    fi
    rm -f "${MANIFEST_FILE}"
    return 0
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

################################################################################
# Help / args
################################################################################
show_help() {
    cat <<EOF
PMM-HA Restore Orchestrator (manifest-driven; mirrors backup-orchestrator.sh)

Usage: $0 [restore] --backup-id <id|latest> --target <s3|shared> [OPTIONS]
       $0 list [BACKUP_ID] --target <s3|shared> [--s3-bucket ...]

Commands:
  restore                    (default) Restore the selected components from a backup.
  list [BACKUP_ID]           List backups, or — given a BACKUP_ID — show that backup's per-component
                             status + files from its manifest.json (mirrors backup-orchestrator.sh).

Options:
  -h, --help                 Show this help
  -v, --verbose              Detailed output
  -n, --namespace NS         Namespace (default: demo)
  -d, --backup-dir DIR       backup-tools central mount / log dir (default: /backups)
  --backup-id ID             Backup to restore: <timestamp>, backup_<timestamp>, or 'latest'
  --list                     Alias for the 'list' subcommand (list all backups) and exit
  --dry-run                  Show what would run, change nothing
  --parallel | --sequential  Restore DB components in parallel (default) or one by one

  Target:
  --target s3|shared         Must match how the backup was taken (default: s3)
  --s3-bucket NAME           S3 bucket (required for --target s3)
  --s3-prefix PREFIX         Key prefix (default: pmm-ha)
  --s3-endpoint URL          S3-compatible endpoint (optional; MinIO/Ceph/... — also
                             passed to vmrestore as -customS3Endpoint)
  --s3-provider NAME         rclone provider for the temp S3 client: AWS (default),
                             Minio, Ceph, Other
  --s3-secret NAME           k8s Secret holding static S3 creds for the temp pods
                             (keys: access-key/secret-key; override via
                             S3_SECRET_ACCESS_KEY_KEY / S3_SECRET_SECRET_KEY_KEY).
                             Required on non-AWS storage; on AWS+IRSA leave unset
  --s3-service-account NAME  IRSA-annotated SA for the temp pods (default:
                             pmm-ha-backup-s3). Ignored when --s3-secret is set (temp
                             pods then use the default SA with static-key env)
  --s3-region REGION         AWS region for the vmrestore pod (default: us-east-1)
  --shared-mount-path PATH   Central vol path inside pods (default: /central)

  Component selection (default: all components the manifest marks 'success'):
  --postgresql  --clickhouse  --victoriametrics  --pmm-server  --encryption-key
  --skip-postgresql  --skip-clickhouse  --skip-victoriametrics  --skip-pmm-server  --skip-encryption-key
  --ch-secret NAME           Kubernetes secret for ClickHouse credentials (default: pmm-secret)

  PostgreSQL: logical restore via pg_restore (databases from the manifest; no options).

  --force                    Skip the confirmation prompt (required with no TTY)

Examples:
  $0 list --target s3 --s3-bucket my-bucket                  # list all backups
  $0 list backup_20260610-124515 --target shared            # inspect one backup
  $0 --target s3 --s3-bucket my-bucket --backup-id latest
  $0 --target shared --backup-id 20260610-124515 --postgresql
  $0 --target shared --backup-id latest --skip-victoriametrics --dry-run
EOF
    exit 0
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) show_help ;;
            -v|--verbose) VERBOSE=true ;;
            -n|--namespace) NAMESPACE="$2"; shift ;;
            -d|--backup-dir) BACKUP_DIR="$2"; shift ;;
            --backup-id) BACKUP_ID="$2"; shift ;;
            --list) LIST_ONLY=true ;;
            --dry-run) DRY_RUN=true ;;
            --parallel) PARALLEL=true ;;
            --sequential) PARALLEL=false ;;
            --target) BACKUP_TARGET="$2"; shift ;;
            --s3-bucket) S3_BUCKET="$2"; shift ;;
            --s3-prefix) S3_PREFIX=$(echo "$2" | sed 's|^/||; s|/$||'); shift ;;
            --s3-endpoint) S3_ENDPOINT="$2"; shift ;;
            --s3-provider) S3_PROVIDER="$2"; shift ;;
            --s3-secret) S3_SECRET_NAME="$2"; shift ;;
            --s3-service-account) S3_SERVICE_ACCOUNT="$2"; S3_SA_EXPLICIT=true; shift ;;
            --s3-region) S3_REGION="$2"; shift ;;
            --shared-mount-path) SHARED_MOUNT_PATH="$2"; shift ;;
            --postgresql) [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false; RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }; RESTORE_POSTGRESQL=true ;;
            --clickhouse) [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_VICTORIAMETRICS=false; RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }; RESTORE_CLICKHOUSE=true ;;
            --victoriametrics) [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }; RESTORE_VICTORIAMETRICS=true ;;
            --pmm-server) [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false; RESTORE_ENCRYPTION_KEY=false; EXPLICIT_SELECTION=true; }; RESTORE_PMM_SERVER=true ;;
            --encryption-key) [ "${EXPLICIT_SELECTION}" = "false" ] && { RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false; RESTORE_PMM_SERVER=false; EXPLICIT_SELECTION=true; }; RESTORE_ENCRYPTION_KEY=true ;;
            --skip-postgresql) SKIP_POSTGRESQL=true ;;
            --skip-clickhouse) SKIP_CLICKHOUSE=true ;;
            --skip-victoriametrics) SKIP_VICTORIAMETRICS=true ;;
            --skip-pmm-server) SKIP_PMM_SERVER=true ;;
            --skip-encryption-key) SKIP_ENCRYPTION_KEY=true ;;
            --ch-secret) CH_SECRET_NAME="$2"; shift ;;
            --force) FORCE=true ;;
            *) log "ERROR" "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done

    case "${BACKUP_TARGET}" in
        s3) S3_ENABLED=true; S3_BASE="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups" ;;
        shared) S3_ENABLED=false ;;
        *) echo "Error: invalid --target '${BACKUP_TARGET}' (must be s3 or shared)" >&2; exit 1 ;;
    esac
    # No LIST_ONLY exemption: without a bucket, list would query rclone path "s3:/pmm-ha/…"
    # (bucket "pmm-ha") and silently print "no backups" with exit 0 — during an incident
    # that reads as data loss instead of a missing flag.
    if [ "${S3_ENABLED}" = "true" ] && [ -z "${S3_BUCKET}" ]; then
        echo "Error: --target s3 requires --s3-bucket" >&2; exit 1
    fi
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
    return 0
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

preflight_checks() {
    local ok=true
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || { log "ERROR" "Namespace ${NAMESPACE} not found / no access"; ok=false; }
    command -v timeout >/dev/null 2>&1 || { log "ERROR" "timeout command not found"; ok=false; }
    ensure_jq || { log "ERROR" "jq is required (manifest parsing) but not available (Alpine: apk add jq; Debian: apt-get install jq)"; ok=false; }
    [ "${ok}" = "true" ] || return 1
    log "INFO" "Pre-flight checks passed"
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
        if [ -n "${S3_SECRET_NAME}" ]; then
            if ! kubectl get secret "${S3_SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
                log "ERROR" "[Preflight] S3 secret '${S3_SECRET_NAME}' not found in ${NAMESPACE}; every temp restore pod would be rejected at admission"
                fail=1
            else
                local _key
                for _key in "${S3_SECRET_ACCESS_KEY_KEY}" "${S3_SECRET_SECRET_KEY_KEY}"; do
                    if ! kubectl get secret "${S3_SECRET_NAME}" -n "${NAMESPACE}" \
                        -o "jsonpath={.data.${_key}}" 2>/dev/null | grep -q .; then
                        log "ERROR" "[Preflight] S3 secret '${S3_SECRET_NAME}' has no key '${_key}'"
                        fail=1
                    fi
                done
            fi
        fi
        if [ -n "${TEMP_POD_SA_LINE}" ] \
            && ! kubectl get serviceaccount "${S3_SERVICE_ACCOUNT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            log "ERROR" "[Preflight] ServiceAccount '${S3_SERVICE_ACCOUNT}' not found in ${NAMESPACE}; every temp restore pod would be rejected at admission"
            fail=1
        fi
    fi

    # ---- Encryption key ----------------------------------------------------------
    if [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${MF_ENC_STATUS}" = "success" ]; then
        if [ "${S3_ENABLED}" = "true" ]; then
            if [ "${s3_readable}" = "true" ] \
                && ! s3_object_present "${S3_BASE}/${BACKUP_NAME}/encryption/pg-encryption-key.yaml"; then
                log "ERROR" "[Preflight] encryption: key object missing or empty in S3 (--skip-encryption-key to proceed without it)"
                fail=1
            fi
        elif [ ! -s "${BACKUP_DIR}/${BACKUP_NAME}/encryption/pg-encryption-key.yaml" ]; then
            log "ERROR" "[Preflight] encryption: ${BACKUP_DIR}/${BACKUP_NAME}/encryption/pg-encryption-key.yaml missing or empty (--skip-encryption-key to proceed without it)"
            fail=1
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
                    if [ "${s3_readable}" = "true" ] \
                        && ! s3_object_present "${S3_BASE}/${BACKUP_NAME}/postgresql/${_db}.dump"; then
                        log "ERROR" "[Preflight] postgresql: dump missing or empty in S3: ${_db}.dump"
                        fail=1
                    fi
                elif [ ! -s "${BACKUP_DIR}/${BACKUP_NAME}/postgresql/${_db}.dump" ]; then
                    log "ERROR" "[Preflight] postgresql: dump missing or empty: ${BACKUP_DIR}/${BACKUP_NAME}/postgresql/${_db}.dump"
                    fail=1
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
            local _ch_list="" _ch_rc=0
            _ch_list=$(timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${_chpod}" -c clickhouse-backup -- \
                clickhouse-backup list remote \
                --env "S3_BUCKET=${S3_BUCKET}" --env "S3_PATH=${S3_PREFIX}/clickhouse" 2>/dev/null) || _ch_rc=$?
            if [ "${_ch_rc}" -ne 0 ]; then
                log "ERROR" "[Preflight] clickhouse: could not list remote backups (exit ${_ch_rc}); is the 'clickhouse-backup' sidecar running in ${_chpod}?"
                log "ERROR" "[Preflight]   Not treating this as 'backup absent' — the check itself failed. Fix the sidecar, or pass --skip-clickhouse."
                fail=1
            elif ! echo "${_ch_list}" | awk '{print $1}' | grep -Fxq "${MF_CH_NAME}"; then
                log "ERROR" "[Preflight] clickhouse: remote backup '${MF_CH_NAME}' not found under s3://${S3_BUCKET}/${S3_PREFIX}/clickhouse"
                log "ERROR" "[Preflight]   ClickHouse retention prunes independently of the central backups, so an older backup can outlive its ClickHouse half."
                log "ERROR" "[Preflight]   Restore a newer backup, or pass --skip-clickhouse to restore everything else without QAN data."
                fail=1
            fi
        elif [ ! -s "${BACKUP_DIR}/${BACKUP_NAME}/clickhouse/${MF_CH_NAME}.tar.gz" ]; then
            log "ERROR" "[Preflight] clickhouse: ${BACKUP_DIR}/${BACKUP_NAME}/clickhouse/${MF_CH_NAME}.tar.gz missing or empty (--skip-clickhouse to drop it)"
            fail=1
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
                    if [ "${S3_ENABLED}" = "true" ]; then
                        if ! s3_rclone lsf "${S3_BASE}/${BACKUP_NAME}/victoriametrics/${_sub}/${_vmname}/" 2>/dev/null | grep -q .; then
                            log "ERROR" "[Preflight] victoriametrics: source for ordinal '${_ord}' is empty (${_sub}/${_vmname})"
                            fail=1
                        fi
                    elif ! ls -A "${BACKUP_DIR}/${BACKUP_NAME}/victoriametrics/${_sub}/${_vmname}" 2>/dev/null | grep -q .; then
                        log "ERROR" "[Preflight] victoriametrics: source for ordinal '${_ord}' is empty (${_sub}/${_vmname})"
                        fail=1
                    fi
                done
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
            while [ "${_i}" -lt "${_replicas}" ]; do
                _sub=$(pmm_src_subdir_for_ord "${_i}" 2>/dev/null || echo "")
                if [ -z "${_sub}" ]; then
                    # restore_pmm_server() only WARNs and skips here, so without this gate a
                    # PMM replica silently keeps its pre-restore /srv while the run reports success.
                    log "ERROR" "[Preflight] pmm-server: backup has no /srv directory for ordinal ${_i} (${_replicas} replica(s) expected)"
                    fail=1
                elif [ "${S3_ENABLED}" = "true" ]; then
                    if ! s3_object_present "${S3_BASE}/${BACKUP_NAME}/pmm-server/${_sub}/srv.tar.gz"; then
                        log "ERROR" "[Preflight] pmm-server: srv.tar.gz missing or empty for ordinal ${_i} (${_sub})"
                        fail=1
                    fi
                elif [ ! -s "${BACKUP_DIR}/${BACKUP_NAME}/pmm-server/${_sub}/srv.tar.gz" ]; then
                    log "ERROR" "[Preflight] pmm-server: ${BACKUP_DIR}/${BACKUP_NAME}/pmm-server/${_sub}/srv.tar.gz missing or empty"
                    fail=1
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

################################################################################
# Metrics
################################################################################
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
# Locking (shares lock names with backup-orchestrator.sh)
################################################################################
acquire_component_lock() {
    local component=$1 lock_dir="${BACKUP_DIR}/.backup_${1}.lock" existing_pid
    if mkdir "${lock_dir}" 2>/dev/null; then echo $$ > "${lock_dir}/pid"; log "INFO" "Acquired ${component} lock (PID $$)"; return 0; fi
    existing_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
    if [ -n "${existing_pid}" ] && kill -0 "${existing_pid}" 2>/dev/null; then
        log "ERROR" "Another backup/restore holds the ${component} lock (PID: ${existing_pid}); aborting"; exit 1
    fi
    log "WARN" "Stale ${component} lock (PID: ${existing_pid}), removing"; rm -rf "${lock_dir}"
    mkdir "${lock_dir}" 2>/dev/null || { log "ERROR" "Cannot acquire ${component} lock (lost race)"; exit 1; }
    echo $$ > "${lock_dir}/pid"; log "INFO" "Acquired ${component} lock (PID $$, stale recovered)"
}

release_component_lock() {
    local lock_dir="${BACKUP_DIR}/.backup_${1}.lock"
    [ "$(cat "${lock_dir}/pid" 2>/dev/null || echo "")" = "$$" ] && rm -rf "${lock_dir}" 2>/dev/null || true
}

acquire_restore_locks() {
    [ "${RESTORE_CLICKHOUSE}" = "true" ] && acquire_component_lock "clickhouse"
    # pmm-server lock is unconditional: every restore scales PMM down/up (so nothing writes the
    # DBs mid-restore), regardless of which components were selected.
    acquire_component_lock "pmm-server"
    [ "${RESTORE_POSTGRESQL}" = "true" ] && acquire_component_lock "postgresql"
    [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && acquire_component_lock "victoriametrics"
    return 0
}

release_restore_locks() {
    [ "${RESTORE_CLICKHOUSE}" = "true" ] && release_component_lock "clickhouse"
    release_component_lock "pmm-server"
    [ "${RESTORE_POSTGRESQL}" = "true" ] && release_component_lock "postgresql"
    [ "${RESTORE_VICTORIAMETRICS}" = "true" ] && release_component_lock "victoriametrics"
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
    release_restore_locks
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
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone cat "${S3_BASE}/${BACKUP_NAME}/encryption/pg-encryption-key.yaml" > "${tmp}" 2>/dev/null || true
    else
        cat "${BACKUP_DIR}/${BACKUP_NAME}/encryption/pg-encryption-key.yaml" > "${tmp}" 2>/dev/null || true
    fi
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
                log "INFO" "[PostgreSQL] [DRY RUN] rclone cat ${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/${BACKUP_NAME}/postgresql/${db}.dump | pg_restore --clean --if-exists -d ${db} (in ${pg_pod})"
            else
                log "INFO" "[PostgreSQL] [DRY RUN] pg_restore --clean --if-exists -d ${db} < ${BACKUP_DIR}/${BACKUP_NAME}/postgresql/${db}.dump (in ${pg_pod})"
            fi
            continue
        fi
        rc=0
        log "INFO" "[PostgreSQL] Restoring database ${db} into ${pg_pod}..."
        local pr_out; pr_out=$(mktemp /tmp/pgrestore.XXXXXX 2>/dev/null || echo "/tmp/pgrestore.$$")
        if [ "${S3_ENABLED}" = "true" ]; then
            local uri="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/${BACKUP_NAME}/postgresql/${db}.dump"
            local s3pod; s3pod=$(pick_s3_client_pod) || { log "ERROR" "[PostgreSQL] No pmm-backup sidecar to read the dump"; rm -f "${pr_out}"; return 1; }
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
            local dump="${BACKUP_DIR}/${BACKUP_NAME}/postgresql/${db}.dump"
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
            log "INFO" "[ClickHouse] [DRY RUN] kubectl exec ${ch_pod} -c clickhouse-backup -- clickhouse-backup restore_remote --env S3_BUCKET=${S3_BUCKET} --env S3_PATH=${S3_PREFIX}/clickhouse --rm ${name}"
        else
            log "INFO" "[ClickHouse] [DRY RUN] kubectl exec ${ch_pod} -c clickhouse-backup -- sh -c 'tar -xzf ${SHARED_MOUNT_PATH}/${BACKUP_NAME}/clickhouse/${name}.tar.gz -C /var/lib/clickhouse/backup && clickhouse-backup restore --rm ${name}'"
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
        log "INFO" "[ClickHouse] restore_remote --rm ${name} (from s3://${S3_BUCKET}/${S3_PREFIX}/clickhouse, in ${ch_pod})..."
        timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${ch_pod}" -c clickhouse-backup -- \
            clickhouse-backup restore_remote \
            --env "S3_BUCKET=${S3_BUCKET}" --env "S3_PATH=${S3_PREFIX}/clickhouse" \
            --rm "${name}" >>"${LOG_FILE}" 2>&1 || rc=$?
    else
        local tar="${SHARED_MOUNT_PATH}/${BACKUP_NAME}/clickhouse/${name}.tar.gz"
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

delete_vm_restore_pod() {
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
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone lsf --dirs-only "${S3_BASE}/${BACKUP_NAME}/victoriametrics/" 2>/dev/null \
            | sed 's:/$::' | grep -E "\-${ord}\$" | head -1
    else
        ls -1 "${BACKUP_DIR}/${BACKUP_NAME}/victoriametrics/" 2>/dev/null \
            | grep -E "\-${ord}\$" | head -1
    fi
}

# Count vmstorage ordinals present in the backup (source). Used to fail fast on a shard-count
# mismatch with the target before anything is scaled down: restoring an N-shard backup into a
# different number of target pods either silently drops the extra source shards (source > target)
# or runs the whole restore then fails on a missing ordinal (target > source).
vm_src_ordinal_count() {
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone lsf --dirs-only "${S3_BASE}/${BACKUP_NAME}/victoriametrics/" 2>/dev/null | grep -c '/$'
    else
        ls -1 "${BACKUP_DIR}/${BACKUP_NAME}/victoriametrics/" 2>/dev/null | grep -c '[^[:space:]]'
    fi
}

vm_src_for_pod() {
    local pod="$1" name="vm_backup_${BACKUP_NAME#backup_}" ord sub
    ord="${pod##*-}"                        # trailing ordinal of the target vmstorage pod
    sub=$(vm_src_subdir_for_ord "${ord}")   # backup dir for that ordinal (source release name)
    # No silent fallback to the target pod's own name: an empty lookup means the S3/fs
    # listing failed (e.g. no rclone client) or the backup lacks this ordinal — restoring
    # from a guessed path produced a wasted full run once already. Caller must handle rc=1.
    [ -z "${sub}" ] && return 1
    if [ "${S3_ENABLED}" = "true" ]; then
        echo "s3://${S3_BUCKET}/${S3_PREFIX}/backups/${BACKUP_NAME}/victoriametrics/${sub}/${name}"
    else
        echo "fs://${SHARED_MOUNT_PATH}/${BACKUP_NAME}/victoriametrics/${sub}/${name}"
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
    vm_src_count=$(vm_src_ordinal_count)
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
            delete_vm_restore_pod "${restore_pod}"; continue
        fi
        timeout "${KUBECTL_STATUS_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -c vmrestore -- rm -f /vmstorage-data/flock.lock 2>/dev/null || true
        exec_out=$(mktemp /tmp/vmrestore.XXXXXX 2>/dev/null || echo "/tmp/vmrestore.$$"); rc=0
        # -loggerLevel=WARN silences vmrestore's per-part "downloading/deleting" info spam; its
        # full output still goes to the log FILE (not the console). On failure we surface the tail.
        timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -c vmrestore -- \
            /vmrestore-prod -src="${src}" -storageDataPath=/vmstorage-data ${vm_endpoint_flag} -concurrency=10 -loggerLevel=WARN >"${exec_out}" 2>&1 || rc=$?
        cat "${exec_out}" >> "${LOG_FILE}" 2>/dev/null || true
        delete_vm_restore_pod "${restore_pod}"
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
    if [ "${S3_ENABLED}" = "true" ]; then
        s3_rclone lsf --dirs-only "${S3_BASE}/${BACKUP_NAME}/pmm-server/" 2>/dev/null | sed 's:/$::' | grep -E "\-${ord}\$" | head -1
    else
        ls -1 "${BACKUP_DIR}/${BACKUP_NAME}/pmm-server/" 2>/dev/null | grep -E "\-${ord}\$" | head -1
    fi
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
        if ! create_pmm_restore_pod "${restore_pod}" "${pvc}" "${image}"; then delete_vm_restore_pod "${restore_pod}"; continue; fi
        rc=0
        if [ "${S3_ENABLED}" = "true" ]; then
            local uri="${RCLONE_REMOTE}:${S3_BUCKET}/${S3_PREFIX}/backups/${BACKUP_NAME}/pmm-server/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from S3..."
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -- \
                sh -c "rclone cat --s3-no-check-bucket '${uri}' | tar -xzf - -C /srv --no-same-owner && rm -rf /srv/ha" >>"${LOG_FILE}" 2>&1 || rc=$?
        else
            local tb="${SHARED_MOUNT_PATH}/${BACKUP_NAME}/pmm-server/${src_subdir}/srv.tar.gz"
            log "INFO" "[PMMServer] Restoring /srv (ord ${ord}) -> ${pvc} from ${tb}..."
            timeout "${KUBECTL_EXEC_TIMEOUT}" kubectl exec -n "${NAMESPACE}" "${restore_pod}" -- \
                sh -c "tar -xzf '${tb}' -C /srv --no-same-owner && rm -rf /srv/ha" >>"${LOG_FILE}" 2>&1 || rc=$?
        fi
        delete_vm_restore_pod "${restore_pod}"
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
# Main
################################################################################
main() {
    # Optional leading subcommand: 'restore' (default) or 'list [BACKUP_ID]'. Mirrors
    # backup-orchestrator.sh so both tools share the same `list [id]` UX. (--list still works.)
    if [ $# -gt 0 ]; then
        case "$1" in
            list) LIST_ONLY=true; shift ;;
            restore) shift ;;
        esac
    fi
    if [ "${LIST_ONLY}" = "true" ] && [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then LIST_ID="$1"; shift; fi
    parse_args "$@"
    init_log

    log "INFO" "================================================================================"
    log "INFO" "PMM-HA Restore Orchestrator"
    log "INFO" "================================================================================"
    log "INFO" "Namespace: ${NAMESPACE}  Target: ${BACKUP_TARGET}  Log: ${LOG_FILE}"

    if [ "${LIST_ONLY}" = "true" ]; then cmd_list "${LIST_ID}"; exit 0; fi
    if ! preflight_checks; then exit 1; fi

    # s3 mode: bring up the dedicated rclone client pod BEFORE anything reads S3 — the
    # pmm-backup sidecar disappears with the PMM scale-down (and after a failed restore,
    # a re-run starts with PMM already at 0, so even load_manifest needs this).
    if [ "${S3_ENABLED}" = "true" ] && [ "${DRY_RUN}" != "true" ]; then
        trap restore_cleanup EXIT INT TERM
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

    if [ "${DRY_RUN}" != "true" ]; then trap restore_cleanup EXIT INT TERM; acquire_restore_locks; fi
    RESTORE_START_TIME=$(date +%s)

    # 1. Encryption key first — abort if it fails (can't decrypt restored data otherwise).
    [ "${DRY_RUN}" != "true" ] && write_restore_metrics 1 "encryption_key" 0 0 0 0 0 0 0
    if [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && [ "${MF_ENC_STATUS}" = "success" ]; then
        restore_encryption_key && ENCRYPTION_KEY_OK=true
    else
        [ "${RESTORE_ENCRYPTION_KEY}" = "true" ] && log "WARN" "Encryption key requested but not in this backup"
        ENCRYPTION_KEY_OK=true
    fi
    if [ "${ENCRYPTION_KEY_OK}" != "true" ] && [ "${FORCE}" != "true" ]; then
        log "ERROR" "Encryption key restore failed. Aborting (use --force to override)."
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

main "$@"
