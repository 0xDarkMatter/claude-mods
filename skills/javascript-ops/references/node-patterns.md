# Node.js Patterns Reference

Production-ready Node.js patterns — testing, file system, workers, streams, crypto, and operational concerns.

---

## Built-In Test Runner (node:test)

Available from Node 18 (experimental) and Node 20+ (stable).

### Basic Structure

```javascript
// test/user.test.mjs
import { describe, it, before, after, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createUser, getUser, deleteUser } from '../src/user.js';

describe('User module', () => {
  let userId;

  before(async () => {
    // Setup — runs once before all tests in this describe block
    await db.connect();
  });

  after(async () => {
    // Teardown — runs once after all tests
    await db.disconnect();
  });

  beforeEach(async () => {
    // Runs before each test
    const user = await createUser({ name: 'Alice', email: 'alice@example.com' });
    userId = user.id;
  });

  afterEach(async () => {
    // Runs after each test
    await deleteUser(userId).catch(() => {}); // ignore if already deleted
  });

  it('creates a user', async () => {
    const user = await getUser(userId);
    assert.equal(user.name, 'Alice');
    assert.equal(user.email, 'alice@example.com');
    assert.ok(user.id, 'should have an id');
  });

  it('throws on missing user', async () => {
    await assert.rejects(
      () => getUser('nonexistent-id'),
      { name: 'NotFoundError' }
    );
  });
});
```

### Running Tests

```bash
# Run all test files
node --test

# Specific files or glob
node --test test/**/*.test.mjs

# Watch mode (re-runs on file change)
node --test --watch

# With coverage (experimental)
node --test --experimental-test-coverage

# Filter by test name
node --test --test-name-pattern="User module"

# Concurrency (default: os.availableParallelism() - 1)
node --test --test-concurrency=4

# Reporter (spec, tap, dot, junit)
node --test --test-reporter=spec
node --test --test-reporter=junit --test-reporter-destination=results.xml
```

### Mocking

```javascript
import { describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';

// Mock a function
const fn = mock.fn((x) => x * 2);
fn(5);
fn(10);

assert.equal(fn.mock.calls.length, 2);
assert.deepEqual(fn.mock.calls[0].arguments, [5]);
assert.equal(fn.mock.calls[0].result, 10);

// Reset mock state
fn.mock.resetCalls();

// Restore mocked methods
fn.mock.restore();
```

```javascript
// Mock module methods
import { describe, it, mock, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';

describe('config loader', () => {
  afterEach(() => mock.restoreAll()); // important — restore after each test

  it('loads config from file', async () => {
    // Replace fs.readFile with a mock
    mock.method(fs, 'readFile', async () => '{"port": 3000}');

    const config = await loadConfig('./config.json');
    assert.equal(config.port, 3000);
  });

  it('uses default when file missing', async () => {
    mock.method(fs, 'readFile', async () => {
      throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
    });

    const config = await loadConfig('./config.json');
    assert.deepEqual(config, { port: 8080 }); // default
  });
});
```

### Timer Mocking

```javascript
import { describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';

describe('debounce', () => {
  it('delays execution', async () => {
    // Take control of timers
    mock.timers.enable(['setTimeout', 'setInterval']);

    const fn = mock.fn();
    const debounced = debounce(fn, 1000);

    debounced();
    debounced();
    debounced();

    assert.equal(fn.mock.calls.length, 0); // not called yet

    // Advance time by 1000ms
    mock.timers.tick(1000);

    assert.equal(fn.mock.calls.length, 1); // called once (debounced)

    mock.timers.reset();
  });
});
```

### Snapshot Testing

```javascript
import { describe, it } from 'node:test';

describe('serializer', () => {
  it('formats output correctly', (t) => {
    const output = serialize({ name: 'Alice', scores: [1, 2, 3] });
    t.assert.snapshot(output);
    // First run: creates .snap file
    // Subsequent runs: compares against snapshot
  });
});

// Update snapshots:
// node --test --test-update-snapshots
```

---

## File System — fs/promises

### Common Operations

