#!/usr/bin/env python3
"""Report what Linear would do with the issue references in PR or commit text.

"Fixes ENG-123" closes the issue when the PR merges; "Part of ENG-123" does not. Agents
write these words casually, so this reads the text before it is sent. Word lists are from
https://linear.app/docs/github.md and /docs/gitlab.md, seen 2026-11-05. Facts about which
surfaces link are Linear's; this script's prose matching is an approximation of theirs.

Effects reported per reference:
  closing          a closing word; the issue completes on merge
  negated-closing  closing word after "not"/"never"/"don't": unverified, so reword it
  non-closing      linked; moves status but does not apply the on-merge status
  relation         marks the issues as related only
  opt-out          skip/ignore: stops a branch name linking the issue
  create           ENG-NEW: creates and links an issue
  bare             an id with no magic word: this text alone does not link it
  ignored          --kind comment: magic words in PR comments do not link

Usage:   scan-magic-words.py [--kind pr|commit|comment] [--gitlab] [--json] [FILE ... | -]
Input:   files, or stdin when none is given or FILE is "-".
Output:  stdout = rows (source, line, effect, id, word) or a --json envelope. Data only.
Stderr:  the verdict line and errors.
Exit:    0 nothing would close, 2 usage, 3 file not found,
         10 at least one closing or negated-closing reference (a signal, not an error)

Examples:
  scan-magic-words.py --kind pr pr-body.md
  git log -1 --format=%B | scan-magic-words.py --kind commit -
  scan-magic-words.py --json pr-body.md | jq '.data[] | select(.effect=="closing")'
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_SIGNAL = 10

CLOSING = ("close closes closed closing fix fixes fixed fixing resolve resolves resolved resolving "
           "complete completes completed completing implement implements implemented implementing").split()
NON_CLOSING = ["ref", "refs", "references", "part of", "contributes to", "toward", "towards"]
RELATION = ["relates to", "related to"]
OPT_OUT = ["skip", "ignore"]

# Team keys are short, uppercase-led and case-sensitive here on purpose: `sha-256` and `utf-8` are not
# issues. `SHA-256` and `UTF-8` still match, and read as harmless `bare` rows unless a magic word precedes.
ISSUE = r"[A-Z][A-Z0-9]{0,6}-(?:\d+|NEW)"
LIST_SEP = r"(?:\s*(?:,|&|\band\b)\s*)+"
ID_LIST = rf"{ISSUE}(?:{LIST_SEP}{ISSUE})*"
ISSUE_RE = re.compile(ISSUE)
NEGATION_RE = re.compile(r"(?:\bnot|\bnever|n't)\s+(?:\w+\s+)?$", re.IGNORECASE)


def build_pattern(gitlab: bool) -> re.Pattern:
    words: dict[str, str] = {w: "closing" for w in CLOSING}
    words["linear issue"] = "closing"
    words.update({w: "non-closing" for w in NON_CLOSING + (["updates"] if gitlab else [])})
    words.update({w: "relation" for w in RELATION})
    words.update({w: "opt-out" for w in OPT_OUT})
    build_pattern.effects = words  # type: ignore[attr-defined]
    # Longest first, so "part of" and "linear issue" win over shorter overlaps.
    alternatives = "|".join(sorted((re.escape(w).replace(r"\ ", r"\s+") for w in words), key=len, reverse=True))
    return re.compile(rf"(?<![\w-])({alternatives})\s*:?\s+({ID_LIST})", re.IGNORECASE)


def scan(text: str, source: str, kind: str, pattern: re.Pattern) -> list[dict]:
    effects: dict[str, str] = build_pattern.effects  # type: ignore[attr-defined]
    rows: list[dict] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        taken: set[int] = set()
        for m in pattern.finditer(line):
            word = re.sub(r"\s+", " ", m.group(1).lower())
            effect = effects[word]
            for idm in ISSUE_RE.finditer(m.group(2)):
                start = m.start(2) + idm.start()
                taken.add(start)
                final = effect
                if effect == "closing" and NEGATION_RE.search(line[: m.start(1)]):
                    final = "negated-closing"
                if idm.group().endswith("-NEW") and effect in ("closing", "non-closing"):
                    final = "closing" if final != "negated-closing" and effect == "closing" else "create"
                if kind == "comment":
                    final = "ignored"
                rows.append({"source": source, "line": lineno, "effect": final, "id": idm.group(), "word": word})
        for idm in ISSUE_RE.finditer(line):
            if idm.start() in taken:
                continue
            if idm.group().endswith("-NEW"):
                final = "ignored" if kind == "comment" else "create"
            else:
                final = "ignored" if kind == "comment" else "bare"
            rows.append({"source": source, "line": lineno, "effect": final, "id": idm.group(), "word": ""})
    rows.sort(key=lambda r: (r["source"], r["line"]))
    return rows


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="scan-magic-words.py",
        description="Report what Linear would do with the issue references in PR or commit text.",
        epilog=(
            "Examples:\n"
            "  scan-magic-words.py --kind pr pr-body.md\n"
            "  git log -1 --format=%B | scan-magic-words.py --kind commit -\n"
            "  scan-magic-words.py --json pr-body.md | jq '.data[]'\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("files", nargs="*", help="files to read; '-' or nothing reads stdin")
    p.add_argument("--kind", choices=["pr", "commit", "comment"], default="pr", help="where the text will go")
    p.add_argument("--gitlab", action="store_true", help="use GitLab's word list and linking rules")
    p.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    pattern = build_pattern(args.gitlab)
    # GitLab does not link from commit messages or comments, per its docs page.
    kind = "comment" if args.gitlab and args.kind == "commit" else args.kind

    rows: list[dict] = []
    for name in args.files or ["-"]:
        if name == "-":
            rows += scan(sys.stdin.read(), "<stdin>", kind, pattern)
            continue
        path = Path(name)
        if not path.is_file():
            print(f"error: file not found: {name}", file=sys.stderr)
            return EX_NOTFOUND
        rows += scan(path.read_text(encoding="utf-8", errors="replace"), name, kind, pattern)

    if args.json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "kind": kind,
                                                 "schema": "claude-mods.linear-ops.magic-words/v1"}}, indent=2))
    else:
        for r in rows:
            print(f"{r['source']}\t{r['line']}\t{r['effect']}\t{r['id']}\t{r['word']}")

    closing = [r["id"] for r in rows if r["effect"] in ("closing", "negated-closing")]
    if closing:
        print(f"scan-magic-words: would close on merge: {', '.join(sorted(set(closing)))}", file=sys.stderr)
        return EX_SIGNAL
    print(f"scan-magic-words: nothing would close ({len(rows)} references)", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
