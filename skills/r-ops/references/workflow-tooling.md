# Workflow Tooling — Project Hygiene, Reproducibility, Environment

Operational reference for R project workflow: environment isolation,
dependency management, reproducible reports, code style, pipelines,
testing, and the base-R vs tidyverse decision.

---

## Project Structure

### RStudio / Posit Projects (`.Rproj`)

Create one project per analysis. Every `.Rproj` file sets the working
directory to its own folder on open — no manual path wrangling needed.

```r
# Start fresh:  File > New Project > New/Existing Directory in RStudio
# Or from R:
usethis::create_project("my-analysis")
```

The project root becomes `here::here()` automatically.

### Path discipline — never use `setwd()` with absolute paths

Absolute paths break on any other machine, in CI, or after a folder rename.

```r
# BAD — ties code to one machine
setwd("/Users/mack/projects/analysis")
data <- read.csv("data/raw.csv")

# GOOD — works everywhere the .Rproj exists
library(here)
data <- read.csv(here("data", "raw.csv"))
```

`here::here()` walks up the directory tree to find the project root
(`.Rproj`, `.git`, `DESCRIPTION`, `.here`). Pass path components as
separate strings; `here` handles the OS separator.

### Restart R often

Accumulated state in a live session hides bugs. Bind **Cmd/Ctrl+Shift+F10**
to "Restart R" and use it between major steps. If your script doesn't
run clean from a fresh session, it's broken.

### Do not save or restore `.RData`

The hidden `.RData` file silently reloads stale objects. Disable it globally:

```r
# In ~/.Rprofile or via Tools > Global Options in RStudio
usethis::use_blank_slate()  # sets save.defaults and restore defaults

# Equivalent manual toggle (in .Rprofile):
# RStudio GUI: Tools > Global Options > Workspace > Never save/restore
```

Set in project `.Rprofile` too if sharing with collaborators who may
have different global defaults.

---

## Dependency Management

### `renv` — project-local library

`renv` records exact package versions in a lockfile and restores them
on any machine. The gold standard for reproducible R environments.

```r
# Initialise in a new or existing project
renv::init()

# After installing or updating packages, snapshot the lockfile
renv::snapshot()

# On a collaborator's machine or in CI
renv::restore()

# Check for out-of-sync state
renv::status()
```

Key files committed to version control:

- `renv.lock` — exact versions (JSON, human-readable)
- `.Rprofile` — sources `renv/activate.R` automatically
- `renv/activate.R` — bootstraps renv on clone

`.renv/library/` goes in `.gitignore` (large, platform-specific).

### `pak` — fast, reliable installs

`pak` resolves dependencies in parallel and handles CRAN, GitHub,
Bioconductor, and local packages uniformly. Use it inside `renv`
workflows for faster installs.

```r
# Install pak (once)
install.packages("pak")

# Install from CRAN
pak::pak("dplyr")

# Install from GitHub (owner/repo)
pak::pak("tidyverse/dplyr")

# Install multiple at once
pak::pak(c("dplyr", "ggplot2", "tidyr"))

# Within renv: pak integrates transparently
options(renv.config.pak.enabled = TRUE)  # in .Rprofile
```

`pak` is faster than `install.packages()` for initial setup; `renv`
owns reproducibility; the two compose well.

---

## Reproducible Reports with Quarto

Quarto (`.qmd`) is the current standard for reproducible documents.
It supersedes R Markdown for new work while remaining compatible with
the same `knitr`/`pandoc` backend. R Markdown (`.Rmd`) is still
maintained and supported.

### Document anatomy

```yaml
---
title: "Analysis Title"
author: "Your Name"
date: today
format: html          # or pdf, docx, revealjs, dashboard, …
execute:
  echo: true
  warning: false
---
```

Code chunks use `#|` YAML-style options:

````r
```{r}
#| label: load-data
#| message: false
#| echo: false          # hide code, show output
library(tidyverse)
df <- read_csv(here::here("data", "raw.csv"))
```
````

````r
```{r}
#| label: plot-dist
#| fig-width: 8
#| fig-height: 4
#| fig-cap: "Distribution of values"
ggplot(df, aes(x = value)) + geom_histogram()
```
````

### Common chunk options

| Option | Values | Effect |
|---|---|---|
| `echo` | `true`/`false`/`fenced` | Show source code |
| `eval` | `true`/`false` | Run the chunk |
| `include` | `true`/`false` | Include output (false suppresses everything) |
| `message` | `true`/`false` | Show package messages |
| `warning` | `true`/`false` | Show warnings |
| `cache` | `true`/`false` | Cache results (invalidated on code change) |
| `fig-width` / `fig-height` | numeric (inches) | Figure dimensions |
| `label` | string (no spaces) | Chunk identifier (required for cross-refs) |

Set document-wide defaults in the YAML `execute:` block; override
per-chunk with `#|` options.

### Output formats

```bash
# CLI render
quarto render report.qmd
quarto render report.qmd --to pdf
quarto render report.qmd --to docx

# From R
quarto::quarto_render("report.qmd", output_format = "html")

# Preview with live reload
quarto preview report.qmd
```

