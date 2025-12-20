# data-processing Functional Tests

Verify jq and yq commands work correctly.

## Prerequisites

```bash
# Check tools are installed
jq --version   # jq-1.7+
yq --version   # yq 4.x (Mike Farah's version)
```

---

## jq Tests

### Test 1: Extract single field

```bash
echo '{"name": "test-app", "version": "1.0.0"}' | jq '.name'
```

**Expected:** `"test-app"`

### Test 2: Extract nested field

```bash
echo '{"scripts": {"build": "tsc", "test": "jest"}}' | jq '.scripts.build'
```

**Expected:** `"tsc"`

### Test 3: Array filtering

```bash
echo '{"users": [{"name": "Alice", "active": true}, {"name": "Bob", "active": false}]}' | jq '.users[] | select(.active == true) | .name'
```

**Expected:** `"Alice"`

### Test 4: Count array length

```bash
echo '{"items": [1, 2, 3, 4, 5]}' | jq '.items | length'
```

**Expected:** `5`

### Test 5: Raw string output

```bash
echo '{"name": "myapp"}' | jq -r '.name'
```

**Expected:** `myapp` (no quotes)

### Test 6: Transform with map

```bash
echo '{"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}' | jq '.users | map({id, name})'
```

**Expected:** Array with id and name objects

---

## yq Tests

### Test 7: Extract YAML field

```bash
echo 'name: myapp
version: 2.0.0' | yq '.name'
```

**Expected:** `myapp`

### Test 8: List keys

```bash
echo 'database:
  host: localhost
  port: 5432' | yq '.database | keys'
```

**Expected:** `- host` and `- port`

### Test 9: Docker Compose services

```bash
echo 'services:
  web:
    image: nginx
  db:
    image: postgres' | yq '.services | keys'
```

**Expected:** `- web` and `- db`

### Test 10: TOML parsing

```bash
echo '[package]
name = "myapp"
version = "1.0.0"' | yq -p toml '.package.name'
```

**Expected:** `myapp`

---

## Integration Test

### Test: Process package.json

Create a test file and verify full workflow:

```bash
cat > /tmp/test-package.json << 'EOF'
{
  "name": "test-project",
  "version": "1.0.0",
  "dependencies": {
    "express": "^4.18.0",
    "lodash": "^4.17.21"
  },
  "scripts": {
    "start": "node index.js",
    "test": "jest"
  }
}
EOF

# Extract dependencies
jq '.dependencies | keys' /tmp/test-package.json

# Extract scripts
jq '.scripts' /tmp/test-package.json

# Get version as raw string
jq -r '.version' /tmp/test-package.json

# Cleanup
rm /tmp/test-package.json
```

**Expected:**
- Dependencies: `["express", "lodash"]`
- Scripts: Object with start and test
- Version: `1.0.0`
