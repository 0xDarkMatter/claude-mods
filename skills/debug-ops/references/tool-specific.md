# Tool-Specific Debugging Reference

Detailed guides for debugging tools across languages and environments.

## Browser DevTools

### Elements Panel

```
Inspect and modify the DOM and CSS in real-time.

Key Operations:
├─ Right-click element → Inspect (jump to element in DOM tree)
├─ Ctrl+Shift+C: Pick element mode (click any element to inspect)
├─ Edit HTML: Double-click tag name, attribute, or text content
├─ Force element state: Right-click → Force state → :hover, :active, :focus
├─ Break on DOM changes: Right-click element → Break on → subtree/attribute/removal
└─ Computed tab: See final computed CSS values and which rule wins
```

CSS debugging workflow:

```
1. Inspect the element
2. Check Computed tab for the actual value
3. Look for strikethrough rules (overridden)
4. Check for specificity conflicts
5. Toggle rules on/off with checkboxes
6. Use the color picker, shadow editor, easing editor for visual tweaking
7. Changes persist until page reload (or use Overrides for persistence)
```

Event listener debugging:

```
Elements panel → Event Listeners tab
├─ Shows all listeners attached to selected element
├─ Check "Ancestors" to see inherited/delegated listeners
├─ Click filename link to jump to handler source code
├─ "Remove" button to detach a listener for testing
└─ Framework listeners: check "Framework listeners" to unwrap React/Vue
```

Accessibility inspection:

```
Elements panel → Accessibility tab
├─ ARIA role and computed properties
├─ Accessible name and description
├─ Keyboard focusability
└─ Color contrast ratio
```

### Console Panel

Essential console methods beyond `console.log`:

```javascript
// Structured data display
console.table(arrayOfObjects);               // Tabular format with sorting
console.table(arrayOfObjects, ['name','id']); // Show only specific columns

// Grouping related logs
console.group('Processing order #123');       // Collapsible group (open)
console.groupCollapsed('Details');            // Collapsible group (closed)
console.log('item count:', items.length);
console.groupEnd();
console.groupEnd();

// Timing operations
console.time('fetchUsers');
await fetchUsers();
console.timeEnd('fetchUsers');               // "fetchUsers: 142.3ms"

// Stack traces
console.trace('How did we get here?');       // Prints call stack

// Assertions (only logs on failure)
console.assert(user.age > 0, 'Invalid age:', user.age);

// Counting occurrences
console.count('render');                     // "render: 1", "render: 2", etc.
console.countReset('render');

// Styled output
console.log('%cIMPORTANT', 'color: red; font-size: 20px; font-weight: bold');

// Object with label
console.dir(domElement, { depth: 3 });       // Expandable object tree
```

Console utilities (only available in DevTools console, not in code):

```javascript
$0                    // Currently selected element in Elements panel
$_                    // Result of last expression
$('selector')         // document.querySelector shorthand
$$('selector')        // document.querySelectorAll as array
$x('//xpath')         // XPath query

copy(object)          // Copy object as JSON to clipboard
clear()               // Clear the console

// Monitor function calls
monitor(functionName) // Log every call with arguments
unmonitor(functionName)

// Monitor events on an element
monitorEvents($0, 'click')   // Log all click events on selected element
monitorEvents(window, 'resize')
unmonitorEvents($0, 'click')

// Get event listeners for an element
getEventListeners($0)

// Query objects by constructor
queryObjects(Promise)         // Find all Promise instances in heap
```

### Network Panel

```
Key Features:
├─ Filter by type: XHR, JS, CSS, Img, Media, Font, Doc, WS, Manifest
├─ Filter by text: URL contains, status code, method
├─ Throttling: Simulate slow connections (Slow 3G, Offline, Custom)
├─ Request blocking: Right-click → Block request URL/domain
├─ Replay request: Right-click → Replay XHR (re-sends identical request)
├─ Copy: Right-click → Copy as cURL/fetch/Node.js
└─ HAR export: Right-click → Save all as HAR with content
```

