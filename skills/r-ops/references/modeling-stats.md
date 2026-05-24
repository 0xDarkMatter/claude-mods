# Statistics & Modeling in R

From base inferential tests through tidymodels. Use base R lm/glm for
straightforward regression; reach for tidymodels when you need CV,
hyperparameter tuning, or multiple competing model types.

---

## 1. Inferential Tests (base R)

### Reading a p-value

`p` = P(observing data this extreme | null is true). It is **not**
P(null is true | data). α = 0.05 is convention, not law. Report effect
sizes and confidence intervals alongside p-values.

### Normality check

```r
shapiro.test(x)          # H0: data are normal; n < 5000 only
qqnorm(x); qqline(x)     # Q-Q plot: fat tails / skew visible at a glance
```

Shapiro-Wilk loses power at small n and is over-powered at large n —
always pair it with a Q-Q plot.

### One- and two-sample t-tests

```r
# One-sample
t.test(x, mu = 0)

# Two-sample unpaired (Welch by default — no equal-variance assumption)
t.test(y ~ group, data = df)
t.test(a, b)                    # same thing, vectors

# Paired (measurements are linked row-by-row)
t.test(before, after, paired = TRUE)

# One-sided
t.test(x, mu = 0, alternative = "greater")
```

`paired = TRUE` matters: paired reduces noise by removing between-subject
variance. Using unpaired on paired data inflates the SE and loses power.

### Non-parametric alternatives

```r
wilcox.test(y ~ group, data = df)          # Mann-Whitney U (two-sample)
wilcox.test(before, after, paired = TRUE)  # Wilcoxon signed-rank

# The estimate returned is the Hodges-Lehmann pseudomedian,
# NOT the sample median. Don't report it as the median.
wilcox.test(x, conf.int = TRUE)$estimate   # pseudomedian
```

### Proportions & distributions

```r
prop.test(c(successes_a, successes_b), c(n_a, n_b))  # two-proportion z-test
prop.test(x = 42, n = 100, p = 0.5)                  # one-sample vs H0

ks.test(x, "pnorm", mean(x), sd(x))  # K-S goodness-of-fit
ks.test(x, y)                         # two-sample distributional equality
```

### Correlation

```r
cor(x, y)                          # point estimate only — no CI, no p
cor.test(x, y)                     # CI + p-value; method = "pearson"|"spearman"|"kendall"
cor.test(x, y, method = "spearman")
```

Always use `cor.test`, not bare `cor`, when you want inference.

### Chi-square & Fisher

```r
tbl <- table(df$var1, df$var2)
chisq.test(tbl)                    # assumes expected counts ≥ 5
fisher.test(tbl)                   # exact; use when counts are small
```

### ANOVA

```r
m <- aov(score ~ group, data = df)
summary(m)               # F stat and p-value
TukeyHSD(m)              # post-hoc pairwise with family-wise correction

# Non-parametric equivalent
kruskal.test(score ~ group, data = df)
```

### Multiple comparisons

```r
pairwise.t.test(df$score, df$group, p.adjust.method = "holm")
# "holm" is uniformly more powerful than Bonferroni; use it by default.
# "BH" (Benjamini-Hochberg) for FDR control in high-throughput settings.
p.adjust(p_vec, method = "holm")   # adjust a vector of raw p-values
```

---

## 2. Linear Models

### Formula operators

| Operator | Meaning |
|----------|---------|
| `y ~ x` | regress y on x |
| `y ~ x1 + x2` | additive main effects |
| `y ~ x1 : x2` | interaction only |
| `y ~ x1 * x2` | main effects + interaction (shorthand for `x1 + x2 + x1:x2`) |
| `y ~ (x1 + x2)^2` | all two-way interactions among x1, x2 |
| `y ~ I(x^2)` | arithmetic inside formula (raw squaring) |
| `y ~ poly(x, 2)` | orthogonal polynomial (prefer over `I(x^2)`) |
| `y ~ .` | all remaining columns as predictors |
| `y ~ . - z` | all minus z |

### Fitting and reading summary

```r
m <- lm(mpg ~ wt + hp, data = mtcars)
summary(m)
```

Read `summary()` in order:

1. **F-statistic & p-value** (bottom) — does the model beat a flat mean?
2. **Adjusted R²** — variance explained, penalised for complexity
3. **Coefficients table** — estimate, SE, t-value, p-value per term
4. **Residual standard error** — typical prediction error in y-units

```r
confint(m)               # 95% CIs on coefficients
coef(m)                  # named vector of estimates
fitted(m)                # ŷ for training data
residuals(m)             # raw residuals
```

