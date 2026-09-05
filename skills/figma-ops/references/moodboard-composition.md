# Moodboard composition — three patterns, one session

The arrangements below were built in sequence for one brand board (Agntik, Sep 2026)
and each one was the answer to the previous one's feedback. Kept in that order because
the *order* is the lesson: a composition request usually needs two or three rounds,
and knowing the likely next round saves one.

All coordinates are backdrop-relative Figma units. All rotations are 0°.

## Grouping before geometry

Every pattern started from the same sort. Thirteen images, characterised by what they
shared, produced four clusters that later became the arms of the plus:

| Cluster | Shared trait | Members |
|---|---|---|
| Paper / document | cream and bone grounds, ink type, registration marks — print objects | serro wordmark, COLLECTED, FACTORY, DROID |
| Product UI | the actual websites; white, live data | Cloudflare, Agentic Search, Case Studies |
| Pop field | full-bleed orange | OP-1, DROIDS ACTIVE, Brass Hands 04, DEPLOY DROIDS |
| Ink ground | near-black grounds, big display type | Brand Systems, serro field report, ConductorAI hero |

The fourth cluster had two members until the ConductorAI *viewport* shot replaced its
unusable full-page strip — a reminder that a thin cluster is often a capture gap, not a
grouping problem.

## Pattern 1 — column grid ("all elements should be aligned")

Three columns at x = 70 / 833 / 1596, 733 wide, 30 gutters; hero images span two
columns (1496). Every image at true aspect ratio; captions left-aligned to the column
edge 14px below each image; a four-column vocabulary footer sharing the same outer
margins (70 → 2330) so both grids resolve to the same edges.

- What it solved: rotation and collisions from a first "organic" attempt.
- What it lacked: a reason for the order. Ragged column ends read as omissions.
- Keep for: reference sheets, equal-weight items, anything that will be scanned.

## Pattern 2 — rigid plus (axes drawn)

Centre element 1040×1040 at the cross origin; four arms; ring widths stepping ~0.72×
outward (N/S 1040 → 760 → 540 → 380; E/W 1040 → 700 → 480 → 330); 72 gap from the
centre, 56 between rings; two hairline axes behind the arms ending in solid dots with a
mono callout at each terminal; the four vocabulary categories in the four quadrants,
anchored to the centre block's diagonal corners.

- What it solved: meaning. Vertical = medium (paper ↑, screen ↓); horizontal =
  temperature (ink ←, Pop →). The plus is an argument, the images are evidence.
- What it lacked: warmth. Drawn axes + symmetric rings read as a diagram.
- Keep for: decks and rationale documents where the reader needs the structure stated.

## Pattern 3 — loose plus ("more organic, clustered around the centre")

Same grouping, axes removed. Ring 1 overlaps the centre by 40px and is nudged
off-axis (serro left, Cloudflare right, OP-1 up, hero down); ring 2 tucks onto ring 1's
corner by ≤ 250×80; outer pieces stagger ±18% of their width off the axis; the
wordmark floats in the eye with no block chrome; vocabulary moved to the backdrop's
four corners, out of the cluster.

- What it solved: the plus is implied by density, not drawn. Reads as composed.
- The defect it introduced and how it was fixed: the centre block's stroke, ticks and
  corner metadata became fragments once images overlapped it. Stripping the chrome
  and floating the wordmark (196px, 111px clear each side) fixed it in one call.
- Keep for: moodboards, brand boards, anything meant to be *felt* before it is read.

`scripts/plan-layout.mjs --mode loose` reproduces this geometry from the image
dimensions; `assets/plus-layout.example.json` is the exact input.

## Rules that survived all three rounds

1. Group first; geometry second. The arms/columns only work once the groups mean
   something.
2. Zero rotation unless asked. "Organic" was satisfied by offset and overlap.
3. Largest toward the centre, stepping ~0.72× per ring.
4. Overlap budget: ≤ 40px onto the centre, ≤ 250×80 onto a neighbour.
5. A typographic centre beats a borrowed image — the brand at the centre of its
   influences — but strip its chrome the moment images overlap it.
6. Dark images need a hairline stroke on a dark ground or they vanish.
7. The single-accent rule, if the brief has one, is enforced on the board itself:
   one Pop square, not a Pop panel.
8. Screenshot between every structural change; fix collisions before adding chrome.
9. Build each round on a new page; delete the old ones only when told to.
