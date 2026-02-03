# Severity Classification Guide

How to rank technical debt findings by severity and impact.

## Severity Levels

| Level | Label | Action Required | Examples |
|-------|-------|-----------------|----------|
| **P0** | Critical | Block merge | Security vulnerabilities, data loss risks |
| **P1** | High | Address soon | Major duplication, high complexity |
| **P2** | Medium | Plan to fix | Minor duplication, moderate complexity |
| **P3** | Low | Nice to have | Dead code, style issues, minor TODOs |

## Classification Framework

### Security Issues → P0 (Critical)

**Criteria:**
- Exposes sensitive data
- Enables unauthorized access
- Allows code injection
- Compromises system integrity

**Examples:**
- Hardcoded API keys, passwords, tokens
- SQL injection vulnerabilities
- XSS vulnerabilities
- Path traversal risks
- Insecure cryptography (MD5, SHA1 for passwords)
- Unsafe deserialization
- Missing authentication checks

**Action:** Fix immediately, block merge until resolved

### Data Integrity → P0 (Critical)

**Criteria:**
- Risk of data corruption
- Inconsistent state possible
- Transaction safety compromised

**Examples:**
- Race conditions in critical paths
- Missing database constraints
- Improper error handling in transactions
- Lack of input validation on critical fields

**Action:** Fix before deploying to production

### Major Duplication → P1 (High)

**Criteria:**
- 30+ lines duplicated
- Duplicated across 3+ files
- Core business logic duplicated
- High maintenance burden

**Impact:**
- Bug fixes must be applied multiple times
- Inconsistencies between copies
- Increased testing burden

**Action:** Refactor within current sprint/milestone

**Refactoring strategies:**
- Extract shared function/method
- Create utility module
- Implement template method pattern
- Use composition over duplication

### High Complexity → P1 (High)

**Criteria:**
- Cyclomatic complexity >15
- Function length >100 lines
- Nested depth >5 levels
- Difficult to test/maintain

**Impact:**
- Bug-prone code
- Hard to understand and modify
- Testing becomes expensive
- Knowledge silos form

**Action:** Simplify when next touching this code

**Refactoring strategies:**
- Extract method
- Replace conditionals with polymorphism
- Introduce guard clauses
- Break into smaller functions

### Minor Duplication → P2 (Medium)

**Criteria:**
- 15-30 lines duplicated
- Duplicated in 2 files
- Utility/helper logic duplicated
- Moderate maintenance burden

**Action:** Track in backlog, address during related work

### Moderate Complexity → P2 (Medium)

**Criteria:**
- Cyclomatic complexity 10-15
- Function length 50-100 lines
- Nested depth 4-5 levels
- Testable but challenging

**Action:** Consider refactoring when adding features

### Dead Code → P3 (Low)

**Criteria:**
- Unused imports
- Unreachable code blocks
- Orphaned functions/classes
- Commented-out code

**Impact:**
- Clutter and confusion
- False positives in searches
- Maintenance overhead
- Misleading context

**Action:** Remove during code cleanup sessions

**Safe removal checklist:**
- Verify no dynamic references (reflection, eval, etc.)
- Check not part of public API
- Confirm not referenced in documentation
- Use git for history, not comments

### Trivial Issues → P3 (Low)

**Criteria:**
- Minor style inconsistencies
- Recent TODOs (<30 days old)
- Small magic numbers
- Minor naming issues

**Action:** Fix opportunistically or ignore

## Special Cases

### Age-Based Adjustments

**Old TODOs:**
- >90 days → P1 (likely forgotten, needs resolution)
- 30-90 days → P2 (track and prioritize)
- <30 days → P3 (fresh, being actively worked on)

**Rationale:** Old TODOs indicate unresolved design decisions or deferred work that should be addressed.

### Context-Based Adjustments

**Critical paths (auth, payment, data processing):**
- Elevate all findings by one level
- P2 complexity → P1 in payment processing
- P3 dead code → P2 in authentication

**Test code:**
- Reduce all findings by one level
- P1 duplication → P2 in test fixtures
- Allow higher complexity in integration tests

**Example code/documentation:**
- Ignore most issues
- Focus only on security P0s

### Team Velocity Adjustments

**Fast-moving startups:**
- Focus on P0 only
- Track P1 but don't block
- P2/P3 for cleanup sprints

**Mature products:**
- Strict P0/P1 enforcement
- Regular P2 addressing
- Zero-debt goal for critical modules

## Decision Matrix

Use this matrix when severity is ambiguous:

| Question | Yes → Higher | No → Lower |
|----------|-------------|------------|
| Is this in a critical path? | +1 level | 0 |
| Does it affect end users directly? | +1 level | 0 |
| Has this caused bugs before? | +1 level | 0 |
| Is this code frequently modified? | +1 level | 0 |
| Would fixing this take >2 hours? | -1 level | 0 |
| Is there a documented plan to fix? | -1 level | 0 |

