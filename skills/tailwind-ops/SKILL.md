---
name: tailwind-ops
description: "Tailwind CSS utility patterns, responsive design, component patterns, v4 migration, and configuration. Use for: tailwind, tailwindcss, utility classes, responsive design, dark mode, tailwind v4, tailwind config, tw, container queries, @apply, prose, typography, animation."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "react-ops, vue-ops, astro-ops, craftcms-ops, frontend-upgrade-ops, web-perf-ops"
---

# Tailwind Operations

Comprehensive Tailwind CSS patterns covering layout, responsive design, components, dark mode, animations, and v4 migration.

> Tailwind v4 ecosystem facts verified as of 2026-07.

## Layout Decision Tree

```
Which layout approach?
│
├─ Items in a single row or column?
│  └─ Use Flexbox
│     ├─ Row:    class="flex items-center gap-4"
│     ├─ Column: class="flex flex-col gap-4"
│     ├─ Wrap:   class="flex flex-wrap gap-4"
│     └─ Push item to end: class="flex" + child class="ml-auto"
│
├─ Items in a 2D grid (rows AND columns)?
│  └─ Use CSS Grid
│     ├─ Equal columns:   class="grid grid-cols-3 gap-6"
│     ├─ Responsive grid:  class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6"
│     ├─ Sidebar layout:  class="grid grid-cols-[250px_1fr] gap-6"
│     ├─ Spanning:         child class="col-span-2" or "row-span-2"
│     └─ Auto-fill:        class="grid grid-cols-[repeat(auto-fill,minmax(250px,1fr))] gap-6"
│
├─ Component should adapt to its CONTAINER size (not viewport)?
│  └─ Use Container Queries (v3.2+ / v4 native)
│     ├─ Parent:  class="@container"
│     ├─ Child:   class="@sm:flex-row @lg:grid-cols-3"
│     └─ Named:   class="@container/sidebar" → child: "@sm/sidebar:flex-row"
│
├─ Centering something?
│  ├─ Horizontal text:  class="text-center"
│  ├─ Horizontal block: class="mx-auto" (needs width)
│  ├─ Flex center:      class="flex items-center justify-center"
│  ├─ Grid center:      class="grid place-items-center"
│  └─ Absolute center:  class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2"
│
└─ Full-page layout (header/sidebar/content/footer)?
   └─ Use Grid with named areas or template rows
      ├─ Sticky header:  class="grid grid-rows-[auto_1fr_auto] min-h-screen"
      └─ Sidebar + main: class="grid grid-cols-[250px_1fr] min-h-screen"
```

## Responsive Design Quick Reference

### Breakpoints (Mobile-First)

| Prefix | Min Width | Typical Target |
|--------|-----------|----------------|
| _(none)_ | 0px | Mobile (default) |
| `sm:` | 640px | Large phones, landscape |
| `md:` | 768px | Tablets |
| `lg:` | 1024px | Small laptops |
| `xl:` | 1280px | Desktops |
| `2xl:` | 1536px | Large screens |

**Mobile-first means**: base styles apply to mobile, add breakpoint prefixes to override upward.

```html
<!-- Stack on mobile, 2 columns on tablet, 3 on desktop -->
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
  <div>Card 1</div>
  <div>Card 2</div>
  <div>Card 3</div>
</div>

<!-- Hide on mobile, show on desktop -->
<nav class="hidden lg:flex items-center gap-6">...</nav>

<!-- Full width on mobile, constrained on desktop -->
<div class="w-full max-w-3xl mx-auto px-4 sm:px-6 lg:px-8">...</div>
```

### Container Queries

```html
<!-- Parent declares itself as a container -->
<div class="@container">
  <!-- Children respond to PARENT width, not viewport -->
  <div class="flex flex-col @sm:flex-row @lg:grid @lg:grid-cols-3 gap-4">
    <div>Adapts to container</div>
  </div>
</div>

<!-- Named container (useful when nesting) -->
<div class="@container/card">
  <h2 class="text-sm @md/card:text-lg">Responds to card container</h2>
</div>
```

### Fluid Typography with clamp()

