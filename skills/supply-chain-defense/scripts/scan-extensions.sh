#!/usr/bin/env bash
# Inventory, recency, and (optional) behavioural scan of installed editor
# extensions, Claude Code plugins, and skills — the "what's on this machine, what
# changed recently, and is any of it malicious?" audit.
#
# DEFAULT (zero-dependency): lists every installed editor extension, Claude plugin,
#   and skill with its version + whether it changed within the recency window. The
#   2026 campaign exploits exactly the gap this closes — fresh malicious versions
#   live for minutes (Nx Console: 11 min) and most teams have no inventory. This
#   mode has NO false positives; it is an inventory, not a verdict.
#
# --deep (auto-detects guarddog + semgrep): runs GuardDog's AST/semgrep behavioural
#   rules against editor extensions changed within the window (or --all) — the real
#   "unknown bad" engine. If the engine is NOT installed it does NOT pretend: it runs
#   inventory + recency, then LOUDLY reports that the behavioural scan was skipped and
#   recommends `uv tool install guarddog semgrep` (on-demand — kept off the machine by
#   default to stay lean). It never reports "clean" for a scan it didn't run.
#   Note: extension bundles are minified, so even AST scanning is best-effort here;
#   inventory + recency + IOC (exposure-check.py) remain the backbone for extensions.
#
# Usage:   scan-extensions.sh [--json] [--days N]              # inventory + recency
#          scan-extensions.sh --deep [--all] [--days N]        # behavioural (needs guarddog+semgrep)
# Input:   editor-extension dirs (SC_EXT_DIRS overrides), ~/.claude/plugins, ~/.claude/skills
# Output:  stdout = inventory / findings (tab-separated, or JSON with --json)
# Stderr:  framing, plugin SHA inventory, verdict
# Exit:    0 ok (incl. --deep with engine absent — behavioural skipped, not failed),
#          2 usage, 5 part of the inventory could not be read (jq missing, a
#          manifest it cannot parse, a failed recency probe - see stderr) -
#          NOT ok, 10 behavioural finding(s) (wins over 5; never a false clean)
#
# Examples:
#   scan-extensions.sh                       # full inventory + recency
#   scan-extensions.sh --days 7 --json       # JSON, 7-day recency window
#   scan-extensions.sh --deep --days 7       # behavioural-scan extensions changed in 7d

set -uo pipefail
EXIT_OK=0; EXIT_USAGE=2; EXIT_MISSING_DEP=5; EXIT_FINDING=10

JSON=0; QUIET=0; DEEP=0; ALL=0; DAYS=14
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1 ;;
    -q|--quiet) QUIET=1 ;;
    --deep) DEEP=1 ;;
    --all) ALL=1 ;;
    --days) DAYS="${2:?--days needs a value}"; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -*) echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit "$EXIT_USAGE" ;;
  esac
  shift
done

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1

# Terminal design system: framing on stderr (term_init 2); the inventory/--json
# data product stays plain on stdout. Full panel for a human at a TTY (or
# FORCE_COLOR); piped/quiet keeps the legacy "== section ==" framing.
# The lib is OPTIONAL: this skill is copied standalone into other plugins with no
# skills/_lib beside it, so the fallback must work and stay 7-bit ASCII (pinned by
# the "standalone" block in tests/run.sh). Never source it unconditionally.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2; __HAVE_TERM=1
else __HAVE_TERM=0; TERM_DOT="|"; fi
if [[ "$__HAVE_TERM" -eq 1 ]]; then
  C_Y="$TERM_C_YELLOW"; C_G="$TERM_C_GREEN"; C_D="$TERM_C_DIM"; C_R="$TERM_C_RED"; C_O="$TERM_C_OFF"
