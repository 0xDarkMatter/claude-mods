---
name: sqlite-ops
description: "Patterns for SQLite databases in Python projects - state management, caching, and async operations. Triggers on: sqlite, sqlite3, aiosqlite, local database, database schema, migration, wal mode."
compatibility: "Requires Python 3.8+ with sqlite3 (standard library) or aiosqlite for async."
allowed-tools: "Read Write Bash"
---

# SQLite Operations

Patterns for SQLite databases in Python projects - state management, caching, and async operations.

## Schema Design Patterns

### State/Config Storage
```sql
CREATE TABLE IF NOT EXISTS app_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Upsert pattern
INSERT INTO app_state (key, value) VALUES ('last_sync', '2024-01-15')
ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now');
```

### Cache Table
```sql
CREATE TABLE IF NOT EXISTS cache (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

-- Create index for expiry cleanup
CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache(expires_at);

-- Cleanup expired entries
DELETE FROM cache WHERE expires_at < datetime('now');
```

### Event/Log Table
```sql
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    payload TEXT,  -- JSON
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_events_type_date ON events(event_type, created_at);
```

### Deduplication Table
```sql
CREATE TABLE IF NOT EXISTS seen_items (
    hash TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    first_seen TEXT DEFAULT (datetime('now'))
);

-- Check if seen
SELECT 1 FROM seen_items WHERE hash = ? LIMIT 1;
```

## Python sqlite3 Patterns

### Connection with Best Practices
```python
import sqlite3
from pathlib import Path

def get_connection(db_path: str | Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row  # Dict-like access
    conn.execute("PRAGMA journal_mode=WAL")  # Better concurrency
    conn.execute("PRAGMA foreign_keys=ON")   # Enforce FK constraints
    return conn
```

### Context Manager Pattern
```python
from contextlib import contextmanager

@contextmanager
def db_transaction(conn: sqlite3.Connection):
    """Auto-commit or rollback on error."""
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
```

### Batch Insert
```python
def batch_insert(conn, items: list[dict]):
    """Efficient bulk insert."""
    conn.executemany(
        "INSERT OR IGNORE INTO items (id, name, data) VALUES (?, ?, ?)",
        [(i["id"], i["name"], json.dumps(i["data"])) for i in items]
    )
    conn.commit()
```

## Python aiosqlite Patterns

### Async Connection
```python
import aiosqlite

async def get_async_connection(db_path: str) -> aiosqlite.Connection:
    conn = await aiosqlite.connect(db_path)
    conn.row_factory = aiosqlite.Row
    await conn.execute("PRAGMA journal_mode=WAL")
    await conn.execute("PRAGMA foreign_keys=ON")
    return conn
```

### Async Context Manager
```python
async def query_items(db_path: str, status: str) -> list[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM items WHERE status = ?", (status,)
        ) as cursor:
            rows = await cursor.fetchall()
            return [dict(row) for row in rows]
```

### Async Batch Operations
```python
async def batch_update_status(db_path: str, ids: list[int], status: str):
    async with aiosqlite.connect(db_path) as db:
        await db.executemany(
            "UPDATE items SET status = ? WHERE id = ?",
            [(status, id) for id in ids]
        )
        await db.commit()
```

## WAL Mode (Write-Ahead Logging)

**Enable for concurrent read/write:**
```python
conn.execute("PRAGMA journal_mode=WAL")
```

| Mode | Reads | Writes | Best For |
|------|-------|--------|----------|
| DELETE (default) | Blocked during write | Single | Simple scripts |
| WAL | Concurrent | Single | Web apps, MCP servers |

**Checkpoint WAL periodically:**
```python
conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
```

## Migration Pattern

```python
MIGRATIONS = [
    # Version 1
    """
    CREATE TABLE IF NOT EXISTS items (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
    );
    """,
    # Version 2 - add status column
    """
    ALTER TABLE items ADD COLUMN status TEXT DEFAULT 'active';
    CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);
    """,
]

def migrate(conn: sqlite3.Connection):
    """Apply pending migrations."""
    conn.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER)")

    result = conn.execute("SELECT version FROM schema_version").fetchone()
    current = result[0] if result else 0

    for i, migration in enumerate(MIGRATIONS[current:], start=current):
        conn.executescript(migration)
        conn.execute("DELETE FROM schema_version")
        conn.execute("INSERT INTO schema_version VALUES (?)", (i + 1,))
        conn.commit()
```

## Query Optimization

### Use EXPLAIN QUERY PLAN
```python
plan = conn.execute("EXPLAIN QUERY PLAN SELECT * FROM items WHERE status = ?", ("active",)).fetchall()
for row in plan:
    print(row)
# Look for "SCAN" (bad) vs "SEARCH" or "USING INDEX" (good)
```

### Common Index Patterns
```sql
-- Single column (equality + range)
CREATE INDEX idx_items_status ON items(status);

-- Composite (filter + sort)
CREATE INDEX idx_items_status_date ON items(status, created_at);

-- Covering index (avoid table lookup)
CREATE INDEX idx_items_status_covering ON items(status) INCLUDE (name, created_at);
```

## JSON in SQLite

```sql
-- Store JSON
INSERT INTO events (payload) VALUES ('{"type": "click", "x": 100}');

-- Query JSON (SQLite 3.38+)
SELECT json_extract(payload, '$.type') as event_type FROM events;

-- Filter by JSON value
SELECT * FROM events WHERE json_extract(payload, '$.type') = 'click';
```

## CLI Quick Reference

```bash
# Open database
sqlite3 mydb.sqlite

# Show tables
.tables

# Show schema
.schema items

# Export to CSV
.headers on
.mode csv
.output items.csv
SELECT * FROM items;
.output stdout

# Import CSV
.mode csv
.import items.csv items

# Run SQL file
.read schema.sql

# Vacuum (reclaim space)
VACUUM;
```

## Common Gotchas

| Issue | Solution |
|-------|----------|
| "database is locked" | Use WAL mode, or ensure single writer |
| Slow queries | Add indexes, check EXPLAIN QUERY PLAN |
| Memory issues with large results | Use `fetchmany(1000)` in batches |
| Thread safety | Use `check_same_thread=False` + connection per thread |
| Foreign key not enforced | Run `PRAGMA foreign_keys=ON` after connect |
| datetime storage | Store as TEXT in ISO format, use `datetime()` function |
