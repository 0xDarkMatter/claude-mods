#!/usr/bin/env bash
# Self-test for test-engineering - fully offline, deterministic, Linux-safe.
#
# Two scripts ship with the skill, and each check below is named for the bug it blocks:
#   - mutate.mjs: the prove-it-fails / audit harness. Parsers run against REAL recorded
#     runner reports (tests/parsers.test.mjs); end-to-end checks run the `command` runner
#     on a throwaway COPY of tests/fixtures/node-project, never on the fixture in place.
#   - coverage-check.sh: report-only by default since the test-engineering consolidation
#     (decision Q7); --threshold keeps the old gate. Uses the CM_COVERAGE_OVERRIDE seam, so
#     no real pytest ever runs.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/coverage-check.sh"
M="$SKILL/scripts/mutate.mjs"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== test-engineering self-test ==="

# -- coverage-check.sh ------------------------------------------------------------------
echo "-- coverage-check: contract --"
bash -n "$V" 2>/dev/null && ok "bash -n coverage-check.sh" || no "bash -n coverage-check.sh"
bash "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
out="$(bash "$V" --help 2>/dev/null)"
expect_has "--help has Examples" "xamples" "$out"
expect_has "--help says report-only is the default" "report only" "$out"
expect_has "--help names the test seam" "CM_COVERAGE_OVERRIDE" "$out"
bash "$V" --bogus            >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?
bash "$V" --threshold        >/dev/null 2>&1; expect_exit "--threshold needs value -> 2" 2 $?
bash "$V" --threshold notnum >/dev/null 2>&1; expect_exit "--threshold non-numeric -> 2" 2 $?
CM_COVERAGE_OVERRIDE=bogus bash "$V" >/dev/null 2>&1; expect_exit "bad override -> 2" 2 $?

echo "-- coverage-check: low coverage never fails a build unless a threshold is set --"
out="$(CM_COVERAGE_OVERRIDE=12 bash "$V" 2>/dev/null)"; rc=$?
expect_exit "12% with no threshold -> report, exit 0" 0 "$rc"
expect_has "default verdict is report" "report" "$out"
CM_COVERAGE_OVERRIDE=90 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "90>=80 -> pass 0" 0 $?
CM_COVERAGE_OVERRIDE=80 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "80>=80 boundary -> pass 0" 0 $?
CM_COVERAGE_OVERRIDE=79 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "79<80 -> below 1" 1 $?
CM_COVERAGE_OVERRIDE=99.4 bash "$V" --threshold 99.5 >/dev/null 2>&1; expect_exit "99.4<99.5 float -> below 1" 1 $?
out="$(CM_COVERAGE_OVERRIDE=72 bash "$V" --threshold 80 2>/dev/null)"
case "$out" in *$'\n'*) no "stdout is a single verdict line";; *) ok "stdout is a single verdict line";; esac
case "$out" in *"==="*) no "banner leaked onto stdout";; *) ok "no banner on stdout";; esac

# -- mutate.mjs -------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP  mutate.mjs checks (node not on PATH)"
else
  echo "-- mutate.mjs: contract --"
  node --check "$M" 2>/dev/null && ok "node --check mutate.mjs" || no "node --check mutate.mjs"
  node "$M" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
  expect_has "--help has Examples" "xamples" "$(node "$M" --help 2>/dev/null)"
  node "$M" --bogus >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?
  node "$M" --runner nope --baseline >/dev/null 2>&1; expect_exit "unknown runner -> 2" 2 $?

  echo "-- mutate.mjs: parsers on recorded runner reports --"
  node "$HERE/parsers.test.mjs"; expect_exit "parser checks" 0 $?

  # Fresh copy per scenario: the harness edits files, and the fixture in the repo must not move.
  fresh() { rm -rf "$SB/p"; cp -R "$HERE/fixtures/node-project" "$SB/p"; }
  FX="$HERE/fixtures"
  RUN=(node "$M" --runner command --repo "$SB/p")

  echo "-- mutate.mjs: prove-it-fails --"
  fresh
  out="$("${RUN[@]}" --catalogue "$FX/catalogue-boundary.json" --prove limit -- node test/run.mjs 2>/dev/null)"; rc=$?
  expect_exit "a test that pins the boundary is proved" 0 "$rc"
  expect_has "evidence row says proved" '"proved": true' "$out"
  fresh
  "${RUN[@]}" --catalogue "$FX/catalogue-fee.json" --prove fee -- node test/run.mjs >/dev/null 2>&1
  expect_exit "a mutant no test catches is NOT proved" 10 $?

  echo "-- mutate.mjs: never leaves the developer's tree changed --"
  fresh
  # CRLF copy: the restore must be byte-identical, line endings included.
  node -e 'const f=process.argv[1],fs=require("fs");fs.writeFileSync(f,fs.readFileSync(f,"utf8").replace(/\n/g,"\r\n"))' "$SB/p/src/limit.mjs"
  cp "$SB/p/src/limit.mjs" "$SB/before.mjs"
  "${RUN[@]}" --catalogue "$FX/catalogue-boundary.json" --prove limit -- node test/run.mjs >/dev/null 2>&1
  expect_exit "prove still works on a CRLF file" 0 $?
  cmp -s "$SB/before.mjs" "$SB/p/src/limit.mjs" && ok "mutated file restored byte-identical (CRLF kept)" || no "mutated file restored byte-identical (CRLF kept)"

  echo "-- mutate.mjs: refuses evidence it cannot trust --"
  fresh
  "${RUN[@]}" --catalogue "$FX/catalogue-ambiguous.json" --dry-run >/dev/null 2>&1
  expect_exit "an anchor that is not unique is refused" 4 $?
  fresh
  "${RUN[@]}" --catalogue "$FX/catalogue-boundary.json" --prove limit -- node -e "process.exit(1)" >/dev/null 2>&1
  expect_exit "a red baseline blocks mutation" 5 $?
  fresh
  "${RUN[@]}" --baseline --typecheck "node -e process.exit(1)" -- node test/run.mjs >/dev/null 2>&1
  expect_exit "a typecheck already red before mutation blocks the run" 5 $?

  echo "-- mutate.mjs: credentials never reach the code under test --"
  fresh
  probe='process.exit(process.env.FIXTURE_API_TOKEN ? 1 : 0)'
  FIXTURE_API_TOKEN=live "${RUN[@]}" --baseline -- node -e "$probe" >/dev/null 2>&1
  expect_exit "a secret-looking env var is stripped from test runs" 0 $?
  FIXTURE_API_TOKEN=live "${RUN[@]}" --baseline --keep-env FIXTURE_API_TOKEN -- node -e "$probe" >/dev/null 2>&1
  expect_exit "--keep-env passes it through on request" 5 $?

  echo "-- mutate.mjs: audit batch --"
  fresh
  out="$("${RUN[@]}" --catalogue "$FX/catalogue-batch.json" --out "$SB/rows.jsonl" -- node test/run.mjs 2>/dev/null)"; rc=$?
  expect_exit "batch with green null controls exits 0" 0 "$rc"
  expect_has "batch counts the kill" '"killed": 1' "$out"
  expect_has "batch counts the survivor" '"survived": 1' "$out"
  expect_has "batch is trusted when both null controls agree" '"trusted": true' "$out"
  [[ "$(grep -c . "$SB/rows.jsonl")" == "2" ]] && ok "--out appends one row per mutant" || no "--out appends one row per mutant"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
