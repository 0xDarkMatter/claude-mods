# data.table — High-Performance Data Manipulation

`data.table` is an in-memory data frame replacement optimised for large datasets.
Use it when dplyr is too slow, memory is constrained, or reference semantics are
wanted. Core advantage: **no copies** — mutations happen in place via `:=`.

---

## Core Syntax: `DT[i, j, by]`

```r
DT[i, j, by]
# i  = row filter (WHERE)
# j  = column expression (SELECT / mutate)
# by = grouping variable(s) (GROUP BY)
```

Empty slots use nothing — not `NULL`, not a comma placeholder for `i`/`by`, but
literally omit when chaining makes sense.

---

## Creating data.tables

```r
library(data.table)

# From scratch
DT <- data.table(id = 1:5, val = rnorm(5), grp = c("a","a","b","b","b"))

# Convert data.frame — copies
DT <- as.data.table(df)

# Convert in place — no copy (modifies df's class)
setDT(df)        # df is now a data.table; no assignment needed
setDF(DT)        # reverse: back to data.frame in place
```

---

## Row Filtering (`i`)

```r
DT[val > 0]                    # logical
DT[grp == "a"]
DT[grp %in% c("a","b")]

# Keyed binary search (set key first — see Keys section)
setkey(DT, grp)
DT["a"]                        # all rows where grp == "a"
DT[.("a", "b")]                # multi-value lookup
```

---

## Column Operations (`j`)

```r
# Select columns — use .() not c()
DT[, .(id, val)]
DT[, c("id", "val")]           # also works; .() is idiomatic

# Compute
DT[, .(mean_val = mean(val), n = .N)]

# Add / update column BY REFERENCE — no copy made
DT[, new_col := val * 2]
DT[grp == "a", flag := TRUE]   # conditional assignment

# Multiple columns at once
DT[, `:=`(sq = val^2, log_val = log(val + 1))]

# Delete a column
DT[, drop_col := NULL]

# .N — row count (in j or by context)
DT[, .N]                       # total rows
DT[, .N, by = grp]             # rows per group

# .SD — Subset of Data (the current group's rows as a data.table)
DT[, lapply(.SD, mean), by = grp]

# .SDcols — restrict .SD to specific columns
DT[, lapply(.SD, sum), by = grp, .SDcols = c("val", "sq")]

# .I — row indices of the original DT
DT[, .I[which.max(val)], by = grp]   # index of max val per group

# .GRP — integer group counter (1, 2, ...)
DT[, grp_id := .GRP, by = grp]
```

---

## Grouping (`by` / `keyby`)

```r
DT[, .(total = sum(val)), by = grp]          # result order not guaranteed
DT[, .(total = sum(val)), keyby = grp]       # result sorted by grp (sets key too)

# Multi-column grouping
DT[, .(n = .N), by = .(grp, flag)]

# Expression in by
DT[, .(mean_val = mean(val)), by = .(positive = val > 0)]
```

---

## Keys and Indices

```r
# Set key — sorts DT in place, enables binary search
setkey(DT, grp)
key(DT)                        # check current key

# Composite key
setkey(DT, grp, id)

# Secondary index (doesn't sort; auto-created on first on= use)
setindex(DT, val)

# Ad-hoc join / filter without setting key
DT[.(val = "a"), on = "grp"]
```

---

## Joins

```r
# Basic join — X[Y] — right join by default (all Y rows kept)
X[Y, on = .(id)]               # Y's rows drive output

# Left join
Y[X, on = .(id)]

# Inner join
merge(X, Y, by = "id")         # uses merge.data.table, returns data.table

# Full outer join
merge(X, Y, by = "id", all = TRUE)

# Nomatch — control unmatched behaviour
X[Y, on = .(id), nomatch = NULL]   # inner join via [

# Non-equi join
X[Y, on = .(start <= date, end >= date)]

# Rolling join — last observation carried forward
setkey(prices, date)
trades[prices, roll = TRUE, on = .(date)]   # each trade gets prev price

# roll = "nearest" for nearest-value join
# roll = -Inf for next observation carried backward (NOCB)

# Anti-join
X[!Y, on = .(id)]
```

---

## Reshaping

```r
# Wide → long (like tidyr::pivot_longer)
long <- melt(DT,
  id.vars       = c("id", "grp"),
  measure.vars  = c("val", "sq"),
  variable.name = "metric",
  value.name    = "number")

# Long → wide (like tidyr::pivot_wider)
wide <- dcast(long,
  id + grp ~ metric,
  value.var = "number",
  fun.aggregate = sum)   # if there are duplicates

# Multiple value columns at once
dcast(long, id ~ metric, value.var = c("number"))
```

---

## Fast I/O: fread / fwrite

```r
# fread — fastest CSV reader (multi-threaded, auto-detects sep, header, types)
DT <- fread("large.csv")
DT <- fread("large.csv", select = c("id", "val"), nrows = 1e6)
DT <- fread("zcat large.csv.gz |")   # pipe input

# fwrite — fastest CSV writer
fwrite(DT, "output.csv")
fwrite(DT, "output.csv.gz", compress = "gzip")

# Common options
fread("data.csv",
  na.strings = c("", "NA", "NULL"),
  colClasses = list(character = "id"),
  skip        = 2)
```

---

## Chaining

