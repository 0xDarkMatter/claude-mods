#!/usr/bin/env node
// Brand-colour analyser: hue angles between a set of colours and the harmony rule each pair is nearest.
//
// Usage:   brand-analyse.js <colour> <colour> [<colour>...] [--tolerance DEG] [--json]
// Input:   two to twelve colours (#rgb, #rrggbb, oklch(L C H)); no stdin
// Output:  text: one TSV row per colour, then one per pair (arc, nearest rule, offset, match,
//          lightness gap, contrast); --json: claude-mods.color-ops.brand-analyse/v1 envelope,
//          data = { colours: [...], pairs: [...], summary: {...} }
// Stderr:  errors only
// Exit:    0 ok, 2 usage, 4 colour unparseable
//
// Angles are the shortest arc between OKLCH hues (0-180), so a golden-angle pair reads
// 137.5 whichever way round it was measured (the long way it is 222.5). A colour with
// chroma under 0.02 has no reliable hue: its pairs report achromatic=true and match=false.
//
// Examples:
//   brand-analyse.js '#14283A' '#E0675F'
//   brand-analyse.js '#14283A' '#E0675F' '#17716F' --json | jq '.data.pairs[] | {a, b, nearest}'
//   brand-analyse.js '#1D4ED8' '#F59E0B' '#10B981' --tolerance 5
'use strict';

const core = require('./lib/oklch-core.js');

const HELP = `
Usage: brand-analyse.js <colour> <colour> [<colour>...] [options]

Report each colour in OKLCH, the hue angle between every pair (shortest arc,
0-180), and the harmony rule each pair is closest to: monochrome 0, analogous 30,
triadic 120, golden 137.5, split-complementary 150, complementary 180.

Options:
  --tolerance DEG   a pair matches its nearest rule within this many degrees (default: 8)
  --json            JSON envelope (claude-mods.color-ops.brand-analyse/v1)
  -h, --help        this help

Exit codes: 0 ok, 2 usage, 4 colour unparseable

EXAMPLES
  brand-analyse.js '#14283A' '#E0675F'
  brand-analyse.js '#14283A' '#E0675F' '#17716F' --json | jq '.data.pairs[] | {a, b, nearest}'
  brand-analyse.js '#1D4ED8' '#F59E0B' '#10B981' --tolerance 5
`;

function build(argv) {
  const { opts, positional } = core.parseArgs(argv, { tolerance: 'number', json: 'bool', help: 'bool' });
  const mode = core.outputMode(opts);
  if (mode === 'css' || mode === 'svg') throw new core.UsageError('brand-analyse supports text and --json only');
  if (positional.length < 2 || positional.length > 12) throw new core.UsageError(`want 2-12 colours, got ${positional.length}`);
  const tolerance = opts.tolerance !== undefined ? opts.tolerance : 8;
  if (!(tolerance >= 0 && tolerance <= 90)) throw new core.UsageError('--tolerance must be within 0-90');

  const colours = positional.map(p => {
    const c = core.parseColor(p);
    return {
      input: c.input,
      hex: c.hex,
      oklch: { l: core.round(c.oklch.l, 3), c: core.round(c.oklch.c, 3), h: core.round(c.oklch.h, 1) },
      achromatic: c.oklch.c < core.ACHROMATIC_C,
      raw: c.oklch,
    };
  });

  const pairs = [];
  for (let i = 0; i < colours.length; i++) {
    for (let j = i + 1; j < colours.length; j++) {
      const a = colours[i];
      const b = colours[j];
      const achromatic = a.achromatic || b.achromatic;
      const arc = core.hueArc(a.raw.h, b.raw.h);
      const nearest = core.nearestRule(arc);
      pairs.push({
        a: a.hex,
        b: b.hex,
        hue_arc: core.round(arc, 1),
        hue_directed: core.round(core.wrapHue(b.raw.h - a.raw.h), 1),
        nearest,
        match: !achromatic && nearest.off <= tolerance,
        achromatic,
        lightness_gap: core.round(Math.abs(a.raw.l - b.raw.l), 3),
        chroma_gap: core.round(Math.abs(a.raw.c - b.raw.c), 3),
        contrast: core.round(core.contrastRatio(a.hex, b.hex), 2),
      });
    }
  }
  colours.forEach(c => delete c.raw);

  const matched = {};
  for (const p of pairs) if (p.match) matched[p.nearest.rule] = (matched[p.nearest.rule] || 0) + 1;
  const summary = { pairs: pairs.length, matched: pairs.filter(p => p.match).length, by_rule: matched, tolerance };
  const data = { colours, pairs, summary };

  if (mode === 'json') return { mode, data, meta: { count: colours.length } };
  const lines = [
    ...colours.map(c => ['colour', c.hex, `oklch(${c.oklch.l} ${c.oklch.c} ${c.oklch.h})`, c.achromatic ? 'achromatic' : ''].join('\t')),
    ...pairs.map(p => ['pair', `${p.a}-${p.b}`, `arc=${p.hue_arc}`, `nearest=${p.nearest.rule}`, `off=${p.nearest.off}`,
      p.match ? 'match' : 'no-match', `dL=${p.lightness_gap}`, `contrast=${p.contrast}`].join('\t')),
  ];
  return { mode, text: lines.join('\n') };
}

core.runCli('brand-analyse', 'claude-mods.color-ops.brand-analyse/v1', HELP, build);
