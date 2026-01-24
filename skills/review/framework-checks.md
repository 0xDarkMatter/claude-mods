# Framework-Specific Review Checks

Reference document for expert reviewers. Contains common issues, anti-patterns, and best practices by framework.

---

## React / Next.js

### Hook Rules

```typescript
// BAD: Conditional hook call
function Component({ show }) {
  if (show) {
    const [value, setValue] = useState(0); // Hooks must be at top level
  }
}

// GOOD: Always call hooks unconditionally
function Component({ show }) {
  const [value, setValue] = useState(0);
  if (!show) return null;
}
```

### useEffect Dependencies

```typescript
// BAD: Missing dependency
useEffect(() => {
  fetchUser(userId);
}, []); // userId missing from deps

// GOOD: Include all dependencies
useEffect(() => {
  fetchUser(userId);
}, [userId]);

// GOOD: Use useCallback for stable references
const fetchUserData = useCallback(() => {
  fetchUser(userId);
}, [userId]);

useEffect(() => {
  fetchUserData();
}, [fetchUserData]);
```

### Key Props in Lists

```tsx
// BAD: Index as key (causes issues with reordering)
{items.map((item, index) => (
  <Item key={index} {...item} />
))}

// GOOD: Stable unique identifier
{items.map((item) => (
  <Item key={item.id} {...item} />
))}
```

### Server/Client Boundaries (Next.js App Router)

```tsx
// BAD: Using hooks in Server Component
// app/page.tsx (Server Component by default)
export default function Page() {
  const [count, setCount] = useState(0); // Error!
}

// GOOD: Mark as Client Component
'use client';
export default function Page() {
  const [count, setCount] = useState(0);
}

// BETTER: Keep Server Component, extract interactive part
// app/page.tsx
import Counter from './Counter';
export default function Page() {
  return <Counter />;
}

// app/Counter.tsx
'use client';
export default function Counter() {
  const [count, setCount] = useState(0);
  return <button onClick={() => setCount(c => c + 1)}>{count}</button>;
}
```

### Prop Drilling vs Context

```tsx
// BAD: Excessive prop drilling
<Parent user={user}>
  <Child user={user}>
    <GrandChild user={user}>
      <DeepChild user={user} />  // 4 levels deep
    </GrandChild>
  </Child>
</Parent>

// GOOD: Use Context for widely-shared state
const UserContext = createContext<User | null>(null);

function Parent({ user }) {
  return (
    <UserContext.Provider value={user}>
      <Child />
    </UserContext.Provider>
  );
}

function DeepChild() {
  const user = useContext(UserContext);
}
```

### Memo Optimization

```tsx
// BAD: Premature optimization
const MemoizedComponent = memo(({ onClick }) => {
  return <button onClick={onClick}>Click</button>;
}); // onClick is new every render anyway

// GOOD: Memoize the callback too
const Parent = () => {
  const handleClick = useCallback(() => {
    console.log('clicked');
  }, []);

  return <MemoizedComponent onClick={handleClick} />;
};
```

---

## TypeScript

### Avoid `any`

```typescript
// BAD: any defeats type safety
function process(data: any) {
  return data.foo.bar; // No type checking
}

// GOOD: Use unknown + type guards
function process(data: unknown) {
  if (isValidData(data)) {
    return data.foo.bar; // Type-safe
  }
  throw new Error('Invalid data');
}

function isValidData(data: unknown): data is { foo: { bar: string } } {
  return typeof data === 'object' && data !== null && 'foo' in data;
}
```

### Non-null Assertions

```typescript
// BAD: Non-null assertion hiding potential bugs
const user = users.find(u => u.id === id)!;
console.log(user.name); // Runtime error if not found

// GOOD: Handle the undefined case
const user = users.find(u => u.id === id);
if (!user) {
  throw new Error(`User ${id} not found`);
}
console.log(user.name);
```

### Generic Constraints

```typescript
// BAD: Overly permissive generic
function getProperty<T, K>(obj: T, key: K) {
  return obj[key]; // Error: Type 'K' cannot be used to index type 'T'
}

// GOOD: Constrain K to keys of T
function getProperty<T, K extends keyof T>(obj: T, key: K): T[K] {
  return obj[key];
}
```

### Type vs Interface

```typescript
// Prefer interface for object shapes (extendable)
interface User {
  id: string;
  name: string;
}

interface Admin extends User {
  permissions: string[];
}

// Use type for unions, intersections, primitives
type Status = 'pending' | 'active' | 'archived';
type UserWithMeta = User & { metadata: Record<string, unknown> };
```

