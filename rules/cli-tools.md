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

## Document Conversion

| Instead of | Use | Why |
|------------|-----|-----|
| PyMuPDF/pdfplumber | `markitdown` | One tool for PDF, Word, Excel, PowerPoint |
| python-docx | `markitdown` | Consistent markdown output |
| Manual OCR | `markitdown` | Built-in image text extraction |

```bash
# Convert documents to markdown (use markitdown)
markitdown document.pdf           # PDF to markdown
markitdown report.docx            # Word to markdown
markitdown data.xlsx              # Excel to markdown tables
markitdown slides.pptx            # PowerPoint to markdown
markitdown screenshot.png         # OCR image text
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

When fetching web content, use this hierarchy based on benchmarked performance:

| Priority | Tool | Speed | Use Case |
|----------|------|-------|----------|
| 1 | `WebFetch` | Instant | First attempt - built-in |
| 2 | `r.jina.ai/URL` | **0.5s avg** | Default fallback - 5-10x faster than alternatives |
| 3 | `firecrawl <url>` | 4-5s avg | Anti-bot bypass, Cloudflare, heavy JS |
| 4 | `markitdown <url>` | 2-3s avg | Simple static pages (or local files) |

```bash
# Jina Reader - fastest option (free, 10M tokens)
curl https://r.jina.ai/https://example.com

# Jina Search - search + fetch in one call
curl https://s.jina.ai/your%20search%20query

# Firecrawl CLI - anti-bot bypass
firecrawl https://blocked-site.com
firecrawl https://example.com --json

# markitdown - simple pages or local files
markitdown https://example.com
markitdown document.pdf
```

**Decision Tree:**
1. Try `WebFetch` first (instant, free)
2. If blocked → Try Jina: `r.jina.ai/URL` (fastest, 10/10 success rate)
3. If anti-bot/Cloudflare → Try `firecrawl <url>` (designed for bypass)
4. For local files (PDF, Word, Excel) → Use `markitdown`

## Reference

Tools from: https://github.com/0xDarkMatter/claude-mods/tree/main/tools

Install all tools:
```bash
# Windows (as Admin)
.\tools\install-windows.ps1

# Linux/macOS
./tools/install-unix.sh
```
