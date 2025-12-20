#!/bin/bash
# Functional tests for data-processing skill
# Tests jq and yq CLI tools

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

# Check prerequisites
HAS_JQ=false
HAS_YQ=false

check_prereqs() {
    local missing=()
    if command -v jq >/dev/null 2>&1; then
        HAS_JQ=true
    else
        missing+=("jq")
    fi

    if command -v yq >/dev/null 2>&1; then
        HAS_YQ=true
    else
        missing+=("yq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Missing tools: ${missing[*]}${NC}"
        echo "Install with: brew install ${missing[*]}"
        echo "Some tests will be skipped."
        echo ""
    fi
}

# Test helper
assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local name="$1"
    local needle="$2"
    local haystack="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "output does not contain '$needle'"
    fi
}

# === jq Tests ===

test_jq_extract_field() {
    if [[ $HAS_JQ != true ]]; then
        skip "jq: extract single field" "jq not installed"
        return
    fi
    local result
    result=$(echo '{"name": "test-app"}' | jq -r '.name')
    assert_eq "jq: extract single field" "test-app" "$result"
}

test_jq_nested_field() {
    [[ $HAS_JQ != true ]] && { skip "jq: extract nested field" "jq not installed"; return; }
    local result
    result=$(echo '{"scripts": {"build": "tsc"}}' | jq -r '.scripts.build')
    assert_eq "jq: extract nested field" "tsc" "$result"
}

test_jq_array_filter() {
    [[ $HAS_JQ != true ]] && { skip "jq: filter array by condition" "jq not installed"; return; }
    local result
    result=$(echo '{"users": [{"name": "Alice", "active": true}, {"name": "Bob", "active": false}]}' | jq -r '.users[] | select(.active == true) | .name')
    assert_eq "jq: filter array by condition" "Alice" "$result"
}

test_jq_array_length() {
    [[ $HAS_JQ != true ]] && { skip "jq: count array length" "jq not installed"; return; }
    local result
    result=$(echo '{"items": [1, 2, 3, 4, 5]}' | jq '.items | length')
    assert_eq "jq: count array length" "5" "$result"
}

test_jq_raw_output() {
    [[ $HAS_JQ != true ]] && { skip "jq: raw string output" "jq not installed"; return; }
    local quoted unquoted
    quoted=$(echo '{"name": "myapp"}' | jq '.name')
    unquoted=$(echo '{"name": "myapp"}' | jq -r '.name')

    if [[ "$quoted" == '"myapp"' && "$unquoted" == "myapp" ]]; then
        pass "jq: raw string output (-r flag)"
    else
        fail "jq: raw string output" "quoted='$quoted', unquoted='$unquoted'"
    fi
}

test_jq_map_transform() {
    [[ $HAS_JQ != true ]] && { skip "jq: map transformation" "jq not installed"; return; }
    local result
    result=$(echo '{"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}' | jq '[.users[] | {id, name}] | length')
    assert_eq "jq: map transformation" "2" "$result"
}

test_jq_package_json() {
    [[ $HAS_JQ != true ]] && { skip "jq: parse package.json" "jq not installed"; return; }
    if [[ -f "$FIXTURES/package.json" ]]; then
        local name version
        name=$(jq -r '.name' "$FIXTURES/package.json")
        version=$(jq -r '.version' "$FIXTURES/package.json")

        if [[ -n "$name" && -n "$version" ]]; then
            pass "jq: parse package.json fixture"
        else
            fail "jq: parse package.json" "name='$name', version='$version'"
        fi
    else
        skip "jq: parse package.json fixture" "fixture not found"
    fi
}

# === yq Tests ===

test_yq_extract_field() {
    [[ $HAS_YQ != true ]] && { skip "yq: extract YAML field" "yq not installed"; return; }
    local result
    result=$(echo -e "name: myapp\nversion: 2.0.0" | yq -r '.name')
    assert_eq "yq: extract YAML field" "myapp" "$result"
}

test_yq_list_keys() {
    [[ $HAS_YQ != true ]] && { skip "yq: list keys count" "yq not installed"; return; }
    local result
    result=$(echo -e "database:\n  host: localhost\n  port: 5432" | yq '.database | keys | length')
    assert_eq "yq: list keys count" "2" "$result"
}

test_yq_docker_compose() {
    [[ $HAS_YQ != true ]] && { skip "yq: Docker Compose services" "yq not installed"; return; }
    local result
    result=$(echo -e "services:\n  web:\n    image: nginx\n  db:\n    image: postgres" | yq '.services | keys | length')
    assert_eq "yq: Docker Compose services" "2" "$result"
}

test_yq_toml_parsing() {
    [[ $HAS_YQ != true ]] && { skip "yq: TOML parsing" "yq not installed"; return; }
    local result
    result=$(echo -e '[package]\nname = "myapp"' | yq -p toml -r '.package.name')
    assert_eq "yq: TOML parsing" "myapp" "$result"
}

test_yq_config_fixture() {
    [[ $HAS_YQ != true ]] && { skip "yq: parse config.yaml" "yq not installed"; return; }
    if [[ -f "$FIXTURES/config.yaml" ]]; then
        local result
        result=$(yq -r '.name' "$FIXTURES/config.yaml")
        if [[ -n "$result" && "$result" != "null" ]]; then
            pass "yq: parse config.yaml fixture"
        else
            fail "yq: parse config.yaml" "got '$result'"
        fi
    else
        skip "yq: parse config.yaml fixture" "fixture not found"
    fi
}

# === Run Tests ===

main() {
    echo "=== data-processing functional tests ==="
    echo ""

    check_prereqs

    echo "--- jq tests ---"
    test_jq_extract_field
    test_jq_nested_field
    test_jq_array_filter
    test_jq_array_length
    test_jq_raw_output
    test_jq_map_transform
    test_jq_package_json

    echo ""
    echo "--- yq tests ---"
    test_yq_extract_field
    test_yq_list_keys
    test_yq_docker_compose
    test_yq_toml_parsing
    test_yq_config_fixture

    echo ""
    echo "=== Results ==="
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"

    [[ $FAILED -eq 0 ]]
}

main "$@"
