#!/bin/sh
# Tool bootstrap for pmm-backup.sh. Bootstrap lives in `command`, the operation in `args`,
# so a cloned Job only rewrites `args` (see DN-47, DN-49 in docs/pmm-backup-design-notes.md).
#
# Usage:
#   backup-entrypoint.sh <pmm-backup.sh args...>   install tools, then exec pmm-backup.sh
#   backup-entrypoint.sh --ensure-tools-only       install tools and return
#
# Environment:
#   PMM_TOOLS_REQUIRE_RCLONE=true   rclone is mandatory (s3 mode)
#   PMM_TOOLS_STRICT=true           exit non-zero if a tool is missing (Jobs). The backup-tools
#                                   Deployment runs non-strict so it stays exec-able for DR.
#   apk add needs root: on OpenShift the tools image must already carry jq and rclone.
set -eu

ENSURE_ONLY=false
if [ "${1:-}" = "--ensure-tools-only" ]; then
    ENSURE_ONLY=true
    shift
fi

require_rclone="${PMM_TOOLS_REQUIRE_RCLONE:-false}"
strict="${PMM_TOOLS_STRICT:-false}"

# Probe first; install only what is missing.
need=""
jq --version   >/dev/null 2>&1 || need="${need} jq"
# rclone only when the target needs it (s3); keeps the install off the Job's critical path.
if [ "${require_rclone}" = "true" ]; then
    rclone version >/dev/null 2>&1 || need="${need} rclone"
fi

if [ -n "${need}" ]; then
    echo "tools: installing${need}"
    # Unpinned: Alpine only carries current versions. Use a tools image for pinned versions.
    apk add --no-cache ${need} >/dev/null 2>&1 \
        || echo "WARN: 'apk add${need}' failed (no repository access, or not an Alpine image)"
fi

# rclone is required only in s3 mode (same rule as pmm-backup.sh preflight).
missing=""
jq --version >/dev/null 2>&1 || missing="${missing} jq"
if [ "${require_rclone}" = "true" ]; then
    rclone version >/dev/null 2>&1 || missing="${missing} rclone"
fi

if [ -n "${missing}" ]; then
    echo "ERROR: missing tool(s):${missing} — both backup and restore need them."
    echo "ERROR:   Fix by either:"
    echo "ERROR:     - giving this pod access to an Alpine package mirror, or"
    echo "ERROR:     - setting centralBackupStorage.tools.image to an image that already ships jq and rclone."
    if [ "${strict}" = "true" ]; then
        exit 1
    fi
    echo "ERROR:   Continuing anyway: this container stays up (Not Ready) so it can be inspected and exec'd into."
else
    # command -v, not `rclone version | head -1 || ...`: a pipeline's status is head's.
    if command -v rclone >/dev/null 2>&1; then
        echo "tools: $(jq --version), $(rclone version | head -1)"
    else
        echo "tools: $(jq --version), rclone absent (not required for this target; 'pmm-backup.sh --target s3' would need it)"
    fi
fi

[ "${ENSURE_ONLY}" = "true" ] && exit 0

# Absolute path: an overridden tools image may lack /usr/local/bin on PATH.
# As PID 1 (Job pod), forward TERM to all processes; the shell defers traps until the child exits.
if [ "$$" -eq 1 ]; then
    set +e
    # Trap before the fork (PID 1 drops an untrapped TERM); an early TERM is replayed below.
    term=""
    trap 'term=1; kill -TERM -1 2>/dev/null' TERM INT
    /usr/local/bin/pmm-backup.sh "$@" &
    child=$!
    [ -z "${term}" ] || kill -TERM "${child}" 2>/dev/null
    while :; do
        wait "${child}"; rc=$?
        kill -0 "${child}" 2>/dev/null || break
    done
    exit "${rc}"
fi
exec /usr/local/bin/pmm-backup.sh "$@"
