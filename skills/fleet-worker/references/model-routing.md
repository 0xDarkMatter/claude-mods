# Model routing convention (hybrid: in-process tiers + provider workers)

A reusable convention for routing different models to different agents across a fan-out —
both the **in-process** Workflow-tool agents and the **out-of-process** fleet-worker
provider workers. One taxonomy drives both, so routing is intentional and uniform instead
of ad-hoc per script.

The helper that implements it is [`assets/route.js`](../assets/route.js) (a paste-in, since
Workflow scripts have no `require`).

---

## Why there are two loci (read this first)

The split is forced by how Claude Code resolves models — see SKILL.md *"architecture crux"*:

- **Model alias slots are per-agent, within one process.** A Workflow `agent()` call takes
  `opts.model: 'opus' | 'sonnet' | 'haiku' | 'fable'`. That selects a *slot* for that one
  agent. On a normal session the slots resolve to real Anthropic Opus/Sonnet/Haiku. So you
  **can** route agent A → haiku and agent B → opus in the same workflow. This is
  **in-process tier routing**: cheaper than all-Opus, same provider, same account.
- **The provider (`ANTHROPIC_BASE_URL`) is process-global.** It's read once per `claude`
  process and applied to every call. You **cannot** point agent A at Anthropic and agent B
  at GLM inside one process. Mixing providers requires a **separate OS process with its own
  env** — that process is `fleet-worker`. This is **provider routing**: the big cost lever.

So: tier *within* a process is free to vary per agent; provider varies only *across*
processes. The taxonomy below assigns each work class a tier **and** a locus.

---

## The taxonomy — work class → locus, model, effort

| Work class | Examples | Locus | Model | Effort |
|---|---|---|---|---|
| **mechanical** | format, rename, regex sweep, file-by-file transform | fleet-worker (GLM) or in-proc | `haiku` / GLM-4.5-Air | low |
| **scout** | find, enumerate, read-and-extract, summarize | in-proc (fleet-worker if very wide) | `sonnet` / GLM-5.2 | low |
| **build** | implement a change needing judgment | in-proc | `sonnet`→`opus` | medium |
| **synthesize** | merge findings, write the report, design | **in-proc only** | inherit (session = Fable/Opus) | high |
| **judge** | adversarial verify, score, gate a finding | **in-proc only** | inherit (session = Fable/Opus) | high–max |

Two rules of thumb that keep this honest:

- **Never under-power a judge.** A cheap verifier that rubber-stamps is worse than no
  verifier — it launders bad findings as confirmed. Judges and synthesis inherit the
  session model — omit `opts.model` rather than pinning `'opus'`, which would
  *downgrade* the decider on a Fable session.
- **Effort is a finer knob than model.** Dropping a mechanical stage to `effort: 'low'` on
  the *same* model often saves more than is worth a model switch, with no quality cliff.
  Reach for the effort lever before the model lever.

### Cost intuition

In-process tier routing saves *some* (Anthropic Haiku/Sonnet are far cheaper than Opus, but
still Anthropic pricing). Provider routing via fleet-worker saves *a lot* (GLM is pennies).
So: tier-route everything in-process by default; escalate to fleet-worker only when a stage
is cost-dominant **and** fits the locus rule.

---

## The locus rule — when to leave the Workflow tool for fleet-worker

> Shell out to **fleet-worker** when a stage is a **large** (≈12+ items), **independent**
> (no shared orchestrator context), **file-mutating**, **cost-dominant** fan-out you can
> **gate before landing**. Otherwise stay **in-process**.

Stay in-process when: the stage is synthesize/judge (you want Opus + a tight loop), the
results feed straight into the next stage, the fan-out is modest, or the work needs the
conversation's context. `useFleetWorker()` in the helper encodes the test.

The canonical fleet-worker case: *"30 file migrations → 30 GLM workers → `fleet-collect.sh`
gate → fleet-ops landing."* The canonical in-process case: *"review 6 dimensions (sonnet) →
adversarially verify each finding (opus)."*

---

## Worked examples

**1. Review → verify (all in-process, tier by stage).** Reviewers are cheap and wide;
verifiers are expensive and decisive.

```js
const reviews = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { ...route('scout'),  phase: 'Review', schema: FINDINGS }),
  r => parallel(r.findings.map(f => () =>
        agent(verifyPrompt(f), { ...route('judge'), phase: 'Verify', schema: VERDICT })))
);
```

**2. Migrate (hybrid — provider workers for the bulk, Opus judge in-process).**

```js
const sites = await agent(discoverPrompt, { ...route('scout'), schema: SITES });
if (useFleetWorker({ items: sites.length, selfContained: true, mutatesFiles: true })) {
  // each site → a fleet-worker (GLM) launched via Bash in its own worktree;
  // collect + gate with scripts/fleet-collect.sh, then land via fleet-ops.
} else {
  await parallel(sites.map(s => () => agent(migratePrompt(s), { ...route('build') })));
}
const ok = await agent(auditPrompt, { ...route('judge') });   // always in-process Opus
```

**3. Budget-aware degradation.** Pass the Workflow `budget` so a long run steps down a tier
as it nears the ceiling instead of throwing at it:

```js
while (budget.total && budget.remaining() > 50_000) {
  const r = await agent(findPrompt, { ...route('scout', budget), schema: BUGS });
  // route() returns sonnet/low early, drops to haiku/low once <15% budget remains
}
```

---

## What this convention is NOT

- Not a way to run in-process subagents on GLM — that's impossible (process-global
  provider). Use fleet-worker.
- Not automatic — you tag each `agent()` call with a work class. The value is a *consistent
  vocabulary*, not magic inference.
- Not a fixed price list — for actual cost/$ estimates use
  [`loop-ops`](../../loop-ops/SKILL.md)'s `loop-estimate.py` + `assets/model-pricing.json`
  (the source of truth for model pricing).

## See also

- [`fleetflow/references/native-model-routing.md`](../../fleetflow/references/native-model-routing.md)
  — the in-process half in depth: cost evidence (7-day audit), full mechanism
  (`opts.model`/`opts.effort`, `meta.phases[].model`, fork inheritance), caveats
- [`assets/route.js`](../assets/route.js) — the paste-in helper
- SKILL.md *"architecture crux"* — the process-global-provider constraint this is built on
- [`fleet-ops`](../../fleet-ops/SKILL.md) — test-gated landing for the provider-worker branches
- [`loop-ops`](../../loop-ops/SKILL.md) — cost/budget spine and `loop-estimate.py`
