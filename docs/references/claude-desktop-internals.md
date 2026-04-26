# Claude Desktop Internals — File System, Storage, and Session Architecture

> Probed 2026-04-26 against Claude Desktop v1.3109.0 (Electron 41.2.0) on Windows 11.
> Discovery method: live file system exploration + ccl_chromium_reader leveldb reads.
> See `skills/leveldb-ops/` for reusable probe scripts.

---

## Overview

Claude Desktop is an Electron app that embeds `https://claude.ai` as its frontend. It has three tabs — Chat, Cowork, and Code. This document focuses entirely on the **Code tab**, which runs Claude Code sessions.

The app maintains **two parallel storage systems**: a Chromium-backed browser storage (leveldb for Local Storage and IndexedDB), and a structured file hierarchy in `%APPDATA%\Claude\`. The browser storage caches server-fetched data. The file hierarchy stores the durable local state — session metadata, transcripts, worktrees, extensions.

---

## 1. File System Layout

All app data lives under `%APPDATA%\Claude\` on Windows:

```
%APPDATA%\Claude\
  Local Storage/leveldb/          ← Chromium Local Storage (browser-side, leveldb)
  IndexedDB/                      ← Chromium IndexedDB (browser-side, leveldb)
  Session Storage/                ← Chromium Session Storage (per-tab, ephemeral)
  Partitions/                     ← Per-origin sandboxed storage for MCP iframes

  claude-code-sessions/           ← Session metadata registry (one JSON per session)
    <account-uuid>/
      <workspace-uuid>/
        local_<session-uuid>.json

  local-agent-mode-sessions/      ← Session transcripts (JSONL conversation logs)
    <account-uuid>/
      <workspace-uuid>/
        local_<session-uuid>/
          audit.jsonl
          .claude/projects/
            -sessions-<human-name>/
              <cli-session-uuid>.jsonl
              subagents/
                agent-<id>.jsonl
                agent-acompact-<id>.jsonl

  claude-code-vm/                 ← VM/sandbox state for remote sessions
  agents/                         ← Installed agent extensions
  Claude Extensions/              ← Installed connector extensions (MCP wrappers)
  Claude Extensions Settings/     ← Per-extension config
  git-worktrees.json              ← Registry of active git worktrees (all accounts)
  config.json                     ← UI preferences (theme, scale, locale, allowlists)
  buddy-tokens.json               ← Daily token usage counter
  claude_desktop_config.json      ← MCP server declarations
  window-state.json               ← Last window position/size
  Local State                     ← Chromium DPAPI key store (for cookie encryption)
  logs/                           ← Diagnostic logs
  Crashpad/                       ← Crash reports
