# Go Interfaces and Generics Reference

## Table of Contents

1. [Interface Design Principles](#1-interface-design-principles)
2. [Interface Composition](#2-interface-composition)
3. [Type Assertions](#3-type-assertions)
4. [Empty Interface and any](#4-empty-interface-and-any)
5. [Generics Basics](#5-generics-basics)
6. [Generic Functions](#6-generic-functions)
7. [Generic Types](#7-generic-types)
8. [Constraints](#8-constraints)
9. [When NOT to Use Generics](#9-when-not-to-use-generics)
10. [Functional Options](#10-functional-options)
11. [Builder Pattern](#11-builder-pattern)
12. [Strategy via Interfaces](#12-strategy-via-interfaces)

---

## 1. Interface Design Principles

**Accept interfaces, return concrete types.** Callers decide what abstraction they need; implementations should not hide their type behind an interface at the return site.

```go
// BAD: returns interface, hides the concrete type unnecessarily
func NewStore() Store {
    return &postgresStore{}
}

// GOOD: returns concrete pointer; callers that need the interface accept it
func NewStore() *PostgresStore {
    return &postgresStore{}
}
```

**Keep interfaces small.** One or two methods is the ideal. Large interfaces are hard to mock and hard to satisfy.

```go
// BAD: one interface does too much
type UserService interface {
    GetUser(id int64) (*User, error)
    CreateUser(u *User) error
    DeleteUser(id int64) error
    SendWelcomeEmail(u *User) error
    AuditLog(action string) error
}

// GOOD: split by role
type UserReader interface {
    GetUser(id int64) (*User, error)
}

type UserWriter interface {
    CreateUser(u *User) error
    DeleteUser(id int64) error
}

type Notifier interface {
    SendWelcomeEmail(u *User) error
}
```

**Define interfaces at the point of use (consumer), not the provider.** This avoids import cycles and keeps packages decoupled.

Standard library examples of well-sized interfaces:

```go
// io package: one method each
type Reader interface { Read(p []byte) (n int, err error) }
type Writer interface { Write(p []byte) (n int, err error) }
type Closer interface { Close() error }

// fmt package: one method
type Stringer interface { String() string }

// sort package: three methods (minimum needed for the algorithm)
type Interface interface {
    Len() int
    Less(i, j int) bool
    Swap(i, j int)
}
```

---

## 2. Interface Composition

Embed smaller interfaces to build larger ones. Only embed what callers genuinely need together.

```go
// Compose from stdlib primitives
type ReadWriter interface {
    io.Reader
    io.Writer
}

type ReadWriteCloser interface {
    io.Reader
    io.Writer
    io.Closer
}

// Compose from your own interfaces
type Repository interface {
    UserReader
    UserWriter
}

// Satisfy a composed interface with one struct
type postgresStore struct{ db *sql.DB }

func (s *postgresStore) GetUser(id int64) (*User, error)    { /* ... */ }
func (s *postgresStore) CreateUser(u *User) error           { /* ... */ }
func (s *postgresStore) DeleteUser(id int64) error          { /* ... */ }

var _ Repository = (*postgresStore)(nil) // compile-time check
```

The blank identifier assignment `var _ Repository = (*postgresStore)(nil)` is a zero-cost compile-time assertion that `*postgresStore` satisfies `Repository`.

---

## 3. Type Assertions

### Single-Value Form (Panics on Failure)

Use only when you are certain of the type, such as immediately after a type switch.

```go
var v interface{} = "hello"
s := v.(string) // panics if v is not a string
```

### Comma-OK Form (Safe)

```go
var v interface{} = "hello"

s, ok := v.(string)
if !ok {
    // handle wrong type
}
```

### Type Switch

The idiomatic way to branch on dynamic type. The variable `x` is narrowed to the concrete type in each case.

```go
func describe(v interface{}) string {
    switch x := v.(type) {
    case string:
        return fmt.Sprintf("string of length %d", len(x))
    case int:
        return fmt.Sprintf("int: %d", x)
    case []byte:
        return fmt.Sprintf("bytes: %x", x)
    case fmt.Stringer:
        return fmt.Sprintf("stringer: %s", x.String())
    case nil:
        return "nil"
    default:
        return fmt.Sprintf("unknown type: %T", x)
    }
}
```

---

## 4. Empty Interface and any

`any` is an alias for `interface{}` introduced in Go 1.18. Prefer `any` in new code.

Use `any` only when the type is genuinely unknown at compile time: codec targets, generic containers before generics were available, or variadic logging arguments.

```go
// Legitimate: JSON decode target unknown at call site
func Decode(r io.Reader, dst any) error {
    return json.NewDecoder(r).Decode(dst)
}

// Legitimate: structured logging with arbitrary fields
func Info(msg string, fields ...any) { /* ... */ }

// Avoid: using any when a concrete type or interface would work
func Process(v any) {         // BAD if callers always pass *User
    u := v.(*User)            // forced assertion everywhere
}

func Process(u *User) { /* ... */ } // GOOD
```

Do not use `any` as a way to avoid thinking about types. Every `any` is a deferred type error waiting for runtime.

---

## 5. Generics Basics

Go generics use type parameters in square brackets. Introduced in Go 1.18.

```go
// Type parameter T with constraint comparable
func Contains[T comparable](slice []T, item T) bool {
    for _, v := range slice {
        if v == item {
            return true
        }
    }
    return false
}

// Usage - type inferred from arguments
found := Contains([]string{"a", "b", "c"}, "b") // true
found = Contains([]int{1, 2, 3}, 4)              // false

// Multiple type parameters
func Map[K comparable, V any](m map[K]V, f func(V) V) map[K]V {
    out := make(map[K]V, len(m))
    for k, v := range m {
        out[k] = f(v)
    }
    return out
}
```

Type inference works in most cases. Provide explicit type arguments only when the compiler cannot infer them.

```go
// Explicit type argument needed when return type differs from arguments
func Zero[T any]() T {
    var zero T
    return zero
}

z := Zero[int]()    // must be explicit: no argument to infer from
```

---

## 6. Generic Functions

### Filter, Map, Reduce

```go
func Filter[T any](slice []T, predicate func(T) bool) []T {
    var result []T
    for _, v := range slice {
        if predicate(v) {
            result = append(result, v)
        }
    }
    return result
}

func Map[T, U any](slice []T, f func(T) U) []U {
    result := make([]U, len(slice))
    for i, v := range slice {
        result[i] = f(v)
    }
    return result
}

func Reduce[T, U any](slice []T, initial U, f func(U, T) U) U {
    acc := initial
    for _, v := range slice {
        acc = f(acc, v)
    }
    return acc
}

// Keys returns the keys of a map in unspecified order
func Keys[K comparable, V any](m map[K]V) []K {
    keys := make([]K, 0, len(m))
    for k := range m {
        keys = append(keys, k)
    }
    return keys
}

// Values returns the values of a map in unspecified order
func Values[K comparable, V any](m map[K]V) []V {
    values := make([]V, 0, len(m))
    for _, v := range m {
        values = append(values, v)
    }
    return values
}
```

---

## 7. Generic Types

### Stack

```go
type Stack[T any] struct {
    items []T
}

func (s *Stack[T]) Push(item T) {
    s.items = append(s.items, item)
}

func (s *Stack[T]) Pop() (T, bool) {
    if len(s.items) == 0 {
        var zero T
        return zero, false
    }
    n := len(s.items) - 1
    item := s.items[n]
    s.items = s.items[:n]
    return item, true
}

func (s *Stack[T]) Len() int { return len(s.items) }
```

### Result Type

Encode success or failure without error returns scattered through call sites.

```go
type Result[T any] struct {
    value T
    err   error
}

func Ok[T any](value T) Result[T]    { return Result[T]{value: value} }
func Err[T any](err error) Result[T] { return Result[T]{err: err} }

func (r Result[T]) Unwrap() (T, error) { return r.value, r.err }

func (r Result[T]) Must() T {
    if r.err != nil {
        panic(r.err)
    }
    return r.value
}
```

### Generic Cache with TTL

```go
type entry[V any] struct {
    value     V
    expiresAt time.Time
}

type Cache[K comparable, V any] struct {
    mu   sync.RWMutex
    data map[K]entry[V]
    ttl  time.Duration
}

func NewCache[K comparable, V any](ttl time.Duration) *Cache[K, V] {
    return &Cache[K, V]{data: make(map[K]entry[V]), ttl: ttl}
}

func (c *Cache[K, V]) Set(key K, value V) {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.data[key] = entry[V]{value: value, expiresAt: time.Now().Add(c.ttl)}
}

func (c *Cache[K, V]) Get(key K) (V, bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    e, ok := c.data[key]
    if !ok || time.Now().After(e.expiresAt) {
        var zero V
        return zero, false
    }
    return e.value, true
}
```

---

## 8. Constraints

### Built-In Constraints

```go
// comparable: supports == and != (maps, channels, basic types, structs of comparable fields)
func Index[T comparable](slice []T, item T) int {
    for i, v := range slice {
        if v == item {
            return i
        }
    }
    return -1
}

// any: no constraint, widest possible
func Ptr[T any](v T) *T { return &v }
```

### golang.org/x/exp/constraints

```go
import "golang.org/x/exp/constraints"

// Ordered: all types that support <, <=, >, >=
func Min[T constraints.Ordered](a, b T) T {
    if a < b {
        return a
    }
    return b
}

func Max[T constraints.Ordered](a, b T) T {
    if a > b {
        return a
    }
    return b
}

func Clamp[T constraints.Ordered](v, lo, hi T) T {
    return Min(Max(v, lo), hi)
}
```

### Custom Constraints

```go
// Union of specific types
type Integer interface {
    ~int | ~int8 | ~int16 | ~int32 | ~int64
}

type Float interface {
    ~float32 | ~float64
}

type Number interface {
    Integer | Float
}

func Sum[T Number](nums []T) T {
    var total T
    for _, n := range nums {
        total += n
    }
    return total
}
```

### Tilde (~) for Underlying Types

`~T` includes all types whose underlying type is `T`. Without `~`, named types are excluded.

```go
type Celsius float64
type Fahrenheit float64

// Without ~: Celsius and Fahrenheit do not satisfy Float
type Float interface { float32 | float64 }

// With ~: Celsius and Fahrenheit satisfy ~float64
type Float interface { ~float32 | ~float64 }

func Convert[T ~float64](v T) T { return v * 9 / 5 + 32 }

c := Celsius(100)
f := Convert(c) // works because ~float64 includes Celsius
```

---

## 9. When NOT to Use Generics

**Use an interface when behavior varies by type.** Generics parametrize over structure, not behavior. If the algorithm calls different methods depending on the type, use an interface.

```go
// BAD: generics cannot help here - behavior is type-specific
func Process[T any](v T) {
    // Cannot call v.Serialize() without a constraint defining it
}

// GOOD: interface captures the varying behavior
type Processor interface {
    Process() error
}
func Run(p Processor) error { return p.Process() }
```

**Use a concrete type when you only have one type.** Adding a type parameter for a function that only ever handles `string` or `int` adds noise with no benefit.

```go
// Unnecessary generics
func ParseInt[T ~string](s T) (int64, error) {
    return strconv.ParseInt(string(s), 10, 64)
}

// Simpler and clearer
func ParseInt(s string) (int64, error) {
    return strconv.ParseInt(s, 10, 64)
}
```

**Prefer `any` + type switch for heterogeneous collections** where types are enumerable and fixed. Generics do not simplify this case.

---

## 10. Functional Options

The functional options pattern gives constructors optional, named parameters with default values and forward compatibility.

```go
type Server struct {
    host    string
    port    int
    timeout time.Duration
    maxConn int
    logger  *slog.Logger
}

type Option func(*Server) error

func WithHost(host string) Option {
    return func(s *Server) error {
        if host == "" {
            return errors.New("host cannot be empty")
        }
        s.host = host
        return nil
    }
}

func WithPort(port int) Option {
    return func(s *Server) error {
        if port < 1 || port > 65535 {
            return fmt.Errorf("invalid port: %d", port)
        }
        s.port = port
        return nil
    }
}

func WithTimeout(d time.Duration) Option {
    return func(s *Server) error {
        if d <= 0 {
            return errors.New("timeout must be positive")
        }
        s.timeout = d
        return nil
    }
}

func WithLogger(l *slog.Logger) Option {
    return func(s *Server) error {
        s.logger = l
        return nil
    }
}

func NewServer(opts ...Option) (*Server, error) {
    s := &Server{ // defaults
        host:    "localhost",
        port:    8080,
        timeout: 30 * time.Second,
        maxConn: 100,
        logger:  slog.Default(),
    }
    for _, opt := range opts {
        if err := opt(s); err != nil {
            return nil, fmt.Errorf("applying option: %w", err)
        }
    }
    return s, nil
}

// Usage
srv, err := NewServer(
    WithHost("0.0.0.0"),
    WithPort(9090),
    WithTimeout(time.Minute),
)
```

---

## 11. Builder Pattern

Use when construction requires many steps and partial construction is meaningful.

```go
type QueryBuilder struct {
    table   string
    columns []string
    where   []string
    orderBy string
    limit   int
    args    []any
    err     error // carry errors through the chain
}

func NewQuery(table string) *QueryBuilder {
    if table == "" {
        return &QueryBuilder{err: errors.New("table name required")}
    }
    return &QueryBuilder{table: table, columns: []string{"*"}}
}

func (q *QueryBuilder) Select(cols ...string) *QueryBuilder {
    if q.err != nil {
        return q
    }
    q.columns = cols
    return q
}

func (q *QueryBuilder) Where(condition string, args ...any) *QueryBuilder {
    if q.err != nil {
        return q
    }
    q.where = append(q.where, condition)
    q.args = append(q.args, args...)
    return q
}

func (q *QueryBuilder) OrderBy(col string) *QueryBuilder {
    if q.err != nil {
        return q
    }
    q.orderBy = col
    return q
}

func (q *QueryBuilder) Limit(n int) *QueryBuilder {
    if q.err != nil {
        return q
    }
    if n < 0 {
        q.err = fmt.Errorf("limit must be non-negative, got %d", n)
        return q
    }
    q.limit = n
    return q
}

func (q *QueryBuilder) Build() (string, []any, error) {
    if q.err != nil {
        return "", nil, q.err
    }
    // assemble SQL from q.table, q.columns, q.where, q.orderBy, q.limit
    sql := fmt.Sprintf("SELECT %s FROM %s", strings.Join(q.columns, ", "), q.table)
    if len(q.where) > 0 {
        sql += " WHERE " + strings.Join(q.where, " AND ")
    }
    if q.orderBy != "" {
        sql += " ORDER BY " + q.orderBy
    }
    if q.limit > 0 {
        sql += fmt.Sprintf(" LIMIT %d", q.limit)
    }
    return sql, q.args, nil
}

// Usage
sql, args, err := NewQuery("users").
    Select("id", "name", "email").
    Where("active = $1", true).
    Where("role = $2", "admin").
    OrderBy("name").
    Limit(25).
    Build()
```

---

## 12. Strategy via Interfaces

Swap algorithms at runtime by accepting an interface. The caller chooses the strategy; the function does not need to know the implementation.

```go
// Define the strategy interface
type Hasher interface {
    Hash(data []byte) []byte
    Name() string
}

// Multiple implementations
type SHA256Hasher struct{}

func (SHA256Hasher) Hash(data []byte) []byte {
    h := sha256.Sum256(data)
    return h[:]
}
func (SHA256Hasher) Name() string { return "sha256" }

type Blake2Hasher struct{}

func (Blake2Hasher) Hash(data []byte) []byte {
    h := blake2b.Sum256(data)
    return h[:]
}
func (Blake2Hasher) Name() string { return "blake2b" }

// Consumer accepts the interface - does not care about the algorithm
type FileStore struct {
    hasher Hasher
}

func NewFileStore(h Hasher) *FileStore {
    return &FileStore{hasher: h}
}

func (fs *FileStore) Store(path string, data []byte) error {
    checksum := fs.hasher.Hash(data)
    // write data and checksum to path
    return writeWithChecksum(path, data, checksum, fs.hasher.Name())
}

// Swap strategies at call site
fastStore := NewFileStore(Blake2Hasher{})
secureStore := NewFileStore(SHA256Hasher{})
```

This pattern is the Go equivalent of the Gang of Four Strategy pattern. It composes without inheritance and is trivially testable: inject a `mockHasher` that returns fixed bytes.
