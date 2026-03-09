# Optimization Patterns

Proven performance optimization strategies across the stack.

## Caching Strategies

### Cache Selection Decision Tree

```
What are you caching?
│
├─ Computation result (same input → same output)
│  ├─ In-process only
│  │  └─ In-memory cache (LRU map, memoization)
│  │     Eviction: LRU, LFU, TTL
│  │     Tools: lru-cache (Node), functools.lru_cache (Python), sync.Map (Go)
│  └─ Shared across processes/servers
│     └─ Redis / Memcached
│        TTL-based, key-value, sub-millisecond latency
│
├─ Database query result
│  ├─ Rarely changes, expensive to compute
│  │  └─ Materialized view (database-level cache)
│  │     Refresh: on schedule, on trigger, on demand
│  ├─ Changes with writes
│  │  └─ Cache-aside pattern (read: cache → DB, write: DB → invalidate cache)
│  └─ Read-heavy, tolerate slight staleness
│     └─ Read replica + cache with TTL
│
├─ API response
│  ├─ Same for all users
│  │  └─ CDN cache (Cloudflare, CloudFront)
│  │     Headers: Cache-Control, ETag, Last-Modified
│  ├─ Varies by user but cacheable
│  │  └─ Vary header + CDN or reverse proxy cache
│  └─ Personalized but expensive
│     └─ Server-side cache (Redis) with user-specific keys
│
├─ Static assets (JS, CSS, images)
│  └─ CDN + long cache + content-hashed filenames
│     Cache-Control: public, max-age=31536000, immutable
│     Bust cache by changing filename (app.a1b2c3.js)
│
└─ HTML pages
   ├─ Static content
   │  └─ Pre-render at build time (SSG)
   │     Cache-Control: public, max-age=3600
   ├─ Mostly static, some dynamic
   │  └─ Stale-while-revalidate
   │     Cache-Control: public, max-age=60, stale-while-revalidate=3600
   └─ Fully dynamic
      └─ Short TTL or no-cache + ETag for conditional requests
```

### Cache Invalidation Patterns

```
Pattern: TTL (Time-To-Live)
├─ Simplest approach: cache expires after N seconds
├─ Pro: no coordination needed, self-healing
├─ Con: stale data for up to TTL duration
└─ Best for: session data, config, rate limits

Pattern: Cache-Aside (Lazy Loading)
├─ Read: check cache → miss → query DB → populate cache
├─ Write: update DB → delete cache key (not update)
├─ Pro: only caches what's actually requested
├─ Con: first request after invalidation is slow (cache miss)
└─ Best for: general purpose, most common pattern

Pattern: Write-Through
├─ Write: update cache AND DB in same operation
├─ Pro: cache always consistent with DB
├─ Con: write latency increases, caches unused data
└─ Best for: read-heavy data that must be fresh

Pattern: Write-Behind (Write-Back)
├─ Write: update cache, async flush to DB
├─ Pro: fast writes, batch DB operations
├─ Con: data loss risk if cache crashes before flush
└─ Best for: high-write-throughput, non-critical data (counters, analytics)

Pattern: Event-Driven Invalidation
├─ Publish event on data change, subscribers invalidate caches
├─ Pro: low latency invalidation, decoupled
├─ Con: eventual consistency, event delivery guarantees needed
└─ Best for: microservices, distributed systems
```

### Cache Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| Cache without eviction | Memory grows unbounded | Set max size + LRU/LFU eviction |
| Thundering herd | Cache expires, all requests hit DB simultaneously | Mutex/singleflight, stale-while-revalidate |
| Cache stampede | Hot key expires under high load | Background refresh before expiry |
| Inconsistent cache + DB | Update DB, crash before invalidating cache | Delete cache first (slightly stale reads), or use distributed transactions |
| Caching errors | Error response cached, served to all users | Only cache successful responses, or cache with very short TTL |
| Over-caching | Too many cache layers, hard to debug | Cache at one layer, usually closest to consumer |

## Database Optimization

### Indexing Strategy

