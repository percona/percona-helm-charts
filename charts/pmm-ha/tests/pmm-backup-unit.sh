#!/bin/sh
# Unit tests for the pure / stubbable functions in files/pmm-backup.sh.
#
# WHY THESE FUNCTIONS. The script's own comments record regressions that all lived in
# functions like these — a `${var:0:16}` that is fatal on dash, a `grep -c` whose exit status
# was taken for the pipeline's, a files-only listing that made a failed directory purge report
# "provably gone" so retention deleted the manifest anyway. Every one is a few lines of pure
# logic, and every one shipped because nothing could exercise it without a cluster and a
# populated bucket. These are the functions that decide what gets DELETED and what a restore
# believes about a backup, so they are the ones worth pinning.
#
# No bats, no fixtures, no cluster: source the orchestrator as a library (PMM_BACKUP_LIB=1),
# stub the storage layer, assert. Runs under bash, dash and BusyBox ash — the same three
# shells the orchestrator claims to support.
#
#   sh charts/pmm-ha/tests/pmm-backup-unit.sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TARGET="${SCRIPT_DIR}/../files/pmm-backup.sh"

[ -r "${TARGET}" ] || { echo "cannot read ${TARGET}"; exit 1; }
# A missing interpreter must FAIL, not skip. This suite is the CI gate for the `set -u` aborts
# and dash-only expansions that files/pmm-backup.sh records shipping twice, and an `exit 0` here
# made the workflow step green while running nothing at all — the same silent-skip pattern
# validate_restore_targets refuses ("a silent skip is worse than no gate"). Set
# PMM_BACKUP_TESTS_ALLOW_SKIP=1 to opt out deliberately on a machine that cannot install jq.
if ! command -v jq >/dev/null 2>&1; then
    if [ "${PMM_BACKUP_TESTS_ALLOW_SKIP:-0}" = "1" ]; then
        echo "SKIP: jq is not installed (PMM_BACKUP_TESTS_ALLOW_SKIP=1)"; exit 0
    fi
    echo "FAIL: jq is required to run these tests and is not on PATH." >&2
    echo "      Install it, or re-run with PMM_BACKUP_TESTS_ALLOW_SKIP=1 to skip deliberately." >&2
    exit 1
fi

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; }

# assert_eq <label> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then ok; else bad "$1" "$2" "$3"; fi
}
# assert_rc <label> <expected-rc> <actual-rc>
assert_rc() {
    if [ "$2" -eq "$3" ]; then ok; else bad "$1" "rc $2" "rc $3"; fi
}

section() { echo; echo "-- $1"; }

# ---------------------------------------------------------------------------------------
# Load the orchestrator's definitions WITHOUT running its dispatcher.
# ---------------------------------------------------------------------------------------
PMM_BACKUP_LIB=1
export PMM_BACKUP_LIB
# shellcheck disable=SC1090
. "${TARGET}"

# The orchestrator runs under `set -eu`, and sourcing it turns that on HERE too — which would
# make the first intentionally-failing assertion abort the whole suite instead of recording it.
set +e

# Quiet the logger: these tests assert return values, not output.
log() { :; }

#########################################################################################
section "backup_id_epoch — decides what retention classifies as expired"
#########################################################################################

# A well-formed id parses to the epoch of its embedded timestamp.
got=$(backup_id_epoch "backup_20260610-120000" 2>/dev/null || echo "")
case "${got}" in
    ''|*[!0-9]*) bad "valid id parses to a number" "digits" "${got}" ;;
    *) ok ;;
esac

# The documented promise is that an id whose timestamp cannot be parsed is SKIPPED, never
# deleted. BusyBox `date -D` ignores trailing garbage while GNU date rejects it, so without
# the explicit shape check the same bucket got opposite retention decisions per image — and on
# BusyBox a deliberately-named backup_<ts>-preupgrade would have been DELETED.
backup_id_epoch "backup_20260610-120000-preupgrade" >/dev/null 2>&1
assert_rc "suffixed id is refused, not parsed" 1 $?

backup_id_epoch "backup_notatimestamp" >/dev/null 2>&1
assert_rc "non-timestamp id is refused" 1 $?

backup_id_epoch "" >/dev/null 2>&1
assert_rc "empty id is refused" 1 $?

# A bare timestamp (no backup_ prefix) is what --backup-id accepts, so it must parse too.
got=$(backup_id_epoch "20260610-120000" 2>/dev/null || echo "")
case "${got}" in ''|*[!0-9]*) bad "bare timestamp parses" "digits" "${got}" ;; *) ok ;; esac

# Ordering must be monotonic, or "older than the cutoff" is meaningless.
older=$(backup_id_epoch "backup_20260610-120000" 2>/dev/null)
newer=$(backup_id_epoch "backup_20260611-120000" 2>/dev/null)
if [ "${newer}" -gt "${older}" ]; then ok; else bad "later id yields a later epoch" ">${older}" "${newer}"; fi

#########################################################################################
section "human_bytes"
#########################################################################################
assert_eq "0 bytes"      "0B"     "$(human_bytes 0)"
assert_eq "512 bytes"    "512B"   "$(human_bytes 512)"
assert_eq "1 KiB"        "1.0KB"  "$(human_bytes 1024)"
assert_eq "1 MiB"        "1.0MB"  "$(human_bytes 1048576)"

#########################################################################################
section "store_absent — a failed delete is only forgiven if the thing is PROVABLY gone"
#########################################################################################

# store_absent must use a listing that can contain DIRECTORIES. A files-only listing can never
# show a surviving <component>/<id>/, which made every failed purge report "provably gone" —
# so retention counted no failure and deleted the manifest, orphaning the component data.
store_list() { printf 'other-id\nbackup_20260610-120000/\n'; }
store_absent "/root/backup_20260610-120000" && rc=0 || rc=$?
assert_rc "surviving DIRECTORY is not absent (trailing slash stripped)" 1 "${rc}"

store_list() { printf 'other-id\n'; }
store_absent "/root/backup_20260610-120000" && rc=0 || rc=$?
assert_rc "genuinely missing entry is absent" 0 "${rc}"

# "Could not look" must never read as "not there".
store_list() { return 1; }
store_absent "/root/backup_20260610-120000" && rc=0 || rc=$?
assert_rc "unreadable listing is NOT absence" 1 "${rc}"

# A prefix match must not count: backup_2026 is not backup_20260610-120000.
store_list() { printf 'backup_2026\n'; }
store_absent "/root/backup_20260610-120000" && rc=0 || rc=$?
assert_rc "partial name match does not prove presence" 0 "${rc}"

#########################################################################################
section "src_subdir_for_ord — bucket-controlled names that reach a root pod's shell"
#########################################################################################

CURRENT_ID="backup_20260610-120000"
S3_ENABLED=false
BACKUP_DIR="/backups"

store_list_dirs() { printf 'vmstorage-src-vmcluster-0\nvmstorage-src-vmcluster-1\n'; }
assert_eq "matches by trailing ordinal" "vmstorage-src-vmcluster-1" "$(src_subdir_for_ord victoriametrics 1)"
assert_eq "no directory for that ordinal" "" "$(src_subdir_for_ord victoriametrics 7)"

# The injection this gate exists for: the value is interpolated into a command that runs as
# root against the pmm-storage PVC. A name carrying a quote must be refused, not used.
store_list_dirs() { printf "%s\n" "evil'; rm -rf /; echo -0"; }
assert_eq "single quote in name is refused" "" "$(src_subdir_for_ord pmm-server 0)"

store_list_dirs() { printf '%s\n' 'pmm-$(id)-0'; }
assert_eq "command substitution in name is refused" "" "$(src_subdir_for_ord pmm-server 0)"

# Read line-by-line, never `for x in $(...)`: word-splitting would turn this into the
# fragments "harmless" and "name-0", and "name-0" would pass a per-word charset check.
store_list_dirs() { printf '%s\n' 'harmless name-0'; }
assert_eq "name containing a space is refused whole" "" "$(src_subdir_for_ord pmm-server 0)"

# A safe name alongside an unsafe one still resolves.
store_list_dirs() { printf "%s\n%s\n" "bad'quote-0" "pmm-server-sts-0"; }
assert_eq "safe candidate still wins" "pmm-server-sts-0" "$(src_subdir_for_ord pmm-server 0)"

# Dots are legal in pod names.
store_list_dirs() { printf 'pmm.server.sts-0\n'; }
assert_eq "dots are allowed" "pmm.server.sts-0" "$(src_subdir_for_ord pmm-server 0)"

# A failed listing must not abort the caller: rc 0 with empty output, because vm_src_for_pod
# assigns from this under `set -e` and then tests for empty.
store_list_dirs() { return 1; }
out=$(src_subdir_for_ord pmm-server 0) && rc=0 || rc=$?
assert_rc "listing failure returns rc 0 (caller tests for empty)" 0 "${rc}"
assert_eq "listing failure yields no candidate" "" "${out}"

#########################################################################################
section "object_size_state — catches the truncated upload that 'size > 0' passes"
#########################################################################################

store_bytes() { echo 1000; }
object_size_state /x 1000 && rc=0 || rc=$?
assert_rc "size matches the manifest" 0 "${rc}"

object_size_state /x 2000 && rc=0 || rc=$?
assert_rc "size mismatch is a failure, not a pass" 1 "${rc}"
case "${OBJECT_SIZE_DETAIL}" in
    *"2000"*"1000"*) ok ;;
    *) bad "mismatch reports both sizes" "mentions 2000 and 1000" "${OBJECT_SIZE_DETAIL}" ;;
esac

# An older backup carries no recorded size; that is not a mismatch.
object_size_state /x "" && rc=0 || rc=$?
assert_rc "no expectation falls back to non-empty" 0 "${rc}"
assert_eq "no expectation reports no detail" "" "${OBJECT_SIZE_DETAIL}"

