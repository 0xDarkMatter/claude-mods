---
name: go-ops
description: "Go development patterns, concurrency, error handling, testing, and project structure. Use for: golang, go, goroutine, channel, context, errgroup, go test, go mod, go build, interface, generics, table-driven tests, worker pool, sync.Mutex, sync.WaitGroup, pprof, go vet, golangci-lint, go workspace, functional options, middleware, http handler."
allowed-tools: "Read Write Bash"
related-skills: [docker-ops, ci-cd-ops, api-design-ops, testing-ops]
---

# Go Operations

Comprehensive Go skill covering idiomatic patterns, concurrency, and production practices.

## Module Quick Start

```bash
# New module
go mod init github.com/user/project

# Add dependency
go get github.com/lib/pq@latest

# Tidy (remove unused, add missing)
go mod tidy

# Vendor dependencies
go mod vendor

# Workspace (multi-module)
go work init ./api ./shared
go work use ./cli
```

## Error Handling Decision Tree

```
What kind of error?
│
├─ Known, expected condition (e.g. "not found")
│  └─ Sentinel error: var ErrNotFound = errors.New("not found")
│     └─ Caller checks: errors.Is(err, ErrNotFound)
│
├─ Need to carry structured data (status code, field name)
│  └─ Custom error type: type ValidationError struct { Field, Message string }
│     └─ Implement Error() string
│     └─ Caller checks: errors.As(err, &validErr)
│
├─ Adding context to an existing error
│  └─ Wrap: fmt.Errorf("load config: %w", err)
│     └─ Preserves original for Is/As checks
│
├─ Truly unrecoverable (corrupted state, programmer bug)
│  └─ panic("invariant violated: ...")
│     └─ Almost never in library code
│
└─ Multiple errors from concurrent work
   └─ errors.Join(err1, err2) or multierr package
```

### Error Wrapping Convention

```go
// Add context at each layer, don't repeat the function name
func LoadUser(id int) (*User, error) {
    row, err := db.Query("SELECT ...", id)
    if err != nil {
        return nil, fmt.Errorf("load user %d: %w", id, err)
    }
    // ...
}
```

## Concurrency Decision Tree

```
What's the concurrency pattern?
│
├─ Run N independent tasks, collect results
│  └─ errgroup.Group (cancels on first error)
│
├─ Fire-and-forget background work
│  └─ go func() with context for cancellation
│     └─ ALWAYS handle the error or log it
│
├─ Producer/consumer pipeline
│  └─ Channels (buffered for throughput)
│     └─ Close channel when producer is done
│
├─ Rate-limited concurrent work
│  └─ Semaphore: make(chan struct{}, maxConcurrency)
│
├─ Shared mutable state
│  └─ sync.Mutex or sync.RWMutex
│     └─ Prefer channels if the state is simple
│
├─ One-time initialization
│  └─ sync.Once
│
└─ Wait for N goroutines to finish (no error collection)
   └─ sync.WaitGroup
```

### errgroup Quick Start

```go
import "golang.org/x/sync/errgroup"

g, ctx := errgroup.WithContext(ctx)
g.SetLimit(10) // max 10 concurrent goroutines

for _, url := range urls {
    g.Go(func() error {
        return fetch(ctx, url)
    })
}

if err := g.Wait(); err != nil {
    return fmt.Errorf("fetch urls: %w", err)
}
```

**Deep dive**: Load `./references/concurrency.md` for worker pools, fan-out/fan-in, pipeline patterns, context best practices.

## Interface Design

```
Accept interfaces, return structs.
```

```go
// Good: function accepts interface
func Process(r io.Reader) error { ... }

// Good: return concrete type
func NewServer(cfg Config) *Server { ... }

// Bad: returning interface (hides implementation, prevents extension)
func NewServer(cfg Config) ServerInterface { ... }
```

### Common Stdlib Interfaces

| Interface | Methods | Use For |
|-----------|---------|---------|
| `io.Reader` | `Read([]byte) (int, error)` | Any byte source |
| `io.Writer` | `Write([]byte) (int, error)` | Any byte sink |
| `io.Closer` | `Close() error` | Resource cleanup |
| `fmt.Stringer` | `String() string` | String representation |
| `error` | `Error() string` | Error values |
| `sort.Interface` | `Len, Less, Swap` | Custom sorting |
| `http.Handler` | `ServeHTTP(w, r)` | HTTP handlers |
| `encoding.BinaryMarshaler` | `MarshalBinary() ([]byte, error)` | Binary encoding |

### Functional Options Pattern

```go
type Option func(*Server)

func WithPort(port int) Option {
    return func(s *Server) { s.port = port }
}

func WithTimeout(d time.Duration) Option {
    return func(s *Server) { s.timeout = d }
}

func NewServer(opts ...Option) *Server {
    s := &Server{port: 8080, timeout: 30 * time.Second} // defaults
    for _, opt := range opts {
        opt(s)
    }
    return s
}

// Usage
srv := NewServer(WithPort(9090), WithTimeout(5*time.Second))
```

