#!/usr/bin/env bash
# claude-mods validation script
# Validates YAML frontmatter, required fields, and naming conventions

set -Eeuo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASS=0
FAIL=0
WARN=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse arguments
YAML_ONLY=false
NAMES_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --yaml-only)
            YAML_ONLY=true
            shift
            ;;
        --names-only)
            NAMES_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Helper functions
log_pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    PASS=$((PASS + 1))
}

log_fail() {
    echo -e "${RED}FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
}

log_warn() {
    echo -e "${YELLOW}WARN${NC}: $1"
    WARN=$((WARN + 1))
}

# Check if file has valid YAML frontmatter
check_yaml_frontmatter() {
    local file="$1"
    local content
    content=$(cat "$file")

    # Check for opening ---
    if [[ "$content" != ---* ]]; then
        log_fail "$file - Missing YAML frontmatter (no opening ---)"
        return 1
    fi

    # Check for closing ---
    local frontmatter
    frontmatter=$(echo "$content" | sed -n '1,/^---$/p' | tail -n +2)
    if [[ -z "$frontmatter" ]]; then
        log_fail "$file - Invalid YAML frontmatter (no closing ---)"
        return 1
    fi

    return 0
}

# Extract field from YAML frontmatter
get_yaml_field() {
    local file="$1"
    local field="$2"

    # Extract frontmatter and get field value
    sed -n '2,/^---$/p' "$file" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^["'"'"']//' | sed 's/["'"'"']$//'
}

# Check required fields in agents/commands
check_required_fields() {
    local file="$1"
    local type="$2"

    local name
    local description

    name=$(get_yaml_field "$file" "name")
    description=$(get_yaml_field "$file" "description")

    # Agents require both name and description
    if [[ "$type" == "agent" ]]; then
        if [[ -z "$name" ]]; then
            log_fail "$file - Missing required field: name"
            return 1
        fi
        if [[ -z "$description" ]]; then
            log_fail "$file - Missing required field: description"
            return 1
        fi
    fi

    # Commands only require description
    if [[ "$type" == "command" ]]; then
        if [[ -z "$description" ]]; then
            log_fail "$file - Missing required field: description"
            return 1
        fi
    fi

    return 0
}