```
Index selection decision tree:
│
├─ Query uses WHERE clause
│  ├─ Single column filter
│  │  └─ B-tree index on that column
│  ├─ Multiple column filter (AND)
│  │  └─ Composite index (most selective column first)
│  │     CREATE INDEX idx ON table(col_a, col_b, col_c)
│  │     Left-prefix rule: this index covers (a), (a,b), (a,b,c) queries
│  └─ Text search (LIKE '%term%')
│     └─ Full-text index (not B-tree, which only helps prefix LIKE 'term%')
│
├─ Query uses ORDER BY
│  └─ Index matching ORDER BY columns avoids filesort
│     Combine with WHERE columns: INDEX(where_col, order_col)
│
├─ Query uses JOIN
│  └─ Index on join columns of the inner table
│     ON a.id = b.a_id → index on b.a_id
│
├─ Query uses GROUP BY / DISTINCT
│  └─ Index matching GROUP BY columns
│
└─ High cardinality vs low cardinality
   ├─ High cardinality (many unique values): good index candidate
   └─ Low cardinality (few unique values, e.g., boolean): partial index
      CREATE INDEX idx ON orders(status) WHERE status = 'pending'
```

### Query Optimization Patterns

```sql
-- AVOID: SELECT * (fetches unnecessary columns)
SELECT * FROM users WHERE id = 1;
-- PREFER: select only needed columns
SELECT id, name, email FROM users WHERE id = 1;

-- AVOID: N+1 queries
-- Python/ORM: for user in users: user.orders  (fires query per user)
-- PREFER: eager loading
-- SELECT * FROM users JOIN orders ON users.id = orders.user_id

-- AVOID: OFFSET for pagination on large tables
SELECT * FROM posts ORDER BY created_at DESC LIMIT 20 OFFSET 10000;
-- PREFER: cursor-based pagination
SELECT * FROM posts WHERE created_at < '2025-01-01' ORDER BY created_at DESC LIMIT 20;

-- AVOID: functions on indexed columns in WHERE
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
-- PREFER: expression index or store normalized
CREATE INDEX idx_email_lower ON users(LOWER(email));

-- AVOID: implicit type conversion
SELECT * FROM users WHERE id = '123';  -- string vs integer
-- PREFER: correct types
SELECT * FROM users WHERE id = 123;

-- AVOID: correlated subqueries
SELECT *, (SELECT COUNT(*) FROM orders WHERE orders.user_id = users.id) FROM users;
-- PREFER: JOIN with GROUP BY
SELECT users.*, COUNT(orders.id) FROM users LEFT JOIN orders ON users.id = orders.user_id GROUP BY users.id;
```

### Connection Pooling

```
Connection pool sizing:
│
├─ Too small
│  └─ Requests queue waiting for connections
│     Symptom: latency spikes, "connection pool exhausted" errors
│
├─ Too large
│  └─ Database overwhelmed with connections
│     Symptom: high memory usage on DB, mutex contention, slower queries
│
└─ Right size
   └─ Formula: connections = (core_count * 2) + effective_spindle_count
      For SSD: connections ≈ core_count * 2-3
      For cloud DB (e.g., RDS): check instance limits

Tools:
- PostgreSQL: PgBouncer (transaction pooling, session pooling)
- MySQL: ProxySQL
- Java: HikariCP (fastest JVM pool)
- Python: SQLAlchemy pool (pool_size, max_overflow, pool_timeout)
- Node.js: built-in pool in pg, mysql2, knex
- Go: database/sql built-in pool (SetMaxOpenConns, SetMaxIdleConns)
```

## Frontend Optimization

### Code Splitting

```
When to split:
│
├─ Route-based splitting (most impactful)
│  └─ Each page/route is a separate chunk
│     React: React.lazy(() => import('./Page'))
│     Next.js: automatic per-page
│     Vue: defineAsyncComponent(() => import('./Page.vue'))
│
├─ Component-based splitting
│  └─ Heavy components loaded on demand
│     Modal dialogs, rich text editors, charts, maps
│     <Suspense fallback={<Spinner />}><LazyComponent /></Suspense>
│
├─ Library-based splitting
│  └─ Large libraries in separate chunks
│     Moment.js, chart libraries, syntax highlighters
│     // vite.config.js
│     build: { rollupOptions: { output: {
│       manualChunks: { vendor: ['react', 'react-dom'] }
│     }}}
│
└─ Conditional feature splitting
   └─ Features only some users need (admin panel, A/B tests)
      const AdminPanel = lazy(() => import('./AdminPanel'))
```

### Image Optimization

```
Format selection:
│
├─ Photographs
│  ├─ Best: AVIF (30-50% smaller than JPEG)
│  ├─ Good: WebP (25-35% smaller than JPEG)
│  └─ Fallback: JPEG (universal support)
│
├─ Graphics/logos with transparency
│  ├─ Best: WebP or AVIF
│  ├─ Good: PNG (lossless)
│  └─ Simple graphics: SVG (scalable, tiny file size)
│
└─ Icons
   └─ SVG sprites or icon fonts (not individual PNGs)

Implementation:
<picture>
  <source srcset="image.avif" type="image/avif">
  <source srcset="image.webp" type="image/webp">
  <img src="image.jpg" alt="Description"
       loading="lazy"
       decoding="async"
       width="800" height="600">
</picture>

Responsive images:
<img srcset="small.jpg 400w, medium.jpg 800w, large.jpg 1200w"
     sizes="(max-width: 600px) 400px, (max-width: 900px) 800px, 1200px"
     src="medium.jpg" alt="Description">
```

