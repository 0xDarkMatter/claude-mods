---
name: fleet-worker
description: "Delegate tool-using, multi-step agent tasks to a cheaper headless Claude Code worker on a cheaper model — Anthropic Sonnet/Haiku or a non-Anthropic endpoint (GLM via z.ai by default) — a 'grunt worker' an Opus orchestrator fans out in parallel and verifies. Each worker is a real `claude -p` carrying Claude Code's full tool harness (Read/Write/Edit/Bash/Glob/Grep/Task) but a cheaper brain, isolated in its own git worktree + CLAUDE_CONFIG_DIR. Pairs with fleet-ops for test-gated landing. Triggers on: fleet-worker, delegate to GLM, spin up a GLM worker, cheap parallel agent, grunt worker, offload to glm, headless GLM, z.ai worker, GLM-5.2 worker, sonnet worker, haiku worker, cheap coding agent, fan out workers, non-Anthropic model in Claude Code, ANTHROPIC_BASE_URL worker."
when_to_use: "Use when you have independent, well-scoped, tool-using subtasks (refactors, test-writing, doc edits, mechanical multi-file changes) that don't need Opus-level judgment, and you want them done cheaply in parallel while the orchestrator reviews and gates the results before they land. Not for tasks needing the orchestrator's conversation context or expensive-if-wrong unreviewed changes."
license: MIT
allowed-tools: "Read Bash Glob Grep AskUserQuestion"
metadata:
  author: claude-mods
  status: beta
  related-skills: fleet-ops, git-ops, push-gate, claude-code-ops
---

# fleet-worker

Run a **cheap headless Claude Code worker on a cheaper model** and let an
Opus orchestrator (this session) fan workers out in parallel, then verify and
land their work. The worker keeps Claude Code's *entire tool harness*
(Read/Write/Edit/Bash/Glob/Grep/Task/MCP/hooks) — only the **brain** is swapped
to a cheaper model via env — a cheaper Anthropic model (Sonnet/Haiku) or a
non-Anthropic endpoint. GLM-5.2 on z.ai is the default worked example; the
mechanism is provider- and model-agnostic (any Anthropic-compatible endpoint).

**This is the spawning layer. [`fleet-ops`](../fleet-ops/) is the landing layer.**
fleet-worker produces branches cheaply; fleet-ops lands them through a test gate
with your review. See [references/fleet-ops-handoff.md](references/fleet-ops-handoff.md).

## The architecture crux: per-agent model = process isolation

`ANTHROPIC_BASE_URL` and the `ANTHROPIC_DEFAULT_*_MODEL` mapping vars are
**process-global** — read once per `claude` process, applied to *every* model
call it makes (including in-process Task subagents). There is no per-agent
override. So you **cannot** keep one Opus session and have its subagents secretly
run on GLM. The only way to pair a GLM-brained agent with an Opus orchestrator is
a **separate OS process** with its own env block. That process is `fleet-worker`.

## The load-bearing rule: auth isolation (do not skip)

On any machine also logged into a Claude.ai/Anthropic subscription, the naïve
"just set `ANTHROPIC_AUTH_TOKEN`" launcher **fails with `401 token expired or
incorrect`** — the host's stored subscription OAuth token (`~/.claude.json`
`oauthAccount` + `forceLoginMethod`) takes precedence and gets sent to the
non-Anthropic endpoint, which rejects it. `--settings` overrides do **not** fix
it. The fix is a dedicated, empty config dir:

```bash
export CLAUDE_CONFIG_DIR="$HOME/.fleet-worker/cfg"   # no inherited OAuth/hooks
```

The launcher sets this automatically. It also gives each worker a clean
hook/permission/MCP profile so it can't trip the host's hooks. Full analysis in
[references/fleet-worker-spec.md](references/fleet-worker-spec.md) §4.

## Giving a worker skills

The isolated config dir starts **clean** — the worker inherits none of the host's
skills, MCP servers, or hooks (that isolation is what keeps it off your
credentials). So *provision* what a worker should have: drop skill dirs into the
worker's own config (`$FLEET_WORKER_CONFIG_DIR/skills/<name>/`) or commit them to
the project's `.claude/skills/` in the worktree. The cheap brain then loads the
same on-demand, progressively-disclosed procedural knowledge your orchestrator has
— often the cheapest way to lift a weak model's output on a specialized task.

