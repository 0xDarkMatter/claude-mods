#!/usr/bin/env bash
# Self-test for the summon skill (scripts/summon.py).
#
# Offline-deterministic: builds a throwaway Claude Desktop dir tree in a temp
# sandbox (HOME/USERPROFILE/APPDATA redirected), so no real account data is
# read or written. Covers the selection/confirmation flow (--yes, --select,
# piped stdin), the cp1252 UnicodeEncodeError regression, the toolbox modes
# (rebind/recover/pick/doctor, incl. the worktree-repair hint), and the
# distilled-handover flow (extraction skips tool blobs, cache hit/miss on
# mtime, --no-distill, degrade paths via a PATH-shimmed fake `claude` —
# no real LLM call is ever made by this suite).
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pick a python that actually executes — skips the Windows Store python3 stub.
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found — skipping" >&2; exit 0; }

"$PYTHON" "$HERE/test_summon.py"
