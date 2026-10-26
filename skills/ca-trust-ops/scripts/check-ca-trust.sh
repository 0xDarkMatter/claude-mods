#!/usr/bin/env bash
# Read-only check of this Mac or Linux machine (WSL included) against a CA distrust event.
#
# Usage:   check-ca-trust.sh --incident NAME [--offline] [--scan DIR]... [--bundle FILE]...
#          check-ca-trust.sh --list
# Input:   argv only. NAME names ../assets/incidents/NAME.conf (see --list).
# Output:  one line per check, `STATUS id detail[ - fix: step]`, STATUS = PASS|FAIL|UNKNOWN,
#          then `RESULT  ca-trust-ops 1 <incident> <platform> <date>: <verdict> (<n> pass,
#          <n> fail, <n> unknown)`. --list prints `<id>  <as_of>  <title>` per pack.
# Stderr:  usage and incident-pack errors only.
# Exit:    0 every line PASS, 10 any FAIL, 11 no FAIL but an UNKNOWN, 2 usage,
#          3 no such incident pack, 4 malformed incident pack
#
# Examples:
#   bash check-ca-trust.sh --list
#   bash check-ca-trust.sh --incident emudhra-2026-10
#   bash check-ca-trust.sh --incident emudhra-2026-10 --bundle ./image-ca-certificates.crt
#
# Contract (the reasons, and the landmines, are in ../AGENTS.md):
#   - Read-only: writes no file, runs no sudo, pipes nothing into a shell. No here-documents
#     or here-strings anywhere: bash before 5.1 backs both with temporary files.
#   - Network: only the pack's control and path hosts, direct (no proxy, no redirect), curl
#     with -q, git with no credential helper, extra header or cookie file, a fixed User-Agent.
#   - A client's refusal is PASS only when (1) the same client opened the control page,
#     (2) this script's own handshake saw a listed key in the chain, on a current leaf that
#     names the host, and (3) the client's error was a certificate error. Else UNKNOWN.
#   - Runs under macOS bash 3.2: no associative arrays or mapfile, `${1+"$@"}` for a list
#     that may be empty, arrays walked by index (never "${a[@]}"), no `timeout` command.
#
# Sections: SETUP, OUTPUT, INCIDENT PACK, BUNDLES, PATH CONFIRMATION, CLIENT PROBES,
#           SHARED CHECKS, MACOS, LINUX, MAIN.
# One file on purpose: every file write, process and network call it can make is reviewable
# in one place against the contract above, and a script sourcing helpers by relative path
# under bash 3.2 adds ways to break. It reads only its incident pack beside it.
set -u
set -o pipefail

# === SETUP ===

# Cleared for the whole run: SSLKEYLOGFILE and git's trace variables would make a probe
# write files or log headers, and a proxy would give a probe a different route from the
# path-confirming handshake, so a proxy's block page could read as a client's refusal.
unset SSLKEYLOGFILE GIT_TRACE GIT_TRACE_CURL GIT_TRACE_PACKET GIT_TRACE_SETUP GIT_CURL_VERBOSE GIT_HTTP_USER_AGENT 2>/dev/null
unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY NODE_USE_ENV_PROXY 2>/dev/null

readonly TOOL="ca-trust-ops 1"
# One fixed User-Agent for every probe: disclosure sites count connections per User-Agent,
# and nothing about the user's own tools should ride along. PY_PROBE and NODE_PROBE repeat it.
readonly AGENT="ca-trust-ops/1"
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACK_DIR="$SELF_DIR/../assets/incidents"
TAB=$(printf '\t')

# urllib with no proxy and no redirect. "rejected" only for a certificate-verification
# error whose OpenSSL verify code means "untrusted issuer or revoked" (2 unable to get
# issuer, 19/20/21 self-signed or unknown issuer, 23 revoked, 27/28 untrusted or rejected):
# an expired or wrong-name leaf is a different code and must not read as a refusal.
readonly PY_PROBE='import ssl, sys, urllib.request, urllib.error
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
bad = getattr(ssl, "SSLCertVerificationError", ssl.SSLError)
trust = (2, 19, 20, 21, 23, 27, 28)
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "ca-trust-ops/1"})
try:
    urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(req, timeout=20).close()
    print("connected")
except urllib.error.HTTPError:
    print("connected")
except Exception as e:
    x = e if isinstance(e, bad) else getattr(e, "reason", None)
    print("rejected" if isinstance(x, bad) and getattr(x, "verify_code", None) in trust else "neterr")'

# Node's https module ignores proxy variables unless NODE_USE_ENV_PROXY is set (cleared
# above). Same rule as PY_PROBE: only an untrusted-issuer or revoked code is a refusal.
readonly NODE_PROBE='const trust = /^(UNABLE_TO_GET_ISSUER_CERT|UNABLE_TO_GET_ISSUER_CERT_LOCALLY|SELF_SIGNED_CERT_IN_CHAIN|UNABLE_TO_VERIFY_LEAF_SIGNATURE|CERT_UNTRUSTED|CERT_REJECTED|CERT_REVOKED)$/;
const req = require("https").get(process.argv[1], {headers: {"user-agent": "ca-trust-ops/1"}, timeout: 20000}, (res) => { console.log("connected"); res.destroy(); process.exit(0); });
req.on("timeout", () => { console.log("neterr"); process.exit(0); });
req.on("error", (e) => { console.log(trust.test(String(e.code || "")) ? "rejected" : "neterr"); process.exit(0); });'

PASSES=0
FAILS=0
UNKNOWNS=0
OFFLINE=0
HELP=0
LIST=0
INCIDENT=""
BUNDLES=""
SCANS=""
PLATFORM=""
SEEN_CONTENT=""
CHECKED=""
CLT=1
BREW=""
PYTHONS=""

# === OUTPUT ===

