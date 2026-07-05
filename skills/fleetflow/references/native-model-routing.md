# Per-Stage Model/Effort Routing in Native Workflow Scripts

> Mechanism verified 2026-07-05 against the live Workflow and Agent tool schemas
> (Claude Code v2.1.x session surface). Model strings are **aliases** the harness
> resolves at spawn time — this doc deliberately never names a dated model ID.
>
> Scope: the **in-process** half of routing (native `agent()` calls sharing the
> session's provider). The cross-provider half (GLM/Codex process workers) and
> the shared work-class taxonomy live in
> [fleet-worker/references/model-routing.md](../../fleet-worker/references/model-routing.md).

## 1. Why — the cost evidence

A 7-day session-log audit (2026-06-28..07-05, all projects on this machine):

- Subagent transcripts produced **10.1M output tokens**. **75% ran on the two
  premium tiers** — 4.8M on Opus, 2.9M on Fable — vs 2.2M on Sonnet and only
  **0.3M on Haiku**.
- **729 StructuredOutput tool calls** in the week — overwhelmingly mechanical
  extract/verdict stages inside Workflow runs — every one billed at the premium
  session model.

Root cause is a default, not a decision: a Workflow `agent()` call **inherits
the main-loop model and effort unless overridden**, and nobody sets overrides.
On a Fable/Opus session, every "grep the logs and return JSON" stage runs on the
most expensive brain available. The fix is one line per collect-stage.

## 2. The mechanism

```js
await agent(prompt, {
  model:  'haiku',   // 'sonnet' | 'opus' | 'haiku' | 'fable' — omit to inherit session model
  effort: 'low',     // 'low' | 'medium' | 'high' | 'xhigh' | 'max' — omit to inherit session effort
  // ...label, phase, schema, isolation, agentType as usual
});
```

Facts that matter (all schema-sourced):

- **Omission = inheritance.** No override → the agent runs at the session's
  resolved model *and* effort. That is the correct default for stages whose
  failure is expensive — and the silent cost sink for stages whose failure isn't.
- **Aliases, not IDs.** `'opus'` means "the current Opus slot", resolved by the
  harness. Never hard-code dated model IDs in a workflow script — they rot.
- **`meta.phases[].model` is display metadata.** It annotates the phase in the
  /workflows progress UI so the override is visible; it does **not** route
  anything. `opts.model` on the `agent()` call is what routes. Set both — the
  annotation is how a reader audits the run's routing at a glance.
- **The Agent tool takes the same `model` param** for single subagent spawns,
  and it composes with custom `agentType`/`subagent_type` (an `Explore` scout on
  haiku is legal). Exception: **fork-type agents always inherit** — `model` is
  ignored for `subagent_type: 'fork'`.
- **`effort` is a reasoning-depth knob, not just a price knob.** Low effort
  buys shallower thinking. Cheap and shallow is exactly right for extraction;
  it is exactly wrong for a verdict.
- **Schema-forced output is what makes cheap models safe here.** With
  `opts.schema`, validation runs at the tool-call layer and re-asks on mismatch
  — a haiku extractor can't hand back malformed JSON, only wrong content, which
  is the verifier's job to catch anyway.

## 3. Routing table — stage type → tier

| Stage type | Typical stages | Override |
|---|---|---|
| **Mechanical collect** | StructuredOutput extraction, log scans, dedup, classification, format conversion, count/enumerate | `{ model: 'haiku', effort: 'low' }` |
| **Broad sweep** | finders, per-dimension reviewers, read-and-summarize, multi-modal search legs | `{ model: 'sonnet' }` (+ `effort: 'low'` when the sweep is wide and mechanical) |
| **Decide** | adversarial verifiers, judges, synthesis, final report, anything expensive-if-wrong | **omit both** — inherit the session's premium model |

**The rule of thumb: the stage that DECIDES stays premium; the stages that
COLLECT go cheap.** When unsure, omit the override — a wrong cheap answer that
survives verification costs more than the override saves.

Corollaries (carried over from the shared taxonomy, they bind here too):

- **Never under-power a judge.** A cheap verifier that rubber-stamps launders
  bad findings as confirmed — worse than no verifier. Deciders inherit; don't
  even pin them to `'opus'`, because on a Fable session that's a *downgrade*.
- **Reach for the effort lever before the model lever.** Same model at
  `effort: 'low'` is often the bigger saving with no quality cliff.
- **Budget pressure degrades collectors, never deciders.**
  [route.js](../../fleet-worker/assets/route.js) encodes this: under 15%
  remaining budget it steps collect-stages down a tier; judge/synthesize are
  exempt.

## 4. Before / after

Extraction stage (the 729-calls-a-week shape):

```js
// before — inherits Fable/Opus for a grep-and-format job
const flaky = await agent('Scan CI logs for retry markers; return the list.', { schema: FLAKY });

// after — one line
const flaky = await agent('Scan CI logs for retry markers; return the list.',
  { schema: FLAKY, model: 'haiku', effort: 'low' });
```

Review fan-out — sweep cheap, verify premium:

```js
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review',
                         schema: FINDINGS, model: 'sonnet', effort: 'low' }),
  review => parallel(review.findings.map(f => () =>
    agent(`Adversarially verify: ${f.title}`,
          { label: `verify:${f.file}`, phase: 'Verify', schema: VERDICT })
          // no model/effort — the decider inherits the premium session model
  ))
);
```

Single Agent-tool spawn (same param, same doctrine):

```js
Agent({ subagent_type: 'Explore', model: 'haiku',
        prompt: 'List every file that constructs a cache key…' })
```

## 5. Caveats — what this doctrine does NOT claim

- **Not a fixed price list.** Aliases float; for actual $/token use
  loop-ops' `loop-estimate.py` + `assets/model-pricing.json`.
- **Not applicable to forks.** Fork-type agents inherit unconditionally.
- **Not a provider switch.** `opts.model` picks a tier on the *session's*
  provider; pointing a stage at GLM/Codex requires an OS-process worker
  (fleetflow/fleet-worker) — see the locus rule in
  [fleet-worker/references/model-routing.md](../../fleet-worker/references/model-routing.md).
- **Not free accuracy.** A haiku collector will miss things a premium collector
  wouldn't. That's acceptable *only* when a premium-tier verify/judge stage
  stands downstream — which is why the [default posture](../SKILL.md) pairs
  every cheap collect fan-out with a verify phase.

## See also

- [native-workflow-insights.md](native-workflow-insights.md) §5 — where
  `opts.model`/`opts.effort` sit in the progress/structure surface.
- [fleet-worker/references/model-routing.md](../../fleet-worker/references/model-routing.md)
  — the shared work-class taxonomy and the in-process vs provider-worker locus rule.
- [fleet-worker/assets/route.js](../../fleet-worker/assets/route.js) — paste-in
  helper implementing this table (`route('mechanical')` etc.).
