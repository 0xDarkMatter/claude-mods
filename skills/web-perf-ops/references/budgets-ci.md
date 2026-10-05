# Performance budgets in CI (Lighthouse CI, size-limit, field alerts)

A fix that is not guarded regresses within a few releases. Lock wins in three layers:
**build-time byte budgets** (fast, deterministic), **lab budgets per template** (Lighthouse
CI), and **field alerts** (CrUX/RUM, the only layer that sees real users). Verified
2026-10-05 against the LHCI docs and source.

## Contents

- [The three layers](#the-three-layers)
- [The Lighthouse version trap](#the-lighthouse-version-trap)
- [Lighthouse CI config](#lighthouse-ci-config)
- [Assertion syntax](#assertion-syntax)
- [A GitHub Actions job](#a-github-actions-job)
- [Testing a CMS site in CI](#testing-a-cms-site-in-ci)
- [Field alerts](#field-alerts)
- [Gotchas](#gotchas)

## The three layers

| Layer | Tool | Speed | Catches | Misses |
|---|---|---|---|---|
| Bytes | `size-limit` (v14), or a script over the Vite manifest | Seconds | Bundle growth, new heavy dependency | Runtime cost, images, third parties added in a tag manager |
| Lab | Lighthouse CI (`@lhci/cli` 0.15) | Minutes | LCP/TBT/CLS regressions per template, render-blocking additions, image regressions | Real devices, interactions (INP), consent-gated tags |
| Field | CrUX History API / RUM thresholds | Days to weeks | What users actually got | Nothing user-facing, but it's slow and after the fact |

Make the byte layer **blocking** and the lab layer **blocking on a few robust assertions**
(warn on the rest). Treat field alerts as alerts, not CI gates.

## The Lighthouse version trap

**`@lhci/cli` 0.15.1 bundles Lighthouse 12.6.1, not Lighthouse 13.** Lighthouse 13
(2025-10) removed many legacy performance audits in favour of `*-insight` audits. In
Lighthouse 12 both generations exist side by side, and LHCI's `lighthouse:recommended`
preset asserts on both (e.g. `render-blocking-resources` *and*
`render-blocking-insight`).

So:

- Write CI assertions against the **metric audits** (`largest-contentful-paint`,
  `total-blocking-time`, `cumulative-layout-shift`, `first-contentful-paint`) and
  `resource-summary:*`. These ids are the same in 12 and 13.
- If you assert on an insight, use the **`*-insight` id**: it survives the move to 13. A
  legacy id like `uses-responsive-images` silently becomes "audit not found" on 13.
- Lighthouse budgets (`budget.json` inside Lighthouse) were removed in Lighthouse 12.0.
  LHCI still accepts `--budgetsFile` and converts it into `resource-summary` assertions
  itself, but plain assertions are clearer.
- `check-web-perf-facts.py --live` re-checks which Lighthouse major LHCI bundles every
  week and flags the day it changes.

## Lighthouse CI config

`lighthouserc.json` (also `.js`, `.cjs`, `.yml`, `.yaml`, with or without a leading dot):

```json
{
  "ci": {
    "collect": {
      "url": [
        "http://localhost:8080/",
        "http://localhost:8080/news/",
        "http://localhost:8080/news/example-article/"
      ],
      "numberOfRuns": 5,
      "settings": { "preset": "perf" }
    },
    "assert": {
      "assertions": {
        "largest-contentful-paint":  ["error", { "maxNumericValue": 2500, "aggregationMethod": "median-run" }],
        "total-blocking-time":       ["error", { "maxNumericValue": 300,  "aggregationMethod": "median-run" }],
        "cumulative-layout-shift":   ["error", { "maxNumericValue": 0.1,  "aggregationMethod": "median-run" }],
        "first-contentful-paint":    ["warn",  { "maxNumericValue": 1800, "aggregationMethod": "median-run" }],
        "resource-summary:script:size":      ["error", { "maxNumericValue": 250000 }],
        "resource-summary:third-party:size": ["warn",  { "maxNumericValue": 150000 }],
        "resource-summary:font:count":       ["warn",  { "maxNumericValue": 4 }],
        "render-blocking-insight":           ["warn",  { "maxLength": 0 }],
        "categories:performance":            ["warn",  { "minScore": 0.9 }]
      }
    },
    "upload": { "target": "temporary-public-storage" }
  }
}
```

| Choice | Why |
|---|---|
| One URL per **template type** | A CMS site has 5-10 templates, not 10,000 pages; regressions are per template |
| `numberOfRuns: 5` (default 3) with `median-run` | Single runs vary; the median run is the most representative |
| Metric thresholds slightly **looser** than the Core Web Vitals ones in CI | Simulated lab mobile is harsher than many real users; tune to "no regression from today", then tighten |
| `categories:performance` as `warn` | The score bundles five metrics with weights; gate on the metrics themselves |
| `temporary-public-storage` | Free, public, short-lived report links. **Public**: don't use it for unreleased client sites. Self-host an LHCI server, or use `filesystem` and upload the reports as CI artifacts |

## Assertion syntax

| Form | Meaning |
|---|---|
| `"<audit-id>": ["error", {"maxNumericValue": N}]` | Audit's `numericValue` must be <= N (ms for timings, bytes for sizes) |
| `"<audit-id>": ["warn", {"minScore": 0.9}]` | Audit score >= 0.9 |
| `"<audit-id>": ["error", {"maxLength": 0}]` | No items in the audit's details (e.g. no render-blocking resources) |
| `"categories:performance": [...]` | Category score |
| `"resource-summary:<type>:size"` / `":count"` | Types: `document`, `script`, `stylesheet`, `image`, `media`, `font`, `other`, `third-party`, `total`. Size in **bytes** |
| `"user-timings:<kebab-name>": [...]` | Your own `performance.mark`/`measure` |
| `aggregationMethod` | `median`, `optimistic` (default; best run), `pessimistic`, `median-run` |
| Levels | `off`, `warn` (prints, exit 0), `error` (non-zero exit) |
| `assertMatrix` | Different assertions per URL pattern (e.g. looser for the map-heavy template) |

## A GitHub Actions job

```yaml
lighthouse:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-node@v4
      with: { node-version: 22 }
    - run: npm ci && npm run build
    - run: npx size-limit                       # byte layer: fast, blocking
    - run: docker compose up -d --wait          # or however the site boots in CI
    - run: ./scripts/warm-cache.sh              # warm Blitz/static cache before measuring
    - run: npx --yes @lhci/cli@0.15.1 autorun   # collect + assert + upload
```

Pin `@lhci/cli` to an exact version, following the repo's supply-chain rules, so the
bundled Lighthouse cannot change under you between runs. See `ci-cd-ops` for workflow
hardening (pinned action SHAs, permissions).

## Testing a CMS site in CI

| Problem | Approach |
|---|---|
| The site needs PHP + a database | Boot it with Docker Compose (DDEV and similar) from a sanitised DB snapshot, or point LHCI at a staging URL after deploy |
| Measuring a static-cached site | Warm the cache first, or you measure PHP on a cold miss (useful, but a different question: TTFB on a miss) |
| Staging behind basic auth | `collect.settings.extraHeaders` with an `Authorization` header from a CI secret |
| Third-party tags differ on staging | Decide deliberately: block them (`blockedUrlPatterns`) for a stable first-party signal, and measure tags separately on production with RUM |
| Content changes move the numbers | Pin test URLs to stable content (a fixture article), not "latest news" |

## Field alerts

- **CrUX History API**, weekly: alert when an origin's or key URL's p75 crosses from good
  to needs-improvement, or worsens two weeks running. `triage-vitals.py` rates a
  History API response directly (it uses the latest non-null point).
- **RUM**: alert on p75 per template and device class over a 7-day window. Daily p75 on
  low traffic is noise.
- **Search Console** emails when a URL group's status changes. It lags; treat it as
  confirmation.

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| Asserting a legacy audit id, then upgrading to Lighthouse 13 | The audit no longer exists; the assertion fails or is skipped depending on config | Use metric audits, `resource-summary`, `*-insight` ids |
| CI on shared runners is noisy | CPU contention changes TBT run to run | `median-run`, 5 runs, thresholds with headroom; byte budgets as the hard gate |
| `npx @lhci/cli` unpinned | A new LHCI (and Lighthouse) arrives silently | Pin the exact version |
| Gating on `categories:performance >= 0.9` alone | One metric can regress while the score holds | Gate on the individual metrics |
| Lighthouse in CI passes, field regresses | Consent-gated tags, real devices, caches | Field alerts; this is why layer 3 exists |
