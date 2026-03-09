# Modules & Runtime Reference

ESM, CommonJS, dual packages, V8 internals, memory management, and the Node.js event loop in depth.

---

## ESM — ES Modules

### import / export Syntax

```javascript
// Named exports
export function add(a, b) { return a + b; }
export const PI = 3.14159;
export class Vector { /* ... */ }

// Default export — one per module
export default class App { /* ... */ }

// Re-export from another module
export { add, PI } from './math.js';
export * from './utils.js';                   // re-export all named
export * as utils from './utils.js';          // re-export as namespace
export { default as BaseApp } from './base.js'; // re-export default as named

// Named import
import { add, PI } from './math.js';

// Default import
import App from './app.js';

// Both default and named
import App, { version, config } from './app.js';

// Namespace import
import * as MathUtils from './math.js';
MathUtils.add(1, 2);

// Rename on import
import { add as sum, PI as pi } from './math.js';
```

### import.meta

```javascript
// import.meta is available in ESM only

// URL of current module (always available)
console.log(import.meta.url); // file:///path/to/module.mjs

// Derive __dirname equivalent (Node 21.2+ has import.meta.dirname)
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Node 21.2+ — built-in equivalents
// import.meta.filename → /path/to/module.mjs
// import.meta.dirname  → /path/to/

// Resolve relative paths to absolute
const configPath = import.meta.resolve('./config.json');
// Returns: file:///path/to/config.json

// Environment (Vite, Webpack inject these)
if (import.meta.env?.DEV) { /* development-only */ }
if (import.meta.hot) { /* HMR support */ }
```

---

## Dynamic import()

```javascript
// Lazy loading — import() returns a Promise<Module>
const { default: Chart } = await import('./chart.js');

// Conditional platform code
const platform = process.platform === 'win32'
  ? await import('./windows.js')
  : await import('./unix.js');

// Code splitting (works in bundlers and browsers)
async function loadHeavyFeature() {
  const { HeavyComponent } = await import('./heavy-component.js');
  return new HeavyComponent();
}

// Dynamic path (bundlers may warn — prefer static strings)
const locale = 'en-US';
const { messages } = await import(`./locales/${locale}.js`);

// Import attributes (ES2024)
const config = await import('./config.json', { with: { type: 'json' } });
const styles = await import('./theme.css', { with: { type: 'css' } });

// import() in CJS modules — interop with ESM
// In a .cjs file, you can use dynamic import() to load ESM:
async function loadESMModule() {
  const esm = await import('./esm-only.mjs');
  return esm;
}
```

---

## CommonJS (CJS)

### require / module.exports

```javascript
// Synchronous — entire file executes before require() returns
const path = require('node:path');
const { readFileSync } = require('node:fs');

// module.exports — single export value
module.exports = function add(a, b) { return a + b; };

// Attach multiple exports to exports object
exports.add = (a, b) => a + b;
exports.PI = 3.14159;
// Note: never replace exports itself — use module.exports

// __dirname / __filename — built-in in CJS
console.log(__dirname);  // /path/to/current/directory
console.log(__filename); // /path/to/current/file.js

// require.resolve — get full path without loading
const configPath = require.resolve('./config');

// require.cache — access loaded module cache
delete require.cache[require.resolve('./module')]; // force re-load

// Conditional require for optional dependencies
let chalk;
try {
  chalk = require('chalk');
} catch {
  chalk = { red: s => s, green: s => s }; // fallback
}
```

### CJS ↔ ESM Interop

```javascript
// From CJS: load ESM with dynamic import (async!)
// require() cannot load ES modules directly
const esmModule = await import('./esm-module.mjs');

// From ESM: load CJS with static import (works!)
import cjsModule from './commonjs-module.cjs';
// Named exports from CJS — only default is guaranteed
// Some bundlers analyze CJS for named exports (Vite, Rollup)

// util.promisify — convert CJS callbacks to Promises
import { promisify } from 'node:util';
import { readFile } from 'node:fs';
const readFileAsync = promisify(readFile);
const content = await readFileAsync('./file.txt', 'utf8');
```

---

## Dual Packages — Publish ESM + CJS

### package.json "exports" Field

