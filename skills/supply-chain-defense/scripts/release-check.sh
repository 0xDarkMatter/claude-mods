#!/usr/bin/env bash
# Cooldown and waiver-evidence check for a tool installed from a GitHub release.
#
# For standalone tools and installers that no package registry covers (Git for
# Windows, a CLI shipped as .exe or .msi). Reads the release from the GitHub API
# and reports: its age against the cooldown, the CVE IDs its notes name, whether
# the downloaded file's SHA-256 matches a hash the release publishes (the asset
# digest or the notes), and on Windows the file's Authenticode status and signer
# beside an installed reference binary's. Read-only: it downloads and installs
# nothing. Rule: rules/supply-chain.md, "Security-release exception"; steps:
# references/hardening-checklist.md section 5.
#
# Usage:   release-check.sh [--reference <installed-binary>] [--json] [-q] <owner/repo> <tag|latest> <file>
# Input:   the release (owner/repo and its tag, or "latest") and the file you
#          downloaded from it. --reference is a binary of the version installed
#          today; the new file must carry the same signing certificate.
# Output:  stdout = one tab-separated record: repo, tag, age_days, verdict, CVE IDs
#          (comma-joined, or -); or a JSON envelope with --json
# Stderr:  the evidence, the recommendation, errors
# Exit:    0 outside the cooldown and nothing contradicts the file, 2 usage,
#          3 file, reference or release not found,
#          5 missing dep (curl, jq, a SHA-256 tool),
#          7 release NOT checked (GitHub unreachable or rate-limited, an answer that
#            is not a release, no publish time) - never read 7 as a pass,
#          10 hold: inside the cooldown and some evidence is missing,
#          11 waiver recommended: inside the cooldown and every check this tool can
#             run passed - a person still decides,
#          12 refuse: the hash contradicts the release, or the signer is a
#             different subject (or none where the installed version has one) -
#             do not install this file, whatever its age
#
# Guard: there is no flag to waive or skip any check, the same deliberate design
# as preinstall-check.sh: a flag is the first thing a "critical fix, install now"
# lure would ask an agent to pass. Exit 11 RECOMMENDS asking for a waiver; it never
# grants one. Its wording must never read as approval (tests/run.sh pins that).
#
# Why the signer carries the weight: a hijacked release account can rewrite the
# notes, their CVE list and the hashes beside the asset, but it does not hold the
# vendor's code-signing key. So a recommendation needs a valid Authenticode
# signature with the SAME certificate thumbprint as the installed --reference.
# Only Authenticode (.exe .msi .msix .appx .dll, read by PowerShell's
# Get-AuthenticodeSignature, which exists on Windows only) is checked; any other
# file type, or a host without it, can at best hold.
#
# Renewal holds, it does not refuse. Code-signing certificates renew about once a
# year: same subject, new thumbprint. Refusing that would put every later release
# at 12 until someone installed past the refusal, which teaches people to ignore
# 12, the one code that must stay credible. So a renewal is missing evidence (hold
# inside the cooldown, ok outside it, never 11), confirmed with the vendor before
# anyone asks for a waiver. A different subject, or an unsigned file where the
# installed version is signed, still refuses. The policy is the checksum-and-signer
# row of rules/supply-chain.md, "Security-release exception".
#
# Examples:
#   release-check.sh git-for-windows/git v2.56.1.windows.1 ~/Downloads/Git-2.56.1-64-bit.exe \
#     --reference "/c/Program Files/Git/cmd/git.exe"
#   release-check.sh --json cli/cli latest ./gh_2.80.0_windows_amd64.msi | jq '.data[0].verdict'
#   COOLDOWN_DAYS=14 release-check.sh owner/tool v1.2.3 ./tool.exe --reference ./installed/tool.exe

set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_NOT_FOUND=3; EXIT_MISSING_DEP=5; EXIT_UNAVAILABLE=7
EXIT_HOLD=10; EXIT_WAIVER=11; EXIT_REFUSE=12

COOLDOWN_DAYS="${COOLDOWN_DAYS:-7}"; JSON=0; QUIET=0; REF=""; POS=()

