# JSONL Patterns Reference

Comprehensive patterns for working with JSONL (JSON Lines) files -- one JSON object per line, the dominant format for structured logs, agent conversation records, and streaming data.

## JSONL Basics

### Format Rules

- One valid JSON object per line
- No trailing commas between lines
- No wrapping array or outer object
- Each line is independently parseable
- Newlines within string values must be escaped as `\n`

### Streaming vs Slurp

```bash
# STREAMING (default): processes one line at a time, constant memory
jq -c 'select(.level == "error")' app.jsonl

# SLURP (-s): loads ALL lines into a single array, requires memory for entire file
jq -sc 'group_by(.level)' app.jsonl

# Rule of thumb:
#   File < 100MB  --> slurp is fine
#   File 100MB-1GB --> slurp with caution, prefer streaming + sort/uniq
#   File > 1GB    --> never slurp, use streaming or split+parallel
```

### Key jq Flags for JSONL

| Flag | Purpose | Example |
|------|---------|---------|
| `-c` | Compact output (one line per object) | `jq -c '.' file.jsonl` |
| `-r` | Raw string output (no quotes) | `jq -r '.message' file.jsonl` |
| `-s` | Slurp all lines into array | `jq -s 'length' file.jsonl` |
| `-e` | Exit with error if output is false/null | `jq -e '.status == 200' line.json` |
| `-R` | Read each line as raw string | `jq -R 'fromjson? // empty' messy.jsonl` |
| `--stream` | SAX-style path/value pairs | `jq --stream '.' huge.json` |
| `--slurpfile` | Load a file as variable | `jq --slurpfile ids ids.json 'select(.id | IN($ids[][]))' data.jsonl` |
| `--arg` | Pass string variable | `jq --arg name "foo" 'select(.name == $name)' data.jsonl` |
| `--argjson` | Pass JSON variable | `jq --argjson min 100 'select(.count > $min)' data.jsonl` |
| `--unbuffered` | Flush output after each line | `tail -f app.jsonl \| jq --unbuffered -r '.message'` |

---

## Extraction Patterns

### Select by Field Value

```bash
# Exact match
jq -c 'select(.level == "error")' app.jsonl

# Numeric comparison
jq -c 'select(.status >= 400)' app.jsonl

# String contains
jq -c 'select(.message | test("timeout"))' app.jsonl

# Regex match
jq -c 'select(.path | test("^/api/v[0-9]+/users"))' app.jsonl

# Case-insensitive match
jq -c 'select(.message | test("error"; "i"))' app.jsonl

# Null check
jq -c 'select(.error != null)' app.jsonl

# Boolean field
jq -c 'select(.retry == true)' app.jsonl
```

### Select by Nested Field

```bash
# Dot notation for nesting
jq -c 'select(.request.method == "POST")' app.jsonl

# Deep nesting
jq -c 'select(.context.user.role == "admin")' app.jsonl

# Safe navigation (no error if path missing)
jq -c 'select(.request?.headers?["authorization"] != null)' app.jsonl
```

### Select by Array Contains

```bash
# Array contains value
jq -c 'select(.tags | index("critical"))' app.jsonl

# Any element matches condition
jq -c 'select(.events | any(.type == "error"))' app.jsonl

# All elements match condition
jq -c 'select(.checks | all(.passed == true))' app.jsonl

# Array length
jq -c 'select((.retries | length) > 3)' app.jsonl
```

### Extract and Flatten Nested Structures

```bash
# Flatten one level of nesting
jq -c '{timestamp, level, msg: .message, user: .context.user.id}' app.jsonl

# Explode array into separate lines
jq -c '.events[]' app.jsonl

# Flatten array with parent context
jq -c '. as $parent | .events[] | {request_id: $parent.request_id, event: .type, ts: .timestamp}' app.jsonl

# Extract from array of objects
jq -c '.results[] | select(.score < 0.5) | {name, score}' results.jsonl

# Recursive descent (find all values for a key at any depth)
jq -c '.. | .error_message? // empty' app.jsonl
```

### Handle Optional and Nullable Fields

