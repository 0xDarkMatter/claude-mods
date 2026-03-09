# Tailwind CSS v4 Migration Guide

Comprehensive guide for migrating from Tailwind CSS v3 to v4. Tailwind v4 is a ground-up rewrite with CSS-first configuration, new engine, and native support for modern CSS features.

## What Changed: Overview

### Architecture Shift

Tailwind v4 replaces JavaScript-based configuration with CSS-first configuration. The `tailwind.config.js` file is no longer required (but supported via compatibility layer).

| Concept | v3 | v4 |
|---------|----|----|
| Config | `tailwind.config.js` (JS) | `@theme {}` block in CSS |
| Entry point | `@tailwind base/components/utilities` | `@import "tailwindcss"` |
| Plugins | JS `plugin()` API | `@plugin "package"` in CSS |
| PostCSS | `tailwindcss` package | `@tailwindcss/postcss` |
| Vite | PostCSS plugin | `@tailwindcss/vite` (faster) |
| Content detection | `content: [...]` in config | Automatic (scans project) |
| Theme values | JS objects | CSS custom properties |
| Directives | `@tailwind`, `@screen`, `@variants` | `@import`, `@theme`, `@variant` |

## @theme Directive

The `@theme` directive replaces `theme.extend` in `tailwind.config.js`. Values defined here become both CSS custom properties and Tailwind utilities.

### Basic Usage

```css
/* v4: CSS-first configuration */
@import "tailwindcss";

@theme {
  /* Colors: creates bg-brand, text-brand, border-brand, etc. */
  --color-brand: #3b82f6;
  --color-brand-light: #60a5fa;
  --color-brand-dark: #1d4ed8;

  /* Semantic colors */
  --color-success: #22c55e;
  --color-warning: #f59e0b;
  --color-danger: #ef4444;

  /* Typography */
  --font-display: "Inter", "system-ui", sans-serif;
  --font-body: "Source Sans Pro", "system-ui", sans-serif;
  --font-mono: "JetBrains Mono", "Fira Code", monospace;

  /* Custom spacing */
  --spacing-18: 4.5rem;
  --spacing-88: 22rem;
  --spacing-128: 32rem;

  /* Custom breakpoints */
  --breakpoint-3xl: 1920px;

  /* Animations */
  --animate-fade-in: fade-in 0.3s ease-out;
  --animate-slide-up: slide-up 0.4s ease-out;
}

@keyframes fade-in {
  from { opacity: 0; transform: translateY(8px); }
  to { opacity: 1; transform: translateY(0); }
}

@keyframes slide-up {
  from { opacity: 0; transform: translateY(100%); }
  to { opacity: 1; transform: translateY(0); }
}
```

### Overriding vs Extending

```css
/* EXTENDING: add to existing scale (use --color-* namespace) */
@theme {
  --color-brand: #3b82f6;
  /* All default colors (slate, gray, red, etc.) still available */
}

/* OVERRIDING: replace entire namespace */
@theme {
  --color-*: initial;  /* Clear all default colors */
  --color-primary: #3b82f6;
  --color-secondary: #6b7280;
  --color-accent: #f59e0b;
  /* Only these 3 colors available now */
}
```

### Accessing Theme Values in CSS

```css
/* Theme values are CSS custom properties, usable anywhere */
.custom-element {
  color: var(--color-brand);
  font-family: var(--font-display);
  padding: var(--spacing-18);
}
```

## @config: Compatibility Layer

For projects with existing `tailwind.config.js` files, v4 provides a compatibility layer.

```css
@import "tailwindcss";

/* Load existing JS config */
@config "./tailwind.config.js";

/* Can combine with @theme (theme overrides config) */
@theme {
  --color-brand: #3b82f6;
}
```

**Migration path**: Start with `@config`, then gradually move values into `@theme`, then remove the JS config.

## @plugin Directive

Plugins are now imported directly in CSS.

```css
@import "tailwindcss";

/* v4: Import plugins in CSS */
@plugin "@tailwindcss/typography";
@plugin "@tailwindcss/forms";
@plugin "@tailwindcss/container-queries";

/* Local plugin */
@plugin "./plugins/my-custom-plugin.js";
```

### Plugin API Changes

```js
// v4 plugin API (similar to v3 but with changes)
export default function ({ addUtilities, addComponents, matchUtilities, theme }) {
  addUtilities({
    '.content-auto': { 'content-visibility': 'auto' },
    '.content-hidden': { 'content-visibility': 'hidden' },
  })
}
```

## New Default Scales

### Spacing

v4 uses a simplified spacing scale based on multiples of `0.25rem` (4px). The existing numeric scale (0-96) remains, but new scales are rationalized.

### Colors

v4 retains the same color palette names but adds:
- OKLCH color support for more perceptually uniform colors
- Automatic color opacity via `bg-blue-500/75` (unchanged syntax, improved output)

### Typography

