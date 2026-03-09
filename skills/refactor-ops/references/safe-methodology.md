# Safe Refactoring Methodology Reference

Strategies for large and small refactorings that preserve behavior, minimize risk, and provide rollback safety.

---

## Test-Driven Refactoring

### The Core Loop

```
Red-Green-Refactor (for new code)
│
├─ RED: Write a failing test for the desired behavior
├─ GREEN: Write the simplest code that makes the test pass
└─ REFACTOR: Clean up while keeping tests green
   └─ This is where refactoring happens safely

Characterization-Then-Refactor (for existing code)
│
├─ Step 1: Write Characterization Tests
│  │  Run the existing code and capture its actual output
│  │  Assert on that output, even if it seems wrong
│  │  Goal: document what the code DOES, not what it SHOULD do
│  │
│  │  Example:
│  │  def test_calculate_tax_current_behavior():
│  │      # This may be "wrong" but it's what the code does today
│  │      assert calculate_tax(100) == 8.25  # captures actual behavior
│  │
│  └─ Coverage: ensure every branch you will touch is covered
│
├─ Step 2: Refactor Under Test Safety
│  │  Make one small change
│  │  Run all characterization tests
│  │  If tests pass → commit and continue
│  │  If tests fail → revert and try smaller change
│  └─ Never refactor and change behavior in the same step
│
├─ Step 3: Replace Characterization Tests
│  │  Once code is clean, write proper intention-revealing tests
│  │  The characterization tests served as scaffolding
│  └─ Now you can safely fix behavioral bugs you discovered
│
└─ Step 4: Fix Behavioral Issues (if any)
   Now that you have proper tests and clean code,
   fix any bugs discovered during characterization
   Each fix gets its own test + commit
```

### Writing Effective Characterization Tests

```python
# Strategy: Use the code itself to tell you what to assert

# 1. Call the function with representative inputs
result = process_order(sample_order)

# 2. Print the result
print(result)  # {'total': 108.25, 'tax': 8.25, 'status': 'pending'}

# 3. Assert on the printed output
def test_process_order_characterization():
    result = process_order(sample_order)
    assert result['total'] == 108.25
    assert result['tax'] == 8.25
    assert result['status'] == 'pending'

# 4. Cover edge cases the same way
def test_process_order_empty_items():
    result = process_order(Order(items=[]))
    # Even if this behavior is "wrong", capture it
    assert result['total'] == 0
    assert result['status'] == 'pending'  # maybe should be 'invalid'?
```

### When You Cannot Write Tests First

Sometimes characterization tests are impractical (tightly coupled UI, external service dependencies, time-based logic). Alternatives:

```
Cannot write characterization tests?
│
├─ Too coupled to test → Extract the testable parts first
│  Use "Sprout Method" or "Sprout Class":
│  1. Write the new logic in a new, testable function
│  2. Call it from the old code
│  3. Test the new function
│  4. Gradually move more logic into testable functions
│
├─ External service dependency → Record and replay
│  Use VCR/Polly/nock to record real responses
│  Replay them in tests
│
├─ UI-heavy → Snapshot/Approval tests
│  Capture screenshots or HTML output
│  Compare against approved baseline
│
└─ Time-based logic → Inject a clock
   Pass a clock/timer as a parameter
   Use a fake clock in tests
```

---

## Strangler Fig Pattern

For replacing a large legacy system or module incrementally, without a risky big-bang rewrite.

```
Strangler Fig Strategy
│
├─ Phase 1: Identify boundaries
│  │  Map the legacy system's entry points (API routes, function calls, events)
│  │  Each entry point is a candidate for strangling
│  └─ Prioritize by: risk (low first), value (high first), coupling (loose first)
│
├─ Phase 2: Build new implementation alongside old
│  │  New code lives in a new module/service
│  │  Both old and new exist simultaneously
│  └─ No modification to legacy code yet
│
├─ Phase 3: Route traffic to new implementation
│  │  Use a router/proxy/feature flag to direct requests
│  │  Start with a small percentage (canary)
│  │  Monitor for errors and performance differences
│  └─ Gradually increase percentage
│
├─ Phase 4: Remove legacy code
│  │  Once 100% traffic goes to new implementation
│  │  Keep legacy code for one release cycle (rollback safety)
│  └─ Then delete it
│
└─ Repeat for each entry point
```