store_bytes() { echo 0; }
object_size_state /x 1000 && rc=0 || rc=$?
assert_rc "zero bytes is absent/empty" 1 "${rc}"

# "Could not look" is the third state, and must not be reported as a bad backup.
store_bytes() { return 1; }
object_size_state /x 1000 && rc=0 || rc=$?
assert_rc "unreadable object is 'could not check'" 2 "${rc}"

store_bytes() { echo "not-a-number"; }
object_size_state /x 1000 && rc=0 || rc=$?
assert_rc "non-numeric size is 'could not check', never a mismatch" 2 "${rc}"

#########################################################################################
section "ch_chain_required_names — an incremental's base must outlive it"
#########################################################################################

# Helper: define catalog_manifest from a name->json table held in variables.
mf() {  # <id> -> json on stdout
    case "$1" in
        A) echo '{"components":{"clickhouse":{"name":"A","base":""}}}' ;;
        B) echo '{"components":{"clickhouse":{"name":"B","base":"A"}}}' ;;
        C) echo '{"components":{"clickhouse":{"name":"C","base":"B"}}}' ;;
        N) echo '{"components":{"postgresql":{"status":"success"}}}' ;;
        *) return 1 ;;
    esac
}
catalog_manifest() { mf "$1"; }

# All fulls, nothing chained: expiring A takes nothing else with it.
catalog_manifest() { echo '{"components":{"clickhouse":{"name":"'"$1"'","base":""}}}'; }
out=$(ch_chain_required_names "A B" "A") && rc=0 || rc=$?
assert_rc "all-full catalog resolves" 0 "${rc}"
assert_eq "a full is required only by itself (B kept)" "B" "$(printf '%s' "${out}" | tr '\n' ' ' | sed 's/ *$//')"

catalog_manifest() { mf "$1"; }

# B is kept and was diffed against A, so A must survive even though it is expired.
out=$(ch_chain_required_names "A B" "A") && rc=0 || rc=$?
assert_rc "chained catalog resolves" 0 "${rc}"
case " $(printf '%s' "${out}" | tr '\n' ' ') " in
    *" A "*) ok ;;
    *) bad "base of a retained incremental is required" "contains A" "${out}" ;;
esac

# Transitive: C kept, B and A both expired — both must survive.
out=$(ch_chain_required_names "A B C" "A B") && rc=0 || rc=$?
req=" $(printf '%s' "${out}" | tr '\n' ' ') "
case "${req}" in *" A "*) ok ;; *) bad "transitive base A required" "contains A" "${out}" ;; esac
case "${req}" in *" B "*) ok ;; *) bad "direct base B required" "contains B" "${out}" ;; esac

# Everything expired: nothing is retained, so nothing is required and the sweep is free to
# proceed (the all-expired guard elsewhere is what stops a total wipe).
out=$(ch_chain_required_names "A B C" "A B C") && rc=0 || rc=$?
assert_rc "nothing retained still resolves" 0 "${rc}"
assert_eq "nothing retained requires nothing" "" "$(printf '%s' "${out}" | tr -d '[:space:]')"

# Backups without ClickHouse are simply not part of the graph.
out=$(ch_chain_required_names "N" "N") && rc=0 || rc=$?
assert_rc "catalog with no ClickHouse resolves" 0 "${rc}"
assert_eq "no ClickHouse means nothing required" "" "$(printf '%s' "${out}" | tr -d '[:space:]')"

# FAIL CLOSED, but only where it has to. An unreadable manifest belonging to a RETAINED backup
# hides which base that backup needs, so any expired ClickHouse backup might be it.
catalog_manifest() { case "$1" in B) return 1 ;; *) mf "$1" ;; esac; }
ch_chain_required_names "A B" "A" >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "unreadable manifest of a RETAINED backup fails closed" 1 "${rc}"

# ...and NOT where it does not. An unreadable manifest belonging to a backup that is about to be
# PURGED tells us nothing about anyone's chain, and the purge loop refuses that id on its own
# grounds (it will not delete a backup whose contents it cannot read). Failing the whole
# computation here disabled ClickHouse retention permanently: one stray object under manifests/
# or one transient read error deferred every ClickHouse-carrying id on every later run, while
# the sweep reported "0 purged" and success and the bucket grew without bound.
catalog_manifest() { case "$1" in A) return 1 ;; *) mf "$1" ;; esac; }
out=$(ch_chain_required_names "A B C" "A") && rc=0 || rc=$?
assert_rc "unreadable manifest of an EXPIRED backup does not disable the sweep" 0 "${rc}"
# B and C are retained, so their own names are still required.
req=" $(printf '%s' "${out}" | tr '\n' ' ') "
case "${req}" in *" B "*) ok ;; *) bad "retained B still required" "contains B" "${out}" ;; esac

# A non-JSON manifest is treated exactly like an unreadable one, per side of that same split.
catalog_manifest() { case "$1" in B) echo 'not json at all' ;; *) mf "$1" ;; esac; }
ch_chain_required_names "A B" "A" >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "non-JSON manifest of a RETAINED backup fails closed" 1 "${rc}"

# A required base that NO manifest in the catalog declares: that backup is already gone, so the
# chain is already incomplete and keeping expired backups cannot repair it. Treated as a chain
# end (with a warning) rather than freezing retention forever over damage already done.
catalog_manifest() { case "$1" in Z) echo '{"components":{"clickhouse":{"name":"Z","base":"GONE"}}}' ;; *) return 1 ;; esac; }
out=$(ch_chain_required_names "Z" "" 2>/dev/null) && rc=0 || rc=$?
assert_rc "a base that no longer exists is a chain end, not a permanent freeze" 0 "${rc}"
req=" $(printf '%s' "${out}" | tr '\n' ' ') "
case "${req}" in *" Z "*) ok ;; *) bad "the retained backup itself is still required" "contains Z" "${out}" ;; esac
case "${req}" in *" GONE "*) bad "a vanished base is not resurrected as a requirement" "no GONE" "${out}" ;; *) ok ;; esac

#########################################################################################
section "temp-pod env block — YAML indentation is CONTENT, not shell formatting"
#########################################################################################

# render_rclone_s3_env's output is spliced into the temp restore pods' `env:` list, so every
# entry must sit at exactly 8 spaces and every `value:`/`valueFrom:` at 10. Re-indenting those
# lines along with the surrounding shell (which is what wrapping the dispatcher in main() did)
# produces "error converting YAML to JSON: did not find expected key" from kubectl apply — and
# the only symptom the operator sees is "Failed to create restore pod", after PMM is at 0.
S3_PROVIDER="AWS"; S3_REGION="eu-north-1"; S3_ENDPOINT=""
# Build the keys block the way the SCRIPT does, not from a copy of the literal — testing a
# copy is what let the original indentation bug through this very suite.
S3_SECRET_NAME="sec"; S3_SECRET_ACCESS_KEY_KEY="access-key"; S3_SECRET_SECRET_KEY_KEY="secret-key"
TEMP_POD_S3_KEYS_ENV=$(render_temp_pod_s3_keys_env)

# mktemp, not a fixed /tmp path: a predictable name in a world-writable directory can be
# pre-created as a symlink by another local user, and this script redirects onto it.
_indent_check=$(mktemp) || _indent_check=""
if [ -z "${_indent_check}" ]; then
    # errexit is off in this suite, so a failed mktemp would leave the redirection below
    # writing to "", the grep would find nothing, and the check would report SUCCESS having
    # inspected no output at all. A gate that cannot run must fail, not skip.
    echo "FAIL: cannot create the indentation-check temporary file" >&2
    exit 1
fi
bad_indent=0
name_lines=0
render_rclone_s3_env | while IFS= read -r line; do
    [ -n "${line}" ] || continue
    case "${line}" in
        "        - name: "*) ;;                       # exactly 8 spaces
        "          value: "*|"          valueFrom: "*) ;;   # exactly 10
        *) echo "BADLINE:${line}" ;;
    esac
done > "${_indent_check}" 2>/dev/null
if grep -q '^BADLINE:' "${_indent_check}" 2>/dev/null; then
    bad="$(head -1 "${_indent_check}")"
    bad "every env line is at the manifest's expected column" "8/10 spaces" "${bad}"
else
    ok
fi
# ...and the entries are actually there (an empty block would trivially pass the check above).
n=$(render_rclone_s3_env | grep -c '^        - name: ')
if [ "${n}" -ge 6 ]; then ok; else bad "env block carries the rclone settings + keys" ">=6 entries" "${n}"; fi
rm -f "${_indent_check}"

# The SA line sits at pod-spec level: exactly two leading spaces.
S3_SERVICE_ACCOUNT="pmm-ha-backup-s3"; S3_SA_EXPLICIT=false
S3_SECRET_NAME=""            # IRSA path: no static keys, so the SA carries the credentials
assert_eq "SA line rendered at pod-spec column" "  serviceAccountName: pmm-ha-backup-s3" "$(render_temp_pod_sa_line)"

# Static keys with no explicit SA must emit NOTHING: the chart does not create that SA on this
# path, and naming a non-existent SA makes every temp pod fail admission after PMM is down.
S3_SECRET_NAME="sec"; S3_SA_EXPLICIT=false
assert_eq "static keys + implicit SA emits no SA line" "" "$(render_temp_pod_sa_line)"

# ...unless it was asked for explicitly (e.g. an SA carrying imagePullSecrets).
S3_SA_EXPLICIT=true
assert_eq "static keys + explicit SA is honoured" "  serviceAccountName: pmm-ha-backup-s3" "$(render_temp_pod_sa_line)"

S3_SERVICE_ACCOUNT=""
assert_eq "no SA configured emits nothing" "" "$(render_temp_pod_sa_line)"


