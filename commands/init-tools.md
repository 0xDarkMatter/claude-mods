---
name: init-tools
description: "Initialize Claude Code with dev-shell-tools. Creates permissions, rules, and tool preferences in .claude/ directory."
---

# /init-tools

Initialize Claude Code with modern dev-shell-tools for a comfortable development experience.

## What This Does

**Installs complete dev environment setup:**

1. **Permissions** (`.claude/settings.local.json`) - Pre-approved CLI tools
2. **Rules** (`.claude/rules/cli-tools.md`) - Instructions to prefer modern tools

Tools from [dev-shell-tools](https://github.com/0xDarkMatter/dev-shell-tools):

**Core Tools:**
- **Git**: Full git access, lazygit, gh (GitHub CLI)
- **File ops**: ls, mkdir, cat, wc, tree, eza, bat
- **Search**: rg (ripgrep), fd, fzf, ast-grep/sg
- **Navigation**: zoxide/z, broot/br
- **Data processing**: jq, yq, sd
- **Diff tools**: delta, difft (difftastic)
- **Analysis**: tokei, procs, hyperfine

**Dev Tools:**
- **Package managers**: npm, node, python, uv, pip
- **Task runners**: just
- **Network**: curl, http (httpie)
- **Windows**: powershell

## Execution Flow

```
/init-tools
    |
    +-- Check for existing .claude/ files
    |     +-- If exists: Ask to overwrite or skip
    |     +-- If not: Proceed
    |
    +-- Create .claude directory
    +-- Create .claude/rules directory
    |
    +-- Write settings.local.json (permissions)
    +-- Write rules/cli-tools.md (tool preferences)
```

## Instructions

### Step 1: Check for existing settings

```bash
ls -la .claude/settings.local.json 2>/dev/null
ls -la .claude/rules/cli-tools.md 2>/dev/null
```

If files exist, ask user:
- **Overwrite**: Replace entirely
- **Skip**: Keep existing, do nothing

### Step 2: Create directories

```bash
mkdir -p .claude/rules
```

### Step 3: Write permissions file

Write to `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(cat:*)",
      "Bash(wc:*)",
      "Bash(tree:*)",
      "Bash(curl:*)",
      "Bash(rg:*)",
      "Bash(fd:*)",
      "Bash(fzf:*)",
      "Bash(z:*)",
      "Bash(zoxide:*)",
      "Bash(br:*)",
      "Bash(broot:*)",
      "Bash(ast-grep:*)",
      "Bash(sg:*)",
      "Bash(bat:*)",
      "Bash(eza:*)",
      "Bash(delta:*)",
      "Bash(difft:*)",
      "Bash(jq:*)",
      "Bash(yq:*)",
      "Bash(sd:*)",
      "Bash(lazygit:*)",
      "Bash(gh:*)",
      "Bash(tokei:*)",
      "Bash(uv:*)",
      "Bash(just:*)",
      "Bash(http:*)",
      "Bash(procs:*)",
      "Bash(hyperfine:*)",
      "Bash(npm:*)",
      "Bash(node:*)",
      "Bash(python:*)",
      "Bash(pip:*)",
      "Bash(powershell -Command:*)",
      "Bash(powershell.exe:*)"
    ],
    "deny": [],
    "ask": []
  },
  "hooks": {}
}
```

### Step 4: Write rules file

Write to `.claude/rules/cli-tools.md`:

```markdown
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

## Python

| Instead of | Use |
|------------|-----|
| `pip` | `uv` |
| `python -m venv` | `uv venv` |

## Task Running

Prefer `just` over Makefiles.

Reference: https://github.com/0xDarkMatter/dev-shell-tools
```

### Step 5: Confirm

Report to user:
```
Initialized Claude Code with dev-shell-tools:

Created:
  .claude/settings.local.json  (37 tool permissions)
  .claude/rules/cli-tools.md   (modern tool preferences)

Claude will now:
  - Auto-approve dev-shell-tools commands
  - Prefer fd over find, rg over grep, bat over cat, etc.

To customize: edit files in .claude/
To add to git: git add .claude/
```

## Options

| Flag | Effect |
|------|--------|
| `--force` | Overwrite existing without asking |
| `--perms-only` | Only install permissions, skip rules |
| `--rules-only` | Only install rules, skip permissions |
| `--minimal` | Minimal permissions (git, ls, cat, mkdir only) |
| `--full` | Add cloud/container tools (docker, kubectl, terraform, etc.) |

### Full Template (--full)

Adds to permissions:
```json
"Bash(docker:*)",
"Bash(docker-compose:*)",
"Bash(kubectl:*)",
"Bash(helm:*)",
"Bash(terraform:*)",
"Bash(aws:*)",
"Bash(gcloud:*)",
"Bash(az:*)",
"Bash(wrangler:*)"
```

## Notes

- Permissions are project-local (don't affect other projects)
- Rules instruct Claude to prefer modern tools
- Global settings in `~/.claude/` still apply
- Restart Claude Code session for changes to take effect
- Tools from: https://github.com/0xDarkMatter/dev-shell-tools
