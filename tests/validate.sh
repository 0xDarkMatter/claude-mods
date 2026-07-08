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
        # Skip shared helper dirs (e.g. _lib) - not skills, no SKILL.md expected.
        [[ "$(basename "$skill_subdir")" == _* ]] && continue

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

# Validate the session-wide cost of skill descriptions
validate_description_budget() {
    echo ""
    echo "=== Validating Skill Description Budget ==="

    # Ship in warn mode while the 18 known offenders are trimmed; flipping to fail is a one-word change.
    # The cap combines description + when_to_use because Claude Code loads both, so moving text between
    # fields does not reduce the per-session cost.
    DESC_BUDGET_MODE="warn" # warn|fail

    local skills_dir="$PROJECT_DIR/skills"
    local hard_cap=700
    local soft_budget=35000
    local catalog_total=0
    local name
    local combined_len
    local budget_rows

    if [[ ! -d "$skills_dir" ]]; then
        log_warn "skills/ directory not found"
        return
    fi

    local python_status=1
    if command -v python3 >/dev/null 2>&1; then
        set +e
        budget_rows=$(python3 - "$skills_dir" 2>/dev/null <<'PY'
import pathlib
import sys

import yaml

skills_dir = pathlib.Path(sys.argv[1])
for skill_dir in sorted(path for path in skills_dir.iterdir() if path.is_dir() and not path.name.startswith("_")):
    skill_file = skill_dir / "SKILL.md"
    if not skill_file.is_file():
        continue
    lines = skill_file.read_text(encoding="utf-8-sig").splitlines()
    markers = [index for index, line in enumerate(lines) if line.strip() == "---"]
    if len(markers) < 2:
        continue
    frontmatter = yaml.safe_load("\n".join(lines[markers[0] + 1:markers[1]])) or {}
    description = str(frontmatter.get("description") or "")
    when_to_use = str(frontmatter.get("when_to_use") or "")
    print(f"{skill_dir.name}\t{len(description) + len(when_to_use)}")
PY
        )
        python_status=$?
        set -e
    fi

    if ((python_status != 0)); then
        local skill_subdir
        local skill_file
        local description
        local when_to_use
        budget_rows=""
        while IFS= read -r -d '' skill_subdir; do
            [[ "$(basename "$skill_subdir")" == _* ]] && continue
            skill_file="$skill_subdir/SKILL.md"
            [[ -f "$skill_file" ]] || continue
            description=$(get_yaml_field "$skill_file" "description" || true)
            when_to_use=$(get_yaml_field "$skill_file" "when_to_use" || true)
            budget_rows+="$(printf '%s\t%s' "$(basename "$skill_subdir")" "$((${#description} + ${#when_to_use}))")"$'\n'
        done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    while IFS=$'\t' read -r name combined_len; do
        [[ -z "$name" ]] && continue
        catalog_total=$((catalog_total + combined_len))

        if ((combined_len > hard_cap)); then
            if [[ "$DESC_BUDGET_MODE" == "fail" ]]; then
                log_fail "$name - description + when_to_use is $combined_len chars (hard cap: $hard_cap)"
            else
                log_warn "$name - description + when_to_use is $combined_len chars (hard cap: $hard_cap)"
            fi
        fi
    done <<< "$budget_rows"

    if ((catalog_total > soft_budget)); then
        log_warn "Skill catalog descriptions total $catalog_total chars (soft budget: $soft_budget)"
    else
        log_pass "Skill catalog descriptions total $catalog_total chars (soft budget: $soft_budget)"
    fi
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

# Validate plugin + marketplace manifests (.claude-plugin/)
#
# The authoritative validator is `claude plugin validate` (it tracks the live
# schema - it caught a bad plugin `source` shape and an `author` type error
# that a hand-rolled jq check sailed past). We prefer it when the CLI is
# present and fall back to lightweight structural jq checks otherwise. The
# stray-root-file guard runs regardless, because the official tool validates
# whatever path it is given and cannot see a misplaced copy.
validate_plugin() {
    echo ""
    echo "=== Validating Plugin Manifests ==="

    local plugin_dir="$PROJECT_DIR/.claude-plugin"
    local plugin_file="$plugin_dir/plugin.json"
    local mkt_file="$plugin_dir/marketplace.json"

    # --- location guard (official tool can't see this) ---
    # The spec mandates .claude-plugin/marketplace.json. A copy at the repo
    # root is the regression that caused /plugin marketplace add to fail (#4).
    if [[ -f "$PROJECT_DIR/marketplace.json" ]]; then
        log_fail "marketplace.json found at repo root - must live at .claude-plugin/marketplace.json"
    fi

    [[ -f "$plugin_file" ]] || log_fail ".claude-plugin/plugin.json - Missing"
    [[ -f "$mkt_file" ]] || log_fail ".claude-plugin/marketplace.json - Missing (required for /plugin marketplace add)"

    # --- authoritative path: claude plugin validate ---
    if command -v claude >/dev/null 2>&1; then
        # Marketplace manifest (repo root resolves to the marketplace).
        if claude plugin validate "$PROJECT_DIR" >/dev/null 2>&1; then
            log_pass "marketplace.json - claude plugin validate passed"
        else
            log_fail "marketplace.json - claude plugin validate failed (run: claude plugin validate .)"
        fi

        # Plugin manifest: validate in isolation so it is not shadowed by the
        # marketplace manifest in the same .claude-plugin/ directory.
        if [[ -f "$plugin_file" ]]; then
            local tmp
            tmp=$(mktemp -d)
            mkdir -p "$tmp/.claude-plugin"
            cp "$plugin_file" "$tmp/.claude-plugin/plugin.json"
            if claude plugin validate "$tmp" >/dev/null 2>&1; then
                log_pass "plugin.json - claude plugin validate passed"
            else
                log_fail "plugin.json - claude plugin validate failed (unrecognized keys or wrong field types)"
            fi
            rm -rf "$tmp"
        fi
        return
    fi

    # --- fallback path: lightweight structural checks (jq) ---
    log_warn "claude CLI not found - using lightweight manifest checks only (install Claude Code for authoritative validation)"

    if [[ -f "$plugin_file" ]]; then
        if ! jq empty "$plugin_file" 2>/dev/null; then
            log_fail "$plugin_file - Invalid JSON"
        elif jq -e '.name | strings' "$plugin_file" >/dev/null 2>&1; then
            log_pass "$plugin_file - structurally OK (name present)"
        else
            log_fail "$plugin_file - Missing required field: name"
        fi
    fi

    if [[ -f "$mkt_file" ]]; then
        if ! jq empty "$mkt_file" 2>/dev/null; then
            log_fail "$mkt_file - Invalid JSON"
        else
            jq -e '.name | strings' "$mkt_file" >/dev/null 2>&1 \
                || log_fail "$mkt_file - Missing required field: name (string)"
            jq -e '.owner.name | strings' "$mkt_file" >/dev/null 2>&1 \
                || log_fail "$mkt_file - owner.name missing (owner must be an object with a name)"
            jq -e '.plugins | arrays' "$mkt_file" >/dev/null 2>&1 \
                || log_fail "$mkt_file - Missing required field: plugins (array)"
            if jq -e '.name and (.owner.name | strings) and (.plugins | arrays)' "$mkt_file" >/dev/null 2>&1; then
                log_pass "$mkt_file - structurally OK (run claude plugin validate for full schema)"
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
    validate_description_budget
    validate_rules
    validate_settings
    validate_plugin

    echo ""
    echo "======================"
    echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$WARN warnings${NC}"

    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