### Critical Rendering Path

```
Optimization checklist:
│
├─ Critical CSS
│  ├─ Inline above-the-fold CSS in <head>
│  ├─ Defer non-critical CSS: <link rel="preload" as="style">
│  └─ Tools: critical (npm package), Critters (webpack plugin)
│
├─ JavaScript loading
│  ├─ <script defer>: download parallel, execute after HTML parse
│  ├─ <script async>: download parallel, execute immediately (non-order)
│  ├─ <script type="module">: deferred by default, strict mode
│  └─ Move non-critical JS below the fold
│
├─ Resource hints
│  ├─ <link rel="preconnect" href="https://api.example.com">
│  │  Establish early connections to known origins
│  ├─ <link rel="dns-prefetch" href="https://cdn.example.com">
│  │  Resolve DNS early for third-party domains
│  ├─ <link rel="preload" href="font.woff2" as="font" crossorigin>
│  │  Preload critical resources (fonts, hero image, key CSS)
│  └─ <link rel="prefetch" href="next-page.js">
│     Prefetch resources for likely next navigation
│
├─ Font optimization
│  ├─ font-display: swap (show fallback immediately)
│  ├─ Subset fonts to used characters
│  ├─ Preload critical fonts
│  ├─ Use woff2 format (best compression)
│  └─ Self-host instead of Google Fonts (one fewer connection)
│
└─ Layout stability (CLS)
   ├─ Always set width/height on images and videos
   ├─ Reserve space for ads and embeds
   ├─ Use CSS aspect-ratio for responsive containers
   └─ Avoid inserting content above existing content
```

## API Optimization

### Response Optimization

```
Reducing payload size:
│
├─ Field selection (GraphQL-style)
│  └─ GET /users/123?fields=id,name,email
│     Only return requested fields
│
├─ Pagination
│  ├─ Offset-based: ?page=3&limit=20
│  │  Simple but slow for deep pages (OFFSET 10000)
│  ├─ Cursor-based: ?after=cursor_abc&limit=20
│  │  Fast at any depth, stable during inserts
│  └─ Keyset: ?created_after=2025-01-01&limit=20
│     Uses indexed column for efficient seeking
│
├─ Compression
│  ├─ Brotli (br): best ratio for static content
│  ├─ gzip: universal support, good for dynamic content
│  ├─ Accept-Encoding: br, gzip
│  └─ Skip compression for small payloads (<150 bytes)
│
├─ Batch endpoints
│  └─ POST /batch with array of operations
│     Reduces HTTP overhead, enables server-side optimization
│
└─ Caching headers
   ├─ ETag + If-None-Match: 304 Not Modified (no body transfer)
   ├─ Last-Modified + If-Modified-Since: same as ETag
   └─ Cache-Control: max-age=60, stale-while-revalidate=600
```

### HTTP/2 and HTTP/3

```
HTTP/2 optimizations (changes from HTTP/1.1):
│
├─ Multiplexing: multiple requests on single connection
│  └─ STOP: domain sharding (hurts with HTTP/2)
│  └─ STOP: sprite sheets (individual files are fine)
│  └─ STOP: concatenating CSS/JS into mega-bundles
│
├─ Server Push: server sends resources before client requests
│  └─ Mostly deprecated: use <link rel="preload"> instead
│
├─ Header compression (HPACK)
│  └─ Automatic, no action needed
│
└─ Stream prioritization
   └─ Browsers handle automatically, server must support

HTTP/3 (QUIC):
├─ Faster connection setup (0-RTT)
├─ No head-of-line blocking
├─ Better on lossy networks (mobile)
└─ Enable on CDN/reverse proxy (Cloudflare, nginx with quic module)
```

## Concurrency Optimization

### Worker Pool Patterns