elif [[ -t 2 && -z "${NO_COLOR:-}" ]]; then C_Y=$'\033[33m'; C_G=$'\033[32m'; C_D=$'\033[2m'; C_R=$'\033[31m'; C_O=$'\033[0m'
else C_Y=""; C_G=""; C_D=""; C_R=""; C_O=""; fi
PANEL=0
if [[ "$__HAVE_TERM" -eq 1 && "$QUIET" -eq 0 ]] && { [ -t 2 ] || [ -n "${FORCE_COLOR:-}" ]; }; then PANEL=1; fi
__PANEL_OPEN=0
popen(){ [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 0 ]] || return 0; { term_panel_open supply-chain "scan-extensions"; term_panel_vert; } >&2; __PANEL_OPEN=1; }
section(){
  [[ "$QUIET" -eq 1 ]] && return
  if [[ "$PANEL" -eq 1 ]]; then
    popen
    { term_panel_vert
      if [[ -n "${2:-}" ]]; then term_panel_line "$(term_color cyan "$1")  $(term_color dim "$2")"
      else term_panel_line "$(term_color cyan "$1")"; fi
    } >&2
  else printf '%s== %s ==%s %s\n' "$C_D" "$1" "$C_O" "${2:-}" >&2; fi
}
info(){
  [[ "$QUIET" -eq 1 ]] && return
  if [[ "$PANEL" -eq 1 ]]; then popen; term_panel_line "$(term_color dim "$1")" >&2
  else printf '   %s\n' "$1" >&2; fi
}

# ── --deep: auto-detect the engine; recommend (don't require) if absent ────
# Lean by default — guarddog+semgrep are NOT kept on the machine. If --deep is asked
# for and they're present, use them; if absent, run inventory+recency and LOUDLY skip
# the behavioural pass (never report a scan we didn't run as clean).
DEEP_OK=0; DEEP_SKIPPED=0
if [[ "$DEEP" -eq 1 ]]; then
  if command -v guarddog >/dev/null 2>&1 && command -v semgrep >/dev/null 2>&1 && semgrep --version >/dev/null 2>&1; then
    DEEP_OK=1
  else
    DEEP_SKIPPED=1
  fi
fi

window_min=$(( DAYS * 1440 ))
EXT_DIRS=("$HOME/.vscode/extensions" "$HOME/.vscode-server/extensions" "$HOME/.vscode-oss/extensions" "$HOME/.cursor/extensions" "$HOME/.windsurf/extensions")
[[ -n "${SC_EXT_DIRS:-}" ]] && IFS="$(printf ':')" read -ra EXT_DIRS <<< "$SC_EXT_DIRS"

INV_JSON=(); FIND_JSON=(); FINDINGS=0; RECENT=0
UNSCANNED=()   # "<what>: <why>" per inventory part we could not read

# unscanned <what> <why> — printed even with -q (an error, not framing); turns a
# would-be exit 0 into 5. "inventory done" must mean the inventory was read.
unscanned() {
  UNSCANNED+=("$1: $2")
  if [[ "$PANEL" -eq 1 ]]; then popen; term_status_row bad "NOT read  $1" "$2" >&2
  else printf '   %s[NOT read]%s %s: %s\n' "$C_Y" "$C_O" "$1" "$2" >&2; fi
}

R_ERRF="$(mktemp)"; trap 'rm -f "$R_ERRF"' EXIT

# dir_recent <dir> — sets RECENT_OF to yes / no / unknown (any code file in <dir>
# modified within the window?) and, for unknown, RECENT_ERR to the probe's error.
# Called directly, never in $(...), so both globals reach the caller.
# Portability guard: `-mmin` is in GNU, BSD/macOS and busybox find; `-printf` is
# GNU-only. BSD find rejected the old `-printf '%T@'`, the error was discarded,
# and every item read recent=no, so --deep (gated to recent items) scanned
# nothing and exited 0. A find that still fails (one without -mmin, find.exe
# ahead on PATH) is unknown, never no: unknown is reported unscanned and is
# behaviourally scanned under --deep. Matches found before an error still mean yes.
RECENT_OF=no; RECENT_ERR=""
dir_recent() {
  local hits rc=0
  hits="$(find "$1" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.cjs' -o -name '*.mjs' -o -name '*.py' -o -name '*.sh' -o -name 'package.json' \) -mmin "-$window_min" -print 2>"$R_ERRF")" || rc=$?
  RECENT_ERR=""
  if [[ -n "$hits" ]]; then RECENT_OF=yes
  elif (( rc != 0 )); then RECENT_OF=unknown; RECENT_ERR="find exit $rc: $(head -1 "$R_ERRF" | tr -d '\r')"
  else RECENT_OF=no; fi
}

