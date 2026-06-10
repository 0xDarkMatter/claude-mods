---
name: playwright-ops
description: "Playwright end-to-end testing operations - selectors, fixtures, network mocking, auth, parallelism, CI, visual regression, flake hunting. Use for: playwright, e2e test, end-to-end testing, browser test, getByRole, page object, storageState, trace viewer, flaky test, test sharding, visual regression, toHaveScreenshot, playwright config, codegen."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: testing-ops, ci-cd-ops
---

# Playwright Operations

End-to-end testing with Playwright Test (`@playwright/test`, TS/JS). A Python flavor
(`pytest-playwright`) exists with the same browser API but pytest-style fixtures — patterns here
translate directly; runner config does not.

## Quick Start

```bash
npm init playwright@latest          # scaffold config + example test + GH Actions workflow
npx playwright test                 # run all tests, all projects
npx playwright test --project=chromium --grep "@smoke"
npx playwright test --ui            # interactive UI mode (watch, time-travel)
npx playwright codegen https://app.local   # record actions -> generated locators
npx playwright show-report          # open last HTML report
npx playwright show-trace trace.zip # inspect a trace
```

## Selector Strategy

**Hierarchy — always prefer the highest tier that uniquely matches:**

| Tier | Locator | When |
|------|---------|------|
| 1 | `page.getByRole('button', { name: 'Submit' })` | Anything with an ARIA role — buttons, links, headings, textboxes. Tests a11y for free |
| 2 | `page.getByLabel('Password')` | Form fields with labels |
| 3 | `page.getByPlaceholder('name@example.com')` | Inputs without labels (fix the label instead, when you can) |
| 4 | `page.getByText('Welcome back')` | Non-interactive text content |
| 5 | `page.getByTestId('cart-total')` | Stable hook when semantics don't disambiguate. Configure attribute via `testIdAttribute` |
| 6 | `page.locator('css=...')` / `xpath=` | **Last resort.** Coupled to DOM structure; breaks on refactor |

Why: tiers 1–4 locate the way a user perceives the page — resilient to markup changes, and
`getByRole` fails loudly when accessibility regresses. CSS/XPath encode implementation detail.

**Narrowing without CSS:**

```ts
page.getByRole('listitem')
    .filter({ hasText: 'Product 2' })
    .getByRole('button', { name: 'Add to cart' });

page.getByRole('row').filter({ has: page.getByRole('cell', { name: 'Alice' }) });
```

### Web-First Assertions (no manual waits, ever)

```ts
// BAD — checks once, races the render; sleeps are flake factories
expect(await page.getByText('welcome').isVisible()).toBe(true);
await page.waitForTimeout(2000);

// GOOD — auto-retries until pass or timeout
await expect(page.getByText('welcome')).toBeVisible();
await expect(page.getByRole('list')).toHaveCount(3);
await expect(page).toHaveURL(/\/dashboard/);
await expect.soft(page.getByTestId('status')).toHaveText('Active'); // don't stop test on failure
```

Actions (`click`, `fill`) auto-wait for actionability (visible, stable, enabled). If you feel the
need for `waitForTimeout`, you're missing an assertion or an `await expect(...)` on a state change.
For async non-DOM conditions use `expect.poll(() => fn())` or `expect(async () => {...}).toPass()`.

Lint guard: enable `@typescript-eslint/no-floating-promises` — a missing `await` on an assertion is
the most common silent-pass bug.

## Config Skeleton

Full production template with comments: [assets/playwright.config.template.ts](assets/playwright.config.template.ts)

```ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? 'blob' : 'html',
  use: {
    baseURL: process.env.BASE_URL ?? 'http://localhost:3000',
    trace: 'on-first-retry',
    testIdAttribute: 'data-testid',
  },
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: 'playwright/.auth/user.json' },
      dependencies: ['setup'],
    },
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI,
  },
});
```

## Fixtures Decision Tree

```
What do I need to share/setup?
│
├─ Per-test object (page object, seeded record)
│  └─ test.extend() test-scoped fixture — setup, await use(x), teardown
│
├─ Expensive, safe-to-share resource (DB pool, test account)
│  └─ Worker-scoped: [fn, { scope: 'worker' }] — once per worker process
│
├─ Side effect every test needs (log capture, network stub)
│  └─ Automatic: [fn, { auto: true }] — runs without being referenced
│
├─ Config-tunable value (locale, default item)
│  └─ Option: ['default', { option: true }] — override in projects[].use
│
├─ Fixtures from several modules
│  └─ mergeTests(testA, testB)
│
└─ Auth state per test file/role
   └─ test.use({ storageState: 'playwright/.auth/admin.json' })
```

**POM-as-fixture (modern recommendation)** — page objects are fine; *instantiating them by hand in
every test* is not. Inject via fixture:

```ts
// fixtures.ts
import { test as base } from '@playwright/test';
import { TodoPage } from './pages/todo-page';

export const test = base.extend<{ todoPage: TodoPage }>({
  todoPage: async ({ page }, use) => {
    const todoPage = new TodoPage(page);
    await todoPage.goto();
    await use(todoPage);          // test body runs here
  },
});
export { expect } from '@playwright/test';
```

