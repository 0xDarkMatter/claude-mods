---
description: "Code review with semantic diffs, expert routing, and auto-TodoWrite. Analyzes staged changes or specific files for bugs, security, performance, and style."
---

# Review - AI Code Review

Perform a comprehensive code review on staged changes, specific files, or pull requests. Routes to expert agents based on file types, respects project conventions, and automatically creates TodoWrite tasks for critical issues.

## Arguments

$ARGUMENTS

- No args: Review staged changes (`git diff --cached`)
- `<file>`: Review specific file
- `<directory>`: Review all files in directory
- `--all`: Review all uncommitted changes
- `--pr <number>`: Review a GitHub PR
- `--focus <security|perf|types|tests|style>`: Focus on specific area
- `--depth <quick|normal|thorough>`: Review depth

## Architecture

```
/review [target] [--focus] [--depth]
    │
    ├─→ Step 1: Determine Scope
    │     ├─ No args → git diff --cached (staged)
    │     ├─ --all → git diff HEAD (all uncommitted)
    │     ├─ File path → specific file diff
    │     └─ --pr N → gh pr diff N
    │
    ├─→ Step 2: Analyze Changes (parallel)
    │     ├─ delta for syntax-highlighted diff
    │     ├─ difft for semantic diff (structural)
    │     ├─ Categorize: logic, style, test, docs, config
    │     └─ Identify touched modules/components
    │
    ├─→ Step 3: Load Project Standards
    │     ├─ AGENTS.md, CLAUDE.md conventions
    │     ├─ .eslintrc, .prettierrc, pyproject.toml
    │     ├─ Detect test framework
    │     └─ Check CI config for existing linting
    │
    ├─→ Step 4: Route to Expert Reviewers
    │     ├─ TypeScript → typescript-expert
    │     ├─ React/JSX → react-expert
    │     ├─ Python → python-expert
    │     ├─ Vue → vue-expert
    │     ├─ SQL/migrations → postgres-expert
    │     ├─ Claude extensions → claude-architect
    │     └─ Multi-domain → parallel expert dispatch
    │
    ├─→ Step 5: Generate Review
    │     ├─ Severity: CRITICAL / WARNING / SUGGESTION / PRAISE
    │     ├─ Line-specific comments (file:line refs)
    │     ├─ Suggested fixes as diff blocks
    │     └─ Overall verdict: Ready to commit? Y/N
    │
    └─→ Step 6: Integration
          ├─ Auto-create TodoWrite for CRITICAL issues
          ├─ Link to /save for tracking
          └─ Suggest follow-up: /test, /explain
```

## Execution Steps

### Step 1: Determine Scope

```bash
# Default: staged changes
git diff --cached --name-only

# Check if anything is staged
STAGED=$(git diff --cached --name-only | wc -l)
if [ "$STAGED" -eq 0 ]; then
    echo "No staged changes. Use --all for uncommitted or specify a file."
    git status --short
fi
```

**For PR review:**
```bash
gh pr diff $PR_NUMBER --patch
```

**For specific file:**
```bash
git diff HEAD -- "$FILE"
```

### Step 2: Analyze Changes

Run semantic diff analysis (parallel where possible):

**With difft (semantic):**
```bash
command -v difft >/dev/null 2>&1 && git difftool --tool=difftastic --no-prompt HEAD~1 || git diff HEAD~1
```

**With delta (syntax highlighting):**
```bash
command -v delta >/dev/null 2>&1 && git diff --cached | delta || git diff --cached
```

**Categorize changes:**
```bash
# Get changed files
git diff --cached --name-only | while read file; do
    case "$file" in
        *.test.* | *.spec.*) echo "TEST: $file" ;;
        *.md | docs/*) echo "DOCS: $file" ;;
        *.json | *.yaml | *.toml) echo "CONFIG: $file" ;;
        *) echo "CODE: $file" ;;
    esac
done
```

**Get diff statistics:**
```bash
git diff --cached --stat
```

### Step 3: Load Project Standards

