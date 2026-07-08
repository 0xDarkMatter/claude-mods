#!/usr/bin/env bash
# Run pytest with coverage and exit non-zero when coverage is below a threshold.
#
# Usage:   coverage-check.sh [--threshold N] [--cov TARGET] [pytest-args...]
# Input:   a pytest project in the current directory; OR CM_COVERAGE_OVERRIDE=PCT
#          to judge a given percentage offline (test seam — skips pytest entirely)
# Output:  one verdict line on stdout, e.g. "coverage-check<TAB>pass<TAB>90<TAB>80"
# Stderr:  status banners and the full pytest run (progress, coverage report, errors)
# Exit:    0 pass, 1 below threshold, 2 usage, 5 pytest missing
#
# Examples:
#   coverage-check.sh
#   coverage-check.sh --threshold 90 --cov mypkg
#   CM_COVERAGE_OVERRIDE=72 coverage-check.sh --threshold 80   # offline test mode

set -uo pipefail

THRESHOLD=80
COV_TARGET="src"
PYTEST_ARGS=()
OVERRIDE="${CM_COVERAGE_OVERRIDE:-}"

usage() {
  cat <<'EOF'
Usage: coverage-check.sh [--threshold N] [--cov TARGET] [pytest-args...]

Run pytest with coverage; exit non-zero when coverage is below --threshold.
The verdict is one line on stdout; pytest output and status banners go to stderr.

Options:
  --threshold N   minimum coverage percent (default 80)
  --cov TARGET    package to measure (default src)

Offline test seam:
  CM_COVERAGE_OVERRIDE=PCT   skip pytest, judge this percentage instead.

Exit codes: 0 pass, 1 below threshold, 2 usage, 5 pytest missing.

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

# threshold must be a number
if ! [[ "$THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "coverage-check.sh: --threshold must be a number, got '$THRESHOLD'" >&2
  exit 2
fi

# ge PCT THRESHOLD -> returns 0 if PCT >= THRESHOLD (float-safe via awk)
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 >= b+0) }'; }

# Offline test seam: judge a supplied percentage without running pytest. This is
# what lets the threshold logic be exercised offline, deterministically, with no
# slow suite and no network — the same pattern check-ytdlp-version.sh uses.
if [[ -n "$OVERRIDE" ]]; then
  if ! [[ "$OVERRIDE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "coverage-check.sh: CM_COVERAGE_OVERRIDE must be a number, got '$OVERRIDE'" >&2
    exit 2
  fi
  if ge "$OVERRIDE" "$THRESHOLD"; then
    printf 'coverage-check\tpass\t%s\t%s\n' "$OVERRIDE" "$THRESHOLD"; exit 0
  else
    printf 'coverage-check\tfail\t%s\t%s\n' "$OVERRIDE" "$THRESHOLD"; exit 1
  fi
fi

# Live path: run pytest with coverage. All of its output (progress + coverage
# report) is data for a human, not for this script's caller, so it goes to
# stderr; the one-line verdict on stdout is the machine-readable product.
command -v pytest >/dev/null 2>&1 || {
  echo "coverage-check.sh: pytest not found (pip install pytest pytest-cov)" >&2
  exit 5
}

printf '=== Running tests with coverage (threshold %s%%) ===\n' "$THRESHOLD" >&2
pytest \
    --cov="$COV_TARGET" \
    --cov-report=term-missing \
    --cov-report=html \
    --cov-fail-under="$THRESHOLD" \
    "${PYTEST_ARGS[@]}" >&2
rc=$?
case "$rc" in
  0) printf 'coverage-check\tpass\t-\t%s\n' "$THRESHOLD"; exit 0 ;;
  2) printf 'coverage-check\tfail\t-\t%s\n' "$THRESHOLD"; exit 1 ;;  # pytest-cov below-threshold signal
  *) printf 'coverage-check.sh: pytest exited %s\n' "$rc" >&2; exit "$rc" ;;
esac
