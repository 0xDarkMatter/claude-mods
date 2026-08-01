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
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: ff-spawn.sh --run NAME --id ID --brain BRAIN --prompt-file FILE
                   [--worktree] [--base BRANCH] [--repo PATH] [--max-turns N]
                   [--effort low|medium|high|max] [--schema FILE] [--no-guard]
                   [--force] [--dry-run]

  --run NAME       run name (groups lanes; [a-z0-9-]+)
  --id ID          lane id within the run ([a-z0-9-]+)
  --brain BRAIN    glm | codex | grok | pi | sonnet | opus | haiku | fable
  --prompt-file F  packet file (guard preamble is prepended unless --no-guard)
  --phase NAME     progress-group label (default: build) - display only
  --worktree       give the worker its own worktree lane (branch fleetflow/RUN/ID)
  --base BRANCH    worktree base (default: main, falls back to HEAD)
  --repo PATH      repo root (default: git toplevel of cwd)
  --max-turns N    worker turn cap (default: 100)
  --effort LEVEL   reasoning effort lever: low|medium|high|max (default: unset =
                   inherit the brain's own default). GLM -> FLEET_WORKER_EFFORT;
                   claude brains -> --settings effortLevel; codex -> model_reasoning_effort.
                   Effort IS part of the cache key (different effort = different run).
  --schema FILE    JSON Schema for the final answer (codex: native
                   --output-schema; other brains: appended to the prompt)
  --no-guard       skip the guard preamble injection
  --force          ignore a journal cache hit and re-run
  --dry-run        do not launch a worker; write a stub result (for tests/planning)

ENV (pi brain)
  FLEETFLOW_PI_BIN                 pi launcher (default: pi on PATH; point at a
                                   local install's pi.cmd, e.g. X:/Agents/Pi/pi.cmd)
  FLEETFLOW_PI_PROVIDER            provider passed to `pi --provider` (pi's
                                   wildcard slot: gemini, deepseek, zai, groq, ...)
  FLEETFLOW_PI_MODEL               model passed to `pi --model`
                                   NOTE: lanes get an ISOLATED PI_CODING_AGENT_DIR,
                                   so ~/.pi/agent/auth.json does NOT apply - the
                                   provider's API key env var is the only auth.

ENV (codex brain)
  FLEETFLOW_CODEX_MODEL            model passed to `codex exec -m`
  FLEETFLOW_CODEX_WINDOWS_SANDBOX  windows.sandbox override, Windows hosts only
                                   (default: unelevated - `elevated` needs a UAC
                                   approval no headless lane can give). Set empty
                                   to pass nothing and defer to ~/.codex/config.toml.

EXAMPLES
  ff-spawn.sh --run audit --id ts-refresh --brain glm --worktree \
              --prompt-file packets/ts.txt
  ff-spawn.sh --run audit --id dissent-1 --brain codex --effort high \
              --prompt-file packets/refute.txt --schema verdict.schema.json
  ff-spawn.sh --run audit --id judge --brain opus --effort max --prompt-file packets/judge.txt
EOF
}

err() { echo "ff-spawn: $*" >&2; }

# main() wrapper - parse-before-execute guard (incident 2026-08-01, run
# atdw-sync, lane verify-cli-2). bash parses script files INCREMENTALLY during
# execution: when this file was rewritten mid-run (a concurrent session edit +
# a repo->global skills sync), the resuming parser read shifted bytes and a
# 5-minute lane died with a phantom "line 457: syntax error" AFTER its worker
# succeeded - in a 341-line file, with `bash -n` passing. Wrapping the whole
# procedural body in main() forces bash to parse the entire file up front, so
# a mid-run file replacement can no longer kill a running lane.
# Body is deliberately NOT re-indented (keeps the diff/blame readable).
# DO NOT unwrap this as a "simplification".
main() {

RUN="" ID="" BRAIN="" PROMPT_FILE="" WORKTREE=0 BASE="main" REPO=""
MAX_TURNS=100 SCHEMA="" GUARD=1 FORCE=0 DRYRUN=0 PHASE="build" EFFORT=""
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
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --schema) SCHEMA="${2:-}"; shift 2 ;;
    --no-guard) GUARD=0; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

