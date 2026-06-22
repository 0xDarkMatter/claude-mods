#!/usr/bin/env bash
# term.sh — terminal panel design system for claude-mods skills.
#
# Source from any skill script:
#   LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" && pwd)"
#   . "$LIB/term.sh"
#   term_init          # detect on stdout (panels printed to stdout)
#   term_init 2        # detect on stderr (stream-separated tools: data→stdout,
#                      #                    framing→stderr — color follows fd 2)
#
# Honors: NO_COLOR, FORCE_COLOR, TERM_ASCII=1, FLEET_ASCII=1 (legacy).
# See docs/TERMINAL-DESIGN.md for the design system this implements.

# Guard against double-sourcing.
[[ -n "${__TERM_SH_LOADED:-}" ]] && return 0
__TERM_SH_LOADED=1

# ─── Globals (populated by term_init) ──────────────────────────────────────
TERM_TTY=0
TERM_COLOR=0
TERM_ASCII_MODE=0
TERM_WIDTH=80

# ─── ANSI escapes (empty when color disabled) ─────────────────────────────
TERM_C_GREEN=""
TERM_C_YELLOW=""
TERM_C_ORANGE=""
TERM_C_RED=""
TERM_C_CYAN=""
TERM_C_MAGENTA=""
TERM_C_DIM=""
TERM_C_OFF=""

# ─── Tree connectors (set by term_init based on TERM_ASCII_MODE) ──────────
TERM_TREE_BRANCH=""    # ├─  /  +-
TERM_TREE_LAST=""      # └─  /  `-
TERM_TREE_VERT=""      # │   /  |

# ─── Panel chrome ─────────────────────────────────────────────────────────
TERM_PANEL_TL=""       # ╭   /  +
TERM_PANEL_BL=""       # ╰   /  +
TERM_PANEL_HRULE=""    # ─   /  -
TERM_PANEL_TERM=""     # ●   /  *

# ─── Legacy state icons (kept for backwards-compat with fleet.sh) ─────────
TERM_ICON_PENDING=""
TERM_ICON_READY=""
TERM_ICON_DONE=""
TERM_ICON_FAILED=""
TERM_ICON_WARN=""
TERM_ICON_HINT=""

# ─── Registries (Unicode|ASCII) ───────────────────────────────────────────
# Implemented as case statements in __term_lookup below (bash 3.2 compatible —
# stock macOS bash lacks associative arrays).

# Header indicator glyph (branch/⎇)
TERM_GLYPH_BRANCH=""

# Inline alert glyph (▲)
TERM_GLYPH_ALERT=""

# Empty-state tip glyph (💡)
TERM_GLYPH_TIP=""

# Pointer/arrow glyph (→ / ->) — for "problem → remedy" leads.
TERM_ARROW=""

# Soft separator (· / |) — for joining hotkeys/labels ("R refresh · L land").
# ASCII-safe so authored footer/summary strings stay pure under TERM_ASCII=1.
TERM_DOT=""

# Spinner frame banks (set by term_init; arrays keep order).
TERM_SPIN_WORKING=()
TERM_SPIN_HEARTBEAT=()

