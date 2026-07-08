#!/usr/bin/env bash
# Self-test for claude-api-ops — fully offline: no network, no Anthropic API.
#
# Wraps the skill's §7 staleness verifier (scripts/check-model-table.py), which
# guards the two fast-moving fact tables (SKILL.md "Current Models" and
# references/caching-and-cost.md cache-minimums) against silent drift. Contract
# (py_compile + --help), offline happy path against the shipped skill, the
# --json §7 envelope, and a NEGATIVE proving the verifier actually rejects a bad
# model id (a date-suffixed alias — exactly what SKILL.md forbids). --live is
# NEVER invoked: it hits the Models API, and a network blip must never fail a PR.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/check-model-table.py"

# Pick a python that actually executes (the Windows Store python3 stub exists
# on PATH but exits non-zero; probe by running it).
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== claude-api-ops self-test ==="

if [[ -z "$PYTHON" ]]; then
  echo "  SKIP  no working python (verifier is python) — cannot test"
  [[ "$FAIL" -eq 0 ]] || exit 1
  exit 0
fi

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
"$PYTHON" -m py_compile "$V" 2>/dev/null && ok "py_compile check-model-table.py" || no "py_compile check-model-table.py"
"$PYTHON" "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
out="$("$PYTHON" "$V" --help 2>&1)"
expect_has "--help has EXAMPLES" "EXAMPLES" "$out"
"$PYTHON" "$V" --bogus >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?

# ── offline structural mode (§7 seam: --offline default, --live advisory) ─────
echo "-- offline structural --"
"$PYTHON" "$V" --offline >/dev/null 2>&1; expect_exit "--offline clean on shipped skill" 0 $?
out="$("$PYTHON" "$V" --offline --json 2>/dev/null)"
expect_has "--offline --json envelope schema" '"schema": "claude-mods.claude-api-ops.model-table/v1"' "$out"
expect_has "--offline --json consistent" '"consistent": true' "$out"

# ── negative: a date-suffixed alias must be rejected (exit 4 VALIDATION) ──────
# Run the verifier from a doctored copy; never mutate the shipped skill.
echo "-- negative --"
cp -r "$SKILL" "$SB/copy"
# Append the date suffix SKILL.md explicitly forbids ("Never append date
# suffixes"). The verifier's DATE_SUFFIX_RE must flag it as VALIDATION drift.
# Target the table cell uniquely (the prose never pairs "Opus 4.8 |" with the
# backticked id) so the edit is surgical.
"$PYTHON" - "$SB/copy/SKILL.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
t = t.replace("Opus 4.8 | `claude-opus-4-8`", "Opus 4.8 | `claude-opus-4-8-20251114`")
p.write_text(t, encoding="utf-8")
PY
"$PYTHON" "$SB/copy/scripts/check-model-table.py" --offline >"$SB/neg.out" 2>&1
expect_exit "--offline flags date-suffixed id -> 4" 4 $?
expect_has "finding names the date suffix" "date suffix" "$(cat "$SB/neg.out")"

# ── SKILL.md sanity ───────────────────────────────────────────────────────────
echo "-- SKILL.md --"
grep -q '^name: claude-api-ops$' "$SKILL/SKILL.md" && ok "frontmatter name" || no "frontmatter name"
grep -q 'check-model-table.py' "$SKILL/SKILL.md" && ok "verifier cited from SKILL.md" || no "verifier cited from SKILL.md"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
