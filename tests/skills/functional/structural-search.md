# structural-search Functional Tests

Verify ast-grep (sg) commands work correctly.

## Prerequisites

```bash
# Check tool is installed
sg --version   # ast-grep 0.20+
```

---

## Basic Pattern Matching

### Test 1: Find console.log calls

```bash
# Create test file
cat > /tmp/test.js << 'EOF'
function example() {
  console.log("hello");
  console.error("error");
  console.log("world");
}
EOF

sg -p 'console.log($MSG)' /tmp/test.js

rm /tmp/test.js
```

**Expected:** Matches two console.log calls

### Test 2: Find function declarations

```bash
cat > /tmp/test.js << 'EOF'
function add(a, b) { return a + b; }
const multiply = (a, b) => a * b;
function subtract(a, b) { return a - b; }
EOF

sg -p 'function $NAME($$$ARGS) { $$$BODY }' /tmp/test.js

rm /tmp/test.js
```

**Expected:** Matches add and subtract functions

### Test 3: Find imports

```bash
cat > /tmp/test.js << 'EOF'
import React from 'react';
import { useState, useEffect } from 'react';
import lodash from 'lodash';
EOF

sg -p "import $NAME from 'react'" /tmp/test.js

rm /tmp/test.js
```

**Expected:** Matches first React import

---

## Multi-variable Patterns

### Test 4: Find async functions

```bash
cat > /tmp/test.js << 'EOF'
async function fetchData() {
  const response = await fetch('/api');
  return response.json();
}

function syncFunction() {
  return "sync";
}
EOF

sg -p 'async function $NAME($$$) { $$$BODY }' /tmp/test.js

rm /tmp/test.js
```

**Expected:** Matches fetchData only

### Test 5: Find try-catch blocks

```bash
cat > /tmp/test.js << 'EOF'
try {
  riskyOperation();
} catch (error) {
  console.error(error);
}
EOF

sg -p 'try { $$$TRY } catch ($ERR) { $$$CATCH }' /tmp/test.js

rm /tmp/test.js
```

**Expected:** Matches the try-catch block

---

## Python Patterns

### Test 6: Find Python function definitions

```bash
cat > /tmp/test.py << 'EOF'
def greet(name):
    return f"Hello, {name}"

async def fetch_data():
    return await get_api()
EOF

sg -p 'def $NAME($$$ARGS): $$$BODY' -l python /tmp/test.py

rm /tmp/test.py
```

**Expected:** Matches greet function

---

## Refactoring Tests

### Test 7: Replace pattern (dry run)

```bash
cat > /tmp/test.js << 'EOF'
console.log("debug1");
console.log("debug2");
EOF

sg -p 'console.log($MSG)' -r 'console.debug($MSG)' /tmp/test.js --dry-run

rm /tmp/test.js
```

**Expected:** Shows replacement preview without modifying file

---

## Integration Test

### Test: Search real codebase

```bash
# Find all React useState hooks
sg -p 'useState($INIT)' -l tsx .

# Find all async arrow functions
sg -p 'async ($$$) => { $$$BODY }' -l typescript .

# Find all imports from a package
sg -p "import { $$$NAMES } from '$PKG'" -l typescript .
```

**Expected:** Matches patterns across the codebase