### Example: Strangling a Legacy API Endpoint

```typescript
// Phase 2: New implementation alongside old
// old: /api/v1/users (legacy monolith)
// new: /api/v2/users (new service)

// Phase 3: Router decides which to call
app.get('/api/users', async (req, res) => {
  const useNewImplementation = await featureFlag('new-users-api', {
    userId: req.user?.id,
    percentage: 25,  // Start with 25% of traffic
  });

  if (useNewImplementation) {
    return newUsersService.getUsers(req, res);
  }
  return legacyUsersController.getUsers(req, res);
});

// Phase 4: Once at 100%, simplify
app.get('/api/users', (req, res) => newUsersService.getUsers(req, res));
```

---

## Parallel Change (Expand-Migrate-Contract)

For changing an interface without breaking consumers. Three phases: expand (add new), migrate (move consumers), contract (remove old).

```
Parallel Change Phases
│
├─ EXPAND: Add the new interface alongside the old
│  │  Both old and new work simultaneously
│  │  Old interface delegates to new implementation internally
│  └─ All existing tests continue to pass
│
├─ MIGRATE: Update all consumers to use the new interface
│  │  One consumer at a time
│  │  Each migration is a separate commit/PR
│  │  Old interface still works (backward compatible)
│  └─ Monitor for issues after each migration
│
└─ CONTRACT: Remove the old interface
   │  All consumers now use the new interface
   │  Delete old code and update tests
   └─ This is the only "breaking" change
```

### Example: Renaming a Function

```python
# EXPAND: Add new name, keep old as alias
def calculate_shipping_cost(order: Order) -> Money:
    """New name with improved logic."""
    # ... implementation ...

def calcShipping(order: Order) -> Money:
    """Deprecated: Use calculate_shipping_cost instead."""
    import warnings
    warnings.warn("calcShipping is deprecated, use calculate_shipping_cost", DeprecationWarning)
    return calculate_shipping_cost(order)

# MIGRATE: Update all call sites one by one
# grep for calcShipping, replace with calculate_shipping_cost
# Run tests after each file

# CONTRACT: Remove old function
# Delete calcShipping entirely
# Remove deprecation warning
```

### Example: Changing a Database Schema

```sql
-- EXPAND: Add new column alongside old
ALTER TABLE users ADD COLUMN full_name VARCHAR(255);

-- Application code writes to BOTH columns
-- UPDATE users SET full_name = first_name || ' ' || last_name, ...

-- MIGRATE: Backfill existing data
-- UPDATE users SET full_name = first_name || ' ' || last_name WHERE full_name IS NULL;
-- Update all queries to read from full_name

-- CONTRACT: Remove old columns
-- ALTER TABLE users DROP COLUMN first_name, DROP COLUMN last_name;
```

---

## Branch by Abstraction

For replacing an internal implementation without feature branches. Introduce an abstraction layer, swap the implementation behind it.

```
Branch by Abstraction
│
├─ Step 1: Create abstraction (interface/protocol/trait)
│  │  Define the contract that both old and new implementations satisfy
│  └─ All existing code uses the abstraction, not the concrete implementation
│
├─ Step 2: Wrap existing implementation
│  │  Make existing code implement the new abstraction
│  └─ All tests pass -- no behavior change
│
├─ Step 3: Build new implementation
│  │  New implementation also satisfies the abstraction
│  │  Test new implementation independently
│  └─ Old implementation is still the default
│
├─ Step 4: Switch
│  │  Change the wiring to use new implementation
│  │  Feature flag or config toggle for easy rollback
│  └─ Monitor in production
│
└─ Step 5: Clean up
   Remove old implementation
   Remove abstraction if only one implementation remains
   Remove feature flag
```

