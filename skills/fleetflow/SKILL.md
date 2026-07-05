---
name: fleetflow
description: "Orchestrate a heterogeneous worker fleet — GLM (z.ai), Codex (OpenAI), and Anthropic Sonnet/Opus/Haiku — from one Claude session, porting the native Workflow tool's proven patterns (phases, pipeline-vs-barrier, adversarial verify, judge panels, hash-keyed journal resume) to OS-process workers that can run DIFFERENT provider brains. Triggers on: fleetflow, heterogeneous fleet, mixed-model fleet, codex worker, orchestrate glm and codex, cross-provider fan-out, multi-provider workers, workflow across providers, codex second opinion, fable orchestrator, mixed fleet, cross-model verify."
when_to_use: "Use when a fan-out wants DIFFERENT brains per work class — e.g. 'fan this backlog out to GLM and Codex workers', 'mixed fleet with cross-model adversarial verify', 'Codex second opinion on each lane'. Same-provider in-process fan-out → native Workflow tool; one cheap worker → fleet-worker; landing branches → fleet-ops."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep Task"
metadata:
  author: claude-mods
  depends-on: "fleet-worker, fleet-ops"
  related-skills: "loop-ops, iterate, claude-code-ops"
---

# fleetflow

> Facts verified as of 2026-07 (Claude Code Workflow tool, codex-cli 0.125, fleet-worker GLM-5.2/z.ai).

Claude Code's native **Workflow tool** is a superb orchestration harness with one
structural limit: every agent it spawns runs **in-process**, so they all share one
provider (`ANTHROPIC_BASE_URL` is process-global — only the model *alias slot*
varies per agent). fleetflow ports the Workflow tool's patterns to **OS-process
workers**, where each worker gets its own env block — and therefore its own brain:

| Worker brain | Process | Harness |
|---|---|---|
| **GLM-5.2 / GLM-4.5-Air** | `claude -p` → z.ai endpoint | Claude Code tools, cheap brain (via `fleet-worker`) |
| **Codex** (GPT-class) | `codex exec` | OpenAI's own agent harness — a genuinely different toolchain *and* model |
| **Sonnet / Haiku** | `claude -p --model sonnet\|haiku` | Claude Code tools, host auth |
| **Opus** | `claude -p --model opus` | reserve for verify/judge lanes |

The **orchestrator is this session** — run it on **Fable if the account has it,
Opus otherwise** (`ff-doctor --live` probes and reports which). Judgment stays in
the orchestrator; the scripts own the deterministic mechanics (spawn, journal,
gate). That split *is* the Workflow tool's design, relocated: its JS script is
deterministic control flow around model judgment — here the orchestrator session
plays the script's role and the journal keeps it resumable.

## Decision gate — is fleetflow the right tool?

| Situation | Use |
|---|---|
| Fan-out where all agents can share the session's provider | **native Workflow tool** (cheaper, integrated progress UI, schema-forced outputs) |
| One-off cheap delegation, single worker | **fleet-worker** directly |
| Worker brains should differ by work class, or you want cross-provider dissent in verification | **fleetflow** |
| Landing the resulting branches | **fleet-ops** (always) |

Rule of thumb from fleet-worker's locus rule, extended: shell out to process
workers only for a **large, independent, file-mutating, cost-dominant** fan-out
you can gate before landing — *or* when the point is **model diversity** (a
Codex refuter catches what three same-model skeptics miss).

## Model routing (work class × brain)