#########################################################################################
section "component selection tables — same semantics both operations"
#########################################################################################

# The first explicit --<component> turns the others OFF; later ones combine. Five hand-written
# blocks per operation was how a component came to be handled in one arm and forgotten in the
# other, so the table is the thing worth pinning.
COMMAND=backup; EXPLICIT_SELECTION=false
BACKUP_POSTGRESQL=true; BACKUP_CLICKHOUSE=true; BACKUP_VICTORIAMETRICS=true; BACKUP_PMM_SERVER=true; BACKUP_ENCRYPTION_KEY=true
select_component clickhouse
assert_eq "backup --clickhouse turns PG off"  "false" "${BACKUP_POSTGRESQL}"
assert_eq "backup --clickhouse keeps CH on"   "true"  "${BACKUP_CLICKHOUSE}"
assert_eq "backup --clickhouse turns VM off"  "false" "${BACKUP_VICTORIAMETRICS}"
# The encryption key rides with PostgreSQL on the backup side, so it must NOT be cleared by a
# component selection — only --skip-encryption-key turns it off.
assert_eq "backup selection leaves the key alone" "true" "${BACKUP_ENCRYPTION_KEY}"
select_component postgresql
assert_eq "a second --<component> combines"   "true"  "${BACKUP_POSTGRESQL}"
assert_eq "...without re-enabling the others" "false" "${BACKUP_VICTORIAMETRICS}"

COMMAND=restore; EXPLICIT_SELECTION=false
RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=true; RESTORE_VICTORIAMETRICS=true; RESTORE_PMM_SERVER=true; RESTORE_ENCRYPTION_KEY=true
select_component postgresql
assert_eq "restore --postgresql selects PG"          "true"  "${RESTORE_POSTGRESQL}"
assert_eq "restore --postgresql clears CH"           "false" "${RESTORE_CLICKHOUSE}"
# On restore the key IS an independently selectable component, so it must be cleared here.
assert_eq "restore --postgresql clears the key"      "false" "${RESTORE_ENCRYPTION_KEY}"

COMMAND=restore; EXPLICIT_SELECTION=false
RESTORE_POSTGRESQL=true; RESTORE_CLICKHOUSE=true; RESTORE_VICTORIAMETRICS=true; RESTORE_PMM_SERVER=true; RESTORE_ENCRYPTION_KEY=false
select_component encryption-key
assert_eq "restore --encryption-key selects only it" "true"  "${RESTORE_ENCRYPTION_KEY}"
assert_eq "...and clears PG"                         "false" "${RESTORE_POSTGRESQL}"
assert_eq "...and clears PMM"                        "false" "${RESTORE_PMM_SERVER}"

# --skip on backup acts now; on restore it records a marker applied after the manifest defaults.
COMMAND=backup; BACKUP_VICTORIAMETRICS=true; skip_component victoriametrics
assert_eq "backup --skip-victoriametrics acts now"   "false" "${BACKUP_VICTORIAMETRICS}"
COMMAND=backup; BACKUP_ENCRYPTION_KEY=true; skip_component encryption-key
assert_eq "backup --skip-encryption-key acts now"    "false" "${BACKUP_ENCRYPTION_KEY}"
COMMAND=restore; SKIP_CLICKHOUSE=false; skip_component clickhouse
assert_eq "restore --skip-clickhouse sets a marker"  "true"  "${SKIP_CLICKHOUSE}"

#########################################################################################
section "pod_sh / vm_dst_for_pod — the preview must BE the command"
#########################################################################################

# In dry run pod_sh logs the script it would run and returns 0 without executing anything.
# The point is that the logged text and the executed text are one string, so they cannot drift.
DRY_RUN=true
captured=""
log() { captured="${captured}$*
"; }
pod_sh TestTag some-pod some-ctr 30 'tar -czf "$1" -C /x "$2"' /dest/a.tgz member && rc=0 || rc=$?
assert_rc "dry run returns 0 without executing" 0 "${rc}"
case "${captured}" in
    *'tar -czf "$1" -C /x "$2"'*) ok ;;
    *) bad "dry run logs the real script text" 'contains the script' "${captured}" ;;
esac
case "${captured}" in
    *"/dest/a.tgz member"*) ok ;;
    *) bad "dry run logs the argument values too" "contains the args" "${captured}" ;;
esac
case "${captured}" in
    *"-c some-ctr"*) ok ;;
    *) bad "dry run names the container" "-c some-ctr" "${captured}" ;;
esac
DRY_RUN=false
log() { :; }

# vmbackup takes a scheme, so this is one of the few places the two targets genuinely differ.
# Resolved in one place and used by both the preview and the real call.
CURRENT_ID="backup_20260610-120000"
S3_ENABLED=true; S3_BUCKET="bkt"; S3_PREFIX="ns/pmm-ha"; RCLONE_REMOTE="s3"
assert_eq "vm dst (s3)" "s3://bkt/ns/pmm-ha/victoriametrics/backup_20260610-120000/p-0/vm_backup_x" "$(vm_dst_for_pod p-0 vm_backup_x)"
S3_ENABLED=false; SHARED_MOUNT_PATH="/central"
assert_eq "vm dst (shared, as the POD sees it)" "fs:///central/victoriametrics/backup_20260610-120000/p-0/vm_backup_x" "$(vm_dst_for_pod p-0 vm_backup_x)"


#########################################################################################
section "result layer — one object feeds the manifest, the summary and the metrics"
#########################################################################################

RESULTS_JSON='{}'
result_set postgresql --arg status success --arg engine pg_dump --argjson bytes 1234 \
    '{status:$status, engine:$engine, bytes:$bytes}'
assert_eq "status round-trips"        "success" "$(result_get postgresql status)"
assert_eq "numeric field round-trips" "1234"    "$(result_get postgresql bytes)"
result_ok postgresql && rc=0 || rc=$?
assert_rc "result_ok is true on success" 0 "${rc}"

# A component that never ran has no entry, and must read as absent — not as failed. The summary
# distinguishes "Skipped" from "Failed" on exactly this.
assert_eq "absent component yields the default" ""     "$(result_get clickhouse status)"
assert_eq "explicit default is honoured"        "none" "$(result_get clickhouse status none)"
result_ok clickhouse && rc=0 || rc=$?
assert_rc "result_ok is false for an absent component" 1 "${rc}"

result_set clickhouse --arg status failed '{status:$status}'
result_ok clickhouse && rc=0 || rc=$?
assert_rc "result_ok is false on failure" 1 "${rc}"

# Only the components that ran appear — that is what write_manifest relies on instead of
# re-deriving which ones were selected.
assert_eq "results hold exactly what ran" "clickhouse postgresql" \
    "$(printf '%s' "${RESULTS_JSON}" | jq -r 'keys|join(" ")')"

# Values are escaped by jq, so a quote or a backslash in a location cannot corrupt the manifest.
result_set pmm-server --arg location 'a"b\c' '{status:"success", location:$location}'
assert_eq "special characters survive" 'a"b\c' "$(result_get pmm-server location)"
printf '%s' "${RESULTS_JSON}" | jq -e . >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "results remain valid JSON" 0 "${rc}"

# sizes_to_json turns the per-object census into a manifest object.
assert_eq "sizes to json"       '{"a":1,"b":2}' "$(sizes_to_json ' a:1 b:2' | jq -c .)"
assert_eq "empty census is {}"  '{}'            "$(sizes_to_json '' | jq -c .)"

# summary_row must distinguish never-ran from failed, or a skipped component reads as a failure.
RESULTS_JSON='{}'
captured=""; log() { captured="${captured}$*|"; }
summary_row victoriametrics "VM:"
case "${captured}" in *Skipped*) ok ;; *) bad "absent component reads as Skipped" "Skipped" "${captured}" ;; esac
captured=""; result_set victoriametrics --arg status failed '{status:$status}'
summary_row victoriametrics "VM:"
case "${captured}" in *Failed*) ok ;; *) bad "failed component reads as Failed" "Failed" "${captured}" ;; esac
captured=""; result_set victoriametrics --arg status success --argjson bytes 2048 --argjson pods 3 \
    --arg engine vmbackup --argjson duration 7 '{status:$status, bytes:$bytes, pods:$pods, engine:$engine, duration:$duration}'
summary_row victoriametrics "VM:"
case "${captured}" in *"2.0KB"*"7s"*"vmbackup"*"3 pods"*) ok ;;
  *) bad "success row renders size/duration/engine/pods" "2.0KB .. 7s .. vmbackup (3 pods)" "${captured}" ;; esac
log() { :; }
RESULTS_JSON='{}'


#########################################################################################
section "lease locks — expiry must never be guessed"
#########################################################################################

assert_eq "lease name" "pmm-backup-postgresql" "$(lease_name postgresql)"
assert_eq "lease name (hyphenated component)" "pmm-backup-pmm-server" "$(lease_name pmm-server)"

# renewTime is MicroTime; the parser must accept it and reject anything it cannot read.
got=$(epoch_from_rfc3339 "2026-08-23T14:05:12.123456Z" 2>/dev/null || echo "")
case "${got}" in ''|*[!0-9]*) bad "MicroTime parses" "digits" "${got}" ;; *) ok ;; esac
got2=$(epoch_from_rfc3339 "2026-08-23T14:05:13Z" 2>/dev/null || echo "")
if [ "${got2}" -gt "${got}" ] 2>/dev/null; then ok; else bad "later timestamp is greater" ">${got}" "${got2}"; fi
epoch_from_rfc3339 "not-a-time" >/dev/null 2>&1
assert_rc "garbage is refused" 1 $?
epoch_from_rfc3339 "" >/dev/null 2>&1
assert_rc "empty is refused" 1 $?