```javascript
import {
  readFile, writeFile, appendFile,
  readdir, mkdir, rm, rename, copyFile,
  stat, access, watch,
  open, // FileHandle for streaming
} from 'node:fs/promises';
import { constants } from 'node:fs';

// Read file
const content = await readFile('./config.json', 'utf8');
const data = JSON.parse(content);

// Write file (creates or overwrites)
await writeFile('./output.json', JSON.stringify(data, null, 2), 'utf8');

// Append
await appendFile('./log.txt', `${new Date().toISOString()} — event\n`);

// Check if file exists
try {
  await access('./config.json', constants.F_OK);
  console.log('File exists');
} catch {
  console.log('File does not exist');
}

// Stat — file metadata
const stats = await stat('./config.json');
stats.isFile();       // true
stats.isDirectory();  // false
stats.size;           // bytes
stats.mtime;          // last modified Date

// Read directory
const entries = await readdir('./src', { withFileTypes: true });
const dirs = entries.filter(e => e.isDirectory()).map(e => e.name);
const files = entries.filter(e => e.isFile()).map(e => e.name);

// Recursive readdir (Node 18.17+)
const allFiles = await readdir('./src', { recursive: true });

// Create directory (recursive creates intermediate dirs)
await mkdir('./dist/assets/images', { recursive: true });

// Delete — rm replaces deprecated rmdir
await rm('./dist', { recursive: true, force: true }); // rm -rf

// Rename / move
await rename('./old-name.js', './new-name.js');

// Copy
await copyFile('./src/file.js', './dist/file.js');
```

### Glob (Node 22+)

```javascript
// Native glob — no glob package needed in Node 22+
import { glob } from 'node:fs/promises';

const tsFiles = await Array.fromAsync(glob('**/*.ts', { cwd: './src' }));
const testFiles = await Array.fromAsync(glob('**/*.test.{js,mjs,ts}'));
```

### File Watching

```javascript
// Watch a file or directory for changes
const watcher = watch('./src', { recursive: true });

for await (const event of watcher) {
  console.log(event.eventType, event.filename);
  // event.eventType: 'rename' | 'change'
  // event.filename: relative path from watch target
}

// Stop watching
watcher.close();
// OR: use AbortSignal
const ac = new AbortController();
const watcher2 = watch('./config.json', { signal: ac.signal });
for await (const event of watcher2) {
  if (shouldStop) ac.abort();
  await reloadConfig();
}
```

### Streaming File Operations

```javascript
import { open } from 'node:fs/promises';

// FileHandle for large files — streaming read
async function processLargeFile(path) {
  const handle = await open(path, 'r');
  try {
    const stream = handle.createReadStream({ encoding: 'utf8' });
    for await (const chunk of stream) {
      await processChunk(chunk);
    }
  } finally {
    await handle.close(); // always close
  }
}

// With 'using' (Node 22+ / ES2025)
async function processWithUsing(path) {
  await using handle = await open(path, 'r'); // auto-closes
  for await (const chunk of handle.createReadStream()) {
    await processChunk(chunk);
  }
}
```

---

## Worker Threads

```javascript
// worker_threads — true parallelism, shared memory
import { Worker, isMainThread, parentPort, workerData,
         receiveMessageOnPort, MessageChannel } from 'node:worker_threads';
import { cpus } from 'node:os';
```

### Main Thread

```javascript
// main.mjs
import { Worker } from 'node:worker_threads';

function runWorker(data) {
  return new Promise((resolve, reject) => {
    const worker = new Worker('./worker.mjs', { workerData: data });

    worker.on('message', resolve);
    worker.on('error', reject);
    worker.on('exit', (code) => {
      if (code !== 0) reject(new Error(`Worker exited with code ${code}`));
    });
  });
}

// Parallel CPU work across all cores
const cpuCount = cpus().length;
const chunks = splitData(data, cpuCount);
const results = await Promise.all(chunks.map(chunk => runWorker(chunk)));
const final = mergeResults(results);
```

### Worker Thread

