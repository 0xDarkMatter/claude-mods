#!/usr/bin/env bash
# Scan source files for security-sensitive grep patterns: Python, JavaScript, PHP,
# Twig/Craft templates (.twig and .html), Craft config, and git-tracked .env files.
#
# Usage:   security-scan.sh [DIRECTORY]
# Input:   Optional directory argument; defaults to the current directory.
# Output:  Findings as plain file:line:match records on stdout.
# Stderr:  Progress banners, check status, summaries, and usage errors.
# Exit:    0 clean, 2 usage error, 5 ripgrep missing, 10 findings present.
#
# Examples:
#   security-scan.sh .
#   security-scan.sh src > findings.txt

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: security-scan.sh [DIRECTORY]

Scan source files for security-sensitive grep patterns (Python, JavaScript, PHP,
Twig/Craft templates, Craft config, tracked .env files). DIRECTORY defaults to .
Findings are written to stdout; progress and summaries are written to stderr.

Exit codes:
  0   scan completed with no findings
  2   usage error
  5   ripgrep (rg) not installed - refuses rather than report a false clean
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

# Craft projects keep Twig templates as .html as often as .twig, so the template
# checks use a custom rg type covering both.
RG_TYPES=(--type-add 'tpl:*.{twig,html}')

check_pattern() {
    local name="$1"
    local pattern="$2"
    local type="$3"

    printf 'Checking: %s... ' "$name" >&2

    # -e: several patterns start with "->", which rg would otherwise parse as a flag
    if rg -l -e "$pattern" "$DIR" "${RG_TYPES[@]}" --type "$type" 2>/dev/null | head -5 | grep -q .; then
        printf '%bFOUND%b\n' "$RED" "$NC" >&2
        rg -n -e "$pattern" "$DIR" "${RG_TYPES[@]}" --type "$type" 2>/dev/null | head -10
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

# PHP/Twig/Craft patterns mirror the review greps in references/php-*.md, twig-*.md
# and craft-*.md. Each is a review prompt, not a verdict. Method-call prefixes (->)
# and the [^>:\w$] guard keep PDO ->exec() and $exec() out of the shell check.
printf '\n%s\n' '--- PHP Security Checks ---' >&2
check_pattern "Hardcoded secrets / security key" "([pP]assword|[sS]ecret|[aA]pi_?[kK]ey|[tT]oken|securityKey)['\"]?\s*(=>|=|\()\s*['\"][^'\"\$<{]{8,}['\"]" "php"
check_pattern "unserialize() (A08)" "\bunserialize\s*\(" "php"
check_pattern "eval() usage" "\beval\s*\(" "php"
check_pattern "Shell execution" "(^|[^>:\w\$])(shell_exec|exec|system|passthru|popen)\s*\(" "php"
check_pattern "SQL built by interpolation" "->(where|andWhere|orWhere|having|createCommand|query|exec)\(\s*(\"[^\"]*\\\$|'[^']*'\s*\.\s*\\\$)" "php"
check_pattern "Request data in orderBy/select" "->(orderBy|groupBy|select|addSelect)\([^)]*(getParam|getQueryParam|getBodyParam|\\\$_(GET|POST|REQUEST))" "php"
check_pattern "Template rendered from request data" "render(String|ObjectTemplate)\s*\([^)]*(getParam|getQueryParam|getBodyParam|\\\$_(GET|POST|REQUEST|COOKIE))" "php"
check_pattern "MD5/SHA1 on passwords" "\b(md5|sha1)\s*\([^)]*[pP](ass|wd)" "php"
check_pattern "Craft allowAnonymous = true" "allowAnonymous\s*=\s*(true|self::ALLOW_ANONYMOUS_LIVE)" "php"
check_pattern "CSRF validation disabled" "enableCsrf(Protection|Validation)['\"]?\s*(=>|=|\()\s*false" "php"
check_pattern "devMode hard-coded on" "devMode['\"]?\s*(=>|\()\s*true" "php"

printf '\n%s\n' '--- Twig Template Checks ---' >&2
check_pattern "Twig |raw output" "\|\s*raw\b" "tpl"
check_pattern "Twig autoescape disabled" "\{%-?\s*autoescape\s+false" "tpl"
check_pattern "Twig template_from_string" "template_from_string\s*\(" "tpl"
check_pattern "Twig template name from request" "(\{%-?\s*(include|embed|extends|import)\s+|\b(include|source)\(\s*)craft\.app\.request" "tpl"

printf '\n%s\n' '--- General Security Checks ---' >&2

# Scoped to DIR's own repo (not the caller's cwd). Example/template env files
# (.env.example.production, .env.dist) are committed on purpose by Craft and others.
printf 'Checking: .env files in git... ' >&2
env_tracked="$(git -C "$DIR" ls-files 2>/dev/null | grep -E '(^|/)\.env(\.[^/]*)?$' | grep -vE '\.(example|sample|dist|template)([./]|$)' || true)"
if [[ -n "$env_tracked" ]]; then
    printf '%bFOUND%b\n' "$RED" "$NC" >&2
    printf '%s\n' "$env_tracked"
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
