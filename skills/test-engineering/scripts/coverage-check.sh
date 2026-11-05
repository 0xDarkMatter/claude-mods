#!/usr/bin/env bash
# Run pytest with coverage and report the percentage; with --threshold, also fail below it.
#
# Usage:   coverage-check.sh [--threshold N] [--cov TARGET] [pytest-args...]
# Input:   a pytest project in the current directory; OR CM_COVERAGE_OVERRIDE=PCT
#          to judge a given percentage offline (test seam - skips pytest entirely)
# Output:  one verdict line on stdout: "coverage-check<TAB>report<TAB>87<TAB>-" by default,
#          "coverage-check<TAB>pass|fail<TAB>87<TAB>80" with --threshold 80
# Stderr:  status banners and the full pytest run (progress, coverage report, errors)
# Exit:    0 report or pass, 1 below threshold (only with --threshold), 2 usage,
#          5 pytest missing; a failing test run passes pytest's own exit code through
#
# Examples:
#   coverage-check.sh
#   coverage-check.sh --threshold 90 --cov mypkg
#   CM_COVERAGE_OVERRIDE=72 coverage-check.sh --threshold 80   # offline test mode
#
# REPORT-ONLY BY DEFAULT, deliberately (test-engineering decision Q7). Coverage finds code
# no test executes; it does not measure whether any test would notice that code breaking.
# In a 13-repo survey the only repo gated on coverage was the one with coverage-filler
# tests (S18: tests written to touch lines, asserting nothing). Protection is measured by
# killed mutants (scripts/mutate.mjs). --threshold keeps the old gate for teams that want it.

set -uo pipefail

THRESHOLD=""
COV_TARGET="src"
PYTEST_ARGS=()
OVERRIDE="${CM_COVERAGE_OVERRIDE:-}"

usage() {
  cat <<'EOF'
Usage: coverage-check.sh [--threshold N] [--cov TARGET] [pytest-args...]

Run pytest with coverage and report the total percentage (report only by default).
With --threshold N it also exits 1 when coverage is below N.
The verdict is one line on stdout; pytest output and status banners go to stderr.

Options:
  --threshold N   fail below N percent (default: none - report only, never fail)
  --cov TARGET    package to measure (default src)

Offline test seam:
  CM_COVERAGE_OVERRIDE=PCT   skip pytest, judge this percentage instead.

Exit codes: 0 report or pass, 1 below threshold, 2 usage, 5 pytest missing.

Examples:
  coverage-check.sh
  coverage-check.sh --threshold 90 --cov mypkg
  CM_COVERAGE_OVERRIDE=72 coverage-check.sh --threshold 80
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --threshold)
      [[ $# -ge 2 ]] || { echo "coverage-check.sh: --threshold needs a value" >&2; exit 2; }
      THRESHOLD="$2"; shift 2 ;;
    --threshold=*) THRESHOLD="${1#--threshold=}"; shift ;;
    --cov)
      [[ $# -ge 2 ]] || { echo "coverage-check.sh: --cov needs a value" >&2; exit 2; }
      COV_TARGET="$2"; shift 2 ;;
    --cov=*) COV_TARGET="${1#--cov=}"; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do PYTEST_ARGS+=("$1"); shift; done ;;
    -*) echo "coverage-check.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) PYTEST_ARGS+=("$1"); shift ;;
  esac
done

isnum() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
if [[ -n "$THRESHOLD" ]] && ! isnum "$THRESHOLD"; then
  echo "coverage-check.sh: --threshold must be a number, got '$THRESHOLD'" >&2
  exit 2
fi

# ge PCT THRESHOLD -> returns 0 if PCT >= THRESHOLD (float-safe via awk)
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 >= b+0) }'; }

verdict() { # $1=percent
  if [[ -z "$THRESHOLD" ]]; then
    printf 'coverage-check\treport\t%s\t-\n' "$1"; return 0
  fi
  if ge "$1" "$THRESHOLD"; then
    printf 'coverage-check\tpass\t%s\t%s\n' "$1" "$THRESHOLD"; return 0
  fi
  printf 'coverage-check\tfail\t%s\t%s\n' "$1" "$THRESHOLD"; return 1
}

# Offline test seam: judge a supplied percentage without running pytest, so the verdict
# logic is exercised offline and deterministically (the check-ytdlp-version.sh pattern).
if [[ -n "$OVERRIDE" ]]; then
  isnum "$OVERRIDE" || { echo "coverage-check.sh: CM_COVERAGE_OVERRIDE must be a number, got '$OVERRIDE'" >&2; exit 2; }
  verdict "$OVERRIDE"; exit $?
fi

# Live path. pytest's output (progress + coverage table) is for humans, so it goes to
# stderr; the TOTAL row is read back from a copy to produce the stdout verdict.
command -v pytest >/dev/null 2>&1 || {
  echo "coverage-check.sh: pytest not found (pip install pytest pytest-cov)" >&2
  exit 5
}

log="$(mktemp)"; trap 'rm -f "$log"' EXIT
printf '=== Running tests with coverage (%s) ===\n' "${THRESHOLD:+threshold $THRESHOLD%}" >&2
pytest --cov="$COV_TARGET" --cov-report=term-missing "${PYTEST_ARGS[@]}" 2>&1 | tee "$log" >&2
rc=${PIPESTATUS[0]}
[[ "$rc" -eq 0 ]] || { printf 'coverage-check.sh: pytest exited %s\n' "$rc" >&2; exit "$rc"; }
pct="$(awk '/^TOTAL/ { v = $NF } END { gsub(/%/, "", v); print v }' "$log")"
isnum "$pct" || { echo "coverage-check.sh: no TOTAL row in the coverage report" >&2; exit 1; }
verdict "$pct"
