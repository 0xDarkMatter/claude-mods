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
#
# Sections, in order (jump with: grep -n '^# ─── ' term.sh):
#   Globals, escapes, connectors, chrome, registries  — state term_init fills
#   term_init · Color helper · Registry lookup · state icons · Checklist mark
#   Primitives
#   Visible width  — every width, pad and cut: cells on UTF-8 bytes, wide table
#   Panel · Body components · Leaf glyph builders · Right-side furniture
#   Spinners · Legacy helpers

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

# Continuation ellipsis (… / ...) — for "sweeping org …" progress lines and the
# truncation marker in term_truncate. Registered rather than authored inline for
# the same reason as TERM_DOT: a literal U+2026 survives TERM_ASCII=1.
TERM_ELLIPSIS=""

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
    TERM_ELLIPSIS="..."
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
    TERM_ELLIPSIS="…"
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

# ─── Visible width (colour is zero-width, wide glyphs are two) ────────────
# Callers hand the layout helpers PRE-COLOURED fragments (term_hotkey,
# term_health, term_pip_bar, term_color output). Both `${#var}` and printf's
# `%-Ns` count every byte of an SGR escape (ESC [ params m) as a column, so a
# coloured panel footer came out short and term_truncate cut ESC[33m in half.
# Hence: every width in this file is measured with __term_vis_width, every
# column is padded with __term_pad, and every cut goes through term_truncate.
# Never `${#x}` or `%-Ns` on text that may carry colour. tests/check-resources.sh
# pins this ("colour is zero-width", "wide glyphs take two cells").
#
# Width means terminal CELLS: one per code point, two for an East Asian Wide or
# Fullwidth one (the ⚡ and 🔁 brands, ✅ ❌ ⏳, CJK). Without that the `fleet
# status` header came out 81 cells to its footer's 80. No grapheme clustering:
# a combining mark, ZWJ or U+FE0F counts one like any code point, so ⚠️ (U+26A0
# U+FE0F) is two cells, as emoji presentation renders in Windows Terminal,
# iTerm2 and kitty.
#
# Counted on UTF-8 BYTES, never the shell's characters (__term_bytes_on): what
# `${#s}` and `${s:i:1}` mean depends on the platform. Linux and macOS bash
# count an astral emoji (🔁) as 1; MSYS bash, whose wchar_t is 16 bits, counts
# it as 2 and `${s:0:1}` returns half its surrogate pair (bytes f0 9f 94), which
# a cut then printed as broken UTF-8; the C locale counts bytes. In bytes, all
# three agree, and term_truncate copies whole sequences.
#
# Fork-free on purpose: these run several times per panel row, and a $(...)
# subshell is a whole process on Windows. The __ forms set a global instead of
# printing; the public wrappers print, for callers that want a value.

# Byte sets for the UTF-8 maths, built once. Bracket expressions take them
# unquoted ([$__TERM_CONT]); they are explicit byte lists, not a-b ranges, so
# no bash version's collation rules come into it. __TERM_HI doubles as the
# lookup table for a byte's value: its offset in the string is value - 0x80.
__TERM_HI=""; __TERM_CONT=""; __TERM_LEAD2=""; __TERM_LEAD3=""; __TERM_LEAD4=""
__term_byte_sets() {
  local i o b
  for (( i=0x80; i<0x100; i++ )); do
    printf -v o '%03o' "$i"; printf -v b "\\$o"
    __TERM_HI="$__TERM_HI$b"
    if   (( i < 0xC0 )); then __TERM_CONT="$__TERM_CONT$b"     # continuation
    elif (( i < 0xE0 )); then __TERM_LEAD2="$__TERM_LEAD2$b"   # 2-byte lead
    elif (( i < 0xF0 )); then __TERM_LEAD3="$__TERM_LEAD3$b"   # 3-byte lead
    elif (( i < 0xF8 )); then __TERM_LEAD4="$__TERM_LEAD4$b"   # 4-byte lead
    fi
  done
  __TERM_LEAD34="$__TERM_LEAD3$__TERM_LEAD4"
  __TERM_STOP=$'\033'"$__TERM_HI"   # where a plain-ASCII run ends
  printf -v __TERM_MB3 '\342\232\241'   # U+26A1 as its 3 bytes: the locale probe
}
__term_byte_sets

