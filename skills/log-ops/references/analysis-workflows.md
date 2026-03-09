# Analysis Workflows Reference

Practical end-to-end workflows for common log analysis tasks. Each workflow is self-contained with commands you can copy and adapt.

---

## Agent Conversation Log Analysis

Claude Code and other AI agents produce JSONL conversation logs with nested content blocks. These workflows extract actionable information from those logs.

### Extract All Tool Calls

```bash
# List every tool call in chronological order
jq -c '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use") |
  {tool: .name, id: .id}
' conversation.jsonl

# Count tool usage frequency
jq -r '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use") | .name
' conversation.jsonl | sort | uniq -c | sort -rn

# Extract tool calls with their inputs (summarized)
jq -c '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use") |
  {
    tool: .name,
    input_preview: (.input | tostring | .[:100])
  }
' conversation.jsonl
```

### Identify What Code Was Written

```bash
# Find all Write tool calls and extract file paths
jq -r '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use" and .name == "Write") |
  .input.file_path
' conversation.jsonl

# Find all Edit tool calls with file paths and old/new strings
jq -c '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use" and .name == "Edit") |
  {file: .input.file_path, old: (.input.old_string | .[:60]), new: (.input.new_string | .[:60])}
' conversation.jsonl

# Find all Bash commands that were run
jq -r '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use" and .name == "Bash") |
  .input.command
' conversation.jsonl

# Files created vs modified
echo "=== Files Created (Write) ==="
jq -r 'select(.role == "assistant") | .content[]? | select(.type == "tool_use" and .name == "Write") | .input.file_path' conversation.jsonl | sort -u

echo "=== Files Modified (Edit) ==="
jq -r 'select(.role == "assistant") | .content[]? | select(.type == "tool_use" and .name == "Edit") | .input.file_path' conversation.jsonl | sort -u
```

### Find Error Messages and Repeated Attempts

```bash
# Find tool results that indicate errors
jq -c '
  select(.role == "tool") |
  .content[]? | select(.type == "text") |
  select(.text | test("error|Error|ERROR|failed|Failed|FAILED|exception|Exception"))  |
  {text_preview: (.text | .[:200])}
' conversation.jsonl

# Find retry patterns (same tool called multiple times with similar input)
jq -r '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use") |
  "\(.name)\t\(.input | tostring | .[:80])"
' conversation.jsonl | sort | uniq -c | sort -rn | head -20

# Count consecutive failures (same tool, error in result)
jq -sc '
  [to_entries[] |
    select(.value.role == "tool") |
    {idx: .key, has_error: (.value.content | tostring | test("error|Error|failed|Failed"))}
  ] |
  map(select(.has_error)) | length
' conversation.jsonl
```

### Calculate Phase Timings

```bash
# If messages have timestamps, calculate time between phases
jq -sc '
  map(select(.timestamp != null)) |
  sort_by(.timestamp) |
  . as $msgs |
  {
    total_messages: length,
    first: .[0].timestamp,
    last: .[-1].timestamp,
    tool_calls: [.[] | select(.role == "assistant") | .content[]? | select(.type == "tool_use")] | length,
    reading_ops: [.[] | select(.role == "assistant") | .content[]? | select(.type == "tool_use" and (.name == "Read" or .name == "Glob" or .name == "Grep"))] | length,
    writing_ops: [.[] | select(.role == "assistant") | .content[]? | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))] | length,
    bash_ops: [.[] | select(.role == "assistant") | .content[]? | select(.type == "tool_use" and .name == "Bash")] | length
  }
' conversation.jsonl

# Phase breakdown by sequential grouping
jq -c '
  select(.role == "assistant") |
  .content[]? | select(.type == "tool_use") |
  if .name == "Read" or .name == "Glob" or .name == "Grep" then "READING"
  elif .name == "Write" or .name == "Edit" then "WRITING"
  elif .name == "Bash" then "EXECUTING"
  else "OTHER"
  end
' conversation.jsonl | uniq -c
```

### Extract Thinking Blocks and Reasoning

