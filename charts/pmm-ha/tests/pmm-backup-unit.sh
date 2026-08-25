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
section "prune bounds — a bound of ZERO must not silently disable the sweep"
#########################################################################################

# Both knobs are compared with -ge against a counter that starts at zero, so 0 breaks the purge
# loop before the first delete, leaves PRUNE_REFUSED at 0, and lets cmd_prune report success and
# publish pmm_ha_prune_last_success=1 — retention stops for good and nothing says so. "0 means
# unlimited" is the natural guess for a cap, which is exactly why it has to be refused.
for _bad in "0" "00" "abc" "" "5m" "-1"; do
    _got=$(S3_PRUNE_MAX_PER_RUN="${_bad}" PMM_BACKUP_LIB=1 sh -c \
        '. "$1" >/dev/null 2>&1; printf "%s" "${S3_PRUNE_MAX_PER_RUN}"' _ "${TARGET}" 2>/dev/null)
    assert_eq "S3_PRUNE_MAX_PER_RUN='${_bad}' falls back to the default" "50" "${_got}"
    _got=$(S3_PRUNE_MAX_SECONDS="${_bad}" PMM_BACKUP_LIB=1 sh -c \
        '. "$1" >/dev/null 2>&1; printf "%s" "${S3_PRUNE_MAX_SECONDS}"' _ "${TARGET}" 2>/dev/null)
    assert_eq "S3_PRUNE_MAX_SECONDS='${_bad}' falls back to the default" "900" "${_got}"
done
# A leading zero is decimal here, not octal, and must survive as itself.
_got=$(S3_PRUNE_MAX_PER_RUN=010 PMM_BACKUP_LIB=1 sh -c \
    '. "$1" >/dev/null 2>&1; printf "%s" "${S3_PRUNE_MAX_PER_RUN}"' _ "${TARGET}" 2>/dev/null)
assert_eq "S3_PRUNE_MAX_PER_RUN=010 normalises to 10, not 8" "10" "${_got}"
_got=$(S3_PRUNE_MAX_SECONDS=120 PMM_BACKUP_LIB=1 sh -c \
    '. "$1" >/dev/null 2>&1; printf "%s" "${S3_PRUNE_MAX_SECONDS}"' _ "${TARGET}" 2>/dev/null)
assert_eq "a valid sweep budget is left alone" "120" "${_got}"
# And the substitution has to reach the operator, like every other clamp.
_got=$(S3_PRUNE_MAX_PER_RUN=0 PMM_BACKUP_LIB=1 sh -c \
    '. "$1" >/dev/null 2>&1; printf "%s" "${NUMERIC_ENV_CLAMPED}"' _ "${TARGET}" 2>/dev/null)
case "${_got}" in
    *S3_PRUNE_MAX_PER_RUN*) ok ;;
    *) bad "a rejected prune bound is reported by preflight" "S3_PRUNE_MAX_PER_RUN..." "${_got}" ;;
esac
# The documented default of RCLONE_TIMEOUT is the status timeout, so the clamp has to fall back
# to THAT and not to a second hardcoded number living next to it.
_got=$(KUBECTL_STATUS_TIMEOUT=120 RCLONE_TIMEOUT=5m PMM_BACKUP_LIB=1 sh -c \
    '. "$1" >/dev/null 2>&1; printf "%s" "${RCLONE_TIMEOUT}"' _ "${TARGET}" 2>/dev/null)
assert_eq "RCLONE_TIMEOUT falls back to KUBECTL_STATUS_TIMEOUT, not 30" "120" "${_got}"

#########################################################################################
section "store_bytes — rc must say whether we could LOOK, not whether the parse worked"
#########################################################################################

# It used to END IN A PIPE, so the rc was the parser's. A successful read whose output the parser
# could not understand returned rc 0 with EMPTY output, and s3_object_state's `-gt 0` test then
# read that as "the object is absent" rather than "the check failed" — fail-open, in the gate
# that exists to fail closed.
# An earlier section stubs store_bytes itself (to drive s3_object_state), and that stub is still
# in scope here — restore the REAL definition before testing it, the same way the rclone-bounds
# section re-reads the definitions it asserts on.
eval "$(sed -n '/^store_bytes() {/,/^}/p' "${TARGET}")"
S3_ENABLED=true
s3_rclone() { printf '%s' '{"count":1,"bytes":4096}'; }
_got=$(store_bytes "s3:b/k") && rc=0 || rc=$?
assert_rc "a parseable size is rc 0" 0 "${rc}"
assert_eq "and prints the byte count" "4096" "${_got}"
# rclone size on a MISSING path exits 0 printing bytes:0 — a legitimate zero, not a failure.
s3_rclone() { printf '%s' '{"count":0,"bytes":0}'; }
_got=$(store_bytes "s3:b/gone") && rc=0 || rc=$?
assert_rc "a legitimate zero is still rc 0" 0 "${rc}"
assert_eq "and prints 0" "0" "${_got}"
# Output the parser cannot understand is NOT 'absent'.
s3_rclone() { printf '%s' 'HTTP 503 from a proxy'; }
_got=$(store_bytes "s3:b/k") && rc=0 || rc=$?
assert_rc "an unparseable read is rc non-zero" 1 "${rc}"
_st=0; s3_object_state "s3:b/k" || _st=$?
assert_rc "so s3_object_state says 'could not check', not 'absent'" 2 "${_st}"
_st=0; object_size_state "s3:b/k" 4096 || _st=$?
assert_rc "and object_size_state says the same" 2 "${_st}"
# A read that FAILS outright keeps propagating its own status, as before.
s3_rclone() { return 7; }
store_bytes "s3:b/k" >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "a failed read still propagates non-zero" 7 "${rc}"
unset -f s3_rclone 2>/dev/null || s3_rclone() { return 1; }

#########################################################################################
section "temp-pod images — resolved from the cluster, never from a stale hardcoded tag"
#########################################################################################

# Both fallbacks were pinned tags: "percona/pmm-server:3.7.0" (already two chart releases behind
# by the time anyone compared) and "victoriametrics/vmrestore:latest" (an unpinned tool reading
# vmstorage's on-disk format, pulled during a DR). A second copy of a chart value in this file is
# the drift DN-39 exists to stop, so there is no copy any more: resolve, or refuse.
# Comment lines are excluded on purpose: the two removed tags are NAMED in the comments that
# explain why they are gone, and that prose is the reason the next person does not put them back.
_pinned=$(grep -v '^[[:space:]]*#' "${TARGET}" \
    | grep -c 'percona/pmm-server:[0-9]\|vmrestore:latest' || true)
assert_eq "no hardcoded image tag remains in code" "0" "${_pinned}"

# get_vmrestore_image must never LOG: every call site is inside $( ), so a log line on stdout
# would be captured as the image name (the bug pmm_storage_pvc_prefix was split to avoid).
_vmlog=$(awk '/^get_vmrestore_image\(\) \{/,/^\}/' "${TARGET}" | grep -c 'log "' || true)
assert_eq "get_vmrestore_image never logs into its own stdout" "0" "${_vmlog}"

NAMESPACE="unit"
VMRESTORE_IMAGE=""
kubectl() { return 1; }                       # no vmrestore container readable
get_vmrestore_image pod-0 >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "get_vmrestore_image refuses rather than guessing a tag" 1 "${rc}"
VMRESTORE_IMAGE="victoriametrics/vmrestore:v1.149.0"
assert_eq "the explicit override is honoured" "${VMRESTORE_IMAGE}" "$(get_vmrestore_image pod-0)"
VMRESTORE_IMAGE=""

