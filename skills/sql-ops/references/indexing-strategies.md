# SQL Indexing Strategies

Vendor-neutral indexing fundamentals. For PostgreSQL-specific index types (GIN, GiST, BRIN, Hash, partial, expression indexes), see `postgres-ops/references/indexing.md`.

## B-Tree (Default)

The standard index type across all major databases. Best for: equality, range queries, ORDER BY, prefix LIKE.

```sql
-- Standard index
CREATE INDEX idx_users_email ON users(email);

-- Unique index
CREATE UNIQUE INDEX idx_users_email ON users(email);

-- Works well for:
WHERE email = 'x@y.com'           -- equality
WHERE email LIKE 'john%'          -- prefix search
WHERE created_at > '2024-01-01'   -- range
ORDER BY created_at               -- sorting
```

## Composite Indexes

### Column Order Matters

```sql
-- Leftmost prefix rule
CREATE INDEX idx_orders ON orders(user_id, status, created_at);

-- This index supports:
WHERE user_id = 123                              -- yes
WHERE user_id = 123 AND status = 'pending'       -- yes
WHERE user_id = 123 AND status = 'pending'
  AND created_at > '2024-01-01'                  -- yes
WHERE user_id = 123
  AND created_at > '2024-01-01'                  -- partial (user_id only)
WHERE status = 'pending'                          -- no (user_id not present)
```

### Optimal Column Order

```sql
-- Rule: equality columns first, then range columns
-- Most selective equality column first when multiple equalities

-- If filtering by status (equality) and date range:
CREATE INDEX idx_orders_status_date ON orders(status, created_at);

-- If user_id is more selective than status:
CREATE INDEX idx_orders_user_status_date ON orders(user_id, status, created_at);
```

## Covering Indexes

Include extra columns to avoid table lookup (index-only scan):

```sql
-- Query needs name but filters by email
SELECT name FROM users WHERE email = 'x@y.com';

-- Covering index (PostgreSQL INCLUDE, SQL Server INCLUDE)
CREATE INDEX idx_users_email_name ON users(email) INCLUDE (name);

-- Now the query uses index-only scan (no table access needed)
```

### When to Use

```sql
-- Frequently accessed columns in SELECT
CREATE INDEX idx_orders_status ON orders(status)
INCLUDE (total, created_at);

-- Supports without table access:
SELECT total, created_at FROM orders WHERE status = 'pending';
```

## Query Analysis with EXPLAIN

```sql
-- Basic plan
EXPLAIN SELECT * FROM users WHERE email = 'x@y.com';

-- Key scan types to look for:
-- Seq Scan       - Full table scan (bad for large tables)
-- Index Scan     - Using index, then fetching rows
-- Index Only Scan - Using covering index (best)
-- Bitmap Scan    - Multiple index conditions combined
```

```sql
-- With actual execution metrics
EXPLAIN ANALYZE SELECT * FROM orders WHERE status = 'pending';

-- Shows:
-- Planning Time: 0.5 ms
-- Execution Time: 12.3 ms
-- actual rows vs estimated rows (mismatch = stale statistics)
```

## Anti-Patterns

| Mistake | Why | Fix |
|---------|-----|-----|
| Function on indexed column | Prevents index use | Expression index or rewrite query |
| `WHERE col LIKE '%text%'` | Leading wildcard, no B-tree match | Full-text search or trigram index |
| `OR` across different columns | May skip index | Rewrite as `UNION ALL` |
| Over-indexing | Slows writes, wastes space | Audit unused indexes regularly |
| Missing index on FK column | Slow cascading deletes, slow joins | Add B-tree on FK columns |

## Quick Reference

| Scenario | Index Strategy |
|----------|---------------|
| Equality lookup | B-tree on column |
| Range queries | B-tree on column |
| Multiple conditions | Composite (equality first, range last) |
| Avoid table access | Covering index with INCLUDE |
| Case-insensitive | Expression index on LOWER() |
| Full-text search | Database-specific (GIN in PostgreSQL) |

## See Also

- **PostgreSQL-specific**: `postgres-ops/references/indexing.md` - GIN, GiST, BRIN, Hash, partial, expression indexes
- **SQLite-specific**: `sqlite-ops` - SQLite indexing considerations
