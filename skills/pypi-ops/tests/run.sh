#!/usr/bin/env bash
# Self-test for pypi-ops scripts.
#
# Offline-deterministic: builds throwaway fixtures, asserts documented exit codes
# and key output, then cleans up. The one network-touching check
# (publish-preflight's PyPI lookup) is asserted only where a *deterministic*
# failure dominates the exit code; the all-pass fixture tolerates {0 ok, 7
# pypi-unreachable}. Resolves paths relative to itself so it works in-repo and
# once installed to ~/.claude/skills/pypi-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
SHA="de0fac2e4500dabe0009e67214ff5f5447ce83dd"   # a real 40-hex sha (actions/checkout v6.0.2)

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit()  { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_in()    { case " $2 " in *" $3 "*) ok "$1 (exit $3)";; *) no "$1 (want one of [$2] got $3)";; esac; }
expect_has()   { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== pypi-ops self-test ==="

# ── publish-preflight.sh ───────────────────────────────────────────────────
echo "-- publish-preflight.sh --"
PF="$SCRIPTS/publish-preflight.sh"
bash "$PF" --help >/dev/null 2>&1;  expect_exit "--help" 0 $?
bash "$PF" --bogus >/dev/null 2>&1; expect_exit "bad flag -> 2" 2 $?
# --build is wired (the actual build is network/backend-dependent, not exercised offline)
# Captured, not `--help | grep -q`: under `set -o pipefail` grep -q's early exit
# SIGPIPEs the producer (141) and flakes the assert even on a match. See
# skills/fleet-ops/tests/run.sh for the pattern.
pf_help="$(bash "$PF" --help 2>&1)"
expect_has "--help documents --build" "--build" "$pf_help"
mkdir -p "$SB/empty"
bash "$PF" "$SB/empty" >/dev/null 2>&1; expect_exit "no pyproject -> 3" 3 $?

# clean fixture: versions agree, workflow uses OIDC, bogus pkg name (offline-safe)
mk_repo() {  # dir  pyproject_version  init_version  workflow_snippet
  local d="$1"
  mkdir -p "$d/src/zzzpkg" "$d/.github/workflows"
  cat > "$d/pyproject.toml" <<EOF
[project]
name = "zzz-claudemods-pypiops-fixture-xyz"
version = "$2"
EOF
  printf '__version__ = "%s"\n' "$3" > "$d/src/zzzpkg/__init__.py"
  printf '%s\n' "$4" > "$d/.github/workflows/publish.yml"
}
OIDC_WF=$'on:\n  push:\n    tags: ["v*"]\njobs:\n  publish:\n    environment: pypi\n    permissions:\n      id-token: write\n    steps:\n      - uses: pypa/gh-action-pypi-publish@'"$SHA"$' # v1.14.0'
TOKEN_WF=$'jobs:\n  publish:\n    steps:\n      - uses: pypa/gh-action-pypi-publish@'"$SHA"$'\n        with:\n          password: ${{ secrets.PYPI_API_TOKEN }}'

mk_repo "$SB/clean" "1.2.3" "1.2.3" "$OIDC_WF"
out="$(bash "$PF" "$SB/clean" 2>&1)"; rc=$?
expect_in  "clean fixture -> {0,7}" "0 7" "$rc"
expect_has "clean: init-version ok" "init-version" "$out"
expect_has "clean: workflow OIDC recognised" "OIDC" "$out"

# version-skew fixture: deterministic failure regardless of network
mk_repo "$SB/skew" "1.2.3" "1.2.4" "$OIDC_WF"
out="$(bash "$PF" "$SB/skew" 2>&1)"; rc=$?
expect_exit "version skew -> 10" 10 "$rc"
expect_has  "skew names the mismatch" "1.2.4" "$out"

# token-in-workflow fixture: workflow-oidc must fail -> 10
mk_repo "$SB/token" "1.2.3" "1.2.3" "$TOKEN_WF"
out="$(bash "$PF" "$SB/token" 2>&1)"; rc=$?
expect_exit "stored token -> 10" 10 "$rc"
expect_has  "token: flags stored token" "token" "$out"

# --json envelope shape (skew fixture, deterministic)
if command -v jq >/dev/null 2>&1; then
  out="$(bash "$PF" --json "$SB/skew" 2>/dev/null)"
  expect_has "json envelope schema" "publish-preflight/v1" "$out"
else
  echo "  SKIP  --json shape (jq not installed)"
fi

# ── diagnose-publish.sh ────────────────────────────────────────────────────
echo "-- diagnose-publish.sh --"
DG="$SCRIPTS/diagnose-publish.sh"
bash "$DG" --help >/dev/null 2>&1; expect_exit "--help" 0 $?
bash "$DG" >/dev/null 2>&1;        expect_exit "no arg -> 2" 2 $?
bash "$DG" --bogus >/dev/null 2>&1; expect_exit "bad flag -> 2" 2 $?

INVALID_LOG=$'Trusted publishing exchange failure:\n* `invalid-publisher`: valid token, but no corresponding publisher\n* `repository`: `0xDarkMatter/flarecrawl`\n* `environment`: `pypi`'
out="$(printf '%s' "$INVALID_LOG" | bash "$DG" - 2>&1)"; rc=$?
expect_exit "invalid-publisher -> 10" 10 "$rc"
expect_has  "classes PENDING_PUBLISHER" "PENDING_PUBLISHER" "$out"
expect_has  "surfaces presented claims" "0xDarkMatter/flarecrawl" "$out"

out="$(printf 'ERROR: File already exists (pkg-1.2.3.tar.gz)' | bash "$DG" - 2>&1)"; rc=$?
expect_exit "file-exists -> 10" 10 "$rc"
expect_has  "classes VERSION_EXISTS" "VERSION_EXISTS" "$out"

out="$(printf 'all green, nothing wrong here' | bash "$DG" - 2>&1)"; rc=$?
expect_exit "no pattern -> 0" 0 "$rc"

if command -v jq >/dev/null 2>&1; then
  out="$(printf '%s' "$INVALID_LOG" | bash "$DG" - --json 2>/dev/null)"
  expect_has "json schema present" "diagnose-publish/v1" "$out"
  expect_has "json carries class" "PENDING_PUBLISHER" "$out"
else
  echo "  SKIP  --json shape (jq not installed)"
fi

# ── check-action-pins.py ───────────────────────────────────────────────────
echo "-- check-action-pins.py --"
CP="$SCRIPTS/check-action-pins.py"
"$PYTHON" "$CP" --help >/dev/null 2>&1; expect_exit "--help" 0 $?
"$PYTHON" "$CP" "$SB/no-such.yml" >/dev/null 2>&1; expect_exit "missing file -> 3" 3 $?

printf 'jobs:\n  x:\n    steps:\n      - uses: actions/checkout@%s # v6.0.2\n' "$SHA" > "$SB/good.yml"
"$PYTHON" "$CP" --offline "$SB/good.yml" >/dev/null 2>&1; expect_exit "pinned+commented -> 0" 0 $?

printf 'jobs:\n  x:\n    steps:\n      - uses: actions/checkout@v4\n' > "$SB/tag.yml"
"$PYTHON" "$CP" --offline "$SB/tag.yml" >/dev/null 2>&1; expect_exit "tag not sha -> 10" 10 $?

printf 'jobs:\n  x:\n    steps:\n      - uses: actions/checkout@%s\n' "$SHA" > "$SB/nocomment.yml"
"$PYTHON" "$CP" --offline "$SB/nocomment.yml" >/dev/null 2>&1; expect_exit "sha w/o comment -> 10" 10 $?

out="$("$PYTHON" "$CP" --offline --json "$SB/good.yml" 2>/dev/null)"
expect_has "json schema present" "check-action-pins/v1" "$out"

# dogfood: the shipped asset must pass our own offline pin check
"$PYTHON" "$CP" --offline "$SKILL/assets/publish.yml" >/dev/null 2>&1
expect_exit "shipped publish.yml pins ok -> 0" 0 $?

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
