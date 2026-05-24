#!/usr/bin/env bash
# Self-integrity scan — detect worm persistence in Claude Code / VS Code settings.
#
# Flags the 2026 worm IOC: hooks / mcpServers injected into Claude Code and VS Code
# settings, plus GitHub Actions workflows with live OIDC publish trust (the Mini
# Shai-Hulud entry point). Read-only — it reports; you decide. Uses `zizmor` for
# richer workflow analysis when installed.
#
# Usage:   integrity-audit.sh [--json] [-q] [-v] [PROJECT_DIR]
# Input:   optional PROJECT_DIR positional (default: cwd) + $HOME config locations
# Output:  stdout = findings (tab-separated records, or JSON with --json)
# Stderr:  section framing, progress, verdict guidance, errors
# Exit:    0 clean, 2 usage, 5 missing-dep (jq, with --json), 10 review-items-found
#
# Note: intentionally NOT `set -e` — a scanner must survive missing files and keep
# going. Errors are handled explicitly.
#
# Examples:
#   integrity-audit.sh
#   integrity-audit.sh --json | jq '.data.review[]'
#   integrity-audit.sh -q ./some/project    # quiet: findings only, no framing

set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_MISSING_DEP=5; EXIT_REVIEW=10

JSON=0; QUIET=0; VERBOSE=0; PROJECT_DIR="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)        JSON=1 ;;
    -q|--quiet)    QUIET=1 ;;
    -v|--verbose)  VERBOSE=1 ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -*) echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)  PROJECT_DIR="$1" ;;
  esac
  shift
done

# stderr framing — colored only when stderr is a TTY and NO_COLOR unset.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_Y=$'\033[33m'; C_G=$'\033[32m'; C_D=$'\033[2m'; C_O=$'\033[0m'
else C_Y=""; C_G=""; C_D=""; C_O=""; fi
section() { [[ "$QUIET" -eq 1 ]] && return; printf '%s== %s ==%s %s\n' "$C_D" "$1" "$C_O" "${2:-}" >&2; }
info()    { [[ "$QUIET" -eq 1 ]] && return; printf '   %s\n' "$1" >&2; }
vinfo()   { [[ "$VERBOSE" -eq 1 ]] && printf '   %s\n' "$1" >&2; }

HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
HAS_ZIZMOR=0; command -v zizmor >/dev/null 2>&1 && HAS_ZIZMOR=1
if [[ "$JSON" -eq 1 && "$HAS_JQ" -eq 0 ]]; then
  echo '{"error":{"code":"MISSING_DEPENDENCY","message":"jq required for --json","details":{"install":"apt-get install jq"}}}'
  echo "ERROR: jq required for --json output" >&2
  exit "$EXIT_MISSING_DEP"
fi

REVIEW_JSON=()    # array of compact JSON objects
REVIEW_COUNT=0

# record <category> <source> <kind> <entries-newline-separated>
record() {
  local category=$1 source=$2 kind=$3 entries=$4
  REVIEW_COUNT=$((REVIEW_COUNT+1))
  # tab-separated record to stdout (the data product, non-JSON mode)
  if [[ "$JSON" -eq 0 ]]; then
    local flat; flat=$(echo "$entries" | paste -sd',' - 2>/dev/null)
    printf '%s\t%s\t%s\t%s\n' "$category" "$source" "$kind" "$flat"
  fi
  if [[ "$HAS_JQ" -eq 1 ]]; then
    local obj
    obj=$(jq -cn --arg c "$category" --arg s "$source" --arg k "$kind" \
      --arg e "$entries" '{category:$c, source:$s, kind:$k, entries:($e|split("\n")|map(select(length>0)))}')
    REVIEW_JSON+=("$obj")
  fi
  printf '   %s[review]%s %s %s: %s\n' "$C_Y" "$C_O" "$kind" "$source" \
    "$(echo "$entries" | paste -sd',' - 2>/dev/null)" >&2
}

