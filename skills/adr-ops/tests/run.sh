#!/usr/bin/env bash
# Self-test for adr-ops scripts (adr-new.sh, adr-index.sh, adr-lint.py).
#
# Offline-deterministic (no network). Builds throwaway ADR fixtures, asserts the
# documented exit codes and key output of each script, then cleans up. Resolves
# paths relative to itself so it works both in the repo and once installed to
# ~/.claude/skills/adr-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
NEW="$SCRIPTS/adr-new.sh"
INDEX="$SCRIPTS/adr-index.sh"
LINT="$SCRIPTS/adr-lint.py"
TOUCHING="$SCRIPTS/adr-touching.py"
INIT="$SCRIPTS/adr-init.sh"

# Pick a python that actually executes — skips the Windows Store `python3` stub.
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

# Write a minimal conformant ADR.
#   make_adr <dir> <NNN> <slug> <status> <date> <supersedes-yaml> <superseded-by-yaml>
make_adr() {
  local dir="$1" nnn="$2" slug="$3" status="$4" date="$5" sup="$6" supby="$7"
  cat > "$dir/ADR-$nnn-$slug.md" <<EOF
---
status: $status
date: $date
supersedes: $sup
superseded-by: $supby
touches:
  - "src/x.py"
---

# ADR-$nnn: $slug Title

## Decision (one sentence)

The system does the $slug thing by default.

## Context

Some forces were in play.

## Alternatives considered

We considered nothing and it lost.

## Consequences

### Positive
- Good.

### Negative
- Cost.

### Non-goals
- Not that.

## See also

- src/x.py
EOF
}

echo "=== adr-ops self-test (python: $PYTHON) ==="

# ── --help contracts (exit 0) ──────────────────────────────────────────────
echo "-- --help --"
bash "$NEW"   --help >/dev/null 2>&1; expect_exit "adr-new --help" 0 $?
bash "$INDEX" --help >/dev/null 2>&1; expect_exit "adr-index --help" 0 $?
"$PYTHON" "$LINT" --help >/dev/null 2>&1; expect_exit "adr-lint --help" 0 $?
"$PYTHON" "$TOUCHING" --help >/dev/null 2>&1; expect_exit "adr-touching --help" 0 $?
bash "$INIT" --help >/dev/null 2>&1; expect_exit "adr-init --help" 0 $?

# ── adr-lint.py: clean conformant pair -> 0 ────────────────────────────────
echo "-- adr-lint: clean --"
CLEAN="$SB/clean"; mkdir -p "$CLEAN"
make_adr "$CLEAN" 001 alpha accepted 2026-01-01 "[]" "[]"
make_adr "$CLEAN" 002 beta  accepted 2026-01-02 "[]" "[]"
"$PYTHON" "$LINT" --dir "$CLEAN" >/dev/null 2>&1; expect_exit "clean pair -> 0" 0 $?

# ── adr-lint.py: missing dir -> 3 ──────────────────────────────────────────
"$PYTHON" "$LINT" --dir "$SB/no-such-dir" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?

# ── adr-lint.py: missing required field -> 10 ──────────────────────────────
echo "-- adr-lint: findings --"
MISS="$SB/missing"; mkdir -p "$MISS"
cat > "$MISS/ADR-001-x.md" <<'EOF'
---
status: accepted
date: 2026-01-01
superseded-by: []
touches:
  - "a"
---

# ADR-001: X

## Decision (one sentence)

Rule.

## Context
## Alternatives considered
## Consequences
## See also
EOF
out="$("$PYTHON" "$LINT" --dir "$MISS" 2>&1)"; rc=$?
expect_exit "missing 'supersedes' field -> 10" 10 "$rc"
expect_has  "names missing field" "supersedes" "$out"

# ── adr-lint.py: bad status -> 10 ──────────────────────────────────────────
BADS="$SB/badstatus"; mkdir -p "$BADS"
make_adr "$BADS" 001 x bogus 2026-01-01 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$BADS" 2>&1)"; rc=$?
expect_exit "bad status -> 10" 10 "$rc"
expect_has  "flags bad status" "not in" "$out"

