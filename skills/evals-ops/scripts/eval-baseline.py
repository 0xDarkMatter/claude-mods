#!/usr/bin/env python3
"""Tell a real eval regression from noise, using run history and McNemar's test.

Reads the rolling run-history file the runner appends to, derives the baseline
and the NOISE FLOOR, and judges one candidate run against them. Where per-case
results for both runs are supplied it also runs McNemar's exact test, which is
the honest answer to "did my change make it worse" on paired binary outcomes --
a score drop inside the noise band is not evidence of anything.

Usage:   eval-baseline.py [OPTIONS] <HISTORY.jsonl>
Input:   HISTORY.jsonl -- one summary object per run, appended over time.
         Recognised: `score` (required), `n`, `date`, `dataset`, `judge`,
         `cost_usd`, `p95_ms`. `-` reads stdin.
         --candidate FILE     a one-row summary for the run under test
                              (default: the last row of HISTORY)
         --baseline-results / --candidate-results  per-case JSONL of
                              {"id": ..., "passed": true|false} for McNemar
Output:  stdout -- human-readable verdict, or a --json envelope
         {"data": {...}, "meta": {...}} per SKILL-RESOURCE-PROTOCOL.md §4.
Stderr:  headers, warnings, errors.
Exit:    0 no regression (noise, improvement, or not enough evidence),
         2 usage, 3 not-found, 4 validation,
         10 REGRESSION CONFIRMED or a cost/latency ceiling breached

         --accept INVERTS this deliberately, for use as a hillclimb keep/discard
         gate:  0 = KEEP (a real improvement),  10 = DISCARD (noise or worse).
         Under --accept, "noise" is a DISCARD -- banking a change that is inside
         the noise band is how an improvement loop turns into a random walk.
         See references/hillclimbing.md.

Examples:
  eval-baseline.py evals/history.jsonl
  eval-baseline.py evals/history.jsonl --candidate /tmp/run.jsonl
  eval-baseline.py evals/history.jsonl --baseline-results base.jsonl \
      --candidate-results new.jsonl --alpha 0.05
  eval-baseline.py evals/history.jsonl --max-cost-usd 2.50 --max-p95-ms 6000
  eval-baseline.py evals/history.jsonl --candidate iter.jsonl --accept  # keep/discard
  eval-baseline.py evals/history.jsonl --json | jq '.data.recommended_threshold'

Offline and stdlib-only: it reads files you already have, it never calls a model.
"""

import argparse
import json
import math
import sys

SCHEMA = "claude-mods.evals-ops.eval-baseline/v1"

EXIT_OK, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_VALIDATION, EXIT_REGRESSION = 0, 2, 3, 4, 10


def load_jsonl(path, label):
    """Read JSONL from a path or stdin. Raises with a line number on bad input."""
    if path == "-":
        text = sys.stdin.read()
    else:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except FileNotFoundError:
            raise FileNotFoundError(path)
        except IsADirectoryError:
            raise ValueError(f"{path} is a directory, not a JSONL file")

    rows = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{label} line {lineno}: not valid JSON ({exc.msg})")
        if not isinstance(obj, dict):
            raise ValueError(f"{label} line {lineno}: expected a JSON object")
        rows.append(obj)
    return rows


def stdev(values):
    """Sample standard deviation. None below two points -- one run is not a spread."""
    n = len(values)
    if n < 2:
        return None
    mean = sum(values) / n
    return math.sqrt(sum((v - mean) ** 2 for v in values) / (n - 1))


# Above this many discordant pairs the exact test is switched for the normal
# approximation. The exact sum is O(n) big-integer work over 2**n: measured at
# 133 ms for n=2000 but ~100 SECONDS for n=20000, which is a CI hang, not a
# slow test. The approximation is reliable well below this bound (the usual
# rule of thumb is b+c >= 25), so nothing accurate is lost by switching here.
MCNEMAR_EXACT_MAX = 1000


def mcnemar(b, c):
    """Two-sided McNemar p-value. Returns (p_value, method).

    b = passed before, fails now (regressions);  c = failed before, passes now.
    Only the DISCORDANT pairs carry information -- cases that behaved the same in
    both runs tell you nothing about whether the change helped. Under the null
    b ~ Binomial(b+c, 0.5), so the p-value is a coin-flip tail probability.

    Exact below MCNEMAR_EXACT_MAX because eval sets routinely produce b+c < 25,
    where the chi-square/normal approximation is unreliable; normal (with a
    continuity correction) above it, because the exact form does not terminate
    in useful time. The method used is reported so a caller never has to guess.
    """
    n = b + c
    if n == 0:
        return 1.0, "none-discordant"
    if n <= MCNEMAR_EXACT_MAX:
        k = min(b, c)
        tail = sum(math.comb(n, i) for i in range(0, k + 1)) / (2 ** n)
        return min(1.0, 2 * tail), "exact"
    # Continuity-corrected normal approximation; erfc gives the two-sided tail.
    z = (abs(b - c) - 1) / math.sqrt(n)
    return min(1.0, math.erfc(abs(z) / math.sqrt(2))), "normal-approx"


