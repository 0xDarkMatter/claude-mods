#!/usr/bin/env bash
# Offline contract tests. The shipped readers intentionally have no profile
# copy helper: callers must copy and remove LOCK before invoking them, so no
# production lock-safety path exists to exercise without fabricating coverage.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -n "$PYTHON" ]] || { echo "python is required" >&2; exit 1; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# Minimal import surface: --help exits during argparse before reader use.
mkdir -p "$SB/stub/ccl_chromium_reader"
printf '' > "$SB/stub/ccl_chromium_reader/__init__.py"
printf '' > "$SB/stub/ccl_chromium_reader/ccl_chromium_indexeddb.py"
printf '' > "$SB/stub/ccl_chromium_reader/ccl_chromium_localstorage.py"

echo "=== leveldb-ops contract self-test ==="
for script in dump_indexeddb.py dump_localstorage.py extract_keys.py; do
  PYTHONPYCACHEPREFIX="$SB/pycache" "$PYTHON" -m py_compile "$SCRIPTS/$script" \
    && ok "py_compile $script" || no "py_compile $script"

  # Imports are stubbed so argparse help remains offline and does not require
  # the optional forensic reader package.
  out="$(PYTHONPATH="$SB/stub" "$PYTHON" "$SCRIPTS/$script" --help 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 && "$out" == *"usage:"* ]]; then
    ok "--help usage contract $script"
  else
    no "--help usage contract $script"
  fi
done

echo ""
echo "NOTE: lock safety is contract-only; scripts accept pre-copied stores and expose no copy helper."
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
