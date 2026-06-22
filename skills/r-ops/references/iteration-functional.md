# Iteration & Functional Programming in R

Modern R iteration is mostly implicit — vectorised ops, `across()`, and purrr's
`map()` family replace explicit loops in nearly every data-science context. This
reference covers the full stack: writing reusable functions, column-wise
iteration with `across()`, list iteration with purrr, and list-columns for
model-per-group workflows.

---

## Writing Functions

### Rule of three

Extract a function when you've written the same logic three times. Two copies
are tolerable; three means a function.

```r
# Pattern spotted 3× → extract
rescale01 <- function(x) {
  rng <- range(x, na.rm = TRUE, finite = TRUE)
  (x - rng[1]) / (rng[2] - rng[1])
}
```

### Argument conventions

| Convention | Rationale |
|---|---|
| Data first (`df`, `x`) | Enables pipe chaining |
| Logical flags default `FALSE` | Opt-in behaviour is safer |
| `na.rm = FALSE` to match base | Users expect base semantics |
| `...` to pass through to inner calls | Avoids re-specifying every arg |

```r
# Passing ... to inner function
cv <- function(x, na.rm = FALSE) {
  sd(x, na.rm = na.rm) / mean(x, na.rm = na.rm)
}

# Using ... for flexible pass-through
my_read <- function(path, ...) {
  readr::read_csv(path, show_col_types = FALSE, ...)
}
```

### Early return

Prefer explicit early return over nested `if`/`else` for guard clauses.

```r
process <- function(x) {
  if (length(x) == 0) return(NULL)
  if (all(is.na(x))) return(NA_real_)
  mean(x, na.rm = TRUE)
}
```

### Data-masking and `{{ }}` embracing

Functions that call dplyr verbs using column-name arguments need **embracing**.
Without `{{ }}`, dplyr interprets the argument name literally instead of
looking up what it contains.

```r
# WRONG — group_by sees "group_var" not what group_var holds
grouped_mean <- function(df, group_var, mean_var) {
  df |> group_by(group_var) |> summarize(mean(mean_var))
}

# CORRECT — {{ }} tells dplyr to look inside the argument
grouped_mean <- function(df, group_var, mean_var) {
  df |>
    group_by({{ group_var }}) |>
    summarize(mean = mean({{ mean_var }}, na.rm = TRUE), .groups = "drop")
}

diamonds |> grouped_mean(cut, carat)
```

**When to embrace:** check the docs for the two tidy-evaluation subtypes:

- **Data-masking** (`arrange`, `filter`, `mutate`, `summarize`) → embrace with `{{ }}`
- **Tidy-selection** (`select`, `relocate`, `rename`, `across`) → embrace with `{{ }}`; for
  multi-column tidy-select args passed to data-masking verbs, use `pick({{ var }})`

```r
# pick() bridges tidy-selection into data-masking context
count_missing <- function(df, group_vars, x_var) {
  df |>
    group_by(pick({{ group_vars }})) |>
    summarize(n_miss = sum(is.na({{ x_var }})), .groups = "drop")
}

flights |> count_missing(c(year, month, day), dep_time)
```

```r
# across() inside a function — embrace the column-selector argument
summarize_means <- function(df, summary_vars = where(is.numeric)) {
  df |>
    summarize(
      across({{ summary_vars }}, \(x) mean(x, na.rm = TRUE)),
      n = n(),
      .groups = "drop"
    )
}

diamonds |> group_by(cut) |> summarize_means()
diamonds |> group_by(cut) |> summarize_means(c(carat, x:z))
```

---

## Column-wise Iteration with `across()`

### Core usage

```r
# Single function — pass without ()
df |> summarize(across(a:d, median))

# Anonymous function — use \(x) shorthand (R 4.1+)
df |> summarize(across(a:d, \(x) median(x, na.rm = TRUE)))

# Multiple functions — named list, output named {.col}_{.fn}
df |> summarize(
  across(a:d, list(
    med  = \(x) median(x, na.rm = TRUE),
    miss = \(x) sum(is.na(x))
  ))
)

# Custom name template
df |> summarize(
  across(a:d, list(med = \(x) median(x, na.rm = TRUE)),
         .names = "{.fn}_{.col}")
)
```

### Column selectors for `.cols`

```r
across(everything())              # all non-grouping columns
across(where(is.numeric))        # type predicate
across(starts_with("val_"))      # name pattern
across(c(a, b, x:z))             # explicit set
across(!where(is.character))     # negation
```

### `mutate()` with `across()`

