#!/usr/bin/env bash
# Offline self-test for the mcp-ops skill — structure, frontmatter, and the
# staleness-verifier contract (SKILL-RESOURCE-PROTOCOL §7, §10).
#
# Usage:   tests/run.sh
# Input:   none (self-contained; no network, no MCP server required)
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped on unsupported platform), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/mcp-ops/tests/run.sh
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

# 2. SKILL.md frontmatter house rules
skill="$here/SKILL.md"
if [ -f "$skill" ]; then
  ok "SKILL.md present"
  grep -q '^name: mcp-ops$' "$skill" && ok "name matches directory" || bad "name != mcp-ops"
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
for res in assets/mcp-facts.json scripts/check-mcp-facts.py; do
  [ -f "$here/$res" ] && ok "resource present: $res" || bad "missing resource: $res"
done

# 5. check-mcp-facts.py — staleness verifier contract (§7, §10), offline-safe
verifier="$here/scripts/check-mcp-facts.py"
catalog="$here/assets/mcp-facts.json"
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }
if [ -f "$verifier" ]; then
  "$PY" -m py_compile "$verifier" && ok "verifier: py_compile clean" || bad "verifier: py_compile failed"
  grep -qE '^Examples:$' "$verifier" && ok "verifier: has Examples block" || bad "verifier: no Examples block (docstring)"
  "$PY" "$verifier" --help >/dev/null 2>&1 && ok "verifier: --help exits 0" || bad "verifier: --help nonzero"
  # Offline mode must pass on the skill's own content (internal consistency).
  ec 0 "verifier: --offline consistent"  "$PY" "$verifier" --offline
  # Bad flag → USAGE (exit 2); conflicting modes → USAGE.
  ec 2 "verifier: bad flag → exit 2"     "$PY" "$verifier" --bogus
  ec 2 "verifier: --offline --live → 2"  "$PY" "$verifier" --offline --live
  # stdout is data-only: --offline --json must emit parseable JSON.
  "$PY" "$verifier" --offline --json -q 2>/dev/null \
    | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.mcp-ops.facts/v1"' \
    && ok "verifier: --json envelope parses (stdout clean)" || bad "verifier: --json envelope broken"
  # Error paths: missing catalog → 3, malformed catalog → 4, drift catalog → 10.
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ec 3 "verifier: missing catalog -> 3"  "$PY" "$verifier" --offline --catalog "$TMP/nope.json"
  printf '{"packages":"x"}' > "$TMP/bad.json"
  ec 4 "verifier: malformed catalog -> 4" "$PY" "$verifier" --offline --catalog "$TMP/bad.json"
  # Minimal drift catalog (argv path so MSYS translates it): a package whose
  # prose_token is not in the real skill prose -> drift -> exit 10.
  printf '%s\n' '{"schema":"claude-mods.mcp-ops.facts/v1","as_of":"2026-07-05","spec":{"url":"https://spec.example","prose_token":"zzz.no.such.spec"},"packages":{"@no-such/sdk":{"registry":"npm","prose_token":"@no-such/sdk","sampled_major":1,"track_major":true}}}' > "$TMP/drift.json"
  ec 10 "verifier: unnamed package -> 10" "$PY" "$verifier" --offline --catalog "$TMP/drift.json"
  # cited from SKILL.md
  grep -qF "scripts/check-mcp-facts.py" "$skill" && ok "verifier: cited from SKILL.md" || bad "verifier: uncited"
else
  bad "check-mcp-facts.py missing"
fi

# 6. mcp-facts.json — parses, carries schema the verifier depends on
"$PY" -c "
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['schema'] == 'claude-mods.mcp-ops.facts/v1'
assert d['packages'], 'no packages committed'
assert '@modelcontextprotocol/sdk' in d['packages']
assert d['spec']['url'].startswith('https://')
" "$catalog" && ok "mcp-facts.json schema + packages" || bad "mcp-facts.json invalid"

# 7. Currency note present near the top of the body
grep -qE 'verified as of [0-9]{4}' "$skill" && ok "currency note present" || bad "no dated currency note"

echo "mcp-ops self-test: $pass passed, $fail failed" >&2
[ "$fail" -eq 0 ]