# Check naming convention (kebab-case)
check_naming() {
    local file="$1"
    local basename
    basename=$(basename "$file" .md)

    # Check if filename is kebab-case
    if [[ ! "$basename" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
        log_warn "$file - Filename not kebab-case: $basename"
        return 1
    fi

    # Check if name field matches filename (for agents)
    local name
    name=$(get_yaml_field "$file" "name")
    if [[ -n "$name" && "$name" != "$basename" ]]; then
        log_warn "$file - Name field '$name' doesn't match filename '$basename'"
        return 1
    fi

    return 0
}

# Validate agents
validate_agents() {
    echo ""
    echo "=== Validating Agents ==="

    local agent_dir="$PROJECT_DIR/agents"
    if [[ ! -d "$agent_dir" ]]; then
        log_warn "agents/ directory not found"
        return
    fi

    # Use find for better Windows compatibility
    while IFS= read -r -d '' file; do
        if ! $NAMES_ONLY; then
            if check_yaml_frontmatter "$file"; then
                if check_required_fields "$file" "agent"; then
                    log_pass "$file - Valid agent"
                fi
            fi
        fi

        if ! $YAML_ONLY; then
            check_naming "$file" || true
        fi
    done < <(find "$agent_dir" -maxdepth 1 -name "*.md" -type f -print0)
}

# Validate commands
validate_commands() {
    echo ""
    echo "=== Validating Commands ==="

    local cmd_dir="$PROJECT_DIR/commands"
    if [[ ! -d "$cmd_dir" ]]; then
        log_warn "commands/ directory not found"
        return
    fi

    # Check .md files directly in commands/
    while IFS= read -r -d '' file; do
        if ! $NAMES_ONLY; then
            if check_yaml_frontmatter "$file"; then
                if check_required_fields "$file" "command"; then
                    log_pass "$file - Valid command"
                fi
            fi
        fi

        if ! $YAML_ONLY; then
            check_naming "$file" || true
        fi
    done < <(find "$cmd_dir" -maxdepth 1 -name "*.md" -type f -print0)

    # Check subdirectories (like g-slave/, session-manager/)
    while IFS= read -r -d '' subdir; do
        # Look for main command file (exclude README.md, LICENSE.md)
        while IFS= read -r -d '' file; do
            local basename
            basename=$(basename "$file")
            # Skip README and LICENSE files
            [[ "$basename" == "README.md" || "$basename" == "LICENSE.md" ]] && continue

            if ! $NAMES_ONLY; then
                if check_yaml_frontmatter "$file"; then
                    # Commands in subdirs may have different required fields
                    local desc
                    desc=$(get_yaml_field "$file" "description")
                    if [[ -n "$desc" ]]; then
                        log_pass "$file - Valid subcommand"
                    else
                        log_warn "$file - Missing description"
                    fi
                fi
            fi
        done < <(find "$subdir" -maxdepth 1 -name "*.md" -type f -print0)
    done < <(find "$cmd_dir" -mindepth 1 -maxdepth 1 -type d -print0)
}

# Validate skills
validate_skills() {
    echo ""
    echo "=== Validating Skills ==="

    local skills_dir="$PROJECT_DIR/skills"
    if [[ ! -d "$skills_dir" ]]; then
        log_warn "skills/ directory not found"
        return
    fi

    while IFS= read -r -d '' skill_subdir; do
        local skill_file="$skill_subdir/SKILL.md"
        if [[ ! -f "$skill_file" ]]; then
            log_fail "$skill_subdir - Missing SKILL.md"
            continue
        fi

        if ! $NAMES_ONLY; then
            if check_yaml_frontmatter "$skill_file"; then
                local name
                local desc
                name=$(get_yaml_field "$skill_file" "name")
                desc=$(get_yaml_field "$skill_file" "description")

                if [[ -n "$name" && -n "$desc" ]]; then
                    log_pass "$skill_file - Valid skill"
                else
                    [[ -z "$name" ]] && log_fail "$skill_file - Missing name"
                    [[ -z "$desc" ]] && log_fail "$skill_file - Missing description"
                fi
            fi
        fi
    done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0)
}

# Validate rules (optional YAML frontmatter with optional paths field)
validate_rules() {
    echo ""
    echo "=== Validating Rules ==="

    local rules_dir="$PROJECT_DIR/templates/rules"
    if [[ ! -d "$rules_dir" ]]; then
        echo "  (no templates/rules/ directory - skipping)"
        return
    fi

    while IFS= read -r -d '' file; do
        local basename
        basename=$(basename "$file")

        # Rules should be .md files
        if [[ "$file" != *.md ]]; then
            log_warn "$file - Rule file should be .md"
            continue
        fi

        # Check if file has content
        if [[ ! -s "$file" ]]; then
            log_fail "$file - Empty rule file"
            continue
        fi

        # Check for valid YAML frontmatter if present
        local content
        content=$(cat "$file")
        if [[ "$content" == ---* ]]; then
            # Has frontmatter - validate it
            local closing
            closing=$(echo "$content" | sed -n '2,${/^---$/=;}'| head -1)
            if [[ -z "$closing" ]]; then
                log_fail "$file - Invalid YAML frontmatter (no closing ---)"
                continue
            fi

            # If paths field exists, validate it's not empty
            local paths
            paths=$(get_yaml_field "$file" "paths")
            if grep -q "^paths:" "$file" && [[ -z "$paths" ]]; then
                log_warn "$file - paths field is empty"
            fi
        fi

        # Check naming convention (kebab-case)
        local name
        name=$(basename "$file" .md)
        if [[ ! "$name" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
            log_warn "$file - Filename not kebab-case: $name"
        fi

        log_pass "$file - Valid rule"
    done < <(find "$rules_dir" -name "*.md" -type f -print0)
}

# Validate settings files (permissions and hooks)
validate_settings() {
    echo ""
    echo "=== Validating Settings ==="

    local settings_file="$PROJECT_DIR/templates/settings.local.json"
    if [[ ! -f "$settings_file" ]]; then
        echo "  (no templates/settings.local.json - skipping)"
        return
    fi

    # Check if valid JSON
    if ! jq empty "$settings_file" 2>/dev/null; then
        log_fail "$settings_file - Invalid JSON"
        return
    fi

    # Check for permissions structure
    if ! jq -e '.permissions' "$settings_file" >/dev/null 2>&1; then
        log_fail "$settings_file - Missing 'permissions' key"
    else
        # Check permissions has allow array
        if ! jq -e '.permissions.allow | type == "array"' "$settings_file" >/dev/null 2>&1; then
            log_fail "$settings_file - permissions.allow should be an array"
        else
            log_pass "$settings_file - Valid permissions structure"
        fi
    fi

    # Check for hooks structure (optional but if present should be object)
    if jq -e '.hooks' "$settings_file" >/dev/null 2>&1; then
        if ! jq -e '.hooks | type == "object"' "$settings_file" >/dev/null 2>&1; then
            log_fail "$settings_file - hooks should be an object"
        else
            # Validate hook event names if any hooks defined
            local hook_events
            hook_events=$(jq -r '.hooks | keys[]' "$settings_file" 2>/dev/null || true)
            local valid_events="PreToolUse PostToolUse PermissionRequest Notification UserPromptSubmit Stop SubagentStop PreCompact SessionStart SessionEnd"

            for event in $hook_events; do
                if [[ ! " $valid_events " =~ " $event " ]]; then
                    log_warn "$settings_file - Unknown hook event: $event"
                fi
            done

            if [[ -n "$hook_events" ]]; then
                log_pass "$settings_file - Valid hooks structure"
            else
                log_pass "$settings_file - Hooks defined (empty)"
            fi
        fi
    fi
}

# Main
main() {
    echo "claude-mods Validation"
    echo "======================"
    echo "Project: $PROJECT_DIR"

    validate_agents
    validate_commands
    validate_skills
    validate_rules
    validate_settings

    echo ""
    echo "======================"
    echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$WARN warnings${NC}"

    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
