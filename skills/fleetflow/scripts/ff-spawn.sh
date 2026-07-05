#!/usr/bin/env bash
# ff-spawn.sh - spawn one fleetflow worker lane (GLM / Codex / Anthropic brain).
#
# Creates the run dir + optional worktree lane, injects the guard preamble,
# journals a hash-keyed started/result pair (native-Workflow-style replay
# cache), launches the brain-appropriate process, and writes its artifacts.
# stdout: the artifact path (data). stderr: progress chatter.
#
# Exit codes: 0 ok | 2 usage | 3 cache hit (cached artifact path on stdout)
#             5 missing dependency | 10 worker failed
set -u

usage() {
  cat <<'EOF'
Usage: ff-spawn.sh --run NAME --id ID --brain BRAIN --prompt-file FILE
                   [--worktree] [--base BRANCH] [--repo PATH] [--max-turns N]
                   [--schema FILE] [--no-guard] [--force] [--dry-run]

  --run NAME       run name (groups lanes; [a-z0-9-]+)
  --id ID          lane id within the run ([a-z0-9-]+)
  --brain BRAIN    glm | codex | sonnet | opus | haiku | fable
  --prompt-file F  packet file (guard preamble is prepended unless --no-guard)
  --phase NAME     progress-group label (default: build) - display only
  --worktree       give the worker its own worktree lane (branch fleetflow/RUN/ID)
  --base BRANCH    worktree base (default: main, falls back to HEAD)
  --repo PATH      repo root (default: git toplevel of cwd)
  --max-turns N    worker turn cap (default: 100)
  --schema FILE    JSON Schema for the final answer (codex: native
                   --output-schema; other brains: appended to the prompt)
  --no-guard       skip the guard preamble injection
  --force          ignore a journal cache hit and re-run
  --dry-run        do not launch a worker; write a stub result (for tests/planning)

EXAMPLES
  ff-spawn.sh --run audit --id ts-refresh --brain glm --worktree \
              --prompt-file packets/ts.txt
  ff-spawn.sh --run audit --id dissent-1 --brain codex \
              --prompt-file packets/refute.txt --schema verdict.schema.json
  ff-spawn.sh --run audit --id judge --brain opus --prompt-file packets/judge.txt
EOF
}

err() { echo "ff-spawn: $*" >&2; }

RUN="" ID="" BRAIN="" PROMPT_FILE="" WORKTREE=0 BASE="main" REPO=""
MAX_TURNS=100 SCHEMA="" GUARD=1 FORCE=0 DRYRUN=0 PHASE="build"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    --id) ID="${2:-}"; shift 2 ;;
    --brain) BRAIN="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --worktree) WORKTREE=1; shift ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --max-turns) MAX_TURNS="${2:-}"; shift 2 ;;
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    --no-guard) GUARD=0; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

case "$BRAIN" in glm|codex|sonnet|opus|haiku|fable) ;; *) err "invalid --brain '$BRAIN'"; exit 2 ;; esac
echo "$RUN" | grep -qE '^[a-z0-9-]+$' || { err "invalid --run"; exit 2; }
echo "$ID"  | grep -qE '^[a-z0-9-]+$' || { err "invalid --id"; exit 2; }
[ -f "$PROMPT_FILE" ] || { err "prompt file not found: $PROMPT_FILE"; exit 2; }
[ -z "$SCHEMA" ] || [ -f "$SCHEMA" ] || { err "schema file not found: $SCHEMA"; exit 2; }
command -v jq >/dev/null || { err "jq required"; exit 5; }
command -v git >/dev/null || { err "git required"; exit 5; }

