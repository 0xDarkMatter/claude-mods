#!/usr/bin/env bash
# Offline behavioural suite for the fleetflow skill scripts.
# Self-contained: builds a throwaway git repo, exercises spawn/collect/doctor
# via --dry-run (no network, no workers). Exits nonzero on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
PASS=0; FAILN=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAILN=$((FAILN+1)); echo "  FAIL  $1"; }
check() { # desc, expected-rc, cmd...
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" = "$want" ] && ok "$desc (exit $want)" || bad "$desc: wanted $want got $got"
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable on this platform"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO" && git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
PKT="$TMP/packet.txt"; echo "Do the thing. FINAL REPLY: one line." > "$PKT"

# --- syntax + help ------------------------------------------------------------
for s in ff-spawn.sh ff-collect.sh ff-doctor.sh ff-status.sh ff-run.sh ff-clean.sh ff-import.sh; do
  bash -n "$S/$s" 2>/dev/null && ok "syntax $s" || bad "syntax $s"
  bash "$S/$s" --help 2>/dev/null | grep -q "EXAMPLES" && ok "$s --help has EXAMPLES" || bad "$s --help lacks EXAMPLES"
  check "$s --help exits 0" 0 bash "$S/$s" --help
done

# --- usage validation -----------------------------------------------------------
check "spawn: no args" 2 bash "$S/ff-spawn.sh"
check "spawn: bad brain" 2 bash "$S/ff-spawn.sh" --run r1 --id a --brain gpt9 --prompt-file "$PKT" --repo "$REPO"
check "spawn: bad run name" 2 bash "$S/ff-spawn.sh" --run "R 1" --id a --brain glm --prompt-file "$PKT" --repo "$REPO"
check "spawn: missing prompt file" 2 bash "$S/ff-spawn.sh" --run r1 --id a --brain glm --prompt-file "$TMP/nope" --repo "$REPO"
check "collect: no args" 2 bash "$S/ff-collect.sh" --repo "$REPO"
check "doctor: bad flag" 2 bash "$S/ff-doctor.sh" --frobnicate

# --- dry-run lifecycle -----------------------------------------------------------
check "spawn: dry-run ok" 0 bash "$S/ff-spawn.sh" --run r1 --id a --brain sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run
[ -f "$REPO/.fleetflow/r1/a.result.json" ] && ok "artifact written" || bad "artifact missing"
[ -f "$REPO/.fleetflow/r1/journal.jsonl" ] && ok "journal exists" || bad "journal missing"
N_STARTED="$(jq -r 'select(.type=="started")|.key' "$REPO/.fleetflow/r1/journal.jsonl" | wc -l)"
N_RESULT="$(jq -r 'select(.type=="result")|.key' "$REPO/.fleetflow/r1/journal.jsonl" | wc -l)"
[ "$N_STARTED" -ge 1 ] && [ "$N_RESULT" -ge 1 ] && ok "journal has started+result" || bad "journal records missing"
grep -q '^v2:' <(jq -r '.key' "$REPO/.fleetflow/r1/journal.jsonl") && ok "keys carry v2: prefix" || bad "key prefix wrong"
grep -qs '^\.fleetflow/$' "$REPO/.git/info/exclude" && ok ".fleetflow gitignored via info/exclude" || bad "info/exclude not updated"
[ -f "$REPO/.fleetflow/r1/main-baseline.txt" ] && ok "escape baseline snapshotted" || bad "baseline missing"
grep -q "relative to cwd" "$REPO/.fleetflow/r1/a.prompt.txt" && ok "guard preamble injected" || bad "guard preamble absent"

# resume: identical packet -> cache hit (exit 3); --force -> re-run (exit 0)
check "spawn: cache hit on identical packet" 3 bash "$S/ff-spawn.sh" --run r1 --id a --brain sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run
check "spawn: --force re-runs" 0 bash "$S/ff-spawn.sh" --run r1 --id a --brain sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --force
echo "changed" >> "$PKT"
check "spawn: changed packet re-runs" 0 bash "$S/ff-spawn.sh" --run r1 --id a --brain sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run

# worktree lane creation
check "spawn: worktree lane" 0 bash "$S/ff-spawn.sh" --run r1 --id lane --brain sonnet --prompt-file "$PKT" --repo "$REPO" --dry-run --worktree
git -C "$REPO" show-ref --verify --quiet refs/heads/fleetflow/r1/lane && ok "lane branch created" || bad "lane branch missing"
[ -d "$REPO/.fleetflow/r1/wt-lane" ] && ok "lane worktree created" || bad "lane worktree missing"

# --- collect gating ---------------------------------------------------------------
check "collect: dry-run result passes" 0 bash "$S/ff-collect.sh" --run r1 --id a --repo "$REPO"
OUT="$(bash "$S/ff-collect.sh" --run r1 --id a --repo "$REPO" 2>/dev/null)"
[ "$OUT" = "DRYRUN" ] && ok "collect prints final text" || bad "collect text wrong: '$OUT'"
jq -nc '{is_error:true,result:"boom"}' > "$REPO/.fleetflow/r1/bad.result.json"
jq -nc '{type:"result",key:"v2:x",id:"bad",brain:"sonnet",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/r1/journal.jsonl"
check "collect: is_error=true fails gate" 10 bash "$S/ff-collect.sh" --run r1 --id bad --repo "$REPO"
check "collect: missing artifact" 3 bash "$S/ff-collect.sh" --run r1 --id ghost --repo "$REPO"
# codex-style artifact: last.txt path with schema validation
printf '{"verdict":"ok"}' > "$REPO/.fleetflow/r1/cx.last.txt"
check "collect: codex last-message passes" 0 bash "$S/ff-collect.sh" --run r1 --id cx --repo "$REPO"
check "collect: codex schema-valid JSON" 0 bash "$S/ff-collect.sh" --run r1 --id cx --repo "$REPO" --schema
printf 'not json' > "$REPO/.fleetflow/r1/cx.last.txt"
check "collect: codex schema-invalid fails" 10 bash "$S/ff-collect.sh" --run r1 --id cx --repo "$REPO" --schema

# --- phases --------------------------------------------------------------------------
check "spawn: --phase accepted" 0 bash "$S/ff-spawn.sh" --run r1 --id ver --brain opus --phase verify --prompt-file "$PKT" --repo "$REPO" --dry-run
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes[] | select(.id=="ver") | .phase=="verify"' >/dev/null \
  && ok "status: phase propagates" || bad "status: phase missing"
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes[] | select(.id=="a") | .phase=="build"' >/dev/null \
  && ok "status: default phase is build" || bad "status: default phase wrong"

# --- status feed --------------------------------------------------------------------
check "status: no args" 2 bash "$S/ff-status.sh"
check "status: watch without out" 2 bash "$S/ff-status.sh" --run r1 --repo "$REPO" --watch 3
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes | length >= 2' >/dev/null \
  && ok "status: emits lanes JSON" || bad "status: JSON invalid"
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.lanes[] | select(.id=="a") | .state=="done"' >/dev/null \
  && ok "status: dry-run lane state done" || bad "status: lane state wrong"
[ -f "$HERE/../assets/ff-monitor.html" ] && grep -q "status.json" "$HERE/../assets/ff-monitor.html" \
  && ok "monitor asset present + polls status.json" || bad "monitor asset missing"
# torn-write guard: an empty/missing-lanes payload is treated as a fetch miss
grep -q "torn-write guard" "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: empty-lanes torn-write guard present" || bad "monitor: torn-write guard missing"
grep -q "d.lanes.length === 0" "$HERE/../assets/ff-monitor.html" \
  && ok "monitor: guards on empty lanes array" || bad "monitor: empty-lanes guard logic missing"

# --- escape guard ------------------------------------------------------------------
check "escape guard: clean main" 0 bash "$S/ff-collect.sh" --check-main-clean --run r1 --repo "$REPO"
echo rogue > "$REPO/rogue.txt"
check "escape guard: detects new file" 12 bash "$S/ff-collect.sh" --check-main-clean --run r1 --repo "$REPO"
rm "$REPO/rogue.txt"
check "escape guard: clean again" 0 bash "$S/ff-collect.sh" --check-main-clean --run r1 --repo "$REPO"

# --- doctor (offline only; never hits network) ---------------------------------------
bash "$S/ff-doctor.sh" --offline >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] || [ "$RC" = 10 ] && ok "doctor --offline runs (rc=$RC)" || bad "doctor --offline rc=$RC"
bash "$S/ff-doctor.sh" --offline 2>/dev/null | grep -qE "^bin-jq	ok" && ok "doctor TSV output" || bad "doctor TSV output missing"

