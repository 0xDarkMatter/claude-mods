---
name: sqlite-ops
description: "SQLite across every host and engine - query performance, concurrency, schema, feature modules, operations. Triggers on: sqlite, slow query, EXPLAIN QUERY PLAN, query plan, SCAN vs SEARCH, covering index, index not used, rows read, rows_read, sql_duration_ms, ANALYZE, sqlite_stat1, LIKE performance, database is locked, SQLITE_BUSY, WAL, busy_timeout, STRICT tables, type affinity, foreign_keys, VACUUM, integrity_check, fts5, trigram, json_extract, D1, cloudflare d1, wrangler d1, node:sqlite, better-sqlite3, bun:sqlite, aiosqlite, libsql, turso, migration, d1 batch, read replication, sessions api, d1 bookmark, migration timeout."
license: MIT
compatibility: "Guidance is engine-agnostic (SQLite 3.x semantics). Examples are labelled by host: sqlite3 CLI, Python sqlite3/aiosqlite, node:sqlite/better-sqlite3/bun:sqlite, Cloudflare D1 via wrangler, libSQL/Turso. scripts/eqp-triage.py needs Python 3.8+ (stdlib only)."
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "sql-ops, perf-ops, cloudflare-ops, postgres-ops"
---

# SQLite Operations

SQLite is one engine with many hosts. The **SQL semantics, query planner, and pragmas are
the same** whether you reach it through the `sqlite3` CLI, Python, `node:sqlite`,
better-sqlite3, Bun, Cloudflare D1, or libSQL/Turso — what differs is the *driver surface*
and the *operational envelope* (who owns the file, what a "connection" costs, whether you
can even run `PRAGMA`). Reason about the engine first; then check the host section for the
traps that differ.

```
Where does the problem live?
│
├─ A statement is slow, or scans too much
│  └─ EXPLAIN QUERY PLAN first, always → references/query-performance.md
│
├─ "database is locked" / SQLITE_BUSY / writers blocking readers
│  └─ WAL + busy_timeout + BEGIN IMMEDIATE → references/concurrency-durability.md
│
├─ Wrong data got in, or a constraint didn't fire
│  └─ Type affinity, STRICT, foreign_keys=OFF → references/schema-design.md
│
├─ Search / JSON / geo / analytics feature question
│  └─ FTS5, JSON, R-tree, window fns → references/feature-modules.md
│
├─ Running on a managed/edge engine (D1, Turso)
│  └─ references/d1-edge.md + references/hosts.md
│
└─ Corruption, size, backup, VACUUM
   └─ references/operations.md
```

## Measurement discipline (read this before optimising anything)

Most SQLite "optimisations" are unmeasured. Four rules, in order of how often they are
broken:

1. **Measure the statement, not the tool call.** An expensive aggregate that ships inside
   a batch another query was already sending costs *no extra round trip* and is therefore
   invisible to per-call timing — while still scanning the whole table on every request.
   Decompose multi-part statements and time each part separately.
2. **Report latency AND rows scanned.** They move independently. An optimisation can cut
   latency ~25x while leaving rows-read essentially unchanged (and on a billed engine like
   D1, rows read is the money metric — see `references/d1-edge.md`).
3. **Never trust wall-clock time from a CLI.** Process startup dominates. Use the engine's
   own reported duration (`.timer on` in the CLI, `meta.timings.sql_duration_ms` on D1).
4. **Take a median of 10+ runs and report the range.** First runs are cold. In one measured
   session a cold run hit 2,495 ms against a 171 ms median on the same statement — a
   1.5–1.7x first-run penalty was routine on multi-thousand-row reads.

```bash
# sqlite3 CLI: engine-reported timing, not shell time
sqlite3 app.db '.timer on' "SELECT count(*) FROM q_product WHERE org LIKE '%acme%';"

# What the planner thinks the data looks like (empty = ANALYZE never ran)
sqlite3 app.db 'SELECT * FROM sqlite_stat1;'
```

### Prove an index will help *before* you create it

The highest-leverage trick in this skill, and the one that keeps schema work inside a
deploy gate: **run the identical statement shape against a column an existing index
already covers.** Same table, same row count, same predicate shape — only the column
changes. The difference is your projected payoff, measured on live production data with
**zero schema writes**.

