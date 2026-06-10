/**
 * Production Cypress config template (E2E + Component).
 *
 * Copy to cypress.config.ts at the repo root and adjust the marked sections.
 * Conventions baked in:
 *   - baseUrl set so specs use cy.visit('/relative') and relative cy.request
 *   - retries only in runMode (CI) — feel flakes immediately in openMode (local)
 *   - testIsolation left at its default (true) — each test starts from a clean slate
 *   - Test Replay assumed for CI debugging, so video is off (saves CI time)
 *   - one shared test-selector convention: [data-test=...]
 */
import { defineConfig } from 'cypress';

export default defineConfig({
  // Project-wide defaults (apply to both e2e and component unless overridden) ----------
  // Standard 1280x720; bump for wide-layout apps.
  viewportWidth: 1280,
  viewportHeight: 720,

  // Default 4000ms retry budget for queries/assertions. Raise only for genuinely slow
  // apps — a high global timeout masks real perf problems and slows failure feedback.
  defaultCommandTimeout: 4000,

  // Test Replay (v13+, Cloud, Chromium-only) is the better CI debugging artefact than
  // video and captures DOM/network/console. Turn video off when recording to Cloud.
  video: false,
  screenshotOnRunFailure: true,

  // Retries are flake telemetry, not a fix: a retried-then-passed test shows as "flaky".
  // 0 locally so you feel flakes the instant they appear; up to 2 in CI to keep PRs green
  // while you triage the flaky queue.
  retries: {
    runMode: 2,   // cypress run (CI)
    openMode: 0,  // cypress open (local)
  },

  // Fill from CI secrets via CYPRESS_RECORD_KEY env var; never hard-code it here.
  // projectId: 'abc123',   // set when recording to Cypress Cloud

  e2e: {
    // cy.visit('/login') and relative cy.request resolve against this. Override per
    // environment with the CYPRESS_BASE_URL env var.
    baseUrl: 'http://localhost:3000',

    specPattern: 'cypress/e2e/**/*.cy.{ts,tsx,js,jsx}',
    supportFile: 'cypress/support/e2e.ts',

    // testIsolation: true is the default — cookies/storage cleared and page reset to
    // about:blank before each test. Leave it on; reset SERVER state in beforeEach.
    // testIsolation: true,

    setupNodeEvents(on, config) {
      // Register Node-side plugins/tasks here, e.g. DB reset tasks, code coverage,
      // or env-specific config. Return config if you mutate it.
      //
      // on('task', { resetDb() { /* ... */ return null; } });
      return config;
    },
  },

  component: {
    // framework: which UI library; bundler: 'vite' or 'webpack'. Cypress infers the rest
    // of the dev-server wiring. See references/component-testing.md for the support matrix.
    devServer: {
      framework: 'react',   // 'react' | 'vue' | 'angular' | 'svelte' | 'next' | 'nuxt'
      bundler: 'vite',      // 'vite' | 'webpack'
    },

    // Co-locate component specs with the components, or point at cypress/component/.
    specPattern: 'src/**/*.cy.{ts,tsx,js,jsx}',
    supportFile: 'cypress/support/component.ts',  // must register cy.mount (see refs)
  },
});

// Notes:
// - Add cypress/screenshots/, cypress/videos/, and cypress/downloads/ to .gitignore.
// - For a multi-server app, start each server (app + api) before `cypress run` and use
//   wait-on; never start servers inside a test via cy.exec/cy.task.
// - The default selector convention here is [data-test=...] — wrap it in a getBySel
//   custom command (see SKILL.md Selector Strategy) and enforce data-test on the frontend.
