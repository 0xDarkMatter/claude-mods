#!/usr/bin/env bash
# Preflight a loop config - will this loop actually RUN, or die at 3am?
#
# loop-check checks the config is well-formed; loop-doctor checks the loop will
# execute: the gate command's binary resolves, claude/git are on PATH, the budget
# can fit a tick, and the permission mode is achievable from where it launches.
#
# HOST-AWARE. Since native scheduling landed, "where it launches" is a real
# variable, so the config's optional `host:` selects which constraints apply - a
# cloud routine has NO permission mode and a >=1h floor, and this machine's PATH
# says nothing about it; a session-cron host cannot run unattended at all.
# Verified surface + limits: references/native-scheduling.md (2026-08-30).
# Modeled on fleet-worker/scripts/fleet-doctor.sh.
#
# Usage:   loop-doctor.sh [--offline|--live] [--json] [-q] <loop.config.yaml>
# Input:   argv flags + a config path (no stdin).
# Output:  stdout = check rows (TSV: state<TAB>check<TAB>detail), or a --json envelope.
# Stderr:  the preflight panel, notices, errors.
# Exit:    0 ok, 2 usage, 3 config not found, 4 unparseable, 5 missing core dep,
#          10 a check predicts a runtime failure (a gate binary missing, bypass on
#          host without isolation, budget too small for a tick)
#
#   --offline (default): no PATH/exec - config-shape + budget-vs-cost + permission/
#                        isolation coherence. Safe for PR CI.
#   --live:              adds runtime preflight - claude/git on PATH, the verify/guard
#                        leading binary resolvable, the kill-switch path's parent exists.
#                        Skipped (not failed) when host: cloud-routine - the tick does
#                        not run on this machine, so this machine's PATH is irrelevant.
#
# Examples:
#   loop-doctor.sh --offline .loops/pr-watch/loop.config.yaml
#   loop-doctor.sh --live .loops/ci-watch/loop.config.yaml
#   loop-doctor.sh --live --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.state=="bad")'
set -uo pipefail

readonly EX_OK=0 EX_USAGE=2 EX_NOTFOUND=3 EX_UNPARSEABLE=4 EX_MISSING_DEP=5 EX_FINDINGS=10

__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2
else
  term_panel_open() { :; }; term_panel_close() { :; }; term_panel_vert() { :; }
  term_status_row() { shift; printf '  - %s %s\n' "$1" "${2:-}"; }
  term_color() { shift; printf '%s' "$*"; }; TERM_DOT="|"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRICING="$HERE/../assets/model-pricing.json"

CFG=""; MODE="offline"; JSON=0; QUIET=0

usage() {
  cat <<'EOF'
loop-doctor.sh - preflight a loop config (will it actually run?).

Usage:
  loop-doctor.sh [--offline|--live] [--json] [-q] <loop.config.yaml>

Options:
  --offline      config-shape + budget-vs-cost + permission coherence (default; no PATH/exec).
  --live         adds runtime preflight: claude/git on PATH, verify/guard binary resolvable
                 (skipped for host: cloud-routine - ticks do not run on this machine).
  --json         emit a JSON envelope.
  -q, --quiet    suppress the stderr panel.
  -h, --help     show this help and exit 0.

Exit codes:
  0 ok   2 usage   3 not found   4 unparseable   5 missing dep   10 predicted runtime failure

Examples:
  loop-doctor.sh --offline .loops/pr-watch/loop.config.yaml
  loop-doctor.sh --live .loops/ci-watch/loop.config.yaml
  loop-doctor.sh --live --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.state=="bad")'
EOF
}
die_usage() { printf 'error: %s\n' "$1" >&2; echo >&2; usage >&2; exit "$EX_USAGE"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline) MODE="offline"; shift ;;
    --live)    MODE="live"; shift ;;
    --json)    JSON=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit "$EX_OK" ;;
    -*)        die_usage "unknown flag: $1" ;;
    *)         [[ -z "$CFG" ]] || die_usage "unexpected extra argument: $1"; CFG="$1"; shift ;;
  esac