case "$BRAIN" in glm|codex|grok|pi|sonnet|opus|haiku|fable) ;; *) err "invalid --brain '$BRAIN'"; exit 2 ;; esac
case "$EFFORT" in ""|low|medium|high|max) ;; *) err "invalid --effort '$EFFORT' (low|medium|high|max)"; exit 2 ;; esac

# --- Windows/Codex elevation trap (incident 2026-07-27, run bkv2p2) ------------
# codex-cli's `elevated` Windows sandbox mode provisions its AppContainer through
# a setup helper launched via ShellExecuteExW - i.e. a UAC prompt. In a HEADLESS
# fleet there is no approver, so Windows cancels the launch (error 1223 =
# ERROR_CANCELLED, surfaced as `orchestrator_helper_launch_canceled`) and the
# lane HANGS instead of failing fast: two lanes sat at state=running for 2.7h
# with dead event streams. The provisioning cache (~/.codex/.sandbox*) is why
# earlier lanes in the same session survive - any invalidation, or a race between
# concurrently-provisioning lanes, re-triggers the elevation request.
# Fleet lanes therefore pin `unelevated` PER INVOCATION. Deliberately NOT a write
# to the user's ~/.codex/config.toml: interactive Codex keeps whatever mode they
# chose. Escape hatches: FLEETFLOW_CODEX_WINDOWS_SANDBOX=elevated to opt back in,
# or ="" (empty) to pass nothing and defer to the global config.
# DO NOT remove this flag as "redundant" - it is the whole fix.
CODEX_WINSANDBOX=""
if [ "$BRAIN" = "codex" ]; then
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) CODEX_WINSANDBOX="${FLEETFLOW_CODEX_WINDOWS_SANDBOX-unelevated}" ;;
  esac
  # the binary accepts exactly these two values for windows.sandbox
  case "$CODEX_WINSANDBOX" in
    ""|elevated|unelevated) ;;
    *) err "invalid FLEETFLOW_CODEX_WINDOWS_SANDBOX '$CODEX_WINSANDBOX' (elevated|unelevated)"; exit 2 ;;
  esac
fi
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
# codex and grok take a native structured-output flag (--output-schema /
# --json-schema), so their schema is passed out-of-band, not appended to the
# prompt. Every other brain gets the schema embedded and validated at collect.
if [ -n "$SCHEMA" ] && [ "$BRAIN" != "codex" ] && [ "$BRAIN" != "grok" ]; then
  { echo; echo "FINAL REPLY MUST be a single JSON object valid against this schema:";
    cat "$SCHEMA"; } >> "$SENT"
fi

# --- journal: hash-keyed replay cache (native Workflow pattern) --------------
# effort is part of the key (different effort = a different run), per Wave 1.
# The env-selected model is part of the key too (added 2026-08-01): for codex/
# grok/pi the model comes from FLEETFLOW_* env, not the prompt, so without it
# two pi lanes on DIFFERENT providers running the same packet collided into one
# cache entry (found benching pi across google/openai/zai). Anthropic brains
# don't need it - their model IS the brain name, already hashed. NB: this
# invalidates pre-2026-08 journal keys for codex/grok lanes (they gain the
# "|model=" suffix) - old runs replay live once, then re-cache.
KEY_MODEL=""
case "$BRAIN" in
  codex) KEY_MODEL="${FLEETFLOW_CODEX_MODEL:-}" ;;
  grok)  KEY_MODEL="${FLEETFLOW_GROK_MODEL:-}" ;;
  pi)    KEY_MODEL="${FLEETFLOW_PI_PROVIDER:-}/${FLEETFLOW_PI_MODEL:-}" ;;
