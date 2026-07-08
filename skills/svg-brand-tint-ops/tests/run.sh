#!/usr/bin/env bash
# Offline self-test for svg-brand-tint-ops: the server contract + that it serves
# the studio (tri-tone filter + trace engine) and the sample.
#
# Self-contained, no network. Resolves paths relative to itself so it runs both
# in the repo and once installed to ~/.claude/skills/svg-brand-tint-ops/.
# Skips gracefully (exit 0) when node or curl is unavailable.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or skipped on unsupported host), 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SERVER="$SKILL/scripts/server.mjs"
INDEX="$SKILL/assets/index.html"
SAMPLE="$SKILL/assets/sample.svg"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit(){ [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
has(){ case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== svg-brand-tint-ops self-test ==="

# ── static content sanity (no runtime needed) ──────────────────────────────
[[ -f "$INDEX" ]] && ok "index.html present" || no "index.html missing"
idx="$(cat "$INDEX" 2>/dev/null)"
has "index carries the tri-tone filter" "feComponentTransfer" "$idx"
has "index references the tone-map filter" "url(#tonemap)" "$idx"
has "index ships the iso-contour tracer" "isoContours" "$idx"
has "index has the Image Trace panel" "Image Trace" "$idx"
[[ -f "$SAMPLE" ]] && ok "sample.svg present" || no "sample.svg missing"

# --- section-map drift gate (assets/index.html: guard comment ↔ // === markers) ---
# index.html is a deliberately single-file studio; its top <script> guard
# comment lists the `// === NAME ===` banner sections so the file is
# navigable. This gate keeps the guard list and the body markers in sync
# bidirectionally and FAILS LOUDLY if either side parses to zero names — the
# classic rot mode where a guard-comment/marker format change silently yields
# an empty list and the check would otherwise vacuously pass.
map_names="$(awk '
  /Sections \(grep/ { cap=1; sub(/.*:[[:space:]]*/,"",$0); blob=blob $0 " "; if ($0 ~ /\*\//) cap=0; next }
  cap { if ($0 ~ /\*\//) { cap=0; next } blob=blob $0 " " }
  END { gsub(/·/,"\n",blob); n=split(blob,a,"\n");
        for (i=1;i<=n;i++){ s=a[i]; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); if (s!="") print s } }
' "$INDEX")"
mark_names="$(grep -E '^// === .* ===$' "$INDEX" | sed -E 's|^// === (.*) ===$|\1|')"
dc="$(printf '%s\n' "$map_names"  | grep -c . || true)"
mc="$(printf '%s\n' "$mark_names" | grep -c . || true)"
# empty-parse guard: either side unparseable is a hard fail (never a silent pass)
if [[ "$dc" -gt 0 && "$mc" -gt 0 ]]; then
  ok "section-map parses (guard=$dc names, body=$mc markers)"
else
  no "section-map EMPTY PARSE (guard=$dc, body=$mc) — guard comment or marker format changed"
fi
# forward: every guard-listed section has a matching // === marker
fwd_miss=""
while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  grep -Fxq -- "$n" <<< "$mark_names" || fwd_miss="$fwd_miss $n"
done <<< "$map_names"
if [[ -z "$fwd_miss" ]]; then
  ok "forward: every guard-listed section has a // === marker"
else
  no "forward: guard sections with no marker:${fwd_miss}"
fi
# reverse: every // === marker is present in the guard list
rev_miss=""
while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  grep -Fxq -- "$n" <<< "$map_names" || rev_miss="$rev_miss $n"
done <<< "$mark_names"
if [[ -z "$rev_miss" ]]; then
  ok "reverse: every // === marker is listed in the guard comment"
else
  no "reverse: body markers missing from guard:${rev_miss}"
fi

# ── runtime: needs node + curl ─────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then echo "  SKIP  node not found — runtime checks skipped"; echo "=== $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]] || exit 1; exit 0; fi
if ! command -v curl >/dev/null 2>&1; then echo "  SKIP  curl not found — runtime checks skipped"; echo "=== $PASS passed, $FAIL failed ==="; [[ "$FAIL" -eq 0 ]] || exit 1; exit 0; fi

# server contract (offline, fast)
node "$SERVER" --help >/dev/null 2>&1;  expect_exit "server --help" 0 $?
node "$SERVER" --bogus >/dev/null 2>&1; expect_exit "server bad flag -> 2" 2 $?
EMPTY="$(mktemp -d)"; node "$SERVER" --root "$EMPTY" >/dev/null 2>&1; expect_exit "server no-web-root -> 5" 5 $?; rmdir "$EMPTY" 2>/dev/null

# ── engine (trace-core.mjs) + headless CLI (trace.mjs) ─────────────────────
CORE="$SKILL/assets/trace-core.mjs"; CLI="$SKILL/scripts/trace.mjs"
node --check "$CORE" >/dev/null 2>&1; expect_exit "trace-core.mjs compiles" 0 $?
node --check "$CLI"  >/dev/null 2>&1; expect_exit "trace.mjs compiles" 0 $?
# engine smoke — trace a synthetic 8x8 two-colour image, expect a valid SVG
sm="$(cd "$SKILL" && node --input-type=module -e 'import("./assets/trace-core.mjs").then(m=>{const w=8,h=8,d=new Uint8ClampedArray(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=(y*w+x)*4,v=x<4?0:255;d[i]=v;d[i+1]=v;d[i+2]=v;d[i+3]=255;}const s=m.traceImage({data:d,width:w,height:h},{mode:"color",colors:2});process.stdout.write((s.includes("<path")&&s.includes("</svg>"))?"OK":"BAD");}).catch(()=>process.stdout.write("ERR"))' 2>&1)"
case "$sm" in *OK*) ok "trace-core traces a synthetic image";; *) no "trace-core smoke ($sm)";; esac
# CLI contract
node "$CLI" --help >/dev/null 2>&1;            expect_exit "trace.mjs --help" 0 $?
node "$CLI" x.png --bogus >/dev/null 2>&1;     expect_exit "trace.mjs bad flag -> 2" 2 $?
node "$CLI" /no/such-file.png >/dev/null 2>&1; expect_exit "trace.mjs missing input -> 3" 3 $?
node "$CLI" "$INDEX" "$(mktemp -u).svg" >/dev/null 2>&1; rc=$?
case "$rc" in 5) ok "trace.mjs missing-dep -> 5 (needs sharp; browser tool doesn't)";; 1) ok "trace.mjs decoder present (non-image input -> 1)";; *) no "trace.mjs decoder path (got $rc)";; esac

# boot the server on an ephemeral port and probe it
LOG="$(mktemp)"; PORT_FILE="$(mktemp)"
node "$SERVER" --port 0 >/dev/null 2>"$LOG" &
SRV=$!
trap 'kill "$SRV" >/dev/null 2>&1' EXIT
PORT=""
for _ in $(seq 1 40); do
  PORT="$(sed -n 's#.*http://localhost:\([0-9]\{1,\}\)/.*#\1#p' "$LOG" | head -1)"
  [[ -n "$PORT" ]] && break
  sleep 0.1
done

if [[ -z "$PORT" ]]; then
  no "server printed a listening URL"; cat "$LOG" >&2
else
  ok "server bound ephemeral port $PORT"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/" 2>/dev/null)"
  expect_exit "GET / -> 200" 200 "$code"
  body="$(curl -s "http://localhost:$PORT/" 2>/dev/null)"
  has "served index has tri-tone filter" "feComponentTransfer" "$body"
  has "served index has the tracer" "isoContours" "$body"
  scode="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/sample.svg" 2>/dev/null)"
  expect_exit "GET /sample.svg -> 200" 200 "$scode"
  tcode="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/../server.mjs" 2>/dev/null)"
  case "$tcode" in 403|404) ok "path traversal blocked (../server.mjs -> $tcode)";; *) no "path traversal not blocked (got $tcode)";; esac
fi
kill "$SRV" >/dev/null 2>&1; trap - EXIT
rm -f "$LOG" "$PORT_FILE" 2>/dev/null

echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
