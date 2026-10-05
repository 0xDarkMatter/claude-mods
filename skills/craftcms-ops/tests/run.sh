#!/usr/bin/env bash
# Offline self-test for craftcms-ops - the reference set, the port-format
# limits, and the staleness verifier's script contract (SKILL-RESOURCE-PROTOCOL
# §2, §5, §7, §10).
#
# The bug this suite exists to catch: a key reference (SEOmatic, Blitz, Twig
# security, ...) goes missing, gets gutted, or is no longer linked from SKILL.md,
# so the router silently stops finding it. Secondary: the skill drifts past the
# limits of the team-plugin format it is ported into (see PORT LIMITS below).
#
# Usage:   tests/run.sh
#          CRAFTCMS_OPS_DIR=<copy-of-skill> tests/run.sh   # run against a copy,
#                                                           # e.g. to prove a mutation fails
# Input:   none (self-contained; no network, no PHP/Craft install required)
# Output:  progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (verifier checks skip cleanly without python), 1 any failure.
#
# Examples:
#   bash skills/craftcms-ops/tests/run.sh
#   CRAFTCMS_OPS_DIR=/tmp/craft-copy bash skills/craftcms-ops/tests/run.sh
set -uo pipefail

here="${CRAFTCMS_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
skill="$here/SKILL.md"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }

# 1. Layout + frontmatter house rules
# CONTRACT: requires `name: craftcms-ops`, `license: MIT`, `metadata.author:
# claude-mods`, and a SINGLE-LINE quoted `description:` (the length check below
# reads one line). A frontmatter trim must keep these or update this block.
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done
if [ ! -f "$skill" ]; then
  bad "SKILL.md missing"
  echo "craftcms-ops tests: $pass passed, $fail failed" >&2; echo "FAIL" >&2; exit 1
fi
grep -q '^name: craftcms-ops$' "$skill" && ok "name matches directory" || bad "name != craftcms-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"

# 2. SIZE + PORT LIMITS.
# CONTRACT (set 2026-10-05 by the coordinating session):
#  - SKILL.md BODY <= ~5,000 estimated tokens (chars / 3.6). Not arbitrary: after
#    auto-compaction Claude Code keeps only the FIRST 5,000 tokens of an invoked
#    skill, so anything past that silently vanishes mid-session. That is also why
#    the procedure and decision tables sit at the top of SKILL.md.
#  - every reference <= 300 lines; one over 100 lines opens with a "## Contents"
#    table of contents (Anthropic skill guidance: partial reads still see the map).
#  - description <= 500 chars carrying a "Use when" trigger clause, and NO
#    separate `when_to_use:` field - the team-plugin format this skill is ported
#    into has only `description`, so the trigger must live there.
desc_line="$(grep -m1 '^description: ' "$skill" || true)"
desc="${desc_line#description: }"; desc="${desc#\"}"; desc="${desc%\"}"
[ -n "$desc" ] && ok "description present" || bad "description missing or not single-line"
[ "${#desc}" -le 500 ] && ok "description ${#desc} chars (<=500)" || bad "description ${#desc} chars (>500)"
case "$desc" in *"Use when"*) ok "description has a 'Use when' clause" ;; *) bad "description lacks 'Use when'" ;; esac
grep -q '^when_to_use:' "$skill" && bad "when_to_use: present (port format has description only)" || ok "no when_to_use field"
# Body = everything after the closing frontmatter fence.
body_chars="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$skill" | wc -c | tr -d ' ')"
body_tokens=$(( body_chars * 10 / 36 ))
[ "$body_tokens" -le 5000 ] && ok "SKILL.md body ~$body_tokens tokens (<=5000)" \
  || bad "SKILL.md body ~$body_tokens tokens (>5000 - the tail is lost after compaction)"

