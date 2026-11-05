#!/usr/bin/env bash
# Run every skill's behavioural test suite (skills/*/tests/run.sh), then every
# cross-mechanism end-to-end suite (tests/skills/functional/<skill>/e2e.sh).
# Suites are responsible for their own OS gating (exit 0 with a skip
# message on unsupported platforms). Any nonzero exit fails this runner.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

suites=(skills/*/tests/run.sh)
if [ ! -e "${suites[0]}" ]; then
    echo "No skill test suites found (skills/*/tests/run.sh)"
    exit 0
fi
# e2e suites are globbed, not registered, for the same reason as the per-skill
# ones: a suite nothing runs rots. fleet-ops' e2e sat outside this runner and
# had drifted to 7 FAILs by the time it was wired in (2026-09-28).
e2e=(tests/skills/functional/*/e2e.sh)
if [ -e "${e2e[0]}" ]; then suites+=("${e2e[@]}"); fi

failed=0
total=0
for suite in "${suites[@]}"; do
    total=$((total + 1))
    case "$suite" in
        skills/*) name="$(basename "$(dirname "$(dirname "$suite")")")" ;;
        *)        name="$(basename "$(dirname "$suite")") (e2e)" ;;
    esac
    echo "=== $name"
    if bash "$suite"; then
        echo "--- $name: PASS"
    else
        rc=$?
        echo "--- $name: FAIL (exit $rc)"
        failed=$((failed + 1))
    fi
    echo
done

echo "Skill test suites: $((total - failed))/$total passed"
[ "$failed" -eq 0 ] || exit 1
