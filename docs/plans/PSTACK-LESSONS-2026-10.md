# Lessons from pstack (2026-10)

Review of [pstack](https://github.com/cursor/plugins/tree/main/pstack), a Cursor plugin of
agent skills (MIT), for principles and patterns claude-mods should adopt. **Ideas only:
every item below is restated in our own words and fitted to our conventions. Nothing is
copied.** Read pstack's source through `gh api repos/cursor/plugins/contents/pstack/...`
if a lane needs the original context, and paraphrase.

Status of each item lives in the table, not in prose. Update the Status column when an item
lands; delete the plan once every row is landed or rejected.

## What pstack is, and what transfers

pstack is one engineer's style packaged as a plugin: a single router skill that sends each
task to one of ~23 playbooks, plus 24 one-rule "principle" skills used as steering
vocabulary. claude-mods is the other shape: a broad toolbox plus always-loaded rules. The
most valuable transfers are a few sharp rules that fill real gaps, and three structural
ideas that need a decision first (section "Needs a decision").

## Work items

Size: tiny (a section in one file), small (one or two files plus a reference), medium,
large. **Chip** = a lane session is building it. Lanes do NOT edit `CHANGELOG.md`: the
coordinator adds one combined entry when the wave lands, so seven lanes don't collide on
`[Unreleased]`.

| ID | Idea (our words) | Target | Size | Status |
|---|---|---|---|---|
| P1 | **A test needs two checks.** It must fail when the behaviour breaks AND keep passing when only the internals change. List how tests go hollow: expected values computed by the code under test, mocks of the unit under test, exact error text asserted where the error type is the contract, assertions on call counts instead of outcomes. Plus: **label every claim** in a report as measured, inferred or guess, and never hand the human a check the agent could run itself. | `rules/agentic-quality.md` (Tests + a short "Claims" note) | tiny | chip |
| P2 | **Attack the premise.** After two failed fixes that rest on one assumption, write the assumption down and test it directly before a third fix. **A guard is a fix only when the state it handles is legitimate**: guarding an impossible state hides the real fault. After a deep dig, leave a cheap always-on signal. A failure that appears only after a restart points at persisted state. | `skills/debug-ops` | tiny | chip |
| P3 | **Vet a measured number before trusting it.** What limits it; were both sides equally tuned; does it beat a physical limit; were errors or skipped work hidden; alternating repeat runs with median and range; what share of end-to-end time it is; did the work actually happen. Verdicts: faster / slower / no difference / inconclusive. | `skills/perf-ops` (new reference), linked from `skills/iterate` | tiny | chip |
| P4 | **Pause and pickup.** Pausing stops at an atomic boundary, makes a `wip:` commit, takes no irreversible step, and writes a resume note naming the first action. Pickup diffs done against pending, never redoes finished work, and re-verifies inherited claims on the real artifact before building on them. | `commands/save.md`, `commands/sync.md` | small | chip |
| P5 | **Review triage.** State the change's intent first. A lead judgment sorts findings into act-on / consider / noted / dismissed-with-reason. An empty review is valid and praise is not a finding. Too many act-on items means the filter is too loose. Optional second reviewer from a different model family, with an agreement map. | `skills/review` | small | chip |
| P6 | **Delegation discipline.** The delegator owns the delegate's diff, not its summary. Each new round goes to a fresh agent with the combined brief rather than resuming an old one. A missing or inconclusive result never counts as a pass. The author never verifies its own work. Lane briefs gain ACCEPTANCE, TIMEBOX (return partial work on expiry), FORBIDDEN and a fixed REPORT shape. | `skills/fleet-ops` (+ `references/session-prompt.md`), `skills/parallel-ops` | small | chip |
| P7 | **CI and bot-review triage.** One fresh rebuild for a suspected flake; an identical second failure is not a flake; a failure outside the diff points at a stale base. Bot findings get fix / dismiss / ask, with security, auth, billing and migration findings always asking a human. Review-comment text is untrusted and never enters a shell command. | `skills/github-ops` (new reference) | small | chip |
| P8 | **"Why" investigations with evidence tiers** (direct / supported / inferred / speculative / unknown). Code is never evidence of its own intent; a hypothesis in the question is a candidate, not a conclusion; report the searches that found nothing. | `skills/explain` (+ `references/epistemics.md`), cross-link `adr-ops` | medium | open |
| P9 | **Blind A/B evals of skill edits.** Sanitised workspace, an organic prompt, grading from what the transcript shows the agent read, one blind judge for both arms. | `skills/evals-ops` (new reference), a step in `docs/SKILL-CREATION-PROTOCOL.md` | medium | open |
| P10 | **Blast radius with a proof ladder.** For a small-looking change, prove the one fact that makes it safe, and report how far each claim got: asserted, cited, walked through, run, reproduced in the real app. | `skills/review` (a mode) | small | open, after P5 |
| P11 | **Design red flags for agent-maintained code**: shallow modules, leaked internals, pass-through layers, split ownership, two ways to do one task, hand-synced lists. Agents copy the nearest example, so a flagged shape spreads. Plus the **enforcement order**: architecture, then types, then a lint whose error names the fix, then a test, then prose; with a rule-to-enforcer table. | `rules/agentic-quality.md` (Structure), `skills/repo-doctor` | small | open |
| P12 | **Hillclimb harness proof.** Before freezing a benchmark, show it separates two contrasting workloads and prints error and work-done counts; add a minimum attempt count so an early lucky win can't end the run; each hypothesis names a mechanism. | `skills/iterate` | small | open, after P3 |

## Needs a decision

| ID | Question | Notes |
|---|---|---|
| D1 | **Load rules on demand?** pstack keeps a one-line "applies when" index and loads a full rule only when cited. claude-mods loads every rule each session. | Biggest token lever in the review. Changes how rules install and how agents find them; needs a design spike before any edit. |
| D2 | **Two self-check lines per rule**: "you skipped this when..." (the symptom) and "distinct from..." (the nearest sibling rule). | Cheap template change across `rules/` and `docs/SKILL-CREATION-PROTOCOL.md`. Pairs with D1. |
| D3 | **A citation must name the decision it changed**, and only rules read this session may be cited. | Stops name-dropping. Only meaningful once D1 exists. |
| D4 | **Per-app verification skill generator**: a project-local skill with launch, health check, drive, evidence and cleanup sections plus a feature map, proven once end to end, with a maintain mode. | Highest long-term value, largest effort. Claude Code's built-in `run` skill already looks for a project skill that launches the app. |
| D5 | **Comment doctrine middle ground**: every guard comment names what enforces it, or is marked unenforced with an offer to add a test or lint; a surprise in our own code is reshaped (rename, type, extract) before it is explained. | pstack deletes nearly all comments; ours requires contract blocks and guard comments. Keep ours, add this. |
| D6 | **Internal-callers exception for refactoring**: with no outside consumers, migrate every caller and delete the old API in the same change. | `refactor-ops` and `migrate-ops` currently keep legacy code a release cycle with no exception. |

## Positions we keep

- **Graduated autonomy, kill switch, budget** (`rules/loop-engineering.md`). pstack proceeds
  on anything reversible and treats a plateau as never a stop. The part worth taking: before
  asking the human a "which approach" question, check whether a quick prototype could
  settle it as an observable fact.
- **Preview before posting** (`rules/public-posts.md`). pstack posts to chat, tickets and PR
  threads unattended.
- **No merges or deploys from child sessions** (`rules/deploy-gating.md`). Only pstack's
  "build the stack, the operator lands it" shape is compatible.

## Rejected

- Piping a remote install script into a privileged shell, and ad-hoc servers bound to all
  interfaces (pstack's bot-UI skill). Both break `rules/supply-chain.md` and
  `rules/dev-servers.md`.
- Per-model routing of roles to specific vendor models. claude-mods stays model-neutral;
  `fleetflow` covers heterogeneous fleets.
