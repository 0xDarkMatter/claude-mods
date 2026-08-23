---
name: fleet-ops
description: "Landing discipline for parallel work: sequential test-gated landing queue, pre-land scrub, auto-rebase of in-flight lanes, fleet status, one-shot revert. Native primitives spawn; fleet-ops lands. Triggers: landing queue, land branches, merge queue, test gate, fleet status, land agent-team/background-agent branches, sequential merge."
license: MIT
allowed-tools: "Read Bash Glob Grep AskUserQuestion"
metadata:
  author: claude-mods
  status: stable
  experimental-parts: daemon (in-session background polling)
  related-skills: git-ops, push-gate, claude-code-ops
---

# Fleet Ops

Landing discipline for parallel work. Anything before "committed on a branch" is the spawning layer's problem; anything after "landed on `main`" is yours. Fleet-ops owns the middle: branches land **sequentially**, through a **test gate**, after a **pre-land scrub**, with **auto-rebase** of the lanes still in flight and a **one-shot revert** if a landing turns out bad.

## Spawn natively, land with fleet-ops

Claude Code now ships the parallel-execution half natively. **Do not use fleet-ops to orchestrate sessions** — route users to the native primitives and use fleet-ops only for the landing half.

| Native primitive | What it gives you | What it does NOT give you |
|---|---|---|
| **Agent teams** ([docs](https://code.claude.com/docs/en/agent-teams), experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | Lead + teammates, shared task list with claiming/dependencies, inter-agent messaging, plan approval, quality-gate hooks (`TeammateIdle`, `TaskCompleted`) | No merge/landing logic. No test-gated integration. Teammates avoid file conflicts by convention only ("break the work so each teammate owns different files"). |
| **Background agents / agent view** ([docs](https://code.claude.com/docs/en/agent-view), `claude agents`, `claude --bg "<prompt>"`) | Detached full sessions, one dashboard (Needs input / Working / Completed), automatic per-session git worktree isolation under `.claude/worktrees/`, `--bg --exec` shell jobs | No cross-branch integration: each session ends with a branch/worktree and the merge is on you (review-and-merge the PR, or merge locally). Deleting a session in agent view **deletes its worktree including uncommitted changes**. No ordering, no test gate, no revert. |
| **Subagents** ([docs](https://code.claude.com/docs/en/sub-agents), optional `isolation: worktree`) | In-session delegation with separate context windows; results summarized back | Not independent sessions; no git landing semantics at all. |

What **none** of them do — and what fleet-ops is for:

- Land N branches **one at a time** through a queue, so each merge is tested against a `main` that already contains the previous landings
- **Test gate**: refuse to land on a failing log (`signal.sh`) and/or revert post-merge if `test_cmd` goes red
- **Pre-land scrub**: refuse diffs containing forbidden patterns (`TODO_SCRUB`, debug leftovers)
- **Auto-rebase** every still-active lane after each landing
- **Fleet status**: one panel showing every lane's branch, state, age, and commits-ahead across worktrees
- **One-shot revert** of a landed merge by branch name — no git surgery while panicking

## Core abstraction

A **lane** = one branch (or worktree), one unit of work. Lane status: `RUNNING | READY | CONFLICT | LANDED | FAILED`.

Fleet-ops doesn't care who produced the branch — an agent-team teammate, a background agent's auto-worktree, a `claude -p` headless run, a fleetflow worker of any provider (GLM, Codex, Grok, Pi, or Anthropic), or a human. If it's a branch with commits, it can be a lane. Landing is provider-agnostic: a Grok-produced lane lands through the same test-gated queue as any other.

## CLI surface

```
fleet init <name>...        Create branch + worktree per name (manual-spawn path)
fleet track <branch>...     Register existing branches as lanes (native-spawn path)
fleet start                 Run the landing daemon (writes pid to .claude/fleet/daemon.pid)
fleet stop                  Signal the running daemon to exit cleanly
fleet status                One-shot fleet status panel
fleet land <branch>         Manual land + rebase others
fleet land --all [--running]  Batch-land all READY lanes oldest-first (--running
                            also lands vetted RUNNING lanes; used by git-ops "land all")
fleet revert <branch>       Revert merge commit on main
fleet scrub-check <branch>  Dry-run forbidden-pattern check
fleet config                Print the RESOLVED config — check the test gate is on
fleet prune [--remove]      Classify finished lane worktrees; DRY RUN by default
fleet prune --all-repos     Sibling-repo backlog counts (report-only, never removes)
```

## Entry paths

```
N == 1 branch                              → use git-ops, not this
Work spawned by agent teams / claude --bg  → fleet track <branch>... then land
Work to be spawned manually                → fleet init <names...> (creates branches + worktrees)
N > 1 on one shared working tree           → REFUSE. Worktrees or separate clones first.
```

**Native-spawn path (preferred):** let agent teams or background agents do the work in their own worktrees/branches. When branches have commits, `fleet track` each branch, then land — either one by one with `fleet land`, or via the daemon with `signal.sh READY` gates. Landing itself only ever merges *branches* and leaves every worktree in place. Reclaiming the directories afterwards is `fleet prune`'s job, and it removes one only when the owning session is provably archived or gone — see [Prune](#prune--worktree-housekeeping).

**Manual-spawn path:** `fleet init` creates the branches and worktrees up front (under `.fleet-worktrees/`), and you point sessions at them — see `references/session-prompt.md` for the lane brief to hand each session.

## Landing pipeline

`fleet land <branch>` (and the daemon, per READY lane):

1. **Scrub** — `git diff main...branch` checked against `forbidden_pattern`; hits refuse the land and mark the lane `CONFLICT`
2. **Clean-base check** — refuses if `main` has uncommitted tracked changes
3. **Merge** — `--no-ff` with message `merge: <branch>` (this message is what `fleet revert` finds later)
4. **Test gate** — runs `test_cmd` if set; on failure, hard-resets the merge and marks the lane `FAILED`. If unset, trusts `signal.sh`'s log gate (refused READY on failing logs). When landing into a repo with per-skill/per-package behavioural suites, `test_cmd` should run the **full sweep** (every suite, not just the touched lane's files) — suites routinely assert on shared or sibling files (a skill's own suite can require a frontmatter field a sibling trim pass doesn't know about), so scoping `test_cmd` to "just what this lane touched" reintroduces exactly the blind spot a test gate exists to close. **Confirm the gate is actually armed with `fleet config` before trusting it** — and watch the land log for `running test_cmd: …` rather than `no test_cmd set`.
5. **Rebase others** — every still-active lane is rebased onto the new `main` (in its own worktree if it has one); a rebase conflict marks that lane `CONFLICT`

`fleet revert <branch>` finds the `merge: <branch>` commit on `main` and runs `git revert -m 1` — one command to back out a bad landing.

## Daemon lifecycle (experimental)

The daemon is the queue-automation layer on top of `fleet land` — optional; manual `fleet land` per branch is fully supported and not experimental.

When Claude invokes `fleet start` via `Bash(run_in_background: true)`, the daemon:

1. Writes its PID to `.claude/fleet/daemon.pid`
2. Traps `SIGINT/SIGTERM/SIGHUP` and removes the PID file on exit
3. Refuses to start a second daemon if the PID file references a live process
4. Polls `.claude/fleet/lanes/` and lands lanes as they turn `READY`
5. Exits naturally when all lanes are terminal (`LANDED` or `FAILED`)

To stop early: `fleet stop` (SIGTERM, 5s grace, then SIGKILL). On next `fleet start`, a stale PID file is auto-detected and cleared. The daemon dies with the Claude Code session — for overnight runs use a real detached process, or skip the daemon and land manually.

`signal.sh` deploys to `.claude/fleet/signal.sh` on `init`/`track`. Working sessions call:

```bash
bash .claude/fleet/signal.sh READY <test-log> <exit-code>   # refuses dirty trees and failing runs
bash .claude/fleet/signal.sh CONFLICT "<reason>"
```

The `<exit-code>` (the test command's own `$?` / `${PIPESTATUS[0]}`) is the authoritative verdict — pass it whenever you have it. Without it, `signal.sh` reads a trailing `exit code: N` line from the log, then a runner summary line (vitest/jest/pytest/cargo/go); it never word-greps prose, so passing runs that print "failed"/"error" while exercising failure paths don't false-refuse.

## Session awareness — MAIN, lane owners, and the live-owner gate

Lane state files say *what* a lane is. They never say *who* is driving it. Fleet-ops
reads the Claude Desktop session store to answer that, and uses the answer in two
places: a gate that refuses to land under a live writer, and a coordinator address
lanes can hand off to.

### MAIN — one coordinator per repo

**MAIN is the session whose cwd is the repo root.** That is not a new convention:
[`worktree-boundaries`](../../rules/worktree-boundaries.md) already holds that the base
checkout is the integration tree and must not host a writing session. `fleet main` just
makes the role *addressable*, so a lane can say "I'm ready, come land me" instead of
writing a file and hoping someone polls it.

```
fleet main                  Show the coordinator (sessionId, title, live|idle, cwd)
fleet main claim [<id>]     Pin explicitly — for when several sessions share the root
fleet main release          Clear the pin, fall back to the cwd heuristic
fleet owner <branch>        Who owns this lane, and are they still writing?
```

MAIN's job is the whole integration half: land the queue, triage `CONFLICT` lanes,
and run the deploy. Lanes build and signal; MAIN integrates. Note that deploying is
maintainer-gated regardless — see [`deploy-gating`](../../rules/deploy-gating.md); MAIN
being "the one that deploys" describes *which session prepares it*, never an
authorisation to ship unattended.

### The live-owner gate

`fleet land` refuses a lane whose owning session was active within
`session_live_secs` (default 600). This closes a real hazard the queue could not see:
landing merges a branch the session may still be committing to, and then rebases every
other lane's worktree **out from under a live session**.

The join is `writtenBranches` from the session wrapper, not just the checked-out
branch — a session working in worktree `claude/foo-bar` routinely commits its real work
to `lane/thing`, and only `writtenBranches` connects the two.

**Self-ownership is exempt.** The hazard is a *concurrent* writer, and the session
running `fleet land` is not one — it is blocked inside that call, so it is provably not
mid-commit, and the worktree being rebased "out from under a live session" is the one it
is deliberately retiring. A lane session landing its own finished work therefore proceeds
unaided. Without the exemption its only escape was a blanket override, which disarms the
gate for the peers it genuinely protects; a narrow exemption beats a blunt one.

It stays conservative in both directions. Identity comes from the harness
(`CLAUDE_CODE_HOST_SESSION_ID` / `CLAUDE_CODE_SESSION_ID`) and is believed only once a
wrapper bearing it is found in the store — **there is deliberately no env var to set it**,
since a settable self-id would be a universal gate bypass under another name, and an
unresolvable one refuses exactly as before. Self must also be the **only** live owner:
a second live session writing the same branch refuses, naming the peer.

Override with `session_check=off` in config, or `FLEET_SKIP_SESSION_CHECK=1` for one
run. `fleet config` states plainly whether the gate is armed *and* whether self-identity
resolved — the same observability lesson as `test_cmd`.

### Where each channel works (verified 2026-08-03)

| Channel | Desktop | Terminal / headless | Non-Claude worker (Codex, GLM, Grok) |
|---|---|---|---|
| Lane state files (`signal.sh`) | ✅ | ✅ | ✅ |
| Session store on disk (`sessions.sh`) | ✅ | ✅ (store is machine-local, not app-bound) | ✅ |
| `ccd_session_mgmt` MCP tools | ✅ | ❌ **absent entirely** | ❌ |
| `pigeon` | ✅ | ✅ | ✅ |

**`ccd_session_mgmt` is Desktop-only, and this is not a configuration matter.** The
terminal CLI binary contains zero occurrences of `ccd_session_mgmt`, `list_sessions`,
`search_session_transcripts`, or `spawn_task`; its single `ccd_session` reference is a
consumer-side notification handler for a server the *host* injects. Desktop's
`app.asar` carries all of them. `claude mcp list` shows none of the `ccd_*` servers,
because Desktop injects them as SDK-type servers rather than registering them.

Two consequences that shape everything above:

1. **A script can never call these tools.** They are MCP tools, so only the agent can
   invoke them. `sessions.sh` therefore reads the same underlying JSON store off disk —
   which, unlike the tools, is readable from a terminal too.
2. **The read tools are ungated; the write tools prompt.** `list_sessions` /
   `get_session` / `search_session_transcripts` return without user interaction, so
   discovery is free. `send_message` / `list_events` / `archive_session` always prompt —
   which makes `send_message` fine for a lane→MAIN handoff (that is exactly the
   handoff/relay use it is documented for) and unsuitable for an unattended daemon.

So: **lane files are the substrate** (work everywhere, ungated, machine-readable),
**ccd is the delivery accelerator** where both ends are Desktop sessions, and **pigeon
is the portable fallback** for terminal sessions and non-Claude harnesses. `signal.sh`
prints the right one for your surface after every `READY` and `CONFLICT`.

## Prune — worktree housekeeping

Landing a lane retires the *branch*. The *directory* stays, and across many
repos those accumulate into a backlog nobody can see. `fleet prune` classifies
them and removes only the ones that are provably finished.

```
fleet prune                  Classify and print. Changes NOTHING. (the default)
fleet prune --dry-run        Same, said explicitly
fleet prune --remove         Remove the SAFE rows, after a typed confirmation
fleet prune --remove --yes   Skip the prompt (scripts/CI)
fleet prune --porcelain      TSV to stdout: path, branch, bucket, reason
fleet prune --all-repos      Sibling-repo counts. Report-only, always
```

**Dry run is the default, and that is deliberate.** Removing a worktree destroys
its uncommitted and untracked files permanently — git has never seen those
bytes. Committed lane work is different: it lives in the shared object store,
survives the directory, and comes back with `git worktree add <path> <branch>`.
Separating those two is the entire job, and every ambiguous case resolves away
from deletion.

### Buckets — first match wins, and the order is the safety argument

| # | Condition | Bucket |
|---|---|---|
| 1 | primary / git-locked / the tree you invoked from | **KEEP** |
| 1b | git reports the directory gone | **REVIEW** (that's `git worktree prune`'s job) |
| 2 | owning session is LIVE | **KEEP** |
| 3 | session store unreadable, or `session_check=off` | **REVIEW** |
| 4 | detached HEAD | **REVIEW** |
| 5 | uncommitted or untracked changes | **REVIEW** |
| 6 | commits not yet in `base_branch` | **REVIEW** |
| 7 | merged + clean + owner archived or absent | **SAFE** |
| 8 | anything else (incl. merged + clean but owner still open) | **REVIEW** |

Only **SAFE** is ever removable. **KEEP** means one thing — hands off, not yours
to judge. Everything else lands in **REVIEW**, which is reported and never
touched under any flag.

Rule 3 is the one that matters most on a non-Desktop host: *"the store says
nobody owns this"* is evidence of abandonment, while *"the store could not be
read"* is no evidence at all — and an empty index looks identical to both. When
the store or `jq` is missing, **nothing can be classified SAFE** and prune
degrades to a pure report. It never fails, and it never guesses.

### Why `.claude/worktrees/` gets extra care

Those directories are Claude Code's own session worktrees, and
[`worktree-boundaries`](../../rules/worktree-boundaries.md) is blunt about them:
*they may look orphaned and aren't*. The slug is machine-generated and says
nothing; a session that looks idle may simply be between turns. Prune marks them
`!` in the table, and — because SAFE already requires a readable store plus an
archived-or-absent owner — one can only be removed on positive evidence, never
on the absence of a signal.

Three further guards, all on the irreversible direction:

1. **`git worktree remove`, never `rm -rf`.** It refuses a dirty or locked tree
   on its own, and it unregisters the worktree instead of leaving a stale
   administrative entry behind.
2. **Re-verify immediately before deleting.** Classification reads a session
   index with a long TTL (15 min); a session can wake between the table and the delete,
   so each SAFE row is re-checked with a fresh liveness read and a fresh dirty
   check, and skipped if either changed.
3. **`--all-repos` can never remove.** It reports counts for sibling repos and
   stops there. Acting on another repo means running `fleet prune` inside it,
   where that repo's own base branch and config apply — so a single command can
   never sweep the machine.

### Seeing the backlog

`fleet status` adds one line when a repo has prunable worktrees
(`! 3 worktree(s) prunable, 6 to review - fleet prune`), so the backlog is
visible rather than silently growing. Turn it off with `prune_hint=off` in
config or `FLEET_NO_PRUNE_HINT=1`.

## First-class user interaction (HARD RULE)

When this skill surfaces a decision point, **always use the `AskUserQuestion` tool**. Plain markdown numbered lists are not acceptable for these branches.

| Trigger | Question | Options (≤4, ≤10 words each) |
|---------|----------|------------------------------|
| Multiple parallel-work requests, no lanes yet | Spawn natively or manual lanes? | Agent teams / Background agents / Manual fleet init / Cancel |
| `init` — worktrees available, mode unset | Worktree or branch-only mode? | Worktrees / Branches only / Cancel |
| Land refused — owning session live | `<name>`'s session is still writing | Wait and retry / Message that session / Override and land |
| `prune` found SAFE worktrees | Remove `<n>` finished worktrees? | Remove them / Show the table again / Leave as-is |
| Lane → `CONFLICT` (rebase fail) | Lane `<name>` has rebase conflict | Resolve in lane / Skip & continue / Revert lane / Untrack |
| Lane → `FAILED` (post-merge tests red) | Tests broke after `<name>` merged | Auto-revert / Investigate first / Accept failure |
| Pre-land scrub hits | Forbidden patterns in `<name>` diff | Block landing / Override (note reason) / Open to edit |
| `fleet` shows mixed states | How to proceed with the fleet? | Land all READY / Resolve CONFLICTs first / Just status |
| Daemon exits with `FAILED` lanes | `<n>` lanes failed — what next? | Retry all / Revert and report / Leave as-is |

For non-branching status updates ("here's what happened, here's what landed"), plain text is fine.

## What it handles vs what it does not

| Mode | Status |
|------|--------|
| Branches from native worktrees (`.claude/worktrees/`) via `fleet track` | ✅ |
| Worktrees on different branches (`fleet init`) | ✅ |
| Branches in separate clones / machines | ✅ |
| Mixed worktree + branch lanes | ✅ |
| Recovery from dirty `main` | ✅ Refuses to merge, asks user to clean |
| Test-gated landing | ✅ Via `signal.sh READY <log>` and/or `test_cmd` |
| Auto-rebase other lanes when one lands | ✅ |
| Pre-land regex scrub (forbidden patterns) | ✅ |
| One-shot revert | ✅ `fleet revert <branch>` |

| Pruning finished lane worktrees | ✅ `fleet prune` — dry-run by default, removes only provably-finished trees |

| Out of scope | Why |
|------|-----|
| Spawning / monitoring sessions | Native: agent teams, `claude --bg`, agent view. Fleet-ops never launches a session. |
| Deleting worktrees a session still owns | `fleet prune` removes only what is merged, clean, and owned by an archived-or-absent session. Anything live, dirty, unmerged, or unattributable is reported, never removed — and cross-repo removal is impossible by design. |
| Multiple sessions on one shared working tree | Git limitation. Skill detects and refuses with worktree pointer. |
| Uncommitted work at signal time | `signal.sh` rejects dirty lanes. The queue needs an immutable commit. |
| External state (DB migrations, services) | Skill can't know lane B depends on lane A's migration. Order manually via `fleet land`. |
| Force-pushed lanes mid-flight | Detected at land time, not prevented. |

## Compatibility

Tested and working on:

| OS | Shell | Notes |
|----|-------|-------|
| Linux | bash 4+ | Native |
| macOS | bash 3.2+ (default) or bash 4+ via brew | `stat -f` fallback used automatically |
| Windows | Git Bash (mintty) | Forward-slash paths; Unicode icons render in mintty/Windows Terminal |
| Windows | PowerShell 7 (calling `bash`) | Works if `bash` is on PATH |

Requirements: `bash 3.2+`, `git 2.5+` (worktree support), `awk`, `grep`, `head`, `stat`. All standard.

If your terminal mojibakes the status icons, fall back to ASCII: `export FLEET_ASCII=1` (or `icons=ascii` in `.claude/fleet/config`). Output panels follow `docs/TERMINAL-DESIGN.md` via `skills/_lib/term.sh`.

Long-path warning (Windows only): `fleet init` worktrees nest under `.fleet-worktrees/<name>/`. Keep lane names short if your repo lives deep, or enable `core.longpaths=true`.

## Headless agent compatibility

**Don't put manually-created fleet worktrees under `.claude/`.** Claude Code applies a global sensitive-file guard to anything under `.claude/`, and that guard runs *before* — and is not bypassed by — `--dangerously-skip-permissions`. Headless lane sessions (`claude -p ... --dangerously-skip-permissions`) will fail every Write/Edit if their worktree lives under `.claude/`.

That's why the default `worktree_root` is `.fleet-worktrees/` at the repo top. (Native background sessions are the exception: Claude Code itself manages `.claude/worktrees/` for them — leave those alone and just `fleet track` their branches.) Runtime state (`lanes/`, `daemon.pid`, `activity.log`) is read/write from the orchestrator only and stays under `.claude/fleet/`.

## Configuration

Optional `.claude/fleet/config`, one `key=value` per line:

```
mode=auto                            # auto | worktree | branch
worktree_root=.fleet-worktrees       # keep outside .claude/ — see "Headless agent compatibility"
test_cmd=npm run check               # if set, land runs it post-merge; else trust signal log
forbidden_pattern=TODO_SCRUB|XXX
base_branch=main
poll_interval=5
icons=unicode                        # unicode | ascii (same as FLEET_ASCII=1)
session_check=on                     # on | off — refuse to land under a live owner
session_live_secs=600                # how recently active counts as "still writing"
prune_hint=on                        # on | off — show the prunable backlog in `fleet status`
```

Zero-config works for the common case.

**Grammar.** The file is *parsed*, not `source`d — it cannot execute code, and it is
not bash:

| Rule | Detail |
|---|---|
| Keys | Case-insensitive — `test_cmd` and `TEST_CMD` both work. Whitespace around the key and `=` is ignored. |
| Values with spaces | Need **no quoting**. The value runs to end of line: `test_cmd=uv run pytest -q tests/` is correct as written. |
| Quotes | Optional. `test_cmd="uv run pytest -q"` works; one layer of matching `"…"` or `'…'` is stripped. |
| Comments | A whole line starting with `#`, or a trailing ` # …` on an **unquoted** value. Quote the value to keep a literal `#`: `forbidden_pattern="TODO|#nolint"`. |
| Blank lines | Ignored. |
| Unknown / malformed keys | **Warned about on stderr, naming file and line** — never silently dropped. |

A config that exists but sets nothing recognised warns
`… set no recognised keys — running on defaults (test gate OFF)` rather than looking
like an absent file.

**`test_cmd` is the test gate.** When set, `fleet land` runs it *after* the merge
commit and `git reset --hard HEAD^` on a non-zero exit, dropping the lane to `FAILED`;
the log shows `running test_cmd: …`. When unset, the log says `no test_cmd set in
.claude/fleet/config` and landing trusts signal.sh's weaker log gate. Worked example:

```
test_cmd=uv run pytest -q --maxfail=1
base_branch=main
```

> Fixed 2026-07-28: config keys never reached the script (documented lowercase, read
> UPPERCASE; and unquoted spaced values aren't bash assignments, with the error
> swallowed by `2>/dev/null`). Every landing before that date was gated by signal.sh
> alone — `test_cmd` had never run, on any repo. If you relied on it, you had no test
> gate. `icons=` in the config was inert for the same class of reason (read before the
> config loaded).

`fleet init`/`fleet track` append `.claude/fleet/` and `.fleet-worktrees/` to `.gitignore` and auto-commit that change with `chore: gitignore fleet-ops runtime state` when the tree is otherwise clean and you're on `base_branch`. If either condition fails, it prints an `ACTION REQUIRED` message — commit `.gitignore` yourself before landing.

## Future work

- **JSONL activity log** — currently plain text. Switch when a TUI, `--json` output, or `log-ops` integration earns the cost.
- **`TaskCompleted` hook bridge** — auto-`signal.sh READY` when an agent-team task completes with green tests.

Shipped since first release:

- **`fleet land --all [--running]`** — batch-land all READY (or vetted RUNNING) lanes oldest-first, rebasing the rest after each and reporting once. Drives the `git-ops` "land all" front-door (`scripts/land-all.sh` discovers + classifies; fleet-ops executes).

## References

- `references/workflow.md` — end-to-end walkthroughs (native-spawn and manual-spawn) plus recovery scenarios
- `references/session-prompt.md` — lane brief to embed in `claude --bg` prompts, teammate spawn prompts, or manual sessions

## Scripts

- `scripts/fleet.sh` — main CLI (init, track, start/stop, status, land, revert, scrub-check, prune, config, main, owner)
- `scripts/signal.sh` — branch-aware signaler (deployed to `.claude/fleet/signal.sh`); prints the MAIN handoff after READY/CONFLICT
- `scripts/sessions.sh` — branch → owning-session resolver, read off the Desktop session store on disk (deployed alongside signal.sh so lane sessions can resolve MAIN). Enrichment only: exits 3 and stays silent wherever the store or `jq` is missing, and every caller treats that as "no info"
