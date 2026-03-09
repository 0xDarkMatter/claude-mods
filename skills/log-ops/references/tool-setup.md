# Tool Setup Reference

Installation, configuration, and key commands for log analysis tools. Each tool includes install commands for all platforms, the most useful flags, and integration patterns.

---

## jq -- JSON/JSONL Processor

The primary tool for structured log analysis. Processes JSONL line by line (streaming) or as a batch (slurp).

### Installation

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq

# Windows
choco install jq
# or
winget install jqlang.jq

# Verify
jq --version
```

### Key Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `-c` | Compact output (one JSON per line) | `jq -c '.' file.jsonl` |
| `-r` | Raw string output (no quotes) | `jq -r '.message' file.jsonl` |
| `-s` | Slurp: read all lines into array | `jq -s 'length' file.jsonl` |
| `-S` | Sort object keys | `jq -S '.' file.json` |
| `-e` | Exit 1 if output is false/null | `jq -e '.ok' file.json` |
| `-R` | Read lines as raw strings | `jq -R 'fromjson?' messy.jsonl` |
| `-n` | Null input (use with inputs) | `jq -n '[inputs]' file.jsonl` |
| `--arg` | Pass string variable | `jq --arg id "42" 'select(.id == $id)'` |
| `--argjson` | Pass JSON variable | `jq --argjson n 10 'select(.count > $n)'` |
| `--slurpfile` | Load file as variable | `jq --slurpfile ids ids.json 'select(.id | IN($ids[][]))'` |
| `--stream` | SAX-style path/value output | `jq --stream '.' huge.json` |
| `--unbuffered` | Flush after each output | `tail -f f.jsonl \| jq --unbuffered '.'` |
| `--tab` | Use tabs for indentation | `jq --tab '.' file.json` |

### Essential Commands

```bash
# Pretty print a single JSON object
jq '.' file.json

# Validate JSONL (report bad lines)
jq -c '.' file.jsonl > /dev/null 2>&1 || echo "Invalid JSON detected"

# Find and show invalid lines
awk '{
  cmd = "echo " "'\'''" $0 "'\'''" " | jq . 2>/dev/null"
  if (system(cmd) != 0) print NR": "$0
}' file.jsonl

# Better: use jq -R to find invalid lines
jq -R 'fromjson? // error' file.jsonl 2>&1 | rg "error" | head

# Count lines in JSONL
jq -sc 'length' file.jsonl

# Get unique keys across all objects
jq -sc '[.[] | keys[]] | unique' file.jsonl

# Get schema (keys and types) from first line
head -1 file.jsonl | jq '[to_entries[] | {key, type: (.value | type)}]'

# Reformat JSONL with consistent key ordering
jq -cS '.' file.jsonl > normalized.jsonl
```

### Debugging jq Expressions

```bash
# Use debug to print intermediate values to stderr
jq '.items[] | debug | select(.active)' file.json

# Use @text to see what jq thinks a value is
jq '.field | @text' file.json

# Use type to check value types
jq '.field | type' file.json

# Build expressions incrementally
jq '.' file.json                    # Start: see full structure
jq '.items' file.json               # Navigate to array
jq '.items[]' file.json             # Iterate array
jq '.items[] | .name' file.json     # Extract field
jq '.items[] | select(.active)' file.json  # Filter

# Common error: "Cannot iterate over null"
# Fix: use ? operator
jq '.items[]?' file.json            # Won't error if items is null

# Common error: "null is not iterable"
# Fix: default empty array
jq '(.items // [])[]' file.json
```

### Integration with Other Tools

```bash
# rg prefilter then jq parse
rg '"error"' app.jsonl | jq -r '.message'

# jq output to column for alignment
jq -r '[.name, .status, .duration] | @tsv' app.jsonl | column -t

# jq output to sort/uniq for frequency
jq -r '.error_type' errors.jsonl | sort | uniq -c | sort -rn

# jq to CSV for spreadsheet import
jq -r '[.timestamp, .level, .message] | @csv' app.jsonl > export.csv

# jq with xargs for per-line processing
jq -r '.file_path' manifest.jsonl | xargs wc -l
```

---

## lnav -- Log File Navigator

Interactive terminal-based log viewer with SQL support, automatic format detection, timeline view, and filtering. Ideal for exploratory analysis.

### Installation

```bash
# macOS
brew install lnav