# A lease renewed just now is live; one renewed long ago is expired.
lease_expired "$(lease_now)" 900 && rc=0 || rc=$?
assert_rc "freshly renewed lease is live" 1 "${rc}"
lease_expired "2020-01-01T00:00:00.000000Z" 900 && rc=0 || rc=$?
assert_rc "long-stale lease is expired" 0 "${rc}"

# THE important one: "cannot tell" must be its own answer. Reading it as expired lets a run
# steal a live lock and write the same database as another run.
lease_expired "garbage" 900 && rc=0 || rc=$?
assert_rc "unparseable renewTime is 'cannot tell', not expired" 2 "${rc}"
lease_expired "" 900 && rc=0 || rc=$?
assert_rc "missing renewTime is 'cannot tell'" 2 "${rc}"
lease_expired "$(lease_now)" "" && rc=0 || rc=$?
assert_rc "missing duration is 'cannot tell'" 2 "${rc}"
lease_expired "$(lease_now)" "abc" && rc=0 || rc=$?
assert_rc "non-numeric duration is 'cannot tell'" 2 "${rc}"

# lease_now must be the format the API expects, or every patch is rejected at admission.
case "$(lease_now)" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]Z) ok ;;
    *) bad "lease_now is RFC3339 MicroTime" "YYYY-MM-DDThh:mm:ss.ffffffZ" "$(lease_now)" ;;
esac

#########################################################################################
section "layout — an empty id must never resolve to the component ROOT"
#########################################################################################

S3_ENABLED=false
BACKUP_DIR="/backups"
CURRENT_ID="backup_20260610-120000"
assert_eq "comp_path"     "/backups/postgresql/backup_20260610-120000" "$(comp_path postgresql)"
assert_eq "manifest_path" "/backups/manifests/backup_20260610-120000.json" "$(manifest_path)"
assert_eq "latest_path"   "/backups/latest" "$(latest_path)"

S3_ENABLED=true
S3_BUCKET="bkt"; S3_PREFIX="ns/pmm-ha"; RCLONE_REMOTE="s3"
assert_eq "comp_path (s3)"    "s3:bkt/ns/pmm-ha/postgresql/backup_20260610-120000" "$(comp_path postgresql)"
assert_eq "comp_display (s3)" "s3://bkt/ns/pmm-ha/postgresql/backup_20260610-120000" "$(comp_display postgresql)"
assert_eq "clickhouse_remote_key" "ns/pmm-ha/clickhouse" "$(clickhouse_remote_key)"

# An empty id would address every backup at once — a delete target of the whole component.
CURRENT_ID=""
comp_path postgresql >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "comp_path refuses an unset backup id" 1 "${rc}"

#########################################################################################
section "epoch_utc / backup_id_epoch — UTC in, UTC out, on every date(1) there is"
#########################################################################################

# Fixed points, checked against known epoch values. These decide what retention classifies as
# expired and whether a lock is judged live, so they are pinned rather than trusted.
assert_eq "the epoch itself"          "0"          "$(epoch_utc 1970 01 01 00 00 00)"
assert_eq "leading zeros are decimal" "951782400"  "$(epoch_utc 2000 02 29 00 00 00)"
assert_eq "end of a leap year"        "1735689599" "$(epoch_utc 2024 12 31 23 59 59)"
assert_eq "a backup id, as UTC"       "1781092800" "$(backup_id_epoch backup_20260610-120000)"
assert_eq "an RFC3339 MicroTime"      "1787493912" "$(epoch_from_rfc3339 2026-08-23T14:05:12.123456Z)"

# THE regression this replaced. `date -d` / `date -D` interpret their input in the LOCAL zone
# with no way to say "this is UTC", so a lease written a moment ago read back as one UTC offset
# older or newer than it is: east of UTC every live lease looked EXPIRED and a run took over a
# lock another run was holding (two writers, one database), west of UTC nothing ever expired and
# a genuinely stale lock could never be recovered. The conversion must not depend on TZ at all.
_e_utc=$(TZ=UTC              epoch_from_rfc3339 2026-08-23T14:05:12.000000Z)
_e_east=$(TZ=Europe/Bucharest epoch_from_rfc3339 2026-08-23T14:05:12.000000Z)
_e_west=$(TZ=America/Los_Angeles epoch_from_rfc3339 2026-08-23T14:05:12.000000Z)
assert_eq "east of UTC parses identically" "${_e_utc}" "${_e_east}"
assert_eq "west of UTC parses identically" "${_e_utc}" "${_e_west}"
_b_utc=$(TZ=UTC              backup_id_epoch backup_20260610-120000)
_b_west=$(TZ=America/Los_Angeles backup_id_epoch backup_20260610-120000)
assert_eq "backup ids age the same in every zone" "${_b_utc}" "${_b_west}"

# Out-of-range and malformed fields are refused rather than silently wrapping: a bogus epoch
# would be COMPARED against the retention cutoff.
for bad_in in "1969 01 01 00 00 00" "2026 13 01 00 00 00" "2026 00 01 00 00 00" \
              "2026 01 32 00 00 00" "2026 01 00 00 00 00" "2026 01 01 24 00 00" \
              "2026 01 01 00 60 00" "202x 01 01 00 00 00"; do
    # shellcheck disable=SC2086
    epoch_utc ${bad_in} >/dev/null 2>&1 && rc=0 || rc=$?
    assert_rc "epoch_utc refuses '${bad_in}'" 1 "${rc}"
done

# An explicit non-Z offset is NOT silently read as UTC — it is reported unparseable, which
# lease_expired turns into "cannot tell", which refuses to steal the lock. The safe direction.
epoch_from_rfc3339 "2026-08-23T14:05:12+03:00" >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "a non-Z offset is refused rather than assumed UTC" 1 "${rc}"

#########################################################################################
section "lease_name — a backup id may not be a legal Kubernetes object name"
#########################################################################################

# --backup-id accepts [A-Za-z0-9_-]; object names accept none of the uppercase or '_'. An
# illegal name made `kubectl create lease` fail with Invalid rather than AlreadyExists, so the
# manifest merge lock could never be held and every concurrent component run wrote the shared
# manifest unprotected — in exactly the workflow the merge exists to protect.
assert_eq "already-legal names are untouched" "pmm-backup-postgresql" "$(lease_name postgresql)"
assert_eq "hyphens are fine"                  "pmm-backup-pmm-server" "$(lease_name pmm-server)"
assert_eq "uppercase is folded"    "pmm-backup-manifest-pre-upgrade"  "$(lease_name manifest-Pre_Upgrade)"
assert_eq "a normal id is stable"  "pmm-backup-manifest-20260610-120000" "$(lease_name manifest-20260610-120000)"
assert_eq "no trailing separator"  "pmm-backup-manifest-abc"           "$(lease_name manifest-abc_)"
# Whatever comes in, what comes out has to be a DNS-1123 subdomain, or the create is rejected.
for id in "Pre_Upgrade" "UPPER" "a..b" "trailing---" "$(printf 'x%.0s' 1 2 3 4 5 6 7 8 9 0)0000000000000000000000000000000000000000000000000000000000000000"; do
    got=$(lease_name "manifest-${id}")
    case "${got}" in
        [a-z0-9]*[a-z0-9]) ;;
        *) bad "lease_name('${id}') starts and ends alphanumeric" "DNS-1123" "${got}"; continue ;;
    esac
    case "${got}" in
        *[!a-z0-9.-]*) bad "lease_name('${id}') has only legal characters" "[a-z0-9.-]" "${got}"; continue ;;
    esac
    if [ "${#got}" -gt 63 ]; then bad "lease_name('${id}') is not over-long" "<=63" "${#got}"; continue; fi
    ok
done

#########################################################################################
section "result_set / record_backup_result — a failure must never look like a skip"
#########################################################################################

RESULTS_JSON='{}'

# result_set must NEVER return non-zero. Every call site is a bare statement, so under `set -e`
# a non-zero status aborts the run — after every component has uploaded and before the manifest
# is written, orphaning the data in the bucket with no restore index. That is the exact failure
# the in-memory results exist to prevent, and one non-JSON --argjson value used to cause it.
result_set postgresql --argjson bytes "" '{status: "success", bytes: $bytes}' && rc=0 || rc=$?
assert_rc "a jq failure does not abort the caller" 0 "${rc}"
# ...and the component is recorded as FAILED rather than dropped: an absent entry is
# indistinguishable from "was never selected" everywhere downstream.
assert_eq "an undescribable component is recorded as failed" "failed" "$(result_get postgresql status)"

# A component that fails EARLY returns before its own result_set, so it had no entry at all —
# it then printed "Skipped" in the summary, never reached the manifest, and (worst) never had
# its .prom rewritten, so the PREVIOUS run's last_success=1 kept being scraped and a total
# failure looked green in Prometheus. record_backup_result is the one place every component's
# outcome passes through, so the entry is created there.
RESULTS_JSON='{}'
components_backed_up=0; components_failed=0; all_success=true
record_backup_result "ClickHouse" clickhouse 1 >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "a failed component reports failure" 1 "${rc}"
assert_eq "a component that never called result_set is still recorded" "failed" "$(result_get clickhouse status)"
assert_eq "and it is in the results, so the manifest and metrics see it" "clickhouse" \
    "$(printf '%s' "${RESULTS_JSON}" | jq -r 'keys | join(" ")')"
# The summary must agree with the log line record_backup_result already prints. It used to say
# "Skipped" for a component that had just been logged as failed.
captured=""; log() { captured="${captured}$*|"; }
summary_row clickhouse "ClickHouse:"
log() { :; }
case "${captured}" in
    *Skipped*) bad "a failed component does not render as Skipped" "Failed" "${captured}" ;;
    *Failed*)  ok ;;
    *)         bad "a failed component renders as Failed" "Failed" "${captured}" ;;