```sql
-- Hypothesis: a covering index on (org, product_id) makes this fast.
-- Unindexed control (what you have today):
SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%';

-- Proof shot: same shape, over a column an existing index already covers.
-- If this is fast, the index is worth writing. If it isn't, the index is not your problem.
SELECT DISTINCT org FROM q_product WHERE org LIKE '%acme%';
```

In the worked example below the proof shot returned 6.75 ms against a 171.83 ms control —
enough to justify the index without touching production schema.

## EXPLAIN QUERY PLAN — the 60-second read

`EXPLAIN QUERY PLAN` (EQP) is the first command for any slow statement. It is cheap, safe,
read-only, and available on every host that lets you run arbitrary SQL.

```sql
EXPLAIN QUERY PLAN
SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%';
```

| Plan line | Means | Verdict |
|---|---|---|
| `SEARCH t USING INDEX ix (col=?)` | B-tree seek, touches matching rows only | Best case |
| `SEARCH t USING COVERING INDEX ix` | Seek, and every needed column is in the index — table never read | Best case |
| `SCAN t USING COVERING INDEX ix` | Full pass, but over narrow index entries, not wide rows | Often fine — see below |
| `SCAN t USING INDEX ix` | Full pass over the index **and** a row fetch per hit | Suspicious: the index is buying little |
| `SCAN t` | Full table scan | Fix it, unless the table is tiny |
| `USE TEMP B-TREE FOR ORDER BY` | Sorting because no index supplies the order | Cost signal |
| `USE TEMP B-TREE FOR GROUP BY` | Same, for grouping | Cost signal |
| `CORRELATED SCALAR SUBQUERY` | Subquery re-executed per outer row | Usually the whole problem |

**The distinction that matters most:** `SCAN … USING COVERING INDEX` is not a failure.
A covering scan reads narrow index entries instead of paging in wide rows, which is exactly
how you make an *unseekable* predicate fast.

**Deep dive**: `./references/query-performance.md` — index design, column order, partial and
expression indexes, ANALYZE/`sqlite_stat1`, and the full catalogue of planner defeats.

### The unseekable-predicate trap (worked example)

A leading-wildcard `LIKE '%x%'` can **never** use a B-tree — SQLite optimises `LIKE` only
for an anchored prefix (`'x%'`). So a plain index on that column changes nothing, people
observe no improvement, and conclude "indexing didn't help here". The index wasn't wrong;
the *shape* was. The fix is to make the scan **covering**, so the unavoidable full pass
reads narrow index entries instead of wide rows.

```sql
-- Column order is load-bearing: FILTERED column first, PROJECTED column second.
CREATE INDEX q_product_org_product ON q_product(org, product_id);
```

> **Worked example — one database, not a constant.** Measured 2026-08-04 against a live
> Cloudflare D1 (`atdw-mirror`, region OC, colo SYD), 12 runs each, median of server-side
> `sql_duration_ms`; 73-column table, 58k rows.
> Before: `SCAN q_product USING INDEX q_product_org`, **171.83 ms**, 60,736 rows read.
> The identical statement shape over an already-covered column: **6.75 ms**, 58,433 rows
> read. **~25x faster with rows-read essentially unchanged** — proof that the win came from
> row width, not from touching fewer rows. Your table's numbers will differ; the *shape* of
> the result is what transfers.
>
> Two further findings from the same session worth internalising:
> - Once the covering index existed, SQLite **dropped the `GROUP BY` temp B-tree by itself**.
>   A hand-rewrite to avoid the grouping measured 5.99 ms vs 5.85 ms — noise. Don't
>   hand-optimise around a temp B-tree until you have re-read the plan post-index.
> - An unindexed `MAX()` riding inside a batch another query was already sending cost
>   **28.09 ms and 58,432 rows scanned on every response across four tools**, while the
>   statement without it cost 0.17 ms / 2 rows. The same `MAX()` over an indexed column:
>   0.17 ms / 1 row. It never showed up in per-query timing because it added no round trip.

### Verify the planner's choice with and without statistics