### Example:

```typescript
// Step 1: Define abstraction
interface PaymentGateway {
  charge(amount: Money, card: CardInfo): Promise<PaymentResult>;
  refund(paymentId: string, amount: Money): Promise<RefundResult>;
}

// Step 2: Wrap existing implementation
class StripeGateway implements PaymentGateway {
  async charge(amount: Money, card: CardInfo): Promise<PaymentResult> {
    // existing Stripe code, now behind the interface
  }
  async refund(paymentId: string, amount: Money): Promise<RefundResult> {
    // existing Stripe refund code
  }
}

// Step 3: Build new implementation
class SquareGateway implements PaymentGateway {
  async charge(amount: Money, card: CardInfo): Promise<PaymentResult> {
    // new Square implementation
  }
  async refund(paymentId: string, amount: Money): Promise<RefundResult> {
    // new Square refund implementation
  }
}

// Step 4: Switch via configuration
function createPaymentGateway(): PaymentGateway {
  if (config.paymentProvider === 'square') {
    return new SquareGateway();
  }
  return new StripeGateway(); // default/fallback
}
```

---

## Small Commits Strategy

Every commit during a refactoring must satisfy two invariants:

1. **Code compiles** (type-checks, no syntax errors)
2. **All tests pass** (no behavioral regressions)

### Commit Granularity Guide

```
Refactoring Commit Patterns
│
├─ Rename → 1 commit
│  "refactor: rename calcShipping to calculateShippingCost"
│
├─ Extract Function → 1 commit
│  "refactor: extract validateOrderItems from processOrder"
│
├─ Move File → 1 commit
│  "refactor: move utils/helpers.ts to lib/string-utils.ts"
│
├─ Extract Class → 2-3 commits
│  1. "refactor: extract PriceCalculator interface"
│  2. "refactor: implement PriceCalculator, delegate from OrderService"
│  3. "refactor: remove pricing logic from OrderService"
│
├─ Replace Algorithm → 2 commits
│  1. "test: add characterization tests for sorting"
│  2. "refactor: replace bubble sort with merge sort"
│
└─ Large Restructure → Many small commits
   Each file move or extraction is its own commit
   Never batch unrelated changes
```

### Git Workflow for Refactoring

```bash
# Start a refactoring session
git checkout -b refactor/extract-payment-service

# After each small refactoring step
git add -p  # Stage only the relevant changes
git commit -m "refactor: extract PaymentValidator from PaymentService"

# Verify at each step
npm test  # or pytest, cargo test, go test ./...

# If a step goes wrong, revert just that step
git revert HEAD

# When done, create a clean PR
# Each commit should be reviewable independently
```

---

## Feature Flags for Gradual Rollout

When a refactoring affects runtime behavior (e.g., new algorithm, new data flow), use feature flags to control rollout.

```
Feature Flag Strategy
│
├─ Before refactoring
│  │  Add a feature flag that defaults to OFF (old behavior)
│  └─ Deploy the flag infrastructure
│
├─ During refactoring
│  │  New code path guarded by the flag
│  │  Old code path remains the default
│  └─ Both paths are tested
│
├─ Rollout
│  │  Enable for internal users first
│  │  Enable for 1% → 10% → 50% → 100%
│  │  Monitor error rates, latency, correctness
│  └─ Rollback = disable the flag (instant, no deploy needed)
│
└─ Cleanup
   Remove the flag and old code path
   This is a separate PR after the rollout is complete
```

### Implementation Pattern

```typescript
// Simple feature flag check
async function searchProducts(query: string): Promise<Product[]> {
  if (await featureFlags.isEnabled('new-search-algorithm', { userId })) {
    return newSearchAlgorithm(query);
  }
  return legacySearch(query);
}
```