# --- manifest (feature 1): created on first spawn, append, idempotent -----------
M="$REPO/.fleetflow/r1/manifest.json"
[ -f "$M" ] && ok "manifest created on first spawn" || bad "manifest not created"
jq -e '.run=="r1" and .base=="main" and (.created_by|startswith("ff-spawn/"))' "$M" >/dev/null \
  && ok "manifest header fields" || bad "manifest header wrong"
# lane 'a' was spawned several times (cache-hit, --force, changed) yet stays 1 entry
NA="$(jq '[.packets[]|select(.id=="a")]|length' "$M")"
[ "$NA" = "1" ] && ok "manifest packet idempotent (one entry per id)" || bad "manifest has $NA 'a' entries"
# every packet carries the Wave-1 fields the brief requires
jq -e '.packets[]|select(.id=="a")|has("effort") and has("key") and has("max_turns") and has("worktree")' "$M" >/dev/null \
  && ok "manifest packet has effort+key+max_turns+worktree" || bad "manifest packet fields missing"
# ff-status surfaces the manifest summary
bash "$S/ff-status.sh" --run r1 --repo "$REPO" 2>/dev/null | jq -e '.manifest.packet_count >= 1' >/dev/null \
  && ok "status: surfaces manifest.packet_count" || bad "status: manifest summary missing"