# ─── term_init ────────────────────────────────────────────────────────────
term_init() {
  # TTY/color detection follows the chosen fd (default 1 = stdout). Stream-separated
  # tools that print framing to stderr should call `term_init 2` so color tracks the
  # stream the human actually sees, even when stdout is piped to jq.
  local fd=${1:-1}
  if [[ -t "$fd" ]]; then TERM_TTY=1; else TERM_TTY=0; fi

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
    TERM_PANEL_TL="+"
    TERM_PANEL_BL="+"
    TERM_PANEL_HRULE="-"
    TERM_PANEL_TERM="*"
    TERM_GLYPH_BRANCH="(b)"
    TERM_GLYPH_ALERT="!"
    TERM_GLYPH_TIP="(i)"
    TERM_ARROW="->"
    TERM_DOT="|"
    TERM_SPIN_WORKING=('|' '/' '-' '\')
    TERM_SPIN_HEARTBEAT=('.' ':' '*' ':')
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
    TERM_PANEL_TL="╭"
    TERM_PANEL_BL="╰"
    TERM_PANEL_HRULE="─"
    TERM_PANEL_TERM="●"
    TERM_GLYPH_BRANCH="⎇"
    TERM_GLYPH_ALERT="▲"
    TERM_GLYPH_TIP="💡"
    TERM_ARROW="→"
    TERM_DOT="·"
    TERM_SPIN_WORKING=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    TERM_SPIN_HEARTBEAT=('·' '∙' '•' '●' '•' '∙')
  fi

  if [[ "$TERM_COLOR" -eq 1 ]]; then
    TERM_C_GREEN=$'\033[32m'
    TERM_C_YELLOW=$'\033[33m'
    TERM_C_ORANGE=$'\033[38;5;208m'
    TERM_C_RED=$'\033[31m'
    TERM_C_CYAN=$'\033[36m'
    TERM_C_MAGENTA=$'\033[35m'
    TERM_C_DIM=$'\033[2m'
    TERM_C_OFF=$'\033[0m'
  else
    TERM_C_GREEN=""; TERM_C_YELLOW=""; TERM_C_ORANGE=""
    TERM_C_RED=""; TERM_C_CYAN=""; TERM_C_MAGENTA=""
    TERM_C_DIM=""; TERM_C_OFF=""
  fi
}

# ─── Color helper ─────────────────────────────────────────────────────────
# term_color <name> <text...>
term_color() {
  local name=$1; shift
  local code=""
  case "$name" in
    green)   code="$TERM_C_GREEN" ;;
    yellow)  code="$TERM_C_YELLOW" ;;
    orange)  code="$TERM_C_ORANGE" ;;
    red)     code="$TERM_C_RED" ;;
    cyan)    code="$TERM_C_CYAN" ;;
    magenta) code="$TERM_C_MAGENTA" ;;
    dim)     code="$TERM_C_DIM" ;;
  esac
  printf '%s%s%s' "$code" "$*" "$TERM_C_OFF"
}

# ─── Registry lookup ──────────────────────────────────────────────────────
# term_emoji <registry_name> <key>  — returns Unicode glyph or ASCII fallback.
# Internal helper; pass "BRAND", "HEALTH_GLYPH", "DIAGRAM_ICON".
__term_lookup() {
  local map=$1 key=$2 entry="" uni ascii
  case "${map}::${key}" in
    BRAND::fleet)               entry="⚡|[F]" ;;
    BRAND::forge)               entry="🔨|[B]" ;;
    BRAND::psql)                entry="🐘|[P]" ;;
    BRAND::watch)               entry="📡|[M]" ;;
    BRAND::deploy)              entry="🚀|[D]" ;;
    BRAND::git)                 entry="🌿|[G]" ;;
    BRAND::windows-ops)         entry="🩺|[H]" ;;
    BRAND::mac-ops)             entry="🩺|[M]" ;;
    BRAND::github-ops)          entry="🐙|[G]" ;;
    BRAND::audit)               entry="🔎|[A]" ;;
    BRAND::supply-chain)        entry="🛡|[S]" ;;
    BRAND::net-ops)             entry="📡|[N]" ;;
    BRAND::adr)                 entry="📒|[A]" ;;
    BRAND::loop)                entry="🔁|[L]" ;;
    BRAND::terraform)           entry="🏗|[T]" ;;
    BRAND::claude)              entry="✶|[C]" ;;
    BRAND::play)                entry="🎭|[P]" ;;
    HEALTH_GLYPH::healthy)      entry="•|(+)" ;;
    HEALTH_GLYPH::pending)      entry="•|(.)" ;;
    HEALTH_GLYPH::warning)      entry="•|(!)" ;;
    HEALTH_GLYPH::critical)     entry="•|(!!)" ;;
    HEALTH_GLYPH::alarm)        entry="•|(!!)" ;;
    HEALTH_GLYPH::busted)       entry="⬤|(X)" ;;
    HEALTH_GLYPH::unknown)      entry="•|(?)" ;;
    DIAGRAM_ICON::user)         entry="👤|(U)" ;;
    DIAGRAM_ICON::web)          entry="🌐|(W)" ;;
    DIAGRAM_ICON::mobile)       entry="📱|(M)" ;;
    DIAGRAM_ICON::auth)         entry="🔐|(A)" ;;
    DIAGRAM_ICON::database)     entry="🗄|(D)" ;;
    DIAGRAM_ICON::cache)        entry="⚡|(C)" ;;
    DIAGRAM_ICON::queue)        entry="📨|(Q)" ;;
    DIAGRAM_ICON::storage)      entry="📦|(P)" ;;
    DIAGRAM_ICON::service)      entry="⚙|*" ;;
    DIAGRAM_ICON::api)          entry="🔌|(I)" ;;
    DIAGRAM_ICON::search)       entry="🔍|(S)" ;;
    DIAGRAM_ICON::timer)        entry="⏱|(T)" ;;
    DIAGRAM_ICON::build)        entry="🔨|(B)" ;;
    DIAGRAM_ICON::hook)         entry="🪝|(H)" ;;
    DIAGRAM_ICON::log)          entry="📄|(F)" ;;
  esac
  [[ -z "$entry" ]] && { printf '%s' "?"; return; }
  uni="${entry%|*}"
  ascii="${entry#*|}"
  if [[ "$TERM_ASCII_MODE" -eq 1 ]]; then printf '%s' "$ascii"
  else printf '%s' "$uni"; fi
}

