# Systematic Debugging Methods

Structured approaches to finding and fixing bugs, from scientific method to team-based protocols.

## Scientific Debugging Method

The most rigorous approach: treat debugging as an experiment.

### The Cycle

```
Observe → Hypothesize → Predict → Test → Conclude
   ↑                                        │
   └────────────────────────────────────────┘
           (if hypothesis rejected)
```

### Step-by-Step

1. **Observe**: Gather all available evidence without interpretation
   - Error messages, stack traces, logs
   - System state (memory, CPU, disk, network)
   - User-reported behavior vs expected behavior
   - When it started (correlate with deployments, config changes)

2. **Hypothesize**: Form a specific, falsifiable explanation
   - "The query times out because the users table lacks an index on email"
   - NOT "something is wrong with the database" (too vague)

3. **Predict**: State what should happen if the hypothesis is true
   - "If I add an index on email, the query should complete in <100ms"
   - "If I run EXPLAIN on the query, it should show a sequential scan"

4. **Test**: Run the smallest experiment that distinguishes true from false
   - Run EXPLAIN ANALYZE on the query
   - Check if the index exists: `\di users_email_idx`

5. **Conclude**: Accept or reject the hypothesis based on evidence
   - If confirmed: proceed to fix
   - If rejected: return to step 1 with new information

### Example Walkthrough

```
OBSERVATION:
  API endpoint POST /api/orders returns 500 after deploying v2.3.1
  Error log: "TypeError: Cannot read property 'id' of undefined"
  Stack trace points to orders.controller.js:47

HYPOTHESIS 1:
  "The user object is null because the auth middleware is not
   attaching it to the request in the new version"

PREDICTION:
  "If I log req.user in the auth middleware, it will be undefined
   for the failing requests"

TEST:
  Added console.log(req.user) in auth middleware
  Result: req.user IS defined and correct

CONCLUSION:
  Hypothesis 1 REJECTED. The user object exists.

HYPOTHESIS 2:
  "The order.customer field changed from an object to a string ID
   in the new schema, so order.customer.id fails"

PREDICTION:
  "If I inspect the order document, customer will be a string, not
   an object with an .id property"

TEST:
  db.orders.findOne({_id: "failing-order-id"})
  Result: { customer: "user_123", ... }  -- string, not object

CONCLUSION:
  Hypothesis 2 CONFIRMED. Schema migration changed customer from
  embedded object to reference ID. Fix: update controller to handle
  both formats or ensure migration is complete.
```

## Binary Search Debugging

Divide the search space in half with each step. Works for both code and history.

### Git Bisect (Automated)

Find the exact commit that introduced a bug:

```bash
# Start bisect
git bisect start

# Mark current (broken) state as bad
git bisect bad

# Mark a known-good commit
git bisect good v2.2.0

# Automate with a test script (exit 0 = good, exit 1 = bad)
git bisect run ./test-bug.sh
```

Example test script:

```bash
#!/bin/bash
# test-bug.sh - exits 0 if bug is absent, 1 if present

# Build the project (skip if not needed)
npm install --silent 2>/dev/null
npm run build --silent 2>/dev/null

# Run the specific test that catches the bug
npm test -- --grep "order creation" 2>/dev/null
exit $?
```

```bash
# After bisect completes:
# "abc1234 is the first bad commit"

# View the offending commit
git show abc1234

# Clean up
git bisect reset
```

### Git Bisect (Manual)

```bash
git bisect start
git bisect bad HEAD
git bisect good v2.2.0

# Git checks out a middle commit
# Test manually, then mark:
git bisect good   # if this commit works
git bisect bad    # if this commit is broken

# Repeat until the first bad commit is found
# ~10 steps for 1000 commits (log2(1000) ≈ 10)
```

### Manual Code Bisection

When the bug is in a single file or function:

```
1. Comment out the bottom half of the suspect function
2. Test → still broken? Bug is in the top half
3. Uncomment bottom half, comment out top half of remaining suspect code
4. Repeat until you isolate the exact line(s)
```

This is particularly effective for:
- Long functions with no clear fault location
- Template/config files where errors are positional
- CSS debugging (comment out rule blocks)

## Wolf Fence Algorithm

Named after the strategy of placing a fence across a territory to determine which side the wolf is on.

### Concept

