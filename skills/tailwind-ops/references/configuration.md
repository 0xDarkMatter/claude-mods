# Tailwind CSS Configuration

Complete configuration reference covering both Tailwind v3 (JS config) and v4 (CSS-first config).

## Tailwind v3 Configuration (tailwind.config.js)

### Minimal Config

```js
// tailwind.config.js (v3)
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './src/**/*.{html,js,jsx,ts,tsx,vue,astro}',
    './public/index.html',
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
```

### theme.extend vs theme Override

```js
module.exports = {
  theme: {
    // OVERRIDE: replaces ALL default colors (only these 3 exist)
    colors: {
      primary: '#3b82f6',
      secondary: '#6b7280',
      white: '#ffffff',
    },

    // EXTEND: adds to defaults (all defaults + these custom values)
    extend: {
      colors: {
        brand: '#3b82f6',        // Adds brand color, keeps slate/gray/red/etc.
        primary: {
          50: '#eff6ff',
          100: '#dbeafe',
          500: '#3b82f6',
          600: '#2563eb',
          700: '#1d4ed8',
          900: '#1e3a5f',
        },
      },
      spacing: {
        '18': '4.5rem',
        '88': '22rem',
        '128': '32rem',
      },
      borderRadius: {
        '4xl': '2rem',
      },
    },
  },
}
```

**Rule**: Almost always use `theme.extend`. Only use direct `theme` override when you want to eliminate defaults entirely.

### Screens (Breakpoints)

```js
module.exports = {
  theme: {
    // Override ALL breakpoints
    screens: {
      'sm': '640px',
      'md': '768px',
      'lg': '1024px',
      'xl': '1280px',
      '2xl': '1536px',
    },

    // Or extend with additional breakpoints
    extend: {
      screens: {
        '3xl': '1920px',
        'tall': { 'raw': '(min-height: 800px)' },  // Height-based
      },
    },
  },
}
```

## Tailwind v4 Configuration (@theme in CSS)

### Basic @theme Block

```css
@import "tailwindcss";

@theme {
  /* Colors: generate bg-*, text-*, border-*, ring-*, etc. */
  --color-brand: #3b82f6;
  --color-brand-50: #eff6ff;
  --color-brand-100: #dbeafe;
  --color-brand-500: #3b82f6;
  --color-brand-600: #2563eb;
  --color-brand-700: #1d4ed8;
  --color-brand-900: #1e3a5f;

  /* Semantic colors */
  --color-surface: #ffffff;
  --color-surface-dark: #1f2937;
  --color-on-surface: #111827;
  --color-on-surface-dark: #f9fafb;

  /* Fonts */
  --font-sans: "Inter", system-ui, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, monospace;

  /* Spacing */
  --spacing-18: 4.5rem;
  --spacing-128: 32rem;

  /* Breakpoints */
  --breakpoint-3xl: 1920px;

  /* Border radius */
  --radius-4xl: 2rem;

  /* Animations */
  --animate-fade-in: fade-in 0.3s ease-out forwards;
}
```

### Clearing Default Values

```css
@theme {
  /* Clear all default colors, only keep what you define */
  --color-*: initial;

  --color-white: #ffffff;
  --color-black: #000000;
  --color-gray-50: #f9fafb;
  --color-gray-100: #f3f4f6;
  --color-gray-200: #e5e7eb;
  --color-gray-300: #d1d5db;
  --color-gray-400: #9ca3af;
  --color-gray-500: #6b7280;
  --color-gray-600: #4b5563;
  --color-gray-700: #374151;
  --color-gray-800: #1f2937;
  --color-gray-900: #111827;
  --color-blue-500: #3b82f6;
  --color-blue-600: #2563eb;
  --color-blue-700: #1d4ed8;
}
```

## Custom Colors

### Color Palette Definition (v3)

