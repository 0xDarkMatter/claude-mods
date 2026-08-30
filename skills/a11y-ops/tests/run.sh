#!/usr/bin/env bash
# Self-test for a11y-ops — scan-a11y.py behaviour against known-bad and
# known-good fixtures, plus resource-citation checks.
#
# Fully offline and self-contained: fixtures are written to a temp dir, nothing
# is fetched. Needs python3 (or python); skips cleanly with exit 0 where absent.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or skipped), 1 a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCAN="$SKILL/scripts/scan-a11y.py"
STATEMENT="$SKILL/assets/accessibility-statement.template.md"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "=== a11y-ops self-test ==="

echo "-- resources --"
[ -f "$SCAN" ]      && ok "scan-a11y.py present"                  || no "scan-a11y.py missing"
[ -f "$STATEMENT" ] && ok "accessibility-statement template present" || no "statement template missing"
for r in references/wcag-conformance.md references/audit-workflow.md references/common-failures.md; do
  [ -f "$SKILL/$r" ] && ok "$r present" || no "$r missing"
  # An uncited resource is dead weight the router never finds (resource protocol §1).
  grep -q "$(basename "$r")" "$SKILL/SKILL.md" && ok "$r cited from SKILL.md" || no "$r not cited from SKILL.md"
done
grep -q 'scan-a11y.py' "$SKILL/SKILL.md" && ok "script cited from SKILL.md" || no "script not cited"
grep -q 'accessibility-statement.template.md' "$SKILL/SKILL.md" && ok "asset cited from SKILL.md" || no "asset not cited"

# Probe by EXECUTING python, not `command -v`: on Windows the python3 name
# resolves to a Microsoft Store stub that is on PATH and exits 49.
PY=""
for c in python3 python py; do
  if "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "  (python not found — skipping dynamic checks)"
  echo "=== $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

echo "-- scan-a11y --"
"$PY" -m py_compile "$SCAN" 2>/dev/null && ok "py_compile clean" || no "py_compile failed"
"$PY" "$SCAN" --help >/dev/null 2>&1 && ok "--help exits 0" || no "--help nonzero"
"$PY" "$SCAN" --help 2>/dev/null | grep -q 'EXAMPLES' && ok "--help lists EXAMPLES" || no "--help has no EXAMPLES"
# The honesty caveat is load-bearing: a caller who reads a clean run as a
# conformance claim has been misled by the tool.
"$PY" "$SCAN" --help 2>/dev/null | grep -qi 'not an audit\|PRE-FILTER' \
  && ok "--help states it is not an audit" || no "--help omits the not-an-audit caveat"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/bad.html" <<'FIXTURE'
<!doctype html>
<html>
<head></head>
<body>
  <h1>Title</h1>
  <h3>Skipped a level</h3>
  <img src="cat.jpg">
  <input type="text" placeholder="Your name">
  <input type="email" id="em">
  <a href="/x"><svg viewBox="0 0 1 1"></svg></a>
  <button></button>
  <a>no href</a>
  <div onclick="go()">Click me</div>
  <span tabindex="3">skip order</span>
  <button aria-hidden="true">hidden but focusable</button>
  <iframe src="/embed"></iframe>
  <video autoplay src="v.mp4"></video>
  <p id="dupe">a</p><p id="dupe">b</p>
  <!-- <img src="commented.jpg"> -->
</body>
</html>
FIXTURE

# Every construct here is CORRECT. Any finding is a false positive, and a linter
# that cries wolf gets muted - which is worse than not having one.
cat > "$TMP/good.html" <<'FIXTURE'
<!doctype html>
<html lang="en">
<head><title>Fine</title></head>
<body>
  <h1>Title</h1>
  <h2>Sub</h2>
  <img src="dog.jpg" alt="A dog">
  <img src="spacer.gif" alt="">
  <label for="nm">Name</label><input id="nm" type="text">
  <input type="search" aria-label="Search products">
  <input type="hidden" name="csrf" value="x">
  <a href="/x" aria-label="Search"><svg aria-hidden="true"></svg></a>
  <button type="button">Go</button>
  <button type="button" onclick="go()">Handler on a real button</button>
  <div role="button" tabindex="0" onclick="go()" onkeydown="k(e)">Proper custom control</div>
  <span tabindex="-1">programmatic focus only</span>
  <iframe src="/embed" title="Embedded map"></iframe>
  <video autoplay muted src="v.mp4"></video>
