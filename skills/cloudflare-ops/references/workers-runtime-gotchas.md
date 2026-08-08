# Workers Runtime Gotchas — production footguns

Battle-tested failure modes from a multi-tenant production Worker (D1 + R2 + Email +
cron, behind Cloudflare Access). Each entry: the failing symptom, why the runtime
behaves that way, and the pattern that fixes it. These are the bugs that pass local
tests and ship — several shipped more than once before the pattern below was adopted.

Companion to [workers-runtime.md](workers-runtime.md) (the API surface) and
[bindings.md](bindings.md) (per-binding config). Verified 2026-08.

## 1. Detached `fetch` — "Illegal invocation"

**Symptom:** `TypeError: Illegal invocation` the moment a request handler calls an
external API — but only in production/`wrangler dev`, never in unit tests.

**Why:** workerd's global `fetch` is a native method that validates its receiver.
Calling it *as a method of something else* — `this.fetchImpl(...)` after
`constructor(env, fetchImpl = fetch)`, or `obj.fetch(...)` after stashing it on an
object — binds that object as `this`, and the native binding rejects any receiver
that isn't the global scope. The classic carriers: an injectable-for-tests
`fetchImpl` property, destructuring, or passing `fetch` around as a value.

**Why tests don't catch it:** the injected test double is a plain JS function with no
receiver check, so the suite is green while the production default (`= fetch`) throws
on first use. This exact bug shipped **three separate times** in one repo — each new
API client copied the injectable-fetch constructor pattern and reintroduced it.

**Fix — either bind at the assignment site or strip the receiver at the call site:**

```typescript
export class ApiClient {
  private readonly fetchImpl: typeof fetch;

  constructor(env: Env, fetchImpl: typeof fetch = fetch) {
    // Option A: bind once at assignment — every later call site is safe.
    this.fetchImpl = fetchImpl === fetch ? fetch.bind(globalThis) : fetchImpl;
  }

  private async get(path: string): Promise<Response> {
    // Option B: call fetch DETACHED — pulling it into a bare local strips the
    // receiver so `this` is undefined and the global fetch runs. Without this,
    // `this.fetchImpl(...)` binds `this` to this object → "Illegal invocation".
    const doFetch = this.fetchImpl;
    return doFetch(`${this.base}${path}`);
  }
}
```

Whichever you pick, leave a guard comment at the site — this pattern *looks* like a
pointless local and a future refactor will inline it straight back into the bug.
(`(...args) => fetch(...args)` as the default parameter also works.)

## 2. `caches` is per-colo — not a KV substitute

**Symptom:** cache entries "disappear" (a write in Sydney is invisible to a request
landing in London); `cache.delete()` "doesn't work" (it only deletes in the colo that
ran it); a cache-backed feature behaves differently per user by geography.

**Why:** the Cache API (`caches.default` / `caches.open`) is a **per-datacenter**
store. There is no replication and **no cross-colo invalidation** — every colo has an
independent cache, populated only by requests that landed there. It is also
best-effort: entries can be evicted anytime, and `put()` refuses responses marked
`private` or `no-store`.

**Choosing the right store:**

| Need | Use | Why |
|------|-----|-----|
| Collapse repeated reads of slow/rate-limited upstreams, staleness in seconds is fine | **`caches` + short TTL** | Free, no binding, per-colo is acceptable when the TTL is shorter than "who cares" |
| Global read-mostly config, staleness up to ~60 s is fine | **KV** | Actually replicated globally (eventually) |
| Read-your-own-write, transactions, anything money-shaped | **D1** (or a Durable Object) | The only options with real consistency |

