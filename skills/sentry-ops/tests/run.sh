#!/usr/bin/env bash
# Offline self-test for the sentry-ops skill: structure, script contracts, the
# staleness verifier and the scrubber. The sink runs on loopback in the reserved
# throwaway range and exits by itself.
#
# Usage:   tests/run.sh
# Input:   none (no network beyond loopback; node is optional).
# Output:  progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped when no python), 1 any failure.
#
# Examples:
#   bash skills/sentry-ops/tests/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }

# `python3` can be a Store stub on Windows, so check that it actually runs.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then
    PY="$cand"; break
  fi
done
if [ -z "$PY" ]; then
  echo "SKIP: no working python interpreter on this platform" >&2
  exit 0
fi

ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }

tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/sentry-ops-test.$$")"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# 1. Layout and frontmatter.
# CONTRACT: asserts the frontmatter keeps `name: sentry-ops`, `license: MIT` and
# `metadata.author: claude-mods`. A trim lane editing them must update this too.
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/" || bad "missing dir $d/"
done
skill="$here/SKILL.md"
grep -q '^name: sentry-ops$' "$skill" && ok "name matches directory" || bad "name != sentry-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"

# 2. Every reference on disk is cited, every cited resource exists.
for ref in "$here"/references/*.md; do
  base="references/$(basename "$ref")"
  grep -qF "$base" "$skill" && ok "cited: $base" || bad "uncited reference: $base"
done
for res in assets/scrub-event.mjs assets/sentry-facts.json scripts/envelope-sink.py scripts/check-sentry-facts.py; do
  [ -f "$here/$res" ] && ok "present: $res" || bad "missing: $res"
done

# 3. Public repo: no real DSN or token can sit in the skill. Patterns are Sentry's
# own published formats. A loopback DSN with the placeholder key is the only kind allowed.
if grep -rEq 'https?://[a-f0-9]{32}@|sntry[us]_[A-Za-z0-9]{8}' "$here/SKILL.md" "$here/references" "$here/assets" "$here/scripts"; then
  bad "something shaped like a real DSN or token is in the skill"
else
  ok "no real DSN or token shapes"
fi

# 4. envelope-sink.py: contract.
sink="$here/scripts/envelope-sink.py"
"$PY" -m py_compile "$sink" && ok "sink: py_compile" || bad "sink: py_compile"
"$PY" "$sink" --help 2>/dev/null | grep -q "Examples:" && ok "sink: --help has Examples" || bad "sink: --help Examples"
ec 2 "sink: no command -> 2" "$PY" "$sink"
ec 2 "sink: bad flag -> 2" "$PY" "$sink" listen --bogus
ec 3 "sink: missing path -> 3" "$PY" "$sink" inspect "$tmp/no-such"
mkdir -p "$tmp/empty"
ec 3 "sink: empty dir -> 3" "$PY" "$sink" inspect "$tmp/empty"
printf 'not an envelope' > "$tmp/bad.envelope"
ec 4 "sink: garbage -> 4" "$PY" "$sink" inspect "$tmp/bad.envelope"

# 5. inspect: a recorded-shape fixture, with exact findings.
# CONTRACT: tests/fixtures/leaky.envelope and clean.envelope move with these checks.
leaky="$here/tests/fixtures/leaky.envelope"
clean="$here/tests/fixtures/clean.envelope"
ec 0  "inspect: clean, strict -> 0" "$PY" "$sink" inspect "$clean" --strict --forbid person@example.com
ec 10 "inspect: forbidden string -> 10" "$PY" "$sink" inspect "$leaky" --forbid person@example.com
ec 10 "inspect: forbid match is case-insensitive -> 10" "$PY" "$sink" inspect "$leaky" --forbid PERSON@EXAMPLE.COM
ec 10 "inspect: exposed field under --strict -> 10" "$PY" "$sink" inspect "$leaky" --strict
ec 0  "inspect: exposed field without --strict -> 0" "$PY" "$sink" inspect "$leaky"
row="$("$PY" "$sink" inspect "$leaky" --json 2>/dev/null)"
printf '%s' "$row" | "$PY" -c '
import json,sys
d=json.load(sys.stdin); r=d["data"][0]
assert d["meta"]["schema"]=="claude-mods.sentry-ops.envelope/v1"
assert r["items"]==["event"]
assert r["exposed_fields"]==["breadcrumbs","request.cookies","request.data","request.headers","request.query_string","request.url?query","user"], r["exposed_fields"]
' && ok "inspect: names each exposed field" || bad "inspect: exposed field list wrong"

# A Replay-style binary payload holds newlines: `length` must be honoured, or the
# next item header gets parsed as garbage and the file reads as corrupt.
"$PY" - "$tmp/binary.envelope" <<'PY'
import json,sys
payload=b'\x00\n\xff{"not":"json"\n'
with open(sys.argv[1],"wb") as f:
    f.write(json.dumps({"event_id":"e1"}).encode()+b"\n")
    f.write(json.dumps({"type":"replay_recording","length":len(payload)}).encode()+b"\n"+payload+b"\n")
    f.write(json.dumps({"type":"event"}).encode()+b"\n"+json.dumps({"event_id":"e1"}).encode()+b"\n")
PY
"$PY" "$sink" inspect "$tmp/binary.envelope" 2>/dev/null | grep -q "replay_recording,event" \
  && ok "inspect: binary item with length parses" || bad "inspect: binary item misparsed"

# gzip-encoded bodies are decoded, so a leak can't hide behind compression.
"$PY" - "$leaky" "$tmp/gz.envelope" <<'PY'
import gzip,sys
open(sys.argv[2],"wb").write(gzip.compress(open(sys.argv[1],"rb").read()))
PY
ec 10 "inspect: leak inside gzip still found -> 10" "$PY" "$sink" inspect "$tmp/gz.envelope" --forbid person@example.com

# 6. listen: end to end on loopback, in the throwaway range. A busy port is skipped,
# since another process may hold one.
post() { # port file
  "$PY" - "$1" "$2" <<'PY'
import sys,urllib.request
port,path=sys.argv[1],sys.argv[2]
req=urllib.request.Request(f"http://127.0.0.1:{port}/api/1/envelope/?sentry_key=publickey",data=open(path,"rb").read(),method="POST")
urllib.request.urlopen(req,timeout=5)
PY
}
# Returns 0 only once THIS listener is bound. Guard: posting without this check sends
# the fixture to whatever already owns the port, such as someone's dev server, and a
# 2xx from that would look like a delivery.
wait_bound() { # pid errfile
  local i
  for i in $(seq 1 200); do
    kill -0 "$1" 2>/dev/null || return 1
    grep -q '^listening' "$2" 2>/dev/null && return 0
    "$PY" -c 'import time; time.sleep(0.05)'
  done
  return 1
}
ran_listen=""
for port in 8197 8198 8199 8196; do
  out="$tmp/listen-$port"
  "$PY" "$sink" listen --port "$port" --out "$out" --count 1 --timeout 20 >"$tmp/listen.out" 2>"$tmp/listen.err" &
  pid=$!
  if ! wait_bound "$pid" "$tmp/listen.err"; then
    wait "$pid"
    continue
  fi
  post "$port" "$leaky"
  wait "$pid"; rc=$?
  ran_listen=1
  [ "$rc" = "0" ] && ok "listen: --count 1 exits 0" || bad "listen: exit $rc"
  grep -q "001.envelope" "$tmp/listen.out" && ok "listen: stdout names the saved file" || bad "listen: stdout"
  cmp -s "$out/001.envelope" "$leaky" && ok "listen: saved bytes equal the POST" || bad "listen: bytes differ"

  "$PY" "$sink" listen --port "$port" --out "$tmp/none" --timeout 15 --expect-none >/dev/null 2>"$tmp/listen.err" &
  pid=$!
  wait_bound "$pid" "$tmp/listen.err" && post "$port" "$leaky"
  # A request arriving under --expect-none must be a finding, not a quiet success.
  wait "$pid"; rc=$?
  [ "$rc" = "10" ] && ok "listen: --expect-none with traffic -> 10" || bad "listen: --expect-none exit $rc"
  break
done
[ -n "$ran_listen" ] || bad "listen: no free port in 8196-8199"

# It stops by itself and reports zero: an orphan would hold the port for good.
for port in 8195 8194; do
  "$PY" "$sink" listen --port "$port" --out "$tmp/quiet" --timeout 1 --expect-none >/dev/null 2>&1; rc=$?
  [ "$rc" = "7" ] && continue
  [ "$rc" = "0" ] && ok "listen: self-stops, no traffic -> 0" || bad "listen: quiet exit $rc"
  break
done

# A port another process is already listening on must be refused with exit 7. On Windows,
# two sockets that both set SO_REUSEADDR can listen on the same address and port, so the
# sink used to print `listening` while the incumbent got the traffic. The holder sets
# SO_REUSEADDR as Python's http.server does, because only such a holder let the old sink
# in: one without it (a Node dev server, say) already refused it. Port 0 lets the OS pick
# a free port, so this check can't collide with whatever holds the throwaway range.
ec 7 "listen: port held by another process -> 7, no co-bind" "$PY" - "$sink" "$tmp/held" <<'PY'
import socket,subprocess,sys
holder=socket.socket()
holder.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
holder.bind(("127.0.0.1",0))
holder.listen()
port=str(holder.getsockname()[1])
sys.exit(subprocess.run([sys.executable,sys.argv[1],"listen","--port",port,"--out",sys.argv[2],"--timeout","1"]).returncode)
PY

# The bind address is loopback, in code: a flag can't widen it.
grep -q '^LOOPBACK = "127.0.0.1"' "$sink" && ok "listen: binds loopback" || bad "listen: LOOPBACK changed"
"$PY" "$sink" listen --help 2>/dev/null | grep -qE -- '--(host|bind)' && bad "listen: grew a bind flag" || ok "listen: no bind flag"

# 7. check-sentry-facts.py: verifier contract (SKILL-RESOURCE-PROTOCOL section 7).
ver="$here/scripts/check-sentry-facts.py"
"$PY" -m py_compile "$ver" && ok "verifier: py_compile" || bad "verifier: py_compile"
grep -qE '^Examples:$' "$ver" && ok "verifier: Examples block" || bad "verifier: no Examples block"
ec 0 "verifier: --help" "$PY" "$ver" --help
ec 0 "verifier: --offline consistent" "$PY" "$ver" --offline
ec 2 "verifier: bad flag -> 2" "$PY" "$ver" --bogus
ec 2 "verifier: --offline --live -> 2" "$PY" "$ver" --offline --live
ec 3 "verifier: missing catalog -> 3" "$PY" "$ver" --offline --catalog "$tmp/no.json"
printf 'not json' > "$tmp/bad.json"
ec 4 "verifier: malformed catalog -> 4" "$PY" "$ver" --offline --catalog "$tmp/bad.json"
"$PY" "$ver" --offline --json -q 2>/dev/null \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.sentry-ops.facts/v1"' \
  && ok "verifier: --json envelope" || bad "verifier: --json envelope"

# Drift must trip: a new SDK category missing from the baseline is the case this
# verifier exists for, plus a major bump and a package the prose stopped naming.
sed 's/"mcp", //' "$here/assets/sentry-facts.json" > "$tmp/keys.json"
ec 10 "verifier: baseline/catalog key mismatch -> 10" "$PY" "$ver" --offline --catalog "$tmp/keys.json"
sed 's/"documented_sdk_major": 11/"documented_sdk_major": 99/' "$here/assets/sentry-facts.json" > "$tmp/major.json"
ec 10 "verifier: currency note mismatch -> 10" "$PY" "$ver" --offline --catalog "$tmp/major.json"
sed 's#"prose_token": "@sentry/wizard"#"prose_token": "@sentry/nope"#' "$here/assets/sentry-facts.json" > "$tmp/tok.json"
ec 10 "verifier: unnamed package -> 10" "$PY" "$ver" --offline --catalog "$tmp/tok.json"
# And an asset that configures the removed option.
mkdir -p "$tmp/skill/assets" "$tmp/skill/references"
cp "$here/SKILL.md" "$tmp/skill/"; cp "$here"/references/*.md "$tmp/skill/references/"
sed 's/^export const STRICT_DATA_COLLECTION/const x = {\n  sendDefaultPii: false,\n};\nexport const STRICT_DATA_COLLECTION/' "$here/assets/scrub-event.mjs" > "$tmp/skill/assets/scrub-event.mjs"
ec 10 "verifier: asset sets sendDefaultPii -> 10" "$PY" "$ver" --offline --skill "$tmp/skill"

# 8. The scrubber's own tests, when node is available.
if command -v node >/dev/null 2>&1; then
  if node --test "$here/tests/scrub-event.test.mjs" >"$tmp/node.out" 2>&1; then
    ok "scrub-event: node --test passes"
  else
    bad "scrub-event: node --test failed"; sed 's/^/    /' "$tmp/node.out" >&2
  fi
else
  note "skip" "scrub-event: node not installed"
fi

echo "sentry-ops tests: $pass passed, $fail failed" >&2
[ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
