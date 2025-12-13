# Tailwind Patterns Skill

Quick reference for Tailwind CSS utility patterns, responsive design, and configuration.

## Triggers

tailwind, utility classes, responsive design, tailwind config, dark mode css, tw classes

## Responsive Breakpoints

| Prefix | Min Width | CSS |
|--------|-----------|-----|
| `sm:` | 640px | `@media (min-width: 640px)` |
| `md:` | 768px | `@media (min-width: 768px)` |
| `lg:` | 1024px | `@media (min-width: 1024px)` |
| `xl:` | 1280px | `@media (min-width: 1280px)` |
| `2xl:` | 1536px | `@media (min-width: 1536px)` |

**Mobile-first:** No prefix = mobile, add prefix for larger screens.

```html
<div class="w-full md:w-1/2 lg:w-1/3">
  <!-- Full width on mobile, half on tablet, third on desktop -->
</div>
```

## Common Layout Patterns

### Centered Container
```html
<div class="container mx-auto px-4">
  <!-- Centered with padding -->
</div>
```

### Flexbox Row
```html
<div class="flex items-center justify-between gap-4">
  <div>Left</div>
  <div>Right</div>
</div>
```

### Grid Layout
```html
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
  <div>Card 1</div>
  <div>Card 2</div>
  <div>Card 3</div>
</div>
```

### Stack (Vertical)
```html
<div class="flex flex-col gap-4">
  <div>Item 1</div>
  <div>Item 2</div>
</div>
```

## Common Component Patterns

### Card
```html
<div class="bg-white rounded-lg shadow-md p-6">
  <h3 class="text-lg font-semibold mb-2">Title</h3>
  <p class="text-gray-600">Content</p>
</div>
```

### Button Variants
```html
<!-- Primary -->
<button class="bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700 transition-colors">
  Primary
</button>

<!-- Secondary -->
<button class="bg-gray-200 text-gray-800 px-4 py-2 rounded-lg hover:bg-gray-300 transition-colors">
  Secondary
</button>

<!-- Outline -->
<button class="border border-blue-600 text-blue-600 px-4 py-2 rounded-lg hover:bg-blue-50 transition-colors">
  Outline
</button>
```

### Form Input
```html
<input
  type="text"
  class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
  placeholder="Enter text"
/>
```

## Dark Mode

### Class Strategy (Recommended)
```js
// tailwind.config.js
module.exports = {
  darkMode: 'class',
  // ...
}
```

```html
<!-- Add 'dark' class to html or parent -->
<div class="bg-white dark:bg-gray-900 text-gray-900 dark:text-white">
  Content adapts to dark mode
</div>
```

### Media Strategy
```js
// tailwind.config.js
module.exports = {
  darkMode: 'media', // Uses prefers-color-scheme
  // ...
}
```

## Minimal Config Template

```js
// tailwind.config.js
module.exports = {
  content: [
    './src/**/*.{js,ts,jsx,tsx,html}',
  ],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        brand: {
          50: '#f0f9ff',
          500: '#3b82f6',
          900: '#1e3a8a',
        },
      },
      fontFamily: {
        sans: ['Inter', 'sans-serif'],
      },
    },
  },
  plugins: [],
}
```

## Spacing Scale Reference

| Class | Size |
|-------|------|
| `p-0` | 0px |
| `p-1` | 4px (0.25rem) |
| `p-2` | 8px (0.5rem) |
| `p-4` | 16px (1rem) |
| `p-6` | 24px (1.5rem) |
| `p-8` | 32px (2rem) |
| `p-12` | 48px (3rem) |
| `p-16` | 64px (4rem) |

Same scale applies to: `m-`, `gap-`, `w-`, `h-`, `space-x-`, `space-y-`

## Arbitrary Values

When the scale doesn't have what you need:

```html
<div class="w-[137px] h-[calc(100vh-64px)] top-[17px]">
  <!-- Exact values when needed -->
</div>
```

## State Modifiers

| Modifier | Triggers On |
|----------|-------------|
| `hover:` | Mouse hover |
| `focus:` | Element focused |
| `active:` | Being clicked |
| `disabled:` | Disabled state |
| `group-hover:` | Parent hovered |
| `first:` | First child |
| `last:` | Last child |
| `odd:` | Odd children |
| `even:` | Even children |

```html
<button class="bg-blue-500 hover:bg-blue-600 active:bg-blue-700 disabled:opacity-50">
  Button
</button>
```

## Performance Tips

1. **Content configuration** - Ensure all template paths are in `content` array
2. **Avoid @apply overuse** - Prefer utility classes directly
3. **Use CSS variables** for dynamic values that change at runtime
4. **Purge in production** - Tailwind does this automatically via `content`

## Class Organization

Recommended order for readability:
1. Layout (flex, grid, position)
2. Box model (w, h, p, m)
3. Typography (text, font)
4. Visual (bg, border, shadow)
5. Interactive (hover, focus)

```html
<div class="flex items-center | w-full p-4 | text-lg font-medium | bg-white border rounded-lg | hover:shadow-md">
  <!-- Pipes are comments for organization -->
</div>
```