```
When to use worker pools:
│
├─ CPU-bound tasks
│  ├─ Pool size = number of CPU cores
│  ├─ Node.js: worker_threads
│  ├─ Python: multiprocessing.Pool, ProcessPoolExecutor
│  ├─ Go: bounded goroutine pool (semaphore pattern)
│  └─ Rust: rayon::ThreadPool, tokio::task::spawn_blocking
│
├─ I/O-bound tasks
│  ├─ Pool size = much larger than CPU cores (100s-1000s)
│  ├─ Node.js: async/await (event loop handles concurrency)
│  ├─ Python: asyncio, ThreadPoolExecutor for blocking I/O
│  ├─ Go: goroutines (lightweight, thousands are fine)
│  └─ Rust: tokio tasks (lightweight, thousands are fine)
│
└─ Mixed workloads
   └─ Separate pools for CPU and I/O work
      Don't let CPU-bound tasks block I/O pool
      Don't let I/O waits occupy CPU pool slots
```

### Backpressure

```
Without backpressure:
Producer (fast) → → → → → QUEUE OVERFLOW → OOM/Crash
                          ↓ ↓ ↓ ↓ ↓ ↓ ↓
Consumer (slow) → → →

With backpressure:
Producer (fast) → → BLOCKED (queue full)
                          ↓ ↓ ↓
Consumer (slow) → → → (processes at own pace)

Implementation strategies:
├─ Bounded queues: reject/block when full
├─ Rate limiting: token bucket, leaky bucket
├─ Circuit breaker: stop sending when consumer is unhealthy
├─ Load shedding: drop low-priority work under pressure
└─ Reactive streams: consumer signals demand to producer
```

### Batching

```
Individual operations:
Request 1 → DB Query → Response
Request 2 → DB Query → Response    Total: 100 DB queries
Request 3 → DB Query → Response
... (100 times)

Batched operations:
Request 1 ─┐
Request 2 ──┤ Batch → 1 DB Query → Responses    Total: 1 DB query
Request 3 ──┤
... (100)  ─┘

Implementation:
├─ DataLoader pattern (GraphQL/general)
│  Collect individual loads within one event loop tick
│  Execute as single batch query
│  Return individual results
│
├─ Bulk INSERT
│  Collect rows, INSERT multiple in one statement
│  INSERT INTO items (a, b) VALUES (1,2), (3,4), (5,6)
│
├─ Batch API calls
│  Collect individual API calls
│  Send as single batch request
│  POST /batch [{method, path, body}, ...]
│
└─ Write coalescing
   Buffer writes for short window (10-100ms)
   Flush as single operation
   Trade latency for throughput
```

## Memory Optimization

### Object Pooling

```
When to pool:
├─ Objects are expensive to create (DB connections, threads, buffers)
├─ Objects are created and destroyed frequently
├─ GC pressure is high (many short-lived allocations)
└─ Object initialization involves I/O or complex setup

Implementation pattern:
Pool {
  available: []     // Ready to use
  in_use: []        // Currently checked out
  max_size: N       // Maximum pool size

  acquire():
    if available.length > 0:
      return available.pop()
    elif in_use.length < max_size:
      return create_new()
    else:
      wait_or_reject()

  release(obj):
    reset(obj)       // Clean state for reuse
    available.push(obj)
}

Language-specific:
- Go: sync.Pool (GC-aware, may evict items)
- Rust: object-pool crate, crossbeam ObjectPool
- Java: Apache Commons Pool, HikariCP (connection pool)
- Python: queue.Queue-based custom pool
- Node.js: generic-pool package
```

### Streaming vs Buffering

```
Buffering (load all into memory):
├─ Simple code
├─ Random access to data
├─ DANGER: memory scales with data size
└─ Max data size limited by available RAM

Streaming (process chunk by chunk):
├─ Constant memory regardless of data size
├─ Can start processing before all data arrives
├─ Required for: large files, real-time data, video/audio
└─ Slightly more complex code

Decision:
├─ Data < 10MB → buffering is fine
├─ Data > 100MB → streaming required
├─ Data size unknown → streaming required
├─ Real-time processing → streaming required
└─ Need multiple passes → buffer or use temp file

Examples:
- Node.js: fs.createReadStream() vs fs.readFileSync()
- Python: open().read() vs for line in open()
- Go: io.Reader/io.Writer interfaces
- Rust: BufReader/BufWriter, tokio AsyncRead/AsyncWrite
```

### String Interning

```
Problem: many duplicate strings consuming memory

Before interning:
  "status: active"  →  String { ptr: 0x1000, len: 14 }
  "status: active"  →  String { ptr: 0x2000, len: 14 }  // Duplicate!
  "status: active"  →  String { ptr: 0x3000, len: 14 }  // Another!

After interning:
  "status: active"  →  all point to same allocation

When to use:
├─ Many repeated string values (status fields, tags, categories)
├─ Long-lived strings that are compared often
└─ Parsing structured data with repetitive fields

Language support:
- Python: sys.intern() (automatic for small strings)
- Java: String.intern() (JVM string pool)
- Go: no built-in, use map[string]string dedup
- Rust: string-interner crate
- JavaScript: V8 interns short strings automatically
```

