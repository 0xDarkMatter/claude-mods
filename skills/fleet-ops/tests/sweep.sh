# Sourced by tests/run.sh, never run alone: it needs the suite's ok/no/ee
# helpers, $SB, $FLEET, $REPO and hermetic_sessions. It lives in its own file so
# the suite's tail, which every lane extends, changes by one line, not 200.
#
# `fleet sweep` (scripts/sweep.sh), the post-wave sweep. Every case is named for
# the bug it stops: a verdict that would send MAIN to the wrong next action, or
# an --apply that would destroy something it promised not to touch.
echo "-- sweep (post-wave verdicts, competing work, zero-loss --apply) --"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  sweep tests (jq not installed)"
else
export FLEET_SESSION_NOCACHE=1 FLEET_TRANSCRIPT_ROOTS=""
# Two Desktop instances, laid out as on a real machine: the primary store and a
# --user-data-dir profile ("alt"). The archive tools reach only the calling
# session's own instance, so the rows must say which one each session is in.
SWP="$SB/swdesk/AppData/Roaming/Claude/claude-code-sessions"
SWA="$SB/swdesk/.claude-desktop-profiles/alt/claude-code-sessions"
SWS="$SWP/acct/ws"; SWS2="$SWA/acct/ws"; mkdir -p "$SWS" "$SWS2"
export FLEET_SESSION_STORE="$SWP;$SWA"
# The private lists live outside the repo; point at fixtures so the developer's
# real lists never reach the logic under test.
printf 'secret/*\n# comment lines are ignored\n' > "$SB/never-push.txt"
export FLEET_NEVER_PUSH="$SB/never-push.txt"
printf '# lanes that wait on someone\nlane/hold-*   waits on an outside review\n' > "$SB/held-lanes.txt"
export FLEET_HELD_LANES="$SB/held-lanes.txt"

SW="$SB/swrepo"; mkdir -p "$SW"
git -C "$SW" init -q -b main
git -C "$SW" config user.email t@t; git -C "$SW" config user.name t
git -C "$SW" config core.autocrlf false
printf 'base\n' > "$SW/hook.sh"; printf '# log\n' > "$SW/CHANGELOG.md"
git -C "$SW" add -A; git -C "$SW" commit -qm init
printf '.claude/\n' >> "$SW/.git/info/exclude"
WTS="$SW/.claude/worktrees"; mkdir -p "$WTS"