By default output columns **replace** inputs. Use `.names` to add new cols.

```r
# Replace in place (coerce NA → 0)
df |> mutate(across(a:d, \(x) coalesce(x, 0)))

# Preserve originals, add suffixed cols
df |> mutate(across(a:d, \(x) coalesce(x, 0), .names = "{.col}_filled"))
```

### Filtering variants

`across()` is awkward in `filter()`. Use dedicated helpers instead.

```r
df |> filter(if_any(a:d, is.na))   # at least one NA
df |> filter(if_all(a:d, is.na))   # all NA
```

### `across()` vs `pivot_longer()` for grouped column ops

When you need to operate on **pairs** of columns simultaneously (e.g., a value
column plus its weight column), `across()` cannot express this. Pivot first.

```r
df_paired |>
  pivot_longer(everything(),
               names_to  = c("group", ".value"),
               names_sep = "_") |>
  group_by(group) |>
  summarize(mean = weighted.mean(val, wts))
```

---

## purrr Map Family

### Anonymous function syntax (R 4.1+)

```r
# Preferred: base backslash lambda
\(x) x + 1

# Old tidyverse-only shorthand (still works but avoid in new code)
~ .x + 1
```

### `map()` and type-stable variants

`map()` always returns a list. Use typed variants for atomic output — they
fail loudly if the return type doesn't match, which catches bugs early.

```r
map(x, f)          # → list
map_lgl(x, f)      # → logical vector
map_int(x, f)      # → integer vector
map_dbl(x, f)      # → double vector
map_chr(x, f)      # → character vector
map_vec(x, f)      # → simplest atomic type (like vapply auto-detect)
```

```r
# Practical examples
files <- map(paths, readr::read_csv)          # list of data frames
medians <- map_dbl(df, \(col) median(col, na.rm = TRUE))
col_types <- map_chr(df, \(col) class(col)[1])
n_missing <- map_int(df, \(col) sum(is.na(col)))
```

### Multi-input variants

```r
# map2: two parallel inputs
map2(xs, ys, f)           # f(xs[[i]], ys[[i]])
walk2(xs, ys, f)          # same but discard output (side effects)

# pmap: arbitrary number of inputs via list
pmap(list(a = xs, b = ys, c = zs), f)

# imap: index + value
imap(x, \(val, idx) paste(idx, val))   # idx is name or position
```

```r
# walk2 for saving multiple files
walk2(by_clarity$data, by_clarity$path, write_csv)

# walk2 for saving multiple plots
walk2(
  by_clarity$path,
  by_clarity$plot,
  \(path, plot) ggsave(path, plot, width = 6, height = 6)
)
```

### Combining list of data frames

```r
# CURRENT — list_rbind / list_cbind
map(paths, read_csv) |> list_rbind()
map(paths, read_csv) |> list_cbind()

# SUPERSEDED — avoid in new code
map_dfr(paths, read_csv)   # was bind_rows(map(...))
map_dfc(paths, read_csv)   # was bind_cols(map(...))
```

### Carrying filename metadata into the combined frame

```r
paths |>
  set_names(basename) |>          # names carry through map()
  map(readxl::read_excel) |>
  list_rbind(names_to = "file") |>
  mutate(year = readr::parse_number(file))
```

### Error handling with `possibly()`

`map()` fails entirely on the first error. `possibly()` wraps a function to
return a sentinel value instead of throwing.

```r
safe_read <- possibly(\(path) readxl::read_excel(path), otherwise = NULL)

files  <- map(paths, safe_read)
data   <- list_rbind(files)              # list_rbind silently drops NULLs

failed <- map_vec(files, is.null)
paths[failed]                            # inspect which paths failed
```

### `reduce()` and `accumulate()`

```r
# reduce: fold list into single value
reduce(list(df1, df2, df3), dplyr::left_join, by = "id")
reduce(1:5, `+`)                          # → 15

# accumulate: keep intermediate values
accumulate(1:5, `+`)                      # → c(1, 3, 6, 10, 15)
```

---

## List-Columns and Model-per-Group

Nest → model → unnest is the canonical workflow for fitting many models.

```r
library(tidyverse)

nested <- mtcars |>
  group_by(cyl) |>
  nest()

# Fit a model per group
nested <- nested |>
  mutate(
    model  = map(data, \(df) lm(mpg ~ wt, data = df)),
    tidy   = map(model, broom::tidy),
    glance = map(model, broom::glance)
  )

# Extract tidy coefficients
nested |>
  select(cyl, tidy) |>
  unnest(tidy)

# Extract model-level stats
nested |>
  select(cyl, glance) |>
  unnest(glance)
```

