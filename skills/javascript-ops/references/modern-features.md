# Modern JavaScript Features Reference

ES2022 through ES2025, stage 3 proposals, and advanced runtime features.

---

## ES2022 Features

### Top-Level Await

```javascript
// ESM only — works at the top level of a module, no async wrapper
import { createPool } from 'pg';

// Module-level async initialization
const pool = await createPool({ connectionString: process.env.DATABASE_URL });

export async function query(sql, params) {
  return pool.query(sql, params);
}

// Use case: lazy initialization that must complete before module is usable
const config = await fetch('/api/config').then(r => r.json());

export const API_URL = config.apiUrl;
export const TIMEOUT = config.timeout;
```

### Private Class Fields and Methods

```javascript
class BankAccount {
  // Private field — truly inaccessible from outside
  #balance = 0;
  #transactionLog = [];

  // Private method
  #recordTransaction(amount, type) {
    this.#transactionLog.push({ amount, type, at: new Date() });
  }

  // Private static field
  static #instanceCount = 0;

  constructor(initialBalance) {
    this.#balance = initialBalance;
    BankAccount.#instanceCount++;
  }

  deposit(amount) {
    if (amount <= 0) throw new Error('Amount must be positive');
    this.#balance += amount;
    this.#recordTransaction(amount, 'deposit');
  }

  withdraw(amount) {
    if (amount > this.#balance) throw new Error('Insufficient funds');
    this.#balance -= amount;
    this.#recordTransaction(amount, 'withdrawal');
  }

  get balance() { return this.#balance; }

  // Check private field existence — 'in' operator works with private fields
  static isAccount(obj) {
    return #balance in obj; // true if obj has this private field
  }

  static get count() { return BankAccount.#instanceCount; }
}

const account = new BankAccount(1000);
account.deposit(500);
// account.#balance  // SyntaxError — genuinely inaccessible
BankAccount.isAccount(account); // true
```

### Static Class Blocks

```javascript
class Config {
  static DEBUG;
  static API_URL;
  static #initialized = false;

  // Static initialization block — runs once when class is defined
  static {
    // Can contain arbitrary initialization logic
    Config.DEBUG = process.env.NODE_ENV !== 'production';
    Config.API_URL = process.env.API_URL ?? 'https://api.example.com';
    Config.#initialized = true;
    console.log('Config initialized');
  }

  static isReady() { return Config.#initialized; }
}

// Use case: initialize from multiple sources, run try/catch
class Database {
  static connection;
  static error;

  static {
    try {
      Database.connection = createConnection(process.env.DB_URL);
    } catch (err) {
      Database.error = err;
    }
  }
}
```

### Array.at() — Negative Indexing

```javascript
const arr = [1, 2, 3, 4, 5];

// Before at()
arr[arr.length - 1]; // 5 — verbose
arr.slice(-1)[0];    // 5 — creates a new array

// With at()
arr.at(-1);   // 5 — last element
arr.at(-2);   // 4 — second to last
arr.at(0);    // 1 — first element (same as arr[0])
arr.at(1);    // 2

// Also works on strings and TypedArrays
'hello'.at(-1); // 'o'
new Uint8Array([10, 20, 30]).at(-1); // 30
```

### Object.hasOwn() — Safe hasOwnProperty

```javascript
// obj.hasOwnProperty is unsafe — can be overridden or null prototype
const obj = Object.create(null); // no prototype
// obj.hasOwnProperty('key'); // TypeError: not a function

// Object.hasOwn is always safe
Object.hasOwn(obj, 'key');     // false
Object.hasOwn({ a: 1 }, 'a'); // true
Object.hasOwn({ a: 1 }, 'b'); // false

// Replaces the classic idiom:
Object.prototype.hasOwnProperty.call(obj, 'key');
```

### Error cause — Error Chaining