```css
@theme {
  /* v4 uses --text-* for font-size + line-height combos */
  --text-base: 1rem;           /* 16px */
  --text-base--line-height: 1.5rem;  /* 24px */

  /* Custom text scale */
  --text-hero: 4rem;
  --text-hero--line-height: 1.1;
  --text-hero--letter-spacing: -0.02em;
  --text-hero--font-weight: 800;
}
```

## Removed Utilities and Replacements

| v3 Utility | Status in v4 | Replacement |
|------------|-------------|-------------|
| `bg-opacity-*` | Removed | `bg-blue-500/75` (opacity modifier) |
| `text-opacity-*` | Removed | `text-blue-500/75` |
| `border-opacity-*` | Removed | `border-blue-500/75` |
| `divide-opacity-*` | Removed | `divide-blue-500/75` |
| `ring-opacity-*` | Removed | `ring-blue-500/75` |
| `placeholder-opacity-*` | Removed | `placeholder:text-gray-400/75` |
| `flex-shrink` | Renamed | `shrink` (already available in v3) |
| `flex-grow` | Renamed | `grow` (already available in v3) |
| `overflow-ellipsis` | Renamed | `text-ellipsis` |
| `decoration-slice` | Renamed | `box-decoration-slice` |
| `decoration-clone` | Renamed | `box-decoration-clone` |

### Opacity Modifier Migration

```html
<!-- v3: Separate opacity utilities -->
<div class="bg-blue-500 bg-opacity-75">

<!-- v4: Opacity modifier on the color -->
<div class="bg-blue-500/75">

<!-- Both opacity and color in one -->
<div class="bg-blue-500/50 text-white/90 border-gray-300/30">
```

## Variant Changes

### New Variants

| Variant | Usage | Description |
|---------|-------|-------------|
| `@sm:` / `@md:` / `@lg:` | `@md:flex` | Container query breakpoints |
| `@min-*:` / `@max-*:` | `@min-[400px]:flex` | Arbitrary container queries |
| `starting:` | `starting:opacity-0` | `@starting-style` for entry animations |
| `not-*:` | `not-last:mb-4` | Negation pseudo-class |
| `in-*:` | `in-[.dark]:text-white` | Match within ancestor |
| `has-*:` | `has-[input:focus]:ring-2` | `:has()` pseudo-class |
| `nth-*:` | `nth-3:bg-gray-100` | `:nth-child()` |
| `nth-last-*:` | `nth-last-2:mb-0` | `:nth-last-child()` |

### Removed / Changed Variants

| v3 | v4 | Notes |
|----|----| ------|
| `@screen sm` | `@sm` or `@media (width >= 640px)` | `@screen` directive removed |
| `@variants hover, focus` | Removed | Not needed, variants auto-generated |

### Container Query Variants

```html
<!-- v4: Native container queries -->
<div class="@container">
  <div class="flex flex-col @sm:flex-row @md:grid @md:grid-cols-2 @lg:grid-cols-3 gap-4">
    <div>Card</div>
  </div>
</div>

<!-- Named containers -->
<div class="@container/main">
  <div class="@sm/main:flex">Responds to main container</div>
</div>

<!-- Arbitrary container query values -->
<div class="@container">
  <div class="@min-[400px]:flex @max-[800px]:flex-col">
    Custom breakpoints
  </div>
</div>
```

## @starting-style: Entry Animations

v4 supports `@starting-style` for CSS-native entry animations, eliminating the need for JavaScript animation libraries in many cases.

```css
/* Dialog with entry animation */
dialog[open] {
  opacity: 1;
  transform: scale(1);
  transition: opacity 0.3s ease, transform 0.3s ease,
              display 0.3s ease allow-discrete,
              overlay 0.3s ease allow-discrete;

  @starting-style {
    opacity: 0;
    transform: scale(0.95);
  }
}

/* Popover entry */
[popover]:popover-open {
  opacity: 1;
  transform: translateY(0);
  transition: opacity 0.2s, transform 0.2s,
              display 0.2s allow-discrete,
              overlay 0.2s allow-discrete;

  @starting-style {
    opacity: 0;
    transform: translateY(-8px);
  }
}
```

### Using with Tailwind v4 Classes

```html
<!-- The starting: variant maps to @starting-style -->
<dialog class="opacity-100 scale-100 transition-all duration-300
               starting:opacity-0 starting:scale-95
               backdrop:bg-black/50">
  <div class="p-6">Dialog content</div>
</dialog>
```

## Anchor Positioning

v4 supports CSS Anchor Positioning for tooltips, popovers, and dropdowns without JavaScript positioning libraries.

```css
/* Anchor a tooltip to a button */
.trigger {
  anchor-name: --my-trigger;
}

.tooltip {
  position: absolute;
  position-anchor: --my-trigger;
  top: anchor(bottom);
  left: anchor(center);
  transform: translateX(-50%);
}
```

## PostCSS Changes

### v3 PostCSS Setup

```js
// postcss.config.js (v3)
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
```

### v4 PostCSS Setup

```js
// postcss.config.js (v4)
module.exports = {
  plugins: {
    '@tailwindcss/postcss': {},
    // autoprefixer no longer needed - handled by Tailwind v4
  },
}
```

