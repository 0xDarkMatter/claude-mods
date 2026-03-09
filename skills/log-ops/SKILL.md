---
name: log-ops
description: "Log analysis and JSONL processing - structured extraction, cross-log correlation, timeline reconstruction, pattern search"
allowed-tools: "Read Edit Write Bash Glob Grep Agent"
related-skills: [data-processing, debug-ops, monitoring-ops, file-search]
---

# Log Operations

Practical patterns for analyzing log files -- especially JSONL format used in agent conversation logs, benchmark outputs, and structured application logs.

## Log Format Decision Tree

```
Unknown Log File
│
├─ Is it one JSON object per line?
│  ├─ Yes ──────────────────────── JSONL
│  │  ├─ Small file (<100MB)
│  │  │  └─ jq for extraction, jq -s for aggregation
│  │  ├─ Large file (100MB-1GB)
│  │  │  └─ rg prefilter then pipe to jq
│  │  └─ Huge file (>1GB)
│  │     └─ split + parallel jq, or jq --stream
│  │
│  └─ No
│     ├─ Is it one large JSON object/array?
│     │  └─ Yes ──────────────── Single JSON
│     │     └─ jq --stream for SAX-style, or jq directly if fits in memory
│     │
│     ├─ Does it have key=value pairs?
│     │  └─ Yes ──────────────── Structured (logfmt / key-value)
│     │     └─ rg for search, awk/sd for extraction, angle-grinder for aggregation
│     │
│     ├─ Does it follow syslog format? (timestamp hostname service[pid]: message)
│     │  └─ Yes ──────────────── Syslog
│     │     └─ rg for search, awk for column extraction, lnav for interactive
│     │
│     ├─ Is it space/tab delimited with consistent columns?
│     │  └─ Yes ──────────────── Column-based (access logs, CSV)
│     │     └─ awk for extraction, mlr for CSV, rg for pattern search
│     │
│     └─ Mixed or unstructured
│        └─ Plain text ─────────── Freeform
│           └─ rg for search, rg -A/-B for context, lnav for exploration
```

## Tool Selection Matrix

| Tool | Best For | Speed | Install |
|------|----------|-------|---------|
| `rg` (ripgrep) | Raw pattern matching in any format | Fastest | `cargo install ripgrep` |
| `jq` | JSONL structured extraction and transformation | Fast | `brew install jq` / `choco install jq` |
| `jq -s` | JSONL aggregation (slurp all lines into array) | Medium (loads all into memory) | Same as jq |
| `lnav` | Interactive exploration, SQL over logs | Interactive | `brew install lnav` / `cargo install lnav` |
| `agrind` (angle-grinder) | Pipeline aggregation and counting | Fast | `cargo install ag` |
| `awk` | Column-based log formats, field extraction | Fast | Pre-installed |
| `mlr` (Miller) | CSV/TSV log analysis, statistics | Fast | `brew install miller` |
| `fd` + `rg` | Searching across many log directories | Fast | Pre-installed in dev-shell |
| `GNU parallel` | Splitting large files for parallel processing | N/A (orchestrator) | `brew install parallel` |

### When to Use What

```
Need to...
│
├─ Find lines matching a pattern
│  └─ rg (always fastest for text search)
│
├─ Extract specific fields from JSONL
│  └─ jq -r '[.field1, .field2] | @tsv'
│
├─ Count/aggregate over JSONL
│  └─ jq -sc 'group_by(.field) | map({key: .[0].field, n: length})'
│
├─ Search JSONL by value then format results
│  └─ rg '"error"' file.jsonl | jq -r '.message'  (two-stage)
│
├─ Explore interactively with filtering/SQL
│  └─ lnav file.log
│
├─ Aggregate with pipeline syntax
│  └─ agrind '* | parse "* * *" as ts, level, msg | count by level'
│
├─ Extract columns from space-delimited logs
│  └─ awk '{print $1, $4, $7}' access.log
│
└─ Process CSV/TSV logs with headers
   └─ mlr --csv filter '$status >= 400' then stats1 -a count -f status
```

## JSONL Quick Reference

The most common format for structured logs. One JSON object per line, no trailing commas, no wrapping array.

### Stream Filtering (line by line, constant memory)

