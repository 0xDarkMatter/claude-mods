# CPU & Memory Profiling

Comprehensive profiling guide across languages and runtimes.

## Flamegraph Reading Guide

### Anatomy of a Flamegraph

```
A flamegraph is a visualization of stack traces collected by a sampling profiler.

   ┌─────────────────────────────────────────────────────┐
   │              expensiveComputation()                 │  ← Leaf (top): where CPU time is spent
   ├───────────────────────┬─────────────────────────────┤
   │   processItem()       │      validateInput()        │  ← Callees of handleRequest
   ├───────────────────────┴─────────────────────────────┤
   │                  handleRequest()                    │  ← Called by main
   ├─────────────────────────────────────────────────────┤
   │                      main()                         │  ← Root (bottom): entry point
   └─────────────────────────────────────────────────────┘

Reading rules:
- Width = proportion of total samples (wider = more CPU time)
- Height = stack depth (bottom = caller, top = callee)
- Colors = typically random or language-based (not meaningful)
- Left-to-right order = alphabetical (not temporal)

What to look for:
1. WIDE bars at the TOP → functions consuming the most CPU directly
2. WIDE bars in the MIDDLE → functions whose callees consume most CPU
3. Narrow tall towers → deep call stacks but fast (usually fine)
4. Flat plateaus → single function dominating CPU time
```

### Top-Down vs Bottom-Up Analysis

```
Top-Down (Caller → Callee):
- Start from root (main), follow widest paths down
- Good for: understanding call hierarchy, finding which code path is slow
- Question answered: "What is my application doing?"

Bottom-Up (Callee → Caller):
- Start from leaf functions, trace up to callers
- Good for: finding hot functions regardless of who calls them
- Question answered: "Which functions use the most CPU?"

Differential Flamegraphs:
- Compare two profiles (before/after change, baseline/regression)
- Red = regression (more samples), Blue = improvement (fewer samples)
- Generate: flamegraph.pl --negate > diff.svg
- Tools: speedscope, Firefox Profiler, pprof diff
```

### Common Flamegraph Patterns

```
Pattern: GC Pressure
- Look for: wide GC/runtime.gc bars, frequent small allocations
- Fix: reduce allocations, use object pools, pre-allocate buffers

Pattern: Lock Contention
- Look for: wide mutex/lock/wait bars in multiple goroutines/threads
- Fix: reduce critical section size, use lock-free data structures

Pattern: Regex Backtracking
- Look for: wide regex engine bars (re.match, regexp.exec)
- Fix: anchor patterns, use possessive quantifiers, compile once

Pattern: Serialization Overhead
- Look for: wide JSON.parse/encode/marshal bars
- Fix: schema-based serialization (protobuf, msgpack), streaming

Pattern: Syscall Heavy
- Look for: wide read/write/sendto/recvfrom system call bars
- Fix: buffered I/O, batch operations, io_uring (Linux)
```

## Node.js Profiling

### clinic.js Suite

```bash
# Install clinic.js globally
npm install -g clinic

# Doctor: automated diagnosis (CPU, memory, I/O, event loop)
clinic doctor -- node app.js
# Exercise your application, then Ctrl+C
# Opens HTML report with diagnosis and recommendations

# Flame: CPU flamegraph
clinic flame -- node app.js
# Exercise, Ctrl+C → interactive flamegraph

# BubbleProf: async operation visualization
clinic bubbleprof -- node app.js
# Shows async operations, delays, and dependencies
# Great for finding async bottlenecks invisible to CPU profilers
```

### 0x: Lightweight Flamegraphs

```bash
# Install and profile
npm install -g 0x
0x app.js
# Exercise, Ctrl+C → opens flamegraph in browser

# Profile with specific flags
0x --collect-only app.js     # Collect stacks, don't generate graph
0x --visualize-only PID.0x   # Generate graph from collected data
0x -o flamegraph.html app.js # Specify output file
```

### Built-in V8 Profiling

```bash
# CPU profile (generates .cpuprofile)
node --cpu-prof --cpu-prof-interval=100 app.js
# Load in Chrome DevTools → Performance tab → Load profile

# Heap profile (generates .heapprofile)
node --heap-prof app.js
# Load in Chrome DevTools → Memory tab

# V8 trace optimization decisions
node --trace-opt --trace-deopt app.js 2>&1 | grep -E "(OPTIMIZED|DEOPTIMIZED)"
# Shows which functions V8 optimizes and deoptimizes

# GC tracing
node --trace-gc app.js
# Output: [GC] type, duration, heap before/after

# Allocation tracking
node --trace-gc --trace-gc-verbose app.js
```

