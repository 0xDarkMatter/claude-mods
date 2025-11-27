#!/bin/bash

# claude-mods installer for Linux/macOS
# Creates symlinks to Claude Code directories

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "Installing claude-mods..."
echo "Source: $SCRIPT_DIR"
echo "Target: $CLAUDE_DIR"
echo ""

# Create Claude directories if they don't exist
mkdir -p "$CLAUDE_DIR/commands"
mkdir -p "$CLAUDE_DIR/skills"
mkdir -p "$CLAUDE_DIR/agents"

# Install commands
echo "Installing commands..."
for cmd_dir in "$SCRIPT_DIR/commands"/*/; do
    if [ -d "$cmd_dir" ]; then
        cmd_name=$(basename "$cmd_dir")
        # Look for the main .md file
        if [ -f "$cmd_dir/$cmd_name.md" ]; then
            target="$CLAUDE_DIR/commands/$cmd_name.md"
            if [ -L "$target" ] || [ -f "$target" ]; then
                echo "  Updating: $cmd_name.md"
                rm -f "$target"
            else
                echo "  Installing: $cmd_name.md"
            fi
            ln -s "$cmd_dir/$cmd_name.md" "$target"
        fi
    fi
done

# Install skills
echo "Installing skills..."
for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    if [ -d "$skill_dir" ]; then
        skill_name=$(basename "$skill_dir")
        target="$CLAUDE_DIR/skills/$skill_name"
        if [ -L "$target" ] || [ -d "$target" ]; then
            echo "  Updating: $skill_name"
            rm -rf "$target"
        else
            echo "  Installing: $skill_name"
        fi
        ln -s "$skill_dir" "$target"
    fi
done

# Install agents
echo "Installing agents..."
for agent_file in "$SCRIPT_DIR/agents"/*.md; do
    if [ -f "$agent_file" ]; then
        agent_name=$(basename "$agent_file")
        target="$CLAUDE_DIR/agents/$agent_name"
        if [ -L "$target" ] || [ -f "$target" ]; then
            echo "  Updating: $agent_name"
            rm -f "$target"
        else
            echo "  Installing: $agent_name"
        fi
        ln -s "$agent_file" "$target"
    fi
done

echo ""
echo "Installation complete!"
echo ""
echo "Installed to:"
echo "  Commands: $CLAUDE_DIR/commands/"
echo "  Skills:   $CLAUDE_DIR/skills/"
echo "  Agents:   $CLAUDE_DIR/agents/"
