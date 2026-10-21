#!/bin/bash
# hooks/post-tls-verify-scan.sh
# PostToolUse hook (matcher: Write|Edit) - the code half of pre-tls-verify-ask.sh.
#
# pre-tls-verify-ask.sh asks before a COMMAND turns TLS certificate verification
# off. The same switch also arrives as code or config the agent writes: verify=False
# in a client, rejectUnauthorized: false in an agent, strict-ssl=false in a
# committed .npmrc. That is worse than a one-off command, because it ships. This
# hook reads the text an Edit or Write adds and, when it turns verification off,
# tells Claude so beside the tool result. rules/supply-chain.md: a certificate
# error is a stop-and-report, never switched off.
#
# Advisory only: exit 0, one additionalContext JSON envelope, never blocks. The
# edit has already happened; the advisory asks for a revert or an explicit,
# host-scoped exception (a self-signed certificate on a local dev host).
#
# Patterns (each one is a case in tests/hooks.sh; only the NEW text is read):
#   Python  verify=False, ssl.CERT_NONE, ssl._create_unverified_context,
#           check_hostname = False
#   Node    rejectUnauthorized: false; NODE_TLS_REJECT_UNAUTHORIZED, PYTHONHTTPSVERIFY
#           set to 0 and GIT_SSL_NO_VERIFY set at all (code, .env, YAML, Dockerfile ENV)
#   PHP     Guzzle 'verify' => false, CURLOPT_SSL_VERIFYPEER/VERIFYHOST false or 0,
#           stream context verify_peer(_name) => false, Laravel Http::withoutVerifying()
#   Go      InsecureSkipVerify: true          Ruby / C   VERIFY_NONE
#   Rust    danger_accept_invalid_certs(true) / danger_accept_invalid_hostnames(true)
#   Java    trust-all X509TrustManager (empty checkServerTrusted), HostnameVerifier
#           returning true, NoopHostnameVerifier, TrustAllStrategy,
#           InsecureTrustManagerFactory
#   .NET    a certificate validation callback returning true,
#           DangerousAcceptAnyServerCertificateValidator, PowerShell {$true} callbacks
#   Config  .npmrc strict-ssl=false, .yarnrc.yml enableStrictSsl: false,
#           pip.conf/pip.ini and requirements*.txt trusted-host, composer.json
#           "disable-tls": true / "secure-http": false, .gitconfig sslVerify = false
#
# Prose is skipped (.md .mdx .markdown .rst .adoc .txt; requirements*.txt is config,
# not prose), or the rule file, this repo's docs and every CHANGELOG that quotes
# the patterns would trigger it.
#
# Reads the tool call as JSON on stdin (.tool_input.file_path, .new_string or
# .content). Silent on no match, on prose, and without jq.
# Channel contract tests: tests/hooks.sh ("post-tls-verify-scan").

set -u
export LC_ALL=C

RAW=""; [[ ! -t 0 ]] && { IFS= read -r -d '' RAW || true; }
[[ -z "$RAW" ]] && exit 0
# Cheap pre-filter before jq: every pattern below contains one of these (nocase).
shopt -s nocasematch
RE_PREFILTER='(verif|cert|ssl|tls|trust|hostname|unauthorized|secure-http)'
[[ "$RAW" =~ $RE_PREFILTER ]] || exit 0
shopt -u nocasematch

command -v jq >/dev/null 2>&1 || exit 0   # no jq, no envelope - stay silent
out="$(printf '%s' "$RAW" | jq -r '(.tool_input.file_path // ""), (.tool_input.new_string // .tool_input.content // "")' 2>/dev/null)" || exit 0
out="${out//$'\r'/}"   # Windows jq.exe writes -r output in text mode (\r\n)
FILE="${out%%$'\n'*}"
NEW=""; [[ "$out" == *$'\n'* ]] && NEW="${out#*$'\n'}"
[[ -z "$FILE" || -z "$NEW" ]] && exit 0

BASE="${FILE##*[/\\]}"
shopt -s nocasematch
if [[ "$BASE" != requirements*.txt && "$BASE" =~ [.](md|mdx|markdown|rst|adoc|txt)$ ]]; then exit 0; fi
shopt -u nocasematch

HITS=""
hit() { case $'\n'"$HITS" in *$'\n'"$1"$'\n'*) ;; *) HITS+="$1"$'\n' ;; esac; return 0; }

