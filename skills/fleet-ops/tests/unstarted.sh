# Sourced by tests/run.sh, never run alone: it needs the suite's ok/no/ee
# helpers, $SB, $FLEET, $REPO and hermetic_sessions.
#
# Unstarted lanes and named claims (2026-10-22). A session ran
# `git worktree add "$WORKTREE_ROOT/<repo>/<slug>" -b lane/<slug> main`, called
# EnterWorktree on that path, and sat for 30+ hours waiting for the user to
# approve the prompt. The lane had no commits, so its tip (an older main commit)
# was an ancestor of main and read MERGED; no transcript had that path as a cwd
# yet, so nothing claimed it; prune called it SAFE and the sweep said REMOVE,
# which would have pulled the tree out from under the session. Each case is named
# for one half of that: "no commits" is not "landed", and a transcript that
# NAMES the tree in a tool call is a claim even before the cwd gets there.
echo "-- prune/sweep: unstarted lanes and named claims (2026-10-22) --"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  unstarted-lane tests (jq not installed)"
else
UR="$SB/urroot"; URP="$SB/urrepo"     # UR is a throwaway WORKTREE_ROOT, set per command
git init -q -b main "$URP"; git -C "$URP" config user.email t@t; git -C "$URP" config user.name t
git -C "$URP" config core.autocrlf false
# main's tip is an hour old, so a lane forked from it now has a tip OLDER than its tree.
echo base > "$URP/f"; git -C "$URP" add -A
GIT_COMMITTER_DATE="@$(( $(date +%s) - 3600 )) +0000" git -C "$URP" commit -qm init
printf '.claude/\n' >> "$URP/.git/info/exclude"
UST="$SB/ustore/acct/ws"; UTX="$SB/utx"; mkdir -p "$UST" "$UTX"
export FLEET_SESSION_STORE="$SB/ustore" FLEET_TRANSCRIPT_ROOTS="$UTX" FLEET_SESSION_NOCACHE=1

un_native(){ cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }   # git's path form
un_age(){ local t=$(( $(date +%s) - $2 )); touch -d "@$t" "$1" 2>/dev/null || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"; }
un_add(){ git -C "$URP" worktree add -q "$UR/urrepo/$1" -b "lane/$1" main; }   # hand-made, zero commits
un_old(){ un_age "$(git -C "$UR/urrepo/$1" rev-parse --git-dir)/commondir" $(( 40 * 86400 )); }  # made 40 days ago
un_wrap(){ # id title archived(true|false) cliId — cwd is the repo root, idle 30 hours
  jq -n --arg id "$1" --arg t "$2" --argjson ar "$3" --arg cli "$4" --arg c "$(un_native "$URP")" \
        --argjson la "$(( ($(date +%s) - 108000) * 1000 ))" \
    '{sessionId:$id, title:$t, cwd:$c, lastActivityAt:$la, isArchived:$ar, branch:("claude/" + $id),
      writtenBranches:null, cliSessionId:$cli}' > "$UST/$1.json"
}
un_tx(){ # cliId toolName inputJSON — filed under the repo root, last written 30 hours ago
  local d; d="$UTX/$(printf '%s' "$(un_native "$URP")" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$d"
  { printf '{"type":"user","cwd":%s,"message":{"role":"user","content":"start"}}\n' "$(jq -Rn --arg c "$(un_native "$URP")" '$c')"
    jq -cn --arg n "$2" --argjson in "$3" --arg c "$(un_native "$URP")" \
      '{type:"assistant", cwd:$c, message:{role:"assistant", content:[{type:"tool_use", id:"toolu_1", name:$n, input:$in}]}}'
  } > "$d/$1.jsonl"
  un_age "$d/$1.jsonl" 108000
}
un_quiet(){ env CLAUDE_CODE_HOST_SESSION_ID= CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID= WORKTREE_ROOT="$UR" "$@"; }
# bucket<TAB>reason of the tree <slug>, from one prune --porcelain run ($1 = its output).
un_b(){ printf '%s\n' "$1" | awk -F'\t' -v n="/$2" 'substr($1, length($1) - length(n) + 1) == n { print $3 "\t" $4; exit }'; }

