#!/usr/bin/env bash
# Self-test for python-pytest-ops — fully offline, deterministic, Linux-safe.
#
# generate-conftest.sh writes ./tests/conftest.py relative to the cwd and, when
# one already exists, prompts interactively (defaulting to KEEP the file). Every
# run executes inside a mktemp -d sandbox so nothing is ever written into the
# repo or a real project. Asserts the --help contract, the generated conftest's
# fixture blocks (base + --async/--db/--api), and the overwrite-safety guarantee:
# an existing user conftest.py is NOT clobbered unless the user answers the
# prompt with "y" (the documented mechanism — fed "n" here keeps the file).
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/generate-conftest.sh"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== python-pytest-ops self-test ==="

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
bash -n "$V" 2>/dev/null && ok "bash -n generate-conftest.sh" || no "bash -n generate-conftest.sh"
bash "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
bash "$V" -h     >/dev/null 2>&1; expect_exit "-h exits 0" 0 $?
out="$(bash "$V" --help 2>/dev/null)"
expect_has "--help has Examples" "xamples" "$out"
expect_has "--help lists --async" "--async" "$out"
expect_has "--help lists --db"    "--db" "$out"
expect_has "--help lists --api"   "--api" "$out"
# --help must short-circuit before any side effect (no file created even though
# the cwd has no tests/ dir)
mkdir -p "$SB/help-cwd"
( cd "$SB/help-cwd" && bash "$V" --help >/dev/null 2>&1 )
[[ ! -e "$SB/help-cwd/tests" ]] && ok "--help creates no files" || no "--help created files"

# ── fresh generation ──────────────────────────────────────────────────────────
echo "-- fresh generation --"
mkdir -p "$SB/fresh"
( cd "$SB/fresh" && bash "$V" </dev/null >"$SB/fresh.out" 2>"$SB/fresh.err" ); expect_exit "fresh generate -> 0" 0 $?
[[ -f "$SB/fresh/tests/conftest.py" ]] && ok "creates tests/conftest.py" || no "conftest.py not created"
out="$(cat "$SB/fresh/tests/conftest.py")"
expect_has "has module docstring"      "Pytest configuration and fixtures" "$out"
expect_has "imports pytest"            "import pytest" "$out"
expect_has "registers slow marker"     '"slow: marks tests as slow"' "$out"
expect_has "has sample_data fixture"   "def sample_data():" "$out"
expect_has "has temp_file fixture"     "def temp_file(tmp_path):" "$out"
expect_has "has pytest_addoption"      "def pytest_addoption(parser):" "$out"
expect_has "summary on stdout"         "Generated tests/conftest.py" "$(cat "$SB/fresh.out")"

# ── fixture-block flags ───────────────────────────────────────────────────────
echo "-- fixture blocks --"
mkdir -p "$SB/all"
( cd "$SB/all" && bash "$V" --async --db --api </dev/null >/dev/null 2>&1 ); expect_exit "all flags -> 0" 0 $?
out="$(cat "$SB/all/tests/conftest.py")"
expect_has "--async adds event_loop"    "def event_loop():" "$out"
expect_has "--async adds async_client"  "async def async_client():" "$out"
expect_has "--db adds db_engine"        "def db_engine():" "$out"
expect_has "--db adds db_session"       "def db_session(db_engine):" "$out"
expect_has "--api adds client fixture"  "def client(app):" "$out"
expect_has "--api adds authed client"   "def authenticated_client(client):" "$out"

# base generation must NOT include the optional blocks
! grep -q "def event_loop" "$SB/fresh/tests/conftest.py" && ok "base omits async blocks" || no "base included async blocks"
! grep -q "def db_engine"  "$SB/fresh/tests/conftest.py" && ok "base omits db blocks"    || no "base included db blocks"
! grep -q "def client"     "$SB/fresh/tests/conftest.py" && ok "base omits api blocks"   || no "base included api blocks"

# ── overwrite safety ─────────────────────────────────────────────────────────
echo "-- overwrite safety --"
# Decline ("n", the documented default) MUST preserve an existing user conftest.
mkdir -p "$SB/ow/tests"
printf '# USER-SENTINEL: do not overwrite me\nimport user_thing\n' >"$SB/ow/tests/conftest.py"
( cd "$SB/ow" && printf 'n\n' | bash "$V" >/dev/null 2>&1 ); expect_exit "decline overwrite -> 0" 0 $?
out="$(cat "$SB/ow/tests/conftest.py")"
expect_has "user conftest preserved (decline)" "USER-SENTINEL" "$out"
expect_has "user import preserved (decline)"   "import user_thing" "$out"

# Confirming ("y") DOES replace the file — that is the documented overwrite path.
mkdir -p "$SB/ow2/tests"
printf '# USER-SENTINEL-2\n' >"$SB/ow2/tests/conftest.py"
( cd "$SB/ow2" && printf 'y\n' | bash "$V" >/dev/null 2>&1 ); expect_exit "confirm overwrite -> 0" 0 $?
out="$(cat "$SB/ow2/tests/conftest.py")"
! grep -q "USER-SENTINEL-2" "$SB/ow2/tests/conftest.py" && ok "confirm 'y' replaces user conftest" || no "confirm 'y' did not replace"
expect_has "new conftest has pytest import" "import pytest" "$out"

# Non-interactive (closed stdin, no answer) also keeps the existing file — the
# safe default when there is no TTY to answer the prompt.
mkdir -p "$SB/ow3/tests"
printf '# USER-SENTINEL-3\n' >"$SB/ow3/tests/conftest.py"
( cd "$SB/ow3" && bash "$V" </dev/null >/dev/null 2>&1 )
expect_has "closed-stdin keeps user conftest" "USER-SENTINEL-3" "$(cat "$SB/ow3/tests/conftest.py")"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
