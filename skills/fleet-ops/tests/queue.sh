# Sourced by tests/run.sh, never run alone: it needs the suite's ok/no/ee helpers, $SB,
# $SKILL, $FLEET, arm_gate and hermetic_sessions.
#
# `fleet queue` (scripts/queue.sh) is the coordinator's landing chain: settle, check the
# reviewed tip, trial-merge, audit the would-be merge, memory guard, then `fleet land`
# with quiet retries. Every case is named for the failure it prevents. The refusals it
# retries are fleet.sh's own log lines, so the retry cases run the REAL fleet.sh against a
# fixture session store and a really held landing marker, never a shim that would keep
# passing after fleet rewords them.
echo "-- fleet queue (audited, one-at-a-time landing) --"
QUEUE="$SKILL/scripts/queue.sh"
QR="$SB/qrepo"
QF=(--poll 1s --deadline 20s --mem-limit off)   # fast; the memory guard only where a case wants it
# A retry loop broken into "never stops" must fail this suite, not hang it.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 120"

git init -q -b main "$QR"
git -C "$QR" config user.email t@t; git -C "$QR" config user.name t
git -C "$QR" config core.autocrlf false
cat > "$QR/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- **Old entry** text.

## [1.0.0] - 2026-01-01

- **Released** thing.
EOF
# twice() is a duplicate the base already has: only duplicates a merge ADDS may count.
printf 'helper() { echo one; }\ntwice() { echo a; }\ntwice() { echo b; }\n' > "$QR/lib.sh"
printf '.claude/fleet/\n.fleet-worktrees/\n' > "$QR/.gitignore"
echo base > "$QR/f"
git -C "$QR" add -A; git -C "$QR" commit -qm init
arm_gate "$QR"
cd "$QR"

q_lane(){ QW="$SB/qwt-$1"; git -C "$QR" worktree add -q -b "lane/$1" "$QW" main; }
q_commit(){ git -C "$1" add -A; git -C "$1" -c user.email=w@t -c user.name=w commit -qm "$2"; }
q_tip(){ git -C "$QR" rev-parse "lane/$1"; }
q_merged(){ case "$(git -C "$QR" log --format=%s main)" in *"merge: lane/$1"*) return 0 ;; esac; return 1; }
q_run(){ $TO bash "$FLEET" queue "$@" > "$SB/q.out" 2> "$SB/q.err"; QX=$?; }
q_row(){ sed -n "${1}p" "$SB/q.out" | cut -f"$2"; }   # row N, field M of the last run
# Add an [Unreleased] entry: at the top with its blank line (glue=0), or glued straight
# under "Old entry" with no blank line between (glue=1).
q_entry(){
  awk -v t="$2" -v g="${3:-0}" '
    g == 0 && /^## \[Unreleased\]/ { print; getline; print; print "- **" t "** text."; print ""; next }
    g == 1 && /^- \*\*Old entry\*\*/ { print; print "- **" t "** text."; next }
    { print }' "$1" > "$1.new" && mv "$1.new" "$1"
}

# -- contract surface ----------------------------------------------------------
bash "$FLEET" queue lane/x >/dev/null 2>&1; ee "queue: a lane without a tip is a usage error" 2 $?
bash "$FLEET" queue --bogus lane/x abc >/dev/null 2>&1; ee "queue: an unknown option is a usage error" 2 $?
case "$(bash "$FLEET" queue --help 2>/dev/null)" in *EXAMPLES*) ok "queue: --help lists EXAMPLES";; *) no "queue: --help has no EXAMPLES";; esac
cq="$(bash "$FLEET" config --quiet 2>"$SB/cq.err")"
case "$cq" in *"base_branch=main"*) ok "config --quiet prints the resolved keys";; *) no "config --quiet: [$cq]";; esac
[ -s "$SB/cq.err" ] && no "config --quiet still printed diagnostics: $(head -c 200 "$SB/cq.err")" \
  || ok "config --quiet skips the session-store diagnostics"