### Chrome DevTools CPU Profiler

```
1. Open chrome://inspect (or node --inspect-brk app.js)
2. Click "inspect" on your Node.js target
3. Go to Performance tab
4. Click Record (●)
5. Perform the actions you want to profile
6. Stop recording
7. Analyze:
   - Summary: pie chart of activity types
   - Bottom-Up: hottest functions first
   - Call Tree: top-down call hierarchy
   - Event Log: chronological events

Key columns:
- Self Time: time in the function itself (not callees)
- Total Time: time including all callees
- Focus on high Self Time for optimization targets
```

### Node.js Memory Profiling

```bash
# Heap snapshot via Chrome DevTools
node --inspect app.js
# DevTools → Memory → Take heap snapshot

# Programmatic heap snapshots
# npm install heapdump
# In code:
# const heapdump = require('heapdump');
# heapdump.writeSnapshot('/tmp/heap-' + Date.now() + '.heapsnapshot');

# Process memory monitoring
node -e "
  setInterval(() => {
    const mem = process.memoryUsage();
    console.log(JSON.stringify({
      rss_mb: (mem.rss / 1024 / 1024).toFixed(1),
      heap_used_mb: (mem.heapUsed / 1024 / 1024).toFixed(1),
      heap_total_mb: (mem.heapTotal / 1024 / 1024).toFixed(1),
      external_mb: (mem.external / 1024 / 1024).toFixed(1)
    }));
  }, 5000);
"

# Event loop utilization (Node 14+)
# const { monitorEventLoopDelay } = require('perf_hooks');
# const h = monitorEventLoopDelay({ resolution: 20 });
# h.enable();
# setInterval(() => console.log('p99:', h.percentile(99) / 1e6, 'ms'), 5000);
```

## Python Profiling

### py-spy: Sampling Profiler

```bash
# Install
pip install py-spy

# Record flamegraph (no code changes needed)
py-spy record -o profile.svg -- python app.py
py-spy record -o profile.svg --pid PID   # Attach to running process

# Live top-like view
py-spy top --pid PID
py-spy top -- python app.py

# Output format options
py-spy record -o profile.json --format speedscope -- python app.py
py-spy record -o profile.txt --format raw -- python app.py

# Profile subprocesses too
py-spy record --subprocesses -o profile.svg -- python app.py

# Sample rate (default 100 Hz)
py-spy record --rate 250 -o profile.svg -- python app.py

# Include native (C extension) frames
py-spy record --native -o profile.svg -- python app.py
```

### cProfile and line_profiler

```python
# cProfile: function-level profiling (built-in)
import cProfile
import pstats

# Profile a function
cProfile.run('my_function()', 'output.prof')

# Analyze results
stats = pstats.Stats('output.prof')
stats.sort_stats('cumulative')  # or 'tottime' for self time
stats.print_stats(20)  # top 20 functions

# Command-line usage
# python -m cProfile -s cumulative app.py
# python -m cProfile -o output.prof app.py

# line_profiler: line-by-line profiling
# pip install line_profiler
# Decorate functions with @profile
# kernprof -l -v script.py
```

### scalene: CPU + Memory + GPU

```bash
# Install
pip install scalene

# Profile (no code changes needed)
scalene script.py
scalene --cpu --memory --gpu script.py

# Output as JSON for programmatic analysis
scalene --json --outfile profile.json script.py

# Profile specific function
scalene --profile-only my_module script.py

# Web-based UI
scalene --html --outfile profile.html script.py

# What scalene shows:
# - CPU time (Python vs native code)
# - Memory allocation and deallocation per line
# - GPU usage per line
# - Copy volume (data copying overhead)
```

### memray: Memory Profiler

```bash
# Install
pip install memray

# Record memory allocations
memray run script.py
memray run --output output.bin script.py

# Attach to running process
memray attach PID

# Generate reports
memray flamegraph output.bin              # Allocation flamegraph
memray table output.bin                   # Table of allocations
memray tree output.bin                    # Tree of allocations
memray summary output.bin                 # High-level summary
memray stats output.bin                   # Allocation statistics

# Live monitoring
memray run --live script.py               # TUI live view
memray run --live-remote --live-port 9001 script.py  # Remote live view

# Detect memory leaks
memray flamegraph --leaks output.bin      # Show only leaked memory
memray table --leaks output.bin

# Temporal flamegraph (allocation over time)
memray flamegraph --temporal output.bin
```

### tracemalloc: Built-in Memory Tracking

