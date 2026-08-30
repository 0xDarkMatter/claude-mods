# Compaction & Context Editing Reference

> **What this file owns:** the decision to *discard or rewrite* context — when it is
> justified, what each option costs, and the first-party APIs that do it
> (`context_management` edits, the memory tool).
>
> **Adjacent files:** [context-engineering.md](context-engineering.md) owns the budget
> and the three tiers; [caching-and-cost.md](caching-and-cost.md) owns cache mechanics.
>
> Facts verified against platform.claude.com and anthropic.com **2026-08-30**.

---

## 1. The headline: compaction is not the default

**Compaction** = summarising the message history and reinitiating a context window
from the summary.

The instinct is that long conversations must be summarised or they get expensive and
the model gets confused. **Under modern prompt caching that instinct is measurably
wrong more often than it is right.**

A 2026 evaluation of a production AI tutor (Bouchard, Solano & Vaid, Towards AI —
660 turns across 11 configurations) compared keeping the full history against a
range of compaction strategies (their production preset of clearing + summarisation,
context reset, prompt compression, selective retention):

| Strategy | Fact recall at turn 11 | Cost / turn | Time to first token |
|---|---:|---:|---:|
| **Full history (keep everything)** | **92–100%** | **$0.11** | **17 s** |
| Production preset (clear + summarise) | 38–58% | $0.24 | 21 s |
| Context reset | 17% | — | — |

Keep-everything won **cost, latency and recall simultaneously** — the three axes
compaction is usually reached for. Summarisation was more than twice the cost per
turn, slower to first token, and forgot roughly half of a fact planted ten turns
earlier.

**Read the caveats, they matter:**

- The study ran on **Gemini 3.5 Flash via LangChain**, not Claude. What transfers is
  the *mechanism* — a cached prefix is billed at a fraction of base input, while
  summarising rewrites that prefix and forfeits the discount. Claude's cache economics
  make the mechanism *stronger*, not weaker (§3). The specific percentages are theirs,
  not a Claude benchmark.
- "Keep everything" is not "ignore context entirely." The same study found that
  **capping tool outputs at a fixed size cut cost per turn 38% with no recall loss** —
  because a cap shrinks context *without rewriting the cached prefix*. Shaping what
  enters context is cheap; rewriting what is already there is not.

**The rule:** compaction is a deliberate response to a **named constraint**, not a
reflex. If you cannot name which of the three constraints in §2 you are hitting, do
not compact — cap tool output and append instead.

---

## 2. The three constraints that justify compaction

Name one before you compact. Each has a different remedy, and reaching for the wrong
one is how teams pay summarisation costs to solve a problem summarisation does not fix.

### Constraint A — Context ceiling

*The conversation will not fit.* The hard one; it is not negotiable by budget.

- **Diagnose:** projected tokens at turn N exceed the model's window (1M on the
  current flagships, 200K on Haiku 4.5 — see the model table in `SKILL.md`).
- **Cheapest remedies first:** cap tool outputs → move payloads to files (tier 2) →
  server-side clearing (§3) → summarising compaction (§5).
- **Note:** a 1M window makes this constraint *rare* for conversational work and
  still common for long agentic runs, where tool results dominate.

### Constraint B — Cost ceiling

*It fits, but the bill is unacceptable.* This is the constraint most often assumed
and least often real, because the comparison is usually made against **uncached**
costs.

- **Diagnose honestly:** compare `cache_read_input_tokens × 0.1 × base_rate` against
  the cost of a summarisation call **plus** the cache write it forces on the next
  request. Do the arithmetic before assuming (§3).
- **Cheapest remedies first:** verify the cache is actually hitting (a zero
  `cache_read_input_tokens` is a bug, not a reason to compact) → tier the model down →
  cap tool outputs → 1-hour TTL if the gaps between turns are the problem.

### Constraint C — Latency target

*Time-to-first-token is too slow at depth.* Real, and the weakest case for
summarisation.

- **Diagnose:** measure TTFT against context length; confirm the growth is in the
  prefix rather than in thinking or tool round-trips.
- **Caution:** the tutor study measured compaction as *slower* (21 s vs 17 s) — the
  summarisation call is itself a round-trip, and the next request re-writes the cache.
  Compaction buys latency only when it is amortised over many subsequent turns.