```bash
# Filter by field value
jq -c 'select(.level == "error")' app.jsonl

# Filter by nested field
jq -c 'select(.request.method == "POST")' app.jsonl

# Filter by multiple conditions
jq -c 'select(.level == "error" and .status >= 500)' app.jsonl

# Filter by array contains
jq -c 'select(.tags | index("critical"))' app.jsonl

# Filter by field existence
jq -c 'select(.stack_trace != null)' app.jsonl

# Negate a filter
jq -c 'select(.level != "debug")' app.jsonl
```

### Field Extraction

```bash
# Extract single field
jq -r '.message' app.jsonl

# Extract multiple fields as TSV
jq -r '[.timestamp, .level, .message] | @tsv' app.jsonl

# Extract with default for missing fields
jq -r '.error_code // "none"' app.jsonl

# Extract nested field safely
jq -r '.response.headers["content-type"] // "unknown"' app.jsonl
```

### Aggregation (requires slurp: loads entire file)

```bash
# Count by field value
jq -sc 'group_by(.level) | map({level: .[0].level, count: length})' app.jsonl

# Top-N most common values
jq -sc '[.[].error_type] | group_by(.) | map({type: .[0], count: length}) | sort_by(-.count) | .[:10]' app.jsonl

# Sum a numeric field
jq -sc 'map(.duration_ms) | add' app.jsonl

# Average
jq -sc 'map(.duration_ms) | add / length' app.jsonl

# Min and max
jq -sc 'map(.duration_ms) | {min: min, max: max}' app.jsonl
```

### Nested Extraction (agent logs, complex structures)

```bash
# Extract tool calls from conversation logs
jq -c '.content[]? | select(.type == "tool_use") | .name' conversation.jsonl

# De-escape nested JSON strings
jq -c '.content | fromjson' app.jsonl

# Flatten nested arrays
jq -c '[.events[]? | .action]' app.jsonl

# Extract from arrays of objects
jq -c '.results[]? | select(.passed == false) | {test: .name, error: .message}' results.jsonl
```

### Two-Stage Pipeline (rg for speed, jq for structure)

```bash
# Fast prefilter then structured extraction
rg '"error"' app.jsonl | jq -r '[.timestamp, .message] | @tsv'

# Search for specific value then aggregate
rg '"timeout"' app.jsonl | jq -sc 'length'

# Pattern match then extract
rg '"user_id":"u-123"' app.jsonl | jq -c '{ts: .timestamp, action: .action}'
```

### Time-Range Filtering

```bash
# Filter by timestamp range (ISO 8601 string comparison works)
jq -c 'select(.timestamp > "2026-03-08T10:00" and .timestamp < "2026-03-08T11:00")' app.jsonl

# Events in the last N minutes (using epoch seconds)
jq -c --arg cutoff "$(date -d '30 minutes ago' +%s)" 'select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdate) > ($cutoff | tonumber))' app.jsonl

# Extract hour for histogram
jq -r '.timestamp | split("T")[1] | split(":")[0]' app.jsonl | sort | uniq -c
```

### Cross-File Join

```bash
# Extract IDs from one file, search in another
jq -r '.request_id' errors.jsonl | while read id; do
  rg "\"$id\"" responses.jsonl | jq -c '{id: .request_id, status: .status}'
done

# Faster: build lookup, then join
jq -r '.request_id' errors.jsonl | sort -u > /tmp/error_ids.txt
rg -Ff /tmp/error_ids.txt responses.jsonl | jq -c '{id: .request_id, status: .status}'

# Join two JSONL files by key using jq --slurpfile
jq --slurpfile lookup <(jq -sc 'map({(.id): .}) | add' lookup.jsonl) \
  '. + ($lookup[0][.ref_id] // {})' main.jsonl
```

## Plain Text Log Patterns

### Pattern Search with Context

```bash
# Show 5 lines before and after each match
rg -B5 -A5 "OutOfMemoryError" app.log

# Show only matching files
rg -l "FATAL" /var/log/

# Count matches per file
rg -c "ERROR" /var/log/*.log | sort -t: -k2 -rn

# Multiline patterns (stack traces)
rg -U "Exception.*\n(\s+at .*\n)+" app.log
```

### Column Extraction with awk

