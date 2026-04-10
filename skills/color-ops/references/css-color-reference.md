# CSS Color Reference

Complete reference for CSS Color Level 4 and Level 5 functions. Baseline 2024+ unless noted.

## Color Functions

### oklch()

The recommended default for CSS color work. Perceptually uniform, intuitive cylindrical coordinates.

```css
oklch(L C H)
oklch(L C H / alpha)

/* L: lightness 0-1 (0 = black, 1 = white) */
/* C: chroma 0-0.4 (0 = grey, higher = more vivid) */
/* H: hue 0-360 (degrees on color wheel) */

color: oklch(0.7 0.15 250);           /* medium blue */
color: oklch(0.7 0.15 250 / 0.5);     /* 50% transparent */
color: oklch(0.9 0.04 90);            /* pale yellow */
color: oklch(0.3 0.2 30);             /* deep red */
```

**Practical chroma ranges by context:**

| Context | Chroma Range | Notes |
|---------|-------------|-------|
| Neutral/grey | 0 - 0.02 | Near-zero, slight warmth/coolness via hue |
| Muted/pastel | 0.02 - 0.08 | Backgrounds, large surfaces |
| Medium | 0.08 - 0.15 | Body text links, secondary UI |
| Vivid | 0.15 - 0.25 | Primary actions, brand colors |
| Maximum | 0.25 - 0.37 | Saturated accents (gamut-dependent) |

**OKLCH hue map (approximate):**

| Hue | Color |
|-----|-------|
| 0-30 | Pink / Red |
| 30-70 | Orange / Amber |
| 70-110 | Yellow / Lime |
| 110-160 | Green |
| 160-200 | Teal / Cyan |
| 200-260 | Blue |
| 260-310 | Indigo / Violet |
| 310-360 | Magenta / Pink |

### oklab()

Cartesian version of OKLCH. Better for interpolation and mixing.

```css
oklab(L a b)
oklab(L a b / alpha)

/* L: lightness 0-1 */
/* a: green(-) to red(+), roughly -0.4 to 0.4 */
/* b: blue(-) to yellow(+), roughly -0.4 to 0.4 */

color: oklab(0.7 -0.1 0.1);           /* greenish */
color: oklab(0.5 0.15 -0.1);          /* purplish */
```

### color-mix()

Blend two colors in any color space.

```css
color-mix(in <colorspace>, <color1> <percentage>?, <color2> <percentage>?)

/* Default: 50/50 mix */
color: color-mix(in oklch, blue, white);

/* Weighted mix */
color: color-mix(in oklch, #3b82f6 70%, white);        /* 70% blue, 30% white */
color: color-mix(in oklab, var(--primary), black 20%);  /* 80% primary, 20% black */

/* Hue interpolation control */
color: color-mix(in oklch shorter hue, red, blue);      /* shorter arc */
color: color-mix(in oklch longer hue, red, blue);       /* longer arc (rainbow) */
```

**Supported color spaces for interpolation:**
`srgb`, `srgb-linear`, `display-p3`, `a98-rgb`, `prophoto-rgb`, `rec2020`, `lab`, `oklab`, `xyz`, `xyz-d50`, `xyz-d65`, `hsl`, `hwb`, `lch`, `oklch`

**Best spaces for mixing:**

| Space | Result |
|-------|--------|
| `oklch` | Vivid, predictable hue path |
| `oklab` | Smooth, no hue shift surprises |
| `srgb` | Legacy default, can muddy |
| `hsl` | Unpredictable brightness |

### Relative Color Syntax

Transform an existing color by modifying its components. Game-changer for design systems.

```css
/* Syntax: <colorspace>(from <origin> <component-expressions>) */

/* Lighten */
color: oklch(from var(--brand) calc(l + 0.1) c h);

/* Darken */
color: oklch(from var(--brand) calc(l - 0.1) c h);

/* Desaturate */
color: oklch(from var(--brand) l calc(c * 0.5) h);

/* Saturate */
color: oklch(from var(--brand) l calc(c * 1.5) h);

/* Shift hue (complement) */
color: oklch(from var(--brand) l c calc(h + 180));

/* Auto readable text (invert lightness) */
color: oklch(from var(--surface) calc(1 - l) 0 h);

/* Extract and modify alpha */
color: oklch(from var(--brand) l c h / 0.5);

/* Works with any origin format */
color: oklch(from #3b82f6 calc(l + 0.2) c h);
color: oklch(from rgb(59 130 246) l calc(c * 0.5) h);
```

**Available channel keywords by space:**

| Space | Keywords |
|-------|----------|
| oklch | `l` `c` `h` |
| oklab | `l` `a` `b` |
| hsl | `h` `s` `l` |
| srgb | `r` `g` `b` |

### color()

Access predefined color spaces directly. Primary use: Display P3 wide gamut.