```

**Example account UUIDs:**

| UUID prefix | Account | Email | Session type | Sessions |
|-------------|---------|-------|--------------|----------|
| `aabbccdd` | account-a | user@example.com | Local | 10 |
| `11223344` | account-b | user@company.com | Local | 22 |
| `55667788` | account-c | user@gmail.com | **Remote (cloud VM)** | 40 |

Account emails are stored in `local-agent-mode-sessions/<account-uuid>/<workspace-uuid>/local_<session-uuid>.json` → `emailAddress` field.

Account UUIDs are assigned by Anthropic's server. To identify them: read `~/.claude/.claude.json` → `oauthAccount.accountUuid` for the currently logged-in CLI account.

---

## 2. Session ID Schemes — Two Separate Namespaces

Claude Code has **two distinct session systems** that share the brand name but are architecturally different.

| Property | Desktop Code-tab sessions | CLI terminal sessions |
|----------|--------------------------|----------------------|
| ID format | `local_<uuid>` | `<uuid>` (no prefix) |
| Where shown | Desktop sidebar | `claude --resume` picker |
| Storage | `%APPDATA%\Claude\claude-code-sessions\` + server cache | `~/.claude/projects/<encoded-cwd>/*.jsonl` |
| Account-bound? | Metadata is account-scoped (stored in account subfolder) | No — pure local files |
| Server-dependent? | Sidebar list fetched from server; transcript stored locally | Fully local |
| Resume flag | No native CLI flag | `claude --resume <uuid>` |

**Critical:** these IDs don't overlap. A `local_<uuid>` session never appears in the CLI picker and vice versa.

---

## 3. `claude-code-sessions/` — Session Metadata Registry

Each Desktop session has one JSON file at:

```
%APPDATA%\Claude\claude-code-sessions\<account-uuid>\<workspace-uuid>\local_<session-uuid>.json
```

### Full Schema

```json
{
  "sessionId":        "local_<session-uuid>",
  "cliSessionId":     "<cli-session-uuid>",
  "cwd":              "C:\\Projects\\my-project",
  "originCwd":        "C:\\Projects\\my-project",
  "createdAt":        1777168830743,
  "lastActivityAt":   1777171587818,
  "model":            "claude-opus-4-7[1m]",
  "effort":           "medium",
  "isArchived":       false,
  "title":            "dev",
  "titleSource":      "user",
  "permissionMode":   "acceptEdits",
  "completedTurns":   5,
  "enabledMcpTools":  { "<tool-hash>": true, ... },
  "remoteMcpServersConfig": [...],
  "alwaysAllowedReasons": [...]
}
```

### Key Fields

| Field | Purpose |
|-------|---------|
| `sessionId` | Desktop session ID — matches sidebar, worktree registry, leveldb references |
| `cliSessionId` | UUID pointing to the JSONL transcript in `local-agent-mode-sessions/`. This is a plain UUID (no `local_` prefix) — same format as CLI session IDs |
| `cwd` | Working directory when session was created |
| `titleSource` | `"user"` (manually renamed) or `"auto"` (generated) |
| `permissionMode` | `"default"`, `"acceptEdits"`, `"plan"`, `"auto"`, `"bypassPermissions"` |
| `isArchived` | Set to `true` when session is archived (hidden from sidebar by default) |
| `completedTurns` | Number of user→assistant exchange pairs |
| `enabledMcpTools` | Map of `<tool-hash>: true` for each enabled MCP tool this session |

The `workspace-uuid` in the path is a Desktop-internal grouping UUID — not user-visible, not the session ID.

---

## 4. `local-agent-mode-sessions/` — Session Transcripts

The full conversation transcript for each Desktop session lives at:

```
%APPDATA%\Claude\local-agent-mode-sessions\
  <account-uuid>\<workspace-uuid>\local_<session-uuid>\
    audit.jsonl
    .claude\projects\-sessions-<human-name>\
      <cliSessionId>.jsonl          ← main transcript
      subagents\
        agent-<id>.jsonl            ← subagent transcripts
        agent-acompact-<id>.jsonl   ← compacted subagent transcripts
```

**The `<cliSessionId>` in the filename matches `cliSessionId` in the metadata JSON.** This is the bridge between the two storage locations.

### JSONL Record Types

The transcript JSONL contains multiple record types, identical in shape to CLI session JSONL files:

```
type="queue-operation"   keys: type, operation, timestamp, sessionId, content
type="user"              keys: parentUuid, isSidechain, userType, cwd, sessionId,
                               version, gitBranch, type, message, uuid, timestamp,
                               permissionMode
type="assistant"         keys: parentUuid, isSidechain, userType, cwd, sessionId,
                               version, gitBranch, message, requestId, type, uuid,
                               timestamp
```

The `user` and `assistant` records are structurally identical to CLI JSONL records — the transcript format is shared.

### `audit.jsonl`

Separate from the main transcript. Records operational events (session start, tool calls, errors) at a lower level. Not needed for conversation resume.

---

## 5. `git-worktrees.json` — Global Worktree Registry

Single file at `%APPDATA%\Claude\git-worktrees.json`. Tracks all active worktrees across all sessions and accounts.

```json
{
  "worktrees": {
    "<worktree-name>": {
      "name":         "<worktree-name>",
      "path":         "C:\\Projects\\my-project\\.claude\\worktrees\\<worktree-name>",
      "leasedBy":     "local_<session-uuid>",
      "baseRepo":     "C:\\Projects\\my-project",
      "branch":       "claude/<worktree-name>",
      "sourceBranch": "main",
      "createdAt":    1777163079076
    }
  }
}
```

`leasedBy` contains the Desktop `local_<uuid>` session ID that owns the worktree.

---

## 6. Chromium Local Storage — LevelDB Schema

Location: `%APPDATA%\Claude\Local Storage\leveldb\`  
Origin: `https://claude.ai`  
Format: Chromium-encoded LevelDB. Requires `ccl_chromium_reader` to read (not `plyvel` — no Windows wheels).

**Safety rule:** Always copy the dir and delete the `LOCK` file before reading. Never open the live store.

### Key Entries (origin: `https://claude.ai`)

| Key | Survives logout? | Shape | Purpose |
|-----|-----------------|-------|---------|
| `react-query-cache-ls` | No — cleared on logout | JSON, 10–20MB | Server query cache: conversation list, account info, model availability |
| `react-query-cache` (IndexedDB mirror) | No | Same content | Duplicate of above in IndexedDB `keyval-store` |
| `dframe-store` | Yes | `{state: {pinnedOrder, sidebarWidth, lastKnownMode, groupByByMode}}` | Sidebar layout — pin order, width, grouping mode |
| `ccd-session-store` | Yes | `{state: {selectedFolder}}` | Active project folder |
| `epitaxy.sidePaneStore.v1` | Yes | `{state: {tileLayoutBySession: {local_<uuid>: layout}}}` | Per-session pane layouts (keyed by session ID) |
| `epitaxy-unread-v1` | Yes | `{state: {unreadIds: []}}` | Unread session markers |
| `__qk_hint_account_uuid` | Yes (multi-account) | string | Last-active account UUID — multiple records may exist across accounts |
| `lastLoginMethod` | Yes | string | e.g. `"google"` |
| `default-model` | Yes | string | e.g. `"claude-opus-4-7"` |
| `branch-status-cache` | Yes | JSON | Cached git branch status per repo |

**Append-only gotcha:** LevelDB appends new writes; old values persist until compaction. Always iterate all records and keep the last value per key — never trust the first hit.

**Mutation:** Quit Claude Desktop → edit via Node `level` package or direct leveldb write → restart. Or use `--remote-debugging-port=<n>` for live DevTools access.

---

## 7. MCP Iframe Partitioning

MCP tool widgets run in iframes scoped to per-session origins:

```
https://<hash>.claudemcpcontent.com/^0https://claude.ai
```

Each MCP iframe has its own isolated Local Storage (Chromium's `^0` storage partition suffix). State persists across sessions for that widget — e.g. Asana task drafts cache per-widget. These are stored in `%APPDATA%\Claude\Partitions\`.

---

## 8. Local vs Remote Session Execution

Desktop sessions run in one of three environments (set at session creation):

| Environment | `cwd` pattern | Transcript stored locally? |
|-------------|--------------|---------------------------|
| **Local** | `C:\...` / `X:\...` (Windows path) | Yes — JSONL in `local-agent-mode-sessions/<account>/<ws>/local_<id>/.claude/projects/` |
| **Remote** (Anthropic cloud VM) | `/sessions/<name>/mnt` | No — server-side only |
| **SSH** | `/<remote-path>` | No — server-side only |

**Local sessions** write a full JSONL transcript to disk as the session runs. These transcripts are account-agnostic bytes — any account can read and replay them.

**Remote sessions** (Anthropic-hosted, selected via the "Remote" environment option) run in an ephemeral cloud VM. The conversation transcript is stored server-side under the creating account. The local `local-agent-mode-sessions` directory for remote sessions contains only workspace environment files (`.claude/.claude.json`, debug logs) — no conversation JSONL.

This distinction determines what cross-account session transfer is possible:
- Local → any account: transcript file copy + leveldb pin is feasible
- Remote → different account: server-gated, no local transcript to copy

**Observed pattern:**
- Accounts running **local** sessions have cwd like `C:\Projects\...` (a Windows path)
- Accounts running **remote** sessions have cwd like `/sessions/<vm-name>/mnt`

## 8b. Account Binding — What Survives Account Switching

| Storage | Account-scoped? | Survives logout? | Notes |
|---------|----------------|-----------------|-------|
| `~/.claude/projects/*.jsonl` | No | Yes | CLI transcripts — pure local, zero account markers |
| `~/.claude/.claude.json` | Yes | Replaced on login | CLI auth state |
| `claude-code-sessions/<account-uuid>/` | Yes (by path) | Yes | Metadata files remain on disk, accessible by path |
| `local-agent-mode-sessions/<account-uuid>/` | Yes (by path) | Yes | Transcript JSONLs remain on disk |
| `react-query-cache-ls` | Yes | No — cleared | Server-fetched sidebar list |
| `dframe-store.pinnedOrder` | No | Yes | Pin order persists; references server IDs |
| `epitaxy.sidePaneStore.v1` | No | Yes | Tile layouts persist; reference local session IDs |
| `git-worktrees.json` | No | Yes | Worktree registry persists |

**Key insight:** When you switch accounts, the Desktop sidebar repopulates from the new account's server-fetched `react-query-cache-ls`. Prior sessions are not gone — their metadata and transcripts remain on disk under the old account's UUID subdirectory.

---

## 9. Cross-Account Session Continuity (Local Sessions Only)

### What's possible

**CLI resume of a Desktop session (account-agnostic):**

Any Desktop session can be resumed in the CLI terminal from any account, because the transcript JSONL is a local file:

1. Find the session in `claude-code-sessions/<account-uuid>/*/local_<session-uuid>.json`
2. Extract `cliSessionId` from that JSON
3. Find the JSONL at `local-agent-mode-sessions/<account-uuid>/*/local_<session-uuid>/.claude/projects/-sessions-*/< cliSessionId>.jsonl`
4. Copy the JSONL to `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`
5. Run `claude --resume <cliSessionId>` — works regardless of logged-in account

**Desktop-to-Desktop cross-account (VALIDATED — 2026-04-26):**

Confirmed working: copying only the session metadata JSON from account A's `claude-code-sessions/` dir into account B's `claude-code-sessions/` dir is sufficient for the session to appear in account B's sidebar and accept new messages.

**How Desktop resolves the transcript:** Desktop reads `cliSessionId` from the metadata JSON, then loads the transcript from `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl` — which is account-agnostic. It does NOT validate session ownership against the server on click. No server gating observed.

**Minimal procedure (battle-tested):**

```bash
# 1. Find sessions to transfer
A_SESSIONS="$APPDATA/Claude/claude-code-sessions/<A-uuid>/"
B_WORKSPACE="$APPDATA/Claude/claude-code-sessions/<B-uuid>/<any-existing-workspace-uuid>/"

