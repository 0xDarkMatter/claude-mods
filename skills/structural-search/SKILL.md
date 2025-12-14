---
name: structural-search
description: "Search code by AST structure using ast-grep. Find semantic patterns like function calls, imports, class definitions instead of text patterns. Triggers on: find all calls to X, search for pattern, refactor usages, find where function is used, structural search."
---

# Structural Search

## Purpose
Search code by its abstract syntax tree (AST) structure rather than plain text. Finds semantic patterns that regex cannot match reliably.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| ast-grep | `ast-grep -p 'pattern'` | AST-aware code search |
| sg | `sg -p 'pattern'` | Short alias for ast-grep |

## Pattern Syntax

| Pattern | Matches | Example |
|---------|---------|---------|
| `$NAME` | Single identifier | `function $NAME() {}` |
| `$_` | Any single node (wildcard) | `console.log($_)` |
| `$$$` | Zero or more nodes | `function $_($$$) { $$$ }` |
| `$$_` | One or more nodes | `[$_, $$_]` (non-empty array) |

## JavaScript/TypeScript Patterns

### Function Calls

```bash
# Find all console.log calls
sg -p 'console.log($_)'

# Find all console methods
sg -p 'console.$_($_)'

# Find fetch calls
sg -p 'fetch($_)'

# Find await fetch
sg -p 'await fetch($_)'

# Find specific function calls
sg -p 'getUserById($_)'

# Find method chaining
sg -p '$_.then($_).catch($_)'
```

### React Patterns

```bash
# Find useState hooks
sg -p 'const [$_, $_] = useState($_)'

# Find useEffect with dependencies
sg -p 'useEffect($_, [$$$])'

# Find useEffect without dependencies (runs every render)
sg -p 'useEffect($_, [])'

# Find component definitions
sg -p 'function $NAME($$$) { return <$$$> }'

# Find specific prop usage
sg -p '<Button onClick={$_}>'

# Find useState without destructuring
sg -p 'useState($_)'
```

### Imports

```bash
# Find all imports from a module
sg -p 'import $_ from "react"'

# Find named imports
sg -p 'import { $_ } from "lodash"'

# Find default and named imports
sg -p 'import $_, { $$$ } from $_'

# Find dynamic imports
sg -p 'import($_)'

# Find require calls
sg -p 'require($_)'
```

### Async Patterns

```bash
# Find async functions
sg -p 'async function $NAME($$$) { $$$ }'

# Find async arrow functions
sg -p 'async ($$$) => { $$$ }'

# Find try-catch blocks
sg -p 'try { $$$ } catch ($_) { $$$ }'

# Find Promise.all
sg -p 'Promise.all([$$$])'

# Find unhandled promises (no await)
sg -p '$_.then($_)'
```

### Error Prone Patterns

```bash
# Find == instead of ===
sg -p '$_ == $_'

# Find assignments in conditions
sg -p 'if ($_ = $_)'

# Find empty catch blocks
sg -p 'catch ($_) {}'

# Find console.log (for cleanup)
sg -p 'console.log($$$)'

# Find TODO comments
sg -p '// TODO$$$'

# Find debugger statements
sg -p 'debugger'
```

## Python Patterns

```bash
# Find function definitions
sg -p 'def $NAME($$$): $$$' --lang python

# Find class definitions
sg -p 'class $NAME: $$$' --lang python

# Find decorated functions
sg -p '@$_
def $NAME($$$): $$$' --lang python

# Find specific decorator
sg -p '@pytest.fixture
def $NAME($$$): $$$' --lang python

# Find imports
sg -p 'import $_' --lang python
sg -p 'from $_ import $_' --lang python

# Find f-strings
sg -p 'f"$$$"' --lang python

# Find list comprehensions
sg -p '[$_ for $_ in $_]' --lang python

# Find with statements
sg -p 'with $_ as $_: $$$' --lang python

# Find async definitions
sg -p 'async def $NAME($$$): $$$' --lang python
```

## Go Patterns

