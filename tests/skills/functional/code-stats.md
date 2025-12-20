# code-stats Functional Tests

Verify tokei and difft commands work correctly.

## Prerequisites

```bash
# Check tools are installed
tokei --version   # tokei 12.x+
difft --version   # difftastic 0.50+
```

---

## tokei Tests

### Test 1: Basic line count

```bash
tokei .
```

**Expected:** Table showing:
- Languages detected
- Files count per language
- Lines of code, comments, blanks

### Test 2: Specific language

```bash
tokei -t=TypeScript .
```

**Expected:** Only TypeScript file statistics

### Test 3: Compact output

```bash
tokei --compact .
```

**Expected:** Single-line per language format

### Test 4: Exclude directories

```bash
tokei -e node_modules -e .git .
```

**Expected:** Stats excluding node_modules and .git

### Test 5: JSON output

```bash
tokei -o json . | jq '.TypeScript'
```

**Expected:** JSON with language breakdown

---

## difft (difftastic) Tests

### Test 6: Compare two files

```bash
# Create test files
cat > /tmp/old.js << 'EOF'
function greet(name) {
  console.log("Hello, " + name);
}
EOF

cat > /tmp/new.js << 'EOF'
function greet(name) {
  console.log(`Hello, ${name}!`);
}
EOF

difft /tmp/old.js /tmp/new.js

rm /tmp/old.js /tmp/new.js
```

**Expected:** AST-aware diff showing string template change

### Test 7: Compare with syntax highlighting

```bash
cat > /tmp/v1.py << 'EOF'
def add(a, b):
    return a + b
EOF

cat > /tmp/v2.py << 'EOF'
def add(a: int, b: int) -> int:
    return a + b
EOF

difft /tmp/v1.py /tmp/v2.py

rm /tmp/v1.py /tmp/v2.py
```

**Expected:** Shows type annotation additions

### Test 8: Git integration

```bash
# Configure difft as git diff tool (if not already set)
git config diff.external difft

# Run git diff (reverts after test)
GIT_EXTERNAL_DIFF=difft git diff HEAD~1 --stat
```

**Expected:** Semantic diff output

---

## Integration Tests

### Test 9: Full codebase analysis

```bash
# Get overview
tokei --compact .

# Get detailed breakdown
tokei --files .
```

**Expected:** Complete statistics for the project

### Test 10: Compare versions

```bash
# Compare current file with previous commit
difft <(git show HEAD~1:package.json 2>/dev/null || echo '{}') package.json
```

**Expected:** Diff between versions (or error if file doesn't exist in history)

---

## Performance Test

### Test 11: Large codebase timing

```bash
time tokei . --compact
```

**Expected:** Completes in under 2 seconds for most projects
