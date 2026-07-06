#!/usr/bin/env bash
# Offline self-test for the threejs-ops skill — structure, frontmatter, script contract.
#
# Usage:   tests/run.sh
# Input:   none (self-contained; no network, no browser)
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped on unsupported platform), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/threejs-ops/tests/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }

# Resolve a *working* python (python3, else python). The bare `command -v` is not
# enough on Windows, where `python3` is a Microsoft Store stub that exits nonzero.
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

# 1. Required directories exist
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done

# 2. SKILL.md frontmatter house rules (SKILL-SUBAGENT-REFERENCE)
skill="$here/SKILL.md"
if [ -f "$skill" ]; then
  ok "SKILL.md present"
  grep -q '^name: threejs-ops$' "$skill" && ok "name matches directory" || bad "name != threejs-ops"
  grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
  grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
else
  bad "SKILL.md missing"
fi

# 3. Every reference on disk is cited from SKILL.md (no dead weight)
for ref in "$here"/references/*.md; do
  base="references/$(basename "$ref")"
  grep -qF "$base" "$skill" && ok "cited: $base" || bad "uncited reference: $base"
done

# 4. Every SKILL.md-cited bundled resource exists on disk
for res in assets/importmap-starter.html assets/three-facts.json scripts/check-three-facts.py; do
  [ -f "$here/$res" ] && ok "resource present: $res" || bad "missing resource: $res"
done

# 5. check-three-facts.py — staleness verifier contract (§7, §10), offline-safe
facts="$here/scripts/check-three-facts.py"
if [ -f "$facts" ]; then
  "$PY" -m py_compile "$facts" && ok "facts: py_compile clean" || bad "facts: py_compile failed"
  # Captured, not `head | grep -q`: under `set -o pipefail` grep -q's early exit
  # SIGPIPEs the producer (141) and flakes the assert even on a match.
  facts_head="$(head -35 "$facts")"
  grep -Eq '^# +Examples:' <<<"$facts_head" && ok "facts: has Examples block" || bad "facts: no Examples block"
  "$PY" "$facts" --help >/dev/null 2>&1 && ok "facts: --help exits 0" || bad "facts: --help nonzero"
  # Offline mode must pass on the skill's own content (internal consistency).
  "$PY" "$facts" --offline >/dev/null 2>&1 && ok "facts: --offline consistent (exit 0)" || bad "facts: --offline found inconsistency"
  # Bad flag → USAGE (exit 2); stays offline.
  "$PY" "$facts" --bogus >/dev/null 2>&1
  [ "$?" -eq 2 ] && ok "facts: bad flag → exit 2 (USAGE)" || bad "facts: bad flag did not exit 2"
  # --offline and --live are mutually exclusive → USAGE.
  "$PY" "$facts" --offline --live >/dev/null 2>&1
  [ "$?" -eq 2 ] && ok "facts: --offline --live → exit 2 (USAGE)" || bad "facts: conflicting modes did not exit 2"
  # stdout is data-only: --offline --json must emit parseable JSON with no stderr leakage.
  "$PY" "$facts" --offline --json -q 2>/dev/null | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"].startswith("claude-mods.threejs-ops")' \
    && ok "facts: --json envelope parses (stdout clean)" || bad "facts: --json envelope broken"
  # cited from SKILL.md
  grep -qF "scripts/check-three-facts.py" "$skill" && ok "facts: cited from SKILL.md" || bad "facts: uncited"
else
  bad "check-three-facts.py missing"
fi

# 6. three-facts.json — parses, carries schema + gates the verifier depends on
fj="$here/assets/three-facts.json"
"$PY" -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['schema'] == 'claude-mods.threejs-ops.facts/v1'
assert d['version_gates']['examples_js_removed'] == 'r148'
assert d['version_gates']['umd_builds_removed'] == 'r160'
assert d['packages'], 'no packages committed'
" "$fj" && ok "three-facts.json schema + gates" || bad "three-facts.json invalid"

# 7. importmap-starter.html — import map parses, same pinned version both entries
"$PY" -c "
import json, re, sys
html = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'<script type=\"importmap\">\s*(\{.*?\})\s*</script>', html, re.S)
imports = json.loads(m.group(1))['imports']
v = re.search(r'three@(0\.\d+\.\d+)/', imports['three']).group(1)
va = re.search(r'three@(0\.\d+\.\d+)/', imports['three/addons/']).group(1)
assert v == va, f'{v} != {va}'
" "$here/assets/importmap-starter.html" && ok "starter import map pinned + consistent" || bad "starter import map broken"

# 8. Negative test: verifier catches a broken facts file (exit 4 VALIDATION)
tmpd="$(mktemp -d)"
cp -r "$here/scripts" "$here/assets" "$here/references" "$tmpd/"
cp "$skill" "$tmpd/SKILL.md"
"$PY" -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['version_gates']['umd_builds_removed'] = 'r999'   # gate no longer stated in SKILL.md
json.dump(d, open(p, 'w', encoding='utf-8'))
" "$tmpd/assets/three-facts.json"
"$PY" "$tmpd/scripts/check-three-facts.py" --offline >/dev/null 2>&1
[ "$?" -eq 4 ] && ok "negative: broken gate → exit 4 (VALIDATION)" || bad "negative: broken gate not caught"
rm -rf "$tmpd"

echo "threejs-ops self-test: $pass passed, $fail failed" >&2
[ "$fail" -eq 0 ]