```html
<!-- Fluid heading: 1.5rem at small, 3rem at large, scales between -->
<h1 class="text-[clamp(1.5rem,4vw,3rem)]">Fluid Heading</h1>

<!-- Fluid body text -->
<p class="text-[clamp(0.875rem,1.5vw,1.125rem)] leading-relaxed">
  Body text that scales smoothly.
</p>
```

## Dark Mode Decision Tree

```
Which dark mode strategy?
│
├─ Manual toggle (user preference stored)?
│  └─ class strategy (v3) / selector strategy (v4)
│
│     v3: tailwind.config.js
│     module.exports = { darkMode: 'class' }
│     → Add class="dark" to <html> element
│
│     v4: CSS @custom-variant or default behavior
│     @custom-variant dark (&:where(.dark, .dark *));
│     → Same toggle, add class="dark" to <html>
│
├─ Follow system preference only?
│  └─ media strategy
│
│     v3: tailwind.config.js
│     module.exports = { darkMode: 'media' }
│     → Uses prefers-color-scheme automatically
│
│     v4: Default behavior (no config needed)
│     → Uses prefers-color-scheme out of the box
│
└─ Custom selector (data attribute, etc.)?
   └─ selector strategy (v4 only)

      v4: @custom-variant dark (&:where([data-theme="dark"], [data-theme="dark"] *));
      → Add data-theme="dark" to <html>
```

### Dark Mode Patterns

```html
<!-- Background and text -->
<div class="bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100">

  <!-- Card with dark variant -->
  <div class="bg-gray-50 dark:bg-gray-800 rounded-lg p-6 border border-gray-200 dark:border-gray-700">
    <h3 class="text-gray-900 dark:text-white font-semibold">Card Title</h3>
    <p class="text-gray-600 dark:text-gray-400">Card content adapts to dark mode.</p>
  </div>

  <!-- Input with dark variant -->
  <input type="text"
    class="bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
           text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500
           focus:ring-2 focus:ring-blue-500 rounded-lg px-4 py-2"
    placeholder="Type here...">
</div>
```

## Component Patterns Quick Reference