# The /srv restore image: resolver logs (it runs in the parent), accessor does not (it is used
# inside $( )), and the accessor fails loudly if nothing resolved rather than emitting "".
PMM_RESTORE_IMAGE=""
PMM_RESTORE_IMAGE_RESOLVED=""
pmm_restore_image >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "pmm_restore_image fails when nothing resolved it" 1 "${rc}"
S3_ENABLED=true
kubectl() { return 1; }
resolve_pmm_restore_image pmm-sts >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "resolve_pmm_restore_image refuses an unreadable StatefulSet" 1 "${rc}"
kubectl() { printf '%s' "percona/pmm-server:9.9.9"; }
resolve_pmm_restore_image pmm-sts >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "and succeeds when the StatefulSet answers" 0 "${rc}"
assert_eq "the accessor returns what was resolved" "percona/pmm-server:9.9.9" "$(pmm_restore_image)"
# The accessor — and the helper it delegates to — must never log: every call site is inside
# `$( )`, so a log line on stdout is captured AS the image name. Handles a one-line function
# body as well as a braces-on-their-own-lines one.
_fn_has_log() {   # <function-name>
    awk -v f="$1" '
        $0 ~ "^" f "\\(\\) \\{" { inside = 1; if ($0 ~ /\}[[:space:]]*$/) { print; inside = 0; next } }
        inside { print }
        inside && /^\}/ { inside = 0 }
    ' "${TARGET}" | grep -c 'log "' || true
}
assert_eq "the accessor never logs into its own stdout"  "0" "$(_fn_has_log pmm_restore_image)"
assert_eq "nor does the helper it delegates to"          "0" "$(_fn_has_log resolved_or_override)"
assert_eq "nor the PVC-prefix accessor"                  "0" "$(_fn_has_log pmm_storage_pvc_prefix)"
# An explicit override wins and needs no cluster read at all.
PMM_RESTORE_IMAGE="my/tools:1"
PMM_RESTORE_IMAGE_RESOLVED=""
kubectl() { echo "should not be called"; return 1; }
resolve_pmm_restore_image pmm-sts >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc "an explicit PMM_RESTORE_IMAGE short-circuits the read" 0 "${rc}"
assert_eq "and is what the accessor returns" "my/tools:1" "$(pmm_restore_image)"
PMM_RESTORE_IMAGE=""
unset -f kubectl 2>/dev/null || kubectl() { return 1; }

#########################################################################################
section "write_restore_metrics — a metrics write must never be able to kill a restore"
#########################################################################################

