#!/usr/bin/env python3
"""Skill hygiene ratchet: four ways a skill quietly stops working as written.

  orphan-side-file      a file under references/, assets/ or scripts/ that the skill's own
                        SKILL.md never names. The router only finds what SKILL.md points to
                        (SKILL-RESOURCE-PROTOCOL section 1), so an unnamed file is dead weight.
                        Naming a folder (`assets/grids/`) names the files in it, and paths with
                        an underscore-prefixed part (`scripts/_lib/`) are internal helpers that
                        scripts load, so they are exempt.
  related-not-named     a `metadata.related-skills` entry the SKILL.md body never mentions.
                        Frontmatter metadata is not shown to the model, so a hand-off that is
                        only listed there never happens.
  relative-script-call  the body runs `scripts/...` relative to the current directory
                        (`python scripts/x.py`). Run from a project root that fails with exit
                        127, or worse, runs the project's own scripts/x.py (docker/skills #102).
                        Write "<skill-dir>/scripts/x.py" instead.
  owns-duplicate        two skills claim the same `metadata.owns` token. Overlapping scopes
                        misroute, so ownership must be unique. Hard fail, never baselined.

The first three are a RATCHET against tests/skill-hygiene-baseline.txt, which holds the
violations that existed when the gate arrived (2026-10-07). A violation not in the baseline
fails (new debt). A baseline line that no longer matches a violation also fails (it was fixed,
so delete the line), so the list only shrinks. Baseline format: one `skill<TAB>check<TAB>key`
per line, sorted; `#` comments allowed.

Usage:   skill-hygiene.py [--skills DIR] [--baseline FILE] [--report] [--write-baseline]
Output:  stdout = one line per problem (NEW / FIXED / DUPLICATE), and with --report every
         current violation. Data only.
Stderr:  the verdict line.
Exit:    0 no new violations and no stale baseline lines, 1 new violations, stale baseline
         lines or duplicate owns, 2 usage or nothing to scan

Examples:
  python tests/skill-hygiene.py                      # the gate (bash tests/skill-hygiene.sh runs it)
  python tests/skill-hygiene.py --report             # every violation, baselined or not
  python tests/skill-hygiene.py --write-baseline     # after FIXING things: rewrite the list
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKS = ("orphan-side-file", "related-not-named", "relative-script-call")
SIDE_DIRS = ("references", "assets", "scripts")
SKIP_FILES = {".gitkeep", ".DS_Store"}
# An interpreter (or ./) directly followed by scripts/: a path relative to whatever the cwd is.
RELATIVE_RE = re.compile(r"(?:^|[\s`(])(?:python3?|py|bash|sh|pwsh|node|uv run|\./)\s+\"?(scripts/[^\s\"'`)]+)")
# Lines that already anchor the path somewhere stable.
ANCHORED_RE = re.compile(r"<skill-dir>|\$\{?CLAUDE_SKILL_DIR|SKILL_DIR|\$HOME/\.claude|~/\.claude")


def split_frontmatter(text: str):
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text.replace("\r\n", "\n"), re.S)
    return (m.group(1), m.group(2)) if m else ("", text)


def list_field(fm: str, name: str):
    m = re.search(rf"^\s*{re.escape(name)}:\s*(.+)$", fm, re.M)
    if not m:
        return []
    raw = m.group(1).strip().strip("\"'").strip("[]")
    return [x.strip().strip("\"' ") for x in raw.split(",") if x.strip().strip("\"' ")]


def scan(skills_dir: Path):
    violations, owners = set(), defaultdict(list)
    skills = sorted(p for p in skills_dir.iterdir() if (p / "SKILL.md").is_file())
    for s in skills:
        text = (s / "SKILL.md").read_text(encoding="utf-8", errors="replace")
        fm, body = split_frontmatter(text)
        for sub in SIDE_DIRS:
            d = s / sub
            if not d.is_dir():
                continue
            for f in sorted(d.rglob("*")):
                if not f.is_file() or f.name in SKIP_FILES or "__pycache__" in f.parts:
                    continue
                rel = f.relative_to(s).as_posix()
                parts = rel.split("/")
                if any(p.startswith("_") for p in parts[1:]):
                    continue
                folders = ["/".join(parts[:k]) + "/" for k in range(2, len(parts))]
                if rel not in text and f.name not in text and not any(d in text for d in folders):
                    violations.add((s.name, "orphan-side-file", rel))
        for other in list_field(fm, "related-skills"):
            if not re.search(rf"(?<![\w-]){re.escape(other)}(?![\w-])", body):
                violations.add((s.name, "related-not-named", other))
        for line in body.splitlines():
            if ANCHORED_RE.search(line):
                continue
            for m in RELATIVE_RE.finditer(line):
                violations.add((s.name, "relative-script-call", m.group(1).rstrip(".,;:")))
        for token in list_field(fm, "owns"):
            owners[token].append(s.name)
    duplicates = {t: names for t, names in owners.items() if len(names) > 1}
    return skills, violations, duplicates


def read_baseline(path: Path):
    out = set()
    if not path.is_file():
        return out
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or parts[1] not in CHECKS:
            print(f"error: {path.name}:{n}: want skill<TAB>check<TAB>key with a known check", file=sys.stderr)
            raise SystemExit(2)
        out.add(tuple(parts))
    return out


def write_baseline(path: Path, rows) -> None:
    # LF on every OS, so a rewrite on Windows doesn't turn the whole file into a CRLF diff.
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(HEADER + "".join("\t".join(v) + "\n" for v in sorted(rows)))


HEADER = ("# Skill hygiene baseline - violations that predate tests/skill-hygiene.py (2026-10-07).\n"
          "# The list may only shrink: fix one, then delete its line (the gate fails until you do).\n"
          "# Never add a line to silence a new violation; fix the skill instead.\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="skill-hygiene.py", description=(__doc__ or "").split("\n\n", 1)[0],
                                 epilog="EXAMPLES:\n  python tests/skill-hygiene.py\n  python tests/skill-hygiene.py --report",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--skills", type=Path, default=ROOT / "skills")
    ap.add_argument("--baseline", type=Path, default=ROOT / "tests" / "skill-hygiene-baseline.txt")
    ap.add_argument("--report", action="store_true", help="also list every current violation")
    ap.add_argument("--write-baseline", action="store_true",
                    help="rewrite the baseline to the current violations (refuses to grow it)")
    ap.add_argument("--init-baseline", action="store_true",
                    help="create the baseline from the current violations; only when none exists yet")
    opts = ap.parse_args(argv)
    if not opts.skills.is_dir():
        print(f"error: no skills directory at {opts.skills}", file=sys.stderr)
        return 2
    skills, current, duplicates = scan(opts.skills)
    if not skills:
        print(f"error: no SKILL.md under {opts.skills}", file=sys.stderr)
        return 2
    if opts.init_baseline:
        if opts.baseline.exists():
            print(f"error: {opts.baseline} already exists; use --write-baseline after fixing things",
                  file=sys.stderr)
            return 2
        write_baseline(opts.baseline, current)
        print(f"skill-hygiene: baseline created, {len(current)} line(s)", file=sys.stderr)
        return 0
    baseline = read_baseline(opts.baseline)
    new = sorted(current - baseline)
    fixed = sorted(baseline - current)
    if opts.write_baseline:
        if new:
            print(f"error: refusing to grow the baseline: {len(new)} new violation(s); fix them first",
                  file=sys.stderr)
            for v in new:
                print("NEW\t" + "\t".join(v))
            return 1
        write_baseline(opts.baseline, current)
        print(f"skill-hygiene: baseline rewritten, {len(current)} line(s) ({len(fixed)} removed)", file=sys.stderr)
        return 0
    for v in new:
        print("NEW\t" + "\t".join(v))
    for v in fixed:
        print("FIXED\t" + "\t".join(v) + "\t(delete this line from the baseline)")
    for token, names in sorted(duplicates.items()):
        print(f"DUPLICATE\towns\t{token}\t{', '.join(names)}")
    if opts.report:
        for v in sorted(current):
            print("CURRENT\t" + "\t".join(v))
    counts = {c: sum(1 for v in current if v[1] == c) for c in CHECKS}
    summary = ", ".join(f"{n} {c}" for c, n in counts.items())
    if new or fixed or duplicates:
        print(f"skill-hygiene: FAIL - {len(new)} new, {len(fixed)} fixed but still baselined, "
              f"{len(duplicates)} duplicate owns ({summary} in {len(skills)} skills)", file=sys.stderr)
        return 1
    print(f"skill-hygiene: ok - no new violations; baseline holds {summary} in {len(skills)} skills", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