```javascript
// worker.mjs
import { parentPort, workerData } from 'node:worker_threads';

// workerData is a deep clone of what was passed to Worker constructor
const result = heavyComputation(workerData);

// Send result back to main thread
parentPort.postMessage(result);
```

### Thread Pool Pattern

```javascript
// Reusable worker pool — avoid create/destroy overhead
class WorkerPool {
  #workers = [];
  #queue = [];
  #size;

  constructor(workerPath, size = cpus().length) {
    this.#size = size;
    this.#workers = Array.from({ length: size }, () => ({
      worker: new Worker(workerPath),
      busy: false,
    }));

    for (const entry of this.#workers) {
      entry.worker.on('message', (result) => {
        entry.busy = false;
        entry.resolve(result);
        this.#processQueue();
      });
    }
  }

  run(data) {
    return new Promise((resolve, reject) => {
      this.#queue.push({ data, resolve, reject });
      this.#processQueue();
    });
  }

  #processQueue() {
    if (!this.#queue.length) return;
    const idle = this.#workers.find(w => !w.busy);
    if (!idle) return;

    const { data, resolve, reject } = this.#queue.shift();
    idle.busy = true;
    idle.resolve = resolve;
    idle.reject = reject;
    idle.worker.postMessage(data);
  }

  async terminate() {
    await Promise.all(this.#workers.map(({ worker }) => worker.terminate()));
  }
}

const pool = new WorkerPool('./image-processor.mjs', 4);
const thumbnails = await Promise.all(
  images.map(img => pool.run({ image: img, width: 200 }))
);
await pool.terminate();
```

### SharedArrayBuffer in Node.js

```javascript
// main.mjs
import { Worker } from 'node:worker_threads';

const shared = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT * 1024);
const counter = new Int32Array(shared);

const workers = Array.from({ length: 4 }, () =>
  new Worker('./counter-worker.mjs', {
    workerData: { shared }, // no transfer needed — it's shared
  })
);

await Promise.all(workers.map(w => new Promise(r => w.on('exit', r))));
console.log('Final count:', Atomics.load(counter, 0));
```

```javascript
// counter-worker.mjs
import { workerData } from 'node:worker_threads';

const counter = new Int32Array(workerData.shared);
for (let i = 0; i < 10_000; i++) {
  Atomics.add(counter, 0, 1); // atomic — no race condition
}
```

---

## Cluster Module

```javascript
import cluster from 'node:cluster';
import { cpus } from 'node:os';
import { createServer } from 'node:http';

if (cluster.isPrimary) {
  // Fork one worker per CPU
  const numCPUs = cpus().length;
  for (let i = 0; i < numCPUs; i++) {
    cluster.fork();
  }

  cluster.on('exit', (worker, code, signal) => {
    console.log(`Worker ${worker.process.pid} died (${signal || code})`);
    cluster.fork(); // auto-restart
  });

  // Graceful restart — zero-downtime deploy
  process.on('SIGUSR2', () => {
    const workers = Object.values(cluster.workers);
    let i = 0;
    function restartNext() {
      if (i >= workers.length) return;
      const worker = workers[i++];
      worker.once('exit', () => {
        cluster.fork().once('listening', restartNext);
      });
      worker.kill('SIGTERM');
    }
    restartNext();
  });
} else {
  // Worker process
  createServer((req, res) => {
    res.writeHead(200);
    res.end(`Worker ${process.pid}: hello\n`);
  }).listen(3000);

  // Graceful shutdown signal from primary
  process.on('SIGTERM', () => {
    server.close(() => process.exit(0));
  });
}
```

---

## Streams

### node:stream with pipeline()

