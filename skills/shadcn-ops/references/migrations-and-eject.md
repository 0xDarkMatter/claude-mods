# Migrations, upgrades and eject

Changes that rewrite many files at once. Each one goes on a clean tree, in its own commit
(or branch), with a typecheck and build after it. Commands from `shadcn migrate --list` and
`--help` of shadcn 4.23.0; behaviour from ui.shadcn.com/docs/cli, /tailwind-v4 and the
changelog, checked 2026-11-10.

## Contents

- [The migrate command](#the-migrate-command)
- [Tailwind v3 to v4](#tailwind-v3-to-v4)
- [React 18 to 19](#react-18-to-19)
- [Other moves the changelog asks for](#other-moves-the-changelog-asks-for)
- [Eject](#eject)

## The migrate command

```bash
$SHADCN migrate --list
$SHADCN migrate cn                               # clsx + tailwind-merge -> the cn package
$SHADCN migrate icons --from lucide --to tabler  # swap the icon library in your components
$SHADCN migrate base-color --to zinc             # rewrite theme variables to another base colour
$SHADCN migrate radix                            # @radix-ui/react-* imports -> the unified radix-ui package
$SHADCN migrate rtl                              # physical -> logical classes, rtl: true
$SHADCN migrate radix "src/components/ui/**"     # an optional path or glob limits the scope
```

| Migration | What it rewrites | Watch for |
|---|---|---|
| `migrate cn` | `twMerge(clsx(...))` and imports from `clsx`/`tailwind-merge` to `cn`; removes those packages once unused | v4 only: Tailwind v3 projects stay on tailwind-merge 2. Optional: nothing breaks if you skip it |
| `migrate icons` | icon imports and names across components; `iconLibrary` in components.json | libraries: lucide, tabler, hugeicons, phosphor, remixicon, radix (legacy). Check icons with no equivalent |
| `migrate base-color` | the theme's CSS variables and `baseColor` | your own custom tokens are untouched; review the diff |
| `migrate radix` | `@radix-ui/react-*` imports to `radix-ui`, adds the package | then remove the unused `@radix-ui/react-*` packages yourself. It does not switch you to Base UI |
| `migrate rtl` | `ml-4` to `ms-4` and similar, adds `rtl:` variants, sets `rtl: true` | check custom components the CLI didn't write |

`migrate` asks before writing unless `-y`; run it without `-y` the first time and read the
plan.

## Tailwind v3 to v4

The upgrade order from the shadcn docs:

1. Run Tailwind's own upgrade codemod and guide (tailwind-ops covers the engine side:
   `@import "tailwindcss"`, `@theme`, removed utilities, the PostCSS or Vite plugin).
2. Move `:root` and `.dark` out of `@layer base`, wrap the HSL values in `hsl()` (or convert
   to OKLCH), and add an `@theme inline` block mapping each variable to `--color-*`.
3. Charts: `hsl(var(--chart-1))` becomes `var(--chart-1)` in every chart config.
4. Replace `w-* h-*` pairs with `size-*`.
5. Replace `tailwindcss-animate` with `tw-animate-css` (devDependency, `@import
   "tw-animate-css";`, delete the `@plugin` line).
6. Set `tailwind.config` to `""` in components.json.
7. Update the primitive packages and re-add components you haven't customised
   (`add <item> --diff` first for those you have).

Only new projects start on Tailwind CSS v4 and React 19; existing v3 apps keep working on the
`new-york` components. Don't half-migrate: one project, one line.

## React 18 to 19

Components for Tailwind v4 dropped `forwardRef` and take `ref` as a plain prop, which only
React 19 passes through. On React 18 those refs never reach the DOM (focus management and
popover positioning quietly break), so the audit reports `react-pre-19`. Upgrade React first
(react-ops), then the components. npm may stop on peer-dependency ranges that don't list
React 19 yet: fix or replace the package rather than reaching for `--legacy-peer-deps`.

## Other moves the changelog asks for

- **Toast (Radix):** the old `toast` + `use-toast` is deprecated; move to Sonner. Base UI
  projects use the newer Base UI `toast` component (bases.md).
- **Default style:** `default` is retired; new-york and the base-prefixed styles are live.
  Changing style means re-adding components (style is fixed at init).
- **Recharts v3:** the chart notes in charts.md.
- **TanStack Table v9:** a v8 data table keeps working; a v9 rewrite is its own change
  (data-tables.md).
- **`diff` command:** deprecated; use `add <item> --diff`.

## Eject

```bash
$SHADCN eject            # asks first; -y skips the question
```

`eject` copies the contents of `shadcn/tailwind.css` into your global CSS (with a
`/* ejected from shadcn@<version> */` marker) and uninstalls the `shadcn` package with your
package manager. The CLI warns "This action is not reversible": from then on, fixes to the
shared variants, utilities and RTL rules that ship in that file no longer reach you.

- Eject only when the user asks and understands that. Reasons that hold: a policy against
  build-time imports from a CLI package, or a heavily customised copy of those rules.
- It also removes the pinned CLI from devDependencies, so afterwards `shadcn-cmd.sh`
  falls back to the pinned one-off runner. Re-add the devDependency if the team still uses
  the CLI: `<pm> add -D -E shadcn@<pin>` (the import is gone, so it is a tool again, not a
  build dependency).
- In a monorepo, run it in the workspace that holds the CSS (`packages/ui`); at the root it
  stops and lists workspaces.
- Undoing it means restoring the commit before it. Commit first.
