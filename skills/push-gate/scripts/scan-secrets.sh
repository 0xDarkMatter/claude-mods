#!/usr/bin/env bash
# scan-secrets.sh — Secret-scan a pending push diff via gitleaks + regex layer.
#
# Usage:   scan-secrets.sh <remote> <branch>
# Exit:    0 clean, 1 secret hit, 5 missing dep

set -euo pipefail

REMOTE="${1:?usage: scan-secrets.sh <remote> <branch>}"
BRANCH="${2:?usage: scan-secrets.sh <remote> <branch>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS_FILE="$SCRIPT_DIR/../references/secret-patterns.txt"

# ── Dep check ─────────────────────────────────────────────────────────────────
if ! command -v gitleaks >/dev/null 2>&1; then
  cat >&2 <<'EOF'
push-gate: gitleaks not installed.

Install:
  Windows (scoop):    scoop install gitleaks
  Windows (winget):   winget install gitleaks.gitleaks
  macOS:              brew install gitleaks
  Linux (apt):        apt install gitleaks
  Any platform:       https://github.com/gitleaks/gitleaks/releases
EOF
  exit 5
fi

if ! command -v rg >/dev/null 2>&1; then
  echo "push-gate: ripgrep (rg) not installed. See https://github.com/BurntSushi/ripgrep" >&2
  exit 5
fi

# ── Range to scan ─────────────────────────────────────────────────────────────
# Two cases:
#   (a) origin/<branch> exists  → diff range scan (incremental push)
#   (b) origin/<branch> missing → full branch scan (first push to new remote)
# The well-known empty-tree SHA lets us express "everything as added" for the
# regex layer's diff-based extraction without special-casing its plumbing.
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

if git rev-parse --verify "${REMOTE}/${BRANCH}" >/dev/null 2>&1; then
  RANGE="${REMOTE}/${BRANCH}..${BRANCH}"
  GITLEAKS_LOG_OPTS="$RANGE"
  DIFF_RANGE="$RANGE"
  COMMIT_COUNT="$(git rev-list --count "$RANGE")"
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "push-gate: nothing to push (${RANGE} is empty)."
    exit 0
  fi
  SCAN_LABEL="${COMMIT_COUNT} commits via gitleaks (${RANGE})"
else
  COMMIT_COUNT="$(git rev-list --count "$BRANCH")"
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "push-gate: branch ${BRANCH} has no commits."
    exit 0
  fi
  GITLEAKS_LOG_OPTS="$BRANCH"
  DIFF_RANGE="${EMPTY_TREE}..${BRANCH}"
  SCAN_LABEL="full branch — ${COMMIT_COUNT} commits via gitleaks (first push to new remote)"
fi

# ── Layer 1: gitleaks on the commit range ─────────────────────────────────────
echo "push-gate: scanning ${SCAN_LABEL}"
GITLEAKS_REPORT="$(mktemp -t gitleaks.XXXXXX.json)"
trap 'rm -f "$GITLEAKS_REPORT" "$DIFF_FILE" 2>/dev/null || true' EXIT

GITLEAKS_EXIT=0
gitleaks detect \
  --source . \
  --log-opts="$GITLEAKS_LOG_OPTS" \
  --report-format=json \
  --report-path="$GITLEAKS_REPORT" \
  --redact \
  --no-banner \
  --exit-code=1 \
  2>&1 || GITLEAKS_EXIT=$?

if [ "$GITLEAKS_EXIT" -ne 0 ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  SECRET DETECTED (gitleaks)"
  echo "═══════════════════════════════════════════════════════════════"
  if command -v jq >/dev/null 2>&1 && [ -s "$GITLEAKS_REPORT" ]; then
    jq -r '.[] | "  \(.RuleID) in \(.File):\(.StartLine) — \(.Description)"' "$GITLEAKS_REPORT" 2>/dev/null \
      || cat "$GITLEAKS_REPORT"
  else
    cat "$GITLEAKS_REPORT"
  fi
  echo ""
  echo "Refusing push. Remediate via one of:"
  echo "  1. If the secret is real: rotate it NOW, then rewrite history"
  echo "     (git filter-repo, BFG, or reset + re-commit)."
  echo "  2. If it is a false positive: add to .gitleaksignore at repo root"
  echo "     and commit, then re-run push-gate."
  exit 1
fi

# ── Layer 2: regex corpus on the diff ─────────────────────────────────────────
echo "push-gate: regex layer on added lines"
DIFF_FILE="$(mktemp -t push-gate-diff.XXXXXX)"
# Exclude push-gate's own pattern corpus — it contains examples of every
# secret shape it's trying to detect, so scanning it matches everything.
# (Classic snake-eating-tail when push-gate is part of the pushed content.)
git diff "$DIFF_RANGE" -- . \
  ':(exclude,glob)**/push-gate/references/secret-patterns.txt' \
  > "$DIFF_FILE"

# Extract added lines only (strip the leading '+'), ignore file-header lines
ADDED_FILE="$(mktemp -t push-gate-added.XXXXXX)"
grep -E '^\+' "$DIFF_FILE" | grep -vE '^\+\+\+ ' | sed 's/^+//' > "$ADDED_FILE" || true

# Load patterns (skip blanks/comments)
PATTERN_ARGS=()
while IFS= read -r line; do
  case "$line" in
    ''|\#*) continue ;;
    *) PATTERN_ARGS+=(-e "$line") ;;
  esac
done < "$PATTERNS_FILE"

# Run ripgrep with all patterns; capture matches
RAW_HITS="$(rg --no-filename --line-number --no-heading "${PATTERN_ARGS[@]}" "$ADDED_FILE" 2>/dev/null || true)"

# Filter common false positives.
# Note: the `\.\.\.'` ellipsis-apostrophe patterns were removed because they
# required an embedded `'` inside a bash single-quoted string, which closes
# the string early and breaks the regex ("Unmatched ( or \("). The remaining
# patterns (placeholder/example/getenv/etc) cover the bulk of false positives.
FILTERED_HITS="$(
  printf '%s\n' "$RAW_HITS" \
    | grep -viE '(example|placeholder|\<dummy\>|\<fake\>|\<TODO\>|<unset>|os\.environ|process\.env|getenv|\$\{[A-Z_]+:-|\$\{[A-Z_]+\}|\$\([A-Z_]+\)|\$env:[A-Z_]+|\.\.\.<)' \
    || true
)"

# Drop blank lines
FILTERED_HITS="$(printf '%s\n' "$FILTERED_HITS" | grep -v '^$' || true)"

rm -f "$ADDED_FILE" "$DIFF_FILE"

if [ -n "$FILTERED_HITS" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  SECRET-PATTERN MATCH (regex layer)"
  echo "═══════════════════════════════════════════════════════════════"
  printf '%s\n' "$FILTERED_HITS" | head -40
  echo ""
  echo "Refusing push. These are added lines matching secret-shape patterns."
  echo "Each match must be confirmed safe (placeholder/reference) or redacted"
  echo "via history rewrite. See SKILL.md §False-positive handling."
  exit 1
fi

echo "push-gate: secret scan CLEAN (gitleaks + regex layer)"
exit 0
