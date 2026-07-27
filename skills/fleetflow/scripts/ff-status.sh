#!/usr/bin/env bash
# ff-status.sh - emit a fleetflow run's live status as JSON (the data feed
# behind assets/ff-monitor.html, and a machine-readable run summary on its own).
#
# Reads the run journal + artifacts; never modifies anything. Lane state is
# derived from journal records (started-without-result = running), timings
# from artifact mtimes, activity from lane commits (claude brains) or the
# codex event stream (item.completed counts + last item). A running lane whose
# activity signal has gone silent past FLEETFLOW_STALL_SECONDS is reported
# `stalled` (see the stall block below for why that state has to exist).
# stdout: the JSON document (data only). stderr: chatter.
#
# Exit codes: 0 ok | 2 usage | 14 stalled lane(s) (only with --exit-stalled)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

FF_VERSION="1.1.0"

usage() {
  cat <<'EOF'
Usage: ff-status.sh --run NAME [--repo PATH] [--out FILE] [--watch SECONDS]

  --run NAME       run name under <repo>/.fleetflow/
  --repo PATH      repo root (default: git toplevel of cwd)
  --out FILE       write JSON to FILE instead of stdout
  --watch SECONDS  loop forever, rewriting --out every SECONDS (requires --out)
  --exit-stalled   exit 14 if any lane is stalled (still emits the JSON first).
                   With --watch this turns the loop into a watchdog: it polls
                   until a lane stalls, then exits 14.

Lane state: running | stalled | done | failed. A lane is `stalled` once its
LIVE stream (codex --json events, claude/glm session transcript) has been silent
longer than FLEETFLOW_STALL_SECONDS (default 600). `last_activity_s` is reported
for every lane; `live_signal` says whether the lane has a stream that could
substantiate a stall at all - where it is false, `stalled` is always false and
means "cannot tell", not "healthy".

ENV
  FLEETFLOW_STALL_SECONDS  silence before a running lane reads stalled (600)

EXAMPLES
  ff-status.sh --run currency | jq '.lanes[] | {id, state, elapsed_s}'
  ff-status.sh --run currency | jq '.lanes[] | select(.stalled) | {id, last_activity_s}'
  ff-status.sh --run currency --out .fleetflow/currency/status.json --watch 3
  ff-status.sh --run currency --exit-stalled >/dev/null || echo "a lane is wedged"
EOF
}

err() { echo "ff-status: $*" >&2; }

RUN="" REPO="" OUT="" WATCH="" EXIT_STALLED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --watch) WATCH="${2:-}"; shift 2 ;;
    --exit-stalled) EXIT_STALLED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ] || { err "--run required"; usage >&2; exit 2; }
command -v jq >/dev/null || { err "jq required"; exit 2; }
[ -z "$WATCH" ] || [ -n "$OUT" ] || { err "--watch requires --out"; exit 2; }
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || true
RUNDIR="$REPO/.fleetflow/$RUN"
[ -f "$RUNDIR/journal.jsonl" ] || { err "no journal at $RUNDIR"; exit 2; }
STALL_S="${FLEETFLOW_STALL_SECONDS:-600}"
echo "$STALL_S" | grep -qE '^[0-9]+$' || { err "FLEETFLOW_STALL_SECONDS must be an integer"; exit 2; }

mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