sw_wt(){ git -C "$SW" branch "$2" "${3:-main}"; git -C "$SW" worktree add -q "$WTS/$1" "$2"; }  # slug branch [base]
sw_ci(){ printf '%s\n' "$3" >> "$1/$2"; git -C "$1" add -A; git -C "$1" -c user.email=w@t -c user.name=w commit -qm "work $2"; }
sw_land(){ git -C "$SW" merge -q --no-ff -m "merge: $1" "$1"; }
# Desktop's own cwd form: native and backslashed (POSIX hosts: slashes flipped).
sw_bs(){ local p; p=$(cygpath -w "$1" 2>/dev/null) || p=$(printf '%s' "$1" | tr / '\\'); printf '%s' "$p"; }
sw_wrap(){ # id title cwd ageSecs archived(true|false) [writtenBranch] [storeDir]
  local ms=$(( ($(date +%s) - $4) * 1000 ))
  jq -n --arg id "$1" --arg t "$2" --arg c "$(sw_bs "$3")" --argjson la "$ms" --argjson ar "$5" --arg wb "${6:-}" \
    '{sessionId:$id, title:$t, cwd:$c, lastActivityAt:$la, isArchived:$ar, branch:("claude/" + $id),
      writtenBranches:(if $wb == "" then null else [$wb] end)}' > "${7:-$SWS}/$1.json"
}
sw_old(){ local t=$(( $(date +%s) - 7200 )); touch -d "@$t" "$1" 2>/dev/null || touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"; }

# Squash-landed (two commits, so `git cherry` alone cannot see it) and
# half-landed (first commit cherry-picked, second not).
sw_wt squash lane/squash; sw_ci "$WTS/squash" sq.txt one; sw_ci "$WTS/squash" sq.txt two
git -C "$SW" merge -q --squash lane/squash; git -C "$SW" commit -qm "squash lane/squash"
sw_wt partial lane/partial; sw_ci "$WTS/partial" p1.txt one
git -C "$SW" cherry-pick lane/partial >/dev/null 2>&1; sw_ci "$WTS/partial" p2.txt two
# Competing: comp-a COMMITS hook.sh; comp-b, merged, holds UNCOMMITTED edits to it.
sw_wt comp-a lane/comp-a; sw_ci "$WTS/comp-a" hook.sh "from a"
sw_wt comp-b lane/comp-b; printf 'from b\n' >> "$WTS/comp-b/hook.sh"
# Two lanes touching only the shared ledger.
sw_wt led-a lane/led-a; sw_ci "$WTS/led-a" CHANGELOG.md "- a"
sw_wt led-b lane/led-b; sw_ci "$WTS/led-b" CHANGELOG.md "- b"
# Owners: done and idle; done here but unlanded elsewhere; live.
sw_wt done-tree lane/done; sw_ci "$WTS/done-tree" done.txt x; sw_land lane/done
sw_wrap local_swdone "Done lane" "$WTS/done-tree" 7200 false
sw_wt busy-a lane/busy-a; sw_ci "$WTS/busy-a" ba.txt x; sw_land lane/busy-a
sw_wt busy-b lane/busy-b; sw_ci "$WTS/busy-b" bb.txt x
sw_wrap local_swbusy "Busy lane" "$WTS/busy-a" 7200 false lane/busy-b
sw_wt live-tree lane/live; sw_ci "$WTS/live-tree" lv.txt x; sw_land lane/live
sw_wrap local_swlive "Live lane" "$WTS/live-tree" 5 false
# Prune KEEPs a locked tree; its idle owner must not be asked to archive either.
sw_wt locked-tree lane/locked; sw_ci "$WTS/locked-tree" lk.txt x; sw_land lane/locked
git -C "$SW" worktree lock "$WTS/locked-tree"
sw_wrap local_swlocked "Locked lane" "$WTS/locked-tree" 7200 false
# A ghost: registered, its directory deleted behind git's back.
sw_wt ghosty lane/ghosty; rm -rf "$WTS/ghosty"
# Empty unregistered dirs: one is an open session's cwd (that session also owns
# a landed lane - it must be archived directly, never messaged), one is free,
# one was created a moment ago.
# The hollow owner lives in the OTHER Desktop instance ("alt"); the session that
# runs the sweep (local_swself) lives in the primary one.
mkdir -p "$WTS/hollow-held"; sw_old "$WTS/hollow-held"
sw_wt hdone lane/hdone; sw_ci "$WTS/hdone" hd.txt x; sw_land lane/hdone
sw_wrap local_swhollow "Hollow lane" "$WTS/hollow-held" 7200 false lane/hdone "$SWS2"
sw_wrap local_swself "The sweeping session" "$SB/elsewhere" 0 false
mkdir -p "$WTS/hollow-free"; sw_old "$WTS/hollow-free"
mkdir -p "$WTS/hollow-new"
# Branches with no worktree.
git -C "$SW" branch old/merged main~1
git -C "$SW" branch release/1.0 main
git -C "$SW" branch secret/old main
git -C "$SW" branch held/branch main
sw_wrap local_swheld "Holds a branch" "$SB/elsewhere" 7200 false held/branch
git -C "$SW" checkout -q -b wip/unmerged main; sw_ci "$SW" w.txt x; git -C "$SW" checkout -q main
git -C "$SW" checkout -q -b secret/leak main; sw_ci "$SW" s.txt x; git -C "$SW" checkout -q main
git -C "$SW" update-ref refs/remotes/origin/secret/leak secret/leak
# Held lanes: one with a worktree (would read LAND), one without, pushed for its
# outside review (would read UNLANDED, and LEAKED were it a never-push entry).
sw_wt hold-a lane/hold-a; sw_ci "$WTS/hold-a" ha.txt x
git -C "$SW" checkout -q -b lane/hold-b main; sw_ci "$SW" hb.txt x; git -C "$SW" checkout -q main
git -C "$SW" update-ref refs/remotes/origin/lane/hold-b lane/hold-b
# A merged branch named by a session that is archived AFTER the index is cached.
git -C "$SW" branch named/later main
sw_wrap local_swlater "Archives soon" "$SB/elsewhere" 7200 false named/later
printf 'stashed\n' >> "$SW/hook.sh"
GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git -C "$SW" stash push -q -m old-stash

cd "$SW"
sw_snap(){ { git -C "$SW" for-each-ref --format='%(refname) %(objectname)'; git -C "$SW" worktree list --porcelain
             git -C "$SW" stash list; ls -a "$WTS"; } 2>/dev/null; }
# Verdict of the first row in <phase> whose subject is <key> or ends in /<key>.
sw_v(){ printf '%s\n' "$SWOUT" | awk -F'\t' -v ph="$1" -v k="$2" '
          $1 == ph && ($2 == k || substr($2, length($2) - length(k)) == "/" k) && !f { print $3; f = 1 }'; }
sw_before=$(sw_snap)
# Re-stamp the live owner last, so building the fixture can never age it past
# the 600s live window before the sweep reads it.
sw_wrap local_swlive "Live lane" "$WTS/live-tree" 0 false
# Run as local_swself, the way a Desktop session's Bash tool runs it; the other
# two ids are blanked so the developer's own session can never resolve.
sw_as_self(){ env CLAUDE_CODE_HOST_SESSION_ID=local_swself CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID= "$@"; }
sw_as_none(){ env CLAUDE_CODE_HOST_SESSION_ID= CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID= "$@"; }
SWOUT=$(sw_as_self bash "$FLEET" sweep --porcelain 2>/dev/null); swx=$?
ee "a repo with leftovers exits 10 (findings)" 10 "$swx"
[ "$(sw_snap)" = "$sw_before" ] && ok "bare 'fleet sweep' changed nothing (refs, worktrees, stashes, dirs)" \
  || no "bare 'fleet sweep' CHANGED repo state"

[ "$(sw_v worktree squash)" = CONTENT-LANDED ] && ok "squash-landed lane reads CONTENT-LANDED, not unlanded" \
  || no "squash-landed lane read [$(sw_v worktree squash)], want CONTENT-LANDED"
[ "$(sw_v worktree partial)" = LAND ] && ok "half-landed lane still reads LAND - never called landed" \
  || no "half-landed lane read [$(sw_v worktree partial)], want LAND"

[ "$(sw_v worktree comp-b)" = COMPETING ] && ok "uncommitted edits to another lane's committed files read COMPETING" \
  || no "uncommitted overlap read [$(sw_v worktree comp-b)], want COMPETING"
case "$(printf '%s\n' "$SWOUT" | awk -F'\t' '$1 == "compete" && $2 == "lane/comp-a <> lane/comp-b" { print $4 }')" in
  *"uncommitted in lane/comp-b"*) ok "the competing pair names the side whose overlap is uncommitted" ;;
  *) no "no competing pair, or it misses which side is uncommitted" ;; esac
