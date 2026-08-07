#!/bin/sh
# PMM-HA scheduled-backup trigger wrapper.
#
# Runs INSIDE the backup-tools pod — the backup CronJob execs `cron-backup.sh` here. A naive
# CronJob would `kubectl exec ... -- backup-orchestrator.sh` and hold that exec stream open
# for the whole (multi-hour) backup; a single apiserver/network blip then kills the
# orchestrator mid-upload, and the Job's retry collides with the still-held per-component
# locks. Instead this wrapper:
#   1. starts backup-orchestrator.sh DETACHED (setsid/nohup) so it outlives the exec stream,
#      recording its exit code in a small status file next to the log, and
#   2. polls that status file for completion.
# If the trigger's exec dies, the detached backup keeps running and the CronJob's retry
# re-execs this wrapper with the SAME --run-id, which RE-ATTACHES to the poll (no second
# orchestrator, no lock collision).
#
# If instead the backup-tools pod ITSELF dies mid-backup (eviction/OOM/Recreate rollout),
# the detached orchestrator never writes its status. A stale `.started` would otherwise make
# every future trigger re-attach and poll a never-arriving status forever, silently wedging
# the whole schedule (concurrencyPolicy: Forbid then skips every run). To prevent that, a run
# whose log has not advanced in CRON_BACKUP_STALL_MIN minutes is treated as CRASHED and
# restarted instead of re-attached. A CronJob-level activeDeadlineSeconds is the final bound.
#
# Usage: cron-backup.sh [--run-id ID] [backup-orchestrator.sh options...]
#   --run-id  Stable identifier for this scheduled run (the CronJob passes the Job name), so
#             retries reconnect to the same backup. Defaults to a per-process id if omitted.
set -eu

BACKUP_DIR="${BACKUP_DIR:-/backups}"
LOGDIR="${BACKUP_DIR}/.logs"
mkdir -p "${LOGDIR}"

# Hidden re-entry: the detached child calls back here to run the orchestrator and capture its
# exit code next to the log. Kept as a self re-exec so setsid/nohup run a real file, not a
# shell function, and so there is zero nested-quoting in the CronJob manifest.
if [ "${1:-}" = "__run" ]; then
    _rid="${2:-}"
    [ -n "${_rid}" ] || { echo "[cron-backup] __run requires a run id" >&2; exit 2; }
    shift 2
    _log="${LOGDIR}/cron-${_rid}.log"
    _status="${LOGDIR}/cron-${_rid}.status"
    # Capture the exit code without letting `set -e` abort before we record it.
    backup-orchestrator.sh "$@" >"${_log}" 2>&1 && _rc=0 || _rc=$?
    # Publish atomically: write the fully-formed file, then rename into place, so a polling
    # reader never sees a 0-byte .status mid-write (which would read back as an empty, then
    # non-numeric, exit code).
    echo "${_rc}" > "${_status}.tmp" && mv -f "${_status}.tmp" "${_status}"
    exit 0
fi

POLL_INTERVAL="${CRON_BACKUP_POLL_INTERVAL:-30}"
# A detached run whose log has not advanced in this many minutes is treated as crashed
# (pod evicted/OOM/rolled) rather than in-flight — generous, so a legitimately quiet upload
# phase is never mistaken for a crash.
STALL_MIN="${CRON_BACKUP_STALL_MIN:-15}"
# Prune leftover per-run marker/log files older than this many days so .logs/ (which the
# orchestrator's backup retention does not cover) doesn't grow unbounded on a schedule.
MARKER_RETENTION_DAYS="${CRON_BACKUP_MARKER_RETENTION_DAYS:-7}"

RUN_ID=""
if [ "${1:-}" = "--run-id" ]; then RUN_ID="${2:-}"; shift 2; fi
# Fallback id (manual invocation, or an empty Job-name label): still detaches, but retries
# won't reconnect since the id differs per process — acceptable degradation.
[ -n "${RUN_ID}" ] || RUN_ID="manual-$$"