A production worked example (recorded as two ADRs in the source repo — "no KV; D1 is
the store" and "short-TTL `caches` for upstream reads"): client-portal reads each made
2–3 live calls into an upstream API where **every tenant shares one org-wide rate
budget** (~60 req/min). A client polling hard enough starved the admin's *write* path
of that budget. The fix was a 45 s TTL cache over the `caches` API — long enough to
collapse a poll storm into one upstream call per window, short enough that staleness
is immaterial. Anything needing consistency (idempotency keys, tokens, config that
admins toggle live) stayed in D1.

```typescript
const TTL_S = 45;
// Synthetic internal-host key: can never collide with a real request URL, and the
// identity (tenant, resolved client, resource) is IN the key — never cache across
// an authorization boundary you didn't encode into the key.
const key = (t: string, c: string, r: string) =>
  new Request(`https://xero-cache.internal/v1/${t}/${c}/${r}`);

export async function cached<T>(t: string, c: string, r: string, produce: () => Promise<T>): Promise<T> {
  const hit = await caches.default.match(key(t, c, r));
  if (hit) return (await hit.json()) as T;
  const value = await produce();           // an unexpected error THROWS OUT — never cached
  await caches.default.put(key(t, c, r), new Response(JSON.stringify(value), {
    // max-age on the STORED copy only (put() refuses `private`/`no-store`); build the
    // wire response fresh so this header never reaches the browser/edge.
    headers: { 'content-type': 'application/json', 'cache-control': `max-age=${TTL_S}` },
  }));
  return value;
}
```

Two safety rules from that example: put the caller's *validated* identity in the key
(never a raw query param), and let unexpected errors throw out of the producer so
failures are never cached. Also note the [Smart Placement](#7-smart-placement--run-near-the-data-not-the-user)
interaction below — placement concentrates invocations into few colos, which turns a
"fragmented per-colo cache" into an effectively shared one.

## 3. `waitUntil` — a latency optimisation, not a guarantee

**What it guarantees:** `ctx.waitUntil(promise)` keeps the isolate alive after the
response is returned (or the cron tick ends) until the promise settles, within the
runtime's post-response window. The response is never blocked on it.

**What it does NOT guarantee:** execution. A rejected promise is logged and dropped —
no retry. An isolate can be evicted; a crash in the request path can take the
background work with it. Anything that *must* happen cannot live only in `waitUntil`.

**The pattern — outbox + drain:** make the durable intent a transactional write in
the request path, use `waitUntil` only to *accelerate* processing, and let a cron
re-drain as the guarantee:

```typescript
// Request path: the D1 write IS the guarantee; waitUntil is just promptness.
app.post('/api/referrals', async (c) => {
  const referral = await c.get('repo').createReferral(body);   // enqueues outbox rows in the same txn
  c.executionCtx.waitUntil(dispatchNotifications(c.env));      // immediate drain attempt
  return c.json({ referral }, 201);
});

// Cron (*/5): the real delivery guarantee — re-drains anything the fast path missed.
export default {
  scheduled(controller, env, ctx) {
    if (controller.cron === '*/5 * * * *') ctx.waitUntil(dispatchNotifications(env));
  },
};
```

Second rule: **`waitUntil` each independent job separately.** `ctx.waitUntil(a); ctx.waitUntil(b)`
isolates failures; `ctx.waitUntil(a.then(b))` means a failure in `a` silently
suppresses `b`. Chain only when the order is the point (e.g. "generate, *then* drain
the outbox so the notification goes out in the same tick").

## 4. Testing cron `scheduled()` handlers

`@cloudflare/vitest-pool-workers` gives tests real bindings via
`import { env } from 'cloudflare:test'` (a real D1 with your migrations applied, per
the pool's `miniflare` config). The pattern that makes cron testable:

**Keep the dispatcher thin; test the jobs.** Make `scheduled()` a switch on
`controller.cron` whose only job is `ctx.waitUntil()`-ing exported job functions.
Then tests import and await the job functions directly with `env` — no scheduled
controller machinery, no waiting on an execution context:

```typescript
// src/index.ts — dispatch only, no logic
scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext) {
  if (controller.cron === '*/15 * * * *') ctx.waitUntil(runHostingPinger(env));
}

// test/cron.test.ts — the job is just an async function taking env
import { env } from 'cloudflare:test';
import { runHostingPinger } from '../src/cron';