# ── adr-lint.py: broken supersession (one-sided) -> 10 ─────────────────────
BROKE="$SB/broken-sup"; mkdir -p "$BROKE"
# 002 supersedes 001, but 001 was NOT flipped (still accepted, empty superseded-by).
make_adr "$BROKE" 001 old accepted 2026-01-01 "[]" "[]"
make_adr "$BROKE" 002 new accepted 2026-01-02 "[ADR-001]" "[]"
out="$("$PYTHON" "$LINT" --dir "$BROKE" 2>&1)"; rc=$?
expect_exit "broken supersession -> 10" 10 "$rc"
expect_has  "flags one-sided supersession" "superseded-by" "$out"

# ── adr-lint.py: a properly-flipped supersession pair is clean -> 0 ─────────
GOODSUP="$SB/good-sup"; mkdir -p "$GOODSUP"
make_adr "$GOODSUP" 001 old superseded 2026-01-01 "[]" "[ADR-002]"
make_adr "$GOODSUP" 002 new accepted   2026-01-02 "[ADR-001]" "[]"
"$PYTHON" "$LINT" --dir "$GOODSUP" >/dev/null 2>&1; expect_exit "valid supersession pair -> 0" 0 $?

# ── adr-lint.py: duplicate number -> 10 ────────────────────────────────────
DUP="$SB/dup"; mkdir -p "$DUP"
make_adr "$DUP" 001 a accepted 2026-01-01 "[]" "[]"
make_adr "$DUP" 001 b accepted 2026-01-02 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$DUP" 2>&1)"; rc=$?
expect_exit "duplicate number -> 10" 10 "$rc"
expect_has  "flags duplicate" "duplicate ADR number" "$out"

# ── adr-lint.py: unparseable frontmatter -> 4 ──────────────────────────────
BADFM="$SB/badfm"; mkdir -p "$BADFM"
printf '# ADR-001: No Frontmatter\n\n## Decision (one sentence)\nRule.\n' > "$BADFM/ADR-001-x.md"
"$PYTHON" "$LINT" --dir "$BADFM" >/dev/null 2>&1; expect_exit "no frontmatter fence -> 4" 4 $?

# ── adr-lint.py: --json envelope ───────────────────────────────────────────
out="$("$PYTHON" "$LINT" --dir "$DUP" --json 2>/dev/null)"
expect_has "json envelope schema" "claude-mods.adr-ops.lint/v1" "$out"

# ── adr-new.sh: computes next number, derives slug ─────────────────────────
echo "-- adr-new --"
NEWDIR="$SB/newdir"; mkdir -p "$NEWDIR"
make_adr "$NEWDIR" 001 alpha accepted 2026-01-01 "[]" "[]"
make_adr "$NEWDIR" 007 gamma accepted 2026-01-02 "[]" "[]"
out="$(bash "$NEW" --dir "$NEWDIR" --title "Cache The Things" --date 2026-02-02 2>/dev/null)"; rc=$?
expect_exit "adr-new -> 0" 0 "$rc"
expect_has  "next number is highest+1 (008)" "ADR-008-cache-the-things.md" "$out"
[[ -f "$NEWDIR/ADR-008-cache-the-things.md" ]] && ok "file written" || no "file not written"
# the written file passes the linter
"$PYTHON" "$LINT" --dir "$NEWDIR" >/dev/null 2>&1; expect_exit "scaffolded file lints clean -> 0" 0 $?

# ── adr-new.sh: refuses to overwrite -> 5 ──────────────────────────────────
# A pre-existing target must never be clobbered. Create one (ADR-004 already on
# disk), then ask adr-new to write that exact slot via --number — the precondition
# guard must refuse. (--number also exercises the explicit-number override path.)
OWDIR="$SB/overwrite"; mkdir -p "$OWDIR"
make_adr "$OWDIR" 004 collide accepted 2026-01-01 "[]" "[]"
bash "$NEW" --dir "$OWDIR" --title "Collide" --slug collide --number 4 --date 2026-02-02 >/dev/null 2>&1
expect_exit "refuse overwrite -> 5" 5 $?
# --number on a free slot writes there (and lints clean).
bash "$NEW" --dir "$OWDIR" --title "Backfill Two" --slug backfill-two --number 2 --date 2026-02-02 >/dev/null 2>&1
expect_exit "--number free slot writes -> 0" 0 $?
[[ -f "$OWDIR/ADR-002-backfill-two.md" ]] && ok "--number wrote ADR-002" || no "--number did not write ADR-002"

