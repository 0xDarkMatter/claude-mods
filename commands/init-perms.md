---
name: init-perms
description: "Initialize generous Claude Code permissions in current project. Creates .claude/settings.local.json with common dev tool permissions."
---

# /init-perms

Initialize project-local Claude Code permissions for a comfortable development experience.

## What This Does

Creates `.claude/settings.local.json` in the current project with pre-approved permissions for common development tools:

- **Git**: Full git access (`git:*`)
- **File ops**: `ls`, `mkdir`, `cat`, `wc`, `tree`
- **Data processing**: `jq`, `yq`
- **Package managers**: `npm`, `node`, `python`, `uv`, `pip`
- **Task runners**: `just`
- **Network**: `curl`
- **Windows**: `powershell`

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
      "Bash(jq:*)",
      "Bash(yq:*)",
      "Bash(npm:*)",
      "Bash(node:*)",
      "Bash(python:*)",
      "Bash(uv:*)",
      "Bash(pip:*)",
      "Bash(just:*)",
      "Bash(tree:*)",
      "Bash(curl:*)",
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
Created .claude/settings.local.json with development permissions.

Allowed tools:
  - git, ls, mkdir, cat, wc, tree
  - jq, yq (data processing)
  - npm, node, python, uv, pip
  - just, curl, powershell

To customize: edit .claude/settings.local.json
To add to git: git add .claude/settings.local.json
```

## Options

| Flag | Effect |
|------|--------|
| `--force` | Overwrite existing without asking |
| `--minimal` | Only git, ls, cat, mkdir |
| `--full` | Add additional tools (docker, kubectl, etc.) |

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

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(cat:*)",
      "Bash(wc:*)",
      "Bash(jq:*)",
      "Bash(yq:*)",
      "Bash(npm:*)",
      "Bash(node:*)",
      "Bash(python:*)",
      "Bash(uv:*)",
      "Bash(pip:*)",
      "Bash(just:*)",
      "Bash(tree:*)",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(docker:*)",
      "Bash(docker-compose:*)",
      "Bash(kubectl:*)",
      "Bash(terraform:*)",
      "Bash(aws:*)",
      "Bash(gcloud:*)",
      "Bash(az:*)",
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