```json
{
  "name": "my-library",
  "version": "1.0.0",
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "exports": {
    ".": {
      "import": {
        "types": "./dist/index.d.mts",
        "default": "./dist/index.mjs"
      },
      "require": {
        "types": "./dist/index.d.cts",
        "default": "./dist/index.cjs"
      }
    },
    "./utils": {
      "import": "./dist/utils.mjs",
      "require": "./dist/utils.cjs"
    },
    "./package.json": "./package.json"
  },
  "files": ["dist"]
}
```

### Conditional Exports — Environment-Specific

```json
{
  "exports": {
    ".": {
      "browser": "./dist/browser.mjs",
      "worker": "./dist/worker.mjs",
      "node": {
        "import": "./dist/node.mjs",
        "require": "./dist/node.cjs"
      },
      "default": "./dist/index.mjs"
    }
  }
}
```

### Dual Package Hazard

When both ESM and CJS versions are loaded in the same process, singletons (class instances, global state) can be duplicated. Guard with state stored outside module scope:

```javascript
// Use a package-level state file or Symbol registry to detect duplication
// package: ./src/state.mjs
let instance = null;
export function getInstance() {
  if (!instance) instance = createInstance();
  return instance;
}
```

---

## Tree Shaking

```json
// package.json — mark package as free of side effects
{
  "sideEffects": false
}

// Or list files with side effects
{
  "sideEffects": [
    "*.css",
    "./src/polyfills.js",
    "./src/global-setup.js"
  ]
}
```

```javascript
// Barrel file pitfall — re-exporting everything kills tree shaking
// BAD: src/index.js
export * from './moduleA'; // bundler must include ALL of moduleA
export * from './moduleB';
export * from './moduleC';

// GOOD: import directly from source
import { specificThing } from './lib/moduleA';

// GOOD: barrel with explicit named exports is better
export { ThingA, ThingB } from './moduleA';  // explicit = tree-shakeable

// Side-effect-free module pattern
// Don't do top-level work that modifies globals
// BAD:
Array.prototype.sum = function() { return this.reduce((a, b) => a + b, 0); };

// GOOD:
export function sum(arr) { return arr.reduce((a, b) => a + b, 0); }
```

---

## Bundler Comparison — Module Handling

| Feature | Vite | esbuild | Rollup | Webpack 5 |
|---------|------|---------|--------|-----------|
| Default output | ESM + CJS | ESM/CJS/IIFE | ESM + CJS | CJS/ESM |
| Tree shaking | Yes (Rollup) | Yes | Yes | Yes |
| Code splitting | Yes | Yes | Yes | Yes |
| CJS named imports | Analyzed | Analyzed | Analyzed | Analyzed |
| `sideEffects` respected | Yes | Yes | Yes | Yes |
| Top-level await | Yes | Yes | Yes | Partial |
| Import attributes | Planned | No | Plugin | Loader |
| Speed | Fast (esbuild) | Fastest | Moderate | Slow |

```javascript
// Vite — resolves modules with node resolution + browser overrides
// vite.config.js
export default {
  build: {
    lib: {
      entry: './src/index.ts',
      formats: ['es', 'cjs'],
      fileName: (format) => `my-lib.${format === 'es' ? 'mjs' : 'cjs'}`,
    },
    rollupOptions: {
      external: ['react', 'vue'], // don't bundle peer deps
    },
  },
};
```

---

## V8 Internals — Writing Optimizable Code

### Hidden Classes (Shapes)

```javascript
// V8 creates a "hidden class" (shape) for each object structure
// Objects with the same properties in the same ORDER share a shape

// GOOD — consistent shape
function Point(x, y) {
  this.x = x; // always in this order
  this.y = y;
}
const p1 = new Point(1, 2); // shape: { x, y }
const p2 = new Point(3, 4); // same shape — fast!

// BAD — dynamic property addition changes shape
const obj = {};
obj.x = 1;   // shape 1: { x }
obj.y = 2;   // shape 2: { x, y } — shape transition!

// BAD — adding properties in different orders
function makePoint(x, y, swap) {
  const p = {};
  if (swap) { p.y = y; p.x = x; } // different order!
  else { p.x = x; p.y = y; }
  return p;
}
// p.x may hit a different shape → slower property access
```

### Inline Caches (ICs)

