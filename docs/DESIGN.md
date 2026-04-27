# Terminal Output Design Language

> Status: **experimental**. The first skill on this language is `fleet-ops`.
> New output-heavy skills should follow this guide and source `skills/_lib/term.sh`.

claude-mods ships ~70 skills, many of which write to a TTY (`fleet-ops`,
`git-ops`, `push-gate`, `sync`, ...). When you run five of them in one session
and each rolled its own glyphs and dividers, the toolkit feels like five
toolkits. This document is the forcing function: one palette, one helper
library, one shape.

## Principles

1. **Readable first, structured second, decorative last.** A pipe-friendly
   plaintext line beats a beautiful one nobody can grep.
2. **ASCII fallback is mandatory.** Every Unicode glyph has an ASCII twin.
   Honor `TERM_ASCII=1`, `LANG` without UTF-8, and `TERM=dumb`.
3. **Respect the pipe.** No color into non-TTY stdout. Honor `NO_COLOR`.
   `FORCE_COLOR=1` overrides for CI tooling that wants ANSI in logs.
4. **One screen of output preferred.** A status command should fit in 24
   lines on a default terminal. Long output earns its length.
5. **80 columns is the ceiling.** Some users still split panes. Tables that
   exceed it must wrap or truncate, not scroll horizontally.
6. **Color is signal, not skin.** Never use color as the *only* differentiator.
   Glyphs and labels carry the meaning; color amplifies.

## Glyph Palette

State icons. Use through `term_state_icon` when possible; the literals are
listed for cross-reference.

| Meaning | Unicode | ASCII | Color   | Use for                          |
| ------- | ------- | ----- | ------- | -------------------------------- |
| pending | ⏳      | `[.]` | yellow  | running, queued, in-flight       |
| ready   | ✅      | `[+]` | green   | passed, ready to land            |
| done    | 🚀      | `[*]` | green   | merged, shipped, terminal good   |
| failed  | ❌      | `[x]` | red     | tests failed, refused, blocked   |
| warning | ⚠️      | `[!]` | yellow  | conflict, hygiene flag           |
| hint    | 💡      | `[i]` | cyan    | suggestion, next-step pointer    |

> Don't introduce new state glyphs without adding them here and to
> `term_state_icon`. Improvising glyphs is what got us here.

## Box Drawing

Use sparingly — borders that wrap nothing waste lines.

| Role        | Unicode      | ASCII   |
| ----------- | ------------ | ------- |
| horizontal  | `─`          | `-`     |
| vertical    | `│`          | `\|`    |
| corners     | `┌ ┐ └ ┘`    | `+`     |
| connectors  | `├ ┤ ┬ ┴ ┼`  | `+`     |
| tree branch | `├─ └─ │`    | `+- \`- \|` |

`term_header` and `term_divider` already pick the right glyph based on
`TERM_ASCII_MODE`. Reach for them before drawing your own boxes.

## Layouts

The default layout is **rule + grouped tree**: a horizontal-line "app
header" on top, then items grouped by state with tree connectors. Flat
tables are reserved for one-row-per-thing data where grouping would just
add noise.

### Header rule (the "app header")

Always present. Title in cyan, trailing meta in dim. The rule extends to
terminal width so the header reads as the section's banner.

```
── fleet ─────────────────────────────────────────────────────  4 lanes · 3 active
```

### Grouped tree (default body)

**Tree-control rule:** the connectors `├─ │ └─` are the scaffold.
**Nothing sits at a junction.** A junction is the point where a node's
connector meets its parent's vertical — putting a glyph there breaks
the eye-line that gives the tree its meaning.

- Group headers (interior nodes — they have children below) get **no
  icon**. State is carried by the label text plus color.
- Leaves (terminal nodes — nothing continues below them) **may** carry
  an icon, since there's no vertical line to interrupt.
- If you find yourself wanting an icon on an interior node, ask whether
  it's really a group or just a decorated leaf — the answer is usually
  the latter.

#### 2-level: groups → leaves

The default for state-bucketed views (lanes, PR checks, jobs). Group
labels read as plain text, the `│` runs unbroken down column 0.

```
── fleet ─────────────────────────────────────────────────────  4 lanes · 3 active
├─  RUNNING     (2)
│  ├─ feat/auth-rewrite             12m
│  └─ spike/wasm-eval               34m
├─  READY       (1)
│  └─ fix/cache-bust                2m
└─  LANDED      (1)
   └─ chore/bump-deps               1h
```

The double space after each connector (`├─ ` + leading space on the
label) gives the eye a small breath before the label, reinforcing that
the connector is structural and the label is content.

Why grouped instead of flat: when ten lanes are in flight, scanning a
flat table for "what's actually ready to land?" forces your eyes to do
the filtering. Grouping does it for you, and the count tells you at a
glance whether the answer is none, one, or twelve.

#### 3-level: groups → branches → leaves

For hierarchies with intermediate structure — repos with branches with
files, projects with packages with tests, lanes with commits with
patches. Interior nodes (`main`, `src/`, `utils/`) stay icon-free; only
the leaves carry glyphs (state of the file).

