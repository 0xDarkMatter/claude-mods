---
name: adr-ops
description: "Author, index, and lint Architecture Decision Records — append-only memory that recovers the WHY behind a system's shape. Triggers on: adr, architecture decision record, decision log, record this decision, supersede an adr, why was this decided, adr template, next adr number."
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "git-ops, doc-scanner"
---

# ADR Ops

An **Architecture Decision Record (ADR)** captures one architectural decision: what was
decided, why, what was rejected, and what it costs. ADRs are **append-only project
memory** — they exist so a future maintainer touching a subsystem can recover the
*reasoning* behind its shape without archaeology through git history or chat logs.

This skill encapsulates a battle-tested ADR protocol and generalizes it to **any repo**.
The default location is `docs/adr/`, but every script takes `--dir` so a repo can keep
records anywhere (`docs/decisions/`, `architecture/adr/`, …).

---

## When to write an ADR

Write one when a change has **any** of these properties:

- It **constrains future options** — a boundary, an invariant, a "we will always / never
  do X" rule that later work must respect.
- **Multiple alternatives were seriously evaluated** and the choice is not obvious in
  hindsight.
- The **rationale is non-obvious from the code** — the code shows *what*, the ADR
  preserves *why*.

Write one decision per ADR. If a change bundles two separable decisions, write two.

### When NOT to write one

- A bug fix, refactor, or feature that follows existing architecture without changing it
  — that is a commit message.
- A reversible, low-stakes choice — that is a code comment.
- A point-in-time event with no forward constraint (a benchmark run, an incident
  write-up) — that is an audit/log entry, not an ADR.

> **Rule of thumb:** if someone could plausibly undo this next month without
> re-litigating a trade-off, it is **not** an ADR.

---

## Naming, location, numbering

- Path: `<adr-dir>/ADR-NNN-slug.md` (default `<adr-dir>` = `docs/adr`).
- `NNN` is zero-padded three digits, assigned **sequentially**: the next number is
  `highest existing + 1`. **Numbers are never reused, never reordered** — a superseded
  ADR keeps its number forever.
- `slug` is short kebab-case naming the subject (`oauth-only-auth`, `per-trial-container`).
- A protocol/how-to file (e.g. `00_*`) sorts above the numbered records and is **not**
  part of the sequence.

### The directory IS the index

Do **not** maintain a hand-curated numbered list as the source of truth — it drifts from
the filesystem. The authoritative list is the directory itself; `adr-index.sh` is just a
clean parse of it. Any prose list elsewhere (README, AGENTS.md) is a convenience pointer
that **may lag** and must say so.

---

## Canonical format (compact view)

Full template in `assets/ADR-template.md`; full rules in
`references/canonical-format.md`. The shape:

```markdown
---
status: accepted
date: YYYY-MM-DD
supersedes: []
superseded-by: []
touches:
  - "path/one.py"
---

# ADR-NNN: Title in Title Case

## Decision (one sentence)
<BLUF — one present-tense sentence stating the standing rule; greppable, stands alone.>

## Context
## Alternatives considered
## Consequences
### Positive / ### Negative / ### Non-goals
## See also
```

**Fixed section order:** Decision → Context → Alternatives considered → Consequences →
See also. Extra sections (Migration path, Enforcement, Implementation summary) go *after*
Consequences. For a multi-part decision, keep the one-sentence BLUF and add a
`## Decision (detail)` section lower down.

### Frontmatter fields

| Field | Required | Rule |
|---|---|---|
| `status` | yes | `proposed` / `accepted` / `superseded` / `deprecated` (lowercase). |
| `date` | yes | Decision date, `YYYY-MM-DD`. |
| `supersedes` | yes | YAML list of ADR ids this replaces (`[]` if none). |
| `superseded-by` | yes | YAML list of ADR ids that replace this (`[]` until superseded). |
| `touches` | yes | YAML list of paths / globs / config keys this governs. **Quote each.** The grep discovery surface — `grep touches:` answers "is there an ADR about the thing I'm changing?" |
| `extends` | optional | ADR ids this builds on without replacing. |
| `related` | optional | Companion ADR ids (not parents). |
| `deciders` | optional | Who made the call. |