# It used to end in a bare `cat > "${tmp_file}" <<EOF`, and every call site is either a plain
# command or the last command of an && list — so under `set -e` a full or read-only METRICS_DIR
# aborted the restore, after scale_down_pmm, with the components half done. DN-32: metrics writers
# never fail the run.
# The directory must EXIST and be unwritable. A non-existent METRICS_DIR only exercises the
# mkdir fallback to /tmp and never reaches the write at all — which is how a test for this could
# pass while the bug it is aimed at was still there.
_ro=$(mktemp -d 2>/dev/null || echo "/tmp/.ro_$$"); mkdir -p "${_ro}"; chmod 500 "${_ro}" 2>/dev/null || true
# The probe runs in a SUBSHELL with stderr redirected: a failed redirection is reported by the
# shell itself, not by the command being redirected, so `: > f 2>/dev/null` still prints it.
if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && ! ( : >"${_ro}/.probe" ) 2>/dev/null; then
    _out=$(METRICS_DIR="${_ro}" PMM_BACKUP_LIB=1 sh -c '
        set -eu
        . "$1" >/dev/null 2>&1
        METRICS_DIR="$2"; NAMESPACE=unit
        write_restore_metrics 1 "components"
        printf "SURVIVED"' _ "${TARGET}" "${_ro}" 2>/dev/null)
    assert_eq "an unwritable METRICS_DIR does not abort the caller" "SURVIVED" "${_out}"
    # The other two writers already promised this; assert all three keep it.
    _out=$(METRICS_DIR="${_ro}" PMM_BACKUP_LIB=1 sh -c '
        set -eu
        . "$1" >/dev/null 2>&1
        METRICS_DIR="$2"; NAMESPACE=unit
        write_prune_metrics 1
        printf "SURVIVED"' _ "${TARGET}" "${_ro}" 2>/dev/null)
    assert_eq "write_prune_metrics likewise" "SURVIVED" "${_out}"
else
    echo "     (skipped the unwritable-dir assertions: running as root, mode bits do not apply)"
fi
chmod 700 "${_ro}" 2>/dev/null || true; rm -rf "${_ro}" 2>/dev/null || true

# The component label VALUES are the manifest's keys, so they match pmm_ha_backup_last_success.
# They were 'pmm_server' and 'encryption_key' here and 'pmm-server'/'encryption' on the backup
# side: one tool, one directory, one scrape, two spellings, nothing able to join them (DN-42).
_mdir=$(mktemp -d 2>/dev/null || echo "/tmp/.rm_$$"); mkdir -p "${_mdir}"
( METRICS_DIR="${_mdir}" NAMESPACE=unit PMM_BACKUP_LIB=1 sh -c '
    . "$1" >/dev/null 2>&1
    METRICS_DIR="$2"; NAMESPACE=unit
    POSTGRESQL_OK=true; CLICKHOUSE_OK=true; VICTORIAMETRICS_OK=true
    PMM_SERVER_OK=true; ENCRYPTION_KEY_OK=true
    write_restore_metrics 0 idle 1 100 5' _ "${TARGET}" "${_mdir}" ) >/dev/null 2>&1
_labels=$(grep -c 'component="pmm-server"\|component="encryption"' "${_mdir}/restore_metrics.prom" 2>/dev/null || true)
assert_eq "restore metrics use the manifest's component keys" "2" "${_labels}"
_old=$(grep -c 'component="pmm_server"\|component="encryption_key"' "${_mdir}/restore_metrics.prom" 2>/dev/null || true)
assert_eq "and no longer the old underscored spellings" "0" "${_old}"
rm -rf "${_mdir}" 2>/dev/null || true

# The chart's listener must actually SERVE every family this file writes. prune_metrics.prom was
# written here and cat'd by nothing, so the one signal that separates "nothing was expired" from
# "the sweep refused" reached no scrape at all — the same failure the listener's own comment
# records for pmm-server_metrics.prom.
_tools="${SCRIPT_DIR}/../templates/backup-tools.yaml"
if [ -r "${_tools}" ]; then
    for _fam in "backup/*.prom" "restore_metrics.prom" "prune_metrics.prom"; do
        if grep -Fq "${_fam}" "${_tools}"; then ok
        else bad "the listener serves ${_fam}" "a cat of ${_fam}" "not found in backup-tools.yaml"; fi
    done
fi

#########################################################################################
section "S3 settings reaching an interpreter are charset-gated"
#########################################################################################

# S3_BUCKET and S3_PREFIX are spliced UNQUOTED into a clickhouse-backup action string that is then
# embedded in a single-quoted SQL literal and re-used as that row's poll key; the endpoint/region/
# provider are rendered into the temp pods' YAML as double-quoted scalars. Operator-supplied is not
# the same as trusted once a values.yaml is templated by anything but a human.
_try() {   # <label> <expected-rc> <env-assignment...>
    _lbl="$1"; _want="$2"; shift 2
    env "$@" PMM_BACKUP_LIB= sh "${TARGET}" list >/dev/null 2>&1 && rc=0 || rc=$?
    if [ "${_want}" = "reject" ]; then
        [ "${rc}" -eq 1 ] && ok || bad "${_lbl} is refused" "rc 1" "rc ${rc}"
    else
        [ "${rc}" -ne 1 ] && ok || bad "${_lbl} is accepted" "not rc 1" "rc ${rc}"
    fi
}
_try "a normal bucket + prefix"      accept BACKUP_TARGET=s3 S3_BUCKET=pmm-backups S3_PREFIX=demo/pmm-ha NAMESPACE=demo
_try "an apostrophe in the bucket"   reject BACKUP_TARGET=s3 "S3_BUCKET=b' , '" S3_PREFIX=demo/pmm-ha NAMESPACE=demo
_try "a space in the prefix"         reject BACKUP_TARGET=s3 S3_BUCKET=b "S3_PREFIX=demo --env X=y" NAMESPACE=demo
_try "a quote in the endpoint"       reject BACKUP_TARGET=s3 S3_BUCKET=b 'S3_ENDPOINT=http://x" bad' NAMESPACE=demo
_try "a real endpoint URL"           accept BACKUP_TARGET=s3 S3_BUCKET=b 'S3_ENDPOINT=https://minio.example.com:9000' NAMESPACE=demo
_try "a quote in the namespace"      reject BACKUP_TARGET=s3 S3_BUCKET=b 'NAMESPACE=de"mo'
_try "a non-alphanumeric provider"   reject BACKUP_TARGET=s3 S3_BUCKET=b 'S3_PROVIDER=AWS"x' NAMESPACE=demo


#########################################################################################
section "CHARACTERIZATION: path views across both targets"
#########################################################################################
# Pinned before the six root/comp helpers are folded into parameterised ones. The exact
# strings matter: they are rclone remote specs, s3:// URIs and in-pod mount paths, and each is
# consumed by a different tool.
_pv_save_t="${BACKUP_TARGET}" _pv_save_e="${S3_ENABLED}" _pv_save_b="${S3_BUCKET}"
_pv_save_p="${S3_PREFIX}" _pv_save_d="${BACKUP_DIR}" _pv_save_m="${SHARED_MOUNT_PATH}"
_pv_save_r="${RCLONE_REMOTE}" _pv_save_id="${CURRENT_ID}"

BACKUP_TARGET=s3; S3_ENABLED=true; S3_BUCKET=bk; S3_PREFIX=demo/pmm-ha
BACKUP_DIR=/backups; SHARED_MOUNT_PATH=/central; RCLONE_REMOTE=s3; CURRENT_ID=backup_20260610-120000
assert_eq "s3 root"          "s3:bk/demo/pmm-ha"                    "$(backup_root)"
assert_eq "s3 root display"  "s3://bk/demo/pmm-ha"                  "$(backup_root_display)"
assert_eq "s3 root inpod"    "s3:bk/demo/pmm-ha"                    "$(backup_root_inpod)"
assert_eq "s3 comp path"     "s3:bk/demo/pmm-ha/postgresql/backup_20260610-120000"   "$(comp_path postgresql)"
assert_eq "s3 comp display"  "s3://bk/demo/pmm-ha/postgresql/backup_20260610-120000" "$(comp_display postgresql)"
assert_eq "s3 comp inpod"    "s3:bk/demo/pmm-ha/postgresql/backup_20260610-120000"   "$(comp_inpod postgresql)"
assert_eq "s3 comp location" "s3://bk/demo/pmm-ha/clickhouse/backup_20260610-120000" "$(comp_location clickhouse)"
assert_eq "s3 manifest"      "s3:bk/demo/pmm-ha/manifests/backup_20260610-120000.json"   "$(manifest_path)"
assert_eq "s3 manifest disp" "s3://bk/demo/pmm-ha/manifests/backup_20260610-120000.json" "$(manifest_display)"
assert_eq "s3 manifests dir" "s3:bk/demo/pmm-ha/manifests"          "$(manifests_dir)"
assert_eq "s3 latest"        "s3:bk/demo/pmm-ha/latest"             "$(latest_path)"
assert_eq "ch remote key"    "demo/pmm-ha/clickhouse"               "$(clickhouse_remote_key)"
assert_eq "explicit id wins" "s3:bk/demo/pmm-ha/pmm-server/backup_OTHER" "$(comp_path pmm-server backup_OTHER)"
assert_eq "staging is local" "/backups/.staging/backup_20260610-120000/encryption" "$(staging_dir encryption)"
assert_eq "vm dst s3"        "s3://bk/demo/pmm-ha/victoriametrics/backup_20260610-120000/p0/n" "$(vm_dst_for_pod p0 n)"

BACKUP_TARGET=shared; S3_ENABLED=false
assert_eq "shared root"          "/backups"                                   "$(backup_root)"
assert_eq "shared root display"  "/backups"                                   "$(backup_root_display)"
assert_eq "shared root inpod"    "/central"                                   "$(backup_root_inpod)"
assert_eq "shared comp path"     "/backups/postgresql/backup_20260610-120000" "$(comp_path postgresql)"
assert_eq "shared comp display"  "/backups/postgresql/backup_20260610-120000" "$(comp_display postgresql)"
assert_eq "shared comp inpod"    "/central/postgresql/backup_20260610-120000" "$(comp_inpod postgresql)"
assert_eq "shared comp location" "/central/clickhouse/backup_20260610-120000" "$(comp_location clickhouse)"
assert_eq "shared manifest"      "/backups/manifests/backup_20260610-120000.json" "$(manifest_path)"
assert_eq "shared latest"        "/backups/latest"                            "$(latest_path)"
assert_eq "vm dst shared"        "fs:///central/victoriametrics/backup_20260610-120000/p0/n" "$(vm_dst_for_pod p0 n)"

BACKUP_TARGET="${_pv_save_t}"; S3_ENABLED="${_pv_save_e}"; S3_BUCKET="${_pv_save_b}"
S3_PREFIX="${_pv_save_p}"; BACKUP_DIR="${_pv_save_d}"; SHARED_MOUNT_PATH="${_pv_save_m}"
RCLONE_REMOTE="${_pv_save_r}"; CURRENT_ID="${_pv_save_id}"

#########################################################################################
section "CHARACTERIZATION: restore component selection + verdict"
#########################################################################################
# Pinned before the ~30 restore globals collapse into a table. These decide what a destructive
# restore touches.
_rs_reset() {
    EXPLICIT_SELECTION=false
    RESTORE_POSTGRESQL=false; RESTORE_CLICKHOUSE=false; RESTORE_VICTORIAMETRICS=false
    RESTORE_PMM_SERVER=false; RESTORE_ENCRYPTION_KEY=false
    SKIP_POSTGRESQL=false; SKIP_CLICKHOUSE=false; SKIP_VICTORIAMETRICS=false
    SKIP_PMM_SERVER=false; SKIP_ENCRYPTION_KEY=false
    MF_PG_STATUS=success; MF_CH_STATUS=success; MF_VM_STATUS=success
    MF_PMM_STATUS=success; MF_ENC_STATUS=success
}
_rs_reset; select_default_components
assert_eq "default selects PG"  "true" "${RESTORE_POSTGRESQL}"
assert_eq "default selects CH"  "true" "${RESTORE_CLICKHOUSE}"
assert_eq "default selects VM"  "true" "${RESTORE_VICTORIAMETRICS}"
assert_eq "default selects PMM" "true" "${RESTORE_PMM_SERVER}"
assert_eq "default selects key" "true" "${RESTORE_ENCRYPTION_KEY}"

_rs_reset; MF_CH_STATUS=failed; select_default_components
assert_eq "a failed component is not selected" "false" "${RESTORE_CLICKHOUSE}"
assert_eq "...and the others still are"        "true"  "${RESTORE_POSTGRESQL}"

_rs_reset; SKIP_VICTORIAMETRICS=true; select_default_components
assert_eq "--skip beats the manifest default" "false" "${RESTORE_VICTORIAMETRICS}"
assert_eq "...and leaves the rest alone"      "true"  "${RESTORE_PMM_SERVER}"

_rs_reset; EXPLICIT_SELECTION=true; RESTORE_CLICKHOUSE=true; SKIP_CLICKHOUSE=true
select_default_components
assert_eq "--skip beats an explicit --<component>" "false" "${RESTORE_CLICKHOUSE}"

_rs_reset; EXPLICIT_SELECTION=true; RESTORE_POSTGRESQL=true; select_default_components
assert_eq "explicit selection stays narrow (PG on)"  "true"  "${RESTORE_POSTGRESQL}"
assert_eq "explicit selection stays narrow (CH off)" "false" "${RESTORE_CLICKHOUSE}"
_rs_reset

#########################################################################################
section "CHARACTERIZATION: store_list family + prune sweep, in a FRESH shell"
#########################################################################################
# Both drive the REAL storage layer against a temp directory in shared mode. They run in a
# fresh sourced shell because earlier sections replace store_list/store_list_dirs with
# fixture stubs, and asserting against those would exercise nothing (same reason as the
# catalog_manifest cache test above).
cat > "${SCRIPT_DIR}/.storetest.$$" <<'STOREEOF'
PMM_BACKUP_LIB=1
export PMM_BACKUP_LIB
# shellcheck disable=SC1090
. "$1"
set +e
log() { :; }
S3_ENABLED=false; BACKUP_TARGET=shared; LOG_FILE=/dev/null
R() { printf '%s=%s\n' "$1" "$2"; }

D=$(mktemp -d)
mkdir -p "${D}/sub-0" "${D}/sub-1" "${D}/empty"
: > "${D}/a.json"; : > "${D}/b.json"
R list_all   "$(store_list "${D}" | sort | tr '\n' ' ' | sed 's/ *$//')"
R list_files "$(store_list_files "${D}" | sort | tr '\n' ' ' | sed 's/ *$//')"
R list_dirs  "$(store_list_dirs "${D}" | sort | tr '\n' ' ' | sed 's/ *$//')"
out=$(store_list "${D}/nope"); R absent_rc "$?"; R absent_out "${out}"
out=$(store_list_dirs "${D}/nope"); R absentdir_rc "$?"
out=$(store_list "${D}/empty"); R empty_rc "$?"; R empty_out "${out}"
if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "${D}/locked"; chmod 000 "${D}/locked"
    store_list "${D}/locked" >/dev/null 2>&1;       R locked_rc "$?"
    store_list_files "${D}/locked" >/dev/null 2>&1; R lockedf_rc "$?"
    store_list_dirs "${D}/locked" >/dev/null 2>&1;  R lockedd_rc "$?"
    chmod 755 "${D}/locked"
else
    R locked_rc 1; R lockedf_rc 1; R lockedd_rc 1
fi
rm -rf "${D}"

# ---- prune fixtures ----------------------------------------------------------------
NAMESPACE=demo; BACKUP_RETENTION=7; DRY_RUN=false
id_days_ago() {
    e=$(( $(date +%s) - $1 * 86400 ))
    date -u -d "@${e}" '+backup_%Y%m%d-%H%M%S' 2>/dev/null || date -u -r "${e}" '+backup_%Y%m%d-%H%M%S' 2>/dev/null
}
mk() {   # <root> <id> <status> <ns> <components> [ch-base]
    root="$1"; id="$2"; st="$3"; ns="$4"; comps="$5"; base="${6:-}"
    mkdir -p "${root}/manifests"
    obj='{}'
    for c in ${comps}; do
        mkdir -p "${root}/${c}/${id}"; : > "${root}/${c}/${id}/data"
        if [ "${c}" = "clickhouse" ]; then
            obj=$(printf '%s' "${obj}" | jq --arg c "${c}" --arg n "${id}" --arg b "${base}" '. + {($c):{status:"success",name:$n,base:$b}}')
        else
            obj=$(printf '%s' "${obj}" | jq --arg c "${c}" '. + {($c):{status:"success"}}')
        fi
    done
    jq -n --arg id "${id}" --arg st "${st}" --arg ns "${ns}" --argjson c "${obj}" \
        '{schema:1,backup_id:$id,namespace:$ns,status:$st,components:$c}' > "${root}/manifests/${id}.json"
}
have() { [ -e "$1" ] && echo yes || echo no; }
ALL4="postgresql clickhouse victoriametrics pmm-server"
NEW=$(id_days_ago 1); OLD=$(id_days_ago 30); OLDER=$(id_days_ago 60)

# 1. expired purged whole, fresh untouched
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${NEW}" complete demo "${ALL4}"; mk "${B}" "${OLD}" complete demo "${ALL4}"
printf '%s' "${NEW}" > "${B}/latest"
PRUNE_REFUSED=0; prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t1_new_mf "$(have "${B}/manifests/${NEW}.json")"; R t1_new_data "$(have "${B}/postgresql/${NEW}")"
R t1_old_mf "$(have "${B}/manifests/${OLD}.json")"; R t1_old_pg "$(have "${B}/postgresql/${OLD}")"
R t1_old_ch "$(have "${B}/clickhouse/${OLD}")";     R t1_old_pmm "$(have "${B}/pmm-server/${OLD}")"
R t1_refused "${PRUNE_REFUSED}"
rm -rf "${B}"

# 2. 'latest' protected past the cutoff
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${OLD}" complete demo "${ALL4}"; mk "${B}" "${NEW}" complete demo "${ALL4}"
printf '%s' "${OLD}" > "${B}/latest"
prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t2_latest_kept "$(have "${B}/manifests/${OLD}.json")"
rm -rf "${B}"

# 3. no full-scope survivor => refuse
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${OLD}" complete demo "${ALL4}"; mk "${B}" "${NEW}" complete demo "clickhouse"
PRUNE_REFUSED=0; prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t3_refused "${PRUNE_REFUSED}"; R t3_kept "$(have "${B}/manifests/${OLD}.json")"
rm -rf "${B}"

# 4. every parseable backup expired => refuse
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${OLD}" complete demo "${ALL4}"; mk "${B}" "${OLDER}" complete demo "${ALL4}"
PRUNE_REFUSED=0; prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t4_refused "${PRUNE_REFUSED}"; R t4_a "$(have "${B}/manifests/${OLD}.json")"; R t4_b "$(have "${B}/manifests/${OLDER}.json")"
rm -rf "${B}"

# 5. foreign namespace is never deleted
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${NEW}" complete demo "${ALL4}"; mk "${B}" "${OLD}" complete other-ns "${ALL4}"
prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t5_foreign_kept "$(have "${B}/manifests/${OLD}.json")"
rm -rf "${B}"

# 6. a retained incremental pins ONLY its ClickHouse base
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${OLD}" complete demo "${ALL4}"; mk "${B}" "${NEW}" complete demo "${ALL4}" "${OLD}"
printf '%s' "${NEW}" > "${B}/latest"
prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t6_ch_kept "$(have "${B}/clickhouse/${OLD}")";  R t6_mf_kept "$(have "${B}/manifests/${OLD}.json")"
R t6_pg_gone "$(have "${B}/postgresql/${OLD}")";  R t6_pmm_gone "$(have "${B}/pmm-server/${OLD}")"
R t6_pg_status "$(jq -r '.components.postgresql.status' "${B}/manifests/${OLD}.json" 2>/dev/null)"
R t6_ch_status "$(jq -r '.components.clickhouse.status' "${B}/manifests/${OLD}.json" 2>/dev/null)"
R t6_overall   "$(jq -r '.status' "${B}/manifests/${OLD}.json" 2>/dev/null)"
rm -rf "${B}"

# 7. unreadable manifest defers the id
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${NEW}" complete demo "${ALL4}"; mk "${B}" "${OLD}" complete demo "${ALL4}"
printf 'not json' > "${B}/manifests/${OLD}.json"
prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t7_mf "$(have "${B}/manifests/${OLD}.json")"; R t7_data "$(have "${B}/postgresql/${OLD}")"
rm -rf "${B}"

# 8. a newer-schema manifest is deferred, never half-purged
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${NEW}" complete demo "${ALL4}"; mk "${B}" "${OLD}" complete demo "${ALL4}"
jq '.schema=99' "${B}/manifests/${OLD}.json" > "${B}/t" && mv "${B}/t" "${B}/manifests/${OLD}.json"
prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t8_mf "$(have "${B}/manifests/${OLD}.json")"; R t8_data "$(have "${B}/postgresql/${OLD}")"
rm -rf "${B}"

# 9. retention < 1 refuses outright
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${NEW}" complete demo "${ALL4}"; mk "${B}" "${OLD}" complete demo "${ALL4}"
BACKUP_RETENTION=0; PRUNE_REFUSED=0; prune_expired_backups >/dev/null 2>&1; catalog_cache_clear
R t9_refused "${PRUNE_REFUSED}"; R t9_kept "$(have "${B}/manifests/${OLD}.json")"
BACKUP_RETENTION=7
rm -rf "${B}"

# 10. a dry run deletes nothing
B=$(mktemp -d); BACKUP_DIR="${B}"
mk "${B}" "${NEW}" complete demo "${ALL4}"; mk "${B}" "${OLD}" complete demo "${ALL4}"
DRY_RUN=true; prune_expired_backups >/dev/null 2>&1; DRY_RUN=false; catalog_cache_clear
R t10_mf "$(have "${B}/manifests/${OLD}.json")"; R t10_data "$(have "${B}/postgresql/${OLD}")"
rm -rf "${B}"
STOREEOF
_st_res=$(sh "${SCRIPT_DIR}/.storetest.$$" "${TARGET}" 2>&1)
rm -f "${SCRIPT_DIR}/.storetest.$$"
# field <key> — pull one result out of the fresh shell's output
_f() { printf '%s\n' "${_st_res}" | sed -n "s/^$1=//p" | head -1; }

assert_eq "store_list sees files and dirs"            "a.json b.json empty sub-0 sub-1" "$(_f list_all)"
assert_eq "store_list_files sees only files"          "a.json b.json"                   "$(_f list_files)"
assert_eq "store_list_dirs sees only dirs, unslashed" "empty sub-0 sub-1"               "$(_f list_dirs)"
assert_eq "an absent dir is rc 0 (nothing there)"     "0"  "$(_f absent_rc)"
assert_eq "...and yields no output"                   ""   "$(_f absent_out)"
assert_eq "an absent dir is rc 0 (dirs-only)"         "0"  "$(_f absentdir_rc)"
assert_eq "an empty dir is rc 0"                      "0"  "$(_f empty_rc)"
assert_eq "...and yields no output"                   ""   "$(_f empty_out)"
assert_eq "an UNREADABLE dir is a LOOK failure"       "1"  "$(_f locked_rc)"
assert_eq "...files-only too"                         "1"  "$(_f lockedf_rc)"
assert_eq "...dirs-only too"                          "1"  "$(_f lockedd_rc)"

assert_eq "fresh backup's manifest survives"  "yes" "$(_f t1_new_mf)"
assert_eq "fresh backup's data survives"      "yes" "$(_f t1_new_data)"
assert_eq "expired manifest is deleted"       "no"  "$(_f t1_old_mf)"
assert_eq "expired PG data is deleted"        "no"  "$(_f t1_old_pg)"
assert_eq "expired CH data is deleted"        "no"  "$(_f t1_old_ch)"
assert_eq "expired /srv data is deleted"      "no"  "$(_f t1_old_pmm)"
assert_eq "a sweep that pruned is not refused" "0"  "$(_f t1_refused)"
assert_eq "the id 'latest' names is never pruned" "yes" "$(_f t2_latest_kept)"
assert_eq "no full-scope survivor => refuse"  "1"   "$(_f t3_refused)"
assert_eq "...and nothing is deleted"         "yes" "$(_f t3_kept)"
assert_eq "all expired => refuse"             "1"   "$(_f t4_refused)"
assert_eq "...nothing deleted (a)"            "yes" "$(_f t4_a)"
assert_eq "...nothing deleted (b)"            "yes" "$(_f t4_b)"
assert_eq "a foreign-namespace backup is skipped" "yes" "$(_f t5_foreign_kept)"
assert_eq "a pinned chain base keeps its CH data" "yes" "$(_f t6_ch_kept)"
assert_eq "...and its manifest"                   "yes" "$(_f t6_mf_kept)"
assert_eq "...but PG is still reclaimed"          "no"  "$(_f t6_pg_gone)"
assert_eq "...and /srv too"                       "no"  "$(_f t6_pmm_gone)"
assert_eq "...the index marks PG pruned"          "pruned"  "$(_f t6_pg_status)"
assert_eq "...ClickHouse stays restorable"        "success" "$(_f t6_ch_status)"
assert_eq "...and the id becomes partial"         "partial" "$(_f t6_overall)"
assert_eq "an unreadable manifest defers the id"  "yes" "$(_f t7_mf)"
assert_eq "...and its data is left alone"         "yes" "$(_f t7_data)"
assert_eq "a newer-schema manifest is deferred"   "yes" "$(_f t8_mf)"
assert_eq "...and nothing under it is purged"     "yes" "$(_f t8_data)"
assert_eq "--retention 0 refuses"                 "1"   "$(_f t9_refused)"
assert_eq "...and deletes nothing"                "yes" "$(_f t9_kept)"
assert_eq "a dry run deletes no manifest"         "yes" "$(_f t10_mf)"
assert_eq "a dry run deletes no data"             "yes" "$(_f t10_data)"

#########################################################################################
section "CHARACTERIZATION: temp restore pod specs are complete"
#########################################################################################
# Pinned before the two creators become one. A dropped field here is a pod rejected at
# admission — after PMM is already scaled to 0.
_tp_save_e="${S3_ENABLED}"; _tp_save_sec="${S3_SECRET_NAME}"; _tp_save_sa="${S3_SERVICE_ACCOUNT}"
_tp_save_pvc="${CENTRAL_BACKUP_PVC}"; _tp_save_keys="${TEMP_POD_S3_KEYS_ENV}"; _tp_save_line="${TEMP_POD_SA_LINE}"
_tp_out=$(mktemp)
kubectl() { if [ "${1:-}" = "create" ]; then cat > "${_tp_out}"; fi; return 0; }
clear_leftover_temp_pod() { :; }
wait_for_pod_ready_by_name() { return 0; }
_tp_yaml=""
_tp_capture() { : > "${_tp_out}"; TEMP_PODS_MARKER="" "$@" >/dev/null 2>&1; _tp_yaml=$(cat "${_tp_out}"); }
# has <label> <needle>  /  hasnt <label> <needle>
_tp_has()   { case "${_tp_yaml}" in *"$2"*) ok ;; *) bad "$1" "$2" "not in the rendered pod" ;; esac; }
_tp_hasnt() { case "${_tp_yaml}" in *"$2"*) bad "$1" "no $2" "present" ;; *) ok ;; esac; }

