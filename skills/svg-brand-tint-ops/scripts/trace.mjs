#!/usr/bin/env node
// Headless raster→vector tracer — PNG/JPG/WebP → SVG using the shared engine.
//
// Wraps assets/trace-core.mjs (the same code the browser tool runs) with a PNG
// decoder so logos can be vectorised from the command line or an agent. The
// browser tool is zero-dependency; this CLI needs `sharp` only to decode pixels.
//
// Pipeline: decode → 2x lanczos supersample (sharp resize; --super N to change)
// → v3 engine (soft-field + matte machinery + Potrace-style global geometry,
// all ON by default in the engine) → SVG at native size. Pixel-space knobs are
// specified at the 2x-supersample reference scale and scaled with --super so a
// different factor behaves identically in native px. Fine hairline/barcode art
// (sub-pixel strokes at 2x) benefits from --super 4.
//
// Usage:   node trace.mjs <input> [output.svg] [OPTIONS]
// Input:   an image file (png/jpg/webp). Output path optional (else stdout).
// Output:  SVG on stdout when no output path is given (data only).
// Stderr:  progress + the fidelity-relevant settings.
// Exit:    0 ok, 2 usage, 3 input-not-found, 5 missing-dep (sharp), 1 error.
//
// Options (defaults tuned for flat brand logos):
//   --mode color|bw|poster   trace mode (default color)
//   --colors N               palette size for color mode (default 6)
//   --super N                supersample factor for sub-pixel edges (default 2;
//                            use 4 for hairline serifs / fine barcode marks)
//   --detail N               simplify tolerance, native px (default 0.35;
//                            only used when the potrace stage is disabled)
//   --smooth N               curve tension 0..1 (default 0.5)
//   --merge N                merge palette colours within N (default 48)
//   --despeckle N            drop features under N px², native (default 4)
//   --threshold N            bw luminance cut (default 128)
//   --levels N               poster bands (default 4)
//   --invert                 invert luminance (bw/poster)
//
// Examples:
//   node trace.mjs logo.png logo.svg
//   node trace.mjs logo.png --colors 8 --super 2 > logo.svg
//   node trace.mjs wordmark.png wordmark.svg --super 4
//   node trace.mjs icon.png icon.svg --mode bw --threshold 140

import { readFile, writeFile, access } from 'node:fs/promises';
import { constants as FS } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const has = f => argv.includes(f);
const flag = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

if (has('-h') || has('--help') || argv.length === 0) {
  process.stdout.write(HELP()); process.exit(0);
}
function HELP() {
  return `headless raster→vector tracer (PNG/JPG/WebP → SVG)

Usage:   node trace.mjs <input> [output.svg] [OPTIONS]

Options:
  --mode color|bw|poster  (default color)   --colors N     palette size (default 6)
  --super N   supersample (default 2; 4 for hairline/barcode art)
  --detail N  simplify px, non-potrace path (default 0.35)
  --smooth N  curve tension (default 0.5)     --merge N      merge colours < N (default 48)
  --despeckle N native px² (default 4)        --threshold N  bw cut (default 128)
  --levels N  poster bands (default 4)        --invert       invert luminance
  -h, --help

Examples:
  node trace.mjs logo.png logo.svg
  node trace.mjs logo.png --colors 8 > logo.svg
  node trace.mjs wordmark.png wordmark.svg --super 4
  node trace.mjs icon.png icon.svg --mode bw --threshold 140
`;
}

// positionals (first two non-flag, non-flag-value tokens)
const flagsWithVal = new Set(['--mode', '--colors', '--super', '--detail', '--smooth', '--merge', '--despeckle', '--threshold', '--levels']);
const pos = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--invert') continue;
  if (flagsWithVal.has(a)) { i++; continue; }
  if (a.startsWith('--') || a.startsWith('-')) { process.stderr.write(`error: unknown flag ${a}\n`); process.exit(2); }
  pos.push(a);
}
const input = pos[0], output = pos[1];
if (!input) { process.stderr.write('error: no input file\n'); process.exit(2); }