### Diagnostics

```r
par(mfrow = c(2, 2))
plot(m)
# Panel 1: Residuals vs Fitted — non-linearity shows as curve
# Panel 2: Q-Q of residuals — normality of errors
# Panel 3: Scale-Location — heteroscedasticity (fanning)
# Panel 4: Cook's distance — influential observations (> 0.5 or > 1 flag)

# Individual Cook's distances
cooks.distance(m) |> sort(decreasing = TRUE) |> head()
```

### GLMs

```r
# Logistic regression (binary outcome)
m_log <- glm(survived ~ age + fare, data = df, family = binomial)
summary(m_log)

# CRITICAL: default predict() returns log-odds (link scale)
predict(m_log, newdata = new_df)                   # log-odds — rarely what you want
predict(m_log, newdata = new_df, type = "response") # probabilities — usually what you want

# Poisson regression (count outcome)
m_poi <- glm(count ~ x, data = df, family = poisson)

# Quasi-poisson for overdispersion
m_qpoi <- glm(count ~ x, data = df, family = quasipoisson)
```

Exponentiate logistic coefficients for odds ratios:

```r
exp(coef(m_log))
exp(confint(m_log))
```

---

## 3. broom — Model Objects → Tibbles

broom is the bridge between base model objects and the tidyverse.
Three functions cover almost everything:

| Function | Returns | Use for |
|----------|---------|---------|
| `tidy()` | one row per coefficient | extracting estimates, CIs, p-values |
| `glance()` | one row per model | comparing models; R², AIC, BIC |
| `augment()` | one row per observation | residuals, fitted values, Cook's D |

```r
library(broom)

m <- lm(mpg ~ wt + hp, data = mtcars)

tidy(m)                         # coefficients tibble
tidy(m, conf.int = TRUE)        # + 95% CI columns
tidy(m, conf.int = TRUE, conf.level = 0.90)

glance(m)                       # r.squared, adj.r.squared, AIC, BIC, sigma, ...

augment(m)                      # .fitted, .resid, .hat, .cooksd, .std.resid
augment(m, newdata = test_df)   # predictions on new data
```

Works identically for `glm`, `aov`, `t.test`, `wilcox.test`, `cor.test`,
and many modelling packages. Check `?tidy.<class>` for method-specific args.

```r
# Pattern: compare many models at once
library(purrr)
models <- list(
  simple  = lm(mpg ~ wt,       data = mtcars),
  full    = lm(mpg ~ wt + hp,  data = mtcars),
  poly    = lm(mpg ~ poly(wt, 2) + hp, data = mtcars)
)
map_dfr(models, glance, .id = "model") |>
  select(model, adj.r.squared, AIC, BIC) |>
  arrange(AIC)
```

---

## 4. tidymodels — Modern ML Framework

tidymodels replaces `caret`. Use it when you need:
- Train/test splits with resampling (CV)
- Preprocessing pipelines that respect data leakage rules
- Multiple model types with a unified interface
- Hyperparameter tuning

Core packages: `rsample`, `recipes`, `parsnip`, `workflows`, `tune`, `yardstick`.

### End-to-end skeleton

```r
library(tidymodels)   # loads all core packages

# 1. Split ----------------------------------------------------------------
set.seed(42)
split  <- initial_split(df, prop = 0.8, strata = outcome)
train  <- training(split)
test   <- testing(split)

# Cross-validation folds (on training data only)
folds  <- vfold_cv(train, v = 10, strata = outcome)

# 2. Recipe (preprocessing) -----------------------------------------------
rec <- recipe(outcome ~ ., data = train) |>
  step_impute_median(all_numeric_predictors()) |>
  step_normalize(all_numeric_predictors()) |>
  step_dummy(all_nominal_predictors()) |>
  step_zv(all_predictors())    # remove zero-variance columns

# 3. Model spec (parsnip) -------------------------------------------------
spec_rf <- rand_forest(mtry = tune(), trees = 500, min_n = tune()) |>
  set_engine("ranger") |>
  set_mode("classification")

# 4. Workflow (bundle recipe + model) -------------------------------------
wf <- workflow() |>
  add_recipe(rec) |>
  add_model(spec_rf)

# 5. Tune -----------------------------------------------------------------
grid <- grid_latin_hypercube(mtry(range = c(2, 10)), min_n(), size = 20)

tune_res <- tune_grid(
  wf,
  resamples = folds,
  grid      = grid,
  metrics   = metric_set(roc_auc, accuracy),
  control   = control_grid(save_pred = TRUE)
)

# 6. Select best & finalise -----------------------------------------------
best_params <- select_best(tune_res, metric = "roc_auc")
final_wf    <- finalize_workflow(wf, best_params)

# 7. Last fit (train on full train, evaluate on test) --------------------
last_fit_res <- last_fit(final_wf, split)

collect_metrics(last_fit_res)   # roc_auc, accuracy on held-out test
collect_predictions(last_fit_res) |>
  roc_curve(truth = outcome, .pred_yes) |>
  autoplot()

# 8. Final model for production ------------------------------------------
final_model <- fit(final_wf, data = df)  # refit on all data
predict(final_model, new_data = new_df)
```