- **Cheapest remedies first:** cap tool outputs → tier down → reduce `effort` →
  stream (TTFT is a streaming problem before it is a context problem).

### What each option costs you

| Option | Recall | Cache | Latency | Reversible? |
|---|---|---|---|---|
| **Append (do nothing)** | Full | Preserved | Grows with length | n/a |
| **Cap tool output at the boundary** | Loses untruncated detail only | **Preserved** | Improves | No, but loss is bounded and predictable |
| **Write payload to file, keep the path** | Full (one round-trip away) | Preserved | One extra hop when read | Yes |
| **Server-side clearing** (`context_management`) | Cleared results unrecoverable to the model unless saved to memory | **Invalidated at the clear point** | Improves after the re-write | No |
| **Summarising compaction** | Lossy, and the loss is unpredictable | **Invalidated wholesale** | One extra call now, faster later | No |

Read that table top-down: the first three preserve the cache, and the two that break
it are the two people reach for first.

---

## 3. The break-even arithmetic

Claude's cache read is **0.1× the base input rate** on every model; writes are
**1.25×** (5-minute TTL) or **2×** (1-hour TTL).

So the per-turn cost of carrying an N-token history is:

```
append   :  N × 0.1 × base_rate                    (steady state, cache hit)
compact  :  summarisation call (input ≈ N, output ≈ S)
         +  S × 1.25 × base_rate                   (cache write of the new prefix)
         +  S × 0.1  × base_rate  per later turn   (steady state on the summary)
         +  everything before the rewrite, forfeited
```

Compaction only wins once `0.1 × N` exceeds `0.1 × S` by enough to repay the
summarisation call **and** the forfeited prefix — i.e. when the history is very large,
the summary is very small, and the session continues for many turns afterwards. A
compaction just before the conversation ends is pure loss.

**The published threshold, adapted to Claude.** The tutor study put the crossover at
a *cached input price above ~$0.55 per million tokens* — above that, summarisation
starts to compete. Because a Claude cache read is 0.1× base input, that translates to:

```
cache-read rate  =  0.1 × base input rate
crossover        ≈  $0.55 / MTok cached
                 →  base input rate  ≳  $5.50 / MTok
```

Derive it from the current price table in `SKILL.md` rather than memorising a model
list: a model whose **base input rate is under ~$5.50/MTok has cache reads cheap
enough that appending stays ahead**, and only the premium tier approaches the
crossover. Re-run this arithmetic when prices change — it is two multiplications.

This is why the honest first question is never "should we compact?" but **"is the
cache hitting?"** A broken cache makes appending look 10× worse than it is and makes
compaction look like the fix, when the actual fix is a stray timestamp in the system
prompt.

---

## 4. First-party option: server-side context editing

`context_management` clears content **server-side, before the prompt reaches the
model**. Your client keeps the full unmodified history — there is no client state to
synchronise.

Beta header: `context-management-2025-06-27`.

### Strategy: clear tool uses

```python
response = client.beta.messages.create(
    model="claude-opus-5",
    max_tokens=4096,
    messages=messages,
    tools=tools,
    betas=["context-management-2025-06-27"],
    context_management={"edits": [{
        "type": "clear_tool_uses_20250919",
        "trigger":       {"type": "input_tokens", "value": 30000},  # when to fire
        "keep":          {"type": "tool_uses",    "value": 3},      # recent pairs kept
        "clear_at_least":{"type": "input_tokens", "value": 5000},   # min cleared per fire
        "exclude_tools": ["web_search"],                            # never clear these
    }]},
)
```

| Parameter | Default | Meaning |
|---|---|---|
| `trigger` | 100,000 input tokens | Threshold that activates clearing (`input_tokens` or `tool_uses`) |
| `keep` | 3 tool uses | Most recent tool-use/result pairs preserved |
| `clear_at_least` | none | Minimum tokens cleared per activation — **the cache-economics knob** |
| `exclude_tools` | none | Tools whose results are never cleared |
| `clear_tool_inputs` | `false` | Also clear the tool *call parameters*, not just results |

Oldest results go first; cleared content is replaced with a placeholder.

### Strategy: clear thinking blocks