```python
import tracemalloc

# Start tracing
tracemalloc.start(25)  # Store 25 frames of traceback

# Take snapshots at different points
snapshot1 = tracemalloc.take_snapshot()
# ... run code ...
snapshot2 = tracemalloc.take_snapshot()

# Top allocators
top_stats = snapshot2.statistics('lineno')  # or 'traceback', 'filename'
for stat in top_stats[:10]:
    print(stat)

# Compare snapshots (find growth)
diff = snapshot2.compare_to(snapshot1, 'lineno')
for stat in diff[:10]:
    print(stat)

# Current memory usage
current, peak = tracemalloc.get_traced_memory()
print(f"Current: {current / 1024 / 1024:.1f} MB")
print(f"Peak:    {peak / 1024 / 1024:.1f} MB")
```

### objgraph: Reference Chain Visualization

```python
import objgraph

# Show most common types in memory
objgraph.show_most_common_types(limit=20)

# Show growth between two points
objgraph.show_growth(limit=10)
# ... do something ...
objgraph.show_growth(limit=10)  # Shows only types that grew

# Find reference chains keeping objects alive
objgraph.show_backrefs(
    objgraph.by_type('MyClass')[0],
    max_depth=10,
    filename='refs.png'
)

# Count instances of a type
print(objgraph.count('dict'))
print(objgraph.count('MyClass'))
```

## Go Profiling

### pprof: Built-in Profiler

```go
// Enable pprof HTTP endpoint (add to your main.go)
import _ "net/http/pprof"

func main() {
    go func() {
        log.Println(http.ListenAndServe("localhost:6060", nil))
    }()
    // ... rest of application
}

// Or for non-HTTP applications, use runtime/pprof directly:
import "runtime/pprof"

f, _ := os.Create("cpu.prof")
pprof.StartCPUProfile(f)
defer pprof.StopCPUProfile()
```

```bash
# CPU profile (30 seconds)
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30

# Interactive mode commands:
# top          - top functions by CPU
# top -cum     - top by cumulative time
# list funcName - source-level annotation
# web          - open graph in browser
# svg          - export call graph as SVG

# Web UI (recommended)
go tool pprof -http :8080 http://localhost:6060/debug/pprof/profile?seconds=30
# Opens browser with flamegraph, graph, source, top views

# Heap profile (current allocations)
go tool pprof http://localhost:6060/debug/pprof/heap

# Heap profile options:
# -inuse_space   (default) currently allocated bytes
# -inuse_objects  currently allocated object count
# -alloc_space    total bytes allocated (including freed)
# -alloc_objects  total objects allocated (including freed)

# Goroutine profile (debug hanging/leaking goroutines)
go tool pprof http://localhost:6060/debug/pprof/goroutine

# Block profile (time spent blocking on sync primitives)
# Must enable: runtime.SetBlockProfileRate(1)
go tool pprof http://localhost:6060/debug/pprof/block

# Mutex profile (mutex contention)
# Must enable: runtime.SetMutexProfileFraction(5)
go tool pprof http://localhost:6060/debug/pprof/mutex

# Compare two profiles (differential)
go tool pprof -diff_base=base.prof current.prof
```

### Go Trace

```bash
# Capture execution trace
curl -o trace.out http://localhost:6060/debug/pprof/trace?seconds=5
go tool trace trace.out

# Or in code:
# f, _ := os.Create("trace.out")
# trace.Start(f)
# defer trace.Stop()

# Trace viewer shows:
# - Goroutine execution timeline
# - Network blocking
# - Syscall blocking
# - Scheduler latency
# - GC events
```

### Go Escape Analysis

```bash
# See what escapes to heap (allocations you may not expect)
go build -gcflags '-m' ./...

# More verbose
go build -gcflags '-m -m' ./...

# Common escape reasons:
# "moved to heap: x" - variable allocated on heap instead of stack
# "leaking param: x" - parameter escapes the function
# "x escapes to heap" - compiler cannot prove x doesn't outlive the stack frame

# Fix: reduce pointer usage, return values instead of pointers for small types,
# use sync.Pool for frequently allocated objects
```

### GC Tuning

```bash
# GC trace logging
GODEBUG=gctrace=1 ./myapp

# Output format:
# gc N @T% G%: wall_time+cpu_time ms clock, H->H->H MB, S MB goal, P P
# N = GC number, T = time since start, G = fraction of CPU in GC
# H = heap before -> after -> live, S = heap goal

# Set GC target percentage (default 100 = GC when heap doubles)
GOGC=200 ./myapp  # Less frequent GC, more memory usage
GOGC=50 ./myapp   # More frequent GC, less memory usage

# Memory limit (Go 1.19+)
GOMEMLIMIT=1GiB ./myapp  # Hard memory limit
```

