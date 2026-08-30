#!/usr/bin/env bash
# Self-test for evals-ops scripts.
#
# Offline and deterministic: builds throwaway JSONL fixtures with KNOWN correct
# answers (kappa computed by hand below), asserts the documented exit codes and
# the actual numbers, then cleans up. Resolves paths relative to itself so it
# works in the repo and once installed to ~/.claude/skills/evals-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
CAL="$SCRIPTS/judge-calibration.py"
AUD="$SCRIPTS/goldenset-audit.py"
BAS="$SCRIPTS/eval-baseline.py"

# Probe python by EXECUTING it. `command -v python3` finds the Windows Store
# app-execution stub, which exists on PATH but exits 49 non-interactively.
PYTHON=""
for c in python3 python py; do
    if "$c" -c 'import sys' >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
if [ -z "$PYTHON" ]; then
    echo "evals-ops tests: no working python3 found - skipping" >&2
    exit 0
fi

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok()  { echo "  ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

# exit_is <want> <label> -- <command...>
exit_is() {
    local want="$1" label="$2"; shift 3
    "$@" >/dev/null 2>&1; local got=$?
    if [ "$got" -eq "$want" ]; then ok "$label (exit $got)"; else bad "$label (want $want, got $got)"; fi
}

# json_eq <jq-ish python path> <expected> <label> -- <command...>
# Reads stdout as JSON and compares a dotted path. Uses python, not jq, so the
# suite has no dependency beyond the interpreter it already requires.
json_eq() {
    local path="$1" want="$2" label="$3"; shift 4
    local out got
    out="$("$@" 2>/dev/null)"
    got="$(printf '%s' "$out" | "$PYTHON" -c '
import json, sys
doc = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    doc = doc[int(part)] if part.isdigit() else doc[part]
print(doc)
' "$path" 2>/dev/null)"
    if [ "$got" = "$want" ]; then ok "$label ($path = $got)"; else bad "$label ($path: want $want, got '$got')"; fi
}

# emits <pattern> <label> -- <command...>
# Capture stdout into a variable BEFORE grepping. Piping the script straight into
# grep would let `set -o pipefail` surface the script's own domain exit code (10)
# as the `if` condition, failing the assertion for the wrong reason.
emits() {
    local pattern="$1" label="$2"; shift 3
    local out
    out="$("$@" 2>/dev/null)"
    if printf '%s' "$out" | grep -q -- "$pattern"; then ok "$label"; else bad "$label (no '$pattern' in output)"; fi
}

echo "== evals-ops self-test ($PYTHON)"

# --- protocol surface -------------------------------------------------------
exit_is 0 "judge-calibration --help"  -- "$PYTHON" "$CAL" --help
exit_is 0 "goldenset-audit --help"    -- "$PYTHON" "$AUD" --help
exit_is 0 "eval-baseline --help"      -- "$PYTHON" "$BAS" --help
exit_is 2 "judge-calibration no args" -- "$PYTHON" "$CAL"
exit_is 2 "goldenset-audit no args"   -- "$PYTHON" "$AUD"
exit_is 2 "eval-baseline no args"     -- "$PYTHON" "$BAS"
exit_is 2 "judge-calibration rejects out-of-range --min-kappa" \
    -- "$PYTHON" "$CAL" /dev/null --min-kappa 5
exit_is 3 "judge-calibration missing file"  -- "$PYTHON" "$CAL" "$SB/nope.jsonl"
exit_is 3 "goldenset-audit missing file"    -- "$PYTHON" "$AUD" "$SB/nope.jsonl"

printf 'not json at all\n' > "$SB/bad.jsonl"
exit_is 4 "judge-calibration malformed JSONL" -- "$PYTHON" "$CAL" "$SB/bad.jsonl"
exit_is 4 "goldenset-audit malformed JSONL"   -- "$PYTHON" "$AUD" "$SB/bad.jsonl"

: > "$SB/empty.jsonl"
exit_is 4 "goldenset-audit empty set" -- "$PYTHON" "$AUD" "$SB/empty.jsonl"

# --- judge-calibration: arithmetic --------------------------------------------
# Perfect agreement on a balanced set: observed 1.0, expected 0.5, kappa = 1.0.
{
  for i in 1 2 3 4 5; do echo "{\"id\":\"p$i\",\"human\":\"pass\",\"judge\":\"pass\"}"; done
  for i in 1 2 3 4 5; do echo "{\"id\":\"f$i\",\"human\":\"fail\",\"judge\":\"fail\"}"; done
} > "$SB/perfect.jsonl"
json_eq "data.kappa" "1.0" "kappa = 1.0 on perfect balanced agreement" \
    -- "$PYTHON" "$CAL" "$SB/perfect.jsonl" --json
exit_is 0 "perfect agreement is calibrated" -- "$PYTHON" "$CAL" "$SB/perfect.jsonl"

# Chance-level agreement. human 5 pass / 5 fail; judge 4 pass / 6 fail; 5 agree.
# observed 0.5; expected (0.5*0.4)+(0.5*0.6) = 0.5  ->  kappa exactly 0.0.
{
  echo '{"id":"a1","human":"pass","judge":"pass"}'
  echo '{"id":"a2","human":"pass","judge":"pass"}'
  echo '{"id":"a3","human":"pass","judge":"fail"}'
  echo '{"id":"a4","human":"pass","judge":"fail"}'
  echo '{"id":"a5","human":"pass","judge":"fail"}'
  echo '{"id":"b1","human":"fail","judge":"fail"}'
  echo '{"id":"b2","human":"fail","judge":"fail"}'
  echo '{"id":"b3","human":"fail","judge":"fail"}'
  echo '{"id":"b4","human":"fail","judge":"pass"}'
  echo '{"id":"b5","human":"fail","judge":"pass"}'
} > "$SB/chance.jsonl"
json_eq "data.kappa" "0.0" "chance-level agreement scores kappa 0.0" \
    -- "$PYTHON" "$CAL" "$SB/chance.jsonl" --json
json_eq "data.raw_agreement" "0.5" "chance set raw agreement is 0.5" \
    -- "$PYTHON" "$CAL" "$SB/chance.jsonl" --json
exit_is 10 "under-calibrated set exits 10" -- "$PYTHON" "$CAL" "$SB/chance.jsonl"

# A genuinely moderate judge: 5/5 balanced both sides, 8 of 10 agree.
# observed 0.8; expected 0.5  ->  kappa exactly 0.6, the gate boundary.
{
  for i in 1 2 3 4; do echo "{\"id\":\"m$i\",\"human\":\"pass\",\"judge\":\"pass\"}"; done
  echo '{"id":"m5","human":"pass","judge":"fail"}'
  for i in 6 7 8 9; do echo "{\"id\":\"m$i\",\"human\":\"fail\",\"judge\":\"fail\"}"; done
  echo '{"id":"m10","human":"fail","judge":"pass"}'
} > "$SB/moderate.jsonl"
json_eq "data.kappa" "0.6" "moderate judge scores kappa 0.6" \
    -- "$PYTHON" "$CAL" "$SB/moderate.jsonl" --json
json_eq "data.band" "substantial" "kappa 0.6 lands in the substantial band" \
    -- "$PYTHON" "$CAL" "$SB/moderate.jsonl" --json

# THE point of using kappa at all: on an imbalanced set a judge that answers
# "pass" unconditionally gets 90% RAW agreement and kappa 0.0. If these two ever
# report the same number, the chance correction has been broken.
{
  for i in $(seq 1 9); do echo "{\"id\":\"y$i\",\"human\":\"pass\",\"judge\":\"pass\"}"; done
  echo '{"id":"n1","human":"fail","judge":"pass"}'
} > "$SB/imbalanced.jsonl"
json_eq "data.raw_agreement" "0.9" "imbalanced set: raw agreement flatters at 0.9" \
    -- "$PYTHON" "$CAL" "$SB/imbalanced.jsonl" --json
json_eq "data.kappa" "0.0" "imbalanced set: kappa correctly reports 0.0" \
    -- "$PYTHON" "$CAL" "$SB/imbalanced.jsonl" --json
exit_is 10 "constant judge is not calibrated" -- "$PYTHON" "$CAL" "$SB/imbalanced.jsonl"

# Degenerate case: both raters used one identical label, so chance agreement is
# 1.0 and kappa is 0/0. Must report null and say so, not divide by zero.
{
  for i in 1 2 3; do echo "{\"id\":\"s$i\",\"human\":\"pass\",\"judge\":\"pass\"}"; done
} > "$SB/single.jsonl"
json_eq "data.kappa" "None" "single-label sample reports kappa as null" \
    -- "$PYTHON" "$CAL" "$SB/single.jsonl" --json
json_eq "data.band" "undefined" "single-label sample is banded 'undefined'" \
    -- "$PYTHON" "$CAL" "$SB/single.jsonl" --json
exit_is 10 "undefined kappa is never treated as calibrated" -- "$PYTHON" "$CAL" "$SB/single.jsonl"

# Label normalisation: true/false, 1/0 and "PASS" must compare like their peers.
{
  echo '{"id":"n1","human":true,"judge":"PASS"}'
  echo '{"id":"n2","human":true,"judge":"pass"}'
  echo '{"id":"n3","human":false,"judge":"Fail"}'
  echo '{"id":"n4","human":false,"judge":"fail"}'
} > "$SB/norm.jsonl"
json_eq "data.kappa" "1.0" "boolean and cased labels normalise to agreement" \
    -- "$PYTHON" "$CAL" "$SB/norm.jsonl" --json

# --min-kappa is the gate. moderate.jsonl scores exactly 0.6.
exit_is 0  "--min-kappa 0.6 accepts kappa 0.6 (inclusive)" -- "$PYTHON" "$CAL" "$SB/moderate.jsonl" --min-kappa 0.6
exit_is 0  "--min-kappa 0.5 accepts kappa 0.6"             -- "$PYTHON" "$CAL" "$SB/moderate.jsonl" --min-kappa 0.5
exit_is 10 "--min-kappa 0.8 rejects kappa 0.6"             -- "$PYTHON" "$CAL" "$SB/moderate.jsonl" --min-kappa 0.8

# Disagreements are enumerated so a human can go look at them.
json_eq "meta.count" "10" "report counts every case" \
    -- "$PYTHON" "$CAL" "$SB/chance.jsonl" --json
json_eq "data.disagreements.0.id" "a3" "first disagreement is reported by id" \
    -- "$PYTHON" "$CAL" "$SB/chance.jsonl" --json

# Confusion direction matters more than the headline: a judge that only ever
# under-passes is safe to gate on. Recall must be per-human-class, not global.
json_eq "data.per_class.fail.recall" "0.0" "per-class recall exposes a judge that never says fail" \
    -- "$PYTHON" "$CAL" "$SB/imbalanced.jsonl" --json
json_eq "data.per_class.pass.recall" "1.0" "per-class recall is 1.0 for the class it always picks" \
    -- "$PYTHON" "$CAL" "$SB/imbalanced.jsonl" --json

# Verbosity probe: judge score rises monotonically with length while the human
# scored every case identically -- that is the bias, and it must be detected.
{
  echo '{"id":"v1","human":1,"judge":1,"length":10}'
  echo '{"id":"v2","human":1,"judge":2,"length":100}'
  echo '{"id":"v3","human":1,"judge":3,"length":200}'
  echo '{"id":"v4","human":1,"judge":4,"length":300}'
  echo '{"id":"v5","human":1,"judge":5,"length":400}'
} > "$SB/verbose.jsonl"
json_eq "data.probes.verbosity_correlation" "0.9998" "verbosity probe detects length correlation" \
    -- "$PYTHON" "$CAL" "$SB/verbose.jsonl" --json

# stdin path
if [ "$("$PYTHON" "$CAL" - --json < "$SB/perfect.jsonl" 2>/dev/null | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["data"]["n"])' 2>/dev/null)" = "10" ]; then
    ok "reads JSONL from stdin"
else
    bad "reads JSONL from stdin"
fi

# stdout must stay parseable JSON under --json even when the script exits 10 and
# warnings are firing on stderr. Capture first -- pipefail would mask this.
_out="$("$PYTHON" "$CAL" "$SB/verbose.jsonl" --json 2>/dev/null)"
if printf '%s' "$_out" | "$PYTHON" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    ok "stdout stays pure JSON on a nonzero exit"
else
    bad "stdout stays pure JSON on a nonzero exit"
fi

# ...and the human report must NOT be JSON, so the two modes cannot be confused.
_out="$("$PYTHON" "$CAL" "$SB/moderate.jsonl" 2>/dev/null)"
case "$_out" in
    *"cohen kappa"*) ok "human mode prints a readable report" ;;
    *) bad "human mode prints a readable report" ;;
