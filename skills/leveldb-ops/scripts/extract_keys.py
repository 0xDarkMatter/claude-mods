#!/usr/bin/env python3
"""Extract specific keys from Local Storage with full values and JSON pretty-print.

Usage:
  python extract_keys.py <leveldb-dir> <key1> [key2] [key3] ...

Latest-wins per key. JSON-decodes values when possible.
"""
import argparse
import json
import pathlib
import sys

from ccl_chromium_reader import ccl_chromium_localstorage


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", type=pathlib.Path)
    ap.add_argument("keys", nargs="+", help="script_keys to extract (exact match)")
    ap.add_argument("--origin", default="https://claude.ai", help="Origin to scan")
    args = ap.parse_args()

    ls = ccl_chromium_localstorage.LocalStoreDb(args.path)

    latest: dict = {}
    for rec in ls.iter_records_for_storage_key(args.origin):
        if rec.script_key in args.keys:
            latest[rec.script_key] = rec.value

    for k in args.keys:
        v = latest.get(k)
        print(f"\n=== {k} ===")
        if v is None:
            print("  (not found)")
            continue
        size = len(v) if isinstance(v, str) else 0
        print(f"  size: {size} bytes")
        try:
            parsed = json.loads(v)
            print(json.dumps(parsed, indent=2))
        except (json.JSONDecodeError, TypeError):
            print(repr(v))

    return 0


if __name__ == "__main__":
    sys.exit(main())
