// check-invariants.mjs — asserts the geometric promises SKILL.md makes about a plan.
// Called by tests/run.sh: `node check-invariants.mjs MODE FIXTURE < plan.json`.
// Prints PASS/FAIL lines to stdout; exit 0 when every check passes, 1 otherwise.
// Lives in its own file (not a heredoc) because a `node -` heredoc cannot also take
// the plan on stdin — the second redirection wins and node executes the JSON.
import { readFileSync } from 'node:fs';

const [, , mode, fixPath] = process.argv;
const plan = JSON.parse(readFileSync(0, 'utf8'));
const fix = JSON.parse(readFileSync(fixPath, 'utf8'));
let fails = 0;
const say = (ok, m) => { console.log(`  ${ok ? 'PASS' : 'FAIL'}  [${mode}] ${m}`); if (!ok) fails++; };

const imgs = plan.placements.filter(p => p.id !== 'centre');
say(imgs.length === fix.images.length, `all ${fix.images.length} images placed`);
say(mode === 'grid' ? !plan.placements.some(p => p.id === 'centre') : plan.placements.some(p => p.id === 'centre'),
  'centre presence matches mode');

// true aspect ratio preserved within rounding
const byId = Object.fromEntries(fix.images.map(i => [i.id, i]));
say(imgs.every(p => Math.abs(p.w / p.h - byId[p.id].w / byId[p.id].h) < 0.01), 'aspect ratios preserved');

// every image inside the canvas margin
const M = 240;
say(imgs.every(p => p.x >= M - 1 && p.y >= M - 1 && p.x + p.w <= plan.canvas.w - M + 1 && p.y + p.h <= plan.canvas.h - M + 1),
  'every image inside the margin');
say(Number.isInteger(plan.canvas.w) && Number.isInteger(plan.canvas.h), 'canvas dims are integers');

if (mode !== 'grid') {
  for (const arm of ['N', 'S', 'E', 'W']) {
    const a = imgs.filter(p => p.arm === arm).sort((x, y) => x.ring - y.ring);
    say(a.every((p, i) => i === 0 || p.w <= a[i - 1].w), `arm ${arm} widths step down toward the edge`);
  }
  const c = plan.placements.find(p => p.id === 'centre');
  const touches = p => Math.min(p.x + p.w, c.x + c.w) - Math.max(p.x, c.x) > 0
                    && Math.min(p.y + p.h, c.y + c.h) - Math.max(p.y, c.y) > 0;
  const ring1 = imgs.filter(p => p.ring === 1);
  say(mode === 'loose' ? ring1.every(touches) : !ring1.some(touches),
    mode === 'loose' ? 'ring 1 overlaps the centre' : 'ring 1 clears the centre');
} else {
  say(plan.overlaps.length === 0, 'grid has zero overlaps');
}
say(plan.overBudget === 0, 'no overlap exceeds the budget');
process.exit(fails ? 1 : 0);