## Setup

1. **Install** — these scripts ship with the skill. After `scripts/install.sh`
   they live at `~/.claude/skills/fleet-worker/scripts/`. Either call them by that
   path, or symlink onto PATH for convenience:
   ```bash
   ln -s ~/.claude/skills/fleet-worker/scripts/fleet-worker ~/.local/bin/fleet-worker
   ln -s ~/.claude/skills/fleet-worker/scripts/fleet-collect.sh ~/.local/bin/fleet-collect.sh
   ```
2. **Provide the key** (the launcher never prints it; resolution order):
   - `export ANTHROPIC_AUTH_TOKEN=<key>`, or
   - `export FLEET_WORKER_KEYRING_SERVICE=<svc> FLEET_WORKER_KEYRING_KEY=<name>` (uses `keyring get`), or
   - `export ZHIPU_API_KEY=<key>` (or `GLM_API_KEY`).
3. **Preflight** — `bash scripts/fleet-doctor.sh --offline` (structural) or
   `--live` (pings the endpoint; warns about the §4 oauth trap).

### Config knobs (env, all optional)

| Var | Default | Purpose |
|---|---|---|
| `FLEET_WORKER_BASE_URL` | `https://api.z.ai/api/anthropic` | Anthropic-compatible endpoint |
| `FLEET_WORKER_MODEL` | `GLM-5.2` | main model (opus+sonnet mapping) |
| `FLEET_WORKER_SMALL_MODEL` | `GLM-4.5-Air` | background/cheap model (haiku mapping) |
| `FLEET_WORKER_CONFIG_DIR` | `~/.fleet-worker/cfg` | isolated config dir — **one per parallel worker** |
| `FLEET_WORKER_EFFORT` | `high` | seeded `effortLevel` in the worker's settings |

Point `FLEET_WORKER_BASE_URL`/`FLEET_WORKER_MODEL` at any other Anthropic-compatible
gateway (this is the documented Claude Code custom-endpoint mechanism) to drive a
different cheap model.

**Staying all-Anthropic?** The same separate-process trick runs a cheaper *Claude*
model as the worker — an Opus orchestrator with Sonnet/Haiku workers, no third-party
account. Point `FLEET_WORKER_BASE_URL` at Anthropic's API and set `FLEET_WORKER_MODEL`/
`FLEET_WORKER_SMALL_MODEL` to a Claude model, authenticating with an Anthropic API key.
The defaults target z.ai/GLM only because that's the cheapest brain; the mechanism
doesn't care which model answers.

## When to delegate (and when not)

| Delegate to a worker | Keep on the orchestrator |
|---|---|
| Independent, well-scoped, tool-using subtasks | Tasks needing this conversation's context |
| Refactors, test-writing, doc edits, mechanical multi-file changes | Judgment calls, architecture, ambiguous specs |
| Work where Opus-quality isn't required and a wrong edit is cheap to discard | Anything expensive-if-wrong and unreviewed |

The safety comes from the **cage, not the model**: isolated worktree (blast
radius), isolated config dir (no host creds/hooks), and the orchestrator's
merge gate (nothing lands without review).

## Single-worker recipe

```bash
cd <target-worktree>
fleet-worker --output-format json "Refactor src/parser.py to use the visitor pattern" \
  > result.json
fleet-collect.sh result.json && echo "succeeded — review the diff"
```

`fleet-collect.sh` gates on `is_error` (the real success signal — `subtype` lies)
and prints the worker's final text. Exit `0` = success, `10` = worker failed.

## Fan-out recipe (parallel workers)

Each task gets its **own git worktree + branch** *and* its **own config dir** so
N workers never clobber each other. Spawn from the orchestrator's Bash tool with
`run_in_background: true`, then collect by output file.

```bash
delegate() {                     # $1 = task-id, $2 = prompt
  local id="$1" prompt="$2" wt=".fleet-work/$1"
  git worktree add -q -b "fleet/$id" "$wt" HEAD
  ( cd "$wt"
    FLEET_WORKER_CONFIG_DIR="$HOME/.fleet-worker/cfg-$id" \
      fleet-worker --output-format json "$prompt" > "../$id.result.json" 2> "../$id.err"
  )
}
delegate task-a "Add tests for the auth module"      &
delegate task-b "Update the README install section"  &
delegate task-c "Refactor utils.py duplications"     &
wait                                                  # barrier

for id in task-a task-b task-c; do
  if fleet-collect.sh ".fleet-work/$id.result.json" >/dev/null; then echo "fleet/$id OK"; fi
done
```

