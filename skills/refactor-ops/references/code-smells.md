# Code Smells Reference

Comprehensive catalog of code smells with detection heuristics, refactoring prescriptions, tooling by language, and complexity metrics.

---

## Smell Catalog

### Long Function / Method

**Heuristic:** > 20 lines, > 5 levels of indentation, or cyclomatic complexity > 10.

**Why it's a smell:** Long functions do too many things. They are hard to name, hard to test, hard to reuse, and hard to understand. Each additional responsibility multiplies the cognitive load.

**Detection:**

```
Function length check
│
├─ Count lines (excluding blanks and comments)
│  ├─ < 10 lines → Fine
│  ├─ 10-20 lines → Monitor
│  ├─ 20-50 lines → Likely needs extraction
│  └─ > 50 lines → Almost certainly too long
│
└─ Count indentation levels
   ├─ 1-2 levels → Normal
   ├─ 3 levels → Borderline
   └─ 4+ levels → Extract inner blocks
```

**Refactoring options:**
- Extract Function (most common)
- Decompose Conditional (if/else chains)
- Replace Loop with Pipeline (map/filter/reduce)
- Replace Method with Method Object (when extraction needs too many params)

**Example -- Before:**

```python
def process_application(app):
    # Validate
    if not app.name:
        raise ValueError("Name required")
    if not app.email or "@" not in app.email:
        raise ValueError("Valid email required")
    if app.age < 18:
        raise ValueError("Must be 18+")

    # Score
    score = 0
    if app.gpa > 3.5:
        score += 30
    elif app.gpa > 3.0:
        score += 20
    else:
        score += 10

    if app.experience_years > 5:
        score += 40
    elif app.experience_years > 2:
        score += 25
    else:
        score += 10

    if app.has_certification:
        score += 20

    # Decide
    if score >= 70:
        status = "accepted"
    elif score >= 50:
        status = "waitlisted"
    else:
        status = "rejected"

    # Persist and notify
    app.score = score
    app.status = status
    db.save(app)
    send_email(app.email, f"Your application was {status}")
    return app
```

**Example -- After:**

```python
def process_application(app):
    validate_application(app)
    score = calculate_score(app)
    status = determine_status(score)
    return finalize_application(app, score, status)
```

---

### God Object / God Class

**Heuristic:** > 10 public methods, > 500 lines, > 7 dependencies injected, or the class name contains "Manager", "Handler", "Processor", "Service" without a specific domain qualifier.

**Why it's a smell:** A class that knows too much or does too much becomes a bottleneck. Every change risks breaking unrelated functionality. It attracts more responsibilities because "it already handles X, so let's add Y."

**Detection:**

```
Signs of a God Object
│
├─ Class has 10+ public methods
├─ Constructor takes 5+ dependencies
├─ Multiple unrelated groups of methods
│  (some deal with users, others with billing, others with notifications)
├─ Methods don't use most of the class's fields
│  (low cohesion -- methods only touch a subset of state)
├─ Class is imported by > 20 other files
└─ Changes to the class are in every PR
```

**Refactoring options:**
- Extract Class (split by responsibility)
- Extract Interface (define role-specific interfaces)
- Move Method (move methods to the class whose data they use)
- Facade Pattern (keep the god object as a thin coordinator)

**TypeScript example -- identifying responsibilities:**

```typescript
// BEFORE: UserManager does everything
class UserManager {
  // Group 1: Authentication
  login(email, password) { /* ... */ }
  logout(userId) { /* ... */ }
  resetPassword(email) { /* ... */ }

  // Group 2: Profile management
  updateProfile(userId, data) { /* ... */ }
  uploadAvatar(userId, file) { /* ... */ }
  getPreferences(userId) { /* ... */ }

  // Group 3: Billing
  createSubscription(userId, plan) { /* ... */ }
  cancelSubscription(userId) { /* ... */ }
  processPayment(userId, amount) { /* ... */ }

  // Group 4: Notifications
  sendWelcomeEmail(userId) { /* ... */ }
  sendInvoice(userId) { /* ... */ }
  updateNotificationPrefs(userId, prefs) { /* ... */ }
}

// AFTER: Split by responsibility
class AuthService { login, logout, resetPassword }
class ProfileService { updateProfile, uploadAvatar, getPreferences }
class BillingService { createSubscription, cancelSubscription, processPayment }
class NotificationService { sendWelcomeEmail, sendInvoice, updateNotificationPrefs }
```

