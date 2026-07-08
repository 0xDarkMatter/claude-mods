#!/usr/bin/env bash
# Scan source files for security-sensitive grep patterns.
#
# Usage:   security-scan.sh [DIRECTORY]
# Input:   Optional directory argument; defaults to the current directory.
# Output:  Findings as plain file:line:match records on stdout.
# Stderr:  Progress banners, check status, summaries, and usage errors.
# Exit:    0 clean, 2 usage error, 10 findings present.
#
# Examples:
#   security-scan.sh .
#   security-scan.sh src > findings.txt

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: security-scan.sh [DIRECTORY]

Scan source files for security-sensitive grep patterns. DIRECTORY defaults to .
Findings are written to stdout; progress and summaries are written to stderr.

Exit codes:
  0   scan completed with no findings
  2   usage error
  10  scan completed with findings

EXAMPLES
  security-scan.sh .
  security-scan.sh src > findings.txt
EOF
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    -*) printf 'security-scan.sh: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    printf 'security-scan.sh: expected at most one directory\n' >&2
    usage >&2
    exit 2
fi

DIR="${1:-.}"

# rg is the scan engine. A security scanner that silently reports "clean"
# because its engine is missing is worse than useless — refuse loudly (exit 5)
# rather than let a rg-less environment produce a false all-clear.
if ! command -v rg >/dev/null 2>&1; then
    printf 'security-scan.sh: ripgrep (rg) not installed — cannot scan. Install rg; refusing to report a false clean.\n' >&2
    exit 5
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

printf '=== Security Scan: %s ===\n\n' "$DIR" >&2

ISSUES=0

check_pattern() {
    local name="$1"
    local pattern="$2"
    local type="$3"

    printf 'Checking: %s... ' "$name" >&2

    if rg -l "$pattern" "$DIR" --type "$type" 2>/dev/null | head -5 | grep -q .; then
        printf '%bFOUND%b\n' "$RED" "$NC" >&2
        rg -n "$pattern" "$DIR" --type "$type" 2>/dev/null | head -10
        ISSUES=$((ISSUES + 1))
    else
        printf '%bOK%b\n' "$GREEN" "$NC" >&2
    fi
}

printf '%s\n' '--- Python Security Checks ---' >&2
check_pattern "Hardcoded secrets" "(password|secret|api_key|token)\s*=\s*['\"][^'\"]{8,}['\"]" "py"
check_pattern "SQL injection (f-strings)" "execute\(f['\"]" "py"
check_pattern "SQL injection (format)" "execute\(.*\.format\(" "py"
check_pattern "eval() usage" "\beval\s*\(" "py"
check_pattern "exec() usage" "\bexec\s*\(" "py"
check_pattern "pickle.loads" "pickle\.loads?\(" "py"
check_pattern "os.system" "os\.system\(" "py"
check_pattern "shell=True" "subprocess.*shell\s*=\s*True" "py"
check_pattern "MD5 hashing" "hashlib\.md5\(" "py"
check_pattern "SHA1 hashing" "hashlib\.sha1\(" "py"

printf '\n%s\n' '--- JavaScript Security Checks ---' >&2
check_pattern "innerHTML" "\.innerHTML\s*=" "js"
check_pattern "eval() usage" "\beval\s*\(" "js"
check_pattern "document.write" "document\.write\(" "js"

printf '\n%s\n' '--- General Security Checks ---' >&2

printf 'Checking: .env files in git... ' >&2
if git ls-files | grep -E "\.env$|\.env\." | grep -q .; then
    printf '%bFOUND%b\n' "$RED" "$NC" >&2
    git ls-files | grep -E "\.env$|\.env\."
    ISSUES=$((ISSUES + 1))
else
    printf '%bOK%b\n' "$GREEN" "$NC" >&2
fi

printf 'Checking: TODO/FIXME security items... ' >&2
if rg -i "TODO.*security|FIXME.*security|HACK.*security" "$DIR" 2>/dev/null | head -5 | grep -q .; then
    printf '%bFOUND%b\n' "$YELLOW" "$NC" >&2
    rg -i "TODO.*security|FIXME.*security|HACK.*security" "$DIR" 2>/dev/null | head -10
    ISSUES=$((ISSUES + 1))
else
    printf '%bOK%b\n' "$GREEN" "$NC" >&2
fi

printf '\n%s\n' '=== Summary ===' >&2
if [[ $ISSUES -eq 0 ]]; then
    printf '%bNo issues found!%b\n' "$GREEN" "$NC" >&2
    exit 0
fi

printf '%bFound %d potential security issues%b\n' "$RED" "$ISSUES" "$NC" >&2
printf '%s\n' 'Review the findings above and address any real vulnerabilities.' >&2
exit 10