# Ubuntu/Debian
sudo apt install lnav

# Windows (via Chocolatey)
choco install lnav

# From source
curl -LO https://github.com/tstack/lnav/releases/download/v0.12.2/lnav-0.12.2-linux-musl-x86_64.zip
unzip lnav-0.12.2-linux-musl-x86_64.zip
sudo cp lnav-0.12.2/lnav /usr/local/bin/

# Verify
lnav -V
```

### Key Features

| Feature | Access | Description |
|---------|--------|-------------|
| Auto-detect format | Automatic | Recognizes syslog, Apache, nginx, JSON, and many more |
| SQL queries | `:` then SQL | Run SQL against log data |
| Filter in/out | `i` / `o` | Interactive include/exclude filters |
| Bookmarks | `m` | Mark lines for later reference |
| Timeline | `t` | Show time histogram |
| Pretty print | `p` | Toggle pretty-printing JSON |
| Headless mode | `-n -c "..."` | Non-interactive command execution |
| Compressed files | Automatic | Handles .gz, .bz2, .xz transparently |

### Essential Commands

```bash
# Open log file(s)
lnav app.log
lnav /var/log/syslog /var/log/auth.log   # multiple files, merged by timestamp

# Open JSONL logs
lnav app.jsonl

# Open compressed logs
lnav app.log.gz

# Open all logs in a directory
lnav /var/log/myapp/

# Headless mode: run query and output results
lnav -n -c ";SELECT count(*) FROM logline WHERE log_level = 'error'" app.log

# Headless mode: filter and export
lnav -n -c ";SELECT log_time, log_body FROM logline WHERE log_level = 'error'" \
  -c ":write-csv-to errors.csv" app.log

# Headless mode: get stats
lnav -n -c ";SELECT log_level, count(*) as cnt FROM logline GROUP BY log_level ORDER BY cnt DESC" app.log
```

### SQL Mode Recipes

```sql
-- Error count by hour
SELECT strftime('%Y-%m-%d %H', log_time) as hour, count(*) as errors
FROM logline WHERE log_level = 'error'
GROUP BY hour ORDER BY hour;

-- Top error messages
SELECT log_body, count(*) as cnt
FROM logline WHERE log_level = 'error'
GROUP BY log_body ORDER BY cnt DESC LIMIT 10;

-- Time between events
SELECT log_time, log_body,
  julianday(log_time) - julianday(lag(log_time) OVER (ORDER BY log_time)) as gap_days
FROM logline WHERE log_level = 'error';

-- Log volume over time
SELECT strftime('%Y-%m-%d %H:%M', log_time) as minute, count(*) as lines
FROM logline
GROUP BY minute ORDER BY minute;
```

### Custom Log Formats

```json
// ~/.lnav/formats/installed/myapp.json
{
  "myapp_log": {
    "title": "My Application Log",
    "regex": {
      "std": {
        "pattern": "^(?<timestamp>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})\\s+\\[(?<level>\\w+)\\]\\s+(?<body>.*)"
      }
    },
    "timestamp-format": ["%Y-%m-%dT%H:%M:%S"],
    "level": {
      "error": "ERROR",
      "warning": "WARN",
      "info": "INFO",
      "debug": "DEBUG"
    }
  }
}
```

### Interactive Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `/` | Search forward (regex) |
| `n` / `N` | Next/previous search match |
| `i` | Toggle filter: show only matching lines |
| `o` | Toggle filter: hide matching lines |
| `TAB` | Switch between views (log, text, help) |
| `t` | Toggle timeline histogram |
| `m` | Set bookmark on current line |
| `u` / `U` | Next/previous bookmark |
| `z` / `Z` | Zoom in/out on timeline |
| `p` | Toggle pretty-print for JSON |
| `e` / `E` | Next/previous error |
| `w` / `W` | Next/previous warning |
| `:` | Enter command mode |
| `;` | Enter SQL query mode |

---

## angle-grinder (agrind) -- Log Pipeline Aggregation

Pipeline-based aggregation tool designed for log analysis. Think SQL-like queries in a streaming pipeline syntax.

### Installation

```bash
# Via cargo (all platforms)
cargo install ag