S3_ENABLED=true; S3_SECRET_NAME=""; S3_SERVICE_ACCOUNT="pmm-ha-backup-s3"
TEMP_POD_S3_KEYS_ENV=$(render_temp_pod_s3_keys_env)
TEMP_POD_SA_LINE=$(render_temp_pod_sa_line)

_tp_capture create_vm_restore_pod vm-restore-vmstorage-0 vmstorage-db-vmstorage-0 vmrestore:v1
_tp_has "vm pod is a Pod"                  "kind: Pod"
_tp_has "vm pod carries its name"          "name: vm-restore-vmstorage-0"
_tp_has "vm pod mounts the data PVC"       "claimName: vmstorage-db-vmstorage-0"
_tp_has "vm pod uses the resolved image"   "image: vmrestore:v1"
_tp_has "vm pod mounts at /vmstorage-data" "mountPath: /vmstorage-data"
_tp_has "vm pod opts out of consolidation" "karpenter.sh/do-not-disrupt"
_tp_has "vm pod carries the SA"            "serviceAccountName: pmm-ha-backup-s3"
_tp_has "vm pod carries its sweep label"   "component: vm-restore-temp"
_tp_has "vm pod never restarts"            "restartPolicy: Never"
_tp_has "vm pod gets the region"           "AWS_REGION"

