#!/usr/bin/env node
// Contrast checker - WCAG 2.x ratio + pass/fail for AA/AAA
// Usage: node contrast-check.js <color1> <color2>
// Accepts: hex (#fff, #ffffff), rgb(r,g,b), oklch(l c h)

const args = process.argv.slice(2);
if (args.length < 2) {
  console.log(`Usage: node contrast-check.js <color1> <color2>

Examples:
  node contrast-check.js "#1a1a2e" "#e0e0e0"
  node contrast-check.js "rgb(26,26,46)" "rgb(224,224,224)"
  node contrast-check.js "oklch(0.15 0.02 250)" "oklch(0.9 0.01 250)"
  node contrast-check.js "#1a1a2e" "oklch(0.9 0.01 250)"`);
  process.exit(1);
}

// --- Color parsing ---

function parseHex(hex) {
  hex = hex.replace('#', '');
  if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
  const n = parseInt(hex, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function parseRgb(str) {
  const m = str.match(/rgb\(\s*(\d+)\s*[,\s]\s*(\d+)\s*[,\s]\s*(\d+)\s*\)/i);
  if (!m) return null;
  return [+m[1], +m[2], +m[3]];
}

function parseOklch(str) {
  const m = str.match(/oklch\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\)/i);
  if (!m) return null;
  return oklchToSrgb(+m[1], +m[2], +m[3]);
}

function parseColor(str) {
  str = str.trim();
  if (str.startsWith('#')) return parseHex(str);
  if (str.startsWith('rgb')) return parseRgb(str);
  if (str.startsWith('oklch')) return parseOklch(str);
  // Try as bare hex
  if (/^[0-9a-f]{3,8}$/i.test(str)) return parseHex(str);
  return null;
}

// --- OKLCH -> sRGB conversion ---

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

function oklchToSrgb(L, C, H) {
  const [labL, labA, labB] = oklchToOklab(L, C, H);
  const [lr, lg, lb] = oklabToLinearRgb(labL, labA, labB);
  return [
    Math.round(Math.min(255, Math.max(0, linearToSrgb(lr) * 255))),
    Math.round(Math.min(255, Math.max(0, linearToSrgb(lg) * 255))),
    Math.round(Math.min(255, Math.max(0, linearToSrgb(lb) * 255))),
  ];
}

// --- Contrast calculation ---

function srgbToLinear(c) {
  c /= 255;
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function relativeLuminance(r, g, b) {
  return 0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b);
}

function contrastRatio(l1, l2) {
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

function rgbToHex(r, g, b) {
  return '#' + [r, g, b].map(c => c.toString(16).padStart(2, '0')).join('');
}

// --- Main ---

// Rejoin args that might have been split by spaces (e.g. "oklch(0.5" "0.1" "250)")
const raw = args.join(' ');
const colors = [];
const patterns = [
  /oklch\(\s*[\d.]+\s+[\d.]+\s+[\d.]+\s*\)/gi,
  /rgb\(\s*\d+\s*[,\s]\s*\d+\s*[,\s]\s*\d+\s*\)/gi,
  /#[0-9a-f]{3,8}/gi,
];

let remaining = raw;
for (const pat of patterns) {
  const matches = remaining.match(pat);
  if (matches) {
    for (const m of matches) {
      colors.push(m);
      remaining = remaining.replace(m, '');
    }
  }
}
// Pick up any bare tokens left
const bare = remaining.trim().split(/\s+/).filter(s => s.length > 0);
colors.push(...bare);

if (colors.length < 2) {
  console.error('Error: Could not parse two colors from input.');
  process.exit(1);
}

const rgb1 = parseColor(colors[0]);
const rgb2 = parseColor(colors[1]);

if (!rgb1 || !rgb2) {
  console.error(`Error: Could not parse color${!rgb1 ? ' 1: ' + colors[0] : ''}${!rgb2 ? ' 2: ' + colors[1] : ''}`);
  process.exit(1);
}

const l1 = relativeLuminance(...rgb1);
const l2 = relativeLuminance(...rgb2);
const ratio = contrastRatio(l1, l2);

const pass = (threshold) => ratio >= threshold ? 'PASS' : 'FAIL';

console.log(`
Color 1:  ${colors[0].trim()}  ->  rgb(${rgb1.join(', ')})  ${rgbToHex(...rgb1)}
Color 2:  ${colors[1].trim()}  ->  rgb(${rgb2.join(', ')})  ${rgbToHex(...rgb2)}

Contrast ratio: ${ratio.toFixed(2)}:1

  WCAG AA  normal text (4.5:1)   ${pass(4.5)}
  WCAG AA  large text   (3:1)    ${pass(3)}
  WCAG AAA normal text (7:1)     ${pass(7)}
  WCAG AAA large text  (4.5:1)   ${pass(4.5)}
`.trim());
