# Traits and Generics Reference

## Table of Contents

1. [Trait Definition](#1-trait-definition)
2. [Trait Bounds](#2-trait-bounds)
3. [Associated Types vs Generic Parameters](#3-associated-types-vs-generic-parameters)
4. [Supertraits](#4-supertraits)
5. [Trait Objects](#5-trait-objects)
6. [Derive Macros](#6-derive-macros)
7. [Common Trait Implementations](#7-common-trait-implementations)
8. [Sealed Traits](#8-sealed-traits)
9. [Extension Traits](#9-extension-traits)
10. [Generics](#10-generics)
11. [Blanket Implementations](#11-blanket-implementations)

---

## 1. Trait Definition

### Define Methods, Default Implementations, and Associated Functions

```rust
pub trait Greet {
    // Required method — implementors must provide this
    fn name(&self) -> &str;

    // Default method — implementors may override
    fn greeting(&self) -> String {
        format!("Hello, {}!", self.name())
    }

    // Associated function (no self) — often used as constructors
    fn kind() -> &'static str {
        "greeter"
    }
}

struct Person {
    name: String,
}

impl Greet for Person {
    fn name(&self) -> &str {
        &self.name
    }
    // greeting() uses the default implementation
}

let p = Person { name: "Alice".into() };
println!("{}", p.greeting()); // "Hello, Alice!"
println!("{}", Person::kind()); // "greeter"
```

### Define Traits with Associated Types and Constants

```rust
pub trait Encode {
    type Output;
    const VERSION: u8 = 1;

    fn encode(&self) -> Self::Output;
}

struct Json(String);

impl Encode for Json {
    type Output = Vec<u8>;
    const VERSION: u8 = 2; // override default

    fn encode(&self) -> Vec<u8> {
        self.0.as_bytes().to_vec()
    }
}
```

---

## 2. Trait Bounds

### Apply Bounds to Functions

```rust
// Inline bound
fn print_item<T: std::fmt::Display>(item: T) {
    println!("{}", item);
}

// Where clause — cleaner for multiple or complex bounds
fn log<T, E>(result: Result<T, E>)
where
    T: std::fmt::Debug,
    E: std::fmt::Display,
{
    match result {
        Ok(v) => println!("OK: {:?}", v),
        Err(e) => eprintln!("ERR: {}", e),
    }
}

// Multiple bounds with +
fn serialize_and_print<T: serde::Serialize + std::fmt::Debug>(val: &T) {
    println!("{:?}", val);
    let json = serde_json::to_string(val).unwrap();
    println!("{}", json);
}
```

### Use impl Trait in Argument Position

`impl Trait` in argument position is syntactic sugar for a generic parameter with that bound. Each call site can use a different concrete type.

```rust
// These are equivalent
fn process(item: impl std::fmt::Display) { println!("{}", item); }
fn process<T: std::fmt::Display>(item: T) { println!("{}", item); }

// impl Trait in return position — hides the concrete type
fn make_adder(x: i32) -> impl Fn(i32) -> i32 {
    move |y| x + y
}
```

Note: `impl Trait` in return position always returns the same concrete type — it is not a trait object. Use `Box<dyn Trait>` when you need to return different types.

### Apply Bounds to Structs and Impls

```rust
struct Wrapper<T: Clone> {
    val: T,
}

// Bound on impl — methods only available when T: Clone + std::fmt::Debug
impl<T: Clone + std::fmt::Debug> Wrapper<T> {
    fn inspect(&self) -> T {
        println!("{:?}", self.val);
        self.val.clone()
    }
}
```

---

## 3. Associated Types vs Generic Parameters

### Choose Associated Types for One-to-One Relationships

Use associated types when there is only one sensible implementation per type. `Iterator` is the canonical example — a type can only produce one kind of item.

```rust
// Associated type: Vec<i32> implements Iterator<Item = &i32>
// There is exactly one Item type per implementor
trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
}

// Caller syntax is clean
fn sum_iter<I: Iterator<Item = i32>>(mut it: I) -> i32 {
    let mut total = 0;
    while let Some(n) = it.next() { total += n; }
    total
}
```

### Choose Generic Parameters for Multiple Implementations

Use generic parameters when a type may implement the trait for many different type arguments. `From<T>` is the canonical example — `String` implements `From<&str>`, `From<char>`, etc.

```rust
// Generic parameter: String can implement Converter for many T
trait Converter<T> {
    fn convert(&self) -> T;
}

struct Celsius(f64);

impl Converter<f64> for Celsius {
    fn convert(&self) -> f64 { self.0 }
}

impl Converter<String> for Celsius {
    fn convert(&self) -> String { format!("{}°C", self.0) }
}

let c = Celsius(100.0);
let f: f64 = c.convert();
let s: String = c.convert();
```

---

## 4. Supertraits

### Require Other Traits

A supertrait is a trait that must be implemented before another trait can be implemented. Declare it with `:` after the trait name.

```rust
use std::fmt;

// Animal requires Display and Debug
trait Animal: fmt::Display + fmt::Debug {
    fn sound(&self) -> &str;
}

#[derive(Debug)]
struct Dog;

impl fmt::Display for Dog {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Dog")
    }
}

impl Animal for Dog {
    fn sound(&self) -> &str { "woof" }
}
```

### Coerce to a Supertrait Object

You can use a trait object of the supertrait when you only need shared functionality.

```rust
fn describe(animal: &dyn fmt::Display) {
    println!("{}", animal);
}

let dog = Dog;
describe(&dog as &dyn fmt::Display);
```

---

## 5. Trait Objects

### Create and Use dyn Trait

A trait object (`dyn Trait`) is a fat pointer: a data pointer plus a vtable pointer. They enable dynamic dispatch.

```rust
trait Shape {
    fn area(&self) -> f64;
}

struct Circle { radius: f64 }
struct Square { side: f64 }

impl Shape for Circle {
    fn area(&self) -> f64 { std::f64::consts::PI * self.radius * self.radius }
}

impl Shape for Square {
    fn area(&self) -> f64 { self.side * self.side }
}

// Heterogeneous collection via Box<dyn Trait>
let shapes: Vec<Box<dyn Shape>> = vec![
    Box::new(Circle { radius: 1.0 }),
    Box::new(Square { side: 2.0 }),
];

for shape in &shapes {
    println!("area = {:.2}", shape.area());
}
```

### Satisfy Object Safety Rules

A trait is object-safe (usable as `dyn Trait`) if:
- It has no methods that return `Self`
- It has no generic methods
- All methods are dispatchable (take `&self`, `&mut self`, or `Box<Self>`)

```rust
// NOT object-safe: clone() returns Self
// trait Cloneable: Clone {} // cannot be dyn

// Object-safe version: return Box<dyn Trait>
trait DynClone {
    fn clone_box(&self) -> Box<dyn DynClone>;
}

// NOT object-safe: generic method
trait Bad {
    fn convert<T>(&self) -> T; // generic method — not dispatchable
}

// OK: use associated type instead
trait Good {
    type Output;
    fn convert(&self) -> Self::Output;
}
```

### Add Send + Sync to Trait Objects for Threads

```rust
// Sendable trait object
fn spawn_worker(task: Box<dyn Fn() + Send + 'static>) {
    std::thread::spawn(task);
}

// Arc<dyn Trait + Send + Sync> for shared access across threads
use std::sync::Arc;
let shared: Arc<dyn Shape + Send + Sync> = Arc::new(Circle { radius: 1.0 });
```

---

## 6. Derive Macros

### Use Common Derives

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
struct Config {
    name: String,
    value: u32,
}

// Debug: {:?} and {:#?} formatting
// Clone: .clone() method
// PartialEq/Eq: == and != operators
// Hash: usable as HashMap/HashSet key (requires PartialEq + Eq)
// Default: Config::default() returns Config { name: "", value: 0 }

#[derive(PartialOrd, Ord, PartialEq, Eq)]
struct Version(u32, u32, u32);

// PartialOrd/Ord: <, >, <=, >= operators; enables .sort() on Vec<Version>
// Ord requires PartialOrd; PartialOrd requires PartialEq
```

### Extend with the derive_more Crate

`derive_more` provides derives for common trait impls that the standard library does not include.

```rust
// Cargo.toml: derive_more = { version = "1", features = ["display", "from", "into"] }
use derive_more::{Display, From, Into};

#[derive(Display, From, Into)]
#[display("User({name}, {id})")]
struct UserId {
    name: String,
    id: u64,
}

let id = UserId::from(("Alice".to_string(), 42u64));
let (name, num): (String, u64) = id.into();
```

---

## 7. Common Trait Implementations

### Implement Display

```rust
use std::fmt;

struct Point { x: f64, y: f64 }

impl fmt::Display for Point {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({:.2}, {:.2})", self.x, self.y)
    }
}

// Implementing Display gives .to_string() for free via blanket impl
let p = Point { x: 1.0, y: 2.0 };
println!("{}", p);
let s: String = p.to_string();
```

### Implement From and Into

Implement `From`; `Into` is derived automatically via a blanket impl.

```rust
struct Meters(f64);
struct Feet(f64);

impl From<Meters> for Feet {
    fn from(m: Meters) -> Self {
        Feet(m.0 * 3.28084)
    }
}

let m = Meters(1.0);
let f: Feet = m.into();      // Into<Feet> for Meters — derived from From
let f2 = Feet::from(Meters(2.0)); // From<Meters> for Feet
```

### Implement FromStr

```rust
use std::str::FromStr;

#[derive(Debug)]
struct Color { r: u8, g: u8, b: u8 }

#[derive(Debug)]
struct ParseColorError(String);

impl std::fmt::Display for ParseColorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "parse color error: {}", self.0)
    }
}

impl FromStr for Color {
    type Err = ParseColorError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let parts: Vec<&str> = s.split(',').collect();
        if parts.len() != 3 {
            return Err(ParseColorError("expected R,G,B".into()));
        }
        let parse = |p: &str| p.trim().parse::<u8>()
            .map_err(|e| ParseColorError(e.to_string()));
        Ok(Color { r: parse(parts[0])?, g: parse(parts[1])?, b: parse(parts[2])? })
    }
}

let c: Color = "255, 128, 0".parse().unwrap();
```

### Implement Deref and DerefMut

`Deref` enables the `*` operator and auto-deref coercions. Use it for smart-pointer-like types, not general type conversions.

```rust
use std::ops::{Deref, DerefMut};

struct Wrapper<T>(Vec<T>);

impl<T> Deref for Wrapper<T> {
    type Target = Vec<T>;
    fn deref(&self) -> &Vec<T> { &self.0 }
}

impl<T> DerefMut for Wrapper<T> {
    fn deref_mut(&mut self) -> &mut Vec<T> { &mut self.0 }
}

let mut w = Wrapper(vec![1, 2, 3]);
w.push(4);         // DerefMut: Vec::push via auto-deref
println!("{}", w.len()); // Deref: Vec::len via auto-deref
```

### Implement AsRef and AsMut

`AsRef<T>` is for cheap reference conversions. Prefer it over `Deref` in function parameters.

```rust
// Accept String, &str, PathBuf, &Path, etc. — anything that is AsRef<str>
fn print_upper(s: impl AsRef<str>) {
    println!("{}", s.as_ref().to_uppercase());
}

print_upper("hello");
print_upper(String::from("world"));

// AsRef<Path> for filesystem functions
fn read_config(path: impl AsRef<std::path::Path>) -> std::io::Result<String> {
    std::fs::read_to_string(path)
}
```

---

## 8. Sealed Traits

### Prevent External Implementations

The sealed trait pattern restricts who can implement a trait — useful for stable API surfaces in libraries.

```rust
// In your library crate
mod private {
    pub trait Sealed {}
}

pub trait MyTrait: private::Sealed {
    fn do_thing(&self);
}

// Implement Sealed only for types you control
pub struct TypeA;
pub struct TypeB;

impl private::Sealed for TypeA {}
impl private::Sealed for TypeB {}

impl MyTrait for TypeA {
    fn do_thing(&self) { println!("A"); }
}

impl MyTrait for TypeB {
    fn do_thing(&self) { println!("B"); }
}

// External users CANNOT implement MyTrait because they cannot implement
// private::Sealed (it's not publicly accessible)
```

---

## 9. Extension Traits

### Add Methods to Foreign Types

Extension traits let you add methods to types you do not own, including primitives and standard library types.

```rust
pub trait StrExt {
    fn word_count(&self) -> usize;
    fn capitalize(&self) -> String;
}

impl StrExt for str {
    fn word_count(&self) -> usize {
        self.split_whitespace().count()
    }

    fn capitalize(&self) -> String {
        let mut chars = self.chars();
        match chars.next() {
            None => String::new(),
            Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        }
    }
}

// Bring the trait into scope to use the methods
use crate::StrExt;
println!("{}", "hello world".word_count()); // 2
println!("{}", "hello".capitalize());       // "Hello"
```

Extension traits must be in scope (imported) to use their methods. This is why `use std::io::Write` and similar imports are necessary.

---

## 10. Generics

### Use Type Parameters

```rust
// Generic struct
struct Stack<T> {
    items: Vec<T>,
}

impl<T> Stack<T> {
    fn push(&mut self, item: T) { self.items.push(item); }
    fn pop(&mut self) -> Option<T> { self.items.pop() }
    fn is_empty(&self) -> bool { self.items.is_empty() }
}

// Generic enum
enum Either<L, R> {
    Left(L),
    Right(R),
}
```

### Use Const Generics

Const generics allow types to be parameterized by constant values (integers, booleans, chars).

```rust
// Array type parameterized by size — zero-cost abstraction
struct Matrix<T, const ROWS: usize, const COLS: usize> {
    data: [[T; COLS]; ROWS],
}

impl<T: Default + Copy, const R: usize, const C: usize> Matrix<T, R, C> {
    fn new() -> Self {
        Matrix { data: [[T::default(); C]; R] }
    }

    fn rows(&self) -> usize { R }
    fn cols(&self) -> usize { C }
}

let m: Matrix<f64, 3, 4> = Matrix::new();
assert_eq!(m.rows(), 3);
```

### Use PhantomData for Marker Types

`PhantomData<T>` tells the compiler that a type logically contains `T` without storing it, affecting variance and drop checking.

```rust
use std::marker::PhantomData;

// A typed ID that cannot be mixed between entity types
struct Id<T> {
    value: u64,
    _phantom: PhantomData<T>,
}

impl<T> Id<T> {
    fn new(value: u64) -> Self {
        Id { value, _phantom: PhantomData }
    }
}

struct User;
struct Order;

let user_id: Id<User> = Id::new(1);
let order_id: Id<Order> = Id::new(1);
// Cannot mix: user_id and order_id are different types even though value is same
```

### Use the Turbofish Syntax

When the compiler cannot infer a generic type argument, use `::<>` (turbofish) to supply it explicitly.

```rust
// Collect requires knowing what to collect into
let nums: Vec<i32> = "1 2 3".split(' ')
    .map(|s| s.parse::<i32>().unwrap()) // turbofish on parse
    .collect::<Vec<_>>();               // turbofish on collect (alternative to type annotation)

// Any generic function may need turbofish
fn identity<T>(val: T) -> T { val }
let x = identity::<String>(String::from("hello"));
```

### Express Lifetime Constraints on Generic Types

`T: 'a` means "all references inside T live at least as long as 'a". This is required when storing generic types behind references.

```rust
struct Holder<'a, T: 'a> {
    reference: &'a T,
}

// 'static bound: T contains no non-static references
// (common for thread-spawning and stored callbacks)
fn store_callback<F: Fn() + Send + 'static>(f: F) {
    std::thread::spawn(f);
}
```

---

## 11. Blanket Implementations

### Understand Blanket Impls

A blanket implementation applies a trait to any type that satisfies certain bounds, rather than to a specific named type.

```rust
// From the standard library — any T that implements Display also gets ToString
impl<T: std::fmt::Display> ToString for T {
    fn to_string(&self) -> String {
        format!("{}", self)
    }
}

// This is why any Display type has .to_string() for free
42i32.to_string();
3.14f64.to_string();
```

### Write Blanket Impls for Your Own Traits

```rust
trait Summary {
    fn summarize(&self) -> String;
}

// Any type that implements Display also gets a free Summary impl
impl<T: std::fmt::Display> Summary for T {
    fn summarize(&self) -> String {
        format!("Summary: {}", self)
    }
}
```

Be careful: blanket impls can create conflicts. Two blanket impls that could overlap will fail to compile (the orphan rule plus coherence checking prevents ambiguity).

### Apply the Orphan Rule

You can implement a trait for a type only if either the trait or the type is defined in your crate. Both cannot be foreign.

```rust
// OK: MyTrait (yours) for String (foreign)
impl MyTrait for String { ... }

// OK: Display (foreign) for MyType (yours)
impl std::fmt::Display for MyType { ... }

// ERROR: Display (foreign) for Vec<T> (foreign) — orphan rule violation
// impl std::fmt::Display for Vec<i32> { ... }
```

Work around this using the newtype pattern:

```rust
struct MyVec(Vec<i32>);

impl std::fmt::Display for MyVec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self.0)
    }
}
```
