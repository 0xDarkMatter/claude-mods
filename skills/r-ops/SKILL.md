---
name: r-ops
description: "Modern R for data analysis and statistics — tidyverse-first (dplyr, tidyr, ggplot2, native |> pipe), with base R and data.table as alternatives. Triggers on: R, Rstats, tidyverse, dplyr, tidyr, ggplot2, pivot/join/group, data.table, purrr map, broom, renv, Quarto."
when_to_use: "Use for any R question — wrangling, visualization, modeling, time series — or when reviewing/modernizing R code to current (2024+) idioms."
license: MIT
compatibility: "R >= 4.1 (native |> pipe); tidyverse 2.0; Quarto"
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: "sql-ops, postgres-ops, python-database-ops"
---

# Modern R Operations

A tidyverse-first, current-best-practice reference for working in R (2024+): data analysis, statistics, visualization, and reproducible workflow. Opinionated where the community has converged, with base R and `data.table` flagged as the right tool when they are.

## The modern R stack at a glance

| Job | Reach for | Not (anymore) |
|-----|-----------|---------------|
| Pipe | native `\|>` (R 4.1+) | `%>%` only when you need its placeholder/`.` features |
| Data frame | `tibble` | `data.frame` defaults (but it's fine) |
| Wrangle | `dplyr` + `tidyr` | hand-rolled `[`, `subset`, `aggregate` |
| Read CSV | `readr::read_csv` (prod), `data.table::fread` (speed) | `read.csv` |
| Excel / Parquet / DB | `readxl` / `arrow` / `DBI`+`dbplyr` | — |
| Strings / dates / factors | `stringr` / `lubridate` / `forcats` | base `grepl`/`POSIXlt`/`factor` juggling |
| Plot | `ggplot2` | base graphics (fine for throwaway plots) |
| Iterate | `purrr::map_*` + `across()` | `sapply` (type-unstable); `lapply` ok in package code |
| Big / fast | `data.table` (or `dtplyr`, `arrow`+`duckdb`) | — |
| Model | base `lm`/`glm` + `broom`; `tidymodels` for CV/tuning | `caret` |
| Time series | `tsibble` + `fable` | `forecast::auto.arima` (maintenance-only) |
| Reports | Quarto (`.qmd`) | R Markdown (still works) |
| Reproducibility | `renv` + Projects + `here()` | `setwd()`, saving `.RData` |

## The analysis workflow (and where each reference lives)

```
import → tidy → transform → visualize → model → communicate
```

1. **Import** — get data in: [import-io.md](references/import-io.md)
2. **Tidy & transform** — the dplyr/tidyr core: [tidyverse-core.md](references/tidyverse-core.md)
3. **Clean types** — strings, dates, factors: [strings-dates-factors.md](references/strings-dates-factors.md)
4. **Iterate** — map over many things, list-columns: [iteration-functional.md](references/iteration-functional.md)
5. **Visualize** — ggplot2 + EDA: [visualization.md](references/visualization.md)
6. **Model** — tests, lm/glm, broom, tidymodels: [modeling-stats.md](references/modeling-stats.md)
7. **Scale up** — when dplyr is too slow: [data-table.md](references/data-table.md)
8. **Time series** — tsibble/fable, xts: [time-series.md](references/time-series.md)
9. **Ship it** — projects, renv, Quarto, testing: [workflow-tooling.md](references/workflow-tooling.md)

Open the reference for the task at hand — they load on demand. For broad orientation, this file is enough.

## Core idioms (internalize these)

```r
library(tidyverse)

# The native pipe threads a value into the first argument.
diamonds |>
  filter(carat > 0.5) |>
  mutate(price_per_carat = price / carat) |>
  summarise(
    mean_ppc = mean(price_per_carat),
    n = n(),
    .by = cut                      # per-operation grouping (dplyr 1.1+)
  ) |>
  arrange(desc(mean_ppc))

# across() applies one op to many columns
df |> summarise(across(where(is.numeric), \(x) mean(x, na.rm = TRUE)))

# map over a list/vector, type-stable; combine results
files |> map(read_csv) |> list_rbind(names_to = "source")

# ggplot: data + aesthetic mapping + layered geoms
ggplot(df, aes(x = displ, y = hwy, colour = class)) +
  geom_point() +
  geom_smooth(method = "lm")
```

## Decision shortcuts

**Grouping**: prefer per-operation `.by =` over `group_by() |> ... |> ungroup()` — it avoids sticky-group bugs.

**Joins**: always write `join_by(...)` explicitly. Natural joins on shared names are almost always wrong on real data.

**Which CSV reader?** `read_csv` (readable, good defaults, production) · `fread` (fastest, big files) · `vroom` (many files, column subset).

**dplyr or data.table?** dplyr for readability and teams; data.table (or `dtplyr`) when profiling says dplyr is the bottleneck or data is large. `arrow`+`duckdb` for larger-than-memory.

**lm or tidymodels?** Base `lm`/`glm` is the right default — reach for tidymodels only when you need cross-validation, tuning, or uniform multi-model comparison.

**base R or tidyverse?** Tidyverse for analysis, readability, teams. Base R (or data.table) for package development, minimal-dependency scripts, and performance-critical inner loops. The `|>` pipe is base and dependency-free — use it everywhere.

## High-value gotchas

These bite people repeatedly — full detail in the referenced files:

- **`stringsAsFactors` is `FALSE` since R 4.0** (2020). Old advice warning about automatic factor conversion on import is stale and sometimes backwards. (import-io)
- **`predict(glm_model, type = "response")`** for probabilities — the default returns link-scale (log-odds). (modeling-stats)
- **`cor.test()`, not `cor()`** when you care whether a correlation is real. (modeling-stats)
- **`sapply` is type-unstable** — never in function bodies; use a typed `map_*`. (iteration-functional)
- **`map_dfr`/`map_dfc` are superseded** → `map() |> list_rbind()` / `list_cbind()`. (iteration-functional)
- **ggplot mapping vs setting**: `aes(colour = class)` maps a variable; `colour = "blue"` sets a constant. Putting a constant inside `aes()` is the #1 ggplot mistake. (visualization)
- **`coord_cartesian(ylim=)` zooms; `scale_y_continuous(limits=)` drops data** — the latter silently corrupts smooths/boxplots. (visualization)
- **Factor order is not cosmetic** — it sets ggplot axis/legend order and regression reference levels. `fct_reorder` for plots, `fct_relevel` for models. (strings-dates-factors)
- **lubridate periods vs durations**: `months(1)` (calendar) vs `dmonths(1)` (fixed seconds); use `%m+%` for safe month-end arithmetic. (strings-dates-factors)
- **`data.table` `:=` mutates in place** — `DT2 <- DT` is not a copy; use `copy(DT)`. (data-table)
- **xts `lag(k = +1)` *leads*** (future data); use `k = -1`. `rollapply` defaults to center alignment — set `align = "right"` to avoid look-ahead bias. (time-series)
- **Never `setwd()` with an absolute path** — use an RStudio Project + `here::here()`. Don't save/restore `.RData`. (workflow-tooling)

## Currency note

Reflects the R ecosystem as of 2024–2026: R ≥ 4.3, tidyverse 2.0, native `|>`, dplyr `.by=`, the `\(x)` lambda, `list_rbind`/`list_cbind`, the tidyverts (tsibble/fable) time-series stack, and Quarto. Where a once-standard approach has been superseded (base apply → purrr, `forecast` → fable, R Markdown → Quarto, `map_dfr` → `list_rbind`), the modern form leads and the older one is noted for when you encounter it in the wild.

This currency is **verified, not asserted** — [`scripts/check-r-facts.py`](scripts/check-r-facts.py) guards it against silent drift:

```bash
# Structural (PR CI, no network): every CRAN package in the catalog is still
# named in this skill's prose, and the currency note still carries a year.
python scripts/check-r-facts.py --offline        # exit 0 consistent, 10 drift

# Live (weekly freshness job, never blocks a PR): every recommended package
# still resolves on CRAN.
python scripts/check-r-facts.py --live            # exit 10 a package is gone, 7 CRAN unreachable
```

The canonical package list lives in [`assets/r-packages.json`](assets/r-packages.json); when you add or drop a recommendation, update it to match or `--offline` fails CI.
