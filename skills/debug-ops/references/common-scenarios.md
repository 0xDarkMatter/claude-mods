# Common Debugging Scenarios

Playbooks for the most frequently encountered bug categories.

## Memory Leaks

### Symptoms

```
├─ RSS (Resident Set Size) grows continuously over time
├─ OOM (Out of Memory) kills after hours/days of uptime
├─ Increasing GC time / GC pauses getting longer
├─ Application slows down gradually
└─ Swap usage increases
```

### Browser / Frontend

Three-snapshot technique:

```
1. Take heap snapshot (baseline after page load)
2. Perform the suspected leaking action (e.g., open/close modal 10 times)
3. Force garbage collection (Performance panel → trash can icon)
4. Take heap snapshot 2
5. Repeat step 2 (10 more times)
6. Force GC again
7. Take heap snapshot 3
8. In snapshot 3, select "Objects allocated between snapshot 1 and 2"
9. Sort by "Retained Size" descending
10. Look for objects that should have been GC'd
```

Detached DOM nodes:

```javascript
// Find detached DOM nodes in DevTools Console
// Take heap snapshot → search for "Detached" in class filter

// Common cause: event listener on removed element
const handler = () => { /* ... */ };
element.addEventListener('click', handler);
element.remove(); // Element is detached but handler holds reference

// Fix: remove listener before removing element
element.removeEventListener('click', handler);
element.remove();

// Or use AbortController (modern approach)
const controller = new AbortController();
element.addEventListener('click', handler, { signal: controller.signal });
// Later: clean up all listeners at once
controller.abort();
```

### Node.js

```bash
# Method 1: Chrome DevTools
node --inspect app.js
# Open chrome://inspect → Take heap snapshots

# Method 2: heapdump module
# In code: require('heapdump');
# Send SIGUSR2 to take snapshot: kill -USR2 PID
# Compare .heapsnapshot files in Chrome DevTools

# Method 3: clinic.js doctor
clinic doctor -- node app.js
# Generates report identifying likely memory leak

# Method 4: Process memory monitoring
node -e "setInterval(() => console.log(process.memoryUsage()), 5000)"
# Watch rss, heapUsed, heapTotal, external, arrayBuffers
```

### Python

```python
# objgraph: find reference chains keeping objects alive
import objgraph

# Show object count growth between two points
objgraph.show_growth(limit=10)
# ... run suspect code ...
objgraph.show_growth(limit=10)  # Shows what increased

# Find what holds a reference to an object
objgraph.show_backrefs(
    objgraph.by_type('MyClass')[0],
    max_depth=5,
    filename='refs.png'
)

# tracemalloc: track where allocations happen
import tracemalloc
tracemalloc.start(25)  # Store 25 frames of traceback

# ... run suspect code ...

snapshot = tracemalloc.take_snapshot()
for stat in snapshot.statistics('traceback')[:5]:
    print(stat)
    for line in stat.traceback.format():
        print(f"  {line}")

# gc: inspect garbage collector
import gc
gc.set_debug(gc.DEBUG_LEAK)  # Log uncollectable objects
gc.collect()  # Force collection
print(gc.garbage)  # List of uncollectable objects

# Find circular references
gc.collect()
for obj in gc.garbage:
    print(type(obj), gc.get_referrers(obj))
```

### Go

```bash
# Enable pprof endpoint (add to your app)
# import _ "net/http/pprof"

# Take heap profile
go tool pprof http://localhost:6060/debug/pprof/heap

# Compare two heap profiles (before and after)
go tool pprof -diff_base=heap1.prof heap2.prof

# Inside pprof:
(pprof) top             # Top allocators
(pprof) top -cum        # Top by cumulative allocations
(pprof) list funcName   # Annotated source showing allocations per line
(pprof) web             # Graphical view in browser

# Quick check: runtime memory stats
import "runtime"

var m runtime.MemStats
runtime.ReadMemStats(&m)
fmt.Printf("Alloc: %d MiB\n", m.Alloc / 1024 / 1024)
fmt.Printf("TotalAlloc: %d MiB\n", m.TotalAlloc / 1024 / 1024)
fmt.Printf("Sys: %d MiB\n", m.Sys / 1024 / 1024)
fmt.Printf("NumGC: %d\n", m.NumGC)
```

### Common Causes