```javascript
// Attach the original error to provide context
async function fetchUser(id) {
  try {
    const res = await fetch(`/api/users/${id}`);
    return await res.json();
  } catch (err) {
    // Wrap with context, preserve original
    throw new Error(`Failed to fetch user ${id}`, { cause: err });
  }
}

// Access the chain
try {
  await fetchUser(42);
} catch (err) {
  console.error(err.message);       // "Failed to fetch user 42"
  console.error(err.cause.message); // original network error
}

// Works with custom error classes
class DatabaseError extends Error {
  constructor(message, { cause, query } = {}) {
    super(message, { cause });
    this.name = 'DatabaseError';
    this.query = query;
  }
}
```

### structuredClone() — Deep Clone Built-In

```javascript
// No more lodash.cloneDeep or JSON.parse(JSON.stringify(...))
const original = {
  name: 'Alice',
  scores: [1, 2, 3],
  metadata: { created: new Date(), tags: new Set(['js', 'node']) },
};

const clone = structuredClone(original);
clone.scores.push(4);
clone.metadata.tags.add('es2022');

original.scores;           // [1, 2, 3] — unchanged
original.metadata.tags;   // Set {'js', 'node'} — unchanged

// Supports: Date, RegExp, Map, Set, ArrayBuffer, TypedArray, Blob, File, etc.
// Does NOT support: functions, class instances (becomes plain object), Symbol values

// Transfer ownership of ArrayBuffer while cloning the rest
const { buffer } = structuredClone(
  { name: 'test', data: new ArrayBuffer(1024) },
  { transfer: [original.data] } // transfer the buffer
);
```

---

## ES2023 Features

### Array.findLast() and Array.findLastIndex()

```javascript
const events = [
  { type: 'login', at: '08:00' },
  { type: 'purchase', at: '09:30' },
  { type: 'login', at: '14:00' },
  { type: 'logout', at: '17:00' },
];

// Find last login event
const lastLogin = events.findLast(e => e.type === 'login');
// { type: 'login', at: '14:00' }

// Before findLast — verbose
const lastLogin2 = [...events].reverse().find(e => e.type === 'login');

// findLastIndex — returns index, -1 if not found
const lastLoginIdx = events.findLastIndex(e => e.type === 'login'); // 2
```

### WeakMap with Symbol Keys

```javascript
// Previously only objects could be WeakMap keys
// Now Symbols (non-registered, non-global) can be WeakMap keys

const key = Symbol('private-data');
const weakMap = new WeakMap();

function attachPrivateData(obj, data) {
  weakMap.set(key, { obj, data }); // Symbol as key
}

// Use case: library code that attaches private metadata to symbols
```

---

## ES2024 Features

### Object.groupBy() and Map.groupBy()

```javascript
const products = [
  { name: 'Apple', category: 'fruit', price: 1.2 },
  { name: 'Banana', category: 'fruit', price: 0.5 },
  { name: 'Carrot', category: 'vegetable', price: 0.8 },
  { name: 'Broccoli', category: 'vegetable', price: 1.5 },
];

// Object.groupBy — groups into plain object
const byCategory = Object.groupBy(products, ({ category }) => category);
// {
//   fruit: [{ name: 'Apple', ... }, { name: 'Banana', ... }],
//   vegetable: [{ name: 'Carrot', ... }, { name: 'Broccoli', ... }]
// }

// Map.groupBy — groups into Map (preserves key type, any key type works)
const byPriceRange = Map.groupBy(products, ({ price }) => {
  if (price < 1) return 'budget';
  if (price < 2) return 'mid';
  return 'premium';
});
byPriceRange.get('budget'); // [{ name: 'Banana', ... }, { name: 'Carrot', ... }]
```

### Promise.withResolvers()

```javascript
// See async-patterns.md for full coverage
const { promise, resolve, reject } = Promise.withResolvers();

// Enables clean deferred patterns
class Semaphore {
  #count;
  #queue = [];

  constructor(count) { this.#count = count; }

  async acquire() {
    if (this.#count > 0) {
      this.#count--;
      return;
    }
    const { promise, resolve } = Promise.withResolvers();
    this.#queue.push(resolve);
    await promise;
  }

  release() {
    const resolve = this.#queue.shift();
    if (resolve) {
      resolve();
    } else {
      this.#count++;
    }
  }
}
```

