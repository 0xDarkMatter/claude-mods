#!/usr/bin/env bash
# Release-age pre-check for dependencies — enforce the cooldown policy.
#
# Flags any package whose target version was published inside the cooldown window
# (default 7 days), because the 2026 worm campaign poisons brand-new releases that
# are removed within hours. Routes to `socket` for a behavioural verdict when the
# CLI is installed. Queries public registries (npm registry / PyPI JSON API) — no
# auth, no install, read-only.
#
# Usage:   preinstall-check.sh [--npm|--pip|--composer|--cargo|--go] [--json] [-q] <pkg>[@version] ...
# Input:   one or more package specs as positionals; a flag picks the ecosystem
#          (default npm; Composer specs are vendor/pkg[@version])
# Output:  stdout = per-package records (tab-separated, or JSON with --json)
# Stderr:  headers, socket suggestions, progress, errors
# Exit:    0 all outside cooldown, 2 usage, 5 missing-dep, 7 registry-unavailable,
#          10 at-least-one-inside-cooldown
#
# Examples:
#   preinstall-check.sh axios react@19.0.0
#   preinstall-check.sh --pip requests fastapi@0.110.0
#   preinstall-check.sh --composer laravel-lang/lang craftcms/cms@4.5.0
#   preinstall-check.sh --cargo serde  ;  preinstall-check.sh --go github.com/gin-gonic/gin
#   preinstall-check.sh --json axios | jq '.data[] | select(.inside_cooldown)'
#   COOLDOWN_DAYS=14 preinstall-check.sh left-pad

set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_MISSING_DEP=5; EXIT_UNAVAILABLE=7; EXIT_INSIDE=10

ECOSYSTEM="npm"; COOLDOWN_DAYS="${COOLDOWN_DAYS:-7}"; JSON=0; QUIET=0; PKGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pip|--pypi) ECOSYSTEM="pypi" ;;
    --npm)        ECOSYSTEM="npm" ;;
    --composer)   ECOSYSTEM="composer" ;;
    --cargo)      ECOSYSTEM="cargo" ;;
    --go)         ECOSYSTEM="go" ;;
    --json)       JSON=1 ;;
    -q|--quiet)   QUIET=1 ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -*)  echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)   PKGS+=("$1") ;;
  esac
  shift
done

