#!/usr/bin/env python3
"""The 40-line eval runner. Copy into your repo and adapt the two ADAPT blocks.

This is deliberately small and dependency-free. It is the thing to start with
before adopting a platform (see references/tooling-landscape.md) -- it forces you
to decide what you are measuring, which is the hard part no platform does for you.

What it does:
  - reads a golden set (JSONL, one case per line)
  - runs each case k times through YOUR system
  - applies deterministic assertions first, judge criteria only where needed
  - records cost and latency PER CASE from the first run, not retrofitted later
  - writes a per-case results file and appends one summary row to a run history

Usage:   eval-runner.py GOLDEN.jsonl [-k 3] [--out results.jsonl] [--history history.jsonl]
Exit:    0 ran to completion, 1 a case raised, 2 usage

The summary row is what eval-baseline.py consumes to tell noise from regression.
"""

import argparse
import json
import time


# ==========================================================================
# ADAPT BLOCK 1 -- call your system.
# Return a dict. Include token counts and the model id; you will want them and
# threading them in later means touching every runner, result and dashboard.
# ==========================================================================
def run_system(case):
    # from my_app import agent
    # result = agent.invoke(case["input"])
    # return {"output": result.text, "tool_calls": result.tool_calls,
    #         "tokens_in": result.usage.input_tokens,
    #         "tokens_out": result.usage.output_tokens,
    #         "model": result.model}
    raise NotImplementedError("wire this to your agent")


# ==========================================================================
# ADAPT BLOCK 2 -- call your judge, ONLY for criteria code cannot check.
# Return True/False per criterion. Pin the judge model version: an unpinned
# judge silently re-baselines your whole history (references/llm-judge.md).
# ==========================================================================
JUDGE_MODEL = "<pin-a-specific-model-version-here>"


def judge(criterion, case, result):
    # from my_app import judge_client
    # verdict = judge_client.score(model=JUDGE_MODEL, temperature=0,
    #                              criterion=criterion, output=result["output"])
    # return verdict["pass"]
    raise NotImplementedError("wire this to your judge, or drop criteria entirely")


def deterministic(case, result):
    """Cheap assertions run first and are the ones that gate CI.

    Every criterion you can express here instead of in `judge` removes cost,
    latency AND variance at once. Re-audit periodically -- rubric items become
    codifiable once the output format stabilises.
    """
    expected = case.get("expected")
    if not expected:
        return None  # nothing deterministic to check; criteria carry this case
    if "tool" in expected:
        calls = result.get("tool_calls") or []
        if not any(c.get("name") == expected["tool"] for c in calls):
            return False
        if "args" in expected:
            got = next(c for c in calls if c.get("name") == expected["tool"])
            for key, want in expected["args"].items():
                if got.get("args", {}).get(key) != want:
                    return False
        return True
    if expected.get("refused") or expected.get("clarifies"):
        # Absence of a tool call is the check; the wording is a judge question.
        return not (result.get("tool_calls") or [])
    return result.get("output") == expected.get("output")


def evaluate(case, k):
    """Run one case k times. Returns the per-case record."""
    runs = []
    for _ in range(k):
        started = time.monotonic()
        result = run_system(case)
        elapsed_ms = int((time.monotonic() - started) * 1000)

        det = deterministic(case, result)
        crit = {c: judge(c, case, result) for c in case.get("criteria", [])} \
            if det is not False else {}
        passed = bool(det is not False and all(crit.values()) if crit else det)

        runs.append({
            "passed": passed,
            "deterministic": det,
            "criteria": crit,
            "ms": elapsed_ms,
            "tokens_in": result.get("tokens_in"),
            "tokens_out": result.get("tokens_out"),
            "model": result.get("model"),
        })

    return {
        "id": case.get("id"),
        "bucket": case.get("bucket"),
        # pass@1 is the honest headline; pass^k is what production experiences.
        "passed": runs[0]["passed"],
        "pass_hat_k": all(r["passed"] for r in runs),
        "pass_at_k": any(r["passed"] for r in runs),
        "runs": runs,
    }


def main():
    ap = argparse.ArgumentParser(description="Minimal golden-set eval runner.")
    ap.add_argument("golden")
    ap.add_argument("-k", type=int, default=1, help="runs per case (3 to report pass^k)")
    ap.add_argument("--out", default="results.jsonl")
    ap.add_argument("--history", default="history.jsonl")
    ap.add_argument("--dataset-version", default="unversioned",
                    help="never compare scores across dataset versions")
    args = ap.parse_args()

    cases = [json.loads(l) for l in open(args.golden, encoding="utf-8")
             if l.strip() and not l.startswith("#")]
    results = [evaluate(c, args.k) for c in cases]

    with open(args.out, "w", encoding="utf-8") as fh:
        for r in results:
            fh.write(json.dumps(r) + "\n")

    n = len(results)
    summary = {
        "dataset": args.dataset_version,
        "judge": JUDGE_MODEL,
        "n": n,
        "k": args.k,
        "score": round(sum(r["passed"] for r in results) / n, 4),
        "pass_hat_k": round(sum(r["pass_hat_k"] for r in results) / n, 4),
        "tokens_in": sum(run["tokens_in"] or 0 for r in results for run in r["runs"]),
        "tokens_out": sum(run["tokens_out"] or 0 for r in results for run in r["runs"]),
        "p95_ms": sorted(run["ms"] for r in results for run in r["runs"])[int(0.95 * n * args.k)],
        # Stamp `date` from CI (git commit date / job start), not from the runner,
        # so a re-run of an old commit does not claim to be today's measurement.
    }
    with open(args.history, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(summary) + "\n")

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