esac

# --- goldenset-audit --------------------------------------------------------
mk_case() { # id bucket
    printf '{"id":"%s","bucket":"%s","added":"2026-01-0%s","why":"case %s",' "$1" "$2" "$((RANDOM % 9 + 1))" "$1"
    printf '"input":{"q":"unique question about %s here"},"expected":{"a":"%s"}}\n' "$1" "$1"
}
{
  for i in $(seq 1 12); do mk_case "prod-$i" production; done
  for i in $(seq 1 6);  do mk_case "replay-$i" replay; done
  for i in $(seq 1 5);  do mk_case "adv-$i" adversarial; done
  for i in $(seq 1 4);  do mk_case "edge-$i" edge; done
} > "$SB/healthy.jsonl"
exit_is 0 "healthy balanced set audits clean" -- "$PYTHON" "$AUD" "$SB/healthy.jsonl"
json_eq "data.stats.cases" "27" "case count is reported" -- "$PYTHON" "$AUD" "$SB/healthy.jsonl" --json

# Duplicate id + identical case content are both errors (exit 10).
{ cat "$SB/healthy.jsonl"; mk_case "prod-1" production; } > "$SB/dupid.jsonl"
exit_is 10 "duplicate id is a finding" -- "$PYTHON" "$AUD" "$SB/dupid.jsonl"
emits "DUPLICATE_ID" "duplicate id reports DUPLICATE_ID" -- "$PYTHON" "$AUD" "$SB/dupid.jsonl" --json

