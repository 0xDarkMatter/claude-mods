#!/usr/bin/env python3
"""Estate rollup: run pm-audit.py on many repo directories and group the findings by id.

Usage:   pm-rollup.py [--format md|json] [--as-of YYYY-MM-DD] [--facts FILE] DIR [DIR...]
         pm-rollup.py [--format md|json] --from FILE
Input:   argv: one or more local repo root directories, and/or --from FILE (one directory
         per line; blank lines and #-comments skipped; "-" reads stdin). Read-only, no
         network, no cloning - to audit a remote repo, sparse-clone just its manifests
         first (see "Cloning" below) and pass that directory.
Output:  stdout = the estate report: markdown (default) or JSON
         {"data": [{id, severity, repo_count, repos[]}...], "meta": {...}} with schema
         claude-mods.package-manager-ops.pm-rollup/v1. Data only.
Stderr:  one progress line per repo, the verdict line, errors.
Exit:    0 every repo audited clean, 2 usage, 3 --from file missing,
         10 findings OR a repo whose audit errored (a blind repo is not a clean estate)

Why it is a wrapper: pm-audit.py stays one repo, one root. The estate view is just that
tool run N times and pivoted by finding id, so a fix (one rule, many repos) can be
planned from one page. It locates pm-audit.py beside itself and runs it with the current
interpreter (sys.executable) - never `bash`, which on Windows can be WSL's.

Waivers: a repo's own `.pm-audit.json` (ignore[] entries with id/path/reason/until) is
listed, with expired ones marked, so a rollup shows which findings are being tolerated
and for how long. The file is only read here; pm-audit.py owns applying it.

Cloning (sparse, manifests only - choose the destination per your own layout):
  git clone --depth 1 --filter=blob:none --sparse <url> <dir>
  git -C <dir> sparse-checkout set --no-cone '/package.json' '/package-lock.json' \
      '/composer.json' '/composer.lock' '/.github/' '/.ddev/' '/Dockerfile*' '/.nvmrc'

Examples:
  bash scripts/run-python.sh scripts/pm-rollup.py ../site-a ../site-b
  bash scripts/run-python.sh scripts/pm-rollup.py --from repos.txt --format json | jq '.data[].id'
  ls -d ../*/ | bash scripts/run-python.sh scripts/pm-rollup.py --from -
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

EX_OK, EX_USAGE, EX_NOTFOUND, EX_FINDINGS = 0, 2, 3, 10
SCHEMA = "claude-mods.package-manager-ops.pm-rollup/v1"
# Guard: the sibling is found relative to THIS file, never via sys.path or ../.. - the
# skill folder is copied alone into other plugins and must keep working there.
AUDIT = Path(__file__).resolve().parent / "pm-audit.py"
# pm-audit exits 0 (clean) or 10 (findings) for a repo it could audit; anything else
# (2 usage, 3 missing path, 4 bad facts, a crash) means the repo was NOT audited.
AUDITED = (0, 10)
SEV_RANK = {"error": 0, "warn": 1}


def safe_streams():
    """WHY: piped stdout on Windows defaults to cp1252 and one non-ASCII repo name would
    raise halfway through the report; stdout is data, so UTF-8 always, and LF-only (text-mode
    CRLF would leave a stray CR in every line a pipeline consumer reads)."""
    for stream, kw in ((sys.stdout, {"encoding": "utf-8", "errors": "backslashreplace", "newline": "\n"}),
                       (sys.stderr, {"errors": "backslashreplace"})):
        reconfigure = getattr(stream, "reconfigure", None)
        try:
            if reconfigure:
                reconfigure(**kw)
        except ValueError:
            pass


def read_dir_list(src: str) -> list:
    text = sys.stdin.read() if src == "-" else Path(src).read_text(encoding="utf-8-sig")
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def audit_one(repo: str, extra: list) -> dict:
    """Run pm-audit on one repo; never raises - a failure becomes an `error` row."""
    try:
        proc = subprocess.run([sys.executable, str(AUDIT), "--json", *extra, repo],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"repo": repo, "error": {"exit": None, "message": str(exc)}}
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
    if proc.returncode not in AUDITED:
        # pm-audit prints a JSON error envelope for NOT_FOUND; the stderr tail is the
        # human message for everything else.
        msg = err[-1] if err else "no output"
        return {"repo": repo, "error": {"exit": proc.returncode, "message": msg}}
    try:
        doc = json.loads(out)
    except ValueError:
        return {"repo": repo, "error": {"exit": proc.returncode, "message": "unparseable pm-audit output"}}
    return {"repo": repo, "name": doc.get("meta", {}).get("root", Path(repo).name),
            "findings": doc.get("data", []), "meta": doc.get("meta", {})}


def waivers(repo: str, today: dt.date) -> list:
    """The repo's declared ignores, with an `expired` flag; [] when absent or unreadable
    (a malformed config is pm-audit's `config.invalid` finding, not the rollup's job)."""
    cfg = Path(repo) / ".pm-audit.json"
    try:
        doc = json.loads(cfg.read_text(encoding="utf-8-sig"))
        entries = doc.get("ignore", [])
        if not isinstance(entries, list):
            return []
    except (OSError, ValueError, AttributeError):
        return []
    out = []
    for e in entries:
        if not isinstance(e, dict) or "id" not in e:
            continue
        until = str(e.get("until", ""))
        try:
            expired = dt.date.fromisoformat(until) < today
        except ValueError:
            expired = False
        out.append({"id": e["id"], "path": e.get("path", ""), "reason": e.get("reason", ""),
                    "until": until, "expired": expired})
    return out


def pivot(results: list) -> list:
    by_id = {}
    for r in results:
        if "error" in r:
            continue
        for f in r["findings"]:
            slot = by_id.setdefault(f["id"], {"id": f["id"], "severity": f.get("severity", "warn"), "repos": {}})
            slot["repos"].setdefault(r["name"], 0)
            slot["repos"][r["name"]] += 1
            if SEV_RANK.get(f.get("severity"), 2) < SEV_RANK.get(slot["severity"], 2):
                slot["severity"] = f["severity"]
    rows = [{"id": s["id"], "severity": s["severity"], "repo_count": len(s["repos"]),
             "repos": sorted(s["repos"])} for s in by_id.values()]
    rows.sort(key=lambda r: (SEV_RANK.get(r["severity"], 2), -r["repo_count"], r["id"]))
    return rows


def render_md(rows: list, results: list, wv: dict) -> str:
    ok = [r for r in results if "error" not in r]
    bad = [r for r in results if "error" in r]
    clean = [r["name"] for r in ok if not r["findings"]]
    total = sum(len(r["findings"]) for r in ok)
    lines = ["# Package-manager estate rollup", "",
             f"{len(results)} repo(s): {len(ok)} audited, {len(clean)} clean, "
             f"{len(ok) - len(clean)} with findings ({total} finding(s)), {len(bad)} errored.", ""]
    for row in rows:
        lines += [f"## {row['id']} ({row['severity']})", "",
                  "| Repos | Repo list |", "|---|---|",
                  f"| {row['repo_count']} | {', '.join(row['repos'])} |", ""]
    if clean:
        lines += ["## Clean", "", ", ".join(sorted(clean)), ""]
    if any(wv.values()):
        lines += ["## Waivers", "", "| Repo | Id | Path | Until | Status |", "|---|---|---|---|---|"]
        for repo in sorted(wv):
            for w in wv[repo]:
                status = "EXPIRED" if w["expired"] else "active"
                lines.append(f"| {repo} | {w['id']} | {w['path'] or '*'} | {w['until']} | {status} |")
        lines.append("")
    if bad:
        lines += ["## Errored (not audited)", "", "| Repo | Exit | Message |", "|---|---|---|"]
        for r in bad:
            lines.append(f"| {r['repo']} | {r['error']['exit']} | {r['error']['message']} |")
        lines.append("")
    return "\n".join(lines)


def main(argv: list) -> int:
    safe_streams()
    p = argparse.ArgumentParser(
        prog="pm-rollup.py",
        description="Run pm-audit.py on many repo directories and group findings by id (read-only, no network).",
        epilog="Examples:\n"
               "  bash scripts/run-python.sh scripts/pm-rollup.py ../site-a ../site-b\n"
               "  bash scripts/run-python.sh scripts/pm-rollup.py --from repos.txt --format json\n\n"
               "Exit: 0 clean, 2 usage, 3 --from file missing, 10 findings or an errored repo",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("dirs", nargs="*", help="repo root directories to audit")
    p.add_argument("--from", dest="from_file", metavar="FILE", help="file listing one repo directory per line ('-' = stdin)")
    p.add_argument("--format", choices=("md", "json"), default="md", help="report format (default md)")
    p.add_argument("--as-of", default=None, help="date for end-of-life and waiver-expiry checks (default: today, UTC)")
    p.add_argument("--facts", default=None, help="facts catalogue JSON, passed through to pm-audit.py")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    try:
        today = dt.date.fromisoformat(args.as_of) if args.as_of else dt.datetime.now(dt.timezone.utc).date()
    except ValueError:
        print(f"error: --as-of wants YYYY-MM-DD, got {args.as_of!r}", file=sys.stderr)
        return EX_USAGE
    repos = list(args.dirs)
    if args.from_file:
        try:
            repos += read_dir_list(args.from_file)
        except OSError as exc:
            print(f"error: cannot read --from file: {exc}", file=sys.stderr)
            return EX_NOTFOUND
    if not repos:
        print("error: give at least one repo directory or --from FILE", file=sys.stderr)
        return EX_USAGE
    if not AUDIT.is_file():
        print(f"error: sibling pm-audit.py not found at {AUDIT}", file=sys.stderr)
        return EX_NOTFOUND
    extra = ["--as-of", today.isoformat()]
    if args.facts:
        extra += ["--facts", args.facts]
    results = []
    for repo in repos:
        r = audit_one(repo, extra)
        results.append(r)
        state = f"error (exit {r['error']['exit']})" if "error" in r else f"{len(r['findings'])} finding(s)"
        print(f"pm-rollup: {repo}: {state}", file=sys.stderr)
    rows = pivot(results)
    wv = {r["name"]: waivers(r["repo"], today) for r in results if "error" not in r}
    bad = [r for r in results if "error" in r]
    if args.format == "json":
        print(json.dumps({"data": rows,
                          "meta": {"schema": SCHEMA, "as_of": today.isoformat(), "repos": len(results),
                                   "errored": [{"repo": r["repo"], **r["error"]} for r in bad],
                                   "waivers": {k: v for k, v in wv.items() if v}}}, indent=2))
    else:
        print(render_md(rows, results, wv))
    if rows or bad:
        print(f"pm-rollup: {len(rows)} finding id(s) across {len(results)} repo(s); {len(bad)} errored", file=sys.stderr)
        return EX_FINDINGS
    print(f"pm-rollup: clean across {len(results)} repo(s)", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
