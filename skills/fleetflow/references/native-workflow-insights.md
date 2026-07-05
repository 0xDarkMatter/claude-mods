# Native Workflow Tool — Inner Workings & Extracted Patterns

> Evidence base, compiled 2026-07-05: (a) the Workflow tool's published tool-spec
> (Claude Code v2.1.x session surface), (b) on-disk inspection of real completed
> runs under `~/.claude/projects/<encoded-cwd>/<session>/subagents/workflows/wf_*/`
> (GlyphWeb + Simulacra sessions, July 2026). Where a claim comes only from disk
> inspection it is marked **[disk]**; spec-sourced claims are **[spec]**.
> Internal formats may change between Claude Code releases — re-verify on major
> version bumps.

## 1. Run anatomy on disk [disk]

A workflow run is a directory `wf_<8hex>-<3hex>/` under the owning session's
transcript dir, containing:

```
wf_21db8d15-782/
├── journal.jsonl                    # the replay journal (see §2)
├── agent-a01cb5f01fadf5610.jsonl    # full transcript per agent (one file each)
├── agent-a01cb5f01fadf5610.meta.json# {"agentType":"workflow-subagent","spawnDepth":1}
└── ...                              # (script text persists separately in the session dir)
```

- Agent IDs are 17-hex tokens prefixed `a`.
- `meta.json` is minimal: agent type + spawn depth (nesting is capped at one
  level [spec] — `workflow()` inside a child throws).
- The workflow *script* is persisted under the session directory (the tool
  result returns its path) so it can be edited and re-invoked via `scriptPath`.

## 2. The journal: hash-keyed replay [disk+spec]

`journal.jsonl` holds exactly two record shapes:

```json
{"type":"started","key":"v2:<sha256>","agentId":"a02ba44d2c2c1ed9c"}
{"type":"result","key":"v2:<sha256>","agentId":"...","result":{ ...structured object... }}
```

Key facts:

- **The key is a content hash of the agent call** — `(prompt, opts)` under a
  `v2:` version prefix. Resume works by replaying the script and answering each
  `agent()` call from the journal when its key matches: "the longest unchanged
  prefix of agent() calls returns cached results instantly" [spec]. Same script
  + same args → 100% cache hit.
- **Results are stored as structured objects inline** — when the agent was
  called with a `schema`, the validated JSON object itself is journaled (a real
  example held `{"green":true,"failures":[],"notes":"...","ideas":[...]}`).
  Validation happens at the tool-call layer so the model retries on mismatch
  [spec]. The worker never "formats a report"; it emits data.
- **This is why determinism is enforced:** `Date.now()`, `Math.random()`, and
  argless `new Date()` *throw* inside workflow scripts [spec] — any
  nondeterminism in prompt construction would change the hash and break replay.
  Timestamps go in via `args`; randomness via index-varied prompts.

**fleetflow port:** `ff-spawn` journals the same two record shapes into
`.fleetflow/<run>/journal.jsonl`, keyed `v2:sha256(brain + "\n" + prompt + "\n" + opts)`.
Same corollary: keep timestamps/randomness out of packet prompts.

## 3. Control-flow doctrine [spec]

The tool's most opinionated — and most portable — design:

- **`pipeline()` is the default.** Items flow through stages independently with
  *no barrier*: item A can be in stage 3 while B is in stage 1. Wall-clock =
  slowest single-item chain, not sum of slowest-per-stage.
- **`parallel()` is a barrier** and must be justified. Legitimate only when
  stage N needs cross-item context from *all* of stage N−1: dedup/merge across
  the full set, early-exit on zero total, "compare with the other findings"
  prompts.
- **The barrier smell test:** `await parallel(...)` → pure transform
  (flatten/map/filter) → `await parallel(...)` means the middle transform never
  needed the barrier — fold it into a pipeline stage.
- Failure isolation: a stage that throws drops *that item* to `null` (skip its
  remaining stages); `parallel()` never rejects wholesale — thunk errors become
  `null` slots, so `.filter(Boolean)` before use.

**fleetflow port:** the orchestrator plans lanes the same way — don't hold a
whole round hostage to a barrier unless a later packet genuinely consumes all
prior results. Failure isolation comes free (one lane failing gates out at
collect; the others land).

## 4. Concurrency, caps, budget [spec]