# 2. For each session, verify the JSONL bridge exists
cliSessionId=$(jq -r '.cliSessionId' session.json)
ls ~/.claude/projects/<encoded-cwd>/$cliSessionId.jsonl  # must exist

# 3. Copy just the metadata JSON
cp "$A_SESSIONS/<ws>/local_<uuid>.json" "$B_WORKSPACE/local_<uuid>.json"

# 4. Sessions appear in account B's sidebar immediately (no Desktop restart needed)
#    Desktop scans the filesystem for sessions — does NOT rely on dframe-store.pinnedOrder
```

**What is NOT needed:**
- Copying `local-agent-mode-sessions/` transcript directories
- Modifying `dframe-store.pinnedOrder` in leveldb

**Sidebar refresh behaviour (important):**
- `Ctrl+R` — reloads the renderer from cached state only. Does NOT retrigger filesystem scan. Copied sessions will NOT appear.
- **Logout → Login** — triggers fresh `react-query-cache-ls` server fetch AND full filesystem rescan. Copied sessions WILL appear. This is the required step.
- Live file creation while Desktop is open — fs.watch fires immediately, sessions appear without restart.

**Sidebar discovery — how it actually works (validated via leveldb probe):**

The sidebar is populated from two sources, unioned together:
1. **Server session list** — fetched from Anthropic's server on login, cached in `react-query-cache-ls` (20MB blob). Contains only sessions the server knows about for the current account.
2. **Filesystem scan** — on login, Desktop scans `claude-code-sessions/<current-account-uuid>/` and loads all `local_*.json` files found. These appear in the sidebar regardless of whether the server knows about them.

Transferred sessions (copied from another account's dir) appear via path #2 — the filesystem scan. Confirmed: 7 of 8 transferred sessions were ABSENT from `react-query-cache-ls` but appeared in the sidebar. The 8th appeared in the cache only as a previously-cached transcript (`epitaxy.local.transcript.*` key), not as a session list entry.

`dframe-store.pinnedOrder` only controls pinned-to-top ordering — all other sessions are shown below, sorted by `lastActivityAt`. Confirmed: `pinnedOrder` had 2 entries while 40+ sessions appeared in the sidebar.

**Validated transfers (2026-04-26):**
- account-a → account-b: single session (29 turns, 1.8MB JSONL) — appeared, opened, accepted new messages ✓
- account-a → account-b: 8× sessions from a single repo (0–132 turns) — bulk copied ✓

**Bulk copy script:**

```bash
EVO="$APPDATA/Claude/claude-code-sessions/<A-uuid>"
TARGET="$APPDATA/Claude/claude-code-sessions/<B-uuid>/<workspace-uuid>"
JSONL_DIR="$HOME/.claude/projects/<encoded-cwd>"