---

### Feature Envy

**Heuristic:** A method accesses another object's data more than its own. Count field accesses -- if > 50% reference another class, the method probably belongs there.

**Why it's a smell:** The method is in the wrong place. It has more affinity for another class's data, which means changes to that class's data structure will also require changing this method.

**Detection:**

```python
# Feature Envy: this method is in OrderService but only touches Product data
class OrderService:
    def calculate_discount(self, product):
        if product.category == "electronics" and product.price > 500:
            return product.price * product.bulk_discount_rate
        elif product.is_seasonal and product.days_until_expiry < 30:
            return product.price * 0.25
        return 0
```

**Fix: Move to the class whose data it uses:**

```python
class Product:
    def calculate_discount(self) -> float:
        if self.category == "electronics" and self.price > 500:
            return self.price * self.bulk_discount_rate
        elif self.is_seasonal and self.days_until_expiry < 30:
            return self.price * 0.25
        return 0
```

**Exception:** Feature envy is acceptable when:
- You intentionally keep logic separate from data (e.g., pure functions operating on DTOs)
- The "envied" class is a simple data transfer object with no behavior
- Moving the method would create a circular dependency

---

### Duplicate Code

**Heuristic:** Same logic in 2+ places, differing only in variable names or minor details. > 5 lines of near-identical code is a strong signal.

**Why it's a smell:** When you fix a bug in one copy, you must find and fix all copies. You will forget one. Duplicated code also inflates the codebase, making it harder to navigate.

**DRY vs WET vs AHA:**

```
Duplication Strategy
│
├─ 1 occurrence → Leave it alone
│
├─ 2 occurrences → Note it, but don't extract yet (WET: Write Everything Twice)
│  │  Reason: You don't yet know the right abstraction
│  └─ Exception: If the two are truly identical and likely to stay so, extract
│
├─ 3+ occurrences → Extract (AHA: Avoid Hasty Abstractions)
│  │  Now you have enough examples to see the real pattern
│  └─ Extract with parameters for the varying parts
│
└─ Wrong abstraction is worse than duplication
   If the shared code diverges, it's OK to un-DRY and duplicate again
```

**Detection tools:**

| Language | Tool | Command |
|----------|------|---------|
| JavaScript/TypeScript | jscpd | `npx jscpd src/ --min-lines 5` |
| Python | pylint | `pylint --disable=all --enable=duplicate-code src/` |
| Multi-language | PMD CPD | `pmd cpd --minimum-tokens 50 --dir src/` |
| Any | ast-grep | Write a pattern to find structural duplicates |
| IDE | IntelliJ | Analyze > Locate Duplicates |

**Example -- Extract with parameterization:**

```typescript
// BEFORE: Two near-identical functions
function sendWelcomeEmail(user: User) {
  const template = loadTemplate('welcome');
  const html = render(template, { name: user.name, date: new Date() });
  await mailer.send({ to: user.email, subject: 'Welcome!', html });
  await analytics.track('email_sent', { type: 'welcome', userId: user.id });
}

function sendPasswordResetEmail(user: User, token: string) {
  const template = loadTemplate('password-reset');
  const html = render(template, { name: user.name, token, date: new Date() });
  await mailer.send({ to: user.email, subject: 'Password Reset', html });
  await analytics.track('email_sent', { type: 'password-reset', userId: user.id });
}

// AFTER: Parameterized
interface EmailParams {
  templateName: string;
  subject: string;
  extraData?: Record<string, unknown>;
}

async function sendEmail(user: User, params: EmailParams) {
  const template = loadTemplate(params.templateName);
  const html = render(template, { name: user.name, date: new Date(), ...params.extraData });
  await mailer.send({ to: user.email, subject: params.subject, html });
  await analytics.track('email_sent', { type: params.templateName, userId: user.id });
}

// Usage
await sendEmail(user, { templateName: 'welcome', subject: 'Welcome!' });
await sendEmail(user, { templateName: 'password-reset', subject: 'Password Reset', extraData: { token } });
```

