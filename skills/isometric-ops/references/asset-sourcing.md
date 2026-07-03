# Asset Sourcing — licences, libraries, and the procurement rule

Where to get isometric assets you didn't draw yourself: free/CC0 game-art packs, icon and
illustration marketplaces, and the licence discipline that keeps a sourced asset from
becoming a legal liability at client delivery. This file is about **acquiring** existing
assets. For building your own from scratch, see `svg-vector-generation.md` (hand-rolled
SVG/vector), `pixel-art-workflow.md` (sprites), `ai-generation.md` (generative pipelines),
and `blender-prerender.md` (pre-rendered 3D). For the visual discipline sourced or
generated assets must still conform to, see `style-guide.md`.

Projection note: most "isometric" packs below are actually **2:1 dimetric (commonly
called isometric in games)** — see `projection-math.md` for the distinction. Check a
pack's tile geometry (2:1 aspect, e.g. 128×64) before mixing it with true-iso vector work.

## The procurement rule (read this before downloading anything)

For every asset you plan to ship — especially from a marketplace or subscription library —
check three things, in order, **before client delivery**:

1. **Current plan.** Marketplaces mix free, subscription, and seller-specific rights inside
   the same site. What was free last quarter may now be a paid-tier asset, or vice versa.
2. **Current licence.** Read the licence page itself, not a blog summary — attribution
   requirements, redistribution/resale limits, and "unlimited use" caveats vary pack-to-pack
   even within one vendor.