Debugging API calls:

```
1. Open Network panel before reproducing the issue
2. Filter by XHR/Fetch to see only API calls
3. Click the failing request:
   - Headers tab: check request method, URL, headers (Authorization, Content-Type)
   - Payload tab: inspect request body
   - Preview tab: formatted response
   - Response tab: raw response
   - Timing tab: DNS lookup, TLS, TTFB, content download breakdown
4. Check for CORS errors:
   - Look for preflight OPTIONS request
   - Check Access-Control-Allow-Origin in response
   - Console will show CORS error message
5. Waterfall: hover over bars to see timing breakdown
```

### Performance Panel

```bash
# Recording a performance trace:
1. Open Performance panel
2. Click Record (or Ctrl+E)
3. Perform the action to profile
4. Click Stop
5. Analyze the flame chart

# Key sections:
├─ Summary: pie chart of time spent (Scripting, Rendering, Painting, Idle)
├─ Main: flame chart showing call stack over time
│  ├─ Wide bars = long-running functions
│  ├─ Red corner = long task (>50ms blocks main thread)
│  └─ Click any bar to see source location and timing
├─ Network: requests timeline correlated with execution
├─ Frames: frame rate and dropped frames
└─ Timings: user timing marks and measures
```

Web Vitals debugging:

```javascript
// Measure Core Web Vitals in code
new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}: ${entry.startTime.toFixed(0)}ms`);
  }
}).observe({ type: 'largest-contentful-paint', buffered: true });

// Layout shift debugging
new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    if (!entry.hadRecentInput) {
      console.log('CLS:', entry.value, entry.sources);
    }
  }
}).observe({ type: 'layout-shift', buffered: true });
```

### Memory Panel

Heap snapshot workflow:

```
Three-Snapshot Technique (finding memory leaks):
1. Take snapshot 1 (baseline)
2. Perform the action suspected of leaking
3. Take snapshot 2
4. Perform the action again
5. Take snapshot 3
6. Select snapshot 3 → "Objects allocated between snapshot 1 and 2"
7. Look for objects that should have been GC'd but weren't

Key views:
├─ Summary: objects grouped by constructor, sorted by retained size
├─ Comparison: diff between two snapshots (delta of object counts)
├─ Containment: object hierarchy from GC roots
└─ Statistics: pie chart of memory by type
```

Common memory leak patterns:

```javascript
// Detached DOM nodes (common in SPAs)
// Symptom: "Detached" elements in heap snapshot
// Cause: JS reference to removed DOM node
let cache = [];
document.getElementById('btn').addEventListener('click', () => {
  const el = document.createElement('div');
  document.body.appendChild(el);
  cache.push(el);  // ← Reference keeps element alive even after removal
  document.body.removeChild(el);  // ← Element is "detached" but not GC'd
});

// Fix: remove from cache when element is removed, or use WeakRef
```

### Sources Panel

Breakpoint types:

```
Line breakpoint:     Click line number gutter
Conditional:         Right-click line → "Add conditional breakpoint"
                     Expression: user.id === 'problem-user'
Logpoint:            Right-click line → "Add logpoint"
                     Expression: 'User:', user.name, 'at', new Date()
DOM breakpoint:      Elements panel → right-click element → Break on
XHR/fetch:           Sources → XHR/fetch Breakpoints → add URL substring
Event listener:      Sources → Event Listener Breakpoints → check events
                     (mouse, keyboard, timer, animation, etc.)
Exception:           Sources → pause on caught/uncaught exceptions toggle
```

Source maps:

```
Enable source maps: Settings → Sources → Enable JavaScript/CSS source maps
├─ Maps minified/transpiled code back to original source
├─ Works with TypeScript, Babel, Webpack, etc.
├─ Breakpoints set on original source, not compiled output
└─ Stack traces show original file names and line numbers

Debugging source map issues:
1. Check for //# sourceMappingURL= comment at end of JS file
2. Verify the .map file is accessible (Network panel, check 404)
3. Check source map is valid: JSON.parse(mapContent)
```

## Node.js Debugging

### Inspector Protocol

```bash
# Start with debugger (pauses at first line)
node --inspect-brk app.js