---

### Deep Nesting

**Heuristic:** > 3 levels of indentation from nesting if/for/while/try blocks.

**Why it's a smell:** Each level of nesting adds cognitive load. The reader must mentally track every condition that led to the current branch. Error handling and happy path become interleaved and hard to follow.

**Refactoring techniques:**

#### Guard Clauses (Early Returns)

```typescript
// BEFORE: nested
function processPayment(order: Order) {
  if (order) {
    if (order.items.length > 0) {
      if (order.paymentMethod) {
        if (order.total > 0) {
          // actual logic buried 4 levels deep
          return chargePayment(order);
        } else {
          throw new Error('Invalid total');
        }
      } else {
        throw new Error('No payment method');
      }
    } else {
      throw new Error('No items');
    }
  } else {
    throw new Error('No order');
  }
}

// AFTER: guard clauses
function processPayment(order: Order) {
  if (!order) throw new Error('No order');
  if (order.items.length === 0) throw new Error('No items');
  if (!order.paymentMethod) throw new Error('No payment method');
  if (order.total <= 0) throw new Error('Invalid total');

  return chargePayment(order);
}
```

#### Replace Nested Loops with Pipeline

```python
# BEFORE
results = []
for user in users:
    if user.is_active:
        for order in user.orders:
            if order.total > 100:
                results.append({
                    "user": user.name,
                    "order": order.id,
                    "total": order.total,
                })

# AFTER
results = [
    {"user": u.name, "order": o.id, "total": o.total}
    for u in users if u.is_active
    for o in u.orders if o.total > 100
]
```

#### Extract Inner Block

```go
// BEFORE
func processRecords(records []Record) error {
    for _, record := range records {
        if record.IsValid() {
            for _, field := range record.Fields {
                if field.NeedsTransform() {
                    // 20 lines of transformation logic
                }
            }
        }
    }
    return nil
}

// AFTER
func processRecords(records []Record) error {
    for _, record := range records {
        if !record.IsValid() {
            continue
        }
        if err := transformFields(record.Fields); err != nil {
            return err
        }
    }
    return nil
}

func transformFields(fields []Field) error {
    for _, field := range fields {
        if !field.NeedsTransform() {
            continue
        }
        if err := transformField(field); err != nil {
            return err
        }
    }
    return nil
}
```

---

### Primitive Obsession

**Heuristic:** Using raw strings, numbers, or booleans to represent domain concepts that have validation rules or behavior.

**Why it's a smell:** A string can hold any value, but an email address cannot. Primitive obsession means validation logic is scattered across every place the value is used, or worse, missing entirely.

**Examples:**

```typescript
// BEFORE: Primitives everywhere
function createUser(
  email: string,        // Could be "not-an-email"
  age: number,          // Could be -5 or 999
  role: string,         // Could be "superadmin-hacker"
  currency: string,     // Could be "DOGECOIN"
  amount: number,       // Dollars? Cents? Yen?
) { /* ... */ }

// AFTER: Value objects / branded types
type Email = string & { readonly __brand: 'Email' };
type Age = number & { readonly __brand: 'Age' };
type Role = 'admin' | 'editor' | 'viewer';
type Currency = 'USD' | 'EUR' | 'GBP';
interface Money { amount: number; currency: Currency; }

function createEmail(raw: string): Email {
  if (!/^[^@]+@[^@]+\.[^@]+$/.test(raw)) throw new Error('Invalid email');
  return raw as Email;
}

function createAge(raw: number): Age {
  if (raw < 0 || raw > 150) throw new Error('Invalid age');
  return raw as Age;
}
```

