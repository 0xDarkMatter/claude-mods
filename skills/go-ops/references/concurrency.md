# Go Concurrency Reference

## Table of Contents

1. [Goroutines](#goroutines)
2. [Channels](#channels)
3. [Select](#select)
4. [Context](#context)
5. [Sync Primitives](#sync-primitives)
6. [errgroup](#errgroup)
7. [Worker Pool Pattern](#worker-pool-pattern)
8. [Fan-out / Fan-in](#fan-out--fan-in)
9. [Pipeline Pattern](#pipeline-pattern)
10. [Rate Limiting](#rate-limiting)
11. [Common Mistakes](#common-mistakes)

---

## Goroutines

### Launch Patterns

```go
// Anonymous function - capture variables carefully
go func() {
    doWork()
}()

// Named function
go processItem(item)

// Method
go srv.handleConnection(conn)

// Capture loop variable correctly (pre-Go 1.22)
for _, item := range items {
    item := item // shadow to capture
    go func() {
        process(item)
    }()
}

// Go 1.22+: loop variable captured per iteration automatically
for _, item := range items {
    go func() {
        process(item) // safe in Go 1.22+
    }()
}
```

### Goroutine Lifecycle

Every goroutine needs an exit path. Establish ownership at creation time.

```go
func startWorker(ctx context.Context, jobs <-chan Job) {
    go func() {
        for {
            select {
            case <-ctx.Done():
                return // clean exit on cancellation
            case job, ok := <-jobs:
                if !ok {
                    return // channel closed
                }
                process(job)
            }
        }
    }()
}
```

### Avoid Goroutine Leaks

A goroutine leaks when it blocks forever with no exit condition.

```go
// LEAK: goroutine blocks on send forever if nobody reads
func bad() {
    ch := make(chan int)
    go func() {
        ch <- compute() // blocks if caller exits
    }()
    // if caller returns without reading ch, goroutine leaks
}

// FIX: use buffered channel or context
func good(ctx context.Context) {
    ch := make(chan int, 1) // buffer absorbs the send
    go func() {
        select {
        case ch <- compute():
        case <-ctx.Done():
        }
    }()
}
```

### Cost Model

- Initial stack: ~2 KB (grows as needed, up to 1 GB by default)
- Goroutines are multiplexed onto OS threads by the Go scheduler
- Switching between goroutines is cheap (~100 ns) vs OS thread switch (~1 µs)
- Practical limit: tens of thousands of goroutines; millions is unusual but possible
- Use `runtime.NumGoroutine()` to inspect count; expose via `pprof` in production

---

## Channels

### Buffered vs Unbuffered

```go
// Unbuffered: sender blocks until receiver is ready (synchronous handoff)
ch := make(chan int)

// Buffered: sender blocks only when buffer is full
ch := make(chan int, 10)
```

Use unbuffered when you want a synchronization guarantee (the receiver got the value).
Use buffered to decouple producer/consumer speeds or to avoid goroutine creation.

### Directional Channels

```go
// Restrict channels at function boundaries for clarity and safety
func produce(out chan<- int) { // send-only
    out <- 42
}

func consume(in <-chan int) { // receive-only
    v := <-in
    fmt.Println(v)
}

func wire() {
    ch := make(chan int, 1)
    go produce(ch)
    consume(ch)
}
```

### Close Semantics

```go
// Only the sender should close
close(ch)

// Closed channel returns zero value immediately
v, ok := <-ch
// ok == false means channel is closed and drained

// Panic conditions:
// - closing a nil channel
// - closing an already-closed channel
// - sending on a closed channel
```

### Range over Channel

```go
// Range exits when channel is closed and drained
for v := range ch {
    process(v)
}

// Equivalent explicit loop
for {
    v, ok := <-ch
    if !ok {
        break
    }
    process(v)
}
```

### Nil Channel Behavior

```go
var ch chan int // nil channel

// Sending or receiving on nil blocks forever
// <-ch   // blocks
// ch <- 1 // blocks

// Useful in select to disable a case dynamically
func merge(a, b <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for a != nil || b != nil {
            select {
            case v, ok := <-a:
                if !ok {
                    a = nil // disable this case
                    continue
                }
                out <- v
            case v, ok := <-b:
                if !ok {
                    b = nil // disable this case
                    continue
                }
                out <- v
            }
        }
    }()
    return out
}
```

---

## Select

### Multi-channel Operations

```go
select {
case msg := <-ch1:
    handle(msg)
case ch2 <- value:
    // sent successfully
case <-done:
    return
}
```

### Timeout Pattern

```go
func fetchWithTimeout(url string, timeout time.Duration) (*Response, error) {
    result := make(chan *Response, 1)
    go func() {
        result <- fetch(url)
    }()

    select {
    case resp := <-result:
        return resp, nil
    case <-time.After(timeout):
        return nil, fmt.Errorf("fetch %s: timed out after %v", url, timeout)
    }
}
```

### Non-blocking with Default

```go
// Try to send/receive; skip if not ready
select {
case ch <- value:
    // sent
default:
    // channel full or no receiver; drop or handle
}

// Non-blocking receive
select {
case v := <-ch:
    use(v)
default:
    // nothing available right now
}
```

### Priority Pattern

Go's select is random when multiple cases are ready. Force priority explicitly.

```go
// Drain high-priority channel before processing low-priority
func prioritySelect(hi, lo <-chan Job) {
    for {
        select {
        case job := <-hi:
            process(job)
        default:
            // hi empty; check both
            select {
            case job := <-hi:
                process(job)
            case job := <-lo:
                process(job)
            }
        }
    }
}
```

---

## Context

### Create Root Contexts

```go
ctx := context.Background() // top-level; never cancelled
ctx := context.TODO()       // placeholder; replace before shipping
```

### WithCancel

```go
ctx, cancel := context.WithCancel(parent)
defer cancel() // always defer to free resources

go func() {
    <-ctx.Done()
    fmt.Println("cancelled:", ctx.Err()) // context.Canceled
}()

cancel() // trigger cancellation
```

### WithTimeout and WithDeadline

```go
ctx, cancel := context.WithTimeout(parent, 5*time.Second)
defer cancel()

// WithDeadline takes an absolute time
deadline := time.Now().Add(5 * time.Second)
ctx, cancel = context.WithDeadline(parent, deadline)
defer cancel()

// Check remaining time
if d, ok := ctx.Deadline(); ok {
    remaining := time.Until(d)
    fmt.Println("remaining:", remaining)
}
```

### WithValue

```go
type contextKey string // unexported to avoid collisions

const requestIDKey contextKey = "request-id"

func withRequestID(ctx context.Context, id string) context.Context {
    return context.WithValue(ctx, requestIDKey, id)
}

func requestIDFromContext(ctx context.Context) (string, bool) {
    id, ok := ctx.Value(requestIDKey).(string)
    return id, ok
}
```

### Propagation Rules

- Always pass `ctx` as the first argument to functions that do I/O
- Never store context in a struct field (pass explicitly)
- Derive child contexts; never modify the parent
- Cancel is inherited: cancelling parent cancels all children

### HTTP Middleware Pattern

```go
func requestIDMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        id := r.Header.Get("X-Request-ID")
        if id == "" {
            id = generateID()
        }
        ctx := withRequestID(r.Context(), id)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func handler(w http.ResponseWriter, r *http.Request) {
    id, _ := requestIDFromContext(r.Context())
    // id flows through without explicit passing
}
```

---

## Sync Primitives

### Mutex

```go
type SafeMap struct {
    mu sync.Mutex
    m  map[string]int
}

func (s *SafeMap) Set(key string, val int) {
    s.mu.Lock()
    defer s.mu.Unlock()
    s.m[key] = val
}

func (s *SafeMap) Get(key string) (int, bool) {
    s.mu.Lock()
    defer s.mu.Unlock()
    v, ok := s.m[key]
    return v, ok
}
```

### RWMutex

Use when reads vastly outnumber writes.

```go
type Cache struct {
    mu   sync.RWMutex
    data map[string]string
}

func (c *Cache) Get(key string) (string, bool) {
    c.mu.RLock()         // multiple readers allowed
    defer c.mu.RUnlock()
    v, ok := c.data[key]
    return v, ok
}

func (c *Cache) Set(key, val string) {
    c.mu.Lock()          // exclusive write
    defer c.mu.Unlock()
    c.data[key] = val
}
```

### Once

```go
var (
    instance *DB
    once     sync.Once
)

func GetDB() *DB {
    once.Do(func() {
        instance = connectDB()
    })
    return instance
}
```

### WaitGroup

```go
var wg sync.WaitGroup

for _, url := range urls {
    wg.Add(1)
    go func(u string) {
        defer wg.Done()
        fetch(u)
    }(url)
}

wg.Wait() // block until all goroutines call Done
```

### Pool

```go
var bufPool = sync.Pool{
    New: func() any {
        return new(bytes.Buffer)
    },
}

func processRequest(data []byte) []byte {
    buf := bufPool.Get().(*bytes.Buffer)
    defer func() {
        buf.Reset()
        bufPool.Put(buf)
    }()

    buf.Write(data)
    // transform buf...
    return buf.Bytes()
}
```

### Atomic Operations

```go
import "sync/atomic"

var counter atomic.Int64

counter.Add(1)
counter.Store(0)
v := counter.Load()
swapped := counter.CompareAndSwap(old, new)

// Prefer atomic for simple counters; prefer Mutex for compound operations
```

### When to Use Each

| Primitive | Use When |
|-----------|----------|
| `Mutex` | Protecting a struct with multiple fields |
| `RWMutex` | Read-heavy access; reads >> writes |
| `Once` | One-time initialization |
| `WaitGroup` | Waiting for a collection of goroutines |
| `Pool` | Reusing temporary objects to reduce GC pressure |
| `atomic` | Single integer/pointer with no compound operations |
| Channel | Transferring ownership of data between goroutines |

---

## errgroup

### Basic Usage

```go
import "golang.org/x/sync/errgroup"

func fetchAll(ctx context.Context, urls []string) ([][]byte, error) {
    g, ctx := errgroup.WithContext(ctx)
    results := make([][]byte, len(urls))

    for i, url := range urls {
        i, url := i, url
        g.Go(func() error {
            body, err := get(ctx, url)
            if err != nil {
                return fmt.Errorf("fetch %s: %w", url, err)
            }
            results[i] = body
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return results, nil
}
```

### Limit Concurrency with SetLimit

```go
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(10) // at most 10 goroutines at a time

for _, url := range urls {
    url := url
    g.Go(func() error {
        return process(ctx, url)
    })
}

return g.Wait()
```

### Collect Results Safely

Pre-allocate the result slice before launching goroutines. Each goroutine writes to its own index — no mutex needed because slice indices do not overlap.

```go
type Result struct {
    URL  string
    Data []byte
}

func gather(ctx context.Context, urls []string) ([]Result, error) {
    g, ctx := errgroup.WithContext(ctx)
    results := make([]Result, len(urls))

    for i, url := range urls {
        i, url := i, url
        g.Go(func() error {
            data, err := get(ctx, url)
            if err != nil {
                return err
            }
            results[i] = Result{URL: url, Data: data}
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return results, nil
}
```

---

## Worker Pool Pattern

```go
type Job struct {
    ID   int
    Data []byte
}

type Result struct {
    JobID  int
    Output []byte
    Err    error
}

func workerPool(
    ctx context.Context,
    jobs <-chan Job,
    numWorkers int,
) <-chan Result {
    results := make(chan Result, numWorkers)

    var wg sync.WaitGroup
    for i := 0; i < numWorkers; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for {
                select {
                case <-ctx.Done():
                    return
                case job, ok := <-jobs:
                    if !ok {
                        return
                    }
                    out, err := processJob(job)
                    results <- Result{JobID: job.ID, Output: out, Err: err}
                }
            }
        }()
    }

    // Close results when all workers finish
    go func() {
        wg.Wait()
        close(results)
    }()

    return results
}

func run(ctx context.Context, allJobs []Job) error {
    jobs := make(chan Job, len(allJobs))
    for _, j := range allJobs {
        jobs <- j
    }
    close(jobs)

    results := workerPool(ctx, jobs, 5)

    for r := range results {
        if r.Err != nil {
            return fmt.Errorf("job %d: %w", r.JobID, r.Err)
        }
        fmt.Printf("job %d done\n", r.JobID)
    }
    return nil
}
```

---

## Fan-out / Fan-in

### Fan-out: Distribute One Channel to Many Workers

```go
func fanOut(in <-chan int, n int) []<-chan int {
    outs := make([]<-chan int, n)
    for i := 0; i < n; i++ {
        ch := make(chan int)
        outs[i] = ch
        go func() {
            defer close(ch)
            for v := range in {
                ch <- v
            }
        }()
    }
    return outs
}
```

### Fan-in: Merge Multiple Channels into One

```go
func fanIn(ctx context.Context, ins ...<-chan int) <-chan int {
    out := make(chan int)
    var wg sync.WaitGroup

    forward := func(ch <-chan int) {
        defer wg.Done()
        for {
            select {
            case v, ok := <-ch:
                if !ok {
                    return
                }
                select {
                case out <- v:
                case <-ctx.Done():
                    return
                }
            case <-ctx.Done():
                return
            }
        }
    }

    wg.Add(len(ins))
    for _, ch := range ins {
        go forward(ch)
    }

    go func() {
        wg.Wait()
        close(out)
    }()

    return out
}
```

---

## Pipeline Pattern

Each stage reads from upstream and writes to downstream. Cancellation propagates via context.

```go
func generate(ctx context.Context, nums ...int) <-chan int {
    out := make(chan int)
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

func square(ctx context.Context, in <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for v := range in {
            select {
            case out <- v * v:
            case <-ctx.Done():
                return
            }
        }
    }()
    return out
}

func filter(ctx context.Context, in <-chan int, pred func(int) bool) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for v := range in {
            if pred(v) {
                select {
                case out <- v:
                case <-ctx.Done():
                    return
                }
            }
        }
    }()
    return out
}

func runPipeline(ctx context.Context) {
    nums := generate(ctx, 1, 2, 3, 4, 5)
    squares := square(ctx, nums)
    evens := filter(ctx, squares, func(n int) bool { return n%2 == 0 })

    for v := range evens {
        fmt.Println(v) // 4, 16
    }
}
```

---

## Rate Limiting

### Semaphore Pattern

```go
type Semaphore chan struct{}

func NewSemaphore(n int) Semaphore {
    return make(Semaphore, n)
}

func (s Semaphore) Acquire() { s <- struct{}{} }
func (s Semaphore) Release() { <-s }

func fetchConcurrently(ctx context.Context, urls []string, limit int) {
    sem := NewSemaphore(limit)
    var wg sync.WaitGroup

    for _, url := range urls {
        url := url
        wg.Add(1)
        go func() {
            defer wg.Done()
            sem.Acquire()
            defer sem.Release()
            fetch(ctx, url)
        }()
    }

    wg.Wait()
}
```

### time.Ticker Rate Limiter

```go
func rateLimitedFetch(ctx context.Context, urls []string, rps int) error {
    ticker := time.NewTicker(time.Second / time.Duration(rps))
    defer ticker.Stop()

    for _, url := range urls {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            if err := fetch(ctx, url); err != nil {
                return err
            }
        }
    }
    return nil
}
```

### Token Bucket (using time/rate)

```go
import "golang.org/x/time/rate"

limiter := rate.NewLimiter(rate.Limit(100), 10) // 100 req/s, burst 10

func callAPI(ctx context.Context, req Request) error {
    if err := limiter.Wait(ctx); err != nil {
        return fmt.Errorf("rate limiter: %w", err)
    }
    return sendRequest(req)
}
```

---

## Common Mistakes

### Goroutine Leak: Blocking Send with No Receiver

```go
// BAD
func search(query string) <-chan Result {
    ch := make(chan Result) // unbuffered
    go func() {
        ch <- doSearch(query) // blocks if caller gives up
    }()
    return ch
}

// GOOD: buffer of 1 so goroutine never blocks
func search(ctx context.Context, query string) <-chan Result {
    ch := make(chan Result, 1)
    go func() {
        select {
        case ch <- doSearch(ctx, query):
        case <-ctx.Done():
        }
    }()
    return ch
}
```

### Race Condition: Shared Variable without Protection

```go
// BAD: data race on count
var count int
var wg sync.WaitGroup
for i := 0; i < 100; i++ {
    wg.Add(1)
    go func() {
        defer wg.Done()
        count++ // not safe
    }()
}

// GOOD: use atomic or mutex
var count atomic.Int64
for i := 0; i < 100; i++ {
    wg.Add(1)
    go func() {
        defer wg.Done()
        count.Add(1)
    }()
}
```

### Deadlock: All Goroutines Waiting on Each Other

```go
// BAD: both goroutines block trying to send before anyone reads
ch := make(chan int)
ch <- 1 // blocks main goroutine
go func() { ch <- 2 }() // never reached

// GOOD: buffer or launch reader first
ch := make(chan int, 2)
ch <- 1
ch <- 2
```

### Closing a Channel from the Wrong Side

```go
// BAD: receiver closes channel; sender may still write
func consumer(ch chan int) {
    close(ch) // panics if sender writes after this
}

// GOOD: only the producer closes
func producer(ch chan<- int) {
    defer close(ch)
    for _, v := range data {
        ch <- v
    }
}
```

### WaitGroup Counter Mismatch

```go
// BAD: Add inside goroutine; may call Wait before Add
for _, item := range items {
    go func(item Item) {
        wg.Add(1) // too late
        defer wg.Done()
        process(item)
    }(item)
}
wg.Wait()

// GOOD: Add before launching goroutine
for _, item := range items {
    wg.Add(1)
    go func(item Item) {
        defer wg.Done()
        process(item)
    }(item)
}
wg.Wait()
```

### Detect Races at Test Time

```go
// Always run tests with the race detector
// go test -race ./...
// go build -race ./cmd/server
```
