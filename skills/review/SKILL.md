---
name: review
description: "Code review with semantic diffs, expert routing, and auto-TaskCreate. Triggers on: code review, review changes, check code, review PR, security audit."
when_to_use: "Use when the user asks for a code review of staged changes, specific files, or a PR — e.g. 'review my changes', 'check this code before commit', 'security audit this diff', 'review PR 12'."
argument-hint: "[target|--all|--pr N] [--security|--perf|--types|--tests|--style] [--quick|--thorough] [--base <branch>] [--second-opinion] [--json]"
effort: high
license: MIT
allowed-tools: "Read Write Edit Bash Glob Grep Task TaskCreate TaskUpdate"
metadata:
  author: claude-mods
---

# Review Skill - AI Code Review

Perform comprehensive code reviews on staged changes, specific files, or pull requests. States the change's intent first, dispatches general-purpose reviewers that preload the relevant `-ops` skill based on file types, then runs a lead-judgment pass that sorts every finding before the user sees it, and creates tasks for the ones to act on.

## Architecture

```
review [target] [--focus] [--depth]
    │
    ├─→ Step 1: Determine Scope
    │     ├─ No args → git diff --cached (staged)
    │     ├─ --all → git diff HEAD (all uncommitted)
    │     ├─ File path → specific file diff
    │     └─ --pr N → gh pr diff N
    │
    ├─→ Step 2: State the Intent
    │     ├─ 1-2 sentences: PR body, commits, the user's request
    │     └─ Unclear (interactive) → ask before reviewing
    │
    ├─→ Step 3: Analyze Changes (parallel)
    │     ├─ delta for syntax-highlighted diff
    │     ├─ difft for semantic diff (structural)
    │     ├─ Categorize: logic, style, test, docs, config
    │     └─ Identify touched modules/components
    │
    ├─→ Step 4: Load Project Standards
    │     ├─ AGENTS.md, CLAUDE.md conventions
    │     ├─ .eslintrc, .prettierrc, pyproject.toml
    │     ├─ Detect test framework
    │     └─ Check CI config for existing linting
    │
    ├─→ Step 5: Route to Reviewers (general-purpose + skill preload)
    │     ├─ TypeScript → general-purpose, preload typescript-ops
    │     ├─ React/JSX → general-purpose, preload react-ops
    │     ├─ Python → general-purpose, preload python-pytest-ops
    │     ├─ Go → general-purpose, preload go-ops
    │     ├─ Rust → general-purpose, preload rust-ops
    │     ├─ Vue → general-purpose, preload vue-ops
    │     ├─ SQL/migrations → general-purpose, preload postgres-ops
    │     ├─ Cypress/E2E → general-purpose, preload cypress-ops
    │     ├─ Cloudflare/Workers → general-purpose, preload cloudflare-ops
    │     ├─ Shell/bash → general-purpose, preload bash-ops
    │     ├─ Claude extensions → general-purpose, preload claude-code-ops
    │     ├─ Multi-domain → parallel general-purpose dispatch
    │     ├─ All reviewers preload: security-ops + testing-ops context
    │     └─ --second-opinion → one more reviewer, other model family
    │
    ├─→ Step 6: Lead Judgment
    │     ├─ Check each finding against the repo and the intent
    │     ├─ Sort: act on / consider / noted / dismissed (with reason)
    │     └─ > ~5 act on = filter too loose; no findings is valid
    │
    ├─→ Step 7: Generate Review
    │     ├─ Severity (reviewer): CRITICAL / WARNING / SUGGESTION
    │     ├─ Bucket (lead): the section each finding appears in
    │     ├─ Line-specific comments (file:line refs)
    │     ├─ Suggested fixes as diff blocks
    │     └─ Verdict: ready to commit only when Act On is empty
    │
    └─→ Step 8: Integration
          ├─ Auto-create tasks (TaskCreate) for Act On items
          ├─ Link to /save for tracking
          └─ Suggest follow-up: /testgen, /explain
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

**For baseline comparison (--base):**
```bash
git diff $BASE_BRANCH...HEAD
```

### Step 2: State the Intent

Before any reviewer runs, write one or two sentences on what the change is meant to do. Take it from the PR body (`gh pr view N --json title,body`), the commit messages (`git log --format=%B $BASE_BRANCH..HEAD`) or the user's request; mark it *inferred* when only the diff supports it. If the sources disagree, or the purpose is unclear in an interactive session, ask before reviewing. Every reviewer gets this statement, and Step 6 judges each finding against it ([references/lead-judgment.md](references/lead-judgment.md)).

### Step 3: Analyze Changes

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

### Step 4: Load Project Standards

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
```