```rust
// Rust: newtypes
struct Email(String);
struct Age(u8);

impl Email {
    fn new(raw: &str) -> Result<Self, ValidationError> {
        if raw.contains('@') { Ok(Email(raw.to_string())) }
        else { Err(ValidationError::InvalidEmail) }
    }
}

impl Age {
    fn new(raw: u8) -> Result<Self, ValidationError> {
        if raw > 0 && raw < 150 { Ok(Age(raw)) }
        else { Err(ValidationError::InvalidAge) }
    }
}
```

```python
# Python: dataclass value objects
@dataclass(frozen=True)
class Email:
    value: str

    def __post_init__(self):
        if "@" not in self.value:
            raise ValueError(f"Invalid email: {self.value}")

@dataclass(frozen=True)
class Money:
    amount: Decimal
    currency: str

    def __add__(self, other: "Money") -> "Money":
        if self.currency != other.currency:
            raise ValueError("Cannot add different currencies")
        return Money(self.amount + other.amount, self.currency)
```

---

### Shotgun Surgery

**Heuristic:** A single logical change requires editing 5+ files. The opposite of god object -- responsibility is spread too thin.

**Why it's a smell:** Every change is a scavenger hunt. Easy to miss one of the N files that need updating, leading to inconsistencies.

**Detection:**

```
Signs of Shotgun Surgery
│
├─ Adding a new field requires changes in:
│  model + serializer + validator + API + UI + test + migration + docs
│
├─ git log shows that certain groups of files always change together
│  └─ git log --name-only --pretty=format: | sort | uniq -c | sort -rn
│
└─ Code review comments: "Did you update X too?"
```

**Refactoring options:**
- Move Method / Move Field to consolidate related logic
- Inline Class (merge overly-split classes)
- Create a module that owns the entire concept end-to-end

---

### Dead Code

**Heuristic:** Code that is never executed -- unused imports, unreachable branches, commented-out code, exports with no importers, functions never called.

**Why it's a smell:** Dead code confuses readers ("is this important?"), increases maintenance burden, and can mask bugs. It adds noise to search results and IDE navigation.

**Detection by language:**

```
Dead Code Detection
│
├─ TypeScript / JavaScript
│  ├─ knip → comprehensive (files, exports, deps, types)
│  │  └─ npx knip
│  ├─ ts-prune → unused exports
│  │  └─ npx ts-prune
│  ├─ eslint → unused vars, unreachable code
│  │  └─ no-unused-vars, no-unreachable
│  └─ webpack-bundle-analyzer → unused modules in bundle
│
├─ Python
│  ├─ vulture → unused functions, variables, imports
│  │  └─ vulture src/ --min-confidence 80
│  ├─ ruff → unused imports (F401), unreachable code
│  │  └─ ruff check --select F401,F811
│  └─ coverage.py → branches never executed in tests
│
├─ Go
│  ├─ Compiler → unused imports (error), unused vars (error)
│  ├─ staticcheck → unused functions, types, fields
│  │  └─ staticcheck ./...
│  └─ golangci-lint → deadcode, unused linters
│
├─ Rust
│  ├─ Compiler → dead_code, unused_imports warnings
│  │  └─ cargo build 2>&1 | rg 'warning.*unused'
│  └─ cargo-udeps → unused dependencies
│     └─ cargo +nightly udeps
│
└─ Manual checks
   ├─ Search for commented-out code blocks → delete them
   ├─ Search for TODO/FIXME referencing removed features
   └─ Check feature flags for permanently-off features
```

**Safe removal strategy:**

1. Verify the code is truly dead (not used via reflection, dynamic import, or external consumers)
2. Remove in small batches, run full test suite after each
3. One commit per logical group of dead code
4. Keep the PR focused: dead code removal only, no behavior changes

---

### Data Clumps

**Heuristic:** The same group of 3+ values appears together repeatedly as function parameters, constructor args, or data fields.

**Why it's a smell:** The group of values represents a concept that deserves its own name and type. Without it, you duplicate validation and the relationship between the values is implicit.

**Example:**

