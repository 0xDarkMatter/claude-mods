# Claude Desktop State Map

Decoded from `%APPDATA%\Claude\Local Storage\leveldb\` and `%APPDATA%\Claude\IndexedDB\` using `ccl_chromium_reader`. Probed 2026-04-26 against Claude Desktop v1.3109.0 (Electron 41.2.0).

## Storage Locations (Windows)

| Component | Path |
|-----------|------|
| Local Storage | `%APPDATA%\Claude\Local Storage\leveldb\` |
| IndexedDB | `%APPDATA%\Claude\IndexedDB\https_claude.ai_0.indexeddb.leveldb\` |
| Session Storage | `%APPDATA%\Claude\Session Storage\` |
| Account/profile JSON | `~\.claude\.claude.json` |
| CLI session transcripts | `~\.claude\projects\<encoded-cwd>\<uuid>.jsonl` |
| Local State (DPAPI keys) | `%APPDATA%\Claude\Local State` |

The Electron app loads `https://claude.ai` as its frontend, so all browser storage is keyed to that origin. MCP content servers also appear under their own `*.claudemcpcontent.com` origins.

## Account Binding — Critical Distinction

| Storage | Account-bound? | Survives logout? |
|---------|---------------|------------------|
| `~\.claude\projects\*.jsonl` (CLI transcripts) | **No** — pure local files, zero account markers | **Yes** |
| `~\.claude\.claude.json` (CLI account state) | Yes — `userID`, `oauthAccount` | Replaced on login |
| Local Storage `react-query-cache-ls` | Server-fetched cache, **per-account** | Cleared on logout |
| IndexedDB `keyval-store` `react-query-cache` | Same — server cache mirror | Cleared on logout |
| Local Storage `dframe-store`, `epitaxy.*` | Local UI state (pin order, layouts) | Yes, but references server IDs |

**Implication:** Desktop "Code" tab sessions (visible in the sidebar) are **server-stored under whichever account created them**. Switching accounts hides them; they cannot be re-registered locally because the new account's server doesn't know about them.

CLI sessions are different — fully local, account-agnostic, resumable via `claude --resume <uuid>`.

## Session ID Schemes (Two Different Things!)

| Surface | ID format | Example | Storage |
|---------|-----------|---------|---------|
| Desktop "Code" sidebar | `local_<uuid>` | `local_00000000-0000-0000-0000-000000000030` | Server + Local Storage references |
| CLI `claude --resume` | `<uuid>` (no prefix) | `04093688-bcd7-423e-9cc6-675beab2805a` | `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` |

These ID spaces do not overlap. The desktop's `local_` sessions are not the same as CLI session JSONL files.

## Key Local Storage Entries (origin: `https://claude.ai`)

### Read-only / observe

| Key | Shape | Purpose |
|-----|-------|---------|
| `react-query-cache-ls` | JSON, often huge (10-20MB) | Cached server queries: conversation list, account info, model availability. Cleared on logout. |
| `__qk_hint_account_uuid` | string | Last-active account UUID (multiple values across accounts) |
| `lastLoginMethod` | string | e.g., `"google"` |
| `default-model` | string | e.g., `"claude-opus-4-7"` |
| `branch-status-cache` | JSON | Cached git branch status per repo |
| `epitaxy.sidePaneStore.v1` | JSON | Tile layouts per `local_<uuid>` session |

### Writable / mutate

| Key | Shape | What you can change |
|-----|-------|----------------------|
| `dframe-store` | `{state: {pinnedOrder, sidebarWidth, lastKnownMode, groupByByMode, ...}}` | Pin/unpin sessions in sidebar (`pinnedOrder: ["code:local_<uuid>"]`), resize, change grouping |
| `ccd-session-store` | `{state: {selectedFolder, ...}}` | Programmatically set the active project folder |
| `epitaxy-unread-v1` | `{state: {unreadIds: []}}` | Mark sessions read/unread |

**To mutate safely:**
1. Quit Claude Desktop (drops the LOCK and stops the app from clobbering your write)
2. Use a leveldb writer (Node `level` package, or `plyvel` on platforms with wheels)
3. Restart the app

OR use Electron remote DevTools (`--remote-debugging-port=<n>`) to call `localStorage.setItem` directly while the app runs.

## IndexedDB Contents

`keyval-store` database, single `keyval` object store:

| Key | Value |
|-----|-------|
| `react-query-cache` | Mirror of the Local Storage `react-query-cache-ls` — same buster/queries |

Empty post-logout, populated post-login. No additional state worth poking.

## MCP Sandboxed Origins

Claude Desktop renders MCP tool widgets in iframes scoped to per-session origins:

```
https://2829b00d401b181891a38dad5b2e3140.claudemcpcontent.com/^0https://claude.ai
https://2ce089db561642ac93752a8a0e5fca3b.claudemcpcontent.com/^0https://claude.ai
https://45dfbdaaa3edb5a1e9641febd6bdaf76.claudemcpcontent.com/^0https://claude.ai
```

The `^0` partition suffix is Chromium's storage partitioning. Each MCP iframe's localStorage is isolated. We observed Asana widget state (task drafts) cached per-widget here — survives across sessions.

## What You Cannot Do

- **Re-register cross-account sessions in the sidebar** — they're server-locked
- **Recover transcripts of desktop "Code" sessions from another account** — never stored locally in full; only metadata cached, and that's cleared on logout
- **Forge sidebar entries** — they'd point at server-side IDs the new account can't open

## What You Can Do

- **Find local CLI sessions** by scanning `~/.claude/projects/<encoded-cwd>/*.jsonl` and resuming via `claude --resume <uuid>`
- **Inspect cached server data** from `react-query-cache-ls` if it hasn't been cleared yet (logout clears it)
- **Mutate UI state** — sidebar pins, project folder, sidebar width — via `dframe-store` and `ccd-session-store`
- **Audit what the app remembers about you** across MCP origins, account history, model preferences

## Probe Recipe

```bash
# 1. Copy stores (warning on LOCK is fine)
cp -r "$APPDATA/Claude/Local Storage/leveldb" /tmp/probe/local-storage-db
cp -r "$APPDATA/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb" /tmp/probe/indexeddb
rm -f /tmp/probe/{local-storage-db,indexeddb}/LOCK

# 2. Reader
uv venv /tmp/probe/.venv --python 3.13
source /tmp/probe/.venv/Scripts/activate
uv pip install "git+https://github.com/cclgroupltd/ccl_chrome_indexeddb.git"

# 3. Dump
python skills/leveldb-ops/scripts/dump_localstorage.py /tmp/probe/local-storage-db --origin https://claude.ai
python skills/leveldb-ops/scripts/dump_indexeddb.py /tmp/probe/indexeddb

# 4. Targeted extract
python skills/leveldb-ops/scripts/extract_keys.py /tmp/probe/local-storage-db dframe-store ccd-session-store
```
