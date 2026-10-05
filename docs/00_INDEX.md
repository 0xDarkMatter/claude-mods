# docs/ index

One line per doc: what it is and when you'd read it.

> **Maintenance:** adding, renaming or removing a top-level doc in `docs/` updates this
> table in the same commit. The subfolders are listed by role only; `ls` them for
> their contents.

## Building skills (read in this order)

| Doc | Read when |
|---|---|
| [SKILL-CREATION-PROTOCOL.md](SKILL-CREATION-PROTOCOL.md) | Building a new skill: the lifecycle in order, and which doc owns each step |
| [SKILL-SUBAGENT-REFERENCE.md](SKILL-SUBAGENT-REFERENCE.md) | Writing frontmatter, sizing a SKILL.md and its references (the size rule), or choosing skill vs subagent |
| [SKILL-RESOURCE-PROTOCOL.md](SKILL-RESOURCE-PROTOCOL.md) | A skill ships scripts, assets or references: streams, exit codes, `--help`, `--json`, the staleness verifier |
| [TERMINAL-DESIGN.md](TERMINAL-DESIGN.md) | A script prints to a TTY: panels and glyphs via `skills/_lib/term.sh` |
| [RESERVED-COMMANDS.md](RESERVED-COMMANDS.md) | Naming a skill or command: Claude Code's built-in names to avoid |

## How the pieces fit

| Doc | Read when |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Deciding between CLAUDE.md, rules, skills, agents, commands, hooks, output styles and plugins |
| [WORKFLOWS.md](WORKFLOWS.md) | Explore-plan-code-commit, TDD and the other day-to-day loops |
| [SESSION-CONTINUITY.md](SESSION-CONTINUITY.md) | Working on `/save` and `/sync`, or the session cache format |
| [AUTO-MODE-CLASSIFIER.md](AUTO-MODE-CLASSIFIER.md) | A loop or headless run is blocked or allowed by auto mode and you need to know why |
| [PLAN.md](PLAN.md) | What ships next; shipped history lives in `CHANGELOG.md` |

## Subfolders

| Folder | Holds |
|---|---|
| `plans/` | Dated build specs for a past or current work wave |
| `archive/` | Completed-migration records, kept for the reasoning; not current guidance |
| `references/` | Vendored external guides, kept as published (they may disagree with the repo's own rules, which win) |