# Start with debugger (does not pause)
node --inspect app.js

# Custom port
node --inspect=0.0.0.0:9230 app.js

# Then open chrome://inspect in Chrome and click "inspect"
```

### ndb (Enhanced DevTools)

```bash
# Install globally
npm install -g ndb

# Debug a script
ndb node app.js

# Debug tests
ndb npm test

# Features over standard DevTools:
# - Child process debugging (workers, clusters)
# - Blackboxing of node_modules by default
# - Edit and run code from within debugger
# - Detect common async issues
```

### clinic.js Suite

```bash
# Install
npm install -g clinic

# Detect common performance issues
clinic doctor -- node app.js
# Generates HTML report with recommendations

# Profile async operations (event loop delays)
clinic bubbleprof -- node app.js
# Shows async operation flow diagram

# CPU flame graph
clinic flame -- node app.js
# Interactive flame chart in browser

# Each tool outputs a .clinic/ directory with HTML report
# Open the generated .html file in a browser
```

### 0x Flame Graphs

```bash
# Install
npm install -g 0x

# Generate flame graph
0x app.js

# With specific arguments
0x -- node --max-old-space-size=4096 app.js

# Output: flamegraph.html
# Wider bars = more time spent in that function
# Search for your code's function names to find hot paths
```

### Node.js Diagnostics

```bash
# Trace warnings with stack traces
node --trace-warnings app.js

# Trace deprecations
node --trace-deprecation app.js

# Enable debug logging for specific modules
NODE_DEBUG=http,net node app.js
NODE_DEBUG=stream,fs node app.js

# Heap snapshot on OOM
node --heapsnapshot-near-heap-limit=3 app.js

# Generate diagnostic report
node --report-on-fatalerror app.js
# Or in code: process.report.writeReport()

# Trace garbage collection
node --trace-gc app.js
```

## Python Debugging

### pdb Commands

```
# Launch pdb
python -m pdb script.py

# Or insert breakpoint in code (Python 3.7+)
breakpoint()

# Essential commands:
n (next)          Step over (execute current line, stop at next)
s (step)          Step into (enter function call)
c (continue)      Run until next breakpoint
r (return)        Run until current function returns

p expr            Print expression value
pp expr           Pretty-print expression
l (list)          Show source around current line
ll (longlist)     Show full source of current function
w (where)         Print stack trace (alias: bt)
u (up)            Move up one frame in stack
d (down)          Move down one frame in stack

b 42              Set breakpoint at line 42
b module.py:42    Set breakpoint in specific file
b func            Set breakpoint at function entry
b 42, x > 10     Conditional breakpoint
cl 1              Clear breakpoint number 1
cl                Clear all breakpoints

a (args)          Print arguments of current function
display expr      Display expression value at each stop
undisplay expr    Stop displaying

commands 1        Set commands to run when breakpoint 1 is hit
  p x
  p y
  c
end

interact          Start interactive Python shell with current scope
```

### debugpy (VS Code Remote Debugging)

```python
# In the application code
import debugpy
debugpy.listen(("0.0.0.0", 5678))
print("Waiting for debugger to attach...")
debugpy.wait_for_client()
debugpy.breakpoint()
```

```json
// VS Code launch.json
{
  "name": "Attach to Remote",
  "type": "debugpy",
  "request": "attach",
  "connect": { "host": "localhost", "port": 5678 }
}
```

### py-spy (Sampling Profiler)

```bash
# Install
pip install py-spy

# Profile a running process (no code changes needed)
py-spy top --pid PID

# Generate flame graph
py-spy record -o profile.svg --pid PID

# Profile a command
py-spy record -o profile.svg -- python myapp.py

# Dump all thread stacks (instant, non-invasive)
py-spy dump --pid PID
```

### memray (Memory Profiler)

```bash
# Install
pip install memray

