// hono-ops starter: vitest-pool-workers config for testing a Hono Worker
// inside workerd with real bindings. ADAPT-POINTS marked <<<.
// Companion: the skill's references/testing.md explains every choice here.
//
// Install: npm i -D vitest @cloudflare/vitest-pool-workers
// Type the `env` import in tests via a test/env.d.ts:
//   declare module 'cloudflare:test' {
//     interface ProvidedEnv extends Env {}          // your Worker's Env
//     interface ProvidedEnv { TEST_MIGRATIONS: D1Migration[] }
//   }

import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';

export default defineWorkersConfig(async () => {
  // Apply the REAL migrations into each test run's D1 so tests hit the same
  // schema (and CHECK constraints) as production. Delete if you have no D1.
  const migrations = await readD1Migrations('./migrations');   // <<< your migrations dir

  return {
    test: {
      include: ['test/**/*.{test,spec}.ts'],
      // Exclude sibling git worktrees and the SPA's own suite: worktrees under
      // .claude/worktrees/* carry their own (often stale) copy of test/ +
      // migrations/ — sweeping them in double-counts and lets an unrelated
      // worktree's broken migration fail this run.
      exclude: ['**/node_modules/**', '**/.claude/**', 'web/**'],   // <<< adjust web/ to your SPA dir
      setupFiles: ['./test/apply-migrations.ts'],
      // test/apply-migrations.ts is two lines:
      //   import { applyD1Migrations, env } from 'cloudflare:test';
      //   await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
      poolOptions: {
        workers: {
          // One workerd instance for the whole suite: faster, and module-level
          // state (JWKS caches etc.) behaves like a live isolate.
          singleWorker: true,
          // Per-TEST-FILE storage isolation: D1/KV/R2 writes in one file never
          // leak into another. Within a file, re-seed in beforeEach.
          isolatedStorage: true,
          miniflare: {
            // KEEP EQUAL to your wrangler config's compatibility_date — a skew
            // here is the classic "passes local, fails deployed" source.
            compatibilityDate: '2024-12-01',                    // <<<
            compatibilityFlags: ['nodejs_compat'],
            d1Databases: { DB: 'my-app-test' },                 // <<< binding name -> test db id
            // r2Buckets: ['FILES'],                            // <<< R2 bindings, if any
            // durableObjects: { ROOM: 'Room' },                // <<< DO bindings, if any
            bindings: {
              TEST_MIGRATIONS: migrations,
              // Plain-var bindings the suite needs; per-test overrides are just
              // a spread at the call site: app.request(path, {}, { ...env, KEY: 'x' })
              SOME_CONFIG_VAR: 'test-value',                    // <<<
            },
          },
        },
      },
    },
  };
});