### Feature Flag Hygiene

| Rule | Why |
|------|-----|
| Remove flags within 2 sprints of 100% rollout | Stale flags accumulate and confuse |
| Name flags descriptively | `new-search-algorithm` not `flag-123` |
| Log flag evaluations | Debug which path was taken |
| Test both paths | Both old and new must have coverage |
| Flag owner documented | Someone must clean up the flag |

---

## Approval Testing / Snapshot Testing

Capture the output of existing code and use it as the test assertion. Ideal for characterization testing before refactoring.

### How It Works

```
Approval Testing Flow
│
├─ First run: Capture output → save as "approved" baseline
│  ├─ HTML output → screenshot or HTML snapshot
│  ├─ JSON output → save formatted JSON
│  ├─ Console output → save text
│  └─ API response → save response body
│
├─ Subsequent runs: Compare output against baseline
│  ├─ Match → test passes
│  └─ Mismatch → test fails, show diff
│     ├─ If expected change → approve new baseline
│     └─ If unexpected change → regression, investigate
│
└─ During refactoring: any output change is flagged
   You decide if the change is intentional or a bug
```

### Tools

| Language | Tool | Type |
|----------|------|------|
| JavaScript | Jest snapshots | `expect(result).toMatchSnapshot()` |
| JavaScript | Storybook Chromatic | Visual regression |
| Python | pytest-snapshot | `snapshot.assert_match(result)` |
| Python | Approval Tests | `verify(result)` |
| Go | go-snaps | `snaps.MatchSnapshot(t, result)` |
| Rust | insta | `insta::assert_snapshot!(result)` |
| Any | screenshot comparison | Playwright, Cypress, Percy |

### Jest Snapshot Example

```typescript
// Before refactoring: create baseline
test('renders user profile', () => {
  const { container } = render(<UserProfile user={mockUser} />);
  expect(container.innerHTML).toMatchSnapshot();
});

// During refactoring: any HTML change will fail this test
// If the change is intentional:
//   npx jest --updateSnapshot
```

### Python Approval Test Example

```python
from approvaltests import verify

def test_generate_report():
    report = generate_report(sample_data)
    verify(report)  # First run saves "approved" file
                    # Subsequent runs compare against it
```

---

## Rollback Strategies

```
Rollback Options (fastest to slowest)
│
├─ Feature flag toggle (seconds)
│  └─ Disable the flag → old code path runs instantly
│     No deployment needed
│
├─ Git revert (minutes)
│  └─ git revert <commit-hash>
│     Creates a new commit that undoes the change
│     Deploy the revert
│
├─ Redeploy previous version (minutes-hours)
│  └─ Roll back to previous container image / release tag
│     CI/CD pipeline handles the rest
│
├─ Database rollback (hours-days)
│  └─ If schema changed: run reverse migration
│     If data changed: restore from backup
│     Most disruptive, avoid if possible
│
└─ Cannot rollback (prevention only)
   Deleted data, sent emails, external API calls
   Design for forward-fix instead
```

### Forward-Fix vs Rollback Decision

```
Should you rollback or fix forward?
│
├─ Is the bug causing data loss or corruption?
│  └─ ROLLBACK immediately, fix later
│
├─ Is the bug affecting > 10% of users?
│  └─ ROLLBACK, then fix forward on a branch
│
├─ Is the fix obvious and small (< 5 lines)?
│  └─ FIX FORWARD with expedited review
│
├─ Is the bug cosmetic or low-severity?
│  └─ FIX FORWARD in next regular release
│
└─ Are you unsure of the scope?
   └─ ROLLBACK (when in doubt, be safe)
```

---

## Code Review Checklist for Refactoring PRs

