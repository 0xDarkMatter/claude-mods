# Skill Template

> Official specification: https://agentskills.io/specification

## Frontmatter Reference

```yaml
---
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ REQUIRED FIELDS                                                              │
# └─────────────────────────────────────────────────────────────────────────────┘

name: my-skill-name
# - 1-64 characters
# - Lowercase letters, numbers, and hyphens only
# - Must NOT start or end with a hyphen
# - Examples: "code-review", "git-workflow", "api-client"

description: "Clear description of what this skill does and when Claude should use it."
# - Max 1024 characters
# - Must be non-empty
# - Should answer: What does it do? When should it activate?
# - Include trigger phrases for discoverability

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ OPTIONAL FIELDS                                                              │
# └─────────────────────────────────────────────────────────────────────────────┘

license: MIT
# - Licensing terms for the skill
# - Keep brief (e.g., "MIT", "Apache-2.0", "Proprietary")

compatibility: "Requires Node.js 18+, macOS/Linux only"
# - Max 500 characters
# - Only include if skill has specific environment requirements
# - Omit if skill works everywhere

metadata:
  author: "Your Name"
  version: "1.0.0"
  tags: ["git", "workflow", "automation"]
# - Key-value mapping for custom properties
# - Not defined by spec - use for your own tracking

allowed-tools: "Bash Read Write Glob Grep"
# - Space-delimited list of pre-approved tools
# - EXPERIMENTAL: May change in future spec versions
# - Use when skill requires specific tool access
---
```

## Progressive Disclosure

Skills load content in stages to minimize context consumption:

| Level | Content | When Loaded | Token Budget |
|-------|---------|-------------|--------------|
| **Metadata** | `name` + `description` | Startup (all skills) | ~100 tokens |
| **Instructions** | SKILL.md body | Skill activated | <5000 tokens |
| **Resources** | references/, scripts/, assets/ | On-demand | As needed |

### When to Split Content

| SKILL.md Size | Action |
|---------------|--------|
| < 150 lines | Keep as single file |
| 150-300 lines | Consider extracting reference tables |
| 300+ lines | **Must split** - extract to references/ |

## Directory Structure

### Simple Skill (<150 lines)

```
my-skill/
└── SKILL.md
```

### Medium Skill (150-300 lines)

```
my-skill/
├── SKILL.md
└── references/
    └── REFERENCE.md         # Extended patterns
```

### Complex Skill (300+ lines)

```
my-skill/
├── SKILL.md                    # Core only (<300 lines)
├── references/
│   ├── REFERENCE.md            # Primary reference
│   ├── {lang}-patterns.md      # Language-specific
│   └── {domain}-examples.md    # Domain-specific
├── scripts/                    # Optional
│   └── helper.{sh,py,js}
└── assets/                     # Optional
    └── template.{json,yaml}
```

## Content Migration Rules

### What Stays in SKILL.md

- Frontmatter (name, description, compatibility, allowed-tools)
- Purpose/Overview (1-3 sentences)
- Activation triggers (when to use)
- **Top 10 most-common patterns** (essential use cases)
- Quick reference table
- "Additional Resources" section linking to references/

### What Moves to references/

| Content Type | Destination |
|--------------|-------------|
| Complete pattern lookup tables | `references/REFERENCE.md` |
| Language-specific patterns | `references/{lang}-patterns.md` |
| Framework-specific patterns | `references/{framework}-patterns.md` |
| Domain-specific examples | `references/{domain}-examples.md` |
| Edge cases and gotchas | `references/REFERENCE.md` |

### What Goes in scripts/

| Content Type | Destination |
|--------------|-------------|
| Reusable shell scripts | `scripts/{name}.sh` |
| Python helper utilities | `scripts/{name}.py` |
| Node.js helpers | `scripts/{name}.js` |

### What Goes in assets/

| Content Type | Destination |
|--------------|-------------|
| JSON/YAML templates | `assets/{name}.template.{ext}` |
| Schema definitions | `assets/{name}.schema.json` |
| Example configs | `assets/example-{name}.{ext}` |

## File Naming Conventions

| Location | Convention | Example |
|----------|------------|---------|
| references/ primary | `REFERENCE.md` | `references/REFERENCE.md` |
| references/ language | `{lang}-patterns.md` | `references/python-patterns.md` |
| references/ domain | `{domain}-examples.md` | `references/k8s-examples.md` |
| scripts/ | `{action}.{ext}` | `scripts/validate.sh` |
| assets/ templates | `{name}.template.{ext}` | `assets/server.template.py` |
| assets/ schemas | `{name}.schema.json` | `assets/tool.schema.json` |

## Reference Loading Pattern

Add this section to SKILL.md files with supporting references:

```markdown
## Additional Resources

For detailed patterns, load:

- `./references/REFERENCE.md` - Complete pattern library
- `./references/{domain}-patterns.md` - Domain-specific examples
```

## Minimum Compliant Skill

```markdown
---
name: example-skill
description: "Brief description of skill purpose and activation triggers."
---

# Example Skill

Instructions for Claude to follow when this skill is active.

## Usage

Step-by-step instructions with examples.

## Examples

- Example input → expected output
- Another example scenario
```

## Recommended Structure

```markdown
---
name: my-skill
description: "What it does. Triggers on: keyword1, keyword2, action phrases."
compatibility: "Requires tool-x. Install: brew install tool-x"
allowed-tools: "Bash Read"
---

# Skill Name

Brief purpose statement.

## Essentials

Top 10 most-common patterns (inline).

## Quick Reference

| Task | Command |
|------|---------|
| Common task 1 | `command` |
| Common task 2 | `command` |

## When to Use

- Use case 1
- Use case 2

## Additional Resources

For complete patterns, load:
- `./references/REFERENCE.md` - Extended patterns
```

## Validation Checklist

- [ ] `name` is 1-64 chars, lowercase + numbers + hyphens only
- [ ] `name` does not start or end with hyphen
- [ ] `description` is non-empty and under 1024 chars
- [ ] `description` explains what AND when
- [ ] SKILL.md under 300 lines (target for progressive disclosure)
- [ ] Top 10 essential patterns inline, rest in references/
- [ ] All file references use relative paths (`./references/`)
- [ ] No nested directories (one level deep only)
- [ ] Works without loading references (basic cases)
- [ ] Optional fields only included if needed

## Backwards Compatibility

Skills must remain functional even if supporting files are missing:

1. **SKILL.md is self-contained for basic use cases**
2. **Top 10 patterns stay inline** (no reference file required)
3. **Quick reference table always in SKILL.md**
4. **References are additive, not required**
5. **Graceful degradation** if reference files missing
