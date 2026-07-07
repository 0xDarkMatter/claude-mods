#!/usr/bin/env bash
# Self-test for the fleet-worker skill scripts.
#
# Offline + deterministic (no network). Mocks `claude` and `keyring` on a
# controlled PATH, then asserts the launcher's auth isolation, key-resolution
# chain, no-key-leak, and arg forwarding; fleet-collect's success/failure gating;
# and fleet-doctor's --offline / --help / ASCII purity. Resolves paths relative to
# itself so it runs both in the repo and once installed to ~/.claude/skills/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures (SKIP+exit 0 if jq is unavailable)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
WORKER="$SCRIPTS/fleet-worker"
COLLECT="$SCRIPTS/fleet-collect.sh"
DOCTOR="$SCRIPTS/fleet-doctor.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
ee() { [ "$2" = "$3" ] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
eh() { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== fleet-worker self-test ==="

# ── Mock bin: a fake `claude` that records env+args to a probe file and prints
#    only a marker, plus a fake `keyring`. A controlled PATH keeps the real
#    claude out so launcher behaviour is deterministic. ──────────────────────
MB="$SB/bin"; mkdir -p "$MB"
PROBE="$SB/probe.txt"
cat > "$MB/claude" <<EOF
#!/usr/bin/env bash
{
  echo "CONFIG=\$CLAUDE_CONFIG_DIR"
  echo "BASE=\$ANTHROPIC_BASE_URL"
  echo "OPUS=\$ANTHROPIC_DEFAULT_OPUS_MODEL"
  echo "SONNET=\$ANTHROPIC_DEFAULT_SONNET_MODEL"
  echo "HAIKU=\$ANTHROPIC_DEFAULT_HAIKU_MODEL"
  echo "TOKEN=\$ANTHROPIC_AUTH_TOKEN"
  echo "ARGS=\$*"
} > "$PROBE"
echo "MOCK_CLAUDE_RAN"
EOF
chmod +x "$MB/claude"
cat > "$MB/keyring" <<'EOF'
#!/usr/bin/env bash
# keyring get <service> <key>
[ "${1:-}" = "get" ] && echo "KEYRING-TOKEN-${3:-}"
EOF
chmod +x "$MB/keyring"
PC="$MB:/usr/bin:/bin"   # controlled PATH: mock first, no real claude

echo "-- launcher --"
"$WORKER" --help >/dev/null 2>&1; ee "worker --help" 0 $?

# Success: env isolation + model mapping + arg forwarding + key never printed
CFG="$SB/cfg-a"
out="$(PATH="$PC" FLEET_WORKER_CONFIG_DIR="$CFG" \
       ANTHROPIC_AUTH_TOKEN="" ZHIPU_API_KEY="SEKRET-AAA" GLM_API_KEY="" \
       "$WORKER" --output-format json "do a thing" 2>&1)"; rc=$?
ee "worker runs with key" 0 "$rc"
eh "mock claude executed" "MOCK_CLAUDE_RAN" "$out"
case "$out" in *SEKRET-AAA*) no "worker leaked key to its own output";; *) ok "worker never prints the key";; esac
P="$(cat "$PROBE")"
eh "isolated CLAUDE_CONFIG_DIR set" "CONFIG=$CFG" "$P"
eh "z.ai base url set"              "BASE=https://api.z.ai/api/anthropic" "$P"
eh "sonnet maps to GLM-5.2"         "SONNET=GLM-5.2" "$P"
eh "haiku maps to GLM-4.5-Air"      "HAIKU=GLM-4.5-Air" "$P"
eh "key reached claude via env"     "TOKEN=SEKRET-AAA" "$P"
eh "bakes flags + forwards args"    "ARGS=-p --model sonnet --permission-mode bypassPermissions --output-format json do a thing" "$P"
[ -f "$CFG/settings.json" ] && ok "seeds settings.json" || no "settings.json not seeded"
eh "settings carries effortLevel"   "effortLevel" "$(cat "$CFG/settings.json" 2>/dev/null)"

# Permission-mode knob: default stays bypassPermissions (asserted above); override flows through.
: > "$PROBE"
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-pm" ANTHROPIC_AUTH_TOKEN="T" \
  FLEET_WORKER_PERMISSION_MODE="dontAsk" \
  "$WORKER" --allowedTools "Read" "hi" >/dev/null 2>&1
eh "permission-mode override flows through" "--permission-mode dontAsk" "$(cat "$PROBE")"

# Invalid permission mode -> usage exit 2
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-pm2" ANTHROPIC_AUTH_TOKEN="T" \
  FLEET_WORKER_PERMISSION_MODE="bogus" \
  "$WORKER" "hi" >/dev/null 2>&1; ee "invalid permission-mode -> 2" 2 $?

# acceptEdits also flows through (any valid mode, not just dontAsk)
: > "$PROBE"
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-pm7" ANTHROPIC_AUTH_TOKEN="T" \
  FLEET_WORKER_PERMISSION_MODE="acceptEdits" "$WORKER" "hi" >/dev/null 2>&1
