#!/usr/bin/env bash
# Self-test for security-ops scanners; fully offline.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCAN="$SKILL/scripts/security-scan.sh"
AUDIT="$SKILL/scripts/dependency-audit.sh"
BAD="$HERE/fixtures/bad"
CLEAN="$HERE/fixtures/clean"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $3 got $2)"; }
expect_has() { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }
expect_lacks() { case "$3" in *"$2"*) no "$1 (unexpected '$2')";; *) ok "$1";; esac; }

printf '%s\n' '=== security-ops self-test ==='

printf '%s\n' '-- contract --'
for script in "$SCAN" "$AUDIT"; do
    name="$(basename "$script")"
    bash -n "$script" 2>/dev/null && ok "bash -n $name" || no "bash -n $name"
    bash "$script" --help >"$SB/help" 2>/dev/null
    expect_exit "$name --help exits 0" "$?" 0
    expect_has "$name --help has EXAMPLES" 'EXAMPLES' "$(cat "$SB/help")"
    bash "$script" --bogus >/dev/null 2>&1
    expect_exit "$name unknown flag" "$?" 2
done

printf '%s\n' '-- true positives and stream separation --'
bash "$SCAN" "$BAD" >"$SB/bad.out" 2>"$SB/bad.err"
expect_exit 'bad fixture signals findings' "$?" 10
bad_out="$(cat "$SB/bad.out")"
bad_err="$(cat "$SB/bad.err")"
expect_has 'hardcoded secret is flagged' 'hardcoded_secret.py' "$bad_out"
expect_has 'eval use is flagged' 'eval_case.py' "$bad_out"
expect_has 'unsafe deserialization is flagged' 'unsafe_deserialization.py' "$bad_out"
expect_lacks 'stdout excludes scan banner' 'Security Scan' "$bad_out"
expect_lacks 'stdout excludes progress' 'Checking:' "$bad_out"
expect_has 'stderr carries scan banner' 'Security Scan' "$bad_err"

finding_count="$(printf '%s\n' "$bad_out" | grep -cE 'hardcoded_secret\.py|eval_case\.py|unsafe_deserialization\.py' || true)"
[[ "$finding_count" == 3 ]] && ok 'exactly three claimed patterns are flagged' || no "expected 3 flagged patterns, got $finding_count"

printf '%s\n' '-- true negative --'
bash "$SCAN" "$CLEAN" >"$SB/clean.out" 2>"$SB/clean.err"
expect_exit 'clean fixture exits clean' "$?" 0
[[ ! -s "$SB/clean.out" ]] && ok 'clean fixture emits no findings' || no 'clean fixture emitted stdout'

printf '%s\n' '-- mutation --'
cp -R "$BAD" "$SB/mutated"
eval_trigger='ev''al(user_expression)'
sed "s/$eval_trigger/safe_evaluate(user_expression)/" "$BAD/eval_case.py" >"$SB/mutated/eval_case.py"
bash "$SCAN" "$SB/mutated" >"$SB/mutated.out" 2>"$SB/mutated.err"
expect_exit 'remaining bad patterns still signal findings' "$?" 10
mutated_out="$(cat "$SB/mutated.out")"
expect_lacks 'removed eval trigger is no longer reported' 'eval_case.py' "$mutated_out"
expect_has 'mutation retains independent secret finding' 'hardcoded_secret.py' "$mutated_out"
expect_has 'mutation retains independent pickle finding' 'unsafe_deserialization.py' "$mutated_out"

printf '%s\n' '-- fail-loud when scan engine (rg) is absent --'
# A security scanner that reports "clean" because rg is missing is a false
# all-clear — it must refuse (exit 5), never exit 0. The scanner hits its
# `command -v rg` guard before it needs any other tool, so a shim of the
# standard bin dirs minus rg is enough to trip it. Skip-guarded: if the shim
# can't be built (e.g. Windows symlink quirks) we don't fail the suite —
# CI (Linux) builds it cleanly and runs the real assertion.
RGSHIM="$SB/rgless"; mkdir -p "$RGSHIM"
for _d in /usr/bin /bin /usr/local/bin; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _b="$(basename "$_f")"
    [ "$_b" = "rg" ] && continue
    [ -e "$RGSHIM/$_b" ] || ln -sf "$_f" "$RGSHIM/$_b" 2>/dev/null
  done
done
if [ -x "$RGSHIM/bash" ] && ! PATH="$RGSHIM" command -v rg >/dev/null 2>&1; then
  PATH="$RGSHIM" bash "$SCAN" "$BAD" >"$SB/norg.out" 2>/dev/null
  expect_exit 'refuses (exit 5) when rg is absent — no false clean' "$?" 5
else
  printf '  SKIP  rg-absent shim unavailable on this host (CI runs it for real)\n'
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