```bash
# Extract thinking/reasoning content
jq -r '
  select(.role == "assistant") |
  .content[]? | select(.type == "thinking") |
  .thinking
' conversation.jsonl

# Extract text responses (non-tool, non-thinking)
jq -r '
  select(.role == "assistant") |
  .content[]? | select(.type == "text") |
  .text
' conversation.jsonl

# Summary of assistant responses
jq -c '
  select(.role == "assistant") |
  {
    has_thinking: (.content | any(.type == "thinking")),
    has_text: (.content | any(.type == "text")),
    tool_calls: [.content[]? | select(.type == "tool_use") | .name]
  }
' conversation.jsonl
```

### Build a Timeline of Actions

```bash
# Full action timeline
jq -r '
  if .role == "user" then
    "USER: " + (.content | if type == "string" then .[:100] else (.[] | select(.type == "text") | .text | .[:100]) end)
  elif .role == "assistant" then
    (.content[]? |
      if .type == "tool_use" then "TOOL: " + .name + " " + (.input | tostring | .[:80])
      elif .type == "text" then "TEXT: " + (.text | .[:100])
      else empty
      end
    )
  elif .role == "tool" then
    "RESULT: " + (.content | tostring | .[:100])
  else empty
  end
' conversation.jsonl

# Condensed timeline (just tool calls and results)
jq -c '
  if .role == "assistant" then
    .content[]? | select(.type == "tool_use") | {action: "call", tool: .name}
  elif .role == "tool" then
    {action: "result", success: (.content | tostring | test("error|Error|failed") | not)}
  else empty
  end
' conversation.jsonl
```

---

## Application Log Analysis

### Error Rate Over Time

```bash
# Errors per minute
jq -r 'select(.level == "error") | .timestamp | .[:16]' app.jsonl |
  sort | uniq -c

# Errors per hour with total context
jq -rsc '
  group_by(.timestamp | .[:13]) |
  map({
    hour: .[0].timestamp | .[:13],
    total: length,
    errors: (map(select(.level == "error")) | length)
  }) |
  map("\(.hour)\t\(.total)\t\(.errors)\t\(.errors * 100 / .total | round)%") |
  .[]
' app.jsonl | column -t -N HOUR,TOTAL,ERRORS,RATE

# Error rate spike detection (>2x average)
jq -sc '
  group_by(.timestamp | .[:13]) |
  map({hour: .[0].timestamp | .[:13], errors: (map(select(.level == "error")) | length)}) |
  (map(.errors) | add / length) as $avg |
  map(select(.errors > ($avg * 2))) |
  map("\(.hour): \(.errors) errors (avg: \($avg | round))")[]
' app.jsonl
```

### Slow Request Identification

```bash
# Top 20 slowest requests
jq -sc '
  sort_by(-.duration_ms) | .[:20] |
  .[] | [.timestamp, .method, .path, "\(.duration_ms)ms"] | @tsv
' app.jsonl | column -t

# Slow requests by endpoint (p95)
jq -sc '
  group_by(.path) |
  map({
    path: .[0].path,
    count: length,
    p50: (map(.duration_ms) | sort | .[length * 0.5 | floor]),
    p95: (map(.duration_ms) | sort | .[length * 0.95 | floor]),
    p99: (map(.duration_ms) | sort | .[length * 0.99 | floor])
  }) |
  sort_by(-.p95) | .[:10]
' app.jsonl

# Requests exceeding SLA (e.g., 500ms)
jq -c 'select(.duration_ms > 500) | {path, duration_ms, timestamp}' app.jsonl |
  jq -rsc 'group_by(.path) | map({path: .[0].path, count: length, worst: (map(.duration_ms) | max)}) | sort_by(-.count) | .[] | [.path, .count, .worst] | @tsv' |
  column -t -N ENDPOINT,SLA_VIOLATIONS,WORST_MS
```

### Error Correlation

