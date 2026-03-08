# PostgreSQL Indexing Reference

## Table of Contents

1. [Index Types Overview](#index-types-overview)
2. [B-tree Indexes](#b-tree-indexes)
3. [Hash Indexes](#hash-indexes)
4. [GIN Indexes](#gin-indexes)
5. [GiST Indexes](#gist-indexes)
6. [BRIN Indexes](#brin-indexes)
7. [Composite Indexes](#composite-indexes)
8. [Partial Indexes](#partial-indexes)
9. [Expression Indexes](#expression-indexes)
10. [Covering Indexes (INCLUDE)](#covering-indexes-include)
11. [GIN Specifics](#gin-specifics)
12. [GiST Specifics](#gist-specifics)
13. [BRIN Specifics](#brin-specifics)
14. [Index Maintenance](#index-maintenance)
15. [Anti-Patterns](#anti-patterns)

---

## Index Types Overview

| Type | Best For | Operators Supported | Notes |
|------|----------|---------------------|-------|
| B-tree | Equality, range, sorting | `=`, `<`, `>`, `<=`, `>=`, `BETWEEN`, `LIKE 'foo%'` | Default; works for most cases |
| Hash | Equality only | `=` | Smaller than B-tree for pure equality |
| GIN | Multi-valued columns | `@>`, `<@`, `&&`, `?`, `@@` | JSONB, arrays, FTS, tsvector |
| GiST | Geometric, range, custom | `&&`, `@>`, `<@`, `<->` | Ranges, PostGIS, exclusion constraints |
| BRIN | Append-only correlated data | `=`, `<`, `>` range | Tiny size, ideal for time-series |
| SP-GiST | Partitioned/hierarchical data | Varies | IP addresses, phone trees, quadtrees |

---

## B-tree Indexes

The default index type. Keeps values in sorted order, enabling equality lookups, range scans, and ORDER BY satisfaction without a sort step.

```sql
-- Basic B-tree (implicit)
CREATE INDEX idx_orders_customer_id ON orders(customer_id);

-- Explicit declaration
CREATE INDEX idx_orders_customer_id ON orders USING btree(customer_id);

-- Descending sort order (useful when ORDER BY col DESC is common)
CREATE INDEX idx_events_created_desc ON events(created_at DESC);

-- NULLS FIRST / NULLS LAST (match your ORDER BY for index-only scan benefit)
CREATE INDEX idx_tasks_due_date ON tasks(due_date ASC NULLS LAST);
```

B-tree supports prefix matching on text columns with `LIKE 'prefix%'` (but NOT `LIKE '%suffix'`). Requires `text_pattern_ops` if the column uses a non-C locale:

```sql
CREATE INDEX idx_users_name_prefix ON users(name text_pattern_ops);
-- Now: WHERE name LIKE 'Joh%'  uses the index
```

---

## Hash Indexes

Hash indexes store a hash of the indexed value. They are smaller than B-tree and marginally faster for pure equality lookups, but cannot satisfy range queries or sorting.

```sql
CREATE INDEX idx_sessions_token ON sessions USING hash(token);

-- Only useful for:
SELECT * FROM sessions WHERE token = 'abc123';

-- Useless for:
SELECT * FROM sessions WHERE token > 'abc123';   -- cannot use hash index
SELECT * FROM sessions ORDER BY token;            -- cannot use hash index
```

Hash indexes are WAL-logged since PG10 and safe for production use. Choose hash only when you are certain the column will never participate in range queries or ORDER BY.

---

## GIN Indexes

Generalized Inverted Index. Designed for columns that contain multiple values (arrays, JSONB, tsvector). GIN maps each element value to the set of rows containing it.

```sql
-- Array column
CREATE INDEX idx_articles_tags ON articles USING gin(tags);

-- JSONB column (default operator class)
CREATE INDEX idx_products_attrs ON products USING gin(attributes);

-- Full-text search
CREATE INDEX idx_posts_fts ON posts USING gin(to_tsvector('english', body));

-- Pre-computed tsvector column (faster updates)
ALTER TABLE posts ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))) STORED;
CREATE INDEX idx_posts_search ON posts USING gin(search_vector);
```

GIN indexes have high build cost and write overhead (each element is indexed separately) but excellent read performance for containment queries.

---

## GiST Indexes

Generalized Search Tree. A framework supporting custom data types with custom operators. Suitable for geometric data, range types, and exclusion constraints.

```sql
-- Range type
CREATE INDEX idx_bookings_during ON bookings USING gist(during);

-- PostGIS geometry
CREATE INDEX idx_locations_geom ON locations USING gist(geom);

-- Exclusion constraint (requires GiST index internally)
CREATE EXTENSION btree_gist;
ALTER TABLE bookings ADD CONSTRAINT no_overlap
    EXCLUDE USING gist (room_id WITH =, during WITH &&);
```

GiST is lossy (may return false positives that are then rechecked), making it slightly less precise than GIN but more flexible for custom types.

---

## BRIN Indexes

Block Range INdex. Stores min/max values per block range rather than per row. Extremely small (often 1000x smaller than B-tree) but only useful when physical row order correlates with query values.

```sql
-- Time-series table where rows are appended in timestamp order
CREATE INDEX idx_events_created_brin ON events USING brin(created_at);

-- Adjust pages_per_range (default 128): smaller = more precise, larger index
CREATE INDEX idx_events_created_brin ON events USING brin(created_at)
WITH (pages_per_range = 32);
```

---

## Composite Indexes

A composite (multi-column) index covers multiple columns. Column ordering is critical.

### Ordering Rules

1. **Equality conditions first** - columns used with `=` should come before range columns
2. **Most selective first** - among equality columns, put highest cardinality first
3. **Leftmost prefix rule** - an index on `(a, b, c)` can also serve queries on `(a)` and `(a, b)` but NOT `(b)` or `(c)` alone

```sql
-- Query pattern: WHERE status = 'active' AND created_at > '2024-01-01'
-- Equality (status) before range (created_at)
CREATE INDEX idx_orders_status_created ON orders(status, created_at);

-- Query pattern: WHERE tenant_id = 1 AND user_id = 42 AND created_at > '2024-01-01'
CREATE INDEX idx_events_tenant_user_created ON events(tenant_id, user_id, created_at);

-- This index CANNOT be used for: WHERE user_id = 42 (skips leftmost column)
-- This index CAN be used for: WHERE tenant_id = 1 (leftmost prefix only)
-- This index CAN be used for: WHERE tenant_id = 1 AND user_id = 42 ORDER BY created_at

-- Verify index is being used
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM events
WHERE tenant_id = 1 AND user_id = 42 AND created_at > now() - interval '7 days';
```

### Selectivity Check

```sql
-- Estimate selectivity per column before deciding order
SELECT
    count(DISTINCT status)::float / count(*) AS status_selectivity,
    count(DISTINCT customer_id)::float / count(*) AS customer_selectivity
FROM orders;
-- Higher ratio = more selective = put earlier in composite index
```

---

## Partial Indexes

A partial index indexes only the rows satisfying a WHERE predicate. Results in a smaller, faster index.

```sql
-- Index only active users (WHERE status = 'active' is common)
CREATE INDEX idx_users_active_email ON users(email) WHERE status = 'active';

-- Index only unprocessed jobs (queue pattern)
CREATE INDEX idx_jobs_pending ON jobs(created_at) WHERE processed_at IS NULL;

-- Soft-delete pattern: exclude deleted rows from index
CREATE INDEX idx_products_name ON products(name) WHERE deleted_at IS NULL;

-- Partial unique: only one active record per external_id
CREATE UNIQUE INDEX idx_subscriptions_active
ON subscriptions(external_id) WHERE cancelled_at IS NULL;
```

For the planner to use a partial index, the query WHERE clause must be **semantically implied** by the index predicate:

```sql
-- Index: WHERE status = 'active'
-- Query must include: WHERE status = 'active' (explicitly, not implied by a join)
SELECT * FROM users WHERE status = 'active' AND email = 'foo@example.com';
-- Planner can use idx_users_active_email above

-- This query CANNOT use it (predicate not present):
SELECT * FROM users WHERE email = 'foo@example.com';
```

### Size Savings Example

```sql
-- Measure savings
SELECT
    pg_size_pretty(pg_relation_size('idx_jobs_all')) AS full_index,
    pg_size_pretty(pg_relation_size('idx_jobs_pending')) AS partial_index;

-- Often 10-100x smaller when condition filters 90%+ of rows
```

---

## Expression Indexes

Index on the result of an expression or function rather than a raw column value. The expression must be **immutable** (same input always produces same output).

```sql
-- Case-insensitive email lookup
CREATE INDEX idx_users_email_lower ON users(lower(email));
-- Query must use the same expression:
SELECT * FROM users WHERE lower(email) = lower('User@Example.com');

-- Date extraction (find all orders on a given day)
CREATE INDEX idx_orders_date ON orders(date_trunc('day', created_at));
SELECT * FROM orders WHERE date_trunc('day', created_at) = '2024-03-01';

-- JSONB field extraction (use when you query a specific key frequently)
CREATE INDEX idx_users_plan ON users((data ->> 'subscription_plan'));
SELECT * FROM users WHERE data ->> 'subscription_plan' = 'enterprise';

-- Numeric cast from JSONB text field
CREATE INDEX idx_orders_amount ON orders(((data ->> 'amount')::numeric));
SELECT * FROM orders WHERE (data ->> 'amount')::numeric > 1000;

-- Partial expression index: only index non-null computed values
CREATE INDEX idx_products_lower_name ON products(lower(name))
WHERE name IS NOT NULL;
```

### Immutability Requirement

Functions used in expression indexes must be declared `IMMUTABLE`. PostgreSQL will reject `STABLE` or `VOLATILE` functions.

```sql
-- This fails: now() is STABLE, not IMMUTABLE
CREATE INDEX bad ON events(date_trunc('day', now()));  -- ERROR

-- Custom function must be explicitly IMMUTABLE
CREATE FUNCTION clean_phone(text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT regexp_replace($1, '[^0-9]', '', 'g')
$$;

CREATE INDEX idx_contacts_phone ON contacts(clean_phone(phone_raw));
```

---

## Covering Indexes (INCLUDE)

The `INCLUDE` clause adds non-key columns to the index leaf pages. These columns are not searchable but allow index-only scans, avoiding heap fetches entirely.

```sql
-- Without INCLUDE: planner must fetch heap to get email
CREATE INDEX idx_users_name ON users(name);

-- With INCLUDE: index-only scan possible
CREATE INDEX idx_users_name_covering ON users(name) INCLUDE (email, status);
SELECT email, status FROM users WHERE name = 'Alice';  -- no heap access
```

### When to Use INCLUDE vs Composite

| Scenario | Use |
|----------|-----|
| Column needed in SELECT but not WHERE/ORDER BY | `INCLUDE` |
| Column used in WHERE or ORDER BY | Add as key column |
| Column has high write churn | Prefer key column (INCLUDE columns still updated) |
| Need to cover a few extra cheap columns | `INCLUDE` |
| Covering a large text column | Avoid; inflates index; use composite carefully |

```sql
-- Index-only scan verification in EXPLAIN output
EXPLAIN (ANALYZE, BUFFERS)
SELECT name, email FROM users WHERE name LIKE 'A%';
-- Look for "Index Only Scan" and "Heap Fetches: 0" (or low count if visibility map not up to date)

-- Force visibility map update to enable index-only scans
VACUUM users;
```

---

## GIN Specifics

### Operator Classes

```sql
-- Default operator class: supports @>, <@, ?, ?|, ?& on jsonb
-- Indexes all key-value pairs; larger index; supports more operators
CREATE INDEX idx_data_gin ON records USING gin(data);

-- jsonb_path_ops: supports ONLY @> (containment)
-- Indexes only values (not keys); ~30% smaller; faster for containment queries
CREATE INDEX idx_data_gin_path ON records USING gin(data jsonb_path_ops);

-- Choose jsonb_path_ops when:
-- - You only query with @> (containment)
-- - Index size is a concern
-- - Write throughput needs improvement

-- Choose default when:
-- - You use ?, ?|, ?& (key existence checks)
-- - You need to query nested structures with multiple operators
```

### Trigram Search (pg_trgm)

```sql
CREATE EXTENSION pg_trgm;

-- GIN trigram index for LIKE, ILIKE, and regex
CREATE INDEX idx_products_name_trgm ON products USING gin(name gin_trgm_ops);

-- Now these use the index (unlike standard B-tree):
SELECT * FROM products WHERE name ILIKE '%widget%';
SELECT * FROM products WHERE name ~ 'wid.*et';

-- Similarity search
SELECT name, similarity(name, 'wiget') AS sim
FROM products
WHERE name % 'wiget'   -- % operator: similarity > threshold (default 0.3)
ORDER BY sim DESC;

-- GiST alternative (smaller index, slightly slower queries)
CREATE INDEX idx_products_name_trgm_gist ON products USING gist(name gist_trgm_ops);
```

### Array Operators with GIN

```sql
CREATE INDEX idx_articles_tags ON articles USING gin(tags);

-- Supported operators with this index:
SELECT * FROM articles WHERE tags @> ARRAY['postgresql'];   -- contains
SELECT * FROM articles WHERE tags <@ ARRAY['a','b','c'];   -- is contained by
SELECT * FROM articles WHERE tags && ARRAY['postgresql'];  -- overlap
SELECT * FROM articles WHERE 'postgresql' = ANY(tags);    -- equivalent to @>
```

### Full-Text Search

```sql
-- Index a computed tsvector
CREATE INDEX idx_posts_fts ON posts USING gin(to_tsvector('english', title || ' ' || body));

-- Or index a stored tsvector column (faster updates, more storage)
ALTER TABLE posts ADD COLUMN fts tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(body, '')), 'B')
    ) STORED;

CREATE INDEX idx_posts_fts ON posts USING gin(fts);

-- Query
SELECT title, ts_rank(fts, query) AS rank
FROM posts, to_tsquery('english', 'postgresql & index') query
WHERE fts @@ query
ORDER BY rank DESC;
```

### GIN Tuning

```sql
-- gin_pending_list_limit: GIN uses a fast-update pending list
-- Larger = fewer full index updates during writes, more reads deferred
-- Default: 4MB
ALTER INDEX idx_posts_fts SET (fastupdate = on);

-- Force pending list flush (useful before a read-heavy period)
SELECT gin_clean_pending_list('idx_posts_fts');
```

---

## GiST Specifics

### Range Type Indexing

```sql
CREATE EXTENSION btree_gist;  -- required for scalar types in EXCLUDE

CREATE TABLE schedules (
    id       serial PRIMARY KEY,
    staff_id integer,
    shift    tsrange
);

CREATE INDEX idx_schedules_shift ON schedules USING gist(shift);

-- Supported operators:
-- && overlap, @> contains, <@ is contained by, = equal, << strictly left, >> strictly right
SELECT * FROM schedules WHERE shift && '[2024-03-01 08:00, 2024-03-01 16:00)';
SELECT * FROM schedules WHERE shift @> '2024-03-01 10:00'::timestamptz;

-- Exclusion constraint: no staff member double-booked
ALTER TABLE schedules ADD CONSTRAINT no_double_shift
    EXCLUDE USING gist (staff_id WITH =, shift WITH &&);
```

### PostGIS with GiST

```sql
-- Bounding-box spatial index (default, fast)
CREATE INDEX idx_locations_geom ON locations USING gist(geom);

-- KNN search: find 5 nearest stores to a point
SELECT name, geom <-> ST_MakePoint(-87.6298, 41.8781)::geography AS distance
FROM stores
ORDER BY distance
LIMIT 5;

-- Bounding-box overlap (fast, approximate)
SELECT * FROM polygons WHERE geom && ST_MakeEnvelope(-88, 41, -87, 42, 4326);

-- Exact intersection (uses index for bbox pre-filter, then rechecks)
SELECT * FROM polygons WHERE ST_Intersects(geom, ST_MakeEnvelope(-88, 41, -87, 42, 4326));
```

### GiST vs GIN Trade-offs

| Property | GiST | GIN |
|----------|------|-----|
| Build time | Faster | Slower |
| Index size | Larger | Smaller (for same data) |
| Query speed | Slightly slower (lossy, recheck) | Faster for exact lookups |
| Concurrent writes | Better | GIN pending list helps |
| Use for exclusion constraints | Yes | No |

---

## BRIN Specifics

### How BRIN Works

BRIN stores the minimum and maximum values for each block range (group of consecutive pages). Effective when the physical storage order of rows correlates with the query predicate.

```sql
-- Ideal: append-only log table; rows inserted in timestamp order
CREATE TABLE application_logs (
    id          bigserial,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    level       text,
    message     text
);

-- BRIN is tiny: 1 page per 128 pages of heap (default)
CREATE INDEX idx_logs_recorded_brin ON application_logs USING brin(recorded_at);

-- Dramatically smaller than B-tree for the same column:
SELECT
    pg_size_pretty(pg_relation_size('idx_logs_recorded_btree')) AS btree_size,
    pg_size_pretty(pg_relation_size('idx_logs_recorded_brin'))  AS brin_size;
-- Typical ratio: 1000:1 in favor of BRIN for correlated data
```

### Tuning pages_per_range

```sql
-- Default pages_per_range = 128 (coarse, very small index)
-- Smaller value = more precise (fewer false positives), larger index
-- Larger value = less precise, smaller index

-- For high-precision time ranges on a large table
CREATE INDEX idx_logs_brin_precise ON application_logs USING brin(recorded_at)
WITH (pages_per_range = 16);

-- Query still requires a sequential scan of matching block ranges
-- followed by heap fetch and recheck; BRIN shines when most blocks are skipped
```

### Ideal BRIN Workloads

- Time-series and IoT data inserted in timestamp order
- Append-only audit tables
- Log tables where records are never updated out of order
- Data warehouse fact tables loaded in date sequence

### When BRIN Is NOT Appropriate

- Tables with random INSERT patterns (poor correlation)
- Frequently updated rows that change index key values
- Small tables (B-tree overhead is trivial; BRIN gains are minimal)
- When precise, low-latency lookups are required (BRIN may still scan many pages)

---

## Index Maintenance

### Finding Unused Indexes

```sql
-- Indexes with zero or low scans since last statistics reset
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) > 1024 * 1024  -- larger than 1MB
ORDER BY pg_relation_size(indexrelid) DESC;

-- When were statistics last reset?
SELECT stats_reset FROM pg_stat_bgwriter;
```

### Detecting Index Bloat

```sql
-- Approximate bloat using pgstattuple extension
CREATE EXTENSION pgstattuple;

SELECT * FROM pgstatindex('idx_orders_customer_id');
-- Look at: avg_leaf_density (below ~70% means bloat)

-- Or use the bloat query from check_postgres
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    round(100 * (1 - avg_leaf_density / 90.0), 1) AS bloat_pct
FROM pg_stat_user_indexes
JOIN pg_index USING (indexrelid)
CROSS JOIN pgstatindex(indexrelid::regclass::text)
WHERE NOT indisprimary
ORDER BY bloat_pct DESC;
```

### Rebuilding Indexes

```sql
-- Rebuild without locking reads/writes (PG12+)
REINDEX INDEX CONCURRENTLY idx_orders_customer_id;

-- Rebuild all indexes on a table concurrently
REINDEX TABLE CONCURRENTLY orders;

-- Classic REINDEX (takes ShareLock, blocks writes):
REINDEX INDEX idx_orders_customer_id;

-- Rebuild as new index, then swap (manual CONCURRENTLY approach, pre-PG12)
CREATE INDEX CONCURRENTLY idx_orders_customer_id_new ON orders(customer_id);
DROP INDEX idx_orders_customer_id;
ALTER INDEX idx_orders_customer_id_new RENAME TO idx_orders_customer_id;
```

### Monitoring Index Size and Growth

```sql
-- All index sizes for a table, sorted descending
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    indexdef
FROM pg_indexes
JOIN pg_stat_user_indexes USING (schemaname, tablename, indexname)
WHERE tablename = 'orders'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Total index overhead vs table size
SELECT
    relname AS table_name,
    pg_size_pretty(pg_relation_size(oid)) AS table_size,
    pg_size_pretty(pg_indexes_size(oid)) AS indexes_size,
    round(100.0 * pg_indexes_size(oid) / nullif(pg_relation_size(oid), 0), 1) AS index_ratio_pct
FROM pg_class
WHERE relkind = 'r'
  AND relnamespace = 'public'::regnamespace
ORDER BY pg_indexes_size(oid) DESC;
```

### Monitoring Index Usage in Queries

```sql
-- Enable pg_stat_statements for query-level stats
CREATE EXTENSION pg_stat_statements;

-- Find slow queries that do sequential scans on large tables
SELECT
    query,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round(total_exec_time::numeric, 2) AS total_ms
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;

-- Check for sequential scans on a specific table
SELECT
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_live_tup
FROM pg_stat_user_tables
WHERE relname = 'orders';

-- High seq_scan with high n_live_tup = missing index candidate
```

---

## Anti-Patterns

### Over-Indexing

Every index adds overhead to INSERT, UPDATE, and DELETE operations. Index only columns that appear in WHERE, JOIN, or ORDER BY clauses of frequent or critical queries.

```sql
-- Bad: indexing every column "just in case"
CREATE INDEX ON orders(id);           -- already the PK
CREATE INDEX ON orders(created_at);   -- only used in one monthly report
CREATE INDEX ON orders(notes);        -- free-text, rarely filtered
CREATE INDEX ON orders(updated_at);   -- only used in batch maintenance jobs

-- Measure write amplification
SELECT
    relname,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    (SELECT count(*) FROM pg_indexes WHERE tablename = relname) AS index_count
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

### Wrong Index Type Selection

```sql
-- Bad: B-tree on a column used only with @> (JSONB containment)
CREATE INDEX idx_bad ON products USING btree(attributes);
-- attributes @> '{"color": "red"}' will NOT use this index

-- Good: GIN for containment queries
CREATE INDEX idx_good ON products USING gin(attributes jsonb_path_ops);

-- Bad: GIN on a column used only for equality
CREATE INDEX idx_bad2 ON sessions USING gin(token);
-- token is text, not multi-valued; GIN has no benefit here

-- Good: B-tree or Hash for equality on scalar
CREATE INDEX idx_good2 ON sessions USING hash(token);
```

### Indexing Low-Cardinality Columns Without Partial

```sql
-- Bad: B-tree index on a boolean column (only 2 distinct values)
-- Planner will likely choose a seq scan anyway for common value
CREATE INDEX idx_orders_is_paid ON orders(is_paid);

-- Bad: B-tree on status with 3-4 values and one dominant
CREATE INDEX idx_orders_status ON orders(status);
-- If 95% of rows have status = 'completed', this index is useless for that value

-- Good: Partial index targeting the rare, actionable value
CREATE INDEX idx_orders_unpaid ON orders(created_at) WHERE is_paid = false;
CREATE INDEX idx_orders_pending ON orders(created_at) WHERE status = 'pending';
```

### Redundant Indexes

```sql
-- Bad: (a) is made redundant by (a, b) for queries filtering on a alone
CREATE INDEX idx_a   ON t(a);
CREATE INDEX idx_a_b ON t(a, b);

-- Check for prefix-redundant indexes
SELECT
    i1.indexname AS redundant,
    i2.indexname AS superseded_by
FROM pg_indexes i1
JOIN pg_indexes i2 ON i1.tablename = i2.tablename
    AND i1.indexname != i2.indexname
    AND position(replace(i1.indexdef, i1.indexname, '') IN i2.indexdef) > 0
WHERE i1.tablename = 'orders';
```

### Missing Indexes on Foreign Keys

Unindexed foreign keys cause sequential scans during CASCADE deletes and parent-table updates.

```sql
-- Find foreign key columns without an index
SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS referenced_table
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
    ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND NOT EXISTS (
      SELECT 1 FROM pg_index pi
      JOIN pg_attribute pa ON pa.attrelid = pi.indrelid
          AND pa.attnum = ANY(pi.indkey)
      WHERE pi.indrelid = (tc.table_name)::regclass
        AND pa.attname = kcu.column_name
  );
```

### Forgetting to Run ANALYZE After Bulk Load

```sql
-- After COPY or bulk INSERT, statistics are stale; planner makes bad choices
COPY orders FROM '/tmp/orders.csv' CSV HEADER;
ANALYZE orders;  -- always run this after bulk loads

-- Or with autovacuum disabled during load:
SET session_replication_role = replica;  -- disable FK checks for speed
COPY orders FROM '/tmp/orders.csv' CSV HEADER;
SET session_replication_role = DEFAULT;
ANALYZE orders;
```
