# Performance Diagnosis Quick Reference

Symptom classification, tool selection, and common patterns for rapid performance triage.

## Performance Issue Decision Tree

```
What symptom are you observing?
|
+- High CPU usage
|  +- Sustained 100% on one core
|  |  +- CPU-bound: hot loop, regex backtracking, tight computation
|  |     -> Profile with flamegraph (py-spy, pprof, clinic flame, samply)
|  +- Sustained 100% across all cores
|  |  +- Parallelism gone wrong: fork bomb, unbounded workers, spin locks
|  |     -> Check process count, thread count, lock contention
|  +- Periodic spikes
|     +- GC pressure, cron job, batch processing, cache stampede
|        -> Correlate with GC logs, scheduled tasks, traffic patterns
|
+- High memory usage
|  +- Growing over time (never decreasing)
|  |  +- Memory leak: unclosed resources, growing caches, event listener accumulation
|  |     -> Heap snapshots over time, compare retained objects
|  +- Sudden large allocation
|  |  +- Unbounded buffer, loading full dataset into memory, large file read
|  |     -> Check allocation sizes, switch to streaming
|  +- High but stable
|     +- May be normal: in-memory cache, preloaded data, memory-mapped files
|        -> Verify with expected working set size
|
+- Slow responses / high latency
|  +- All endpoints slow
|  |  +- Systemic: resource exhaustion, GC pauses, DNS issues, TLS overhead
|  |     -> Check resource utilization, GC metrics, network path
|  +- Specific endpoint slow
|  |  +- Query-specific: N+1 queries, missing index, unoptimized algorithm
|  |     -> EXPLAIN ANALYZE, query logging, endpoint profiling
|  +- Intermittently slow (p99 spikes)
|     +- Contention: lock wait, connection pool exhaustion, noisy neighbor
|        -> Check lock metrics, pool sizes, correlated traffic
|
+- Low throughput
|  +- CPU not saturated
|  |  +- I/O bound: disk wait, network latency, blocking calls in async code
|  |     -> Check iowait, network RTT, ensure async throughout
|  +- CPU saturated
|  |  +- Compute bound: need algorithmic improvement or horizontal scaling
|  |     -> Profile hot paths, optimize or scale out
|  +- Queues backing up
|     +- Consumer too slow: batch size, consumer count, downstream bottleneck
|        -> Increase consumers, optimize processing, check downstream
|
+- Large bundle size (frontend)
|  +- Main bundle too large
|  |  +- Missing code splitting, tree shaking not working, barrel file imports
|  |     -> Bundle analyzer, check import patterns, add dynamic imports
|  +- Duplicate dependencies
|  |  +- Multiple versions of same library bundled
|  |     -> Dedupe, check peer dependencies, use resolutions
|  +- Large assets
|     +- Unoptimized images, embedded fonts, inline data URIs
|        -> Image optimization, font subsetting, external assets
|
+- Slow database queries
   +- Single slow query
   |  +- Missing index, suboptimal join order, full table scan
   |     -> EXPLAIN ANALYZE, add index, rewrite query
   +- Many small queries (N+1)
   |  +- ORM lazy loading, loop with individual queries
   |     -> Eager loading, batch queries, dataloader pattern
   +- Lock contention
      +- Long transactions, row-level locks, table locks
         -> Shorten transactions, check isolation level, advisory locks
```

## Profiling Tool Selection Matrix

