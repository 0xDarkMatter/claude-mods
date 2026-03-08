# Rust Ecosystem Reference

## Table of Contents

1. [serde Advanced](#1-serde-advanced)
2. [clap](#2-clap)
3. [reqwest](#3-reqwest)
4. [sqlx](#4-sqlx)
5. [axum](#5-axum)
6. [tracing](#6-tracing)
7. [rayon](#7-rayon)
8. [itertools](#8-itertools)
9. [Cow](#9-cow)

---

## 1. serde Advanced

### Use Custom Serialization with `serialize_with` / `deserialize_with`

```rust
use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};

#[derive(Serialize, Deserialize)]
pub struct Event {
    pub name: String,
    #[serde(with = "chrono::serde::ts_seconds")]
    pub occurred_at: DateTime<Utc>,
    #[serde(
        serialize_with = "serialize_uppercase",
        deserialize_with = "deserialize_uppercase"
    )]
    pub code: String,
}

fn serialize_uppercase<S>(value: &str, s: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    s.serialize_str(&value.to_uppercase())
}

fn deserialize_uppercase<'de, D>(d: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = String::deserialize(d)?;
    Ok(raw.to_uppercase())
}
```

### Use `#[serde(with)]` for Custom Module

```rust
mod as_base64 {
    use base64::{engine::general_purpose, Engine};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        s.serialize_str(&general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D>(d: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(d)?;
        general_purpose::STANDARD
            .decode(&s)
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Serialize, Deserialize)]
pub struct Secret {
    #[serde(with = "as_base64")]
    pub key: Vec<u8>,
}
```

### Flatten Nested Structs

```rust
#[derive(Serialize, Deserialize)]
pub struct Metadata {
    pub created_by: String,
    pub version: u32,
}

#[derive(Serialize, Deserialize)]
pub struct Record {
    pub id: u64,
    pub name: String,
    #[serde(flatten)]
    pub meta: Metadata,
    // Serializes as: { "id": 1, "name": "...", "created_by": "...", "version": 1 }
}

// Capture unknown fields
#[derive(Serialize, Deserialize)]
pub struct Flexible {
    pub known: String,
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}
```

### Tag Enums (Internal, External, Adjacent, Untagged)

```rust
// External (default): { "TypeName": { ...fields } }
#[derive(Serialize, Deserialize)]
pub enum External {
    Text { content: String },
    Number { value: i64 },
}

// Internal: { "type": "Text", "content": "..." }
#[derive(Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Internal {
    Text { content: String },
    Number { value: i64 },
}

// Adjacent: { "type": "Text", "data": { "content": "..." } }
#[derive(Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum Adjacent {
    Text { content: String },
    Number { value: i64 },
}

// Untagged: tries each variant until one succeeds
#[derive(Serialize, Deserialize)]
#[serde(untagged)]
pub enum Untagged {
    Text { content: String },
    Number { value: i64 },
    Raw(String),
}
```

### Reject Unknown Fields

```rust
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StrictConfig {
    pub host: String,
    pub port: u16,
    // Any unknown key in JSON causes deserialization to fail
}
```

### Use `#[serde(remote)]` for External Types

```rust
// For types you don't own, create a remote definition
#[derive(Serialize, Deserialize)]
#[serde(remote = "std::time::Duration")]
struct DurationDef {
    secs: u64,
    nanos: u32,
}

#[derive(Serialize, Deserialize)]
pub struct Config {
    #[serde(with = "DurationDef")]
    pub timeout: std::time::Duration,
}
```

---

## 2. clap

### Define CLI with Derive API

```rust
use clap::{Args, Parser, Subcommand, ValueEnum};

#[derive(Parser)]
#[command(name = "mytool", version, about = "A tool that does things")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,

    /// Increase verbosity (-v, -vv, -vvv)
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    pub verbose: u8,

    /// Config file path
    #[arg(long, env = "MYTOOL_CONFIG", default_value = "config.toml", global = true)]
    pub config: std::path::PathBuf,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Fetch data from the server
    Fetch(FetchArgs),
    /// Push data to the server
    Push(PushArgs),
}

#[derive(Args)]
pub struct FetchArgs {
    /// Target URL
    #[arg(value_parser = parse_url)]
    pub url: url::Url,

    /// Output format
    #[arg(long, value_enum, default_value_t = OutputFormat::Json)]
    pub format: OutputFormat,

    /// Optional tags (can be repeated)
    #[arg(long = "tag", short = 't')]
    pub tags: Vec<String>,

    /// Dry run mode
    #[arg(long, conflicts_with = "output")]
    pub dry_run: bool,

    /// Write output to file
    #[arg(long)]
    pub output: Option<std::path::PathBuf>,
}

#[derive(ValueEnum, Clone)]
pub enum OutputFormat {
    Json,
    Csv,
    Pretty,
}

fn parse_url(s: &str) -> Result<url::Url, String> {
    url::Url::parse(s).map_err(|e| e.to_string())
}
```

### Parse and Dispatch

```rust
fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Fetch(args) => run_fetch(args, cli.verbose),
        Commands::Push(args) => run_push(args, cli.verbose),
    }
}
```

### Generate Shell Completions

```rust
use clap::CommandFactory;
use clap_complete::{generate, Shell};

fn print_completions(shell: Shell) {
    let mut cmd = Cli::command();
    generate(shell, &mut cmd, "mytool", &mut std::io::stdout());
}
```

---

## 3. reqwest

### Build a Shared Client

```rust
use reqwest::{Client, ClientBuilder, header};
use std::time::Duration;

fn build_client(base_token: &str) -> reqwest::Result<Client> {
    let mut headers = header::HeaderMap::new();
    let auth = header::HeaderValue::from_str(&format!("Bearer {}", base_token))
        .expect("Invalid token");
    headers.insert(header::AUTHORIZATION, auth);

    ClientBuilder::new()
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(5))
        .default_headers(headers)
        .user_agent("myapp/1.0")
        .build()
}
```

### Send GET / POST / PUT Requests

```rust
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct ApiResponse { data: Vec<Item> }

#[derive(Serialize)]
struct CreateRequest { name: String, value: u32 }

async fn fetch_items(client: &Client, url: &str) -> anyhow::Result<Vec<Item>> {
    let resp = client
        .get(url)
        .query(&[("limit", "100"), ("page", "1")])
        .send()
        .await?
        .error_for_status()?
        .json::<ApiResponse>()
        .await?;

    Ok(resp.data)
}

async fn create_item(client: &Client, url: &str, name: &str) -> anyhow::Result<Item> {
    let body = CreateRequest { name: name.to_string(), value: 42 };

    client
        .post(url)
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json::<Item>()
        .await
        .map_err(Into::into)
}
```

### Upload Multipart Form

```rust
use reqwest::multipart;

async fn upload_file(client: &Client, url: &str, path: &std::path::Path) -> anyhow::Result<()> {
    let file_bytes = tokio::fs::read(path).await?;
    let filename = path.file_name().unwrap().to_string_lossy().into_owned();

    let part = multipart::Part::bytes(file_bytes)
        .file_name(filename)
        .mime_str("application/octet-stream")?;

    let form = multipart::Form::new()
        .text("description", "my upload")
        .part("file", part);

    client.post(url).multipart(form).send().await?.error_for_status()?;
    Ok(())
}
```

### Stream a Response

```rust
use futures_util::StreamExt;

async fn stream_download(client: &Client, url: &str) -> anyhow::Result<Vec<u8>> {
    let mut stream = client.get(url).send().await?.bytes_stream();
    let mut buf = Vec::new();

    while let Some(chunk) = stream.next().await {
        buf.extend_from_slice(&chunk?);
    }

    Ok(buf)
}
```

### Retry with Exponential Backoff

```rust
use std::time::Duration;

async fn get_with_retry(client: &Client, url: &str, max: usize) -> anyhow::Result<String> {
    let mut delay = Duration::from_millis(200);

    for attempt in 0..max {
        match client.get(url).send().await?.error_for_status() {
            Ok(resp) => return Ok(resp.text().await?),
            Err(e) if attempt + 1 < max => {
                tokio::time::sleep(delay).await;
                delay *= 2;
                tracing::warn!(attempt, %e, "Retrying request");
            }
            Err(e) => return Err(e.into()),
        }
    }

    unreachable!()
}
```

---

## 4. sqlx

### Set Up a Connection Pool

```toml
# Cargo.toml
sqlx = { version = "0.7", features = ["postgres", "runtime-tokio-rustls", "macros", "chrono", "uuid"] }
```

```rust
use sqlx::PgPool;

pub async fn connect(database_url: &str) -> sqlx::Result<PgPool> {
    PgPool::connect(database_url).await
}

// Or with options
use sqlx::postgres::PgPoolOptions;

pub async fn connect_pool(database_url: &str) -> sqlx::Result<PgPool> {
    PgPoolOptions::new()
        .max_connections(20)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(database_url)
        .await
}
```

### Write Compile-Time Checked Queries

```rust
// DATABASE_URL must be set at compile time
// sqlx::query! checks SQL against live schema

pub async fn get_user(pool: &PgPool, id: i64) -> sqlx::Result<Option<User>> {
    sqlx::query_as!(
        User,
        r#"SELECT id, name, email, created_at FROM users WHERE id = $1"#,
        id
    )
    .fetch_optional(pool)
    .await
}

pub async fn list_users(pool: &PgPool, limit: i64) -> sqlx::Result<Vec<User>> {
    sqlx::query_as!(
        User,
        r#"SELECT id, name, email, created_at FROM users ORDER BY id LIMIT $1"#,
        limit
    )
    .fetch_all(pool)
    .await
}
```

### Derive `FromRow`

```rust
use sqlx::FromRow;
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, FromRow)]
pub struct User {
    pub id: i64,
    pub name: String,
    pub email: String,
    pub created_at: DateTime<Utc>,
}

// Override column name
#[derive(Debug, FromRow)]
pub struct Post {
    pub id: Uuid,
    #[sqlx(rename = "body_text")]
    pub body: String,
    // Skip a column that won't be in every query
    #[sqlx(skip)]
    pub computed: Option<String>,
}
```

### Use Transactions

```rust
pub async fn transfer_funds(
    pool: &PgPool,
    from: i64,
    to: i64,
    amount: i64,
) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;

    sqlx::query!("UPDATE accounts SET balance = balance - $1 WHERE id = $2", amount, from)
        .execute(&mut *tx)
        .await?;

    sqlx::query!("UPDATE accounts SET balance = balance + $1 WHERE id = $2", amount, to)
        .execute(&mut *tx)
        .await?;

    tx.commit().await
}
```

### Map JSON Columns

```rust
use serde::{Deserialize, Serialize};
use sqlx::types::Json;

#[derive(Debug, Serialize, Deserialize)]
pub struct Settings {
    pub theme: String,
    pub notifications: bool,
}

#[derive(Debug, FromRow)]
pub struct UserWithSettings {
    pub id: i64,
    pub name: String,
    pub settings: Json<Settings>,  // maps JSON column to typed struct
}

pub async fn get_settings(pool: &PgPool, id: i64) -> sqlx::Result<Settings> {
    let row = sqlx::query_as!(
        UserWithSettings,
        r#"SELECT id, name, settings AS "settings: Json<Settings>" FROM users WHERE id = $1"#,
        id
    )
    .fetch_one(pool)
    .await?;

    Ok(row.settings.0)
}
```

### Run Migrations

```rust
// Migrations live in ./migrations/*.sql, named 0001_create_users.sql etc.
pub async fn run_migrations(pool: &PgPool) -> sqlx::Result<()> {
    sqlx::migrate!("./migrations").run(pool).await
}
```

---

## 5. axum

### Define a Router with State

```rust
use axum::{Router, routing::{get, post}};
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::PgPool,
    pub config: Arc<Config>,
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health_handler))
        .route("/users", get(list_users).post(create_user))
        .route("/users/:id", get(get_user).delete(delete_user))
        .nest("/admin", admin_routes())
        .layer(tower_http::trace::TraceLayer::new_for_http())
        .with_state(state)
}
```

### Write Handlers with Extractors

```rust
use axum::{
    extract::{Path, Query, State, Json},
    http::StatusCode,
    response::IntoResponse,
};
use serde::Deserialize;

#[derive(Deserialize)]
pub struct Pagination {
    pub page: Option<u32>,
    pub limit: Option<u32>,
}

pub async fn list_users(
    State(state): State<AppState>,
    Query(params): Query<Pagination>,
) -> impl IntoResponse {
    let limit = params.limit.unwrap_or(20).min(100);
    let page = params.page.unwrap_or(0);

    match fetch_users(&state.pool, limit as i64, page as i64).await {
        Ok(users) => Json(users).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

#[derive(Deserialize)]
pub struct CreateUserRequest {
    pub name: String,
    pub email: String,
}

pub async fn create_user(
    State(state): State<AppState>,
    Json(body): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<User>), AppError> {
    let user = insert_user(&state.pool, &body.name, &body.email).await?;
    Ok((StatusCode::CREATED, Json(user)))
}
```

### Define a Typed Error Response

```rust
use axum::{http::StatusCode, response::{IntoResponse, Response}, Json};
use serde_json::json;

pub enum AppError {
    NotFound(String),
    Database(sqlx::Error),
    Validation(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            AppError::Validation(msg) => (StatusCode::UNPROCESSABLE_ENTITY, msg),
            AppError::Database(e) => {
                tracing::error!("Database error: {}", e);
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal error".to_string())
            }
        };

        (status, Json(json!({ "error": message }))).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        AppError::Database(e)
    }
}
```

### Handle WebSocket Connections

```rust
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};

pub async fn ws_handler(ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(handle_socket)
}

async fn handle_socket(mut socket: WebSocket) {
    while let Some(msg) = socket.recv().await {
        match msg {
            Ok(Message::Text(text)) => {
                if socket.send(Message::Text(format!("echo: {text}"))).await.is_err() {
                    break;
                }
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {}
        }
    }
}
```

### Gracefully Shut Down the Server

```rust
use tokio::net::TcpListener;

pub async fn serve(router: Router) -> anyhow::Result<()> {
    let listener = TcpListener::bind("0.0.0.0:3000").await?;

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c().await.expect("Failed to install Ctrl+C handler");
    tracing::info!("Shutdown signal received");
}
```

---

## 6. tracing

### Set Up a Subscriber

```rust
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init_tracing() {
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(tracing_subscriber::fmt::layer().with_target(true))
        .init();
}

// For JSON output (structured logging in prod)
pub fn init_json_tracing() {
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(tracing_subscriber::fmt::layer().json())
        .init();
}
```

### Instrument Functions

```rust
use tracing::{instrument, info, warn, error, debug, Span};

#[instrument(skip(pool), fields(user_id = %id))]
pub async fn get_user_profile(pool: &PgPool, id: i64) -> anyhow::Result<Profile> {
    debug!("Fetching user profile");

    let profile = sqlx::query_as!(Profile, "SELECT * FROM profiles WHERE user_id = $1", id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| anyhow::anyhow!("Profile not found"))?;

    info!(email = %profile.email, "Profile fetched");
    Ok(profile)
}
```

### Create and Enter Spans Manually

```rust
use tracing::{info_span, Instrument};

pub async fn process_batch(items: Vec<Item>) {
    for item in items {
        let span = info_span!("process_item", item_id = %item.id, kind = %item.kind);

        async move {
            tracing::info!("Processing item");
            // work...
            tracing::info!("Item done");
        }
        .instrument(span)
        .await;
    }
}
```

### Add Structured Fields to Events

```rust
use tracing::info;

pub fn log_request(method: &str, path: &str, status: u16, latency_ms: u64) {
    info!(
        http.method = method,
        http.path = path,
        http.status = status,
        latency_ms = latency_ms,
        "Request completed"
    );
}
```

### Filter by Directive

```
# Environment variable examples
RUST_LOG=info
RUST_LOG=myapp=debug,sqlx=warn,tower_http=info
RUST_LOG=debug,hyper=off
```

---

## 7. rayon

### Parallelize with `par_iter`

```rust
use rayon::prelude::*;

fn sum_squares(numbers: &[f64]) -> f64 {
    numbers.par_iter().map(|x| x * x).sum()
}

fn find_primes(limit: u64) -> Vec<u64> {
    (2..limit)
        .into_par_iter()
        .filter(|&n| is_prime(n))
        .collect()
}

fn transform_records(records: Vec<Record>) -> Vec<Output> {
    records.into_par_iter().map(process_record).collect()
}
```

### Build a Custom Thread Pool

```rust
use rayon::ThreadPoolBuilder;

fn main() {
    let pool = ThreadPoolBuilder::new()
        .num_threads(4)
        .thread_name(|i| format!("worker-{}", i))
        .build()
        .unwrap();

    pool.install(|| {
        (0..1000).into_par_iter().for_each(|i| {
            println!("Processing {}", i);
        });
    });
}
```

### Bridge Sequential Iterators

```rust
use rayon::iter::ParallelBridge;

fn process_lines(reader: impl std::io::BufRead + Send) -> Vec<String> {
    reader
        .lines()
        .par_bridge()           // converts Iterator -> ParallelIterator
        .filter_map(|l| l.ok())
        .map(|l| l.trim().to_string())
        .collect()
}
```

### Know When to Choose rayon vs tokio

| Situation | Use |
|-----------|-----|
| CPU-bound work (parsing, compression, crypto) | `rayon` |
| I/O-bound work (network, disk, database) | `tokio` |
| Mix: CPU work inside async | `tokio::task::spawn_blocking` with rayon inside |
| Parallel collection transforms | `rayon` |
| Concurrent HTTP requests | `tokio` + `FuturesUnordered` |

```rust
// Offload rayon work from async context
pub async fn heavy_computation(data: Vec<u8>) -> Vec<u8> {
    tokio::task::spawn_blocking(move || {
        data.par_iter().map(|b| b.wrapping_add(1)).collect()
    })
    .await
    .expect("blocking task panicked")
}
```

---

## 8. itertools

```toml
itertools = "0.12"
```

### Use Useful Combinators

```rust
use itertools::Itertools;

fn demonstrate_itertools() {
    let nums = vec![1, 2, 3, 4, 5, 6];

    // chunks - fixed-size non-overlapping groups
    for chunk in &nums.iter().chunks(2) {
        let v: Vec<_> = chunk.collect();
        println!("{:?}", v);  // [1,2], [3,4], [5,6]
    }

    // tuple_windows - sliding window of tuples
    let pairs: Vec<_> = nums.iter().tuple_windows::<(_, _)>().collect();
    // [(1,2), (2,3), (3,4), (4,5), (5,6)]

    // group_by - consecutive runs (like Unix uniq)
    let words = vec!["a", "a", "b", "b", "b", "c"];
    for (key, group) in &words.iter().group_by(|w| *w) {
        println!("{}: {}", key, group.count());
    }

    // join - format with separator (no trailing sep)
    let s = ["foo", "bar", "baz"].iter().join(", ");
    // "foo, bar, baz"

    // sorted_by - sort without mutating
    let sorted = nums.iter().sorted_by(|a, b| b.cmp(a)).collect_vec();

    // dedup - remove consecutive duplicates
    let deduped: Vec<_> = vec![1, 1, 2, 3, 3, 3, 4].into_iter().dedup().collect();
    // [1, 2, 3, 4]

    // interleave - alternating elements
    let a = vec![1, 3, 5];
    let b = vec![2, 4, 6];
    let merged: Vec<_> = a.into_iter().interleave(b.into_iter()).collect();
    // [1, 2, 3, 4, 5, 6]

    // unique - deduplicate (not just consecutive)
    let unique: Vec<_> = vec![1, 2, 1, 3, 2, 4].into_iter().unique().collect();
    // [1, 2, 3, 4]

    // combinations and permutations
    let combos: Vec<_> = (0..4).combinations(2).collect();
    // [[0,1],[0,2],[0,3],[1,2],[1,3],[2,3]]

    // partition_map - split into two collections
    let (evens, odds): (Vec<_>, Vec<_>) =
        nums.iter().partition_map(|&n| {
            if n % 2 == 0 { itertools::Either::Left(n) } else { itertools::Either::Right(n) }
        });
}
```

---

## 9. Cow

### Understand Clone-on-Write

`Cow<'a, B>` is either `Borrowed(&'a B)` or `Owned(B::Owned)`. Derefs to `&B` in both cases. Allocates only when you need to mutate.

### Use Cow in Function Signatures

```rust
use std::borrow::Cow;

// Accepts both &str and String, returns without allocating if no change needed
fn normalize(input: &str) -> Cow<str> {
    if input.chars().all(|c| c.is_lowercase()) {
        Cow::Borrowed(input)        // zero allocation
    } else {
        Cow::Owned(input.to_lowercase())  // allocates only when needed
    }
}

// Accept Cow to handle both owned and borrowed callers
fn process(name: Cow<str>) {
    println!("Processing: {}", name);
}

// Call sites
process(Cow::Borrowed("hello"));
process(Cow::Owned(String::from("world")));
process(normalize("Mixed"));
```

### Enable Zero-Copy Parsing

```rust
use serde::Deserialize;

// serde can borrow from input bytes when possible
#[derive(Deserialize)]
pub struct Request<'a> {
    #[serde(borrow)]
    pub method: Cow<'a, str>,  // borrows from JSON bytes if no escaping needed
    pub id: u64,
}
```

### Build Efficient Builders with Cow

```rust
use std::borrow::Cow;

pub struct Query<'a> {
    table: Cow<'a, str>,
    conditions: Vec<Cow<'a, str>>,
}

impl<'a> Query<'a> {
    pub fn from_table(table: impl Into<Cow<'a, str>>) -> Self {
        Query { table: table.into(), conditions: vec![] }
    }

    pub fn where_clause(mut self, cond: impl Into<Cow<'a, str>>) -> Self {
        self.conditions.push(cond.into());
        self
    }

    pub fn build(&self) -> String {
        if self.conditions.is_empty() {
            format!("SELECT * FROM {}", self.table)
        } else {
            format!("SELECT * FROM {} WHERE {}", self.table, self.conditions.iter().join(" AND "))
        }
    }
}
```
