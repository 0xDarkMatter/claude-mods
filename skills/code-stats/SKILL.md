---
name: code-stats
description: "Analyze codebase with tokei (fast line counts by language) and difft (semantic AST-aware diffs). Get quick project overview without manual counting. Triggers on: how big is codebase, count lines of code, what languages, show semantic diff, compare files, code statistics."
compatibility: "Requires tokei and difft CLI tools. Install: brew install tokei difft (macOS) or cargo install tokei difftastic (cross-platform)."
allowed-tools: "Bash"
---

# Code Statistics

## Purpose
Quickly analyze codebase size, composition, and changes with token-efficient output.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| tokei | `tokei` | Line counts by language |
| difft | `difft file1 file2` | Semantic AST-aware diffs |

## tokei - Code Statistics

### Basic Usage

```bash
# Count all code in current directory
tokei

# Count specific directory
tokei src/

# Count multiple directories
tokei src/ lib/ tests/

# Count specific file
tokei src/main.rs
```

### Output Options

```bash
# Compact single-line per language
tokei --compact

# Sort by lines of code
tokei --sort code

# Sort by number of files
tokei --sort files

# Sort by comments
tokei --sort comments

# Only show specific languages
tokei --type=TypeScript,JavaScript

# List all recognized languages
tokei --languages
```

### Filtering

```bash
# Exclude directories
tokei --exclude node_modules --exclude vendor --exclude dist

# Exclude by pattern
tokei --exclude "*.test.*" --exclude "*.spec.*"

# Include hidden files
tokei --hidden

# Only count certain languages
tokei -t Python,Rust
```

### Output Formats

```bash
# JSON output (for processing)
tokei --output json

# YAML output
tokei --output yaml

# CBOR output
tokei --output cbor

# Pipe JSON to jq
tokei --output json | jq '.TypeScript.code'
```

### Sample Output

```
===============================================================================
 Language            Files        Lines         Code     Comments       Blanks
===============================================================================
 TypeScript             45        12847         9823         1456         1568
 JavaScript             12         2341         1876          234          231
 JSON                    8          456          456            0            0
 Markdown               15         1234            0         1234            0
-------------------------------------------------------------------------------
 Total                  80        16878        12155         2924         1799
===============================================================================
```

### Understanding Output

| Column | Meaning |
|--------|---------|
| Files | Number of files of this language |
| Lines | Total lines (code + comments + blanks) |
| Code | Non-blank, non-comment lines |
| Comments | Comment lines |
| Blanks | Empty lines |

## difft - Semantic Diffs

### Basic Usage

```bash
# Compare two files
difft old.py new.py

# Compare directories
difft dir1/ dir2/

# Compare with options
difft --color=always old.ts new.ts
```

### Display Modes

```bash
# Side-by-side (default)
difft old.js new.js

# Inline (unified style)
difft --display=inline old.js new.js

# Show only changes
difft --skip-unchanged old.js new.js
```

### Git Integration

```bash
# Use as git difftool
git difftool --tool=difftastic HEAD~1

# Configure as default difftool
git config --global diff.tool difftastic
git config --global difftool.difftastic.cmd 'difft "$LOCAL" "$REMOTE"'

# Use for specific diff
GIT_EXTERNAL_DIFF=difft git diff HEAD~1
```

### Language Support

```bash
# Force language detection
difft --language=python old.py new.py

# List supported languages
difft --list-languages
```

### Why Semantic Diffs?

| Traditional diff | difft |
|-----------------|-------|
| Line-by-line comparison | AST-aware comparison |
| Shows moved lines as delete+add | Shows as moved |
| Whitespace sensitive | Ignores formatting changes |
| Can be noisy | Focuses on semantic changes |

## Comparison: tokei vs other tools

| Feature | tokei | cloc | wc -l |
|---------|-------|------|-------|
| Speed | Fastest | Slow | Fast |
| Language detection | Yes | Yes | No |
| Comment counting | Yes | Yes | No |
| .gitignore respect | Yes | Yes | No |
| JSON output | Yes | Yes | No |

## Common Workflows

### Project Assessment

```bash
# Quick overview
tokei --compact --sort code

# Detailed breakdown to file
tokei > code-stats.txt

# Compare before/after refactor
tokei --output json > before.json
# ... make changes ...
tokei --output json > after.json
diff before.json after.json
```

### Code Review

```bash
# Semantic diff for review
difft main.ts feature.ts

# Compare branches
git diff main feature -- "*.ts" | difft

# Review specific commit
GIT_EXTERNAL_DIFF=difft git show abc123
```

### CI Integration

```bash
# Check codebase size limits
LINES=$(tokei --output json | jq '.Total.code')
if [ "$LINES" -gt 100000 ]; then
  echo "Codebase exceeds 100k lines"
  exit 1
fi
```

## Quick Reference

| Task | Command |
|------|---------|
| Count all code | `tokei` |
| Compact output | `tokei --compact` |
| Sort by code | `tokei --sort code` |
| TypeScript only | `tokei -t TypeScript` |
| JSON output | `tokei --output json` |
| Exclude dir | `tokei --exclude node_modules` |
| Semantic diff | `difft file1 file2` |
| Inline diff | `difft --display=inline a b` |
| Git diff | `GIT_EXTERNAL_DIFF=difft git diff` |

## When to Use

- Getting quick codebase overview
- Comparing code changes semantically
- Understanding project composition
- Reviewing refactoring impact
- Estimating project size
- Tracking codebase growth over time
- Code review with meaningful diffs