## Algorithm Optimization

### Big-O Awareness

```
Common operations and their complexity:

O(1)        Array index, hash map lookup, stack push/pop
O(log n)    Binary search, balanced BST lookup, heap insert
O(n)        Linear scan, array copy, linked list traversal
O(n log n)  Efficient sort (merge, quick, heap sort)
O(n²)       Nested loops, bubble sort, insertion sort
O(2ⁿ)       Recursive Fibonacci (naive), power set

Practical impact (n = 1,000,000):
O(1)       = 1 operation
O(log n)   = 20 operations
O(n)       = 1,000,000 operations
O(n log n) = 20,000,000 operations
O(n²)      = 1,000,000,000,000 operations  ← TOO SLOW

Quick wins:
├─ Replace list search with set/hash map: O(n) → O(1)
├─ Sort + binary search instead of linear search: O(n) → O(log n)
├─ Replace nested loops with hash join: O(n²) → O(n)
├─ Cache computed values (memoization): avoid redundant work
└─ Use appropriate data structure for access pattern
```

### Data Structure Selection

```
Access pattern → best data structure:
│
├─ Fast lookup by key
│  └─ Hash map / dictionary
│     O(1) average lookup, insert, delete
│
├─ Ordered iteration + fast lookup
│  └─ Balanced BST (TreeMap, BTreeMap)
│     O(log n) lookup, insert, delete, ordered iteration
│
├─ Fast insert/remove at both ends
│  └─ Deque (double-ended queue)
│     O(1) push/pop at front and back
│
├─ Priority-based access (always get min/max)
│  └─ Heap / priority queue
│     O(1) peek min/max, O(log n) insert and extract
│
├─ Fast membership testing
│  └─ Hash set
│     O(1) contains check
│  └─ Bloom filter (probabilistic, space-efficient)
│     O(1) contains, may have false positives
│
├─ Fast prefix search / autocomplete
│  └─ Trie
│     O(k) lookup where k = key length
│
├─ Range queries (find all items between A and B)
│  └─ Sorted array + binary search, or B-tree
│
└─ Graph relationships
   ├─ Sparse graph → adjacency list
   └─ Dense graph → adjacency matrix
```

## Anti-Patterns

### Premature Optimization

```
"Premature optimization is the root of all evil" — Knuth

Signs of premature optimization:
├─ Optimizing before measuring
├─ Optimizing code that runs once or rarely
├─ Sacrificing readability for negligible performance gain
├─ Optimizing at the wrong level (micro vs macro)
└─ Optimizing before the feature is correct

The right approach:
1. Make it work (correct behavior)
2. Make it right (clean, maintainable code)
3. Make it fast (profile, then optimize measured bottlenecks)

Exception: architectural decisions (data model, API design) are
expensive to change later. Think about performance at design time
for structural choices.
```

### Common Performance Anti-Patterns

| Anti-Pattern | Why It's Bad | Better Approach |
|-------------|-------------|-----------------|
| N+1 queries | 1000 items = 1001 DB queries | Eager loading, batch queries, DataLoader |
| Unbounded growth | Cache/queue/buffer grows without limit | Set max size, eviction policy, backpressure |
| Synchronous I/O in async code | Blocks event loop/thread pool, kills throughput | Use async I/O throughout, offload blocking to thread pool |
| Re-rendering everything | UI updates trigger full tree re-render | Virtual DOM diffing, memoization, fine-grained reactivity |
| Serializing/deserializing repeatedly | Data converted between formats multiple times | Pass native objects, serialize once at boundary |
| Polling when events are available | CPU waste checking for changes | WebSockets, SSE, file watch, pub/sub |
| Logging in hot path | String formatting + I/O in tight loop | Sampling, async logging, log level guards |
| Global locks | All threads contend on single mutex | Fine-grained locks, lock-free structures, sharding |
| String concatenation in loop | O(n²) due to repeated copying | StringBuilder, join, format strings |
| Creating regex in loop | Compile regex on every iteration | Compile once, reuse compiled pattern |
| Deep cloning when shallow suffices | Copying entire object graph unnecessarily | Structural sharing, immutable data structures, shallow copy |
| Catching exceptions for flow control | Exceptions are expensive (stack trace capture) | Use return values, option types, result types |
