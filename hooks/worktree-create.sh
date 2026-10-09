#!/bin/bash
# hooks/worktree-create.sh
# WorktreeCreate hook — put Claude Code's own worktrees (--worktree, isolation:
# worktree subagents, background sessions) at $WORKTREE_ROOT/<repo>/<name>
# instead of <repo>/.claude/worktrees/<name>. Pair: hooks/worktree-remove.sh.
# Rule: rules/worktree-boundaries.md "Lane location".
#
# EVENT CONTRACT (https://code.claude.com/docs/en/hooks#worktreecreate,
# https://code.claude.com/docs/en/worktrees, checked 2026-10-09):
#   stdin   JSON: the common fields (cwd, session_id, ...) plus `name`, a slug
#           such as "bold-oak-a3f2" or the user's --worktree argument.
#   stdout  the absolute worktree path as the LAST non-empty line. Nothing else
#           may reach stdout, so every git call below writes to stderr.
#   exit    any non-zero exit, or no path, FAILS creation. There is no fallback
#           to Claude Code's own git logic: a broken hook blocks every worktree
#           creation on the machine. Keep it boring.
#   The hook REPLACES git's worktree logic entirely, so it re-implements what
#   Claude Code did: branch `worktree-<name>`; base per `worktree.baseRef`;
#   reopen an existing worktree of that name; copy `.worktreeinclude` matches.
#   Claude Code refuses a hook path inside any git repo that carries no git
#   metadata of its own, and one with `.`/`..` segments: we return a real linked
#   worktree, normalised, so both checks pass.
#
# BEHAVIOUR
#   WORKTREE_ROOT set    -> $WORKTREE_ROOT/<repo>/<name>; <repo> = the MAIN
#                           checkout's dir name (stable from inside a lane).
#   WORKTREE_ROOT unset  -> <main>/.claude/worktrees/<name>, Claude Code's own
#                           default, with a stderr note. Install this hook only
#                           where WORKTREE_ROOT is set; the fallback exists so a
#                           stray install degrades instead of blocking.
#   Base ref: WORKTREE_BASE_REF (fresh|head) wins; else `worktree.baseRef` from
#     <project>/.claude/settings.local.json, <project>/.claude/settings.json,
#     then ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json; else "fresh".
#     fresh = origin/HEAD, after a 5 s non-interactive fetch when FETCH_HEAD is
#             over 24 h old; falls back to the cwd's HEAD (no remote, no ref).
#     head  = the cwd's HEAD (inside a worktree: that worktree's HEAD).
#   Reopen: a dir that is already a worktree of this repo is returned as-is, at
#     its old tip (Claude Code's reset-to-default-branch case is NOT emulated);
#     a branch worktree-<name> without a dir is re-attached; any other existing
#     path is refused, never clobbered.
#   New branches start at a commit id, so they never track origin/<default>.
#   .worktreeinclude (main checkout root, .gitignore syntax): copies files that
#     match a pattern AND are gitignored, never tracked ones; existing files win.
#
# Exit: 0 path printed | 1 refused or failed (reason on stderr).
# Tests: tests/hooks.sh "worktree-create / worktree-remove".
set -uo pipefail

die() { echo "worktree-create: $*" >&2; exit 1; }
# Git's own path form (X:/a/b on Windows): what Claude Code can enter, and what
# git prints back. A shell form (/x/a/b) would be a different directory string.
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else printf '%s' "$1"; fi
}

command -v jq >/dev/null 2>&1 || die "jq is required to read the hook input"
RAW="$(cat)"
NAME="$(printf '%s' "$RAW" | jq -r '.name // empty' 2>/dev/null | tr -d '\r')"
CWD="$(printf '%s' "$RAW" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')"
[[ -n "$CWD" ]] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
[[ -n "$NAME" ]] || die "no worktree name in the hook input"

# One path segment: anything outside [A-Za-z0-9._-] becomes '-', and no leading
# dot (no '.', '..', or hidden dirs). Claude Code's names are slugs already.
SLUG="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-')"
SLUG="${SLUG#"${SLUG%%[!.]*}"}"
[[ -n "$SLUG" ]] || die "worktree name '$NAME' is empty after sanitising"
BRANCH="worktree-$SLUG"

TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || die "cwd '$CWD' is not inside a git work tree"
COMMON="$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || COMMON="$(cd "$CWD" && cd "$(git rev-parse --git-common-dir)" && pwd)" \
  || die "cannot resolve the git common dir from '$CWD'"
MAIN="$(native "$(dirname "$COMMON")")"
REPO="$(basename "$MAIN")"
g() { git -C "$MAIN" "$@"; }

if [[ -n "${WORKTREE_ROOT:-}" ]]; then
  ROOT="${WORKTREE_ROOT//\\//}"; ROOT="${ROOT%/}"
  WT="$(native "$ROOT")/$REPO/$SLUG"