```typescript
// BEFORE: Data clump (lat, lng, altitude appear together repeatedly)
function calculateDistance(lat1: number, lng1: number, alt1: number,
                           lat2: number, lng2: number, alt2: number): number { /* ... */ }

function formatLocation(lat: number, lng: number, alt: number): string { /* ... */ }

function isWithinBounds(lat: number, lng: number, alt: number,
                         bounds: Bounds): boolean { /* ... */ }

// AFTER: Extract parameter object
interface GeoPoint {
  lat: number;
  lng: number;
  altitude: number;
}

function calculateDistance(from: GeoPoint, to: GeoPoint): number { /* ... */ }
function formatLocation(point: GeoPoint): string { /* ... */ }
function isWithinBounds(point: GeoPoint, bounds: Bounds): boolean { /* ... */ }
```

---

### Long Parameter List

**Heuristic:** A function takes more than 4 parameters. Even 3 can be too many if they are all the same type (easy to swap by mistake).

**Why it's a smell:** Hard to remember argument order. Easy to swap two arguments of the same type. Adding a parameter requires updating all call sites.

**Refactoring options:**

```
Too many parameters?
│
├─ Parameters represent a concept → Extract Parameter Object
│  (firstName, lastName, email, phone → ContactInfo)
│
├─ Parameters are configuration → Builder Pattern or Options Object
│  (timeout, retries, baseUrl, headers → ClientOptions)
│
├─ Some parameters are always the same → Set defaults or partial application
│  (logger, config are always the same → inject via constructor)
│
└─ Parameters are independent concerns → Split into multiple functions
   (validate(data, rules, locale, format) → validate(data, rules) + format(data, locale))
```

---

## Complexity Metrics

### Cyclomatic Complexity

Counts the number of independent paths through a function. Each `if`, `else`, `for`, `while`, `case`, `catch`, `&&`, `||` adds 1 to the count.

| Score | Risk | Action |
|-------|------|--------|
| 1-5 | Low | No action needed |
| 6-10 | Moderate | Consider simplification |
| 11-20 | High | Refactor: extract functions, decompose conditionals |
| > 20 | Very High | Mandatory refactoring |

**Measurement tools:**

| Language | Tool | Command |
|----------|------|---------|
| JavaScript | eslint complexity rule | `eslint --rule 'complexity: ["error", 10]'` |
| Python | radon | `radon cc src/ -a -nc` |
| Go | gocyclo | `gocyclo -over 10 .` |
| Rust | cargo-geiger | Measures unsafe code complexity |
| Multi | SonarQube | Dashboard with complexity metrics |

### Cognitive Complexity

A newer metric (from SonarSource) that better reflects human reading difficulty. Unlike cyclomatic complexity, it penalizes nesting and rewards linear flow.

Key differences from cyclomatic complexity:
- Nested `if` inside `for` scores higher than sequential `if` then `for`
- Early returns (`guard clauses`) reduce complexity
- `switch` counts once, not per case
- Boolean operator sequences (`a && b && c`) count once

### Coupling and Cohesion

```
Coupling (between modules) — LOWER is better
│
├─ Afferent Coupling (Ca): How many modules depend ON this module
│  High Ca = changing this module breaks many things
│
├─ Efferent Coupling (Ce): How many modules this module depends ON
│  High Ce = this module is fragile (many reasons to change)
│
└─ Instability = Ce / (Ca + Ce)
   0.0 = maximally stable (many dependents, few dependencies)
   1.0 = maximally unstable (few dependents, many dependencies)

Cohesion (within a module) — HIGHER is better
│
├─ Every method uses every field → perfectly cohesive
├─ Methods split into groups using different fields → low cohesion
│  → Split into multiple classes
└─ Measured by LCOM (Lack of Cohesion of Methods)
   LCOM = 0 → perfectly cohesive
   LCOM > 0 → methods don't relate to each other
```

---

## Detection Tools by Language

### JavaScript / TypeScript

