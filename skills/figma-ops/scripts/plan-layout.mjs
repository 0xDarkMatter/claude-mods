#!/usr/bin/env node
// plan-layout.mjs — deterministic arrangement planner for Figma reference boards.
//
// Takes a list of images with TRUE pixel dimensions and an arm assignment, and emits
// backdrop-relative placements {id, x, y, w, h} for one of three patterns:
//   grid   — 3-column editorial grid, no rotation, heights from aspect ratio
//   plus   — rigid cross: four arms from a centre block, ring sizes stepping outward
//   loose  — the plus with axes implied: inner ring overlaps the centre, off-axis
//            nudges, second ring tucked onto the inner ring's corners
//
// Why a script and not hand-placed coordinates: every round of a composition session
// re-derives the same arithmetic (ring widths, aspect heights, gaps, margins, overlap
// checks). Doing it by hand cost three collisions in the session this was distilled
// from. The planner makes the arrangement reproducible and reports every overlap so
// the agent fixes the layout before it touches the canvas.
//
// Contract (SKILL-RESOURCE-PROTOCOL): stdout is data only (JSON with --json, else a
// terse table); diagnostics go to stderr; exit codes are semantic:
//   0  planned, all overlaps within budget
//   2  usage error
//   3  bad input (missing dims, unknown arm, unreadable file)
//  10  planned, but at least one overlap exceeds the budget (output still emitted)
//
// Input JSON shape (see assets/plus-layout.example.json):
//   { "centre": { "w": 1040, "h": 1040 },
//     "images": [ { "id": "44:4", "name": "serro-wordmark", "w": 2560, "h": 1491,
//                   "arm": "N", "ring": 1 }, ... ] }
//   arm ∈ N|S|E|W (plus/loose) — ignored by grid. ring is optional; defaults to the
//   order of appearance within the arm.

import { readFileSync } from 'node:fs';

const HELP = `plan-layout.mjs — arrangement planner for Figma reference boards

Usage:
  node plan-layout.mjs --input FILE [--mode grid|plus|loose] [options] [--json]

Options:
  --input FILE        JSON with { centre, images[] } (required; "-" reads stdin)
  --mode MODE         grid | plus | loose            (default: loose)
  --ring-v LIST       N/S ring widths, comma list    (default: 1040,760,540,380)
  --ring-h LIST       E/W ring widths, comma list    (default: 1040,700,480,330)
  --gap N             gap between rings              (default: 56)
  --centre-gap N      gap centre -> ring 1 (plus)    (default: 72)
  --overlap N         ring 1 onto centre (loose)     (default: 40)
  --tuck N            ring 2 pulls back onto ring 1  (default: 130; depth = tuck - gap)
  --corner N          cross-axis overlap width kept  (default: 200; the "corner")
  --nudge N           off-axis nudge, ring 1 (loose) (default: 120)
  --margin N          backdrop margin                (default: 240)
  --columns N         grid columns                   (default: 3)
  --col-width N       grid column width              (default: 733)
  --budget WxH        max tolerated overlap          (default: 250x80)
  --json              emit JSON (default: table)
  -h, --help          this text

Exit codes: 0 ok · 2 usage · 3 bad input · 10 overlap over budget

EXAMPLES:
  node plan-layout.mjs --input assets/plus-layout.example.json --json
  node plan-layout.mjs --input board.json --mode grid --col-width 700
  cat board.json | node plan-layout.mjs --input - --mode plus --json | jq '.placements'
`;

// === ARGS ===================================================================
function parseArgs(argv) {
  const o = { mode: 'loose', ringV: [1040, 760, 540, 380], ringH: [1040, 700, 480, 330],
    gap: 56, centreGap: 72, overlap: 40, tuck: 130, corner: 200, nudge: 120, margin: 240,
    columns: 3, colWidth: 733, budget: { w: 250, h: 80 }, json: false, input: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = argv[i + 1];
    const num = () => { const n = Number(v); if (!Number.isFinite(n)) usage(`bad number for ${a}`); i++; return n; };
    switch (a) {
      case '-h': case '--help': process.stdout.write(HELP); process.exit(0);
      case '--input': o.input = v; i++; break;
      case '--mode': o.mode = v; i++; break;
      case '--ring-v': o.ringV = v.split(',').map(Number); i++; break;
      case '--ring-h': o.ringH = v.split(',').map(Number); i++; break;
      case '--gap': o.gap = num(); break;
      case '--centre-gap': o.centreGap = num(); break;
      case '--overlap': o.overlap = num(); break;
      case '--tuck': o.tuck = num(); break;
      case '--corner': o.corner = num(); break;
      case '--nudge': o.nudge = num(); break;
      case '--margin': o.margin = num(); break;
      case '--columns': o.columns = num(); break;
      case '--col-width': o.colWidth = num(); break;
      case '--budget': { const m = /^(\d+)x(\d+)$/.exec(v || ''); if (!m) usage('--budget wants WxH'); o.budget = { w: +m[1], h: +m[2] }; i++; break; }
      case '--json': o.json = true; break;
      default: usage(`unknown option ${a}`);
    }
  }
  if (!o.input) usage('--input is required');
  if (!['grid', 'plus', 'loose'].includes(o.mode)) usage(`unknown mode ${o.mode}`);
  return o;
}
function usage(msg) { process.stderr.write(`plan-layout: ${msg}\n\n${HELP}`); process.exit(2); }
function bad(msg) { process.stderr.write(`plan-layout: ${msg}\n`); process.exit(3); }