```bash
# Apache/nginx access log: extract status codes
awk '{print $9}' access.log | sort | uniq -c | sort -rn

# Extract specific time range from syslog
awk '$0 >= "Mar  8 10:00" && $0 <= "Mar  8 11:00"' syslog

# Calculate average response time (column 11)
awk '{sum += $11; n++} END {print sum/n}' access.log

# Filter by status code and show URL + response time
awk '$9 >= 500 {print $7, $11"ms"}' access.log
```

### Live Monitoring

```bash
# Follow with filtering
tail -f app.log | rg --line-buffered "ERROR"

# Follow JSONL and extract fields
tail -f app.jsonl | jq --unbuffered -r '[.timestamp, .level, .message] | @tsv'

# Follow multiple files
tail -f /var/log/service-*.log | rg --line-buffered "error|warn"
```

## Timeline Reconstruction

### Extracting and Sorting by Timestamp

```bash
# Merge multiple log files by timestamp
sort -t' ' -k1,2 service-a.log service-b.log > timeline.log

# JSONL: sort by timestamp field
jq -sc 'sort_by(.timestamp)[]' combined.jsonl > sorted.jsonl

# Extract timestamps and calculate gaps
jq -r '.timestamp' app.jsonl | awk '
  NR > 1 {
    cmd = "date -d \"" prev "\" +%s"; cmd | getline t1; close(cmd)
    cmd = "date -d \"" $0 "\" +%s"; cmd | getline t2; close(cmd)
    gap = t2 - t1
    if (gap > 5) print gap "s gap before " $0
  }
  { prev = $0 }
'

# Quick duration between first and last event
jq -sc '{start: .[0].timestamp, end: .[-1].timestamp}' app.jsonl
```

### Calculating Durations Between Events

```bash
# Duration between paired events (start/end)
jq -sc '
  group_by(.request_id) |
  map(
    (map(select(.event == "start")) | .[0].timestamp) as $start |
    (map(select(.event == "end")) | .[0].timestamp) as $end |
    {id: .[0].request_id, start: $start, end: $end}
  )
' events.jsonl

# Identify the slowest phase
jq -sc '
  sort_by(.timestamp) |
  [range(1; length) | {
    from: .[.-1].event,
    to: .[.].event,
    gap: ((.[.].ts_epoch) - (.[.-1].ts_epoch))
  }] |
  sort_by(-.gap) | .[0]
' events.jsonl
```

## Cross-Log Correlation

### By Correlation ID

```bash
# Find a request across all service logs
fd -e jsonl . /var/log/services/ -x rg "\"req-abc-123\"" {}

# Build a timeline for a single request
fd -e jsonl . /var/log/services/ -x rg "\"req-abc-123\"" {} \; | jq -sc 'sort_by(.timestamp)[] | [.timestamp, .service, .event] | @tsv'
```

### By Timestamp Window

```bash
# Find events within 2 seconds of a known event
# First get the target timestamp
TARGET="2026-03-08T14:23:15"
jq -c --arg t "$TARGET" '
  select(
    .timestamp > ($t | sub("15$"; "13")) and
    .timestamp < ($t | sub("15$"; "17"))
  )
' other-service.jsonl
```

### By Session/User

```bash
# Reconstruct a user session across log files
fd -e jsonl . /var/log/ -x rg "\"user-42\"" {} \; |
  jq -sc 'sort_by(.timestamp)[] | [.timestamp, .service, .action] | @tsv'
```

## Large File Strategies

### Search Recent Only

```bash
# Last 10,000 lines (fast for append-only logs)
tail -n 10000 huge.log | rg "pattern"

# Last N lines of JSONL with structured extraction
tail -n 5000 huge.jsonl | jq -c 'select(.level == "error")'
```

### Split for Parallel Processing

```bash
# Split into 100K-line chunks
split -l 100000 huge.jsonl /tmp/chunk_

# Process in parallel
fd 'chunk_' /tmp/ -x jq -c 'select(.level == "error")' {} > errors.jsonl

# With GNU parallel
split -l 100000 huge.jsonl /tmp/chunk_
ls /tmp/chunk_* | parallel 'jq -c "select(.level == \"error\")" {} >> /tmp/errors.jsonl'
```

### Streaming for Huge Single JSON

