# Covering-Index Worked Example

The measured investigation behind SKILL.md's covering-index advice: why a plain index on a leading-wildcard `LIKE` changes nothing, the fix, the before/after numbers from one live D1 database, and how to confirm the planner chooses the index with and without `sqlite_stat1`.

### The unseekable-predicate trap (worked example)

A leading-wildcard `LIKE '%x%'` can **never** use a B-tree — SQLite optimises `LIKE` only
for an anchored prefix (`'x%'`). So a plain index on that column changes nothing, people
observe no improvement, and conclude "indexing didn't help here". The index wasn't wrong;
the *shape* was. The fix is to make the scan **covering**, so the unavoidable full pass
reads narrow index entries instead of wide rows.

```sql
-- Column order is load-bearing: FILTERED column first, PROJECTED column second.
CREATE INDEX q_product_org_product ON q_product(org, product_id);
```

> **Worked example — one database, not a constant.** Measured 2026-08-04 against a live
> Cloudflare D1 (`atdw-mirror`, region OC, colo SYD), 12 runs each, median of server-side
> `sql_duration_ms`; 73-column table, 58k rows.
> Before: `SCAN q_product USING INDEX q_product_org`, **171.83 ms**, 60,736 rows read.
> The identical statement shape over an already-covered column: **6.75 ms**, 58,433 rows
> read. **~25x faster with rows-read essentially unchanged** — proof that the win came from
> row width, not from touching fewer rows. Your table's numbers will differ; the *shape* of
> the result is what transfers.
>
> Two further findings from the same session worth internalising:
> - Once the covering index existed, SQLite **dropped the `GROUP BY` temp B-tree by itself**.
>   A hand-rewrite to avoid the grouping measured 5.99 ms vs 5.85 ms — noise. Don't
>   hand-optimise around a temp B-tree until you have re-read the plan post-index.
> - An unindexed `MAX()` riding inside a batch another query was already sending cost
>   **28.09 ms and 58,432 rows scanned on every response across four tools**, while the
>   statement without it cost 0.17 ms / 2 rows. The same `MAX()` over an indexed column:
>   0.17 ms / 1 row. It never showed up in per-query timing because it added no round trip.

### Verify the planner's choice with and without statistics

A covering index may only be *chosen* once `ANALYZE` has populated `sqlite_stat1` — and
many hosted engines never run `ANALYZE` for you. Test both states before you rely on it:

```sql
ANALYZE;                                  -- populate sqlite_stat1
EXPLAIN QUERY PLAN SELECT ...;            -- record the plan

DELETE FROM sqlite_stat1;                 -- simulate a never-analyzed database
ANALYZE sqlite_master;                    -- force the planner to reload (now-empty) stats
EXPLAIN QUERY PLAN SELECT ...;            -- same plan? then you are safe either way
```

In the worked example the covering index was chosen in **both** states — verified, not
assumed. Do the same check rather than inheriting that result.
