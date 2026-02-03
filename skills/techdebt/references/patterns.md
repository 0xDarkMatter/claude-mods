# Language-Specific Tech Debt Patterns

Detection patterns for common technical debt across programming languages.

## Python

### Duplication Patterns

**Import duplication:**
```python
# Bad: Repeated logic across modules
# file1.py
def process_user(user):
    if not user.email:
        raise ValueError("Email required")
    return user.save()

# file2.py
def update_user(user):
    if not user.email:
        raise ValueError("Email required")
    return user.save()

# Fix: Extract to shared validator
```

**Algorithm duplication:**
```python
# Pattern: Same calculation logic in multiple places
# Detection: AST similarity >85% for blocks >10 lines
```

### Security Patterns

**Hardcoded secrets:**
```python
API_KEY = "sk-1234567890abcdef"  # P0
PASSWORD = "admin123"             # P0
SECRET_TOKEN = "abc" * 10         # P0

# Patterns to detect:
- Uppercase variables with "KEY", "SECRET", "PASSWORD", "TOKEN"
- String values matching common secret formats (sk-, ghp_, aws_)
```

**SQL injection:**
```python
# Bad
query = f"SELECT * FROM users WHERE id={user_id}"  # P0
cursor.execute("SELECT * FROM users WHERE name='" + name + "'")  # P0

# Good
cursor.execute("SELECT * FROM users WHERE id=?", (user_id,))
```

**Insecure crypto:**
```python
import hashlib
hashlib.md5(password)          # P0 - Use bcrypt/scrypt
hashlib.sha1(password)         # P0 - Use bcrypt/scrypt

import random
token = random.random()        # P0 - Use secrets module

import pickle
pickle.loads(user_data)        # P1 - Unsafe deserialization

import yaml
yaml.load(config)              # P1 - Use yaml.safe_load()
```

**Path traversal:**
```python
# Bad
file_path = request.GET['file']
open(file_path)                # P0 - No validation

# Good
file_path = os.path.basename(request.GET['file'])
open(os.path.join(SAFE_DIR, file_path))
```

### Complexity Patterns

**Deeply nested conditionals:**
```python
# P1: >5 levels deep
def process(data):
    if data:
        if data.user:
            if data.user.role:
                if data.user.role == 'admin':
                    if data.user.permissions:
                        if 'delete' in data.user.permissions:
                            # Action here - 6 levels deep
                            pass

# Fix: Use guard clauses and early returns
```

**Long functions:**
```python
# P1: >100 lines
# P2: >50 lines
# Suggest: Extract method refactoring
```

**Many parameters:**
```python
# P2: >5 parameters
def create_user(name, email, age, address, phone, role, department):
    pass

# Fix: Use dataclass or parameter object
```

### Dead Code Patterns

**Unused imports:**
```python
import os          # Used
import sys         # Unused - P3
from typing import List  # Used
from typing import Dict  # Unused - P3
```

**Unreachable code:**
```python
def process():
    return True
    print("Never executed")  # P3 - Unreachable
```

**Unused variables:**
```python
def calculate(x, y):
    result = x + y    # Written but never read - P3
    return x * y
```

## JavaScript/TypeScript

### Duplication Patterns

**React component duplication:**
```typescript
// Bad: Similar components with slight variations
const UserCard = ({ user }) => (
  <div className="card">
    <h2>{user.name}</h2>
    <p>{user.email}</p>
  </div>
);

const ProductCard = ({ product }) => (
  <div className="card">
    <h2>{product.name}</h2>
    <p>{product.price}</p>
  </div>
);

// Fix: Generic Card component with props
```

### Security Patterns

**XSS vulnerabilities:**
```typescript
// Bad
element.innerHTML = userInput;  // P0
document.write(userData);       // P0
$(selector).html(userContent);  // P0

// Good
element.textContent = userInput;
```

**Eval usage:**
```typescript
eval(userCode);                 // P0
new Function(userCode)();       // P0
setTimeout(userCode, 1000);     // P1 if userCode is string
```

**Insecure random:**
```typescript
// Bad
const token = Math.random().toString(36);  // P0

// Good
const token = crypto.randomBytes(32).toString('hex');
```

### Complexity Patterns

**Callback hell:**
```typescript
// P2: >3 levels of nesting
getData((data) => {
  processData(data, (processed) => {
    saveData(processed, (result) => {
      notifyUser(result, (notification) => {
        // 4 levels deep
      });
    });
  });
});

// Fix: Use Promises or async/await
```

**Long switch statements:**
```typescript
// P2: >10 cases
switch (action.type) {
  case 'ACTION_1': /* ... */ break;
  case 'ACTION_2': /* ... */ break;
  // ... 15 more cases
}

// Fix: Use strategy pattern or object lookup
```

### Dead Code Patterns

**Unused imports:**
```typescript
import React from 'react';        // Used
import { useState } from 'react'; // Unused - P3
```

**Dead branches:**
```typescript
if (false) {
  // Never executed - P3
}

const DEBUG = false;
if (DEBUG) {
  // Dead code - P3
}
```

## Go

### Duplication Patterns

