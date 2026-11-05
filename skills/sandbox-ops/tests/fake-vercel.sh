#!/usr/bin/env bash
# Stand-in for the vercel CLI, used by tests/run.sh to drive confirm-gone.sh --provider vercel
# offline. It answers only the one list command confirm-gone.sh may run (list -a)
# and exits 3 on anything else, so a wrong command or a state-changing verb fails loudly.
# The output copies the documented command's shape, not a recorded run.
#
# Env:  FAKE_LOG        file each call is appended to
#       FAKE_LISTED     space-separated ids the list still shows
#       FAKE_LIST_FAIL  1 = the list prints nothing and exits 1 (API unreachable)
set -u
[ -n "${FAKE_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_LOG"
[ "$*" = "list -a" ] || { echo "fake-vercel: unsupported: $*" >&2; exit 3; }
[ "${FAKE_LIST_FAIL:-0}" = 1 ] && exit 1
printf "ID                        STATUS    CREATED\n"
for id in ${FAKE_LISTED:-}; do printf "%-25s stopped   1h ago\n" "$id"; done
