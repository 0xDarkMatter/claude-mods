# Agent Instructions - <repo-name>

<!-- Template: assets/AGENTS-template.md (repo-doctor skill). Hand-fill version; to draft
     from the repo's own facts instead, run scripts/agents-md.py scaffold.
     Budget: 150 lines target, 200 ceiling (Claude Code's documented target) - every line
     is a recurring per-session cost. Human setup walkthroughs go to README/CONTRIBUTING.
     Claude Code reads this file only if no CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md
     exists here or above; a CLAUDE.md must start with an `@AGENTS.md` import.
     Protocol: references/agents-md-protocol.md -->

<2-4 lines: what this repo is, what it produces, who consumes it. Orientation, not
marketing.>

## Commands

```bash
<run command>            # start / serve
<test command>           # tests
<check command>          # the ONE gate: typecheck + lint + tests + invariant scripts
```

<!-- Commands must be exact and run at least once - agents trust these over exploration.
     If there's no single `check`, create one before filling this in. -->

## Landmines

<!-- MANDATORY - the highest-value section. Admission test: would a competent agent
     plausibly trip this? Each entry: what breaks, why, the procedure. Examples of the
     genre: "index.html is BAKED - edit template.html, then run build_preview.py";
     "growing any content pool invalidates three golden suites - regenerate with
     GOLDEN_UPDATE=1, procedure in docs/testing.md"; "tests OOM under default node -
     use NODE_OPTIONS=--max-old-space-size=8192". If you truly have none, write
     'None known yet - add the first one the moment it bites.' -->

1. **<landmine>** - <what breaks, why, procedure/link>

## Deploy

<!-- How it ships and which branch deploys. A merge into an auto-deploying branch IS a
     deploy. Delete this section if the repo deploys nothing. -->

## Structure

| Path | What lives there |
|---|---|
| `<dir>/` | <one line - only what the folder name doesn't already say> |

<!-- Monorepo? This table becomes the ownership table: add Contract + Gate columns
     and link each own-contract package's nested AGENTS.md
     (repo-doctor references/monorepo-structure.md section 2). -->

## Conventions

- <repo-specific deltas ONLY - don't restate global rules>
- <invariants: "money is integer cents everywhere", "no Math.random in engine/">

## Pointers

- Docs index: `docs/00_INDEX.md` · Decisions: `docs/adr/` · Design: `docs/<...>`
