---
name: javascript-ops
description: "JavaScript and Node.js patterns, async programming, modules, runtime internals, and modern ES2024+ features. Use for: javascript, js, node, nodejs, esm, commonjs, promise, async await, event loop, v8, npm, es6, es2024, worker threads, streams, event emitter, prototype, closure."
allowed-tools: "Read Write Bash"
related-skills: [typescript-ops, react-ops, vue-ops, testing-ops]
---

# JavaScript Operations

Comprehensive reference for modern JavaScript and Node.js — async patterns, module systems, runtime internals, and ES2022-2025 features.

---

## Async Decision Tree

```
What are you doing asynchronously?
│
├─ Simple one-off operation (DB query, HTTP call)
│   └─ async/await with try/catch  ✓ default choice
│
├─ Multiple independent operations
│   ├─ All must succeed → Promise.all([a(), b(), c()])
│   ├─ Don't care about failures → Promise.allSettled([...])
│   └─ First one wins → Promise.race([...]) or Promise.any([...])
│
├─ Need external resolve/reject control (deferred)
│   └─ Promise.withResolvers()  (ES2024)
│
├─ Processing a sequence of async values
│   ├─ Known array → for...of with await inside loop
│   └─ Unknown/infinite sequence → async generator + for await...of
│
├─ Large data / backpressure concerns
│   └─ Streams (ReadableStream / node:stream)
│       ├─ Transform data in flight → TransformStream / Transform
│       └─ Pipe chain → stream.pipeline() (Node) / pipeThrough() (Web)
│
├─ CPU-intensive work (would block event loop)
│   ├─ Short burst → offload with setTimeout(fn, 0) to yield
│   └─ Real work → Worker (browser) / worker_threads (Node)
│       └─ Shared memory needed → SharedArrayBuffer + Atomics
│
└─ Legacy code uses callbacks
    └─ Wrap with util.promisify() (Node) or new Promise() constructor
```

---

## Module System Decision Tree

```
Which module system should I use?
│
├─ New project / Node 18+
│   └─ ESM  (set "type": "module" in package.json)
│       ├─ import / export syntax
│       ├─ Top-level await supported
│       └─ Better tree-shaking with bundlers
│
├─ Publishing a library
│   ├─ ESM-only → simplest, but breaks older CJS consumers
│   ├─ CJS-only → safe but no tree-shaking
│   └─ Dual package (recommended) → "exports" field with conditions
│       ├─ "import": "./dist/index.mjs"
│       └─ "require": "./dist/index.cjs"
│
├─ Existing CJS project, want ESM
│   ├─ Per-file migration → rename to .mjs, update require → import
│   ├─ Whole-project → add "type": "module", rename .cjs exceptions
│   └─ Keep CJS, add ESM wrapper → create thin .mjs re-export layer
│
├─ Browser (no bundler)
│   └─ Native ESM — <script type="module"> + importmap
│
└─ Need dynamic loading
    └─ import() — works in both ESM and CJS files
        ├─ Lazy routes / code splitting
        └─ Conditional platform code
```

**Migration path:** CJS → Dual → ESM-only

---

## Event Loop Quick Reference

```
┌─────────────────────────────────────────────────────────┐
│                    Call Stack                           │
│   (synchronous code executes here)                      │
└─────────────────────────┬───────────────────────────────┘
                          │ stack empty?
                          ▼
┌─────────────────────────────────────────────────────────┐
│              Microtask Queue  (drained fully)           │
│   • Promise.then / .catch / .finally callbacks         │
│   • queueMicrotask(fn)                                  │
│   • MutationObserver callbacks (browser)                │
│   • process.nextTick (Node — runs BEFORE other microtasks)│
└─────────────────────────┬───────────────────────────────┘
                          │ microtasks empty?
                          ▼
┌─────────────────────────────────────────────────────────┐
│              Macrotask Queue  (one task per loop tick)  │
│   • setTimeout / setInterval callbacks                  │
│   • setImmediate (Node — runs in "check" phase)         │
│   • I/O callbacks (network, file system)                │
│   • requestAnimationFrame (browser)                     │
│   • MessagePort / Worker messages                       │
└─────────────────────────────────────────────────────────┘

Node.js event loop PHASES (libuv):
  timers → pending callbacks → idle/prepare → poll → check → close callbacks
  └─ process.nextTick + microtasks drain after EVERY phase
```

**Key rules:**
- Microtasks always run before the next macrotask
- `process.nextTick` fires before other microtasks (Promise.then)
- `setImmediate` fires in the "check" phase, after I/O callbacks
- `setTimeout(fn, 0)` fires in "timers" phase — after I/O in same iteration

---

## Modern JS Cheat Sheet (ES2022–2025)

| Feature | Year | Usage |
|---------|------|-------|
| `Array.at(-1)` | ES2022 | Last element without `.length - 1` |
| `Object.hasOwn(obj, key)` | ES2022 | Replaces `obj.hasOwnProperty(key)` |
| `#privateField` in class | ES2022 | True private (not just convention) |
| `static {}` class block | ES2022 | One-time class initialization |
| Top-level `await` | ES2022 | `await` at module top — ESM only |
| `Error cause` | ES2022 | `new Error('msg', { cause: err })` |
| `structuredClone(obj)` | ES2022 | Deep clone — built-in, no lodash |
| `Array.findLast()` | ES2023 | Find from end |
| `WeakMap(Symbol)` | ES2023 | Symbols as WeakMap keys |
| `Object.groupBy(iter, fn)` | ES2024 | Group into plain object |
| `Map.groupBy(iter, fn)` | ES2024 | Group into Map |
| `Promise.withResolvers()` | ES2024 | Deferred pattern |
| `ArrayBuffer.prototype.resize()` | ES2024 | Grow/shrink buffer in-place |
| `String.prototype.isWellFormed()` | ES2024 | Check valid Unicode |
| `import assert { type: 'json' }` | ES2024 | Import attributes |
| `Set.prototype.union(other)` | ES2025 | Set algebra methods |
| `Set.prototype.intersection(other)` | ES2025 | Set algebra methods |
| `Set.prototype.difference(other)` | ES2025 | Set algebra methods |
| Iterator helpers (`map`, `filter`, `take`…) | ES2025 | Lazy iterator protocol |
| `using` / `Symbol.dispose` | ES2025 | Explicit resource management |
| `Temporal` API | Stage 3 | Modern date/time (replaces Date) |
| `import defer` | Stage 3 | Deferred module evaluation |