```javascript
import { pipeline, Transform, Readable, Writable } from 'node:stream';
import { promisify } from 'node:util';
import { createReadStream, createWriteStream } from 'node:fs';
import { createGzip, createGunzip } from 'node:zlib';

const pipelineAsync = promisify(pipeline);
// OR: import { pipeline } from 'node:stream/promises';

// Compress a file
await pipelineAsync(
  createReadStream('./large-file.txt'),
  createGzip(),
  createWriteStream('./large-file.txt.gz'),
);

// Custom Transform stream
class CSVParser extends Transform {
  #buffer = '';
  #headers = null;

  constructor() {
    super({ readableObjectMode: true }); // output objects
  }

  _transform(chunk, encoding, callback) {
    this.#buffer += chunk.toString();
    const lines = this.#buffer.split('\n');
    this.#buffer = lines.pop(); // keep incomplete last line

    for (const line of lines) {
      if (!this.#headers) {
        this.#headers = line.split(',').map(h => h.trim());
      } else {
        const values = line.split(',');
        const record = Object.fromEntries(
          this.#headers.map((h, i) => [h, values[i]?.trim()])
        );
        this.push(record);
      }
    }
    callback();
  }

  _flush(callback) {
    if (this.#buffer.trim() && this.#headers) {
      const values = this.#buffer.split(',');
      this.push(Object.fromEntries(
        this.#headers.map((h, i) => [h, values[i]?.trim()])
      ));
    }
    callback();
  }
}

// Process a large CSV without loading it all into memory
await pipeline(
  createReadStream('./data.csv'),
  new CSVParser(),
  new Writable({
    objectMode: true,
    async write(record, encoding, callback) {
      try {
        await db.insert('records', record);
        callback();
      } catch (err) {
        callback(err);
      }
    },
  }),
);
```

### Web Streams Interop (Node 18+)

```javascript
import { Readable } from 'node:stream';

// Convert Node stream to Web ReadableStream
const nodeReadable = createReadStream('./file.txt');
const webStream = Readable.toWeb(nodeReadable);

// Convert Web ReadableStream to Node stream
const nodeFromWeb = Readable.fromWeb(webStream);

// Use web streams with fetch response body
const response = await fetch('https://api.example.com/large');
for await (const chunk of response.body) { // response.body is ReadableStream
  await processChunk(chunk);
}
```

---

## HTTP

### node:http Server

```javascript
import { createServer } from 'node:http';

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime: process.uptime() }));
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/data') {
    // Read request body
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString());

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ received: body }));
    return;
  }

  res.writeHead(404);
  res.end('Not found');
});

server.listen(3000, () => console.log('Server on :3000'));
```

### undici — Modern HTTP Client (Node built-in)

```javascript
// undici is bundled with Node 18+ — faster than node-fetch
import { fetch, request, stream, pipeline } from 'undici';

// Standard fetch (same as global fetch in Node 18+)
const res = await fetch('https://api.example.com/users');
const users = await res.json();

// Low-level request with connection pooling
const { statusCode, headers, body } = await request('https://api.example.com/data', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ key: 'value' }),
});
const data = await body.json();

// Stream response directly to file
import { createWriteStream } from 'node:fs';
await stream('https://example.com/large-file.zip',
  { method: 'GET' },
  () => createWriteStream('./download.zip')
);
```

---

## Crypto