_tp_capture create_pmm_restore_pod pmm-srv-restore-pmm-0 pmm-storage-pmm-0 percona/pmm-server:3
_tp_has "pmm pod is a Pod"                 "kind: Pod"
_tp_has "pmm pod mounts the data PVC"      "claimName: pmm-storage-pmm-0"
_tp_has "pmm pod mounts at /srv"           "mountPath: /srv"
_tp_has "pmm pod runs as root"             "runAsUser: 0"
_tp_has "pmm pod carries its sweep label"  "component: pmm-srv-restore-temp"
_tp_has "pmm pod gets rclone env on s3"    "RCLONE_CONFIG_S3_TYPE"
_tp_has "pmm pod opts out of consolidation" "karpenter.sh/do-not-disrupt"

S3_ENABLED=false; CENTRAL_BACKUP_PVC=central-pvc
_tp_capture create_vm_restore_pod vm-restore-vmstorage-0 vmstorage-db-vmstorage-0 vmrestore:v1
_tp_has   "shared vm pod mounts the central PVC" "claimName: central-pvc"
_tp_has   "shared vm pod mounts it at the shared path" "mountPath: /central"
_tp_hasnt "shared vm pod takes no rclone env"    "RCLONE_CONFIG"
_tp_capture create_pmm_restore_pod pmm-srv-restore-pmm-0 pmm-storage-pmm-0 img:1
_tp_has "shared pmm pod mounts the central PVC" "claimName: central-pvc"
_tp_has "the central mount is read-only"        "readOnly: true"