# -- audits ----------------------------------------------------------------------
# Control first: a lane that rewords its OWN changelog line is not a dropped line.
q_lane qa; q_entry "$QW/CHANGELOG.md" "Lane A"
sed 's/^- \*\*Old entry\*\* text\./- **Old entry** reworded./' "$QW/CHANGELOG.md" > "$QW/c.new" && mv "$QW/c.new" "$QW/CHANGELOG.md"
q_commit "$QW" "lane a"
mtip=$(git -C "$QR" rev-parse main)
q_run "${QF[@]}" --dry-run lane/qa "$(q_tip qa)"
ee "dry-run: a lane rewording its own changelog line passes the audits" 0 $QX
[ "$(q_row 1 3)" = clean ] && ok "dry-run: the row says clean" || no "dry-run row: $(cat "$SB/q.out")"
[ "$(git -C "$QR" rev-parse main)" = "$mtip" ] && ok "dry-run: nothing landed" || no "dry-run moved main"

# A "keep both sides" resolution in the lane's merge of main that loses a line. The
# lane's own commits removed nothing, so the merge commit did it. A bullet line shows in
# a diff as "-- **...", which a '^-[^-]' filter never sees: assert the bullet by name.
q_lane qb; q_entry "$QW/CHANGELOG.md" "Lane B"; q_commit "$QW" "lane b"
q_entry "$QR/CHANGELOG.md" "Main M"; git -C "$QR" commit -qam "main entry"
git -C "$QW" -c user.email=w@t -c user.name=w merge -q main >/dev/null 2>&1
cat > "$QW/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- **Lane B** text.

- **Main M** text.

## [1.0.0] - 2026-01-01

- **Released** thing.
EOF
git -C "$QW" add CHANGELOG.md; git -C "$QW" -c user.email=w@t -c user.name=w commit -q --no-edit
q_run "${QF[@]}" lane/qb "$(q_tip qb)"
ee "dropped: a merge resolution that loses a changelog line stops the land" 4 $QX
grep -qF 'dropped: - **Old entry** text.' "$SB/q.err" && ok "dropped: the lost bullet entry is named" \
  || no "dropped: the lost bullet was not reported: $(head -c 300 "$SB/q.err")"
# git aligns this diff as replacements, so "Main M" shows as removed AND added: moved,
# not dropped. Only a net loss is a dropped line.
grep -qF 'dropped: - **Main M** text.' "$SB/q.err" && no "dropped: reported a line the merge only moved" \
  || ok "dropped: a line the merge only moves is not reported"
q_merged qb && no "dropped: the lane landed anyway" || ok "dropped: nothing landed"

q_lane qg; q_entry "$QW/CHANGELOG.md" "Glued G" 1; q_commit "$QW" "lane g"
q_run "${QF[@]}" --dry-run lane/qg "$(q_tip qg)"
ee "glued: an [Unreleased] entry with no blank line above stops the land" 4 $QX
grep -qF 'glued: - **Glued G** text.' "$SB/q.err" && ok "glued: the glued entry is named" \
  || no "glued: not reported: $(head -c 300 "$SB/q.err")"

# A glue already on main must not stop every later land.
q_entry "$QR/CHANGELOG.md" "Old glue" 1; git -C "$QR" commit -qam "main glue"
q_lane qe; q_entry "$QW/CHANGELOG.md" "Lane E"; q_commit "$QW" "lane e"
q_run "${QF[@]}" --dry-run lane/qe "$(q_tip qe)"
ee "glued: a glue the base already has does not stop a clean lane" 0 $QX
if command -v jq >/dev/null 2>&1; then
  q_run "${QF[@]}" --dry-run --json lane/qe "$(q_tip qe)"
  jq -e '.data[0].result == "clean" and .meta.schema == "claude-mods.fleet-ops.queue/v1" and .meta.dry_run == true and .meta.count == 1' \
    "$SB/q.out" >/dev/null 2>&1 && ok "--json: one envelope with the row and its schema" || no "--json: $(head -c 300 "$SB/q.out")"
fi

