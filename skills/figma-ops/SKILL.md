---
name: figma-ops
description: "Router and composition workflows for Figma via the official Figma MCP: which Figma skill/tool for which job, capture-to-canvas (screenshots or shotcraft crops into a Figma file), moodboard and reference-board composition (grid, plus, loose-plus arrangements with a deterministic layout planner), canvas craft rules the API skills don't cover, and multi-account routing. Triggers on: figma, moodboard, brand board, reference board, put these screenshots in figma, compose in figma, arrange images in figma, plus arrangement, which figma skill, figma account, upload to figma, delete figma page."
license: MIT
compatibility: "Official Figma MCP server (Claude Code figma plugin) for canvas work; Node 18+ for scripts/plan-layout.mjs; shotcraft optional for live-site capture"
allowed-tools: "Read Write Bash Glob Grep AskUserQuestion"
metadata:
  author: claude-mods
  related-skills: color-ops, icon-ops, frontend-design
---

# Figma Operations

The front door for Figma work. The official Figma plugin ships eleven skills that own
the Plugin API surface; the community ships fifty more for tokens, components, a11y
and docs. **This skill does not replicate any of them.** It does three things they
don't:

1. **Routes** — says which skill or tool to load for a given job (§1).
2. **Composes** — capture → curate → arrange workflows for moodboards, reference
   boards and any "put these images in Figma, beautifully" request (§3–§5).
3. **Guards** — the canvas craft rules that sit *above* the API rules: aspect ratio,
   z-order, overlap budgets, verification loops, page hygiene (§6).

> **Always load `figma-use` before any `use_figma` call.** It is the source of truth
> for the Plugin API and its gotchas. This skill assumes it is loaded and cites its
> references rather than restating them.

## 1. Router — which skill for which job

| The job | Load | Tool it wraps |
|---|---|---|
| Any script that mutates or reads the canvas | `figma-use` (mandatory prerequisite) | `use_figma` |
| Design → code, implement a screen | `figma-design-to-code` (or `get_design_context` guidance) | `get_design_context`, `get_screenshot` |
| Build a page/screen *from* app code | `figma-generate-design` + `figma-use` | `use_figma`, `generate_figma_design` |
| Tokens, variables, component library | `figma-generate-library` + `figma-use` | `use_figma`, `search_design_system` |
| Map components to code | `figma-code-connect` | Code Connect tools |
| New blank file | `figma-create-new-file` | `create_new_file` |
| Mermaid-class diagram in FigJam | `figma-generate-diagram` | `generate_diagram` |
| FigJam board content | `figma-use-figjam` + `figma-use` | `use_figma` |
| Slides deck | `figma-use-slides` + `figma-use` | `use_figma` |
| Motion / animation | `figma-use-motion`, `figma-implement-motion` | `use_figma`, `get_motion_context` |
| Images or SVGs into a file | **this skill §4** | `upload_assets` |
| Moodboard, reference board, composed arrangement | **this skill §3–§5** | `upload_assets` + `use_figma` |
| Live-site captures as source imagery | `shotcraft` → this skill §4 | — |
| Design-token export/import, a11y audits, variable CRUD | community skills — see [references/skill-map.md](references/skill-map.md) | varies |

Two routing rules the tables can't express:

- **A read-only inspection comes first, always.** Pages, existing frames, fonts, naming
  conventions. `figma-use` §9 has the scripts. Never create before you have looked.
- **`get_metadata` needs editor access, not viewer.** "You don't have edit access" on a
  file you can open in the browser means the share is view-only. Ask for editor, or
  check you are on the right account (§2).

## 2. Multi-account routing

One Figma OAuth token binds to exactly one Figma account. If the user belongs to more
than one org (agency + client, personal + work), the correct setup is **one MCP server
per account** — typically the plugin server for one and a claude.ai connector for the
other. They expose separate tool namespaces; pick the account per call by prefix.

- Confirm identity with `whoami` on each server before assuming which file it can see.
- Do **not** consolidate to one server: every account switch would become an interactive
  OAuth re-auth, impossible from a non-interactive session.
- The durable fact is *mechanism → account* (plugin = X, connector = Y). Connector UUIDs
  change on re-add — never key notes on them.
- A View-only team seat fails the same way as a view-only share. `whoami` lists seats.