done

command -v awk  >/dev/null 2>&1 || { echo "loop-doctor: awk required" >&2; exit "$EX_MISSING_DEP"; }
command -v grep >/dev/null 2>&1 || { echo "loop-doctor: grep required" >&2; exit "$EX_MISSING_DEP"; }

[[ -n "$CFG" ]] || die_usage "a loop.config.yaml path is required"
[[ -f "$CFG" ]] || { printf 'error: config not found: %s\n' "$CFG" >&2; exit "$EX_NOTFOUND"; }
# Normalize Windows-authored configs: strip a leading UTF-8 BOM + CR line-endings so a
# CRLF/BOM file parses like a clean LF one (portable octal BOM + gsub \r).
__NORM="$(mktemp 2>/dev/null)" && awk 'NR==1{sub(/^\357\273\277/,"")} {gsub(/\r/,""); print}' "$CFG" > "$__NORM" 2>/dev/null && CFG="$__NORM" && trap 'rm -f "$__NORM"' EXIT
grep -Eq '^[a-z_]+:' "$CFG" || { printf 'error: no parseable keys in %s\n' "$CFG" >&2; exit "$EX_UNPARSEABLE"; }

# Pick a working python for the budget-vs-cost check (skipped gracefully if none).
PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done

# ── flat-YAML readers (no yq), same contract as loop-check.sh ────────────────
cfg_scalar() {
  awk -v k="$1" -v q="'" '
    $0 ~ "^"k":" { sub("^"k":[ \t]*",""); sub(/[ \t]*#.*$/,""); gsub(/^[ \t]+|[ \t]+$/,"");
      gsub(/^"|"$/,""); gsub("^"q"|"q"$",""); print; exit }' "$CFG"
}
cfg_list_items() {
  awk -v k="$1" -v q="'" '
    $0 ~ "^"k":" { inlist=1; next }
    inlist==1 { if ($0 ~ /^[ \t]*-[ \t]+/) { line=$0; sub(/^[ \t]*-[ \t]+/,"",line); sub(/[ \t]*#.*$/,"",line);
        gsub(/^[ \t]+|[ \t]+$/,"",line); gsub(/^"|"$/,"",line); gsub("^"q"|"q"$","",line); if (line!="") print line }
      else if ($0 ~ /^[^ \t#]/) { inlist=0 } }' "$CFG"
}

TIER="$(cfg_scalar tier)"; PMODE="$(cfg_scalar permission_mode)"; PATTERN="$(cfg_scalar pattern)"
VERIFY="$(cfg_scalar verify)"; GUARD="$(cfg_scalar guard)"; BUDGET="$(cfg_scalar budget_tokens)"
KILL="$(cfg_scalar kill_switch)"; ESCAL="$(cfg_scalar escalation)"
CADENCE="$(cfg_scalar cadence)"; HOST="$(cfg_scalar host)"; [[ -z "$HOST" ]] && HOST="local"
WORKTREE="$(cfg_scalar worktree)"
is_l2plus=0; [[ "$TIER" == "L2" || "$TIER" == "L3" ]] && is_l2plus=1

# ── findings ─────────────────────────────────────────────────────────────
ROWS=()       # "state\tcheck\tdetail"
FINDING=0
row() { ROWS+=("$1"$'\t'"$2"$'\t'"$3"); [[ "$1" == "bad" ]] && FINDING=1; }

# leading binary of a command string (first whitespace token; strips a leading VAR= prefix)
lead_bin() { awk '{ for(i=1;i<=NF;i++){ if($i !~ /=/){print $i; exit} } }' <<<"$1"; }

# ── OFFLINE checks ───────────────────────────────────────────────────────
# Cadence in minutes, for the host floor checks. Nm/Nh/Nd, or "*/N * * * *" -> N.
# Anything richer returns empty and the floor check is SKIPPED rather than guessed:
# a wrong floor finding is worse than no finding.
#
# The digits-only guard is load-bearing, not defensive padding: `1a2m` matches the
# *[0-9]m glob, and ${1%m} would hand `1a2` to arithmetic - which errors to stderr and
# leaves a garbage CAD_MIN that later trips `[[ -lt ]]`. Malformed cadence is loop-check's
# finding to report; here it must simply yield "unknown" and skip the floor check.
cadence_minutes() {
  local n=""
  case "$1" in
    *[0-9]m) n="${1%m}"; [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" ;;
    *[0-9]h) n="${1%h}"; [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$(( n * 60 ))" ;;
    *[0-9]d) n="${1%d}"; [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$(( n * 1440 ))" ;;
    */[0-9]*\ *) awk '{ n=$1; sub(/^\*\//,"",n); if (n ~ /^[0-9]+$/ && $2=="*") print n }' <<<"$1" ;;
    *) printf '' ;;
  esac
}
CAD_MIN="$(cadence_minutes "$CADENCE" 2>/dev/null)"

# Host coherence. `host:` names where ticks execute; each surface has different hard
# limits (references/native-scheduling.md, verified 2026-08-30).
case "$HOST" in
  local|external|desktop-task|cloud-routine|session-cron) row ok "host" "$HOST" ;;
  *) row bad "host" "unknown host '$HOST' - use local|session-cron|desktop-task|cloud-routine|external" ;;
esac

case "$HOST" in
  session-cron)
    # /loop + CronCreate are session-scoped: they need an open, idle session and every
    # recurring job self-deletes 7 days after creation. Fine for L1 supervised polling;
    # it cannot host an unattended loop, which is what L2+ means.
    if [[ "$is_l2plus" -eq 1 ]]; then
      row bad "host/tier" "session-cron can't run unattended ($TIER) - needs an open idle session and expires after 7 days; use desktop-task or external"
    else
      row warn "host/tier" "session-cron is supervised-only: open idle session, 7-day expiry, no catch-up for missed fires"
    fi
    ;;
  desktop-task)
    # One catch-up run for the most recently missed window; older ones are discarded,
    # so a slow tick can land at any hour. The prompt needs its own time guardrails.
    if [[ -n "$CAD_MIN" ]] && [[ "$CAD_MIN" -ge 720 ]]; then
      row warn "catch-up" "desktop-task runs ONE catch-up for the latest missed window - a $CADENCE tick may fire hours late; put time guardrails in run.md"
    fi
    # `worktree: true` in this config is a DECLARATION, not the switch. The real toggle
    # lives on the task itself and is OFF by default, so a task can satisfy the config
    # while running against the working dir including uncommitted changes. Nothing on
    # disk lets us verify it - so say so rather than implying the config settled it.
    if [[ "$WORKTREE" == "true" ]]; then
      row warn "worktree" "config declares worktree: true - confirm the TASK's worktree toggle is on (it is off by default); this file cannot enforce it"
    fi
    ;;
  cloud-routine)
    # Routines run autonomously in the cloud: no permission-mode picker, >=1h floor,
    # fresh clone with no local files. The boundary is repos + environment + connectors.
    if [[ -n "$CAD_MIN" ]] && [[ "$CAD_MIN" -lt 60 ]]; then
      row bad "cadence" "cloud-routine minimum interval is 1 hour - '$CADENCE' is rejected at creation"
    fi
    if printf '%s %s' "$ESCAL" "$(cfg_list_items scope | tr '\n' ' ')" | grep -Eqi 'connectors?|environment|network access|repositor'; then
      row ok "boundary" "cloud-routine boundary names repos/environment/connectors"
    else
      row bad "boundary" "cloud-routine has NO permission mode - the boundary must be repos + environment network policy + connectors (ALL connectors attach by default); name it in scope/escalation"
    fi
    ;;
