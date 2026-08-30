# Tooling Landscape — which eval platform, when

> **Verified 2026-08.** This is the fastest-moving part of the skill. Features, pricing and
> OSS/commercial boundaries here change on a scale of months. **Re-verify with a web search
> before quoting any specific claim** — treat everything below as a shape to check against
> reality, not as a current fact sheet. No version numbers are quoted deliberately.

## The one structural fact

**Trace-level observability and eval scoring have converged into the same products.** As of
2026 you are not choosing a tracer and then an eval library; you are choosing one system
that captures the nested span tree (model calls, tool calls, arguments, cost) and attaches
scores to those traces, in dev and in production. Any comparison that treats them as two
categories is out of date.

That convergence is what makes trajectory- and step-level eval practical at all
(`eval-taxonomy.md`) — you cannot score a path you did not capture.

## The honest default

**Start with a JSONL file and a 40-line runner.** Read cases, call the system, apply
assertions, write results, print a delta. It is a morning's work, it has no vendor coupling,
and it forces you to decide what you are actually measuring — which is the hard part, and
the part no platform does for you.

Adopt a platform when you hit a specific wall:

| Wall | Then you want |
|---|---|
| Non-engineers need to curate the dataset | A dataset-management UI (Braintrust is the archetype) |
| You need to search production traces and score live traffic | An observability-first platform (Langfuse, Arize, LangSmith, Opik) |
| Evals should feel like the test suite | A pytest-native framework (DeepEval) |
| You already run ML infra and want one system | MLflow |
| Scheduled runs, shared dashboards, alerting | Any hosted platform; this is what you are paying for |

Do not adopt one because the eval list is long. Metric catalogs are cheap; a rubric
calibrated against your humans is not, and no platform ships that.

## The players

Open-source cores (self-hostable, no vendor lock on the data):

| Tool | Shape | Reach for it when |
|---|---|---|
| **DeepEval** | pytest-native LLM eval framework, large research-backed metric library | Your team's mental model is "tests"; you want evals in the existing test command |
| **MLflow** | Tracing with replay, prompt versioning, automated eval — one OSS platform | You already run MLflow, or you want the whole stack under one OSS licence |
| **Opik** (Comet) | Tracing with cost tracking, built-in metrics, prompt versioning, broad framework integrations | You want hosted-or-self-hosted flexibility with wide framework coverage |
| **Langfuse** | Observability-first: traces, datasets, scores, self-hostable | Production trace search is the primary need |
| **Arize Phoenix** | OSS tracing/eval, OpenTelemetry-native | You are standardising on OTel semantics |

Commercial-first:

| Tool | Shape | Reach for it when |
|---|---|---|
| **Braintrust** | Eval-focused, strong collaborative dataset curation, scheduled runs, score-regression tracking | PMs and domain experts must own the golden set |
| **LangSmith** | Tracing + eval, tight LangChain/LangGraph integration | You are already deep in that ecosystem |
| **Arize** | Production ML/LLM observability at scale | Enterprise monitoring is the driver |
| **AgentOps** | Agent-run-centric session replay, cost and step tracking | Debugging long agent trajectories is the pain |

## Selection checklist

Score candidates on the things that actually bite six months in:

1. **Can you export your traces and datasets?** The dataset is the durable asset
   (`golden-datasets.md`). If it only lives in a vendor UI, you have rented your history.
2. **Does it capture the full nested span tree**, including tool arguments? Without
   arguments you cannot do step-level scoring.
3. **Can it run in CI and fail a build** with a machine-readable result? A platform you can
   only read in a browser cannot gate anything.
4. **Can you pin the judge model version?** Unpinned judges silently re-baseline
   (`llm-judge.md`).
5. **Does it record cost and latency per case** natively, or must you thread it yourself?
6. **Self-host option?** Matters the moment eval inputs contain customer data.
7. **What happens to your custom metrics** — are they plain functions you own, or a DSL you
   would have to rewrite to migrate?

## Benchmarks vs your evals

Public benchmarks (tau-bench and the agentic-benchmark family, SWE-bench and its
descendants) are for *model selection* — they tell you which model to start from. They are
not your eval suite: they are contaminated over time, they measure someone else's task
distribution, and a model that tops them can still fail your product's specific policy.

Use them once, at model-choice time. Then measure your own thing, on your own frozen set.

## Cross-reference

- What to measure before you shop for a tool: `eval-taxonomy.md`
- The asset that outlives whatever you pick: `golden-datasets.md`
- Making the chosen tool gate CI: `regression-gating.md`