// === INPUT ==================================================================
function loadInput(path) {
  let raw;
  try { raw = path === '-' ? readFileSync(0, 'utf8') : readFileSync(path, 'utf8'); }
  catch (e) { bad(`cannot read ${path}: ${e.message}`); }
  let data;
  try { data = JSON.parse(raw); } catch (e) { bad(`invalid JSON: ${e.message}`); }
  if (!Array.isArray(data.images) || data.images.length === 0) bad('images[] is required');
  data.images.forEach((im, i) => {
    // Before upload there is no Figma node ID; the staging slug (name) is the identity.
    im.id = im.id || im.name;
    if (!im.id) bad(`images[${i}] needs an id or a name`);
    if (!(im.w > 0 && im.h > 0)) bad(`images[${i}] (${im.id}) needs true w and h`);
  });
  data.centre = data.centre || { w: 1040, h: 1040 };
  return data;
}

// === GEOMETRY ===============================================================
const ar = im => im.w / im.h;
const fitW = (im, w) => ({ w, h: Math.round(w / ar(im)) });

function byArm(images) {
  const arms = { N: [], S: [], E: [], W: [] };
  for (const im of images) {
    const a = (im.arm || '').toUpperCase();
    if (!arms[a]) bad(`image ${im.id} has unknown arm "${im.arm}" (want N|S|E|W)`);
    arms[a].push(im);
  }
  for (const k of Object.keys(arms)) {
    arms[k].sort((a, b) => (a.ring ?? Infinity) - (b.ring ?? Infinity));
    arms[k].forEach((im, i) => { im.ring = i + 1; });
  }
  return arms;
}

// Plus / loose share one walk: along-axis distance accumulates ring by ring.
// In loose mode, ring 1 pulls INTO the centre by `overlap` and shifts off-axis by
// `nudge` (alternating sign per arm so the four nudges don't all lean the same way);
// ring 2 pulls back by `tuck` so it lands on ring 1's corner; rings alternate a
// lateral stagger of ±18% of their own width to break the axis line.
function planPlus(data, o, loose) {
  const arms = byArm(data.images);
  const C = data.centre;
  const half = { x: C.w / 2, y: C.h / 2 };
  const out = [];
  const dir = { N: [0, -1], S: [0, 1], E: [1, 0], W: [-1, 0] };
  const nudgeSign = { N: -1, S: 1, E: -1, W: 1 };

  for (const arm of ['N', 'S', 'E', 'W']) {
    const [dx, dy] = dir[arm];
    const vertical = dx === 0;
    const rings = vertical ? o.ringV : o.ringH;
    let along = (vertical ? half.y : half.x) + (loose ? -o.overlap : o.centreGap);
    let prevCross = null, prevLateral = 0;      // cross-axis size + offset of the previous ring
    arms[arm].forEach((im, i) => {
      const width = rings[Math.min(i, rings.length - 1)];
      const { w, h } = fitW(im, width);
      const extent = vertical ? h : w;          // size along the axis
      const cross  = vertical ? w : h;          // size across the axis
      if (loose && i === 1) along -= o.tuck;    // tuck ring 2 onto ring 1's corner
      let lateral = 0;
      if (loose) {
        if (i === 0) lateral = nudgeSign[arm] * o.nudge;
        else {
          // Land on the previous ring's CORNER, not centred on it: shift so exactly
          // `corner` px of cross-axis overlap remain. Alternate sides for a zig-zag.
          const side = (i % 2 === 0 ? -1 : 1) * nudgeSign[arm];
          lateral = prevLateral + side * Math.round(prevCross / 2 + cross / 2 - o.corner);
        }
      }
      prevCross = cross; prevLateral = lateral;
      // centre of this image along the axis:
      const c = along + extent / 2;
      const cx = vertical ? lateral : dx * c;
      const cy = vertical ? dy * c : lateral;
      out.push({ id: im.id, name: im.name, arm, ring: i + 1, x: cx - w / 2, y: cy - h / 2, w, h });
      along += extent + o.gap;
    });
  }
  out.push({ id: 'centre', name: 'centre', arm: 'C', ring: 0, x: -half.x, y: -half.y, w: C.w, h: C.h });
  return out;
}

