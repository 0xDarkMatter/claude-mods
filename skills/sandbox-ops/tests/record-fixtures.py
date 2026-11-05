#!/usr/bin/env python3
"""Re-record the provider fixtures that tests/run.sh feeds the --live verifier.

Each fixture is a verbatim excerpt of a docs page: its title line plus every line that a
fact's pattern in assets/facts-providers.json matches, under a header comment. Re-record
after you change a fact (never hand-edit a fixture to make a case pass), and re-read the
page when you do. boat's fixtures (tests/fixtures/live/boat/) are older, hand-trimmed
excerpts of docs.boat.dev and are not touched here.

Usage:   record-fixtures.py [--provider NAME|all] [--pages-dir DIR] [--date YYYY-MM-DD]
Input:   argv only. Default: fetch each page's url from the catalogue. --pages-dir DIR
         reads <provider>__<page>.md from DIR instead, for a machine whose Python
         rejects a docs site's certificate chain (save the pages with curl first).
Output:  stdout = one line per fixture written. Data only.
Stderr:  errors.
Exit:    0 ok, 2 usage, 3 a page could not be read, 4 a fact matches nothing on its page
         (the fact has drifted: fix the catalogue, card and date before recording)

Examples:
  python tests/record-fixtures.py --provider e2b
  python tests/record-fixtures.py --pages-dir /tmp/pages --date 2026-11-05
"""
from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import urllib.request
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
CATALOGUE = SKILL / "assets" / "facts-providers.json"
OUT = SKILL / "tests" / "fixtures" / "live"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="record-fixtures.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--provider", default="all")
    ap.add_argument("--pages-dir")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    try:
        args = ap.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code not in (0, None) else 0
    provs = json.loads(CATALOGUE.read_text(encoding="utf-8"))["providers"]
    if args.provider != "all" and args.provider not in provs:
        print(f"record-fixtures: unknown provider {args.provider!r}", file=sys.stderr)
        return 2
    for name, p in provs.items():
        if args.provider not in ("all", name):
            continue
        for page, spec in p["pages"].items():
            try:
                if args.pages_dir:
                    text = (Path(args.pages_dir) / f"{name}__{page}.md").read_text(encoding="utf-8")
                else:
                    req = urllib.request.Request(spec["url"], headers={"User-Agent": "claude-mods-sandbox-ops-record/1"})
                    text = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")
            except (OSError, ValueError) as exc:
                print(f"record-fixtures: {name}/{page}: {exc}", file=sys.stderr)
                return 3
            lines = text.splitlines()
            keep = [l for l in lines if l.strip() == spec["title"].strip()][:1]
            for f in p["facts"]:
                if f["page"] != page:
                    continue
                hit = [l for l in lines if re.search(f["pattern"], l)]
                if not hit:  # a pattern that spans lines: keep the whole matched line span
                    m = re.search(f["pattern"], text)
                    if not m:
                        print(f"record-fixtures: {name}/{f['id']} matches nothing on {page}", file=sys.stderr)
                        return 4
                    hit = [text[text.rfind("\n", 0, m.start()) + 1: text.find("\n", m.end())]]
                if hit[0] not in keep:
                    keep.append(hit[0])
            out = OUT / name / f"{page}.md"
            out.parent.mkdir(parents=True, exist_ok=True)
            header = (f"<!-- Recorded excerpt of {spec['url']}, fetched {args.date}. Test input for "
                      "check-sandbox-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->")
            out.write_bytes(("\n".join([header] + keep) + "\n").encode("utf-8"))
            print(out.relative_to(SKILL))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
