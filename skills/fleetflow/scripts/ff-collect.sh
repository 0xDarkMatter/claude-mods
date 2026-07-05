#!/usr/bin/env bash
# ff-collect.sh - gate one fleetflow lane's result, or run the escape guard.
#
# Per-brain success semantics: Claude-harness brains (glm/sonnet/opus/haiku/
# fable) gate on the JSON envelope's is_error; codex gates on a non-empty
# last-message (plus JSON validity when a schema was used). The escape guard
# compares the main checkout's status against the baseline snapshotted at
# first spawn — new entries mean a worker wrote outside its lane.
# stdout: the worker's final text (data). stderr: chatter.
#
# Exit codes: 0 pass | 2 usage | 3 artifact missing | 10 gate failed
#             12 escape detected
set -u

FF_VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: ff-collect.sh --run NAME --id ID [--repo PATH] [--schema] [--repair]
       ff-collect.sh --check-main-clean [--repo PATH] [--run NAME]

  --run NAME           run name
  --id ID              lane id to gate
  --repo PATH          repo root (default: git toplevel of cwd)
  --schema             the lane used a JSON schema: require the final text to
                       parse as JSON (markdown code fences are stripped first)
  --repair             on --schema failure: save the bad output to
                       <run>/<id>.invalid.txt and respawn a <id>-repair lane
                       (one attempt); print the repaired text on success
  --check-main-clean   escape guard - compare the MAIN checkout's git status
                       against the run's baseline; exit 12 on new entries

EXAMPLES
  ff-collect.sh --run audit --id ts-refresh
  ff-collect.sh --run audit --id dissent-1 --schema
  ff-collect.sh --run audit --id verdict --schema --repair
  ff-collect.sh --check-main-clean --run audit
EOF
}

err() { echo "ff-collect: $*" >&2; }

RUN="" ID="" REPO="" SCHEMA=0 CHECK_CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --id) ID="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --schema) SCHEMA=1; shift ;;
    --check-main-clean) CHECK_CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

# --- escape guard -------------------------------------------------------------
if [ "$CHECK_CLEAN" = 1 ]; then
  BASELINE=""
  if [ -n "$RUN" ] && [ -f "$REPO/.fleetflow/$RUN/main-baseline.txt" ]; then
    BASELINE="$REPO/.fleetflow/$RUN/main-baseline.txt"
  else
    # fall back to the most recent run's baseline
    BASELINE="$(ls -t "$REPO/.fleetflow"/*/main-baseline.txt 2>/dev/null | head -1)"
  fi
  [ -n "$BASELINE" ] && [ -f "$BASELINE" ] || { err "no baseline found - run ff-spawn first"; exit 2; }
  NOW="$(git -C "$REPO" status --porcelain 2>/dev/null)"
  NEW="$(comm -13 <(sort "$BASELINE") <(printf '%s\n' "$NOW" | sort) | grep -v '^\s*$' || true)"
  if [ -n "$NEW" ]; then
    err "ESCAPE DETECTED - main checkout changed since baseline:"
    printf '%s\n' "$NEW"
    err "salvage: git -C \"$REPO\" stash push -u -- <path>; then apply in the lane"
    exit 12
  fi
  echo "main-clean"
  exit 0
fi

# --- lane gate ------------------------------------------------------------
[ -n "$RUN" ] && [ -n "$ID" ] || { err "--run and --id required"; usage >&2; exit 2; }
RUNDIR="$REPO/.fleetflow/$RUN"
JOURNAL="$RUNDIR/journal.jsonl"

BRAIN=""
[ -f "$JOURNAL" ] && \
  BRAIN="$(jq -r --arg id "$ID" 'select(.type=="result" and .id==$id) | .brain' "$JOURNAL" 2>/dev/null | tail -1)"

if [ "$BRAIN" = "codex" ] || { [ -z "$BRAIN" ] && [ -f "$RUNDIR/$ID.last.txt" ]; }; then
  ART="$RUNDIR/$ID.last.txt"
  [ -s "$ART" ] || { err "codex last-message missing/empty: $ART"; exit 3; }
  if [ "$SCHEMA" = 1 ]; then
    jq empty < "$ART" 2>/dev/null || { err "final message is not valid JSON (schema lane)"; exit 10; }
  fi
  cat "$ART"
  exit 0
fi

ART="$RUNDIR/$ID.result.json"
[ -s "$ART" ] || { err "result missing/empty: $ART"; exit 3; }
# NB: jq's // treats boolean false as absent, so probe with has()
IS_ERR="$(jq -r 'if has("is_error") then (.is_error|tostring) else "missing" end' "$ART" 2>/dev/null)"
[ -n "$IS_ERR" ] && [ "$IS_ERR" != "missing" ] || { err "unparseable result envelope: $ART"; exit 10; }
if [ "$IS_ERR" != "false" ]; then
  err "worker reported is_error=$IS_ERR"
  jq -r '.result // empty' "$ART" | head -5 >&2
  exit 10
fi
TEXT="$(jq -r '.result // empty' "$ART")"
if [ "$SCHEMA" = 1 ]; then
  printf '%s' "$TEXT" | jq empty 2>/dev/null || { err "final text is not valid JSON (schema lane)"; exit 10; }
fi
printf '%s\n' "$TEXT"
exit 0
