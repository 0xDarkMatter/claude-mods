#!/usr/bin/env bash
# Print incident-pack `key` records for the certificates in PEM files.
#
# Usage:   pack-keys.sh FILE...
# Input:   PEM files holding one or more certificates each (roots, intermediates, cross-signs).
# Output:  one `key|<SPKI SHA-256>|<subject CN>|<SPKI base64>` line per distinct key, in
#          first-seen order, ready for assets/incidents/<id>.conf (format in
#          references/incident-packs.md). Certificates sharing a key print once.
# Stderr:  errors only.
# Exit:    0 ok, 2 usage, 3 a file is missing, 4 a certificate could not be read,
#          5 openssl is not installed
#
# Examples:
#   bash pack-keys.sh roots.pem impacted-intermediates.pem
#   bash pack-keys.sh tests/fixtures/emudhra-2026-10/listed-*.crt
#
# The key's DER is openssl's own encoding of the certificate's SubjectPublicKeyInfo, the
# same bytes check-ca-trust.sh hashes, so the hash printed here is the one it compares.
# Reads and prints only: writes no file (each certificate passes through a pipe).
set -uo pipefail

usage() {
  printf '%s\n' \
    "Usage: pack-keys.sh FILE..." \
    "" \
    "Print one incident-pack key record per distinct key in the certificates of the" \
    "given PEM files: key|<SPKI SHA-256>|<subject CN>|<SPKI base64>." \
    "" \
    "EXAMPLES" \
    "  bash pack-keys.sh roots.pem impacted-intermediates.pem" \
    "  bash pack-keys.sh tests/fixtures/emudhra-2026-10/listed-*.crt" \
    "" \
    "Exit: 0 ok, 2 usage, 3 a file is missing, 4 a certificate could not be read," \
    "5 openssl is not installed."
}

case ${1:-} in
  -h | --help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  -*) printf 'pack-keys: unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
command -v openssl >/dev/null 2>&1 || { echo "pack-keys: openssl is not installed" >&2; exit 5; }

# The subject's CN from its RFC 2253 form, where RDNs are split by unescaped commas.
cn_of() {
  openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed -e 's/^subject= *//' | awk '{
    s = $0; n = length(s); i = 1
    while (i <= n) {
      v = ""
      for (j = i; j <= n; j++) {
        c = substr(s, j, 1)
        if (c == "\\") { v = v c substr(s, j + 1, 1); j++; continue }
        if (c == ",") break
        v = v c
      }
      if (v ~ /^CN=/) { print substr(v, 4); exit }
      i = j + 1
    }
  }'
}

seen="|"
for file in "$@"; do
  [ -f "$file" ] || { printf 'pack-keys: %s does not exist\n' "$file" >&2; exit 3; }
  pems=$(awk '/^-----BEGIN CERTIFICATE-----/ { on = 1 } on { print } /^-----END CERTIFICATE-----/ { on = 0; print "--next--" }' "$file" | tr -d '\r')
  pem=""
  while IFS= read -r line; do
    if [ "$line" != "--next--" ]; then
      pem="${pem:+$pem
}$line"
      continue
    fi
    spki=$(printf '%s\n' "$pem" | openssl x509 -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null | openssl base64 -A 2>/dev/null) && [ -n "$spki" ] \
      || { printf 'pack-keys: a certificate in %s could not be read\n' "$file" >&2; exit 4; }
    hash=$(printf '%s' "$spki" | openssl base64 -d -A 2>/dev/null | openssl dgst -sha256 2>/dev/null | awk '{print toupper($NF)}')
    name=$(printf '%s\n' "$pem" | cn_of)
    pem=""
    case $seen in *"|$hash|"*) continue ;; esac
    seen="$seen$hash|"
    printf 'key|%s|%s|%s\n' "$hash" "${name:-?}" "$spki"
  # procsub ok: printf of a variable cannot stop early
  done < <(printf '%s\n' "$pems")
done
