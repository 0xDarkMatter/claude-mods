# Tidyverse Core — dplyr / tidyr / Joins Reference

Operational reference for data manipulation with the tidyverse. Covers the pipe, tibbles, all major dplyr verbs, tidyr reshaping, and joins. Targets R 4.3+ / tidyverse 2.0+.

---

## The Pipe

```r
# Native pipe — preferred for R 4.1+
x |> f(y)          # equivalent to f(x, y)
x |> f(y) |> g(z)  # chain reads left-to-right: "then"

# Placeholder: pipe into non-first argument (R 4.2+)
mtcars |> lm(mpg ~ cyl, data = _)

# magrittr pipe — still valid, slightly more flexible
library(magrittr)
x %>% f(.)         # explicit dot placeholder
x %T>% plot()      # tee: passes x through AND calls plot(x) for side effects
x %$% cor(mpg, cyl) # expose columns directly (no $)
```

**Pipe choice decision table:**

| Situation | Use |
|---|---|
| All new code, R ≥ 4.1 | `\|>` |
| Need dot placeholder in non-first position, R < 4.2 | `%>%` |
| Side-effect step mid-pipe (print/plot without breaking chain) | `%T>%` |
| Column-access shorthand inside pipe | `%$%` |
| Package must support R < 4.1 | `%>%` |

Native `|>` has no runtime overhead; magrittr `%>%` involves a function call.

---

## Tibbles vs Data Frames

```r
library(tibble)

# Creation
tb <- tibble(x = 1:3, y = x^2)   # column refs work immediately
tb <- tribble(
  ~name, ~score,
  "A",   91,
  "B",   84
)

# Inspection
glimpse(tb)          # compact: types + first values
print(tb, n = 20)    # show more rows
View(tb)             # RStudio interactive viewer
```

**Key behavioural differences from base data.frame:**

| Behaviour | data.frame | tibble |
|---|---|---|
| Printing | All rows/cols | First 10 rows, fits screen |
| Partial column name match | Yes (`df$mp` → `mpg`) | Error |
| `[` always drops dimension | Yes → often returns vector | No → always returns tibble |
| String → factor auto-coerce | Old default | Never |
| `stringsAsFactors` | Needed to suppress | Not relevant |

---

## dplyr — Row Verbs

```r
library(dplyr)

# filter: keep rows matching conditions (& = AND, | = OR)
df |> filter(x > 5, y %in% c("a", "b"))   # comma = &
df |> filter(month == 1 | month == 2)
df |> filter(month %in% c(1, 2))           # cleaner OR for same-column

# arrange: sort rows
df |> arrange(year, month, day)
df |> arrange(desc(dep_delay))

# distinct: unique rows or unique combinations
df |> distinct()
df |> distinct(origin, dest)               # unique pairs
df |> distinct(origin, dest, .keep_all = TRUE)  # keep all cols, first occurrence

# count: shorthand for group_by + summarise(n = n())
df |> count(carrier)
df |> count(carrier, sort = TRUE)
df |> count(carrier, dest, wt = seats)    # weighted count

# slice family
df |> slice_head(n = 5)
df |> slice_tail(n = 5)
df |> slice_sample(n = 10)
df |> slice_sample(prop = 0.1)
df |> slice_min(dep_delay, n = 3)
df |> slice_max(arr_delay, n = 1, with_ties = FALSE)  # exactly 1 row

# Within groups, slice_max/min give the top-n per group:
df |>
  group_by(dest) |>
  slice_max(arr_delay, n = 1)
```

---

## dplyr — Column Verbs

```r
# select: pick or drop columns; use tidyselect helpers
df |> select(year, month, day)
df |> select(year:dep_time)
df |> select(!year:dep_time)           # negate range
df |> select(where(is.numeric))
df |> select(starts_with("dep_"), ends_with("time"))
df |> select(contains("delay"), matches("^arr"))

# rename: new = old
df |> rename(tail_num = tailnum)

# rename_with: apply function to names
df |> rename_with(toupper)
df |> rename_with(~ str_replace(.x, "dep_", ""), starts_with("dep_"))

# relocate: reorder columns
df |> relocate(time_hour, air_time)         # moves to front by default
df |> relocate(time_hour, .after = day)
df |> relocate(time_hour, .before = arr_time)

# mutate: add or modify columns (right side by default)
df |>
  mutate(
    gain = dep_delay - arr_delay,
    speed_mph = distance / air_time * 60,
    .before = 1                            # put new cols at front
  )
df |> mutate(log_price = log(price), .keep = "used")  # keep only cols used

# .keep options in mutate:
# "all"  (default) — keep all columns
# "used" — only cols that appear in mutate expressions
# "unused" — opposite of "used"
# "none" — only new cols (like transmute, now deprecated)
```

