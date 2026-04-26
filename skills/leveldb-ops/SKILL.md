---
name: leveldb-ops
description: "Read and inspect LevelDB stores - especially Chromium/Electron app state (Local Storage, IndexedDB, Session Storage). Triggers on: leveldb, .ldb files, IndexedDB, Local Storage, Chromium storage, Electron app state, claude.ai cache, browser forensics, decode app state, claude desktop state."
license: MIT
compatibility: "Pure Python via ccl_chromium_reader. Works on Windows/macOS/Linux. No native compilation."
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
---

# LevelDB Operations

Read and decode LevelDB stores — primarily the Chromium/Electron storage layers (Local Storage, IndexedDB, Session Storage) used by every Electron app on disk: Claude Desktop, VS Code, Discord, Slack, Obsidian.

## What is LevelDB

Embedded key-value store by Google. Sorted KV map, no SQL, no server. Format: a folder of `.ldb` (sorted runs), `.log` (write-ahead), `MANIFEST-*`, `CURRENT`, `LOCK`. Both keys and values are arbitrary bytes.

Chromium layers richer formats on top:
- **Local Storage** — flat key→string map, scoped per origin. Easiest to read.
- **Session Storage** — same shape, per-tab.
- **IndexedDB** — per-origin databases with object stores, indexes, versioned schemas. Encoded with v8 serialization. Needs a real reader.

## When This Skill Triggers

- "What's in the Local Storage of <Electron app>"
- "Decode IndexedDB" / "read .ldb files"
- "Why does the sidebar show X" / "where does the desktop app cache Y"
- "Reset / mutate Electron app state"
- Forensic-style probes of Chrome/Edge/Brave/Electron state

## Critical Safety Protocol

**LevelDB uses an exclusive `LOCK` file.** A running app holds it. Trying to open a live store fails OR silently returns stale snapshots.

**Always copy before reading:**

```bash
# Copy the entire leveldb dir to a temp location
cp -r "$APPDATA/Claude/Local Storage/leveldb" /tmp/probe/local-storage-db
cp -r "$APPDATA/Claude/IndexedDB/https_claude.ai_0.indexeddb.leveldb" /tmp/probe/indexeddb

# Remove the copied LOCK file so the reader can open it
rm -f /tmp/probe/local-storage-db/LOCK /tmp/probe/indexeddb/LOCK
```

The `cp -r` will warn `Device or resource busy` for the `LOCK` file itself — that's fine, the data files copy successfully.

**Never write to the live store while the app is running.** It will corrupt the LSM and crash the app. Quit the app first if you need to mutate.

## Setup

`plyvel` and similar require native compilation and lack Windows wheels. Use **`ccl_chromium_reader`** — pure Python, written for browser forensics.

```bash
uv venv .venv --python 3.13
source .venv/Scripts/activate          # or .venv/bin/activate on Unix
uv pip install "git+https://github.com/cclgroupltd/ccl_chrome_indexeddb.git"
```

Not on PyPI — install direct from GitHub. Pulls in `ccl-simplesnappy` and `brotli` as transitive deps.

## Reading Local Storage

Storage keys are origin URLs (`https://claude.ai`). Records are append-only — duplicate `script_key` entries mean older versions; the **last record wins**.

```python
import pathlib
from ccl_chromium_reader import ccl_chromium_localstorage

ls = ccl_chromium_localstorage.LocalStoreDb(pathlib.Path("./local-storage-db"))

# List all origins
for origin in sorted(set(ls.iter_storage_keys())):
    print(origin)

# Dump one origin, latest-value-wins
latest = {}
for rec in ls.iter_records_for_storage_key("https://claude.ai"):
    latest[rec.script_key] = rec.value
for k, v in latest.items():
    print(f"{k}: {repr(v)[:200]}")
```

See [scripts/dump_localstorage.py](scripts/dump_localstorage.py) for the full reusable script.

## Reading IndexedDB

IndexedDB is more complex — wrapped object stores with v8-serialized values. `ccl_chromium_reader` parses it cleanly:

```python
from ccl_chromium_reader import ccl_chromium_indexeddb

db = ccl_chromium_indexeddb.WrappedIndexDB(pathlib.Path("./indexeddb"))
for db_id in db.database_ids:
    wdb = db[db_id.dbid_no]
    print(f"DB: {wdb.name}")
    for store_name in wdb.object_store_names:
        store = wdb[store_name]
        for rec in store.iterate_records():
            print(f"  {rec.key!r} -> {repr(rec.value)[:200]}")
```

See [scripts/dump_indexeddb.py](scripts/dump_indexeddb.py).

## Common Chromium Storage Locations

| OS | Path |
|----|------|
| Windows | `%APPDATA%\<App>\Local Storage\leveldb\` |
| Windows | `%APPDATA%\<App>\IndexedDB\https_<host>_0.indexeddb.leveldb\` |
| macOS | `~/Library/Application Support/<App>/Local Storage/leveldb/` |
| Linux | `~/.config/<App>/Local Storage/leveldb/` |

For raw browsers, `<App>` is `Google/Chrome/User Data/Default`, `BraveSoftware/Brave-Browser/User Data/Default`, etc.

## Mutation (Advanced)

Writing requires either:
1. **Quitting the app** and using a leveldb writer (Node `level` package, or rebuild the dir manually) — or
2. **Patching via the app itself** — many Electron apps expose DevTools. Open with the `--remote-debugging-port=<n>` flag, attach, and call `localStorage.setItem(key, value)`. Survives the app's normal write path so it doesn't corrupt the LSM.

For Claude Desktop specifically, see [references/claude-desktop-state.md](references/claude-desktop-state.md) for the discovered key map.

## Decision Framework

| You want to | Do |
|-------------|-----|
| Just see what's there | Copy + ccl_chromium_reader |
| Find a specific value | `strings` + grep first; reader if structure matters |
| Mutate while app runs | Don't. Use DevTools remote debugging. |
| Mutate while app is closed | Quit, then Node `level` package or write back via re-opened leveldb |
| Cross-account recovery | Read-only forensics; can't impersonate server-bound entries |

## Anti-patterns

- **Opening the live store directly** → silently stale or open errors
- **Forgetting to remove LOCK from copy** → reader fails
- **Trusting first hit on a key** → leveldb is append-only; iterate all and keep the last
- **Using `strings` for structured analysis** → misses keys, conflates duplicates, can't distinguish origins
- **Writing while app runs** → LSM corruption, app crash, possible data loss

## Reference

- [scripts/dump_localstorage.py](scripts/dump_localstorage.py) — full Local Storage dump
- [scripts/dump_indexeddb.py](scripts/dump_indexeddb.py) — full IndexedDB dump
- [scripts/extract_keys.py](scripts/extract_keys.py) — targeted key extraction with latest-wins
- [references/claude-desktop-state.md](references/claude-desktop-state.md) — Claude Desktop state map (storage keys, sidebar, sessions, account binding)
- [references/chromium-format.md](references/chromium-format.md) — leveldb on-disk format, locking, append semantics
- ccl_chromium_reader: https://github.com/cclgroupltd/ccl_chrome_indexeddb
- LevelDB spec: https://github.com/google/leveldb/blob/main/doc/impl.md