emit() {
  local now lanes id brain state started finished elapsed art commits last_c tools activity tokens etail rc
  local T enc f m last_act idle stalled live
  # NOT local: --exit-stalled reads it after emit returns, and in --watch mode it
  # must reset every tick so a lane that resumes writing clears the verdict.
  STALL_ANY=0
  now=$(date +%s)
  lanes="[]"
  for id in $(jq -r 'select(.type=="started") | .id' "$RUNDIR/journal.jsonl" | awk '!seen[$0]++'); do
    brain="$(jq -r --arg id "$id" 'select(.id==$id) | .brain' "$RUNDIR/journal.jsonl" | head -1)"
    phase="$(jq -r --arg id "$id" 'select(.type=="started" and .id==$id) | .phase // "build"' "$RUNDIR/journal.jsonl" | head -1)"
    # state derives from the LAST STATE-BEARING journal record for this id: a
    # respawn appends a fresh "started" AFTER an old "result", which means the
    # lane is running again. last-result-wins (tail -1 of result records) would
    # wrongly show done/failed.
    # The started/result filter is load-bearing: ff-spawn also appends "proc"
    # records (reap anchors), and any future record type would otherwise become
    # the "last" one and silently break state derivation for that lane.
    last_type="$(jq -r --arg id "$id" 'select(.id==$id and (.type=="started" or .type=="result")) | .type' "$RUNDIR/journal.jsonl" | tail -1)"
    rc="$(jq -r --arg id "$id" 'select(.type=="result" and .id==$id) | .rc' "$RUNDIR/journal.jsonl" | tail -1)"
    art="$(jq -r --arg id "$id" 'select(.type=="result" and .id==$id) | .artifact' "$RUNDIR/journal.jsonl" | tail -1)"
    if [ "$last_type" = "started" ]; then state="running"; finished=0
    elif [ -z "$rc" ]; then state="running"; finished=0
    elif [ "$rc" = "0" ]; then state="done"; finished=$(mtime "$art")
    else state="failed"; finished=$(mtime "$art"); fi
    started=$(mtime "$RUNDIR/$id.prompt.txt")
    if [ "$finished" -gt 0 ]; then elapsed=$((finished - started)); else elapsed=$((now - started)); fi
    [ "$elapsed" -ge 0 ] || elapsed=0

    commits=0; last_c=""
    if [ -d "$RUNDIR/wt-$id" ]; then
      commits="$(git -C "$RUNDIR/wt-$id" rev-list --count "main..HEAD" 2>/dev/null || echo 0)"
      last_c="$(git -C "$RUNDIR/wt-$id" log -1 --format=%s "main..HEAD" -- 2>/dev/null | head -c 90)"
    fi

    tools=0; activity=""; tokens=0; T=""
    if [ "$brain" = "codex" ] && [ -f "$RUNDIR/$id.events.jsonl" ]; then
      tools="$(jq -r 'select(.type=="item.completed" and .item.type=="command_execution") | 1' "$RUNDIR/$id.events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
      activity="$(jq -r 'select(.type=="item.completed") | .item | (.type + ": " + ((.command // .text // "") | gsub("\n";" ") | .[0:70]))' "$RUNDIR/$id.events.jsonl" 2>/dev/null | tail -1)"
      tokens="$(jq -r 'select(.usage != null) | .usage.total_tokens // (.usage.input_tokens + .usage.output_tokens) // 0' "$RUNDIR/$id.events.jsonl" 2>/dev/null | tail -1)"
      [ -n "$tokens" ] || tokens=0
    elif [ "$state" != "running" ] && [ -f "$RUNDIR/$id.result.json" ]; then
      tokens="$(jq -r '.usage.output_tokens // 0' "$RUNDIR/$id.result.json" 2>/dev/null | head -1)"
      tools="$(jq -r '.num_turns // 0' "$RUNDIR/$id.result.json" 2>/dev/null | head -1)"
      [ -n "$tokens" ] || tokens=0; [ -n "$tools" ] || tools=0
    elif [ "$state" = "running" ]; then
      # claude -p persists its session transcript as it runs - the only live
      # signal a claude-brain lane emits. GLM workers get an isolated config dir
      # (fleet-worker), so theirs is easy to find; Anthropic-brain workers use
      # host auth, so theirs lands under ~/.claude/projects/<encoded-workdir>/.
      T="$(ls -t "${FLEETFLOW_CFG_BASE:-$HOME/.fleet-worker}/cfg-ff-$id/projects"/*/*.jsonl 2>/dev/null | head -1)"
      if [ -z "$T" ] && [ -d "$RUNDIR/wt-$id" ]; then
        # Worktree lanes ONLY. Their workdir is unique to the lane, so the newest
        # transcript in its project dir is unambiguously this lane's. A
        # non-worktree lane shares the repo dir with its siblings AND with the
        # orchestrator's own session - guessing there would attribute someone
        # else's activity to this lane, which is worse than reporting none.
        # Encoding is ff-spawn's archive_transcript() rule: [:\/.] -> "-" per char.
        enc="$(printf '%s' "$RUNDIR/wt-$id" | sed 's#[:\\/.]#-#g')"
        T="$(ls -t "$HOME/.claude/projects/$enc"/*.jsonl 2>/dev/null | head -1)"
      fi
      if [ -n "$T" ]; then
        tools="$(grep -c '"type":"tool_use"' "$T" 2>/dev/null | tr -d ' ')"
        last_tool="$(grep -o '"name":"[A-Za-z_]*"' "$T" 2>/dev/null | tail -1 | cut -d'"' -f4)"
        [ -z "$last_tool" ] || activity="live: $last_tool"
        tokens="$(grep -o '"output_tokens":[0-9]*' "$T" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
      fi
    fi
    [ -n "$activity" ] || activity="${last_c:-working}"
    etail="$(grep -v '^\s*$' "$RUNDIR/$id.err" 2>/dev/null | tail -1 | head -c 160)"

    # --- stall detection (incident 2026-07-27, run bkv2p2) --------------------
    # elapsed_s cannot distinguish a working lane from a wedged one: a codex lane
    # blocked on an un-approvable UAC prompt (see ff-spawn's windows.sandbox
    # guard) keeps `state: running` with a climbing clock forever - two lanes hid
    # that way for 2.7h. The ONE signal that separates them from outside the
    # process is whether the lane is still WRITING.
    #
    # Two tiers, and the split is load-bearing. A LIVE STREAM is a file the brain
    # appends to WHILE it works: codex's --json event stream, or a claude/glm
    # session transcript. Only those can substantiate a stall. The artifact and
    # stderr are created by the shell's redirect at LAUNCH and then sit untouched
    # until exit, so on their own they prove nothing - counting them as evidence
    # flagged every healthy 10-minute sonnet lane as stalled, and grok under
    # --output-format json (buffers to exit) has no live stream at all. They still
    # count toward last_activity_s, since a write there IS real activity, but
    # never toward the verdict.
    #
    # NEVER CLAIM A STALL YOU CANNOT SUBSTANTIATE: no live stream, no verdict.
    # `live_signal` reports which lanes the detector actually covers, so a
    # `stalled: false` it cannot back up is never read as a clean bill of health.
    last_act=0; live=false
    for f in "$RUNDIR/$id.events.jsonl" "$T"; do
      [ -n "$f" ] && [ -f "$f" ] || continue
      live=true
      m="$(mtime "$f")"; [ "$m" -gt "$last_act" ] && last_act="$m"
    done
    for f in "$RUNDIR/$id.last.txt" "$RUNDIR/$id.result.json" "$RUNDIR/$id.err"; do
      [ -f "$f" ] || continue
      m="$(mtime "$f")"; [ "$m" -gt "$last_act" ] && last_act="$m"
    done
    # nothing on disk yet (just spawned): measure silence from the lane's start
    [ "$last_act" -gt 0 ] || last_act=$started
    idle=$((now - last_act)); [ "$idle" -ge 0 ] || idle=0
    stalled=false
    if [ "$state" = "running" ] && [ "$live" = true ] && [ "$idle" -gt "$STALL_S" ]; then
      state="stalled"; stalled=true; STALL_ANY=1
    fi

    lanes="$(jq -nc --argjson L "$lanes" \
      --arg id "$id" --arg brain "$brain" --arg state "$state" --arg activity "$activity" \
      --arg last_c "$last_c" --arg etail "$etail" --arg art "${art:-}" --arg phase "${phase:-build}" \
      --argjson started "$started" --argjson elapsed "$elapsed" \
      --argjson idle "$idle" --argjson stalled "$stalled" --argjson live "$live" \
      --argjson commits "${commits:-0}" --argjson tools "${tools:-0}" --argjson tokens "${tokens:-0}" \
      '$L + [{id:$id,brain:$brain,phase:$phase,state:$state,started:$started,elapsed_s:$elapsed,
              last_activity_s:$idle,stalled:$stalled,live_signal:$live,
              commits:$commits,tools:$tools,tokens:$tokens,activity:$activity,
              last_commit:$last_c,artifact:$art,err_tail:$etail}]')"
  done
  local manifest="null"
  if [ -f "$RUNDIR/manifest.json" ]; then
    manifest="$(jq -c '{packet_count:(.packets|length), phases:(.phases // [])}' "$RUNDIR/manifest.json" 2>/dev/null)"
  fi
  jq -nc --arg run "$RUN" --arg repo "$REPO" --argjson now "$now" --argjson lanes "$lanes" \
    --argjson manifest "${manifest:-null}" --argjson stall "$STALL_S" \
    '{run:$run,repo:$repo,generated_at:$now,stall_seconds:$stall,lanes:$lanes,manifest:$manifest}'
}

STALL_ANY=0
# the JSON is always emitted first - --exit-stalled changes the exit code, never
# the data product, so a caller can pipe and branch in the same invocation.
if [ -n "$WATCH" ]; then
  err "watching every ${WATCH}s -> $OUT (ctrl-c to stop)"
  while :; do
    emit > "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"
    if [ "$EXIT_STALLED" = 1 ] && [ "$STALL_ANY" = 1 ]; then
      err "stalled lane detected - exiting 14"; exit 14
    fi
    sleep "$WATCH"
  done
elif [ -n "$OUT" ]; then
  emit > "$OUT"
else
  emit
fi
[ "$EXIT_STALLED" = 1 ] && [ "$STALL_ANY" = 1 ] && { err "stalled lane(s) detected"; exit 14; }
exit 0
