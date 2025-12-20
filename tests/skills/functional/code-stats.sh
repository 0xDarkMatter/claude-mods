#!/bin/bash
# Functional tests for code-stats skill
# Tests tokei and difft CLI tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/../fixtures"
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
    command -v tokei >/dev/null 2>&1 || missing+=("tokei")
    command -v difft >/dev/null 2>&1 || missing+=("difft")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Missing tools: ${missing[*]}${NC}"
        echo "Install with: brew install ${missing[*]}"
        echo "Some tests will be skipped."
        echo ""
    fi
}

# === tokei Tests ===

test_tokei_basic() {
    if ! command -v tokei >/dev/null 2>&1; then
        skip "tokei: basic line count" "tokei not installed"
        return
    fi

    local result
    result=$(tokei "$PROJECT_ROOT" --compact 2>/dev/null | head -5)

    if [[ -n "$result" ]]; then
        pass "tokei: basic line count"
    else
        fail "tokei: basic line count" "no output"
    fi
}

test_tokei_json_output() {
    if ! command -v tokei >/dev/null 2>&1; then
        skip "tokei: JSON output" "tokei not installed"
        return
    fi

    local result
    result=$(tokei "$PROJECT_ROOT" -o json 2>/dev/null | jq 'keys | length')

    if [[ "$result" -gt 0 ]]; then
        pass "tokei: JSON output with languages"
    else
        fail "tokei: JSON output" "no languages found"
    fi
}

test_tokei_exclude() {
    if ! command -v tokei >/dev/null 2>&1; then
        skip "tokei: exclude directories" "tokei not installed"
        return
    fi

    local with_node without_node
    with_node=$(tokei "$PROJECT_ROOT" -o json 2>/dev/null | jq '.Total.code // 0')
    without_node=$(tokei "$PROJECT_ROOT" -e node_modules -o json 2>/dev/null | jq '.Total.code // 0')

    # Both should be valid numbers
    if [[ "$with_node" =~ ^[0-9]+$ && "$without_node" =~ ^[0-9]+$ ]]; then
        pass "tokei: exclude directories works"
    else
        fail "tokei: exclude directories" "invalid output"
    fi
}

# === difft Tests ===

test_difft_basic() {
    if ! command -v difft >/dev/null 2>&1; then
        skip "difft: basic diff" "difft not installed"
        return
    fi

    # Create temp files
    local file1 file2
    file1=$(mktemp)
    file2=$(mktemp)

    echo 'function hello() { console.log("hello"); }' > "$file1"
    echo 'function hello() { console.log("world"); }' > "$file2"

    local result
    result=$(difft "$file1" "$file2" 2>/dev/null || true)

    rm -f "$file1" "$file2"

    if [[ -n "$result" ]]; then
        pass "difft: basic file comparison"
    else
        fail "difft: basic file comparison" "no diff output"
    fi
}

test_difft_identical() {
    if ! command -v difft >/dev/null 2>&1; then
        skip "difft: identical files" "difft not installed"
        return
    fi

    local file1 file2
    file1=$(mktemp)
    file2=$(mktemp)

    echo 'const x = 1;' > "$file1"
    echo 'const x = 1;' > "$file2"

    local result
    result=$(difft "$file1" "$file2" 2>/dev/null || true)

    rm -f "$file1" "$file2"

    # Identical files should have minimal or no output
    if [[ -z "$result" || "$result" == *"No changes"* || ${#result} -lt 50 ]]; then
        pass "difft: identical files show no changes"
    else
        fail "difft: identical files" "unexpected output"
    fi
}

test_difft_syntax_aware() {
    if ! command -v difft >/dev/null 2>&1; then
        skip "difft: syntax-aware diff" "difft not installed"
        return
    fi

    local file1 file2
    file1=$(mktemp)
    file2=$(mktemp)
    mv "$file1" "${file1}.js"; file1="${file1}.js"
    mv "$file2" "${file2}.js"; file2="${file2}.js"

    cat > "$file1" << 'EOF'
function add(a, b) {
    return a + b;
}
EOF

    cat > "$file2" << 'EOF'
function add(a, b) {
    // Added comment
    return a + b;
}
EOF

    local result
    result=$(difft "$file1" "$file2" 2>/dev/null || true)

    rm -f "$file1" "$file2"

    if [[ -n "$result" ]]; then
        pass "difft: syntax-aware JavaScript diff"
    else
        fail "difft: syntax-aware diff" "no output"
    fi
}

# === Run Tests ===

main() {
    echo "=== code-stats functional tests ==="
    echo ""

    check_prereqs

    echo "--- tokei tests ---"
    test_tokei_basic
    test_tokei_json_output
    test_tokei_exclude

    echo ""
    echo "--- difft tests ---"
    test_difft_basic
    test_difft_identical
    test_difft_syntax_aware

    echo ""
    echo "=== Results ==="
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"

    [[ $FAILED -eq 0 ]]
}

main "$@"
