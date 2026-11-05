# Consolidation Template

The template for merging several platform docs (CLAUDE.md, WARP.md, COPILOT.md,
`.cursorrules`, ...) into one AGENTS.md.

To draft an AGENTS.md from scratch, don't start here: use the repo-doctor skill's
`scripts/agents-md.py scaffold`, which builds the draft from a sourced scan of the repo
(declared commands only, landmine questions from git history). The standard both follow
is repo-doctor's `references/agents-md-protocol.md`.

## Consolidating multiple platform docs

```markdown
# Agent Instructions - <project>

<!-- Consolidated from: CLAUDE.md, WARP.md (originals in .doc-archive/, YYYY-MM-DD) -->

<2-4 lines: what the repo is, what it produces, who consumes it>

## Commands

<the union of the sources' commands, de-duplicated; keep only ones you have run>

## Landmines

<every hazard any source mentions, as numbered entries: what breaks, why, procedure>

## Structure

<one line per folder whose name doesn't say what it holds>

## Conventions

<repo-specific deltas only; drop rules that restate global instruction files>
```

## Rules for the merge

1. **Hazards first.** Warnings scattered through the sources ("don't edit X", "always run
   Y after Z") all go under Landmines. They are the highest-value lines.
2. **Platform-specific content leaves AGENTS.md.** Claude-only instructions (plan mode for
   a path, a hook) go in a CLAUDE.md whose first line is `@AGENTS.md`. Without that
   import, Claude Code reads the CLAUDE.md instead of AGENTS.md.
3. **Human setup goes to README.** Install walkthroughs and prerequisites are for people,
   not every agent session.
4. **Stay under budget**: 150 lines target, 200 ceiling. Over that, run
   `agents-md.py audit --diff` for a split proposal.
5. **Archive, don't delete.** Move the originals to `.doc-archive/` with a date suffix and
   say so in the consolidation comment.
6. **Audit the result**: `agents-md.py audit --repo .` should exit 0 before you commit.
