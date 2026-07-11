#!/usr/bin/env bash
# ff-collect.sh - gate one fleetflow lane's result, or run the escape guard.
#
# Per-brain success semantics: Claude-harness brains (glm/sonnet/opus/haiku/
# fable) gate on the JSON envelope's is_error; codex gates on a non-empty
# last-message (plus JSON validity when a schema was used); grok gates on a
# parseable envelope with non-empty .text (its envelope has no is_error - a
# failed grok run exits nonzero, which ff-spawn already caught). The escape guard
# compares the main checkout's status against the baseline snapshotted at
# first spawn — new entries mean a worker wrote outside its lane.
# stdout: the worker's final text (data). stderr: chatter.
#
# Exit codes: 0 pass | 2 usage | 3 artifact missing | 10 gate failed
#             12 escape detected
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

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

RUN="" ID="" REPO="" SCHEMA=0 CHECK_CLEAN=0 REPAIR=0 JQERR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --id) ID="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --schema) SCHEMA=1; shift ;;
    --repair) REPAIR=1; shift ;;
    --check-main-clean) CHECK_CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { err "jq required"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/ff-spawn.sh"
COLLECT="$HERE/ff-collect.sh"

# strip markdown code fences (```json ... ```) so schema gating tolerates fenced replies
strip_fences() { sed -E '/^[[:space:]]*```[[:alnum:]]*[[:space:]]*$/d'; }

# stdin = text; returns 0 if valid JSON else 1; sets global JQERR to the parse error
json_ok() {
  local t; t="$(cat)"
  JQERR="$(printf '%s' "$t" | jq empty 2>&1 1>/dev/null | head -1)"
  printf '%s' "$t" | jq empty >/dev/null 2>&1
}

# do_repair <bad_text> <jq_error>: save bad output, respawn a <id>-repair lane
# (same brain, --max-turns 3, no worktree), gate it, print its text on success.
# One attempt only. Exits 0 (repaired) or 10 (repair also failed). FLEETFLOW_REPAIR_DRYRUN
# forces the respawn to --dry-run (test/offline seam).
do_repair() {
  local bad="$1" jqerr="$2" rid="${ID}-repair" pf spawn_rc=0 rout rc2
  pf="$RUNDIR/$rid.prompt-src.txt"
  printf '%s' "$bad" > "$RUNDIR/$ID.invalid.txt"
  err "schema validation failed (--repair): saved $RUNDIR/$ID.invalid.txt; respawning lane $rid"
  printf 'Your previous FINAL REPLY failed JSON validation. Error: %s. Previous output: %s. Reply with ONLY the corrected JSON object, nothing else.' \
    "$jqerr" "$bad" > "$pf"
  if [ -n "${FLEETFLOW_REPAIR_DRYRUN:-}" ]; then
    bash "$SPAWN" --run "$RUN" --id "$rid" --brain "$BRAIN" --max-turns 3 \
      --repo "$REPO" --prompt-file "$pf" --dry-run >/dev/null 2>"$RUNDIR/$rid.spawn.err" || spawn_rc=$?
  else
    bash "$SPAWN" --run "$RUN" --id "$rid" --brain "$BRAIN" --max-turns 3 \
      --repo "$REPO" --prompt-file "$pf" >/dev/null 2>"$RUNDIR/$rid.spawn.err" || spawn_rc=$?
  fi
  case "$spawn_rc" in 0|3) ;; *) err "repair spawn failed (rc=$spawn_rc; see $RUNDIR/$rid.spawn.err)"; exit 10 ;; esac
  # gate the repair lane WITHOUT --repair (one attempt); its stdout is the repaired text
  rout="$(bash "$COLLECT" --run "$RUN" --id "$rid" --repo "$REPO" --schema 2>"$RUNDIR/$rid.collect.err")"; rc2=$?
  if [ "$rc2" = 0 ]; then printf '%s\n' "$rout"; exit 0; fi
  err "repair lane also failed validation (see $RUNDIR/$rid.collect.err)"; exit 10
}

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

if [ "$BRAIN" = "grok" ]; then
  # grok's headless envelope is {text, stopReason, sessionId, ...} with NO
  # is_error field. rc was already gated by ff-spawn (a failed run exits nonzero
  # and writes stderr), so the content gate here is: envelope parses AND produced
  # non-empty output. stopReason is informational (EndTurn = a clean turn); we do
  # NOT hard-gate on it, because an agentic tool-turn can end on other reasons.
  ART="$RUNDIR/$ID.result.json"
  [ -s "$ART" ] || { err "grok result missing/empty: $ART"; exit 3; }
  jq -e 'type=="object"' "$ART" >/dev/null 2>&1 || { err "grok envelope unparseable: $ART"; exit 10; }
  if [ "$SCHEMA" = 1 ]; then
    # --json-schema makes grok emit an already-parsed .structuredOutput - prefer it
    # over re-parsing .text (grok did the validation server-side).
    SO="$(jq -c 'if has("structuredOutput") then .structuredOutput else empty end' "$ART" 2>/dev/null)"
    if [ -n "$SO" ]; then printf '%s\n' "$SO"; exit 0; fi
    # fallback: no structuredOutput (schema not passed natively) - .text may hold fenced JSON
    CLEAN="$(jq -r '.text // empty' "$ART" | strip_fences)"
    if ! printf '%s' "$CLEAN" | json_ok; then
      [ "$REPAIR" = 1 ] && do_repair "$CLEAN" "$JQERR"
      err "grok final output not valid JSON (schema lane): $JQERR"; exit 10
    fi
    printf '%s\n' "$CLEAN"
    exit 0
  fi
  TEXT="$(jq -r '.text // empty' "$ART")"
  [ -n "$TEXT" ] || { err "grok produced empty text"; exit 10; }
  printf '%s\n' "$TEXT"
  exit 0
fi

if [ "$BRAIN" = "codex" ] || { [ -z "$BRAIN" ] && [ -f "$RUNDIR/$ID.last.txt" ]; }; then
  ART="$RUNDIR/$ID.last.txt"
  [ -s "$ART" ] || { err "codex last-message missing/empty: $ART"; exit 3; }
  if [ "$SCHEMA" = 1 ]; then
    CLEAN="$(strip_fences < "$ART")"
    if ! printf '%s' "$CLEAN" | json_ok; then
      [ "$REPAIR" = 1 ] && do_repair "$CLEAN" "$JQERR"
      err "final message is not valid JSON (schema lane): $JQERR"; exit 10
    fi
    printf '%s\n' "$CLEAN"
    exit 0
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
  CLEAN="$(printf '%s' "$TEXT" | strip_fences)"
  if ! printf '%s' "$CLEAN" | json_ok; then
    [ "$REPAIR" = 1 ] && do_repair "$CLEAN" "$JQERR"
    err "final text is not valid JSON (schema lane): $JQERR"; exit 10
  fi
  printf '%s\n' "$CLEAN"
  exit 0
fi
printf '%s\n' "$TEXT"
exit 0
