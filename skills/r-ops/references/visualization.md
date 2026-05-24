# ggplot2 — Data Visualization Reference

ggplot2 implements the grammar of graphics: every plot is built by composing layers over a coordinate system. The payoff is a small vocabulary that handles 95% of analysis plots without memorizing ad-hoc APIs.

```r
library(tidyverse)   # loads ggplot2, dplyr, forcats, scales, etc.
```

---

## The Layered Mental Model

```
ggplot(data, aes(...))   # canvas + default aesthetics
  + geom_*()             # geometric layer (what to draw)
  + stat_*()             # optional: transform data before drawing
  + scale_*()            # override axis/colour/size mappings
  + coord_*()            # coordinate system (flip, polar, fixed)
  + facet_*()            # small multiples
  + theme_*() / theme()  # non-data ink (fonts, grid, legend)
```

Every `+` adds a layer. Layers share the canvas-level `aes()` unless overridden locally. Build incrementally; assign the base to an object and add layers for variants.

```r
base <- ggplot(df, aes(x = weight, y = height))
base + geom_point()
base + geom_point(aes(colour = group)) + geom_smooth(method = "lm")
```

---

## Aesthetics: Mapping vs. Setting

**Mapping** — inside `aes()`, driven by data:

```r
geom_point(aes(colour = species, shape = species, size = mass))
```

**Setting** — outside `aes()`, constant:

```r
geom_point(colour = "steelblue", size = 2, alpha = 0.6)
```

The most common gotcha: `geom_point(aes(colour = "blue"))` maps the string literal `"blue"` to the colour scale — it does NOT produce blue points.

### Common Aesthetics

| Aesthetic | Types | Notes |
|-----------|-------|-------|
| `x`, `y` | all | positional |
| `colour` / `color` | all | border/line/point colour |
| `fill` | bars, areas, polygons | interior colour |
| `shape` | point | 0–25; 21–25 have fill |
| `size` | point, line | in mm |
| `alpha` | all | 0 (transparent) – 1 (opaque) |
| `linetype` | line | solid, dashed, dotted, etc. |
| `group` | line, smooth | grouping without visual change |
| `label` | text geoms | character string |

---

## Key Geoms

### Points and Lines

```r
geom_point()               # scatterplot; add jitter via position_jitter()
geom_jitter(width=0.2)     # convenience: jittered points
geom_line()                # connect points in x order; needs group= for multiple series
geom_path()                # connect in data order (trajectory plots)
geom_smooth(method="lm")   # trend line; method: "lm", "loess", "gam"
geom_smooth(se=FALSE)      # suppress confidence ribbon
```

### Distributions (one variable)

```r
geom_histogram(binwidth=5)        # choose binwidth, not bins
geom_density(adjust=1)            # kernel density; adjust scales bandwidth
geom_freqpoly(binwidth=5)         # histogram as lines; good for overlaying groups
geom_boxplot()                    # five-number summary + outliers
geom_violin()                     # density shape; more info than boxplot
geom_dotplot(binaxis="y")         # individual points in bins
```

### Categorical / Counts

```r
geom_bar()                        # counts rows (stat="count" default)
geom_col()                        # heights from data (stat="identity")
geom_count()                      # bubble size = count; cat × cat grids
```

### Heatmaps / Tiles

```r
geom_tile(aes(fill=value))        # rectangular heatmap
geom_raster(aes(fill=value))      # faster tile for regular grids
```

### Annotations / Text

```r
geom_text(aes(label=name))        # raw text; overlaps freely
geom_label(aes(label=name))       # text with background box
annotate("text", x=5, y=10, label="Peak")   # single annotation, no data frame needed
annotate("rect", xmin=2, xmax=4, ymin=0, ymax=100, alpha=0.2)
# For non-overlapping labels:
library(ggrepel)
geom_text_repel(aes(label=name))
geom_label_repel(aes(label=name))
```

### Area / Ribbon

```r
geom_area()                       # filled area chart; stack with position_stack()
geom_ribbon(aes(ymin=lo, ymax=hi))  # confidence band around a line
```

---

## Which Geom?

| Goal | Geom(s) |
|------|---------|
| Two continuous variables | `geom_point` + `geom_smooth` |
| One continuous distribution | `geom_histogram` or `geom_density` |
| Continuous by group | `geom_boxplot` or `geom_violin` |
| Continuous over time | `geom_line` |
| Count by category | `geom_bar` |
| Pre-computed values | `geom_col` |
| Two categorical, covariation | `geom_count` or `geom_tile` after `count()` |
| Trend with uncertainty | `geom_smooth` + `geom_ribbon` |
| Labelled points | `geom_text_repel` (ggrepel) |
| Many overlapping points | `geom_hex` or `geom_bin2d` |

---

## Position Adjustments