```javascript
// V8 caches property lookup results at each call site
// Monomorphic (1 shape) → fast
// Polymorphic (2-4 shapes) → slower
// Megamorphic (5+ shapes) → very slow, no caching

// GOOD — function always receives same shape
function area(rect) {
  return rect.width * rect.height; // monomorphic — one shape
}
area({ width: 10, height: 20 });
area({ width: 5, height: 15 });

// BAD — function receives many different shapes
function getProperty(obj, key) {
  return obj[key]; // megamorphic — every object is different
}
```

### JIT Compilation — What Deoptimizes

```javascript
// Things that prevent or undo JIT optimization:

// 1. typeof checks can hint at types — use them consistently
// 2. delete operator changes object shape
delete obj.property; // BAD for perf — sets to undefined instead

// 3. arguments object prevents optimization
function sum() {
  let total = 0;
  for (let i = 0; i < arguments.length; i++) total += arguments[i]; // slow
  return total;
}
// GOOD: use rest parameters
function sum(...nums) {
  return nums.reduce((a, b) => a + b, 0);
}

// 4. Changing array element types
const arr = [1, 2, 3];       // SMI (small integer) array — fastest
arr.push(1.5);               // now DOUBLE array — shape changed
arr.push('hello');           // now ELEMENTS array — slowest

// 5. try/catch in hot loops (older V8; mostly fixed in Node 12+)
// Still worth moving try/catch outside tight loops when possible
```

---

## Memory Management

### Garbage Collection — Mark-and-Sweep

```javascript
// V8 uses generational GC:
// Young generation (Scavenger) — short-lived objects, collected frequently, fast
// Old generation (Mark-Sweep-Compact) — survived 2 young GCs, collected less often

// Objects become unreachable when no references point to them
function createLeak() {
  const largeData = new Array(1_000_000).fill(0);
  // If largeData is captured by a closure that outlives this function...
  globalThis.leakedCallback = () => largeData.length; // LEAK!
}

// GOOD: explicitly null out large references
globalThis.leakedCallback = null;
largeData = null;
```

### WeakRef — Weak References

```javascript
// WeakRef allows GC to collect the object even if the ref exists
class ImageCache {
  #cache = new Map();

  set(key, image) {
    this.#cache.set(key, new WeakRef(image));
  }

  get(key) {
    const ref = this.#cache.get(key);
    if (!ref) return null;
    const image = ref.deref(); // returns undefined if GC'd
    if (!image) {
      this.#cache.delete(key); // clean up dead entry
      return null;
    }
    return image;
  }
}
```

### FinalizationRegistry — Cleanup After GC

```javascript
// Runs a callback AFTER an object is garbage collected
const registry = new FinalizationRegistry((heldValue) => {
  console.log(`Object with key ${heldValue} was collected`);
  cleanupResource(heldValue);
});

function createResource(key) {
  const resource = new SomeResource();
  registry.register(resource, key); // register for cleanup notification
  return resource;
}

// Caution: cleanup callback runs in unpredictable timing
// Do NOT use for time-sensitive cleanup — use explicit disposal instead
```

### Common Memory Leaks

```javascript
// 1. Forgotten event listeners
const el = document.querySelector('#button');
el.addEventListener('click', handler); // LEAK if el is removed from DOM

// FIX: remove listener when no longer needed
el.removeEventListener('click', handler);
// OR: use { once: true } for one-time listeners
el.addEventListener('click', handler, { once: true });
// OR: use AbortController to remove multiple listeners at once
const ac = new AbortController();
el.addEventListener('click', handler, { signal: ac.signal });
el.addEventListener('focus', handler2, { signal: ac.signal });
ac.abort(); // removes all listeners at once

// 2. Timers holding references
const data = fetchLargeData();
const timer = setInterval(() => {
  process(data); // data is kept alive by closure
}, 1000);
// FIX:
clearInterval(timer);

// 3. Closures capturing large scope
function setup() {
  const HUGE_ARRAY = new Array(1_000_000);
  return function small() {
    return HUGE_ARRAY.length; // keeps HUGE_ARRAY alive!
  };
}

// FIX: only capture what you need
function setup() {
  const HUGE_ARRAY = new Array(1_000_000);
  const size = HUGE_ARRAY.length; // extract the value
  return function small() {
    return size; // HUGE_ARRAY can now be collected
  };
}

// 4. Detached DOM nodes
let el = document.querySelector('#container');
const cache = new WeakMap(); // WeakMap — keys are weakly held
cache.set(el, { data: 'important' });
el = null; // but if the DOM node is detached and nobody holds it, WeakMap auto-cleans

// 5. Growing arrays/maps without eviction
class EventBus {
  #handlers = new Map(); // grows forever if subscribers never unsubscribe!

  on(event, handler) { /* ... */ }
  off(event, handler) { /* ... */ } // MUST provide this
}
```