### ArrayBuffer.prototype.resize() and transferToFixedLength()

```javascript
// Create a resizable ArrayBuffer
const buffer = new ArrayBuffer(1024, { maxByteLength: 1024 * 1024 }); // max 1MB

const view = new Uint8Array(buffer);
console.log(buffer.byteLength); // 1024

// Grow in-place — no new allocation, views stay valid
buffer.resize(2048);
console.log(buffer.byteLength); // 2048
console.log(view.byteLength);   // 2048 — view updated!

// Shrink
buffer.resize(512);

// Transfer to fixed-length (detaches original)
const fixed = buffer.transferToFixedLength();
// buffer is now detached (byteLength === 0)
// fixed is a regular ArrayBuffer that cannot be resized
```

### String.isWellFormed() and String.toWellFormed()

```javascript
// Detect and fix lone surrogates (invalid UTF-16)
const valid = 'Hello, world!';
const invalid = 'Hello\uD800World'; // lone surrogate

valid.isWellFormed();   // true
invalid.isWellFormed(); // false

// Replace lone surrogates with replacement character (U+FFFD)
invalid.toWellFormed(); // 'Hello\uFFFDWorld'

// Use case: before passing strings to APIs that require valid Unicode
function safeEncode(str) {
  return encodeURIComponent(str.isWellFormed() ? str : str.toWellFormed());
}
```

---

## ES2025 Features

### Set Methods — Set Algebra

```javascript
const js = new Set(['react', 'vue', 'angular', 'svelte']);
const ts = new Set(['react', 'angular', 'solid', 'qwik']);

// union — all elements from both
js.union(ts);
// Set { 'react', 'vue', 'angular', 'svelte', 'solid', 'qwik' }

// intersection — elements in both
js.intersection(ts);
// Set { 'react', 'angular' }

// difference — in js but not ts
js.difference(ts);
// Set { 'vue', 'svelte' }

// symmetricDifference — in either but not both
js.symmetricDifference(ts);
// Set { 'vue', 'svelte', 'solid', 'qwik' }

// Membership predicates
const react = new Set(['react']);
react.isSubsetOf(js);             // true
js.isSupersetOf(react);           // true
react.isDisjointFrom(new Set(['vue', 'svelte'])); // true

// These methods are non-mutating — return new Sets
```

### Iterator Helpers — Lazy Iteration Protocol

```javascript
// Iterator helpers are lazy — they don't evaluate until consumed
// Works on any iterable via Iterator.from()

const numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

// map — transform each element
const doubled = numbers.values().map(x => x * 2).toArray();
// [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]

// filter — keep matching elements
const evens = numbers.values().filter(x => x % 2 === 0).toArray();
// [2, 4, 6, 8, 10]

// take — limit to first N
const first3 = numbers.values().take(3).toArray();
// [1, 2, 3]

// drop — skip first N
const after3 = numbers.values().drop(3).toArray();
// [4, 5, 6, 7, 8, 9, 10]

// flatMap — transform and flatten
const sentences = ['hello world', 'foo bar'];
const words = sentences.values()
  .flatMap(s => s.split(' '))
  .toArray();
// ['hello', 'world', 'foo', 'bar']

// reduce — fold
const sum = numbers.values().reduce((acc, n) => acc + n, 0);
// 55

// Chaining — lazy, memory-efficient pipeline
const result = Iterator.from(hugeDataset)
  .filter(item => item.active)
  .map(item => transform(item))
  .take(100)
  .toArray(); // only evaluates 100 items + filter overhead

// forEach, some, every, find — terminal operations
numbers.values().some(x => x > 5);  // true
numbers.values().every(x => x > 0); // true
numbers.values().find(x => x > 7);  // 8
```

### Explicit Resource Management — using / Symbol.dispose