### Discriminated Unions

```typescript
// BAD: Optional fields for variants
interface Result {
  success: boolean;
  data?: string;
  error?: Error;
}

// GOOD: Discriminated union
type Result =
  | { success: true; data: string }
  | { success: false; error: Error };

function handle(result: Result) {
  if (result.success) {
    console.log(result.data); // TypeScript knows data exists
  } else {
    console.error(result.error); // TypeScript knows error exists
  }
}
```

---

## Python

### Mutable Default Arguments

```python
# BAD: Mutable default persists across calls
def append_to(element, target=[]):
    target.append(element)
    return target

append_to(1)  # [1]
append_to(2)  # [1, 2] - Unexpected!

# GOOD: Use None and create inside function
def append_to(element, target=None):
    if target is None:
        target = []
    target.append(element)
    return target
```

### Bare Except Clauses

```python
# BAD: Catches everything including KeyboardInterrupt
try:
    risky_operation()
except:
    pass

# BAD: Too broad
try:
    risky_operation()
except Exception:
    pass

# GOOD: Catch specific exceptions
try:
    risky_operation()
except (ValueError, TypeError) as e:
    logger.error(f"Operation failed: {e}")
    raise
```

### Resource Management

```python
# BAD: Manual resource management
f = open('file.txt')
content = f.read()
f.close()  # May not run if exception occurs

# GOOD: Context manager
with open('file.txt') as f:
    content = f.read()

# GOOD: For database connections
with engine.connect() as conn:
    result = conn.execute(query)
```

### String Formatting for SQL

```python
# BAD: SQL injection vulnerability
query = f"SELECT * FROM users WHERE id = {user_id}"

# GOOD: Parameterized query
query = "SELECT * FROM users WHERE id = %s"
cursor.execute(query, (user_id,))

# GOOD: SQLAlchemy
query = select(User).where(User.id == user_id)
```

### Type Hints

```python
# BAD: No type information
def process(data):
    return data.items()

# GOOD: Full type annotations
from typing import Dict, List, Tuple

def process(data: Dict[str, int]) -> List[Tuple[str, int]]:
    return list(data.items())
```

### Async Patterns

```python
# BAD: Blocking call in async function
async def fetch_data():
    response = requests.get(url)  # Blocks event loop!
    return response.json()

# GOOD: Use async HTTP client
async def fetch_data():
    async with aiohttp.ClientSession() as session:
        async with session.get(url) as response:
            return await response.json()

# BAD: Sequential when could be concurrent
async def fetch_all(urls):
    results = []
    for url in urls:
        results.append(await fetch(url))  # Sequential!
    return results

# GOOD: Concurrent execution
async def fetch_all(urls):
    return await asyncio.gather(*[fetch(url) for url in urls])
```

---

## Go

### Error Handling

```go
// BAD: Ignoring errors
result, _ := someFunction()

// BAD: Just returning error without context
if err != nil {
    return err
}

// GOOD: Wrap errors with context
if err != nil {
    return fmt.Errorf("failed to process user %s: %w", userID, err)
}
```

### Goroutine Leaks

```go
// BAD: Goroutine blocked forever on channel
func process() {
    ch := make(chan int)
    go func() {
        result := expensiveComputation()
        ch <- result  // Blocks if no receiver
    }()
    // Function returns without receiving from ch
}

// GOOD: Use buffered channel or context
func process(ctx context.Context) error {
    ch := make(chan int, 1)  // Buffered
    go func() {
        ch <- expensiveComputation()
    }()

    select {
    case result := <-ch:
        return processResult(result)
    case <-ctx.Done():
        return ctx.Err()
    }
}
```

### Race Conditions

```go
// BAD: Concurrent map access
var cache = make(map[string]int)

func get(key string) int {
    return cache[key]  // Race!
}

func set(key string, value int) {
    cache[key] = value  // Race!
}

// GOOD: Use sync.Map or mutex
var cache sync.Map

func get(key string) (int, bool) {
    val, ok := cache.Load(key)
    if !ok {
        return 0, false
    }
    return val.(int), true
}

func set(key string, value int) {
    cache.Store(key, value)
}
```

### Context Propagation

```go
// BAD: Creating new context, breaking cancellation chain
func handler(ctx context.Context) {
    newCtx := context.Background()  // Loses parent's deadline/cancellation
    doWork(newCtx)
}

// GOOD: Propagate context
func handler(ctx context.Context) {
    doWork(ctx)
}

// GOOD: Add timeout while preserving parent
func handler(ctx context.Context) {
    childCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()
    doWork(childCtx)
}
```

