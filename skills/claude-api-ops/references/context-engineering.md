# Context Engineering Reference

> **What this file owns:** the discipline of deciding *what the model sees on every
> call* — the context budget, the three placement tiers, and the agentic-loop
> specifics (tool-result bloat, sub-agents as isolation, note-taking).
>
> **Adjacent files, so this one doesn't duplicate them:**
> [compaction.md](compaction.md) owns the *decision to discard* context and the
> `context_management` / memory-tool APIs.
> [caching-and-cost.md](caching-and-cost.md) owns prompt-cache *mechanics*
> (breakpoints, TTLs, minimum prefixes, invalidation table).
>
> Facts verified against platform.claude.com and anthropic.com **2026-08-30**.

---

## 1. The frame: context is a budget, not a container

Prompt engineering asks "what do I write in the prompt?". **Context engineering asks
"what earns a place in the window on *this* call?"** — including everything that lands
there without you typing it: tool definitions, tool results, retrieved documents,
prior turns, system reminders, thinking blocks.

Anthropic's framing (*Effective context engineering for AI agents*): the goal is
"the smallest possible set of high-signal tokens that maximize the likelihood of some
desired outcome." Prompt engineering is discrete — you write it once. Context
engineering is **iterative**: it happens on every single inference.

### Why the budget is real

- **Attention is finite.** Transformers form n² pairwise relationships for n tokens.
  Accuracy degrades as token count grows — the failure mode Anthropic names
  **context rot**. A 1M-token window is a *capacity*, not a *target*.
- **Training-distribution thinness.** Models have seen far fewer long-range,
  context-wide dependencies than short ones, so long-context reasoning is the
  weakest part of the envelope, not merely the slowest.
- **Every token is billed on every turn.** In a multi-turn loop the same prefix is
  re-sent each call. Uncached, a 50K-token prefix over 40 turns is 2M input tokens.
  (Cached, it is ~10% of that — see §4, and it is exactly why the compaction
  instinct is often wrong. → [compaction.md](compaction.md).)

**Working rule.** Before adding anything to a prompt, ask: *does this change the
model's next action?* If not, it belongs on disk or behind a retrieval call, not in
the window.

---

## 2. The three tiers

Every piece of information the agent could use lives in exactly one of three places.
Choosing the tier deliberately is most of context engineering.

| Tier | Where it lives | Latency to use | Cost profile | Use when |
|---|---|---|---|---|
| **1 — In context** | Rendered into `tools` / `system` / `messages` every call | Zero | Paid every turn (≈0.1× when cached) | It steers *most* turns: the task spec, the invariants, the current working set |
| **2 — On disk, read on demand** | A file the agent can `Read`/`Grep` when it decides to | One tool round-trip | Paid only when read | It steers *some* turns and the agent can tell when it needs it from the filename alone |
| **3 — Retrieved** | Index / vector store / API behind a search tool | One+ round-trips, plus a relevance gamble | Paid only when hit | The corpus is too large to enumerate and relevance is query-dependent |

### Choosing between tiers

- **Tier 1 is the expensive tier.** It costs on every call whether or not the turn
  needed it. Reserve it for what is load-bearing on the majority of turns.
- **Tier 2 is the default for "might need it".** Anthropic's just-in-time framing:
  let the agent maintain lightweight identifiers (file paths, queries, links) and
  hydrate them at runtime. A path is ~10 tokens; the file it names may be 10,000.
  The trade-off is honest — "runtime exploration is slower than retrieving
  pre-computed data."
- **Tier 3 pays for scale with a relevance risk.** If retrieval misses, the model
  does not know what it did not see. Prefer tier 2 whenever the candidate set is
  small enough to name.
- **Hybrids win in practice.** Pre-load the handful of things that steer every turn
  (tier 1), leave the long tail addressable (tier 2/3).

### The demotion test

When a prompt is too big, demote rather than delete. For each block ask:

1. Does it change the next action on **most** turns? → stays tier 1.
2. Can the agent tell from a **name** that it needs this? → tier 2 (write it to a
   file, leave the path in context).
3. Neither, but it is occasionally essential? → tier 3 (index it, ship a search tool).

Deleting outright is the fourth option and the only irreversible one.

---

## 3. Progressive disclosure — this repo already runs on it

**Claude Code skills are a tier-1/tier-2 split you can read on disk.** That is not an
analogy; it is the same mechanism:

| Layer | Tier | Loaded |
|---|---|---|
| Skill `name` + `description` frontmatter | 1 | Always — every skill's description sits in the session prompt |
| `SKILL.md` body | 2 | When the router matches the description |
| `references/*.md` (this file) | 2 | Only when `SKILL.md` cites it and the task needs it |
| `scripts/*` output | 2 | Only when executed |

This is why the repo's own rules read the way they do, and the rules are context
engineering rules wearing authoring clothes:

- **"The `description` is the trigger"** — the description is the only always-resident
  text, so it must carry the routing signal and nothing else.
- **"Keep the body under 500 lines"** — the body is what gets pulled in wholesale on a
  match; an oversized body spends the budget of every task that touches the skill.
- **"One concept per reference file"** — a file is the unit of loading. Two concepts
  in one file means loading both to get either.
- **"Every reference must be cited from `SKILL.md`"** — an uncited file is
  unreachable. In tier terms: a tier-2 artefact with no pointer in tier 1 does not
  exist.

The same shape generalises to any agent you build: a small always-on spec, a set of
named-and-addressable documents, and a retrieval path for the long tail.
See [SKILL-CREATION-PROTOCOL.md](../../../docs/SKILL-CREATION-PROTOCOL.md) Step 3 and
[SKILL-RESOURCE-PROTOCOL.md](../../../docs/SKILL-RESOURCE-PROTOCOL.md) §1.

---

## 4. Cache-aware prompt architecture

The cache is what makes a large tier-1 affordable — and the cache is a **prefix
match**, so *ordering is architecture*.

### The layout rule

Requests render in a fixed order — `tools` → `system` → `messages` — and each level
builds on the previous. Therefore:

```
tools        ─┐
system        ├─ static, byte-identical across calls   ← cache_control breakpoint here
(stable docs) ┘
messages      ← volatile: the turn, the retrieved chunk, the timestamp
```

**Static prefix first, volatile content last.** Anything that varies per request must
sit *after* the last breakpoint, or it changes the prefix bytes and every cached
token behind it is re-billed at write price.

### Why reordering silently destroys the cache

There is no error. Moving a block, adding a conditional system section, or
interpolating a user id early in the prompt produces a *different prefix hash*, which
is simply a miss: `cache_read_input_tokens: 0`, `cache_creation_input_tokens: <all of
it>`, a 1.25–2× bill instead of 0.1×, and no diagnostic anywhere. The only signal is
the usage block — which is why "assert `cache_read_input_tokens > 0` in staging" is a
real test, not a nicety.

Two ordering traps specific to agent loops:

- **A breakpoint searches backward at most 20 content blocks.** A turn that appends
  more than 20 blocks (many `tool_use`/`tool_result` pairs) jumps the window and
  silently misses. Add an intermediate breakpoint roughly every 15 blocks in long
  turns.
- **A cache entry only becomes readable once the first response begins streaming.**
  Fanning out N parallel requests against a cold shared prefix writes N entries and
  reads none. Fire one, await first token, then fire the rest.

The invalidation table, per-model minimum prefixes, TTL pricing and the full
silent-invalidator checklist live in
[caching-and-cost.md](caching-and-cost.md) — this section is the *shape* rule only.

### The consequence for compaction

Rewriting history to make it shorter changes the prefix. A summarisation pass
therefore pays a full cache write on the next call *and* discards every cached token
before it. That is the mechanism behind the counter-intuitive finding in
[compaction.md](compaction.md): under caching, the cheap thing is usually to
**append**, not to **rewrite**.

---

## 5. Multi-turn and agentic specifics

### 5.1 Tool results are where the budget actually goes

In an agent loop, the growth term is almost never the system prompt — it is tool
output. A file read, a search result, an HTTP response: each lands verbatim and stays
for the rest of the session.

**Design tools to return decisions, not dumps.** Anthropic's guidance: tools should
be "self-contained, robust to error, and extremely clear with respect to their
intended use", with "minimal overlap in functionality". A bloated tool set costs
tokens at position 0 *and* creates ambiguous decision points.

Concrete levers, cheapest first:

| Lever | What it does | Cost |
|---|---|---|
| **Cap tool output at a fixed size** | Truncate/paginate at the tool boundary, before the result enters context | Free — and critically, it **shrinks context without rewriting the prefix**, so the cache survives |
| **Return a handle, not the payload** | Tool writes to a file, returns the path + a 200-token précis | One extra round-trip if the agent needs the full text |
| **Filter at the source** | `grep`-shaped tools instead of `cat`-shaped ones | Design-time only |
| **Clear stale results** | `context_management` server-side clearing | Invalidates the cache at the clear point → [compaction.md](compaction.md) |

