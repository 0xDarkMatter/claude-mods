# Lane Brief Template

The contract each parallel worker needs so its branch can land through the fleet queue, and so the session that spawned it can judge what comes back. Embed it wherever the worker is spawned:

- **Background agent**: append it to the `claude --bg "<prompt>"` text
- **Agent team teammate**: include it in the teammate's spawn prompt
- **Manual session** (Path B, `fleet init`): paste it as the opening message

Fill in the seven fields. One you cannot fill means the lane is not scoped yet: finish scoping before you spawn it.

## Contents

- [The brief](#the-brief)
- [Filling in the fields](#filling-in-the-fields)
- [Owning what comes back](#owning-what-comes-back)
- [Native-spawn note](#native-spawn-note)
- [Why the scope rule matters](#why-the-scope-rule-matters)
- [Per-language test cmd snippets](#per-language-test-cmd-snippets)

## The brief

```
You are a fleet-ops lane.

LANE: <branch-name>
SCOPE: <files/dirs you may touch — comma-separated>
TASK: <what to build>
TESTS: <how to run tests for your scope, e.g. "pytest tests/test_auth.py">
ACCEPTANCE: <the observable results that mean done, one per line>
TIMEBOX: <rough cap on your working time, e.g. "90 minutes">
FORBIDDEN: <actions and paths this lane must leave alone, beyond the rules below>

Setup:
  Work on branch <branch-name>. If you're in a worktree already on it, stay put;
  otherwise: git checkout <branch-name>

Rules:
  - Only modify files within SCOPE. If you need to go outside, STOP and ask.
  - Never do what FORBIDDEN lists. Off limits whatever it says: pushing,
    force-pushing, deploying, writing in another worktree, and weakening or
    deleting a test so that it passes.
  - Make atomic commits with conventional commit messages as you go.
  - Run TESTS before finishing, capturing the log AND the exit code:
      <test-cmd> 2>&1 | tee <path-to-test-log>; rc=${PIPESTATUS[0]}
  - When tests pass and you're ready to land, run:
      bash .claude/fleet/signal.sh READY <path-to-test-log> $rc
    Ready means you checked every ACCEPTANCE line and each one holds.
  - If you hit a conflict, scope creep, or any unresolvable issue, run:
      bash .claude/fleet/signal.sh CONFLICT "<one-line reason>"
    then stop and explain.
  - When TIMEBOX runs out, start nothing new. Commit what you have (a wip:
    commit is fine), then run:
      bash .claude/fleet/signal.sh CONFLICT "timebox: <what remains>"
    and report PARTIAL. Unfinished work never signals READY.
  - Do not merge to main yourself. The fleet landing queue handles that.
  - Before you branch from or rebase onto main (starting out, or fixing a
    CONFLICT), run `fleet status`. A tip it marks PROVISIONAL is a merge still
    under its land's test gate: NOT landed, and a red gate resets it. Wait
    until `fleet landing` exits 0, then branch or rebase.
  - End with this REPORT, every line filled ("none" where nothing applies):
      STATUS:     READY | PARTIAL | BLOCKED  (READY sent READY; the others CONFLICT)
      BRANCH:     <branch> @ <head sha>
      ACCEPTANCE: each line, met or not met, and the evidence
      RAN:        every check you ran, with its exit code
      CHANGED:    every file you touched, one line each
      DEVIATIONS: where you departed from the brief, and why
      REMAINING:  what is still undone
    Label each claim measured, inferred or guess.

Begin.
```

The PROVISIONAL rule exists because `fleet land` merges first and gates second: for the whole gate, `main`'s tip is a `merge: <lane>` commit that a red gate hard-resets. Lanes that read it as landed have branched from it and rebased onto it. Details: [landing.md](landing.md#provisional-main).

## Filling in the fields

| Field | Example |
|-------|---------|
| `LANE` | `auth-middleware` (matches the branch name from `fleet init` / `fleet track`) |
| `SCOPE` | `src/auth/, tests/test_auth.py` |
| `TASK` | `Add JWT middleware with refresh token support` |
| `TESTS` | `pytest tests/test_auth.py 2>&1 | tee tests/test_auth.log` |
| `ACCEPTANCE` | `An expired access token gets 401` / `POST /auth/refresh with a valid refresh token returns a new access token` |
| `TIMEBOX` | `90 minutes` |
| `FORBIDDEN` | `src/billing/, db/migrations/; no new dependencies` |

The tee'd log plus the exit code (`${PIPESTATUS[0]}` — tee's own exit is always 0) is what `signal.sh READY` uses to verify tests passed. The exit code is the authoritative verdict; the log is evidence.

**ACCEPTANCE** is what the lane gets judged against. TESTS shows nothing broke; ACCEPTANCE shows the task got done. Write each line as something a reader can observe (a command's output, a response, a file that now exists), never "works well".

**TIMEBOX** is a rough cap that lets a stuck lane notice it is stuck. A lane that stops and hands back a committed branch gives the next round somewhere to start; one that runs on burns budget and holds up the wave. `fleet status` lists it as `CONFLICT` with its `timebox:` reason, so half-done work cannot land.

**FORBIDDEN** complements SCOPE. SCOPE says where the lane may write; FORBIDDEN names what it must leave alone even there: a migration, a lockfile, a new dependency, a public API.

**REPORT** has a fixed shape so the spawning session can line several lanes up and spot a gap at a glance. It is a map to the diff, not a stand-in for it ([below](#owning-what-comes-back)).

## Owning what comes back

The brief governs the lane. These rules govern the session that spawned it, usually MAIN. Spawning a lane hands off the typing, never the responsibility: what it returns is yours once you land it.

1. **Read the diff, not the report.** The REPORT says where to look; `git diff main...<lane>` (and `fleet scrub-check <lane>`) is what you would land. Hold the ACCEPTANCE lines up against the diff and the evidence, then write your own account of the lane instead of forwarding its summary, which records only what the worker believes it did.
2. **Each new round gets a fresh agent.** A fix, a retry, a follow-up or the next item goes to a new agent whose brief combines the first task, each instruction added since, and the last round's REPORT and branch. Committed lane work lives on the branch, so starting fresh loses nothing. Resuming or messaging an old agent quietly drops instructions that arrived by interrupt or across resumes, and carries over its mistaken picture of the work. Reuse one only when the next step needs something that agent alone holds and cannot hand over cheaply: uncommitted edits, or a server or watcher it has running.
3. **No result is not a pass.** A lane that never reported, a session that crashed, a land log with no `running test_cmd:` line, an empty or cut-off test log, a PARTIAL, a verifier that could not run: each means *not verified yet*. Leave the lane unlanded until a fresh run gives an answer. Account for every lane you spawned. Doing a vanished lane's work yourself conceals that it failed and leaves what it was meant to cover unexamined.
4. **The author never verifies.** An agent checking its own change tests its intent, not its output. A lane's own test run and its `READY` are its self-report. The verdict comes from something other than the author: the land gate's `test_cmd`, or a verifier agent, preferably on a different model from the author's.

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

`signal.sh` trusts, in order: the exit-code argument, a trailing `exit code: N` line in the log, a recognized runner summary line (vitest/jest `Tests …`, pytest `=== N passed ===`, cargo `test result:`, go `FAIL`/`ok`), and only then a count-anchored fallback (`N failed`). If your runner's output is unusual and you can't pass the exit code, append `echo "exit code: $rc" >> <log>` — it never word-greps prose, so stderr lines like `… failed: No such module` in a green run won't false-refuse.
