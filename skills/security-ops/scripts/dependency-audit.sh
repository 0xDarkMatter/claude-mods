#!/usr/bin/env bash
# Audit project dependencies with available ecosystem vulnerability scanners:
# pip-audit/safety, npm audit, govulncheck, cargo audit, trivy, composer audit.
#
# Usage:   dependency-audit.sh
# Input:   Project manifests in the current directory; no stdin input.
# Output:  Raw vulnerability scanner findings on stdout.
# Stderr:  Progress banners, missing-tool guidance, summaries, and usage errors.
# Exit:    0 clean, 2 usage error, 10 findings present.
#
# Examples:
#   dependency-audit.sh
#   dependency-audit.sh > dependency-findings.txt

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: dependency-audit.sh

Run available ecosystem vulnerability scanners for manifests in the current
directory (requirements.txt/pyproject.toml, package.json, go.mod, Cargo.toml,
Dockerfile, composer.json). Findings are written to stdout; progress is written
to stderr.

Exit codes:
  0   audits completed with no findings
  2   usage error
  10  one or more scanners reported findings

EXAMPLES
  dependency-audit.sh
  dependency-audit.sh > dependency-findings.txt
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    '') ;;
    *) printf 'dependency-audit.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    printf 'dependency-audit.sh: expected no arguments\n' >&2
    usage >&2
    exit 2
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
ISSUES=0

run_audit() {
    if "$@"; then
        return 0
    fi
    ISSUES=$((ISSUES + 1))
    return 0
}

printf '%s\n\n' '=== Dependency Security Audit ===' >&2

if [[ -f requirements.txt || -f pyproject.toml ]]; then
    printf '%s\n' '--- Python Dependencies ---' >&2
    if command -v pip-audit >/dev/null 2>&1; then
        printf '%s\n' 'Running pip-audit...' >&2
        run_audit pip-audit
    elif command -v safety >/dev/null 2>&1; then
        printf '%s\n' 'Running safety check...' >&2
        run_audit safety check
    else
        printf '%bInstall pip-audit or safety for Python vulnerability scanning%b\n' "$YELLOW" "$NC" >&2
        printf '%s\n' '  pip install pip-audit' >&2
    fi
fi

if [[ -f package.json ]]; then
    printf '%s\n' '--- Node.js Dependencies ---' >&2
    if command -v npm >/dev/null 2>&1; then
        printf '%s\n' 'Running npm audit...' >&2
        run_audit npm audit --audit-level=moderate
    fi
fi

if [[ -f go.mod ]]; then
    printf '%s\n' '--- Go Dependencies ---' >&2
    if command -v govulncheck >/dev/null 2>&1; then
        printf '%s\n' 'Running govulncheck...' >&2
        run_audit govulncheck ./...
    else
        printf '%bInstall govulncheck for Go vulnerability scanning%b\n' "$YELLOW" "$NC" >&2
        printf '%s\n' '  go install golang.org/x/vuln/cmd/govulncheck@latest' >&2
    fi
fi

if [[ -f Cargo.toml ]]; then
    printf '%s\n' '--- Rust Dependencies ---' >&2
    if command -v cargo-audit >/dev/null 2>&1; then
        printf '%s\n' 'Running cargo audit...' >&2
        run_audit cargo audit
    else
        printf '%bInstall cargo-audit for Rust vulnerability scanning%b\n' "$YELLOW" "$NC" >&2
        printf '%s\n' '  cargo install cargo-audit' >&2
    fi
fi

if [[ -f Dockerfile ]]; then
    printf '%s\n' '--- Docker Image ---' >&2
    if command -v trivy >/dev/null 2>&1; then
        printf '%s\n' 'Running trivy on Dockerfile...' >&2
        run_audit trivy config Dockerfile
    else
        printf '%bInstall trivy for container vulnerability scanning%b\n' "$YELLOW" "$NC" >&2
        printf '%s\n' '  brew install trivy' >&2
    fi
fi

if [[ -f composer.json ]]; then
    printf '%s\n' '--- PHP Dependencies (Composer) ---' >&2
    # `audit` exists from Composer 2.4; probe for it so an old Composer's "command not
    # defined" error is never counted as a vulnerability. Any non-zero exit is a
    # finding: 2.8.4-2.9 used a 1/2/3 bitmask, 2.10+ returns only 0/1, so never decode it.
    # --locked reads composer.lock without needing vendor/ (2.10+ fails without it).
    if ! command -v composer >/dev/null 2>&1; then
        printf '%bInstall Composer 2.4+ for PHP vulnerability scanning (composer audit)%b\n' "$YELLOW" "$NC" >&2
        printf '%s\n' '  https://getcomposer.org/download/  (inside DDEV: ddev composer audit)' >&2
    elif ! composer audit --help >/dev/null 2>&1; then
        printf '%bComposer predates 2.4 (no audit command): composer self-update, or require roave/security-advisories%b\n' "$YELLOW" "$NC" >&2
    elif [[ -f composer.lock ]]; then
        printf '%s\n' 'Running composer audit --locked...' >&2
        run_audit composer audit --locked --format=plain --no-interaction
    else
        printf '%s\n' 'Running composer audit (no composer.lock: auditing vendor/)...' >&2
        run_audit composer audit --format=plain --no-interaction
    fi
fi

printf '%s\n' '=== Audit Complete ===' >&2
if [[ $ISSUES -gt 0 ]]; then
    printf '%bOne or more dependency scanners reported findings%b\n' "$RED" "$NC" >&2
    exit 10
fi
exit 0
