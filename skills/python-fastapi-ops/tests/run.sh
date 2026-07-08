#!/usr/bin/env bash
# Self-test for python-fastapi-ops — fully offline, deterministic, Linux-safe.
#
# scaffold-api.sh emits a FastAPI module to stdout; it never opens a file for
# writing, so it cannot clobber a user's project. Every run here is redirected
# into a mktemp -d sandbox — nothing is ever written into the repo or a real
# project. Asserts the protocol contract (--help, exit codes, stream
# separation), the generated module's structure, byte-identical idempotency,
# and that the script owns no overwrite hazard (the only clobber is the
# caller's shell `>` redirect — a latent caller-side hazard, documented here,
# NOT "fixed" in the script per its contract).
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/scaffold-api.sh"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== python-fastapi-ops self-test ==="

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
bash -n "$V" 2>/dev/null && ok "bash -n scaffold-api.sh" || no "bash -n scaffold-api.sh"
bash "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
bash "$V" -h     >/dev/null 2>&1; expect_exit "-h exits 0" 0 $?
out="$(bash "$V" --help 2>/dev/null)"
expect_has "--help has Examples" "xamples" "$out"
expect_has "--help documents exit 2" "2" "$out"
bash "$V"          >/dev/null 2>&1; expect_exit "missing resource -> 2" 2 $?
bash "$V" --bogus  >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?

# usage/errors must go to stderr, never polluting the stdout data stream
err="$(bash "$V" 2>&1 >/dev/null)"
expect_has "missing-resource usage on stderr" "Usage:" "$err"
noso="$(bash "$V" --bogus 2>/dev/null)"
[[ -z "$noso" ]] && ok "unknown-flag writes nothing to stdout" || no "unknown-flag leaked to stdout"

# ── generated module structure ────────────────────────────────────────────────
echo "-- generated module --"
bash "$V" user >"$SB/user.py" 2>"$SB/user.err"; expect_exit "generate user -> 0" 0 $?
[[ -s "$SB/user.py" ]] && ok "module written to redirected stdout" || no "module not written"
[[ ! -s "$SB/user.err" ]] && ok "happy path is silent on stderr" || no "happy path wrote to stderr"
out="$(cat "$SB/user.py")"
expect_has "has Pydantic Create model"  "class UserCreate(BaseModel):" "$out"
expect_has "has Pydantic Update model"  "class UserUpdate(BaseModel):" "$out"
expect_has "has Pydantic Response model" "class UserResponse(BaseModel):" "$out"
expect_has "has APIRouter with prefix"  'router = APIRouter(prefix="/users"' "$out"
expect_has "has create endpoint"  "async def create_user" "$out"
expect_has "has list endpoint"    "async def list_users" "$out"
expect_has "has get endpoint"     "async def get_user" "$out"
expect_has "has update endpoint"  "async def update_user" "$out"
expect_has "has delete endpoint"  "async def delete_user" "$out"
expect_has "resource name in Create docstring" "Create user request" "$out"

# title-casing + pluralization for mixed-case input
bash "$V" Order >"$SB/order.py" 2>/dev/null; expect_exit "generate Order -> 0" 0 $?
out="$(cat "$SB/order.py")"
expect_has "title-cases Order"        "class OrderCreate(BaseModel):" "$out"
expect_has "pluralizes to orders"     'prefix="/orders"' "$out"
expect_has "orders create endpoint"   "async def create_order" "$out"

# ── idempotency: re-running produces byte-identical output ───────────────────
echo "-- idempotency --"
bash "$V" user >"$SB/a.py" 2>/dev/null
bash "$V" user >"$SB/b.py" 2>/dev/null
if cmp -s "$SB/a.py" "$SB/b.py"; then ok "re-run produces byte-identical output"; else no "re-run output differs"; fi

# ── overwrite safety ─────────────────────────────────────────────────────────
echo "-- overwrite safety --"
# The script emits to stdout only and never opens a file, so it is
# non-destructive by construction: running it leaves the cwd untouched. There
# is no --force/--no-clobber flag because the script has no file target to
# guard — the sole clobber path is the caller's own shell redirect (`>`),
# which the script cannot see. That caller-side hazard is documented here,
# not "fixed".
mkdir -p "$SB/cwd-check"
( cd "$SB/cwd-check" && bash "$V" user >/dev/null 2>&1 )
n="$(find "$SB/cwd-check" -type f | wc -l | tr -d ' ')"
[[ "$n" == "0" ]] && ok "script creates no files in cwd (non-destructive)" || no "script wrote files into cwd ($n)"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