# --- ff-run.sh (feature 2): whole-run resume + status alias ---------------------
check "ff-run: no subcommand -> 2" 2 bash "$S/ff-run.sh"
check "ff-run: bad subcommand -> 2" 2 bash "$S/ff-run.sh" frobnicate --run r1 --repo "$REPO"
check "ff-run: resume missing run -> 2" 2 bash "$S/ff-run.sh" resume --run nope --repo "$REPO"
check "ff-run: resume no manifest -> 2" 2 bash "$S/ff-run.sh" resume --run r1 --repo "$TMP"
# fresh run, two DISTINCT packets so replay order is unambiguous
PA="$TMP/r2-a.txt"; echo "do A. FINAL REPLY: a" > "$PA"
PB="$TMP/r2-b.txt"; echo "do B. FINAL REPLY: b" > "$PB"
bash "$S/ff-spawn.sh" --run r2 --id a --brain sonnet --prompt-file "$PA" --repo "$REPO" --dry-run >/dev/null 2>&1
bash "$S/ff-spawn.sh" --run r2 --id b --brain sonnet --prompt-file "$PB" --repo "$REPO" --dry-run >/dev/null 2>&1
# resume re-spawns both -> both cache-hit -> exit 0; ids return in manifest order
RR="$(bash "$S/ff-run.sh" resume --run r2 --repo "$REPO" 2>/dev/null)"; RC=$?
[ "$RC" = "0" ] && ok "ff-run: all-cached resume exits 0" || bad "ff-run: resume rc=$RC"
printf '%s' "$RR" | jq -e 'length==2 and .[0].id=="a" and .[1].id=="b" and all(.[]; .status=="cached")' >/dev/null \
  && ok "ff-run: resume preserves packet order (no reorder drift)" || bad "ff-run: resume order wrong: $RR"
# status subcommand == ff-status (compare stable fields; generated_at differs by design)
SA="$(bash "$S/ff-run.sh" status --run r2 --repo "$REPO" 2>/dev/null | jq -c '{run,lanes:[.lanes[].id]}')"
SB="$(bash "$S/ff-status.sh" --run r2 --repo "$REPO" 2>/dev/null | jq -c '{run,lanes:[.lanes[].id]}')"
[ "$SA" = "$SB" ] && ok "ff-run status aliases ff-status" || bad "ff-run status != ff-status"