```r
# Chain [] calls — left to right
DT[val > 0][, .(mean_val = mean(val)), by = grp][order(-mean_val)]

# Equivalent pipe style (R 4.1+)
DT |> _[val > 0] |> _[, .(mean_val = mean(val)), by = grp]
# Note: the _ placeholder pipe syntax for [  is awkward — chaining is cleaner
```

---

## dtplyr — dplyr Syntax, data.table Speed

```r
library(dtplyr)

# Wrap once; dplyr verbs generate data.table calls lazily
lazy <- lazy_dt(DT)

result <- lazy |>
  filter(val > 0) |>
  group_by(grp) |>
  summarise(mean_val = mean(val)) |>
  as.data.table()   # or collect() / as_tibble()

# See generated code
lazy |> filter(val > 0) |> show_query()
```

Use dtplyr when: team knows dplyr, data is large enough to need data.table speed,
but you don't want to rewrite pipelines. Accept ~10-20% overhead vs native data.table.

---

## dplyr ↔ data.table Translation

| dplyr | data.table |
|---|---|
| `filter(DT, val > 0)` | `DT[val > 0]` |
| `select(DT, id, val)` | `DT[, .(id, val)]` |
| `mutate(DT, sq = val^2)` | `DT[, sq := val^2]` |
| `summarise(DT, n = n())` | `DT[, .(.N)]` |
| `group_by(DT, grp) |> summarise(m = mean(val))` | `DT[, .(m = mean(val)), by = grp]` |
| `arrange(DT, -val)` | `DT[order(-val)]` |
| `left_join(X, Y, by = "id")` | `Y[X, on = .(id)]` |
| `inner_join(X, Y, by = "id")` | `X[Y, on = .(id), nomatch = NULL]` |
| `pivot_longer(...)` | `melt(DT, id.vars = ..., measure.vars = ...)` |
| `pivot_wider(...)` | `dcast(DT, formula, value.var = ...)` |
| `bind_rows(A, B)` | `rbindlist(list(A, B), fill = TRUE)` |
| `bind_cols(A, B)` | `cbind(A, B)` |
| `distinct(DT, grp)` | `unique(DT, by = "grp")` |
| `slice_max(DT, val, by = grp)` | `DT[DT[, .I[which.max(val)], by=grp]$V1]` |
| `rename(DT, new = old)` | `setnames(DT, "old", "new")` |
| `relocate` | `setcolorder(DT, c("id", ...))` |
| `n_distinct(x)` | `uniqueN(x)` |
| `count(DT, grp)` | `DT[, .N, by = grp]` |

---

## Performance Intuition

```
Operation            dplyr (tibble)    data.table     Speedup
─────────────────────────────────────────────────────────────
groupby sum, 100M    ~4.5 s            ~0.3 s          15×
equi join, 10M×10M   ~8 s              ~0.5 s          16×
CSV read, 1GB        ~12 s (readr)     ~2 s (fread)     6×
melt, 50M rows       ~3 s (tidyr)      ~0.4 s           7×
```

Speedups vary with hardware, cardinality, and data shape — treat as order-of-magnitude guidance.
Memory: data.table avoids intermediate copies; dplyr allocates at each verb.

---

## Gotchas — Reference Semantics Surprises

### `:=` mutates the original, always

```r
DT2 <- DT          # NOT a copy — DT2 and DT point to same memory
DT2[, new := 1]    # DT is also changed!

# Fix: explicit copy
DT2 <- copy(DT)
DT2[, new := 1]    # DT unchanged
```

### Functions that modify via `:=` inside a function

```r
# This silently modifies the caller's DT
bad <- function(dt) {
  dt[, x := 1]   # mutates caller's object
}

# If mutation is intentional, document it clearly
# If not, copy() at the top of the function
safe <- function(dt) {
  dt <- copy(dt)
  dt[, x := 1]
  dt
}
```

### Printing triggers duplicate first-row display

```r
DT <- data.table(x = 1:3)
DT[, y := x * 2]   # silent (by design — returns DT invisibly for chaining)
# In interactive session: no output printed after :=
# This is expected — use print(DT) or DT[] to force display
```

### `[` on a data.table column that is itself a list

```r
DT[, list_col]      # returns the list column as a list
DT[, .(list_col)]   # returns a one-column data.table
```

### `by=` uses the string name, not the column object

```r
grp_var <- "grp"
DT[, .N, by = grp_var]    # WRONG — treats "grp_var" as column name
DT[, .N, by = (grp_var)]  # WRONG still
DT[, .N, by = grp_var]    # Actually works in recent versions — but use:
DT[, .N, by = eval(grp_var)]          # explicit eval
DT[, .N, by = c(grp_var)]             # character vector form (safe)
```

### `setkey` sorts in place — existing row order is gone

```r
setkey(DT, id)    # DT is now sorted by id; original order lost
                  # use data.table::rowidv(DT) before setkey if order matters
```

### Subset with single column returns vector, not data.table

```r
DT[, val]          # vector
DT[, .(val)]       # one-column data.table — use .() to keep as DT
DT[, "val"]        # one-column data.table (character indexing returns DT)
```

---

## When to Use data.table vs dplyr

| Situation | Choose |
|---|---|
| > 1M rows, speed matters | data.table |
| Memory constrained | data.table (no copy on mutate) |
| Rolling / non-equi joins | data.table |
| Team knows dplyr, data is large | dtplyr |
| < 100k rows, readability priority | dplyr |
| Rapid exploration / prototyping | dplyr |
| Production pipeline, large data | data.table |
| Mixed team, want both | dtplyr for reads, data.table for writes |
