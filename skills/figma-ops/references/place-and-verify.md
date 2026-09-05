# Place and verify — the last mile, generated and checked

Everything between "I have a plan" and "the board is right" used to be hand-typed.
Now it is three scripts and two `use_figma` calls, and the canvas is checked
against the plan by a program rather than by squinting.

```
board.json ──plan-layout──▶ plan.json ──emit-placement──▶ use_figma (backdrop)
                                          │                      │
                                          └──emit-placement──▶ use_figma (place)
                                                                 │
                              read-back script (below) ──▶ readback.json
                                                                 │
                                       verify-board ◀────────────┘  → exit 0 or findings
```

## 1. Fill in node IDs after upload

`plan.json` carries slugs as `id` until upload. After `upload_assets`, overwrite each
`id` with the returned `placedOnNodeId`, and set `vetted: true` on every image you
have actually opened and looked at. A one-liner with `jq` or a short node script —
the point is that the plan file, not the conversation, is where these facts live.

## 2. Backdrop

```bash
node scripts/emit-placement.mjs --plan plan.json --phase backdrop --page "Moodboard — Plus" --fill 002D3C
```

Paste the output into `use_figma` (with `figma-use` loaded). It creates or reuses
the page, creates the backdrop at the plan's canvas size, and returns
`{ pageId, backdropId }`.

## 3. Place

```bash
node scripts/emit-placement.mjs --plan plan.json --phase place --backdrop 45:2 --captions
```

Paste into `use_figma`. The generated loop appends each image to the backdrop **in
plan order (= z-order)**, zeroes rotation, resizes to the plan's true-aspect size,
positions, strokes, and — with `--captions` — drops a mono caption under any image
whose plan entry has a `caption`. It refuses to run if any image is `vetted: false`
(exit 10 at generation time) unless you pass `--allow-unvetted`.

## 4. Read the board back

Run this read-only script in `use_figma`, save the returned JSON as `readback.json`:

```js
// figma-ops read-back — no mutations. BACKDROP_ID from the backdrop phase.
const BACKDROP_ID = "45:2";
const page = figma.root.children.find(p => p.name === "Moodboard — Plus");
await figma.setCurrentPageAsync(page);
const bg = await figma.getNodeByIdAsync(BACKDROP_ID);
const children = bg.children.map((n, index) => ({
  id: n.id, name: n.name, type: n.type, index,
  x: n.x, y: n.y, w: n.width, h: n.height, rotation: n.rotation,
  hasStroke: Array.isArray(n.strokes) && n.strokes.length > 0
}));
return { backdrop: { id: bg.id, w: bg.width, h: bg.height }, children };
```

`index` is the child's position in the backdrop — the canvas's actual z-order.

## 5. Verify

```bash
node scripts/verify-board.mjs --plan plan.json --board readback.json
```

Exit 0 means every planned node is present, at plan size (±2px), at plan position,
unrotated, inside the backdrop, stroked, with overlaps inside budget and stacking
in plan order. Exit 10 lists what is wrong, one finding per line, with the fix
implied by the kind:

| Finding | Usually means | Fix |
|---|---|---|
| `size … still the 400x300 upload frame` | the place loop never ran for that node, or ran before the resize | re-run place for that id |
| `position` | a later edit nudged it | re-run place, or update the plan if the nudge was intentional |
| `z-order` | overlapper appended before its base | re-run place (plan order is z-order) |
| `overlap` | manual moves broke the budget | re-plan with tighter `--corner`/`--tuck`, or accept and update `--budget` |
| `stroke` | image added outside the emitter | add the hairline |
| `missing` | wrong page, or the node was deleted | check `page`, re-upload |

Then — and only then — `get_screenshot` for the things a program can't judge.

## Why this shape

The session that produced this skill had two defects the eye missed and a program
would not have: fourteen frames sitting at 400×300 (spotted only because a
diagnostic call returned the numbers), and four 9px squares displaced 440px by a
size-based filter (spotted because a returned count was 8 where 4 was expected).
Both are one-line findings from `verify-board`. The screenshot still matters — it is
the only judge of whether the board is *good* — but it should be the last check,
not the first.