# A case with neither expected nor criteria is ungradeable.
{ cat "$SB/healthy.jsonl"; echo '{"id":"x1","bucket":"edge","added":"2026-02-01","why":"w","input":{"q":"z"}}'; } > "$SB/noexp.jsonl"
emits "NO_EXPECTATION" "ungradeable case reports NO_EXPECTATION" -- "$PYTHON" "$AUD" "$SB/noexp.jsonl" --json
exit_is 10 "ungradeable case is an error" -- "$PYTHON" "$AUD" "$SB/noexp.jsonl"

# Bucket skew: 25 production, 1 of everything else -> BUCKET_HEAVY + BUCKET_THIN.
{
  for i in $(seq 1 25); do mk_case "p-$i" production; done
  mk_case "r-1" replay; mk_case "a-1" adversarial; mk_case "e-1" edge
} > "$SB/skew.jsonl"
emits "BUCKET_HEAVY" "production-heavy set reports BUCKET_HEAVY" -- "$PYTHON" "$AUD" "$SB/skew.jsonl" --json
emits "BUCKET_THIN" "starved buckets report BUCKET_THIN"      -- "$PYTHON" "$AUD" "$SB/skew.jsonl" --json
# Balance findings are warnings, so the default --fail-on error must NOT trip.
exit_is 0  "bucket skew is advisory under --fail-on error" -- "$PYTHON" "$AUD" "$SB/skew.jsonl"
exit_is 10 "bucket skew trips --fail-on warn"              -- "$PYTHON" "$AUD" "$SB/skew.jsonl" --fail-on warn