printf '%s\n' "$SWOUT" | awk -F'\t' '$1 == "compete" && $2 ~ /led-/' | grep -q . \
  && no "lanes touching only CHANGELOG.md flagged as competing" || ok "a ledger-only overlap is not competing"

[ "$(sw_v worktree done-tree)" = ASK-ARCHIVE ] && [ "$(sw_v session local_swdone)" = ARCHIVE-REQUEST ] \
  && ok "a finished, idle owner gets an archive request" || no "finished owner: [$(sw_v worktree done-tree)] / [$(sw_v session local_swdone)]"
[ "$(sw_v worktree busy-a)" = OWNER-BUSY ] && [ -z "$(sw_v session local_swbusy)" ] \
  && ok "an owner with an unlanded lane elsewhere is not asked to archive" || no "busy owner: [$(sw_v worktree busy-a)] / [$(sw_v session local_swbusy)]"
[ "$(sw_v worktree live-tree)" = KEEP ] && [ -z "$(sw_v session local_swlive)" ] \
  && ok "a live owner's tree is KEEP and the owner is never asked to archive" || no "live owner: [$(sw_v worktree live-tree)] / [$(sw_v session local_swlive)]"
[ "$(sw_v worktree locked-tree)" = KEEP ] && [ -z "$(sw_v session local_swlocked)" ] \
  && ok "an idle owner of a tree prune keeps is never asked to archive" \
  || no "kept-tree owner: [$(sw_v worktree locked-tree)] / [$(sw_v session local_swlocked)]"
[ "$(sw_v hygiene hollow-held)" = HOLLOW ] && [ "$(sw_v session local_swhollow)" = ARCHIVE-DIRECT ] \
  && ok "a session whose lane dir is hollow is archived directly" || no "hollow owner: [$(sw_v hygiene hollow-held)] / [$(sw_v session local_swhollow)]"
