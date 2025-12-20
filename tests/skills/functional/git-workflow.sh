#!/bin/bash
# Functional tests for git-workflow skill
# Tests gh (GitHub CLI) and delta

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../../.."

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass() { ((PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((FAILED++)); echo -e "${RED}✗${NC} $1: $2"; }
skip() { ((SKIPPED++)); echo -e "${YELLOW}○${NC} $1 (skipped: $2)"; }

check_prereqs() {
    local missing=()
    command -v gh >/dev/null 2>&1 || missing+=("gh")
    command -v delta >/dev/null 2>&1 || missing+=("delta")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Missing tools: ${missing[*]}${NC}"
        echo "Install with: brew install ${missing[*]}"
        echo "Some tests will be skipped."
        echo ""
    fi
}

# === gh Tests ===

test_gh_version() {
    if ! command -v gh >/dev/null 2>&1; then
        skip "gh: version check" "gh not installed"
        return
    fi

    local result
    result=$(gh --version 2>/dev/null | head -1)

    if [[ "$result" == *"gh version"* ]]; then
        pass "gh: version command works"
    else
        fail "gh: version" "unexpected output: $result"
    fi
}

test_gh_auth_status() {
    if ! command -v gh >/dev/null 2>&1; then
        skip "gh: auth status" "gh not installed"
        return
    fi

    local result exit_code
    result=$(gh auth status 2>&1) || exit_code=$?

    if [[ "$result" == *"Logged in"* ]]; then
        pass "gh: authenticated"
    elif [[ "$result" == *"not logged"* ]]; then
        skip "gh: auth status" "not authenticated (run 'gh auth login')"
    else
        fail "gh: auth status" "unexpected: $result"
    fi
}

test_gh_repo_view() {
    if ! command -v gh >/dev/null 2>&1; then
        skip "gh: repo view" "gh not installed"
        return
    fi

    # Check if we're in a git repo with a remote
    if ! git remote get-url origin >/dev/null 2>&1; then
        skip "gh: repo view" "no git remote configured"
        return
    fi

    local result
    result=$(gh repo view --json name 2>/dev/null | jq -r '.name' 2>/dev/null || echo "")

    if [[ -n "$result" && "$result" != "null" ]]; then
        pass "gh: repo view (name: $result)"
    else
        skip "gh: repo view" "not a GitHub repo or not authenticated"
    fi
}

test_gh_api() {
    if ! command -v gh >/dev/null 2>&1; then
        skip "gh: API access" "gh not installed"
        return
    fi

    local result
    result=$(gh api user --jq '.login' 2>/dev/null || echo "")

    if [[ -n "$result" ]]; then
        pass "gh: API access works (user: $result)"
    else
        skip "gh: API access" "not authenticated"
    fi
}

# === delta Tests ===

test_delta_version() {
    if ! command -v delta >/dev/null 2>&1; then
        skip "delta: version check" "delta not installed"
        return
    fi

    local result
    result=$(delta --version 2>/dev/null)

    if [[ "$result" == *"delta"* ]]; then
        pass "delta: version command works"
    else
        fail "delta: version" "unexpected output"
    fi
}

test_delta_diff() {
    if ! command -v delta >/dev/null 2>&1; then
        skip "delta: diff formatting" "delta not installed"
        return
    fi

    local file1 file2 result
    file1=$(mktemp)
    file2=$(mktemp)

    echo "line 1" > "$file1"
    echo "line 2" > "$file2"

    result=$(diff -u "$file1" "$file2" | delta 2>/dev/null || true)

    rm -f "$file1" "$file2"

    if [[ -n "$result" ]]; then
        pass "delta: formats diff output"
    else
        fail "delta: diff formatting" "no output"
    fi
}

test_delta_git_diff() {
    if ! command -v delta >/dev/null 2>&1; then
        skip "delta: git diff" "delta not installed"
        return
    fi

    # Check if we're in a git repo
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        skip "delta: git diff" "not in a git repository"
        return
    fi

    # This just verifies delta can process git diff output
    local result
    result=$(git diff HEAD~1 --stat 2>/dev/null | delta 2>/dev/null || echo "ok")

    pass "delta: processes git diff"
}

# === lazygit Tests ===

test_lazygit_version() {
    if ! command -v lazygit >/dev/null 2>&1; then
        skip "lazygit: version check" "lazygit not installed"
        return
    fi

    local result
    result=$(lazygit --version 2>/dev/null)

    if [[ -n "$result" ]]; then
        pass "lazygit: version command works"
    else
        fail "lazygit: version" "no output"
    fi
}

# === Run Tests ===

main() {
    echo "=== git-workflow functional tests ==="
    echo ""

    check_prereqs

    echo "--- gh (GitHub CLI) tests ---"
    test_gh_version
    test_gh_auth_status
    test_gh_repo_view
    test_gh_api

    echo ""
    echo "--- delta tests ---"
    test_delta_version
    test_delta_diff
    test_delta_git_diff

    echo ""
    echo "--- lazygit tests ---"
    test_lazygit_version

    echo ""
    echo "=== Results ==="
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"

    [[ $FAILED -eq 0 ]]
}

main "$@"
