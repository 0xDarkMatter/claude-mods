# PostgreSQL Configuration & Tuning Reference

## Table of Contents

1. [Memory Settings](#memory-settings)
   - shared_buffers
   - work_mem
   - maintenance_work_mem
   - effective_cache_size
   - huge_pages
2. [WAL & Checkpoint Settings](#wal--checkpoint-settings)
   - wal_level
   - wal_buffers
   - checkpoint_completion_target
   - max_wal_size and min_wal_size
   - full_page_writes
3. [Query Planner Settings](#query-planner-settings)
   - random_page_cost and seq_page_cost
   - effective_io_concurrency
   - JIT compilation
4. [Parallelism Settings](#parallelism-settings)
5. [Connection Settings](#connection-settings)
6. [Logging](#logging)
7. [OLTP vs OLAP Profiles](#oltp-vs-olap-profiles)
8. [Extensions](#extensions)
   - pg_stat_statements
   - pg_trgm
   - PostGIS
   - timescaledb
   - pgcrypto
   - auto_explain

---

## Memory Settings

### shared_buffers

The PostgreSQL buffer cache: how much memory the server reserves for caching data pages.

```ini
shared_buffers = 8GB   # Recommended: 25% of total RAM
```

Rules of thumb:
- Start at 25% of RAM. Going above 40% rarely helps and can hurt because the OS page cache also buffers the same pages.
- On dedicated database servers, 25% is conservative but safe. Profile with `pg_buffercache` to measure actual cache hit rates.
- Requires a server restart to take effect.

Check cache hit ratio:

```sql
SELECT
    sum(heap_blks_hit)  AS heap_hit,
    sum(heap_blks_read) AS heap_read,
    round(
        sum(heap_blks_hit)::numeric /
        nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 2
    ) AS hit_ratio_pct
FROM pg_statio_user_tables;
-- Target: > 99% for OLTP, > 95% for OLAP
```

Identify which tables consume the most buffer space (requires `pg_buffercache`):

```sql
CREATE EXTENSION pg_buffercache;

SELECT
    relname,
    count(*) * 8192 / 1024 / 1024 AS cached_mb,
    round(count(*) * 100.0 / (SELECT count(*) FROM pg_buffercache), 2) AS pct_of_cache
FROM pg_buffercache bc
JOIN pg_class c ON bc.relfilenode = c.relfilenode
WHERE c.relkind = 'r'
GROUP BY relname
ORDER BY cached_mb DESC
LIMIT 20;
```

### work_mem

Memory granted per sort, hash, or merge operation. Each query node (sort, hash join, hash aggregate) can use up to `work_mem` individually.

```ini
work_mem = 64MB   # Default 4MB is usually too low
```

Critical nuance: if a query has 5 sort nodes and 20 parallel workers, it can consume `5 * 20 * work_mem` = 100x `work_mem`. For a 32GB server running 100 connections, setting `work_mem = 320MB` is catastrophic.

Sizing strategy:
1. Estimate concurrent queries: `max_connections * avg_active_fraction`
2. Reserve memory for OS + shared_buffers + maintenance_work_mem
3. Divide remainder: `work_mem = remaining / (active_connections * avg_nodes_per_query)`

For most OLTP systems: 16-64MB. For analytics: 256MB-1GB with fewer connections.

Override per session for specific heavy queries:

```sql
SET work_mem = '512MB';
SELECT ... FROM large_table ORDER BY ...;
RESET work_mem;
```

Monitor actual temporary file creation to detect under-allocation:

```ini
log_temp_files = 0   # Log all temp files (0 = log everything, N = only above N bytes)
```

```sql
-- Check existing temp file usage stats
SELECT query, temp_blks_written
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;
```

### maintenance_work_mem

Memory for maintenance operations: VACUUM, ANALYZE, CREATE INDEX, ALTER TABLE ADD FOREIGN KEY, CLUSTER.

```ini
maintenance_work_mem = 2GB   # Recommended: up to 10% RAM or 1-4GB
```

Larger values dramatically speed up `CREATE INDEX` and VACUUM on large tables. Unlike `work_mem`, there are never many concurrent maintenance operations, so you can set this aggressively.

Override per session before a large index build:

```sql
SET maintenance_work_mem = '4GB';
CREATE INDEX CONCURRENTLY idx_events_created_at ON events (created_at);
RESET maintenance_work_mem;
```

### effective_cache_size

A hint to the query planner about total memory available for caching (RAM + OS page cache). It does not allocate memory; it only influences cost estimates.

```ini
effective_cache_size = 24GB   # Recommended: 75% of total RAM
```

Higher values make the planner prefer index scans (which benefit from caching) over sequential scans. Too low a value causes the planner to choose sequential scans even when an index scan would be faster.

### huge_pages

Huge pages (2MB pages on Linux instead of 4KB) reduce TLB pressure and can improve throughput on large `shared_buffers` values (above 8GB).

```ini
huge_pages = try    # 'try' falls back gracefully; use 'on' to enforce
```

Linux OS setup (must be done before starting PostgreSQL):

```bash
# Calculate pages needed: shared_buffers / 2MB
# For shared_buffers = 16GB: 16384 MB / 2 MB = 8192 huge pages, add 10% buffer
echo 9000 > /proc/sys/vm/nr_hugepages

# Persist across reboots
echo "vm.nr_hugepages = 9000" >> /etc/sysctl.conf
sysctl -p

# Verify allocation
grep HugePages /proc/meminfo
```

---

## WAL & Checkpoint Settings

### wal_level

Controls how much information is written to WAL.

```ini
wal_level = replica    # Minimum for streaming replication
wal_level = logical    # Required for logical replication (writes more)
```

`wal_level = minimal` disables replication and reduces WAL volume slightly. Use only for standalone servers where you never need PITR.

### wal_buffers

Memory for WAL writes before flushing to disk. PostgreSQL auto-tunes this to 1/32 of `shared_buffers`, capped at 16MB.

```ini
wal_buffers = 64MB   # Manual override; auto value is usually fine
```

Rarely needs manual tuning. Increase only if you see contention on `WALBufMappingLock` in `pg_stat_activity`.

### checkpoint_completion_target

Fraction of the checkpoint interval over which to spread checkpoint I/O. Reduces I/O spikes at checkpoint time.

```ini
checkpoint_completion_target = 0.9   # Recommended (default is 0.9 in PG14+)
```

With `max_wal_size = 4GB` and `checkpoint_completion_target = 0.9`, PostgreSQL spreads writes over 90% of the checkpoint interval instead of flushing all at once.

### max_wal_size and min_wal_size

Control WAL retention between checkpoints. Larger values reduce checkpoint frequency (less I/O) at the cost of more WAL on disk and longer crash recovery time.

```ini
min_wal_size = 1GB     # Minimum WAL to retain (default 80MB)
max_wal_size = 8GB     # Triggers checkpoint when exceeded (default 1GB)
```

For write-heavy workloads, increase `max_wal_size` to reduce checkpoint frequency. Monitor checkpoint frequency:

```sql
SELECT checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time
FROM pg_stat_bgwriter;
-- checkpoints_req >> checkpoints_timed means max_wal_size is too small
```

### full_page_writes

After a checkpoint, PostgreSQL writes the full page image of a modified page the first time it is touched. This protects against torn page writes when the OS crashes mid-write.

```ini
full_page_writes = on   # NEVER disable this
```

Disabling `full_page_writes` can cause unrecoverable data corruption after an OS crash. The only safe way to reduce full-page write overhead is to use a filesystem or storage that guarantees atomic page writes (ZFS, some SAN configurations) and you fully understand the implications.

---

## Query Planner Settings

### random_page_cost and seq_page_cost

Control the planner's cost model for I/O. Lower values make the planner favor the corresponding access method.

```ini
# For NVMe/SSD storage:
random_page_cost = 1.1
seq_page_cost = 1.0

# For traditional HDD:
random_page_cost = 4.0
seq_page_cost = 1.0
```

The default `random_page_cost = 4.0` is calibrated for spinning disk. On SSD, it causes the planner to undervalue index scans, leading to unnecessary sequential scans. Always set `random_page_cost = 1.1` on SSD-based servers.

Override per session to diagnose planner choices:

```sql
SET random_page_cost = 1.1;
EXPLAIN ANALYZE SELECT ...;
```

### effective_io_concurrency

Number of concurrent I/O operations the planner assumes the storage can handle. Affects bitmap index scan prefetching.

```ini
effective_io_concurrency = 200   # NVMe SSD (high parallelism)
effective_io_concurrency = 2     # Traditional HDD (low parallelism)
effective_io_concurrency = 1     # NFS/SAN (conservative)
```

### JIT Compilation

JIT (Just-In-Time compilation via LLVM) can speed up CPU-intensive queries (complex aggregations, many expressions) but adds compilation overhead that hurts short OLTP queries.

```ini
jit = on                  # Enable JIT globally (default on in PG11+)
jit_above_cost = 100000   # Only JIT-compile queries above this cost
jit_optimize_above_cost = 500000  # Apply expensive optimizations above this cost
jit_inline_above_cost = 500000    # Inline functions above this cost
```

For OLTP workloads where queries are fast and simple:

```ini
jit = off   # Disable entirely to avoid overhead
```

Check if JIT was used in a query:

```sql
EXPLAIN (ANALYZE, VERBOSE, FORMAT TEXT)
SELECT sum(total) FROM orders WHERE created_at > now() - interval '1 year';
-- Look for "JIT:" section in output
```

---

## Parallelism Settings

PostgreSQL can parallelize sequential scans, aggregations, joins, and index scans.

```ini
# Total background workers available to the instance
max_worker_processes = 16           # Default 8; should be >= CPU cores

# Maximum parallel workers available for queries at any time
max_parallel_workers = 8            # Default 8; cap at physical CPU cores

# Workers per individual query node
max_parallel_workers_per_gather = 4 # Default 2; practical limit 4-8

# Minimum table size before considering parallel scan
min_parallel_table_scan_size = 8MB  # Default; lower to enable on smaller tables
min_parallel_index_scan_size = 512kB

# Include leader process in parallel work (default on)
parallel_leader_participation = on
```

Force parallelism for testing (dangerous in production):

```sql
SET max_parallel_workers_per_gather = 8;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
EXPLAIN ANALYZE SELECT count(*) FROM large_table;
```

Disable parallelism for a session (useful when debugging):

```sql
SET max_parallel_workers_per_gather = 0;
```

---

## Connection Settings

### max_connections

PostgreSQL creates one process per connection. High connection counts waste memory and cause lock contention.

```ini
max_connections = 200   # Keep below 300; use pgBouncer for more
```

Each idle connection consumes ~5MB RAM just for the process overhead. With `work_mem = 64MB` and a sort-heavy query, one connection can briefly use 64MB * N sort nodes.

Use PgBouncer in transaction mode for OLTP:

```ini
# pgbouncer.ini
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 20   # Connections to PostgreSQL per database/user pair
```

```ini
# Reserve connections for superusers (DBA access during emergencies)
superuser_reserved_connections = 5
```

### TCP Keepalives

Detect dead connections (e.g., after network partition) without relying on the application:

```ini
tcp_keepalives_idle = 60      # Start keepalives after 60s idle
tcp_keepalives_interval = 10  # Retry every 10s
tcp_keepalives_count = 6      # Drop connection after 6 failed probes (1 minute)
```

Monitor current connections and their state:

```sql
SELECT
    state,
    count(*),
    max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY state
ORDER BY count DESC;

-- Find idle connections older than 10 minutes
SELECT pid, usename, application_name, state, state_change, query
FROM pg_stat_activity
WHERE state = 'idle'
  AND state_change < now() - interval '10 minutes';
```

---

## Logging

### Slow Query Logging

```ini
log_min_duration_statement = 1000   # Log queries taking > 1 second (ms)
                                     # Set to 0 to log all; -1 to disable
```

### Statement-Level Logging

```ini
log_statement = 'ddl'   # Recommended for most production servers
# Options: none | ddl | mod | all
# 'ddl'  = CREATE, DROP, ALTER, TRUNCATE
# 'mod'  = ddl + INSERT, UPDATE, DELETE, COPY
# 'all'  = everything (very verbose, for debugging only)
```

### Lock Logging

```ini
log_lock_waits = on       # Log if a query waits for a lock
deadlock_timeout = 1s     # Time before checking for deadlock (and logging wait)
```

Deadlocks are logged automatically at `log_error_verbosity` level. Lock waits (not deadlocks) require `log_lock_waits = on`:

```ini
# Also useful for identifying lock contention:
log_min_duration_statement = 500    # Catch queries slow due to lock waits
```

Query current lock waits:

```sql
SELECT
    blocked.pid                   AS blocked_pid,
    blocked.query                 AS blocked_query,
    blocking.pid                  AS blocking_pid,
    blocking.query                AS blocking_query,
    now() - blocked.query_start   AS wait_duration
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

### auto_explain

Automatically log EXPLAIN ANALYZE for slow queries without modifying application code:

```ini
# Load as a shared library (requires restart)
shared_preload_libraries = 'pg_stat_statements, auto_explain'

# auto_explain settings (in postgresql.conf or per session)
auto_explain.log_min_duration = 5000    # Log plans for queries > 5 seconds
auto_explain.log_analyze = on           # Include ANALYZE (actual vs estimated rows)
auto_explain.log_buffers = on           # Include buffer usage
auto_explain.log_format = text          # text | json | yaml | xml
auto_explain.log_verbose = off          # Include column-level output (very noisy)
auto_explain.log_nested_statements = off # Exclude PL/pgSQL internal queries
auto_explain.sample_rate = 1.0          # Sample 100% of queries; set lower under load
```

Enable per session without restart:

```sql
LOAD 'auto_explain';
SET auto_explain.log_min_duration = '1s';
SET auto_explain.log_analyze = true;
```

---

## OLTP vs OLAP Profiles

Two complete configuration profiles showing key differences.

### OLTP Profile (32GB RAM, NVMe SSD, 200 connections)

```ini
# Memory
shared_buffers = 8GB
work_mem = 32MB
maintenance_work_mem = 1GB
effective_cache_size = 24GB
huge_pages = try

# WAL & Checkpoints
wal_level = replica
wal_buffers = 64MB
checkpoint_completion_target = 0.9
max_wal_size = 4GB
min_wal_size = 1GB
full_page_writes = on

# Planner
random_page_cost = 1.1
seq_page_cost = 1.0
effective_io_concurrency = 200
jit = off                        # Short queries don't benefit; avoid overhead

# Parallelism - conservative for OLTP
max_worker_processes = 16
max_parallel_workers = 4
max_parallel_workers_per_gather = 2

# Connections
max_connections = 200
superuser_reserved_connections = 5
tcp_keepalives_idle = 60
tcp_keepalives_interval = 10
tcp_keepalives_count = 6

# Logging
log_min_duration_statement = 500
log_statement = 'ddl'
log_lock_waits = on
deadlock_timeout = 1s

# Extensions
shared_preload_libraries = 'pg_stat_statements, auto_explain'
pg_stat_statements.track = all
auto_explain.log_min_duration = 2000
auto_explain.log_analyze = on
auto_explain.log_buffers = on
```

### OLAP Profile (128GB RAM, NVMe SSD, 20 connections, analytics workload)

```ini
# Memory - larger allocations per query
shared_buffers = 32GB
work_mem = 2GB                   # Large sorts and hash joins for analytics
maintenance_work_mem = 4GB
effective_cache_size = 96GB
huge_pages = on

# WAL & Checkpoints - less frequent, larger checkpoints
wal_level = replica
wal_buffers = 64MB
checkpoint_completion_target = 0.9
max_wal_size = 16GB              # Fewer checkpoints for write-heavy ETL
min_wal_size = 4GB
full_page_writes = on

# Planner - favor parallel plans and large scans
random_page_cost = 1.1
seq_page_cost = 1.0
effective_io_concurrency = 200
jit = on                         # CPU-heavy aggregations benefit from JIT
jit_above_cost = 50000           # Lower threshold to engage JIT sooner

# Parallelism - aggressive for analytics
max_worker_processes = 32
max_parallel_workers = 24
max_parallel_workers_per_gather = 12
min_parallel_table_scan_size = 1MB
min_parallel_index_scan_size = 128kB
parallel_leader_participation = on

# Connections - low count, use pooling at application layer
max_connections = 50
superuser_reserved_connections = 5
tcp_keepalives_idle = 60
tcp_keepalives_interval = 10
tcp_keepalives_count = 6

# Logging
log_min_duration_statement = 5000   # Only log very slow queries
log_statement = 'ddl'
log_lock_waits = on
deadlock_timeout = 5s

# Extensions
shared_preload_libraries = 'pg_stat_statements, auto_explain'
pg_stat_statements.track = all
auto_explain.log_min_duration = 10000
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_verbose = on        # Column-level detail useful for analytics
```

---

## Extensions

### pg_stat_statements

Tracks cumulative execution statistics for all SQL statements. Essential for identifying slow queries.

```ini
# postgresql.conf
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all          # top | all (includes nested statements)
pg_stat_statements.max = 10000          # Max distinct statements tracked
pg_stat_statements.track_utility = on   # Track VACUUM, CREATE, etc.
```

```sql
CREATE EXTENSION pg_stat_statements;

-- Top 10 queries by total execution time
SELECT
    round(total_exec_time::numeric, 2) AS total_ms,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    round(100.0 * total_exec_time / sum(total_exec_time) OVER (), 2) AS pct,
    left(query, 120) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;

-- Queries with high I/O (temp file usage)
SELECT query, calls, total_exec_time, temp_blks_written
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;

-- Reset statistics
SELECT pg_stat_statements_reset();
```

### pg_trgm

Trigram similarity enables fast fuzzy text search and LIKE/ILIKE acceleration with GIN or GiST indexes.

```sql
CREATE EXTENSION pg_trgm;

-- Similarity search (0 to 1 score)
SELECT name, similarity(name, 'PostgreSQL') AS sim
FROM products
WHERE similarity(name, 'PostgreSQL') > 0.3
ORDER BY sim DESC;

-- Accelerate LIKE/ILIKE with GIN index
CREATE INDEX idx_products_name_trgm ON products USING gin (name gin_trgm_ops);

-- Now this query uses the index:
EXPLAIN ANALYZE SELECT * FROM products WHERE name ILIKE '%ostgre%';

-- Word similarity (better for phrase matching)
SELECT word_similarity('PostgreSQL', 'Postgres SQL tutorial');
```

### PostGIS

Spatial and geographic data types, indexing, and functions. Use GiST indexes for geometry columns.

```sql
CREATE EXTENSION postgis;

-- Spatial columns
CREATE TABLE locations (
    id      bigserial PRIMARY KEY,
    name    text,
    geom    geometry(Point, 4326)   -- WGS84 lat/lng
);

CREATE INDEX idx_locations_geom ON locations USING gist (geom);

-- Find points within 10km of a given point
SELECT name, ST_Distance(geom::geography, ST_MakePoint(-73.9857, 40.7484)::geography) AS dist_m
FROM locations
WHERE ST_DWithin(geom::geography, ST_MakePoint(-73.9857, 40.7484)::geography, 10000)
ORDER BY dist_m;
```

### timescaledb

Automatically partitions time-series data into chunks, enables continuous aggregates, and provides compression.

```sql
CREATE EXTENSION timescaledb;

-- Convert a regular table to a hypertable (partitioned by time)
CREATE TABLE metrics (
    time        timestamptz NOT NULL,
    device_id   int,
    temperature double precision
);
SELECT create_hypertable('metrics', 'time', chunk_time_interval => interval '1 day');

-- Automatic compression for old chunks
ALTER TABLE metrics SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'time DESC',
    timescaledb.compress_segmentby = 'device_id'
);
SELECT add_compression_policy('metrics', interval '7 days');

-- Continuous aggregate (materialized, auto-refreshed)
CREATE MATERIALIZED VIEW metrics_hourly
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket, device_id, avg(temperature) AS avg_temp
FROM metrics
GROUP BY bucket, device_id;
```

### pgcrypto

Cryptographic functions for hashing, encryption, and key generation.

```sql
CREATE EXTENSION pgcrypto;

-- Password hashing (bcrypt)
INSERT INTO users (email, password_hash)
VALUES ('user@example.com', crypt('user_password', gen_salt('bf', 12)));

-- Verify password
SELECT id FROM users
WHERE email = 'user@example.com'
  AND password_hash = crypt('supplied_password', password_hash);

-- Symmetric encryption (AES via pgp_sym_encrypt)
SELECT pgp_sym_encrypt('sensitive data', 'encryption_key');
SELECT pgp_sym_decrypt(encrypted_col, 'encryption_key') FROM secrets;

-- Generate random UUID
SELECT gen_random_uuid();

-- Generate cryptographically secure random bytes
SELECT encode(gen_random_bytes(32), 'hex');
```

### auto_explain

Logs query execution plans automatically for slow queries. Configured as a shared library (see [Logging](#logging) section). No SQL setup required beyond loading the library.

Load temporarily in a session for debugging without a server restart:

```sql
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;    -- Log everything in this session
SET auto_explain.log_analyze = true;
SET auto_explain.log_buffers = true;

-- Run your query; check PostgreSQL logs for the plan
SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 100;
```

Sample only a fraction of queries under high load to reduce log volume:

```ini
auto_explain.sample_rate = 0.01   # Log plans for ~1% of qualifying queries
```
