# @claude-mods/canvas-tui

Terminal canvas for Claude Code - live markdown preview in split panes.

Works with any terminal that supports split panes: **Warp**, **tmux**, **iTerm2**, **Windows Terminal**, and more.

## Installation

```bash
npm install -g @claude-mods/canvas-tui
```

Or run directly with npx:

```bash
npx @claude-mods/canvas-tui --watch
```

## Usage

```bash
# Watch default location (.claude/canvas/content.md)
canvas-tui --watch

# Watch specific directory
canvas-tui --watch ./my-canvas

# Watch specific file
canvas-tui --file ./draft.md

# Enable in-app scrolling (arrow keys instead of terminal scroll)
canvas-tui --watch --scroll

# Show help
canvas-tui --help
```

## Terminal Setup

### Warp
```bash
# Split pane: Ctrl+Shift+D (Windows/Linux) or Cmd+Shift+D (Mac)
# Or right-click > Split Pane
canvas-tui --watch
```

### tmux
```bash
# Split horizontally and run canvas
tmux split-window -h 'canvas-tui --watch'

# Or split vertically
tmux split-window -v 'canvas-tui --watch'

# From existing tmux session, split current pane
# Ctrl+B then % (horizontal) or " (vertical)
```

### iTerm2
```bash
# Split pane: Cmd+D (vertical) or Cmd+Shift+D (horizontal)
canvas-tui --watch
```

### Windows Terminal
```bash
# Split pane: Alt+Shift+D
# Or use wt command:
wt split-pane --horizontal canvas-tui --watch
```

## Keyboard Shortcuts

**Default mode (terminal scroll):**

| Key | Action |
|-----|--------|
| `q` | Quit |
| `Ctrl+C` | Quit |
| `r` | Refresh |

**With `--scroll` flag (in-app scroll):**

| Key | Action |
|-----|--------|
| `Up/Down` | Scroll |
| `g` | Go to top |
| `G` | Go to bottom |
| `q` | Quit |
| `r` | Refresh |

## Integration with Claude Code

This TUI works with the `/canvas` command in Claude Code:

1. Run `/canvas start --type email` in Claude Code
2. Open a split pane in your terminal
3. Run `canvas-tui --watch` in the split pane
4. Claude writes content, you see live preview

## File Structure

```
.claude/canvas/
├── content.md      # Shared content (Claude writes, TUI renders)
└── meta.json       # Session metadata
```

## Requirements

- Node.js >= 18.0.0
- Terminal with ANSI color support

## License

MIT