eh "acceptEdits flows through" "--permission-mode acceptEdits" "$(cat "$PROBE")"

# dontAsk advisory: warns on stderr when no allowlist is present (worker would auto-deny all)
err="$(PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-pm3" ANTHROPIC_AUTH_TOKEN="T" \
       FLEET_WORKER_PERMISSION_MODE="dontAsk" "$WORKER" "hi" 2>&1 1>/dev/null)"
eh "dontAsk w/o allowlist warns" "auto-deny most tools" "$err"

# ...suppressed when --allowedTools is passed
err="$(PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-pm4" ANTHROPIC_AUTH_TOKEN="T" \
       FLEET_WORKER_PERMISSION_MODE="dontAsk" "$WORKER" --allowedTools "Read" "hi" 2>&1 1>/dev/null)"
case "$err" in *"auto-deny most tools"*) no "advisory wrongly fired with --allowedTools";; *) ok "no advisory when --allowedTools present";; esac

# ...suppressed when the worker config already carries permissions.allow
CFGALLOW="$SB/cfg-pm5"; mkdir -p "$CFGALLOW"
printf '{ "hooks": {}, "permissions": { "allow": ["Read"] } }\n' > "$CFGALLOW/settings.json"
err="$(PATH="$PC" FLEET_WORKER_CONFIG_DIR="$CFGALLOW" ANTHROPIC_AUTH_TOKEN="T" \
       FLEET_WORKER_PERMISSION_MODE="dontAsk" "$WORKER" "hi" 2>&1 1>/dev/null)"
case "$err" in *"auto-deny most tools"*) no "advisory wrongly fired with settings allow";; *) ok "no advisory when settings has permissions.allow";; esac

# default (unset) mode must not emit the dontAsk advisory
err="$(PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-pm6" ANTHROPIC_AUTH_TOKEN="T" \
       "$WORKER" "hi" 2>&1 1>/dev/null)"
case "$err" in *"auto-deny most tools"*) no "default mode wrongly warned";; *) ok "default mode emits no dontAsk advisory";; esac

# Custom endpoint/model override
: > "$PROBE"
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-x" \
  ANTHROPIC_AUTH_TOKEN="T" FLEET_WORKER_BASE_URL="https://example.test/anthropic" \
  FLEET_WORKER_MODEL="GLM-9" FLEET_WORKER_SMALL_MODEL="GLM-9-mini" \
  "$WORKER" "hi" >/dev/null 2>&1
P="$(cat "$PROBE")"
eh "custom base url honoured" "BASE=https://example.test/anthropic" "$P"
eh "custom model honoured"    "SONNET=GLM-9" "$P"

# Key chain: keyring
: > "$PROBE"
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-b" \
  ANTHROPIC_AUTH_TOKEN="" ZHIPU_API_KEY="" GLM_API_KEY="" \
  FLEET_WORKER_KEYRING_SERVICE="svc" FLEET_WORKER_KEYRING_KEY="glm" \
  "$WORKER" "hi" >/dev/null 2>&1; ee "worker via keyring" 0 $?
eh "keyring token reached claude" "TOKEN=KEYRING-TOKEN-glm" "$(cat "$PROBE")"

# Key chain: GLM_API_KEY
: > "$PROBE"
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-c" \
  ANTHROPIC_AUTH_TOKEN="" ZHIPU_API_KEY="" GLM_API_KEY="GAK-1" \
  "$WORKER" "hi" >/dev/null 2>&1
eh "GLM_API_KEY reached claude" "TOKEN=GAK-1" "$(cat "$PROBE")"

# No key resolved -> exit 5
PATH="$PC" FLEET_WORKER_CONFIG_DIR="$SB/cfg-d" \
  ANTHROPIC_AUTH_TOKEN="" ZHIPU_API_KEY="" GLM_API_KEY="" \
  "$WORKER" "hi" >/dev/null 2>&1; ee "no key -> 5" 5 $?

# claude missing -> exit 5 (only when real claude isn't in the base PATH)
if PATH="/usr/bin:/bin" command -v claude >/dev/null 2>&1; then
  echo "  SKIP  claude-missing (claude resolves via base PATH)"
else
  MB2="$SB/bin2"; mkdir -p "$MB2"
  PATH="$MB2:/usr/bin:/bin" FLEET_WORKER_CONFIG_DIR="$SB/cfg-e" ZHIPU_API_KEY="X" \
    ANTHROPIC_AUTH_TOKEN="" GLM_API_KEY="" \
    "$WORKER" "hi" >/dev/null 2>&1; ee "claude missing -> 5" 5 $?
fi