| Cause | Language | Detection |
|-------|----------|-----------|
| Event listener accumulation | JS | Heap snapshot → EventListener count growing |
| Cache without eviction | All | Memory grows linearly with unique inputs |
| Closure capturing large scope | JS/Python | Heap snapshot → large retained size in closures |
| Circular references | Python | `gc.garbage` shows uncollectable objects |
| Goroutine leak | Go | `pprof/goroutine` count grows over time |
| Global/static collections | All | Check module-level lists, dicts, maps |
| Unreleased database connections | All | Connection pool stats show exhaustion |
| String concatenation in loops | Go/Java | `strings.Builder` / `StringBuilder` instead |
| Forgotten timers/intervals | JS | `setInterval` without corresponding `clearInterval` |

## Deadlocks

### Symptoms

```
├─ Process hangs (0% CPU, still alive)
├─ All worker threads blocked
├─ No new log output
├─ Health check timeouts
└─ Incoming requests queue up, never complete
```

### Detection by Language

```bash
# Go: dump all goroutine stacks
kill -SIGQUIT PID
# Or: curl http://localhost:6060/debug/pprof/goroutine?debug=2

# Java: thread dump
jstack PID
kill -3 PID  # SIGQUIT also works for JVM

# Python: faulthandler (prints all thread stacks)
python -c "import faulthandler; faulthandler.enable()" # then Ctrl+\
# Or send SIGUSR1 if faulthandler is registered

# Node.js: get active handles/requests
process._getActiveHandles()
process._getActiveRequests()

# Linux: check what threads are waiting on
cat /proc/PID/stack           # Kernel stack of main thread
ls /proc/PID/task/            # List all threads
cat /proc/PID/task/TID/stack  # Kernel stack of specific thread

# GDB: attach to stuck process
gdb -p PID
(gdb) info threads
(gdb) thread apply all bt    # Backtrace for all threads
```

### Classic Deadlock Pattern

```
Thread 1: lock(A) → lock(B)
Thread 2: lock(B) → lock(A)

Timeline:
  T1: acquires A         T2: acquires B
  T1: waits for B        T2: waits for A
  → DEADLOCK (both waiting forever)
```

### Prevention

```
1. Consistent lock ordering:
   Always acquire locks in the same order (e.g., alphabetical by resource name)

2. Timeout on lock acquisition:
   mutex.tryLock(timeout: 5.seconds)
   If timeout → release all locks, backoff, retry

3. Lock-free data structures:
   Use atomic operations, channels (Go), or concurrent collections

4. Detect and break:
   Deadlock detection thread that monitors lock wait times
   Go: runtime detects goroutine deadlocks (fatal error: all goroutines asleep)
```

### Go-Specific: Channel Deadlocks

```go
// Deadlock: unbuffered channel with no receiver
ch := make(chan int)
ch <- 1  // blocks forever, no goroutine reading

// Deadlock: channel in select without default
select {
case msg := <-ch:
    process(msg)
// no default → blocks forever if ch has no sender
}

// Fix: add timeout or default
select {
case msg := <-ch:
    process(msg)
case <-time.After(5 * time.Second):
    log.Println("timeout waiting for message")
default:
    // non-blocking
}

// Goroutine leak detection
// If goroutine count grows over time, goroutines are stuck
import "runtime"
fmt.Println("Goroutines:", runtime.NumGoroutine())
```

### Go-Specific: Mutex Deadlock Detection

```go
// Use sync.Mutex with deadlock detector during development
// go get github.com/sasha-s/go-deadlock
import "github.com/sasha-s/go-deadlock"

var mu go_deadlock.Mutex  // Drop-in replacement for sync.Mutex
// Prints potential deadlock warning with stack traces
// when lock is held for too long
```

## Race Conditions

### Symptoms

```
├─ Intermittent test failures ("flaky tests")
├─ Different results on different runs with same input
├─ Bug disappears when adding print/log statements (Heisenbug)
├─ Works with 1 user, fails with 10 concurrent users
├─ Works in debugger, fails in production
└─ Data corruption that "should be impossible"
```

### Detection Tools

```bash
# Go: built-in race detector
go test -race ./...
go run -race ./cmd/server

# C/C++/Rust: ThreadSanitizer
# Compile with: -fsanitize=thread
gcc -fsanitize=thread -g program.c -o program
./program

# Rust: Miri (for unsafe code)
cargo miri test

# Java: use -XX:+UseThreadSanitizer (experimental)
# or tools like FindBugs, SpotBugs with concurrency detectors

# Python: threading issues are less common due to GIL
# but still occur with multiprocessing, asyncio, or C extensions
```

### Reproduction Techniques

```python
# Technique 1: Add strategic delays to widen the race window
import time

def transfer(from_account, to_account, amount):
    balance = from_account.balance
    time.sleep(0.001)  # ← Widens the race window
    from_account.balance = balance - amount
    time.sleep(0.001)  # ← Makes race more likely
    to_account.balance += amount
```

