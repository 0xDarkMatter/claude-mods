#!/usr/bin/env bash
# Behavioural suite for ca-trust-ops: both checkers, every incident pack and its fixtures.
#
# Offline: no test reaches the internet. Stand-in clients on PATH answer for curl, git,
# python3, node and `openssl s_client`; the real-client cases talk to `openssl s_server`
# on localhost ports 8191-8194 (the machine's throwaway range) through the checker's
# localhost-only CA_TRUST_LOCAL_PORTS hook. Every case runs against a throwaway copy of the
# skill, so the checkers are also proven to run from a copied folder.
#
# Each named test is a predicate (t_*) that returns 0 when the behaviour is right. The
# mutants group re-runs chosen predicates against copies of the checkers with one guard
# deliberately broken, and fails when no predicate notices: proof that each test can fail.
#
# Groups (each skips cleanly where its tools or platform are missing):
#   pack        each pack's keys equal its fixtures' keys; keys live only in packs
#   bundles     bash: bundle verdicts, exit codes, the RESULT line, malformed packs
#   standins    bash network logic against stand-in clients (Linux: the checker refuses Git Bash)
#   real        real curl, git, python3 (and node) against local test servers (Linux)
#   powershell  bundle mode, packs, environment restore (pwsh and powershell.exe where present)
#   mutants     deliberate breakages; each must be caught by a named test
#
# Usage:   bash tests/run.sh [--group NAME]... [--no-mutants]
# Exit:    0 all pass, 1 one or more failures, 2 usage
# Sections: TARGETS, PACK, BUNDLES, STANDINS, REAL, POWERSHELL, MUTANTS, MAIN.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SB="$(mktemp -d)"
SERVERS=""
cleanup() {
  local pid
  for pid in $SERVERS; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
  rm -rf "$SB"
}
trap cleanup EXIT

GROUPS_WANTED=""
MUTANTS=1
while [ $# -gt 0 ]; do
  case $1 in
    --group) [ $# -ge 2 ] || { echo "usage: run.sh [--group NAME]... [--no-mutants]" >&2; exit 2; }; GROUPS_WANTED="$GROUPS_WANTED $2"; shift ;;
    --no-mutants) MUTANTS=0 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: run.sh [--group NAME]... [--no-mutants]" >&2; exit 2 ;;
  esac
  shift
done
wanted() { [ -z "$GROUPS_WANTED" ] || case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PASS=0; FAIL=0; SKIP=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }

# check PREDICATE: runs a named test against the current target and reports it.
WHY=""
check() {
  WHY=""
  if "$1"; then
    ok "${1#t_}"
  else
    no "${1#t_}${WHY:+ - $WHY}"
    [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /'
  fi
}

has_line() { printf '%s\n' "$OUT" | grep -Eq "$1" || { WHY="${WHY:-no line matches /$1/}"; return 1; }; }
lacks_line() { ! printf '%s\n' "$OUT" | grep -Eq "$1" || { WHY="${WHY:-a line matches /$1/}"; return 1; }; }
rc_is() { [ "$RC" = "$1" ] || { WHY="${WHY:-want exit $1, got $RC}"; return 1; }; }

# Wire format of the shareable line: tool, version, incident, platform, date, verdict, counts.
readonly RESULT_RE='^RESULT  ca-trust-ops 1 [a-z0-9-]+ [a-z0-9_-]+ [0-9]{4}-[0-9]{2}-[0-9]{2}: (PASS|FAIL|UNKNOWN) \([0-9]+ pass, [0-9]+ fail, [0-9]+ unknown\)$'

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$2"
  elif [ "${1%.exe}" != "$1" ] && command -v wslpath >/dev/null 2>&1; then wslpath -w "$2"
  else printf '%s' "$2"; fi
}

# The SPKI SHA-256 of every certificate in a PEM file, one per line, computed independently
# of the checkers (openssl over each split-out certificate) and memoised per file.
spki_of_file() {
  local dir="$SB/split" memo c
  memo="$SB/spki.$(memo_key "$1")"
  [ -f "$memo" ] && { cat "$memo"; return 0; }
  rm -rf "$dir"; mkdir -p "$dir"
  awk -v d="$dir" '/-----BEGIN CERTIFICATE-----/{n++; f=d "/" n ".pem"} f{print > f} /-----END CERTIFICATE-----/{close(f); f=""}' "$1"
  for c in "$dir"/*.pem; do
    openssl x509 -in "$c" -noout -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 | awk '{print toupper($NF)}'
  done >"$memo"
  cat "$memo"
}

first_cert() { awk '/-----BEGIN CERTIFICATE-----/{on=1} on{print} /-----END CERTIFICATE-----/{exit}' "$1"; }
pack_keys() { awk -F'|' '$1 == "key" { print $2 }' "$1" | tr -d '\r' | sort -u; }

# === TARGETS ===
# A target is a copy of the skill plus synthetic packs. Tests read $SH and $PS; mutants
# swap in a broken copy. Results are memoised per target, so a scenario several tests
# share runs once.

EM=emudhra-2026-10
EM_CONTROL=emudhra.we-have-a-problem.com
EM_A=dv-g3b-emudhra.we-have-a-problem.com
EM_B=dv-g3b-aaa-emudhra.we-have-a-problem.com
T3_CONTROL=control.ca-trust-test.invalid
T3_ONE=one.ca-trust-test.invalid
T3_TWO=two.ca-trust-test.invalid
T3_THREE=three.ca-trust-test.invalid
FIX="$SKILL/tests/fixtures/$EM"
BAD_PACKS="bad-host bad-key bad-spki bad-record bad-nopath bad-id bad-extra bad-command bad-port"
EM_DV_KEY=EBED6475C2C2D80FCB199F3FE8DD6E6B3CE60B77EB15D4E42C3DEC0C6F5B5105
# A real key record (hash, name, SPKI), so each malformed pack below is refused for its own
# defect only, never for a missing SPKI.
EM_DV_LINE=$(grep "^key|$EM_DV_KEY|" "$SKILL/assets/incidents/$EM.conf" | tr -d '\r')
EM_DV_SPKI=${EM_DV_LINE##*|}

write_packs() {
  local d=$1/assets/incidents
  # Three trust paths and no `fixed` records: proves the engine is not hard-wired to two.
  printf '%s\n' "id|test-three-paths" "name|Test" "title|Synthetic three-path incident" "as_of|2026-01-01" \
    "$EM_DV_LINE" "control|$T3_CONTROL" "path|one|$T3_ONE" "path|two|$T3_TWO" "path|three|$T3_THREE" >"$d/test-three-paths.conf"
  bad() { local name=$1; shift; printf '%s\n' "id|$name" "name|Bad" "title|Malformed pack" "as_of|2026-01-01" "$@" >"$d/$name.conf"; }
  bad bad-host "$EM_DV_LINE" "control|evil.example/steal" "path|p|p.example.invalid"
  bad bad-key "key|${EM_DV_KEY%?}|x|$EM_DV_SPKI" "control|c.example.invalid" "path|p|p.example.invalid"
  bad bad-spki "key|$EM_DV_KEY|x|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "control|c.example.invalid" "path|p|p.example.invalid"
  bad bad-record "$EM_DV_LINE" "control|c.example.invalid" "path|p|p.example.invalid" "exec|sh -c id"
  bad bad-nopath "$EM_DV_LINE" "control|c.example.invalid"
  bad bad-extra "$EM_DV_LINE|y" "control|c.example.invalid" "path|p|p.example.invalid"
  bad bad-command "$EM_DV_LINE" "control|c.example.invalid" "path|p|p.example.invalid" "version|v|rm -rf|Tool|1.0.0|fix"
  bad bad-port "$EM_DV_LINE" "control|c.example.invalid" "path|p|p.example.invalid:8443"
  printf '%s\n' "id|not-bad-id" "name|Bad" "title|Malformed pack" "as_of|2026-01-01" "$EM_DV_LINE" \
    "control|c.example.invalid" "path|p|p.example.invalid" >"$d/bad-id.conf"
}

# Only what the checkers read at run time: copying the fixtures per mutant cost seconds.
make_target() {
  local dir="$SB/targets/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$SKILL/scripts" "$SKILL/assets" "$dir/"
  write_packs "$dir"
  printf '%s' "$dir"
}

TARGET=""
use_target() {
  TARGET=$1
  SH="$TARGET/scripts/check-ca-trust.sh"
  PS="$TARGET/scripts/check-ca-trust.ps1"
  CACHE="$SB/cache/${TARGET##*/}"
  mkdir -p "$CACHE"
}

memo_key() { printf '%s\n' "$@" | cksum | awk '{print $1 "-" $2}'; }
memo_load() { [ -f "$CACHE/$1.rc" ] || return 1; OUT=$(cat "$CACHE/$1.out"); RC=$(cat "$CACHE/$1.rc"); LOGF="$CACHE/$1.log"; }
memo_save() { printf '%s\n' "$OUT" >"$CACHE/$1.out"; printf '%s' "$RC" >"$CACHE/$1.rc"; }

