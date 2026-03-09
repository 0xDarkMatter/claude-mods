# Async Patterns Reference

Comprehensive patterns for asynchronous JavaScript — Promises, async/await, iterators, streams, workers, and cancellation.

---

## Promise Fundamentals

### Constructor

```javascript
// Only use the constructor to wrap callback-based APIs
function readFileAsync(path) {
  return new Promise((resolve, reject) => {
    fs.readFile(path, 'utf8', (err, data) => {
      if (err) reject(err);
      else resolve(data);
    });
  });
}

// Anti-pattern: Promise constructor around another Promise
// BAD — "deferred anti-pattern"
const p = new Promise((resolve) => {
  fetch('/api/data').then(resolve); // don't do this
});

// GOOD — just return the Promise directly
const p = fetch('/api/data');
```

### then / catch / finally

```javascript
fetch('/api/users')
  .then(res => {
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json(); // return value becomes next then's input
  })
  .then(users => console.log(users))
  .catch(err => {
    // catches ALL errors from any then() above
    console.error('Failed:', err);
    return []; // recover — return value continues the chain
  })
  .finally(() => {
    // always runs, receives no argument, does NOT change resolved value
    hideLoadingSpinner();
  });
```

### Chaining vs Nesting

```javascript
// BAD — nested (pyramid of doom with Promises)
fetch('/api/user')
  .then(res => res.json().then(user => {
    fetch(`/api/posts/${user.id}`).then(res => res.json().then(posts => {
      console.log(posts);
    }));
  }));

// GOOD — flat chain
fetch('/api/user')
  .then(res => res.json())
  .then(user => fetch(`/api/posts/${user.id}`))
  .then(res => res.json())
  .then(posts => console.log(posts));

// BEST — async/await
const res = await fetch('/api/user');
const user = await res.json();
const postsRes = await fetch(`/api/posts/${user.id}`);
const posts = await postsRes.json();
```

---

## Promise Combinators

### Promise.all — All must succeed

```javascript
// Runs in parallel, fails fast on first rejection
const [user, posts, comments] = await Promise.all([
  fetchUser(userId),
  fetchPosts(userId),
  fetchComments(userId),
]);

// With error handling — if any rejects, the whole thing rejects
try {
  const results = await Promise.all([a(), b(), c()]);
} catch (err) {
  // err is from whichever promise rejected first
  // The other promises are NOT cancelled (still running!)
}

// Use case: multiple independent API calls that all must succeed
async function loadDashboard(userId) {
  const [profile, analytics, notifications] = await Promise.all([
    api.getProfile(userId),
    api.getAnalytics(userId),
    api.getNotifications(userId),
  ]);
  return { profile, analytics, notifications };
}
```

### Promise.allSettled — Handle each individually

```javascript
// Never rejects — always resolves with array of outcome objects
const results = await Promise.allSettled([
  fetch('/api/primary'),
  fetch('/api/secondary'),
  fetch('/api/tertiary'),
]);

for (const result of results) {
  if (result.status === 'fulfilled') {
    console.log('Success:', result.value);
  } else {
    console.warn('Failed:', result.reason);
  }
}

// Use case: batch operations where partial success is acceptable
async function syncAllRecords(records) {
  const results = await Promise.allSettled(
    records.map(r => syncRecord(r))
  );
  const failures = results.filter(r => r.status === 'rejected');
  if (failures.length > 0) {
    console.warn(`${failures.length} of ${records.length} records failed to sync`);
  }
  return results;
}
```

### Promise.race — First settled wins

```javascript
// Resolves or rejects with the FIRST settled promise (fulfilled OR rejected)
const result = await Promise.race([
  fetch('/api/data'),
  new Promise((_, reject) =>
    setTimeout(() => reject(new Error('Timeout')), 5000)
  ),
]);

// Use case: implement timeout (prefer AbortSignal.timeout() in modern code)
function withTimeout(promise, ms) {
  const timeout = new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`Operation timed out after ${ms}ms`)), ms)
  );
  return Promise.race([promise, timeout]);
}

// Use case: racing multiple endpoints (first one wins)
const data = await Promise.race([
  fetchFromPrimary(),
  fetchFromFallback(),
]);
```

