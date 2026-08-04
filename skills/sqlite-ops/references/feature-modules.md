# SQLite Feature Modules

FTS5, JSON/JSONB, R-tree, window functions, upsert, and RETURNING. Engine-agnostic SQL —
but **availability varies by build**, and that is the first thing to check. See
[Checking availability](#checking-availability).

## Contents

- [Checking availability](#checking-availability)
- [FTS5 full-text search](#fts5-full-text-search)
- [The trigram tokenizer](#the-trigram-tokenizer)
- [External-content FTS tables](#external-content-fts-tables)
- [JSON functions](#json-functions)
- [JSONB](#jsonb)
- [R-tree](#r-tree)
- [Window functions](#window-functions)
- [Upsert](#upsert)
- [RETURNING](#returning)
- [Other useful modules](#other-useful-modules)

---

## Checking availability

FTS5, R-tree, and JSON are **compile-time options**. Most distributions include all three;
some minimal or embedded builds don't, and managed engines may block the introspection you
would use to find out.

```sql
SELECT sqlite_version();                          -- version gate for syntax features
SELECT * FROM pragma_compile_options;             -- look for ENABLE_FTS5, ENABLE_RTREE
SELECT * FROM pragma_module_list;                 -- registered virtual-table modules
```

| Feature | Minimum version | Notes |
|---|---|---|
| Window functions | 3.25 (2018) | Also `ALTER TABLE RENAME COLUMN` |
| Upsert (`ON CONFLICT DO UPDATE`) | 3.24 | |
| `RETURNING` | 3.35 (2021) | Also `ALTER TABLE DROP COLUMN` |
| `STRICT` tables | 3.37 | |
| `->` / `->>` JSON operators | 3.38 | JSON functions themselves are much older |
| JSONB | 3.45 (2024) | Internal binary format |
| FTS5 `trigram` tokenizer | 3.34 | |

**On Cloudflare D1, `sqlite_version()` and `pragma_module_list` are both refused with
`SQLITE_AUTH`** (verified 2026-08-04). Confirming FTS5 availability there requires
`CREATE VIRTUAL TABLE`, which is a write — so it **could not be confirmed read-only**, and
this file records it as genuinely unknown. Test it in a preview/dev D1 database if your
design depends on it; do not assume from stock SQLite behaviour. See
[`d1-edge.md`](d1-edge.md).

---

## FTS5 full-text search

A virtual table that maintains an inverted index over text columns.

```sql
CREATE VIRTUAL TABLE doc_fts USING fts5(title, body);

INSERT INTO doc_fts (title, body) VALUES ('Indexing', 'How B-trees work in SQLite');

-- Match syntax
SELECT * FROM doc_fts WHERE doc_fts MATCH 'btree';
SELECT * FROM doc_fts WHERE doc_fts MATCH '"exact phrase"';
SELECT * FROM doc_fts WHERE doc_fts MATCH 'index*';             -- prefix
SELECT * FROM doc_fts WHERE doc_fts MATCH 'sqlite NOT mysql';
SELECT * FROM doc_fts WHERE doc_fts MATCH 'title: indexing';    -- column filter
SELECT * FROM doc_fts WHERE doc_fts MATCH 'NEAR(btree sqlite, 5)';
```

### Ranking

```sql
-- bm25(): lower (more negative) is better; ORDER BY rank uses it automatically
SELECT title, rank FROM doc_fts WHERE doc_fts MATCH 'sqlite' ORDER BY rank LIMIT 10;

-- Column weights: title matters 10x more than body
SELECT title, bm25(doc_fts, 10.0, 1.0) AS score
FROM doc_fts WHERE doc_fts MATCH 'sqlite'
ORDER BY score LIMIT 10;

-- Highlighted excerpt
SELECT snippet(doc_fts, 1, '<b>', '</b>', '…', 20) FROM doc_fts WHERE doc_fts MATCH 'sqlite';
SELECT highlight(doc_fts, 0, '[', ']')             FROM doc_fts WHERE doc_fts MATCH 'sqlite';
```

### Tokenizers

```sql
CREATE VIRTUAL TABLE t USING fts5(body, tokenize = 'unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE t USING fts5(body, tokenize = 'porter unicode61');   -- stemming
CREATE VIRTUAL TABLE t USING fts5(body, tokenize = 'trigram');            -- substring
```

| Tokenizer | Use for |
|---|---|
| `unicode61` (default) | General word search; `remove_diacritics 2` folds accents |
| `porter` | English stemming — "running" matches "run" |
| `ascii` | ASCII-only, fastest, no Unicode folding |
| `trigram` | **Substring** search — the real fix for `LIKE '%x%'` |

### Maintenance

```sql
INSERT INTO doc_fts(doc_fts) VALUES ('optimize');   -- merge index segments; do periodically
INSERT INTO doc_fts(doc_fts) VALUES ('rebuild');    -- rebuild from content table
PRAGMA integrity_check;                             -- also checks FTS structures
```

---

## The trigram tokenizer

The answer to substring search. It indexes every 3-character sequence, so both `MATCH` and —
uniquely — `LIKE '%…%'` become index-backed.

```sql
CREATE VIRTUAL TABLE org_fts USING fts5(name, tokenize = 'trigram');
INSERT INTO org_fts(name) SELECT DISTINCT org FROM q_product;

SELECT * FROM org_fts WHERE org_fts MATCH 'acme';       -- substring, index-backed
SELECT * FROM org_fts WHERE name LIKE '%acme%';         -- ALSO index-backed on a trigram table
```

| Property | Detail |
|---|---|
| Minimum search length | 3 characters — shorter patterns fall back to a scan |
| Case handling | Case-insensitive by default (`case_sensitive 1` to change) |
| Index size | Large — roughly one entry per character position |
| Write cost | Higher than `unicode61`; not for high-churn columns |

**Decision rule.** For a leading-wildcard predicate:

- Occasional query, wide table → covering index (see
  [`query-performance.md`](query-performance.md#covering-indexes)) — cheap, no new object.
- Frequent query, or the scan is genuinely too big → trigram FTS5 — eliminates the scan,
  costs index size and write throughput.

The covering index makes the scan cheap; trigram makes the scan disappear.

---

## External-content FTS tables

By default FTS5 stores its own copy of the text. An **external-content** table indexes rows
that live in an ordinary table, halving storage.

```sql
CREATE TABLE doc (id INTEGER PRIMARY KEY, title TEXT, body TEXT) STRICT;

CREATE VIRTUAL TABLE doc_fts USING fts5(
    title, body,
    content = 'doc',
    content_rowid = 'id'
);

-- You must maintain the index yourself, via triggers
CREATE TRIGGER doc_ai AFTER INSERT ON doc BEGIN
    INSERT INTO doc_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER doc_ad AFTER DELETE ON doc BEGIN
    INSERT INTO doc_fts(doc_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
END;
CREATE TRIGGER doc_au AFTER UPDATE ON doc BEGIN
    INSERT INTO doc_fts(doc_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
    INSERT INTO doc_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
```

**The delete trigger's odd shape is mandatory**: FTS5 needs the *old values* to remove the
right index entries, and it cannot read them from the content table (they're already gone).
Omitting the old values corrupts the index silently — searches start returning deleted rows.

`contentless` tables (`content=''`) store no text at all: smallest, but `snippet()`/
`highlight()` and updates are unavailable. Use for pure "which rowids match" lookups.

---

## JSON functions

```sql
CREATE TABLE event (id INTEGER PRIMARY KEY, payload TEXT NOT NULL) STRICT;

-- Extract
SELECT json_extract(payload, '$.user.id')  FROM event;   -- SQL value
SELECT payload -> '$.user'                 FROM event;   -- JSON representation
SELECT payload ->> '$.user.id'             FROM event;   -- SQL value (3.38+, preferred)

-- Modify (returns a new document; does not mutate in place)
UPDATE event SET payload = json_set(payload, '$.status', 'done')    WHERE id = ?;
UPDATE event SET payload = json_remove(payload, '$.tmp')            WHERE id = ?;
UPDATE event SET payload = json_patch(payload, '{"a":1,"b":null}')  WHERE id = ?;  -- RFC 7386

-- Build
SELECT json_object('id', id, 'kind', payload ->> '$.kind') FROM event;
SELECT json_group_array(json_object('id', id))             FROM event;

-- Inspect
SELECT json_valid(payload), json_type(payload, '$.tags'), json_array_length(payload, '$.tags')
FROM event;
```

### Expanding arrays and objects

`json_each` and `json_tree` are table-valued functions — the workhorses of JSON querying.

```sql
-- One row per array element
SELECT e.id, t.value AS tag
FROM event e, json_each(e.payload, '$.tags') t
WHERE t.value = 'urgent';

-- Turn a bound JSON array into a joinable set (one parameter, any length —
-- the standard way past a host's bound-parameter cap)
SELECT p.* FROM product p JOIN json_each(?) j ON j.value = p.id;

-- Recursive walk of the whole document
SELECT fullkey, value FROM event, json_tree(event.payload) WHERE atom IS NOT NULL;
```

### Indexing JSON

`json_extract` on a plain column is **never** indexable. Use a generated column or an
expression index:

```sql
ALTER TABLE event ADD COLUMN kind TEXT
    GENERATED ALWAYS AS (payload ->> '$.kind') VIRTUAL;
CREATE INDEX event_kind ON event(kind);

-- or, without changing the table shape
CREATE INDEX event_kind_expr ON event(json_extract(payload, '$.kind'));
```

The query must use the **same expression** as the index, syntactically. An index on
`json_extract(payload,'$.kind')` is not used by a query written with `payload ->> '$.kind'`.

---

## JSONB

SQLite 3.45+ adds a binary JSON representation. Every `json_*` function has a `jsonb_*`
counterpart that returns the binary form.

```sql
CREATE TABLE doc (id INTEGER PRIMARY KEY, body BLOB) STRICT;
INSERT INTO doc (body) VALUES (jsonb('{"a":1,"b":[2,3]}'));

SELECT body ->> '$.a' FROM doc;        -- operators work directly on JSONB
SELECT json(body) FROM doc;            -- back to text for display/export
```

| | JSON (TEXT) | JSONB (BLOB) |
|---|---|---|
| Parse cost per read | Full re-parse | None — already parsed |
| Storage | Slightly smaller for simple docs | Usually smaller for nested docs |
| Human-readable in a CLI dump | Yes | No — wrap in `json()` |
| Portability | Universal | SQLite-internal format; **not** PostgreSQL's JSONB |

Use JSONB when documents are read and traversed frequently. Keep TEXT when the column is
mostly passed through to an application that parses it anyway, or when tooling needs to read
the file directly. The format is a SQLite implementation detail — do not send it over a wire
or store it expecting another system to read it.

---

## R-tree

A virtual table for bounding-box and interval overlap queries. Compile-time module
(`ENABLE_RTREE`), enabled in most builds.

```sql
CREATE VIRTUAL TABLE place_idx USING rtree(
    id,                  -- INTEGER primary key, joins to the real table
    min_lon, max_lon,
    min_lat, max_lat
);

INSERT INTO place_idx VALUES (1, 151.20, 151.22, -33.87, -33.85);

-- Bounding-box query: fast, index-backed
SELECT p.name FROM place p JOIN place_idx i ON p.id = i.id
WHERE i.min_lon <= 151.25 AND i.max_lon >= 151.15
  AND i.min_lat <= -33.80 AND i.max_lat >= -33.90;
```

R-tree gives you the **coarse filter**; apply exact geometry or distance maths afterwards on
the small result set. It also works for one-dimensional intervals (time ranges, version
ranges) by using a single min/max pair.

For real geospatial work (projections, true distance, polygon operations) you need
SpatiaLite, a separate loadable extension.

---

## Window functions

SQLite 3.25+, with essentially PostgreSQL-compatible syntax.

```sql
-- Running total
SELECT id, amount, sum(amount) OVER (ORDER BY created_at) AS running
FROM txn;

-- Rank within a group
SELECT org, name, price,
       row_number() OVER (PARTITION BY org ORDER BY price DESC) AS rn,
       rank()       OVER (PARTITION BY org ORDER BY price DESC) AS rnk
FROM product;

-- Compare to the previous row (gap detection)
SELECT id, created_at,
       lag(created_at) OVER (ORDER BY created_at) AS prev,
       julianday(created_at) - julianday(lag(created_at) OVER (ORDER BY created_at)) AS gap_days
FROM event;

-- Top-N per group: filter on the window result via a CTE
WITH ranked AS (
    SELECT *, row_number() OVER (PARTITION BY org ORDER BY price DESC) AS rn FROM product
)
SELECT * FROM ranked WHERE rn <= 3;
```

Available: `row_number`, `rank`, `dense_rank`, `percent_rank`, `cume_dist`, `ntile`, `lag`,
`lead`, `first_value`, `last_value`, `nth_value`, plus every aggregate used as a window
function. Frame specifications (`ROWS BETWEEN … `, `RANGE BETWEEN …`, `GROUPS`) are
supported.

**Performance:** an `OVER (ORDER BY x)` clause needs the rows in `x` order — an index on `x`
avoids a temp B-tree, which will show up in `EXPLAIN QUERY PLAN` if it's missing.

---

## Upsert

```sql
-- Insert or update
INSERT INTO cache (key, value, expires_at) VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET
    value = excluded.value,
    expires_at = excluded.expires_at;

-- Conditional update (only overwrite if newer)
INSERT INTO cache (key, value, updated_at) VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
WHERE excluded.updated_at > cache.updated_at;

-- Insert or ignore
INSERT INTO seen (hash) VALUES (?) ON CONFLICT DO NOTHING;

-- Counter increment
INSERT INTO counter (name, n) VALUES (?, 1)
ON CONFLICT(name) DO UPDATE SET n = n + 1;
```

`excluded.*` refers to the row that *would* have been inserted. The conflict target
(`ON CONFLICT(key)`) must match a `UNIQUE` constraint or index.

The older `INSERT OR REPLACE` is **not** the same thing: it deletes and re-inserts, so it
fires `ON DELETE CASCADE`, drops columns you didn't supply back to their defaults, and
allocates a new rowid. Prefer `ON CONFLICT DO UPDATE` unless you specifically want the
delete semantics.

---

## RETURNING

SQLite 3.35+. Read back the rows a write touched, in one statement.

```sql
INSERT INTO product (sku, price) VALUES (?, ?) RETURNING id, created_at;
UPDATE product SET price = price * 1.1 WHERE org = ? RETURNING id, price;
DELETE FROM session WHERE expires_at < datetime('now') RETURNING token;
```

The highest-value use is an **atomic claim**, which without `RETURNING` needs a
select-then-update race:

```sql
UPDATE job_queue
SET status = 'running', started_at = datetime('now')
WHERE id = (
    SELECT id FROM job_queue WHERE status = 'pending'
    ORDER BY priority DESC, created_at LIMIT 1
)
RETURNING *;
```

Note the row order of a `RETURNING` result is undefined, and the rows are produced *before*
triggers and foreign-key actions complete — don't rely on either.

---

## Other useful modules

| Module | Purpose |
|---|---|
| `json_each` / `json_tree` | Table-valued JSON expansion (above) |
| `generate_series(a,b,step)` | Row generator — calendars, gap-filling, test data |
| `dbstat` | Per-table/index page usage — the honest answer to "what is taking up space" |
| `pragma_*` functions | `pragma_table_info('t')`, `pragma_index_list('t')` as queryable tables |
| `carray` | Bind a C array as a table (available in some builds/CLI) |
| `sqlite_dbpage` | Raw page access — recovery tooling only |

```sql
-- Gap-fill a daily report with generate_series
SELECT d.value AS day, coalesce(count(e.id), 0) AS n
FROM generate_series(
        (SELECT min(cast(strftime('%s', created_at) AS INTEGER)) FROM event),
        (SELECT max(cast(strftime('%s', created_at) AS INTEGER)) FROM event),
        86400) d
LEFT JOIN event e ON date(e.created_at) = date(d.value, 'unixepoch')
GROUP BY 1 ORDER BY 1;
```

---

## See also

- [`query-performance.md`](query-performance.md) — when trigram FTS beats a covering index
- [`schema-design.md`](schema-design.md) — generated columns for indexable JSON fields
- [`schema-patterns.md`](schema-patterns.md) — the FTS-backed document table recipe
- [`d1-edge.md`](d1-edge.md) — why FTS5 availability on D1 is unconfirmed