term_brand_glyph()    { __term_lookup BRAND        "$1"; }
term_health_glyph()   { __term_lookup HEALTH_GLYPH "$1"; }
term_diagram_icon()   { __term_lookup DIAGRAM_ICON "$1"; }

# ─── Legacy state-icon helper (used by fleet.sh) ──────────────────────────
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

# ─── Checklist mark ───────────────────────────────────────────────────────
# term_mark <state>  — compact single-glyph status mark, colored + ASCII-aware.
# The lightweight checklist counterpart to the emoji-heavy term_state_icon: use
# it for ✓/✗ audit rows. Every glyph has a registered ASCII fallback (TERM_ASCII=1).
#   ok ✓/+ green · bad|gap ✗/x red · warn ▲/! orange · skip|na —/- dim · unknown ?/? yellow
term_mark() {
  local g c
  case "$1" in
    ok)        g="✓"; c="green" ;;
    bad|gap)   g="✗"; c="red" ;;
    warn)      g="▲"; c="orange" ;;
    skip|na)   g="—"; c="dim" ;;
    unknown)   g="?"; c="yellow" ;;
    *)         g="·"; c="" ;;
  esac
  if [[ "$TERM_ASCII_MODE" -eq 1 ]]; then
    case "$1" in
      ok) g="+" ;; bad|gap) g="x" ;; warn) g="!" ;; skip|na) g="-" ;; unknown) g="?" ;; *) g="." ;;
    esac
  fi
  if [[ -n "$c" ]]; then term_color "$c" "$g"; else printf '%s' "$g"; fi
}

# ─── Primitives ───────────────────────────────────────────────────────────

# term_repeat <char> <n>
term_repeat() {
  local ch=$1 n=$2 i out=""
  for (( i=0; i<n; i++ )); do out="$out$ch"; done
  printf '%s' "$out"
}

