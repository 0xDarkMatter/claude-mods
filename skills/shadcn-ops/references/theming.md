# Theming with CSS variables (Tailwind CSS v4), presets and apply

Components never hard-code colours: they use semantic utilities (`bg-primary`) backed by CSS
variables in the global CSS file. Change a variable and every component follows. Facts from
ui.shadcn.com/docs/theming, /tailwind-v4, /cli and the changelog, checked 2026-11-10; the
custom-colour steps are adapted from the official shadcn skill's `customization.md`
(shadcn-ui/ui, MIT licence).

## Contents

- [The global CSS file](#the-global-css-file)
- [Tokens](#tokens)
- [Adding a colour](#adding-a-colour)
- [Radius](#radius)
- [Customising a component](#customising-a-component)
- [Presets, apply and switching](#presets-apply-and-switching)
- [Tailwind v3 projects](#tailwind-v3-projects)

## The global CSS file

Edit the file `tailwind.css` points at (`$SHADCN info --json`: `tailwindCssFile`); never
create a second theme file.

```css
@import "tailwindcss";
@import "tw-animate-css";
@import "shadcn/tailwind.css";          /* shared variants (data-open:, data-closed:) and utilities */

@custom-variant dark (&:is(.dark *));

:root {
  --radius: 0.625rem;
  --background: oklch(1 0 0);
  --foreground: oklch(0.145 0 0);
  --primary: oklch(0.205 0 0);
  --primary-foreground: oklch(0.985 0 0);
  /* ... */
}
.dark {
  --background: oklch(0.145 0 0);
  --foreground: oklch(0.985 0 0);
  /* ... the same names, dark values */
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  /* ... one --color-* per token, plus the radius scale */
}
```

`:root` and `.dark` sit outside `@layer base`; `@theme inline` maps each variable to a
Tailwind colour so `bg-primary` and `text-primary-foreground` exist.

## Tokens

Each surface token pairs with a `-foreground` for text and icons on it:

| Token | Use |
|---|---|
| `background` / `foreground` | the page |
| `card`, `popover` (+ `-foreground`) | raised surfaces and overlays |
| `primary`, `secondary`, `accent`, `muted` (+ `-foreground`) | actions, hover states, quiet text (`text-muted-foreground`) |
| `destructive` | errors and destructive actions |
| `border`, `input`, `ring` | lines, input borders, focus rings |
| `chart-1` to `chart-5` | chart series (charts.md) |
| `sidebar`, `sidebar-foreground`, `sidebar-primary`, `sidebar-accent`, `sidebar-border`, `sidebar-ring` | the sidebar shell |

Values are OKLCH (`oklch(lightness chroma hue)`); base colours are neutral, stone, zinc,
mauve, olive, mist and taupe (`migrate base-color` switches between them).

## Adding a colour

A status colour the theme lacks (warning, success) becomes a token, not a raw utility:

```css
:root  { --warning: oklch(0.84 0.16 84);  --warning-foreground: oklch(0.28 0.07 46); }
.dark  { --warning: oklch(0.41 0.11 46);  --warning-foreground: oklch(0.99 0.02 95); }
@theme inline {
  --color-warning: var(--warning);
  --color-warning-foreground: var(--warning-foreground);
}
```

Then `bg-warning text-warning-foreground`, or a `warning` variant in the Badge or Alert
`cva`. Check both pairs for contrast (4.5:1 for text).

## Radius

`--radius` is the base; v4 themes derive a scale from it: `--radius-sm` = 0.6x,
`--radius-md` = 0.8x, `--radius-lg` = 1x, `--radius-xl` = 1.4x, up to `--radius-4xl` =
2.6x. A brand with its own scale pins each step in `@theme inline` instead of deriving.

## Customising a component

In order of preference:

1. A built-in variant (`variant="outline"`, `size="sm"`).
2. Layout classes through `className` (`max-w-md`, `mx-auto`).
3. A new variant in the component's `cva` (it is your source file):
   `warning: "bg-warning text-warning-foreground hover:bg-warning/90"`.
4. A wrapper component that composes primitives (a `ConfirmDialog` around `AlertDialog`).

Restyling a whole design system from a brand spec is design-systems.md.

## Presets, apply and switching

A preset (named style like `nova`, a short code like `a2r6bw`, or a ui.shadcn.com/init URL)
fixes style, colours, fonts, radius and icon library. Codes are opaque: inspect with
`$SHADCN preset decode <code>`, see the project's current one with `preset resolve`.

Switching presets rewrites the project; ask the user which of these they want, and commit
first:

| Choice | Command | Effect |
|---|---|---|
| Overwrite | `$SHADCN apply <code>` | config, fonts, CSS variables and every detected component |
| Partial | `$SHADCN apply <code> --only theme,font` | colours and/or fonts only; components untouched (`icon` is not a partial option) |
| Merge | `$SHADCN init --preset <code> --force --no-reinstall`, then per component `add --dry-run` / `--diff` | new config and CSS; components merged one by one, keeping local edits |
| Skip | `$SHADCN init --preset <code> --force --no-reinstall` | config and CSS only |

`apply` needs an existing components.json and keeps the project's base; preset codes don't
encode the base, so pass `--base` when you try one in a scratch folder.

## Tailwind v3 projects

v3 themes use HSL triplets in `@layer base` and register colours in `tailwind.config.js`
(`warning: "hsl(var(--warning) / <alpha-value>)"`), with the `tailwindcss-animate` plugin.
New components target v4; upgrade before mixing (migrations-and-eject.md). Tailwind itself
(utilities, `@theme`, plugins, the v4 engine) is tailwind-ops' subject.