json_key_entries() {  # file key -> newline-separated entry list (jq)
  local file=$1 key=$2
  [[ -f "$file" && "$HAS_JQ" -eq 1 ]] || return 0
  jq -r --arg k "$key" '
    if (.[$k] // empty) == null then empty
    elif (.[$k]|type)=="object" then (.[$k]|keys[])
    elif (.[$k]|type)=="array"  then (.[$k][]|tostring)
    else (.[$k]|tostring) end' "$file" 2>/dev/null
}

# ─── 1. AI-tool config: hooks / mcpServers across hosts ────────────────────
# Broadened with the MCP host-config map from Perplexity's Bumblebee
# (docs/inventory-sources.md) — the worm targets these persistence surfaces.
section "AI-tool config" "hooks / mcpServers you may not have added (Claude + MCP hosts)"
APPDATA_DIR="${APPDATA:-$HOME/AppData/Roaming}"
CLAUDE_FILES=(
  "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude.json"
  "$HOME/.gemini/settings.json"                                    # Gemini CLI / Code Assist
  "$HOME/Library/Application Support/Claude/claude_desktop_config.json"   # Claude Desktop (mac)
  "$APPDATA_DIR/Claude/claude_desktop_config.json"                 # Claude Desktop (win)
  "$HOME/.config/Claude/claude_desktop_config.json")              # Claude Desktop (linux)
# Project-local MCP / Claude configs (skip worktrees — owned by other sessions).
while IFS= read -r f; do CLAUDE_FILES+=("$f"); done < <(
  find "$PROJECT_DIR" -maxdepth 4 \
    \( -name 'settings*.json' -path '*/.claude/*' \
       -o -name '.mcp.json' -o -name 'mcp.json' \
       -o -name 'cline_mcp_settings.json' -o -name 'mcp_settings.json' \) \
    -not -path '*/worktrees/*' -not -path '*/node_modules/*' 2>/dev/null)
for f in "${CLAUDE_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  vinfo "scanning $f"
  for key in hooks mcpServers; do
    entries=$(json_key_entries "$f" "$key")
    [[ -n "$entries" ]] && record "aitool_config" "$f" "$key" "$entries"
  done
done

# ─── 2. Editor user settings (VS Code + forks) ─────────────────────────────
section "Editor settings" "startup / autorun / task IOCs (VS Code, Cursor, Windsurf, VSCodium)"
EDITOR_SETTINGS=()
for ed in Code Cursor Windsurf VSCodium; do
  EDITOR_SETTINGS+=(
    "$HOME/.config/$ed/User/settings.json"                       # Linux
    "$HOME/Library/Application Support/$ed/User/settings.json"   # macOS
    "${APPDATA:-$HOME/AppData/Roaming}/$ed/User/settings.json")  # Windows
done
SUSPECT='task.allowAutomaticTasks|automationProfile|shellArgs|runOnStartup|autoRun|"command":'
for f in "${EDITOR_SETTINGS[@]}"; do
  [[ -f "$f" ]] || continue
  vinfo "scanning $f"
  hits=$(grep -nEi "$SUSPECT" "$f" 2>/dev/null)
  [[ -n "$hits" ]] && record "vscode_settings" "$f" "autorun_keys" "$hits"
done
info "audit extensions too: code --list-extensions --show-versions (pause <7-day, non-verified)"

# ─── 3. GitHub Actions OIDC publish trust ──────────────────────────────────
section "GitHub Actions" "live OIDC publish trust (Mini Shai-Hulud entry point)"
WF_DIR="$PROJECT_DIR/.github/workflows"
if [[ -d "$WF_DIR" ]]; then
  if [[ "$HAS_ZIZMOR" -eq 1 ]]; then
    info "running zizmor (richer workflow analysis) — see stderr"
    [[ "$QUIET" -eq 0 ]] && zizmor "$WF_DIR" >&2 2>&1 || true
  else
    # Surface the degradation at info level (NOT verbose-only) — the caller must
    # know they're getting the weaker check, or they'll assume full coverage.
    info "NOTE: zizmor not installed — using weaker rg-based OIDC check only."
    info "      Misses pull_request_target / template-injection. Install: uv tool install zizmor"
  fi
  while IFS= read -r wf; do
    [[ -z "$wf" ]] && continue
    pub=$(grep -nE 'npm publish|pypi|twine upload|trusted.?publish|registry-url' "$wf" 2>/dev/null)
    record "workflow_oidc" "$wf" "id-token-write" "${pub:-id-token: write present}"
  done < <(grep -rlE 'id-token:\s*write' "$WF_DIR" 2>/dev/null)
else
  info "no .github/workflows in $PROJECT_DIR"
fi

# ─── Output + verdict ──────────────────────────────────────────────────────
if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "${REVIEW_JSON[@]:-}" | jq -s \
    --argjson z "$HAS_ZIZMOR" \
    '{data:{review: (map(select(length>0)))}, meta:{count:(map(select(length>0))|length), zizmor_used:($z==1), schema:"axiom.tool.integrity-audit.report/v1"}}'
fi

if [[ "$REVIEW_COUNT" -eq 0 ]]; then
  [[ "$QUIET" -eq 0 ]] && printf '%sClean: nothing flagged for review.%s\n' "$C_G" "$C_O" >&2
  exit "$EXIT_OK"
fi
if [[ "$QUIET" -eq 0 ]]; then
  printf '%s%d item(s) flagged for review — confirm YOU added each.%s\n' "$C_Y" "$REVIEW_COUNT" "$C_O" >&2
  cat >&2 <<'EOF'
   Not proof of compromise. If any entry is unexplained, treat as an incident:
     1. Isolate the machine.  2. Rotate every reachable credential.  3. Investigate.
EOF
fi
exit "$EXIT_REVIEW"
