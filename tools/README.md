# Modern CLI Toolkit

Token-efficient CLI tools that replace verbose legacy commands. These tools are optimized for AI coding assistants by producing cleaner, more concise output.

## Why These Tools?

| Benefit | Impact |
|---------|--------|
| **Respects .gitignore** | 60-99% fewer irrelevant results |
| **Cleaner output** | 50-80% fewer tokens consumed |
| **Faster execution** | 2-100x speed improvements |
| **Better defaults** | Less flags needed |

## Quick Install

**Windows (PowerShell as Admin):**
```powershell
.\tools\install-windows.ps1
```

**Linux/macOS:**
```bash
./tools/install-unix.sh
```

## Tool Categories

### File Search & Navigation

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `find` | `fd` | 5x faster, simpler syntax, .gitignore aware |
| `grep` | `rg` (ripgrep) | 10x faster, .gitignore aware, better output |
| `ls` | `eza` | Git status, icons, tree view built-in |
| `cat` | `bat` | Syntax highlighting, line numbers |
| `cd` | `zoxide` | Smart directory jumping |
| `tree` | `broot` | Interactive, filterable tree |

### Data Processing

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `sed` | `sd` | Simpler regex syntax, no escaping pain |
| JSON manual | `jq` | Structured queries and transforms |
| YAML manual | `yq` | Same as jq for YAML/TOML |

### Git Operations

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `git diff` | `delta` | Syntax highlighting, side-by-side |
| `git diff` | `difft` | Semantic AST-aware diffs |
| `git *` | `lazygit` | Full TUI, faster workflow |
| GitHub web | `gh` | CLI for PRs, issues, actions |

### System Monitoring

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `du -h` | `dust` | Visual tree sorted by size |
| `top` | `btm` (bottom) | Graphs, cleaner UI |
| `ps aux` | `procs` | Structured, colored output |

### Code Analysis

| Task | Tool |
|------|------|
| Line counts | `tokei` |
| AST search | `ast-grep` / `sg` |
| Benchmarks | `hyperfine` |

### Interactive Selection

| Task | Tool |
|------|------|
| Fuzzy file find | `fzf` + `fd` |
| Interactive grep | `fzf` + `rg` |
| History search | `Ctrl+R` (fzf) |

### Documentation

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `man` | `tldr` | 98% smaller, practical examples |

### Python

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `pip` | `uv` | 10-100x faster installs |
| `python -m venv` | `uv venv` | Faster venv creation |

### Task Running

| Legacy | Modern | Improvement |
|--------|--------|-------------|
| `make` | `just` | Simpler syntax, better errors |

### AI Provider CLIs

Custom CLI wrappers included in this toolkit for multi-LLM delegation:

| Provider | CLI | Strength |
|----------|-----|----------|
| Gemini | `gemini` | 1M context, code analysis (install separately) |
| OpenAI | `codex` | Deep reasoning (install separately) |
| **Perplexity** | `perplexity` | **Web search + citations** (included) |

**Perplexity CLI** (included - runs via `perplexity.py`):
```bash
# Direct question with web-grounded answer
perplexity "What's new in TypeScript 5.7?"

# Use reasoning model for complex analysis
perplexity -m sonar-reasoning "Explain microservices vs monolith tradeoffs"

# Pipe content for analysis
cat code.py | perplexity "Review this code for security issues"

# Filter by recency (day, week, month, year)
perplexity --recency day "Latest AI news"

# Restrict search to specific domains
perplexity --domains "github.com,docs.python.org" "Python asyncio patterns"

# JSON output for programmatic use
perplexity --json "query" > output.json

# List available models
perplexity --list-models
```

**Models:**
| Model | Use Case |
|-------|----------|
| `sonar` | Fast, cost-effective for quick facts |
| `sonar-pro` | Complex queries, more citations (default) |
| `sonar-reasoning` | Multi-step problem solving |
| `sonar-reasoning-pro` | Deep reasoning (DeepSeek-R1) |
| `sonar-deep-research` | Comprehensive agentic research |

**Setup:**
```bash
# Set API key (get from https://www.perplexity.ai/settings/api)
export PERPLEXITY_API_KEY="your-key-here"

# Or add to ~/.claude/conclave.yaml:
# api_keys:
#   perplexity: "your-key-here"
```

---

### Web Fetching (URL Retrieval Hierarchy)

When Claude's built-in `WebFetch` gets blocked (403, Cloudflare, etc.), use these alternatives in order:

| Tool | When to Use | Setup |
|------|-------------|-------|
| **WebFetch** | First attempt - fast, built-in | None required |
| **Jina Reader** | JS-rendered pages, PDFs, cleaner extraction | Prefix URL with `r.jina.ai/` |
| **Firecrawl** | Anti-bot bypass, complex scraping, structured extraction | Use `firecrawl-expert` agent |

**Jina Reader** (free tier: 10M tokens):
```bash
# Simple - just prefix any URL
curl https://r.jina.ai/https://example.com

# Search + fetch in one call
curl https://s.jina.ai/your%20search%20query
```

**Firecrawl** (requires API key):
```bash
# Simple URL scrape (globally available)
firecrawl https://blocked-site.com

# Save to file
firecrawl https://example.com -o output.md

# With JSON metadata
firecrawl https://example.com --json

# For complex scraping, use the firecrawl-expert agent
```
- Handles Cloudflare, Datadome, and other anti-bot systems
- Supports interactive scraping (click, scroll, fill forms)
- AI-powered structured data extraction
- CLI: `E:\Projects\Coding\Firecrawl\scripts\fc.py`

**Decision Tree:**
1. Try `WebFetch` first (instant, free)
2. If blocked/JS-heavy → Try `r.jina.ai/URL` prefix
3. If still blocked → Try `firecrawl <url>` CLI
4. For complex scraping/extraction → Use `firecrawl-expert` agent

## Token Efficiency Benchmarks

Tested on a typical Node.js project with `node_modules`:

| Operation | Legacy | Modern | Token Savings |
|-----------|--------|--------|---------------|
| Find all files | `find`: 307 results | `fd`: 69 results | **78%** |
| Search 'function' | `grep`: 6,193 bytes | `rg`: 1,244 bytes | **80%** |
| Directory listing | `ls -laR`: 3,666 bytes | `eza --tree`: 670 bytes | **82%** |
| Disk usage | `du -h`: ~500 tokens | `dust`: ~100 tokens | **80%** |
| Man page | `man git`: ~5000 tokens | `tldr git`: ~100 tokens | **98%** |

## Verification

After installation, verify all tools:

```bash
# Check all tools are available
which fd rg eza bat zoxide delta difft jq yq sd lazygit gh tokei uv just ast-grep fzf dust btm procs tldr

# Check custom CLI wrappers
perplexity --list-models
```

## Experimental / Future

### Nushell - Structured Data Shell

[Nushell](https://www.nushell.sh/) is a modern shell that treats everything as structured data (tables, records, lists) instead of text streams. It could potentially replace jq + yq + awk + sed with a unified syntax.

**Status:** Experimental (v0.108.x) - not recommended for production scripts yet.

**When to consider:**
- Heavy data pipeline work (parsing APIs, configs)
- Frustrated with jq syntax
- Want unified commands across JSON/YAML/CSV/TOML

**Example comparison:**

```bash
# Traditional (jq)
curl -s api.example.com/users | jq '.data[] | select(.active) | .name'

# Nushell
http get api.example.com/users | where active | get name
```

```bash
# Traditional (multiple tools)
ps aux | grep node | awk '{print $2, $4}' | sort -k2 -nr

# Nushell
ps | where name == "node" | select pid mem | sort-by mem --reverse
```

**Why we're waiting:**
- Still 0.x (breaking changes possible)
- Learning curve for team environments
- Current jq + yq stack handles 95% of cases
- CI/CD scripts need POSIX bash compatibility

**Install (when ready to experiment):**
```bash
# Windows
winget install Nushell.Nushell

# macOS
brew install nushell

# Linux
cargo install nu
```

**Resources:**
- [Nushell Book](https://www.nushell.sh/book/)
- [Nushell GitHub](https://github.com/nushell/nushell)
- [Nushell for SREs](https://medium.com/@nonickedgr/nushell-for-sres-modern-shell-scripting-for-internal-tools-7b5dca51dc66)

---

## Sources

- [It's FOSS - Rust CLI Tools](https://itsfoss.com/rust-cli-tools/)
- [Zaiste - Shell Commands in Rust](https://zaiste.net/posts/shell-commands-rust/)
- [GitHub - Rust CLI Tools List](https://gist.github.com/sts10/daadbc2f403bdffad1b6d33aff016c0a)
- [DEV.to - CLI Tools You Can't Live Without](https://dev.to/lissy93/cli-tools-you-cant-live-without-57f6)
