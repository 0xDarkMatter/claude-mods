---
name: sentry-ops
description: "Add Sentry error reporting so it sends only what you decided to send, and prove it without sending traffic. Use for: Sentry setup, @sentry/* SDK choice, Sentry on Cloudflare Workers or Astro, withSentry, DSN vs auth token, source map upload, tracesSampleRate and Replay defaults, dataCollection, sendDefaultPii removed in v11, beforeSend scrubbing, PII in Sentry events, testing Sentry with a fake DSN, the Sentry wizard or agent plugin."
license: MIT
allowed-tools: "Read Write Edit Bash Grep Glob"
metadata:
  author: claude-mods
  related-skills: "astro-ops, cloudflare-ops, hono-ops, monitoring-ops, supply-chain-defense"
---

# Sentry Operations

Sentry's onboarding is built to get data flowing fast, and its defaults reflect that.
This skill covers the decisions those defaults make for you, then shows how to check the
result by reading the bytes the SDK would send.

> Verified against Sentry JavaScript SDK v11 (2026). Exact versions, dates and
> measurements are in `assets/sentry-facts.json` and the references.

**Evidence labels used here.** Keep them when you repeat a claim:
**[measured]** we ran it and saw the result. **[code]** read from published package code,
not run. **[docs]** Sentry's docs say so. **[inferred]** reasoned from the above.
**[open]** nobody has checked yet.

## Read this first: v11 changed the privacy default

`sendDefaultPii` was **removed** in v11 [code: zero occurrences in `@sentry/core`,
`@sentry/cloudflare` and `@sentry/astro` 11.10.0]. Older guides still say
`sendDefaultPii: false`. On v11 that line does nothing and raises no error. Unset
`dataCollection` now collects everything [docs: v10-to-v11 migration].

The same request through `withSentry`, by configuration [measured, SDK 11.10.0 on Node]:

| Config | What reached the listener |
|---|---|
| No privacy options | Client IP in `user`, custom headers, full body, query string, cookie names and non-sensitive values, `console.log` text in breadcrumbs, the error message |
| `dataCollection` off + `maxBreadcrumbs: 0` | Error type, stack, message, URL path. **The email in the error message still went out** |
| The above + `beforeSend` scrub | Error type, stack, URL path. Nothing we planted |
| No DSN | Nothing |

So set both layers. `dataCollection` decides what gets collected, and `beforeSend` handles
what your own code put in messages. The built-in denylist matches key names only, so it is
best effort [docs]. `cf-connecting-ip` and our custom header got past it [measured].

## Decide before you install

Sentry's snippets are a demo. Treat each default as a question:

| Default in the snippets | Why it is a decision | Sensible start |
|---|---|---|
| `tracesSampleRate: 1.0` (client and server) | Cost: every trace counts against quota. Docs say to lower it in production. | Leave it out. `0` still counts as tracing enabled, because the check is `!= null` [code] |
| `browserTracingIntegration()` | Browser bytes and quota | Leave out until you use traces |
| `replayIntegration()` at 10% of sessions, 100% on error | Records what users do. Text masking and media blocking are on by default [docs], but that is yours to check. Largest byte cost below | Leave out. If you add it, keep the masks and update your privacy page |
| `feedbackIntegration()` | UI and bytes. Sends what the user types | Only if you will read it |
| Client SDK at all | Server-only setups don't need it. **The wizard's Verify step uses a client-side button, so its page may keep waiting** [inferred] | Add it only if browser errors matter |
| Source map upload | Sends your source to Sentry and adds a credential to the build | Its own decision, see `references/credentials-and-source-maps.md` |

Bytes, as minified / gzipped from a minimal entry with esbuild [measured, 11.10.0]. These
are indicative, so measure your own build before and after:

| Bundle | Minified | Gzipped |
|---|---|---|
| Worker with `withSentry` | 171 KB | 57 KB |
| Browser `init` only | 91 KB | 32 KB |
| Browser + Replay | 232 KB | 77 KB |
| Browser + Tracing + Replay + Feedback | 340 KB | 115 KB |

Also before installing: Sentry becomes a new data processor, so check your privacy page and
any data processing agreement. An organization's US or EU storage region is chosen when it
is created and **can't be changed afterwards** [docs]. Sentry has a project setting to
prevent storing IP addresses.

## Which SDK

| Runtime | Package | Notes |
|---|---|---|
| Plain Cloudflare Worker | `@sentry/cloudflare` | `withSentry`, or its Vite plugin plus `instrument.server.ts` [docs] |
| Astro on Workers | `@sentry/astro` + `@sentry/cloudflare` | Official guide exists. Worked case: `references/astro-on-workers.md` |
| Cloudflare Pages | `@sentry/cloudflare` `sentryPagesPlugin` | Sentry recommends moving to Workers [docs] |
| Hono on Workers | `@sentry/hono` [docs] | App patterns: `hono-ops` |
| Astro on Node | `@sentry/astro` | Its main guide is Node-only [docs] |
| Plain browser | `@sentry/browser` | |
| Node | `@sentry/node` | |

For anything else, start at docs.sentry.io/platforms. Every doc page has a `.md` variant,
and `docs.sentry.io/llms.txt` lists them, which is far easier to read than the rendered
site. For stack-level detail see `astro-ops` and `cloudflare-ops`; for metrics, logs and
alerting beyond errors see `monitoring-ops`.

