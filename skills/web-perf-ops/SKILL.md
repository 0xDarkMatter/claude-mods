---
name: web-perf-ops
description: "Frontend page speed and Core Web Vitals (LCP, INP, CLS), method first: field data (CrUX, RUM) vs lab (Lighthouse, WebPageTest), find the failing metric's subpart, then fix images, fonts, JavaScript and third-party tags, critical CSS and caching/CDN headers, and lock wins with Lighthouse CI budgets. Covers Craft CMS levers (Blitz, eager loading, transforms, craft-vite). Use when pages load or respond slowly, PageSpeed/Lighthouse scores drop, or Search Console flags Core Web Vitals."
license: MIT
allowed-tools: "Read Edit Write Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "perf-ops, craftcms-ops, frontend-upgrade-ops, nginx-ops, cloudflare-ops, ci-cd-ops, vue-ops, tailwind-ops"
---

# Web Performance Operations

> Verified against web.dev + Chrome docs (2026-10-05). Every threshold below lives once in
> `assets/web-perf-facts.json`. `scripts/check-web-perf-facts.py --offline` fails if this
> table and the catalog disagree, and `--live` (weekly) fails if Google moves a number.

Diagnose and fix frontend page speed the way Core Web Vitals are judged: **field data
decides whether there is a problem, lab data explains it, and each fix targets the
failing metric's dominant subpart**, not "the score". Server-side profiling, load
testing and backend latency belong to `perf-ops`; this skill takes over once the question
is about what a browser experiences.

## The method

```
1 FIELD   Is it real? CrUX p75 (PSI field block, CrUX API, Search Console) or your RUM.
          Phone and desktop separately. No field data -> say the verdict is lab-only.
2 METRIC  Which Core Web Vital fails, and which SUBPART:
            LCP = TTFB | load delay | load duration | render delay
            INP = input delay | processing | presentation      CLS = which element, why
3 LAB     Reproduce for a trace: Lighthouse, DevTools Performance panel, WebPageTest
          (or the cloudflare:web-perf skill, if installed). Lab explains; field judges.
4 FIX     Fix the dominant subpart. One change per measurement.
5 PROVE   Lab before/after (median of 5 runs) -> ship -> field confirms over 28 days
          -> lock it with a CI budget so it cannot regress.
```

Skipping step 1 is the classic failure: optimising a Lighthouse score that users never
felt, while the real problem (INP after the consent banner, CLS three screens down) is
invisible in the lab.

## Thresholds

Assessed at the **75th percentile** of page loads. Mobile and desktop are assessed
separately against the same numbers. INP replaced FID as a Core Web Vital on 2024-03-12.

| Metric | Good | Poor | Measures | Field / lab |
|---|---|---|---|---|
| **LCP** | <= 2.5 s | > 4 s | Loading: largest image/text block painted | Both |
| **INP** | <= 200 ms | > 500 ms | Responsiveness: slowest interaction to next paint | **Field**; lab only for an interaction you perform (load proxy: TBT) |
| **CLS** | <= 0.1 | > 0.25 | Visual stability: largest burst of unexpected shifts | Both (lab sees load only) |
| **FCP** | <= 1.8 s | > 3 s | First paint (diagnostic, not a CWV) | Both |
| **TTFB** | <= 800 ms | > 1.8 s | Server + network (diagnostic; web.dev calls it a rough guide) | Both |
| **TBT** | <= 200 ms | > 600 ms | Main-thread blocking during load (Lighthouse scoring points) | Lab only |

Between the two columns is "needs improvement". The Lighthouse performance score is a
weighted lab composite (TBT 30, LCP 25, CLS 25, FCP 10, Speed Index 10). It is not a
Core Web Vital and not a ranking signal.

## Step 1: which number to trust

| Situation | Trust | Next move |
|---|---|---|
| Field poor, lab fine | **Field** | Lab isn't reproducing users: throttle, cold cache, consent accepted, scroll, mid-range phone; get attribution from RUM |
| Field good, lab poor | Field | No user-facing problem today; treat lab findings as regression risks |
| No field data for the URL | Origin-level CrUX, then lab | State that the verdict is lab-only |
| Fix just shipped | Lab now, field later | CrUX is a rolling 28-day window; watch the History API's weekly points or RUM |
| INP fails | **RUM** | Lab page loads have no interactions; find the slow interaction in RUM, then reproduce it in DevTools |
| CrUX and RUM disagree | Both | CrUX is Chrome-only; segment RUM to Chrome to compare |

Details, tool defaults (Lighthouse 13 emulates a Moto G Power on slow 4G with 4x CPU) and
a RUM snippet for web-vitals v6: [field-vs-lab.md](references/field-vs-lab.md).

## Step 2: name the metric and its subpart

