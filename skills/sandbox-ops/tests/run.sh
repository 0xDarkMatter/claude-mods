#!/usr/bin/env bash
# Offline self-test for sandbox-ops: the facts verifier's drift detection and the
# deletion confirmer's verdicts, for boat and for each provider through a fake CLI
# (SKILL-RESOURCE-PROTOCOL sections 2, 5, 7, 10).
#
# The bugs this suite exists to catch:
#   - the verifier stops noticing drift (a changed rate, a removed CLI flag, prose
#     that no longer states a catalogued fact), so stale boat facts look current;
#   - the verifier reads an unreachable or reshaped docs page as drift (exit 10)
#     instead of "unavailable" (exit 7), which would make the weekly job cry wolf;
#   - a provider card stops stating a catalogued fact, or a provider page changes,
#     and the verifier does not notice;
#   - confirm-gone.sh reports a box gone while its provider still lists it (the
#     20,000-box case: `printf | grep -q` under pipefail once did exactly that), runs
#     on bash 3.2 with an associative array, or ever calls a verb that changes anything.
#
# Usage:   tests/run.sh
#          SANDBOX_OPS_DIR=<copy-of-skill> tests/run.sh   # run against a copy,
#                                                       # e.g. to prove a mutation fails
# Input:   none (self-contained: no network, no boat CLI or account needed)
# Output:  progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or no Python 3: skipped), 1 any failure.
#
# Examples:
#   bash skills/sandbox-ops/tests/run.sh
#   SANDBOX_OPS_DIR=/tmp/sandbox-ops-copy bash skills/sandbox-ops/tests/run.sh
set -uo pipefail

