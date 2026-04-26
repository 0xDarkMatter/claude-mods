#!/usr/bin/env python3
"""Dump Chromium Local Storage.

Usage:
  python dump_localstorage.py <leveldb-dir> [--origin <url>] [--key <pattern>]

The leveldb-dir is a copy of the app's `Local Storage/leveldb/` dir. Copy first,
remove the LOCK file, then point this at the copy.
"""
import argparse
import pathlib
import sys

from ccl_chromium_reader import ccl_chromium_localstorage


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=pathlib.Path, help="Path to leveldb dir")
    ap.add_argument("--origin", help="Filter by origin (substring match)")
    ap.add_argument("--key", help="Filter by script_key (substring match)")
    ap.add_argument("--max-bytes", type=int, default=300, help="Truncate values longer than this")
    args = ap.parse_args()

    if not args.path.exists():
        print(f"error: {args.path} does not exist", file=sys.stderr)
        return 1

    ls = ccl_chromium_localstorage.LocalStoreDb(args.path)
    origins = sorted(set(ls.iter_storage_keys()))

    for origin in origins:
        if args.origin and args.origin not in origin:
            continue
        # latest-wins: leveldb is append-only
        latest: dict = {}
        for rec in ls.iter_records_for_storage_key(origin):
            latest[rec.script_key] = rec.value

        keys = sorted(latest.keys())
        if args.key:
            keys = [k for k in keys if args.key in k]
        if not keys:
            continue

        print(f"\n=== {origin} ({len(keys)} keys) ===")
        for k in keys:
            v = latest[k]
            if isinstance(v, str) and len(v) > args.max_bytes:
                v = v[: args.max_bytes] + f"...[+{len(latest[k]) - args.max_bytes}b]"
            print(f"  {k!r}")
            print(f"    => {v!r}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