# ── adr-new.sh: --dry-run writes nothing ───────────────────────────────────
DRY="$SB/dry"; mkdir -p "$DRY"
before="$(ls "$DRY" | wc -l)"
out="$(bash "$NEW" --dir "$DRY" --title "Dry Run Test" --dry-run 2>/dev/null)"; rc=$?
expect_exit "dry-run -> 0" 0 "$rc"
after="$(ls "$DRY" | wc -l)"
[[ "$before" == "$after" ]] && ok "dry-run wrote nothing" || no "dry-run wrote a file"
expect_has "dry-run prints target path" "ADR-001-dry-run-test.md" "$out"

# ── adr-new.sh: bad status -> 2, missing title -> 2 ────────────────────────
bash "$NEW" --dir "$NEWDIR" --title "X" --status nonsense >/dev/null 2>&1; expect_exit "bad status -> 2" 2 $?
bash "$NEW" --dir "$NEWDIR" >/dev/null 2>&1; expect_exit "missing title -> 2" 2 $?
bash "$NEW" --dir "$SB/no-such" --title "X" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?

# ── adr-new.sh: --apply-supersede flips the old record ─────────────────────
SUPDIR="$SB/supdir"; mkdir -p "$SUPDIR"
make_adr "$SUPDIR" 001 router accepted 2026-01-01 "[]" "[]"
bash "$NEW" --dir "$SUPDIR" --title "New Router" --supersedes ADR-001 --apply-supersede --date 2026-03-03 >/dev/null 2>&1
expect_exit "apply-supersede -> 0" 0 $?
"$PYTHON" "$LINT" --dir "$SUPDIR" >/dev/null 2>&1
expect_exit "auto-flipped pair lints clean -> 0" 0 $?

# ── adr-index.sh: one row per ADR, in order ────────────────────────────────
echo "-- adr-index --"
out="$(bash "$INDEX" --dir "$CLEAN" 2>/dev/null)"; rc=$?
expect_exit "adr-index -> 0" 0 "$rc"
lines="$(printf '%s\n' "$out" | grep -c '^ADR-')"
[[ "$lines" == 2 ]] && ok "two ADRs -> two rows" || no "expected 2 rows, got $lines"
expect_has "row carries status" "accepted" "$out"
bash "$INDEX" --dir "$SB/no-such-dir" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?
out="$(bash "$INDEX" --dir "$CLEAN" --json 2>/dev/null)"
expect_has "json envelope schema" "claude-mods.adr-ops.index/v1" "$out"

# ── adr-lint.py: lifecycle consistency checks ──────────────────────────────
echo "-- adr-lint: lifecycle --"
# superseded with empty superseded-by -> error -> 10
LCS="$SB/lc-sup-empty"; mkdir -p "$LCS"
make_adr "$LCS" 001 a superseded 2026-01-01 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$LCS" 2>&1)"; rc=$?
expect_exit "superseded w/ empty superseded-by -> 10" 10 "$rc"
expect_has  "names the lifecycle error" "must name its successor" "$out"

# deprecated with non-empty superseded-by -> error -> 10
LCD="$SB/lc-dep"; mkdir -p "$LCD"
make_adr "$LCD" 001 a deprecated 2026-01-01 "[]" "[ADR-002]"
make_adr "$LCD" 002 b accepted   2026-01-02 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$LCD" 2>&1)"; rc=$?
expect_exit "deprecated w/ superseded-by -> 10" 10 "$rc"
expect_has  "names the deprecated error" "nothing replaces it" "$out"

# accepted (in force) with superseded-by -> error -> 10. Pair it with a valid
# back-reference so ONLY the lifecycle error fires (no bidirectionality noise),
# proving the two checks don't double-report.
LCA="$SB/lc-accepted"; mkdir -p "$LCA"
make_adr "$LCA" 001 a accepted 2026-01-01 "[]"          "[ADR-002]"
make_adr "$LCA" 002 b accepted 2026-01-02 "[ADR-001]"   "[]"
out="$("$PYTHON" "$LINT" --dir "$LCA" 2>&1)"; rc=$?
expect_exit "accepted w/ superseded-by -> 10" 10 "$rc"
expect_has  "names the in-force error" "in force" "$out"

