#!/usr/bin/env node
// verify-board.mjs — check what is actually on the canvas against the plan.
//
// "Screenshot and eyeball" catches what eyes catch. This catches what they don't:
// a frame still at its 400x300 upload size, a node nudged 3px by a later edit, an
// overlapper appended BEFORE the thing it overlaps (z-order inverted), an image
// outside the backdrop, an overlap that crept past budget, a rotation that isn't 0.
// It is the mechanical half of the verify gate in SKILL.md §3 Phase 4.
//
// Input is a read-back of the board, not a live connection: run the read-only
// use_figma script in references/place-and-verify.md, save the returned JSON, and
// pass it here. Offline, deterministic, testable.
//
// Contract: stdout report (JSON with --json, else table); stderr diagnostics.
//   0 clean · 2 usage · 3 bad input · 10 findings (report still emitted)
//
// Read-back shape (what the reference script returns):
//   { "backdrop": { "id": "45:2", "w": 6230, "h": 4605 },
//     "children": [ { "id": "44:4", "name": "…", "index": 3, "x": .., "y": .., "w": .., "h": ..,
//                     "rotation": 0, "hasStroke": true, "type": "FRAME" }, … ] }

import { readFileSync } from 'node:fs';

const HELP = `verify-board.mjs — verify a Figma board read-back against its plan

Usage:
  node verify-board.mjs --plan FILE --board FILE [--tolerance N] [--budget WxH] [--json]

Options:
  --plan FILE        plan-layout.mjs --json output (ids = Figma node ids)
  --board FILE       read-back JSON from the use_figma script ("-" = stdin)
  --tolerance N      px slack for size/position matches   (default: 2)
  --budget WxH       max tolerated image-image overlap    (default: 250x80)
  --require-stroke   flag images with no stroke           (default: on; --no-require-stroke)
  --json             JSON report
  -h, --help

Findings (each is a line in the report):
  missing        planned node not on the backdrop
  size           w/h differ from plan (a 400x300 means resize never happened)
  position       x/y differ from plan beyond tolerance
  rotation       rotation is not 0
  outside        node extends beyond the backdrop
  z-order        an overlapping pair is stacked the wrong way round
  overlap        an image-image overlap exceeds the budget
  stroke         image has no stroke (dark-on-dark risk)
  extra          node on the backdrop that the plan doesn't know (info only)

Exit: 0 clean · 2 usage · 3 bad input · 10 one or more findings

EXAMPLES:
  node verify-board.mjs --plan plan.json --board board-readback.json
  node verify-board.mjs --plan plan.json --board - --json < readback.json | jq '.findings'
`;

function usage(m) { process.stderr.write(`verify-board: ${m}\n\n${HELP}`); process.exit(2); }
function bad(m) { process.stderr.write(`verify-board: ${m}\n`); process.exit(3); }

const o = { plan: null, board: null, tol: 2, budget: { w: 250, h: 80 }, stroke: true, json: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i], v = argv[i + 1];
  switch (a) {
    case '-h': case '--help': process.stdout.write(HELP); process.exit(0);
    case '--plan': o.plan = v; i++; break;
    case '--board': o.board = v; i++; break;
    case '--tolerance': o.tol = Number(v); if (!Number.isFinite(o.tol)) usage('bad --tolerance'); i++; break;
    case '--budget': { const m = /^(\d+)x(\d+)$/.exec(v || ''); if (!m) usage('--budget wants WxH'); o.budget = { w: +m[1], h: +m[2] }; i++; break; }
    case '--require-stroke': o.stroke = true; break;
    case '--no-require-stroke': o.stroke = false; break;
    case '--json': o.json = true; break;
    default: usage(`unknown option ${a}`);
  }
}
if (!o.plan || !o.board) usage('--plan and --board are required');

