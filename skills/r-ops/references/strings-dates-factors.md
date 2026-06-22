# Strings, Dates, and Factors — Modern R Reference

The three tidyverse packages that replace the clunkiest parts of base R:
**stringr** for strings, **lubridate** for dates/times, **forcats** for
categoricals. All three are core tidyverse as of tidyverse 2.0.

```r
library(tidyverse)  # loads all three
```

---

## 1. Strings and Regular Expressions (stringr)

Every stringr function starts with `str_`. That prefix-consistency is
intentional — in RStudio, typing `str_` triggers autocomplete over the
full function set.

### Building strings

```r
# Concatenation — tidyverse-safe paste0()
str_c("Hello ", c("Ana", "Bob"))           # vectorises, NA propagates
str_c("a", "b", "c", sep = "-")            # "a-b-c"

# Interpolation — cleaner for templates
str_glue("Hello {name}, you are {age}!")   # {expr} is evaluated in scope
str_glue_data(df, "Row {row_number()}: {col}")

# Base equivalents (avoid in new code):
# paste0() / paste() / sprintf()
```

Raw strings avoid backslash hell (R >= 4.0):

```r
r"(C:\Users\name\file.txt)"   # no escaping needed
r"[He said "yes"]"            # bracket delimiter if content has )]
```

### Detecting and counting

```r
str_detect(x, pattern)        # logical vector; pairs with filter()
str_which(x, pattern)         # integer positions
str_subset(x, pattern)        # returns matching strings
str_count(x, pattern)         # count matches per element
```

```r
# Use sum/mean with str_detect for aggregates
sum(str_detect(words, "^[aeiou]"))          # how many start with vowel
mean(str_detect(words, "ing$"))             # proportion ending in "ing"
```

### Extracting

```r
str_extract(x, pattern)       # first match per string (NA if none)
str_extract_all(x, pattern)   # list of all matches per string
str_sub(x, start, end)        # positional slice; negative = from end
```

```r
str_extract("2024-05-01", "\\d{4}")         # "2024"
str_extract_all("a1 b2 c3", "\\d")          # list: c("1","2","3")
str_sub("Hello", 1, 3)                      # "Hel"
str_sub("Hello", -3, -1)                    # "llo"
```

### Replacing and splitting

```r
str_replace(x, pattern, replacement)        # first match
str_replace_all(x, pattern, replacement)    # all matches

str_split(x, pattern)                       # returns list
str_split_fixed(x, pattern, n)             # returns matrix (n cols)
str_split_i(x, pattern, i)                 # extract i-th piece (vectorised)
```

```r
str_replace_all("aabbcc", "[bc]", "X")     # "aaXXXX"
str_replace_all(x, c("a" = "1", "b" = "2")) # named vector = multiple rules

str_split_i("2024-05-01", "-", 2)          # "05"
```

### Padding, trimming, case

```r
str_pad(x, width, side = "left", pad = " ")   # pad to minimum width
str_trim(x, side = "both")                    # strip whitespace
str_squish(x)                                 # trim + collapse internal spaces

str_to_lower(x)
str_to_upper(x)
str_to_title(x)                               # Title Case
str_to_sentence(x)                            # Sentence case
```

### Regex syntax in R

Patterns are PCRE (Perl-compatible) by default. Key elements:

| Pattern | Meaning |
|---------|---------|
| `.` | Any character except `\n` |
| `^` / `$` | Start / end of string |
| `[abc]` | Character class |
| `[^abc]` | Negated class |
| `\d` / `\D` | Digit / non-digit |
| `\w` / `\W` | Word char / non-word |
| `\s` / `\S` | Whitespace / non-whitespace |
| `a?` | 0 or 1 of `a` |
| `a+` | 1 or more |
| `a*` | 0 or more |
| `a{3}` / `a{2,4}` | Exact / range count |
| `(abc)` | Capturing group |
| `(?:abc)` | Non-capturing group |
| `\1` | Backreference to group 1 |
| `a\|b` | Alternation |

In R strings, `\` must be doubled: to match a literal dot write `"\\."`,
to match `\d` write `"\\d"`. Raw strings sidestep this:

```r
str_detect(x, r"(\d{4}-\d{2}-\d{2})")    # ISO date pattern, no doubling
```

### Modifier functions

Pass these instead of a plain string to tune matching:

```r
# Case-insensitive
str_detect(x, regex("hello", ignore_case = TRUE))

# Multiline — ^ and $ match line boundaries
str_extract(x, regex("^\\w+", multiline = TRUE))

# Literal matching — disables all metacharacters
str_detect(x, fixed("a.b.c"))            # matches the literal string

# Word boundary (shorthand)
str_detect(x, boundary("word"))
```

### Useful patterns

```r
# Extract email-like tokens
str_extract_all(text, "[\\w.+-]+@[\\w-]+\\.[\\w.]+")

