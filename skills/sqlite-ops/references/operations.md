# SQLite Operations

Integrity, corruption, backups, VACUUM, and size/page tuning. Applies to any host that owns
a real database file. Managed engines (D1, Turso primaries) handle most of this for you —
see [`d1-edge.md`](d1-edge.md).

## Contents

- [Integrity checks](#integrity-checks)
- [What actually corrupts a SQLite database](#what-actually-corrupts-a-sqlite-database)
- [Recovering a corrupted database](#recovering-a-corrupted-database)
- [Backups](#backups)
- [VACUUM vs VACUUM INTO](#vacuum-vs-vacuum-into)
- [Where the space went](#where-the-space-went)
- [Page size, cache, and mmap](#page-size-cache-and-mmap)
- [Bulk-load tuning](#bulk-load-tuning)
- [Routine maintenance](#routine-maintenance)

---

## Integrity checks

```sql
PRAGMA quick_check;        -- structural checks only; fast
PRAGMA integrity_check;    -- full: pages, indexes, constraints. Slow on large files
PRAGMA integrity_check(10);-- stop after 10 errors
PRAGMA foreign_key_check;  -- orphaned rows (independent of the foreign_keys pragma)
```

Both return the single row `ok` when clean. `quick_check` skips the index-content
verification, so it misses a corrupt index whose pages are structurally valid — run the full
check when you actually suspect damage, and `quick_check` as a routine heartbeat.

`integrity_check` reads every page. On a multi-GB database that is minutes of I/O and it
holds a read transaction throughout, which (in WAL) pins the checkpoint — schedule it, don't
run it casually against a busy production database.

---

## What actually corrupts a SQLite database

SQLite is extremely hard to corrupt through the API. Nearly every real case is external:

| Cause | Detail |
|---|---|
| **Networked filesystems** | NFS/SMB/CIFS advisory locking is unreliable. The single most common cause |
| **Copying a live database** | `cp`/`rsync` of a file with an active writer produces a torn copy |
| **Deleting `-wal` / `-shm` by hand** | Removing them while a connection is open discards committed data |
| **`PRAGMA synchronous = OFF`** | Power loss mid-write can leave the file inconsistent |
| Two processes with different locking assumptions | e.g. a WSL process and a Windows process on the same file |
| Hardware / filesystem failure | Bad sectors, a lying fsync in a virtualised disk stack |
| Killing a process with `SIGKILL` mid-write | Safe at `synchronous=NORMAL` or higher — SQLite recovers. Only unsafe with `synchronous=OFF` |

Application crashes and normal process kills are **not** on the corruption list — SQLite's
journal/WAL recovery handles them. Note the file's own defence: `PRAGMA integrity_check`
verifies structure, not semantics, so it will not detect application-level data errors.

---

## Recovering a corrupted database

Work on a **copy**. Never attempt recovery on the only artefact you have.

```bash
cp app.db app.db.broken          # after stopping every writer

# 1. Confirm and characterise
sqlite3 app.db.broken 'PRAGMA integrity_check;'

# 2. The .recover command — reconstructs from whatever pages are readable.
#    Strictly better than .dump for damaged files: it walks the b-trees directly
#    and salvages orphaned pages instead of aborting at the first bad read.
sqlite3 app.db.broken '.recover' > recovered.sql
sqlite3 app_new.db < recovered.sql
sqlite3 app_new.db 'PRAGMA integrity_check;'

# 3. If .recover is unavailable, .dump gets what it can
sqlite3 app.db.broken '.dump' > dump.sql
```

| Symptom | Likely meaning |
|---|---|
| `database disk image is malformed` | Real page-level corruption |
| `file is not a database` | Wrong file, truncated header, or an encrypted database opened without its key |
| `database is locked` on every attempt | Not corruption — a stale lock or another process |
| Missing rows, intact structure | Application bug or an interrupted write, not corruption |

After recovery, `.recover` output usually needs indexes and triggers re-created and should
be diffed against the schema you expect. Compare row counts per table against your last
known-good backup before declaring success.

---

## Backups

| Method | Consistent under writers | Output | Best for |
|---|---|---|---|
| `VACUUM INTO 'f.db'` | **Yes** | Compact database file | The default answer |
| Backup API (driver-level) | **Yes** | Database file | Programmatic/incremental backups |
| `.dump` | Yes (single read txn) | SQL text | Portability, archival, cross-version moves |
| Continuous WAL replication (Litestream-style) | Yes | Object storage | Point-in-time recovery |
| `cp` / `rsync` | **No** | Corrupt copy | Never, unless all writers are stopped |

```bash
# Online, consistent, defragmented — no downtime
sqlite3 app.db "VACUUM INTO '/backup/app-$(date +%F).db'"

# Portable text backup
sqlite3 app.db '.dump' | gzip > /backup/app.sql.gz

# Verify the backup before trusting it. An unverified backup is a rumour.
sqlite3 /backup/app-2026-08-04.db 'PRAGMA integrity_check;'
sqlite3 /backup/app-2026-08-04.db 'SELECT count(*) FROM product;'
```

```python
# Backup API: consistent, incremental, works while the source is being written
import sqlite3
src = sqlite3.connect("app.db")
dst = sqlite3.connect("/backup/app.db")
with dst:
    src.backup(dst, pages=1000, sleep=0.05)   # yields between page batches
dst.close(); src.close()
```

**Restore drills matter more than backup scripts.** Schedule a periodic restore-and-verify;
a backup nobody has restored is an untested assumption.

---

## VACUUM vs VACUUM INTO

```sql
VACUUM;                          -- rebuild this database in place
VACUUM INTO 'copy.db';           -- write a fresh, compact copy elsewhere
```

| | `VACUUM` | `VACUUM INTO` |
|---|---|---|
| Locks the database | **Yes**, exclusive, for the whole operation | No — a read transaction only |
| Disk needed | Up to **2x** the database size, plus temp | Size of the output |
| Result | Same file, defragmented, free pages released | New compact file; original untouched |
| Safe on a live system | No | Yes |

**`VACUUM` is not a performance tool.** It defragments and reclaims free pages; it does not
fix a missing index, and running it "to speed things up" is a common misdiagnosis. Reach for
it when the file has genuinely bloated after large deletions.

`auto_vacuum` handles reclamation incrementally instead:

```sql
PRAGMA auto_vacuum;               -- 0 NONE (default) | 1 FULL | 2 INCREMENTAL
PRAGMA auto_vacuum = INCREMENTAL; -- must be set before tables exist, or followed by VACUUM
PRAGMA incremental_vacuum(1000);  -- release up to 1000 free pages, cheaply
```

`INCREMENTAL` + a periodic `incremental_vacuum` is the low-impact choice for a
delete-heavy database. `FULL` reclaims on every commit and costs write throughput.

---

## Where the space went

```sql
-- Overall geometry
PRAGMA page_count;    -- pages in the file
PRAGMA page_size;     -- bytes per page  (file size ≈ page_count * page_size)
PRAGMA freelist_count;-- unused pages — a large number means VACUUM would reclaim

-- Per-object breakdown (needs the dbstat virtual table; present in most builds)
SELECT name, SUM(pgsize) AS bytes, SUM(pgsize)/1024/1024 AS mb
FROM dbstat GROUP BY name ORDER BY bytes DESC LIMIT 20;

-- Rows per table
SELECT name, (SELECT count(*) FROM sqlite_master) AS _ FROM sqlite_master WHERE type='table';
```

`dbstat` distinguishes tables from indexes by name, which is how you discover that an index
you added is larger than the table it indexes — a common outcome with wide covering indexes
and trigram FTS. The CLI's `.dbinfo` gives the header summary in one shot.

---

## Page size, cache, and mmap

```sql
PRAGMA page_size;              -- default 4096; only changeable before the first table, or via VACUUM
PRAGMA cache_size = -64000;    -- NEGATIVE means KiB → 64 MB. Positive means a page count
PRAGMA mmap_size = 268435456;  -- 256 MB memory-mapped I/O
PRAGMA temp_store = MEMORY;    -- keep temp B-trees in RAM
```

| Setting | Guidance |
|---|---|
| `page_size` | 4096 suits most workloads. 8192/16384 can help large sequential scans and large rows. Changing it requires `PRAGMA page_size = N; VACUUM;` |
| `cache_size` | The highest-leverage knob. Always express as negative KiB — a positive value is a *page count* and silently means something different if you later change `page_size` |
| `mmap_size` | Can cut read syscalls substantially. Avoid on network filesystems; a corrupt page becomes a segfault rather than an error |
| `temp_store` | `MEMORY` avoids disk for sorts and temp B-trees — worth setting when EQP shows temp B-trees you can't design away |

Measure rather than cargo-cult: on a database that fits in the OS page cache, none of these
will move the needle, and index design will move it 25x.

---

## Bulk-load tuning

For an import into a database nobody else is using, temporarily trading durability for speed
is legitimate — **on a database you can rebuild**.

```sql
PRAGMA journal_mode = OFF;      -- no rollback journal (UNSAFE: crash = corrupt)
PRAGMA synchronous = OFF;       -- no fsync            (UNSAFE)
PRAGMA temp_store = MEMORY;
PRAGMA cache_size = -256000;    -- 256 MB

BEGIN;
-- ... millions of INSERTs, one transaction ...
COMMIT;

-- Restore safe settings, then build indexes AFTER the data is in
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
CREATE INDEX ...;
ANALYZE;
```

| Technique | Effect |
|---|---|
| One transaction around the whole load | The single biggest win — one fsync instead of N |
| Create indexes **after** loading | Bulk index build beats N incremental updates |
| `.import --csv` in the CLI | Fastest path for CSV; skips per-row round trips |
| Prepared statement + `executemany`/batch | Avoids re-parsing the statement per row |
| `ANALYZE` after loading | The planner has no statistics for freshly loaded data |

Never leave `journal_mode = OFF` or `synchronous = OFF` set on a production database.

---

## Routine maintenance

| Cadence | Task |
|---|---|
| On connection close (long-lived apps) | `PRAGMA optimize` — cheap, targeted `ANALYZE` |
| Daily | `VACUUM INTO` backup + `integrity_check` on the **backup** (not the live file) |
| Weekly | `PRAGMA quick_check` on the live database |
| After bulk changes | `ANALYZE`; FTS5 `'optimize'`; re-read plans for affected statements |
| After large deletions | `incremental_vacuum`, or a scheduled `VACUUM` during a maintenance window |
| Monthly | Restore drill: restore the backup somewhere and verify row counts |
| On schema change | Re-run `EXPLAIN QUERY PLAN` on the statements the change was meant to fix |

```bash
#!/usr/bin/env bash
# Nightly: consistent backup, then verify the BACKUP rather than locking production.
set -uo pipefail
DB=/var/lib/app/app.db
OUT=/backup/app-$(date +%F).db
sqlite3 "$DB" "VACUUM INTO '$OUT'"          || exit 1
result=$(sqlite3 "$OUT" 'PRAGMA integrity_check;')
[ "$result" = "ok" ] || { echo "backup failed integrity_check: $result" >&2; exit 1; }
find /backup -name 'app-*.db' -mtime +14 -delete
```

---

## See also

- [`concurrency-durability.md`](concurrency-durability.md) — WAL checkpointing and `synchronous`
- [`query-performance.md`](query-performance.md) — `ANALYZE`, `PRAGMA optimize`, index sizing
- [`migration-patterns.md`](migration-patterns.md) — schema change procedure
- [`testing.md`](testing.md) — verifying a restore in a test harness