# term_truncate <text> <max_cols>  — ellipsis-truncate, append "…" or "..".
term_truncate() {
  local text=$1 max=$2
  local len=${#text}
  if [[ $len -le $max ]]; then printf '%s' "$text"; return; fi
  local ell="…"
  [[ "$TERM_ASCII_MODE" -eq 1 ]] && ell=".."
  local elllen=${#ell}
  printf '%s%s' "${text:0:$((max - elllen))}" "$ell"
}

# ─── Panel ────────────────────────────────────────────────────────────────

# term_panel_open <emoji_key> <name> [right_indicator]
#   ╭── ⚡ name ─────────  <indicator> ───●
term_panel_open() {
  local key=$1 name=$2 indicator=${3:-}
  local emoji
  emoji=$(term_brand_glyph "$key")
  local left="${TERM_PANEL_TL}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE} ${emoji} $(term_color cyan "$name") "
  local right=""
  if [[ -n "$indicator" ]]; then
    right=" $(term_color dim "$indicator") ${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}$(term_color cyan "$TERM_PANEL_TERM")"
  else
    right="${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}$(term_color cyan "$TERM_PANEL_TERM")"
  fi

  # Visible (color-stripped) widths to size the rule fill correctly.
  local left_vis="${TERM_PANEL_TL}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE} ${emoji} ${name} "
  local right_vis=""
  [[ -n "$indicator" ]] && right_vis=" ${indicator} ${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_TERM}" \
                       || right_vis="${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_TERM}"

  local fill=$(( TERM_WIDTH - ${#left_vis} - ${#right_vis} ))
  [[ $fill -lt 4 ]] && fill=4
  local rule
  rule=$(term_repeat "$TERM_PANEL_HRULE" "$fill")
  printf '%s%s%s\n' "$left" "$(term_color cyan "$rule")" "$right"
}

# term_panel_close [hotkeys] [health_indicators]
#   ╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
# `hotkeys`: pre-formatted "R refresh · L land · ? help" string.
# `healths`: pre-formatted "• daemon  • 17m" string.
term_panel_close() {
  local hotkeys=${1:-} healths=${2:-}
  local left="${TERM_PANEL_BL}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE} ${hotkeys} "
  local right=""
  if [[ -n "$healths" ]]; then
    right=" ${healths} ${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}$(term_color cyan "$TERM_PANEL_TERM")"
  else
    right="${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}$(term_color cyan "$TERM_PANEL_TERM")"
  fi

  local left_vis="${TERM_PANEL_BL}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE} ${hotkeys} "
  local right_vis=""
  [[ -n "$healths" ]] && right_vis=" ${healths} ${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_TERM}" \
                     || right_vis="${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_TERM}"

  local fill=$(( TERM_WIDTH - ${#left_vis} - ${#right_vis} ))
  [[ $fill -lt 4 ]] && fill=4
  local rule
  rule=$(term_repeat "$TERM_PANEL_HRULE" "$fill")
  printf '%s%s%s\n' "$left" "$(term_color cyan "$rule")" "$right"
}

# term_panel_vert  — emit a single body-line spacer "│"
term_panel_vert() {
  printf '%s\n' "$(term_color dim "$TERM_TREE_VERT")"
}

# term_panel_line <text>  — a generic body row on the rail:  │   <text>
# The fleet-specific term_leaf_line is shaped for branch + commit-rail + age; this
# is the open-ended counterpart for any panel body. `text` may already carry colored
# marks (term_mark / term_color) — it is printed verbatim so the caller owns styling.
term_panel_line() {
  printf '%s   %s\n' "$(term_color dim "$TERM_TREE_VERT")" "$*"
}

# ─── Body components ──────────────────────────────────────────────────────

# term_section <state> <label> <count>
#   ├── LABEL (n)   (label colored by state)
term_section() {
  local state=$1 label=$2 count=$3
  local color=""
  case "$state" in
    RUNNING|PENDING|CONFLICT|WARN|warning) color="yellow" ;;
    READY|LANDED|DONE|OK|healthy)          color="green" ;;
    FAILED|ERROR|critical|alarm)           color="red" ;;
    *)                                     color="" ;;
  esac
  local rendered_label="$label"
  [[ -n "$color" ]] && rendered_label=$(term_color "$color" "$label")
  printf '%s%s %s %s\n' \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
    "$rendered_label" \
    "$(term_color dim "($count)")"
}

# term_summary_line <text>  — dim metadata branch
#   ├── text
term_summary_line() {
  printf '%s%s %s\n' \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
    "$(term_color dim "$*")"
}

# term_leaf_line <connector> <name> <leaf_glyph> <meta> <age>
#   │   ├── name              ●─●─●─◉    M4 ?1   12m
# `connector` = ├── or └──
term_leaf_line() {
  local conn=$1 name=$2 leaf=$3 meta=${4:-} age=${5:-}
  local trunc_name
  trunc_name=$(term_truncate "$name" 28)
  printf '%s   %s %-28s  %-14s %-10s %s\n' \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color dim "$conn$TERM_PANEL_HRULE")" \
    "$trunc_name" \
    "$leaf" \
    "$(term_color dim "$meta")" \
    "$(term_color dim "$age")"
}

# term_toast <emoji_key> <text>  — ├── ⚡ text   (dim cyan)
term_toast() {
  local key=$1; shift
  local emoji
  emoji=$(term_brand_glyph "$key")
  printf '%s%s %s\n' \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color dim "$TERM_TREE_BRANCH$TERM_PANEL_HRULE")" \
    "$(term_color cyan "$emoji $*")"
}

# term_status_row <mark_state> <label> [value]  — §5.3 status-panel checklist row
#   │   ✓  label                          value
# The no-tree counterpart to term_leaf_line: a flat row riding the panel rail,
# led by a term_mark glyph (ok/bad/warn/skip/na/unknown). `value` is dim, right of
# the label column. Use inside a status panel (a PR's checks, a health summary).
term_status_row() {
  local mark label value
  mark="$(term_mark "$1")"; label=$2; value=${3:-}
  if [[ -n "$value" ]]; then
    printf '%s   %s  %-30s %s\n' \
      "$(term_color dim "$TERM_TREE_VERT")" "$mark" "$(term_truncate "$label" 30)" \
      "$(term_color dim "$value")"
  else
    printf '%s   %s  %s\n' \
      "$(term_color dim "$TERM_TREE_VERT")" "$mark" "$label"
  fi
}

# term_alert <severity> <text>  — ▲ message (orange/red), as a sub-row
# `severity` = warning | critical
term_alert() {
  local sev=$1; shift
  local color="orange"
  [[ "$sev" == "critical" ]] && color="red"
  printf '%s   %s %s %s\n' \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color "$color" "$TERM_GLYPH_ALERT")" \
    "$*"
}

# ─── Leaf glyph builders ──────────────────────────────────────────────────

# term_rail <commits_ahead> <head_state>
#   head_state: HEAD | CONFLICT | EMPTY
# Examples:
#   term_rail 3 HEAD     → ●─●─●─◉
#   term_rail 4 HEAD     → ●─●─●─●─◉
#   term_rail 1 HEAD     → ●─◉
#   term_rail 3 CONFLICT → ●─●─⊗
#   term_rail 0 EMPTY    → ─
term_rail() {
  local n=$1 head=${2:-HEAD}
  local commit="●"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && commit="*"
  local link="─";   [[ "$TERM_ASCII_MODE" -eq 1 ]] && link="-"
  local headg="◉";  [[ "$TERM_ASCII_MODE" -eq 1 ]] && headg="@"
  local conflict="⊗"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && conflict="X"

  if [[ $n -le 0 && "$head" == "EMPTY" ]]; then printf '%s' "$link"; return; fi

  local out=""
  local i
  # n landed commits, joined by links
  for (( i=0; i<n-1; i++ )); do
    out="${out}$(term_color green "$commit")${link}"
  done

  # final glyph
  case "$head" in
    HEAD)
      if [[ $n -ge 1 ]]; then out="${out}$(term_color green "$commit")${link}"; fi
      out="${out}$(term_color yellow "$headg")"
      ;;
    CONFLICT)
      if [[ $n -ge 1 ]]; then out="${out}$(term_color green "$commit")${link}"; fi
      out="${out}$(term_color red "$conflict")"
      ;;
    *)
      [[ $n -ge 1 ]] && out="${out}$(term_color green "$commit")"
      ;;
  esac
  printf '%s' "$out"
}