3. **The AI-training clause.** This is the layer most teams miss. **"Commercial use
   permitted" does not imply "dataset use permitted."** Some vendors explicitly forbid using
   their assets to train, fine-tune, or improve AI/ML models even while allowing normal
   commercial use in shipped products. DrawKit is the documented example: its licence
   explicitly forbids using DrawKit icons and illustrations to train, fine-tune, or improve
   AI/ML models, while otherwise permitting commercial use with unlimited copies and no
   attribution ([drawkit.com/license](https://www.drawkit.com/license)). Treat any
   AI-training-adjacent use (dataset curation, LoRA training references, style-transfer
   corpora) as a separate rights question from "can I ship this in a product."

Pricing, plan tiers, and licence text change without notice — treat every vendor's own
licence page as the source of truth at the moment of use, not this document, not a cached
summary, and not a review blog.

## CC0-first: free game-art tile and prop packs

Prefer these before reaching for a paid marketplace — CC0 means no attribution, no
licence-check step, and no AI-training ambiguity (public domain dedication has no training
clause to violate).

| Source | What's there | Licence | Notes |
|---|---|---|---|
| **Kenney.nl** ([kenney.nl](https://kenney.nl/assets?q=isometric)) | Isometric Prototypes Tiles (50+), Isometric Dungeon Tiles (70+), Isometric Library Tiles (30+), Isometric Blocks (130+), Isometric Landscape (128 assets), Isometric Miniature Bases, Isometric City | **CC0** | The gold standard for CC0 game art. Packs ship with Unity + Tiled sample projects — the fastest path from download to engine. No attribution needed, but a credit is appreciated practice. |
| **itch.io** ([itch.io](https://itch.io), tag: isometric) | Screaming Brain Studios: 1,008 Isometric Floor Tiles, 443 Town/Roof Tiles, 1,872 Wall Tiles. Also: DevilsWork.shop, dani maccari "Tiny Blocks," MarkGosbell "50+ Hand Drawn Isometric Dungeon Assets," "Mushy — neural-network-generated isometric tiles" | **CC0** (per-pack — verify each listing) | Deepest CC0 catalog by raw tile count. itch.io licences are set per-creator per-listing, not platform-wide — check each pack's page even though the ecosystem trends CC0. |
| **OpenGameArt** ([opengameart.org](https://opengameart.org)) | Isometric City (mirrors Kenney's set), plus many community tilesets | Mixed — **CC0, CC-BY, CC-BY-SA** all present | Filter by licence on every search; OpenGameArt hosts multiple licence families side by side, unlike Kenney's blanket CC0. |

## Icon and illustration marketplaces (paid + freemium)

These trade CC0 simplicity for volume, consistency, and format breadth (SVG/PNG/EPS/AI/
Lottie/3D). All require the procurement rule above before shipping.

| Library | What it's for | Formats | Licence shape | Recommended use |
|---|---|---|---|---|
| **IconScout** ([iconscout.com/icons/isometric](https://iconscout.com/icons/isometric)) | Large free+premium isometric icon and illustration sets; brand recolouring | SVG, PNG, EPS, AI, PDF, 3D, Lottie | Free tier + paid individual/team plans; read [iconscout.com/licenses](https://iconscout.com/licenses) per-asset — IconScout mixes free, subscription, and seller-specific rights in one catalog | Wide-format needs (Lottie/3D alongside vector); Figma/XD/Sketch plugin workflows |
| **Flaticon** ([flaticon.com/free-icons/isometric](https://flaticon.com/free-icons/isometric)) | Large isometric icon catalog (tens of thousands of icons) | SVG, PSD, PNG, EPS, icon font | Free **with attribution**; premium licence (via Flaticon/Freepik) removes the attribution requirement | Fast icon fills where attribution is acceptable, or budget covers the premium tier |
| **Icons8** ([icons8.com](https://icons8.com)) | Systematically organized isometric icon families | SVG, PNG; Pichon desktop app for offline access | Free tier + subscription; API + Figma/Sketch/Adobe plugins | Teams wanting a consistent family across a large icon surface, with offline/API tooling |
| **Streamline** ([streamlinehq.com](https://streamlinehq.com)) | Massive, highly consistent isometric icon/illustration systems | SVG, PNG, Figma | Premium subscription | Design systems needing hundreds of icons in one consistent hand |
| **Iconify** ([icon-sets.iconify.design](https://icon-sets.iconify.design)) | Open-source icon aggregator/framework spanning many icon sets | SVG, framework components (React/Vue/Svelte) | Aggregates icon sets with **their own individual licences** — check the specific set, not "Iconify" as a blanket licence | The developer-friendly way to pull SVG icons programmatically (npm package per icon set, tree-shakeable) |
| **DrawKit** ([drawkit.com](https://drawkit.com)) | Curated 2D & 3D illustration and icon packs, including isometric-themed sets (e.g. "Isotopia") | SVG, PNG, Figma | Free + Pro packs; commercial use permitted under the DrawKit Licence, no attribution required — **but AI-training explicitly forbidden**, see licence page | Polished, curated illustration where volume matters less than hand-consistency |
| **Blush** ([blush.design](https://blush.design)) | Character-led, customisable illustration compositions (mix-and-match) | SVG, Figma/Sketch plugin | Free + Pro; commercial use allowed with unlimited copies, no attribution | Onboarding art, editorial scenes composed live inside a design tool |
| **Storyset** ([storyset.com](https://storyset.com)) | Free customisable illustration library (Freepik/Flaticon ecosystem) | SVG, web-based colour customiser | Free with attribution; premium via Flaticon removes attribution | Quick blog/marketing fills, budget-conscious editorial illustration |
| **Icograms** ([icograms.com](https://icograms.com)) | Purpose-built isometric diagram/map editor with a large built-in icon+template library (1,000+ icons, thousands of templates per vendor) | Browser editor; SVG/PNG export | Free to try; paid individual plans (roughly $19–34/mo at time of writing, verify current pricing) | Isometric maps, campus plans, logistics diagrams, network/infra diagrams — the map/diagram problem specifically, not general illustration |

Dated note: pricing figures above (IconScout tiers, Icograms $19–34/mo) are **as of July
2026** and vendor pricing shifts without notice — always confirm on the vendor's own
pricing page before quoting a client.

## Cloud-architecture diagram tools (adjacent, worth knowing)

Not "asset libraries" in the sprite-sheet sense, but they ship their own maintained
isometric icon sets (AWS/Azure/GCP/Kubernetes) and are the fastest path for infra diagrams
specifically:

- **Isoflow** ([isoflow.io](https://isoflow.io)) — open-source native isometric diagramming, drag-and-drop, free with a premium tier.
- **FossFLOW** — fully open-source (Unlicense), built on the Isoflow library, adds JSON export/import.
- **Cloudcraft** ([cloudcraft.co](https://cloudcraft.co)) — live-connected AWS/Azure architecture diagrams with cost overlays; free tier then paid.
- **Holori** — multi-cloud (AWS/Azure/GCP/OCI/OVH/Scaleway/DigitalOcean), imports from Terraform/AWS console/GitHub.

## Attribution tracking practice

When a sourced pack requires attribution (Flaticon free tier, Storyset free tier, some
itch.io listings), track it the same way you'd track a software dependency, not as an
afterthought in a README nobody reads:

- Keep a single `CREDITS.md` (or equivalent) per project, one line per pack: **source,
  licence, attribution text required, URL to the exact licence page you checked, and the
  date you checked it.** Licence terms drift; the date matters.
- If an asset later gets swapped for a CC0 or in-house replacement, keep the credit line
  until the asset is fully gone from every shipped build, not just the working file.
- For AI-training-restricted assets (DrawKit and similar), add an explicit note in the same
  file — "not for dataset/training use" — so a future teammate building an in-house LoRA
  doesn't accidentally violate the source licence months later.

## Prefer SVG source over PNG

When a library offers both, take the SVG. Reasons specific to isometric work:

- **Re-coloring for the three-tone plane system** (`style-guide.md`) requires editable fill
  paths — a PNG forces you to redraw or paint-bucket-and-hope, an SVG lets you swap the
  `fill` per plane directly.
- **Re-scaling to match your tile module** (32/64/128 px tile width) is lossless from SVG,
  lossy from PNG raster.
- **Downstream optimisation** (SVGO/SVGOMG, see `svg-vector-generation.md`) only works on
  vector source — you cannot "SVGO" a PNG.
- If the only available format is PNG (common for AI-generated or hand-painted pixel-art
  packs), that's fine — pixel-art tiles are raster-native by design (`pixel-art-workflow.md`)
  and vectorizing them is usually the wrong move. The SVG-preference rule applies to
  icon/illustration-style assets meant to scale, not to intentionally-raster pixel tiles.

## Quick decision table

| You need | Go to |
|---|---|
| Free game tiles/props, no licence review needed | Kenney.nl first, then itch.io (check per-listing), then OpenGameArt (filter by licence) |
| A large, consistent icon family for a product UI | Icons8 or Streamline (subscription, consistent hand) |
| Fast marketing/editorial illustration, budget-conscious | Storyset (free) or Blush (free/Pro) |
| A cloud/infra isometric diagram | Icograms (dedicated iso editor) or Isoflow/Cloudcraft/Holori (cloud-provider icon sets) |
| Curated, higher-craft illustration and don't need AI-training rights | DrawKit |
| Programmatic SVG icon pulls into a build pipeline | Iconify (check the specific icon set's licence, not just "Iconify") |
| Anything destined for an AI training/fine-tuning dataset | CC0 sources only (Kenney, verified-CC0 itch.io/OpenGameArt), or your own commissioned/generated work — never a licence you haven't confirmed permits training use |

## Sources

- SRC-A ch.4 "Icon & Asset Libraries" — Kenney, itch.io, OpenGameArt pack names and counts.
- SRC-A ch.5 (diagram tools) — Isoflow, FossFLOW, Cloudcraft, Holori.
- SRC-C "Core asset libraries" table and "Ethics, IP and commercial-use considerations"
  section — IconScout, Flaticon, Icons8, Streamline, Iconify, DrawKit, Blush, Storyset,
  Icograms descriptions, pricing, and licence shapes; the DrawKit AI-training prohibition
  and the general "commercial use permitted ≠ dataset use permitted" doctrine.
- [drawkit.com/license](https://www.drawkit.com/license) — primary source for the
  AI-training exclusion clause, verified directly (not vendor-summary-only).
- [iconscout.com/licenses](https://iconscout.com/licenses), [kenney.nl](https://kenney.nl),
  [icograms.com](https://icograms.com), [storyset.com/faqs](https://storyset.com/faqs),
  [blush.design](https://blush.design) — vendor licence/product pages cited in SRC-C.