# --json errors go to stdout as an envelope, and a human line to stderr. jq may be
# the missing dependency, so the fallback envelope is printed by hand, with the
# characters JSON would need escaped (quotes, Windows backslashes) dropped.
fail() {  # code exit message
  if [[ "$JSON" -eq 1 ]]; then
    jq -cn --arg c "$1" --arg m "$3" '{error:{code:$c, message:$m}}' 2>/dev/null \
      || printf '{"error":{"code":"%s","message":"%s"}}\n' "$1" "${3//[\"\\]/}"
  fi
  echo "ERROR: $3" >&2; exit "$2"
}
who() { jq -r '"\(.subject // "no subject") [\(.thumbprint // "no thumbprint")]"' <<<"$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reference)   [[ $# -ge 2 ]] || fail USAGE "$EXIT_USAGE" "--reference needs a path (try --help)"; REF=$2; shift ;;
    --reference=*) REF=${1#*=} ;;
    --json)        JSON=1 ;;
    -q|--quiet)    QUIET=1 ;;
    -h|--help)     awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "$EXIT_OK" ;;
    --)            shift; POS+=("$@"); break ;;
    -*)            fail USAGE "$EXIT_USAGE" "unknown flag: $1 (try --help)" ;;
    *)             POS+=("$1") ;;
  esac
  shift
done

[[ ${#POS[@]} -eq 3 ]] || fail USAGE "$EXIT_USAGE" "want <owner/repo> <tag|latest> <file> (try --help)"
REPO=${POS[0]}; TAG=${POS[1]}; FILE=${POS[2]}
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail USAGE "$EXIT_USAGE" "not an owner/repo: $REPO"
[[ "$TAG" =~ ^[A-Za-z0-9_.+/-]+$ ]] || fail USAGE "$EXIT_USAGE" "not a tag: $TAG"
[[ "$COOLDOWN_DAYS" =~ ^[0-9]+$ ]] || fail USAGE "$EXIT_USAGE" "COOLDOWN_DAYS must be a whole number of days"

command -v curl >/dev/null 2>&1 || fail MISSING_DEPENDENCY "$EXIT_MISSING_DEP" "curl required to read the release"
command -v jq   >/dev/null 2>&1 || fail MISSING_DEPENDENCY "$EXIT_MISSING_DEP" "jq required to read the release (winget install jqlang.jq | brew install jq | apt install jq)"
SHA_TOOL=""
for t in sha256sum shasum openssl; do command -v "$t" >/dev/null 2>&1 && { SHA_TOOL=$t; break; }; done
[[ -n "$SHA_TOOL" ]] || fail MISSING_DEPENDENCY "$EXIT_MISSING_DEP" "a SHA-256 tool required (sha256sum, shasum or openssl)"

[[ -f "$FILE" ]] || fail NOT_FOUND "$EXIT_NOT_FOUND" "file not found: $FILE"
[[ -z "$REF" || -f "$REF" ]] || fail NOT_FOUND "$EXIT_NOT_FOUND" "reference binary not found: $REF"

# Terminal framing on stderr: a term.sh panel for a human at a TTY, else plain
# lines. The lib is OPTIONAL (this skill is copied alone into other plugins), so the
# fallback must work and stay 7-bit ASCII; tests/run.sh "standalone" pins both.
emit() { [[ "$QUIET" -eq 1 ]] && return; printf '%s\n' "$1" >&2; }
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2; __HAVE_TERM=1
else __HAVE_TERM=0; TERM_DOT="|"; fi
PANEL=0
if [[ "$__HAVE_TERM" -eq 1 && "$QUIET" -eq 0 ]] && { [ -t 2 ] || [ -n "${FORCE_COLOR:-}" ]; }; then PANEL=1; fi
__PANEL_OPEN=0
popen() {
  [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 0 ]] || return 0
  { term_panel_open supply-chain "release ${TERM_DOT} ${REPO}"; term_panel_vert; } >&2; __PANEL_OPEN=1
}
prow() {  # mark legacy-prefix text
  if [[ "$PANEL" -eq 1 ]]; then popen; term_status_row "$1" "$2" "$3" >&2
  else emit "  $2 $3"; fi
}

iso_to_epoch() {
  local ts=$1
  date -d "$ts" +%s 2>/dev/null && return 0
  ts="${ts%%.*}"; ts="${ts%Z}"
  date -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null && return 0
  echo ""
}

# === RELEASE (GitHub API) ===
# -w appends the HTTP status on its own line, so a 404 (no such release: exit 3)
# is told apart from a rate limit or an outage (exit 7). Unauthenticated: 60
# requests an hour per IP.
if [[ "$TAG" == "latest" ]]; then URL="https://api.github.com/repos/${REPO}/releases/latest"
else URL="https://api.github.com/repos/${REPO}/releases/tags/${TAG//\//%2F}"; fi
resp=$(curl -sSL -m 30 -A "supply-chain-defense/release-check" -H 'Accept: application/vnd.github+json' \
  -w '\n%{http_code}' "$URL" 2>/dev/null) || fail UNAVAILABLE "$EXIT_UNAVAILABLE" "GitHub unreachable ($URL): release NOT checked"
http=${resp##*$'\n'}; REL=${resp%$'\n'*}
case "$http" in
  200) ;;
  404) fail NOT_FOUND "$EXIT_NOT_FOUND" "no release ${TAG} in ${REPO} (HTTP 404)" ;;
  403|429) fail UNAVAILABLE "$EXIT_UNAVAILABLE" "GitHub refused the request (HTTP ${http}, likely the 60/hour rate limit): release NOT checked" ;;
  *) fail UNAVAILABLE "$EXIT_UNAVAILABLE" "GitHub answered HTTP ${http:-none}: release NOT checked" ;;
