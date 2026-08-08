# TypeScript 7 Native Compiler Reference

Adoption knowledge for `typescript@7` — the Go-native compiler (formerly `tsgo` /
`@typescript/native-preview`), stable on npm as `typescript@7.0.2` since 2026-07-08.

> **Point-in-time warning:** sections 3–6 describe the TS 7.0.x state as of
> 2026-08-08. The JavaScript compiler API is slated to return in **7.1+**, and
> ecosystem tools re-port on their own schedules — verify the current 7.x state
> before applying any of the "lockout" or "fallback" guidance below.

## Table of Contents

1. [What TS 7 Native Is](#what-ts-7-native-is)
2. [No JavaScript Compiler API](#no-javascript-compiler-api)
3. [Dual-Install Bin Ambiguity](#dual-install-bin-ambiguity)
4. [Ecosystem Lockout Until 7.1](#ecosystem-lockout-until-71)
5. [The Adoption Case: Measured](#the-adoption-case-measured)
6. [Go/No-Go Checklist](#gono-go-checklist)

---

## What TS 7 Native Is

TypeScript 7 is the Go-based rewrite of the compiler (project "Corsa", previewed
as `tsgo`). The npm package `typescript@7` ships:

- **A `bin/tsc` shim** that launches the platform-native Go binary (delivered via
  optional dependencies like `@typescript/typescript-win32-x64`)
- **No `lib/typescript.js`** — the package is a CLI, not a library

Type-checking semantics are intended to be identical to the JS compiler; the
announcement claimed 7.7–11.9× faster typechecks (real-world repos measure in and
above that range — see [the adoption case](#the-adoption-case-measured)).

TS 6.0 is the JS-based bridge release: it exists to modernise config defaults
(strict-by-default, `module: esnext`, legacy options removed) so a 6.0-clean
tsconfig upgrades to 7 with little or no change. A repo whose tsconfig *already*
matches the strict modern defaults can skip the bridge entirely and adopt 7
directly — the bridge is for config migration, not a required step.

One known hard break at the config level: **TS 7 errors on `baseUrl`**
(TS5102). Repos using `baseUrl`-relative `paths` must rewrite them
tsconfig-relative (`./src/*`, `../pkg/*`) — if they already are, deleting the
`baseUrl` line changes nothing.

## No JavaScript Compiler API

The single biggest adoption consequence, and the one that silently breaks repo
tooling:

```javascript
// Under typescript@7 (7.0.x):
const ts = require("typescript");
// Error: Cannot find module — MODULE_NOT_FOUND
// There is no lib/typescript.js; the package is a bin shim over a Go binary.
```

Anything that imports TypeScript **programmatically** — `ts.createSourceFile`,
`ts.createProgram`, custom lint scripts, codemods, doc generators,
`typescript-eslint` — has no compiler to import. Options, in order of preference:

1. **Make the tool AST-free.** For lint-style checks, a dependency-free
   scrub-then-scan (strip strings/comments with regex, then scan the residue
   for the forbidden pattern) needs no compiler at all. A worked production
   example: a D1-access lint gate (`check-no-raw-d1.mjs`) written as a plain
   Node script precisely so the typecheck compiler could change out from under
   it without breaking the gate. If a script *can* be dependency-free, that is
   the most durable shape — don't "improve" it into `require('typescript')`.
2. **Use an alternative parser** that doesn't depend on the TS package: swc,
   oxc, babel with the TypeScript plugin, or `@typescript-eslint`'s standalone
   parser pinned to a TS 5/6 peer.
3. **Pin the API consumer to an alias.** Install
   `typescript5` (`npm:typescript@^5.9.3`) or the `@typescript/typescript6`
   alias alongside `typescript@7`, and point the API consumer at the alias.
   This works but drags in the [bin ambiguity](#dual-install-bin-ambiguity)
   below — treat it as a transition state, not an end state.

Audit before adopting: `npm ls typescript` in every workspace. If `typescript`
is a **leaf** (nothing depends on it), nothing consumes the API and the switch
is safe. If typescript-eslint or similar appears above it, you're in the
[lockout](#ecosystem-lockout-until-71) case.

Note the boundary: bundlers and test runners that transpile via **esbuild or
swc** (vite, vitest, wrangler, tsup) never invoke tsc or its API — they are
unaffected. The API break only bites tools that *import* the `typescript`
package.

## Dual-Install Bin Ambiguity

> Point-in-time: this section applies while a `typescript5` fallback alias is
> installed next to `typescript@7`. Once the alias is retired the ambiguity
> disappears.

Keeping a TS 5 fallback during a soak period means root `node_modules` holds
**two packages that both ship a `tsc` bin** (`typescript@7` and the
`typescript5` alias). npm's bin-link order is **not deterministic** — observed
in production: after installing the alias, `npx tsc` in the repo root resolved
to **5.9.3**, not 7. Consequences:

- **Bare `tsc` / `npx tsc` must not be trusted** in any directory whose
  `node_modules` holds both packages. `npx tsc --version` tells you which one
  *won the link race*, not which one your scripts should run.
- **Package scripts must invoke explicit bin paths** while the alias exists:

```jsonc
// package.json — explicit compiler paths while typescript5 alias is installed
{
    "scripts": {
        // Native TS 7 — the gate
        "typecheck":      "node node_modules/typescript/bin/tsc --noEmit && node node_modules/typescript/bin/tsc --noEmit -p web/tsconfig.json",
        // Classic TS 5 fallback — one-command cross-check during the soak
        "typecheck:tsc5": "node node_modules/typescript5/lib/tsc.js --noEmit && node node_modules/typescript5/lib/tsc.js --noEmit -p web/tsconfig.json"
    },
    "devDependencies": {
        "typescript": "^7.0.2",
        "typescript5": "npm:typescript@^5.9.3"
    }
}
```

- Workspaces with a **single** typescript install (e.g. a `web/` sub-package
  that only has TS 7) have an unambiguous `tsc` — bare invocations there are
  fine and don't need rewriting.
- Prefer the vendored alias over `npx -p typescript@5.9.3` for the fallback: an
  escape hatch that reaches for the network/npx cache at fallback time can fail
  to resolve exactly when you need it offline.
- **Retire the alias after the soak** (a few weeks of normal work with no
  native-compiler-attributable discrepancies): remove `typescript5` and the
  `*:tsc5` scripts, and scripts may return to bare `tsc` since the collision is
  gone. Leave a guard comment on the explicit paths until then so nobody
  "simplifies" them back early.

## Ecosystem Lockout Until 7.1

> Point-in-time: this is the TS 7.0.x situation. The JS API returns in 7.1+;
> each tool then ports on its own schedule. Check each tool's current status
> before treating it as blocked.

Toolchains that embed the TS programmatic API to typecheck **non-TS file
formats** cannot run on 7.0.x at all:

| Tool | Why it's pinned |
|------|-----------------|
| `vue-tsc` | Wraps the TS API to check `.vue` SFC template/script blocks |
| `svelte-check` | Same pattern for `.svelte` files |
| Astro (`astro check`) | TS API over `.astro` frontmatter/components |
| MDX type-checking | TS API over embedded JSX in `.mdx` |
| `typescript-eslint` type-aware rules | `ts.createProgram` under the hood |

These stay on TS 6 (or a `typescript6` alias) until the API lands in 7.1+ *and*
each tool ships a port. This makes compiler choice a **stack-selection input**:

- **Single-language TS/TSX stacks** (React, plain Node/Workers, anything where
  tsc only ever sees `.ts`/`.tsx`): adopt TS 7 immediately — nothing in the
  check path needs the API.
- **Embedded-language stacks** (Vue, Svelte, Astro, MDX-heavy docs): the
  typecheck gate is welded to the TS 6 API for now. Adopting TS 7 for *speed*
  means either waiting for 7.1+ ports or splitting the gate (native tsc for
  `.ts`, tool-pinned TS 6 for the embedded formats) — added complexity that
  usually isn't worth it before the ports exist.

## The Adoption Case: Measured

> Point-in-time: numbers from one production adoption on 2026-07-09
> (`typescript@7.0.2`); your repo will differ — measure your own.

A ~60k-line Cloudflare Workers + React SPA repo (two tsconfigs) measured with
hyperfine (warmup 1, 5 runs):

| Typecheck | tsc 5.9.3 | tsc 7.0.2 | Speedup |
|-----------|-----------|-----------|---------|
| Worker config | 4.02 s | 0.53 s | 7.6× |
| Web SPA config | 10.05 s | 0.63 s | 16.0× |
| Combined | 14.07 s | 1.16 s | **12.1×** |

Total adoption cost: **one config line** (removing `baseUrl` from the web
tsconfig — its `paths` were already tsconfig-relative). The root tsconfig,
already on TS 6-style strict defaults, needed zero changes; the 6.0 bridge was
skipped entirely.

Second-order win: at ~0.6 s the previously-too-slow SPA typecheck moved *into*
the pre-land check gate — web-side type drift now surfaces at check time
instead of at build time. A 12× compiler isn't just the same gate faster; it
makes previously-rationed checks cheap enough to run always.

Supply-chain footnote: first-stable adoption (`7.0.2` was one day old) sits
inside the usual 7-day new-release cooldown for build deps. The mitigations
that made an early land acceptable there: Microsoft-published, no install
lifecycle scripts on the package or its platform binaries, and tsc running
`--noEmit` (it never writes shipped artifacts). Weigh the same factors — or
just wait out the cooldown.

## Go/No-Go Checklist

Run through this before switching a repo's typecheck to `typescript@7`:

1. **API audit** — `npm ls typescript` in every workspace. TypeScript must be a
   leaf, or every dependent must have a 7.0-era answer (AST-free rewrite,
   alternative parser, or pinned alias). Embedded-language tools
   (vue-tsc/svelte-check/Astro/MDX) → wait for 7.1+ ports.
2. **Config audit** — remove `baseUrl` (TS5102 hard error); confirm `paths`
   are tsconfig-relative and resolution is unchanged under the old compiler
   first.
3. **Benchmark before/after** — hyperfine with warmup on your actual configs.
   The speedup is the justification; record it.
4. **Zero behaviour diff** — run old and new compilers over the same tree and
   compare emitted diagnostics. Identical error sets = go. Any discrepancy is
   an upstream bug report, not a "close enough".
5. **Keep the fallback documented** — vendored `typescript5` alias +
   explicit-path scripts + a `check:tsc5` mirror for the soak period, with the
   retirement condition written down (N weeks, no native-attributable
   discrepancies → remove alias, return to bare `tsc`).
6. **Full gate green** — the entire check pipeline (typecheck + lints + tests +
   build) on the new compiler before landing.