### Promise.any — First success wins

```javascript
// Resolves with FIRST fulfilled promise; rejects (AggregateError) only if ALL reject
try {
  const data = await Promise.any([
    fetchFromCDN1(),
    fetchFromCDN2(),
    fetchFromOrigin(),
  ]);
  console.log('Got data from fastest source:', data);
} catch (err) {
  // err is AggregateError — all failed
  console.error('All sources failed:', err.errors);
}

// Use case: redundant data sources with automatic fallback
async function fetchWithFallback(urls) {
  return Promise.any(urls.map(url => fetch(url).then(r => r.json())));
}
```

---

## async/await Patterns

### Sequential vs Parallel

```javascript
// SEQUENTIAL — each waits for the previous (slow if independent)
const user = await getUser(id);
const posts = await getPosts(id);     // waits for getUser to finish first
const friends = await getFriends(id); // waits for getPosts to finish first

// PARALLEL — all start together (fast)
const [user, posts, friends] = await Promise.all([
  getUser(id),
  getPosts(id),
  getFriends(id),
]);

// MIXED — some sequential dependencies, some parallel
const user = await getUser(id); // must come first
const [posts, preferences] = await Promise.all([
  getPosts(user.blogId),         // depends on user
  getPreferences(user.settingsId), // depends on user
]);
```

### Error Handling

```javascript
// 1. try/catch — most readable
async function loadUser(id) {
  try {
    const res = await fetch(`/api/users/${id}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`, { cause: res });
    return await res.json();
  } catch (err) {
    if (err.name === 'AbortError') return null; // cancelled — not an error
    throw err; // re-throw unexpected errors
  }
}

// 2. Inline error handling for parallel calls
const [userResult, postsResult] = await Promise.allSettled([
  getUser(id),
  getPosts(id),
]);
const user = userResult.status === 'fulfilled' ? userResult.value : null;

// 3. Utility: "safe" wrapper that returns [error, result]
async function safe(promise) {
  try {
    return [null, await promise];
  } catch (err) {
    return [err, null];
  }
}

const [err, user] = await safe(getUser(id));
if (err) { /* handle */ }
```

### Top-Level Await (ESM only)

```javascript
// Works at the top level of an ES module — no async wrapper needed
// file: config.mjs
const config = await fetch('/api/config').then(r => r.json());

export const DB_URL = config.dbUrl;
export const API_KEY = config.apiKey;

// Importers of this module will wait for the top-level awaits to settle
// import { DB_URL } from './config.mjs'; // already resolved by the time you use it
```

---

## Promise.withResolvers — Deferred Pattern

```javascript
// ES2024 — cleaner deferred pattern
const { promise, resolve, reject } = Promise.withResolvers();

// Classic use case: expose resolve/reject to external code
class EventQueue {
  #waiters = [];

  async waitForNext() {
    const { promise, resolve } = Promise.withResolvers();
    this.#waiters.push(resolve);
    return promise;
  }

  emit(value) {
    const resolve = this.#waiters.shift();
    resolve?.(value);
  }
}

// Use case: WebSocket message waiting
class WebSocketClient {
  #pending = new Map();
  #counter = 0;

  send(data) {
    const id = ++this.#counter;
    const { promise, resolve, reject } = Promise.withResolvers();
    this.#pending.set(id, { resolve, reject });
    this.#ws.send(JSON.stringify({ id, data }));
    return promise;
  }

  #onMessage(event) {
    const { id, result, error } = JSON.parse(event.data);
    const { resolve, reject } = this.#pending.get(id) ?? {};
    this.#pending.delete(id);
    if (error) reject(new Error(error));
    else resolve(result);
  }
}

// Before ES2024 — manual deferred
function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}
```

---

## Async Iterators

### for await...of

```javascript
// Works with any object implementing Symbol.asyncIterator
async function processLargeFile(filePath) {
  const stream = fs.createReadStream(filePath, { encoding: 'utf8' });
  for await (const chunk of stream) {
    await processChunk(chunk);
  }
}

// Paginated API — async iterator wraps pagination logic
async function* paginate(url) {
  let nextUrl = url;
  while (nextUrl) {
    const res = await fetch(nextUrl);
    const { data, next } = await res.json();
    yield* data;        // yield each item individually
    nextUrl = next;     // null/undefined stops the loop
  }
}

for await (const user of paginate('/api/users?limit=100')) {
  await processUser(user);
}
```