[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
[ -n "$REPO" ] && [ -d "$REPO" ] || { err "not in a git repo (or --repo invalid)"; exit 2; }

RUNDIR="$REPO/.fleetflow/$RUN"
mkdir -p "$RUNDIR"
# keep the scratch tree out of git without touching the repo's .gitignore
EXCL="$(git -C "$REPO" rev-parse --absolute-git-dir)/info/exclude"
mkdir -p "$(dirname "$EXCL")"
grep -qs '^\.fleetflow/$' "$EXCL" 2>/dev/null || echo ".fleetflow/" >> "$EXCL"

# escape-guard baseline: snapshot the main checkout's status once per run
BASELINE="$RUNDIR/main-baseline.txt"
[ -f "$BASELINE" ] || git -C "$REPO" status --porcelain > "$BASELINE" 2>/dev/null

# --- build the effective prompt ---------------------------------------------
SENT="$RUNDIR/$ID.prompt.txt"
: > "$SENT"
if [ "$GUARD" = 1 ]; then
  PRE="$(dirname "${BASH_SOURCE[0]}")/../assets/guard-preamble.txt"
  [ -f "$PRE" ] && { cat "$PRE" >> "$SENT"; echo >> "$SENT"; }
fi
cat "$PROMPT_FILE" >> "$SENT"
if [ -n "$SCHEMA" ] && [ "$BRAIN" != "codex" ]; then
  { echo; echo "FINAL REPLY MUST be a single JSON object valid against this schema:";
    cat "$SCHEMA"; } >> "$SENT"
fi

# --- journal: hash-keyed replay cache (native Workflow pattern) --------------
OPTS="turns=$MAX_TURNS|wt=$WORKTREE|schema=$( [ -n "$SCHEMA" ] && basename "$SCHEMA" )"
KEY="v2:$( { printf '%s\n' "$BRAIN"; cat "$SENT"; printf '%s' "$OPTS"; } | sha256sum | cut -d' ' -f1)"
JOURNAL="$RUNDIR/journal.jsonl"
if [ "$FORCE" = 0 ] && [ -f "$JOURNAL" ]; then
  CACHED="$(jq -r --arg k "$KEY" 'select(.type=="result" and .key==$k and .rc==0) | .artifact' "$JOURNAL" 2>/dev/null | tail -1)"
  if [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
    err "cache hit for $ID (unchanged packet) - use --force to re-run"
    echo "$CACHED"
    exit 3
  fi
fi

# --- worktree lane ------------------------------------------------------------
WORKDIR="$REPO"
if [ "$WORKTREE" = 1 ]; then
  WORKDIR="$RUNDIR/wt-$ID"
  if [ ! -d "$WORKDIR" ]; then
    git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE" || BASE="HEAD"
    git -C "$REPO" worktree add -q -b "fleetflow/$RUN/$ID" "$WORKDIR" "$BASE" \
      || { err "worktree add failed"; exit 10; }
  fi
fi

# phase is display metadata only - deliberately NOT part of the cache key
jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$BRAIN" --arg p "$PHASE" \
  '{type:"started",key:$k,id:$id,brain:$b,phase:$p}' >> "$JOURNAL"

# --- launch -------------------------------------------------------------------
ART="$RUNDIR/$ID.result.json"
ERRF="$RUNDIR/$ID.err"
RC=0
if [ "$DRYRUN" = 1 ]; then
  jq -nc '{is_error:false,result:"DRYRUN"}' > "$ART"
else
  case "$BRAIN" in
    glm)
      FW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
      [ -f "$FW" ] || { err "fleet-worker launcher not found ($FW)"; exit 5; }
      ( cd "$WORKDIR" && \
        FLEET_WORKER_CONFIG_DIR="${FLEET_WORKER_CONFIG_DIR:-$HOME/.fleet-worker/cfg-ff-$ID}" \
        bash "$FW" --output-format json --max-turns "$MAX_TURNS" "$(cat "$SENT")" \
      ) > "$ART" 2> "$ERRF" || RC=$?
      ;;
    codex)
      command -v codex >/dev/null || { err "codex CLI not found"; exit 5; }
      ART="$RUNDIR/$ID.last.txt"
      # a worktree's git metadata lives in the MAIN repo's .git - outside the
      # codex sandbox's writable root - so git commit fails without this carve-out
      GITDIR=""; [ "$WORKTREE" = 1 ] && GITDIR="$(git -C "$REPO" rev-parse --absolute-git-dir)"
      ( cd "$WORKDIR" && \
        codex exec --full-auto --ephemeral --color never --json \
          ${GITDIR:+--add-dir "$GITDIR"} \
          ${FLEETFLOW_CODEX_MODEL:+-m "$FLEETFLOW_CODEX_MODEL"} \
          ${SCHEMA:+--output-schema "$SCHEMA"} \
          -o "$ART" - < "$SENT" \
      ) > "$RUNDIR/$ID.events.jsonl" 2> "$ERRF" || RC=$?
      ;;
    sonnet|opus|haiku|fable)
      command -v claude >/dev/null || { err "claude CLI not found"; exit 5; }
      MODEL="$BRAIN"; [ "$BRAIN" = "fable" ] && MODEL="claude-fable-5"
      ( cd "$WORKDIR" && \
        claude -p --model "$MODEL" --output-format json --max-turns "$MAX_TURNS" \
          --permission-mode "${FLEETFLOW_PERMISSION_MODE:-bypassPermissions}" \
        < "$SENT" \
      ) > "$ART" 2> "$ERRF" || RC=$?
      ;;
  esac
fi

jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$BRAIN" --arg a "$ART" --argjson rc "$RC" \
  '{type:"result",key:$k,id:$id,brain:$b,rc:$rc,artifact:$a}' >> "$JOURNAL"

echo "$ART"
if [ "$RC" -ne 0 ]; then err "worker exited rc=$RC (see $ERRF)"; exit 10; fi
exit 0
