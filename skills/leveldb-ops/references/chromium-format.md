# Chromium LevelDB Format Notes

Quick reference for the on-disk layout and gotchas when reading Chromium's leveldb stores.

## File Layout

A leveldb directory contains:

| File | Purpose |
|------|---------|
| `*.ldb` | Sorted runs (immutable SST tables). Numbered by sequence. |
| `*.log` | Write-ahead log. Contains recent writes not yet compacted into `.ldb`. |
| `MANIFEST-<n>` | Metadata: which `.ldb` files are live, version edits |
| `CURRENT` | Tiny pointer file naming the active MANIFEST |
| `LOCK` | File lock; held by the running app. **Blocks readers.** |
| `LOG`, `LOG.old` | Diagnostic text logs (human-readable) |

To read while the app runs: copy the dir, delete the LOCK file from your copy, open the copy.

## Append-Only Semantics

LevelDB is **log-structured**. A write to key `foo` doesn't overwrite — it appends a new entry. Compaction eventually drops older versions.

When iterating raw records (as `ccl_chromium_reader` does), you can see multiple entries for the same key. **The last one in iteration order is the current value.**

```python
# Wrong — uses first match
for rec in ls.iter_records_for_storage_key(origin):
    if rec.script_key == "default-model":
        return rec.value  # might be stale

# Right — iterate all, keep last
latest = {}
for rec in ls.iter_records_for_storage_key(origin):
    latest[rec.script_key] = rec.value
return latest["default-model"]
```

## Chromium's Layers on Top

### Local Storage (simple)

Keys in the underlying leveldb look like:

```
META:<origin>\x00\x00\x01<script_key>
```

Values are UTF-8 strings (the actual `localStorage.setItem` payload). `ccl_chromium_localstorage.LocalStoreDb` decodes the META prefix and yields `(origin, script_key, value)` triples.

### Session Storage (per-tab)

Same shape but partitioned per browsing session/tab. Use `ccl_chromium_sessionstorage`.

### IndexedDB (complex)

- Multiple databases per origin
- Each DB has versioned object stores
- Keys are typed (string, number, array, date, binary)
- Values are **v8-serialized** (not JSON) — the same format Chromium's StructuredClone uses
- Indexes maintained as separate keyspaces

`ccl_chromium_indexeddb.WrappedIndexDB` handles all of this. Walk: `db.database_ids` → `db[id]` → `wdb.object_store_names` → `wdb[name].iterate_records()`.

## Locking Specifics

- **Windows**: `LOCK` uses `LockFile` Win32 API. Robust, no stale locks.
- **macOS/Linux**: `flock(2)` advisory lock. Crashed apps may leave stale LOCK files; safe to delete.
- **Reading concurrently**: Strictly speaking, leveldb supports multiple readers if openers use the same lock. In practice, copy-and-read is safest because `ccl_chromium_reader` doesn't take any lock — it just reads the bytes.

## Encryption / DPAPI Note

`Local State` JSON in the same parent dir contains `os_crypt.encrypted_key` — DPAPI-encrypted on Windows, used by Chrome to encrypt cookies and saved passwords. **Local Storage and IndexedDB themselves are NOT encrypted** at rest. They're plain leveldb. Only the cookie store and password store use that key.

## When to Reach for a Different Tool

| Tool | When |
|------|------|
| `strings` + `grep` | Quick grep for known string. No structure needed. |
| `ccl_chromium_reader` | Structured Local Storage / IndexedDB. Default choice. |
| Node `level` package | You need to **write** to leveldb. Better wheels than Python on Windows. |
| Electron remote DevTools | Mutate live state without taking the app down. `--remote-debugging-port=<n>` then DevTools Protocol. |
| `leveldb-cli` (Go) | Raw leveldb, no Chromium decoding. Good for non-Chromium leveldb stores. |

## References

- LevelDB design: https://github.com/google/leveldb/blob/main/doc/impl.md
- Chromium IndexedDB schema: https://chromium.googlesource.com/chromium/src/+/main/content/browser/indexed_db/
- ccl_chromium_reader: https://github.com/cclgroupltd/ccl_chrome_indexeddb