Extends [fleet-worker's routing convention](../fleet-worker/references/model-routing.md)
with the Codex column and the orchestrator rule:

| Work class | Brain | Why |
|---|---|---|
| **mechanical** (batch edits, verifier clones, backfills) | GLM-5.2, Haiku | proven cheap; gate catches misses |
| **scout** (survey, inventory, locate) | Sonnet, GLM-5.2 | breadth over depth |
| **build** (scoped features, refactors) | Sonnet, Codex | Codex = independent harness; good second implementation for judge panels |
| **verify / judge** | Opus + one cross-provider dissenter (Codex or GLM) | *never under-power a judge*; diversity beats redundancy |
| **synthesize / land decisions** | orchestrator (Fable > Opus) | needs the conversation's context |

Two guardrails carried over verbatim from the native tool's doctrine: reach for
the **effort lever before the model lever**, and a cheap rubber-stamp verifier is
worse than none.

## The run lifecycle

```
plan packets → ff-doctor → ff-spawn (×N, background) → ff-collect (gate) → fleet-ops land → clean up
```

1. **Plan packets that are file-disjoint.** No two lanes may touch the same file
   — this is what makes landing conflict-free and is the #1 planning duty.
   Pipeline-by-default thinking applies: add a barrier (wait for all lanes)
   only when a later stage genuinely needs *all* prior results
   (dedup, early-exit, cross-lane comparison). See
   [references/native-workflow-insights.md](references/native-workflow-insights.md) §3.
2. **Preflight:** `scripts/ff-doctor.sh --live` — probes every provider (GLM
   endpoint, `codex login status`, Anthropic model availability incl. Fable) and
   reports the orchestrator tier. Don't spawn a fleet a doctor won't bless.
3. **Spawn:** `scripts/ff-spawn.sh --run <name> --id <id> --brain <brain>
   --prompt-file <f> --worktree` from the orchestrator's Bash tool with
   `run_in_background: true`, one call per lane. ff-spawn creates the worktree
   lane (`fleetflow/<run>/<id>` at `.fleetflow/<run>/wt-<id>`, repo top — never
   under `.claude/`), injects the guard preamble
   ([assets/guard-preamble.txt](assets/guard-preamble.txt)), journals a
   `started` record, runs the worker to completion, journals the `result`.
4. **Collect + gate:** `scripts/ff-collect.sh <run> <id>` — per-brain success
   semantics (Claude JSON `is_error`; Codex exit + last-message), then the
   orchestrator reviews the three-dot diff (`git diff main...fleetflow/<run>/<id>`)
   and runs the lane's tests. **Always finish with
   `ff-collect.sh --check-main-clean`** — the escape guard (see Safety).
5. **Land** through fleet-ops (sequential, test-gated). Delete lanes and
   `.fleetflow/<run>/` after landing.

**Inter-worker communication is hub-and-spoke, by design.** Workers never talk
to each other — no shared memory, no message bus, no sideband files (lanes are
isolated worktrees). The only channel is the native tool's: a worker's FINAL
REPLY returns through `ff-collect` to the orchestrator, which embeds it in a
later packet (the `prevResult`-into-next-prompt handoff; see
[insights §3/§7](references/native-workflow-insights.md)). A judge packet is
just the collected builder outputs pasted in. If a stage needs *all* sibling
results, that is a barrier — collect everything first, then compose. (True
peer-to-peer between long-lived workers is out of scope; that's what a message
bus like pigeon is for.)

**Clean-room / benchmark runs get their own target repo.** Lanes are worktrees
*of some repo* — don't graft a build experiment onto an unrelated repo's object
store. Seed a standalone repo (e.g. under `X:\Benching`), and **vendor any
external spec INTO it** (`spec/…`) so packets reference it by *relative* path —
the guard preamble forbids workers building absolute paths, and Codex's
sandbox is confined to the lane, so out-of-repo specs are unreadable anyway.

**Resume.** The journal (`.fleetflow/<run>/journal.jsonl`) uses the native
tool's mechanism: each spawn is keyed by a content hash of
`(brain, prompt, opts)` — and `opts` includes `--effort`, so changing only the
effort lever is a cache miss (a different run). Re-running `ff-spawn` with an
unchanged packet returns the cached result instantly (exit 3 + path); change
the prompt and only that lane re-runs. Corollary (same reason the native tool
bans `Date.now()`): keep timestamps and random values OUT of packet prompts, or
the key changes and the cache never hits.

**Manifest & resume.** Each spawn also upserts a packet into
`.fleetflow/<run>/manifest.json` (`{run, base, created_by, phases[], packets[]}`,
one entry per id — idempotent — carrying `{id, brain, phase, prompt_file,
worktree, max_turns, effort, schema, key}`). It is the orchestrator-side plan,
distinct from the per-spawn journal: it records *what was intended* so a whole
run can be replayed. `ff-run.sh resume --run NAME` snapshots the manifest's
packets once, then replays each through `ff-spawn` in manifest order — unchanged
packets cache-hit (`"cached"`), changed or new ones run live; per-lane summary
to stderr, a JSON result list on stdout, exit 0 if all ok/cached, 10 if any
lane failed. `ff-run status --run NAME` is an alias for `ff-status`. Snapshots
matter: ff-spawn re-orders the live manifest on each upsert (remove-then-append),
so the replay reads from a frozen copy. When you're done,
`ff-clean.sh --run NAME [--force]` reclaims zero-commit lanes (worktree + branch
deleted), keeps committed ones, and removes the run's cache dirs.

**Cache & tmp redirect.** Workers' `UV_CACHE_DIR`, `TMPDIR`, `TMP`, and `TEMP`
are pointed at `${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}/<run>-<id>/`
(created before launch), so pytest/uv litter and codex's AppContainer-ACL'd
sandbox dirs land OUTSIDE the repo and lanes — never inside a worktree that
`git worktree remove` later needs to delete. Set `FLEETFLOW_CACHE_ROOT` once for
the whole run and pass the same value to `ff-clean` so it can find and remove
those dirs.

## Patterns ported from the native Workflow tool

Full extraction with evidence in
[references/native-workflow-insights.md](references/native-workflow-insights.md).
The ones to actually use:

- **Adversarial verify:** for each finding/lane output, spawn 2–3 refuters
  prompted to *refute*, majority kills. Make one refuter a different provider.
- **Judge panel:** N independent build attempts (e.g. Sonnet vs Codex), judged
  by Opus lanes, synthesize from the winner.
- **Loop-until-dry:** for unknown-size discovery, keep spawning finder lanes
  until 2 consecutive rounds add nothing new. Dedup against everything *seen*,
  not everything *confirmed*.
- **Completeness critic:** one final lane asking "what's missing?" — its answer
  is the next round's packet list.
- **No silent caps:** if you bound coverage (top-N, sampling), say so in the
  run summary. Silent truncation reads as "covered everything".
- **Workers return data, not prose:** every packet ends with "FINAL REPLY:
  <exact shape>". For machine-parseable results use `--schema` (Codex
  `--output-schema` is native; Claude workers get the schema embedded in the
  prompt and validated at collect time).

