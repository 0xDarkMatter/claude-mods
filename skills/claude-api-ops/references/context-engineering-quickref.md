# Context Engineering: One-Page Version

The working summary of [context-engineering.md](context-engineering.md) and [compaction.md](compaction.md): the three tiers, cache-aware prompt order, the compaction decision and agentic specifics.

### The three tiers

Every candidate fact lives in exactly one place. Choosing deliberately is most of the job.

| Tier | Where | Cost | Use when |
|---|---|---|---|
| **1 — In context** | `tools` / `system` / `messages`, every call | Paid every turn (≈0.1× cached) | It steers *most* turns |
| **2 — On disk, read on demand** | A file the agent can read; only the **path** stays in context | Paid only when read | The agent can tell from a *name* that it needs this |
| **3 — Retrieved** | Index / search tool behind a query | Paid only on a hit, plus a relevance gamble | The corpus is too large to enumerate |

When a prompt is too big, **demote before you delete** — a path is ~10 tokens; the
file it names may be 10,000.

**This repo already runs on the tier-1/tier-2 split.** A skill's `description` is
always resident (tier 1, so it must carry the routing signal); `SKILL.md` loads on a
match; `references/*.md` load only when cited and needed. "Description is the
trigger", "body under 500 lines", "one concept per reference", "every reference must
be cited" are context-engineering rules wearing authoring clothes.

### Cache-aware prompt architecture

Requests render `tools` → `system` → `messages`, and the cache is a **prefix match**.
So **static prefix first, volatile content last** — put the `cache_control` breakpoint
at the end of the stable part and let per-request content fall after it.

Reordering a prompt destroys the cache **silently**: no error, just a different prefix
hash, `cache_read_input_tokens: 0`, and a 1.25–2× bill where you expected 0.1×. The
usage block is the only symptom, which is why asserting `cache_read_input_tokens > 0`
in staging is a real test.

### The compaction decision

**Under modern prompt caching, keeping the full history has been measured to beat
summarisation on cost, latency AND recall at the same time.** A 2026 production-tutor
evaluation (660 turns, 11 configurations) put keep-everything at 92–100% fact recall,
$0.11/turn and 17 s TTFT, against 38–58% recall, $0.24/turn and 21 s for its
clear-plus-summarise preset. Summarising rewrites the cached prefix and forfeits the
0.1× discount — the cheap move is usually to **append**. (That study ran on a
non-Claude model; what transfers is the *mechanism*, and Claude's flat 0.1× cache
read makes it stronger, not weaker. Full caveats in
[references/compaction.md](compaction.md).)

So: **compact only as a deliberate response to a named constraint.**

| Constraint | Diagnose | Try first |
|---|---|---|
| **Context ceiling** — it will not fit | Projected tokens > window | Cap tool output → payloads to files → server-side clearing |
| **Cost ceiling** — the bill is unacceptable | Compare against *cached* cost, not uncached | **Verify the cache is hitting** → tier down → cap tool output |
| **Latency target** — TTFT too slow at depth | Confirm growth is in the prefix | Cap tool output → lower `effort` → stream |

Capping tool output at the tool boundary is the underrated lever: it shrinks context
**without rewriting the cached prefix** (the same study measured −38% cost/turn with
no recall loss). Clearing and summarising both break the cache; they are what people
reach for first and should reach for last.

First-party clearing is `context_management` (beta `context-management-2025-06-27`):
`clear_tool_uses_20250919` and `clear_thinking_20251015`, applied server-side. Always
set `clear_at_least` — it stops a trigger paying a full cache re-write to save a
handful of tokens. Pair with the memory tool so durable conclusions are written out
before raw material is cleared.

### Agentic specifics

- **Tool results are the growth term**, not the system prompt. Design tools to return
  decisions, not dumps.
- **Summarise vs write-to-file:** needed later *in full* → write to a file, return the
  path. Only the *conclusion* matters → summarise **at the tool boundary** (free of
  cache cost, unlike rewriting history after the fact).
- **Sub-agents are context isolation**, not just parallelism: 80K tokens of
  exploration are billed once inside the child and discarded; the parent sees a
  ~1–2K-token distillation. Costs: cold cache in the child, a lossy hand-off. Skip it
  when the subtask needs most of the parent's context to make sense.

Full doctrine — tiers, progressive disclosure, instrumentation:
[references/context-engineering.md](context-engineering.md).
Compaction economics, `context_management` parameters, memory tool:
[references/compaction.md](compaction.md).
For Claude Code's own context surface see the `claude-code-ops` skill; for
prompts re-sent on a cadence, `loop-ops`; for cross-provider fan-out, `fleetflow`.