```bash
# Default value for missing field
jq -r '.region // "unknown"' app.jsonl

# Default for nested missing field
jq -r '.response.body.error // .response.status_text // "no error info"' app.jsonl

# Skip lines where field is missing (instead of outputting null)
jq -r '.optional_field // empty' app.jsonl

# Coalesce multiple possible fields
jq -r '(.error_message // .err_msg // .error // "none")' app.jsonl

# Type check before access
jq -c 'if .data | type == "array" then .data | length else 0 end' app.jsonl
```

### Multi-Level Nesting (Agent Conversation Logs)

```bash
# Claude Code conversation logs have deeply nested tool calls
# Structure: {role, content: [{type: "tool_use", name, input}, ...]}

# Extract all tool call names
jq -c '.content[]? | select(.type == "tool_use") | .name' conversation.jsonl

# Extract tool inputs
jq -c '.content[]? | select(.type == "tool_use") | {tool: .name, input: .input}' conversation.jsonl

# Extract text content blocks
jq -r '.content[]? | select(.type == "text") | .text' conversation.jsonl

# Extract tool results
jq -c '.content[]? | select(.type == "tool_result") | {tool_use_id, content}' conversation.jsonl

# Find tool calls that contain specific patterns in their input
jq -c '.content[]? | select(.type == "tool_use" and (.input | tostring | test("SELECT")))' conversation.jsonl
```

### De-Escape Nested JSON Strings

```bash
# When a field contains a JSON string that needs parsing
jq -c '.payload | fromjson' app.jsonl

# Safe de-escape (skip if not valid JSON)
jq -c '.payload | fromjson? // {raw: .}' app.jsonl

# Double-escaped JSON (escaped twice)
jq -c '.data | fromjson | fromjson' app.jsonl

# Extract field from de-escaped nested JSON
jq -r '.payload | fromjson | .result.status' app.jsonl

# Handle mixed escaped/unescaped
jq -c 'if (.payload | type) == "string" then .payload | fromjson else .payload end' app.jsonl
```

---

## Aggregation Patterns

All aggregation patterns use `-s` (slurp) which loads the entire file into memory. For large files, prefilter with `rg` first.

### Count by Field Value

```bash
# Count per level
jq -sc 'group_by(.level) | map({level: .[0].level, count: length})' app.jsonl

# Count per status code
jq -sc 'group_by(.status) | map({status: .[0].status, count: length}) | sort_by(-.count)' app.jsonl

# Count unique values
jq -sc '[.[].user_id] | unique | length' app.jsonl

# Frequency distribution
jq -rsc 'group_by(.level) | map("\(.[0].level)\t\(length)") | .[]' app.jsonl
```

### Sum, Average, Min, Max

```bash
# Sum
jq -sc 'map(.bytes) | add' app.jsonl

# Average
jq -sc 'map(.duration_ms) | add / length' app.jsonl

# Min and max
jq -sc 'map(.duration_ms) | {min: min, max: max, avg: (add / length)}' app.jsonl

# Percentile approximation (p50, p95, p99)
jq -sc '
  map(.duration_ms) | sort |
  length as $n |
  {
    p50: .[($n * 0.50 | floor)],
    p95: .[($n * 0.95 | floor)],
    p99: .[($n * 0.99 | floor)],
    max: .[-1]
  }
' app.jsonl

# Sum grouped by category
jq -sc '
  group_by(.service) |
  map({service: .[0].service, total_bytes: (map(.bytes) | add)})
' app.jsonl
```

### Group By with Aggregation

```bash
# Group by service, show count and error rate
jq -sc '
  group_by(.service) |
  map({
    service: .[0].service,
    total: length,
    errors: (map(select(.level == "error")) | length),
    error_rate: ((map(select(.level == "error")) | length) / length * 100 | round)
  })
' app.jsonl

# Group by hour
jq -sc '
  group_by(.timestamp | split("T")[1] | split(":")[0]) |
  map({
    hour: .[0].timestamp | split("T")[1] | split(":")[0],
    count: length
  })
' app.jsonl

# Nested group by (service then level)
jq -sc '
  group_by(.service) |
  map({
    service: .[0].service,
    by_level: (group_by(.level) | map({level: .[0].level, n: length}))
  })
' app.jsonl
```