## Default posture: verify by default, scale to the ask

The native tool's fan-outs look "automatic" because its doctrine makes them the
default the script-author follows, not an option — and real runs routinely hit
30–50 agents on large tasks. fleetflow adopts the same posture:

- **Every run gets a verify phase unless you state why not.** Minimum: one
  refuter per build lane (cross-provider) + a judge for anything with more
  than one candidate. A run that skips verification is the exception and says
  so in its summary.
- **Scale the fan-out to the ask, not to caution.** Mechanical batch → one
  lane per file-disjoint packet, however many that is. Discovery/audit →
  loop-until-dry rounds, not a fixed small N. Verification typically adds
  0.5–1.5× the build-lane count on top. 20–50 lanes on a big task is the
  pattern working, not a smell — the native tool budgets 1000 agent calls per
  run for exactly this reason.
- **Throttle in waves, don't shrink the plan.** The native engine queues past
  `min(16, cores−2)` concurrent; fleetflow's orchestrator does the same
  manually — spawn in waves of ≤4–6 per provider (endpoint quota binds first),
  collect as lanes finish, keep the total plan intact. Bound each lane
  (`--max-turns`), never the ambition.
- **No silent caps** (native rule, verbatim): if you sample, top-N, or skip,
  say so in the run summary.

## Safety — the cage, not the model

- **Isolation:** every mutating worker gets its own worktree lane *and* (GLM)
  its own `CLAUDE_CONFIG_DIR`. Codex workers run `--full-auto` (sandboxed,
  workspace-write) confined to their lane via `-C`.
- **Escape guard (learned 2026-07-05, incident):** a worker CAN escape its
  worktree by writing absolute paths — a GLM worker once wrote its output into
  the main checkout while its own lane stayed clean. Two mechanical defenses,
  both defaults: the guard preamble's *relative-paths-only* clause, and
  `ff-collect.sh --check-main-clean` after every run (exit 12 = escape
  detected; stop, `git stash push -u` to salvage, investigate).
- **Permission posture:** workers run non-interactive
  (`bypassPermissions` default; `FLEETFLOW_PERMISSION_MODE=dontAsk` + allowlist
  when the orchestrator session is in auto mode — a `bypassPermissions` child
  is hard-denied there as *Create Unsafe Agents*). Same doctrine as
  fleet-worker; see its Permission posture section.
- **Bounds:** `--max-turns` per worker (default 100), concurrency ≤ 4–6 per
  provider (endpoint quota is the binding constraint), wall-clock patience via
  the orchestrator's background-task notifications — never poll-sleep.
- **Terms:** a subscription-authed orchestrator must stay interactive;
  API-key-authed sessions may be automated. Codex usage bills to the ChatGPT
  plan. Verify your own plans' terms (fleet-worker "Know your terms" applies).

## Scripts

