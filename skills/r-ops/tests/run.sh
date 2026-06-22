#!/usr/bin/env bash
# Self-test for the r-ops skill (knowledge skill — no scripts to exercise).
#
# Offline-deterministic (no network, no R install required). Asserts structural
# integrity (frontmatter, references present + linked) and — the load-bearing
# check — a CONTENT-CURRENCY GUARD: the skill claims to lead with modern R
# idioms and to have shed the superseded ones, so this suite fails if a future
# edit reintroduces a deprecated tidyverse idiom as a recommendation or strips
# the modern stance. That turns the "reflects current R" promise into something
# CI enforces. Resolves paths relative to itself so it works in the repo and
# once installed to ~/.claude/skills/r-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
DOC="$SKILL/SKILL.md"
REF="$SKILL/references"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
has() { case "$2" in *"$1"*) ok "$3";; *) no "$3 (missing '$1')";; esac; }

echo "=== r-ops self-test ==="

# ── SKILL.md frontmatter ───────────────────────────────────────────────────
echo "-- frontmatter --"
[[ -f "$DOC" ]] && ok "SKILL.md present" || { no "SKILL.md missing"; echo "=== $PASS passed, $FAIL failed ==="; exit 1; }
fm="$(sed -n '1,/^---$/{/^---$/!p}' "$DOC" 2>/dev/null)"
# first line must be the opening fence
[[ "$(sed -n '1p' "$DOC")" == "---" ]] && ok "frontmatter fence opens at line 1" || no "no opening frontmatter fence"
doc="$(cat "$DOC")"
has 'name: r-ops'   "$doc" "frontmatter declares name: r-ops"
has 'description:'  "$doc" "frontmatter has description"
has 'when_to_use:'  "$doc" "frontmatter has when_to_use (current bar)"
has 'license: MIT'  "$doc" "frontmatter declares license"

# ── references: the 9 documented files exist and are substantial ───────────
echo "-- references present --"
EXPECT=(tidyverse-core import-io strings-dates-factors visualization \
        iteration-functional modeling-stats data-table time-series workflow-tooling)
for r in "${EXPECT[@]}"; do
  f="$REF/$r.md"
  if [[ -f "$f" ]]; then
    bytes=$(wc -c < "$f")
    if [[ "$bytes" -ge 4000 ]]; then ok "$r.md present and substantial (${bytes}b)"
    else no "$r.md too small (${bytes}b < 4000)"; fi
  else
    no "$r.md missing"
  fi
done

# ── every references/ link in SKILL.md resolves (no ghost links) ───────────
echo "-- internal links resolve --"
linked=0; broken=0
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  linked=$((linked+1))
  [[ -f "$SKILL/$rel" ]] || { no "SKILL.md links missing file: $rel"; broken=$((broken+1)); }
done < <(grep -oE '\]\(references/[^)#]+\)' "$DOC" | sed -E 's/^\]\(//; s/\)$//' | sort -u)
[[ "$linked" -gt 0 ]] && ok "SKILL.md links its references ($linked unique)" || no "SKILL.md links no references"
[[ "$broken" -eq 0 ]] && ok "all referenced files resolve" || no "$broken reference link(s) broken"

# ── content-currency guard: modern idioms present ─────────────────────────
echo "-- modern idioms present --"
# Tokens the skill must keep recommending. Grepping the whole tree means a
# reference rewrite that drops the modern stance is caught too.
present_idiom() { # token label
  if grep -rqF "$1" "$SKILL" --include='*.md'; then ok "$2"; else no "$2 (idiom '$1' vanished)"; fi
}
present_idiom '|>'          "native pipe |> taught"
present_idiom '.by'         "per-op grouping .by= taught"
present_idiom 'across('     "across() taught"
present_idiom 'pivot_longer' "pivot_longer/pivot_wider taught"
present_idiom 'list_rbind'  "list_rbind (map_dfr replacement) taught"
present_idiom 'tidymodels'  "tidymodels covered"

# ── content-currency guard: deprecated idioms not recommended ──────────────
echo "-- deprecated idioms absent --"
# These superseded calls are unambiguous and currently absent everywhere
# (verified at land time). If one reappears as a code recommendation, fail —
# the skill would no longer reflect modern R. (map_dfr is intentionally NOT in
# this set: the skill discusses it by name to mark it superseded.)
DEPRECATED=('gather(' 'spread(' 'funs(' 'aes_string(' 'mutate_at(' 'mutate_if(' \
            'summarise_at(' 'summarize_at(' 'sample_n(' 'top_n(' 'data_frame(')
for d in "${DEPRECATED[@]}"; do
  if grep -rqF "$d" "$SKILL" --include='*.md'; then
    no "deprecated idiom present: $d"
  else
    ok "no '$d'"
  fi
done

# ── staleness verifier: offline contract (SKILL-RESOURCE-PROTOCOL §7) ───────
echo "-- check-r-facts.py (offline) --"
VERIFIER="$SKILL/scripts/check-r-facts.py"
CATALOG="$SKILL/assets/r-packages.json"
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [[ "$got" == "$want" ]] && ok "$lbl (exit $got)" || no "$lbl (want $want got $got)"; }
# Pick a python that actually executes — skips the Windows Store python3 stub.
PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -f "$VERIFIER" ]] && ok "verifier present" || no "verifier missing"
[[ -f "$CATALOG"  ]] && ok "package catalog present" || no "catalog missing"
if [[ -n "$PY" ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ec 0 "py_compile"            "$PY" -m py_compile "$VERIFIER"
  ec 0 "--help"                "$PY" "$VERIFIER" --help
  ec 0 "--offline consistent"  "$PY" "$VERIFIER" --offline
  jout="$("$PY" "$VERIFIER" --offline --json 2>/dev/null)"
  has 'claude-mods.r-ops.r-facts/v1' "$jout" "--json envelope schema"
  ec 3 "missing catalog -> 3"  "$PY" "$VERIFIER" --offline --catalog "$TMP/nope.json"
  printf '{"packages":"x"}' > "$TMP/bad.json"
  ec 4 "malformed catalog -> 4" "$PY" "$VERIFIER" --offline --catalog "$TMP/bad.json"
  printf '{"packages":[{"name":"zzznotreal","role":"x"}]}' > "$TMP/drift.json"
  ec 10 "uncited package -> 10" "$PY" "$VERIFIER" --offline --catalog "$TMP/drift.json"
else
  no "no working python to exercise the verifier"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
