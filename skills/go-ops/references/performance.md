# Go Performance Reference

## Table of Contents

1. [pprof](#pprof)
2. [go tool trace](#go-tool-trace)
3. [Benchmarks](#benchmarks)
4. [Escape Analysis](#escape-analysis)
5. [Memory Optimization](#memory-optimization)
6. [String Performance](#string-performance)
7. [Struct Alignment](#struct-alignment)
8. [Map Performance](#map-performance)
9. [I/O Performance](#io-performance)
10. [Inlining](#inlining)
11. [Common Performance Anti-Patterns](#common-performance-anti-patterns)

---

## pprof

### Enable pprof in a Production Server

```go
import (
    "net/http"
    _ "net/http/pprof"  // Side-effect import registers handlers on DefaultServeMux
)

func main() {
    // Serve pprof on a separate port — never expose this publicly
    go func() {
        log.Println(http.ListenAndServe("localhost:6060", nil))
    }()

    // ... start your actual server
}
```

### Collect and Analyze CPU Profiles

```bash
# 30-second CPU profile from a running server
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30

# Inside pprof interactive shell
(pprof) top10          # Top 10 functions by CPU
(pprof) list myFunc    # Annotated source for a function
(pprof) web            # Open flame graph in browser (requires graphviz)
(pprof) png > cpu.png  # Export to image
```

### Collect and Analyze Memory Profiles

```bash
# Heap profile (in-use allocations)
go tool pprof http://localhost:6060/debug/pprof/heap

# Allocation profile (all allocations since start)
go tool pprof http://localhost:6060/debug/pprof/allocs

# Inside pprof
(pprof) top            # Top allocators
(pprof) inuse_space    # Sort by in-use bytes
(pprof) alloc_objects  # Sort by allocation count
```

### Profile Goroutines

```bash
# Goroutine profile — shows all running goroutines with stack traces
go tool pprof http://localhost:6060/debug/pprof/goroutine

# Or view in browser for a quick human-readable dump
curl http://localhost:6060/debug/pprof/goroutine?debug=2
```

### Write Profiles Programmatically

```go
import "runtime/pprof"

// CPU profile
f, _ := os.Create("cpu.prof")
pprof.StartCPUProfile(f)
defer pprof.StopCPUProfile()

// Memory profile (write at end of program or specific checkpoint)
f, _ := os.Create("mem.prof")
runtime.GC()  // Force GC for accurate snapshot
pprof.WriteHeapProfile(f)
f.Close()
```

### Compare Two Profiles

```bash
# Capture baseline and after a change, then diff them
go tool pprof -base baseline.prof current.prof
```

---

## go tool trace

The tracer records goroutine scheduling, GC pauses, and syscalls at microsecond resolution.

### Record a Trace

```bash
# From a live server
curl http://localhost:6060/debug/pprof/trace?seconds=5 > trace.out

# Or programmatically
import "runtime/trace"

f, _ := os.Create("trace.out")
trace.Start(f)
defer trace.Stop()
```

### Analyze a Trace

```bash
go tool trace trace.out   # Opens browser-based UI
```

Key views in the UI:

- **Goroutine analysis**: Which goroutines ran, for how long, what blocked them
- **View trace**: Timeline of all goroutines across P (processor) threads
- **Minimum mutator utilization (MMU)**: Percentage of time your code ran vs GC

### Identify Scheduling Latency

Look for goroutines spending time in "Runnable" state — this means they are ready to run but waiting for a P. Signs of over-subscription: too many goroutines competing for `GOMAXPROCS` slots.

```go
// Instrument specific regions in the trace
import "runtime/trace"

ctx, task := trace.NewTask(ctx, "processOrder")
defer task.End()

trace.WithRegion(ctx, "validateInput", func() {
    validate(input)
})
```

---

## Benchmarks

### Write Effective Benchmarks

```go
func BenchmarkProcess(b *testing.B) {
    data := generateLargeInput()  // Setup before timer

    b.ResetTimer()  // Exclude setup from measurement
    for i := 0; i < b.N; i++ {
        Process(data)
    }
}
```

### Use b.StopTimer / b.StartTimer for Per-Iteration Setup

```go
func BenchmarkSort(b *testing.B) {
    for i := 0; i < b.N; i++ {
        b.StopTimer()
        data := generateUnsortedSlice(1000)  // Re-create per iteration
        b.StartTimer()

        sort.Ints(data)
    }
}
```

### Allocations Matter — Report Them

```go
func BenchmarkParse(b *testing.B) {
    b.ReportAllocs()  // Show allocs/op and B/op in output
    for i := 0; i < b.N; i++ {
        Parse(input)
    }
}
```

### Run Benchmarks

```bash
go test -bench=. -benchmem -count=5 ./...

# Run only matching benchmarks
go test -bench=BenchmarkProcess -benchmem -run=^$ ./pkg/processor

# -run=^$ suppresses tests, runs only benchmarks
```

### Compare Results with benchstat

```bash
go install golang.org/x/perf/cmd/benchstat@latest

# Capture two runs
go test -bench=. -count=10 ./... > before.txt
# Make your change
go test -bench=. -count=10 ./... > after.txt

benchstat before.txt after.txt
```

Output shows statistical significance: `p < 0.05` means the difference is likely real, not noise. Use `-count=10` or more for reliable statistics.

---

## Escape Analysis

### Inspect Escape Decisions

```bash
go build -gcflags='-m' ./...         # Basic escape analysis
go build -gcflags='-m=2' ./...       # Verbose (shows escape reason)
go test -gcflags='-m' ./...          # On test files
```

### Understand Heap vs Stack

Values escape to the heap when:

- Their address is returned or stored in a longer-lived structure
- They are assigned to an interface
- They are too large for the stack (default stack starts at 8KB, goroutines grow as needed but large locals still escape)
- The compiler cannot prove the lifetime is bounded

```go
// Stack allocated — does NOT escape
func sumSquares(nums []int) int {
    total := 0  // total stays on stack
    for _, n := range nums {
        total += n * n
    }
    return total
}

// Heap allocated — escapes because address is returned
func newCounter() *int {
    n := 0
    return &n  // n escapes: "moved to heap: n"
}

// Interface assignment causes escape
func logValue(v interface{}) {  // Passing int here allocates on heap
    fmt.Println(v)
}
```

### Reduce Allocations with Value Receivers

```go
// BAD: Pointer causes allocation when assigned to interface
type Point struct{ X, Y float64 }
func (p *Point) String() string { return fmt.Sprintf("(%f, %f)", p.X, p.Y) }

// GOOD: Value receiver, may stay on stack
func (p Point) String() string { return fmt.Sprintf("(%f, %f)", p.X, p.Y) }
```

---

## Memory Optimization

### Use sync.Pool for Frequently Allocated Short-Lived Objects

```go
var bufPool = sync.Pool{
    New: func() interface{} {
        return new(bytes.Buffer)
    },
}

func formatMessage(data []byte) string {
    buf := bufPool.Get().(*bytes.Buffer)
    defer func() {
        buf.Reset()
        bufPool.Put(buf)
    }()

    buf.Write(data)
    // ... format into buf
    return buf.String()
}
```

Pool objects may be collected by GC at any time. Never store state that must survive across GC cycles in a pool.

### Pre-Allocate Slices

```go
// BAD: O(n) reallocations as slice grows
var results []Result
for _, item := range items {
    results = append(results, process(item))
}

// GOOD: Single allocation
results := make([]Result, 0, len(items))
for _, item := range items {
    results = append(results, process(item))
}
```

### Reuse Slices Across Calls

```go
type Processor struct {
    buf []byte  // Reused across calls
}

func (p *Processor) Process(input []byte) []byte {
    p.buf = p.buf[:0]           // Reset length, keep capacity
    p.buf = append(p.buf, input...)
    // ... transform p.buf
    return p.buf
}
```

### Avoid Large Value Copies

```go
type LargeStruct struct {
    Data [4096]byte
    // ...
}

// BAD: Copies 4KB on every call
func processLarge(s LargeStruct) { ... }

// GOOD: Pass pointer
func processLarge(s *LargeStruct) { ... }
```

---

## String Performance

### Use strings.Builder for Concatenation

```go
// BAD: Creates a new string on every iteration
var result string
for _, s := range parts {
    result += s + ", "
}

// GOOD: Single allocation
var sb strings.Builder
sb.Grow(estimatedSize)  // Pre-grow if you know the size
for _, s := range parts {
    sb.WriteString(s)
    sb.WriteString(", ")
}
result := sb.String()
```

### Convert Between []byte and string Without Allocation

The standard `string(b)` and `[]byte(s)` conversions always allocate. For read-only access within a single goroutine, use `unsafe`:

```go
import "unsafe"

// []byte to string — zero copy, safe only if you don't modify b afterward
func bytesToString(b []byte) string {
    return unsafe.String(unsafe.SliceData(b), len(b))
}

// string to []byte — zero copy, safe only for reads
func stringToBytes(s string) []byte {
    return unsafe.Slice(unsafe.StringData(s), len(s))
}
```

These are valid as of Go 1.20. Do not use the older `*(*string)(unsafe.Pointer(&b))` pattern.

### Avoid fmt.Sprintf for Simple Concatenation

```go
// BAD: Heap allocation, format parsing overhead
key := fmt.Sprintf("%s:%d", prefix, id)

// GOOD: strconv is faster for basic conversions
key := prefix + ":" + strconv.Itoa(id)

// GOOD: For multiple parts, strings.Join or Builder
key := strings.Join([]string{prefix, strconv.Itoa(id)}, ":")
```

---

## Struct Alignment

The CPU reads memory in aligned chunks. Padding bytes are inserted to satisfy alignment requirements. Reordering fields from largest to smallest eliminates wasted bytes.

```go
// BAD: 24 bytes due to padding
type BadLayout struct {
    Active  bool    // 1 byte + 7 bytes padding
    Count   int64   // 8 bytes
    Flag    bool    // 1 byte + 7 bytes padding
}

// GOOD: 16 bytes, no padding
type GoodLayout struct {
    Count   int64   // 8 bytes
    Active  bool    // 1 byte
    Flag    bool    // 1 byte + 6 bytes padding (to align to 8)
}
```

### Check Sizes and Padding

```go
import "unsafe"

fmt.Println(unsafe.Sizeof(BadLayout{}))   // 24
fmt.Println(unsafe.Sizeof(GoodLayout{}))  // 16
```

### Use fieldalignment to Find Problems Automatically

```bash
go install golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment@latest

fieldalignment ./...         # Report structs with inefficient layout
fieldalignment -fix ./...    # Rewrite fields automatically
```

### Cache Line Considerations for Concurrent Structs

Fields accessed by different goroutines should be on separate cache lines (64 bytes) to prevent false sharing:

```go
type Counters struct {
    reads  int64
    _      [56]byte  // Pad to fill cache line
    writes int64
}
```

---

## Map Performance

### Pre-Size Maps

```go
// BAD: Map grows incrementally, triggering multiple rehashes
m := make(map[string]int)
for _, item := range items {
    m[item.Key] = item.Value
}

// GOOD: Single allocation
m := make(map[string]int, len(items))
for _, item := range items {
    m[item.Key] = item.Value
}
```

### Use Switch for Small Key Sets

For fewer than ~8 fixed string keys, a switch statement is faster than a map due to branch prediction and no hashing overhead:

```go
// Faster for small, known sets
func httpMethodCode(method string) int {
    switch method {
    case "GET":    return 0
    case "POST":   return 1
    case "PUT":    return 2
    case "DELETE": return 3
    default:       return -1
    }
}
```

### Choose sync.Map vs Sharded Map

`sync.Map` is optimized for two specific cases:
1. Write-once, read-many (mostly reads after initial population)
2. Many goroutines reading/writing disjoint keys

For general concurrent access with frequent writes, a sharded map with per-shard mutexes outperforms `sync.Map`:

```go
const numShards = 256

type ShardedMap struct {
    shards [numShards]struct {
        sync.RWMutex
        m map[string]interface{}
    }
}

func (sm *ShardedMap) shard(key string) int {
    h := fnv.New32()
    h.Write([]byte(key))
    return int(h.Sum32()) % numShards
}

func (sm *ShardedMap) Get(key string) (interface{}, bool) {
    s := &sm.shards[sm.shard(key)]
    s.RLock()
    v, ok := s.m[key]
    s.RUnlock()
    return v, ok
}
```

---

## I/O Performance

### Always Wrap with bufio

Unbuffered reads and writes issue a syscall for every call. Buffering batches them:

```go
// BAD: Syscall per line
f, _ := os.Open("data.txt")
scanner := bufio.NewScanner(f)  // This is already buffered — correct

// BAD: Syscall per Write call
f, _ := os.Create("out.txt")
fmt.Fprintln(f, line)  // Goes through direct write

// GOOD: Buffered writes
f, _ := os.Create("out.txt")
bw := bufio.NewWriterSize(f, 64*1024)  // 64KB buffer
defer bw.Flush()
fmt.Fprintln(bw, line)
```

### Use io.Copy for Efficient Transfers

`io.Copy` uses a 32KB internal buffer and delegates to `sendfile(2)` or `splice(2)` when both sides support it (e.g., `*os.File` to `*net.TCPConn`):

```go
// Efficient file download with no intermediate allocation
func serveFile(w http.ResponseWriter, path string) error {
    f, err := os.Open(path)
    if err != nil {
        return err
    }
    defer f.Close()

    _, err = io.Copy(w, f)
    return err
}
```

### Use io.Pipe for Producer-Consumer Pipelines

```go
pr, pw := io.Pipe()

go func() {
    defer pw.Close()
    json.NewEncoder(pw).Encode(largeStruct)  // Streams without buffering whole JSON
}()

http.Post(url, "application/json", pr)
```

### Limit Reads to Avoid Memory Exhaustion

```go
const maxBodySize = 1 << 20  // 1MB

r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)
if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
    http.Error(w, "request too large or invalid", http.StatusBadRequest)
    return
}
```

---

## Inlining

The compiler inlines small functions to eliminate call overhead. A function is inlined when its "cost" (an internal AST node count) stays below a threshold (~80 nodes).

### Check What Gets Inlined

```bash
go build -gcflags='-m' ./...

# Output includes:
# ./pkg/math.go:12:6: can inline Add
# ./pkg/handler.go:45:12: inlining call to Add
# ./pkg/handler.go:60:5: cannot inline processLarge: function too complex
```

### Write Inlineable Functions

```go
// Inlineable: small, no closures, no defer
func clamp(v, min, max int) int {
    if v < min { return min }
    if v > max { return max }
    return v
}

// NOT inlineable: contains a closure
func makeAdder(n int) func(int) int {
    return func(x int) int { return x + n }
}
```

### Prevent Inlining

```go
//go:noinline  // Force a function to never be inlined (useful for benchmarking)
func expensiveOperation(data []byte) Result {
    // ...
}
```

Use `//go:noinline` in benchmarks when you want to measure the cost of a function call itself, or to prevent the compiler from optimizing away a call you want to measure.

---

## Common Performance Anti-Patterns

### Reflection in Hot Paths

Reflection bypasses type-system optimizations, performs map lookups, and allocates. Avoid in code called frequently:

```go
// BAD: reflect.ValueOf allocates, method lookup is slow
func setField(obj interface{}, name string, value interface{}) {
    v := reflect.ValueOf(obj).Elem()
    v.FieldByName(name).Set(reflect.ValueOf(value))
}

// GOOD: Generated code or type switch
func applyUpdate(u *User, field string, value interface{}) {
    switch field {
    case "Name":  u.Name = value.(string)
    case "Email": u.Email = value.(string)
    }
}
```

### fmt.Sprintf in Hot Paths

`fmt.Sprintf` parses a format string, uses reflection, and typically allocates:

```go
// BAD in hot path
key := fmt.Sprintf("user:%d:session:%s", userID, sessionID)

// GOOD: strconv + concatenation
key := "user:" + strconv.FormatInt(userID, 10) + ":session:" + sessionID

// GOOD for complex formatting: pre-build a template or use strings.Builder
```

### Unnecessary Allocations in Loops

```go
// BAD: Allocates a new map every iteration
for _, item := range items {
    m := map[string]int{"count": item.Count}
    process(m)
}

// GOOD: Allocate once, reuse
m := make(map[string]int, 1)
for _, item := range items {
    m["count"] = item.Count
    process(m)
    // Clear before next iteration if needed
    for k := range m { delete(m, k) }
}
```

### Goroutine Leak from Unclosed Channels

```go
// BAD: Goroutine blocked forever if consumer exits early
func generate(nums ...int) <-chan int {
    out := make(chan int)
    go func() {
        for _, n := range nums {
            out <- n  // Blocks forever if nobody reads
        }
        close(out)
    }()
    return out
}

// GOOD: Use context for cancellation
func generate(ctx context.Context, nums ...int) <-chan int {
    out := make(chan int, len(nums))
    go func() {
        defer close(out)
        for _, n := range nums {
            select {
            case out <- n:
            case <-ctx.Done():
                return
            }
        }
    }()
    return out
}
```

### Copying a Mutex

Mutexes must not be copied after first use. Copying a locked mutex will deadlock; copying an unlocked mutex silently creates a new, independent lock:

```go
// BAD: Copies the mutex
type Cache struct{ mu sync.Mutex; data map[string]int }
func copyCache(c Cache) Cache { return c }  // Copies mu — wrong

// GOOD: Always pass and return pointers for types containing mutexes
func processCache(c *Cache) { ... }
```

### Defer in a Tight Loop

Defers execute at function return, not loop iteration. Inside a loop, defers pile up and all run together at the end:

```go
// BAD: All files stay open until the function returns
for _, path := range paths {
    f, _ := os.Open(path)
    defer f.Close()  // Runs at function exit, not loop end
    process(f)
}

// GOOD: Wrap in a closure or extract to a helper
for _, path := range paths {
    func() {
        f, _ := os.Open(path)
        defer f.Close()  // Now runs at end of this closure
        process(f)
    }()
}
```
