#!/usr/bin/env bash
# Offline self-test for the web-perf-ops skill: structure, the port-friendly size
# contract, and the behaviour of both scripts (SKILL-RESOURCE-PROTOCOL §2, §5, §7, §10).
#
# Usage:   tests/run.sh
# Input:   none (self-contained; no network, no Lighthouse/Chrome install needed)
# Output:  per-check lines on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped when no python), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/web-perf-ops/tests/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }

# A *working* python: on Windows `python3` can be a Microsoft Store stub that exits nonzero.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
if [ -z "$PY" ]; then
  echo "SKIP: no working python interpreter on this platform" >&2
  exit 0
fi

skill="$here/SKILL.md"
verify="$here/scripts/check-web-perf-facts.py"
triage="$here/scripts/triage-vitals.py"
fx="$here/tests/fixtures"

# Helper: assert an exact exit code.
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }
# Join args with TABs so TSV rows match with portable `grep -F` (BSD grep has no -P).
tsv() { local IFS=$'\t'; printf '%s' "$*"; }

# 1. Layout
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done

# 2. Frontmatter house rules + Agent Skills spec fields only.
# CONTRACT: these assertions require `name: web-perf-ops`, `license: MIT`,
# `metadata.author: claude-mods`, a description of <= 500 chars carrying a
# "Use when" clause, and NO Claude-Code-only top-level keys (when_to_use,
# argument-hint, effort). The skill is ported into another team's plugin, so it
# stays on the portable spec. A lane editing the frontmatter must keep these or
# change this block in the same commit (SKILL-CREATION-PROTOCOL Step 5).
if [ -f "$skill" ]; then
  ok "SKILL.md present"
  grep -q '^name: web-perf-ops$' "$skill" && ok "name matches directory" || bad "name != web-perf-ops"
  grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
  grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
  for k in when_to_use argument-hint effort; do
    grep -q "^$k:" "$skill" && bad "non-spec top-level key: $k" || ok "no top-level $k"
  done
  desc_len=$("$PY" - "$skill" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^description:\s*"(.*)"\s*$', text, re.M)
print(len(m.group(1)) if m else -1)
PY
)
  [ "$desc_len" -gt 0 ] && [ "$desc_len" -le 500 ] && ok "description $desc_len chars (<= 500)" \
    || bad "description length $desc_len (want 1..500, double-quoted one-liner)"
  grep -q '^description:.*Use when' "$skill" && ok "description has a 'Use when' clause" \
    || bad "description lacks 'Use when'"
else
  bad "SKILL.md missing"
fi

# 3. Size contract: SKILL.md body <= ~5,000 tokens (chars / 3.6), because Claude
# Code keeps only the first 5,000 tokens of an invoked skill after compaction.
# References <= 300 lines; any reference over 100 lines opens with a Contents list.
body_tokens=$("$PY" - "$skill" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
body = text.split("---", 2)[2] if text.startswith("---") else text
print(int(len(body) / 3.6))
PY
)
[ "$body_tokens" -le 5000 ] && ok "SKILL.md body ~${body_tokens} tokens (<= 5000)" \
  || bad "SKILL.md body ~${body_tokens} tokens (> 5000)"