## Rust Profiling

### cargo-flamegraph

```bash
# Install
cargo install flamegraph

# Generate flamegraph (release build recommended)
cargo flamegraph --bin myapp
cargo flamegraph --bin myapp -- --arg1 --arg2  # With arguments
cargo flamegraph --bench my_benchmark         # Profile benchmarks

# Linux: may need to set perf permissions
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
# Or run with sudo

# Output: flamegraph.svg in current directory
```

### samply: Modern Profiler

```bash
# Install
cargo install samply

# Profile (opens Firefox Profiler UI)
samply record ./target/release/myapp
samply record ./target/release/myapp -- --arg1

# samply advantages:
# - Uses Firefox Profiler UI (excellent visualization)
# - Shows both CPU and memory
# - Per-thread timeline view
# - Source code annotation
# - No code changes needed
```

### DHAT: Dynamic Heap Analysis

```bash
# Requires nightly Rust or Valgrind
# With Valgrind:
valgrind --tool=dhat ./target/debug/myapp
# Opens dhat-viewer in browser

# DHAT shows:
# - Total bytes allocated
# - Maximum bytes live at any point
# - Total blocks allocated
# - Access patterns (reads/writes per block)
# - Short-lived allocations (allocated and freed quickly)
# - Allocation sites with full backtraces
```

### heaptrack for Rust

```bash
# Install (Linux)
# sudo apt install heaptrack heaptrack-gui

# Profile
heaptrack ./target/release/myapp

# Analyze
heaptrack_gui heaptrack.myapp.*.zst

# heaptrack shows:
# - Allocation timeline
# - Allocation flamegraph
# - Peak memory consumers
# - Temporary allocation hotspots
# - Potential memory leaks (allocated, never freed)
```

### Rust-Specific Optimization Patterns

```rust
// Avoid unnecessary allocations

// BAD: allocates a new String every call
fn process(name: &str) -> String {
    format!("Hello, {}!", name)
}

// GOOD: take ownership when needed, borrow otherwise
fn process(name: &str) -> Cow<'_, str> {
    if name.is_empty() {
        Cow::Borrowed("Hello, stranger!")
    } else {
        Cow::Owned(format!("Hello, {}!", name))
    }
}

// Use SmallVec for usually-small collections
// use smallvec::SmallVec;
// let mut v: SmallVec<[i32; 8]> = SmallVec::new();  // stack-allocated up to 8

// Use iterators instead of collecting
// BAD
let filtered: Vec<_> = items.iter().filter(|x| x > &5).collect();
let sum: i32 = filtered.iter().sum();

// GOOD: no intermediate allocation
let sum: i32 = items.iter().filter(|x| *x > &5).sum();

// Pre-allocate when size is known
let mut v = Vec::with_capacity(1000);  // One allocation
for i in 0..1000 {
    v.push(i);  // No reallocation
}
```

## Browser Profiling

### Chrome DevTools Performance Tab

```
Recording a performance profile:
1. Open DevTools (F12) → Performance tab
2. Click Record (●) or Ctrl+E
3. Perform the action to profile
4. Stop recording
5. Analyze the timeline

Key areas:
├─ Network: request waterfall (blocking, TTFB, download)
├─ Frames: FPS chart (green = 60fps, red = dropped frames)
├─ Timings: FCP, LCP, DCL markers
├─ Main: flame chart of main thread activity
│  ├─ Yellow = JavaScript execution
│  ├─ Purple = Layout/Rendering
│  ├─ Green = Paint/Composite
│  └─ Gray = System/Idle
├─ Raster: paint operations
└─ GPU: GPU activity

Long Tasks (>50ms):
- Flagged with red triangle in the timeline
- Block the main thread, cause jank
- Fix: break into smaller tasks with requestIdleCallback, setTimeout,
  or scheduler.postTask
```

### Core Web Vitals

```
Metric          Target    Measures
─────────────────────────────────────────────────────
LCP             <2.5s     Largest Contentful Paint (perceived load)
INP             <200ms    Interaction to Next Paint (responsiveness)
CLS             <0.1      Cumulative Layout Shift (visual stability)

Measurement tools:
- Lighthouse: npx lighthouse https://example.com --view
- web-vitals library: import { onLCP, onINP, onCLS } from 'web-vitals'
- Chrome DevTools → Performance → Timings row
- PageSpeed Insights: https://pagespeed.web.dev
- CrUX Dashboard (real user data)
```

### React Profiler

