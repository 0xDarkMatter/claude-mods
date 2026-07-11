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

## 3. Grok workers (`grok -p`)

xAI's **Grok Build CLI** (`grok`, alias `agent`; v0.2.93 verified) — an agentic
coding TUI, a direct Claude Code peer, but a **non-Anthropic** worker: its own
binary and protocol, **not** a `claude -p` wrapper. Verified against
`grok --help` + live headless runs 2026-07-11.

- **Launch** (headless, one turn, prints + exits):
  `grok --prompt-file <f> --output-format json --always-approve --max-turns N
  [-m MODEL] [--reasoning-effort EFFORT] [--json-schema '<SCHEMA-STRING>']`.
  `-p/--single "<prompt>"` is the inline-prompt equivalent of `--prompt-file`.
  ff-spawn runs it from the lane worktree (`cd`), so grok's own `-w/--worktree`
  is deliberately unused — the cage is fleetflow's worktree, one owner per tree.
- **Autonomous tools:** `--always-approve` auto-approves *all* tool executions —
  the codex `--full-auto` analog and a **blast-radius flag**; safe only because
  the lane worktree + escape guard bound it. Granular alternative:
  `--permission-mode dontAsk` + `--allow <RULE>` (mirrors Claude Code
  `--allowedTools`; modes: `default|acceptEdits|auto|dontAsk|bypassPermissions|plan`).