it('records status only for enabled tenants', async () => {
  const summary = await withMockedFetch(mockedFetch, () => runHostingPinger(env));
  expect(summary).toEqual({ tenantsProcessed: 1, checks: 2 });
});
```

Outbound calls are mocked by swap-restoring the global (`globalThis.fetch = impl` in
a `try`/`finally`); bindings a job touches (`EMAIL`, an R2 bucket) are stubbed as
plain objects on a synthetic env — which is exactly the blind spot in
[gotcha 5](#5-vitest-pool-workers-runs-an-older-workerd-than-production).

**Design jobs self-guarding.** Every job checks its own preconditions and no-ops when
they aren't met — a secret unset (`ASANA_TOKEN` absent ⇒ the nightly ingest is
disabled everywhere), an app flag not enabled for a tenant (skip that tenant), already
ran this period (idempotence guard). Two payoffs: crons ship OFF and are enabled by
config rather than a deploy, and a tick never throws as a whole — guard per tenant /
per item with try/catch so one bad row can't suppress the rest of the run.

For a manual end-to-end poke there's also `wrangler dev --test-scheduled` +
`curl "localhost:8787/__scheduled?cron=*+*+*+*+*"` (see
[workers-runtime.md](workers-runtime.md#scheduled-cron)).

## 5. vitest-pool-workers runs an OLDER workerd than production

**Symptom:** the whole suite is green; the deployed Worker rejects a binding call at
runtime.

**Why:** the pool pins its own workerd, which lags the production runtime. A newer
runtime API simply *does not exist* in the test workerd — the concrete case: the
structured Email Service send, `env.EMAIL.send({from, to, subject, text})`. Tests
exercise a stub (`EMAIL: { send: async () => {} }`), which proves your code path but
can never prove the production binding accepts that call shape. A wrong shape ships
green.

**Mitigation ladder, cheapest first:**

1. **Unit tests against a stub** — proves your logic, not the binding. Necessary,
   insufficient.
2. **`wrangler dev` smoke** — wrangler bundles a *current* workerd that has the new
   API. Exercising one real call locally validates the shape before shipping. Cheap;
   do this whenever you touch a newer binding API.
3. **One real post-deploy invocation + log check** — the only real proof. Trigger one
   send (or wait for the next cron tick) and confirm the effect, or check
   `wrangler tail` / Workers Logs for the failure line. Essential when the calling
   code swallows errors (see gotcha 6).

The same test-double blind spot powers gotcha 1: a mock `fetch` has no receiver
check, a stub `EMAIL` has no shape check. **A stub proves the caller, never the
callee.** When production is the first place the real API runs, budget a step 2/3.

## 6. Email Service — two account states, and the silent-failure trap

The `send_email` binding's recipient reach depends on **account setup, not code**:

| Account state | Who you can send to |
|---------------|--------------------|
| Before a sending domain is onboarded (free) | **Verified destination addresses only** — external sends fail |
| After onboarding a domain (dashboard → Email Service → Domains; Workers Paid) | **Any recipient**, immediately, SPF/DKIM provisioned — with zero code change |

Design for state one: make self-sends (to the org's own verified address) the
critical path — admin summaries, alerts — and let external mail (customer/partner
sends) be gated on the onboarding step rather than on a deploy.

**The trap:** the from-address must belong to a domain the account can send from. An
unverified sender rejects with `E_SENDER_NOT_VERIFIED` — and if your send wrapper is
never-throw (a sensible design so one bad recipient doesn't abort a batch run), that
rejection is swallowed into `false` and **every** send silently fails, including the
self-sends that worked yesterday. The only visible symptom is a log line:

```typescript
export async function sendEmail(env: EmailEnv, msg: OutgoingEmail): Promise<boolean> {
  if (!env.EMAIL) { console.warn(`EMAIL binding absent; would send "${msg.subject}"`); return false; }
  try {
    // Structured send — the current API. The legacy `new EmailMessage(from, to, rawMime)`
    // form is documented as backward-compat only (for callers holding raw RFC 5322).
    await env.EMAIL.send({ from: msg.from, to: msg.to, subject: msg.subject, text: msg.text });
    return true;
  } catch (err) {
    // Never-throw means the CATCH can't throw either: a non-Error rejection would
    // TypeError out of the catch and reject the caller's whole cron tick.
    console.error(`email to ${msg.to} failed: ${err instanceof Error ? err.message : String(err)}`);
    return false;   // E_SENDER_NOT_VERIFIED lands HERE — the log line is the only symptom
  }
}
```

So: verify the from-domain is a routing/sending domain on the account *before*
trusting any email leg, and pair every never-throw wrapper with the post-deploy
log check from gotcha 5 — one real send, then `wrangler tail` for `failed`. (Sanitise
CR/LF out of any DB-sourced value that becomes a header while you're here.)

## 7. Smart Placement — run near the data, not the user

By default a Worker runs in the colo nearest the *user*. If the handler makes
multiple sequential round trips to a **region-pinned resource** — a D1 primary, a
Hyperdrive-fronted Postgres, one origin API — every trip pays the user↔data distance:
a Paris user hitting a Sydney D1 pays ~280 ms × N queries. Smart Placement profiles
the Worker's traffic and moves the *invocation* near the data instead, so N queries
become N × ~1 ms plus one user↔Worker hop.

```toml
# wrangler.toml
[placement]
mode = "smart"
```

```jsonc
// wrangler.jsonc
{ "placement": { "mode": "smart" } }
```

**Right call when:** the handler is chatty with one region-pinned backend (several D1
queries per request is the canonical case), and total response time is dominated by
backend round trips.

**Wrong call when:** the Worker is pure edge work — static assets, cached responses,
a single pass-through fetch, latency-to-user-critical logic. Placement can only help
when there's a data dependency to move toward; it observes your subrequests and
falls back to default placement when it wouldn't win.

**Side effect worth knowing:** placement concentrates invocations into a small number
of colos, which makes the per-colo `caches` API (gotcha 2) behave much closer to a
shared cache — one more reason the short-TTL `caches` pattern holds up in a
Smart-Placed Worker that would fragment badly in a default-placed one.