# Profile memory usage
memray run script.py

# Generate flame graph of allocations
memray flamegraph output.bin -o memory.html

# Show summary
memray summary output.bin

# Show top allocators
memray stats output.bin

# Live TUI during execution
memray run --live script.py
```

### tracemalloc (Built-in Memory Tracking)

```python
import tracemalloc

tracemalloc.start()

# ... run suspect code ...

snapshot = tracemalloc.take_snapshot()
top_stats = snapshot.statistics('lineno')

print("[ Top 10 memory allocations ]")
for stat in top_stats[:10]:
    print(stat)

# Compare two snapshots to find leaks
snapshot1 = tracemalloc.take_snapshot()
# ... run more code ...
snapshot2 = tracemalloc.take_snapshot()
top_stats = snapshot2.compare_to(snapshot1, 'lineno')
for stat in top_stats[:10]:
    print(stat)
```

## Go Debugging

### Delve (dlv)

```bash
# Debug a program
dlv debug ./cmd/server

# Debug a test
dlv test ./pkg/handler

# Attach to running process
dlv attach PID

# Connect remotely
dlv debug --headless --listen=:2345 --api-version=2 ./cmd/server
# Then in another terminal:
dlv connect localhost:2345
```

### Delve Commands

```
# Breakpoints
break main.go:42              Set breakpoint at file:line
break mypackage.MyFunction    Set breakpoint at function
cond 1 x > 100                Make breakpoint 1 conditional
on 1 print x                  Execute command when breakpoint 1 hits
clear 1                       Remove breakpoint 1
clearall                      Remove all breakpoints

# Execution
continue (c)                  Run to next breakpoint
next (n)                      Step over
step (s)                      Step into
stepout (so)                  Step out of current function
restart (r)                   Restart program

# Inspection
print (p) variable            Print variable value
display -a variable           Show variable at every stop
set variable = value          Modify variable value
locals                        Show all local variables
args                          Show function arguments
whatis variable               Show type of variable

# Stack
stack (bt)                    Print stack trace
frame N                       Switch to frame N
up                            Move up one frame
down                          Move down one frame

# Goroutines
goroutines                    List all goroutines
goroutine N                   Switch to goroutine N
goroutines -t                 List goroutines with stack traces
goroutine N bt                Stack trace for goroutine N
```

### Go Race Detector

```bash
# Run tests with race detector
go test -race ./...

# Run program with race detector
go run -race ./cmd/server

# Build with race detector
go build -race -o server ./cmd/server

# Example output:
# ==================
# WARNING: DATA RACE
# Write at 0x00c0000b4010 by goroutine 7:
#   main.increment()
#       main.go:15 +0x38
# Previous read at 0x00c0000b4010 by goroutine 6:
#   main.printCount()
#       main.go:20 +0x30
# ==================
```

### Go pprof

```go
// Add to your application
import _ "net/http/pprof"

func main() {
    go func() {
        http.ListenAndServe("localhost:6060", nil)
    }()
    // ... rest of application
}
```

```bash
# CPU profile (30 seconds)
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30

# Heap profile
go tool pprof http://localhost:6060/debug/pprof/heap

# Goroutine profile (find leaks/deadlocks)
go tool pprof http://localhost:6060/debug/pprof/goroutine

# Block profile (find contention)
go tool pprof http://localhost:6060/debug/pprof/block

# Inside pprof interactive mode:
(pprof) top              # Show top consumers
(pprof) top -cum         # Top by cumulative time
(pprof) list funcName    # Show annotated source
(pprof) web              # Open flame graph in browser
(pprof) svg > out.svg    # Export as SVG
```

## Rust Debugging

### rust-gdb / rust-lldb

```bash
# Build with debug info (default for dev profile)
cargo build

# Debug with GDB (Linux)
rust-gdb target/debug/myapp

# Debug with LLDB (macOS)
rust-lldb target/debug/myapp