esac
OPTS="turns=$MAX_TURNS|wt=$WORKTREE|schema=$( [ -n "$SCHEMA" ] && basename "$SCHEMA" )|effort=$EFFORT|model=$KEY_MODEL"
KEY="v2:$( { printf '%s\n' "$BRAIN"; cat "$SENT"; printf '%s' "$OPTS"; } | sha256sum | cut -d' ' -f1)"
JOURNAL="$RUNDIR/journal.jsonl"

# --- run manifest (orchestrator-side packet metadata; ff-run replays it) ----
# Created on first spawn; each spawn upserts its packet by id (idempotent).
MANIFEST="$RUNDIR/manifest.json"
prompt_abs() {
  local d
  d="$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd)" || { printf '%s' "$PROMPT_FILE"; return; }
  printf '%s/%s' "$d" "$(basename "$PROMPT_FILE")"
}
WT_JSON="false"; [ "$WORKTREE" = 1 ] && WT_JSON="true"
MENTRY="$(jq -nc --arg id "$ID" --arg b "$BRAIN" --arg p "$PHASE" --arg pf "$(prompt_abs)" \
  --argjson wt "$WT_JSON" --argjson mt "$MAX_TURNS" --arg e "$EFFORT" --arg s "${SCHEMA:-}" --arg k "$KEY" \
  '{id:$id,brain:$b,phase:$p,prompt_file:$pf,worktree:$wt,max_turns:$mt,effort:$e,schema:$s,key:$k}')"
if [ ! -s "$MANIFEST" ]; then
  jq -nc --arg run "$RUN" --arg base "$BASE" --arg by "ff-spawn/$FF_VERSION" \
    --argjson entry "$MENTRY" --arg phase "$PHASE" \
    '{run:$run,base:$base,created_by:$by,phases:[$phase],packets:[$entry]}' > "$MANIFEST"
else
  jq --argjson entry "$MENTRY" --arg id "$ID" --arg phase "$PHASE" \
    '.packets = ((.packets // []) | map(select(.id != $id))) + [$entry]
     | .phases = (((.phases // []) + [$phase]) | unique)' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
fi

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

# phase is display metadata only - deliberately NOT part of the cache key.
#
# The exact model is journalled because for codex and grok it is otherwise
# UNRECOVERABLE after the fact: their event streams carry no model field, so the
# id exists only in this process's environment and dies with it. Claude-brain
# workers self-report theirs in result.json's modelUsage, but recording it here
# too means every lane can answer "what actually ran" the same way. Also display
# metadata, also deliberately out of the cache key.
SPAWN_MODEL=""
case "$BRAIN" in
  codex) SPAWN_MODEL="${FLEETFLOW_CODEX_MODEL:-}" ;;
  grok)  SPAWN_MODEL="${FLEETFLOW_GROK_MODEL:-}" ;;
  pi)    SPAWN_MODEL="${FLEETFLOW_PI_PROVIDER:+$FLEETFLOW_PI_PROVIDER/}${FLEETFLOW_PI_MODEL:-}" ;;
  fable) SPAWN_MODEL="claude-fable-5" ;;
  *)     SPAWN_MODEL="$BRAIN" ;;
esac
jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$BRAIN" --arg p "$PHASE" --arg v "$FF_VERSION" \
  --arg m "$SPAWN_MODEL" \
  '{type:"started",key:$k,id:$id,brain:$b,phase:$p,v:$v,
    model:(if $m=="" then null else $m end)}' >> "$JOURNAL"

# --- reap anchor (2026-07-27: TaskStop left 5 orphaned codex.exe alive) --------
# Killing the wrapper does NOT kill the worker: `codex exec` spawns codex.exe and
# codex-code-mode-host.exe as descendants, and they survive. Journal THIS
# process's ids so ff-clean --reap can identify that subtree afterwards - $$ is
# ff-spawn, the worker is always below it.
#
# Both ids are recorded because they live in different namespaces: the PID bash
# reports is a Cygwin id, useless to taskkill/Stop-Process, which need the
# Windows PID. `ps -W` is the only place the two appear side by side. Windows
# does not reparent orphans, so a dead ff-spawn's WINPID still identifies its
# subtree - which is exactly the post-kill case reaping has to handle. `at`
# guards against PID reuse: a process older than the spawn cannot be ours.
REAP_WINPID=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) REAP_WINPID="$(ps -W 2>/dev/null | awk -v p=$$ '$1==p {print $4; exit}')" ;;
esac
jq -nc --arg id "$ID" --arg b "$BRAIN" --argjson pid "$$" --arg w "${REAP_WINPID:-}" \
  --argjson at "$(date +%s)" \
  '{type:"proc",id:$id,brain:$b,pid:$pid,
    winpid:(if $w=="" then null else ($w|tonumber) end),at:$at}' >> "$JOURNAL"