A new field is a protocol change — record it in a new ADR, don't invent per-record keys.

---

## Status lifecycle & immutability

```
proposed ──► accepted ──► superseded   (superseded-by: [ADR-NNN])
                │
                └────────► deprecated  (withdrawn; nothing replaces it)
```

ADRs are **append-only**. Once `accepted`, you do not rewrite the Decision or Context.
Three change modes (full detail in `references/lifecycle-and-supersession.md`):

1. **Supersede** — the rule itself changes. Write a new ADR with `supersedes: [ADR-OLD]`;
   flip the old record's frontmatter to `status: superseded` + `superseded-by: [ADR-NEW]`
   in the **same commit**. Body stays intact (obsolete reasoning is itself a record).
   Supersession is **bidirectional** — a one-sided link is a lint error.
2. **Addendum** — new facts that refine an in-force decision. A dated
   `## Addendum — YYYY-MM-DD: <topic>` at the **end** of the body. Never use it to
   quietly reverse the decision.
3. **In-place edit** — typos, dead links, a renamed path in `touches:`. Preserves
   meaning; never rewrites rationale.

---

## End-to-end workflow

1. **Scaffold** the next record:
   `bash scripts/adr-new.sh --dir docs/adr --title "Your decision title"`
   (computes `NNN = highest+1`, derives the slug, fills frontmatter).
2. **Fill it in** — BLUF first, then Context, Alternatives, Consequences, See also.
   Keep `touches:` accurate; it is the discovery surface.
3. **Cross-check the number** against the directory to avoid a collision with a parallel
   session: `ls docs/adr/ADR-*.md` (or `bash scripts/adr-index.sh`).
4. **If superseding**, flip the old record's frontmatter in the **same commit** — either
   by hand or with `adr-new.sh --supersedes ADR-OLD --apply-supersede`.
5. **Lint** before committing: `python scripts/adr-lint.py --dir docs/adr`.
6. **Commit** with a `docs(adr):` conventional-commit subject, e.g.
   `docs(adr): ADR-020 — <subject>`.

Adopting ADRs in a fresh repo? Run `bash scripts/adr-init.sh --first-title "…"` once to
bootstrap the directory + a lint-clean ADR-001. Before changing an existing subsystem, run
`python scripts/adr-touching.py <path>` to surface any decision already governing it.

---

## Tools

All scripts take `--dir` (default `docs/adr`), `--help`, and follow semantic exit codes
(`0` ok, `2` usage, `3` not-found, `5` precondition, `10` findings/domain-signal). Pair
with the `git-ops` skill for the commit/PR step. The three read tools form the legs of a
stool: **lint** = integrity, **index** = overview, **touching** = "what governs this file
before I change it".

### `scripts/adr-init.sh` — bootstrap a repo adopting ADRs cold

```bash
# Create docs/adr/, scaffold a lint-clean ADR-001, write a generated README:
bash scripts/adr-init.sh --first-title "Adopt ADRs"

# Custom dir + preview without writing:
bash scripts/adr-init.sh --dir docs/decisions --first-title "OAuth-only auth" --dry-run
```

Refuses to run in a directory that already holds `ADR-*.md` (exit 5) unless `--force`. The
ADR-001 it scaffolds is rendered by `adr-new.sh`, so it lints clean immediately. The
generated `<dir>/README.md` is self-labeled "generated — do not hand-edit; the directory
is the index" and says to run `adr-index` to regenerate. `--dry-run` writes nothing.

### `scripts/adr-new.sh` — scaffold the next ADR

```bash
# Next number, slug derived from the title, frontmatter pre-filled:
bash scripts/adr-new.sh --title "OAuth-only auth"

# Custom dir + explicit slug + proposed status, preview without writing:
bash scripts/adr-new.sh --dir docs/decisions --title "Per-trial container" \
  --slug per-trial-container --status proposed --dry-run

# Supersede an old record and flip its frontmatter automatically:
bash scripts/adr-new.sh --title "Replace router" --supersedes ADR-002 --apply-supersede
```