# --- schema fence-strip (feature 3) --------------------------------------------
# a result whose text is fenced JSON must still validate (--schema strips fences)
jq -nc '{is_error:false,result:"```json\n{\"verdict\":\"ok\"}\n```"}' > "$REPO/.fleetflow/r1/fence.result.json"
jq -nc '{type:"result",key:"v2:fence",id:"fence",brain:"sonnet",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/r1/journal.jsonl"
FOUT="$(bash "$S/ff-collect.sh" --run r1 --id fence --repo "$REPO" --schema 2>/dev/null)"; FRC=$?
[ "$FRC" = "0" ] && ok "collect: fence-strip lets fenced JSON validate" || bad "collect: fence-strip failed rc=$FRC"
printf '%s' "$FOUT" | jq -e '.verdict=="ok"' >/dev/null && ok "collect: fence-strip returns inner JSON" || bad "collect: fence-strip output wrong"

# --- schema --repair seam (feature 3) ------------------------------------------
# bad result + FLEETFLOW_REPAIR_DRYRUN: do_repair saves <id>.invalid.txt and
# respawns a <id>-repair lane. The dry-run lane replies "DRYRUN" (not JSON), so
# the repair gate fails -> exit 10; we assert the SEAM fired, not a happy path.
jq -nc '{is_error:false,result:"this is not json"}' > "$REPO/.fleetflow/r1/rp.result.json"
jq -nc '{type:"result",key:"v2:rp",id:"rp",brain:"sonnet",rc:0,artifact:"x"}' >> "$REPO/.fleetflow/r1/journal.jsonl"
FLEETFLOW_REPAIR_DRYRUN=1 bash "$S/ff-collect.sh" --run r1 --id rp --repo "$REPO" --schema --repair >/dev/null 2>&1; RPRC=$?
[ "$RPRC" = "10" ] && ok "collect: --repair exits 10 when corrected output invalid" || bad "collect: --repair rc=$RPRC (want 10)"
[ -f "$REPO/.fleetflow/r1/rp.invalid.txt" ] && ok "collect: --repair saved <id>.invalid.txt" || bad "collect: invalid.txt missing"
NREP="$(jq -r 'select(.type=="result" and .id=="rp-repair")|.id' "$REPO/.fleetflow/r1/journal.jsonl" | wc -l | tr -d ' ')"
[ "$NREP" -ge 1 ] && ok "collect: --repair respawned rp-repair lane" || bad "collect: no repair lane spawned"
grep -q 'corrected JSON' "$REPO/.fleetflow/r1/rp-repair.prompt-src.txt" 2>/dev/null \
  && ok "collect: --repair lane got the corrective prompt" || bad "collect: repair prompt missing"

# --- FF_VERSION in journal (feature 4) -----------------------------------------
grep -q '"v":"1.1.0"' "$REPO/.fleetflow/r1/journal.jsonl" && ok "journal records FF_VERSION 1.1.0" || bad "journal missing FF_VERSION"
# every operational script pins the same version (version-skew spine)
VS=0
for s in ff-spawn.sh ff-collect.sh ff-status.sh ff-doctor.sh ff-run.sh ff-clean.sh ff-import.sh; do
  grep -q '^FF_VERSION="1.1.0"$' "$S/$s" || VS=1
done
[ "$VS" = "0" ] && ok "all scripts pin FF_VERSION=1.1.0" || bad "version skew across scripts"

# --- effort lever (feature 5): effort is part of the cache key ------------------
EP="$TMP/effort.txt"; echo "effort test. FINAL REPLY: e" > "$EP"
check "spawn: effort lane first run -> 0" 0 bash "$S/ff-spawn.sh" --run r3 --id e --brain sonnet --prompt-file "$EP" --repo "$REPO" --dry-run
check "spawn: effort lane identical -> cached" 3 bash "$S/ff-spawn.sh" --run r3 --id e --brain sonnet --prompt-file "$EP" --repo "$REPO" --dry-run
# changing ONLY the effort must bust the cache (effort is baked into the OPTS key)
check "spawn: effort change -> cache miss" 0 bash "$S/ff-spawn.sh" --run r3 --id e --brain sonnet --prompt-file "$EP" --repo "$REPO" --dry-run --effort high
jq -e '.packets[]|select(.id=="e")|.effort=="high"' "$REPO/.fleetflow/r3/manifest.json" >/dev/null \
  && ok "manifest records effort=high" || bad "manifest effort field wrong"