| Problem | Node.js | Python | Go | Rust | Browser |
|---------|---------|--------|----|------|---------|
| **CPU hotspots** | clinic flame, 0x | py-spy, scalene | pprof (CPU) | cargo-flamegraph, samply | DevTools Performance |
| **Memory leaks** | clinic doctor, heap snapshot | memray, tracemalloc | pprof (heap) | DHAT, heaptrack | DevTools Memory |
| **Memory allocation** | --heap-prof | memray, scalene | pprof (allocs) | DHAT | DevTools Allocation |
| **Async bottlenecks** | clinic bubbleprof | asyncio debug mode | pprof (goroutine) | tokio-console | DevTools Performance |
| **I/O profiling** | clinic doctor | strace, py-spy | pprof (block) | strace, perf | Network tab |
| **GC pressure** | --trace-gc | gc.set_debug | GODEBUG=gctrace=1 | N/A (no GC) | Performance timeline |
| **Lock contention** | N/A | py-spy (threading) | pprof (mutex) | parking_lot stats | N/A |
| **Startup time** | --cpu-prof | python -X importtime | go build -v | cargo build --timings | Lighthouse |

## CPU Profiling Quick Reference

### Flamegraph Basics

```
Reading a flamegraph:
- X-axis: proportion of total samples (wider = more time)
- Y-axis: call stack depth (bottom = entry point, top = leaf)
- Color: random (not meaningful) in most tools
- Look for: wide plateaus at the top (hot functions)
- Ignore: narrow towers (called often but fast)

Key actions:
1. Find the widest bars at the TOP of the graph
2. Trace down to see what calls them
3. Focus optimization on the widest top-level functions
4. Re-profile after each change to verify improvement
```

### Tool Quick Start

| Tool | Language | Command | Output |
|------|----------|---------|--------|
| **py-spy** | Python | `py-spy record -o profile.svg -- python app.py` | SVG flamegraph |
| **py-spy top** | Python | `py-spy top --pid PID` | Live top-like view |
| **pprof** | Go | `go tool pprof -http :8080 http://localhost:6060/debug/pprof/profile?seconds=30` | Interactive web UI |
| **clinic flame** | Node.js | `clinic flame -- node app.js` | HTML flamegraph |
| **0x** | Node.js | `0x app.js` | SVG flamegraph |
| **cargo-flamegraph** | Rust | `cargo flamegraph --bin myapp` | SVG flamegraph |
| **samply** | Rust/C/C++ | `samply record ./target/release/myapp` | Firefox Profiler UI |
| **perf** | Linux (any) | `perf record -g ./myapp && perf script \| inferno-flamegraph > out.svg` | SVG flamegraph |

## Memory Profiling Quick Reference

| Tool | Language | Command | What It Shows |
|------|----------|---------|---------------|
| **memray** | Python | `memray run script.py && memray flamegraph output.bin` | Allocation flamegraph, leak detection |
| **tracemalloc** | Python | `tracemalloc.start(); snapshot = tracemalloc.take_snapshot()` | Top allocators, allocation traceback |
| **scalene** | Python | `scalene script.py` | CPU + memory + GPU in one profiler |
| **heaptrack** | C/C++/Rust | `heaptrack ./myapp && heaptrack_gui heaptrack.myapp.*.zst` | Allocation timeline, flamegraph, leak candidates |
| **DHAT** | Rust | `valgrind --tool=dhat ./target/debug/myapp` | Allocation sites, short-lived allocs |
| **pprof (heap)** | Go | `go tool pprof http://localhost:6060/debug/pprof/heap` | Live heap, allocation counts |
| **Chrome heap** | JS/Browser | DevTools - Memory - Take heap snapshot | Object retention, detached DOM |
| **clinic doctor** | Node.js | `clinic doctor -- node app.js` | Memory + CPU + event loop diagnosis |

## Bundle Analysis Quick Reference

| Tool | Bundler | Command | Output |
|------|---------|---------|--------|
| **webpack-bundle-analyzer** | Webpack | `npx webpack-bundle-analyzer stats.json` | Interactive treemap |
| **source-map-explorer** | Any | `npx source-map-explorer bundle.js` | Treemap from source maps |
| **rollup-plugin-visualizer** | Rollup/Vite | Add plugin, build | HTML treemap |
| **vite-bundle-visualizer** | Vite | `npx vite-bundle-visualizer` | Treemap visualization |
| **bundlephobia** | npm | `npx bundlephobia <package>` | Package size analysis |
| **size-limit** | Any | Configure in package.json, run in CI | Size budget enforcement |