### Top-N Queries

```bash
# Top 10 slowest requests
jq -sc 'sort_by(-.duration_ms) | .[:10] | .[] | {path: .path, ms: .duration_ms}' app.jsonl

# Top 5 most frequent errors
jq -sc '
  map(select(.level == "error")) |
  group_by(.message) |
  map({message: .[0].message, count: length}) |
  sort_by(-.count) | .[:5]
' app.jsonl

# Top users by request count
jq -sc '
  group_by(.user_id) |
  map({user: .[0].user_id, requests: length}) |
  sort_by(-.requests) | .[:10]
' app.jsonl
```

### Histogram and Distribution Analysis

```bash
# Response time histogram (buckets: 0-100, 100-500, 500-1000, 1000+)
jq -sc '
  map(.duration_ms) |
  {
    "0-100ms": (map(select(. < 100)) | length),
    "100-500ms": (map(select(. >= 100 and . < 500)) | length),
    "500-1000ms": (map(select(. >= 500 and . < 1000)) | length),
    "1000ms+": (map(select(. >= 1000)) | length)
  }
' app.jsonl

# Status code distribution
jq -rsc '
  group_by(.status) |
  map("\(.[0].status)\t\(length)") |
  sort | .[]
' app.jsonl

# Log level distribution over time (by hour)
jq -rsc '
  group_by(.timestamp | split("T")[1] | split(":")[0]) |
  map(
    (.[0].timestamp | split("T")[1] | split(":")[0]) as $hour |
    {
      hour: $hour,
      info: (map(select(.level == "info")) | length),
      warn: (map(select(.level == "warn")) | length),
      error: (map(select(.level == "error")) | length)
    }
  ) | .[] | [.hour, .info, .warn, .error] | @tsv
' app.jsonl | column -t -N HOUR,INFO,WARN,ERROR
```

### Running Totals and Cumulative Sums

```bash
# Cumulative error count over time
jq -sc '
  sort_by(.timestamp) |
  reduce .[] as $item (
    {total: 0, rows: []};
    .total += 1 |
    .rows += [{ts: $item.timestamp, cumulative: .total}]
  ) | .rows[] | [.ts, .cumulative] | @tsv
' <(jq -c 'select(.level == "error")' app.jsonl)

# Running average of response times
jq -sc '
  sort_by(.timestamp) |
  foreach .[] as $item (
    {n: 0, sum: 0};
    .n += 1 | .sum += $item.duration_ms;
    {ts: $item.timestamp, running_avg: (.sum / .n | round)}
  )
' app.jsonl
```

---

## Transformation Patterns

### Reshape Objects

```bash
# Flatten nested to flat
jq -c '{
  ts: .timestamp,
  level: .level,
  msg: .message,
  user: .context.user.id,
  method: .request.method,
  path: .request.path
}' app.jsonl

# Add computed fields
jq -c '. + {
  date: (.timestamp | split("T")[0]),
  hour: (.timestamp | split("T")[1] | split(":")[0] | tonumber),
  is_error: (.level == "error")
}' app.jsonl

# Rename fields
jq -c '{timestamp: .ts, message: .msg, severity: .lvl}' app.jsonl

# Remove fields
jq -c 'del(.stack_trace, .internal_debug_info)' app.jsonl
```

### Merge Fields from Multiple Lines

```bash
# Combine start and end events by request_id
jq -sc '
  group_by(.request_id) |
  map(
    (map(select(.event == "start")) | .[0]) as $start |
    (map(select(.event == "end")) | .[0]) as $end |
    {
      request_id: .[0].request_id,
      start: $start.timestamp,
      end: $end.timestamp,
      status: $end.status,
      path: $start.path
    }
  )[]
' events.jsonl

# Merge consecutive lines (e.g., multiline log entries)
jq -sc '
  reduce .[] as $item (
    [];
    if (. | length) == 0 then [$item]
    elif $item.continuation == true then
      (.[-1].message += "\n" + $item.message) | .
    else . + [$item]
    end
  )[]
' app.jsonl
```

### Convert Between Formats