STARTED="${LOGDIR}/cron-${RUN_ID}.started"
STATUS="${LOGDIR}/cron-${RUN_ID}.status"
LOG="${LOGDIR}/cron-${RUN_ID}.log"

# Resolve this script to an absolute path so the detached re-exec finds it regardless of CWD.
SELF="$(command -v -- "$0" 2>/dev/null || true)"
[ -n "${SELF}" ] || SELF="$0"

# Housekeeping: drop stale per-run files so .logs/ doesn't grow unbounded over months.
find "${LOGDIR}" -maxdepth 1 -name 'cron-*' -type f -mtime "+${MARKER_RETENTION_DAYS}" -delete 2>/dev/null || true

# Start "$@" fully detached so it survives this exec session ending.
detach() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" >/dev/null 2>&1 &
    elif command -v nohup >/dev/null 2>&1; then
        nohup "$@" >/dev/null 2>&1 &
    else
        "$@" >/dev/null 2>&1 &
    fi
}

# File mtime as epoch seconds, portable across busybox/GNU (`stat -c %Y`) and BSD (`stat -f %m`).
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Is the detached run for this id still making progress? Uses the log's mtime as a heartbeat
# (restart-proof across pod restarts, no PID/proc dependency): no log yet = just starting =
# alive; log touched within STALL_MIN = alive; otherwise the writer is gone (crashed). If the
# mtime can't be read at all, err toward "alive" so a live backup is never killed — the
# CronJob's activeDeadlineSeconds is the hard backstop for a genuine wedge.
run_is_alive() {
    [ -f "${LOG}" ] || return 0
    _now="$(date +%s 2>/dev/null)"
    _mt="$(mtime_epoch "${LOG}")"
    [ -n "${_now}" ] && [ -n "${_mt}" ] || return 0
    [ "$(( _now - _mt ))" -le "$(( STALL_MIN * 60 ))" ]
}

start_run() {
    : > "${STARTED}"
    rm -f "${STATUS}"
    echo "[cron-backup] starting detached backup run '${RUN_ID}' (log: ${LOG})"
    detach "${SELF}" __run "${RUN_ID}" "$@"
}

# Decide: start fresh, re-attach to a live run, or restart a crashed one.
if [ ! -f "${STARTED}" ]; then
    start_run "$@"
elif [ -f "${STATUS}" ]; then
    echo "[cron-backup] backup run '${RUN_ID}' already finished; reporting its result"
elif run_is_alive; then
    echo "[cron-backup] backup run '${RUN_ID}' already in flight; re-attaching"
else
    echo "[cron-backup] backup run '${RUN_ID}' stalled >${STALL_MIN}m with no result (prior pod likely died); restarting"
    rm -f "${STARTED}" "${STATUS}"
    start_run "$@"
fi

# Poll for completion. Disposable stream: it can die and be retried without affecting the
# detached backup. The stall watchdog breaks the poll if the detached run dies mid-flight, so
# the Job fails (and its retry / the next schedule restarts) instead of polling forever.
while [ ! -f "${STATUS}" ]; do
    sleep "${POLL_INTERVAL}"
    if ! run_is_alive; then
        echo "[cron-backup] run '${RUN_ID}' stalled >${STALL_MIN}m with no status; treating as crashed" >&2
        rm -f "${STARTED}"
        exit 1
    fi
done

echo "===== backup-orchestrator log (${RUN_ID}) ====="
cat "${LOG}" 2>/dev/null || true
echo "===== end log (${RUN_ID}) ====="

# Robust read: a missing / empty / non-numeric status counts as a failure — never `exit ""`.
CODE="$(cat "${STATUS}" 2>/dev/null || true)"
case "${CODE}" in
    ''|*[!0-9]*) CODE=1 ;;
esac
echo "[cron-backup] run '${RUN_ID}' finished with exit code ${CODE}"

# Tidy this run's state markers now that the result is reported; the .log is kept for
# debugging and aged out by the prune above.
rm -f "${STARTED}" "${STATUS}"
exit "${CODE}"
