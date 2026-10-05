#!/usr/bin/env bash
# Offline self-test for frontend-upgrade-ops - the port-friendly shape contract,
# intra-skill link integrity, and the staleness-verifier contract
# (SKILL-RESOURCE-PROTOCOL.md §7, §10).
#
# Offline-deterministic (no network, no npm install). Resolves paths relative to
# itself so it works in the repo and once installed to ~/.claude/skills/.
#
# FRONTMATTER CONTRACT - this suite asserts on SKILL.md's own frontmatter shape:
#   * top-level keys limited to the six Agent Skills spec fields (no when_to_use)
#   * description <= 500 chars and contains "Use when"
# Those limits are what keep the skill portable as one unit; a trim or spec-alignment
# pass that edits the frontmatter must keep them, or change this suite in the same
# commit. (docs/SKILL-CREATION-PROTOCOL.md, Step 5.)
#
# Usage:   bash tests/run.sh
#          SKILL_DIR=/path/to/a/copy bash tests/run.sh   # prove a guard fails on a broken copy
# Input:   none (self-contained; no network)
# Output:  PASS/FAIL rows on stderr; final tally line.
# Exit:    0 all pass, 1 any failure
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${SKILL_DIR:-$(dirname "$HERE")}"
DOC="$SKILL/SKILL.md"
V="$SKILL/scripts/check-frontend-upgrade-facts.py"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1" >&2; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; }

# A *working* python: on Windows `python3` can be a Store stub that exits nonzero.
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done

echo "=== frontend-upgrade-ops self-test ($SKILL) ===" >&2

[[ -f "$DOC" ]] && ok "SKILL.md present" || { no "SKILL.md missing"; echo "=== $PASS passed, $FAIL failed ===" >&2; exit 1; }
[[ -n "$PY" ]] || { no "no working python - cannot run the shape checks"; echo "=== $PASS passed, $FAIL failed ===" >&2; exit 1; }

# -- shape contract: frontmatter, budgets, reference sizes, citations, anchors --------
# One python pass emits "PASS|msg" / "FAIL|msg" rows so bash keeps the tally.
while IFS='|' read -r verdict msg; do
  [[ "$verdict" == PASS ]] && ok "$msg" || no "$msg"
done < <("$PY" - "$SKILL" <<'PY'
import re, sys
from pathlib import Path

skill = Path(sys.argv[1])
text = (skill / "SKILL.md").read_text(encoding="utf-8")
def row(ok, msg): print(f"{'PASS' if ok else 'FAIL'}|{msg}")

parts = text.split("---", 2)
fm, body = (parts[1], parts[2]) if len(parts) == 3 else ("", text)
keys = re.findall(r"^([A-Za-z_-]+):", fm, re.M)
spec = {"name", "description", "license", "compatibility", "allowed-tools", "metadata"}
row(set(keys) <= spec, f"frontmatter keys are Agent Skills spec only ({', '.join(keys)})")
row(re.search(r"^name: frontend-upgrade-ops\s*$", fm, re.M) is not None, "name: frontend-upgrade-ops")
row(re.search(r"^license: MIT\s*$", fm, re.M) is not None, "license: MIT")
m = re.search(r'^description: "(.*)"\s*$', fm, re.M)
desc = m.group(1) if m else ""
row(0 < len(desc) <= 500, f"description <= 500 chars ({len(desc)})")
row("Use when" in desc, 'description carries a "Use when" clause')

# Token rule (coordinator, 2026-10-05): Claude Code keeps the first 5,000 tokens of an
# invoked skill after compaction, so the body must fit. chars/3.6 is the estimate.
est = round(len(body) / 3.6)
row(est <= 5000, f"SKILL.md body <= ~5000 est. tokens ({est})")
row(re.search(r"as of 20\d\d", body) is not None, "dated 'as of <year>' currency note")

refs = sorted((skill / "references").glob("*.md"))
row(len(refs) > 0, f"{len(refs)} reference file(s)")
for ref in refs:
    lines = ref.read_text(encoding="utf-8").splitlines()
    row(len(lines) <= 300, f"{ref.name} <= 300 lines ({len(lines)})")
    if len(lines) > 100:
        row(any(l.strip() == "## Contents" for l in lines[:20]),
            f"{ref.name} has a '## Contents' TOC near the top (>100 lines)")
    row(f"references/{ref.name}" in text, f"{ref.name} cited from SKILL.md")

# Every relative link inside the skill resolves, including #anchors (GitHub slug rules):
# a renamed heading silently breaks a deep link from SKILL.md's checklist.
def slugs(md):
    out = set()
    for h in re.findall(r"^#{1,6} (.+)$", md, re.M):
        s = re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-")
        out.add(s)
    return out
bad = []
for f in [skill / "SKILL.md", *refs]:
    md = f.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)\s]+)\)", md):
        if re.match(r"[a-z]+:", target):
            continue
        path, _, anchor = target.partition("#")
        dest = (f.parent / path).resolve() if path else f
        if not dest.exists():
            bad.append(f"{f.name} -> {target} (missing file)")
        elif anchor and dest.suffix == ".md" and anchor not in slugs(dest.read_text(encoding="utf-8")):
            bad.append(f"{f.name} -> {target} (missing anchor)")
