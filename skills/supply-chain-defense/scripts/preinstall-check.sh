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
#          (default npm, scoped @scope/pkg[@version] included; Composer specs are
#          vendor/pkg[@version]). Versions are exact or an npm dist-tag, not ranges.
# Output:  stdout = per-package records (tab-separated, or JSON with --json)
# Stderr:  headers, socket suggestions, progress, errors
# Exit:    0 every package checked and outside cooldown, 2 usage,
#          5 missing-dep (curl, jq - nothing can be checked without them),
#          7 at least one package NOT checked (registry unreachable, or no publish
#            time for the version asked for) - never read 7 as a pass,
#          10 at-least-one-inside-cooldown (wins over 7)
#
# Examples:
#   preinstall-check.sh axios react@19.0.0 @types/node@22.0.0
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
    -h|--help)    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "$EXIT_OK" ;;
    -*)  echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)   PKGS+=("$1") ;;
  esac
  shift
done

[[ ${#PKGS[@]} -eq 0 ]] && { echo "ERROR: no package specs given (try --help)" >&2; exit "$EXIT_USAGE"; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required" >&2; exit "$EXIT_MISSING_DEP"; }
# jq is required in every mode, not just --json: it is what reads the version and
# publish time out of each registry answer. Without it every package came back
# "age unknown", the cooldown was never tested and the run exited 0.
command -v jq >/dev/null 2>&1 || {
  [[ "$JSON" -eq 1 ]] && echo '{"error":{"code":"MISSING_DEPENDENCY","message":"jq required to read registry responses"}}'
  echo "ERROR: jq required to read registry responses - no package can be checked without it" >&2
  echo "  install: winget install jqlang.jq | brew install jq | apt install jq" >&2
  exit "$EXIT_MISSING_DEP"; }
HAS_SOCKET=0; command -v socket >/dev/null 2>&1 && HAS_SOCKET=1

emit() { [[ "$QUIET" -eq 1 ]] && return; printf '%s\n' "$1" >&2; }

# Terminal design system: framing on stderr (term_init 2); TSV/--json stays plain
# on stdout. Full panel for a human at a TTY (or FORCE_COLOR); else legacy emit.
# The lib is OPTIONAL: this skill is copied standalone into other plugins with no
# skills/_lib beside it, so the fallback must work and stay 7-bit ASCII (pinned by
# the "standalone" block in tests/run.sh). Never source it unconditionally.
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
UNCHECKED=()   # name@version: reason, for every package whose age stayed unknown
JSON_OBJS=()

iso_to_epoch() {
  local ts=$1
  date -d "$ts" +%s 2>/dev/null && return 0
  ts="${ts%%.*}"; ts="${ts%Z}"
  date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null && return 0
  echo ""
}

# Every record either proves an age or lands in UNCHECKED, and UNCHECKED forces a
# non-zero exit: a package whose age is unknown was not checked, so it must never
# fall through to the exit-0 "all outside cooldown" verdict.
result() {  # name version published [why-unchecked]
  local name=$1 version=$2 published=$3 why=${4:-} days=-1 ic=false
  if [[ -n "$version" && -n "$published" ]]; then
    local epoch; epoch=$(iso_to_epoch "$published")
    if [[ -n "$epoch" ]]; then
      days=$(( (now_epoch - epoch) / 86400 ))
      if [[ "$days" -lt "$COOLDOWN_DAYS" ]]; then ic=true; inside=1; fi
    else
      why="could not parse publish time '${published}'"
    fi
  elif [[ -z "$why" ]]; then
    why="registry has no publish time for ${version:-its latest version}"
  fi
  [[ "$days" -lt 0 ]] && UNCHECKED+=("${name}${version:+@$version}: ${why}")
  # data record → stdout (non-json mode)
  if [[ "$JSON" -eq 0 ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$ECOSYSTEM" "$name" "${version:-?}" "${days}" "$ic"
  fi
  # null, never select(): an empty select() inside {...} empties the whole object,
  # which silently dropped every unchecked package from --json output.
  JSON_OBJS+=("$(jq -cn \
    --arg e "$ECOSYSTEM" --arg n "$name" --arg v "$version" \
    --arg p "$published" --argjson d "$days" --argjson ic "$ic" --arg w "$why" \
    '{ecosystem:$e, name:$n, version:(if $v == "" then null else $v end), published:(if $p == "" then null else $p end), age_days:(if $d<0 then null else $d end), inside_cooldown:$ic, unchecked_reason:(if $d<0 then $w else null end)}')")
  # human framing → stderr
  if [[ "$ic" == "true" ]]; then
    prow bad "[INSIDE COOLDOWN]" "${name}@${version} - ${days}d ago (< ${COOLDOWN_DAYS}d). Hold off."
  elif [[ "$days" -ge 0 ]]; then
    prow ok "[ok]" "${name}@${version} - ${days}d ago (>= ${COOLDOWN_DAYS}d)."
  else
    prow unknown "[NOT CHECKED]" "${name}${version:+@$version} - ${why}."
  fi
}

# fetch runs inside $(...), a subshell, so it cannot set `unavailable` itself (the
# assignment would die with the subshell). It returns curl's status; every caller
# writes `json=$(fetch ...) || unavailable=1` and passes an empty answer to
# result() as unchecked, which is what drives exit 7.
fetch() { curl -fsSL -A "supply-chain-defense/preinstall-check" "$1" 2>/dev/null; }
UNREACHABLE="registry unreachable or package not found"

# npm spec grammar: [@scope/]name[@version]. A scope's leading "@" is not the
# version separator, so it is set aside before splitting: `${spec%@*}` on a bare
# "@scope/pkg" yields "" (an empty registry query), and a guard that skipped every
# "@*/*" spec dropped the version from "@scope/pkg@1.2.3" and checked `latest`.
split_npm_spec() {  # spec -> NPM_NAME, NPM_VERSION
  local spec=$1 scope=""
  [[ "$spec" == @* ]] && { scope="@"; spec="${spec#@}"; }
  if [[ "$spec" == *@* ]]; then NPM_NAME="${scope}${spec%@*}"; NPM_VERSION="${spec##*@}"
  else NPM_NAME="${scope}${spec}"; NPM_VERSION=""; fi
}

check_npm() {
  local name version json
  split_npm_spec "$1"; name=$NPM_NAME; version=$NPM_VERSION
  # The registry's canonical scoped path escapes the slash: /@scope%2fpkg.
  json=$(fetch "https://registry.npmjs.org/${name/\//%2f}") || unavailable=1
  [[ -z "$json" ]] && { result "$name" "$version" "" "$UNREACHABLE"; return; }
  # An absent version means `latest`; a dist-tag (next, beta) resolves to its version.
  version=$(jq -r --arg v "${version:-latest}" '."dist-tags"[$v] // $v' <<<"$json")
  result "$name" "$version" "$(jq -r --arg v "$version" '.time[$v] // empty' <<<"$json")"
}
check_pypi() {
  local spec=$1 name version url json
  name="${spec%==*}"; version=""
  [[ "$spec" == *"=="* ]] && version="${spec#*==}"
  [[ "$spec" == *"@"* ]] && { name="${spec%@*}"; version="${spec#*@}"; }
  url="https://pypi.org/pypi/${name}/json"; [[ -n "$version" ]] && url="https://pypi.org/pypi/${name}/${version}/json"
  json=$(fetch "$url") || unavailable=1
  [[ -z "$json" ]] && { result "$name" "$version" "" "$UNREACHABLE"; return; }
  [[ -z "$version" ]] && version=$(jq -r '.info.version // empty' <<<"$json")
  result "$name" "$version" "$(jq -r --arg v "$version" \
    '(.releases[$v]//[])[0].upload_time_iso_8601 // .urls[0].upload_time_iso_8601 // empty' <<<"$json")"
}

check_composer() {  # Packagist: repo.packagist.org/p2/<vendor>/<pkg>.json
  local spec=$1 name version json published
  name="${spec%@*}"; version=""
  [[ "$spec" == *"@"* ]] && version="${spec#*@}"
  json=$(fetch "https://repo.packagist.org/p2/${name}.json") || unavailable=1
  [[ -z "$json" ]] && { result "$name" "$version" "" "$UNREACHABLE"; return; }
  [[ -z "$version" ]] && version=$(jq -r --arg n "$name" '(.packages[$n][0].version) // empty' <<<"$json")
  published=$(jq -r --arg n "$name" --arg v "$version" 'first(.packages[$n][] | select(.version==$v) | .time) // empty' <<<"$json")
  result "$name" "$version" "$published"
}
check_cargo() {  # crates.io API (requires User-Agent — fetch sets one)
  local spec=$1 name version json published
  name="${spec%@*}"; version=""
  [[ "$spec" == *"@"* ]] && version="${spec#*@}"
  json=$(fetch "https://crates.io/api/v1/crates/${name}") || unavailable=1
  [[ -z "$json" ]] && { result "$name" "$version" "" "$UNREACHABLE"; return; }
  [[ -z "$version" ]] && version=$(jq -r '.crate.max_stable_version // .crate.newest_version // empty' <<<"$json")
  published=$(jq -r --arg v "$version" 'first(.versions[] | select(.num==$v) | .created_at) // empty' <<<"$json")
  result "$name" "$version" "$published"
}
check_go() {  # proxy.golang.org/<module>/@v/<version>.info  (or /@latest)
  local spec=$1 mod version json
  mod="${spec%@*}"; version=""
  [[ "$spec" == *"@"* ]] && version="${spec#*@}"
  if [[ -z "$version" ]]; then json=$(fetch "https://proxy.golang.org/${mod}/@latest") || unavailable=1
  else json=$(fetch "https://proxy.golang.org/${mod}/@v/${version}.info") || unavailable=1; fi
  [[ -z "$json" ]] && { result "$mod" "$version" "" "$UNREACHABLE"; return; }
  result "$mod" "$(jq -r '.Version // empty' <<<"$json")" "$(jq -r '.Time // empty' <<<"$json")"
}

spec_name() {  # bare package name of a spec, for the socket suggestions
  case "$ECOSYSTEM" in
    npm)  split_npm_spec "$1"; printf '%s' "$NPM_NAME" ;;
    pypi) local n="${1%%==*}"; printf '%s' "${n%@*}" ;;
    *)    printf '%s' "${1%@*}" ;;
  esac
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
    '{data: map(select(length>0)), meta:{ecosystem:$eco, cooldown_days:$cd, count:(map(select(length>0))|length), unchecked:(map(select(length>0 and .age_days == null))|length), schema:"axiom.tool.preinstall-check.report/v1"}}'
fi

if [[ "$QUIET" -eq 0 ]]; then
  [[ "$PANEL" -eq 1 ]] && term_panel_vert >&2 || emit ""
  if [[ "$HAS_SOCKET" -eq 1 ]]; then
    pinfo "behavioural verdict:"
    for spec in "${PKGS[@]}"; do pinfo "  socket package score ${ECOSYSTEM} $(spec_name "$spec")"; done
  else
    pinfo "behavioural scan (free):  npm install -g socket   # then: socket package score ${ECOSYSTEM} <pkg>"
    pinfo "or depscore MCP (no key):  claude mcp add --transport http socket-mcp https://mcp.socket.dev/"
  fi
  if [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 1 ]]; then
    ph_state="healthy"; ph_text="outside cooldown"
    [[ ${#UNCHECKED[@]} -gt 0 ]] && { ph_state="warning"; ph_text="not all checked"; }
    [[ "$unavailable" -eq 1 ]] && { ph_state="warning"; ph_text="registry unavailable"; }
    [[ "$inside" -eq 1 ]] && { ph_state="warning"; ph_text="inside cooldown"; }
    { term_panel_vert; term_panel_close "hold new releases ${TERM_DOT} --json for data" "$(term_health "$ph_state" "$ph_text")"; } >&2
  fi
fi

# Not suppressed by -q: an unchecked package is an error to report, not chatter.
if [[ ${#UNCHECKED[@]} -gt 0 ]]; then
  echo "ERROR: ${#UNCHECKED[@]} package(s) NOT checked - unknown age is not a pass:" >&2
  printf '  %s\n' "${UNCHECKED[@]}" >&2
fi

[[ "$inside" -eq 1 ]] && exit "$EXIT_INSIDE"
[[ ${#UNCHECKED[@]} -gt 0 ]] && exit "$EXIT_UNAVAILABLE"
exit "$EXIT_OK"