# Inside GDB:
(gdb) break main           # Breakpoint at main
(gdb) break src/lib.rs:42  # Breakpoint at file:line
(gdb) run                  # Start program
(gdb) next                 # Step over
(gdb) step                 # Step into
(gdb) print variable       # Print value (Rust-aware pretty printing)
(gdb) bt                   # Backtrace
(gdb) info threads          # List threads
(gdb) thread 2             # Switch to thread 2
```

### Backtrace Control

```bash
# Short backtrace (usually sufficient)
RUST_BACKTRACE=1 cargo run

# Full backtrace (all frames including stdlib)
RUST_BACKTRACE=full cargo run

# Combine with log levels
RUST_LOG=debug RUST_BACKTRACE=1 cargo run
```

### Miri (Undefined Behavior Detector)

```bash
# Install miri
rustup component add miri

# Run tests under miri (detects UB, use-after-free, data races)
cargo miri test

# Run a specific binary
cargo miri run

# Miri detects:
# - Use of uninitialized memory
# - Accessing memory out of bounds
# - Use-after-free
# - Invalid use of unsafe/raw pointers
# - Data races (with -Zmiri-disable-isolation)
# - Memory leaks (with -Zmiri-leak-check)
```

### cargo-flamegraph

```bash
# Install
cargo install flamegraph

# Generate flame graph (needs perf on Linux, dtrace on macOS)
cargo flamegraph

# For a specific binary
cargo flamegraph --bin myapp

# For tests
cargo flamegraph --test my_test

# Output: flamegraph.svg (open in browser)
```

## Database Debugging

### PostgreSQL

```sql
-- Explain query execution plan
EXPLAIN ANALYZE SELECT * FROM users WHERE email = 'test@example.com';

-- Verbose explain with all details
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE user_id = 123 ORDER BY created_at DESC LIMIT 10;

-- Key things to look for:
-- Seq Scan (full table scan - usually bad on large tables)
-- Nested Loop (can be slow with large datasets)
-- Sort (in-memory vs disk sort)
-- actual time vs estimated time (large difference = stale statistics)

-- Check for slow queries (enable slow query log)
ALTER SYSTEM SET log_min_duration_statement = 100; -- log queries > 100ms
SELECT pg_reload_conf();

-- View currently running queries
SELECT pid, now() - pg_stat_activity.query_start AS duration,
       query, state, wait_event_type, wait_event
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY duration DESC;

-- Kill a stuck query
SELECT pg_cancel_backend(PID);      -- graceful
SELECT pg_terminate_backend(PID);   -- force

-- Check table statistics
SELECT relname, n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum, last_analyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- Check index usage
SELECT indexrelname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;  -- low scan count = possibly unused index

-- Lock analysis
SELECT blocked_locks.pid AS blocked_pid,
       blocked_activity.usename AS blocked_user,
       blocking_locks.pid AS blocking_pid,
       blocking_activity.usename AS blocking_user,
       blocked_activity.query AS blocked_query,
       blocking_activity.query AS blocking_query
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity
  ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks
  ON blocking_locks.locktype = blocked_locks.locktype
  AND blocking_locks.relation = blocked_locks.relation
  AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity
  ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;

-- Connection pool debugging
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
SHOW max_connections;
```

### pg_stat_statements

```sql
-- Enable (requires extension)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top queries by total time
SELECT query, calls, total_exec_time, mean_exec_time,
       rows, shared_blks_hit, shared_blks_read
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- Top queries by calls (hot queries)
SELECT query, calls, mean_exec_time
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 20;

-- Reset statistics
SELECT pg_stat_statements_reset();
```

## Network Debugging

### curl Verbose Mode

```bash
# Show full request/response headers and TLS handshake
curl -v https://api.example.com/endpoint

# Include timing breakdown
curl -w "\n\nDNS: %{time_namelookup}s\nConnect: %{time_connect}s\nTLS: %{time_appconnect}s\nTTFB: %{time_starttransfer}s\nTotal: %{time_total}s\n" \
  -o /dev/null -s https://api.example.com/endpoint

# Follow redirects and show each hop
curl -vL https://example.com/old-path