### Bundle Size Reduction Checklist

```
[ ] Dynamic imports for routes and heavy components
[ ] Tree shaking working (check for side effects in package.json)
[ ] No barrel file re-exports pulling in entire modules
[ ] Lodash: use lodash-es or individual imports (lodash/debounce)
[ ] Moment.js replaced with date-fns or dayjs
[ ] Images optimized (WebP/AVIF, responsive sizes, lazy loading)
[ ] Fonts subsetted to used characters
[ ] Gzip/Brotli compression enabled on server
[ ] Source maps excluded from production bundle size
[ ] CSS purged of unused styles (PurgeCSS, Tailwind JIT)
```

## Database Performance Quick Reference

### EXPLAIN ANALYZE Interpretation

```
Key metrics in EXPLAIN ANALYZE output:
|
+- Seq Scan          -> Full table scan (often bad for large tables)
|  +- Fix: Add index on filter columns
+- Index Scan        -> Using index (good)
+- Bitmap Index Scan -> Multiple index conditions combined (good)
+- Nested Loop       -> OK for small inner table, bad for large joins
|  +- Fix: Add index on join column, consider Hash Join
+- Hash Join         -> Good for large equi-joins
+- Sort              -> Check if index can provide order
|  +- Fix: Add index matching ORDER BY
+- actual time       -> First row..last row in milliseconds
+- rows              -> Actual rows vs planned (estimate accuracy)
+- buffers           -> shared hit (cache) vs read (disk I/O)
```

### N+1 Detection

```
Symptoms:
- Many identical queries with different WHERE values
- Response time scales linearly with result count
- Query log shows repeated patterns

Detection:
- Django: django-debug-toolbar, nplusone
- Rails: Bullet gem
- SQLAlchemy: sqlalchemy.echo=True, look for repeated patterns
- General: enable slow query log, count queries per request

Fix:
- Eager loading (JOIN, prefetch, include)
- Batch queries (WHERE id IN (...))
- DataLoader pattern (batch + cache per request)
```

## Load Testing Quick Reference

| Tool | Language | Strengths | Command |
|------|----------|-----------|---------|
| **k6** | Go (JS scripts) | Scripted scenarios, thresholds, cloud | `k6 run script.js` |
| **artillery** | Node.js | YAML config, plugins, Playwright | `artillery run config.yml` |
| **vegeta** | Go | CLI piping, constant rate | `echo "GET http://localhost" \| vegeta attack \| vegeta report` |
| **wrk** | C | Lightweight, Lua scripts | `wrk -t4 -c100 -d30s http://localhost` |
| **autocannon** | Node.js | Programmatic, pipelining | `autocannon -c 100 -d 30 http://localhost` |
| **locust** | Python | Python classes, distributed | `locust -f locustfile.py` |

### Load Test Types

```
Test Type Selection:
|
+- Smoke Test
|  +- Minimal load (1-2 VUs) to verify system works
|     Duration: 1-5 minutes
|
+- Load Test
|  +- Expected production load
|     Duration: 15-60 minutes
|     Goal: Verify SLOs are met under normal conditions
|
+- Stress Test
|  +- Beyond expected load, find breaking point
|     Ramp up until errors or unacceptable latency
|     Goal: Know the system's limits
|
+- Spike Test
|  +- Sudden burst of traffic
|     Instant jump to high load, then drop
|     Goal: Test auto-scaling, queue behavior
|
+- Soak Test (Endurance)
|  +- Moderate load for extended period (hours)
|     Goal: Find memory leaks, resource exhaustion, GC issues
|
+- Breakpoint Test
   +- Continuously ramp up until failure
      Goal: Find maximum capacity
```

## Benchmarking Quick Reference