| Metric | Read the breakdown from | Dominant subpart -> first fix |
|---|---|---|
| LCP | CrUX image-LCP subparts; RUM `onLCP` attribution; Lighthouse `lcp-breakdown-insight` | **TTFB**: page/edge caching. **Load delay**: hero lazy-loaded, CSS background or JS-injected, missing `fetchpriority`. **Load duration**: oversized image or format. **Render delay**: render-blocking CSS/JS, fonts, fade-in animation |
| INP | RUM `onINP` attribution (`interactionTarget`, phases, `longestScript`, `loadState`) | **Input delay**: load-time JS and third-party tags. **Processing**: handler work, so paint first and yield. **Presentation**: DOM size, layout cost |
| CLS | RUM `onCLS` `largestShiftTarget`; DevTools layout-shift track; `cls-culprits-insight` | Unsized images/embeds, injected banners, font swaps, late CSS, scroll-triggered content |

The healthy LCP profile is about 40% TTFB, under 10% load delay, about 40% load duration
and under 10% render delay. **The two delays are pure waste; check them first.**

## Step 3: triage a report

`scripts/triage-vitals.py` turns whichever report you have into rated rows that each
name the reference holding the fix. It accepts a Lighthouse JSON, a PageSpeed Insights
API response or a CrUX API / History API response, and normalises their different
encodings (PSI sends CLS x100 as an integer; CrUX sends it as a string).

```bash
# PSI: field (URL + origin) + one lab run. Use an API key: keyless calls hit a quota of 0.
curl -s "https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=https%3A%2F%2Fexample.com%2F&strategy=mobile&key=$PSI_KEY" > psi.json
python scripts/triage-vitals.py psi.json
# field:psi-url   LCP    4.20 s   poor               references/lcp.md
# field:psi-url   CLS    0.12     needs-improvement  references/cls.md
# lab:audit       image-delivery-insight  LCP -900 ms  opportunity  references/images.md

python scripts/triage-vitals.py crux.json --json | jq '.data[] | select(.rating != "good")'
```

Field rows come first. With CrUX it also prints the four field LCP subparts and marks
the `dominant` one. Lab audits are listed only when they claim `metricSavings`. Exit
`10` = at least one metric needs work, `0` = all rated metrics good, `4` = unrecognised
report.

## Step 4: fix map

| Symptom | Fix | Reference |
|---|---|---|
| High TTFB on a CMS site | Full-page static cache + HTML at the CDN edge with purge-on-publish; kill redirect chains | [caching-cdn.md](references/caching-cdn.md), [craft.md](references/craft.md) |
| LCP image discovered late | `<img>` in server HTML, eager, `fetchpriority="high"`; preload only if CSS/JS-discovered | [lcp.md](references/lcp.md) |
| LCP image too heavy | `srcset` + accurate `sizes`, AVIF/WebP, transform at upload | [images.md](references/images.md) |
| Render-blocking CSS, slow FCP | Per-template critical CSS inline, rest via `media` swap; purge unused CSS | [css.md](references/css.md) |
| Text LCP or CLS from web fonts | Self-host WOFF2, preload 1-2 files, `font-display` + metric-matched fallback | [fonts.md](references/fonts.md) |
| Poor INP / TBT | Defer and split JS, re-trigger or delete tags, paint then `yieldToMain()` | [inp.md](references/inp.md), [javascript.md](references/javascript.md) |
| Third-party tags (GTM, pixels, chat) | Inventory, delete, re-trigger after load/consent, facades; offload last | [javascript.md](references/javascript.md) |
| CLS from images/embeds/banners | `width`/`height` everywhere, reserved boxes, overlay banners | [cls.md](references/cls.md) |
| Repeat views slow, assets re-download | Hashed filenames + `max-age=31536000, immutable` | [caching-cdn.md](references/caching-cdn.md) |
| Back/forward navigations slow | Remove bfcache blockers (`unload`, needless `no-store`) | [caching-cdn.md](references/caching-cdn.md) |
| Wins keep regressing | Byte budgets (size-limit) + Lighthouse CI on metric audits + field alerts | [budgets-ci.md](references/budgets-ci.md) |

## Step 5: prove it and lock it

- **Lab**: same URL, same throttling, median of at least 5 runs, before and after. Warm
  static caches first, or you are measuring a cache miss.
- **Field**: CrUX moves over 28 days; RUM shows it within days. A fix is done when the
  field p75 says so.
- **CI**: `@lhci/cli` 0.15 still bundles **Lighthouse 12**, so assert on metric audits,
  `resource-summary:*` and `*-insight` ids, never on legacy audit ids that Lighthouse 13
  removed. See [budgets-ci.md](references/budgets-ci.md).

## Craft CMS quick map