# ── adr-lint.py: stale touches: warning ────────────────────────────────────
echo "-- adr-lint: stale touches --"
# An ADR whose touches: lists a literal path absent under --repo-root. Warning
# tier: exit 0 normally, exit 10 under --strict. (make_adr writes touches src/x.py;
# the sandbox repo-root has no such file, so it's stale by construction.)
STALE="$SB/stale"; mkdir -p "$STALE"
make_adr "$STALE" 001 a accepted 2026-01-01 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$STALE" --repo-root "$SB" 2>&1)"; rc=$?
expect_exit "stale touches normally -> 0" 0 "$rc"
expect_has  "warns on stale touches path" "no longer exists" "$out"
"$PYTHON" "$LINT" --dir "$STALE" --repo-root "$SB" --strict >/dev/null 2>&1
expect_exit "stale touches --strict -> 10" 10 $?
# When the path DOES exist under repo-root, no stale warning.
mkdir -p "$STALE/repo/src"; : > "$STALE/repo/src/x.py"
out="$("$PYTHON" "$LINT" --dir "$STALE" --repo-root "$STALE/repo" 2>&1)"
case "$out" in *"no longer exists"*) no "existing touches path still flagged";; *) ok "existing touches path not flagged";; esac

# ── adr-touching.py: exact / prefix / glob / config-key / no-match ──────────
echo "-- adr-touching --"
TCH="$SB/touching"; mkdir -p "$TCH"
cat > "$TCH/ADR-001-auth.md" <<'EOF'
---
status: accepted
date: 2026-01-01
supersedes: []
superseded-by: []
touches:
  - "src/auth.py"
  - "lib/**"
  - "config.yaml:db.host"
---

# ADR-001: Auth Title

## Decision (one sentence)

Rule.

## Context
C.

## Alternatives considered
A.

## Consequences
### Positive
- G.

## See also
- x
EOF

# exact match -> 10, names the ADR
out="$("$PYTHON" "$TOUCHING" --dir "$TCH" src/auth.py 2>/dev/null)"; rc=$?
expect_exit "touching exact match -> 10" 10 "$rc"
expect_has  "touching names the ADR" "ADR-001" "$out"
# prefix query (dir governs file) -> 10
"$PYTHON" "$TOUCHING" --dir "$TCH" src/ >/dev/null 2>&1; expect_exit "touching prefix query -> 10" 10 $?
# glob query matches a literal touches entry -> 10
"$PYTHON" "$TOUCHING" --dir "$TCH" 'src/*.py' >/dev/null 2>&1; expect_exit "touching glob query -> 10" 10 $?
# touches glob matches a concrete query path -> 10
"$PYTHON" "$TOUCHING" --dir "$TCH" lib/deep/thing.go >/dev/null 2>&1; expect_exit "touching matched by touches-glob -> 10" 10 $?
# config-key exact -> 10
"$PYTHON" "$TOUCHING" --dir "$TCH" config.yaml:db.host >/dev/null 2>&1; expect_exit "touching config-key -> 10" 10 $?
# no governing ADR -> 0
"$PYTHON" "$TOUCHING" --dir "$TCH" other/unrelated.txt >/dev/null 2>&1; expect_exit "touching no match -> 0" 0 $?
# dir not found -> 3
"$PYTHON" "$TOUCHING" --dir "$SB/no-such-dir" src/auth.py >/dev/null 2>&1; expect_exit "touching missing dir -> 3" 3 $?
# missing query -> 2
"$PYTHON" "$TOUCHING" --dir "$TCH" >/dev/null 2>&1; expect_exit "touching missing query -> 2" 2 $?
# --json envelope schema
out="$("$PYTHON" "$TOUCHING" --dir "$TCH" --json src/auth.py 2>/dev/null)"
expect_has "touching json envelope schema" "claude-mods.adr-ops.touching/v1" "$out"

# ── non-Latin-1 text must not break the exit contract (regression) ──────────
# Both Python tools print ADR titles / touches: entries / field values verbatim.
# On Windows those streams default to cp1252 whenever redirected, so a title
# carrying an em dash or an arrow raised UnicodeEncodeError *after* the work was
# done: the traceback replaced the findings and the process exited 1, making a
# governed path look ungoverned and a dirty repo look clean. PYTHONIOENCODING is
# pinned to cp1252 here so the regression is reproduced deterministically on every
# platform, not just on a Windows box — the import-time reconfigure must win over
# it. Assert the documented codes AND that the text actually survives.
echo "-- non-Latin-1 titles --"
U8="$SB/utf8"; mkdir -p "$U8/src"; : > "$U8/src/auth.py"
cat > "$U8/ADR-001-write-path.md" <<'EOF'
---
status: accepted
date: 2026-01-01
supersedes: []
superseded-by: []
touches:
  - "src/auth.py"