```js
// tailwind.config.js
const colors = require('tailwindcss/colors')

module.exports = {
  theme: {
    extend: {
      colors: {
        // Reference built-in palette
        gray: colors.slate,
        primary: colors.blue,
        success: colors.green,
        warning: colors.amber,
        danger: colors.red,

        // Custom palette with full scale
        brand: {
          50: '#faf5ff',
          100: '#f3e8ff',
          200: '#e9d5ff',
          300: '#d8b4fe',
          400: '#c084fc',
          500: '#a855f7',
          600: '#9333ea',
          700: '#7e22ce',
          800: '#6b21a8',
          900: '#581c87',
          950: '#3b0764',
        },
      },
    },
  },
}
```

### Color Palette Definition (v4)

```css
@theme {
  --color-brand-50: #faf5ff;
  --color-brand-100: #f3e8ff;
  --color-brand-200: #e9d5ff;
  --color-brand-300: #d8b4fe;
  --color-brand-400: #c084fc;
  --color-brand-500: #a855f7;
  --color-brand-600: #9333ea;
  --color-brand-700: #7e22ce;
  --color-brand-800: #6b21a8;
  --color-brand-900: #581c87;
  --color-brand-950: #3b0764;
}
```

### Opacity Variants

```html
<!-- Opacity modifier works with any color (v3.1+ and v4) -->
<div class="bg-brand-500/75">75% opacity</div>
<div class="bg-brand-500/50">50% opacity</div>
<div class="bg-brand-500/25">25% opacity</div>
<div class="text-brand-700/90">90% text opacity</div>
<div class="border-brand-300/50">50% border opacity</div>
```

### Semantic Colors (Design Tokens)

```css
/* v4: Define semantic tokens that reference palette values */
@theme {
  --color-primary: var(--color-brand-600);
  --color-primary-hover: var(--color-brand-700);
  --color-secondary: var(--color-gray-600);
  --color-secondary-hover: var(--color-gray-700);
  --color-accent: var(--color-amber-500);

  --color-surface: var(--color-white);
  --color-surface-elevated: var(--color-gray-50);
  --color-on-surface: var(--color-gray-900);
  --color-on-surface-muted: var(--color-gray-500);

  --color-destructive: var(--color-red-600);
  --color-destructive-hover: var(--color-red-700);
}
```

```html
<!-- Usage with semantic tokens -->
<button class="bg-primary text-white hover:bg-primary-hover">Primary Action</button>
<button class="bg-destructive text-white hover:bg-destructive-hover">Delete</button>
<div class="bg-surface text-on-surface">Card on surface</div>
```

## Custom Spacing

### Extending the Spacing Scale

```js
// v3: tailwind.config.js
module.exports = {
  theme: {
    extend: {
      spacing: {
        '13': '3.25rem',   // 52px
        '15': '3.75rem',   // 60px
        '18': '4.5rem',    // 72px
        '88': '22rem',     // 352px
        '128': '32rem',    // 512px
        'header': '64px',  // Named spacing
        'sidebar': '280px',
      },
    },
  },
}
```

```css
/* v4: @theme */
@theme {
  --spacing-13: 3.25rem;
  --spacing-15: 3.75rem;
  --spacing-18: 4.5rem;
  --spacing-88: 22rem;
  --spacing-128: 32rem;
  --spacing-header: 64px;
  --spacing-sidebar: 280px;
}
```

### Arbitrary Spacing Values

```html
<!-- One-off values (use sparingly, prefer config for repeated values) -->
<div class="p-[13px]">Arbitrary padding</div>
<div class="mt-[clamp(1rem,3vw,2rem)]">Fluid margin</div>
<div class="w-[calc(100%-250px)]">Calculated width</div>
<div class="h-[calc(100vh-var(--spacing-header))]">Dynamic height</div>
```

## Typography

### Font Families

```js
// v3: tailwind.config.js
module.exports = {
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        display: ['Poppins', 'system-ui', 'sans-serif'],
        body: ['Source Sans Pro', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'Fira Code', 'monospace'],
      },
    },
  },
}
```