**Example:**
- Base: P2 (moderate complexity in utility function)
- Critical path? No (0)
- Affects users? No (0)
- Caused bugs? Yes (+1 → P1)
- Frequently modified? Yes (+1 → P0)
- **Final:** P0 (block merge)

## Auto-Fix Eligibility

Only certain findings can be auto-fixed safely:

**Eligible (with confirmation):**
- Unused imports (P3)
- Formatting issues (P3)
- Simple dead code removal (P3)
- Magic number extraction to const (P3)

**Not eligible (manual review required):**
- All security issues (P0)
- Complexity refactoring (P1/P2)
- Duplication extraction (P1/P2)
- Architecture changes (any)

## Reporting Guidelines

### Summary Statistics

Always include in reports:

```
Total findings: 42
├─ P0: 2 (BLOCK MERGE)
├─ P1: 8 (Address soon)
├─ P2: 15 (Plan to fix)
└─ P3: 17 (Nice to have)

Debt Score: 38/100 (lower is better)
```

**Debt Score Formula:**
```
Score = (P0 * 50) + (P1 * 10) + (P2 * 5) + (P3 * 1)
Normalized to 0-100 scale based on codebase size
```

### Trend Tracking

Show changes over time:

```
Debt Score: 38 (↓12% from baseline)

Category changes since baseline:
├─ Duplication: 12 findings (↓3)
├─ Security: 0 findings (✓ no change)
├─ Complexity: 18 findings (↑2)
└─ Dead Code: 12 findings (↓8)

✓ Good: Security issues resolved
⚠ Watch: Complexity trending up
```

### Actionable Recommendations

Prioritize by impact:

```
## Immediate Actions (P0)

1. Remove hardcoded API key in config.py:42
   └─ Impact: Security breach risk
   └─ Fix: Move to environment variable
   └─ Time: 5 minutes

2. Fix SQL injection in users.py:156
   └─ Impact: Database compromise
   └─ Fix: Use parameterized query
   └─ Time: 10 minutes

## High Priority (P1)

3. Refactor process_payment() - 125 lines, complexity 18
   └─ Impact: Bug-prone, hard to test
   └─ Fix: Extract validation, calculation, and persistence
   └─ Time: 2 hours

[... continue with ranked list ...]
```

## Exceptions and Suppressions

Sometimes technical debt is acceptable:

### Suppress findings

Add comments to justify:

```python
# techdebt: suppress complexity - intentionally complex
# reason: Performance-critical path, optimized algorithm
# reviewed: 2026-02-01 by @username
def highly_optimized_function():
    # 150 lines of complex but necessary code
    pass
```

**Valid suppression reasons:**
- Performance optimization (with benchmarks)
- External API compatibility (can't change)
- Temporary workaround (with ticket reference)
- Generated code (with generator version)

**Invalid reasons:**
- "Will fix later" (create ticket instead)
- "No time" (prioritize properly)
- "Works fine" (doesn't address debt)

### Document technical debt decisions

For intentional debt:

```markdown
## Known Technical Debt

| Component | Issue | Reason | Plan |
|-----------|-------|--------|------|
| payment.py | Duplication with refund.py | Rapid prototyping | Refactor in Q2 (PROJ-123) |
| auth.py | High complexity | Legacy system | Migrate to new auth in v3.0 |
```

## Review Process

### Pre-Merge Checklist

- [ ] All P0 issues resolved
- [ ] P1 issues tracked in backlog (with tickets)
- [ ] Debt score not increased significantly
- [ ] New code doesn't introduce P0/P1 debt

### Regular Debt Reviews

**Weekly:** Review new P1 findings, prioritize fixes

**Monthly:** Full scan, track trends, set improvement goals

**Quarterly:** Architectural review, major refactorings

## Calibration Examples

Learn from these real-world examples:

**Example 1: Hardcoded secret**
```python
API_KEY = "sk-abc123def456"  # Severity: P0
```
- Impact: Credential exposure
- Fix time: 5 minutes
- Can't wait: Yes
- **Verdict: P0 (block merge)**

**Example 2: Duplicated validation (30 lines, 3 files)**
```python
# Same 30-line validation in user.py, admin.py, api.py
```
- Impact: Inconsistent validation
- Fix time: 1 hour
- Can wait: Until next feature in module
- **Verdict: P1 (address soon)**

**Example 3: Complex function (95 lines, complexity 12)**
```python
def process_order():  # 95 lines, complexity 12
```
- Impact: Hard to modify
- Fix time: 2 hours
- Can wait: Yes, if tests are good
- **Verdict: P2 (plan to fix)**

**Example 4: Unused import**
```python
import os  # Never used
```
- Impact: Clutter
- Fix time: 1 second
- Can wait: Yes
- **Verdict: P3 (clean up when convenient)**
