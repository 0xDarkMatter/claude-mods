# Capture → canvas, end to end

The mechanical half of the composition workflow: getting source imagery from the web
(or from the user's folder) into a Figma file as correctly-sized frames with sensible
layer names. Everything here is deterministic; the taste lives in
[moodboard-composition.md](moodboard-composition.md).

## 1. Capture (shotcraft, or the user's own images)

For live sites, `shotcraft` is the capture tool. Its three modes map onto what a
board needs:

| Mode | Script | Use for |
|---|---|---|
| Probe | `probe-site.mjs --url U --json` | Bot-wall detection (exit 8 → headed Chrome via `SHOTCRAFT_LAUNCH`) and page-set suggestion |
| Sections | `probe-sections.mjs --url U --out DIR --top 7` | Structural section crops, ranked — the useful unit for boards |
| Targeted | `capture.mjs --config C` with `elements[]`, `scrollTo`, `colorScheme` | Nav lockups, hero at viewport, dark-mode variants, mid-page moments |

Two capture lessons:

- **Element selectors are guesses until you have looked at the markup.** `"header"`
  timed out on two of six sites (sticky/zero-height). Inspect, then select.
- **Full-page strips are for showreels, not boards.** A 2560×16886 page at 210px wide
  is a black column. Use the `--viewport` shot for the hero.

Regenerate the shotcraft viewer (`contact-sheet.mjs --dir RUN` per run, then `--hub`
over the library root) or the new runs will not appear in it — the hub is a static
generated index.

## 2. Vet by eye

Open every image before it goes near the canvas. The user's supplied comps are often
the strongest material and the least described ("images attached" turned out to be
eight designed brand comps, not the robot photos the captions implied). Write one line
per image saying what it contributes — that line becomes its caption later.

## 3–4. Stage: slugs + true dimensions in one step

`scripts/stage-assets.mjs` does both jobs the old way did by hand:

```bash
node scripts/stage-assets.mjs --list shortlist.txt --dir E:/refs --out ./staged --json
#  → exit 10: every image listed with w/h and flags [needs-subject] / [needs-arm]
```

Look at the flagged images (Phase 2 — you were going to anyway), then supply the
two human decisions as small JSON maps and re-run for exit 0:

```bash
echo '{"IMG_0997.PNG":"collected system","IMG_0998.PNG":"serro field report"}' > names.json
echo '{"07-ref-collected-system":"N","08-ref-serro-field-report":"W"}'         > arms.json
node scripts/stage-assets.mjs --list shortlist.txt --dir E:/refs --out ./staged \
  --names names.json --arms arms.json --json > board.json
```

What it guarantees: originals untouched; copies named `NN-<source>-<subject>.<ext>`
(the `NN` keeps upload order == layer order; shotcraft filenames are parsed into
`<domain>-<page>`); dimensions read from the PNG/JPEG/GIF header, never from the
upload frame; `board.json` is valid `plan-layout.mjs` input as-is (`id` is the slug
until upload assigns a node ID — overwrite it then).

If you need the header logic elsewhere: PNG width/height are big-endian uint32 at
bytes 16 and 20; JPEG walks markers to the first SOFn (`C0`–`CF` except `C4/C8/CC`),
height then width; GIF is little-endian uint16 at 6 and 8.

## 5. Upload

1. `upload_assets({ fileKey, count: N })` → N single-use `submitUrl`s (10-minute expiry).
2. POST each file: `curl -F "file=@path" "$url"` (multipart, `file` field).
3. Record `placedOnNodeId` per file in the ledger. Uploads land on whichever page is
   current for the upload tool; find by ID and reparent.

Limits: 10 MB per asset, 60 URLs per call. SVGs import as vector trees (no fill
semantics).

## 6. Resize to true aspect ratio, then place

Every uploaded frame is 400×300 with `scaleMode: FILL`. One `use_figma` loop:
`appendChild(parent)` → `rotation = 0` → `resize(w, h)` from the planner → `x, y` →
hairline stroke. Append order is z-order; the planner's placement order already puts
overlappers after what they overlap.

## 7. Verify

`get_screenshot` on the backdrop node (`maxDimension` 1400–1800). Look for: images
invisible against the ground (dark on dark — add stroke), frames still 400×300
(resize missed), overlaps beyond budget, anything the planner reported. Fix, then
dress with captions and marks.