# Near-duplicate detection, and the --max-pairs escape hatch.
{
  mk_case "u-1" production
  echo '{"id":"d-1","bucket":"edge","added":"2026-01-01","why":"w","input":{"q":"the quick brown fox jumps over the lazy dog"},"expected":{"a":1}}'
  echo '{"id":"d-2","bucket":"edge","added":"2026-01-01","why":"w","input":{"q":"the quick brown fox jumps over the lazy dog"},"expected":{"a":2}}'
} > "$SB/near.jsonl"
emits '"NEAR_DUPLICATE"' "identical inputs report NEAR_DUPLICATE" -- "$PYTHON" "$AUD" "$SB/near.jsonl" --json
emits "NEAR_DUPLICATE_SKIPPED" "--max-pairs 0 skips the O(n^2) scan and says so" -- "$PYTHON" "$AUD" "$SB/near.jsonl" --max-pairs 0 --json

# --- freeze manifest --------------------------------------------------------
exit_is 0 "--write-freeze on a clean set" -- "$PYTHON" "$AUD" "$SB/healthy.jsonl" --write-freeze "$SB/m.json"
[ -f "$SB/m.json" ] && ok "freeze manifest written" || bad "freeze manifest written"
[ -f "$SB/m.json.tmp" ] && bad "temp file left behind" || ok "atomic write leaves no .tmp"
exit_is 0 "unchanged set matches its freeze" -- "$PYTHON" "$AUD" "$SB/healthy.jsonl" --freeze "$SB/m.json"

