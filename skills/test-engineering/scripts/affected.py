#!/usr/bin/env python3
"""Run only the tests a change needs: map changed paths to test commands, fail safe to full.

Usage:   affected.py [--map .test-map.json] [--base REF] [--files PATH...] [--json]
Input:   a committed map (format below) and the change: `git diff --name-only <base>...HEAD`
         plus uncommitted and untracked files, or an explicit --files list (the test seam,
         and for CI systems that already know the changed files).
Output:  the commands to run, one per line, or --json with the mode and the reason for every
         command (schema claude-mods.test-engineering.affected/v1). Run them with your shell:
         `affected.py | while read -r cmd; do eval "$cmd" || exit 1; done`, or in CI from JSON.
Stderr:  the mode line (none / affected / full) and why.
Exit:    0 ok (including "nothing to run"), 2 usage, 3 map not found, 4 invalid map,
         5 git unavailable or the base ref unknown.

Use the ecosystem's selector where one exists (pytest-testmon, vitest --changed, jest
--changedSince, nx/turbo affected: references/speed.md). This is for the stacks with none:
shell suites, PHP, per-folder monorepos, anything with a "tests per package" layout.

Map format (.test-map.json):
  {
    "full":        "just check",                        # the safety net command
    "always_full": ["justfile", "tests/**", "*.lock"],  # changes no rule can scope
    "ignore":      ["**/*.md", "docs/**"],              # changes that need no test
    "rules": [
      {"paths": ["skills/*/**"], "run": "bash skills/{1}/tests/run.sh"},
      {"paths": ["hooks/**"],    "run": "bash tests/hooks.sh"}
    ]
  }
Glob syntax: `*` one path segment, `**` any depth; `{1}`, `{2}` in "run" are the segments
the rule's `*`s matched. Fail-safe rules, in order: a changed file under always_full -> full;
a changed file that is neither ignored nor matched by any rule -> full (an unmapped change
is exactly what selection misses); a matched command whose script no longer exists (a
deleted package: its importers may break) -> full; otherwise the union of matched commands.
Ignored files are skipped before rules match. Globs are anchored at the repo root: write
`**/*.lock`, not `*.lock`, to catch nested lockfiles.

Examples:
  affected.py --base origin/main
  affected.py --base origin/main --json | jq -r '.data.commands[]'
  affected.py --files skills/fleet-ops/SKILL.md README.md
"""
import argparse
import json
import os
import re
import subprocess
import sys

SCHEMA = "claude-mods.test-engineering.affected/v1"


def err(msg):
    print(f"affected: {msg}", file=sys.stderr)


def glob_re(g):
    """`*` = one segment (captured), `**` = any depth. Anchored, forward slashes."""
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif g.startswith("**", i):
            out += ".*"
            i += 2
        elif g[i] == "*":
            out += "([^/]*)"
            i += 1
        elif g[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(g[i])
            i += 1
    return re.compile("^" + out + "$")


def changed_files(base):
    def git(*args):
        r = subprocess.run(["git", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if r.returncode != 0:
            err(f"git {' '.join(args)}: {r.stderr.strip()[:200]}")
            sys.exit(5)
        return [l for l in r.stdout.splitlines() if l]
    try:
        files = git("diff", "--name-only", f"{base}...HEAD")
    except FileNotFoundError:
        err("git not found")
        sys.exit(5)
    files += git("diff", "--name-only", "HEAD")
    files += git("ls-files", "--others", "--exclude-standard")
    return sorted(set(files))


def load_map(path):
    try:
        with open(path, encoding="utf-8") as fh:
            m = json.load(fh)
    except FileNotFoundError:
        err(f"map not found: {path} (see --help for the format)")
        sys.exit(3)
    except ValueError as e:
        err(f"map is not JSON: {e}")
        sys.exit(4)
    if not isinstance(m.get("full"), str) or not isinstance(m.get("rules"), list):
        err('map needs "full" (a command) and "rules" (a list)')
        sys.exit(4)
    for r in m["rules"]:
        if not (isinstance(r, dict) and isinstance(r.get("paths"), list) and isinstance(r.get("run"), str)):
            err(f"bad rule (needs paths[] and run): {r}")
            sys.exit(4)
    return m


def plan(m, files, root):
    always = [glob_re(g) for g in m.get("always_full", [])]
    ignore = [glob_re(g) for g in m.get("ignore", [])]
    rules = [([glob_re(g) for g in r["paths"]], r["run"]) for r in m["rules"]]
    commands, why, unmapped = {}, {}, []
    for f in files:
        f = f.replace("\\", "/")
        if any(g.match(f) for g in always):
            return {"mode": "full", "commands": [m["full"]], "reasons": {m["full"]: [f"{f} is always-full"]}}
        if any(g.match(f) for g in ignore):
            continue  # ignore beats rules: a package README needs no package test run
        hit = False
        for globs, run in rules:
            for g in globs:
                mt = g.match(f)
                if mt:
                    cmd = run
                    for i, grp in enumerate(mt.groups(), 1):
                        cmd = cmd.replace("{%d}" % i, grp)
                    commands.setdefault(cmd, None)
                    why.setdefault(cmd, []).append(f)
                    hit = True
                    break
        if not hit:
            unmapped.append(f)
    if unmapped:
        return {"mode": "full", "commands": [m["full"]],
                "reasons": {m["full"]: [f"{u} matches no rule" for u in unmapped]}}
    kept = []
    for cmd in commands:
        # Drop a command whose script was deleted with its package: `bash skills/gone/tests/run.sh`.
        script = next((w for w in cmd.split() if "/" in w and os.path.splitext(w)[1] in (".sh", ".py", ".mjs", ".js", ".ps1")), None)
        if script and not os.path.exists(os.path.join(root, script)):
            # A deleted package can break whatever imported it, which no rule can scope.
            return {"mode": "full", "commands": [m["full"]],
                    "reasons": {m["full"]: [f"{script} is gone (deleted package?)"]}}
        kept.append(cmd)
    return {"mode": "affected" if kept else "none", "commands": kept, "reasons": {c: why[c] for c in kept}}


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--map", default=".test-map.json")
    p.add_argument("--base", default="origin/main")
    p.add_argument("--files", nargs="+")
    p.add_argument("--root", default=".", help="where command scripts are resolved (default: cwd)")
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    m = load_map(a.map)
    files = a.files if a.files is not None else changed_files(a.base)
    out = plan(m, files, a.root)
    out["changed"] = len(files)
    if a.json:
        print(json.dumps({"data": out, "meta": {"schema": SCHEMA}}, indent=2))
    else:
        for c in out["commands"]:
            print(c)
    first = next(iter(out["reasons"].values()), [""])[0] if out["reasons"] else ""
    err(f"{out['mode']}: {len(out['commands'])} command(s) for {len(files)} changed file(s)"
        + (f" ({first})" if out["mode"] == "full" else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
