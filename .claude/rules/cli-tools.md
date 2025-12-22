# CLI Tool Preferences (dev-shell-tools)

ALWAYS prefer modern CLI tools over traditional alternatives.

## File Search & Navigation

| Instead of | Use | Why |
|------------|-----|-----|
| `find` | `fd` | 5x faster, respects .gitignore |
| `grep` | `rg` (ripgrep) | 10x faster, respects .gitignore |
| `ls` | `eza` | Git status, tree view |
| `cat` | `bat` | Syntax highlighting |
| `cd` + manual | `z`/`zoxide` | Frecent directories |
| `tree` | `eza --tree` | Interactive |

## Data Processing

| Instead of | Use |
|------------|-----|
| `sed` | `sd` |
| Manual JSON | `jq` |
| Manual YAML | `yq` |

## Git Operations

| Instead of | Use |
|------------|-----|
| `git diff` | `delta` or `difft` |
| Manual git | `lazygit` |
| GitHub web | `gh` |

## Code Analysis

- Line counts: `tokei`
- AST search: `ast-grep` / `sg`
- Benchmarks: `hyperfine`
- Disk usage: `dust`

## System Monitoring

| Instead of | Use |
|------------|-----|
| `du -h` | `dust` |
| `top`/`htop` | `btm` (bottom) |

## Documentation

| Instead of | Use |
|------------|-----|
| `man <cmd>` | `tldr <cmd>` |

## Python

| Instead of | Use |
|------------|-----|
| `pip` | `uv` |
| `python -m venv` | `uv venv` |

## Task Running

Prefer `just` over Makefiles.

## Web Fetching

| Priority | Tool | When to Use |
|----------|------|-------------|
| 1 | `WebFetch` | First attempt - fast, built-in |
| 2 | `r.jina.ai/URL` | JS-rendered pages, cleaner extraction |
| 3 | `firecrawl <url>` | Anti-bot bypass, blocked sites |

## AI CLI Tools

For multi-model analysis (see /conclave command):

| Tool | Model | Best For |
|------|-------|----------|
| `gemini` | Gemini 2.5 | 2M context, large codebases |
| `claude` | Claude | Coding, analysis |
| `codex` | OpenAI | Deep reasoning |
| `perplexity` | Perplexity | Web search, current info |

## Git Safety

Destructive commands require confirmation (in "ask" list):

| Command | Risk | Safe Alternative |
|---------|------|------------------|
| `git reset --hard` | Loses uncommitted changes | `git stash` first |
| `git checkout -- <file>` | Discards file changes | `git stash` or `git diff` first |
| `git clean -fd` | Deletes untracked files | `git clean -n` (dry run) first |
| `git stash drop` | Permanently deletes stash | Check `git stash list` first |
| `git push --force` | Overwrites remote history | `git push --force-with-lease` |
| `git branch -D` | Deletes unmerged branch | `git branch -d` (safe delete) |

**Before destructive operations:**
1. Check status: `git status`
2. Check for uncommitted changes: `git diff`
3. Consider stashing: `git stash`
4. Use dry-run flags when available

Reference: https://github.com/0xDarkMatter/dev-shell-tools
