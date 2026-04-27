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

### Header block

A header opens a logical section. Title is cyan; trailing meta is dim.

```
── Fleet ──────────────────────────────────────────────────────  3 lanes
```

### Status table

Two- or three-column, glyph-first. No nested tables.

```
  ⏳  feat/auth-rewrite             RUNNING    12m
  ✅  fix/cache-bust                READY      2m
  🚀  chore/bump-deps               LANDED     1h
  ❌  spike/wasm                    FAILED     34m
```

### Tree

For hierarchical state — worktrees under a repo, files under a branch.

```
repo/
├─ main                           clean
├─ feat/auth-rewrite              ahead 3, dirty
└─ fix/cache-bust                 behind 1
```

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

### Before — `fleet-ops` rolling its own

```
── Fleet ──────────────────────────────────────────────────────
        BRANCH                           STATUS     AGE
────────────────────────────────────────────────────────────────
  ⏳   feat/auth-rewrite                 RUNNING    12m
  ✅   fix/cache-bust                    READY      2m
────────────────────────────────────────────────────────────────
```

### After — same skill, sourcing `_lib/term.sh`

```
── Fleet ──────────────────────────────────────────────────────  2 lanes
  ⏳   feat/auth-rewrite                 RUNNING    12m
  ✅   fix/cache-bust                    READY      2m
```

The chrome shrinks; the glyph and meta carry the structure.

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