### Custom Async Generators

```javascript
// Async generator function — yields Promises
async function* generateNumbers(start, end, delayMs = 100) {
  for (let i = start; i <= end; i++) {
    await new Promise(r => setTimeout(r, delayMs));
    yield i;
  }
}

// Async generator for event-based sources
async function* fromEventTarget(target, event, { signal } = {}) {
  const { promise, resolve } = Promise.withResolvers();
  const handler = (e) => resolve(e);
  target.addEventListener(event, handler, { once: true, signal });
  try {
    yield await promise;
    // Recurse to get next event
    yield* fromEventTarget(target, event, { signal });
  } finally {
    target.removeEventListener(event, handler);
  }
}

// Consuming with early exit
const controller = new AbortController();
for await (const event of fromEventTarget(emitter, 'data', { signal: controller.signal })) {
  processEvent(event);
  if (shouldStop) controller.abort();
}
```

### Symbol.asyncIterator

```javascript
class AsyncRange {
  constructor(start, end, delay = 0) {
    this.start = start;
    this.end = end;
    this.delay = delay;
  }

  [Symbol.asyncIterator]() {
    let current = this.start;
    const { end, delay } = this;
    return {
      async next() {
        if (delay) await new Promise(r => setTimeout(r, delay));
        if (current <= end) {
          return { value: current++, done: false };
        }
        return { value: undefined, done: true };
      },
      return() {
        // Called when consumer breaks early
        return { value: undefined, done: true };
      }
    };
  }
}

for await (const n of new AsyncRange(1, 5, 100)) {
  console.log(n); // 1, 2, 3, 4, 5 with 100ms between each
}
```

---

## AbortController — Cancellation

### Fetch Cancellation

```javascript
// Cancel an in-flight fetch
const controller = new AbortController();

const button = document.querySelector('#cancel');
button.addEventListener('click', () => controller.abort());

try {
  const res = await fetch('/api/large-export', {
    signal: controller.signal,
  });
  const data = await res.json();
} catch (err) {
  if (err.name === 'AbortError') {
    console.log('Request was cancelled');
  } else {
    throw err;
  }
}
```

### AbortSignal.timeout — Built-in Timeout

```javascript
// No need for Promise.race with a timeout Promise anymore
const res = await fetch('/api/data', {
  signal: AbortSignal.timeout(5000), // throws TimeoutError after 5s
});

// TimeoutError is a subclass of DOMException
try {
  const res = await fetch(url, { signal: AbortSignal.timeout(3000) });
} catch (err) {
  if (err.name === 'TimeoutError') {
    console.log('Request timed out');
  }
}
```

### AbortSignal.any — Combine Signals

```javascript
// Cancel if EITHER the user aborts OR we time out
const userController = new AbortController();
const combined = AbortSignal.any([
  userController.signal,
  AbortSignal.timeout(10_000),
]);

const res = await fetch(url, { signal: combined });
```

### Custom Abortable Operations

```javascript
// Make your own async functions respect abort signals
async function delay(ms, { signal } = {}) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => {
      clearTimeout(timer);
      reject(signal.reason ?? new DOMException('Aborted', 'AbortError'));
    }, { once: true });
  });
}

// Propagate cancellation through a chain of operations
async function processItems(items, { signal } = {}) {
  for (const item of items) {
    signal?.throwIfAborted(); // throws if already aborted
    await processItem(item, { signal });
  }
}
```

---

## Streams API

### ReadableStream

```javascript
// Create a readable stream from scratch
const stream = new ReadableStream({
  start(controller) {
    // Called once when stream is created
  },
  async pull(controller) {
    // Called when consumer wants more data
    const chunk = await getNextChunk();
    if (chunk === null) {
      controller.close();
    } else {
      controller.enqueue(chunk);
    }
  },
  cancel(reason) {
    // Called if consumer cancels
    cleanup();
  },
});

// Consume with for await
const reader = stream.getReader();
try {
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    process(value);
  }
} finally {
  reader.releaseLock();
}

// Or use for-await-of (web streams are async iterable in modern browsers/Node 18+)
for await (const chunk of stream) {
  process(chunk);
}
```