Place a "probe" (assertion, log, breakpoint) at the midpoint of execution. Check if the state is correct at that point. If correct, the bug is downstream. If incorrect, it is upstream. Repeat.

### Implementation

```python
def process_order(order):
    validated = validate(order)
    # PROBE 1: is validated correct here?
    assert validated.total > 0, f"Probe 1 failed: total={validated.total}"

    enriched = enrich_with_inventory(validated)
    # PROBE 2: is enriched correct here?
    assert enriched.items_available, f"Probe 2 failed: items={enriched.items}"

    charged = charge_payment(enriched)
    # PROBE 3: is charged correct here?
    assert charged.payment_id, f"Probe 3 failed: payment={charged.payment_id}"

    return finalize(charged)
```

### Strategic Probe Placement

```
Place probes at:
├─ Function entry/exit boundaries
├─ Before/after external calls (DB, API, filesystem)
├─ Before/after data transformations
├─ At conditional branches (which path was taken?)
└─ At loop boundaries (iteration count, accumulator value)
```

## Rubber Duck Debugging

Explaining the problem forces you to examine your assumptions.

### Structured Rubber Duck Template

```
1. WHAT I EXPECT TO HAPPEN:
   [describe the correct behavior in detail]

2. WHAT ACTUALLY HAPPENS:
   [describe the observed behavior precisely]

3. THE GAP:
   [what is different between expected and actual?]

4. MY CODE DOES THIS:
   [walk through the relevant code line by line]
   - Line 1: "First, we fetch the user by ID..."
   - Line 2: "Then we check if the user has permission..."
   - Line 3: "Wait... we check user.role but role could be
              undefined if the user was created before we
              added roles... THAT'S THE BUG"

5. ASSUMPTIONS I AM MAKING:
   [list every assumption, then question each one]
   - "The user always has a role" ← IS THIS TRUE?
   - "The database returns results in insertion order" ← IS THIS TRUE?
   - "The config file is loaded before this function runs" ← IS THIS TRUE?
```

### Why It Works

- Forces sequential reasoning instead of pattern-matching
- Exposes implicit assumptions
- Catches "it obviously works" blind spots
- The bug is usually found in step 4 or 5

## Differential Debugging

Compare what works against what does not.

### Method

```
Working State          vs.          Broken State
─────────────                      ────────────
Environment A                      Environment B
Input set X                        Input set Y
Version N-1                        Version N
Config A                           Config B
```

### Practical Comparison Commands

```bash
# Compare environment variables
diff <(env | sort) <(ssh prod 'env | sort')

# Compare installed packages
diff <(pip list --format=freeze | sort) <(ssh prod 'pip list --format=freeze | sort')

# Compare config files
diff local.env production.env
difft config-working.yaml config-broken.yaml  # semantic diff

# Compare database schemas
diff <(pg_dump --schema-only dbA) <(pg_dump --schema-only dbB)

# Compare API responses
diff <(curl -s localhost:3000/api/users | jq .) <(curl -s prod:3000/api/users | jq .)

# Compare directory structures
diff <(fd -t f . ./working/ | sort) <(fd -t f . ./broken/ | sort)
```

### Environment Diff Checklist

```
[ ] OS and version
[ ] Runtime version (node --version, python --version, go version)
[ ] Dependency versions (package-lock.json, requirements.txt, go.sum)
[ ] Environment variables (especially secrets, API keys, feature flags)
[ ] Config files (compare byte-for-byte)
[ ] Database schema and seed data
[ ] Network configuration (firewall, DNS, proxy)
[ ] File system (permissions, case sensitivity, available disk)
[ ] System resources (memory, CPU, file descriptors)
[ ] Time and timezone
```

## Delta Debugging

Systematically reduce the input or code to find the minimal failing case.

### Concept (ddmin Algorithm)

```
Given: A failing input of N elements
Goal:  Find the smallest subset that still triggers the failure

1. Split input into 2 halves
2. Test each half:
   - If one half fails alone → recurse on that half
   - If neither half fails alone → the bug requires elements from both
     → try removing each quarter, then each eighth, etc.
3. Stop when no single element can be removed without fixing the bug
```

### Practical Application