# bash_run [VAR=value]... ARGS...: the bash checker with a clean environment, no network.
bash_run() {
  local key item envs="" ; key=$(memo_key bash "$@")
  memo_load "$key" && return 0
  local e=() a=()
  for item in "$@"; do case $item in [A-Z_]*=*) e+=("$item") ;; *) a+=("$item") ;; esac; done
  mkdir -p "$SB/bhome" "$SB/bcwd"
  OUT=$(cd "$SB/bcwd" && env -i HOME="$SB/bhome" PATH="$PATH" ${e[@]+"${e[@]}"} bash "$SH" ${a[@]+"${a[@]}"} 2>&1)
  RC=$?
  memo_save "$key"
}

# === PACK ===

t_every_pack_has_fixtures_and_a_reference() {
  local f id ref
  for f in "$SKILL"/assets/incidents/*.conf; do
    id=$(basename "$f" .conf)
    ref=$(awk -F'|' '$1 == "reference" { print $2 }' "$f" | tr -d '\r')
    [ -n "$ref" ] && [ -f "$SKILL/$ref" ] || { WHY="$id: no reference file ($ref)"; return 1; }
    ls "$SKILL/tests/fixtures/$id"/listed-*.crt >/dev/null 2>&1 || { WHY="$id: no tests/fixtures/$id/listed-*.crt"; return 1; }
    ls "$SKILL/tests/fixtures/$id"/unlisted*.crt >/dev/null 2>&1 || { WHY="$id: no tests/fixtures/$id/unlisted*.crt"; return 1; }
  done
}

# The pack's key list must equal the keys of the real certificates in its fixtures, so a
# typo in a hash (or a certificate hash where a key hash belongs) cannot ship.
t_pack_keys_equal_their_fixture_keys() {
  local f id want got
  for f in "$SKILL"/assets/incidents/*.conf; do
    id=$(basename "$f" .conf)
    want=$(for c in "$SKILL/tests/fixtures/$id"/listed-*.crt; do spki_of_file "$c"; done | sort -u)
    got=$(pack_keys "$f")
    [ -n "$want" ] && [ "$want" = "$got" ] || { WHY="$id: pack keys differ from the listed fixtures' keys"; return 1; }
  done
}

t_unaffected_certificates_are_not_listed() {
  local f id overlap
  for f in "$SKILL"/assets/incidents/*.conf; do
    id=$(basename "$f" .conf)
    overlap=$(comm -12 <(for c in "$SKILL/tests/fixtures/$id"/unlisted*.crt; do spki_of_file "$c"; done | sort -u) <(pack_keys "$f"))
    [ -z "$overlap" ] || { WHY="$id lists an unaffected key: $overlap"; return 1; }
  done
}

# The SPKI the bash scanner builds its needles from must be the key the hash names.
t_pack_spki_hashes_match_their_keys() {
  local f hash spki got
  for f in "$SKILL"/assets/incidents/*.conf; do
    # procsub ok: awk over a file the glob just matched cannot stop early
    while IFS='|' read -r hash spki; do
      got=$(printf '%s' "$spki" | openssl base64 -d -A | openssl dgst -sha256 | awk '{print toupper($NF)}')
      [ "$got" = "$hash" ] || { WHY="$(basename "$f"): the SPKI of $hash hashes to $got"; return 1; }
    done < <(awk -F'|' '$1 == "key" { print $2 "|" $4 }' "$f" | tr -d '\r')
  done
}

# scripts/pack-keys.sh is how a pack's key lines are made; it must reproduce the shipped ones.
t_pack_keys_tool_reproduces_each_pack() {
  local f id want got
  for f in "$SKILL"/assets/incidents/*.conf; do
    id=$(basename "$f" .conf)
    want=$(grep '^key|' "$f" | tr -d '\r' | LC_ALL=C sort)
    got=$(bash "$TARGET/scripts/pack-keys.sh" "$SKILL/tests/fixtures/$id"/listed-*.crt | LC_ALL=C sort)
    [ -n "$got" ] && [ "$want" = "$got" ] || { WHY="$id: pack-keys.sh output differs from the pack's key lines"; return 1; }
  done
}

t_pack_keys_tool_follows_the_script_contract() {
  local rc
  OUT=$(bash "$TARGET/scripts/pack-keys.sh" --help 2>&1); rc=$?
  [ "$rc" = 0 ] && has_line '^EXAMPLES' || { WHY="--help: exit $rc or no EXAMPLES"; return 1; }
  bash "$TARGET/scripts/pack-keys.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || { WHY="no arguments: want exit 2, got $rc"; return 1; }
  bash "$TARGET/scripts/pack-keys.sh" "$SB/no-such.crt" >/dev/null 2>&1; rc=$?
  [ "$rc" = 3 ] || { WHY="missing file: want exit 3, got $rc"; return 1; }
}

# One source of truth: a key written into a script would drift from the pack unnoticed.
t_keys_live_only_in_packs() {
  ! grep -lE '[0-9A-F]{64}' "$SKILL"/scripts/* >/dev/null 2>&1 || { WHY="a script carries a 64-hex key: $(grep -lE '[0-9A-F]{64}' "$SKILL"/scripts/*)"; return 1; }
}

# PowerShell 5.1 reads files in the ANSI code page and bash 3.2 reads lines: packs stay
# 7-bit ASCII with LF endings.
t_packs_are_ascii_with_lf_endings() {
  local f
  for f in "$SKILL"/assets/incidents/*.conf; do
    ! LC_ALL=C grep -q "$(printf '\r')" "$f" || { WHY="$(basename "$f") has CR line endings"; return 1; }
    ! LC_ALL=C grep -q '[^ -~]' "$f" || { WHY="$(basename "$f") is not 7-bit ASCII"; return 1; }
  done
}

# === BUNDLES ===

t_listed_root_in_bundle_fails() {
  bash_run --incident "$EM" --bundle "$FIX/listed-roots.crt"
  rc_is 10 && has_line '^FAIL +bundle .*emSign ECC Root CA - G3' && has_line '^FAIL +bundle .*AAA Certificate Services' \
    && has_line '^FAIL +bundle .*emSign Root TLS CA - G3' && has_line '^FAIL +bundle .*emSign Root CS CA - G3' \
    && has_line '^FAIL .* - fix: ' && has_line '^RESULT .*: FAIL '
}

t_cross_signed_intermediate_caught_by_its_key() {
  bash_run --incident "$EM" --bundle "$FIX/listed-cross-signs.crt"
  rc_is 10 && has_line '^FAIL +bundle .*EM DV TLS CA - G3B'
}

t_sibling_roots_stay_trusted() {
  bash_run --incident "$EM" --bundle "$FIX/unlisted.crt"
  rc_is 0 && has_line '^PASS +bundle .*none of the 12 listed keys in 4 certificates' && has_line '^RESULT .*: PASS '
}

t_missing_bundle_is_unknown_not_pass() {
  bash_run --incident "$EM" --bundle "$SB/no-such-bundle.pem"
  rc_is 11 && has_line '^UNKNOWN +bundle '
}

t_empty_bundle_is_unknown_not_pass() {
  : >"$SB/empty.pem"
  bash_run --incident "$EM" --bundle "$SB/empty.pem"
  rc_is 11 && has_line '^UNKNOWN +bundle .*no certificates could be read'
}

# A garbled certificate among good ones: hashing it fails, and that must not read as clean.
t_unreadable_certificate_is_unknown_not_pass() {
  { cat "$FIX/unlisted.crt"; printf '%s\n' '-----BEGIN CERTIFICATE-----' 'bm90IGEgY2VydGlmaWNhdGU=' '-----END CERTIFICATE-----'; } >"$SB/garbled.pem"
  bash_run --incident "$EM" --bundle "$SB/garbled.pem"
  rc_is 11 && has_line '^UNKNOWN +bundle .*1 of 5 certificates could not be read'
}

# Every certificate in every listed fixture is found, whatever byte offset its key sits at
# (the scanner's needles cover the three base64 alignments): the FAIL line names exactly as
# many listed keys as the file holds.
t_every_listed_fixture_certificate_is_caught() {
  local f c id want got
  for f in "$SKILL"/assets/incidents/*.conf; do
    id=$(basename "$f" .conf)
    for c in "$SKILL/tests/fixtures/$id"/listed-*.crt; do
      want=$(spki_of_file "$c" | sort -u | grep -c .)
      bash_run --incident "$id" --bundle "$c"
      got=$(printf '%s\n' "$OUT" | grep -E '^FAIL +bundle ' | sed -e 's/.* trusts //' -e 's/ - fix: .*//' | tr ';' '\n' | grep -c .)
      [ "$RC" = 10 ] && [ "$got" = "$want" ] || { WHY="$id/$(basename "$c"): $got of $want listed keys found (exit $RC)"; return 1; }
    done
  done
}

