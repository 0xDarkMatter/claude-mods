#!/usr/bin/env bash
# Self-test for testing-ops — fully offline, deterministic, Linux-safe.
#
# coverage-check.sh gates a project on a coverage threshold. To exercise its
# threshold logic WITHOUT running a slow real pytest suite, the script exposes
# an offline test seam (CM_COVERAGE_OVERRIDE=PCT) that substitutes a given
# percentage for the live measurement — the same pattern check-ytdlp-version.sh
# uses for its installed/latest versions. Asserts the --help contract, semantic
# exit codes (0 pass / 1 below / 2 usage / 5 missing-dep), and stream separation
# (the verdict on stdout; banners + pytest on stderr). Never invokes real pytest.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/coverage-check.sh"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== testing-ops self-test ==="

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
bash -n "$V" 2>/dev/null && ok "bash -n coverage-check.sh" || no "bash -n coverage-check.sh"
bash "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
bash "$V" -h     >/dev/null 2>&1; expect_exit "-h exits 0" 0 $?
out="$(bash "$V" --help 2>/dev/null)"
expect_has "--help has Examples"          "xamples" "$out"
expect_has "--help documents exit 1 (below)" "below threshold" "$out"
expect_has "--help documents exit 2 (usage)" "usage" "$out"
expect_has "--help documents exit 5 (missing-dep)" "pytest missing" "$out"
expect_has "--help names the test seam"   "CM_COVERAGE_OVERRIDE" "$out"
bash "$V" --bogus            >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?
bash "$V" --threshold        >/dev/null 2>&1; expect_exit "--threshold needs value -> 2" 2 $?
bash "$V" --threshold notnum >/dev/null 2>&1; expect_exit "--threshold non-numeric -> 2" 2 $?
CM_COVERAGE_OVERRIDE=bogus bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "bad override -> 2" 2 $?

# ── threshold logic (offline seam; no real pytest) ───────────────────────────
echo "-- threshold logic (seamed) --"
CM_COVERAGE_OVERRIDE=90 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "90>=80 -> pass 0" 0 $?
CM_COVERAGE_OVERRIDE=80 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "80>=80 boundary -> pass 0" 0 $?
CM_COVERAGE_OVERRIDE=79 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "79<80 -> below 1" 1 $?
CM_COVERAGE_OVERRIDE=72 bash "$V" --threshold 80 >/dev/null 2>&1; expect_exit "72<80 -> below 1" 1 $?
CM_COVERAGE_OVERRIDE=100 bash "$V" --threshold 99.5 >/dev/null 2>&1; expect_exit "100>=99.5 float -> pass 0" 0 $?
CM_COVERAGE_OVERRIDE=99.4 bash "$V" --threshold 99.5 >/dev/null 2>&1; expect_exit "99.4<99.5 float -> below 1" 1 $?

# default threshold is 80 when --threshold is omitted
CM_COVERAGE_OVERRIDE=79 bash "$V" >/dev/null 2>&1; expect_exit "default threshold 80: 79 -> below 1" 1 $?
CM_COVERAGE_OVERRIDE=81 bash "$V" >/dev/null 2>&1; expect_exit "default threshold 80: 81 -> pass 0" 0 $?

# ── stream separation (verdict on stdout; no banner leaks) ───────────────────
echo "-- stream separation --"
out="$(CM_COVERAGE_OVERRIDE=90 bash "$V" --threshold 80 2>/dev/null)"; rc=$?
expect_exit "seamed pass exit 0" 0 "$rc"
expect_has "stdout verdict is pass"       "pass" "$out"
expect_has "stdout verdict carries threshold" "80" "$out"
case "$out" in *$'\n'*) no "stdout has more than one line";; *) ok "stdout is a single verdict line";; esac
case "$out" in *"==="*)  no "banner leaked onto stdout";;       *) ok "no banner on stdout";; esac

out="$(CM_COVERAGE_OVERRIDE=72 bash "$V" --threshold 80 2>/dev/null)"; rc=$?
expect_exit "seamed fail exit 1" 1 "$rc"
expect_has "stdout verdict is fail" "fail" "$out"
case "$out" in *"==="*) no "banner leaked onto stdout (fail)";; *) ok "no banner on stdout (fail)";; esac

# ── missing-dep path: no seam AND no pytest -> exit 5 with install hint ───────
echo "-- missing-dep --"
# Scrub PATH so a host-installed pytest is not resolvable, keeping the suite
# offline and deterministic regardless of host tooling (bash itself stays
# resolvable under /usr/bin:/bin). If pytest somehow survives the scrub, SKIP
# rather than ever launching a real suite.
if PATH=/usr/bin:/bin command -v pytest >/dev/null 2>&1; then
  echo "  SKIP  missing-dep exit 5 (pytest resolvable even under scrubbed PATH)"
else
  out="$(PATH=/usr/bin:/bin bash "$V" 2>&1)"; rc=$?
  expect_exit "no pytest, no seam -> 5" 5 "$rc"
  expect_has "names pytest install hint" "pytest" "$out"
  case "$out" in *"pip install pytest"*) ok "hint suggests install";; *) no "hint missing install suggestion";; esac
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