```
React DevTools Profiler:
1. Install React DevTools browser extension
2. Open DevTools → Profiler tab
3. Click Record
4. Interact with your app
5. Stop recording

What it shows:
- Commit-by-commit render timeline
- Which components rendered and why
- Render duration per component
- Ranked chart (slowest components)

Programmatic profiling:
import { Profiler } from 'react';

function onRender(id, phase, actualDuration, baseDuration, startTime, commitTime) {
  console.log({ id, phase, actualDuration, baseDuration });
}

<Profiler id="MyComponent" onRender={onRender}>
  <MyComponent />
</Profiler>

// phase: "mount" or "update"
// actualDuration: time spent rendering (with memoization)
// baseDuration: time without memoization (worst case)
```

## Memory Leak Detection Patterns

### Universal Detection Strategy

```
Step 1: Confirm the leak exists
├─ Monitor memory over time (RSS, heap)
├─ Perform repeated action cycles (create/destroy)
├─ Force GC between cycles
└─ If memory grows without bound → leak confirmed

Step 2: Identify the leak type
├─ Growing collections (maps, arrays, caches without eviction)
├─ Event listener accumulation (add without remove)
├─ Closure captures (inner function holds reference to outer scope)
├─ Unreleased resources (file handles, DB connections, sockets)
├─ Circular references (in languages without cycle-collecting GC)
├─ Global state accumulation (module-level variables growing)
└─ Timer/interval not cleared (setInterval without clearInterval)

Step 3: Locate the leak source
├─ Take heap snapshots at different points
├─ Compare snapshots (objects allocated between snap 1 and 2)
├─ Sort by retained size
├─ Follow retainer chains to find root reference
└─ The "GC root → ... → leaked object" chain shows you what to fix
```

### Language-Specific Leak Patterns

```
JavaScript / Node.js:
├─ Closures capturing large scope
│  Fix: null out references, restructure to minimize capture
├─ Event emitter listeners without removeListener
│  Fix: AbortController, cleanup in componentWillUnmount / useEffect return
├─ Global caches without LRU eviction
│  Fix: Use lru-cache package, set maxSize
├─ Detached DOM nodes
│  Fix: Remove event listeners before removing elements
└─ Unresolved Promises holding references
   Fix: Add timeout, ensure rejection paths release resources

Python:
├─ __del__ preventing GC of cycles
│  Fix: Use weakref, avoid __del__, use context managers
├─ Module-level mutable defaults growing
│  Fix: Reset between requests, use request-scoped storage
├─ C extension objects not properly released
│  Fix: Explicit cleanup, context managers
└─ threading.local() without cleanup
   Fix: Clean up in thread exit callback

Go:
├─ Goroutine leaks (blocked goroutines never collected)
│  Fix: Always provide cancellation (context.WithCancel)
├─ time.After in loops (each creates a timer)
│  Fix: Use time.NewTimer with Reset
├─ Slice header retaining large underlying array
│  Fix: Copy needed elements to new slice
└─ sync.Pool objects growing
   Fix: Set reasonable object sizes, profile pool usage

Rust:
├─ Rc/Arc cycles
│  Fix: Use Weak references to break cycles
├─ Forgotten JoinHandle (task never joined/cancelled)
│  Fix: Store and join/abort all spawned tasks
└─ Unbounded channels
   Fix: Use bounded channels, apply backpressure
```

### Leak Investigation Checklists

```
Node.js Leak Investigation:
[ ] Enabled --max-old-space-size to catch OOM earlier
[ ] Took 3+ heap snapshots at intervals
[ ] Compared snapshots in Chrome DevTools (Objects allocated between)
[ ] Sorted by Retained Size to find largest leaked objects
[ ] Followed retainer chain from leaked object to GC root
[ ] Checked event listener count: process._getActiveHandles().length
[ ] Checked timer count: process._getActiveRequests().length
[ ] Tested with clinic doctor for automated diagnosis

Python Leak Investigation:
[ ] Used tracemalloc to identify top allocation sites
[ ] Compared snapshots to find growing allocations
[ ] Used objgraph.show_growth() to find growing object types
[ ] Used objgraph.show_backrefs() to find reference chains
[ ] Checked gc.garbage for objects with __del__ preventing collection
[ ] Used memray --leaks to identify unreleased memory
[ ] Tested with gc.collect() to distinguish real leaks from delayed GC

Go Leak Investigation:
[ ] Checked goroutine count via pprof/goroutine
[ ] Looked for goroutine profile growth over time
[ ] Used runtime.NumGoroutine() in metrics
[ ] Checked for blocked channel operations
[ ] Verified all contexts have cancel called
[ ] Used goleak in tests to catch goroutine leaks
[ ] Compared heap profiles: pprof -diff_base
```
