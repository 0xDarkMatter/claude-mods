# PostgreSQL Replication, Partitioning & FDW Reference

## Table of Contents

1. [Streaming Replication](#streaming-replication)
   - Primary Configuration
   - Replica Configuration
   - Synchronous vs Asynchronous
   - Monitoring Replication
   - Replication Slots
2. [Logical Replication](#logical-replication)
   - Publications
   - Subscriptions
   - Row Filters and Column Lists (PG15+)
   - Use Cases and Limitations
3. [Failover](#failover)
   - Promoting a Standby
   - Timeline Switches
   - Connection Routing
4. [Table Partitioning](#table-partitioning)
   - RANGE Partitioning
   - LIST Partitioning
   - HASH Partitioning
   - Sub-partitioning
   - Partition Maintenance
   - When to Partition
5. [Foreign Data Wrappers](#foreign-data-wrappers)
   - postgres_fdw Setup
   - IMPORT FOREIGN SCHEMA
   - Performance and Pushdown

---

## Streaming Replication

### Primary Configuration

Edit `postgresql.conf` on the primary:

```ini
# Minimum required for streaming replication
wal_level = replica          # or 'logical' if you also need logical replication
max_wal_senders = 10         # number of concurrent standby connections
wal_keep_size = 1GB          # retain WAL to prevent standby falling behind
                             # prefer replication slots over this setting

# Optional but recommended
hot_standby_feedback = on    # prevents primary from vacuuming rows standby needs
```

Create a replication role on the primary:

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'secret';
```

Allow the standby in `pg_hba.conf` on the primary:

```
# TYPE  DATABASE        USER         ADDRESS          METHOD
host    replication     replicator   192.168.1.0/24   scram-sha-256
```

Reload after editing `pg_hba.conf`:

```sql
SELECT pg_reload_conf();
```

### Replica Configuration

Take a base backup from the primary (run on standby host):

```bash
pg_basebackup \
  --host=primary-host \
  --username=replicator \
  --pgdata=/var/lib/postgresql/data \
  --wal-method=stream \
  --checkpoint=fast \
  --progress
```

Create `postgresql.conf` overrides or `postgresql.auto.conf` on the replica:

```ini
primary_conninfo = 'host=primary-host port=5432 user=replicator password=secret'
primary_slot_name = 'replica1_slot'   # if using replication slots
hot_standby = on                       # allow read queries on replica
recovery_min_apply_delay = 0           # set to e.g. '30min' for delayed replica
```

Create the standby signal file (PG12+):

```bash
touch /var/lib/postgresql/data/standby.signal
```

### Synchronous vs Asynchronous Replication

**Asynchronous** (default): primary commits without waiting for standby. Risk of data loss on primary failure equal to replication lag.

**Synchronous**: primary waits for at least one standby to confirm WAL receipt before returning to client.

```ini
# On primary postgresql.conf
synchronous_standby_names = 'replica1'
# or for ANY 1 of multiple standbys:
synchronous_standby_names = 'ANY 1 (replica1, replica2, replica3)'
# or require ALL listed:
synchronous_standby_names = 'FIRST 2 (replica1, replica2, replica3)'
```

Standby names come from the `application_name` in `primary_conninfo`:

```ini
primary_conninfo = 'host=primary port=5432 user=replicator application_name=replica1'
```

Trade-offs:

| Mode | Durability | Write Latency | Throughput |
|------|-----------|---------------|------------|
| Async | Data loss possible | Low | Highest |
| Sync (remote_write) | WAL received, not flushed | Medium | High |
| Sync (on) | WAL flushed to disk | Higher | Lower |
| Sync (remote_apply) | Changes applied | Highest | Lowest |

```ini
# Control sync level (default is 'on' = flush to standby disk)
synchronous_commit = remote_write   # faster, slight durability trade-off
```

### Monitoring Replication

On the primary, query `pg_stat_replication`:

```sql
SELECT
    application_name,
    client_addr,
    state,                          -- startup, catchup, streaming
    sync_state,                     -- async, sync, potential
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    -- Replication lag in bytes
    (sent_lsn - replay_lsn) AS replay_lag_bytes,
    -- Replication lag in time (PG10+)
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

On the replica, check if it is in recovery and its LSN position:

```sql
SELECT
    pg_is_in_recovery(),
    pg_last_wal_receive_lsn(),
    pg_last_wal_replay_lsn(),
    pg_last_xact_replay_timestamp(),
    -- Time lag (approximate)
    now() - pg_last_xact_replay_timestamp() AS replication_delay;
```

Alert when lag exceeds threshold:

```sql
-- Alert if replay lag > 30 seconds
SELECT application_name, replay_lag
FROM pg_stat_replication
WHERE replay_lag > interval '30 seconds';
```

### Replication Slots

Replication slots prevent the primary from removing WAL segments needed by a standby, eliminating the need for `wal_keep_size` tuning. The risk is unbounded WAL accumulation if a slot is abandoned.

Create a physical slot on the primary:

```sql
SELECT pg_create_physical_replication_slot('replica1_slot');
```

List all slots and check for lag:

```sql
SELECT
    slot_name,
    slot_type,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    -- WAL retained by this slot in bytes
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_size
FROM pg_replication_slots;
```

Drop an abandoned slot to reclaim disk:

```sql
SELECT pg_drop_replication_slot('replica1_slot');
```

Set a safety limit to prevent disk exhaustion (PG13+):

```ini
max_slot_wal_keep_size = 10GB   # drop slot if WAL retention exceeds this
```

---

## Logical Replication

Logical replication decodes WAL into row-level change streams. It allows selective table sync and works across major versions.

### Publications

A publication defines what changes to export:

```sql
-- All tables, all operations
CREATE PUBLICATION pub_all FOR ALL TABLES;

-- Specific tables
CREATE PUBLICATION pub_orders FOR TABLE orders, order_items;

-- Specific operations only
CREATE PUBLICATION pub_inserts FOR TABLE events WITH (publish = 'insert');

-- With row filter (PG15+): only published rows matching WHERE
CREATE PUBLICATION pub_active_orders FOR TABLE orders
    WHERE (status != 'cancelled');

-- With column list (PG15+): only publish selected columns
CREATE PUBLICATION pub_orders_summary FOR TABLE orders (id, status, total, created_at);
```

Manage publications:

```sql
ALTER PUBLICATION pub_orders ADD TABLE shipments;
ALTER PUBLICATION pub_orders DROP TABLE order_items;
DROP PUBLICATION pub_orders;

-- Inspect
SELECT * FROM pg_publication;
SELECT * FROM pg_publication_tables;
```

The publisher must have `wal_level = logical`:

```ini
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
```

### Subscriptions

On the subscriber database:

```sql
CREATE SUBSCRIPTION sub_orders
    CONNECTION 'host=primary-host dbname=mydb user=replicator password=secret'
    PUBLICATION pub_orders;
```

The subscriber creates a replication slot on the publisher automatically. The target tables must already exist with compatible schemas.

```sql
-- Disable/re-enable a subscription
ALTER SUBSCRIPTION sub_orders DISABLE;
ALTER SUBSCRIPTION sub_orders ENABLE;

-- Refresh after publisher adds tables
ALTER SUBSCRIPTION sub_orders REFRESH PUBLICATION;

-- Skip copying initial data (for ongoing sync only)
CREATE SUBSCRIPTION sub_orders
    CONNECTION '...'
    PUBLICATION pub_orders
    WITH (copy_data = false);

-- Drop subscription (also drops remote slot)
DROP SUBSCRIPTION sub_orders;
```

Monitor subscriptions:

```sql
-- On subscriber
SELECT * FROM pg_stat_subscription;

-- On publisher - logical slots
SELECT slot_name, active, confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_type = 'logical';
```

### Limitations of Logical Replication

- DDL changes are not replicated. Schema changes must be applied manually to subscribers before altering the publisher.
- Sequences are not replicated. After failover, reset sequences on the new primary.
- Large objects (`pg_largeobject`) are not replicated.
- Conflict resolution is basic: by default, subscriber errors on unique constraint conflicts. Use `ALTER SUBSCRIPTION ... SKIP` to advance past a conflict LSN.
- Requires `REPLICA IDENTITY` on tables without primary keys:

```sql
-- Full row image (slow, safe for tables without PK)
ALTER TABLE events REPLICA IDENTITY FULL;

-- Use a unique index as identity
ALTER TABLE events REPLICA IDENTITY USING INDEX events_uuid_idx;
```

---

## Failover

### Promoting a Standby

Trigger promotion using `pg_promote()` (PG12+, no file touch needed):

```sql
-- Connect to the standby and run:
SELECT pg_promote();
```

Or use `pg_ctl`:

```bash
pg_ctl promote -D /var/lib/postgresql/data
```

After promotion, the former standby becomes a normal read-write primary. Update `primary_conninfo` on remaining standbys to point to the new primary and restart them.

### Timeline Switches

Every promotion increments the timeline ID. PostgreSQL uses timelines to track branching histories, allowing standbys to follow the correct WAL history.

```sql
-- Check current timeline on any server
SELECT timeline_id FROM pg_control_checkpoint();

-- View WAL segment filenames: first 8 hex chars = timeline
-- 000000020000000000000001 = timeline 2, segment 1
```

When a former primary comes back, configure it as a new standby using `recovery_target_timeline = 'latest'` (the default), which lets it follow the new timeline.

### Connection Routing

**HAProxy** (layer 4, health-check based):

```
frontend postgres_write
    bind *:5432
    default_backend postgres_primary

backend postgres_primary
    option httpchk GET /primary  # Patroni health endpoint
    server pg1 192.168.1.1:5432 check port 8008
    server pg2 192.168.1.2:5432 check port 8008

backend postgres_replica
    option httpchk GET /replica
    server pg1 192.168.1.1:5432 check port 8008
    server pg2 192.168.1.2:5432 check port 8008
```

**PgBouncer** target switch: update `[databases]` section and reload:

```ini
[databases]
mydb = host=new-primary-ip port=5432 dbname=mydb
```

```bash
psql -p 6432 pgbouncer -c "RELOAD"
```

**DNS-based**: Update the DNS record for `pg-primary.internal` to point to the new primary's IP. Works well with short TTLs (30s) and application-level retry logic.

---

## Table Partitioning

Declarative partitioning (PG10+) uses `PARTITION BY` on the parent table. The parent table itself holds no rows.

### RANGE Partitioning

Most common for time-series and log data:

```sql
CREATE TABLE orders (
    id          bigserial,
    created_at  timestamptz NOT NULL,
    customer_id bigint,
    total       numeric(12,2)
) PARTITION BY RANGE (created_at);

-- Create partitions for each month
CREATE TABLE orders_2024_01
    PARTITION OF orders
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE orders_2024_02
    PARTITION OF orders
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- Catch-all default partition
CREATE TABLE orders_default
    PARTITION OF orders DEFAULT;
```

### LIST Partitioning

Useful for discrete categorical values:

```sql
CREATE TABLE products (
    id     bigserial,
    region text NOT NULL,
    name   text
) PARTITION BY LIST (region);

CREATE TABLE products_us   PARTITION OF products FOR VALUES IN ('us', 'ca');
CREATE TABLE products_eu   PARTITION OF products FOR VALUES IN ('de', 'fr', 'uk');
CREATE TABLE products_apac PARTITION OF products FOR VALUES IN ('au', 'jp', 'sg');
CREATE TABLE products_other PARTITION OF products DEFAULT;
```

### HASH Partitioning

Distributes rows evenly when there is no natural range or list split:

```sql
CREATE TABLE sessions (
    id      uuid NOT NULL,
    user_id bigint,
    data    jsonb
) PARTITION BY HASH (id);

-- 8 partitions, modulus = total count, remainder = partition number
CREATE TABLE sessions_0 PARTITION OF sessions FOR VALUES WITH (modulus 8, remainder 0);
CREATE TABLE sessions_1 PARTITION OF sessions FOR VALUES WITH (modulus 8, remainder 1);
-- ... through remainder 7
```

### Sub-partitioning

Combine strategies: partition by month, then by region within each month:

```sql
CREATE TABLE events (
    id         bigserial,
    created_at timestamptz NOT NULL,
    region     text NOT NULL
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2024_01
    PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')
    PARTITION BY LIST (region);

CREATE TABLE events_2024_01_us
    PARTITION OF events_2024_01
    FOR VALUES IN ('us');
```

### Partition Pruning

The planner eliminates irrelevant partitions at plan time (static) or execution time (dynamic):

```sql
-- Enable/disable for debugging
SET enable_partition_pruning = on;  -- default on

EXPLAIN SELECT * FROM orders WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01';
-- Should show only orders_2024_06 in the plan, not all partitions
```

Each partition should have its own indexes. Indexes on the parent do not cascade automatically (they do in PG11+ for primary keys and unique constraints created on the parent):

```sql
-- Create index on all existing partitions at once (PG11+ creates on parent + all children)
CREATE INDEX ON orders (customer_id);
```

### Partition Maintenance

```sql
-- Add a new partition (no locking on existing data)
CREATE TABLE orders_2025_01
    PARTITION OF orders
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

-- Detach a partition (it becomes a standalone table, no data movement)
ALTER TABLE orders DETACH PARTITION orders_2023_01;
-- PG14+: detach concurrently (non-blocking)
ALTER TABLE orders DETACH PARTITION orders_2023_01 CONCURRENTLY;

-- Drop old data instantly (no vacuum needed)
DROP TABLE orders_2023_01;

-- Attach an existing table as a partition (verify constraint first)
ALTER TABLE orders_old ADD CONSTRAINT orders_old_check
    CHECK (created_at >= '2022-01-01' AND created_at < '2023-01-01');
ALTER TABLE orders ATTACH PARTITION orders_old
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
```

### When to Partition

Partition when:
- Table exceeds ~100M rows or 100GB and queries frequently filter on the partition key
- You need instant bulk deletes (drop a partition vs DELETE + VACUUM)
- You want to spread data across tablespaces on different disks
- Autovacuum cannot keep up with a single large table

Do not partition just because a table is large. Partitioning adds overhead for queries that scan all partitions (no partition key filter). A well-indexed single table often outperforms a partitioned one for OLTP workloads.

---

## Foreign Data Wrappers

FDWs allow PostgreSQL to query external data sources as if they were local tables.

### postgres_fdw Setup

```sql
-- 1. Install extension
CREATE EXTENSION postgres_fdw;

-- 2. Define the remote server
CREATE SERVER remote_analytics
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (
        host 'analytics-db.internal',
        port '5432',
        dbname 'analytics'
    );

-- 3. Map local user to remote credentials
CREATE USER MAPPING FOR current_user
    SERVER remote_analytics
    OPTIONS (user 'readonly_user', password 'secret');

-- 4. Create individual foreign tables
CREATE FOREIGN TABLE remote_events (
    id         bigint,
    event_type text,
    created_at timestamptz,
    payload    jsonb
)
SERVER remote_analytics
OPTIONS (schema_name 'public', table_name 'events');
```

### IMPORT FOREIGN SCHEMA

Import all (or selected) tables from a remote schema at once:

```sql
-- Import entire remote schema
IMPORT FOREIGN SCHEMA public
    FROM SERVER remote_analytics
    INTO local_remote_schema;

-- Import only specific tables
IMPORT FOREIGN SCHEMA public
    LIMIT TO (events, pageviews, sessions)
    FROM SERVER remote_analytics
    INTO local_remote_schema;

-- Exclude specific tables
IMPORT FOREIGN SCHEMA public
    EXCEPT (internal_audit_log)
    FROM SERVER remote_analytics
    INTO local_remote_schema;
```

### Performance and Pushdown

postgres_fdw pushes WHERE clauses, ORDER BY, LIMIT, and aggregates to the remote server when possible, reducing data transfer.

```sql
-- Check what gets pushed down with EXPLAIN VERBOSE
EXPLAIN (VERBOSE, ANALYZE)
SELECT event_type, count(*)
FROM remote_events
WHERE created_at > now() - interval '7 days'
GROUP BY event_type;
-- Look for "Remote SQL:" in the output
```

Join pushdown (PG14+): joins between two foreign tables on the same server are pushed down to a single remote query:

```sql
-- Both tables on same server -> single remote query
SELECT e.event_type, s.user_id
FROM remote_events e
JOIN remote_sessions s ON e.session_id = s.id
WHERE e.created_at > now() - interval '1 day';
```

Control pushdown behavior per server:

```sql
ALTER SERVER remote_analytics OPTIONS (
    use_remote_estimate 'true',   -- fetch remote row estimates for better plans
    fetch_size '10000'             -- rows fetched per round-trip (default 100)
);
```

Inspect all configured FDW objects:

```sql
SELECT srvname, srvfdw, srvoptions FROM pg_foreign_server;
SELECT * FROM pg_user_mappings;
SELECT foreign_table_schema, foreign_table_name, foreign_server_name
FROM information_schema.foreign_tables;
```