### WritableStream

```javascript
const writable = new WritableStream({
  async write(chunk, controller) {
    await persistChunk(chunk);
  },
  close() {
    console.log('Stream finished');
  },
  abort(err) {
    console.error('Stream aborted:', err);
  },
});

const writer = writable.getWriter();
await writer.write('chunk 1');
await writer.write('chunk 2');
await writer.close();
```

### TransformStream — Data Transformation in Flight

```javascript
// Parse newline-delimited JSON (NDJSON)
class NDJSONParser extends TransformStream {
  constructor() {
    let buffer = '';
    super({
      transform(chunk, controller) {
        buffer += chunk;
        const lines = buffer.split('\n');
        buffer = lines.pop(); // last line may be incomplete
        for (const line of lines) {
          if (line.trim()) {
            controller.enqueue(JSON.parse(line));
          }
        }
      },
      flush(controller) {
        if (buffer.trim()) {
          controller.enqueue(JSON.parse(buffer));
        }
      },
    });
  }
}

// Usage: fetch NDJSON and stream parsed objects
const response = await fetch('/api/export.ndjson');
const objectStream = response.body
  .pipeThrough(new TextDecoderStream())
  .pipeThrough(new NDJSONParser());

for await (const record of objectStream) {
  await insertRecord(record);
}
```

### Node.js Streams — pipeline()

```javascript
import { pipeline } from 'node:stream/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { createGzip } from 'node:zlib';
import { Transform } from 'node:stream';

// pipeline() properly handles errors and cleanup
await pipeline(
  createReadStream('./input.csv'),
  new Transform({
    objectMode: true,
    transform(chunk, encoding, callback) {
      // Transform each chunk
      const processed = processCSVChunk(chunk.toString());
      callback(null, processed);
    },
  }),
  createGzip(),
  createWriteStream('./output.csv.gz'),
);
```

### Backpressure

```javascript
// Writer respects backpressure automatically
const writer = writable.getWriter();

for (const chunk of largeDataset) {
  // write() returns a Promise that resolves when ready for more
  await writer.write(chunk);
}
```

---

## Web Workers

### Basic Worker (browser)

```javascript
// main.js
const worker = new Worker('./worker.js', { type: 'module' });

worker.postMessage({ type: 'COMPUTE', data: largeArray });

worker.addEventListener('message', (event) => {
  console.log('Result:', event.data.result);
});

worker.addEventListener('error', (event) => {
  console.error('Worker error:', event.message);
});

// Terminate when done
worker.terminate();
```

```javascript
// worker.js
self.addEventListener('message', async (event) => {
  const { type, data } = event.data;
  if (type === 'COMPUTE') {
    const result = heavyComputation(data);
    self.postMessage({ result });
  }
});
```

### Transferable Objects — Zero-Copy Transfer

```javascript
// Transfer ownership of ArrayBuffer — zero-copy, no serialization
const buffer = new ArrayBuffer(1024 * 1024 * 100); // 100MB
const view = new Uint8Array(buffer);

// After transfer, buffer is detached in the sender
worker.postMessage({ buffer }, [buffer]); // second arg = transferables
// buffer.byteLength === 0 now — ownership transferred

// In worker.js
self.addEventListener('message', ({ data: { buffer } }) => {
  const view = new Uint8Array(buffer);
  // ... process ...
  // Transfer back
  self.postMessage({ buffer }, [buffer]);
});
```

### SharedArrayBuffer + Atomics

```javascript
// SharedArrayBuffer — both threads read/write same memory
// Requires Cross-Origin Isolation: COOP + COEP headers

// main.js
const shared = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 10);
const array = new Int32Array(shared);

worker.postMessage({ shared }); // no transfer needed — it's shared

// Atomic operations prevent data races
Atomics.add(array, 0, 1);          // atomic increment
const val = Atomics.load(array, 0); // atomic read
Atomics.store(array, 0, 42);        // atomic write
const exchanged = Atomics.compareExchange(array, 0, expected, replacement);

// Atomic wait/notify (for coordination between threads)
// worker: wait for index 0 to change from 0
Atomics.wait(array, 0, 0); // blocks worker thread

// main: signal worker
Atomics.store(array, 0, 1);
Atomics.notify(array, 0, 1); // wake one waiter
```