```bash
# Which errors occur together in the same time window?
jq -rsc '
  map(select(.level == "error")) |
  group_by(.timestamp | .[:16]) |
  map(select(length > 1)) |
  map([.[].message] | unique | sort) |
  group_by(.) |
  map({errors: .[0], co_occurrences: length}) |
  sort_by(-.co_occurrences) | .[:10]
' app.jsonl

# Errors that always precede another error
jq -rsc '
  map(select(.level == "error")) |
  sort_by(.timestamp) |
  [range(1; length) | {before: .[. - 1].message, after: .[.].message}] |
  group_by([.before, .after]) |
  map({sequence: .[0], count: length}) |
  sort_by(-.count) | .[:10]
' app.jsonl

# Error clusters (errors within 5 seconds of each other)
jq -rsc '
  map(select(.level == "error")) |
  sort_by(.timestamp) |
  . as $errs |
  [range(1; length) |
    select(
      (($errs[.].ts_epoch // 0) - ($errs[. - 1].ts_epoch // 0)) < 5
    ) |
    {ts: $errs[.].timestamp, msg: $errs[.].message}
  ]
' app.jsonl
```

### User Session Reconstruction

```bash
# Reconstruct a single user session
jq -c 'select(.user_id == "user-42")' app.jsonl |
  jq -sc 'sort_by(.timestamp) | .[] | [.timestamp, .action, .path // .event] | @tsv' |
  column -t

# Session summary for all users
jq -sc '
  group_by(.user_id) |
  map({
    user: .[0].user_id,
    events: length,
    first_seen: (sort_by(.timestamp) | .[0].timestamp),
    last_seen: (sort_by(.timestamp) | .[-1].timestamp),
    unique_actions: ([.[].action] | unique | length),
    errors: (map(select(.level == "error")) | length)
  }) |
  sort_by(-.events)
' app.jsonl

# User journey (sequence of page views)
jq -r 'select(.user_id == "user-42" and .event == "page_view") | .path' app.jsonl
```

### Deployment Impact Analysis

```bash
# Compare error rates before and after deployment
DEPLOY_TIME="2026-03-08T14:30:00"

echo "=== Before Deployment ==="
jq -c --arg t "$DEPLOY_TIME" 'select(.timestamp < $t)' app.jsonl |
  jq -sc '{total: length, errors: (map(select(.level == "error")) | length)}'

echo "=== After Deployment ==="
jq -c --arg t "$DEPLOY_TIME" 'select(.timestamp >= $t)' app.jsonl |
  jq -sc '{total: length, errors: (map(select(.level == "error")) | length)}'

# New error types after deployment
BEFORE=$(jq -r --arg t "$DEPLOY_TIME" 'select(.timestamp < $t and .level == "error") | .message' app.jsonl | sort -u)
AFTER=$(jq -r --arg t "$DEPLOY_TIME" 'select(.timestamp >= $t and .level == "error") | .message' app.jsonl | sort -u)
comm -13 <(echo "$BEFORE") <(echo "$AFTER")

# Response time comparison
echo "=== Response Times Before ==="
jq -sc --arg t "$DEPLOY_TIME" '
  map(select(.timestamp < $t and .duration_ms != null)) |
  {avg: (map(.duration_ms) | add / length | round), p95: (map(.duration_ms) | sort | .[length * 0.95 | floor])}
' app.jsonl

echo "=== Response Times After ==="
jq -sc --arg t "$DEPLOY_TIME" '
  map(select(.timestamp >= $t and .duration_ms != null)) |
  {avg: (map(.duration_ms) | add / length | round), p95: (map(.duration_ms) | sort | .[length * 0.95 | floor])}
' app.jsonl
```

---

## Benchmark and Test Result Analysis

### Parse Structured Test Results

```bash
# CTRF JSON format (Common Test Report Format)
jq -r '.results.tests[] | select(.status == "failed") | [.name, .message // "no message"] | @tsv' ctrf-report.json

# CTRF summary
jq '{
  total: .results.summary.tests,
  passed: .results.summary.passed,
  failed: .results.summary.failed,
  skipped: .results.summary.skipped,
  duration: "\(.results.summary.duration)ms"
}' ctrf-report.json

# JUnit XML (convert to JSON first with xq or yq)
yq -p xml '.testsuites.testsuite.testcase[] | select(.failure != null) | ."+@name"' junit-results.xml

# TAP (Test Anything Protocol) - extract failures
rg "^not ok" test-output.tap | sd 'not ok \d+ - ' ''
```

### Compare Pass/Fail Rates Across Runs

