#!/usr/bin/env bash
# Offline self-test for the nextjs-ops skill — structure, frontmatter, and the
# script contracts (SKILL-RESOURCE-PROTOCOL §2, §5, §7, §10).
#
# Usage:   tests/run.sh
# Input:   none (self-contained; no network, no node/next install required)
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped on unsupported platform), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/nextjs-ops/tests/run.sh
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
# CONTRACT: these assertions require the frontmatter to keep `name: nextjs-ops`,
# `license: MIT`, and `metadata.author: claude-mods` — a trim/cleanup lane that
# edits the frontmatter must keep them or update these assertions in the same
# commit (see SKILL-CREATION-PROTOCOL Step 5).
skill="$here/SKILL.md"
if [ -f "$skill" ]; then
  ok "SKILL.md present"
  grep -q '^name: nextjs-ops$' "$skill" && ok "name matches directory" || bad "name != nextjs-ops"
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
for res in assets/next.config.template.ts assets/nextjs-facts.json \
           scripts/audit-app-router.py scripts/check-nextjs-facts.py \
           tests/fixtures/app-sample/package.json \
           tests/fixtures/clean-app/package.json; do
  [ -f "$here/$res" ] && ok "resource present: $res" || bad "missing resource: $res"
done

# Helper: assert an exact exit code.
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }

# 5. audit-app-router.py — script contract + behaviour on the bundled fixture
audit="$here/scripts/audit-app-router.py"
fixture="$here/tests/fixtures/app-sample"
clean="$fixture/app/clean/page.tsx"
cleanapp="$here/tests/fixtures/clean-app"
"$PY" -m py_compile "$audit" && ok "audit: py_compile clean" || bad "audit: py_compile failed"
"$PY" "$audit" --help 2>/dev/null | grep -q "Examples:" && ok "audit: --help has Examples" || bad "audit: --help missing Examples"
ec 0 "audit: --help exits 0"          "$PY" "$audit" --help
ec 2 "audit: bad flag -> 2"           "$PY" "$audit" --bogus "$fixture"
ec 2 "audit: unknown rule -> 2"       "$PY" "$audit" --rules no-such-rule "$fixture"
ec 2 "audit: --limit 0 -> 2"          "$PY" "$audit" --limit 0 "$fixture"
ec 3 "audit: missing path -> 3"       "$PY" "$audit" /no/such/path
ec 10 "audit: fixture has findings -> 10" "$PY" "$audit" "$fixture"

# Behaviour: app-sample/ is a minefield carrying at least one bait per rule, so
# every rule must fire. (sync-params-prop has two: a sync type annotation and a
# sync destructure, which are separate code paths.)
# CONTRACT: tests/fixtures/app-sample/ and these numbers move together — adding
# a rule to audit-app-router.py means adding its bait to the fixture.
out="$("$PY" "$audit" "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | grep -c .)" = "17" ] && ok "audit: 17 findings" || bad "audit: finding count != 17"
for rule in sync-request-api sync-params-prop request-api-in-use-cache \
            client-secret-env client-imports-server-only parallel-route-no-default \
            nondeterministic-in-use-cache middleware-file edge-runtime-segment \
            revalidate-tag-single-arg images-domains-config action-without-auth \
            force-static-with-request-api client-component-route-file \
            proxy-without-matcher blanket-force-dynamic; do
  n="$(printf '%s\n' "$out" | grep -cF "	$rule	")"
  [ "$n" -ge 1 ] && ok "audit: rule fires: $rule" || bad "audit: rule $rule never fired"
done

# The negative controls are the load-bearing half: a linter that flags correct
# code is worse than no linter. app/clean/page.tsx is a single correct page;
# clean-app/ is the adversarial version - a whole app built from constructs a
# naive regex misreads (the documented read-outside-pass-in pattern with the
# cached and uncached functions in ONE module, params aliased rather than
# destructured, an unrelated object literal carrying a `params:` key, a guard
# named requireOwner rather than auth). It must stay at zero findings.
# CONTRACT: a rule added to audit-app-router.py needs its near-miss added here,
# not only its bait in app-sample/. Every construct in clean-app/ is a false
# positive this suite has already caught once.
ec 0 "audit: negative control is clean" "$PY" "$audit" "$clean"
ec 0 "audit: adversarial clean app is clean" "$PY" "$audit" "$cleanapp"
scanned="$("$PY" "$audit" --json "$cleanapp" 2>/dev/null | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["meta"]["files_scanned"])')"
[ "${scanned:-0}" -ge 7 ] \
  && ok "audit: clean app actually scanned ($scanned files)" \
  || bad "audit: clean app scanned $scanned files - a zero finding count would be meaningless"

# The destructure path shipped dead once: its character class ended in a literal
# newline, but splitlines() has already removed the newline, so
# `const { id } = params` at end-of-line never matched and the branch never ran.
# Assert the exact bait, not just a rule-level count that the type path satisfies.
printf '%s\n' "$out" | grep -q "app/page.tsx:5	.*destructured" \
  && ok "audit: sync-params destructure path fires (regression: was dead code)" \
  || bad "audit: sync-params destructure path is dead again"

# Severity floor actually filters, and results stay sorted worst-first.
err_out="$("$PY" "$audit" --min-severity error "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$err_out" | grep -c .)" = "8" ] && ok "audit: 8 errors" || bad "audit: error count != 8"
printf '%s\n' "$err_out" | grep -qv '^error	' && bad "audit: --min-severity error leaked lower severities" \
  || ok "audit: --min-severity error filters cleanly"
[ "$(printf '%s\n' "$out" | head -1 | cut -f1)" = "error" ] && ok "audit: sorted worst-first" || bad "audit: not sorted worst-first"