# Editing a frozen case in place is the cardinal sin -- must be an error.
"$PYTHON" - "$SB/healthy.jsonl" "$SB/edited.jsonl" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
lines = [json.loads(l) for l in open(src, encoding="utf-8") if l.strip()]
lines[0]["expected"] = {"a": "quietly changed to make it pass"}
with open(dst, "w", encoding="utf-8") as fh:
    for c in lines:
        fh.write(json.dumps(c) + "\n")
PYEOF
emits "FREEZE_CASE_CHANGED" "in-place edit of a frozen case reports FREEZE_CASE_CHANGED" -- "$PYTHON" "$AUD" "$SB/edited.jsonl" --freeze "$SB/m.json" --json
exit_is 10 "in-place edit fails the freeze check" -- "$PYTHON" "$AUD" "$SB/edited.jsonl" --freeze "$SB/m.json"

# Adding a case is a warning (re-baseline), not an error.
{ cat "$SB/healthy.jsonl"; mk_case "new-1" adversarial; } > "$SB/grown.jsonl"
emits "FREEZE_CASE_ADDED" "added case reports FREEZE_CASE_ADDED" -- "$PYTHON" "$AUD" "$SB/grown.jsonl" --freeze "$SB/m.json" --json
exit_is 0 "added case is advisory under --fail-on error" -- "$PYTHON" "$AUD" "$SB/grown.jsonl" --freeze "$SB/m.json"

# Field order must not change a case hash -- otherwise every reformat is "drift".
"$PYTHON" - "$SB/healthy.jsonl" "$SB/reordered.jsonl" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(dst, "w", encoding="utf-8") as fh:
    for line in open(src, encoding="utf-8"):
        if line.strip():
            c = json.loads(line)
            fh.write(json.dumps(dict(reversed(list(c.items())))) + "\n")
PYEOF
exit_is 0 "key reordering does not count as drift" -- "$PYTHON" "$AUD" "$SB/reordered.jsonl" --freeze "$SB/m.json"

exit_is 2 "--freeze and --write-freeze are mutually exclusive" \
    -- "$PYTHON" "$AUD" "$SB/healthy.jsonl" --freeze "$SB/m.json" --write-freeze "$SB/m2.json"