usage() {
  printf '%s\n' \
    "Usage: check-ca-trust.sh --incident NAME [--offline] [--scan DIR]... [--bundle FILE]..." \
    "       check-ca-trust.sh --list" \
    "" \
    "Read-only check of this Mac or Linux machine (WSL included) against a CA distrust" \
    "event: does any client or CA bundle here still trust a chain built on the incident's" \
    "listed keys? Each line reads PASS, FAIL or UNKNOWN; a FAIL or UNKNOWN line ends with a" \
    "one-line fix. The last line, RESULT, holds no host, user or path: it is the line to" \
    "share. On Windows, run check-ca-trust.ps1 instead." \
    "" \
    "  --incident NAME  the incident pack to check against (required; see --list)" \
    "  --list           list the incident packs this copy carries" \
    "  --offline        skip the network tests (the result is then UNKNOWN at best)" \
    "  --scan DIR       also look for Python certifi bundles under DIR (repeatable)" \
    "  --bundle FILE    check only these CA bundle files, offline (repeatable)" \
    "  -h, --help       print this text (with --incident, also that pack's hosts)" \
    "" \
    "It contacts only the hosts its incident pack names, changes nothing, needs no admin" \
    "rights and writes only to stdout." \
    "" \
    "EXAMPLES" \
    "  bash check-ca-trust.sh --list" \
    "  bash check-ca-trust.sh --incident emudhra-2026-10" \
    "  bash check-ca-trust.sh --incident emudhra-2026-10 --scan ~/code" \
    "  bash check-ca-trust.sh --incident emudhra-2026-10 --bundle ./image-ca-certificates.crt" \
    "" \
    "Exit: 0 every line PASS, 10 any FAIL, 11 no FAIL but an UNKNOWN, 2 usage error," \
    "3 no such incident pack, 4 malformed incident pack."
}

usage_error() {
  printf 'check-ca-trust: %s\n' "$1" >&2
  printf '%s\n' "Run with --help for usage." >&2
  exit 2
}

# Paths under the home folder print as ~, so a pasted line names no user.
tidy() {
  local text=$1 tilde='~'
  if [ -n "${HOME:-}" ] && [ "$HOME" != / ]; then
    text=${text//"$HOME"/$tilde}
  fi
  printf '%s' "$text"
}

report() {
  local status=$1 id=$2 detail fix=${4:-}
  detail=$(tidy "$3")
  case $status in
    PASS) PASSES=$((PASSES + 1)) ;;
    FAIL) FAILS=$((FAILS + 1)) ;;
    *) UNKNOWNS=$((UNKNOWNS + 1)) ;;
  esac
  if [ "$status" != PASS ] && [ -n "$fix" ]; then
    printf '%-7s %-22s %s - fix: %s\n' "$status" "$id" "$detail" "$(tidy "$fix")"
  else
    printf '%-7s %-22s %s\n' "$status" "$id" "$detail"
  fi
}