### MessageChannel — Direct Worker-to-Worker Communication

```javascript
const channel = new MessageChannel();
const worker1 = new Worker('./worker1.js');
const worker2 = new Worker('./worker2.js');

// Give each worker a port — they can now talk directly
worker1.postMessage({ port: channel.port1 }, [channel.port1]);
worker2.postMessage({ port: channel.port2 }, [channel.port2]);

// In worker1.js
self.addEventListener('message', ({ data: { port } }) => {
  port.addEventListener('message', (e) => console.log('From worker2:', e.data));
  port.start();
  port.postMessage('Hello from worker1');
});
```

---

## Structured Concurrency — Cancellation Propagation

```javascript
// Cancel a group of operations atomically
async function fetchWithCleanup(urls, { signal } = {}) {
  const controller = new AbortController();

  // Cancel our internal controller if the parent signal fires
  signal?.addEventListener('abort', () => controller.abort(signal.reason), {
    once: true,
    signal: controller.signal, // auto-remove listener when we're done
  });

  try {
    return await Promise.all(
      urls.map(url => fetch(url, { signal: controller.signal }))
    );
  } catch (err) {
    controller.abort(err); // cancel remaining on first failure
    throw err;
  }
}

// Race with cleanup: cancel losers when winner is found
async function raceWithCleanup(operations) {
  const controller = new AbortController();
  try {
    return await Promise.any(
      operations.map(op => op({ signal: controller.signal }))
    );
  } finally {
    controller.abort(); // cancel all remaining operations
  }
}
```

---

## Error Handling in Async Code

### Global Unhandled Rejection Handlers

```javascript
// Browser
window.addEventListener('unhandledrejection', (event) => {
  console.error('Unhandled promise rejection:', event.reason);
  event.preventDefault(); // prevent default browser behavior (console error)
});

window.addEventListener('rejectionhandled', (event) => {
  console.log('Previously unhandled rejection was handled:', event.promise);
});

// Node.js
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection at:', promise, 'reason:', reason);
  process.exit(1); // crash — unknown state is dangerous
});

process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
  process.exit(1);
});
```

### Async Stack Traces

```javascript
// Node.js — enable async stack traces (slight performance cost)
// node --async-stack-traces script.js  (default in Node 12+)

// The Error.captureStackTrace pattern
class AsyncError extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = 'AsyncError';
    // Stack trace starts here, not inside Error constructor
    Error.captureStackTrace?.(this, AsyncError);
  }
}

// Preserving context across async boundaries with cause
async function loadConfig(path) {
  try {
    const text = await readFile(path, 'utf8');
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`Failed to load config from ${path}`, { cause: err });
  }
}
```

---

## Anti-Patterns to Avoid

```javascript
// BAD: async void — fire and forget, errors are silently swallowed
someButton.addEventListener('click', async () => {
  await doSomething(); // if this throws, nobody knows
});

// GOOD: handle the error
someButton.addEventListener('click', () => {
  doSomething().catch(err => showErrorToUser(err));
});

// BAD: floating promise (not awaited, not .catch'd)
function processItem(item) {
  fetch('/api/track'); // fire and forget — may fail silently
  return transformItem(item);
}

// BAD: Promise constructor wrapping a Promise
const p = new Promise(resolve => resolve(fetch(url))); // unnecessary wrapping

// BAD: sequential await where parallel is possible
const a = await getA();
const b = await getB(); // waits unnecessarily
const c = await getC(); // waits unnecessarily

// GOOD
const [a, b, c] = await Promise.all([getA(), getB(), getC()]);

// BAD: .then() inside async function (mixing styles)
async function getData() {
  return fetch(url).then(r => r.json()); // confusing mix
}

// GOOD: consistent async/await
async function getData() {
  const res = await fetch(url);
  return res.json();
}
```
