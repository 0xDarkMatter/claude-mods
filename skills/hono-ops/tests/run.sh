#!/usr/bin/env bash
# Offline self-test for the hono-ops skill — structure, frontmatter, and the
# script contracts (SKILL-RESOURCE-PROTOCOL §2, §5, §7, §10).
#
# Usage:   tests/run.sh
# Input:   none (self-contained; no network, no node/wrangler install required)
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped on unsupported platform), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/hono-ops/tests/run.sh
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
# CONTRACT: these assertions require the frontmatter to keep `name: hono-ops`,
# `license: MIT`, and `metadata.author: claude-mods` — a trim/cleanup lane that
# edits the frontmatter must keep them or update these assertions in the same
# commit (see SKILL-CREATION-PROTOCOL Step 5).
skill="$here/SKILL.md"
if [ -f "$skill" ]; then
  ok "SKILL.md present"
  grep -q '^name: hono-ops$' "$skill" && ok "name matches directory" || bad "name != hono-ops"
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
for res in assets/worker-template.ts assets/vitest.config.template.ts \
           assets/hono-facts.json \
           scripts/route-inventory.py scripts/check-hono-facts.py \
           tests/fixtures/sample-app.ts; do
  [ -f "$here/$res" ] && ok "resource present: $res" || bad "missing resource: $res"
done

# Helper: assert an exact exit code.
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }

# 5. route-inventory.py — script contract + behaviour on the bundled fixture
inv="$here/scripts/route-inventory.py"
fixture="$here/tests/fixtures/sample-app.ts"
"$PY" -m py_compile "$inv" && ok "route-inventory: py_compile clean" || bad "route-inventory: py_compile failed"
"$PY" "$inv" --help 2>/dev/null | grep -q "Examples:" && ok "route-inventory: --help has Examples" || bad "route-inventory: --help missing Examples"
ec 0 "route-inventory: --help exits 0" "$PY" "$inv" --help
ec 2 "route-inventory: bad flag -> 2"  "$PY" "$inv" --bogus "$fixture"
ec 3 "route-inventory: missing path -> 3" "$PY" "$inv" /no/such/path
ec 0 "route-inventory: fixture inventory ok" "$PY" "$inv" "$fixture"

# Behaviour: the fixture registers exactly 18 things; assert the count and a few
# load-bearing rows (a mount, the custom method, chained-app attribution).
# CONTRACT: tests/fixtures/sample-app.ts and these numbers move together.
out="$("$PY" "$inv" "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | wc -l)" = "18" ] && ok "route-inventory: 18 rows" || bad "route-inventory: row count != 18"
printf '%s\n' "$out" | grep -q "mount	-	/api/time" && ok "route-inventory: mount row" || bad "route-inventory: mount row missing"
printf '%s\n' "$out" | grep -q "route	PURGE	/api/cache" && ok "route-inventory: on() custom method" || bad "route-inventory: on() row missing"
printf '%s\n' "$out" | grep -q "route	GET	/posts/:id	chained" && ok "route-inventory: chained attribution" || bad "route-inventory: chained attribution wrong"

# --json envelope parses with the documented schema (stdout is data-only)
"$PY" "$inv" --json "$fixture" 2>/dev/null \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.hono-ops.route-inventory/v1"; assert d["meta"]["count"]==18' \
  && ok "route-inventory: --json envelope parses" || bad "route-inventory: --json envelope broken"

# --check flags exactly the fixture's three deliberate baits: one bypass
# (/api/health before the /api/* middleware), one duplicate (GET /api/me twice),
# one shadowed (/api/reports/daily under the earlier /api/reports/* wildcard).
ec 10 "route-inventory: --check finds issues -> 10" "$PY" "$inv" --check "$fixture"
chk="$("$PY" "$inv" --check "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$chk" | grep -c '^finding')" = "3" ] && ok "route-inventory: exactly 3 findings" || bad "route-inventory: finding count != 3"
printf '%s\n' "$chk" | grep -q "/api/health.*bypasses" && ok "route-inventory: bypass finding" || bad "route-inventory: bypass finding missing"
printf '%s\n' "$chk" | grep -q "/api/me.*duplicate of" && ok "route-inventory: duplicate finding" || bad "route-inventory: duplicate finding missing"
printf '%s\n' "$chk" | grep -q "/api/reports/daily.*shadowed by" && ok "route-inventory: shadowed finding" || bad "route-inventory: shadowed finding missing"
# Capture first: --check exits 10, and under pipefail that would sink the pipe.
chk_json="$("$PY" "$inv" --check --json "$fixture" 2>/dev/null)"
printf '%s' "$chk_json" \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert sorted(f["issue"] for f in d["data"])==["bypass","duplicate","shadowed"]' \
  && ok "route-inventory: --check --json issue fields" || bad "route-inventory: --check --json issue fields wrong"

# 6. check-hono-facts.py — staleness verifier contract (§7), offline-safe
verifier="$here/scripts/check-hono-facts.py"
"$PY" -m py_compile "$verifier" && ok "verifier: py_compile clean" || bad "verifier: py_compile failed"
grep -qE '^Examples:$' "$verifier" && ok "verifier: has Examples block" || bad "verifier: no Examples block (docstring)"
ec 0 "verifier: --help exits 0" "$PY" "$verifier" --help
ec 0 "verifier: --offline consistent" "$PY" "$verifier" --offline
ec 2 "verifier: bad flag -> 2" "$PY" "$verifier" --bogus
ec 2 "verifier: --offline --live -> 2" "$PY" "$verifier" --offline --live
ec 3 "verifier: missing catalog -> 3" "$PY" "$verifier" --offline --catalog /no/such/catalog.json
"$PY" "$verifier" --offline --json -q 2>/dev/null \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.hono-ops.facts/v1"' \
  && ok "verifier: --json envelope parses (stdout clean)" || bad "verifier: --json envelope broken"

# Error paths against synthetic catalogs: malformed -> 4, drifted token -> 10.
tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/hono-ops-test.$$")"
mkdir -p "$tmp"
printf 'not json' > "$tmp/bad.json"
ec 4 "verifier: malformed catalog -> 4" "$PY" "$verifier" --offline --catalog "$tmp/bad.json"
sed 's/Hono v4/Hono v99/' "$here/assets/hono-facts.json" > "$tmp/drift.json"
ec 10 "verifier: drifted token -> 10" "$PY" "$verifier" --offline --catalog "$tmp/drift.json"
rm -rf "$tmp"

# 7. Template sanity: the starters name their load-bearing sections
tmpl="$here/assets/worker-template.ts"
for marker in "securityHeaders" "app.onError" "satisfies ExportedHandler" "not_found" "timingSafeEqual"; do
  grep -qF "$marker" "$tmpl" && ok "worker template carries: $marker" || bad "worker template missing: $marker"
done
vtmpl="$here/assets/vitest.config.template.ts"
for marker in "defineWorkersConfig" "readD1Migrations" "isolatedStorage" "compatibilityDate"; do
  grep -qF "$marker" "$vtmpl" && ok "vitest template carries: $marker" || bad "vitest template missing: $marker"
done

echo "hono-ops tests: $pass passed, $fail failed" >&2
[ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