```bash
# Technique 2: Increase concurrency
# Run the same test with 100 concurrent workers
for i in $(seq 1 100); do
    curl -s http://localhost:3000/api/transfer &
done
wait

# Technique 3: Stress test with loop
for i in $(seq 1 1000); do
    go test -race -count=1 ./pkg/... || echo "FAILED on iteration $i"
done
```

```go
// Technique 4: Go - use t.Parallel() in tests
func TestConcurrentAccess(t *testing.T) {
    for i := 0; i < 100; i++ {
        t.Run(fmt.Sprintf("case_%d", i), func(t *testing.T) {
            t.Parallel() // Run sub-tests concurrently
            // ... test code that exercises shared state
        })
    }
}
```

### Common Race Condition Patterns

**Read-Modify-Write (most common)**:

```
Thread 1: read counter (= 5)
Thread 2: read counter (= 5)
Thread 1: write counter (= 6)
Thread 2: write counter (= 6)  ← Should be 7!

Fix: atomic operations or mutex
  Go:    atomic.AddInt64(&counter, 1)
  Rust:  counter.fetch_add(1, Ordering::SeqCst)
  JS:    N/A (single-threaded, but async read-modify-write exists)
  Python: threading.Lock()
```

**Check-Then-Act (TOCTOU)**:

```
Thread 1: if file.exists()        (yes)
Thread 2:                         delete file
Thread 1:     file.read()         ← CRASH: file no longer exists

Fix: atomic operations or locks
  OS-level: use O_CREAT|O_EXCL flags
  DB-level: use transactions with proper isolation
  App-level: lock around check+act
```

**Publication Without Synchronization**:

```go
// BAD: other goroutines may see partially initialized Config
config = &Config{Host: "example.com", Port: 8080}

// GOOD: use atomic.Value or sync.Once
var configValue atomic.Value
configValue.Store(&Config{Host: "example.com", Port: 8080})
```

## Performance Regressions

### Detection

```bash
# Git bisect with benchmark
git bisect start
git bisect bad HEAD
git bisect good v1.0.0

# Automated bisect using benchmark threshold
cat > /tmp/bench-test.sh << 'SCRIPT'
#!/bin/bash
go test -bench=BenchmarkCriticalPath -count=5 ./pkg/... |
  grep "ns/op" |
  awk '{print $3}' |
  awk '{s+=$1; n++} END {
    avg = s/n;
    if (avg > 1000) exit 1;  # Bad if > 1000 ns/op
    else exit 0;              # Good otherwise
  }'
SCRIPT
chmod +x /tmp/bench-test.sh
git bisect run /tmp/bench-test.sh
```

### CPU Profiling

```bash
# Go: CPU profile
go test -cpuprofile=cpu.prof -bench=. ./pkg/...
go tool pprof cpu.prof
(pprof) top 20
(pprof) list HotFunction  # Annotated source with time per line
(pprof) web               # Visual graph

# Node.js: clinic flame
clinic flame -- node app.js
# Or: 0x app.js

# Python: cProfile
python -m cProfile -s cumulative script.py
# Or: py-spy for live profiling
py-spy top --pid PID

# Rust: cargo flamegraph
cargo flamegraph --bin myapp
```

### Flame Graph Interpretation

```
Reading flame graphs:
├─ X-axis: fraction of total time (wider = more time)
├─ Y-axis: call stack depth (bottom = entry point, top = leaf)
├─ Each bar: a function in the stack
├─ Color: usually random (not meaningful) unless semantic coloring
│
├─ Look for: "plateaus" (wide flat bars) = hot functions
├─ Look for: unexpected depth = unnecessary call chains
├─ Look for: multiple thin towers = function called many times
└─ Ignore: narrow bars (insignificant time)

Common findings:
├─ Wide JSON.parse bar → large payload parsing
├─ Wide sort bar → inefficient sorting algorithm or large dataset
├─ Wide GC bar → too many allocations (reduce object creation)
├─ Deep regex bar → regex backtracking (simplify pattern)
└─ Wide I/O bar → blocking I/O on critical path
```

### Memory Profiling for Performance

```bash
# Go: allocation profiling
go test -memprofile=mem.prof -bench=. ./pkg/...
go tool pprof -alloc_objects mem.prof  # Count of allocations
go tool pprof -alloc_space mem.prof    # Size of allocations

# Node.js: allocation timeline in DevTools
# Memory panel → Allocation instrumentation on timeline
# Shows objects allocated over time, find what survives GC

# Python: memray for allocation hot spots
memray run --trace-python-allocators script.py
memray flamegraph output.bin
```

