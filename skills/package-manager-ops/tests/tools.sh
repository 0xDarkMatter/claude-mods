#!/usr/bin/env bash
# Offline self-test for package-manager-ops' estate tools: scripts/pm-rollup.py (many repos
# -> one report) and scripts/lock-replay.py (composer.lock conflict -> composer commands).
#
# Kept apart from tests/run.sh (which owns the pm-audit matrix) so the two suites can move
# independently. Same conventions: offline, resolves paths relative to itself, fixtures end
# in `.fx` and are materialised (suffix stripped) into a temp dir - guard: do NOT rename
# them to bare composer.lock / package.json, scanners would read fixture packages as real.
#
# Every test is named for the bug it prevents. They were each watched failing against a
# deliberately broken copy of the tool (SKILL_DIR points the suite at another copy).
#
# Usage:   bash tests/tools.sh
#          SKILL_DIR=/path/to/copy bash tests/tools.sh      # prove a guard fails on a broken copy
# Input:   none
# Output:  PASS/FAIL rows on stderr; final tally line.
# Exit:    0 all pass, 1 any failure
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${SKILL_DIR:-$(dirname "$HERE")}"
FX="$HERE/fixtures/tools"
ROLLUP="$SKILL/scripts/pm-rollup.py"
REPLAY="$SKILL/scripts/lock-replay.py"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1" >&2; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; }
finish() { echo "=== $PASS passed, $FAIL failed ===" >&2; [[ "$FAIL" -eq 0 ]] || exit 1; exit 0; }

echo "=== package-manager-ops tools self-test ($SKILL) ===" >&2
PY="$(bash "$SKILL/scripts/run-python.sh" --which 2>/dev/null)" || { no "no Python 3.8+ (run-python.sh --which)"; finish; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# materialise <fixture-dir> <dest>: copy, stripping the .fx suffix
materialise() {
  mkdir -p "$2"
  local f rel
  while IFS= read -r f; do
    rel="${f#"$1"/}"; mkdir -p "$2/$(dirname "$rel")"; cp "$f" "$2/${rel%.fx}"
  done < <(find "$1" -type f -name '*.fx')
}
for d in repo-clean repo-bower lock-conflict lock-conflict-ragged lock-sides; do
  materialise "$FX/$d" "$TMP/$d"
done

ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [[ "$got" == "$want" ]] && ok "$lbl (exit $got)" || no "$lbl (want $want got $got)"; }
# has <label> <needle> <haystack>: fixed-string containment
has() { [[ "$3" == *"$2"* ]] && ok "$1" || no "$1 - missing: $2"; }
lacks() { [[ "$3" != *"$2"* ]] && ok "$1" || no "$1 - unexpected: $2"; }

# -- 1. pm-rollup -------------------------------------------------------------------------
ec 0 "pm-rollup py_compile"          "$PY" -m py_compile "$ROLLUP"
ec 0 "pm-rollup --help"              "$PY" "$ROLLUP" --help
ec 2 "pm-rollup no dirs -> 2"        "$PY" "$ROLLUP"
ec 2 "pm-rollup bad flag -> 2"       "$PY" "$ROLLUP" --bogus "$TMP/repo-clean"
ec 2 "pm-rollup bad --as-of -> 2"    "$PY" "$ROLLUP" --as-of 05/10/2026 "$TMP/repo-clean"
ec 3 "pm-rollup --from missing file -> 3" "$PY" "$ROLLUP" --from "$TMP/no-such-list.txt"
ec 0 "clean-only estate exits 0"     "$PY" "$ROLLUP" --as-of 2026-10-05 "$TMP/repo-clean"
ec 10 "estate with findings exits 10" "$PY" "$ROLLUP" --as-of 2026-10-05 "$TMP/repo-clean" "$TMP/repo-bower"