here="${SANDBOX_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$tests_dir/fixtures/live"
fake="$tests_dir/fake-boat.sh"
verifier="$here/scripts/check-sandbox-facts.py"
gone="$here/scripts/confirm-gone.sh"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }
finish() {
  echo "sandbox-ops tests: $pass passed, $fail failed" >&2
  [ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
}
expect() { # desc, want-exit, cmd...
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" = "$want" ] && ok "$desc (exit $got)" || bad "$desc (want $want, got $got)"
}

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    PY="$c"; break
  fi
done
[ -n "$PY" ] || { echo "sandbox-ops tests: no Python 3.8+ - skipped" >&2; exit 0; }

tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sandbox-ops-test.$$")"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# === 1. Layout + frontmatter house rules ===
# CONTRACT: requires `name: sandbox-ops`, `license: MIT` and `metadata.author: claude-mods`.
# A frontmatter trim must keep these or update this block.
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done
[ -f "$here/SKILL.md" ] || { bad "SKILL.md missing"; finish; }
grep -q '^name: sandbox-ops$' "$here/SKILL.md" && ok "name matches directory" || bad "name != sandbox-ops"
grep -q '^license: MIT$' "$here/SKILL.md" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$here/SKILL.md" && ok "metadata.author" || bad "missing metadata.author"
# Every reference must be linked from SKILL.md, or the router never loads it.
for r in "$here"/references/*.md; do
  b="$(basename "$r")"
  grep -q "references/$b" "$here/SKILL.md" && ok "SKILL.md links $b" || bad "SKILL.md does not link $b"
done

# === 2. check-sandbox-facts.py: offline (catalogues vs prose) ===
[ -f "$verifier" ] || { bad "check-sandbox-facts.py missing"; finish; }
out="$("$PY" "$verifier" --help 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'Examples:' \
  && ok "verifier --help exits 0 with Examples" || bad "verifier --help (rc $rc, or no Examples)"
expect "verifier unknown flag is a usage error" 2 "$PY" "$verifier" --bogus
expect "verifier --offline on the shipped skill" 0 "$PY" "$verifier" --offline --skill "$here"

out="$("$PY" "$verifier" --offline --skill "$here" --json 2>/dev/null)"
printf '%s' "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["data"]==[] and d["meta"]["schema"]=="claude-mods.sandbox-ops.sandbox-facts/v1" and d["meta"]["consistent"] is True else 1)' \
  && ok "--offline --json envelope (empty data, schema, consistent)" || bad "--offline --json envelope"

# A copy whose prose no longer states one fact must be drift.
cp -R "$here" "$tmp/drop"
"$PY" - "$tmp/drop" <<'PYEOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for p in [root / "SKILL.md", *sorted((root / "references").glob("*.md"))]:
    p.write_text(p.read_text(encoding="utf-8").replace("$0.036", "$0.0XX"), encoding="utf-8")
PYEOF
expect "--offline: prose that drops a catalogued fact is drift" 10 "$PY" "$verifier" --offline --skill "$tmp/drop" --catalog "$here/assets/facts-boat.json"

# A copy whose prose no longer names one relied-on flag must be drift.
cp -R "$here" "$tmp/flag"
"$PY" - "$tmp/flag" <<'PYEOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for p in [root / "SKILL.md", *sorted((root / "references").glob("*.md"))]:
    p.write_text(p.read_text(encoding="utf-8").replace("--fail-fast", "--fail-quick"), encoding="utf-8")
PYEOF
expect "--offline: prose that drops a relied-on flag is drift" 10 "$PY" "$verifier" --offline --skill "$tmp/flag" --catalog "$here/assets/facts-boat.json"

# SKILL.md states the date the facts were verified; it must match the catalog.
cp -R "$here" "$tmp/date"
"$PY" - "$tmp/date/assets/facts-boat.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8")); d["verified"] = "2001-01-01"
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
expect "--offline: catalog date that SKILL.md does not state is drift" 10 "$PY" "$verifier" --offline --skill "$tmp/date" --catalog "$tmp/date/assets/facts-boat.json"

printf '{"facts": [' > "$tmp/broken.json"
expect "--offline: unparseable catalog" 4 "$PY" "$verifier" --offline --catalog "$tmp/broken.json"
expect "--offline: missing catalog" 3 "$PY" "$verifier" --offline --catalog "$tmp/no-such.json"
printf '{"verified":"2026-10-27","pages":{"pricing":"# Pricing"},"facts":[{"id":"x","page":"nowhere","pattern":"a","skill_text":"a"}],"flags":{}}' > "$tmp/badpage.json"
expect "--offline: a fact on an undeclared page is a malformed catalog" 4 "$PY" "$verifier" --offline --catalog "$tmp/badpage.json"

# === 3. check-sandbox-facts.py: live logic against recorded sources ===
expect "--live vs recorded docs + CLI help" 0 "$PY" "$verifier" --live --fixtures "$fixtures" --skill "$here"

cp -R "$fixtures" "$tmp/rate"
"$PY" - "$tmp/rate/boat/pricing.md" <<'PYEOF'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("**\\$0.036**", "**\\$0.040**"))
PYEOF
expect "--live: a changed published rate is drift" 10 "$PY" "$verifier" --live --fixtures "$tmp/rate" --skill "$here"

cp -R "$fixtures" "$tmp/cliflag"
grep -v -- '--no-snapshots' "$fixtures/boat/cli-help-new.txt" > "$tmp/cliflag/boat/cli-help-new.txt"
expect "--live: a flag gone from boat help is drift" 10 "$PY" "$verifier" --live --fixtures "$tmp/cliflag" --skill "$here"

cp -R "$fixtures" "$tmp/nopage"
rm -f "$tmp/nopage/boat/limits.md"
expect "--live: an unreachable page is unavailable, not drift" 7 "$PY" "$verifier" --live --fixtures "$tmp/nopage" --skill "$here"

cp -R "$fixtures" "$tmp/notitle"
grep -v '^# Security and isolation' "$fixtures/boat/security.md" > "$tmp/notitle/boat/security.md"
expect "--live: a page that lost its title is unavailable, not drift" 7 "$PY" "$verifier" --live --fixtures "$tmp/notitle" --skill "$here"

cp -R "$fixtures" "$tmp/nocli"
rm -f "$tmp/nocli"/boat/cli-help-*.txt
out="$("$PY" "$verifier" --live --fixtures "$tmp/nocli" --skill "$here" --json 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | "$PY" -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["meta"]["cli"]=="skipped" else 1)' \
  && ok "--live: no boat CLI is skipped, docs still decide (exit 0)" || bad "--live without CLI help (rc $rc)"

# === 3b. check-sandbox-facts.py: the other providers' cards and pages ===
expect "verifier: an unknown provider is a usage error" 2 "$PY" "$verifier" --offline --provider nimbus
for prov in e2b modal vercel daytona fly; do
  expect "--offline --provider $prov on the shipped card" 0 "$PY" "$verifier" --offline --provider "$prov" --skill "$here"
done
out="$("$PY" "$verifier" --offline --json 2>/dev/null)"
printf '%s' "$out" | "$PY" -c 'import json,sys; m=json.load(sys.stdin)["meta"]; sys.exit(0 if sorted(m["verified"])==["boat","daytona","e2b","fly","modal","vercel"] else 1)'   && ok "--offline --json names a verified date for every provider" || bad "--offline --json per-provider dates"

# A card that no longer states a catalogued fact is drift (E2B's 5-minute kill default).
cp -R "$here" "$tmp/card"
"$PY" - "$tmp/card/references/e2b.md" <<'PYEOF2'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("defaults to **5 minutes**", "defaults to **an hour**"))
PYEOF2
expect "--offline: a card that drops a fact is drift" 10 "$PY" "$verifier" --offline --provider e2b --skill "$tmp/card"

# A card whose "Facts verified" date differs from its provider's is drift.
cp -R "$here" "$tmp/carddate"
"$PY" - "$tmp/carddate/references/fly.md" <<'PYEOF2'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("Facts verified 2026-11-05", "Facts verified 2001-01-01"))
PYEOF2
expect "--offline: a card date that differs from its provider's is drift" 10 "$PY" "$verifier" --offline --provider fly --skill "$tmp/carddate"

# A provider page whose fact changed is drift; one that lost its title line is unavailable.
cp -R "$fixtures" "$tmp/prate"
"$PY" - "$tmp/prate/daytona/sandboxes.md" <<'PYEOF2'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("15 minutes of inactivity", "30 minutes of inactivity"))
PYEOF2
expect "--live: a changed provider default is drift" 10 "$PY" "$verifier" --live --provider daytona --fixtures "$tmp/prate"
cp -R "$fixtures" "$tmp/ptitle"
grep -v '^title: Sandbox Regions' "$fixtures/vercel/regions.md" > "$tmp/ptitle/vercel/regions.md"
expect "--live: a provider page that lost its title is unavailable" 7 "$PY" "$verifier" --live --provider vercel --fixtures "$tmp/ptitle"

# === 4. confirm-gone.sh: verdicts against a fake boat CLI ===
[ -f "$gone" ] || { bad "confirm-gone.sh missing"; finish; }
grep -Eq '(declare|local|typeset) +-[a-zA-Z]*A' "$gone" \
  && bad "confirm-gone.sh uses an associative array, which macOS's bash 3.2 lacks" \
  || ok "confirm-gone.sh has no associative array (macOS bash 3.2)"
out="$(bash "$gone" --help 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'Examples:' \
  && ok "confirm-gone --help exits 0 with Examples" || bad "confirm-gone --help (rc $rc, or no Examples)"
expect "confirm-gone: no id is a usage error" 2 env BOAT_BIN="$fake" bash "$gone"
expect "confirm-gone: a malformed id is a usage error" 2 env BOAT_BIN="$fake" bash "$gone" 'bx_ok;rm -rf ~'
expect "confirm-gone: no boat CLI is a precondition failure" 5 env BOAT_BIN="$tmp/no-boat" bash "$gone" bx_aaaa

if command -v jq >/dev/null 2>&1; then
  log="$tmp/calls.log"; : > "$log"
  out="$(env BOAT_BIN="$fake" FAKE_LOG="$log" FAKE_GONE="bx_aaaa bx_bbbb" FAKE_LISTED="" \
         bash "$gone" --timeout 4 --interval 1 bx_aaaa bx_bbbb 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "^bx_bbbb	gone$" \
    && ok "confirm-gone: boxes answering not_found and absent from list are gone (exit 0)" \
    || bad "confirm-gone all-gone case (rc $rc, out: $out)"
  if grep -Eq '(^| )(delete|stop|extend|exec|ssh|new)( |$)' "$log"; then
    bad "confirm-gone called a verb that changes state: $(tr '\n' ';' < "$log")"
  else ok "confirm-gone only ever calls info and list"; fi
  grep -q -- '--no-update' "$log" && ! grep -v -- '--no-update' "$log" | grep -q . \
    && ok "confirm-gone passes --no-update on every boat call" || bad "a boat call lacked --no-update"

  expect "confirm-gone: a box still answering info is not gone" 10 \
    env BOAT_BIN="$fake" FAKE_GONE="" bash "$gone" --timeout 2 --interval 1 bx_aaaa
  expect "confirm-gone: info says not_found but list --all still shows it" 10 \
    env BOAT_BIN="$fake" FAKE_GONE="bx_aaaa" FAKE_LISTED="bx_aaaa" bash "$gone" --timeout 2 --interval 1 bx_aaaa
  # 20,000 filler rows: under pipefail, `printf | grep -qx` lets grep exit at the first
  # match, printf takes SIGPIPE and the pipeline fails, so a listed box read as gone.
  expect "confirm-gone: a box listed first in a long list --all is not gone" 10 \
    env BOAT_BIN="$fake" FAKE_GONE="bx_aaaa" FAKE_LISTED="bx_aaaa" FAKE_LIST_PAD=20000 \
    bash "$gone" --timeout 2 --interval 1 bx_aaaa
  expect "confirm-gone: info never answering is unavailable" 7 \
    env BOAT_BIN="$fake" FAKE_INFO_FAIL=1 bash "$gone" --timeout 2 --interval 1 bx_aaaa
  expect "confirm-gone: info never answering but list --all shows it is not gone" 10 \
    env BOAT_BIN="$fake" FAKE_INFO_FAIL=1 FAKE_LISTED="bx_aaaa" bash "$gone" --timeout 2 --interval 1 bx_aaaa
  expect "confirm-gone: list --all failing is unavailable" 7 \
    env BOAT_BIN="$fake" FAKE_GONE="bx_aaaa" FAKE_LIST_FAIL=1 bash "$gone" --timeout 2 --interval 1 bx_aaaa
  out="$(env BOAT_BIN="$fake" FAKE_GONE="bx_aaaa" bash "$gone" --json --timeout 2 --interval 1 bx_aaaa 2>/dev/null)"
  printf '%s' "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); r=d["data"][0]; sys.exit(0 if r=={"id":"bx_aaaa","gone":True,"info":"not_found","listed":False} and d["meta"]["schema"]=="claude-mods.sandbox-ops.confirm-gone/v1" else 1)' 2>/dev/null \
    && ok "confirm-gone --json envelope" || bad "confirm-gone --json envelope: $out"

  # --provider: the id must vanish from that provider's widest list (one fake CLI each).
  expect "confirm-gone: an unknown provider is a usage error" 2 bash "$gone" --provider nimbus abc
  expect "confirm-gone: modal (no CLI list) is a usage error" 2 bash "$gone" --provider modal sb-abc
  expect "confirm-gone: a provider id with shell metacharacters is a usage error" 2 \
    env E2B_BIN="$tests_dir/fake-e2b.sh" bash "$gone" --provider e2b 'abc;rm -rf ~'
  expect "confirm-gone: a missing provider CLI is a precondition failure" 5 \
    env DAYTONA_BIN="$tmp/no-daytona" bash "$gone" --provider daytona abc123
  for prov in e2b vercel daytona fly; do
    case "$prov" in
      e2b) var=E2B_BIN ;; vercel) var=VERCEL_SANDBOX_BIN ;; daytona) var=DAYTONA_BIN ;; fly) var=FLY_BIN ;;
    esac
    pfake="$tests_dir/fake-$prov.sh"; plog="$tmp/$prov.log"; : > "$plog"
    expect "confirm-gone --provider $prov: an id absent from the list is gone" 0 \
      env "$var=$pfake" FAKE_LOG="$plog" FAKE_LISTED="other1 other2" bash "$gone" --provider "$prov" --timeout 2 --interval 1 abc123
    expect "confirm-gone --provider $prov: an id the list still shows is not gone" 10 \
      env "$var=$pfake" FAKE_LOG="$plog" FAKE_LISTED="other1 abc123" bash "$gone" --provider "$prov" --timeout 2 --interval 1 abc123
    expect "confirm-gone --provider $prov: a list that never answers is unavailable" 7 \
      env "$var=$pfake" FAKE_LOG="$plog" FAKE_LIST_FAIL=1 bash "$gone" --provider "$prov" --timeout 2 --interval 1 abc123
    # The fake exits 3 on any other argv, so only the list ever ran if every call matched.
    if grep -qv -- 'list' "$plog"; then bad "confirm-gone --provider $prov ran a non-list command: $(tr '\n' ';' < "$plog")"
    else ok "confirm-gone --provider $prov only ever lists"; fi
  done
  out="$(env E2B_BIN="$tests_dir/fake-e2b.sh" FAKE_LISTED="" bash "$gone" --provider e2b --json --timeout 1 --interval 1 abc123 2>/dev/null)"
  printf '%s' "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["data"]==[{"id":"abc123","gone":True,"info":"skipped","listed":False}] and d["meta"]["provider"]=="e2b" else 1)' 2>/dev/null \
    && ok "confirm-gone --provider e2b --json envelope" || bad "confirm-gone --provider e2b --json envelope: $out"
else
  note "skip" "jq not on PATH: confirm-gone behaviour cases skipped"
fi

finish