```javascript
import {
  randomUUID, randomBytes, randomInt,
  createHash, createHmac,
  createCipheriv, createDecipheriv,
  scrypt, scryptSync,
  timingSafeEqual,
  generateKeyPair, createSign, createVerify,
} from 'node:crypto';
import { promisify } from 'node:util';

const scryptAsync = promisify(scrypt);

// Unique IDs
const id = randomUUID(); // cryptographically random UUID v4
const token = randomBytes(32).toString('hex'); // 64-char hex token
const otp = randomInt(100_000, 999_999); // 6-digit OTP

// Hashing
const hash = createHash('sha256').update('content').digest('hex');

// HMAC
const hmac = createHmac('sha256', 'secret-key').update('message').digest('hex');

// Password hashing with scrypt
async function hashPassword(password) {
  const salt = randomBytes(16);
  const hash = await scryptAsync(password, salt, 64);
  return `${salt.toString('hex')}:${hash.toString('hex')}`;
}

async function verifyPassword(password, stored) {
  const [saltHex, hashHex] = stored.split(':');
  const salt = Buffer.from(saltHex, 'hex');
  const hash = await scryptAsync(password, salt, 64);
  // timingSafeEqual prevents timing attacks
  return timingSafeEqual(hash, Buffer.from(hashHex, 'hex'));
}

// AES-256-GCM encryption
function encrypt(plaintext, keyHex) {
  const key = Buffer.from(keyHex, 'hex'); // 32 bytes for AES-256
  const iv = randomBytes(16);
  const cipher = createCipheriv('aes-256-gcm', key, iv);

  const encrypted = Buffer.concat([
    cipher.update(plaintext, 'utf8'),
    cipher.final(),
  ]);
  const authTag = cipher.getAuthTag();

  return {
    iv: iv.toString('hex'),
    encrypted: encrypted.toString('hex'),
    authTag: authTag.toString('hex'),
  };
}

function decrypt({ iv, encrypted, authTag }, keyHex) {
  const key = Buffer.from(keyHex, 'hex');
  const decipher = createDecipheriv(
    'aes-256-gcm',
    key,
    Buffer.from(iv, 'hex')
  );
  decipher.setAuthTag(Buffer.from(authTag, 'hex'));

  return Buffer.concat([
    decipher.update(Buffer.from(encrypted, 'hex')),
    decipher.final(),
  ]).toString('utf8');
}

// RSA signing
const { privateKey, publicKey } = await promisify(generateKeyPair)('rsa', {
  modulusLength: 2048,
});

const sign = createSign('SHA256');
sign.update('message to sign');
const signature = sign.sign(privateKey, 'hex');

const verify = createVerify('SHA256');
verify.update('message to sign');
const isValid = verify.verify(publicKey, signature, 'hex');
```

---

## Diagnostics and Observability

### diagnostics_channel

```javascript
import diagnostics from 'node:diagnostics_channel';

// Publisher — library code
const ch = diagnostics.channel('mylib:db:query');

async function query(sql, params) {
  if (ch.hasSubscribers) {
    ch.publish({ sql, params, start: performance.now() });
  }
  const result = await db.execute(sql, params);
  if (ch.hasSubscribers) {
    ch.publish({ sql, params, duration: performance.now() - start, rows: result.rowCount });
  }
  return result;
}

// Subscriber — monitoring/APM code
diagnostics.channel('mylib:db:query').subscribe((data) => {
  metrics.histogram('db.query.duration', data.duration, { sql: data.sql });
});

// Subscribe to undici (built-in HTTP client) events
diagnostics.channel('undici:request:create').subscribe((data) => {
  console.log('HTTP request:', data.request.method, data.request.origin + data.request.path);
});
```

### Performance Hooks

```javascript
import { performance, PerformanceObserver } from 'node:perf_hooks';

// Mark + measure
performance.mark('start');
await doWork();
performance.mark('end');
performance.measure('doWork', 'start', 'end');

const entries = performance.getEntriesByName('doWork');
console.log(`Duration: ${entries[0].duration}ms`);

// Observe all measures
const obs = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log(`${entry.name}: ${entry.duration.toFixed(2)}ms`);
  }
});
obs.observe({ entryTypes: ['measure'] });

// timerify — auto-measure function calls
function myFunction() { /* ... */ }
const timerified = performance.timerify(myFunction);
obs.observe({ entryTypes: ['function'] });
timerified(); // automatically measured
```

---

## Custom ESM Loaders

```javascript
// register-hooks.mjs — entry point
import { register } from 'node:module';
register('./typescript-loader.mjs', import.meta.url);
```

```javascript
// typescript-loader.mjs
import { transform } from 'esbuild';

export async function load(url, context, nextLoad) {
  if (url.endsWith('.ts') || url.endsWith('.tsx')) {
    const { source } = await nextLoad(url, { ...context, format: 'module' });
    const { code } = await transform(source.toString(), {
      loader: url.endsWith('.tsx') ? 'tsx' : 'ts',
      format: 'esm',
      target: 'node18',
    });
    return { format: 'module', shortCircuit: true, source: code };
  }
  return nextLoad(url, context);
}
```

```bash
# Use the loader
node --import ./register-hooks.mjs ./src/main.ts
```

---

## Permission Model (Node 22+)