Page objects should expose **locators and actions**, not assertions wrapped in try/catch, and never
store element handles. Details: [references/fixtures-and-pom.md](references/fixtures-and-pom.md)

## Network & API

```
Network need?
│
├─ Stub a third-party API           → page.route('**/api/**', r => r.fulfill({ json }))
├─ Tweak a real response            → const res = await route.fetch(); route.fulfill({ response: res, json })
├─ Simulate failure / offline       → route.abort() / route.fulfill({ status: 500 })
├─ Many endpoints, real shapes      → HAR record + replay (page.routeFromHAR, update: true to record)
├─ Pure API test (no browser)       → request fixture / APIRequestContext
├─ Seed data fast, assert via UI    → hybrid: create via request, verify via page
└─ WebSocket traffic                → page.routeWebSocket(url, ws => ws.onMessage(...))
```

**Hybrid seed-via-API, assert-via-UI** — the single biggest speed win in most suites:

```ts
test('shows new project', async ({ request, page }) => {
  const res = await request.post('/api/projects', { data: { name: 'Apollo' } });
  expect(res.ok()).toBeTruthy();
  await page.goto('/projects');
  await expect(page.getByRole('link', { name: 'Apollo' })).toBeVisible();
});
```

Rule of thumb: **mock third-party dependencies you don't own; exercise your own backend for real**
(or mock it deliberately in a separate "frontend-isolated" project).
Details: [references/network-and-api.md](references/network-and-api.md)

## Authentication

Standard pattern — login once in a setup project, reuse `storageState` everywhere:

```ts
// tests/auth.setup.ts
import { test as setup, expect } from '@playwright/test';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Username').fill(process.env.E2E_USER!);
  await page.getByLabel('Password').fill(process.env.E2E_PASS!);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByTestId('user-menu')).toBeVisible();   // wait for auth to settle!
  await page.context().storageState({ path: 'playwright/.auth/user.json' });
});
```

| Pattern | Use when |
|---------|----------|
| One setup project + `storageState` in `use` | One shared account, tests don't mutate server-side user state |
| Per-role files (`admin.json`, `user.json`) + `test.use({ storageState })` | Role-based behavior under test |
| Worker-scoped account fixture (`testInfo.parallelIndex`) | Parallel tests mutate user state — one account per worker |
| API login (`request.post` + `request.storageState`) | Login endpoint exists; 10x faster than UI login |

Gotchas: add `playwright/.auth/` to `.gitignore`. `storageState` captures cookies +
localStorage — **not sessionStorage** (persist that manually via `page.evaluate` + init script).
Always assert a logged-in signal before saving state, or you save a half-logged-in race.

## Parallelism, Retries, Isolation

| Knob | Setting | Notes |
|------|---------|-------|
| Workers | `workers: process.env.CI ? 1 : undefined` | Local: half the logical CPU cores. CI runners are small — shard machines instead of oversubscribing |
| File-level parallel | `fullyParallel: true` | Also makes sharding split per-test, not per-file |
| Sharding | `npx playwright test --shard=1/4` | One shard per CI machine; merge blob reports after |
| Retries | `retries: process.env.CI ? 2 : 0` | Pair with `trace: 'on-first-retry'`; treat "flaky" status as a bug queue, not a fix |
| Serial | `test.describe.configure({ mode: 'serial' })` | Smell — usually means hidden inter-test coupling |

**Isolation discipline:** every test gets a fresh `context`/`page` (cookies, storage) — keep it
that way. No test reads state written by another test; shared server-side state is reset via API in
`beforeEach` or scoped per worker (`test.info().parallelIndex` in usernames/tenant IDs). A suite
that only passes single-worker is broken, not "sensitive".

**Flake diagnosis:** `trace: 'on-first-retry'` → `npx playwright show-trace` (DOM snapshots,
network, console per action). Local: `npx playwright test --ui` or `PWDEBUG=1` / `page.pause()`.
Repro: `--repeat-each=20 --workers=4`. Playbook: [references/flake-hunting.md](references/flake-hunting.md)

**Triage a whole run without eyeballing the report** — generate the JSON reporter output, then
rank the offenders with the bundled triage tool ([scripts/triage-flakes.py](scripts/triage-flakes.py)):

```bash
npx playwright test --reporter=json > results.json   # or reporter: [['json', { outputFile: 'results.json' }]]
scripts/triage-flakes.py results.json                # flaky tests first, then hard fails
```

It emits a ranked TSV (or `--json` envelope, schema `claude-mods.playwright-ops.flake-triage/v1`):
flaky tests (passed only on retry) first — ordered by retry count then duration — followed by
`unexpected` hard failures, each with `file:line`, the status sequence (`failed->passed`), and total
duration. **Exit 10 means flakes/fails were found** (the triage signal — go fix them); exit 0 means a
clean suite. `--outcome all` includes the passing tests for context; `-n N` caps rows.