# A certificate whose base64 still holds a listed key but which openssl cannot parse (its
# outer length is damaged) is a candidate that fails confirmation: UNKNOWN, never a hit.
t_an_unreadable_certificate_holding_a_listed_key_is_unknown() {
  first_cert "$FIX/listed-roots.crt" | awk 'NR == 2 { $0 = substr($0, 1, 3) (substr($0, 4, 1) == "A" ? "B" : "A") substr($0, 5) } { print }' >"$SB/damaged.pem"
  bash_run --incident "$EM" --bundle "$SB/damaged.pem"
  rc_is 11 && has_line '^UNKNOWN +bundle .*1 of 1 certificates could not be read'
}

t_one_dirty_bundle_fails_the_run() {
  bash_run --incident "$EM" --bundle "$FIX/unlisted.crt" --bundle "$FIX/listed-intermediates.crt"
  rc_is 10 && has_line '^PASS +bundle ' && has_line '^FAIL +bundle '
}

t_result_line_names_no_host_user_or_path() {
  bash_run --incident "$EM" --bundle "$FIX/listed-roots.crt"
  [ "$(printf '%s\n' "$OUT" | tail -n 1 | grep -Ec "$RESULT_RE")" = 1 ] || { WHY="last line is not /$RESULT_RE/"; return 1; }
}

t_home_folder_prints_as_tilde() {
  mkdir -p "$SB/bhome"
  cp "$FIX/unlisted.crt" "$SB/bhome/in-home.crt"
  bash_run --incident "$EM" --bundle "$SB/bhome/in-home.crt"
  has_line '^PASS +bundle +~/in-home\.crt' && lacks_line "$SB/bhome"
}

t_bundle_mode_writes_nothing() {
  local before after
  mkdir -p "$SB/bhome" "$SB/bcwd"
  before=$(find "$SB/bhome" "$SB/bcwd" | sort)
  OUT=$(cd "$SB/bcwd" && env -i HOME="$SB/bhome" PATH="$PATH" bash "$SH" --incident "$EM" --bundle "$FIX/unlisted.crt" 2>&1)
  after=$(find "$SB/bhome" "$SB/bcwd" | sort)
  [ "$before" = "$after" ] || { WHY="created: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"; return 1; }
}

# A valid incident and an offline bundle, so the unknown option is the only thing wrong
# (without them the run exits 2 for the missing --incident, and the test proves nothing).
t_unknown_option_is_a_usage_error() { bash_run --incident "$EM" --bundle "$FIX/unlisted.crt" --no-such-option; rc_is 2; }
t_incident_is_required() { bash_run --bundle "$FIX/unlisted.crt"; rc_is 2 && has_line 'packs here: .*emudhra-2026-10'; }
t_incident_name_cannot_be_a_path() { bash_run --incident ../../etc/passwd --bundle "$FIX/unlisted.crt"; rc_is 2; }
t_unknown_incident_is_not_found() { bash_run --incident no-such-incident --bundle "$FIX/unlisted.crt"; rc_is 3; }
t_accepts_the_three_path_pack() { bash_run --incident test-three-paths --offline --help; rc_is 0 && has_line "three +https://$T3_THREE/"; }
t_list_shows_every_pack() { bash_run --list; rc_is 0 && has_line '^emudhra-2026-10  2026-10-26  ' && has_line '^test-three-paths  '; }

t_help_prints_examples_and_the_pack_hosts() {
  bash_run --incident "$EM" --offline --help
  rc_is 0 && has_line '^EXAMPLES' && has_line "control +https://$EM_CONTROL/" && has_line "emSign +https://$EM_A/" && has_line "AAA +https://$EM_B/"
}

t_malformed_packs_are_refused() {
  local p
  for p in $BAD_PACKS; do
    bash_run --incident "$p" --bundle "$FIX/unlisted.crt"
    rc_is 4 || { WHY="$p: $WHY"; return 1; }
  done
}

# The hook can only ever mean localhost: anything but digits and commas is a usage error.
t_local_ports_hook_takes_digits_only() {
  bash_run CA_TRUST_LOCAL_PORTS=8191,evil.example,8193 --incident "$EM" --bundle "$FIX/unlisted.crt"
  rc_is 2 || return 1
  bash_run CA_TRUST_LOCAL_PORTS=8191,8192 --incident "$EM" --bundle "$FIX/unlisted.crt"
  rc_is 2 || { WHY="a port count that does not match the paths: $WHY"; return 1; }
}

t_local_ports_hook_means_localhost() {
  bash_run CA_TRUST_LOCAL_PORTS=8191,8192,8193 --incident "$EM" --offline --help
  rc_is 0 && has_line 'control +https://localhost:8191/' && has_line 'AAA +https://localhost:8193/' && lacks_line 'we-have-a-problem'
}

# === STANDINS ===
# The fakes look a URL's host up in FAKE_HOSTS ("host=state ...") and answer connected,
# rejected (a certificate error), reset, or a network error; the fake `openssl s_client`
# serves a chain chosen by FAKE_PATH (or per host by FAKE_PATHS).

CLIENTS="curl git python3 node"
FAKE=""
LOG=""

setup_standins() {
  local C="$SB/certs"
  REAL_OPENSSL=$(command -v openssl)
  FAKE="$SB/fake"; LOG="$SB/calls.log"
  mkdir -p "$FAKE" "$SB/home" "$SB/cwd" "$C"
  local sans="DNS:$EM_A,DNS:$EM_B,DNS:$T3_ONE,DNS:$T3_TWO,DNS:$T3_THREE"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$C/leaf.key" -out "$C/leaf.pem" -days 2 -subj /CN=canary -addext "subjectAltName=$sans" 2>/dev/null
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$C/other.key" -out "$C/other.pem" -days 2 -subj /CN=other -addext "subjectAltName=DNS:other.invalid" 2>/dev/null
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$C/prefix.key" -out "$C/prefix.pem" -days 2 -subj /CN=prefix \
    -addext "subjectAltName=DNS:$EM_A.invalid,DNS:$EM_B.invalid,DNS:$T3_ONE.x,DNS:$T3_TWO.x,DNS:$T3_THREE.x" 2>/dev/null
  new_ca "$C/oldca" old-ca
  new_key_csr "$C/old" canary "$sans"
  sign "$C/oldca" "$C/old" -startdate 20200101000000Z -enddate 20200102000000Z
  first_cert "$FIX/listed-intermediates.crt" >"$C/listed.pem"
  first_cert "$FIX/unlisted.crt" >"$C/notlisted.pem"

  cat >"$FAKE/state.sh" <<'EOF'
host_of() { local u=${1#https://}; u=${u%%/*}; printf '%s' "${u%%:*}"; }
state_for() {
  local h pair; h=$(host_of "$1")
  for pair in $FAKE_HOSTS; do case $pair in "$h="*) echo "${pair#*=}"; return ;; esac; done
  echo neterr
}
blocked() { local h; h=$(host_of "$1"); case " ${FAKE_BLOCKED:-} " in *" $h "*) return 0 ;; esac; return 1; }
url_in() { local u="" a; for a in "$@"; do case $a in https://*) u=$a ;; esac; done; printf '%s' "$u"; }
EOF
  cat >"$FAKE/openssl" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = s_client ]; then
  printf 'openssl %s\n' "\$*" >>"\$FAKE_LOG"
  host="" prev=""
  for a in "\$@"; do [ "\$prev" = -connect ] && host=\${a%:*}; prev=\$a; done
  state=\${FAKE_PATH:-ok}
  for pair in \${FAKE_PATHS:-}; do case \$pair in "\$host="*) state=\${pair#*=} ;; esac; done
  case \$state in
    ok) cat "$C/leaf.pem" "$C/listed.pem" ;;
    nochain) cat "$C/leaf.pem" "$C/notlisted.pem" ;;
    expired) cat "$C/old.pem" "$C/listed.pem" ;;
    wrongname) cat "$C/other.pem" "$C/listed.pem" ;;
    prefixname) cat "$C/prefix.pem" "$C/listed.pem" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exec "$REAL_OPENSSL" "\$@"
EOF
  # A filtering proxy: when a proxy variable reaches a client that does not bypass it, the
  # hosts in FAKE_BLOCKED answer with the proxy's own certificate, which the client refuses.
  cat >"$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/state.sh"
printf 'curl %s\n' "$*" >>"$FAKE_LOG"
u=$(url_in "$@")
if [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ] && blocked "$u"; then
  case " $* " in *" --noproxy "*) ;; *) echo "curl: (60) SSL certificate problem: unable to get local issuer certificate" >&2; exit 60 ;; esac
fi
case $(state_for "$u") in
  connected) exit 0 ;;
  rejected) echo "curl: (60) SSL certificate problem: unable to get local issuer certificate" >&2; exit 60 ;;
  reset) echo "curl: (35) Recv failure: Connection reset by peer" >&2; exit 35 ;;
  *) exit 6 ;;
esac
EOF
  cat >"$FAKE/git" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/state.sh"
printf 'git %s\n' "$*" >>"$FAKE_LOG"
case " $* " in *" --version "*) echo "git version 2.50.1"; exit 0 ;; esac
case " $* " in *" config "*) exit 1 ;; esac
u=$(url_in "$@")
if [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ] && blocked "$u"; then
  case " $* " in *" http.proxy= "*) ;; *) echo "fatal: unable to access '$u': SSL certificate problem: unable to get local issuer certificate" >&2; exit 128 ;; esac
