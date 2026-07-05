# Modern Tools — Enforcement

Companion to [cli-tools.md](cli-tools.md). cli-tools.md is the *reference* (what's available). This file is the *directive* (which to pick when drafting commands, scripts, install instructions, or docs).

## The rule

**Default to the most modern, canonical tool. Never drift back to legacy aliases just because they're more common in the wild.**

This applies whenever you're generating user-facing commands — README install steps, Dockerfile RUN lines, CI workflows, AGENTS.md run-commands tables, scratch shell snippets, anything the user will see or copy-paste.

## Why this matters

The user has explicitly built their environment around modern tooling and pre-approved permissions for it. Every legacy fallback you generate is friction the user has to undo. The user notices. They've corrected this drift more than once.

Modern tools are also typically 10–100× faster (uv vs pip, fd vs find, rg vs grep) — defaulting legacy is a measurable cost, not a stylistic preference.

## Translation table (this is what "modern" means here)

| Don't generate | Generate instead | Why |
|---|---|---|
| `pip install <pkg>` | `uv tool install <pkg>` (CLI tool) <br/> `uv add <pkg>` (project dep) <br/> `uv pip install <pkg>` (last resort) | uv is 10–100× faster; `uv tool` is the right answer for CLI binaries — isolated env, lands on PATH, supports `uv tool upgrade` / `uninstall` |
| `pipx install <pkg>` / `pipx run <pkg>` | `uv tool install <pkg>` / `uvx <pkg>` | uvx is the one-shot ephemeral runner; uv tool is persistent |
| `pip install -e .` | `uv sync` (uv-managed project) <br/> `uv pip install -e ".[dev]"` (last resort) | `uv sync` reads pyproject + lockfile, installs everything, faster |
| `python -m venv .venv` | `uv venv .venv` | Faster |
| `python -m pip install` | `uv pip install` | Same |
| VCS install: `pip install git+https://...` | `uv tool install git+https://...` <br/> or `uvx --from git+https://... <cmd>` | Modern equivalent works identically |
| `find . -name "*.py"` | `fd -e py` | Faster, respects .gitignore, simpler syntax |
| `grep -r "pattern"` | `rg "pattern"` | 10× faster, respects .gitignore |
| `sed -i 's/old/new/g' file` | `sd 'old' 'new' file` | No escaping headaches |
| `cat file.py` (for display) | `bat file.py` | Syntax highlighting; for editing, use the Read tool |
| `ls -la --git` | `eza -la --git` | Git status + icons in one command |
| `man <cmd>` | `tldr <cmd>` | Practical examples, 98% smaller |
| `du -sh *` | `dust` | Visual tree |
| `make <target>` | `just <target>` | Simpler syntax, no tab-vs-space pain |
| `top` / `htop` | `btm` (when shown to user) | Cleaner UI; `ps` is fine for shell scripts |

## Web fetch hierarchy (when fetching URL content)

Never default to `curl <url>` for content extraction. Use this priority:

1. `WebFetch` tool — built-in, instant
2. `r.jina.ai/<url>` — fastest fallback (~0.5s avg)
3. `firecrawl <url>` — anti-bot bypass (Cloudflare, heavy JS)
4. `markitdown <url>` — simple static pages or local files

## Docker base images

When writing Dockerfiles, install uv from the official image rather than `pip install uv`:

```dockerfile
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/
```

Then use `uv tool install`, `uv sync`, etc. Avoid plain `pip` in `RUN` lines.

## When to bend the rule

If a downstream user's environment provably doesn't have uv (e.g. constrained CI runner, system without HOME write access), document the legacy fallback as a **footnote**, not the default. Default-modern, footnote-legacy.

If the user explicitly asks for a `pip`/`find`/`grep` invocation (e.g. "show me the pip command for X"), give them what they asked for — but mention the modern equivalent in passing.

## Self-check before writing install/setup docs

Before committing any `README.md`, `QUICKSTART.md`, `DEPLOYMENT.md`, `Dockerfile`, or `.github/workflows/*.yml`:

```
rg -n 'pip install|pipx |\bfind \.|^grep |sed -i|^cat ' <file>
```

If anything matches, ask: is this *really* the modern way, or am I drifting?

## Cross-reference

- `cli-tools.md` — reference table (what's installed, syntax cheatsheet)
- `commit-style.md` — Conventional Commits enforcement
- This file — picks-which-tool enforcement when *generating* commands