</body>
</html>
FIXTURE

out="$("$PY" "$SCAN" "$TMP/bad.html" 2>/dev/null)"; rc=$?
[ "$rc" = "10" ] && ok "findings -> exit 10 (domain signal)" || no "bad fixture -> exit $rc, expected 10"
for rule in img-missing-alt input-missing-label placeholder-as-label icon-only-control-unnamed \
            empty-interactive anchor-without-href click-on-non-interactive positive-tabindex \
            aria-hidden-focusable iframe-missing-title autoplay-unmuted heading-skip \
            duplicate-id html-missing-lang missing-title; do
  printf '%s' "$out" | grep -q "$rule" && ok "detects $rule" || no "missed $rule"
done
# Commented-out markup must not be scanned, or every dead example becomes a finding.
printf '%s' "$out" | grep -q 'commented.jpg' && no "flagged commented-out markup" || ok "ignores commented-out markup"

echo "-- false positives --"
gout="$("$PY" "$SCAN" "$TMP/good.html" 2>/dev/null)"; rc=$?
if [ "$rc" = "0" ] && [ -z "$gout" ]; then
  ok "clean fixture produces zero findings (exit 0)"
else
  no "false positives on the clean fixture (exit $rc): $gout"
fi

echo "-- filtering and envelope --"
sev="$("$PY" "$SCAN" --min-severity critical "$TMP/bad.html" 2>/dev/null)"
printf '%s' "$sev" | grep -q 'heading-skip' && no "--min-severity critical leaked a moderate finding" \
                                            || ok "--min-severity filters by level"
printf '%s' "$sev" | grep -q 'img-missing-alt' && ok "--min-severity keeps critical findings" \
                                               || no "--min-severity dropped a critical finding"
one="$("$PY" "$SCAN" --rule positive-tabindex "$TMP/bad.html" 2>/dev/null)"
[ "$(printf '%s' "$one" | grep -c . )" = "1" ] && ok "--rule narrows to a single rule" || no "--rule did not narrow output"

jout="$("$PY" "$SCAN" --json "$TMP/bad.html" 2>/dev/null)"
printf '%s' "$jout" | grep -q 'claude-mods.a11y-ops.scan-a11y/v1' && ok "JSON envelope declares the schema" \
                                                                  || no "JSON schema missing"
printf '%s' "$jout" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["count"]>0 and "by_severity" in d["meta"]' 2>/dev/null \
  && ok "JSON envelope carries counts and severity breakdown" || no "JSON envelope malformed"
# stdout must stay data-only so `| jq` is safe (resource protocol §4).
printf '%s' "$jout" | head -1 | grep -q '^{' && ok "stdout is data-only under --json" || no "stdout polluted under --json"

echo "-- guard rails --"
"$PY" "$SCAN" "$TMP/__absent__" >/dev/null 2>&1; rc=$?
[ "$rc" = "3" ] && ok "missing path -> exit 3" || no "missing path -> exit $rc, expected 3"
mkdir -p "$TMP/empty"
"$PY" "$SCAN" "$TMP/empty" >/dev/null 2>&1; rc=$?
[ "$rc" = "5" ] && ok "no scannable files -> exit 5" || no "empty dir -> exit $rc, expected 5"
"$PY" "$SCAN" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "no args -> exit 2 (usage)" || no "no args -> exit $rc, expected 2"
# node_modules and friends must be skipped or a scan of a real repo never ends.
mkdir -p "$TMP/proj/node_modules" && cp "$TMP/bad.html" "$TMP/proj/node_modules/x.html"
cp "$TMP/good.html" "$TMP/proj/ok.html"
"$PY" "$SCAN" "$TMP/proj" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "skips node_modules when walking a tree" || no "did not skip node_modules (exit $rc)"

echo "-- statement template --"
# Overclaiming is the failure mode this template exists to prevent.
grep -qi 'partially conformant' "$STATEMENT" && ok "template offers a partial-conformance status" \
                                             || no "template has no partial-conformance option"
grep -qi 'do not overclaim\|overclaims is worse' "$STATEMENT" && ok "template warns against overclaiming" \
                                                              || no "template lacks the overclaim warning"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