def paired_counts(baseline_rows, candidate_rows):
    """Pair per-case results by id. Returns (b, c, both_pass, both_fail, unpaired)."""
    # Test `"id" in r`, NOT the truthiness of r["id"] -- an integer id of 0 or an
    # empty-string id is falsy, and the truthiness form silently DROPPED those
    # cases from the paired test, hiding real regressions. Stringify so 1 and "1"
    # pair with each other rather than becoming two unpaired cases.
    def index(rows):
        return {str(r["id"]): bool(r.get("passed")) for r in rows if "id" in r}

    base, cand = index(baseline_rows), index(candidate_rows)
    shared = set(base) & set(cand)

    b = sorted(i for i in shared if base[i] and not cand[i])
    c = sorted(i for i in shared if not base[i] and cand[i])
    both_pass = sum(1 for i in shared if base[i] and cand[i])
    both_fail = sum(1 for i in shared if not base[i] and not cand[i])
    unpaired = len(set(base) ^ set(cand))
    return b, c, both_pass, both_fail, unpaired


def build_report(history, candidate, window, sigma, paired, alpha, ceilings):
    prior = [r for r in history if r is not candidate][-window:]
    scores = [float(r["score"]) for r in prior if isinstance(r.get("score"), (int, float))]

    warnings = []
    # A row whose score is absent or non-numeric (a JSON string "0.9", a null) is
    # unusable. Dropping it in silence let a whole malformed history report
    # "insufficient data" and exit 0 -- a gate failing open with no explanation.
    unusable = len(prior) - len(scores)
    if unusable:
        warnings.append(
            f"{unusable} history row(s) had a missing or non-numeric 'score' and "
            "were ignored (scores must be JSON numbers, not strings)"
        )

    baseline = round(sum(scores) / len(scores), 4) if scores else None
    spread = stdev(scores)
    spread = round(spread, 4) if spread is not None else None

    # A threshold inside the noise band fails on identical code. Sit below the
    # baseline by more than the measured spread -- that is the whole point of
    # keeping a history rather than judging each run standalone.
    #
    # `spread is not None` is deliberate, NOT a truthiness test: a spread of
    # exactly 0.0 is a MEASURED result (a deterministic metric, or a genuinely
    # stable suite) and the most informative history you can have. Treating it as
    # "no data" made the gate report insufficient-data and exit 0 on an
    # unambiguous 0.90 -> 0.70 regression.
    threshold = (round(baseline - sigma * spread, 4)
                 if (baseline is not None and spread is not None) else None)

    cand_score = candidate.get("score") if candidate else None
    cand_score = float(cand_score) if isinstance(cand_score, (int, float)) else None
    delta = round(cand_score - baseline, 4) if (cand_score is not None and baseline is not None) else None
    # z is undefined when the spread is exactly 0 (division by zero), but that is
    # the EASY case, not the hard one: with no measured variance any movement is
    # real. Handled explicitly in the verdict below rather than left as None.
    z = None
    if delta is not None and spread:
        z = round(delta / spread, 2)

    if len(scores) < 3:
        warnings.append(
            f"only {len(scores)} prior run(s) in the window; a noise floor needs "
            "at least 3, and 5 reruns of unchanged code is the honest way to get it"
        )

    # Comparing across a dataset, judge or rubric change is confounded: you cannot
    # tell whether the system moved or the measurement did.
    for field, human in (("dataset", "dataset version"), ("judge", "judge model")):
        seen = {r.get(field) for r in prior + ([candidate] if candidate else []) if r.get(field)}
        if len(seen) > 1:
            warnings.append(
                f"{human} changed within the window ({', '.join(sorted(map(str, seen)))}) "
                "-- re-baseline; scores across that boundary are not comparable"
            )

    # --- significance -------------------------------------------------------
    significance = None
    if paired is not None:
        b_ids, c_ids, both_pass, both_fail, unpaired = paired
        p, method = mcnemar(len(b_ids), len(c_ids))
        significance = {
            "test": f"mcnemar-{method}",
            "regressed": b_ids,           # passed before, fails now
            "fixed": c_ids,               # failed before, passes now
            "n_regressed": len(b_ids),
            "n_fixed": len(c_ids),
            "both_pass": both_pass,
            "both_fail": both_fail,
            "unpaired_ids": unpaired,
            "p_value": round(p, 6),
            "alpha": alpha,
            "significant": p < alpha,
            "direction": "worse" if len(b_ids) > len(c_ids)
                         else ("better" if len(c_ids) > len(b_ids) else "unchanged"),
        }
        if unpaired:
            warnings.append(
                f"{unpaired} case id(s) appear in only one result set; they are "
                "excluded from the paired test"
            )
        if len(b_ids) + len(c_ids) == 0:
            warnings.append("no discordant cases -- the two runs agree everywhere")

    # --- ceilings -----------------------------------------------------------
    # Ceilings, not trends: a trend gate fires on noise, a ceiling encodes a
    # product decision someone actually made.
    breaches = []
    if candidate:
        for key, limit, label in (
            ("cost_usd", ceilings.get("cost"), "cost_usd"),
            ("p95_ms", ceilings.get("p95"), "p95_ms"),
        ):
            value = candidate.get(key)
            if limit is not None and isinstance(value, (int, float)) and value > limit:
                breaches.append({"metric": label, "value": value, "ceiling": limit})

    # --- verdict ------------------------------------------------------------
    # Paired significance is the strongest evidence available; fall back to the
    # sigma rule only when per-case results were not supplied.
    if significance is not None:
        if significance["significant"] and significance["direction"] == "worse":
            verdict, reason = "regression", (
                f"{significance['n_regressed']} case(s) regressed vs "
                f"{significance['n_fixed']} fixed, p={significance['p_value']} "
                f"< alpha={alpha}"
            )
        elif significance["significant"] and significance["direction"] == "better":
            verdict, reason = "improvement", (
                f"{significance['n_fixed']} case(s) fixed vs "
                f"{significance['n_regressed']} regressed, p={significance['p_value']}"
            )
        else:
            verdict, reason = "noise", (
                f"p={significance['p_value']} >= alpha={alpha}; the difference is "
                "not distinguishable from chance"
            )
    elif cand_score is None or threshold is None:
        verdict, reason = "insufficient-data", (
            "no candidate score, or fewer than 2 usable history rows -- rerun the "
            "suite against unchanged code a few times to establish a noise floor "
            "before gating on it"
        )
    elif spread == 0:
        # Zero measured variance: every rerun of unchanged code gave the same
        # number, so ANY movement is signal and there is no band to be inside.
        if cand_score < baseline:
            verdict, reason = "regression", (
                f"score {cand_score} is below a baseline of {baseline} measured "
                "with zero variance across the window"
            )
        elif cand_score > baseline:
            verdict, reason = "improvement", (
                f"score {cand_score} exceeds a zero-variance baseline of {baseline}"
            )
        else:
            verdict, reason = "noise", f"score is identical to the baseline {baseline}"
    elif cand_score < threshold:
        verdict, reason = "regression", (
            f"score {cand_score} is below the {sigma}-sigma threshold {threshold}"
        )
    elif z is not None and z > sigma:
        verdict, reason = "improvement", f"score is {z} sigma above baseline"
    else:
        verdict, reason = "noise", (
            f"score {cand_score} is within the noise band around {baseline}"
        )

    if breaches:
        reason += "; " + ", ".join(
            f"{x['metric']} {x['value']} exceeds ceiling {x['ceiling']}" for x in breaches
        )

    # The hillclimb decision is NOT the same question as the CI-gate decision.
    # CI asks "did this get worse?" (noise is fine). A hillclimb asks "is this
    # improvement real?" (noise is not good enough to bank). Only an improvement
    # that clears the floor, or is significant on the paired test, is a KEEP.
    decision = "keep" if verdict == "improvement" else "discard"

    return {
        "verdict": verdict,
        "reason": reason,
        "hillclimb_decision": decision,
        "failing": verdict == "regression" or bool(breaches),
        "baseline": baseline,
        "noise_floor": spread,
        "sigma": sigma,
        "recommended_threshold": threshold,
        "candidate_score": cand_score,
        "delta": delta,
        "z": z,
        "window": len(scores),
        "significance": significance,
        "ceiling_breaches": breaches,
        "warnings": warnings,
    }