# Strip HTML tags
str_remove_all(html, "<[^>]+>")

# Capture and reuse groups
str_replace(x, "(\\w+) (\\w+)", "\\2 \\1")  # swap first two words

# Normalise whitespace
str_squish(str_to_lower(x))
```

### Base R equivalents (for reading legacy code)

| base | stringr |
|------|---------|
| `grepl(pat, x)` | `str_detect(x, pat)` |
| `grep(pat, x)` | `str_which(x, pat)` |
| `sub(pat, rep, x)` | `str_replace(x, pat, rep)` |
| `gsub(pat, rep, x)` | `str_replace_all(x, pat, rep)` |
| `regmatches(x, regexpr(...))` | `str_extract(x, pat)` |
| `substr(x, s, e)` | `str_sub(x, s, e)` |
| `paste0(...)` | `str_c(...)` |

---

## 2. Dates and Times (lubridate)

Base R's `as.Date()` / `as.POSIXct()` / `as.POSIXlt()` work but are
inconsistent. lubridate wraps them with a uniform interface and handles
the common traps automatically.

### Parsing from strings

Name the parser after the order of components in your data:

```r
ymd("2024-05-01")                    # "2024-05-01" <date>
mdy("05/01/2024")                    # same result
dmy("01-May-2024")                   # same result
ymd_hms("2024-05-01 14:30:00")       # <dttm>
ymd_hm("2024-05-01 14:30")
mdy_hms("01/05/2024 2:30pm")         # AM/PM parsed automatically
```

These functions are flexible — they handle separators, ordinals (`31st`),
abbreviated and full month names. They return `NA` with a warning for
unparseable input rather than throwing an error.

### From components

```r
make_date(year = 2024, month = 5, day = 1)
make_datetime(year, month, day, hour, minute, second, tz = "UTC")

# From numeric Unix epoch
as_datetime(1714521600)          # seconds since 1970-01-01 UTC
as_date(19843)                   # days since 1970-01-01
```

### Accessors (get and set)

```r
x <- ymd_hms("2024-05-01 14:30:45")
year(x)      # 2024
month(x)     # 5
month(x, label = TRUE)   # May (ordered factor)
day(x)       # 1
wday(x)      # 4 (1 = Sunday by default)
wday(x, label = TRUE, abbr = FALSE)  # "Wednesday"
yday(x)      # day of year: 122
hour(x)      # 14
minute(x)    # 30
second(x)    # 45

# Setters use the same functions on the left-hand side
year(x) <- 2025
month(x) <- 12
```

### Rounding

```r
floor_date(x, unit = "month")     # first instant of the month
ceiling_date(x, unit = "week")    # first instant of next week
round_date(x, unit = "hour")      # nearest hour

# Common units: "second", "minute", "hour", "day", "week", "month",
#               "bimonth", "quarter", "halfyear", "year"
```

Useful for binning time series:

```r
df |> mutate(week = floor_date(ts, "week")) |> count(week)
```

### Time spans

lubridate has three distinct span types:

| Type | Class | Definition |
|------|-------|------------|
| Duration | `dseconds()` etc | Fixed number of seconds |
| Period | `seconds()` etc | Calendar-aware (months, years) |
| Interval | `interval()` / `%--%` | A specific span between two instants |

```r
# Durations — always exact seconds
ddays(1)              # 86400s regardless of DST
dhours(3) + dminutes(30)

# Periods — calendar-friendly
days(1)               # "1 day" — may be 23/24/25 hours across DST
months(1) + years(2)
ymd("2024-01-31") + months(1)   # "2024-02-29" (lubridate clips to valid date)

# Intervals — for "how long between these two instants"
start %--% end
as.duration(start %--% end)
as.period(start %--% end)
int_length(start %--% end)    # seconds
```

Choose **periods** when you mean "one calendar month later". Choose
**durations** when you mean "86400 seconds later" (physics/scheduling).

### Time zones

```r
now(tzone = "Australia/Sydney")

# Change display without changing the instant
with_tz(x, "America/New_York")

# Change the instant, keep the clock reading (dangerous — use rarely)
force_tz(x, "Europe/London")

# List valid zone names
OlsonNames()
```

### Base R contrast

```r
# Base: parsing is format-sensitive and error-prone
as.Date("01/05/2024", format = "%d/%m/%Y")   # must specify format exactly
as.POSIXct("2024-05-01 14:30", tz = "UTC")

# Base POSIXlt is a list — common traps:
lt <- as.POSIXlt("2024-05-01")
lt$year   # 124, not 2024 — stored as years since 1900
lt$mon    # 4, not 5 — 0-based months (0 = January)

