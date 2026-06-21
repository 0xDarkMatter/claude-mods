#!/usr/bin/env bash
# fleet-collect.sh - gate one fleet-worker JSON result; print its text, set exit code.
#
# Reads a `claude -p --output-format json` result object (file arg or stdin),
# prints the worker's final assistant text to stdout, and exits 0 only when the
# worker truly succeeded. Encodes the spec footgun: the `subtype` field reads
# "success" even on an API error - the real gate is is_error==false (corroborated
# by the process exit code and api_error_status). Use this to decide which fanned-
# out worker branches are worth landing.
#
# Usage:   fleet-collect.sh [--quiet] [RESULT_JSON]
#          fleet-worker --output-format json "task" | fleet-collect.sh
# Input:   result JSON as a file arg, or on stdin
# Output:  stdout = the worker's final text (.result), only on success
# Stderr:  one human status line (OK / FAILED + api_error_status)
# Exit:    0 success; 10 worker failed (is_error / api_error); 3 file not found;
#          4 malformed / not a result object; 2 usage; 5 missing jq
#
# Examples:
#   fleet-collect.sh task-a.result.json && echo "branch fleet/task-a is landable"
#   fleet-worker --output-format json "fix the failing test" | fleet-collect.sh -q
set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_NOT_FOUND=3; EXIT_VALIDATION=4; EXIT_MISSING_DEP=5; EXIT_FAIL=10

QUIET=0; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit "$EXIT_OK" ;;
    -q|--quiet) QUIET=1 ;;
    -*)         echo "fleet-collect.sh: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)          if [ -z "$SRC" ]; then SRC="$1"; else echo "fleet-collect.sh: too many arguments" >&2; exit "$EXIT_USAGE"; fi ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fleet-collect.sh: jq is required" >&2; exit "$EXIT_MISSING_DEP"; }
emit() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1" >&2; }

if [ -n "$SRC" ]; then
  [ -f "$SRC" ] || { echo "fleet-collect.sh: file not found: $SRC" >&2; exit "$EXIT_NOT_FOUND"; }
  DATA="$(cat "$SRC")"
else
  DATA="$(cat)"
fi

printf '%s' "$DATA" | jq -e . >/dev/null 2>&1 || {
  echo "fleet-collect.sh: input is not valid JSON" >&2; exit "$EXIT_VALIDATION"; }

# Note: `.is_error // empty` is WRONG - jq's `//` treats boolean false like null,
# so a genuine is_error:false would read as empty. Gate on has()/tostring instead.
is_error="$(printf '%s' "$DATA"  | jq -r 'if has("is_error") then (.is_error|tostring) else "" end')"
api_status="$(printf '%s' "$DATA" | jq -r '.api_error_status // empty')"
result="$(printf '%s' "$DATA"    | jq -r '.result // ""')"

if [ -z "$is_error" ]; then
  echo "fleet-collect.sh: not a result object (no .is_error field)" >&2
  exit "$EXIT_VALIDATION"
fi

if [ "$is_error" = "false" ]; then
  printf '%s\n' "$result"
  emit "OK"
  exit "$EXIT_OK"
fi

emit "FAILED (is_error=$is_error api_error_status=${api_status:-none})"
exit "$EXIT_FAIL"