A covering index may only be *chosen* once `ANALYZE` has populated `sqlite_stat1` — and
many hosted engines never run `ANALYZE` for you. Test both states before you rely on it:

```sql
ANALYZE;                                  -- populate sqlite_stat1
EXPLAIN QUERY PLAN SELECT ...;            -- record the plan

DELETE FROM sqlite_stat1;                 -- simulate a never-analyzed database
ANALYZE sqlite_master;                    -- force the planner to reload (now-empty) stats
EXPLAIN QUERY PLAN SELECT ...;            -- same plan? then you are safe either way
```

In the worked example the covering index was chosen in **both** states — verified, not
assumed. Do the same check rather than inheriting that result.

## Index design in one table

| Predicate shape | Indexable? | What to build |
|---|---|---|
| `col = ?`, `col IN (…)`, `col > ?`, `BETWEEN` | Yes | B-tree on `col` |
| `a = ? AND b = ?` | Yes | Composite `(a, b)` — equality columns first |
| `a = ? ORDER BY b` | Yes | Composite `(a, b)` — kills the temp B-tree |
| `col LIKE 'x%'` (anchored) | Yes, if `col` is TEXT with `BINARY` collation | B-tree on `col` |
| `col LIKE '%x%'` (leading wildcard) | **No seek possible** | Make the scan covering, or use FTS5 trigram |
| `lower(col) = ?` | Not on a plain index | Expression index `ON t(lower(col))` |
| `status = 'open'` where 2% of rows qualify | Yes | Partial index `WHERE status = 'open'` |
| `json_extract(doc,'$.k') = ?` | Not on a plain index | Expression index, or generated column + index |

**Rules that repay themselves:** put the *filtered* column first and the *projected*
column second in a covering index; index the column, never a function of it (unless it is
an expression index); and every index you add taxes every write — audit before adding.

## Concurrency and durability — the 80/20

| Symptom | Cause | Fix |
|---|---|---|
| `SQLITE_BUSY` | Another **connection** holds a lock; yours gave up waiting | `PRAGMA busy_timeout = 5000;` and keep write transactions short |
| `SQLITE_LOCKED` | Conflict **within the same connection** (or a shared cache) | Fix the code — a retry loop will spin forever |
| "database is locked" mid-transaction | `BEGIN` (DEFERRED) read that later writes → upgrade deadlock, **not retryable** | `BEGIN IMMEDIATE` for any transaction that will write |
| Readers blocked by a writer | Rollback journal mode | `PRAGMA journal_mode = WAL;` (persistent, set once) |
| `-wal` file grows without bound | Long-lived reader pins the checkpoint | Close/refresh readers; `PRAGMA wal_checkpoint(TRUNCATE);` |

```sql
PRAGMA journal_mode = WAL;      -- persistent; survives reconnect
PRAGMA busy_timeout = 5000;     -- per-connection; set on EVERY connection
PRAGMA foreign_keys = ON;       -- per-connection, OFF by default — see below
PRAGMA synchronous = NORMAL;    -- safe with WAL; FULL only if you fear power loss
```

**Deep dive**: `./references/concurrency-durability.md` — WAL internals, the
DEFERRED-upgrade deadlock, `synchronous` levels, checkpoint starvation, multi-process access.

## Schema — the three silent bugs

1. **`PRAGMA foreign_keys` is OFF by default.** Per connection, every connection. Your
   `REFERENCES` clauses parse, are stored, and do nothing. This is the classic silent
   data-integrity bug in SQLite applications.
2. **Type affinity is not a type.** A `TEXT` column will happily store an integer; a
   declared type is a *suggestion* about conversion. Use **`STRICT` tables** (SQLite 3.37+)
   when you want a declared type enforced.
3. **`ALTER TABLE` is limited.** Adding a column and renaming are supported; dropping,
   retyping, and changing constraints need the 12-step recreate dance.

```sql
CREATE TABLE product (
    id       INTEGER PRIMARY KEY,
    org      TEXT NOT NULL,
    price    REAL NOT NULL,
    doc      TEXT,
    -- indexable projection of a JSON field
    sku      TEXT GENERATED ALWAYS AS (json_extract(doc, '$.sku')) VIRTUAL
) STRICT;
```

