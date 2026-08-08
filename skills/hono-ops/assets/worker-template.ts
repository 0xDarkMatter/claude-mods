// hono-ops starter: a Hono v4 composition root for one Cloudflare Worker serving
// an authed JSON API + a SPA, with a bearer-auth machine surface and cron beside it.
// ADAPT-POINTS are marked <<< — everything else is the load-bearing skeleton.
// Registration ORDER in this file is the security topology (see the skill's
// middleware.md): middleware before the routes it must cover, catch-alls last.
//
// Pairs with wrangler config:
//   assets = { directory: "./web/dist", binding: "ASSETS",
//              not_found_handling: "single-page-application",
//              run_worker_first: ["/api/*", "/ingest/*"] }
//   triggers = { crons: ["*/5 * * * *"] }

import { Hono } from 'hono';
import type { MiddlewareHandler } from 'hono';

// --- env: the Worker's configuration contract --------------------------------
interface Env {
  DB: D1Database;                 // <<< your bindings
  ASSETS: Fetcher;                // static assets binding (the built SPA)
  /** Comma-separated bearer keys for /ingest (two during rotation). Optional:
   *  while unset the surface 503s — absence disables, never crashes. */
  INGEST_KEYS?: string;
}

// Per-request context set by the auth middleware; handlers read ONLY this.
type Identity = { userId: string; email: string; role: 'admin' | 'member' };
type Vars = { identity: Identity };

export const app = new Hono<{ Bindings: Env; Variables: Vars }>();

// --- 1. outermost: response hardening (fills missing headers on EVERY response)
function securityHeaders(): MiddlewareHandler {
  return async (c, next) => {
    await next();
    // ASSETS.fetch responses have IMMUTABLE headers — copy, then rebuild.
    const headers = new Headers(c.res.headers);
    const setIfMissing = (n: string, v: string) => { if (!headers.has(n)) headers.set(n, v); };
    setIfMissing('x-content-type-options', 'nosniff');
    setIfMissing('x-frame-options', 'DENY');
    setIfMissing('referrer-policy', 'no-referrer');
    c.res = new Response(c.res.body, { status: c.res.status, statusText: c.res.statusText, headers });
  };
}
app.use('*', securityHeaders());

// --- 2. unauthenticated exceptions, registered BEFORE auth (deliberate bypass)
app.get('/api/health', (c) => c.json({ ok: true }));

// --- 3. auth: verify the credential, then build the request's world ----------
app.use('/api/*', async (c, next) => {
  if (c.req.path === '/api/health') return next();   // skip-list documents the exception
  const identity = await verifyCaller(c.req.raw, c.env);   // <<< your JWT/session verify
  if (!identity) return c.json({ error: 'forbidden' }, 403);
  c.set('identity', identity);
  await next();
});

// --- 4. routes + feature sub-app mounts (inside the auth boundary) -----------
app.get('/api/me', (c) => c.json({ identity: c.get('identity') }));
// app.route('/api/widgets', widgetsApi);   // <<< identity already set for sub-apps

// --- 5. machine surface OUTSIDE /api/*: its own bearer auth, not session auth -
const ingest = new Hono<{ Bindings: Env }>();
ingest.use('*', async (c, next) => {
  if (!c.env.INGEST_KEYS) return c.json({ error: 'unavailable' }, 503);
  const token = (c.req.header('authorization') ?? '').replace(/^Bearer /, '');
  const keys = c.env.INGEST_KEYS.split(',').map((k) => k.trim()).filter(Boolean);
  if (!token || !keys.some((k) => timingSafeEqual(token, k))) {
    return c.json({ error: 'unauthorized' }, 401);
  }
  await next();
});
ingest.post('/events', async (c) => {
  const body = await c.req.json<{ events?: unknown[] }>().catch(() => ({}) as { events?: unknown[] });
  if (!Array.isArray(body.events)) return c.json({ error: 'bad_request', message: 'events[] required' }, 400);
  return c.json({ accepted: body.events.length }, 202);
});
app.route('/ingest', ingest);

// --- 6. the 404 split: JSON for API typos, SPA shell for everything else -----
app.all('/api/*', (c) => c.json({ error: 'not_found' }, 404));
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw));

// --- 7. one error boundary ---------------------------------------------------
class AppError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) {
    super(message); this.name = 'AppError';
  }
}
app.onError((err, c) => {
  if (err instanceof AppError) return c.json({ error: err.code, message: err.message }, err.status as 400);
  if (err instanceof SyntaxError) return c.json({ error: 'bad_request', message: 'invalid JSON body' }, 400);
  console.error('unhandled error', err);            // detail to logs,
  return c.json({ error: 'internal' }, 500);        // generic to the wire
});

// --- export: fetch + cron in one Worker --------------------------------------
export default {
  fetch: app.fetch,
  scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    // Branch per cron expression; each job independently waitUntil'd so one
    // failure never suppresses a sibling. Jobs must be idempotent — crons re-run.
    if (controller.cron === '*/5 * * * *') {
      ctx.waitUntil(drainOutbox(env));               // <<< your jobs
    }
  },
} satisfies ExportedHandler<Env>;

// --- helpers (stubs — replace) -----------------------------------------------
async function verifyCaller(_req: Request, _env: Env): Promise<Identity | null> {
  throw new AppError(500, 'not_implemented', 'wire your JWT/session verification here'); // <<<
}
async function drainOutbox(_env: Env): Promise<void> {} // <<<
function timingSafeEqual(a: string, b: string): boolean {
  // Constant-time compare over a fixed length — an early-return compare leaks
  // prefix length via timing.
  const enc = new TextEncoder();
  const ab = enc.encode(a), bb = enc.encode(b);
  const len = Math.max(ab.length, bb.length, 1);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}
