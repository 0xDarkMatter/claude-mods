# README "Recent Updates" Section

Every published 0xDarkMatter repo's README has a **"Recent Updates"** section as a first-class element near the top.

**Why:** Visitors immediately see velocity + what's new without clicking through to CHANGELOG.md. Surfaces project liveness and recent capability adds at a glance.

**Canonical example (DEFAULT style):** https://github.com/0xDarkMatter/claude-mods
**Alternate (denser, table-based):** https://github.com/0xDarkMatter/flarecrawl

## Default style — claude-mods

Per-version blocks with emoji-prefixed bullets. Use this unless the project's release cadence is so high (multiple per day) that the table style is justified.

```markdown
## Recent Updates

**v2.4.3** (April 2026)

*   🌳 **Worktree-aware `git-ops`** - Folded the briefly-considered `git-status` skill straight into `git-ops` rather than ship a third sibling. T1 inline now exposes `scripts/status.sh` (rich repo overview...)
*   🛡️ **`push-gate` skill** - Hard pre-push safety gate. Gitleaks + regex layer secret scan, forbidden-file check, divergence check...
*   📌 **`rules/worktree-boundaries.md`** - Hard rule promoted from user-global into the plugin: never `rm -rf .claude/worktrees/`...

**v2.4.1** (April 2026)

*   🎭 **13 output styles** - Added 8 daemon personalities from Forma: Atlas (strategic advisor), Coach (momentum builder)...

[View full changelog →](https://github.com/0xDarkMatter/<repo>/commits/main)
```

### Style rules

- Version header: `**v2.4.3** (Month YYYY)` — bold version, month-year in parens (NOT ISO date)
- Each change is a bulleted item under the version
- Bullet prefix: relevant **emoji** + **bold tagline** (often a skill name in backticks like `` `push-gate` skill `` or a capability label)
- Followed by ` - ` and a **1–2 sentence** prose description with concrete details (file names, flag names, key counts, links to references)
- Multiple bullets per version is normal and good — one bullet per discrete change
- 5–7 most recent versions visible; link "View full changelog →" at the bottom to the commits view
- External references (other tools, articles, posts) get inline markdown links

### Length discipline

Each bullet should be **scannable in one breath** — roughly 30–60 words after the bold tagline. If a bullet runs longer:

- Drop parenthetical category lists ("(`PRUNABLE` / `WIP` / `GHOST` / `ORPHAN`)") — these belong in skill docs, not release notes
- Drop sub-features ("Plus a harness whitelist on Gate 1: ...") — split into a separate bullet or omit
- Drop bug fixes from feature releases unless they're the headline — move to a `🐛` bullet only if user-visible

Rule of thumb: a release block of 4 bullets averaging 40 words each (~160 words total) reads cleanly. A block of 5 bullets averaging 80 words each (~400 words) becomes a wall and visitors skim past it.

Long bullets erode the value of the section — visitors should see velocity at a glance, not have to read paragraphs to extract what shipped.

## Alternate style — flarecrawl (table)

Only use when the project ships so frequently that the per-version block format would dominate the README.

```markdown
## Recent Updates

| Version | Date | Changes |
| --- | --- | --- |
| **v0.22.0** | 2026-04-21 | **Secure credential storage.** OS keyring via `flarecrawl[secure]`. Auto-migrates legacy plaintext config.json. 1112 tests |
| **v0.21.0** | 2026-04-20 | **Auth + crawl fixes.** `--browser-cookies` on scrape/interact/design (was videos-only). `--session` on crawl. `--ignore-robots` made actionable |

For older releases, see [CHANGELOG.md](CHANGELOG.md).
```

Table style uses ISO dates (YYYY-MM-DD) since it's denser. One row per version, summary in single cell with bold tagline lead.

## Update cadence

- **Patch** release: single-bullet block describing the fix
- **Minor** release: 2–6 bullets covering each shipped change
- **Major** release: lead with the breaking change, then enhancements

Update on **every** release regardless of size. This is the one README touch that always happens.

## Placement in README

- After the hero/tagline + quick install or quickstart
- Before the deep "Why this exists" / feature comparison sections
- High enough to be visible without scrolling on a typical browser

## Trim policy

When the section grows past ~7 versions, trim oldest version blocks atomically with adding the new one (same commit). CHANGELOG.md keeps the full history.

## Emoji vocabulary

Used consistently across claude-mods. Pick the closest match for each bullet; introducing new emoji is fine when no existing one fits.

| Emoji | Meaning |
|---|---|
| 🚀 | launch / major capability |
| 🔄 | refactor / rename |
| 🛠️ | tooling |
| 🛡️ | security / safety |
| 🌳 | worktree / structural |
| 📌 | rule / policy |
| 📬 | messaging / inter-process |
| 🎭 | personalities / styles |
| 🐛 | bug fix |
| 🆕 | new addition |
| 📚 | docs |
| 🎯 | architecture / pattern |
| 🎨 | design / generative |
| 📐 | spec / standards |
| 🔍 | introspection / observability |
| 🔧 | config / settings |
| 🗑️ | removal |
| 🔁 | loop / iteration |
| ⚡ | performance |
| 📦 | packaging / distribution |
| 🧪 | tests |
| 🔌 | integration / plugin |

## Adding the section to a new repo (mode `new`)

For first publish (only v0.1.0 exists), generate a single block summarising the initial release:

```markdown
## Recent Updates

**v0.1.0** (Month YYYY)

*   🚀 **Initial release** - <one-paragraph summary of what shipped, including key counts (LOC, tests), capability headlines, and any notable provenance>

[View full changelog →](https://github.com/<org>/<repo>/commits/main)
```

Place it between Quickstart and the deep "why this exists" sections.
