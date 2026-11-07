#!/usr/bin/env node
// Palette checks: WCAG contrast against a background, colour-blind distinguishability, sRGB gamut.
//
// Usage:   palette-check.js <colour>... [--bg COLOUR] [--min-contrast R] [--min-delta D] [--json]
// Input:   one to twenty-four colours (#rgb, #rrggbb, oklch(L C H)); no stdin
// Output:  text: TSV rows "colour" (hex, contrast, gamut, pass) then "pair" (deltaE per vision,
//          pass), last line "result pass|fail"; --json: claude-mods.color-ops.palette-check/v1
//          envelope, data = { colours: [...], pairs: [...], failures: [...] }
// Stderr:  a one-line failure summary when a check fails
// Exit:    0 every check passes, 2 usage, 4 colour unparseable, 10 a check failed
//
// deltaE is Euclidean OKLab distance x100 (about 2 = just noticeable) after simulating
// protanopia, deuteranopia and tritanopia at full severity (Machado et al. 2009). The
// default --min-delta 10 is a working threshold for chart marks, not a standard; raise
// it for thin lines and small markers. --min-contrast defaults to 3, the WCAG 2.2 SC
// 1.4.11 non-text minimum; use 4.5 for text. An oklch() input outside sRGB fails the
// gamut check and is checked as its chroma-clipped hex.
//
// Examples:
//   palette-check.js '#1F77B4' '#FF7F0E' '#2CA02C' '#D62728'
//   palette-check.js '#1F77B4' '#FF7F0E' --bg '#121212' --json | jq '.data.failures'
//   palette-check.js 'oklch(0.7 0.3 150)' --min-contrast 4.5
'use strict';

const core = require('./lib/oklch-core.js');

const HELP = `
Usage: palette-check.js <colour>... [options]

Check a palette: contrast of each colour against a background, deltaE between
every pair under normal vision and three colour-vision deficiencies, and whether
each oklch() input fits sRGB. Exits 10 when any check fails.

Options:
  --bg COLOUR        background (default: #FFFFFF)
  --min-contrast R   minimum contrast ratio against --bg (default: 3)
  --min-delta D      minimum OKLab deltaE x100 between pairs, every vision (default: 10)
  --json             JSON envelope (claude-mods.color-ops.palette-check/v1)
  -h, --help         this help

Exit codes: 0 all pass, 2 usage, 4 colour unparseable, 10 a check failed

EXAMPLES
  palette-check.js '#1F77B4' '#FF7F0E' '#2CA02C' '#D62728'
  palette-check.js '#1F77B4' '#FF7F0E' --bg '#121212' --json | jq '.data.failures'
  palette-check.js 'oklch(0.7 0.3 150)' --min-contrast 4.5
`;

function build(argv) {
  const { opts, positional } = core.parseArgs(argv, {
    bg: 'string', 'min-contrast': 'number', 'min-delta': 'number', json: 'bool', help: 'bool',
  });
  const mode = core.outputMode(opts);
  if (mode === 'css' || mode === 'svg') throw new core.UsageError('palette-check supports text and --json only');
  if (positional.length < 1 || positional.length > 24) throw new core.UsageError(`want 1-24 colours, got ${positional.length}`);
  const minContrast = opts['min-contrast'] !== undefined ? opts['min-contrast'] : 3;
  const minDelta = opts['min-delta'] !== undefined ? opts['min-delta'] : 10;
  if (!(minContrast >= 1 && minContrast <= 21)) throw new core.UsageError('--min-contrast must be within 1-21');
  if (!(minDelta >= 0)) throw new core.UsageError('--min-delta must be 0 or more');
  const bg = core.parseColor(opts.bg || '#FFFFFF');

  const failures = [];
  const colours = positional.map(p => {
    const c = core.parseColor(p);
    const contrast = core.round(core.contrastRatio(c.hex, bg.hex), 2);
    const row = {
      input: c.input,
      hex: c.hex,
      oklch: { l: core.round(c.oklch.l, 3), c: core.round(c.oklch.c, 3), h: core.round(c.oklch.h, 1) },
      in_gamut: c.in_gamut,
      contrast,
      contrast_pass: contrast >= minContrast,
    };
    if (!row.in_gamut) failures.push({ check: 'gamut', colour: c.input, detail: `outside sRGB, checked as ${c.hex}` });
    if (!row.contrast_pass) failures.push({ check: 'contrast', colour: c.hex, detail: `${contrast}:1 < ${minContrast}:1 on ${bg.hex}` });
    return row;
  });

  const pairs = [];
  for (let i = 0; i < colours.length; i++) {
    for (let j = i + 1; j < colours.length; j++) {
      const delta = core.deltaEAllVisions(colours[i].hex, colours[j].hex);
      const worst = core.VISION.reduce((w, v) => (delta[v] < delta[w] ? v : w), 'normal');
      const pass = delta[worst] >= minDelta;
      pairs.push({ a: colours[i].hex, b: colours[j].hex, delta_e: delta, worst_vision: worst, pass });
      if (!pass) failures.push({ check: 'distinguishable', colour: `${colours[i].hex}/${colours[j].hex}`, detail: `deltaE ${delta[worst]} under ${worst} < ${minDelta}` });
    }
  }

  const exit = failures.length ? 10 : 0;
  if (exit) process.stderr.write(`palette-check: ${failures.length} check(s) failed\n`);
  const data = { background: bg.hex, thresholds: { min_contrast: minContrast, min_delta: minDelta }, colours, pairs, failures };
  if (mode === 'json') return { mode, data, meta: { count: colours.length, pass: !exit }, exit };
  const lines = [
    ...colours.map(c => ['colour', c.hex, `${c.contrast}:1`, c.in_gamut ? 'in-gamut' : 'out-of-gamut', c.contrast_pass && c.in_gamut ? 'pass' : 'fail'].join('\t')),
    ...pairs.map(p => ['pair', `${p.a}/${p.b}`, ...core.VISION.map(v => `${v}=${p.delta_e[v]}`), p.pass ? 'pass' : 'fail'].join('\t')),
    `result\t${exit ? 'fail' : 'pass'}`,
  ];
  return { mode, text: lines.join('\n'), exit };
}

core.runCli('palette-check', 'claude-mods.color-ops.palette-check/v1', HELP, build);
