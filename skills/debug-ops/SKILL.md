---
name: debug-ops
description: "Systematic debugging methodology, language-specific debuggers, and common scenario playbooks. Use for: debug, debugging, bug, crash, hang, memory leak, race condition, deadlock, bisect, reproduce, root cause, breakpoint, profiling, performance issue, segfault, stack trace, core dump."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: testing-ops, security-ops, monitoring-ops, code-stats
---

# Debug Operations

Systematic debugging methodology with language-specific tooling and common scenario playbooks.

## Bug Classification Decision Tree

```
Bug Report / Symptom
│
├─ Crash
│  ├─ Segfault / Access Violation
│  │  └─ Check: null pointer, buffer overflow, use-after-free, stack overflow
│  ├─ Panic / Fatal Error
│  │  └─ Check: assertion failure, unrecoverable state, out-of-memory
│  └─ Unhandled Exception
│     └─ Check: missing error handler, unexpected input type, network failure
│
├─ Hang
│  ├─ Deadlock
│  │  └─ Check: lock ordering, mutex contention, channel blocking
│  ├─ Infinite Loop
│  │  └─ Check: loop termination condition, counter overflow, recursive call
│  └─ Blocked I/O
│     └─ Check: network timeout, DNS resolution, disk full, file lock
│
├─ Wrong Output
│  ├─ Logic Error
│  │  └─ Check: operator precedence, boundary conditions, boolean logic
│  ├─ Data Corruption
│  │  └─ Check: concurrent mutation, encoding mismatch, truncation
│  └─ Off-by-One
│     └─ Check: loop bounds, array indexing, fence-post errors
│
├─ Performance
│  ├─ Slow Queries
│  │  └─ Check: missing index, N+1 queries, full table scan, lock wait
│  ├─ Memory Bloat
│  │  └─ Check: cache without eviction, leaked references, large allocations
│  └─ CPU Spikes
│     └─ Check: hot loops, regex backtracking, excessive GC, busy-wait
│
└─ Intermittent
   ├─ Race Condition
   │  └─ Check: shared mutable state, read-modify-write, check-then-act
   ├─ Timing-Dependent
   │  └─ Check: timeout values, clock skew, event ordering assumptions
   └─ Environment-Specific
      └─ Check: OS differences, locale, timezone, file system case sensitivity
```

## Systematic Debugging Workflow

Six-step process from symptom to prevention:

### Step 1: Reproduce

Confirm the bug exists and create a reliable reproduction. A bug you cannot reproduce is a bug you cannot confidently fix. Capture exact inputs, environment, and sequence of operations.

### Step 2: Isolate

Narrow the fault to the smallest possible scope. Use binary search (git bisect, commenting out code halves), stubs, feature flags, and environment isolation to eliminate innocent code.

### Step 3: Identify

Find the root cause, not just the proximate trigger. Use the 5 Whys technique, trace execution, inspect state at key points. Distinguish between the symptom and the underlying defect.

### Step 4: Fix

Apply the minimal correct change that addresses the root cause. Avoid shotgun debugging (changing multiple things at once). Understand why the fix works, not just that it works.

### Step 5: Verify

Confirm the fix resolves the original issue without introducing regressions. Re-run the original reproduction case. Run the full test suite. Test edge cases related to the fix.

### Step 6: Prevent

Add a regression test. Update documentation or runbooks if applicable. Consider whether the same class of bug could exist elsewhere. Share findings with the team.

## Reproduction Checklist

```
[ ] Minimal reproduction steps documented (numbered, unambiguous)
[ ] Environment captured (OS, runtime version, dependencies, config)
[ ] Exact inputs recorded (request payload, CLI args, file contents)
[ ] Timing sensitivity assessed (does it fail only under load? after delay?)
[ ] Single-threaded reproduction attempted (eliminates concurrency noise)
[ ] Reproduction automated as script or test case
[ ] Confirmed reproduction is deterministic (fails N/N attempts)
[ ] Identified whether reproduction requires specific data/state
```