# --- launch -------------------------------------------------------------------
ART="$RUNDIR/$ID.result.json"
ERRF="$RUNDIR/$ID.err"
RC=0

# cache/tmp redirect: worker/pytest/uv litter lands OUTSIDE repo + lanes
# (a codex sandbox once left AppContainer-ACL'd pytest dirs inside a lane that
# resisted unelevated deletion and blocked a repo move).
CACHE_DIR="${FLEETFLOW_CACHE_ROOT:-$HOME/.fleet-worker/cache}/$RUN-$ID"
mkdir -p "$CACHE_DIR"
CFGD="${FLEET_WORKER_CONFIG_DIR:-$HOME/.fleet-worker/cfg-ff-$ID}"
# precompute the claude --settings effortLevel JSON so ${EFFORT:+...} stays simple
EFF_JSON=""
[ -n "$EFFORT" ] && EFF_JSON="$(jq -nc --arg e "$EFFORT" '{"effortLevel":$e}' 2>/dev/null)"

# archive the session transcript next to the artifact (best-effort, never fatal)
archive_transcript() {
  local dest="$RUNDIR/$ID.transcript.jsonl" src="" sid enc
  case "$BRAIN" in
    glm)
      src="$(ls -t "$CFGD"/projects/*/*.jsonl 2>/dev/null | head -1)"
      ;;
    pi)
      # pi persists sessions under <PI_CODING_AGENT_DIR>/sessions/<path-slug>/<uuid>.jsonl;
      # the lane's dir is isolated, so the newest session there is unambiguously ours
      src="$(ls -t "$CFGD"/sessions/*/*.jsonl 2>/dev/null | head -1)"
      ;;
    sonnet|opus|haiku|fable)
      sid="$(jq -r '.session_id // empty' "$ART" 2>/dev/null)"
      if [ -n "$sid" ]; then
        # workdir encoding: per-char [:\\/.] -> "-" (verified empirically:
        # C:\Users\Mack -> C--Users-Mack under ~/.claude/projects)
        enc="$(printf '%s' "$WORKDIR" | sed 's#[:\\/.]#-#g')"
        src="$HOME/.claude/projects/$enc/$sid.jsonl"
        [ -f "$src" ] || src="$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
      fi
      ;;
  esac
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp -f "$src" "$dest" 2>/dev/null && err "archived transcript -> $dest" \
      || err "transcript copy failed ($src), skipped"
  else
    err "transcript source not found (${src:-no session_id}), skipped (non-fatal)"
  fi
}

if [ "$DRYRUN" = 1 ]; then
  # the stub must match the brain's real envelope so collect can gate it:
  # grok emits {text,stopReason,...} (no is_error); every other brain here
  # collects via the claude-style {is_error,result} envelope.
  case "$BRAIN" in
    grok) jq -nc '{text:"DRYRUN",stopReason:"EndTurn"}' > "$ART" ;;
    *)    jq -nc '{is_error:false,result:"DRYRUN"}' > "$ART" ;;
  esac
