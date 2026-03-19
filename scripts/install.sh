#!/usr/bin/env bash
#
# claude-mods Installer (Linux/macOS)
# Copies commands, skills, agents, and rules to ~/.claude/
# Handles cleanup of deprecated items and command-to-skill migrations.
#
# Usage: ./scripts/install.sh

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           claude-mods Installer (Unix)                       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLAUDE_DIR="$HOME/.claude"

# Ensure ~/.claude directories exist
for dir in commands skills agents rules output-styles; do
    mkdir -p "$CLAUDE_DIR/$dir"
done

# =============================================================================
# DEPRECATED ITEMS - Remove these from user's config
# =============================================================================
echo -e "${YELLOW}Cleaning up deprecated items...${NC}"

deprecated_items=(
    # Removed commands (migrated to skills or deleted)
    "$CLAUDE_DIR/commands/review.md"      # Migrated to skill
    "$CLAUDE_DIR/commands/testgen.md"     # Migrated to skill
    "$CLAUDE_DIR/commands/conclave.md"    # Deprecated
    "$CLAUDE_DIR/commands/pulse.md"       # Now a skill only

    # Removed skills
    "$CLAUDE_DIR/skills/conclave"                # Deprecated
    "$CLAUDE_DIR/skills/claude-code-templates"   # Replaced by skill-creator
)

# Renamed skills: -patterns -> -ops (March 2026)
renamed_skills=(
    cli-patterns
    mcp-patterns
    python-async-patterns
    python-cli-patterns
    python-database-patterns
    python-fastapi-patterns
    python-observability-patterns
    python-pytest-patterns
    python-typing-patterns
    rest-patterns
    security-patterns
    sql-patterns
    tailwind-patterns
    testing-patterns
)

for old_skill in "${renamed_skills[@]}"; do
    old_path="$CLAUDE_DIR/skills/$old_skill"
    if [ -d "$old_path" ]; then
        rm -rf "$old_path"
        echo -e "  ${RED}Removed renamed: $old_skill (now ${old_skill%-patterns}-ops)${NC}"
    fi
done

for item in "${deprecated_items[@]}"; do
    if [ -e "$item" ]; then
        rm -rf "$item"
        echo -e "  ${RED}Removed: $item${NC}"
    fi
done
echo ""

# =============================================================================
# COMMANDS - Only copy commands that haven't been migrated to skills
# =============================================================================
echo -e "${BLUE}Installing commands...${NC}"

# Commands that should NOT be copied (migrated to skills)
skip_commands=("review.md" "testgen.md")

for file in "$PROJECT_ROOT/commands"/*.md; do
    [ -f "$file" ] || continue
    filename=$(basename "$file")

    # Skip migrated commands
    skip=false
    for skip_cmd in "${skip_commands[@]}"; do
        if [ "$filename" = "$skip_cmd" ]; then
            skip=true
            break
        fi
    done

    # Skip archive directory contents
    [[ "$file" == *"/archive/"* ]] && continue

    if [ "$skip" = false ]; then
        cp "$file" "$CLAUDE_DIR/commands/"
        echo -e "  ${GREEN}$filename${NC}"
    fi
done
echo ""

# =============================================================================
# SKILLS - Copy all skill directories
# =============================================================================
echo -e "${BLUE}Installing skills...${NC}"

for skill_dir in "$PROJECT_ROOT/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")

    # Remove existing and copy fresh
    rm -rf "$CLAUDE_DIR/skills/$skill_name"
    cp -r "$skill_dir" "$CLAUDE_DIR/skills/"
    echo -e "  ${GREEN}$skill_name/${NC}"
done
echo ""

# =============================================================================
# AGENTS - Copy all agent files
# =============================================================================
echo -e "${BLUE}Installing agents...${NC}"

for file in "$PROJECT_ROOT/agents"/*.md; do
    [ -f "$file" ] || continue
    cp "$file" "$CLAUDE_DIR/agents/"
    echo -e "  ${GREEN}$(basename "$file")${NC}"
done
echo ""

# =============================================================================
# RULES - Copy all rule files
# =============================================================================
echo -e "${BLUE}Installing rules...${NC}"

for file in "$PROJECT_ROOT/rules"/*.md; do
    [ -f "$file" ] || continue
    cp "$file" "$CLAUDE_DIR/rules/"
    echo -e "  ${GREEN}$(basename "$file")${NC}"
done
echo ""

# =============================================================================
# OUTPUT STYLES - Copy all output style files
# =============================================================================
echo -e "${BLUE}Installing output styles...${NC}"

if [ -d "$PROJECT_ROOT/output-styles" ]; then
    for file in "$PROJECT_ROOT/output-styles"/*.md; do
        [ -f "$file" ] || continue
        cp "$file" "$CLAUDE_DIR/output-styles/"
        echo -e "  ${GREEN}$(basename "$file")${NC}"
    done
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Installation complete!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Restart Claude Code to load the new extensions.${NC}"
echo ""
