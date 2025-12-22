# Naming Conventions

Consistent naming patterns for all claude-mods components.

## General Principles

1. **kebab-case** for all file and directory names
2. **Lowercase** always (no PascalCase, camelCase, or UPPERCASE)
3. **Descriptive** but concise
4. **No abbreviations** unless universally understood (API, CLI, SQL)

## Component Patterns

### Agents (`/agents`)

```
{domain}-expert.md
```

| Pattern | Example | Notes |
|---------|---------|-------|
| Language | `python-expert.md` | Programming languages |
| Framework | `laravel-expert.md` | Frameworks |
| Tool | `docker-expert.md` | Specific tools |
| Domain | `aws-fargate-ecs-expert.md` | Compound domains |
| Specialized | `playwright-roulette-expert.md` | Project-specific |

**Frontmatter:**

```yaml
---
name: python-expert          # Match filename (without .md)
description: <one line>      # Concise capability summary
model: sonnet|opus|haiku     # Recommended model
---
```

### Skills (`/skills`)

```
{topic}-patterns/skill.md    # Pattern collections
{tool-name}/skill.md         # Tool-specific knowledge
```

| Pattern | Example | Notes |
|---------|---------|-------|
| Language patterns | `python-async-patterns/` | Domain + "patterns" |
| Tool knowledge | `sqlite-ops/` | Tool + operation |
| Workflow | `git-workflow/` | Activity-focused |
| Framework | `tailwind-patterns/` | Framework + "patterns" |

**Frontmatter:**

```yaml
---
name: python-async-patterns  # Match directory name
description: "<trigger phrases>"
compatibility: "<version requirements>"
allowed-tools: "<tool list>"
depends-on: [<skill-names>]
related-skills: [<skill-names>]
---
```

### Commands (`/commands`)

```
{action}.md
```

| Pattern | Example | Notes |
|---------|---------|-------|
| Single verb | `review.md` | Preferred |
| Compound | `testgen.md` | Concatenate, no hyphens |
| Conceptual | `atomise.md` | Abstract operations |

**Frontmatter:**

```yaml
---
description: "<one line summary with trigger phrases>"
---
```

### Rules (`/rules`)

```
{topic}.md
```

| Pattern | Example | Notes |
|---------|---------|-------|
| Tool guidance | `cli-tools.md` | Tool + purpose |
| Workflow | `commit-style.md` | Activity + aspect |
| Philosophy | `thinking.md` | Conceptual guidance |

**No frontmatter required** - plain markdown injected into context.

### Output Styles (`/output-styles`)

```
{personality}.md
```

| Pattern | Example | Notes |
|---------|---------|-------|
| Character | `vesper.md` | Named personality |
| Descriptor | `spartan.md` | Style type |
| Role | `mentor.md` | Persona type |

**Frontmatter:**

```yaml
---
keep-coding-instructions: true|false
---
```

### Hooks (`/hooks`)

```
{trigger}-{action}.sh
```

| Pattern | Example | Notes |
|---------|---------|-------|
| Pre-action | `pre-commit-lint.sh` | Before operation |
| Post-action | `post-edit-format.sh` | After operation |
| Warning | `dangerous-cmd-warn.sh` | Guardrails |

## Variable Naming

### Shell Scripts

```bash
# Constants: UPPER_SNAKE_CASE
readonly PROJECT_ROOT="/path/to/root"
readonly MAX_RETRIES=3

# Variables: lower_snake_case
local file_count=0
local current_branch=""

# Functions: lower_snake_case (verbs)
check_prerequisites() { ... }
run_tests() { ... }
```

### YAML Frontmatter

```yaml
# Keys: kebab-case
name: skill-name
depends-on: [other-skill]
allowed-tools: "Read Write"

# NOT these:
dependsOn: [bad]      # camelCase wrong
depends_on: [bad]     # snake_case wrong
```

### Markdown

- Headers: Title Case (`## Decision Frameworks`)
- Tables: Title Case headers, sentence case content
- Code blocks: Language-appropriate conventions

## Anti-patterns

```
BAD:  Python-Expert.md       - PascalCase
BAD:  python_expert.md       - snake_case
BAD:  pythonExpert.md        - camelCase
GOOD: python-expert.md       - kebab-case

BAD:  skills/PythonPatterns/ - PascalCase directory
GOOD: skills/python-patterns/

BAD:  commands/TestGen.md    - PascalCase
GOOD: commands/testgen.md    - Concatenated lowercase

BAD:  VESPER.md              - UPPERCASE
GOOD: vesper.md              - lowercase
```

## Quick Reference

| Component | Pattern | Example |
|-----------|---------|---------|
| Agent | `{domain}-expert.md` | `docker-expert.md` |
| Skill | `{topic}-patterns/skill.md` | `python-async-patterns/skill.md` |
| Command | `{action}.md` | `review.md` |
| Rule | `{topic}.md` | `commit-style.md` |
| Output Style | `{personality}.md` | `vesper.md` |
| Hook | `{trigger}-{action}.sh` | `pre-commit-lint.sh` |
