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
| `check-mail.sh` | PreToolUse | Deliver unread pigeon pmail, one stat when nothing is new. Delivery is per session (stdin `session_id`): each session is told about each message once and never about mail it sent itself, so a worktree lane's report reaches the coordinator in the main checkout instead of the lane. The shared signal file is a timestamp it never deletes. Inside a worktree the footer warns that a bare `pigeon read` marks the coordinator's mail read too. |
| `config-change-guard.sh` | ConfigChange | Worm-persistence tripwire: when a Claude settings file changes mid-session, scan just that file for the vetted IOC set (curl\|sh, base64-decode eval, Invoke-Expression+Download, /dev/tcp, reads of `.claude/settings` / `.aws/credentials`). Silent on clean; on a finding, a desktop notification (`terminalSequence`, interactive sessions only - ConfigChange discards `systemMessage`, so no text reaches you or the model). `SUPPLY_CHAIN_BLOCK=1` blocks the change (exit 2). Fast single-file sibling of `supply-chain-defense`'s `integrity-audit.sh`. |
| `worktree-guard.sh` | PreToolUse (Bash) | Enforce `rules/worktree-boundaries.md`: flags `rm` on `.claude/worktrees`, `git worktree remove/prune` against worktrees, `git rm` on worktree gitlinks, and `git add -A`/`.` in a repo that has a `.claude/worktrees` dir. With `WORKTREE_ROOT` set, lanes under `$WORKTREE_ROOT` get the same `rm`/`git rm`/`worktree remove`/`prune` guard. Sessions whose cwd is inside their own worktree are exempt. Advisory by default; `WORKTREE_GUARD_BLOCK=1` hard-denies (exit 2). |
| `worktree-create.sh` | WorktreeCreate | Put Claude Code's own worktrees (`--worktree`, `isolation: worktree`, background sessions) at `$WORKTREE_ROOT/<repo>/<name>` instead of `<repo>/.claude/worktrees/`. Replaces Claude Code's git logic: branch `worktree-<name>`, `worktree.baseRef`, reopen by name, `.worktreeinclude`. A cwd outside any git repo gets an empty workspace from Claude Desktop and a failure from the CLI. Opt-in, machine-specific, wired **by absolute path** (Claude Desktop runs it through `cmd.exe`, where `~` and `$HOME` don't expand): see [Worktree placement](#worktree-placement-worktreecreate--worktreeremove). |
| `worktree-remove.sh` | WorktreeRemove | Pair of `worktree-create.sh`: `git worktree remove` without `--force` (a dirty tree is kept, exit 1), then `git branch -d` on its `worktree-*` branch (never `-D`). An empty non-git workspace (Desktop, plain folder) is rmdir'd; any other non-git dir is left in place. |
| `session-start-unicode-scan.sh` | SessionStart | One-shot hidden-Unicode scan of the project's instruction files (CLAUDE.md/AGENTS.md/SKILL.md/.cursorrules) at session boot. Silent on clean; advisory on a finding, and a separate "NOT scanned" advisory naming any file the scanner could not read. Pairs with `prompt-injection-defense`. |
| `pre-write-peer-guard.sh` | PreToolUse (Edit\|Write) | Mid-session peer-writer guard (`rules/worktree-boundaries.md`): before writing a file, warn if it was freshly modified by something that isn't this session — the signature of a live peer session sharing the checkout. Uses the touched-ledger to tell own edits apart. Advisory by default; `GUARD_BLOCK=1` denies the write. Auto-wired with its ledger companion. |
| `session-touched-ledger.sh` | PostToolUse (Edit\|Write) | Companion to `pre-write-peer-guard.sh`: records every file this session writes to `~/.claude/.session-touched/<session_id>.list` so the guard can distinguish this session's edits from a peer's. Silent, never blocks. Auto-wired with the peer guard. |
| `pre-tls-verify-ask.sh` | PreToolUse (Bash\|PowerShell) | Ask before a command turns TLS certificate verification off: `curl -k`/`--insecure`, `wget --no-check-certificate`, `NODE_TLS_REJECT_UNAUTHORIZED=0`, `PYTHONHTTPSVERIFY=0`, `GIT_SSL_NO_VERIFY`, `git -c http.sslVerify=false`, npm/pnpm/yarn `strict-ssl false`, pip/uv `--trusted-host`, Composer `disable-tls`/`secure-http`, PowerShell `-SkipCertificateCheck` and trust-all callbacks. Persistent switches (`git config`, `npm config set`, `pip config set`, `composer config`, `setx`) say they outlive the session. curl, wget and the package managers count only at command position, through a quote- and heredoc-aware lexer, so a commit message or `rg` pattern that quotes `curl -k` stays silent. See [Why the TLS guard asks](#why-the-tls-guard-asks-instead-of-denying). |
| `post-tls-verify-scan.sh` | PostToolUse (Write\|Edit) | Advisory when an edit turns verification off in code or config: Python `verify=False`/`CERT_NONE`, Node `rejectUnauthorized: false`, Guzzle `'verify' => false`, `CURLOPT_SSL_VERIFYPEER` 0, Go `InsecureSkipVerify`, Ruby `VERIFY_NONE`, Rust `danger_accept_invalid_certs`, Java trust-all managers and verifiers, .NET callbacks returning true, and committed `.npmrc`/`.yarnrc.yml`/pip/`composer.json`/`.gitconfig` settings. Skips prose (`.md .mdx .markdown .rst .adoc .txt`). |
| `pre-commit-unicode-scan.sh` | git pre-commit | Refuse commits that ADD hidden Unicode to instruction files. Scans the **staged (index) copy**, not the file on disk, including renamed and non-ASCII-named files. Silent on clean, warn on `high`, **block on `critical`** (tag-block / bidi override) **or on a staged instruction file it could not scan**. Override once with `PROMPT_INJECTION_ALLOW=1`. |
| `tool-loop-guard.sh` | PreToolUse + PostToolUse + PostToolUseFailure (all tools) | Repetition guard, Factory Droid 1.0's loop rule moved into the harness: the 3rd identical tool call in a row (same input **and** same result) gets an `additionalContext` nudge, and the 6th is denied. A poll whose output changes never counts. Per session (and per subagent) state in `~/.claude/.loop-guard/`. Fail-open. Opt-in: see [Tool loop guard](#tool-loop-guard). |

## Auto-wired vs opt-in

`hooks/hooks.json` is the **plugin-level hook config** — when claude-mods is installed
as a plugin, these hooks are active automatically (no settings.json hand-wiring), with
paths resolved via `${CLAUDE_PLUGIN_ROOT}`:

| Set | Hooks | Why |
|-----|-------|-----|
| **Auto-wired (security advisory)** | `pre-install-scan.sh` (PreToolUse Bash), `worktree-guard.sh` (PreToolUse Bash), `pre-tls-verify-ask.sh` (PreToolUse Bash\|PowerShell, asks), `manifest-dep-scan.sh` (PostToolUse Write\|Edit), `post-tls-verify-scan.sh` (PostToolUse Write\|Edit), `session-start-unicode-scan.sh` (SessionStart), `config-change-guard.sh` (ConfigChange), `pre-write-peer-guard.sh` (PreToolUse Write\|Edit), `session-touched-ledger.sh` (PostToolUse Write\|Edit) | Silent-on-clean guardrails: zero noise until something is actually wrong, so they're safe to ship on by default. |
| **Opt-in (opinionated / formatting)** | `pre-commit-lint.sh`, `post-edit-format.sh`, `dangerous-cmd-warn.sh`, `enforce-uv.sh`, `check-mail.sh`, `pre-commit-unicode-scan.sh` (a *git* hook), `worktree-create.sh` + `worktree-remove.sh` (machine-specific; never auto-wired), `tool-loop-guard.sh` (it denies calls, so turning it on is the user's choice) | Workflow opinions — wire them yourself per the examples below. |

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

### Tool loop guard

A model that keeps re-running the same failing command, or re-reading the same file,
spends turns until a person notices. Factory's Droid 1.0 puts the rule in the harness
so every model gets it: three identical tool calls get a nudge, six stop the loop, and
repeats that return new results may continue. Claude Code has no such rule, so
`tool-loop-guard.sh` adds it. Wire all three events to the one script, with no matcher
so it sees every tool:

```json
{
  "hooks": {
    "PreToolUse":         [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tool-loop-guard.sh", "timeout": 10 }] }],
    "PostToolUse":        [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tool-loop-guard.sh", "timeout": 10 }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/tool-loop-guard.sh", "timeout": 10 }] }]
  }
}
```

How it counts:

- **Identical means input and result.** The fingerprint is the tool name plus
  `tool_input` with its keys sorted (Bash's `description` is dropped as prose). The
  result is `tool_response`, or `error` on PostToolUseFailure, which is where a Bash
  command with a non-zero exit lands. Timing keys such as `durationMs` are dropped
  first, or no Glob or WebFetch repeat would ever match.
- **Why the result, not a list of polling tools.** A poll (`gh run view`, a log tail,
  `TaskOutput`) repeats its input by design. While its output changes, it is making
  progress, so a changed result restarts the count at 1. A list of exempt tools would
  need upkeep and would miss `Bash` polls. A poll that returns the same output six
  times running is stuck, and gets denied like anything else.
- **Post counts, Pre denies.** PostToolUse and PostToolUseFailure update the count and
  add the nudge from call 3 on, next to the tool result. The result of call 6 is
  unknown before it runs, so PreToolUse denies it when the previous 5 calls had this
  input and one unchanged result. A denied call has no Post, so retrying it stays
  denied until the model does something else.
- **State is per session, and per subagent within it**:
  `~/.claude/.loop-guard/<session_id>[.<agent_id>].state`, one line. A subagent's calls
  arrive under the parent's `session_id`, interleaved with the parent's, so a shared
  file would break both runs. Files idle for 2 days are pruned when a new session
  starts writing.
- **Fail-open.** No `jq`, no `session_id`, unparsable input or a failed hash: exit 0,
  silent.

| Variable | Default | Effect |
|----------|---------|--------|
| `LOOP_GUARD` | `1` | `0` turns the guard off |
| `LOOP_GUARD_NUDGE` | `3` | Identical call that gets the first nudge (minimum 2) |
| `LOOP_GUARD_DENY` | `6` | Identical call that is denied; `0` nudges only |
| `LOOP_GUARD_EXEMPT` | (empty) | ERE on `tool_name` for tools the guard skips |
| `LOOP_GUARD_DIR` | `~/.claude/.loop-guard` | State directory |

Cost: the hook runs twice per tool call. Pre spawns `jq` and `sha1sum`. Post spawns
those plus `split` and `rm`, so tool output is hashed from temp files and never read
into a shell variable. On Windows that measured about 125 ms for Pre and 185 ms for
Post.

### Why the TLS guard asks instead of denying

Turning certificate verification off to get past a certificate error lets anyone on
the network path impersonate the server and read or change the traffic, credentials
included, and a download or package fetched that way can be swapped in transit. An
agent reaches for `curl -k` or `verify=False` mid-task without saying so, which is the
behaviour `pre-tls-verify-ask.sh` interrupts. It asks rather than denies because a
self-signed certificate on a local development host is the one legitimate case, and
only the person at the keyboard knows whether this is it. The ask costs nothing unless
one of the switches is present. In auto mode the hook's ask still forces the prompt;
under `claude -p` nobody can answer, so Claude Code denies the call and Claude reads the
reason. The code advisory never blocks: the edit has already happened, so it asks
Claude to revert it or to scope it to the local host and say so.

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

### Worktree placement (WorktreeCreate + WorktreeRemove)

Claude Code has no setting for where `claude --worktree`, `isolation: worktree`
subagents and background sessions put their worktrees (`<repo>/.claude/worktrees/<name>`).
A `WorktreeCreate` hook is the only lever, and it **replaces** git's worktree logic
entirely. On a machine whose `settings.json` `env` sets `WORKTREE_ROOT`, this pair moves
those worktrees to `$WORKTREE_ROOT/<repo>/<name>`, the same root `new-lane.sh` and
`fleet init` use (`rules/worktree-boundaries.md` "Lane location"). Wire it in the
**user** settings of that machine only, **by absolute path**:

```json
{
  "env": { "WORKTREE_ROOT": "<absolute path outside every repo>" },
  "hooks": {
    "WorktreeCreate": [
      { "hooks": [{ "type": "command", "command": "bash <your-home>/.claude/hooks/worktree-create.sh" }] }
    ],
    "WorktreeRemove": [
      { "hooks": [{ "type": "command", "command": "bash <your-home>/.claude/hooks/worktree-remove.sh" }] }
    ]
  }
}
```

`<your-home>` is your home directory written out in full, with forward slashes:

| OS | `WorktreeCreate` command |
|----|--------------------------|
| Windows | `bash C:/Users/<you>/.claude/hooks/worktree-create.sh` |
| macOS | `bash /Users/<you>/.claude/hooks/worktree-create.sh` |
| Linux | `bash /home/<you>/.claude/hooks/worktree-create.sh` |

`WorktreeRemove` is the same with `worktree-remove.sh`.

**Never `~` or `$HOME` in these two commands.** Claude Desktop runs WorktreeCreate and
WorktreeRemove itself, not through Claude Code, and on Windows it hands the command to
`cmd.exe /d /s /c` (read from its app bundle, builds 2.26454 and 2.31226). cmd.exe
expands neither `~` nor `$HOME`, so with `bash ~/.claude/...` or
`bash "$HOME/.claude/..."` bash looks for a file literally named that, the hook exits
127, and Desktop aborts every worktree session and chip on the machine (its `main.log`
says `worktree_hook_failed, aborting session`). The CLI runs hook commands through Git
Bash or `sh`, so the `~` form works there and hides the break until Desktop starts a
session. An absolute path works in both. To reproduce, run
`cmd /d /s /c 'bash "$HOME/.claude/hooks/worktree-create.sh"'` from PowerShell: exit 127.

**Desktop doesn't pass the settings `env` block either.** It starts the hook with its own
environment (`PATH`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PROJECT_DIR`), so
`WORKTREE_ROOT` set in `settings.json` never reaches the hook as a variable. When the
variable is missing, the hook reads `env.WORKTREE_ROOT` from
`${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` itself, so keep the root in the user
settings file above. A real environment variable wins, including one set in the command
(`bash -c "WORKTREE_ROOT=<root> exec bash <your-home>/.claude/hooks/worktree-create.sh"`),
but neither is needed. Before this fallback, Desktop's worktrees silently landed in
`<repo>/.claude/worktrees/`.

**A folder that is not a git repository has nothing to isolate**, and Desktop still
calls the hook for it (`no repository anchor` in its log). Desktop aborts the session if
the hook fails, and refuses the folder itself as the result (`hook printed the base
repository path ...; it must create a separate workspace`). So for Desktop the hook
makes an **empty** workspace at `$WORKTREE_ROOT/_no-repo/<folder>/<name>` and the
session works on the folder by absolute path, unisolated. `_no-repo/` keeps it out of
the lane scans (`fleet sweep`, `worktree-survey.sh`) that walk `$WORKTREE_ROOT/<repo>/`.
`worktree-remove.sh` rmdirs it while it is still empty and leaves it otherwise. The hook
tells Desktop's calls apart by their `"transcript_path": ""`. For the CLI the hook fails
instead, and Claude Code then runs a background session in the folder itself, its
documented fallback. An empty dir would strand that session, and any
`isolation: worktree` subagent, away from the files.

**Two calls for one name can arrive at once.** When the source folder fails Claude
Code's trust check (it was never opened and trusted as a project), Desktop retries the
start within the same second, so its log shows two `Creating worktree for session ...`
lines. Two CLI sessions asking for the same `--worktree` name race the same way.
Unserialised, both runs `git worktree add` one branch and the loser exits 1, which fails
that start. The hook takes a per-name lock in the git common dir, so the second call
waits and reopens the first call's worktree. The lock doesn't fix an untrusted folder:
open the folder once in Claude Code and accept the trust prompt.

Trade-offs, stated plainly:

- **No automatic sweep.** Claude Code's periodic cleanup keeps any worktree without its
  own git marker, so hook-made worktrees stay until removed. `WorktreeRemove` covers a
  session you exit or delete; everything else is `fleet sweep` / `fleet prune`, which
  see these trees (`git worktree list`) and say "hook-made" on them.
- **A broken hook blocks every worktree creation on the machine.** Claude Code has no
  fallback: any non-zero exit, or no path on stdout, fails creation, and Claude Desktop
  then aborts the session. Needs `jq` and `git`. With `WORKTREE_ROOT` unset the hook
  falls back to Claude Code's own location rather than fail, but still loses the sweep,
  so install it only where the root is set.
- **A fresh base can cost up to 5 s.** Like Claude Code, the hook fetches the default
  branch when `FETCH_HEAD` is missing or over 24 h old, capped at 5 s and never
  prompting. On a private HTTPS remote that can't authenticate silently, the session
  start waits out the cap, then uses the cached `origin/HEAD`.
- **The hook owns what Claude Code did.** It copies `.worktreeinclude` matches, reads
  `worktree.baseRef` (or `WORKTREE_BASE_REF`), names branches `worktree-<name>` and
  reopens a worktree by name, at its old tip (Claude Code's reset of an untouched
  worktree to the default branch is not emulated). `WorktreeRemove` never forces:
  a tree with changed or untracked files is kept and the removal reports failure.

`tests/hooks.sh` pins both contracts against throwaway repos.

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
| Advise, don't block (PreToolUse / PostToolUse) | exit 0 + **one** JSON value on stdout: `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}` (capped at 10,000 chars) | `pre-install-scan`, `worktree-guard`, `manifest-dep-scan`, `post-tls-verify-scan`, `pre-write-peer-guard`, `check-mail`, `tool-loop-guard` (PostToolUse and PostToolUseFailure) |
| Deny with a reason (PreToolUse) | exit 0 + one JSON value: `permissionDecision: "deny"`, `permissionDecisionReason` (fed to the model) | `tool-loop-guard`, `pre-write-peer-guard` with `GUARD_BLOCK=1` |
| Ask the user (PreToolUse) | exit 0 + one JSON value: `permissionDecision: "ask"`, `permissionDecisionReason` (shown to the user in the prompt) and `additionalContext` (for the model) | `pre-tls-verify-ask` |
| Block | exit 2 + reason on **stderr** | `dangerous-cmd-warn`, `enforce-uv`, `pre-commit-lint`, and the `*_BLOCK=1` modes |
| SessionStart advisory | plain stdout (delivered for this event) | `session-start-unicode-scan` |
| ConfigChange | no text channel: `systemMessage` is discarded and even a block is silent. Only `terminalSequence` (a desktop notification, interactive sessions only) reaches a person | `config-change-guard` |

Build the envelope with `jq -nc --arg c "$MSG" '...'`, never by string
concatenation, and print nothing else to stdout. `tests/hooks.sh` asserts each
channel; run it with `HOOKS_DIR=<dir>` to point it at another copy of the hooks.

### Hook start cost

A PreToolUse hook that runs past its `timeout` is cancelled and **the tool call goes
ahead unchecked**: a guard that times out fails open. On Windows (Git Bash/MSYS) every
process a hook starts (`bash`, `jq`, `git`, `grep`, `sed`) costs about 110-130 ms on an
idle machine and seconds under load. One week on a busy workstation (2026-11, about 30
sessions) logged 25,299 cancelled PreToolUse hooks, recorded at a median of 7-18 s against
limits of 5-10 s. `worktree-guard` alone started about 25 processes on every Bash call.

So the hooks that run on most calls exit before their first fork when they can:

- Read stdin with `IFS= read -r -d '' RAW || true` (a builtin), not `RAW=$(cat)`.
- Pre-filter in pure bash: `[[ "$RAW" =~ $RE_PRE ]] || exit 0`, the regex in a variable.
  `worktree-guard` needs `worktree`, `clean`, `add` or the last part of `$WORKTREE_ROOT`;
  `pre-install-scan` needs `install`, `add`, `composer` or `npm i`. **Keep each pre-filter
  a superset of the checks after it**: a new check adds its word, or it silently never runs.
- `check-mail` caches the project hash per directory, so its fast path is one process.

Measured on the same machine at about 30% CPU, per call on a command that is not a
match: `worktree-guard` 1.1-2.1 s -> 0.12-0.14 s, `pre-install-scan` 0.9-1.2 s ->
0.11-0.12 s, `check-mail` 0.25-0.45 s -> 0.11-0.15 s.

If you wire these with settings.json `if` rules instead, note that on a command Claude
Code cannot parse (`$(...)`, heredocs, loops) **every** rule fires, so one hook behind
five rules runs five times at once. With the pre-filter, one unfiltered entry is cheaper.
The guards that must not fail open (`worktree-guard`, `pre-tls-verify-ask`,
`pre-write-peer-guard`) get a 30 s timeout in `hooks.json`.

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