[[ ${#PKGS[@]} -eq 0 ]] && { echo "ERROR: no package specs given (try --help)" >&2; exit "$EXIT_USAGE"; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required" >&2; exit "$EXIT_MISSING_DEP"; }
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
[[ "$JSON" -eq 1 && "$HAS_JQ" -eq 0 ]] && {
  echo '{"error":{"code":"MISSING_DEPENDENCY","message":"jq required for --json"}}'
  echo "ERROR: jq required for --json" >&2; exit "$EXIT_MISSING_DEP"; }
HAS_SOCKET=0; command -v socket >/dev/null 2>&1 && HAS_SOCKET=1

emit() { [[ "$QUIET" -eq 1 ]] && return; printf '%s\n' "$1" >&2; }

# Terminal design system: framing on stderr (term_init 2); TSV/--json stays plain
# on stdout. Full panel for a human at a TTY (or FORCE_COLOR); else legacy emit.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2; __HAVE_TERM=1
else __HAVE_TERM=0; TERM_DOT="|"; fi
PANEL=0
if [[ "$__HAVE_TERM" -eq 1 && "$QUIET" -eq 0 ]] && { [ -t 2 ] || [ -n "${FORCE_COLOR:-}" ]; }; then PANEL=1; fi
__PANEL_OPEN=0
popen() {
  [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 0 ]] || return 0
  { term_panel_open supply-chain "preinstall ${TERM_DOT} ${ECOSYSTEM}"; term_panel_vert; } >&2; __PANEL_OPEN=1
}
prow() {  # mark legacy-prefix text
  if [[ "$PANEL" -eq 1 ]]; then popen; term_status_row "$1" "$3" >&2
  else emit "  $2 $3"; fi
}
pinfo() { [[ "$PANEL" -eq 1 ]] && { popen; term_panel_line "$(term_color dim "$1")" >&2; } || emit "$1"; }

now_epoch=$(date +%s); inside=0; unavailable=0
JSON_OBJS=()

iso_to_epoch() {
  local ts=$1
  date -d "$ts" +%s 2>/dev/null && return 0
  ts="${ts%%.*}"; ts="${ts%Z}"
  date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null && return 0
  echo ""
}

result() {  # name version published
  local name=$1 version=$2 published=$3 days=-1 ic=false
  if [[ -n "$version" && -n "$published" ]]; then
    local epoch; epoch=$(iso_to_epoch "$published")
    if [[ -n "$epoch" ]]; then
      days=$(( (now_epoch - epoch) / 86400 ))
      if [[ "$days" -lt "$COOLDOWN_DAYS" ]]; then ic=true; inside=1; fi
    fi
  fi
  # data record → stdout (non-json mode)
  if [[ "$JSON" -eq 0 ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$ECOSYSTEM" "$name" "${version:-?}" "${days}" "$ic"
  fi
  [[ "$HAS_JQ" -eq 1 ]] && JSON_OBJS+=("$(jq -cn \
    --arg e "$ECOSYSTEM" --arg n "$name" --arg v "$version" \
    --arg p "$published" --argjson d "$days" --argjson ic "$ic" \
    '{ecosystem:$e, name:$n, version:($v|select(length>0)), published:($p|select(length>0)), age_days:(if $d<0 then null else $d end), inside_cooldown:$ic}')")
  # human framing → stderr
  if [[ "$ic" == "true" ]]; then
    prow bad "[INSIDE COOLDOWN]" "${name}@${version} - ${days}d ago (< ${COOLDOWN_DAYS}d). Hold off."
  elif [[ "$days" -ge 0 ]]; then
    prow ok "[ok]" "${name}@${version} - ${days}d ago (>= ${COOLDOWN_DAYS}d)."
  else
    prow unknown "[?]" "${name} - version/publish time not found or registry unreachable."
  fi
}

fetch() { curl -fsSL -A "supply-chain-defense/preinstall-check" "$1" 2>/dev/null || { unavailable=1; echo ""; }; }

check_npm() {
  local spec=$1 name version json
  name="${spec%@*}"; version=""
  [[ "$spec" == *"@"* && "$spec" != @*/* ]] && version="${spec#*@}"
  json=$(fetch "https://registry.npmjs.org/${name}")
  [[ -z "$json" || "$HAS_JQ" -eq 0 ]] && { result "$name" "" ""; return; }
  [[ -z "$version" ]] && version=$(jq -r '."dist-tags".latest // empty' <<<"$json")
  result "$name" "$version" "$(jq -r --arg v "$version" '.time[$v] // empty' <<<"$json")"
}
check_pypi() {
  local spec=$1 name version url json
  name="${spec%==*}"; version=""
  [[ "$spec" == *"=="* ]] && version="${spec#*==}"
  [[ "$spec" == *"@"* ]] && { name="${spec%@*}"; version="${spec#*@}"; }
  url="https://pypi.org/pypi/${name}/json"; [[ -n "$version" ]] && url="https://pypi.org/pypi/${name}/${version}/json"
  json=$(fetch "$url")
  [[ -z "$json" || "$HAS_JQ" -eq 0 ]] && { result "$name" "" ""; return; }
  [[ -z "$version" ]] && version=$(jq -r '.info.version // empty' <<<"$json")
  result "$name" "$version" "$(jq -r --arg v "$version" \
    '(.releases[$v]//[])[0].upload_time_iso_8601 // .urls[0].upload_time_iso_8601 // empty' <<<"$json")"
}

check_composer() {  # Packagist: repo.packagist.org/p2/<vendor>/<pkg>.json
  local spec=$1 name version json published
  name="${spec%@*}"; version=""
  [[ "$spec" == *"@"* ]] && version="${spec#*@}"
  json=$(fetch "https://repo.packagist.org/p2/${name}.json")
  [[ -z "$json" || "$HAS_JQ" -eq 0 ]] && { result "$name" "" ""; return; }
  [[ -z "$version" ]] && version=$(jq -r --arg n "$name" '(.packages[$n][0].version) // empty' <<<"$json")
  published=$(jq -r --arg n "$name" --arg v "$version" 'first(.packages[$n][] | select(.version==$v) | .time) // empty' <<<"$json")
  result "$name" "$version" "$published"
}
check_cargo() {  # crates.io API (requires User-Agent — fetch sets one)
  local spec=$1 name version json published
  name="${spec%@*}"; version=""
  [[ "$spec" == *"@"* ]] && version="${spec#*@}"
  json=$(fetch "https://crates.io/api/v1/crates/${name}")
  [[ -z "$json" || "$HAS_JQ" -eq 0 ]] && { result "$name" "" ""; return; }
  [[ -z "$version" ]] && version=$(jq -r '.crate.max_stable_version // .crate.newest_version // empty' <<<"$json")
  published=$(jq -r --arg v "$version" 'first(.versions[] | select(.num==$v) | .created_at) // empty' <<<"$json")
  result "$name" "$version" "$published"
}
check_go() {  # proxy.golang.org/<module>/@v/<version>.info  (or /@latest)
  local spec=$1 mod version json
  mod="${spec%@*}"; version=""
  [[ "$spec" == *"@"* ]] && version="${spec#*@}"
  if [[ -z "$version" ]]; then json=$(fetch "https://proxy.golang.org/${mod}/@latest")
  else json=$(fetch "https://proxy.golang.org/${mod}/@v/${version}.info"); fi
  [[ -z "$json" || "$HAS_JQ" -eq 0 ]] && { result "$mod" "" ""; return; }
  result "$mod" "$(jq -r '.Version // empty' <<<"$json")" "$(jq -r '.Time // empty' <<<"$json")"
}

if [[ "$PANEL" -eq 1 ]]; then popen; else emit "=== Pre-install check (${ECOSYSTEM}, cooldown ${COOLDOWN_DAYS}d) ==="; fi
for spec in "${PKGS[@]}"; do
  case "$ECOSYSTEM" in
    npm) check_npm "$spec" ;; pypi) check_pypi "$spec" ;;
    composer) check_composer "$spec" ;; cargo) check_cargo "$spec" ;; go) check_go "$spec" ;;
  esac
done

if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "${JSON_OBJS[@]:-}" | jq -s \
    --argjson cd "$COOLDOWN_DAYS" --arg eco "$ECOSYSTEM" \
    '{data: map(select(length>0)), meta:{ecosystem:$eco, cooldown_days:$cd, count:(map(select(length>0))|length), schema:"axiom.tool.preinstall-check.report/v1"}}'
fi

if [[ "$QUIET" -eq 0 ]]; then
  [[ "$PANEL" -eq 1 ]] && term_panel_vert >&2 || emit ""
  if [[ "$HAS_SOCKET" -eq 1 ]]; then
    pinfo "behavioural verdict:"
    for spec in "${PKGS[@]}"; do n="${spec%@*}"; n="${n%==*}"; pinfo "  socket package score ${ECOSYSTEM} ${n}"; done
  else
    pinfo "behavioural scan (free):  npm install -g socket   # then: socket package score ${ECOSYSTEM} <pkg>"
    pinfo "or depscore MCP (no key):  claude mcp add --transport http socket-mcp https://mcp.socket.dev/"
  fi
  if [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 1 ]]; then
    ph_state="healthy"; ph_text="outside cooldown"
    [[ "$unavailable" -eq 1 ]] && { ph_state="warning"; ph_text="registry unavailable"; }
    [[ "$inside" -eq 1 ]] && { ph_state="warning"; ph_text="inside cooldown"; }
    { term_panel_vert; term_panel_close "hold new releases ${TERM_DOT} --json for data" "$(term_health "$ph_state" "$ph_text")"; } >&2
  fi
fi

[[ "$inside" -eq 1 ]] && exit "$EXIT_INSIDE"
[[ "$unavailable" -eq 1 ]] && exit "$EXIT_UNAVAILABLE"
exit "$EXIT_OK"