```bash
# Reduce a failing test input file
# Start: 1000-line input.json that causes a crash

# Test: does the first half crash?
head -500 input.json > test.json && ./program test.json

# If yes: recurse on first 500 lines
# If no: test second half
tail -500 input.json > test.json && ./program test.json

# Continue halving until minimal input found
```

### Code Reduction

```
1. Start with the full failing program
2. Remove half the code (e.g., half the imports, half the functions)
3. Does it still fail?
   - Yes → keep removing from what remains
   - No → restore that half, remove the other half
4. Result: minimal code that reproduces the failure
```

### Tools

- **C-Reduce** (`creduce`): Automated C/C++ test case reduction
- **Perses**: Language-agnostic program reducer
- **picireny**: Python-based delta debugging framework
- Manual reduction is often fastest for small programs

## Trace-Based Debugging

Follow the execution path through the system.

### Strategic Trace Points

```python
import functools
import time
import json

def trace(func):
    """Decorator that traces function entry, exit, and timing."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        call_id = id(args) % 10000
        arg_summary = json.dumps(args[:3], default=str)[:100]
        print(f"[TRACE {call_id}] ENTER {func.__name__}({arg_summary})")
        start = time.perf_counter()
        try:
            result = func(*args, **kwargs)
            elapsed = (time.perf_counter() - start) * 1000
            result_summary = str(result)[:100]
            print(f"[TRACE {call_id}] EXIT  {func.__name__} -> {result_summary} ({elapsed:.1f}ms)")
            return result
        except Exception as e:
            elapsed = (time.perf_counter() - start) * 1000
            print(f"[TRACE {call_id}] ERROR {func.__name__}: {e} ({elapsed:.1f}ms)")
            raise
    return wrapper
```

### System Call Tracing

```bash
# Linux: trace system calls
strace -f -e trace=network,file -p PID

# Trace a command from start
strace -f -o trace.log ./my-program

# Count system calls (find the hot path)
strace -c ./my-program

# macOS: dtrace/dtruss
sudo dtruss -p PID

# Trace file access only
strace -e trace=open,openat,read,write -p PID
```

### Structured Trace Output

```
Timestamp   | Component     | Event    | Detail
------------|---------------|----------|---------------------------
10:23:01.001| auth-service  | ENTRY    | validateToken(tok_abc...)
10:23:01.003| auth-service  | CALL     | redis.get("session:abc")
10:23:01.015| auth-service  | RETURN   | redis -> {user: "u123"}
10:23:01.016| auth-service  | EXIT     | validateToken -> valid
10:23:01.017| order-service | ENTRY    | createOrder(user=u123)
10:23:01.018| order-service | CALL     | db.query("SELECT ...")
10:23:01.250| order-service | RETURN   | db -> timeout after 232ms  ← PROBLEM
```

## Time-Travel Debugging

Record execution and replay it, stepping forwards AND backwards.

### rr (Linux only)

```bash
# Record the execution
rr record ./my-program arg1 arg2

# Replay (starts at the end, you can go backwards)
rr replay

# Inside the rr session (gdb-like interface):
(rr) continue           # run forward
(rr) reverse-continue   # run backward to previous breakpoint
(rr) reverse-next       # step backward one line
(rr) reverse-step       # step backward into function calls
(rr) watch -l var       # break when var changes (works in reverse too)

# Set a breakpoint and reverse-continue to find what set a value
(rr) break my_function
(rr) continue           # hit the breakpoint going forward
(rr) watch -l result    # watch the variable
(rr) reverse-continue   # go back to where result was last set
```

### When to Use Time-Travel Debugging

- Bug manifests late but root cause is early in execution
- You need to find "what set this variable to the wrong value?"
- Intermittent bugs that are hard to reproduce (record once, replay many times)
- Complex multi-step state corruption

### Alternatives by Language

| Language | Tool | Notes |
|----------|------|-------|
| C/C++ | rr | Best-in-class, Linux only |
| C/C++ | UDB (UndoDB) | Commercial, cross-platform |
| JavaScript | Chrome DevTools | "Step backward" in Sources panel (limited) |
| Python | `epdb` / `pdb++` | Post-mortem with history, not true time-travel |
| Java | IntelliJ IDEA | Limited reverse debugging |
| .NET | Visual Studio | IntelliTrace (Enterprise edition) |

## Hypothesis-Driven Debugging

Maintain a structured log of hypotheses to avoid going in circles.

