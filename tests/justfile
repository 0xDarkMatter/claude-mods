# claude-mods justfile
# Run tasks with: just <task>

# Default: list available tasks
default:
    @just --list

# Run all validation tests
test:
    @echo "Running claude-mods validation..."
    @bash tests/validate.sh

# Validate YAML frontmatter only
validate-yaml:
    @bash tests/validate.sh --yaml-only

# Check file naming conventions
validate-names:
    @bash tests/validate.sh --names-only

# Windows test runner
test-win:
    powershell -ExecutionPolicy Bypass -File tests/validate.ps1

# Count extensions
stats:
    @echo "Agents:   $(find agents -name '*.md' | wc -l)"
    @echo "Commands: $(find commands -name '*.md' | wc -l)"
    @echo "Skills:   $(find skills -name 'SKILL.md' | wc -l)"
    @echo "Rules:    $(find templates/rules -name '*.md' 2>/dev/null | wc -l)"

# List all agents
list-agents:
    @ls -1 agents/*.md | xargs -n1 basename | sed 's/\.md$//'

# List all commands
list-commands:
    @find commands -name '*.md' -not -path '*/\.*' | xargs -n1 basename | sed 's/\.md$//' | sort -u

# List all skills
list-skills:
    @ls -1 skills/*/SKILL.md | xargs -n1 dirname | xargs -n1 basename

# List all rules
list-rules:
    @find templates/rules -name '*.md' 2>/dev/null | xargs -n1 basename | sed 's/\.md$//' || echo "(none)"

# Validate settings template
validate-settings:
    @echo "Validating settings template..."
    @jq empty templates/settings.local.json && echo "Valid JSON" || echo "Invalid JSON"