- **Structured output:** `--json-schema '<schema>'` takes the schema as a JSON
  **string** (not a file path), implies `--output-format json`, and surfaces an
  **already-parsed `.structuredOutput`** field — grok validates server-side, so
  ff-collect prefers it over re-parsing `.text`. ff-spawn passes the schema
  out-of-band (like codex's `--output-schema`), not appended to the prompt.
- **Envelope** (`--output-format json`): `{text, stopReason, sessionId,
  requestId, thought, structuredOutput?}` — **no `is_error`**. A clean turn ends
  `stopReason:"EndTurn"`.
- **Output modes** (`--output-format`, verified live 2026-07-11): `plain` (text
  only, the default), `json` (the single buffered envelope above), and
  `streaming-json` — **NDJSON**, one event object per line streamed as it
  generates: `{"type":"thought","data":"…"}` (reasoning tokens),
  `{"type":"text","data":"…"}` (answer tokens), terminated by
  `{"type":"end","stopReason","sessionId","requestId"}`. This is grok's analog of
  `claude -p --output-format stream-json`. **ff-collect gates on the buffered
  `json` envelope** (a whole-turn result is what a lane's success is judged on);
  **`streaming-json` is the live-progress source** — the codex `--json`
  event-stream analog the live monitor consumes. Consumer note: it interleaves
  `thought` and `text`, so filter `type=="text"` for answer-only, and read
  `structuredOutput` off the terminal event (not a `thought`) on `--json-schema`
  lanes.
- **Auth:** the `GROK_DEPLOYMENT_KEY` env var **only** — grok has no
  config/auth/key subcommand to store a deployment key (`~/.grok/auth.json`
  holds OAuth tokens, and OAuth lacked chat entitlement on the test account, so
  the `xai-…` deployment key is the working path). ff-spawn reads it from the
  **inherited environment** — never written to disk, args (`ps`-safe), or logs.
  Config home is `~/.grok/`; **no per-worker config-dir isolation needed** (like
  codex, grok has no Claude OAuth to collide with).
- **Gate** (`ff-collect`): rc was already gated by ff-spawn (a failed grok run
  exits nonzero + writes stderr), so the content gate is **envelope parses AND
  non-empty `.text`** (or `.structuredOutput` for `--schema` lanes). `stopReason`
  is informational — *not* hard-gated, because an agentic tool-turn can end on a
  terminal reason other than `EndTurn`.
- **Models:** `grok models` lists available IDs (test account: `grok-4.5`, the
  default). `-m`/`FLEETFLOW_GROK_MODEL` overrides.
- **Character:** a genuinely different **provider** (xAI), model, *and* harness —
  its highest fleetflow value is **cross-provider dissent** (refuter/judge lanes)
  and independent second implementations, same role codex plays.
- **fleetflow env knobs:** `FLEETFLOW_GROK_BIN` (default `grok`; point at
  `…/grok.exe` when it isn't on PATH), `FLEETFLOW_GROK_MODEL` (model override).
- **Transcript archiving is not wired for grok** (its session store under
  `~/.grok/` isn't a verified path); `ff-spawn`'s archive step skips grok with a
  `transcript source not found … (non-fatal)` note — the lane still passes.
- **Programmatic surface (beyond `-p`)**, for tighter SDK integration than a
  one-shot headless call: `grok agent stdio` (drive over stdio — the SDK path),
  `grok agent headless` (over the Grok WebSocket relay), `grok agent serve`
  (WebSocket server, `--bind` default `127.0.0.1:2419`, `--secret`/
  `GROK_AGENT_SECRET`), `grok agent leader` (one shared backend for multiple
  clients; `--leader`/`--no-leader`, `--leader-socket`). fleetflow uses plain
  headless `grok -p`; the relay/serve/leader modes are for embedding grok as a
  long-lived backend, out of scope for hub-and-spoke lanes.
- **MCP:** `grok mcp add|list|remove|doctor` — grok is an MCP *client* like
  Claude Code, so a lane can be given MCP servers via its `~/.grok` config.
- **Terms:** deployment-key usage bills to your xAI account/plan — verify its
  terms as you would codex's ChatGPT-plan billing.

## 4. Anthropic workers (`claude -p`)

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

## 5. Orchestrator: Fable if available, Opus if not

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

## 6. Uniform result layout

```
<repo>/.fleetflow/<run>/
├── journal.jsonl        # started/result records, v2 content-hash keys (v: FF_VERSION)
├── manifest.json        # orchestrator plan: {run,base,created_by,phases[],packets[]}
├── main-baseline.txt    # main-checkout status snapshot (escape-guard baseline)
├── <id>.prompt.txt      # guard preamble + packet (what was actually sent)
├── <id>.result.json     # claude JSON envelope (glm/anthropic brains) OR
│                        #   grok envelope {text,stopReason,…} (grok brain)
├── <id>.last.txt        # codex last-message (codex brain)
├── <id>.events.jsonl    # codex --json event stream (codex brain)
├── <id>.transcript.jsonl# archived session transcript (claude-brain lanes; best-effort)
├── <id>.invalid.txt     # last failed schema output (only when --repair ran)
├── <id>.err             # stderr
└── wt-<id>/             # the lane worktree (branch fleetflow/<run>/<id>)
```

`.fleetflow/` sits at the repo top (never under `.claude/` — Claude Code's
sensitive-file guard fires there before `bypassPermissions`) and must be
gitignored; `ff-spawn` appends it to `.git/info/exclude` if absent.

## 7. Effort lever, cache redirect, transcript archiving (Wave 1)

**Effort lever** (`ff-spawn --effort low|medium|high|max`). Default unset =
inherit the brain's own. The mapping (effort IS part of the cache-key OPTS
string, so changing only effort is a cache miss):

| Brain | How effort is applied |
|---|---|
| glm (fleet-worker) | `FLEET_WORKER_EFFORT=<v>` in the worker env |
| codex (`codex exec`) | `-c model_reasoning_effort="<v>"` |
| grok (`grok -p`) | `--reasoning-effort <v>` (alias `--effort`) |
| sonnet/opus/haiku/fable | `claude -p --settings '{"effortLevel":"<v>"}'` |

Doctrine (carried from the native tool): reach for the effort lever before the
model lever. Effort is recorded in the manifest packet, so `ff-run resume`
replays each lane at its captured effort.

**Cache & tmp redirect.** Every worker launch exports `UV_CACHE_DIR`,
`TMPDIR`, `TMP`, `TEMP` into the worker env pointing at
`${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}/<run>-<id>/` (created
pre-launch). This keeps uv/pytest cache and codex sandbox litter OUT of the
repo and lanes — the AppContainer-ACL'd dirs codex leaves behind resist
unelevated deletion and would otherwise block `git worktree remove` (the
`sandbox litter gotcha`, §2). Set `FLEETFLOW_CACHE_ROOT` once for the whole run
and pass the same value to `ff-clean` so it can reclaim the dirs.

**Transcript archiving** (best-effort, never fails the lane). After a
non-dry-run claude-brain lane, the session transcript is copied to
`<rundir>/<id>.transcript.jsonl`:

- **glm**: newest `projects/*/*.jsonl` under the worker's isolated config dir
  (`FLEET_WORKER_CONFIG_DIR`, default `$HOME/.fleet-worker/cfg-ff-<id>`).
- **sonnet/opus/haiku/fable**: the result envelope's `session_id` resolves to
  `$HOME/.claude/projects/<encoded-workdir>/<session_id>.jsonl`, where the
  encoding is per-char `[:\\/.]` → `-` (verified empirically: `C:\Users\Mack`
  → `C--Users-Mack`). Falls back to a `<session_id>.jsonl` search across all
  project dirs if the encoded path misses.

If the source transcript can't be found, the lane logs a `transcript source
not found ... skipped (non-fatal)` warning and continues — the transcript is a
convenience for inspection/audit, not a gate.