esac
# A component that succeeded must not be overwritten by this path.
RESULTS_JSON='{}'
result_set victoriametrics --arg status success '{status: $status}'
components_backed_up=0; components_failed=0; all_success=true
record_backup_result "VictoriaMetrics" victoriametrics 0 >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "a successful component still reports success" 0 "${rc}"
assert_eq "and keeps its own result" "success" "$(result_get victoriametrics status)"

#########################################################################################
section "write_manifest — a failed encryption key export must be visible in the index"
#########################################################################################

# backup_encryption_key calls result_set only on SUCCESS, so a FAILED or not-configured export
# left no components.encryption entry at all — and without one, a backup whose key export failed
# was byte-for-byte indistinguishable in the restore index from a backup taken on an install
# with no encryption configured. The restore's explicit-selection gate then said
# `encryption(absent)` instead of `encryption(failed)`, losing the one signal that this run's
# PostgreSQL dumps cannot be decrypted after a DR. write_manifest is handed that status; it has
# to record it.
_wm_out=$(mktemp)
S3_ENABLED=false
DRY_RUN=false
NAMESPACE="test-ns"
CURRENT_ID="backup_20260610-120000"
kubectl() { return 1; }                   # no cluster: the merge lease is simply not taken
store_read() { return 1; }                # nothing there yet
store_absent() { return 0; }              # ...and that absence is positively established
store_write() { cat > "${_wm_out}"; }

for st in failed not_found success skipped; do
    RESULTS_JSON='{"postgresql":{"status":"success"}}'
    write_manifest complete "${st}" >/dev/null 2>&1
    got=$(jq -r '.components.encryption.status // "ABSENT"' "${_wm_out}")
    case "${st}" in
        skipped) assert_eq "encryption '${st}' records nothing" "ABSENT" "${got}" ;;
        *)       assert_eq "encryption '${st}' reaches the manifest" "${st}" "${got}" ;;
    esac
done

# A component's own richer entry wins: the injection only fills a gap, it never overwrites what
# backup_encryption_key recorded (location, sha256, ...).
RESULTS_JSON='{"encryption":{"status":"success","sha256":"abc"}}'
write_manifest complete failed >/dev/null 2>&1
assert_eq "an existing encryption entry is not overwritten" "abc" \
    "$(jq -r '.components.encryption.sha256 // "MISSING"' "${_wm_out}")"
rm -f "${_wm_out}"

#########################################################################################
section "restore_encryption_key — the store must not be able to choose what gets applied"
#########################################################################################

# This is the ONE place store content reaches the apiserver as a MANIFEST rather than as data.
# The first version of the gate used a bare `jq -e '<predicate>'`, which takes its exit status
# from the LAST value in a JSON STREAM — so an attacker object placed FIRST passed, and the
# namespace rewrite then emitted both documents for `kubectl apply` to create. That is why the
# check is slurped (`-s` + `length == 1`), and why the ordering cases below exist.
# comp_path is deliberately NOT stubbed: a stub here leaked into a later section and made it
# assert against the stub instead of the real function. BACKUP_DIR points at a temp tree and the
# payload is written to the path comp_path actually computes, so the real path builder is
# exercised too. mf_field is restored at the end of the section for the same reason.
_ek_dir=$(mktemp -d)
_ek_applied="${_ek_dir}/applied"
LOG_FILE=/dev/null; DRY_RUN=false; NAMESPACE="target-ns"; S3_ENABLED=false
BACKUP_DIR="${_ek_dir}"; CURRENT_ID=backup_20260610-120000; BACKUP_NAME=backup_20260610-120000
_ek_payload="$(comp_path encryption)/pg-encryption-key.yaml"
mkdir -p "$(dirname "${_ek_payload}")"
_ek_saved_mf_field=$(command -v mf_field >/dev/null 2>&1 && echo yes || echo no)
mf_field() { echo ""; }                       # no sha256 recorded: the checksum block is skipped
store_read() { cat "$1" 2>/dev/null; }
kubectl() { if [ "$1" = apply ]; then cp "$3" "${_ek_applied}"; fi; return 0; }

_ek_probe() {   # <label> <expect-applied yes|no>
    : > "${_ek_applied}"
    restore_encryption_key >/dev/null 2>&1
    _ek_got=$( [ -s "${_ek_applied}" ] && echo yes || echo no )
    assert_eq "$1" "$2" "${_ek_got}"
}

_SECRET='{"apiVersion":"v1","kind":"Secret","metadata":{"name":"pg-encryption-key","namespace":"source-ns"},"data":{"k":"dg=="}}'
_POD='{"apiVersion":"v1","kind":"Pod","metadata":{"name":"pwn"},"spec":{"hostPID":true}}'

printf '%s\n' "${_SECRET}" > "${_ek_payload}"
_ek_probe "the real key Secret is applied" "yes"
assert_eq "and its namespace is rewritten to the target" "target-ns" \
    "$(jq -r '.metadata.namespace' "${_ek_applied}" 2>/dev/null)"
assert_eq "and exactly one object is applied" "1" \
    "$(jq -s 'length' "${_ek_applied}" 2>/dev/null)"

printf '%s\n%s\n' "${_SECRET}" "${_POD}" > "${_ek_payload}"
_ek_probe "an object appended AFTER the Secret is refused" "no"

# THE regression: with the attacker object first, the last value in the stream is the real
# Secret, so an unslurped `jq -e` returns 0 and the payload sails through.
printf '%s\n%s\n' "${_POD}" "${_SECRET}" > "${_ek_payload}"
_ek_probe "an object placed BEFORE the Secret is refused" "no"

printf '%s\n' "${_POD}" > "${_ek_payload}"
_ek_probe "a Pod alone is refused" "no"
printf '%s\n' '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"pmm-secret"},"data":{}}' > "${_ek_payload}"
_ek_probe "a Secret with another name is refused" "no"
printf '%s\n' 'not json at all' > "${_ek_payload}"
_ek_probe "unparseable content is refused" "no"
rm -rf "${_ek_dir}"
# Put the manifest accessor back so later sections see the real one.
mf_field() { jq -r --arg c "$1" --arg k "$2" '.components[$c][$k] // empty' "${MANIFEST_FILE}" 2>/dev/null; }

#########################################################################################
section "wait_for_pods_replaced — StatefulSet pods keep their names"
#########################################################################################

# vmselect is a StatefulSet, so the replacement pod is recreated with the SAME name. Identifying
# the old set by NAME therefore never saw it drain: the wait burned its full timeout and
# returned failure on every VM restore. Identity has to be the pod UID.
_wpr_state="${TMPDIR:-/tmp}/.wpr_uid_state.$$"
echo old > "${_wpr_state}"
kubectl() {
    case "$*" in
        *metadata.uid*)  if [ "$(cat "${_wpr_state}")" = old ]; then echo "uid-OLD"; else echo "uid-NEW"; fi ;;
        *metadata.name*) echo "vmselect-pmm-ha-vmcluster-0" ;;   # SAME name before and after
        *Ready*)         echo "True" ;;
    esac
    [ "$(cat "${_wpr_state}")" = old ] && echo new > "${_wpr_state}"
    return 0
}
VERBOSE=false
wait_for_pods_replaced ns app=vmselect "uid-OLD" 1 30 >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "a pod recreated under the same name IS seen as replaced" 0 "${rc}"

# ...and a pod that genuinely has not been replaced must NOT satisfy the wait.
echo old > "${_wpr_state}"
kubectl() {
    case "$*" in
        *metadata.uid*) echo "uid-OLD" ;;    # never changes: nothing was replaced
        *Ready*)        echo "True" ;;
    esac
    return 0
}
wait_for_pods_replaced ns app=vmselect "uid-OLD" 1 10 >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "an unreplaced pod does not satisfy the wait" 1 "${rc}"
rm -f "${_wpr_state}"

#########################################################################################
section "numeric knobs — a non-numeric value must not disable the check it guards"
#########################################################################################

# `[ 0 -lt 5m ]` EXITS 2, which an `if` reads as false — so CH_CREATE_TIMEOUT=5m made
# backup_clickhouse skip its wait loop AND skip the timeout arm, and report success for a
# ClickHouse backup it never confirmed had been created.
for _bad in "5m" "abc" "" "0" "-1" "1.5"; do
    _got=$(CH_CREATE_TIMEOUT="${_bad}" PMM_BACKUP_LIB=1 sh -c \
        '. "$1" >/dev/null 2>&1; printf "%s" "${CH_CREATE_TIMEOUT}"' _ "${TARGET}" 2>/dev/null)
    assert_eq "CH_CREATE_TIMEOUT='${_bad}' falls back to the default" "300" "${_got}"
done
_got=$(CH_CREATE_TIMEOUT=45 PMM_BACKUP_LIB=1 sh -c \
    '. "$1" >/dev/null 2>&1; printf "%s" "${CH_CREATE_TIMEOUT}"' _ "${TARGET}" 2>/dev/null)
assert_eq "a valid value is left alone" "45" "${_got}"
# What was clamped has to reach the operator: it is applied before log() exists, so it is
# recorded and reported by preflight_checks instead of being swallowed.
_got=$(KUBECTL_STATUS_TIMEOUT=abc PMM_BACKUP_LIB=1 sh -c \
    '. "$1" >/dev/null 2>&1; printf "%s" "${NUMERIC_ENV_CLAMPED}"' _ "${TARGET}" 2>/dev/null)
case "${_got}" in
    *KUBECTL_STATUS_TIMEOUT*) ok ;;
    *) bad "the clamp is recorded for preflight to report" "KUBECTL_STATUS_TIMEOUT..." "${_got}" ;;
esac

#########################################################################################
section "path views — the WRITE-facing ones must refuse an unset id too"
#########################################################################################