exit_is 3 "missing freeze manifest" -- "$PYTHON" "$AUD" "$SB/healthy.jsonl" --freeze "$SB/absent.json"

# --- eval-baseline: noise floor, significance, ceilings ---------------------
# History with a KNOWN spread. scores .88 .85 .89 .86 .88
#   mean         = 0.872
#   sample stdev = sqrt(0.00108/4) = 0.016432 -> 0.0164
#   2-sigma gate = 0.872 - 2(0.0164) = 0.8392
for v in 0.88 0.85 0.89 0.86 0.88; do
  echo "{\"score\":$v,\"n\":30,\"dataset\":\"v3\",\"judge\":\"j1\"}"
done > "$SB/hist.jsonl"
echo '{"score":0.87,"n":30,"dataset":"v3","judge":"j1","cost_usd":1.20,"p95_ms":3000}' > "$SB/cand.jsonl"

json_eq "data.baseline" "0.872" "baseline is the window mean" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --json
json_eq "data.noise_floor" "0.0164" "noise floor is the sample stdev" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --json
json_eq "data.recommended_threshold" "0.8392" "gate sits 2 sigma below baseline" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --json
json_eq "data.verdict" "noise" "a 0.002 drop inside the band is noise" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --json
exit_is 0 "noise does not fail the gate" -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl"

echo '{"score":0.62,"n":30,"dataset":"v3","judge":"j1"}' > "$SB/drop.jsonl"
json_eq "data.verdict" "regression" "a drop past the threshold is a regression" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/drop.jsonl" --json
exit_is 10 "regression exits 10" -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/drop.jsonl"

# --sigma widens the band: 0.83 is below the 2-sigma gate (0.8392) but above the
# 4-sigma gate (0.8064), so the same score must classify differently.
echo '{"score":0.83,"n":30,"dataset":"v3","judge":"j1"}' > "$SB/mid.jsonl"
json_eq "data.verdict" "regression" "0.83 is a regression at the default 2 sigma" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/mid.jsonl" --json
json_eq "data.verdict" "noise" "0.83 is noise at 4 sigma (wider band)" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/mid.jsonl" --sigma 4 --json

# --- McNemar exact test -----------------------------------------------------
# 30 cases all passing at baseline; 8 now fail. b=8, c=0.
# p = 2 * C(8,0)/2^8 = 2/256 = 0.007812
for i in $(seq 1 30); do echo "{\"id\":\"c$i\",\"passed\":true}"; done > "$SB/base-res.jsonl"
{ for i in $(seq 1 22); do echo "{\"id\":\"c$i\",\"passed\":true}"; done
  for i in $(seq 23 30); do echo "{\"id\":\"c$i\",\"passed\":false}"; done; } > "$SB/cand-res.jsonl"

PAIR=(--baseline-results "$SB/base-res.jsonl" --candidate-results "$SB/cand-res.jsonl")
json_eq "data.significance.p_value" "0.007812" "McNemar exact p for b=8,c=0" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${PAIR[@]}" --json
json_eq "data.verdict" "regression" "paired test overrides a flat aggregate score" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${PAIR[@]}" --json
json_eq "data.significance.regressed.0" "c23" "regressed cases are named, not just counted" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${PAIR[@]}" --json
exit_is 10 "significant paired regression exits 10" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${PAIR[@]}"

# CHURN, not regression. 8 break and 7 are fixed: b=8, c=7, p = 1.0 exactly.
# This is the case references/regression-gating.md calls out: the honest verdict
# is "noise", and the value of the run is the enumerated lists, not the verdict.
# If this ever flips to "regression", the exact test has been replaced by
# something that over-claims - which is the failure mode the whole file warns about.
{ for i in $(seq 1 15); do echo "{\"id\":\"c$i\",\"passed\":true}"; done
  for i in $(seq 16 22); do echo "{\"id\":\"c$i\",\"passed\":false}"; done
  for i in $(seq 23 30); do echo "{\"id\":\"c$i\",\"passed\":true}"; done; } > "$SB/churn-base.jsonl"
{ for i in $(seq 1 15); do echo "{\"id\":\"c$i\",\"passed\":true}"; done
  for i in $(seq 16 22); do echo "{\"id\":\"c$i\",\"passed\":true}"; done
  for i in $(seq 23 30); do echo "{\"id\":\"c$i\",\"passed\":false}"; done; } > "$SB/churn-cand.jsonl"