---

## Event Loop Deep Dive (Node.js)

### Libuv Phases

```
Each "tick" of the Node.js event loop runs these phases in order:

┌──────────────────────────────────────────────────────┐
│  timers                                              │
│  Executes setTimeout() and setInterval() callbacks  │
│  (after their minimum delay — not exactly)          │
└──────────────────────┬───────────────────────────────┘
                       │ process.nextTick + microtasks drain here
┌──────────────────────▼───────────────────────────────┐
│  pending callbacks                                   │
│  I/O callbacks deferred from previous iteration     │
│  (e.g., TCP errors)                                 │
└──────────────────────┬───────────────────────────────┘
                       │ process.nextTick + microtasks drain here
┌──────────────────────▼───────────────────────────────┐
│  idle, prepare                                       │
│  Internal use only                                  │
└──────────────────────┬───────────────────────────────┘
┌──────────────────────▼───────────────────────────────┐
│  poll                                                │
│  Retrieve new I/O events — execute I/O callbacks    │
│  (will block here if nothing pending)               │
└──────────────────────┬───────────────────────────────┘
                       │ process.nextTick + microtasks drain here
┌──────────────────────▼───────────────────────────────┐
│  check                                               │
│  setImmediate() callbacks execute here              │
└──────────────────────┬───────────────────────────────┘
                       │ process.nextTick + microtasks drain here
┌──────────────────────▼───────────────────────────────┐
│  close callbacks                                     │
│  e.g., socket.on('close', ...) callbacks            │
└──────────────────────────────────────────────────────┘
```

### process.nextTick vs setImmediate vs queueMicrotask

```javascript
console.log('1: sync start');

setTimeout(() => console.log('5: setTimeout'), 0);

setImmediate(() => console.log('6: setImmediate'));

Promise.resolve().then(() => console.log('3: Promise.then (microtask)'));

queueMicrotask(() => console.log('4: queueMicrotask'));

process.nextTick(() => console.log('2: nextTick'));

console.log('1b: sync end');

// Output order:
// 1: sync start
// 1b: sync end
// 2: nextTick           ← nextTick runs before other microtasks
// 3: Promise.then       ← then other microtasks
// 4: queueMicrotask     ← queueMicrotask is a microtask
// 5: setTimeout         ← macrotask (timers phase)
// 6: setImmediate       ← macrotask (check phase)

// NOTE: setTimeout vs setImmediate order is non-deterministic
// UNLESS inside an I/O callback — then setImmediate always comes first
fs.readFile('./file', () => {
  setTimeout(() => console.log('timeout'), 0);
  setImmediate(() => console.log('immediate')); // always first in I/O callback
});
```

### process.nextTick — Use Sparingly

```javascript
// nextTick runs BEFORE I/O, even before Promises
// Recursive nextTick can starve I/O (starvation attack)

// BAD: recursive nextTick starves event loop
function badRecursion() {
  process.nextTick(badRecursion); // I/O NEVER runs!
}

// GOOD for: async-like callback for sync operations
class EventEmitter {
  emit(event, data) {
    // Emit in next tick to allow current stack to finish
    process.nextTick(() => {
      this.handlers.get(event)?.forEach(h => h(data));
    });
  }
}

// PREFER: queueMicrotask (same timing, no nextTick starvation risk)
queueMicrotask(() => doSomething());
```

---

## Import Attributes (ES2024)

```javascript
// Static import with type assertion
import data from './data.json' with { type: 'json' };
import styles from './theme.css' with { type: 'css' };
import wasm from './module.wasm' with { type: 'webassembly' };

// Dynamic import with attributes
const config = await import('./config.json', { with: { type: 'json' } });

// Node.js — JSON modules require import assertion
import pkg from './package.json' with { type: 'json' };
console.log(pkg.version);

// Bundler support:
// Vite: supported for JSON (built-in) and CSS
// esbuild: JSON supported
// Rollup: JSON plugin
// Webpack: asset modules
```
