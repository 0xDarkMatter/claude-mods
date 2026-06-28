#!/usr/bin/env bash
# Self-test for git-ops worktree provisioning. Offline + deterministic (git only,
# no network). Covers new-lane.sh (in-repo default, gitignore precondition,
# --sibling, main-anchoring, validate-before-mutate, arg hygiene) and the
# worktree-guard.sh `git clean` double-force detection.
# Resolves paths relative to itself so it runs in the repo and once installed.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures (SKIP+exit 0 if git is unavailable)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
NL="$SKILL/scripts/new-lane.sh"
# worktree-guard.sh lives in the repo's hooks/ — resolve for both repo + installed layouts.
GUARD=""
for c in "$SKILL/../../hooks/worktree-guard.sh" "$HOME/.claude/hooks/worktree-guard.sh"; do
  [ -f "$c" ] && { GUARD="$c"; break; }
done

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
P=0; F=0
ok(){ P=$((P+1)); printf '  PASS  %s\n' "$1"; }
no(){ F=$((F+1)); printf '  FAIL  %s\n' "$1"; }
mkrepo(){ rm -rf "$1"; git init -q -b main "$1"; git -C "$1" config user.email t@t
  git -C "$1" config user.name t; git -C "$1" config core.autocrlf false
  echo base > "$1/f"; git -C "$1" add -A; git -C "$1" commit -qm init; }

echo "=== git-ops new-lane / worktree-guard self-test ==="

echo "-- new-lane: in-repo default + gitignore precondition --"
mkrepo "$SB/A"; cd "$SB/A"
OUT="$(bash "$NL" auth-refactor 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && ok "exit 0" || no "exit $rc"
case "$OUT" in */.claude/worktrees/auth-refactor) ok "stdout = in-repo path only";; *) no "stdout=[$OUT]";; esac
[ -d "$SB/A/.claude/worktrees/auth-refactor" ] && ok "lane dir created in-repo" || no "lane dir missing"
git check-ignore -q .claude/worktrees/.x && ok ".claude/worktrees/ now gitignored" || no "gitignore not ensured"
git show-ref --verify --quiet refs/heads/lane/auth-refactor && ok "branch lane/auth-refactor" || no "branch missing"

echo "-- new-lane: no duplicate gitignore on second lane --"
before=$(grep -c worktrees .gitignore); bash "$NL" hotfix main >/dev/null 2>&1
[ "$before" = "$(grep -c worktrees .gitignore)" ] && ok "gitignore not duplicated" || no "gitignore duplicated"

echo "-- new-lane: blanket .claude/ ignore is respected (no append) --"
mkrepo "$SB/B"; cd "$SB/B"; printf '.claude/\n' > .gitignore; git add .gitignore; git commit -qm ig
sz=$(wc -c <.gitignore); bash "$NL" x >/dev/null 2>&1
[ "$sz" = "$(wc -c <.gitignore)" ] && ok "blanket .claude/ -> gitignore untouched" || no "appended despite blanket ignore"

echo "-- new-lane: --sibling places outside the repo --"
mkrepo "$SB/S"; cd "$SB/S"
OS="$(bash "$NL" --sibling big 2>/dev/null)"
[ "$OS" = "$SB/S-big" ] && ok "sibling path = $OS" || no "sibling=[$OS]"
[ -d "$SB/S-big" ] && ok "sibling dir outside repo" || no "sibling dir missing"

echo "-- new-lane: anchors at MAIN when invoked from inside a lane (no nesting) --"
mkrepo "$SB/N"; cd "$SB/N"; L1="$(bash "$NL" first 2>/dev/null)"
( cd "$L1" && bash "$NL" second >/dev/null 2>&1 )
[ -d "$SB/N/.claude/worktrees/second" ] && ok "lane anchored to MAIN" || no "did not anchor to MAIN"
[ ! -d "$L1/.claude/worktrees/second" ] && ok "no nested worktree inside the lane" || no "nested worktree leaked"

echo "-- new-lane: validate-before-mutate + arg hygiene --"
mkrepo "$SB/V"; cd "$SB/V"
bash "$NL" lane1 no-such-branch >/dev/null 2>/dev/null; ee=$?
[ $ee -eq 2 ] && ok "invalid base -> exit 2" || no "invalid base exit $ee"
[ ! -f .gitignore ] && ok "invalid base left no .gitignore" || no "partial gitignore on bad base"
bash "$NL" --frobnicate slug >/dev/null 2>/dev/null; ee=$?
[ $ee -eq 2 ] && ok "unknown flag -> exit 2" || no "unknown flag exit $ee"
[ -z "$(git branch --list 'lane/*')" ] && ok "unknown flag created no branch" || no "stray branch from bad flag"
mkrepo "$SB/V2"; cd "$SB/V2"; git branch lane/dup
bash "$NL" dup >/dev/null 2>/dev/null; ee=$?
[ $ee -eq 1 ] && ok "existing branch -> exit 1" || no "dup exit $ee"
[ ! -f .gitignore ] && ok "conflict left no .gitignore" || no "partial gitignore on conflict"
bash "$NL" >/dev/null 2>/dev/null; [ $? -eq 2 ] && ok "no slug -> exit 2" || no "empty not exit 2"

echo "-- new-lane: slug sanitised; syntax clean --"
mkrepo "$SB/Z"; cd "$SB/Z"
bash "$NL" "Feat Foo/Bar" >/dev/null 2>&1
git show-ref --verify --quiet refs/heads/lane/feat-foobar && ok "slug 'Feat Foo/Bar' -> lane/feat-foobar" || no "slug sanitise wrong: $(git branch --list 'lane/*')"
bash -n "$NL" && ok "new-lane.sh syntax OK" || no "new-lane.sh syntax error"

if [ -n "$GUARD" ]; then
  echo "-- worktree-guard: git clean force-level detection --"
  bash -n "$GUARD" && ok "worktree-guard.sh syntax OK" || no "guard syntax error"
  WG="$SB/WG"; mkrepo "$WG"; mkdir -p "$WG/.claude/worktrees"
  gclean(){ local o; o=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$WG" | bash "$GUARD" 2>&1)
    if [ "$2" = warn ]; then case "$o" in *double-force*) ok "guard WARN: $1";; *) no "guard expected WARN: $1 [${o:-silent}]";; esac
    else [ -z "$o" ] && ok "guard silent: $1" || no "guard expected silent: $1"; fi; }
  gclean "git clean -fdx"            silent
  gclean "git clean -ffdx"          warn
  gclean "git clean --force --force" warn
  gclean "git clean -f -f"          warn
  gclean "git clean -fd -fx"        warn
  gclean "git clean --force -f"     warn
  gclean "git clean -n"             silent
  gclean "git clean -fd ./somepath" silent
  # exemption: a session whose cwd is inside a worktree is not warned
  ex=$(printf '{"tool_input":{"command":"git clean -ffdx"},"cwd":"%s/.claude/worktrees/foo"}' "$WG" | bash "$GUARD" 2>&1)
  [ -z "$ex" ] && ok "guard exempt inside own worktree" || no "guard warned inside own worktree"
  # existing rules unregressed
  for c in "git add -A" "rm -rf .claude/worktrees/foo" "git worktree remove .claude/worktrees/foo"; do
    o=$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$c" "$WG" | bash "$GUARD" 2>&1)
    [ -n "$o" ] && ok "guard still warns: $c" || no "guard regressed: $c"
  done
else
  echo "  SKIP  worktree-guard.sh not found (hooks/ unavailable in this layout)"
fi

echo "=== $P passed, $F failed ==="
[ $F -eq 0 ]
