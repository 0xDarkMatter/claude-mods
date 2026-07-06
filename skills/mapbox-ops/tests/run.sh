#!/usr/bin/env bash
# Offline self-test for the mapbox-ops skill — structure, frontmatter, script contract.
#
# Usage:   tests/run.sh
# Input:   none (self-contained; no network, no playwright, no browser)
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped on unsupported platform), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/mapbox-ops/tests/run.sh
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
  grep -q '^name: mapbox-ops$' "$skill" && ok "name matches directory" || bad "name != mapbox-ops"
  grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
  grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
else
  bad "SKILL.md missing"
fi

# 3. Every reference cited from SKILL.md actually exists, and vice-versa
for ref in "$here"/references/*.md; do
  base="references/$(basename "$ref")"
  grep -qF "$base" "$skill" && ok "cited: $base" || bad "uncited reference: $base"
done

# 4. Bundled resources referenced from SKILL.md exist on disk
for res in assets/circular_image_marker.js scripts/screenshot_map.py; do
  [ -f "$here/$res" ] && ok "resource present: $res" || bad "missing resource: $res"
done

# 5. screenshot_map.py — script contract (§10)
py="$here/scripts/screenshot_map.py"
if [ -f "$py" ]; then
  "$PY" -m py_compile "$py" && ok "py_compile clean" || bad "py_compile failed"
  # Captured, not `head | grep -q`: under `set -o pipefail` grep -q's early exit
  # SIGPIPEs the producer (141) and flakes the assert even on a match.
  py_head="$(head -25 "$py")"
  grep -Eq '^(# )?Examples:' <<<"$py_head" && ok "has Examples block" || bad "no Examples block"
  "$PY" "$py" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help nonzero"
  # USAGE (exit 2) on a file:// URL — happens before the playwright import, so this is offline-safe
  "$PY" "$py" "file:///tmp/x.html" /tmp/o.png >/dev/null 2>&1
  [ "$?" -eq 2 ] && ok "file:// URL → exit 2 (USAGE)" || bad "file:// URL did not exit 2"
else
  bad "screenshot_map.py missing"
fi

# 5b. check-mapbox-facts.py — staleness verifier contract (§7, §10), offline-safe
facts="$here/scripts/check-mapbox-facts.py"
if [ -f "$facts" ]; then
  ok "resource present: scripts/check-mapbox-facts.py"
  "$PY" -m py_compile "$facts" && ok "facts: py_compile clean" || bad "facts: py_compile failed"
  facts_head="$(head -30 "$facts")"   # captured, not piped — see SIGPIPE note above
  grep -Eq '^# +Examples:' <<<"$facts_head" && ok "facts: has Examples block" || bad "facts: no Examples block"
  "$PY" "$facts" --help >/dev/null 2>&1 && ok "facts: --help exits 0" || bad "facts: --help nonzero"
  # Offline mode must pass on the skill's own content (internal consistency).
  "$PY" "$facts" --offline >/dev/null 2>&1 && ok "facts: --offline consistent (exit 0)" || bad "facts: --offline found drift"
  # Bad flag → USAGE (exit 2); stays offline.
  "$PY" "$facts" --bogus >/dev/null 2>&1
  [ "$?" -eq 2 ] && ok "facts: bad flag → exit 2 (USAGE)" || bad "facts: bad flag did not exit 2"
  # stdout is data-only: --offline --json must emit parseable JSON with no stderr leakage.
  "$PY" "$facts" --offline --json -q 2>/dev/null | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"].startswith("claude-mods.mapbox-ops")' \
    && ok "facts: --json envelope parses (stdout clean)" || bad "facts: --json envelope broken"
  # cited from SKILL.md
  grep -qF "scripts/check-mapbox-facts.py" "$skill" && ok "facts: cited from SKILL.md" || bad "facts: uncited"
else
  bad "check-mapbox-facts.py missing"
fi

# 6. circular_image_marker.js — node --check if node present (optional)
js="$here/assets/circular_image_marker.js"
if command -v node >/dev/null 2>&1; then
  node --check "$js" >/dev/null 2>&1 && ok "js syntax (node --check)" || bad "js syntax error"
else
  note "skip" "node absent — js syntax check skipped"
fi

echo "mapbox-ops self-test: $pass passed, $fail failed" >&2
[ "$fail" -eq 0 ]
