#!/usr/bin/env node
// Harmony generator - build harmonious palettes from a base color or from scratch
// Usage: node harmony-gen.js <color|hue> [scheme] [--css] [--json] [--tokens]
//
// Inspired by Coolors, Color Hunt, and Colour Lovers palette approaches.
// Generates palettes that work in practice - not just geometric hue math,
// but varied lightness and chroma for actual UI use.

const args = process.argv.slice(2);
if (args.length < 1 || args.includes('--help') || args.includes('-h')) {
  console.log(`Usage: node harmony-gen.js <color|hue> [scheme] [--css] [--json] [--tokens]

Arguments:
  color      Base color: #hex, rgb(r,g,b), oklch(l c h), or bare hue (0-360)
  scheme     Harmony type (default: analogous)

Schemes:
  complementary   Base + opposite hue (2 colors + tints)
  analogous       Base + neighboring hues (5 colors)
  triadic         3 evenly spaced hues
  split           Base + 2 flanking its complement
  tetradic        4 hues in rectangle pattern
  monochromatic   Single hue, varied lightness + chroma (6 stops)
  warm            Warm palette (reds, oranges, golds)
  cool            Cool palette (blues, teals, greens)
  earth           Muted natural tones (ochre, sage, clay, slate)
  pastel          High lightness, low chroma, varied hue
  vibrant         Mid lightness, high chroma, varied hue
  random          5 curated random colors with good contrast spread

Flags:
  --css      Output as CSS custom properties (default)
  --json     Output as JSON
  --tokens   Output as design token CSS (surface, primary, accent, etc.)
  --tints    Include 3-step tint/shade per color

Examples:
  node harmony-gen.js 250                          # Analogous from hue 250
  node harmony-gen.js "#3b82f6" triadic            # Triadic from a hex color
  node harmony-gen.js "oklch(0.6 0.18 250)" split --tokens
  node harmony-gen.js 30 earth --json
  node harmony-gen.js random`);
  process.exit(0);
}

// ========== Color math ==========

function oklchToOklab(L, C, H) {
  const hRad = H * Math.PI / 180;
  return [L, C * Math.cos(hRad), C * Math.sin(hRad)];
}

