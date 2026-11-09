# The shadcn CLI, pinned

Every command and flag below was read from `shadcn --help` of shadcn 4.23.0 and checked
against ui.shadcn.com/docs/cli on 2026-11-10. Parts are adapted from the official shadcn
skill (shadcn-ui/ui, `skills/shadcn/`, MIT licence).

## Contents

- [Why pin](#why-pin)
- [Resolving the runner](#resolving-the-runner)
- [Commands](#commands)
- [Flags worth knowing](#flags-worth-knowing)
- [Templates and presets](#templates-and-presets)
- [Updating installed components](#updating-installed-components)
- [Bumping the pin](#bumping-the-pin)

## Why pin

The upstream docs and the official skill run the CLI as `npx shadcn@latest` (or
`pnpm dlx shadcn@latest`), and the official skill pre-approves exactly those commands. That
is prompt-free execution of whatever release npm calls `latest` at that moment. shadcn
published eight stable releases between 2026-10-05 and 2026-10-27, plus beta and rc tags. A
compromised publish would reach every agent that runs it within minutes, long before an
advisory exists (the supply-chain-defense skill covers that threat in depth).

`init` itself adds `shadcn` to the project's devDependencies (alongside `tw-animate-css`),
because the global CSS imports `shadcn/tailwind.css` from it. So a v4 project already has a
locked copy of the CLI: use it.

## Resolving the runner

`scripts/shadcn-cmd.sh` picks the first of:

| Order | Source | Prefix it prints |
|---|---|---|
| a | the project's own dependency (package.json chain up to the lockfile's folder) | npm `npx --no shadcn`, pnpm `pnpm exec shadcn`, Yarn `yarn run shadcn`, Bun `bunx --no-install shadcn` |
| b | a global `shadcn` whose major matches the pin | `shadcn` |
| c | the package manager's one-off runner at the exact pin | `npx shadcn@4.23.0`, `pnpm dlx shadcn@4.23.0`, `yarn dlx shadcn@4.23.0` (Yarn 2+), `bunx shadcn@4.23.0` |

The local forms never download: `npx --no` and `bunx --no-install` fail instead of fetching,
and `pnpm exec` only runs installed bins. Yarn 1 has no `dlx`, so (c) uses npx there.

```bash
bash "<skill-dir>/scripts/shadcn-cmd.sh"                  # {"prefix":"pnpm exec shadcn","source":"project",...}
bash "<skill-dir>/scripts/shadcn-cmd.sh" --cwd apps/web   # resolve for a workspace
bash "<skill-dir>/scripts/shadcn-cmd.sh" --prefix         # the bare prefix, for scripts
```

The references write the resolved prefix as `$SHADCN`. An agent types the literal prefix
in each command (`pnpm exec shadcn info --json`): a shell variable is gone by the next tool
call, and only the literal forms match the skill's pre-approved `allowed-tools`. In a
script or CI job that runs in one shell, `SHADCN="$(bash .../shadcn-cmd.sh --prefix)"` is
fine.

Exit 10 means the project declares shadcn but `node_modules` lacks it: run the frozen
install first (`npm ci`, `pnpm install --frozen-lockfile`, `yarn install --immutable`,
`bun ci`). Exit 5 means nothing pinned is available; `--no-dlx` makes that the answer instead
of a one-off download. Inside package.json scripts, write plain `shadcn ...`: the package
manager already puts `node_modules/.bin` on PATH.

## Commands

| Command | What it does | Notes |
|---|---|---|
| `init` (alias `create`) | sets up components.json, CSS, utils; with `--name` scaffolds a new app | `--base base|radix|aria`, `--template`, `--preset`, `--monorepo`, `--force`, `--rtl`, `--no-css-variables` |
| `add` | copies registry items into the project and installs their npm dependencies | `--dry-run`, `--diff [path]`, `--view [path]`, `-o/--overwrite`, `-a/--all`, `-p/--path` |
| `view` | prints registry items (metadata and file contents) without a project | for browsing before an `add` |
| `search` (alias `list`) | fuzzy search across registries | `-q`, `-t ui,block,hook`, `--json`; namespaces, `owner/repo` and URLs |
| `docs` | prints docs, example and API URLs for components | `--base` to read another base's API, `--json` |
| `info` | project facts: framework, Tailwind version, aliases, resolved paths, installed components | `--json`; run it first |
| `apply` | applies a preset to an existing project; overwrites detected components | `--only theme,font` for a partial apply |
| `preset` | `decode <code>`, `resolve` (alias `info`), `url <code>`, `open <code>` | never decode a preset code by hand |
| `migrate` | codemods: `cn`, `icons`, `base-color`, `radix`, `rtl` | `--list`, `-f/--from`, `-t/--to`; see migrations-and-eject.md |
| `eject` | inlines `shadcn/tailwind.css` into your CSS and removes the shadcn dependency | irreversible; see migrations-and-eject.md |
| `build` | turns `registry.json` into served JSON files (default `./public/r`) | registry-authoring.md |
| `registry` | `add [registries...]` writes registries into components.json; `validate [registry]` | |
| `mcp` | starts the MCP server; `mcp init --client claude|cursor|vscode|codex|opencode` writes a config | mcp.md explains why not for Claude Code |
| `diff` | deprecated | use `add <item> --diff` |

There is no `--package-manager` flag: the CLI detects the manager from the lockfile. Don't
invent flags; `$SHADCN <command> --help` is the authority for the pinned version.

## Flags worth knowing

- **`-y/--yes`** skips the confirmation. `init` defaults it to true; `add`, `apply`,
  `migrate` and `eject` default it to false. Never pass `-y` to `apply`, `eject` or
  `add --overwrite` without the user's OK.
- **`init` without `--preset` or `--base` stops at an interactive library prompt** even with
  `-y`. In scripts and agents pass one of them, plus `--no-monorepo` (or `--monorepo`).
- **`--dry-run` / `--diff` / `--view`** write nothing. `--diff` and `--view` imply
  `--dry-run`; without a path they show the first five files.
- **`-c/--cwd`** runs against another folder (a monorepo workspace).

```bash
$SHADCN init --base base --template vite --name admin --no-monorepo   # new app, Base UI
$SHADCN add button card dialog table
$SHADCN add @shadcn/sidebar --dry-run
$SHADCN add button --diff button.tsx
$SHADCN search @shadcn -q "chart" -t block
$SHADCN docs data-table field --json
```

## Templates and presets

Templates for `init --template`: `next`, `start` (TanStack Start), `vite`, `react-router`,
`laravel`, `astro`. All but Laravel take `--monorepo`.

A preset is a short code (or a named style, or a ui.shadcn.com/init URL) that packs style,
colours, fonts, radius and icon library. Pass it through untouched:

```bash
$SHADCN init --preset base-nova --template next --name admin --no-monorepo
$SHADCN preset decode a2r6bw          # what a code contains
$SHADCN preset resolve --json         # what this project uses
$SHADCN apply a2r6bw --only theme     # colours only, components untouched
```

Switching presets is a project-wide rewrite: theming.md covers the four ways (overwrite,
partial, merge, skip) and which to choose.

## Updating installed components

Installed components are your source code. Never re-add over local edits blind:

1. `$SHADCN add <item> --dry-run` lists every file it would touch.
2. `$SHADCN add <item> --diff <file>` per file: upstream versus local.
3. No local edits in a file: overwrite it. Local edits: apply the upstream change by hand and
   keep yours.
4. `--overwrite` only when the user says so, after a commit.

Don't fetch component source from GitHub by hand: the CLI resolves the right style, base
and aliases for this project.

## Bumping the pin

The pin is `cli.version` in `assets/shadcn-facts.json`. The weekly `--live` check fails when
the pin is older than 60 days and a newer release has passed the cooldown, when a new major
ships, or when a release gains install scripts. To bump:

1. Pick the newest release that is at least 7 days old (`npm view shadcn time --json`).
2. Check it: `npm view shadcn@<v> scripts` (no `preinstall`/`install`/`postinstall`), a
   Socket score (the depscore MCP, or supply-chain-defense's `preinstall-check.sh`), and
   the changelog at ui.shadcn.com/docs/changelog for removed commands or flags.
3. In one commit: `cli.version`, `cli.published`, `as_of` in the facts file; the pinned forms
   in SKILL.md's `allowed-tools`; the prose tokens; the "Versions verified" note.
4. Run `check-shadcn-facts.py --offline`, then `--live` with that version installed
   (`npm install -g --ignore-scripts shadcn@<v>`) so the `--help` comparison runs.
5. Re-record the coupled test fixtures in `tests/fixtures/live/` from that version:
   `version.txt`, `help.txt`, `init-help.txt` and `migrate-list.txt` from its own output
   (replace the machine's default `--cwd` path with `/work`), and the new version's entry
   in `npm-shadcn.json` (`dist-tags`, `time`, `versions`). Move `--today` in
   `tests/check-resources.sh` and the suite to the new `as_of`. Fenced examples that name the
   exact pin are reported by `--offline` until updated.