row(not bad, "all relative links + anchors resolve" + (f": {bad}" if bad else ""))
PY
)

# -- resources present + cited -------------------------------------------------------
for res in assets/frontend-upgrade-facts.json scripts/check-frontend-upgrade-facts.py; do
  [[ -f "$SKILL/$res" ]] && ok "resource present: $res" || no "missing resource: $res"
  grep -q "$res" "$DOC" && ok "cited from SKILL.md: $res" || no "uncited: $res"
done

# -- staleness verifier: offline contract (§7) --------------------------------------
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [[ "$got" == "$want" ]] && ok "$lbl (exit $got)" || no "$lbl (want $want got $got)"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ec 0 "verifier py_compile"           "$PY" -m py_compile "$V"
ec 0 "verifier --help"               "$PY" "$V" --help
ec 0 "verifier --offline consistent" "$PY" "$V" --offline --skill "$SKILL" --facts "$SKILL/assets/frontend-upgrade-facts.json"
ec 2 "bad flag -> 2"                 "$PY" "$V" --bogus
ec 2 "conflicting modes -> 2"        "$PY" "$V" --offline --live
ec 3 "missing facts -> 3"            "$PY" "$V" --offline --facts "$TMP/nope.json"
jout="$("$PY" "$V" --offline --json --skill "$SKILL" 2>/dev/null)"
case "$jout" in *"claude-mods.frontend-upgrade-ops.facts/v1"*) ok "--json envelope schema";; *) no "--json envelope schema missing";; esac
S='"schema":"claude-mods.frontend-upgrade-ops.facts/v1"'
printf '{%s,"packages":{"zzz":{"documented_major":1,"prose":["zzznotreal"]}}}' "$S" > "$TMP/pkg.json"
ec 10 "uncited package -> 10"        "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/pkg.json"
printf '{%s,"packages":{"vite":{"documented_major":8,"prose":["Vite 8"]}},"dated_facts":{"x":"31 Smarch 1999"}}' "$S" > "$TMP/dated.json"
ec 10 "unstated dated fact -> 10"    "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/dated.json"
printf '{%s,"packages":{"vite":{"documented_major":"8","prose":["Vite 8"]}}}' "$S" > "$TMP/badtype.json"
ec 4 "non-integer major -> 4"        "$PY" "$V" --offline --facts "$TMP/badtype.json"

# The live path's peer-range parser decides whether the sequencing advice is stale;
# test it offline so a regex slip can't make --live permanently green.
peer="$(cd "$(dirname "$V")" && "$PY" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("v", "check-frontend-upgrade-facts.py")
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
cases = {"^3.0.0 || ^4.0.0 || ^5.0.0 || ^6.0.0 || ^7.0.0": 7, "^8.0.0": 8, ">=7.0.0": None, "*": None}
bad = [k for k, want in cases.items() if v.peer_max_major(k) != want]
print("ok" if not bad else "bad:" + ";".join(bad))' 2>&1)"
[[ "$peer" == ok ]] && ok "peer-range parser (^, ||, open-ended)" || no "peer-range parser: $peer"

echo "=== $PASS passed, $FAIL failed ===" >&2
[[ "$FAIL" -eq 0 ]] || exit 1