CHURN=(--baseline-results "$SB/churn-base.jsonl" --candidate-results "$SB/churn-cand.jsonl")
json_eq "data.significance.p_value" "1.0" "8 broken / 7 fixed is p=1.0, not a regression" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${CHURN[@]}" --json
json_eq "data.verdict" "noise" "churn is reported as noise, honestly" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${CHURN[@]}" --json
json_eq "data.significance.n_fixed" "7" "...but the 7 fixed cases are still enumerated" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${CHURN[@]}" --json
exit_is 0 "churn does not fail the gate" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${CHURN[@]}"

# Identical runs: zero discordant pairs, p = 1.0 by definition.
json_eq "data.significance.p_value" "1.0" "identical runs give p=1.0" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" \
       --baseline-results "$SB/base-res.jsonl" --candidate-results "$SB/base-res.jsonl" --json

# Direction matters: the same pair reversed is an improvement, not a regression.
REV=(--baseline-results "$SB/cand-res.jsonl" --candidate-results "$SB/base-res.jsonl")
json_eq "data.verdict" "improvement" "a significant improvement is labelled as such" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${REV[@]}" --json
exit_is 0 "an improvement never fails the gate" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" "${REV[@]}"

# Cases present in only one result set cannot be paired and must be flagged.
head -20 "$SB/base-res.jsonl" > "$SB/short-res.jsonl"
json_eq "data.significance.unpaired_ids" "10" "unpaired case ids are counted" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" \
       --baseline-results "$SB/short-res.jsonl" --candidate-results "$SB/cand-res.jsonl" --json

# --- confounded comparisons must warn ---------------------------------------
# A dataset or judge change inside the window means the MEASUREMENT moved, not
# necessarily the system. Silence here would be the worst possible failure.
for v in 0.88 0.85 0.89; do echo "{\"score\":$v,\"dataset\":\"v3\",\"judge\":\"j1\"}"; done > "$SB/mixed.jsonl"
echo '{"score":0.86,"dataset":"v4","judge":"j1"}' >> "$SB/mixed.jsonl"
_err="$("$PYTHON" "$BAS" "$SB/mixed.jsonl" 2>&1 >/dev/null)"
case "$_err" in
    *"dataset version changed"*) ok "warns when the dataset version changes mid-window" ;;
    *) bad "warns when the dataset version changes mid-window" ;;
esac
_err="$("$PYTHON" "$BAS" "$SB/hist.jsonl" --window 2 --candidate "$SB/cand.jsonl" 2>&1 >/dev/null)"
case "$_err" in
    *"noise floor needs"*) ok "warns when the window is too small for a noise floor" ;;
    *) bad "warns when the window is too small for a noise floor" ;;
esac

# --- ceilings: absolute, not trend ------------------------------------------
exit_is 10 "cost ceiling breach fails"    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --max-cost-usd 0.50
exit_is 0  "cost under ceiling passes"    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --max-cost-usd 5.00
exit_is 10 "latency ceiling breach fails" -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --max-p95-ms 1000
exit_is 0  "latency under ceiling passes" -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --max-p95-ms 9000

# --- argument validation ----------------------------------------------------
exit_is 2 "paired flags must be given together" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --baseline-results "$SB/base-res.jsonl"
exit_is 2 "--alpha must be in (0,1)"  -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --alpha 1.5
exit_is 2 "--sigma must be positive"  -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --sigma 0
exit_is 2 "--window must be >= 1"     -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --window 0
exit_is 3 "missing history file"      -- "$PYTHON" "$BAS" "$SB/absent.jsonl"
exit_is 4 "malformed history"         -- "$PYTHON" "$BAS" "$SB/bad.jsonl"