### I/O Performance

```bash
# Identify slow queries
# PostgreSQL:
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
# Look for:
#   Seq Scan on large table → add index
#   Nested Loop with high row count → consider join strategy
#   Sort with external merge → increase work_mem

# N+1 query detection:
# Count queries per request (log all queries, count):
grep "SELECT\|INSERT\|UPDATE\|DELETE" query.log | wc -l
# If count scales with data size → N+1 problem

# Connection pool exhaustion:
# PostgreSQL:
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
# If active ≈ max_connections → pool exhaustion
```

## API Debugging

### Request/Response Inspection

```bash
# Full request/response with timing
curl -v -w "\n\nTiming:\n  DNS:     %{time_namelookup}s\n  Connect: %{time_connect}s\n  TLS:     %{time_appconnect}s\n  TTFB:    %{time_starttransfer}s\n  Total:   %{time_total}s\n  Size:    %{size_download} bytes\n" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key": "value"}' \
  https://api.example.com/endpoint

# Compare expected vs actual response
diff <(curl -s expected-endpoint | jq .) <(curl -s actual-endpoint | jq .)
```

### Status Code Debugging

```
2xx: Success (but check response body for soft errors)
├─ 200: OK
├─ 201: Created (check Location header for new resource URL)
└─ 204: No Content (no response body expected)

3xx: Redirect (follow with curl -L, check redirect chain)
├─ 301: Permanent redirect (cache implications)
├─ 302: Temporary redirect
└─ 304: Not Modified (caching working correctly)

4xx: Client error (fix the request)
├─ 400: Bad Request → check request body against API schema
├─ 401: Unauthorized → check token validity, expiration
├─ 403: Forbidden → check permissions, scopes, IP allowlist
├─ 404: Not Found → check URL path, resource existence
├─ 405: Method Not Allowed → check HTTP method (GET vs POST)
├─ 409: Conflict → check for duplicate/concurrent operations
├─ 413: Payload Too Large → reduce request body size
├─ 422: Unprocessable → valid JSON but semantic errors
├─ 429: Rate Limited → check Retry-After header, implement backoff
└─ 431: Headers Too Large → reduce cookie/header size

5xx: Server error (usually not your fault, but check your request)
├─ 500: Internal Server Error → check server logs
├─ 502: Bad Gateway → upstream service down
├─ 503: Service Unavailable → service overloaded or deploying
└─ 504: Gateway Timeout → upstream too slow, check timeout settings
```

### Header Debugging

```bash
# CORS debugging
curl -v -X OPTIONS \
  -H "Origin: http://localhost:3000" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type,Authorization" \
  https://api.example.com/endpoint

# Check response headers:
# Access-Control-Allow-Origin: must match your origin (or *)
# Access-Control-Allow-Methods: must include your method
# Access-Control-Allow-Headers: must include your custom headers
# Access-Control-Allow-Credentials: must be true if sending cookies

# Content-Type debugging
# Sending JSON but getting 400? Check:
curl -H "Content-Type: application/json" ...   # CORRECT
curl -H "Content-Type: text/plain" ...         # WRONG for JSON APIs

# Auth header debugging
# Bearer token:
curl -H "Authorization: Bearer eyJhbG..." ...
# Basic auth:
curl -u username:password ...
# API key:
curl -H "X-API-Key: your-key" ...
```

### Payload Debugging

```bash
# Validate JSON syntax
echo '{"key": "value"}' | jq .

# Pretty-print API response
curl -s https://api.example.com/endpoint | jq .

# Compare schemas
# Save expected schema and actual response, then diff
curl -s https://api.example.com/endpoint | jq 'keys' > actual-keys.json
diff expected-keys.json actual-keys.json

# Check encoding issues
curl -s https://api.example.com/endpoint | file -
# Should show: "UTF-8 Unicode text" or "ASCII text"
# If "ISO-8859" or "binary" → encoding mismatch

# Large payload debugging
curl -s https://api.example.com/endpoint | jq '. | length'  # Array length
curl -s https://api.example.com/endpoint | wc -c             # Byte count
```

### Timeout and Retry Debugging

```bash
# Test with explicit timeout
curl --connect-timeout 5 --max-time 30 https://api.example.com/endpoint

# If timing out, check at each layer:
# 1. DNS resolution
dig api.example.com
nslookup api.example.com

# 2. TCP connectivity
nc -zv api.example.com 443

# 3. TLS handshake
openssl s_client -connect api.example.com:443

# 4. HTTP response time
curl -o /dev/null -s -w "TTFB: %{time_starttransfer}s\n" https://api.example.com/endpoint

# Retry with exponential backoff (script)
for i in 1 2 4 8 16; do
    if curl -sf https://api.example.com/health; then
        echo "Service is up"
        break
    fi
    echo "Retry in ${i}s..."
    sleep $i
done
```