```javascript
// 'using' is like const but automatically calls [Symbol.dispose] on block exit
// Similar to C# 'using' or Python 'with'

class DatabaseConnection {
  constructor(url) {
    this.#conn = openConnection(url);
    console.log('Connection opened');
  }

  query(sql) { return this.#conn.query(sql); }

  [Symbol.dispose]() {
    this.#conn.close();
    console.log('Connection closed');
  }
}

// Automatic cleanup — connection closed even if function throws
function doWork() {
  using conn = new DatabaseConnection(DB_URL);
  const result = conn.query('SELECT * FROM users');
  return result; // conn[Symbol.dispose]() called here automatically
}

// await using — for async cleanup
class FileHandle {
  static async open(path) {
    const handle = new FileHandle();
    handle.#fd = await fs.open(path, 'r');
    return handle;
  }

  async read() { return this.#fd.readFile(); }

  async [Symbol.asyncDispose]() {
    await this.#fd.close();
  }
}

async function readFile(path) {
  await using handle = await FileHandle.open(path);
  return handle.read(); // handle[Symbol.asyncDispose]() called automatically
}

// DisposableStack — manage multiple resources
function processFiles(paths) {
  using stack = new DisposableStack();
  const handles = paths.map(p => stack.use(openFile(p)));
  // All handles disposed when stack goes out of scope
  return handles.map(h => h.read());
}
```

---

## Proxy and Reflect

### Validation Proxy

```javascript
function createValidated(schema) {
  return new Proxy({}, {
    set(target, prop, value) {
      const validator = schema[prop];
      if (validator && !validator(value)) {
        throw new TypeError(`Invalid value for ${String(prop)}: ${value}`);
      }
      return Reflect.set(target, prop, value);
    },
    get(target, prop) {
      return Reflect.get(target, prop);
    },
  });
}

const user = createValidated({
  age: (v) => typeof v === 'number' && v >= 0 && v <= 150,
  email: (v) => typeof v === 'string' && v.includes('@'),
});

user.email = 'alice@example.com'; // OK
user.age = 25;                     // OK
user.age = -1;                     // TypeError: Invalid value for age: -1
```

### Observable Proxy — Reactive Data

```javascript
function observable(target, onChange) {
  return new Proxy(target, {
    set(obj, prop, value) {
      const old = obj[prop];
      const result = Reflect.set(obj, prop, value);
      if (old !== value) {
        onChange(prop, value, old);
      }
      return result;
    },
    deleteProperty(obj, prop) {
      const had = prop in obj;
      const result = Reflect.deleteProperty(obj, prop);
      if (had) {
        onChange(prop, undefined, obj[prop]);
      }
      return result;
    },
  });
}

const state = observable({ count: 0 }, (key, newVal, oldVal) => {
  console.log(`${key}: ${oldVal} → ${newVal}`);
  render();
});

state.count++;  // count: 0 → 1
```

### Deep Proxy — Recursive Observable

```javascript
function deepObservable(target, onChange, path = '') {
  return new Proxy(target, {
    get(obj, prop) {
      const value = Reflect.get(obj, prop);
      if (value && typeof value === 'object') {
        // Wrap nested objects
        return deepObservable(value, onChange, `${path}.${String(prop)}`);
      }
      return value;
    },
    set(obj, prop, value) {
      const fullPath = `${path}.${String(prop)}`;
      const result = Reflect.set(obj, prop, value);
      onChange(fullPath, value);
      return result;
    },
  });
}
```

### Revocable Proxy — Temporary Access

```javascript
const { proxy, revoke } = Proxy.revocable(sensitiveData, {
  get(target, prop) {
    console.log(`Access: ${String(prop)}`);
    return Reflect.get(target, prop);
  },
});

grantAccess(proxy);     // give someone temporary access

setTimeout(() => {
  revoke();             // all future access throws TypeError
}, 60_000);
```

---

## Decorators (Stage 3)