for ws in "$EVO"/*/; do
  for f in "$ws"*.json; do
    [ -f "$f" ] || continue
    cwd=$(jq -r '.cwd // ""' "$f")
    [ "$cwd" = "C:\\Projects\\TargetProject" ] || continue
    cli=$(jq -r '.cliSessionId' "$f")
    [ -f "$JSONL_DIR/$cli.jsonl" ] || { echo "SKIP (no JSONL): $f"; continue; }
    cp "$f" "$TARGET/$(basename "$f")"
    echo "OK: $(jq -r '.title' "$f") → $(basename "$f")"
  done
done
```

### What's not possible

- Accessing account A session **content** through the server while logged into account B — server-gated
- Re-registering Desktop sidebar entries server-side from a different account — server-gated
- Resuming a Desktop session via `claude --resume` using the `local_<uuid>` ID — wrong format; CLI only accepts plain UUIDs
- Transferring **remote** sessions (cwd: `/sessions/<vm-name>/mnt`) — no local JSONL exists to bridge

---

## 10. Probe Recipes

### List all Desktop sessions across all accounts

```python
import json, pathlib, sys

base = pathlib.Path(r'C:/Users/<user>/AppData/Roaming/Claude/claude-code-sessions')
sessions = []
for account_dir in sorted(base.iterdir()):
    if not account_dir.is_dir(): continue
    for ws in account_dir.iterdir():
        if not ws.is_dir(): continue
        for f in ws.glob('local_*.json'):
            try:
                d = json.loads(f.read_text(encoding='utf-8'))
                sessions.append({
                    'account': account_dir.name[:8],
                    'sessionId': d['sessionId'],
                    'cliSessionId': d.get('cliSessionId', ''),
                    'title': d.get('title', '?'),
                    'cwd': d.get('cwd', ''),
                    'isArchived': d.get('isArchived', False),
                    'lastActivity': d.get('lastActivityAt', 0),
                    '_path': str(f)
                })
            except: pass

sessions.sort(key=lambda x: x['lastActivity'], reverse=True)
for s in sessions:
    print(f"[{s['account']}] {s['title']!r:<20} cli:{s['cliSessionId'][:8]} {s['cwd'][-40:]}")
```

### Find JSONL for a Desktop session

```python
def find_transcript(appdata, account_uuid, desktop_session_uuid, cli_session_id):
    base = pathlib.Path(appdata) / 'Claude' / 'local-agent-mode-sessions'
    pattern = f'**/local_{desktop_session_uuid}/**/{cli_session_id}.jsonl'
    results = list((base / account_uuid).rglob(f'{cli_session_id}.jsonl'))
    return results[0] if results else None
