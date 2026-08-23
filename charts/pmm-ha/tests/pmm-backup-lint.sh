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

# A bare `wait` waits for EVERY background child. Since held locks are kept fresh by a
# background renewer with an infinite loop, a bare `wait` never returns — the restore hung with
# all components finished and PMM at 0 replicas, and nothing in the log explained it. Always
# wait on explicit PIDs.
# The --help text contains a `wait` in its concurrent-backup example; that is documentation
# inside a heredoc, not code, so the help function's body is excluded.
help_start = next((i for i, ln in enumerate(lines) if ln.startswith('show_help()')), None)
help_end = next((i for i, ln in enumerate(lines[help_start:], help_start)
                 if ln.strip() == 'EOF'), help_start) if help_start is not None else -1
bare = [i + 1 for i, ln in enumerate(lines)
        if re.match(r'^\s*wait\s*(#.*)?$', ln)
        and not (help_start is not None and help_start <= i <= help_end)]
if bare:
    print("FAIL: bare `wait` waits for the lock renewer too and will hang. Wait on explicit PIDs.")
    for n in bare: print(f"        line {n}")
    raise SystemExit(1)
print("  ok: no bare `wait` (it would block on the lock renewer)")

# show_help's heredoc is UNQUOTED, because the usage text interpolates $0. That also makes
# backticks inside it command substitution: a markdown-style `consistency: per-component` in the
# text ran `consistency:` as a command, so every --help printed a "command not found" error, and
# any future backticked content would EXECUTE. Use single quotes in that text.
if help_start is not None and help_end > help_start:
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
