# components.json: what the CLI reads

The CLI reads `components.json` to decide where files go, which component flavour to fetch
and how to write imports. Facts from ui.shadcn.com/docs/components-json and the published
schema (https://ui.shadcn.com/schema.json), checked 2026-11-10.

## Contents

- [A v4 file](#a-v4-file)
- [Fields](#fields)
- [Styles and bases](#styles-and-bases)
- [Aliases must resolve](#aliases-must-resolve)
- [Tailwind v3 or v4](#tailwind-v3-or-v4)
- [Reading it as an agent](#reading-it-as-an-agent)

## A v4 file

```json
{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "base-nova",
  "rsc": true,
  "tsx": true,
  "tailwind": { "config": "", "css": "app/globals.css", "baseColor": "neutral", "cssVariables": true },
  "iconLibrary": "lucide",
  "aliases": {
    "components": "@/components",
    "utils": "@/lib/utils",
    "ui": "@/components/ui",
    "lib": "@/lib",
    "hooks": "@/hooks"
  }
}
```

## Fields

| Field | Required | Meaning | Change after init? |
|---|---|---|---|
| `style` | yes | `<base>-<style>`, or legacy `new-york` / `default` | no: re-add components |
| `tailwind.config` | yes | path to tailwind.config.* for v3; `""` for v4 | |
| `tailwind.css` | yes | the global CSS file that imports Tailwind; theme variables live here | |
| `tailwind.baseColor` | yes | `neutral`, `stone`, `zinc`, `mauve`, `olive`, `mist`, `taupe` | no (`migrate base-color` rewrites it) |
| `tailwind.cssVariables` | yes | `true` = semantic tokens (`bg-primary`); `false` = inline colour utilities | no: re-add components |
| `tailwind.prefix` | no | utility prefix such as `tw-` | |
| `rsc` | yes | `true` makes the CLI add `"use client"` to client components | |
| `tsx` | no | `false` writes `.jsx` | |
| `iconLibrary` | no | `lucide`, `tabler`, `hugeicons`, `phosphor`, `remixicon`; components import from it | `migrate icons` |
| `aliases.utils`, `aliases.components` | yes | import aliases; `ui`, `lib`, `hooks` optional | |
| `menuColor`, `menuAccent` | no | menu surface (`default`, `inverted`, `*-translucent`) and accent (`subtle`, `bold`) | |
| `rtl` | no | right-to-left support; `migrate rtl` sets it | |
| `registries` | no | `@namespace` to URL template or `{url, headers, params}` | supply-chain-and-registries.md |

## Styles and bases

The base is the primitive library under the components, encoded as the style's prefix:

| Base | Package | Since |
|---|---|---|
| `base` | `@base-ui/react` | default for new projects since July 2026 |
| `radix` | `radix-ui` (the unified package) | the original; still fully supported |
| `aria` | `react-aria-components` | July 2026 |

Styles: `vega` (classic), `nova` (compact), `maia` (soft, generous), `lyra` (boxy),
`mira` (dense), `luma` (rounded, soft elevation), `rhea` (luma, more compact), `sera`
(editorial, typographic). So `base-maia`, `radix-nova`, `aria-lyra`. The legacy styles are
Radix-based: `new-york` (still served) and `default` (retired). `$SHADCN info --json` reports
`base` and `style` separately. bases.md covers the API differences.

## Aliases must resolve

Aliases are import specifiers, and the CLI turns them into file paths through the same
mappings TypeScript uses:

- `compilerOptions.paths` in `tsconfig.json` / `jsconfig.json`. A Vite app has two
  configs; shadcn's Vite guide puts `"@/*": ["./src/*"]` in both `tsconfig.json` and
  `tsconfig.app.json`.
- `package.json#imports` (`"#components/*": "./src/components/*.tsx"`), supported since
  May 2026; a target with an extension makes the CLI write extensionless imports.
- In a monorepo, a workspace package name (`@workspace/ui/components`) through paths or the
  package's `exports`.

Two failure shapes, both reported by the audit: an alias no mapping matches
(`alias-unresolved`), and a mapping that points into a tree that doesn't exist, typically a
`src/` prefix the project doesn't use (`alias-missing`). Either way `add` writes files your
imports can't find, or creates a second component folder.

## Tailwind v3 or v4

| Signal | v3 | v4 |
|---|---|---|
| `tailwind.config` in components.json | a file path | `""` |
| global CSS | `@tailwind base; @tailwind components; @tailwind utilities;` | `@import "tailwindcss";` |
| theme tokens | HSL triplets, colours registered in tailwind.config | OKLCH values, `@theme inline` |
| animations | `tailwindcss-animate` plugin | `tw-animate-css` import |
| shared utilities | none | `@import "shadcn/tailwind.css"` (from the shadcn devDependency) |

New projects start on Tailwind CSS v4 and React 19. Components fetched for a v4 project use
`data-slot`, `size-*`, no `forwardRef`. Mixing v4 components into a v3 project, or the
reverse, produces silently wrong styling: upgrade first (migrations-and-eject.md).

## Reading it as an agent

Run `$SHADCN info --json` before writing code and use its fields, never assumptions:

- `aliases` / `resolvedPaths`: import prefixes and where files live.
- `isRSC`: components with state, effects, handlers or browser APIs need `"use client"`.
- `tailwindVersion` and `tailwindCssFile`: where and how to add tokens (theming.md).
- `base`: `asChild` (radix) vs `render` (base) vs React Aria's own props (bases.md).
- `iconLibrary`: which package icons come from. Never assume `lucide-react`.
- installed components: don't import what isn't installed, don't re-add what is.
