# SQLite Schema Design

Engine-agnostic. Type affinity, STRICT tables, foreign-key enforcement, generated columns,
and `WITHOUT ROWID` behave identically on every host. For ready-made table recipes see
[`schema-patterns.md`](schema-patterns.md); for changing an existing schema see
[`migration-patterns.md`](migration-patterns.md).

## Contents

- [Type affinity: the thing that surprises everyone](#type-affinity-the-thing-that-surprises-everyone)
- [STRICT tables](#strict-tables)
- [Foreign keys are OFF by default](#foreign-keys-are-off-by-default)
- [Primary keys and rowid](#primary-keys-and-rowid)
- [WITHOUT ROWID](#without-rowid)
- [Generated columns](#generated-columns)
- [Constraints and defaults](#constraints-and-defaults)
- [Storing dates, booleans, and JSON](#storing-dates-booleans-and-json)
- [Collation](#collation)
- [Schema review checklist](#schema-review-checklist)

---

## Type affinity: the thing that surprises everyone

SQLite is **dynamically typed**. A column's declared type is not a constraint — it is an
*affinity*, a preference for how values are converted when they can be converted losslessly.
A `TEXT` column will store the integer `42` if you insert `42`.

| Declared type contains | Affinity | Behaviour |
|---|---|---|
| `INT` | INTEGER | Text that looks like an integer is converted |
| `CHAR`, `CLOB`, `TEXT` | TEXT | Numbers are converted to text |
| `BLOB`, or no type at all | BLOB (none) | Everything stored as given |
| `REAL`, `FLOA`, `DOUB` | REAL | Integers stored as floats |
| anything else (e.g. `NUMERIC`, `DATETIME`, `BOOLEAN`) | NUMERIC | Converts to INTEGER/REAL when lossless, else TEXT |

```sql
CREATE TABLE t (a INTEGER, b TEXT, c BLOB);
INSERT INTO t VALUES ('42', 42, 42);
SELECT typeof(a), typeof(b), typeof(c) FROM t;
-- integer | text | integer     <- a and b converted; c kept as given
```

### Why this is a performance bug, not just a tidiness bug

A type mismatch between a column and a bound parameter can **prevent index use** and
**silently return no rows**, because comparison across storage classes follows fixed rules
(NULL < INTEGER/REAL < TEXT < BLOB) rather than converting.

```sql
CREATE TABLE code (id TEXT PRIMARY KEY);
INSERT INTO code VALUES ('00123');
SELECT * FROM code WHERE id = 123;    -- 0 rows: integer 123 never equals text '00123'
```

Debug with `typeof()`, which is the fastest way to find a column that has been storing two
storage classes for years:

```sql
SELECT typeof(id), count(*) FROM code GROUP BY 1;
```

---

## STRICT tables

SQLite 3.37+ (2021). Adding `STRICT` after the closing parenthesis makes declared types
**enforced**.

```sql
CREATE TABLE product (
    id     INTEGER PRIMARY KEY,
    sku    TEXT NOT NULL,
    price  REAL NOT NULL,
    active INTEGER NOT NULL DEFAULT 1     -- SQLite has no BOOLEAN; use INTEGER 0/1
) STRICT;

INSERT INTO product (sku, price) VALUES (42, 'free');
-- Error: cannot store INTEGER value in TEXT column product.sku
```

Rules for STRICT tables:

- Every column must declare one of exactly six types: `INT`, `INTEGER`, `REAL`, `TEXT`,
  `BLOB`, `ANY`.
- `ANY` stores anything without conversion — the escape hatch, and unlike a non-STRICT
  column with no type, it preserves the original storage class exactly.
- `NOT NULL` is enforced as always; STRICT does not change nullability.
- The `PRIMARY KEY` of a STRICT table is implicitly `NOT NULL` (fixing a long-standing
  legacy quirk where a non-INTEGER primary key could be NULL).

**Use STRICT for all new tables** unless you have a specific reason for dynamic typing. It
costs nothing at runtime and converts a class of silent data bugs into loud errors. The one
migration consideration: existing rows with mixed storage classes will block the table
recreation, which is a feature — it tells you the data was already wrong.

---

## Foreign keys are OFF by default

```sql
PRAGMA foreign_keys = ON;    -- per CONNECTION, every connection, not persistent
```

This is the classic silent data-integrity bug in SQLite applications. `REFERENCES` clauses
parse fine, are stored in the schema, appear in `.schema` output, and **do nothing** unless
the pragma is on for the connection performing the write. Applications routinely ship for
years with orphaned rows accumulating.

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE author (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
CREATE TABLE book (
    id        INTEGER PRIMARY KEY,
    author_id INTEGER NOT NULL REFERENCES author(id) ON DELETE CASCADE,
    title     TEXT NOT NULL
) STRICT;

-- Index the child column: SQLite indexes the PARENT key automatically, never the child
CREATE INDEX book_author ON book(author_id);
```

| Action | Options |
|---|---|
| `ON DELETE` | `NO ACTION` (default), `RESTRICT`, `CASCADE`, `SET NULL`, `SET DEFAULT` |
| `ON UPDATE` | Same set |
| Deferred checking | `DEFERRABLE INITIALLY DEFERRED` — checked at COMMIT, needed for circular references |

**Two operational notes:**

- `PRAGMA foreign_keys` is a **no-op inside a transaction** — set it before `BEGIN`.
- Find pre-existing damage with `PRAGMA foreign_key_check;` before turning enforcement on.
  It lists every violating row so you can repair rather than discover at runtime.

```sql
PRAGMA foreign_key_check;                 -- whole database
PRAGMA foreign_key_check(book);           -- one table
```

**Always index the child column.** SQLite requires an index on the parent side (the
`PRIMARY KEY`/`UNIQUE` it references) but creates nothing on the child side — so a
`ON DELETE CASCADE` on an unindexed child column triggers a full table scan per parent
delete.

---

## Primary keys and rowid

Every ordinary table has a hidden 64-bit `rowid`. `INTEGER PRIMARY KEY` is special: it
**becomes** the rowid rather than creating a separate index, which makes it the fastest
possible key.

```sql
CREATE TABLE a (id INTEGER PRIMARY KEY);           -- id IS the rowid. Fast, no extra index.
CREATE TABLE b (id INT PRIMARY KEY);               -- NOT the rowid (INT != INTEGER) - separate index
CREATE TABLE c (id TEXT PRIMARY KEY);              -- separate unique index + rowid
```

`INTEGER PRIMARY KEY AUTOINCREMENT` adds a `sqlite_sequence` table and guarantees ids are
never reused. It is **slower** and rarely needed: without it, SQLite reuses the ids of
deleted rows only when the max row is deleted. Use `AUTOINCREMENT` only when id reuse would
be a correctness or security problem (e.g. externally published ids).

| Key choice | Trade-off |
|---|---|
| `INTEGER PRIMARY KEY` | Fastest; rowid alias; ids may be reused |
| `INTEGER PRIMARY KEY AUTOINCREMENT` | Never reuses; extra table and write cost |
| `TEXT PRIMARY KEY` (UUID) | Portable and mergeable; larger index, random insert order hurts write locality |
| ULID / UUIDv7 in TEXT | Retains sortability, so insert locality is good — usually the right choice if you need a distributed id |

---

## WITHOUT ROWID

Stores rows directly in a B-tree keyed by the primary key, eliminating the extra rowid
indirection.

```sql
CREATE TABLE kv (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID, STRICT;
```

| Use it when | Avoid it when |
|---|---|
| Primary key is a non-integer (TEXT/BLOB) that you always look up by | Primary key is `INTEGER` (already optimal) |
| Rows are small (a few hundred bytes) | Rows are large — big rows overflow badly here |
| Key-value or association tables | You need `AUTOINCREMENT` (incompatible) |
| Lookups are almost always by the full primary key | You rely on `rowid` / `last_insert_rowid()` |

Requires an explicit `PRIMARY KEY`. The win is typically both space and lookup speed for
small keyed rows; the loss is worse behaviour for wide rows and no rowid semantics.

---

## Generated columns

SQLite 3.31+. Compute a column from other columns in the same row — and, crucially, **index
it**. This is the clean way to make a JSON field or a normalised form queryable.

```sql
CREATE TABLE event (
    id      INTEGER PRIMARY KEY,
    payload TEXT NOT NULL,
    kind    TEXT GENERATED ALWAYS AS (json_extract(payload, '$.kind')) VIRTUAL,
    email_l TEXT GENERATED ALWAYS AS (lower(json_extract(payload, '$.email'))) VIRTUAL
) STRICT;

CREATE INDEX event_kind ON event(kind);
```

| Kind | Storage | Computed | Choose when |
|---|---|---|---|
| `VIRTUAL` (default) | None | On read | Indexed columns, or cheap expressions — usually right |
| `STORED` | On disk | On write | Expensive expressions read far more often than written |

Constraints: the expression must be deterministic and reference only columns of the same
row. Generated columns can be added by `ALTER TABLE ADD COLUMN` (`VIRTUAL` only) but not
dropped or altered without the full recreate dance.

---

## Constraints and defaults

```sql
CREATE TABLE account (
    id        INTEGER PRIMARY KEY,
    email     TEXT NOT NULL UNIQUE,
    status    TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','suspended','closed')),
    balance   REAL NOT NULL DEFAULT 0 CHECK (balance >= 0),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
) STRICT;
```

| Constraint | Note |
|---|---|
| `NOT NULL` | Cheapest correctness win available; use liberally |
| `UNIQUE` | Creates an index — don't also create one manually |
| `CHECK` | Evaluated on insert/update; expression must be deterministic |
| `DEFAULT (expr)` | Parenthesised expression allowed (e.g. `datetime('now')`); function defaults need the parentheses |
| Partial `UNIQUE` | `CREATE UNIQUE INDEX ix ON t(a) WHERE b IS NULL` — the only way to express a conditional uniqueness rule |

`CHECK` constraints are enforced by the engine on every host, including managed ones, which
makes them more reliable than application-layer validation.

---

## Storing dates, booleans, and JSON

SQLite has no dedicated DATE, TIME, or BOOLEAN storage class. Pick one convention and put
it in the schema comment, because mixed conventions in one database are a recurring bug.

| Data | Recommended | Why |
|---|---|---|
| Timestamp | `TEXT` ISO-8601 UTC: `'2026-08-04T10:23:45Z'` | Sorts lexicographically, human-readable, works with `datetime()` |
| Timestamp (compact) | `INTEGER` Unix epoch seconds | Smaller, arithmetic-friendly, not human-readable |
| Date only | `TEXT` `'2026-08-04'` | Same sorting property |
| Boolean | `INTEGER` 0/1 | `TRUE`/`FALSE` keywords exist (3.23+) and store as 1/0 |
| Money | `INTEGER` minor units (cents) | Avoids float rounding; `REAL` money is a bug factory |
| JSON document | `TEXT` (or JSONB, 3.45+) | See [`feature-modules.md`](feature-modules.md) |
| Binary | `BLOB` | Keep large blobs out of hot tables — they widen every row read |

**Never mix conventions across tables.** A database with epoch integers in one table and ISO
strings in another guarantees a comparison bug eventually.

Storing large BLOBs inline is a specific performance trap: because SQLite stores rows
contiguously, a 2 MB blob in a row makes *every* scan of that table pay for it, even when
the blob column isn't selected — unless a covering index avoids the table entirely. Store
large binaries out of line (filesystem, object storage) and keep a reference.

---

## Collation

| Collation | Behaviour |
|---|---|
| `BINARY` (default) | Byte comparison; case-sensitive |
| `NOCASE` | ASCII case-insensitive only — **does not handle non-ASCII** |
| `RTRIM` | Ignores trailing spaces |

```sql
CREATE TABLE users (email TEXT COLLATE NOCASE);
CREATE INDEX users_email ON users(email);       -- index inherits the column collation
SELECT * FROM users WHERE email = 'Alice@Example.COM';   -- matches, and uses the index
```

The index must have the **same collation as the comparison** or it cannot be used. If you
write `WHERE email COLLATE NOCASE = ?` against a `BINARY` column and index, the index is
skipped — declare the collation on the column instead.

For real Unicode case-folding you need the ICU extension, which is not compiled in by
default and is unavailable on most managed hosts. A portable alternative is storing a
normalised (`lower()`ed) generated column and indexing that.

---

## Schema review checklist

- [ ] New tables declared `STRICT`
- [ ] `PRAGMA foreign_keys = ON` set in the connection factory (every host, every path)
- [ ] Every foreign-key **child** column has its own index
- [ ] `PRAGMA foreign_key_check` clean
- [ ] `NOT NULL` on everything that logically cannot be null
- [ ] `CHECK` constraints for enumerations instead of free-text status columns
- [ ] One timestamp convention across the whole database, documented
- [ ] Money as integer minor units, never `REAL`
- [ ] Large BLOBs stored out of line
- [ ] `INTEGER PRIMARY KEY` unless a distributed id is genuinely needed
- [ ] `AUTOINCREMENT` only where id reuse would be a real problem
- [ ] Collation declared on the column, not in the query
- [ ] JSON fields that are queried have a generated column + index

---

## See also

- [`schema-patterns.md`](schema-patterns.md) — ready-made designs (state, cache, queue, log)
- [`migration-patterns.md`](migration-patterns.md) — changing a schema safely
- [`query-performance.md`](query-performance.md) — how affinity mismatches defeat indexes
- [`feature-modules.md`](feature-modules.md) — JSON, FTS5, and other module-backed columns
