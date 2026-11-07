#!/usr/bin/env node
// Hue-harmony palettes from one anchor colour, with OKLCH lightness and chroma held fixed.
//
// Usage:   hue-harmony.js <colour> [--rule NAME] [--l L] [--c C] [--count N] [--json|--css|--svg]
// Input:   one colour (#rgb, #rrggbb, oklch(L C H)); no stdin
// Output:  text: TSV rule, role, hex, oklch, clipped; --json: claude-mods.color-ops.hue-harmony/v1
//          envelope, data = [{rule, role, offset, hex, oklch, css, requested_c, clipped}];
//          --css: :root custom properties; --svg: static swatch sheet (no JavaScript)
// Stderr:  errors only
// Exit:    0 ok, 2 usage, 4 colour unparseable
//
// Each rule rotates the hue and keeps L and C, so no member dominates by being lighter or
// more saturated. Where a hue cannot reach C inside sRGB, chroma is lowered (never L) and
// the row is marked clipped=true. monochrome keeps the hue and steps lightness toward
// white and black, each gap 1/phi of the one before.
//
// Examples:
//   hue-harmony.js '#E0675F'
//   hue-harmony.js '#E0675F' --rule golden --count 6 --l 0.6 --c 0.12 --json | jq '.data[].hex'
//   hue-harmony.js 'oklch(0.55 0.14 250)' --rule triadic --css
//   hue-harmony.js '#3B82F6' --svg > harmony.svg
'use strict';

const core = require('./lib/oklch-core.js');

const RULES = {
  complementary: () => [['base', 0], ['complement', 180]],
  'split-complementary': () => [['base', 0], ['split-a', 150], ['split-b', 210]],
  triadic: () => [['base', 0], ['triad-a', 120], ['triad-b', 240]],
  analogous: () => [['left', -30], ['base', 0], ['right', 30]],
  golden: n => Array.from({ length: n }, (_, k) => [k === 0 ? 'base' : `golden-${k}`, k * core.GOLDEN_ANGLE]),
};
const RULE_NAMES = [...Object.keys(RULES), 'monochrome'];

const HELP = `
Usage: hue-harmony.js <colour> [options]

Build palettes from one anchor colour by rotating its OKLCH hue while holding
lightness and chroma fixed. Chroma (never lightness) is lowered where a hue
cannot reach it inside sRGB; those rows are marked clipped.

Rules:
  complementary         +180
  split-complementary   +150, +210
  triadic               +120, +240
  analogous             -30, +30
  golden                k x 137.508 (golden angle), --count members
  monochrome            same hue, lightness steps by the golden ratio
  all                   every rule above (default)

Options:
  --rule NAME     one rule, or all (default: all)
  --l L           fixed lightness 0-1 (default: the anchor's)
  --c C           fixed chroma (default: the anchor's)
  --count N       members for golden, steps per side for monochrome (default: 5 / 2)
  --json          JSON envelope (claude-mods.color-ops.hue-harmony/v1)
  --css           CSS custom properties
  --svg           static SVG swatch sheet
  -h, --help      this help

Exit codes: 0 ok, 2 usage, 4 colour unparseable

EXAMPLES
  hue-harmony.js '#E0675F'
  hue-harmony.js '#E0675F' --rule golden --count 6 --l 0.6 --c 0.12 --json | jq '.data[].hex'
  hue-harmony.js 'oklch(0.55 0.14 250)' --rule triadic --css
  hue-harmony.js '#3B82F6' --svg > harmony.svg
`;

function monochrome(anchor, L, C, steps) {
  const rows = [];
  for (let k = steps; k >= 1; k--) rows.push([`dark-${k}`, L / core.PHI ** k]);
  rows.push(['base', L]);
  for (let k = 1; k <= steps; k++) rows.push([`light-${k}`, 1 - (1 - L) / core.PHI ** k]);
  return rows.map(([role, l]) => ({ rule: 'monochrome', role, offset: 0, ...core.colourRecord(core.fitGamut(l, C, anchor.h)) }));
}

function build(argv) {
  const { opts, positional } = core.parseArgs(argv, {
    rule: 'string', l: 'number', c: 'number', count: 'number', json: 'bool', css: 'bool', svg: 'bool', help: 'bool',
  });
  const mode = core.outputMode(opts);
  if (positional.length !== 1) throw new core.UsageError(`want exactly one colour, got ${positional.length}`);
  const rule = opts.rule || 'all';
  if (rule !== 'all' && !RULE_NAMES.includes(rule)) throw new core.UsageError(`unknown rule "${rule}" (want ${RULE_NAMES.join(', ')}, all)`);
  if (opts.l !== undefined && !(opts.l >= 0 && opts.l <= 1)) throw new core.UsageError('--l must be within 0-1');
  if (opts.c !== undefined && !(opts.c >= 0 && opts.c <= 0.5)) throw new core.UsageError('--c must be within 0-0.5');
  if (opts.count !== undefined && !(Number.isInteger(opts.count) && opts.count >= 1 && opts.count <= 24)) {
    throw new core.UsageError('--count must be an integer 1-24');
  }

  const anchor = core.parseColor(positional[0]);
  const L = opts.l !== undefined ? opts.l : anchor.oklch.l;
  const C = opts.c !== undefined ? opts.c : anchor.oklch.c;
  const H = anchor.oklch.h;

  const rows = [];
  for (const name of rule === 'all' ? RULE_NAMES : [rule]) {
    if (name === 'monochrome') {
      rows.push(...monochrome(anchor.oklch, L, C, opts.count || 2));
      continue;
    }
    for (const [role, offset] of RULES[name](opts.count || 5)) {
      rows.push({ rule: name, role, offset: core.round(offset, 1), ...core.colourRecord(core.fitGamut(L, C, H + offset)) });
    }
  }

  const meta = {
    count: rows.length,
    anchor: { input: anchor.input, hex: anchor.hex, oklch: core.colourRecord(core.fitGamut(anchor.oklch.l, anchor.oklch.c, H)).oklch },
    fixed: { l: core.round(L, 3), c: core.round(C, 3) },
    clipped: rows.filter(r => r.clipped).length,
  };

  if (mode === 'json') return { mode, data: rows, meta };
  if (mode === 'css') {
    const vars = rows.map(r => [`harmony-${r.rule}-${r.role}`, r.hex, r.css + (r.clipped ? ' clipped' : '')]);
    return { mode, text: core.renderCss([{ selector: ':root', vars }], `hue-harmony from ${anchor.hex}, fixed L ${meta.fixed.l} C ${meta.fixed.c}`) };
  }
  if (mode === 'svg') {
    const groups = [];
    for (const r of rows) {
      let g = groups.find(x => x.title === r.rule);
      if (!g) groups.push((g = { title: r.rule, swatches: [] }));
      g.swatches.push({ label: r.role, hex: r.hex, note: r.clipped ? '*' : '' });
    }
    return { mode, text: core.renderSwatchSvg(groups, `Harmony from ${anchor.hex} at L ${meta.fixed.l} C ${meta.fixed.c} (* = chroma clipped)`) };
  }
  const lines = rows.map(r => [r.rule, r.role, r.hex, r.css, r.clipped ? 'clipped' : ''].join('\t'));
  return { mode, text: lines.join('\n') };
}

core.runCli('hue-harmony', 'claude-mods.color-ops.hue-harmony/v1', HELP, build);