### Defer in Loops

```go
// BAD: Defers accumulate, resources not released until function returns
func processFiles(files []string) error {
    for _, file := range files {
        f, err := os.Open(file)
        if err != nil {
            return err
        }
        defer f.Close()  // All closes happen at function end!
    }
    return nil
}

// GOOD: Use closure to scope defer
func processFiles(files []string) error {
    for _, file := range files {
        if err := processFile(file); err != nil {
            return err
        }
    }
    return nil
}

func processFile(path string) error {
    f, err := os.Open(path)
    if err != nil {
        return err
    }
    defer f.Close()  // Closes when this function returns
    return process(f)
}
```

### Interface Satisfaction

```go
// GOOD: Compile-time interface check
var _ io.Reader = (*MyReader)(nil)

type MyReader struct{}

func (r *MyReader) Read(p []byte) (n int, err error) {
    // Implementation
}
```

---

## Rust

### Ownership and Borrowing

```rust
// BAD: Trying to use moved value
let s1 = String::from("hello");
let s2 = s1;
println!("{}", s1);  // Error: value borrowed after move

// GOOD: Clone if you need both
let s1 = String::from("hello");
let s2 = s1.clone();
println!("{} {}", s1, s2);

// BETTER: Borrow instead of move
let s1 = String::from("hello");
let s2 = &s1;
println!("{} {}", s1, s2);
```

### Unwrap Abuse

```rust
// BAD: Panics on None/Err
let value = some_option.unwrap();
let result = some_result.unwrap();

// GOOD: Handle the error case
let value = some_option.ok_or_else(|| Error::new("value missing"))?;

// GOOD: Provide default
let value = some_option.unwrap_or_default();
let value = some_option.unwrap_or_else(|| compute_default());

// GOOD: Pattern matching
match some_option {
    Some(v) => process(v),
    None => handle_missing(),
}
```

### Lifetime Annotations

```rust
// BAD: Missing lifetime causes confusion
fn longest(x: &str, y: &str) -> &str {
    if x.len() > y.len() { x } else { y }
}

// GOOD: Explicit lifetime
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
    if x.len() > y.len() { x } else { y }
}
```

### Unsafe Blocks

```rust
// BAD: Unnecessary unsafe
unsafe {
    let v = vec![1, 2, 3];  // Safe operation in unsafe block
}

// BAD: Unsafe without documentation
unsafe {
    ptr::copy_nonoverlapping(src, dst, len);
}

// GOOD: Documented safety invariants
// SAFETY: src and dst are valid for len bytes, non-overlapping,
// and properly aligned for T
unsafe {
    ptr::copy_nonoverlapping(src, dst, len);
}
```

### Error Handling

```rust
// BAD: String errors lose type information
fn process() -> Result<(), String> {
    Err("something went wrong".into())
}

// GOOD: Custom error types
#[derive(Debug, thiserror::Error)]
enum ProcessError {
    #[error("failed to read config: {0}")]
    ConfigRead(#[from] std::io::Error),
    #[error("invalid format: {0}")]
    InvalidFormat(String),
}

fn process() -> Result<(), ProcessError> {
    let config = std::fs::read_to_string("config.toml")?;
    // ...
}
```

### Clone vs Copy

```rust
// Know when to derive Copy
#[derive(Clone, Copy)]  // Small, stack-only types
struct Point {
    x: i32,
    y: i32,
}

// Don't derive Copy for heap-allocated types
#[derive(Clone)]  // Clone only, has String
struct User {
    name: String,
    age: u32,
}
```

---

## Vue.js

### Reactivity Gotchas

```vue
<script setup>
// BAD: Destructuring loses reactivity
const { name, email } = props;  // Not reactive!

// GOOD: Use toRefs
const { name, email } = toRefs(props);

// BAD: Replacing reactive object
let state = reactive({ count: 0 });
state = reactive({ count: 1 });  // Loses reactivity!

// GOOD: Mutate properties instead
const state = reactive({ count: 0 });
state.count = 1;
</script>
```

### v-for Key Requirement

```vue
<!-- BAD: Missing key -->
<li v-for="item in items">{{ item.name }}</li>

<!-- BAD: Index as key with mutable list -->
<li v-for="(item, index) in items" :key="index">{{ item.name }}</li>

<!-- GOOD: Unique identifier -->
<li v-for="item in items" :key="item.id">{{ item.name }}</li>
```

