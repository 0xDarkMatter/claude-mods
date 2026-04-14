---
name: auto-skill
description: "Evaluate current session for skill-worthy workflows and create reusable skills. Triggers on: auto-skill, create skill from session, save workflow, capture this as a skill."
license: MIT
allowed-tools: "Read Glob Grep Bash Write Edit"
metadata:
  author: claude-mods
  depends-on: "skill-creator"
  related-skills: "skill-creator, introspect"
---

# Auto-Skill

Evaluate the current session and create a reusable skill from complex workflows. Enforces the [Agent Skills specification](https://agentskills.io/specification) and quality gates.

## When This Triggers

- User runs `/auto-skill`
- Stop hook suggests it after a complex session (8+ mutating ops across 4+ tool types)
- User says "save this as a skill", "capture this workflow", etc.

## Command Router

Parse arguments after `auto-skill` (or `/auto-skill`):

| User says | Action |
|-----------|--------|
| `auto-skill` (no args) | Run the full evaluation procedure below |
| `auto-skill off` | Disable globally: `touch ~/.claude/auto-skill.disable` and confirm |
| `auto-skill on` | Enable globally: `rm -f ~/.claude/auto-skill.disable` and confirm |
| `auto-skill off --project` | Disable for this project: `mkdir -p .claude && touch .claude/auto-skill.disable` |
| `auto-skill on --project` | Enable for this project: `rm -f .claude/auto-skill.disable` |
| `auto-skill status` | Show current state (see Status section below) |

### Status

When the user runs `auto-skill status`, check and report:

```bash
# Global toggle
[ -f "$HOME/.claude/auto-skill.disable" ] && echo "Global: OFF" || echo "Global: ON"

# Project toggle
[ -f ".claude/auto-skill.disable" ] && echo "Project: OFF" || echo "Project: ON"

# Hook scripts installed?
[ -x "$HOME/.claude/auto-skill/track-tools.sh" ] && echo "Hooks: installed" || echo "Hooks: not installed"

# Active session tracking?
ls /tmp/claude_autoskill_* 2>/dev/null | head -1 && echo "Tracking: active" || echo "Tracking: idle"
```

Report results in a brief table.

## Procedure

### Step 1: Evaluate the Session

Review the conversation history in the current session. Ask yourself:

1. **Was this a multi-step workflow?** (3+ distinct actions, not just read/search)
2. **Is it reusable?** Would someone do this again - in this project or another?
3. **Is it novel?** Does an existing skill already cover this? Check with:
   ```bash
   ls ~/.claude/skills/ 2>/dev/null; ls .claude/skills/ 2>/dev/null
   ```
4. **Is it teachable?** Can it be described as a clear procedure with steps?

If ANY answer is no, tell the user: "This session doesn't look like a good skill candidate" and explain which criterion failed. **Stop here.**

### Step 2: Duplicate Detection

Before creating, check for overlapping skills:

```bash
# List existing skill names and descriptions
for f in ~/.claude/skills/*/SKILL.md .claude/skills/*/SKILL.md 2>/dev/null; do
  [ -f "$f" ] || continue
  name=$(head -10 "$f" | grep '^name:' | sed 's/name: *//')
  desc=$(head -10 "$f" | grep '^description:' | sed 's/description: *//' | tr -d '"')
  echo "$name: $desc"
done
```

**Block if:**
- Exact name match exists
- 60%+ word overlap in proposed name vs existing name
- 50%+ word overlap in proposed description vs existing description

If overlap detected, suggest extending the existing skill instead.

### Step 3: Draft the Skill

Propose a skill to the user with:

| Field | Value |
|-------|-------|
| **Name** | kebab-case, descriptive, matches what it does |
| **Description** | 1-2 sentences with trigger keywords |
| **Procedure** | Numbered steps extracted from the session workflow |
| **Tools needed** | Which tools the skill requires |

Ask the user to confirm or adjust before creating.

### Step 4: Quality Gates

Before writing, validate:

| Gate | Requirement | Why |
|------|-------------|-----|
| **Name format** | `^[a-z][a-z0-9-]*$`, 1-64 chars | Agent Skills spec |
| **Description** | Non-empty, 1-1024 chars, includes trigger phrases | Spec + discovery |
| **Procedure** | Must contain numbered steps, `## Procedure`/`## Steps`, or checkboxes | Ensures actionable content |
| **Min content** | 200+ characters in body (after frontmatter) | Rejects trivial stubs |
| **License** | `license: MIT` | claude-mods convention |
| **Metadata** | `metadata.author: claude-mods` | claude-mods convention |
| **No non-standard top-level keys** | Only `name`, `description`, `license`, `compatibility`, `allowed-tools`, `metadata` | Agent Skills spec |

If any gate fails, explain which one and help the user fix it.

### Step 5: Create the Skill

Write the skill to the project's skill directory:

```
.claude/skills/<skill-name>/
  SKILL.md
  scripts/.gitkeep
  references/.gitkeep
  assets/.gitkeep
```

**SKILL.md frontmatter template** (Agent Skills spec compliant):

```yaml
---
name: <kebab-case-name>
description: "<what it does>. Triggers on: <keyword1>, <keyword2>, <keyword3>."
license: MIT
allowed-tools: "<space-delimited tool list>"
metadata:
  author: claude-mods
---
```

**Body structure:**

```markdown
# <Skill Title>

<1-2 sentence overview>

## When to Use

- <trigger condition 1>
- <trigger condition 2>

## Procedure

1. <Step one>
2. <Step two>
3. <Step three>
...

## Notes

<Edge cases, caveats, or tips>
```

### Step 6: Verify

After creating, verify the skill:

1. Check the file was written correctly:
   ```bash
   head -20 .claude/skills/<name>/SKILL.md
   ```
2. Validate frontmatter has only spec-compliant top-level keys
3. Confirm the procedure section exists and has steps
4. Tell the user the skill is ready and how to invoke it

## Per-Project Disable

```bash
touch .claude/auto-skill.disable    # Disable Stop hook suggestions
rm .claude/auto-skill.disable       # Re-enable
```

The skill itself can always be invoked manually regardless of this setting.

## Hook Setup

Auto-skill uses two hooks for automatic suggestions. These are installed globally:

```
~/.claude/auto-skill/
  track-tools.sh     # PostToolUse: counts tool calls per session
  evaluate.sh        # Stop: suggests skill creation if complex enough
```

Both hooks fail silently - they will never produce error output or block Claude.

### Hook Configuration

Add to `~/.claude/settings.json` (merge with existing hooks):

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "bash \"$HOME/.claude/auto-skill/track-tools.sh\"",
        "timeout": 2
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$HOME/.claude/auto-skill/evaluate.sh\"",
        "timeout": 5
      }]
    }]
  }
}
```

## Suggestion Gates

The Stop hook only suggests skill creation when ALL of these pass:

| Gate | Threshold | Rationale |
|------|-----------|-----------|
| **Mutating ops** | 8+ | High bar reduces noise from routine edits |
| **Tool diversity** | 4+ distinct types | Write+Edit+Bash+Agent = workflow; Write*20 = repetitive |
| **No skill loaded** | `Skill` tool absent | If following a skill, work isn't novel |
| **Per-session** | Once per session | Never nags on resume/continue |
| **Not disabled** | No `.disable` file | Global or per-project toggle |

Read-only tools (Read, Glob, Grep, LS, Task*) are excluded from counts.

## Design Decisions

- **Stop hook, not in-loop**: Claude Code doesn't expose the agent loop. The Stop hook fires while context is still in memory, which is the best we can get.
- **systemMessage output**: The Stop hook outputs JSON that Claude Code displays to the user. Non-blocking, dismissible.
- **Diversity over volume**: Tool type count matters more than raw call count. A 20-file rename isn't a skill; a workflow using Write+Edit+Bash+Agent probably is.
- **Per-session cooldown**: Uses a temp file keyed by session ID. No harsh time-based cooldown - each new session gets a fresh chance.
- **500-line cap on tracking**: Prevents runaway sessions from filling /tmp.
- **Silent failures**: Both hooks wrap everything in `2>/dev/null` and always `exit 0`.
