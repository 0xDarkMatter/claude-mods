# Skill Creation Protocol

> **The one doc to read before building a claude-mods skill.** It sequences the whole
> lifecycle — is-it-warranted → frontmatter → body → resources → tests → repo wiring →
> ship — and points to the adjacent docs that own each layer. It **restates none of
> them**: each step cites its authority and adds only the repo-specific fact that lives
> nowhere else.

**How to use this.** Read top to bottom once. Follow the steps in order; skip a step only
when there's a clear reason it doesn't apply. Where a step says "→ see X", X is the
single source of truth for that layer — go there for detail, come back here for sequence.

**Adjacent docs this protocol orchestrates:**

| Layer | Authority | Owns |
|---|---|---|
| Authoring method | `skill-creator` skill (`Skill` tool) | concrete-examples → plan → init → edit → package → iterate; description-as-trigger; progressive disclosure |
| Frontmatter fields | [SKILL-SUBAGENT-REFERENCE.md](SKILL-SUBAGENT-REFERENCE.md) | allowed top-level keys, `metadata` block, license/author rules |
| Naming & layout | [naming-conventions.md](../rules/naming-conventions.md) | `-ops` suffix, kebab-case, the three subdirs |
| Resource contract | [SKILL-RESOURCE-PROTOCOL.md](SKILL-RESOURCE-PROTOCOL.md) | scripts/assets/references: streams, exit codes, `--help`, `--json`, staleness verifier |
| Terminal output | [TERMINAL-DESIGN.md](TERMINAL-DESIGN.md) | TTY glyphs/panels via `skills/_lib/term.sh` |

When two sources disagree, **this table decides** which one wins for that layer. The
notable case: the bundled `skill-creator` says "name + description only, no other
frontmatter fields" — that is Anthropic's portable default. **In this repo,
SKILL-SUBAGENT-REFERENCE overrides it** (we require `license` + `metadata.author`).

---

## Step 0 — Is a skill warranted?

→ method: `skill-creator` Steps 1–2 (work concrete usage examples first, then plan the
reusable contents).

Repo-specific gates before you scaffold anything:

- **A skill is comprehensive operational knowledge.** If the thing is a one-line
  behavioural directive ("always prefer `uv`"), it's a **rule** (`rules/`), not a skill.
  If it's context-isolation/worker behaviour, it may be an **agent** (`agents/`). See
  [ARCHITECTURE.md](ARCHITECTURE.md) for the skill-vs-rule-vs-agent split.
- **Don't duplicate an existing skill.** Search `skills/` first; prefer extending one.
- If it is a skill, it almost certainly takes the **`-ops` suffix** (→ naming-conventions).

## Step 1 — Scaffold

→ method: `skill-creator` Step 3 (`init_skill.py`).

The skill directory MUST contain `scripts/`, `references/`, and `assets/` — create them
even if empty, with a `.gitkeep` (→ naming-conventions, "Directory Structure"). The
directory name is kebab-case and matches the frontmatter `name` exactly.

## Step 2 — Frontmatter to spec

→ authority: [SKILL-SUBAGENT-REFERENCE.md](SKILL-SUBAGENT-REFERENCE.md) — read its
"Allowed Top-Level Fields" table; it is the only legal field list.

claude-mods house rules layered on top (checklist, not a restatement):

- [ ] `license: MIT` (exception: `skill-creator` keeps its custom license)
- [ ] `metadata.author: claude-mods`
- [ ] `depends-on` / `related-skills` live **under `metadata`** as **comma-separated
      strings** — never arrays, never top-level. Omit entirely if empty.
- [ ] `name` matches the directory.

## Step 3 — Body (progressive disclosure)

→ authority: `skill-creator` ("Progressive Disclosure", "What to Not Include").

The load-bearing rules it owns: the **`description` is the trigger** (put every "when to
use" cue there, never in the body); keep the **body under 500 lines**; split detail into
`references/*.md` (one concept per file, linked from SKILL.md); **don't ship**
README/CHANGELOG/INSTALL files inside a skill.

## Step 4 — Resources (scripts / assets / references)

→ authority: [SKILL-RESOURCE-PROTOCOL.md](SKILL-RESOURCE-PROTOCOL.md) — its §10
compliance checklist is the gate for anything executable.

In one line: stdout is data-only, semantic exit codes, `--help` with an EXAMPLES section,
the first-comment-block contract, validate agent-supplied input. Every reference/asset
must be **cited from SKILL.md** or it's dead weight the router never finds. If the skill
encodes fast-moving external facts (model IDs, API params, action versions), ship the
`--offline`/`--live` **staleness verifier** (§7) so drift trips a tripwire instead of
rotting. TTY output → [TERMINAL-DESIGN.md](TERMINAL-DESIGN.md).

## Step 5 — Tests

Add `tests/run.sh` — an **offline, self-contained** behavioural suite that exits nonzero
on any failure and prints a skip message (exit 0) on unsupported platforms. Pattern after
[`skills/supply-chain-defense/tests/run.sh`](../skills/supply-chain-defense/tests/run.sh).

No registration needed: [`tests/run-skill-tests.sh`](../tests/run-skill-tests.sh) globs
`skills/*/tests/run.sh` and runs them all in CI. If the skill ships a verifier script,
also add an offline-mode assertion to [`tests/check-resources.sh`](../tests/check-resources.sh)
(PR CI, may block); its `--live` mode runs in the scheduled
[`freshness.yml`](../.github/workflows/freshness.yml), never blocking a PR.

## Step 6 — Repo integration (the doc-drift gate)

[`tests/doc-drift.sh`](../tests/doc-drift.sh) blocks CI unless docs match disk. Before you
commit:

- [ ] Add a **README skill-table row** — `skills/<name>/` must appear in `README.md` (the
      gate requires one row per skill).
- [ ] Bump the **count headers** in `README.md`, `AGENTS.md`, and `docs/PLAN.md` (skills
      total).
- [ ] Any new repo-relative markdown link must resolve (no ghost references).

## Step 7 — Validate & ship

- [ ] [`tests/validate.sh`](../tests/validate.sh) passes (frontmatter + naming).
- [ ] `claude plugin validate` passes — gate on the **official** validator, never a
      hand-rolled reimplementation.
- [ ] `skill-creator` Step 5 `package_skill.py` if a distributable `.skill` is needed.
- [ ] Commit per [commit-style.md](../rules/commit-style.md) (`feat(skills): …`).

---

## At a glance

```
0 warranted?  → skill-creator §1-2 + ARCHITECTURE (skill vs rule vs agent)
1 scaffold    → skill-creator init_skill.py; 3 subdirs (naming-conventions)
2 frontmatter → SKILL-SUBAGENT-REFERENCE (+ license:MIT, metadata.author)
3 body        → skill-creator (description=trigger, <500 lines, progressive disclosure)
4 resources   → SKILL-RESOURCE-PROTOCOL (§10 gate; staleness verifier if external facts)
5 tests       → tests/run.sh → run-skill-tests.sh; verifier → check-resources.sh
6 integrate   → doc-drift.sh: README row + count bumps + no ghost links
7 ship        → validate.sh + claude plugin validate + package + commit
```

This doc owns the **sequence and the test/CI/counts bookend**. Everything else is owned by
the adjacent doc named at each step — read that doc for depth, this one for order.