```javascript
// Experimental permission model — opt-in security sandboxing
// Deny all by default, explicitly allow what you need
```

```bash
# Allow reading only from specific directories
node --experimental-permission \
     --allow-fs-read=/app/config \
     --allow-fs-write=/app/logs \
     --allow-net=api.example.com:443 \
     --allow-child-process \
     server.mjs

# Check permissions at runtime
process.permission.has('fs.read', '/app/config/db.json'); // true
process.permission.has('fs.write', '/etc/passwd');         // false

# Deny all network access
node --experimental-permission --allow-fs-read=. --allow-fs-write=./dist bundler.mjs
```

---

## Package Management Patterns

### npm workspaces

```json
// Root package.json
{
  "name": "my-monorepo",
  "private": true,
  "workspaces": ["packages/*", "apps/*"]
}
```

```bash
# Install deps for all packages
npm install

# Run script in specific package
npm run build --workspace=packages/my-lib

# Run script in all packages
npm run test --workspaces

# Add dep to a specific workspace
npm install zod --workspace=packages/my-lib
```

### corepack — Package Manager Version Pinning

```bash
# Enable corepack (built into Node 16.9+)
corepack enable

# Use specific pnpm version
corepack use pnpm@9.0.0
# Adds "packageManager": "pnpm@9.0.0" to package.json

# Corepack downloads and uses exact version — no global installs
```

### package.json Best Practices

```json
{
  "name": "my-package",
  "version": "1.0.0",
  "engines": {
    "node": ">=18.17.0",
    "npm": ">=9.0.0"
  },
  "packageManager": "pnpm@9.0.0",
  "overrides": {
    "vulnerable-package": ">=2.1.0"
  }
}
```

---

## Graceful Shutdown

```javascript
// server.mjs — production-ready graceful shutdown
import { createServer } from 'node:http';

const server = createServer(handler);
server.listen(3000);

// Track active connections for graceful drain
let isShuttingDown = false;
const connections = new Set();

server.on('connection', (socket) => {
  connections.add(socket);
  socket.on('close', () => connections.delete(socket));
});

async function shutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;

  console.log(`Received ${signal}. Starting graceful shutdown...`);

  // Stop accepting new connections
  server.close();

  // Set response header to signal clients to disconnect
  // (Connection: close is set automatically during close())

  // Wait for in-flight requests (max 30s)
  const forceShutdown = setTimeout(() => {
    console.error('Forcing shutdown after timeout');
    for (const socket of connections) socket.destroy();
    process.exit(1);
  }, 30_000);

  // Wait for all connections to close naturally
  await new Promise(resolve => server.on('close', resolve));
  clearTimeout(forceShutdown);

  // Cleanup other resources
  await db.end();
  await redis.quit();

  console.log('Graceful shutdown complete');
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// Unhandled errors — always exit
process.on('unhandledRejection', (reason) => {
  console.error('Unhandled rejection:', reason);
  process.exit(1);
});
process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err);
  process.exit(1);
});
```

### .env File Loading (Node 21+)

```bash
# No dotenv package needed
node --env-file=.env server.mjs
node --env-file=.env --env-file=.env.local server.mjs  # multiple files, later wins
```

```javascript
// Validate required env vars at startup
const required = ['DATABASE_URL', 'API_KEY', 'JWT_SECRET'];
const missing = required.filter(key => !process.env[key]);
if (missing.length) {
  throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
}
```

### Health Check Endpoint

```javascript
// Standard health check pattern for load balancers
import { createServer } from 'node:http';

const healthServer = createServer(async (req, res) => {
  if (req.url !== '/health') {
    res.writeHead(404);
    res.end();
    return;
  }

  try {
    // Check dependencies
    await Promise.all([
      db.query('SELECT 1'),
      redis.ping(),
    ]);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'healthy',
      uptime: process.uptime(),
      memory: process.memoryUsage(),
      version: process.env.npm_package_version,
    }));
  } catch (err) {
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'unhealthy', error: err.message }));
  }
});

// Bind to different port from main app (accessible internally, not publicly)
healthServer.listen(3001);
```