# East Asian Width W and F code points as inclusive lo/hi pairs, ascending:
# Unicode 15.0 EastAsianWidth.txt, the table python's unicodedata reports.
# term.ps1's $Script:TermWide is the same list, token for token, and
# tests/check-resources.sh compares the two. Not a block heuristic (all of
# U+2600-27BF, every astral code point): that makes ✓ ✗ ⚠ ⚙ ✶ ⬤ and the 🛡 🏗 🗄
# brands two cells, which terminals draw in one. To regenerate, list every code
# point whose unicodedata.east_asian_width() is W or F, merged into runs.
__TERM_WIDE=(
  0x1100 0x115F  0x231A 0x231B  0x2329 0x232A  0x23E9 0x23EC  0x23F0 0x23F0  0x23F3 0x23F3
  0x25FD 0x25FE  0x2614 0x2615  0x2648 0x2653  0x267F 0x267F  0x2693 0x2693  0x26A1 0x26A1
  0x26AA 0x26AB  0x26BD 0x26BE  0x26C4 0x26C5  0x26CE 0x26CE  0x26D4 0x26D4  0x26EA 0x26EA
  0x26F2 0x26F3  0x26F5 0x26F5  0x26FA 0x26FA  0x26FD 0x26FD  0x2705 0x2705  0x270A 0x270B
  0x2728 0x2728  0x274C 0x274C  0x274E 0x274E  0x2753 0x2755  0x2757 0x2757  0x2795 0x2797
  0x27B0 0x27B0  0x27BF 0x27BF  0x2B1B 0x2B1C  0x2B50 0x2B50  0x2B55 0x2B55  0x2E80 0x2E99
  0x2E9B 0x2EF3  0x2F00 0x2FD5  0x2FF0 0x2FFB  0x3000 0x303E  0x3041 0x3096  0x3099 0x30FF
  0x3105 0x312F  0x3131 0x318E  0x3190 0x31E3  0x31F0 0x321E  0x3220 0x3247  0x3250 0x4DBF
  0x4E00 0xA48C  0xA490 0xA4C6  0xA960 0xA97C  0xAC00 0xD7A3  0xF900 0xFAFF  0xFE10 0xFE19
  0xFE30 0xFE52  0xFE54 0xFE66  0xFE68 0xFE6B  0xFF01 0xFF60  0xFFE0 0xFFE6
  0x16FE0 0x16FE4  0x16FF0 0x16FF1  0x17000 0x187F7  0x18800 0x18CD5  0x18D00 0x18D08
  0x1AFF0 0x1AFF3  0x1AFF5 0x1AFFB  0x1AFFD 0x1AFFE  0x1B000 0x1B122  0x1B132 0x1B132
  0x1B150 0x1B152  0x1B155 0x1B155  0x1B164 0x1B167  0x1B170 0x1B2FB  0x1F004 0x1F004
  0x1F0CF 0x1F0CF  0x1F18E 0x1F18E  0x1F191 0x1F19A  0x1F200 0x1F202  0x1F210 0x1F23B
  0x1F240 0x1F248  0x1F250 0x1F251  0x1F260 0x1F265  0x1F300 0x1F320  0x1F32D 0x1F335
  0x1F337 0x1F37C  0x1F37E 0x1F393  0x1F3A0 0x1F3CA  0x1F3CF 0x1F3D3  0x1F3E0 0x1F3F0
  0x1F3F4 0x1F3F4  0x1F3F8 0x1F43E  0x1F440 0x1F440  0x1F442 0x1F4FC  0x1F4FF 0x1F53D
  0x1F54B 0x1F54E  0x1F550 0x1F567  0x1F57A 0x1F57A  0x1F595 0x1F596  0x1F5A4 0x1F5A4
  0x1F5FB 0x1F64F  0x1F680 0x1F6C5  0x1F6CC 0x1F6CC  0x1F6D0 0x1F6D2  0x1F6D5 0x1F6D7
  0x1F6DC 0x1F6DF  0x1F6EB 0x1F6EC  0x1F6F4 0x1F6FC  0x1F7E0 0x1F7EB  0x1F7F0 0x1F7F0
  0x1F90C 0x1F93A  0x1F93C 0x1F945  0x1F947 0x1F9FF  0x1FA70 0x1FA7C  0x1FA80 0x1FA88
  0x1FA90 0x1FABD  0x1FABF 0x1FAC5  0x1FACE 0x1FADB  0x1FAE0 0x1FAE8  0x1FAF0 0x1FAF8
  0x20000 0x2FFFD  0x30000 0x3FFFD
)

