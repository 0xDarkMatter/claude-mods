#!/usr/bin/env bash
# Staleness verifier for GitHub Actions `uses:` references in workflow YAML.
#
# Lints every `uses: owner/repo@ref` line in one or more workflow files. General-
# purpose: not terraform-specific — point it at any GitHub Actions workflow. Two
# modes per the staleness-verifier pattern (SKILL-RESOURCE-PROTOCOL §7):
#   --offline (default): structural-only, NO network. Asserts every `uses:` is
#                        well-formed; floating @main/@master refs are a WARNING.
#   --live:              resolves every owner/repo@ref against the GitHub API.
#                        A 404 (ref does not exist) is DRIFT; rate-limit/offline
#                        is UNAVAILABLE (advisory, never a build failure).
#
# Usage:   check-action-refs.sh [--offline|--live] [--strict] [--json] [-q] [FILE ...]
# Input:   workflow YAML paths as positionals (default: the skill's own
#          assets/github-actions-terraform.yml). Pure grep/sed extraction — no
#          YAML library dependency.
# Output:  stdout = data only (findings list, or JSON envelope with --json)
# Stderr:  headers, progress, warnings, errors
# Exit:    0 ok, 2 usage, 3 not-found, 4 malformed-uses, 5 missing-dep or an
#          input file grep could not read, 7 api-unavailable (live), 10 drift
#          (live: a ref does not resolve)
#
# Examples:
#   check-action-refs.sh --offline
#   check-action-refs.sh --offline .github/workflows/ci.yml
#   GITHUB_TOKEN=ghp_xxx check-action-refs.sh --live ci.yml deploy.yml
#   check-action-refs.sh --json --offline | jq '.data[] | select(.status!="ok")'

set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_NOT_FOUND=3; EXIT_MALFORMED=4
EXIT_MISSING_DEP=5; EXIT_UNAVAILABLE=7; EXIT_DRIFT=10

# Terminal design system (skills/_lib/term.sh). Framing rides stderr (term_init 2);
# the findings list / --json stay plain on stdout. Degrade if the lib is gone.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2; __HAVE_TERM=1
else __HAVE_TERM=0; TERM_DOT="|"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FILE="${SCRIPT_DIR}/../assets/github-actions-terraform.yml"

MODE="offline"; STRICT=0; JSON=0; QUIET=0; FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)   MODE="offline" ;;
    --live)      MODE="live" ;;
    --strict)    STRICT=1 ;;
    --json)      JSON=1 ;;
    -q|--quiet)  QUIET=1 ;;
    -h|--help)   sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -*)  echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)   FILES+=("$1") ;;
  esac
  shift
done

