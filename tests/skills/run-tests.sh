#!/bin/bash
# Main test runner for skill tests
# Runs all validation and functional tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Test results
SUITE_PASSED=0
SUITE_FAILED=0

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [TEST...]

Run skill tests.

Options:
    -h, --help      Show this help message
    -v, --verbose   Show detailed output
    -q, --quiet     Only show failures
    --triggers      Run trigger validation only
    --functional    Run functional tests only
    --list          List available tests
    --report        Generate timestamped report in reports/

Tests:
    all             Run all tests (default)
    triggers        Trigger keyword validation
    data-processing Functional tests for data-processing skill
    code-stats      Functional tests for code-stats skill
    git-workflow    Functional tests for git-workflow skill
    structural-search Functional tests for structural-search skill

Examples:
    $(basename "$0")                    # Run all tests
    $(basename "$0") triggers           # Run trigger validation only
    $(basename "$0") data-processing    # Run data-processing tests only
    $(basename "$0") --functional       # Run all functional tests

EOF
}

run_test_suite() {
    local name="$1"
    local script="$2"

    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $name${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}\n"

    if [[ -x "$script" ]]; then
        if "$script"; then
            ((SUITE_PASSED++))
            echo -e "\n${GREEN}✓ $name passed${NC}"
        else
            ((SUITE_FAILED++))
            echo -e "\n${RED}✗ $name failed${NC}"
        fi
    else
        echo -e "${RED}Script not found or not executable: $script${NC}"
        ((SUITE_FAILED++))
    fi
}

run_triggers() {
    run_test_suite "Trigger Validation" "$SCRIPT_DIR/validate-triggers.sh"
}

run_functional() {
    local tests=("$@")

    if [[ ${#tests[@]} -eq 0 ]]; then
        tests=(data-processing code-stats git-workflow structural-search)
    fi

    for test in "${tests[@]}"; do
        local script="$SCRIPT_DIR/functional/${test}.sh"
        if [[ -f "$script" ]]; then
            run_test_suite "$test" "$script"
        else
            echo -e "${YELLOW}Skipping $test: no test script found${NC}"
        fi
    done
}

list_tests() {
    echo "Available tests:"
    echo ""
    echo "  Validation:"
    echo "    triggers          - Validate skill frontmatter and trigger keywords"
    echo ""
    echo "  Functional:"
    for script in "$SCRIPT_DIR"/functional/*.sh; do
        if [[ -f "$script" ]]; then
            local name
            name=$(basename "$script" .sh)
            echo "    $name"
        fi
    done
    echo ""
    echo "  Groups:"
    echo "    all               - Run all tests"
    echo "    --triggers        - Run trigger validation only"
    echo "    --functional      - Run all functional tests"
}

print_summary() {
    echo -e "\n${BOLD}════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Test Summary${NC}"
    echo -e "${BOLD}════════════════════════════════════════${NC}"
    echo -e "  Suites passed: ${GREEN}$SUITE_PASSED${NC}"
    echo -e "  Suites failed: ${RED}$SUITE_FAILED${NC}"
    echo ""

    if [[ $SUITE_FAILED -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All tests passed!${NC}"
    else
        echo -e "${RED}${BOLD}Some tests failed.${NC}"
    fi
}

# === Main ===

generate_report() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H%M%S')
    local report_dir="$SCRIPT_DIR/reports"
    local report_file="$report_dir/report_${timestamp}.md"

    mkdir -p "$report_dir"

    {
        echo "# Skill Test Report"
        echo ""
        # Re-run tests and capture output (strip colors)
        "$0" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
        echo ""
        echo "---"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host: $(hostname)"
    } > "$report_file"

    echo -e "${GREEN}Report saved: $report_file${NC}"
}

main() {
    local run_triggers=false
    local run_functional=false
    local generate_report=false
    local specific_tests=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                set -x
                shift
                ;;
            -q|--quiet)
                # Quiet mode - could redirect stdout
                shift
                ;;
            --triggers)
                run_triggers=true
                shift
                ;;
            --functional)
                run_functional=true
                shift
                ;;
            --list)
                list_tests
                exit 0
                ;;
            --report)
                generate_report
                exit 0
                ;;
            all)
                run_triggers=true
                run_functional=true
                shift
                ;;
            triggers)
                run_triggers=true
                shift
                ;;
            *)
                specific_tests+=("$1")
                shift
                ;;
        esac
    done

    # Default: run everything
    if [[ $run_triggers == false && $run_functional == false && ${#specific_tests[@]} -eq 0 ]]; then
        run_triggers=true
        run_functional=true
    fi

    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║         Skill Test Runner                ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    # Make scripts executable
    chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/functional/*.sh 2>/dev/null || true

    # Run requested tests
    if [[ $run_triggers == true ]]; then
        run_triggers
    fi

    if [[ ${#specific_tests[@]} -gt 0 ]]; then
        run_functional "${specific_tests[@]}"
    elif [[ $run_functional == true ]]; then
        run_functional
    fi

    print_summary

    [[ $SUITE_FAILED -eq 0 ]]
}

main "$@"