```css
/* v4: @theme */
@theme {
  --font-sans: "Inter", system-ui, sans-serif;
  --font-display: "Poppins", system-ui, sans-serif;
  --font-body: "Source Sans Pro", system-ui, sans-serif;
  --font-mono: "JetBrains Mono", "Fira Code", monospace;
}
```

```html
<h1 class="font-display text-4xl font-bold">Display Heading</h1>
<p class="font-body text-base">Body text with Source Sans Pro</p>
<code class="font-mono text-sm">Code block</code>
```

### Font Sizes

```js
// v3: Custom font sizes with line-height
module.exports = {
  theme: {
    extend: {
      fontSize: {
        'xs': ['0.75rem', { lineHeight: '1rem' }],
        'tiny': ['0.625rem', { lineHeight: '0.875rem' }],
        'hero': ['4rem', { lineHeight: '1.1', letterSpacing: '-0.02em', fontWeight: '800' }],
      },
    },
  },
}
```

```css
/* v4: Font size with associated properties */
@theme {
  --text-tiny: 0.625rem;
  --text-tiny--line-height: 0.875rem;

  --text-hero: 4rem;
  --text-hero--line-height: 1.1;
  --text-hero--letter-spacing: -0.02em;
  --text-hero--font-weight: 800;
}
```

```html
<h1 class="text-hero">Hero Heading</h1>
<span class="text-tiny uppercase tracking-wider">Label</span>
```

### Line Heights

```html
<!-- Relative line heights -->
<p class="leading-none">1.0 line-height</p>
<p class="leading-tight">1.25 line-height</p>
<p class="leading-snug">1.375 line-height</p>
<p class="leading-normal">1.5 line-height (default)</p>
<p class="leading-relaxed">1.625 line-height</p>
<p class="leading-loose">2.0 line-height</p>

<!-- Fixed line heights -->
<p class="leading-4">1rem (16px)</p>
<p class="leading-6">1.5rem (24px)</p>
<p class="leading-8">2rem (32px)</p>
```

### @tailwindcss/typography Plugin (Prose Classes)

```bash
npm install @tailwindcss/typography
```

```js
// v3
module.exports = {
  plugins: [require('@tailwindcss/typography')],
}
```

```css
/* v4 */
@plugin "@tailwindcss/typography";
```

```html
<!-- Apply prose to markdown/CMS content wrappers -->
<article class="prose dark:prose-invert lg:prose-lg max-w-none">
  <h1>Article Title</h1>
  <p>Rendered markdown with beautiful typography defaults.</p>
  <blockquote>Styled blockquotes.</blockquote>
  <pre><code>Styled code blocks</code></pre>

  <!-- Exclude sections from prose -->
  <div class="not-prose">
    <button class="bg-blue-600 text-white px-4 py-2 rounded-lg">
      Not affected by prose
    </button>
  </div>
</article>
```

**Prose modifiers**: `prose-sm`, `prose-base`, `prose-lg`, `prose-xl`, `prose-2xl`, `prose-invert` (dark mode), `prose-gray`, `prose-slate`, `prose-zinc`.

## Plugins

### Writing Plugins (v3)

```js
const plugin = require('tailwindcss/plugin')

module.exports = {
  plugins: [
    // addUtilities: generate utility classes
    plugin(function ({ addUtilities }) {
      addUtilities({
        '.text-balance': { 'text-wrap': 'balance' },
        '.text-pretty': { 'text-wrap': 'pretty' },
        '.content-auto': { 'content-visibility': 'auto' },
      })
    }),

    // addComponents: generate component classes
    plugin(function ({ addComponents, theme }) {
      addComponents({
        '.btn': {
          padding: `${theme('spacing.2')} ${theme('spacing.4')}`,
          borderRadius: theme('borderRadius.lg'),
          fontWeight: theme('fontWeight.medium'),
          fontSize: theme('fontSize.sm'),
          lineHeight: theme('lineHeight.5'),
        },
      })
    }),

    // matchUtilities: generate dynamic utilities with values
    plugin(function ({ matchUtilities, theme }) {
      matchUtilities(
        {
          'grid-area': (value) => ({ gridArea: value }),
        },
        { values: { header: 'header', main: 'main', sidebar: 'sidebar', footer: 'footer' } }
      )
    }),
  ],
}
```

