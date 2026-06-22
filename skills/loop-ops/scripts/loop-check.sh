#!/usr/bin/env bash
# Score an outer-loop config for readiness before it is scheduled.
#
# Usage:   loop-check.sh [OPTIONS] <loop.config.yaml>
# Input:   argv flags + a config path (no stdin).
# Output:  stdout = findings (plain `SEVERITY  message` rows, or --json envelope).
#          Data only.
# Stderr:  the readiness panel (score + verdict), notices, errors.
# Exit:    0 ready (no errors, score >= --min), 2 usage, 3 config not found,
#          4 config unparseable, 10 NOT ready (findings present)
#
# Scores a flat loop.config.yaml against the tier's requirements: a bounded scope,
# a defined escalation rule + kill switch, and — at L2+ — a verify gate, a guard, a
# worktree, and a landing path. The config is parsed without a yq dependency.
# Pair with loop-scaffold.sh (scaffold) and references/risk-tiers.md (the rubric).
#
# Examples:
#   loop-check.sh .loops/pr-watch/loop.config.yaml
#   loop-check.sh --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.severity=="error")'
#   loop-check.sh --min 80 --strict .loops/ci-watch/loop.config.yaml
set -uo pipefail

readonly EX_OK=0 EX_USAGE=2 EX_NOTFOUND=3 EX_UNPARSEABLE=4 EX_FINDINGS=10

# Terminal design system. stdout = findings (data); the score panel frames on stderr.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2
else
  term_panel_open() { :; }; term_panel_close() { :; }; term_panel_vert() { :; }
  term_status_row() { shift; printf '  - %s %s\n' "$1" "${2:-}"; }
  term_pip_bar() { printf '%s/%s' "$2" "$3"; }
  term_color() { shift; printf '%s' "$*"; }; TERM_DOT="|"
fi

CFG=""
MIN=70
STRICT=0
JSON=0

usage() {
  cat <<'EOF'
loop-check.sh — score an outer-loop config for readiness.

Usage:
  loop-check.sh [OPTIONS] <loop.config.yaml>

Options:
  --min N        readiness score (0-100) required for a "ready" verdict (default: 70).
  --strict       count warnings toward the NOT-ready signal (exit 10).
  --json         emit a JSON envelope instead of plain rows.
  -h, --help     show this help and exit 0.

Exit codes:
  0 ready    2 usage    3 config not found    4 unparseable    10 NOT ready (findings)

Examples:
  loop-check.sh .loops/pr-watch/loop.config.yaml
  loop-check.sh --json .loops/dep-bump/loop.config.yaml | jq '.data[] | select(.severity=="error")'
  loop-check.sh --min 80 --strict .loops/ci-watch/loop.config.yaml
EOF
}

die_usage() { printf 'error: %s\n' "$1" >&2; echo >&2; usage >&2; exit "$EX_USAGE"; }

# ── parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min)     [[ $# -ge 2 ]] || die_usage "--min needs a value"; MIN="$2"; shift 2 ;;
    --strict)  STRICT=1; shift ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit "$EX_OK" ;;
    -*)        die_usage "unknown flag: $1" ;;
    *)         [[ -z "$CFG" ]] || die_usage "unexpected extra argument: $1"; CFG="$1"; shift ;;
  esac
done

[[ -n "$CFG" ]] || die_usage "a loop.config.yaml path is required"
[[ "$MIN" =~ ^[0-9]+$ ]] || die_usage "--min must be an integer (got '$MIN')"
[[ -f "$CFG" ]] || { printf 'error: config not found: %s\n' "$CFG" >&2; exit "$EX_NOTFOUND"; }

# Unparseable: no top-level `key:` lines at all.
if ! grep -Eq '^[a-z_]+:' "$CFG"; then
  printf 'error: no parseable top-level keys in %s\n' "$CFG" >&2
  exit "$EX_UNPARSEABLE"
fi