# Guard: regexes live in variables (bash 3.2 and 5 read inline regexes differently).
# B = a word boundary that also refuses $ and ${, so ${GIT_SSL_NO_VERIFY:-} and
# $NODE_TLS_REJECT_UNAUTHORIZED (reads, not writes) stay silent. A bare { is a
# boundary: Go's tls.Config{InsecureSkipVerify: true} and JS {rejectUnauthorized:
# false} start right after one. E = end of word.
B='(^|[^$[:alnum:]_{]|(^|[^$])[{])'
E='([^[:alnum:]_]|$)'
NL=$'\n'
# label|flags|regex - flags: i = case-insensitive. One row per pattern.
RULES=(
  "verify=False (Python requests/httpx)||${B}verify[[:space:]]*=[[:space:]]*False${E}"
  "ssl.CERT_NONE||${B}CERT_NONE${E}"
  "ssl._create_unverified_context||_create_unverified_context"
  "check_hostname = False||${B}check_hostname[[:space:]]*=[[:space:]]*False${E}"
  "rejectUnauthorized: false||${B}rejectUnauthorized[\"']?[[:space:]]*[:=][[:space:]]*false${E}"
  "NODE_TLS_REJECT_UNAUTHORIZED=0|i|${B}NODE_TLS_REJECT_UNAUTHORIZED[\"']?[]]?[[:space:]]*[:=][[:space:]]*[\"']?0([^[:alnum:]_.]|$)"
  "NODE_TLS_REJECT_UNAUTHORIZED=0|i|${B}ENV[[:space:]]+NODE_TLS_REJECT_UNAUTHORIZED[[:space:]]+[\"']?0${E}"
  "PYTHONHTTPSVERIFY=0|i|${B}PYTHONHTTPSVERIFY[\"']?[]]?[[:space:]]*[:=][[:space:]]*[\"']?0([^[:alnum:]_.]|$)"
  "PYTHONHTTPSVERIFY=0|i|${B}ENV[[:space:]]+PYTHONHTTPSVERIFY[[:space:]]+[\"']?0${E}"
  "GIT_SSL_NO_VERIFY set|i|${B}GIT_SSL_NO_VERIFY[\"']?[]]?[[:space:]]*[:=][[:space:]]*[^=[:space:]]"
  "GIT_SSL_NO_VERIFY set|i|${B}ENV[[:space:]]+GIT_SSL_NO_VERIFY[[:space:]]+[^[:space:]]"
  "Guzzle 'verify' => false|i|([\"']verify[\"']|RequestOptions::VERIFY)[[:space:]]*=>[[:space:]]*false${E}"
  "CURLOPT_SSL_VERIFYPEER/VERIFYHOST off|i|${B}(CURLOPT_)?SSL_VERIFY(PEER|HOST)[]]?[[:space:]]*(,|=>|=)[[:space:]]*(false|0L?)${E}"
  "verify_peer => false|i|${B}[\"']?verify_peer(_name)?[\"']?[[:space:]]*(=>|:|=)[[:space:]]*false${E}"
  "Http::withoutVerifying()||${B}withoutVerifying[[:space:]]*[(]"
  "InsecureSkipVerify: true||${B}InsecureSkipVerify[[:space:]]*[:=][[:space:]]*true${E}"
  "VERIFY_NONE (Ruby OpenSSL / C)||(^|[^[:alnum:]])VERIFY_NONE${E}"
  "danger_accept_invalid_certs(true)||${B}danger_accept_invalid_(certs|hostnames)[[:space:]]*[(][[:space:]]*true"
  "trust-all TLS class||${B}(NoopHostnameVerifier|ALLOW_ALL_HOSTNAME_VERIFIER|AllowAllHostnameVerifier|TrustAllStrategy|InsecureTrustManagerFactory)${E}"
  "HostnameVerifier returning true||[Hh]ostnameVerifier[^;]*(->[[:space:]]*true|return[[:space:]]+true)${E}"
  "X509TrustManager that trusts everything||checkServerTrusted[[:space:]]*[(][^)]*[)][^{;]*[{][[:space:]]*(//[^${NL}]*[[:space:]]*)*[}]"
  "certificate validation callback returning true|i|(ServerCertificateCustomValidationCallback|ServerCertificateValidationCallback|RemoteCertificateValidationCallback)[^;]*(=>[[:space:]]*true|return[[:space:]]+true|[{][[:space:]]*[\$]true)${E}"
  "DangerousAcceptAnyServerCertificateValidator||DangerousAcceptAnyServerCertificateValidator"
  "ServicePointManager CertificatePolicy|i|ServicePointManager[]]::CertificatePolicy[[:space:]]*="
)
# Committed client config: only in the file that the client reads.
case "$BASE" in
  .npmrc)        RULES+=("strict-ssl=false in .npmrc|i|(^|[[:space:]])strict-ssl[[:space:]]*=[[:space:]]*false${E}") ;;
  .yarnrc.yml)   RULES+=("enableStrictSsl: false in .yarnrc.yml|i|(^|[[:space:]])enableStrictSsl[[:space:]]*:[[:space:]]*false${E}") ;;
  pip.conf|pip.ini) RULES+=("trusted-host in pip config|i|(^|[[:space:]])trusted-host[[:space:]]*=") ;;
  requirements*.txt) RULES+=("--trusted-host in requirements|i|(^|[[:space:]])--trusted-host([[:space:]=]|$)") ;;
  composer.json) RULES+=("composer disable-tls / secure-http off|i|\"(disable-tls\"[[:space:]]*:[[:space:]]*true|secure-http\"[[:space:]]*:[[:space:]]*false)${E}") ;;
  .gitconfig|config)
    if [[ "$BASE" == .gitconfig || "$FILE" =~ [.]git[/\\]config$ ]]; then
      RULES+=("sslVerify = false in git config|i|(^|[[:space:]])sslverify[[:space:]]*=[[:space:]]*(false|no|off|0)${E}")
    fi ;;
esac

for row in "${RULES[@]}"; do
  label="${row%%|*}"; rest="${row#*|}"; flags="${rest%%|*}"; re="${rest#*|}"
  if [[ "$flags" == *i* ]]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  [[ "$NEW" =~ $re ]] && hit "$label"
done
shopt -u nocasematch
[[ -z "$HITS" ]] && exit 0

LIST="${HITS%$'\n'}"; LIST="${LIST//$'\n'/, }"
MSG="TLS ADVISORY: this edit to $BASE turns TLS certificate verification off ($LIST).
Anyone on the network path can then impersonate the server it talks to and read or
change the traffic. If a certificate error prompted it, revert the change and report
the error and the host to the user instead (rules/supply-chain.md). A self-signed
certificate on a local development host is the one expected case: scope the setting
to that host and say so in your reply."

# Guard: do not "simplify" this to plain echo. For PostToolUse, plain stdout on exit 0
# goes to the debug log and never reaches the model ("Exit code 0" in
# https://code.claude.com/docs/en/hooks). additionalContext lands next to the tool
# result. Nothing else may write to stdout, or the JSON stops parsing.
jq -nc --arg c "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
