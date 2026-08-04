# SQLite Query Performance

Engine-agnostic. Everything here applies to any SQLite 3.x host — CLI, Python, Node, Bun,
Cloudflare D1, libSQL/Turso — because the query planner is the same code everywhere. Host
differences are about *how you observe* the cost, not what the cost is; see
[`d1-edge.md`](d1-edge.md) and [`hosts.md`](hosts.md) for those.

## Contents

- [The measurement contract](#the-measurement-contract)
- [Reading EXPLAIN QUERY PLAN](#reading-explain-query-plan)
- [Covering indexes](#covering-indexes)
- [Predicates that cannot be seeked](#predicates-that-cannot-be-seeked)
- [LIKE and GLOB optimisation rules](#like-and-glob-optimisation-rules)
- [Index design and column order](#index-design-and-column-order)
- [Partial and expression indexes](#partial-and-expression-indexes)
- [ANALYZE and sqlite_stat1](#analyze-and-sqlite_stat1)
- [Query planner defeats](#query-planner-defeats)
- [Joins and subqueries](#joins-and-subqueries)
- [Pagination](#pagination)
- [The read-only proof technique](#the-read-only-proof-technique)
- [A worked optimisation, end to end](#a-worked-optimisation-end-to-end)
- [Triage checklist](#triage-checklist)

---

## The measurement contract

Before changing anything, be able to state four numbers for the statement you are about to
optimise: **median latency, range across runs, rows read, and plan shape.** If you can't,
you are guessing.

| Rule | Why | How |
|---|---|---|
| Measure the **statement**, not the request/tool call | A statement piggy-backing on a batch someone else was already sending adds no round trip, so it never appears in per-call timing — while still scanning the table on every request | Decompose multi-part statements; time each part alone |
| Use engine-reported duration | Process/driver startup dominates a CLI stopwatch (a `npx`-shaped launch is ~2 s before any SQL runs) | `.timer on` (CLI), `sql_duration_ms` (D1), driver-level instrumentation |
| Median of 10+, report the range | First runs are cold: a 1.5–1.7x first-run penalty on multi-thousand-row reads is routine, and outliers an order of magnitude above the median happen | Loop the statement, sort, take the middle |
| Report latency **and** rows scanned | They move independently: an optimisation can cut latency ~25x with rows-read unchanged, and a different one can collapse rows-read ~58,000x | Pair `sql_duration_ms`-style timing with a rows-read counter |

**Why rows-read matters even when latency doesn't change.** Rows read is a proxy for work
done and, on managed engines, is literally the billing unit. Two optimisations with
identical latency wins can have completely different cost profiles. Always report both, and
never let one stand in for the other.

### Getting the numbers per host

```bash
# sqlite3 CLI — engine timing plus a scan counter
sqlite3 app.db '.timer on' 'SELECT ...;'
sqlite3 app.db '.stats on' 'SELECT ...;'   # includes fullscan steps / sort counts
```

```python
# Python — sqlite3 exposes VM steps, a good proxy for work done
import sqlite3, time, statistics
conn = sqlite3.connect("app.db")
times = []
for _ in range(12):
    t0 = time.perf_counter()
    conn.execute(SQL).fetchall()
    times.append((time.perf_counter() - t0) * 1000)
print(f"median {statistics.median(times):.2f} ms  range {min(times):.2f}-{max(times):.2f}")
```

For Cloudflare D1's `meta.timings.sql_duration_ms` / `meta.rows_read`, see
[`d1-edge.md`](d1-edge.md) — those are server-side and are the only trustworthy numbers there.

---

## Reading EXPLAIN QUERY PLAN

EQP is read-only, instant, and safe on production. Run it first, every time.

```sql
EXPLAIN QUERY PLAN SELECT ...;
```

| Line | What the engine is doing | Read as |
|---|---|---|
| `SEARCH t USING INDEX ix (col=?)` | Seek into a B-tree, then fetch each matching row from the table | Good |
| `SEARCH t USING COVERING INDEX ix (col=?)` | Seek, and answer entirely from the index — the table is never touched | Best |
| `SEARCH t USING INTEGER PRIMARY KEY (rowid=?)` | Direct rowid lookup | Best |
| `SCAN t USING COVERING INDEX ix` | Every entry of a narrow index is read; the table is never touched | Acceptable, often the right answer for unseekable predicates |
| `SCAN t USING INDEX ix` | Every index entry read **and** a table row fetched per hit — usually strictly worse than a plain scan | Suspicious |
| `SCAN t` | Full table scan: every row, all columns' pages | Fix unless the table is tiny |
| `USE TEMP B-TREE FOR ORDER BY` | No index supplies the requested order; rows are buffered and sorted | Cost signal |
| `USE TEMP B-TREE FOR GROUP BY` | Same for grouping | Cost signal |
| `USE TEMP B-TREE FOR DISTINCT` | Same for de-duplication | Cost signal |
| `CORRELATED SCALAR SUBQUERY` | Subquery re-runs once per outer row | Usually dominates |
| `MULTI-INDEX OR` | An `OR` split into multiple index lookups then merged | Fine; better than the scan it replaced |
| `BLOOM FILTER ON t` | Join pre-filter (3.38+) | Informational |
| `MATERIALIZE subquery` | A subquery/CTE result is written to a temp table then read | Watch for repeated materialisation |

### The three questions to ask of any plan

1. **Is there a `SCAN` on a large table?** If yes, is it covering? A non-covering scan on a
   wide table is the single most common cause of slow SQLite.
2. **Is there a temp B-tree?** That is a sort or grouping the schema could have supplied.
   Note it, but do not fix it first — an index added for the scan often removes it for free.
3. **Does the plan change after `ANALYZE`?** If yes, your production behaviour depends on
   whether stats exist. See [ANALYZE and sqlite_stat1](#analyze-and-sqlite_stat1).

### EXPLAIN vs EXPLAIN QUERY PLAN

`EXPLAIN` (without `QUERY PLAN`) dumps the VDBE bytecode — hundreds of opcodes. It is
occasionally useful for confirming *which* index a statement opened, or spotting a hidden
`OpenEphemeral` (a temp table), but EQP answers 95% of questions. Reach for `EXPLAIN` only
after EQP has left you genuinely puzzled.

---

## Covering indexes

An index **covers** a statement when every column the statement needs — in the `WHERE`, the
`SELECT` list, the `ORDER BY`, the `GROUP BY` — is present in the index itself. The engine
then answers from the index and never reads the table.

This is the highest-value optimisation in SQLite specifically because SQLite stores rows
contiguously: a 73-column row costs the same page reads whether you asked for one column or
all of them. A covering index turns "read 58k wide rows" into "read 58k narrow entries".

```sql
-- Statement: filter on org, project product_id
SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%';

-- Covering index — FILTERED column first, PROJECTED column second
CREATE INDEX q_product_org_product ON q_product(org, product_id);
```

**Column order is load-bearing**, even when the leading column can't be seeked:

- The leading column is what the planner matches against the `WHERE` clause when deciding
  the index is relevant at all.
- Trailing columns exist to make the index *cover*, not to be searched.
- Reversing them (`(product_id, org)`) gives you an index the planner is far less likely to
  choose for this statement.

### When a covering index is the right answer

| Situation | Covering index? |
|---|---|
| Predicate is unseekable (`LIKE '%x%'`, function on column) but the table is wide | **Yes** — this is the classic win |
| Predicate is seekable and selective | Usually unnecessary — a plain index already avoids most row reads |
| Statement projects many columns | No — the index would be as wide as the table |
| Table is narrow (a few small columns) | No — a table scan already reads narrow pages |

### Verify it worked

```sql
EXPLAIN QUERY PLAN SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%';
-- want: SCAN q_product USING COVERING INDEX q_product_org_product
-- not:  SCAN q_product USING INDEX q_product_org
```

The word **COVERING** is the whole test. If it is missing, some column the statement needs
isn't in the index — commonly because someone wrote `SELECT *`.

---

## Predicates that cannot be seeked

A B-tree can only seek when the predicate constrains a **prefix of the indexed value**.
Anything that transforms the column first destroys that property.

| Predicate | Seekable? | Remedy |
|---|---|---|
| `col = ?` / `col IN (…)` / `col > ?` / `BETWEEN` | Yes | Plain index |
| `col LIKE 'abc%'` | Yes, conditionally (see below) | Plain index |
| `col LIKE '%abc%'` or `'%abc'` | **No** | Covering index, or FTS5 trigram |
| `lower(col) = ?`, `date(col) = ?`, `substr(col,1,3) = ?` | **No** | Expression index on the same expression |
| `col + 0 = ?`, `CAST(col AS TEXT) = ?` | **No** | Fix the type, or expression index |
| `col LIKE ?` (parameterised pattern) | **No** at prepare time | The planner can't see the pattern; treat as unseekable |
| `a = ? OR b = ?` | Sometimes (`MULTI-INDEX OR`) | Index both columns; or rewrite as `UNION` |
| `col != ?`, `NOT IN` | Effectively no | Rethink the predicate |
| `col IS NULL` | Yes | Plain index (NULLs are indexed in SQLite) |
| `json_extract(doc,'$.k') = ?` | **No** | Expression index or generated column + index |

**Type mismatch is a silent killer.** Because of type affinity, comparing a TEXT column to
an integer parameter can prevent index use *and* silently return nothing. `WHERE id = '42'`
against an `INTEGER` column and `WHERE code = 42` against a `TEXT` column both behave
surprisingly — see [`schema-design.md`](schema-design.md).

---

## LIKE and GLOB optimisation rules

SQLite converts `LIKE` into a range constraint (`col >= 'abc' AND col < 'abd'`) only when
**all** of these hold:

1. The pattern is a **string literal or a bound parameter whose value is known**, and it
   does not start with a wildcard (`%` or `_`).
2. The column has **TEXT affinity** and the default **`BINARY`** collation — unless
   `PRAGMA case_sensitive_like = ON`, in which case `BINARY` is required, or the column
   uses `COLLATE NOCASE`, which enables the optimisation for case-insensitive `LIKE`.
3. The `ESCAPE` clause is not used.
4. The right-hand side is not a column reference.

`GLOB` follows the same rule with `*`/`?` wildcards and is always case-sensitive, so it
optimises under `BINARY` collation without the `case_sensitive_like` dance.

```sql
-- Optimisable: anchored prefix
SELECT * FROM city WHERE name LIKE 'Syd%';         -- SEARCH ... USING INDEX

-- Not optimisable: leading wildcard
SELECT * FROM city WHERE name LIKE '%ney';         -- SCAN

-- Case-insensitive, still optimisable if the column is COLLATE NOCASE
CREATE TABLE city (name TEXT COLLATE NOCASE);
CREATE INDEX city_name ON city(name);
SELECT * FROM city WHERE name LIKE 'syd%';          -- SEARCH ... USING INDEX
```

**For genuine substring search, stop fighting `LIKE`.** FTS5 with the `trigram` tokenizer
indexes 3-character sequences and makes `LIKE '%abc%'` and `MATCH` both fast — see
[`feature-modules.md`](feature-modules.md). The covering-index trick makes an unseekable
scan cheaper; trigram FTS makes it disappear.

---

## Index design and column order

### The ordering rule

For a composite index `(a, b, c)`, the planner can use a prefix — `(a)`, `(a, b)`,
`(a, b, c)` — never a suffix. Order columns:

1. **Equality predicates first** (`WHERE a = ?`)
2. **Then one range or sort column** (`WHERE b > ?` or `ORDER BY b`)
3. **Then columns needed only for coverage** (projected, never filtered)

```sql
-- Statement: WHERE org = ? AND created_at > ? ORDER BY created_at, projecting title
CREATE INDEX ev_org_created ON events(org, created_at, title);
--                                    ^equality  ^range/sort   ^coverage only
```

A range column stops the usefulness of everything after it for *seeking* — but those
trailing columns still count for *coverage*, which is exactly why coverage columns go last.

### Sizing and maintenance

| Consideration | Guidance |
|---|---|
| Write cost | Every index is updated on every INSERT/UPDATE/DELETE touching its columns |
| Redundant indexes | `(a)` is redundant if `(a, b)` exists — drop the shorter one |
| Index size | Check with `dbstat` (if compiled in) or by summing column widths; a covering index over wide TEXT columns can rival the table |
| Naming | `<table>_<col1>_<col2>` — readable in EQP output, which is where you will see it |
| `UNIQUE` | Enforces a constraint *and* provides an index — don't add both |

### DESC and ORDER BY

SQLite can scan an index backwards, so `CREATE INDEX ix ON t(a)` serves both
`ORDER BY a` and `ORDER BY a DESC`. A `DESC` index is only needed for **mixed** orders:

```sql
-- Needs an explicitly mixed index; a plain (a, b) index cannot supply this order
SELECT * FROM t ORDER BY a ASC, b DESC;
CREATE INDEX t_a_bdesc ON t(a ASC, b DESC);
```

---

## Partial and expression indexes

### Partial indexes

Index only the rows you actually query. Smaller index, cheaper writes for the excluded rows.

```sql
-- Only pending jobs are ever fetched by this predicate
CREATE INDEX job_pending ON job_queue(priority DESC, created_at)
    WHERE status = 'pending';

-- Only non-NULL values matter
CREATE INDEX product_sku ON product(sku) WHERE sku IS NOT NULL;
```

**The catch:** the planner uses a partial index only when it can *prove* the statement's
`WHERE` clause implies the index's `WHERE` clause. `WHERE status = 'pending'` matches;
`WHERE status = :status` does **not**, because the value isn't known at prepare time. Write
the literal, or keep a full index.

### Expression indexes

When you can't stop the code calling a function on the column, index the function.

```sql
CREATE INDEX user_email_lower ON users(lower(email));
SELECT * FROM users WHERE lower(email) = lower(?);   -- now seekable

CREATE INDEX ev_kind ON events(json_extract(payload, '$.kind'));
SELECT * FROM events WHERE json_extract(payload, '$.kind') = 'login';
```

The expression in the query must match the indexed expression **syntactically**. Only
deterministic functions are allowed.

**Generated column alternative** — often clearer, and indexable the same way:

```sql
ALTER TABLE events ADD COLUMN kind TEXT
    GENERATED ALWAYS AS (json_extract(payload, '$.kind')) VIRTUAL;
CREATE INDEX ev_kind ON events(kind);
```

`VIRTUAL` costs nothing on disk and is computed on read; `STORED` costs disk and is
computed on write. For an indexed generated column, `VIRTUAL` is usually right — the index
already materialises the value.

---

## ANALYZE and sqlite_stat1

`ANALYZE` samples indexes and writes row-distribution statistics into the `sqlite_stat1`
table. Without it, the planner uses fixed guesses (roughly: "an index lookup returns ~10
rows"), which is fine for simple statements and wrong for skewed data.

```sql
ANALYZE;              -- whole database
ANALYZE events;       -- one table and its indexes
SELECT * FROM sqlite_stat1;   -- empty means it never ran
PRAGMA optimize;      -- run periodically / before closing: ANALYZEs only what changed
```

`PRAGMA optimize` is the maintenance answer for a long-lived application: cheap, targeted,
and safe to call on connection close.

### Verify the plan with and without statistics

**Many managed engines never run `ANALYZE`.** If your index only wins once stats exist, it
may not win in production. Test both states explicitly rather than assuming:

```sql
ANALYZE;
EXPLAIN QUERY PLAN SELECT ...;         -- plan A

DELETE FROM sqlite_stat1;
ANALYZE sqlite_master;                 -- forces the planner to reload now-empty stats
EXPLAIN QUERY PLAN SELECT ...;         -- plan B — same as A?
```

If A and B agree, the index is chosen regardless of statistics and you are safe. If they
disagree, either arrange for `ANALYZE` to run in production, or design an index the planner
picks without stats. In the worked example below, the covering index was chosen in both
states — a result that was **verified, not assumed**.

`sqlite_stat1` is an ordinary table: you can copy it between databases to reproduce a
production plan locally, which is the cheapest way to debug "fast on my machine".

---

## Query planner defeats

| Anti-pattern | Effect | Fix |
|---|---|---|
| `SELECT *` | Prevents covering-index plans; reads every column's page | Project explicitly |
| Function on an indexed column | Index unusable | Expression index, or move the function to the parameter side |
| Type mismatch (TEXT column vs integer param) | Index unusable; may silently return nothing | Fix affinity, cast the parameter, use `STRICT` |
| `OR` across different columns | May force a scan | `MULTI-INDEX OR` needs an index per branch; else rewrite as `UNION ALL` |
| `NOT IN (subquery)` with NULLs | Returns no rows at all | `NOT EXISTS` |
| Correlated scalar subquery in the `SELECT` list | Re-executed per row | Rewrite as a `JOIN` or a windowed aggregate |
| `LIMIT` without `ORDER BY` | Non-deterministic rows | Always pair them |
| `OFFSET` pagination on a large table | Scans and discards | Keyset pagination (below) |
| `ORDER BY random()` | Full sort of the table | Sample by rowid range |
| Aggregates over an unindexed column | Full scan per call | Index the column, or maintain a watermark row |
| Too many indexes | Slows every write, bloats the file | Audit; drop redundant prefixes |

### The invisible aggregate

The subtlest cost in this list. An aggregate like `MAX(updated_at)` over an unindexed
column scans the table — but if it ships inside a statement batch the application was
already sending, it costs **no extra round trip** and never surfaces in per-request timing.

Decomposition is how you find it:

```sql
-- The full statement as shipped
SELECT count(*) AS n, MAX(updated_at) AS watermark FROM q_product;

-- Time each half separately:
SELECT count(*) FROM q_product;                    -- cheap? then the MAX owns the cost
SELECT MAX(updated_at) FROM q_product;             -- the real cost centre
```

In the measured example: the full statement 27.17 ms / 58,434 rows; the `MAX` alone
28.09 ms / 58,432 rows; the statement **without** the `MAX` 0.17 ms / 2 rows; the same
`MAX` over an indexed column 0.17 ms / 1 row. One index on the aggregated column removed a
58,000-row scan from every response across four separate tools.

**Rule:** any `MIN`/`MAX`/`COUNT DISTINCT` over an unindexed column, executed per request,
is a full scan hiding in plain sight. Index the column — `MAX(col)` over an indexed column
is an O(log n) walk to the end of the B-tree.

---

## Joins and subqueries

SQLite uses nested-loop joins exclusively. Performance therefore hinges on the **inner**
table having an index on the join column.

```sql
EXPLAIN QUERY PLAN
SELECT o.id, u.email FROM orders o JOIN users u ON u.id = o.user_id;
-- want: SCAN o  +  SEARCH u USING INTEGER PRIMARY KEY (rowid=?)
-- bad:  SCAN o  +  SCAN u                      -> O(n*m)
```

| Symptom | Fix |
|---|---|
| `SCAN` on the inner table | Index the join column on the inner table |
| Join order looks wrong | Usually the planner is right; if genuinely wrong, `ANALYZE` first, `CROSS JOIN` to force order only as a last resort |
| CTE materialised repeatedly | `WITH x AS NOT MATERIALIZED (...)` (3.35+) to inline, or `AS MATERIALIZED` to force one evaluation |
| `IN (subquery)` slow | Often better as a `JOIN`; check whether the subquery is correlated |

---

## Pagination

```sql
-- Bad: OFFSET must generate and discard 10,000 rows
SELECT * FROM events ORDER BY id LIMIT 20 OFFSET 10000;

-- Good: keyset pagination — seeks straight to the page
SELECT * FROM events WHERE id > :last_id ORDER BY id LIMIT 20;

-- Composite sort key
SELECT * FROM events
WHERE (created_at, id) > (:last_created, :last_id)
ORDER BY created_at, id LIMIT 20;
```

Keyset pagination needs an index on exactly the sort key. It also gives stable results when
rows are inserted between page fetches, which `OFFSET` does not.

---

## The read-only proof technique

**Problem:** you believe an index will help, but creating it means writing to production
schema — which in a properly gated setup you cannot do from a working session, and which is
irreversible enough that you would like evidence first.

**Technique:** run the **identical statement shape** against a column that an existing index
already covers. Same table, same row count, same predicate shape, same projection width —
only the column identity changes. The measured difference is your projected payoff, obtained
with zero writes.

```sql
-- Control: the real, unindexed statement
SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%acme%';
-- measured: 171.83 ms, 60,736 rows read

-- Proof: same shape over a column already covered by an index
SELECT DISTINCT org FROM q_product WHERE org LIKE '%acme%';
-- measured:   6.75 ms, 58,433 rows read
```

**How to keep the proof honest:**

| Requirement | Why |
|---|---|
| Same table and same predicate shape | Row count and scan pattern must match |
| Comparable column width | Proving with a 4-byte int and shipping a 200-char TEXT column overstates the win |
| Same projection count | `DISTINCT one_col` vs `DISTINCT three_cols` are different index widths |
| Confirm the control's plan is what you think | Run EQP on both; the proof shot should show `COVERING` |
| Report rows-read for both | If rows-read is unchanged, the win is row *width* — say so |

**What this technique cannot prove:** whether the planner will *choose* your new index (see
[ANALYZE](#analyze-and-sqlite_stat1)), or what the index costs on write. Pair it with the
stats check and a write-volume sanity check before shipping.

Generalises beyond indexes: any time you want to measure "what if this data were shaped
differently" on a production system you may not write to, look for an existing object that
already has the shape you're proposing and measure against that.

---

## A worked optimisation, end to end

> **These are numbers from one database, not constants.** Measured 2026-08-04 against a
> live Cloudflare D1 (`atdw-mirror`, region OC, colo SYD), 12 runs each, reporting the
> median of server-side `sql_duration_ms`. Table: 73 columns, 58k rows. Your database will
> produce different magnitudes; the *shape* of the reasoning is what transfers.

**1. Symptom.** A lookup filtering on an organisation name took ~170 ms and got slower as
the table grew.

**2. Plan.**

```
SCAN q_product USING INDEX q_product_org
```

A `SCAN` — but *with* an index. That combination is the tell: the index was consulted and
bought nothing, because the predicate was `LIKE '%…%'` and could not be seeked.

**3. Diagnosis.** Leading-wildcard `LIKE` is unseekable by construction. The existing index
did not cover the projected column, so every one of the 58k index entries triggered a fetch
of a 73-column row. The cost was **row width**, not row count.

**4. Hypothesis.** A covering index `(org, product_id)` keeps the scan but confines it to
narrow index entries.

**5. Read-only proof.** The same statement shape over an already-covered column: **6.75 ms /
58,433 rows** vs the control's **171.83 ms / 60,736 rows**. ~25x, with rows read essentially
unchanged — confirming the win is width, not selectivity.

**6. Stats check.** Plan compared with `sqlite_stat1` populated and after deleting it. The
covering index was chosen in both states — verified, not assumed.

**7. Second-order effect.** With the covering index in place, SQLite **dropped the
`GROUP BY` temp B-tree on its own**. A hand-rewrite to avoid the grouping measured 5.99 ms
vs 5.85 ms — noise. *Re-read the plan after adding an index before hand-optimising anything
else; the index may have already fixed it.*

**8. The one that was invisible.** A separate `MAX()` over an unindexed column rode inside a
batch the application was already sending: 28.09 ms and 58,432 rows scanned per response
across four tools, never once appearing in per-query timing. Decomposition found it; an
index on the aggregated column reduced it to 0.17 ms / 1 row.

**Transferable lessons:** `SCAN … USING INDEX` means the index is not earning its keep ·
prove before you write · check the plan with and without stats · re-read the plan after
each change · measure statements, not calls.

---

## Triage checklist

Work top to bottom; stop when the numbers are acceptable.

1. **Capture the baseline** — median of 10+, range, rows read, engine-reported timing.
2. **`EXPLAIN QUERY PLAN`** — classify every line against the table above.
3. **Any `SCAN` on a large table?** Determine whether the predicate is seekable at all.
   - Seekable → add or fix the index.
   - Unseekable → make the scan covering, or move to FTS5 trigram.
4. **`SCAN … USING INDEX`** (non-covering)? The index is not earning its place — either
   extend it to cover, or drop it.
5. **Decompose multi-part statements** — time each part; hunt for invisible aggregates.
6. **Check `SELECT *`** — it silently defeats covering plans.
7. **Prove read-only** before writing schema (see above).
8. **Check the plan with and without `sqlite_stat1`.**
9. **Apply the change; re-read the plan.** Temp B-trees often vanish for free.
10. **Re-measure both metrics** — latency and rows read — and report the deltas separately.

---

## See also

- [`d1-edge.md`](d1-edge.md) — measuring on Cloudflare D1, rows-read billing, caps
- [`schema-design.md`](schema-design.md) — affinity and type mismatches that defeat indexes
- [`feature-modules.md`](feature-modules.md) — FTS5 trigram as the real fix for substring search
- [`operations.md`](operations.md) — `PRAGMA optimize`, page sizing, size analysis
- `perf-ops` skill — the surrounding before/after profiling workflow