### Popular Plugins

| Plugin | Purpose | Install |
|--------|---------|---------|
| `@tailwindcss/typography` | Prose classes for rich content | `npm i @tailwindcss/typography` |
| `@tailwindcss/forms` | Better default form styles | `npm i @tailwindcss/forms` |
| `@tailwindcss/container-queries` | Container queries (v3) | `npm i @tailwindcss/container-queries` |
| `tailwindcss-animate` | Animation utilities (shadcn) | `npm i tailwindcss-animate` |
| `@tailwindcss/aspect-ratio` | Aspect ratio (pre-native) | `npm i @tailwindcss/aspect-ratio` |

```js
// v3: Using plugins
module.exports = {
  plugins: [
    require('@tailwindcss/typography'),
    require('@tailwindcss/forms'),
    require('@tailwindcss/container-queries'),
    require('tailwindcss-animate'),
  ],
}
```

```css
/* v4: Using plugins */
@plugin "@tailwindcss/typography";
@plugin "@tailwindcss/forms";
/* container-queries not needed in v4 (native) */
@plugin "tailwindcss-animate";
```

## Content Configuration

### Template Paths (v3)

```js
// v3: Tell Tailwind where to find class usage
module.exports = {
  content: [
    './src/**/*.{html,js,jsx,ts,tsx,vue,svelte,astro}',
    './public/index.html',
    './content/**/*.md',
    // Include component libraries
    './node_modules/@acme/ui/dist/**/*.js',
  ],
}
```

### Automatic Detection (v4)

v4 automatically scans your project for template files. Override with `@source` if needed:

```css
/* v4: Explicit source paths (usually not needed) */
@source "../content/**/*.md";
@source "../node_modules/@acme/ui/dist/**/*.js";
```

### Safelisting

```js
// v3: Safelist classes that can't be detected
module.exports = {
  safelist: [
    'bg-red-500',
    'bg-green-500',
    'bg-blue-500',
    // Pattern-based
    { pattern: /bg-(red|green|blue)-(100|500|900)/ },
    // With variants
    { pattern: /text-(red|green|blue)-500/, variants: ['hover', 'dark'] },
  ],
}
```

```css
/* v4: Safelist via CSS comment */
@source "safelist:bg-red-500,bg-green-500,bg-blue-500";
```

## @layer Directive

### Layer Hierarchy

```css
@import "tailwindcss";

/* BASE: Reset, HTML element defaults, @font-face */
@layer base {
  html {
    scroll-behavior: smooth;
    -webkit-font-smoothing: antialiased;
  }

  body {
    font-family: var(--font-body);
    color: var(--color-on-surface);
    background-color: var(--color-surface);
  }

  h1, h2, h3, h4, h5, h6 {
    font-family: var(--font-display);
    font-weight: 700;
  }

  a {
    color: var(--color-primary);
    text-decoration-line: underline;
    text-underline-offset: 2px;
  }
}

/* COMPONENTS: Reusable multi-property classes */
@layer components {
  .card {
    @apply rounded-lg bg-white p-6 shadow-md dark:bg-gray-800;
  }

  .btn {
    @apply inline-flex items-center justify-center rounded-lg px-4 py-2
           text-sm font-medium transition-colors
           focus-visible:outline-2 focus-visible:outline-offset-2;
  }

  .btn-primary {
    @apply btn bg-blue-600 text-white hover:bg-blue-700
           focus-visible:outline-blue-600;
  }

  .input {
    @apply w-full rounded-lg border border-gray-300 bg-white px-3 py-2
           text-gray-900 placeholder:text-gray-400
           focus:border-transparent focus:ring-2 focus:ring-blue-500
           dark:border-gray-600 dark:bg-gray-800 dark:text-gray-100;
  }
}

/* UTILITIES: Single-property overrides */
@layer utilities {
  .text-balance {
    text-wrap: balance;
  }

  .content-auto {
    content-visibility: auto;
  }

  .scrollbar-hidden {
    scrollbar-width: none;
    &::-webkit-scrollbar { display: none; }
  }
}
```

