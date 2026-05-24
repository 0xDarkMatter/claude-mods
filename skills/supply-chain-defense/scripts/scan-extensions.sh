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
#          2 usage, 10 behavioural finding(s)
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
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -*) echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit "$EXIT_USAGE" ;;
  esac
  shift
done

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then C_Y=$'\033[33m'; C_G=$'\033[32m'; C_D=$'\033[2m'; C_R=$'\033[31m'; C_O=$'\033[0m'
else C_Y=""; C_G=""; C_D=""; C_R=""; C_O=""; fi
section(){ [[ "$QUIET" -eq 1 ]] || printf '%s== %s ==%s %s\n' "$C_D" "$1" "$C_O" "${2:-}" >&2; }
info(){ [[ "$QUIET" -eq 1 ]] || printf '   %s\n' "$1" >&2; }

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

now_epoch=$(date +%s); window=$(( DAYS * 86400 ))
EXT_DIRS=("$HOME/.vscode/extensions" "$HOME/.vscode-server/extensions" "$HOME/.vscode-oss/extensions" "$HOME/.cursor/extensions" "$HOME/.windsurf/extensions")
[[ -n "${SC_EXT_DIRS:-}" ]] && IFS="$(printf ':')" read -ra EXT_DIRS <<< "$SC_EXT_DIRS"

INV_JSON=(); FIND_JSON=(); FINDINGS=0; RECENT=0

dir_recent() {  # echoes yes/no — any code file in $1 modified within window
  local newest
  newest=$(find "$1" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.cjs' -o -name '*.mjs' -o -name '*.py' -o -name '*.sh' -o -name 'package.json' \) -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
  [[ -n "$newest" && $(( now_epoch - ${newest%.*} )) -lt $window ]] && echo yes || echo no
}

# ── 1. Editor extensions: inventory (+ behavioural if --deep) ──────────────
section "Editor extensions" "inventory + recency <${DAYS}d$( [[ $DEEP_OK -eq 1 ]] && echo ' + GuardDog behavioural' )"
for base in "${EXT_DIRS[@]}"; do
  [[ -d "$base" ]] || continue
  for ext in "$base"/*/; do
    [[ -f "$ext/package.json" ]] || continue
    pub=$(jq -r '.publisher // empty' "$ext/package.json" 2>/dev/null)
    name=$(jq -r '.name // empty' "$ext/package.json" 2>/dev/null)
    ver=$(jq -r '.version // empty' "$ext/package.json" 2>/dev/null)
    [[ -z "$pub" || -z "$name" ]] && continue
    id="$pub.$name"; recent=$(dir_recent "$ext")
    [[ "$recent" == yes ]] && RECENT=$((RECENT+1))
    [[ "$JSON" -eq 0 && "$QUIET" -eq 0 ]] && printf '%s\t%s\trecent=%s\n' "$id" "${ver:-?}" "$recent"
    [[ "$HAS_JQ" -eq 1 ]] && INV_JSON+=("$(jq -cn --arg i "$id" --arg v "$ver" --argjson r "$([[ $recent == yes ]] && echo true || echo false)" '{kind:"editor-extension",id:$i,version:$v,recent:$r}')")
    # behavioural scan: --deep, gated to recent unless --all
    if [[ "$DEEP_OK" -eq 1 && ( "$ALL" -eq 1 || "$recent" == yes ) ]]; then
      gout=$(PYTHONUTF8=1 guarddog npm scan "$ext" --exit-non-zero-on-finding 2>/dev/null); grc=$?
      if [[ $grc -ne 0 ]] && echo "$gout" | grep -qiE 'potentially malicious|source code matches'; then
        FINDINGS=$((FINDINGS+1))
        printf '   %s[FINDING]%s %s\n' "$C_R" "$C_O" "$id" >&2
        echo "$gout" | grep -iE 'found|matches|: This' | head -5 | sed 's/^/        /' >&2
        [[ "$HAS_JQ" -eq 1 ]] && FIND_JSON+=("$(jq -cn --arg i "$id" --arg d "$(echo "$gout" | tr '\n' ' ' | head -c 400)" '{id:$i,engine:"guarddog",detail:$d}')")
      fi
    fi
  done
done

# ── 2. Claude Code plugins: inventory + pinned-commit ──────────────────────
section "Claude Code plugins" "pinned-commit inventory — verify each against its marketplace"
PMETA="$HOME/.claude/plugins/installed_plugins.json"
if [[ -f "$PMETA" && "$HAS_JQ" -eq 1 ]]; then
  while IFS= read -r line; do info "$line"; done < <(jq -r '.plugins | to_entries[] | .key as $n | .value[] | "\($n)  sha=\(.gitCommitSha[0:12])  scope=\(.scope)  updated=\(.lastUpdated)"' "$PMETA" 2>/dev/null)
else
  info "no installed_plugins.json (no marketplace plugins) or jq missing"
fi

# ── 3. Installed skills: inventory + recency ───────────────────────────────
section "Installed skills" "recency <${DAYS}d (review recently-changed you didn't edit)"
for sk in "$HOME/.claude/skills"/*/; do
  [[ -d "$sk" ]] || continue
  recent=$(dir_recent "$sk")
  if [[ "$recent" == yes ]]; then
    RECENT=$((RECENT+1))
    [[ "$QUIET" -eq 0 ]] && printf '%s\t(recently changed)\n' "$(basename "$sk")"
  fi
done

# ── Output + verdict ───────────────────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "${INV_JSON[@]:-}" | jq -s \
    --argjson f "$(printf '%s\n' "${FIND_JSON[@]:-}" | jq -s 'map(select(length>0))' 2>/dev/null || echo '[]')" \
    --argjson deep "$DEEP" --argjson days "$DAYS" \
    '{data:{inventory: map(select(length>0)), findings:$f}, meta:{deep:($deep==1), recency_days:$days, finding_count:($f|length), schema:"axiom.tool.scan-extensions.report/v1"}}'
fi

if [[ "$DEEP_OK" -eq 1 ]]; then
  if [[ "$FINDINGS" -eq 0 ]]; then
    [[ "$QUIET" -eq 1 ]] || printf '%sBehavioural: GuardDog found no indicators in scanned extensions.%s\n' "$C_G" "$C_O" >&2
    exit "$EXIT_OK"
  fi
  [[ "$QUIET" -eq 1 ]] || printf '%s%d extension(s) with behavioural findings — inspect + treat as incident.%s\n' "$C_R" "$FINDINGS" "$C_O" >&2
  exit "$EXIT_FINDING"
fi
if [[ "$DEEP_SKIPPED" -eq 1 ]]; then
  [[ "$QUIET" -eq 1 ]] || {
    printf '%sBEHAVIOURAL SCAN SKIPPED%s — guarddog/semgrep not installed (kept off by default).\n' "$C_Y" "$C_O" >&2
    printf '   Ran inventory + recency only — this is NOT a clean behavioural verdict.\n' >&2
    printf '   Enable on-demand:  uv tool install guarddog semgrep   (then re-run --deep)\n' >&2
  }
fi
[[ "$QUIET" -eq 1 ]] || printf '%sInventory done. %d item(s) changed within %dd — review those; run exposure-check.py for known-IOC matching.%s\n' "$C_D" "$RECENT" "$DAYS" "$C_O" >&2
exit "$EXIT_OK"