try { await access(resolve(input), FS.R_OK); }
catch { process.stderr.write(`error: input not found: ${input}\n`); process.exit(3); }

// engine + decoder
let traceImage, sharp;
try { ({ traceImage } = await import(pathToFileURL(resolve(HERE, '..', 'assets', 'trace-core.mjs')).href)); }
catch (e) { process.stderr.write(`error: cannot load trace-core.mjs (${e.message})\n`); process.exit(1); }
try { sharp = (await import('sharp')).default; }
catch { process.stderr.write('error: `sharp` is required to decode images.\n  install it:  npm i sharp   (or:  uv tool install --from …)\n  the browser tool needs no dependency — this CLI only needs a pixel decoder.\n'); process.exit(5); }

const superF = Math.max(1, Math.min(8, Number(flag('--super', 2)) || 2));
const opts = {
  mode: flag('--mode', 'color'),
  colors: Number(flag('--colors', 6)),
  smooth: Number(flag('--smooth', 0.5)),
  mergeDist: Number(flag('--merge', 48)),
  despeckle: Number(flag('--despeckle', 4)) * superF * superF,
  cornerDeg: 40, fair: 1, fitErr: 1.5,
  detail: Number(flag('--detail', 0.35)) * superF,   // only used on the non-potrace path
  smoothPx: 1,
  threshold: Number(flag('--threshold', 128)),
  levels: Number(flag('--levels', 4)),
  invert: has('--invert'),
  // field/palette machinery (engine defaults; restated so the CLI config is explicit)
  softField: true, alphaField: true, fringeCull: true, matteAnchor: true, demat: true,
  straightRun: false, runTol: 0.75, fringeAreaRatio: 0.25,
  matteDilate: Math.ceil(3 * superF / 2),            // matte-halo border band scales with supersample
  matteField: true, polarize: true, interiorGuard: true,
  minFlat: Math.round(16 * superF * superF / 4),     // 2x-reference px²
  fieldSharp: 1.0,
  sharpR: Math.max(1, Math.round(2 * superF / 2)),
  minLoop: 0,
  blendVeto: true, isoArea: true,
  // Potrace-style global geometry stage — px-space knobs are specified at the
  // 2x-supersample reference scale and scaled with superF so a different
  // factor behaves identically in native px
  potrace: true,
  tubeTol: 1.0 * superF / 2,
  alphaMax: 1.0,
  cornerBox: 1.0 * superF / 2,
  adjustR: 0.75 * superF / 2,
  chamferMax: 4.5 * superF / 2,
  axisSnap: true, snapDeg: 0.75, snap45Deg: 0.4,
  minSeg: 0.2 * superF / 2,
  optiCurve: true, optTol: 0.2 * superF / 2,
};

const buf = await readFile(resolve(input));
const meta = await sharp(buf).metadata();
const W = Math.max(2, Math.round(meta.width * superF)), H = Math.max(2, Math.round(meta.height * superF));
// libvips lanczos-family upscale (sharp's default kernel) — supersampling stays
// in the caller; the engine only ever sees decoded RGBA pixels.
const { data } = await sharp(buf).resize(W, H, { fit: 'fill' }).ensureAlpha().raw().toBuffer({ resolveWithObject: true });

const t0 = Date.now();
let svg = traceImage({ data, width: W, height: H }, opts);
svg = svg.replace('<svg ', `<svg width="${meta.width}" height="${meta.height}" `);
const paths = (svg.match(/<path/g) || []).length;
process.stderr.write(`traced ${input} (${meta.width}x${meta.height}, ${superF}x) → ${paths} paths, ${svg.length} B in ${Date.now() - t0}ms\n`);

if (output) { await writeFile(resolve(output), svg); process.stderr.write(`wrote ${output}\n`); }
else process.stdout.write(svg + '\n');