---

## Node.js Quick Start

```javascript
// Built-in test runner (Node 18+, stable in Node 20)
import { describe, it, before, after, mock } from 'node:test';
import assert from 'node:assert/strict';

describe('my module', () => {
  it('adds numbers', () => {
    assert.equal(1 + 1, 2);
  });
});

// Run: node --test
// Watch: node --test --watch
// Coverage: node --test --experimental-test-coverage
```

```javascript
// fs/promises — built-in, no third-party needed
import { readFile, writeFile, readdir } from 'node:fs/promises';

const content = await readFile('./config.json', 'utf8');
const files = await readdir('./src', { recursive: true }); // Node 18.17+

// .env loading — Node 21+ (no dotenv package required)
// node --env-file=.env server.js
```

**Key built-in modules:**

| Module | Purpose |
|--------|---------|
| `node:fs/promises` | Async file system |
| `node:path` | Path manipulation |
| `node:url` | URL parsing, `fileURLToPath` |
| `node:crypto` | Hashing, encryption, UUIDs |
| `node:stream` | Streams + `pipeline()` |
| `node:worker_threads` | CPU parallelism |
| `node:child_process` | Subprocess execution |
| `node:test` | Built-in test runner |
| `node:http` / `node:http2` | HTTP servers |
| `node:diagnostics_channel` | Observability hooks |
| `node:perf_hooks` | Performance measurement |

---

## Error Handling Patterns

```javascript
// 1. Standard async try/catch
async function fetchUser(id) {
  try {
    const res = await fetch(`/api/users/${id}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`, { cause: res });
    return await res.json();
  } catch (err) {
    console.error('fetchUser failed:', err);
    throw err; // re-throw unless you can recover
  }
}

// 2. Abort with timeout (Node 17.3+ / browsers)
const signal = AbortSignal.timeout(5000);
const res = await fetch(url, { signal });

// 3. Global unhandled rejection handler
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection:', reason);
  process.exit(1); // always exit — unknown state
});

// 4. AggregateError — wraps multiple errors
const results = await Promise.allSettled([a(), b(), c()]);
const failures = results.filter(r => r.status === 'rejected');
if (failures.length) {
  throw new AggregateError(failures.map(f => f.reason), 'Multiple failures');
}

// 5. Custom Error class
class AppError extends Error {
  constructor(message, { code, cause } = {}) {
    super(message, { cause });
    this.name = 'AppError';
    this.code = code;
  }
}
```

---

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| `this` is `undefined` in callback | Arrow functions capture `this` lexically; regular functions don't | Use arrow function or `.bind(this)` |
| Closure captures loop variable `var i` | `var` is function-scoped; all closures share same `i` | Use `let i` (block-scoped) or `.forEach` |
| `==` treats `null == undefined` as true | Loose equality does type coercion | Always use `===` and `!==` |
| `0.1 + 0.2 !== 0.3` | IEEE 754 floating-point precision | `Math.round(n * 1e10) / 1e10` or use `Number.EPSILON` comparison |
| `a?.b ?? c` vs `a?.b \|\| c` | `??` only falls back on `null`/`undefined`; `\|\|` on any falsy | Use `??` when 0 or `""` are valid values |
| `typeof null === 'object'` | Historic JavaScript bug | Check `val === null` explicitly |
| `[3,10,2].sort()` → `[10,2,3]` | Default sort converts to strings | Provide comparator: `.sort((a,b) => a - b)` |
| `parseInt('08')` → 8 in modern, 0 in old | Octal parsing in pre-ES5 | Always pass radix: `parseInt(str, 10)` |
| `for...in` on arrays | Iterates inherited enumerable properties too | Use `for...of` or `.forEach()` for arrays |
| `Promise.all` fails fast | One rejection cancels all (others still run) | Use `Promise.allSettled` if you need all results |
| `JSON.stringify` drops `undefined` / functions / Symbols | Not JSON-serializable | Convert to `null` first or use a replacer function |
| Async function always returns a Promise | `async () => 42` returns `Promise<42>`, not `42` | `await` the call site or chain `.then()` |

---

## Reference Files

| File | When to Load |
|------|-------------|
| `references/async-patterns.md` | Promise combinators, async iterators, AbortController, Streams, Web Workers, structured concurrency |
| `references/modules-runtime.md` | ESM/CJS/dual packages, dynamic import, V8 internals, memory management, event loop deep dive |
| `references/modern-features.md` | ES2022-2025 feature details, Proxy/Reflect, Decorators, Temporal, Explicit Resource Management |
| `references/node-patterns.md` | node:test runner, fs/promises, worker_threads, streams, crypto, graceful shutdown, permission model |

---

## See Also

- `typescript-ops` — TypeScript types, generics, utility types, tsconfig
- `react-ops` — React hooks, Server Components, state management
- `vue-ops` — Vue 3 Composition API, Pinia, Nuxt
- `testing-ops` — Jest, Vitest, Playwright, TDD patterns