else
  case "$BRAIN" in
    glm)
      FW="${FLEETFLOW_FLEET_WORKER:-$HOME/.claude/skills/fleet-worker/scripts/fleet-worker}"
      [ -f "$FW" ] || { err "fleet-worker launcher not found ($FW)"; exit 5; }
      # env(1) carries the assignments: a ${VAR:+NAME=val} expansion is NOT an
      # assignment prefix (bash parses prefixes before expansion), so without
      # env the expanded NAME=val word execs as a command -> rc 127.
      ( cd "$WORKDIR" && \
        env FLEET_WORKER_CONFIG_DIR="$CFGD" \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        ${EFFORT:+FLEET_WORKER_EFFORT="$EFFORT"} \
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
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        codex exec --full-auto --ephemeral --color never --json \
          ${CODEX_WINSANDBOX:+-c windows.sandbox="$CODEX_WINSANDBOX"} \
          ${GITDIR:+--add-dir "$GITDIR"} \
          ${FLEETFLOW_CODEX_MODEL:+-m "$FLEETFLOW_CODEX_MODEL"} \
          ${EFFORT:+-c "model_reasoning_effort=$EFFORT"} \
          ${SCHEMA:+--output-schema "$SCHEMA"} \
          -o "$ART" - < "$SENT" \
      ) > "$RUNDIR/$ID.events.jsonl" 2> "$ERRF" || RC=$?
      ;;
    grok)
      # xAI's Grok Build CLI - a NON-Anthropic worker (own binary + protocol,
      # NOT a claude -p wrapper). Auth is the GROK_DEPLOYMENT_KEY env var, read
      # from the inherited environment - never written to disk or args.
      GROK="${FLEETFLOW_GROK_BIN:-grok}"
      command -v "$GROK" >/dev/null || { err "grok CLI not found ($GROK)"; exit 5; }
      # --always-approve = codex --full-auto analog: autonomous tool use, headless.
      # --json-schema takes the schema STRING (not a path) and implies json output,
      # surfacing an already-parsed .structuredOutput field (see ff-collect).
      ( cd "$WORKDIR" && \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        "$GROK" --prompt-file "$SENT" --output-format json --always-approve \
          --max-turns "$MAX_TURNS" \
          ${FLEETFLOW_GROK_MODEL:+-m "$FLEETFLOW_GROK_MODEL"} \
          ${EFFORT:+--reasoning-effort "$EFFORT"} \
          ${SCHEMA:+--json-schema "$(cat "$SCHEMA")"} \
      ) > "$ART" 2> "$ERRF" || RC=$?
      ;;
    pi)
      # earendil-works Pi (@earendil-works/pi-coding-agent) - one harness
      # fronting 15+ providers, which makes this brain the fleet's WILDCARD
      # slot: gemini/deepseek/zai/groq/... are env changes, not new brain code.
      # Posture is GLM-class: NO sandbox, so the cage is the worktree lane +
      # guard preamble; and pi has NO --max-turns equivalent, so bounds are the
      # stall detector + orchestrator wall-clock patience. Headless pi never
      # shows a trust prompt (docs/security.md) - no UAC-style hang risk.
      PI="${FLEETFLOW_PI_BIN:-pi}"
      # -f fallback: bash executes a .cmd shim fine, but its `command -v`/-x
      # tests reject one (no exec bit on NTFS), so a path-shaped FLEETFLOW_PI_BIN
      # is checked for existence instead.
      command -v "$PI" >/dev/null || [ -f "$PI" ] || { err "pi CLI not found ($PI - set FLEETFLOW_PI_BIN)"; exit 5; }
      # fleetflow effort -> pi --thinking (pi also has off/minimal below, xhigh above)
      PI_THINK=""
      case "$EFFORT" in low|medium|high) PI_THINK="$EFFORT" ;; max) PI_THINK="xhigh" ;; esac
      # - prompt via STDIN, never argv: $PI is usually a .cmd shim and cmd.exe
      #   caps the command line at ~8K chars; a guard-preamble packet exceeds it.
      # - --no-extensions/--no-skills: discovery loads behavior OUTSIDE the
      #   cache key's hash - same packet must mean same run.
      # - PI_CODING_AGENT_DIR: per-lane config/session isolation (the analog of
      #   GLM's CLAUDE_CONFIG_DIR). Consequence: ~/.pi/agent/auth.json does NOT
      #   apply - the provider's API key env var is the lane's only auth.
      ( cd "$WORKDIR" && \
        env PI_CODING_AGENT_DIR="$CFGD" \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        "$PI" -p --mode json --no-extensions --no-skills \
          ${FLEETFLOW_PI_PROVIDER:+--provider "$FLEETFLOW_PI_PROVIDER"} \
          ${FLEETFLOW_PI_MODEL:+--model "$FLEETFLOW_PI_MODEL"} \
          ${PI_THINK:+--thinking "$PI_THINK"} \
        < "$SENT" \
      ) > "$RUNDIR/$ID.events.jsonl" 2> "$ERRF" || RC=$?
      # Distill the event stream into a claude-style envelope so ff-collect's
      # default gate and ff-status's finished-lane reader work UNCHANGED ("one
      # implementation of lane state"). The stream stays on disk as the live
      # stall signal, exactly like codex's. Field mapping (docs/session-format.md):
      # pi usage {input,output,cacheRead,cacheWrite,cost.total} -> claude usage
      # names; stopReason error/aborted (or no assistant reply at all) -> is_error.
      jq -s '
        ([.[] | select(.type=="agent_end")] | last) as $end
        | (($end.messages // []) | map(select(.role=="assistant"))) as $as
        | ($as | last) as $fin
        | ($as | map(.usage // {})) as $us
        | (($fin.content // []) | map(select(.type=="text") | .text) | join("\n")) as $text
        | {is_error: (($fin == null) or ($fin.stopReason == "error") or ($fin.stopReason == "aborted")),
           result: (if $fin == null then "no assistant reply (see events/.err)"
                    else ($fin.errorMessage // $text) end),
           usage: {input_tokens: ($us | map(.input // 0) | add // 0),
                   output_tokens: ($us | map(.output // 0) | add // 0),
                   cache_read_input_tokens: ($us | map(.cacheRead // 0) | add // 0),
                   cache_creation_input_tokens: ($us | map(.cacheWrite // 0) | add // 0)},
           num_turns: ($as | length),
           total_cost_usd: (($us | map(.cost.total // 0) | add // 0) as $c
                            | if $c > 0 then $c else null end),
           modelUsage: (if ($fin.model // "") != ""
                        then {(($fin.provider // "pi") + "/" + $fin.model):
                              {outputTokens: ($us | map(.output // 0) | add // 0)}}
                        else {} end)}
      ' "$RUNDIR/$ID.events.jsonl" > "$ART" 2>> "$ERRF" || { [ "$RC" = 0 ] && RC=10; }
      # an error-flagged envelope must fail the spawn even on a clean exit,
      # or the journal would cache it as a replayable success
      [ "$RC" = 0 ] && [ "$(jq -r '.is_error' "$ART" 2>/dev/null)" = "true" ] && RC=10
      ;;
    sonnet|opus|haiku|fable)
      command -v claude >/dev/null || { err "claude CLI not found"; exit 5; }
      MODEL="$BRAIN"; [ "$BRAIN" = "fable" ] && MODEL="claude-fable-5"
      ( cd "$WORKDIR" && \
        UV_CACHE_DIR="$CACHE_DIR" TMPDIR="$CACHE_DIR" TMP="$CACHE_DIR" TEMP="$CACHE_DIR" \
        claude -p --model "$MODEL" --output-format json --max-turns "$MAX_TURNS" \
          --permission-mode "${FLEETFLOW_PERMISSION_MODE:-bypassPermissions}" \
          ${EFFORT:+--settings "$EFF_JSON"} \
        < "$SENT" \
      ) > "$ART" 2> "$ERRF" || RC=$?
      ;;
  esac
  archive_transcript
fi

jq -nc --arg k "$KEY" --arg id "$ID" --arg b "$BRAIN" --arg a "$ART" --argjson rc "$RC" \
  '{type:"result",key:$k,id:$id,brain:$b,rc:$rc,artifact:$a}' >> "$JOURNAL"

echo "$ART"
if [ "$RC" -ne 0 ]; then err "worker exited rc=$RC (see $ERRF)"; exit 10; fi
exit 0

}

main "$@"