# comp_inpod is what backup_clickhouse tars into and what vm_dst_for_pod turns into vmbackup's
# fs:// destination; comp_display is the s3:// -dst vmbackup writes to. With an unset id they
# used to resolve to the component ROOT, so a call before the dispatcher sets CURRENT_ID would
# write on top of every backup of that component instead of failing.
S3_ENABLED=false
BACKUP_DIR="/backups"
SHARED_MOUNT_PATH="/central"
CURRENT_ID=""
for _fn in comp_path comp_display comp_inpod; do
    "${_fn}" postgresql >/dev/null 2>&1 && rc=0 || rc=$?
    assert_rc "${_fn} refuses an unset backup id" 1 "${rc}"
done
CURRENT_ID="backup_20260610-120000"
assert_eq "comp_display with an id" "/backups/postgresql/backup_20260610-120000" "$(comp_display postgresql)"
assert_eq "comp_inpod with an id"   "/central/postgresql/backup_20260610-120000"  "$(comp_inpod postgresql)"

#########################################################################################
section "write_manifest — an unmerged write must not be able to erase a sibling"
#########################################################################################

# Without the merge Lease the read-merge-write is a read-modify-write race: two component runs
# of one backup id both read the manifest as it was, each add their own entry, and the second
# write drops the first one's component from the restore index while its payload sits uploaded.
# That race needs a SIBLING, which only exists in the documented concurrent workflow (one
# process per component, sharing an explicit --backup-id) — so the refusal is scoped to it. A
# run with an auto-generated id owns an id nobody else is writing, and must still be able to
# write its index when the lease is unavailable, or an unreachable apiserver would turn every
# ordinary backup into an orphan.
# store_write is invoked through a PIPE, so anything it assigns happens in a subshell and never
# comes back — the fact of the write has to be observed on disk, not in a variable.
_wm_out2=$(mktemp)
S3_ENABLED=false
DRY_RUN=false
NAMESPACE="test-ns"
CURRENT_ID="backup_20260610-120000"
TIMESTAMP="20260610-120000"
RESULTS_JSON='{"clickhouse":{"status":"success"}}'
kubectl() { return 1; }          # no cluster: the merge lease can never be taken
store_read() { return 1; }
store_absent() { return 0; }
store_write() { cat > "${_wm_out2}"; }

# Concurrent workflow: an explicit --backup-id means siblings may be writing the same manifest.
BACKUP_ID="20260610-120000"
: > "${_wm_out2}"
write_manifest complete skipped >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "no lease + shared --backup-id refuses to write" 1 "${rc}"
assert_eq "and nothing was written"                       "0" "$(wc -c < "${_wm_out2}" | tr -d ' ')"

# Solo run: the id is this process's own timestamp, so there is no sibling to erase.
BACKUP_ID=""
: > "${_wm_out2}"
write_manifest complete skipped >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "no lease + auto id still writes" 0 "${rc}"
if [ -s "${_wm_out2}" ]; then ok; else bad "and it did write" "a manifest" "(empty)"; fi
assert_eq "with this run's component"          "clickhouse" \
    "$(jq -r '.components | keys | join(" ")' "${_wm_out2}" 2>/dev/null)"
rm -f "${_wm_out2}"
BACKUP_ID=""

#########################################################################################
section "start_lock_renewer — it must not outlive the orchestrator"
#########################################################################################

# cron-backup.sh detaches the orchestrator with setsid inside the long-lived backup-tools pod,
# so an abnormal end (SIGKILL, the OOM killer) never runs the EXIT trap and never calls
# stop_lock_renewer. A renewer left behind kept patching renewTime for the life of the POD: the
# leases never expired, every later backup and restore aborted on "another backup/restore holds
# the lock", and the schedule stayed wedged until someone deleted the Leases by hand.
_rn_dir=$(mktemp -d)
cat > "${_rn_dir}/run.sh" <<'RNEOF'
PMM_BACKUP_LIB=1
export PMM_BACKUP_LIB
# shellcheck disable=SC1090
. "$1"
set +e
log() { :; }
MARK="$2"
LOCK_COMPONENTS="postgresql"
LOCK_RENEW_SECONDS=1
NAMESPACE="test-ns"
kubectl() { echo tick >> "${MARK}"; }
start_lock_renewer
echo "${LOCK_RENEWER_PID}" > "${MARK}.pid"
# Stand in for a run that is still working, then die WITHOUT releasing anything.
sleep 2
RNEOF
sh "${_rn_dir}/run.sh" "${TARGET}" "${_rn_dir}/marks" >/dev/null 2>&1
# While the parent lived, the lease was being kept fresh.
if [ -s "${_rn_dir}/marks" ]; then ok; else bad "a held lease is renewed while the run works" "at least one renewal" "none"; fi
# The parent is gone now. The renewer has to notice and stop on its own.
#
# Assert the pid was actually captured FIRST. Without this the whole check is vacuous: an empty
# _rn_pid makes `kill -0 ""` fail immediately, which reads as "stopped" and passes the assertion
# below no matter what start_lock_renewer did — so a renewer that never started, or a child that
# died before writing marks.pid, would look like a working fix.
_rn_pid=$(cat "${_rn_dir}/marks.pid" 2>/dev/null || echo "")
case "${_rn_pid}" in
    ''|*[!0-9]*) bad "the renewer's pid was captured" "a pid" "[${_rn_pid}]" ;;
    *) ok ;;
esac
_rn_state="still-running"
_rn_waited=0
while [ "${_rn_waited}" -lt 8 ]; do
    kill -0 "${_rn_pid}" 2>/dev/null || { _rn_state="stopped"; break; }
    sleep 1; _rn_waited=$((_rn_waited + 1))
done
# Only meaningful if there was a pid to watch — guarded above, asserted here.
case "${_rn_pid}" in
    ''|*[!0-9]*) ;;   # already reported; do not also report a meaningless "stopped"
    *) assert_eq "the renewer stops once the orchestrator is gone" "stopped" "${_rn_state}" ;;
esac
[ "${_rn_state}" = "stopped" ] || kill "${_rn_pid}" 2>/dev/null || true
rm -rf "${_rn_dir}"

#########################################################################################
section "rclone helpers — nothing may be unbounded"
#########################################################################################

# Moving rclone in-process dropped the `timeout` wrappers the kubectl-exec calls had, and
# nothing replaced them: a wedged endpoint blocked for rclone's own 5m x 3 defaults instead of
# ${KUBECTL_STATUS_TIMEOUT}s, which hung `list`, hung the restore pre-flight that must not
# "stall a --dry-run for ten silent minutes", and made S3_PRUNE_MAX_SECONDS unenforceable
# because it is only checked BETWEEN ids. Asserted on the definitions, since calling them needs
# a bucket: every read/delete op carries a wall clock, and every op carries rclone's own
# idle/connect bounds.
_defs="$(sed -n '/^s3_rclone() {/,/^}/p;/^s3_rclone_rcat() {/,/^}/p;/^s3_rclone_purge() {/,/^}/p;/^s3_rclone_deletefile() {/,/^}/p' "${TARGET}")"
for fn in s3_rclone s3_rclone_purge s3_rclone_deletefile; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${TARGET}")
    case "${body}" in
        *_rclone_bounded*) ok ;;
        *) bad "${fn} has a wall clock" "_rclone_bounded" "${body}" ;;
    esac
done
# rcat streams multi-gigabyte pg_dumps, so it gets neither a wall clock nor the tight metadata
# idle bound. Both would kill a healthy backup of a large database: pg_dump can emit nothing for
# minutes while it waits on an ACCESS SHARE lock, and rcat cannot rewind stdin to retry.
body=$(sed -n '/^s3_rclone_rcat() {/,/^}/p' "${TARGET}")
case "${body}" in
    *_rclone_bounded*)  bad "rcat must not carry a wall clock" "_rclone_stream only" "${body}" ;;
    *_rclone_stream\ rcat*) ok ;;
    *) bad "rcat goes through the streaming helper" "_rclone_stream rcat" "${body}" ;;
esac
# ...and the streaming helper's idle bound must be the generous one, not the metadata one.
body=$(sed -n '/^_rclone_stream() {/,/^}/p' "${TARGET}")
case "${body}" in
    *RCLONE_STREAM_IO_TIMEOUT*) ok ;;
    *) bad "the streaming helper uses the stream idle bound" "RCLONE_STREAM_IO_TIMEOUT" "${body}" ;;
esac
if [ "${RCLONE_STREAM_IO_TIMEOUT}" -ge "${RCLONE_IO_TIMEOUT}" ]; then ok; else
    bad "the stream idle bound is not tighter than the metadata one" \
        ">= ${RCLONE_IO_TIMEOUT}" "${RCLONE_STREAM_IO_TIMEOUT}"
fi
# No helper may reach for the bare binary and bypass both bounds.
case "${_defs}" in
    *"    rclone "*) bad "no helper calls bare rclone" "via _rclone/_rclone_bounded" "${_defs}" ;;
    *) ok ;;
esac

#########################################################################################
section "pmm_replica_count — ONE resolver, and it always returns a number"
#########################################################################################

