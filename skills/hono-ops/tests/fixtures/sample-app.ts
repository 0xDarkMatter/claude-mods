// Test fixture for route-inventory.py — a miniature composition root exercising
// every registration shape the scanner claims to parse. NOT runnable code; the
// identifiers are stubs. tests/run.sh asserts exact counts against this file,
// so adding a registration here means updating those assertions.
import { Hono } from 'hono';

export const app = new Hono<{ Bindings: Env; Variables: Vars }>();

app.use('*', securityHeaders());

// Deliberately registered BEFORE the /api/* auth middleware: the --check linter
// must flag this route as bypassing it (the fixture's one expected finding).
app.get('/api/health', (c) => c.json({ ok: true }));

app.use('/api/*', authMiddleware);

app.get('/api/me', (c) => c.json({}));
app.post('/api/things', (c) => c.json({}, 201));
app.patch('/api/things/:id', (c) => c.json({}));
app.delete('/api/things/:id', (c) => c.json({ ok: true }));
app.on('PURGE', '/api/cache', (c) => c.json({ ok: true }));

app.route('/api/time', timeApi);
app.route('/vesper', vesper);

app.all('/api/*', (c) => c.json({ error: 'not_found' }, 404));
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw));

app.onError((err, c) => c.json({ error: 'internal' }, 500));

// Chained definition (RPC style) — attribution must follow the new app var,
// not stick to `app` from the statements above.
const chained = new Hono()
  .get('/posts/:id', (c) => c.json({ post: null }))
  .post('/posts', (c) => c.json({ ok: true }, 201));

export type ChainedType = typeof chained;
