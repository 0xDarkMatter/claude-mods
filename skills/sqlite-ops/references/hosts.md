# SQLite Hosts

One engine, many drivers. The SQL, the planner, and the pragmas are identical everywhere —
this file covers the **driver surface** and the traps that differ per host.

## Contents

- [The portable connection baseline](#the-portable-connection-baseline)
- [sqlite3 CLI](#sqlite3-cli)
- [Python: sqlite3](#python-sqlite3)
- [Python: aiosqlite](#python-aiosqlite)
- [node:sqlite](#nodesqlite)
- [better-sqlite3](#better-sqlite3)
- [bun:sqlite](#bunsqlite)
- [Cloudflare D1](#cloudflare-d1)
- [libSQL / Turso](#libsql--turso)
- [Host comparison](#host-comparison)

---

## The portable connection baseline

Every host that gives you a real connection should apply the same four pragmas on **every
connection** (only `journal_mode` is persistent — the rest are per-connection and reset each
time). Rationale in [`concurrency-durability.md`](concurrency-durability.md).

```sql
PRAGMA journal_mode = WAL;      -- once per database (persistent)
PRAGMA busy_timeout = 5000;     -- every connection
PRAGMA foreign_keys = ON;       -- every connection
PRAGMA synchronous = NORMAL;    -- every connection
```

The single most common bug across all hosts below is setting these once at startup and
missing the connections a pool or framework creates later.

---

## sqlite3 CLI

```bash
sqlite3 app.db                     # interactive
sqlite3 app.db 'SELECT 1;'         # one-shot
sqlite3 -readonly app.db 'SELECT 1;'
```

| Dot command | Purpose |
|---|---|
| `.tables` / `.schema t` / `.indexes t` | Structure |
| `.timer on` | **Engine-reported timing** — the only honest CLI measurement |
| `.stats on` | VM steps, sorts, full-scan steps per statement |
| `.mode box\|json\|csv\|markdown` | Output format (`box` for reading, `json` for piping) |
| `.headers on` | Column names |
| `.once file` / `.output file` | Redirect the next / all results |
| `.import --csv data.csv t` | Bulk load |
| `.dump` / `.read f.sql` | Text backup / run a script |
| `.expert` | Suggests indexes for a statement (build-dependent) |
| `.eqp on` | Auto-print the query plan for every statement |

```bash
# Export
sqlite3 app.db -header -csv 'SELECT * FROM product;' > product.csv
sqlite3 app.db -json 'SELECT * FROM product LIMIT 5;' | jq '.[0]'

# Pragmas in a one-shot invocation (they apply to that connection only)
sqlite3 app.db 'PRAGMA foreign_keys=ON; DELETE FROM author WHERE id=1;'
```

**Trap:** the CLI does not enable foreign keys for you. A manual `DELETE` from the CLI can
leave orphans in a database whose application always sets the pragma.

---

## Python: sqlite3

Standard library. The main traps are transaction handling and thread affinity.

```python
import sqlite3

def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.row_factory = sqlite3.Row          # dict-like access by column name
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA synchronous = NORMAL")
    return conn
```

| Trap | Detail |
|---|---|
| Implicit transactions | By default the module opens a transaction before DML and commits on `commit()`. `isolation_level=None` turns this off so **you** write `BEGIN IMMEDIATE` explicitly — strongly preferred (see [the upgrade deadlock](concurrency-durability.md#transaction-modes-and-the-upgrade-deadlock)) |
| DDL and autocommit | Older Pythons implicitly committed before DDL; explicit control avoids version-dependent surprises |
| `check_same_thread=False` | Lets a connection cross threads, but does **not** make it thread-safe — you must serialise access yourself. One connection per thread is the safe pattern |
| `timeout=` | This is `busy_timeout` in **seconds**, set at connect time |
| `executemany` | Use for bulk inserts; wrap in one explicit transaction for the real win |
| `detect_types` | Legacy converters; prefer explicit conversion in your own code |
| Python 3.12+ | Warns on deprecated default adapters for `date`/`datetime` — store ISO text yourself |

```python
# Explicit transaction with retry-friendly semantics
conn.execute("BEGIN IMMEDIATE")
try:
    conn.executemany("INSERT INTO event (kind, payload) VALUES (?, ?)", rows)
    conn.execute("COMMIT")
except Exception:
    conn.execute("ROLLBACK")
    raise
```

```python
# Read the plan from Python — no external binary needed
for row in conn.execute("EXPLAIN QUERY PLAN SELECT * FROM event WHERE kind = ?", ("login",)):
    print(row["detail"])
```

`scripts/eqp-triage.py` in this skill uses exactly this path, which is why it needs no
`sqlite3` binary on PATH.

---

## Python: aiosqlite

A thread-pool wrapper around `sqlite3` with an async API. It does **not** make SQLite
concurrent — there is still one writer, and each connection still occupies a worker thread.

```python
import aiosqlite

async def connect(path: str) -> aiosqlite.Connection:
    conn = await aiosqlite.connect(path, isolation_level=None)
    conn.row_factory = aiosqlite.Row
    await conn.execute("PRAGMA busy_timeout = 5000")
    await conn.execute("PRAGMA foreign_keys = ON")
    return conn
```

| Consideration | Guidance |
|---|---|
| When it helps | Keeps an async event loop unblocked during disk I/O |
| When it doesn't | CPU-bound queries; write-heavy workloads (still serialised) |
| Pooling | A small pool of read connections + **one** dedicated write connection is the pattern that works |
| Long transactions | Especially harmful here — an awaited call inside a transaction can hold a lock across arbitrary scheduling delays |

**Deep dive:** [`async-patterns.md`](async-patterns.md) — async CRUD, batching, pooling.

---

## node:sqlite

Built into modern Node, synchronous, zero dependencies.

```js
import { DatabaseSync } from "node:sqlite";

const db = new DatabaseSync("app.db");
db.exec("PRAGMA journal_mode = WAL");
db.exec("PRAGMA busy_timeout = 5000");
db.exec("PRAGMA foreign_keys = ON");

const insert = db.prepare("INSERT INTO event (kind, payload) VALUES (?, ?)");
insert.run("login", JSON.stringify({ user: 1 }));

const rows = db.prepare("SELECT * FROM event WHERE kind = ?").all("login");
const one  = db.prepare("SELECT * FROM event WHERE id = ?").get(1);
```

| Note | Detail |
|---|---|
| Synchronous by design | Blocks the event loop — fine for fast statements, bad for long scans |
| API stability | Newer than the alternatives; check your Node version's docs before relying on a specific method |
| No native async | For long-running work use a worker thread, not a promise wrapper |
| Named parameters | Supported (`@name`/`:name`), style varies by version — verify against your Node |

Use it when you want no native build step and no dependency. Use better-sqlite3 when you
want the most mature Node API and the broadest feature surface.

---

## better-sqlite3

The mature Node option. Synchronous, native addon, fastest of the Node choices.

```js
import Database from "better-sqlite3";

const db = new Database("app.db");
db.pragma("journal_mode = WAL");
db.pragma("busy_timeout = 5000");
db.pragma("foreign_keys = ON");

// Prepared statements are the unit of reuse - prepare ONCE, at module scope
const findByKind = db.prepare("SELECT * FROM event WHERE kind = ?");
const rows = findByKind.all("login");

// Transactions: the wrapper handles BEGIN/COMMIT/ROLLBACK
const insertMany = db.transaction((events) => {
  for (const e of events) insertOne.run(e.kind, e.payload);
});
insertMany(events);          // one transaction, one fsync
```

| Feature | Note |
|---|---|
| `.transaction(fn)` | Wraps in `BEGIN`/`COMMIT`; use `.immediate(...)` for write transactions |
| Statement reuse | Re-preparing in a loop is the #1 performance mistake with this driver |
| `.iterate()` | Streams rows without materialising the whole result |
| `.pluck()` / `.raw()` | Single-column / array-row modes; avoid object allocation in hot loops |
| Native build | Needs a prebuilt binary or a toolchain — the cost of admission |
| WASM alternatives | `sql.js`, `wa-sqlite` for browsers/edge — different performance envelope entirely |

Synchronous is a **feature** here: it eliminates a class of race conditions, and SQLite reads
from page cache are fast enough that the event-loop cost is usually negligible. Measure
before assuming you need async.

---

## bun:sqlite

Built into Bun. API is close to better-sqlite3 but **not identical** — porting code between
them needs review, not just a find-and-replace on the import.

```js
import { Database } from "bun:sqlite";

const db = new Database("app.db");
db.run("PRAGMA journal_mode = WAL");
db.run("PRAGMA busy_timeout = 5000");
db.run("PRAGMA foreign_keys = ON");

const q = db.query("SELECT * FROM event WHERE kind = ?");
const rows = q.all("login");
const one  = q.get("login");

const tx = db.transaction((rows) => { for (const r of rows) ins.run(r.kind, r.payload); });
tx(rows);
```

Differences worth checking when porting: `query()` caches prepared statements where
better-sqlite3 expects you to hold the statement yourself; `.run()`/`.exec()` semantics
differ; class-mapping (`.as(Class)`) is Bun-specific.

---

## Cloudflare D1

Managed, accessed over HTTP/RPC. No file, no `PRAGMA` surface, billed on rows read.

```js
export default {
  async fetch(request, env) {
    const { results, meta } = await env.DB
      .prepare("SELECT id, name FROM product WHERE org = ?")
      .bind("acme")
      .all();
    // meta.rows_read and meta.timings.sql_duration_ms are the numbers that matter
    return Response.json({ results, cost: meta.rows_read });
  },
};
```

| API | Use |
|---|---|
| `.all()` | All rows plus `meta` |
| `.first()` | First row, or a single column with `.first("col")` |
| `.run()` | Writes; returns `meta` only |
| `.raw()` | Arrays instead of objects — cheaper for wide results |
| `env.DB.batch([...])` | Multiple statements, one round trip, implicit transaction |

| Constraint | Detail |
|---|---|
| Bound parameters | Capped at **100 per statement** — chunk, don't inline literals |
| Connection pragmas | Not available; the platform owns journal mode, durability, timeouts |
| Introspection | `sqlite_version()` and `pragma_module_list` refused with `SQLITE_AUTH` |
| Interactive transactions | Not supported — use `batch()` |
| Billing | Rows read, not time |

**Deep dive:** [`d1-edge.md`](d1-edge.md).

---

## libSQL / Turso

A SQLite fork plus a hosted service. Three connection modes with very different profiles:

```js
import { createClient } from "@libsql/client";

// 1. Remote server
const remote = createClient({ url: "libsql://db.turso.io", authToken: TOKEN });

// 2. Local file (plain SQLite semantics)
const local = createClient({ url: "file:local.db" });

// 3. Embedded replica: local reads, remote writes, background sync
const replica = createClient({
  url: "file:replica.db",
  syncUrl: "libsql://db.turso.io",
  authToken: TOKEN,
});
await replica.sync();     // pull latest before a read that must be fresh
```

| Consideration | Note |
|---|---|
| Embedded replica staleness | A read right after a write may not see it — call `sync()` or use the client's read-your-writes support |
| Mode choice | Remote = simple, network-latency per query. Replica = fast reads, sync complexity. Pick deliberately |
| Extensions | libSQL adds features beyond stock SQLite (e.g. native vector types in recent versions) — verify against **your** server version; this moves |
| Portability | Keep SQL stock-SQLite unless you have a concrete reason not to |
| Billing | Reads-oriented, like D1 — the rows-read discipline transfers |

---

## Host comparison

| | Real file | `PRAGMA` control | Sync/async | Transactions | Billed on reads |
|---|---|---|---|---|---|
| `sqlite3` CLI | Yes | Full | Sync | Full | No |
| Python `sqlite3` | Yes | Full | Sync | Full | No |
| Python `aiosqlite` | Yes | Full | Async (thread-backed) | Full | No |
| `node:sqlite` | Yes | Full | Sync | Full | No |
| better-sqlite3 | Yes | Full | Sync | Full | No |
| `bun:sqlite` | Yes | Full | Sync | Full | No |
| Cloudflare D1 | No | None | Async | `batch()` only | **Yes** |
| libSQL / Turso | Depends on mode | Partial | Async | Full (server mode) | **Yes** |

### Choosing

| Situation | Host |
|---|---|
| Ad-hoc investigation, migrations, exports | `sqlite3` CLI |
| Python service, sync | stdlib `sqlite3` |
| Python service, async framework | `aiosqlite` (one write connection + a read pool) |
| Node, no native build allowed | `node:sqlite` |
| Node, maximum maturity and speed | better-sqlite3 |
| Bun runtime | `bun:sqlite` |
| Cloudflare Workers | D1 |
| Multi-region reads, embedded replicas | libSQL / Turso |
| Many concurrent writers, large dataset | **Not SQLite** — see `postgres-ops` |

---

## See also

- [`concurrency-durability.md`](concurrency-durability.md) — why the pragma baseline is what it is
- [`d1-edge.md`](d1-edge.md) — the managed-engine chapter in full
- [`async-patterns.md`](async-patterns.md) — Python async depth
- [`testing.md`](testing.md) — per-host test database setup
