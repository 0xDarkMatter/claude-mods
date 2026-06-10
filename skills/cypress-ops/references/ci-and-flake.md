# CI & Flake Hunting

## GitHub Actions — the official action

`cypress-io/github-action` wraps install, dependency caching, app boot, and the run. It is
the path of least resistance.

```yaml
name: e2e
on: [push, pull_request]
jobs:
  cypress:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: cypress-io/github-action@v6
        with:
          build: npm run build
          start: npm start                 # boots the app
          wait-on: 'http://localhost:3000' # polls until the app answers — no `sleep`
          wait-on-timeout: 120
          browser: chrome
        env:
          CYPRESS_BASE_URL: http://localhost:3000
```

Key point: **start the app outside the test run** (`start` + `wait-on`), never `cy.exec` a
server inside a test. Port conflicts and lost stdout follow from in-test servers.

## Recording to Cypress Cloud (Test Replay)

```yaml
      - uses: cypress-io/github-action@v6
        with:
          start: npm start
          wait-on: 'http://localhost:3000'
          record: true
        env:
          CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Test Replay** (Cypress v13+) replaces video as the CI debugging artefact. It captures DOM
mutations, network requests, JS errors, console logs, CSS, SVG, iframes, and shadow DOM —
then lets you time-travel through the failed run in Cloud. Caveats: **Chromium-family
browsers only** (Chrome, Edge, Electron — not Firefox/WebKit), and it does **not** capture
video/audio elements, websockets, `localStorage`/cookies, or `cy.request` traffic. With Test
Replay on, disable video (`video: false`) to save CI time.

## Parallelism

```yaml
  cypress:
    strategy:
      fail-fast: false
      matrix:
        containers: [1, 2, 3, 4]           # 4 machines
    steps:
      - uses: cypress-io/github-action@v6
        with:
          record: true
          parallel: true                   # Cloud balances specs across the 4
          group: 'e2e'
        env:
          CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
```

`--parallel` **requires Cypress Cloud** (paid) — Cloud does the spec balancing. Without
Cloud, shard manually by globbing distinct spec sets per matrix job:

```yaml
        with:
          spec: cypress/e2e/group-${{ matrix.shard }}/**/*.cy.ts
```

This is cruder (no load balancing, you partition by hand) but free.

## Container image

```yaml
    container:
      image: cypress/browsers:node-22.11.0-chrome-131-ff-133
```

`cypress/browsers` and `cypress/included` images pin browser + OS — the right choice when
screenshot/visual stability matters or to avoid installing system deps each run.

## Retry configuration

```ts
// cypress.config.ts
export default defineConfig({
  retries: {
    runMode: 2,      // cypress run (CI): retry a failing test up to 2x
    openMode: 0,     // cypress open (local): never retry — feel flakes immediately
  },
});
```

Retries are **flake telemetry, not a cure**. A test that only passes on retry is a bug in
the queue — Cypress flags it as flaky. Treat the flaky list as work, not noise.

---

## Flake playbook

Most Cypress flake reduces to four root causes. Diagnose in this order.

### 1. Action chained where a query/assertion belonged

```ts
// FLAKY — re-render between .find and .click detaches the element
cy.get('[data-test=row]').find('[data-test=edit]').click().should('be.disabled');

// STABLE — split so the action's leading query retries; assert separately
cy.get('[data-test=row]').find('[data-test=edit]').click();
cy.get('[data-test=edit]').should('be.disabled');
```

"Element is detached from the DOM" almost always means this.

### 2. Racing the network with a numeric wait

```ts
cy.wait(2000);                                  // FLAKY — guesses at timing
// →
cy.intercept('GET', '/api/data').as('getData'); // STABLE — wait on the actual request
cy.get('[data-test=load]').click();
cy.wait('@getData');
```

### 3. Stale value captured with `.then()`

```ts
// FLAKY — .then doesn't retry; $count snapshot may be pre-update
cy.get('[data-test=count]').then(($count) => {
  expect($count.text()).to.eq('5');
});
// →
cy.get('[data-test=count]').should('have.text', '5');   // STABLE — .should retries
```

### 4. Inter-test state leakage

A test that passes alone but fails in the suite is coupled to another test's state.
- Verify with `it.only` — does it pass in isolation? If yes, it's coupling.
- Reset **server-side** state in `beforeEach` (not `afterEach` — an `after` hook may be
  skipped if the run is interrupted or refreshed mid-test).
- `testIsolation: true` (default) already clears browser state per test; don't disable it
  to "fix" a leak — that hides the real coupling.

### Diagnosis tooling

| Tool | How | Use |
|------|-----|-----|
| Test Replay | `cypress run --record` → Cloud | Post-mortem a CI failure: DOM/network/console time-travel |
| Cypress App | `cypress open` | Local time-travel: hover each command to see DOM snapshot |
| Headed CI repro | `cypress run --headed --no-exit` | Watch the failing run locally |
| Repeat to surface | `cypress run --spec <flaky> --env repeat=20` (loop in script) | Force intermittent flake to reproduce |
| Screenshots | automatic on failure in `cypress/screenshots/` | Quick "what did the page look like" |