# The RESULT line is what people paste into a thread to sign a machine off: it carries no
# host, user or path, and its fields stay in this order (tests/run.sh pins the format).
finish() {
  local verdict=PASS code=0
  if [ "$FAILS" -gt 0 ]; then
    verdict=FAIL code=10
  elif [ "$UNKNOWNS" -gt 0 ]; then
    verdict=UNKNOWN code=11
  fi
  printf 'RESULT  %s %s %s %s: %s (%d pass, %d fail, %d unknown)\n' "$TOOL" "$PACK_ID" "${PLATFORM:-bundles}" "$(date +%Y-%m-%d)" "$verdict" "$PASSES" "$FAILS" "$UNKNOWNS"
  exit "$code"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Stands in for `timeout`, which macOS lacks.
with_timeout() {
  local secs=$1 pid watcher rc
  shift
  "$@" &
  pid=$!
  (sleep "$secs"; kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid"
  rc=$?
  kill "$watcher" 2>/dev/null
  return "$rc"
}

# === INCIDENT PACK ===
# Format and field rules: ../references/incident-packs.md. Everything a pack says is
# validated here, because hosts and commands from it reach the network and the PATH.

PACK_FILE=""
PACK_ID=""
NAME=""
TITLE=""
AS_OF=""
CONTROL_HOST=""
CONTROL_PORT=443
CONTROL_URL=""
LISTED=""
LISTED_KEYS="|"
SPKIS=""
KEY_COUNT=0
TP_COUNT=0
VER_COUNT=0
FIXED_NODE=""
FIXED_PYTHON=""
FIXED_CERTIFI=""
FIXED_PIP=""
TP_LABEL=()
TP_HOST=()
TP_PORT=()
TP_URL=()
TP_STATE=()
VER_ID=()
VER_CMD=()
VER_LABEL=()
VER_MIN=()
VER_FIX=()

pack_names() {
  local f names=""
  for f in "$PACK_DIR"/*.conf; do
    [ -f "$f" ] || continue
    f=${f##*/}
    names="${names:+$names, }${f%.conf}"
  done
  printf '%s' "${names:-none}"
}

list_packs() {
  local f found=0 kind a rest id title as_of
  for f in "$PACK_DIR"/*.conf; do
    [ -f "$f" ] || continue
    found=1
    id="" title="" as_of=""
    while IFS='|' read -r kind a rest || [ -n "$kind" ]; do
      a=${a%$'\r'}
      case $kind in
        id) id=$a ;;
        title) title=$a ;;
        as_of) as_of=$a ;;
      esac
    done <"$f"
    printf '%s  %s  %s\n' "${id:-?}" "${as_of:-?}" "${title:-?}"
  done
  if [ "$found" -eq 0 ]; then
    printf 'check-ca-trust: no incident packs in %s\n' "$PACK_DIR" >&2
    exit 3
  fi
}

pack_error() {
  printf 'check-ca-trust: %s: %s\n' "$PACK_FILE" "$1" >&2
  exit 4
}

# A host is lowercase letters, digits, dots and hyphens, with at least one dot: nothing
# that could carry a path, port, credential or second URL into a probe's command line.
valid_host() {
  case $1 in
    "" | .* | *. | -* | *- | *..* | *[!a-z0-9.-]*) return 1 ;;
    *.*) return 0 ;;
  esac
  return 1
}

# Reads the fields of the record being parsed (kind, a..e, rest are load_pack's locals).
only_fields() {
  local tail=""
  case $1 in
    1) tail=$b$c$d$e$rest ;;
    2) tail=$c$d$e$rest ;;
    3) tail=$d$e$rest ;;
    5) tail=$rest ;;
  esac
  [ -z "$tail" ] || pack_error "line $n: '$kind' takes $1 field(s) after its type"
}

load_pack() {
  local kind a b c d e rest n=0 i
  while IFS='|' read -r kind a b c d e rest || [ -n "$kind" ]; do
    n=$((n + 1))
    kind=${kind%$'\r'} a=${a%$'\r'} b=${b%$'\r'} c=${c%$'\r'} d=${d%$'\r'} e=${e%$'\r'} rest=${rest%$'\r'}
    case $kind in
      '#'*) continue ;;
      "") [ -z "$a$b$c$d$e$rest" ] && continue; pack_error "line $n: a record starts with its type" ;;
    esac
    case $kind in
      id | name | title | reference)
        only_fields 1
        [ -n "$a" ] || pack_error "line $n: '$kind' is empty"
        case $kind in
          id) PACK_ID=$a ;;
          name) NAME=$a ;;
          title) TITLE=$a ;;
        esac
        ;;
      as_of)
        only_fields 1
        case $a in
          [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) AS_OF=$a ;;
          *) pack_error "line $n: as_of must be YYYY-MM-DD" ;;
        esac
        ;;
      key)
        only_fields 3
        case $a in *[!0-9A-F]*) pack_error "line $n: a key is 64 upper-case hex digits (SPKI SHA-256)" ;; esac
        [ "${#a}" -eq 64 ] || pack_error "line $n: a key is 64 upper-case hex digits (SPKI SHA-256)"
        [ -n "$b" ] || pack_error "line $n: a key needs the name of its certificate"
        case $c in "" | *[!A-Za-z0-9+/=]*) pack_error "line $n: a key needs its SPKI in base64 (scripts/pack-keys.sh prints it)" ;; esac
        case $LISTED_KEYS in *"|$a|"*) pack_error "line $n: key $a is listed twice" ;; esac
        LISTED="$LISTED$a|$b
"
        LISTED_KEYS="$LISTED_KEYS$a|"
        SPKIS="$SPKIS$a|$c
"
        KEY_COUNT=$((KEY_COUNT + 1))
        ;;
      control)
        only_fields 1
        valid_host "$a" || pack_error "line $n: '$a' is not a host name"
        CONTROL_HOST=$a
        ;;
      path)
        only_fields 2
        case $a in "" | *[!A-Za-z0-9._\ -]*) pack_error "line $n: a path label is letters, digits, spaces, dots, hyphens" ;; esac
        valid_host "$b" || pack_error "line $n: '$b' is not a host name"
        i=0
        while [ "$i" -lt "$TP_COUNT" ]; do
          [ "${TP_LABEL[$i]}" != "$a" ] && [ "${TP_HOST[$i]}" != "$b" ] || pack_error "line $n: path '$a' repeats a label or host"
          i=$((i + 1))
        done
        TP_LABEL[$TP_COUNT]=$a
        TP_HOST[$TP_COUNT]=$b
        TP_PORT[$TP_COUNT]=443
        TP_COUNT=$((TP_COUNT + 1))
        ;;
      version)
        only_fields 5
        case $a in "" | *[!a-z0-9-]*) pack_error "line $n: a version id is lower-case letters, digits, hyphens" ;; esac
        case $b in "" | -* | *[!A-Za-z0-9._-]*) pack_error "line $n: '$b' is not a command name" ;; esac
        [ -n "$c" ] && [ -n "$e" ] || pack_error "line $n: a version record needs a label and a fix"
        case $d in
          *[!0-9.]* | .* | *. | *..* | *.*.*.*) pack_error "line $n: a minimum version is N.N.N" ;;
          *.*.*) ;;
          *) pack_error "line $n: a minimum version is N.N.N" ;;
        esac
        VER_ID[$VER_COUNT]=$a
        VER_CMD[$VER_COUNT]=$b
        VER_LABEL[$VER_COUNT]=$c
        VER_MIN[$VER_COUNT]=$d
        VER_FIX[$VER_COUNT]=$e
        VER_COUNT=$((VER_COUNT + 1))
        ;;
      fixed)
        only_fields 2
        [ -n "$b" ] || pack_error "line $n: 'fixed' needs the first fixed versions"
        # The PowerShell checker uses the other two slots.
        case $a in
          node) FIXED_NODE=$b ;;
          python) FIXED_PYTHON=$b ;;
          certifi) FIXED_CERTIFI=$b ;;
          pip) FIXED_PIP=$b ;;
          git-for-windows | composer-ca-bundle) ;;
          *) pack_error "line $n: unknown 'fixed' slot '$a'" ;;
        esac
        ;;
      *) pack_error "line $n: unknown record type '$kind'" ;;
    esac
  done <"$PACK_FILE"
  [ "$PACK_ID" = "$INCIDENT" ] || pack_error "its id is '$PACK_ID', not the file name '$INCIDENT'"
  [ -n "$NAME" ] && [ -n "$TITLE" ] && [ -n "$AS_OF" ] || pack_error "it needs a name, a title and an as_of date"
  [ "$KEY_COUNT" -gt 0 ] || pack_error "it lists no key"
  [ -n "$CONTROL_HOST" ] || pack_error "it names no control host"
  [ "$TP_COUNT" -gt 0 ] || pack_error "it names no trust path"
  i=0
  while [ "$i" -lt "$TP_COUNT" ]; do
    [ "${TP_HOST[$i]}" != "$CONTROL_HOST" ] || pack_error "the control host is also a path host"
    i=$((i + 1))
  done
  # An SPKI the scanner cannot take apart would give it no needle, so its key could never
  # be found: refuse the pack rather than scan blind.
  case $(LC_ALL=C CA_TRUST_SPKIS="$SPKIS" awk "$SCAN_AWK" </dev/null) in
    *BADSPKI*) pack_error "a key's SPKI is not a SubjectPublicKeyInfo (scripts/pack-keys.sh prints it)" ;;
  esac
}

# Test hook for tests/run.sh: CA_TRUST_LOCAL_PORTS=<control>,<one port per path> sends every
# probe and handshake to localhost on those ports. Digits and commas only, and it always
# means localhost, so it cannot point the checker at any other host. Keep it that way.
apply_local_ports() {
  local spec=${CA_TRUST_LOCAL_PORTS:-} rest i=0
  [ -n "$spec" ] || return 0
  case $spec in
    *[!0-9,]* | ,* | *, | *,,*) usage_error "CA_TRUST_LOCAL_PORTS takes <control>,<one port per path>: digits and commas" ;;
  esac
  rest="$spec,"
  CONTROL_HOST=localhost
  CONTROL_PORT=${rest%%,*}
  rest=${rest#*,}
  while [ "$i" -lt "$TP_COUNT" ]; do
    [ -n "$rest" ] || usage_error "CA_TRUST_LOCAL_PORTS needs one port per trust path ($TP_COUNT)"
    TP_HOST[$i]=localhost
    TP_PORT[$i]=${rest%%,*}
    rest=${rest#*,}
    i=$((i + 1))
  done
  [ -z "$rest" ] || usage_error "CA_TRUST_LOCAL_PORTS has more ports than trust paths ($TP_COUNT)"
}

url_of() {
  if [ "$2" = 443 ]; then printf 'https://%s/' "$1"; else printf 'https://%s:%s/' "$1" "$2"; fi
}

set_urls() {
  local i=0
  CONTROL_URL=$(url_of "$CONTROL_HOST" "$CONTROL_PORT")
  while [ "$i" -lt "$TP_COUNT" ]; do
    TP_URL[$i]=$(url_of "${TP_HOST[$i]}" "${TP_PORT[$i]}")
    i=$((i + 1))
  done
}

print_hosts() {
  local i=0
  printf '\n%s\n' "Hosts for $PACK_ID ($TITLE, as of $AS_OF):"
  printf '  control  %s\n' "$CONTROL_URL"
  while [ "$i" -lt "$TP_COUNT" ]; do
    printf '  %-8s %s\n' "${TP_LABEL[$i]}" "${TP_URL[$i]}"
    i=$((i + 1))
  done
}

# An upgrade target for a fix hint: the pack's first fixed versions when it names them.
upgrade_hint() {
  if [ -n "$2" ]; then printf '%s to %s or later' "$1" "$2"; else printf '%s to a release with the %s fix' "$1" "$NAME"; fi
}

# === BUNDLES ===
# A bundle is judged by the SHA-256 of each certificate's SubjectPublicKeyInfo, so a
# cross-signed or re-issued certificate on a listed key is caught like the original.

EMPTY_SHA256=""

spki_of() {
  openssl x509 -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print toupper($NF)}'
}

listed_name() {
  printf '%s' "$LISTED" | awk -F'|' -v k="$1" '$1 == k { print $2; exit }'
}

add_hit() {
  case "; $SCAN_HITS;" in
    *"; $1;"*) ;;
    *) SCAN_HITS="${SCAN_HITS:+$SCAN_HITS; }$1" ;;
  esac
}

# The bundle prefilter: one awk pass per bundle, where hashing every certificate took three
# openssl start-ups each (5 s for a 120-certificate bundle). A certificate's DER holds its
# public key's bytes verbatim at some offset k, so its base64 holds the base64 of those
# bytes from offset (3 - k % 3) % 3 on: three "needles" per listed key, one per alignment,
# built here from the pack's SPKI (the subjectPublicKey BIT STRING after its unused-bits
# byte, RFC 5280 section 4.1). A certificate holding a needle is only a candidate:
# scan_stream hashes its key with openssl, so a hit still means "SPKI SHA-256 equals a
# listed key". Prints each candidate's PEM after a CANDIDATE line, then TOTAL and BAD
# counts; a block that is not base64 DER ("MI...") counts as BAD. BADSPKI <hash> means a
# pack SPKI could not be parsed (load_pack refuses the pack). POSIX awk only (macOS, mawk).
readonly SCAN_AWK='
function decode(s,   i, c, acc, bits, n) {
  n = 0; acc = 0; bits = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "=") break
    acc = acc * 64 + val[c]; bits += 6
    if (bits >= 8) { bits -= 8; byte[n++] = int(acc / 2 ^ bits); acc = acc % (2 ^ bits) }
  }
  return n
}
function tlv(p,   l, k, i) {
  l = byte[p + 1]
  if (l < 128) { hlen = 2; clen = l; return }
  k = l - 128; clen = 0
  for (i = 0; i < k; i++) clen = clen * 256 + byte[p + 2 + i]
  hlen = 2 + k
}
function encode(from, to,   i, v, out) {
  out = ""
  for (i = from; i + 2 < to; i += 3) {
    v = byte[i] * 65536 + byte[i + 1] * 256 + byte[i + 2]
    out = out substr(b64, int(v / 262144) + 1, 1) substr(b64, int(v / 4096) % 64 + 1, 1) substr(b64, int(v / 64) % 64 + 1, 1) substr(b64, v % 64 + 1, 1)
  }
  return out
}
BEGIN {
  b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for (i = 0; i < 64; i++) val[substr(b64, i + 1, 1)] = i
  rows = split(ENVIRON["CA_TRUST_SPKIS"], row, "\n")
  for (r = 1; r <= rows; r++) {
    if (split(row[r], f, "|") != 2) continue
    len = decode(f[2]); ok = 0
    if (len > 4 && byte[0] == 48) {
      tlv(0); p = hlen
      if (byte[p] == 48) {
        tlv(p); p += hlen + clen
        if (byte[p] == 3) { tlv(p); start = p + hlen + 1; stop = p + hlen + clen; ok = (stop <= len && stop - start >= 16) }
      }
    }
    if (!ok) { print "BADSPKI " f[1]; continue }
    for (s = 0; s < 3; s++) needle[++n] = encode(start + s, start + s + 3 * int((stop - start - s) / 3))
  }
}
{ sub(/\r$/, "") }
/^-----BEGIN (TRUSTED )?CERTIFICATE-----$/ { inside = 1; body = ""; pem = $0; next }
/^-----END (TRUSTED )?CERTIFICATE-----$/ {
  if (!inside) next
  inside = 0; total++; pem = pem "\n" $0
  if (length(body) % 4 != 0 || body !~ "^MI[A-Za-z0-9+/]*=*$") { bad++; next }
  for (i = 1; i <= n; i++) if (index(body, needle[i])) { print "CANDIDATE"; print pem; break }
  next
}
inside { gsub(/[ \t]/, ""); body = body $0; pem = pem "\n" $0 }
END { print "TOTAL " total + 0; print "BAD " bad + 0 }
'

confirm_candidate() {
  local key
  # Computed on first use: a clean bundle has no candidate and needs no extra openssl run.
  [ -n "$EMPTY_SHA256" ] || EMPTY_SHA256=$(printf '' | openssl dgst -sha256 2>/dev/null | awk '{print toupper($NF)}')
  if ! key=$(printf '%s\n' "$1" | spki_of); then
    SCAN_BAD=$((SCAN_BAD + 1))
    return
  fi
  case $key in
    "" | "$EMPTY_SHA256") SCAN_BAD=$((SCAN_BAD + 1)); return ;;
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F]*) ;;
    *) SCAN_BAD=$((SCAN_BAD + 1)); return ;;
  esac
  case $LISTED_KEYS in
    *"|$key|"*) add_hit "$(listed_name "$key")" ;;
  esac
}

# Reads a PEM bundle on stdin. Sets SCAN_TOTAL, SCAN_BAD (blocks that are not certificates,
# or candidates openssl could not hash) and SCAN_HITS (the listed names found). A
# certificate that cannot be read is counted, never skipped: a bundle of unreadable
# certificates must not read as one with no listed key.
scan_stream() {
  local out line pem="" collecting=0
  SCAN_TOTAL=0
  SCAN_BAD=0
  SCAN_HITS=""
  # An awk that dies part-way leaves SCAN_TOTAL at 0, which judge_scan reports as UNKNOWN.
  out=$(LC_ALL=C CA_TRUST_SPKIS="$SPKIS" awk "$SCAN_AWK") || return 0
  while IFS= read -r line; do
    case $line in
      CANDIDATE) collecting=1; pem="" ;;
      "TOTAL "*) SCAN_TOTAL=${line#TOTAL } ;;
      "BAD "*) SCAN_BAD=$((SCAN_BAD + ${line#BAD })) ;;
      *)
        [ "$collecting" -eq 1 ] || continue
        pem="${pem:+$pem
}$line"
        case $line in
          "-----END CERTIFICATE-----" | "-----END TRUSTED CERTIFICATE-----") collecting=0; confirm_candidate "$pem" ;;
        esac
        ;;
    esac
  # procsub ok: printf of a variable cannot stop early
  done < <(printf '%s\n' "$out")
}

judge_scan() {
  local id=$1 what=$2 fix=$3
  if [ "$SCAN_TOTAL" -eq 0 ]; then
    report UNKNOWN "$id" "no certificates could be read from $what" "check that it is a PEM bundle"
  elif [ -n "$SCAN_HITS" ]; then
    report FAIL "$id" "$what trusts $SCAN_HITS" "$fix"
  elif [ "$SCAN_BAD" -gt 0 ]; then
    report UNKNOWN "$id" "$what: $SCAN_BAD of $SCAN_TOTAL certificates could not be read" "check the file with: openssl crl2pkcs7 -nocrl -certfile <file>"
  else
    report PASS "$id" "$what: none of the $KEY_COUNT listed keys in $SCAN_TOTAL certificates"
  fi
}

real_path() {
  readlink -f "$1" 2>/dev/null || printf '%s' "$1"
}

check_bundle() {
  local id=$1 file=$2 fix=$3 sum cached
  if ! have openssl; then
    report UNKNOWN "$id" "cannot read $file without openssl" "install openssl, then re-run"
    return
  fi
  if [ ! -e "$file" ]; then
    report UNKNOWN "$id" "$file does not exist" "point it at a CA bundle that exists"
    return
  fi
  if [ ! -r "$file" ]; then
    report UNKNOWN "$id" "$file cannot be read" "re-run as a user who can read it"
    return
  fi
  CHECKED="$CHECKED|$(real_path "$file")|"
  # Identical content (a symlinked or copied bundle) is scanned once per run.
  sum=$(openssl dgst -sha256 <"$file" 2>/dev/null | awk '{print $NF}')
  cached=$(printf '%s\n' "$SEEN_CONTENT" | awk -F'\t' -v s="$sum" '$1 == s { print $2 "\t" $3 "\t" $4; exit }')
  if [ -n "$sum" ] && [ -n "$cached" ]; then
    SCAN_TOTAL=$(printf '%s' "$cached" | cut -f1)
    SCAN_BAD=$(printf '%s' "$cached" | cut -f2)
    SCAN_HITS=$(printf '%s' "$cached" | cut -f3)
  else
    scan_stream <"$file"
    SEEN_CONTENT="$SEEN_CONTENT
$sum$TAB$SCAN_TOTAL$TAB$SCAN_BAD$TAB$SCAN_HITS"
  fi
  judge_scan "$id" "$file" "$fix"
}

# === PATH CONFIRMATION ===
# Before any client's refusal counts, this script makes its own handshake with each path
# host and requires a listed key in the presented chain, on a current leaf that names the
# host. A DNS filter, block page, intercepting proxy, reset or expired leaf all make a
# client fail to connect, which would otherwise read as a safe refusal.

epoch_of() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%b %e %T %Y %Z' "$1" +%s 2>/dev/null
}

# The leaf's DNS names as ", DNS:a, DNS:b," so a match is on whole names: a name that only
# starts with the host (host.example.invalid) is not the host.
leaf_names() {
  local sans
  sans=$(printf '%s\n' "$1" | openssl x509 -noout -text 2>/dev/null | awk '/X509v3 Subject Alternative Name/ { getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }')
  printf ', %s,' "$sans"
}

path_state() {
  local host=$1 port=$2 chain leaf start now
  have openssl || { echo "openssl is not installed"; return; }
  chain=$(with_timeout 20 openssl s_client -connect "$host:$port" -servername "$host" -showcerts </dev/null 2>/dev/null)
  leaf=$(printf '%s\n' "$chain" | awk '/-----BEGIN CERTIFICATE-----/ { on = 1 } on { print } /-----END CERTIFICATE-----/ { exit }')
  [ -n "$leaf" ] || { echo "it could not be reached"; return; }
  # procsub ok: printf of a variable cannot stop early
  scan_stream < <(printf '%s\n' "$chain")
  [ -n "$SCAN_HITS" ] || { echo "it did not present a chain with a listed key, so a proxy or filter may be in the way"; return; }
  printf '%s\n' "$leaf" | openssl x509 -noout -checkend 0 >/dev/null 2>&1 || { echo "its certificate has expired"; return; }
  start=$(printf '%s\n' "$leaf" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)
  start=$(epoch_of "$start")
  now=$(date -u +%s)
  if [ -n "$start" ] && [ "$start" -gt "$now" ]; then
    echo "its certificate is not valid yet, so this machine's clock may be wrong"
    return
  fi
  case $(leaf_names "$leaf") in
    *", DNS:$host,"* | *", DNS:*.${host#*.},"*) echo ok ;;
    *) echo "its certificate does not name $host" ;;
  esac
}

PATHS_CONFIRMED=0
confirm_paths() {
  local i=0
  [ "$PATHS_CONFIRMED" -eq 1 ] && return
  while [ "$i" -lt "$TP_COUNT" ]; do
    TP_STATE[$i]=$(path_state "${TP_HOST[$i]}" "${TP_PORT[$i]}")
    i=$((i + 1))
  done
  PATHS_CONFIRMED=1
}

# === CLIENT PROBES ===
# Each probe prints connected, rejected (a certificate error), cafail (curl could not
# read its CA file) or neterr (anything else), and goes direct to one URL.

probe_curl() {
  local bin=$1 url=$2 err rc
  err=$("$bin" -q -sS --noproxy '*' -o /dev/null --max-time 20 -A "$AGENT" "$url" 2>&1 >/dev/null)
  rc=$?
  case $rc in
    0) echo connected ;;
    51 | 60) echo rejected ;;
    # 35 is any TLS handshake failure, a reset included: a refusal only when the message
    # says revoked or untrusted root (Schannel builds report distrust this way).
    35)
      case $err in
        *[Rr]evok* | *CRYPT_E_REVOKED* | *SEC_E_UNTRUSTED_ROOT* | *CERT_E_UNTRUSTEDROOT*) echo rejected ;;
        *) echo neterr ;;
      esac
      ;;
    77) echo cafail ;;
    *) echo neterr ;;
  esac
}

probe_git() {
  local bin=$1 url=$2 out
  out=$(env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 "$bin" -c credential.helper= -c http.extraHeader= -c http.cookieFile= \
    -c core.askPass= -c http.proxy= -c http.followRedirects=false -c "http.userAgent=$AGENT" -c http.lowSpeedLimit=1 -c http.lowSpeedTime=20 \
    ls-remote --heads "$url" 2>&1)
  if [ $? -eq 0 ]; then
    echo connected
    return
  fi
  # Order matters: an untrusted-issuer message is a refusal, any other TLS message is not,
  # and an HTTP-level error (no repository there) means the TLS handshake succeeded.
  case $out in
    *"local issuer"* | *"issuer certificate"* | *"self-signed certificate in"* | *"self signed certificate in"* | \
      *"certificate verification failed"* | *"unable to verify the first"* | *[Rr]evok* | *REVOKED* | *UNTRUSTED* | *"not trusted"*) echo rejected ;;
    *[Cc]ertificate* | *SSL* | *TLS* | *schannel*) echo neterr ;;
    *"not found"* | *"not valid"* | *"returned error"* | *"Authentication failed"* | *"git repository"* | *"dumb http"* | *redirect*) echo connected ;;
    *) echo neterr ;;
  esac
}

# python -I ignores PYTHON* variables and the user site, so a stray PYTHONHTTPSVERIFY or a
# sitecustomize cannot change the probe.
probe_python() {
  local out
  out=$("$1" -I -c "$PY_PROBE" "$2" 2>/dev/null | tail -n 1)
  case $out in connected | rejected) echo "$out" ;; *) echo neterr ;; esac
}

probe_node() {
  local out
  out=$("$1" -e "$NODE_PROBE" "$2" 2>/dev/null | tail -n 1)
  case $out in connected | rejected) echo "$out" ;; *) echo neterr ;; esac
}

# check_client ID LABEL FIX PROBE ARGS...: probes the control page, then each trust path.
check_client() {
  local id=$1 label=$2 fix=$3 control result i=0 open="" why="" seen="" names="" all_rejected=1
  shift 3
  [ "$OFFLINE" -eq 1 ] && return
  confirm_paths
  control=$("$@" "$CONTROL_URL")
  [ "$control" = neterr ] && control=$("$@" "$CONTROL_URL")
  if [ "$control" != connected ]; then
    case $control in
      cafail) report UNKNOWN "$id" "$label cannot read its CA bundle, so it trusts nothing" "point it at a bundle that exists" ;;
      *) report UNKNOWN "$id" "$label could not open the control page ($control), so its tests would prove nothing" "re-run on a network that allows HTTPS to $CONTROL_HOST" ;;
    esac
    return
  fi
  while [ "$i" -lt "$TP_COUNT" ]; do
    names="${names:+$names, }${TP_LABEL[$i]}"
    if [ "${TP_STATE[$i]}" = ok ]; then
      result=$("$@" "${TP_URL[$i]}")
    else
      # Not probed: without a confirmed chain neither a refusal nor a connection means anything.
      result=unconfirmed
      why="${why:+$why; }the ${TP_LABEL[$i]} test site: ${TP_STATE[$i]}"
    fi
    [ "$result" = connected ] && open="${open:+$open and }${TP_LABEL[$i]} path"
    [ "$result" = rejected ] || all_rejected=0
    seen="${seen:+$seen, }${TP_LABEL[$i]} test $result"
    i=$((i + 1))
  done
  if [ -n "$open" ]; then
    report FAIL "$id" "$label accepts a certificate chained to a listed $NAME key ($open)" "$fix"
  elif [ "$all_rejected" -eq 1 ]; then
    report PASS "$id" "$label rejects every test chain ($names)"
  elif [ -n "$why" ]; then
    report UNKNOWN "$id" "$label could not be tested: $why" "re-run on another network, without a VPN, proxy or DNS filter"
  else
    report UNKNOWN "$id" "$label: $seen" "re-run; if it repeats, open ${TP_URL[0]} with $label by hand"
  fi
}

# === SHARED CHECKS ===

check_tls_env() {
  local bad=""
  [ "$(printenv NODE_TLS_REJECT_UNAUTHORIZED 2>/dev/null)" = 0 ] && bad="NODE_TLS_REJECT_UNAUTHORIZED=0"
  [ "$(printenv PYTHONHTTPSVERIFY 2>/dev/null)" = 0 ] && bad="${bad:+$bad, }PYTHONHTTPSVERIFY=0"
  [ -n "$(printenv GIT_SSL_NO_VERIFY 2>/dev/null)" ] && bad="${bad:+$bad, }GIT_SSL_NO_VERIFY"
  if [ -n "$bad" ]; then
    report FAIL tls-env "$bad turns certificate checks off for everything started from this shell" "remove it from your shell profile and open a new terminal"
  else
    report PASS tls-env "no environment variable turns certificate checks off"
  fi
}

check_ca_env() {
  local name value
  for name in SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE PIP_CERT NODE_EXTRA_CA_CERTS GIT_SSL_CAINFO; do
    value=$(printenv "$name" 2>/dev/null)
    [ -n "$value" ] || continue
    check_bundle "env-$name" "$value" "point $name at a current bundle, such as Homebrew's ca-certificates or the distribution's"
  done
}

# macOS ships /usr/bin/git and /usr/bin/python3 as shims that open the Command Line Tools
# installer when the tools are missing; calling one would pop a dialog mid-check.
apple_shim_missing() {
  [ "$PLATFORM" = macos ] && [ "$CLT" -eq 0 ] && [ "$1" = "/usr/bin/$2" ]
}

check_git() {
  local git verify cainfo version
  git=$(command -v git 2>/dev/null) || { report PASS git "git is not installed"; return; }
  if apple_shim_missing "$git" git; then
    report PASS git "/usr/bin/git needs the Command Line Tools, which are not installed"
    return
  fi
  verify=$("$git" config --get --type=bool http.sslVerify 2>/dev/null || "$git" config --get http.sslVerify 2>/dev/null)
  if [ "$verify" = false ]; then
    report FAIL git-sslverify "git config sets http.sslVerify false, so git checks no certificate" "git config --global --unset http.sslVerify"
  fi
  cainfo=$("$git" config --get --type=path http.sslCAInfo 2>/dev/null || "$git" config --get http.sslCAInfo 2>/dev/null)
  [ -n "$cainfo" ] && check_bundle git-cainfo "$cainfo" "point git config --global http.sslCAInfo at a current bundle"
  version=$("$git" --version 2>/dev/null | awk '{print $3}')
  check_client git "git ${version:-?}" "git config --global http.sslCAInfo <a current bundle>" probe_git "$git"
}

check_python() {
  local py version
  py=$(command -v python3 2>/dev/null) || return
  apple_shim_missing "$py" python3 && return
  [ "$PLATFORM" = macos ] && [ "$py" = /usr/bin/python3 ] && return
  version=$("$py" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null | tail -n 1)
  check_client python3 "python3 ${version:-?} urllib" "set SSL_CERT_FILE to a current bundle, or update $(upgrade_hint Python "$FIXED_PYTHON")" probe_python "$py"
  PYTHONS="$PYTHONS $py"
}

check_node() {
  local node version roots fix
  node=$(command -v node 2>/dev/null) || { report PASS node "node is not installed"; return; }
  version=$("$node" --version 2>/dev/null)
  fix="update $(upgrade_hint Node.js "$FIXED_NODE")"
  roots=$("$node" -p 'require("tls").rootCertificates.join("\n")' 2>/dev/null)
  if [ -n "$roots" ] && have openssl; then
    # procsub ok: printf of a variable cannot stop early
    scan_stream < <(printf '%s\n' "$roots")
    judge_scan node-roots "Node.js ${version:-?} bundled roots" "$fix"
  else
    report UNKNOWN node-roots "could not read Node.js ${version:-?} bundled roots" "check node runs: node -p process.version"
  fi
  check_client node "Node.js ${version:-?} https" "$fix, and check NODE_EXTRA_CA_CERTS" probe_node "$node"
}

# Numeric, field by field: 2.1.1000 is later than 2.1.303.
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 } exit 1 }'
}

check_tool_version() {
  local id=$1 command=$2 label=$3 minimum=$4 fix=$5 bin version
  bin=$(command -v "$command" 2>/dev/null) || { report PASS "$id" "$label is not on the PATH"; return; }
  version=$("$bin" --version 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^v?[0-9]+\.[0-9]+\.[0-9]+/) { sub(/^v/, "", $i); print $i; exit } }')
  case $version in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) report UNKNOWN "$id" "could not read the version of $bin" "run: $command --version"; return ;;
  esac
  if version_lt "$version" "$minimum"; then
    report FAIL "$id" "$label $version predates $minimum, the first release with the $NAME fix" "$fix"
  else
    report PASS "$id" "$label $version is $minimum or later"
  fi
}

check_versions() {
  local i=0
  while [ "$i" -lt "$VER_COUNT" ]; do
    check_tool_version "${VER_ID[$i]}" "${VER_CMD[$i]}" "${VER_LABEL[$i]}" "${VER_MIN[$i]}" "${VER_FIX[$i]}"
    i=$((i + 1))
  done
}

# Both the plain import and one with the user site added: python -I drops the user site,
# which is where a Mac's `pip3 install --user requests` puts certifi.
python_bundle() {
  "$1" -I -c "import $2 as c; print(c.where())" 2>/dev/null | tail -n 1
  "$1" -I -c "import site, sys; sys.path.insert(0, site.getusersitepackages()); import $2 as c; print(c.where())" 2>/dev/null | tail -n 1
}

certifi_candidates() {
  local py root
  for py in ${1+"$@"}; do
    python_bundle "$py" certifi
    python_bundle "$py" pip._vendor.certifi
  done
  for root in "$HOME/.local" "$HOME/Library/Python" "$HOME/.virtualenvs" "$HOME/.venv" "$HOME/venvs" "$HOME/.pyenv" \
    "$HOME/.cache/pypoetry" "$HOME/Library/Caches/pypoetry" "$HOME/Library/Application Support/pipx" ${BREW:+"$BREW/lib"}; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 9 -type f -name cacert.pem -path '*certifi*' 2>/dev/null
  done
  printf '%s\n' "$SCANS" | while IFS= read -r root; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    find "$root" -maxdepth 9 -type f -name cacert.pem -path '*certifi*' 2>/dev/null
  done
}

certifi_fix() {
  local tool
  case $1 in
    */uv/tools/*)
      tool=${1#*/uv/tools/}
      echo "uv tool upgrade ${tool%%/*} (or uv tool upgrade --all)"
      ;;
    */pipx/venvs/*)
      tool=${1#*/pipx/venvs/}
      echo "pipx runpip ${tool%%/*} install -U certifi"
      ;;
    */pip/_vendor/certifi/*) echo "update $(upgrade_hint pip "$FIXED_PIP") in that Python: python -m pip install -U pip" ;;
    *) echo "update $(upgrade_hint certifi "$FIXED_CERTIFI") in that environment: python -m pip install -U certifi" ;;
  esac
}

check_certifi() {
  local found=0 file
  while IFS= read -r file; do
    [ -n "$file" ] && [ -f "$file" ] || continue
    found=1
    case $CHECKED in *"|$(real_path "$file")|"*) continue ;; esac
    check_bundle certifi "$file" "$(certifi_fix "$file")"
  # procsub ok: a candidate lister that stops early lists fewer bundles, like a machine
  # with fewer; python's and find's own failures are per-candidate and already ignored
  done < <(certifi_candidates ${1+"$@"} | awk 'NF && !seen[$0]++')
  [ "$found" -eq 1 ] || report PASS certifi "no Python certifi bundle found in the usual places (add --scan DIR for project venvs)"
}

# === MACOS ===

check_macos() {
  local prefix version
  xcode-select -p >/dev/null 2>&1 || CLT=0
  # Apple's own trust store (Safari, URLSession) is separate and not tested here; this is
  # the bundle that /usr/bin/curl, LibreSSL and Apple's python3 read.
  check_bundle apple-cert-pem /etc/ssl/cert.pem "remove the listed roots from /etc/ssl/cert.pem (needs admin; a macOS update may restore them) or install Apple's fix when it ships; exporting SSL_CERT_FILE covers your shell only"
  check_client apple-curl "/usr/bin/curl" "export SSL_CERT_FILE and CURL_CA_BUNDLE pointing at a current bundle (such as Homebrew's ca-certificates) in ~/.zshrc, then open a new terminal" probe_curl /usr/bin/curl
  for prefix in /opt/homebrew /usr/local; do
    if [ -x "$prefix/bin/brew" ]; then
      BREW=$prefix
      break
    fi
  done
  if [ -z "$BREW" ]; then
    report PASS homebrew "Homebrew is not installed"
  else
    version=$(ls "$BREW/Cellar/ca-certificates" 2>/dev/null | sort | tail -n 1)
    if [ -e "$BREW/etc/ca-certificates/cert.pem" ]; then
      check_bundle brew-bundle "$BREW/etc/ca-certificates/cert.pem" "brew update && brew upgrade ca-certificates (installed: ${version:-unknown})"
    else
      report PASS brew-bundle "Homebrew's ca-certificates is not installed"
    fi
    [ -e "$BREW/etc/openssl@3/cert.pem" ] && check_bundle brew-openssl "$BREW/etc/openssl@3/cert.pem" "brew update && brew upgrade ca-certificates openssl@3"
    [ -x "$BREW/opt/curl/bin/curl" ] && check_client brew-curl "Homebrew curl" "brew update && brew upgrade curl ca-certificates" probe_curl "$BREW/opt/curl/bin/curl"
  fi
  if [ "$CLT" -eq 0 ]; then
    report PASS apple-python3 "Apple's python3 needs the Command Line Tools, which are not installed"
  else
    check_client apple-python3 "Apple python3 urllib" "export SSL_CERT_FILE pointing at a current bundle in ~/.zshrc, then open a new terminal" probe_python /usr/bin/python3
    PYTHONS="/usr/bin/python3"
  fi
}

# === LINUX ===

distro_fix() {
  if have apt-get; then echo "sudo apt update && sudo apt install --only-upgrade ca-certificates"
  elif have dnf; then echo "sudo dnf upgrade ca-certificates"
  elif have yum; then echo "sudo yum update ca-certificates"
  elif have zypper; then echo "sudo zypper update ca-certificates"
  elif have apk; then echo "apk upgrade ca-certificates (as root)"
  elif have pacman; then echo "sudo pacman -Syu ca-certificates-mozilla"
  else echo "update the ca-certificates package"; fi
}

distro_version() {
  if have dpkg-query; then dpkg-query -W -f='${Version}' ca-certificates 2>/dev/null
  elif have rpm; then rpm -q ca-certificates 2>/dev/null
  elif have apk; then apk info -v ca-certificates 2>/dev/null | head -n 1
  fi
}

check_linux() {
  local file real seen="" fix found=0 version
  grep -qi microsoft /proc/version 2>/dev/null && PLATFORM=wsl
  version=$(distro_version)
  fix="$(distro_fix) (installed: ${version:-unknown})"
  for file in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    [ -e "$file" ] || continue
    real=$(real_path "$file")
    case "|$seen|" in *"|$real|"*) continue ;; esac
    seen="$seen|$real"
    found=1
    check_bundle system-bundle "$file" "$fix"
  done
  [ "$found" -eq 1 ] || report UNKNOWN system-bundle "no system CA bundle found in the usual places" "install the ca-certificates package"
  if have curl; then
    check_client curl "curl $(curl --version 2>/dev/null | awk 'NR == 1 {print $2}')" "$fix" probe_curl "$(command -v curl)"
  else
    report PASS curl "curl is not installed"
  fi
}

# === MAIN ===

while [ $# -gt 0 ]; do
  case $1 in
    --incident)
      [ $# -ge 2 ] || usage_error "--incident needs a pack name (see --list)"
      INCIDENT=$2
      shift
      ;;
    --offline) OFFLINE=1 ;;
    --list) LIST=1 ;;
    --bundle)
      [ $# -ge 2 ] || usage_error "--bundle needs a file"
      BUNDLES="$BUNDLES
$2"
      shift
      ;;
    --scan)
      [ $# -ge 2 ] || usage_error "--scan needs a folder"
      SCANS="$SCANS
$2"
      shift
      ;;
    -h | --help) HELP=1 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

if [ "$LIST" -eq 1 ]; then
  list_packs
  exit 0
fi
if [ "$HELP" -eq 1 ] && [ -z "$INCIDENT" ]; then
  usage
  exit 0
fi
[ -n "$INCIDENT" ] || usage_error "--incident NAME is required; packs here: $(pack_names)"
# A name, never a path: it selects a reviewed pack from this skill's own assets.
case $INCIDENT in
  -* | *[!a-z0-9-]*) usage_error "an incident name is lower-case letters, digits and hyphens; packs here: $(pack_names)" ;;
esac
PACK_FILE="$PACK_DIR/$INCIDENT.conf"
if [ ! -f "$PACK_FILE" ] || [ ! -r "$PACK_FILE" ]; then
  printf 'check-ca-trust: no incident pack named %s; packs here: %s\n' "$INCIDENT" "$(pack_names)" >&2
  exit 3
fi
load_pack
apply_local_ports
set_urls
if [ "$HELP" -eq 1 ]; then
  usage
  print_hosts
  exit 0
fi
if [ -n "$BUNDLES" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] && check_bundle bundle "$file" "remove the listed certificates, or replace the bundle with a current one"
  # procsub ok: printf of a variable cannot stop early
  done < <(printf '%s\n' "$BUNDLES")
  finish
fi

case $(uname -s) in
  Darwin) PLATFORM=macos; check_macos ;;
  Linux) PLATFORM=linux; check_linux ;;
  *)
    PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    report UNKNOWN platform "$(uname -s) is not macOS or Linux" "on Windows, run check-ca-trust.ps1 from PowerShell"
    finish
    ;;
esac

check_tls_env
check_ca_env
check_git
check_python
check_node
check_versions
check_certifi $PYTHONS
[ "$OFFLINE" -eq 1 ] && report UNKNOWN network "the network tests were skipped (--offline), so no client was tested" "re-run without --offline"
finish
