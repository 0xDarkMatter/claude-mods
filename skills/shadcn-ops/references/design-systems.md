# A design system from a brand spec (DESIGN.md)

Turning a brand spec into a themed shadcn/ui app and a page that shows every component.
Condensed from the official shadcn skill's `design-system.md` and `design-system-page.md`
(shadcn-ui/ui, MIT licence); the style list and flags were checked against
ui.shadcn.com and `shadcn init --help` (4.23.0) on 2026-11-10.

## Contents

- [Inputs](#inputs)
- [Scaffold and pick a style](#scaffold-and-pick-a-style)
- [Map tokens](#map-tokens)
- [Recipes to variants](#recipes-to-variants)
- [The design system page](#the-design-system-page)
- [Verify and report](#verify-and-report)

## Inputs

Confirm before starting: the spec (path, URL or pasted text; copy it into the app as
`DESIGN.md`), a preset code if the user has one, the template (`vite`, or `next` for
Next.js/SSR), the app name, and the base (`base` unless the user asks for `radix` or
`aria`). Don't guess a spec you can't read; ask for it.

## Scaffold and pick a style

```bash
$SHADCN init --preset <code> --template vite --name <app> --no-monorepo        # with a preset code
$SHADCN init --base base --preset <style> --template vite --name <app> --no-monorepo   # without one
$SHADCN add --all -y          # every component; count them from disk, never from memory
$SHADCN info --json           # base, style, iconLibrary, tailwindCssFile, aliases
```

Without a preset, pick the style whose geometry the CSS variables can't change (padding,
density, roundness, elevation) and say why in one line:

| Style | Pick when the spec has |
|---|---|
| `vega` | conventional SaaS geometry |
| `nova` | 32 to 36px controls, 6 to 8px radius, hairlines over shadows |
| `maia` | 40px+ controls, 12px+ card radius, generous padding |
| `lyra` | 0 to 4px radius, hard edges, technical or mono type |
| `mira` | dense data UIs, 28 to 32px controls, tight tables |
| `luma` | pill buttons, soft layered shadows, glassy surfaces |
| `rhea` | luma's softness at product density |
| `sera` | serif display type, editorial pacing |

Then wrap the app in `TooltipProvider` and the base's `Toaster` (bases.md), and typecheck
the app sources (`tsc -p tsconfig.app.json --noEmit` in Vite; the root tsconfig only holds
references and checks nothing).

## Map tokens

Read the spec's frontmatter, Do's and Don'ts and Known Gaps in full first: they override
defaults. Then edit only the global CSS file (theming.md):

| Spec role | shadcn variable |
|---|---|
| canvas, page floor | `--background` |
| ink, headline text | `--foreground`, `--card-foreground`, `--popover-foreground` |
| primary fill / on-primary | `--primary` / `--primary-foreground`; a pressed shade becomes a new `--primary-active` |
| secondary button | `--secondary` / `--secondary-foreground` |
| soft band; descriptive text | `--muted`; `--muted-foreground` |
| hover wash, active tab | `--accent` / `--accent-foreground` |
| card fill; menus and dialogs | `--card`; `--popover` |
| hairlines; focus; errors | `--border`, `--input`; `--ring`; `--destructive` |
| nav rail | `--sidebar-*` |

- Keep hex values when the spec gives hex. Every extra token gets a variable plus an
  `@theme inline` registration.
- **Radius:** pin each step (`--radius-sm` to `--radius-4xl`) in `@theme inline` instead of
  deriving from `--radius`; grep the installed components for the `rounded-*` classes they use.
- **Shadows:** override the scale in `@theme` (not `inline`), copying multi-layer shadows
  verbatim; `--shadow-xs: 0 0 #0000` for hairline-only systems.
- **Fonts:** licensed brand fonts get the spec's named substitutes from Fontsource (new
  dependencies: cooldown and scan); set `--font-sans`, `--font-serif`, `--font-mono` and
  `--font-heading` (small component titles: only a display face that reads at 16px).
- **Type scale:** one `@utility type-*` per typography token (clamped display sizes,
  tracking in `em`). Not `--text-*` theme keys: `cn()` treats unknown `text-*` classes as
  colours and drops one when it sits beside `text-muted-foreground`.
- **Dark:** spec dark surfaces go in `.dark`; `className="dark"` on a section renders a
  dark band. A light-only spec gets a derived dark theme, and you say it is derived.
- **Focus:** match the spec (ring alpha on field controls, or an unlayered
  `:focus-visible` outline with offset for actions).

## Recipes to variants

Restyle by editing `cva` variants in the installed components, keeping the standard variant
names: primary is Button `default`, a tinted secondary is `secondary`, canvas-plus-border is
`outline`, nav links are `ghost`, text links are `link`; badges and cards likewise. Control
heights move together: when the button height changes, change input, input-group, select,
native-select, combobox, toggle, input-otp, tabs, menubar and command to match (grep for the
style's default height class first). Follow documented states exactly (`active:` when the
spec says "darken on press"), and turn each "Don't" into a check before finishing.

## The design system page

One page (Vite `src/showcase/`, Next.js `app/design-system/`) in this order:

1. **Foundations:** colour roles as surface/foreground pairs with measured contrast ratios,
   the palette, a type specimen table, spacing, radius and elevation ladders.
2. **Components by tier:** primitives get a variant x state matrix (hover, focus, active,
   disabled pinned with data attributes rather than real interaction), sizes and an icon
   row; composed components get a real example and their edge cases; overlays get real
   triggers.
3. **Do/don't pairs** for the spec's rules, the spec's named recipes rebuilt from
   components, and one example screen.

Known traps: an inline `Command` scrolls its first item into view on mount (control its
value); `Sidebar` is `fixed` and escapes a preview frame (`SidebarProvider
className="min-h-0"` + `collapsible="none"`); a Base UI `Select` without `items` shows raw
values; `Resizable` (react-resizable-panels v4) takes `orientation` and string sizes.

Coverage, every installed component shown at least once:

```bash
for f in src/components/ui/*.tsx; do n="$(basename "$f" .tsx)"; rg -q "/ui/$n[\"']" src/showcase || echo "not shown: $n"; done
```

## Verify and report

Typecheck; no console errors; the page loads at the top (a component stealing scroll on
mount is a bug); no horizontal overflow at 375px and 1280px; dark mode toggled once;
screenshots compared with the spec (canvas, primary, display font, radius, focus). Report
the app path, component count from disk, the style and why, what maps where, contrast pairs
under 4.5:1 (including the spec's own), every edited component, and every deliberate
deviation (substituted fonts, derived dark theme, kept hover states).