OUT="$("$PY" "$ROLLUP" --as-of 2026-10-05 "$TMP/repo-clean" "$TMP/repo-bower" "$TMP/repo-missing" 2>/dev/null)"
has "findings are grouped under their id heading"   "## legacy.bower" "$OUT"
has "a group lists the repo that raised it"          "repo-bower" "$OUT"
has "clean repos are named, not dropped"             "repo-clean" "$OUT"
# A repo that could not be audited must be reported with its exit code - silently dropping
# it would make a blind estate read as a clean one.
has "errored repo section exists"                    "## Errored (not audited)" "$OUT"
has "errored repo carries pm-audit's exit code"      "| 3 |" "$OUT"
has "waivers section is rendered"                    "## Waivers" "$OUT"
has "an expired waiver is flagged EXPIRED"           "EXPIRED" "$OUT"
has "a live waiver is flagged active"                "active" "$OUT"

ec 10 "errored repo alone is not a clean estate" "$PY" "$ROLLUP" "$TMP/repo-missing"

JSON="$("$PY" "$ROLLUP" --format json --as-of 2026-10-05 "$TMP/repo-clean" "$TMP/repo-bower" "$TMP/repo-missing" 2>/dev/null)"
echo "$JSON" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
ids = [r["id"] for r in d["data"]]
assert "legacy.bower" in ids, ids
row = next(r for r in d["data"] if r["id"] == "legacy.bower")
assert row["repo_count"] == 1 and row["repos"] == ["repo-bower"], row
assert d["meta"]["schema"].endswith("pm-rollup/v1"), d["meta"]
assert len(d["meta"]["errored"]) == 1 and d["meta"]["errored"][0]["exit"] == 3, d["meta"]["errored"]
' 2>/dev/null && ok "json envelope: grouped rows, schema, errored list" || no "json envelope shape"

# the list's CONTENT is read by python, which on Windows cannot open an MSYS /tmp path
WTMP="$(cygpath -m "$TMP" 2>/dev/null || echo "$TMP")"
printf '# estate list\n%s\n\n%s\n' "$WTMP/repo-clean" "$WTMP/repo-bower" > "$TMP/repos.txt"
FROM="$("$PY" "$ROLLUP" --from "$TMP/repos.txt" --as-of 2026-10-05 2>/dev/null)"
has "--from reads dirs, skipping comments and blanks" "## legacy.bower" "$FROM"
STDIN="$(printf '%s\n' "$WTMP/repo-bower" | "$PY" "$ROLLUP" --from - --as-of 2026-10-05 2>/dev/null)"
has "--from - reads stdin" "## legacy.bower" "$STDIN"

# stdout is data only: progress and verdicts go to stderr
STDOUT_ONLY="$("$PY" "$ROLLUP" --as-of 2026-10-05 "$TMP/repo-bower" 2>/dev/null)"
lacks "stdout carries no progress lines" "pm-rollup:" "$STDOUT_ONLY"

# -- 2. lock-replay -----------------------------------------------------------------------
ec 0 "lock-replay py_compile"        "$PY" -m py_compile "$REPLAY"
ec 0 "lock-replay --help"            "$PY" "$REPLAY" --help
ec 2 "lock-replay no args -> 2"      "$PY" "$REPLAY"
ec 2 "lock-replay only --ours -> 2"  "$PY" "$REPLAY" --ours "$TMP/lock-sides/ours.lock"
ec 2 "lock-replay lock + --ours -> 2" "$PY" "$REPLAY" "$TMP/lock-conflict/composer.lock" --ours "$TMP/lock-sides/ours.lock"
ec 3 "lock-replay missing file -> 3" "$PY" "$REPLAY" "$TMP/no-such.lock"
echo 'not a lock' > "$TMP/garbage.lock"
ec 4 "lock-replay non-lock input -> 4" "$PY" "$REPLAY" "$TMP/garbage.lock"
printf '<<<<<<< HEAD\n{"packages": []}\n' > "$TMP/unclosed.lock"
ec 4 "unclosed conflict marker -> 4, not a silent half-merge" "$PY" "$REPLAY" "$TMP/unclosed.lock"