## CI (GitHub Actions)

```yaml
- uses: actions/checkout@v5
- uses: actions/setup-node@v5
  with: { node-version: lts/* }
- run: npm ci
- run: npx playwright install --with-deps chromium   # only browsers you test
- run: npx playwright test
- uses: actions/upload-artifact@v4
  if: ${{ !cancelled() }}
  with: { name: playwright-report, path: playwright-report/, retention-days: 30 }
```

| Decision | Guidance |
|----------|----------|
| Container vs install-deps | `mcr.microsoft.com/playwright:vX.Y.Z-jammy` image pins browser+OS (best for visual tests); `install --with-deps` is simpler and fine otherwise. **Pin image tag to your `@playwright/test` version** |
| Browser caching | Cache `~/.cache/ms-playwright` keyed on Playwright version; skip when using the container |
| Sharded reports | `reporter: 'blob'` on shards → upload `blob-report/` → merge job: `npx playwright merge-reports --reporter html ./all-blob-reports` |
| Fail-fast vs full suite | PRs: `fail-fast: false` + `--max-failures=10` per shard — see *all* failures in one round-trip. Smoke gates: fail fast |

Full workflows (sharding matrix, merge job, caching): [references/ci-patterns.md](references/ci-patterns.md)

## Visual Testing

```ts
await expect(page).toHaveScreenshot('landing.png', {
  maxDiffPixels: 100,                       // or maxDiffPixelRatio / threshold
  mask: [page.getByTestId('ad-banner')],    // black-box dynamic regions
  fullPage: true,
});
```

- First run generates the baseline (test fails); update with `npx playwright test --update-snapshots`
- Snapshots are named per browser **and platform** (`landing-chromium-darwin.png`) — baselines
  generated on macOS will not match Linux CI. Fix: generate baselines inside the same Docker image
  CI uses, or run visual tests only in the container
- Disable animations: `toHaveScreenshot` defaults `animations: 'disabled'`; hide dynamic bits with
  `mask` or `stylePath` (CSS applied at capture time)
- Global defaults: `expect: { toHaveScreenshot: { maxDiffPixels: 100 } }` in config
- `toMatchSnapshot()` for non-image data (text/buffers)

## Component Testing & When to Prefer Cypress

`@playwright/experimental-ct-react` (also vue/svelte) mounts components in a real browser —
**still experimental**; for component-level work, Vitest browser mode or Testing Library are the
safer default, with Playwright covering E2E.

| Factor | Playwright | Cypress |
|--------|-----------|---------|
| Browsers | Chromium, Firefox, WebKit (real Safari engine) | Chrome-family, Firefox; WebKit experimental |
| Parallelism | Free, built-in, shardable | Paid Cloud for parallel orchestration |
| Multi-tab / multi-origin / iframes | Native | Historically constrained |
| API testing | Built-in `request` context | Via `cy.request`, less ergonomic |
| Component testing | Experimental | Mature, first-class |
| In-browser interactive DX | UI mode (excellent) | The original benchmark; some teams still prefer it |

Reach for Cypress when component testing maturity or an existing Cypress investment dominates;
otherwise Playwright is the default for new E2E suites. (Repo also has a sibling `cypress-ops` skill.)

## Debugging & Codegen

| Tool | Command | Use |
|------|---------|-----|
| UI mode | `npx playwright test --ui` | Watch mode, time-travel, pick locators |
| Inspector | `PWDEBUG=1 npx playwright test` or `page.pause()` | Step through actions live |
| Codegen | `npx playwright codegen <url>` | Records actions, emits role-based locators — treat output as a draft, refactor into POMs/fixtures |
| Trace viewer | `npx playwright show-trace trace.zip` | Post-mortem: snapshots, network, console |
| Headed + slow | `--headed --debug` | Eyeball a single test |
| VS Code extension | — | Run/debug tests, pick locators in-editor |

An official Playwright MCP server (`@playwright/mcp`) also exists for agent-driven browser
automation — distinct from the test runner; don't conflate browsing automation with the test suite.

## References

| File | Contents |
|------|----------|
| [references/fixtures-and-pom.md](references/fixtures-and-pom.md) | Fixture scopes/options/merging, POM-as-fixture architecture, anti-patterns |
| [references/network-and-api.md](references/network-and-api.md) | route/fulfill/abort, HAR replay, API testing, hybrid seeding, WebSocket |
| [references/ci-patterns.md](references/ci-patterns.md) | Full GH Actions workflows: basic, sharded+merge, container, caching, reporters |
| [references/flake-hunting.md](references/flake-hunting.md) | Systematic flake diagnosis: traces, repro loops, common causes + fixes |
| [scripts/triage-flakes.py](scripts/triage-flakes.py) | Parse a Playwright JSON report and rank flaky/failing tests (exit 10 = findings); see Flake diagnosis above |
| [assets/playwright.config.template.ts](assets/playwright.config.template.ts) | Commented production config template |
