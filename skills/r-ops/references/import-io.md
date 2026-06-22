# R Data Import & I/O

Comprehensive operational reference for getting data into and out of R. Covers flat files, spreadsheets, databases, columnar/big data, web sources, nested JSON, and R-native serialization.

---

## CSV & Delimited Files

### readr (tidyverse standard)

```r
library(readr)

# Basic read — prints column spec on first run, suppress with show_col_types = FALSE
df <- read_csv("data/sales.csv")

# Explicit column types — always do this in production code
df <- read_csv(
  "data/sales.csv",
  col_types = cols(
    id        = col_integer(),
    date      = col_date(format = "%Y-%m-%d"),
    amount    = col_double(),
    category  = col_character(),
    flag      = col_logical()
  ),
  na = c("", "NA", "N/A", "NULL", "-"),
  locale = locale(encoding = "UTF-8", decimal_mark = ".", grouping_mark = ",")
)

# Skip metadata rows at top
df <- read_csv("data/report.csv", skip = 3, comment = "#")

# No header row
df <- read_csv("data/raw.csv", col_names = c("x", "y", "z"))

# Semicolon-delimited (European locale where comma = decimal)
df <- read_csv2("data/european.csv")          # ; delimited, , decimal
df <- read_delim("data/file.psv", delim = "|")

# Tab-separated
df <- read_tsv("data/data.tsv")

# Write back
write_csv(df, "out/cleaned.csv")
write_csv2(df, "out/european.csv")  # semicolon, European decimal
```

Key `col_types` shortcuts: `"icdc_l"` — one char per column (i=integer, c=character, d=double, l=logical, _=skip, D=date, T=datetime).

### data.table::fread — fastest option

```r
library(data.table)

# Fastest CSV reader; auto-detects delimiter, header, encoding
dt <- fread("data/large.csv")

# Back to tibble for dplyr workflows
df <- as_tibble(fread("data/large.csv"))

# Select columns up front (avoids loading full file)
dt <- fread("data/large.csv", select = c("id", "amount", "date"))

# Parallel threads (default = all cores)
dt <- fread("data/huge.csv", nThread = 4)

# Write — also fastest
fwrite(dt, "out/output.csv")
```

Use `fread` when: file > 500 MB, speed matters, delimiter is uncertain.

### vroom — lazy/streaming alternative

```r
library(vroom)

# Lazy indexing — fast open, reads only requested columns into memory
df <- vroom("data/large.csv", col_select = c(id, amount))

# Multiple files in one call
df <- vroom(list.files("data/monthly/", full.names = TRUE))
```

`vroom` wins for multi-file ingestion and column-subset workflows on very large files.

### Multiple files — readr pattern

```r
# Read and bind many CSVs (readr >= 2.0)
df <- read_csv(list.files("data/", pattern = "\\.csv$", full.names = TRUE),
               id = "source_file")   # adds filename column
```

---

## Excel

### readxl (read)

```r
library(readxl)

# Auto-detect xls vs xlsx
df <- read_excel("data/report.xlsx")

# Specific sheet by name or index
df <- read_excel("data/report.xlsx", sheet = "Q2")
df <- read_excel("data/report.xlsx", sheet = 2)

# List all sheets
excel_sheets("data/report.xlsx")

# Named cell range (Excel range notation)
df <- read_excel("data/report.xlsx",
                 sheet  = "Sales",
                 range  = "B3:G50",
                 col_names = c("region", "q1", "q2", "q3", "q4", "total"))

# Column types: "skip", "guess", "logical", "numeric", "date", "text", "list"
df <- read_excel("data/report.xlsx",
                 col_types = c("numeric", "text", "date", "numeric"))

# NA strings
df <- read_excel("data/report.xlsx", na = c("", "N/A", "-"))
```

### writexl (write — no Java dependency)

```r
library(writexl)

# Single sheet
write_xlsx(df, "out/results.xlsx")

# Multiple sheets from named list
write_xlsx(list(summary = summary_df, detail = detail_df), "out/report.xlsx")
```

For heavy Excel work (formatting, formulas, styled output) use `openxlsx2` instead.

---

## Databases

### DBI + dbplyr (write dplyr, get SQL)