```bash
# Compare multiple CTRF reports
for report in results/*/ctrf-report.json; do
  dir=$(dirname "$report" | xargs basename)
  passed=$(jq '.results.summary.passed' "$report")
  failed=$(jq '.results.summary.failed' "$report")
  total=$(jq '.results.summary.tests' "$report")
  echo -e "$dir\t$passed\t$failed\t$total"
done | column -t -N RUN,PASSED,FAILED,TOTAL

# Find tests that regressed (passed before, fail now)
jq -r '.results.tests[] | select(.status == "passed") | .name' run1/ctrf-report.json | sort > /tmp/passed_before.txt
jq -r '.results.tests[] | select(.status == "failed") | .name' run2/ctrf-report.json | sort > /tmp/failed_after.txt
comm -12 /tmp/passed_before.txt /tmp/failed_after.txt

# Flaky test detection (tests that flip between runs)
for report in results/*/ctrf-report.json; do
  jq -r '.results.tests[] | "\(.name)\t\(.status)"' "$report"
done | sort | awk -F'\t' '
  {status[$1] = status[$1] " " $2}
  END {
    for (test in status) {
      if (status[test] ~ /passed/ && status[test] ~ /failed/) {
        print "FLAKY:", test, status[test]
      }
    }
  }
'
```

### Performance Regression Detection

```bash
# Compare timing data between runs
jq -sc '[.[] | {name: .name, duration: .duration}]' run1/results.jsonl > /tmp/run1_times.json
jq -sc '[.[] | {name: .name, duration: .duration}]' run2/results.jsonl > /tmp/run2_times.json

# Find tests that got significantly slower (>20% regression)
jq -sc '
  [., input] |
  (.[0] | map({(.name): .duration}) | add) as $before |
  (.[1] | map({(.name): .duration}) | add) as $after |
  [$before | keys[] |
    select($after[.] != null) |
    {
      name: .,
      before: $before[.],
      after: $after[.],
      change_pct: (($after[.] - $before[.]) / $before[.] * 100 | round)
    } |
    select(.change_pct > 20)
  ] |
  sort_by(-.change_pct)
' /tmp/run1_times.json /tmp/run2_times.json

# Aggregate metrics across trial directories
for dir in trials/trial-*/; do
  trial=$(basename "$dir")
  if [ -f "$dir/metrics.jsonl" ]; then
    avg=$(jq -sc 'map(.duration) | add / length | round' "$dir/metrics.jsonl")
    p95=$(jq -sc 'map(.duration) | sort | .[length * 0.95 | floor]' "$dir/metrics.jsonl")
    echo -e "$trial\t$avg\t$p95"
  fi
done | column -t -N TRIAL,AVG_MS,P95_MS
```

### Aggregate Metrics Across Trial Directories

```bash
# Build summary from multiple benchmark runs
fd -t d 'trial-' trials/ -x bash -c '
  trial=$(basename "$1")
  if [ -f "$1/results.jsonl" ]; then
    total=$(wc -l < "$1/results.jsonl")
    passed=$(jq -c "select(.passed == true)" "$1/results.jsonl" | wc -l)
    failed=$((total - passed))
    echo -e "$trial\t$total\t$passed\t$failed"
  fi
' _ {} | sort | column -t -N TRIAL,TOTAL,PASSED,FAILED

# Combine all results into one file with trial label
fd -t d 'trial-' trials/ -x bash -c '
  trial=$(basename "$1")
  jq -c --arg trial "$trial" ". + {trial: \$trial}" "$1/results.jsonl"
' _ {} > combined_results.jsonl

# Then aggregate across all trials
jq -sc '
  group_by(.trial) |
  map({
    trial: .[0].trial,
    total: length,
    pass_rate: ((map(select(.passed == true)) | length) / length * 100 | round),
    avg_duration: (map(.duration) | add / length | round)
  }) |
  sort_by(.trial)
' combined_results.jsonl
```

---

## Cross-Directory Analysis

### Search Pattern Across All Log Directories

```bash
# Find which log files contain a specific error
fd -e jsonl -e log . /var/log/services/ -x rg -l "ConnectionTimeout" {}

# Count occurrences per directory
fd -e jsonl . logs/ -x bash -c '
  count=$(rg -c "error" "$1" 2>/dev/null || echo 0)
  echo -e "$(dirname "$1" | xargs basename)\t$(basename "$1")\t$count"
' _ {} | sort -t$'\t' -k3 -rn | column -t -N DIR,FILE,ERRORS

# Search for a pattern and show matching lines with source file
fd -e jsonl . logs/ -x bash -c '
  rg "\"error\"" "$1" 2>/dev/null | while read line; do
    echo "$1: $line"
  done
' _ {}
```

