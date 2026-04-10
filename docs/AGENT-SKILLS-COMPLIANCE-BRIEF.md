# Agent Skills Spec Compliance Brief

> Bring all 66 skills in claude-mods into compliance with the Agent Skills specification at https://agentskills.io/specification

## Background

The Agent Skills format (originally by Anthropic, now an open standard backed by Vercel, Google, Microsoft, and 40+ agent platforms) has a formal spec. Our skills are ~80% compliant but have non-standard top-level frontmatter fields that need to move into the `metadata:` block.

The spec allows exactly these top-level frontmatter fields:
- `name` (required) - lowercase, hyphens, 1-64 chars, must match directory name
- `description` (required) - 1-1024 chars
- `license` (optional)
- `compatibility` (optional) - 1-500 chars
- `allowed-tools` (optional, experimental) - space-delimited
- `metadata` (optional) - arbitrary key-value map

Everything else is non-standard and should move into `metadata:`.

## Changes Required Per Skill

For each of the 66 SKILL.md files:

1. **Move `related-skills`** into `metadata.related-skills` (comma-separated string)
2. **Move `depends-on`** into `metadata.depends-on` (comma-separated string)
3. **Move `version`** into `metadata.version` (if present)
4. **Move `category`** into `metadata.category` (if present)
5. **Move `requires`** into `metadata.requires-bins` / `metadata.requires-skills`
6. **Move `cli-help`** into `metadata.cli-help`
7. **Add `license: MIT`** if missing
8. **Add `metadata.author: claude-mods`** if no metadata block exists
9. **Ensure `compatibility`** stays top-level (it's spec-compliant already)
10. **Ensure `allowed-tools`** stays top-level (spec-compliant)

## Example Transform

### Before
```yaml
---
name: pigeon
description: "Inter-session pmail..."
allowed-tools: "Read Bash Grep"
related-skills: [sqlite-ops]
---
```

### After
```yaml
---
name: pigeon
description: "Inter-session pmail..."
license: MIT
allowed-tools: "Read Bash Grep"
metadata:
  author: claude-mods
  related-skills: "sqlite-ops"
---
```

## Directory Structure Convention

The spec recommends these optional dirs alongside SKILL.md:
- `scripts/` - executable code
- `references/` - documentation loaded on demand
- `assets/` - templates, resources

Create `scripts/` and `assets/` with `.gitkeep` where missing. Most skills already have `references/`.

## Do NOT Change

- Markdown body content after frontmatter
- File paths, directory names
- Content in references/, scripts/, assets/

## Validation

After changes, frontmatter should pass: `npx skills-ref validate ./skills/<name>`

Or manual check: only `name`, `description`, `license`, `compatibility`, `allowed-tools`, and `metadata` at the top level.

## Execution

```bash
# From claude-mods root
claude -p "Update all 66 SKILL.md files in /Users/mack/projects/claude-mods/skills/ to comply with Agent Skills spec. [paste this brief as context]" --dangerously-skip-permissions
```

## Reference

- Spec: https://agentskills.io/specification
- CLI: https://github.com/vercel-labs/skills (npx skills)
- Directory: https://skills.sh
- private-project core skills (already updated): /Users/mack/projects/private-project/00_forma/.claude/skills/