# A private name in prose, in a plans file a repo's own leak gate skips by design. The
# list has a comment and a blank line: neither may become a pattern (a blank one matches
# every line). The finding must never print the name it protects.
printf '# private names, one regex per line\n\n\\bzorblax\\b\n' > "$SB/deny.txt"
q_run "${QF[@]}" --dry-run --deny-file "$SB/deny.txt" lane/qe "$(q_tip qe)"
ee "deny: a deny list's comments and blank lines match nothing in a clean lane" 0 $QX
q_lane qz; mkdir -p "$QW/docs/plans"; printf 'Plan.\nNotes for the Zorblax project.\n' > "$QW/docs/plans/p.md"; q_commit "$QW" "lane z"
q_run "${QF[@]}" --dry-run --deny-file "$SB/deny.txt" lane/qz "$(q_tip qz)"
ee "deny: an added line naming a denied word stops the land, in any file" 4 $QX
grep -qF 'deny: docs/plans/p.md:2 matches pattern #1 of deny.txt' "$SB/q.err" && ok "deny: the finding names file, line and pattern number" \
  || no "deny: finding not reported: $(head -c 300 "$SB/q.err")"
cat "$SB/q.out" "$SB/q.err" | grep -qi zorblax && no "deny: the output printed the denied word" \
  || ok "deny: the output never prints the denied word"
bash "$FLEET" queue --dry-run --deny-file "$SB/no-such-list" lane/qz "$(q_tip qz)" >/dev/null 2>&1
ee "deny: a deny file that does not exist is not silently skipped" 3 $?

q_lane qd; printf 'helper() { echo two; }\n' >> "$QW/lib.sh"; q_commit "$QW" "lane d"
q_run "${QF[@]}" --dry-run lane/qd "$(q_tip qd)"
ee "dups: a merge that defines a shell function twice stops the land" 4 $QX
grep -qF 'helper()' "$SB/q.err" && ok "dups: the duplicated function is named" || no "dups: helper() not reported: $(head -c 300 "$SB/q.err")"
grep -qF 'twice()' "$SB/q.err" && no "dups: reported twice(), a duplicate the base already had" \
  || ok "dups: a duplicate already on the base is not reported"

# Released sections never change. The failure: a lane appends its bullet at the end of
# [Unreleased]; a release cut puts "## [1.1.0]" above those lines; git merges cleanly and
# the bullet is filed under the released 1.1.0. Its own repo, with a link footer, so the
# control (a release cut rewrites the footer) is meaningful.
QV="$SB/qrel"
git init -q -b main "$QV"; git -C "$QV" config user.email t@t; git -C "$QV" config user.name t
git -C "$QV" config core.autocrlf false
cat > "$QV/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- **Old entry** text.

## [1.0.0] - 2026-01-01

- **Released** thing.

[Unreleased]: https://example.com/compare/v1.0.0...HEAD
[1.0.0]: https://example.com/releases/v1.0.0
EOF
printf '.claude/fleet/\n.fleet-worktrees/\n' > "$QV/.gitignore"
git -C "$QV" add -A; git -C "$QV" commit -qm init
arm_gate "$QV"
cd "$QV"
git -C "$QV" worktree add -q -b lane/cut "$SB/qvwt-cut" main
awk '/^## \[Unreleased\]/ { print; getline; print; print "## [1.1.0] - 2026-02-01"; print ""; next }
     /^\[Unreleased\]: / { print "[Unreleased]: https://example.com/compare/v1.1.0...HEAD"
                           print "[1.1.0]: https://example.com/compare/v1.0.0...v1.1.0"; next }
     { print }' "$QV/CHANGELOG.md" > "$SB/qvwt-cut/CHANGELOG.md"
q_commit "$SB/qvwt-cut" "release 1.1.0"
git -C "$QV" worktree add -q -b lane/late "$SB/qvwt-late" main
awk '/^## \[1\.0\.0\]/ { print "- **Late bullet** text."; print "" } { print }' "$QV/CHANGELOG.md" > "$SB/qvwt-late/CHANGELOG.md"
q_commit "$SB/qvwt-late" "late bullet"
q_run "${QF[@]}" --dry-run lane/cut "$(git -C "$QV" rev-parse lane/cut)"
ee "released: a release cut (new section, rewritten link footer) passes" 0 $QX
git -C "$QV" merge -q --no-ff -m "merge: lane/cut" lane/cut >/dev/null 2>&1
q_run "${QF[@]}" --dry-run lane/late "$(git -C "$QV" rev-parse lane/late)"
ee "released: a bullet that merges into a released section stops the land" 4 $QX
grep -qF 'released: [1.1.0] gains: - **Late bullet** text.' "$SB/q.err" && ok "released: the section and the bullet are named" \
  || no "released: not reported: $(head -c 300 "$SB/q.err")"
cd "$QR"