esac
jq -e 'type == "object" and has("tag_name")' >/dev/null 2>&1 <<<"$REL" \
  || fail UNAVAILABLE "$EXIT_UNAVAILABLE" "GitHub answer is not a release document: release NOT checked"

REL_TAG=$(jq -r '.tag_name' <<<"$REL")
REL_URL=$(jq -r '.html_url // empty' <<<"$REL")
PUBLISHED=$(jq -r '.published_at // empty' <<<"$REL")
PRERELEASE=$(jq -r 'if (.prerelease // false) or (.draft // false) then "true" else "false" end' <<<"$REL")
[[ -n "$PUBLISHED" ]] || fail UNAVAILABLE "$EXIT_UNAVAILABLE" "release ${REL_TAG} has no publish time: age NOT checked"
EPOCH=$(iso_to_epoch "$PUBLISHED")
[[ -n "$EPOCH" ]] || fail UNAVAILABLE "$EXIT_UNAVAILABLE" "could not parse publish time ${PUBLISHED}: age NOT checked"
AGE=$(( ($(date +%s) - EPOCH) / 86400 ))
INSIDE=false; [[ "$AGE" -lt "$COOLDOWN_DAYS" ]] && INSIDE=true

REFUSE=()    # contradictions: the file is not what the release or the installed version says
MISSING=()   # evidence the exception needs that is absent or could not be checked

# === CVE IDS (release notes) ===
# Every CVE ID in the notes. A note can also mention an older CVE in passing (Git
# for Windows 2.56.1 cites CVE-2019-1348 as background), so the person still
# confirms each one is fixed in this release; the tool only proves IDs are named.
CVES_JSON=$(jq -c '[(.body // "") | scan("CVE-[0-9]{4}-[0-9]{4,}")] | unique' <<<"$REL")
[[ "$CVES_JSON" == "[]" ]] && MISSING+=("the release notes name no CVE IDs: \"security fixes\" alone is the lure, not evidence")
[[ "$PRERELEASE" == "true" ]] && MISSING+=("a prerelease or draft is never waived")