```python
context_management={"edits": [
    {"type": "clear_thinking_20251015", "keep": {"type": "thinking_turns", "value": 2}},
    {"type": "clear_tool_uses_20250919", "trigger": {"type": "input_tokens", "value": 50000}},
]}
```

`keep` takes `{"type": "thinking_turns", "value": N}` or `"all"` (maximises cache
hits). When combining strategies, **thinking-block clearing must be listed first**.

Default behaviour differs by model generation: Opus 4.5+ and Sonnet 4.6+ keep all
prior thinking; earlier Opus/Sonnet and all Haiku models keep only the last turn.

### The cache interaction — the part that decides whether this pays

- **Clearing invalidates the cached prefix from the clear point onward.** Each
  activation costs a cache write on the next request.
- Therefore **set `clear_at_least`**. Without it, a trigger can fire and clear a
  trivial amount, paying a full cache re-write to save a few hundred tokens. It exists
  precisely to make each cache break worth taking.
- Thinking-block clearing is the mirror image: **keeping** thinking preserves the
  cache; **clearing** it invalidates at the clearing point. `"all"` is the
  cache-optimal setting.

### Inspecting and previewing

Responses report what was applied:

```json
{"context_management": {"applied_edits": [
  {"type": "clear_tool_uses_20250919", "cleared_tool_uses": 8, "cleared_input_tokens": 50000}
]}}
```

Preview before committing to a configuration — `count_tokens` accepts the same
`context_management` block and returns both the post-clearing `input_tokens` and
`context_management.original_input_tokens`.

### Reported results

Anthropic's internal agentic-search evaluation: **context editing alone +29% over
baseline; context editing with the memory tool +39%.** In a 100-turn web-search
evaluation, context editing let agents complete workflows that would otherwise fail
on context exhaustion, **reducing token consumption by 84%**.

Note the shape of that claim — the gains are on *long-horizon agentic search*, where
Constraint A is genuinely binding. It is not evidence that clearing helps a
twelve-turn conversation.

---

## 5. First-party option: the memory tool

`memory_20250818` gives Claude a directory of files it can create, read, update and
delete, persisting **across** conversations.

```python
tools=[{"type": "memory_20250818", "name": "memory"}],
context_management={"edits": [{"type": "clear_tool_uses_20250919"}]}
```

The pairing is the point: Claude is warned as context approaches a clearing
threshold, and can **write the durable conclusion to memory before the raw material is
cleared**. Clearing without memory throws information away; clearing with memory
demotes it from tier 1 to tier 2
(→ [context-engineering.md](context-engineering.md) §2).

---

## 6. If you must compact: do it well

When a named constraint genuinely demands summarisation:

- **Maximise recall first, then tune precision.** Anthropic's guidance is to start
  with a compaction prompt that captures every relevant piece of information, then
  iterate to trim. A compaction prompt tuned for brevity first will silently drop the
  one detail the next 40 turns needed.
- **Compact at a natural boundary** — a finished sub-task, a landed change — not at an
  arbitrary token count mid-reasoning.
- **Keep the last N turns verbatim** alongside the summary. Recent turns are where
  reference resolution ("that file", "the second one") lives.
- **Write the durable facts to a file first** (memory tool or `NOTES.md`), so the
  summary is a convenience rather than the sole record.
- **Compact once, deep** rather than repeatedly and shallowly. Every pass is a
  cache write and a lossy re-encoding; summaries of summaries degrade fast.
- **Measure it.** Plant a fact early, probe for it later, and compare against the
  keep-everything baseline on *your* workload. The tutor study's headline result is
  that the baseline is much stronger than teams assume — including, quite possibly,
  yours.

---

## 7. Sources

- Anthropic — *Effective context engineering for AI agents*:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Anthropic — *Managing context on the Claude Developer Platform* (29% / 39% / 84%):
  `https://claude.com/blog/context-management`
- Context editing API: `https://platform.claude.com/docs/en/build-with-claude/context-editing`
- Memory tool: `https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool`
- Prompt caching (multipliers, prefix rules):
  `https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md`
- Bouchard, Solano & Vaid (Towards AI), *Context Engineering in 2026: Why We Stopped
  Compacting Our Agent's Context*, AI Engineer World's Fair, Aug 2026:
  `https://www.louisbouchard.ai/context-engineering-2026/`
