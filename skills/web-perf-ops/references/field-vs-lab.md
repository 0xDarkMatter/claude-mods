# Field data vs lab data: which to trust, when

**Field data** is what real users experienced: real devices, networks, caches,
interactions. **Lab data** is one synthetic page load in a controlled environment. Field
data **judges** (it is what Core Web Vitals and Search Console assess); lab data
**explains** (it gives you a trace you can debug). Verified 2026-10-05.

## Contents

- [The sources](#the-sources)
- [Which number to trust](#which-number-to-trust)
- [CrUX: what it is and its limits](#crux-what-it-is-and-its-limits)
- [Getting field data](#getting-field-data)
- [RUM with web-vitals v6](#rum-with-web-vitals-v6)
- [Lab tools and their defaults](#lab-tools-and-their-defaults)
- [Making lab runs comparable](#making-lab-runs-comparable)
- [Gotchas](#gotchas)

## The sources

| Source | Kind | Gives you | Blind to |
|---|---|---|---|
| **CrUX** (Chrome UX Report) | Field, Chrome users only | p75 LCP/INP/CLS/FCP/TTFB per origin and per URL, phone/desktop/tablet; field LCP subparts | Non-Chrome users, low-traffic URLs, anything not publicly discoverable, the last day |
| **PageSpeed Insights** | Both | CrUX field block (URL + origin) **and** one Lighthouse lab run | Field: same as CrUX. Lab: one run, one device |
| **Search Console CWV report** | Field (CrUX) | URL **groups** that fail, mobile/desktop | Exact URLs (it samples), anything before ~28 days ago |
| **RUM** (your own `web-vitals` beacons) | Field, every browser you instrument | Per-page, per-template, per-segment values **with attribution** (which element, which script) | Users who leave before the beacon fires; whatever you do not instrument |
| **Lighthouse** (CLI, DevTools, PSI) | Lab | Metrics, a 0-100 score, insights with estimated savings | Real interactions (no INP), scrolling, logged-in state, field caching |
| **DevTools Performance panel** | Lab | Full trace, LCP breakdown, layout-shift track, INP of *your* interactions | Real devices and networks (unless you throttle) |
| **WebPageTest** | Lab | Real browsers on real devices/locations, filmstrips, waterfalls, repeat-view | Real users |
| `cloudflare:web-perf` skill | Lab, via `chrome-devtools-mcp` | An agent-driven trace + insight + network audit, if that third-party skill is installed | Same as DevTools |

## Which number to trust

| Situation | Trust | Do |
|---|---|---|
| Field poor, lab looks fine | **Field** | The lab is not reproducing the user's conditions. Get attribution from RUM, or reproduce with throttling, a cold cache, the consent banner, scrolling, a real phone |
| Field good, lab score poor | **Field** for "is there a problem" | No user-facing problem today. Use the lab findings as regression *risks*, not emergencies |
| No field data (new site, low traffic, URL too quiet) | Origin-level CrUX for context, then lab | Say explicitly that the verdict is lab-only |
| A fix just shipped | **Lab now, field later** | CrUX is a rolling 28-day window: the field number moves gradually over four weeks |
| INP is the problem | **Field (RUM) only** | Lab cannot produce INP on a page load: nobody interacts. TBT is a correlated proxy, not INP |
| Lighthouse score vs metrics | **The metrics** | The score is a weighted lab composite (TBT 30, LCP 25, CLS 25, FCP 10, SI 10). It is not a ranking signal and varies run to run |
| CrUX and RUM disagree | Usually both are right | Different populations: CrUX is Chrome users who sync history and share usage statistics; RUM covers every browser you instrument. Segment RUM to Chrome to compare |
| One template is slow, the origin is fine | **URL/template-level** data | Origin p75 hides a slow template; group RUM by template, or query CrUX per URL |

## CrUX: what it is and its limits

| Fact | Detail |
|---|---|
| Window | Rolling **28 days** |
| Statistic | **75th percentile** of page loads; mobile and desktop are assessed separately against the same thresholds |
| Granularity | Origin and URL; form factors `PHONE`, `DESKTOP`, `TABLET` |
| Eligibility | Publicly discoverable (200, indexable) and "sufficiently popular" - the threshold is not published |
| CrUX API | Refreshed daily (~04:00 UTC); needs a Google Cloud API key; 150 queries/min per project |
| CrUX History API | Weekly points, updated Mondays; 25 periods by default, up to 40 (`collectionPeriodCount`) |
| BigQuery | One table per calendar month, released the second Tuesday of the following month |
| Visualisation | **CrUX Vis** (`cruxvis.withgoogle.com`). The Looker Studio CrUX Dashboard was deprecated at the end of November 2025 |
| FID | Gone. INP replaced FID as a Core Web Vital on 2024-03-12; FID left the CrUX API on 2024-09-10 |

The field record also carries **LCP subparts** for image LCPs
(`largest_contentful_paint_image_time_to_first_byte`, `..._resource_load_delay`,
`..._resource_load_duration`, `..._element_render_delay`) and the LCP resource type.
`scripts/triage-vitals.py` prints them and flags the dominant one: that is the field telling
you which LCP fix to make (see [lcp.md](lcp.md)).

## Getting field data

```bash
# CrUX API: one origin, phone. Needs a Google Cloud API key with the CrUX API enabled.
curl -s "https://chromeuxreport.googleapis.com/v1/records:queryRecord?key=$CRUX_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"origin": "https://example.com", "formFactor": "PHONE"}' > crux.json
python scripts/triage-vitals.py crux.json

# PageSpeed Insights API: field (URL + origin) + one lab run in one response.
curl -s "https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=https%3A%2F%2Fexample.com%2F&strategy=mobile&category=performance&key=$PSI_KEY" > psi.json
python scripts/triage-vitals.py psi.json
```

**Use a key.** Keyless PSI API calls share an anonymous quota; on 2026-10-05 they
returned `429 RESOURCE_EXHAUSTED` with a daily limit of 0. Encodings differ between the
APIs. PSI reports field CLS x100 as an integer (`12` = 0.12) and CrUX reports p75 CLS as a
string (`"0.12"`). `triage-vitals.py` normalises both, so don't hand-parse them.

## RUM with web-vitals v6

`web-vitals` is Google's reference implementation and holds the canonical thresholds.
Use the **attribution build** in production: it reports *why* a metric is bad, not only
the value.

```js
import {onCLS, onINP, onLCP} from 'web-vitals/attribution';

function send(metric) {
  const body = JSON.stringify({
    name: metric.name, value: metric.value, rating: metric.rating, id: metric.id,
    navigationType: metric.navigationType,
    // The "why": element, script, subpart. Keep it small - this is a beacon.
    lcp: metric.name === 'LCP' && {target: metric.attribution.target, url: metric.attribution.url,
      ttfb: metric.attribution.timeToFirstByte, loadDelay: metric.attribution.resourceLoadDelay,
      loadDuration: metric.attribution.resourceLoadDuration, renderDelay: metric.attribution.elementRenderDelay},
    inp: metric.name === 'INP' && {target: metric.attribution.interactionTarget,
      inputDelay: metric.attribution.inputDelay, processing: metric.attribution.processingDuration,
      presentation: metric.attribution.presentationDelay,
      script: metric.attribution.longestScript?.entry?.sourceURL},
    cls: metric.name === 'CLS' && {target: metric.attribution.largestShiftTarget},
    template: document.body.dataset.template, // segment by template, not just URL
  });
  (navigator.sendBeacon && navigator.sendBeacon('/rum', body)) ||
    fetch('/rum', {body, method: 'POST', keepalive: true});
}

onLCP(send); onINP(send); onCLS(send);
```

| v5/v6 change | Impact |
|---|---|
| `onFID()` removed (v5.0.0, 2025-05) | Delete FID reporting; GA4/GTM dashboards still charting FID are reading nothing new |
| Browser support policy: Baseline Widely available (v5) | `onLCP`/`onINP` now report from Safari too (Safari 26.2 shipped LCP + Event Timing); `onCLS` is still Chromium-only |
| Soft navigations (v6.0.0, 2026-07) | Opt in with `{reportSoftNavs: true}` (Chromium 151+). SPA route changes (Vue router) then report their own LCP/INP/CLS. It changes how the first page is finalised, so register a second callback if you need both views |
| `includeProcessedEventEntries` defaults to `false` (v6) | Set it explicitly if your INP attribution reads processed event entries |
| Types must be imported with `import type` (v6) | TypeScript builds with `verbatimModuleSyntax` need the change |

Sending to GA4 through GTM is supported (see the web-vitals README), but a GA4
`event` per metric per page view is heavy. Sample (e.g. 10%) or batch.

## Lab tools and their defaults

| Tool | Default conditions | Notes |
|---|---|---|
| Lighthouse 13 (CLI/DevTools) and PSI's lab run | Moto G Power (2022) emulation, 412x823 @1.75x; "slow 4G" simulated (150 ms RTT, 1.6 Mbps down, 750 Kbps up); 4x CPU slowdown; **simulated** throttling (Lantern) | PSI's About page still says "Moto G4"; the Lighthouse source says Moto G Power. Lighthouse 13 needs Node 22.19+ |
| Lighthouse CI (`@lhci/cli` 0.15) | Same profile, but bundles **Lighthouse 12.6** | Audit ids differ between 12 and 13 - see [budgets-ci.md](budgets-ci.md) |
| DevTools Performance panel | Your machine, unthrottled unless you set CPU/network throttling | Shows live LCP/INP/CLS as you interact - the only lab place INP appears |
| WebPageTest | Real browsers and devices, chosen location | Best for filmstrips, repeat-view caching and third-party blocking experiments |

Lighthouse 13 replaced most legacy performance audits with **insights** that match the
DevTools Performance panel: `lcp-breakdown-insight`, `lcp-discovery-insight`,
`render-blocking-insight`, `image-delivery-insight`, `cls-culprits-insight`,
`inp-breakdown-insight`, `document-latency-insight`, `network-dependency-tree-insight`,
`cache-insight`, `third-parties-insight`, `font-display-insight`, `forced-reflow-insight`.
Audits with a non-zero `metricSavings` are the ones worth reading; `triage-vitals.py`
lists exactly those.

## Making lab runs comparable

- **Median of at least 5 runs** for any before/after claim; single Lighthouse runs vary
  by 5-10 points on the same build.
- Same machine, same throttling, same Chrome. Simulated throttling is stable but estimates;
  DevTools-applied throttling is closer to reality but noisier.
- **Warm the server cache first** on a static-cached site (Blitz, a CDN). A first, cache-miss
  run measures PHP and the database, not what users get.
- Test the **template**, not just the homepage: one representative URL per template type.
- Record the build/commit and the Lighthouse version with every result.

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| "Lighthouse is 98, we're done" | Lab, one device, no interactions | Check CrUX/RUM; INP only exists in the field |
| PSI field block says "not enough data" | The URL is below CrUX's popularity threshold | Use the origin block, or RUM |
| Field didn't improve the day after the fix | 28-day rolling window | Watch the CrUX History API weekly points, or RUM daily |
| RUM INP far worse on Android than CrUX suggests | CrUX blends; RUM segments | Report RUM by device class; CrUX's PHONE vs DESKTOP split is the coarse version |
| CLS fine in RUM for Safari users | `onCLS` does not report outside Chromium | Read CLS from Chromium RUM + CrUX only |
| Search Console lists a URL group as poor after a fix | It lags the 28-day window and validates in batches | Start "Validate fix" after deploy and wait |
