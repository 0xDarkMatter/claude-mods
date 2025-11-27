---
name: structural-search
description: Search code by AST structure using ast-grep. Find semantic patterns like function calls, imports, class definitions instead of text patterns. Triggers on: find all calls to X, search for pattern, refactor usages, find where function is used, structural search.
---

# Structural Search

## Purpose
Search code by its abstract syntax tree (AST) structure rather than plain text. Finds semantic patterns that regex cannot match reliably.

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| ast-grep | `ast-grep -p 'pattern'` | AST-aware code search |
| sg | `sg -p 'pattern'` | Short alias for ast-grep |

## Usage Examples

```bash
# Find all console.log calls
ast-grep -p 'console.log($_)'

# Find all function definitions
ast-grep -p 'function $NAME($_) { $$$ }'

# Find React useState hooks
ast-grep -p 'const [$_, $_] = useState($_)'

# Find Python function definitions
ast-grep -p 'def $NAME($_): $$$' --lang python

# Find all imports of a module
ast-grep -p 'import $_ from "react"'

# Search and show context
ast-grep -p 'fetch($_)' -A 3

# Search specific file types
ast-grep -p '$_.map($_)' --lang javascript
```

## Pattern Syntax

- `$NAME` - matches single identifier
- `$_` - matches any single node (wildcard)
- `$$$` - matches zero or more nodes
- `$$_` - matches one or more nodes

## When to Use

- Finding all usages of a function/method
- Locating specific code patterns (hooks, API calls)
- Preparing for refactoring
- Understanding code structure
- When regex would match false positives