| Lever | Moves | Trap |
|---|---|---|
| Blitz static cache (server rewrites, warm after deploy) | TTFB | Pages containing ungenerated transform URLs are never cached: set `generateTransformsBeforePageLoad` |
| `.with()` / `.eagerly()` (Craft 5) | TTFB on cache misses | Blitz Hints was retired in Blitz 5.10; eager-load by hand |
| `{% cache %}` | TTFB without Blitz | Don't combine with Blitz; not auto-disabled for logged-in users |
| Transforms: `getImg()`, ImageOptimize `imgTag()`, Imager X | LCP, CLS | Global lazy-loading macro hits the hero; ImageOptimize has no AVIF |
| craft-vite critical CSS + `modulepreload` | Render delay, FCP | CSS is async by default: no critical CSS means FOUC and CLS |
| SEOmatic script positions, per-template `.include(false)`; Formie JS location | INP | Tracking scripts render only in `live`: measure production |
| Queue worker (`runQueueAutomatically` off) | TTFB, INP | The default runs jobs via an extra request from front-end pages |

Full mapping, versions and syntax: [craft.md](references/craft.md). Craft modelling and
Twig in general: `craftcms-ops`.

## Reference map

| Reference | Read when |
|---|---|
| [field-vs-lab.md](references/field-vs-lab.md) | Choosing data sources; CrUX limits; RUM with web-vitals; Lighthouse 13 insight ids |
| [lcp.md](references/lcp.md) | LCP fails: subparts, discovery, priority, speculation rules |
| [inp.md](references/inp.md) | INP or TBT fails: phases, yielding, framework notes |
| [cls.md](references/cls.md) | CLS fails: session windows, culprits, why field beats lab |
| [images.md](references/images.md) | Formats, `srcset`/`sizes`, `fetchpriority`, lazy loading |
| [fonts.md](references/fonts.md) | `font-display`, preload, subsetting, fallback metrics |
| [javascript.md](references/javascript.md) | Bundle budgets, splitting, GTM/third parties, Partytown-style offload |
| [css.md](references/css.md) | Render-blocking CSS, critical CSS, purging |
| [caching-cdn.md](references/caching-cdn.md) | Cache-Control policy, HTML at the edge, compression, Early Hints, bfcache |
| [budgets-ci.md](references/budgets-ci.md) | Lighthouse CI config/assertions, size-limit, field alerts |
| [craft.md](references/craft.md) | Any Craft CMS site: Blitz, transforms, craft-vite, SEOmatic, Formie, queue |

## Scripts

| Script | Use |
|---|---|
| `scripts/triage-vitals.py REPORT.json` | Rate a Lighthouse / PSI / CrUX report and route each finding to a reference (Step 3) |
| `scripts/check-web-perf-facts.py --offline` | After editing thresholds or prose: catalog <-> SKILL.md table consistency; flags FID advice that doesn't say INP replaced it |
| `scripts/check-web-perf-facts.py --live` | Weekly freshness: web-vitals' own threshold constants, npm majors, deprecations, LHCI's bundled Lighthouse |

Both follow the repo's script contract: `--help` with examples, `--json` envelopes, exit
`10` for findings, `7` (live only) when a source is unreachable.

## Boundaries

| Need | Use |
|---|---|
| An agent-driven lab trace through Chrome DevTools MCP (`chrome-devtools-mcp`) | The third-party `cloudflare:web-perf` skill, if installed: it *runs* the audit; this skill *judges and fixes* it |
| CPU/memory profiling, load tests, slow queries, backend p99 | `perf-ops` |
| Craft content modelling, Twig, element queries | `craftcms-ops` |
| Nginx/Cloudflare configuration syntax | `nginx-ops`, `cloudflare-ops` |
| CI workflow hardening | `ci-cd-ops` |
| Laravel Mix/Webpack -> Vite, Vue 2 -> 3 on a Craft/Twig site | `frontend-upgrade-ops` (other stacks: `migrate-ops`; steady-state Vue 3: `vue-ops`) |

## Gotchas

| Gotcha | Fix |
|---|---|
| Optimising the Lighthouse score instead of the field metric | Start from CrUX/RUM; the score is a lab composite |
| "TBT is fine, so INP is fine" | TBT covers load only; INP covers every interaction in the visit |
| Hero image lazy-loaded by a site-wide image macro | Eager + `fetchpriority="high"` as an explicit macro parameter for the first image |
| Measuring a cold static cache | Warm Blitz/CDN before lab runs, or label the run a cache-miss test |
| Field didn't move the day after a fix | 28-day window; check RUM or CrUX History weekly points |
| Third-party tags invisible in lab | Lab runs consent-free; reproduce with consent accepted and read RUM attribution |
| `@lhci/cli` assertions on legacy audit ids | LHCI bundles Lighthouse 12; legacy ids vanish on 13. Use metric, `resource-summary`, `*-insight` ids |
| `@builder.io/partytown` in package.json | Deprecated; the project is now `@qwik.dev/partytown` (still beta) |
| LCP or CLS worse right after a Mix -> Vite cutover | craft-vite loads CSS async by default: add critical CSS or `asyncCss = false`, and re-check `modulepreload` (`frontend-upgrade-ops` cutover checklist). Take the lab baseline on the Mix build first |
