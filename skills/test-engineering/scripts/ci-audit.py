#!/usr/bin/env python3
"""What CI costs per change, and the workflow settings that waste it.

Usage:   ci-audit.py cost [--repo OWNER/NAME] [--limit N] [--workflow NAME] [--rates FILE]
                          [--from-file RUNS.json] [--save RUNS.json] [--json]
         ci-audit.py lint [WORKFLOW.yml...] [--json]   (default: .github/workflows/*.y*ml)
Input:   cost: GitHub's REST API through `gh api` (runs, then each run's jobs), or a file
         saved earlier with --save (that is also the offline test seam). --rates is a JSON
         map of runner OS to $ per minute, e.g. {"linux": 0.006, "windows": 0.010}: rates
         change, so none are built in; with no --rates, cost is reported in minutes only.
Output:  TSV, or --json (schema claude-mods.test-engineering.ci-audit/v1).
Stderr:  progress, the summary line, errors.
Exit:    0 ok, 2 usage, 3 file not found, 4 invalid input, 5 gh missing or not logged in,
         7 GitHub unreachable or rate-limited, 10 (lint) at least one finding.

Billing model encoded here: GitHub bills each JOB rounded UP to the whole minute, so ten
20-second jobs cost ten minutes, not three. That is why splitting a suite into many tiny
jobs can cost more than it saves; the report shows billed minutes beside wall-clock.

Lint rules (each a cost the change never needed to pay; references/ci.md):
  CI1 no `concurrency:` with `cancel-in-progress: true` - superseded pushes run to the end
  CI2 a job with no `timeout-minutes:` - a hung test bills up to 6 hours
  CI3 a pull_request trigger with no `paths`/`paths-ignore` - docs-only changes run the suite
  CI4 no dependency cache (actions/cache, setup-* `cache:`, or setup-uv `enable-cache`)
Lint reads YAML as text (stdlib has no YAML parser): it reports a setting's absence, which
text search decides reliably; it never judges a value it would have to parse.

Examples:
  ci-audit.py cost --repo acme/widget --limit 50 --rates rates.json
  ci-audit.py cost --limit 30 --save runs.json && ci-audit.py cost --from-file runs.json --json
  ci-audit.py lint
  ci-audit.py lint .github/workflows/test.yml --json | jq '.data[] | .rule'
"""
import argparse
import glob
import json
import math
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime

SCHEMA = "claude-mods.test-engineering.ci-audit/v1"


def err(msg):
    print(f"ci-audit: {msg}", file=sys.stderr)


def gh_api(path):
    try:
        r = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=60,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        err(f"gh api {path}: timed out")
        sys.exit(7)
    if r.returncode != 0:
        msg = (r.stderr or "").strip()
        if "auth" in msg.lower() or "login" in msg.lower():
            err("gh is not logged in: run `gh auth login`")
            sys.exit(5)
        err(f"gh api {path}: {msg[:200]}")
        sys.exit(7)
    return json.loads(r.stdout)


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ") if s else None


def runner_os(job):
    labels = " ".join(job.get("labels") or []).lower()
    for k in ("windows", "macos", "ubuntu", "linux"):
        if k in labels:
            return "linux" if k == "ubuntu" else k
    return "self-hosted" if "self-hosted" in labels else "linux"


def fetch(repo, limit, workflow):
    runs, page = [], 1
    while len(runs) < limit:
        q = f"repos/{repo}/actions/runs?per_page={min(100, limit)}&page={page}"
        batch = gh_api(q).get("workflow_runs", [])
        if not batch:
            break
        runs += [r for r in batch if not workflow or r.get("name") == workflow]
        page += 1
    runs = runs[:limit]
    for i, r in enumerate(runs, 1):
        err(f"jobs {i}/{len(runs)}")
        r["jobs"] = gh_api(f"repos/{repo}/actions/runs/{r['id']}/jobs?per_page=100").get("jobs", [])
    return {"repo": repo, "runs": runs}