### When to Use Each Layer

| Layer | Use For | Example |
|-------|---------|---------|
| `base` | HTML element defaults, resets, `@font-face` | Body font, link colors, heading styles |
| `components` | Multi-property reusable patterns | `.card`, `.btn`, `.input`, `.badge` |
| `utilities` | Single-purpose utility classes | `.text-balance`, `.content-auto` |

## @apply

### When @apply is Appropriate

```css
/* GOOD: Component libraries where utility classes aren't available */
@layer components {
  .prose-custom h2 {
    @apply text-2xl font-bold text-gray-900 dark:text-white mt-8 mb-4;
  }
}

/* GOOD: Markdown content styling */
@layer base {
  .markdown-content h1 { @apply text-3xl font-bold mb-4; }
  .markdown-content p { @apply text-gray-600 dark:text-gray-400 mb-4; }
  .markdown-content a { @apply text-blue-600 hover:underline; }
}

/* GOOD: Repeated pattern across many elements */
@layer components {
  .btn {
    @apply px-4 py-2 rounded-lg font-medium transition-colors
           focus-visible:outline-2 focus-visible:outline-offset-2;
  }
}
```

### When NOT to Use @apply

```html
<!-- BAD: Using @apply when inline utilities work fine -->
<!-- .my-div { @apply flex items-center gap-4 p-6; } -->

<!-- GOOD: Inline utilities - easier to read, change, and delete -->
<div class="flex items-center gap-4 p-6">
```

**Rule of thumb**: Use inline utilities by default. Only reach for `@apply` when:
1. You need to style elements you don't control (CMS content, markdown)
2. You're building a component library with `.btn`, `.card` classes
3. A combination of 5+ utilities is repeated identically in 5+ places

## Custom Variants

### addVariant (v3)

```js
const plugin = require('tailwindcss/plugin')

module.exports = {
  plugins: [
    plugin(function ({ addVariant }) {
      // Simple variant
      addVariant('hocus', ['&:hover', '&:focus'])
      addVariant('supports-grid', '@supports (display: grid)')
      addVariant('optional', '&:optional')

      // Parent state
      addVariant('group-sidebar', ':merge(.group-sidebar):hover &')
    }),
  ],
}
```

### @custom-variant (v4)

```css
/* v4: Define custom variants in CSS */
@custom-variant hocus (&:hover, &:focus);
@custom-variant optional (&:optional);
@custom-variant supports-grid (@supports (display: grid));

/* Dark mode with custom selector */
@custom-variant dark (&:where(.dark, .dark *));

/* Dark mode with data attribute */
@custom-variant dark (&:where([data-theme="dark"], [data-theme="dark"] *));
```

```html
<!-- Usage -->
<button class="bg-blue-600 hocus:bg-blue-700">Hover or focus</button>
<input class="border-gray-300 optional:border-dashed" type="text">
```

### Data Attribute Variants

```html
<!-- Built-in data-* variant -->
<div data-state="open" class="data-[state=open]:bg-blue-50 data-[state=closed]:bg-gray-50">
  Responds to data-state attribute
</div>

<div data-size="lg" class="data-[size=sm]:text-sm data-[size=lg]:text-lg">
  Responds to data-size
</div>

<!-- With boolean data attributes -->
<div data-loading class="data-[loading]:animate-pulse">
  Loading state
</div>
```

## Prefix Configuration

### v3: Avoiding Conflicts

```js
// v3: Add prefix to all Tailwind classes
module.exports = {
  prefix: 'tw-',
}
```

```html
<!-- All classes get tw- prefix -->
<div class="tw-flex tw-items-center tw-gap-4 tw-bg-blue-500">
```