**Check CI for existing linting:**
```bash
cat .github/workflows/*.yml 2>/dev/null | grep -E "eslint|prettier|pylint|ruff" | head -10
```

### Step 5: Route to Reviewers

Dispatch is skills-first: domain knowledge lives in `-ops` skills, and the generic `general-purpose` subagent preloads the relevant SKILL.md before reviewing.

| File Pattern | Dispatch | Preload |
|--------------|----------|---------|
| `*.ts` | general-purpose | `skills/typescript-ops/SKILL.md` |
| `*.tsx` | general-purpose | `skills/react-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.vue` | general-purpose | `skills/vue-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.py` | general-purpose | `skills/python-pytest-ops/SKILL.md` (+ `skills/sql-ops/SKILL.md` if ORM) |
| `*.go` | general-purpose | `skills/go-ops/SKILL.md` |
| `*.rs` | general-purpose | `skills/rust-ops/SKILL.md` |
| `*.sql`, `migrations/*` | general-purpose | `skills/postgres-ops/SKILL.md` |
| `agents/*.md`, `skills/*`, `commands/*` | general-purpose | `skills/claude-code-ops/SKILL.md` |
| `*.test.*`, `*.spec.*` | general-purpose | (framework skill by file type) |
| `*.cy.ts`, `cypress/*` | general-purpose | `skills/cypress-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `*.spec.ts` (Playwright) | general-purpose | `skills/playwright-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `playwright/*`, `e2e/*` | general-purpose | `skills/playwright-ops/SKILL.md` + `skills/typescript-ops/SKILL.md` |
| `wrangler.toml`, `workers/*` | general-purpose | `skills/cloudflare-ops/SKILL.md` |
| `*.sh`, `*.bash` | general-purpose | `skills/bash-ops/SKILL.md` |

**Invoke via the Agent tool:**
```
Agent tool with subagent_type: "general-purpose" (or surviving specialist from table)
model: "sonnet"
Prompt includes:
  - Skill preloading (domain knowledge):
    "First, read these files for review context:
     - Read: skills/security-ops/references/owasp-top10-a01-a05.md
     - Read: skills/security-ops/references/owasp-top10-a06-a10.md
     - Read: skills/testing-ops/SKILL.md
     - Read: [Preload column for the matched file pattern]"
  - The intent statement from Step 2: test whether the change achieves it,
    not whether the goal is right
  - Diff content
  - Project conventions from AGENTS.md
  - Linting config summaries
  - Requested focus area
  - Output: per finding, severity, file:line, the evidence, and a fix only
    when a concrete one exists. "No findings" when nothing is wrong; no
    padding, no praise
```

**Language-specific preloads** (append to the preloading section above):

| Language | Additional Preload | Why |
|----------|-------------------|-----|
| Python | `skills/python-pytest-ops/SKILL.md` | Python test patterns for coverage review |
| Go | `skills/go-ops/SKILL.md` | Go idioms, concurrency gotchas |
| Rust | `skills/rust-ops/SKILL.md` | Ownership patterns, unsafe review |
| TypeScript | `skills/typescript-ops/SKILL.md` | Type safety patterns |