# term_pip_bar <metric_type> <filled> <total>
#   metric_type: progress | score | capacity
#   filled / total are integers (e.g., 30, 100)
term_pip_bar() {
  local kind=$1 filled=$2 total=$3
  local pip_full="▰"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && pip_full="#"
  local pip_empty="▱"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && pip_empty="-"
  local width=10
  [[ "$total" -ne 100 && "$total" -gt 0 && "$total" -le 12 ]] && width=$total

  # Pip count
  local pips
  if [[ "$total" -eq 100 ]]; then
    pips=$(( filled / 10 ))
  else
    pips=$filled
  fi
  [[ $pips -lt 0 ]] && pips=0
  [[ $pips -gt $width ]] && pips=$width

  # Color selection
  local color="green"
  local pct=$(( total > 0 ? filled * 100 / total : 0 ))
  case "$kind" in
    progress) color="yellow"; [[ $pct -ge 100 ]] && color="green" ;;
    score)    if   [[ $pct -lt 33 ]]; then color="red"
              elif [[ $pct -lt 66 ]]; then color="yellow"
              else color="green"; fi ;;
    capacity) if   [[ $pct -ge 80 ]]; then color="red"
              elif [[ $pct -ge 60 ]]; then color="yellow"
              else color="green"; fi ;;
  esac

  local i out=""
  for (( i=0; i<pips; i++ )); do out="${out}$(term_color "$color" "$pip_full")"; done
  for (( i=pips; i<width; i++ )); do out="${out}$(term_color dim "$pip_empty")"; done
  printf '%s' "$out"
}

