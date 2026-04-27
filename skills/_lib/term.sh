#!/usr/bin/env bash
# term.sh — shared terminal-output helpers for claude-mods skills.
#
# Source from any skill script:
#   LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
#   . "$LIB/term.sh"
#   term_init
#
# Honors: NO_COLOR, FORCE_COLOR, TERM_ASCII=1.
# Status: experimental — see docs/DESIGN.md.

# Guard against double-sourcing.
[[ -n "${__TERM_SH_LOADED:-}" ]] && return 0
__TERM_SH_LOADED=1

# Globals populated by term_init.
TERM_TTY=0
TERM_COLOR=0
TERM_ASCII_MODE=0
TERM_WIDTH=80

# State icons (set by term_init based on TERM_ASCII_MODE).
TERM_ICON_PENDING=""
TERM_ICON_READY=""
TERM_ICON_DONE=""
TERM_ICON_FAILED=""
TERM_ICON_WARN=""
TERM_ICON_HINT=""

# ANSI escapes (empty when color disabled).
TERM_C_GREEN=""
TERM_C_YELLOW=""
TERM_C_RED=""
TERM_C_CYAN=""
TERM_C_DIM=""
TERM_C_OFF=""

term_init() {
  # TTY detection — stdout only.
  if [[ -t 1 ]]; then TERM_TTY=1; else TERM_TTY=0; fi

  # ASCII fallback: explicit env, or non-UTF locale.
  if [[ "${TERM_ASCII:-}" == "1" ]] || [[ "${FLEET_ASCII:-}" == "1" ]]; then
    TERM_ASCII_MODE=1
  elif [[ "${LC_ALL:-${LANG:-}}" != *[Uu][Tt][Ff]* ]] && [[ -z "${LC_ALL:-${LANG:-}}" || "${TERM:-}" == "dumb" ]]; then
    TERM_ASCII_MODE=1
  else
    TERM_ASCII_MODE=0
  fi

  # Color: TTY + not NO_COLOR, or FORCE_COLOR overrides.
  if [[ -n "${FORCE_COLOR:-}" ]]; then
    TERM_COLOR=1
  elif [[ -n "${NO_COLOR:-}" ]] || [[ "$TERM_TTY" -eq 0 ]] || [[ "${TERM:-}" == "dumb" ]]; then
    TERM_COLOR=0
  else
    TERM_COLOR=1
  fi

  # Terminal width — fall back to 80.
  if [[ "$TERM_TTY" -eq 1 ]] && command -v tput >/dev/null 2>&1; then
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
  fi
  [[ "$TERM_WIDTH" -lt 40 ]] && TERM_WIDTH=80

  if [[ "$TERM_ASCII_MODE" -eq 1 ]]; then
    TERM_ICON_PENDING="[.]"
    TERM_ICON_READY="[+]"
    TERM_ICON_DONE="[*]"
    TERM_ICON_FAILED="[x]"
    TERM_ICON_WARN="[!]"
    TERM_ICON_HINT="[i]"
    TERM_TREE_BRANCH="+-"
    TERM_TREE_LAST="\`-"
    TERM_TREE_VERT="|"
  else
    TERM_ICON_PENDING="⏳"
    TERM_ICON_READY="✅"
    TERM_ICON_DONE="🚀"
    TERM_ICON_FAILED="❌"
    TERM_ICON_WARN="⚠️ "
    TERM_ICON_HINT="💡"
    TERM_TREE_BRANCH="├─"
    TERM_TREE_LAST="└─"
    TERM_TREE_VERT="│"
  fi

  if [[ "$TERM_COLOR" -eq 1 ]]; then
    TERM_C_GREEN=$'\033[32m'
    TERM_C_YELLOW=$'\033[33m'
    TERM_C_RED=$'\033[31m'
    TERM_C_CYAN=$'\033[36m'
    TERM_C_DIM=$'\033[2m'
    TERM_C_OFF=$'\033[0m'
  else
    TERM_C_GREEN=""; TERM_C_YELLOW=""; TERM_C_RED=""
    TERM_C_CYAN=""; TERM_C_DIM=""; TERM_C_OFF=""
  fi
}