# --- cache/tmp redirect (feature 7) --------------------------------------------
CRT="$TMP/ffcache"; CDP="$TMP/cdp.txt"; echo "cache test. FINAL REPLY: c" > "$CDP"
FLEETFLOW_CACHE_ROOT="$CRT" bash "$S/ff-spawn.sh" --run r4 --id c --brain sonnet --prompt-file "$CDP" --repo "$REPO" --dry-run >/dev/null 2>&1
[ -d "$CRT/r4-c" ] && ok "spawn: cache dir created under FLEETFLOW_CACHE_ROOT" || bad "spawn: cache dir not redirected to FLEETFLOW_CACHE_ROOT"

# --- ff-clean.sh (feature 8): autoclean lanes + cache --------------------------
check "ff-clean: usage -> 2" 2 bash "$S/ff-clean.sh"
check "ff-clean: no such run -> 2" 2 bash "$S/ff-clean.sh" --run ghost --repo "$REPO"
# fresh run, cache redirected, three DISTINCT-prompt worktree lanes (distinct so
# they don't cache-hit and skip worktree creation)
CLEANROOT="$TMP/cleancache"
for lid in cleanlane keeplane dirtlane; do
  echo "clean-$lid task. FINAL REPLY: $lid" > "$TMP/clean-$lid.txt"
  FLEETFLOW_CACHE_ROOT="$CLEANROOT" bash "$S/ff-spawn.sh" --run rc --id "$lid" --brain sonnet \
    --prompt-file "$TMP/clean-$lid.txt" --repo "$REPO" --dry-run --worktree >/dev/null 2>&1
done
# keeplane gets a real commit (must survive every clean); dirtlane gets untracked junk
( cd "$REPO/.fleetflow/rc/wt-keeplane" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "real work" )
echo "junk" > "$REPO/.fleetflow/rc/wt-dirtlane/junk.txt"
[ -d "$CLEANROOT/rc-cleanlane" ] && ok "ff-clean: setup created cache dir" || bad "ff-clean: setup cache dir missing"
# no --force: cleanlane removed, dirtlane kept (dirty), keeplane kept (1 commit).
# pass the SAME FLEETFLOW_CACHE_ROOT to ff-clean so it finds the redirected dirs.
CL="$(FLEETFLOW_CACHE_ROOT="$CLEANROOT" bash "$S/ff-clean.sh" --run rc --repo "$REPO" 2>/dev/null)"
printf '%s' "$CL" | awk -F'\t' '$1=="cleanlane"&&$2=="removed"{f=1} END{exit !f}' && ok "ff-clean: removes zero-commit clean lane" || bad "ff-clean: clean lane not removed"
printf '%s' "$CL" | awk -F'\t' '$1=="dirtlane"&&$2=="kept"&&$3~/dirty/{f=1} END{exit !f}' && ok "ff-clean: keeps dirty zero-commit lane (no --force)" || bad "ff-clean: dirty lane mishandled"
printf '%s' "$CL" | awk -F'\t' '$1=="keeplane"&&$2=="kept"&&$3~/1 commits/{f=1} END{exit !f}' && ok "ff-clean: keeps committed lane" || bad "ff-clean: committed lane mishandled"
[ -d "$REPO/.fleetflow/rc/wt-cleanlane" ] && bad "ff-clean: clean worktree dir remains" || ok "ff-clean: clean worktree removed"
git -C "$REPO" show-ref --verify --quiet refs/heads/fleetflow/rc/keeplane && ok "ff-clean: committed branch preserved" || bad "ff-clean: keeper branch deleted"
# --force: dirtlane now removed; keeplane STILL kept (committed lanes are never force-removed)
CL2="$(FLEETFLOW_CACHE_ROOT="$CLEANROOT" bash "$S/ff-clean.sh" --run rc --repo "$REPO" --force 2>/dev/null)"
printf '%s' "$CL2" | awk -F'\t' '$1=="dirtlane"&&$2=="removed"{f=1} END{exit !f}' && ok "ff-clean: --force removes dirty zero-commit lane" || bad "ff-clean: --force dirty mishandled"
printf '%s' "$CL2" | awk -F'\t' '$1=="keeplane"&&$2=="kept"{f=1} END{exit !f}' && ok "ff-clean: --force still keeps committed lane" || bad "ff-clean: --force removed committed lane!"
[ -d "$CLEANROOT/rc-cleanlane" ] || [ -d "$CLEANROOT/rc-dirtlane" ] || [ -d "$CLEANROOT/rc-keeplane" ] \
  && bad "ff-clean: cache dir remains" || ok "ff-clean: cache dirs removed"

