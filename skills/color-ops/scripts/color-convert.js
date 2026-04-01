#!/usr/bin/env node
// Color converter - convert between hex, rgb, hsl, oklch, oklab
// Usage: node color-convert.js <color>
// Accepts: #hex, rgb(r,g,b), hsl(h,s%,l%), oklch(l c h), oklab(l a b)

const args = process.argv.slice(2);
if (args.length < 1) {
  console.log(`Usage: node color-convert.js <color>

Examples:
  node color-convert.js "#3b82f6"
  node color-convert.js "rgb(59, 130, 246)"
  node color-convert.js "hsl(217, 91%, 60%)"
  node color-convert.js "oklch(0.62 0.18 250)"
  node color-convert.js "oklab(0.62 -0.05 -0.16)"`);
  process.exit(1);
}

const raw = args.join(' ').trim();

// ========== Conversion math ==========

function srgbToLinear(c) {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function linearToSrgb(c) {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

function rgbToLinear(r, g, b) {
  return [srgbToLinear(r / 255), srgbToLinear(g / 255), srgbToLinear(b / 255)];
}

function linearToRgb(lr, lg, lb) {
  const clamp = v => Math.round(Math.min(255, Math.max(0, linearToSrgb(v) * 255)));
  return [clamp(lr), clamp(lg), clamp(lb)];
}

function linearRgbToOklab(lr, lg, lb) {
  const l_ = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m_ = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s_ = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return [
    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
  ];
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

function oklabToOklch(L, a, b) {
  const C = Math.sqrt(a * a + b * b);
  const H = (Math.atan2(b, a) * 180 / Math.PI + 360) % 360;
  return [L, C, H];
}

function oklchToOklab(L, C, H) {
  const hRad = H * Math.PI / 180;
  return [L, C * Math.cos(hRad), C * Math.sin(hRad)];
}

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  const l = (max + min) / 2;
  if (d === 0) return [0, 0, l * 100];
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h;
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
  else if (max === g) h = ((b - r) / d + 2) / 6;
  else h = ((r - g) / d + 4) / 6;
  return [h * 360, s * 100, l * 100];
}

function hslToRgb(h, s, l) {
  h /= 360; s /= 100; l /= 100;
  if (s === 0) { const v = Math.round(l * 255); return [v, v, v]; }
  const hue2rgb = (p, q, t) => {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1/6) return p + (q - p) * 6 * t;
    if (t < 1/2) return q;
    if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
    return p;
  };
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return [
    Math.round(hue2rgb(p, q, h + 1/3) * 255),
    Math.round(hue2rgb(p, q, h) * 255),
    Math.round(hue2rgb(p, q, h - 1/3) * 255),
  ];
}

function relativeLuminance(r, g, b) {
  const [lr, lg, lb] = rgbToLinear(r, g, b);
  return 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
}

// ========== Parsing ==========

function parseColor(str) {
  str = str.trim();

  // Hex
  if (str.startsWith('#') || /^[0-9a-f]{3,8}$/i.test(str)) {
    let hex = str.replace('#', '');
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    const n = parseInt(hex, 16);
    return { type: 'hex', rgb: [(n >> 16) & 255, (n >> 8) & 255, n & 255] };
  }

  // rgb()
  const rgbMatch = str.match(/rgb\(\s*(\d+)\s*[,\s]\s*(\d+)\s*[,\s]\s*(\d+)\s*\)/i);
  if (rgbMatch) return { type: 'rgb', rgb: [+rgbMatch[1], +rgbMatch[2], +rgbMatch[3]] };

  // hsl()
  const hslMatch = str.match(/hsl\(\s*([\d.]+)\s*[,\s]\s*([\d.]+)%?\s*[,\s]\s*([\d.]+)%?\s*\)/i);
  if (hslMatch) {
    const rgb = hslToRgb(+hslMatch[1], +hslMatch[2], +hslMatch[3]);
    return { type: 'hsl', rgb, hsl: [+hslMatch[1], +hslMatch[2], +hslMatch[3]] };
  }

  // oklch()
  const oklchMatch = str.match(/oklch\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\)/i);
  if (oklchMatch) {
    const [L, C, H] = [+oklchMatch[1], +oklchMatch[2], +oklchMatch[3]];
    const [labL, labA, labB] = oklchToOklab(L, C, H);
    const [lr, lg, lb] = oklabToLinearRgb(labL, labA, labB);
    const rgb = linearToRgb(lr, lg, lb);
    return { type: 'oklch', rgb, oklch: [L, C, H], oklab: [labL, labA, labB] };
  }

  // oklab()
  const oklabMatch = str.match(/oklab\(\s*([\d.e+-]+)\s+([\d.e+-]+)\s+([\d.e+-]+)\s*\)/i);
  if (oklabMatch) {
    const [L, a, b] = [+oklabMatch[1], +oklabMatch[2], +oklabMatch[3]];
    const [lr, lg, lb] = oklabToLinearRgb(L, a, b);
    const rgb = linearToRgb(lr, lg, lb);
    return { type: 'oklab', rgb, oklab: [L, a, b] };
  }

  return null;
}

// ========== Main ==========

const parsed = parseColor(raw);
if (!parsed) {
  console.error(`Error: Could not parse color "${raw}"`);
  console.error('Supported formats: #hex, rgb(r,g,b), hsl(h,s%,l%), oklch(l c h), oklab(l a b)');
  process.exit(1);
}

const [r, g, b] = parsed.rgb;
const hex = '#' + [r, g, b].map(c => c.toString(16).padStart(2, '0')).join('');
const [lr, lg, lb] = rgbToLinear(r, g, b);
const [labL, labA, labB] = parsed.oklab || linearRgbToOklab(lr, lg, lb);
const [oklchL, oklchC, oklchH] = parsed.oklch || oklabToOklch(labL, labA, labB);
const [hslH, hslS, hslL] = parsed.hsl || rgbToHsl(r, g, b);
const lum = relativeLuminance(r, g, b);

const inGamut = [lr, lg, lb].every(v => v >= -0.001 && v <= 1.001);

console.log(`
Input:    ${raw}

hex       ${hex}
rgb       rgb(${r}, ${g}, ${b})
hsl       hsl(${hslH.toFixed(1)}, ${hslS.toFixed(1)}%, ${hslL.toFixed(1)}%)
oklch     oklch(${oklchL.toFixed(4)} ${oklchC.toFixed(4)} ${oklchH.toFixed(1)})
oklab     oklab(${labL.toFixed(4)} ${labA.toFixed(4)} ${labB.toFixed(4)})

Luminance ${lum.toFixed(4)}
sRGB      ${inGamut ? 'in gamut' : 'OUT OF GAMUT - will be clamped on sRGB displays'}
`.trim());
