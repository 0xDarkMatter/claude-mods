#!/usr/bin/env bash
# Self-test for claude-code-ops — fully offline: no network.
#
# Wraps the skill's offline hooks-contract verifier (scripts/validate-hooks-json.py),
# which lints a hooks.json / settings.json hooks block against the 30-event Claude
# Code hook catalog. Contract (py_compile + --help), offline happy path against
# the shipped skill (assets/hooks.json.template, stripped of its JSONC comments
# exactly as the template's own header instructs — "STRIP EVERY COMMENT"), the
# --json §7 envelope, and a NEGATIVE proving the verifier rejects an unknown
# event (exit 10, names the event). The verifier is structural-only by design;
# there is no --live mode to avoid.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/validate-hooks-json.py"
TPL="$SKILL/assets/hooks.json.template"

# Pick a python that actually executes (the Windows Store python3 stub exists on
# PATH but exits non-zero; probe by running it).
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

echo "=== claude-code-ops self-test ==="

if [[ -z "$PYTHON" ]]; then
  echo "  SKIP  no working python (verifier is python) — cannot test"
  [[ "$FAIL" -eq 0 ]] || exit 1
  exit 0
fi

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
"$PYTHON" -m py_compile "$V" 2>/dev/null && ok "py_compile validate-hooks-json.py" || no "py_compile validate-hooks-json.py"
"$PYTHON" "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
out="$("$PYTHON" "$V" --help 2>&1)"
expect_has "--help has EXAMPLES" "EXAMPLES" "$out"
"$PYTHON" "$V" --bogus >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?

# ── offline happy path: shipped template, comments stripped (its own rule) ─────
echo "-- offline structural --"
# The shipped assets/hooks.json.template is intentionally JSONC. Stripping // lines
# yields strict JSON that must lint clean against the catalog. The path is passed
# as an argv (MSYS translates it for Windows Python); never embed it in -c.
grep -vE '^[[:space:]]*//' "$TPL" > "$SB/hooks.json"
"$PYTHON" -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$SB/hooks.json" \
  >/dev/null 2>&1 && ok "stripped template is strict JSON" || no "stripped template is strict JSON"
"$PYTHON" "$V" "$SB/hooks.json" >/dev/null 2>&1; expect_exit "lint clean on shipped skill" 0 $?
out="$("$PYTHON" "$V" --json "$SB/hooks.json" 2>/dev/null)"
expect_has "--json envelope schema" '"schema": "claude-mods.claude-code-ops.hooks-lint/v1"' "$out"
expect_has "--json zero errors" '"errors": 0' "$out"

# ── negative: an unknown event must be flagged (exit 10, names the event) ─────
echo "-- negative --"
cat > "$SB/bad.json" <<'EOF'
{
  "hooks": {
    "PreToolUs": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo hi" } ] }
    ]
  }
}
EOF
"$PYTHON" "$V" "$SB/bad.json" >"$SB/neg.out" 2>&1
expect_exit "unknown event -> 10" 10 $?
expect_has "finding names the bad event" "PreToolUs" "$(cat "$SB/neg.out")"

# ── SKILL.md sanity ───────────────────────────────────────────────────────────
echo "-- SKILL.md --"
grep -q '^name: claude-code-ops$' "$SKILL/SKILL.md" && ok "frontmatter name" || no "frontmatter name"
grep -q 'validate-hooks-json.py' "$SKILL/SKILL.md" && ok "verifier cited from SKILL.md" || no "verifier cited from SKILL.md"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