# __term_bytes_on / __term_bytes_off <sw>  — run the width maths on bytes.
# If the live locale is multibyte (the probe is not 3 long), set LC_ALL=C and
# report __TERM_LC_SW=1; the caller keeps that in a local and hands it back to
# __term_bytes_off, which restores LC_ALL as it was (or unsets it). A nested
# call finds bytes already on and does nothing, so only the outermost restores.
# Plain assignment and unset rather than `local LC_ALL`: both re-run setlocale
# in every bash since 2.x. Each ends on a 0 status, safe under set -e.
__TERM_LC_SW=0; __TERM_LC_SAVED=""; __TERM_LC_WASSET=""
__term_bytes_on() {
  __TERM_LC_SW=0
  if [[ ${#__TERM_MB3} -ne 3 ]]; then
    __TERM_LC_SAVED=${LC_ALL-}; __TERM_LC_WASSET=${LC_ALL+1}
    LC_ALL=C; __TERM_LC_SW=1
  fi
}
__term_bytes_off() {
  if [[ ${1:-0} -eq 1 ]]; then
    if [[ -n $__TERM_LC_WASSET ]]; then LC_ALL=$__TERM_LC_SAVED; else unset LC_ALL; fi
  fi
}

# __term_char_cells <one UTF-8 sequence>  — sets __TERM_CELLS to 2 when it
# encodes a code point in __TERM_WIDE, else 1. Bytes on. Only 3- and 4-byte
# sequences can be wide; a malformed one costs 1 or 2, never a crash.
# Answers are memoised in __TERM_SEEN1 / __TERM_SEEN2 (sequences concatenated):
# a panel reuses a handful of glyphs, and one glob test beats the ~15 builtins
# of a lookup on MSYS. A match is always aligned, because a lead byte (E0-F7)
# never occurs inside another sequence.
__TERM_SEEN1=""; __TERM_SEEN2=""
__term_char_cells() {
  local s=$1 v b0 b1 b2 b3=0 cp lo hi mid
  __TERM_CELLS=1
  [[ ${#s} -ge 3 ]] || return 0
  [[ $__TERM_SEEN1 == *"$s"* ]] && return 0
  if [[ $__TERM_SEEN2 == *"$s"* ]]; then __TERM_CELLS=2; return 0; fi
  v=${__TERM_HI%%"${s:0:1}"*}; b0=${#v}      # byte value - 0x80
  v=${__TERM_HI%%"${s:1:1}"*}; b1=${#v}
  v=${__TERM_HI%%"${s:2:1}"*}; b2=${#v}
  if [[ ${#s} -ge 4 ]]; then
    v=${__TERM_HI%%"${s:3:1}"*}; b3=${#v}
    cp=$(( (b0 & 7) << 18 | b1 << 12 | b2 << 6 | b3 ))
  else
    cp=$(( (b0 & 15) << 12 | b1 << 6 | b2 ))
  fi
  lo=0; hi=$(( ${#__TERM_WIDE[@]} / 2 - 1 ))  # binary search over the pairs
  while (( lo <= hi )); do
    mid=$(( (lo + hi) / 2 ))
    if   (( cp < __TERM_WIDE[2 * mid] ));     then hi=$(( mid - 1 ))
    elif (( cp > __TERM_WIDE[2 * mid + 1] )); then lo=$(( mid + 1 ))
    else __TERM_CELLS=2; break; fi
  done
  if [[ $__TERM_CELLS -eq 2 ]]; then __TERM_SEEN2="$__TERM_SEEN2$s"
  else __TERM_SEEN1="$__TERM_SEEN1$s"; fi
}

# __term_strip <text>  — sets __TERM_STRIPPED to <text> minus every CSI escape
# (ESC [ <digits and ;> <final byte>). An escape cut off at the end of the text
# goes whole, and so does a lone ESC with no '['. term.sh itself only emits SGR.
# Callers turn bytes on first, so the final byte is one byte, never half a glyph.
__term_strip() {
  local s=$1 out="" params esc=$'\033'
  while [[ "$s" == *"$esc"* ]]; do
    out="$out${s%%"$esc"*}"
    s=${s#*"$esc"}
    if [[ "$s" == "["* ]]; then
      s=${s:1}
      params=${s%%[!0-9;]*}
      s=${s#"$params"}
      s=${s:1}
    fi
  done
  __TERM_STRIPPED="$out$s"
}

# __term_vis_width <text>  — sets __TERM_VIS_WIDTH to the cells <text> fills:
# one per code point (bytes that are not continuation bytes), plus one for each
# wide one. Only 3- and 4-byte sequences are looked up. Text with no byte above
# 0x7F is cells == bytes == characters in every locale, so it skips the locale
# switch (setlocale is slow on MSYS) and stays as cheap as before.
__term_vis_width() {
  local sw r pre seq w
  if [[ $1 != *[$__TERM_HI]* ]]; then
    __term_strip "$1"; __TERM_VIS_WIDTH=${#__TERM_STRIPPED}; return 0
  fi
  __term_bytes_on; sw=$__TERM_LC_SW
  __term_strip "$1"
  r=$__TERM_STRIPPED
  pre=${r//[$__TERM_CONT]/}; w=${#pre}
  while [[ $r == *[$__TERM_LEAD34]* ]]; do
    pre=${r%%[$__TERM_LEAD34]*}; r=${r:${#pre}}
    case ${r:0:1} in [$__TERM_LEAD4]) seq=${r:0:4} ;; *) seq=${r:0:3} ;; esac
    r=${r:${#seq}}
    __term_char_cells "$seq"; w=$(( w + __TERM_CELLS - 1 ))
  done
  __TERM_VIS_WIDTH=$w
  __term_bytes_off "$sw"
}

# __term_pad <text> <cols>  — sets __TERM_PADDED to <text> right-padded with
# spaces to <cols> visible columns. Never truncates: wider text comes back as-is.
__term_pad() {
  __term_vis_width "$1"
  local gap=$(( $2 - __TERM_VIS_WIDTH ))
  [[ $gap -lt 0 ]] && gap=0
  printf -v __TERM_PADDED '%s%*s' "$1" "$gap" ''
}

# term_strip <text>  — <text> with colour escapes removed.
term_strip() {
  local sw; __term_bytes_on; sw=$__TERM_LC_SW
  __term_strip "$1"
  __term_bytes_off "$sw"
  printf '%s' "$__TERM_STRIPPED"
}

# term_vis_width <text>  — visible cells of <text> (colour 0, wide glyphs 2).
term_vis_width() { __term_vis_width "$1"; printf '%s' "$__TERM_VIS_WIDTH"; }

# term_pad <text> <cols>  — <text> padded to <cols> visible columns. Use it, not
# printf %-Ns, for any column that may hold colour or multibyte glyphs.
term_pad() { __term_pad "$1" "$2"; printf '%s' "$__TERM_PADDED"; }

# term_truncate <text> <max_cols>  — ellipsis-truncate to <max_cols> VISIBLE
# cells, appending "…" or "..". Escapes are zero-width and copied whole, so a
# cut never lands inside one; if any were copied, a reset (ESC[0m) precedes the
# marker so the cut cannot leave the terminal mid-colour. Characters are copied
# whole too: a wide glyph that would straddle the limit is left out, so the
# result can be one cell short of <max_cols> (callers pad with __term_pad).
term_truncate() {
  local text=$1 max=$2 sw=0 ell="" keep s out run params n esc=$'\033' coloured=0
  if [[ $text == *[$__TERM_HI]* ]]; then __term_bytes_on; sw=$__TERM_LC_SW; fi
  __term_vis_width "$text"
  if [[ $__TERM_VIS_WIDTH -le $max ]]; then
    out=$text
  else
    # Registered glyph, not a literal — TERM_ASCII=1 must swap it. The ASCII
    # marker stays two dots (not $TERM_ELLIPSIS's three): it is the truncation
    # cue, and a third dot would eat another column of the name it shortens.
    ell="$TERM_ELLIPSIS"
    [[ "$TERM_ASCII_MODE" -eq 1 ]] && ell=".."
    __term_vis_width "$ell"; keep=$(( max - __TERM_VIS_WIDTH ))
    [[ $keep -lt 0 ]] && keep=0
    s=$text out=""
    while [[ $keep -gt 0 && -n "$s" ]]; do
      if [[ "$s" == "$esc["* ]]; then
        s=${s:2}; params=${s%%[!0-9;]*}; s=${s#"$params"}
        out="$out$esc[$params${s:0:1}"; s=${s:1}; coloured=1
      elif [[ "$s" == "$esc"* ]]; then
        s=${s:1}                      # lone ESC: zero columns, dropped as in __term_strip
      else
        run=${s%%[$__TERM_STOP]*}     # plain ASCII up to the next escape or glyph
        if [[ -n "$run" ]]; then
          [[ ${#run} -gt $keep ]] && run=${run:0:$keep}
          out="$out$run"; s=${s:${#run}}; keep=$(( keep - ${#run} ))
        else                          # one multibyte character: whole, or not at all
          case ${s:0:1} in
            [$__TERM_LEAD4]) n=4 ;; [$__TERM_LEAD3]) n=3 ;; [$__TERM_LEAD2]) n=2 ;; *) n=1 ;;
          esac
          run=${s:0:$n}
          __term_char_cells "$run"
          case $run in [$__TERM_CONT]) __TERM_CELLS=0 ;; esac   # stray continuation byte
          [[ $__TERM_CELLS -gt $keep ]] && break
          out="$out$run"; s=${s:$n}; keep=$(( keep - __TERM_CELLS ))
        fi
      fi
    done
    # $TERM_C_OFF's colour-on value as a literal: the escapes came from the
    # caller, so the reset is needed whatever TERM_COLOR says.
    [[ $coloured -eq 1 ]] && out="$out"$'\033[0m'
  fi
  __term_bytes_off "$sw"
  printf '%s%s' "$out" "$ell"
}

# ─── Panel ────────────────────────────────────────────────────────────────

# __term_panel_bar <left> <right>  — print <left>, a cyan rule filling the rest
# of TERM_WIDTH, then <right>. Both widths come from the RENDERED strings with
# colour stripped, never from a hand-kept uncoloured twin: the footer once kept
# such a twin, filled it with its callers' pre-coloured hotkeys and healths, and
# came out short whenever colour was on (62 of 80 cells in `fleet status`).
__term_panel_bar() {
  local lw
  __term_vis_width "$1"; lw=$__TERM_VIS_WIDTH
  __term_vis_width "$2"
  local fill=$(( TERM_WIDTH - lw - __TERM_VIS_WIDTH ))
  [[ $fill -lt 4 ]] && fill=4
  printf '%s%s%s\n' "$1" "$(term_color cyan "$(term_repeat "$TERM_PANEL_HRULE" "$fill")")" "$2"
}

# term_panel_open <emoji_key> <name> [right_indicator]
#   ╭── ⚡ name ─────────  <indicator> ───●
term_panel_open() {
  local key=$1 name=$2 indicator=${3:-}
  local emoji
  emoji=$(term_brand_glyph "$key")
  local left="${TERM_PANEL_TL}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE} ${emoji} $(term_color cyan "$name") "
  local right="${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}$(term_color cyan "$TERM_PANEL_TERM")"
  [[ -n "$indicator" ]] && right=" $(term_color dim "$indicator") ${right}"
  __term_panel_bar "$left" "$right"
}

# term_panel_close [hotkeys] [health_indicators]
#   ╰── R refresh · L land · ? help ───── • daemon  • 17m ───●
# `hotkeys`: pre-formatted "R refresh · L land · ? help" string.
# `healths`: pre-formatted "• daemon  • 17m" string.
# Both may carry colour (term_hotkey, term_health): it is measured as zero-width.
term_panel_close() {
  local hotkeys=${1:-} healths=${2:-}
  local left="${TERM_PANEL_BL}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE} ${hotkeys} "
  local right="${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}${TERM_PANEL_HRULE}$(term_color cyan "$TERM_PANEL_TERM")"
  [[ -n "$healths" ]] && right=" ${healths} ${right}"
  __term_panel_bar "$left" "$right"
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
# Columns are padded on visible width: `leaf` is a coloured rail or pip bar, and
# printf %-14s counted its escape and multibyte bytes, so the meta/age columns
# wandered with the commit count (docs/TERMINAL-DESIGN.md §3.3 grid).
term_leaf_line() {
  local conn=$1 name=$2 leaf=$3 meta=${4:-} age=${5:-}
  local name_col leaf_col
  __term_pad "$(term_truncate "$name" 28)" 28; name_col=$__TERM_PADDED
  __term_pad "$leaf" 14; leaf_col=$__TERM_PADDED
  __term_pad "$(term_color dim "$meta")" 10
  printf '%s   %s %s  %s %s %s\n' \
    "$(term_color dim "$TERM_TREE_VERT")" \
    "$(term_color dim "$conn$TERM_PANEL_HRULE")" \
    "$name_col" \
    "$leaf_col" \
    "$__TERM_PADDED" \
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
# `label` may carry colour (loop-check puts a coloured pip bar in it): it is cut
# and padded on visible columns, so the value column stays put either way.
term_status_row() {
  local mark label value
  mark="$(term_mark "$1")"; label=$2; value=${3:-}
  if [[ -n "$value" ]]; then
    __term_pad "$(term_truncate "$label" 30)" 30
    printf '%s   %s  %s %s\n' \
      "$(term_color dim "$TERM_TREE_VERT")" "$mark" "$__TERM_PADDED" \
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
# term_tree_item, term_tree_node and term_table_row keep their printf %-Ns
# columns, so they align PLAIN text only; pass colour in their last argument.
# Left alone because nothing in this repo calls them and term_table_row's icon
# column relies on byte padding happening to give a wide emoji its 2 cells.

# term_header <title> [meta]  — "── title ──────  meta" (legacy)
term_header() {
  local title=$1 meta=${2:-}
  local glyph="─"; [[ "$TERM_ASCII_MODE" -eq 1 ]] && glyph="-"
  __term_vis_width "$title"
  local pad=$(( TERM_WIDTH - __TERM_VIS_WIDTH - 6 ))
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