```r
geom_bar(position = "stack")    # default for bar: stack groups
geom_bar(position = "fill")     # stack to 100% — shows proportions
geom_bar(position = "dodge")    # side-by-side bars
geom_point(position = position_jitter(width=0.1, height=0))
geom_point(position = position_dodge(width=0.8))  # offset overlapping points by group
```

---

## Stats

Stats transform data before drawing. Most geoms have a paired stat; you can swap them.

```r
# Draw means ± SE without pre-summarising:
geom_point(stat = "summary", fun = mean)
stat_summary(fun = mean, fun.min = function(x) mean(x)-sd(x),
             fun.max = function(x) mean(x)+sd(x),
             geom = "pointrange")

# Density from raw data:
stat_density_2d(aes(fill = after_stat(level)), geom = "polygon")

# after_stat() accesses computed variables:
geom_histogram(aes(y = after_stat(density)))   # normalised histogram
```

---

## Scales

Scale functions follow `scale_<aesthetic>_<type>()`.

### Axes

```r
scale_x_continuous(breaks = seq(0, 100, 25), labels = scales::label_comma())
scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05)))
scale_x_log10()                          # log-transformed axis
scale_x_date(date_breaks = "1 year", date_labels = "%Y")
scale_x_discrete(limits = rev)           # reverse categorical axis
```

### Colour / Fill

```r
# Continuous:
scale_colour_gradient(low="white", high="steelblue")
scale_colour_gradient2(midpoint=0, low="blue", mid="white", high="red")
scale_fill_viridis_c()          # perceptually uniform, colourblind-safe
scale_fill_viridis_d()          # discrete version

# Discrete:
scale_colour_brewer(palette = "Set2")    # ColorBrewer palettes
scale_colour_manual(values = c(A = "#E41A1C", B = "#377EB8"))

# Ordinal:
scale_colour_ordinal()          # for ordered factors
```

### Other Scales

```r
scale_size_continuous(range = c(1, 8))
scale_alpha_continuous(range = c(0.2, 1))
scale_shape_manual(values = c(16, 17, 15))
```

### Labels

```r
labs(
  title    = "Main title",
  subtitle = "Secondary line",
  caption  = "Source: ...",
  x        = "X axis label",
  y        = "Y axis label",
  colour   = "Legend title",   # match the aesthetic name
  fill     = "Fill legend"
)
```

---

## Facets

```r
# Wrap a single variable into a grid:
facet_wrap(~ species)
facet_wrap(~ species, ncol = 2, scales = "free_y")

# Two-way grid:
facet_grid(rows ~ cols)
facet_grid(cut ~ color, scales = "free")

# Strip labels:
facet_wrap(~ species, labeller = label_both)   # "species: Adelie" etc.
```

Faceting is usually cleaner than colour-coding when you have 3+ groups with overlap.

---

## Coordinate Systems

```r
coord_flip()                      # swap x and y; useful for long category names
coord_fixed(ratio = 1)            # equal aspect ratio
coord_cartesian(ylim = c(0, 50))  # zoom without dropping data (vs. scale limits which drop)
coord_polar()                     # polar coords (pie charts, rose plots)
coord_trans(y = "sqrt")           # transform after statistics
```

Use `coord_cartesian()` to zoom; use scale `limits` only when you want to exclude data from stats.

---

## Themes

```r
# Built-in themes:
theme_minimal()      # clean, white background, subtle grid
theme_bw()           # white background, black border
theme_classic()      # no grid lines — publication style
theme_void()         # blank canvas; useful for maps
theme_light()

# Fine-tune anything:
theme(
  legend.position    = "bottom",         # "top","left","right","none"
  legend.direction   = "horizontal",
  axis.text.x        = element_text(angle = 45, hjust = 1),
  axis.title         = element_text(size = 12, face = "bold"),
  plot.title         = element_text(size = 14, face = "bold"),
  panel.grid.minor   = element_blank(),
  strip.background   = element_blank()   # cleaner facet labels
)

# Set a global default for a session:
theme_set(theme_minimal(base_size = 12))
```

---

## EDA Workflow: Question-Driven Exploration

The EDA loop: plot → notice → refine question → plot again.

**Step 1 — Understand each variable's distribution**

```r
# Continuous:
ggplot(df, aes(x = price)) + geom_histogram(binwidth = 100)
ggplot(df, aes(x = price)) + geom_density()

# Categorical:
df |> count(cut) |> ggplot(aes(x = fct_reorder(cut, n), y = n)) + geom_col()
```

**Step 2 — Examine covariation**

```r
# Continuous × Continuous:
ggplot(df, aes(x = carat, y = price)) + geom_point(alpha = 0.1) + geom_smooth()

# Continuous × Categorical — compare distributions:
ggplot(df, aes(x = price, y = fct_reorder(cut, price, median))) + geom_boxplot()

# Two categorical — count grid:
df |> count(cut, color) |>
  ggplot(aes(x = cut, y = color, fill = n)) +
  geom_tile()
```

