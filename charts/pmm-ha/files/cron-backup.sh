#!/bin/sh
# PMM-HA scheduled-backup trigger wrapper.
#
# Runs INSIDE the backup-tools pod — the backup CronJob execs `cron-backup.sh` here. A naive
# CronJob would `kubectl exec ... -- pmm-backup.sh backup` and hold that exec stream open
# for the whole (multi-hour) backup; a single apiserver/network blip then kills the
# orchestrator mid-upload, and the Job's retry collides with the still-held per-component
# locks. Instead this wrapper:
#   1. starts `pmm-backup.sh backup` DETACHED (setsid/nohup) so it outlives the exec stream,
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
# Usage: cron-backup.sh [--run-id ID] [pmm-backup.sh backup options...]
#   --run-id  Stable identifier for this scheduled run (the CronJob passes the Job name), so
#             retries reconnect to the same backup. Defaults to a per-process id if omitted.
set -eu

BACKUP_DIR="${BACKUP_DIR:-/backups}"
LOGDIR="${BACKUP_DIR}/.logs"
mkdir -p "${LOGDIR}"

# The ONE marker that is not keyed by --run-id: "an orchestrator is running right now, and it
# belongs to this run". Everything else here is per-run-id, which is what a Job RETRY needs —
# but it is exactly wrong across SCHEDULES. `activeDeadlineSeconds` terminates only the trigger
# pod, never the detached orchestrator, so a long backup outlives its Job; the next schedule
# arrives with a different --run-id, sees no `.started` of its own, and starts a SECOND
# orchestrator, which then dies on the first component Lease it tries to take. The per-component
# Leases are what actually protect the data; this marker is what keeps the schedule from
# generating a failed Job every time a backup runs long.
INFLIGHT="${LOGDIR}/inflight.pid"

# Hidden re-entry: the detached child calls back here to run the orchestrator and capture its
# exit code next to the log. Kept as a self re-exec so setsid/nohup run a real file, not a
# shell function, and so there is zero nested-quoting in the CronJob manifest.
if [ "${1:-}" = "__run" ]; then
    _rid="${2:-}"
    [ -n "${_rid}" ] || { echo "[cron-backup] __run requires a run id" >&2; exit 2; }
    shift 2
    _log="${LOGDIR}/cron-${_rid}.log"
    _status="${LOGDIR}/cron-${_rid}.status"
    : > "${_log}"   # fresh log for this (re)start
    # Heartbeat: advance the log mtime every 60s so the parent's stall watchdog (which reads log
    # mtime) never mistakes a legitimately QUIET phase — a large ClickHouse/VM/​/srv upload can
    # print nothing for many minutes — for a dead writer and falsely restart the run (which would
    # truncate this live log and lock-collide). If the pod dies, this subshell dies with it and
    # mtime stops advancing, so a genuine crash is still detected. Stops when .status appears.
    ( while [ ! -f "${_status}" ]; do sleep 60; touch "${_log}" 2>/dev/null || true; done ) &
    _hb=$!
    # Claim the in-flight marker for the whole life of this orchestrator. `$$` is this detached
    # process, so its liveness IS the run's liveness — and because cron-backup.sh runs inside
    # the backup-tools pod, a later trigger execs into that same pod and can check it directly.
    printf '%s %s\n' "$$" "${_rid}" > "${INFLIGHT}" 2>/dev/null || true
    # Capture the exit code without letting `set -e` abort before we record it.
    pmm-backup.sh backup "$@" >>"${_log}" 2>&1 && _rc=0 || _rc=$?
    kill "${_hb}" 2>/dev/null || true
    # Publish atomically: write the fully-formed file, then rename into place, so a polling
    # reader never sees a 0-byte .status mid-write (which would read back as an empty, then
    # non-numeric, exit code).
    echo "${_rc}" > "${_status}.tmp" && mv -f "${_status}.tmp" "${_status}"
    # Released only after the status is published, so no window exists where the run looks
    # finished to one check and absent to the other.
    rm -f "${INFLIGHT}" 2>/dev/null || true
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

# Is an orchestrator from a DIFFERENT run still alive? Sets _ip/_ir for the caller's message.
# A stale marker (pod restarted, so the pid is gone) is cleaned up rather than trusted, which
# keeps a crashed run from wedging the schedule the way a stale `.started` once did.
inflight_other_run() {
    [ -f "${INFLIGHT}" ] || return 1
    _ip=""; _ir=""
    read -r _ip _ir < "${INFLIGHT}" 2>/dev/null || return 1
    case "${_ip}" in ''|*[!0-9]*) rm -f "${INFLIGHT}" 2>/dev/null || true; return 1 ;; esac
    if ! kill -0 "${_ip}" 2>/dev/null; then
        rm -f "${INFLIGHT}" 2>/dev/null || true
        return 1
    fi
    [ "${_ir}" != "${RUN_ID}" ]
}

# Skip rather than collide. Exiting 0 is deliberate: the schedule was not missed through a
# fault, it was superseded by a backup that is still running, and reporting that as a Job
# failure would page someone for a system behaving exactly as designed. The run that IS in
# flight reports its own result through its own trigger.
if [ ! -f "${STARTED}" ] && inflight_other_run; then
    echo "[cron-backup] a backup from an earlier schedule ('${_ir}', pid ${_ip}) is still running;"
    echo "[cron-backup] skipping this run rather than starting a second orchestrator that would"
    echo "[cron-backup] only fail on the component locks. Its own trigger reports its result."
    echo "[cron-backup] If backups routinely run past their interval, lengthen the schedule or"
    echo "[cron-backup] raise backup.schedule.activeDeadlineSeconds."
    exit 0
fi

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

echo "===== pmm-backup log (${RUN_ID}) ====="
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