# ─── Right-side furniture ─────────────────────────────────────────────────

# term_health <state> <text>  — • text (colored bullet, with ⬤ for busted)
# state: healthy|pending|warning|critical|busted|unknown
term_health() {
  local state=$1; shift
  local glyph
  glyph=$(term_health_glyph "$state")
  local color=""
  case "$state" in
    healthy)  color="green" ;;
    pending)  color="yellow" ;;
    warning)  color="orange" ;;
    critical) color="red" ;;
    busted)   color="dim" ;;
    *)        color="dim" ;;
  esac
  printf '%s %s' "$(term_color "$color" "$glyph")" "$*"
}

# term_hotkey <key> <verb>  — "R refresh"  (key in cyan)
term_hotkey() {
  printf '%s %s' "$(term_color cyan "$1")" "$2"
}

# ─── Spinners (live mode) ─────────────────────────────────────────────────

# term_spinner_frame <family> <tick>  — return frame at `tick % frames`.
# family: working | heartbeat
term_spinner_frame() {
  local fam=$1 tick=$2
  local -a frames
  case "$fam" in
    working)   frames=("${TERM_SPIN_WORKING[@]}") ;;
    heartbeat) frames=("${TERM_SPIN_HEARTBEAT[@]}") ;;
    *)         printf '?'; return ;;
  esac
  local n=${#frames[@]}
  printf '%s' "${frames[$(( tick % n ))]}"
}

# ─── Legacy / kept-for-compat helpers (used by older scripts) ─────────────

# term_header <title> [meta]  — "── title ──────  meta" (legacy)
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

term_divider() {
  local w=${1:-$TERM_WIDTH}
  local glyph="─"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && glyph="-"
  printf '%s\n' "$(term_repeat "$glyph" "$w")"
}

term_tree_item() {
  local icon=$1 label=$2 meta=${3:-}
  if [[ -n "$meta" ]]; then
    printf '  %s  %-32s %s\n' "$icon" "$label" "$(term_color dim "$meta")"
  else
    printf '  %s  %s\n' "$icon" "$label"
  fi
}

term_tree_connector() {
  if [[ "$1" -eq "$2" ]]; then printf '%s' "$TERM_TREE_LAST"
  else printf '%s' "$TERM_TREE_BRANCH"; fi
}

term_tree_indent() {
  if [[ "$1" -eq 1 ]]; then printf '   '
  else printf '%s  ' "$TERM_TREE_VERT"; fi
}

term_tree_node() {
  local prefix=$1 conn=$2 label=$3 meta=${4:-}
  if [[ -n "$meta" ]]; then
    printf '%s%s %-32s %s\n' "$prefix" "$conn" "$label" "$(term_color dim "$meta")"
  else
    printf '%s%s %s\n' "$prefix" "$conn" "$label"
  fi
}

term_table_row() {
  printf '  %-2s  %-32s %-10s %s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

term_empty() {
  printf '  %s\n' "$(term_color dim "($*)")"
}