```r
library(DBI)
library(dbplyr)
library(dplyr)

# --- Connect ---
# PostgreSQL
con <- dbConnect(RPostgres::Postgres(),
                 host     = "db.example.com",
                 port     = 5432,
                 dbname   = "analytics",
                 user     = Sys.getenv("DB_USER"),
                 password = Sys.getenv("DB_PASS"))

# SQLite
con <- dbConnect(RSQLite::SQLite(), "local.sqlite")

# DuckDB (in-process, no server needed)
con <- dbConnect(duckdb::duckdb(), dbdir = "project.duckdb")
# Ephemeral (disappears on session end)
con <- dbConnect(duckdb::duckdb())

# --- Inspect ---
dbListTables(con)
dbListFields(con, "orders")

# --- Reference a table (lazy — no data fetched yet) ---
orders_db <- tbl(con, "orders")

# Write dplyr; dbplyr translates to SQL
result <- orders_db |>
  filter(year == 2024, status == "shipped") |>
  group_by(region) |>
  summarise(total = sum(amount, na.rm = TRUE)) |>
  arrange(desc(total))

# See the SQL dbplyr will run
show_query(result)

# Fetch data into R
df <- collect(result)

# --- Write to database ---
dbWriteTable(con, "clean_orders", df, overwrite = TRUE)

# --- Raw SQL when needed ---
df <- dbGetQuery(con, "SELECT * FROM orders WHERE amount > 10000")

# --- Always disconnect ---
dbDisconnect(con)
```

Backend packages by DBMS:

| DBMS | Package |
|---|---|
| PostgreSQL | `RPostgres` |
| MySQL / MariaDB | `RMariaDB` |
| SQLite | `RSQLite` |
| SQL Server | `odbc` + ODBC driver |
| BigQuery | `bigrquery` |
| DuckDB | `duckdb` |
| Snowflake | `odbc` + ODBC driver |

Never load passwords in source files — use `Sys.getenv()` or `keyring::key_get()`.

---

## Big & Columnar Data — Arrow + DuckDB

### Arrow (Parquet, larger-than-memory datasets)

```r
library(arrow)
library(dplyr)

# --- Read single Parquet file ---
df <- read_parquet("data/orders.parquet")

# Read selected columns only
df <- read_parquet("data/orders.parquet", col_select = c("id", "amount", "date"))

# --- Write Parquet ---
write_parquet(df, "out/orders.parquet")

# --- Open a multi-file dataset (Hive-partitioned or flat directory) ---
ds <- open_dataset("data/checkouts/")        # auto-detects partitioning
ds <- open_dataset("data/checkouts/", format = "parquet")
ds <- open_dataset("data/checkouts.csv", format = "csv")

# Lazy dplyr pipeline — nothing loaded yet
result <- ds |>
  filter(year == 2023) |>
  group_by(category) |>
  summarise(n = n(), total = sum(amount)) |>
  collect()   # <-- triggers computation, loads into memory

# --- Write partitioned dataset (creates directory structure) ---
df |>
  group_by(year) |>
  write_dataset("data/out/", format = "parquet")
```

Parquet vs CSV: ~2-3x smaller on disk, typed, column-oriented — always prefer it for persistent analytical data.

### DuckDB for SQL-style big data

```r
library(duckdb)
library(DBI)

con <- dbConnect(duckdb::duckdb())

# Query Parquet directly — no loading into R
df <- dbGetQuery(con, "SELECT year, SUM(amount) FROM 'data/*.parquet' GROUP BY year")

# Load CSV directly into DuckDB (faster than R round-trip)
duckdb_read_csv(con, "raw", "data/large.csv")

# Arrow <-> DuckDB bridge (zero-copy)
library(arrow)
ds <- open_dataset("data/orders/")
result <- ds |>
  to_duckdb() |>          # hand off to DuckDB engine
  filter(amount > 1000) |>
  collect()

dbDisconnect(con, shutdown = TRUE)
```

Rule of thumb: Arrow for Parquet/file-based workflows; DuckDB for complex SQL, joins across multiple sources, or when you need window functions on large data.

---

## Web: Scraping & APIs

### rvest (HTML scraping)

```r
library(rvest)

page <- read_html("https://example.com/table-page")

# CSS selectors
headings <- page |> html_elements("h2") |> html_text2()
links     <- page |> html_elements("a") |> html_attr("href")
prices    <- page |> html_elements(".price") |> html_text2()
title     <- page |> html_element("#main-title") |> html_text2()

# HTML tables — returns a list of data frames
tables <- page |> html_table()
df     <- tables[[1]]   # first table

# Navigate structure
rows <- page |>
  html_elements("table.results tr") |>
  html_elements("td") |>
  html_text2()

# Polite scraping: respect robots.txt, cache, rate-limit
# install.packages("polite")
library(polite)
session <- bow("https://example.com", force = TRUE)
page    <- scrape(session)
```