fi
case $(state_for "$u") in
  connected) echo "fatal: repository '$u' not found" >&2 ;;
  rejected) echo "fatal: unable to access '$u': SSL certificate problem: unable to get local issuer certificate" >&2 ;;
  reset) echo "fatal: unable to access '$u': OpenSSL SSL_connect: Connection reset by peer" >&2 ;;
  *) echo "fatal: unable to access '$u': Could not resolve host: example" >&2 ;;
esac
exit 128
EOF
  cat >"$FAKE/python3" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/state.sh"
printf 'python3 %s\n' "$*" >>"$FAKE_LOG"
u=$(url_in "$@")
if [ -n "$u" ] && [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ] && blocked "$u"; then echo rejected; exit 0; fi
if [ -n "$u" ]; then case $(state_for "$u") in reset) echo neterr ;; *) state_for "$u" ;; esac; exit 0; fi
case "$*" in *version_info*) echo "3.12.3"; exit 0 ;; esac
exit 1
EOF
  cat >"$FAKE/node" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/state.sh"
printf 'node %s\n' "$*" >>"$FAKE_LOG"
case $1 in --version) echo "v22.23.4"; exit 0 ;; -p) cat "$FAKE_NODE_ROOTS"; exit 0 ;; esac
u=$(url_in "$@")
if [ "${NODE_USE_ENV_PROXY:-}" = 1 ] && [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ] && blocked "$u"; then echo rejected; exit 0; fi
if [ -n "$u" ]; then case $(state_for "$u") in reset) echo neterr ;; *) state_for "$u" ;; esac; exit 0; fi
exit 1
EOF
  cat >"$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$FAKE_LOG"
[ "$1" = --version ] && echo "${FAKE_CLAUDE:-2.1.310} (Claude Code)"
exit 0
EOF
  cat >"$FAKE/uv" <<'EOF'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >>"$FAKE_LOG"