# ── flat-YAML readers (no yq) ───────────────────────────────────────────────
cfg_scalar() { # inline scalar value for `^KEY:`; empty if absent or block-list
  awk -v k="$1" -v q="'" '
    $0 ~ "^"k":" {
      sub("^"k":[ \t]*","")
      sub(/[ \t]*#.*$/,"")
      gsub(/^[ \t]+|[ \t]+$/,"")
      gsub(/^"|"$/,""); gsub("^"q"|"q"$","")
      print; exit
    }' "$CFG"
}
cfg_has_key() { grep -Eq "^$1:" "$CFG"; }
cfg_list_items() { # `  - item` lines under `^KEY:`, until the next top-level key
  awk -v k="$1" -v q="'" '
    $0 ~ "^"k":" { inlist=1; next }
    inlist==1 {
      if ($0 ~ /^[ \t]*-[ \t]+/) {
        line=$0
        sub(/^[ \t]*-[ \t]+/,"",line); sub(/[ \t]*#.*$/,"",line)
        gsub(/^[ \t]+|[ \t]+$/,"",line); gsub(/^"|"$/,"",line); gsub("^"q"|"q"$","",line)
        if (line != "") print line
      } else if ($0 ~ /^[^ \t#]/) { inlist=0 }
    }' "$CFG"
}
is_placeholder() { [[ "$1" == *"<"*">"* ]]; }   # an unfilled <PLACEHOLDER>

# ── findings + scoring ──────────────────────────────────────────────────────
FIND_SEV=(); FIND_MSG=()
CHECKS_TOTAL=0; CHECKS_PASS=0
add() { FIND_SEV+=("$1"); FIND_MSG+=("$2"); }
pass() { CHECKS_TOTAL=$((CHECKS_TOTAL+1)); CHECKS_PASS=$((CHECKS_PASS+1)); }
fail() { CHECKS_TOTAL=$((CHECKS_TOTAL+1)); add "$1" "$2"; }    # $1=severity $2=message

# require <severity> <ok?> <message-on-fail>  — a present+valid scalar check.
require() { if [[ "$2" -eq 1 ]]; then pass; else fail "$1" "$3"; fi; }

TIER="$(cfg_scalar tier)"
PMODE="$(cfg_scalar permission_mode)"
NAME="$(cfg_scalar name)"
GOAL="$(cfg_scalar goal)"
ESCAL="$(cfg_scalar escalation)"
KILL="$(cfg_scalar kill_switch)"
BUDGET="$(cfg_scalar budget_tokens)"
VERIFY="$(cfg_scalar verify)"
GUARD="$(cfg_scalar guard)"
WORKTREE="$(cfg_scalar worktree)"
LANDVIA="$(cfg_scalar land_via)"
CADENCE="$(cfg_scalar cadence)"
PATTERN="$(cfg_scalar pattern)"

is_l2plus=0; [[ "$TIER" == "L2" || "$TIER" == "L3" ]] && is_l2plus=1

# present-and-not-placeholder predicate
filled() { [[ -n "$1" ]] && ! is_placeholder "$1"; }

# ── always-applicable checks ────────────────────────────────────────────────
require error  "$(filled "$NAME" && echo 1 || echo 0)"  "name: missing or placeholder"
require warning "$(filled "$PATTERN" && echo 1 || echo 0)" "pattern: missing"
case "$TIER" in L1|L2|L3) pass ;; *) fail error "tier: must be L1|L2|L3 (got '${TIER:-empty}')" ;; esac
require warning "$(filled "$CADENCE" && echo 1 || echo 0)" "cadence: missing"
require error  "$(filled "$GOAL" && echo 1 || echo 0)"  "goal: missing or placeholder"
require error  "$(filled "$ESCAL" && echo 1 || echo 0)" "escalation: undefined — every loop must declare what it escalates"
require error  "$(filled "$KILL" && echo 1 || echo 0)"  "kill_switch: undefined — no loop ships without a stop signal"

# budget present + numeric
if [[ -n "$BUDGET" && "$BUDGET" =~ ^[0-9]+$ ]]; then pass; else fail warning "budget_tokens: missing or non-numeric — bound the per-run spend"; fi

# scope present + bounded + not placeholder
mapfile -t SCOPE_ITEMS < <(cfg_list_items scope)
SCOPE_INLINE="$(cfg_scalar scope)"
[[ -n "$SCOPE_INLINE" ]] && SCOPE_ITEMS+=("$SCOPE_INLINE")
if ! cfg_has_key scope || [[ ${#SCOPE_ITEMS[@]} -eq 0 ]]; then
  fail error "scope: missing — bound what the loop may touch"
else
  scope_bad=0
  for it in "${SCOPE_ITEMS[@]}"; do
    if is_placeholder "$it"; then fail error "scope: unfilled placeholder ('$it')"; scope_bad=1; break; fi
    case "$it" in '*'|'**'|'.'|'./'|'/'|'') fail error "scope: unbounded ('$it') — a loop that may touch anything is not bounded"; scope_bad=1; break ;; esac
  done
  [[ "$scope_bad" -eq 0 ]] && pass
fi

# permission_mode present + valid
case "$PMODE" in
  plan|dontAsk|auto|acceptEdits|bypassPermissions) pass ;;
  "") fail error "permission_mode: missing" ;;
  *)  fail error "permission_mode: invalid ('$PMODE')" ;;
esac

# permission_mode consistent with tier (warning)
case "$TIER" in
  L1) case "$PMODE" in plan|dontAsk) pass ;; *) fail warning "permission_mode '$PMODE' is broad for L1 (report-only) — prefer plan or dontAsk" ;; esac ;;
  L2) case "$PMODE" in dontAsk|auto|acceptEdits) pass ;; *) fail warning "permission_mode '$PMODE' fits L2 poorly — prefer dontAsk/auto/acceptEdits" ;; esac ;;
  L3) case "$PMODE" in bypassPermissions) pass ;; *) fail warning "L3 unattended usually needs bypassPermissions in a container (got '$PMODE')" ;; esac ;;
  *)  : ;;
