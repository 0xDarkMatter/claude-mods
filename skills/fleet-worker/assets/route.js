// route.js — model/effort routing for Workflow `agent()` calls (claude-mods convention).
//
// Workflow scripts have NO filesystem/require access, so this is a PASTE-IN snippet:
// copy the block into your workflow script, then spread route() into agent() opts.
// See ../references/model-routing.md for the taxonomy, the locus rule, and worked examples.
//
// Mechanics (why this works — see SKILL.md "architecture crux"):
//   * opts.model picks an ALIAS SLOT (opus|sonnet|haiku|fable) PER AGENT, within the
//     orchestrator's one process. On a normal session those resolve to real Anthropic
//     Opus/Sonnet/Haiku. This is in-process tier routing — cheaper, same provider.
//   * ANTHROPIC_BASE_URL is process-GLOBAL: you cannot point agent A at Anthropic and
//     agent B at GLM in the same process. Cross-PROVIDER routing needs a separate
//     process — that's fleet-worker. Hence two loci, one taxonomy.

// --- Work class → in-process tier. Omit fields to inherit the main-loop default. ---
const TIERS = {
  mechanical: { model: 'haiku',  effort: 'low'    }, // format, rename, regex sweep, file-by-file transform
  scout:      { model: 'sonnet', effort: 'low'    }, // find, enumerate, read-and-extract, summarize
  build:      { model: 'sonnet', effort: 'medium' }, // implement a change needing judgment
  synthesize: { model: 'opus',   effort: 'high'   }, // merge findings, write the report, design — in-proc only
  judge:      { model: 'opus',   effort: 'high'   }, // adversarial verify, score, gate — in-proc only
};

// route(cls[, budget]) → opts fragment for agent(). Budget-aware: when the turn's
// tokens run low it drops one tier and forces low effort, so long "+500k" runs
// degrade gracefully instead of stalling at the budget ceiling.
function route(cls, budget) {
  const base = TIERS[cls] ?? {};                       // {} → inherit session model+effort
  if (budget?.total && budget.remaining() < 0.15 * budget.total) {
    const down = { opus: 'sonnet', sonnet: 'haiku', haiku: 'haiku' };
    return { model: down[base.model] ?? base.model, effort: 'low' };
  }
  return base;
}

// Locus decision: keep it in-process, or shell out to a fleet-worker (different
// provider/process). True only for a LARGE, INDEPENDENT, FILE-MUTATING fan-out you
// can gate before landing (e.g. 30 migrations → 30 GLM workers → fleet-ops). Anything
// that needs the orchestrator's context, or is synthesize/judge, stays in-process.
const useFleetWorker = ({ items, selfContained, mutatesFiles }) =>
  items >= 12 && selfContained && !!mutatesFiles;

// --- Usage -----------------------------------------------------------------------
//   await agent(prompt, { ...route('judge', budget), phase: 'Verify' });
//   await agent(findPrompt, { ...route('scout'), phase: 'Find' });
//   if (useFleetWorker({ items: files.length, selfContained: true, mutatesFiles: true })) {
//     // run the stage via the fleet-worker launcher (Bash), then gate with fleet-collect.sh
//   } else {
//     await parallel(files.map(f => () => agent(buildPrompt(f), { ...route('build') })));
//   }