**Deep dive**: Load `./references/interfaces-generics.md` for generics, type constraints, embedding, type assertions.

## Testing Quick Reference

```go
// Table-driven test
func TestAdd(t *testing.T) {
    tests := []struct {
        name     string
        a, b     int
        expected int
    }{
        {"positive", 1, 2, 3},
        {"zero", 0, 0, 0},
        {"negative", -1, -2, -3},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got := Add(tt.a, tt.b)
            if got != tt.expected {
                t.Errorf("Add(%d, %d) = %d, want %d", tt.a, tt.b, got, tt.expected)
            }
        })
    }
}
```

```bash
# Run tests
go test ./...

# With coverage
go test -cover -coverprofile=coverage.out ./...
go tool cover -html=coverage.out

# Run specific test
go test -run TestAdd ./pkg/math/

# Benchmarks
go test -bench=. -benchmem ./...

# Race detector
go test -race ./...

# Fuzz testing
go test -fuzz=FuzzParse ./...
```

**Deep dive**: Load `./references/testing.md` for mocking with interfaces, httptest, testcontainers, golden files.

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| Nil slice vs empty slice | `var s []int` is nil, `s := []int{}` is empty. `json.Marshal` gives `null` vs `[]` | Use `make([]int, 0)` or `[]int{}` if JSON matters |
| Goroutine leak | Goroutine blocked on channel with no reader/writer | Use `context.WithCancel`, always provide exit path |
| Defer in loop | Deferred calls don't run until function returns | Wrap loop body in a closure or use explicit cleanup |
| Interface nil pitfall | `(*MyType)(nil)` assigned to `error` interface is not `== nil` | Return `nil` explicitly, not a nil typed pointer |
| Range variable capture | Loop var reused (pre-Go 1.22) | Use `go func(v T) { ... }(v)` or upgrade to Go 1.22+ |
| String concatenation in loop | O(n^2) allocation | Use `strings.Builder` |
| `sync.WaitGroup` Add after Go | Race condition | Call `wg.Add(1)` before `go func()` |
| Unbuffered channel deadlock | Send/receive must happen concurrently | Use buffered channel or separate goroutines |
| `map` not safe for concurrent use | Race condition, may crash | Use `sync.Mutex` or `sync.Map` |

## Project Structure

```
project/
├── cmd/
│   ├── api/main.go           # Entry points
│   └── worker/main.go
├── internal/                  # Private packages
│   ├── handler/
│   ├── service/
│   └── repository/
├── pkg/                       # Public packages (optional)
├── go.mod
├── go.sum
├── Makefile                   # or justfile
└── .golangci.yml
```

**Deep dive**: Load `./references/project-structure.md` for workspace mode, build tags, ldflags, linting config.

## Performance Quick Reference

```bash
# CPU profile
go test -cpuprofile=cpu.prof -bench=. ./...
go tool pprof cpu.prof

# Memory profile
go test -memprofile=mem.prof -bench=. ./...
go tool pprof -alloc_space mem.prof

# Trace
go test -trace=trace.out ./...
go tool trace trace.out

# Escape analysis
go build -gcflags='-m' ./...
```

| Optimization | When | Pattern |
|-------------|------|---------|
| Pre-allocate slices | Known size | `make([]T, 0, n)` |
| `strings.Builder` | String concatenation | `var b strings.Builder` |
| `sync.Pool` | Frequent alloc/free of same type | `pool.Get()` / `pool.Put()` |
| Struct field alignment | Memory-sensitive | Group fields by size (largest first) |
| Buffer reuse | I/O-heavy | `bufio.NewReaderSize(r, 64*1024)` |

**Deep dive**: Load `./references/performance.md` for pprof walkthrough, benchmarking patterns, escape analysis.

## Reference Files

Load these for deep-dive topics. Each is self-contained.

| Reference | When to Load |
|-----------|-------------|
| `./references/concurrency.md` | Goroutines, channels, context, sync primitives, worker pools, pipelines |
| `./references/error-handling.md` | Error wrapping, sentinel errors, custom types, multi-error, panic/recover |
| `./references/testing.md` | Table tests, mocking, httptest, benchmarks, fuzz, testcontainers, golden files |
| `./references/interfaces-generics.md` | Interface design, embedding, type assertions, generics, type constraints |
| `./references/project-structure.md` | Standard layout, go.mod, workspaces, build tags, ldflags, golangci-lint |
| `./references/performance.md` | pprof, trace, benchmarks, escape analysis, sync.Pool, struct alignment |

## See Also

- `docker-ops` - Multi-stage builds for Go binaries (scratch/distroless)
- `ci-cd-ops` - Go CI pipelines, caching go modules, goreleaser
- `testing-ops` - Cross-language testing strategies