```bash
# JSONL to CSV
jq -r '[.timestamp, .level, .message] | @csv' app.jsonl > app.csv

# JSONL to TSV
jq -r '[.timestamp, .level, .message] | @tsv' app.jsonl > app.tsv

# JSONL to CSV with header
echo "timestamp,level,message" > app.csv
jq -r '[.timestamp, .level, .message] | @csv' app.jsonl >> app.csv

# CSV to JSONL (using mlr)
mlr --c2j cat app.csv > app.jsonl

# JSONL to formatted table
jq -r '[.timestamp, .level, .message] | @tsv' app.jsonl | column -t -s$'\t'

# JSONL to markdown table
echo "| Timestamp | Level | Message |"
echo "|-----------|-------|---------|"
jq -r '"| \(.timestamp) | \(.level) | \(.message) |"' app.jsonl
```

### Annotate Lines with Computed Fields

```bash
# Add line number
jq -c --argjson n 0 '. + {line_num: (input_line_number)}' app.jsonl

# Add duration since previous event (requires slurp)
jq -sc '
  sort_by(.timestamp) |
  . as $all |
  [range(length)] |
  map(
    $all[.] + (
      if . > 0 then {gap_from_prev: "computed"}
      else {gap_from_prev: null}
      end
    )
  )[]
' app.jsonl

# Tag lines matching criteria
jq -c '. + {
  severity_class: (
    if .level == "error" or .level == "fatal" then "critical"
    elif .level == "warn" then "warning"
    else "normal"
    end
  )
}' app.jsonl

# Enrich with filename when processing multiple files
fd -e jsonl . logs/ -x bash -c 'jq -c --arg src "$1" ". + {source: \$src}" "$1"' _ {}
```

---

## Comparison Patterns

### Diff Two JSONL Files by Matching Key

```bash
# Find entries in A but not in B (by id)
jq -r '.id' b.jsonl | sort > /tmp/b_ids.txt
jq -c --slurpfile bids <(jq -Rs 'split("\n") | map(select(. != ""))' /tmp/b_ids.txt) '
  select(.id | IN($bids[0][]))  | not
' a.jsonl

# Simpler approach using comm
jq -r '.id' a.jsonl | sort > /tmp/a_ids.txt
jq -r '.id' b.jsonl | sort > /tmp/b_ids.txt
comm -23 /tmp/a_ids.txt /tmp/b_ids.txt  # IDs in A but not B
comm -13 /tmp/a_ids.txt /tmp/b_ids.txt  # IDs in B but not A
comm -12 /tmp/a_ids.txt /tmp/b_ids.txt  # IDs in both

# Find records that exist in both but have different values
jq -sc '
  [., input] |
  (.[0] | map({(.id): .}) | add) as $a |
  (.[1] | map({(.id): .}) | add) as $b |
  ($a | keys) as $keys |
  [$keys[] | select($a[.] != $b[.])] |
  map({id: ., a: $a[.], b: $b[.]})
' <(jq -sc '.' a.jsonl) <(jq -sc '.' b.jsonl)
```

### Side-by-Side Field Comparison

```bash
# Compare a specific field between two runs
paste <(jq -r '[.id, .score] | @tsv' run1.jsonl | sort) \
      <(jq -r '[.id, .score] | @tsv' run2.jsonl | sort) |
  awk -F'\t' '$2 != $4 {print $1, "run1=" $2, "run2=" $4}'

# Summary comparison of two log files
echo "=== File A ===" && jq -sc '{
  lines: length,
  errors: (map(select(.level == "error")) | length),
  unique_users: ([.[].user_id] | unique | length)
}' a.jsonl
echo "=== File B ===" && jq -sc '{
  lines: length,
  errors: (map(select(.level == "error")) | length),
  unique_users: ([.[].user_id] | unique | length)
}' b.jsonl
```

### Find New, Missing, and Changed Records

