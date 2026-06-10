# Lane Brief Template

The contract each parallel worker needs so its branch can land through the fleet queue. Embed it wherever the worker is spawned:

- **Background agent**: append it to the `claude --bg "<prompt>"` text
- **Agent team teammate**: include it in the teammate's spawn prompt
- **Manual session** (Path B, `fleet init`): paste it as the opening message

Fill in the four fields.

---

```
You are a fleet-ops lane.

LANE: <branch-name>
SCOPE: <files/dirs you may touch — comma-separated>
TASK: <what to build>
TESTS: <how to run tests for your scope, e.g. "pytest tests/test_auth.py">

Setup:
  Work on branch <branch-name>. If you're in a worktree already on it, stay put;
  otherwise: git checkout <branch-name>

Rules:
  - Only modify files within SCOPE. If you need to go outside, STOP and ask.
  - Make atomic commits with conventional commit messages as you go.
  - Run TESTS before finishing.
  - When tests pass and you're ready to land, run:
      bash .claude/fleet/signal.sh READY <path-to-test-log>
  - If you hit a conflict, scope creep, or any unresolvable issue, run:
      bash .claude/fleet/signal.sh CONFLICT "<one-line reason>"
    then stop and explain.
  - Do not merge to main yourself. The fleet landing queue handles that.

Begin.
```

---

## Filling in the fields

| Field | Example |
|-------|---------|
| `LANE` | `auth-middleware` (matches the branch name from `fleet init` / `fleet track`) |
| `SCOPE` | `src/auth/, tests/test_auth.py` |
| `TASK` | `Add JWT middleware with refresh token support` |
| `TESTS` | `pytest tests/test_auth.py 2>&1 | tee tests/test_auth.log` |

The tee'd log is what `signal.sh READY` reads to verify tests passed.

## Native-spawn note

If the worker is a background agent spawned *before* `fleet track` ran, `signal.sh` will refuse with `branch '<name>' is not a registered lane` — run `fleet track <name>` from the main checkout and have the session re-signal. Alternatively skip signaling entirely and land natively-spawned branches by hand with `fleet land <branch>` once you've reviewed them.

## Why the scope rule matters

If two lanes silently edit the same file, the queue's auto-rebase will throw a conflict on the second one. By forcing each worker to declare and respect its scope, you catch the overlap at design time, not merge time. (Agent teams give you the same advice — "break the work so each teammate owns a different set of files" — but enforce nothing; the scrub + rebase steps here are the enforcement.)

## Per-language test cmd snippets

| Language | Tee'd test command |
|----------|---------------------|
| Python (pytest) | `pytest tests/test_X.py 2>&1 \| tee tests/test_X.log` |
| Node (jest) | `npx jest src/X 2>&1 \| tee tests/test_X.log` |
| Go | `go test ./pkg/X/... 2>&1 \| tee tests/test_X.log` |
| Rust | `cargo test --lib X 2>&1 \| tee tests/test_X.log` |
| Just | `just test-X 2>&1 \| tee tests/test_X.log` |

`signal.sh` does crude pass detection — it works fine for these. If your test runner has unusual output, write a small grep-friendly summary line at the end.
