# Find Replace Skill

Modern find-and-replace using sd (simpler than sed) and batch replacement patterns.

## Triggers

sd, find replace, batch replace, sed replacement, string replacement, rename

## sd Basics

### Simple Replacement
```bash
# Replace in file (in-place)
sd 'oldText' 'newText' file.txt

# Replace in multiple files
sd 'oldText' 'newText' *.js

# Preview without changing (pipe instead of file)
cat file.txt | sd 'old' 'new'
```

### sd vs sed Comparison

| sed | sd | Notes |
|-----|-----|-------|
| `sed 's/old/new/g'` | `sd 'old' 'new'` | Global by default |
| `sed -i 's/old/new/g'` | `sd 'old' 'new' file` | In-place by default |
| `sed 's/\./dot/g'` | `sd '\.' 'dot'` | Same escaping |
| `sed 's#path/to#new/path#g'` | `sd 'path/to' 'new/path'` | No delimiter issues |

## Common Patterns

### Variable Rename
```bash
# Rename variable across files
sd 'oldVarName' 'newVarName' src/**/*.ts

# Preview first with rg
rg 'oldVarName' src/
# Then apply
sd 'oldVarName' 'newVarName' $(rg -l 'oldVarName' src/)
```

### Function Rename
```bash
# Rename function (all usages)
sd 'getUserData' 'fetchUserProfile' src/**/*.ts

# More precise with word boundaries
sd '\bgetUserData\b' 'fetchUserProfile' src/**/*.ts
```

### Import Path Update
```bash
# Update import paths
sd "from '../utils'" "from '@/utils'" src/**/*.ts
sd "require\('./config'\)" "require('@/config')" src/**/*.js
```

### String Quotes
```bash
# Single to double quotes
sd "'" '"' file.json

# Template literals
sd '"\$\{(\w+)\}"' '`${$1}`' src/**/*.ts
```

## Regex Patterns

### Capture Groups
```bash
# Reorder parts
sd '(\w+)@(\w+)\.com' '$2/$1' emails.txt
# john@example.com → example/john

# Wrap in function
sd 'console\.log\((.*)\)' 'logger.info($1)' src/**/*.js
```

### Optional Matching
```bash
# Handle optional whitespace
sd 'function\s*\(' 'const fn = (' src/**/*.js
```

### Multiline (with -s flag)
```bash
# Replace across lines
sd -s 'start\n.*\nend' 'replacement' file.txt
```

## Batch Workflows

### Find Then Replace
```bash
# 1. Find files with pattern
rg -l 'oldPattern' src/

# 2. Preview replacements
rg 'oldPattern' -r 'newPattern' src/

# 3. Apply to found files
sd 'oldPattern' 'newPattern' $(rg -l 'oldPattern' src/)
```

### With fd
```bash
# Replace in specific file types
fd -e ts -x sd 'old' 'new' {}

# Replace in files matching name pattern
fd 'config' -e json -x sd '"dev"' '"prod"' {}
```

### Dry Run Pattern
```bash
# Safe workflow: preview → verify → apply

# Step 1: List affected files
rg -l 'oldText' src/

# Step 2: Show what will change
rg 'oldText' -r 'newText' src/

# Step 3: Apply (only after verification)
sd 'oldText' 'newText' $(rg -l 'oldText' src/)

# Step 4: Verify
rg 'oldText' src/  # Should return nothing
git diff           # Review changes
```

## Special Characters

### Escaping
```bash
# Literal dot
sd '\.' ',' file.txt

# Literal brackets
sd '\[' '(' file.txt

# Literal dollar sign
sd '\$' '€' file.txt

# Literal backslash
sd '\\' '/' paths.txt
```

### Common Escapes
| Character | Escape |
|-----------|--------|
| `.` | `\.` |
| `*` | `\*` |
| `?` | `\?` |
| `[` `]` | `\[` `\]` |
| `(` `)` | `\(` `\)` |
| `{` `}` | `\{` `\}` |
| `$` | `\$` |
| `^` | `\^` |
| `\` | `\\` |

## Real-World Examples

### Update Package Version
```bash
sd '"version": "\d+\.\d+\.\d+"' '"version": "2.0.0"' package.json
```

### Fix File Extensions in Imports
```bash
sd "from '(\./[^']+)'" "from '\$1.js'" src/**/*.ts
```

### Convert CSS Class Names
```bash
# kebab-case to camelCase (simple cases)
sd 'class="(\w+)-(\w+)"' 'className="$1$2"' src/**/*.jsx
```

### Update API Endpoints
```bash
sd '/api/v1/' '/api/v2/' src/**/*.ts
sd 'api\.example\.com' 'api.newdomain.com' src/**/*.ts
```

### Remove Console Logs
```bash
# Remove entire console.log statements
sd 'console\.log\([^)]*\);?\n?' '' src/**/*.ts
```

### Add Prefix to IDs
```bash
sd 'id="(\w+)"' 'id="prefix-$1"' src/**/*.html
```

## Tips

| Tip | Why |
|-----|-----|
| Always preview with `rg -r` first | Avoid accidental mass changes |
| Use `git diff` after | Verify changes before commit |
| Prefer specific patterns | `\bword\b` over `word` to avoid partial matches |
| Quote patterns | Avoid shell interpretation |
| Use fd to target files | More precise than `**/*.ext` |

## Installation

```bash
# Cargo (Rust)
cargo install sd

# Homebrew (macOS)
brew install sd

# Windows (scoop)
scoop install sd
```
