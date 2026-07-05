# Agentic Quality — code, comments, and structure that survive the session

Companion to the [`repo-doctor`](../skills/repo-doctor/SKILL.md) skill (the auditor that
scores a repo against this doctrine, plus the deep references on commenting, entry docs,
and monorepo structure). This file is the *directive* — how to write code, comments,
docs, and directory structure in **every** repo, on **every** task, so the work stays
navigable by the next agent session.

## The rule

**Every artifact you produce must pass the cold-agent test: a fresh session with zero
conversation context must be able to find it, understand why it is the way it is, and
modify it without breaking an invisible constraint.** Session context dies at the end of
every conversation — the repo is the only channel to your future self. Anything that
lives only in the chat (a constraint you discovered, a format you invented, a reason you
chose the weird option) is lost unless it lands in the code, a comment, or a doc *in the
same piece of work*.

Three non-negotiables:

1. **The WHY gets written down at the site of the WHAT.** A non-obvious constraint,
   invariant, or format is documented where it lives — not in the commit message, not in
   the chat, not "later".
2. **Deliberate weirdness carries a guard comment.** Anything that *looks* refactorable
   but isn't — a single-file app, a reused buffer, a monster file with a single-writer
   rule, an odd key format — gets an explicit "why this shape" comment. The #1
   agent-specific failure mode is a future agent "improving" away a constraint it
   couldn't see.
3. **Done includes the doc touch.** A feature is not finished until the entry doc,
   index, or design doc it invalidates is updated — in the same commit or the one beside
   it. Staleness is measured in **commits-since-doc-touched**, never days.

## Why this matters

A 2026-07 audit of 10 active repos on this machine found the single best (GlyphWeb,
4.8/5) and one of the weakest (Simulacra, 3.2/5) were built by the same developer with
the same tooling in the same month. The difference was never effort — it was whether the
conventions below were *applied as-you-go* vs deferred. The recurring failures, every
one of them expensive for agents: 9,560-line files navigable only by grep; docs lagging
100+ commits behind code; idempotency-key formats with zero explanation two ADRs away
from their construction site; agents refactoring single-file apps into modules and
breaking `file://` preview because nobody wrote down why it was one file. Enforcement
beats intention, and written doctrine is the first enforcement layer.

## Comment doctrine — what goes in the code

| Layer | Directive |
|---|---|
| **Contract block** (top of file) | Every substantive source file opens with 3–12 lines: what this module is, the invariants it enforces or relies on ("crash-safe + idempotent", "the ONLY module that touches D1", "no Math.random — deterministic replay"), and cross-refs to the doc/ADR that owns the reasoning. |
| **WHY-only inline** | Inline comments state constraints, invariants, units, ranges, and reasons — never narrate what the next line does. `// order-independent so retries hash to the same key` earns its place; `// loop over the items` never does. |
| **Guard comments** | Anything deliberately "wrong-looking" gets 2–5 lines starting with the constraint: why the file is one file, why the buffer is reused, why the allocation is hoisted, why the dependency is pinned. Name what breaks if it's "fixed". |
| **Formats at the construction site** | Wire formats, cache keys, hash inputs, magic strings: document the format grammar and the reason for each component **where the string is built**, even if an ADR also covers it. |
| **Section markers** | Files over ~400 lines get `// === SECTION ===` markers and, over ~800, a top-of-file section map so an agent can jump instead of scroll. |
| **Citations** | Domain knowledge embedded in code (standards, papers, OSM way IDs, RFC numbers, spec sections) is cited inline — that's what makes domain code modifiable by a non-domain agent. |
| **Docstrings/JSDoc** | Public functions get them when the signature alone under-specifies: side effects, error behaviour, units, ordering guarantees. Private helpers with honest names don't need ceremony. |

What NOT to write: comments explaining what the code obviously does, comments addressed
to the current reviewer ("fixed per feedback"), commented-out code, TODO without an
owner-context ("TODO(cache): invalidate on rename — see #42" is fine; bare "TODO fix"
is noise).

## Entry docs — AGENTS.md is the front door

- **One `AGENTS.md` per repo, and it is the single source of truth.** It carries: what
  the repo is (2–4 lines), run/test/check commands (exact, tested), a structure map
  (folder → what lives there), conventions, and — mandatory — a **Landmines** section:
  the specific things that break non-obviously (coupled golden fixtures, generated files
  you must not hand-edit, ordering-sensitive registries). Landmines are the highest-value
  lines in the file.
- **Keep it lean.** An agent re-reads this every session; every line is a recurring
  token cost. Target under ~150 lines; push walkthroughs and rationale into `docs/` and
  link them. Setup guides for humans go in README or CONTRIBUTING, not AGENTS.md.
- **CLAUDE.md**: only as a one-line pointer to AGENTS.md (tool compatibility), or when
  there are genuinely Claude-specific deltas — and then it holds *only* the deltas,
  never a copy. If both exist, a change to a shared rule updates both in one commit.