```r
# Inspect list-column structure safely
df_types <- function(df) {
  tibble(
    col_name = names(df),
    col_type = map_chr(df, \(x) class(x)[1]),
    n_miss   = map_int(df, \(x) sum(is.na(x)))
  )
}
```

---

## Base R ↔ purrr Translation

| Base R | purrr equivalent | Notes |
|---|---|---|
| `lapply(x, f)` | `map(x, f)` | Identical semantics; purrr adds `\(x)` shorthand |
| `sapply(x, f)` | `map_vec(x, f)` | `sapply` silently simplifies — type unstable. Avoid. |
| `vapply(x, f, numeric(1))` | `map_dbl(x, f)` | Both are type-stable; purrr is terser |
| `mapply(f, x, y)` | `map2(x, y, f)` | `mapply` also exists but arg order is awkward |
| `Map(f, x, y)` | `map2(x, y, f)` | `Map` returns a list like `map2` |
| `apply(m, 1, f)` | `apply(m, 1, f)` | Row-wise on matrix — no purrr equivalent; keep base |
| `apply(m, 2, f)` | `map(as.list(df), f)` or `across()` | Column-wise on data frame → use `across()` |
| `Reduce(f, x)` | `reduce(x, f)` | purrr adds `.init`, `.right`, `.accumulate` |
| `Filter(pred, x)` | `keep(x, pred)` | `discard(x, pred)` for the inverse |
| `Find(pred, x)` | `detect(x, pred)` | Returns first match |
| `Position(pred, x)` | `detect_index(x, pred)` | Returns position of first match |

### When to prefer base

- **Package code with no tidyverse dependency** — `lapply`/`vapply` add zero imports
- **Matrix row/column ops** — `apply(m, 1, f)` has no clean purrr equivalent
- **Simple single-function map, no lambda needed** — `lapply(x, sum)` is fine

---

## Iterating Over Files

```r
# Pattern: list → map → combine
paths <- list.files("data/", pattern = "[.]csv$", full.names = TRUE)

data <- paths |>
  map(readr::read_csv, show_col_types = FALSE) |>
  list_rbind()

# With per-step transformations (prefer multiple simple maps over one complex fn)
data <- paths |>
  map(readr::read_csv, show_col_types = FALSE) |>
  map(\(df) filter(df, !is.na(id))) |>
  map(\(df) mutate(df, id = tolower(id))) |>
  list_rbind()

# Even better — bind first, then dplyr on the full frame
data <- paths |>
  map(readr::read_csv, show_col_types = FALSE) |>
  list_rbind() |>
  filter(!is.na(id)) |>
  mutate(id = tolower(id))
```

---

## Gotchas

**`sapply` is type-unstable.** It returns different types depending on the
result — a vector, a matrix, or a list. In scripts this is fine; in functions
it makes behaviour unpredictable. Use `map_dbl`/`map_chr`/`map_vec` instead.

**`walk` for side effects.** Any call whose purpose is writing to disk,
printing, or appending to a DB belongs in `walk`/`walk2`, not `map`. Using
`map` for side effects silently accumulates a large list of return values.

```r
walk(paths, \(p) append_file(p))    # not map() — we don't need the return value
```

**`map2` vs `pmap` arg matching.** `map2(x, y, f)` passes positional args
`f(x[[i]], y[[i]])`. With `pmap`, names in the list must match the function's
argument names — use a named list to be explicit.

```r
args <- list(mean = c(0, 1, 2), sd = c(1, 2, 3), n = c(10, 10, 10))
pmap(args, rnorm)    # names match rnorm's formal arguments
```

**`{{ }}` scope.** Embracing only works in functions passed to tidy-eval
verbs. It has no effect in base R or non-tidy functions, and it does nothing
outside a function body.

**`map_dfr`/`map_dfc` are superseded.** They still work but are no longer
recommended. Use `map() |> list_rbind()` / `list_cbind()` — more composable
and the name-carrying behaviour of `list_rbind(names_to=)` replaces the old
`.id` argument.

**`across()` replaces columns by default.** Inside `mutate()`, the output
names match the input names unless you set `.names`. Always set `.names` when
you want to add columns alongside originals.

**Grouped summarize message.** `summarize()` after `group_by()` emits a
message about the grouping structure unless you set `.groups = "drop"` or
`.groups = "keep"`. Suppress it explicitly in production code.

```r
df |>
  group_by(cyl) |>
  summarize(mean_mpg = mean(mpg), .groups = "drop")
```