### Tracking Template

```markdown
## Bug: [Brief description]

### Evidence Collected
- [ ] Error message: "..."
- [ ] Stack trace captured
- [ ] Logs reviewed for timeframe: X to Y
- [ ] Reproduction rate: N/M attempts

### Hypotheses

| # | Hypothesis | Prediction | Test | Result | Status |
|---|-----------|------------|------|--------|--------|
| 1 | Missing index on users.email | EXPLAIN shows seq scan | Run EXPLAIN ANALYZE | Shows index scan | REJECTED |
| 2 | Connection pool exhausted | Active connections = max | Check pg_stat_activity | 47/50 connections | INVESTIGATING |
| 3 | | | | | |

### Current Best Hypothesis: #2

### What I Tried That Didn't Work
- Restarting the service (symptom returned after 5 min)
- Increasing query timeout (different error, same root cause)
```

### Rules

1. Write hypotheses down before testing them
2. Define the prediction before running the test
3. Record results even for rejected hypotheses (prevents retesting)
4. If you have tested 5+ hypotheses without progress, step back and re-examine assumptions

## Debugging Checklists

### Pre-Debug Checklist

```
[ ] Read the full error message and stack trace
[ ] Check if this is a known issue (search issue tracker, logs)
[ ] Identify when it started (correlate with recent changes)
[ ] Verify you are on the correct branch/version
[ ] Check recent commits: git log --oneline -10
[ ] Check recent deployments or config changes
[ ] Reproduce the bug locally
[ ] Set a time limit (30 min before seeking help)
```

### During-Debug Log

```
Time    | Action Taken              | Result           | Next Step
--------|---------------------------|------------------|----------
10:00   | Reproduced locally        | Fails 3/3 times  | Check logs
10:05   | Checked error logs        | Found stack trace | Form hypothesis
10:10   | Hypothesis: null user obj | Test: add assert  | Test
10:15   | Assert passed (user OK)   | Rejected H1      | New hypothesis
10:20   | Hypothesis: stale cache   | Test: clear cache | Test
10:22   | Cache cleared, bug gone   | Confirmed H2     | Find root cause
10:30   | Cache TTL was 0 (never expires) | Root cause found | Fix
```

### Post-Debug Retrospective

```
[ ] Root cause documented
[ ] Fix applied and verified
[ ] Regression test added
[ ] Could this bug class exist elsewhere? (search for similar patterns)
[ ] Was the debugging process efficient? What would I do differently?
[ ] Knowledge shared with team (if applicable)
[ ] Monitoring/alerting added to catch recurrence
```

## When to Stop Debugging

### Diminishing Returns Signals

- You have been debugging for 2+ hours without new information
- You are retesting hypotheses you already rejected
- You are making changes "just to see what happens"
- You are frustrated and making mistakes

### Decision Framework

```
Can you reproduce it?
├─ No → Workaround + monitoring + move on
└─ Yes
   ├─ Is the impact high? (data loss, security, outage)
   │  └─ Yes → Keep debugging, escalate if needed
   └─ Is the impact low? (cosmetic, edge case, rare)
      └─ Yes → Workaround + backlog ticket + move on
```

### Escalation Criteria

- You have spent 2x your initial time estimate
- You need access to systems/data you do not have
- The bug crosses team boundaries (your service + another team's service)
- You suspect a bug in a third-party library or runtime

## Debugging in Teams

### Pair Debugging

Two people, one screen. One drives (types), one navigates (thinks strategically).

- Driver focuses on tactical execution
- Navigator watches for wrong turns, suggests hypotheses
- Switch roles every 20-30 minutes
- Navigator should resist the urge to grab the keyboard

### Fresh Eyes Protocol

When stuck, explain the problem to a colleague who has NOT been debugging it:

1. Describe the expected behavior
2. Describe the actual behavior
3. List hypotheses tested and their results
4. Ask: "What am I missing?"

The fresh person often spots an assumption the original debugger has gone blind to.

### Knowledge Transfer After Debugging

```
Share with the team:
├─ What the bug was (root cause, not just symptom)
├─ How it was found (which technique worked)
├─ Why existing tests/monitoring did not catch it
├─ What was added to prevent recurrence
└─ Any broader lessons (design patterns, common pitfalls)
```
