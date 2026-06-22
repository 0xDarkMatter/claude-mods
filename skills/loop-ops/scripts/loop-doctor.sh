#!/usr/bin/env bash
# Preflight a loop config - will this loop actually RUN, or die at 3am?
#
# loop-audit checks the config is well-formed; loop-doctor checks the loop will
# execute: the gate command's binary resolves, claude/git are on PATH, the budget
# can fit a tick, and the permission mode is achievable from where it launches.
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
#
# Examples:
#   loop-doctor.sh --offline .loops/pr-babysitter/loop.config.yaml
#   loop-doctor.sh --live .loops/ci-sweeper/loop.config.yaml
#   loop-doctor.sh --live --json .loops/dep-sweeper/loop.config.yaml | jq '.data[] | select(.state=="bad")'
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
  --live         adds runtime preflight: claude/git on PATH, verify/guard binary resolvable.
  --json         emit a JSON envelope.
  -q, --quiet    suppress the stderr panel.
  -h, --help     show this help and exit 0.

Exit codes:
  0 ok   2 usage   3 not found   4 unparseable   5 missing dep   10 predicted runtime failure

Examples:
  loop-doctor.sh --offline .loops/pr-babysitter/loop.config.yaml
  loop-doctor.sh --live .loops/ci-sweeper/loop.config.yaml
  loop-doctor.sh --live --json .loops/dep-sweeper/loop.config.yaml | jq '.data[] | select(.state=="bad")'
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
grep -Eq '^[a-z_]+:' "$CFG" || { printf 'error: no parseable keys in %s\n' "$CFG" >&2; exit "$EX_UNPARSEABLE"; }

# Pick a working python for the budget-vs-cost check (skipped gracefully if none).
PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done

# ── flat-YAML readers (no yq), same contract as loop-audit.sh ────────────────
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
is_l2plus=0; [[ "$TIER" == "L2" || "$TIER" == "L3" ]] && is_l2plus=1

# ── findings ─────────────────────────────────────────────────────────────
ROWS=()       # "state\tcheck\tdetail"
FINDING=0
row() { ROWS+=("$1"$'\t'"$2"$'\t'"$3"); [[ "$1" == "bad" ]] && FINDING=1; }

# leading binary of a command string (first whitespace token; strips a leading VAR= prefix)
lead_bin() { awk '{ for(i=1;i<=NF;i++){ if($i !~ /=/){print $i; exit} } }' <<<"$1"; }

# ── OFFLINE checks ───────────────────────────────────────────────────────
# Permission mode achievability.
case "$PMODE" in
  default) row bad "permission_mode" "default is interactive - a headless 'claude -p' tick can't answer prompts; use dontAsk/auto/bypassPermissions" ;;
  "")      row bad "permission_mode" "missing" ;;
  *)       row ok  "permission_mode" "$PMODE" ;;
esac
# L3 bypass needs an isolation boundary.
if [[ "$TIER" == "L3" && "$PMODE" == "bypassPermissions" ]]; then
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
if [[ "$MODE" == "live" ]]; then
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
