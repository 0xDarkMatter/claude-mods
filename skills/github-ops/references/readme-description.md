# README Description

Guidance for the README intro that sits between the title and the first `##` heading. This is the bit a person reads when they land on the repo — not the GitHub one-line description (that's a separate, shorter beast; see `metadata-checklist.md`).

The default tagline-only intro is too thin. Most published 0xDarkMatter repos deserve **2–3 substantial paragraphs** that orient a reader who landed cold from a search result or a link.

## What it is, not what it does

| Layer | Length | Purpose |
|---|---|---|
| Title (`# repo-name`) | ~3 words | Identity |
| Tagline (one line, optional `>` blockquote) | ≤ 120 chars | The pitch |
| Intro paragraphs (2–3) | ~150–300 words total | Orientation |
| Then `## Install` etc. | — | The mechanics |

The intro is *not* a feature list. Save bullets for later sections. This is prose, written like a developer explaining the project to a peer over coffee — concrete, slightly opinionated, not performative.

## Structure (the three-paragraph shape)

Not a rigid template — a default to vary from when the repo demands it.

### Paragraph 1 — What it is

- Concrete, specific noun phrase. Not "a powerful framework for..."
- Name the actual category (CLI, library, plugin, daemon, skill collection, MCP server).
- One sentence on the *shape* (single binary? plugin pack? long-running daemon? collection of scripts?).
- One sentence on the *primary surface* (what command/import/endpoint does the user touch first).

### Paragraph 2 — Why it exists / what it solves

- The pain that prompted it. Real, specific, recognisable.
- What the existing options were and why they didn't fit. (Tactful — no need to dunk.)
- The shape of the solution, in one sentence.
- This is where dry wit can land — naming a frustration accurately is itself a kind of joke.

### Paragraph 3 — Who it's for / when it's handy

- Who would reach for this tool. Be honest about scope.
- A scenario or two where it shines.
- A scenario where it's the wrong choice (this builds trust faster than any feature list).
- Optional: how it fits alongside related tools the reader probably already knows.

## Voice

- **Developer-to-developer.** Assume technical literacy; don't explain what a CLI is.
- **Concrete over abstract.** "Wraps `gh` and adds a confirm step before pushes" beats "streamlines GitHub workflows".
- **Confidence without pomp.** State what it does. Don't sell.
- **Occasional dry wit.** Earned, not sprayed. One well-placed observation > three jokes. British understatement scales better than zingers.
- **Honest about scope.** "Handles the boring 80%" is more trustworthy than "comprehensive solution".

### Wit calibration

Good wit names something the reader has *also* felt:

> "Because every project eventually needs the same six bash scripts, and writing them again at 11pm is no longer charming."

Bad wit performs cleverness:

> "Behold! A revolutionary new paradigm that will *blow your mind* 🤯"

When in doubt, omit the joke. A clean, plain description is always better than a strained one.

## Anti-patterns

| Avoid | Why |
|---|---|
| "Blazing fast", "powerful", "cutting-edge", "robust" | Marketing words signal nothing. Show specifics. |
| "Easy to use" | Decided by the reader, not you. |
| Emoji walls (🚀✨🔥💯) at the top | Reads as AI slop. One contextual emoji is fine; a parade isn't. |
| Feature bullets in the intro | Save for `## Features` or just let the structure speak. |
| Comparison tables before saying what the thing is | Orient first, position later. |
| "This project aims to..." | Just describe what it is, not what it aspires to be. |
| Auto-generated boilerplate | A reader can spot it instantly. Trust collapses. |
| Restating the title | "Foo is a tool called foo that does foo things." |
| Hedging ("might be useful for", "could potentially help") | Either it's for them or it isn't. Say so. |

## Process

Before writing, read these in this order:

1. **Existing README** — what's already there? Don't discard prior voice if it's good; refine it.
2. **Package metadata** — `pyproject.toml` / `package.json` description + keywords. These were chosen for a reason.
3. **CHANGELOG.md** — the v0.1.0 / first-publish entry often captures the original motivation cleanly.
4. **Source layout** — top-level dirs and entry points reveal the actual shape.
5. **Primary entry point file** — read the main script / `__init__.py` / `main.go` opening for any module docstring.
6. **Tests** — test names often describe the contract more honestly than docs.

Then draft 2–3 paragraphs, read them back as if you'd never seen the repo, and cut every sentence that doesn't add information. The final intro should be **dense** — a reader scanning it should come away knowing what the repo is, why it exists, and whether they should keep reading.

## When to update vs leave alone

| Situation | Action |
|---|---|
| Mode `new` (first publish) | Always draft the intro before publish. This is the reader's first impression. |
| Mode `update` (subsequent release) | Touch only if scope drifted *or* the original intro was thin. Don't churn good prose. |
| Mode `audit` | Flag if the intro is < 80 words OR is a single tagline. Suggest, don't auto-edit. |
| Existing intro is already good | Leave it. Suggest a minor tweak if a release added a major capability. |

## Worked example

### Before (the thin version)

```markdown
# push-gate

> Pre-push safety checks for git.

## Install
...
```

### After (the 3-paragraph version)

```markdown
# push-gate

> Pre-push safety gate for any `git push` to a remote — secret scan, forbidden-file check, divergence check, explicit confirm.

`push-gate` is a Claude Code skill that intercepts pushes to GitHub, GitLab,
Bitbucket, or any other remote and runs a fast preflight before the bytes
leave your machine. It layers `gitleaks` with a regex-based secret scan,
checks for files that shouldn't be in the repo (private keys, `.env`, large
binaries), confirms the local branch hasn't diverged unexpectedly from its
upstream, and requires an explicit "yes" before the push proceeds.

It exists because the worst time to discover a leaked AWS key is *after* it's
in someone else's clone. Pre-commit hooks help, but they only run on commit
and they're easy to bypass; CI scanners catch leaks too late. `push-gate`
sits at the last useful checkpoint — the moment between "I've staged
everything" and "the world has it" — and refuses to let a known-bad push
through. Refusal is hard, not advisory: there's no `--force-anyway` flag,
because if there were, you'd use it.

It's most useful for solo developers who don't have org-level secret
scanning, for repos that mix public and private code, and for the mid-pour
late-night push where careful review has politely left the building. If you
already run gitleaks pre-commit and have CI guards on every push, `push-gate`
is redundant — go enjoy your weekend. If you don't, it's a small skill that
will eventually save you from a very large incident.

## Install
...
```

The difference: a reader of the second version knows what the tool is, why it exists, when to use it, and when *not* to. That's the bar.

## Length sanity check

| Word count | Verdict |
|---|---|
| < 60 | Thin — expand. |
| 60–150 | Borderline — fine for tiny utilities, light for anything substantial. |
| 150–300 | The sweet spot. |
| 300–500 | Acceptable for a complex/foundational repo; tighten if possible. |
| > 500 | Too long for an intro — split into intro + a `## Why this exists` section. |