**Deep dive**: `./references/schema-design.md` (affinity, STRICT, generated columns,
`WITHOUT ROWID`, constraints) and `./references/migration-patterns.md` (the 12-step ALTER
dance, versioned migration runners).

## Feature modules at a glance

| Need | Reach for | Note |
|---|---|---|
| Substring / fuzzy text search | FTS5 with the `trigram` tokenizer | The real answer to `LIKE '%x%'` at scale |
| Word/phrase search with ranking | FTS5 + `bm25()` | External-content table avoids duplicating the corpus |
| Semi-structured documents | `json_extract` / `->` / `->>`, JSONB (3.45+) | Index via generated column or expression index |
| Bounding-box / interval overlap | R-tree virtual table | Compile-time module; check availability |
| Running totals, ranking, gaps | Window functions (3.25+) | Same syntax as PostgreSQL |
| Insert-or-update | `ON CONFLICT … DO UPDATE` (3.24+) | `excluded.col` refers to the proposed row |
| Read back what you wrote | `RETURNING` (3.35+) | Makes atomic claim-a-job patterns single-statement |

**Deep dive**: `./references/feature-modules.md`.

## Hosts

The engine is the same; the envelope is not.

| Host | Connection model | Watch out for |
|---|---|---|
| `sqlite3` CLI | Direct file | `.timer on` for real timings; `.mode`/`.headers` for output |
| Python `sqlite3` | Direct file, per-connection pragmas | Implicit transaction handling; `check_same_thread` |
| Python `aiosqlite` | Thread-backed async wrapper | Still one writer; see `./references/async-patterns.md` |
| `node:sqlite` | Synchronous, built into Node | No external dependency; API still stabilising |
| `better-sqlite3` | Synchronous, native addon | Fastest Node option; prepared statements are the unit of reuse |
| `bun:sqlite` | Synchronous, built into Bun | API close to better-sqlite3, not identical |
| **Cloudflare D1** | HTTP/RPC to a managed SQLite | Billed on **rows read**; 100-parameter cap; no `PRAGMA` surface |
| libSQL / Turso | Server or embedded replica | Replica staleness; syntax extensions beyond stock SQLite |

**Deep dive**: `./references/hosts.md` for per-host connection recipes and traps.

On D1 specifically, three platform features have no stock-SQLite equivalent and are the most
commonly missed:

```bash
wrangler d1 insights <db> --sort-type=sum --sort-by=reads --limit=10   # rank REAL queries by cost
wrangler d1 time-travel info <db>                                      # 30-day point-in-time restore point
# Sessions API (env.DB.withSession(bookmark)) - read replicas, sequential consistency
```

`./references/d1-edge.md` covers those plus the rows-read economics, the verified limits
table, the error catalogue, and import/export. For the production incident patterns —
a timed-out `migrations apply --remote` that landed anyway, `batch()` treating a 0-row
scoped UPDATE as success, and the opt-in-to-replica rollout shape for read replication —
see `./references/d1-production-patterns.md`.

## Operations

```bash
sqlite3 app.db 'PRAGMA quick_check;'        # fast structural check
sqlite3 app.db 'PRAGMA integrity_check;'    # full check — slow on big DBs
sqlite3 app.db "VACUUM INTO 'backup.db';"   # consistent backup, no downtime, defragmented
sqlite3 app.db '.dump' > backup.sql         # portable text backup
sqlite3 app.db 'PRAGMA optimize;'           # run before closing a long-lived connection
```

**Never** copy a live database file with `cp` while a writer is active — use
`VACUUM INTO`, the backup API, or `.dump`.

**Deep dive**: `./references/operations.md` — corruption causes and recovery, `VACUUM` vs
`VACUUM INTO`, page/cache sizing, size analysis.

## Triage script

`scripts/eqp-triage.py` reads an `EXPLAIN QUERY PLAN` result — either by running the
statement against a database, or from piped plan text — and classifies each line by
severity with a fix hint. Exits `10` when it finds something (the domain signal), `0`
when the plan is clean.

