# Worker Contracts — per-brain launch, gate, and auth

> Verified against installed binaries 2026-07-05: `codex-cli 0.125.0`,
> Claude Code v2.1.x, fleet-worker (GLM-5.2 via z.ai). Re-verify flag maps on
> major version bumps (`ff-doctor --offline` checks the load-bearing ones).

## 1. GLM workers (via fleet-worker)

The [fleet-worker](../../fleet-worker/SKILL.md) launcher is the contract —
fleetflow does not duplicate it. Load-bearing facts:

- **Auth isolation is mandatory**: on a machine with a Claude subscription,
  each worker needs its own empty `CLAUDE_CONFIG_DIR` or the host OAuth token
  is sent to z.ai and rejected (`401`). One config dir **per parallel worker**:
  `FLEET_WORKER_CONFIG_DIR=$HOME/.fleet-worker/cfg-ff-<id>`.
- Key resolution: `ANTHROPIC_AUTH_TOKEN` → keyring
  (`FLEET_WORKER_KEYRING_SERVICE`/`KEY`) → `ZHIPU_API_KEY`/`GLM_API_KEY`.
- Launch: `fleet-worker --output-format json --max-turns N "PROMPT" > result.json`
- **Gate**: `is_error` in the result JSON is the real success signal
  (`subtype` lies); `fleet-collect.sh` implements it and `ff-collect` defers
  to the same check.
- Models: `FLEET_WORKER_MODEL` (default GLM-5.2), `FLEET_WORKER_SMALL_MODEL`
  (GLM-4.5-Air). The isolated config starts with **no skills** — provision any
  the packet needs into `<config>/skills/` or the lane's `.claude/skills/`.

## 2. Codex workers (`codex exec`)

OpenAI's agent harness, non-interactive. Flag map (codex-cli 0.125.0):

| Flag | Use |
|---|---|
| `[PROMPT]` or stdin | prompt as arg, or piped (`-` explicit); piped stdin appends as a `<stdin>` block |
| `-m, --model <MODEL>` | model override; omit to use the user's `config.toml` default |
| `--full-auto` | sandboxed automatic execution (workspace-write) — the fleetflow default |
| `-s, --sandbox <read-only\|workspace-write\|danger-full-access>` | explicit sandbox policy; prefer over `--dangerously-bypass-approvals-and-sandbox` (only for externally-sandboxed environments) |
| `-C, --cd <DIR>` | working root — **point at the lane worktree**; this is the confinement |
| `--add-dir <DIR>` | extra writable dirs (rarely needed; widens the cage) |
| `-o, --output-last-message <FILE>` | final message → file; **the primary result artifact** |
| `--output-schema <FILE>` | JSON Schema for the final response — native structured output |
| `--json` | JSONL event stream on stdout (the transcript analogue; capture to `<id>.events.jsonl`) |
| `--ephemeral` | don't persist session files — good fleet hygiene |
| `--skip-git-repo-check` | only if the workdir isn't a git repo (lanes are, so unneeded) |
| `codex exec resume <id> \| --last` | continue a previous run — the resume analogue |
| `codex exec review` | built-in repo code-review mode — useful as a judge lane |