def print_human(r, source):
    out = [f"eval baseline: {source}"]
    out.append(f"  window          {r['window']} prior run(s)")
    out.append(f"  baseline        {r['baseline']}")
    out.append(f"  noise floor     {r['noise_floor']}  (sample stdev)")
    out.append(f"  gate at         {r['recommended_threshold']}  ({r['sigma']} sigma below baseline)")
    out.append(f"  candidate       {r['candidate_score']}   delta {r['delta']}   z {r['z']}")
    sig = r["significance"]
    if sig:
        out.append("")
        out.append("  paired test (McNemar exact)")
        out.append(f"    regressed     {sig['n_regressed']}   fixed {sig['n_fixed']}")
        out.append(f"    unchanged     {sig['both_pass']} pass / {sig['both_fail']} fail")
        out.append(f"    p-value       {sig['p_value']}  (alpha {sig['alpha']})")
        # Naming the flipped cases is what stops people ignoring a red gate.
        if sig["regressed"]:
            out.append(f"    now failing   {', '.join(sig['regressed'][:15])}")
        if sig["fixed"]:
            out.append(f"    now passing   {', '.join(sig['fixed'][:15])}")
    for x in r["ceiling_breaches"]:
        out.append(f"  CEILING         {x['metric']} {x['value']} > {x['ceiling']}")
    out.append("")
    out.append(f"  verdict         {r['verdict'].upper()} - {r['reason']}")
    out.append(f"  hillclimb       {r['hillclimb_decision'].upper()}")
    print("\n".join(out))


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="eval-baseline.py",
        description="Distinguish an eval regression from noise using run history "
                    "and McNemar's exact test.",
    )
    ap.add_argument("history", help="rolling run-history JSONL, or - for stdin")
    ap.add_argument("--candidate", metavar="FILE",
                    help="one-row summary for the run under test "
                         "(default: the last row of HISTORY)")
    ap.add_argument("--baseline-results", metavar="FILE",
                    help="per-case JSONL of the baseline run, for the paired test")
    ap.add_argument("--candidate-results", metavar="FILE",
                    help="per-case JSONL of the candidate run, for the paired test")
    ap.add_argument("--window", type=int, default=10, metavar="N",
                    help="prior runs used for baseline and noise floor (default: 10)")
    ap.add_argument("--sigma", type=float, default=2.0, metavar="K",
                    help="how many noise-floor widths below baseline the gate sits "
                         "(default: 2.0)")
    ap.add_argument("--alpha", type=float, default=0.05, metavar="A",
                    help="significance level for the paired test (default: 0.05)")
    ap.add_argument("--max-cost-usd", type=float, metavar="USD",
                    help="fail if the candidate run exceeds this cost")
    ap.add_argument("--max-p95-ms", type=float, metavar="MS",
                    help="fail if the candidate run exceeds this p95 latency")
    ap.add_argument("--accept", action="store_true",
                    help="hillclimb keep/discard gate: exit 0 = KEEP a real improvement, "
                         "exit 10 = DISCARD noise or a regression (INVERTS the default "
                         "meaning of noise -- see the header)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")

    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        raise SystemExit(exc.code)

    def fail(code, kind, message):
        if args.json:
            print(json.dumps({"error": {"code": kind, "message": message, "details": {}}}))
        print(f"eval-baseline: {message}", file=sys.stderr)
        return code

    if args.window < 1:
        return fail(EXIT_USAGE, "VALIDATION", "--window must be at least 1")
    if args.sigma <= 0:
        return fail(EXIT_USAGE, "VALIDATION", "--sigma must be positive")
    if not (0.0 < args.alpha < 1.0):
        return fail(EXIT_USAGE, "VALIDATION", "--alpha must be strictly between 0 and 1")
    if bool(args.baseline_results) != bool(args.candidate_results):
        return fail(EXIT_USAGE, "VALIDATION",
                    "--baseline-results and --candidate-results must be given together")

    try:
        history = load_jsonl(args.history, "history")
        candidate = None
        if args.candidate:
            rows = load_jsonl(args.candidate, "candidate")
            if not rows:
                return fail(EXIT_VALIDATION, "VALIDATION", "candidate file has no rows")
            candidate = rows[-1]
        elif history:
            candidate = history[-1]

        paired = None
        if args.baseline_results:
            base_rows = load_jsonl(args.baseline_results, "baseline-results")
            cand_rows = load_jsonl(args.candidate_results, "candidate-results")
            if not base_rows or not cand_rows:
                return fail(EXIT_VALIDATION, "VALIDATION",
                            "per-case result files must not be empty")
            paired = paired_counts(base_rows, cand_rows)
    except FileNotFoundError as exc:
        return fail(EXIT_NOT_FOUND, "NOT_FOUND", f"no such file: {exc}")
    except ValueError as exc:
        return fail(EXIT_VALIDATION, "VALIDATION", str(exc))

    if not history and candidate is None:
        return fail(EXIT_VALIDATION, "VALIDATION", "history is empty and no --candidate given")

    report = build_report(
        history, candidate, args.window, args.sigma, paired, args.alpha,
        {"cost": args.max_cost_usd, "p95": args.max_p95_ms},
    )

    if args.json:
        print(json.dumps({
            "data": report,
            "meta": {"count": report["window"], "schema": SCHEMA, "source": args.history},
        }, indent=2))
    else:
        print_human(report, args.history)

    for w in report["warnings"]:
        print(f"eval-baseline: warning: {w}", file=sys.stderr)

    if args.accept:
        return EXIT_OK if report["hillclimb_decision"] == "keep" else EXIT_REGRESSION
    return EXIT_REGRESSION if report["failing"] else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