esac

# ── L2+ checks (code-changing tiers) ────────────────────────────────────────
if [[ "$is_l2plus" -eq 1 ]]; then
  require error "$(filled "$VERIFY" && echo 1 || echo 0)" "verify: no gate command — a code-changing loop with no gate is invalid"
  require error "$(filled "$GUARD" && echo 1 || echo 0)"  "guard: no must-always-pass command at $TIER"
  if [[ "$WORKTREE" == "true" ]]; then pass; else fail error "worktree: must be true at $TIER — isolate code changes"; fi
  require warning "$(filled "$LANDVIA" && echo 1 || echo 0)" "land_via: undefined — name who gates+lands (e.g. fleet-ops)"
fi

# ── L3-specific isolation check ─────────────────────────────────────────────
if [[ "$TIER" == "L3" ]]; then
  if printf '%s %s' "$ESCAL" "${SCOPE_ITEMS[*]:-}" | grep -Eqi 'container|isolat|sandbox|devcontainer'; then
    pass
  else
    fail warning "L3 declares no isolation boundary — bypassPermissions is only safe in a container/VM; note it in escalation"
  fi
fi

# ── verdict ─────────────────────────────────────────────────────────────────
ERRORS=0; WARNINGS=0
for s in "${FIND_SEV[@]:-}"; do
  [[ "$s" == "error" ]] && ERRORS=$((ERRORS+1))
  [[ "$s" == "warning" ]] && WARNINGS=$((WARNINGS+1))
done
SCORE=0
[[ "$CHECKS_TOTAL" -gt 0 ]] && SCORE=$(( CHECKS_PASS * 100 / CHECKS_TOTAL ))

READY=1
[[ "$ERRORS" -gt 0 ]] && READY=0
[[ "$SCORE" -lt "$MIN" ]] && READY=0
[[ "$STRICT" -eq 1 && "$WARNINGS" -gt 0 ]] && READY=0

# ── output ──────────────────────────────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
  printf '{\n  "data": [\n'
  for i in "${!FIND_SEV[@]}"; do
    msg="${FIND_MSG[$i]//\\/\\\\}"; msg="${msg//\"/\\\"}"
    sep=","; [[ "$i" -eq $(( ${#FIND_SEV[@]} - 1 )) ]] && sep=""
    printf '    {"severity": "%s", "message": "%s"}%s\n' "${FIND_SEV[$i]}" "$msg" "$sep"
  done
  printf '  ],\n  "meta": {"count": %d, "errors": %d, "warnings": %d, "score": %d, "min": %d, "ready": %s, "tier": "%s", "schema": "claude-mods.loop-ops.check/v1"}\n}\n' \
    "${#FIND_SEV[@]}" "$ERRORS" "$WARNINGS" "$SCORE" "$MIN" "$([[ "$READY" -eq 1 ]] && echo true || echo false)" "${TIER:-unknown}"
else
  if [[ ${#FIND_SEV[@]} -gt 0 ]]; then
    for i in "${!FIND_SEV[@]}"; do
      printf '%-7s %s\n' "$(printf '%s' "${FIND_SEV[$i]}" | tr '[:lower:]' '[:upper:]')" "${FIND_MSG[$i]}"
    done
  fi
  verdict="$([[ "$READY" -eq 1 ]] && echo READY || echo "NOT READY")"
  vstate="$([[ "$READY" -eq 1 ]] && echo ok || echo bad)"
  {
    term_panel_open loop "loop ${TERM_DOT} audit" "${NAME:-$(basename "$(dirname "$CFG")")}"
    term_panel_vert
    term_status_row "$vstate" "$verdict  $(term_pip_bar score "$SCORE" 100)" "score $SCORE/100 ${TERM_DOT} tier ${TIER:-?}"
    term_status_row "$([[ "$ERRORS" -eq 0 ]] && echo ok || echo bad)" "$ERRORS error(s)" "must be 0 to be ready"
    term_status_row "$([[ "$WARNINGS" -eq 0 ]] && echo ok || echo warn)" "$WARNINGS warning(s)" "$([[ "$STRICT" -eq 1 ]] && echo 'block under --strict' || echo advisory)"
    term_panel_vert
    term_panel_close "min $MIN ${TERM_DOT} fix errors before scheduling" ""
  } >&2
fi

[[ "$READY" -eq 1 ]] && exit "$EX_OK" || exit "$EX_FINDINGS"
