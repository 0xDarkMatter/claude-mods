# README Steps of Modes new and update

The README detail behind SKILL.md's mode `new` steps 2 and 2b and mode `update` step 4. The register choice and its tie-breakers stay in SKILL.md; the full guidance is in [readme-description.md](readme-description.md) and [readme-landing-page.md](readme-landing-page.md).

## Mode `new`, step 2: the README intro

```
   - If the README intro is just a tagline or < 80 words, draft a proper 2–3 paragraph
     description: what it is, why it exists, who it's for. Read package metadata, CHANGELOG,
     and the primary entry point first; do not fabricate.
   - Voice: developer-to-developer, concrete, occasional dry wit (earned, never sprayed).
     Anti-patterns ("blazing fast", emoji walls, marketing fluff) listed in the reference.
   - Surface the draft to the user for approval before committing — this is the repo's
     first impression and shouldn't be a one-shot.
```

## Mode `new`, step 2b: building the layer

```
   Then, in whichever register:
   - Badge row under the title: at most five — license, version, CI, runtime floor,
     project status. One shared labelColor so they read as one row. Never add a badge
     you won't maintain; a stale red CI badge is worse than no badge.
   - ## Features section ABOVE Install, written as benefits (bold lead = what the
     reader gets, then the concrete detail), 4–7 bullets. Not a component inventory.
   - A screenshot or demo ONLY if the project has a visual surface (TUI/GUI/dashboard/
     rendered output, or colourised CLI output). Plain-text CLI and libraries take a
     fenced code block instead. Store under docs/screenshots/, alt text on every image,
     <picture> + prefers-color-scheme so it doesn't glow white in dark mode.
```

## Mode `update`, step 4: minor vs patch, and the intro

```
   For minor: update Recent Updates AND scan diff for new commands/config/install steps;
              touch README body sections only if found.
   For patch: update Recent Updates ONLY (single bullet); no body changes unless asked.

   Also: if the README intro is still < 80 words OR the repo's scope has drifted since
   the intro was written, propose an expansion (see references/readme-description.md).
   Don't churn good prose — only act if the intro is genuinely thin or stale.
```

## Mode `update`, step 4: landing-page touch-ups

```
   - The release added a capability worth a Features bullet → add one (benefit-led),
     and cut a weaker one if the section now runs past ~7.
   - The CI badge is red/stale, or the version badge no longer tracks releases →
     fix it or remove it. A badge nobody maintains is worse than no badge.
   - A shipped UI change made an existing screenshot wrong → recapture or drop it.
   - The repo has a visual surface and still has no visual → propose one; don't add
     it unasked.
```