```css
color(<colorspace> <values>)
color(<colorspace> <values> / alpha)

/* Display P3 (wider gamut than sRGB) */
color: color(display-p3 1 0.5 0);
color: color(display-p3 0.3 0.8 0.2 / 0.9);

/* sRGB (explicit) */
color: color(srgb 0.5 0.5 0.5);

/* Other spaces */
color: color(a98-rgb 0.44 0.5 0.37);
color: color(prophoto-rgb 0.36 0.48 0.14);
color: color(rec2020 0.42 0.47 0.13);
```

### light-dark()

Return different values based on computed color-scheme.

```css
/* Requires color-scheme to be set */
:root { color-scheme: light dark; }

color: light-dark(#333, #eee);
background: light-dark(white, oklch(0.2 0.01 250));
border-color: light-dark(
  oklch(0.8 0.02 250),
  oklch(0.3 0.02 250)
);
```

**Browser support:** Baseline 2024

## Gradients

### Interpolation Space

```css
/* Default (sRGB) - often muddy */
background: linear-gradient(blue, yellow);

/* OKLCH - vivid, predictable */
background: linear-gradient(in oklch, blue, yellow);

/* OKLAB - smooth, no hue surprises */
background: linear-gradient(in oklab, blue, yellow);

/* Hue interpolation for oklch/hsl/lch */
background: linear-gradient(in oklch shorter hue, red, blue);
background: linear-gradient(in oklch longer hue, red, red);  /* rainbow */
background: linear-gradient(in oklch increasing hue, red, blue);
background: linear-gradient(in oklch decreasing hue, red, blue);
```

### Common Gradient Patterns

```css
/* Smooth multi-stop */
background: linear-gradient(in oklch,
  oklch(0.6 0.2 30),   /* warm red */
  oklch(0.7 0.18 60),  /* orange */
  oklch(0.8 0.15 90)   /* gold */
);

/* Eased gradient (manual) - smoother than default linear */
background: linear-gradient(in oklch,
  oklch(0.3 0.15 250) 0%,
  oklch(0.35 0.14 250) 10%,
  oklch(0.45 0.12 250) 30%,
  oklch(0.6 0.08 250) 60%,
  oklch(0.8 0.04 250) 85%,
  oklch(0.95 0.01 250) 100%
);

/* Radial in oklch */
background: radial-gradient(in oklch, oklch(0.8 0.2 60), oklch(0.3 0.1 30));

/* Conic in oklch (color wheel) */
background: conic-gradient(in oklch longer hue, red, red);
```

## Conversion Formulas

### Hex to sRGB

```javascript
function hexToRgb(hex) {
  const n = parseInt(hex.replace('#', ''), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
```

### sRGB to Linear RGB

```javascript
function srgbToLinear(c) {
  c /= 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}
```

### Linear RGB to OKLAB

```javascript
function linearRgbToOklab(r, g, b) {
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}
```

### OKLAB to OKLCH

```javascript
function oklabToOklch(L, a, b) {
  const C = Math.sqrt(a * a + b * b);
  const H = (Math.atan2(b, a) * 180 / Math.PI + 360) % 360;
  return [L, C, H];
}
```

### Relative Luminance (WCAG 2.x)

```javascript
function relativeLuminance(r, g, b) {
  const [rs, gs, bs] = [r, g, b].map(srgbToLinear);
  return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
}

function contrastRatio(l1, l2) {
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}
```

## @media and @supports Queries

```css
/* Detect wide gamut display */
@media (color-gamut: p3) {
  :root { --can-p3: true; }
}
@media (color-gamut: rec2020) {
  :root { --can-rec2020: true; }
}

/* Detect color scheme preference */
@media (prefers-color-scheme: dark) { /* dark mode */ }
@media (prefers-color-scheme: light) { /* light mode */ }

/* Detect reduced motion (relevant for animated gradients) */
@media (prefers-reduced-motion: reduce) { /* tone it down */ }

/* Detect contrast preference */
@media (prefers-contrast: more) { /* increase contrast */ }
@media (prefers-contrast: less) { /* decrease contrast */ }

/* Feature detection */
@supports (color: oklch(0 0 0)) { /* oklch supported */ }
@supports (color: color(display-p3 1 0 0)) { /* P3 supported */ }
@supports (color: color-mix(in oklch, red, blue)) { /* color-mix supported */ }
```

## Browser Support Summary

| Feature | Chrome | Firefox | Safari | Baseline |
|---------|--------|---------|--------|----------|
| oklch() / oklab() | 111+ | 113+ | 15.4+ | 2023 |
| color-mix() | 111+ | 113+ | 16.2+ | 2023 |
| Relative color syntax | 119+ | 128+ | 16.4+ | 2024 |
| color() (P3, etc.) | 111+ | 113+ | 15+ | 2023 |
| light-dark() | 123+ | 120+ | 17.5+ | 2024 |
| Gradient interpolation | 111+ | 127+ | 16.2+ | 2024 |

All features listed here are Baseline 2023-2024 - safe for production with a simple sRGB fallback for older browsers.
