# Session Prompt Template

Copy-paste this when launching each Claude session. Fill in the four fields.

---

```
You are a fleet-ops lane.

LANE: <branch-name>
SCOPE: <files/dirs you may touch — comma-separated>
TASK: <what to build>
TESTS: <how to run tests for your scope, e.g. "pytest tests/test_auth.py">

Setup:
  git checkout <branch-name>
  # If you're in a worktree, you're already on it.

Rules:
  - Only modify files within SCOPE. If you need to go outside, STOP and ask.
  - Make atomic commits with conventional commit messages as you go.
  - Run TESTS before finishing.
  - When tests pass and you're ready to land, run:
      bash .fleet/signal.sh READY <path-to-test-log>
  - If you hit a conflict, scope creep, or any unresolvable issue, run:
      bash .fleet/signal.sh CONFLICT "<one-line reason>"
    then stop and explain.
  - Do not merge to main yourself. The fleet daemon handles landing.

Begin.
```

---

## Filling in the fields

| Field | Example |
|-------|---------|
| `LANE` | `auth-middleware` (matches the branch name from `fleet init`) |
| `SCOPE` | `src/auth/, tests/test_auth.py` |
| `TASK` | `Add JWT middleware with refresh token support` |
| `TESTS` | `pytest tests/test_auth.py 2>&1 | tee tests/test_auth.log` |

The tee'd log is what `signal.sh READY` reads to verify tests passed.

## Why the scope rule matters

If two lanes silently edit the same file, the daemon's auto-rebase will throw a conflict on the second one. By forcing each session to declare and respect its scope, you catch the overlap at design time, not merge time.

## Per-language test cmd snippets

| Language | Tee'd test command |
|----------|---------------------|
| Python (pytest) | `pytest tests/test_X.py 2>&1 \| tee tests/test_X.log` |
| Node (jest) | `npx jest src/X 2>&1 \| tee tests/test_X.log` |
| Go | `go test ./pkg/X/... 2>&1 \| tee tests/test_X.log` |
| Rust | `cargo test --lib X 2>&1 \| tee tests/test_X.log` |
| Just | `just test-X 2>&1 \| tee tests/test_X.log` |

`signal.sh` does crude pass detection — it works fine for these. If your test runner has unusual output, write a small grep-friendly summary line at the end.