[ "$1" = --version ] && echo "uv ${FAKE_UV:-0.13.5} (abc1234 2026-10-21)"
exit 0
EOF
  chmod +x "$FAKE"/*
}

new_key_csr() { openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$2" -addext "subjectAltName=$3" 2>/dev/null; }
new_ca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.pem" -days 30 -subj "/CN=$2" 2>/dev/null
  mkdir -p "$1.db"; : >"$1.db/index.txt"; echo 01 >"$1.db/serial"
  printf '%s\n' "[ca]" "default_ca = d" "[d]" "database = $1.db/index.txt" "serial = $1.db/serial" "new_certs_dir = $1.db" \
    "default_md = sha256" "policy = p" "copy_extensions = copy" "unique_subject = no" "[p]" "commonName = supplied" >"$1.cnf"
}
sign() { local ca=$1 out=$2; shift 2; openssl ca -batch -config "$ca.cnf" -cert "$ca.pem" -keyfile "$ca.key" -in "$out.csr" -out "$out.pem" -notext "$@" >/dev/null 2>&1; }

# fake_with INCIDENT HOSTMAP [VAR=value]... [ARGS]...: a full run against the stand-ins.
fake_with() {
  local incident=$1 hosts=$2 item key; shift 2
  key=$(memo_key fake "$incident" "$hosts" "$@")
  memo_load "$key" && return 0
  local e=() a=()
  for item in "$@"; do case $item in [A-Z_a-z]*=*) e+=("$item") ;; *) a+=("$item") ;; esac; done
  : >"$LOG"
  OUT=$(cd "$SB/cwd" && env -i HOME="$SB/home" PATH="$FAKE:/usr/bin:/bin" FAKE_LOG="$LOG" FAKE_NODE_ROOTS="$FIX/unlisted.crt" \
    FAKE_HOSTS="$hosts" ${e[@]+"${e[@]}"} bash "$SH" --incident "$incident" ${a[@]+"${a[@]}"} 2>&1)
  RC=$?
  cp "$LOG" "$CACHE/$key.log"
  LOGF="$CACHE/$key.log"
  memo_save "$key"
}
fake_run() { local c=$1 a=$2 b=$3; shift 3; fake_with "$EM" "$EM_CONTROL=$c $EM_A=$a $EM_B=$b" ${1+"$@"}; }
each_client() { local id; for id in $CLIENTS; do has_line "${1//@/$id}" || { WHY="$id: no line matches /${1//@/$id}/"; return 1; }; done; }
no_client() { local id; for id in $CLIENTS; do lacks_line "${1//@/$id}" || { WHY="$id: a line matches /${1//@/$id}/"; return 1; }; done; }
log_lines() { grep -E "$1" "$LOGF"; }

t_client_accepting_the_emsign_path_fails() { fake_run connected connected rejected; each_client '^FAIL +@ .*emSign path'; }
t_client_accepting_only_the_aaa_path_fails() { fake_run connected rejected connected; each_client '^FAIL +@ .*\(AAA path\)'; }
t_client_rejecting_every_chain_passes() { fake_run connected rejected rejected; each_client '^PASS +@ .*rejects every test chain \(emSign, AAA\)'; }
t_node_bundled_roots_are_read_offline() { fake_run connected connected rejected; has_line '^PASS +node-roots '; }

t_writes_nothing_to_home_or_cwd() {
  local before after
  before=$(find "$SB/home" "$SB/cwd" | sort)
  fake_with "$EM" "$EM_CONTROL=connected $EM_A=connected $EM_B=rejected" FAKE_FRESH=writes
  after=$(find "$SB/home" "$SB/cwd" | sort)
  [ "$before" = "$after" ] || { WHY="created: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"; return 1; }
}

t_curlrc_is_never_read() { fake_run connected connected rejected; ! log_lines '^curl .*https://' | grep -vqE '^curl -q ' || { WHY="curl ran without -q"; return 1; }; }
t_curl_bypasses_proxies() { fake_run connected connected rejected; ! log_lines '^curl .*https://' | grep -vqF -- '--noproxy * ' || { WHY="curl may use a proxy"; return 1; }; }
t_git_credentials_are_never_offered() { fake_run connected connected rejected; ! log_lines '^git .*ls-remote' | grep -vq 'credential.helper= ' || { WHY="git ran with credential helpers"; return 1; }; }
t_git_extra_headers_are_dropped() { fake_run connected connected rejected; ! log_lines '^git .*ls-remote' | grep -vq 'http.extraHeader= ' || { WHY="git kept configured extra headers"; return 1; }; }
t_git_never_follows_redirects() { fake_run connected connected rejected; ! log_lines '^git .*ls-remote' | grep -vq 'http.followRedirects=false ' || { WHY="git may follow a redirect"; return 1; }; }
t_git_sends_the_fixed_user_agent() { fake_run connected connected rejected; ! log_lines '^git .*ls-remote' | grep -vq 'http.userAgent=ca-trust-ops/1 ' || { WHY="git sends its own User-Agent"; return 1; }; }
t_git_bypasses_configured_proxies() { fake_run connected connected rejected; ! log_lines '^git .*ls-remote' | grep -vq 'http.proxy= ' || { WHY="git may use a configured proxy"; return 1; }; }
t_paths_are_confirmed_before_a_result_counts() { fake_run connected connected rejected; log_lines '^openssl s_client' >/dev/null || { WHY="no path handshake ran"; return 1; }; }

t_only_the_pack_hosts_are_contacted() {
  local hosts
  fake_run connected connected rejected
  hosts=$( { grep -oE 'https://[^ ]+' "$LOGF"; grep -oE -- '-connect [^ ]+' "$LOGF" | sed 's#-connect #https://#'; } | sed -E 's#https://([^/:]+).*#\1#' | LC_ALL=C sort -u | tr '\n' ' ')
  [ "$hosts" = "$EM_B $EM_A $EM_CONTROL " ] || { WHY="contacted: $hosts"; return 1; }
}

t_current_tool_versions_pass() { fake_run connected rejected rejected; has_line '^PASS +claude-code .*2\.1\.310' && has_line '^PASS +uv .*0\.13\.5'; }
t_old_tool_versions_fail() { fake_run connected rejected rejected FAKE_CLAUDE=2.1.288 FAKE_UV=0.11.2; has_line '^FAIL +claude-code .*2\.1\.288 predates 2\.1\.303' && has_line '^FAIL +uv .*0\.11\.2'; }
t_tool_version_compare_is_numeric() { fake_run connected rejected rejected FAKE_CLAUDE=2.1.1000; has_line '^PASS +claude-code .*2\.1\.1000'; }

# The checker clears proxy variables; were one to reach a client, the proxy's refusal of
# the test hosts would read as the client's own, and a FAIL would turn into a PASS.
t_a_filtering_proxy_cannot_turn_fail_into_pass() {
  fake_run connected connected connected https_proxy=http://proxy.invalid:3128 HTTPS_PROXY=http://proxy.invalid:3128 NODE_USE_ENV_PROXY=1 "FAKE_BLOCKED=$EM_A $EM_B"
  each_client '^FAIL +@ .*emSign path and AAA path'
}

t_client_that_trusts_nothing_is_unknown() { fake_run rejected rejected rejected; each_client '^UNKNOWN +@ .*control page' && no_client '^PASS +@ '; }
t_offline_client_is_unknown_not_pass() { fake_run neterr neterr neterr; each_client '^UNKNOWN +@ ' && no_client '^PASS +@ '; }
t_unreachable_test_host_is_unknown_even_when_the_other_refuses() { fake_run connected rejected neterr; each_client '^UNKNOWN +@ ' && no_client '^PASS +@ '; }
t_a_reset_during_the_handshake_is_unknown_not_pass() { fake_run connected reset rejected; has_line '^UNKNOWN +curl ' && lacks_line '^PASS +curl '; }

test_site_unconfirmed() { fake_run connected rejected rejected "FAKE_PATH=$1"; each_client '^UNKNOWN +@ .*could not be tested' && no_client '^PASS +@ '; }
t_test_site_without_a_listed_key_is_unknown() { test_site_unconfirmed nochain; }
t_test_site_with_an_expired_leaf_is_unknown() { test_site_unconfirmed expired; }
t_test_site_with_a_leaf_for_another_name_is_unknown() { test_site_unconfirmed wrongname; }
t_test_site_whose_leaf_name_only_starts_with_the_host_is_unknown() { test_site_unconfirmed prefixname; }
t_unreachable_test_site_is_unknown() { test_site_unconfirmed unreachable; }
t_an_intercepted_test_site_is_never_read_as_fail() { fake_run connected connected connected FAKE_PATH=nochain; no_client '^FAIL +@ '; }

t_insecure_env_fails() { fake_run connected rejected rejected NODE_TLS_REJECT_UNAUTHORIZED=0; has_line '^FAIL +tls-env .*NODE_TLS_REJECT_UNAUTHORIZED'; }
t_offline_mode_contacts_nothing() {
  fake_run connected connected connected --offline
  has_line '^UNKNOWN +network ' && { ! grep -qE 'https://|s_client' "$LOGF" || { WHY="offline mode made a network call: $(grep -E 'https://|s_client' "$LOGF" | head -n 1)"; return 1; }; }
}
t_a_bundle_named_by_ssl_cert_file_is_checked() { fake_run connected rejected rejected "SSL_CERT_FILE=$FIX/listed-roots.crt"; has_line '^FAIL +env-SSL_CERT_FILE .*AAA Certificate Services'; }
t_fix_hints_name_the_packs_fixed_versions() { fake_run connected connected rejected; has_line '^FAIL +node .* - fix: update Node\.js to 22\.23\.4, 24\.22\.1, 26\.12\.1 or later'; }

three() { fake_with test-three-paths "$T3_CONTROL=connected $T3_ONE=$1 $T3_TWO=$2 $T3_THREE=$3" ${4+"$4"}; }
t_three_paths_all_refused_pass() { three rejected rejected rejected; each_client '^PASS +@ .*rejects every test chain \(one, two, three\)'; }
t_three_paths_an_open_later_path_fails() { three rejected rejected connected; each_client '^FAIL +@ .*\(three path\)' && no_client '^FAIL +@ .*one path'; }
t_three_paths_one_unconfirmed_is_unknown() { three rejected rejected rejected "FAKE_PATHS=$T3_TWO=nochain"; each_client '^UNKNOWN +@ .*the two test site' && no_client '^PASS +@ '; }
t_a_pack_without_fixed_versions_still_gives_a_fix() { three connected rejected rejected; has_line '^FAIL +node .* - fix: update Node\.js to a release with the Test fix'; }

# === REAL ===

serve() {
  openssl s_server -accept "$1" -cert "$2.pem" -key "$2.key" -cert_chain "$3" -www -quiet >/dev/null 2>&1 &
  SERVERS="$SERVERS $!"
}
stop_servers() { local pid; for pid in $SERVERS; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done; SERVERS=""; }
wait_port() {
  local i
  for i in $(seq 1 40); do
    python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1).close()" "$1" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}
start_canaries() {
  stop_servers
  serve 8191 "$L/control" "$L/controlca.pem"
  serve 8192 "$L/$1" "$L/chain.pem"
  serve 8193 "$L/$1" "$L/chain.pem"
  wait_port 8191 && wait_port 8192 && wait_port 8193
}
local_run() {
  OUT=$(cd "$SB/cwd" && env -i HOME="$SB/home2" PATH="/usr/local/bin:/usr/bin:/bin" CA_TRUST_LOCAL_PORTS="${2:-8191,8192,8193}" \
    SSL_CERT_FILE="$1" CURL_CA_BUNDLE="$1" GIT_SSL_CAINFO="$1" NODE_EXTRA_CA_CERTS="$1" bash "$SH" --incident "$EM" 2>&1)
}

run_real_group() {
  local clients="curl git python3" id usersite
  command -v node >/dev/null 2>&1 && clients="$clients node" || skip "node is not installed, so its real probe is not run here"
  L="$SB/local"; mkdir -p "$L" "$SB/home2"
  new_ca "$L/controlca" control-ca
  new_ca "$L/canaryca" canary-ca
  new_key_csr "$L/control" localhost "DNS:localhost"; sign "$L/controlca" "$L/control" -days 2
  new_key_csr "$L/good" localhost "DNS:localhost"; sign "$L/canaryca" "$L/good" -days 2
  new_key_csr "$L/wrong" localhost "DNS:localhost.invalid"; sign "$L/canaryca" "$L/wrong" -days 2
  new_key_csr "$L/old" localhost "DNS:localhost"; sign "$L/canaryca" "$L/old" -startdate 20200101000000Z -enddate 20200102000000Z
  cat "$L/canaryca.pem" "$SB/certs/listed.pem" >"$L/chain.pem"
  cat "$L/controlca.pem" >"$L/trust-control.pem"
  cat "$L/controlca.pem" "$L/canaryca.pem" >"$L/trust-both.pem"
  # A user-site certifi that points at a dirty bundle: python -I hides it unless asked.
  usersite=$(env -i HOME="$SB/home2" PATH="/usr/local/bin:/usr/bin:/bin" python3 -c 'import site; print(site.getusersitepackages())')
  mkdir -p "$usersite/certifi"
  printf 'def where():\n    return %s\n' "'$FIX/listed-roots.crt'" >"$usersite/certifi/__init__.py"

  if start_canaries good; then
    local_run "$L/trust-control.pem"
    for id in $clients; do has_line "^PASS +$id " && ok "real_$id: an untrusted test chain reads PASS" || no "real_$id: an untrusted test chain reads PASS - $WHY"; WHY=""; done
    has_line '^FAIL +certifi .*listed-roots\.crt' && ok "user_site_certifi_is_found" || no "user_site_certifi_is_found - $WHY"; WHY=""
    local_run "$L/trust-both.pem"
    for id in $clients; do has_line "^FAIL +$id .*emSign path and AAA path" && ok "real_$id: a trusted test chain reads FAIL" || no "real_$id: a trusted test chain reads FAIL - $WHY"; WHY=""; done
  else
    no "the local test servers did not start on 8191-8193"
  fi
  if start_canaries wrong; then
    local_run "$L/trust-both.pem"
    for id in $clients; do has_line "^UNKNOWN +$id .*does not name localhost" && ok "real_$id: a leaf for another name is UNKNOWN" || no "real_$id: a leaf for another name is UNKNOWN - $WHY"; WHY=""; done
  fi
  if start_canaries old; then
    local_run "$L/trust-control.pem"
    for id in $clients; do has_line "^UNKNOWN +$id .*has expired" && ok "real_$id: an expired test leaf is UNKNOWN" || no "real_$id: an expired test leaf is UNKNOWN - $WHY"; WHY=""; done
  fi
  stop_servers
  serve 8191 "$L/control" "$L/controlca.pem"
  python3 -c 'import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 8194)); s.listen(8)
while True:
    c, _ = s.accept(); c.close()' >/dev/null 2>&1 &
  SERVERS="$SERVERS $!"
  if wait_port 8191 && wait_port 8194; then
    local_run "$L/trust-control.pem" 8191,8194,8194
    for id in $clients; do has_line "^UNKNOWN +$id " && lacks_line "^PASS +$id " && ok "real_$id: a test host that resets the handshake is UNKNOWN, not PASS" || no "real_$id: a test host that resets the handshake is UNKNOWN, not PASS - $WHY"; WHY=""; done
  fi
  stop_servers
}

# === POWERSHELL ===

PSHELL=""
ps_run() {
  local key; key=$(memo_key ps "$PSHELL" "$@")
  memo_load "$key" && return 0
  OUT=$("$PSHELL" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(native_path "$PSHELL" "$PS")" "$@" 2>&1 | tr -d '\r')
  RC=${PIPESTATUS[0]}
  memo_save "$key"
}
psf() { native_path "$PSHELL" "$1"; }

t_ps_listed_root_in_bundle_fails() {
  ps_run -Incident "$EM" -Bundle "$(psf "$FIX/listed-roots.crt")"
  rc_is 10 && has_line '^FAIL +bundle .*emSign ECC Root CA - G3' && has_line '^FAIL +bundle .*AAA Certificate Services' && has_line '^FAIL +bundle .*emSign Root TLS CA - G3'
}
t_ps_cross_signed_intermediate_caught_by_its_key() { ps_run -Incident "$EM" -Bundle "$(psf "$FIX/listed-cross-signs.crt")"; rc_is 10 && has_line '^FAIL +bundle .*EM DV TLS CA - G3B'; }
t_ps_sibling_roots_stay_trusted() { ps_run -Incident "$EM" -Bundle "$(psf "$FIX/unlisted.crt")"; rc_is 0 && has_line '^PASS +bundle .*none of the 12 listed keys in 4 certificates'; }
t_ps_missing_bundle_is_unknown_not_pass() { ps_run -Incident "$EM" -Bundle "$(psf "$SB/no-such-bundle.pem")"; rc_is 11 && has_line '^UNKNOWN +bundle '; }
t_ps_unreadable_certificate_is_unknown_not_pass() {
  { cat "$FIX/unlisted.crt"; printf '%s\n' '-----BEGIN CERTIFICATE-----' 'bm90IGEgY2VydGlmaWNhdGU=' '-----END CERTIFICATE-----'; } >"$SB/garbled.pem"
  ps_run -Incident "$EM" -Bundle "$(psf "$SB/garbled.pem")"
  rc_is 11 && has_line '^UNKNOWN +bundle .*1 of 5 certificates could not be read'
}
t_ps_every_listed_fixture_certificate_is_caught() {
  local f c id want got
  for f in "$SKILL"/assets/incidents/*.conf; do
    id=$(basename "$f" .conf)
    for c in "$SKILL/tests/fixtures/$id"/listed-*.crt; do
      want=$(spki_of_file "$c" | sort -u | grep -c .)
      ps_run -Incident "$id" -Bundle "$(psf "$c")"
      got=$(printf '%s\n' "$OUT" | grep -E '^FAIL +bundle ' | sed -e 's/.* trusts //' -e 's/ - fix: .*//' | tr ';' '\n' | grep -c .)
      [ "$RC" = 10 ] && [ "$got" = "$want" ] || { WHY="$id/$(basename "$c"): $got of $want listed keys found (exit $RC)"; return 1; }
    done
  done
}
t_ps_result_line_names_no_host_user_or_path() {
  ps_run -Incident "$EM" -Bundle "$(psf "$FIX/listed-roots.crt")"
  [ "$(printf '%s\n' "$OUT" | grep -v '^$' | tail -n 1 | grep -Ec "$RESULT_RE")" = 1 ] || { WHY="last line is not /$RESULT_RE/"; return 1; }
}
t_ps_list_shows_every_pack() { ps_run -List; rc_is 0 && has_line '^emudhra-2026-10  2026-10-26  ' && has_line '^test-three-paths  '; }
t_ps_incident_name_cannot_be_a_path() { ps_run -Incident '..\..\x' -Bundle "$(psf "$FIX/unlisted.crt")"; rc_is 2; }
# -Bundle keeps a broken checker offline: without it, a script that ignored the argument would
# run a full live check of this machine.
t_ps_unknown_argument_is_a_usage_error() { ps_run -Incident "$EM" -Bundle "$(psf "$FIX/unlisted.crt")" -NoSuchSwitch; rc_is 2; }
t_ps_accepts_the_three_path_pack() { ps_run -Incident test-three-paths -Help; rc_is 0 && has_line "three +https://$T3_THREE/"; }
# One PowerShell session for the whole sweep: a process start per pack cost a minute.
t_ps_malformed_packs_are_refused() {
  local p cmd="" key
  for p in $BAD_PACKS; do
    cmd="$cmd & '$(psf "$PS")' -Incident $p -Bundle '$(psf "$FIX/unlisted.crt")' *> \$null; '$p=' + \$LASTEXITCODE;"
  done
  key=$(memo_key psbad "$PSHELL")
  if ! memo_load "$key"; then
    OUT=$("$PSHELL" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$cmd" 2>&1 | tr -d '\r')
    RC=$?
    memo_save "$key"
  fi
  for p in $BAD_PACKS; do
    has_line "^$p=4\$" || { WHY="$p: not refused with exit 4"; return 1; }
  done
}

# Run inside one session, as a user would: no variable created (pwsh 7 leaves an empty one
# behind when given $null, and git turns tracing on when GIT_CURL_VERBOSE merely exists) and
# none lost (Windows names ignore case, so https_proxy and HTTPS_PROXY are one variable).
t_ps_running_in_a_session_leaves_its_environment_as_it_was() {
  local cmd
  cmd="\$env:HTTPS_PROXY = 'http://proxy.invalid:3128'; & '$(psf "$PS")' -Incident $EM -Bundle '$(psf "$FIX/unlisted.crt")' | Out-Null; "
  cmd="$cmd foreach (\$n in 'GIT_CURL_VERBOSE', 'GIT_TRACE', 'SSLKEYLOGFILE', 'WSL_UTF8', 'NODE_USE_ENV_PROXY') { if (\$null -ne [Environment]::GetEnvironmentVariable(\$n)) { 'created ' + \$n } }; "
  cmd="$cmd if (\$env:HTTPS_PROXY -ne 'http://proxy.invalid:3128') { 'lost HTTPS_PROXY' }"
  OUT=$("$PSHELL" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$cmd" 2>&1 | tr -d '\r')
  [ -z "$OUT" ] || { WHY="the session's environment changed: $(printf '%s' "$OUT" | tr '\n' ' ')"; return 1; }
}

PS_TESTS="t_ps_listed_root_in_bundle_fails t_ps_cross_signed_intermediate_caught_by_its_key t_ps_sibling_roots_stay_trusted t_ps_every_listed_fixture_certificate_is_caught
  t_ps_missing_bundle_is_unknown_not_pass t_ps_unreadable_certificate_is_unknown_not_pass t_ps_result_line_names_no_host_user_or_path
  t_ps_list_shows_every_pack t_ps_incident_name_cannot_be_a_path t_ps_unknown_argument_is_a_usage_error t_ps_accepts_the_three_path_pack
  t_ps_malformed_packs_are_refused t_ps_running_in_a_session_leaves_its_environment_as_it_was"

PSHELLS=""
for s in pwsh powershell.exe; do command -v "$s" >/dev/null 2>&1 && PSHELLS="$PSHELLS $s"; done

# Two of the landmines exist only on some hosts: pwsh 7 keeps an empty variable when handed
# $null, and Windows variable names ignore case. A mutant only such a host can catch runs
# only on shells that have the quirk (probed here), and is skipped elsewhere.
ps_says_yes() { "$1" -NoProfile -NonInteractive -Command "$2" 2>/dev/null | tr -d '\r' | grep -qx yes; }
NULL_QUIRK_SHELLS=""
CASELESS_SHELLS=""
probe_ps_quirks() {
  local s
  for s in $PSHELLS; do
    ps_says_yes "$s" "[Environment]::SetEnvironmentVariable('CA_TRUST_PROBE', \$null); if (\$null -ne [Environment]::GetEnvironmentVariable('CA_TRUST_PROBE')) { 'yes' }" \
      && NULL_QUIRK_SHELLS="$NULL_QUIRK_SHELLS $s"
    ps_says_yes "$s" "\$env:CA_TRUST_PROBE = '1'; if (\$null -ne [Environment]::GetEnvironmentVariable('ca_trust_probe')) { 'yes' }" \
      && CASELESS_SHELLS="$CASELESS_SHELLS $s"
  done
}

# === MUTANTS ===
# mutant GROUP NAME FILE OLD NEW PREDICATE...: replaces the one occurrence of OLD in a copy
# of scripts/FILE and expects at least one PREDICATE to fail against it. OLD must occur
# exactly once, so a refactor that moves the guarded code fails here loudly instead of
# leaving a mutant that silently tests nothing.
MUTANT_N=0
mutant() {
  local group=$1 name=$2 file=$3 old=$4 new=$5 dir count p shell shells killed=""
  shift 5
  case " $AVAILABLE " in *" $group "*) ;; *) skip "mutant ($group unavailable here): $name"; return ;; esac
  MUTANT_N=$((MUTANT_N + 1))
  dir=$(make_target "mutant-$MUTANT_N")
  count=$(OLD=$old awk 'BEGIN { o = ENVIRON["OLD"] } { s = $0; while ((i = index(s, o)) > 0) { n++; s = substr(s, i + length(o)) } } END { print n + 0 }' "$dir/scripts/$file")
  if [ "$count" != 1 ]; then
    no "mutant $name: its target text occurs $count times in $file, want 1 - update the mutant"
    return
  fi
  OLD=$old NEW=$new awk 'BEGIN { o = ENVIRON["OLD"]; r = ENVIRON["NEW"] } { i = index($0, o); if (i) $0 = substr($0, 1, i - 1) r substr($0, i + length(o)); print }' \
    "$dir/scripts/$file" >"$dir/scripts/$file.new" && mv "$dir/scripts/$file.new" "$dir/scripts/$file"
  use_target "$dir"
  for p in "$@"; do
    if case $group in powershell | ps-*) true ;; *) false ;; esac; then
      case $group in
        ps-null-quirk) shells=$NULL_QUIRK_SHELLS ;;
        ps-caseless-env) shells=$CASELESS_SHELLS ;;
        *) shells=$PSHELLS ;;
      esac
      for shell in $shells; do PSHELL=$shell; WHY=""; "$p" || { killed="$p ($shell)"; break; }; done
    else
      WHY=""; "$p" || killed=$p
    fi
    [ -n "$killed" ] && break
  done
  use_target "$MAIN"
  [ -n "$killed" ] && ok "mutant caught by ${killed#t_}: $name" || no "mutant survived: $name (expected one of: $*)"
}

