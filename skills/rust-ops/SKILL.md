---
name: rust-ops
description: "Rust development patterns, ownership, async, error handling, and ecosystem. Use for: rust, cargo, ownership, borrow checker, lifetime, tokio, serde, trait, Result, Option, async rust, crate, derive, impl, enum, pattern matching, Arc, Mutex, Send, Sync, thiserror, anyhow, clap, axum, sqlx, reqwest, rayon, tracing."
allowed-tools: "Read Write Bash"
related-skills: [docker-ops, ci-cd-ops, testing-ops]
---

# Rust Operations

Comprehensive Rust skill covering ownership, async, error handling, and the production ecosystem.

## Ownership Quick Reference

```
Who owns the value?
│
├─ Need to transfer ownership
│  └─ Move: let s2 = s1;  (s1 is invalid after this)
│
├─ Need to read without owning
│  └─ Shared borrow: &T (multiple allowed, no mutation)
│
├─ Need to mutate without owning
│  └─ Exclusive borrow: &mut T (only one, no other borrows)
│
├─ Need to share ownership across threads
│  └─ Arc<T> (atomic reference counting)
│     └─ Need mutation too? Arc<Mutex<T>>
│
├─ Need to share ownership single-threaded
│  └─ Rc<T> (reference counting, not Send)
│     └─ Need mutation too? Rc<RefCell<T>>
│
└─ Need to avoid cloning large data
   └─ Cow<'a, T> (clone-on-write, borrows when possible)
```

### The Borrow Rules

1. At any time, you can have **either** one `&mut T` **or** any number of `&T`
2. References must always be valid (no dangling)
3. These rules are enforced at compile time (zero runtime cost)

## Error Handling Decision Tree

```
What kind of error?
│
├─ Operation might not have a value (no error info needed)
│  └─ Option<T>: Some(value) or None
│
├─ Library code (callers need to match on error variants)
│  └─ thiserror: #[derive(Error)] enum with variants
│     └─ Each variant can wrap source errors with #[from]
│
├─ Application code (just need context, not matching)
│  └─ anyhow: anyhow::Result<T>, .context("msg")
│
├─ Converting between error types
│  └─ impl From<SourceError> for MyError
│     └─ Or use #[from] with thiserror
│
└─ Truly unrecoverable (violating invariants)
   └─ panic!() or unwrap() - avoid in library code
```

### thiserror (Library Errors)

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("not found: {entity} with id {id}")]
    NotFound { entity: &'static str, id: i64 },

    #[error("validation failed: {0}")]
    Validation(String),
}
```

### anyhow (Application Errors)

```rust
use anyhow::{Context, Result};

fn load_config(path: &str) -> Result<Config> {
    let content = std::fs::read_to_string(path)
        .context("failed to read config file")?;
    let config: Config = toml::from_str(&content)
        .context("failed to parse config")?;
    Ok(config)
}
```

### The ? Operator

```rust
// ? on Result: returns Err early, unwraps Ok
let file = File::open(path)?;

// ? on Option: returns None early, unwraps Some
let first = items.first()?;

// Chain with map_err for context
let port: u16 = env::var("PORT")
    .map_err(|_| AppError::Config("PORT not set"))?
    .parse()
    .map_err(|_| AppError::Config("PORT not a number"))?;
```

**Deep dive**: Load `./references/error-handling.md` for Result/Option combinators, error conversion patterns, panic/recover.

## Trait Design Quick Reference

### Common Derives

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]  // Value types
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]  // API types
#[derive(Debug, thiserror::Error)]  // Error types
```

### Trait Objects vs Generics

| | Trait Objects (`dyn Trait`) | Generics (`T: Trait`) |
|---|---|---|
| Dispatch | Dynamic (vtable) | Static (monomorphized) |
| Binary size | Smaller | Larger (per-type copies) |
| Performance | Slight overhead | Zero-cost |
| Heterogeneous collections | Yes | No |
| Use when | Runtime polymorphism, plugin systems | Performance-critical, known types |

```rust
// Generics (preferred when types known at compile time)
fn process<T: Display>(item: T) { println!("{item}"); }

// Trait objects (when you need heterogeneous collections)
fn process_all(items: &[Box<dyn Display>]) {
    for item in items { println!("{item}"); }
}
```

### Key Traits to Know

| Trait | Purpose | Auto-derive? |
|-------|---------|-------------|
| `Debug` | Debug formatting | Yes |
| `Clone` | Explicit copy | Yes |
| `Copy` | Implicit copy (small, stack-only) | Yes |
| `Display` | User-facing formatting | No (impl manually) |
| `From`/`Into` | Type conversion | No (impl `From`, get `Into` free) |
| `Send` | Safe to send between threads | Auto |
| `Sync` | Safe to share references between threads | Auto |
| `Deref` | Smart pointer dereference | No |
| `Iterator` | Iteration protocol | No |
| `Default` | Default value | Yes |

**Deep dive**: Load `./references/traits-generics.md` for associated types, supertraits, sealed traits, extension traits.

## Async Decision Tree

