#!/usr/bin/env python3
"""Verify a publish workflow's GitHub Action pins — SHA-pinned, commented, undrifted.

Mutable @vN action tags get hijacked (tj-actions, 2025), so every `uses:` must be
pinned to a full commit SHA with a trailing `# vX` comment. This is the §7
staleness verifier for the pypi-ops `assets/publish.yml` and any release workflow.

Usage:   check-action-pins.py [--offline | --live] [--json] <workflow.yml>
Input:   a GitHub Actions workflow file
Output:  stdout = per-action records (text, or --json envelope)
Stderr:  progress, the human summary
Exit:    0 all good, 2 usage, 3 file not found, 7 github-unreachable (live only),
         10 a problem found (unpinned/uncommented offline; SHA drift live)

  --offline (default)  structural: every external `uses:` is SHA-pinned + `# vX`
  --live               resolve each `# vX` tag via the GitHub API; flag when the
                       pinned SHA no longer matches that tag (retag / stale pin).
                       Honors GITHUB_TOKEN/GH_TOKEN for a higher rate limit.

Examples:
  check-action-pins.py --offline .github/workflows/publish.yml
  check-action-pins.py --live .github/workflows/publish.yml
  check-action-pins.py --live --json publish.yml | jq '.data[] | select(.ok==false)'
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

EXIT_OK, EXIT_USAGE, EXIT_NOTFOUND, EXIT_UNAVAIL, EXIT_FOUND = 0, 2, 3, 7, 10

# uses: owner/repo@<ref>            with optional trailing  # comment
USES_RE = re.compile(
    r"""^\s*-?\s*uses:\s*
        (?P<action>[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+)   # owner/repo[/path]
        @(?P<ref>[^\s#]+)                               # ref (sha or tag)
        (?:\s*\#\s*(?P<comment>.+?))?\s*$               # optional # comment
    """,
    re.VERBOSE,
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
TAGISH_RE = re.compile(r"\bv?\d+(?:\.\d+){0,2}\b")


def parse_uses(path: str) -> list[dict]:
    out = []
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            m = USES_RE.match(line.rstrip("\n"))
            if not m:
                continue
            action = m.group("action")
            # local (./.github/...) and docker:// actions are not pinnable tags
            if action.startswith(".") or "://" in action:
                continue
            out.append(
                {"line": i, "action": action, "ref": m.group("ref"),
                 "comment": (m.group("comment") or "").strip()}
            )
    return out


def gh_tag_sha(action: str, tag: str) -> tuple[str | None, str | None]:
    """Resolve owner/repo@tag -> commit sha via the GitHub API. Returns (sha, err)."""
    owner_repo = "/".join(action.split("/")[:2])
    url = f"https://api.github.com/repos/{owner_repo}/commits/{tag}"
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "claude-mods-pypi-ops",
    })
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            return json.load(resp).get("sha"), None
    except urllib.error.HTTPError as e:
        if e.code in (403, 429):
            return None, "rate-limited"
        if e.code == 404:
            return None, "tag-not-found"
        return None, f"http-{e.code}"
    except (urllib.error.URLError, TimeoutError, OSError):
        return None, "unreachable"


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description="Verify GitHub Action pins.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural checks only (default)")
    mode.add_argument("--live", action="store_true", help="resolve tags via the GitHub API")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope")
    ap.add_argument("workflow", help="path to a workflow .yml")
    args = ap.parse_args()

    if not os.path.isfile(args.workflow):
        print(f"ERROR: no such file: {args.workflow}", file=sys.stderr)
        return EXIT_NOTFOUND

    uses = parse_uses(args.workflow)
    live = args.live
    records, problem, unavailable = [], False, False

    if not uses:
        print("no external `uses:` actions found", file=sys.stderr)

    for u in uses:
        rec = {"action": u["action"], "ref": u["ref"], "line": u["line"], "ok": True, "note": ""}
        pinned = bool(SHA_RE.match(u["ref"]))
        comment_tag = TAGISH_RE.search(u["comment"])
        if not pinned:
            rec["ok"], rec["note"] = False, f"not SHA-pinned (ref={u['ref']}); pin to a 40-char commit SHA"
            problem = True
        elif comment_tag is None:
            rec["ok"], rec["note"] = False, "SHA-pinned but missing a `# vX` version comment"
            problem = True
        elif live:
            tag = comment_tag.group(0)
            sha, err = gh_tag_sha(u["action"], tag)
            if err:
                unavailable = True
                rec["note"] = f"live check skipped ({err})"
            elif sha and sha != u["ref"]:
                rec["ok"], rec["note"] = False, f"DRIFT: pin != {tag} (tag now {sha[:12]}…); retag or refresh the pin"
                problem = True
            else:
                rec["note"] = f"matches {tag}"
        else:
            rec["note"] = "pinned + commented"
        records.append(rec)
        if not args.json:
            mark = "ok" if rec["ok"] else "XX"
            print(f"  [{mark}] {rec['action']}@{rec['ref'][:12]}  {rec['note']}", file=sys.stderr)

    if args.json:
        print(json.dumps({
            "data": records,
            "meta": {"count": len(records), "mode": "live" if live else "offline",
                     "ok": not problem,
                     "schema": "claude-mods.pypi-ops.check-action-pins/v1"},
        }, indent=2))

    if problem:
        print("=== pin check FAILED ===", file=sys.stderr)
        return EXIT_FOUND
    if unavailable:
        print("=== structurally ok; some live checks were unavailable (advisory) ===", file=sys.stderr)
        return EXIT_UNAVAIL
    print("=== all action pins ok ===", file=sys.stderr)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
