#!/bin/sh
# Tool bootstrap for pmm-backup.sh, shared by every place the orchestrator runs.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE `command:`
# The backup CronJob's jobTemplate is the thing operators clone to run an ad-hoc backup or a
# restore:
#     kubectl create job --from=cronjob/<release>-backup ... -o yaml \
#       | yq '.spec.template.spec.containers[0].args = ["restore","--backup-id","latest","--yes"]'
# A clone that has to REPLACE `command` in order to change the operation would also throw away
# whatever bootstrap lived in it — and on any tools image that does not already carry jq and
# rclone the cloned Job would then fail pmm-backup.sh's preflight on a missing tool, in the
# middle of the DR it was written for. Keeping the bootstrap in `command` and the
# operation in `args` makes the swap safe: `args` is the only thing a caller ever rewrites.
#
# Usage:
#   backup-entrypoint.sh <pmm-backup.sh args...>   install tools, then exec pmm-backup.sh "$@"
#   backup-entrypoint.sh --ensure-tools-only       install tools and return; do not exec
#
# Environment:
#   PMM_TOOLS_REQUIRE_RCLONE=true   rclone is mandatory, not just nice to have (s3 mode)
#   PMM_TOOLS_STRICT=true           exit non-zero when a required tool is still missing
#
# STRICTNESS IS THE CALLER'S CHOICE, deliberately:
#   - Job pods pass STRICT=true. A Job that cannot get its tools must fail loudly and early:
#     backoffLimit retries it and the failed Job is the alert.
#   - The always-on backup-tools Deployment passes --ensure-tools-only WITHOUT strict, because
#     that pod is also the exec target for disaster recovery. An `apk add || exit 1` there took
#     DR out with it in three ordinary situations — an air-gapped or egress-restricted cluster,
#     a centralBackupStorage.tools.image override that already ships the tools but has no
#     working apk, and a non-Alpine image — because the container CrashLoopBackOff'd, and a
#     CrashLooping pod cannot be exec'd into to run a restore. It stays up Not Ready instead
#     (its readinessProbe reports the truth) so an operator can install the tools by hand.
#
# `apk add` NEEDS ROOT, so on OpenShift — or any cluster whose SCC/PodSecurity assigns a
# non-root UID — this install cannot succeed, and the fix is not in this script: the tools image
# must carry the tools, and the probe below then skips the install entirely. The chart's DEFAULT
# image does carry them, so this fallback only runs for an overridden image. DN-49 records that decision and the four alternatives
# measured against it (chart-shipped binaries, apk --usermode, downloading them, and mounting
# the official images as OCI volumes, which is the intended end state once its Kubernetes
# floor is low enough).
set -eu

ENSURE_ONLY=false
if [ "${1:-}" = "--ensure-tools-only" ]; then
    ENSURE_ONLY=true
    shift
fi

require_rclone="${PMM_TOOLS_REQUIRE_RCLONE:-false}"
strict="${PMM_TOOLS_STRICT:-false}"

# PROBE FIRST, install only what is missing. An image that already ships the tools (the
# documented air-gap answer) then needs no package repository at all.
need=""
jq --version   >/dev/null 2>&1 || need="${need} jq"
# rclone ONLY when this target actually needs it — the same rule the `missing` check below
# applies, which already knew rclone is optional in shared mode. Probing (and installing) it
# regardless put a package download on the critical path of EVERY scheduled Job, where the
# pre-Job design paid it once per backup-tools pod, and it counts against the Job's
# activeDeadlineSeconds.
if [ "${require_rclone}" = "true" ]; then
    rclone version >/dev/null 2>&1 || need="${need} rclone"
fi

if [ -n "${need}" ]; then
    echo "tools: installing${need}"
    # Unpinned on purpose: Alpine only carries current versions, so a pin breaks the install
    # the moment Alpine bumps. Ship a tools image instead if you need reproducible versions.
    apk add --no-cache ${need} >/dev/null 2>&1 \
        || echo "WARN: 'apk add${need}' failed (no repository access, or not an Alpine image)"
fi

# What is actually MISSING now — which is not the same list as what we tried to install:
# rclone is required only in s3 mode, and pmm-backup.sh's preflight applies exactly this rule.
missing=""
jq --version >/dev/null 2>&1 || missing="${missing} jq"
if [ "${require_rclone}" = "true" ]; then
    rclone version >/dev/null 2>&1 || missing="${missing} rclone"
fi
# The rclone-absent case is reported ONCE, by the success line below. Noting it here as well
# printed the same fact twice in every shared-mode start-up and Job log.

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
    # Probe with command -v, NOT `rclone version | head -1 || echo ...`: a pipeline's status is
    # its LAST element's, so head always succeeds and the fallback could never fire — the line
    # then reported an empty second field for the very tool it was reporting on.
    if command -v rclone >/dev/null 2>&1; then
        echo "tools: $(jq --version), $(rclone version | head -1)"
    else
        echo "tools: $(jq --version), rclone absent (not required for this target; 'pmm-backup.sh --target s3' would need it)"
    fi
fi

[ "${ENSURE_ONLY}" = "true" ] && exit 0

# exec, so pmm-backup.sh is PID 1's successor and receives TERM directly from Kubernetes —
# its EXIT/TERM traps are what release the per-component Leases.
#
# ABSOLUTE path, for the same reason the Job's `command` is absolute: a
# centralBackupStorage.tools.image override (documented for mirrors and air-gapped registries)
# may not carry /usr/local/bin on PATH. Resolving by bare name here would only move that
# failure one step later — past a bootstrap that had already reported success.
exec /usr/local/bin/pmm-backup.sh "$@"