# There were three copies of this ladder and only the pre-flight gate checked the answer was
# numeric. A hand-edited `original-replicas=three` therefore reached `kubectl scale
# --replicas=three` (rejected, restore aborts with PMM already annotated) and
# `while [ "${i}" -lt "three" ]` (exits 2, so the /srv loop body never runs and the component
# reports "No /srv archives found in backup" for a backup that has them).
NAMESPACE="test-ns"
_prc_stub() { _PRC_SPEC="$1"; _PRC_ANN="$2"; }
kubectl() {
    case "$*" in
        *spec.replicas*)       printf '%s' "${_PRC_SPEC}" ;;
        *original-replicas*)   printf '%s' "${_PRC_ANN}" ;;
    esac
}
_prc_stub 3 "";      assert_eq "live spec wins"                       "3" "$(pmm_replica_count sts)"
_prc_stub 0 5;       assert_eq "at 0, the stashed count is used"      "5" "$(pmm_replica_count sts)"
_prc_stub 0 three;   assert_eq "a non-numeric annotation is ignored"  "3" "$(pmm_replica_count sts)"
_prc_stub "" "";     assert_eq "nothing known falls back"             "3" "$(pmm_replica_count sts)"
_prc_stub abc "";    assert_eq "a non-numeric spec falls back"        "3" "$(pmm_replica_count sts)"
PMM_SERVER_REPLICAS=2; _prc_stub 0 ""
assert_eq "PMM_SERVER_REPLICAS overrides the fallback"                "2" "$(pmm_replica_count sts)"
PMM_SERVER_REPLICAS=x; _prc_stub 0 ""
assert_eq "even a non-numeric PMM_SERVER_REPLICAS yields a number"    "3" "$(pmm_replica_count sts)"
PMM_SERVER_REPLICAS=3

# The fallback WARNING must come from the resolver, not from a caller comparing the answer to
# PMM_SERVER_REPLICAS: an install that legitimately runs 3 replicas resolves to 3 from the live
# spec, and that comparison warned "spec.replicas is 0 and no stashed count" on every healthy
# restore — a false alarm in the one log an operator reads during a DR.
captured=""; log() { captured="${captured}$*|"; }
_prc_stub 3 ""; pmm_replica_count sts >/dev/null
assert_eq "a healthy 3-replica install warns about nothing" "" "${captured}"
captured=""; _prc_stub 0 ""; pmm_replica_count sts >/dev/null
case "${captured}" in
    *"neither spec.replicas nor a stashed count"*) ok ;;
    *) bad "a genuine fallback does warn" "a fallback warning" "${captured}" ;;
esac
log() { :; }

#########################################################################################
section "wait_for_pods_gone — the SUCCESS path must not return non-zero"
#########################################################################################

# `grep -c` exits 1 on a zero count, which is the success case here. Without `|| true` the
# assignment returns non-zero and, wherever errexit is not suppressed, the run dies silently
# the moment the pods are actually gone — no log line at all, with PMM already at 0.
kubectl() { return 0; }          # succeeds with empty output => no pods
captured=""; log() { captured="${captured}$*|"; }
wait_for_pods_gone test-ns app=x 30 && rc=0 || rc=$?
log() { :; }
assert_rc "an empty pod list is success" 0 "${rc}"
case "${captured}" in
    *"All pods gone"*) ok ;;
    *) bad "and it says so" "All pods gone" "${captured}" ;;
esac

#########################################################################################
section "catalog_manifest cache — one read per manifest, invalidated on write"
#########################################################################################

# A retention sweep used to fetch the same manifest three times per deletion candidate (the
# ownership proof, the ClickHouse chain pass, the component list), each a separate rclone
# process against S3, all inside the lock window and all charged to S3_PRUNE_MAX_SECONDS.
#
# Run in a FRESH shell rather than inline: an earlier section replaces catalog_manifest itself
# with a fixture stub, and that override is still in effect here — testing the cache against
# that stub would exercise nothing. The counter is a file for the same reason the cache needed
# one: catalog_manifest calls store_read inside a command substitution, so an increment to a
# variable happens in a subshell and never comes back.
cat > "${SCRIPT_DIR}/.cachetest.$$" <<'CACHEEOF'
PMM_BACKUP_LIB=1
export PMM_BACKUP_LIB
# shellcheck disable=SC1090
. "$1"
set +e
log() { :; }
T="$2"
store_read() { echo r >> "${T}"; echo '{"namespace":"test-ns"}'; }
manifest_path() { echo "/m/$1.json"; }
tally() { wc -l < "${T}" | tr -d ' '; }
catalog_cache_init
[ -n "${CATALOG_CACHE_DIR}" ] || { echo "NOCACHEDIR"; exit 1; }
: > "${T}"
catalog_manifest A >/dev/null; catalog_manifest A >/dev/null; catalog_manifest A >/dev/null
n_same=$(tally)
catalog_manifest B >/dev/null
n_other=$(tally)
catalog_cache_drop A
catalog_manifest A >/dev/null
n_afterdrop=$(tally)
# A FAILED read must not be cached as a result: "could not read" drives fail-closed decisions.
store_read() { echo r >> "${T}"; return 1; }
catalog_manifest C >/dev/null 2>&1; rc_fail=$?
: > "${T}"
catalog_manifest C >/dev/null 2>&1
n_retry=$(tally)
catalog_cache_clear
echo "${n_same} ${n_other} ${n_afterdrop} ${rc_fail} ${n_retry} [${CATALOG_CACHE_DIR}]"
CACHEEOF
_cm_tally=$(mktemp)
_cm_res=$(sh "${SCRIPT_DIR}/.cachetest.$$" "${TARGET}" "${_cm_tally}" 2>&1)
rm -f "${SCRIPT_DIR}/.cachetest.$$" "${_cm_tally}"
# shellcheck disable=SC2086
set -- ${_cm_res}
assert_eq "three reads of one id hit the store once" "1" "${1:-}"
assert_eq "a different id is its own entry"          "2" "${2:-}"
assert_eq "dropping an entry forces a re-read"       "3" "${3:-}"
if [ "${4:-0}" -ne 0 ]; then ok; else bad "a failed read is reported as failed" "rc != 0" "rc ${4:-}"; fi
assert_eq "and it is retried, not remembered"        "1" "${5:-}"
assert_eq "clearing forgets the dir"                 "[]" "${6:-}"

#########################################################################################
section "restore_cleanup — an aborted run must not delete another run's temp pods"
#########################################################################################

# The EXIT trap is installed BEFORE acquire_locks, so a second restore that aborts at the
# non-TTY gate or on acquire_component_lock's `exit 1` — the documented "my kubectl exec
# dropped, re-run it" hazard — used to run a label-wide `kubectl delete pod` and kill the
# in-flight run's vmrestore or /srv pod mid-write, truncating that ordinal.
_rc_swept=$(mktemp)
kubectl() { case "$*" in "delete pod"*) echo "$*" >> "${_rc_swept}" ;; esac; return 0; }
release_locks() { :; }
LOCK_COMPONENTS=""
# The parent picks the marker path before any fork, exactly as cmd_restore does.
TEMP_PODS_MARKER=$(mktemp); rm -f "${TEMP_PODS_MARKER}"

: > "${_rc_swept}"
restore_cleanup
assert_eq "a run that created no temp pod deletes none" "0" "$(wc -l < "${_rc_swept}" | tr -d ' ')"

# THE case the flag has to survive: in the default --parallel mode each component restore runs
# in `( ... ) &`, so a shell VARIABLE set by create_vm_restore_pod is set in a subshell and is
# invisible to the parent that runs restore_cleanup. The gate would then skip the sweep for
# exactly the pods it exists to clean up — VictoriaMetrics', which hold the RWO vmstorage-db
# PVCs — and a Ctrl-C would leave one attached, wedging vmstorage on Multi-Attach at scale-up.
( [ -n "${TEMP_PODS_MARKER}" ] && : > "${TEMP_PODS_MARKER}" || true ) &
wait $!
: > "${_rc_swept}"
restore_cleanup
_rc_deletes="$(tr '\n' ' ' < "${_rc_swept}")"
case "${_rc_deletes}" in
    *vm-restore-temp*) ok ;;
    *) bad "a temp pod created in a SUBSHELL is still swept" "vm-restore-temp" "${_rc_deletes}" ;;
esac
case "${_rc_deletes}" in
    *pmm-srv-restore-temp*) ok ;;
    *) bad "both temp pod kinds are swept" "pmm-srv-restore-temp" "${_rc_deletes}" ;;
esac
# The sweep consumed the marker, so a second cleanup (INT then EXIT) does not re-sweep.
: > "${_rc_swept}"
restore_cleanup
assert_eq "the marker is consumed, so a second cleanup is a no-op" "0" "$(wc -l < "${_rc_swept}" | tr -d ' ')"
rm -f "${_rc_swept}"

#########################################################################################
section "value-taking flags — a missing value names the flag, not a line number"
#########################################################################################

# `"$2"` on a flag with no value is an unset read under `set -u`: the operator got
# "pmm-backup.sh: line 546: $2: unbound variable" and rc 2. A truncated CronJob argument list
# produces exactly this.
for _flag in --namespace --backup-dir --backup-id --target --s3-bucket --s3-prefix --retention; do
    # PMM_BACKUP_LIB must be UNSET for the child: this suite exports it, and with it set the
    # script loads as a library and never reaches the dispatcher at all.
    _rv_out=$(PMM_BACKUP_LIB= sh "${TARGET}" backup "${_flag}" 2>&1) && _rv_rc=0 || _rv_rc=$?
    assert_rc "${_flag} with no value exits 1" 1 "${_rv_rc}"
    case "${_rv_out}" in
        *"${_flag} requires a value"*) ok ;;
        *) bad "${_flag} names itself in the error" "${_flag} requires a value" "${_rv_out}" ;;
    esac
done

#########################################################################################
section "the ClickHouse size query must be single-row"
#########################################################################################

# system.backup_list can hold more than one row for a name (a retry with the same --backup-id
# leaves the earlier attempt's remote row while `create` adds a local one). A two-line result
# made `--argjson bytes "123\n456"` invalid JSON, so result_set's fallback recorded a
# ClickHouse backup whose data is safely in the bucket as FAILED.
_sz_q=$(grep -c "FROM system.backup_list WHERE name=.\${backup_name}. ORDER BY location LIMIT 1" "${TARGET}")
assert_eq "both size queries are LIMIT 1" "2" "${_sz_q}"

#########################################################################################
section "manifest schema — an older reader must refuse a newer format, not guess"
#########################################################################################

