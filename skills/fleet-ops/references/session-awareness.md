# Session Awareness: the Live-Owner Gate and Channels

How fleet-ops decides a lane's owner is still writing, what the self-ownership exemption requires, how to override, and which session channels work where.

## Contents

- [The live-owner gate](#the-live-owner-gate)
- [`fleet owner` sees a session that moved in (2026-10-06)](#fleet-owner-sees-a-session-that-moved-in-2026-10-06)
- [Where each channel works (verified 2026-08-03)](#where-each-channel-works-verified-2026-08-03)
- [`scripts/sessions.sh`](#scriptssessionssh)

### The live-owner gate

`fleet land` refuses a lane whose owning session was active within
`session_live_secs` (default 600). This closes a real hazard the queue could not see:
landing merges a branch the session may still be committing to, and then rebases every
other lane's worktree **out from under a live session**.

The name join is `writtenBranches` from the session wrapper, not just the checked-out
branch — a session working in worktree `claude/foo-bar` routinely commits its real work
to `lane/thing`, and only `writtenBranches` connects the two. Since about 2026-09-24
Desktop writes each entry as `<worktreePath>\0<branch>` (a NUL between), where it once
wrote the bare branch, and the store holds both shapes. `sessions.sh` splits a pair:
the branch half joins the index, and the path half is a claim on that worktree (route
`written`).

**It also joins on the directory.** Any session claiming the worktree the lane branch
is checked out in blocks, whatever branch its wrapper records: branch drift and
`EnterWorktree` both defeat the name join (2026-09-28). The routes are the ones
[prune](../SKILL.md#prune--worktree-housekeeping) uses: wrapper `cwd`/`worktreePath`,
a `writtenBranches` path (`written`), the transcript's directory, and the transcript's
last recorded cwd (`live-cwd`). Both joins come from one read, `sessions.sh claimants
--fresh <branch>`, and `fleet owner` reads the same claims (below). The cached index may
nominate claimants but never decides: each one's liveness is re-read, and two routes
are read straight off disk, so a session that arrived after the index was built still
blocks: a transcript being written in the worktree, and a live transcript whose last
recorded cwd is the worktree or inside it, wherever the file is filed (~2s over ~15k
transcripts). Blind spot: a write by absolute path from a session whose cwd is
elsewhere.

### `fleet owner` sees a session that moved in (2026-10-06)

A Desktop session spawned in one worktree `EnterWorktree`'d into lane L, committed
there and stayed live. `fleet owner L` and `sessions.sh at --fresh` both reported no
owner, and a second session, taking the lane for orphaned, ported it to a new branch.
Four minutes later `fleet sweep` kept the same tree as `live session: ... (fresh
read)`. Three things hid the owner:

1. **The pairs.** Its `writtenBranches` named L as `<L's path>\0L`, read whole as one
   branch name that no lane ever equalled. Every name join was blind to every session
   on the new format.
2. **The resume.** When Desktop resumes a session that moved, it files the transcript
   under the wrapper's `cwd` again (the launch dir, a copy beside the old one) and
   re-enters L from the `worktree-state` records the transcript keeps. Only each
   record's `cwd` still names L, and the index records it only for a session live when
   the index was built. The earlier read's `paths` held no claim on L at all; sweep's
   index was most likely rebuilt (15-minute TTL) while the session was live.
3. **`owner` joined on the name alone.** Sweep and prune read the directory claims
   too; `owner` never had.

So `owner` is now the winning row of `claimants`: every session claiming the branch by
name or by its worktree, live first under `--fresh`, then open over archived, then the
newest, with its routes in column 8. The `written` claim holds while the owner is idle,
and `--fresh` reads every live transcript's recorded cwd. `at` also resolves a relative
path against the caller's directory; before, `at .claude/worktrees/x` compared the
relative string with stored absolute paths and printed nothing, which reads as "no
owner". A `/x/...` cwd (Git Bash form, found in nested `git_state` records) is folded
to `x:/...` so it matches. The suite's `-- owner: a session that moved into the lane --`
block reproduces all of it. Prune counts a `written` claim as a claim (it keeps a
tree), never as proof that an archived session finished there (it cannot make a tree
SAFE).

Expect more refusals than in the two weeks before the fix, all of them the gate working
as documented: the split restores the name join for every session on the new format,
so a lane is refused while any session that wrote its branch was active within
`session_live_secs`, wherever that session is working now. A lane session that hands
off and stays busy elsewhere holds its lane until it has been idle that long; `fleet
owner --fresh` names it, and its `written` row in `at` stays (idle) after that.

"Active" means the newer of the wrapper's `lastActivityAt` and the session's last
transcript write (its subagents' included), searched across every Desktop
instance's store. Until 2026-09-28 the gate read the wrapper alone, from the
primary instance alone — so a session deep in a long turn, or running in a
`--user-data-dir` instance, read as idle and did not block a land.

**An archived session is not active**, unless its transcript was written after the
archive. Archiving stops the session, and the stop itself appends records
(`last-prompt`, `cost-state`) to the transcript ~2s before Desktop rewrites the
wrapper with `isArchived: true`. Read naively, that write made every just-archived
session "live" for `session_live_secs`: the land gate refused its lane, and `fleet
prune` kept its worktrees (2026-10-05). Desktop stores no archive time, so the
wrapper's mtime stands in for it, and only a transcript write more than 60s newer
counts. That is what a `claude --resume` from a terminal would produce, and it
still blocks. An `isArchived` that is missing or not a boolean reads `?` (every
wrapper seen carries a boolean, so anything else is a format change). That is
never presumed archived: the session keeps timestamp liveness and counts as open.

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
unresolvable one refuses exactly as before. Self must also be the **only** live
claimant, by branch or by directory: a second live session writing the same branch, or
working in the same worktree, refuses, naming the peer. A CLI or headless session has
no store record to prove it is self, so if one is live in the lane's worktree the land
refuses, even when it is that session's own.

Override with `session_check=off` in config, or `FLEET_SKIP_SESSION_CHECK=1` for one
run. One run means one run: fleet consumes the variable at startup and strips it (and
the rest of the `FLEET_*` knob family) from the environment before `test_cmd` runs, so
the override can never disarm a gate inside the very suite the landing is gated on —
inherited into fleet-ops' own self-test, it once turned 6 live-owner refusal tests into
false FAILs and reverted a green merge (2026-09-01). `fleet config` states plainly
whether the gate is armed *and* whether self-identity resolved — the same observability
lesson as `test_cmd`.

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

## `scripts/sessions.sh`

- `scripts/sessions.sh` — branch → owning-session and directory → claiming-session resolver, read off every Desktop instance's session store plus the CLI transcripts on disk (deployed alongside signal.sh so lane sessions can resolve MAIN). `sessions.sh stores` shows what it read; `sessions.sh at <path>` shows who claims a directory (`--fresh`: liveness re-read plus the disk probes); `sessions.sh claimants <branch>` lists every session claiming a branch by name or by its worktree (`--fresh` is the land gate's read), and `sessions.sh owner <branch>` prints the one that wins; `sessions.sh state <id>...` re-reads liveness, the archive flag (`1`/`0`/`?`) and an archived session's last transcript cwd straight off disk, which is what `fleet prune` reads before it classifies; `sessions.sh where <id>...` names the Desktop instance (store) holding each session, since the `ccd_session_mgmt` tools reach only their own instance's sessions. Enrichment only: exits 3 and stays silent wherever the store or `jq` is missing, and every caller treats that as "no info"