### v4: Prefix

```css
/* v4: Prefix via @import option */
@import "tailwindcss" prefix(tw);
```

## Important Configuration

### v3: Important Selector Strategy

```js
// v3: Make all utilities important
module.exports = {
  // Option 1: All utilities get !important
  important: true,

  // Option 2: Selector strategy (recommended)
  important: '#app',
}
```

### Per-Utility Important

```html
<!-- Add ! prefix for individual important override -->
<div class="!text-red-500">This text is red regardless of other styles</div>
<div class="bg-blue-500 !bg-red-500">Background is red</div>
```

## Dark Mode Configuration

### Class Strategy (v3)

```js
// v3: tailwind.config.js
module.exports = {
  darkMode: 'class',  // Toggle via class="dark" on <html>
}
```

```html
<html class="dark">
  <body class="bg-white dark:bg-gray-900 text-gray-900 dark:text-white">
```

### Media Strategy (v3 and v4 Default)

```js
// v3: Uses system preference (prefers-color-scheme)
module.exports = {
  darkMode: 'media',  // Default in v4
}
```

### Selector Strategy (v4)

```css
/* v4: Class-based dark mode */
@custom-variant dark (&:where(.dark, .dark *));

/* v4: Data attribute dark mode */
@custom-variant dark (&:where([data-mode="dark"], [data-mode="dark"] *));
```

### Dark Mode Toggle Script

```html
<!-- Prevent flash of wrong theme: add to <head> before CSS -->
<script>
  const theme = localStorage.getItem('theme');
  if (theme === 'dark' || (!theme && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.classList.add('dark');
  }
</script>
```

## Container Queries

### Setup (v3)

```bash
npm install @tailwindcss/container-queries
```

```js
// v3: tailwind.config.js
module.exports = {
  plugins: [require('@tailwindcss/container-queries')],
}
```

### Setup (v4)

Container queries are native in v4. No plugin needed.

### Usage

```html
<!-- Unnamed container -->
<div class="@container">
  <div class="flex flex-col @sm:flex-row @md:grid @md:grid-cols-2 gap-4">
    <div class="p-4">Responds to parent width</div>
    <div class="p-4">Not viewport width</div>
  </div>
</div>

<!-- Named container -->
<div class="@container/sidebar">
  <nav class="flex flex-col @md/sidebar:flex-row gap-2">
    <a href="#">Link 1</a>
    <a href="#">Link 2</a>
  </nav>
</div>
```

### Container Query Breakpoints

| Variant | Min Width |
|---------|-----------|
| `@xs:` | 320px (20rem) |
| `@sm:` | 384px (24rem) |
| `@md:` | 448px (28rem) |
| `@lg:` | 512px (32rem) |
| `@xl:` | 576px (36rem) |
| `@2xl:` | 672px (42rem) |
| `@3xl:` | 768px (48rem) |
| `@4xl:` | 896px (56rem) |
| `@5xl:` | 1024px (64rem) |

### Container Query Units

```html
<!-- Container query units: relative to container size -->
<div class="@container">
  <div class="w-[50cqw] h-[30cqh]">
    50% of container width, 30% of container height
  </div>
</div>
```

| Unit | Description |
|------|-------------|
| `cqw` | 1% of container width |
| `cqh` | 1% of container height |
| `cqi` | 1% of container inline size |
| `cqb` | 1% of container block size |
| `cqmin` | Smaller of `cqi` / `cqb` |
| `cqmax` | Larger of `cqi` / `cqb` |

### Nested Containers

```html
<div class="@container/page">
  <div class="grid @lg/page:grid-cols-[250px_1fr]">
    <aside class="@container/sidebar">
      <nav class="flex flex-col @md/sidebar:flex-row">Sidebar nav</nav>
    </aside>
    <main class="@container/content">
      <div class="grid @md/content:grid-cols-2 @xl/content:grid-cols-3 gap-6">
        <div>Card</div>
      </div>
    </main>
  </div>
</div>
```
