#!/usr/bin/env python3
"""fake-gh - a stand-in `gh` for the agents-md survey tests. Test fixture, not a tool.

Usage:   AGENTS_MD_GH=fake-gh.py FAKE_GH_FIXTURE=fixture.json FAKE_GH_LOG=calls.jsonl \
           agents-md.py survey --org acme
Input:   FAKE_GH_FIXTURE: {"repos": {owner: [{nameWithOwner, defaultBranchRef, isArchived}]},
         "api": {"<path as requested>": <JSON response>}, "fail_repo_list": bool}
Output:  what real gh prints: JSON on stdout; a 404 body plus exit 1 for unknown paths
Stderr:  gh-style error lines
Exit:    0 served, 1 not found / failure, 2 a subcommand this fake doesn't serve

Every call is appended to FAKE_GH_LOG as a JSON argv list, so the suite can prove the
survey only ever reads (no -X/--method/-f/-F/--input, nothing but `repo list` and `api`).

Examples:
  FAKE_GH_FIXTURE=f.json fake-gh.py api repos/acme/site
  FAKE_GH_FIXTURE=f.json fake-gh.py repo list acme --json nameWithOwner --no-archived
"""
import json
import os
import sys


def main() -> int:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    log = os.environ.get("FAKE_GH_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(args) + "\n")
    with open(os.environ["FAKE_GH_FIXTURE"], encoding="utf-8") as fh:
        fx = json.load(fh)
    if args[:2] == ["repo", "list"] and len(args) > 2:
        if fx.get("fail_repo_list"):
            print("gh: HTTP 401: Bad credentials", file=sys.stderr)
            return 1
        repos = fx.get("repos", {}).get(args[2], [])
        if "--no-archived" in args:
            repos = [r for r in repos if not r.get("isArchived")]
        print(json.dumps(repos))
        return 0
    if args[:1] == ["api"]:
        path = [a for a in args[1:] if not a.startswith("-")][-1]
        if path in fx.get("api", {}):
            print(json.dumps(fx["api"][path]))
            return 0
        print(json.dumps({"message": "Not Found", "status": "404"}))
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        return 1
    print(f"fake-gh: unsupported: {args}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