The capping lever is the one to reach for first: a Towards AI evaluation
(AI Engineer World's Fair, August 2026) measured **38% lower cost per turn** from
fixed-size tool-output caps alone, with no loss of recall — precisely because it does
not touch the cached prefix.

### 5.2 Summarise a tool result, or write it to a file?

| Situation | Do this |
|---|---|
| Result is large and needed **later, in full** (a fetched spec, a big file) | **Write to a file**, return the path. Lossless, addressable, and the path costs ~10 tokens per turn |
| Result is large and only its **conclusion** matters (a 300-row query → "4 rows failed") | **Summarise at the tool boundary** — before it enters context, not after |
| Result is large, and you cannot tell which parts matter yet | **Both**: file for fidelity, précis in context, path in the précis |
| Result is small, or is the thing the user asked for | **Leave it alone.** Compression has a floor; do not spend a round-trip to save 200 tokens |

The distinction that matters: **summarising at the tool boundary is free of cache
cost** (the shorter result is what gets appended, and nothing before it moves).
Summarising *after the fact* — rewriting history that is already in the prefix — is
compaction, and pays the full cache-write penalty.

### 5.3 Structured note-taking (persistent memory)

Have the agent maintain an external `NOTES.md` / progress file and pull it back in
when needed — "persistent memory with minimal overhead". It is a tier-2 artefact that
the agent itself authors, and it survives context resets, which is what makes it the
natural companion to any clearing strategy: write the durable conclusion out
*before* the raw material is cleared. The first-party version of this is the memory
tool → [compaction.md](compaction.md) §4.

### 5.4 Sub-agents as context isolation

A sub-agent is not primarily a parallelism device — **it is a second context window
whose contents never touch yours.**

```
orchestrator context:  task spec + plan + N × (≈1-2K token summary)
      ↓ spawn                                   ↑ return
sub-agent context:     the 80K tokens of exploration nobody else needs
```

The exploration — dozens of file reads, failed greps, dead ends — is billed once,
inside the sub-agent, and then discarded. The orchestrator sees only the distilled
result; Anthropic's guidance puts that return payload at roughly **1,000–2,000
tokens**.

Use it when:

- A subtask generates far more intermediate context than conclusion (search, triage,
  audit, "find where X is implemented").
- You want a genuinely independent opinion — a fresh window cannot be primed by the
  orchestrator's earlier wrong turn. (Adversarial verification depends on this.)
- The subtask's tool set is large and irrelevant to the main loop — it renders at
  position 0 in the sub-agent's prompt, not yours.

Do **not** use it when the subtask needs most of the orchestrator's context to make
sense: you will pay to reconstruct that context in the child, and lose fidelity in
the hand-off. The hand-off is a lossy channel by design; if the summary has to carry
everything, isolation was the wrong tool.

Costs to price in: the sub-agent's prefix is a **cold cache** (a fresh window shares
nothing with the parent), the hand-off is lossy, and errors are harder to attribute.
Tier the model down for the isolated leg — an Opus orchestrator with Haiku/Sonnet
sub-agents is the standard shape (see [caching-and-cost.md](caching-and-cost.md),
"Model Tiering Economics").

---

## 6. Instrumentation — what to measure

You cannot engineer a budget you cannot see. Log per request:

| Signal | Source | What it tells you |
|---|---|---|
| `usage.input_tokens` | response | Uncached remainder — the part after your last breakpoint |
| `usage.cache_read_input_tokens` | response | Cache is working. **Zero across identical-prefix calls = a silent invalidator** |
| `usage.cache_creation_input_tokens` | response | What you paid write price for this turn |
| `usage.output_tokens` | response | The other half of the bill |
| Pre-flight estimate | `client.messages.count_tokens(...)` | Free; counts tools + system. Never `tiktoken` (OpenAI's tokenizer, 15–20% undercount on Claude) |
| Growth per turn | your own diff | Which tool is the growth term — almost always one of them dominates |

The single most valuable alarm: **`cache_read_input_tokens == 0` on a request whose
prefix should be unchanged.** It is the only symptom a broken cache produces.

---

## 7. Cross-references

| Concern | Where |
|---|---|
| Compaction decision, `context_management`, memory tool | [compaction.md](compaction.md) |
| Cache breakpoints, TTLs, minimums, invalidation table, batches | [caching-and-cost.md](caching-and-cost.md) |
| Tool definitions, agentic loop, `tool_result` mechanics | [tool-use.md](tool-use.md) |
| Sub-agents in the Agent SDK (`agents` option) | [agent-sdk.md](agent-sdk.md) |
| Claude Code's own context surface (CLAUDE.md, skills, hooks) | `claude-code-ops` skill |
| Scheduled/autonomous loops that re-send a prompt on a cadence | `loop-ops` skill |
| Cross-provider fleets and adversarial verify | `fleetflow` skill |

## 8. Sources

- Anthropic — *Effective context engineering for AI agents*:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Anthropic — *Managing context on the Claude Developer Platform*:
  `https://claude.com/blog/context-management`
- Prompt caching (ordering, 20-block lookback, concurrency):
  `https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md`
- Context editing: `https://platform.claude.com/docs/en/build-with-claude/context-editing`
- Bouchard, Solano & Vaid (Towards AI), *Context Engineering in 2026*, AI Engineer
  World's Fair, Aug 2026: `https://www.louisbouchard.ai/context-engineering-2026/`
