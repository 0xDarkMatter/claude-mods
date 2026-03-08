# PostgreSQL Schema Design Reference

## Table of Contents

1. [Normalization Quick Guide](#normalization-quick-guide)
2. [Data Types Deep Dive](#data-types-deep-dive)
   - [JSONB](#jsonb)
   - [Arrays](#arrays)
   - [Range Types](#range-types)
   - [Composite Types](#composite-types)
   - [Domain Types](#domain-types)
3. [Constraints](#constraints)
4. [Generated Columns](#generated-columns)
5. [Table Inheritance and Partitioning](#table-inheritance-and-partitioning)
6. [Row-Level Security](#row-level-security)

---

## Normalization Quick Guide

### 1NF - First Normal Form
Each column holds atomic values; no repeating groups; each row uniquely identified.

```sql
-- Violates 1NF: phone_numbers is a comma-separated list
CREATE TABLE contacts_bad (
    id      integer PRIMARY KEY,
    name    text,
    phones  text   -- "555-1234, 555-5678"
);

-- 1NF compliant: one phone per row
CREATE TABLE contacts (
    id   integer PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE contact_phones (
    contact_id integer REFERENCES contacts(id),
    phone      text NOT NULL,
    PRIMARY KEY (contact_id, phone)
);
```

### 2NF - Second Normal Form
Must be 1NF. Every non-key column depends on the *entire* primary key (eliminates partial dependencies in composite-key tables).

```sql
-- Violates 2NF: product_name depends only on product_id, not the full key
CREATE TABLE order_items_bad (
    order_id     integer,
    product_id   integer,
    product_name text,    -- partial dependency
    quantity     integer,
    PRIMARY KEY (order_id, product_id)
);

-- 2NF compliant: move product_name to products table
CREATE TABLE products (
    id   integer PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE order_items (
    order_id   integer,
    product_id integer REFERENCES products(id),
    quantity   integer NOT NULL,
    PRIMARY KEY (order_id, product_id)
);
```

### 3NF - Third Normal Form
Must be 2NF. No transitive dependencies (non-key columns depending on other non-key columns).

```sql
-- Violates 3NF: zip_code -> city, zip_code -> state (transitive)
CREATE TABLE employees_bad (
    id        integer PRIMARY KEY,
    name      text,
    zip_code  text,
    city      text,   -- depends on zip_code, not id
    state     text    -- depends on zip_code, not id
);

-- 3NF compliant
CREATE TABLE zip_codes (
    zip   text PRIMARY KEY,
    city  text NOT NULL,
    state text NOT NULL
);

CREATE TABLE employees (
    id       integer PRIMARY KEY,
    name     text NOT NULL,
    zip_code text REFERENCES zip_codes(zip)
);
```

### When to Denormalize

Denormalization trades write complexity for read performance. Justify it with EXPLAIN ANALYZE evidence, not intuition.

| Scenario | Denormalization Approach |
|----------|--------------------------|
| Frequent aggregate reads | Materialized view or stored summary column |
| Immutable reference data | Embed directly (e.g., country name at order time) |
| Hot join path with no writes | Redundant column with trigger to keep in sync |
| Reporting / OLAP workload | Star schema, wide fact tables |

```sql
-- Example: store calculated total on order to avoid summing line items every read
ALTER TABLE orders ADD COLUMN total_cents integer NOT NULL DEFAULT 0;

-- Keep in sync via trigger
CREATE FUNCTION recalc_order_total() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE orders
    SET total_cents = (
        SELECT COALESCE(SUM(unit_price_cents * quantity), 0)
        FROM order_items
        WHERE order_id = COALESCE(NEW.order_id, OLD.order_id)
    )
    WHERE id = COALESCE(NEW.order_id, OLD.order_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_order_items_total
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION recalc_order_total();
```

---

## Data Types Deep Dive

### JSONB

JSONB stores JSON as a binary decomposed format. Supports indexing; operators work directly on the stored value. Use `jsonb` over `json` unless you need to preserve key order or duplicate keys.

#### Operators

```sql
-- @>  containment: does left contain right?
SELECT * FROM products WHERE attributes @> '{"color": "red"}';

-- ->  extract field as jsonb
SELECT data -> 'address' FROM users;

-- ->> extract field as text
SELECT data ->> 'email' FROM users;

-- #>  extract at path as jsonb
SELECT data #> '{address, city}' FROM users;

-- #>> extract at path as text
SELECT data #>> '{address, city}' FROM users;

-- jsonb_path_query (SQL/JSON path, PG12+)
SELECT jsonb_path_query(data, '$.orders[*].amount ? (@ > 100)') FROM users;

-- jsonb_path_exists
SELECT * FROM users WHERE jsonb_path_exists(data, '$.tags[*] ? (@ == "premium")');

-- Modifying JSONB
UPDATE users SET data = data || '{"verified": true}';         -- merge/overwrite key
UPDATE users SET data = data - 'temp_field';                   -- remove key
UPDATE users SET data = jsonb_set(data, '{address,zip}', '"90210"');
```

#### Indexing JSONB

```sql
-- GIN default: supports @>, ?, ?|, ?& on all keys and values
CREATE INDEX idx_products_attrs ON products USING gin(attributes);

-- GIN jsonb_path_ops: supports only @> but uses less space and is faster for containment
CREATE INDEX idx_products_attrs_path ON products USING gin(attributes jsonb_path_ops);

-- B-tree on extracted scalar: for equality/range on a known field
CREATE INDEX idx_users_email ON users ((data ->> 'email'));

-- B-tree on cast extracted value
CREATE INDEX idx_orders_amount ON orders ((data ->> 'amount')::numeric);
```

#### When to Use JSONB vs Relational Columns

| Use JSONB When | Use Relational Columns When |
|----------------|----------------------------|
| Schema varies per row (EAV alternative) | Column is queried in WHERE, JOIN, or ORDER BY frequently |
| Optional metadata with sparse keys | Column participates in foreign key |
| Storing external API payloads as-is | Strong type enforcement required |
| Prototyping before schema stabilizes | Aggregate functions (SUM, AVG) on the field |

---

### Arrays

PostgreSQL native arrays allow storing multiple values of the same type in a single column.

```sql
CREATE TABLE articles (
    id   integer PRIMARY KEY,
    tags text[]
);

INSERT INTO articles (id, tags) VALUES (1, ARRAY['postgres', 'sql', 'performance']);
INSERT INTO articles (id, tags) VALUES (2, '{"nosql","databases"}');  -- literal syntax
```

#### Operators

```sql
-- ANY: value matches any element
SELECT * FROM articles WHERE 'postgres' = ANY(tags);

-- ALL: condition holds for every element
SELECT * FROM articles WHERE 5 > ALL(ARRAY[1,2,3,4]);

-- @>  contains (left contains right)
SELECT * FROM articles WHERE tags @> ARRAY['sql', 'postgres'];

-- <@  is contained by
SELECT * FROM articles WHERE ARRAY['sql'] <@ tags;

-- &&  overlap (share at least one element)
SELECT * FROM articles WHERE tags && ARRAY['postgres', 'mysql'];

-- Appending / removing
UPDATE articles SET tags = tags || ARRAY['new-tag'] WHERE id = 1;
UPDATE articles SET tags = array_remove(tags, 'old-tag') WHERE id = 1;

-- Array length and access
SELECT array_length(tags, 1), tags[1] FROM articles;  -- 1-indexed
```

#### Indexing Arrays

```sql
-- GIN index for @>, <@, &&, ANY equality
CREATE INDEX idx_articles_tags ON articles USING gin(tags);
```

#### Arrays vs Junction Tables

| Use Arrays When | Use Junction Tables When |
|-----------------|--------------------------|
| List is small and bounded | Elements have their own attributes |
| No referential integrity needed | Many-to-many with query filters on the joined entity |
| Queries use containment/overlap operators | Need to query "all articles for a tag" efficiently |
| Ordering within the list matters | Cardinality is high or unbounded |

---

### Range Types

Range types represent a range of values of a base type. Built-in range types: `int4range`, `int8range`, `numrange`, `tsrange`, `tstzrange`, `daterange`.

```sql
CREATE TABLE room_bookings (
    id          serial PRIMARY KEY,
    room_id     integer NOT NULL,
    booked_at   tsrange NOT NULL
);

INSERT INTO room_bookings (room_id, booked_at) VALUES
    (1, '[2024-03-01 09:00, 2024-03-01 11:00)'),  -- inclusive start, exclusive end
    (1, '[2024-03-01 14:00, 2024-03-01 16:00)');
```

#### Operators

```sql
-- && overlap
SELECT * FROM room_bookings WHERE booked_at && '[2024-03-01 10:00, 2024-03-01 12:00)';

-- @> contains a point
SELECT * FROM room_bookings WHERE booked_at @> '2024-03-01 10:30'::timestamptz;

-- <@ is contained by
SELECT * FROM room_bookings WHERE booked_at <@ '[2024-03-01 00:00, 2024-03-02 00:00)';

-- Boundary extraction
SELECT lower(booked_at), upper(booked_at) FROM room_bookings;

-- Adjacency
SELECT * FROM schedules WHERE period1 -|- period2;  -- ranges are adjacent

-- daterange example
SELECT * FROM subscriptions
WHERE validity @> CURRENT_DATE::date;
```

#### Exclusion Constraints (prevent overlaps)

```sql
-- Requires btree_gist extension for non-geometric types
CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE room_bookings
ADD CONSTRAINT no_double_booking
EXCLUDE USING gist (room_id WITH =, booked_at WITH &&);

-- Multi-column exclusion with additional equality condition
ALTER TABLE room_bookings
ADD CONSTRAINT no_double_booking_per_tenant
EXCLUDE USING gist (tenant_id WITH =, room_id WITH =, booked_at WITH &&);
```

#### Custom Range Types

```sql
CREATE TYPE floatrange AS RANGE (subtype = float8, subtype_diff = float8mi);

SELECT '[1.5, 2.5]'::floatrange @> 2.0;  -- true
```

---

### Composite Types

Composite types group multiple fields into a single reusable type.

```sql
-- Define a composite type
CREATE TYPE address AS (
    street  text,
    city    text,
    state   text,
    zip     text
);

-- Use in a table
CREATE TABLE customers (
    id              serial PRIMARY KEY,
    name            text NOT NULL,
    billing_address address,
    shipping_address address
);

-- Insert and access
INSERT INTO customers (name, billing_address)
VALUES ('Acme Corp', ROW('123 Main St', 'Springfield', 'IL', '62701'));

SELECT (billing_address).city FROM customers;
SELECT * FROM customers WHERE (billing_address).state = 'IL';

-- Update a field within composite
UPDATE customers
SET billing_address.zip = '62702'
WHERE id = 1;
```

Composite types are also implicitly created for every table and are used as the row type in PL/pgSQL functions.

---

### Domain Types

Domains are named data types with optional constraints, providing centralized validation logic.

```sql
-- Email domain with CHECK constraint
CREATE DOMAIN email_address AS text
CHECK (VALUE ~ '^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$');

-- Non-negative money (in cents)
CREATE DOMAIN positive_cents AS integer
CHECK (VALUE > 0);

-- Non-empty text
CREATE DOMAIN nonempty_text AS text
CHECK (VALUE <> '' AND VALUE IS NOT NULL)
NOT NULL;

-- Use domains in tables
CREATE TABLE invoices (
    id            serial PRIMARY KEY,
    customer_email email_address NOT NULL,
    amount_cents   positive_cents NOT NULL,
    description    nonempty_text
);

-- Domain constraints can be altered without modifying tables
ALTER DOMAIN positive_cents ADD CONSTRAINT allow_zero CHECK (VALUE >= 0);
```

---

## Constraints

### CHECK Constraints

```sql
-- Column-level
CREATE TABLE products (
    id         serial PRIMARY KEY,
    price      numeric CHECK (price >= 0),
    status     text CHECK (status IN ('active', 'inactive', 'archived'))
);

-- Table-level (can reference multiple columns)
CREATE TABLE discounts (
    id              serial PRIMARY KEY,
    discount_pct    numeric,
    discount_flat   numeric,
    CONSTRAINT one_discount_type CHECK (
        (discount_pct IS NULL) != (discount_flat IS NULL)
    )
);

-- Named constraint for clearer error messages
ALTER TABLE orders ADD CONSTRAINT chk_positive_total
CHECK (total_cents > 0);
```

### UNIQUE Constraints

```sql
-- Single column
CREATE TABLE users (
    id    serial PRIMARY KEY,
    email text UNIQUE NOT NULL
);

-- Composite unique
CREATE TABLE team_members (
    team_id integer,
    user_id integer,
    UNIQUE (team_id, user_id)
);

-- Partial unique (unique only within a condition)
CREATE UNIQUE INDEX idx_users_active_email
ON users (email) WHERE deleted_at IS NULL;
```

### EXCLUDE Constraints

Exclusion constraints generalize UNIQUE by allowing any operator, not just equality. Require a GiST or SP-GiST index.

```sql
-- No two bookings for the same room may overlap
CREATE EXTENSION btree_gist;

CREATE TABLE bookings (
    id      serial PRIMARY KEY,
    room    text,
    during  tsrange,
    EXCLUDE USING gist (room WITH =, during WITH &&)
);
```

### Foreign Key Options

```sql
CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id integer,

    -- ON DELETE options:
    -- CASCADE     - delete order when customer deleted
    -- SET NULL    - set customer_id to NULL
    -- SET DEFAULT - set to column default
    -- RESTRICT    - error if customer has orders (default behavior)
    -- NO ACTION   - like RESTRICT but deferred-constraint-friendly

    CONSTRAINT fk_orders_customer
        FOREIGN KEY (customer_id)
        REFERENCES customers(id)
        ON DELETE RESTRICT
        ON UPDATE CASCADE
);
```

### Deferrable Constraints

Deferrable constraints are checked at transaction commit instead of statement time, enabling circular references and bulk data loading.

```sql
-- Define as deferrable
ALTER TABLE employees ADD CONSTRAINT fk_manager
FOREIGN KEY (manager_id) REFERENCES employees(id)
DEFERRABLE INITIALLY DEFERRED;

-- Or defer within a transaction
BEGIN;
SET CONSTRAINTS fk_manager DEFERRED;
-- Insert records that temporarily violate the constraint
INSERT INTO employees (id, manager_id, name) VALUES (1, 2, 'Alice');
INSERT INTO employees (id, manager_id, name) VALUES (2, 1, 'Bob');
COMMIT;  -- constraint checked here, both records now exist
```

---

## Generated Columns

Generated columns compute their value automatically from other columns. PG12+ supports STORED (persisted to disk). PG16+ added experimental VIRTUAL (computed on read, not stored).

```sql
-- STORED generated column
CREATE TABLE measurements (
    id            serial PRIMARY KEY,
    value_celsius numeric NOT NULL,
    -- Automatically computed and stored
    value_fahrenheit numeric GENERATED ALWAYS AS (value_celsius * 9/5 + 32) STORED
);

INSERT INTO measurements (value_celsius) VALUES (100);
SELECT value_celsius, value_fahrenheit FROM measurements;
-- Returns: 100, 212

-- Full name from parts
CREATE TABLE persons (
    id         serial PRIMARY KEY,
    first_name text NOT NULL,
    last_name  text NOT NULL,
    full_name  text GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED
);

-- Searchable slug from title
CREATE TABLE posts (
    id    serial PRIMARY KEY,
    title text NOT NULL,
    slug  text GENERATED ALWAYS AS (
        lower(regexp_replace(trim(title), '[^a-zA-Z0-9]+', '-', 'g'))
    ) STORED
);

CREATE INDEX idx_posts_slug ON posts(slug);
```

Restrictions: generation expression cannot reference other generated columns, user-defined functions must be IMMUTABLE, cannot have a DEFAULT, cannot be written to directly.

---

## Table Inheritance and Partitioning

### Traditional Inheritance (pre-PG10)

```sql
CREATE TABLE events (
    id         bigserial PRIMARY KEY,
    occurred_at timestamptz NOT NULL,
    payload    jsonb
);

CREATE TABLE click_events (
    element_id text NOT NULL
) INHERITS (events);

-- Queries on parent include child rows
SELECT count(*) FROM events;  -- includes click_events rows
SELECT count(*) FROM ONLY events;  -- excludes child tables
```

Traditional inheritance is largely superseded by declarative partitioning for the partition use case.

### Declarative Partitioning (PG10+)

#### Range Partitioning

```sql
CREATE TABLE events (
    id          bigint NOT NULL,
    occurred_at timestamptz NOT NULL,
    payload     jsonb
) PARTITION BY RANGE (occurred_at);

CREATE TABLE events_2024_q1 PARTITION OF events
FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

CREATE TABLE events_2024_q2 PARTITION OF events
FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');

-- Default partition catches unmatched rows
CREATE TABLE events_default PARTITION OF events DEFAULT;

-- Index on partition key (propagates to all partitions)
CREATE INDEX ON events (occurred_at);
```

#### List Partitioning

```sql
CREATE TABLE orders (
    id      bigint NOT NULL,
    region  text NOT NULL,
    total   numeric
) PARTITION BY LIST (region);

CREATE TABLE orders_us PARTITION OF orders FOR VALUES IN ('US', 'CA');
CREATE TABLE orders_eu PARTITION OF orders FOR VALUES IN ('DE', 'FR', 'GB');
CREATE TABLE orders_other PARTITION OF orders DEFAULT;
```

#### Hash Partitioning

```sql
CREATE TABLE user_events (
    user_id bigint NOT NULL,
    event   text
) PARTITION BY HASH (user_id);

CREATE TABLE user_events_0 PARTITION OF user_events FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE user_events_1 PARTITION OF user_events FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE user_events_2 PARTITION OF user_events FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE user_events_3 PARTITION OF user_events FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

#### Sub-partitioning

```sql
CREATE TABLE metrics (
    tenant_id integer NOT NULL,
    recorded_at date NOT NULL,
    value numeric
) PARTITION BY LIST (tenant_id);

CREATE TABLE metrics_tenant1 PARTITION OF metrics
FOR VALUES IN (1) PARTITION BY RANGE (recorded_at);

CREATE TABLE metrics_tenant1_2024 PARTITION OF metrics_tenant1
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
```

---

## Row-Level Security

RLS restricts which rows a user can see or modify. Enabled per table; policies define the filter predicate.

### Enabling RLS

```sql
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

-- Without this, the table owner bypasses all policies!
ALTER TABLE documents FORCE ROW LEVEL SECURITY;
```

### Policy Types

```sql
-- PERMISSIVE (default): policies are OR'd together; user sees rows matching ANY policy
-- RESTRICTIVE: policies are AND'd; user must match ALL restrictive policies

-- Allow users to see only their own rows
CREATE POLICY user_isolation ON documents
AS PERMISSIVE
FOR ALL
TO application_role
USING (owner_id = current_setting('app.user_id')::integer);

-- Separate read and write policies
CREATE POLICY documents_select ON documents
FOR SELECT
TO application_role
USING (owner_id = current_setting('app.user_id')::integer OR is_public = true);

CREATE POLICY documents_insert ON documents
FOR INSERT
TO application_role
WITH CHECK (owner_id = current_setting('app.user_id')::integer);

CREATE POLICY documents_update ON documents
FOR UPDATE
TO application_role
USING (owner_id = current_setting('app.user_id')::integer)
WITH CHECK (owner_id = current_setting('app.user_id')::integer);

CREATE POLICY documents_delete ON documents
FOR DELETE
TO application_role
USING (owner_id = current_setting('app.user_id')::integer);
```

### Multi-Tenant Pattern

```sql
-- Set tenant context at session start (via connection pooler or app middleware)
SET app.tenant_id = '42';

-- RLS policy using session variable
CREATE POLICY tenant_isolation ON orders
USING (tenant_id = current_setting('app.tenant_id')::integer);

-- Superuser bypass: use a dedicated non-superuser role for the app
CREATE ROLE app_user NOLOGIN;
GRANT SELECT, INSERT, UPDATE, DELETE ON orders TO app_user;

-- Service role that bypasses RLS (for admin tasks)
CREATE ROLE service_role BYPASSRLS LOGIN;
```

### RESTRICTIVE Policies

```sql
-- Combine PERMISSIVE (what user owns) AND RESTRICTIVE (not deleted)
CREATE POLICY only_active ON documents
AS RESTRICTIVE
FOR ALL
USING (deleted_at IS NULL);

CREATE POLICY owner_access ON documents
AS PERMISSIVE
FOR ALL
USING (owner_id = current_setting('app.user_id')::integer);

-- Result: user sees rows where deleted_at IS NULL AND owner_id matches
```

### Common Pitfalls

| Pitfall | Fix |
|---------|-----|
| Table owner bypasses RLS silently | Add `FORCE ROW LEVEL SECURITY` to the table |
| No policy defined means no rows visible | Always define at least one PERMISSIVE policy per operation |
| Superuser always bypasses RLS | Use a non-superuser application role |
| `current_user` vs session variable | Use `current_setting()` for app-set context; `current_user` reflects DB login role |
| Performance: predicate not pushed down | Create index on the tenant/owner column used in policy USING clause |

```sql
-- Verify your policies are working
SET ROLE app_user;
SET app.user_id = '1';
SELECT count(*) FROM documents;  -- should only return user 1's documents
RESET ROLE;
```
