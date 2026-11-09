# ADR Canonical Format

The exact shape every ADR takes. Copy `assets/ADR-template.md` verbatim and fill it
in, or copy an existing accepted ADR. `adr-lint.py` enforces what is on this page.

---

## The template

```markdown
---
status: accepted
date: YYYY-MM-DD
supersedes: []
superseded-by: []
touches:
  - "path/one.py"
  - "path/two.py"
  - "config.yaml:some.key"
---

# ADR-NNN: Title in Title Case

## Decision (one sentence)

<One present-tense sentence stating the rule. This is the BLUF — it must stand
alone and be greppable. A reader who reads only this line knows what was decided.>

## Context

<The forces in play: what problem, what constraints, what made this a decision
rather than an obvious default. Enough that the decision reads as inevitable given
the context — not a coin flip.>

## Alternatives considered

<Each serious option, and the specific reason it lost. "We didn't consider any" is
a signal the change may not warrant an ADR. Omit this section only for a forced
decision with no real alternative — and say so explicitly if you omit it.>

## Consequences

### Positive
- <What this buys us.>

### Negative
- <The costs and risks we accept.>

### Non-goals
- <What this ADR deliberately does NOT decide or constrain — fences against
  scope-creep readings.>

## See also

- <Links to the enforcing code, tests, related ADRs, audits. An invariant that is
  enforced by a test should link that test — the protocol is the contract is the
  test.>
```

---

## Frontmatter fields

| Field | Required | Rule |
|---|---|---|
| `status` | yes | One of `proposed` / `accepted` / `superseded` / `deprecated` (lowercase). |
| `date` | yes | Decision date, `YYYY-MM-DD`. |
| `supersedes` | yes | YAML list of ADR ids this record replaces (`[]` if none, else `[ADR-002]`). |
| `superseded-by` | yes | YAML list of ADR ids that replace this one (`[]` until superseded). |
| `touches` | yes | YAML list of the paths / globs / config keys this decision governs. **Quote every entry.** This is the discovery surface — a future editor greps `touches:` to find "is there an ADR about the thing I'm changing?" Keep it accurate. |
| `extends` | optional | YAML list of ADR ids this record builds on without replacing. |
| `related` | optional | YAML list of ADR ids that are companions, not parents. |
| `deciders` | optional | YAML list of who made the call. |

Keep the frontmatter to these fields. A new field is a protocol change — propose it in
a new ADR rather than inventing per-record keys.

---

## Body rules

- **Title.** `# ADR-NNN: Title` — **colon separator**, Title Case, immediately after the
  closing `---` of the frontmatter (one blank line between them). Backticks for code
  identifiers in the title are fine. The `NNN` in the title MUST match the filename.
- **Decision-first (BLUF).** `## Decision (one sentence)` comes immediately after the
  title, before `## Context`. A reader skims the decision, then reads context only if
  they need the why.
- The one-sentence decision is **literally one sentence**, present tense, stating the
  standing rule (not "we decided to…" but "X routes through Y by default…").
- **Fixed section order:** Decision → Context → Alternatives considered → Consequences →
  See also. Add extra sections (e.g. `## Migration path`, `## Enforcement`,
  `## Implementation summary`) **after** Consequences when useful; never reorder the
  core five.
- **Consequences** carries three sub-headings: `### Positive`, `### Negative`,
  `### Non-goals`. Non-goals fence the record against scope-creep readings.
- **Multi-part decisions.** When the decision needs more than one sentence to specify
  (enumerated rules, a comparison table), keep the one-sentence BLUF at the top and put
  the full statement in a `## Decision (detail)` section lower down. Do not drop the
  one-sentence BLUF.

---

## Naming, location, numbering

- Path: `<adr-dir>/ADR-NNN-slug.md` (default `<adr-dir>` is `docs/adr`, configurable).
  `adr-touching.py` also reads MADR-style `NNNN-slug.md` (exactly four digits), so a repo
  that already numbers its records that way keeps its discovery surface; the other
  scripts expect `ADR-NNN-slug.md`.
- `NNN` is zero-padded three digits, assigned sequentially. **The next number is
  `highest existing + 1`. Numbers are never reused, never reordered** — a superseded
  ADR keeps its number forever.
- `slug` is short kebab-case naming the subject (`oauth-only-auth`,
  `per-trial-container`).
- A protocol/how-to file (e.g. `00_*`) sorts above the numbered records and is **not**
  part of the sequence.

### The directory IS the index

Do **not** maintain a hand-curated numbered list of ADRs as a source of truth — that
list drifts from the filesystem. The authoritative list is the directory itself:

```bash
ls <adr-dir>/ADR-*.md          # or: adr-index.sh --dir <adr-dir>
```

Any prose list of ADRs elsewhere (a README, an AGENTS.md) is a **convenience pointer
that may lag** and must say so. Because metadata lives in YAML frontmatter, a fresh
index is a clean parse — `adr-index.sh` does exactly this.