# -- tips --------------------------------------------------------------------------
# Fleet rebases every tracked lane after each land, so a reviewed tip moves. That is
# accepted only when it merges to the same tree as the tip that was reviewed.
q_lane r1; echo r1 > "$QW/r1.txt"; q_commit "$QW" "lane r1"
q_lane r2; echo r2 > "$QW/r2.txt"; q_commit "$QW" "lane r2"
bash "$FLEET" track lane/r2 >/dev/null 2>&1
r2frozen=$(q_tip r2)
q_run "${QF[@]}" lane/r1 "$(q_tip r1)" lane/r2 "$r2frozen"
ee "rebase: a lane fleet auto-rebased after the previous land still lands" 0 $QX
[ "$(q_tip r2)" != "$r2frozen" ] && ok "rebase: the second lane's tip really moved" || no "rebase: fleet did not rebase lane/r2 (case did not exercise the path)"
q_merged r1 && q_merged r2 && ok "rebase: both lanes merged" || no "rebase: rows $(cat "$SB/q.out")"
case "$(q_row 2 4)" in *"rebased from ${r2frozen:0:7}"*) ok "rebase: the row says it accepted a rebase";;
  *) no "rebase: row 2 detail: $(q_row 2 4)";; esac

q_lane qm; echo m1 > "$QW/m.txt"; q_commit "$QW" "lane m"
mfrozen=$(q_tip qm); echo m2 > "$QW/m.txt"; q_commit "$QW" "lane m, after review"
q_run "${QF[@]}" lane/qm "$mfrozen"
ee "moved: a tip whose content changed after review is refused" 11 $QX
q_merged qm && no "moved: the unreviewed content landed" || ok "moved: nothing landed"

# Squash-landed by hand: its content is in main, its commits are not. A land would be
# an empty merge and a gate; it is reported already and left alone.
q_lane qs; echo s > "$QW/s.txt"; q_commit "$QW" "lane s"
git -C "$QR" merge -q --squash lane/qs >/dev/null 2>&1; git -C "$QR" commit -qm "squash of lane s"
q_run "${QF[@]}" lane/qs "$(q_tip qs)"
ee "already: a lane whose content is already on main succeeds without a land" 0 $QX
[ "$(q_row 1 3)" = already ] && ok "already: the row says already" || no "already row: $(cat "$SB/q.out")"
q_merged qs && no "already: it was landed a second time" || ok "already: no second merge"

q_lane qc; echo lane-change > "$QW/f"; q_commit "$QW" "lane c"
echo main-change > "$QR/f"; git -C "$QR" commit -qam "main f"
q_run "${QF[@]}" --dry-run lane/qc "$(q_tip qc)"
ee "conflict: a lane that conflicts with main is sent back" 10 $QX
case "$(q_row 1 4)" in *f*) ok "conflict: the conflicted file is named";; *) no "conflict detail: $(q_row 1 4)";; esac

q_lane qk; echo k > "$QW/k.txt"; q_commit "$QW" "lane k"
echo uncommitted >> "$QW/k.txt"
q_run "${QF[@]}" lane/qk "$(q_tip qk)"
ee "dirty: a lane with uncommitted tracked changes is not landed" 11 $QX
q_merged qk && no "dirty: landed under its owner's uncommitted work" || ok "dirty: nothing landed"
git -C "$QW" checkout -q -- k.txt

q_run "${QF[@]}" lane/qc "$(q_tip qc)" lane/qk "$(q_tip qk)"
ee "chain: the first lane's failure is the exit code" 10 $QX
[ "$(q_row 2 3)" = skipped ] && ok "chain: the lane after a failure is skipped" || no "chain row 2: $(q_row 2 3)"
q_merged qk && no "chain: a later lane landed on top of a failure" || ok "chain: the later lane did not land"

# -- memory guard (Windows commit charge; injected here so it runs on every OS) ----
FLEET_QUEUE_COMMIT_PCT=97 $TO bash "$FLEET" queue --poll 1s --deadline 3s --mem-limit 92 lane/qk "$(q_tip qk)" > "$SB/q.out" 2> "$SB/q.err"
ee "memory: a commit charge over the limit holds the gate until the deadline" 6 $?
q_merged qk && no "memory: a gate started under memory pressure" || ok "memory: nothing landed"
FLEET_QUEUE_COMMIT_PCT=50 $TO bash "$FLEET" queue --poll 1s --deadline 20s --mem-limit 92 lane/qk "$(q_tip qk)" > "$SB/q.out" 2> "$SB/q.err"
ee "memory: under the limit the lane lands" 0 $?
q_merged qk && ok "memory: lane/qk merged" || no "memory: lane/qk not merged: $(cat "$SB/q.out")"

