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
```

## Sources

- [It's FOSS - Rust CLI Tools](https://itsfoss.com/rust-cli-tools/)
- [Zaiste - Shell Commands in Rust](https://zaiste.net/posts/shell-commands-rust/)
- [GitHub - Rust CLI Tools List](https://gist.github.com/sts10/daadbc2f403bdffad1b6d33aff016c0a)
- [DEV.to - CLI Tools You Can't Live Without](https://dev.to/lissy93/cli-tools-you-cant-live-without-57f6)
