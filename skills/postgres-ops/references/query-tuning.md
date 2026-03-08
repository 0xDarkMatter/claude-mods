# PostgreSQL Query Tuning Reference

## Table of Contents

1. [EXPLAIN Output Reference](#explain-output-reference)
2. [Plan Node Reference](#plan-node-reference)
3. [pg_stat_statements](#pg_stat_statements)
4. [Common Optimization Patterns](#common-optimization-patterns)
5. [Parallel Query](#parallel-query)
6. [Statistics and Planner](#statistics-and-planner)

---

## EXPLAIN Output Reference

### Format Options

```sql
-- Default text format (human readable)
EXPLAIN SELECT * FROM orders WHERE customer_id = 42;

-- With actual execution stats (runs the query)
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 42;

-- Full verbose output with all options
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT) SELECT * FROM orders WHERE customer_id = 42;

-- JSON format for programmatic parsing
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM orders WHERE customer_id = 42;

-- YAML format
EXPLAIN (ANALYZE, BUFFERS, FORMAT YAML) SELECT * FROM orders WHERE customer_id = 42;
```

### Key Fields Decoded

```
Seq Scan on orders  (cost=0.00..4821.00 rows=1000 width=64)
                          ^      ^       ^         ^
                          |      |       |         estimated avg row width (bytes)
                          |      |       estimated output rows
                          |      total cost (return last row)
                          startup cost (return first row)

(actual time=0.042..18.340 rows=987 loops=1)
              ^       ^     ^        ^
              |       |     |        number of times node executed
              |       |     actual rows returned
              |       actual time to return last row (ms)
              actual time to return first row (ms)
```

**Startup cost vs total cost**: An index scan on a large table may have a high startup cost
(building the bitmap) but low total cost per row. Nested loops favor low startup cost.
A sort node has startup cost = full sort cost because no rows are returned until sorted.

**Loops**: When a node has `loops=N`, the `actual time` is per-loop average and `actual rows`
is per-loop average. Multiply by loops to get totals. This matters for nested loop inners.

```sql
-- Identify row estimate errors (poor estimates = bad plans)
-- Look for large divergence between "rows=X" and "actual rows=Y"
-- A 10x+ difference warrants investigation via ANALYZE or statistics adjustments
```

### Buffer Information

```
Buffers: shared hit=1024 read=256 dirtied=10 written=5
          ^              ^         ^           ^
          |              |         |           pages written to disk
          |              |         pages modified during query
          |              pages read from disk (cache miss)
          pages served from shared_buffers (cache hit)
```

Cache hit ratio for a single query:
- `hit / (hit + read)` -- aim for > 0.99 in OLTP workloads

### Reading Execution Time

```sql
-- Planning time vs execution time appear at bottom of EXPLAIN ANALYZE output
-- Planning Time: 1.234 ms
-- Execution Time: 45.678 ms
-- High planning time relative to execution suggests query plan caching issues
-- or extremely complex queries with many joins
```

---

## Plan Node Reference

### Scan Types

**Sequential Scan** -- reads entire table from disk in order.
Chosen when: selectivity is high (returning large fraction of rows), no suitable index,
small table fits in a few pages, or planner estimates index overhead exceeds benefit.

```sql
-- Force/prevent seq scan for testing (session level)
SET enable_seqscan = off;   -- discourages seq scan
SET enable_seqscan = on;    -- restore default
```

**Index Scan** -- follows index B-tree to find heap row pointers, fetches each heap page.
Chosen when: high selectivity (few rows), index covers filter column, ORDER BY matches index.
Drawback: random I/O on heap. Can be slower than seq scan on spinning disk for > ~5% of table.

**Index Only Scan** -- satisfies query entirely from index, no heap fetch (if visibility map allows).
Requires: all SELECT and WHERE columns in the index. Needs up-to-date visibility map (regular VACUUM).

```sql
-- Check if index only scan is blocked by visibility map
SELECT relname, n_dead_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'orders';

-- Create covering index to enable index only scan
CREATE INDEX idx_orders_covering ON orders (customer_id) INCLUDE (total, status, created_at);
```

**Bitmap Index Scan + Bitmap Heap Scan** -- builds bitmap of matching pages in memory,
then fetches those pages in order (reduces random I/O vs plain Index Scan for moderate selectivity).
Two-phase: BitmapIndexScan builds the bitmap, BitmapHeapScan fetches heap pages.

```sql
-- Bitmap scans combine multiple indexes via BitmapAnd / BitmapOr
-- Useful when query has multiple filter conditions each with their own index
EXPLAIN SELECT * FROM orders WHERE status = 'pending' AND region = 'EU';
-- May show: BitmapAnd -> BitmapIndexScan on idx_status + BitmapIndexScan on idx_region
```

### Join Types

**Nested Loop** -- for each outer row, scan inner relation.
Cost: O(outer_rows * inner_scan_cost). Best when outer is small and inner lookup is fast (indexed).
Chosen when: outer result set is small, inner has index on join column.

```sql
-- Nested loop is ideal for:
-- SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.id = 99;
-- (single order -> single customer lookup via PK)

SET enable_nestloop = off;  -- force alternative join type for testing
```

**Hash Join** -- build hash table from smaller relation, probe with larger.
Cost: O(build + probe). Best for large unsorted relations with no useful index on join key.
Chosen when: joining large tables, no index on join columns, equality join only.
Memory: controlled by `work_mem`. If hash table exceeds work_mem, spills to disk (batch mode).

```sql
-- Check for hash join disk spills in EXPLAIN ANALYZE
-- Batches: 4 means spilled to disk in 4 batches -- increase work_mem to fix
-- Hash Batches: 1 is ideal (all in memory)
SET work_mem = '256MB';  -- session level for large analytical queries
```

**Merge Join** -- sort both relations on join key, merge in order.
Cost: O(N log N + M log M) for sorting. Best when inputs are already sorted (index).
Chosen when: both sides are large, inputs already sorted, range or equality join.

```sql
SET enable_hashjoin = off;
SET enable_mergejoin = off;
-- Use sparingly in production; better to fix the cause (add index, fix statistics)
```

### Aggregation

**HashAggregate** -- builds hash table of group keys, accumulates aggregates.
Chosen for: unsorted input, many distinct groups. Memory: bounded by `work_mem`.
When it exceeds work_mem, spills to disk (check `Disk: XkB` in EXPLAIN ANALYZE output).

**GroupAggregate** -- streams sorted input, emits group when key changes.
Chosen when: input already sorted on GROUP BY columns (index), or few distinct groups.
Zero memory overhead but requires sorted input.

```sql
-- Force sorted approach by ensuring index on GROUP BY columns
CREATE INDEX idx_orders_customer ON orders (customer_id, created_at);
-- Now GROUP BY customer_id may use GroupAggregate instead of HashAggregate
```

### Sort Operations

```sql
EXPLAIN ANALYZE SELECT * FROM orders ORDER BY created_at DESC LIMIT 100;

-- In-memory sort: Sort Method: quicksort  Memory: 2048kB
-- Disk sort:      Sort Method: external merge  Disk: 512000kB  -- bad, increase work_mem

-- Top-N Heapsort: Sort Method: top-N heapsort  Memory: 64kB  -- efficient for LIMIT
-- Top-N heapsort is optimal for ORDER BY ... LIMIT N patterns
```

---

## pg_stat_statements

### Setup

```sql
-- postgresql.conf (requires restart)
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 10000          -- number of query fingerprints tracked
pg_stat_statements.track = all          -- top|all|none (all includes nested queries)
pg_stat_statements.track_utility = on   -- track COPY, CREATE TABLE, etc.

-- After restart, create extension in each database you want to monitor
CREATE EXTENSION pg_stat_statements;
```

### Key Columns (PostgreSQL 14+)

```sql
SELECT
    queryid,                          -- internal hash identifier
    query,                            -- normalized query text (params replaced with $1, $2)
    calls,                            -- number of times executed
    total_exec_time,                  -- total execution time (ms)
    mean_exec_time,                   -- avg execution time (ms)
    stddev_exec_time,                 -- std deviation (high = inconsistent)
    min_exec_time,
    max_exec_time,
    rows,                             -- total rows returned/affected
    shared_blks_hit,                  -- buffer cache hits
    shared_blks_read,                 -- disk reads
    shared_blks_dirtied,
    shared_blks_written,
    temp_blks_read,                   -- temp file reads (work_mem overflow)
    temp_blks_written,
    wal_bytes,                        -- WAL generated (high = write-heavy)
    toplevel                          -- true if called at top level (PG14+)
FROM pg_stat_statements;
```

### Finding Problem Queries

```sql
-- Top 10 queries by total time (cumulative load on server)
SELECT
    round(total_exec_time::numeric, 2) AS total_ms,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_total,
    left(query, 80) AS query_snippet
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Top 10 by mean execution time (slowest individual queries)
SELECT
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    round(max_exec_time::numeric, 2) AS max_ms,
    left(query, 80) AS query_snippet
FROM pg_stat_statements
WHERE calls > 10                   -- ignore rarely-run queries
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Queries with worst cache hit ratio (I/O bound candidates)
SELECT
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    shared_blks_hit + shared_blks_read AS total_blks,
    round(
        100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0),
        2
    ) AS hit_pct,
    left(query, 80) AS query_snippet
FROM pg_stat_statements
WHERE shared_blks_hit + shared_blks_read > 1000
ORDER BY hit_pct ASC
LIMIT 10;

-- Queries generating most temp files (work_mem too low or bad query)
SELECT
    calls,
    temp_blks_written,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    left(query, 80) AS query_snippet
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;
```

### Reset Strategy

```sql
-- Reset stats for all queries (do after tuning to get fresh baseline)
SELECT pg_stat_statements_reset();

-- Reset stats for specific query (PG12+ by queryid)
SELECT pg_stat_statements_reset(userid, dbid, queryid)
FROM pg_stat_statements
WHERE query LIKE '%orders%'
LIMIT 1;
```

---

## Common Optimization Patterns

### CTE Materialization (PostgreSQL 12+)

```sql
-- Pre-PG12: CTEs were always materialized (optimization fence)
-- PG12+: planner decides, but you can force behavior

-- MATERIALIZED: always execute CTE once and cache result
-- Use when: CTE is expensive but referenced multiple times
WITH expensive_agg AS MATERIALIZED (
    SELECT customer_id, sum(total) AS lifetime_value
    FROM orders
    GROUP BY customer_id
)
SELECT c.name, e.lifetime_value
FROM customers c
JOIN expensive_agg e ON e.customer_id = c.id;

-- NOT MATERIALIZED: inline the CTE (allow planner to push predicates in)
-- Use when: CTE is referenced once, or predicate pushdown is important
WITH recent_orders AS NOT MATERIALIZED (
    SELECT * FROM orders WHERE status = 'complete'
)
SELECT * FROM recent_orders WHERE customer_id = 42;
-- Planner can now push "customer_id = 42" into the subquery and use an index
```

### EXISTS vs IN vs JOIN

```sql
-- EXISTS: short-circuits on first match, good for correlated checks
-- Best when: checking existence only, inner side can be large
SELECT c.id, c.name
FROM customers c
WHERE EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.status = 'pending'
);

-- IN with subquery: similar to EXISTS in modern PG (planner converts to semi-join)
-- Bad when: subquery returns NULLs (IN with NULLs behaves unexpectedly)
SELECT c.id, c.name
FROM customers c
WHERE c.id IN (SELECT customer_id FROM orders WHERE status = 'pending');

-- JOIN (semi-join via DISTINCT): explicit, predictable
-- Needed when: you want columns from both sides, or deduplication matters
SELECT DISTINCT c.id, c.name
FROM customers c
JOIN orders o ON o.customer_id = c.id AND o.status = 'pending';

-- NOT IN danger with NULLs: returns zero rows if subquery has any NULL
-- Always use NOT EXISTS for negation checks
SELECT * FROM customers WHERE id NOT IN (SELECT customer_id FROM orders);
-- If ANY customer_id in orders is NULL, returns no rows!
-- Use instead:
SELECT * FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);
```

### Lateral Join vs Subquery

```sql
-- LATERAL: allows subquery to reference columns from preceding FROM items
-- Useful for: top-N per group, correlated row-limited subqueries

-- Top 3 orders per customer (lateral is clean and indexed)
SELECT c.name, o.id, o.total
FROM customers c
CROSS JOIN LATERAL (
    SELECT id, total
    FROM orders
    WHERE customer_id = c.id
    ORDER BY total DESC
    LIMIT 3
) o;

-- Equivalent window function approach (often similar performance)
SELECT name, order_id, total
FROM (
    SELECT c.name, o.id AS order_id, o.total,
           row_number() OVER (PARTITION BY c.id ORDER BY o.total DESC) AS rn
    FROM customers c
    JOIN orders o ON o.customer_id = c.id
) ranked
WHERE rn <= 3;
```

### Pagination: OFFSET vs Keyset

```sql
-- OFFSET pagination: simple but degrades at high page numbers
-- At page 1000 with LIMIT 20, PostgreSQL fetches 20020 rows and discards 20000
SELECT id, name, created_at FROM orders ORDER BY created_at DESC LIMIT 20 OFFSET 20000;

-- Keyset (cursor) pagination: O(1) regardless of page depth
-- Requires: sorting by unique+indexed column(s), no arbitrary page jumping
-- After receiving last row of previous page with (created_at='2024-01-15', id=9876):
SELECT id, name, created_at
FROM orders
WHERE (created_at, id) < ('2024-01-15', 9876)  -- uses row comparison
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Index to support keyset:
CREATE INDEX idx_orders_keyset ON orders (created_at DESC, id DESC);
```

### DISTINCT ON vs Window Function Deduplication

```sql
-- DISTINCT ON: PostgreSQL extension, returns first row per group (by ORDER BY)
-- Fast, single pass, leverages index on distinct columns
SELECT DISTINCT ON (customer_id)
    customer_id, id AS order_id, total, created_at
FROM orders
ORDER BY customer_id, created_at DESC;   -- gets most recent order per customer

-- Create index to support: (customer_id, created_at DESC)
CREATE INDEX idx_orders_latest ON orders (customer_id, created_at DESC);

-- Window function equivalent (more portable, more flexible)
SELECT customer_id, order_id, total, created_at
FROM (
    SELECT customer_id, id AS order_id, total, created_at,
           row_number() OVER (PARTITION BY customer_id ORDER BY created_at DESC) AS rn
    FROM orders
) t
WHERE rn = 1;
```

### Bulk Operations

```sql
-- COPY is fastest for bulk insert (bypasses most overhead)
-- From file:
COPY orders (customer_id, total, status) FROM '/tmp/orders.csv' WITH (FORMAT csv, HEADER);

-- From stdin (psql):
\COPY orders (customer_id, total, status) FROM 'orders.csv' CSV HEADER

-- unnest trick for bulk insert from application (avoids N round trips)
-- Send arrays of values, unnest server-side
INSERT INTO orders (customer_id, total, status)
SELECT * FROM unnest(
    ARRAY[1, 2, 3],              -- customer_ids
    ARRAY[100.00, 200.00, 50.00], -- totals
    ARRAY['pending', 'complete', 'pending']::text[]
) AS t(customer_id, total, status);

-- For very large bulk loads, disable indexes and re-add after:
ALTER TABLE orders DISABLE TRIGGER ALL;
-- ... COPY ...
ALTER TABLE orders ENABLE TRIGGER ALL;
-- Or: drop indexes, load, recreate (faster than incremental index updates)

-- Batch INSERT with ON CONFLICT (UPSERT)
INSERT INTO order_status_log (order_id, status, updated_at)
VALUES (1, 'shipped', now()), (2, 'delivered', now())
ON CONFLICT (order_id) DO UPDATE
    SET status = EXCLUDED.status,
        updated_at = EXCLUDED.updated_at;
```

---

## Parallel Query

### Configuration Settings

```sql
-- Key settings (postgresql.conf or ALTER SYSTEM)
max_parallel_workers_per_gather = 4      -- max workers per Gather node (default: 2)
max_parallel_workers = 8                  -- total parallel workers across all queries
max_worker_processes = 16                 -- total background workers (includes parallel)
min_parallel_table_scan_size = '8MB'     -- table must be > this for parallel seq scan
min_parallel_index_scan_size = '512kB'   -- index must be > this for parallel index scan
parallel_tuple_cost = 0.1                -- cost of passing tuple between workers
parallel_setup_cost = 1000               -- overhead of launching workers
```

### When Parallel Query Engages

```sql
-- Parallel is chosen when: large table, high work_mem not limiting, no write operations
-- Check if parallel is being used:
EXPLAIN SELECT count(*), avg(total) FROM orders;
-- Should show: Gather -> Partial Aggregate -> Parallel Seq Scan on orders

-- Force parallel for testing (lower thresholds):
SET min_parallel_table_scan_size = 0;
SET parallel_setup_cost = 0;
SET max_parallel_workers_per_gather = 4;
```

### When Parallel Does NOT Kick In

- Queries that write (INSERT, UPDATE, DELETE, MERGE)
- Queries inside functions marked `PARALLEL UNSAFE` (default for user functions)
- Queries using cursors (`DECLARE ... CURSOR FOR`)
- Queries called from another parallel worker
- When `max_parallel_workers_per_gather = 0`
- When `LIMIT` is small relative to table size (planner avoids parallel startup cost)

```sql
-- Mark functions parallel safe to allow parallel plans that call them
CREATE OR REPLACE FUNCTION calculate_discount(total numeric) RETURNS numeric
LANGUAGE sql
PARALLEL SAFE    -- only if function has no side effects and is truly safe
AS $$
    SELECT total * 0.9;
$$;
```

---

## Statistics and Planner

### Column Statistics

```sql
-- Default statistics target is 100 (samples ~30000 rows per column)
-- Increase for columns with many distinct values or skewed distributions

-- Check current statistics targets
SELECT attname, attstattarget
FROM pg_attribute
WHERE attrelid = 'orders'::regclass AND attnum > 0;

-- Increase statistics for a specific column
ALTER TABLE orders ALTER COLUMN status SET STATISTICS 500;
ANALYZE orders;  -- must re-run ANALYZE to collect new statistics

-- Check what the planner knows about a column
SELECT * FROM pg_stats
WHERE tablename = 'orders' AND attname = 'status';
-- Key fields: n_distinct, most_common_vals, most_common_freqs, histogram_bounds
```

### Extended Statistics

```sql
-- When two columns are correlated, single-column stats mislead the planner
-- Example: city and zip_code are correlated; planner underestimates after filtering both

-- Create extended statistics to capture column correlations
CREATE STATISTICS orders_region_status_stats (dependencies, ndistinct)
    ON region, status FROM orders;

ANALYZE orders;

-- Check extended statistics
SELECT * FROM pg_statistic_ext;
SELECT * FROM pg_statistic_ext_data;

-- MCV (most common values) extended statistics
CREATE STATISTICS orders_mcv ON region, status FROM orders
    WITH (kind = mcv);
ANALYZE orders;
```

### n_distinct Overrides

```sql
-- When planner guesses wrong number of distinct values
-- Positive value = exact count, negative = fraction of total rows

-- Tell planner there are exactly 50 distinct statuses
ALTER TABLE orders ALTER COLUMN status SET (n_distinct = 50);

-- Tell planner distinct count is 10% of table rows
ALTER TABLE orders ALTER COLUMN customer_id SET (n_distinct = -0.1);

ANALYZE orders;  -- re-analyze to apply
```

### pg_hint_plan (Last Resort)

```sql
-- Install pg_hint_plan extension (not in core, must compile or use package)
-- Use only when statistics fixes and index changes are insufficient

-- Hints are embedded in comments before the query
/*+ SeqScan(orders) */ SELECT * FROM orders WHERE status = 'pending';

/*+ IndexScan(orders idx_orders_status) */ SELECT * FROM orders WHERE status = 'pending';

/*+ HashJoin(orders customers) Leading(orders customers) */
SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id;

-- Available hint types:
-- Scan: SeqScan, IndexScan, IndexOnlyScan, BitmapScan, NoSeqScan, NoIndexScan
-- Join: NestLoop, HashJoin, MergeJoin, NoNestLoop, NoHashJoin, NoMergeJoin
-- Join order: Leading(table1 table2 table3)
-- Parallel: Parallel(table N)  -- N = number of workers

-- Always document WHY a hint is needed and create a ticket to fix root cause
-- Hints become stale as data grows and can cause regressions after schema changes
```

### Diagnosing Estimate vs Actual Divergence

```sql
-- Large divergence between estimated and actual rows is the #1 cause of bad plans
-- Use this query pattern to identify problem queries via pg_stat_statements + EXPLAIN

-- Step 1: find high-variance queries in pg_stat_statements
-- Step 2: run EXPLAIN ANALYZE and look for nodes where rows estimate is off by 10x+
-- Step 3: check pg_stats for the filtered columns

-- Example: orders table filtered on two correlated columns
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT * FROM orders WHERE region = 'US' AND status = 'pending';

-- If estimated rows = 10 but actual rows = 50000, investigate:
SELECT n_distinct, most_common_vals, most_common_freqs
FROM pg_stats
WHERE tablename = 'orders' AND attname IN ('region', 'status');

-- Fix options in priority order:
-- 1. ANALYZE (if stats are stale)
-- 2. Increase statistics target: ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 500
-- 3. Create extended statistics for correlated columns
-- 4. Rewrite query to give planner better information
-- 5. pg_hint_plan as absolute last resort
```
