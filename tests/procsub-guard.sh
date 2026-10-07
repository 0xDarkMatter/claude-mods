#!/usr/bin/env bash
# Mutation gate for the `# procsub guard:` sites in tests/ and the skill suites.
#
# A loop fed by `< <(producer)` never sees the producer's exit status, so a producer
# that dies part-way just ends the loop and the suite passes on fewer checks. Each
# guarded site captures the producer, checks its exit, then loops (AGENTS.md
# Landmines). This gate proves every guard still bites: for each case it puts a shim
# first on PATH that runs the real tool, keeps only the first half of its output and
# exits 70, the shape of a producer that died part-way. The suite must then FAIL with
# that site's own guard message. A suite that passes, or fails for another reason,
# fails this gate.
#
# The case table is EXPLICIT on purpose. Never switch it to discovering
# `# procsub guard:` tags: sites under skills/*/scripts/ break other producers, which
# this gate cannot shim. Add one row per new guarded site in tests/ or a skill suite.
#
# Usage:   bash tests/procsub-guard.sh [--help]
# Output:  one PASS/FAIL row per case on stdout; a failing case's log tail follows it.
# Exit:    0 every guard bites, 1 a guard let a broken producer through, 2 usage
#          error or no working tool to shim.
set -u

usage() {
    cat <<'EOF'
Usage: tests/procsub-guard.sh [--help]

Break the producer of each guarded `< <(producer)` site (shim: real tool, half its
output, exit 70) and check that the owning suite fails with the guard's message.

EXAMPLES
  bash tests/procsub-guard.sh
  bash tests/procsub-guard.sh --help

Exit codes: 0 every guard bites, 1 a guard let a broken producer through,
2 usage error or no working tool to shim.
EOF
}

case "${1-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "procsub-guard: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A *working* python, picked the way the suites pick theirs: on Windows `python3` can be
# the Store stub, which is on PATH but exits non-zero.
REAL_PY=""
for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then REAL_PY="$(type -P "$c")"; break; fi
done
REAL_RG="$(type -P rg || true)"
REAL_GIT="$(type -P git || true)"

# make_shim <dir> <name> <real-tool> <case-pattern>
# The pattern is a bash `case` pattern matched against the call's "$*"; only matching
# calls are broken, every other call execs the real tool untouched.
make_shim() {
    mkdir -p "$1"
    cat >"$1/$2" <<EOF
#!/usr/bin/env bash
case "\$*" in
    $4)
        out="\$("$3" "\$@")"
        n="\$(printf '%s\n' "\$out" | wc -l)"
        printf '%s\n' "\$out" | head -n "\$(( n / 2 ))"
        echo "procsub-guard: injected producer crash" >&2
        exit 70 ;;
esac
exec "$3" "\$@"
EOF
    chmod +x "$1/$2"
}

PASS=0; FAIL=0; MISSING=0
# expect_guard <label> <shim-dir> <expected guard message> <suite...>
expect_guard() {
    local label="$1" shims="$2" want="$3" log rc=0
    shift 3
    log="$WORK/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').log"
    PATH="$shims:$PATH" bash "$@" >"$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF -- "$want" "$log"; then
        PASS=$((PASS + 1)); echo "  PASS  $label (exit $rc)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL  $label (exit $rc, want non-zero with: $want)"
        tail -n 15 "$log" | sed 's/^/        /'
    fi
}
missing() { MISSING=$((MISSING + 1)); FAIL=$((FAIL + 1)); echo "  FAIL  $1: no working $2 to shim"; }

echo "=== procsub-guard: each guarded producer, broken part-way ==="

# --- case table: <label> | tool shimmed | call broken | suite | its guard message ---
if [ -n "$REAL_PY" ]; then
    for name in python3 python py; do
        make_shim "$WORK/py" "$name" "$REAL_PY" '"- "*'   # `python - <args>` = program on stdin
    done
    expect_guard "frontend-upgrade-ops shape check" "$WORK/py" \
        "shape-contract python exited 70" skills/frontend-upgrade-ops/tests/run.sh
else missing "frontend-upgrade-ops shape check" python; fi

if [ -n "$REAL_RG" ]; then
    make_shim "$WORK/rg" rg "$REAL_RG" '*security-ops/references/*'
    expect_guard "security-ops citation scan" "$WORK/rg" \
        "citation scan failed (rg exit 70)" skills/security-ops/tests/run.sh
else missing "security-ops citation scan" rg; fi

if [ -n "$REAL_GIT" ]; then
    make_shim "$WORK/git" git "$REAL_GIT" '"ls-files "*'
    expect_guard "check-exec-bits index scan" "$WORK/git" \
        "git ls-files failed (exit 70)" tests/check-exec-bits.sh
else missing "check-exec-bits index scan" git; fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$MISSING" -eq 0 ] || exit 2
[ "$FAIL" -eq 0 ] || exit 1
exit 0