---

# ADR-001: Propose→Approve Is The Only Chat→Profile Write Path

## Decision (one sentence)

Writes reach the profile only via propose→approve — never a direct chat write.

## Context
C — an em dash lives here too.

## Alternatives considered
A.

## Consequences
### Positive
- G.

## See also
- x
EOF

out="$(PYTHONIOENCODING=cp1252 "$PYTHON" "$TOUCHING" --dir "$U8" src/auth.py 2>/dev/null)"; rc=$?
expect_exit "touching: non-Latin-1 title still exits 10" 10 "$rc"
expect_has  "touching: non-Latin-1 title survives to stdout" "Chat→Profile" "$out"

out="$(PYTHONIOENCODING=cp1252 "$PYTHON" "$TOUCHING" --dir "$U8" --json src/auth.py 2>/dev/null)"; rc=$?
expect_exit "touching --json: non-Latin-1 title still exits 10" 10 "$rc"
expect_has  "touching --json: envelope intact" "claude-mods.adr-ops.touching/v1" "$out"

# A conformant record with a non-Latin-1 title lints clean -> 0.
PYTHONIOENCODING=cp1252 "$PYTHON" "$LINT" --dir "$U8" --repo-root "$U8" >/dev/null 2>&1
expect_exit "lint: non-Latin-1 title lints clean -> 0" 0 $?

# A finding that QUOTES non-Latin-1 text must still reach stdout, and still exit 10.
cat > "$U8/ADR-002-boundary.md" <<'EOF'
---
status: accepted
date: 2026-01-01
supersedes: ["ADR-001 → replaced"]
superseded-by: []
touches:
  - "src/auth.py"
---

# ADR-002: Chat→Profile Boundary

## Decision (one sentence)

The boundary is one-way.

## Context
C.

## Alternatives considered
A.

## Consequences
### Positive
- G.

## See also
- x
EOF
out="$(PYTHONIOENCODING=cp1252 "$PYTHON" "$LINT" --dir "$U8" --repo-root "$U8" 2>/dev/null)"; rc=$?
expect_exit "lint: finding quoting non-Latin-1 text still exits 10" 10 "$rc"
expect_has  "lint: non-Latin-1 finding survives to stdout" "ADR-001 → replaced" "$out"

# ── adr-init.sh: bootstrap, refuse populated, dry-run ──────────────────────
echo "-- adr-init --"
INITD="$SB/init"
bash "$INIT" --dir "$INITD/docs/adr" --first-title "Adopt ADRs" >/dev/null 2>&1
expect_exit "adr-init -> 0" 0 $?
[[ -f "$INITD/docs/adr/ADR-001-adopt-adrs.md" ]] && ok "init scaffolded ADR-001" || no "init did not scaffold ADR-001"
[[ -f "$INITD/docs/adr/README.md" ]] && ok "init wrote README.md" || no "init did not write README.md"
case "$(cat "$INITD/docs/adr/README.md" 2>/dev/null)" in
  *"generated by adr-init.sh"*) ok "init README carries generated marker";;
  *) no "init README missing generated marker";;
esac
# the scaffolded ADR-001 lints clean (repo-root = init root; touches paths are template placeholders -> warnings only, exit 0)
"$PYTHON" "$LINT" --dir "$INITD/docs/adr" --repo-root "$INITD" >/dev/null 2>&1
expect_exit "init ADR-001 lints clean -> 0" 0 $?
# refuses a populated dir -> 5
bash "$INIT" --dir "$INITD/docs/adr" >/dev/null 2>&1; expect_exit "init refuses populated dir -> 5" 5 $?
# --dry-run writes nothing into a fresh location
DRYI="$SB/init-dry"
bash "$INIT" --dir "$DRYI/docs/adr" --dry-run >/dev/null 2>&1; expect_exit "init dry-run -> 0" 0 $?
[[ -e "$DRYI" ]] && no "init dry-run created files" || ok "init dry-run wrote nothing"

