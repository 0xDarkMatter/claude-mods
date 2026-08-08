# Cloudflare D1 and Edge SQLite

D1 is SQLite, so everything in [`query-performance.md`](query-performance.md),
[`schema-design.md`](schema-design.md), and [`feature-modules.md`](feature-modules.md)
applies unchanged. This file covers what is **different**: how you observe cost, how you are
billed, the platform features stock SQLite has no equivalent for (Sessions API read
replication, Time Travel, `d1 insights`), and the limits that will bite.

> **Two sourcing notes.** Measurements labelled *verified 2026-08-04* come from a live D1
> database (`atdw-mirror`, region OC, colo SYD) and are **one database's numbers, not
> constants**. Platform limits and feature descriptions come from the Cloudflare D1 docs as
> of 2026-08-04 — that surface moves, so re-check
> [platform/limits](https://developers.cloudflare.com/d1/platform/limits/) before designing
> around a number.

## Contents

- [Two metrics, not one](#two-metrics-not-one)
- [The meta object](#the-meta-object)
- [Measuring correctly](#measuring-correctly)
- [wrangler d1 insights](#wrangler-d1-insights)
- [Statement formatting rules](#statement-formatting-rules)
- [Cold runs and variance](#cold-runs-and-variance)
- [Platform limits](#platform-limits)
- [The bound-parameter cap](#the-bound-parameter-cap)
- [Introspection is blocked](#introspection-is-blocked)
- [Batching and the invisible statement](#batching-and-the-invisible-statement)
- [Sessions API and read replication](#sessions-api-and-read-replication)
- [Time Travel](#time-travel)
- [Automatic retries](#automatic-retries)
- [Error catalogue](#error-catalogue)
- [Import and export](#import-and-export)
- [Optimising for rows read](#optimising-for-rows-read)
- [Schema changes under a deploy gate](#schema-changes-under-a-deploy-gate)
- [libSQL and Turso](#libsql-and-turso)

---

## Two metrics, not one

D1 reports latency and rows-read per statement, and **they move independently**:

| Metric | What it is | Why it matters |
|---|---|---|
| `meta.timings.sql_duration_ms` | Server-side execution, excluding network | User-facing latency |
| `meta.rows_read` | Rows the engine **scanned** | **The billing unit** |
| `meta.rows_written` | Rows written (`INSERT`/`UPDATE`/`DELETE`) | Also billed |

Billing is per row scanned, regardless of row size: a 1 KB row and a 100 KB row each count
as one. Indexes add a written row when the indexed column is written (one to the table, one
to the index) — almost always repaid by the reduction in rows read.

Measured examples from the same session (verified 2026-08-04):

- A covering-index fix cut latency **~25x** (171.83 ms → 6.75 ms) while leaving rows read
  essentially **unchanged** (60,736 → 58,433). Latency win, **no billing win**.
- A watermark fix (replacing an unindexed `MAX()` scan with an indexed lookup) collapsed rows
  read roughly **58,000x** — 58,432 → 1. Billing win *and* latency win.

An "optimisation" that halves latency while leaving a 58k-row scan in place has not reduced
your D1 bill at all. Always report the pair.

---

## The meta object

Returned by `run()`, `all()`, and each result of `batch()`.

| Field | Meaning |
|---|---|
| `timings.sql_duration_ms` | SQL execution by the database instance, **excluding network time** — the number to optimise against |
| `duration` | Duration of the query execution, in milliseconds |
| `rows_read` | Rows scanned — the billing unit |
| `rows_written` | Rows written |
| `changes` | Number of changes made |
| `changed_db` | `true` if anything on the database changed — useful for asserting a statement really was read-only |
| `last_row_id` | Last inserted row id (not applicable to `WITHOUT ROWID` tables) |
| `size_after` | Database size after the query |
| `served_by_region` | Region of the instance that executed the query |
| `served_by_primary` | `true` only if the primary served it — the replica-routing tell |

```js
const { results, meta } = await env.DB
  .prepare("SELECT id, name FROM product WHERE org = ?").bind("acme").all();

console.log({
  ms: meta.timings.sql_duration_ms,
  scanned: meta.rows_read,
  efficiency: results.length / Math.max(meta.rows_read, 1),  // want close to 1.0
  region: meta.served_by_region,
  primary: meta.served_by_primary,
});
```

**Query efficiency** — rows returned ÷ rows read — is the single best one-number health
metric for a D1 statement. A query returning 20 rows after scanning 58,000 has an efficiency
of 0.0003 and is a missing index.

---

## Measuring correctly

**Use `sql_duration_ms`. Never wall-clock a `wrangler` invocation** — `npx`/wrangler startup
is roughly two seconds before any SQL executes, which drowns the signal entirely. A Worker
with a D1 binding talks to the database directly and pays none of that startup, so CLI wall
time is doubly misleading about production.

```bash
wrangler d1 execute atdw-mirror --remote --json \
  --command "SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%'" \
  | jq '.[0].meta | {ms: .timings.sql_duration_ms, rows_read, rows_written, served_by_primary}'
```

A 12-run median loop, reporting the range as well:

```bash
for i in $(seq 1 12); do
  wrangler d1 execute atdw-mirror --remote --json \
    --command "SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%'" \
    | jq -r '.[0].meta.timings.sql_duration_ms'
done | sort -n | awk '{a[NR]=$1} END {printf "median %.2f  min %.2f  max %.2f\n", a[int(NR/2)+1], a[1], a[NR]}'
```

`EXPLAIN QUERY PLAN` works over the same path and is the right first move:

```bash
wrangler d1 execute atdw-mirror --remote --json \
  --command "EXPLAIN QUERY PLAN SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%'" \
  | jq -r '.[0].results[].detail'
```

Pipe that into `scripts/eqp-triage.py` for severities and fix hints.

**Note `--remote`.** Omit it and you hit a *local* copy, which will happily give you fast,
meaningless numbers against different data.

---

## wrangler d1 insights

The feature most often missed. `d1 insights` ranks your **actual production queries** by
cost — it finds the expensive statement you didn't know to look for, which is precisely the
class of problem the "invisible aggregate" below belongs to.

```bash
# Slowest queries on average over the last day
wrangler d1 insights atdw-mirror --sort-type=avg --sort-by=time --limit=10

# Biggest total row-scanners over a week - the ones costing you money
wrangler d1 insights atdw-mirror --sort-type=sum --sort-by=reads --limit=10 --timePeriod=7d

# Most frequently executed - a cheap query run 10M times beats a slow one run twice
wrangler d1 insights atdw-mirror --sort-type=sum --sort-by=count --limit=10

# Machine-readable, for triage in a script
wrangler d1 insights atdw-mirror --sort-by=reads --limit=20 --json | jq '.[]'
```

| Flag | Values | Default |
|---|---|---|
| `--timePeriod` | e.g. `1d`, `7d` | `1d` |
| `--sort-type` | `sum`, `avg` | `sum` |
| `--sort-by` | `time`, `reads`, `writes`, `count` | `time` |
| `--sort-direction` | `ASC`, `DESC` | `DESC` |
| `--limit` | integer | — |
| `--json` | flag | `false` |

Reported per query: `avgRowsRead` / `totalRowsRead`, `avgRowsWritten` / `totalRowsWritten`,
`avgDurationMs` / `totalDurationMs`, `numberOfTimesRun`, and **`queryEfficiency`** (rows
returned ÷ rows read — target close to 1.0).

**Triage order that works:** sort by `sum`/`reads` first (total cost), then by `avg`/`time`
(worst single experience), then look for low `queryEfficiency` at high `numberOfTimesRun` —
that combination is a missing index on a hot path.

The command is marked experimental; if it changes, the same data is available through the
GraphQL Analytics API (`d1AnalyticsAdaptiveGroups`, `d1QueriesAdaptiveGroups`,
`d1StorageAdaptiveGroups`; fields include `readQueries`, `writeQueries`, `rowsRead`,
`rowsWritten`, `queryBatchTimeMs` with percentiles such as `queryBatchTimeMsP90`, and
`databaseSizeBytes`; 31-day retention).

---

## Statement formatting rules

**Statements must be on ONE LINE.** A multi-line `--command` fails with:

```
incomplete input: SQLITE_ERROR 7500
```

This is a wrapper-parsing artefact, not a SQL error, and the message is actively misleading —
it reads like unbalanced parentheses. Collapse to one line, or use a file.

```bash
# Fails: multi-line --command
wrangler d1 execute db --remote --command "SELECT a
FROM t"

# Works: one line
wrangler d1 execute db --remote --command "SELECT a FROM t"

# Works: multi-line via file
wrangler d1 execute db --remote --file ./query.sql
```

---

## Cold runs and variance

The **first run is not representative.** Observed on multi-thousand-row reads (verified
2026-08-04): a routine 1.5–1.7x penalty above median on the first execution, and one cold run
measured **2,495 ms against a 171 ms median** for the same statement — a 14x outlier.

- Take a **median of 10+ runs** and report the range.
- Discard, or at least label, the first run.
- Never compare a single before-run to a single after-run — that comparison can invert the
  true result entirely.
- Report honestly: "171.83 ms median, 168–2,495 ms across 12 runs", not "171 ms".

---

## Platform limits

From the D1 docs, 2026-08-04. Re-check before designing around any of them.

| Limit | Workers Paid | Workers Free |
|---|---|---|
| Databases per account | 50,000 | 10 |
| Maximum database size | 10 GB | 500 MB |
| Maximum storage per account | 1 TB | 5 GB |
| Queries per Worker invocation | 1,000 | 50 |
| Maximum SQL statement length | 100,000 bytes (100 KB) | same |
| **Maximum bound parameters per query** | **100** | same |
| Maximum SQL query duration | 30 seconds | same |
| Maximum columns per table | 100 | same |
| Maximum rows per table | Unlimited (within storage) | same |
| Maximum string / BLOB / row size | 2,000,000 bytes (2 MB) | same |
| Maximum arguments per SQL function | 32 | same |
| **Maximum bytes in a `LIKE`/`GLOB` pattern** | **50 bytes** | same |
| Maximum file import (`d1 execute --file`) | 5 GB | same |

Individual query limits apply to **each statement inside a batch**, not to the batch as a
whole.

Two of these interact with material elsewhere in this skill:

- **100 columns per table.** The worked example's 73-column table was already close. A wide
  table is exactly where covering indexes pay off most (see
  [`query-performance.md`](query-performance.md#covering-indexes)) — and past 100 columns you
  must split the table regardless.
- **50 bytes in a `LIKE` pattern.** Long user-supplied search strings will be rejected — a
  further argument for FTS5 `MATCH` over `LIKE` for real search
  ([`feature-modules.md`](feature-modules.md#the-trigram-tokenizer)).

Rows-read/written pricing (2026-08-04): Free 5M rows read + 100k written per day; Paid
includes 25B rows read + 50M written per month, then $0.001/M read and $1.00/M written;
storage 5 GB included, then $0.75/GB-month. No egress charges. **Read replicas cost nothing
extra** — you pay the same `rows_read`/`rows_written`.

---

## The bound-parameter cap

100 bound parameters per statement. Exceeding it:

```
too many SQL variables … SQLITE_ERROR 7500
```

This bites the moment you build `WHERE id IN (?, ?, ?, …)` from a list. Inline literals are
**not** capped — and that is the trap, because switching to string-interpolated literals to
dodge the cap is how SQL injection gets introduced.

**Chunk instead:**

```js
const CHUNK = 90;   // headroom under the 100-parameter cap
const out = [];
for (let i = 0; i < ids.length; i += CHUNK) {
  const slice = ids.slice(i, i + CHUNK);
  const placeholders = slice.map(() => "?").join(",");
  const { results } = await env.DB
    .prepare(`SELECT id, name FROM product WHERE id IN (${placeholders})`)
    .bind(...slice)
    .all();
  out.push(...results);
}
```

Note what is and isn't interpolated: the **placeholder string** is generated (safe — it is
`?` characters), the **values** are always bound. Never build the value list by
concatenation, whatever the cap says.

**Better still, one parameter for any list length** using `json_each`:

```sql
SELECT p.id, p.name FROM product p JOIN json_each(?) j ON j.value = p.id;
```

```js
await env.DB.prepare("SELECT p.id, p.name FROM product p JOIN json_each(?) j ON j.value = p.id")
  .bind(JSON.stringify(ids)).all();
```

Watch the 100 KB statement-length limit if you go the inline route for a very large list —
and remember chunked reads each count separately toward the 1,000-queries-per-invocation cap.

---

## Introspection is blocked

D1 refuses several introspection paths with `SQLITE_AUTH`. Verified refused 2026-08-04:

| Attempted | Result |
|---|---|
| `SELECT sqlite_version()` | `SQLITE_AUTH` |
| `SELECT * FROM pragma_module_list` | `SQLITE_AUTH` |

**Consequence: FTS5 and trigram availability on D1 could not be confirmed read-only.**
Confirming it requires `CREATE VIRTUAL TABLE`, which is a **write** — out of reach of a
read-only investigation and of a session under a deploy gate.

**This is genuinely unknown, not "probably fine".** If your design depends on FTS5 on D1,
verify deliberately: create a throwaway virtual table in a **preview/dev** D1 database (never
production) and observe. Record the result; do not infer it from stock SQLite behaviour.

What *does* work for schema discovery:

```sql
SELECT name, sql FROM sqlite_master WHERE type IN ('table','index');
SELECT * FROM pragma_table_info('q_product');
SELECT * FROM pragma_index_list('q_product');
SELECT * FROM pragma_index_info('q_product_org');
```

The `pragma_*` **table-valued functions** are the introspection route on D1 — the classic
`PRAGMA table_info(x)` statement form is not generally available through the HTTP path.
Connection-scoped pragmas (`journal_mode`, `busy_timeout`, `foreign_keys`, `synchronous`) are
managed by the platform and are not yours to set.

---

## Batching and the invisible statement

`batch()` sends multiple statements in one round trip, wrapped in an implicit transaction
that stops at the first failure. Good for latency and atomicity — **dangerous for
observability**: a statement inside someone else's batch adds no measurable round-trip cost,
so it never appears in per-request timing, while still doing all its work and billing every
row it reads.

The measured case (verified 2026-08-04): a `MAX()` over an unindexed column, riding inside a
batch another query was already sending, scanned **58,432 rows on every response across four
separate tools** and cost **28.09 ms** — invisible to per-query measurement.

```js
// Each of these is billed and timed separately, even though it is one round trip
const [a, b] = await env.DB.batch([
  env.DB.prepare("SELECT id, name FROM product WHERE org = ?").bind(org),
  env.DB.prepare("SELECT MAX(updated_at) FROM product"),   // <- full scan, hiding here
]);
```

**Audit rule for any D1 codebase:** enumerate every statement in every `batch()` and price
each individually. A batch's cost is the *sum* of its statements' rows read. `d1 insights`
sorted by `sum`/`reads` will surface these even when your own instrumentation cannot.

Batching has a *correctness* trap as well as this observability one: the batch rolls back
on a SQL error, but a conditional `UPDATE` matching 0 rows is **not** an error — see
[`d1-production-patterns.md`](d1-production-patterns.md#batch-and-the-0-row-conditional-write)
for the pre-check / post-verify / compensate shape.

---

## Sessions API and read replication

D1 can serve reads from **read replicas** — read-only copies, one per supported D1 region,
created and routed to automatically by Cloudflare **at no additional cost**. Writes always
go to the primary; replicas forward them.

Replication is **opt-in twice**: enable it on the database (dashboard → D1 → your database →
Settings → Enable Read Replication, or the REST API with `read_replication.mode: auto`),
**and** use the Sessions API in your Worker. Without `withSession()`, every query goes to the
primary and you get no benefit.

```ts
export default {
  async fetch(request, env) {
    // Continue a prior session's consistency guarantee, or start fresh
    const bookmark = request.headers.get("x-d1-bookmark") ?? "first-unconstrained";
    const session = env.DB.withSession(bookmark);

    const { results, meta } = await session
      .prepare("SELECT * FROM Customers WHERE CompanyName = ?")
      .bind("Bs Beverages")
      .all();

    const response = Response.json(results);
    // Hand the bookmark back so the NEXT request is at least as fresh as this one
    response.headers.set("x-d1-bookmark", session.getBookmark() ?? "");
    return response;
  },
};
```

| `withSession()` argument | Behaviour |
|---|---|
| `"first-unconstrained"` (default) | First query may go to any instance — lowest latency, may be slightly stale |
| `"first-primary"` | First query goes to the primary — freshest data, higher first-query latency |
| A bookmark string | Session starts at least as current as that bookmark |

**The consistency model is sequential consistency *within a session*.** Queries in one
session never see the database go backwards, and a read after a write in the same session
sees that write. Across sessions you get nothing unless you carry the bookmark — which is why
the header round-trip above is the whole pattern, not an optimisation.

The classic bug replication introduces: write, redirect, read — and the read lands on a
replica that hasn't caught up, so the user doesn't see their own change. Carrying the
bookmark (or using `first-primary` on the read-after-write path) is the fix.

`session.getBookmark()` returns `null` if no query ran in the session. Check
`meta.served_by_primary` and `meta.served_by_region` to see where a query actually landed —
that is how you verify replication is doing anything.

**When replication does not help:** write-heavy workloads (all writes hit the primary
anyway), single-region traffic, and workloads that require the absolute latest data on every
read.

For the production rollout shape — default every request to `first-primary` and let only an
enumerated allowlist of display-only GETs touch a replica, so a misclassified route degrades
to slower rather than staler — see
[`d1-production-patterns.md`](d1-production-patterns.md#read-replication-opt-in-to-replica-never-opt-out).

---

## Time Travel

D1's built-in point-in-time recovery. There is no stock-SQLite equivalent, and it is the
reason a D1 migration is less frightening than a local one.

| Property | Detail |
|---|---|
| Retention | **30 days** (Workers Paid), 7 days (Free) |
| Granularity | Any timestamp, or a bookmark |
| Restore is destructive | Overwrites the database **in place**; in-flight queries are cancelled |
| Restoring keeps history | Older bookmarks remain valid, so you can restore again to a different point |
| Bookmarks from timestamps | Deterministic — the same timestamp always yields the same bookmark |
| Not yet supported | Cloning/forking a database to a new one via Time Travel |
| Requires | Wrangler v3.4.0+, a production-version database |

```bash
# Current bookmark - capture this BEFORE any risky migration
wrangler d1 time-travel info atdw-mirror

# Restore to a Unix timestamp, or an ISO-8601 date-time string
wrangler d1 time-travel restore atdw-mirror --timestamp=1754280000
wrangler d1 time-travel restore atdw-mirror --timestamp=2026-08-04T11:18:53.000+10:00

# Restore to a specific bookmark
wrangler d1 time-travel restore atdw-mirror --bookmark=<BOOKMARK_ID>
```

**A restore is a production-state change** — maintainer-gated, exactly like a deploy. A
working session records the bookmark and reports the command; it does not run it.

Bookmarks are the same objects the Sessions API uses, which is what makes "restore to the
state that request saw" possible: log `session.getBookmark()` alongside a request id and you
can later restore to precisely that point.

---

## Automatic retries

D1 detects read-only queries and retries them up to **two** times on retryable failures.

- Only statements containing solely `SELECT`, `EXPLAIN`, or `WITH` are retried.
- Anything containing a write keyword is never retried.
- D1 checks for modifications after each execution and rolls back if a retry caused a write,
  so retries are side-effect-free even if detection is fooled.

**Implication for measurement:** a `sql_duration_ms` outlier may be a retried query. One more
reason to take a median rather than trusting a single sample.

Your own code still needs retry logic for **writes** — those are never retried for you.

---

## Error catalogue

| Message | Meaning | Action |
|---|---|---|
| `incomplete input: SQLITE_ERROR 7500` | Multi-line `--command` | One line, or `--file` |
| `too many SQL variables … SQLITE_ERROR 7500` | >100 bound parameters | Chunk, or `json_each` |
| `SQLITE_AUTH` | Blocked introspection (`sqlite_version()`, `pragma_module_list`) | Use `sqlite_master` / `pragma_*` functions |
| `D1 DB is overloaded. Requests queued for too long.` | Too many requests, or queries too slow | Optimise queries, spread load, shard |
| `D1 DB is overloaded. Too many requests queued.` | Queue too long | Same |
| `D1 DB's isolate exceeded its memory limit and was reset.` | A query loaded too much into memory | Shard the query; add a `LIMIT` |
| `D1 DB exceeded its CPU time limit and was reset.` | A very expensive scan, or a large import/export | Split into smaller statements |
| `Exceeded maximum DB size.` | Past the storage limit | Delete data, or shard across databases |
| `Your account has exceeded D1's maximum account storage limit` | Account-wide storage limit | Delete unused databases, or upgrade |
| `No SQL statements detected.` | Empty/invalid input | Check the statement made it through |
| `D1 DB reset because its code was updated.` / `Network connection lost.` | Transient platform events | Retry |

The "overloaded" and "CPU time limit" errors are the ones an unindexed scan produces at
scale. They are performance problems wearing an infrastructure costume — go to
[`query-performance.md`](query-performance.md), not to a support ticket.

---

## Import and export

```bash
# Export the whole database as SQL
wrangler d1 export atdw-mirror --remote --output=./database.sql

# Schema only / data only / one table
wrangler d1 export atdw-mirror --remote --output=./schema.sql --no-data
wrangler d1 export atdw-mirror --remote --output=./data.sql   --no-schema
wrangler d1 export atdw-mirror --remote --output=./one.sql    --table=q_product

# Import (this is a WRITE to production - maintainer-gated when --remote)
wrangler d1 execute atdw-mirror --local  --file=./database.sql
wrangler d1 execute atdw-mirror --remote --file=./database.sql
```

| Constraint | Detail |
|---|---|
| Import file size | 5 GB max for `d1 execute --file` — split larger loads and import sequentially |
| Statement length | 100 KB — split a huge `INSERT` into batches (e.g. 1,000 rows → four 250-row statements) |
| Transactions | **Remove `BEGIN TRANSACTION` / `COMMIT`** from a dump before importing |
| From local SQLite | `sqlite3 db.sqlite3 .dump > db.sql`, then strip the transaction statements |
| CPU limits | A very large import can trip the isolate's CPU limit — smaller chunks are the fix |

Export is also the honest way to get a local copy for plan experiments: export the schema,
import it locally, seed representative row counts, and iterate on indexes there before
proposing a migration.

---

## Optimising for rows read

Because rows read is the billing unit, D1 rewards optimisations stock SQLite treats as a
nice-to-have.

| Pattern | Rows-read effect |
|---|---|
| Index an aggregated column (`MAX`/`MIN` watermark) | Collapses a full scan to ~1 row — the biggest single win available |
| Add a selective `WHERE` a plain index can seek | Proportional reduction |
| Covering index for an unseekable predicate | Usually **no** rows-read change — latency only |
| Maintain a counter/summary row instead of `COUNT(*)` | O(n) scan → one row read |
| `LIMIT` with a matching index | Stops the scan early |
| Cache in KV or the Workers cache in front of D1 | Removes the read entirely |

Watermark pattern — the highest-value D1 refactor, from the measured session:

```sql
-- Before: full scan on every request
SELECT MAX(updated_at) FROM q_product;             -- 28.09 ms, 58,432 rows read

-- After: index the aggregated column
CREATE INDEX q_product_updated ON q_product(updated_at);
SELECT MAX(updated_at) FROM q_product;             -- 0.17 ms, 1 row read
```

`MAX(col)` over an indexed column is a walk to the end of the B-tree. That is the whole fix.

---

## Schema changes under a deploy gate

Creating an index on D1 is a **write to production**, applied through a migration and a
deploy — and deploys are maintainer-gated. A working session should:

1. Prove the payoff **read-only** using the technique in
   [`query-performance.md`](query-performance.md#the-read-only-proof-technique).
2. Write the migration file and commit it.
3. Capture a Time Travel bookmark so the maintainer has a named restore point.
4. **Stop.** Report the exact command and what it would change.

```bash
wrangler d1 time-travel info atdw-mirror              # record the restore point
wrangler d1 migrations apply atdw-mirror --local      # safe: local copy
wrangler d1 migrations apply atdw-mirror --remote     # MAINTAINER RUNS THIS
```

An unverified-until-deploy conclusion is a legitimate deliverable: "this index is projected
to cut the statement from 171 ms to ~7 ms based on a read-only proof; applying it needs a
gated deploy" beats applying it to find out.

And when the maintainer's `--remote` apply reports a timeout: the migration may have landed
anyway — verify schema state read-only before re-running
([`d1-production-patterns.md`](d1-production-patterns.md#migration-apply-can-time-out-yet-still-land)).

---

## libSQL and Turso

libSQL is a SQLite fork; Turso is its hosted service. Same planner, same SQL, different
operational envelope.

| Aspect | Note |
|---|---|
| Embedded replicas | Local read replica synced from the primary — reads local-fast, writes remote |
| Replica staleness | A read right after a write may not see it; sync or use read-your-writes support before assuming consistency |
| Connection model | HTTP/WebSocket to a server, embedded file, or embedded replica — pick deliberately; the performance profiles differ enormously |
| Extensions | libSQL adds features beyond stock SQLite (e.g. native vector support in recent versions). Verify against **your** server version — this moves |
| Pragmas | More of the pragma surface than D1, but a hosted primary still owns durability settings |
| Billing | Also reads-oriented — the rows-read discipline transfers directly |

The portability rule: **keep your SQL stock-SQLite unless you have a specific reason not
to.** A schema that runs unmodified on the CLI, on D1, and on Turso is worth real money in
optionality, and the vast majority of application SQL never needs a vendor extension.

---

## See also

- [`query-performance.md`](query-performance.md) — the engine-level analysis this builds on
- [`d1-production-patterns.md`](d1-production-patterns.md) — incident-derived procedures: timed-out migrations, `batch()` 0-row writes, the replication rollout
- [`hosts.md`](hosts.md) — the D1 driver API alongside the other hosts
- [`migration-patterns.md`](migration-patterns.md) — wrangler migrations and the deploy gate
- [`feature-modules.md`](feature-modules.md) — why FTS5 on D1 is recorded as unknown
- `cloudflare-ops` skill — Workers, bindings, wrangler configuration, deployment
