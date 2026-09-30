# Contributing

Issues and PRs are welcome. A few ground rules keep them mergeable.

## Before you open a PR

- **Open an issue first** for anything non-trivial (new skills, behaviour
  changes). Small fixes and typo-level docs can go straight to a PR.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): summary` - see `rules/commit-style.md` for the house specifics.
- Run the gate before pushing: `just check` (frontmatter validation, doc-drift,
  the agnostic gate, hook contract tests, resource contracts, and every skill's
  behavioural suite).
- Keep contributions machine-agnostic: no real usernames, home paths, hostnames or
  private project names in examples - use placeholders (`/Users/me`, `<project>`).
- Conventions for skills, agents, and naming live in
  [AGENTS.md](AGENTS.md) and `docs/SKILL-CREATION-PROTOCOL.md` - read those
  before adding components.

## What isn't accepted

- **Translations.** README and docs change too frequently for committed copies
  to stay current - a translated README is stale within days, and one language
  fairly obliges maintaining several. On-demand browser/AI translation serves
  readers better than a rotting copy. Translation PRs are closed with thanks.
- Drive-by dependency bumps outside the bot's cadence, cosmetic reformatting,
  and generated-file edits (anything marked "built - don't hand-edit").

## Licence

Contributions are accepted under the repository's MIT licence.