```
── repo ──────────────────────────────────────────────────────  X:/Forge/claude-mods · 2 worktrees
├─  main
│  ├─  src/
│  │  ├─ index.ts                   ⚠️  modified
│  │  └─  utils/
│  │     ├─ format.ts               ⚠️  modified
│  │     └─ parse.ts                ✅  added
│  └─ README.md                     clean
└─  feat/auth-rewrite
   └─  src/
      ├─ auth.ts                    ✅  new
      └─  middleware/
         └─ session.ts              ⚠️  modified
```

Look at any `├─` or `└─` and trace upward: there's always a clean `│`
or empty space directly above it, never a glyph. That's the rule.

Each level adds a 3-column indent: `│  ` while the ancestor still has
siblings to render, `   ` once the ancestor is on its last sibling. The
helpers in `term.sh` (`term_tree_node`, `term_tree_indent`,
`term_tree_connector`) compose this prefix so you don't have to count
spaces.

### Flat status table (escape hatch)

When the data is genuinely flat — `git status`-style fields, a single
PR's checks — drop the tree. Glyph-first, no nested tables.

```
── push-gate ─────────────────────────────────────────────────  refusing
  ✅  secret scan        clean
  ✅  forbidden files    none
  ❌  divergence         3 ahead, 1 behind
```

The header rule still anchors the section; only the body is flat.

### Section divider

Plain rule between blocks. No title.

```
────────────────────────────────────────────────────────────────
```

### Empty state

Dim, parenthesised, single line — never a multi-line "nothing here" banner.

```
  (no lanes — run: fleet init <name>...)
```

## Colors

Color is signal layered on top of glyph and label. Strip color and the
output must still be readable.

| Color  | Meaning                                  |
| ------ | ---------------------------------------- |
| green  | success, terminal-good (READY, LANDED)   |
| yellow | pending or warning (RUNNING, CONFLICT)   |
| red    | failure (FAILED, refused)                |
| cyan   | section headers, hints                   |
| dim    | metadata: timestamps, counts, hint text  |

Disabled when stdout isn't a TTY, or `NO_COLOR` is set. Forced on with
`FORCE_COLOR=1`.

## Examples (rendered)

### Before — `fleet-ops` rolling its own (flat table, double rules)

```
── Fleet ──────────────────────────────────────────────────────
        BRANCH                           STATUS     AGE
────────────────────────────────────────────────────────────────
  ⏳   feat/auth-rewrite                 RUNNING    12m
  ✅   fix/cache-bust                    READY      2m
  🚀   chore/bump-deps                   LANDED     1h
────────────────────────────────────────────────────────────────
```

### After — rule on top, grouped tree with unbroken connectors

```
── fleet ─────────────────────────────────────────────────────  3 lanes · 2 active
├─  RUNNING     (1)
│  └─ feat/auth-rewrite             12m
├─  READY       (1)
│  └─ fix/cache-bust                2m
└─  LANDED      (1)
   └─ chore/bump-deps               1h
```

The header rule stays — strongest cue you're inside a skill's output.
Group labels are icon-free so the `│` running down column 0 is unbroken
from the first group to the last leaf. State is carried by the label
text and color (yellow for RUNNING, green for READY/LANDED). The tree
reads as a tree, not a list with decorations.

### `git-ops/status` reformatted in the same language

```
── Repo ───────────────────────────────────────────────────────  X:/Forge/claude-mods
  branch    claude/sleepy-johnson-74f19d
  HEAD      367b062 fix(skills/fleet-ops): consistent .claude/ path (2h ago)
  sync      0 ahead / 0 behind
  tree      0 staged / 2 unstaged / 1 untracked

  ⚠️   HYGIENE  main checkout on 'claude/...' — feature work belongs in worktrees
```

### `push-gate` refusal

```
── push-gate ──────────────────────────────────────────────────  refusing
  ❌   secret scan        2 hits in src/config/keys.ts
  ✅   forbidden files    none
  ✅   divergence         clean

  💡   run: gitleaks detect --source . --no-git
```

## Anti-patterns

- **Decorative emoji.** ✨📦🎉 carry no state. Keep the glyph budget for the
  six in the palette.
- **Nested tables or boxes.** A table inside a bordered box is two layouts
  fighting for the same line. Pick one.
- **Color as the only difference.** "Red row vs green row" fails for
  CI logs, screen readers, and color-blind users. Always pair with a glyph.
- **Lines past 80 columns by default.** If you genuinely need 120, gate it
  behind `--wide` or auto-detect via `tput cols`.
- **Assuming color in CI.** GitHub Actions sets `TERM=dumb`. Check.
- **Multi-line empty states.** `(no lanes)` beats a 4-line ASCII shrug.
- **New glyphs.** If your state doesn't fit pending/ready/done/failed/warn/hint,
  the state probably collapses into one of them. If it really doesn't,
  amend this document first.

## The library

`skills/_lib/term.sh` is the single source of truth for glyphs, colors,
and layout helpers. Source it, call `term_init`, then use:

```bash
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
. "$LIB/term.sh"
term_init

term_header "Fleet" "$count lanes"
term_table_row "$(term_state_icon READY)" "$branch" "READY" "$age"
term_empty "no lanes — run: fleet init <name>..."
```

The helpers no-op gracefully under `NO_COLOR`, non-TTY, and `TERM_ASCII=1`.
That's the whole contract — if you're reaching for raw `\033[` codes in a
skill, you're off the path.
