# Terminal Panel Design System

> **Status:** Experimental. First consumer: `fleet-ops`.
>
> **Format:** Adapted from [google-labs-code/design.md](https://github.com/google-labs-code/design.md) — a structured design-spec template — and remapped to bash CLIs. Where that spec talks about screens, components, and tokens, this one talks about panels, sections, and glyphs.

---

## 1. Vision

A unified terminal-output design language for bash-based CLIs in the claude-mods family. One panel grammar, one set of glyphs, one grid. Tools that follow it feel like instruments on the same workbench instead of seventy hand-rolled formats.

The aspiration: outputs that read as **deliberate, bespoke, and quiet** — like a well-laid PCB. Every glyph in its place, nothing decorative, nothing shouting. When a user runs five tools in a session, the toolkit feels coherent.

---

## 2. Principles

1. **Information first, ornament last.** Decoration that doesn't carry meaning gets cut.
2. **Strip color and the layout still works.** Color amplifies; it never carries the only signal.
3. **ASCII fallback is mandatory.** Every Unicode glyph has a 1–3 char ASCII proxy registered alongside it.
4. **Use the invisible grid, not lines, to align.** Whitespace between columns aligns rows. Long horizontal rules are clutter.
5. **Tether to the left.** Primary content rides the left rail. Right-side elements are leaves or iconography, never floating UI.
6. **Let elements breathe.** Blank `│` rows between sections are content. Density without breath is unreadable.
7. **Pops of color are dopamine; everywhere is wallpaper.** One brand emoji in the header, two health indicators in the footer, color on state words. That's the budget.
8. **Borders are continuous.** Top and bottom rules run uninterrupted from corner to terminator. Gaps break the panel's "wrap the interface" feel.
9. **One style per diagram.** Pick rounded corners, stick with rounded corners. Don't mix box families.
10. **Same width, taller height for emphasis** — never wider. Width consistency is what makes columns line up; height variation gives presence without breaking the grid.
11. **Bespoke, not branded.** No ASCII art logos. No flashy gradients. The polish is in placement and restraint.

---

## 3. Foundations

### 3.1 Color tokens

Color is signal, never the only signal. Disabled when stdout isn't a TTY or `NO_COLOR` is set; forced on with `FORCE_COLOR=1`.

| Token         | ANSI    | Use for                                                  |
| ------------- | ------- | -------------------------------------------------------- |
| `accent`      | cyan    | Brand chrome (panel rules, hotkey letters, header rule)  |
| `pending`     | yellow  | RUNNING, CONFLICT, modified files, HEAD marker           |
| `ok`          | green   | READY, LANDED, healthy daemon, landed commits            |
| `alarm`       | red     | FAILED, blocked, conflicts, critical health              |
| `warn`        | orange  | Warning alerts, the inline alert triangle                |
| `tag`         | magenta | Untracked files (lazygit/magit convention)               |
| `meta`        | dim     | Counts, ages, base branch, timestamps, dotted leaders    |
| `default`     | fg      | Branch names, file paths — the content the user came for |

### 3.2 Glyph palette

Every glyph below is registered with an ASCII fallback in `term.sh`. Don't introduce new ones without registering them.

#### Panel and tree connectors

| Role              | Unicode | ASCII   | Notes                                   |
| ----------------- | ------- | ------- | --------------------------------------- |
| corner: panel TL  | `╭`     | `+`     | Rounded — for the outer panel only      |
| corner: panel TR  | `╮`     | `+`     | Rounded                                 |
| corner: panel BL  | `╰`     | `+`     | Rounded                                 |
| corner: panel BR  | `╯`     | `+`     | Rounded                                 |
| T-junction        | `├`     | `+`     | Section attachment point                |
| L-corner          | `└`     | `` ` `` | Last leaf in a section                  |
| horizontal        | `─`     | `-`     | Rule fill                               |
| vertical          | `│`     | `\|`    | Panel left edge, section continuation   |

#### Rail glyphs (commit-graph and pipeline beads)

| Role               | Unicode | ASCII | Meaning                          |
| ------------------ | ------- | ----- | -------------------------------- |
| commit (landed)    | `●`     | `*`   | a commit on the rail             |
| HEAD               | `◉`     | `@`   | tip of the lane                  |
| conflict           | `⊗`     | `X`   | rebase / merge failure point     |
| link               | `─`     | `-`   | rail segment between commits     |

#### Pip-bar glyphs (progress / completion)

| Role       | Unicode | ASCII |
| ---------- | ------- | ----- |
| pip filled | `▰`     | `#`   |
| pip empty  | `▱`     | `-`   |

Default width: **10 pips** = clean 10% increments. Override only when the data has a natural denominator that isn't a percentage (`5 of 7 stages` → 7 pips).

#### Health indicators (small bullets, colored)

| Role     | Unicode | ASCII   | Notes                                   |
| -------- | ------- | ------- | --------------------------------------- |
| healthy  | `•`     | `(+)`   | Green, slowly pulsing in live mode      |
| pending  | `•`     | `(.)`   | Yellow                                  |
| warning  | `•`     | `(!)`   | Orange                                  |
| critical | `•`     | `(!!)`  | Red                                     |
| busted   | `⬤`     | `(X)`   | LARGE grey, motionless — unmissable     |
| unknown  | `•`     | `(?)`   | Dim                                     |

`•` (BULLET, U+2022) is smaller than `●` and reads as a tidy dot when colored. `⬤` (BLACK LARGE CIRCLE, U+2B24) is intentionally bigger to make a busted state unmissable.

#### The terminator dot

`●` is reserved as the right-edge terminator on header and footer rules. **Never** used as an inline divider, decorator, or health indicator. One job, one place.

#### Brand emoji registry

| Tool   | Unicode | ASCII |
| ------ | ------- | ----- |
| fleet  | ⚡       | `[F]` |
| forge  | 🔨       | `[B]` |
| psql   | 🐘       | `[P]` |
| watch  | 📡       | `[M]` |
| deploy | 🚀       | `[D]` |
| git    | 🌿       | `[G]` |

#### Header indicators

| Role            | Unicode | ASCII | Use for                            |
| --------------- | ------- | ----- | ---------------------------------- |
| branch          | `⎇`     | `(b)` | `⎇ main` — base branch indicator   |

#### Inline alert

| Role     | Unicode | ASCII | Color  |
| -------- | ------- | ----- | ------ |
| warning  | `▲`     | `!`   | orange |
| critical | `▲`     | `!`   | red    |

#### Empty state

| Role | Unicode | ASCII |
| ---- | ------- | ----- |
| tip  | `💡`     | `(i)` |

#### Spinners (live mode only)

Three families, each with a different role:

**Working** — task actively progressing. Fast, 10 frames, ~80ms/frame.
```
⠋  ⠙  ⠹  ⠸  ⠼  ⠴  ⠦  ⠧  ⠇  ⠏
```
ASCII fallback: `|  /  -  \` (classic 4-frame).

**Heartbeat** — daemon proof-of-life. Slow, 6 frames, ~600ms/cycle.
```
·  ∙  •  ●  •  ∙
```
ASCII fallback: `.  :  *  :`. Used in the footer health-indicator slot. Stops and goes grey when the daemon is busted.

### 3.3 Spacing & the invisible grid

Layout is built on whitespace alignment, not vertical bars. The grid for a leaf row in a panel:

```
[panel-vert] [section-indent] [tree-conn] [name-col]  [rail-col]    [meta-col]   [age-col]
     │            ····             ├──     32 chars    14 chars     12 chars     6 chars
```

- **Panel vertical** — column 0, the panel's `│`.
- **Section indent** — 4 cols of breathing room inside the panel.
- **Tree connector** — `├──` or `└──` (4 cols including trailing space).
- **Name column** — 32 cols, ellipsis-truncated past that (`feat/oauth-pkce-with-very-long…`).
- **Rail column** — 14 cols, right-padded with spaces to align the next column.
- **Meta column** — 12 cols (e.g., `M4 ?1`, `clean`, `blocked`).
- **Age column** — 6 cols, right-aligned.

These widths target an **80-col default**. They scale: a `--wide=120` mode bumps name to 48 and rail to 20. They never exceed terminal width — at <60 cols, drop the rail and meta columns rather than wrap.

Section rows ride the same indent: `│   ` (panel + 3 spaces) to land at the section-indent column.

---

## 4. Components

### 4.1 Panel

The outer frame: header bar, body, footer bar. The body is wrapped by the panel's `│` running unbroken from `╭──` down to `╰──`.

```
╭── ⚡ fleet ─────────────────────────────────  ⎇ main ───●
│
[body]
│
╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
```

**Rules**
- Top rule starts at column 0 with `╭──`, ends at the right with terminator `●`.
- Bottom rule mirrors with `╰──` and a terminator.
- The rules have no whitespace gaps. `─` fills every span between elements.
- Body lives between the rules; every body line begins with `│`.

**Helper:** `term_panel_open` / `term_panel_close`.

### 4.2 Header bar

```
╭── ⚡ fleet ─────────────────────────────────  ⎇ main ───●
   └┬─┘ └─┬─┘                                  └──┬──┘ └┬┘
    │    │                                        │     └─ terminator
    │    └─ tool name (cyan)                      └─ right indicator (≤ 1)
    └─ brand emoji (always before name)
```

**Rules**
- **Brand emoji + tool name** at top-left, in that order, always. The emoji *is* the tool's identity at a glance.
- **One indicator** at top-right max — typically a context tag (`⎇ main`, `db: production`, `region: us-east`). Format: `<icon> <value>` or `key: value` in dim.
- The rule (`─`) fills every gap between brand and indicator and indicator and terminator.

**Helper:** `term_panel_open <emoji_key> <name> <indicator>`.

### 4.3 Footer bar

```
╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
   └─────────┬──────────┘             └────┬─────┘     └┬┘
             │                             │            └─ terminator
             │                             └─ health indicators (≤ 2)
             └─ hotkeys (≤ 3)
```

**Rules**
- **Up to 3 hotkeys** at bottom-left, format `<key> <verb>`, separated by `·`. Hotkey letters in cyan.
- **Up to 2 health indicators** at bottom-right, format `• <text>`. **Two spaces** between indicators (no `·` separator — `•` is already a strong leading marker).
- Continuous rule `─` fills the gap between hotkeys and health.
- `●` terminator at far right.

**Helper:** `term_panel_close <hotkeys> <healths>`.

### 4.4 Section

A grouped block under the header. Section labels are colored by state; no glyph at the junction, no trailing rule.

```
├── RUNNING (2)
│   ├── feat/oauth-pkce       ●─●─●─◉      M4 ?1      12m
│   └── spike/wasm-eval       ●─●─●─●─◉    M7         34m
│
├── READY (2)
│   ├── fix/cache-bust        ●─◉          clean       2m
│   └── chore/bump-axios      ●─◉          clean       5m
```

**Rules**
- Section header: `├── LABEL (count)`, label colored by state.
- No icon at the junction. State is carried by the **label color** plus the **label text**.
- One blank `│` row of breath between sections — never zero, never two.
- Empty sections are omitted; never render `(0)`.

**Helper:** `term_section <state> <label> <count>`.

### 4.5 Summary line

A metadata-only branch of the panel. Tethers to the left rail like a section but renders in dim because it's reference, not actionable.

```
├── 4 lanes · 3 active
```

**Rules**
- Same `├──` connector as a section.
- No count in parens (it's a label, not a bucket).
- Rendered dim throughout so it visually recedes below the colored state sections.
- One blank `│` row above and below.

### 4.6 Toast row

A transient announcement at the top of the body, just under the header rule.

```
╭── ⚡ fleet ──────────────────────────────────  ⎇ main ───●
│
├── ⚡ feat/oauth-pkce just LANDED              ← toast: dim cyan, fades
│
├── 4 lanes · 3 active
```

**Rules**
- **At most one toast** at a time. Older toasts get replaced, not stacked.
- Brand emoji leads the toast — reinforces "this is fleet news."
- Color: dim cyan on the leading emoji, default fg on the message.
- Lifetime: until next render in static mode; ~3s in live mode.

### 4.7 Inline alert

A sub-row attached under a leaf, drawing attention without disrupting structure.

```
│   ├── feat/audit-log        ●─●─⊗        blocked    17m
│   │   ▲ rebase against main failed at 4ff21e6
│   └── feat/oauth-pkce       ●─●─●─◉      M4 ?1     12m
```

**Rules**
- Sub-row only — never replaces the leaf headline.
- `▲` triangle leads the message, colored by severity:
  - orange = warning, recoverable
  - red = critical, blocks progress
- Indented under the leaf's `│` continuation (column 8 in the standard grid).
- ASCII fallback: `!`.

### 4.8 Leaf

A single row inside a section. The atomic unit of content.

```
│   ├── feat/oauth-pkce       ●─●─●─◉      M4 ?1      12m
    └┬─┘ └────────┬────────┘  └───┬───┘    └──┬──┘    └┬┘
     │            │               │           │        └─ age (right-aligned)
     │            │               │           └─ meta (file-status shorthand)
     │            │               └─ leaf glyph (one style only)
     │            └─ name (ellipsis-truncate at column boundary)
     └─ tree connector (├── except last sibling = └──)
```

**Rules**
- **Choose one leaf glyph style per panel.** Rail (`●─●─◉`) for git-style data. Pip bar (`▰▰▰▱`) for percentage-style. Don't mix in the same panel.
- **All columns conform to the grid.** The rail/pip column is fixed-width and right-padded; meta and age land in their own columns.
- **Health/icon indicator on a leaf goes at the START** of the row, before the name — only when the indicator is *useful* on a per-leaf basis (typically only in flat / ungrouped views — in grouped views the section already conveys state).
- **Long names ellipsis-truncate** at the name column boundary: `feat/oauth-pkce-with-very-long…`. Don't word-wrap in the body — wrapping breaks the grid.

**Helper:** `term_leaf <name> <rail_or_pips> <meta> <age>`.

### 4.9 Rail (commit / pipeline graph)

```
●─●─●─◉      a 3-commit lane with HEAD
●─●─●─●─◉    a 4-commit lane
●─◉          1 commit ahead
●─●─⊗        conflict at the third commit
─            empty rail (queued, no commits yet)
```

**Rules**
- Use only on leaves whose data is naturally a chain (commits, pipeline stages).
- Right-pad to the rail column width so subsequent columns align.
- HEAD marker (`◉`) is always last; conflict marker (`⊗`) replaces HEAD at the failure point.

**Helper:** `term_rail <commits_ahead> <head_state>`.

### 4.10 Pip bar (progress / completion)

#### Anatomy

```
▰▰▰▱▱▱▱▱▱▱   30%
└─┘└──────┘
filled  empty
state-color  dim
```

- **Default width: 10 pips.** Clean 10% increments, easy mental math.
- **Override only for natural denominators** that aren't percentage (`5 of 7 stages` → 7 pips).
- **Filled pip color** = state color (depends on metric type, see below).
- **Empty pip color** = dim grey, always.

#### Color by metric type

The filled-pip color depends on what the metric *means*. Three families:

**A. Progress** — work in motion, more = closer to done.
```
▰▰▰▱▱▱▱▱▱▱   30%  running build         yellow  (in-flight)
▰▰▰▰▰▰▰▰▰▰  100%  build done            green   (terminal good)
```

**B. Score / pass rate** — static measurement, more = better.
```
▰▰▱▱▱▱▱▱▱▱   20%  test pass rate        red     (alarm)
▰▰▰▰▰▱▱▱▱▱   50%  test pass rate        yellow  (warn)
▰▰▰▰▰▰▰▰▱▱   80%  test pass rate        green   (ok)
```
Thresholds: <33% red, <66% yellow, ≥66% green. Override per-skill.

**C. Capacity / load** — utilization, more = worse (heading toward limits).
```
▰▰▱▱▱▱▱▱▱▱   20%  disk used             green   (plenty of room)
▰▰▰▰▰▰▰▱▱▱   70%  disk used             yellow  (warn)
▰▰▰▰▰▰▰▰▰▱   90%  disk used             red     (alarm)
```
Thresholds: <60% green, <80% yellow, ≥80% red. Override per-skill.

**Helpers:**
```bash
term_pip_bar progress  n total          # type A
term_pip_bar score     n total          # type B
term_pip_bar capacity  n total          # type C
```

The metric type drives color selection. Skills don't pick a color directly — they pick the *kind* of measurement and the helper does the right thing.

### 4.11 Health indicator

A colored bullet followed by descriptive text. Lives in the footer's bottom-right slot (≤ 2 per panel) or at the start of a leaf when needed.

```
• daemon         healthy   (green pulsing)
• 17m idle       slow / pending  (yellow)
• lagging        warning  (orange)
• down           critical  (red)
⬤ daemon         busted    (large grey, static)
```

**Rules**
- `•` (small bullet) leads the text, single space between.
- `⬤` (large) replaces `•` only when the system is *busted* — visually unmissable.
- Text is short — 1–3 words max.
- Color of the bullet must match the semantic meaning.
- Two spaces between consecutive indicators — no `·` separator (the bullet is a strong enough lead).

**Helper:** `term_health <state> <text>`.

### 4.12 Hotkey hint

```
R refresh
L land
? help
```

**Rules**
- Single key (or modifier+key like `^C`) followed by a verb.
- Letters in cyan.
- Up to 3 in the footer; dropdown to a `?` help screen if more are needed.
- Separated by `·` in the rendered footer (the dot disambiguates adjacent letter+verb pairs).

**Helper:** `term_hotkey <key> <verb>`.

### 4.13 Count

Always `(n)`. Bare numbers belong in prose; counts in `()` belong in chrome.

```
RUNNING (2)
4 lanes · 3 active        <- prose, no parens
```

### 4.14 Spinner

Live-mode component. Replaces a single glyph in place as it cycles through frames.

- **Working** spinner cycles `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` at ~80ms/frame on rows whose work is in progress (replaces the leaf glyph during the operation).
- **Heartbeat** spinner cycles `· ∙ • ● • ∙` at ~600ms/cycle on the daemon health indicator. Stops and turns into a static grey `⬤` when the daemon is busted.

**Helper:** `term_spinner_frame working|heartbeat tick` returns the glyph for tick `n`.

---

## 5. Patterns

### 5.1 Grouped tree (default)

The default for state-bucketed data. One panel, summary line, then state-grouped sections, each with leaves.

```
╭── ⚡ fleet ─────────────────────────────────  ⎇ main ───●
│
├── 4 lanes · 3 active
│
├── RUNNING (2)
│   ├── feat/oauth-pkce       ●─●─●─◉      M4 ?1      12m
│   └── spike/wasm-eval       ●─●─●─●─◉    M7         34m
│
├── READY (2)
│   ├── fix/cache-bust        ●─◉          clean       2m
│   └── chore/bump-axios      ●─◉          clean       5m
│
├── CONFLICT (1)
│   └── feat/audit-log        ●─●─⊗        blocked    17m
│
╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
```

**When to use:** state matters more than time. Most CLIs.

### 5.2 Flat rail (alternate)

Same atoms, no grouping. Sorted by age. State moves to a per-leaf indicator at the start.

```
╭── ⚡ fleet ─────────────────────────────────  ⎇ main ───●
│
├── 4 lanes · 3 active
│
│   • fix/cache-bust         ●─◉          clean       2m
│   • chore/bump-axios       ●─◉          clean       5m
│   • feat/oauth-pkce        ●─●─●─◉      M4 ?1      12m
│   • feat/audit-log         ●─●─⊗        blocked    17m
│   • spike/wasm-eval        ●─●─●─●─◉    M7         34m
│
╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
```

**When to use:** chronological or activity-sorted views (`fleet --flat`).

### 5.3 Status panel (no tree)

For genuinely flat data — a PR's checks, a service's health summary. No sections, no tree connectors, just leaves under the panel `│`.

```
╭── ⚡ push-gate ───────────────────────────  refusing ───●
│
│   ✓  secret scan
│   ✓  forbidden files
│   ✗  divergence              3 ahead, 1 behind
│
╰── R retry · ? help ─────────────── • blocking ───●
```

### 5.4 Multi-panel stacking

For dashboards — fleet next to git status, build output next to test output. Side-by-side is **not** supported (column arithmetic doesn't survive); panels stack vertically.

```
╭── ⚡ fleet ───────────────────────────  ⎇ main ───●
│
├── RUNNING (2)
│   └── feat/oauth-pkce      ●─●─●─◉    12m
│
╰── R · L · ? ──── • daemon ───●


╭── 🌿 git ─────────────────────────────  ⎇ main ───●
│
├── HEAD (3 ahead, 0 behind)
│   └── 367b062  fix(skills): consistent path  ●─◉  2h
│
╰── s · c · ? ──── • clean ───●
```

**Rule:** exactly **2 blank lines** between stacked panels. The terminator `●` and the opening `╭──` get to breathe; less than that they cling, more than that they drift apart.

### 5.5 Help screen

The `?` hotkey in every footer leads here. Same panel grammar, different content shape.

```
╭── ⚡ fleet · help ────────────────────────────  ⎇ main ───●
│
├── commands
│   ├── R refresh     re-read lane state from disk
│   ├── L land        merge a READY lane into base
│   ├── F flat        switch to rail view, sorted by age
│   └── ? help        you are here
│
├── concepts
│   ├── lane          a branch managed by fleet
│   ├── base          the trunk lanes merge into (default: main)
│   └── daemon        background poller; auto-lands READY lanes
│
╰── q quit ─────────────────────── • v2.4.9 ───●
```

The header gets `· help` after the tool name. Title is contextual; everything else is the same panel.

### 5.6 Empty state

A whole panel when there's nothing to show. Empty states earn extra whitespace and become tutorials.

```
╭── ⚡ fleet ──────────────────────────────────  ⎇ main ───●
│
│
│   no lanes yet
│
│
│   💡 to get started:
│
│      1. fleet init feat/foo bar      create branches + worktrees
│      2. (work in each lane)          commits, tests
│      3. fleet start                  run the daemon
│
│
╰── ? help ─────────────────────────── • v2.4.9 ───●
```

**Rules**
- Empty state body uses **flat indented content** (no leaf tree connectors). Empty states are welcome posters, not data trees, so they get to break the tree convention.
- The trunk `│` still tethers everything left.
- 💡 emoji leads the "to get started" tip line.
- 2 blank `│` rows above and below each block (vs. 1 in non-empty panels).
- Footer drops to a single hotkey (`? help`) and a single status indicator (typically version).

---

## 6. Edge cases

### 6.1 Long titles / names

Ellipsis-truncate at the name-column boundary. Don't word-wrap in the body.

```
│   ├── feat/oauth-pkce-with-very-l…  ●─●─●─◉      M4 ?1      12m
│   └── chore/bump-axios               ●─◉          clean       5m
```

The full name is recoverable via `--wide` or the verbose view. Truncation preserves the grid.

### 6.2 Narrow terminals (<60 cols)

Drop columns from the right, in order: age → meta → rail. The leaf collapses to:

```
│   ├── feat/oauth-pkce
│   └── spike/wasm-eval
```

Never wrap. Wrapping breaks the grid; truncation just hides data.

### 6.3 ASCII fallback (`TERM_ASCII=1`, non-UTF locale, `TERM=dumb`)

Every glyph has a registered ASCII proxy:

```
+-- [F] fleet -------------------------------- (b) main ---*
|
+-- 4 lanes · 3 active
|
+-- RUNNING (2)
|   +-- feat/oauth-pkce       *-*-*-@      M4 ?1      12m
|   `-- spike/wasm-eval       *-*-*-*-@    M7         34m
|
+-- READY (2)
|   +-- fix/cache-bust        *-@          clean       2m
|   `-- chore/bump-axios      *-@          clean       5m
|
+-- CONFLICT (1)
|   `-- feat/audit-log        *-*-X        blocked    17m
|
`-- R refresh · L land · ? help ---- (+) daemon  (.) 17m ---*
```

Same skeleton. Rounded corners (`╭ ╰`) collapse to `+`. Rail dots (`● ◉ ⊗`) become `* @ X`. Health bullets (`•`) become `(+) (.) (!)`. The grid survives.

### 6.4 NO_COLOR

Strip every ANSI sequence. The structure (glyphs, grid, indentation) carries 100% of the information. Verify: `NO_COLOR=1 fleet` should be unambiguous.

### 6.5 Rendering context

Panels and diagrams render only in monospace contexts with verbatim whitespace. There are exactly two:

- **TTY output** — automatic. The canonical target.
- **Fenced code blocks in any markdown** — ideal. Locks monospace, preserves the grid pixel-for-pixel. Use this in README, CHANGELOG, design docs, GitHub issues, anywhere markdown is rendered.

Never paste unfenced. Markdown's `|` is table syntax; box-drawing collapses; whitespace compresses; the panel renders as visual nonsense. If a panel needs to live in prose, fence it.

---

## 7. Anti-patterns

- **Long horizontal rules in the body** (`──────────── 🟡`). Decorative clutter; use whitespace to separate sections instead.
- **Glyphs at tree junctions.** A glyph between `├──` and the parent's `│` breaks the eye-line of the tree.
- **Mixing leaf glyph styles in one panel.** Rail and pips together looks like two languages fighting.
- **Floating right-side UI.** Anything important tethers to the left rail. Right side is for leaves and small iconography (terminator dot, base-branch tag) only.
- **More than one brand emoji per panel.** ⚡ in the header earns its keep. ⚡ next to every "running" lane is wallpaper.
- **Using `●` as decoration.** Reserved for header/footer terminators. If you need a small marker elsewhere, use `•` (bullet, smaller) or pick a different shape (`◉ ◐ ◇ ▰ ⬢`).
- **Bare numbers in chrome.** `RUNNING 2` is prose. `RUNNING (2)` is a count. Counts in chrome wear parens.
- **Word-wrapping leaf rows.** Breaks the grid. Truncate with `…` instead.
- **Section headers with `(0)`.** Empty sections are omitted, not rendered.
- **Color-only state differentiation.** Red row vs green row fails on `NO_COLOR`, screen readers, and printouts. Always pair color with text or shape.
- **Wider boxes for emphasis in diagrams.** Breaks column alignment. Use taller, same width.
- **Multiple corner families in one diagram.** Pick rounded, stick with rounded.

---

## 8. Reference example

```
╭── ⚡ fleet ─────────────────────────────────  ⎇ main ───●
│
├── 4 lanes · 3 active
│
├── RUNNING (2)
│   ├── feat/oauth-pkce       ●─●─●─◉      M4 ?1      12m
│   └── spike/wasm-eval       ●─●─●─●─◉    M7         34m
│
├── READY (2)
│   ├── fix/cache-bust        ●─◉          clean       2m
│   └── chore/bump-axios      ●─◉          clean       5m
│
├── CONFLICT (1)
│   └── feat/audit-log        ●─●─⊗        blocked    17m
│
╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
```

Color map:
- `╭── ─ ╰──` panel chrome: cyan (accent)
- `⚡` brand emoji: as-is (yellow rendering)
- `fleet`: cyan
- `⎇ main`: dim
- `4 lanes · 3 active`: dim
- `├── │ └──`: dim cyan (recede)
- `RUNNING`, `CONFLICT`: yellow (pending)
- `READY`: green (ok)
- `(2)`: dim
- branch names: default fg
- `●─●─●` (landed): green; `◉` (HEAD): yellow; `⊗` (conflict): red
- `M4`: yellow; `?1`: magenta; `clean`: dim green; `blocked`: red
- `12m`: dim
- `R`, `L`, `?`: bright cyan; verbs: default
- `•` (healthy): green, pulsing in live mode
- `●` terminators: cyan

---

## 9. Implementation — `skills/_lib/term.sh`

The library is the single source of truth. Skills source it; nothing else needs to know about glyphs or colors.

```bash
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
. "$LIB/term.sh"
term_init
```

### Helpers

```bash
# Foundations
term_init                                # detect TTY, NO_COLOR, TERM_ASCII, set globals
term_color name "text"                   # green/yellow/red/cyan/dim/orange/magenta wrap
term_emoji key                           # registered glyph + ASCII fallback

# Components
term_panel_open  emoji_key name [right_indicator]
term_panel_close [hotkeys] [health_indicators]
term_summary_line "text"                 # "├── 4 lanes · 3 active" (dim)
term_section     state label count       # "├── LABEL (n)"
term_leaf        name leaf_glyph meta age
term_toast       emoji_key "text"        # toast row
term_alert       severity "text"         # ▲ inline alert sub-row

# Leaf glyph builders (pick one per panel)
term_rail        commits_ahead head_state    # ●─●─●─◉ / ●─●─⊗
term_pip_bar     metric_type filled total    # progress / score / capacity

# Right-side furniture
term_health      state text              # • daemon (colored, with ⬤ for busted)
term_hotkey      key verb                # R refresh

# Live mode
term_spinner_frame family tick           # working / heartbeat → glyph

# Edge cases
term_truncate    "text" max_cols         # ellipsis-truncate
term_term_width                          # current cols
```

### Registries

Centralized at the top of `term.sh`, sourced into associative arrays:

```bash
declare -A TERM_BRAND=(
  [fleet]="⚡|[F]"
  [forge]="🔨|[B]"
  [psql]="🐘|[P]"
  [watch]="📡|[M]"
  [deploy]="🚀|[D]"
  [git]="🌿|[G]"
)

declare -A TERM_HEALTH=(
  [healthy]="•|(+)"
  [pending]="•|(.)"
  [warning]="•|(!)"
  [critical]="•|(!!)"
  [busted]="⬤|(X)"
  [unknown]="•|(?)"
)

declare -A TERM_DIAGRAM_ICON=(
  [user]="👤|(U)"
  [web]="🌐|(W)"
  [mobile]="📱|(M)"
  [auth]="🔐|(A)"
  [database]="🗄|(D)"
  [cache]="⚡|(C)"
  [queue]="📨|(Q)"
  [storage]="📦|(P)"
  [service]="⚙|*"
  [api]="🔌|(I)"
  [search]="🔍|(S)"
  [timer]="⏱|(T)"
  [build]="🔨|(B)"
  [hook]="🪝|(H)"
  [log]="📄|(F)"
)
```

Adding a tool means one row. Adding a state means one row. No hardcoded escape sequences in skills.

---

## 10. Open questions

- **`--wide` mode.** Should claude-mods skills auto-detect `tput cols >= 120` and widen the grid, or always default to 80? Lean toward always-80 unless user opts in.
- **Animation framework.** Spinners and live-updating panels (`fleet --watch`). The static-output spec is clear; a live mode would need a separate component family covering frame timing and partial redraws.
- **Sub-panels.** A `verbose` view could nest a sub-panel per leaf. Not covered yet — defer until two skills genuinely need it.
- **Accessibility audit.** Verify the panel reads coherently to screen readers when piped through `aspell` or similar. The "structure carries information" principle should hold; needs proof.

---

## 11. Diagrams

The panel grammar handles lists and trees. For relationships — services talking to each other, state transitions, decision flows, timelines — diagrams take over. Same grid, same glyph palette, same color tokens; just different compositions.

Diagrams render in code-fenced blocks (TTY or markdown); they are otherwise subject to the same rules as panels (§6.5). They may stand alone in docs or live inside a panel as body content.

### 11.1 Foundations

- **Grid**: cells are 1 char wide. Connections are orthogonal — horizontal `─` and vertical `│` only. Diagonals (`\` `/`) read poorly in monospace; don't use them.
- **One corner family per diagram**: rounded `╭ ╮ ╰ ╯` is the canonical choice for diagrams in this system. Mix rounded with light corners (`┌ └`) only inside layered stacks (§11.5).
- **Colors**: same tokens as panels. State words wear their state colors inside diagrams too.

### 11.2 Box anatomy

Every box in a diagram follows the same construction rules.

#### Width

`width = max(label_with_icon) + 4`

The longest label on the page (icon + space + text) plus 4 cells of padding (3 left, 1 right). All boxes on the same diagram are this width — alignment is the price of admission.

#### Height

- **Standard**: 1 content row (3 lines total: top corner, label, bottom corner).
- **Emphasis**: 3 content rows (5 lines total: top corner, blank, label, blank, bottom corner). Same width, taller height — never wider.

#### Label position

Top-anchored, right-aligned, **1-char right padding**.

```
╭──────────────╮
│       🌐 web │     ← label hits "1-char-from-right"; left side absorbs slack
╰──────────────╯
```

Left padding = `width − label_cells − 1 − 2` (corners). The constant 1-char right pad is what makes labels visibly right-anchored across boxes with mixed icon/no-icon content.

Cell-width counting: emoji = 2 cells; standard glyphs and ASCII chars = 1 cell.

#### Examples — same 16-wide box, varied content

```
╭──────────────╮     ╭──────────────╮     ╭──────────────╮
│     👤 users │     │           lb │     │       🌐 web │
╰──────────────╯     ╰──────────────╯     ╰──────────────╯

╭──────────────╮     ╭──────────────╮     ╭──────────────╮
│    📱 mobile │     │      🔐 auth │     │    🔍 search │
╰──────────────╯     ╰──────────────╯     ╰──────────────╯

╭──────────────╮     ╭──────────────╮     ╭──────────────╮
│         user │     │       orders │     │          pay │
╰──────────────╯     ╰──────────────╯     ╰──────────────╯
```

Every label's last character lands at column-from-right = 1, regardless of icon presence.

#### Emphasis — same width, taller

```
╭──────────────╮          ╭──────────────╮
│    🔌 api gw │          │              │
╰──────────────╯          │    🔌 api gw │
                          │              │
   standard               ╰──────────────╯
   3 lines total
                            emphasis
                            5 lines total
```

Use sparingly: at most 1 emphasis box per diagram. The point of emphasis is to draw the eye; multiple emphases scatter it.

### 11.3 Connectors and arrows

#### Straight connectors

```
──▶          horizontal right
◀──          horizontal left
▲            vertical up
▼            vertical down
```

#### Bent connectors

Use the rounded corner family:

```
──╮                   ╭──
  │                   │
  ▼                   ▼

      ─╯           ╰─
       │           │
```

#### Junctions (orthogonal multi-way)

```
─┬─    drop down from horizontal
─┴─    rise up to horizontal
─├─    branch right from vertical
─┤─    branch left from vertical
─┼─    cross
```

#### Arrowheads

```
Standard       ▶  ◀  ▲  ▼          filled triangle (default)
Open           ▷  ◁  △  ▽          for "weak" / optional connections
ASCII          >  <  ^  v
```

**Rule:** orthogonal lines only. If two boxes aren't on the same row, bend the connector with a corner; never use diagonals.

### 11.4 Connector labels

Labels go above the line for outgoing, below for incoming.

```
                req
client ────────────▶ server
       ◀────────────
                resp
```

For vertical fan-outs, labels sit between the junction and the arrowhead:

```
       ╭─────────┴─────────╮
       │                   │
      no                  yes
       │                   │
       ▼                   ▼
```

### 11.5 Composed patterns

#### Architecture (boxes + arrows)

```
╭──────────────╮      ╭──────────────╮      ╭──────────────╮
│       🌐 web │ ───▶ │    🔌 api gw │ ───▶ │     🗄 pgsql │
╰──────────────╯      ╰──────────────╯      ╰──────────────╯
```

#### Cluster (container holding boxes)

The one place where mixing corner families is allowed: double `╔ ╝` for the container, rounded for interior nodes.

```
╔═ web tier ═════════════════════════╗
║                                    ║
║   ╭──────────────╮ ╭──────────────╮║
║   │       🌐 web │ │    📱 mobile │║
║   ╰──────────────╯ ╰──────────────╯║
║                                    ║
╚════════════════════════════════════╝
```

#### Decision flow

```
                    ╭──────────────╮
                    │        start │
                    ╰───────┬──────╯
                            │
                            ▼
                    ╭──────────────╮
                    │       ready? │
                    ╰───────┬──────╯
                            │
                ╭───────────┴───────────╮
                │                       │
               no                      yes
                │                       │
                ▼                       ▼
        ╭──────────────╮        ╭──────────────╮
        │         wait │        │         land │
        ╰──────────────╯        ╰──────────────╯
```

Fan-out goes through a `┴` junction below the diamond — keeps every box the same width.

#### State machine

```
   ╭──────────────╮      ╭──────────────╮      ╭──────────────╮
   │      RUNNING │ ───▶ │        READY │ ───▶ │       LANDED │
   ╰───────┬──────╯      ╰───────┬──────╯      ╰──────────────╯
           │                     │
           ▼                     ▼
   ╭──────────────╮      ╭──────────────╮
   │       FAILED │      │     CONFLICT │
   ╰──────────────╯      ╰──────────────╯
```

State labels in their state colors. Terminal states (LANDED, FAILED, CONFLICT) have no outgoing arrows.

#### Sequence / lifeline

```
client                 server
  │                      │
  ├── login ────────────▶│
  │                      │
  │◀──── token ──────────┤
  │                      │
  ├── /api/data ────────▶│
  │                      │
  │◀──── 200 ok ─────────┤
  │                      │
```

Lifelines as `│` columns, messages as `├──▶` arrows. Time runs top-down.

#### Pipeline with status

```
   build              test              deploy
╭──────────────╮  ╭──────────────╮  ╭──────────────╮
│ ●  ●  ●      │  │ ●  ●  ◌      │  │ ◌  ◌  ◌      │
╰──────────────╯  ╰──────────────╯  ╰──────────────╯
   done              running           pending
```

Each box's interior shows work units as filled/empty dots. Pipeline reads as both flow and status.

#### Hierarchy

```
                   ╭──────────────╮
                   │         core │
                   ╰───────┬──────╯
                           │
              ╭────────────┼────────────╮
              │            │            │
              ▼            ▼            ▼
      ╭──────────────╮╭──────────────╮╭──────────────╮
      │       🔐 auth││         data ││           ui │
      ╰──────────────╯╰──────────────╯╰──────────────╯
```

Tree shape with proper boxes — for deps where the layout is the point.

#### Layered stack (one allowed exception to rounded-only)

```
┌─ application ────────────────┐
│   bash + term.sh             │
├─ runtime ────────────────────┤
│   git, stat, sed, awk        │
├─ filesystem ─────────────────┤
│   .claude/fleet/             │
└──────────────────────────────┘
```

Light corners (`┌ ┐ └ ┘`) for stacks — distinguishes them from panels and diagrams. Layer name in the top edge of each layer.

### 11.6 Icon dictionary

A small registered set for diagrams. Use sparingly — at most one per box, only when the icon adds meaning. ASCII fallback registered for each.

| Concept            | Glyph | ASCII | Use for                                  |
| ------------------ | ----- | ----- | ---------------------------------------- |
| user / actor       | 👤     | `(U)` | external person/role at the system edge  |
| web / browser      | 🌐     | `(W)` | client web tier                          |
| mobile             | 📱     | `(M)` | mobile clients                           |
| auth / security    | 🔐     | `(A)` | auth services, key vaults                |
| database           | 🗄     | `(D)` | persistent storage                       |
| cache              | ⚡     | `(C)` | fast in-memory stores                    |
| queue / message    | 📨     | `(Q)` | message brokers, event buses             |
| storage / blob     | 📦     | `(P)` | object storage, file blobs               |
| service / worker   | ⚙     | `*`   | background processes, scheduled jobs     |
| api / endpoint     | 🔌     | `(I)` | api gateway, ingress                     |
| search / index     | 🔍     | `(S)` | search services                          |
| timer / schedule   | ⏱     | `(T)` | scheduled tasks, crons                   |
| build / compile    | 🔨     | `(B)` | build systems                            |
| event / hook       | 🪝     | `(H)` | webhooks, event triggers                 |
| log / file         | 📄     | `(F)` | logs, files, records                     |

**Rules for icons in diagrams:**
1. **At most one icon per box.** No stacking.
2. **Icon goes inside the box, before the label.** Same row, single space between.
3. **Boxes must size for emoji width.** Emoji = 2 cells; size the box accordingly.
4. **Be selective.** A diagram of 16 boxes shouldn't have 16 icons — pick 4–6 *categories* of node and icon those (one for each tier or role).

### 11.7 Reference exemplar — 16-element architecture

```
                          ╭──────────────╮
                          │     👤 users │
                          ╰───────┬──────╯
                                  │
                                  ▼
                          ╭──────────────╮
                          │           lb │
                          ╰───────┬──────╯
                                  │
                       ╭──────────┴──────────╮
                       │                     │
                       ▼                     ▼
                 ╭──────────────╮     ╭──────────────╮
                 │       🌐 web │     │    📱 mobile │
                 ╰───────┬──────╯     ╰───────┬──────╯
                         │                    │
                         ╰─────────┬──────────╯
                                   │
                                   ▼
                          ╭──────────────╮
                          │    🔌 api gw │
                          ╰───────┬──────╯
                                  │
        ╭──────┬──────────┬───────┼───────┬──────────┬──────╮
        │      │          │       │       │          │      │
        ▼      ▼          ▼       ▼       ▼          ▼      ▼
   ╭──────────────╮ ╭──────────────╮ ╭──────────────╮ ╭──────────────╮ ╭──────────────╮
   │      🔐 auth │ │         user │ │       orders │ │          pay │ │    🔍 search │
   ╰───────┬──────╯ ╰───────┬──────╯ ╰───────┬──────╯ ╰───────┬──────╯ ╰───────┬──────╯
           │                │                │                │                │
           ▼                ▼                ▼                ▼                ▼
   ╭──────────────╮ ╭──────────────╮ ╭──────────────╮ ╭──────────────╮ ╭──────────────╮
   │     🗄 pgsql │ │     ⚡ redis │ │     📨 kafka │ │       stripe │ │    🗄 elastic│
   ╰──────────────╯ ╰──────────────╯ ╰───────┬──────╯ ╰──────────────╯ ╰──────────────╯
                                             │
                                             ▼
                                    ╭──────────────╮
                                    │     ⚙ worker │
                                    ╰──────────────╯
```

16 elements, all the same width, all rounded corners. Icons on tier-defining nodes (clients, gateway, security, search, data layer, worker); domain services (`user`, `orders`, `pay`, `lb`, `stripe`) stay icon-free where the name is the meaning.

### 11.8 Rules of thumb

- **Don't draw if you can list.** A bulleted list always wins for purely sequential content. Diagrams earn their keep when there's a *spatial* relationship the reader needs to grasp.
- **Pick one corner family per diagram.** Rounded everywhere; the cluster container double-line and the layered-stack light-corner are the only sanctioned exceptions.
- **Width budget: 80 cols.** Diagrams that need >100 cols need to be split or rethought.
- **Color is amplification.** Strip color, the diagram still works.
- **No diagonals, no overlapping lines, no crossing connectors.** If your diagram needs them, it's the wrong representation for monospace.
- **Anti-pattern: ASCII art logos and decorative borders.** This is about communicating structure, not flexing.

---

## Appendix A: rules of skill-agent-updates

Output-heavy skills follow this spec and source `skills/_lib/term.sh`. See [`rules/skill-agent-updates.md`](../rules/skill-agent-updates.md).
