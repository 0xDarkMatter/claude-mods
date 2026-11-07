#!/usr/bin/env node
// Chart series colours in light and dark themes: a current/comparison pair plus a categorical set.
//
// Usage:   series-palette.js <colour> [options] [--json|--css|--svg]
// Input:   one anchor colour (#rgb, #rrggbb, oklch(L C H)) whose hue the pair takes; no stdin
// Output:  text: TSV theme, role, hex, oklch, contrast vs background; --json:
//          claude-mods.color-ops.series-palette/v1 envelope, data = { light, dark } each with
//          { background, pair:[...], categorical:[...], checks }; --css: :root plus a dark block
//          for prefers-color-scheme and [data-theme="dark"]; --svg: static chart preview
// Stderr:  errors only
// Exit:    0 ok (checks are reported, not enforced; gate with palette-check.js), 2 usage,
//          4 colour unparseable
//
// The pair holds hue and chroma and splits on lightness only: "current" is the strong
// line, "previous" the muted one. Defaults (light L 0.45 / 0.72, dark L 0.80 / 0.62,
// C 0.11) came from a dashboard where the muted line read as context, not as a rival
// series. In light mode "previous" is under 3:1 against white on purpose; draw it dashed
// or thicker, or raise --previous-l contrast if it must stand alone (WCAG 2.2 SC 1.4.11).
// Categorical members step the hue by the golden angle at one fixed L and C, so
// neighbours stay far apart in hue however many you ask for.
//
// Examples:
//   series-palette.js '#17716F'
//   series-palette.js '#17716F' --json | jq '.data.dark.pair'
//   series-palette.js '#3B82F6' --categories 8 --css > series.css
//   series-palette.js '#3B82F6' --svg > series.svg
'use strict';

const core = require('./lib/oklch-core.js');

const HELP = `
Usage: series-palette.js <colour> [options]

Light and dark chart colours from one anchor hue: a current-period and a
comparison-period pair (same hue and chroma, different lightness), and a
categorical palette stepped by the golden angle at fixed lightness and chroma.
Each colour carries its contrast against the theme background and the
categorical set carries its worst colour-blind deltaE.

Options:
  --c C                pair chroma (default: 0.11)
  --current-l L        light theme current lightness (default: 0.45)
  --previous-l L       light theme previous lightness (default: 0.72)
  --dark-current-l L   dark theme current lightness (default: 0.80)
  --dark-previous-l L  dark theme previous lightness (default: 0.62)
  --categories N       categorical members, 0 for none (default: 6)
  --cat-l L            light theme categorical lightness (default: 0.55)
  --dark-cat-l L       dark theme categorical lightness (default: 0.72)
  --cat-c C            categorical chroma (default: 0.13)
  --bg COLOUR          light background (default: #FFFFFF)
  --dark-bg COLOUR     dark background (default: #121212)
  --prefix NAME        CSS custom-property prefix (default: series)
  --json | --css | --svg   output format (default: TSV text)
  -h, --help           this help

Exit codes: 0 ok, 2 usage, 4 colour unparseable

EXAMPLES
  series-palette.js '#17716F'
  series-palette.js '#17716F' --json | jq '.data.dark.pair'
  series-palette.js '#3B82F6' --categories 8 --css > series.css
  series-palette.js '#3B82F6' --svg > series.svg
`;

const SPEC = {
  c: 'number', 'current-l': 'number', 'previous-l': 'number', 'dark-current-l': 'number', 'dark-previous-l': 'number',
  categories: 'number', 'cat-l': 'number', 'dark-cat-l': 'number', 'cat-c': 'number', bg: 'string', 'dark-bg': 'string',
  prefix: 'string', json: 'bool', css: 'bool', svg: 'bool', help: 'bool',
};

function unit(opts, key, def, max = 1) {
  const v = opts[key] !== undefined ? opts[key] : def;
  if (!(v >= 0 && v <= max)) throw new core.UsageError(`--${key} must be within 0-${max}`);
  return v;
}

function theme(name, bg, pairL, catL, C, catC, hue, n) {
  const withContrast = (role, fit) => ({ role, ...core.colourRecord(fit), contrast: core.round(core.contrastRatio(fit.hex, bg.hex), 2) });
  const pair = [
    withContrast('current', core.fitGamut(pairL[0], C, hue)),
    withContrast('previous', core.fitGamut(pairL[1], C, hue)),
  ];
  const categorical = Array.from({ length: n }, (_, k) => withContrast(`cat-${k + 1}`, core.fitGamut(catL, catC, hue + k * core.GOLDEN_ANGLE)));
  let worst = null;
  for (let i = 0; i < categorical.length; i++) {
    for (let j = i + 1; j < categorical.length; j++) {
      const d = core.deltaEAllVisions(categorical[i].hex, categorical[j].hex);
      for (const v of core.VISION) {
        if (!worst || d[v] < worst.delta_e) worst = { a: categorical[i].role, b: categorical[j].role, vision: v, delta_e: d[v] };
      }
    }
  }
  return {
    theme: name,
    background: bg.hex,
    pair,
    categorical,
    checks: {
      pair_delta_e: core.deltaEAllVisions(pair[0].hex, pair[1].hex),
      min_contrast: core.round(Math.min(...[...pair, ...categorical].map(x => x.contrast)), 2),
      categorical_worst: worst,
      clipped: [...pair, ...categorical].filter(x => x.clipped).map(x => x.role),
    },
  };
}

