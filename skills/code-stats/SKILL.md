---
name: code-stats
description: Analyze codebase with tokei (fast line counts by language) and difft (semantic AST-aware diffs). Get quick project overview without manual counting. Triggers on: how big is codebase, count lines of code, what languages, show semantic diff, compare files, code statistics.
---

# Code Statistics

## Purpose
Quickly analyze codebase size, composition, and changes with token-efficient output.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| tokei | `tokei` | Line counts by language |
| difft | `difft file1 file2` | Semantic AST-aware diffs |

## Usage Examples

### Code Statistics with tokei

```bash
# Count all code in current directory
tokei

# Count specific directory
tokei src/

# Count specific languages
tokei --type=Python,JavaScript

# Compact output
tokei --compact

# Sort by lines of code
tokei --sort=code

# Exclude directories
tokei --exclude=node_modules --exclude=vendor
```

### Semantic Diffs with difft

```bash
# Compare two files
difft old.py new.py

# Use as git difftool
git difftool --tool=difftastic HEAD~1

# Compare directories
difft dir1/ dir2/

# Inline display mode
difft --display=inline old.js new.js
```

## Output Interpretation

### tokei output
- **Lines**: Total lines including blanks
- **Code**: Actual code lines
- **Comments**: Comment lines
- **Blanks**: Empty lines

### difft output
- Shows structural changes, not line-by-line
- Highlights moved code blocks
- Ignores whitespace-only changes

## When to Use

- Getting quick codebase overview
- Comparing code changes semantically
- Understanding project composition
- Reviewing refactoring impact
- Estimating project size