## Isolation Techniques Quick Reference

| Technique | Method | Best For |
|-----------|--------|----------|
| **Binary search (git)** | `git bisect start BAD GOOD` then `git bisect run ./test.sh` | Finding which commit introduced the bug |
| **Binary search (code)** | Comment out half the code, test, repeat | Narrowing fault location in unfamiliar code |
| **Stubs/Mocks** | Replace dependencies with known-good fakes | Isolating from external services |
| **Feature flags** | Toggle features off one by one | Finding which feature causes the issue |
| **Environment isolation** | Docker container, fresh VM, clean install | Eliminating environment contamination |
| **Network interception** | mitmproxy, Charles Proxy, mock server | Isolating client vs server issues |
| **Input reduction** | Remove input fields/data until bug disappears | Finding minimal trigger |
| **Dependency pinning** | Lock all deps, update one at a time | Finding breaking dependency update |

## Root Cause Analysis Template

### 5 Whys Example

```
Problem: API returns 500 error on user login

1. Why? → The database query throws a timeout exception
2. Why? → The users table scan takes >30 seconds
3. Why? → There is no index on the email column
4. Why? → The migration that adds the index was never run in production
5. Why? → The deployment script skips migrations when the --fast flag is used

Root cause: Deployment script's --fast flag bypasses migrations
Fix: Remove --fast flag behavior that skips migrations, add migration check to health endpoint
Prevention: CI check that verifies all migrations are applied after deployment
```

### Fault Tree Basics

```
                    [System Failure]
                    /              \
            [Hardware]          [Software]
            /       \           /        \
       [Disk]    [Memory]  [Config]   [Code Bug]
                              |          |
                         [Missing    [Race in
                          env var]    worker pool]
```

Work from the top (observed failure) down to leaves (root causes). Each branch is an AND/OR gate -- AND means all children must be true, OR means any one child suffices.

## Language-Specific Debugger Quick Reference

| Language | Tool | Launch Command | Key Commands |
|----------|------|----------------|--------------|
| **Node.js** | Chrome DevTools | `node --inspect-brk app.js` | Open `chrome://inspect`, set breakpoints in Sources |
| **Node.js** | ndb | `npx ndb app.js` | Enhanced DevTools with blackboxing |
| **Python** | pdb | `python -m pdb script.py` | `n` next, `s` step, `c` continue, `p expr` print, `bt` backtrace |
| **Python** | debugpy | `python -m debugpy --listen 5678 --wait-for-client script.py` | VS Code "Attach" launch config |
| **Python** | breakpoint() | Insert `breakpoint()` in code | Drops into pdb at that line (Python 3.7+) |
| **Go** | Delve | `dlv debug ./cmd/server` | `b main.go:42` break, `c` continue, `n` next, `p var` print |
| **Go** | Delve (test) | `dlv test ./pkg/...` | Debug test functions directly |
| **Go** | Delve (attach) | `dlv attach PID` | Debug running process |
| **Rust** | rust-gdb | `rust-gdb target/debug/myapp` | `b main`, `r`, `n`, `p variable`, `bt` |
| **Rust** | rust-lldb | `rust-lldb target/debug/myapp` | `b s main`, `r`, `n`, `p variable`, `bt` |
| **Rust** | CodeLLDB | VS Code extension | GUI breakpoints, variable inspection |
| **Browser** | DevTools | F12 or Ctrl+Shift+I | Elements, Console, Network, Sources, Performance, Memory |

### Quick Debug Snippets

```javascript
// Node.js: drop into debugger at this point
debugger;

// Node.js: conditional breakpoint
if (user.id === 'problem-user') debugger;
```

```python
# Python: drop into debugger at this point
breakpoint()

# Python: conditional breakpoint
if user_id == 'problem-user':
    breakpoint()
```

```go
// Go: print goroutine stacks (send SIGQUIT or SIGABRT)
// kill -QUIT <pid>
// Or in code:
import "runtime/debug"
debug.PrintStack()
```