**Check for project conventions:**
```bash
# Claude Code conventions
cat AGENTS.md 2>/dev/null | head -50
cat CLAUDE.md 2>/dev/null | head -50

# Linting configs
cat .eslintrc* 2>/dev/null | head -30
cat .prettierrc* 2>/dev/null
cat pyproject.toml 2>/dev/null | head -30

# Test framework detection
cat package.json 2>/dev/null | jq '.devDependencies | keys | map(select(test("jest|vitest|mocha|cypress|playwright")))' 2>/dev/null
cat pyproject.toml 2>/dev/null | grep -E "pytest|unittest" 2>/dev/null
```

**Check CI for existing linting:**
```bash
cat .github/workflows/*.yml 2>/dev/null | grep -E "eslint|prettier|pylint|ruff" | head -10
```

### Step 4: Route to Expert Reviewers

Determine experts based on changed files:

| File Pattern | Primary Expert | Secondary Expert |
|--------------|----------------|------------------|
| `*.ts` | typescript-expert | - |
| `*.tsx` | react-expert | typescript-expert |
| `*.vue` | vue-expert | typescript-expert |
| `*.py` | python-expert | sql-expert (if ORM) |
| `*.sql`, `migrations/*` | postgres-expert | - |
| `agents/*.md`, `skills/*`, `commands/*` | claude-architect | - |
| `*.test.*`, `*.spec.*` | cypress-expert | (framework expert) |
| `wrangler.toml`, `workers/*` | wrangler-expert | cloudflare-expert |
| `*.sh`, `*.bash` | bash-expert | - |

**Multi-domain changes:** If files span multiple domains, dispatch experts in parallel via Task tool.

**Invoke via Task tool:**
```
Task tool with subagent_type: "[detected]-expert"
Prompt includes:
  - Diff content
  - Project conventions from AGENTS.md
  - Linting config summaries
  - Requested focus area
  - Request for structured review output
```

### Step 5: Generate Review

The expert produces a structured review:

```markdown
# Code Review: [scope description]

## Summary

| Metric | Value |
|--------|-------|
| Files reviewed | N |
| Lines changed | +X / -Y |
| Issues found | N (X critical, Y warnings) |

## Verdict

**Ready to commit?** Yes / No

[1-2 sentence summary of overall quality]

---

## Critical Issues

### `src/auth/login.ts:42`

**Issue:** SQL injection vulnerability in user input handling

**Risk:** Attacker can execute arbitrary SQL queries

**Fix:**
```diff
- const query = `SELECT * FROM users WHERE id = ${userId}`;
+ const query = `SELECT * FROM users WHERE id = $1`;
+ const result = await db.query(query, [userId]);
```

---

## Warnings

### `src/components/Form.tsx:89`

**Issue:** Missing dependency in useEffect

**Suggestion:** Add `userId` to dependency array or use useCallback

```diff
- useEffect(() => { fetchUser(userId) }, []);
+ useEffect(() => { fetchUser(userId) }, [userId]);
```

---

## Suggestions

### `src/utils/helpers.ts:15`

**Suggestion:** Consider using optional chaining

```diff
- const name = user && user.profile && user.profile.name;
+ const name = user?.profile?.name;
```

---

## Praise

### `src/services/api.ts:78`

**Good pattern:** Proper error boundary with typed error handling. This is exactly the pattern we want to follow.

---

## Files Reviewed

| File | Changes | Issues |
|------|---------|--------|
| `src/auth/login.ts` | +42/-8 | 1 critical |
| `src/components/Form.tsx` | +89/-23 | 1 warning |
| `src/utils/helpers.ts` | +15/-3 | 1 suggestion |

## Follow-up

- Run `/test src/auth/` to verify security fix
- Run `/explain src/auth/login.ts` for deeper understanding
- Use `/save` to track these issues
```

### Step 6: Integration

**Auto-create TodoWrite tasks for CRITICAL issues:**

For each CRITICAL issue found, automatically add to TodoWrite:
```
TodoWrite:
  - content: "Fix: SQL injection in login.ts:42"
    status: "pending"
    activeForm: "Fixing SQL injection in login.ts:42"
```

**Link to session management:**
```
Issues have been added to your task list.
Run /save to persist before ending session.
```

## Severity System