| Tool | Detects | Install | Command |
|------|---------|---------|---------|
| **eslint** | Unused vars, complexity, unreachable code | `npm i -D eslint` | `eslint --rule 'complexity: ["error", 10]' src/` |
| **knip** | Unused files, exports, deps, types | `npm i -D knip` | `npx knip` |
| **ts-prune** | Unused exports | `npm i -D ts-prune` | `npx ts-prune` |
| **jscpd** | Copy-paste detection | `npm i -D jscpd` | `npx jscpd src/ --min-lines 5` |
| **SonarQube** | Comprehensive (complexity, duplication, smells) | Server install | Web dashboard |

### Python

| Tool | Detects | Install | Command |
|------|---------|---------|---------|
| **ruff** | Unused imports, vars, complexity, style | `pip install ruff` | `ruff check --select ALL src/` |
| **vulture** | Dead code (functions, vars, imports) | `pip install vulture` | `vulture src/ --min-confidence 80` |
| **radon** | Cyclomatic + Halstead complexity | `pip install radon` | `radon cc src/ -a -nc` |
| **pylint** | Duplicate code, design smells | `pip install pylint` | `pylint --disable=all --enable=R src/` |
| **wily** | Complexity trends over time | `pip install wily` | `wily build src/ && wily report src/module.py` |

### Go

| Tool | Detects | Install | Command |
|------|---------|---------|---------|
| **golangci-lint** | Meta-linter (50+ linters) | Binary install | `golangci-lint run` |
| **gocyclo** | Cyclomatic complexity | `go install` | `gocyclo -over 10 .` |
| **goconst** | Repeated strings/numbers | Part of golangci-lint | `golangci-lint run --enable goconst` |
| **dupl** | Duplicate code | Part of golangci-lint | `golangci-lint run --enable dupl` |
| **staticcheck** | Unused code, bugs, simplifications | `go install` | `staticcheck ./...` |

### Rust

| Tool | Detects | Install | Command |
|------|---------|---------|---------|
| **clippy** | Lint, style, complexity, correctness | Built-in | `cargo clippy -- -W clippy::all` |
| **cargo-udeps** | Unused dependencies | `cargo install` | `cargo +nightly udeps` |
| **cargo-geiger** | Unsafe code usage | `cargo install` | `cargo geiger` |
| **Compiler** | Dead code, unused imports/vars | Built-in | `#[deny(dead_code, unused)]` |

---

## Smell Prioritization

Not all smells are equally urgent. Prioritize based on impact:

```
Triage Smells
│
├─ Fix NOW (blocks work or causes bugs)
│  ├─ Dead code that confuses newcomers
│  ├─ Duplicate code that has already diverged (bug in one copy)
│  └─ God object that causes merge conflicts every sprint
│
├─ Fix SOON (increasing maintenance cost)
│  ├─ Long functions (> 50 lines)
│  ├─ Deep nesting (> 4 levels)
│  └─ Shotgun surgery (every feature touches 10 files)
│
├─ Fix LATER (annoyances, not blockers)
│  ├─ Primitive obsession (works but fragile)
│  ├─ Data clumps (inconvenient but functional)
│  └─ Moderate duplication (2 copies, stable)
│
└─ Maybe NEVER (acceptable trade-offs)
   ├─ Generated code (don't refactor auto-generated files)
   ├─ Legacy code with no tests (write tests first)
   └─ Code scheduled for replacement
```

---

## Anti-patterns in Smell Remediation

| Anti-pattern | Problem | Better Approach |
|--------------|---------|-----------------|
| Refactoring without tests | Cannot verify behavior is preserved | Write characterization tests first |
| Premature DRY | Wrong abstraction extracted from 2 examples | Wait for 3+ examples (AHA principle) |
| Big-bang refactor | Everything breaks at once, can't bisect | Small, incremental changes with tests after each |
| Gold plating | Refactoring beyond what is needed for the task | Refactor only the code you are actively working on |
| Refactoring old stable code "just because" | Risk with no business value | Only refactor when you need to change it |
| Introducing patterns without need | Design patterns are solutions to problems, not goals | Pattern should reduce complexity, not add it |