unset -f kubectl clear_leftover_temp_pod wait_for_pod_ready_by_name
rm -f "${_tp_out}"
S3_ENABLED="${_tp_save_e}"; S3_SECRET_NAME="${_tp_save_sec}"; S3_SERVICE_ACCOUNT="${_tp_save_sa}"
CENTRAL_BACKUP_PVC="${_tp_save_pvc}"; TEMP_POD_S3_KEYS_ENV="${_tp_save_keys}"; TEMP_POD_SA_LINE="${_tp_save_line}"

#########################################################################################
section "CHARACTERIZATION: lease_try_acquire — the shared lock primitive"
#########################################################################################
# Both the component locks and write_manifest's merge lease go through this now, so its
# outcomes are pinned here: a live holder is never stolen, a lease whose age cannot be
# determined is never stolen, and an apiserver failure is never read as "the lock is free".
_lt_save_ns="${NAMESPACE}"; NAMESPACE=unit

# The manifest body is what both the create and the guarded replace send.
_lm=$(LOCK_HOLDER=h1 lease_manifest pmm-backup-postgresql 900 postgresql "")
case "${_lm}" in *"name: pmm-backup-postgresql"*) ok ;; *) bad "manifest carries the name" "name" "${_lm}" ;; esac
case "${_lm}" in *"locked-component: postgresql"*) ok ;; *) bad "manifest carries the component label" "label" "${_lm}" ;; esac
case "${_lm}" in *resourceVersion*) bad "a create carries NO resourceVersion" "absent" "present" ;; *) ok ;; esac
_lm=$(LOCK_HOLDER=h1 lease_manifest pmm-backup-x 120 "" 4242)
case "${_lm}" in *'resourceVersion: "4242"'*) ok ;; *) bad "a takeover is resourceVersion-guarded" "rv" "${_lm}" ;; esac
case "${_lm}" in *locked-component*) bad "no component label when none is given" "absent" "present" ;; *) ok ;; esac

# Free lease: created, acquired, no incumbent reported.
kubectl() { case "$1" in create) return 0 ;; esac; return 0; }
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "a free lease is acquired" 0 "${_rc}"
assert_eq "...with no incumbent to report" "" "${LEASE_HOLDER}"

# The apiserver refuses for a reason that is NOT contention: must be rc 2, never "free".
kubectl() { echo "Error from server (Forbidden): leases is forbidden" >&2; return 1; }
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "an RBAC failure is 'could not tell', not 'free'" 2 "${_rc}"
case "${LEASE_ERR}" in *Forbidden*) ok ;; *) bad "the apiserver's text is kept" "Forbidden" "${LEASE_ERR}" ;; esac

# Held by a LIVE holder: refused, and never replaced.
_replaced=0
kubectl() {
    case "$1" in
        create)  echo 'Error from server (AlreadyExists): leases "l" already exists' >&2; return 1 ;;
        get)     printf '99\tother-holder\t%s\t900' "$(lease_now)"; return 0 ;;
        replace) _replaced=1; return 0 ;;
    esac
    return 0
}
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "a live lease is not acquired" 1 "${_rc}"
assert_eq "...and is reported as live"    "live" "${LEASE_STATE}"
assert_eq "...and is NEVER replaced"      "0" "${_replaced}"
assert_eq "...and names its holder"       "other-holder" "${LEASE_HOLDER}"