**Second reviewer (`--second-opinion`).** Dispatch one more reviewer from a different model family with the same intent, diff and output format, independent of the first, so Step 6 can map where they agree. Without the flag, the lead offers it for high-risk or contested changes. When, how, and how to read the agreement: [references/lead-judgment.md](references/lead-judgment.md).

### Step 6: Lead Judgment

The session running the review is the lead, not a relay. Reviewers are asked to find problems and report some either way; the lead holds the repo and the intent, and decides what each finding is worth. Follow [references/lead-judgment.md](references/lead-judgment.md):

1. Merge duplicates, then check each finding against the real code: a reachable path, the codebase's own conventions, the change's scope, and whether it would block a merge.
2. Sort every finding into one bucket:

| Bucket | Meaning |
|--------|---------|
| **Act on** | Confirmed defect that would block a merge, given the intent |
| **Consider** | Real or unconfirmed, and the cost of fixing now is unclear; the user decides |
| **Noted** | True, but not worth action now |
| **Dismissed** | Wrong, out of scope, taste, or missing context, each with its reason |

3. Calibrate. More than about five act-on items means the filter is too loose: re-check and demote. An empty result is valid: report "No findings" and the scope covered. Praise is never a finding.

### Step 7: Generate Review

The lead writes the review from the sorted findings:

```markdown
# Code Review: [scope description]

**Intent:** [1-2 sentences from Step 2; *inferred* if only the diff supports it]

## Summary

| Metric | Value |
|--------|-------|
| Files reviewed | N |
| Lines changed | +X / -Y |
| Findings | N raised: A act on, C consider, O noted, D dismissed |

## Verdict

**Ready to commit?** Yes / No (Yes only when Act On is empty)

[1-2 sentences. With nothing left after Step 6: "No findings", plus the scope covered.]

---

## Act On

### :red_circle: CRITICAL `src/auth/login.ts:42`

**Issue:** SQL injection vulnerability in user input handling

**Risk:** Attacker can execute arbitrary SQL queries (path: `POST /login` → `findUser(req.body.id)`)

**Fix:**
```diff
- const query = `SELECT * FROM users WHERE id = ${userId}`;
+ const query = `SELECT * FROM users WHERE id = $1`;
+ const result = await db.query(query, [userId]);
```

### :yellow_circle: WARNING `src/components/Form.tsx:89`

**Issue:** Missing dependency in useEffect; the form keeps the first user's data

**Fix:**
```diff
- useEffect(() => { fetchUser(userId) }, []);
+ useEffect(() => { fetchUser(userId) }, [userId]);
```

---

## Consider

- :yellow_circle: `src/api/client.ts:15` - retries without backoff. Tradeoff: matters only
  during an upstream outage; a fixed delay is a three-line change.

## Noted

- `src/api/client.ts:30` - responses are not cached; fine at current traffic.

## Dismissed

- `src/auth/login.ts:58` "user may be null" - unreachable: `requireUser()` throws first.
- `src/utils/format.ts:12` "extract a helper" - premature: one call site.

## Agreement (only when a second reviewer ran)

| Finding | First | Second | Bucket |
|---------|-------|--------|--------|
| `login.ts:42` SQL injection | yes | yes | Act on |

---

## Files Reviewed

| File | Changes | Act on |
|------|---------|--------|
| `src/auth/login.ts` | +42/-8 | 1 |
```

### Step 8: Integration

**Auto-create a task for each Act On item** (whatever its severity; dismissed and noted findings get none):
```
TaskCreate:
  subject: "Fix: SQL injection in login.ts:42"
  description: "SQL injection vulnerability found in user input handling."
  activeForm: "Fixing SQL injection in login.ts:42"
```

**Link with dependencies for related issues:**
```
TaskCreate: #1 "Fix SQL injection in login.ts"
TaskCreate: #2 "Fix SQL injection in register.ts"
TaskUpdate: taskId: "2", addBlockedBy: ["1"]
```