```bash
# Comprehensive diff report
jq -r '.id' a.jsonl | sort > /tmp/a.ids
jq -r '.id' b.jsonl | sort > /tmp/b.ids

echo "--- New in B (not in A) ---"
comm -13 /tmp/a.ids /tmp/b.ids

echo "--- Removed from A (not in B) ---"
comm -23 /tmp/a.ids /tmp/b.ids

echo "--- Changed (in both, different values) ---"
comm -12 /tmp/a.ids /tmp/b.ids | while read id; do
  a_hash=$(rg "\"id\":\"$id\"" a.jsonl | md5sum | cut -d' ' -f1)
  b_hash=$(rg "\"id\":\"$id\"" b.jsonl | md5sum | cut -d' ' -f1)
  [ "$a_hash" != "$b_hash" ] && echo "$id"
done
```

---

## Performance Patterns

### Two-Stage rg + jq Pipeline

The single most important performance pattern. ripgrep is 10-100x faster than jq at scanning text.

```bash
# BAD: jq scans every line (slow on large files)
jq -c 'select(.level == "error" and .service == "auth")' huge.jsonl

# GOOD: rg filters text first, jq only parses matching lines
rg '"error"' huge.jsonl | rg '"auth"' | jq -c '.'

# GOOD: for precise matching after rg prefilter
rg '"error"' huge.jsonl | jq -c 'select(.level == "error" and .service == "auth")'

# Benchmarks (typical 1GB JSONL file):
#   jq alone:     45 seconds
#   rg + jq:      3 seconds
#   rg alone:     0.8 seconds
```

### GNU parallel for Splitting Large Files

```bash
# Split a 10GB file and process in parallel
split -l 500000 huge.jsonl /tmp/chunk_

# Count errors across all chunks
ls /tmp/chunk_* | parallel "rg -c '\"error\"' {}" | awk -F: '{sum+=$2} END {print sum}'

# Extract and merge results
ls /tmp/chunk_* | parallel "jq -c 'select(.level == \"error\")' {}" > all_errors.jsonl

# Cleanup
rm /tmp/chunk_*

# One-liner with process substitution
parallel --pipe -L 100000 'jq -c "select(.level == \"error\")"' < huge.jsonl > errors.jsonl
```

### jq --stream for SAX-Style Processing

For files too large to fit in memory, even line-by-line (e.g., a single 5GB JSON array).

```bash
# Count items in a huge JSON array without loading it
jq --stream 'select(.[0] | length == 1) | .[0][0]' huge-array.json | tail -1

# Extract specific field from each item in huge array
jq -cn --stream 'fromstream(1 | truncate_stream(inputs)) | .name' huge-array.json

# Filter items from huge array
jq -cn --stream '
  fromstream(1 | truncate_stream(inputs)) |
  select(.status == "failed")
' huge-array.json
```

### Indexing Frequently-Queried Files

```bash
# Build an index of line offsets by key value
awk '{
  match($0, /"request_id":"([^"]+)"/, m)
  if (m[1]) print m[1], NR
}' app.jsonl | sort > app.idx

# Look up specific request by index
LINE=$(grep "req-abc-123" app.idx | awk '{print $2}')
sed -n "${LINE}p" app.jsonl | jq .

# Build a SQLite index for repeated queries
sqlite3 log_index.db "CREATE TABLE idx (request_id TEXT, line INTEGER)"
awk '{
  match($0, /"request_id":"([^"]+)"/, m)
  if (m[1]) print "INSERT INTO idx VALUES (\047" m[1] "\047, " NR ");"
}' app.jsonl | sqlite3 log_index.db

# Query by index
LINE=$(sqlite3 log_index.db "SELECT line FROM idx WHERE request_id = 'req-abc-123'")
sed -n "${LINE}p" app.jsonl | jq .
```

### Memory-Efficient Aggregation Without Slurp

```bash
# Count by level without loading entire file
jq -r '.level' app.jsonl | sort | uniq -c | sort -rn

# Top error messages without slurp
jq -r 'select(.level == "error") | .message' app.jsonl | sort | uniq -c | sort -rn | head -20

# Unique users without slurp
jq -r '.user_id' app.jsonl | sort -u | wc -l

# Sum without slurp
jq -r '.bytes' app.jsonl | awk '{sum+=$1} END {print sum}'

# These are all O(1) memory (streaming) vs O(n) memory (slurp)
```
