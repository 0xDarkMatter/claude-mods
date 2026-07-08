# Shell Preference — speak the user's shell, never assume bash

Companion to [cli-tools.md](cli-tools.md) and [modern-tools.md](modern-tools.md). Those pick *which tool*;
this picks *which shell syntax* to hand the user.

> **Portability note:** the worked example below is the **author's** setup — Windows
> PowerShell 5.1 on Windows. It ships as one concrete instance of the pattern, not as
> universal law. Treat it as a template: if your interactive shell differs (zsh, fish,
> bash, pwsh 7, cmd), replace that example's table with your own shell's syntax. The
> pattern — detect the user's shell, hand them native commands — is the portable part.

## The rule

**Hand the user commands native to THEIR interactive shell — never assume bash.** Bash
is one shell, not the default of the universe. Before emitting a user-facing command,
infer which shell the user pastes into and use that shell's syntax.

A command in the wrong shell syntax errors on paste (e.g. `&&` is not a valid separator
in every shell) and is pure friction every time. Speaking the user's own shell avoids
that — the whole point of this rule.

How to tell which shell the user runs, in rough priority:

| Signal | Reads as |
|---|---|
| The user says so (`I'm on pwsh`, `use zsh`) | authoritative — use it |
| OS / platform (Windows → PowerShell or cmd; macOS/Linux → bash, zsh, fish) | strong default |
| cwd style (`X:\…` / `C:\Users\…` → Windows; `/home/…`, `/mnt/…` → WSL/Linux) | corroborating |
| Commands that already ran cleanly this session | corroborating |

When the signals conflict or you can't tell, **ask once** rather than guess.

This governs **user-facing commands** — what the user pastes into their terminal. The
assistant's own `Bash` tool runs Git Bash internally and may keep using bash for its own
execution; that's invisible to the user and fine.

## The same principle, applied to WSL

When the work is explicitly inside **WSL** / a Linux shell — the user says so, the cwd
is a WSL path like `/home/…` or `/mnt/…`, or the task is clearly Linux — the user's
interactive shell there is **bash**, so hand them bash. This isn't a special case bolted
on; it's the same rule (speak their shell) applied to a shell that happens not to be the
host's default.

## Worked example: a Windows PowerShell 5.1 user

The author of this plugin pastes into **Windows PowerShell 5.1**. Generate against its
limits: no `&&`/`||` chaining, no `export`, no `\` line-continuation, no unix coreutils.
The table below is the bash → PowerShell translation that keeps paste-error friction to
zero for that one user. **If your shell differs, replace this whole section with your own
table** — see the portability note above.

| Don't give the user | Give instead |
|---|---|
| `export NAME=value` | `$env:NAME = "value"` |
| `cmd1 && cmd2` | two separate lines (PS 5.1 has **no** `&&`). `;` runs sequentially but does **not** stop on failure |
| `cmd1 \`<newline>` continuation | one line, or backtick `` ` `` continuation |
| `cd /x/Roam/BlockLab` | `cd X:\Roam\BlockLab` |
| `grep PAT file` | `Select-String -Path file -Pattern 'PAT'` |
| `jq '.x' f.json` | `Get-Content f.json \| ConvertFrom-Json \| % { $_.x }` |
| `cat` / `cut -d= -f2` | `Get-Content` / `.Split('=')[1]` |
| `$(cmd)` | `(cmd)` (or `$(cmd)` works too, but `(cmd)` is idiomatic) |
| `VAR=x cmd` (inline env) | `$env:VAR='x'; cmd` |

**Interactive-prompt lines** (e.g. `keeper get` asking for a master password): tell the
user to run that line **alone**, because a multi-line paste feeds the following lines
into the prompt.
