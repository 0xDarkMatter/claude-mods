#!/usr/bin/env node
// Shared OKLCH maths, checks and renderers for the color-ops scripts.
//
// Usage:   const core = require('./lib/oklch-core.js');   (a module, not a CLI)
// Input:   colours as '#rgb', '#rrggbb' or 'oklch(L C H)' (L as 0-1 or a percentage)
// Output:  plain objects; renderers return strings (CSS, SVG); nothing is printed here
// Exit:    run directly it prints a one-line pointer to stderr and exits 2
//
// Invariants:
//   - The ONLY place colour-space maths lives. Every script requires this file, so a
//     matrix typo is fixed once (harmony-gen.js once carried `* lb` for `* lg` in the
//     sRGB->LMS row and read #14283A as hue 261 instead of 247).
//   - Gamut mapping keeps L and H and lowers C only (binary search), so a palette that
//     holds L and C fixed keeps its lightness when a hue cannot reach the chroma.
//
// Sources:
//   - OKLab matrices: Bjorn Ottosson, "A perceptual color space for image processing",
//     2020, https://bottosson.github.io/posts/oklab/
//   - sRGB transfer and relative luminance: IEC 61966-2-1; WCAG 2.2 SC 1.4.3 / 1.4.11
//   - CVD simulation: Machado, Oliveira & Fernandes 2009, severity 1.0 matrices, applied
//     to linear sRGB
//
// Examples:
//   node -e "console.log(require('./lib/oklch-core.js').parseColor('#14283A'))"
'use strict';

const GOLDEN_ANGLE = 137.50776405003785;
const PHI = (1 + Math.sqrt(5)) / 2;
const ACHROMATIC_C = 0.02;

class ColorError extends Error {}
class UsageError extends Error {}

const wrapHue = h => ((h % 360) + 360) % 360;
const round = (v, d) => Math.round(v * 10 ** d) / 10 ** d;