Format | YAML `format:` value | Notes
---|---|---
HTML (default) | `html` | Self-contained with `embed-resources: true`
PDF | `pdf` | Requires LaTeX (`tinytex::install_tinytex()`)
Word | `docx` | Use reference doc for corporate styles
Slides | `revealjs` | HTML slideshow
Dashboard | `dashboard` | `shinylive` or `shiny` for interactivity
Website | `website` (in `_quarto.yml`) | Multi-page projects

### Project-level `_quarto.yml`

```yaml
project:
  type: website
  output-dir: _site

website:
  title: "My Analysis"
  navbar:
    left:
      - href: index.qmd
        text: Home
      - analysis.qmd

format:
  html:
    theme: cosmo
    toc: true
```

---

## Code Style

Follow the [tidyverse style guide](https://style.tidyverse.org). Key rules:

### Naming

```r
# snake_case for variables and functions
daily_revenue <- df |> group_by(date) |> summarise(rev = sum(amount))
compute_rate <- function(x, n) x / n

# No camelCase, no dots (dots reserved for S3 methods)
```

### Assignment

```r
x <- 10          # use <-  for assignment
mean(x = 10)     # = is fine for function arguments
```

### Spacing

```r
# Spaces around <- and binary operators (except ^ and :)
z <- (a + b)^2 / d

# Space after comma, not before
mean(x, na.rm = TRUE)

# No space before parenthesis in function calls
mean(x)           # not  mean (x)
```

### Pipes

```r
# |> (native, R >= 4.1) — prefer over magrittr %>% for new code
# space before pipe, pipe at end of line
flights |>
  filter(!is.na(arr_delay)) |>
  group_by(carrier) |>
  summarise(mean_delay = mean(arr_delay))

# Keep pipelines vertical when > 2 steps
# Break function args onto new lines when > ~80 chars
flights |>
  mutate(
    speed    = distance / air_time * 60,
    dep_hour = dep_time %/% 100
  )
```

### Tooling

```r
# Auto-format a file or selection
styler::style_file("analysis.R")
styler::style_dir("R/")      # whole directory

# Lint for style + common bugs
lintr::lint("analysis.R")
lintr::lint_dir("R/")

# RStudio: Cmd/Ctrl+Shift+P → "styler" for palette shortcuts
```

Both tools are CI-friendly:

```bash
# In CI (GitHub Actions etc.)
Rscript -e "lintr::lint_dir('R/', linters = lintr::linters_with_defaults())"
```

---

## Pipelines at Scale — `targets`

For analyses where intermediate steps are slow, `targets` gives you
Make-like dependency tracking in R: reruns only what changed.

```r
# _targets.R (project root)
library(targets)

tar_option_set(packages = c("tidyverse", "here"))

list(
  tar_target(raw_data, read_csv(here("data", "raw.csv"))),
  tar_target(clean_data, clean(raw_data)),
  tar_target(model,      fit_model(clean_data)),
  tar_target(report,     render_report(model),
             format = "file")
)
```

```r
# Run the pipeline
targets::tar_make()

# Visualise dependency graph
targets::tar_visnetwork()

# Check what's out of date
targets::tar_outdated()
```

`targets` integrates with `renv` and Quarto. Reach for it when
`source("analysis.R")` takes minutes and reruns waste your time.

---

## Testing

### `testthat` (3rd edition)

```r
# Scaffold a package or analysis project test suite
usethis::use_testthat()

# tests/testthat/test-clean.R
test_that("remove_outliers drops values beyond 3 SD", {
  x <- c(1, 2, 3, 100)
  result <- remove_outliers(x, sd_threshold = 3)
  expect_length(result, 3)
  expect_false(100 %in% result)
})

# Run all tests
devtools::test()   # inside a package
testthat::test_dir("tests/testthat/")  # standalone
```

Use `expect_snapshot()` for output that's hard to specify precisely
(regression tests on printed output, ggplot objects via `vdiffr`).

### `usethis` scaffolding

```r
usethis::create_project("my-pkg")   # analysis project
usethis::create_package("mypkg")    # R package
usethis::use_r("helpers")           # R/helpers.R + tests/testthat/test-helpers.R
usethis::use_github_actions()       # R-CMD-check / lintr CI
usethis::use_renv()                 # add renv to existing project
```

---

## Getting Help

### `reprex` — reproducible examples

Before posting a question, produce a minimal reproducible example:

```r
# Copy failing code to clipboard, then:
reprex::reprex()        # formats for GitHub/Stack Overflow
reprex::reprex(venue = "so")   # Stack Overflow formatting
reprex::reprex(venue = "slack") # Slack-friendly
```

`reprex()` runs your code in a clean session, captures output/errors,
and copies markdown to your clipboard. If it fails inside `reprex`,
your example is not self-contained — fix that first.

Include minimal data:

```r
# Inline small data with dput()
dput(head(my_df, 10))
# Paste the output into your reprex as  my_df <- <pasted output>

# Or use built-in data
reprex::reprex({
  library(dplyr)
  mtcars |> filter(cyl == 4) |> summarise(mpg = mean(mpg))
})
```

### Where to ask

| Channel | Best for |
|---|---|
| [Posit Community](https://community.rstudio.com) | Tidyverse, RStudio, Shiny, Quarto |
| Stack Overflow `[r]` | General R questions with reprex |
| GitHub Issues (package repo) | Confirmed bugs, feature requests |
| `#rstats` on Mastodon/Twitter | Community discussion |

### Reading docs efficiently

```r
?dplyr::mutate              # function docs
vignette("dplyr")           # package vignettes
browseVignettes("ggplot2")  # all vignettes in browser
# pkgdown sites: https://dplyr.tidyverse.org
```

---

## Base R vs Tidyverse — Decision Table

Both are valid. The native pipe `|>` works in either world with no
dependencies (R >= 4.1).

| Situation | Reach for | Why |
|---|---|---|
| Interactive analysis, EDA | **tidyverse** | Readable pipelines, consistent API across dplyr/tidyr/ggplot2 |
| Team projects, code review | **tidyverse** | Shared vocabulary lowers onboarding cost |
| Package development (public) | **base R** or selective imports | Minimise user-facing `Imports`; CRAN policy discourages heavy dep trees |
| Minimal-dep scripts / system tools | **base R** | No install requirements beyond R itself |
| Very large data (> memory pressure) | **data.table** | 2–10× faster than dplyr on multi-GB data; lower memory copies |
| Performance-critical inner loops | **base R** / **data.table** | Avoid tidyverse overhead in tight iteration |
| Subsetting / indexing gymnastics | **base R** `[` `[[` `$` | More expressive for non-rectangular access patterns |
| Apply-family parallelism | **base R** `lapply` / `parallel` | No extra dependency; composes with `future` |
| Everything else | **Your preference** | Mix freely — tidyverse and base R interoperate |

**Native pipe `|>` notes:**
- No `magrittr` dependency required
- Placeholder `_` (R >= 4.2): `x |> lm(y ~ ., data = _)`
- Does not support `.` as implicit first argument (magrittr feature)
- Slightly faster than `%>%` in microbenchmarks (negligible in practice)

---

## Gotchas

### Absolute paths break portability

```r
# This crashes on every other machine
read_csv("/Users/mack/Desktop/data.csv")

# Use here::here() relative to project root
read_csv(here::here("data", "raw.csv"))
```

### `.RData` persistence corrupts reproducibility

If `save.image()` or `.RData` auto-restore is on, stale objects
accumulate. Scripts that "work" in your session may fail for anyone
else. Disable at project and global level — see "Do not save `.RData`"
above.

### `library()` calls inside packages (vs scripts)

In scripts / analysis: `library(pkg)` at the top is correct.
In package code (`R/*.R`): NEVER call `library()` or `require()`.
Use `pkg::function()` (recommended) or declare in `DESCRIPTION` under
`Imports:` and call the function unqualified. `library()` in package
code modifies the user's search path silently.

```r
# Package code — correct
clean <- function(df) {
  df |> dplyr::filter(!is.na(value))
}

# Package code — wrong (affects the user's session)
library(dplyr)
clean <- function(df) df |> filter(!is.na(value))
```

### `renv` + `pak` interaction

`pak` must be enabled before `renv::init()` if you want it as the
installer. Set `options(renv.config.pak.enabled = TRUE)` in
`.Rprofile` (before `renv` sources its activation script) or in
`renv/settings.json`:

```json
{ "package.install.backend": "pak" }
```

### Quarto caching stale results

`#| cache: true` caches on code hash, but not on upstream data changes.
If your source data changes, manually bust:

```r
targets::tar_invalidate("affected_target")  # if using targets
# Or delete the _cache/ directory for the affected chunk
```

Use `cache: false` (the default) unless render time is genuinely painful.

### `here::here()` root detection order

`here` finds the root via (in priority order): `.here` file,
`DESCRIPTION`, `.Rproj`, `.git`, `.svn`. If your project has
nested git repos or unusual layouts, place an explicit `.here` file
at the true root with `here::set_here()`.

---

## Quick Reference — Key Packages

| Package | Install | Purpose |
|---|---|---|
| `here` | CRAN | Portable paths from project root |
| `renv` | CRAN | Project-local library + lockfile |
| `pak` | CRAN | Fast, unified package installer |
| `quarto` | CRAN (R pkg) + [quarto.org](https://quarto.org) CLI | Render `.qmd` from R |
| `styler` | CRAN | Auto-format R code (tidyverse style) |
| `lintr` | CRAN | Static analysis / linting |
| `targets` | CRAN | Make-like reproducible pipelines |
| `testthat` | CRAN | Unit testing (3rd edition) |
| `usethis` | CRAN | Project / package scaffolding |
| `reprex` | CRAN | Minimal reproducible examples |
| `devtools` | CRAN | Package development workflow |

```r
# Install the whole workflow toolkit at once
pak::pak(c(
  "here", "renv", "pak", "quarto",
  "styler", "lintr", "targets",
  "testthat", "usethis", "reprex", "devtools"
))
```
