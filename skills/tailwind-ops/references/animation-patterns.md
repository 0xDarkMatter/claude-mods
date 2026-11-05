# Tailwind Animation Patterns

Copy-paste animation snippets: transition utilities, the built-in `animate-*` utilities, custom keyframes in a v3 config and in v4 CSS, and `@starting-style` entry animations.

## Contents

- [Animation Patterns](#animation-patterns)
  - [Transition Utilities](#transition-utilities)
  - [Built-in Animations](#built-in-animations)
  - [Custom Keyframes (v3 Config)](#custom-keyframes-v3-config)
  - [Custom Keyframes (v4 CSS)](#custom-keyframes-v4-css)
  - [Entry Animations with @starting-style (v4)](#entry-animations-with-starting-style-v4)

## Animation Patterns

### Transition Utilities

```html
<!-- Color transition (most common) -->
<button class="bg-blue-600 hover:bg-blue-700 transition-colors duration-150">
  Hover me
</button>

<!-- Multiple properties -->
<div class="transform hover:scale-105 hover:shadow-lg transition-all duration-200 ease-in-out">
  Scale and shadow on hover
</div>

<!-- Specific properties -->
<div class="transition-[transform,opacity] duration-300 ease-out">
  Only transform and opacity animate
</div>
```

### Built-in Animations

```html
<!-- Spin (loading spinners) -->
<svg class="animate-spin h-5 w-5 text-blue-600" viewBox="0 0 24 24">
  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"/>
  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
</svg>

<!-- Pulse (skeleton loaders) -->
<div class="animate-pulse bg-gray-200 dark:bg-gray-700 h-4 rounded w-3/4"></div>

<!-- Ping (notification indicator) -->
<span class="relative flex h-3 w-3">
  <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-400 opacity-75"></span>
  <span class="relative inline-flex rounded-full h-3 w-3 bg-red-500"></span>
</span>

<!-- Bounce -->
<div class="animate-bounce">&#8595;</div>
```

### Custom Keyframes (v3 Config)

```js
// tailwind.config.js (v3)
module.exports = {
  theme: {
    extend: {
      keyframes: {
        'fade-in': {
          '0%': { opacity: '0', transform: 'translateY(10px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        'slide-in-right': {
          '0%': { transform: 'translateX(100%)' },
          '100%': { transform: 'translateX(0)' },
        },
      },
      animation: {
        'fade-in': 'fade-in 0.3s ease-out',
        'slide-in-right': 'slide-in-right 0.3s ease-out',
      },
    },
  },
}
```

### Custom Keyframes (v4 CSS)

```css
/* v4: Define in CSS with @theme */
@theme {
  --animate-fade-in: fade-in 0.3s ease-out;
  --animate-slide-in-right: slide-in-right 0.3s ease-out;
}

@keyframes fade-in {
  from { opacity: 0; transform: translateY(10px); }
  to { opacity: 1; transform: translateY(0); }
}

@keyframes slide-in-right {
  from { transform: translateX(100%); }
  to { transform: translateX(0); }
}
```

### Entry Animations with @starting-style (v4)

```css
/* Dialog that animates in from transparent/translated */
dialog[open] {
  opacity: 1;
  transform: translateY(0);
  transition: opacity 0.3s, transform 0.3s;

  @starting-style {
    opacity: 0;
    transform: translateY(10px);
  }
}
```