## 3. Composition workflow — capture → curate → compose

The phases, each with an exit gate. Post a short checklist before each phase and a
summary after (the phase contract in `figma-generate-library` §1 is the model —
visible progress, decisions surfaced, never silently defaulting).

| Phase | Output | Exit gate |
|---|---|---|
| **0 Brief** | Sources list, art direction (2–3 sentences), palette/vocabulary if any, target file + page | User has confirmed the source list; blockers named (attached-not-sent images, login-walled sites) |
| **1 Capture** | Screenshots / section crops / user-supplied images on disk, at true pixel dimensions | Every file exists; dimensions read from the file header, not assumed |
| **2 Curate** | Shortlist with one line per image saying *what it contributes* | **Every image has been looked at by the agent.** Unvetted images never enter a composition |
| **3 Upload** | Nodes in the target file, named after their source files | Node IDs returned and recorded (§7 ledger) |
| **4 Arrange** | Images resized to true aspect ratio and placed per a chosen pattern (§5) | Screenshot reviewed; collisions and defects fixed *before* adding chrome |
| **5 Dress** | Typography, hairlines, marks, labels — only what the brief's vocabulary calls for | Second screenshot; nothing overlaps text; single accent rule honoured if one exists |
| **6 Hand back** | Rendered PNG sent to the user; page name; what was left open | The user sees the render, not just a description of it |

**Hard gates:**

- No `use_figma` mutation before Phase 0's source list is confirmed.
- No image placed before it has been opened and looked at (Phase 2). The gate exists
  because the mistakes that slip through are obvious to eyes and invisible to exit codes.
- No chrome (labels, rules, marks) before the bare arrangement screenshot is clean.
- Build on a **new page**; never restructure the user's existing page in place. Deleting
  the old pages is a separate, explicit request (§6).

## 4. Capture → canvas

**Sources.** Three kinds, in rising order of value for a moodboard:

1. Full-page screenshots — good for scroll strips, bad for boards (a 16,000px strip
   compressed to board width is an unreadable column; use the viewport shot instead).
2. Section crops — the useful unit. `shotcraft`'s `probe-sections.mjs` finds them
   structurally; `capture.mjs` with `elements[]`/`scrollTo` takes targeted ones.
3. Designed comps the user supplies — usually the strongest material; these are the
   aesthetic *executed*, not referenced.

**Upload.** `upload_assets` with `count: N`, then POST each file as `multipart/form-data`
with a `file` field — the filename becomes the layer name, so **rename files to
meaningful slugs before uploading** (`07-ref-collected-system.png`, not `IMG_0997.PNG`).
Record the returned `placedOnNodeId` for every file.

**The 400×300 trap.** Uploaded images land as 400×300 frames with `scaleMode: FILL`,
which *crops*. The frame tells you nothing about the image. Read true dimensions from
the file on disk (PNG: bytes 16–23; JPEG: SOF marker) and `resize()` every frame to its
real aspect ratio at the chosen width before placing it. `scripts/plan-layout.mjs`
takes those dimensions as input.

**Uploads land on whichever page is current for the upload tool** — not necessarily
the page your last script switched to. Find them by ID and `appendChild` them where
they belong.

## 5. Arrangement patterns

Three patterns, in the order a session usually discovers them. Details, coordinates
and the reasoning behind each choice live in
[references/moodboard-composition.md](references/moodboard-composition.md).

| Pattern | When | Character |
|---|---|---|
| **Column grid** | Reference sheet, equal-weight items, "make it aligned" | 3 columns + 2-col spans; every rotation 0; captions left-aligned to column |
| **Rigid plus** | Groups have a *meaning* along each axis (medium ↑↓, temperature ←→) | Four arms from a centre element, ring sizes stepping ~0.72× outward, axes drawn as hairlines with terminal dots |
| **Loose plus** | "Organic", "clustered around the centre", "loosely a plus" | Same grouping, axes *removed*, inner ring overlapping the centre by ~40px and nudged off-axis, second ring tucked onto the inner ring's corners (≤ 250×80), wordmark floating in the eye |

Rules that held across all three:

- **Rotation is opt-in.** Zero degrees unless the user asks for angles; "organic"
  means offset and overlap, not tilt.
- **Group by what images share** — type, aesthetic, or colour — and let the axes
  *mean* something. A plus with arbitrary arms is just a cross.
