# Go Testing Reference

## Table of Contents

1. [Table-Driven Tests](#1-table-driven-tests)
2. [Test Helpers](#2-test-helpers)
3. [Mocking with Interfaces](#3-mocking-with-interfaces)
4. [testify](#4-testify)
5. [httptest](#5-httptest)
6. [Benchmarks](#6-benchmarks)
7. [Fuzz Testing](#7-fuzz-testing)
8. [Integration Tests](#8-integration-tests)
9. [Golden Files](#9-golden-files)
10. [Test Fixtures and TestMain](#10-test-fixtures-and-testmain)
11. [Race Detection](#11-race-detection)
12. [Coverage](#12-coverage)

---

## 1. Table-Driven Tests

Write tests as a slice of structs. Name the slice `tests` and each element `tt`. Run each with `t.Run`.

```go
func TestDivide(t *testing.T) {
    t.Parallel()

    tests := []struct {
        name      string
        dividend  float64
        divisor   float64
        want      float64
        wantErr   bool
    }{
        {name: "positive", dividend: 10, divisor: 2, want: 5},
        {name: "negative divisor", dividend: 10, divisor: -2, want: -5},
        {name: "fractional result", dividend: 7, divisor: 2, want: 3.5},
        {name: "zero divisor", dividend: 10, divisor: 0, wantErr: true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            t.Parallel() // run subtests in parallel when safe

            got, err := Divide(tt.dividend, tt.divisor)

            if tt.wantErr {
                if err == nil {
                    t.Fatal("expected error, got nil")
                }
                return
            }

            if err != nil {
                t.Fatalf("unexpected error: %v", err)
            }
            if got != tt.want {
                t.Errorf("Divide(%v, %v) = %v, want %v",
                    tt.dividend, tt.divisor, got, tt.want)
            }
        })
    }
}
```

Use `t.Fatal` when further execution is meaningless. Use `t.Error` to accumulate multiple failures. Capture loop variables before `t.Parallel()` in Go versions before 1.22 (Go 1.22+ fixes loop variable capture automatically).

---

## 2. Test Helpers

### t.Helper

Mark helper functions with `t.Helper()` so failures report the caller's line, not the helper's.

```go
func assertNoError(t *testing.T, err error) {
    t.Helper()
    if err != nil {
        t.Fatalf("unexpected error: %v", err)
    }
}

func assertEqual[T comparable](t *testing.T, got, want T) {
    t.Helper()
    if got != want {
        t.Errorf("got %v, want %v", got, want)
    }
}
```

### t.Cleanup

Register cleanup functions that run even if the test panics or calls `t.Fatal`.

```go
func newTestDB(t *testing.T) *sql.DB {
    t.Helper()

    db, err := sql.Open("sqlite3", ":memory:")
    if err != nil {
        t.Fatalf("opening db: %v", err)
    }

    t.Cleanup(func() {
        if err := db.Close(); err != nil {
            t.Errorf("closing db: %v", err)
        }
    })

    return db
}
```

### t.TempDir

Use `t.TempDir()` instead of `os.MkdirTemp`. It is automatically removed after the test.

```go
func TestWriteFile(t *testing.T) {
    dir := t.TempDir() // cleaned up automatically

    path := filepath.Join(dir, "output.txt")
    err := WriteFile(path, []byte("hello"))
    if err != nil {
        t.Fatal(err)
    }

    got, err := os.ReadFile(path)
    if err != nil {
        t.Fatal(err)
    }
    if string(got) != "hello" {
        t.Errorf("got %q, want %q", got, "hello")
    }
}
```

### testdata Directory

Place static input files in `testdata/`. The Go tool ignores this directory for builds. Reference files relative to the package root using `filepath.Join("testdata", "input.json")`.

```go
func TestParseConfig(t *testing.T) {
    data, err := os.ReadFile(filepath.Join("testdata", "config.json"))
    if err != nil {
        t.Fatal(err)
    }

    cfg, err := ParseConfig(data)
    if err != nil {
        t.Fatalf("ParseConfig: %v", err)
    }
    if cfg.Port != 8080 {
        t.Errorf("got port %d, want 8080", cfg.Port)
    }
}
```

---

## 3. Mocking with Interfaces

Define narrow interfaces at the point of use, not in the package that implements them.

```go
// Define the interface (in the consumer's package)
type UserStore interface {
    GetUser(ctx context.Context, id int64) (*User, error)
    SaveUser(ctx context.Context, u *User) error
}

// Hand-rolled mock (no external dependencies)
type mockUserStore struct {
    getUser  func(ctx context.Context, id int64) (*User, error)
    saveUser func(ctx context.Context, u *User) error
    calls    []string
}

func (m *mockUserStore) GetUser(ctx context.Context, id int64) (*User, error) {
    m.calls = append(m.calls, "GetUser")
    if m.getUser != nil {
        return m.getUser(ctx, id)
    }
    return nil, nil
}

func (m *mockUserStore) SaveUser(ctx context.Context, u *User) error {
    m.calls = append(m.calls, "SaveUser")
    if m.saveUser != nil {
        return m.saveUser(ctx, u)
    }
    return nil
}

// Test using the mock
func TestUserService_Promote(t *testing.T) {
    store := &mockUserStore{
        getUser: func(_ context.Context, id int64) (*User, error) {
            return &User{ID: id, Role: "member"}, nil
        },
        saveUser: func(_ context.Context, u *User) error {
            if u.Role != "admin" {
                return fmt.Errorf("expected role admin, got %s", u.Role)
            }
            return nil
        },
    }

    svc := NewUserService(store)
    err := svc.Promote(context.Background(), 42)
    if err != nil {
        t.Fatalf("Promote: %v", err)
    }
    if len(store.calls) != 2 {
        t.Errorf("expected 2 calls, got %d: %v", len(store.calls), store.calls)
    }
}
```

---

## 4. testify

Install: `go get github.com/stretchr/testify`.

### assert vs require

`assert` logs failure and continues. `require` stops the test immediately (calls `t.FailNow`).

```go
import (
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestUserCreation(t *testing.T) {
    user, err := NewUser("alice@example.com")

    require.NoError(t, err)            // stop if error
    require.NotNil(t, user)            // stop if nil

    assert.Equal(t, "alice@example.com", user.Email)
    assert.Empty(t, user.PasswordHash) // multiple checks continue on failure
    assert.WithinDuration(t, time.Now(), user.CreatedAt, time.Second)
}
```

### testify/suite

Group related tests with shared setup/teardown.

```go
import "github.com/stretchr/testify/suite"

type UserSuite struct {
    suite.Suite
    db  *sql.DB
    svc *UserService
}

func (s *UserSuite) SetupSuite() {
    db, err := sql.Open("sqlite3", ":memory:")
    s.Require().NoError(err)
    s.db = db
    s.svc = NewUserService(db)
}

func (s *UserSuite) TearDownSuite() {
    s.db.Close()
}

func (s *UserSuite) SetupTest() {
    _, err := s.db.Exec("DELETE FROM users")
    s.Require().NoError(err)
}

func (s *UserSuite) TestCreate() {
    u, err := s.svc.Create(context.Background(), "bob@example.com")
    s.Require().NoError(err)
    s.Equal("bob@example.com", u.Email)
}

func TestUserSuite(t *testing.T) {
    suite.Run(t, new(UserSuite))
}
```

### testify/mock

Use `mock.Mock` for dynamic expectations with call counting.

```go
import "github.com/stretchr/testify/mock"

type MockStore struct {
    mock.Mock
}

func (m *MockStore) GetUser(ctx context.Context, id int64) (*User, error) {
    args := m.Called(ctx, id)
    return args.Get(0).(*User), args.Error(1)
}

func TestWithMock(t *testing.T) {
    store := new(MockStore)
    store.On("GetUser", mock.Anything, int64(1)).
        Return(&User{ID: 1, Name: "Alice"}, nil)

    svc := NewUserService(store)
    user, err := svc.GetUser(context.Background(), 1)

    require.NoError(t, err)
    assert.Equal(t, "Alice", user.Name)
    store.AssertExpectations(t)
}
```

---

## 5. httptest

### Test HTTP Handlers Directly

```go
import "net/http/httptest"

func TestGetUserHandler(t *testing.T) {
    store := &mockUserStore{
        getUser: func(_ context.Context, id int64) (*User, error) {
            return &User{ID: id, Name: "Alice"}, nil
        },
    }
    h := NewHandler(store)

    req := httptest.NewRequest(http.MethodGet, "/users/1", nil)
    w := httptest.NewRecorder()

    h.ServeHTTP(w, req)

    resp := w.Result()
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        t.Fatalf("status %d, want 200", resp.StatusCode)
    }

    var got User
    if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
        t.Fatalf("decoding response: %v", err)
    }
    if got.Name != "Alice" {
        t.Errorf("name %q, want Alice", got.Name)
    }
}
```

### Test HTTP Clients Against a Real Server

```go
func TestAPIClient(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path != "/v1/users/42" {
            t.Errorf("unexpected path: %s", r.URL.Path)
        }
        w.Header().Set("Content-Type", "application/json")
        fmt.Fprintln(w, `{"id":42,"name":"Bob"}`)
    }))
    defer srv.Close()

    client := NewAPIClient(srv.URL)
    user, err := client.GetUser(context.Background(), 42)

    if err != nil {
        t.Fatalf("GetUser: %v", err)
    }
    if user.Name != "Bob" {
        t.Errorf("name %q, want Bob", user.Name)
    }
}

// TLS variant
func TestAPIClientTLS(t *testing.T) {
    srv := httptest.NewTLSServer(myHandler)
    defer srv.Close()

    client := srv.Client() // pre-configured to trust the test certificate
    resp, err := client.Get(srv.URL + "/health")
    // ...
}
```

---

## 6. Benchmarks

Functions named `BenchmarkXxx` receive `*testing.B`. Run with `go test -bench=. -benchmem`.

```go
func BenchmarkEncode(b *testing.B) {
    user := &User{ID: 1, Name: "Alice", Email: "alice@example.com"}

    b.ReportAllocs()  // show allocations per op
    b.ResetTimer()    // exclude setup time

    for b.Loop() {    // Go 1.24+; use i := 0; i < b.N; i++ for older versions
        if _, err := json.Marshal(user); err != nil {
            b.Fatal(err)
        }
    }
}

// Sub-benchmarks compare implementations
func BenchmarkEncoding(b *testing.B) {
    user := &User{ID: 1, Name: "Alice", Email: "alice@example.com"}

    b.Run("json/stdlib", func(b *testing.B) {
        for b.Loop() {
            json.Marshal(user)
        }
    })

    b.Run("json/sonic", func(b *testing.B) {
        for b.Loop() {
            sonic.Marshal(user)
        }
    })
}

// Parallel benchmark
func BenchmarkEncodeParallel(b *testing.B) {
    user := &User{ID: 1, Name: "Alice"}

    b.RunParallel(func(pb *testing.PB) {
        for pb.Next() {
            json.Marshal(user)
        }
    })
}
```

Run and compare: `go test -bench=BenchmarkEncoding -benchmem -count=5 | tee new.txt && benchstat old.txt new.txt`.

---

## 7. Fuzz Testing

Fuzz tests find inputs that crash your code. Run normally as unit tests; enable fuzzing with `-fuzz`.

```go
func FuzzParseURL(f *testing.F) {
    // Seed the corpus with known-good inputs
    f.Add("https://example.com/path?q=1")
    f.Add("http://localhost:8080")
    f.Add("")
    f.Add("not-a-url")

    f.Fuzz(func(t *testing.T, raw string) {
        // Must not panic
        u, err := ParseURL(raw)
        if err != nil {
            return // errors are acceptable
        }

        // Round-trip property: re-parsing the output must succeed
        reparsed, err := ParseURL(u.String())
        if err != nil {
            t.Errorf("round-trip failed for %q: %v", u.String(), err)
        }
        if reparsed.String() != u.String() {
            t.Errorf("round-trip mismatch: %q != %q", reparsed.String(), u.String())
        }
    })
}
```

Run fuzzing: `go test -fuzz=FuzzParseURL -fuzztime=30s`. Failing inputs are saved to `testdata/fuzz/FuzzParseURL/`. Reproduce: `go test -run=FuzzParseURL/testdata/fuzz/FuzzParseURL/<id>`.

---

## 8. Integration Tests

### Build Tags

Guard integration tests with a build tag so `go test ./...` skips them by default.

```go
//go:build integration

package store_test

import (
    "testing"
    // ...
)

func TestPostgresUserStore(t *testing.T) {
    dsn := os.Getenv("TEST_DSN")
    if dsn == "" {
        t.Skip("TEST_DSN not set")
    }
    // ...
}
```

Run: `go test -tags integration ./...`

### testcontainers-go

Spin up real databases in Docker for integration tests.

```go
//go:build integration

func TestWithPostgres(t *testing.T) {
    ctx := context.Background()

    container, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:16"),
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
        testcontainers.WithWaitStrategy(
            wait.ForLog("database system is ready to accept connections").
                WithOccurrence(2)),
    )
    if err != nil {
        t.Fatalf("starting postgres: %v", err)
    }
    t.Cleanup(func() { container.Terminate(ctx) })

    dsn, err := container.ConnectionString(ctx, "sslmode=disable")
    if err != nil {
        t.Fatal(err)
    }

    db, err := sql.Open("postgres", dsn)
    if err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { db.Close() })

    // Run migrations, then test
    runMigrations(t, db)
    store := NewPostgresStore(db)
    // ... test store methods
}
```

---

## 9. Golden Files

Golden files store expected output. Re-generate them with `-update`.

```go
var update = flag.Bool("update", false, "update golden files")

func TestRenderMarkdown(t *testing.T) {
    input, err := os.ReadFile(filepath.Join("testdata", "input.md"))
    if err != nil {
        t.Fatal(err)
    }

    got := RenderMarkdown(input)

    golden := filepath.Join("testdata", "golden", "output.html")

    if *update {
        err := os.WriteFile(golden, got, 0644)
        if err != nil {
            t.Fatal(err)
        }
        return
    }

    want, err := os.ReadFile(golden)
    if err != nil {
        t.Fatal(err)
    }

    if !bytes.Equal(got, want) {
        t.Errorf("output mismatch (-want +got):\n%s",
            cmp.Diff(string(want), string(got)))
    }
}
```

Run `go test -run=TestRenderMarkdown -update` to regenerate, then commit the golden files.

---

## 10. Test Fixtures and TestMain

### TestMain for Global Setup

```go
func TestMain(m *testing.M) {
    // Setup: runs once before any test
    db, err := setupTestDatabase()
    if err != nil {
        fmt.Fprintf(os.Stderr, "setup: %v\n", err)
        os.Exit(1)
    }
    globalDB = db

    // Run tests
    code := m.Run()

    // Teardown: runs once after all tests
    db.Close()
    os.Exit(code)
}
```

### Per-Test Setup with t.Cleanup

Prefer `t.Cleanup` over `defer` in test helpers; it composes across multiple helpers cleanly.

```go
func prepareUser(t *testing.T, db *sql.DB, email string) *User {
    t.Helper()

    u, err := db.CreateUser(context.Background(), email)
    if err != nil {
        t.Fatalf("creating user: %v", err)
    }

    t.Cleanup(func() {
        if err := db.DeleteUser(context.Background(), u.ID); err != nil {
            t.Logf("cleanup: deleting user %d: %v", u.ID, err)
        }
    })

    return u
}
```

---

## 11. Race Detection

Enable with `go test -race ./...`. The race detector adds ~5-10x overhead; use it in CI.

### Common Race: Shared State in Goroutines

```go
// RACE: multiple goroutines write to results without synchronization
func badCollect(items []Item) []Result {
    results := make([]Result, 0, len(items))
    var wg sync.WaitGroup
    for _, item := range items {
        wg.Add(1)
        go func(it Item) {
            defer wg.Done()
            results = append(results, process(it)) // DATA RACE
        }(item)
    }
    wg.Wait()
    return results
}

// FIXED: preallocate by index
func goodCollect(items []Item) []Result {
    results := make([]Result, len(items))
    var wg sync.WaitGroup
    for i, item := range items {
        wg.Add(1)
        go func(i int, it Item) {
            defer wg.Done()
            results[i] = process(it) // safe: each goroutine owns its index
        }(i, item)
    }
    wg.Wait()
    return results
}
```

### Common Race: Closing Over Loop Variables (pre-Go 1.22)

```go
// RACE in Go < 1.22
for _, url := range urls {
    go func() {
        fetch(url) // captures loop variable by reference
    }()
}

// FIXED
for _, url := range urls {
    url := url // shadow with local copy
    go func() {
        fetch(url)
    }()
}
```

---

## 12. Coverage

```bash
# Generate coverage profile
go test -coverprofile=coverage.out ./...

# View summary by package
go tool cover -func=coverage.out

# Open interactive HTML report
go tool cover -html=coverage.out

# Enforce a minimum threshold in CI
go test -coverprofile=coverage.out ./...
go tool cover -func=coverage.out | awk '/^total:/ {pct=$3+0; if (pct < 80) {print "coverage "$pct"% below 80%"; exit 1}}'
```

Target 80% coverage for business logic. Avoid chasing 100%: generated code, main functions, and deliberate error paths that only trigger under hardware failure are not worth testing directly.