# --- shipped assets must survive the skill's own tools ----------------------
# An asset the skill's own scripts reject is worse than no asset at all.
ASSETS="$SKILL/assets"
exit_is 0 "example golden set passes its own audit" -- "$PYTHON" "$AUD" "$ASSETS/golden-set.example.jsonl"
exit_is 0 "runner template compiles"                -- "$PYTHON" -m py_compile "$ASSETS/eval-runner.template.py"
[ -f "$ASSETS/judge-rubric.template.md" ] && ok "judge rubric template ships" || bad "judge rubric template ships"
[ -f "$ASSETS/eval-gate.template.yml" ]   && ok "CI gate template ships"      || bad "CI gate template ships"


# --- --accept: the hillclimb keep/discard gate ------------------------------
# The whole point of this flag is that it asks a DIFFERENT question from CI.
# CI: "did this get worse?" -> noise is fine, exit 0.
# Hillclimb: "is this improvement real?" -> noise is NOT good enough to bank.
# These four assertions pin that inversion. If a refactor ever makes the noise
# case exit 0 under --accept, the loop silently goes back to banking noise.
echo '{"score":0.97,"n":30,"dataset":"v3","judge":"j1"}' > "$SB/win.jsonl"

exit_is 0  "noise passes CI (did it get worse? no)" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl"
exit_is 10 "noise is a DISCARD under --accept (is it real? no)" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --accept
exit_is 0  "a real improvement is a KEEP under --accept" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/win.jsonl" --accept
exit_is 10 "a regression is a DISCARD under --accept" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/drop.jsonl" --accept

json_eq "data.hillclimb_decision" "discard" "noise reports decision=discard" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" --json
json_eq "data.hillclimb_decision" "keep" "a real improvement reports decision=keep" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/win.jsonl" --json

# The decision is exposed in the report regardless of the flag, so a caller can
# read it without adopting the inverted exit semantics.
json_eq "data.hillclimb_decision" "discard" "decision is reported without --accept too" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/drop.jsonl" --json

# A significant paired improvement is a KEEP even when the aggregate barely moved -
# this is the case a raw score comparison gets wrong in the generous direction.
json_eq "data.hillclimb_decision" "keep" "paired significance drives the keep decision" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" \
       --baseline-results "$SB/cand-res.jsonl" --candidate-results "$SB/base-res.jsonl" --json
# ...and churn (8 broken / 7 fixed, p=1.0) is NOT a keep, despite 7 fixes.
json_eq "data.hillclimb_decision" "discard" "churn is never banked as an improvement" \
    -- "$PYTHON" "$BAS" "$SB/hist.jsonl" --candidate "$SB/cand.jsonl" \
       --baseline-results "$SB/churn-base.jsonl" --candidate-results "$SB/churn-cand.jsonl" --json

# --- the iterate <-> evals-ops seam is documented in BOTH directions --------
# A one-way cross-reference rots: whichever side gets edited without the other
# leaves a dangling claim. These assert the link exists from each end.
ITERATE="$SKILL/../iterate/SKILL.md"
if [ -f "$ITERATE" ]; then
    grep -q "eval-baseline.py" "$ITERATE" \
        && ok "iterate points at the noise-floor gate" \
        || bad "iterate points at the noise-floor gate"
    grep -q "hillclimbing.md" "$ITERATE" \
        && ok "iterate links the hillclimbing reference" \
        || bad "iterate links the hillclimbing reference"
else
    ok "iterate skill not present (installed standalone) - seam check skipped"
fi
grep -q "iterate" "$SKILL/references/hillclimbing.md" \
    && ok "hillclimbing defers loop mechanics to iterate" \
    || bad "hillclimbing defers loop mechanics to iterate"


echo
echo "evals-ops: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
