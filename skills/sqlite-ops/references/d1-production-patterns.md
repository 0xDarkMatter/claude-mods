# D1 Production Patterns

Three patterns learned running a multi-tenant production Worker on Cloudflare D1. Each is
incident-shaped — **symptom → why → procedure** — and each closes a gap where D1's happy-path
API reads as success while something else happened. [`d1-edge.md`](d1-edge.md) is the
platform reference (billing, limits, meta, Sessions API mechanics); this file is what those
mechanics do to you in production and the defensive shape that survives them.

> **Sourcing note.** These patterns come from a live multi-tenant billing platform on one
> Worker + one D1 database (2026-07/08): a migration-timeout incident, a conditional-write
> race in the Xero push path, and a signed-off read-replication rollout (its ADR and the
> ~100-line session module are distilled in pattern 3). The code shapes are generalised;
> the failure modes are not hypothetical.

## Contents

- [Migration apply can time out yet still land](#migration-apply-can-time-out-yet-still-land)
- [batch() and the 0-row conditional write](#batch-and-the-0-row-conditional-write)
- [Read replication: opt-in-to-replica, never opt-out](#read-replication-opt-in-to-replica-never-opt-out)

---

## Migration apply can time out yet still land

**Symptom.** `wrangler d1 migrations apply <db> --remote` reports a timeout or network
error. The natural reflex — re-run it — is the trap.

**Why.** The apply is an HTTP round trip to a remote engine, and the error you saw is about
the *response*, not the *work*. The migration can execute and be recorded server-side while
the CLI's connection dies waiting — so the client-visible outcome ("it failed") and the
database's actual state ("it applied") disagree. A blind re-run then re-executes SQL against
a database that already has it:

- `CREATE TABLE` / `CREATE INDEX` without `IF NOT EXISTS` → the re-run fails, which at
  least tells you the truth, confusingly.
- Seed/backfill `INSERT`s → **duplicated data**, which tells you nothing until something
  downstream breaks.
- `ALTER TABLE ... ADD COLUMN` → fails with "duplicate column name" (SQLite has no
  `IF NOT EXISTS` for column adds — this is why column-add migrations can never be made
  fully idempotent and *must* go through the verify step).

**Procedure — verify state before re-applying, read-only:**

```bash
# 1. What does wrangler think was applied? (D1 tracks applied migrations in its own table)
wrangler d1 migrations list <db> --remote

# 2. Does the schema object actually exist? Ask the database, not the CLI's last error.
wrangler d1 execute <db> --remote --json \
  --command "SELECT name, sql FROM sqlite_master WHERE name = 'new_table_or_index'"

# 3. For a column add, inspect the table shape (pragma_* function form — see d1-edge.md)
wrangler d1 execute <db> --remote --json \
  --command "SELECT * FROM pragma_table_info('the_table')"
```

Decision table:

| Observed | Meaning | Action |
|---|---|---|
| Object exists, migrations list shows it applied | Landed; only the response was lost | Nothing to do — do **not** re-run |
| Object exists, migrations list does NOT show it | Landed but bookkeeping is behind | Reconcile deliberately (the migration's SQL must not run twice) — never a blind re-apply |
| Object missing | Genuinely did not land | Re-apply |

Two habits make the incident boring instead of dangerous:

- **Write migrations idempotent-safe where the syntax allows it** — `IF NOT EXISTS` on
  every `CREATE`, `INSERT OR IGNORE` for seeds — so an accidental double-apply is a no-op.
  Where it doesn't (column adds), the verify-first procedure above is the whole protection.
- **Treat "timeout" as "state unknown", never as "failed".** The same discipline as any
  distributed write: an error after the request left the building tells you nothing about
  what the server did.

---

## batch() and the 0-row conditional write

**Symptom.** A scoped write inside a `batch()` — `UPDATE ... WHERE id = ? AND
tenant_id = ?` — "succeeds": no error, batch commits, caller returns 200. But the row
belongs to another tenant (or was already claimed, or doesn't exist), so the statement
matched **zero rows** and changed nothing. The caller reported success for a write that
never happened.

**Why.** `batch()` wraps its statements in a transaction and rolls back on a **SQL
error** — and a conditional `UPDATE`/`DELETE` matching 0 rows is *not* an error. It is a
successful statement with `meta.changes === 0`. This is correct SQL semantics on every
engine, but D1's batch framing makes it easy to read "the batch committed" as "every
statement did what I meant". The scoping predicate that makes multi-tenant writes safe
(`AND tenant_id = ?`) is exactly the predicate that turns an authorization failure into a
silent no-op.

**Procedure — pre-check, post-verify, compensate.** The rule in one line: **0 rows
affected on a scoped UPDATE/DELETE means 403/404/conflict, never success.**

The single-statement shape — check `meta.changes` on every conditional write:

```ts
const res = await db
  .prepare(`UPDATE clients SET name = ?, updated_at = ? WHERE id = ? AND tenant_id = ?`)
  .bind(name, now, clientId, tenantId)
  .run();
if ((res.meta?.changes ?? 0) === 0) throw NotFound('client not found');
// 0 here means: wrong tenant, or no such row. Either way, NOT success.
```

The compare-and-set shape — a conditional claim where exactly one racer may win:

```ts
// Claim is a CAS on the ownership column, never an assumption. Two racers issue the
// same UPDATE; the WHERE ... IS NULL lets exactly one match. The loser's statement
// "succeeds" with 0 changes — the explicit count check is what turns that into Conflict.
const claim = await db
  .prepare(`UPDATE push_intents SET document_id = ?, updated_at = ?
             WHERE id = ? AND tenant_id = ? AND document_id IS NULL`)
  .bind(documentId, now, intentId, tenantId)
  .run();
if ((claim.meta?.changes ?? 0) !== 1) throw Conflict();
```

The batch shape — conditional statements inside a `batch()` need a **post-verify count
and a compensating undo**, because the batch cannot fail itself on your behalf:

```ts
// lockStmts are conditional claims (`... WHERE owner_id IS NULL`): a racing writer
// matches zero rows there and the batch still commits. The post-verify is the gate.
await db.batch([docStmt, ...lineStmts, ...lockStmts]);

const locked = await db
  .prepare(`SELECT COUNT(*) AS n FROM entries WHERE tenant_id = ? AND owner_id = ?`)
  .bind(tenantId, documentId)
  .first<{ n: number }>();
if ((locked?.n ?? 0) !== expectedCount) {
  await db.batch(undoStmts);   // compensate: release partial claims, delete the doc
  throw Conflict();            // a concurrent writer claimed some rows first
}
```

`batch()` returns one result per statement, each with its own `meta` — so for batches
where each statement's effect matters, walk the results and check `meta.changes`
per-statement rather than trusting the commit. (Counting actual changes is also how you
report an honest number for `INSERT OR IGNORE` batches: sum `meta.changes`, don't count
statements.)

When you *want* the batch to abort atomically on a precondition, invert the trick: make
the guard statement **violate a constraint** on failure (e.g. an `INSERT` that collides
with a `UNIQUE` index) — a real SQL error rolls the whole batch back. That is the one
shape where "error aborts batch" works *for* you; a 0-row match never will.

---

## Read replication: opt-in-to-replica, never opt-out

**Symptom class this prevents.** With D1 read replication enabled (see
[`d1-edge.md`](d1-edge.md#sessions-api-and-read-replication) for the mechanics), the naive
rollout routes *all* reads through replica-eligible sessions and then exempts the routes
someone remembered are sensitive. Every route the exemption list misses is a **stale read
feeding a write flow** — a balance check, a pre-push billing review, a lock check — and the
failure only shows up as an occasional wrong decision under replica lag, which is the worst
possible way to discover a route classification bug.

**The pattern.** Invert the default so a classification mistake degrades to *slower*,
never to *staler*:

1. **Every request defaults to `first-primary`** — strongly consistent, identical to
   pre-replication behaviour.
2. A request may serve from a replica **only** when it is a `GET` **and** its path is
   positively enumerated in a replica allowlist of display-only surfaces.
3. A route missing from the allowlist — by oversight or by design — stays on the primary:
   no latency win, no correctness risk. **A misclassification cannot corrupt data.** The
   partition's safety is a property of the code shape, not of per-query vigilance.
4. **Writes always hit the primary** regardless of session mode (D1 routes writes to the
   primary itself) — so the only thing the allowlist can get wrong is letting a
   *pre-write read* see stale data. Keep every entry display-only.
5. **Carry the session bookmark in a cookie** so the caller's next request is bounded to
   be at least as fresh as their own last write (read-your-writes), even when served by
   a replica.

The whole decision fits in ~100 lines, and isolating it in one module is part of the
pattern — one place owns the safety decision, and the data layer just receives a session:

```ts
/** Display-only GET routes allowed to serve from a nearby read replica.
 *  Two matching shapes, chosen deliberately per entry:
 *   - Trailing '/': whole-subtree prefix. Safe ONLY because the method gate below
 *     excludes every mutation under it anyway.
 *   - No trailing slash: exact path only. Use this when the same mount point also
 *     serves write-flow reads (e.g. '/api/time/dashboard' is listed, but the
 *     billing-review reads under '/api/time/billing' must never become eligible —
 *     a prefix would have silently swept them in).
 *  When unsure, leave the route off — the default (primary) is always safe, just slower. */
const REPLICA_ALLOWLIST: readonly string[] = [
  '/api/analytics/',        // subtree: pure read-model surface
  '/api/dashboard',         // exact: sibling routes include write-flow reads
];

function isReplicaEligible(method: string, path: string): boolean {
  if (method !== 'GET') return false;
  return REPLICA_ALLOWLIST.some((e) => (e.endsWith('/') ? path.startsWith(e) : path === e));
}

/** Argument for env.DB.withSession(...) for this request. */
function pickSessionMode(method: string, path: string, bookmark: string | null): string {
  if (!isReplicaEligible(method, path)) return 'first-primary';   // the safe default
  // Replica-eligible: constrain to the caller's own last write if they have one.
  return bookmark ?? 'first-unconstrained';
}

// In the request middleware: one session per request, bookmark round-tripped in a cookie.
const bookmark = getCookie(request, 'd1_bookmark');
const session = env.DB.withSession(pickSessionMode(request.method, url.pathname, bookmark));
// ... handlers run against `session` instead of `env.DB` ...
const newBookmark = session.getBookmark();
if (newBookmark) setCookie(response, 'd1_bookmark', newBookmark);
```

Classification guidance from the production partition that shipped:

| Surface | Classification | Why |
|---|---|---|
| Analytics, dashboards, index/list read-models | Replica-eligible | Seconds of lag is invisible on a display surface |
| Money *display* (totals, statements) | Replica-eligible | Display-only; nothing decides on it |
| Any read **inside a write flow** (balance/lock checks, review-before-push) | Primary-only | A stale read here feeds a mutation |
| Read immediately after that user's own write | Covered by the bookmark | Read-your-writes without pinning the route to primary |

Two operational notes:

- **Local test environments have one D1 and no replicas**, so the *refactor* (threading a
  session through the data layer) is testable locally but the *staleness behaviour* is
  not — validate replication in a preview/staging environment, and verify routing in
  production via `meta.served_by_primary` / `meta.served_by_region`
  ([`d1-edge.md`](d1-edge.md#the-meta-object)).
- Session mode only constrains the **first** query; within a session D1 guarantees
  sequential consistency. The allowlist + bookmark pattern is about *choosing* the right
  first-query constraint per request, cheaply and safely, for every route you have —
  including the ones nobody thought about.

---

## See also

- [`d1-edge.md`](d1-edge.md) — the D1 platform reference: billing, limits, `meta`,
  Sessions API mechanics, Time Travel, error catalogue
- [`migration-patterns.md`](migration-patterns.md) — wrangler migrations, numbering,
  the deploy gate these apply-verification steps slot into
- [`concurrency-durability.md`](concurrency-durability.md) — the engine-level locking
  model behind the CAS/claim shapes
- `cloudflare-ops` skill — Workers, bindings, wrangler configuration, deployment