---

## across() — Multi-Column Operations

```r
# Apply function(s) to multiple columns inside mutate/summarise
df |>
  mutate(across(where(is.numeric), round, digits = 2))

df |>
  mutate(across(c(x, y, z), ~ .x / max(.x, na.rm = TRUE)))

# Named list of functions → generates name_fn columns
df |>
  summarise(across(
    where(is.numeric),
    list(mean = mean, sd = sd),
    na.rm = TRUE
  ))

# Control output names with .names
df |>
  mutate(across(starts_with("score"), ~ .x * 100, .names = "{.col}_pct"))

# c_across: for rowwise operations
df |>
  rowwise() |>
  mutate(total = sum(c_across(starts_with("score"))))
```

---

## dplyr — Grouping and Summaries

```r
# group_by + summarise: classic pattern
df |>
  group_by(carrier) |>
  summarise(
    n         = n(),
    avg_delay = mean(dep_delay, na.rm = TRUE),
    p95_delay = quantile(dep_delay, 0.95, na.rm = TRUE)
  )

# .by argument (dplyr 1.1.0+): per-operation grouping, no ungroup() needed
df |>
  summarise(
    n         = n(),
    avg_delay = mean(dep_delay, na.rm = TRUE),
    .by = carrier
  )

df |>
  mutate(rank = dense_rank(desc(dep_delay)), .by = c(origin, month))

# .groups controls residual grouping after multi-level summarise
df |>
  group_by(year, month, day) |>
  summarise(n = n(), .groups = "drop")       # fully ungrouped after
  # .groups = "drop_last" (default), "keep", "rowwise"

# Always ungroup when done with grouped work if using group_by
df |> group_by(carrier) |> mutate(...) |> ungroup()

# Useful summary functions
n()                    # row count
n_distinct(x)          # unique values
sum(x, na.rm = TRUE)
mean(x, na.rm = TRUE)
median(x, na.rm = TRUE)
first(x); last(x)      # first/last value in group
nth(x, 2)              # nth value
```

---

## tidyr — Pivoting

```r
library(tidyr)

# Tidy data rules:
# 1. Each variable → one column
# 2. Each observation → one row
# 3. Each value → one cell

# pivot_longer: wide → long (most common; column names become a variable)
df |>
  pivot_longer(
    cols         = starts_with("wk"),   # which cols to pivot
    names_to     = "week",              # new col for old col names
    values_to    = "rank",              # new col for old cell values
    values_drop_na = TRUE               # drop implicit NAs from structure
  )

# Multiple name parts → multiple name columns
df |>
  pivot_longer(
    cols      = -id,
    names_to  = c("metric", "year"),
    names_sep = "_"                    # or names_pattern = "(.+)_(\\d+)"
  )

# pivot_wider: long → wide (inverse; unique values in a column become column names)
df |>
  pivot_wider(
    id_cols      = id,
    names_from   = measurement,
    values_from  = value,
    values_fill  = 0                   # fill structural NAs
  )

# Multiple value columns
df |>
  pivot_wider(
    names_from  = year,
    values_from = c(cases, population)  # generates cases_1999, population_1999, …
  )
```

---

## tidyr — Splitting and Combining

```r
# separate_wider_delim: split on a delimiter (replaces separate())
df |>
  separate_wider_delim(
    col   = code,
    delim = "-",
    names = c("prefix", "num")
  )

# separate_wider_position: split by fixed character widths
df |>
  separate_wider_position(
    col   = code,
    widths = c(prefix = 3, num = 4)
  )

# separate_wider_regex: split by regex capture groups
df |>
  separate_wider_regex(
    col   = address,
    patterns = c(street = "[^,]+", ", ", city = ".+")
  )

# unite: combine columns into one
df |>
  unite(col = "date_str", year, month, day, sep = "-")
```

---

## tidyr — Nesting and Completeness

```r
# nest: list-column of data frames per group
nested <- df |>
  nest(data = -group_col)

# unnest: explode list-columns back out
nested |>
  unnest(data)

# unnest_wider / unnest_longer for non-df list columns
df |> unnest_wider(json_col)    # list → columns
df |> unnest_longer(tags_col)   # list → rows

# complete: make implicit missing rows explicit
df |>
  complete(year, month, fill = list(sales = 0))

# fill: carry values forward/backward (LOCF)
df |>
  fill(product, .direction = "down")   # "up", "downup", "updown"

# drop_na: remove rows with NAs in specified columns
df |> drop_na()              # any NA
df |> drop_na(x, y)         # NA in x or y only
```