# Held, demonstrably EXPIRED, resourceVersion readable: taken over, with the rv as precondition.
# The replace runs inside a pipeline inside $( ), i.e. two subshells deep — so what it received
# has to come back through a FILE, not a variable.
_rv_file=$(mktemp)
kubectl() {
    case "$1" in
        create)  echo 'AlreadyExists' >&2; return 1 ;;
        get)     printf '77\tdead-holder\t2020-01-01T00:00:00.000000Z\t900'; return 0 ;;
        replace) cat > "${_rv_file}"; return 0 ;;
    esac
    return 0
}
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "an expired lease is taken over" 0 "${_rc}"
_rv_seen=$(cat "${_rv_file}"); rm -f "${_rv_file}"
case "${_rv_seen}" in *'resourceVersion: "77"'*) ok ;; *) bad "the takeover is rv-guarded" 'rv 77' "${_rv_seen}" ;; esac
assert_eq "...and the old holder is reported" "dead-holder" "${LEASE_HOLDER}"

# Expired, but the resourceVersion could not be read: no unguarded takeover.
kubectl() {
    case "$1" in
        create) echo 'AlreadyExists' >&2; return 1 ;;
        get)    printf '\tdead-holder\t2020-01-01T00:00:00.000000Z\t900'; return 0 ;;
    esac
    return 0
}
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "no resourceVersion means no takeover" 1 "${_rc}"
assert_eq "...reported as 'norv'"               "norv" "${LEASE_STATE}"

# renewTime unparseable: "cannot tell" must not read as expired.
kubectl() {
    case "$1" in
        create) echo 'AlreadyExists' >&2; return 1 ;;
        get)    printf '77\tsomeone\tnot-a-time\t900'; return 0 ;;
    esac
    return 0
}
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "an unreadable renewTime is not expiry" 1 "${_rc}"
assert_eq "...reported as 'unknown'"              "unknown" "${LEASE_STATE}"

# Lost the takeover race (the replace 409s).
kubectl() {
    case "$1" in
        create)  echo 'AlreadyExists' >&2; return 1 ;;
        get)     printf '77\tdead\t2020-01-01T00:00:00.000000Z\t900'; return 0 ;;
        replace) echo 'Operation cannot be fulfilled: the object has been modified' >&2; return 1 ;;
    esac
    return 0
}
_rc=0; lease_try_acquire l 900 postgresql || _rc=$?
assert_rc "losing the takeover race is its own outcome" 3 "${_rc}"

unset -f kubectl
NAMESPACE="${_lt_save_ns}"


#########################################################################################
section "CHARACTERIZATION: ch_run_action — one poll loop for create and upload"
#########################################################################################
# 'create' and 'upload' were two copies of this loop. The `since` fence is the part worth
# pinning: the command string is the poll key, so a rerun with the same --backup-id produces a
# byte-identical command, and without the fence the poll matches a stale 'success' row from the
# earlier attempt and reports success having created nothing.
_ca_log="${SCRIPT_DIR}/.chq.$$"
: > "${_ca_log}"
LOG_FILE=/dev/null
# ch_query stub: records each query and answers from _CA_STATUS / _CA_SINCE.
_CA_STATUS=success; _CA_SINCE=100
ch_query() {
    printf '%s\n' "$1" >> "${_ca_log}"
    case "$1" in
        *"ifNull(toUnixTimestamp(max(start)),0)"*) printf '%s' "${_CA_SINCE}" ;;
        "INSERT INTO"*) return 0 ;;
        "SELECT status"*) printf '%s' "${_CA_STATUS}" ;;
        "SELECT error"*)  printf 'disk full' ;;
    esac
    return 0
}
_rc=0; ch_run_action "create backup_X" 30 1 "backup creation" >/dev/null 2>&1 || _rc=$?
assert_rc "a successful action returns 0" 0 "${_rc}"
# The fence must be READ before the INSERT and APPLIED in the status poll.
_first=$(head -1 "${_ca_log}")
case "${_first}" in *"ifNull(toUnixTimestamp(max(start)),0)"*) ok ;;
    *) bad "the fence is read before enqueuing" "max(start) query first" "${_first}" ;; esac
case "$(grep -c 'toUnixTimestamp(start) > 100' "${_ca_log}")" in 0) bad "the poll applies the fence" ">100" "absent" ;; *) ok ;; esac
case "$(grep -c "^INSERT INTO system.backup_actions(command) VALUES('create backup_X')$" "${_ca_log}")" in
    1) ok ;; *) bad "the action is enqueued exactly once" "1" "$(grep -c INSERT "${_ca_log}")" ;; esac

# An error row fails the action and surfaces the message.
: > "${_ca_log}"; _CA_STATUS=error
_out=$(ch_run_action "upload backup_X" 30 1 "S3 upload" 2>&1); _rc=$?
assert_rc "a reported error fails the action" 1 "${_rc}"
case "$(grep -c '^SELECT error' "${_ca_log}")" in 0) bad "the error text is read" "SELECT error" "absent" ;; *) ok ;; esac

# A status that never becomes success times out rather than hanging.
: > "${_ca_log}"; _CA_STATUS=in_progress
_rc=0; ch_run_action "create backup_X" 2 1 "backup creation" >/dev/null 2>&1 || _rc=$?
assert_rc "a stuck action times out" 1 "${_rc}"

# A failed enqueue is a failure, not a poll.
ch_query() { case "$1" in "INSERT INTO"*) return 1 ;; *) printf '0' ;; esac; }
_rc=0; ch_run_action "create backup_X" 30 1 "backup creation" >/dev/null 2>&1 || _rc=$?
assert_rc "a failed enqueue fails immediately" 1 "${_rc}"

unset -f ch_query
rm -f "${_ca_log}"


#########################################################################################
section "prune_component_keys — a rejected key must reach the operator, not the caller's variable"
#########################################################################################
# Component keys come from the MANIFEST, i.e. from the store, and each becomes a path handed to
# a destructive call, so they are charset-gated (DN-17). The gate returns its results in globals
# on purpose: an earlier shape returned the list on stdout, and the caller's `$( )` then
# swallowed the diagnostic naming the bad key — while a global set inside that subshell could
# never propagate back out either.
prune_component_keys '{"components":{"postgresql":{},"clickhouse":{}}}' && _rc=0 || _rc=$?
assert_rc "a clean manifest passes"            0 "${_rc}"
assert_eq "...and yields its keys"             "clickhouse postgresql" "$(echo ${PRUNE_KEYS})"
assert_eq "...with nothing rejected"           "" "${PRUNE_BAD_KEYS}"

prune_component_keys '{"components":{"postgresql":{},"bad key!":{}}}' && _rc=0 || _rc=$?
assert_rc "a bad key fails the whole id"       1 "${_rc}"
assert_eq "...and NAMES it for the operator"   "'bad key!'" "${PRUNE_BAD_KEYS}"
# The whole id is deferred rather than the key dropped: dropping it leaves that component's data
# unpurged while the manifest — the only record of what the backup held — is deleted anyway.
assert_eq "...while the good keys are still reported" "postgresql" "$(echo ${PRUNE_KEYS})"

prune_component_keys '{"components":{}}' && _rc=0 || _rc=$?
assert_rc "an empty component set is not an error" 0 "${_rc}"
assert_eq "...and yields nothing"                  "" "$(echo ${PRUNE_KEYS})"
prune_component_keys 'not json' && _rc=0 || _rc=$?
assert_rc "unparseable input yields no keys, not a crash" 0 "${_rc}"
assert_eq "...and nothing to purge"                       "" "$(echo ${PRUNE_KEYS})"


#########################################################################################
section "value-returning functions must not log into their own stdout"
#########################################################################################
# Every one of these is called inside `$( )`. A plain log() there is swallowed into the captured
# value AND corrupts it — which turned ch_incremental_base's charset gate into the very
# injection it exists to prevent, and fed log text to `kubectl scale --replicas=`.
# These tests deliberately restore the REAL log() so the trap is reproducible.
_vr_saved_lf="${LOG_FILE}"; LOG_FILE=/dev/null
log() {
    _l="[$1] $2"
    echo "${_l}"
    { echo "${_l}" >> "${LOG_FILE}"; } 2>/dev/null || true
}