LOCK="$TMP/lock-conflict/composer.lock"
BEFORE="$(cksum < "$LOCK")"
GOT="$("$PY" "$REPLAY" "$LOCK" 2>/dev/null)"; RC=$?
WANT='composer require acme/bump:1.2.0
composer require --dev acme/dev-tool:1.1.0
composer require acme/new-on-theirs:v3.0.0
composer remove acme/gone-on-theirs'
[[ "$RC" == 10 ]] && ok "conflicted lock: exit 10" || no "conflicted lock: want exit 10 got $RC"
[[ "$GOT" == "$WANT" ]] && ok "theirs replay: exact require/remove commands" || no "theirs replay differs: $GOT"
# the nested author object carries its own name+version; it must never read as a package
lacks "nested object name/version is not a package" "nested-author" "$GOT"
lacks "the diff3 base section is ignored" "0.9.0" "$GOT"
[[ "$(cksum < "$LOCK")" == "$BEFORE" ]] && ok "lock-replay never modifies the lock" || no "lock-replay modified the input"

GOT="$("$PY" "$REPLAY" --side ours "$LOCK" 2>/dev/null)"
WANT='composer require acme/bump:1.0.0
composer require --dev acme/dev-tool:1.0.0
composer require acme/gone-on-theirs:2.0.0
composer remove acme/new-on-theirs'
[[ "$GOT" == "$WANT" ]] && ok "--side ours reverses the direction" || no "--side ours differs: $GOT"

# A hunk that cuts an object, leaving a side that is not valid JSON, must still replay.
GOT="$("$PY" "$REPLAY" "$TMP/lock-conflict-ragged/composer.lock" 2>/dev/null)"
WANT='composer require acme/added:4.0.0
composer require acme/bump:1.2.0'
[[ "$GOT" == "$WANT" ]] && ok "ragged hunk (invalid-JSON side) replays via the line scanner" || no "ragged replay differs: $GOT"

GOT="$("$PY" "$REPLAY" --ours "$TMP/lock-sides/ours.lock" --theirs "$TMP/lock-sides/theirs.lock" 2>/dev/null)"
WANT='composer require acme/a:1.1.0
composer require acme/c:3.0.0
composer remove acme/b'
[[ "$GOT" == "$WANT" ]] && ok "--ours/--theirs files replay" || no "--ours/--theirs differs: $GOT"
ec 0 "identical sides -> nothing to replay (0)" "$PY" "$REPLAY" --ours "$TMP/lock-sides/ours.lock" --theirs "$TMP/lock-sides/ours.lock"
ec 0 "lock without markers -> 0" "$PY" "$REPLAY" "$TMP/repo-clean/composer.lock"

echo "$("$PY" "$REPLAY" --json "$LOCK" 2>/dev/null)" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
assert d["meta"]["schema"].endswith("lock-replay/v1") and d["meta"]["count"] == 4, d["meta"]
assert {r["action"] for r in d["data"]} == {"require", "remove"}
assert any(r["dev"] and r["package"] == "acme/dev-tool" for r in d["data"])
' 2>/dev/null && ok "lock-replay --json envelope" || no "lock-replay --json envelope"

# -- 3. copy-alone: the pair must run with nothing beside the skill folder ----------------
ALONE="$TMP/alone"; mkdir -p "$ALONE"
cp -R "$SKILL/scripts" "$ALONE/scripts"; mkdir -p "$ALONE/assets"; cp "$SKILL/assets/package-manager-facts.json" "$ALONE/assets/"
ec 0 "standalone pm-rollup --help"   bash "$ALONE/scripts/run-python.sh" "$ALONE/scripts/pm-rollup.py" --help
ec 0 "standalone pm-rollup on clean repo" bash "$ALONE/scripts/run-python.sh" "$ALONE/scripts/pm-rollup.py" --as-of 2026-10-05 "$TMP/repo-clean"
ec 0 "standalone lock-replay --help" bash "$ALONE/scripts/run-python.sh" "$ALONE/scripts/lock-replay.py" --help
ec 10 "standalone lock-replay on conflict" bash "$ALONE/scripts/run-python.sh" "$ALONE/scripts/lock-replay.py" "$LOCK"

finish
