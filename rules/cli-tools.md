# CLI Tool Preferences (dev-shell-tools)

ALWAYS prefer modern CLI tools over traditional alternatives. These are pre-approved in permissions.

## File Search & Navigation

| Instead of | Use | Why |
|------------|-----|-----|
| `find` | `fd` | 5x faster, simpler syntax, respects .gitignore |
| `grep` | `rg` (ripgrep) | 10x faster, respects .gitignore, better defaults |
| `ls` | `eza` | Git status, icons, tree view built-in |
| `cat` | `bat` | Syntax highlighting, line numbers, git integration |
| `cd` + manual | `z`/`zoxide` | Jump to frecent directories |
| `tree` | `broot` or `eza --tree` | Interactive, filterable |

### Examples

```bash
# Find files (use fd, not find)
fd "\.ts$"                    # Find TypeScript files
fd -e py                      # Find by extension

# Search content (use rg, not grep)
rg "TODO"                     # Search for TODO
rg -t ts "function"           # Search in TypeScript files

# List files (use eza, not ls)
eza -la --git                 # List with git status
eza --tree --level=2          # Tree view

# View files (use bat, not cat)
bat src/index.ts              # Syntax highlighted
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

# JSON processing
jq '.dependencies | keys' package.json

# YAML processing
yq '.services | keys' docker-compose.yml
```

## Git Operations

| Instead of | Use | Why |
|------------|-----|-----|
| `git diff` | `delta` or `difft` | Syntax highlighting, side-by-side |
| `git log/status/add` | `lazygit` | Full TUI, faster workflow |
| GitHub web | `gh` | CLI for PRs, issues, actions |

```bash
# Better diffs
git diff | delta              # Syntax highlighted diff
difft file1.ts file2.ts       # Semantic AST diff

# GitHub operations
gh pr create                  # Create PR from CLI
gh pr list                    # List PRs
```

## Code Analysis

| Task | Tool |
|------|------|
| Line counts | `tokei` |
| AST search | `ast-grep` / `sg` |
| Benchmarks | `hyperfine` |

```bash
# Count lines by language
tokei --compact

# Search by AST pattern (find all console.log calls)
sg -p 'console.log($$$)' -l js

# Benchmark commands
hyperfine 'fd . -e ts' 'find . -name "*.ts"'
```

## System Monitoring

| Instead of | Use | Why |
|------------|-----|-----|
| `du -h` | `dust` | Visual tree sorted by size |
| `top`/`htop` | `btm` (bottom) | Graphs, cleaner UI (optional) |

```bash
# Disk usage (use dust, not du)
dust                          # Visual tree sorted by size
dust -d 2                     # Limit depth
```

**Note:** `ps` is fine for shell process checks. Use `procs` only when you need full system process monitoring with CPU/memory stats.

## Interactive Selection

| Task | Tool |
|------|------|
| Fuzzy file find | `fzf` + `fd` |
| Interactive grep | `fzf` + `rg` |
| History search | `Ctrl+R` (fzf) |
| Git branch select | `git branch \| fzf` |

```bash
# Fuzzy find and open file
fd --type f | fzf | xargs bat

# Interactive grep results
rg --line-number . | fzf --preview 'bat --color=always {1} --highlight-line {2}'

# Select git branch
git checkout $(git branch | fzf)

# Kill process interactively
procs | fzf | awk '{print $1}' | xargs kill
```

## Documentation

| Instead of | Use | Why |
|------------|-----|-----|
| `man <cmd>` | `tldr <cmd>` | 98% smaller, practical examples only |

```bash
# Quick command reference (use tldr, not man)
tldr git-rebase               # Concise examples
tldr tar                      # No more forgetting tar flags
```

## Python

| Instead of | Use | Why |
|------------|-----|-----|
| `pip` | `uv` | 10-100x faster installs |
| `python -m venv` | `uv venv` | Faster venv creation |

```bash
uv venv .venv
uv pip install -r requirements.txt
```

## Task Running

Prefer `just` over Makefiles:

```bash
just                          # List available tasks
just test                     # Run test task
```

## Web Fetching (URL Retrieval)

When fetching web content, use this hierarchy in order:

| Priority | Tool | When to Use |
|----------|------|-------------|
| 1 | `WebFetch` | First attempt - fast, built-in |
| 2 | `r.jina.ai/URL` | JS-rendered pages, PDFs, cleaner extraction |
| 3 | `firecrawl <url>` | Anti-bot bypass, blocked sites (403, Cloudflare) |
| 4 | `firecrawl-expert` agent | Complex scraping, structured extraction |

```bash
# Jina Reader - prefix any URL (free, 10M tokens)
curl https://r.jina.ai/https://example.com

# Jina Search - search + fetch in one call
curl https://s.jina.ai/your%20search%20query

# Firecrawl CLI - when WebFetch gets blocked
firecrawl https://blocked-site.com
firecrawl https://example.com -o output.md
firecrawl https://example.com --json
```

**Decision Tree:**
1. Try `WebFetch` first (instant, free)
2. If 403/blocked/JS-heavy → Try Jina: `r.jina.ai/URL`
3. If still blocked → Try `firecrawl <url>`
4. For complex scraping → Use `firecrawl-expert` agent

## Reference

Tools from: https://github.com/0xDarkMatter/claude-mods/tree/main/tools

Install all tools:
```bash
# Windows (as Admin)
.\tools\install-windows.ps1

# Linux/macOS
./tools/install-unix.sh
```
