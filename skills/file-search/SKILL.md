# File Search Skill

Modern file and content search using fd, ripgrep (rg), and fzf for interactive selection.

## Triggers

fd, ripgrep, rg, find files, search code, fzf, fuzzy find, search codebase

## fd - Find Files (Better than find)

### Basic Usage
```bash
# Find by name (case-insensitive by default)
fd config                    # Files containing "config"
fd "\.ts$"                   # TypeScript files (regex)
fd -e py                     # Python files by extension

# Multiple extensions
fd -e js -e ts               # JS and TS files
fd -e md -e txt              # Markdown and text files
```

### Filtering
```bash
# By type
fd -t f config               # Files only
fd -t d src                  # Directories only
fd -t l                      # Symlinks only

# By depth
fd -d 2 config               # Max 2 levels deep
fd --min-depth 2 config      # At least 2 levels deep

# Include hidden/ignored
fd -H config                 # Include hidden files
fd -I config                 # Include .gitignore'd files
fd -HI config                # Include both
```

### Exclusion
```bash
# Exclude patterns
fd -E "*.min.js" -E "dist/"  # Exclude minified and dist
fd -E node_modules           # Exclude node_modules
fd config -E "*.bak"         # Find config, exclude backups
```

### Execute Commands
```bash
# Run command on each result
fd -e py -x wc -l            # Line count for each Python file
fd -e ts -x bat {}           # View each TypeScript file with bat
fd -e json -x jq . {}        # Pretty print each JSON file
```

## ripgrep (rg) - Search Content (Better than grep)

### Basic Usage
```bash
# Simple search
rg "TODO"                    # Find TODO in all files
rg "function \w+"            # Regex pattern
rg -i "error"                # Case-insensitive
rg -w "log"                  # Word boundary (not "catalog")
```

### File Filtering
```bash
# By type
rg -t py "import"            # Search Python files only
rg -t js -t ts "async"       # JS and TS files
rg --type-list               # Show all known types

# By glob
rg -g "*.tsx" "useState"     # Search .tsx files
rg -g "!*.test.*" "fetch"    # Exclude test files
rg -g "src/**" "config"      # Only in src directory
```

### Context and Format
```bash
# Show context lines
rg -C 3 "function"           # 3 lines before and after
rg -B 2 -A 5 "class"         # 2 before, 5 after

# Output format
rg -l "TODO"                 # File names only
rg -c "TODO"                 # Count per file
rg --json "TODO"             # JSON output
rg -n "TODO"                 # With line numbers (default)
```

### Advanced Patterns
```bash
# Multiline
rg -U "class.*\n.*constructor"   # Across lines

# Fixed strings (no regex)
rg -F "[]"                   # Literal brackets

# Invert match
rg -v "console.log"          # Lines NOT containing

# Replace (preview)
rg "oldFunc" -r "newFunc"    # Show replacements (use sd to apply)
```

## fzf - Interactive Selection

### Basic Workflows
```bash
# Find and open file
fd | fzf                             # Select file interactively
fd -e py | fzf                       # Select from Python files

# Find and edit
nvim $(fd -e ts | fzf)               # Open selected in nvim
code $(fd | fzf -m)                  # Open multiple in VS Code
```

### With Preview
```bash
# Preview with bat
fd | fzf --preview 'bat --color=always {}'

# Preview with rg context
rg -l "TODO" | fzf --preview 'rg -C 3 "TODO" {}'
```

### Multi-Select
```bash
# Select multiple (Tab to mark, Enter to confirm)
fd -e ts | fzf -m                    # Multi-select mode
fd -e ts | fzf -m | xargs rm         # Delete selected
```

### Combined Workflows
```bash
# Fuzzy grep: search content, select file, open at line
rg -n "pattern" | fzf --preview 'bat {1} --highlight-line {2}'

# Kill process interactively
procs | fzf | awk '{print $1}' | xargs kill

# Git branch checkout
git branch | fzf | xargs git checkout

# Git log with preview
git log --oneline | fzf --preview 'git show --color=always {1}'
```

## Combined Patterns

### Find and Search
```bash
# Find Python files, search for pattern
fd -e py -x rg "async def" {}

# Search specific directories
rg "import" $(fd -t d src lib)
```

### Find, Select, Act
```bash
# Interactive file deletion
fd -t f "\.bak$" | fzf -m | xargs rm -i

# Interactive config editing
fd -g "*.config.*" | fzf --preview 'bat {}' | xargs nvim
```

### Codebase Exploration
```bash
# Find all entry points
rg -l "^(export )?function main|^if __name__"

# Find all TODO/FIXME with context
rg -C 2 "TODO|FIXME|HACK|XXX"

# Find unused exports (basic)
rg "export (const|function|class) (\w+)" -o -r '$2' | sort | uniq
```

## Performance Tips

| Tip | Why |
|-----|-----|
| Both respect `.gitignore` | Automatically skip node_modules, dist, etc. |
| Use `-t` over `-g` when possible | Type flags are faster than globs |
| Narrow the path | `rg pattern src/` faster than `rg pattern` |
| Use `-F` for literal strings | Avoids regex engine overhead |
| Add `-u` for unignored only when needed | Hidden files slow things down |

## Quick Reference

| Task | Command |
|------|---------|
| Find TS files | `fd -e ts` |
| Find in src only | `fd -e ts src/` |
| Search for pattern | `rg "pattern"` |
| Search in type | `rg -t py "import"` |
| Files containing | `rg -l "pattern"` |
| Count matches | `rg -c "pattern"` |
| Interactive select | `fd \| fzf` |
| Multi-select | `fd \| fzf -m` |
| Preview files | `fd \| fzf --preview 'bat {}'` |
