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
  err="$(node "$M" --runner phpunit --repo "$HERE/fixtures/node-project" --baseline 2>&1 >/dev/null)"; rc=$?
  expect_exit "phpunit with no vendor/bin is a precondition failure" 5 "$rc"
  # Exit 5 alone is not enough: a missing binary also ends as a no-report baseline (exit 5).
  # What the user needs is the actionable cause, before any run is attempted.
  expect_has "missing vendor/bin says to composer install" "composer install" "$err"

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

# -- cost-side scripts (stdlib Python) -----------------------------------------------------
# Each check is named for the bug it blocks; each was watched failing against a broken copy
# of its script before it was kept. Fixtures: tests/fixtures/cost/ (hand-written, minimal).
# A candidate python only counts if it RUNS: on Windows `python3` is often the Store shim.
PY=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys; sys.exit(sys.version_info < (3, 8))" >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
if [[ -z "$PY" ]]; then
  echo "  SKIP  cost-side checks (no working Python 3.8+)"
else
  S="$SKILL/scripts"; C="$HERE/fixtures/cost"
  jget() { "$PY" -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

  echo "-- cost scripts: contract --"
  for s in suite-profile budget-gate ci-audit coverage-overlap run-plan oracle-scan affected; do
    "$PY" -m py_compile "$S/$s.py" 2>/dev/null && ok "py_compile $s.py" || no "py_compile $s.py"
    expect_has "$s --help has Examples" "xamples" "$("$PY" "$S/$s.py" --help 2>/dev/null)"
    "$PY" "$S/$s.py" --bogus >/dev/null 2>&1; expect_exit "$s unknown flag -> 2" 2 $?
  done

  echo "-- suite-profile: time and outcomes are what ran --"
  out="$("$PY" "$S/suite-profile.py" profile "$C/nested.xml" --json 2>/dev/null)"
  [[ "$(jget "d['data']['totals']['time_s']" <<<"$out")" == "4.0" ]] \
    && ok "nested suites: time is the testcases' sum, not the suites' (no double count)" \
    || no "nested suites: time is the testcases' sum, not the suites' (no double count)"
  out="$("$PY" "$S/suite-profile.py" profile "$C/retried.xml" --json 2>/dev/null)"
  [[ "$(jget "d['data']['totals']['flaky'], d['data']['totals']['tests']" <<<"$out")" == "(1, 2)" ]] \
    && ok "a pass-on-retry is counted flaky, and a bare <testsuite> root still parses" \
    || no "a pass-on-retry is counted flaky, and a bare <testsuite> root still parses"
  out="$("$PY" "$S/suite-profile.py" profile "$HERE/fixtures/pest.xml" --json 2>/dev/null)"
  [[ "$(jget "[(f['file'], f['tests']) for f in d['data']['files']]" <<<"$out")" == "[('tests/MoneyTest.php', 3)]" ]] \
    && ok "pest's 'file::test name' attribute groups under one file" \
    || no "pest's 'file::test name' attribute groups under one file"
  out="$("$PY" "$S/suite-profile.py" flakes "$C/runs-a" "$C/runs-b" "$C/runs-c" --json 2>/dev/null)"; rc=$?
  expect_exit "flakes: red in some runs -> exit 10" 10 "$rc"
  [[ "$(jget "[f['id'] for f in d['data']]" <<<"$out")" == "['t::sometimes_red']" ]] \
    && ok "flakes: a test red in EVERY run is a failure, not a flake" \
    || no "flakes: a test red in EVERY run is a failure, not a flake"
  # Seen in a pilot: a Workers pool that failed to start wrote an EMPTY report beside green runs.
  "$PY" "$S/suite-profile.py" flakes "$C/runs-green2" "$C/runs-crashed" >/dev/null 2>&1
  expect_exit "flakes: a run that crashed to an empty report is incomplete (10), never green" 10 $?
  "$PY" "$S/suite-profile.py" profile "$C/missing.xml" >/dev/null 2>&1; expect_exit "missing input -> 3" 3 $?

  echo "-- budget-gate: the ratchet --"
  "$PY" "$S/suite-profile.py" profile "$C/nested.xml" --json > "$SB/base.json" 2>/dev/null
  "$PY" "$S/budget-gate.py" baseline "$SB/base.json" --floor-s 0.5 --max-test-s 2 > "$SB/budget.json" 2>/dev/null
  # Build "after" profiles by editing the baseline profile's numbers (one variable each).
  mkprof() { "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1])); t=d['data']['tests']
exec(sys.argv[2])
d['data']['totals']['time_s']=round(sum(x['time_s'] for x in t),3); d['data']['totals']['tests']=len(t)
json.dump(d,open(sys.argv[3],'w'))" "$SB/base.json" "$1" "$2"; }
  # grandfathered: testRefundIsNegative (2.5 s > 2 s) is on the slow list
  mkprof "t[0]['time_s']=1.8" "$SB/ok.json"
  "$PY" "$S/budget-gate.py" check "$SB/ok.json" --baseline "$SB/budget.json" >/dev/null 2>&1
  expect_exit "growth inside tolerance passes" 0 $?
  mkprof "t[0]['time_s']=1.9; t.append(dict(t[0], id='InvoiceTest::testNewSlowExport', time_s=2.4))" "$SB/slow.json"
  out="$("$PY" "$S/budget-gate.py" check "$SB/slow.json" --baseline "$SB/budget.json" 2>/dev/null)"; rc=$?
  expect_exit "a new test over max-test-s -> 10" 10 "$rc"
  expect_has "  ...reported as B2 for that test" "B2	2.4	2.0	InvoiceTest::testNewSlowExport" "$out"
  mkprof "t[1]['time_s']=4.0" "$SB/slower.json"
  out="$("$PY" "$S/budget-gate.py" check "$SB/slower.json" --baseline "$SB/budget.json" 2>/dev/null)"; rc=$?
  expect_exit "a grandfathered slow test that got slower -> 10" 10 "$rc"
  expect_has "  ...reported as B3" "B3" "$out"
  mkprof "t.pop()" "$SB/subset.json"
  "$PY" "$S/budget-gate.py" check "$SB/subset.json" --baseline "$SB/budget.json" >/dev/null 2>&1
  expect_exit "a subset run's profile is refused, not passed as fast" 4 $?
  "$PY" "$S/budget-gate.py" check "$SB/subset.json" --baseline "$SB/budget.json" --shrink-ok 1 >/dev/null 2>&1
  expect_exit "  ...unless the deletion is declared (prune)" 0 $?
  "$PY" "$S/budget-gate.py" check "$SB/ok.json" --baseline "$SB/nope.json" >/dev/null 2>&1
  expect_exit "missing baseline -> 3" 3 $?

  echo "-- coverage-overlap: candidates, never twice --"
  out="$("$PY" "$S/coverage-overlap.py" "$C/coverage.json" --json 2>/dev/null)"; rc=$?
  expect_exit "candidates found -> 10" 10 "$rc"
  got="$(jget "sorted(r['candidate'].split('::')[1] for r in d['data'])" <<<"$out")"
  [[ "$got" == "['test_total', 'test_total_again', 'test_twin_b']" || "$got" == "['test_total', 'test_total_again', 'test_twin_a']" ]] \
    && ok "subsets are candidates, an identical pair is reported once, partial overlap is not" \
    || no "subsets are candidates, an identical pair is reported once, partial overlap is not (got $got)"

  echo "-- ci-audit: billing and waste --"
  out="$("$PY" "$S/ci-audit.py" cost --from-file "$C/runs.json" --json 2>/dev/null)"
  [[ "$(jget "d['data']['billed_min'], d['data']['cancelled_billed_min'], d['data']['by_os_min']" <<<"$out")" == "(7, 3, {'linux': 5, 'windows': 2})" ]] \
    && ok "each job bills rounded UP to a minute; cancelled runs still bill" \
    || no "each job bills rounded UP to a minute; cancelled runs still bill"
  "$PY" "$S/ci-audit.py" lint "$C/wf/lean.yml" >/dev/null 2>&1; expect_exit "a lean workflow has no findings" 0 $?
  out="$("$PY" "$S/ci-audit.py" lint "$C/wf/wasteful.yml" 2>/dev/null)"; rc=$?
  expect_exit "a wasteful workflow -> 10" 10 "$rc"
  for r in CI1 CI3 CI4; do expect_has "  ...flags $r" "$r" "$out"; done
  # Match the rule and the job, not the path: Git Bash and Python spell drive letters differently.
  ci2="$(grep '^CI2' <<<"$out")"
  expect_has "  ...CI2 names the job without a timeout" "job \`unit\`" "$ci2"
  case "$out" in *"job \`lint\`"*) no "  ...CI2 spares the job that has one";; *) ok "  ...CI2 spares the job that has one";; esac
  # Seen in a pilot: CI1 told a deploy workflow to cancel in progress. A half-cancelled deploy is the bug.
  "$PY" "$S/ci-audit.py" lint "$C/wf/deploy.yml" >/dev/null 2>&1
  expect_exit "a serialised deploy workflow is never told to cancel in progress" 0 $?
  out="$("$PY" "$S/ci-audit.py" lint "$C/wf/deploy-unserialised.yml" 2>/dev/null)"
  expect_has "  ...but a deploy with no concurrency group is told to serialise" "serialise" "$out"
  "$PY" "$S/ci-audit.py" lint "$C/wf/scheduled.yml" >/dev/null 2>&1
  expect_exit "a schedule-only workflow is not told to cancel superseded runs" 0 $?

  echo "-- oracle-scan: tests that copy the code --"
  out="$("$PY" "$S/oracle-scan.py" --repo "$C/oracle" 2>/dev/null)"; rc=$?
  expect_exit "copied logic found -> 10" 10 "$rc"
  expect_has "O1: the expected value recomputed with the source's own formula" "O1	tests/test_pricing.py:6	src/pricing.py:3" "$out"
  expect_has "O2: a test file re-declaring a source function" "O2	tests/test_pricing.py:10	src/pricing.py:6" "$out"
  expect_has "O3: the same source function on both sides of one assertion" "O3	tests/test_pricing.py:19" "$out"
  expect_has "O1: the formula pasted into the assertion itself" "O1	tests/test_pricing.py:23	src/pricing.py:3" "$out"
  case "$out" in *test_pricing_good*) no "clean file stays clean: a literal oracle, an equivalence test, a helper named like a source local";; *) ok "clean file stays clean: a literal oracle, an equivalence test, a helper named like a source local";; esac

  echo "-- affected: run only what changed, fail safe to full --"
  aff() { "$PY" "$S/affected.py" --map "$C/mono/.test-map.json" --root "$C/mono" --files "$@" 2>/dev/null; }
  [[ "$(aff pkgs/billing/src/a.py pkgs/billing/README.md)" == "bash pkgs/billing/tests/run.sh" ]] \
    && ok "a change in one package runs that package's tests only" || no "a change in one package runs that package's tests only"
  [[ -z "$(aff docs/x.md pkgs/search/README.md)" ]] && ok "docs-only changes run nothing (ignore beats a package rule)" \
    || no "docs-only changes run nothing (ignore beats a package rule)"
  [[ "$(aff pkgs/billing/x.py tools/new.py)" == "bash run-all.sh" ]] && ok "a file no rule maps forces the full suite" \
    || no "a file no rule maps forces the full suite"
  # A path a package rule ALSO matches: only the always-full rule can make this a full run.
  [[ "$(aff pkgs/billing/tests/fixtures/rates.json)" == "bash run-all.sh" ]] \
    && ok "an always-full path wins even where a package rule also matches it" \
    || no "an always-full path wins even where a package rule also matches it"
  [[ "$(aff pkgs/gone/x.py)" == "bash run-all.sh" ]] && ok "a deleted package forces the full suite (its importers may break)" \
    || no "a deleted package forces the full suite (its importers may break)"
  "$PY" "$S/affected.py" --map "$C/nope.json" --files a >/dev/null 2>&1; expect_exit "missing map -> 3" 3 $?

  echo "-- run-plan: never asks for the whole machine --"
  # TE_RUNPLAN_FAKE pins the machine: live load would make every number below untestable.
  w() { TE_RUNPLAN_FAKE="$1" "$PY" "$S/run-plan.py" local --per-worker-mb 1024 --json 2>/dev/null | jget "d['data']['workers']"; }
  [[ "$(w cpus=8,busy=0,mem=64000)" == 6 ]] && ok "an idle 8-core machine keeps a quarter of its cores back (6 workers)" \
    || no "an idle 8-core machine keeps a quarter of its cores back (6 workers)"
  [[ "$(w cpus=8,busy=50,mem=64000)" == 3 ]] && ok "current CPU load is subtracted (50% busy -> 3)" \
    || no "current CPU load is subtracted (50% busy -> 3)"
  [[ "$(w cpus=8,busy=0,mem=4096)" == 2 ]] && ok "memory per worker caps the count, after a 2 GiB reserve" \
    || no "memory per worker caps the count, after a 2 GiB reserve"
  # 32 cores at 85%: 3 workers would still fit, so only the busy rule can say offload.
  TE_RUNPLAN_FAKE=cpus=32,busy=85,mem=64000 "$PY" "$S/run-plan.py" local >/dev/null 2>&1
  expect_exit "a machine already over 80% busy says offload (10)" 10 $?
  out="$("$PY" "$S/run-plan.py" stack --repo "$C/repo-py" 2>/dev/null)"
  expect_has "stack: an installed testmon is offered as the changed-only command" "pytest	changed	pytest --testmon" "$out"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