**Error handling duplication:**
```go
// Bad: Repeated error handling
result1, err := operation1()
if err != nil {
    log.Printf("Error in operation1: %v", err)
    return nil, err
}

result2, err := operation2()
if err != nil {
    log.Printf("Error in operation2: %v", err)
    return nil, err
}

// Fix: Extract error handler
```

### Security Patterns

**SQL injection:**
```go
// Bad
query := "SELECT * FROM users WHERE id=" + userId  // P0
db.Query(query)

// Good
db.Query("SELECT * FROM users WHERE id=?", userId)
```

**Insecure TLS:**
```go
// Bad
&tls.Config{
    InsecureSkipVerify: true,  // P0
}

// Good
&tls.Config{
    MinVersion: tls.VersionTLS12,
}
```

### Complexity Patterns

**Deep interface nesting:**
```go
// P2: Multiple type assertions in one function
func process(data interface{}) {
    if v, ok := data.(map[string]interface{}); ok {
        if inner, ok := v["key"].([]interface{}); ok {
            if item, ok := inner[0].(string); ok {
                // 3 levels deep
            }
        }
    }
}
```

### Dead Code Patterns

**Unused imports:**
```go
import (
    "fmt"  // Used
    "os"   // Unused - P3
)
```

**Unreachable returns:**
```go
func process() error {
    return nil
    return errors.New("never reached")  // P3
}
```

## Rust

### Duplication Patterns

**Error conversion duplication:**
```rust
// Bad: Repeated error conversion logic
let file1 = File::open("file1.txt")
    .map_err(|e| format!("Failed to open file1: {}", e))?;

let file2 = File::open("file2.txt")
    .map_err(|e| format!("Failed to open file2: {}", e))?;

// Fix: Extract error conversion helper
```

### Security Patterns

**Unsafe blocks:**
```rust
// P1: Any unsafe block requires review
unsafe {
    // Requires careful audit
}
```

**Unwrap in production:**
```rust
// P2: Unwrap can panic
let value = result.unwrap();  // P2 - Use ? or match instead
```

### Complexity Patterns

**Deep match nesting:**
```rust
// P2: >4 levels
match outer {
    Some(x) => match x {
        Ok(y) => match y {
            Some(z) => match z {
                Valid(v) => {
                    // 4 levels deep
                }
                _ => {}
            }
            _ => {}
        }
        _ => {}
    }
    _ => {}
}

// Fix: Use if-let chains or early returns
```

## SQL

### Duplication Patterns

**Repeated CTEs:**
```sql
-- Bad: Same CTE in multiple queries
WITH active_users AS (
  SELECT * FROM users WHERE status = 'active'
)
SELECT * FROM active_users WHERE role = 'admin';

-- Same CTE repeated in another query
-- Fix: Create materialized view
```

### Security Patterns

**SQL injection in dynamic SQL:**
```sql
-- Bad: String concatenation
EXECUTE 'SELECT * FROM ' || table_name;  -- P0

-- Good: Use prepared statements
```

### Complexity Patterns

**Overly complex queries:**
```sql
-- P1: >5 JOINs in single query
-- P2: >3 subqueries nested
-- Fix: Break into CTEs or temporary tables
```

## Cross-Language Patterns

### Magic Numbers

**Pattern:** Unexplained numeric constants
```
# Any language
timeout = 3600  # P3 - Should be named constant
rate_limit = 100  # P3 - Should be config
```

### TODOs and FIXMEs

**Pattern:** Age-based tracking
```
# P1: >90 days old
# P2: >30 days old
# P3: <30 days old

# Use git blame to determine age:
git blame -L <line>,<line> <file> | awk '{print $1}' | xargs git show -s --format=%ci
```

### Long Functions

**Universal threshold:**
- P1: >150 lines (any language)
- P2: >75 lines (any language)

### Commented-Out Code

**Pattern:** Code blocks commented instead of deleted
```
// P3: Remove dead code, rely on git history
/*
def old_implementation():
    # 50 lines of commented code
*/
```

## Detection Tools by Language

| Language | Duplication | Security | Complexity | Dead Code |
|----------|-------------|----------|------------|-----------|
| Python | `ast-grep`, `jscpd` | `bandit`, `semgrep` | `radon`, `mccabe` | `vulture`, `pylint` |
| JavaScript | `jscpd`, `ast-grep` | `eslint-plugin-security` | `eslint` | `eslint` |
| TypeScript | `jscpd`, `ast-grep` | `eslint-plugin-security` | `eslint` | `eslint` |
| Go | `gocyclo`, `ast-grep` | `gosec`, `staticcheck` | `gocyclo` | `golangci-lint` |
| Rust | `ast-grep` | `cargo-audit`, `clippy` | `cargo-clippy` | `cargo-clippy` |
| Java | `pmd`, `jscpd` | `spotbugs`, `pmd` | `pmd` | `pmd` |

## Custom Pattern Matching

For languages without specialized tools, use regex patterns:

```python
# Hardcoded secrets (universal)
r'(password|passwd|pwd|secret|token|api[_-]?key)\s*=\s*["\'][^"\']{8,}["\']'

# SQL injection markers (universal)
r'(execute|query|sql)\s*\(\s*["\'].*?\+.*?["\']'

# Magic numbers (universal, excluding 0, 1, -1, 100, 1000)
r'\b(?!0\b|1\b|-1\b|100\b|1000\b)\d{2,}\b'
```
