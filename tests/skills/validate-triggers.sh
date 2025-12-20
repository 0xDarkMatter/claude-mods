#!/bin/bash
# Validate skill trigger keywords
# Ensures descriptions contain advertised triggers and follows naming conventions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$SCRIPT_DIR/../../skills"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

pass() { ((PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((FAILED++)); echo -e "${RED}✗${NC} $1: $2"; }
warn() { ((WARNINGS++)); echo -e "${YELLOW}!${NC} $1: $2"; }

# Extract frontmatter field from SKILL.md
get_frontmatter() {
    local file="$1"
    local field="$2"

    # Extract value between --- markers (|| true to prevent set -e failure)
    sed -n '/^---$/,/^---$/p' "$file" | grep "^${field}:" | sed "s/^${field}: *//" | sed 's/^"//' | sed 's/"$//' || true
}

# Validate skill name format
validate_name() {
    local skill_dir="$1"
    local name="$2"
    local dirname
    dirname=$(basename "$skill_dir")

    # Check name matches directory
    if [[ "$name" != "$dirname" ]]; then
        fail "$dirname" "name '$name' doesn't match directory"
        return 1
    fi

    # Check format: lowercase, numbers, hyphens only
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
        fail "$dirname" "name must be lowercase alphanumeric with hyphens"
        return 1
    fi

    # Check length
    if [[ ${#name} -gt 64 ]]; then
        fail "$dirname" "name exceeds 64 characters"
        return 1
    fi

    return 0
}

# Validate description has triggers
validate_description() {
    local skill_dir="$1"
    local description="$2"
    local dirname
    dirname=$(basename "$skill_dir")

    # Check non-empty
    if [[ -z "$description" ]]; then
        fail "$dirname" "description is empty"
        return 1
    fi

    # Check length
    if [[ ${#description} -gt 1024 ]]; then
        fail "$dirname" "description exceeds 1024 characters"
        return 1
    fi

    # Check for trigger keywords
    if [[ "$description" != *"Triggers on"* && "$description" != *"triggers on"* && "$description" != *"Auto-activates"* ]]; then
        warn "$dirname" "no 'Triggers on:' section in description"
    fi

    return 0
}

# Extract and validate trigger keywords
validate_triggers() {
    local skill_dir="$1"
    local description="$2"
    local dirname
    dirname=$(basename "$skill_dir")

    # Extract triggers after "Triggers on" using sed (macOS compatible)
    local triggers=""

    if [[ "$description" == *"Triggers on:"* ]]; then
        triggers=$(echo "$description" | sed -n 's/.*Triggers on:[[:space:]]*//p')
    elif [[ "$description" == *"Triggers on "* ]]; then
        # Handle "Triggers on X, Y, Z" without colon
        triggers=$(echo "$description" | sed -n 's/.*Triggers on[[:space:]]*//p')
    elif [[ "$description" == *"triggers on:"* ]]; then
        triggers=$(echo "$description" | sed -n 's/.*triggers on:[[:space:]]*//p')
    elif [[ "$description" == *"Auto-activates"* ]]; then
        triggers=$(echo "$description" | sed -n 's/.*Auto-activates[[:space:]]*//p')
    fi

    if [[ -n "$triggers" ]]; then
        # Count trigger keywords (comma separated)
        local count
        count=$(echo "$triggers" | tr ',' '\n' | wc -l | tr -d ' ')

        if [[ $count -lt 3 ]]; then
            warn "$dirname" "only $count trigger keywords (recommend 5+)"
        else
            pass "$dirname: $count trigger keywords"
        fi
    fi
}

# Validate required CLI tools are documented
validate_compatibility() {
    local skill_dir="$1"
    local skill_file="$skill_dir/SKILL.md"
    local dirname
    dirname=$(basename "$skill_dir")

    local compat
    compat=$(get_frontmatter "$skill_file" "compatibility")

    local content
    content=$(cat "$skill_file")

    # Check if skill references CLI tools
    local needs_tools=false

    if [[ "$content" == *"brew install"* || "$content" == *"npm install"* ]]; then
        needs_tools=true
    fi

    if [[ "$needs_tools" == true && -z "$compat" ]]; then
        warn "$dirname" "references CLI tools but no compatibility field"
    fi
}

# Validate allowed-tools field
validate_allowed_tools() {
    local skill_dir="$1"
    local skill_file="$skill_dir/SKILL.md"
    local dirname
    dirname=$(basename "$skill_dir")

    local tools
    tools=$(get_frontmatter "$skill_file" "allowed-tools")

    if [[ -z "$tools" ]]; then
        warn "$dirname" "no allowed-tools field"
    fi
}

# Main validation
validate_skill() {
    local skill_dir="$1"
    local skill_file="$skill_dir/SKILL.md"

    if [[ ! -f "$skill_file" ]]; then
        fail "$(basename "$skill_dir")" "SKILL.md not found"
        return
    fi

    local name description
    name=$(get_frontmatter "$skill_file" "name")
    description=$(get_frontmatter "$skill_file" "description")

    validate_name "$skill_dir" "$name" || true
    validate_description "$skill_dir" "$description" || true
    validate_triggers "$skill_dir" "$description"
    validate_compatibility "$skill_dir"
    validate_allowed_tools "$skill_dir"
}

# === Main ===

main() {
    echo "=== Skill Trigger Validation ==="
    echo ""

    local skill_count=0

    for skill_dir in "$SKILLS_DIR"/*/; do
        if [[ -d "$skill_dir" ]]; then
            ((skill_count++))
            echo -e "${BLUE}--- $(basename "$skill_dir") ---${NC}"
            validate_skill "$skill_dir"
            echo ""
        fi
    done

    echo "=== Summary ==="
    echo "Skills validated: $skill_count"
    echo -e "Passed: ${GREEN}$PASSED${NC}"
    echo -e "Failed: ${RED}$FAILED${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"

    [[ $FAILED -eq 0 ]]
}

main "$@"