**Worker requirements** [docs]: `nodejs_compat` and `compatibility_date` of 2024-09-23 or
later. `withSentry` covers `fetch`, `scheduled`, `email`, `queue` and `tail`, and
`WorkerEntrypoint` classes [code]. It skips SDK setup for `OPTIONS` and `HEAD`, so test
with `GET` or `POST` [code].

## The privacy baseline

`assets/scrub-event.mjs` ships a strict `STRICT_DATA_COLLECTION` and a tested `beforeSend`:

```js
import { STRICT_DATA_COLLECTION, makeBeforeSend } from "./scrub-event.mjs";

const sentryOptions = (env) => ({
  dsn: env.SENTRY_DSN,                // unset means nothing is sent
  dataCollection: STRICT_DATA_COLLECTION,
  maxBreadcrumbs: 0,                  // console.log text arrives as breadcrumbs otherwise
  beforeSend: makeBeforeSend({
    isSensitivePath: (path) => path.startsWith("/contact") || path.startsWith("/admin"),
  }),
  // tracesSampleRate omitted on purpose: no tracing at all
});
```

Then set "Prevent storing IP addresses" in the project's Security & Privacy settings, and
keep server-side scrubbing on, which is the default [docs]. Full reasoning, what each layer
misses, and what is left in an event: `references/privacy-baseline.md`.

## Credentials

| | DSN | Auth token |
|---|---|---|
| Can do | Send events to one project. No read access [docs] | Whatever its scopes allow, including reading data |
| Secret? | Semi-public. It ships in browser JS. Abuse means junk events | **Yes, a real credential** |
| Needed by | The running app | The build, only for source map upload |
| Lives in | Worker env or secret, client config | CI secret or local gitignored file. **Never** in the Worker's env or a `PUBLIC_` variable |
| If leaked | Rotate in Client Keys | Revoke now, check what it could reach |

The wizard shows these side by side, which makes them look like equals. They aren't. Prefer
an organization token over a personal one for CI [docs]. Details and secret-scanning
patterns: `references/credentials-and-source-maps.md`.

## Prove it without sending traffic

`astro dev` and unit tests don't prove the real build. `"<skill-dir>/scripts/envelope-sink.py"`
records what the SDK would send, on loopback:

```bash
python "<skill-dir>/scripts/envelope-sink.py" listen --out ./envelopes --count 1 --timeout 120
# wait for its "listening" line, set SENTRY_DSN=http://publickey@127.0.0.1:8191/1,
# then trigger a real error in the real build with planted canary values
python "<skill-dir>/scripts/envelope-sink.py" inspect ./envelopes --forbid person@example.com --strict
```

Order: scrub tests seen failing first, canary run, no-DSN run with `--expect-none`, and one
live event to real Sentry **last**, matched by event id. Steps and the runtime caveats:
`references/prove-without-traffic.md`. Any listener follows the machine's dev-server rule:
throwaway range, killed before finishing.

## Landmines

- **`sendDefaultPii: false` is a silent no-op on v11.** See above. Search for it when
  upgrading from v10 or copying an older guide.
- **A returned 500 is not captured, only a throw** [measured]. Frameworks that turn errors
  into responses need capture inside the framework. Astro does this: see the worked case.
- **A new `dataCollection` category defaults to on.** `mcp` arrived in 11.9.0 [docs]. An
  explicit list can go stale, and `--live` on the verifier below trips when one appears.
- **Spans, logs and metrics skip `beforeSend`.** They have their own hooks [docs]. If you
  turn those products on, scrub them too.
- **The request URL path is always sent** and can't be turned off [docs]. `/users/1234` goes
  out. Change it in `beforeSend` if your paths carry identifiers.
- **`setUser()` is always sent**, whatever `dataCollection.userInfo` says [docs].
- **Start the listener, and wait for it, before triggering.** An SDK posting to a port that
  isn't bound yet loses the event quietly and looks exactly like a pass [measured: it cost
  us one false result]. `--count 1` plus reading the "received" line catches it.
- **All `@sentry/*` packages must match.** `@sentry/astro` pins its siblings exactly [code].
- **Installing Sentry is a dependency add.** Newest by date isn't always the version you
  will install, and `@sentry/agent-plugin` doesn't instrument anything. See
  `references/vetting.md`, and `supply-chain-defense` for the general gate.
- **Deploying isn't part of proving.** `wrangler secret put` and `wrangler deploy` change a
  live environment, so they need the owner's explicit go-ahead.

## Files

| File | Use |
|---|---|
| `references/privacy-baseline.md` | Both layers, what each misses, sensitive routes, the replay decision |
| `references/credentials-and-source-maps.md` | Token types, where each lives, scanning, the source map decision |
| `references/prove-without-traffic.md` | The method step by step, with what was measured and what wasn't |
| `references/astro-on-workers.md` | Worked case: routes by version, capture points, open questions |
| `references/vetting.md` | Choosing a version, reading packages without installing, the agent plugin and wizard |
| `assets/scrub-event.mjs` | Copy into the app: `STRICT_DATA_COLLECTION`, `scrubEvent`, `makeBeforeSend` |
| `assets/sentry-facts.json` | Catalog of version-bound facts |
| `scripts/envelope-sink.py` | Loopback listener and envelope leak checker |
| `scripts/check-sentry-facts.py` | Staleness check |

**Staleness:** `python "<skill-dir>/scripts/check-sentry-facts.py" --offline` checks the
facts against this prose. `--live` checks npm majors, doc pages, and whether the SDK has
gained a `dataCollection` category this baseline doesn't turn off.
