# Rust Testing Reference

## Table of Contents

1. [Unit Tests](#1-unit-tests)
2. [Integration Tests](#2-integration-tests)
3. [Doc Tests](#3-doc-tests)
4. [Async Tests](#4-async-tests)
5. [mockall](#5-mockall)
6. [Test Fixtures](#6-test-fixtures)
7. [Property-Based Testing](#7-property-based-testing)
8. [Benchmarks](#8-benchmarks)
9. [Snapshot Testing](#9-snapshot-testing)
10. [Test Organization](#10-test-organization)
11. [CI Patterns](#11-ci-patterns)

---

## 1. Unit Tests

### Write Tests in `#[cfg(test)]` Modules

```rust
pub fn divide(a: f64, b: f64) -> Result<f64, String> {
    if b == 0.0 {
        Err("division by zero".to_string())
    } else {
        Ok(a / b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;  // bring parent module into scope

    #[test]
    fn divide_positive_numbers() {
        assert_eq!(divide(10.0, 2.0), Ok(5.0));
    }

    #[test]
    fn divide_returns_error_on_zero() {
        assert!(divide(1.0, 0.0).is_err());
    }

    #[test]
    #[should_panic(expected = "index out of bounds")]
    fn panics_on_bad_index() {
        let v: Vec<i32> = vec![];
        let _ = v[0];
    }

    // Return Result from a test - failure message from the Err variant
    #[test]
    fn parse_valid_input() -> Result<(), String> {
        let n: i32 = "42".parse().map_err(|e: std::num::ParseIntError| e.to_string())?;
        assert_eq!(n, 42);
        Ok(())
    }
}
```

### Use Assert Macros Effectively

```rust
#[cfg(test)]
mod tests {
    #[test]
    fn assert_variants() {
        let x = 5;

        assert!(x > 0);                          // boolean
        assert_eq!(x, 5);                        // equality (implements PartialEq + Debug)
        assert_ne!(x, 99);                       // inequality
        assert_eq!(x, 5, "Expected 5, got {}", x);  // with message

        // Floating point - check within epsilon
        let f = 0.1 + 0.2;
        assert!((f - 0.3).abs() < 1e-10, "float comparison failed: {}", f);
    }
}
```

---

## 2. Integration Tests

### Organize Tests in the `tests/` Directory

```
my_crate/
├── src/
│   └── lib.rs
└── tests/
    ├── common/
    │   └── mod.rs        # shared helpers (not a test file)
    ├── api_test.rs
    └── db_test.rs
```

```rust
// tests/common/mod.rs - shared setup, not discovered as a test binary
pub fn setup_logging() {
    let _ = tracing_subscriber::fmt::try_init();
}

pub fn load_fixture(name: &str) -> serde_json::Value {
    let path = std::path::Path::new("tests/fixtures").join(name);
    let bytes = std::fs::read(path).expect("fixture not found");
    serde_json::from_slice(&bytes).expect("invalid fixture JSON")
}
```

```rust
// tests/api_test.rs - each file becomes a separate test binary
mod common;

use my_crate::ApiClient;

#[test]
fn client_builds_with_defaults() {
    common::setup_logging();
    let client = ApiClient::new("http://localhost");
    assert_eq!(client.base_url(), "http://localhost");
}
```

### Share State Between Integration Test Files

```rust
// tests/common/mod.rs
use std::sync::OnceLock;

static SERVER: OnceLock<TestServer> = OnceLock::new();

pub fn get_server() -> &'static TestServer {
    SERVER.get_or_init(|| TestServer::start())
}
```

---

## 3. Doc Tests

### Write Testable Examples in Documentation

```rust
/// Parses a version string into major, minor, patch components.
///
/// # Examples
///
/// ```
/// use my_crate::parse_version;
///
/// let (major, minor, patch) = parse_version("1.2.3").unwrap();
/// assert_eq!((major, minor, patch), (1, 2, 3));
/// ```
///
/// Returns `None` for invalid input:
///
/// ```
/// use my_crate::parse_version;
/// assert!(parse_version("not_a_version").is_none());
/// ```
pub fn parse_version(s: &str) -> Option<(u32, u32, u32)> {
    // ...
}
```

### Use Hidden Setup Lines

```rust
/// Demonstrates the cache in action.
///
/// ```
/// # use my_crate::Cache;
/// # let mut cache = Cache::new(100);  // hidden: sets up state
/// cache.insert("key", "value");
/// assert_eq!(cache.get("key"), Some("value"));
/// ```
```

### Mark Non-Runnable Examples

```rust
/// Connect to the database.
///
/// ```no_run
/// # use my_crate::connect;
/// // This compiles but does not run (needs a real database)
/// let pool = connect("postgres://localhost/mydb").unwrap();
/// ```
///
/// This example is only shown, not compiled:
///
/// ```ignore
/// // Complex setup omitted
/// some_impossible_setup();
/// ```
///
/// This example should fail to compile:
///
/// ```compile_fail
/// let x: u32 = "not a number";  // type error
/// ```
```

---

## 4. Async Tests

### Test with `#[tokio::test]`

```rust
#[tokio::test]
async fn fetch_returns_data() {
    let client = build_client();
    let result = client.fetch("https://example.com").await;
    assert!(result.is_ok());
}

// Multi-thread runtime (matches production tokio::main)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_requests() {
    let (r1, r2) = tokio::join!(
        do_request("a"),
        do_request("b"),
    );
    assert!(r1.is_ok());
    assert!(r2.is_ok());
}

// Current-thread runtime (deterministic, good for unit tests)
#[tokio::test(flavor = "current_thread")]
async fn sequential_processing() {
    let result = process_sequentially(vec![1, 2, 3]).await;
    assert_eq!(result, vec![2, 4, 6]);
}
```

### Mock Time with `tokio::time::pause`

```rust
use tokio::time::{self, Duration, Instant};

#[tokio::test]
async fn cache_expires_after_ttl() {
    time::pause();  // freeze the clock

    let cache = Cache::with_ttl(Duration::from_secs(60));
    cache.insert("key", "value");

    assert_eq!(cache.get("key"), Some("value"));

    time::advance(Duration::from_secs(61)).await;  // advance clock

    assert_eq!(cache.get("key"), None);  // now expired
}
```

---

## 5. mockall

```toml
mockall = "0.12"
```

### Automock a Trait

```rust
use mockall::automock;

#[automock]
pub trait UserRepository: Send + Sync {
    async fn find_by_id(&self, id: u64) -> Option<User>;
    async fn save(&self, user: &User) -> Result<(), DbError>;
    fn count(&self) -> usize;
}
```

### Configure Expectations in Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use mockall::predicate::*;

    #[tokio::test]
    async fn get_user_returns_user_when_found() {
        let mut mock = MockUserRepository::new();

        mock.expect_find_by_id()
            .with(eq(42u64))                    // match specific argument
            .times(1)                           // must be called exactly once
            .returning(|_| Some(User { id: 42, name: "Alice".to_string() }));

        let service = UserService::new(mock);
        let user = service.get_user(42).await.unwrap();
        assert_eq!(user.name, "Alice");
    }

    #[tokio::test]
    async fn get_user_returns_error_when_not_found() {
        let mut mock = MockUserRepository::new();

        mock.expect_find_by_id()
            .returning(|_| None);  // any argument, always None

        let service = UserService::new(mock);
        let result = service.get_user(99).await;
        assert!(matches!(result, Err(ServiceError::NotFound)));
    }

    #[test]
    fn saves_only_valid_users() {
        let mut mock = MockUserRepository::new();

        mock.expect_save()
            .withf(|user| !user.name.is_empty())  // custom predicate
            .times(1)
            .returning(|_| Ok(()));

        // mock verifies expectations on drop
    }
}
```

### Chain Sequences of Calls

```rust
use mockall::Sequence;

#[test]
fn retries_on_first_failure() {
    let mut mock = MockUserRepository::new();
    let mut seq = Sequence::new();

    mock.expect_count()
        .times(1)
        .in_sequence(&mut seq)
        .returning(|| 0);

    mock.expect_count()
        .times(1)
        .in_sequence(&mut seq)
        .returning(|| 5);

    assert_eq!(mock.count(), 0);
    assert_eq!(mock.count(), 5);
}
```

### Mock Structs (not just traits)

```rust
use mockall::mock;

mock! {
    pub HttpClient {
        pub fn get(&self, url: &str) -> Result<String, reqwest::Error>;
        pub fn post(&self, url: &str, body: &str) -> Result<String, reqwest::Error>;
    }
}
```

---

## 6. Test Fixtures

### Set Up and Tear Down with Drop

```rust
pub struct TestDb {
    pub pool: sqlx::PgPool,
    pub db_name: String,
}

impl TestDb {
    pub async fn new() -> Self {
        let db_name = format!("test_{}", uuid::Uuid::new_v4().simple());
        let admin_pool = sqlx::PgPool::connect("postgres://localhost/postgres").await.unwrap();

        sqlx::query(&format!("CREATE DATABASE {}", db_name))
            .execute(&admin_pool)
            .await
            .unwrap();

        let pool = sqlx::PgPool::connect(&format!("postgres://localhost/{}", db_name))
            .await
            .unwrap();

        sqlx::migrate!("./migrations").run(&pool).await.unwrap();

        TestDb { pool, db_name }
    }
}

impl Drop for TestDb {
    fn drop(&mut self) {
        // Schedule async cleanup - use a blocking approach here
        let db_name = self.db_name.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(async {
                let pool = sqlx::PgPool::connect("postgres://localhost/postgres").await.unwrap();
                sqlx::query(&format!("DROP DATABASE IF EXISTS {}", db_name))
                    .execute(&pool)
                    .await
                    .ok();
            });
        });
    }
}
```

### Share Expensive Setup with `OnceLock`

```rust
use std::sync::OnceLock;

static CONFIG: OnceLock<TestConfig> = OnceLock::new();

fn test_config() -> &'static TestConfig {
    CONFIG.get_or_init(|| TestConfig::load_from_env())
}

#[test]
fn uses_shared_config() {
    let config = test_config();
    assert!(!config.api_key.is_empty());
}
```

### Use Temporary Directories

```rust
use tempfile::TempDir;

#[test]
fn writes_output_file() {
    let dir = TempDir::new().unwrap();  // deleted on drop
    let file_path = dir.path().join("output.txt");

    write_results(&file_path, &[1, 2, 3]).unwrap();

    let contents = std::fs::read_to_string(&file_path).unwrap();
    assert!(contents.contains("1"));
}

// Keep dir alive for the test scope
#[test]
fn reads_fixture_from_temp() {
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("input.json"), br#"{"key":"value"}"#).unwrap();

    let result = process_file(dir.path().join("input.json")).unwrap();
    assert_eq!(result.get("key").unwrap(), "value");
    // dir dropped here, cleanup happens
}
```

---

## 7. Property-Based Testing

```toml
proptest = "1"
```

### Write Property Tests

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn parse_then_serialize_roundtrips(s in "[a-zA-Z0-9]{1,20}") {
        let parsed = parse_identifier(&s).unwrap();
        let serialized = serialize_identifier(&parsed);
        prop_assert_eq!(s, serialized);
    }

    #[test]
    fn sort_is_idempotent(mut v in prop::collection::vec(any::<i32>(), 0..100)) {
        v.sort();
        let sorted_once = v.clone();
        v.sort();
        prop_assert_eq!(sorted_once, v);
    }

    #[test]
    fn addition_commutes(a in 0i32..1000, b in 0i32..1000) {
        prop_assert_eq!(a + b, b + a);
    }
}
```

### Derive `Arbitrary` for Custom Types

```rust
use proptest_derive::Arbitrary;

#[derive(Debug, Clone, Arbitrary)]
pub struct User {
    #[proptest(regex = "[a-z]{3,20}")]
    pub username: String,
    pub age: u8,
    pub active: bool,
}

proptest! {
    #[test]
    fn user_validation_never_panics(user in any::<User>()) {
        // Should return Ok or Err, never panic
        let _ = validate_user(&user);
    }
}
```

### Handle Shrinking and Regression Files

Proptest automatically saves failing inputs to `proptest-regressions/` and replays them on subsequent runs. Commit these files to catch regressions. Suppress with `#[proptest(skip_shrink)]` for expensive types.

---

## 8. Benchmarks

```toml
[dev-dependencies]
criterion = { version = "0.5", features = ["html_reports"] }

[[bench]]
name = "my_bench"
harness = false
```

### Write Criterion Benchmarks

```rust
// benches/my_bench.rs
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use my_crate::{parse, process};

fn bench_parse(c: &mut Criterion) {
    let input = "example input string";

    c.bench_function("parse_simple", |b| {
        b.iter(|| parse(criterion::black_box(input)))
    });
}

fn bench_process_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("process");

    for size in [100usize, 1_000, 10_000] {
        let data: Vec<u8> = (0..size).map(|i| i as u8).collect();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(BenchmarkId::from_parameter(size), &data, |b, data| {
            b.iter(|| process(criterion::black_box(data)))
        });
    }

    group.finish();
}

fn bench_comparison(c: &mut Criterion) {
    let mut group = c.benchmark_group("sort_comparison");
    let data: Vec<i32> = (0..1000).rev().collect();

    group.bench_function("std_sort", |b| {
        b.iter(|| {
            let mut v = data.clone();
            v.sort();
            v
        })
    });

    group.bench_function("unstable_sort", |b| {
        b.iter(|| {
            let mut v = data.clone();
            v.sort_unstable();
            v
        })
    });

    group.finish();
}

criterion_group!(benches, bench_parse, bench_process_sizes, bench_comparison);
criterion_main!(benches);
```

### Run Benchmarks and Generate Flamegraphs

```bash
# Run all benchmarks
cargo bench

# Run specific benchmark
cargo bench --bench my_bench parse

# Save baseline for comparison
cargo bench -- --save-baseline before
# ... make changes ...
cargo bench -- --baseline before

# Generate flamegraph (requires cargo-flamegraph and perf/dtrace)
cargo flamegraph --bench my_bench -- --bench bench_parse
```

---

## 9. Snapshot Testing

```toml
insta = { version = "1", features = ["json", "yaml", "redactions"] }
```

### Assert with Snapshots

```rust
use insta::assert_snapshot;

#[test]
fn renders_report() {
    let report = generate_report(&sample_data());
    assert_snapshot!(report);
    // First run: creates snapshot file in snapshots/ directory
    // Subsequent runs: compares against saved snapshot
}

// JSON snapshots (pretty-printed, sorted keys)
use insta::assert_json_snapshot;

#[test]
fn serializes_user() {
    let user = User { id: 1, name: "Alice".into(), active: true };
    assert_json_snapshot!(user);
}
```

### Use Redactions for Dynamic Values

```rust
use insta::assert_json_snapshot;

#[test]
fn snapshot_with_dynamic_id() {
    let response = create_item("test");
    assert_json_snapshot!(response, {
        ".id" => "[id]",                // replace dynamic id
        ".created_at" => "[timestamp]", // replace timestamp
    });
}
```

### Review and Accept Snapshots

```bash
# Install the review tool
cargo install cargo-insta

# Run tests (failures create .snap.new files)
cargo test

# Review all pending snapshots interactively
cargo insta review

# Accept all pending snapshots at once
cargo insta accept
```

Commit `.snap` files alongside code. They are the expected output and act as documentation.

---

## 10. Test Organization

### Build a Common Test Utilities Module

```
tests/
├── common/
│   ├── mod.rs          # re-exports all helpers
│   ├── fixtures.rs     # load JSON/TOML test data
│   ├── builders.rs     # test builder patterns for structs
│   └── assertions.rs   # custom assert helpers
```

```rust
// tests/common/builders.rs
pub struct UserBuilder {
    id: u64,
    name: String,
    email: String,
}

impl UserBuilder {
    pub fn new() -> Self {
        UserBuilder { id: 1, name: "Test User".into(), email: "test@example.com".into() }
    }
    pub fn id(mut self, id: u64) -> Self { self.id = id; self }
    pub fn name(mut self, name: impl Into<String>) -> Self { self.name = name.into(); self }
    pub fn build(self) -> User {
        User { id: self.id, name: self.name, email: self.email }
    }
}
```

### Extract a `test-utils` Workspace Crate

For large workspaces, extract test utilities into a dedicated crate:

```toml
# Cargo.toml (workspace root)
[workspace]
members = ["my-app", "my-lib", "test-utils"]

# my-lib/Cargo.toml
[dev-dependencies]
test-utils = { path = "../test-utils" }
```

This avoids duplicating helpers across crates and allows `#[cfg(test)]`-gated re-exports.

### Write Custom Assertion Helpers

```rust
// tests/common/assertions.rs
pub fn assert_sorted<T: Ord + std::fmt::Debug>(items: &[T]) {
    for window in items.windows(2) {
        assert!(
            window[0] <= window[1],
            "Expected sorted slice, found {:?} before {:?}",
            window[0], window[1]
        );
    }
}

pub fn assert_error_contains(result: &anyhow::Result<()>, expected: &str) {
    match result {
        Err(e) => assert!(
            e.to_string().contains(expected),
            "Expected error to contain '{}', got: {}",
            expected, e
        ),
        Ok(_) => panic!("Expected error containing '{}', got Ok", expected),
    }
}
```

---

## 11. CI Patterns

### Run the Full Test Suite

```yaml
# .github/workflows/ci.yml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt
      - uses: Swatinem/rust-cache@v2

      - name: Format check
        run: cargo fmt --all -- --check

      - name: Lint
        run: cargo clippy --all-targets --all-features -- -D warnings

      - name: Test
        run: cargo test --workspace --all-features
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost/test

      - name: Doc test
        run: cargo test --doc --workspace
```

### Test a Feature Matrix

```yaml
strategy:
  matrix:
    features: ["", "feature-a", "feature-b", "full"]
steps:
  - name: Test feature set
    run: cargo test --no-default-features --features "${{ matrix.features }}"
```

### Measure Coverage with `cargo-llvm-cov`

```bash
# Install
cargo install cargo-llvm-cov

# Generate coverage report
cargo llvm-cov --workspace --all-features --lcov --output-path lcov.info

# HTML report locally
cargo llvm-cov --workspace --html
open target/llvm-cov/html/index.html
```

```yaml
# In CI
- name: Coverage
  run: cargo llvm-cov --workspace --all-features --lcov --output-path lcov.info
- uses: codecov/codecov-action@v4
  with:
    files: lcov.info
```

### Run Tests Against a Live Database in CI

```yaml
services:
  postgres:
    image: postgres:16
    env:
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: test
    ports:
      - 5432:5432
    options: >-
      --health-cmd pg_isready
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5
```

### Check for Unused Dependencies

```bash
cargo install cargo-machete
cargo machete

# Or for dependency audit
cargo install cargo-audit
cargo audit
```

### Enforce MSRV (Minimum Supported Rust Version)

```toml
# Cargo.toml
[package]
rust-version = "1.75"
```

```yaml
- uses: dtolnay/rust-toolchain@1.75
- run: cargo test --workspace
```