| Script | Purpose |
|---|---|
| [scripts/ff-doctor.sh](scripts/ff-doctor.sh) | `--offline` structural preflight; `--live` probes GLM endpoint, Codex auth, Anthropic models, reports orchestrator tier (fable/opus) |
| [scripts/ff-spawn.sh](scripts/ff-spawn.sh) | uniform spawner: worktree lane + guard preamble + journal + per-brain launch (GLM via fleet-worker, Codex via `codex exec`, Anthropic via `claude -p`) |
| [scripts/ff-collect.sh](scripts/ff-collect.sh) | per-brain result gate; strips ```json fences before `--schema` validation; `--repair` respawns a `<id>-repair` lane on validation failure; `--check-main-clean` escape guard |
| [scripts/ff-status.sh](scripts/ff-status.sh) | run status as JSON (lane state, elapsed, commits, tools, tokens, activity, manifest summary); `--watch N --out status.json` feeds the live monitor |
| [scripts/ff-run.sh](scripts/ff-run.sh) | `resume --run NAME` replays every manifest packet through ff-spawn in order (unchanged = cached, changed/new = live); `status --run NAME` aliases ff-status |
| [scripts/ff-clean.sh](scripts/ff-clean.sh) | `--run NAME [--force]` reclaims zero-commit lanes (worktree remove + branch -D), keeps committed lanes, removes the run's cache dirs; reports locked ACL-litter dirs |
| [scripts/ff-import.sh](scripts/ff-import.sh) | `--wf DIR --run NAME` imports a native Claude Code Workflow run dir (`wf_*/`) — completed agents become lanes (prompt + result envelope + journal + manifest), started-only agents are flagged incomplete; native keys are terminal, not replayable |

**Live monitor** ([assets/ff-monitor.html](assets/ff-monitor.html)): a
zero-dependency page reproducing the native /workflows progress surface — run
header with square per-lane pips, a mono/technical agent grid, elapsed/tools/
commits/tokens, and expandable per-agent detail (activity, last commit, error
tail, artifact). Wire-up: copy it into the run dir as `index.html`, run
`ff-status --watch 3 --out <rundir>/status.json`, serve the run dir with any
static server, open in a browser/preview panel. It polls `status.json` every
2.5s. Live claude-brain lanes are introspected via the session transcript in
their isolated config dir; codex lanes via their `--json` event stream.

**Two surfaces, like the native tool.** The served monitor is the *live*
grid (the Background-tasks panel analogue). In-chat, the orchestrator emits a
compact *snapshot* card at phase boundaries (spawn, phase change, all-done) —
chat-widget sandboxes cannot poll localhost, so the inline card is a
moment-in-time render by design, re-emitted rather than self-updating.

All follow the Skill Resource Protocol: stdout is data, chatter on stderr,
semantic exit codes (`0` ok, `2` usage, `3` cached/missing, `7` unreachable,
`10` worker failed, `12` escape detected), `--help` with EXAMPLES.

## Importing a native Workflow run

`ff-import --wf <wf_*/> --run <name>` reads a native Claude Code Workflow run
directory — its `journal.jsonl` (`started`/`result` records with `v2:` hash
keys and `agentId`) plus per-agent `agent-<id>.jsonl` transcripts — and lands
each completed agent as a fleetflow lane: the agent's first user-role message
(string content or content-array-with-text-blocks, both handled) becomes
`<id>.prompt.txt`, its native `result` object becomes `<id>.result.json`
(`{is_error:false, result:<native-result>|tojson}`), and a `native`-brain
packet is appended to the manifest (`imported_from: <DIR>`) for provenance.
Agents with a `started` but no `result` get a prompt file only and are
reported `incomplete` on stdout's TSV — respawn candidates.

**Caveat — imported results are terminal facts, not a replayable cache.** The
native `v2:` keys are content hashes of the *native* `(prompt, opts)` call, not
fleetflow's `sha256(brain+prompt+opts)`, and `native` is not a spawnable brain
— so `ff-run resume` **skips** native packets rather than replaying them (it
reports each `imported` and exits 0). The native script's control flow
(pipeline/barrier/loop) is not recovered either. To continue from an imported
result, spawn a fresh lane with a real brain and paste the imported result into
its packet (the hub-and-spoke handoff). Use import for salvage, provenance, and
visual continuity in the monitor — not to resume native work in place.

## References

- [references/native-workflow-insights.md](references/native-workflow-insights.md)
  — the extraction: journal format on disk, resume semantics, control-flow
  doctrine, quality patterns, caps and budget spine, with evidence.
- [references/worker-contracts.md](references/worker-contracts.md) — per-brain
  launch/collect/auth contracts (GLM env knobs, full `codex exec` flag map,
  Anthropic alias notes) and the Fable/Opus orchestrator probe.

## See Also

- [fleet-worker](../fleet-worker/) — the single-worker spawn layer fleetflow builds on (GLM auth isolation, model routing, terms).
- [fleet-ops](../fleet-ops/) — the landing layer; every fleetflow run ends there.
- [loop-ops](../loop-ops/) — schedule a recurring fleetflow run as an L1/L2 loop.
