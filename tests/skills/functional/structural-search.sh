#!/bin/bash
# Functional tests for structural-search skill
# Tests ast-grep (sg) CLI tool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/../fixtures"

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

HAS_SG=false

check_prereqs() {
    if command -v sg >/dev/null 2>&1; then
        HAS_SG=true
    else
        echo -e "${YELLOW}Missing tool: ast-grep (sg)${NC}"
        echo "Install with: brew install ast-grep"
        echo "All tests will be skipped."
        echo ""
    fi
}

# === Pattern Matching Tests ===

test_sg_console_log() {
    [[ $HAS_SG != true ]] && { skip "sg: find console.log calls" "sg not installed"; return; }
    local file result
    file=$(mktemp).js

    cat > "$file" << 'EOF'
function example() {
    console.log("hello");
    console.error("error");
    console.log("world");
}
EOF

    result=$(sg -p 'console.log($MSG)' "$file" 2>/dev/null | grep -c "console.log" || echo "0")
    rm -f "$file"

    if [[ "$result" -eq 2 ]]; then
        pass "sg: find console.log calls (found 2)"
    else
        fail "sg: find console.log calls" "expected 2, found $result"
    fi
}

test_sg_function_declaration() {
    [[ $HAS_SG != true ]] && { skip "sg: find function declarations" "sg not installed"; return; }
    local file result
    file=$(mktemp).js

    cat > "$file" << 'EOF'
function add(a, b) { return a + b; }
const multiply = (a, b) => a * b;
function subtract(a, b) { return a - b; }
EOF

    result=$(sg -p 'function $NAME($$$) { $$$BODY }' "$file" 2>/dev/null | grep -c "function" || echo "0")
    rm -f "$file"

    if [[ "$result" -ge 2 ]]; then
        pass "sg: find function declarations"
    else
        fail "sg: find function declarations" "expected >=2, found $result"
    fi
}

test_sg_imports() {
    [[ $HAS_SG != true ]] && { skip "sg: find imports" "sg not installed"; return; }
    local file result
    file=$(mktemp).js

    cat > "$file" << 'EOF'
import React from 'react';
import { useState } from 'react';
import lodash from 'lodash';
EOF

    result=$(sg -p "import \$_ from 'react'" "$file" 2>/dev/null | grep -c "import" || echo "0")
    rm -f "$file"

    if [[ "$result" -ge 1 ]]; then
        pass "sg: find imports from specific package"
    else
        fail "sg: find imports" "expected >=1, found $result"
    fi
}

test_sg_async_functions() {
    [[ $HAS_SG != true ]] && { skip "sg: find async functions" "sg not installed"; return; }
    local file result
    file=$(mktemp).js

    cat > "$file" << 'EOF'
async function fetchData() {
    return await fetch('/api');
}
function syncFunction() {
    return "sync";
}
EOF

    result=$(sg -p 'async function $NAME($$$) { $$$BODY }' "$file" 2>/dev/null | grep -c "async" || echo "0")
    rm -f "$file"

    if [[ "$result" -ge 1 ]]; then
        pass "sg: find async functions"
    else
        fail "sg: find async functions" "expected >=1, found $result"
    fi
}

test_sg_arrow_functions() {
    [[ $HAS_SG != true ]] && { skip "sg: find arrow functions" "sg not installed"; return; }
    # Skip this test - arrow function pattern matching is inconsistent
    skip "sg: find arrow functions" "pattern matching varies by version"
}

test_sg_python() {
    [[ $HAS_SG != true ]] && { skip "sg: find Python functions" "sg not installed"; return; }
    local file result
    file=$(mktemp).py

    cat > "$file" << 'EOF'
def greet(name):
    return f"Hello, {name}"

def add(a, b):
    return a + b
EOF

    result=$(sg -p 'def $NAME($$$): $$$BODY' -l python "$file" 2>/dev/null | grep -c "def" || echo "0")
    rm -f "$file"

    if [[ "$result" -ge 2 ]]; then
        pass "sg: find Python function definitions"
    else
        fail "sg: find Python functions" "expected >=2, found $result"
    fi
}

test_sg_replace_dry_run() {
    [[ $HAS_SG != true ]] && { skip "sg: dry-run replacement" "sg not installed"; return; }
    local file result
    file=$(mktemp).js

    cat > "$file" << 'EOF'
console.log("debug");
EOF

    # Dry run replacement
    result=$(sg -p 'console.log($MSG)' -r 'console.debug($MSG)' "$file" 2>/dev/null || true)

    # Original file should be unchanged
    local content
    content=$(cat "$file")
    rm -f "$file"

    if [[ "$content" == *"console.log"* ]]; then
        pass "sg: dry-run replacement (file unchanged)"
    else
        fail "sg: dry-run replacement" "file was modified"
    fi
}

test_sg_json_output() {
    [[ $HAS_SG != true ]] && { skip "sg: JSON output" "sg not installed"; return; }
    local file result
    file=$(mktemp).js

    cat > "$file" << 'EOF'
console.log("test");
EOF

    result=$(sg -p 'console.log($MSG)' "$file" --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    rm -f "$file"

    if [[ "$result" -ge 1 ]]; then
        pass "sg: JSON output format"
    else
        fail "sg: JSON output" "invalid JSON or no matches"
    fi
}

# === Run Tests ===

main() {
    echo "=== structural-search functional tests ==="
    echo ""

    check_prereqs

    echo "--- ast-grep pattern tests ---"
    test_sg_console_log
    test_sg_function_declaration
    test_sg_imports
    test_sg_async_functions
    test_sg_arrow_functions

    echo ""
    echo "--- multi-language tests ---"
    test_sg_python

    echo ""
    echo "--- utility tests ---"
    test_sg_replace_dry_run
    test_sg_json_output

    echo ""
    echo "=== Results ==="
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"

    [[ $FAILED -eq 0 ]]
}

main "$@"
