---
name: project-docs
description: "Scans for project documentation files (AGENTS.md, CLAUDE.md, GEMINI.md, COPILOT.md, CURSOR.md, WARP.md, and 15+ other formats) and synthesizes guidance. Auto-activates when user asks to review, understand, or explore a codebase, when starting work in a new project, when asking about conventions or agents, or when documentation context would help. Can consolidate multiple platform docs into unified AGENTS.md."
---

# Project Documentation Scanner

Scan for and synthesize project documentation across AI assistants, IDEs, and CLI tools.

## When to Activate

Use this skill when:
- User asks to review, understand, or explore a codebase
- User says "review this codebase", "explain this project", "what does this repo do"
- Starting work in a new or unfamiliar project
- User asks about project conventions, workflows, or recommended agents
- User asks "how do I work with this codebase" or similar
- User asks which agent to use for a task
- Before making significant architectural decisions
- User explicitly invokes `/project-docs`

## Instructions

### Step 0: Load Skill Resources (Do This First)

Before scanning the project, read the supporting files from this skill directory:

1. Read `~/.claude/skills/project-docs/reference.md` - Contains the complete list of documentation files to scan for
2. Read `~/.claude/skills/project-docs/templates.md` - Contains templates for generating AGENTS.md

These files provide the patterns and templates needed for the remaining steps.

### Step 1: Scan for Documentation Files

Use Glob to search the project root for documentation files using the patterns from `reference.md`.

Priority order:
1. **AGENTS.md** - Platform-agnostic (highest priority)
2. **CLAUDE.md** - Claude-specific workflows
3. **Other AI docs** - GEMINI.md, COPILOT.md, CHATGPT.md, CODEIUM.md
4. **IDE docs** - CURSOR.md, WINDSURF.md, VSCODE.md, JETBRAINS.md
5. **Terminal docs** - WARP.md, FIG.md, ZELLIJ.md
6. **Environment docs** - DEVCONTAINER.md, GITPOD.md, CODESPACES.md
7. **Generic docs** - AI.md, ASSISTANT.md

### Step 2: Read All Found Files

Read the complete contents of every documentation file found. Do not skip any.

### Step 3: Synthesize and Present

Combine information from all sources into a unified summary:

```
PROJECT DOCUMENTATION

Sources: [list each file found]

RECOMMENDED AGENTS
  Primary: [agents recommended for core work]
  Secondary: [agents for specific tasks]

KEY WORKFLOWS
  [consolidated workflows from all docs]

CONVENTIONS
  [code style, patterns, architecture guidelines]

QUICK COMMANDS
  [common commands extracted from docs]
```

When information conflicts between files:
- Prefer AGENTS.md (platform-agnostic)
- Then CLAUDE.md (Claude-specific)
- Note platform-specific details with annotations like "(from CURSOR.md)"

### Step 4: Offer Consolidation

If 2 or more documentation files exist, ask the user:

"I found [N] documentation files. Would you like me to consolidate them into a single AGENTS.md?

This would:
- Merge all guidance into one platform-agnostic file
- Preserve platform-specific notes with annotations
- Archive originals to `.doc-archive/`

Reply 'yes' to consolidate, or 'no' to keep separate files."

**If user agrees to consolidate, follow these steps IN ORDER:**

#### 4a: Create Archive Directory

Use Bash to create the archive directory:
```bash
mkdir -p .doc-archive
```

#### 4b: Archive Each Original File (REQUIRED)

For EACH documentation file found (except AGENTS.md if it exists), archive it BEFORE creating the new AGENTS.md:

```bash
# Get today's date for the suffix
DATE=$(date +%Y-%m-%d)

# Move each file - repeat for every doc file found
mv CLAUDE.md .doc-archive/CLAUDE.md.$DATE
mv WARP.md .doc-archive/WARP.md.$DATE
# etc. for each file
```

**Do not skip this step.** Every original file must be safely archived before proceeding.

#### 4c: Verify Archives Exist

Use Glob to confirm files were archived:
```
.doc-archive/*.md.*
```

List what was archived to the user.

#### 4d: Generate Unified AGENTS.md

Now create the new AGENTS.md using the template from `templates.md`. Include:
- Content merged from all archived files
- HTML comments marking the source: `<!-- Source: CLAUDE.md -->`
- Platform-specific notes clearly labeled

#### 4e: Confirm Completion

Report to user:
```
Consolidation complete.

Archived to .doc-archive/:
  - CLAUDE.md.2024-01-15
  - WARP.md.2024-01-15

Created: AGENTS.md (unified documentation)
```

### Step 5: No Documentation Found

If no documentation files exist:

```
No project documentation found.

Recommended: Create AGENTS.md for AI-agnostic project guidance.

I can generate a starter AGENTS.md based on:
- This project's structure and tech stack
- Common patterns I observe in the codebase

Would you like me to create one?
```

If user agrees, analyze the project and generate appropriate AGENTS.md using the template structure from `templates.md`.

## Important Notes

- Always read documentation files completely before summarizing
- Preserve original intent when synthesizing multiple sources
- Platform-specific instructions (e.g., Cursor keybindings) should be noted but marked as potentially non-applicable
- Never delete original files without archiving first
- Keep summaries concise but comprehensive
