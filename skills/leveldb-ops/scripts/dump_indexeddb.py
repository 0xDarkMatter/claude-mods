#!/usr/bin/env python3
"""Dump Chromium IndexedDB.

Usage:
  python dump_indexeddb.py <leveldb-dir> [--store <name>] [--max <n>]

The leveldb-dir is a copy of `IndexedDB/https_<host>_0.indexeddb.leveldb/`.
Remove the LOCK file from the copy first.
"""
import argparse
import pathlib
import sys

from ccl_chromium_reader import ccl_chromium_indexeddb


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=pathlib.Path)
    ap.add_argument("--store", help="Filter by object store name")
    ap.add_argument("--max", type=int, default=10, help="Max records per store to print")
    ap.add_argument("--max-bytes", type=int, default=300, help="Truncate value repr")
    args = ap.parse_args()

    if not args.path.exists():
        print(f"error: {args.path} does not exist", file=sys.stderr)
        return 1

    db = ccl_chromium_indexeddb.WrappedIndexDB(args.path)
    db_ids = list(db.database_ids)
    if not db_ids:
        print("no databases found")
        return 0

    for db_id in db_ids:
        wdb = db[db_id.dbid_no]
        print(f"\n=== DB: {wdb.name} (id={db_id.dbid_no}) ===")
        for store_name in wdb.object_store_names:
            if args.store and args.store not in store_name:
                continue
            store = wdb[store_name]
            recs = list(store.iterate_records())
            print(f"  STORE: {store_name} ({len(recs)} records)")
            for i, rec in enumerate(recs[: args.max]):
                v = repr(rec.value)
                if len(v) > args.max_bytes:
                    v = v[: args.max_bytes] + f"...[+{len(repr(rec.value)) - args.max_bytes}c]"
                print(f"    [{i}] key={rec.key!r}")
                print(f"         val={v}")
            if len(recs) > args.max:
                print(f"    ... +{len(recs) - args.max} more")

    return 0


if __name__ == "__main__":
    sys.exit(main())
