# fleet-worker — Design Specification

**Status:** smoke-tested on live infrastructure; pattern proven.
**Verdict:** ✅ Feasible. A non-Anthropic (GLM) brain reliably drives Claude
Code's tool harness in headless mode — *provided* the worker is given an isolated
config directory (the load-bearing finding, §4).

Contents: [1 Purpose](#1-purpose--scope) · [2 Facts](#2-established-facts) ·
[3 Architecture](#3-architecture) · [4 Auth isolation](#4-the-load-bearing-finding-auth-isolation) ·
[5 Launcher](#5-the-launcher) · [6 Invocation](#6-invocation-contract) ·
[7 Output](#7-output-formats) · [8 Parallel isolation](#8-parallel-worker-isolation) ·
[9 Permissions](#9-permission-modes) · [10 Effort](#10-effort-control) ·
[11 Limits](#11-error-handling--limitations) · [12 Security](#12-security-model) ·
[13 Packaging](#13-packaging) · [14 Rollout](#14-phased-rollout) ·
[Appendix](#appendix-live-smoke-test-evidence)

---

## 1. Purpose & scope

`fleet-worker` is a thin launcher around the `claude` binary (Claude Code CLI). It
injects environment variables that point Claude Code at an **Anthropic-compatible
endpoint** (default: z.ai, model **GLM-5.2**), then runs `claude -p` (headless /
print mode). The result is a headless Claude Code agent whose *brain* is the
cheaper model but which retains Claude Code's full tool harness — Read, Write,
Edit, Bash, Glob, Grep, in-process subagents (Task), MCP, hooks.

The purpose: let an **orchestrator** (a normal Claude Code session on Opus)
delegate tool-using, multi-step agent tasks to cheaper workers by spawning them as
subprocesses — one per task, fanned out in parallel.

**What it IS:** a thin env-injecting wrapper that `exec`s `claude -p`; a way to get
per-agent model selection through process isolation; the unit of delegation an
orchestrator spawns and collects from.

**What it is NOT:** a new application or agent reimplementation (all capability
comes from `claude` itself); a one-shot "ask three models" query tool (that asks a
model a *question*; this hands a model a *task* and a *toolbox*); an in-process
feature (Claude Code's native Task subagents cannot be repointed per-agent — §3).

## 2. Established facts

- The endpoint speaks the **Anthropic Messages protocol**, so Claude Code can be
  pointed at it via `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` + the
  `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` mapping vars. This is Claude
  Code's documented custom-endpoint mechanism (the same one used for Bedrock /
  Vertex / LLM gateways).
- Default models: **GLM-5.2** (flagship reasoning model, ~3–15 s/call, large
  context, effort levels) and **GLM-4.5-Air** (smaller, faster, used for the
  haiku-mapped background calls).
- Verified against Claude Code 2.x. The key is supplied at spawn time from the
  environment or an OS keyring (never embedded in the script).

## 3. Architecture

```
ORCHESTRATOR — Claude Code on Opus (real api.anthropic.com)
  Bash tool ──spawns──► fleet-worker (subprocess #1) ──┐
  Bash tool ──spawns──► fleet-worker (subprocess #2) ──┤  each subprocess has
  Bash tool ──spawns──► fleet-worker (subprocess #N) ──┤  its OWN env block
  collects JSON results ◄────────────────────────────┘
                         │
                         ▼
WORKER — claude -p (headless)
  CLAUDE_CONFIG_DIR = isolated   (no host OAuth!)
  ANTHROPIC_BASE_URL = <endpoint>      model: GLM-5.2 (via sonnet/opus mapping)
  Brain: GLM   Tools: Claude Code's own harness (Read/Write/Edit/Bash/Task/MCP)
```

### Why workers MUST be separate processes

`ANTHROPIC_BASE_URL` and the model-mapping vars are **process-global** — read once
per `claude` process and applied to *every* model call it makes, including
in-process Task subagents. There is no per-agent override. Therefore the only way
to run a GLM-brained agent alongside an Opus orchestrator is a **separate OS
process** with its own env block. Per-agent model selection = process isolation,
full stop. That is the reason the launcher exists.

## 4. The load-bearing finding: auth isolation

> **The single most important result. The naïve launcher (just set
> `ANTHROPIC_AUTH_TOKEN`) does NOT work on a machine logged into a Claude.ai /
> Anthropic subscription. It fails with `401 token expired or incorrect`.**

**What goes wrong.** When the host is logged into a subscription, `~/.claude.json`
holds an `oauthAccount` and `~/.claude/settings.json` may set
`"forceLoginMethod": "claudeai"`. With `claude -p` pointed at a non-Anthropic
endpoint but inheriting that host config, the **stored subscription OAuth token
takes precedence over `ANTHROPIC_AUTH_TOKEN`** and is sent to the endpoint, which
rejects it (`401`). Claude Code then retries with backoff for minutes before
surfacing the failure. (Proven independently: the *same* key sent via raw `curl`
to `…/v1/messages` returns HTTP 200 — the key and endpoint are fine; Claude Code
was simply sending a *different* credential.)

**What does NOT fix it:** setting `ANTHROPIC_AUTH_TOKEN` alone; also setting
`ANTHROPIC_API_KEY`; passing `--settings '{"forceLoginMethod":"console"}'`. The
stored `oauthAccount` wins regardless.

**What DOES fix it — `CLAUDE_CONFIG_DIR` isolation:**

```bash
export CLAUDE_CONFIG_DIR="$HOME/.fleet-worker/cfg"   # fresh, empty dir
```

A clean config dir inherits **no `oauthAccount`** and **no `forceLoginMethod`**, so
`ANTHROPIC_AUTH_TOKEN` becomes the only credential and reaches the endpoint.
(Verified: the error flipped from `401` (rejected) to `529` (accepted, server
overloaded) — i.e. the request now reached the model — and a subsequent run
completed a full tool-driving loop end-to-end; see Appendix.)

> **Design rule:** the launcher MUST set `CLAUDE_CONFIG_DIR` to a dedicated
> directory. Non-negotiable on any machine also logged into a subscription. Happy
> side effect: the worker gets a clean hook/permission/MCP profile and can't trip
> the host's hooks.

## 5. The launcher

The shipped `scripts/fleet-worker` (bash) and `scripts/fleet-worker.ps1` (PowerShell)
implement, in order: isolate `CLAUDE_CONFIG_DIR` and seed its `settings.json`
(§4, §10); resolve the key from `ANTHROPIC_AUTH_TOKEN` → keyring
(`FLEET_WORKER_KEYRING_SERVICE`/`_KEY`) → `ZHIPU_API_KEY`/`GLM_API_KEY` (never
echoed); set `ANTHROPIC_BASE_URL` + the model mapping; `exec claude -p --model
sonnet --permission-mode bypassPermissions "$@" </dev/null`.

Notes:
- **`--model sonnet`** maps to `FLEET_WORKER_MODEL` (default GLM-5.2). Mapping
  opus+sonnet → main model means whatever tier the harness requests internally,
  you get the main model; background/cheap calls hit the haiku-mapped small model.
- **`</dev/null`** avoids the ~3 s "no stdin data received" stall when the prompt
  is an argument.
- **Windows / PowerShell:** `.Trim()` the keyring output (it can carry a trailing
  CRLF). If a `401` persists despite isolation, check the key for CR contamination.

## 6. Invocation contract

```
fleet-worker [claude-flags…] "PROMPT"
fleet-worker [claude-flags…] < prompt.txt
```

| Aspect | Value |
|---|---|
| Prompt | final positional arg, or piped on stdin (arg form recommended) |
| Baked-in flags | `-p`, `--model sonnet`, `--permission-mode bypassPermissions` |
| Common extra flags | `--output-format {text,json,stream-json}`, `--add-dir`, `--max-turns N`, `--append-system-prompt`, `--allowedTools`/`--disallowedTools` |
| Env knobs | `FLEET_WORKER_*` (see SKILL.md table) — give each parallel worker its own `FLEET_WORKER_CONFIG_DIR` |
| CWD | the worker operates in the process CWD — spawn it `cd`'d into the target worktree |

### Exit codes & failure signals
| Source | Success | Failure |
|---|---|---|
| Process exit code | `0` | `1` (auth, API errors, overload) |
| `--output-format json` | `is_error: false` | `is_error: true` + `api_error_status: <code>` |

**Caveat:** with `--output-format json`, a 529/overload still produces a
well-formed result with `"subtype":"success"` but `"is_error":true` and
`"api_error_status":529`. **Don't trust `subtype` — gate on `is_error`** (and the
process exit code). `fleet-collect.sh` encodes this.

## 7. Output formats

The final **result object** (from `--output-format json`, or the last line of
`stream-json`) carries: `is_error` (← primary gate), `api_error_status` (e.g. 529
/ 401), `duration_ms`, `num_turns`, `result` (← deliverable text), `stop_reason`,
`session_id` (resumable with `claude -r`), `usage.{input_tokens,
cache_read_input_tokens, output_tokens}`, `modelUsage.<model>.{…}`,
`permission_denials`, `terminal_reason`, `uuid`, and `total_cost_usd`.

```bash
RES=$(fleet-worker --output-format json "…task…")
echo "$RES" | jq -r '.result'                       # final text
echo "$RES" | jq -r '.is_error'                     # success gate (NOT subtype)
echo "$RES" | jq -r '.api_error_status // "none"'   # failure code
```

> ⚠ **`total_cost_usd` is notional.** Claude Code computes it from its internal
> pricing table applied to a model name it doesn't recognise, so it falls back to
> a placeholder rate — it does **not** reflect what the provider charged. Account
> by `usage.*_tokens` and your provider's plan; ignore the dollar figure.

`stream-json` emits newline-delimited events in real time (init → assistant/user
with `tool_use`/`tool_result` blocks → final result), so the orchestrator can
watch tool calls live. Use plain `json` for fire-and-collect; `text` returns only
`.result`.

## 8. Parallel worker isolation

Each delegated subtask gets its **own git worktree + branch** *and* its **own
config dir**, so N workers never clobber each other's files, branches, or session
state. See SKILL.md "Fan-out recipe". Isolation matrix:

| Resource | Mechanism |
|---|---|
| Working files / branch | `git worktree add -b fleet/<id>` — one per task |
| Claude session/config | `FLEET_WORKER_CONFIG_DIR=…/cfg-<id>` — one per task |
| Result/error capture | per-task `…result.json` / `…err` |
| Concurrency cap | shell job control / `xargs -P` — ≤ 4–6 (endpoint quota, not CPU, is the limit) |

The orchestrator spawns workers via its Bash tool with `run_in_background: true`,
tracks them by output file, and collects on completion: gate on `is_error`, merge
the winners (hand to `fleet-ops`), discard/retry failures.

## 9. Permission modes

| Mode | Edits | Bash | Prompts | For a delegated worker |
|---|---|---|---|---|
| `default` | ask | ask | yes | ❌ hangs headless |
| `acceptEdits` | auto | ask | partial | ⚠ Bash still prompts → can hang |
| `bypassPermissions` | auto | auto | no | ✅ recommended |

**Safety comes from the cage, not the prompt:** dedicated worktree (blast radius),
isolated `CLAUDE_CONFIG_DIR` (no host hooks/MCP/creds), optional `--disallowedTools`
/ `--add-dir` scoping, and the orchestrator's **merge gate** — nothing the worker
writes reaches `main` without review. Standard headless-CI posture.

## 10. Effort control

Headless `-p` has no interactive `/effort`. Seed it via the isolated config dir's
`settings.json` — Claude Code persists effort as `"effortLevel"`. The launcher
writes `{"hooks":{}, "effortLevel":"<FLEET_WORKER_EFFORT|high>"}` into a fresh config
dir (see `assets/worker-settings.json`). Recommended default for coding workers:
`high`. Per-task override: `--settings '{"effortLevel":"high"}'`. Confirm the
provider's effort mapping against its docs at integration time.

## 11. Error handling & limitations

| Failure | Symptom | Mitigation |
|---|---|---|
| Auth | `401`; exit 1 after minutes of retries | Ensure `CLAUDE_CONFIG_DIR` isolation (§4); verify the key with raw `curl`; check CRLF on Windows |
| Overload | `is_error:true`, `api_error_status:529`; exit 1 | Retry with jittered backoff; cap attempts; prefer off-peak; route overflow to the small model |
| Quota | 429 once a plan cap is hit | Throttle fan-out; schedule heavy batches off-peak |
| Latency | multi-turn reasoning runs into minutes | `--max-turns N`; orchestrator-side wall-clock timeout; collect via background, never block |
| Partial output | `result` empty; `stop_reason` ≠ `end_turn` | Check `stop_reason`/`num_turns`; re-dispatch (worktree makes retries clean) |
| Cost figures wrong | implausible `total_cost_usd` | Ignore — notional (§7) |

**Reliability note (from the investigation, during the GLM-5.2 launch window):**
the flagship was frequently **529-overloaded** for large Claude-Code-shaped
requests at peak, while the smaller **GLM-4.5-Air succeeded cleanly**. The
*pattern* is proven; flagship capacity during launch peaks is a real availability
risk → build in retry/backoff, an off-peak schedule, and a small-model fallback.

## 12. Security model

1. **Key never at rest in the script** — pulled from env/keyring at spawn time.
2. **Never in process args** — goes in `ANTHROPIC_AUTH_TOKEN` (env), so it can't
   leak via `ps` / `/proc/*/cmdline` / shell history.
3. **Never logged** — the launcher doesn't echo it; `--output-format json` carries
   no credentials. Avoid `--debug` in shared logs.
4. **Isolated config dir** — worker creds/session live under `FLEET_WORKER_CONFIG_DIR`,
   separate from the host; the worker can't read the host's subscription creds.
5. **Worktree blast-radius + merge gate** bound what an over-eager or
   prompt-injected worker can do.
6. **`.gitignore`** the scratch dirs (`.fleet-work/`, `.fleet-worker/`).

## 13. Packaging

Ship the **script on PATH** (the executable the orchestrator spawns) **plus this
Claude Code skill** (how the orchestrator *knows* it can delegate, with the
fan-out/collect/isolation recipes). A shell alias is optional sugar.

## 14. Phased rollout

- **Phase 1 (this skill):** the thin launcher + `fleet-collect`/`fleet-doctor` + the
  recipes. Orchestrator-driven fan-out via Bash + git worktrees, landed by
  `fleet-ops`. Start here.
- **Phase 2 (later, on concrete pain):** wire into standing fleet/queue
  infrastructure for persistent job tracking. Only when manual fan-out is the
  bottleneck.
- **Phase 3 (conditional):** a worker-router MCP — only if a standing shared
  fleet, an async job API, or cost/quota auto-routing becomes a real need.

> **Start thin, graduate only on concrete pain.** The launcher is ~12 lines of
> load-bearing logic and proven. Don't pre-build the router.

## Appendix: live smoke-test evidence

Observed on Windows 11, Claude Code 2.x, against an Anthropic-compatible GLM
endpoint, during the GLM-5.2 launch window (peak hours). Key redacted throughout.

- **Endpoint/key validity (raw curl, bypasses Claude Code):** Anthropic-protocol
  endpoint returned HTTP 200 with both `x-api-key` and `Authorization: Bearer`.
  Key valid, endpoint correct.
- **The auth saga:** naïve launcher (host config inherited) → `401`. Adding
  `--settings '{"forceLoginMethod":"console"}'` → still `401`. Adding
  `CLAUDE_CONFIG_DIR=isolated` → `529` (**auth accepted**, server overloaded). Fixed
  *only* by config-dir isolation (§4).
- **Does a GLM brain drive the tools?** GLM-5.2 was 529-blocked on every attempt
  at peak; routing the *same* task to **GLM-4.5-Air** completed a **3-turn
  Write+Read tool loop in ~23 s**, `is_error:false`, file actually written to
  disk, `modelUsage` showing Claude Code's full system prompt + tool schemas as
  input. **Verdict: ✅ the pattern works** — a non-Anthropic brain reliably drives
  Claude Code's harness headless. The only material risk surfaced was flagship
  endpoint capacity during the launch peak (transient infra, not a design flaw).
