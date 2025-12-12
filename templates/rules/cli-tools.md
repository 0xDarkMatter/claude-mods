# CLI Tool Preferences

Prefer modern, fast CLI tools over traditional alternatives. These tools are pre-approved in permissions.

## File Search & Navigation

| Instead of | Use | Why |
|------------|-----|-----|
| `find` | `fd` | 5x faster, simpler syntax, respects .gitignore |
| `grep` | `rg` (ripgrep) | 10x faster, respects .gitignore, better defaults |
| `ls` | `eza` | Git status, icons, tree view built-in |
| `cat` | `bat` | Syntax highlighting, line numbers, git integration |
| `cd` + manual | `z`/`zoxide` | Jump to frecent directories |
| `tree` | `broot` or `eza --tree` | Interactive, filterable |

## Examples

```bash
# Find files (use fd, not find)
fd "\.ts$"                    # Find TypeScript files
fd -e py                      # Find by extension
fd -H config                  # Include hidden files

# Search content (use rg, not grep)
rg "TODO"                     # Search for TODO
rg -t ts "function"           # Search in TypeScript files
rg -l "error"                 # List files with matches

# List files (use eza, not ls)
eza -la --git                 # List with git status
eza --tree --level=2          # Tree view

# View files (use bat, not cat)
bat src/index.ts              # Syntax highlighted
bat -l json data.txt          # Force language

# Navigate (use z, not cd)
z project                     # Jump to frecent "project" dir
```

## Data Processing

| Instead of | Use | Why |
|------------|-----|-----|
| `sed` | `sd` | Simpler syntax, no escaping headaches |
| Manual JSON | `jq` | Structured queries, transformations |
| Manual YAML | `yq` | Same as jq but for YAML/TOML |

```bash
# Find and replace (use sd, not sed)
sd 'oldText' 'newText' file.txt
sd -f 'pattern' 'replacement' **/*.ts

# JSON processing
jq '.dependencies | keys' package.json
jq -r '.scripts | to_entries[] | "\(.key): \(.value)"' package.json

# YAML processing
yq '.services | keys' docker-compose.yml
```

## Git Operations

| Instead of | Use | Why |
|------------|-----|-----|
| `git diff` | `delta` or `difft` | Syntax highlighting, side-by-side |
| `git log/status/add` manually | `lazygit` | Full TUI, faster workflow |
| GitHub web | `gh` | CLI for PRs, issues, actions |

```bash
# Better diffs
git diff | delta              # Syntax highlighted diff
difft file1.ts file2.ts       # Semantic AST diff

# GitHub operations
gh pr create                  # Create PR from CLI
gh pr list                    # List PRs
gh issue list                 # List issues
```

## Code Analysis

| Task | Tool | Example |
|------|------|---------|
| Line counts | `tokei` | `tokei src/` |
| AST search | `ast-grep` | `sg -p 'console.log($_)' -l ts` |
| Benchmarks | `hyperfine` | `hyperfine 'npm test' 'yarn test'` |
| Process view | `procs` | `procs --tree` |

## Python

| Instead of | Use | Why |
|------------|-----|-----|
| `pip` | `uv` | 10-100x faster installs |
| `python -m venv` | `uv venv` | Faster venv creation |
| `pip install -r` | `uv pip install -r` | Parallel, cached |

```bash
uv venv .venv                 # Create venv
uv pip install -r requirements.txt
uv pip install pandas         # Install package
```

## Task Running

Prefer `just` over Makefiles for task running:

```bash
just                          # List available tasks
just test                     # Run test task
just build                    # Run build task
```
