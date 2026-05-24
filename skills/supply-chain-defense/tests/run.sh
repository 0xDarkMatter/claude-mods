#!/usr/bin/env bash
# Self-test for supply-chain-defense scripts + hook.
#
# Offline-deterministic (no network). Builds throwaway fixtures, asserts the
# documented exit codes and key output of each script and the pre-install-scan
# hook, then cleans up. Resolves paths relative to itself so it works both in the
# repo and once installed to ~/.claude/skills/supply-chain-defense/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures
#
# Network-dependent checks (preinstall-check registry lookups) are intentionally
# omitted here — run that script manually against live registries.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
HOOK="$SKILL/../../hooks/pre-install-scan.sh"   # repo root/hooks or ~/.claude/hooks
# Pick a python that actually executes — skips the Windows Store `python3` stub
# (an app-execution alias that exits non-zero non-interactively).
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== supply-chain-defense self-test ==="

# ── exposure-check.py ──────────────────────────────────────────────────────
echo "-- exposure-check.py --"
"$PYTHON" "$SCRIPTS/exposure-check.py" --help >/dev/null 2>&1; expect_exit "--help" 0 $?

mkdir -p "$SB/exposed" "$SB/clean"
printf '{"name":"a","lockfileVersion":3,"packages":{"node_modules/axios":{"version":"1.14.1"}}}' > "$SB/exposed/package-lock.json"
printf '{"name":"b","lockfileVersion":3,"packages":{"node_modules/axios":{"version":"1.7.9"}}}'  > "$SB/clean/package-lock.json"

out="$("$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/exposed" --findings-only 2>&1)"; rc=$?
expect_exit "exposed tree -> 10" 10 "$rc"
expect_has  "exposed tree names axios" "axios@1.14.1" "$out"

"$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/clean" --findings-only >/dev/null 2>&1
expect_exit "clean tree -> 0" 0 $?

"$PYTHON" "$SCRIPTS/exposure-check.py" --catalog "$SB/nope.json" --root "$SB/clean" >/dev/null 2>&1
expect_exit "missing catalog -> 3" 3 $?

# ── integrity-audit.sh ─────────────────────────────────────────────────────
echo "-- integrity-audit.sh --"
bash "$SCRIPTS/integrity-audit.sh" --help >/dev/null 2>&1; expect_exit "--help" 0 $?

mkdir -p "$SB/proj/.github/workflows"
cat > "$SB/proj/.github/workflows/x.yml" <<'YML'
on:
  pull_request_target:
permissions:
  id-token: write
jobs: { b: { runs-on: ubuntu-latest, steps: [ { run: "npm publish" } ] } }
YML
out="$(bash "$SCRIPTS/integrity-audit.sh" "$SB/proj" 2>&1)"; rc=$?
expect_exit "planted OIDC workflow -> 10" 10 "$rc"
expect_has  "flags id-token workflow" "id-token" "$out"

# ── preinstall-check.sh (offline bits only) ────────────────────────────────
echo "-- preinstall-check.sh --"
bash "$SCRIPTS/preinstall-check.sh" --help >/dev/null 2>&1; expect_exit "--help" 0 $?
bash "$SCRIPTS/preinstall-check.sh" --bogus >/dev/null 2>&1; expect_exit "bad flag -> 2" 2 $?
bash "$SCRIPTS/preinstall-check.sh" >/dev/null 2>&1;        expect_exit "no args -> 2" 2 $?

# ── pre-install-scan.sh hook (both input modes) ────────────────────────────
echo "-- pre-install-scan.sh hook --"
if [[ -f "$HOOK" ]]; then
  # legacy $1 arg mode
  out="$(bash "$HOOK" "npm install lodash" 2>&1)"; rc=$?
  expect_exit "arg: npm install advisory -> 0" 0 "$rc"
  expect_has  "arg: advisory text" "SUPPLY CHAIN" "$out"
  # modern stdin-JSON mode
  out="$(printf '{"tool_input":{"command":"pip install requests"}}' | bash "$HOOK" 2>&1)"; rc=$?
  expect_exit "stdin: pip install advisory -> 0" 0 "$rc"
  expect_has  "stdin: advisory text" "SUPPLY CHAIN" "$out"
  # already-wrapped is silent
  out="$(printf '{"tool_input":{"command":"socket npm install x"}}' | bash "$HOOK" 2>&1)"; rc=$?
  expect_exit "stdin: socket-wrapped silent -> 0" 0 "$rc"
  [[ -z "$out" ]] && ok "stdin: socket-wrapped produces no output" || no "stdin: socket-wrapped should be silent"
  # hard gate
  printf '{"tool_input":{"command":"npm install evil"}}' | SUPPLY_CHAIN_BLOCK=1 bash "$HOOK" >/dev/null 2>&1
  expect_exit "block mode -> 2" 2 $?
else
  echo "  SKIP  hook not found at $HOOK"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