### Props Mutation

```vue
<script setup>
// BAD: Mutating props directly
const props = defineProps(['modelValue']);
props.modelValue = 'new value';  // Error!

// GOOD: Emit update event
const emit = defineEmits(['update:modelValue']);
emit('update:modelValue', 'new value');
</script>
```

### Computed vs Methods

```vue
<script setup>
// BAD: Method for derived data
const getFullName = () => `${firstName.value} ${lastName.value}`;

// GOOD: Computed for derived data (cached)
const fullName = computed(() => `${firstName.value} ${lastName.value}`);

// Methods are for actions/side effects
const submit = () => {
  api.save(fullName.value);
};
</script>
```

### Watch Cleanup

```vue
<script setup>
// GOOD: Clean up side effects
watch(searchQuery, async (newQuery, oldQuery, onCleanup) => {
  const controller = new AbortController();
  onCleanup(() => controller.abort());

  const results = await fetch(`/search?q=${newQuery}`, {
    signal: controller.signal
  });
});
</script>
```

---

## SQL / Database

### SQL Injection

```sql
-- BAD: String concatenation
query = "SELECT * FROM users WHERE id = " + userId

-- GOOD: Parameterized queries
query = "SELECT * FROM users WHERE id = $1"
```

### N+1 Query Problem

```python
# BAD: N+1 queries
users = User.query.all()
for user in users:
    print(user.posts)  # Separate query for each user!

# GOOD: Eager loading
users = User.query.options(joinedload(User.posts)).all()
for user in users:
    print(user.posts)  # Already loaded
```

### Missing Indexes

```sql
-- Check for missing indexes on frequently queried columns
-- BAD: Full table scan
SELECT * FROM orders WHERE customer_id = 123;

-- GOOD: Add index
CREATE INDEX idx_orders_customer_id ON orders(customer_id);

-- For compound queries
CREATE INDEX idx_orders_customer_date ON orders(customer_id, created_at);
```

### Transaction Boundaries

```python
# BAD: No transaction for related operations
user = create_user(data)
profile = create_profile(user.id)  # What if this fails?

# GOOD: Wrap in transaction
with db.transaction():
    user = create_user(data)
    profile = create_profile(user.id)
    # Both succeed or both rollback
```

### SELECT *

```sql
-- BAD: Fetching all columns
SELECT * FROM users WHERE id = 1;

-- GOOD: Fetch only needed columns
SELECT id, name, email FROM users WHERE id = 1;
```

### LIKE with Leading Wildcard

```sql
-- BAD: Cannot use index
SELECT * FROM products WHERE name LIKE '%widget%';

-- BETTER: Trailing wildcard can use index
SELECT * FROM products WHERE name LIKE 'widget%';

-- BEST: Full-text search for complex patterns
SELECT * FROM products WHERE to_tsvector('english', name) @@ to_tsquery('widget');
```

---

## Security Checks (Cross-Framework)

### Secrets in Code

```
# CRITICAL: Never commit secrets
BAD:  api_key = "sk-1234567890abcdef"
BAD:  password = "hunter2"
BAD:  AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE

GOOD: Use environment variables
GOOD: Use secret management (AWS Secrets Manager, HashiCorp Vault)
GOOD: Use .env files (gitignored)
```

### Input Validation

```
# Always validate at system boundaries
- User input from forms
- URL parameters
- API request bodies
- File uploads (type, size, content)
- Headers and cookies
```

### Authentication/Authorization

```
# Common issues:
- Missing authentication on endpoints
- Authorization bypass (checking user ID client-side)
- Insecure session handling
- Missing rate limiting
- Weak password requirements
```

### Sensitive Data Exposure

```
# Check for:
- Passwords in logs
- PII in error messages
- Sensitive data in URLs
- Missing encryption at rest
- Missing HTTPS
```

---

## Performance Checks (Cross-Framework)

### Unnecessary Re-renders

```
# React: Check for
- Missing memo/useMemo/useCallback
- Creating objects/arrays in render
- Context value changing every render

# Vue: Check for
- Computed not used for derived state
- Missing v-once for static content
- Large reactive objects when ref would suffice
```

### Memory Leaks

```
# Check for:
- Event listeners not removed
- Timers not cleared
- Subscriptions not unsubscribed
- DOM references held after removal
- Closures capturing large objects
```

### Bundle Size

```
# Check for:
- Importing entire libraries (import _ from 'lodash')
- Missing tree-shaking
- Large dependencies for small features
- Duplicate dependencies
- Missing code splitting
```