echo "-- fleet-collect.sh --"
"$COLLECT" --help >/dev/null 2>&1; ee "collect --help" 0 $?
out="$(printf '{"is_error":false,"result":"DELIVERABLE"}' | "$COLLECT" -q)"; rc=$?
ee "collect success -> 0" 0 "$rc"
eh "collect prints .result" "DELIVERABLE" "$out"
printf '{"is_error":true,"api_error_status":529,"result":""}' | "$COLLECT" -q >/dev/null 2>&1
ee "collect worker-failed -> 10" 10 $?
printf 'not json' | "$COLLECT" -q >/dev/null 2>&1; ee "collect bad json -> 4" 4 $?
printf '{"x":1}'  | "$COLLECT" -q >/dev/null 2>&1; ee "collect no is_error -> 4" 4 $?
"$COLLECT" "$SB/nope.json" >/dev/null 2>&1;        ee "collect missing file -> 3" 3 $?
"$COLLECT" --bogus >/dev/null 2>&1;                ee "collect bad flag -> 2" 2 $?

echo "-- fleet-doctor.sh --"
"$DOCTOR" --help >/dev/null 2>&1;        ee "doctor --help" 0 $?
"$DOCTOR" --offline -q >/dev/null 2>&1;  ee "doctor --offline consistent -> 0" 0 $?
"$DOCTOR" --bogus >/dev/null 2>&1;       ee "doctor bad flag -> 2" 2 $?
out="$("$DOCTOR" --offline --json -q 2>/dev/null)"
eh "doctor --json schema" "claude-mods.fleet-worker.doctor/v1" "$out"
e="$(TERM_ASCII=1 FORCE_COLOR=1 "$DOCTOR" --offline 2>&1 1>/dev/null)"
if printf '%s' "$e" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
  no "doctor framing pure ASCII under TERM_ASCII=1"
else ok "doctor framing pure ASCII under TERM_ASCII=1"; fi
grep -q '_lib/term.sh' "$DOCTOR" && ok "doctor sources term.sh" || no "doctor missing term.sh"

# Drift tripwire: copy the skill into a temp dir with a SKILL.md that documents
# no model name; the doctor run from there must report drift -> exit 10.
DSB="$SB/skillcopy"; mkdir -p "$DSB/scripts" "$DSB/assets"
cp "$WORKER" "$DSB/scripts/fleet-worker"
cp "$DOCTOR" "$DSB/scripts/fleet-doctor.sh"
printf '# fleet-worker\nThis doc deliberately mentions no model name or endpoint.\n' > "$DSB/SKILL.md"
printf '{ "hooks": {}, "effortLevel": "high" }\n' > "$DSB/assets/worker-settings.json"
bash "$DSB/scripts/fleet-doctor.sh" --offline -q >/dev/null 2>&1
ee "drift (undocumented model) -> 10" 10 $?

# --- assets/route.js: paste-in model-routing helper ---------------------------
ROUTE="$SKILL/assets/route.js"
if [ -f "$ROUTE" ] && command -v node >/dev/null 2>&1; then
  node --check "$ROUTE" && ok "route.js valid JS" || no "route.js syntax error"
  RT="$SB/rt.js"
  { cat "$ROUTE"; cat <<'TEST'

const S=JSON.stringify; let P=0,F=0;
const eq=(n,g,w)=>{ if(S(g)===S(w)){P++} else {F++;console.error("ROUTE FAIL "+n+" got "+S(g)+" want "+S(w))} };
// Deciders (judge/synthesize) omit model: they INHERIT the session's premium brain
// (Fable > Opus); pinning would DOWNGRADE on a Fable session. See native-model-routing.md.
eq("judge inherits model",route("judge"),{effort:"high"});
eq("synthesize inherits model",route("synthesize"),{effort:"high"});
eq("scout",route("scout"),{model:"sonnet",effort:"low"});
eq("unknown->inherit",route("nope"),{});
const low={total:100000,remaining:()=>10000};
// Deciders are EXEMPT from budget degradation — never under-power a judge under pressure.
eq("judge exempt under low budget",route("judge",low),{effort:"high"});
eq("synthesize exempt under low budget",route("synthesize",low),{effort:"high"});
eq("scout degrades one tier",route("scout",low),{model:"haiku",effort:"low"});
const okb={total:100000,remaining:()=>50000};
eq("judge healthy budget",route("judge",okb),{effort:"high"});
eq("fw yes",useFleetWorker({items:30,selfContained:true,mutatesFiles:true}),true);
eq("fw small",useFleetWorker({items:3,selfContained:true,mutatesFiles:true}),false);
eq("fw shared",useFleetWorker({items:30,selfContained:false,mutatesFiles:true}),false);
eq("fw read-only",useFleetWorker({items:30,selfContained:true,mutatesFiles:false}),false);
process.exit(F?1:0);
TEST
  } > "$RT"
  node "$RT" >/dev/null 2>&1; ee "route()/useFleetWorker() logic (12 cases)" 0 $?
else
  ok "route.js helper test (SKIP — node unavailable or asset absent)"
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
