#!/usr/bin/env bash
# Surface open GitHub issues you may not have seen — externally-authored and stale.
#
# Read-only (gh issue list). Built to flag the blind spot: issues filed by someone
# other than the repo owner, and issues left untouched for a while. Designed to run
# advisory at push-time without ever gating the push.
#
# Usage:   check-issues.sh [--repo OWNER/REPO | --remote NAME] [--stale-days N]
#                          [--limit N] [--advisory] [--json] [-h|--help]
# Input:   argv only. Default repo = derived from the 'origin' remote of the cwd.
# Output:  stdout = data (human summary, or --json envelope). Framing on stderr.
# Stderr:  headers, the advisory banner, skip notices, errors.
# Exit:    0 nothing you're missing (no open issues, or all are yours and fresh)
#          2 usage
#          5 gh not installed (standalone mode; --advisory downgrades this to a skip)
#          7 unavailable — not a GitHub remote, gh not authed, offline, rate-limited,
#            or the lookup timed out (ADVISORY signal; never a real failure)
#          10 open external and/or stale issues present (the thing to look at)
#
# Examples:
#   check-issues.sh                                  # origin of the cwd
#   check-issues.sh --repo 0xDarkMatter/flarecrawl
#   check-issues.sh --remote origin --stale-days 14
#   check-issues.sh --json | jq '.data[] | select(.external)'
#   check-issues.sh --advisory --remote origin       # compact, silent when clean
set -uo pipefail

EX_OK=0; EX_USAGE=2; EX_MISSING_DEP=5; EX_UNAVAILABLE=7; EX_FINDINGS=10
GH_TIMEOUT="${GH_TIMEOUT:-15}"   # seconds; bounds the network call

# Terminal design system (skills/_lib/term.sh). Framing prints to stderr, so detect
# color on fd 2. Degrade to plain output if the shared lib isn't reachable.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2
else
  term_panel_open()  { printf '== %s %s ==\n' "${2:-}" "${3:-}"; }
  term_panel_close() { [ -n "${1:-}" ] && printf '%s\n' "$1"; }
  term_panel_vert()  { :; }
  term_panel_line()  { printf '  %s\n' "$*"; }
  term_color()       { shift; printf '%s' "$*"; }
  term_mark()        { case "${1:-}" in ok) printf '+';; bad|gap) printf 'x';; warn) printf '!';; skip|na) printf '-';; unknown) printf '?';; *) printf '.';; esac; }
  term_health()      { shift; printf '%s' "$*"; }
  TERM_ARROW="->"
fi

REPO=""; REMOTE="origin"; STALE_DAYS=30; LIMIT=50; ADVISORY=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       REPO="${2:?--repo needs OWNER/REPO}"; shift 2 ;;
    --remote)     REMOTE="${2:?--remote needs a name}"; shift 2 ;;
    --stale-days) STALE_DAYS="${2:?--stale-days needs N}"; shift 2 ;;
    --limit)      LIMIT="${2:?--limit needs N}"; shift 2 ;;
    --advisory)   ADVISORY=1; shift ;;
    --json)       JSON=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "$EX_OK" ;;
    *) echo "check-issues: unknown argument: $1" >&2; exit "$EX_USAGE" ;;
  esac
done

# In advisory mode, ANY inability to check is a silent skip (never disturb a push).
skip() { # message
  [ "$ADVISORY" -eq 1 ] || echo "check-issues: $1" >&2
  exit "$EX_UNAVAILABLE"
}

command -v gh >/dev/null 2>&1 || {
  [ "$ADVISORY" -eq 1 ] && exit "$EX_UNAVAILABLE"
  echo "check-issues: gh not installed (https://cli.github.com)" >&2
  exit "$EX_MISSING_DEP"
}

# Resolve OWNER/REPO from the remote if not given explicitly.
if [ -z "$REPO" ]; then
  url="$(git remote get-url "$REMOTE" 2>/dev/null)" || skip "no '$REMOTE' remote here"
  case "$url" in
    *github.com[:/]*)
      # strip everything up to github.com<sep>, then a trailing .git and/or slash
      REPO="$(printf '%s' "$url" | sed -E 's#^.*github\.com[:/]+##; s#\.git$##; s#/$##')" ;;
    *) skip "remote '$REMOTE' is not a github.com repo" ;;
  esac
fi
OWNER="${REPO%%/*}"

# Bounded, read-only lookup. Any failure (auth/offline/rate-limit/timeout) -> skip/7.
runner() { if command -v timeout >/dev/null 2>&1; then timeout "$GH_TIMEOUT" "$@"; else "$@"; fi; }
raw="$(runner gh issue list --repo "$REPO" --state open --limit "$LIMIT" \
        --json number,title,author,createdAt,updatedAt,labels 2>/dev/null)" \
  || skip "gh issue list failed for $REPO (not authed / offline / rate-limited?)"
[ -n "$raw" ] || skip "empty response from gh for $REPO"

# Classify with jq: external = author.login != owner; stale = updatedAt older than N days.
command -v jq >/dev/null 2>&1 || skip "jq not installed"
analysis="$(printf '%s' "$raw" | jq -c --arg owner "$OWNER" --argjson stale "$STALE_DAYS" '
  (now - ($stale * 86400)) as $cutoff
  | map(. + {
      external: (.author.login != $owner),
      stale: ((.updatedAt | sub("\\.[0-9]+";"") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < $cutoff)
    })
  | { total: length,
      flagged: map(select(.external or .stale)),
    }' 2>/dev/null)" || skip "could not parse gh output"

total="$(printf '%s' "$analysis" | jq -r '.total')"
flagged_n="$(printf '%s' "$analysis" | jq -r '.flagged | length')"

if [ "$JSON" -eq 1 ]; then
  printf '%s' "$analysis" | jq -c --arg repo "$REPO" \
    '{data: .flagged, meta: {repo: $repo, total_open: .total, flagged: (.flagged|length), schema: "claude-mods.github-ops.check-issues/v1"}}'
fi

# Human / advisory output (stderr framing; the data above is the stdout product).
if [ "$flagged_n" -eq 0 ]; then
  [ "$ADVISORY" -eq 1 ] || echo "check-issues: $REPO — $total open, none external or stale." >&2
  exit "$EX_OK"
fi

{
  term_panel_open github-ops "OPEN ISSUES" "$REPO  $flagged_n of $total flagged"
  term_panel_vert
  while IFS= read -r ln; do term_panel_line "$ln"; done < <(printf '%s' "$analysis" | jq -r --arg m "$(term_mark warn)" '.flagged[]
    | "\($m) #\(.number)  [\(if .external then "external" else "yours" end)\(if .stale then ",stale" else "" end)]  by \(.author.login)  \(.title)"')
  term_panel_vert
  term_panel_close \
    "$(term_color dim "${TERM_ARROW} gh issue view <n>    read-only, never blocks a push")" \
    "$(term_health warning "$flagged_n flagged")"
} >&2

exit "$EX_FINDINGS"
