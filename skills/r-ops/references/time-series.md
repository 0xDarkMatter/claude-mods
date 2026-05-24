# Time Series Analysis in R

Modern best practice centres on the **tidyverts** ecosystem (`tsibble` + `feasts` + `fable`). The older `xts`/`zoo` pair still dominates in finance; base `ts` shows up everywhere — know it but don't start new work with it.

---

## Object Classes

### Decision Guide

| Situation | Use |
|---|---|
| New project, general forecasting | `tsibble` (tidyverts) |
| Finance data, irregular intervals, xts already in pipeline | `xts` |
| Reading legacy code / CRAN examples | `ts` (regular, fixed freq) |
| Need zoo's partial regularity | `zoo` |

### Base `ts`

```r
# Monthly data starting Jan 2020
ts_obj <- ts(values, start = c(2020, 1), frequency = 12)
time(ts_obj)        # decimal dates
cycle(ts_obj)       # 1..12 per year
window(ts_obj, start = c(2022, 1))  # subset
```

Limitation: single time index, fixed frequency, no multiple series or metadata.

### zoo / xts

```r
library(zoo)
library(xts)

# zoo: arbitrary index (Date, POSIXct, numeric)
z <- zoo(values, order.by = dates)
index(z)         # extract index
coredata(z)      # extract matrix of values

# xts: strict POSIXct index; extends zoo
x <- xts(matrix(values, ncol = 1), order.by = as.POSIXct(dates))
```

### tsibble

```r
library(tsibble)

tsbl <- as_tsibble(df, key = symbol, index = date)
# key:   grouping variable (stock ticker, store ID, …)
# index: time variable — must be a recognised temporal class
```

`tsibble` enforces no implicit gaps and requires unique (key, index) combinations. Use `fill_gaps()` to make implicit NA gaps explicit.

---

## tidyverts Modern Workflow

Four packages, one pipeline:

| Package | Role |
|---|---|
| `tsibble` | Data structure |
| `feasts` | Features, decomposition, ACF/PACF, STL |
| `fable` | Models: ARIMA, ETS, TSLM, NNETAR, MEAN, NAIVE |
| `fabletools` | `model()`, `forecast()`, `accuracy()`, `autoplot()` |

### End-to-End Skeleton

```r
library(tsibble)
library(feasts)
library(fable)
library(fabletools)
library(dplyr)

# 1. Build tsibble
tsbl <- df |>
  mutate(month = yearmonth(date)) |>
  as_tsibble(key = series_id, index = month)

# 2. Diagnostics
tsbl |> gg_season(value)          # seasonal plots
tsbl |> ACF(value) |> autoplot()
tsbl |> PACF(value) |> autoplot()

# 3. Decomposition (STL)
stl_dcmp <- tsbl |>
  model(STL(value ~ trend(window = 13) + season(window = "periodic"))) |>
  components()
autoplot(stl_dcmp)

# 4. Fit models
fit <- tsbl |>
  model(
    arima  = ARIMA(value),          # stepwise search; set stepwise=FALSE for exhaustive
    ets    = ETS(value),
    tslm   = TSLM(value ~ trend() + season()),
    nnetar = NNETAR(value)
  )

# 5. Forecast
fc <- fit |> forecast(h = "2 years")
autoplot(fc, tsbl)

# 6. Accuracy (in-sample; use stretch_tsibble for CV)
accuracy(fit)

# 7. Cross-validation accuracy
tsbl_tr <- tsbl |>
  stretch_tsibble(.init = 36, .step = 1)

fit_cv <- tsbl_tr |> model(arima = ARIMA(value))
fc_cv  <- fit_cv |> forecast(h = 12)
fc_cv |> accuracy(tsbl)
```

### Key fable Model Specs

```r
# ARIMA with forced order
ARIMA(log(value) ~ 0 + pdq(1,1,1) + PDQ(1,1,0))

# ETS with explicit method
ETS(value ~ error("A") + trend("Ad") + season("A"))

# TSLM with external regressors
TSLM(value ~ trend() + season() + xreg_column)

# Combination / ensemble
(ARIMA(value) + ETS(value)) / 2
```

### Transformations

```r
# Box-Cox inside model spec; guerrero selects lambda
fit <- tsbl |> model(ARIMA(box_cox(value, lambda = "auto")))

# log shorthand
ARIMA(log(value))
```

---

## Stationarity

### Unit Root Tests

```r
library(urca)          # preferred; more complete than tseries

# ADF — H0: unit root (non-stationary)
ur_adf <- ur.df(tsbl$value, type = "drift", selectlags = "AIC")
summary(ur_adf)        # reject H0 → stationary

# KPSS — H0: stationary
ur_kpss <- ur.kpss(tsbl$value, type = "tau")
summary(ur_kpss)       # fail to reject H0 → stationary

# Quick ndiffs / nsdiffs (fable-aware)
library(feasts)
tsbl |> features(value, list(unitroot_ndiffs, unitroot_nsdiffs))
```

### Differencing in fable

`ARIMA()` auto-determines d and D. To force:

```r
ARIMA(value ~ pdq(p, 1, q) + PDQ(P, 1, Q, period = 12))
```

Manual differencing outside of model:

```r
tsbl <- tsbl |> mutate(d_value = difference(value))
```

---

## Order Identification (ACF / PACF)

| Pattern | Interpretation |
|---|---|
| ACF cuts off at lag q, PACF tails off | MA(q) |
| PACF cuts off at lag p, ACF tails off | AR(p) |
| Both tail off | ARMA(p, q) — mixed |
| ACF decays slowly | Non-stationary — difference first |