function chartSvg(themes, title) {
  const PW = 360, PH = 220, PAD = 16, HEAD = 34;
  const width = PAD + themes.length * (PW + PAD);
  const height = HEAD + PH + PAD;
  const current = [42, 55, 49, 68, 74, 66, 88];
  const previous = [38, 44, 51, 47, 58, 61, 63];
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" font-family="system-ui, -apple-system, Segoe UI, sans-serif">`,
    `<title>${core.esc(title)}</title>`,
    `<rect width="100%" height="100%" fill="#E5E5E5"/>`,
    `<text x="${PAD}" y="22" font-size="14" font-weight="600" fill="#000000">${core.esc(title)}</text>`,
  ];
  themes.forEach((t, ti) => {
    const x0 = PAD + ti * (PW + PAD);
    const y0 = HEAD;
    const ink = core.labelInk(t.background);
    const plotX = x0 + 16, plotY = y0 + 36, plotW = PW - 32, plotH = 110;
    const pts = series => series.map((v, i) => `${(plotX + (i * plotW) / (series.length - 1)).toFixed(1)},${(plotY + plotH - (v / 100) * plotH).toFixed(1)}`).join(' ');
    const [cur, prev] = t.pair;
    parts.push(
      `<rect x="${x0}" y="${y0}" width="${PW}" height="${PH}" rx="8" fill="${t.background}"/>`,
      `<text x="${x0 + 16}" y="${y0 + 22}" font-size="12" font-weight="600" fill="${ink}">${core.esc(t.theme)} on ${t.background}</text>`,
      `<line x1="${plotX}" y1="${plotY + plotH}" x2="${plotX + plotW}" y2="${plotY + plotH}" stroke="${ink}" stroke-opacity="0.25"/>`,
      `<polyline points="${pts(previous)}" fill="none" stroke="${prev.hex}" stroke-width="2.5" stroke-dasharray="6 4"/>`,
      `<polyline points="${pts(current)}" fill="none" stroke="${cur.hex}" stroke-width="3"/>`,
      `<text x="${x0 + 16}" y="${plotY + plotH + 20}" font-size="11" fill="${ink}">current ${cur.hex} (${cur.contrast}:1)  previous ${prev.hex} (${prev.contrast}:1)</text>`,
    );
    const sw = Math.min(40, (plotW - 4 * (t.categorical.length - 1)) / Math.max(1, t.categorical.length));
    t.categorical.forEach((c, i) => {
      parts.push(`<rect x="${(plotX + i * (sw + 4)).toFixed(1)}" y="${plotY + plotH + 32}" width="${sw.toFixed(1)}" height="18" rx="3" fill="${c.hex}"><title>${c.role} ${c.hex}</title></rect>`);
    });
  });
  parts.push('</svg>');
  return parts.join('\n') + '\n';
}

function build(argv) {
  const { opts, positional } = core.parseArgs(argv, SPEC);
  const mode = core.outputMode(opts);
  if (positional.length !== 1) throw new core.UsageError(`want exactly one colour, got ${positional.length}`);
  const n = opts.categories !== undefined ? opts.categories : 6;
  if (!(Number.isInteger(n) && n >= 0 && n <= 16)) throw new core.UsageError('--categories must be an integer 0-16');
  const prefix = opts.prefix !== undefined ? opts.prefix : 'series';
  if (!/^[a-z][a-z0-9-]*$/i.test(prefix)) throw new core.UsageError('--prefix must be letters, digits and hyphens');

  const anchor = core.parseColor(positional[0]);
  const bg = core.parseColor(opts.bg || '#FFFFFF');
  const darkBg = core.parseColor(opts['dark-bg'] || '#121212');
  const C = unit(opts, 'c', 0.11, 0.5);
  const catC = unit(opts, 'cat-c', 0.13, 0.5);
  const hue = anchor.oklch.h;

  const light = theme('light', bg, [unit(opts, 'current-l', 0.45), unit(opts, 'previous-l', 0.72)], unit(opts, 'cat-l', 0.55), C, catC, hue, n);
  const dark = theme('dark', darkBg, [unit(opts, 'dark-current-l', 0.80), unit(opts, 'dark-previous-l', 0.62)], unit(opts, 'dark-cat-l', 0.72), C, catC, hue, n);
  const meta = { anchor: { input: anchor.input, hex: anchor.hex }, hue: core.round(hue, 1), count: 2 * (2 + n) };

  if (mode === 'json') return { mode, data: { light, dark }, meta };
  if (mode === 'css') {
    const vars = t => [...t.pair, ...t.categorical].map(x => [`${prefix}-${x.role}`, x.hex, `${x.css}, ${x.contrast}:1 on ${t.background}`]);
    return {
      mode,
      text: core.renderCss([
        { selector: ':root', vars: vars(light) },
        { selector: ':root:not([data-theme="light"])', media: '@media (prefers-color-scheme: dark)', vars: vars(dark) },
        { selector: ':root[data-theme="dark"]', vars: vars(dark) },
      ], `series-palette from ${anchor.hex} (hue ${meta.hue})`),
    };
  }
  if (mode === 'svg') return { mode, text: chartSvg([light, dark], `Series palette from ${anchor.hex}, hue ${meta.hue}`) };
  const lines = [];
  for (const t of [light, dark]) {
    for (const x of [...t.pair, ...t.categorical]) {
      lines.push([t.theme, x.role, x.hex, x.css, `${x.contrast}:1`, x.clipped ? 'clipped' : ''].join('\t'));
    }
  }
  return { mode, text: lines.join('\n') };
}

core.runCli('series-palette', 'claude-mods.color-ops.series-palette/v1', HELP, build);