printf '%s\n' "$SWOUT" | awk -F'\t' '$1 == "session" && $2 == "local_swhollow" && $3 == "ARCHIVE-REQUEST"' | grep -q . \
  && no "a hollow-dir session was queued for send_message (resume into a dead tree)" \
  || ok "a hollow-dir session is never messaged, even with all its work landed"

[ "$(sw_v worktree ghosty)" = GHOST ] && ok "a registered worktree whose dir is gone reads GHOST" || no "ghost read [$(sw_v worktree ghosty)]"
[ "$(sw_v hygiene hollow-free)" = EMPTY-DIR ] && [ "$(sw_v hygiene hollow-new)" = KEEP ] \
  && ok "an old unclaimed empty dir is EMPTY-DIR; a brand-new one is left alone" || no "empty dirs: [$(sw_v hygiene hollow-free)] / [$(sw_v hygiene hollow-new)]"
[ "$(sw_v branch old/merged)" = DELETE-MERGED ] && [ "$(sw_v branch held/branch)" = HELD ] \
  && [ "$(sw_v branch secret/old)" = PARK ] && [ -z "$(sw_v branch release/1.0)" ] \
  && ok "merged branches: deletable, held by an open session, never-push, keep-pattern" \
  || no "merged branch verdicts: [$(sw_v branch old/merged)] [$(sw_v branch held/branch)] [$(sw_v branch secret/old)] [$(sw_v branch release/1.0)]"
[ "$(sw_v branch secret/leak)" = LEAKED ] && ok "a never-push branch with a remote copy reads LEAKED" || no "leaked read [$(sw_v branch secret/leak)]"
[ "$(sw_v hygiene 'stash@{0}')" = STALE-STASH ] && ok "an old stash reads STALE-STASH" || no "stash read [$(sw_v hygiene 'stash@{0}')]"

# Desktop instances. archive_session/send_message reach only the caller's own
# instance: a row that offers a tool call for a session in another one fails
# "Session ... not found" when MAIN acts on it.
# Column <c> (4 detail, 5 action) of the row sw_v would read.
sw_f(){ printf '%s\n' "$SWOUT" | awk -F'\t' -v ph="$1" -v k="$2" -v c="$3" '
          $1 == ph && ($2 == k || substr($2, length($2) - length(k)) == "/" k) && !f { print $c; f = 1 }'; }
case "$(sw_f session local_swhollow 5)" in
  *archive_session*|*send_message\ *) no "a session in another Desktop instance was offered a tool call: $(sw_f session local_swhollow 5)" ;;
  *"alt Desktop window"*) ok "a session in another Desktop instance gets its window, never a tool call from this one" ;;
  *) no "other-instance session: action names no window: $(sw_f session local_swhollow 5)" ;; esac
case "$(sw_f session local_swdone 4)|$(sw_f session local_swdone 5)|$(sw_f session local_swhollow 4)" in
  "[primary] "*"|send_message:"*"|[alt] "*) ok "every session row names its Desktop instance; one in this instance keeps its tool call" ;;
  *) no "session rows: [$(sw_f session local_swdone 4)] [$(sw_f session local_swdone 5)] [$(sw_f session local_swhollow 4)]" ;; esac
case "$(printf '%s\n' "$SWOUT" | awk -F'\t' '$1 == "hygiene" && $3 == "HOLLOW" { print $4 }')" in
  *"local_swhollow [alt]"*) ok "a HOLLOW row names its session's Desktop instance" ;;
  *) no "HOLLOW row does not name the instance" ;; esac
# Not knowing which instance this run is in (a terminal, or an unresolvable id)
# must not read as "this one": the row still names the window.
swun=$(sw_as_none bash "$FLEET" sweep --porcelain 2>/dev/null \
  | awk -F'\t' '$1 == "session" && $2 == "local_swhollow" { print $5 }')
case "$swun" in *"archive_session local_swhollow from a session in the alt Desktop window"*)
  ok "with its own instance unknown, the sweep names the window to act from" ;;
  *) no "unknown own instance: [$swun]" ;; esac

