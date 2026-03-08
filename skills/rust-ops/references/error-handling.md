# Rust Error Handling Reference

## Table of Contents

1. [Result and Option](#1-result-and-option)
2. [The ? Operator](#2-the--operator)
3. [thiserror](#3-thiserror)
4. [anyhow](#4-anyhow)
5. [Custom Error Enums](#5-custom-error-enums)
6. [Error Conversion](#6-error-conversion)
7. [Error Context](#7-error-context)
8. [panic vs Result](#8-panic-vs-result)
9. [Result in main](#9-result-in-main)
10. [Anti-Patterns](#10-anti-patterns)

---

## 1. Result and Option

### Basics

```rust
// Result<T, E>: Ok(T) on success, Err(E) on failure
fn parse_port(s: &str) -> Result<u16, std::num::ParseIntError> {
    s.parse::<u16>()
}

// Option<T>: Some(T) or None
fn find_user(id: u64) -> Option<User> {
    users.get(&id).cloned()
}
```

### map and and_then

```rust
// map: transform Ok/Some without touching Err/None
let doubled: Option<i32> = Some(5).map(|x| x * 2);          // Some(10)
let upper: Result<String, _> = Ok("hi").map(|s: &str| s.to_uppercase());

// and_then: chain fallible operations (flatMap)
fn load_config(path: &str) -> Result<Config, Error> {
    read_file(path)
        .and_then(|contents| parse_toml(&contents))
        .and_then(|raw| validate_config(raw))
}

// Option::and_then for chaining lookups
let city = get_user(id)
    .and_then(|user| get_address(user.address_id))
    .and_then(|addr| addr.city);
```

### unwrap_or and unwrap_or_else

```rust
// unwrap_or: provide a fallback value (evaluated eagerly)
let port: u16 = parse_port(s).unwrap_or(8080);
let name: String = maybe_name.unwrap_or_else(String::new);

// unwrap_or_else: provide a closure (evaluated lazily — prefer for expensive defaults)
let config = load_config("app.toml")
    .unwrap_or_else(|_| Config::default());

// unwrap_or_default: use the Default impl
let value: Vec<u8> = maybe_bytes.unwrap_or_default();
```

### ok_or and transpose

```rust
// ok_or: convert Option into Result
let user = find_user(id).ok_or(Error::UserNotFound(id))?;

// ok_or_else: lazy version
let user = find_user(id)
    .ok_or_else(|| Error::UserNotFound(id))?;

// transpose: flip Option<Result<T, E>> <-> Result<Option<T>, E>
let maybe_result: Option<Result<u32, _>> = Some("42".parse());
let result_maybe: Result<Option<u32>, _> = maybe_result.transpose();  // Ok(Some(42))

// Useful in iterators when you want the first error or all-None
let parsed: Result<Vec<u32>, _> = strings
    .iter()
    .map(|s| s.parse::<u32>())
    .collect();  // fails on first parse error
```

### Other Useful Methods

```rust
// is_ok, is_err, is_some, is_none
if result.is_err() { log_failure(); }

// map_err: transform only the error type
let result = op().map_err(|e| format!("Operation failed: {e}"));

// or / or_else: provide alternative on failure
let result = primary().or_else(|_| fallback());

// inspect / inspect_err: side effects without consuming
let result = load().inspect(|v| tracing::debug!(?v, "loaded"))
                   .inspect_err(|e| tracing::warn!(?e, "load failed"));

// flatten: Option<Option<T>> -> Option<T>, Result<Result<T,E>,E> -> Result<T,E>
let flat: Option<i32> = Some(Some(5)).flatten();  // Some(5)
```

---

## 2. The ? Operator

### Result Propagation

```rust
// ? desugars to: match on Err, call From::from on the error, return early
fn read_config(path: &str) -> Result<Config, AppError> {
    let text = std::fs::read_to_string(path)?;  // io::Error -> AppError via From
    let config: Config = toml::from_str(&text)?; // toml::Error -> AppError via From
    Ok(config)
}
```

### Option Propagation

```rust
// ? on Option returns None immediately (requires the function to return Option)
fn first_line_word(text: &str) -> Option<&str> {
    text.lines().next()?.split_whitespace().next()
}

// Cannot mix Option? and Result? in the same function without conversion
// Use .ok_or() or .ok_or_else() to convert Option -> Result
fn find_section(text: &str) -> Result<&str, AppError> {
    text.lines()
        .find(|l| l.starts_with('['))
        .ok_or(AppError::NoSection)?
        .trim()
        .into()
}
```

### From Conversion

```rust
// ? calls From::from automatically. Define From impls to unlock ?
impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        AppError::Io(e)
    }
}

// Now io::Error can be converted with ?
fn write_output(data: &[u8]) -> Result<(), AppError> {
    std::fs::write("out.bin", data)?;  // io::Error converted automatically
    Ok(())
}
```

### Early Return Pattern

```rust
// ? enables clean early-return without match chains
fn process(input: &str) -> Result<Output, AppError> {
    let parsed = parse(input)?;
    let validated = validate(parsed)?;
    let enriched = enrich(validated)?;
    Ok(transform(enriched))
}
```

---

## 3. thiserror

thiserror generates `std::error::Error` impls via derive macros. Use it in **libraries**.

### Derive Error and Format Messages

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("user {id} not found")]
    UserNotFound { id: u64 },

    #[error("invalid email address: {0}")]
    InvalidEmail(String),

    #[error("timeout after {0:?}")]
    Timeout(std::time::Duration),

    #[error("internal error")]
    Internal,
}
```

### #[from] for Automatic Conversion

```rust
#[derive(Debug, Error)]
pub enum AppError {
    // #[from] generates From<io::Error> for AppError
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    // Enables ? on sqlx operations automatically
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("serialization error: {0}")]
    Json(#[from] serde_json::Error),
}
```

### #[source] for Error Chains

```rust
#[derive(Debug, Error)]
pub enum AppError {
    // #[source] exposes inner error via Error::source()
    // #[from] implies #[source] automatically
    #[error("config load failed")]
    Config {
        #[source]
        cause: std::io::Error,
    },

    // transparent: delegate Display and source to inner error
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}
```

### Struct Errors with thiserror

```rust
#[derive(Debug, Error)]
#[error("parse failed at line {line}: {message}")]
pub struct ParseError {
    pub line: usize,
    pub message: String,
    #[source]
    pub cause: Option<std::num::ParseIntError>,
}
```

---

## 4. anyhow

anyhow provides a single opaque error type for **application** (binary) code.

### anyhow::Result and anyhow!()

```rust
use anyhow::{anyhow, bail, ensure, Context, Result};

fn load(path: &str) -> Result<Config> {
    let text = std::fs::read_to_string(path)?;  // any error works with ?
    let config = serde_json::from_str(&text)?;
    Ok(config)
}

// anyhow!() creates an ad-hoc error
fn validate(n: i32) -> Result<i32> {
    if n < 0 {
        return Err(anyhow!("expected non-negative, got {n}"));
    }
    Ok(n)
}
```

### bail! and ensure!

```rust
fn process(value: i32) -> Result<()> {
    // bail!() is return Err(anyhow!(...))
    if value > 1000 {
        bail!("value {value} exceeds maximum of 1000");
    }

    // ensure!() is if !condition { bail!(...) }
    ensure!(value >= 0, "value must be non-negative, got {value}");

    Ok(())
}
```

### .context() and .with_context()

```rust
fn init() -> Result<()> {
    let config = std::fs::read_to_string("config.toml")
        .context("failed to read config.toml")?;

    // with_context: lazy, use when message is expensive to build
    let parsed: Config = toml::from_str(&config)
        .with_context(|| format!("failed to parse config (len={})", config.len()))?;

    Ok(())
}
```

### Downcasting

```rust
fn handle(err: anyhow::Error) {
    // Check if the underlying error is a specific type
    if let Some(io_err) = err.downcast_ref::<std::io::Error>() {
        eprintln!("IO error: {io_err}");
    } else {
        eprintln!("Unknown error: {err:#}");
    }
}

// {:#} prints the full error chain
// {:?} prints the debug representation including backtrace
```

---

## 5. Custom Error Enums

### Design Error Hierarchies

```rust
// Top-level public error: coarse-grained, stable API surface
#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("authentication failed")]
    Auth(#[from] AuthError),

    #[error("database unavailable")]
    Database(#[from] DbError),

    #[error("request invalid: {0}")]
    Validation(String),
}

// Sub-module error: fine-grained, internal
#[derive(Debug, Error)]
pub enum AuthError {
    #[error("token expired")]
    TokenExpired,

    #[error("invalid signature")]
    BadSignature,

    #[error("user {0} locked")]
    AccountLocked(u64),
}
```

### When to Split vs Combine

```rust
// SPLIT when:
// - Callers need to pattern-match specific variants
// - Different modules own different error domains
// - You want stable public API with internal flexibility

// COMBINE (single enum) when:
// - Small codebase with few error kinds
// - Errors don't need distinct handling by callers
// - Internal-only code

// Guideline: one error enum per public API boundary (crate, module, trait)
```

---

## 6. Error Conversion

### impl From

```rust
impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        match e.kind() {
            std::io::ErrorKind::NotFound => AppError::NotFound,
            std::io::ErrorKind::PermissionDenied => AppError::Forbidden,
            _ => AppError::Io(e),
        }
    }
}
```

### Manual Conversion

```rust
// When From is too broad, convert explicitly with map_err
fn read_key(path: &str) -> Result<Vec<u8>, AppError> {
    std::fs::read(path).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            AppError::KeyMissing(path.to_string())
        } else {
            AppError::Io(e)
        }
    })
}
```

### Converting Between Error Crates

```rust
// thiserror library error -> anyhow application error: just use ?
// anyhow error -> thiserror: use #[error(transparent)] or explicit wrapping

#[derive(Debug, Error)]
pub enum AppError {
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

// Or convert with a helper
fn wrap(e: anyhow::Error) -> AppError {
    AppError::Internal(e)
}
```

---

## 7. Error Context

### Add Context Without Losing Source

```rust
// anyhow .context() preserves the original error as source
let data = fetch(url).context("failed to fetch user data")?;

// thiserror: wrap in a variant with #[source]
#[derive(Debug, Error)]
pub enum LoadError {
    #[error("failed to read {path}")]
    Read {
        path: String,
        #[source]
        cause: std::io::Error,
    },
}

fn load(path: &str) -> Result<Vec<u8>, LoadError> {
    std::fs::read(path).map_err(|cause| LoadError::Read {
        path: path.to_string(),
        cause,
    })
}
```

### Wrapping Strategy

```rust
// Layer context at each boundary crossing
// 1. Low-level: return raw errors with thiserror
// 2. Service layer: add domain context with .context()
// 3. Handler/main: print full chain with {:#}

fn read_user(id: u64) -> Result<User> {
    let row = db.query_one(id)
        .with_context(|| format!("db lookup failed for user {id}"))?;
    parse_user(row)
        .with_context(|| format!("failed to parse user {id} from db row"))
}
```

---

## 8. panic vs Result

### When panic Is Legitimate

```rust
// 1. Tests: use assert!, assert_eq!, unwrap() freely
#[test]
fn test_parse() {
    assert_eq!(parse("42").unwrap(), 42);
}

// 2. Initialization that cannot recover
fn main() {
    let config = load_config().expect("failed to load required config");
}

// 3. Invariant violations that indicate a programmer bug
fn get_first(v: &[i32]) -> i32 {
    // Caller contract: v must not be empty
    v[0]  // panics on empty — that is correct behaviour
}

// 4. Prototype / throwaway code (use todo!, unimplemented!)
fn not_implemented_yet() -> String {
    todo!("implement serialization")
}
```

### catch_unwind for Panic Isolation

```rust
use std::panic;

// Catch panics from untrusted code (plugin, FFI boundary)
let result = panic::catch_unwind(|| {
    potentially_panicking_code()
});

match result {
    Ok(value) => println!("success: {value:?}"),
    Err(_) => eprintln!("caught a panic"),
}

// Note: catch_unwind does NOT catch abort-mode panics or stack overflows
```

---

## 9. Result in main

### Return Result from main

```rust
// main can return Result<(), E> where E: Debug
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = load_config()?;
    run(config)?;
    Ok(())
}

// With anyhow for full error chains
fn main() -> anyhow::Result<()> {
    let config = load_config().context("startup failed")?;
    run(config)?;
    Ok(())
}
```

### ExitCode and process::exit

```rust
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::FAILURE
        }
    }
}

// process::exit for immediate termination (skips destructors)
fn must_succeed() {
    if let Err(e) = critical_setup() {
        eprintln!("fatal: {e}");
        std::process::exit(1);
    }
}
```

### Termination Trait

```rust
// For custom exit codes beyond 0/1
use std::process::{ExitCode, Termination};

struct AppExit(u8);

impl Termination for AppExit {
    fn report(self) -> ExitCode {
        ExitCode::from(self.0)
    }
}

fn main() -> AppExit {
    match run() {
        Ok(()) => AppExit(0),
        Err(AppError::ConfigMissing) => AppExit(2),
        Err(_) => AppExit(1),
    }
}
```

---

## 10. Anti-Patterns

### .unwrap() Everywhere

```rust
// BAD: panics on any error in production
let text = std::fs::read_to_string("config.toml").unwrap();
let user = find_user(id).unwrap();

// GOOD: propagate with ?, provide defaults, or handle explicitly
let text = std::fs::read_to_string("config.toml")
    .context("config.toml is required")?;
let user = find_user(id).ok_or(AppError::UserNotFound(id))?;
```

### Stringly Typed Errors

```rust
// BAD: callers cannot inspect or match on error kind
fn load(path: &str) -> Result<Data, String> {
    std::fs::read_to_string(path).map_err(|e| e.to_string())
}

// GOOD: typed errors callers can handle
fn load(path: &str) -> Result<Data, AppError> {
    let text = std::fs::read_to_string(path)?;
    Ok(parse(&text)?)
}
```

### Excessive Error Types

```rust
// BAD: one error type per function — impossible to use
fn read_name() -> Result<String, ReadNameError> { ... }
fn parse_age() -> Result<u32, ParseAgeError> { ... }
fn validate() -> Result<(), ValidateError> { ... }

// GOOD: one error type per domain boundary
fn load_user(id: u64) -> Result<User, UserError> { ... }
```

### Ignoring Errors with let _ =

```rust
// BAD: silently discards errors — hides bugs
let _ = send_notification(user);
let _ = std::fs::remove_file(tmp);

// GOOD: log or explicitly decide to ignore
if let Err(e) = send_notification(user) {
    tracing::warn!(?e, "notification failed, continuing");
}

// If truly safe to ignore, be explicit about why
std::fs::remove_file(tmp).ok();  // .ok() signals intentional ignore
```

### Boxing Without Cause

```rust
// BAD: loses type information, callers can't downcast easily
fn run() -> Result<(), Box<dyn std::error::Error>> { ... }

// GOOD in main / test harnesses, BAD in library APIs
// For libraries, use typed errors via thiserror
// For applications, use anyhow::Result
```
