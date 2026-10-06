# Hooks

Claude Code hooks allow you to run custom scripts at key workflow points.

## Available Hooks

| Hook Script | Type | Purpose |
|-------------|------|---------|
| `pre-commit-lint.sh` | PreToolUse | Auto-lint staged files before commit (JS/TS, Python, Go, Rust, PHP) |
| `post-edit-format.sh` | PostToolUse | Auto-format files after Write/Edit (Prettier, Ruff, gofmt, rustfmt) |
| `dangerous-cmd-warn.sh` | PreToolUse | Block destructive commands (force push, rm -rf, DROP TABLE, etc.) |
| `enforce-uv.sh` | PreToolUse | Enforce uv over pip/bare tools in uv-managed projects (`pip install` → `uv add`, bare `pytest`/`ruff`/`mypy` → `uv run`) |
| `pre-install-scan.sh` | PreToolUse | Advisory on dependency installs (npm/pnpm/yarn/bun/pip/uv/poetry/composer/gem/cargo, incl. `composer update`) — route through Socket, respect the release-age cooldown. `SUPPLY_CHAIN_BLOCK=1` for a hard gate. |
| `manifest-dep-scan.sh` | PostToolUse (Write\|Edit) | Advisory when the agent edits a dependency manifest (package.json/requirements/composer.json/Cargo.toml/go.mod/Gemfile/pyproject.toml) — depscore + cooldown the added package. High-signal (silent on version bumps). |
| `check-mail.sh` | PreToolUse | Check for unread pigeon pmail via signal file (zero-cost when empty) |
| `config-change-guard.sh` | ConfigChange | Worm-persistence tripwire: when a Claude settings file changes mid-session, scan just that file for the vetted IOC set (curl\|sh, base64-decode eval, Invoke-Expression+Download, /dev/tcp, reads of `.claude/settings` / `.aws/credentials`). Silent on clean; on a finding, a desktop notification (`terminalSequence`, interactive sessions only - ConfigChange discards `systemMessage`, so no text reaches you or the model). `SUPPLY_CHAIN_BLOCK=1` blocks the change (exit 2). Fast single-file sibling of `supply-chain-defense`'s `integrity-audit.sh`. |
| `worktree-guard.sh` | PreToolUse (Bash) | Enforce `rules/worktree-boundaries.md`: flags `rm` on `.claude/worktrees`, `git worktree remove/prune` against worktrees, `git rm` on worktree gitlinks, and `git add -A`/`.` in a repo that has a `.claude/worktrees` dir. Sessions whose cwd is inside their own worktree are exempt. Advisory by default; `WORKTREE_GUARD_BLOCK=1` hard-denies (exit 2). |
| `session-start-unicode-scan.sh` | SessionStart | One-shot hidden-Unicode scan of the project's instruction files (CLAUDE.md/AGENTS.md/SKILL.md/.cursorrules) at session boot. Silent on clean; advisory on a finding, and a separate "NOT scanned" advisory naming any file the scanner could not read. Pairs with `prompt-injection-defense`. |
| `pre-write-peer-guard.sh` | PreToolUse (Edit\|Write) | Mid-session peer-writer guard (`rules/worktree-boundaries.md`): before writing a file, warn if it was freshly modified by something that isn't this session — the signature of a live peer session sharing the checkout. Uses the touched-ledger to tell own edits apart. Advisory by default; `GUARD_BLOCK=1` denies the write. Auto-wired with its ledger companion. |
| `session-touched-ledger.sh` | PostToolUse (Edit\|Write) | Companion to `pre-write-peer-guard.sh`: records every file this session writes to `~/.claude/.session-touched/<session_id>.list` so the guard can distinguish this session's edits from a peer's. Silent, never blocks. Auto-wired with the peer guard. |
| `pre-commit-unicode-scan.sh` | git pre-commit | Refuse commits that ADD hidden Unicode to instruction files. Scans the **staged (index) copy**, not the file on disk, including renamed and non-ASCII-named files. Silent on clean, warn on `high`, **block on `critical`** (tag-block / bidi override) **or on a staged instruction file it could not scan**. Override once with `PROMPT_INJECTION_ALLOW=1`. |

