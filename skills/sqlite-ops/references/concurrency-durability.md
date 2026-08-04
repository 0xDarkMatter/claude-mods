# SQLite Concurrency and Durability

Engine-agnostic. The locking model, journal modes, and transaction semantics below are
properties of SQLite itself and behave identically in every host that gives you a real
connection. Managed engines (D1) hide most of this — see [`d1-edge.md`](d1-edge.md).

## Contents

- [The one-writer model](#the-one-writer-model)
- [Journal modes: WAL vs rollback](#journal-modes-wal-vs-rollback)
- [SQLITE_BUSY vs SQLITE_LOCKED](#sqlite_busy-vs-sqlite_locked)
- [busy_timeout](#busy_timeout)
- [Transaction modes and the upgrade deadlock](#transaction-modes-and-the-upgrade-deadlock)
- [Durability: the synchronous pragma](#durability-the-synchronous-pragma)
- [WAL checkpointing and file growth](#wal-checkpointing-and-file-growth)
- [Connection pragma baseline](#connection-pragma-baseline)
- [Multi-process and networked filesystems](#multi-process-and-networked-filesystems)
- [Retry patterns](#retry-patterns)

---

## The one-writer model

SQLite allows **many concurrent readers and exactly one writer** per database. There is no
row-level locking and no MVCC beyond WAL's single-version snapshot. Almost every
concurrency problem in SQLite is a consequence of that sentence.

| Reality | Implication |
|---|---|
| One writer at a time, database-wide | Write transactions must be **short**; never hold one across network I/O or user think-time |
| Readers don't block readers | Read concurrency scales freely |
| In WAL, readers don't block the writer and the writer doesn't block readers | WAL is the default recommendation for anything concurrent |
| Locks are per **connection**, not per thread or per statement | Two connections in the same process contend exactly like two processes |

**Design consequence:** batch writes. A thousand single-statement transactions cost a
thousand lock acquisitions and (depending on `synchronous`) a thousand fsyncs; the same
thousand statements inside one transaction cost one of each.

```sql
BEGIN IMMEDIATE;
  INSERT INTO events (kind, payload) VALUES (?, ?);
  -- ... 999 more
COMMIT;
```

---

## Journal modes: WAL vs rollback

```sql
PRAGMA journal_mode = WAL;      -- returns 'wal' on success; PERSISTENT (stored in the file)
PRAGMA journal_mode;            -- read current mode
```

| Mode | Readers during write | Crash safety | Notes |
|---|---|---|---|
| `DELETE` (default) | **Blocked** | Safe | Journal file created and deleted per transaction |
| `TRUNCATE` | Blocked | Safe | Journal truncated rather than deleted — slightly faster |
| `PERSIST` | Blocked | Safe | Journal header zeroed rather than deleted |
| `WAL` | **Concurrent** | Safe | Recommended default for concurrent workloads |
| `MEMORY` | Blocked | **Unsafe** — crash corrupts | Only for throwaway data |
| `OFF` | Blocked | **Unsafe** — no rollback at all | Only for import scratch databases |

**WAL is persistent**: set it once and it survives reconnects and restarts, because the mode
is recorded in the database header. It does *not* need to be set on every connection —
unlike `busy_timeout` and `foreign_keys`, which do.

**WAL trade-offs to know before choosing it:**

- Creates two extra files: `-wal` (the log) and `-shm` (shared memory index). Backups must
  account for them, or use `VACUUM INTO`.
- Requires shared memory, so it **does not work on most network filesystems** (see below).
- A single database can't be in WAL mode for some connections and rollback for others.
- Readers see a consistent snapshot from the moment their transaction started.

---

## SQLITE_BUSY vs SQLITE_LOCKED

These look alike and mean opposite things. Getting them confused produces retry loops that
spin forever.

| Error | Meaning | Retryable? |
|---|---|---|
| `SQLITE_BUSY` (5) | Another **connection** holds a conflicting lock and yours timed out waiting | **Yes** — back off and retry |
| `SQLITE_LOCKED` (6) | Conflict **inside your own connection** (or a shared-cache sibling) — e.g. writing to a table you are mid-scan on | **No** — retrying cannot help; fix the code |
| `SQLITE_BUSY_SNAPSHOT` | WAL: your read snapshot is too old to upgrade to a write | Yes, but restart the whole transaction |

`SQLITE_LOCKED` most often means a cursor is still open on the table being modified. Read
the rows out fully (materialise the list) before writing to the same table.

```python
# SQLITE_LOCKED risk: writing while iterating the same table
for row in conn.execute("SELECT id FROM job WHERE status='pending'"):
    conn.execute("UPDATE job SET status='running' WHERE id=?", (row[0],))   # risky

# Safe: materialise first
ids = [r[0] for r in conn.execute("SELECT id FROM job WHERE status='pending'").fetchall()]
for i in ids:
    conn.execute("UPDATE job SET status='running' WHERE id=?", (i,))
```

---

## busy_timeout

```sql
PRAGMA busy_timeout = 5000;   -- milliseconds; per CONNECTION, not persistent
```

Without it, a lock conflict raises `SQLITE_BUSY` **immediately**. With it, SQLite sleeps and
retries internally for up to the timeout before giving up. This single pragma removes the
majority of "database is locked" reports.

| Setting | Suitable for |
|---|---|
| 0 (default) | Nothing concurrent — you will see spurious BUSY |
| 1,000–5,000 ms | Typical application default |
| 30,000 ms | Batch/migration jobs where waiting beats failing |

**It must be set on every connection**, including short-lived ones and those created by
connection pools. It is not stored in the database file.

Caveat: `busy_timeout` does **not** rescue the DEFERRED-upgrade deadlock below. That case
is architecturally unresolvable by waiting, and SQLite returns `SQLITE_BUSY` instantly
regardless of the timeout.

---

## Transaction modes and the upgrade deadlock

```sql
BEGIN;             -- == BEGIN DEFERRED: no lock taken until the first statement
BEGIN IMMEDIATE;   -- takes a write lock now
BEGIN EXCLUSIVE;   -- takes an exclusive lock now (rarely needed in WAL)
```

**The footgun:** `BEGIN DEFERRED` followed by a read and then a write must *upgrade* from a
read lock to a write lock. If another connection wrote to the database between your read and
your upgrade, SQLite cannot give you a consistent view and returns `SQLITE_BUSY`
**immediately, ignoring `busy_timeout`** — because waiting could deadlock two connections
each holding a read lock and each wanting to upgrade.

```sql
-- Deadlock-prone: read, then write, inside a DEFERRED transaction
BEGIN;
  SELECT balance FROM account WHERE id = 1;
  UPDATE account SET balance = balance - 10 WHERE id = 1;   -- may fail with BUSY, instantly
COMMIT;

-- Correct: declare the intent to write up front
BEGIN IMMEDIATE;
  SELECT balance FROM account WHERE id = 1;
  UPDATE account SET balance = balance - 10 WHERE id = 1;
COMMIT;
```

**Rule: if a transaction will write at any point, open it with `BEGIN IMMEDIATE`.** The cost
is serialising writers slightly earlier; the benefit is that `busy_timeout` now actually
applies and the failure mode becomes a retryable wait instead of an instant error.

Read-only transactions should stay `DEFERRED` — they take no write lock and never block
anyone.

### Savepoints

Nested, named transaction points — useful for partial rollback inside a long operation.

```sql
BEGIN IMMEDIATE;
  SAVEPOINT step1;
    -- risky work
  ROLLBACK TO step1;    -- undo just this step, transaction still open
  RELEASE step1;
COMMIT;
```

---

## Durability: the synchronous pragma

```sql
PRAGMA synchronous = NORMAL;   -- per connection
```

| Level | Meaning | Risk on power loss / OS crash |
|---|---|---|
| `OFF` (0) | Never fsync | **Database can be corrupted** |
| `NORMAL` (1) | Fsync at checkpoints only (in WAL) | With WAL: recent commits may be lost, **file stays consistent** |
| `FULL` (2) | Fsync every commit | No committed data lost |
| `EXTRA` (3) | `FULL` plus the directory sync | Marginally stronger |

**`NORMAL` with WAL is the standard production choice**: it is the large majority of the
performance win with no corruption risk — only the possibility of losing the last few
committed transactions if the machine loses power. Application crashes are safe at `NORMAL`;
it is only OS-level or power failure that can lose committed data.

Use `FULL` when a lost commit is unacceptable (financial ledgers, anything with an external
side effect keyed to the write). Never use `OFF` on data you care about; it is for
regenerable scratch databases only.

---

## WAL checkpointing and file growth

The `-wal` file accumulates committed pages until a **checkpoint** moves them back into the
main database. By default SQLite auto-checkpoints when the WAL passes ~1000 pages (~4 MB at
the default page size).

```sql
PRAGMA wal_autocheckpoint = 1000;        -- pages; 0 disables auto-checkpointing
PRAGMA wal_checkpoint(PASSIVE);          -- checkpoint what it can, never blocks
PRAGMA wal_checkpoint(FULL);             -- wait for readers, checkpoint everything
PRAGMA wal_checkpoint(TRUNCATE);         -- FULL, then shrink the -wal file to zero
```

**Why a `-wal` file grows without bound:** a checkpoint cannot advance past the oldest
active reader's snapshot. One long-lived read transaction — an idle connection that opened a
transaction and never committed, a paginated report held open, an ORM session left in
transaction — pins the WAL forever.

| Symptom | Diagnosis | Fix |
|---|---|---|
| `-wal` grows to GBs | Long-lived reader pinning the checkpoint | Find and close it; add a statement timeout; commit read transactions promptly |
| Periodic latency spikes on writes | A large checkpoint blocking | Lower `wal_autocheckpoint`, or run `PASSIVE` checkpoints from a background task |
| `-wal` persists after clean shutdown | Last connection didn't close cleanly | It is recovered automatically on next open; harmless |

Deleting `-wal` or `-shm` by hand while a connection is open risks corruption. Close all
connections first — SQLite removes them on the last clean close.

---

## Connection pragma baseline

Persistence differs per pragma, and it's the most common source of "I set that, why isn't it
on":

| Pragma | Scope | Set where |
|---|---|---|
| `journal_mode = WAL` | **Database file** — persistent | Once, at setup/migration |
| `busy_timeout` | Connection | **Every connection** |
| `foreign_keys` | Connection | **Every connection** |
| `synchronous` | Connection | **Every connection** |
| `cache_size` | Connection | Every connection |
| `page_size` | Database file — only settable before first write or via `VACUUM` | Setup only |
| `auto_vacuum` | Database file — set before first table, or `VACUUM` after change | Setup only |

A correct connection factory sets the connection-scoped ones every time:

```sql
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -64000;   -- negative = KiB, so this is 64 MB
```

See [`hosts.md`](hosts.md) for this baseline written out per host.

---

## Multi-process and networked filesystems

| Environment | Verdict |
|---|---|
| Multiple processes, same local disk | Fine — this is SQLite's design point. Use WAL + `busy_timeout` |
| Threads sharing one connection | Only with correct serialisation; prefer one connection per thread |
| NFS / SMB / CIFS | **Do not.** Advisory locking is unreliable; corruption is a documented outcome |
| Docker volume on a local filesystem | Fine |
| Docker volume over a network mount | Same problem as NFS |
| WSL accessing a Windows drive (`/mnt/c`) | Locking is unreliable across the boundary — keep the database on the native filesystem |
| Cloud object storage (S3 et al.) | Not a filesystem; use a purpose-built layer (libSQL, Litestream-style replication) |

If you need SQLite semantics over a network, put a **server** in front of it (libSQL/Turso,
rqlite, or your own service) rather than sharing the file. See [`d1-edge.md`](d1-edge.md).

**Litestream-style continuous replication** is the standard answer for durability of a
single-node SQLite database: it streams WAL frames to object storage without changing how
the application talks to the database.

---

## Retry patterns

Retry `SQLITE_BUSY`. Never retry `SQLITE_LOCKED`. Always retry the **whole transaction**,
not the failed statement — a partial transaction cannot be resumed.

```python
import sqlite3, time, random

def with_retry(conn, fn, attempts=5):
    """Retry a whole write transaction on SQLITE_BUSY with jittered backoff."""
    for attempt in range(attempts):
        try:
            conn.execute("BEGIN IMMEDIATE")
            result = fn(conn)
            conn.execute("COMMIT")
            return result
        except sqlite3.OperationalError as exc:
            conn.execute("ROLLBACK")
            if "locked" not in str(exc) and "busy" not in str(exc):
                raise                      # not a contention error - do not retry
            if attempt == attempts - 1:
                raise
            time.sleep((2 ** attempt) * 0.05 + random.random() * 0.05)
```

Jitter matters: without it, N contending writers retry in lockstep and keep colliding.

---

## See also

- [`hosts.md`](hosts.md) — the pragma baseline per driver, and which hosts expose it
- [`operations.md`](operations.md) — backups that are safe under concurrent writers
- [`schema-design.md`](schema-design.md) — `foreign_keys` and the constraints it enables
- [`d1-edge.md`](d1-edge.md) — what a managed engine takes away from this chapter
