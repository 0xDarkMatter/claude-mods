#!/usr/bin/env bash
# claude-mods :: tests/hooks.sh - contract tests for the opt-in hooks
#
# WHY THIS EXISTS
#   The opt-in hooks (dangerous-cmd-warn, pre-commit-lint, post-edit-format) had
#   never been run against the input Claude Code actually sends - JSON on stdin -
#   and four defects survived unnoticed: post-edit-format read only $1 and
#   silently formatted nothing; pre-commit-lint exited 1 (non-blocking) so the
#   commit went ahead; dangerous-cmd-warn wrote its reason to stdout (the model
#   never sees it) and blocked `uv venv`, `cat .env.example` and
#   `--force-with-lease`, while its UPDATE-without-WHERE guard never matched.
#   Each assertion below pins one of those contracts.
#
# CONTRACT (Claude Code hooks): exit 0 = allow; exit 2 = block, and STDERR is fed
#   back to the model. Any other exit code is a non-blocking error.
#
# Usage:  bash tests/hooks.sh
# Exit :  0 all pass (tool-dependent cases SKIP when the tool is absent), 1 failure
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
# HOOKS_DIR lets the suite run against another copy of the hooks - e.g. the
# pre-fix versions, to prove every assertion here can actually fail.
H="${HOOKS_DIR:-$root/hooks}"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf "  FAIL  %s\n" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf "  SKIP  %s\n" "$1"; }

echo "=== claude-mods :: hook contract tests ==="
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  all - jq is required (the hooks themselves parse stdin with jq)"
  exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cmd_json()  { jq -cn --arg c "$1" '{tool_input:{command:$c}}'; }
file_json() { jq -cn --arg p "$1" '{tool_input:{file_path:$p}}'; }

# --- dangerous-cmd-warn -------------------------------------------------------
echo "-- dangerous-cmd-warn --"
dcw() {   # $1 expected exit, $2 command
  cmd_json "$2" | bash "$H/dangerous-cmd-warn.sh" >"$tmp/out" 2>"$tmp/err"; local rc=$?
  if [ "$rc" -ne "$1" ]; then bad "exit $1 for: $2 (got $rc)"; return; fi
  if [ "$1" -eq 2 ] && ! grep -q 'Risk:' "$tmp/err"; then
    bad "reason on stderr for: $2"; return
  fi
  ok "exit $1 for: $2"
}
for c in 'git push --force origin main' 'git push -f origin main' 'rm -rf /' \
         'sqlite3 app.db "DROP TABLE users;"' 'psql -c "UPDATE users SET admin=true"' \
         'printenv' 'env' 'ls && env' 'cat .env' 'cat config/.env.local'; do
  dcw 2 "$c"
done
for c in 'git status' 'git push origin main' 'git push --force-with-lease origin feat' \
         'uv venv .venv' 'python -m venv env' 'printenv HOME' 'env FOO=1 node app.js' \
         'psql -c "UPDATE users SET a=1 WHERE id=2"' 'cat .env.example' 'cat README.md'; do
  dcw 0 "$c"
done

# --- post-edit-format ---------------------------------------------------------
echo "-- post-edit-format --"
bash "$H/post-edit-format.sh" </dev/null >/dev/null 2>&1 \
  && ok "no input -> exit 0" || bad "no input -> exit 0"
file_json "$tmp/does-not-exist.py" | bash "$H/post-edit-format.sh" >/dev/null 2>&1 \
  && ok "missing file -> exit 0" || bad "missing file -> exit 0"
if command -v ruff >/dev/null 2>&1; then
  printf 'x=1\n' > "$tmp/fmt.py"
  out="$(file_json "$tmp/fmt.py" | bash "$H/post-edit-format.sh" 2>/dev/null)"
  if [ "$(cat "$tmp/fmt.py")" = "x = 1" ] && [[ "$out" == *"Formatted: fmt.py"* ]]; then
    ok "formats the file named in stdin JSON (ruff)"
  else
    bad "formats the file named in stdin JSON (ruff) - got '$(cat "$tmp/fmt.py")' / '$out'"
  fi
else
  skip "formats the file named in stdin JSON (ruff not installed)"
fi

# --- pre-commit-lint ----------------------------------------------------------
echo "-- pre-commit-lint --"
cmd_json 'git status' | bash "$H/pre-commit-lint.sh" >/dev/null 2>&1 \
  && ok "non-commit command -> exit 0" || bad "non-commit command -> exit 0"
if command -v ruff >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q
  git -C "$repo" config core.autocrlf false
  printf 'import os\n' > "$repo/bad.py"; git -C "$repo" add bad.py
  cmd_json 'git commit -m wip' | env -C "$repo" bash "$H/pre-commit-lint.sh" >"$tmp/out" 2>"$tmp/err"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q 'LINT FAILED' "$tmp/err" && [ ! -s "$tmp/out" ]; then
    ok "lint failure blocks the commit (exit 2, reason on stderr)"
  else
    bad "lint failure blocks the commit - got exit $rc, stdout $(wc -c < "$tmp/out") bytes"
  fi
  git -C "$repo" rm -q --cached bad.py
  printf 'print("ok")\n' > "$repo/good.py"; git -C "$repo" add good.py
  cmd_json 'git commit -m ok' | env -C "$repo" bash "$H/pre-commit-lint.sh" >/dev/null 2>&1 \
    && ok "clean staged files -> exit 0" || bad "clean staged files -> exit 0"
else
  skip "lint failure blocks the commit (ruff or git not installed)"
fi

echo
echo "=== $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