---

## Joins

```r
# Mutating joins — add columns from y to x
left_join(x, y)              # all rows of x; NAs for unmatched y
inner_join(x, y)             # only matched rows
right_join(x, y)             # all rows of y; NAs for unmatched x
full_join(x, y)              # all rows from both; NAs where unmatched

# Filtering joins — filter x based on y; no new columns
semi_join(x, y)              # keep x rows that have a match in y
anti_join(x, y)              # keep x rows that have NO match in y

# Natural join (default): matches on all shared column names — usually wrong
# Always be explicit:
left_join(flights, planes, join_by(tailnum))

# join_by: explicit key specification
left_join(x, y, join_by(x_id == y_id))       # different column names
left_join(x, y, join_by(id, year == yr))      # multiple keys, mixed names

# Non-equi joins (dplyr 1.1.0+): inequality / range / rolling
# Overlap join: find all y ranges that overlap x range
left_join(x, y, join_by(overlaps(x_start, x_end, y_start, y_end)))

# Inequality join
left_join(x, y, join_by(id, x_date >= y_date))

# Disambiguate shared column names in output
left_join(flights, planes, join_by(tailnum), suffix = c("_flight", "_plane"))

# Validate keys before joining
planes |> count(tailnum) |> filter(n > 1)   # check for duplicates
planes |> filter(is.na(tailnum))            # check for NAs in key
```

**Join choice decision table:**

| Goal | Join |
|---|---|
| Enrich x with metadata from y | `left_join` |
| Keep only matched rows | `inner_join` |
| Keep all rows, both sides | `full_join` |
| Does x have a match in y? (filter only) | `semi_join` |
| What in x has no match in y? | `anti_join` |

Default to `left_join`. Use `inner_join` only when you explicitly want to drop unmatched rows.

---

## Missing Values in Manipulation Context

```r
# NA is infectious: any arithmetic with NA returns NA
mean(c(1, 2, NA))           # NA — always pass na.rm = TRUE in summaries
mean(c(1, 2, NA), na.rm = TRUE)  # 1.5

# Test for NA — never use == NA
is.na(x)
!is.na(x)
filter(df, !is.na(price))

# Replace / coerce
coalesce(x, 0)              # replace NA with fallback value
na_if(x, -99)               # treat sentinel value as NA
replace_na(x, list(col = 0)) # tidyr: per-column replacement in data frames

# NaN behaves like NA for most purposes; distinguish with:
is.nan(x)

# Implicit missing rows → explicit
df |> complete(year, qtr)   # add rows for every year×qtr combo
df |> fill(price)           # LOCF / NOCB
```

---

## Gotchas

**Pipe placeholder before R 4.2.** `x |> f(y, data = _)` requires R 4.2+. In R 4.1, use `%>%` with `.`.

**Natural joins silently join on all shared columns.** A `year` column in both tables means `join_by(year)` is implicit — and probably wrong. Always name your keys.

**`group_by()` is sticky.** Grouped data frames stay grouped through `mutate()`, `filter()`, `arrange()`. Unintended downstream effects are a common source of wrong counts. Prefer `.by =` for one-shot grouping, or always call `ungroup()` after a `group_by() |> mutate()` block.

**Multi-group `summarise()` peels the last group.** `group_by(a, b) |> summarise(...)` leaves a group on `a`. Pass `.groups = "drop"` to be explicit.

**`distinct()` drops columns by default.** `distinct(origin, dest)` drops all other columns. Use `.keep_all = TRUE` to keep the first occurrence's full row.

**`pivot_wider()` on non-unique id/name combos produces list-columns.** Verify uniqueness with `count()` first; pass `values_fn = list` intentionally if aggregation is desired.

**`separate_wider_*` supersedes `separate()`.** The old `separate()` (and `extract()`) are superseded as of tidyr 1.3.0. Prefer the typed variants: `separate_wider_delim`, `separate_wider_position`, `separate_wider_regex`.

**`slice_min/max` keeps ties by default.** `n = 1` can return more than one row when values are equal. Set `with_ties = FALSE` for a guaranteed single row.

**`across()` with named function list.** Output columns are named `{.col}_{.fn}`. Control this with `.names = "{.col}_pct"` etc. The `{.fn}` token uses the list name, so name your functions meaningfully.