- **Auth**: ChatGPT-plan login (`codex login status` → "Logged in using
  ChatGPT"). Usage bills to that plan. No per-worker config isolation needed —
  Codex has no Claude OAuth to collide with; `--ephemeral` keeps runs clean.
- **Gate**: exit code 0 **and** non-empty last-message file. With
  `--output-schema`, additionally `jq empty < last-message` (valid JSON) and a
  spot-check of required keys at collect time.
- **Character**: a genuinely different model *and* toolchain — its highest
  value in fleetflow is dissent (refuter/judge lanes) and independent second
  implementations, not bulk mechanical work (GLM is cheaper there).
- **Worktree-lane commit gotcha** (observed 2026-07-05): a git worktree's
  metadata (index, refs) lives in the MAIN repo's `.git/` — outside the codex
  sandbox's writable root — so `git commit` inside a lane fails with
  `index.lock: Permission denied` under `--full-auto`. `ff-spawn` fixes this
  by passing `--add-dir <absolute-git-dir>` for codex worktree lanes; if you
  launch codex by hand, add it yourself (or use a full clone as the lane).
- **Sandbox litter gotcha** (observed 2026-07-05): codex's sandbox creates
  pytest temp/cache dirs (`.pytest-tmp/`, `pytest-cache-files-*/`) with
  AppContainer ACLs that survive the run and resist unelevated deletion —
  even `takeown` + `icacls /reset` fail. Consequences: `git worktree remove`
  leaves a husk, and moving the repo needs a copy-around (`robocopy /XD`).
  Mitigations: have codex packets run pytest with `-p no:cacheprovider` and a
  tmp dir inside the lane, or plan on one elevated `Remove-Item` at cleanup.
- **Skill-loading quirk** (observed 2026-07-05): codex reads Claude-format
  skills from `~/.agents/skills/` at session start and rejects any whose
  description exceeds **1024 chars** (`failed to load skill … exceeds maximum
  length`) — non-fatal (logged to stderr, run continues), so don't gate on a
  clean stderr; `ff-collect` correctly ignores it. Keep skill descriptions
  ≤1024 chars if you want codex workers to load them.

## 3. Anthropic workers (`claude -p`)

- Launch: `claude -p --model <sonnet|haiku|opus> --output-format json
  --max-turns N --permission-mode <mode> "PROMPT" > result.json` from the lane
  worktree. Aliases resolve to current models; pin a full ID only when
  reproducibility across weeks matters.
- **Uses the host config/auth deliberately** (unlike GLM workers): host skills
  and MCP are available to the worker. If you want a clean-room Anthropic
  worker, set an isolated `CLAUDE_CONFIG_DIR` + `ANTHROPIC_API_KEY` — then
  provision skills like a GLM worker.
- **Gate**: same `is_error` JSON semantics as GLM (both are `claude -p`).
- **Terms note** (from fleet-worker): automating a *subscription* is
  restricted by Anthropic's Consumer Terms except via API key. A
  subscription-authed orchestrator stays interactive; if a scheduler drives
  fleetflow runs, put the workers (or the whole run) on an API key.

## 4. Orchestrator: Fable if available, Opus if not

The orchestrator is the session invoking this skill — its model is chosen when
the session starts (`/model`, or the `model` field in settings), not by a
per-call override. Doctrine:

1. **Fable** (`claude-fable-5`) when the account has it — strongest judgment
   for packet planning, diff review, and synthesis.
2. **Opus** otherwise.

`ff-doctor --live` probes availability with a 1-turn `claude -p "reply: ok"
--model claude-fable-5 --max-turns 1` call and prints
`orchestrator	fable|opus` so a wrapper (or the user) can set the session model
accordingly. Never route the orchestrator to GLM/Codex — synthesis and judging
stay on the strongest available brain (the native tool's "never under-power a
judge", applied to yourself).

## 5. Uniform result layout

```
<repo>/.fleetflow/<run>/
├── journal.jsonl        # started/result records, v2 content-hash keys
├── <id>.prompt.txt      # guard preamble + packet (what was actually sent)
├── <id>.result.json     # claude JSON envelope (glm/anthropic brains)
├── <id>.last.txt        # codex last-message (codex brain)
├── <id>.events.jsonl    # codex --json event stream (codex brain)
├── <id>.err             # stderr
└── wt-<id>/             # the lane worktree (branch fleetflow/<run>/<id>)
```

`.fleetflow/` sits at the repo top (never under `.claude/` — Claude Code's
sensitive-file guard fires there before `bypassPermissions`) and must be
gitignored; `ff-spawn` appends it to `.git/info/exclude` if absent.
