#!/usr/bin/env bash
# Classify a failed PyPI publish — name the cause and the exact fix.
#
# Reads a GitHub Actions run log (by run-id via `gh`, or piped on stdin) and
# matches it against the known PyPI-publish failure classes, so the agent acts on
# a named cause instead of re-reading a 2,000-line log. Prints the OIDC claims the
# run presented when the failure is a publisher mismatch.
#
# Usage:   diagnose-publish.sh <run-id> | diagnose-publish.sh -   [--json] [--repo OWNER/REPO]
# Input:   a numeric run-id (resolved with `gh run view --log-failed`), OR "-" to
#          read a log from stdin
# Output:  stdout = the classified finding (text, or --json envelope)
# Stderr:  progress, the human explanation
# Exit:    0 no failure recognised (clean/unknown), 2 usage, 5 missing-dep (gh),
#          7 gh/run unavailable, 10 a known failure class was identified
#
# Examples:
#   diagnose-publish.sh 27662335544 --repo 0xDarkMatter/flarecrawl
#   gh run view 27662335544 --log-failed | diagnose-publish.sh -
#   diagnose-publish.sh 27662335544 --json | jq '.data.fix'

set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_MISSING_DEP=5; EXIT_UNAVAIL=7; EXIT_FOUND=10

JSON=0; REPO=""; SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON=1 ;;
    --repo)  REPO="${2:-}"; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -)       SRC="stdin" ;;
    -*)      echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)       SRC="$1" ;;
  esac
  shift
done
[[ -z "$SRC" ]] && { echo "ERROR: give a run-id or '-' for stdin (try --help)" >&2; exit "$EXIT_USAGE"; }

# --- obtain the log ------------------------------------------------------------
LOG=""
if [[ "$SRC" == "stdin" ]]; then
  LOG="$(cat)"
else
  [[ "$SRC" =~ ^[0-9]+$ ]] || { echo "ERROR: run-id must be numeric (or '-' for stdin)" >&2; exit "$EXIT_USAGE"; }
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required to fetch a run by id (or pipe a log with '-')" >&2; exit "$EXIT_MISSING_DEP"; }
  GHARGS=(run view "$SRC" --log-failed)
  [[ -n "$REPO" ]] && GHARGS+=(--repo "$REPO")
  LOG="$(gh "${GHARGS[@]}" 2>/dev/null)" || { echo "ERROR: could not fetch run $SRC (auth? wrong --repo? run still in progress?)" >&2; exit "$EXIT_UNAVAIL"; }
fi
[[ -n "$LOG" ]] || { echo "ERROR: empty log" >&2; exit "$EXIT_UNAVAIL"; }

# --- classify ------------------------------------------------------------------
CLASS=""; SUMMARY=""; FIX=""; CLAIMS=""
has() { grep -qiE "$1" <<<"$LOG"; }

if has 'invalid-publisher|Trusted publishing exchange failure|no corresponding publisher|Publisher with matching claims was not found'; then
  CLASS="PENDING_PUBLISHER"
  SUMMARY="OIDC token was valid but PyPI has no Trusted Publisher matching the run's claims."
  FIX="Register a publisher at https://pypi.org/manage/account/publishing/ — for a FIRST publish use a *pending publisher* (the project doesn't exist yet). Match all claims: Owner, Repository, Workflow filename, Environment. Then re-run the failed job (gh run rerun <id> --failed)."
  # surface the claims block the action prints, for field-by-field comparison
  # strip the gh-log column prefix (".*\t"), the "* " bullet, and backticks
  CLAIMS="$(grep -iE '`?(sub|repository|repository_owner|workflow_ref|environment)`?[[:space:]]*:' <<<"$LOG" \
    | sed -E 's/.*\t//; s/^[^A-Za-z`]*//; s/`//g; s/[[:space:]]+$//' | sort -u | head -8)"
elif has 'File already exists|filename has already been used|already exists on|400 Bad Request.*[Rr]eupload'; then
  CLASS="VERSION_EXISTS"
  SUMMARY="The version is already on PyPI. Uploads are immutable — a version can never be re-published, even after deletion."
  FIX="Bump the version in pyproject.toml (and __init__/lock), commit, re-tag, push. Do NOT reuse the number. For a transient artifact mix-up, 'skip-existing: true' tolerates partial re-uploads but never replaces a file."
elif has 'environment.*not allowed|environment.*is not defined|environment.*not found'; then
  CLASS="ENV_MISMATCH"
  SUMMARY="The publisher claim names an environment the publish job does not declare (or vice-versa)."
  FIX="Make the job's 'environment:' value equal the Trusted Publisher's 'Environment name' claim on PyPI exactly (e.g. both 'pypi'). They are matched verbatim."
elif has '403 Forbidden|Invalid or non-existent authentication|isn.t allowed to upload|Non-user identities cannot create new projects'; then
  CLASS="AUTH_FORBIDDEN"
  SUMMARY="PyPI refused the credential (403). Either a token is wrong/expired, or an OIDC identity is uploading to a project it isn't trusted for."
  FIX="Prefer OIDC: confirm the Trusted Publisher exists for THIS project/workflow/environment. If using a token, rotate it and re-store the secret; ensure its scope includes this project. New project via OIDC needs a pending publisher first."
elif has 'id-token.*write|OIDC.*not|aud claim|token request failed' && ! has 'invalid-publisher'; then
  CLASS="OIDC_CONFIG"
  SUMMARY="The OIDC token exchange itself failed (permissions or audience), before publisher matching."
  FIX="Ensure the publish job has 'permissions: id-token: write' and 'contents: read', and that it runs gh-action-pypi-publish with no 'password:'. Trusted publishing must not be mixed with a token."
elif has 'twine.*check.*fail|InvalidDistribution|Metadata is missing|long_description'; then
  CLASS="METADATA_INVALID"
  SUMMARY="Artifact metadata failed validation (twine check) before upload."
  FIX="Fix the packaging metadata (README content-type, required fields, classifiers), rebuild, and re-run 'twine check dist/*' locally until clean."
else
  echo "No recognised PyPI-publish failure pattern in the log." >&2
  echo "Inspect manually — common non-publish causes: pip-audit CVE gate, build error, lock drift (uv sync --locked)." >&2
  if [[ "$JSON" -eq 1 ]]; then
    echo '{"data":{"class":"UNKNOWN","summary":"no known publish failure pattern matched","fix":null},"meta":{"schema":"claude-mods.pypi-ops.diagnose-publish/v1","found":false}}'
  fi
  exit "$EXIT_OK"
fi

# --- output --------------------------------------------------------------------
if [[ "$JSON" -eq 1 ]]; then
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg c "$CLASS" --arg s "$SUMMARY" --arg f "$FIX" --arg cl "$CLAIMS" \
      '{data:{class:$c, summary:$s, fix:$f, presented_claims:($cl|if length>0 then split("\n") else [] end)},
        meta:{schema:"claude-mods.pypi-ops.diagnose-publish/v1", found:true}}'
  else
    printf '{"data":{"class":"%s","found":true}}\n' "$CLASS"
    echo "WARN: jq missing; emitted minimal JSON" >&2
  fi
else
  printf '%s\n' "$CLASS"
  echo "  cause: $SUMMARY" >&2
  echo "  fix:   $FIX" >&2
  [[ -n "$CLAIMS" ]] && { echo "  claims the run presented (match these on PyPI):" >&2; sed 's/^/    /' <<<"$CLAIMS" >&2; }
fi
exit "$EXIT_FOUND"