## Deployment Issues ("Works on My Machine")

### Environment Diff Checklist

```bash
# 1. OS and architecture
uname -a                              # Linux/macOS
# Compare: local vs CI vs production

# 2. Runtime versions
node --version                        # Node.js
python --version                      # Python
go version                            # Go
rustc --version                       # Rust

# 3. Dependency versions
# Node.js:
diff <(cat package-lock.json | jq '.dependencies | keys') \
     <(ssh prod 'cat /app/package-lock.json | jq ".dependencies | keys"')

# Python:
diff <(pip list --format=freeze | sort) \
     <(ssh prod 'pip list --format=freeze | sort')

# 4. Environment variables
diff <(env | sort | grep -v SECRET) \
     <(ssh prod 'env | sort | grep -v SECRET')

# 5. Config files (byte-for-byte comparison)
diff local.env <(ssh prod 'cat /app/.env')

# 6. System resources
free -h                               # Memory
df -h                                 # Disk space
ulimit -n                             # File descriptor limit
```

### Docker Reproducibility

```bash
# Ensure same image locally and in production
docker inspect IMAGE --format '{{.Id}}'  # Compare image IDs

# Run locally with production-equivalent constraints
docker run \
  --memory=512m \
  --cpus=1 \
  --env-file production.env \
  --network=host \
  IMAGE

# Debug inside the exact production image
docker run -it --entrypoint /bin/sh PRODUCTION_IMAGE
```

### Dependency Differences

```bash
# Check if lock file is fresh
# Node.js: compare node_modules to lock file
npm ls --all 2>&1 | grep "WARN\|ERR"

# Python: check for mismatched requirements
pip check

# Go: verify module checksum
go mod verify

# Common issue: "works locally" because you have a package
# installed globally that is not in the project's dependencies
# Test: run in clean environment (Docker, CI)
```

### File System Differences

```
Common traps:
├─ Case sensitivity: macOS/Windows are case-insensitive, Linux is case-sensitive
│  import User from './user'  ← works on Mac, fails on Linux if file is User.js
│
├─ Path separators: Windows uses \, Linux/macOS uses /
│  Use path.join() or path.resolve(), never hardcode separators
│
├─ Line endings: Windows CRLF (\r\n) vs Unix LF (\n)
│  Scripts with CRLF fail on Linux: /bin/bash^M: bad interpreter
│  Fix: git config core.autocrlf input
│
├─ File permissions: Linux/macOS have execute bits, Windows does not
│  chmod +x script.sh has no effect on Windows
│
├─ Max path length: Windows has 260 char limit (unless LongPathsEnabled)
│  node_modules paths can exceed this on Windows
│
└─ Symlinks: Windows requires admin privileges or Developer Mode
   npm link / yarn link may fail on Windows
```

### Network Differences

```bash
# DNS resolution differences
dig +short api.example.com              # What does DNS resolve to here?
ssh prod 'dig +short api.example.com'   # What about in production?

# Firewall differences
# Can the production server reach the external API?
ssh prod 'curl -sv https://external-api.com/health 2>&1 | head -20'

# Proxy differences
echo $HTTP_PROXY $HTTPS_PROXY $NO_PROXY
ssh prod 'echo $HTTP_PROXY $HTTPS_PROXY $NO_PROXY'

# TLS/certificate differences
openssl s_client -connect api.example.com:443 < /dev/null 2>/dev/null | openssl x509 -noout -dates
# Check if production has different CA bundle
ssh prod 'openssl s_client -connect api.example.com:443 < /dev/null 2>/dev/null | openssl x509 -noout -dates'

# MTU / packet size issues (rare but painful)
ping -M do -s 1472 api.example.com      # Test path MTU
```

### Quick "Works on My Machine" Decision Tree

```
Does it fail in Docker locally (same image as prod)?
├─ No → Environment difference. Compare: env vars, config, DNS, network
└─ Yes → Does it fail in CI?
   ├─ No → Data or state difference. Compare: database, cache, file system
   └─ Yes → Code bug. Use standard debugging workflow.
       └─ But I swear it works on my machine!
          → Run in clean checkout: git stash && npm ci && npm test
          → If it passes: your working tree has uncommitted changes that fix it
          → If it fails: local cache/build artifact masking the bug
             → rm -rf node_modules .next dist build && npm ci && npm test
```