esac

# Permission mode achievability. A cloud routine has no permission-mode picker at all,
# so requiring one there would be a false finding - the boundary check above replaces it.
if [[ "$HOST" == "cloud-routine" ]]; then
  if [[ -n "$PMODE" ]]; then
    row warn "permission_mode" "'$PMODE' is ignored by cloud routines (they run autonomously, no approval prompts)"
  else
    row ok "permission_mode" "n/a for cloud-routine"
  fi
else
  case "$PMODE" in
    default) row bad "permission_mode" "default is interactive - a headless 'claude -p' tick can't answer prompts; use dontAsk/auto/bypassPermissions" ;;
    "")      row bad "permission_mode" "missing" ;;
    *)       row ok  "permission_mode" "$PMODE" ;;
  esac
fi
# L3 bypass needs an isolation boundary.
#
# A cloud routine already IS one: it runs in Anthropic-managed cloud infrastructure on a
# fresh clone, and its permission_mode is ignored entirely. Demanding a "container" note
# there is a false finding that teaches people to write a bogus note to satisfy the tool -
# so the cloud host reports its real boundary (environment + connectors, checked above)
# instead of the host-isolation one.
if [[ "$TIER" == "L3" && "$HOST" == "cloud-routine" ]]; then
  row ok "isolation" "cloud-routine runs in Anthropic-managed cloud infra - the boundary is environment + connectors, not a local container"
