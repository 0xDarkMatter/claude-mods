#!/usr/bin/env bash
# Stand-in for the boat CLI, used by tests/run.sh to drive confirm-gone.sh offline.
# It answers only the read verbs confirm-gone.sh may call and logs every call, so the
# suite can prove the script never deletes. Shapes copy what fleetflow's boat driver
# parses: `info --json` -> {"code":"not_found"} once a box is gone (exit 1, as an error),
# `list --all --json` -> {"sandboxes":[{"id":...}]}.
#
# Env:  FAKE_LOG        file each call is appended to
#       FAKE_GONE       space-separated ids whose info answers not_found
#       FAKE_LISTED     space-separated ids that list --all still shows
#       FAKE_INFO_FAIL  1 = info prints nothing and exits 1 (API unreachable)
#       FAKE_LIST_FAIL  1 = list prints nothing and exits 1
set -u
[ -n "${FAKE_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_LOG"
args=()
for a in "$@"; do
  case "$a" in --no-update|--json) ;; *) args+=("$a") ;; esac
done
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
case "${args[0]:-}" in
  info)
    [ "${FAKE_INFO_FAIL:-0}" = 1 ] && exit 1
    id="${args[1]:-}"
    if in_list "$id" "${FAKE_GONE:-}"; then
      printf '{"code":"not_found","message":"Sandbox not found"}\n'; exit 1
    fi
    printf '{"sandbox":{"id":"%s","state":"running"}}\n' "$id" ;;
  list)
    [ "${FAKE_LIST_FAIL:-0}" = 1 ] && exit 1
    rows=""
    for id in ${FAKE_LISTED:-}; do rows="${rows:+$rows,}{\"id\":\"$id\",\"state\":\"running\"}"; done
    printf '{"sandboxes":[%s]}\n' "$rows" ;;
  *) echo "fake-boat: unsupported: $*" >&2; exit 3 ;;
esac