run_mutants() {
  local S=check-ca-trust.sh P=check-ca-trust.ps1
  mutant pack "pack-keys prints a shared key once per certificate" pack-keys.sh '    case $seen in *"|$hash|"*) continue ;; esac' '    :' t_pack_keys_tool_reproduces_each_pack
  mutant bundles "a FAIL exits 0" $S 'verdict=FAIL code=10' 'verdict=FAIL code=0' t_listed_root_in_bundle_fails
  mutant bundles "needles cover one base64 alignment only" $S '    for (s = 0; s < 3; s++) needle[++n]' '    for (s = 0; s < 1; s++) needle[++n]' t_every_listed_fixture_certificate_is_caught
  mutant bundles "a candidate counts without its hash being confirmed" $S 'collecting=0; confirm_candidate "$pem" ;;' 'collecting=0; add_hit unconfirmed ;;' \
    t_an_unreadable_certificate_holding_a_listed_key_is_unknown
  mutant bundles "a block that is not base64 DER counts as clean" $S '{ bad++; next }' '{ next }' t_unreadable_certificate_is_unknown_not_pass
  mutant bundles "an SPKI the scanner cannot parse is accepted" $S '    *BADSPKI*) pack_error' '    *NEVER-PRINTED*) pack_error' t_malformed_packs_are_refused
  mutant bundles "bundles are matched by certificate hash, not key" $S \
    'openssl x509 -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst' 'openssl x509 -outform der 2>/dev/null | openssl dgst' \
    t_cross_signed_intermediate_caught_by_its_key
  mutant bundles "an empty bundle reads PASS" $S '  if [ "$SCAN_TOTAL" -eq 0 ]; then' '  if false; then' t_empty_bundle_is_unknown_not_pass
  mutant bundles "unreadable certificates are ignored" $S '  elif [ "$SCAN_BAD" -gt 0 ]; then' '  elif false; then' t_unreadable_certificate_is_unknown_not_pass
  mutant bundles "the home folder prints in full" $S '    text=${text//"$HOME"/$tilde}' '    text=$text' t_home_folder_prints_as_tilde
  mutant bundles "the RESULT line carries a path" $S '"$TOOL" "$PACK_ID" "${PLATFORM:-bundles}"' '"$TOOL" "$PACK_ID" "${PLATFORM:-bundles} $PWD"' t_result_line_names_no_host_user_or_path
  mutant bundles "the checker writes a file" $S 'readonly TOOL="ca-trust-ops 1"' ': >"$HOME/.ca-trust-ops-mutant"; readonly TOOL="ca-trust-ops 1"' t_bundle_mode_writes_nothing
  mutant bundles "pack hosts are not validated" $S '    "" | .* | *. | -* | *- | *..* | *[!a-z0-9.-]*) return 1 ;;' '    "") return 1 ;;' t_malformed_packs_are_refused
  mutant bundles "unknown pack records are ignored" $S '      *) pack_error "line $n: unknown record type' '      *) : "line $n: unknown record type' t_malformed_packs_are_refused
  mutant bundles "the incident name may be a path" $S '  -* | *[!a-z0-9-]*) usage_error "an incident name' '  -*) usage_error "an incident name' t_incident_name_cannot_be_a_path
  mutant bundles "the local-ports hook takes any text" $S '    *[!0-9,]* | ,* | *, | *,,*) usage_error' '    ,,,,) usage_error' t_local_ports_hook_takes_digits_only

  mutant standins "the control page no longer gates a verdict" $S '  if [ "$control" != connected ]; then' '  if false; then' t_client_that_trusts_nothing_is_unknown
  mutant standins "a path's chain is not confirmed" $S '    if [ "${TP_STATE[$i]}" = ok ]; then' '    if true; then' t_test_site_without_a_listed_key_is_unknown
  mutant standins "the handshake needs no listed key" $S '  [ -n "$SCAN_HITS" ] || { echo "it did not present' '  true || { echo "it did not present' t_test_site_without_a_listed_key_is_unknown
  mutant standins "an expired leaf is accepted" $S 'openssl x509 -noout -checkend 0 >/dev/null 2>&1 ||' 'true ||' t_test_site_with_an_expired_leaf_is_unknown
  mutant standins "any leaf name is accepted" $S '    *) echo "its certificate does not name $host" ;;' '    *) echo ok ;;' t_test_site_with_a_leaf_for_another_name_is_unknown
  mutant standins "a name that starts with the host matches" $S '*", DNS:$host,"*' '*", DNS:$host"*' t_test_site_whose_leaf_name_only_starts_with_the_host_is_unknown
  mutant standins "curl exit 35 is always a refusal" $S '    51 | 60) echo rejected ;;' '    35 | 51 | 60) echo rejected ;;' t_a_reset_during_the_handshake_is_unknown_not_pass
  mutant standins "curl reads .curlrc" $S 'err=$("$bin" -q -sS' 'err=$("$bin" -sS' t_curlrc_is_never_read
  mutant standins "curl may use a proxy" $S "-q -sS --noproxy '*' -o" '-q -sS -o' t_curl_bypasses_proxies
  mutant standins "proxy variables reach the clients" $S 'unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY NODE_USE_ENV_PROXY' 'unset ALL_PROXY' t_a_filtering_proxy_cannot_turn_fail_into_pass
  mutant standins "git offers credentials" $S '"$bin" -c credential.helper= -c http.extraHeader=' '"$bin" -c http.extraHeader=' t_git_credentials_are_never_offered
  mutant standins "git keeps extra headers" $S ' -c http.extraHeader= -c http.cookieFile=' ' -c http.cookieFile=' t_git_extra_headers_are_dropped
  mutant standins "git follows redirects" $S '-c http.followRedirects=false ' '' t_git_never_follows_redirects
  mutant standins "git keeps a configured proxy" $S '-c core.askPass= -c http.proxy= ' '-c core.askPass= ' t_git_bypasses_configured_proxies
  mutant standins "another host is contacted" $S 'CONTROL_URL=$(url_of "$CONTROL_HOST" "$CONTROL_PORT")' 'CONTROL_URL=$(url_of "example.com" "$CONTROL_PORT")' t_only_the_pack_hosts_are_contacted
  mutant standins "versions compare as text" $S 'if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1' 'if (x[i] "" < y[i] "") exit 0; if (x[i] "" > y[i] "") exit 1' t_tool_version_compare_is_numeric
  mutant standins "NODE_TLS_REJECT_UNAUTHORIZED=0 is not flagged" $S '[ "$(printenv NODE_TLS_REJECT_UNAUTHORIZED 2>/dev/null)" = 0 ] && bad=' 'false && bad=' t_insecure_env_fails
  mutant standins "offline mode still probes" $S '  [ "$OFFLINE" -eq 1 ] && return' '  :' t_offline_mode_contacts_nothing
  mutant standins "SSL_CERT_FILE's bundle is not read" $S '  for name in SSL_CERT_FILE CURL_CA_BUNDLE' '  for name in CURL_CA_BUNDLE' t_a_bundle_named_by_ssl_cert_file_is_checked
  mutant standins "an open path is not reported" $S '  if [ -n "$open" ]; then' '  if false; then' t_client_accepting_the_emsign_path_fails
  mutant standins "only the first trust path is probed" $S '    seen="${seen:+$seen, }${TP_LABEL[$i]} test $result"' \
    '    seen="${seen:+$seen, }${TP_LABEL[$i]} test $result"; i=$TP_COUNT' t_client_accepting_only_the_aaa_path_fails
  mutant standins "a client that refuses every chain is not passed" $S '  elif [ "$all_rejected" -eq 1 ]; then' '  elif false; then' t_client_rejecting_every_chain_passes
  mutant standins "an unconfirmed path is probed and counted" $S '      result=unconfirmed' '      result=$("$@" "${TP_URL[$i]}")' t_an_intercepted_test_site_is_never_read_as_fail
  mutant standins "the path handshake is skipped" $S '  confirm_paths' '  PATHS_CONFIRMED=1' t_paths_are_confirmed_before_a_result_counts
  mutant standins "git sends its own User-Agent" $S ' -c "http.userAgent=$AGENT"' '' t_git_sends_the_fixed_user_agent
  mutant standins "a tool older than the fix passes" $S '  if version_lt "$version" "$minimum"; then' '  if false; then' t_old_tool_versions_fail
  mutant standins "fix hints ignore the pack's fixed versions" $S '          node) FIXED_NODE=$b ;;' '          node) ;;' t_fix_hints_name_the_packs_fixed_versions
  mutant standins "a pack without fixed versions gives an empty hint" $S "else printf '%s to a release with the %s fix' \"\$1\" \"\$NAME\"; " '' \
    t_a_pack_without_fixed_versions_still_gives_a_fix
  mutant standins "Node's bundled roots are not read" $S '  if [ -n "$roots" ] && have openssl; then' '  if false; then' t_node_bundled_roots_are_read_offline
  mutant standins "a check writes a file" $S '  local bad=""' '  local bad=""; : >"$HOME/.ca-trust-ops-mutant"' t_writes_nothing_to_home_or_cwd
  mutant standins "only the first trust path can fail" $S '    [ "$result" = connected ] && open="${open:+$open and }${TP_LABEL[$i]} path"' \
    '    [ "$result" = connected ] && [ "$i" -eq 0 ] && open="${TP_LABEL[$i]} path"' t_three_paths_an_open_later_path_fails

  mutant powershell "PowerShell walks the SPKI without the version tag" $P 'if ($Der[$p] -eq 0xA0) {' 'if ($false) {' t_ps_listed_root_in_bundle_fails
  mutant powershell "PowerShell ignores unreadable certificates" $P 'if (-not $key) { $bad++; continue }' 'if (-not $key) { continue }' t_ps_unreadable_certificate_is_unknown_not_pass
  mutant powershell "PowerShell passes a missing bundle" $P 'Write-Result UNKNOWN $Id "$Path does not exist"' 'Write-Result PASS $Id "$Path does not exist"' t_ps_missing_bundle_is_unknown_not_pass
  mutant powershell "PowerShell ignores unknown arguments" $P 'if ($args.Count -gt 0) { Stop-Usage' 'if ($false) { Stop-Usage' t_ps_unknown_argument_is_a_usage_error
  mutant powershell "PowerShell takes a path for the incident name" $P "if (\$Incident -cnotmatch '^[a-z0-9][a-z0-9-]*\$') {" 'if ($false) {' t_ps_incident_name_cannot_be_a_path
  mutant powershell "PowerShell's RESULT line carries the user name" $P '$Tool, $script:Pack.Id, $script:Platform,' '$Tool, $script:Pack.Id, "$($script:Platform) $env:USERNAME",' \
    t_ps_result_line_names_no_host_user_or_path
  mutant powershell "PowerShell accepts an SPKI bash would refuse" $P 'if (-not (Test-SpkiShape $v[2])) {' 'if ($false) {' t_ps_malformed_packs_are_refused
  mutant powershell "PowerShell does not validate pack hosts" $P "return (\$Name -cmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\$') -and" 'return $true -or' t_ps_malformed_packs_are_refused
  mutant ps-null-quirk "PowerShell clears with \$null" $P '[Environment]::SetEnvironmentVariable($Name, [NullString]::Value)' '[Environment]::SetEnvironmentVariable($Name, $null)' \
    t_ps_running_in_a_session_leaves_its_environment_as_it_was
  mutant ps-caseless-env "PowerShell saves and clears in one pass" $P 'foreach ($name in $cleared) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }' \
    'foreach ($name in $cleared) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); Set-ProcessEnv $name $null }' \
    t_ps_running_in_a_session_leaves_its_environment_as_it_was
}