```rust
// Rust: enable full backtraces
// RUST_BACKTRACE=1 cargo run
// RUST_BACKTRACE=full cargo run
```

## Log-Based Debugging Patterns

### Strategic Logging

Place logs at decision points, not just error paths:

```
[ENTRY] function_name(args_summary)     -- entering the function
[STATE] key_variable=value              -- state at critical decision point
[BRANCH] taking path X because Y       -- which branch and why
[EXIT] function_name -> result_summary  -- leaving the function
[ERROR] operation failed: detail        -- error with context
```

### Correlation IDs

Trace a single request across services:

```bash
# Generate at entry point, propagate through all calls
X-Request-ID: 550e8400-e29b-41d4-a716-446655440000

# Search across all service logs
rg "550e8400-e29b-41d4-a716-446655440000" /var/log/services/
```

### Timeline Reconstruction

```bash
# Merge and sort logs from multiple sources by timestamp
sort -t' ' -k1,2 service-a.log service-b.log service-c.log > timeline.log

# Find gaps in activity (potential hang/block)
awk '{print $1, $2}' timeline.log | uniq -c | sort -rn | head -20
```

### Structured Log Queries

```bash
# jq queries on JSON logs
# Find all errors for a specific user
jq 'select(.level == "error" and .user_id == "u123")' app.log

# Get timing distribution for slow requests
jq 'select(.duration_ms > 1000) | .duration_ms' app.log | sort -n

# Count errors by type
jq -r 'select(.level == "error") | .error_type' app.log | sort | uniq -c | sort -rn
```

## Common Gotchas

| Gotcha | Why It Hurts | Fix |
|--------|-------------|-----|
| Fixing symptoms, not root cause | Bug resurfaces in a different form | Use 5 Whys to dig deeper |
| Debugging in production without safety net | Risk of data loss or extended outage | Use read-only queries, feature flags, canary deploys |
| Heisenbug (disappears under observation) | Adding logging/breakpoints changes timing | Use non-invasive tools: `strace`, sampling profiler, `rr` |
| Assumption bias ("it can't be X") | Skipping the actual cause because you trust it | Test every assumption explicitly, even "obvious" ones |
| Missing reproduction case | Cannot verify fix, cannot prevent regression | Invest time upfront in reliable reproduction |
| Over-relying on print/log debugging | Slow iteration, pollutes code, misses concurrency bugs | Use proper debugger, profiler, or tracing tool |
| Not checking recent changes | The answer is often in the last few commits | `git log --oneline -20`, `git diff HEAD~5` |
| Ignoring warning messages | Warnings often predict the error that follows | Treat warnings as errors during debugging |
| Debugging wrong version/branch | Wasting time on already-fixed or different code | Verify `git branch`, `git log -1`, runtime version |
| Not reading the full stack trace | Root cause is often in the middle, not the top | Read bottom-up: find your code in the trace first |
| Changing multiple things at once | Cannot tell which change fixed (or broke) it | One change per test cycle |
| Not capturing the "before" state | Cannot diff against working baseline | Snapshot config, deps, data before debugging |

## Reference Files

| File | Contents | Lines |
|------|----------|-------|
| `references/systematic-methods.md` | Scientific method, binary search, delta debugging, differential debugging, time-travel debugging, team debugging | ~600 |
| `references/tool-specific.md` | Browser DevTools, Node.js, Python, Go, Rust, database, network, Docker debugging tools | ~650 |
| `references/common-scenarios.md` | Memory leaks, deadlocks, race conditions, performance regressions, API debugging, deployment issues | ~550 |

## See Also

- **testing-ops** -- Write tests to prevent bugs from recurring
- **security-ops** -- Security-specific debugging (auth failures, injection, CSRF)
- **monitoring-ops** -- Production observability, alerting, dashboards
- **code-stats** -- Measure code complexity and identify bug-prone areas
- **container-orchestration** -- Docker and Kubernetes debugging context
- **git-ops** -- Git bisect workflow and history investigation
