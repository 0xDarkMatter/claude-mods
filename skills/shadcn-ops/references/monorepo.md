# shadcn/ui in a monorepo

Facts from ui.shadcn.com/docs/monorepo and the CLI's own monorepo templates
(`templates/*-monorepo` in shadcn-ui/ui), checked 2026-11-10.

## Layout

`$SHADCN init --monorepo --template next` (or vite, start, react-router, astro; Laravel has
no monorepo template) scaffolds a Turborepo with two workspaces:

```text
apps/web/            the app; its own components.json
packages/ui/         shared components, hooks, utils and the global CSS; its own components.json
  src/components/    ui components land here
  src/styles/globals.css
```

## The two components.json files

| Field | apps/web | packages/ui |
|---|---|---|
| `tailwind.css` | `../../packages/ui/src/styles/globals.css` | `src/styles/globals.css` |
| `aliases.ui` | `@workspace/ui/components` | `@workspace/ui/components` |
| `aliases.utils` | `@workspace/ui/lib/utils` | `@workspace/ui/lib/utils` |
| `aliases.components` | `@/components` (app-level compositions) | `@workspace/ui/components` |

- `style`, `iconLibrary` and `baseColor` must be identical in both files (the audit's
  `monorepo-mismatch`).
- `tailwind.config` is `""` in both (Tailwind CSS v4).
- The app resolves `@workspace/ui/*` through `paths` (`"@workspace/ui/*":
  ["../../packages/ui/src/*"]`) or through the ui package's `exports`
  (`"./components/*": "./src/components/*.tsx"`).

## Adding components

Run `add` against the app, not the root:

```bash
bash "<skill-dir>/scripts/shadcn-cmd.sh" --cwd apps/web --prefix   # e.g. pnpm dlx shadcn@4.23.0
$SHADCN add button -c apps/web         # writes packages/ui/src/components/button.tsx
```

The CLI routes `ui` items into `packages/ui` and app-level blocks into `apps/web`, and
rewrites imports to `@workspace/ui/components/...`. At the monorepo root, `add`, `apply`,
`init`, `info`, `preset` and `eject` stop and list the workspaces instead.

The resolver looks for shadcn from the folder you name up to the install root. The root
lockfile counts for `apps/web` only because the workspace patterns list it, and the walk
never crosses the git root. If only `packages/ui` declares shadcn, `--cwd apps/web`
resolves to a global or the pinned dlx form, reports `"workspace": "packages/ui"`, and
notes on stderr to run the CLI from that workspace with `--cwd` pointing back at the app.
The audit agrees: in `apps/web`, `cli-not-installed` drops to low, names the sibling
workspace that declares shadcn, and suggests `<runner> <command> --cwd <path>` from there
(or notes that its components.json already routes components into the app). To use a
locked copy from the app itself, add the same exact version to its devDependencies
(`pnpm --filter web add -D -E shadcn@4.23.0`).

## Gotchas

- **One lockfile, at the root.** Install shadcn as a devDependency where `init` put it (the
  ui package). The root lockfile counts for a workspace only when the root's workspace
  patterns list it; a lockfile above the git root never counts.
- **Tailwind must see the app's classes.** The shared `globals.css` needs `@source` lines
  that cover the apps (`@source "../../../apps/**/*.{ts,tsx}";`), or utilities used only in
  an app are never generated.
- **Audit each workspace**, not the root: `shadcn-audit.py apps/web` and
  `shadcn-audit.py packages/ui`. At a root without components.json it exits 3 and names the
  workspaces it found.
- Package-manager workspace mechanics (targeting a workspace, hoisting) belong to
  package-manager-ops.