function oklabToLinearRgb(L, a, b) {
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  const l = l_ * l_ * l_;
  const m = m_ * m_ * m_;
  const s = s_ * s_ * s_;
  return [
    +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
}

function linearToSrgb(c) {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

function srgbToLinear(c) {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function linearRgbToOklab(lr, lg, lb) {
  const l_ = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m_ = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s_ = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lb + 0.6299787005 * lb);
  return [
    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
  ];
}

function oklabToOklch(L, a, b) {
  const C = Math.sqrt(a * a + b * b);
  const H = (Math.atan2(b, a) * 180 / Math.PI + 360) % 360;
  return [L, C, H];
}

function toHex(l, c, h) {
  const [labL, labA, labB] = oklchToOklab(l, c, h);
  const [lr, lg, lb] = oklabToLinearRgb(labL, labA, labB);
  const clamp = v => Math.round(Math.min(255, Math.max(0, linearToSrgb(v) * 255)));
  return '#' + [clamp(lr), clamp(lg), clamp(lb)].map(v => v.toString(16).padStart(2, '0')).join('');
}

function isInGamut(l, c, h) {
  const [labL, labA, labB] = oklchToOklab(l, c, h);
  const [lr, lg, lb] = oklabToLinearRgb(labL, labA, labB);
  return [lr, lg, lb].every(v => v >= -0.002 && v <= 1.002);
}

// Reduce chroma until color fits sRGB
function gamutClamp(l, c, h) {
  if (isInGamut(l, c, h)) return { l, c, h };
  let lo = 0, hi = c;
  for (let i = 0; i < 20; i++) {
    const mid = (lo + hi) / 2;
    if (isInGamut(l, mid, h)) lo = mid;
    else hi = mid;
  }
  return { l, c: +lo.toFixed(4), h };
}

function wrapHue(h) {
  return ((h % 360) + 360) % 360;
}

// ========== Parsing ==========

function parseInput(str) {
  str = str.trim();

  // Bare hue number
  if (/^\d+(\.\d+)?$/.test(str)) {
    const h = parseFloat(str);
    if (h >= 0 && h <= 360) return { l: 0.6, c: 0.15, h };
  }

  // Hex
  if (str.startsWith('#') || /^[0-9a-f]{6}$/i.test(str)) {
    let hex = str.replace('#', '');
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    const n = parseInt(hex, 16);
    const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    const [lr, lg, lb] = [srgbToLinear(r / 255), srgbToLinear(g / 255), srgbToLinear(b / 255)];
    const [labL, labA, labB] = linearRgbToOklab(lr, lg, lb);
    const [L, C, H] = oklabToOklch(labL, labA, labB);
    return { l: L, c: C, h: H };
  }

  // rgb()
  const rgbM = str.match(/rgb\(\s*(\d+)\s*[,\s]\s*(\d+)\s*[,\s]\s*(\d+)\s*\)/i);
  if (rgbM) {
    const [r, g, b] = [+rgbM[1], +rgbM[2], +rgbM[3]];
    const [lr, lg, lb] = [srgbToLinear(r / 255), srgbToLinear(g / 255), srgbToLinear(b / 255)];
    const [labL, labA, labB] = linearRgbToOklab(lr, lg, lb);
    const [L, C, H] = oklabToOklch(labL, labA, labB);
    return { l: L, c: C, h: H };
  }

  // oklch()
  const oklchM = str.match(/oklch\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\)/i);
  if (oklchM) return { l: +oklchM[1], c: +oklchM[2], h: +oklchM[3] };

  return null;
}

// ========== Scheme generators ==========
// Each returns an array of { name, l, c, h } objects.
// The key insight: geometric hue harmony alone makes boring palettes.
// Good palettes vary lightness and chroma deliberately.

function complementary(base) {
  return [
    { name: 'base', ...base },
    { name: 'base-light', l: base.l + 0.2, c: base.c * 0.5, h: base.h },
    { name: 'complement', l: base.l, c: base.c * 0.9, h: wrapHue(base.h + 180) },
    { name: 'complement-light', l: base.l + 0.2, c: base.c * 0.4, h: wrapHue(base.h + 180) },
    { name: 'neutral', l: base.l + 0.1, c: 0.02, h: base.h },
  ];
}

function analogous(base) {
  return [
    { name: 'color-1', l: base.l + 0.1, c: base.c * 0.7, h: wrapHue(base.h - 30) },
    { name: 'color-2', l: base.l + 0.05, c: base.c * 0.85, h: wrapHue(base.h - 15) },
    { name: 'base', ...base },
    { name: 'color-3', l: base.l - 0.05, c: base.c * 0.85, h: wrapHue(base.h + 15) },
    { name: 'color-4', l: base.l - 0.1, c: base.c * 0.7, h: wrapHue(base.h + 30) },
  ];
}

function triadic(base) {
  return [
    { name: 'primary', ...base },
    { name: 'primary-muted', l: base.l + 0.15, c: base.c * 0.4, h: base.h },
    { name: 'secondary', l: base.l + 0.05, c: base.c * 0.8, h: wrapHue(base.h + 120) },
    { name: 'tertiary', l: base.l - 0.05, c: base.c * 0.8, h: wrapHue(base.h + 240) },
    { name: 'neutral', l: base.l + 0.25, c: 0.015, h: base.h },
  ];
}

function split(base) {
  return [
    { name: 'base', ...base },
    { name: 'base-muted', l: base.l + 0.2, c: base.c * 0.35, h: base.h },
    { name: 'split-1', l: base.l + 0.05, c: base.c * 0.75, h: wrapHue(base.h + 150) },
    { name: 'split-2', l: base.l - 0.05, c: base.c * 0.75, h: wrapHue(base.h + 210) },
    { name: 'neutral', l: 0.92, c: 0.01, h: base.h },
  ];
}

function tetradic(base) {
  return [
    { name: 'primary', ...base },
    { name: 'secondary', l: base.l + 0.05, c: base.c * 0.85, h: wrapHue(base.h + 90) },
    { name: 'tertiary', l: base.l - 0.05, c: base.c * 0.85, h: wrapHue(base.h + 180) },
    { name: 'quaternary', l: base.l + 0.1, c: base.c * 0.7, h: wrapHue(base.h + 270) },
    { name: 'neutral', l: 0.93, c: 0.012, h: base.h },
  ];
}

function monochromatic(base) {
  return [
    { name: 'lightest', l: 0.95, c: base.c * 0.15, h: base.h },
    { name: 'light', l: 0.82, c: base.c * 0.4, h: base.h },
    { name: 'mid-light', l: 0.7, c: base.c * 0.75, h: base.h },
    { name: 'mid', l: base.l, c: base.c, h: base.h },
    { name: 'dark', l: 0.4, c: base.c * 0.7, h: base.h },
    { name: 'darkest', l: 0.22, c: base.c * 0.3, h: base.h },
  ];
}

function warm(base) {
  const h = base.h;
  // Pull toward warm range (0-70)
  return [
    { name: 'cream', l: 0.94, c: 0.04, h: 80 },
    { name: 'gold', l: 0.78, c: 0.14, h: 85 },
    { name: 'amber', l: 0.68, c: 0.17, h: 55 },
    { name: 'terracotta', l: 0.55, c: 0.14, h: 30 },
    { name: 'deep-red', l: 0.38, c: 0.15, h: 15 },
  ];
}

function cool(base) {
  return [
    { name: 'ice', l: 0.95, c: 0.025, h: 230 },
    { name: 'sky', l: 0.8, c: 0.1, h: 230 },
    { name: 'ocean', l: 0.6, c: 0.15, h: 245 },
    { name: 'teal', l: 0.55, c: 0.12, h: 190 },
    { name: 'deep-navy', l: 0.25, c: 0.08, h: 260 },
  ];
}

function earth(base) {
  return [
    { name: 'sand', l: 0.88, c: 0.04, h: 80 },
    { name: 'sage', l: 0.68, c: 0.06, h: 145 },
    { name: 'ochre', l: 0.62, c: 0.1, h: 65 },
    { name: 'clay', l: 0.5, c: 0.08, h: 35 },
    { name: 'slate', l: 0.35, c: 0.03, h: 260 },
  ];
}

function pastel(base) {
  const offsets = [0, 60, 130, 210, 290];
  return offsets.map((offset, i) => ({
    name: `pastel-${i + 1}`,
    l: 0.88 + Math.random() * 0.06,
    c: 0.04 + Math.random() * 0.03,
    h: wrapHue(base.h + offset),
  }));
}

function vibrant(base) {
  const offsets = [0, 72, 144, 216, 288];
  return offsets.map((offset, i) => ({
    name: `vibrant-${i + 1}`,
    l: 0.55 + (i % 2) * 0.1,
    c: 0.18 + Math.random() * 0.04,
    h: wrapHue(base.h + offset),
  }));
}

function random(_base) {
  // Curated random: ensure good lightness spread and hue variety
  const hueStart = Math.random() * 360;
  const goldenAngle = 137.508;
  const colors = [];
  const lightnesses = [0.9, 0.75, 0.6, 0.45, 0.3];
  for (let i = 0; i < 5; i++) {
    colors.push({
      name: `color-${i + 1}`,
      l: lightnesses[i] + (Math.random() - 0.5) * 0.05,
      c: 0.06 + Math.random() * 0.14,
      h: wrapHue(hueStart + goldenAngle * i),
    });
  }
  return colors;
}

const schemes = {
  complementary, analogous, triadic, split, tetradic,
  monochromatic, warm, cool, earth, pastel, vibrant, random,
};

// ========== Parse arguments ==========

const flags = args.filter(a => a.startsWith('--'));
const positional = args.filter(a => !a.startsWith('--'));

const jsonOutput = flags.includes('--json');
const tokensOutput = flags.includes('--tokens');
const includeTints = flags.includes('--tints');

// Handle "random" as first arg
let inputStr, schemeName;
if (positional[0] === 'random') {
  inputStr = '180'; // dummy
  schemeName = 'random';
} else {
  // Rejoin for oklch() parsing
  const joined = positional.join(' ');
  const oklchM = joined.match(/oklch\(\s*[\d.]+\s+[\d.]+\s+[\d.]+\s*\)/i);
  if (oklchM) {
    inputStr = oklchM[0];
    const rest = joined.replace(oklchM[0], '').trim();
    schemeName = rest || 'analogous';
  } else {
    inputStr = positional[0] || '250';
    schemeName = positional[1] || 'analogous';
  }
}

const base = parseInput(inputStr);
if (!base) {
  console.error(`Error: Could not parse "${inputStr}"`);
  process.exit(1);
}

const schemeFn = schemes[schemeName];
if (!schemeFn) {
  console.error(`Unknown scheme: "${schemeName}"`);
  console.error(`Available: ${Object.keys(schemes).join(', ')}`);
  process.exit(1);
}

// ========== Generate ==========

let palette = schemeFn(base);

// Gamut-clamp all colors
palette = palette.map(c => {
  const clamped = gamutClamp(
    Math.min(1, Math.max(0, c.l)),
    c.c,
    wrapHue(c.h)
  );
  return { name: c.name, ...clamped };
});

// Generate tints if requested
function tints(color) {
  return [
    { name: `${color.name}-tint`, l: color.l + 0.15, c: color.c * 0.5, h: color.h },
    { name: `${color.name}-shade`, l: color.l - 0.15, c: color.c * 0.8, h: color.h },
    { name: `${color.name}-muted`, l: color.l + 0.05, c: color.c * 0.3, h: color.h },
  ].map(t => {
    const clamped = gamutClamp(Math.min(1, Math.max(0, t.l)), t.c, wrapHue(t.h));
    return { name: t.name, ...clamped };
  });
}

if (includeTints) {
  const expanded = [];
  for (const color of palette) {
    expanded.push(color, ...tints(color));
  }
  palette = expanded;
}

// ========== Output ==========

if (jsonOutput) {
  const output = palette.map(c => ({
    name: c.name,
    oklch: `oklch(${c.l.toFixed(3)} ${c.c.toFixed(4)} ${c.h.toFixed(1)})`,
    hex: toHex(c.l, c.c, c.h),
  }));
  console.log(JSON.stringify({ scheme: schemeName, colors: output }, null, 2));
  process.exit(0);
}

if (tokensOutput) {
  // Map palette to semantic tokens
  console.log(`:root {
  /* ${schemeName} harmony - generated from oklch(${base.l.toFixed(2)} ${base.c.toFixed(2)} ${base.h.toFixed(0)}) */`);
  const roles = ['primary', 'secondary', 'accent', 'surface', 'muted'];
  palette.slice(0, roles.length).forEach((c, i) => {
    const role = roles[i] || `color-${i + 1}`;
    console.log(`  --color-${role}: oklch(${c.l.toFixed(3)} ${c.c.toFixed(4)} ${c.h.toFixed(1)});  /* ${toHex(c.l, c.c, c.h)} */`);
  });
  // Auto-generate on-surface
  const darkest = palette.reduce((a, b) => a.l < b.l ? a : b);
  const lightest = palette.reduce((a, b) => a.l > b.l ? a : b);
  console.log(`  --color-on-surface: oklch(${darkest.l.toFixed(3)} ${darkest.c.toFixed(4)} ${darkest.h.toFixed(1)});  /* ${toHex(darkest.l, darkest.c, darkest.h)} */`);
  console.log(`  --color-background: oklch(${lightest.l.toFixed(3)} ${lightest.c.toFixed(4)} ${lightest.h.toFixed(1)});  /* ${toHex(lightest.l, lightest.c, lightest.h)} */`);
  console.log('}');
  process.exit(0);
}

// Default: CSS output
console.log(`/* ${schemeName} harmony from oklch(${base.l.toFixed(2)} ${base.c.toFixed(2)} ${base.h.toFixed(0)}) */`);
console.log(':root {');
for (const c of palette) {
  console.log(`  --${c.name}: oklch(${c.l.toFixed(3)} ${c.c.toFixed(4)} ${c.h.toFixed(1)});  /* ${toHex(c.l, c.c, c.h)} */`);
}
console.log('}');