# Send with specific headers
curl -H "Authorization: Bearer TOKEN" -H "Content-Type: application/json" \
  -d '{"key":"value"}' https://api.example.com/endpoint

# Save response headers
curl -D headers.txt https://api.example.com/endpoint
```

### mitmproxy (HTTPS Interception)

```bash
# Start mitmproxy (TUI)
mitmproxy -p 8080

# Start as transparent proxy
mitmproxy --mode transparent

# Filter specific hosts
mitmproxy --intercept "~d api.example.com"

# Record and replay
mitmdump -w traffic.flow        # Record
mitmdump -r traffic.flow -p 8080 # Replay

# Key bindings in mitmproxy TUI:
# f: set filter expression
# i: set intercept filter
# e: edit intercepted request/response
# r: replay request
# z: clear all flows
# ?: help
```

### tcpdump Quick Reference

```bash
# Capture HTTP traffic on port 80
sudo tcpdump -i any port 80 -A

# Capture and save to file
sudo tcpdump -i any -w capture.pcap

# Filter by host
sudo tcpdump -i any host api.example.com

# Filter by host and port
sudo tcpdump -i any host 10.0.0.5 and port 5432

# Read saved capture
tcpdump -r capture.pcap

# Show packet contents in hex and ASCII
sudo tcpdump -XX -i any port 443
```

## Docker Debugging

### Container Inspection

```bash
# View container logs
docker logs CONTAINER --tail 100 -f        # Last 100 lines, follow
docker logs CONTAINER --since 5m            # Last 5 minutes
docker logs CONTAINER 2>&1 | rg "ERROR"    # Filter for errors

# Execute command in running container
docker exec -it CONTAINER /bin/sh           # Shell into container
docker exec CONTAINER cat /etc/hosts        # Run single command
docker exec CONTAINER env                    # Check environment

# Inspect container configuration
docker inspect CONTAINER                     # Full JSON config
docker inspect --format '{{.State.Status}}' CONTAINER
docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' CONTAINER

# View resource usage
docker stats CONTAINER                       # Live CPU, memory, I/O
docker top CONTAINER                         # Running processes

# Check health status
docker inspect --format '{{.State.Health.Status}}' CONTAINER
docker inspect --format '{{json .State.Health}}' CONTAINER | jq .

# Copy files from container for inspection
docker cp CONTAINER:/app/logs/error.log ./error.log

# View filesystem changes
docker diff CONTAINER                        # Shows A(added), C(changed), D(deleted)
```

### Debugging Crashed Containers

```bash
# Container exited? Check the exit code and logs
docker ps -a --filter "status=exited"
docker logs CONTAINER

# Create image from stopped container for inspection
docker commit CONTAINER debug-image
docker run -it debug-image /bin/sh

# Override entrypoint to debug startup issues
docker run -it --entrypoint /bin/sh IMAGE

# Check what the container was doing
docker inspect CONTAINER --format '{{.State.Error}}'
docker inspect CONTAINER --format '{{.State.OOMKilled}}'
docker inspect CONTAINER --format '{{.State.ExitCode}}'
# Exit codes: 0=success, 1=app error, 137=OOM/SIGKILL, 139=segfault, 143=SIGTERM
```

### Debugging Networking

```bash
# Check container networking
docker network ls
docker network inspect bridge
docker exec CONTAINER ping other-container
docker exec CONTAINER nslookup other-service
docker exec CONTAINER curl -v http://other-service:8080/health

# Debug DNS resolution
docker exec CONTAINER cat /etc/resolv.conf

# Check port mapping
docker port CONTAINER
```

### strace in Container

```bash
# Run container with SYS_PTRACE capability
docker run --cap-add SYS_PTRACE IMAGE

# strace inside container
docker exec CONTAINER strace -p 1 -f -e trace=network

# nsenter from host (if strace not in container)
PID=$(docker inspect --format '{{.State.Pid}}' CONTAINER)
nsenter -t $PID -n tcpdump -i any -A
```
