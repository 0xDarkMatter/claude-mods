#!/usr/bin/env bash
# Starter scaffold for an agent-facing skill script. <one-line, ends with a period.>
#
# Usage:   script-template.sh [OPTIONS] <input>...
# Input:   one or more inputs as positionals; flags select behaviour
# Output:  stdout = data product only (TSV, or JSON under --json)
# Stderr:  headers, progress, warnings, errors
# Exit:    0 ok, 2 usage, 3 not-found, 4 validation, 5 missing-dep,
#          7 unavailable, 10 <domain signal — document it here>
#
# Examples:
#   script-template.sh input.txt
#   script-template.sh --json a.txt b.txt | jq '.data[]'
#   script-template.sh --out result.tsv --quiet input.txt
#
# Requires: bash 4+ (uses mapfile-style idioms); shellcheck-clean.

set -Eeuo pipefail
IFS=$'\n\t'

# --- semantic exit codes (SKILL-RESOURCE-PROTOCOL §5) ---
readonly EXIT_OK=0 EXIT_USAGE=2 EXIT_NOTFOUND=3 EXIT_VALIDATION=4
readonly EXIT_MISSING_DEP=5 EXIT_UNAVAILABLE=7 EXIT_FINDING=10

readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# --- help (stdout, exit 0, EXAMPLES mandatory) ---
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <input>...

Options:
  --json            emit a JSON envelope to stdout (needs jq)
  --out FILE        write output to FILE atomically (default: stdout)
  -q, --quiet       suppress progress framing on stderr
  -h, --help        show this help and exit

EXAMPLES:
  ${SCRIPT_NAME} input.txt
  ${SCRIPT_NAME} --json a.txt b.txt | jq '.data[]'
  ${SCRIPT_NAME} --out result.tsv -q input.txt
EOF
}

# --- framing helpers: human text ALWAYS to stderr, never stdout ---
log()  { [[ "$QUIET" -eq 1 ]] && return 0; printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# --- cleanup trap + atomic write scaffolding ---
TMPFILE=""
cleanup() {
  local rc=$?
  [[ -n "$TMPFILE" && -e "$TMPFILE" ]] && rm -f -- "$TMPFILE"
  exit "$rc"
}
trap cleanup EXIT
trap 'die "interrupted" 130' INT TERM

# --- argument parsing: case loop, long flags, hard usage errors ---
JSON=0; QUIET=0; OUT=""; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)      JSON=1 ;;
    -q|--quiet)  QUIET=1 ;;
    --out)       OUT="${2:?--out needs a value}"; shift ;;
    --out=*)     OUT="${1#*=}" ;;
    -h|--help)   usage; exit "$EXIT_OK" ;;
    --)          shift; ARGS+=("$@"); break ;;
    -*)          die "unknown flag: $1 (try --help)" "$EXIT_USAGE" ;;
    *)           ARGS+=("$1") ;;
  esac
  shift
done

# --- validation (per §5/§6) ---
[[ ${#ARGS[@]} -ge 1 ]] || die "need at least one input (try --help)" "$EXIT_USAGE"
if [[ "$JSON" -eq 1 ]]; then
  command -v jq >/dev/null 2>&1 || die "jq required for --json" "$EXIT_MISSING_DEP"
fi
for in_f in "${ARGS[@]}"; do
  [[ -e "$in_f" ]] || die "input not found: $in_f" "$EXIT_NOTFOUND"
done

# --- work: write the DATA PRODUCT to a buffer, framing to stderr ---
log "=== ${SCRIPT_NAME}: processing ${#ARGS[@]} input(s) ==="

emit_records() {
  # Replace this with real logic. Data → stdout, one TSV record per line.
  local f
  for f in "${ARGS[@]}"; do
    local lines
    lines=$(wc -l < "$f" 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$f" "$lines"   # DATA → stdout
    log "  [ok] ${f} (${lines} lines)"  # framing → stderr
  done
}

if [[ "$JSON" -eq 1 ]]; then
  # Build the §4 success envelope. Booleans true/false, empty lists [], ISO-8601 Z.
  records="$(emit_records | jq -R -s -c 'split("\n")
    | map(select(length>0) | split("\t") | {file: .[0], lines: (.[1]|tonumber)})')"
  payload="$(jq -cn --argjson d "$records" \
    '{data: $d, meta: {count: ($d|length), schema: "claude-mods.bash-ops.script-template/v1"}}')"
else
  payload="$(emit_records)"
fi

# --- output: atomic write when --out, else stdout ---
if [[ -n "$OUT" ]]; then
  TMPFILE="$(mktemp -- "${OUT}.XXXXXX")" || die "mktemp failed" "$EXIT_UNAVAILABLE"
  printf '%s\n' "$payload" > "$TMPFILE"
  mv -- "$TMPFILE" "$OUT"     # atomic rename — reader never sees a partial file
  TMPFILE=""                  # disarm cleanup; the file is now $OUT
  log "wrote ${OUT}"
else
  printf '%s\n' "$payload"    # DATA → stdout
fi

exit "$EXIT_OK"