```bash
# Run against a database file (uses Python's bundled sqlite3 — no external binary needed)
python3 scripts/eqp-triage.py --db app.db \
  --sql "SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%'"

# Triage a plan captured elsewhere (D1, a log, a colleague's paste)
wrangler d1 execute atdw-mirror --remote --json \
  --command "EXPLAIN QUERY PLAN SELECT product_id FROM q_product WHERE org LIKE '%acme%'" \
  | python3 scripts/eqp-triage.py

# Machine-readable findings
python3 scripts/eqp-triage.py --db app.db --sql "SELECT ..." --json | jq '.data[]'
```

## Gotchas

| Mistake | Why it bites | Fix |
|---|---|---|
| Adding an index for `LIKE '%x%'` | Leading wildcard can never seek | Covering index, or FTS5 trigram |
| Timing with a shell stopwatch | CLI/driver startup dominates | Engine-reported duration; median of 10+ |
| Timing the tool call, not the statement | Piggy-backed statements are invisible | Decompose and time each part |
| Assuming `REFERENCES` is enforced | `foreign_keys` is OFF per connection | `PRAGMA foreign_keys = ON` on every connection |
| Assuming a declared type is enforced | Affinity, not typing | `STRICT` tables |
| Retrying `SQLITE_LOCKED` | Same-connection conflict never clears | Fix the code path |
| `BEGIN` then write | DEFERRED→write upgrade deadlocks and is not retryable | `BEGIN IMMEDIATE` |
| `cp` on a live database | Torn copy | `VACUUM INTO` / backup API |
| `SELECT *` | Defeats covering indexes; widens every row read | Project only what you need |
| `VACUUM` to "speed things up" | Rewrites the whole file, needs 2x space, holds a lock | `PRAGMA optimize` / targeted index work |
| Trusting one cold run | 1.5–1.7x first-run penalty is routine | Median of 10+, report the range |
| Inlining literals to dodge a parameter cap | That is how injection happens | Chunk the work; keep bound parameters |
| Re-running a timed-out remote migration | The apply may have landed; the error was about the response | Verify schema state read-only first — `./references/d1-production-patterns.md` |
| Reading a committed `batch()` as per-statement success | A conditional UPDATE matching 0 rows is not an error | Check `meta.changes`; 0 on a scoped write = 403/conflict |

## Reference files

| Reference | Load when |
|---|---|
| `./references/query-performance.md` | Any slow statement: EQP, index design, ANALYZE, planner defeats, measurement method |
| `./references/d1-edge.md` | Cloudflare D1: rows-read economics, `d1 insights`, Sessions API/replication, Time Travel, limits, errors |
| `./references/d1-production-patterns.md` | Running D1 in production: verifying a timed-out migration, `batch()` 0-row write verification, the opt-in-to-replica replication rollout |
| `./references/concurrency-durability.md` | Locking, WAL, busy_timeout, transaction modes, checkpointing, durability |
| `./references/schema-design.md` | Affinity, STRICT, foreign keys, generated columns, `WITHOUT ROWID`, constraints |
| `./references/schema-patterns.md` | Ready-made table designs: state, cache, event log, queue, session, dedup |
| `./references/migration-patterns.md` | Versioned migrations, the 12-step ALTER dance, host-specific runners |
| `./references/feature-modules.md` | FTS5, JSON/JSONB, R-tree, window functions, upsert, RETURNING |
| `./references/hosts.md` | Per-host connection recipes and driver traps (Python, Node, Bun, D1, libSQL) |
| `./references/async-patterns.md` | Python `aiosqlite` depth: async CRUD, batching, pooling |
| `./references/operations.md` | Integrity checks, corruption recovery, VACUUM, backups, size and page tuning |
| `./references/testing.md` | In-memory vs file databases, fixtures, deterministic seeding, migration tests |

## See also

| Skill | When to combine |
|---|---|
| `sql-ops` | Vendor-neutral SQL: CTEs, window functions, JOIN strategy |
| `perf-ops` | The wider performance workflow — profiling, load testing, before/after protocol |
| `cloudflare-ops` | Workers, bindings, and deployment around a D1 database |
| `postgres-ops` | When the workload has outgrown SQLite's single-writer model |
| `python-database-ops` | SQLAlchemy / ORM layers over SQLite |