```javascript
// Method decorator — timing/logging
function measure(target, context) {
  return async function(...args) {
    const start = performance.now();
    try {
      return await target.apply(this, args);
    } finally {
      console.log(`${context.name} took ${performance.now() - start}ms`);
    }
  };
}

// Field/accessor decorator — validation
function range(min, max) {
  return function(target, context) {
    return {
      get() { return context.access.get(this); },
      set(value) {
        if (value < min || value > max) {
          throw new RangeError(`${context.name} must be ${min}–${max}`);
        }
        context.access.set(this, value);
      },
    };
  };
}

class UserService {
  @range(1, 150)
  accessor age = 0;

  @measure
  async fetchUser(id) {
    return this.db.query('SELECT * FROM users WHERE id = ?', [id]);
  }
}

// Class decorator — dependency injection / registration
function injectable(target, context) {
  target[Symbol.for('injectable')] = true;
  return target;
}

@injectable
class EmailService {
  send(to, subject, body) { /* ... */ }
}
```

---

## Temporal API (Stage 3)

```javascript
// Modern date/time — replaces the broken Date object
// Available via polyfill: npm install @js-temporal/polyfill

import { Temporal } from '@js-temporal/polyfill';

// Plain date — no timezone
const today = Temporal.PlainDate.from('2024-03-15');
const tomorrow = today.add({ days: 1 });
const nextMonth = today.add({ months: 1 });

today.toString();  // '2024-03-15'

// Zoned date/time — with timezone
const nyNow = Temporal.Now.zonedDateTimeISO('America/New_York');
const tokyoNow = nyNow.withTimeZone('Asia/Tokyo');

// Duration arithmetic
const meeting = Temporal.ZonedDateTime.from({
  year: 2024, month: 3, day: 20,
  hour: 14, minute: 30,
  timeZone: 'America/Chicago',
});

const now = Temporal.Now.zonedDateTimeISO('America/Chicago');
const until = now.until(meeting);
console.log(`Meeting in ${until.hours}h ${until.minutes}m`);

// Comparison
const d1 = Temporal.PlainDate.from('2024-01-01');
const d2 = Temporal.PlainDate.from('2024-06-01');
Temporal.PlainDate.compare(d1, d2); // -1 (d1 < d2)

// Instant — machine time (like Date.now())
const start = Temporal.Now.instant();
await doWork();
const elapsed = Temporal.Now.instant().since(start);
console.log(`Took ${elapsed.milliseconds}ms`);
```

---

## Signals Proposal (Stage 1)

```javascript
// Reactive primitives — the foundation that Vue, Solid, and Preact Signals built on
// This is a native proposal; for now use framework-specific implementations

// Framework-specific examples (same concept, different API):

// Preact Signals
import { signal, computed, effect } from '@preact/signals-core';

const count = signal(0);
const doubled = computed(() => count.value * 2);

effect(() => {
  console.log(`count: ${count.value}, doubled: ${doubled.value}`);
});

count.value = 5; // triggers effect: "count: 5, doubled: 10"

// SolidJS createSignal
import { createSignal, createMemo, createEffect } from 'solid-js';

const [count, setCount] = createSignal(0);
const doubled = createMemo(() => count() * 2);
createEffect(() => console.log(count(), doubled()));
setCount(5);
```

---

## Records and Tuples (Stage 2)

```javascript
// Immutable, value-typed data structures
// Syntax uses # prefix

// Record — immutable plain object
const point = #{ x: 1, y: 2 };
const point2 = #{ x: 1, y: 2 };
point === point2; // true — compared by VALUE, not reference!

// Tuple — immutable array
const coords = #[1, 2, 3];
const coords2 = #[1, 2, 3];
coords === coords2; // true

// Spread works
const point3D = #{ ...point, z: 3 };

// Cannot contain mutable objects
#{ fn: () => {} }; // TypeError — no functions in Records
#{ obj: {} };      // TypeError — no objects in Records
// Can contain: primitives, other Records, other Tuples, Symbols

// Use case: React state comparison, Map keys by value
const map = new Map();
map.set(#{ x: 1, y: 2 }, 'first quadrant');
map.get(#{ x: 1, y: 2 }); // 'first quadrant' — value equality!
```
