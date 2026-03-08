# Go Error Handling Reference

## Table of Contents

1. [Error Basics](#error-basics)
2. [Wrap Errors with %w](#wrap-errors-with-w)
3. [errors.Is and errors.As](#errorsis-and-errorsas)
4. [Sentinel Errors](#sentinel-errors)
5. [Custom Error Types](#custom-error-types)
6. [Error Wrapping Strategy](#error-wrapping-strategy)
7. [panic and recover](#panic-and-recover)
8. [Errors in Goroutines](#errors-in-goroutines)
9. [Multi-Error](#multi-error)
10. [Test Errors](#test-errors)
11. [Anti-Patterns](#anti-patterns)

---

## Error Basics

### The error Interface

```go
type error interface {
    Error() string
}
```

Any type implementing `Error() string` satisfies the `error` interface.

### Create Simple Errors

```go
import "errors"

var err1 = errors.New("something went wrong")

// fmt.Errorf for formatted messages (no wrapping)
err2 := fmt.Errorf("user %d not found", id)

// Return nil to signal success
func divide(a, b float64) (float64, error) {
    if b == 0 {
        return 0, errors.New("division by zero")
    }
    return a / b, nil
}

// Check error
result, err := divide(10, 0)
if err != nil {
    log.Fatal(err)
}
```

---

## Wrap Errors with %w

The `%w` verb creates a wrapped error that preserves the original for inspection with `errors.Is` and `errors.As`.

```go
func getUser(id int64) (*User, error) {
    row := db.QueryRow("SELECT * FROM users WHERE id = ?", id)
    if err := row.Scan(&user); err != nil {
        return nil, fmt.Errorf("get user %d: %w", id, err)
    }
    return &user, nil
}

func loadProfile(id int64) (*Profile, error) {
    user, err := getUser(id)
    if err != nil {
        return nil, fmt.Errorf("load profile: %w", err)
    }
    // ...
    return profile, nil
}
```

The resulting error chain looks like:

```
load profile: get user 42: sql: no rows in result set
```

### Unwrap the Chain

```go
// errors.Unwrap returns the next error in the chain
wrapped := fmt.Errorf("outer: %w", inner)
inner == errors.Unwrap(wrapped) // true

// Walk the full chain manually
for err != nil {
    fmt.Println(err)
    err = errors.Unwrap(err)
}
```

---

## errors.Is and errors.As

### errors.Is — Identity Check

Use `errors.Is` to check whether a specific sentinel error appears anywhere in the chain.

```go
var ErrNotFound = errors.New("not found")

err := fmt.Errorf("query: %w", ErrNotFound)

errors.Is(err, ErrNotFound) // true — searches the whole chain
err == ErrNotFound          // false — direct comparison misses the wrapping
```

### errors.As — Type Check

Use `errors.As` to extract a typed error from anywhere in the chain.

```go
type ValidationError struct {
    Field   string
    Message string
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

err := fmt.Errorf("create user: %w", &ValidationError{Field: "email", Message: "invalid"})

var valErr *ValidationError
if errors.As(err, &valErr) {
    fmt.Println(valErr.Field)   // "email"
    fmt.Println(valErr.Message) // "invalid"
}
```

### Custom Is Method

Implement `Is` when equality should be value-based rather than pointer-based.

```go
type StatusError struct {
    Code int
}

func (e *StatusError) Error() string {
    return fmt.Sprintf("status %d", e.Code)
}

func (e *StatusError) Is(target error) bool {
    t, ok := target.(*StatusError)
    if !ok {
        return false
    }
    return e.Code == t.Code
}

ErrNotFound := &StatusError{Code: 404}

err := fmt.Errorf("request: %w", &StatusError{Code: 404})
errors.Is(err, ErrNotFound) // true — matched by value
```

---

## Sentinel Errors

Sentinel errors are package-level variables used as well-known error values.

```go
var (
    ErrNotFound     = errors.New("not found")
    ErrUnauthorized = errors.New("unauthorized")
    ErrConflict     = errors.New("conflict")
)

func FindUser(id int64) (*User, error) {
    if id == 0 {
        return nil, ErrNotFound
    }
    // ...
}

// Caller checks identity
user, err := FindUser(id)
if errors.Is(err, ErrNotFound) {
    http.Error(w, "Not Found", http.StatusNotFound)
    return
}
```

### Stdlib Sentinel Examples

```go
io.EOF              // end of stream; not an error condition
io.ErrUnexpectedEOF // stream ended mid-record; is an error
sql.ErrNoRows       // query returned zero rows
os.ErrNotExist      // file does not exist (use errors.Is, not ==)
context.Canceled    // context was cancelled
context.DeadlineExceeded // context deadline passed
```

Note: `os.ErrNotExist` wraps multiple underlying errors (`syscall.ENOENT`, etc.). Always use `errors.Is(err, os.ErrNotExist)` rather than direct comparison.

---

## Custom Error Types

### Struct Error with Extra Fields

```go
type NotFoundError struct {
    Resource string
    ID       int64
}

func (e *NotFoundError) Error() string {
    return fmt.Sprintf("%s with id %d not found", e.Resource, e.ID)
}

func GetOrder(id int64) (*Order, error) {
    order := findOrder(id)
    if order == nil {
        return nil, &NotFoundError{Resource: "order", ID: id}
    }
    return order, nil
}

// Extract and use the extra fields
var notFound *NotFoundError
if errors.As(err, &notFound) {
    log.Printf("missing resource: %s %d", notFound.Resource, notFound.ID)
}
```

### HTTPError with Status Code

```go
type HTTPError struct {
    Code    int
    Message string
    Cause   error
}

func (e *HTTPError) Error() string {
    if e.Cause != nil {
        return fmt.Sprintf("HTTP %d: %s: %v", e.Code, e.Message, e.Cause)
    }
    return fmt.Sprintf("HTTP %d: %s", e.Code, e.Message)
}

func (e *HTTPError) Unwrap() error {
    return e.Cause
}

// Implement Unwrap to keep the chain intact
```

---

## Error Wrapping Strategy

### Add Context at Each Layer

```go
// Repository layer: wrap with operation context
func (r *UserRepo) Find(id int64) (*User, error) {
    var u User
    err := r.db.Get(&u, "SELECT * FROM users WHERE id = $1", id)
    if err != nil {
        return nil, fmt.Errorf("find user %d: %w", id, err)
    }
    return &u, nil
}

// Service layer: wrap with business operation context
func (s *UserService) GetProfile(id int64) (*Profile, error) {
    user, err := s.repo.Find(id)
    if err != nil {
        return nil, fmt.Errorf("get profile: %w", err)
    }
    // ...
}

// Handler layer: inspect and translate for the caller
func (h *Handler) handleGetProfile(w http.ResponseWriter, r *http.Request) {
    id := parseID(r)
    profile, err := h.svc.GetProfile(id)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            http.Error(w, "not found", http.StatusNotFound)
            return
        }
        http.Error(w, "internal error", http.StatusInternalServerError)
        log.Printf("get profile: %v", err) // log full chain here
        return
    }
    writeJSON(w, profile)
}
```

### Message Conventions

- Use lowercase for error strings (Go convention)
- Use `: ` to separate context from cause
- Do not end with punctuation
- Do not duplicate information already in the wrapped error

```go
// GOOD
fmt.Errorf("parse config: %w", err)
fmt.Errorf("connect to database %s: %w", dsn, err)

// BAD: redundant — the wrapped error already says "failed"
fmt.Errorf("failed to connect: %w", err)

// BAD: capitalized
fmt.Errorf("Parse config: %w", err)
```

### Log Once, at the Top

```go
// BAD: logged at every layer, duplicates output
func (r *Repo) Find(id int64) (*User, error) {
    err := query()
    if err != nil {
        log.Printf("repo error: %v", err)  // logged here
        return nil, fmt.Errorf("find: %w", err)
    }
}

func (s *Svc) Get(id int64) (*User, error) {
    u, err := r.Find(id)
    if err != nil {
        log.Printf("svc error: %v", err)   // logged again
        return nil, fmt.Errorf("get: %w", err)
    }
}

// GOOD: wrap through; log once at the edge (handler/main)
```

---

## panic and recover

### When panic Is Legitimate

- Programmer errors that cannot be corrected at runtime (nil dereference, index out of range)
- Impossible conditions in initialization (`init` or package `var` blocks)
- Internal consistency violations inside a package (never cross package boundaries)

```go
func mustParseURL(raw string) *url.URL {
    u, err := url.Parse(raw)
    if err != nil {
        panic(fmt.Sprintf("invalid hardcoded URL %q: %v", raw, err))
    }
    return u
}

// Use Must* pattern for hardcoded values only; never for user input
var baseURL = mustParseURL("https://api.example.com")
```

### recover in HTTP Middleware

```go
func recoveryMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer func() {
            if rec := recover(); rec != nil {
                // Log with stack trace
                buf := make([]byte, 4096)
                n := runtime.Stack(buf, false)
                log.Printf("panic recovered: %v\n%s", rec, buf[:n])

                http.Error(w, "internal server error", http.StatusInternalServerError)
            }
        }()
        next.ServeHTTP(w, r)
    })
}
```

### Do Not recover Across Package Boundaries

A library must never let a panic escape to the caller. Recover internally and return an error.

```go
func (p *Parser) Parse(input []byte) (result Result, err error) {
    defer func() {
        if rec := recover(); rec != nil {
            err = fmt.Errorf("parse panicked: %v", rec)
        }
    }()
    result = p.doParse(input)
    return
}
```

---

## Errors in Goroutines

### Channel-Based

```go
func runAsync(ctx context.Context, fn func() error) <-chan error {
    errCh := make(chan error, 1) // buffer of 1 prevents leak
    go func() {
        errCh <- fn()
    }()
    return errCh
}

errCh := runAsync(ctx, doWork)

select {
case err := <-errCh:
    if err != nil {
        return fmt.Errorf("async work: %w", err)
    }
case <-ctx.Done():
    return ctx.Err()
}
```

### errgroup (Preferred)

```go
g, ctx := errgroup.WithContext(ctx)

g.Go(func() error {
    return stepA(ctx)
})
g.Go(func() error {
    return stepB(ctx)
})

// Wait returns the first non-nil error; other goroutines see ctx cancelled
if err := g.Wait(); err != nil {
    return fmt.Errorf("pipeline: %w", err)
}
```

### Error Aggregation

When all errors matter (not just the first):

```go
type MultiError struct {
    Errors []error
}

func (m *MultiError) Error() string {
    msgs := make([]string, len(m.Errors))
    for i, e := range m.Errors {
        msgs[i] = e.Error()
    }
    return strings.Join(msgs, "; ")
}

func runAll(fns []func() error) error {
    var mu sync.Mutex
    var errs []error
    var wg sync.WaitGroup

    for _, fn := range fns {
        fn := fn
        wg.Add(1)
        go func() {
            defer wg.Done()
            if err := fn(); err != nil {
                mu.Lock()
                errs = append(errs, err)
                mu.Unlock()
            }
        }()
    }

    wg.Wait()
    if len(errs) > 0 {
        return &MultiError{Errors: errs}
    }
    return nil
}
```

---

## Multi-Error

### errors.Join (Go 1.20+)

```go
err1 := errors.New("validation failed on field email")
err2 := errors.New("validation failed on field phone")

combined := errors.Join(err1, err2)
fmt.Println(combined)
// validation failed on field email
// validation failed on field phone

errors.Is(combined, err1) // true
errors.Is(combined, err2) // true
```

### Collect Validation Errors

```go
func validateUser(u User) error {
    var errs []error

    if u.Name == "" {
        errs = append(errs, errors.New("name is required"))
    }
    if !isValidEmail(u.Email) {
        errs = append(errs, fmt.Errorf("email %q is invalid", u.Email))
    }
    if u.Age < 0 {
        errs = append(errs, errors.New("age must not be negative"))
    }

    return errors.Join(errs...) // nil if errs is empty
}
```

---

## Test Errors

### Check Sentinel Errors with errors.Is

```go
func TestFindUser_NotFound(t *testing.T) {
    repo := NewRepo(testDB)

    _, err := repo.Find(999)

    if !errors.Is(err, ErrNotFound) {
        t.Errorf("expected ErrNotFound, got %v", err)
    }
}
```

### Extract Typed Errors with errors.As

```go
func TestValidate_InvalidEmail(t *testing.T) {
    err := validateUser(User{Name: "Alice", Email: "bad"})

    var valErr *ValidationError
    if !errors.As(err, &valErr) {
        t.Fatalf("expected *ValidationError, got %T: %v", err, err)
    }
    if valErr.Field != "email" {
        t.Errorf("expected field 'email', got %q", valErr.Field)
    }
}
```

### Table-Driven Error Tests

```go
func TestDivide(t *testing.T) {
    tests := []struct {
        name    string
        a, b    float64
        wantErr bool
        errIs   error
    }{
        {"normal", 10, 2, false, nil},
        {"divide by zero", 10, 0, true, ErrDivisionByZero},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            _, err := Divide(tt.a, tt.b)
            if (err != nil) != tt.wantErr {
                t.Fatalf("wantErr=%v, got err=%v", tt.wantErr, err)
            }
            if tt.errIs != nil && !errors.Is(err, tt.errIs) {
                t.Errorf("errors.Is(%v, %v) = false", err, tt.errIs)
            }
        })
    }
}
```

---

## Anti-Patterns

### Stringly-Typed Error Checks

```go
// BAD: fragile; breaks on message change
if err.Error() == "not found" { ... }
if strings.Contains(err.Error(), "timeout") { ... }

// GOOD: use sentinel or typed errors
if errors.Is(err, ErrNotFound) { ... }

var netErr *net.OpError
if errors.As(err, &netErr) && netErr.Timeout() { ... }
```

### Swallowing Errors

```go
// BAD: silent discard
result, _ := doSomething()
json.Unmarshal(data, &v) // ignoring error

// GOOD: handle or at minimum log
result, err := doSomething()
if err != nil {
    return fmt.Errorf("doSomething: %w", err)
}

if err := json.Unmarshal(data, &v); err != nil {
    return fmt.Errorf("unmarshal response: %w", err)
}
```

### Log and Return (Double Logging)

```go
// BAD: causes duplicate log lines
func getUser(id int64) (*User, error) {
    user, err := db.Find(id)
    if err != nil {
        log.Printf("db.Find error: %v", err) // logged here
        return nil, fmt.Errorf("find user: %w", err)
    }
    return user, nil
}
// caller also logs → same error appears twice

// GOOD: wrap and propagate; log once at the boundary
func getUser(id int64) (*User, error) {
    user, err := db.Find(id)
    if err != nil {
        return nil, fmt.Errorf("find user %d: %w", id, err)
    }
    return user, nil
}
```

### Over-Wrapping with Redundant Context

```go
// BAD: "failed to" is noise; wrapped error already explains what happened
return fmt.Errorf("failed to get user: failed to query database: %w", err)

// GOOD: each layer adds one meaningful label
return fmt.Errorf("get user %d: %w", id, err)
```

### Panic for Expected Errors

```go
// BAD: panicking on user-controlled input
func ParseAge(s string) int {
    n, err := strconv.Atoi(s)
    if err != nil {
        panic("invalid age") // crashes the program
    }
    return n
}

// GOOD: return the error
func ParseAge(s string) (int, error) {
    n, err := strconv.Atoi(s)
    if err != nil {
        return 0, fmt.Errorf("parse age %q: %w", s, err)
    }
    return n, nil
}
```

### Returning Non-nil Error with Non-zero Value

```go
// BAD: caller may use the value even when err != nil
func compute() (Result, error) {
    if bad {
        return Result{partial: true}, errors.New("incomplete")
    }
}

// GOOD: return zero value on error so callers don't accidentally use it
func compute() (Result, error) {
    if bad {
        return Result{}, errors.New("incomplete")
    }
}
```