# The manifest is read back by whatever version is running at DR time, routinely an OLDER one.
# "Absent means 1" is what keeps every manifest written before the field existed readable, and
# "unreadable means newer" is what keeps a reader from acting on a version it cannot confirm.
assert_eq "absent schema is v1"        "1" "$(echo '{"backup_id":"x"}' | manifest_schema_of)"
assert_eq "explicit v1"                "1" "$(echo '{"schema":1}' | manifest_schema_of)"
assert_eq "a newer schema is reported" "7" "$(echo '{"schema":7}' | manifest_schema_of)"

# Each of these must FAIL rather than default to 1: a version that cannot be read is a format
# that cannot be trusted, and every caller treats a failure as "newer" and fails closed.
for _bad in '{"schema":"next"}' '{"schema":null}' '{"schema":1.5}' 'not json at all'; do
    printf '%s' "${_bad}" | manifest_schema_of >/dev/null 2>&1 && rc=0 || rc=$?
    assert_rc "unreadable schema ${_bad} is rejected" 1 "${rc}"
done

# The writer must actually stamp it, or every backup this version takes reads as v1 forever.
_ms_written=$(grep -c 'schema: \$schema' "${TARGET}")
assert_eq "write_manifest stamps the schema" "1" "${_ms_written}"

#########################################################################################
section "pmm_storage_pvc_name — the StatefulSet owns the PVC name, not a hardcoded default"
#########################################################################################

# The restore mounts this PVC BY NAME, and a name that does not resolve leaves the temp pod
# Pending until the readiness wait gives up — with PMM already scaled to 0. Assuming the chart's
# `storage.name` DEFAULT meant any install that set that value restored /srv from a PVC that had
# never existed.
_sts_json='{"spec":{"volumeClaimTemplates":[{"metadata":{"name":"pmm-data"}}],
  "template":{"spec":{"containers":[
    {"volumeMounts":[{"name":"annotations","mountPath":"/var/run/pmm/annotations"},
                     {"name":"pmm-data","mountPath":"/srv"}]}]}}}}'
kubectl() { printf '%s' "${_sts_json}"; }
PMM_STORAGE_PVC_PREFIX=""; PMM_STORAGE_PVC_PREFIX_RESOLVED=""; PMM_SRV_PATH="/srv"
# Resolution happens in the PARENT via resolve_pmm_storage_pvc_prefix; the accessor is pure so
# it is safe inside `$( )`. That split exists because log() writes to STDOUT, so a warning
# emitted from the accessor was captured as part of the PVC name.
resolve_pmm_storage_pvc_prefix sts >/dev/null 2>&1
assert_eq "prefix comes from the volumeClaimTemplate" "pmm-data-" "$(pmm_storage_pvc_prefix sts)"
assert_eq "per-ordinal PVC name"            "pmm-data-sts-0" "$(pmm_storage_pvc_name sts 0)"
assert_eq "…and the ordinal is not fixed"   "pmm-data-sts-2" "$(pmm_storage_pvc_name sts 2)"

# Selected by MOUNT PATH, not by position: a spec whose /srv claim is not first must still
# resolve to the /srv one.
_sts_json='{"spec":{"volumeClaimTemplates":[{"metadata":{"name":"scratch"}},{"metadata":{"name":"srv-vol"}}],
  "template":{"spec":{"containers":[{"volumeMounts":[{"name":"srv-vol","mountPath":"/srv"}]}]}}}}'
PMM_STORAGE_PVC_PREFIX_RESOLVED=""
resolve_pmm_storage_pvc_prefix sts >/dev/null 2>&1
assert_eq "the /srv claim wins over the first claim" "srv-vol-" "$(pmm_storage_pvc_prefix sts)"

# A volumeMount at /srv that is NOT a claim template (a configMap, say) must not be mistaken
# for one; fall back to the claim template instead.
_sts_json='{"spec":{"volumeClaimTemplates":[{"metadata":{"name":"real-claim"}}],
  "template":{"spec":{"containers":[{"volumeMounts":[{"name":"just-a-volume","mountPath":"/srv"}]}]}}}}'
PMM_STORAGE_PVC_PREFIX_RESOLVED=""
resolve_pmm_storage_pvc_prefix sts >/dev/null 2>&1
assert_eq "a non-claim volume at /srv is not the prefix" "real-claim-" "$(pmm_storage_pvc_prefix sts)"

# The DEFAULT must stay empty. A non-empty default is a second copy of the chart's
# `storage.name` living in this file, and it short-circuits pmm_storage_pvc_prefix so the
# StatefulSet is never consulted — which is the whole regression (DN-39). The tests above set
# the variable explicitly, so only a check on the source itself can catch this coming back.
_pvc_default=$(grep -c '^PMM_STORAGE_PVC_PREFIX="${PMM_STORAGE_PVC_PREFIX:-}"$' "${TARGET}")
assert_eq "PMM_STORAGE_PVC_PREFIX ships no hardcoded default" "1" "${_pvc_default}"

# An explicit override wins without consulting the cluster at all.
kubectl() { echo "kubectl must not be called when the prefix is overridden"; }
PMM_STORAGE_PVC_PREFIX="override-"; PMM_STORAGE_PVC_PREFIX_RESOLVED=""
assert_eq "explicit override wins" "override-sts-0" "$(pmm_storage_pvc_name sts 0)"

# Unreadable StatefulSet: REFUSE, do not guess. Falling back to the historical 'pmm-storage-'
# is the very regression DN-39 is about — on an install that sets storage.name it produces a
# name that looks plausible, passes nothing, and leaves the temp pod Pending until the 300s
# wait expires, with PMM already scaled to 0. There is no safe guess here, only an explicit
# PMM_STORAGE_PVC_PREFIX override.
kubectl() { return 1; }
PMM_STORAGE_PVC_PREFIX=""; PMM_STORAGE_PVC_PREFIX_RESOLVED=""
resolve_pmm_storage_pvc_prefix sts >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "an unreadable StatefulSet refuses rather than guessing" 1 "${rc}"
assert_eq "and nothing is cached from a failed resolution" "" "${PMM_STORAGE_PVC_PREFIX_RESOLVED}"
# The accessor must then FAIL rather than return an empty prefix: an empty one silently builds
# a PVC named "sts-0", which reads as a missing PVC instead of a failed lookup.
pmm_storage_pvc_name sts 0 >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "and the accessor refuses to build a name" 1 "${rc}"

# The override still works with no cluster at all.
PMM_STORAGE_PVC_PREFIX="override-"
assert_eq "an explicit override needs no StatefulSet" "override-sts-0" "$(pmm_storage_pvc_name sts 0)"
PMM_STORAGE_PVC_PREFIX=""

#########################################################################################
section "ch_restore_* — a restore reads the coordinates the BACKUP recorded"
#########################################################################################

# DN-12 honours a sidecar that writes outside this run's root and records where. Recording it
# only as display text meant restore and the pre-flight gate both went on looking under THIS
# run's root, so the backup reported success, moved `latest`, and could not be restored.
S3_BUCKET="run-bucket"; S3_PREFIX="ns/pmm-ha"
MF_CH_S3_BUCKET=""; MF_CH_S3_PATH=""
assert_eq "no recorded bucket falls back to this run's" "run-bucket"       "$(ch_restore_bucket)"
assert_eq "no recorded path falls back to this run's"   "ns/pmm-ha/clickhouse" "$(ch_restore_path)"

MF_CH_S3_BUCKET="other-bucket"; MF_CH_S3_PATH="team/ch"
assert_eq "the recorded bucket wins" "other-bucket" "$(ch_restore_bucket)"
assert_eq "the recorded path wins"   "team/ch"      "$(ch_restore_path)"

# Both the restore and the gate must go through the resolver — DN-33 records what it cost when
# those two looked in different places.
_chr=$(grep -c 'S3_BUCKET=$(ch_restore_bucket)\|S3_BUCKET=\$(ch_restore_bucket)' "${TARGET}")
[ "${_chr}" -ge 2 ] && ok || bad "restore and pre-flight both use the resolver" ">=2 call sites" "${_chr}"
_chold=$(grep -c 'S3_PATH=$(clickhouse_remote_key)' "${TARGET}" || true)
assert_eq "no reader still hardcodes this run's ClickHouse root" "0" "${_chold}"

#########################################################################################
section "flag_requires — 'prune' takes the backup flag set, not the restore one"
#########################################################################################

# prune is the backup side's retention half on its own entry point, so --retention must reach
# it; a restore-only flag typo'd onto a prune run must still be an error rather than silently
# accepted.
( COMMAND=prune; flag_requires backup --retention ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "prune accepts a backup flag"            0 "${rc}"
( COMMAND=prune; flag_requires restore --parallel ) >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "prune rejects a restore-only flag"      1 "${rc}"
( COMMAND=backup; flag_requires restore --force )   >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "backup still rejects a restore-only flag" 1 "${rc}"
( COMMAND=list; flag_requires restore --parallel )  >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "list still accepts both sets"           0 "${rc}"

# --yes answers the prompt; it is not a way to switch a safety gate off (DN-44). The encryption
# gate must not consult it, or every automated restore silently loses that check.
_enc_force=$(awk '/^    if \[ "\$\{RESTORE_ENCRYPTION_KEY\}" = "true" \]/,/^    fi/' "${TARGET}" | grep -c 'ASSUME_YES' || true)
assert_eq "the encryption gate does not consult --yes" "0" "${_enc_force}"

#########################################################################################
echo
echo "========================================"
if [ "${FAIL}" -eq 0 ]; then
    echo "OK: ${PASS} assertion(s) passed"
    echo "========================================"
    exit 0
fi
echo "FAILED: ${FAIL} of $((PASS + FAIL)) assertion(s)"
echo "========================================"
exit 1