Keep concurrency modest (≤ 4–6) — the binding constraint is endpoint quota, not
local CPU. `.gitignore` the scratch dirs (`.fleet-work/`, `.fleet-worker/`).

## Hand off to fleet-ops (test-gated landing)

The winning branches are ordinary git branches — land them with the sibling skill
instead of merging by hand:

```bash
fleet track fleet/task-a fleet/task-b fleet/task-c   # register as lanes
fleet land  fleet/task-a                          # sequential, test-gated, you review each diff
```

Full walkthrough + recovery in [references/fleet-ops-handoff.md](references/fleet-ops-handoff.md).

## Permission posture

Headless `-p` can't answer a permission prompt — it would stall. The launcher
bakes in `--permission-mode bypassPermissions`; safety comes from the cage
(worktree + isolated config + merge gate), not the prompt. Optionally constrain
with `--disallowedTools` (e.g. block `WebFetch`) or `--add-dir` scoping.

> **Worktree-under-`.claude/` gotcha:** Claude Code's sensitive-file guard runs
> *before* `bypassPermissions` for anything under `.claude/`. Keep manual worker
> worktrees at the repo top (e.g. `.fleet-work/`), not under `.claude/`.

## Reliability & limits

- **Overload (429/529)** is the real-world risk, worst during the model's
  launch-window peak hours. Retry with jittered backoff, cap attempts, prefer
  off-peak, and consider routing overflow to `FLEET_WORKER_SMALL_MODEL`.
- **Bound the loop:** set `--max-turns N` and an orchestrator-side wall-clock
  timeout per worker. Collect via background + notification; never block.
- **Cost figures are notional:** `total_cost_usd` is Claude Code's internal
  pricing table applied to a model it doesn't know — ignore it; account by
  `usage.*_tokens` and your provider's plan.
- Re-dispatch is clean (the worktree makes retries idempotent).

## Security

Key pulled at spawn time into a process-local env var, never written to the
script, args (`ps`-safe), or logs. Isolated config dir keeps worker creds/session
separate from the host — and the worker can't read the host's subscription
credentials. Avoid `--debug` in shared logs (may print headers).

## Know your terms (read before publishing or automating)

Using Claude Code with a custom `ANTHROPIC_BASE_URL` is a **documented** feature,
and a non-Anthropic worker's inference never touches Anthropic's API/subscription. But terms
change and vary by plan — verify both your **Anthropic** terms and your **model
provider's** terms for your own use. Two specifics worth knowing:

- **Automated subscription access:** Anthropic's Consumer Terms restrict driving a
  Claude.ai/Pro/Max **subscription** by "automated or non-human means … except
  when accessing via an Anthropic API Key." Keep the orchestrator **interactive**,
  or run it on an **API key** if you automate it. (A non-Anthropic worker isn't
  reached by this clause; an Anthropic-model worker driven by an **API key** lands
  in the API-key exemption.)
- This skill is a tool, not legal advice. When in doubt, ask your provider.

## Scripts

- `scripts/fleet-worker` / `scripts/fleet-worker.ps1` — the launcher (bash + PowerShell).
  `fleet-worker --help` for the full env/flag contract.
- `scripts/fleet-collect.sh` — gate a `--output-format json` result; exit 0 success /
  10 worker-failed; prints the final text. `fleet-collect.sh --help`.
- `scripts/fleet-doctor.sh` — `--offline` structural preflight + doc-consistency
  (CI-safe); `--live` pings the endpoint to confirm the model still resolves and
  flags the §4 oauth trap. `fleet-doctor.sh --help`.

## References & assets

- [references/fleet-worker-spec.md](references/fleet-worker-spec.md) — full design spec:
  the architecture, the §4 auth-isolation finding, output-format schema, effort
  control, the reliability evidence, and the phased-rollout stance.
- [references/fleet-ops-handoff.md](references/fleet-ops-handoff.md) — fan-out →
  collect → `fleet track` → `fleet land` walkthrough and recovery.
- [assets/worker-settings.json](assets/worker-settings.json) — the seed
  `settings.json` the launcher drops into a fresh config dir (`effortLevel: high`).