const read = (p, what) => { try { return JSON.parse(p === '-' ? readFileSync(0, 'utf8') : readFileSync(p, 'utf8')); } catch (e) { bad(`cannot read ${what}: ${e.message}`); } };
const plan = read(o.plan, 'plan'), board = read(o.board, 'board');
if (!Array.isArray(plan.placements)) bad('plan has no placements[]');
if (!board.backdrop || !Array.isArray(board.children)) bad('board read-back needs backdrop{} and children[]');

const findings = [];
const F = (kind, id, detail) => findings.push({ kind, id, detail });
const near = (a, b) => Math.abs(a - b) <= o.tol;
const byId = Object.fromEntries(board.children.map(c => [c.id, c]));
const planned = plan.placements.filter(p => p.id !== 'centre');

for (const p of planned) {
  const c = byId[p.id];
  if (!c) { F('missing', p.id, `${p.name || ''} not on backdrop ${board.backdrop.id}`); continue; }
  if (!near(c.w, p.w) || !near(c.h, p.h)) {
    const hint = Math.round(c.w) === 400 && Math.round(c.h) === 300 ? ' — still the 400x300 upload frame; resize never ran' : '';
    F('size', p.id, `plan ${p.w}x${p.h}, canvas ${Math.round(c.w)}x${Math.round(c.h)}${hint}`);
  }
  if (!near(c.x, p.x) || !near(c.y, p.y)) F('position', p.id, `plan (${p.x},${p.y}), canvas (${Math.round(c.x)},${Math.round(c.y)})`);
  if (Math.abs(c.rotation || 0) > 0.01) F('rotation', p.id, `${c.rotation}° (plan is 0°)`);
  if (c.x < -o.tol || c.y < -o.tol || c.x + c.w > board.backdrop.w + o.tol || c.y + c.h > board.backdrop.h + o.tol) F('outside', p.id, 'extends beyond the backdrop');
  if (o.stroke && c.hasStroke === false) F('stroke', p.id, 'no stroke — invisible if the image is dark on a dark ground');
}

// pairwise overlap + z-order, on canvas geometry
const onCanvas = planned.map(p => byId[p.id] && { p, c: byId[p.id] }).filter(Boolean);
for (let i = 0; i < onCanvas.length; i++) for (let j = i + 1; j < onCanvas.length; j++) {
  const A = onCanvas[i], B = onCanvas[j];
  const w = Math.min(A.c.x + A.c.w, B.c.x + B.c.w) - Math.max(A.c.x, B.c.x);
  const h = Math.min(A.c.y + A.c.h, B.c.y + B.c.h) - Math.max(A.c.y, B.c.y);
  if (w <= 0 || h <= 0) continue;
  if (w > o.budget.w && h > o.budget.h) F('overlap', `${A.p.id}~${B.p.id}`, `${Math.round(w)}x${Math.round(h)} exceeds ${o.budget.w}x${o.budget.h}`);
  // plan order = intended z-order (later on top); canvas index must agree
  const planLater = plan.placements.indexOf(A.p) < plan.placements.indexOf(B.p) ? B : A;
  const planEarlier = planLater === A ? B : A;
  if ((planLater.c.index ?? 0) < (planEarlier.c.index ?? 0)) F('z-order', `${planLater.p.id}`, `should sit on ${planEarlier.p.id} but is behind it`);
}

const plannedIds = new Set(planned.map(p => p.id));
for (const c of board.children) if (!plannedIds.has(c.id) && c.type !== 'TEXT' && c.type !== 'RECTANGLE' && c.type !== 'ELLIPSE') F('extra', c.id, `${c.name || c.type} not in plan (info)`);

const hard = findings.filter(f => f.kind !== 'extra');
const report = { checked: planned.length, findings, hardCount: hard.length };
if (o.json) process.stdout.write(JSON.stringify(report, null, 2) + '\n');
else {
  process.stdout.write(`checked ${planned.length} planned nodes — ${hard.length} finding(s)\n`);
  for (const f of findings) process.stdout.write(`${f.kind.padEnd(9)} ${String(f.id).padEnd(14)} ${f.detail}\n`);
}
process.exit(hard.length ? 10 : 0);
