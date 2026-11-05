# Sourced by tests/run.sh, never run alone: it needs the suite's ok/no/ee
# helpers, $SB, $FLEET, $REPO, arm_gate and hermetic_sessions.
#
# A machine-wide lane root (WORKTREE_ROOT, rules/worktree-boundaries.md "Lane
# location") moves lanes out of the project to $WORKTREE_ROOT/<repo>/<slug>.
# The dangerous half is recognition, not creation: a sweep that stops seeing
# lanes, or a prune that calls a session's tree SAFE because it no longer looks
# like one, fails silently. Every case is named for that failure. WORKTREE_ROOT
# is set per command and always points into the sandbox, never the real root.
echo "-- WORKTREE_ROOT (machine-wide lane root: config, init, prune, sweep) --"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  WORKTREE_ROOT tests (jq not installed)"
else
WRR="$SB/wroot"; WRP="$SB/wrrepo"
git init -q -b main "$WRP"; git -C "$WRP" config user.email t@t; git -C "$WRP" config user.name t
git -C "$WRP" config core.autocrlf false
echo base > "$WRP/f"; git -C "$WRP" add -A; git -C "$WRP" commit -qm init
arm_gate "$WRP"
cd "$WRP"

# fleet.sh once assigned its own default to a variable NAMED WORKTREE_ROOT,
# clobbering the machine's value for itself and every child it ran.
wrcfg=$(WORKTREE_ROOT="$WRR" bash "$FLEET" config 2>/dev/null | sed -n 's/^worktree_root=//p')
[ "$wrcfg" = "$WRR/wrrepo" ] && ok "config: WORKTREE_ROOT set -> worktree_root = <root>/<repo>" \
  || no "config: worktree_root=[$wrcfg], want $WRR/wrrepo"
WORKTREE_ROOT="$WRR" bash "$FLEET" init wr-lane >/dev/null 2>&1
[ -d "$WRR/wrrepo/wr-lane" ] && [ ! -e "$WRP/.fleet-worktrees" ] \
  && ok "init: the lane is created under WORKTREE_ROOT, not in the project" || no "init: lane not under WORKTREE_ROOT"
grep -qx '\.fleet-worktrees/' "$WRP/.gitignore" 2>/dev/null \
  && no "init: wrote a .fleet-worktrees/ ignore for a lane outside the repo" \
  || ok "init: no .fleet-worktrees/ ignore for an outside lane root"
printf 'test_cmd=true\nworktree_root=.mine\n' > "$WRP/.claude/fleet/config"
wrcfg=$(WORKTREE_ROOT="$WRR" bash "$FLEET" config 2>/dev/null | sed -n 's/^worktree_root=//p')
[ "$wrcfg" = .mine ] && ok "config: an explicit worktree_root still wins over WORKTREE_ROOT" || no "explicit worktree_root lost: [$wrcfg]"
arm_gate "$WRP"

# A session tree hooks/worktree-create.sh made (worktree-<name>) and a plain
# lane, both merged + clean, nobody in the (readable, empty) session store.
wr_tree(){ git -C "$WRP" worktree add -q "$WRR/wrrepo/$1" -b "$2" main
  echo "$2" > "$WRR/wrrepo/$1/$1.txt"; git -C "$WRR/wrrepo/$1" add -A
  git -C "$WRR/wrrepo/$1" -c user.email=w@t -c user.name=w commit -qm "work $2"
  git -C "$WRP" merge -q --no-ff -m "merge: $2" "$2"; }
wr_tree sess-x worktree-sess-x
wr_tree lane-y lane/y
wrb(){ env "$@" bash "$FLEET" prune --porcelain 2>/dev/null | awk -F'\t' -v n="/$WRB_T" 'substr($1, length($1) - length(n) + 1) == n { print $3; exit }'; }
WRB_T=sess-x; wr_sess=$(wrb WORKTREE_ROOT="$WRR"); wr_sess0=$(wrb WORKTREE_ROOT=)
WRB_T=lane-y; wr_lane=$(wrb WORKTREE_ROOT="$WRR")
[ "$wr_sess" = REVIEW ] && ok "prune: an unclaimed hook-made session tree is REVIEW, never SAFE" \
  || no "prune: hook-made session tree read [$wr_sess], want REVIEW"
[ "$wr_sess0" = SAFE ] && ok "control: the same tree is SAFE once nothing marks it a session tree" \
  || no "control: unmarked tree read [$wr_sess0], want SAFE"
[ "$wr_lane" = SAFE ] && ok "prune: a merged, clean lane/* tree under WORKTREE_ROOT stays SAFE" \
  || no "prune: lane under WORKTREE_ROOT read [$wr_lane], want SAFE"

# sweep: the lanes it must see, and the one it must not claim.
mkdir -p "$WRR/wrrepo/stray"; echo x > "$WRR/wrrepo/stray/f"
git init -q -b main "$SB/elsewhere-wr/wrrepo"
git -C "$SB/elsewhere-wr/wrrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SB/elsewhere-wr/wrrepo" worktree add -q "$WRR/wrrepo/theirs" -b theirs
WRS=$(WORKTREE_ROOT="$WRR" bash "$FLEET" sweep --porcelain 2>/dev/null)
WRS0=$(WORKTREE_ROOT= bash "$FLEET" sweep --porcelain 2>/dev/null)
wrs(){ printf '%s\n' "$1" | awk -F'\t' -v ph="$2" -v n="/$3" -v c="$4" '$1 == ph && substr($2, length($2) - length(n) + 1) == n && !f { print $c; f = 1 }'; }
[ "$(wrs "$WRS" hygiene stray 3)" = ORPHAN-DIR ] && ok "sweep: an unregistered dir under WORKTREE_ROOT/<repo> is ORPHAN-DIR" \
  || no "sweep: stray dir under WORKTREE_ROOT read [$(wrs "$WRS" hygiene stray 3)]"
[ -z "$(wrs "$WRS" hygiene theirs 3)" ] && ok "sweep: a same-named repo's lane under the root is not our orphan" \
  || no "sweep: claimed another repo's lane as [$(wrs "$WRS" hygiene theirs 3)]"
[ -z "$(wrs "$WRS0" hygiene stray 3)" ] && ok "control: unset, the sweep does not scan WORKTREE_ROOT" \
  || no "control: unset sweep still scanned the root"
case "$(wrs "$WRS" worktree sess-x 4)" in *hook-made*) ok "sweep: a hook-made session tree says Claude Code will not clean it" ;;
  *) no "sweep: hook-made tree detail lacks the note: [$(wrs "$WRS" worktree sess-x 4)]" ;; esac
case "$(wrs "$WRS" worktree lane-y 4)" in *hook-made*) no "sweep: a lane/* tree was called hook-made" ;;
  *) ok "sweep: a lane/* tree under the root is not called hook-made" ;; esac

cd "$REPO"
fi