# === MAIN ===

echo "=== ca-trust-ops self-test ==="
command -v openssl >/dev/null 2>&1 || { echo "  SKIP  openssl is not installed, so nothing can be checked"; exit 0; }
MAIN=$(make_target main)
use_target "$MAIN"
AVAILABLE="pack bundles"
LINUX=0
[ "$(uname -s)" = Linux ] && LINUX=1
[ "$LINUX" -eq 1 ] && AVAILABLE="$AVAILABLE standins"
[ -n "$PSHELLS" ] && AVAILABLE="$AVAILABLE powershell"
if wanted mutants && [ "$MUTANTS" -eq 1 ] && [ -n "$PSHELLS" ]; then
  probe_ps_quirks
  [ -n "$NULL_QUIRK_SHELLS" ] && AVAILABLE="$AVAILABLE ps-null-quirk"
  [ -n "$CASELESS_SHELLS" ] && AVAILABLE="$AVAILABLE ps-caseless-env"
fi

if wanted pack; then
  echo "--- pack: the listed keys are the keys of the real certificates"
  for t in t_every_pack_has_fixtures_and_a_reference t_pack_keys_equal_their_fixture_keys t_unaffected_certificates_are_not_listed \
    t_pack_spki_hashes_match_their_keys t_pack_keys_tool_reproduces_each_pack t_pack_keys_tool_follows_the_script_contract \
    t_keys_live_only_in_packs t_packs_are_ascii_with_lf_endings; do OUT=""; check "$t"; done
