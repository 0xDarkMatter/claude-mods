# Lessons — the session this skill was distilled from

One brand moodboard (Agntik, Evolution 7, 2026-09-05): six live sites captured with
shotcraft, eight user comps, fourteen images composed three ways in one Figma file.
Each entry is a rule in SKILL.md §6 with the incident that earned it. Kept so a
future edit to the rule can check it against the evidence.

## Access and accounts

- **"You don't have edit access"** on both `get_metadata` and `get_screenshot` while
  the file opened fine in the browser. Cause: viewer share. Second cause, minutes later:
  the wrong account entirely — two Figma MCP servers were configured (plugin = one
  org, claude.ai connector = another), and the file lived in the org the plugin
  server could not see. `whoami` on each server settled it in one call.
- Do not consolidate the two servers. A token binds to one account; consolidating
  turns every org switch into an interactive OAuth flow.

## Capture

- Four `header` element crops timed out (`scrollIntoViewIfNeeded`) on two sites.
  A guessed selector, not a tool fault. Inspect markup before naming selectors.
- The shell wrapper reported exit 0; `capture.mjs` had exited 10 (partial failures).
  Read the tool's exit, not the wrapper's.
- The shotcraft hub at its `.lab` URL was a static index dated six weeks earlier.
  New runs were on disk and invisible. Regenerate per-run sheets and the hub after
  every capture; filed as a bug against shotcraft (serve-time regeneration).

## Upload and placement

- All fourteen uploads landed as 400×300 `FILL` frames — including a 2560×16886
  page strip. Dimensions must come from the file header; the frame lies.
- That 16886px strip, squeezed to 210px wide, rendered as an empty outlined box.
  Parked off-board; replaced later by the viewport shot, which is what the
  moodboard had actually cited ("console logs as hero").
- Deleting the strip's *label* removed only the text node; its leader line and dot
  stayed behind as debris. Remove the triplet, or rebuild all captions.
- A dark site on the petrol ground was invisible; diagnostics showed the fill was
  present and correct. A 1px hairline stroke was the fix, not a move.

## Composition rounds

1. **Organic first attempt** — rotations −3°…+2.5°, overlap by feel. Feedback: no
   jaunty angles; aligned; minimal overlap; drop the palette chips.
2. **Column grid** — clean, aligned, zero overlap. Feedback: too rigid; try a plus,
   grouped by similarity, larger toward the centre, some type on its own.
3. **Rigid plus** — axes drawn, vocabulary in the quadrants. Feedback: interesting,
   still rigid; looser; more clustered at the centre.
4. **Loose plus** — axes removed, inner ring overlapping the centre, chrome stripped
   from the centre block. Accepted.

Cost of the arc: ~12 `use_figma` calls that were re-derivations of the same geometry.
Hence `scripts/plan-layout.mjs`.

## Self-inflicted, caught by screenshot or by counts

- Palette heading placed on top of a caption; a note placed over an image. Fixed by
  moving the caption above its image and lifting the block 92px (cleared by 9px —
  verified numerically, not by eye).
- White and Pop swatches landed on the cream part of a comp: white-on-white. Fixed
  by clearing the band above.
- Crop-mark repositioning filtered `width <= 38`; that also matched the 9px footer
  squares and moved them 440px. The returned count (8, not 4) was the tell. Track
  IDs; never select by size.
- `textAlignHorizontal` on an existing node threw "unloaded font". Atomic failure,
  nothing changed; load the font, retry.
- Centre block chrome (stroke, ticks, edge crosshairs, corner metadata) read as a
  broken box once the inner ring overlapped it. Strip it; float the wordmark.

## Hand-back

- Every accepted round was rendered (`get_screenshot` → `curl` → `design/exports/`)
  and *sent* as a file. The description never substituted for the picture.
- Old pages were deleted only when the user pasted their URLs and asked. Current page
  switched to the survivor first; version history noted as the recovery path.