## Auto-wired vs opt-in

`hooks/hooks.json` is the **plugin-level hook config** — when claude-mods is installed
as a plugin, these hooks are active automatically (no settings.json hand-wiring), with
paths resolved via `${CLAUDE_PLUGIN_ROOT}`:

| Set | Hooks | Why |
|-----|-------|-----|
| **Auto-wired (security advisory)** | `pre-install-scan.sh` (PreToolUse Bash), `worktree-guard.sh` (PreToolUse Bash), `manifest-dep-scan.sh` (PostToolUse Write\|Edit), `session-start-unicode-scan.sh` (SessionStart), `config-change-guard.sh` (ConfigChange), `pre-write-peer-guard.sh` (PreToolUse Write\|Edit), `session-touched-ledger.sh` (PostToolUse Write\|Edit) | Silent-on-clean guardrails: zero noise until something is actually wrong, so they're safe to ship on by default. |
| **Opt-in (opinionated / formatting)** | `pre-commit-lint.sh`, `post-edit-format.sh`, `dangerous-cmd-warn.sh`, `enforce-uv.sh`, `check-mail.sh`, `pre-commit-unicode-scan.sh` (a *git* hook) | Workflow opinions — wire them yourself per the examples below. |

Plugin installs resolve auto-wired commands through `${CLAUDE_PLUGIN_ROOT}`. Script
installs copy the hook scripts into `${CLAUDE_DIR:-~/.claude}/hooks/` and merge the
same wiring into `settings.json`. Existing settings and hook groups are preserved;
an already-wired script path is not added again.

### Env toggles (auto-wired set)

All auto-wired hooks are **advisory by default** (exit 0, command/change proceeds).
Escalate to a hard gate per concern:

| Variable | Affects | Effect when `1` |
|----------|---------|-----------------|
| `SUPPLY_CHAIN_BLOCK` | `pre-install-scan.sh`, `config-change-guard.sh` | Block the install / settings change (exit 2) until reviewed |
| `WORKTREE_GUARD_BLOCK` | `worktree-guard.sh` | Deny the boundary-violating command (exit 2) |

### ConfigChange coverage note

`ConfigChange` fires only for Claude settings sources (`user_settings`,
`project_settings`, `local_settings`; `policy_settings` can't be blocked, `skills` has
no single file). It does **not** fire for VS Code `settings.json` or `~/.claude.json` —
those persistence surfaces are covered by the periodic
`skills/supply-chain-defense/scripts/integrity-audit.sh` sweep. The payload carries a
`source` field (no file path), which the hook maps to the file itself; it also accepts
a file path as `$1` for manual scans.

## Configuration

Add hooks to `.claude/settings.json` or `.claude/settings.local.json`. Each entry is an
object with `type` and `command`; the tool call arrives as **JSON on stdin** (see
[Hook input and exit codes](#hook-input-and-exit-codes)), so no arguments are passed:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash hooks/dangerous-cmd-warn.sh" },
          { "type": "command", "command": "bash hooks/enforce-uv.sh" },
          { "type": "command", "command": "bash hooks/pre-commit-lint.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "bash hooks/post-edit-format.sh" }]
      }
    ]
  }
}
```

`tests/hooks.sh` pins the hook contract (stdin in; exit 2 + stderr to block; one
`additionalContext` JSON envelope to advise) and runs in `just check` and CI.

### Prompt-injection hooks (SessionStart + git pre-commit)

These two are wired differently from the `Bash`/`Write|Edit` matchers above.

**SessionStart** — scans the project's instruction files once at boot (silent on clean):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash hooks/session-start-unicode-scan.sh" }] }
    ]
  }
}
```

**git pre-commit** — this is a *git* hook, not a Claude Code hook. Install per repo:

```bash
ln -sf ../../hooks/pre-commit-unicode-scan.sh .git/hooks/pre-commit
# Git Bash's `ln -s` copies unless symlinks are enabled. The copy still finds this
# repo's scanner but keeps the hook code it was copied with; use a wrapper there:
#   printf '#!/bin/sh\nexec bash hooks/pre-commit-unicode-scan.sh\n' > .git/hooks/pre-commit
# already have a pre-commit hook? call it from yours instead:
#   bash hooks/pre-commit-unicode-scan.sh || exit 1
```

Both resolve the scanner relative to themselves, so they work whether claude-mods is
run from the repo or installed under `~/.claude/`. The pre-commit gate blocks on
`critical`, or when a staged instruction file could not be scanned (unreadable blob,
broken scanner) - a gate that could not look does not report clean. Override a single
commit with `PROMPT_INJECTION_ALLOW=1 git commit ...`.

A hook run through a symlink resolves the link first, so it finds the `skills/` beside
its real path, not beside `.git/hooks/`. If the pre-commit gate still finds no scanner,
it says so on every commit and lets the commit through: a broken install is never
silent. The SessionStart hook stays silent then, because it is auto-wired and a setup
without the skill is legitimate.

## Hook Types

| Hook | Trigger | Use Case |
|------|---------|----------|
| `PreToolUse` | Before tool execution | Validate inputs, security checks |
| `PostToolUse` | After tool execution | Run tests, linting, notifications |
| `Notification` | On specific events | Alerts, logging |
| `Stop` | When Claude stops | Cleanup, summaries |

## Examples

### 1. Security Check (PreToolUse)

Detect dangerous patterns before execution:

```bash
#!/bin/bash
# hooks/security-check.sh
# Detects: eval, exec, os.system, pickle, SQL injection patterns

INPUT="$(jq -r '.tool_input.command // .tool_input.content // empty')"

PATTERNS=(
  "eval("
  "exec("
  "os.system("
  "subprocess.call.*shell=True"
  "pickle.loads"
  "__import__"
  "rm -rf /"
  "DROP TABLE"
  "; DROP"
)

for pattern in "${PATTERNS[@]}"; do
  if printf '%s\n' "$INPUT" | grep -qF "$pattern"; then
    # stderr + exit 2 = block, and Claude sees the reason (exit 1 would NOT block)
    echo "SECURITY WARNING: Detected potentially dangerous pattern: $pattern" >&2
    exit 2
  fi
done

exit 0
```

### 2. Auto-Lint (PostToolUse)

Run linter after file edits:

```bash
#!/bin/bash
# hooks/post-edit.sh

FILE="$(jq -r '.tool_input.file_path // empty')"
[[ -f "$FILE" ]] || exit 0
EXT="${FILE##*.}"

case "$EXT" in
  ts|tsx|js|jsx)
    npx eslint --fix "$FILE" 2>/dev/null
    ;;
  py)
    ruff check --fix "$FILE" 2>/dev/null
    ;;
  md)
    # Optional: markdown lint
    ;;
esac
```

### 3. Auto-Test (PostToolUse)

Run tests after code changes:

```bash
#!/bin/bash
# hooks/post-test.sh

FILE="$(jq -r '.tool_input.file_path // empty')"

# Only run for source files
if [[ "$FILE" == *"/src/"* ]]; then
  # Find and run related test
  TEST_FILE="${FILE/src/tests}"
  TEST_FILE="${TEST_FILE/.ts/.test.ts}"

  if [[ -f "$TEST_FILE" ]]; then
    npm test -- "$TEST_FILE" --passWithNoTests
  fi
fi
```

### 4. Commit Message Hook (a *git* hook, not a Claude Code hook)

Ensure commit messages follow convention. Install as `.git/hooks/commit-msg`; git passes
the **path of the message file** as `$1`, not the message itself:

```bash
#!/bin/bash
# .git/hooks/commit-msg

MSG="$(head -n1 "$1")"

# Conventional commits pattern
PATTERN="^(feat|fix|docs|style|refactor|test|chore)(\(.+\))?: .{1,50}"

if ! echo "$MSG" | grep -qE "$PATTERN"; then
  echo "ERROR: Commit message doesn't follow conventional commits format"
  echo "Expected: type(scope): description"
  echo "Example: feat(auth): add login endpoint"
  exit 1
fi
```

## Settings Example

Full hooks configuration:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash hooks/security-check.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "bash hooks/post-edit.sh" },
          { "type": "command", "command": "bash hooks/post-test.sh" }
        ]
      }
    ]
  }
}
```

## Hook input and exit codes

Claude Code passes the tool call to a command hook as **JSON on stdin** — not as shell
variables or arguments. Read it with `jq`:

| Field | Present on | Example |
|-------|-----------|---------|
| `.tool_name` | all tool events | `"Bash"`, `"Edit"` |
| `.tool_input.command` | Bash | `jq -r '.tool_input.command'` |
| `.tool_input.file_path` | Write / Edit | `jq -r '.tool_input.file_path'` |
| `.tool_response` | PostToolUse | the tool's result |

| Exit code | Meaning |
|-----------|---------|
| `0` | Allow / success |
| `2` | **Block** — for PreToolUse the call does not run, and **stderr** is fed back to the model |
| anything else | Non-blocking error — shown to the user, the call proceeds anyway |

A blocking hook must write its reason to **stderr**; stdout is not shown to the model.
Check the hooks reference for the full, current schema:
https://code.claude.com/docs/en/hooks

### Output channels - what actually reaches the model

Plain `echo` on exit 0 is **not** a way to tell the model something. For most events
Claude Code sends that stdout to the debug log; only `UserPromptSubmit`,
`UserPromptExpansion`, `SessionStart` and `PostModelSwitch` add plain stdout to
context. The hooks here use:

| Intent | Channel | Used by |
|--------|---------|---------|
| Advise, don't block (PreToolUse / PostToolUse) | exit 0 + **one** JSON value on stdout: `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}` (capped at 10,000 chars) | `pre-install-scan`, `worktree-guard`, `manifest-dep-scan`, `pre-write-peer-guard`, `check-mail` |
| Block | exit 2 + reason on **stderr** | `dangerous-cmd-warn`, `enforce-uv`, `pre-commit-lint`, and the `*_BLOCK=1` modes |
| SessionStart advisory | plain stdout (delivered for this event) | `session-start-unicode-scan` |
| ConfigChange | no text channel: `systemMessage` is discarded and even a block is silent. Only `terminalSequence` (a desktop notification, interactive sessions only) reaches a person | `config-change-guard` |

Build the envelope with `jq -nc --arg c "$MSG" '...'`, never by string
concatenation, and print nothing else to stdout. `tests/hooks.sh` asserts each
channel; run it with `HOOKS_DIR=<dir>` to point it at another copy of the hooks.

## Best Practices

1. **Keep hooks fast** - They run synchronously and block Claude
2. **Exit 0 for success, 2 to block** - Any other non-zero exit is a non-blocking error; the call proceeds
3. **Pick the channel on purpose** - Plain stdout reaches the model only for a few events; see [Output channels](#output-channels---what-actually-reaches-the-model)
4. **Use matchers** - Only run hooks for relevant tools
5. **Test locally first** - Debug before enabling in Claude

## Security Patterns to Detect

From Anthropic's security-guidance plugin:

| Pattern | Risk |
|---------|------|
| `eval(`, `exec(` | Code injection |
| `os.system(`, `subprocess.call.*shell=True` | Command injection |
| `pickle.loads` | Deserialization attack |
| `__import__` | Dynamic import abuse |
| `innerHTML`, `document.write` | XSS |
| `DROP TABLE`, `; DROP` | SQL injection |
| `rm -rf /` | Destructive commands |
