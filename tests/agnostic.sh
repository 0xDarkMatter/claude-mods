#!/usr/bin/env bash
# claude-mods :: tests/agnostic.sh
#
# WHY THIS EXISTS
#   claude-mods is public. Authoring happens on real machines, so an author's
#   username, hostname, drive layout and private project names leak into examples
#   and sample output very easily - and none of it is useful to anyone else. A
#   2026-08-25 sweep found leaks in nine files; prose asking people to "keep it
#   agnostic" had not prevented any of them. This gate is the enforcement layer,
#   and it runs in `just check` / `just check-fast` and CI.
#
# WHY THE PERSONAL PATTERNS ARE NOT IN THIS FILE
#   A public gate that lists "the author's hostname, account and project names"
#   in order to catch them publishes exactly what it exists to protect. So this
#   script carries only GENERIC patterns. Identifiers specific to one author live
#   in a PRIVATE deny list that is never committed - first one found wins:
#     1. $AGNOSTIC_DENY_FILE                 (explicit override)
#     2. tests/agnostic-deny.local           (gitignored, per checkout)
#     3. ~/.claude/agnostic-deny.txt         (per machine - covers every worktree)
#   One regex per line in ripgrep's default (Rust) syntax - \b and classes work,
#   lookaround does not - matched case-insensitively; '#' starts a comment.
#   CI has no private list and runs the generic checks only.
#
# LEGITIMATE EXCEPTIONS
#   tests/agnostic-allow.txt - committed. Each entry is `<path>:<line-regex>`,
#   preceded by a `# reason` comment. A hit is suppressed only if it is in that
#   exact file AND its line matches the regex - never a whole-file bypass.
#   CHANGELOG.md and docs/plans/ are excluded outright: they are historical
#   records, and rewriting them would falsify the history that explains why
#   things moved.
#
# FAILURE MODES THIS GATE REFUSES TO HIDE (each one has bitten it)
#   - rg exit 2 (bad pattern/flag) is an ERROR, never "no matches".
#   - `rg --path-separator /` is not used: Git Bash rewrites a bare `/` argument to
#     its install dir, which once made every scan error silently and report PASS.
#   - A run that can see 0 files fails instead of passing vacuously.
#   - No PCRE2 dependency: distro ripgrep builds may lack it.
#
# Usage:  bash tests/agnostic.sh
# Exit :  0 clean, 1 leak found or gate could not run
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1

FAIL=0
# --no-ignore-parent: lane worktrees live under the parent checkout's gitignored
# `.claude/worktrees/`, and rg honours parent ignore files by default - without
# this flag a run from a worktree scans nothing.
EXCLUDES=(
  --no-ignore-parent
  --glob '!.git/**'
  --glob '!.claude/**'
  --glob '!CHANGELOG.md'
  --glob '!docs/plans/**'
  --glob '!tests/agnostic.sh'
  --glob '!tests/agnostic-allow.txt'
  --glob '!tests/agnostic-deny.local'
)

# --- allowlist: parallel arrays of exact path + line regex (bash ERE) ---
ALLOW_PATHS=(); ALLOW_RES=()
if [ -f tests/agnostic-allow.txt ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    ALLOW_PATHS+=("${line%%:*}"); ALLOW_RES+=("${line#*:}")
  done < tests/agnostic-allow.txt
fi

allowed() {   # $1 = path, $2 = line text
  local i
  for i in "${!ALLOW_PATHS[@]}"; do
    [ "${ALLOW_PATHS[$i]}" = "$1" ] && [[ "$2" =~ ${ALLOW_RES[$i]} ]] && return 0
  done
  return 1
}

# True when every /Users/<name> on the line is a placeholder or a system folder
# (`/Users/me`, `C:\Users\Public`), so only real-looking names count as leaks.
users_placeholder_only() {   # $1 = line text
  local t="$1" re='[\/\\]Users[\/\\]([A-Za-z][A-Za-z0-9._-]*)' name whole real=0
  shopt -s nocasematch
  while [[ $t =~ $re ]]; do
    whole="${BASH_REMATCH[0]}"; name="${BASH_REMATCH[1]}"
    # prose punctuation is not part of a name: "C:/Users/x." is the placeholder x
    while [[ "$name" == *[._-] ]]; do name="${name%?}"; done
    case "$name" in
      me|you|user|username|name|yourname|your-name|example|runner|shared|public|default|all|x) ;;
      *) real=1 ;;
    esac
    t="${t#*"$whole"}"
  done
  shopt -u nocasematch
  [ "$real" -eq 0 ]
}