# === HASH (asset digest + notes) ===
# GitHub records a sha256 "digest" on each asset at upload; vendors such as Git for
# Windows also print a "<file> | <sha256>" table in the notes. A published hash
# for this file name that differs is a contradiction (refuse); the file's hash
# appearing anywhere is a match; neither is missing evidence (hold). A notes line
# belongs to the file only when one of its tokens IS the file name (split on
# spaces and Markdown table/link punctuation): a substring test made tool.exe
# claim mytool.exe's row and refuse a good file. \b keeps the 64-hex scan from
# taking the first half of a SHA-512.
case "$SHA_TOOL" in
  sha256sum) SUM=$(sha256sum < "$FILE") ;;
  shasum)    SUM=$(shasum -a 256 < "$FILE") ;;
  openssl)   SUM=$(openssl dgst -sha256 < "$FILE"); SUM=${SUM##*= } ;;
esac
SUM=${SUM%% *}; SUM=$(printf '%s' "$SUM" | tr 'A-F' 'a-f')
[[ "$SUM" =~ ^[0-9a-f]{64}$ ]] || fail MISSING_DEPENDENCY "$EXIT_MISSING_DEP" "could not compute the SHA-256 of $FILE with $SHA_TOOL"
BASE=${FILE##*[/\\]}
HASH_JSON=$(jq -c --arg n "$BASE" --arg h "$SUM" '
  ((.body // "") | ascii_downcase) as $notes
  | (first(.assets[]? | select(.name == $n) | .digest // empty | ascii_downcase) // "") as $dig
  | ([(.body // "") | split("\n")[]
      | select([splits("[\\s|`*()\\[\\]<>:,]+")] | any(.[]; . == $n))
      | scan("\\b[0-9a-fA-F]{64}\\b") | ascii_downcase] | unique) as $named
  | { asset_digest: (if $dig == "" then null else $dig end),
      notes_hashes_for_file: $named,
      sources: ([ (if $dig == ("sha256:" + $h) then "asset-digest" else empty end),
                  (if ($notes | contains($h)) then "release-notes" else empty end) ]),
      contradictions: ([ (if ($dig | startswith("sha256:")) and $dig != ("sha256:" + $h)
                            then "the asset digest for \($n) is \($dig)" else empty end),
                         (if ($named | length) > 0 and ($named | any(.[]; . == $h) | not)
                            then "the notes list \($n) as \($named | join(", "))" else empty end) ]) }' <<<"$REL")
HASH_STATE="unpublished"
if jq -e '.contradictions | length > 0' >/dev/null <<<"$HASH_JSON"; then
  HASH_STATE="mismatch"
  REFUSE+=("SHA-256 mismatch: the file is ${SUM}, but $(jq -r '.contradictions | join("; ")' <<<"$HASH_JSON")")
elif jq -e '.sources | length > 0' >/dev/null <<<"$HASH_JSON"; then
  HASH_STATE="match"
else
  MISSING+=("no hash published in the release matches the file (SHA-256 ${SUM})")
fi

# === SIGNER (Authenticode) ===
SIG_STATE="not-applicable"; SIG_FILE="null"; SIG_REF="null"
shopt -s nocasematch
case "$BASE" in *.exe|*.msi|*.msix|*.appx|*.dll) SIGNABLE=1 ;; *) SIGNABLE=0 ;; esac
shopt -u nocasematch
PS=""
for c in pwsh powershell; do command -v "$c" >/dev/null 2>&1 && { PS=$c; break; }; done
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
# Paths reach PowerShell through the environment, never spliced into the code, and
# the code holds no double quotes, which the Windows command line would mangle.
read -r -d '' PS_CODE <<'PS'
$ErrorActionPreference = 'Stop'
$rows = @()
foreach ($role in @('file', 'reference')) {
  $p = [Environment]::GetEnvironmentVariable('RC_SIG_' + $role.ToUpper())
  if (-not $p) { continue }
  $s = Get-AuthenticodeSignature -LiteralPath $p
  $c = $s.SignerCertificate
  $rows += [pscustomobject]@{ role = $role; status = [string]$s.Status; thumbprint = $(if ($c) { $c.Thumbprint } else { $null }); subject = $(if ($c) { $c.Subject } else { $null }) }
}
ConvertTo-Json -InputObject $rows -Compress
PS
if [[ "$SIGNABLE" -eq 0 ]]; then
  MISSING+=("${BASE} is not a file type this tool can check a signature on (.exe .msi .msix .appx .dll): nothing outside the release account vouches for the notes and hashes")
elif [[ -z "$PS" ]]; then
  SIG_STATE="unavailable"; MISSING+=("no PowerShell here, so the Authenticode signature was not checked")
else
  sig=$(RC_SIG_FILE="$(winpath "$FILE")" RC_SIG_REFERENCE="${REF:+$(winpath "$REF")}" \
    "$PS" -NoProfile -NonInteractive -Command "$PS_CODE" 2>/dev/null) || sig=""
  sig=$(jq -c 'if type == "array" then . elif type == "object" then [.] else error("no rows") end' <<<"$sig" 2>/dev/null) || sig=""
  SIG_FILE=$(jq -c 'first(.[] | select(.role == "file")) // null' <<<"${sig:-[]}" 2>/dev/null) || SIG_FILE="null"
  [[ -n "$REF" ]] && { SIG_REF=$(jq -c 'first(.[] | select(.role == "reference")) // null' <<<"${sig:-[]}" 2>/dev/null) || SIG_REF="null"; }
  fstat=$(jq -r '.status // empty' <<<"$SIG_FILE"); rstat=$(jq -r '.status // empty' <<<"$SIG_REF")
  fthumb=$(jq -r '.thumbprint // empty | ascii_upcase' <<<"$SIG_FILE"); rthumb=$(jq -r '.thumbprint // empty | ascii_upcase' <<<"$SIG_REF")
  fsubj=$(jq -r '.subject // empty' <<<"$SIG_FILE"); rsubj=$(jq -r '.subject // empty' <<<"$SIG_REF")
  case "$fstat" in
    "")
      SIG_STATE="unavailable"; MISSING+=("the Authenticode signature could not be read (Get-AuthenticodeSignature runs on Windows only)") ;;
    HashMismatch|NotTrusted)
      SIG_STATE="invalid"; REFUSE+=("the file's Authenticode signature is ${fstat}: it does not vouch for this file") ;;
    NotSigned)
      SIG_STATE="unsigned"
      if [[ "$rstat" == "Valid" ]]; then REFUSE+=("the file is unsigned, but the installed version is signed by $(who "$SIG_REF")")
      else MISSING+=("the file is not signed"); fi ;;
    Valid)
      if [[ -z "$REF" ]]; then
        SIG_STATE="valid-uncompared"; MISSING+=("no --reference given, so the signer was not compared with the installed version")
      elif [[ "$rstat" != "Valid" ]]; then
        SIG_STATE="valid-uncompared"; MISSING+=("the reference binary's signature is ${rstat:-unreadable}, so the signers were not compared")
      elif [[ -n "$fthumb" && "$fthumb" == "$rthumb" ]]; then
        SIG_STATE="same-signer"
      elif [[ -n "$fsubj" && "$fsubj" == "$rsubj" ]]; then
        SIG_STATE="renewed"; MISSING+=("certificate renewed: same subject, new thumbprint (the file ${fthumb:-none}, the installed version ${rthumb:-none}); confirm the renewal with the vendor before asking for a waiver")
      else
        SIG_STATE="signer-changed"; REFUSE+=("signer changed: the file is signed by $(who "$SIG_FILE"), the installed version by $(who "$SIG_REF")")
      fi ;;
    *)
      SIG_STATE="unavailable"; MISSING+=("the file's Authenticode status is ${fstat}") ;;
  esac
fi

# === VERDICT ===
# A contradiction refuses at any age. Otherwise age decides, and inside the cooldown
# only a complete set of evidence turns the hold into a recommendation.
if [[ ${#REFUSE[@]} -gt 0 ]]; then VERDICT="refuse"; RC=$EXIT_REFUSE
elif [[ "$INSIDE" == "false" ]]; then VERDICT="ok"; RC=$EXIT_OK
elif [[ ${#MISSING[@]} -eq 0 ]]; then VERDICT="waiver-recommended"; RC=$EXIT_WAIVER
else VERDICT="hold"; RC=$EXIT_HOLD; fi

jarr() { jq -cn '$ARGS.positional' --args "$@"; }
REASONS_JSON=$(jarr ${REFUSE[@]+"${REFUSE[@]}"} ${MISSING[@]+"${MISSING[@]}"})
STILL_JSON="[]"
[[ "$VERDICT" == "waiver-recommended" ]] && STILL_JSON=$(jarr \
  "confirm each CVE ID is fixed in this release, not only mentioned in its notes" \
  "a person approves the install" \
  "the waiver is recorded in the install note: CVE IDs and where named, the SHA-256 and its source, the signer")
CVES_CSV=$(jq -r 'if length == 0 then "-" else join(",") end' <<<"$CVES_JSON")

# === OUTPUT ===
if [[ "$JSON" -eq 1 ]]; then
  jq -n --arg repo "$REPO" --arg tag "$REL_TAG" --arg url "$REL_URL" --arg pub "$PUBLISHED" \
    --argjson age "$AGE" --argjson inside "$INSIDE" --argjson pre "$PRERELEASE" --argjson cves "$CVES_JSON" \
    --arg path "$FILE" --arg name "$BASE" --arg sum "$SUM" --arg hstate "$HASH_STATE" --argjson hash "$HASH_JSON" \
    --arg sstate "$SIG_STATE" --argjson sfile "$SIG_FILE" --argjson sref "$SIG_REF" \
    --arg verdict "$VERDICT" --argjson reasons "$REASONS_JSON" --argjson still "$STILL_JSON" --argjson cd "$COOLDOWN_DAYS" \
    '{data:[{repo:$repo, tag:$tag, url:$url, published:$pub, age_days:$age, inside_cooldown:$inside, prerelease:$pre,
       cves:$cves,
       file:{path:$path, name:$name, sha256:$sum, hash:$hstate, hash_sources:$hash.sources, asset_digest:$hash.asset_digest},
       signature:{state:$sstate, file:$sfile, reference:$sref},
       verdict:$verdict, reasons:$reasons, still_required:$still}],
      meta:{count:1, cooldown_days:$cd, schema:"axiom.tool.release-check.report/v1"}}'
else
  printf '%s\t%s\t%s\t%s\t%s\n' "$REPO" "$REL_TAG" "$AGE" "$VERDICT" "$CVES_CSV"
fi

if [[ "$PANEL" -eq 1 ]]; then popen; else emit "=== Release check (${REPO} ${REL_TAG}, cooldown ${COOLDOWN_DAYS}d) ==="; fi
if [[ "$INSIDE" == "true" ]]; then prow bad "[INSIDE COOLDOWN]" "published ${PUBLISHED} - ${AGE}d ago (< ${COOLDOWN_DAYS}d)"
else prow ok "[age]" "published ${PUBLISHED} - ${AGE}d ago (>= ${COOLDOWN_DAYS}d)"; fi
if [[ "$CVES_CSV" == "-" ]]; then prow bad "[cves]" "the notes name no CVE IDs"
else prow ok "[cves]" "named in the notes: ${CVES_CSV//,/, }"; fi
case "$HASH_STATE" in
  match)    prow ok "[sha256]" "${SUM} matches the $(jq -r '.sources | join(" and ")' <<<"$HASH_JSON")" ;;
  mismatch) prow bad "[sha256]" "${SUM} contradicts the release" ;;
  *)        prow unknown "[sha256]" "${SUM} is not published in the release" ;;
esac
case "$SIG_STATE" in
  same-signer)      prow ok "[signer]" "valid, same certificate as the installed version: $(who "$SIG_FILE")" ;;
  renewed)          prow warn "[signer]" "renewed: $(who "$SIG_FILE"), the installed version $(who "$SIG_REF")" ;;
  signer-changed|invalid) prow bad "[signer]" "$SIG_STATE" ;;
  *)                prow unknown "[signer]" "$SIG_STATE" ;;