**After fixing issues:**
```
TaskUpdate:
  taskId: "1"
  status: "completed"
```

---

## Severity System

Severity is the reviewer's estimate of the damage if a finding is true. The bucket (Step 6) is the lead's decision on whether it is true and worth doing now. Tasks follow the bucket, not the severity. There is no praise level: a good pattern is not a finding.

| Level | Icon | Meaning | Usual bucket |
|-------|------|---------|--------------|
| CRITICAL | :red_circle: | Security bug, data loss risk, crashes | Act on once the path is confirmed; else Consider |
| WARNING | :yellow_circle: | Logic issues, performance problems | Act on if it would block a merge; else Consider or Noted |
| SUGGESTION | :blue_circle: | Style, minor improvements | Noted or Dismissed |

---

## Focus Modes

| Mode | What It Checks |
|------|----------------|
| `--security` | OWASP top 10, secrets in code, injection, auth issues |
| `--perf` | N+1 queries, unnecessary re-renders, complexity, memory |
| `--types` | Type safety, `any` usage, generics, null handling |
| `--tests` | Coverage gaps, test quality, mocking patterns |
| `--style` | Naming, organization, dead code, comments |
| (default) | All of the above |

---

## Depth Modes

| Mode | Behavior |
|------|----------|
| `--quick` | Surface-level scan, obvious issues only |
| `--normal` | Standard review, all severity levels (default) |
| `--thorough` | Deep analysis, traces data flow, checks edge cases |

---

## Advanced Flags

### `--base <branch>` - Baseline Comparison

Compare changes against a specific branch instead of HEAD:

```bash
/review --base main
/review src/ --base develop --thorough
```

### `--second-opinion` - Second Reviewer, Other Model Family

Adds one independent reviewer from a different model family and an agreement map. A finding both reviewers raise is the strongest signal in the review. Doubles the cost; never runs under `--quick`. Details: [references/lead-judgment.md](references/lead-judgment.md).

### `--json` - CI/CD Integration

Output review results as JSON. Non-interactive runs cannot ask for the intent, so `intent.inferred` says whether it came from the PR or commits (`false`) or only the diff (`true`). Dismissed findings stay in `issues` with their `reason`:

```json
{
  "intent": { "text": "Parameterise the login query", "inferred": false },
  "summary": {
    "files_reviewed": 3,
    "lines_changed": { "added": 42, "removed": 8 },
    "issues": { "critical": 1, "warning": 2, "suggestion": 1 },
    "buckets": { "act_on": 2, "consider": 1, "noted": 0, "dismissed": 1 }
  },
  "verdict": {
    "ready_to_commit": false,
    "reason": "2 act-on findings"
  },
  "issues": [
    { "file": "src/auth/login.ts", "line": 42, "severity": "critical", "bucket": "act_on", "summary": "SQL injection" },
    { "file": "src/auth/login.ts", "line": 58, "severity": "warning", "bucket": "dismissed", "reason": "unreachable: requireUser() throws first" }
  ]
}
```

**CI/CD usage** - gate on the bucket, not the severity: a dismissed CRITICAL is one the lead has already ruled out:
```yaml
- name: Code Review
  run: |
    claude "/review --json" > review.json
    if jq -e '.issues[] | select(.bucket == "act_on")' review.json; then
      exit 1
    fi
```

### `--fix` - Auto-Apply Fixes

Automatically apply suggested fixes:

1. Performs standard review
2. For each Act On item (and any Consider item the user picks), prompts for confirmation
3. Uses Edit tool to apply approved fixes
4. Creates TaskUpdate for resolved issues

**Non-interactive mode:**
```bash
/review --fix --auto-approve
```

---

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

---

## Integration

| Command | Relationship |
|---------|--------------|
| `/explain` | Deep dive into flagged code |
| `/testgen` | Generate tests for issues found |
| `/save` | Persist review findings to session state |
