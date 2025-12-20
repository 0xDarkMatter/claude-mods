---
name: sql-patterns
description: "Quick reference for common SQL patterns, CTEs, window functions, and indexing strategies. Triggers on: sql patterns, cte example, window functions, sql join, index strategy, pagination sql."
allowed-tools: "Read Write"
---

# SQL Patterns

Quick reference for common SQL patterns, CTEs, window functions, and indexing strategies.

## CTE (Common Table Expressions)

### Basic CTE
```sql
WITH active_users AS (
    SELECT id, name, email
    FROM users
    WHERE status = 'active'
)
SELECT * FROM active_users WHERE created_at > '2024-01-01';
```

### Chained CTEs
```sql
WITH
    active_users AS (
        SELECT id, name FROM users WHERE status = 'active'
    ),
    user_orders AS (
        SELECT user_id, COUNT(*) as order_count
        FROM orders
        GROUP BY user_id
    )
SELECT u.name, COALESCE(o.order_count, 0) as orders
FROM active_users u
LEFT JOIN user_orders o ON u.id = o.user_id;
```

### Recursive CTE (Hierarchies)
```sql
WITH RECURSIVE org_tree AS (
    -- Base case: top-level managers
    SELECT id, name, manager_id, 1 as level
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    -- Recursive case: employees under managers
    SELECT e.id, e.name, e.manager_id, t.level + 1
    FROM employees e
    JOIN org_tree t ON e.manager_id = t.id
)
SELECT * FROM org_tree ORDER BY level, name;
```

## Window Functions

### ROW_NUMBER (Unique sequential)
```sql
SELECT
    name,
    department,
    salary,
    ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) as rank
FROM employees;
```

### RANK / DENSE_RANK (Ties allowed)
```sql
-- RANK: 1, 2, 2, 4 (skips after ties)
-- DENSE_RANK: 1, 2, 2, 3 (no skip)
SELECT
    name,
    score,
    RANK() OVER (ORDER BY score DESC) as rank,
    DENSE_RANK() OVER (ORDER BY score DESC) as dense_rank
FROM contestants;
```

### LAG / LEAD (Previous/Next row)
```sql
SELECT
    date,
    revenue,
    LAG(revenue, 1) OVER (ORDER BY date) as prev_day,
    revenue - LAG(revenue, 1) OVER (ORDER BY date) as change
FROM daily_sales;
```

### Running Total
```sql
SELECT
    date,
    amount,
    SUM(amount) OVER (ORDER BY date) as running_total
FROM transactions;
```

### Moving Average
```sql
SELECT
    date,
    value,
    AVG(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) as moving_avg_7day
FROM metrics;
```

## JOIN Reference

| Type | Returns |
|------|---------|
| `INNER JOIN` | Only matching rows from both |
| `LEFT JOIN` | All from left + matching from right |
| `RIGHT JOIN` | All from right + matching from left |
| `FULL JOIN` | All from both, NULL where no match |
| `CROSS JOIN` | Cartesian product (all combinations) |

### Self Join (Same table)
```sql
SELECT e.name as employee, m.name as manager
FROM employees e
LEFT JOIN employees m ON e.manager_id = m.id;
```

## Pagination Patterns

### OFFSET/LIMIT (Simple, slow for large offsets)
```sql
SELECT * FROM products
ORDER BY id
LIMIT 20 OFFSET 40;  -- Page 3, 20 per page
```

### Keyset Pagination (Fast, scalable)
```sql
-- First page
SELECT * FROM products ORDER BY id LIMIT 20;

-- Next page (where last id was 42)
SELECT * FROM products WHERE id > 42 ORDER BY id LIMIT 20;
```

## Index Strategies

| Index Type | Best For |
|------------|----------|
| **B-tree** | Default, range queries, ORDER BY |
| **Hash** | Exact equality only |
| **GIN** | Arrays, JSONB, full-text |
| **GiST** | Geometric, full-text |
| **Covering** | Include columns to avoid table lookup |

### Covering Index
```sql
-- Query needs name but filters on email
CREATE INDEX idx_users_email_name ON users(email) INCLUDE (name);

-- Now this is index-only:
SELECT name FROM users WHERE email = 'x@y.com';
```

### Composite Index Order
```sql
-- Leftmost prefix rule: (a, b, c) supports:
-- WHERE a = ?
-- WHERE a = ? AND b = ?
-- WHERE a = ? AND b = ? AND c = ?
-- NOT: WHERE b = ? (a must be present)
CREATE INDEX idx_orders ON orders(user_id, status, created_at);
```

## EXISTS vs IN

```sql
-- EXISTS: Often faster for large outer, small inner
SELECT * FROM orders o
WHERE EXISTS (SELECT 1 FROM users u WHERE u.id = o.user_id AND u.status = 'active');

-- IN: Often faster for small list, can be optimized
SELECT * FROM orders
WHERE user_id IN (SELECT id FROM users WHERE status = 'active');
```

## Anti-Patterns to Avoid

| Anti-Pattern | Problem | Fix |
|--------------|---------|-----|
| `SELECT *` | Over-fetches, breaks on schema change | List columns explicitly |
| Function on indexed column | `WHERE YEAR(date) = 2024` prevents index | `WHERE date >= '2024-01-01'` |
| `OR` in WHERE | May prevent index usage | Use `UNION` or rewrite |
| N+1 queries | Loop with query per item | Single JOIN or batch |
| `DISTINCT` to fix duplicates | Masks JOIN issues | Fix the JOIN logic |
| `NOT IN` with NULLs | Returns wrong results | Use `NOT EXISTS` instead |

## NULL Handling

```sql
-- NULL comparisons
WHERE column IS NULL        -- Correct
WHERE column IS NOT NULL    -- Correct
WHERE column = NULL         -- WRONG (always false)

-- COALESCE for defaults
SELECT COALESCE(nickname, name, 'Anonymous') as display_name FROM users;

-- NULLIF to create NULLs
SELECT amount / NULLIF(count, 0) as average FROM stats;  -- Avoids divide by zero
```

## Batch Operations

```sql
-- Insert multiple rows
INSERT INTO users (name, email) VALUES
    ('Alice', 'a@x.com'),
    ('Bob', 'b@x.com'),
    ('Carol', 'c@x.com');

-- Update with limit (process in batches)
UPDATE orders SET status = 'archived'
WHERE status = 'completed' AND updated_at < '2023-01-01'
LIMIT 1000;
```
