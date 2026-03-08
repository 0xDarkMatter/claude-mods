# PostgreSQL Operations Reference

## Table of Contents

1. [Backup Strategies](#backup-strategies)
2. [Vacuum Deep Dive](#vacuum-deep-dive)
3. [Monitoring](#monitoring)
4. [Connection Pooling](#connection-pooling)

---

## Backup Strategies

### pg_dump

Logical backup of a single database. Consistent snapshot via a single transaction.
Does not back up roles, tablespaces, or server-level configuration.

```bash
# Custom format (-Fc): compressed, parallel-restorable, most versatile
pg_dump -h localhost -U postgres -d mydb -Fc -f mydb.dump

# Plain SQL format (-Fp): human-readable, pipe-friendly, not parallel-restorable
pg_dump -h localhost -U postgres -d mydb -Fp -f mydb.sql

# Directory format (-Fd): one file per table, supports parallel dump and restore
pg_dump -h localhost -U postgres -d mydb -Fd -f mydb_dir/

# Parallel dump (directory format required, -j = number of workers)
pg_dump -h localhost -U postgres -d mydb -Fd -j 4 -f mydb_dir/

# Compressed with explicit compression level (PG16+ supports --compress=lz4)
pg_dump -h localhost -U postgres -d mydb -Fc --compress=9 -f mydb.dump

# Dump only specific tables
pg_dump -h localhost -U postgres -d mydb -Fc -t orders -t customers -f subset.dump

# Dump only schema (no data)
pg_dump -h localhost -U postgres -d mydb -Fc --schema-only -f schema.dump

# Dump only data (no DDL)
pg_dump -h localhost -U postgres -d mydb -Fc --data-only -f data.dump

# Exclude specific tables (e.g., large log tables)
pg_dump -h localhost -U postgres -d mydb -Fc -T audit_logs -T event_stream -f mydb.dump
```

#### pg_restore

```bash
# Restore custom/directory format
pg_restore -h localhost -U postgres -d mydb_restore -Fc mydb.dump

# Parallel restore (directory format)
pg_restore -h localhost -U postgres -d mydb_restore -Fd -j 4 mydb_dir/

# Restore single table from full dump
pg_restore -h localhost -U postgres -d mydb -t orders mydb.dump

# Restore schema only, then data (useful for pre-creating indexes)
pg_restore -h localhost -U postgres -d mydb --schema-only mydb.dump
pg_restore -h localhost -U postgres -d mydb --data-only mydb.dump

# --no-owner / --no-privileges: skip ownership and ACL statements
pg_restore -h localhost -U postgres -d mydb --no-owner --no-privileges mydb.dump
```

### pg_dumpall

Backs up all databases plus server-level objects (roles, tablespaces).
Output is always plain SQL (no custom/directory format support).

```bash
# Full cluster backup
pg_dumpall -h localhost -U postgres -f cluster_backup.sql

# Globals only (roles and tablespaces, no database data)
pg_dumpall -h localhost -U postgres --globals-only -f globals.sql

# Restore
psql -h localhost -U postgres -f cluster_backup.sql
```

### pg_basebackup

Physical backup of the entire cluster. Required for PITR and streaming replication setup.
Much faster than pg_dump for large databases since it copies raw files.

```bash
# Basic base backup (plain format, WAL streamed during backup)
pg_basebackup -h localhost -U replicator -D /backup/base -P

# Include WAL files in backup (-Xs = stream WAL during backup)
pg_basebackup -h localhost -U replicator -D /backup/base -Xs -P

# Tar format with gzip compression (one .tar.gz per tablespace)
pg_basebackup -h localhost -U replicator -D /backup/base -Ft -z -P

# Tar format with LZ4 (PG15+, faster than gzip)
pg_basebackup -h localhost -U replicator -D /backup/base -Ft --compress=lz4 -P

# Checkpoint mode: fast = force immediate checkpoint, spread = rate-limited I/O
pg_basebackup -h localhost -U replicator -D /backup/base -Xs --checkpoint=fast -P

# Required postgresql.conf settings for pg_basebackup:
# wal_level = replica          (minimum)
# max_wal_senders = 3          (at least 1 available sender)
# archive_mode = on            (for PITR)
```

### PITR: Point-in-Time Recovery

PITR combines a base backup with WAL archive segments to restore to any point in time.

#### WAL Archiving Setup

```bash
# postgresql.conf settings
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /wal_archive/%f && cp %p /wal_archive/%f'
# %p = full path to WAL file, %f = filename only

# With AWS S3 (using WAL-E or pgBackRest in production)
archive_command = 'aws s3 cp %p s3://my-bucket/wal-archive/%f'

# Verify archive is working
SELECT pg_switch_wal();  -- force WAL segment switch to test archive_command
-- Check /wal_archive for new .wal files
```

#### Recovery Configuration

Create `recovery.signal` file in PGDATA to trigger recovery mode (PG12+).
Recovery parameters go in `postgresql.conf` (PG12+) or `recovery.conf` (pre-PG12).

```bash
# postgresql.conf additions for recovery
restore_command = 'cp /wal_archive/%f %p'
# or from S3:
restore_command = 'aws s3 cp s3://my-bucket/wal-archive/%f %p'

# Recovery target options (pick one):
recovery_target_time = '2024-03-15 14:30:00'        # time-based
recovery_target_xid = '1234567'                       # transaction ID
recovery_target_lsn = '0/15D5A50'                    # LSN
recovery_target_name = 'before_migration'             # named restore point
recovery_target = 'immediate'                         # as soon as consistent

# After reaching target:
recovery_target_action = 'promote'   # promote to primary (default)
recovery_target_action = 'pause'     # pause, inspect, then pg_wal_replay_resume()
recovery_target_action = 'shutdown'  # stop after recovery

# Named restore points (create before risky operations)
SELECT pg_create_restore_point('before_bulk_delete');
```

```bash
# Full PITR procedure:
# 1. Stop PostgreSQL
# 2. Move PGDATA aside: mv /var/lib/postgresql/14/main /var/lib/postgresql/14/main.bak
# 3. Restore base backup: pg_basebackup ... or extract tar
# 4. Add recovery settings to postgresql.conf
# 5. Touch recovery.signal: touch $PGDATA/recovery.signal
# 6. Start PostgreSQL -- it will replay WAL until target, then promote
```

### Backup Verification

```bash
# pg_verifybackup (PG13+): verify base backup integrity
pg_verifybackup /backup/base

# Check backup manifest
pg_verifybackup --no-manifest-checksums /backup/base  # skip slow checksum verify

# Test restore (do this regularly in staging)
pg_restore --list mydb.dump | head -20   # check contents without restoring

# Verify dump readability
pg_restore -l mydb.dump > /dev/null && echo "Dump is readable"
```

---

## Vacuum Deep Dive

### Regular VACUUM vs VACUUM FULL vs pg_repack

**Regular VACUUM**: marks dead tuples as reusable space. Does not shrink table on disk.
Non-blocking (shares table with readers and writers). Run this routinely.

**VACUUM FULL**: rewrites entire table to new file, reclaiming disk space.
Requires exclusive lock (blocks all access). Causes table/index bloat to disappear.
Rarely needed if autovacuum is tuned correctly.

**pg_repack**: rewrites table without long exclusive lock (builds new table in background,
swaps at end with brief lock). Preferred over VACUUM FULL for large production tables.

```sql
-- Regular VACUUM (non-blocking)
VACUUM orders;

-- VACUUM with ANALYZE (update statistics too)
VACUUM ANALYZE orders;

-- VERBOSE output to understand what was cleaned
VACUUM VERBOSE orders;

-- VACUUM FULL (requires AccessExclusiveLock -- schedule maintenance window)
VACUUM FULL orders;

-- Check what VACUUM would do (dry run via visibility info)
SELECT relname, n_dead_tup, n_live_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_vacuum, last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

```bash
# pg_repack (must install extension)
pg_repack -h localhost -U postgres -d mydb -t orders

# Repack entire database
pg_repack -h localhost -U postgres -d mydb

# Repack only indexes (faster, lower risk)
pg_repack -h localhost -U postgres -d mydb -t orders --only-indexes
```

### Autovacuum Tuning

Autovacuum triggers when: `n_dead_tup > autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * n_live_tup`

```bash
# postgresql.conf global settings
autovacuum = on                              # never disable
autovacuum_max_workers = 5                   # default 3; increase for many tables
autovacuum_vacuum_threshold = 50            # min dead tuples before trigger
autovacuum_vacuum_scale_factor = 0.02       # 2% of table (default 0.2 = 20%)
autovacuum_analyze_threshold = 50
autovacuum_analyze_scale_factor = 0.01      # 1% (default 0.1 = 10%)
autovacuum_vacuum_cost_delay = 2ms          # throttle I/O (default 2ms in PG13+)
autovacuum_vacuum_cost_limit = 200          # I/O budget per delay cycle
autovacuum_naptime = 30s                    # check interval for each worker
```

```sql
-- Per-table autovacuum override (large tables need lower scale factor)
-- For a 100M row table, 20% = 20M dead tuples before vacuum -- too late
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.01,   -- 1% instead of 20%
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.005,
    autovacuum_vacuum_cost_delay = 10        -- ms; slow down to reduce I/O impact
);

-- High-churn tables (logs, queues): more aggressive
ALTER TABLE job_queue SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 100
);
```

### Transaction ID Wraparound

PostgreSQL uses 32-bit transaction IDs (XIDs). After ~2 billion transactions, XID wraps.
PostgreSQL will stop accepting writes when age reaches `autovacuum_freeze_max_age` (default 200M).

```sql
-- Monitor XID age across all databases (run as superuser)
SELECT datname,
       age(datfrozenxid) AS xid_age,
       2000000000 - age(datfrozenxid) AS remaining_xids,
       round(100.0 * age(datfrozenxid) / 2000000000, 2) AS pct_used
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Monitor per-table XID age (find tables that need freezing)
SELECT relname,
       age(relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(oid)) AS size
FROM pg_class
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;

-- Emergency response when approaching wraparound:
-- 1. Check if autovacuum is running: SELECT * FROM pg_stat_activity WHERE query LIKE 'autovacuum%';
-- 2. Manual aggressive freeze:
VACUUM FREEZE orders;        -- force freeze all tuples in table
-- 3. For cluster-wide freeze:
-- vacuumdb -a -F -j 4       -- freeze all databases, 4 parallel workers

-- Relevant postgresql.conf settings
vacuum_freeze_min_age = 50000000        -- freeze tuples older than this (50M XIDs)
vacuum_freeze_table_age = 150000000     -- force full table scan at this age
autovacuum_freeze_max_age = 200000000   -- emergency autovacuum triggered here
```

### Dead Tuple Accumulation

Long-running transactions and `idle in transaction` sessions prevent VACUUM from removing dead tuples
because those old snapshots may still need to see pre-update versions.

```sql
-- Find sessions holding old snapshots (preventing dead tuple cleanup)
SELECT pid, usename, application_name, state,
       now() - xact_start AS xact_age,
       now() - query_start AS query_age,
       left(query, 80) AS current_query
FROM pg_stat_activity
WHERE state != 'idle'
  AND xact_start < now() - interval '5 minutes'
ORDER BY xact_start;

-- Find the oldest active transaction (this limits vacuum)
SELECT min(xact_start), max(now() - xact_start) AS max_age
FROM pg_stat_activity
WHERE xact_start IS NOT NULL;

-- Check if replication slots are holding back WAL (another source of bloat)
SELECT slot_name, active, pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
) AS lag
FROM pg_replication_slots;

-- Kill long-running idle-in-transaction sessions (use carefully)
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - xact_start > interval '1 hour';

-- Prevent accumulation: set statement/transaction timeouts
-- postgresql.conf or ALTER ROLE:
-- idle_in_transaction_session_timeout = '10min'
-- statement_timeout = '30s'
```

---

## Monitoring

### pg_stat_activity

```sql
-- Connection overview by state
SELECT state, count(*), max(now() - state_change) AS max_time_in_state
FROM pg_stat_activity
GROUP BY state
ORDER BY count DESC;

-- Long-running queries (over 30 seconds)
SELECT pid, usename, application_name, client_addr, state,
       now() - query_start AS duration,
       wait_event_type, wait_event,
       left(query, 120) AS query
FROM pg_stat_activity
WHERE state != 'idle'
  AND query_start < now() - interval '30 seconds'
ORDER BY query_start;

-- Wait events (what are connections waiting for)
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY wait_event_type, wait_event
ORDER BY count DESC;
-- Common wait events:
-- Lock/relation = waiting for table lock
-- Client/ClientRead = waiting for client to send data
-- IO/DataFileRead = reading from disk
-- IPC/BgWorkerShutdown = parallel query coordination
```

### pg_stat_user_tables

```sql
-- Tables with high sequential scan rates (missing indexes?)
SELECT relname,
       seq_scan,
       idx_scan,
       round(100.0 * idx_scan / nullif(seq_scan + idx_scan, 0), 2) AS idx_pct,
       n_live_tup,
       n_dead_tup,
       last_vacuum::date,
       last_autovacuum::date,
       last_analyze::date
FROM pg_stat_user_tables
WHERE seq_scan > 100
ORDER BY seq_scan DESC;

-- Tables most in need of VACUUM
SELECT relname,
       n_dead_tup,
       n_live_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_autovacuum,
       last_vacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

### Unused Index Detection

```sql
-- Indexes that are never used (candidates for removal)
SELECT schemaname, relname AS table, indexrelname AS index,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
       idx_scan AS scans
FROM pg_stat_user_indexes ui
JOIN pg_index i ON i.indexrelid = ui.indexrelid
WHERE idx_scan = 0
  AND NOT indisunique           -- keep unique constraints
  AND NOT indisprimary          -- keep primary keys
ORDER BY pg_relation_size(i.indexrelid) DESC;

-- Indexes with low usage relative to writes (more overhead than benefit)
SELECT relname AS table,
       indexrelname AS index,
       idx_scan AS reads,
       pg_stat_get_tuples_inserted(relid) + pg_stat_get_tuples_updated(relid)
           + pg_stat_get_tuples_deleted(relid) AS writes,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan < 100
ORDER BY pg_relation_size(indexrelid) DESC;

-- Note: reset stats after index creation or major data loads
-- SELECT pg_stat_reset();  -- resets ALL stats for this database
```

### pg_stat_bgwriter

```sql
-- Checkpoint health and buffer writer activity
SELECT checkpoints_timed,
       checkpoints_req,                          -- forced (bad: I/O spike risk)
       round(100.0 * checkpoints_req /
           nullif(checkpoints_timed + checkpoints_req, 0), 2) AS forced_pct,
       buffers_checkpoint,                        -- written at checkpoint
       buffers_clean,                             -- written by bgwriter
       maxwritten_clean,                          -- bgwriter hit write limit (increase bgwriter_lru_maxpages)
       buffers_backend,                           -- written by backend directly (bad)
       buffers_backend_fsync,                     -- backend had to fsync (very bad)
       buffers_alloc,                             -- new buffers allocated
       stats_reset::date
FROM pg_stat_bgwriter;

-- High checkpoints_req: reduce checkpoint_completion_target or increase max_wal_size
-- High buffers_backend: shared_buffers too small or checkpoint interval too short
-- Ideal: checkpoints_req / total < 10%, buffers_backend / total < 5%

-- postgresql.conf tuning:
-- checkpoint_completion_target = 0.9   -- spread checkpoint I/O over 90% of interval
-- max_wal_size = 4GB                   -- larger = fewer forced checkpoints
-- checkpoint_timeout = 10min           -- default
```

### Lock Contention and Deadlocks

```sql
-- Active locks and what is blocking what
SELECT blocked.pid AS blocked_pid,
       blocked.usename AS blocked_user,
       blocking.pid AS blocking_pid,
       blocking.usename AS blocking_user,
       blocked_activity.wait_event,
       blocked_activity.query AS blocked_query,
       blocking_activity.query AS blocking_query
FROM pg_locks blocked
JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked.pid
JOIN pg_locks blocking ON blocking.locktype = blocked.locktype
    AND blocking.database IS NOT DISTINCT FROM blocked.database
    AND blocking.relation IS NOT DISTINCT FROM blocked.relation
    AND blocking.page IS NOT DISTINCT FROM blocked.page
    AND blocking.tuple IS NOT DISTINCT FROM blocked.tuple
    AND blocking.classid IS NOT DISTINCT FROM blocked.classid
    AND blocking.objid IS NOT DISTINCT FROM blocked.objid
    AND blocking.objsubid IS NOT DISTINCT FROM blocked.objsubid
    AND blocking.pid != blocked.pid
    AND blocking.granted
JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking.pid
WHERE NOT blocked.granted;

-- Lock types by table (what mode of locks are held)
SELECT relname, mode, count(*)
FROM pg_locks l
JOIN pg_class c ON c.oid = l.relation
WHERE l.granted
GROUP BY relname, mode
ORDER BY relname, mode;

-- Deadlock investigation: enable logging in postgresql.conf
-- log_lock_waits = on          -- log waits over deadlock_timeout
-- deadlock_timeout = 1s        -- time before deadlock check runs
-- log_min_duration_statement = 5000  -- log queries taking over 5s
```

### Cache Hit Ratio

```sql
-- Database-level buffer cache hit ratio (target: > 99% for OLTP)
SELECT datname,
       blks_hit,
       blks_read,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS hit_ratio
FROM pg_stat_database
WHERE datname = current_database();

-- Table-level cache hit ratio
SELECT relname,
       heap_blks_hit,
       heap_blks_read,
       round(100.0 * heap_blks_hit / nullif(heap_blks_hit + heap_blks_read, 0), 2) AS hit_ratio
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC;

-- Index cache hit ratio
SELECT relname, indexrelname,
       idx_blks_hit,
       idx_blks_read,
       round(100.0 * idx_blks_hit / nullif(idx_blks_hit + idx_blks_read, 0), 2) AS hit_ratio
FROM pg_statio_user_indexes
ORDER BY idx_blks_read DESC;
```

### Table and Index Bloat Estimation

```sql
-- Table bloat estimate (uses pgstattuple extension if available, else heuristic)
-- Heuristic approach (no extension required):
SELECT
    schemaname,
    relname AS table,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || relname)) AS table_size,
    round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_tup_pct
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC;

-- Using pgstattuple for precise bloat (requires extension, scans full table)
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT * FROM pgstattuple('orders');
-- dead_tuple_percent > 20% warrants VACUUM or pg_repack

-- Index bloat via pgstatindex
SELECT * FROM pgstatindex('orders_pkey');
-- avg_leaf_density < 70% suggests bloat; REINDEX or pg_repack --only-indexes

-- Quick bloat estimate without extension (from check_postgres project):
SELECT
    tablename,
    pg_size_pretty(real_size) AS real_size,
    pg_size_pretty(bloat_size) AS bloat_size,
    round(bloat_ratio::numeric, 2) AS bloat_ratio
FROM (
    SELECT tablename,
           pg_total_relation_size(tablename::regclass) AS real_size,
           pg_total_relation_size(tablename::regclass) -
               (pg_relation_size(tablename::regclass) * (1.0 - n_dead_tup::float / nullif(n_live_tup + n_dead_tup, 0))) AS bloat_size,
           100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0) AS bloat_ratio
    FROM pg_stat_user_tables
) t
WHERE bloat_ratio > 10
ORDER BY bloat_size DESC;
```

---

## Connection Pooling

### pgBouncer Modes

**Session mode**: client holds server connection for entire session duration.
Same behavior as direct connection. Use for: apps using session-level features
(temp tables, prepared statements with protocol-level binding, SET LOCAL, advisory locks).

**Transaction mode**: server connection returned to pool after each transaction.
Much higher multiplexing. Use for: most web applications using short transactions.
Limitations: SET, LISTEN, NOTIFY, prepared statements (without `server_reset_query`), temp tables.

**Statement mode**: connection returned after each statement. Rarely used.
Limitation: no multi-statement transactions. Useful only for simple read-only workloads.

```ini
; pgbouncer.ini
[databases]
mydb = host=localhost port=5432 dbname=mydb

[pgbouncer]
listen_port = 6432
listen_addr = *
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

pool_mode = transaction          ; session|transaction|statement
max_client_conn = 1000           ; max connections from clients
default_pool_size = 25           ; server connections per database/user pair
min_pool_size = 5                ; keep this many open even when idle
reserve_pool_size = 5            ; extra connections for pool_mode=session bursts
reserve_pool_timeout = 5         ; seconds to wait before using reserve pool

server_reset_query = DISCARD ALL ; run after each session return (session mode)
server_check_query = SELECT 1    ; health check query
server_idle_timeout = 600        ; close idle server connections after 10min
client_idle_timeout = 0          ; 0 = never close idle clients (set in app instead)

; Logging
log_connections = 0              ; reduce noise in production
log_disconnections = 0
log_pooler_errors = 1
stats_period = 60                ; log stats every 60 seconds
```

```bash
# pgBouncer monitoring via admin console
psql -h localhost -p 6432 -U pgbouncer pgbouncer

SHOW POOLS;      -- pool stats: cl_active, cl_waiting, sv_active, sv_idle
SHOW CLIENTS;    -- connected clients
SHOW SERVERS;    -- server connections
SHOW STATS;      -- request rates, query times
SHOW CONFIG;     -- current configuration

PAUSE mydb;      -- pause pool (for maintenance)
RESUME mydb;     -- resume pool
RELOAD;          -- reload config without restart
```

### Application-Level Pooling (SQLAlchemy)

```python
from sqlalchemy import create_engine

engine = create_engine(
    "postgresql+psycopg2://user:pass@localhost:5432/mydb",
    pool_size=10,           # persistent connections in pool
    max_overflow=20,        # extra connections beyond pool_size (temporary)
    pool_timeout=30,        # seconds to wait for available connection
    pool_recycle=1800,      # recycle connections after 30min (avoid stale connections)
    pool_pre_ping=True,     # test connection before using from pool
)

# With pgBouncer in transaction mode, use NullPool or StaticPool
# (pgBouncer handles pooling, app should not pool on top of pooler)
from sqlalchemy.pool import NullPool
engine = create_engine(
    "postgresql+psycopg2://user:pass@pgbouncer:6432/mydb",
    poolclass=NullPool       # no application-level pooling
)
```

### Connection Sizing Guidelines

The classic formula: `connections = (core_count * 2) + effective_spindle_count`

For SSD storage (spindles = 1), a 16-core server: `(16 * 2) + 1 = 33` PostgreSQL connections.

```sql
-- Check current connection usage
SELECT count(*) AS total,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_txn,
       max_conn
FROM pg_stat_activity
CROSS JOIN (SELECT setting::int AS max_conn FROM pg_settings WHERE name = 'max_connections') s
GROUP BY max_conn;

-- Connections by application
SELECT application_name, count(*), max(now() - state_change) AS longest_idle
FROM pg_stat_activity
GROUP BY application_name
ORDER BY count DESC;
```

```ini
; postgresql.conf connection settings
max_connections = 100            ; total connections (including superuser)
superuser_reserved_connections = 3  ; reserved for superuser access

; Memory implication: each connection uses ~5-10MB of RAM
; At max_connections = 200: budget 1-2GB RAM for connection overhead alone
; Use pgBouncer to keep max_connections low (50-100) and serve thousands of clients

; Recommended approach for most web apps:
; App -> pgBouncer (transaction mode, max_client_conn=1000, pool_size=25)
;     -> PostgreSQL (max_connections=50)
```

### Monitoring Pool Health

```sql
-- Alert conditions to monitor:
-- 1. Connections near max_connections
SELECT count(*) * 100.0 / current_setting('max_connections')::int AS pct_used
FROM pg_stat_activity;

-- 2. Idle-in-transaction accumulating (connection leak or slow clients)
SELECT count(*)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - state_change > interval '5 minutes';

-- 3. Connection wait (pgBouncer cl_waiting > 0 sustained = under-provisioned pool)

-- Set timeouts to prevent connection leaks:
-- ALTER ROLE myapp SET idle_in_transaction_session_timeout = '5min';
-- ALTER ROLE myapp SET statement_timeout = '30s';
```