# -- live owner (real fleet.sh, fixture session store) -------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  queue live-owner cases (jq not installed)"
else
QS="$SB/qstore/acct/ws"; mkdir -p "$QS"
export FLEET_SESSION_STORE="$SB/qstore" FLEET_SESSION_NOCACHE=1
q_owner(){ # lane ageSecs: the lane's owner, active ageSecs ago
  local ms=$(( ($(date +%s) - $2) * 1000 ))
  printf '{"sessionId":"local_qowner","title":"Lane owner","cwd":"%s","lastActivityAt":%s,"isArchived":false,"branch":"%s","writtenBranches":["%s"]}\n' \
    "$SB/elsewhere" "$ms" "$1" "$1" > "$QS/local_qowner.json"
}
q_lane ql; echo l > "$QW/l.txt"; q_commit "$QW" "lane l"
q_owner lane/ql 0
q_run --poll 1s --deadline 4s --mem-limit off lane/ql "$(q_tip ql)"
ee "live owner: an owner live past the deadline ends retryable, not failed" 6 $QX
case "$(q_row 1 4)" in *"LIVE session"*) ok "live owner: the timeout row names fleet's live-owner refusal";;
  *) no "live owner: row $(cat "$SB/q.out")";; esac
q_merged ql && no "live owner: landed under a live owner" || ok "live owner: nothing landed"

# The owner goes idle while the queue is retrying: it must land without being re-queued.
$TO bash "$FLEET" queue --poll 1s --deadline 90s --mem-limit off lane/ql "$(q_tip ql)" > "$SB/q.out" 2> "$SB/q.err" &
qpid=$!
for _ in $(seq 1 90); do grep -q 'retry in' "$SB/q.err" 2>/dev/null && break; sleep 1; done
grep -q 'retry in' "$SB/q.err" && ok "live owner: the refusal is retried" || no "live owner: no retry seen: $(head -c 300 "$SB/q.err")"
q_owner lane/ql 7200
wait "$qpid"; ee "live owner: the lane lands once its owner goes idle" 0 $?
q_merged ql && ok "live owner: lane/ql merged" || no "live owner: lane/ql not merged: $(cat "$SB/q.out")"
rm -f "$QS/local_qowner.json"
unset FLEET_SESSION_NOCACHE; hermetic_sessions
fi

# -- landing lock (a real marker held by a live fleet process) -----------------------
q_lane qlk; echo lk > "$QW/lk.txt"; q_commit "$QW" "lane lk"
# landing_pid_live trusts a pid only while its command line mentions fleet: name it so.
bash -c 'sleep 15; :' fleet-holder & hpid=$!
printf '%s\t%s\t%s\t%s\n' "$hpid" "$(date +%s)" "$(git -C "$QR" rev-parse main)" lane/someone-else > "$QR/.claude/fleet/landing"
bash "$FLEET" land lane/qlk > "$SB/lk.log" 2>&1
rx=$(sed -n "s/^RETRYABLE='\(.*\)'\$/\1/p" "$QUEUE")
[ -n "$rx" ] && grep -Eq "$rx" "$SB/lk.log" && ok "lock: the real refusal under a held marker matches queue's retry pattern" \
  || no "lock: fleet's refusal no longer matches RETRYABLE: $(grep -m1 REFUSE "$SB/lk.log")"
q_run --poll 1s --deadline 90s --mem-limit off lane/qlk "$(q_tip qlk)"
ee "lock: a land held by another fleet process is waited out, then the lane lands" 0 $QX
grep -q 'waiting for main to settle' "$SB/q.err" && ok "lock: the queue waited for the held land" || no "lock: no wait seen: $(head -c 300 "$SB/q.err")"
q_merged qlk && ok "lock: lane/qlk merged" || no "lock: lane/qlk not merged: $(cat "$SB/q.out")"
wait "$hpid" 2>/dev/null

cd "$REPO"