### Build Summary Table from Multiple Log Files

```bash
# Summary statistics per log file
echo -e "FILE\tLINES\tERRORS\tWARNS\tFIRST_TS\tLAST_TS"
fd -e jsonl . logs/ | while read f; do
  lines=$(wc -l < "$f")
  errors=$(rg -c '"error"' "$f" 2>/dev/null || echo 0)
  warns=$(rg -c '"warn"' "$f" 2>/dev/null || echo 0)
  first=$(head -1 "$f" | jq -r '.timestamp // "unknown"')
  last=$(tail -1 "$f" | jq -r '.timestamp // "unknown"')
  echo -e "$(basename "$f")\t$lines\t$errors\t$warns\t$first\t$last"
done | column -t

# Health check across all services
fd -e jsonl -d 1 . /var/log/services/ -x bash -c '
  svc=$(basename "$1" .jsonl)
  last_error=$(tac "$1" | jq -r "select(.level == \"error\") | .timestamp" 2>/dev/null | head -1)
  error_count=$(rg -c "\"error\"" "$1" 2>/dev/null || echo 0)
  echo -e "$svc\t$error_count\t${last_error:-none}"
' _ {} | sort | column -t -N SERVICE,ERRORS,LAST_ERROR
```

### Identify Common Failure Patterns Across Runs

```bash
# Extract all error messages across trial directories
fd -e jsonl . trials/ -x jq -r 'select(.level == "error") | .message' {} |
  sort | uniq -c | sort -rn | head -20

# Find which trials share the same failure
fd -e jsonl . trials/ -x bash -c '
  trial=$(echo "$1" | rg -o "trial-[^/]+")
  jq -r "select(.level == \"error\") | .message" "$1" 2>/dev/null |
    while read msg; do echo -e "$trial\t$msg"; done
' _ {} |
  sort -t$'\t' -k2 |
  awk -F'\t' '
    prev != $2 { if (NR > 1 && count > 1) print count, prev_msg, trials; count=0; trials="" }
    { count++; trials = trials " " $1; prev = $2; prev_msg = $2 }
    END { if (count > 1) print count, prev_msg, trials }
  ' | sort -rn | head -10

# Correlation: which errors appear together
fd -e jsonl . trials/ -x bash -c '
  trial=$(echo "$1" | rg -o "trial-[^/]+")
  errors=$(jq -r "select(.level == \"error\") | .message" "$1" 2>/dev/null | sort -u | paste -sd "|")
  [ -n "$errors" ] && echo -e "$trial\t$errors"
' _ {} | sort -t$'\t' -k2 | uniq -f1 -c | sort -rn
```

### fd + rg + jq Composition

```bash
# The canonical three-stage pipeline for multi-directory log analysis:
# 1. fd: find the files
# 2. rg: prefilter for speed
# 3. jq: structured extraction

# Example: find all timeout errors across services, extract details
fd -e jsonl . /var/log/ |                          # find log files
  xargs rg -l '"timeout"' |                        # filter to files with timeouts
  xargs -I{} jq -c '
    select(.message | test("timeout")) |
    {file: input_filename, ts: .timestamp, svc: .service, msg: .message}
  ' {}

# Example: aggregate error counts by service across all log directories
fd -e jsonl . /var/log/ -x rg -c '"error"' {} |    # count errors per file
  awk -F: '{
    split($1, parts, "/")
    svc = parts[length(parts)-1]
    gsub(/\.jsonl$/, "", svc)
    sum[svc] += $2
  }
  END { for (s in sum) print sum[s], s }' |
  sort -rn

# Example: find the most recent error across all services
fd -e jsonl . /var/log/ -x tail -1 {} |            # last line of each file
  jq -sc '
    map(select(.level == "error")) |
    sort_by(.timestamp) |
    .[-1] |
    {service: .service, timestamp: .timestamp, message: .message}
  '
```
