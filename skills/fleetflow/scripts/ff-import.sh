#!/usr/bin/env bash
# ff-import.sh - turn a native Claude Code Workflow run into fleetflow lanes.
#
# A native Workflow run dir (wf_*/) holds journal.jsonl (hash-keyed started/
# result records keyed by agentId) plus agent-<id>.jsonl transcripts. This
# script folds its COMPLETED agents into <repo>/.fleetflow/<run>/ as fleetflow
# lanes so ff-collect can read them and ff-status can show them, and surfaces
# incomplete agents (started, never finished) as respawn candidates.
#
#   result record  -> <id>.prompt.txt + <id>.result.json envelope + journal
#                     started/result (brain "native", phase "imported") +
#                     manifest packet {id, brain:"native", imported_from}
#   started-only   -> <id>.prompt.txt only; reported INCOMPLETE (respawn via
#                     ff-spawn --run <run> --id <id> --brain <choice> --prompt-file)
#
# CAVEAT: native hash keys are NOT replayable here. An imported result is a
# terminal fact (the object the agent returned); the native script's control
# flow (pipeline/barrier/loop) is not recovered. Continuing the work = spawning
# NEW lanes (e.g. off an incomplete agent's prompt), not resuming the native run.
#
# stdout: one TSV line per agent: id<TAB>imported|incomplete<TAB>prompt_chars.
# stderr: chatter. Exit: 0 ok | 2 usage/bad dir | 3 nothing to import.
set -u

FF_VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: ff-import.sh --wf DIR --run NAME [--repo PATH]

  --wf DIR     native Claude Code Workflow run directory (wf_*/) containing
               journal.jsonl and agent-<id>.jsonl transcripts (+ .meta.json)
  --run NAME   fleetflow run name to create/extend under <repo>/.fleetflow/
  --repo PATH  repo root (default: git toplevel of cwd)

  Completed native agents become fleetflow lanes (prompt + result envelope +
  journal + manifest). Incomplete agents (started, no result) get a prompt
  file and are flagged INCOMPLETE for respawn. Native keys are NOT replayable -
  imported results are terminal facts; the native control flow is not recovered.

EXAMPLES
  ff-import.sh --wf ~/.claude/projects/<enc>/<sess>/subagents/workflows/wf_ab12cd34-ef \
               --run imported-currency
  ff-import.sh --wf ./wf_ab12cd34-ef --run imp --repo /path/to/repo \
    | awk -F'\t' '$2=="incomplete"{print "respawn:", $1}'
EOF
}

err() { echo "ff-import: $*" >&2; }
tsv() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }   # id <TAB> status <TAB> chars

WF="" RUN="" REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wf) WF="${2:-}"; shift 2 ;;
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
command -v git >/dev/null || { err "git required"; exit 2; }
[ -n "$WF" ]  || { err "--wf required"; usage >&2; exit 2; }
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
echo "$RUN" | grep -qE '^[a-z0-9-]+$' || { err "invalid --run '$RUN' ([a-z0-9-]+)"; exit 2; }
[ -d "$WF" ] || { err "--wf not a directory: $WF"; exit 2; }
NJ="$WF/journal.jsonl"
[ -f "$NJ" ] || { err "no journal.jsonl in $WF (not a native Workflow run?)"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
JOURNAL="$RUNDIR/journal.jsonl"
MANIFEST="$RUNDIR/manifest.json"
mkdir -p "$RUNDIR"
# keep the scratch tree out of git without touching the repo's .gitignore
EXCL="$(git -C "$REPO" rev-parse --absolute-git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCL")"
grep -qs '^\.fleetflow/$' "$EXCL" 2>/dev/null || echo ".fleetflow/" >> "$EXCL"