function srgbToLinear(c) {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

function linearToSrgb(c) {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

function linearRgbToOklab([r, g, b]) {
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
}

function oklabToLinearRgb([L, a, b]) {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
}

function oklchToOklab({ l, c, h }) {
  const r = (h * Math.PI) / 180;
  return [l, c * Math.cos(r), c * Math.sin(r)];
}

function oklabToOklch([l, a, b]) {
  return { l, c: Math.hypot(a, b), h: wrapHue((Math.atan2(b, a) * 180) / Math.PI) };
}

function hexToLinear(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map(v => srgbToLinear(v / 255));
}

function linearToHex(rgb) {
  return '#' + rgb
    .map(v => Math.round(Math.min(1, Math.max(0, linearToSrgb(Math.min(1, Math.max(0, v))))) * 255))
    .map(v => v.toString(16).padStart(2, '0').toUpperCase())
    .join('');
}

function normaliseHex(str) {
  let hex = str.trim().replace(/^#/, '');
  if (/^[0-9a-f]{3}$/i.test(hex)) hex = hex.split('').map(ch => ch + ch).join('');
  if (!/^[0-9a-f]{6}$/i.test(hex)) return null;
  return '#' + hex.toUpperCase();
}

function hexToOklch(hex) {
  return oklabToOklch(linearRgbToOklab(hexToLinear(hex)));
}

// Returns { input, hex, oklch:{l,c,h}, in_gamut }. A hex is always in gamut; an oklch()
// input outside sRGB keeps its requested values in `oklch` and gets a chroma-clipped hex.
function parseColor(str) {
  const s = String(str).trim();
  const hex = normaliseHex(s);
  if (hex) return { input: s, hex, oklch: hexToOklch(hex), in_gamut: true };
  const m = s.match(/^oklch\(\s*([\d.]+)(%?)\s+([\d.]+)\s+([\d.]+)(?:deg)?\s*\)$/i);
  if (m) {
    const l = m[2] ? +m[1] / 100 : +m[1];
    const c = +m[3];
    const h = wrapHue(+m[4]);
    if (!(l >= 0 && l <= 1) || !(c >= 0) || !Number.isFinite(h)) {
      throw new ColorError(`oklch values out of range: "${s}"`);
    }
    const fit = fitGamut(l, c, h);
    return { input: s, hex: fit.hex, oklch: { l, c, h }, in_gamut: !fit.clipped };
  }
  throw new ColorError(`cannot parse colour "${s}" (want #rgb, #rrggbb or oklch(L C H))`);
}

function inGamut(l, c, h) {
  return oklabToLinearRgb(oklchToOklab({ l, c, h })).every(v => v >= -1e-4 && v <= 1 + 1e-4);
}

// Lowers chroma until (l, c, h) fits sRGB. Returns the colour actually rendered.
function fitGamut(l, c, h) {
  l = Math.min(1, Math.max(0, l));
  h = wrapHue(h);
  let fitC = c;
  if (!inGamut(l, c, h)) {
    let lo = 0;
    let hi = c;
    for (let i = 0; i < 30; i++) {
      const mid = (lo + hi) / 2;
      if (inGamut(l, mid, h)) lo = mid; else hi = mid;
    }
    fitC = lo;
  }
  const hex = linearToHex(oklabToLinearRgb(oklchToOklab({ l, c: fitC, h })));
  return { l, c: fitC, h, requested_c: c, clipped: fitC < c - 5e-4, hex };
}

function relativeLuminance(hex) {
  const [r, g, b] = hexToLinear(hex);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrastRatio(hexA, hexB) {
  const [hi, lo] = [relativeLuminance(hexA), relativeLuminance(hexB)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const CVD = {
  protan: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
  deutan: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
  tritan: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
};
const VISION = ['normal', 'protan', 'deutan', 'tritan'];

function simulate(hex, vision) {
  const rgb = hexToLinear(hex);
  if (vision === 'normal') return rgb;
  return CVD[vision].map(row => Math.min(1, Math.max(0, row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2])));
}

// Euclidean OKLab distance x100. About 2 is a just-noticeable difference.
function deltaE(hexA, hexB, vision = 'normal') {
  const a = linearRgbToOklab(simulate(hexA, vision));
  const b = linearRgbToOklab(simulate(hexB, vision));
  return 100 * Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}

function deltaEAllVisions(hexA, hexB) {
  const out = {};
  for (const v of VISION) out[v] = round(deltaE(hexA, hexB, v), 1);
  return out;
}

function hueArc(h1, h2) {
  const d = wrapHue(h2 - h1);
  return d > 180 ? 360 - d : d;
}

// Pairwise rules on the shortest hue arc (0-180). A golden-angle pair reads 137.5 one
// way and 222.5 the other; both land here as 137.5.
const PAIR_RULES = [
  { name: 'monochrome', angle: 0 },
  { name: 'analogous', angle: 30 },
  { name: 'triadic', angle: 120 },
  { name: 'golden', angle: GOLDEN_ANGLE },
  { name: 'split-complementary', angle: 150 },
  { name: 'complementary', angle: 180 },
];

function nearestRule(arc) {
  let best = null;
  for (const r of PAIR_RULES) {
    const off = Math.abs(arc - r.angle);
    if (!best || off < best.off) best = { rule: r.name, angle: round(r.angle, 1), off: round(off, 1) };
  }
  return best;
}

function fmtOklch({ l, c, h }) {
  return `oklch(${round(l, 3)} ${round(c, 3)} ${round(h, 1)})`;
}

function colourRecord(fit) {
  return {
    hex: fit.hex,
    oklch: { l: round(fit.l, 3), c: round(fit.c, 3), h: round(fit.h, 1) },
    css: fmtOklch(fit),
    requested_c: round(fit.requested_c, 3),
    clipped: fit.clipped,
  };
}

// === CLI helpers ===

// spec: { flagName: 'bool' | 'number' | 'string' }. Unknown flags and bad numbers throw
// UsageError so a fabricated flag never runs silently.
function parseArgs(argv, spec) {
  const opts = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h') { opts.help = true; continue; }
    if (!a.startsWith('--')) { positional.push(a); continue; }
    const [key, inline] = a.slice(2).split(/=(.*)/s, 2);
    const kind = spec[key];
    if (!kind) throw new UsageError(`unknown option --${key}`);
    if (kind === 'bool') { opts[key] = true; continue; }
    const val = inline !== undefined ? inline : argv[++i];
    if (val === undefined) throw new UsageError(`--${key} needs a value`);
    if (kind === 'number') {
      const n = Number(val);
      if (!Number.isFinite(n)) throw new UsageError(`--${key} wants a number, got "${val}"`);
      opts[key] = n;
    } else {
      opts[key] = val;
    }
  }
  return { opts, positional };
}

function outputMode(opts) {
  const chosen = ['json', 'css', 'svg'].filter(k => opts[k]);
  if (chosen.length > 1) throw new UsageError(`pick one of --json, --css, --svg (got ${chosen.map(k => '--' + k).join(' ')})`);
  return chosen[0] || 'text';
}

// Runs main(); maps thrown errors to the protocol's exit codes and envelopes.
function runCli(name, schema, helpText, main) {
  const argv = process.argv.slice(2);
  const wantsJson = argv.includes('--json');
  const fail = (code, exit, message) => {
    process.stderr.write(`${name}: ${message}\n`);
    if (wantsJson) process.stdout.write(JSON.stringify({ error: { code, message, details: {} } }) + '\n');
    process.exitCode = exit;
  };
  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(helpText.trimStart());
    return;
  }
  try {
    const result = main(argv);
    if (result.mode === 'json') {
      process.stdout.write(JSON.stringify({ data: result.data, meta: { ...result.meta, schema } }, null, 2) + '\n');
    } else {
      process.stdout.write(result.text.endsWith('\n') ? result.text : result.text + '\n');
    }
    process.exitCode = result.exit || 0;
  } catch (e) {
    if (e instanceof UsageError) {
      fail('USAGE', 2, `${e.message} (see --help)`);
    } else if (e instanceof ColorError) {
      fail('VALIDATION', 4, e.message);
    } else {
      fail('ERROR', 1, e.stack || String(e));
    }
  }
}

// === Renderers ===

const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// blocks: [{ selector, vars: [[name, value, comment?]] }]
function renderCss(blocks, header) {
  const out = header ? [`/* ${header} */`] : [];
  for (const b of blocks) {
    const body = b.vars.map(([n, v, note]) => `  --${n}: ${v};${note ? `  /* ${note} */` : ''}`);
    if (b.media) {
      out.push(`${b.media} {`, `  ${b.selector} {`, ...body.map(l => '  ' + l), '  }', '}');
    } else {
      out.push(`${b.selector} {`, ...body, '}');
    }
  }
  return out.join('\n') + '\n';
}

// Picks black or white label text, whichever contrasts more with the swatch.
function labelInk(hex) {
  return contrastRatio(hex, '#000000') >= contrastRatio(hex, '#FFFFFF') ? '#000000' : '#FFFFFF';
}

// groups: [{ title, swatches: [{ label, hex, note? }] }]. Static SVG, no script, no
// external fonts, so it renders in a file preview, an <img> tag or a PR comment.
function renderSwatchSvg(groups, title, bg = '#FFFFFF') {
  const W = 112, H = 72, GAP = 8, PAD = 16, ROW = H + 40;
  const cols = Math.max(1, ...groups.map(g => g.swatches.length));
  const width = PAD * 2 + cols * W + (cols - 1) * GAP;
  const height = PAD * 2 + 28 + groups.length * ROW;
  const ink = labelInk(bg);
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" font-family="system-ui, -apple-system, Segoe UI, sans-serif">`,
    `<title>${esc(title)}</title>`,
    `<rect width="100%" height="100%" fill="${bg}"/>`,
    `<text x="${PAD}" y="${PAD + 14}" font-size="15" font-weight="600" fill="${ink}">${esc(title)}</text>`,
  ];
  groups.forEach((g, gi) => {
    const y0 = PAD + 28 + gi * ROW;
    parts.push(`<text x="${PAD}" y="${y0 + 12}" font-size="12" fill="${ink}" opacity="0.75">${esc(g.title)}</text>`);
    g.swatches.forEach((s, si) => {
      const x = PAD + si * (W + GAP);
      const y = y0 + 20;
      const t = labelInk(s.hex);
      parts.push(
        `<rect x="${x}" y="${y}" width="${W}" height="${H}" rx="6" fill="${s.hex}"/>`,
        `<text x="${x + 8}" y="${y + 18}" font-size="11" font-weight="600" fill="${t}">${esc(s.label)}</text>`,
        `<text x="${x + 8}" y="${y + H - 10}" font-size="11" fill="${t}">${esc(s.hex)}${s.note ? ' ' + esc(s.note) : ''}</text>`,
      );
    });
  });
  parts.push('</svg>');
  return parts.join('\n') + '\n';
}

module.exports = {
  GOLDEN_ANGLE, PHI, ACHROMATIC_C, VISION, PAIR_RULES,
  ColorError, UsageError,
  wrapHue, round, srgbToLinear, linearToSrgb, linearRgbToOklab, oklabToLinearRgb,
  oklchToOklab, oklabToOklch, hexToOklch, normaliseHex, parseColor, inGamut, fitGamut,
  relativeLuminance, contrastRatio, simulate, deltaE, deltaEAllVisions, hueArc, nearestRule,
  fmtOklch, colourRecord, parseArgs, outputMode, runCli, renderCss, renderSwatchSvg,
  labelInk, slug, esc,
};

if (require.main === module) {
  process.stderr.write('oklch-core.js is a module; run hue-harmony.js, brand-analyse.js, series-palette.js or palette-check.js\n');
  process.exitCode = 2;
}