| Tool | Domain | Command | Notes |
|------|--------|---------|-------|
| **hyperfine** | CLI commands | `hyperfine 'cmd1' 'cmd2'` | Warm-up, statistical analysis, export |
| **criterion** | Rust | `cargo bench` (with criterion dep) | Statistical, HTML reports, regression detection |
| **testing.B** | Go | `go test -bench=. -benchmem` | Built-in, memory allocs, sub-benchmarks |
| **pytest-benchmark** | Python | `pytest --benchmark-only` | Statistical, histograms, comparison |
| **vitest bench** | JS/TS | `vitest bench` | Built-in to Vitest, Tinybench engine |
| **Benchmark.js** | JS | Programmatic setup | Statistical analysis, ops/sec |

### Benchmarking Best Practices

```
[ ] Warm up before measuring (JIT compilation, cache population)
[ ] Run multiple iterations (minimum 10, prefer 100+)
[ ] Report statistical summary (mean, median, stddev, min, max)
[ ] Control for system noise (close other apps, pin CPU frequency)
[ ] Compare against baseline (previous version, alternative impl)
[ ] Measure what matters (end-to-end, not micro-operations in isolation)
[ ] Profile before benchmarking (know WHAT to benchmark)
[ ] Document environment (hardware, OS, runtime version, flags)
```

## Optimization Patterns Quick Reference

| Pattern | When to Use | Example |
|---------|-------------|---------|
| **Caching** | Repeated expensive computations or I/O | Redis, in-memory LRU, CDN, memoization |
| **Lazy loading** | Resources not needed immediately | Dynamic imports, virtual scrolling, pagination |
| **Connection pooling** | Frequent DB/HTTP connections | PgBouncer, HikariCP, urllib3 pool |
| **Batch operations** | Many small operations on same resource | Bulk INSERT, DataLoader, batch API calls |
| **Pagination** | Large result sets | Cursor-based (not offset) for large datasets |
| **Compression** | Network transfer of text data | Brotli > gzip for static, gzip for dynamic |
| **Streaming** | Processing large files or datasets | Line-by-line, chunk processing, async iterators |
| **Precomputation** | Predictable expensive calculations | Materialized views, build-time generation |
| **Denormalization** | Read-heavy with expensive joins | Duplicate data for read performance |
| **Index optimization** | Slow queries on large tables | Composite indexes matching query patterns |

## Common Gotchas

| Gotcha | Why It Hurts | Fix |
|--------|-------------|-----|
| Premature optimization | Wastes time on non-bottlenecks, adds complexity | Profile first, optimize the measured hot path |
| Micro-benchmarks misleading | JIT, caching, branch prediction differ from real workload | Benchmark realistic workloads, validate with production metrics |
| Profiling overhead | Profiler itself skews results (observer effect) | Use sampling profilers (py-spy, pprof) not tracing profilers |
| Cache invalidation | Stale data served, inconsistent state across nodes | TTL + event-based invalidation, cache-aside pattern |
| Optimizing cold path | Spending effort on rarely-executed code | Focus on hot paths identified by profiling |
| Ignoring tail latency | p50 looks great but p99 is 10x worse | Measure and optimize p95/p99, not just averages |
| N+1 queries hidden by ORM | Each page load fires hundreds of queries | Enable query logging, use eager loading |
| Compression on small payloads | Overhead exceeds savings for payloads <150 bytes | Only compress above minimum size threshold |
| Connection pool too large | Each connection uses memory, causes lock contention | Size pool to CPU cores x 2-3, not hundreds |
| Missing async in I/O path | One blocking call serializes all concurrent requests | Audit entire request path for blocking calls |
| Benchmarking debug builds | Debug builds 10-100x slower, misleading results | Always benchmark release/optimized builds |
| Over-indexing database | Write performance degrades, storage bloats | Only index columns in WHERE, JOIN, ORDER BY clauses |