- **Sizes step toward the centre.** Largest adjacent to the centre, ~0.72× per ring.
- **Overlap has a budget.** Inner ring onto centre ≤ 40px; neighbour corners
  ≤ 250×80. The planner reports every overlap and exits 10 when one exceeds budget.
- **A centre element is allowed to be typographic.** The brand at the centre of its
  influences reads better than a borrowed image there — but once images overlap it,
  strip its chrome (strokes, ticks, metadata) or it reads as a broken box.
- **Vocabulary in the quadrants or corners, never in the cluster.**

Plan coordinates with the script rather than by hand:

```bash
node scripts/plan-layout.mjs --input assets/plus-layout.example.json --mode loose --json
```

It emits backdrop-relative `{id, x, y, w, h}` placements, canvas size, and an
overlap report — paste the placements into one `use_figma` loop.

## 6. Canvas craft rules (above the API)

Learned the expensive way; each one cost a round-trip this skill now saves.

- **Hairline stroke on every dark image.** A dark site on a dark ground disappears; a
  1px `SOFT` 45–55% stroke, `strokeAlign: OUTSIDE`, defines the edge. Check `fills`
  before concluding an image "didn't render".
- **Z-order is append order.** Anything that overlaps must be appended *after* what it
  sits on. Send axis lines to the back with `insertChild(0, …)`.
- **Font style names are per-family, verify them.** Inter uses `"Semi Bold"`; Archivo
  uses `"SemiBold"`. `listAvailableFontsAsync()` first, always.
- **Load fonts before *any* text property**, including `textAlignHorizontal` on an
  existing node. Scripts are atomic — a font error means nothing ran, so fix and
  retry safely (`figma-use` gotchas: canonical text-edit recipe).
- **Never filter nodes by size to find your marks.** `width <= 38` also matched the
  9px footer squares and moved them 440px. Track IDs; filter by name or ID.
- **Deleting a label deletes only the text.** Its leader line and dot stay. Remove
  the whole triplet, or rebuild all captions after a re-layout rather than nudging.
- **Screenshot after every structural change.** `get_screenshot` on the board node at
  `maxDimension` 1400–1800; look for collisions, stranded chrome, illegible items.
  Node-level screenshots (`contentsOnly`) are for detail, not verification.
- **Renders go to the user.** `curl` the screenshot URL to `design/exports/` and send
  the file; a description of a board is not a board.
- **Page deletion is explicit and last.** Switch `currentPage` to the survivor first
  (you cannot remove the current page), clone-don't-move when building alternatives,
  and remind the user that version history holds the deleted pages.

## 7. State ledger for long builds

Context gets summarised mid-build. Keep a ledger on disk from Phase 3 onward:

```json
{ "file": "<fileKey>", "page": "44:3", "backdrop": "45:2",
  "images": { "07-ref-collected-system": "44:5" },
  "chrome": { "captions": ["38:2","38:3"], "vocab": ["47:2"] },
  "exports": ["design/exports/board-v3.png"] }
```

Re-read it at the start of every turn; reconstruct by name (`page.query('FRAME[name^=07-]')`)
if it is missing. Idempotency is by node name — never re-upload an image whose name
already exists on the page.

## 8. Decision forks — ask, don't default

Ask when two arrangements are both defensible and the brief doesn't decide; present
each with its cost. Do **not** ask about things the source decides (an image's aspect
ratio, whether a dark image needs a stroke). Rejected work is never built on — if the
user says "not jaunty angles", every rotation goes to zero before the next screenshot,
not just the new ones.

## References

- [references/moodboard-composition.md](references/moodboard-composition.md) — the three
  patterns with coordinates, grouping logic, and what each round taught.
- [references/capture-to-canvas.md](references/capture-to-canvas.md) — shotcraft →
  upload → true-AR placement, end to end, with the dimension reader.
- [references/skill-map.md](references/skill-map.md) — the official + community Figma
  skill landscape and what this skill deliberately leaves to them.
- [references/lessons.md](references/lessons.md) — the session log this skill was
  distilled from, kept as evidence for the rules in §6.
- `scripts/plan-layout.mjs` — deterministic layout planner (grid / plus / loose).
- `assets/plus-layout.example.json` — a real 14-image fixture; also the test input.