function planGrid(data, o) {
  const gutter = 30;
  const colX = i => o.margin + i * (o.colWidth + gutter);
  const bottoms = new Array(o.columns).fill(o.margin);
  const out = [];
  for (const im of data.images) {
    const span = im.span === 2 ? 2 : 1;
    const width = span === 2 ? o.colWidth * 2 + gutter : o.colWidth;
    const { w, h } = fitW(im, width);
    // place in the shortest column that can hold the span
    let best = 0, bestY = Infinity;
    for (let c = 0; c + span <= o.columns; c++) {
      const y = Math.max(...bottoms.slice(c, c + span));
      if (y < bestY) { bestY = y; best = c; }
    }
    out.push({ id: im.id, name: im.name, arm: 'G', ring: best, x: colX(best), y: bestY, w, h });
    for (let c = best; c < best + span; c++) bottoms[c] = bestY + h + 60; // 60 = caption room
  }
  return out;
}

// === POST ===================================================================
function normalise(placements, margin) {
  const minX = Math.min(...placements.map(p => p.x));
  const minY = Math.min(...placements.map(p => p.y));
  const maxX = Math.max(...placements.map(p => p.x + p.w));
  const maxY = Math.max(...placements.map(p => p.y + p.h));
  const ox = margin - minX, oy = margin - minY;
  for (const p of placements) { p.x = Math.round(p.x + ox); p.y = Math.round(p.y + oy); }
  return { w: Math.round(maxX - minX + 2 * margin), h: Math.round(maxY - minY + 2 * margin), origin: { x: Math.round(ox), y: Math.round(oy) } };
}

function overlaps(placements, budget) {
  const list = [];
  for (let i = 0; i < placements.length; i++) for (let j = i + 1; j < placements.length; j++) {
    const a = placements[i], b = placements[j];
    const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
    if (w > 0 && h > 0) {
      const centre = a.id === 'centre' || b.id === 'centre';
      // centre overlaps are intentional in loose mode; judge them by depth, not area
      const over = centre ? false : (w > budget.w && h > budget.h);
      list.push({ a: a.id, b: b.id, w, h, overBudget: over });
    }
  }
  return list;
}

// === MAIN ===================================================================
const o = parseArgs(process.argv.slice(2));
const data = loadInput(o.input);
const placements = o.mode === 'grid' ? planGrid(data, o) : planPlus(data, o, o.mode === 'loose');
const canvas = o.mode === 'grid'
  ? { w: o.margin * 2 + o.columns * o.colWidth + (o.columns - 1) * 30, h: Math.max(...placements.map(p => p.y + p.h)) + o.margin, origin: { x: 0, y: 0 } }
  : normalise(placements, o.margin);
const ov = overlaps(placements, o.budget);
const exceeded = ov.filter(x => x.overBudget);
const result = { mode: o.mode, canvas, placements, overlaps: ov, overBudget: exceeded.length };

if (o.json) process.stdout.write(JSON.stringify(result, null, 2) + '\n');
else {
  process.stdout.write(`mode ${o.mode}  canvas ${canvas.w}x${canvas.h}\n`);
  for (const p of placements) process.stdout.write(`${String(p.arm).padEnd(2)} r${p.ring} ${String(p.id).padEnd(10)} ${String(p.x).padStart(6)} ${String(p.y).padStart(6)} ${String(p.w).padStart(5)}x${String(p.h).padEnd(5)} ${p.name || ''}\n`);
  for (const x of ov) process.stdout.write(`overlap ${x.a} ~ ${x.b}  ${x.w}x${x.h}${x.overBudget ? '  OVER BUDGET' : ''}\n`);
}
if (exceeded.length) { process.stderr.write(`plan-layout: ${exceeded.length} overlap(s) exceed ${o.budget.w}x${o.budget.h}\n`); process.exit(10); }