### Package Changes

```bash
# Remove v3 packages
npm uninstall tailwindcss postcss autoprefixer

# Install v4 packages
npm install @tailwindcss/postcss
```

## Vite Plugin

v4 provides a dedicated Vite plugin that is significantly faster than the PostCSS plugin.

```bash
npm install @tailwindcss/vite
```

```js
// vite.config.js
import tailwindcss from '@tailwindcss/vite'

export default {
  plugins: [
    tailwindcss(),
  ],
}
```

```css
/* app.css - no postcss config needed */
@import "tailwindcss";

@theme {
  --color-brand: #3b82f6;
}
```

## CSS Entry Point Changes

### v3 Entry Point

```css
/* v3 */
@tailwind base;
@tailwind components;
@tailwind utilities;

/* Custom styles */
@layer base { ... }
@layer components { ... }
@layer utilities { ... }
```

### v4 Entry Point

```css
/* v4 */
@import "tailwindcss";

/* Layers still work the same way */
@layer base {
  body {
    font-family: var(--font-body);
  }
}

@layer components {
  .card {
    @apply rounded-lg bg-white p-6 shadow-md dark:bg-gray-800;
  }
}

@layer utilities {
  .content-auto {
    content-visibility: auto;
  }
}
```

## Migration Steps

### 1. Automated Migration Tool

```bash
# Run the official migration tool
npx @tailwindcss/upgrade
```

This tool will:
- Update `package.json` dependencies
- Convert `tailwind.config.js` to `@theme` block (where possible)
- Update CSS entry points (`@tailwind` to `@import`)
- Replace removed utilities with modern equivalents
- Update PostCSS config

### 2. Manual Migration Checklist

```
[ ] Update packages: tailwindcss -> @tailwindcss/postcss (or @tailwindcss/vite)
[ ] Remove autoprefixer (built into v4)
[ ] Replace @tailwind directives with @import "tailwindcss"
[ ] Move tailwind.config.js theme values to @theme block
    OR use @config "./tailwind.config.js" as compatibility layer
[ ] Update opacity utilities: bg-opacity-50 -> bg-blue-500/50
[ ] Update deprecated utility names (flex-shrink -> shrink, etc.)
[ ] Replace @screen with @media or container queries
[ ] Update plugins: require() -> @plugin directive
[ ] Test dark mode (default is now media-based)
[ ] Verify content detection (automatic in v4, no content config needed)
[ ] Remove postcss.config.js if using @tailwindcss/vite
```

### 3. Testing Checklist

```
[ ] All pages render correctly
[ ] Dark mode toggle works
[ ] Responsive breakpoints behave correctly
[ ] Custom colors / spacing / typography render
[ ] Animations and transitions work
[ ] Form styles render (if using @tailwindcss/forms)
[ ] Prose/typography content renders (if using @tailwindcss/typography)
[ ] No missing classes in production build
[ ] No console errors related to CSS
[ ] Accessibility: focus rings, sr-only text still work
```

## Breaking Changes by Category

### Configuration

| Change | Impact | Migration |
|--------|--------|-----------|
| `tailwind.config.js` no longer auto-detected | Config not loaded | Add `@config "./tailwind.config.js"` or migrate to `@theme` |
| `content` paths removed | Not needed | v4 automatically detects template files |
| `safelist` moved | Classes not preserved | Use `@source` directive or CSS comments |
| `prefix` option | Not directly supported | Use CSS layers or namespacing |
| `important` option | Changed behavior | Use `@layer` strategy instead |

### Utilities

| Change | Impact | Migration |
|--------|--------|-----------|
| `bg-opacity-*` removed | Transparent backgrounds break | Use `/` opacity modifier: `bg-blue-500/75` |
| `flex-shrink-*` renamed | Warning/removal | Use `shrink-*` |
| `flex-grow-*` renamed | Warning/removal | Use `grow-*` |
| Default border color | Was `gray-200`, now `currentColor` | Explicitly set `border-gray-200` |
| Default ring width | Was `3px`, now `1px` | Explicitly set `ring-3` |
| Shadow color handling | Different cascade behavior | Test shadow utilities |

### Variants

| Change | Impact | Migration |
|--------|--------|-----------|
| `@screen` removed | Compilation error | Use `@media (width >= Xpx)` |
| `@variants` removed | Compilation error | Remove directive (auto-generated) |
| `@responsive` removed | Compilation error | Remove directive (auto-generated) |
| Dark mode default | Was opt-in, now `media` by default | Set `@custom-variant dark` if using class strategy |

### Plugins

| Change | Impact | Migration |
|--------|--------|-----------|
| `require()` not supported in CSS | Plugin not loaded | Use `@plugin "package"` |
| Some plugin APIs changed | Plugin errors | Check plugin compatibility with v4 |
| `addBase()` behavior | Different layer ordering | Test base styles |
| `theme()` function | Returns CSS custom properties | Update if doing string comparison |
