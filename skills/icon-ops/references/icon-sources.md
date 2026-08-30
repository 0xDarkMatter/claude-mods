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
| **Simple Icons** | CC0 1.0 (files) | 24 | filled | Brand marks — see [Brand marks](#brand-marks--three-sources-one-trademark-position) |

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

## Brand marks — three sources, one trademark position

A company's logo is not a UI icon and does not come from a UI icon set. Three
sources cover it, in increasing order of reach and commitment:

| Source | Shape | Coverage | Colour | Offline |
|---|---|---|---|---|
| **Simple Icons** | committed SVG files | ~3k brands | monochrome, themeable | yes |
| **theSVG** | npm package + MCP + Agent Skill | **6,500+** brands | brand colour | yes |
| **Brandfetch** | runtime API keyed on domain | **any domain** | brand colour | **no** |

**Every one of them ships the same legal position**, and each says so in its own
words: theSVG's tooling is MIT while "the brand icons themselves remain the
intellectual property of their respective trademark holders"; Simple Icons
releases files under CC0 with the marks still owned. Reach and convenience vary;
clearance does not exist in any of them.

### theSVG — brand marks as a dependency

Open source ([glincker/thesvg](https://github.com/glincker/thesvg), MIT) with
three delivery routes onto the same 6,500+ brand catalogue:

```bash
npm i thesvg                       # tree-shakeable, typed components
npx -y @thesvg/mcp-server          # MCP server; binary is `thesvg-mcp` (MIT)
npx skills add glincker/thesvg     # Agent Skill via skills.sh
```

The MCP route gives an agent search → preview → fetch as tool calls without
leaving the editor, and needs no API key — a real advantage over Brandfetch for
agent work, where Brandfetch's MCP burns the 100/month Brand API quota.

**Prefer theSVG over Brandfetch whenever the brand set is known at build time.**
You get a committed, offline-safe, versioned asset instead of a runtime
dependency with an expiring URL.

Tooling is MIT. **The marks are not** — theSVG says so itself: the brand icons
"remain the intellectual property of their respective trademark holders", with
an explicit instruction to check each brand's usage guidelines before commercial
use. That is the same position as Simple Icons and Brandfetch, stated plainly.

### Brandfetch — runtime lookup by domain

Where the other two carry a *fixed catalogue*, **Brandfetch** resolves a
company's real brand assets from its **domain** at runtime — full colour, any
company, nothing committed. It answers what no catalogue can: a client whose
logo was never in any set.

Treat it as a separate class, because it behaves like one:

| | Icon set / theSVG | Brandfetch |
|---|---|---|
| Resolved | Build time, committed | **Runtime**, remote |
| Keyed on | Concept ("search") | **Domain** ("nike.com") |
| Colour | Monochrome, `currentColor` | Full brand colour, **not themeable** |
| Coverage | Fixed set | Any domain |
| Offline | Works | **Fails** |

Because it is delivered as a remote image it sits in the `<img>` row of the
[delivery matrix](inline-delivery.md) — it cannot inherit `color`, cannot be
recoloured, and adds a third-party runtime dependency to your page. Correct for
a customer logo wall; never for UI iconography.

### Getting a key

Every Brandfetch product needs a client ID or token. Signup is free:
**https://developers.brandfetch.com/dashboard** (keys live under *Keys and MCP*).

Store it in an environment variable or your secret manager and **never commit
it** — same rule as any other API credential. It is a client-side identifier in
CDN URLs, so treat it as attributable-but-not-secret: rotate it if abused, and
still keep it out of the repo.

### The quota trap — "Brandfetch is free" means two different things

Verified against Brandfetch's own docs 2026-08-30. The free tiers differ by an
order of magnitude *by product*, and assuming the generous one is how you get
throttled on day two:

| Product | Free allowance |
|---|---|
| **Logo API** (CDN logo by domain) | Fair use ~1M req/month; 1,000 per 5 min per IP |
| **Brand Search API** (autocomplete) | Free |
| **Brand API / MCP server** | **100 requests per month** |

Both the Logo API and Brand Search API docs state plainly that **no attribution
is required**. Several third-party comparison pages claim a "Powered by
Brandfetch" link is mandatory — at least one of them is a competitor's landing
page. The official docs win, but re-check before relying on it commercially.

### Operational constraints

- **Hotlink; do not cache or commit.** Logo image URLs expire after ~24 hours.
  Downloading one into `src/icons/` produces an asset that breaks the next day.
- **Fair use forbids replicating their product** — building a standalone brand
  autocomplete on the Search API is out; embedding it in a larger product is fine.
- **Offline and air-gapped builds fail.** If the page must render without
  network, commit a static asset instead and accept the staleness.

### MCP server

`https://mcp.brandfetch.io/mcp` — OAuth in interactive clients, or a bearer
token from the dashboard for headless use. Tools: `brand_search`, `get_brand`,
`get_brand_context`, `enrich_transaction`, `build_logo_urls`, `send_feedback`.

Useful when an agent needs to resolve a brand mid-task. Two cautions: **every
MCP call consumes the Brand API quota** — the 100/month tier, not the 1M Logo
API one — and `build_logo_urls` constructs CDN URLs *without* spending a call,
so prefer it when you only need the URL.

### The trademark position is unchanged

**An API serving you a logo is not permission to use it.** Brandfetch's fair-use
policy governs *their service*; it says nothing about the mark owner's rights.
Everything in trap 1 above applies identically to a logo fetched by domain — the
convenience of resolution is not clearance.

## Sourcing via MCP or a plugin

When an icon-search MCP server is available — `@thesvg/mcp-server` for brand
marks, Brandfetch's for logos by domain, or an aggregator's — it collapses
search → preview → fetch into one step. Two disciplines survive that
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