# A remote backup name that must be REFUSED — a space is a legal S3 key character, so this
# injects a clickhouse-backup flag if it is ever used as the incremental base.
ch_query() { printf '%s' 'backup_a --env S3_ENDPOINT=http://evil'; }
_got=$(ch_incremental_base)
assert_eq "a hostile remote name yields NO base (full upload)" "" "${_got}"
ch_query() { printf '%s' "backup_20260101-120000"; }
_got=$(ch_incremental_base)
assert_eq "a legitimate name is returned as the base" "backup_20260101-120000" "${_got}"
unset -f ch_query

# pmm_replica_count falls back and WARNs; the warning must not become the replica count.
kubectl() { return 1; }
PMM_SERVER_REPLICAS=3
_got=$(pmm_replica_count pmm-sts)
assert_eq "the fallback replica count is a bare number" "3" "${_got}"
case "${_got}" in ''|*[!0-9]*) bad "replica count is numeric" "digits" "${_got}" ;; *) ok ;; esac
# A non-numeric stashed annotation also WARNs, and must still resolve to a number.
kubectl() { case "$*" in *original-replicas*) echo "three" ;; *) echo "" ;; esac; }
_got=$(pmm_replica_count pmm-sts)
case "${_got}" in ''|*[!0-9]*) bad "a bad annotation still yields a number" "digits" "${_got}" ;; *) ok ;; esac
unset -f kubectl

log() { :; }
LOG_FILE="${_vr_saved_lf}"


#########################################################################################
section "--parallel on the backup side"
#########################################################################################
# The DEFAULTS differ by subcommand and that is deliberate, so pin both: a restore runs with
# PMM at 0 (nothing serving, only RTO matters), a backup runs against a live system.
PARALLEL=""
parallel_enabled true  && _rc=0 || _rc=$?; assert_rc "restore defaults to PARALLEL"   0 "${_rc}"
parallel_enabled false && _rc=0 || _rc=$?; assert_rc "backup defaults to SEQUENTIAL"  1 "${_rc}"
PARALLEL=true
parallel_enabled false && _rc=0 || _rc=$?; assert_rc "--parallel overrides the backup default"  0 "${_rc}"
PARALLEL=false
parallel_enabled true  && _rc=0 || _rc=$?; assert_rc "--sequential overrides the restore default" 1 "${_rc}"
PARALLEL=""

# --parallel/--sequential must be accepted by BOTH operations now, and still refused elsewhere.
_saved_cmd="${COMMAND}"
for _c in backup restore list; do
    COMMAND="${_c}"
    ( flag_requires "backup restore" --parallel ) >/dev/null 2>&1 && _rc=0 || _rc=$?
    assert_rc "--parallel is accepted by '${_c}'" 0 "${_rc}"
done
COMMAND=prune
( flag_requires "backup restore" --parallel ) >/dev/null 2>&1 && _rc=0 || _rc=$?
assert_rc "--parallel is still refused by 'prune'" 1 "${_rc}"
# The single-subcommand form must keep working exactly as before.
COMMAND=backup
( flag_requires restore --s3-provider ) >/dev/null 2>&1 && _rc=0 || _rc=$?
assert_rc "a restore-only flag is still refused by 'backup'" 1 "${_rc}"
COMMAND=prune
( flag_requires backup --retention ) >/dev/null 2>&1 && _rc=0 || _rc=$?
assert_rc "'prune' still takes the backup flag set" 0 "${_rc}"
COMMAND="${_saved_cmd}"

# _backup_child must carry the whole RESULT OBJECT back, not just a status — that is what
# distinguishes it from _restore_child, and what the parent merges into RESULTS_JSON.
_bc_dir=$(mktemp -d)
backup_postgresql() {
    result_set postgresql --arg status success --arg engine pg_dump --argjson bytes 4242 \
        '{status:$status, engine:$engine, bytes:$bytes}'
    return 0
}
( _backup_child postgresql "${_bc_dir}" )
assert_eq "the child reports its status"        "0" "$(cat "${_bc_dir}/postgresql.rc" 2>/dev/null)"
assert_eq "...and its full result object"       "success" "$(jq -r '.postgresql.status' "${_bc_dir}/postgresql.json" 2>/dev/null)"
assert_eq "...including the measured detail"    "4242"    "$(jq -r '.postgresql.bytes'  "${_bc_dir}/postgresql.json" 2>/dev/null)"

# A component that FAILS must still report both, so the parent can tell it apart from a child
# that died. record_backup_result then turns an absent entry into an explicit failure.
backup_clickhouse() { return 1; }
( _backup_child clickhouse "${_bc_dir}" )
assert_eq "a failed component reports its rc"   "1"  "$(cat "${_bc_dir}/clickhouse.rc" 2>/dev/null)"
assert_eq "...and an (empty) result object"     "{}" "$(cat "${_bc_dir}/clickhouse.json" 2>/dev/null)"

# The child must NOT inherit a sibling's results: RESULTS_JSON is reset, so each file holds
# exactly one component and the parent's merge cannot resurrect another's entry.
RESULTS_JSON='{"victoriametrics":{"status":"success"}}'
( _backup_child postgresql "${_bc_dir}" )
assert_eq "a child's file holds only its own component" "postgresql" \
    "$(jq -r 'keys|join(",")' "${_bc_dir}/postgresql.json" 2>/dev/null)"
RESULTS_JSON='{}'

# The parent's merge, then record_backup_result — together they are what makes a failure
# visible. The merge alone yields only postgresql, because a component that failed before its
# result_set has nothing to contribute; the synthesised entry is what stops that reading as
# "never selected" (DN-38).
RESULTS_JSON='{}'
for _c in postgresql clickhouse; do
    _r=$(cat "${_bc_dir}/${_c}.json")
    RESULTS_JSON=$(printf '%s' "${RESULTS_JSON}" | jq --argjson o "${_r}" '. + $o')
done
assert_eq "the merge carries the components that reported" "postgresql" \
    "$(printf '%s' "${RESULTS_JSON}" | jq -r 'keys|join(",")')"
# Now the parent records each outcome, exactly as cmd_backup's merge loop does.
components_backed_up=0; components_failed=0; all_success=true
record_backup_result PostgreSQL postgresql "$(cat "${_bc_dir}/postgresql.rc")" || true
record_backup_result ClickHouse clickhouse "$(cat "${_bc_dir}/clickhouse.rc")" || true
# A child that died without writing a status at all: absent file -> rc 1 -> FAILED.
record_backup_result VictoriaMetrics victoriametrics \
    "$(cat "${_bc_dir}/victoriametrics.rc" 2>/dev/null || echo 1)" || true
assert_eq "the successful component is counted"      "1" "${components_backed_up}"
assert_eq "both failures are counted"                "2" "${components_failed}"
assert_eq "...and the run is not a success"          "false" "${all_success}"
assert_eq "a component that failed early is FAILED, not absent" "failed" "$(result_get clickhouse status)"
assert_eq "a child that vanished is FAILED too"                 "failed" "$(result_get victoriametrics status)"
rm -rf "${_bc_dir}"
unset -f backup_postgresql backup_clickhouse
RESULTS_JSON='{}'


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