# --- state derivation (feature C): last journal record wins -----------------------
# a respawn appends "started" AFTER an old "result" -> the lane is running again,
# NOT done/failed (the last-result-wins bug this fixes).
RD5="$REPO/.fleetflow/r5"; mkdir -p "$RD5"
: > "$RD5/z.prompt.txt"   # mtime source for elapsed
printf '%s\n' \
  '{"type":"started","key":"v2:z","id":"z","brain":"sonnet","phase":"build","v":"1.1.0"}' \
  '{"type":"result","key":"v2:z","id":"z","brain":"sonnet","rc":0,"artifact":"x"}' \
  '{"type":"started","key":"v2:z","id":"z","brain":"sonnet","phase":"build","v":"1.1.0"}' \
  > "$RD5/journal.jsonl"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.state=="running"' >/dev/null \
  && ok "status: respawned lane (started,result,started) is running" || bad "status: respawned lane state wrong"
# regression guard: same lane with result-last is still done (common path unchanged)
printf '%s\n' \
  '{"type":"started","key":"v2:z","id":"z","brain":"sonnet","phase":"build","v":"1.1.0"}' \
  '{"type":"result","key":"v2:z","id":"z","brain":"sonnet","rc":0,"artifact":"x"}' \
  > "$RD5/journal.jsonl"
bash "$S/ff-status.sh" --run r5 --repo "$REPO" 2>/dev/null \
  | jq -e '.lanes[]|select(.id=="z")|.state=="done"' >/dev/null \
  && ok "status: result-last lane is still done (no regression)" || bad "status: result-last state wrong"

# --- ff-import.sh (feature B): native Workflow run import ------------------------
# build a synthetic native wf_ dir: journal.jsonl (started/result keyed by
# agentId) + two agent transcripts (one string content, one content-array).
WFD="$TMP/wf_ab12cd34-ef"; mkdir -p "$WFD"
printf '%s\n' \
  '{"type":"started","key":"v2:aaaa","agentId":"a01cb5f01fadf5610"}' \
  '{"type":"result","key":"v2:aaaa","agentId":"a01cb5f01fadf5610","result":{"verdict":"ok","score":7}}' \
  '{"type":"started","key":"v2:bbbb","agentId":"a02deadbeef00000"}' \
  > "$WFD/journal.jsonl"
jq -nc '{type:"user",message:{role:"user",content:"Refute the claim that X is safe."}}' \
  > "$WFD/agent-a01cb5f01fadf5610.jsonl"
jq -nc '{type:"user",message:{role:"user",content:[{type:"text",text:"Find any bugs in module Y."}]}}' \
  > "$WFD/agent-a02deadbeef00000.jsonl"
IMP="$(bash "$S/ff-import.sh" --wf "$WFD" --run imp1 --repo "$REPO" 2>/dev/null)"; IRC=$?
[ "$IRC" = "0" ] && ok "ff-import: exits 0 on import" || bad "ff-import: rc=$IRC"
printf '%s' "$IMP" | awk -F'\t' '$1=="a01cb5f01fadf5610"&&$2=="imported"{f=1} END{exit !f}' \
  && ok "ff-import: completed agent reported imported" || bad "ff-import: imported TSV wrong"
