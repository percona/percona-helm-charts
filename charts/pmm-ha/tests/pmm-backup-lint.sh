#!/bin/sh
# Static checks on files/pmm-backup.sh that a shell parser cannot make.
#
# The orchestrator runs under `set -u`, where reading a variable that was never assigned is a
# FATAL abort — and it aborts wherever the read happens, which for this tool means "after every
# component has uploaded but before the manifest is written", i.e. orphaned data with no index.
# That has happened twice: once from a dash-only `${var:0:16}` (DN-22) and once from a global
# that a refactor deleted while a consumer still read it. `sh -n` cannot catch either, because
# it never evaluates expansions.
#
#   sh charts/pmm-ha/tests/pmm-backup-lint.sh

set -u
DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TARGET="${DIR}/../files/pmm-backup.sh"
FAIL=0

# A missing interpreter must FAIL, not skip. This suite is the CI gate for the `set -u` aborts
# and dash-only expansions that files/pmm-backup.sh records shipping twice, and an `exit 0` here
# made the workflow step green while running nothing at all — the same silent-skip pattern
# validate_restore_targets refuses ("a silent skip is worse than no gate"). Set
# PMM_BACKUP_TESTS_ALLOW_SKIP=1 to opt out deliberately on a machine that cannot install python3.
if ! command -v python3 >/dev/null 2>&1; then
    if [ "${PMM_BACKUP_TESTS_ALLOW_SKIP:-0}" = "1" ]; then
        echo "SKIP: python3 is not installed (PMM_BACKUP_TESTS_ALLOW_SKIP=1)"; exit 0
    fi
    echo "FAIL: python3 is required to run these tests and is not on PATH." >&2
    echo "      Install it, or re-run with PMM_BACKUP_TESTS_ALLOW_SKIP=1 to skip deliberately." >&2
    exit 1
fi

python3 - "${TARGET}" <<'PY' || FAIL=1
import re, sys
src = open(sys.argv[1]).read()