# Holds. A held lane must never read LAND (or REBASE), and the hold is not a
# never-push entry: its review copy on a remote is expected, not LEAKED.
case "$(sw_v worktree hold-a)|$(sw_f worktree hold-a 4)" in
  "ON-HOLD|held: waits on an outside review;"*) ok "a held lane reads ON-HOLD with its reason, never LAND" ;;
  *) no "held lane read [$(sw_v worktree hold-a)]" ;; esac
[ "$(sw_v branch lane/hold-b)" = ON-HOLD ] && ok "a held branch with a remote copy reads ON-HOLD - not LEAKED, not 'fleet land'" \
  || no "held, pushed branch read [$(sw_v branch lane/hold-b)]"

# Phase 3 and phase 4 read the same moment. With the index cached, a session
# archived since is still "open" in it; the branch it names must not stay HELD
# when phase 4's fresh read already treats that session as gone.
unset FLEET_SESSION_NOCACHE
bash "$SKILL/scripts/sessions.sh" views >/dev/null 2>&1   # prime the cache
sw_wrap local_swlater "Archives soon" "$SB/elsewhere" 7200 true named/later
swl=$(bash "$FLEET" sweep --porcelain 2>/dev/null | awk -F'\t' '$1 == "branch" && $2 == "named/later" { print $3 }')
export FLEET_SESSION_NOCACHE=1
[ "$swl" = DELETE-MERGED ] && ok "a branch named only by a since-archived session is not HELD on a stale index" \
  || no "since-archived namer: branch read [$swl], want DELETE-MERGED"
# Captured, not piped: under pipefail the sweep's exit 10 (findings) would win.
sw_json=$(bash "$FLEET" sweep --json 2>/dev/null)
printf '%s' "$sw_json" | jq -e '.meta.schema == "claude-mods.fleet-ops.sweep/v1" and (.data | length) > 0' >/dev/null \
  && ok "--json carries the claude-mods envelope" || no "--json envelope missing or empty"

# --apply: zero-loss classes only, and only behind a confirmation.
bash "$FLEET" sweep --apply </dev/null >/dev/null 2>&1; ee "--apply refuses without a terminal" 2 $?
[ "$(sw_snap)" = "$sw_before" ] && ok "a refused --apply changed nothing" || no "a refused --apply CHANGED repo state"
bash "$FLEET" sweep --porcelain --apply >/dev/null 2>&1; ee "--porcelain --apply is refused" 2 $?
sw_nwt=$(git -C "$SW" worktree list --porcelain | grep -c '^worktree ')
bash "$FLEET" sweep --apply --yes >/dev/null 2>&1; ee "--apply --yes exits 0" 0 $?
sw_has(){ git -C "$SW" rev-parse --verify -q "refs/heads/$1" >/dev/null; }
sw_has old/merged && no "--apply left the merged, worktree-less branch" || ok "--apply deleted the merged, worktree-less branch"
sw_has release/1.0 && sw_has wip/unmerged && sw_has secret/old && sw_has held/branch && sw_has lane/comp-b \
  && ok "--apply kept keep-pattern, unmerged, never-push, held and checked-out branches" \
  || no "--apply deleted a branch it must keep"
git -C "$SW" worktree list --porcelain | grep -q '/ghosty$' && no "--apply left the ghost admin entry" \
  || ok "--apply pruned the ghost admin entry"
[ "$(git -C "$SW" worktree list --porcelain | grep -c '^worktree ')" -eq $((sw_nwt - 1)) ] \
  && ok "--apply removed no worktree (only the ghost entry went)" || no "--apply changed the worktree count beyond the ghost"
[ ! -d "$WTS/hollow-free" ] && ok "--apply removed the unclaimed empty dir" || no "--apply left the unclaimed empty dir"
[ -d "$WTS/hollow-held" ] && ok "--apply kept the empty dir an open session still has as its cwd" \
  || no "--apply REMOVED an open session's cwd"
[ -d "$WTS/hollow-new" ] && ok "--apply kept a just-created empty dir" || no "--apply removed a dir that may be mid-creation"
[ "$(git -C "$SW" stash list | grep -c .)" -eq 1 ] && grep -q 'from b' "$WTS/comp-b/hook.sh" \
  && ok "--apply dropped no stash and touched no uncommitted work" || no "--apply lost a stash or uncommitted edits"