elif [[ "$TIER" == "L3" && "$PMODE" == "bypassPermissions" ]]; then
  if printf '%s %s' "$ESCAL" "$(cfg_list_items scope | tr '\n' ' ')" | grep -Eqi 'container|isolat|sandbox|devcontainer'; then
    row ok "isolation" "L3 bypass declares an isolation boundary"
  else
    row bad "isolation" "L3 + bypassPermissions with no container/sandbox note - only safe in an isolated VM/container"
  fi
fi
# Budget vs estimated tokens/run.
if [[ -n "$BUDGET" && "$BUDGET" =~ ^[0-9]+$ && -n "$PY" && -n "$PATTERN" && -f "$PRICING" ]]; then
  TPR="$(PR="$PRICING" PAT="$PATTERN" "$PY" -c "import json,os
try:
 d=json.load(open(os.environ['PR']))['_pattern_defaults'].get(os.environ['PAT'])
 print((int(d['input'])+int(d['output']))*int(d.get('subagents',1)) if d else '')
except Exception: print('')" 2>/dev/null)"
  if [[ -n "$TPR" && "$TPR" =~ ^[0-9]+$ ]]; then
    if [[ "$BUDGET" -lt "$TPR" ]]; then
      row bad "budget" "budget_tokens $BUDGET < ~$TPR est. tokens/run for $PATTERN - a tick can't complete"
    else
      row ok "budget" "budget_tokens $BUDGET >= ~$TPR est. tokens/run"
    fi
  fi
fi

# ── LIVE checks ──────────────────────────────────────────────────────────
# Skipped wholesale for cloud-routine: the tick runs on a fresh cloud clone, so this
# machine's PATH, git and gate binaries say nothing about whether it will run. A pass
# here would be false confidence - worse than no check.
if [[ "$MODE" == "live" && "$HOST" == "cloud-routine" ]]; then
  row warn "live" "skipped - host cloud-routine runs on a fresh cloud clone; verify the gate in the routine's environment setup script instead"