cd "$URP"
un_add u-bare                                   # no commits, nobody names it
un_add u-noref; rm -f "$URP/.git/logs/refs/heads/lane/u-noref"   # a branch with no reflog, as a Desktop chip's has none
un_add u-named                                  # the incident: EnterWorktree pending in an open session
un_wrap local_unamed "Waiting on EnterWorktree" false cli-unamed
un_tx cli-unamed EnterWorktree "$(jq -cn --arg p "$(un_native "$UR/urrepo/u-named")" '{path:$p}')"
un_add u-old; un_old u-old                      # no commits, unclaimed, 40 days old
un_add u-old-named; un_old u-old-named          # the same, but an open session named it
un_wrap local_uoldnm "Named it long ago" false cli-uoldnm
un_tx cli-uoldnm EnterWorktree "$(jq -cn --arg p "$(un_native "$UR/urrepo/u-old-named")" '{path:$p}')"
un_add u-cmd; un_old u-cmd                      # named by the incident's own command, $WORKTREE_ROOT unexpanded
un_wrap local_ucmd "Made the lane" false cli-ucmd
un_tx cli-ucmd Bash "$(jq -cn '{command:"git worktree add \"$WORKTREE_ROOT/urrepo/u-cmd\" -b lane/u-cmd main"}')"
# Controls: a lane whose own commit landed (its reflog deleted too, so only the
# tip-vs-tree test can tell), and a native tree named only by an ARCHIVED session.
un_add u-landed; echo w > "$UR/urrepo/u-landed/w.txt"; git -C "$UR/urrepo/u-landed" add -A
git -C "$UR/urrepo/u-landed" -c user.email=w@t -c user.name=w commit -qm work
git -C "$URP" merge -q --no-ff -m "merge: lane/u-landed" lane/u-landed
rm -f "$URP/.git/logs/refs/heads/lane/u-landed"
git -C "$URP" worktree add -q "$URP/.claude/worktrees/u-native" -b claude/u-native main
echo n > "$URP/.claude/worktrees/u-native/n.txt"; git -C "$URP/.claude/worktrees/u-native" add -A
git -C "$URP/.claude/worktrees/u-native" -c user.email=w@t -c user.name=w commit -qm native
git -C "$URP" merge -q --no-ff -m "merge: claude/u-native" claude/u-native
un_wrap local_unatv "Named it, then archived" true cli-unatv
un_tx cli-unatv EnterWorktree "$(jq -cn --arg p "$(un_native "$URP/.claude/worktrees/u-native")" '{path:$p}')"

UNP=$(un_quiet bash "$FLEET" prune --porcelain 2>/dev/null)
case "$(un_b "$UNP" u-bare)" in
  REVIEW$'\t'unstarted*) ok "a zero-commit lane nobody names is REVIEW 'unstarted', never SAFE as merged" ;;
  *) no "zero-commit lane read [$(un_b "$UNP" u-bare)], want REVIEW unstarted" ;; esac
case "$(un_b "$UNP" u-noref)" in
  REVIEW$'\t'unstarted*) ok "...and so is one whose branch has no reflog: its tip predates its tree" ;;
  *) no "reflog-less zero-commit lane read [$(un_b "$UNP" u-noref)], want REVIEW unstarted" ;; esac
case "$(un_b "$UNP" u-named)" in
  REVIEW$'\t'unstarted*"Waiting on EnterWorktree"*) ok "a lane an open session's pending EnterWorktree names is REVIEW, naming that session" ;;
  *) no "EnterWorktree-named lane read [$(un_b "$UNP" u-named)], want REVIEW naming the session" ;; esac
case "$(un_b "$UNP" u-old)" in
  SAFE$'\t'unstarted*) ok "an unstarted lane unclaimed for 40 days is SAFE again (the age threshold)" ;;
  *) no "old unclaimed unstarted lane read [$(un_b "$UNP" u-old)], want SAFE" ;; esac
case "$(un_b "$UNP" u-old-named)" in
  REVIEW*"Named it long ago"*) ok "...unless an open session's transcript names it: the named claim alone keeps it" ;;
  *) no "old EnterWorktree-named lane read [$(un_b "$UNP" u-old-named)], want REVIEW" ;; esac
case "$(un_b "$UNP" u-cmd)" in
  REVIEW*"Made the lane"*) ok "a 'git worktree add \$WORKTREE_ROOT/<repo>/<slug>' tool call is a claim on that tree" ;;
  *) no "lane named by git worktree add read [$(un_b "$UNP" u-cmd)], want REVIEW" ;; esac
case "$(un_b "$UNP" u-landed)" in
  SAFE$'\t'"merged + clean"*) ok "control: a lane whose own commit landed is still SAFE when nothing claims it" ;;
  *) no "landed control read [$(un_b "$UNP" u-landed)], want SAFE merged + clean" ;; esac
[ "$(un_b "$UNP" u-native | cut -f1)" = REVIEW ] && ok "a named claim from an ARCHIVED session never proves a tree abandoned" \
  || no "native tree named only by an archived session read [$(un_b "$UNP" u-native)], want REVIEW"
# The session running prune is not a claim on what it named itself: a coordinator
# that made a lane for a peer, which has since finished, can still prune it.
UNS=$(un_quiet env CLAUDE_CODE_HOST_SESSION_ID=local_ucmd bash "$FLEET" prune --porcelain 2>/dev/null)
[ "$(un_b "$UNS" u-cmd | cut -f1)" = SAFE ] && ok "...but not when the session that named it is the one running prune" \
  || no "self-named old lane read [$(un_b "$UNS" u-cmd)] for its own session, want SAFE"

unw(){ printf '%s\n' "$UNW" | awk -F'\t' -v n="/$1" '$1 == "worktree" && substr($2, length($2) - length(n) + 1) == n { print $3; exit }'; }
UNW=$(un_quiet bash "$FLEET" sweep --porcelain 2>/dev/null)
[ "$(unw u-named)" = UNSTARTED ] && [ "$(unw u-bare)" = UNSTARTED ] \
  && ok "sweep: an unstarted lane reads UNSTARTED, never REMOVE or 'merged + clean'" \
  || no "sweep: unstarted lanes read [$(unw u-named)] / [$(unw u-bare)], want UNSTARTED"
[ "$(unw u-landed)" = REMOVE ] && ok "sweep control: the landed lane still reads REMOVE" \
  || no "sweep: landed control read [$(unw u-landed)], want REMOVE"

unset FLEET_SESSION_NOCACHE; hermetic_sessions
cd "$REPO"
fi