SelectorGadget browser extension is the fastest way to find CSS selectors for a target page.

### httr2 (HTTP APIs)

```r
library(httr2)

resp <- request("https://api.example.com/v2/orders") |>
  req_auth_bearer_token(Sys.getenv("API_TOKEN")) |>
  req_url_query(limit = 100, status = "shipped") |>
  req_retry(max_tries = 3) |>
  req_perform()

# Parse JSON response body
data <- resp |> resp_body_json()

# Pagination helper
resps <- request("https://api.example.com/items") |>
  req_perform_iterative(
    iterate_with_offset("page", start = 1),
    max_reqs = 20
  )
```

### jsonlite (JSON <-> R)

```r
library(jsonlite)

# Parse JSON string or file
obj  <- fromJSON('{"name":"Alice","scores":[1,2,3]}')
obj  <- fromJSON("data/payload.json")
obj  <- fromJSON("https://api.example.com/data")  # direct URL

# simplifyVector = TRUE (default) auto-converts arrays to vectors/data frames
df   <- fromJSON("data/records.json")   # works when top-level is array of objects

# Serialize R object to JSON
json <- toJSON(df, pretty = TRUE, auto_unbox = TRUE)
write(json, "out/result.json")
```

---

## Rectangling: Nested JSON/Lists into Tibbles

The tidyr trio for flattening hierarchical list-columns:

```r
library(tidyr)
library(dplyr)
library(jsonlite)

# Source: JSON with nested structure
raw <- fromJSON("data/api_response.json", simplifyVector = FALSE)
df  <- tibble(record = raw)

# unnest_wider: named list → one column per name (parallel expansion)
df |> unnest_wider(record)

# unnest_longer: unnamed list / array → one row per element (sequential expansion)
df |> unnest_longer(record)

# Combine for multi-level nesting
df |>
  unnest_wider(record) |>
  unnest_longer(items) |>
  unnest_wider(items, names_sep = "_")   # names_sep avoids collision

# hoist: pull specific fields from deep nesting without full unnest
df |>
  hoist(record,
        order_id  = "id",
        city      = list("address", "city"),
        zip       = list("address", "zip"))
```

`names_sep = "_"` in `unnest_wider` prefixes child column names with the parent name — avoids collisions when siblings share field names.

---

## R-Native Serialization

### RDS — single object, compact

```r
# Save any R object (model, list, data frame, environment...)
saveRDS(df, "cache/model.rds")
df <- readRDS("cache/model.rds")

# Compress: "gzip" (default), "bzip2", "xz" — xz smallest, slowest
saveRDS(df, "cache/model.rds", compress = "xz")
```

RDS preserves all R types exactly (factors, dates, custom classes). Not portable outside R.

### qs — fast RDS alternative

```r
library(qs)

# 3-10x faster than saveRDS, similar compression
qs::qsave(df, "cache/data.qs")
df <- qs::qread("cache/data.qs")

# Parallel compression (preset: "fast", "balanced", "high")
qs::qsave(df, "cache/data.qs", preset = "balanced", nthreads = 4)
```

Use `qs` over RDS whenever object is > 50 MB and read/write speed matters.

### Base R (avoid for new code)

```r
save(df1, df2, file = "workspace.RData")   # saves multiple objects by name
load("workspace.RData")                     # restores into current env — fragile

# Prefer saveRDS/readRDS: explicit, one object, no name injection
```

---

## Which Reader? Decision Table

| Data source | Size | Recommended | Alternative |
|---|---|---|---|
| CSV, known schema | Any | `readr::read_csv` + `col_types` | — |
| CSV, unknown schema / huge | > 500 MB | `data.table::fread` | `vroom` |
| Multiple CSVs, column subset | Any | `vroom` | `readr::read_csv(files)` |
| Excel .xlsx/.xls | Any | `readxl::read_excel` | — |
| Excel write | Any | `writexl::write_xlsx` | `openxlsx2` (formatting) |
| SQL database | Any | `DBI` + `dbplyr` | `DBI::dbGetQuery` (raw SQL) |
| Parquet / Arrow dataset | Any | `arrow::open_dataset` + `collect()` | — |
| Very large Parquet + SQL | > RAM | `duckdb` + Arrow bridge | — |
| HTML scraping | — | `rvest` + `polite` | — |
| REST API | — | `httr2` | — |
| JSON → tibble | Any | `jsonlite::fromJSON` + `tidyr::unnest_*` | — |
| R objects (persist) | < 50 MB | `saveRDS` / `readRDS` | — |
| R objects (persist, fast) | > 50 MB | `qs::qsave` / `qs::qread` | — |