### Common parsnip engines

```r
# Linear regression
linear_reg() |> set_engine("lm")
linear_reg(penalty = tune()) |> set_engine("glmnet")   # ridge/lasso

# Logistic regression
logistic_reg() |> set_engine("glm")
logistic_reg(penalty = tune()) |> set_engine("glmnet")

# Random forest
rand_forest() |> set_engine("ranger") |> set_mode("classification")
rand_forest() |> set_engine("ranger") |> set_mode("regression")

# Gradient boosting
boost_tree() |> set_engine("xgboost") |> set_mode("classification")

# Support vector machine
svm_rbf() |> set_engine("kernlab") |> set_mode("classification")
```

### yardstick metrics

```r
# Regression
metrics(results, truth = y, estimate = .pred)   # rmse, rsq, mae

# Classification (binary)
roc_auc(results, truth = outcome, .pred_yes)
accuracy(results, truth = outcome, estimate = .pred_class)
conf_mat(results, truth = outcome, estimate = .pred_class)

# Multi-metric
metric_set(roc_auc, accuracy, f_meas)
```

---

## 5. Which Test?

| Situation | Test |
|-----------|------|
| Compare mean to value, normal data | `t.test(x, mu=)` |
| Compare two means, unpaired, normal | `t.test(y ~ group)` |
| Compare two means, **paired** | `t.test(x, y, paired=TRUE)` |
| Two means, non-normal / ordinal | `wilcox.test` |
| Paired, non-normal | `wilcox.test(paired=TRUE)` |
| Three+ group means | `aov` + `TukeyHSD` |
| Three+ groups, non-normal | `kruskal.test` + `pairwise.wilcox.test` |
| Two proportions | `prop.test` |
| Categorical association (expected ≥ 5) | `chisq.test` |
| Categorical association (small counts) | `fisher.test` |
| Normality screening | `shapiro.test` + Q-Q plot |
| Distributional equality | `ks.test` |
| Linear association (inference) | `cor.test` |
| Continuous outcome, 1+ predictors | `lm` |
| Binary outcome | `glm(family=binomial)` |
| Count outcome | `glm(family=poisson)` |
| CV + tuning + multiple models | tidymodels |

---

## 6. Gotchas

**`wilcox.test` pseudomedian** — `$estimate` is the Hodges-Lehmann
estimator, not the sample median. For symmetric distributions they're
close; for skewed data they diverge. Don't label it "median" in a report.

**`predict()` link vs response** — for any GLM, the default `type` is
`"link"` (log-odds for logistic, log for Poisson). Always pass
`type = "response"` unless you specifically want the link scale.

**`cor()` gives no inference** — it's just a scalar. Use `cor.test()`
whenever you need a p-value or CI.

**Data leakage in recipes** — `prep()`/`bake()` must be fitted on
training data only. tidymodels handles this automatically inside
`fit_resamples()` / `tune_grid()`. If you call `prep(rec, training=full_data)`
manually, you've leaked.

**`shapiro.test` limitations** — breaks down above n ≈ 5000 (always
rejects) and has low power at n < 20 (rarely rejects). Use it as a
screen, not a verdict. A Q-Q plot at any sample size is more informative.

**Adjusted R² vs R²** — `summary(m)$r.squared` increases with every
added predictor. Use `adj.r.squared` or AIC/BIC (from `glance()`) for
model comparison.

**Multiple comparisons** — default `pairwise.t.test` uses `"holm"` only
if you specify it. The base default is `"holm"` in current R, but be
explicit. For genomics-scale testing use `"BH"` (FDR control), not Bonferroni.

**`aov` vs `lm`** — `aov()` is `lm()` with a different summary format.
`model.matrix(aov(...))` is identical. You can pass an `aov` object to
`broom::tidy()` just like `lm`.

**tidymodels vs base lm** — base `lm`/`glm` is faster to write, returns
familiar objects, and is fine for: EDA, simple inference, fixed datasets,
one model. Reach for tidymodels when you need reproducible preprocessing,
cross-validated performance estimates, or model comparison at scale.