# --rules selects, and --limit truncates while flagging it in the envelope.
rule_out="$("$PY" "$audit" --rules middleware-file "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$rule_out" | grep -c .)" = "1" ] && ok "audit: --rules narrows to one" || bad "audit: --rules did not narrow"

# Version gating: the fixture pins next ^16.3.3, so all 16 rules apply. Against
# an older major the eight rules describing 15/16-only breakages must go silent —
# a linter that flags correct code is the failure mode this gate exists to stop.
# CONTRACT: these counts follow the min_major column in the script's RULES table.
ec 2 "audit: --assume-major 0 -> 2" "$PY" "$audit" --assume-major 0 "$fixture"
v15="$("$PY" "$audit" --assume-major 15 "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$v15" | grep -c .)" = "13" ] && ok "audit: 13 findings at next 15" || bad "audit: next-15 count != 13"
v14="$("$PY" "$audit" --assume-major 14 "$fixture" 2>/dev/null)"
[ "$(printf '%s\n' "$v14" | grep -c .)" = "8" ] && ok "audit: 8 findings at next 14" || bad "audit: next-14 count != 8"
for gated in sync-request-api sync-params-prop request-api-in-use-cache \
             parallel-route-no-default nondeterministic-in-use-cache \
             middleware-file edge-runtime-segment revalidate-tag-single-arg; do
  printf '%s\n' "$v14" | grep -qF "	$gated	" \
    && bad "audit: $gated fired at next 14 (rule postdates that major)" \
    || ok "audit: $gated correctly silent at next 14"
done

# --json envelope parses with the documented schema (stdout is data-only).
# Capture first: findings exit 10, and under pipefail that would sink the pipe.
audit_json="$("$PY" "$audit" --json "$fixture" 2>/dev/null)"
printf '%s' "$audit_json" \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); m=d["meta"]; assert m["schema"]=="claude-mods.nextjs-ops.app-audit/v1"; assert m["count"]==17; assert m["truncated"] is False; assert m["next_major"]==16, m; assert "package.json" in m["next_major_source"], m; assert {f["rule"] for f in d["data"]} >= {"sync-request-api","action-without-auth"}' \
  && ok "audit: --json envelope parses" || bad "audit: --json envelope broken"
lim_json="$("$PY" "$audit" --json --limit 2 "$fixture" 2>/dev/null)"
printf '%s' "$lim_json" \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["count"]==2; assert d["meta"]["truncated"] is True' \
  && ok "audit: --limit truncates and says so" || bad "audit: --limit envelope wrong"

# 6. check-nextjs-facts.py — staleness verifier contract (§7), offline-safe
verifier="$here/scripts/check-nextjs-facts.py"
"$PY" -m py_compile "$verifier" && ok "verifier: py_compile clean" || bad "verifier: py_compile failed"
grep -qE '^Examples:$' "$verifier" && ok "verifier: has Examples block" || bad "verifier: no Examples block (docstring)"
ec 0 "verifier: --help exits 0"        "$PY" "$verifier" --help
ec 0 "verifier: --offline consistent"  "$PY" "$verifier" --offline
ec 2 "verifier: bad flag -> 2"         "$PY" "$verifier" --bogus
ec 2 "verifier: --offline --live -> 2" "$PY" "$verifier" --offline --live
ec 3 "verifier: missing catalog -> 3"  "$PY" "$verifier" --offline --catalog /no/such/catalog.json
"$PY" "$verifier" --offline --json -q 2>/dev/null \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.nextjs-ops.facts/v1"; assert d["meta"]["as_of"]' \
  && ok "verifier: --json envelope parses (stdout clean)" || bad "verifier: --json envelope broken"

# Error paths against synthetic catalogs: malformed -> 4, drifted major -> 10.
tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/nextjs-ops-test.$$")"
mkdir -p "$tmp"
printf 'not json' > "$tmp/bad.json"
ec 4 "verifier: malformed catalog -> 4" "$PY" "$verifier" --offline --catalog "$tmp/bad.json"
sed 's/"documented_major": "16"/"documented_major": "99"/' "$here/assets/nextjs-facts.json" > "$tmp/drift.json"
ec 10 "verifier: drifted major -> 10" "$PY" "$verifier" --offline --catalog "$tmp/drift.json"
sed 's/Next\.js 16/Next.js 99/' "$here/assets/nextjs-facts.json" > "$tmp/token.json"
ec 10 "verifier: drifted prose token -> 10" "$PY" "$verifier" --offline --catalog "$tmp/token.json"
rm -rf "$tmp"

# 7. The currency note is the skill's most load-bearing line: it tells a reader
# which semantics the caching tables describe. Assert its exact shape here too,
# so deleting it fails the skill suite and not only the verifier.
grep -qE 'Verified against Next\.js 16\.x \([0-9]{4}-[0-9]{2}-[0-9]{2}\)' "$skill" \
  && ok "SKILL.md carries the dated currency note" || bad "SKILL.md currency note missing/reshaped"

# 8. Template sanity: the starter names its load-bearing, version-gated options
tmpl="$here/assets/next.config.template.ts"
for marker in "cacheComponents" "partialPrefetching" "cacheLife" "remotePatterns" \
              "deploymentId" "X-Accel-Buffering" "allowedOrigins"; do
  grep -qF "$marker" "$tmpl" && ok "config template carries: $marker" || bad "config template missing: $marker"
done
# The template must not demonstrate what the audit script flags.
"$PY" "$audit" --min-severity warn "$tmpl" >/dev/null 2>&1
[ "$?" = "0" ] && ok "config template is audit-clean" || bad "config template trips its own audit rules"

echo "nextjs-ops tests: $pass passed, $fail failed" >&2
[ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