---

## Gotchas

### stringsAsFactors is gone (R >= 4.0)

`base::read.csv()` used to silently convert character columns to factors (`stringsAsFactors = TRUE` was the default before R 4.0.0). **Since R 4.0, the default is `FALSE`**. Old Stack Overflow answers warning you to set `stringsAsFactors = FALSE` are stale. `readr::read_csv` never converted to factors — it always returned character columns as character.

```r
# Modern base R — no factor surprise
df <- read.csv("data/file.csv")           # stringsAsFactors = FALSE since R 4.0

# Explicit factor conversion when you actually want factors
df$category <- factor(df$category)
df$category <- factor(df$category, levels = c("low", "med", "high"))
```

### Encoding

```r
# readr: specify encoding explicitly for non-UTF-8 files
df <- read_csv("data/legacy.csv", locale = locale(encoding = "latin1"))
# or
df <- read_csv("data/file.csv", locale = locale(encoding = "Windows-1252"))

# Detect encoding first
readr::guess_encoding("data/legacy.csv")
```

Always write new files as UTF-8. If a downstream system requires a specific encoding, convert at the write step, not the read step.

### Windows path separators

```r
# Forward slashes work on Windows in R — use them
df <- read_csv("C:/Users/me/data/file.csv")   # fine
df <- read_csv("C:\\Users\\me\\data\\file.csv") # also fine but ugly

# file.path() is OS-agnostic and preferred
path <- file.path("data", "subdir", "file.csv")

# here::here() for project-relative paths (never setwd())
library(here)
df <- read_csv(here("data", "file.csv"))
```

### Column type guessing pitfalls

`readr` guesses from the first 1000 rows by default. If a column has all integers in those rows but floats later, types break silently.

```r
# Increase guess range or specify types explicitly
df <- read_csv("data/file.csv", guess_max = 10000)

# Better: specify col_types for any column you care about
df <- read_csv("data/file.csv",
               col_types = cols(amount = col_double(),
                                .default = col_guess()))
```

### NA handling

```r
# readr defaults: only "" is NA. Extend as needed.
read_csv("f.csv", na = c("", "NA", "N/A", "NULL", "none", "-", "."))

# readxl defaults: "" and =NA() formula. Same extension pattern.
read_excel("f.xlsx", na = c("", "N/A", "-"))
```

### DBI credentials

Never hardcode passwords. Use environment variables, `.Renviron`, or `keyring`:

```r
# .Renviron (per-project or user-level)
# DB_PASS=secret

con <- dbConnect(RPostgres::Postgres(),
                 password = Sys.getenv("DB_PASS"))

# Or keyring
con <- dbConnect(RPostgres::Postgres(),
                 password = keyring::key_get("mydb", "username"))
```

### collect() — don't forget it

`tbl()` and `open_dataset()` return lazy objects. Without `collect()` you have a query plan, not data.

```r
# This does nothing — just a lazy reference
orders_db <- tbl(con, "orders") |> filter(year == 2024)

# This fetches data
df <- orders_db |> collect()
```

### Parquet partition columns

When writing partitioned Parquet with `write_dataset()`, the partition column is stored in the directory name, not the file. Arrow re-attaches it on `open_dataset()`. If you convert to a plain data frame first and then write, the column is preserved in the file — choose based on downstream needs.

---

## Quick Install Reference

```r
# Core I/O stack
install.packages(c(
  "readr",        # CSV/delimited (tidyverse core)
  "data.table",   # fread/fwrite — fastest CSV
  "vroom",        # multi-file / lazy CSV
  "readxl",       # Excel read (no Java)
  "writexl",      # Excel write (no Java)
  "DBI",          # database interface
  "dbplyr",       # dplyr → SQL translation
  "RPostgres",    # PostgreSQL backend
  "RSQLite",      # SQLite backend
  "duckdb",       # DuckDB backend
  "arrow",        # Parquet + datasets
  "rvest",        # HTML scraping
  "httr2",        # HTTP / REST APIs
  "jsonlite",     # JSON parsing
  "tidyr",        # unnest_wider/longer for rectangling
  "qs",           # fast RDS alternative
  "polite",       # ethical scraping (rate-limit + cache)
  "here",         # project-relative paths
  "janitor"       # clean_names() for messy headers
))
```
