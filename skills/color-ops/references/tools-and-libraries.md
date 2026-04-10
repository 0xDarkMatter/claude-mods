# Color Tools & Libraries

Curated toolkit for practical color work. Organized by task.

## JavaScript Libraries

### Manipulation & Conversion

| Library | Size | Strengths | Install |
|---------|------|-----------|---------|
| [Culori](https://culorijs.org/) | ~15KB | 50+ color spaces, tree-shakeable, OKLCH native | `npm i culori` |
| [Color.js](https://colorjs.io/) | ~40KB | CSS Color Level 4/5 reference impl, by Lea Verou & Chris Lilley | `npm i colorjs.io` |
| [chroma.js](https://gka.github.io/chroma.js/) | ~14KB | Great API, bezier interpolation, battle-tested | `npm i chroma-js` |
| [tinycolor2](https://github.com/bgrins/TinyColor) | ~10KB | Lightweight, good enough for simple tasks | `npm i tinycolor2` |

### Palette Generation

| Library | Approach | Best For |
|---------|----------|----------|
| [RampenSau](https://github.com/meodai/rampensau) | Hue cycling with easing | Generative palettes, art-directed ramps |
| [Poline](https://meodai.github.io/poline/) | Positionable anchor points in OKLCH | Perceptually smooth multi-stop gradients |
| [IQ Cosine Palettes](https://iquilezles.org/articles/palettes/) | 4-coefficient cosine function | Procedural palettes, shader-friendly |
| [Leonardo](https://leonardocolor.io/) | Contrast-ratio targeting | Accessible design systems (by Adobe) |

### Accessibility

| Library | Purpose | Install |
|---------|---------|---------|
| [apca-w3](https://github.com/nickmarcucci/apca-w3) | APCA contrast calculation | `npm i apca-w3` |
| [colorParsley](https://github.com/nickmarcucci/colorparsley) | Parse any CSS color string | `npm i colorparsley` |

### Spectral & Physical Mixing

| Library | What It Does |
|---------|-------------|
| [Spectral.js](https://github.com/rvanwijnen/spectral.js) | Kubelka-Munk spectral mixing - colors mix like paint, not light |
| [mixbox](https://github.com/scrtwpns/mixbox) | Pigment-based mixing by Scratchapixel |

## Online Tools

### Color Pickers & Explorers

| Tool | URL | Best For |
|------|-----|----------|
| OKLCH Picker | oklch.com | Interactive OKLCH exploration (Evil Martians) |
| Huetone | huetone.ardov.me | Building accessible color systems with contrast checks |
| Color Buddy | colorbuddy.app | Quick palette exploration |
| Coolors | coolors.co | Fast palette generation with locking |
| Realtime Colors | realtimecolors.com | See palette applied to a real page layout |

### Contrast Checkers

| Tool | URL | Algorithm |
|------|-----|-----------|
| WebAIM Contrast Checker | webaim.org/resources/contrastchecker | WCAG 2.x |
| APCA Contrast Calculator | apcacontrast.com | APCA (WCAG 3 draft) |
| Polypane Contrast | polypane.app/color-contrast | Both WCAG + APCA |
| Colour Contrast Analyzer | colourcontrast.cc | WCAG 2.x with visual preview |

### CVD Simulation

| Tool | URL | Notes |
|------|-----|-------|
| Sim Daltonism | michelf.ca/projects/sim-daltonism | macOS app, real-time screen filter |
| Chrome DevTools | Built-in (Rendering > Emulate vision deficiencies) | No install needed |
| Stark (Figma plugin) | getstark.co | WCAG + CVD inside Figma |

### Design System Tools

| Tool | URL | Best For |
|------|-----|----------|
| Leonardo | leonardocolor.io | Contrast-ratio-based scale generation (Adobe) |
| Radix Colors | radix-ui.com/colors | Pre-built accessible scales for UI |
| Open Props Colors | open-props.style | CSS custom property color system |
| Tailwind Color Generator | uicolors.app/create | Generate Tailwind-compatible scales |

## CSS-Native Features

No library needed - these ship in browsers (Baseline 2024+):

```css
/* oklch() */
color: oklch(0.7 0.15 250);

/* color-mix() */
color: color-mix(in oklch, #3b82f6 70%, white);

/* Relative color syntax */
color: oklch(from var(--brand) calc(l + 0.1) c h);

/* color() for P3 */
color: color(display-p3 1 0.5 0);
```

## Color Naming

| Resource | URL | Notes |
|----------|-----|-------|
| meodai/color-names | github.com/meodai/color-names | 30K+ crowd-sourced color names with hex values |
| Name That Color | chir.ag/projects/name-that-color | Quick hex-to-name lookup |

## Figma Plugins

| Plugin | Purpose |
|--------|---------|
| Stark | Accessibility contrast + CVD simulation |
| Realtime Colors | Apply palette to realistic layouts |
| Color Blind | Simulate all CVD types on selected frames |
| P3 Color Picker | Pick Display P3 colors natively |
