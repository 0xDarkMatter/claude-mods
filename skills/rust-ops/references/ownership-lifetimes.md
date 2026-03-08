# Ownership and Lifetimes Reference

## Table of Contents

1. [Move Semantics](#1-move-semantics)
2. [Borrowing Rules](#2-borrowing-rules)
3. [Lifetime Annotations](#3-lifetime-annotations)
4. [Lifetime Elision Rules](#4-lifetime-elision-rules)
5. [static Lifetime](#5-static-lifetime)
6. [Interior Mutability](#6-interior-mutability)
7. [Common Borrow Checker Patterns](#7-common-borrow-checker-patterns)
8. [NLL (Non-Lexical Lifetimes)](#8-nll-non-lexical-lifetimes)
9. [Self-Referential Structs](#9-self-referential-structs)

---

## 1. Move Semantics

### Understand What Moves vs What Copies

Types that implement `Copy` are implicitly duplicated on assignment. All others are moved.

**Copy types:** All integer primitives, `f32`/`f64`, `bool`, `char`, raw pointers, references (`&T`), arrays of Copy types, tuples of Copy types.

**Move types:** `String`, `Vec<T>`, `Box<T>`, `HashMap`, any struct containing a move type.

```rust
// Copy - both variables remain valid
let x: i32 = 5;
let y = x;
println!("{} {}", x, y); // OK

// Move - s1 is no longer valid after assignment
let s1 = String::from("hello");
let s2 = s1;
// println!("{}", s1); // ERROR: value moved

// Clone to keep both
let s3 = String::from("hello");
let s4 = s3.clone();
println!("{} {}", s3, s4); // OK
```

### Recognize Moves in Function Calls

Passing a move type to a function moves ownership into that function. The caller loses access.

```rust
fn consume(s: String) {
    println!("{}", s);
} // s is dropped here

fn borrow(s: &String) {
    println!("{}", s);
} // s is NOT dropped; caller retains ownership

fn main() {
    let s = String::from("hello");
    borrow(&s);   // s still valid
    consume(s);   // s moved into consume
    // consume(s);  // ERROR: s already moved
}
```

### Handle Moves in Closures

Closures capture variables by the minimum required (reference, mutable reference, or move). Use `move` to force ownership transfer.

```rust
let s = String::from("hello");

// Closure borrows s by reference (default when possible)
let print = || println!("{}", s);
print();
println!("{}", s); // s still valid

// Force move into closure (required for threads)
let s2 = String::from("world");
let owned = move || println!("{}", s2);
// println!("{}", s2); // ERROR: s2 moved into closure
owned();
```

Closures sent to threads must own their data because the thread may outlive the caller's stack:

```rust
let data = vec![1, 2, 3];
std::thread::spawn(move || {
    println!("{:?}", data); // data moved into thread
});
```

### Avoid Moves in Loops

Moving a value inside a loop consumes it on the first iteration. Use references or `clone` strategically.

```rust
let items = vec![String::from("a"), String::from("b")];

// BAD: moves items on first iteration if iterating by value
// for item in items { ... } // items consumed after loop

// GOOD: iterate by reference
for item in &items {
    println!("{}", item);
}
println!("{:?}", items); // items still valid

// GOOD: when you need ownership, iterate by value and handle each
for item in items {
    process(item); // each item moved individually, that's fine
}
```

---

## 2. Borrowing Rules

### Apply the Core Rules

1. At any point, you may have either one `&mut T` or any number of `&T` references — never both simultaneously.
2. References must always point to valid data (no dangling references).

```rust
let mut s = String::from("hello");

let r1 = &s;
let r2 = &s;
// let r3 = &mut s; // ERROR: cannot borrow as mutable while borrowed as immutable
println!("{} {}", r1, r2);
// r1 and r2 go out of scope here (NLL)

let r3 = &mut s; // OK now
r3.push_str("!");
```

### Understand Reborrowing

A `&mut T` can be "reborrowed" as `&T` or a shorter-lived `&mut T`. The compiler inserts reborrows automatically in most cases.

```rust
fn modify(s: &mut String) {
    // Reborrow: passing &mut *s creates a new &mut with shorter lifetime
    takes_str(&*s);    // reborrow as &str
    s.push_str("!"); // original mutable ref still usable after reborrow ends
}

fn takes_str(s: &str) {
    println!("{}", s);
}
```

### Recognize Temporary Borrows

Method calls that return references extend the borrow of `self` for the duration the reference is held.

```rust
let mut map: HashMap<&str, Vec<i32>> = HashMap::new();
map.insert("key", vec![1, 2, 3]);

// This holds an immutable borrow of map via get()
let val = map.get("key").unwrap();
println!("{:?}", val);
// val borrow ends here

map.insert("other", vec![4]); // OK: no active borrows
```

---

## 3. Lifetime Annotations

### Read Lifetime Syntax

Lifetime parameters start with `'` and appear in angle brackets. They describe relationships, not durations.

```rust
// 'a is a generic lifetime parameter
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str {
    if x.len() > y.len() { x } else { y }
}
```

The annotation says: "the returned reference lives at least as long as the shorter of x and y."

### Annotate Function Lifetimes

Only annotate when the compiler cannot infer the relationship (multiple input references, output borrows from one of them).

```rust
// Input and output tied to first argument only
fn first_word<'a>(s: &'a str) -> &'a str {
    s.split_whitespace().next().unwrap_or("")
}

// Two unrelated input lifetimes
fn split_at<'a, 'b>(s: &'a str, _sep: &'b str) -> (&'a str, &'a str) {
    let mid = s.len() / 2;
    (&s[..mid], &s[mid..])
}

// Output may come from either input - must unify lifetimes
fn pick<'a>(a: &'a str, b: &'a str, use_a: bool) -> &'a str {
    if use_a { a } else { b }
}
```

### Annotate Struct Lifetimes

Structs holding references must declare the lifetime of those references.

```rust
struct Excerpt<'a> {
    text: &'a str,
}

impl<'a> Excerpt<'a> {
    // &self lifetime elided (elision rule 3)
    fn content(&self) -> &str {
        self.text
    }

    // Must annotate: output could be self.text or announcement
    fn announce<'b>(&'a self, announcement: &'b str) -> &'a str {
        println!("{}", announcement);
        self.text
    }
}
```

### Use Multiple Lifetime Parameters

Use multiple parameters when outputs have different source lifetimes.

```rust
struct Cache<'data, 'key> {
    data: &'data [u8],
    key: &'key str,
}

// 'long outlives 'short: items from 'long can be stored where 'short is needed
fn merge<'long: 'short, 'short>(
    primary: &'long str,
    fallback: &'short str,
    use_primary: bool,
) -> &'short str {
    if use_primary { primary } else { fallback }
}
```

---

## 4. Lifetime Elision Rules

### Apply the Three Elision Rules

The compiler applies these rules in order before requiring annotations:

**Rule 1:** Each reference parameter gets its own distinct lifetime.
```rust
fn foo(x: &str, y: &str) -> &str
// becomes:
fn foo<'a, 'b>(x: &'a str, y: &'b str) -> &??? str
// output lifetime unknown - annotation required
```

**Rule 2:** If there is exactly one input lifetime, it applies to all outputs.
```rust
fn first_word(s: &str) -> &str
// becomes:
fn first_word<'a>(s: &'a str) -> &'a str // inferred
```

**Rule 3:** If one of the inputs is `&self` or `&mut self`, the output gets self's lifetime.
```rust
impl Foo {
    fn bar(&self, x: &str) -> &str
    // becomes:
    fn bar<'a, 'b>(&'a self, x: &'b str) -> &'a str // inferred
}
```

### Know When to Annotate

Annotate when:
- Multiple input references and the output could come from more than one of them
- A struct holds a reference
- You need to express a lifetime bound (`T: 'a`)

Omit when:
- Single input reference (rule 2 applies)
- Method returning reference derived from `&self` (rule 3 applies)
- Output is an owned type (no lifetime needed)

---

## 5. 'static Lifetime

### Understand String Literals vs Owned Data

`&'static str` means the reference points to data embedded in the binary — always valid.

```rust
let s: &'static str = "I am in the binary"; // string literal

// Owned String is NOT 'static, but can produce &str with any lifetime
let owned = String::from("dynamic");
let borrowed: &str = &owned; // lifetime tied to owned, not 'static
```

### Correct the T: 'static Misconception

`T: 'static` does NOT mean T lives forever. It means T contains no non-static references — T may be dropped at any time.

```rust
// T: 'static = T owns all its data (no borrowed references inside)
fn store<T: 'static>(val: T) {
    std::thread::spawn(move || drop(val)); // safe: T outlives any borrow
}

store(String::from("owned")); // OK: String owns its data
store(42i32);                 // OK: Copy type, no references

let s = String::from("temp");
// store(&s); // ERROR: &s has lifetime tied to s, not 'static
```

### Use 'static in Error and Trait Objects

Error types commonly require `'static` so they can be sent across threads or stored.

```rust
fn might_fail() -> Result<(), Box<dyn std::error::Error + 'static>> {
    std::fs::read_to_string("missing.txt")?;
    Ok(())
}

// Thread-sendable trait object
fn run_task(task: Box<dyn Fn() + Send + 'static>) {
    std::thread::spawn(task);
}
```

---

## 6. Interior Mutability

### Use Cell<T> for Copy Types

`Cell<T>` allows mutation through a shared reference. It is `!Sync` (single-threaded only) and works only for `Copy` types.

```rust
use std::cell::Cell;

struct Counter {
    count: Cell<u32>,
}

impl Counter {
    fn increment(&self) { // &self, not &mut self
        self.count.set(self.count.get() + 1);
    }
    fn value(&self) -> u32 {
        self.count.get()
    }
}

let c = Counter { count: Cell::new(0) };
c.increment();
c.increment();
println!("{}", c.value()); // 2
```

### Use RefCell<T> for Non-Copy Types

`RefCell<T>` enforces borrow rules at runtime. Panics if rules are violated. Also `!Sync`.

```rust
use std::cell::RefCell;

let data = RefCell::new(vec![1, 2, 3]);

// Immutable borrow
let r = data.borrow();
println!("{:?}", *r);
drop(r); // release before mutable borrow

// Mutable borrow
data.borrow_mut().push(4);

// try_borrow / try_borrow_mut avoid panics
match data.try_borrow_mut() {
    Ok(mut v) => v.push(5),
    Err(_) => eprintln!("already borrowed"),
}
```

Common pattern: `Rc<RefCell<T>>` for shared, mutable ownership in single-threaded code.

```rust
use std::rc::Rc;
use std::cell::RefCell;

let shared = Rc::new(RefCell::new(vec![]));
let clone = Rc::clone(&shared);

shared.borrow_mut().push(1);
clone.borrow_mut().push(2);
println!("{:?}", shared.borrow()); // [1, 2]
```

### Use OnceCell and OnceLock for Lazy Initialization

`OnceCell<T>` initializes a value at most once. `OnceLock<T>` is the thread-safe version.

```rust
use std::cell::OnceCell;

struct Config {
    expensive: OnceCell<Vec<u8>>,
}

impl Config {
    fn data(&self) -> &Vec<u8> {
        self.expensive.get_or_init(|| {
            expensive_computation()
        })
    }
}

// OnceLock for global statics (thread-safe)
use std::sync::OnceLock;

static INSTANCE: OnceLock<String> = OnceLock::new();

fn get_instance() -> &'static String {
    INSTANCE.get_or_init(|| String::from("initialized once"))
}
```

### Choose the Right Type

| Type | Thread-safe | Works with | Runtime check |
|------|-------------|------------|---------------|
| `Cell<T>` | No | `Copy` types | No (get/set) |
| `RefCell<T>` | No | Any `T` | Yes (panics) |
| `OnceCell<T>` | No | Any `T` | No (init once) |
| `OnceLock<T>` | Yes | Any `T: Send + Sync` | No (init once) |
| `Mutex<T>` | Yes | Any `T: Send` | Blocks |
| `RwLock<T>` | Yes | Any `T: Send + Sync` | Blocks |

---

## 7. Common Borrow Checker Patterns

### Split Borrows to Borrow Multiple Fields

The borrow checker tracks fields independently. Access them through separate references.

```rust
struct Point { x: f64, y: f64 }

let mut p = Point { x: 1.0, y: 2.0 };

// ERROR: cannot borrow p.x as mutable because p is also borrowed
// let rx = &mut p.x;
// let ry = &mut p.y;

// OK: split into two mutable references to distinct fields
let rx = &mut p.x;
let ry = &mut p.y;
*rx += 1.0;
*ry += 1.0;
```

For slices, use `split_at_mut`:

```rust
let mut data = vec![1, 2, 3, 4, 5];
let (left, right) = data.split_at_mut(2);
left[0] = 10;
right[0] = 30;
```

### Use Indices Instead of References

When a data structure is being modified, holding an index avoids borrow conflicts.

```rust
// BAD: first_ref holds a borrow while we try to modify vec
// let first_ref = &vec[0];
// vec.push(99); // ERROR

// GOOD: store index, re-access after modification
let first_idx = 0;
vec.push(99);
println!("{}", vec[first_idx]); // re-borrow, no conflict
```

### Use Temporary Variables to Shorten Borrow Scope

Extracting a value before using it can satisfy the borrow checker.

```rust
fn process(map: &mut HashMap<String, Vec<i32>>, key: &str) {
    // This fails: cannot borrow map as mutable while key is borrowed from it
    // if map.contains_key(key) {
    //     map.get_mut(key).unwrap().push(1);
    // }

    // Clone the key to avoid holding a reference into map
    let key = key.to_string();
    map.entry(key).or_default().push(1);
}
```

### Use the Entry API for Maps

`entry` combines lookup and insert in one operation, avoiding double borrows.

```rust
use std::collections::HashMap;

let mut scores: HashMap<String, Vec<i32>> = HashMap::new();

// BAD: two separate borrows
// if !scores.contains_key("Alice") {
//     scores.insert("Alice".to_string(), vec![]);
// }
// scores.get_mut("Alice").unwrap().push(10);

// GOOD: entry API
scores.entry("Alice".to_string()).or_default().push(10);
scores.entry("Bob".to_string()).or_insert_with(Vec::new).push(5);

// Modify existing or insert computed value
scores.entry("Carol".to_string())
    .and_modify(|v| v.push(99))
    .or_insert_with(|| vec![0]);
```

### Restructure Loops That Hold Borrows

Collecting indices or keys before iterating avoids holding a reference during modification.

```rust
let mut map: HashMap<i32, i32> = HashMap::new();
map.insert(1, 10);
map.insert(2, 20);

// Collect keys first, then iterate
let keys: Vec<i32> = map.keys().cloned().collect();
for key in keys {
    if key % 2 == 0 {
        map.remove(&key); // OK: no active borrow from .keys()
    }
}
```

---

## 8. NLL (Non-Lexical Lifetimes)

### Understand What NLL Provides

Before NLL (pre-2018 edition), borrows lasted until the end of the lexical block. NLL ends borrows at the last point of use.

```rust
let mut s = String::from("hello");

let r = &s;
println!("{}", r); // last use of r

// Pre-NLL: ERROR here because r's scope extended to end of block
// NLL: OK because r is no longer used after the println
s.push_str(" world");
println!("{}", s);
```

### Know NLL's Limits

NLL does not help when a borrow is inside a loop or the returned reference ties back to self.

```rust
// This still fails even with NLL - the borrow from get() ties to map
fn first_or_insert(map: &mut HashMap<i32, i32>, key: i32) -> &i32 {
    if let Some(val) = map.get(&key) {
        return val; // borrows map
    }
    map.insert(key, 0); // ERROR: map already borrowed by return path
    map.get(&key).unwrap()
}

// Fix: use entry API
fn first_or_insert_fixed(map: &mut HashMap<i32, i32>, key: i32) -> &i32 {
    map.entry(key).or_insert(0)
}
```

---

## 9. Self-Referential Structs

### Understand Why Self-Referential Structs Fail

A struct cannot hold a reference to one of its own fields because moving the struct would invalidate the reference.

```rust
// This does NOT compile
struct SelfRef {
    data: String,
    ptr: &str, // would need lifetime tied to self.data — impossible
}
```

### Use the ouroboros Crate

`ouroboros` generates safe self-referential structs via macro.

```rust
// Cargo.toml: ouroboros = "0.18"
use ouroboros::self_referencing;

#[self_referencing]
struct ParsedDocument {
    raw: String,
    #[borrows(raw)]
    #[covariant]
    parsed: Vec<&'this str>,
}

let doc = ParsedDocumentBuilder {
    raw: String::from("hello world foo"),
    parsed_builder: |raw: &str| raw.split_whitespace().collect(),
}.build();

doc.with_parsed(|words| println!("{:?}", words));
```

### Use Pin for Futures and Async

`Pin<P>` prevents moving the pinned value. The async runtime uses it to allow self-referential futures.

```rust
use std::pin::Pin;
use std::marker::PhantomPinned;

struct Unmovable {
    data: String,
    // self_ref would point into data
    _pin: PhantomPinned,
}

// Create pinned on heap
let pinned = Box::pin(Unmovable {
    data: String::from("hello"),
    _pin: PhantomPinned,
});

// Can call methods through Pin
// Cannot move out of Pin<Box<T>> if T: !Unpin
```

In practice, `Pin` appears most often in custom `Future` implementations and when building async combinators. Prefer `async fn` and existing executor abstractions over manual `Pin` management.