# scan <label> <skip-fn|-> <rg args...> : report non-allowlisted hits as leaks.
# skip-fn (optional) gets the line text and returns 0 to drop a hit.
scan() {
  local label="$1" skip="$2"; shift 2
  local hits=() h path rest text out rc errf
  errf="$(mktemp)"
  out="$(rg -n --no-heading "$@" "${EXCLUDES[@]}" . 2>"$errf")"; rc=$?
  if [ "$rc" -ge 2 ]; then
    printf "  [ERROR] %s - rg failed (exit %s): %s\n" "$label" "$rc" "$(head -c 300 "$errf")"
    rm -f "$errf"; FAIL=1; return
  fi
  rm -f "$errf"
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    path="${h%%:*}"; path="${path//\\//}"; path="${path#./}"; rest="${h#*:}"; text="${rest#*:}"
    allowed "$path" "$text" && continue
    [ "$skip" != "-" ] && "$skip" "$text" && continue
    hits+=("$path:$rest")
  done <<< "$out"
  if [ "${#hits[@]}" -gt 0 ]; then
    printf "  [LEAK] %s\n" "$label"; printf "         %s\n" "${hits[@]}" | cut -c1-200
    FAIL=1
  else
    printf "  [ok] %s\n" "$label"
  fi
}

echo "=== claude-mods :: agnostic gate ==="

if ! command -v rg >/dev/null 2>&1; then
  echo "  [ERROR] ripgrep (rg) is required"; exit 1
fi
# Refuse to pass vacuously: if nothing is in scope, the scan proves nothing.
nfiles="$(rg --files "${EXCLUDES[@]}" . 2>/dev/null | wc -l | tr -d ' ')"
if [ "${nfiles:-0}" -eq 0 ]; then
  echo "  [ERROR] scanned 0 files - the gate cannot see the repo (ignore rules?)"
  exit 1
fi
echo "  [info] scanning $nfiles files"

# --- 1. User-profile paths carrying a real-looking name (generic) ---
# macOS / Windows home folders are `Users` with a capital U, so the match is
# case-SENSITIVE (lower-case /users/... is an API route, not a home dir).
scan "no user-profile paths with a real name" users_placeholder_only \
  -e '[\\/]Users[\\/][A-Za-z][A-Za-z0-9._-]*'

# --- 2. Private deny list (author-specific identifiers; never committed) ---
deny=""
for cand in "${AGNOSTIC_DENY_FILE:-}" tests/agnostic-deny.local "$HOME/.claude/agnostic-deny.txt"; do
  [ -n "$cand" ] && [ -f "$cand" ] && { deny="$cand"; break; }
done
if [ -n "$deny" ]; then
  pats=()
  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"
    case "$p" in ''|'#'*) continue ;; esac
    pats+=(-e "$p")
  done < "$deny"
  if [ "${#pats[@]}" -gt 0 ]; then
    scan "no identifiers from the private deny list ($(( ${#pats[@]} / 2 )) patterns)" - -i "${pats[@]}"
  fi
else
  echo "  [info] no private deny list - generic checks only (see header for locations)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== PASS: repo is agnostic ==="
else
  echo "=== FAIL: replace the values above with placeholders, or - if one is a"
  echo "    legitimate example - add a reasoned entry to tests/agnostic-allow.txt ==="
fi
exit "$FAIL"