# ── 1. Editor extensions: inventory (+ behavioural if --deep) ──────────────
section "Editor extensions" "inventory + recency <${DAYS}d$( [[ $DEEP_OK -eq 1 ]] && echo ' + GuardDog behavioural' )"
for base in "${EXT_DIRS[@]}"; do
  [[ -d "$base" ]] || continue
  # Without jq every manifest reads as nameless and is skipped below, so an
  # extension dir full of code inventoried as empty. Say so instead.
  if [[ "$HAS_JQ" -eq 0 ]]; then
    for ext in "$base"/*/; do
      [[ -f "$ext/package.json" ]] && { unscanned "$base" "jq not installed - extension manifests not read"; break; }
    done
    continue
  fi
  rfail=0; rerr=""
  for ext in "$base"/*/; do
    [[ -f "$ext/package.json" ]] || continue
    pub=$(jq -r '.publisher // empty' "$ext/package.json" 2>/dev/null)
    name=$(jq -r '.name // empty' "$ext/package.json" 2>/dev/null)
    ver=$(jq -r '.version // empty' "$ext/package.json" 2>/dev/null)
    [[ -z "$pub" || -z "$name" ]] && continue
    id="$pub.$name"; dir_recent "$ext"; recent=$RECENT_OF
    [[ "$recent" == yes ]] && RECENT=$((RECENT+1))
    [[ "$recent" == unknown ]] && { rfail=$((rfail+1)); [[ -n "$rerr" ]] || rerr=$RECENT_ERR; }
    [[ "$JSON" -eq 0 && "$QUIET" -eq 0 ]] && printf '%s\t%s\trecent=%s\n' "$id" "${ver:-?}" "$recent"
    # recent is true / false / null (unknown - the probe failed)
    [[ "$HAS_JQ" -eq 1 ]] && INV_JSON+=("$(jq -cn --arg i "$id" --arg v "$ver" --argjson r "$(case $recent in yes) echo true ;; no) echo false ;; *) echo null ;; esac)" '{kind:"editor-extension",id:$i,version:$v,recent:$r}')")
    # behavioural scan: --deep, gated to recent unless --all. Unknown recency
    # counts as recent: skipping what we could not date is how --deep scanned nothing.
    if [[ "$DEEP_OK" -eq 1 && ( "$ALL" -eq 1 || "$recent" != no ) ]]; then
      gout=$(PYTHONUTF8=1 guarddog npm scan "$ext" --exit-non-zero-on-finding 2>/dev/null); grc=$?
      if [[ $grc -ne 0 ]] && echo "$gout" | grep -qiE 'potentially malicious|source code matches'; then
        FINDINGS=$((FINDINGS+1))
        if [[ "$PANEL" -eq 1 ]]; then popen; term_status_row bad "$id" "behavioural finding" >&2
        else printf '   %s[FINDING]%s %s\n' "$C_R" "$C_O" "$id" >&2; fi
        echo "$gout" | grep -iE 'found|matches|: This' | head -5 | sed 's/^/        /' >&2
        [[ "$HAS_JQ" -eq 1 ]] && FIND_JSON+=("$(jq -cn --arg i "$id" --arg d "$(echo "$gout" | tr '\n' ' ' | head -c 400)" '{id:$i,engine:"guarddog",detail:$d}')")
      fi
    fi
  done
  (( rfail == 0 )) || unscanned "recency of $rfail extension(s) in $base" "$rerr"
done

# ── 2. Claude Code plugins: inventory + pinned-commit ──────────────────────
section "Claude Code plugins" "pinned-commit inventory - verify each against its marketplace"
PMETA="$HOME/.claude/plugins/installed_plugins.json"
if [[ ! -f "$PMETA" ]]; then
  info "no installed_plugins.json (no marketplace plugins)"
elif [[ "$HAS_JQ" -eq 0 ]]; then
  unscanned "$PMETA" "jq not installed - plugin inventory not read"