printf '%s' "$IMP" | awk -F'\t' '$1=="a02deadbeef00000"&&$2=="incomplete"{f=1} END{exit !f}' \
  && ok "ff-import: started-only agent reported incomplete" || bad "ff-import: incomplete TSV wrong"
PC="$(printf '%s' "$IMP" | awk -F'\t' '$1=="a01cb5f01fadf5610"{print $3}')"
[ -n "$PC" ] && [ "$PC" -gt 0 ] 2>/dev/null && ok "ff-import: prompt_chars > 0" || bad "ff-import: prompt_chars wrong ($PC)"
IRD="$REPO/.fleetflow/imp1"
[ -f "$IRD/a01cb5f01fadf5610.prompt.txt" ] && ok "ff-import: wrote prompt.txt (completed)" || bad "ff-import: prompt.txt missing"
grep -q "Refute the claim" "$IRD/a01cb5f01fadf5610.prompt.txt" && ok "ff-import: prompt extracted (string content)" || bad "ff-import: string-content prompt wrong"
grep -q "Find any bugs" "$IRD/a02deadbeef00000.prompt.txt" && ok "ff-import: prompt extracted (content array)" || bad "ff-import: array-content prompt wrong"
[ -f "$IRD/a01cb5f01fadf5610.result.json" ] && ok "ff-import: wrote result.json (completed)" || bad "ff-import: result.json missing"
[ ! -f "$IRD/a02deadbeef00000.result.json" ] && ok "ff-import: incomplete agent has no result.json" || bad "ff-import: incomplete got result.json"
jq -e '.is_error==false and (.result|fromjson|.verdict=="ok" and .score==7)' "$IRD/a01cb5f01fadf5610.result.json" >/dev/null \
  && ok "ff-import: result.json wraps native result (tojson)" || bad "ff-import: result.json shape wrong"
NJ="$IRD/journal.jsonl"
[ "$(jq -r 'select(.type=="result" and .id=="a01cb5f01fadf5610")|.brain' "$NJ")" = "native" ] \
  && ok "ff-import: journal result brain=native" || bad "ff-import: journal brain wrong"
# phase lives on the started record (same convention as ff-spawn), not the result
[ "$(jq -r 'select(.type=="started" and .id=="a01cb5f01fadf5610")|.phase' "$NJ")" = "imported" ] \
  && ok "ff-import: journal phase=imported" || bad "ff-import: journal phase wrong"
[ -z "$(jq -r 'select(.type=="result" and .id=="a02deadbeef00000")' "$NJ")" ] \
  && ok "ff-import: incomplete agent has no result record" || bad "ff-import: incomplete got a result record"
jq -e --arg wf "$WFD" '.packets[]|select(.id=="a01cb5f01fadf5610")|.brain=="native" and .imported_from==$wf' "$IRD/manifest.json" >/dev/null \
  && ok "ff-import: manifest packet brain=native + imported_from" || bad "ff-import: manifest packet wrong"
# nothing to import -> exit 3
WFE="$TMP/wf_empty"; mkdir -p "$WFE"; : > "$WFE/journal.jsonl"
check "ff-import: empty wf journal -> 3" 3 bash "$S/ff-import.sh" --wf "$WFE" --run imp2 --repo "$REPO"
# ff-run resume SKIPS imported native packets (terminal, not replayable)
RRN="$(bash "$S/ff-run.sh" resume --run imp1 --repo "$REPO" 2>/dev/null)"; RCRR=$?
[ "$RCRR" = "0" ] && ok "ff-run: resume skips native packets (exit 0)" || bad "ff-run: resume on imported run rc=$RCRR"
printf '%s' "$RRN" | jq -e 'any(.[]; .id=="a01cb5f01fadf5610" and .status=="imported")' >/dev/null \
  && ok "ff-run: native packet reported imported (skipped)" || bad "ff-run: native packet not skipped"

echo "=== $PASS passed, $FAILN failed ==="
[ "$FAILN" = 0 ] || exit 1
exit 0