elif [[ "$MODE" == "live" ]]; then
  if command -v claude >/dev/null 2>&1; then row ok "claude" "on PATH"; else row warn "claude" "not on PATH - the scheduler that runs 'claude -p' must have it"; fi
  if command -v git >/dev/null 2>&1; then
    row ok "git" "on PATH"
    if [[ "$is_l2plus" -eq 1 ]] && ! git worktree list >/dev/null 2>&1; then
      row warn "worktree" "'git worktree' unavailable here - L2+ isolates changes in a worktree"
    fi
  elif [[ "$is_l2plus" -eq 1 ]]; then
    row bad "git" "git not on PATH - L2+ needs it for worktree isolation + landing"
  else
    row warn "git" "git not on PATH"
  fi
  # verify / guard leading binary resolvable
  for pair in "verify:$VERIFY" "guard:$GUARD"; do
    label="${pair%%:*}"; cmd="${pair#*:}"
    [[ -z "$cmd" ]] && continue
    case "$cmd" in *"<"*">"*) continue ;; esac   # unfilled placeholder - audit's job
    bin="$(lead_bin "$cmd")"
    [[ -z "$bin" ]] && continue
    if [[ "$bin" == */* ]]; then
      [[ -x "$bin" ]] && row ok "$label" "$bin executable" || row bad "$label" "$bin not executable - the gate can't run"
    elif command -v "$bin" >/dev/null 2>&1; then
      row ok "$label" "$bin resolves"
    else
      row bad "$label" "'$bin' not on PATH - the gate command can't run at tick time"
    fi
  done
  # kill-switch path parent exists (only when it clearly names a path)
  ks_path="$(grep -oE '[^ "'"'"']*/[^ "'"'"']*' <<<"$KILL" | head -1)"
  if [[ -n "$ks_path" ]]; then
    parent="$(dirname "$ks_path")"
    [[ -d "$parent" || "$parent" == "." ]] && row ok "kill_switch" "sentinel path parent exists ($parent)" \
      || row warn "kill_switch" "sentinel parent dir missing ($parent) - create it so the switch works"
  fi
fi

# ── output ───────────────────────────────────────────────────────────────
n_bad=0; n_warn=0; n_ok=0
for r in "${ROWS[@]:-}"; do
  case "${r%%$'\t'*}" in bad) n_bad=$((n_bad+1));; warn) n_warn=$((n_warn+1));; ok) n_ok=$((n_ok+1));; esac
done

if [[ "$JSON" -eq 1 ]]; then
  printf '{\n  "data": [\n'
  if [[ ${#ROWS[@]} -gt 0 ]]; then
   for i in "${!ROWS[@]}"; do
    IFS=$'\t' read -r st ck dt <<<"${ROWS[$i]}"
    dt="${dt//\\/\\\\}"; dt="${dt//\"/\\\"}"
    sep=","; [[ "$i" -eq $(( ${#ROWS[@]} - 1 )) ]] && sep=""
    printf '    {"state": "%s", "check": "%s", "detail": "%s"}%s\n' "$st" "$ck" "$dt" "$sep"
   done
  fi
  printf '  ],\n  "meta": {"mode": "%s", "ok": %d, "warn": %d, "bad": %d, "will_run": %s, "tier": "%s", "schema": "claude-mods.loop-ops.doctor/v1"}\n}\n' \
    "$MODE" "$n_ok" "$n_warn" "$n_bad" "$([[ "$FINDING" -eq 0 ]] && echo true || echo false)" "${TIER:-unknown}"
else
  if [[ ${#ROWS[@]} -gt 0 ]]; then
    for r in "${ROWS[@]}"; do
      IFS=$'\t' read -r st ck dt <<<"$r"
      printf '%-5s %-14s %s\n' "$st" "$ck" "$dt"
    done
  fi
  if [[ "$QUIET" -eq 0 ]]; then
    verdict="$([[ "$FINDING" -eq 0 ]] && echo "WILL RUN" || echo "WILL FAIL")"
    vstate="$([[ "$FINDING" -eq 0 ]] && echo ok || echo bad)"
    {
      term_panel_open loop "loop ${TERM_DOT} doctor ($MODE)" "$(basename "$(dirname "$CFG")")"
      term_panel_vert
      term_status_row "$vstate" "$verdict" "$n_bad blocking ${TERM_DOT} $n_warn advisory ${TERM_DOT} $n_ok ok"
      [[ "$MODE" == "offline" ]] && term_status_row skip "run --live before scheduling" "checks gate binaries + PATH"
      term_panel_vert
      term_panel_close "audit = well-formed ${TERM_DOT} doctor = will-run" ""
    } >&2
  fi
fi

[[ "$FINDING" -eq 0 ]] && exit "$EX_OK" || exit "$EX_FINDINGS"
