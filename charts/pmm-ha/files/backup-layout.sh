# shellcheck shell=sh
################################################################################
# PMM-HA backup layout + storage access — SOURCED by backup-orchestrator.sh and
# restore-orchestrator.sh. Not executable on its own.
#
# This file exists because the two orchestrators previously carried their own copies of all
# of this. The copies drifted, and the drift was not theoretical: a layout migration updated
# one script's path builders and not the other's, so a restore's pre-flight validated the new
# location while the restore itself read the old one — failing only after PMM had been scaled
# to zero. Both scripts ship from one ConfigMap into one pod, so there is no reason for two
# definitions of where a backup lives or how to read it.
#
# Callers must define, before sourcing:
#   S3_ENABLED  true|false        RCLONE_REMOTE  rclone remote name
#   S3_BUCKET   S3_PREFIX         BACKUP_DIR     orchestrator's view of the central volume
#   SHARED_MOUNT_PATH             component pods' view of that same volume
#   backup_id_default()           a FUNCTION echoing the id to assume when none is passed.
#                                 A function, not a variable: restore does not know the id
#                                 until it has resolved 'latest' and read the manifest, so a
#                                 variable captured at source time is either unset (aborting
#                                 under set -u) or stale.
# and must provide: s3_rclone(), s3_rclone_rcat(), s3_rclone_purge(), pick_s3_client_pod(),
# log(), NAMESPACE, KUBECTL_STATUS_TIMEOUT, LOG_FILE.
################################################################################

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
store_exists() {
    if [ "${S3_ENABLED}" = "true" ]; then s3_rclone lsf "$1" >/dev/null 2>&1
    else [ -e "$1" ]; fi
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
# A failed delete is forgivable ONLY if the thing is provably gone. `! store_exists` was
# wrong: store_exists is two-state (non-zero = absent OR unreachable), so unreachable storage
# read as "already deleted" and a sweep that deleted nothing reported success and then removed
# the manifest. Here absence must be POSITIVELY established: a listing that succeeds and comes
# back empty. Anything else is a failure.
store_absent() {
    _sa_out=$(store_list_files "$(dirname "$1")" 2>/dev/null) || return 1
    ! printf '%s\n' "${_sa_out}" | grep -Fxq "$(basename "$1")"
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
