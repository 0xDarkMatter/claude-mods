---
name: safe-file-reader
description: Read and view files without permission prompts. Use bat for syntax-highlighted code viewing, eza for directory listings with git status, cat/head/tail for plain text. Triggers on: view file, show code, list directory, explore codebase, read config, display contents.
---

# Safe File Reader

## Purpose
Reduce permission friction when reading and viewing files during development workflows.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| bat | `bat file.py` | Syntax-highlighted code with line numbers |
| eza | `eza -la --git` | Directory listings with git status |
| cat | `cat file.txt` | Plain text output |
| head | `head -n 50 file.log` | First N lines of file |
| tail | `tail -n 100 file.log` | Last N lines of file |

## Usage Examples

```bash
# View code with syntax highlighting
bat src/main.py

# View specific line range
bat src/main.py -r 10:50

# List directory with git status
eza -la --git

# Tree view of directory
eza --tree --level=2

# First 50 lines of log
head -n 50 app.log

# Follow log file
tail -f app.log
```

## When to Use

- User asks to "show", "view", or "display" a file
- Exploring a codebase structure
- Reading configuration files
- Checking log files
- Listing directory contents