else
  # procsub guard: jq's status is checked before its rows are printed. Fed
  # straight into a loop via `< <(jq ...)`, a manifest jq choked on (truncated
  # write, schema change) listed no plugins and the run still closed "inventory
  # done", exit 0.
  rc=0
  plugin_rows="$(jq -r '.plugins | to_entries[] | .key as $n | .value[] | "\($n)  sha=\(.gitCommitSha[0:12])  scope=\(.scope)  updated=\(.lastUpdated)"' "$PMETA" 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then
    unscanned "$PMETA" "jq exit $rc - not JSON or not the expected shape; plugin inventory not read"
  else
    while IFS= read -r line; do [[ -n "$line" ]] && info "$line"; done <<< "$plugin_rows"
  fi
fi

# ── 3. Installed skills: inventory + recency ───────────────────────────────
section "Installed skills" "recency <${DAYS}d (review recently-changed you didn't edit)"
rfail=0; rerr=""
for sk in "$HOME/.claude/skills"/*/; do
  [[ -d "$sk" ]] || continue
  dir_recent "$sk"
  if [[ "$RECENT_OF" == yes ]]; then
    RECENT=$((RECENT+1))
    # Not under --json: stdout is then the JSON document alone.
    [[ "$QUIET" -eq 0 && "$JSON" -eq 0 ]] && printf '%s\t(recently changed)\n' "$(basename "$sk")"
  elif [[ "$RECENT_OF" == unknown ]]; then
    rfail=$((rfail+1)); [[ -n "$rerr" ]] || rerr=$RECENT_ERR
  fi
done
(( rfail == 0 )) || unscanned "recency of $rfail skill(s) in $HOME/.claude/skills" "$rerr"

# ── Output + verdict ───────────────────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "${INV_JSON[@]:-}" | jq -s \
    --argjson f "$(printf '%s\n' "${FIND_JSON[@]:-}" | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]')" \
    --argjson deep "$DEEP" --argjson days "$DAYS" \
    --argjson u "$(printf '%s\n' "${UNSCANNED[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')" \
    '{data:{inventory: map(select(length>0)), findings:$f}, meta:{deep:($deep==1), recency_days:$days, finding_count:($f|length), unscanned:$u, schema:"axiom.tool.scan-extensions.report/v1"}}'
fi

# vclose <state> <hotkeys> <text>  — panel footer, or a colored legacy verdict line.
vclose() {  # state hotkeys legacy-color legacy-text
  if [[ "$PANEL" -eq 1 ]]; then
    popen; { term_panel_vert; term_panel_close "$2" "$(term_health "$1" "$4")"; } >&2
  else printf '%s%s%s\n' "$3" "$4" "$C_O" >&2; fi
}
# exit_ok — the would-be exit 0, unless part of the inventory went unread. A 10
# (behavioural finding) already says "not clean, look", so it never comes here.
exit_ok() {
  if [[ ${#UNSCANNED[@]} -gt 0 ]]; then
    [[ "$QUIET" -eq 1 ]] || vclose critical "fix the cause, re-run" "$C_Y" "NOT ok: ${#UNSCANNED[@]} inventory part(s) could not be read"
    exit "$EXIT_MISSING_DEP"
  fi
  exit "$EXIT_OK"
}
if [[ "$DEEP_OK" -eq 1 ]]; then
  if [[ "$FINDINGS" -eq 0 ]]; then
    [[ "$QUIET" -eq 1 ]] || vclose healthy "exposure-check for known IOCs" "$C_G" "behavioural: GuardDog found no indicators"
    exit_ok
  fi
  [[ "$QUIET" -eq 1 ]] || vclose critical "inspect ${TERM_DOT} treat as incident" "$C_R" "$FINDINGS extension(s) with behavioural findings"
  exit "$EXIT_FINDING"
fi
if [[ "$DEEP_SKIPPED" -eq 1 && "$QUIET" -eq 0 ]]; then
  info "BEHAVIOURAL SCAN SKIPPED - guarddog/semgrep not installed (kept off by default)."
  info "  ran inventory + recency only - this is NOT a clean behavioural verdict."
  info "  enable on-demand:  uv tool install guarddog semgrep   (then re-run --deep)"
fi
if [[ ${#UNSCANNED[@]} -eq 0 ]]; then
  [[ "$QUIET" -eq 1 ]] || vclose healthy "exposure-check.py for known-IOC matching" "$C_D" "inventory done - $RECENT item(s) changed within ${DAYS}d, review those"
fi
exit_ok