| Level | Icon | Meaning | Action | Auto-Todo? |
|-------|------|---------|--------|------------|
| CRITICAL | :red_circle: | Security bug, data loss risk, crashes | Must fix before merge | Yes |
| WARNING | :yellow_circle: | Logic issues, performance problems | Should address | No |
| SUGGESTION | :blue_circle: | Style, minor improvements | Optional | No |
| PRAISE | :star: | Good patterns worth noting | Recognition | No |

## Focus Modes

| Mode | What It Checks |
|------|----------------|
| `--security` | OWASP top 10, secrets in code, injection, auth issues |
| `--perf` | N+1 queries, unnecessary re-renders, complexity, memory |
| `--types` | Type safety, `any` usage, generics, null handling |
| `--tests` | Coverage gaps, test quality, mocking patterns |
| `--style` | Naming, organization, dead code, comments |
| (default) | All of the above |

### Security Focus Example
```bash
/review --security
```
Checks for:
- Hardcoded secrets, API keys
- SQL/NoSQL injection
- XSS vulnerabilities
- Insecure dependencies
- Auth/authz issues
- CORS misconfigurations

### Performance Focus Example
```bash
/review --perf
```
Checks for:
- N+1 database queries
- Unnecessary re-renders (React)
- Memory leaks
- Blocking operations in async code
- Unoptimized algorithms

## Depth Modes

| Mode | Behavior |
|------|----------|
| `--quick` | Surface-level scan, obvious issues only |
| `--normal` | Standard review, all severity levels (default) |
| `--thorough` | Deep analysis, traces data flow, checks edge cases |

## CLI Tool Integration

| Tool | Purpose | Fallback |
|------|---------|----------|
| `delta` | Syntax-highlighted diffs | `git diff` |
| `difft` | Semantic/structural diffs | `git diff` |
| `gh` | GitHub PR operations | Manual diff |
| `rg` | Search for patterns | Grep tool |
| `jq` | Parse JSON configs | Read manually |

**Graceful degradation:**
```bash
command -v delta >/dev/null 2>&1 && git diff --cached | delta || git diff --cached
```

## Usage Examples

```bash
# Review staged changes (default)
/review

# Review all uncommitted changes
/review --all

# Review specific file
/review src/auth/login.ts

# Review a directory
/review src/components/

# Review a GitHub PR
/review --pr 123

# Security-focused review
/review --security

# Performance-focused review
/review --perf

# Quick scan before committing
/review --quick

# Thorough review for important changes
/review --thorough

# Combined: thorough security review of PR
/review --pr 456 --security --thorough
```

## Framework-Specific Checks

### React/Next.js
- Hook rules violations
- Missing useEffect dependencies
- Key prop issues in lists
- Server/client component boundaries
- Hydration mismatches

### TypeScript
- `any` type abuse
- Missing type annotations on exports
- Incorrect generic constraints
- Type assertion overuse (`as`)
- Null/undefined handling

### Python
- Mutable default arguments
- Bare `except:` clauses
- Resource leaks (files, connections)
- SQL string formatting
- Type hint inconsistencies

### Vue
- Reactivity gotchas
- Missing v-key in v-for
- Props mutation
- Composition API anti-patterns

### SQL/Database
- SQL injection risks
- N+1 query patterns
- Missing indexes
- Transaction handling
- Migration safety

## Integration

| Command | Relationship |
|---------|--------------|
| `/explain` | Deep dive into flagged code |
| `/test` | Generate tests for issues found |
| `/save` | Persist review findings to session state |
| Native `/plan` | Enter Claude Code's planning mode |

## Workflow Examples

### Pre-Commit Review
```bash
git add .
/review
# Fix issues...
git commit -m "feat: add user auth"
```

### PR Review Workflow
```bash
/review --pr 123 --thorough
# Creates TodoWrite tasks for critical issues
# Fix issues...
/save "Addressed review findings"
```

### Security Audit
```bash
/review src/ --security --thorough
# Comprehensive security scan of entire directory
```

## Notes

- Reviews are suggestions, not absolute rules
- Context matters - some "issues" may be intentional
- CRITICAL issues are auto-added to TodoWrite
- Use `/save` to persist review tasks across sessions
- Expert agents provide framework-specific insights
- Respects project conventions from AGENTS.md
