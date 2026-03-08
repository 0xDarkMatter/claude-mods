# Rust Async and Tokio Reference

## Table of Contents

1. [tokio Runtime](#1-tokio-runtime)
2. [Spawn Tasks](#2-spawn-tasks)
3. [Select](#3-select)
4. [Channels](#4-channels)
5. [Async Streams](#5-async-streams)
6. [Timeouts and Sleep](#6-timeouts-and-sleep)
7. [Async Traits](#7-async-traits)
8. [Mutex Choice](#8-mutex-choice)
9. [Graceful Shutdown](#9-graceful-shutdown)
10. [Connection Pooling](#10-connection-pooling)
11. [Test Async Code](#11-test-async-code)
12. [Common Async Mistakes](#12-common-async-mistakes)

---

## 1. tokio Runtime

### #[tokio::main]

```rust
// Multi-threaded (default): uses all CPU cores
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    run().await
}

// Single-threaded: useful for tests or embedded contexts
#[tokio::main(flavor = "current_thread")]
async fn main() -> anyhow::Result<()> {
    run().await
}

// With worker count
#[tokio::main(worker_threads = 4)]
async fn main() -> anyhow::Result<()> {
    run().await
}
```

### runtime::Builder

```rust
use tokio::runtime::Builder;

fn main() -> anyhow::Result<()> {
    let rt = Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("my-worker")
        .thread_stack_size(3 * 1024 * 1024)
        .enable_all()                 // enables both io and time drivers
        .build()?;

    rt.block_on(async {
        run().await
    })
}

// current_thread runtime for single-threaded executors
let rt = Builder::new_current_thread()
    .enable_all()
    .build()?;
```

### runtime::Handle

```rust
use tokio::runtime::Handle;

// Obtain a handle from within an async context
let handle = Handle::current();

// Spawn onto the runtime from a sync context
std::thread::spawn(move || {
    handle.spawn(async { do_work().await });
    handle.block_on(async { do_sync_work().await });
});

// try_current(): returns None outside of a runtime
if let Ok(handle) = Handle::try_current() {
    handle.spawn(async { background_task().await });
}
```

---

## 2. Spawn Tasks

### tokio::spawn and JoinHandle

```rust
use tokio::task::JoinHandle;

async fn run() {
    // spawn returns JoinHandle<T>
    let handle: JoinHandle<u32> = tokio::spawn(async {
        compute().await
    });

    // await the result — JoinHandle<T> returns Result<T, JoinError>
    match handle.await {
        Ok(value) => println!("got {value}"),
        Err(e) if e.is_panic() => eprintln!("task panicked"),
        Err(e) => eprintln!("task cancelled: {e}"),
    }
}
```

### JoinSet for Multiple Tasks

```rust
use tokio::task::JoinSet;

async fn fetch_all(urls: Vec<String>) -> Vec<Result<String, reqwest::Error>> {
    let mut set = JoinSet::new();

    for url in urls {
        set.spawn(async move { reqwest::get(&url).await?.text().await });
    }

    let mut results = Vec::new();
    while let Some(res) = set.join_next().await {
        results.push(res.expect("task panicked"));
    }
    results
}

// Abort all remaining tasks when JoinSet drops (or explicitly)
set.abort_all();
```

### abort

```rust
let handle = tokio::spawn(async {
    loop {
        do_work().await;
    }
});

// Cancel the task
handle.abort();

// abort() is best-effort: the task must be at an await point
// Check completion after abort
match handle.await {
    Err(e) if e.is_cancelled() => println!("task was cancelled"),
    _ => {}
}
```

### spawn_blocking for CPU Work

```rust
// Never block the async executor — offload CPU work to a thread pool
async fn hash_password(password: String) -> String {
    tokio::task::spawn_blocking(move || {
        bcrypt::hash(&password, 12).unwrap()
    })
    .await
    .expect("blocking task panicked")
}

// spawn_blocking has a default limit of 512 threads
// For unbounded work, consider a dedicated rayon thread pool
async fn process_image(data: Vec<u8>) -> Vec<u8> {
    tokio::task::spawn_blocking(move || {
        rayon_heavy_transform(data)
    })
    .await
    .unwrap()
}
```

---

## 3. Select

### tokio::select! Basics

```rust
use tokio::select;

async fn race() -> &'static str {
    select! {
        result = task_a() => {
            println!("A won: {result:?}");
            "a"
        }
        result = task_b() => {
            println!("B won: {result:?}");
            "b"
        }
    }
    // Unselected branch future is dropped immediately
}
```

### biased for Deterministic Priority

```rust
select! {
    biased;  // arms checked top-to-bottom, not randomly

    // shutdown takes priority over incoming work
    _ = shutdown_signal() => {
        cleanup().await;
    }
    msg = receiver.recv() => {
        process(msg).await;
    }
}
```

### Cancellation Safety

```rust
// Only use futures that are cancellation-safe in select!
// Safe: recv(), accept(), sleep(), read_line()
// NOT safe: read_to_end(), write_all() (partial progress is lost)

// For non-cancellation-safe futures, pin them and reuse
let mut read_future = Box::pin(file.read_to_end(&mut buf));

loop {
    select! {
        result = &mut read_future => {
            // Only enters here when done, previous progress preserved
            break result;
        }
        _ = shutdown.recv() => {
            break Err(io::Error::new(io::ErrorKind::Interrupted, "shutdown"));
        }
    }
}
```

### loop + select Pattern

```rust
async fn event_loop(
    mut rx: mpsc::Receiver<Message>,
    mut shutdown: broadcast::Receiver<()>,
) {
    loop {
        select! {
            Some(msg) = rx.recv() => {
                handle_message(msg).await;
            }
            _ = shutdown.recv() => {
                tracing::info!("shutting down event loop");
                break;
            }
            else => {
                // All branches are disabled (channels closed)
                break;
            }
        }
    }
}
```

---

## 4. Channels

### mpsc — Multi-Producer, Single-Consumer

```rust
use tokio::sync::mpsc;

// Bounded channel (backpressure built-in)
let (tx, mut rx) = mpsc::channel::<String>(32);

// Clone the sender for multiple producers
let tx2 = tx.clone();

tokio::spawn(async move {
    tx.send("hello".to_string()).await.unwrap();
});
tokio::spawn(async move {
    tx2.send("world".to_string()).await.unwrap();
});

while let Some(msg) = rx.recv().await {
    println!("received: {msg}");
}
// recv() returns None when all senders are dropped

// Unbounded channel (no backpressure — use carefully)
let (tx, mut rx) = mpsc::unbounded_channel::<String>();
tx.send("hello".to_string()).unwrap();  // non-async send
```

### oneshot — Single Value

```rust
use tokio::sync::oneshot;

// One sender, one receiver, one value
let (tx, rx) = oneshot::channel::<u64>();

tokio::spawn(async move {
    let result = compute().await;
    tx.send(result).ok();  // ok() because receiver might have dropped
});

match rx.await {
    Ok(value) => println!("computed: {value}"),
    Err(_) => println!("sender dropped before sending"),
}

// Common pattern: request-response over a channel
struct Request {
    data: Vec<u8>,
    reply: oneshot::Sender<Result<Vec<u8>, Error>>,
}
```

### broadcast — Single-Producer, Multi-Consumer

```rust
use tokio::sync::broadcast;

// All active receivers get every message
let (tx, mut rx1) = broadcast::channel::<String>(16);
let mut rx2 = tx.subscribe();

tx.send("announcement".to_string()).unwrap();

// Each receiver gets its own copy
let msg1 = rx1.recv().await.unwrap();
let msg2 = rx2.recv().await.unwrap();

// Lagged receiver: if receiver falls behind capacity, it gets Err(Lagged(n))
match rx1.recv().await {
    Ok(msg) => handle(msg),
    Err(broadcast::error::RecvError::Lagged(n)) => {
        tracing::warn!("missed {n} messages, resyncing");
    }
    Err(broadcast::error::RecvError::Closed) => break,
}
```

### watch — Single Writer, Multi-Reader (Latest Value)

```rust
use tokio::sync::watch;

// Only the most recent value is retained
let (tx, rx) = watch::channel(Config::default());

// Writer updates the shared value
tokio::spawn(async move {
    loop {
        let new_config = reload_config().await;
        tx.send(new_config).unwrap();
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
});

// Readers clone a receiver and watch for changes
tokio::spawn(async move {
    let mut rx = rx;
    loop {
        rx.changed().await.unwrap();  // waits for a new value
        let config = rx.borrow_and_update().clone();
        apply_config(config).await;
    }
});
```

---

## 5. Async Streams

### Stream Trait and StreamExt

```rust
use futures::StreamExt;  // or tokio_stream::StreamExt

// Streams are async iterators
async fn process_stream<S>(mut stream: S)
where
    S: futures::Stream<Item = Event> + Unpin,
{
    while let Some(event) = stream.next().await {
        handle(event).await;
    }

    // StreamExt combinators
    stream.map(|e| transform(e))
          .filter(|e| futures::future::ready(e.important))
          .take(100)
          .for_each(|e| async move { handle(e).await })
          .await;
}
```

### tokio_stream

```rust
use tokio_stream::{self as stream, StreamExt};

// Stream from iterator
let s = stream::iter(vec![1, 2, 3]);

// Stream with delay between items
let s = stream::iter(vec![1, 2, 3])
    .throttle(Duration::from_millis(100));

// Merge streams
let s = stream::select(stream_a, stream_b);

// Wrap a channel receiver as a stream
let stream = tokio_stream::wrappers::ReceiverStream::new(rx);
let stream = tokio_stream::wrappers::BroadcastStream::new(rx);
let stream = tokio_stream::wrappers::WatchStream::new(rx);
```

### Create Streams with async_stream

```rust
use async_stream::stream;

fn paginate(client: Client, query: Query) -> impl futures::Stream<Item = Record> {
    stream! {
        let mut cursor = None;
        loop {
            let page = client.fetch(query.clone(), cursor).await.unwrap();
            for record in page.records {
                yield record;
            }
            match page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
    }
}
```

---

## 6. Timeouts and Sleep

### tokio::time::sleep

```rust
use tokio::time::{sleep, Duration};

// Non-blocking sleep
sleep(Duration::from_secs(1)).await;

// Sleep until a specific instant
use tokio::time::Instant;
sleep(Instant::now() + Duration::from_millis(500) - Instant::now()).await;
```

### timeout

```rust
use tokio::time::timeout;

match timeout(Duration::from_secs(5), fetch_data()).await {
    Ok(Ok(data)) => process(data),
    Ok(Err(e)) => handle_error(e),
    Err(_elapsed) => eprintln!("request timed out"),
}

// timeout returns Err(Elapsed) on timeout
// The inner future is cancelled when timeout fires
```

### interval

```rust
use tokio::time::{interval, MissedTickBehavior};

async fn heartbeat() {
    let mut ticker = interval(Duration::from_secs(10));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        ticker.tick().await;
        send_heartbeat().await;
    }
}

// MissedTickBehavior options:
// Burst (default): catch up all missed ticks immediately
// Skip: skip missed ticks, tick at next aligned interval
// Delay: delay next tick by full interval from now
```

### Instant

```rust
use tokio::time::Instant;

let start = Instant::now();
do_work().await;
let elapsed = start.elapsed();
tracing::info!(?elapsed, "work completed");
```

---

## 7. Async Traits

### RPITIT (Rust 1.75+, Preferred)

```rust
// Async functions in traits work natively since Rust 1.75
pub trait DataStore {
    async fn get(&self, key: &str) -> Option<String>;
    async fn set(&self, key: &str, value: String) -> Result<(), Error>;
}

impl DataStore for RedisStore {
    async fn get(&self, key: &str) -> Option<String> {
        self.client.get(key).await.ok()
    }

    async fn set(&self, key: &str, value: String) -> Result<(), Error> {
        self.client.set(key, value).await?;
        Ok(())
    }
}
```

### trait_variant for dyn Compatibility

```rust
// Native async traits are not dyn-safe by default
// Use trait_variant for trait objects
use trait_variant::make;

#[make(SendDataStore: Send)]
pub trait DataStore {
    async fn get(&self, key: &str) -> Option<String>;
}

// Now use dyn SendDataStore for boxed trait objects
fn make_store() -> Box<dyn SendDataStore> {
    Box::new(RedisStore::new())
}
```

### async-trait Crate (Pre-1.75 or dyn-safe)

```rust
use async_trait::async_trait;

#[async_trait]
pub trait Handler: Send + Sync {
    async fn handle(&self, req: Request) -> Response;
}

#[async_trait]
impl Handler for MyHandler {
    async fn handle(&self, req: Request) -> Response {
        process(req).await
    }
}

// async_trait boxes the returned future automatically
// Zero-cost in practice but adds a heap allocation per call
```

### Manual Approach (Maximum Control)

```rust
use std::future::Future;
use std::pin::Pin;

pub trait Handler: Send + Sync {
    fn handle<'a>(
        &'a self,
        req: Request,
    ) -> Pin<Box<dyn Future<Output = Response> + Send + 'a>>;
}

impl Handler for MyHandler {
    fn handle<'a>(&'a self, req: Request) -> Pin<Box<dyn Future<Output = Response> + Send + 'a>> {
        Box::pin(async move { process(&self.state, req).await })
    }
}
```

---

## 8. Mutex Choice

### tokio::sync::Mutex vs std::sync::Mutex

```rust
// Use std::sync::Mutex when:
// - Lock is held only for synchronous operations (no .await inside lock)
// - Lock contention is low
// - You want lower overhead

use std::sync::Mutex;

struct Cache {
    inner: Mutex<HashMap<String, String>>,
}

impl Cache {
    fn get(&self, key: &str) -> Option<String> {
        self.inner.lock().unwrap().get(key).cloned()
    }

    async fn get_or_fetch(&self, key: &str) -> String {
        if let Some(v) = self.get(key) {
            return v;
        }
        let value = fetch(key).await;  // lock NOT held during await
        self.inner.lock().unwrap().insert(key.to_string(), value.clone());
        value
    }
}
```

```rust
// Use tokio::sync::Mutex when:
// - You need to hold the lock across .await points
// - Multiple async tasks contend and fairness matters

use tokio::sync::Mutex;

struct Connection {
    inner: Mutex<TcpStream>,
}

impl Connection {
    async fn send_and_receive(&self, data: &[u8]) -> Vec<u8> {
        let mut conn = self.inner.lock().await;  // lock held across awaits
        conn.write_all(data).await.unwrap();
        let mut buf = vec![0u8; 1024];
        conn.read(&mut buf).await.unwrap();
        buf
    }
}
```

### RwLock

```rust
use tokio::sync::RwLock;

struct Config {
    data: RwLock<ConfigData>,
}

impl Config {
    async fn get(&self) -> ConfigData {
        self.data.read().await.clone()  // multiple concurrent readers
    }

    async fn update(&self, new: ConfigData) {
        *self.data.write().await = new;  // exclusive writer
    }
}

// RwLock can starve writers if readers are constant — monitor in practice
```

---

## 9. Graceful Shutdown

### Signal Handling

```rust
use tokio::signal;

async fn wait_for_shutdown() {
    let ctrl_c = async {
        signal::ctrl_c().await.expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let sigterm = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let sigterm = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = sigterm => {},
    }
    tracing::info!("shutdown signal received");
}
```

### CancellationToken

```rust
use tokio_util::sync::CancellationToken;

#[tokio::main]
async fn main() {
    let token = CancellationToken::new();

    // Give child tasks a clone
    let worker_token = token.child_token();
    tokio::spawn(async move {
        select! {
            _ = worker_token.cancelled() => {
                tracing::info!("worker shutting down");
            }
            _ = do_work() => {}
        }
    });

    // Trigger shutdown on signal
    wait_for_shutdown().await;
    token.cancel();

    // Give tasks time to drain
    tokio::time::sleep(Duration::from_secs(5)).await;
}
```

### Draining Connections and Shutdown Sequence

```rust
async fn shutdown(
    server: Server,
    mut rx: mpsc::Receiver<()>,
    token: CancellationToken,
) {
    // 1. Stop accepting new connections
    server.stop_accepting();

    // 2. Signal all workers
    token.cancel();

    // 3. Wait for in-flight requests (with timeout)
    let drain = timeout(Duration::from_secs(30), server.drain());
    match drain.await {
        Ok(_) => tracing::info!("clean shutdown"),
        Err(_) => tracing::warn!("shutdown timeout: forcing exit"),
    }

    // 4. Flush telemetry, close DB pools, etc.
    flush_telemetry().await;
}
```

---

## 10. Connection Pooling

### sqlx Pool

```rust
use sqlx::postgres::PgPoolOptions;

let pool = PgPoolOptions::new()
    .max_connections(20)
    .min_connections(2)
    .acquire_timeout(Duration::from_secs(5))
    .idle_timeout(Duration::from_secs(600))
    .connect("postgres://user:pass@localhost/db")
    .await?;

// Clone the pool cheaply — it's Arc internally
async fn get_user(pool: &sqlx::PgPool, id: i64) -> sqlx::Result<User> {
    sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
        .fetch_one(pool)
        .await
}
```

### reqwest Client Reuse

```rust
use reqwest::Client;

// Build once, clone cheaply (Arc internally)
let client = Client::builder()
    .timeout(Duration::from_secs(30))
    .pool_max_idle_per_host(10)
    .connection_verbose(false)
    .build()?;

// Share via state, not by creating new clients per request
#[derive(Clone)]
struct AppState {
    http: Client,
    db: sqlx::PgPool,
}
```

### bb8 Generic Pool

```rust
use bb8::Pool;
use bb8_redis::RedisConnectionManager;

let manager = RedisConnectionManager::new("redis://localhost")?;
let pool = Pool::builder()
    .max_size(15)
    .min_idle(Some(2))
    .connection_timeout(Duration::from_secs(3))
    .build(manager)
    .await?;

let mut conn = pool.get().await?;
redis::cmd("SET").arg("key").arg("value").query_async(&mut *conn).await?;
```

---

## 11. Test Async Code

### #[tokio::test]

```rust
#[tokio::test]
async fn test_fetch_user() {
    let db = setup_test_db().await;
    let user = db.get_user(1).await.unwrap();
    assert_eq!(user.name, "Alice");
}

// Multi-thread flavor for concurrency tests
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_concurrent_writes() {
    let state = Arc::new(SharedState::new());
    let handles: Vec<_> = (0..10)
        .map(|i| {
            let s = state.clone();
            tokio::spawn(async move { s.write(i).await })
        })
        .collect();
    futures::future::join_all(handles).await;
    assert_eq!(state.count().await, 10);
}
```

### Mock Time with tokio::time::pause

```rust
#[tokio::test]
async fn test_timeout_behavior() {
    tokio::time::pause();  // freeze time

    let result = tokio::spawn(async {
        timeout(Duration::from_secs(5), slow_operation()).await
    });

    // Advance time without actually waiting
    tokio::time::advance(Duration::from_secs(6)).await;

    let outcome = result.await.unwrap();
    assert!(outcome.is_err(), "should have timed out");
}
```

### Testing Channels

```rust
#[tokio::test]
async fn test_message_processing() {
    let (tx, rx) = mpsc::channel(8);
    let processor = Processor::new(rx);

    let handle = tokio::spawn(processor.run());

    tx.send(Message::Ping).await.unwrap();
    tx.send(Message::Stop).await.unwrap();
    drop(tx);

    handle.await.unwrap();
}

// Test that a task completes within expected time
#[tokio::test]
async fn test_completes_quickly() {
    let result = timeout(Duration::from_millis(100), fast_task()).await;
    assert!(result.is_ok(), "task took too long");
}
```

---

## 12. Common Async Mistakes

### Block in Async Context

```rust
// BAD: blocks the executor thread, starves other tasks
async fn hash(password: &str) -> String {
    bcrypt::hash(password, 12).unwrap()  // CPU-intensive, blocks
}

// GOOD: offload to blocking thread pool
async fn hash(password: String) -> String {
    tokio::task::spawn_blocking(move || {
        bcrypt::hash(&password, 12).unwrap()
    })
    .await
    .unwrap()
}

// BAD: blocking sleep
async fn wait() {
    std::thread::sleep(Duration::from_secs(1));  // blocks executor
}

// GOOD:
async fn wait() {
    tokio::time::sleep(Duration::from_secs(1)).await;
}
```

### Hold std::Mutex Across .await

```rust
// BAD: MutexGuard (which is not Send) held across await point
// This will fail to compile if the future must be Send
async fn bad_update(state: Arc<Mutex<State>>) {
    let mut guard = state.lock().unwrap();
    guard.count += 1;
    do_async_work().await;  // guard still held — not Send!
    guard.finalize();
}

// GOOD: release lock before await
async fn good_update(state: Arc<Mutex<State>>) {
    {
        let mut guard = state.lock().unwrap();
        guard.count += 1;
    }  // guard dropped here
    do_async_work().await;
    {
        let mut guard = state.lock().unwrap();
        guard.finalize();
    }
}

// ALTERNATIVE: use tokio::sync::Mutex if you need to hold across awaits
```

### Missing Send Bounds

```rust
// Task spawned with tokio::spawn must be Send + 'static
// This fails if you capture non-Send types (like Rc, RefCell)
let rc = Rc::new(5);
tokio::spawn(async move {
    println!("{}", rc);  // ERROR: Rc is not Send
});

// GOOD: use Arc instead of Rc
let arc = Arc::new(5);
tokio::spawn(async move {
    println!("{}", arc);  // OK
});
```

### Forget to Drive Futures

```rust
// BAD: creating a future without awaiting it — nothing happens
async fn fire_and_maybe_forget() {
    let future = send_email("user@example.com");  // not awaited, not spawned
    // future is dropped, email never sent
}

// GOOD: either await or spawn
async fn fire_and_actually_do_it() {
    // Option 1: await (sequential)
    send_email("user@example.com").await.unwrap();

    // Option 2: spawn (concurrent, detached)
    tokio::spawn(async { send_email("user@example.com").await.ok() });
}
```

### Unbounded Spawning

```rust
// BAD: spawning one task per item with no limit — OOM on large input
async fn process_all(items: Vec<Item>) {
    for item in items {
        tokio::spawn(async move { process(item).await });
    }
}

// GOOD: use JoinSet with capacity limit or a semaphore
use tokio::sync::Semaphore;

async fn process_all(items: Vec<Item>) {
    let sem = Arc::new(Semaphore::new(50));  // max 50 concurrent tasks
    let mut set = JoinSet::new();

    for item in items {
        let permit = sem.clone().acquire_owned().await.unwrap();
        set.spawn(async move {
            let _permit = permit;  // released when task ends
            process(item).await
        });
    }

    while set.join_next().await.is_some() {}
}
```