# `fleet prune --remove` on Windows: git empties and unregisters the tree, then
# cannot delete the directory a process still stands in. That is a removed
# worktree plus an empty leftover the sweep clears - not a FAILED removal. A git
# shim reproduces the end state on any OS; "-stuck" trees fail for real.
sw_wt left-tree lane/left; sw_ci "$WTS/left-tree" lf.txt x; sw_land lane/left
sw_wrap local_swleft "Finished lane" "$WTS/left-tree" 7200 true
sw_wt real-stuck lane/stuck; sw_ci "$WTS/real-stuck" st.txt x; sw_land lane/stuck
sw_wrap local_swstuck "Finished lane 2" "$WTS/real-stuck" 7200 true
mkdir -p "$SB/gitshim"; sw_realgit=$(command -v git)
cat > "$SB/gitshim/git" <<SHIM
#!/usr/bin/env bash
if [[ " \$* " == *" worktree remove "* ]]; then
  t=\${@: -1}
  [[ "\$t" == *-stuck ]] && { echo "error: failed to delete '\$t': Permission denied" >&2; exit 255; }
  "$sw_realgit" "\$@" || exit \$?
  mkdir -p "\$t"; echo "error: failed to delete '\$t': Permission denied" >&2; exit 255
fi
exec "$sw_realgit" "\$@"
SHIM
chmod +x "$SB/gitshim/git"
swp=$(PATH="$SB/gitshim:$PATH" bash "$FLEET" prune --remove --yes 2>&1); swpx=$?
case "$swp" in *"removed worktree: "*"left-tree"*"empty leftover"*) ok "prune: git removed the tree but the dir is held => removed + empty leftover, not FAILED" ;;
  *) no "prune: held empty dir not reported as a leftover: $(printf '%s\n' "$swp" | grep -i 'left-tree' | head -n2)" ;; esac
case "$swp" in *"FAILED to remove "*"real-stuck"*) ok "prune: a removal that did not happen still reads FAILED (exit $swpx)" ;;
  *) no "prune: a real failure was not reported as FAILED" ;; esac
[ "$(FLEET_SWEEP_MIN_DIR_AGE=0 bash "$FLEET" sweep --porcelain 2>/dev/null | awk -F'\t' '$1 == "hygiene" && $2 ~ /\/left-tree$/ { print $3 }')" = EMPTY-DIR ] \
  && ok "the leftover is an EMPTY-DIR row, as prune's message promises" || no "the prune leftover is not an EMPTY-DIR sweep row"

# A land that STARTS mid-sweep. The sweep used to ask `fleet landing` once, at
# the top, and a land begun after that left a full report of live actions on a
# tip about to move, with no "wait" in it (2026-10-06). This shim claims the
# landing marker when phase 4 lists stashes - after the first ask, before any
# row is printed. An empty marker is a live claim (fleet.sh landing_status).
mkdir -p "$SB/gitshim2"
cat > "$SB/gitshim2/git" <<SHIM
#!/usr/bin/env bash
[[ " \$* " == *" stash list "* ]] && { mkdir -p "$SW/.claude/fleet"; : > "$SW/.claude/fleet/landing"; }
exec "$sw_realgit" "\$@"
SHIM
chmod +x "$SB/gitshim2/git"
rm -f "$SW/.claude/fleet/landing"
swm=$(PATH="$SB/gitshim2:$PATH" bash "$FLEET" sweep --porcelain 2>/dev/null)
rm -f "$SW/.claude/fleet/landing"
case "${swm%%$'\n'*}" in
  landing$'\t'*) ok "a land that starts mid-sweep still leads the report" ;;
  *) no "mid-sweep land: first row is [${swm%%$'\n'*}]" ;; esac
eq "a land that starts mid-sweep leaves no row acting on the tip" "" \
  "$(printf '%s\n' "$swm" | awk -F'\t' 'NF && $1 != "landing" && $5 != "-" && $5 !~ /^wait: /')"

SWC="$SB/swclean"; mkdir -p "$SWC"; git -C "$SWC" init -q -b main
echo x > "$SWC/f"; git -C "$SWC" add -A; git -C "$SWC" -c user.email=t@t -c user.name=t commit -qm init
( cd "$SWC" && bash "$FLEET" sweep >/dev/null 2>&1 ); ee "a swept repo exits 0" 0 $?

unset FLEET_SESSION_NOCACHE FLEET_NEVER_PUSH FLEET_HELD_LANES; hermetic_sessions
cd "$REPO"
fi