Copy-paste snippets for a card, button variants, a form input, navbar, modal overlay, badge and alert: [Component Patterns Quick Reference](references/component-patterns.md#component-patterns-quick-reference), at the top of the component reference that goes deeper per component.

## Tailwind v4 Quick Reference

### Major Changes from v3

| Area | v3 | v4 |
|------|----|----|
| Configuration | `tailwind.config.js` | CSS-first: `@theme` in CSS |
| Theme values | JS `theme.extend.colors` | `@theme { --color-brand: #3b82f6; }` |
| Plugins | JS `plugin()` function | `@plugin "my-plugin"` in CSS |
| Config file | `module.exports = {...}` | `@config "./legacy.config.js"` (compat) |
| PostCSS | `tailwindcss` package | `@tailwindcss/postcss` |
| Vite | PostCSS plugin | `@tailwindcss/vite` (faster) |
| Colors | Named scales (gray-50..950) | Same + OKLCH support |
| Container queries | Plugin required | Native `@container`, `@sm:`, `@md:` |
| Entry animations | JS needed | `@starting-style` (CSS native) |

On a site still building with Laravel Mix, move to Vite on Tailwind v3 first
(`frontend-upgrade-ops`), then do v4 as its own change with its own visual diff.

### v4 CSS-First Config

```css
/* v4: Define theme in CSS */
@import "tailwindcss";

@theme {
  --color-brand: #3b82f6;
  --color-brand-dark: #1d4ed8;
  --font-display: "Inter", sans-serif;
  --breakpoint-3xl: 1920px;
  --spacing-18: 4.5rem;
}

/* v4: Import a plugin */
@plugin "@tailwindcss/typography";

/* v4: Use legacy JS config as fallback */
@config "./tailwind.config.js";
```

### v4 New Utilities

```html
<!-- Container queries (native in v4) -->
<div class="@container">
  <div class="@sm:flex @md:grid @md:grid-cols-2">Adapts to container</div>
</div>

<!-- @starting-style: entry animations without JS -->
<!-- Applied via CSS - Tailwind v4 supports it natively -->

<!-- Anchor positioning (experimental) -->
<!-- Position elements relative to an anchor element via CSS -->

<!-- New shadow and ring defaults -->
<div class="shadow-sm ring ring-blue-500/20">Improved defaults</div>
```

## Animation Patterns

Transition utilities, built-in animations (spin, pulse, ping, bounce), custom keyframes for v3 config and v4 `@theme`, and `@starting-style` entry animations: [references/animation-patterns.md](references/animation-patterns.md).

## State Modifiers Quick Reference

| Modifier | Triggers On | Example |
|----------|-------------|---------|
| `hover:` | Mouse hover | `hover:bg-blue-700` |
| `focus:` | Element focused (all focus) | `focus:ring-2` |
| `focus-visible:` | Keyboard focus only | `focus-visible:outline-2` |
| `focus-within:` | Child is focused | `focus-within:ring-2` |
| `active:` | Being clicked/pressed | `active:scale-95` |
| `disabled:` | `disabled` attribute | `disabled:opacity-50 disabled:cursor-not-allowed` |
| `group-hover:` | Parent `.group` hovered | `group-hover:text-blue-600` |
| `group-focus:` | Parent `.group` focused | `group-focus:ring-2` |
| `peer-checked:` | Sibling `.peer` checked | `peer-checked:bg-blue-600` |
| `peer-invalid:` | Sibling `.peer` invalid | `peer-invalid:text-red-500` |
| `data-[state=open]:` | Custom data attribute | `data-[state=open]:rotate-180` |
| `aria-expanded:` | `aria-expanded="true"` | `aria-expanded:bg-gray-100` |
| `aria-selected:` | `aria-selected="true"` | `aria-selected:font-bold` |
| `open:` | `<details>` or `<dialog>` open | `open:bg-gray-50` |
| `first:` | First child | `first:rounded-t-lg` |
| `last:` | Last child | `last:rounded-b-lg` |
| `odd:` | Odd children | `odd:bg-gray-50` |
| `even:` | Even children | `even:bg-white` |
| `placeholder:` | Placeholder text | `placeholder:text-gray-400` |
| `motion-reduce:` | Prefers reduced motion | `motion-reduce:transition-none` |
| `motion-safe:` | No motion preference | `motion-safe:animate-bounce` |
| `print:` | Print media | `print:hidden` |

### Group and Peer Patterns

```html
<!-- Group: parent state affects children -->
<a href="#" class="group flex items-center gap-3 p-3 rounded-lg hover:bg-gray-100">
  <div class="w-10 h-10 bg-gray-200 group-hover:bg-blue-100 rounded-lg"></div>
  <span class="text-gray-700 group-hover:text-blue-600">Hover the whole card</span>
</a>

<!-- Named groups (nested groups) -->
<div class="group/card p-4">
  <div class="group/button">
    <span class="group-hover/card:text-blue-600 group-hover/button:underline">
      Responds to specific parent
    </span>
  </div>
</div>

<!-- Peer: sibling state affects next sibling -->
<input type="checkbox" class="peer sr-only" id="toggle">
<label for="toggle" class="peer-checked:bg-blue-600 peer-checked:text-white px-4 py-2 rounded-lg cursor-pointer">
  Toggle me
</label>

<!-- Form validation with peer -->
<input type="email" class="peer" required>
<p class="hidden peer-invalid:block text-sm text-red-500 mt-1">
  Please enter a valid email.
</p>
```

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| Dynamic class names don't work: `` `bg-${color}-500` `` | Tailwind scans source for complete class strings at build time. String interpolation produces classes it never sees. | Use complete classes: `const colors = { red: 'bg-red-500', blue: 'bg-blue-500' }` and select by key. |
| Styles not applying (specificity) | Another CSS rule or `@apply` has higher specificity. | Use `!important` modifier: `!text-red-500`. Or restructure to avoid conflicts. |
| `@apply` breaks with component libraries | `@apply` resolves at build time and can't access runtime theme values or conflict with scoped styles. | Prefer inline utility classes. Reserve `@apply` for base styles or markdown content. |
| Prose plugin styles leak | `@tailwindcss/typography` `prose` applies broad element selectors (h1, p, a, etc.). | Scope with `prose` only on content wrappers. Use `not-prose` class to exclude sections. |
| Classes missing in production | JIT content detection didn't scan the file containing the class. | Ensure `content` paths in config cover all template files including component libraries. |
| Dark mode flash (FOUC) | Class-based dark mode renders light first until JS adds `dark` class. | Add inline `<script>` in `<head>` that reads localStorage and sets `dark` class before paint. |
| Container queries not scoped | Child `@sm:` responds to nearest `@container` ancestor, which may not be the intended one. | Use named containers: `@container/card` and `@sm/card:flex`. |
| Arbitrary values vs config | `w-[137px]` works but creates one-off values. Repeated arbitrary values signal missing design tokens. | Add recurring values to theme config: `spacing: { '137': '137px' }`. |
| `group` / `peer` naming collisions | Nested groups without names cause children to respond to wrong ancestor. | Use named groups: `group/card`, `group/button`. |
| Responsive order matters | Adding `lg:flex` without base `block` or `hidden` can cause unexpected behavior on smaller screens. | Always define the mobile-first base, then override upward: `hidden lg:flex`. |
| Transition on `display: none` | `hidden` to `block` can't be transitioned because `display` isn't animatable. | Use `opacity-0`/`opacity-100` with `invisible`/`visible`, or use `@starting-style` (v4). |
| Purge removes dynamic classes | Tailwind purges classes not found as complete strings in scanned files. | Add classes to `safelist` in config, or use a safelist comment in the source file. |

## Reference Files

| File | Content | Lines |
|------|---------|-------|
| `references/component-patterns.md` | Cards, buttons, forms, navigation, modals, tables, alerts, badges, avatars, dropdowns, tooltips, skeleton loaders, accessibility | ~700 |
| `references/v4-migration.md` | CSS-first config, @theme, @plugin, removed utilities, container queries, @starting-style, migration steps, breaking changes | ~500 |
| `references/configuration.md` | Theme config (v3+v4), colors, spacing, typography, plugins, @layer, @apply, custom variants, dark mode, container queries | ~500 |
| `references/animation-patterns.md` | Transition utilities, built-in animations, custom keyframes (v3 config, v4 CSS), `@starting-style` entry animations | ~110 |

## Staleness Verifier

This skill encodes fast-moving facts (the Tailwind v4 CSS-first directives, the
`@tailwindcss/*` package set, the v3→v4 migration). [`scripts/check-tailwind-facts.py`](scripts/check-tailwind-facts.py)
guards them against silent drift — internal consistency in PR CI, live
major-version drift in the scheduled freshness job:

```bash
# Structural (PR CI, no network): every catalogued package + v4 directive gate
# is still named in this skill's prose, and the currency note carries a year.
python3 skills/tailwind-ops/scripts/check-tailwind-facts.py --offline        # exit 0 consistent, 10 drift

# Live (weekly freshness job, never blocks a PR): is any documented major now
# behind npm's latest dist-tag? (e.g. tailwindcss 5 while the prose says v4.)
python3 skills/tailwind-ops/scripts/check-tailwind-facts.py --live           # exit 10 a major moved ahead, 7 npm unreachable
```

The canonical fact list lives in [`assets/tailwind-facts.json`](assets/tailwind-facts.json); when you add or drop a package or the prose stops naming one, update it to match or `--offline` fails CI.

## See Also

- `react-ops` - React component patterns using Tailwind
- `vue-ops` - Vue component patterns using Tailwind
- `astro-ops` - Astro project patterns with Tailwind integration
- `craftcms-ops` - Tailwind in Twig templates; `content` globs must reach `templates/**/*.twig`
- `frontend-upgrade-ops` - Laravel Mix to Vite with Tailwind v3 kept as-is, before any v4 move
- `web-perf-ops` - unused and render-blocking CSS, critical CSS, and their effect on LCP/CLS
- Tailwind docs: https://tailwindcss.com/docs
- Tailwind v4 blog: https://tailwindcss.com/blog/tailwindcss-v4