# ── adr-index.sh: --output generated file ──────────────────────────────────
echo "-- adr-index --output --"
OUTF="$SB/index-out.md"
bash "$INDEX" --dir "$CLEAN" --output "$OUTF" >/dev/null 2>&1; expect_exit "adr-index --output -> 0" 0 $?
[[ -f "$OUTF" ]] && ok "--output wrote a file" || no "--output wrote no file"
outc="$(cat "$OUTF" 2>/dev/null)"
expect_has "--output has the table header" "| # | Status | Date | Title |" "$outc"
expect_has "--output carries the generated marker" "do not hand-edit" "$outc"
expect_has "--output lists a row" "ADR-001" "$outc"
# --json + --output is a usage error -> 2
bash "$INDEX" --dir "$CLEAN" --json --output "$SB/x.md" >/dev/null 2>&1; expect_exit "index --json+--output -> 2" 2 $?

# ── terminal design system (term.sh adoption + ASCII fallback) ─────────────
echo "-- terminal design system --"

# Bash scripts adopt the shared toolkit (full panel grammar), not hand-rolled ANSI.
for s in "$INDEX" "$NEW" "$INIT"; do
  b="$(basename "$s")"
  if grep -q '_lib/term.sh' "$s"; then ok "$b sources _lib/term.sh"; else no "$b does not source _lib/term.sh"; fi
done
# Python scripts carry the inline Term helper (term.sh is bash-only; spec §9).
for s in "$LINT" "$TOUCHING"; do
  b="$(basename "$s")"
  if grep -q 'class Term' "$s"; then ok "$b carries inline Term helper"; else no "$b missing inline Term helper"; fi
done

# term.sh primitives are pure ASCII under TERM_ASCII=1 (design principle #3).
LIBTERM="$SKILL/../_lib/term.sh"
if [[ -f "$LIBTERM" ]]; then
  ok "term.sh present"
  prims="$(TERM_ASCII=1 LT="$LIBTERM" bash -c '. "$LT"; term_init; printf "%s%s%s%s%s" \
    "$(term_mark ok)" "$(term_mark bad)" "$(term_status_row ok lbl val)" \
    "$TERM_DOT" "$(term_panel_open adr adr x)"')"
  if printf '%s' "$prims" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
    no "term.sh TERM_ASCII=1 primitives still emit non-ASCII bytes"
  else ok "term.sh TERM_ASCII=1 primitives are pure ASCII"; fi
else
  no "term.sh missing at $LIBTERM"
fi

# adr-index panel: full bordered frame under FORCE_COLOR, pure ASCII under TERM_ASCII=1.
PB="$SB/panel"; mkdir -p "$PB"
make_adr "$PB" 001 alpha accepted 2026-01-01 "[]" "[]"
pout="$(TERM_ASCII=1 FORCE_COLOR=1 bash "$INDEX" --dir "$PB" 2>/dev/null)"
if printf '%s' "$pout" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
  no "adr-index panel emits non-ASCII under TERM_ASCII=1"
else ok "adr-index panel is pure ASCII under TERM_ASCII=1"; fi
case "$pout" in *"+-- "*) ok "adr-index renders the full panel frame";; *) no "adr-index panel frame missing";; esac
# Piped (non-TTY, no FORCE_COLOR) stays plain data rows — the stdout contract.
pp="$(bash "$INDEX" --dir "$PB" 2>/dev/null)"
case "$pp" in
  *$'\033'*) no "piped adr-index leaked ANSI into the data stream";;
  *"ADR-001 | accepted"*) ok "piped adr-index stays plain data rows";;
  *) no "piped adr-index lost its data row";;
esac

# Python inline Term: colorizes under FORCE_COLOR, pure ASCII under TERM_ASCII=1,
# byte-plain when piped (the data contract).
pylint="$(TERM_ASCII=1 FORCE_COLOR=1 "$PYTHON" "$LINT" --dir "$DUP" 2>/dev/null)"
if printf '%s' "$pylint" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
  no "adr-lint colored output emits non-ASCII under TERM_ASCII=1"
else ok "adr-lint colored output is pure ASCII under TERM_ASCII=1"; fi
case "$pylint" in *$'\033'*) ok "adr-lint colorizes under FORCE_COLOR";; *) no "adr-lint did not colorize under FORCE_COLOR";; esac
plain_lint="$("$PYTHON" "$LINT" --dir "$DUP" 2>/dev/null)"
case "$plain_lint" in *$'\033'*) no "piped adr-lint leaked ANSI";; *) ok "piped adr-lint stays plain data";; esac

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
