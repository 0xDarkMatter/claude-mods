# Shipped Resources and Live Documentation

Worked invocations and caveats for the verifier, the calculator and the copy-and-adapt assets this skill ships, plus the live documentation to check cached facts against.

## Resources & Verification

This skill ships a staleness verifier and two copy-and-adapt starter assets. The
model table and pricing above are the facts most likely to drift — run the
verifier when you suspect they're stale.

**`scripts/check-model-table.py`** — guards the Current Models table (this file)
and the per-model prompt-cache minimum table
([references/caching-and-cost.md](caching-and-cost.md)) against drift.
Two modes per the [resource protocol §7](../../../docs/SKILL-RESOURCE-PROTOCOL.md):

```bash
# Structural (default, no network): every row well-formed, ids carry no date
# suffix, prices numeric, the two files agree on the model lineup. It also
# guards the cache-economics constants that are stated in more than one file
# (0.1x read, 1.25x/2x writes, 4 breakpoints, 20-block lookback, the
# context-management beta id), asserts each doctrine reference carries a
# "verified <ISO date>" stamp, and checks SKILL.md <-> references/ citation
# integrity in both directions. It then scans every file in the skill for model
# ids: an id in neither the table nor the Legacy list is flagged "unknown", and
# a LEGACY id sitting where a reader would copy it (model=..., "model": ...,
# --model ...) is flagged "retired" - append a `legacy-ok` comment to that line
# for a deliberate migration example. Exit 4 on any contradiction.
python skills/claude-api-ops/scripts/check-model-table.py --offline
python skills/claude-api-ops/scripts/check-model-table.py --offline --json | python -m json.tool

# Live (advisory, needs ANTHROPIC_API_KEY): curls the Models API and compares
# its id set against the documented ids. Exit 10 if a documented id is gone or a
# newer alias id is missing from the table; exit 7 (not a failure) if the key is
# unset or the API is unreachable. Live mode checks model-ID coverage ONLY — the
# API returns no pricing, so pricing/context drift stays an --offline + docs concern.
ANTHROPIC_API_KEY=sk-... python skills/claude-api-ops/scripts/check-model-table.py --live
```

**`scripts/context-budget.py`** — append-vs-compact calculator. Models both paths
in dollars over the turns you actually have left, checks the context ceiling
first, and exits **10** when cost favours compaction, **0** when appending wins:

```bash
# Short session — appending is cheaper (exit 0)
python skills/claude-api-ops/scripts/context-budget.py \
    --history-tokens 25000 --turns-remaining 5 --base-rate 0.30

# Deep session — cost favours compaction (exit 10)
python skills/claude-api-ops/scripts/context-budget.py \
    --history-tokens 120000 --turns-remaining 40 --base-rate 2.00 --json
```

Two results worth knowing before you trust it: the break-even turn count is
**scale-invariant** (history size and price cancel out — it tracks the summary
ratio, not how big or costly the conversation is), and it prices **cost only**.
Recall loss is not in the model, so "compact" means cheaper, not better.

**`assets/cached-agent-loop.py`** — the cache-aware sibling of the minimal loop
below, and the executable form of the Context Engineering section: breakpoint at
the end of the static prefix, a rolling breakpoint on the newest turn, an
intermediate anchor every ~15 blocks so long tool-heavy turns don't jump the
20-block lookback, tool output capped at the boundary, and a per-turn
`cache_read_input_tokens` check that warns when the prefix silently changed.
Copy it when the agent is long-running; copy `agentic-loop.py` when it isn't.

The footgun it encodes: `cache_control` is a key on a content block, so it can
only be set on a **dict**. Appending `response.content` verbatim (SDK block
objects) or using the `"content": "a string"` shorthand leaves nowhere to put a
marker — every breakpoint aimed at those turns is discarded with no error and no
warning. Normalise content to dict blocks before placing breakpoints.

**`assets/recall-probe.py`** — the "measure it on your workload" harness:
plants a fact, buries it under N turns, probes for it, and reports recall, cost
per turn and TTFT for **append** vs **compact**. Makes real API calls, so start
small (`--turns 6 --trials 1`). Replace the synthetic filler turns with traffic
from your own logs — that is the point of running it.

**`assets/agentic-loop.py`** — a minimal, runnable tool-use loop (define a tool,
call `messages.create`, loop while `stop_reason == "tool_use"`, append
`tool_result`, re-request until `end_turn`). Copy it as the starting point when
building a manual agent loop; the `>>> ADAPT` marks show what to change.

**`assets/output-schema.json`** — a known-good structured-outputs request body in
the canonical `output_config.format` shape (with `additionalProperties: false`
and a `required` array). Copy and reshape `schema.properties` when adding JSON
outputs; see [references/structured-outputs.md](structured-outputs.md)
for the rules. (Supported on every current model — Fable 5, Opus 5, Sonnet 5,
Haiku 4.5 — and the legacy 4.5–4.8 line.)

## More live documentation

- Messages API: `https://platform.claude.com/docs/en/api/messages`
- Tool use: `https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview.md`
- Prompt caching: `https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md`
- Structured outputs: `https://platform.claude.com/docs/en/build-with-claude/structured-outputs.md`
- Batches: `https://platform.claude.com/docs/en/build-with-claude/batch-processing.md`
- Agent SDK: `https://code.claude.com/docs/en/agent-sdk/overview`
- Context editing: `https://platform.claude.com/docs/en/build-with-claude/context-editing`
- Context engineering: `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
