#!/usr/bin/env bash
# ff-status.sh - emit a fleetflow run's live status as JSON (the data feed
# behind assets/ff-monitor.html, and a machine-readable run summary on its own).
#
# Reads the run journal + artifacts; never modifies anything. Lane state is
# derived from journal records (started-without-result = running), timings
# from artifact mtimes, activity from lane commits (claude brains) or the
# codex event stream (item.completed counts + last item).
# stdout: the JSON document (data only). stderr: chatter.
#
# Exit codes: 0 ok | 2 usage
set -u

usage() {
  cat <<'EOF'
Usage: ff-status.sh --run NAME [--repo PATH] [--out FILE] [--watch SECONDS]

  --run NAME       run name under <repo>/.fleetflow/
  --repo PATH      repo root (default: git toplevel of cwd)
  --out FILE       write JSON to FILE instead of stdout
  --watch SECONDS  loop forever, rewriting --out every SECONDS (requires --out)

EXAMPLES
  ff-status.sh --run currency | jq '.lanes[] | {id, state, elapsed_s}'
  ff-status.sh --run currency --out .fleetflow/currency/status.json --watch 3
EOF
}

err() { echo "ff-status: $*" >&2; }

RUN="" REPO="" OUT="" WATCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --watch) WATCH="${2:-}"; shift 2 ;;
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

mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

emit() {
  local now lanes id brain state started finished elapsed art commits last_c tools activity tokens etail rc
  now=$(date +%s)
  lanes="[]"
  for id in $(jq -r 'select(.type=="started") | .id' "$RUNDIR/journal.jsonl" | awk '!seen[$0]++'); do
    brain="$(jq -r --arg id "$id" 'select(.id==$id) | .brain' "$RUNDIR/journal.jsonl" | head -1)"
    rc="$(jq -r --arg id "$id" 'select(.type=="result" and .id==$id) | .rc' "$RUNDIR/journal.jsonl" | tail -1)"
    art="$(jq -r --arg id "$id" 'select(.type=="result" and .id==$id) | .artifact' "$RUNDIR/journal.jsonl" | tail -1)"
    if [ -z "$rc" ]; then state="running"; finished=0
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

    tools=0; activity=""; tokens=0
    if [ "$brain" = "codex" ] && [ -f "$RUNDIR/$id.events.jsonl" ]; then
      tools="$(jq -r 'select(.type=="item.completed" and .item.type=="command_execution") | 1' "$RUNDIR/$id.events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
      activity="$(jq -r 'select(.type=="item.completed") | .item | (.type + ": " + ((.command // .text // "") | gsub("\n";" ") | .[0:70]))' "$RUNDIR/$id.events.jsonl" 2>/dev/null | tail -1)"
      tokens="$(jq -r 'select(.usage != null) | .usage.total_tokens // (.usage.input_tokens + .usage.output_tokens) // 0' "$RUNDIR/$id.events.jsonl" 2>/dev/null | tail -1)"
      [ -n "$tokens" ] || tokens=0
    elif [ "$state" != "running" ] && [ -f "$RUNDIR/$id.result.json" ]; then
      tokens="$(jq -r '.usage.output_tokens // 0' "$RUNDIR/$id.result.json" 2>/dev/null | head -1)"
      tools="$(jq -r '.num_turns // 0' "$RUNDIR/$id.result.json" 2>/dev/null | head -1)"
      [ -n "$tokens" ] || tokens=0; [ -n "$tools" ] || tools=0
    fi
    [ -n "$activity" ] || activity="${last_c:-working}"
    etail="$(grep -v '^\s*$' "$RUNDIR/$id.err" 2>/dev/null | tail -1 | head -c 160)"

    lanes="$(jq -nc --argjson L "$lanes" \
      --arg id "$id" --arg brain "$brain" --arg state "$state" --arg activity "$activity" \
      --arg last_c "$last_c" --arg etail "$etail" --arg art "${art:-}" \
      --argjson started "$started" --argjson elapsed "$elapsed" \
      --argjson commits "${commits:-0}" --argjson tools "${tools:-0}" --argjson tokens "${tokens:-0}" \
      '$L + [{id:$id,brain:$brain,state:$state,started:$started,elapsed_s:$elapsed,
              commits:$commits,tools:$tools,tokens:$tokens,activity:$activity,
              last_commit:$last_c,artifact:$art,err_tail:$etail}]')"
  done
  jq -nc --arg run "$RUN" --arg repo "$REPO" --argjson now "$now" --argjson lanes "$lanes" \
    '{run:$run,repo:$repo,generated_at:$now,lanes:$lanes}'
}

if [ -n "$WATCH" ]; then
  err "watching every ${WATCH}s -> $OUT (ctrl-c to stop)"
  while :; do emit > "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"; sleep "$WATCH"; done
elif [ -n "$OUT" ]; then
  emit > "$OUT"
else
  emit
fi
exit 0