esac
for r in ${REFUSE[@]+"${REFUSE[@]}"}; do prow bad "[REFUSE]" "$r"; done
for m in ${MISSING[@]+"${MISSING[@]}"}; do [[ "$INSIDE" == "true" ]] && prow unknown "[missing]" "$m"; done
# Recommendation wording is pinned by tests/run.sh: never "approved", never "safe".
case "$VERDICT" in
  refuse) prow bad "[VERDICT]" "REFUSE: do not install this file. Find out why it differs before anything else." ;;
  waiver-recommended) prow warn "[VERDICT]" "WAIVER RECOMMENDED, not granted: the evidence supports asking for a cooldown waiver. A person decides, confirms each CVE is fixed in this release, and records the CVE IDs, the SHA-256 and the signer in the install note (hardening-checklist.md section 5)." ;;
  hold) prow bad "[VERDICT]" "HOLD: wait out the ${COOLDOWN_DAYS}-day cooldown; the evidence for a waiver is incomplete." ;;
  ok) prow ok "[VERDICT]" "outside the cooldown, and nothing contradicts the file. The behavioural checks still apply." ;;
esac
if [[ "$PANEL" -eq 1 && "$__PANEL_OPEN" -eq 1 ]]; then
  case "$VERDICT" in
    refuse) h="critical" ;; ok) h="healthy" ;; *) h="warning" ;;
  esac
  { term_panel_vert; term_panel_close "${VERDICT} ${TERM_DOT} --json for data" "$(term_health "$h" "$VERDICT")"; } >&2
fi
exit "$RC"
