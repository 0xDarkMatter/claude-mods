# Session Awareness: the Live-Owner Gate and Channels

How fleet-ops decides a lane's owner is still writing, what the self-ownership exemption requires, how to override, and which session channels work where.

### The live-owner gate

`fleet land` refuses a lane whose owning session was active within
`session_live_secs` (default 600). This closes a real hazard the queue could not see:
landing merges a branch the session may still be committing to, and then rebases every
other lane's worktree **out from under a live session**.

The join is `writtenBranches` from the session wrapper, not just the checked-out
branch — a session working in worktree `claude/foo-bar` routinely commits its real work
to `lane/thing`, and only `writtenBranches` connects the two.

**It also joins on the directory.** Any session claiming the worktree the lane branch
is checked out in (wrapper `cwd`/`worktreePath`, transcript directory, live `cwd` — the
claims [prune](../SKILL.md#prune--worktree-housekeeping) uses) blocks, whatever branch its wrapper
records: branch drift and `EnterWorktree` both defeat the branch join (2026-09-28). The
read is `sessions.sh at --fresh`. The cached index may nominate claimants but never
decides: each one's liveness is re-read, and transcripts being written in the worktree
are read off disk, so a session that arrived after the index was built still blocks.
Blind spot: a shell that `cd`'d in since the last index, or writes by absolute path.

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

- `scripts/sessions.sh` — branch → owning-session and directory → claiming-session resolver, read off every Desktop instance's session store plus the CLI transcripts on disk (deployed alongside signal.sh so lane sessions can resolve MAIN). `sessions.sh stores` shows what it read; `sessions.sh at <path>` shows who claims a directory (`--fresh`: liveness re-read, the land gate's view); `sessions.sh state <id>...` re-reads liveness, the archive flag (`1`/`0`/`?`) and an archived session's last transcript cwd straight off disk, which is what `fleet prune` reads before it classifies; `sessions.sh where <id>...` names the Desktop instance (store) holding each session, since the `ccd_session_mgmt` tools reach only their own instance's sessions. Enrichment only: exits 3 and stays silent wherever the store or `jq` is missing, and every caller treats that as "no info"