- **Nested AGENTS.md** only where a subsystem has its own contract (a design-system
  package, an engine with determinism laws, a per-tool CLI). Nested files carry deltas
  and their own landmines; the root file links each one in an ownership table.
  Never blanket-nest — duplicated rules rot into contradictions.

## Structure — folders an agent can guess

- **Guessability is the metric**: an agent should predict where a feature lives from
  folder names alone. Feature/subsystem folders over kind-folders at scale; `src/xero/`
  beats `src/utils2/`.
- **File-size discipline**: at ~400 lines add section markers; at ~800 split by
  responsibility or write the guard comment justifying why not; a deliberately large
  file (single-writer rule) REQUIRES a top-of-file section map **and** a mechanical gate
  that enforces the invariant that justifies it (the `lint:db`/"only this module touches
  the DB" pattern — a 30-line check script makes a 9,000-line file safe).
- **Repo root is sacred**: no scratch scripts, screenshots, output artifacts, or one-off
  probes in root. Scratch work goes to the session scratchpad or `dev/`; captured
  verification images go to `docs/screenshots/`; generated artifacts are gitignored or
  clearly marked generated ("built — don't hand-edit" header).
- **Tests live where an agent looks**: colocated `test/`/`tests/` per package, named for
  the behaviour they defend. Adversarial tests are named for the adversary
  (`double-bill-nudge.test.ts`, not `billing2.test.ts`) — the name tells the next agent
  what evil the test blocks.
- **Every repo has one `check` entry point** (`npm run check`, `just check`, `make
  check`) that gates typecheck + lint + tests + the repo's invariant scripts. If it
  isn't one command, agents won't run it.

## Docs discipline — as-you-go, indexed, delegated

- **`docs/` with more than ~6 files gets an index** (`00_INDEX.md`, or a PLAN.md that
  serves the role): one line per doc — what it is, why you'd read it. Two rules that
  keep an index alive: it carries its own maintenance instruction, and volatile lists
  (ADRs, per-item inventories) are *delegated to the filesystem* ("see `ls docs/adr/`")
  instead of hand-copied.
- **Docs pair with features.** The commit that changes behaviour touches the doc that
  described the old behaviour. `docs(...)` commits interleaved with `feat(...)` commits
  is the healthy signature; a docs commit catching up 10 features later is the rot
  signature.
- **Decisions that constrain the future become ADRs** (→ `adr-ops` skill): one decision
  per record, rejected alternatives included. Everything else is a commit message or a
  code comment — don't ceremonialise.
- **Plans state their liveness.** A roadmap/PLAN.md says what's *next* and marks shipped
  phases done; history lives in CHANGELOG/git, not in the plan.

## Monorepos — structure for many-subsystem repos

The full playbook is `repo-doctor`'s [monorepo-structure reference](../skills/repo-doctor/references/monorepo-structure.md). The directives:

- **Root AGENTS.md is a router**: repo-wide invariants + an ownership table mapping
  subsystem → path → its nested AGENTS.md (if it has a contract) → its gate.
- **Each package with its own contract gets its own entry doc and its own `check`**;
  the root `check` fans out.
- **Cross-package invariants get mechanical gates, not prose** — "only X imports Y",
  "no package → app imports", "tokens only, no raw hex" are 20-line scripts, and they're
  the only reason large shared files/dirs stay safe.
- **Extraction signal**: when a subsystem grows a roadmap, an asset library, or an
  audience of its own, it's a product — extract it to its own repo before it distorts
  the host (the iso-studio/svg-studio rule).

## Self-check — before ending any turn that wrote code

- Did I introduce a constraint, format, or non-obvious choice this turn? → Is it written
  at the site (contract block, guard comment, format comment)?
- Did my change invalidate anything AGENTS.md / the docs index / a design doc says? →
  Same-commit fix.
- Did I create a file > 400 lines, or push one past 800? → Markers / split / guard.
- Did I leave anything in repo root that isn't permanent? → Move or delete.
- Would `repo-doctor` flag what I just did? When in doubt, run it.

## When to bend the rule

Scratchpad experiments, one-shot probes, and generated/vendored code are exempt — but
the moment a scratch artifact is committed to a repo, it either meets the doctrine or
carries a header saying what it is and when it can be deleted. Solo creative projects
(art, maps, one-off visualisations) may skip entry-doc ceremony, but the comment
doctrine still applies — domain-heavy code with cited sources is precisely what keeps
creative repos modifiable later.

## Cross-reference

- `~/.claude/skills/repo-doctor/SKILL.md` — the auditor: scores any repo against this
  doctrine; references own the depth (comment-doctrine, entry-docs, monorepo-structure,
  scoring-rubric).
- `~/.claude/skills/adr-ops/SKILL.md` — decision records (when-to-write rule lives there).
- `~/.claude/skills/doc-scanner/SKILL.md` — reads/synthesizes/generates entry docs;
  repo-doctor audits them.
- `~/.claude/skills/refactor-ops/SKILL.md` — the remediation path for monster files.
- `naming-conventions.md` — claude-mods component naming; this rule owns cross-repo
  code/doc quality.