else
  WT="$MAIN/.claude/worktrees/$SLUG"
  echo "worktree-create: WORKTREE_ROOT is unset - using Claude Code's default $WT" >&2
fi
WT="${WT//\/\///}"

# --- reopen -------------------------------------------------------------------
lc() { local p=${1//\\//}; p=${p%/}; printf '%s' "$p" | tr '[:upper:]' '[:lower:]'; }
registered() {   # is $1 a worktree git knows, for this repo?
  local want regs w
  want="$(lc "$1")"
  regs="$(g worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')" || return 1
  while IFS= read -r w; do
    [[ -n "$w" && "$(lc "$(native "$w")")" == "$want" ]] && return 0
  done <<< "$regs"
  return 1
}
if [[ -e "$WT" ]]; then
  registered "$WT" || die "'$WT' exists but is not a worktree of $MAIN - refusing to reuse it"
  echo "worktree-create: reopening existing worktree $WT" >&2
  printf '%s\n' "$WT"
  exit 0
fi

# --- base ref -----------------------------------------------------------------
setting_base_ref() {
  local cfg f v
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  for f in "$TOP/.claude/settings.local.json" "$TOP/.claude/settings.json" "$cfg/settings.json"; do
    [[ -f "$f" ]] || continue
    v="$(jq -r '.worktree.baseRef // empty' "$f" 2>/dev/null | tr -d '\r')"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  return 1
}
MODE="${WORKTREE_BASE_REF:-$(setting_base_ref || echo fresh)}"
case "$MODE" in fresh|head) ;; *) echo "worktree-create: unknown baseRef '$MODE', using fresh" >&2; MODE=fresh ;; esac

BASE=""
if [[ "$MODE" == fresh ]] && g remote get-url origin >/dev/null 2>&1; then
  # Claude Code's rule: refresh origin/HEAD when not fetched in 24 h, capped at
  # 5 s and never prompting (a password or host-key prompt counts as failure).
  fh="$COMMON/FETCH_HEAD"
  if [[ ! -f "$fh" || -n "$(find "$fh" -mmin +1440 2>/dev/null)" ]]; then
    export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
    tmo=(); command -v timeout >/dev/null 2>&1 && tmo=(timeout 5)
    g rev-parse --verify --quiet refs/remotes/origin/HEAD >/dev/null \
      || ${tmo[@]+"${tmo[@]}"} git -C "$MAIN" remote set-head origin --auto >/dev/null 2>&1 || true
    def="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
    [[ -n "$def" ]] && { ${tmo[@]+"${tmo[@]}"} git -C "$MAIN" fetch --quiet origin "${def#origin/}" >/dev/null 2>&1 || true; }
  fi
  BASE="$(g rev-parse --verify --quiet 'refs/remotes/origin/HEAD^{commit}' 2>/dev/null)"
fi
[[ -n "$BASE" ]] || BASE="$(git -C "$CWD" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" \
  || die "no base commit: '$CWD' has no HEAD"
[[ -n "$BASE" ]] || die "no base commit: '$CWD' has no HEAD"

# --- create -------------------------------------------------------------------
mkdir -p "$(dirname "$WT")" || die "cannot create $(dirname "$WT")"
if g show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "worktree-create: re-attaching existing branch $BRANCH" >&2
  g worktree add "$WT" "$BRANCH" >&2 || die "git worktree add $WT $BRANCH failed"
else
  g worktree add -b "$BRANCH" "$WT" "$BASE" >&2 || die "git worktree add -b $BRANCH $WT failed"
fi

# --- .worktreeinclude ------------------------------------------------------------
# ls-files -o -i lists UNTRACKED files matching the include patterns; check-ignore
# then keeps only the gitignored ones, as Claude Code does. A copy failure is a
# warning, never a failed creation: the worktree itself is fine.
if [[ -f "$MAIN/.worktreeinclude" ]]; then
  n=0
  # procsub ok: a listing that dies part-way copies fewer files, never a wrong
  # one, and copying is best-effort by contract (see above).
  while IFS= read -r -d '' f; do
    [[ -e "$WT/$f" ]] && continue
    if mkdir -p "$WT/$(dirname "$f")" && cp -p "$MAIN/$f" "$WT/$f"; then n=$((n + 1))
    else echo "worktree-create: could not copy $f" >&2; fi
  done < <(g ls-files -z --others --ignored --exclude-from="$MAIN/.worktreeinclude" 2>/dev/null \
             | g check-ignore -z --stdin 2>/dev/null)
  [[ $n -gt 0 ]] && echo "worktree-create: copied $n .worktreeinclude file(s)" >&2
fi

echo "worktree-create: $WT on $BRANCH (base $MODE: ${BASE:0:12})" >&2
printf '%s\n' "$WT"