- Concurrent agents: `min(16, cpu cores − 2)` per workflow; excess queues.
- Lifetime cap 1000 agents per run (runaway-loop backstop), 4096 items per
  pipeline/parallel call — an explicit error, never silent truncation.
- **Budget spine:** `budget.total / spent() / remaining()` — a *shared* output
  token pool across the main loop and all workflows; a hard ceiling (agent()
  throws past it), enabling `while (budget.remaining() > 50k)` loops and
  fleet-size-by-budget (`Math.floor(budget.total / 100k)`).
- **No silent caps doctrine:** any bounded coverage (top-N, no-retry, sampling)
  must be `log()`ged — "silent truncation reads as covered-everything".

**fleetflow port:** concurrency ≤ 4–6 *per provider* (endpoint quota binds
before CPU); bound each worker with `--max-turns`; declare any coverage bound
in the run summary. Token budgeting is per-provider-plan rather than a shared
pool — account by the provider's own usage metering, not Claude Code's
notional `total_cost_usd`.

## 5. Progress & structure surface [spec]

- `meta` block (pure literal: name, description, phases) drives the /workflows
  progress UI; `phase()` groups agents; `log()` emits narrator lines.
- `opts.label` names an agent in the tree; `opts.phase` pins an agent to a
  group from inside concurrent stages (avoids racing the global phase state).
- Agents get model (`opts.model`) and effort (`opts.effort`) overrides
  per-call; guidance: omit model (inherit) unless confident, use `effort` as
  the finer lever ("reach for the effort lever before the model lever").

**fleetflow port:** run/lane naming (`--run`/`--id`) is the phase/label
analogue; the orchestrator's status tables to the user play the /workflows UI
role.

## 6. Quality patterns [spec]

Verbatim-portable; the native spec's catalog:

| Pattern | Mechanics | fleetflow note |
|---|---|---|
| **Adversarial verify** | N independent skeptics per finding, each prompted to REFUTE, default-refute on uncertainty, majority kills | make ≥1 skeptic a different provider — model diversity catches failure modes redundancy can't |
| **Perspective-diverse verify** | distinct lenses (correctness/security/perf/repro) instead of N identical refuters | lens × brain grid is even stronger |
| **Judge panel** | N independent attempts from different angles, parallel judges score, synthesize from winner + graft runners-up | natural fit: Sonnet attempt vs Codex attempt, Opus judges |
| **Loop-until-dry** | keep spawning finders until K consecutive rounds return nothing new; dedup vs *seen*, not vs *confirmed* (else judge-rejected findings reappear forever) | identical |
| **Multi-modal sweep** | parallel agents each searching a *different way*; each blind to the others | identical |
| **Completeness critic** | final agent asks "what's missing?" — its findings are the next round | identical |

## 7. Prompting contract [spec]

Workflow subagents are told their **final text IS the return value** — not a
human-facing message — so they return raw data. With a `schema`, the subagent
is forced through a StructuredOutput tool call and the validated object comes
back.

**fleetflow port:** every packet ends with an explicit `FINAL REPLY:` shape.
Codex workers can enforce it natively (`codex exec --output-schema <file>` +
`-o last-message.txt`); Claude workers get the shape in the prompt and
`ff-collect` + the orchestrator validate on the way in.

## 8. Resume ergonomics [spec]

`Workflow({scriptPath, resumeFromRunId})` after a pause/kill/edit: unchanged
prefix replays from journal; first edited call and everything after runs live.
Fallback when no journal: read the `agent-<id>.jsonl` transcripts and
hand-author a continuation.

**fleetflow port:** `ff-spawn` consults the run journal before spawning (cache
hit → exit 3 + cached result path). The same fallback applies: worker stdout
JSON files survive in `.fleetflow/<run>/` for hand-salvage.

## 9. What does NOT port

- **In-process schema enforcement with retry** — the tool-call layer re-asks
  the model on validation failure; fleetflow's Claude workers get one shot +
  collect-time validation (Codex `--output-schema` restores most of it).
- **The shared token budget object** — no cross-provider equivalent; use
  per-provider plan metering.
- **The /workflows live UI** — orchestrator status tables replace it.
- **MCP tool reach-through** (workflow agents can ToolSearch session MCP
  servers) — process workers see only what their own config provisions. For
  GLM workers, provision skills into the isolated config dir (fleet-worker
  "Giving a worker skills").