**Step 3 — Handle outliers and missing values**

```r
# Zoom without losing data from smooths:
ggplot(df, aes(x, y)) + geom_point() + coord_cartesian(ylim = c(0, 500))

# Suppress NA warnings when intentional:
geom_point(na.rm = TRUE)

# Distinguish NA from non-NA:
df |> mutate(cancelled = is.na(dep_time)) |>
  ggplot(aes(x = sched_dep_time, colour = cancelled)) +
  geom_freqpoly(binwidth = 0.25)
```

---

## Plot Composition with patchwork

```r
library(patchwork)

p1 <- ggplot(df, aes(x, y)) + geom_point()
p2 <- ggplot(df, aes(x)) + geom_histogram()
p3 <- ggplot(df, aes(y)) + geom_boxplot()

p1 + p2            # side by side
p1 / p2            # stacked
(p1 | p2) / p3    # 2 on top, 1 spanning bottom

# Unified legend + shared title:
(p1 + p2) +
  plot_annotation(title = "Overview", tag_levels = "A") +
  plot_layout(guides = "collect")
```

---

## Saving Plots

```r
ggsave("output/plot.png", width = 8, height = 5, dpi = 300)
ggsave("output/plot.pdf", width = 8, height = 5)   # vector output for print

# Explicit plot argument:
ggsave("plot.png", plot = p1, width = 6, height = 4, dpi = 150)
```

`ggsave` infers format from the extension. Use `.pdf`/`.svg` for publication; `.png` for web and presentations. Always set explicit `width`/`height` — the default proportions are rarely right.

---

## Gotchas

### 1. Mapping vs. setting colour (the most common mistake)

```r
# WRONG — maps the string "blue" to colour scale, produces red/salmon:
geom_point(aes(colour = "blue"))

# RIGHT — sets all points to blue:
geom_point(colour = "blue")
```

### 2. `group` aesthetic — when colour isn't set but lines need grouping

```r
# Multiple subjects measured over time: lines jump between subjects without group=
ggplot(df, aes(x = time, y = value, group = subject)) + geom_line()

# colour= implicitly sets group; explicit group= needed when colour isn't mapped:
ggplot(df, aes(x = time, y = value)) +
  geom_smooth(aes(group = cohort), se = FALSE)
```

### 3. Factor ordering controls bar/boxplot order

```r
# Alphabetical order is almost never the right order:
df |> mutate(city = fct_reorder(city, sales, sum)) |>
  ggplot(aes(x = city, y = sales)) + geom_col()

# forcats helpers:
fct_reorder(f, x)            # reorder by another variable
fct_infreq(f)                # most frequent first
fct_rev(f)                   # reverse current order
fct_relevel(f, "Other", after=Inf)   # push "Other" to end
```

### 4. Scale limits vs. coord_cartesian — they are not equivalent

```r
# Drops data outside limits → changes smooths, counts, boxplot stats:
scale_y_continuous(limits = c(0, 50))

# Zooms view only, keeps all data in stats:
coord_cartesian(ylim = c(0, 50))
```

### 5. `colour` (British) and `color` (American) are both accepted — but pick one per project.

### 6. Local `data=` in a geom overrides global data — useful for annotation layers

```r
labels_df <- df |> filter(label_me)
ggplot(df, aes(x, y)) +
  geom_point() +
  geom_text_repel(data = labels_df, aes(label = name))
```

### 7. `geom_bar` vs. `geom_col`

- `geom_bar()` counts rows — `x` only, `y` is computed.
- `geom_col()` uses pre-computed heights — both `x` and `y` required.

### 8. Log scales suppress zeros — use `log1p` transform or `scale_x_log10()` only on positive data.

---

## Quick Reference: Useful Extension Packages

| Package | Purpose |
|---------|---------|
| `ggrepel` | Non-overlapping text/label geoms |
| `patchwork` | Compose multiple plots |
| `scales` | Label formatters (`label_comma`, `label_percent`, `label_dollar`) |
| `ggthemes` | Extra themes (including colourblind-safe palettes) |
| `ggridges` | Ridge/joy plots (`geom_density_ridges`) |
| `ggforce` | Advanced annotations, mark hulls, zoom |
| `gghighlight` | Highlight subsets without pre-filtering |
| `ggdist` | Distribution geoms for uncertainty viz |

---

## Base Graphics vs. ggplot2

Base graphics (`plot()`, `hist()`, `barplot()`) are fine for throwaway exploration at the REPL — they need zero setup and print instantly. Use ggplot2 for anything that will be communicated, iterated on, or composed into a report. The grammar pays for itself the moment you want facets, consistent themes, or a second layer.
