# Shell Preference — PowerShell by default (WSL is the exception)

Companion to [cli-tools.md](cli-tools.md) and [modern-tools.md](modern-tools.md). Those pick *which tool*;
this picks *which shell syntax* to hand the user.

## The rule

**On this machine the user ALWAYS uses Windows PowerShell. Every command you give the user to run must be
PowerShell-native — never bash — UNLESS the current work is inside WSL (a Linux shell), where bash is the default.**

The user's PowerShell is **Windows PowerShell 5.1**: no `&&`/`||` chaining, no `export`, no `\` line-continuation,
no unix coreutils. Generate accordingly.

## Why this matters

The user flagged this emphatically after being handed bash one-liners that errored on paste
(`The token '&&' is not a valid statement separator in this version`). Bash syntax in their terminal is pure
friction every time. They use PowerShell for everything except explicit WSL/Linux work.

## How to apply — bash → PowerShell

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

**Interactive-prompt lines** (e.g. `keeper get` asking for a master password): tell the user to run that line
**alone**, because a multi-line paste feeds the following lines into the prompt.

## The WSL exception

When the work is explicitly in **WSL** / a Linux shell (the user says so, the cwd is a WSL path like
`/home/...` or `/mnt/...`, or the task is clearly Linux), **bash is the default there** — give bash commands.
Default to PowerShell whenever it's the normal Windows terminal.

## Scope

This governs **user-facing commands** — what the user pastes into their terminal. The assistant's own `Bash`
tool runs Git Bash internally and may keep using bash for its own execution; that's invisible to the user and
fine. The rule is about what you *hand the user to run*.