# 3. The key references: each must exist, be LINKED from SKILL.md as a markdown
# link, and still carry the token that defines its topic (a gutted file that
# lost its subject is as useless to the router as a missing one).
# Format: <file>|<topic token>   (token matched case-sensitively, fixed-string)
required="
references/seomatic.md|JSON-LD
references/blitz.md|{% cache %}
references/formie.md|CSRF
references/ckeditor.md|nested entries
references/ddev.md|ddev craft
references/codeception.md|fixtures
references/twig-security.md||raw
references/craft-vite.md|manifest
references/upgrades.md|Craft 3
references/performance.md|eagerly
references/element-queries.md|.with(
references/graphql.md|GraphQL
references/plugin-development.md|Plugin.php
"
while IFS='|' read -r ref token; do
  [ -z "$ref" ] && continue
  if [ -f "$here/$ref" ]; then ok "present: $ref"; else bad "missing: $ref"; continue; fi
  grep -qF "]($ref)" "$skill" && ok "linked from SKILL.md: $ref" || bad "not linked from SKILL.md: $ref"
  grep -qF -- "$token" "$here/$ref" && ok "topic token in $ref: $token" || bad "topic token gone from $ref: $token"
done <<< "$required"

# Every reference on disk is linked (an unlinked file is dead weight the router
# never finds) and fits the port limit; one H1 = one topic per file.
for f in "$here"/references/*.md; do
  [ -e "$f" ] || continue
  rel="references/$(basename "$f")"
  grep -qF "]($rel)" "$skill" || bad "unlinked reference on disk: $rel"
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -le 300 ] && ok "$rel $n lines (<=300)" || bad "$rel $n lines (>300)"
  if [ "$n" -gt 100 ]; then
    head -n 15 "$f" | grep -q '^## Contents' && ok "$rel has a Contents TOC" \
      || bad "$rel is $n lines but has no '## Contents' in its first 15 lines"
  fi
  # Count H1s outside fenced code: a `# comment` line in a bash/ini block is not a heading.
  h1="$(awk '/^```/{fence=!fence; next} !fence && /^# /{n++} END{print n+0}' "$f")"
  [ "$h1" = "1" ] && ok "$rel has one H1" || bad "$rel has $h1 H1 headings (want 1: one topic per file)"
done

# Every relative .md link in SKILL.md and the references resolves on disk.
for src in "$skill" "$here"/references/*.md "$here"/assets/*.md; do
  [ -e "$src" ] || continue
  dir="$(dirname "$src")"
  while IFS= read -r target; do
    target="${target%%#*}"
    [ -z "$target" ] && continue
    [ -f "$dir/$target" ] || bad "broken link in $(basename "$src"): $target"
  done < <(grep -oE '\]\([A-Za-z0-9_./-]+\.md(#[^)]*)?\)' "$src" | sed -E 's/^\]\(//; s/\)$//' | grep -v '^\.\./' || true)
done
ok "relative .md links checked"

# 4. The perf reference must link web-perf-ops' Craft lever map - the Core Web
# Vitals method is deliberately NOT duplicated here. Markdown link syntax only: a
# path mentioned in a comment or prose doesn't count.
perf="$here/references/performance.md"
if [ -f "$perf" ]; then
  if grep -qE '\]\(\.\./\.\./web-perf-ops/references/craft\.md' "$perf"; then ok "performance.md links web-perf-ops' Craft lever map"
  else bad "performance.md does not link ../../web-perf-ops/references/craft.md"; fi
fi

# 5. Twig security reference keeps its four load-bearing rules.
tsec="$here/references/twig-security.md"
if [ -f "$tsec" ]; then
  for t in "autoescape" "csrfInput" "|e('js')" "|purify"; do
    grep -qF -- "$t" "$tsec" && ok "twig-security covers: $t" || bad "twig-security lost: $t"
  done
fi

# 6. check-craft-facts.py - staleness verifier contract (§7), offline only.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then PY="$cand"; break; fi
done
verifier="$here/scripts/check-craft-facts.py"
catalog="$here/assets/craft-facts.json"
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }
if [ ! -f "$verifier" ] || [ ! -f "$catalog" ]; then
  bad "verifier or catalog missing (scripts/check-craft-facts.py, assets/craft-facts.json)"
elif [ -z "$PY" ]; then
  note "skip" "no working python - verifier checks skipped"
else
  grep -qF "scripts/check-craft-facts.py" "$skill" && ok "verifier cited from SKILL.md" || bad "verifier not cited from SKILL.md"
  "$PY" -m py_compile "$verifier" && ok "verifier: py_compile clean" || bad "verifier: py_compile failed"
  grep -qE '^Examples:$' "$verifier" && ok "verifier: has Examples block" || bad "verifier: no Examples block"
  ec 0 "verifier: --help exits 0" "$PY" "$verifier" --help
  ec 0 "verifier: --offline consistent" "$PY" "$verifier" --offline --skill "$here" --catalog "$catalog"
  ec 2 "verifier: bad flag -> 2" "$PY" "$verifier" --bogus
  ec 2 "verifier: --offline --live -> 2" "$PY" "$verifier" --offline --live
  ec 3 "verifier: missing catalog -> 3" "$PY" "$verifier" --offline --catalog /no/such/catalog.json
  "$PY" "$verifier" --offline --json -q --skill "$here" --catalog "$catalog" 2>/dev/null \
    | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.craftcms-ops.facts/v1"' \
    && ok "verifier: --json envelope parses (stdout clean)" || bad "verifier: --json envelope broken"
  tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/craftcms-ops-test.$$")"
  mkdir -p "$tmp"
  printf 'not json' > "$tmp/bad.json"
  ec 4 "verifier: malformed catalog -> 4" "$PY" "$verifier" --offline --catalog "$tmp/bad.json" --skill "$here"
  # A prose token the docs no longer state is drift: the catalog and the prose
  # have parted ways, so one of them is wrong.
  sed 's/"prose_token": "SEOmatic 5"/"prose_token": "SEOmatic 99"/' "$catalog" > "$tmp/drift.json"
  ec 10 "verifier: drifted prose token -> 10" "$PY" "$verifier" --offline --catalog "$tmp/drift.json" --skill "$here"
  rm -rf "$tmp"
fi

echo "craftcms-ops tests: $pass passed, $fail failed" >&2
[ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