```
Do you need async?
│
├─ I/O-heavy (network, files, databases)
│  └─ Yes. Use tokio.
│
├─ CPU-heavy computation
│  └─ No. Use rayon for data parallelism.
│     └─ Or tokio::task::spawn_blocking for mixing with async
│
├─ Simple scripts or CLI tools
│  └─ Probably not. Blocking I/O is fine.
│
└─ Yes, I need async:
   │
   ├─ Runtime: tokio (dominant), or async-std
   ├─ HTTP client: reqwest
   ├─ HTTP server: axum (tower-based) or actix-web
   ├─ Database: sqlx (compile-time checked)
   └─ Structured logging: tracing
```

### tokio Quick Start

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Spawn concurrent tasks
    let (a, b) = tokio::join!(
        fetch_users(),
        fetch_orders(),
    );

    // Select first to complete
    tokio::select! {
        result = long_operation() => handle(result),
        _ = tokio::time::sleep(Duration::from_secs(5)) => {
            eprintln!("timeout");
        }
    }

    Ok(())
}
```

### Channel Types

| Channel | Use Case | Import |
|---------|----------|--------|
| `mpsc` | Multiple producers, single consumer | `tokio::sync::mpsc` |
| `oneshot` | Single value, single use | `tokio::sync::oneshot` |
| `broadcast` | Multiple consumers, all get every message | `tokio::sync::broadcast` |
| `watch` | Single value, latest-only (config reload) | `tokio::sync::watch` |

**Deep dive**: Load `./references/async-tokio.md` for spawn patterns, graceful shutdown, Mutex choice, async traits, streams.

## Cargo Quick Reference

```bash
# Create project
cargo new my-project        # binary
cargo new my-lib --lib      # library

# Build and run
cargo build                 # debug
cargo build --release       # optimized
cargo run -- args           # build + run
cargo run --example name    # run example

# Test
cargo test                  # all tests
cargo test test_name        # specific test
cargo test -- --nocapture   # show println output

# Dependencies
cargo add serde --features derive    # add dep
cargo add tokio -F full              # shorthand
cargo update                         # update lock file

# Check without building
cargo check                 # fast type checking
cargo clippy                # lints
cargo fmt                   # format

# Workspace
cargo test --workspace      # test all crates
cargo build -p my-crate     # build specific crate
```

### Feature Flags

```toml
[features]
default = ["json"]
json = ["dep:serde_json"]
full = ["json", "yaml", "toml"]

[dependencies]
serde_json = { version = "1", optional = true }
```

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| `String` vs `&str` | Owned vs borrowed, function signatures | Accept `&str` in params, return `String` |
| Borrow checker fight | Borrowing self while mutating | Split struct, use indices, clone (if cheap) |
| Lifetime elision confusion | Hidden lifetimes in function signatures | Write them out explicitly to understand, then elide |
| `impl Trait` in return | Different branches must return same type | Use `Box<dyn Trait>` for heterogeneous returns |
| `tokio::Mutex` vs `std::Mutex` | `std::Mutex` can't be held across `.await` | Use `tokio::Mutex` across await points |
| Orphan rule | Can't impl foreign trait for foreign type | Newtype pattern: `struct Wrapper(ForeignType)` |
| `Pin` confusion | Required for self-referential async futures | Use `Box::pin()`, don't fight it |
| `Send` bounds on async | Spawned futures must be `Send` | Avoid `Rc`, `RefCell` in async; use `Arc`, `Mutex` |
| `.unwrap()` in production | Panics on None/Err | Use `?`, `.unwrap_or()`, `.expect("reason")` |

## serde Quick Reference

```rust
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct User {
    user_id: i64,
    display_name: String,

    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,

    #[serde(default)]
    is_active: bool,

    #[serde(rename = "type")]
    user_type: UserType,

    #[serde(with = "chrono::serde::ts_seconds")]
    created_at: DateTime<Utc>,
}

// Serialize
let json = serde_json::to_string(&user)?;
let yaml = serde_yaml::to_string(&user)?;

// Deserialize
let user: User = serde_json::from_str(&json)?;
```

**Deep dive**: Load `./references/ecosystem.md` for serde advanced usage, clap, reqwest, sqlx, axum, tracing, rayon.

## Reference Files

Load these for deep-dive topics. Each is self-contained.

| Reference | When to Load |
|-----------|-------------|
| `./references/ownership-lifetimes.md` | Borrowing rules, lifetime annotations, elision, interior mutability, common borrow checker patterns |
| `./references/traits-generics.md` | Trait design, associated types, supertraits, generics, constraints, sealed/extension traits |
| `./references/error-handling.md` | Result/Option combinators, thiserror/anyhow deep dive, error conversion, panic/recover |
| `./references/async-tokio.md` | tokio runtime, spawn, channels, select, streams, graceful shutdown, async traits, Mutex choice |
| `./references/ecosystem.md` | serde advanced, clap, reqwest, sqlx, axum, tracing, rayon, itertools, Cow |
| `./references/testing.md` | Unit/integration/doc tests, async tests, mockall, proptest, criterion benchmarks |

## See Also

- `docker-ops` - Multi-stage builds for Rust (scratch/distroless, cargo-chef for layer caching)
- `ci-cd-ops` - Rust CI pipelines, cargo caching, cross-compilation
- `testing-ops` - Cross-language testing strategies