def cmd_cost(a):
    if a.from_file:
        try:
            with open(a.from_file, encoding="utf-8") as fh:
                doc = json.load(fh)
        except FileNotFoundError:
            err(f"not found: {a.from_file}")
            return 3
        except ValueError as e:
            err(f"not JSON: {a.from_file} ({e})")
            return 4
    else:
        if not shutil.which("gh"):
            err("gh CLI not found: install it from https://cli.github.com")
            return 5
        repo = a.repo or (subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "-q",
                                          ".nameWithOwner"], capture_output=True, text=True).stdout.strip())
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo or ""):
            err("could not tell which repo: pass --repo OWNER/NAME")
            return 2
        doc = fetch(repo, a.limit, a.workflow)
        if a.save:
            with open(a.save + ".tmp", "w", encoding="utf-8") as fh:
                json.dump(doc, fh)
            os.replace(a.save + ".tmp", a.save)
    rates = {}
    if a.rates:
        try:
            with open(a.rates, encoding="utf-8") as fh:
                rates = json.load(fh)
        except (OSError, ValueError) as e:
            err(f"--rates unreadable: {e}")
            return 4
    by_wf, by_os, by_pr = {}, {}, {}
    total_billed = total_wall = cancelled_billed = 0.0
    runs = doc.get("runs", [])
    for r in runs:
        billed = 0
        for j in r.get("jobs", []):
            s, e = ts(j.get("started_at")), ts(j.get("completed_at"))
            if not (s and e):
                continue
            mins = math.ceil(max(1, (e - s).total_seconds()) / 60)  # GitHub rounds each job up
            billed += mins
            o = runner_os(j)
            by_os[o] = by_os.get(o, 0) + mins
        s, e = ts(r.get("run_started_at") or r.get("created_at")), ts(r.get("updated_at"))
        wall = (e - s).total_seconds() / 60 if s and e else 0
        total_billed += billed
        total_wall += wall
        if r.get("conclusion") == "cancelled":
            cancelled_billed += billed
        w = by_wf.setdefault(r.get("name", "?"), {"workflow": r.get("name", "?"), "runs": 0, "billed_min": 0})
        w["runs"] += 1
        w["billed_min"] += billed
        prs = [p.get("number") for p in r.get("pull_requests") or []]
        key = f"#{prs[0]}" if prs else r.get("head_branch", "?")
        by_pr[key] = by_pr.get(key, 0) + billed
    cost = {o: round(m * rates[o], 2) for o, m in by_os.items() if o in rates}
    out = {
        "runs": len(runs),
        "billed_min": int(total_billed),
        "wall_min_per_run": round(total_wall / len(runs), 1) if runs else 0,
        "billed_min_per_run": round(total_billed / len(runs), 1) if runs else 0,
        "cancelled_billed_min": int(cancelled_billed),
        "by_os_min": by_os,
        "cost_usd": cost or None,
        "workflows": sorted(by_wf.values(), key=lambda w: -w["billed_min"]),
        "per_change": sorted(({"change": k, "billed_min": v} for k, v in by_pr.items()),
                             key=lambda x: -x["billed_min"])[:20],
    }
    if a.json:
        print(json.dumps({"data": out, "meta": {"schema": SCHEMA, "repo": doc.get("repo")}}, indent=2))
    else:
        for k in ("runs", "billed_min", "billed_min_per_run", "wall_min_per_run", "cancelled_billed_min"):
            print(f"{k}\t{out[k]}")
        for o, m in by_os.items():
            print(f"os\t{o}\t{m}\t{cost.get(o, '')}")
        for w in out["workflows"]:
            print(f"workflow\t{w['workflow']}\t{w['runs']}\t{w['billed_min']}")
    err(f"{len(runs)} runs, {int(total_billed)} billed min"
        + (f", ${sum(cost.values()):.2f}" if cost else " (pass --rates for $)"))
    return 0


