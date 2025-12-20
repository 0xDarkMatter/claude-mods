# git-workflow Functional Tests

Verify git workflow tools work correctly.

## Prerequisites

```bash
# Check tools are installed
lazygit --version   # lazygit 0.40+
gh --version        # gh 2.x
delta --version     # delta 0.16+
```

---

## gh (GitHub CLI) Tests

### Test 1: Check auth status

```bash
gh auth status
```

**Expected:** Shows authenticated user and scopes

### Test 2: List PRs

```bash
gh pr list --limit 3
```

**Expected:** List of open PRs or "no open pull requests"

### Test 3: View repo info

```bash
gh repo view --json name,description
```

**Expected:** JSON with repo name and description

### Test 4: List issues

```bash
gh issue list --limit 3
```

**Expected:** List of open issues or "no open issues"

---

## delta Tests

### Test 5: Diff with syntax highlighting

```bash
# Create test files
echo 'function hello() { console.log("hello"); }' > /tmp/test1.js
echo 'function hello() { console.log("world"); }' > /tmp/test2.js

# Run delta
diff -u /tmp/test1.js /tmp/test2.js | delta

# Cleanup
rm /tmp/test1.js /tmp/test2.js
```

**Expected:** Colored diff output with syntax highlighting

### Test 6: Git diff with delta

```bash
# In a git repo with changes
git diff | delta
```

**Expected:** Syntax-highlighted diff (or empty if no changes)

---

## lazygit Tests

### Test 7: Launch lazygit (manual)

```bash
# In a git repository
lazygit
```

**Expected:** TUI interface opens showing:
- Status panel
- Files panel
- Branches panel
- Commits panel
- Stash panel

**Key bindings to verify:**
- `q` - Quit
- `?` - Help
- `Space` - Stage/unstage file
- `c` - Commit

---

## Integration Test

### Test: Full PR workflow

```bash
# 1. Check current branch
git branch --show-current

# 2. View recent commits
gh api repos/:owner/:repo/commits --jq '.[0:3] | .[].commit.message'

# 3. Check workflow runs
gh run list --limit 3

# 4. View PR checks (if PR exists)
gh pr checks
```

**Expected:** Each command returns relevant git/GitHub data
