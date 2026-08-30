# Icon Sources and Licensing

Where to get icons, and the licence traps that matter when the work ships.

---

## Pick one set and stay in it

**The single biggest quality tell in an interface is mixed icon sets.** Icons are
drawn to a house grid, stroke weight and corner language; two sets side by side
read as broken even when each is individually excellent. Before sourcing
anything, decide:

| Decision | Why it locks everything downstream |
|---|---|
| **Grid size** (24 / 20 / 16) | Determines optical density. A 16-grid icon scaled to 24 looks thin and under-detailed |
| **Family** (stroke vs filled) | Mixing them within one UI region reads as inconsistent state, not variety |
| **Stroke width** (1.5 vs 2) | The most visible mismatch of all. Non-negotiable across a set |
| **Corner language** (round vs square caps) | Subtle alone, obvious in a toolbar row |

Only source from a second set when the first genuinely lacks a concept — then
match grid and stroke width, and expect to redraw.

## The sets worth knowing

Licences verified 2026-08-30. **Licences do change** — confirm at the source
before shipping client work.

| Set | Licence | Grid | Family | Notes |
|---|---|---|---|---|
| **Lucide** | ISC | 24 | stroke 2 | Community fork of Feather, far larger. Good default |
| **Feather** | MIT | 24 | stroke 2 | Small, very consistent, largely static |
| **Heroicons** | MIT | 24 / 20 / 16 | both | Tailwind Labs. Ships outline + solid + mini as matched sets |
| **Phosphor** | MIT | 16-based | 6 weights | Widest weight range; thin→fill in one family |
| **Tabler** | MIT | 24 | stroke 2 | Very large set, consistent |
| **Bootstrap Icons** | MIT | 16 | both | Pairs with Bootstrap's type scale |
| **Material Symbols** | Apache 2.0 | 24 | variable font | Axes for weight/fill/grade. Google house style |
| **Remix Icon** | Apache 2.0 | 24 | both | Matched outline/fill pairs |
| **Octicons** | MIT | 16 / 24 | filled | GitHub house style |
| **Font Awesome Free** | Icons **CC BY 4.0**, fonts OFL 1.1, code MIT | varies | both | **CC BY requires attribution.** Pro tier is paid |
| **Simple Icons** | CC0 1.0 (files) | 24 | filled | Brand logos — see the trap below |

## The two traps

### 1. Brand logos are trademarks, whatever the file licence says

**Simple Icons releases the SVG files under CC0, but the trademarks they depict
remain the property of their owners.** A permissive file licence is not
permission to use a company's mark. In practice:

- **Fine:** "Sign in with GitHub" next to the GitHub mark — nominative use,
  describing a real integration.
- **Not fine:** a brand's logo in a testimonial, comparison or customer wall
  implying a relationship that does not exist; any modification of the mark
  (recolouring a logo to your palette is a modification); using a mark in your
  own logo, favicon or app icon.
- Many owners publish brand guidelines with clearances, minimum sizes and
  prohibited treatments. For anything client-facing, follow those, not the
  icon-set licence.

This is the one place where "the licence says CC0" is an actively misleading
answer, so state the trademark position explicitly rather than quoting CC0.

### 2. Aggregators hide the licence

**Iconify** exposes 200,000+ icons across 150+ sets behind one API. Iconify's own
code is MIT — **each icon set keeps its own licence**, and the aggregation is
exactly what makes it easy to ship a CC BY icon with no attribution, or a brand
mark you had no right to use.

The same applies to any MCP server, plugin, or design-tool plugin that searches
across sets: the search result is a file, not a clearance.

**Rule: resolve the icon back to its originating set and record that set's
licence before the icon enters the repo.** One line in the commit message or a
`LICENSES.md` row is enough, and it is the difference between an answerable
question and an audit.

## Sourcing via MCP or a plugin

When an icon-search tool is available (e.g. a `thesvg`-style MCP server), it
collapses search → preview → fetch into one step. Two disciplines survive that
convenience:

1. **Name the originating set** for every icon you keep (trap 2).
2. **Normalize before committing** — vendor output carries editor cruft,
   hardcoded fills and fixed `width`/`height`:

   ```bash
   normalize-icon.py --check fetched.svg || normalize-icon.py fetched.svg -o src/icons/search.svg
   ```

Search by *concept*, not by name: "trash", "bin", "delete" and "remove" return
different results in the same set. If the concept genuinely isn't there, prefer
a near neighbour from the same set over an exact match from a foreign one.

## Attribution, when it is required

CC BY (Font Awesome Free) needs attribution; MIT/ISC/Apache-2.0 need the licence
text preserved but no user-visible credit; CC0 needs nothing. A single
`LICENSES.md`, or a comment block at the top of the sprite, discharges all of
them:

```
Icons: Lucide (ISC) — https://lucide.dev
       Font Awesome Free 6 (CC BY 4.0) — https://fontawesome.com
```

Put it where the icons live, not in a README nobody edits when the set changes.

## Cross-reference

- Delivery mechanics (inline vs sprite vs font) and accessibility →
  [inline-delivery.md](inline-delivery.md)
- Recolouring a whole set to a brand palette → `svg-brand-tint-ops`