```bash
# Find function declarations
sg -p 'func $NAME($$$) $_ { $$$ }' --lang go

# Find method declarations
sg -p 'func ($_ $_) $NAME($$$) $_ { $$$ }' --lang go

# Find interface definitions
sg -p 'type $NAME interface { $$$ }' --lang go

# Find struct definitions
sg -p 'type $NAME struct { $$$ }' --lang go

# Find error handling
sg -p 'if err != nil { $$$ }' --lang go

# Find defer statements
sg -p 'defer $_' --lang go

# Find goroutines
sg -p 'go $_' --lang go
```

## Rust Patterns

```bash
# Find function definitions
sg -p 'fn $NAME($$$) -> $_ { $$$ }' --lang rust

# Find impl blocks
sg -p 'impl $_ for $_ { $$$ }' --lang rust

# Find match expressions
sg -p 'match $_ { $$$ }' --lang rust

# Find unwrap calls (potential panics)
sg -p '$_.unwrap()' --lang rust

# Find Result/Option handling
sg -p '$_?' --lang rust
```

## Refactoring Patterns

### Find and Replace

```bash
# Preview replacement
sg -p 'console.log($_)' -r 'logger.info($_)'

# Replace in place
sg -p 'console.log($_)' -r 'logger.info($_)' --rewrite

# Replace with context
sg -p 'var $NAME = $_' -r 'const $NAME = $_'
```

### Common Refactors

```bash
# Convert function to arrow
sg -p 'function $NAME($ARGS) { return $BODY }' \
   -r 'const $NAME = ($ARGS) => $BODY'

# Convert require to import
sg -p 'const $NAME = require("$MOD")' \
   -r 'import $NAME from "$MOD"'

# Add optional chaining
sg -p '$OBJ.$PROP' -r '$OBJ?.$PROP'
```

## Security Patterns

### SQL Injection

```bash
# Find string concatenation in queries
sg -p 'query($_ + $_)'
sg -p 'execute("$$$" + $_)'

# Find template literals in queries
sg -p 'query(`$$$${$_}$$$`)'
```

### XSS Vectors

```bash
# Find innerHTML assignments
sg -p '$_.innerHTML = $_'

# Find dangerouslySetInnerHTML
sg -p 'dangerouslySetInnerHTML={{ __html: $_ }}'

# Find eval calls
sg -p 'eval($_)'

# Find document.write
sg -p 'document.write($_)'
```

### Secrets/Credentials

```bash
# Find hardcoded passwords
sg -p 'password = "$_"'
sg -p 'password: "$_"'

# Find API keys
sg -p 'apiKey = "$_"'
sg -p 'API_KEY = "$_"'
```

## Advanced Usage

### Context and Output

```bash
# Show surrounding lines
sg -p 'console.log($_)' -A 3

# JSON output
sg -p 'console.log($_)' --json

# File names only
sg -p 'TODO' -l

# Count matches
sg -p 'console.log($_)' --count
```

### Combining with Other Tools

```bash
# Find and process with jq
sg -p 'fetch($_)' --json | jq '.matches[].file'

# Find in specific files
fd -e ts | xargs sg -p 'useState($_)'

# Interactive selection
sg -p 'console.log($_)' -l | fzf | xargs code
```

### YAML Rules (Reusable Patterns)

Create `.ast-grep.yml` for complex patterns:

```yaml
id: no-console-log
language: typescript
rule:
  pattern: console.log($$$)
message: Remove console.log before committing
severity: warning
```

Run with:
```bash
sg scan
```

## Quick Reference

| Task | Command |
|------|---------|
| Find pattern | `sg -p 'pattern'` |
| Specific language | `sg -p 'pattern' --lang python` |
| Replace (preview) | `sg -p 'old' -r 'new'` |
| Replace (apply) | `sg -p 'old' -r 'new' --rewrite` |
| Show context | `sg -p 'pattern' -A 3` |
| JSON output | `sg -p 'pattern' --json` |
| File list only | `sg -p 'pattern' -l` |
| Count matches | `sg -p 'pattern' --count` |

## When to Use

- Finding all usages of a function/method
- Locating specific code patterns (hooks, API calls)
- Preparing for large-scale refactoring
- Understanding code structure
- When regex would match false positives
- Detecting anti-patterns and security issues
- Creating custom linting rules