[[ ${#FILES[@]} -eq 0 ]] && FILES=("$DEFAULT_FILE")

command -v grep >/dev/null 2>&1 || { echo "ERROR: grep required" >&2; exit "$EXIT_MISSING_DEP"; }
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
[[ "$JSON" -eq 1 && "$HAS_JQ" -eq 0 ]] && {
  echo '{"error":{"code":"PRECONDITION","message":"jq required for --json"}}'
  echo "ERROR: jq required for --json" >&2; exit "$EXIT_MISSING_DEP"; }
if [[ "$MODE" == "live" ]]; then
  command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for --live" >&2; exit "$EXIT_MISSING_DEP"; }
fi

emit() { [[ "$QUIET" -eq 1 ]] && return; printf '%s\n' "$1" >&2; }

# Panel framing applies to the human stderr stream when it's a TTY (or FORCE_COLOR
# forces a render); piped/quiet consumers keep the legacy "=== / [TAG]" lines.
PANEL=0
if [[ "$__HAVE_TERM" -eq 1 && "$QUIET" -eq 0 ]] && { [ -t 2 ] || [ -n "${FORCE_COLOR:-}" ]; }; then PANEL=1; fi
__PANEL_OPEN=0
popen() {
  [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 0 ]] || return 0
  { term_panel_open terraform "action-refs ${TERM_DOT} ${MODE}"; term_panel_vert; } >&2
  __PANEL_OPEN=1
}
# prow <mark> <legacy-prefix> <text> — panel status row, or the legacy tagged line.
prow() {
  if [[ "$PANEL" -eq 1 ]]; then popen; term_status_row "$1" "$3" >&2
  else emit "  $2 $3"; fi
}

# State accumulators
malformed=0; drift=0; unavailable=0; warned=0
declare -a JSON_OBJS=()
declare -a TEXT_ROWS=()

# --- classify a `uses:` value -------------------------------------------------
# Sets globals: C_STATUS (ok|warn|malformed), C_OWNER, C_REPO, C_REF, C_KIND
classify_uses() {
  local v=$1
  C_OWNER=""; C_REPO=""; C_REF=""; C_KIND=""; C_STATUS="ok"
  # Local action: ./path  — always valid, no network
  if [[ "$v" == ./* ]]; then C_KIND="local"; return; fi
  # Docker action: docker://image[:tag]  — out of scope for ref resolution
  if [[ "$v" == docker://* ]]; then C_KIND="docker"; return; fi
  # Must contain an @ separating owner/repo[/path] from ref
  if [[ "$v" != *"@"* ]]; then C_STATUS="malformed"; C_KIND="action"; return; fi
  local path="${v%@*}" ref="${v#*@}"
  C_REF="$ref"
  # Empty ref, or empty path
  if [[ -z "$ref" || -z "$path" ]]; then C_STATUS="malformed"; C_KIND="action"; return; fi
  # path must be owner/repo[/subpath...]
  if [[ "$path" != */* ]]; then C_STATUS="malformed"; C_KIND="action"; return; fi
  C_OWNER="${path%%/*}"
  local rest="${path#*/}"
  C_REPO="${rest%%/*}"
  C_KIND="action"
  if [[ -z "$C_OWNER" || -z "$C_REPO" ]]; then C_STATUS="malformed"; return; fi
  # Validate ref shape: tag (vN / vN.N.N...), 40-hex SHA, or branch name.
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    C_STATUS="ok"          # pinned SHA — best practice
  elif [[ "$ref" == "main" || "$ref" == "master" ]]; then
    C_STATUS="warn"        # floating default branch — advisory
  elif [[ "$ref" =~ ^v[0-9]+([._][0-9]+)*$ ]]; then
    C_STATUS="ok"          # version tag
  elif [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    C_STATUS="ok"          # other tag/branch name — structurally fine
  else
    C_STATUS="malformed"
  fi
}

# --- live resolution: does owner/repo@ref exist on GitHub? --------------------
# Echoes one of: resolved | notfound | unavailable
resolve_ref() {
  local owner=$1 repo=$2 ref=$3
  local -a auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  local base="https://api.github.com/repos/${owner}/${repo}"
  local code body url

  try() {
    local u=$1 out
    out=$(curl -sS -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${auth[@]}" "$u" 2>/dev/null)
    [[ -z "$out" ]] && { echo "000"; return; }
    code="${out##*$'\n'}"; body="${out%$'\n'*}"
    echo "$code"
  }

  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    url="${base}/commits/${ref}"
  else
    url="${base}/git/ref/tags/${ref}"
  fi
  code=$(try "$url")
  # Network failure
  [[ "$code" == "000" ]] && { echo "unavailable"; return; }
  # Rate limit — advisory, never drift
  if [[ "$code" == "403" || "$code" == "429" ]]; then echo "unavailable"; return; fi
  if [[ "$code" == "200" ]]; then echo "resolved"; return; fi
  # Tag lookup 404'd — fall back to a commit/branch lookup before declaring drift.
  # A non-SHA ref can still be a branch name; the commits endpoint resolves those.
  if [[ "$code" == "404" && ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    code=$(try "${base}/commits/${ref}")
    [[ "$code" == "000" ]] && { echo "unavailable"; return; }
    if [[ "$code" == "403" || "$code" == "429" ]]; then echo "unavailable"; return; fi
    [[ "$code" == "200" ]] && { echo "resolved"; return; }
    # 404 (no such branch) or 422 (unparseable commit-ish) — the ref does not exist
    [[ "$code" == "404" || "$code" == "422" ]] && { echo "notfound"; return; }
    echo "unavailable"; return
  fi
  # Direct SHA lookup that 404/422'd, or a tag 404 with no branch fallback path
  [[ "$code" == "404" || "$code" == "422" ]] && { echo "notfound"; return; }
  echo "unavailable"
}

add_json() {  # file line ref status
  [[ "$HAS_JQ" -eq 1 ]] || return
  JSON_OBJS+=("$(jq -cn --arg f "$1" --argjson l "$2" --arg r "$3" --arg s "$4" \
    '{file:$f, line:$l, ref:$r, status:$s}')")
}

if [[ "$PANEL" -eq 1 ]]; then popen; else emit "=== check-action-refs (${MODE}) ==="; fi

for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    prow bad "ERROR:" "file not found: $f"
    # In JSON mode still report a structured error per §5
    if [[ "$JSON" -eq 1 ]]; then
      echo "{\"error\":{\"code\":\"NOT_FOUND\",\"message\":\"file not found: $f\"}}"
    fi
    exit "$EXIT_NOT_FOUND"
  fi

  # Extract every `uses:` value with its 1-based line number. Strip inline
  # comments and surrounding quotes. grep -n gives "LINE:content".
  # procsub guard: grep's status is checked before its rows are used. Fed straight
  # into the loop via `< <(grep ...)`, a grep that could not read the file (exit 2)
  # looked like a workflow with no `uses:` lines (exit 1) and the run said "refs
  # well-formed". -a: one NUL byte otherwise makes GNU grep call the file binary
  # and print "Binary file ... matches" (3.0, stdout) or nothing (3.5+) instead of
  # the lines, so its refs went unchecked.
  rc=0
  uses_rows="$(grep -anE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*' "$f" 2>/dev/null)" || rc=$?
  if (( rc > 1 )); then
    prow bad "ERROR:" "could not read $f (grep exit $rc)"
    if [[ "$JSON" -eq 1 ]]; then
      echo "{\"error\":{\"code\":\"PRECONDITION\",\"message\":\"could not read $f (grep exit $rc)\"}}"
    fi
    exit "$EXIT_MISSING_DEP"
  fi
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    lineno="${entry%%:*}"
    rawline="${entry#*:}"
    # value after `uses:` — drop leading `- ` list dash if present
    val="${rawline#*uses:}"
    val="${val%%#*}"                       # strip trailing comment
    # trim whitespace
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    # strip surrounding quotes
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    [[ -z "$val" ]] && continue

    classify_uses "$val"

    case "$C_STATUS" in
      malformed)
        malformed=1
        prow bad "[MALFORMED]" "${f}:${lineno}  uses: ${val}"
        TEXT_ROWS+=("${f}:${lineno}	${val}	malformed")
        add_json "$f" "$lineno" "$val" "malformed"
        ;;
      warn)
        warned=1
        prow warn "[WARN floating]" "${f}:${lineno}  ${val}  (prefer SHA pin)"
        TEXT_ROWS+=("${f}:${lineno}	${val}	warn")
        add_json "$f" "$lineno" "$val" "warn"
        ;;
      ok)
        if [[ "$MODE" == "live" && "$C_KIND" == "action" ]]; then
          res=$(resolve_ref "$C_OWNER" "$C_REPO" "$C_REF")
          case "$res" in
            resolved)
              prow ok "[ok]" "${f}:${lineno}  ${C_OWNER}/${C_REPO}@${C_REF}"
              TEXT_ROWS+=("${f}:${lineno}	${val}	ok")
              add_json "$f" "$lineno" "$val" "ok" ;;
            notfound)
              drift=1
              prow bad "[DRIFT 404]" "${f}:${lineno}  ${C_OWNER}/${C_REPO}@${C_REF}"
              TEXT_ROWS+=("${f}:${lineno}	${val}	drift")
              add_json "$f" "$lineno" "$val" "drift" ;;
            unavailable)
              unavailable=1
              prow warn "[unavailable]" "${f}:${lineno}  ${C_OWNER}/${C_REPO}@${C_REF} (API unreachable/rate-limited)"
              TEXT_ROWS+=("${f}:${lineno}	${val}	unavailable")
              add_json "$f" "$lineno" "$val" "unavailable" ;;
          esac
        else
          TEXT_ROWS+=("${f}:${lineno}	${val}	ok")
          add_json "$f" "$lineno" "$val" "ok"
        fi
        ;;
    esac
  done <<< "$uses_rows"
