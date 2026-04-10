---
name: color-ops
description: "Color for developers - color spaces, accessibility contrast, palette generation, CSS color functions, design tokens, dark mode, and CVD simulation. Use for: color, colour, palette, contrast, accessibility, WCAG, APCA, OKLCH, OKLAB, HSL, color picker, color-mix, dark mode colors, design tokens, color system, color scale, color ramp, gradient, CVD, color blind, gamut, P3, sRGB, color naming, color harmony, color temperature, semantic colors."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: tailwind-ops, react-ops, frontend-design
---

# Color Operations

Practical color knowledge for developers and designers. Covers color spaces, accessibility, palette generation, CSS implementation, and design token architecture.

> Inspired by [meodai/skill.color-expert](https://github.com/meodai/skill.color-expert) - a comprehensive 286K-word color science knowledge base with 113 reference files. This is a lightweight operational skill for everyday frontend and design work. For deep color science (spectral mixing, historical color theory, CAM16, pigment physics), install the full skill.

## Color Space Decision Table

Pick the right space for the task. This is the single most impactful color decision you'll make.

| Task | Use | Why |
|------|-----|-----|
| Perceptual color manipulation | **OKLCH** | Best uniformity for lightness, chroma, hue |
| CSS gradients & palettes | **OKLCH** or `color-mix(in oklab)` | No mid-gradient grey/brown deadzone |
| Gamut-aware color picking | **OKHSL / OKHSV** | Cylindrical like HSL but perceptually grounded |
| Normalized saturation (0-100%) | **HSLuv** | CIELUV chroma normalized per hue/lightness |
| Print workflows | **CIELAB D50** | ICC standard illuminant |
| Screen workflows | **OKLAB** | D65 standard, perceptually uniform |
| Color difference (precision) | **CIEDE2000** | Gold standard perceptual distance metric |
| Color difference (fast) | **Euclidean in OKLAB** | Good enough for most applications |
| Quick prototyping | **HSL** | Simple, fast, every tool supports it |

### Why HSL Falls Short

HSL is fine for quick prototyping. It fails for anything perceptual:

- **Lightness is a lie**: `hsl(60,100%,50%)` (yellow) and `hsl(240,100%,50%)` (blue) have the same L=50% but vastly different perceived brightness
- **Hue is non-uniform**: 20 degrees near red is a dramatic shift; 20 degrees near green is barely visible
- **Saturation doesn't correlate**: S=100% dark blue still looks muted

**Rule of thumb**: Use HSL for throwaway work. Use OKLCH for anything that ships.

### Key Distinctions

- **Chroma** = colorfulness relative to a same-lightness neutral
- **Saturation** = perceived colorfulness relative to the color's own brightness
- **Lightness** = perceived reflectance relative to a similarly lit white
- Same chroma != same saturation. These are different dimensions.

## Accessibility - Contrast Numbers That Matter

### The Odds Are Against You

Of ~281 trillion hex color pairs:

| Threshold | % passing | Odds |
|-----------|-----------|------|
| WCAG 3:1 (large text) | 26.49% | ~1 in 4 |
| WCAG 4.5:1 (AA body) | 11.98% | ~1 in 8 |
| WCAG 7:1 (AAA) | 3.64% | ~1 in 27 |
| APCA 60 | 7.33% | ~1 in 14 |
| APCA 75 (fluent reading) | 1.57% | ~1 in 64 |
| APCA 90 (preferred body) | 0.08% | ~1 in 1,250 |

### WCAG vs APCA

| | WCAG 2.x | APCA (WCAG 3 draft) |
|---|----------|---------------------|
| Model | Simple luminance ratio | Perceptual contrast, polarity-aware |
| Dark-on-light vs light-on-dark | Same ratio | Different - accounts for spatial frequency |
| Text size/weight | Only large vs normal | Continuous scale with font lookup table |
| Accuracy | Known problems with blue, dark mode | Much better perceptual accuracy |
| Status | Current standard, legally referenced | Draft - not yet a requirement |

**Practical guidance**: Test with WCAG 2.x for compliance. Use APCA for better perceptual results. When they disagree, APCA is usually more accurate.

### Quick Contrast Checks

```css
/* Use relative color syntax to auto-generate readable text */
--surface: oklch(0.95 0.02 250);
--on-surface: oklch(from var(--surface) calc(l - 0.6) c h);

/* Or simpler: light surface = dark text, dark surface = light text */
--text: oklch(from var(--surface) calc(1 - l) 0 h);
```

```javascript
// Quick WCAG 2.x relative luminance contrast
function contrastRatio(l1, l2) {
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

function relativeLuminance(r, g, b) {
  const [rs, gs, bs] = [r, g, b].map(c => {
    c /= 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
}
```

### Color Vision Deficiency (CVD)

~8% of men and ~0.5% of women have some form of color vision deficiency. Design accordingly.

| Type | Affects | Prevalence | What breaks |
|------|---------|------------|-------------|
| Protanopia | Red perception | ~1% men | Red/green distinction, red appears dark |
| Deuteranopia | Green perception | ~1% men | Red/green distinction (most common) |
| Tritanopia | Blue perception | ~0.01% | Blue/yellow distinction (rare) |

**Rules**:
- Never use color alone to convey information (add icons, labels, patterns)
- Test with CVD simulation tools (see references)
- Red/green is the most dangerous pair - always add a secondary signal

## CSS Color Functions - Modern Syntax

### Core Functions (Baseline 2024+)

```css
/* OKLCH - the recommended default */
color: oklch(0.7 0.15 150);           /* lightness chroma hue */
color: oklch(0.7 0.15 150 / 0.5);     /* with alpha */

/* OKLAB - for interpolation and mixing */
color: oklab(0.7 -0.1 0.1);           /* lightness a b */

/* color-mix() - blend two colors in any space */
color: color-mix(in oklch, #3b82f6 70%, white);
color: color-mix(in oklab, var(--primary), black 20%);

/* Relative color syntax - transform existing colors */
color: oklch(from var(--brand) calc(l + 0.1) c h);          /* lighten */
color: oklch(from var(--brand) calc(l - 0.1) c h);          /* darken */
color: oklch(from var(--brand) l calc(c * 0.5) h);          /* desaturate */
color: oklch(from var(--brand) l c calc(h + 180));           /* complement */

/* P3 wide gamut */
color: color(display-p3 1 0.5 0);     /* ~25% more colors than sRGB */

/* Fallback pattern for wide gamut */
color: #ff8800;                        /* sRGB fallback */
color: oklch(0.79 0.17 70);           /* oklch version */
color: color(display-p3 1 0.55 0);    /* P3 if supported */
```

### Gradients That Don't Muddy

```css
/* BAD - RGB interpolation goes through grey/brown */
background: linear-gradient(to right, blue, yellow);

/* GOOD - OKLCH interpolation stays vivid */
background: linear-gradient(in oklch, blue, yellow);

/* GOOD - OKLAB also works well */
background: linear-gradient(in oklab, blue, yellow);

/* Longer hue path for rainbow-style gradients */
background: linear-gradient(in oklch longer hue, red, red);
```

## Design Token Architecture

### Three-Layer Pattern

```css
/* Layer 1: Reference tokens (the palette) */
:root {
  --ref-blue-50: oklch(0.97 0.01 250);
  --ref-blue-100: oklch(0.93 0.03 250);
  --ref-blue-500: oklch(0.62 0.18 250);
  --ref-blue-900: oklch(0.25 0.09 250);
  --ref-red-500: oklch(0.63 0.22 25);
  --ref-neutral-50: oklch(0.97 0.005 250);
  --ref-neutral-900: oklch(0.15 0.005 250);
}

/* Layer 2: Semantic tokens (meaning) */
:root {
  --color-surface: var(--ref-neutral-50);
  --color-on-surface: var(--ref-neutral-900);
  --color-primary: var(--ref-blue-500);
  --color-error: var(--ref-red-500);
  --color-border: oklch(from var(--color-surface) calc(l - 0.15) 0.01 h);
}

/* Layer 3: Dark mode swaps semantics, not components */
[data-theme="dark"] {
  --color-surface: var(--ref-neutral-900);
  --color-on-surface: var(--ref-neutral-50);
  --color-primary: var(--ref-blue-100);
  --color-border: oklch(from var(--color-surface) calc(l + 0.15) 0.01 h);
}
```

### Generating Scales in OKLCH

```javascript
// Generate a perceptually uniform color scale
function generateScale(hue, steps = 10) {
  return Array.from({ length: steps }, (_, i) => {
    const t = i / (steps - 1);
    return {
      step: (i + 1) * 100,  // 100..1000
      l: 0.97 - t * 0.82,   // 0.97 (lightest) to 0.15 (darkest)
      c: Math.sin(t * Math.PI) * 0.18,  // peak chroma in midtones
      h: hue,
    };
  });
}

// Usage: generateScale(250) for a blue scale
// Format: oklch(${l} ${c} ${h})
```

## Palette & Harmony

### What Actually Works

Geometric hue harmony (complementary, triadic, etc.) is a weak predictor of good palettes on its own. Better approaches:

- **Character-first**: Organize by mood (pale/muted/deep/vivid/dark). Chroma + lightness drive emotional response more than hue.
- **60-30-10 rule**: 60% dominant, 30% secondary, 10% accent. One color dominates.
- **Lightness variation = legibility**: Same character + varied lightness is readable. Same lightness across hues is illegible.
- **Grayscale sanity check**: If your UI doesn't work in grayscale, the color system has a structural problem.

### Practical Palette Workflow

1. Pick a brand hue in OKLCH
2. Generate a 10-step scale (lightness 0.97 to 0.15, chroma peaks at midtones)
3. Pick a neutral (same hue, near-zero chroma) for another 10-step scale
4. Add 1-2 semantic accent hues (success green, error red, warning amber)
5. Map to semantic tokens: surface, on-surface, primary, secondary, error
6. Test contrast at every text/surface combination (WCAG 4.5:1 minimum)
7. Swap semantic mappings for dark mode (don't just invert)

### Quick Harmony Shortcuts

```css
/* Complementary (opposite hue) */
--complement: oklch(from var(--primary) l c calc(h + 180));

/* Analogous (adjacent hues) */
--analogous-1: oklch(from var(--primary) l c calc(h - 30));
--analogous-2: oklch(from var(--primary) l c calc(h + 30));

/* Triadic */
--triadic-1: oklch(from var(--primary) l c calc(h + 120));
--triadic-2: oklch(from var(--primary) l c calc(h + 240));

/* Tint (lighter, less chroma) */
--tint: oklch(from var(--primary) calc(l + 0.2) calc(c * 0.5) h);

/* Shade (darker, slightly less chroma) */
--shade: oklch(from var(--primary) calc(l - 0.2) calc(c * 0.8) h);
```

## Gamut & Wide Color

### sRGB vs P3 vs Rec2020

| Gamut | Coverage | Support |
|-------|----------|---------|
| sRGB | Baseline | Universal - every screen |
| Display P3 | ~25% more than sRGB | Modern Apple, high-end Android, new monitors |
| Rec2020 | ~37% more than P3 | HDR content, limited device support |

```css
/* Progressive enhancement for wide gamut */
.brand-accent {
  /* sRGB fallback - every browser */
  background: #ff6b00;

  /* P3 if supported - more vivid */
  @supports (color: color(display-p3 1 0 0)) {
    background: color(display-p3 1 0.42 0);
  }
}

/* Or use @media for gamut detection */
@media (color-gamut: p3) {
  :root {
    --accent: oklch(0.75 0.2 50);  /* Can push chroma higher in P3 */
  }
}
```

### Gamut Mapping

When a color is out of gamut (e.g., high-chroma OKLCH on an sRGB screen), browsers clamp it. Control this:

```css
/* Browser auto-maps (default) */
color: oklch(0.7 0.3 150);  /* if out of sRGB, browser reduces chroma */

/* Explicit gamut check in JS */
// CSS.supports('color', 'color(display-p3 1 0 0)')
```

## Scripts

Zero-dependency Node.js tools. Run directly or let Claude invoke them during color tasks.

### Contrast Checker

```bash
node scripts/contrast-check.js <color1> <color2>
node scripts/contrast-check.js "#1a1a2e" "#e0e0e0"
node scripts/contrast-check.js "oklch(0.15 0.02 250)" "oklch(0.9 0.01 250)"
```

Returns WCAG 2.x contrast ratio with AA/AAA pass/fail for normal and large text.

### Palette Generator

```bash
node scripts/palette-gen.js <hue> [name] [--neutral] [--json]
node scripts/palette-gen.js 250 blue              # 10-step blue scale
node scripts/palette-gen.js 250 blue --neutral     # + matching neutral scale
node scripts/palette-gen.js 30 orange --json       # JSON output
```

Generates a perceptually uniform 10-step OKLCH scale (100-1000) as CSS custom properties. Chroma peaks at midtones via sine curve. Flags out-of-gamut sRGB values.

### Color Converter

```bash
node scripts/color-convert.js <color>
node scripts/color-convert.js "#3b82f6"
node scripts/color-convert.js "oklch(0.62 0.18 250)"
node scripts/color-convert.js "hsl(217, 91%, 60%)"
```

Converts any color to all formats: hex, rgb, hsl, oklch, oklab. Shows relative luminance and sRGB gamut status.

### Harmony Generator

```bash
node scripts/harmony-gen.js <color|hue> [scheme] [--css] [--json] [--tokens] [--tints]
node scripts/harmony-gen.js "#3b82f6" triadic      # Triadic palette from hex
node scripts/harmony-gen.js 250 complementary --tokens  # Design tokens
node scripts/harmony-gen.js 30 earth               # Earth tone palette
node scripts/harmony-gen.js random                  # Curated random palette
```

12 harmony schemes: `complementary`, `analogous`, `triadic`, `split`, `tetradic`, `monochromatic`, `warm`, `cool`, `earth`, `pastel`, `vibrant`, `random`. All output gamut-clamped to sRGB. Use `--tokens` for semantic design tokens (primary, secondary, accent, surface), `--tints` for tint/shade/muted variants per color.

## Agent Dispatch

For complex color work beyond this skill's scope, dispatch to specialized agents:

- **Palette generation algorithms** (RampenSau, Poline, IQ cosine): Route to `frontend-design` skill or a dedicated subagent with `references/tools-and-libraries.md` preloaded
- **Accessibility audits** (full APCA + CVD simulation): Route to a subagent that runs contrast checks across all component/token combinations
- **Design system color architecture**: Route to `tailwind-ops` for Tailwind-specific implementation, or handle directly for CSS custom properties

## Reference Files

| File | Content |
|------|---------|
| `references/tools-and-libraries.md` | Palette generators, analysis tools, color libraries, online tools, browser extensions |
| `references/css-color-reference.md` | Complete CSS Color Level 4/5 function reference, browser support, conversion formulas |

## See Also

- `tailwind-ops` - Tailwind color configuration and dark mode patterns
- `react-ops` - Theme context and color mode implementation in React
- [meodai/skill.color-expert](https://github.com/meodai/skill.color-expert) - Full color science skill (113 references, spectral mixing, historical theory)
- [oklch.com](https://oklch.com/) - Interactive OKLCH picker by Evil Martians
- [Huetone](https://huetone.ardov.me/) - Accessible color system builder