fi

if wanted bundles; then
  echo "--- bundles: bash, offline"
  for t in t_listed_root_in_bundle_fails t_cross_signed_intermediate_caught_by_its_key t_sibling_roots_stay_trusted \
    t_missing_bundle_is_unknown_not_pass t_empty_bundle_is_unknown_not_pass t_unreadable_certificate_is_unknown_not_pass \
    t_every_listed_fixture_certificate_is_caught t_an_unreadable_certificate_holding_a_listed_key_is_unknown \
    t_one_dirty_bundle_fails_the_run t_result_line_names_no_host_user_or_path t_home_folder_prints_as_tilde t_bundle_mode_writes_nothing \
    t_unknown_option_is_a_usage_error t_incident_is_required t_incident_name_cannot_be_a_path t_unknown_incident_is_not_found \
    t_list_shows_every_pack t_accepts_the_three_path_pack t_help_prints_examples_and_the_pack_hosts t_malformed_packs_are_refused \
    t_local_ports_hook_takes_digits_only t_local_ports_hook_means_localhost; do check "$t"; done
fi

if wanted standins || wanted real || { wanted mutants && [ "$MUTANTS" -eq 1 ]; }; then
  [ "$LINUX" -eq 1 ] && setup_standins
fi

if wanted standins; then
  echo "--- standins: network logic against stand-in clients (no network)"
  if [ "$LINUX" -eq 0 ]; then
    skip "the stand-in network tests run on Linux only ($(uname -s)): the bash checker refuses other platforms"
  else
    for t in t_client_accepting_the_emsign_path_fails t_client_accepting_only_the_aaa_path_fails t_client_rejecting_every_chain_passes \
      t_node_bundled_roots_are_read_offline t_writes_nothing_to_home_or_cwd t_curlrc_is_never_read t_curl_bypasses_proxies \
      t_git_credentials_are_never_offered t_git_extra_headers_are_dropped t_git_never_follows_redirects t_git_sends_the_fixed_user_agent \
      t_git_bypasses_configured_proxies t_paths_are_confirmed_before_a_result_counts t_only_the_pack_hosts_are_contacted \
      t_current_tool_versions_pass t_old_tool_versions_fail t_tool_version_compare_is_numeric t_a_filtering_proxy_cannot_turn_fail_into_pass \
      t_client_that_trusts_nothing_is_unknown t_offline_client_is_unknown_not_pass t_unreachable_test_host_is_unknown_even_when_the_other_refuses \
      t_a_reset_during_the_handshake_is_unknown_not_pass t_test_site_without_a_listed_key_is_unknown t_test_site_with_an_expired_leaf_is_unknown \
      t_test_site_with_a_leaf_for_another_name_is_unknown t_test_site_whose_leaf_name_only_starts_with_the_host_is_unknown \
      t_unreachable_test_site_is_unknown t_an_intercepted_test_site_is_never_read_as_fail t_insecure_env_fails t_offline_mode_contacts_nothing \
      t_a_bundle_named_by_ssl_cert_file_is_checked t_fix_hints_name_the_packs_fixed_versions t_three_paths_all_refused_pass \
      t_three_paths_an_open_later_path_fails t_three_paths_one_unconfirmed_is_unknown t_a_pack_without_fixed_versions_still_gives_a_fix; do check "$t"; done
  fi
fi

if wanted real; then
  echo "--- real: curl, git, python3 and node against local test servers on 8191-8194"
  if [ "$LINUX" -eq 0 ]; then
    skip "the real-client tests run on Linux only ($(uname -s))"
  elif ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is needed to run the local test servers"
  else
    run_real_group
  fi
fi

if wanted powershell; then
  echo "--- powershell: bundle mode, packs, environment"
  if [ -z "$PSHELLS" ]; then
    skip "no pwsh or powershell.exe on PATH"
  else
    for PSHELL in $PSHELLS; do
      for t in $PS_TESTS; do
        WHY=""
        if "$t"; then ok "$PSHELL: ${t#t_ps_}"; else no "$PSHELL: ${t#t_ps_}${WHY:+ - $WHY}"; printf '%s\n' "$OUT" | sed 's/^/        | /'; fi
      done
    done
  fi
fi

if wanted mutants && [ "$MUTANTS" -eq 1 ]; then
  echo "--- mutants: each deliberate breakage must be caught by a named test"
  run_mutants
fi

echo
echo "=== $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