# Extract the agent's ORIGINAL prompt from its transcript: the first user-role
# message's text. content may be a string (the prompt) or an array of blocks
# (later tool_result turns); we want the first one carrying text. "" if absent.
extract_prompt() {  # <transcript-path>  -> echoes prompt text
  local t="$1"
  [ -f "$t" ] || return 1
  jq -rs '
    [.[] | select(.type=="user" and .message.role=="user") | .message.content
       | if   type=="string" then .
         elif type=="array"  then (map(select(.type=="text")) | .[0].text // empty)
         else empty end]
    | map(select((. // "") != ""))
    | .[0] // ""' "$t" 2>/dev/null | tr -d '\r'
}

prompt_abs() { ( cd "$RUNDIR" && pwd ) >/dev/null 2>&1; printf '%s/%s' "$RUNDIR" "$1"; }

# is this agent already imported into the fleetflow journal? (idempotent re-run)
already_imported() {  # <id> <key>  -> rc 0 if present, 1 if not (stdout suppressed)
  [ -f "$JOURNAL" ] || return 1
  jq -es --arg id "$1" --arg k "$2" \
    '[.[] | objects | select(.type=="started" and .brain=="native" and .id==$id and .key==$k)] | length > 0' \
    "$JOURNAL" >/dev/null 2>&1
}

# upsert one packet into the manifest (idempotent by id), creating it if absent
upsert_packet() {  # <id> <key>
  local id="$1" key="$2" entry
  entry="$(jq -nc --arg id "$id" --arg pf "$(prompt_abs "$id.prompt.txt")" \
    --arg k "$key" --arg wf "$WF" \
    '{id:$id,brain:"native",phase:"imported",prompt_file:$pf,imported_from:$wf,key:$k}')"
  if [ ! -s "$MANIFEST" ]; then
    jq -nc --arg run "$RUN" --arg by "ff-import/$FF_VERSION" --argjson entry "$entry" \
      '{run:$run,base:"main",created_by:$by,phases:["imported"],packets:[$entry]}' > "$MANIFEST"
  else
    jq --argjson entry "$entry" --arg id "$id" \
      '.packets = ((.packets // []) | map(select(.id != $id))) + [$entry]
       | .phases = (((.phases // []) + ["imported"]) | unique)' \
      "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
  fi
}

# --- enumerate agents from the native journal ----------------------------------
# result agents (completed) and started-only agents (incomplete), each with key.
# NB: this Windows jq emits CRLF, so strip \r lest it cling to mid-stream values
# when we re-split the multi-line capture with `read` (the native file itself is LF).
RESULT_IDS="$(jq -r 'select(.type=="result") | "\(.agentId)\t\(.key)"' "$NJ" 2>/dev/null | tr -d '\r')"
STARTED_IDS="$(jq -r 'select(.type=="started") | "\(.agentId)\t\(.key)"' "$NJ" 2>/dev/null | tr -d '\r')"
N_STARTED="$(printf '%s\n' "$STARTED_IDS" | grep -c . || true)"
N_RESULT="$(printf '%s\n' "$RESULT_IDS" | grep -c . || true)"
if [ "$N_STARTED" -eq 0 ] && [ "$N_RESULT" -eq 0 ]; then
  err "no started or result records in $NJ - nothing to import"
  exit 3
fi

# ids that have a result -> imported; the rest of the started set -> incomplete
HAVE_RESULT="$(printf '%s\n' "$RESULT_IDS" | awk -F'\t' '{print $1}' | sort -u)"

err "importing native run $WF -> $RUNDIR"

# --- completed agents ----------------------------------------------------------
printf '%s\n' "$RESULT_IDS" | while IFS=$'\t' read -r id key; do
  [ -n "$id" ] || continue
  tf="$WF/agent-$id.jsonl"
  prompt="$(extract_prompt "$tf" || true)"
  if [ -z "$prompt" ] && [ ! -f "$tf" ]; then
    err "WARN: $id has a result but no transcript $tf - empty prompt"
  fi
  printf '%s' "$prompt" > "$RUNDIR/$id.prompt.txt"
  # fleetflow-compatible envelope: result is the native object serialized to a
  # JSON STRING so ff-collect prints the original JSON text
  jq -c 'select(.type=="result" and .agentId==$id) | {is_error:false, result: ((.result // {}) | tojson)}' \
    --arg id "$id" "$NJ" | tail -1 > "$RUNDIR/$id.result.json"
  upsert_packet "$id" "$key"
  if ! already_imported "$id" "$key"; then
    jq -nc --arg k "$key" --arg id "$id" --arg v "$FF_VERSION" \
      '{type:"started",key:$k,id:$id,brain:"native",phase:"imported",v:$v}' >> "$JOURNAL"
    jq -nc --arg k "$key" --arg id "$id" --arg a "$(prompt_abs "$id.result.json")" \
      '{type:"result",key:$k,id:$id,brain:"native",rc:0,artifact:$a}' >> "$JOURNAL"
    err "imported $id (result)"
  else
    err "imported $id (result, already present - refreshed files)"
  fi
  tsv "$id" imported "$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
done

# --- incomplete agents (started, no result) ------------------------------------
printf '%s\n' "$STARTED_IDS" | while IFS=$'\t' read -r id key; do
  [ -n "$id" ] || continue
  printf '%s\n' "$HAVE_RESULT" | grep -qxF "$id" && continue   # has a result -> skip
  tf="$WF/agent-$id.jsonl"
  prompt="$(extract_prompt "$tf" || true)"
  if [ -z "$prompt" ] && [ ! -f "$tf" ]; then
    err "WARN: incomplete $id has no transcript $tf - empty prompt"
  fi
  printf '%s' "$prompt" > "$RUNDIR/$id.prompt.txt"
  err "incomplete $id (started, no result) - respawn candidate"
  tsv "$id" incomplete "$(printf '%s' "$prompt" | wc -c | tr -d ' ')"
done

exit 0