Refuses to overwrite an existing file (exit 5). Atomic write. `--dry-run` prints the path
+ rendered content and writes nothing. `--number N` forces a specific number (backfilling
or coordination) — use sparingly; sequential `highest+1` is the discipline.

### `scripts/adr-index.sh` — the directory as a table (read-only)

```bash
bash scripts/adr-index.sh                       # number | status | date | title
bash scripts/adr-index.sh --json | jq '.data[] | select(.status=="accepted")'
```

Prefers `yq`; degrades to a built-in parser when yq is absent (announced on stderr).
Pass `--output FILE` to write a **generated Markdown index** (heading + a `do not
hand-edit` marker + the `| # | Status | Date | Title |` table) atomically to a file
instead of stdout — for a README pointer that you regenerate rather than hand-curate.

### `scripts/adr-touching.py` — what governs this file? (the discovery surface)

The `touches:` frontmatter is the grep target answering "is there an ADR about the thing
I'm changing?". This tool *is* that grep, done properly — match a path, glob, or config
key against every ADR's `touches:` list.

```bash
# Before editing src/auth.py, ask what decisions constrain it:
python scripts/adr-touching.py src/auth.py        # exit 10 if an ADR governs it
python scripts/adr-touching.py 'src/**'           # glob query
python scripts/adr-touching.py --json src/ | jq '.data[].number'
```

Matching is bidirectional and pragmatic: exact equality; fnmatch glob either direction
(touches `src/**` matches query `src/auth.py`; query `src/*` matches touches
`src/auth.py`); path-prefix containment (query `src/` governs touches `src/auth.py`, and
vice-versa); config keys (`file.yaml:key`) by exact-or-prefix.

**Guard contract (the load-bearing bit):** exit **0 = no governing ADR found**, exit
**10 = at least one ADR governs the query**. A pre-edit hook or CI step branches on it —
"heads up, ADR-010 governs this path; read it before changing." Exit `3` dir not found,
`2` usage.

### `scripts/adr-lint.py` — conformance validator

```bash
python scripts/adr-lint.py --dir docs/adr        # exit 0 clean, 10 if findings
python scripts/adr-lint.py --strict --json | jq '.data[] | select(.severity=="error")'
```

Checks required + well-typed frontmatter, the `# ADR-NNN:` title matching the filename,
the BLUF placement, core section order, **no duplicate numbers** (gaps are a warning),
and **supersession bidirectionality** (the high-value cross-file check). Plus:

- **Lifecycle consistency** (errors): `superseded` with an empty `superseded-by`;
  `deprecated` with a non-empty `superseded-by`; an in-force (`accepted`/`proposed`) ADR
  carrying a `superseded-by`. These complement the bidirectionality check without
  double-reporting.
- **Stale `touches`** (warning): a `touches:` entry that is a literal filesystem path
  (not a glob, not a config key) which no longer resolves under `--repo-root` (default:
  git toplevel, else cwd) — the discovery surface may have drifted. Warning-tier only;
  counts toward exit 10 under `--strict`.

`--strict` makes warnings count toward exit 10. Exit 4 if a file's frontmatter is
unparseable.

---

## CI integration

ADRs only stay trustworthy if the integrity contract is machine-enforced. Gate the lint
in CI; `--strict` turns the stale-`touches` drift warning into a hard signal.

```yaml
# .github/workflows/adr-lint.yml
name: adr-lint
on: [pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Lint ADRs
        run: python skills/adr-ops/scripts/adr-lint.py --strict --dir docs/adr
        # exit 10 (findings, incl. stale-touches under --strict) fails the build
```

**Local pre-commit gate:** add `python scripts/adr-lint.py --strict --dir docs/adr` to a
pre-commit hook so a one-sided supersession or a stale discovery surface is caught before
the commit lands. A pre-edit hook can additionally call `adr-touching.py <changed-path>`
and surface the governing ADR (exit 10) before a subsystem is modified.

---

## See also

- `references/canonical-format.md` — the full template, field table, and body rules.
- `references/lifecycle-and-supersession.md` — status lifecycle + the three change modes.
- `assets/ADR-template.md` — copy-ready canonical template.