# term_color <name> <text...>  — wrap text in named color (green/yellow/red/cyan/dim).
term_color() {
  local name=$1; shift
  local code=""
  case "$name" in
    green)  code="$TERM_C_GREEN" ;;
    yellow) code="$TERM_C_YELLOW" ;;
    red)    code="$TERM_C_RED" ;;
    cyan)   code="$TERM_C_CYAN" ;;
    dim)    code="$TERM_C_DIM" ;;
  esac
  printf '%s%s%s' "$code" "$*" "$TERM_C_OFF"
}

# term_state_icon <STATE>  — echo glyph for a known state.
term_state_icon() {
  case "$1" in
    RUNNING|PENDING)   printf '%s' "$TERM_ICON_PENDING" ;;
    READY)             printf '%s' "$TERM_ICON_READY" ;;
    LANDED|DONE|OK)    printf '%s' "$TERM_ICON_DONE" ;;
    FAILED|ERROR)      printf '%s' "$TERM_ICON_FAILED" ;;
    CONFLICT|WARN)     printf '%s' "$TERM_ICON_WARN" ;;
    HINT|INFO)         printf '%s' "$TERM_ICON_HINT" ;;
    *)                 printf '%s' "?" ;;
  esac
}

# term_repeat <char> <n>
term_repeat() {
  local ch=$1 n=$2 i out=""
  for (( i=0; i<n; i++ )); do out="$out$ch"; done
  printf '%s' "$out"
}

# term_header <title> [meta]  — "── title ──────  meta"
term_header() {
  local title=$1 meta=${2:-}
  local glyph="─"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && glyph="-"
  local pad=$(( TERM_WIDTH - ${#title} - 6 ))
  [[ $pad -lt 4 ]] && pad=4
  local line
  line="$(term_repeat "$glyph" 2) $(term_color cyan "$title") $(term_repeat "$glyph" "$pad")"
  if [[ -n "$meta" ]]; then
    printf '%s  %s\n' "$line" "$(term_color dim "$meta")"
  else
    printf '%s\n' "$line"
  fi
}

# term_divider [width]  — plain horizontal rule.
term_divider() {
  local w=${1:-$TERM_WIDTH}
  local glyph="─"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && glyph="-"
  printf '%s\n' "$(term_repeat "$glyph" "$w")"
}

# term_tree_item <icon> <label> [meta]  — "  <icon>  label                  meta"
term_tree_item() {
  local icon=$1 label=$2 meta=${3:-}
  if [[ -n "$meta" ]]; then
    printf '  %s  %-32s %s\n' "$icon" "$label" "$(term_color dim "$meta")"
  else
    printf '  %s  %s\n' "$icon" "$label"
  fi
}

# Tree connectors — set by term_init via TERM_ASCII_MODE.
TERM_TREE_BRANCH=""    # ├─  /  +-
TERM_TREE_LAST=""      # └─  /  `-
TERM_TREE_VERT=""      # │   /  |

# term_group_header <icon> <LABEL> <count>  — "  ⏳ RUNNING   (3)"
# Use as the parent line above term_tree_branch / term_tree_last children.
term_group_header() {
  local icon=$1 label=$2 count=$3
  printf '  %s %-9s %s\n' "$icon" "$label" "$(term_color dim "($count)")"
}

# term_tree_branch <label> [meta]  — "    ├─ label                meta"
term_tree_branch() {
  local label=$1 meta=${2:-}
  if [[ -n "$meta" ]]; then
    printf '    %s %-32s %s\n' "$TERM_TREE_BRANCH" "$label" "$(term_color dim "$meta")"
  else
    printf '    %s %s\n' "$TERM_TREE_BRANCH" "$label"
  fi
}

# term_tree_last <label> [meta]  — "    └─ label                meta"
term_tree_last() {
  local label=$1 meta=${2:-}
  if [[ -n "$meta" ]]; then
    printf '    %s %-32s %s\n' "$TERM_TREE_LAST" "$label" "$(term_color dim "$meta")"
  else
    printf '    %s %s\n' "$TERM_TREE_LAST" "$label"
  fi
}

# term_tree_connector <idx> <last_idx>  — echo branch or last, for loops.
term_tree_connector() {
  if [[ "$1" -eq "$2" ]]; then printf '%s' "$TERM_TREE_LAST"
  else printf '%s' "$TERM_TREE_BRANCH"; fi
}

# term_table_row <c1> <c2> <c3>  — fixed-width 3-col row.
term_table_row() {
  printf '  %-2s  %-32s %-10s %s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

# term_empty <message>  — dim italic-ish empty state.
term_empty() {
  printf '  %s\n' "$(term_color dim "($*)")"
}