```

### Read leveldb Local Storage

```bash
# Copy live store (LOCK copy will warn — fine)
cp -r "$APPDATA/Claude/Local Storage/leveldb" /tmp/ls-probe
rm -f /tmp/ls-probe/LOCK

# Install reader (GitHub only, not on PyPI)
uv pip install "git+https://github.com/cclgroupltd/ccl_chrome_indexeddb.git"

# Dump all keys
python skills/leveldb-ops/scripts/dump_localstorage.py /tmp/ls-probe --origin https://claude.ai

# Extract specific keys
python skills/leveldb-ops/scripts/extract_keys.py /tmp/ls-probe dframe-store ccd-session-store
```

---

## 11. Feature Flags (GrowthBook / Tengu Flags)

Stored in `~/.claude/.claude.json` → `cachedGrowthBookFeatures`. The app uses these to gate experimental features. Prefix is `tengu_`. Some notable ones observed:

| Flag | Likely purpose |
|------|---------------|
| `tengu_worktree_mode` | Git worktree session isolation |
| `tengu_ccr_bridge_multi_session` | Multi-session bridge mode |
| `tengu_session_memory` | Session memory features |
| `tengu_auto_mode_config` | Auto permission mode |
| `tengu_kairos_loop_dynamic` | Dynamic loop pacing |
| `tengu_sm_compact` | Smart compaction |
| `tengu_harbor` | Sidebar/session management features |
| `tengu_relay_chain_v1` | Agent relay chaining |
| `tengu_mcp_elicitation` | MCP tool elicitation |

These are read-only observations — modifying them locally has unknown effects.

---

## 12. Related Files

| File | Path | Contents |
|------|------|----------|
| `claude-desktop-state.md` | `skills/leveldb-ops/references/` | Full Local Storage key map for `https://claude.ai` origin |
| `chromium-format.md` | `skills/leveldb-ops/references/` | LevelDB on-disk format, locking, append semantics |
| `dump_localstorage.py` | `skills/leveldb-ops/scripts/` | Full Local Storage dump |
| `extract_keys.py` | `skills/leveldb-ops/scripts/` | Targeted key extraction |
| `dump_indexeddb.py` | `skills/leveldb-ops/scripts/` | IndexedDB dump |
