# README as a Landing Page

Guidance for everything **between** the intro and the deep sections — the part a cold
visitor actually scans before deciding whether to install. Two sibling references already
own the ends of that stretch and this one does **not** restate them:

| Layer | Owner |
|---|---|
| The 2–3 paragraph prose intro under the title | `readme-description.md` |
| The `## Recent Updates` changelog block | `readme-recent-updates.md` |
| Badge row, section order, features-as-benefits, screenshots/demo | **this file** |

The audit floor ("tagline, install, quickstart, license link, intro ≥ 80 words") is a
*floor*. A README that clears it can still read as a spec sheet. This file is the ceiling.

## The first ten seconds

A visitor arriving from a search result, a link, or a topic page runs four questions in
order, mostly below conscious thought:

1. **What is this?** — title + tagline + intro paragraph one.
2. **Is it alive?** — badge row (CI green, a version that isn't three years old), then
   `## Recent Updates`.
3. **What do I get?** — `## Features`, written as benefits.
4. **Can I run it / what does it look like?** — screenshot or demo, then install.

They abandon at the first unanswered question. Almost every weak README fails at (2) or
(3): it answers "what is this" thoroughly, then jumps straight to `## Installation`,
leaving the reader to infer value from a `pip install` line.

Note the asymmetry: questions 1–3 are *decisions*, question 4 is *mechanics*. **Benefits
before mechanics** is not a stylistic preference — it is the order the reader is already
asking in.

## Section order

The default shape. Vary it when the project demands, but know what you're trading.

```
# project-name
> one-line tagline (<= 120 chars)

[badges: license · version · CI · runtime · status]

<2-3 paragraph intro>                  <- readme-description.md owns this

## Features                            <- benefits, not inventory
<screenshot / demo>                    <- inline here, or under Features

## Install
## Quickstart

## Recent Updates                      <- readme-recent-updates.md owns this

## Why this exists / How it works / Configuration / Repo layout
## Contributing
## License
```

### Reconciling "Recent Updates" placement

`readme-recent-updates.md` specifies: *after the hero/tagline + quick install or
quickstart, before the deep "why this exists" sections.* That still holds — **this file
does not move it.** What this file adds is that `## Features` and the visual land
*before* Install, which means Recent Updates now sits after four sections rather than
two. It stays above the fold-and-a-bit, which was always the point: liveness has to be
visible without hunting.

The two liveness signals split cleanly by cost:

- The **badge row** is the zero-scroll signal — glanceable, no reading.
- **Recent Updates** is the confirming signal — read *after* the reader has decided the
  project is interesting enough to check whether it is maintained.

Putting Recent Updates above Features inverts that: you ask someone to read a changelog
for a thing they have not yet decided they want.

**Exception — high-cadence tooling.** Where releases are the product (a scraper chasing
anti-bot changes, a wrapper tracking an upstream API), promote Recent Updates above
Install. Recency *is* the feature there. That is exactly the case
`readme-recent-updates.md` covers with its table style.

## Badge row

A short row of shields immediately under the H1 (or under the tagline), answering *what
is this, is it maintained, can I run it* without a single word being read.

### Which badges earn their place

Five slots, at most. Each must answer a question a visitor is actually asking:

| Badge | Answers | Include when |
|---|---|---|
| **License** | "Can I use this?" | Always. Static, never rots. |
| **Version / release** | "Is this shipping?" | Once published to a registry, or once tagged releases exist. |
| **CI status** | "Does it work?" | Only when CI actually runs on every push to the default branch. |
| **Runtime requirement** | "Can I run it?" | When the floor is a real gate — Python >= 3.11, Node >= 20, a specific engine version. |
| **Project status** | "What state is this in?" | When the state is not "stable" — `alpha`, `beta`, `experimental`, `private staging`, `archived`. |

The status badge is the one most projects skip and shouldn't. An honest
`status: experimental` badge does more for trust than a paragraph of hedging, and it
buys you permission to break things.

### Which badges are noise

| Badge | Why it's noise |
|---|---|
| Downloads / stars / forks | Popularity, not utility. A low number actively repels; a high one persuades nobody who was going to read the code anyway. |
| Code coverage | A percentage without a denominator. 94% of what? |
| "PRs welcome" | Say it in CONTRIBUTING, where the reader is when they want it. |
| "Made with love" / "built with X" | Decoration. |
| Dependency-freshness services | Third-party uptime you don't control, rendering in your hero. |
| Chat/community badges on a project with no community | An empty room with a sign on the door. |

**The two failure modes, named:**

- **The badge wall.** Twelve shields wrapped onto three lines reads as insecurity — a
  project arguing for itself before it has said what it is. Five is a row; twelve is a
  plea. If a badge does not change a reader's decision, it costs attention for nothing.
- **The stale red badge.** A failing CI badge left up for months is *worse than no
  badge*: it converts your one liveness signal into a broadcast that nobody is watching.
  Same for a version badge pinned to a release two years old. **A badge you will not
  maintain should not be added.** If CI is broken and won't be fixed this week, remove
  the badge in the same commit that acknowledges it.

### shields.io URL construction

Static badge:

```
https://img.shields.io/badge/<LABEL>-<MESSAGE>-<COLOR>
```

Hyphens inside a segment are escaped by doubling (`--`); underscores or `%20` give a
space. Live badges use the service endpoints:

```markdown
[![License](https://img.shields.io/github/license/OWNER/REPO?labelColor=1b1f24&color=3fb950)](LICENSE)
[![Release](https://img.shields.io/github/v/release/OWNER/REPO?labelColor=1b1f24&color=3fb950)](https://github.com/OWNER/REPO/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/OWNER/REPO/ci.yml?branch=main&label=ci&labelColor=1b1f24)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)
[![Python](https://img.shields.io/badge/python-3.11%2B-blue?labelColor=1b1f24)](https://www.python.org)
[![Status](https://img.shields.io/badge/status-experimental-orange?labelColor=1b1f24)](#project-status)
```

**`labelColor` is the brand lever.** A shields badge has two halves: the left label and
the right message. `color` paints the message (semantic — green pass, red fail, orange
warning); `labelColor` paints the label and is *not* semantic, so it is free to carry the
project's brand colour. Setting the same `labelColor` on every badge is what turns five
independent shields into one coherent row instead of a ransom note. Pick one dark neutral
or one brand hex, apply it to all of them, and let only the right half vary.

Other parameters worth knowing, and their costs:

- `style=flat` (default), `flat-square`, `for-the-badge`. Pick one and use it across the
  whole row. `for-the-badge` is loud and doubles the row's height — reserve it for a
  project with exactly one or two badges.
- `logo=<simple-icons slug>` + `logoColor=` — a logo per badge is charming once and
  cluttered five times. Use it on none or on all.
- `?branch=main` on the Actions badge. **Omit it and the badge reports the most recent
  run on any branch**, which means a red badge from someone's failed feature branch.
  This is the single most common badge misconfiguration.
- `cacheSeconds=` — shields caches aggressively anyway; setting this rarely helps and a
  low value just makes your README slower to paint.

Every badge is a link, and the link must go where the badge's claim can be verified:
license badge to `LICENSE`, CI badge to the workflow's runs page, version badge to
releases. A badge that links nowhere is decoration wearing a data costume — acceptable
only for a pure-declaration status badge, and even then prefer an in-README anchor that
explains the status.

## Features as benefits, not inventory

The discipline: **each bullet leads with what the reader gets, not what the software
contains.** An inventory bullet describes the codebase; a benefit bullet describes the
reader's day after they install it.

The mechanical test — read the bullet and ask *"so what?"*. If there is an obvious
unstated answer, that answer was the bullet.

### Worked example — before

```markdown
## Features

- Built-in gitleaks integration
- Regex-based secret scanning layer
- Forbidden-file checklist (`.env`, `*.pem`, `id_rsa`)
- Upstream divergence detection
- Interactive confirmation prompt
- Configurable via `.push-gate.toml`
```

Six true statements about the implementation. Every one of them makes the reader do the
translation work themselves, and the last one — configuration — has no business being a
headline feature at all.

### Worked example — after

```markdown
## Features

- **Stops a leaked key before it leaves your machine.** Runs gitleaks plus a
  regex layer over the diff, and refuses the push on any hit — no
  `--force-anyway` flag, because you'd use it.
- **Catches the files you never meant to track.** `.env`, private keys, and
  stray credential dumps are checked by name, not just by content.
- **Tells you when your branch has drifted.** Compares against upstream before
  the push, so a surprise force-push never happens by reflex.
- **One confirm step, at the last useful moment.** Between "staged everything"
  and "the world has it" — the only checkpoint that still catches mistakes.
```

Four bullets instead of six, more words, and dramatically more decision-value. What
changed:

- **Bold lead is a claim about the reader**, not a component name. The detail follows in
  the same bullet, so nothing was lost — the gitleaks fact is still there, now attached
  to the reason it matters.
- **Consequences, stated.** "Refuses the push" and "no `--force-anyway` flag" tell you
  how opinionated the tool is, which is exactly the thing a reader is trying to work out.
- **The config bullet is gone.** Configurability is a property of nearly all software; it
  belongs in a `## Configuration` section, where it is useful, not in the pitch.
- **Merged where the reader wouldn't distinguish.** Gitleaks and the regex layer are two
  implementations of one benefit. Splitting them padded the list without informing anyone.

### The rules that fall out of it

- **4–7 bullets.** Under four and the section looks thin; over seven and nobody finishes
  it. If you have twelve features, you have three benefits and nine details.
- **Bold lead, <= 10 words**, scannable on its own. A reader who reads only the bold
  fragments must still come away knowing what the project does.
- **One or two sentences of detail** after the lead, carrying the concrete nouns —
  command names, file names, real numbers.
- **Verbs the reader owns**, not verbs the software owns: "stops", "catches", "tells
  you", "saves you" — not "provides", "supports", "enables", "leverages", "offers".
- **No feature that is table stakes.** "Cross-platform", "configurable", "well-tested",
  "documented" — these are absence-noticed, presence-ignored.
- **Honest scope earns trust.** One bullet naming what it deliberately does *not* do is
  worth three that gild what it does. Same principle as the intro's "when it's the wrong
  choice" paragraph.

## Screenshots and demo media

### When a visual earns its place

A visual is worth its weight only when the project has a **visual surface** — something a
still frame or a short clip can show that prose cannot:

| Project shape | Visual? |
|---|---|
| TUI, dashboard, GUI, web UI, generated diagrams/art | **Yes.** The output is the pitch. |
| CLI with formatted, colourised, or tabular output | **Yes** — a terminal capture of one real run. |
| CLI with plain text output | Usually a fenced code block, not an image. Cheaper, copyable, searchable, diffable. |
| Library, SDK, or API surface | **No.** A code block *is* the screenshot. |
| Agent skill / prompt pack / config bundle | Usually no. If it produces a rendered artefact, show the artefact. |

**A fenced code block beats a screenshot of a terminal every time the content is plain
text**: it is selectable, greppable by search engines, survives dark mode for free, costs
no bytes, and shows up in the diff when it goes stale. Reach for an image only when the
*rendering* is the information — colour, layout, glyph alignment, a real UI.

Conversely, a project *with* a visual surface and no visual is leaving its strongest
argument on the floor. Nobody installs a dashboard on the strength of a bullet list.

### Static vs animated

Default to **static**. A well-chosen still of the finished output answers "what does this
look like" instantly, and the reader controls their own pace.

Reach for animation only when **the motion is the information** — a multi-step flow, a
progressive reveal, a before/after transition that a still cannot convey.

When you do, the costs are real and worth naming:

- **File size.** An animated GIF of a terminal session runs 5–20 MB with no effort at
  all. It is downloaded by everyone who opens the README, on mobile data included, before
  they have decided they care. A 12 MB GIF above the fold is a hostile act. **Budget: 2
  MB, hard.** Shorter loop, fewer frames, smaller capture window, fewer colours.
- **Accessibility.** A GIF cannot be paused, and auto-playing motion is a genuine problem
  for readers with vestibular sensitivity — WCAG 2.2 SC 2.2.2 asks that motion lasting
  more than five seconds be pausable, and a GIF offers no control at all. Keep loops under
  five seconds, or use a `<video>` (which can carry `controls`) instead.
- **Legibility.** GIF's 256-colour palette wrecks anti-aliased terminal text. If the
  reader cannot read the commands in the recording, the recording is decoration.

**Better than a GIF, in order:** an [asciinema](https://asciinema.org) recording linked
by its still-image badge (text-based, selectable, kilobytes not megabytes); an MP4/WebM
in a `<video controls loop muted>` block; an animated `.webp` (same motion, a fraction of
the bytes); a static still linked to a longer recording hosted elsewhere. Plain GIF is
the last resort, not the default.

### Where the files live

**`docs/screenshots/`** — never the repo root. This is the `agentic-quality` rule
("repo root is sacred") applied to media: a root littered with `screenshot1.png` and
`demo-final-v2.gif` is exactly the drift that rule exists to stop. Name files for what
they show and keep the names stable, since the README links them by path:

```
docs/screenshots/dashboard-overview.png
docs/screenshots/dashboard-overview-dark.png
docs/screenshots/scan-run.webp
```

Reference them with a **repo-relative path** (`docs/screenshots/x.png`), not a raw
`raw.githubusercontent.com` URL — the relative path keeps working in forks, in a local
preview, and after a rename of the default branch.

If the images are heavy enough to bloat clones, host them off-repo (a release asset, a
GitHub issue-comment upload) and link by absolute URL. That is a deliberate trade, not
the default: repo-relative is more durable, off-repo is lighter.

### Alt text, always

Every image carries alt text describing **what the picture shows**, not what the file is:

```markdown
![Scorecard output: five weighted dimensions with per-repo grades and the top three fixes](docs/screenshots/scorecard-run.png)
```

Not `![screenshot]`, not an empty `![]()`, not `![demo gif]`. Screen readers read it
aloud, and it is what renders when the image 404s after a path change — which is the state
most stale READMEs are in. Purely decorative images take an empty alt deliberately, but a
README image is almost never decorative.

### Dark mode: the `<picture>` pattern

A screenshot captured on a light background glows like a torch inside GitHub's dark
theme, which is what most readers are using. Ship both and let the browser choose:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="docs/screenshots/overview-light.png">
  <img alt="Fleet matrix: one row per repo, columns for each scored dimension" src="docs/screenshots/overview-light.png">
</picture>
```

The `<img>` fallback is mandatory, not optional — it is what renders anywhere `<picture>`
is not honoured (npm, PyPI, many mirrors, plain-markdown viewers), so its `src` must be
the variant that reads acceptably on *either* background, and its `alt` is where the alt
text lives.

**The cheaper alternative:** capture the shot with a background that survives both
themes. A terminal capture on a mid-dark background, or a UI shot with a defined border,
needs no `<picture>` block at all. One asset, no divergence, nothing to keep in sync.

### GitHub's HTML subset — what actually works

GitHub sanitises README HTML aggressively. Assume this narrow set and nothing more:

- **Works:** `<picture>` / `<source>` / `<img>` (with `width`, `height`, `align`, `alt`),
  `<video>` (with `controls`, `loop`, `muted`, `src`), `<details>` / `<summary>`,
  `<table>`, `<sub>` / `<sup>` / `<kbd>`, `<br>`, `<div align="center">`, `<a>`.
- **Stripped:** `<style>` blocks and `<script>` entirely; `style=` attributes; `class=`
  and `id=` (heading anchors are generated, not authored); CSS custom properties; iframes;
  form elements.

Consequences to plan around: you cannot theme with CSS, so theme-awareness runs through
`prefers-color-scheme` in `<picture>` and nowhere else. You cannot centre with CSS, so
`<div align="center">` is the only lever — use it sparingly (see anti-patterns). Anything
needing real layout belongs on a docs site the README links to, not in the README.

Markdown inside an HTML block needs a blank line to be parsed; without one it renders
literally. This is why a `<details>` section's body so often comes out as raw asterisks.

## Anti-patterns (the landing-page layer)

`readme-description.md` covers prose fluff — "blazing fast", marketing verbs, emoji walls
in the intro. These extend that list to the layout layer:

| Anti-pattern | Why it fails |
|---|---|
| **Emoji per heading** (`## Installation` decorated with a rocket, `## Features` with sparkles) | Adds zero information and burns the reader's novelty budget on navigation furniture. Emoji work as *content* markers (the Recent Updates vocabulary) precisely because headings stay clean. |
| **Centred everything** | `<div align="center">` on the hero is fine. Applied to prose, feature lists, and code blocks it destroys the left edge the eye scans down, and looks visibly broken at narrow widths. |
| **A 12 MB demo GIF** | Downloaded by everyone before they've decided they care. Unpausable, unreadable, and the single heaviest thing in most repos. Budget 2 MB. |
| **A features table restating the API** | A table of every flag and its description is *reference documentation* filed under Features. The reader wanted five reasons to install; they got a man page. Link the reference; keep the benefits. |
| **The badge wall** | Twelve shields reads as insecurity. Five, one `labelColor`, each answering a real question. |
| **A red CI badge left standing** | Worse than no badge. It broadcasts that nobody is watching. |
| **Screenshot of text that should be a code block** | Unsearchable, uncopyable, unreadable on mobile, and stale the moment output changes — with nothing in the diff to say so. |
| **Broken or absent alt text** | A bare `![screenshot]` tells a screen-reader user nothing and renders as noise when the path rots. |
| **A table of contents on a short README** | Below ~200 lines, GitHub's own outline widget already does it. A hand-maintained ToC is a second thing to keep in sync. |
| **"Star this repo" / sponsor plea above the fold** | Asks for payment before delivering value. Bottom of the README, after the reader has decided. |
| **Duplicated install instructions** (badge, hero, and Install section) | Three copies drift; the reader learns to trust none of them. |
| **A hero image that is just the project name in a font** | Costs a network round-trip to say what the `# H1` already said, and is invisible to search. |

## Applying this in the three modes

| Mode | Action |
|---|---|
| `new` | Full treatment. Badge row, Features-as-benefits, and a screenshot **if** the project has a visual surface. Surface the draft README for approval before committing — this is the first impression. |
| `update` | Do not churn a good landing page. Act only when: a release added a capability worth a new Features bullet, the CI badge has gone stale or wrong, or a screenshot no longer matches the UI. |
| `audit` | Report WARN, never a hard fail. Missing badge row is a WARN. No Features/benefits section is a WARN. No screenshot **when the project has a visual surface** is a WARN; when it does not, stay silent. Suggest, don't auto-edit. |

**The conditional matters.** A CLI library legitimately has no screenshot, and a check
that nags it every audit teaches the reader to ignore the audit. Decide "does this project
have a visual surface" from the repo's actual shape — entry points, whether it renders
anything, whether existing docs contain images — and stay quiet when the answer is no.

### Why this isn't in `repo-scorecard.sh`

Deliberate. The scorecard is a mechanical, fleet-scale, read-only tool scoring signals
that are unambiguous from the GitHub API (does a LICENSE exist, are there >= 3 topics, is
the latest tag released). The landing-page checks are not that shape:

- "Has a benefits section" requires judging whether bullets lead with benefits — reading
  comprehension, not pattern matching.
- "Should this have a screenshot" requires judging whether the project has a visual
  surface, which no README-shaped heuristic can answer.
- Both would need the README *body* fetched and parsed per repo, adding an API call and a
  pile of false positives to a fleet sweep whose whole value is that its findings are all
  real.

So these live in mode `audit`, where an agent has the repo in hand and can exercise
judgment, and out of the scorecard, where a wrong answer is charged to every repo in the
fleet. If a future version does score them, it belongs in the metadata dimension, and the
rubric in the script's `--help` header must be updated in the same commit.