```r
# feasts / fabletools
tsbl |> ACF(value, lag_max = 48) |> autoplot()
tsbl |> PACF(value, lag_max = 48) |> autoplot()

# Or combined
tsbl |> gg_tsdisplay(value, plot_type = "partial", lag_max = 48)
```

These give initial *estimates* for p and q — AIC/BIC comparisons across candidate models confirm.

---

## STL Decomposition

STL (Seasonal and Trend decomposition using Loess) is robust and handles multiple seasonalities.

```r
stl_fit <- tsbl |>
  model(
    STL(value ~ trend(window = 13) + season(window = "periodic"),
        robust = TRUE)           # robust = TRUE down-weights outliers
  )

components(stl_fit) |> autoplot()    # trend + seasonal + remainder
components(stl_fit) |> as_tsibble()  # access programmatically
```

For seasonally-adjusted data:

```r
components(stl_fit) |>
  mutate(sa = value - season_year) |>
  autoplot(sa)
```

---

## xts Essentials

Use when data arrives as xts (from quantmod, tidyquant, Bloomberg, etc.).

### Core Operations

```r
library(xts)

# Subset by ISO string
x["2023"]              # full year
x["2023-06/2023-12"]   # range
x["2023-06/"]          # open-ended from

# Period aggregation
apply.monthly(x, colMeans)
apply.quarterly(x, sum)
to.period(x, "months", OHLC = FALSE)  # open/high/low/close columns if TRUE

# Rolling window
rollapply(x, width = 20, FUN = mean, align = "right")  # see Gotchas
rollapply(x, width = 20, FUN = sd,   align = "right", fill = NA)

# Merge (outer join; fills with NA)
merged <- merge(x1, x2)            # union of dates
merged <- merge(x1, x2, join = "inner")

# Fill missing
na.locf(x)             # carry last observation forward
na.locf(x, fromLast = TRUE)  # carry next observation backward
na.approx(x)           # linear interpolation

# Endpoints (index positions of period boundaries)
ep <- endpoints(x, on = "months")
period.apply(x, ep, mean)
```

### Convert to/from tibble

```r
library(tibble)
library(dplyr)

df  <- as_tibble(fortify.zoo(x), rownames = "date")
xts_out <- xts(df |> select(-date), order.by = as.POSIXct(df$date))
```

---

## Package Notes

| Package | Status | Notes |
|---|---|---|
| `fable` | **Active** | Tidyverts flagship; supersedes `forecast` for new work |
| `feasts` | **Active** | Feature extraction, decomposition, diagnostics |
| `forecast` | Maintenance | `auto.arima()` still works; no new features. Migrating: `auto.arima(x)` → `model(ARIMA(x))` |
| `prophet` | Active (Meta) | Good for business series with holidays, multiple seasonalities; less statistically principled |
| `xts` / `zoo` | Stable | Finance standard; will not disappear |
| `timetk` | Active | Bridge: xts ↔ tibble, visualisation, anomaly detection |

---

## Gotchas

### xts lag — `k=+1` LEADS, not lags

```r
# This is a LEAD (shifts values forward, i.e., tomorrow's price today)
lag(x, k = 1)

# This is a LAG (shifts values backward — what most people want)
lag(x, k = -1)
# Equivalent:
lag.xts(x, k = -1)
```

**Mnemonic:** xts `lag` matches `stats::lag` convention — positive k shifts the *time axis* forward, which means values appear earlier in the output. The opposite of dplyr `lag()`.

### rollapply default alignment is "center" — uses future data

```r
# WRONG for real-time or backtesting contexts:
rollapply(x, width = 20, FUN = mean)                    # align = "center" (default)

# CORRECT — only uses past data:
rollapply(x, width = 20, FUN = mean, align = "right")
```

Center alignment is mathematically valid for smoothing historical data for display, but will cause look-ahead bias in any model or backtest. Always set `align = "right"` explicitly.

### tsibble implicit gaps

```r
# Implicit NA dates are silently dropped unless you fill them
tsbl |> has_gaps()           # TRUE/FALSE per key
tsbl |> fill_gaps()          # inserts NA rows for missing periods
tsbl |> fill_gaps(value = 0) # inserts 0 instead
```

### ARIMA in fable is stochastic

`ARIMA()` with `stepwise = TRUE` (default) uses a heuristic search — results can vary between runs. Set `stepwise = FALSE, approximation = FALSE` for fully deterministic exhaustive search (slower).

```r
model(ARIMA(value, stepwise = FALSE, approximation = FALSE))
```

### Forecast horizon `h` string parsing

`fable` accepts human-readable strings:

```r
forecast(h = "2 years")    # resolved against tsibble index frequency
forecast(h = 24)            # 24 periods (safer — unambiguous)
```

String form requires the tsibble index to be a `yearmonth`, `yearquarter`, or similar lubridate-aware class.

---

## Quick-Reference Cheatsheet

```r
# Object creation
ts(x, start, frequency)
as_tsibble(df, key, index)
xts(matrix, order.by = dates)

# Diagnostics
gg_tsdisplay(value, plot_type = "partial")
ACF() |> autoplot()
PACF() |> autoplot()
gg_season()
features(value, list(unitroot_ndiffs, feat_stl))

# Model + forecast
model(ARIMA(y), ETS(y)) |> forecast(h = 24) |> autoplot()
accuracy(fit)

# STL
model(STL(y)) |> components() |> autoplot()

# xts
apply.monthly(x, mean)
rollapply(x, 20, mean, align = "right")
lag(x, k = -1)      # actual lag
na.locf(x)
x["2023-01/2023-06"]
```
