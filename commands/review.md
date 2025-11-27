---
description: "Code review staged changes or specific files. Analyzes for bugs, style issues, security concerns, and suggests improvements."
---

# Review - AI Code Review

Perform a comprehensive code review on staged changes or specific files.

## Arguments

$ARGUMENTS

- No args: Review staged changes (`git diff --cached`)
- File path: Review specific file
- Directory: Review all files in directory
- `--all`: Review all uncommitted changes

## What This Command Does

1. **Identify Target Code**
   - Staged changes (default)
   - Specific files/directories
   - All uncommitted changes

2. **Analyze For**
   - Bugs and logic errors
   - Security vulnerabilities
   - Performance issues
   - Style/convention violations
   - Missing error handling
   - Code smells

3. **Provide Feedback**
   - Issue severity (critical, warning, suggestion)
   - Line-specific comments
   - Suggested fixes
   - Overall assessment

## Execution Steps

### Step 1: Determine Scope

```bash
# Default: staged changes
git diff --cached --name-only

# If no staged changes, prompt user
git status --short
```

### Step 2: Get Diff Content

```bash
# For staged changes
git diff --cached

# For specific file
git diff HEAD -- <file>

# For all changes
git diff HEAD
```

### Step 3: Analyze Code

For each changed file, analyze:

**Bugs & Logic**
- Null/undefined checks
- Off-by-one errors
- Race conditions
- Unhandled edge cases

**Security**
- SQL injection
- XSS vulnerabilities
- Hardcoded secrets
- Insecure dependencies

**Performance**
- N+1 queries
- Unnecessary re-renders
- Memory leaks
- Blocking operations

**Style**
- Naming conventions
- Code organization
- Documentation gaps
- Dead code

### Step 4: Format Output

```markdown
# Code Review: <scope>

## Summary
- Files reviewed: N
- Issues found: X (Y critical, Z warnings)

## Critical Issues 🔴

### <filename>:<line>
**Issue**: <description>
**Risk**: <what could go wrong>
**Fix**:
\`\`\`diff
- <old code>
+ <suggested fix>
\`\`\`

## Warnings 🟡

### <filename>:<line>
**Issue**: <description>
**Suggestion**: <how to improve>

## Suggestions 🔵

### <filename>:<line>
**Suggestion**: <minor improvement>

## Overall Assessment

<1-2 sentence summary>

**Ready to commit?** Yes/No - <reasoning>
```

## Usage Examples

```bash
# Review staged changes
/review

# Review specific file
/review src/auth/login.ts

# Review directory
/review src/components/

# Review all uncommitted changes
/review --all

# Review with specific focus
/review --security
/review --performance
```

## Focus Flags

| Flag | Focus Area |
|------|------------|
| `--security` | Security vulnerabilities only |
| `--performance` | Performance issues only |
| `--style` | Style and conventions only |
| `--bugs` | Logic errors and bugs only |
| `--all-checks` | Everything (default) |

## Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| 🔴 Critical | Must fix before merge | Blocking |
| 🟡 Warning | Should address | Recommended |
| 🔵 Suggestion | Nice to have | Optional |

## Framework-Specific Checks

### React/Next.js
- Hook rules violations
- Missing dependencies in useEffect
- Key prop issues in lists
- Server/client component boundaries

### TypeScript
- `any` type usage
- Missing type annotations
- Incorrect generic constraints
- Type assertion abuse

### Node.js
- Unhandled promise rejections
- Sync operations in async context
- Memory leak patterns
- Insecure eval/exec usage

### Python
- Mutable default arguments
- Bare except clauses
- Resource leaks
- SQL string formatting

## Integration

Works well with:
- `/test` - Generate tests for flagged issues
- `/explain` - Deep dive into complex code
- `/checkpoint` - Save state before fixing issues

## Notes

- Reviews are suggestions, not absolute rules
- Context matters - some "issues" may be intentional
- Use `--verbose` for detailed explanations
- Reviews don't modify code - you decide what to fix