```
Reviewer Checklist
│
├─ Behavior Preservation
│  [ ] No functional changes mixed with structural changes
│  [ ] Test suite passes (check CI, not just author's word)
│  [ ] Snapshot/approval tests show no unexpected diffs
│  [ ] Public API unchanged (or deprecated properly)
│
├─ Quality of Refactoring
│  [ ] Each commit is atomic and independently valid
│  [ ] Naming improves clarity (not just different)
│  [ ] Abstraction level is appropriate (not over-engineered)
│  [ ] No new duplication introduced
│  [ ] No circular dependencies introduced
│
├─ Safety
│  [ ] Characterization tests exist for changed code
│  [ ] Feature flag or rollback plan documented (if applicable)
│  [ ] Performance-sensitive code benchmarked before/after
│  [ ] No dead code left behind (old implementations removed)
│
└─ Completeness
   [ ] All references updated (imports, configs, docs, tests)
   [ ] Deprecation warnings added for public API changes
   [ ] Migration guide for downstream consumers (if applicable)
```

---

## Measuring Refactoring Success

Refactoring is an investment. Measure whether it paid off.

### Quantitative Metrics

| Metric | Before/After | Tool |
|--------|-------------|------|
| **Cyclomatic complexity** | Should decrease | radon, eslint, gocyclo |
| **Cognitive complexity** | Should decrease | SonarQube |
| **File length** | Should decrease (god files → smaller modules) | tokei, wc -l |
| **Test coverage** | Should increase or stay the same | coverage.py, istanbul, tarpaulin |
| **Build time** | Should not increase significantly | CI pipeline timing |
| **Bundle size** | Should not increase (may decrease with dead code removal) | webpack-bundle-analyzer |
| **Deployment frequency** | Should increase (easier to ship) | DORA metrics |
| **Change failure rate** | Should decrease (fewer regressions) | DORA metrics |

### Qualitative Indicators

| Signal | Meaning |
|--------|---------|
| Fewer merge conflicts in the area | Code is better organized, less contention |
| New features in the area are faster to build | Reduced coupling and clear boundaries |
| Fewer bug reports in the area | Cleaner code, better error handling |
| Team members are less afraid to change the code | Improved testability and readability |
| Code review comments shift from "I don't understand" to "looks good" | Better naming and structure |

### Before/After Comparison Template

```bash
# Capture BEFORE metrics
echo "=== BEFORE ==="
tokei src/module-to-refactor/          # Line counts
radon cc src/module-to-refactor/ -a    # Cyclomatic complexity (Python)
npx knip --reporter compact            # Unused code (JS/TS)

# ... do the refactoring ...

# Capture AFTER metrics
echo "=== AFTER ==="
tokei src/module-to-refactor/
radon cc src/module-to-refactor/ -a
npx knip --reporter compact

# Compare
# Complexity should go down
# Line count may go up slightly (more files, smaller each)
# Unused code count should go down
```

---

## Anti-Patterns in Refactoring Methodology

| Anti-pattern | Problem | Better Approach |
|--------------|---------|-----------------|
| Big-bang rewrite | High risk, nothing works for weeks | Strangler fig: replace incrementally |
| Refactoring without a goal | Endless polishing, no business value | Define success criteria before starting |
| Refactoring everything at once | Merge conflicts, hard to review, hard to rollback | One module at a time, one PR at a time |
| Skipping characterization tests | No safety net, cannot verify behavior preserved | Always capture current behavior first |
| Mixing refactoring with features | Cannot tell which caused a regression | Separate PRs: refactor first, then add feature |
| Not measuring improvement | Cannot justify the time investment | Capture before/after metrics |
| Stopping halfway | Half-old, half-new is worse than either | Plan for completion, or don't start |
| Over-designing for the future | YAGNI -- you are not going to need it | Refactor for today's needs, not hypothetical future |
| Refactoring shared library without coordinating consumers | Breaks downstream teams | Parallel change + deprecation period |
| No rollback plan | Stuck if something goes wrong in production | Always have a path back: feature flag, git revert, or previous deploy |
