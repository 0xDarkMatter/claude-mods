---
description: "Terminal canvas for content drafting with live preview. Start split-pane sessions for email, message, and document composition. Triggers on: canvas, draft, compose, write content."
experimental: true
---

# Canvas - Terminal Content Drafting

> ⚠️ **EXPERIMENTAL** - This feature is under active development. APIs may change. Requires Warp terminal for best experience.

Terminal canvas for interactive content drafting with Claude. Creates a split-pane experience in Warp terminal where Claude writes content and you see live markdown preview.

## Arguments

$ARGUMENTS

- `start [--type email|message|doc]`: Initialize canvas session
- `write "content"`: Write/update content in canvas
- `read`: Read current canvas content back
- `clear`: Clear canvas content
- `close`: End canvas session and clean up

## Architecture

```
/canvas <subcommand> [options]
    │
    ├─→ /canvas start [--type email|message|doc]
    │     ├─ Create .claude/canvas/ directory
    │     ├─ Initialize content.md with template
    │     ├─ Initialize meta.json with state
    │     ├─ Detect Warp terminal
    │     └─ Output setup instructions
    │
    ├─→ /canvas write "content"
    │     ├─ Write content to .claude/canvas/content.md
    │     ├─ Update meta.json timestamp
    │     └─ Canvas TUI auto-refreshes
    │
    ├─→ /canvas read
    │     ├─ Read .claude/canvas/content.md
    │     └─ Return content for Claude to process
    │
    ├─→ /canvas clear
    │     ├─ Clear content.md (keep structure)
    │     └─ Reset meta.json
    │
    └─→ /canvas close
          ├─ Optional: copy content to clipboard
          └─ Clean up .claude/canvas/
```

---

## Workflow

### Starting a Canvas Session

```
User: "Help me draft an email to my manager about the project delay"

Claude: I'll help you draft that email. Starting canvas mode...

[Executes internally:]
1. mkdir -p .claude/canvas
2. Write email template to .claude/canvas/content.md
3. Write meta.json with contentType: "email"

[Output:]
Canvas initialized with email template.

To see live preview, open Warp and:
1. Press Cmd+Shift+D (or Ctrl+Shift+D on Windows) to split pane
2. In the new pane, run: npx @claude-mods/canvas-tui --watch

Or use the launch configuration:
  warp://launch/claude-canvas
```

### Writing Content

```
[Claude writes the email draft:]

/canvas write "# Email Draft

**To:** manager@company.com
**Subject:** Project Timeline Update

---

Hi Sarah,

I wanted to give you a heads-up about a delay in the Phoenix project...

Best regards,
[Name]"

[Canvas TUI instantly shows the rendered markdown]
```

### Reading Edits

```
User: "I edited the email in the canvas, can you make it more formal?"

[Claude reads current content:]
/canvas read

[Returns content from .claude/canvas/content.md with user's edits]

[Claude can now rewrite based on user's changes]
```

---

## Execution

### /canvas start

**Step 1: Create IPC Directory**

```bash
mkdir -p .claude/canvas
```

**Step 2: Select Template**

Based on `--type` flag (default: doc):

| Type | Template |
|------|----------|
| email | Subject line, To/CC fields, greeting, body, signature |
| message | Casual format for Slack/Teams/Discord |
| doc | Structured markdown with sections |

**Step 3: Initialize Files**

Write `.claude/canvas/content.md`:
```markdown
# Email Draft

**To:**
**Subject:**

---

Hi [Name],

[Your message here]

Best regards,
[Your name]
```

Write `.claude/canvas/meta.json`:
```json
{
  "version": "1.0",
  "contentType": "email",
  "mode": "view",
  "claudeLastWrite": "2025-01-08T10:30:00Z",
  "userLastEdit": null
}
```

**Step 4: Output Instructions**

```
Canvas ready with email template.

Setup (one-time):
  npm install -g @claude-mods/canvas-tui

To view canvas:
  1. Split your terminal (Cmd+Shift+D in Warp)
  2. Run: canvas-tui --watch

I'll write your content and you'll see it update in real-time.
```

### /canvas write

**Parameters:**
- Content (required): Markdown string to write

**Execution:**

1. Ensure `.claude/canvas/` exists
2. Write content to `.claude/canvas/content.md`
3. Update `meta.json` with `claudeLastWrite` timestamp
4. Canvas TUI detects change via chokidar and re-renders

**Output:**
```
Content updated in canvas.
```

### /canvas read

**Execution:**

1. Read `.claude/canvas/content.md`
2. Return content as string

**Use Case:** After user edits content in canvas, Claude reads it back to incorporate changes.

### /canvas clear

**Execution:**

1. Read current `meta.json` to preserve contentType
2. Write empty template to `content.md`
3. Reset timestamps in `meta.json`

### /canvas close

**Execution:**

1. Optionally copy final content to clipboard (if requested)
2. Remove `.claude/canvas/` directory
3. Confirm cleanup

---

## Templates

### Email Template

```markdown
# Email Draft

**To:**
**CC:**
**Subject:**

---

Hi [Name],

[Your message here]

Best regards,
[Your name]

---
*Draft started: {timestamp}*
```

### Message Template

```markdown
# Message Draft

**To:** #channel / @person

---

[Your message here]

---
*Draft started: {timestamp}*
```

### Document Template

```markdown
# Document Title

## Overview

[Brief description]

## Details

[Main content]

## Summary

[Key takeaways]

---
*Draft started: {timestamp}*
```

---

## Integration

### Warp Launch Configuration

Install the launch config for one-click split pane setup:

**Location:** `~/.warp/launch_configurations/claude-canvas.yaml`

```yaml
name: Claude Canvas
windows:
  - tabs:
      - title: Claude Canvas
        color: Blue
        layout:
          split_direction: vertical
          panes:
            - is_focused: true
            - commands:
                - exec: "npx @claude-mods/canvas-tui --watch"
```

**Usage:**
1. Open Warp Command Palette (Cmd+P)
2. Search "Claude Canvas"
3. Select to open split layout

### Canvas TUI Package

```bash
# Install globally
npm install -g @claude-mods/canvas-tui

# Or run via npx
npx @claude-mods/canvas-tui --watch

# Options
canvas-tui --watch              # Watch .claude/canvas/content.md
canvas-tui --file ./draft.md    # Watch specific file
canvas-tui --help               # Show help
```

---

## File Locations

| File | Purpose |
|------|---------|
| `.claude/canvas/content.md` | Shared content file |
| `.claude/canvas/meta.json` | Session metadata |
| `~/.warp/launch_configurations/claude-canvas.yaml` | Warp split config |

---

## Notes

- Canvas TUI is view-only in MVP; edit mode planned for Phase 2
- File watching uses chokidar with 100ms debounce
- Works best with Warp terminal but compatible with any terminal that supports split panes
- Content persists until `/canvas close` is called
