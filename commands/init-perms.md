---
name: init-perms
description: "Initialize generous Claude Code permissions in current project. Creates .claude/settings.local.json with dev-shell-tools and common dev tool permissions."
---

# /init-perms

Initialize project-local Claude Code permissions for a comfortable development experience.

## What This Does

Creates `.claude/settings.local.json` in the current project with pre-approved permissions for modern CLI tools from [dev-shell-tools](https://github.com/0xDarkMatter/dev-shell-tools):

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
/init-perms
    │
    ├─→ Check if .claude/settings.local.json exists
    │     ├─ If exists: Ask to overwrite or merge
    │     └─ If not: Proceed
    │
    ├─→ Create .claude directory if needed
    │
    └─→ Write settings.local.json with standard permissions
```

## Instructions

### Step 1: Check for existing settings

```bash
ls -la .claude/settings.local.json 2>/dev/null
```

If file exists, show contents and ask user:
- **Overwrite**: Replace entirely with template
- **Skip**: Keep existing, do nothing
- **Merge**: Add missing permissions (advanced)

### Step 2: Create .claude directory

```bash
mkdir -p .claude
```

### Step 3: Write permissions file

Write this content to `.claude/settings.local.json`:

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

### Step 4: Confirm

Report to user:
```
Created .claude/settings.local.json with dev-shell-tools permissions.

Allowed tools (37 total):
  Core: git, ls, mkdir, cat, wc, tree, curl
  Search: rg, fd, fzf, ast-grep, sg
  Navigation: z, zoxide, br, broot
  View: bat, eza, delta, difft
  Data: jq, yq, sd
  Git: lazygit, gh
  Analysis: tokei, procs, hyperfine
  Dev: npm, node, python, pip, uv, just, http
  Windows: powershell

To customize: edit .claude/settings.local.json
To add to git: git add .claude/settings.local.json
```

## Options

| Flag | Effect |
|------|--------|
| `--force` | Overwrite existing without asking |
| `--minimal` | Only git, ls, cat, mkdir |
| `--full` | Add cloud/container tools (docker, kubectl, terraform, aws, etc.) |

### Minimal Template (--minimal)

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(cat:*)"
    ],
    "deny": [],
    "ask": []
  },
  "hooks": {}
}
```

### Full Template (--full)

Includes everything from standard template plus:

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
      "Bash(wget:*)",
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
      "Bash(docker:*)",
      "Bash(docker-compose:*)",
      "Bash(kubectl:*)",
      "Bash(helm:*)",
      "Bash(terraform:*)",
      "Bash(aws:*)",
      "Bash(gcloud:*)",
      "Bash(az:*)",
      "Bash(wrangler:*)",
      "Bash(powershell -Command:*)",
      "Bash(powershell.exe:*)"
    ],
    "deny": [],
    "ask": []
  },
  "hooks": {}
}
```

## Notes

- Permissions are project-local (don't affect other projects)
- Global permissions in `~/.claude/settings.json` still apply
- Project permissions can only ADD to global, not remove
- Restart Claude Code session for changes to take effect
- Tools from: https://github.com/0xDarkMatter/dev-shell-tools