# Variables READ without a default, i.e. ${VAR} rather than ${VAR:-...} / ${VAR#...} etc.
reads    = set(re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', src))
guarded  = set(re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)[:#%+\-/=?]', src))

# Assignments, including several-per-line forms this file uses heavily:
#   FOO=1                      A="" ; B=""            local a b c
#   local x="${1:-}" y=2       for v in ...           while read -r v
assigned = set()
for stmt in re.split(r'[;&|\n]', src):
    stmt = stmt.strip()
    # Several assignments can share one statement, prefix-style:
    #   _ps_tag="$1" _ps_pod="$2" _ps_ctr="$3"
    # so match every VAR= at a token boundary, not just the first.
    for m in re.finditer(r'(?:^|\s)(?:local\s+|export\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=', stmt):
        assigned.add(m.group(1))
    if stmt.startswith('local '):
        for tok in stmt[6:].split():
            assigned.add(tok.split('=')[0])
    m = re.match(r'^for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b', stmt)
    if m: assigned.add(m.group(1))
    for m in re.finditer(r'\bread\s+(?:-r\s+)?([A-Za-z_][A-Za-z0-9_]*)', stmt):
        assigned.add(m.group(1))

# Supplied by the environment or the shell itself.
external = {
    'HOSTNAME','PATH','HOME','PWD','IFS','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY',
    'PMM_BACKUP_LIB','PMM_SERVER_REPLICAS','LOG_FILE_WARNING_SHOWN',
}
missing = sorted(v for v in reads - guarded - assigned - external)
if missing:
    print("FAIL: read under `set -u` but never assigned (would abort at runtime):")
    for v in missing: print(f"        ${{{v}}}")
    raise SystemExit(1)
print("  ok: no variable is read bare without being assigned")

# Every design-note reference must resolve to a real note.
notes = set(re.findall(r'^## (DN-\d+)', open(sys.argv[1].replace('files/pmm-backup.sh','docs/pmm-backup-design-notes.md')).read(), re.M))
refs  = set(re.findall(r'\b(DN-\d+)\b', src))
dangling = sorted(refs - notes)
if dangling:
    print("FAIL: pmm-backup.sh points at design notes that do not exist:", ", ".join(dangling))
    raise SystemExit(1)
print(f"  ok: all {len(refs)} design-note references resolve ({len(notes)} notes exist)")

# A variable can be assigned somewhere and STILL abort under `set -u`, if the assignment sits on
# a conditional path while the read does not. That is exactly how CH_BACKUP_BASE aborted a full
# backup after every component had uploaded: it is set only on the incremental path.
#
# Dataflow analysis is out of scope for a shell lint, but this file already states the
# convention that makes it unnecessary — "runtime state initialised up front, because the script
# runs under set -u". So: any SHOUTY_CASE global assigned only from inside a function body must
# also be initialised at top level (column 0).
lines = src.split("\n")
top_level, in_func, declared_local = set(), {}, set()
for i, ln in enumerate(lines):
    for m in re.finditer(r'(?:^|\s)([A-Z][A-Z0-9_]{2,})=', ln):
        name = m.group(1)
        if re.match(r'^[A-Z]', ln):          # column 0 -> a top-level initialisation
            top_level.add(name)
        else:
            in_func.setdefault(name, i + 1)
    for m in re.finditer(r'\blocal\s+([^;]*)', ln):
        for tok in m.group(1).split():
            declared_local.add(tok.split('=')[0])

late = sorted(n for n in in_func
              if n not in top_level and n not in declared_local and n not in external
              and n in reads)
if late:
    print("FAIL: global(s) assigned only inside a function, so a path that skips the assignment")
    print("      aborts on the read under `set -u`. Initialise them at top level:")
    for n in late: print(f"        {n}  (first assigned at line {in_func[n]})")
    raise SystemExit(1)
print("  ok: every global read is initialised at top level")

# The check above only covers SHOUTY_CASE globals. The same `set -u` abort is reachable through a
# LOWERCASE name, and the first check cannot see it either: a variable that is `local` in ONE
# function counts as "assigned" file-wide, so a read of it from a DIFFERENT function looks fine.
#
# That is exactly how `failed_pods="${failed_pods} ord-${ord}"` shipped in restore_pmm_server:
# `failed_pods` is `local` to the two BACKUP functions and does not exist in the restore path, so
# the line aborted the whole run — after scale_down_pmm, i.e. with PMM at 0 replicas.
#
# The precise signature is: the FIRST assignment of a name inside a function reads that same name
# (`X="${X}..."` / `X=$((X + 1))`), while the name is neither `local` in that function nor
# initialised at top level. Anything else is out of a regex lint's reach, but this shape is the one
# that bites, because appending to an accumulator is how these are always used.
func_starts = [(i, m.group(1)) for i, ln in enumerate(lines)
               for m in [re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{', ln)] if m]
top_level_any = set()
for ln in lines:
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', ln)
    if m: top_level_any.add(m.group(1))

# Intentional dynamic scoping: set by a helper, owned by the caller that always initialises it
# first. Each entry is a promise that the ONLY callers run inside that caller's frame.
#   cmd_backup's counters <- record_backup_result
dynamic_scoped = {'components_backed_up', 'components_failed', 'all_success'}

selfref = []
for idx, (start, fname) in enumerate(func_starts):
    end = next((i for i in range(start + 1, len(lines)) if lines[i].rstrip() == '}'), len(lines))
    body = lines[start + 1:end]
    locals_here = set()
    for ln in body:
        for m in re.finditer(r'\blocal\s+([^;]*)', ln):
            for tok in m.group(1).split():
                locals_here.add(tok.split('=')[0])
    first_seen = {}
    for ln in body:
        for m in re.finditer(r'(?:^|[\s;{&|])([a-z_][a-z0-9_]*)=', ln):
            first_seen.setdefault(m.group(1), ln)
    for name, ln in first_seen.items():
        if name in locals_here or name in top_level_any or name in external or name in dynamic_scoped:
            continue
        rhs = ln.split(name + '=', 1)[1]
        if re.search(r'\$\{' + name + r'[}:#%]', rhs) or re.search(r'\$\(\(.*\b' + name + r'\b', rhs):
            selfref.append((fname, name, ln.strip()))
if selfref:
    print("FAIL: a function's FIRST assignment to a variable reads that same variable, but the")
    print("      variable is not `local` here and not initialised at top level — so under `set -u`")
    print("      this aborts the run. Declare it `local`, or initialise it at top level:")
    for fn, name, ln in selfref:
        print(f"        {fn}(): {name}  ->  {ln}")
    raise SystemExit(1)
print(f"  ok: no function appends to an accumulator it does not own ({len(func_starts)} functions checked)")

# A bare `wait` waits for EVERY background child. Since held locks are kept fresh by a
# background renewer with an infinite loop, a bare `wait` never returns — the restore hung with
# all components finished and PMM at 0 replicas, and nothing in the log explained it. Always
# wait on explicit PIDs.
# The --help text contains a `wait` in its concurrent-backup example; that is documentation
# inside a heredoc, not code, so the help function's body is excluded.
# Both the bare-`wait` rule below and the backtick rule after it EXCLUDE / SCAN the show_help
# heredoc, so if these anchors stop resolving, those checks silently pass on everything or scan
# the wrong range. A renamed function, a `show_help ()` with a space, or a changed heredoc
# The lock renewer runs as a detached subshell and must inherit NONE of the caller's write ends.
# It emits nothing, but stop_lock_renewer's `kill` reaches the subshell, not the `sleep` it is
# blocked in — and that orphaned `sleep` holds whatever descriptors it inherited. With stdout (or
# fd 9, the duplicate opened at the top of the file) still attached, `pmm-backup.sh ... | tee`
# hangs for up to LOCK_RENEW_SECONDS after the run has finished and printed its summary.
m = re.search(r'^start_lock_renewer\(\) \{.*?^\}', src, re.S | re.M)
if not m:
    print("FAIL: start_lock_renewer not found"); raise SystemExit(1)
if not re.search(r'\)\s*>/dev/null\s+2>&1\s+9>&-\s*&', m.group(0)):
    print("FAIL: the lock renewer subshell must be backgrounded as `) >/dev/null 2>&1 9>&- &`")
    print("      so its orphaned `sleep` cannot hold the caller's stdout (or fd 9) open.")
    raise SystemExit(1)
print("  ok: the lock renewer cannot hold the caller's stdout open")

# A function whose STDOUT IS ITS VALUE must not call log() on plain stdout: every call site wraps
# it in `$( )`, so the message is swallowed into the captured value instead of reaching the
# operator — and the value is then corrupted by the log text. That inverted ch_incremental_base's
# charset gate into the injection it exists to prevent, and it silently fed log text to
# `kubectl scale --replicas=`. Such functions must redirect to fd 9 (the duplicate of the original
# stdout opened at the top of the file), which is what pod_sh already does for its preview.
func_bodies = {}
for i, ln in enumerate(lines):
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_-]*)\(\)\s*\{', ln)
    if not m: continue
    name = m.group(1)
    if ln.rstrip().endswith('}'):
        func_bodies[name] = [ln]
    else:
        end = next((j for j in range(i + 1, len(lines)) if lines[j] == '}'), len(lines))
        func_bodies[name] = lines[i + 1:end]

captured = set()
for ln in lines:
    if ln.strip().startswith('#'): continue
    for m in re.finditer(r'\$\(([^()]*)\)', ln):
        toks = m.group(1).strip().split()
        if toks and toks[0] in func_bodies: captured.add(toks[0])

offenders = []
for name in sorted(captured):
    for b in func_bodies[name]:
        if re.search(r'\blog "', b) and not re.search(r'>&9', b):
            offenders.append((name, b.strip()[:80]))
            break
if offenders:
    print("FAIL: function(s) called inside $( ) log to plain stdout, so the message is captured")
    print("      into the caller's value instead of reaching the operator. Redirect to >&9:")
    for n, b in offenders: print(f"        {n}: {b}")
    raise SystemExit(1)
print(f"  ok: no value-returning function logs into its own stdout ({len(captured)} checked)")


# delimiter would do it. Fail loudly instead of degrading into a no-op gate.
help_start = next((i for i, ln in enumerate(lines) if re.match(r'^show_help\s*\(\)', ln)), None)
if help_start is None:
    print("FAIL: cannot find the show_help() definition, so the --help heredoc cannot be located.")
    print("      Two checks below depend on it and would silently pass. Fix this lint's anchor.")
    raise SystemExit(1)
m_delim = next((re.search(r"<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?", ln)
                for ln in lines[help_start:help_start + 5] if '<<' in ln), None)
if not m_delim:
    print(f"FAIL: no heredoc opener found within 5 lines of show_help() (line {help_start + 1}).")
    raise SystemExit(1)
help_delim = m_delim.group(1)
help_end = next((i for i, ln in enumerate(lines[help_start:], help_start)
                 if ln.strip() == help_delim), None)
if help_end is None:
    print(f"FAIL: the show_help heredoc opened with <<{help_delim} has no matching terminator.")
    print("      Without it the checks below would scan an unrelated range of the file.")
    raise SystemExit(1)
print(f"  ok: show_help heredoc located (lines {help_start + 1}-{help_end + 1}, delimiter {help_delim})")
bare = [i + 1 for i, ln in enumerate(lines)
        if re.match(r'^\s*wait\s*(#.*)?$', ln)
        and not (help_start <= i <= help_end)]
if bare:
    print("FAIL: bare `wait` waits for the lock renewer too and will hang. Wait on explicit PIDs.")
    for n in bare: print(f"        line {n}")
    raise SystemExit(1)
print("  ok: no bare `wait` (it would block on the lock renewer)")

# show_help's heredoc is UNQUOTED, because the usage text interpolates $0. That also makes
# backticks inside it command substitution: a markdown-style `consistency: per-component` in the
# text ran `consistency:` as a command, so every --help printed a "command not found" error, and
# any future backticked content would EXECUTE. Use single quotes in that text.
ticked = [i + 1 for i, ln in enumerate(lines[help_start:help_end], help_start) if '`' in ln]
if ticked:
    print("FAIL: backtick inside show_help's unquoted heredoc — it is command substitution,")
    print("      not markdown. Use single quotes:")
    for n in ticked: print(f"        line {n}: {lines[n - 1].strip()}")
    raise SystemExit(1)
print("  ok: no backticks in the unquoted --help heredoc")
PY

if [ "${FAIL}" -eq 0 ]; then echo "LINT OK"; exit 0; fi
echo "LINT FAILED"; exit 1