```bash
# SAX-style processing of a huge JSON array
jq --stream 'select(.[0][0] == "results" and .[0][-1] == "status") | .[1]' huge.json

# Extract items from a huge array without loading all
jq -cn --stream 'fromstream(1 | truncate_stream(inputs))' huge-array.json
```

### Two-Stage Always

```bash
# ALWAYS faster: rg filters text, jq parses survivors
rg '"error"' huge.jsonl | jq -r '.message'

# vs. SLOW: jq reads and parses every line
jq -r 'select(.level == "error") | .message' huge.jsonl
```

## Search Across Directories

### Multi-Directory Patterns

```bash
# Find all JSONL files with errors across trial directories
fd -e jsonl . trials/ -x rg -l '"error"' {}

# Count errors per log file across directories
fd -e jsonl . trials/ -x bash -c 'echo "$(rg -c "\"error\"" "$1" 2>/dev/null || echo 0) $1"' _ {}

# Extract and aggregate across directories
fd -e jsonl . trials/ -x jq -c 'select(.level == "error") | {file: input_filename, msg: .message}' {}

# Build summary table from multiple runs
for dir in trials/*/; do
  total=$(wc -l < "$dir/results.jsonl")
  errors=$(rg -c '"error"' "$dir/results.jsonl" 2>/dev/null || echo 0)
  echo -e "$dir\t$total\t$errors"
done | column -t -N DIR,TOTAL,ERRORS
```

## Common Gotchas

| Gotcha | Why It Hurts | Fix |
|--------|-------------|-----|
| `jq -s` on huge files loads everything into memory | OOM crash or swap thrashing on files over ~500MB | Use streaming: `rg` prefilter, `jq --stream`, or `split` + parallel |
| JSONL with embedded newlines in string values | Line-by-line tools (rg, awk, head) split a single record across lines | Use `jq -c` to re-compact, or `jq -R 'fromjson?'` to skip malformed lines |
| rg matches JSON keys, not just values | `rg "error"` matches `{"error_count": 0}` which is not an error | Use `rg '"level":"error"'` or pipe to `jq 'select(.level == "error")'` |
| Timezone mismatches in timestamp comparisons | Events appear out of order or time ranges miss data | Normalize to UTC before comparing: `jq '.timestamp |= sub("\\+.*"; "Z")'` |
| Unicode and escape sequences in log messages | jq chokes on invalid UTF-8 or double-escaped strings | Prefilter with `rg -a` (binary mode), or use `jq -R` for raw strings |
| Inconsistent JSON schemas across log lines | `jq` errors on lines missing expected fields | Use `//` operator for defaults: `.field // "missing"` and `?` for optional: `.arr[]?` |
| Forgetting `-c` flag with jq on JSONL | jq pretty-prints each line, output is no longer valid JSONL | Always use `jq -c` when output feeds into another JSONL consumer |
| tail -f with jq buffering | Output appears delayed or not at all | Use `jq --unbuffered` or `stdbuf -oL jq` |
| Sorting JSONL by timestamp without slurp | `sort` command does lexicographic sort on whole lines, not by field | Either `jq -sc 'sort_by(.timestamp)[]'` or extract timestamp prefix first |
| Assuming log files are complete | Logs may be rotated, compressed, or still being written | Check for `.gz` rotated files: `fd -e gz . /var/log/ -x zcat {} \| rg pattern` |
| Single quotes in jq on Windows | PowerShell/cmd do not handle single quotes the same as bash | Use double quotes with escaped inner quotes, or write jq filter to a file |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/jsonl-patterns.md` | JSONL extraction, aggregation, transformation, comparison, and performance patterns | ~700 |
| `references/analysis-workflows.md` | Agent conversation analysis, application log analysis, benchmark result parsing, cross-directory workflows | ~600 |
| `references/tool-setup.md` | Installation and configuration for jq, lnav, angle-grinder, rg, awk, GNU parallel, Miller | ~450 |

## See Also

- **data-processing** -- JSON/YAML/TOML processing with jq and yq
- **debug-ops** -- Systematic debugging methodology, log-based debugging section
- **monitoring-ops** -- Production observability, alerting, dashboards
- **file-search** -- Finding files with fd, searching code with rg
