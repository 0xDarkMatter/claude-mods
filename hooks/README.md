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
| `config-change-guard.sh` | ConfigChange | Worm-persistence tripwire: when a Claude settings file changes mid-session, scan just that file for the vetted IOC set (curl\|sh, base64-decode eval, Invoke-Expression+Download, /dev/tcp, reads of `.claude/settings` / `.aws/credentials`). Silent on clean; advisory `systemMessage` on a finding. `SUPPLY_CHAIN_BLOCK=1` blocks the change (exit 2). Fast single-file sibling of `supply-chain-defense`'s `integrity-audit.sh`. |
| `worktree-guard.sh` | PreToolUse (Bash) | Enforce `rules/worktree-boundaries.md`: flags `rm` on `.claude/worktrees`, `git worktree remove/prune` against worktrees, `git rm` on worktree gitlinks, and `git add -A`/`.` in a repo that has a `.claude/worktrees` dir. Sessions whose cwd is inside their own worktree are exempt. Advisory by default; `WORKTREE_GUARD_BLOCK=1` hard-denies (exit 2). |
| `session-start-unicode-scan.sh` | SessionStart | One-shot hidden-Unicode scan of the project's instruction files (CLAUDE.md/AGENTS.md/SKILL.md/.cursorrules) at session boot. Silent on clean; advisory on a finding. Pairs with `prompt-injection-defense`. |
| `pre-commit-unicode-scan.sh` | git pre-commit | Refuse commits that ADD hidden Unicode to instruction files. Silent on clean, warn on `high`, **block on `critical`** (tag-block / bidi override). Override once with `PROMPT_INJECTION_ALLOW=1`. |

## Auto-wired vs opt-in

`hooks/hooks.json` is the **plugin-level hook config** — when claude-mods is installed
as a plugin, these hooks are active automatically (no settings.json hand-wiring), with
paths resolved via `${CLAUDE_PLUGIN_ROOT}`:

| Set | Hooks | Why |
|-----|-------|-----|
| **Auto-wired (security advisory)** | `pre-install-scan.sh` (PreToolUse Bash), `worktree-guard.sh` (PreToolUse Bash), `manifest-dep-scan.sh` (PostToolUse Write\|Edit), `session-start-unicode-scan.sh` (SessionStart), `config-change-guard.sh` (ConfigChange) | Silent-on-clean guardrails: zero noise until something is actually wrong, so they're safe to ship on by default. |
| **Opt-in (opinionated / formatting)** | `pre-commit-lint.sh`, `post-edit-format.sh`, `dangerous-cmd-warn.sh`, `enforce-uv.sh`, `check-mail.sh`, `pre-commit-unicode-scan.sh` (a *git* hook) | Workflow opinions — wire them yourself per the examples below. |

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

Add hooks to `.claude/settings.json` or `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          "bash hooks/dangerous-cmd-warn.sh $TOOL_INPUT",
          "bash hooks/enforce-uv.sh $TOOL_INPUT",
          "bash hooks/pre-commit-lint.sh $TOOL_INPUT"
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": ["bash hooks/post-edit-format.sh $FILE_PATH"]
      }
    ]
  }
}
```

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
# already have a pre-commit hook? call it from yours instead:
#   bash hooks/pre-commit-unicode-scan.sh || exit 1
```

Both resolve the scanner relative to themselves, so they work whether claude-mods is
run from the repo or installed under `~/.claude/`. Blocks only on `critical`; override
a single commit with `PROMPT_INJECTION_ALLOW=1 git commit ...`.

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

INPUT="$1"

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
  if echo "$INPUT" | grep -q "$pattern"; then
    echo "SECURITY WARNING: Detected potentially dangerous pattern: $pattern"
    exit 1
  fi
done

exit 0
```

### 2. Auto-Lint (PostToolUse)

Run linter after file edits:

```bash
#!/bin/bash
# hooks/post-edit.sh

FILE="$1"
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

FILE="$1"

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

### 4. Commit Message Hook

Ensure commit messages follow convention:

```bash
#!/bin/bash
# hooks/commit-msg.sh

MSG="$1"

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
        "hooks": ["bash hooks/security-check.sh $TOOL_INPUT"]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          "bash hooks/post-edit.sh $FILE_PATH",
          "bash hooks/post-test.sh $FILE_PATH"
        ]
      }
    ]
  }
}
```

## Variables Available

| Variable | Description |
|----------|-------------|
| `$TOOL_INPUT` | Full input to the tool |
| `$TOOL_OUTPUT` | Output from tool (PostToolUse only) |
| `$FILE_PATH` | Path to file being modified |
| `$TOOL_NAME` | Name of tool being called |

## Best Practices

1. **Keep hooks fast** - They run synchronously and block Claude
2. **Exit 0 for success** - Non-zero exits halt execution
3. **Log sparingly** - Output goes to Claude's context
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