for ref in "$here"/references/*.md; do
  base="references/$(basename "$ref")"
  lines=$(wc -l < "$ref" | tr -d ' ')
  [ "$lines" -le 300 ] && ok "$base $lines lines (<= 300)" || bad "$base $lines lines (> 300)"
  if [ "$lines" -gt 100 ]; then
    head -12 "$ref" | grep -q '^## Contents' && ok "$base has a Contents list" \
      || bad "$base > 100 lines without '## Contents' in its first 12 lines"
  fi
  grep -qF "$base" "$skill" && ok "cited: $base" || bad "uncited reference: $base"
done

# 4. Cited bundled resources exist
for res in assets/web-perf-facts.json scripts/check-web-perf-facts.py scripts/triage-vitals.py \
           tests/fixtures/psi-poor.json tests/fixtures/crux-good.json; do
  [ -f "$here/$res" ] && ok "resource present: $res" || bad "missing resource: $res"
done

# 5. Craft coordination: craft.md links to craftcms-ops rather than duplicating it.
# Markdown link syntax only - a plain mention of the skill name doesn't count.
grep -qE '\]\(\.\./\.\./craftcms-ops/references/performance\.md' "$here/references/craft.md" 2>/dev/null \
  && ok "craft.md links craftcms-ops' performance reference" \
  || bad "craft.md does not link ../../craftcms-ops/references/performance.md"

# 6. Staleness verifier: contract + offline consistency on the shipped skill
"$PY" -m py_compile "$verify" && ok "verifier: py_compile clean" || bad "verifier: py_compile failed"
"$PY" "$verify" --help 2>/dev/null | grep -q "Examples:" && ok "verifier: --help has Examples" \
  || bad "verifier: --help missing Examples"
ec 0 "verifier: --help exits 0" "$PY" "$verify" --help
ec 2 "verifier: unknown flag -> usage" "$PY" "$verify" --bogus
ec 0 "verifier: --offline clean on shipped skill" "$PY" "$verify" --offline -q
ec 3 "verifier: missing catalog -> not found" "$PY" "$verify" --offline --catalog "$here/nope.json"

# 7. The verifier must SEE drift. Mutate a scratch copy two ways; each must trip exit 10.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$here" "$tmp/skill"
"$PY" - "$tmp/skill/SKILL.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t2 = re.sub(r"(\|\s*\*\*LCP\*\*\s*\|[^|\d]*)2\.5", r"\g<1>3.0", t, count=1)
assert t2 != t, "LCP row not found to mutate"
open(p, "w", encoding="utf-8").write(t2)
PY
ec 10 "verifier: catches an edited LCP threshold" "$PY" "$verify" --offline -q --skill "$tmp/skill"
cp "$here/SKILL.md" "$tmp/skill/SKILL.md"
printf '\nOptimise FID by deferring heavy scripts.\n' >> "$tmp/skill/references/inp.md"
ec 10 "verifier: catches FID presented as current" "$PY" "$verify" --offline -q --skill "$tmp/skill"

# 8. Triage: the measurement -> fix bridge, on the bundled fixtures
"$PY" -m py_compile "$triage" && ok "triage: py_compile clean" || bad "triage: py_compile failed"
"$PY" "$triage" --help 2>/dev/null | grep -q "Examples:" && ok "triage: --help has Examples" \
  || bad "triage: --help missing Examples"
ec 10 "triage: poor PSI report is a finding" "$PY" "$triage" "$fx/psi-poor.json" -q
ec 0  "triage: all-good CrUX report is clean" "$PY" "$triage" "$fx/crux-good.json" -q
ec 3  "triage: missing report -> not found" "$PY" "$triage" "$fx/absent.json"
ec 2  "triage: unknown flag -> usage" "$PY" "$triage" "$fx/crux-good.json" --bogus
out_empty=$(printf '{}' | "$PY" "$triage" - -q >/dev/null 2>&1; echo $?)
[ "$out_empty" = 4 ] && ok "triage: unrecognised shape -> 4" || bad "triage: unrecognised shape (want 4 got $out_empty)"

psi=$("$PY" "$triage" "$fx/psi-poor.json" -q 2>/dev/null)
grep -qxF "$(tsv field:psi-url LCP '4.20 s' poor references/lcp.md)" <<< "$psi" \
  && ok "triage: PSI field LCP 4.2 s rated poor -> lcp.md" || bad "triage: PSI field LCP row wrong"
# PSI encodes field CLS x100 (12 means 0.12): a missed /100 would rate it poor at "12.00".
grep -qF "$(tsv field:psi-url CLS 0.12 needs-improvement)" <<< "$psi" \
  && ok "triage: PSI CLS x100 decoded to 0.12" || bad "triage: PSI CLS not decoded (x100)"
grep -qxF "$(tsv lab:lighthouse TBT '750 ms' poor references/inp.md)" <<< "$psi" \
  && ok "triage: lab TBT routed to inp.md" || bad "triage: lab TBT row wrong"
awk -F'\t' '$1=="lab:audit" && $4=="opportunity" {f=1} END {exit !f}' <<< "$psi" \
  && ok "triage: lab audits with metricSavings listed" || bad "triage: no lab opportunity rows"
awk -F'\t' '$2=="image-delivery-insight" && $5=="references/images.md" {f=1} END {exit !f}' <<< "$psi" \
  && ok "triage: image audit routed to images.md, not just its metric" || bad "triage: image audit misrouted"
grep -q 'passing-audit' <<< "$psi" && bad "triage: listed an audit that already passes" \
  || ok "triage: passing audits not listed"
fid_note=$("$PY" "$triage" "$fx/psi-poor.json" 2>&1 >/dev/null)
grep -q 'FID was retired' <<< "$fid_note" && ok "triage: retired FID data noticed, not rated" \
  || bad "triage: FID data not noticed"

crux=$("$PY" "$triage" "$fx/crux-good.json" -q 2>/dev/null)
grep -qF "$(tsv field:crux-origin CLS 0.03 good)" <<< "$crux" \
  && ok "triage: CrUX string CLS parsed" || bad "triage: CrUX CLS string not parsed"
awk -F'\t' '$2=="LCP subpart: load delay" && $4=="dominant" {f=1} END {exit !f}' <<< "$crux" \
  && ok "triage: dominant field LCP subpart flagged" || bad "triage: dominant LCP subpart not flagged"
"$PY" "$triage" "$fx/crux-good.json" --json -q 2>/dev/null | "$PY" -c \
  'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"].startswith("claude-mods.web-perf-ops."); assert isinstance(d["data"], list)' \
  && ok "triage: --json envelope well-formed" || bad "triage: --json envelope malformed"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
  echo "PASS web-perf-ops: $pass/$total" >&2; exit 0
else
  echo "FAIL web-perf-ops: $fail of $total failed" >&2; exit 1
fi
