# @claude-mods/canvas-tui

Terminal canvas for Claude Code - live markdown preview in split panes.

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

# Show help
canvas-tui --help
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `q` | Quit |
| `Ctrl+C` | Quit |
| `Up/Down` | Scroll |
| `g` | Go to top |
| `G` | Go to bottom |
| `r` | Refresh |

## Integration with Claude Code

This TUI works with the `/canvas` command in Claude Code:

1. Run `/canvas start --type email` in Claude Code
2. Open a split pane in your terminal
3. Run `canvas-tui --watch` in the split pane
4. Claude writes content, you see live preview

## Warp Terminal

For Warp users, install the launch configuration:

```bash
# Windows
copy templates\warp\claude-canvas.yaml %APPDATA%\warp\Warp\data\launch_configurations\

# macOS/Linux
cp templates/warp/claude-canvas.yaml ~/.warp/launch_configurations/
```

Then open Warp Command Palette and search "Claude Canvas".

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
