# Agent Instructions — <repo-name>

<!-- Template: assets/AGENTS-template.md (repo-doctor skill). Budget: ~150 lines,
     250 ceiling — every line is a recurring per-session token cost. Evict human
     setup walkthroughs to README/CONTRIBUTING; keep what agents need every session. -->

<2–4 lines: what this repo is, what it produces, who consumes it. Orientation, not
marketing.>

## Commands

```bash
<run command>            # start / serve
<test command>           # tests
<check command>          # the ONE gate: typecheck + lint + tests + invariant scripts
```

<!-- Commands must be exact and tested — agents trust these over exploration.
     If there's no single `check`, create one before filling this in. -->

## Landmines

<!-- MANDATORY — the highest-value section. Admission test: would a competent agent
     plausibly trip this? Each entry: what breaks, why, the procedure. Examples of the
     genre: "index.html is BAKED — edit template.html, then run build_preview.py";
     "growing any content pool invalidates three golden suites — regenerate with
     GOLDEN_UPDATE=1, procedure in docs/testing.md"; "tests OOM under default node —
     use NODE_OPTIONS=--max-old-space-size=8192". If you truly have none, write
     'None known yet — add the first one the moment it bites.' -->

1. **<landmine>** — <what breaks, why, procedure/link>

## Structure

| Path | What lives there |
|---|---|
| `<dir>/` | <one line> |

<!-- Monorepo? This table becomes the ownership table: add Contract + Gate columns
     and link each own-contract package's nested AGENTS.md
     (repo-doctor references/monorepo-structure.md §2). -->

## Conventions

- <repo-specific deltas ONLY — don't restate global rules>
- <invariants: "money is integer cents everywhere", "no Math.random in engine/">

## Pointers

- Docs index: `docs/00_INDEX.md` · Decisions: `docs/adr/` · Design: `docs/<...>`