done

# --- panel footer (stderr framing only) ---------------------------------------
if [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 1 ]]; then
  ph_state="healthy"; ph_text="refs well-formed"
  if [[ "$malformed" -eq 1 || "$drift" -eq 1 ]]; then ph_state="critical"; ph_text="findings present"
  elif [[ "$unavailable" -eq 1 ]]; then ph_state="warning"; ph_text="api unavailable"
  elif [[ "$warned" -eq 1 ]]; then ph_state="warning"; ph_text="floating refs"; fi
  { term_panel_vert
    term_panel_close "--live to resolve ${TERM_DOT} --json for data" "$(term_health "$ph_state" "$ph_text")"
  } >&2
fi

# --- output -------------------------------------------------------------------
if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "${JSON_OBJS[@]:-}" | jq -s \
    --arg mode "$MODE" \
    '{data: map(select(length>0)),
      meta: {mode:$mode,
             count:(map(select(length>0))|length),
             schema:"claude-mods.terraform-ops.action-refs/v1"}}'
else
  # plain text: data rows to stdout (only the non-ok findings are interesting,
  # but emit all rows so the agent sees the full inventory)
  for row in "${TEXT_ROWS[@]:-}"; do
    [[ -n "$row" ]] && printf '%s\n' "$row"
  done
fi

# --- exit ---------------------------------------------------------------------
[[ "$malformed" -eq 1 ]] && exit "$EXIT_MALFORMED"
[[ "$drift" -eq 1 ]] && exit "$EXIT_DRIFT"
[[ "$unavailable" -eq 1 ]] && exit "$EXIT_UNAVAILABLE"
if [[ "$warned" -eq 1 && "$STRICT" -eq 1 ]]; then exit "$EXIT_MALFORMED"; fi
exit "$EXIT_OK"