# macOS
brew install angle-grinder

# Verify
agrind --version
```

### Pipeline Syntax

```
<input_pattern> | <operator1> | <operator2> | ...
```

### Essential Commands

```bash
# Count log levels
cat app.log | agrind '* | parse "* [*] *" as ts, level, msg | count by level'

# Top URLs
cat access.log | agrind '* | parse "* * * * * * *" as ip, _, _, ts, method, url, status | count by url | sort by _count desc | head 10'

# Average response time by endpoint
cat access.log | agrind '* | parse "* *ms" as prefix, duration | avg of duration by prefix'

# Error frequency over time
cat app.log | agrind '* | parse "*T*:*:* [ERROR]*" as date, hour, min, sec, msg | count by hour'

# Filter then aggregate
cat app.log | agrind '* | where level == "error" | count by msg | sort by _count desc'

# JSON log fields
cat app.jsonl | agrind '* | json | where level == "error" | count by message'
```

### Operators Reference

| Operator | Purpose | Example |
|----------|---------|---------|
| `parse` | Extract fields with pattern | `parse "* [*] *" as a, b, c` |
| `json` | Parse JSON log lines | `json` |
| `where` | Filter rows | `where level == "error"` |
| `count` | Count (optionally by group) | `count by level` |
| `sum` | Sum a field | `sum of bytes` |
| `avg` | Average a field | `avg of duration` |
| `min` / `max` | Min/max of field | `min of response_time` |
| `sort` | Sort results | `sort by _count desc` |
| `head` | Limit results | `head 10` |
| `uniq` | Unique values | `uniq by user_id` |
| `percentile` | Percentile calc | `p50 of duration, p99 of duration` |

---

## rg (ripgrep) -- Fast Pattern Search

Already covered extensively in file-search skill. Here are log-specific flags and patterns.

### Log-Specific Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `-c` | Count matches per file | `rg -c "ERROR" /var/log/*.log` |
| `-l` | List files with matches | `rg -l "timeout" /var/log/` |
| `-L` | List files without matches | `rg -L "healthy" /var/log/` |
| `--stats` | Show match statistics | `rg --stats "error" app.log` |
| `-A N` | Show N lines after match | `rg -A5 "Exception" app.log` |
| `-B N` | Show N lines before match | `rg -B3 "FATAL" app.log` |
| `-C N` | Show N lines context | `rg -C5 "crash" app.log` |
| `-U` | Multiline matching | `rg -U "Error.*\n.*at " app.log` |
| `--json` | JSON output format | `rg --json "error" app.log` |
| `-a` | Search binary files | `rg -a "pattern" binary.log` |
| `--line-buffered` | Flush per line (for tail) | `tail -f app.log \| rg --line-buffered "error"` |
| `-F` | Fixed string (no regex) | `rg -F "stack[0]" app.log` |
| `-f FILE` | Patterns from file | `rg -f patterns.txt app.log` |
| `-v` | Invert match | `rg -v "DEBUG" app.log` |

### Log Search Recipes

```bash
# Find errors across all log files recursively
rg "ERROR|FATAL|CRITICAL" /var/log/

# Count errors per file, sorted
rg -c "ERROR" /var/log/ 2>/dev/null | sort -t: -k2 -rn

# Find stack traces (multiline)
rg -U "Exception.*\n(\s+at .*\n)+" app.log

# Extract timestamps of errors
rg "ERROR" app.log | rg -o "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"

# Search compressed log files
rg -z "error" app.log.gz

# Search JSONL for specific field value (text-level, fast but approximate)
rg '"level":"error"' app.jsonl

# Search JSONL for value in specific key (avoid matching wrong key)
rg '"user_id":"user-42"' app.jsonl

# Negative lookahead: errors that are NOT timeouts
rg "ERROR(?!.*timeout)" app.log

# Time-bounded search (extract lines between two timestamps)
rg "2026-03-08T1[4-5]:" app.log
```

### rg JSON Output Mode

```bash
# Get structured output from rg (useful for programmatic processing)
rg --json "error" app.log | jq -c 'select(.type == "match") | {file: .data.path.text, line: .data.line_number, text: .data.lines.text}'

# Count matches with file info
rg --json "error" app.log | jq -c 'select(.type == "summary") | .data.stats'
```

---

## awk -- Column-Based Log Processing

Pre-installed on all Unix systems. Best for space/tab delimited logs with consistent column structure.

### Common Recipes

```bash
# Apache/nginx combined log format columns:
# $1=IP $2=ident $3=user $4=date $5=time $6=tz $7=method $8=path $9=proto $10=status $11=size

# Status code distribution
awk '{print $9}' access.log | sort | uniq -c | sort -rn

# Requests per IP
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head -20

# 5xx errors with paths
awk '$9 >= 500 {print $1, $9, $7}' access.log

# Average response size
awk '{sum += $10; n++} END {printf "Avg: %.0f bytes\n", sum/n}' access.log

# Requests per minute
awk '{print substr($4, 2, 17)}' access.log | sort | uniq -c | tail -20

# Bandwidth by path
awk '{bytes[$7] += $10} END {for (p in bytes) printf "%10d %s\n", bytes[p], p}' access.log | sort -rn | head -20

# Custom delimiter (e.g., pipe-separated)
awk -F'|' '{print $3, $5}' custom.log

# Time-range filter (syslog format)
awk '/^Mar  8 14:/ {print}' syslog

# Calculate time difference between first and last line
awk 'NR==1 {first=$1" "$2} END {last=$1" "$2; print "From:", first, "To:", last}' app.log
```

### awk for Key-Value Logs

```bash
# Parse key=value format (logfmt)
awk '{
  for (i=1; i<=NF; i++) {
    split($i, kv, "=")
    if (kv[1] == "duration") sum += kv[2]; n++
  }
} END {print "avg_duration=" sum/n}' app.log

# Extract specific key from logfmt
awk '{
  for (i=1; i<=NF; i++) {
    split($i, kv, "=")
    if (kv[1] == "status" && kv[2] >= 500) print $0
  }
}' app.log
```

---

## GNU parallel -- Parallel Log Processing

Splits work across CPU cores for processing large log files.

### Installation

```bash
# macOS
brew install parallel

# Ubuntu/Debian
sudo apt install parallel

# Verify
parallel --version
```

### Essential Commands

```bash
# Process multiple log files in parallel
ls /var/log/app-*.jsonl | parallel "jq -c 'select(.level == \"error\")' {} > {.}_errors.jsonl"

# Split large file and process chunks in parallel
split -l 200000 huge.jsonl /tmp/chunk_
ls /tmp/chunk_* | parallel "jq -r '.message' {} | sort | uniq -c" | sort -rn | head -20

# Parallel grep across many files
fd -e jsonl . /var/log/ | parallel "rg -c '\"error\"' {} 2>/dev/null" | sort -t: -k2 -rn

# Pipe-based parallelism (no temp files)
parallel --pipe -L 50000 "jq -c 'select(.level == \"error\")'" < huge.jsonl > errors.jsonl

# Parallel with progress bar
ls /var/log/app-*.jsonl | parallel --bar "jq -sc 'length' {}" | awk '{sum+=$1} END {print sum, "total lines"}'

# Number of jobs (default: CPU cores)
ls *.jsonl | parallel -j 4 "jq -c 'select(.status >= 500)' {}"
```

### Combining with split

```bash
# Full workflow: split, process in parallel, merge results
FILE=huge.jsonl
CHUNKS=/tmp/log_chunks
mkdir -p "$CHUNKS"

# Split
split -l 100000 "$FILE" "$CHUNKS/chunk_"

# Process in parallel
ls "$CHUNKS"/chunk_* | parallel "jq -r 'select(.level == \"error\") | .message' {}" |
  sort | uniq -c | sort -rn > error_summary.txt

# Cleanup
rm -rf "$CHUNKS"
```

---

## Miller (mlr) -- CSV/TSV Log Analysis

Like awk, sed, and jq combined but specifically for structured record data (CSV, TSV, JSON).

### Installation

```bash
# macOS
brew install miller

# Ubuntu/Debian
sudo apt install miller

# Windows
choco install miller

# Verify
mlr --version
```

### Essential Commands

```bash
# View CSV with headers
mlr --csv head -n 10 access_log.csv

# Filter rows
mlr --csv filter '$status >= 400' access_log.csv

# Sort by column
mlr --csv sort-by -nr duration access_log.csv

# Statistics
mlr --csv stats1 -a min,max,mean,p95 -f duration access_log.csv

# Group by with stats
mlr --csv stats1 -a count,mean -f duration -g endpoint access_log.csv

# Convert formats
mlr --c2j cat access_log.csv          # CSV to JSON
mlr --c2t cat access_log.csv          # CSV to TSV (table)
mlr --j2c cat access_log.json         # JSON to CSV
mlr --c2p cat access_log.csv          # CSV to pretty-print table

# Top-N by group
mlr --csv top -n 5 -f duration -g endpoint access_log.csv

# Add computed fields
mlr --csv put '$error = ($status >= 400 ? "yes" : "no")' access_log.csv

# Decimate (sample every Nth row)
mlr --csv sample -k 100 huge_log.csv

# Uniq count
mlr --csv count-distinct -f status access_log.csv

# Histogram
mlr --csv decimate -g status -n 1 access_log.csv | mlr --csv count-distinct -f status

# Join two CSV files
mlr --csv join -j user_id -f users.csv then sort-by user_id access_log.csv
```

### TSV from jq to mlr Pipeline

```bash
# Extract JSONL to TSV, then use mlr for analysis
jq -r '[.timestamp, .level, .duration_ms, .path] | @tsv' app.jsonl > /tmp/extracted.tsv
mlr --tsvlite --from /tmp/extracted.tsv \
  label timestamp,level,duration_ms,path then \
  filter '$level == "error"' then \
  stats1 -a count,mean -f duration_ms -g path then \
  sort-by -nr count
```

---

## Tool Integration Cheat Sheet

### Combining Tools

```bash
# fd + rg + jq: find files, prefilter, extract
fd -e jsonl . logs/ | xargs rg -l '"error"' | xargs jq -c 'select(.level == "error") | {ts: .timestamp, msg: .message}'

# rg + jq + column: search, extract, format
rg '"timeout"' app.jsonl | jq -r '[.timestamp, .service, .message] | @tsv' | column -t

# jq + sort + uniq: aggregate without slurp
jq -r '.error_type' errors.jsonl | sort | uniq -c | sort -rn

# tail + rg + jq: live monitoring with extraction
tail -f app.jsonl | rg --line-buffered '"error"' | jq --unbuffered -r '[.timestamp, .message] | @tsv'

# fd + parallel + jq: parallel extraction across many files
fd -e jsonl . logs/ | parallel "jq -c 'select(.level == \"error\")' {}" > all_errors.jsonl

# jq + mlr: structured extraction then statistical analysis
jq -r '[.path, .duration_ms, .status] | @csv' app.jsonl | \
  mlr --csv label path,duration,status then \
  stats1 -a p50,p95,p99 -f duration -g path then \
  sort-by -nr p95

# lnav + headless SQL: non-interactive queries
lnav -n -c ";SELECT log_level, count(*) FROM logline GROUP BY log_level" app.log
```

### Decision Guide: Which Combination?

```
Task: Explore unknown log file
  --> lnav (interactive, auto-detects format)

Task: Quick search for pattern
  --> rg "pattern" file.log

Task: Extract fields from JSONL
  --> jq -r '[.field1, .field2] | @tsv' file.jsonl

Task: Count/aggregate JSONL (<100MB)
  --> jq -sc 'group_by(.x) | map(...)' file.jsonl

Task: Count/aggregate JSONL (>100MB)
  --> jq -r '.field' file.jsonl | sort | uniq -c | sort -rn

Task: Search large JSONL then extract
  --> rg "pattern" file.jsonl | jq -r '.field'

Task: CSV/TSV log statistics
  --> mlr --csv stats1 -a mean,p95 -f duration file.csv

Task: Process many log files in parallel
  --> fd -e jsonl . dir/ | parallel "jq ..."

Task: Pipeline aggregation on text logs
  --> cat file.log | agrind '* | parse ... | count by ...'

Task: Live monitoring with filtering
  --> tail -f file.jsonl | rg --line-buffered "x" | jq --unbuffered '.'
```
