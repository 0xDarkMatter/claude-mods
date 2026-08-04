# SQLite Migrations

Changing a schema that already holds data. Engine-agnostic SQL, with runner examples per
host. For designing a schema in the first place see [`schema-design.md`](schema-design.md).

## Contents

- [What ALTER TABLE can and cannot do](#what-alter-table-can-and-cannot-do)
- [The 12-step recreate procedure](#the-12-step-recreate-procedure)
- [Versioned migrations with user_version](#versioned-migrations-with-user_version)
- [A named-migration runner](#a-named-migration-runner)
- [Runners per host](#runners-per-host)
- [Migrating large tables](#migrating-large-tables)
- [Rollback strategy](#rollback-strategy)
- [Migration review checklist](#migration-review-checklist)

---

## What ALTER TABLE can and cannot do

| Operation | Supported | Since |
|---|---|---|
| `ADD COLUMN` | Yes | Always |
| `RENAME TO` (table) | Yes | Always |
| `RENAME COLUMN` | Yes | 3.25 |
| `DROP COLUMN` | Yes, **with conditions** | 3.35 |
| Change a column type | **No** | — |
| Add/remove `NOT NULL`, `CHECK`, `DEFAULT` | **No** | — |
| Add/remove a foreign key | **No** | — |
| Reorder columns | **No** | — |
| Add a `PRIMARY KEY` / `UNIQUE` | **No** (`CREATE UNIQUE INDEX` is the workaround) | — |

```sql
ALTER TABLE product ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
ALTER TABLE product RENAME COLUMN sku TO product_code;
ALTER TABLE product DROP COLUMN legacy_flag;
```

**`ADD COLUMN` constraints:** a `NOT NULL` column must have a non-null `DEFAULT` (existing
rows need a value), the default cannot be from the `CURRENT_TIME` family, and it cannot be
`PRIMARY KEY` or `UNIQUE`. Adding a column is O(1) — SQLite records it in the schema and
materialises the default on read.

**`DROP COLUMN` refuses** when the column is a primary key, has a `UNIQUE` constraint, or is
referenced by an index, view, trigger, `CHECK` constraint, or generated column. Drop the
dependent object first, or use the recreate procedure. Unlike `ADD`, it rewrites every row.

Everything else needs the recreate procedure below.

---

## The 12-step recreate procedure

The official sequence for any change `ALTER TABLE` cannot express. **Order matters** — each
step prevents a specific failure.

```sql
-- 1. If foreign keys are enabled, note that and turn them OFF.
--    Must be OUTSIDE a transaction: PRAGMA foreign_keys is a no-op inside one.
PRAGMA foreign_keys = OFF;

-- 2. Start a transaction.
BEGIN IMMEDIATE;

-- 3. Record every index, trigger and view attached to the table - you will recreate them:
--    SELECT type, name, sql FROM sqlite_master WHERE tbl_name = 'product';

-- 4. Create the new table under a temporary name, with the desired shape.
CREATE TABLE product_new (
    id         INTEGER PRIMARY KEY,
    org        TEXT NOT NULL,
    price      INTEGER NOT NULL,                   -- changed: REAL -> INTEGER (minor units)
    status     TEXT NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active','archived')),  -- added constraint
    created_at TEXT NOT NULL
    -- dropped: legacy_flag
) STRICT;

-- 5. Copy the data, transforming as needed.
INSERT INTO product_new (id, org, price, status, created_at)
SELECT id, org, CAST(round(price * 100) AS INTEGER),
       coalesce(status, 'active'), created_at
FROM product;

-- 6. Drop the old table.
DROP TABLE product;

-- 7. Rename the new table into place.
ALTER TABLE product_new RENAME TO product;

-- 8. Recreate the indexes and triggers recorded in step 3.
CREATE INDEX product_org ON product(org);

-- 9. Recreate any VIEW that referenced the old table shape.

-- 10. If foreign keys were on, verify nothing broke - while you can still ROLLBACK.
PRAGMA foreign_key_check;

-- 11. Commit.
COMMIT;

-- 12. Restore the foreign-key setting (outside the transaction).
PRAGMA foreign_keys = ON;
```

### Why each guard is there

| Step | Guards against |
|---|---|
| FK off during the rebuild (1, 12) | `DROP TABLE` firing `ON DELETE CASCADE` and **deleting child rows** — the destructive failure this procedure exists to prevent |
| FK toggled outside the transaction | `PRAGMA foreign_keys` is silently ignored inside a transaction |
| Recording indexes/triggers first (3) | `DROP TABLE` takes them with it; they are gone before you notice |
| `foreign_key_check` before `COMMIT` (10) | Catching orphans while rollback is still possible |
| `BEGIN IMMEDIATE` (2) | A mid-migration upgrade deadlock — see [`concurrency-durability.md`](concurrency-durability.md) |

**Legacy ordering to avoid:** the shorter "rename old, create new, copy, drop old" sequence
(`ALTER TABLE t RENAME TO t_old` first) interacts badly with `legacy_alter_table` settings —
references from other objects get rewritten to point at `t_old`. Use the order above.

---

## Versioned migrations with user_version

SQLite reserves a 32-bit integer in the file header for exactly this. It costs no table and
cannot drift from the file it describes.

```sql
PRAGMA user_version;        -- read (0 on a fresh database)
PRAGMA user_version = 3;    -- write (cannot be parameterised - interpolate an integer)
```

```sql
-- migrations/001_initial.sql
BEGIN IMMEDIATE;
CREATE TABLE product (
    id  INTEGER PRIMARY KEY,
    org TEXT NOT NULL,
    sku TEXT NOT NULL UNIQUE
) STRICT;
CREATE INDEX product_org ON product(org);
PRAGMA user_version = 1;
COMMIT;
```

```bash
sqlite3 app.db < migrations/001_initial.sql
sqlite3 app.db 'PRAGMA user_version;'    # -> 1
```

| Approach | Pros | Cons |
|---|---|---|
| `PRAGMA user_version` | No extra table; atomic with the schema; trivially readable | Integer only — no names, timestamps, or audit trail |
| A `schema_migrations` table | Names, applied-at timestamps, per-migration audit | An extra table; created by migration zero |

Use `user_version` for embedded/single-app databases; use a table when several people or
services need to see what ran and when.

---

## A named-migration runner

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    name       TEXT PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (datetime('now')),
    checksum   TEXT
) STRICT;
```

Recording a **checksum** catches the nastiest migration bug: someone editing a migration
that has already run somewhere, so environments silently diverge. Compare on startup and
refuse to proceed on a mismatch.

```python
import hashlib, pathlib, sqlite3

def migrate(conn: sqlite3.Connection, directory: str) -> list[str]:
    """Apply pending .sql migrations in filename order. Returns names applied."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            name TEXT PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (datetime('now')),
            checksum TEXT
        ) STRICT
    """)
    applied = {r[0]: r[1] for r in
               conn.execute("SELECT name, checksum FROM schema_migrations")}

    done = []
    for path in sorted(pathlib.Path(directory).glob("*.sql")):
        sql = path.read_text(encoding="utf-8")
        checksum = hashlib.sha256(sql.encode()).hexdigest()

        if path.name in applied:
            if applied[path.name] != checksum:
                raise RuntimeError(
                    f"{path.name} changed after it was applied "
                    f"(recorded {applied[path.name][:12]}, now {checksum[:12]}). "
                    "Add a new migration instead of editing an applied one.")
            continue

        # Each file supplies its own BEGIN/COMMIT so a failure rolls that file back cleanly.
        conn.executescript(sql)
        conn.execute("INSERT INTO schema_migrations (name, checksum) VALUES (?, ?)",
                     (path.name, checksum))
        done.append(path.name)
    return done
```

**Never edit an applied migration.** Add a new one. The checksum turns that convention into
an enforced invariant.

---

## Runners per host

```js
// better-sqlite3 / node:sqlite - synchronous, so the loop reads naturally
import Database from "better-sqlite3";
import { readFileSync, readdirSync } from "node:fs";

const db = new Database("app.db");
db.pragma("foreign_keys = ON");
db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
           name TEXT PRIMARY KEY,
           applied_at TEXT NOT NULL DEFAULT (datetime('now'))) STRICT`);

const applied = new Set(db.prepare("SELECT name FROM schema_migrations").pluck().all());
const record  = db.prepare("INSERT INTO schema_migrations (name) VALUES (?)");

for (const file of readdirSync("migrations").filter(f => f.endsWith(".sql")).sort()) {
  if (applied.has(file)) continue;
  db.exec(readFileSync(`migrations/${file}`, "utf8"));   // file supplies BEGIN/COMMIT
  record.run(file);
}
```

```bash
# Cloudflare D1 - migrations are a first-class wrangler feature
wrangler d1 migrations create atdw-mirror add_covering_index
wrangler d1 migrations list   atdw-mirror --remote
wrangler d1 migrations apply  atdw-mirror --local     # test locally first
wrangler d1 migrations apply  atdw-mirror --remote    # MAINTAINER-GATED: this is a deploy
```

D1 tracks applied migrations in its own table and applies files in name order. Three
differences from a local database: statements are subject to platform limits (100 KB per
statement, 100 bound parameters — see [`d1-edge.md`](d1-edge.md)); a remote apply is a
**production deploy**, so a working session writes the migration file and stops; and
[Time Travel](d1-edge.md#time-travel) gives you a 30-day undo that local SQLite does not,
so take a bookmark before applying.

```python
# aiosqlite - same logic, awaited. Run migrations at startup, before serving.
async def migrate(conn, directory: str) -> None:
    await conn.execute("""CREATE TABLE IF NOT EXISTS schema_migrations (
                            name TEXT PRIMARY KEY,
                            applied_at TEXT NOT NULL DEFAULT (datetime('now'))) STRICT""")
    cur = await conn.execute("SELECT name FROM schema_migrations")
    applied = {r[0] for r in await cur.fetchall()}
    for path in sorted(pathlib.Path(directory).glob("*.sql")):
        if path.name in applied:
            continue
        await conn.executescript(path.read_text(encoding="utf-8"))
        await conn.execute("INSERT INTO schema_migrations (name) VALUES (?)", (path.name,))
        await conn.commit()
```

---

## Migrating large tables

The recreate procedure holds a write lock throughout and needs room for a second copy of the
table. On a large table that is real downtime.

| Technique | Detail |
|---|---|
| Prefer `ADD COLUMN` | O(1) and lock-free — model changes as additive whenever possible |
| Backfill in batches | New nullable column → backfill in ~10k-row chunks in separate transactions → add the constraint later via a recreate |
| Expand/contract | Add the new column, dual-write from the app, backfill, switch reads, drop the old column in a later release |
| Measure first | `SELECT count(*)`, and confirm free disk ≥ 2x the table size |
| Schedule it | A recreate on a multi-GB table is minutes, not seconds |

```sql
-- Batched backfill: bounded transactions, resumable, no long lock
UPDATE product SET price_cents = CAST(round(price * 100) AS INTEGER)
WHERE price_cents IS NULL
  AND id IN (SELECT id FROM product WHERE price_cents IS NULL LIMIT 10000);
-- repeat until 0 rows changed
```

On D1 this pattern is mandatory rather than optional: a statement that scans too much is
killed by the 30-second query-duration limit or the isolate's CPU/memory limits.

---

## Rollback strategy

Down-migrations are frequently more dangerous than the change they undo — a `DROP COLUMN`
rollback destroys everything written since the migration ran.

| Situation | Preferred response |
|---|---|
| Additive change (new column/table/index) | Roll **forward** — old code ignores the addition |
| Destructive change | **Restore from backup** (or D1 Time Travel); snapshot immediately before |
| Constraint tightened, data now violates it | Roll forward with a repair migration |
| Genuine need to reverse | Write an explicit down-migration and test it against a copy of production |

```bash
# The rollback plan that always works: snapshot first
sqlite3 app.db "VACUUM INTO '/backup/pre-migration-$(date +%F-%H%M).db'"
sqlite3 app.db < migrations/007_recreate_product.sql

# On D1, capture a restore point instead
wrangler d1 time-travel info atdw-mirror     # record the bookmark BEFORE applying
```

Design migrations to be **backwards-compatible for one release**: deploy the schema change
first, the code that depends on it second. Then a code rollback never needs a schema
rollback.

---

## Migration review checklist

- [ ] Wrapped in `BEGIN IMMEDIATE` … `COMMIT`
- [ ] `PRAGMA foreign_keys = OFF` around a table recreate — **outside** the transaction
- [ ] Every index, trigger, and view on a recreated table is recreated afterwards
- [ ] `PRAGMA foreign_key_check` before `COMMIT`
- [ ] Version recorded (`user_version` or a `schema_migrations` row) in the same transaction
- [ ] Tested against a **copy of production data**, not just an empty schema
- [ ] Backup (or D1 bookmark) captured immediately before a destructive change
- [ ] Free disk ≥ 2x the table size for a recreate
- [ ] `ANALYZE` after a change that alters data distribution or adds an index
- [ ] Query plans for affected statements re-checked afterwards
- [ ] No edits to an already-applied migration file
- [ ] For D1: the remote apply is left to the maintainer, not run from a working session

---

## See also

- [`schema-design.md`](schema-design.md) — designing the shape you are migrating to
- [`schema-patterns.md`](schema-patterns.md) — ready-made table designs
- [`testing.md`](testing.md) — idempotency, data-preservation, and integrity tests
- [`operations.md`](operations.md) — backups before destructive changes
- [`d1-edge.md`](d1-edge.md) — wrangler migrations, Time Travel, and the deploy gate