# lubridate spares you both traps:
year(ymd("2024-05-01"))   # 2024
month(ymd("2024-05-01"))  # 5
```

---

## 3. Categorical Variables (forcats)

Factors in base R encode categorical variables as integer codes with a
`levels` attribute. The coding determines sort order in plots and the
reference level in models — so getting it right matters.

### Creating factors

```r
# Base — silently converts unknowns to NA
factor(x, levels = c("low", "med", "high"))

# forcats::fct() — errors on unknown levels (safer)
fct(x, levels = c("low", "med", "high"))

# Ordered factor for ordinal data
factor(x, levels = c("low", "med", "high"), ordered = TRUE)
```

### Reordering levels

```r
# Reorder by another numeric variable (plots, not models)
fct_reorder(f, x)                   # order f levels by median of x
fct_reorder(f, x, .fun = mean)      # use mean instead
fct_reorder2(f, x, y)               # for line plots: order by y at max x

# Move specific levels to the front
fct_relevel(f, "Other", "NA")       # put these first, rest unchanged
fct_relevel(f, "last_level", after = Inf)  # move to end

# Most frequent first
fct_infreq(f)
fct_inorder(f)                      # by first appearance in data
```

```r
# Canonical ggplot pattern
df |>
  mutate(cat = fct_reorder(cat, value)) |>
  ggplot(aes(x = value, y = cat)) +
  geom_col()
```

### Recoding level values

```r
# Rename individual levels
fct_recode(f,
  "United States" = "US",
  "United Kingdom" = "GB"
)

# Collapse multiple levels into one
fct_collapse(f,
  anglo = c("US", "GB", "AU", "CA"),
  other = c("FR", "DE", "JP")
)

# Lump rare levels together
fct_lump_n(f, n = 5)            # keep top 5 by frequency, rest → "Other"
fct_lump_prop(f, prop = 0.05)   # keep levels covering >= 5% of data
fct_lump_min(f, min = 10)       # keep levels with at least 10 obs
fct_other(f, keep = c("A","B")) # explicit keep-list, rest → "Other"
```

### Dropping and adding levels

```r
fct_drop(f)                     # remove levels with 0 observations
fct_expand(f, "new_level")      # add a level without adding data
fct_explicit_na(f, na_level = "(Missing)")  # make NA a visible level
```

### Why level order matters

**Plots**: ggplot uses factor level order for axis order and legend order.
The default (alphabetical) is almost never what you want for bar/lollipop
charts.

**Models**: `lm()`, `glm()`, etc. treat the first level as the reference
category. Changing the level order changes the intercept and coefficient
interpretation.

```r
# Set reference level for modelling
f <- fct_relevel(f, "control")  # "control" becomes the baseline
```

---

## Gotchas

**stringr**
- `str_extract()` returns `NA` for no-match, not `""`. Check with `!is.na()`.
- In regex strings, `\` must be doubled: `\\d`, `\\s`, `\\.`. Use raw strings `r"(...)"` to avoid this.
- `str_replace_all()` with a named vector applies rules left-to-right; overlapping replacements may interact unexpectedly.
- `str_split()` returns a list. Use `str_split_fixed()` or `str_split_i()` for rectangular output.
- `str_c()` with `NA` returns `NA`; use `coalesce(x, "fallback")` before concatenating if NAs should be treated as empty.

**lubridate**
- `months(1)` (period) vs `dmonths(1)` (duration = 30.44 days average). Adding periods to dates is usually what you want; adding durations can produce fractional days.
- `ymd("2024-01-31") + months(1)` returns `"2024-02-29"` (valid leap year date) but `ymd("2023-01-31") + months(1)` returns `NA` — February 31 does not exist. Use `%m+%` for roll-forward: `ymd("2023-01-31") %m+% months(1)` → `"2023-02-28"`.
- DST gaps: `force_tz()` on a non-existent local time (e.g. the clocks-forward hour) returns `NA`. Use `with_tz()` to shift display instead.
- `as.numeric(date)` gives days since 1970-01-01 for `<date>`, seconds since epoch for `<dttm>`. Always explicit-convert via `as.integer()` or `int_length()`.
- Base `POSIXlt$year` is years-since-1900 and `$mon` is 0-based. Never access POSIXlt slots directly in new code.

**forcats**
- `factor(x)` with an unexpected value silently produces `NA` in the result. Use `fct()` when you want an error instead.
- `fct_lump_n(f, n)` keeps the top `n` by frequency and lumps the rest into `"Other"`. If ties exist at position `n`, behavior is deterministic but may be surprising — inspect with `fct_count(f)` first.
- `fct_reorder()` is for visualisation only; it does not control model reference levels. Use `fct_relevel()` for that.
- Dropping unused levels after filtering: `droplevels(df$col)` or `fct_drop(col)` — forgetting this leaves empty bars in ggplot.
- `as.integer(factor_var)` gives the internal code (1-based level index), not the original value. To recover the label: `levels(f)[as.integer(f)]`.