def lint_file(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    lines = text.splitlines()
    findings = []
    add = lambda rule, why: findings.append({"rule": rule, "file": path, "why": why})
    # Only push/PR runs get superseded; a schedule-only or dispatch-only workflow has nothing to cancel.
    pushed = re.search(r"^\s*(push|pull_request(_target)?)\s*:|^on:\s*\[?.*\b(push|pull_request)\b", text, re.M)
    # Deploys and releases must never be cancelled half-way: for them, a concurrency group that
    # serialises runs is the fix, and cancel-in-progress would be the bug (references/ci.md).
    shipping = re.search(r"deploy|release|publish", os.path.basename(path), re.I) \
        or re.search(r"^name:.*\b(deploy|release|publish)", text, re.I | re.M) \
        or re.search(r"^\s+environment:", text, re.M)
    if pushed and shipping:
        if not re.search(r"^concurrency:", text, re.M):
            add("CI1", "deploy/release workflow with no concurrency group: overlapping runs race "
                       "(serialise them; keep cancel-in-progress false)")
    elif pushed and not re.search(r"^\s*cancel-in-progress:\s*(true|\$\{\{)", text, re.M):
        add("CI1", "no concurrency group with cancel-in-progress: superseded pushes run to the end")
    jobs_at = next((i for i, l in enumerate(lines) if re.match(r"^jobs:\s*$", l)), None)
    if jobs_at is not None:
        # Job keys sit at the first indent under `jobs:`; each job's block runs to the next one.
        ind = None
        blocks = []
        for i in range(jobs_at + 1, len(lines)):
            m = re.match(r"^(\s+)([\w-]+):\s*$", lines[i])
            if m and (ind is None or len(m.group(1)) == ind):
                ind = len(m.group(1))
                blocks.append([m.group(2), i])
            elif re.match(r"^\S", lines[i]):
                break
        for n, (name, start) in enumerate(blocks):
            end = blocks[n + 1][1] if n + 1 < len(blocks) else len(lines)
            body = "\n".join(lines[start:end])
            if "uses:" in body and re.search(r"^\s+uses:\s*\S+/\S+/\.github/workflows/", body, re.M):
                continue  # a reusable-workflow call: its timeout lives in the callee
            if "timeout-minutes:" not in body:
                add("CI2", f"job `{name}` has no timeout-minutes: a hang bills up to 6 hours")
    if re.search(r"^\s*pull_request(_target)?\s*:", text, re.M) and not re.search(r"^\s*paths(-ignore)?\s*:", text, re.M):
        add("CI3", "pull_request has no paths/paths-ignore filter: docs-only changes run everything")
    if re.search(r"(pytest|vitest|jest|phpunit|pest|go test|nextest|npm (ci|install)|composer install|uv sync)", text) \
            and not re.search(r"actions/cache@|\bcache:\s*['\"]?[\w-]|enable-cache:\s*true|cache-dependency-path", text):
        # \bcache: also matches flow style, `with: { node-version: 22, cache: npm }`
        add("CI4", "installs dependencies with no cache")
    return findings


def cmd_lint(a):
    files = a.files or sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
    if not files:
        err("no workflow files (run from the repo root, or name them)")
        return 3
    findings = []
    for f in files:
        if not os.path.isfile(f):
            err(f"not found: {f}")
            return 3
        findings += lint_file(f)
    if a.json:
        print(json.dumps({"data": findings, "meta": {"schema": SCHEMA, "files": len(files),
                                                     "count": len(findings)}}, indent=2))
    else:
        for f in findings:
            print(f"{f['rule']}\t{f['file']}\t{f['why']}")
    err(f"{len(findings)} finding(s) in {len(files)} workflow file(s)")
    return 10 if findings else 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cost")
    c.add_argument("--repo")
    c.add_argument("--limit", type=int, default=30)
    c.add_argument("--workflow")
    c.add_argument("--rates")
    c.add_argument("--from-file")
    c.add_argument("--save")
    c.add_argument("--json", action="store_true")
    l = sub.add_parser("lint")
    l.add_argument("files", nargs="*")
    l.add_argument("--json", action="store_true")
    a = p.parse_args()
    if a.cmd == "cost" and not 1 <= a.limit <= 1000:
        p.error("--limit must be 1..1000")
    return cmd_cost(a) if a.cmd == "cost" else cmd_lint(a)


if __name__ == "__main__":
    sys.exit(main())
