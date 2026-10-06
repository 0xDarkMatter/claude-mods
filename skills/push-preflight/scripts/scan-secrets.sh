#!/usr/bin/env bash
# scan-secrets.sh — Secret-scan a pending push diff via gitleaks + regex layer.
# push-preflight Step 6. Scans only <remote>/<branch>..<branch> (the commits
# about to leave), never full history — history audits belong to security-ops.
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
push-preflight: gitleaks not installed.

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
  echo "push-preflight: ripgrep (rg) not installed. See https://github.com/BurntSushi/ripgrep" >&2
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
    echo "push-preflight: nothing to push (${RANGE} is empty)."
    exit 0
  fi
  SCAN_LABEL="${COMMIT_COUNT} commits via gitleaks (${RANGE})"
else
  COMMIT_COUNT="$(git rev-list --count "$BRANCH")"
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "push-preflight: branch ${BRANCH} has no commits."
    exit 0
  fi
  GITLEAKS_LOG_OPTS="$BRANCH"
  DIFF_RANGE="${EMPTY_TREE}..${BRANCH}"
  SCAN_LABEL="full branch — ${COMMIT_COUNT} commits via gitleaks (first push to new remote)"
fi

# ── Layer 1: gitleaks on the commit range ─────────────────────────────────────
echo "push-preflight: scanning ${SCAN_LABEL}"
GITLEAKS_REPORT="$(mktemp -t gitleaks.XXXXXX.json)"
DIFF_FILE="" ADDED_FILE="" PATHS_FILE=""
trap 'rm -f "$GITLEAKS_REPORT" "$DIFF_FILE" "$ADDED_FILE" "$PATHS_FILE" 2>/dev/null || true' EXIT

# Config: default rule set + allowlist for public-by-design tokens (e.g. Mapbox pk.*).
# Guarded so the scan still runs with the built-in default config if it's absent.
GL_PUBTOKEN_CFG="$SCRIPT_DIR/../references/gitleaks-config.toml"
GL_CONFIG_ARG=()
[ -f "$GL_PUBTOKEN_CFG" ] && GL_CONFIG_ARG=(--config "$GL_PUBTOKEN_CFG")

GITLEAKS_EXIT=0
gitleaks detect \
  --source . \
  "${GL_CONFIG_ARG[@]}" \
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
  echo "     and commit, then re-run push-preflight."
  exit 1
fi

# ── Layer 2: regex corpus on the diff ─────────────────────────────────────────
echo "push-preflight: regex layer on added lines"
DIFF_FILE="$(mktemp -t push-preflight-diff.XXXXXX)"
# Exclude this skill's own pattern corpus — it contains examples of every
# secret shape it's trying to detect, so scanning it matches everything.
# (Classic snake-eating-tail when the skill is part of the pushed content.)
# Both directory names are excluded: repos that vendor the skill may still
# carry it under its pre-rename name, push-gate.
# Same for the allowlists: their entries are regexes of confirmed-safe hits,
# which by construction resemble the shapes the corpus matches. Only the
# regex pass skips them — the gitleaks layer still scans the allowlist files.
git diff "$DIFF_RANGE" -- . \
  ':(exclude,glob)**/push-preflight/references/secret-patterns.txt' \
  ':(exclude,glob)**/push-gate/references/secret-patterns.txt' \
  ':(exclude,top).push-preflight-allow' \
  ':(exclude,top).pushgate-allow' \
  > "$DIFF_FILE"

# Extract added lines, keeping per-line file attribution: ADDED_FILE holds the
# content ('+' stripped, trailing CR dropped for CRLF checkouts), PATHS_FILE the
# repo-relative path each line was added to — same line count, same order.
# Attribution is what lets an allowlist entry scope an allow to one file
# instead of the whole diff.
ADDED_FILE="$(mktemp -t push-preflight-added.XXXXXX)"
PATHS_FILE="$(mktemp -t push-preflight-paths.XXXXXX)"
awk -v added="$ADDED_FILE" -v paths="$PATHS_FILE" '
  /^\+\+\+ / {
    p = substr($0, 5)
    gsub(/^"|"$/, "", p)          # git quotes paths containing special chars
    sub(/^b\//, "", p)
    path = (p == "/dev/null") ? "" : p
    next
  }
  /^\+/ {
    l = substr($0, 2)
    sub(/\r$/, "", l)
    print l > added
    print path > paths
  }
' "$DIFF_FILE"

# Load patterns (skip blanks/comments)
PATTERN_ARGS=()
while IFS= read -r line; do
  case "$line" in
    ''|\#*) continue ;;
    *) PATTERN_ARGS+=(-e "$line") ;;
  esac
done < "$PATTERNS_FILE"

# Run ripgrep with all patterns; line numbers index into PATHS_FILE
RAW_HITS="$(rg --no-filename --line-number --no-heading "${PATTERN_ARGS[@]}" "$ADDED_FILE" 2>/dev/null || true)"

# Common false positives, filtered before the allowlist is consulted.
# Note: the `\.\.\.'` ellipsis-apostrophe patterns were removed because they
# required an embedded `'` inside a bash single-quoted string, which closes
# the string early and breaks the regex ("Unmatched ( or \("). The remaining
# patterns (placeholder/example/getenv/etc) cover the bulk of false positives.
FP_FILTER='(example|placeholder|\<dummy\>|\<fake\>|\<TODO\>|<unset>|os\.environ|process\.env|getenv|\$\{[A-Z_]+:-|\$\{[A-Z_]+\}|\$\([A-Z_]+\)|\$env:[A-Z_]+|\.\.\.<|pk\.eyJ[A-Za-z0-9_-]{6,})'

# ── Repo-local allowlist (.push-preflight-allow) ──────────────────────────────
# Committed at the scanned repo's root, mirroring gitleaks' .gitleaksignore.
# Entry format (one per line):   <repo-relative-path>:<line-regex>
#   - split on the FIRST ':' — the path portion must not contain ':' (git's
#     repo-relative paths never do on Windows; avoid them elsewhere)
#   - <line-regex> is Rust-regex matched against the full added-line content;
#     no line numbers anywhere — they drift, a content anchor does not
#   - '#' comment lines allowed; each entry must carry a reason comment
#     directly above it (warned when missing, not gated)
# An entry only suppresses regex-layer hits in that exact file. Any hit NOT
# allowlisted still refuses. Entries that no longer match any line of their
# file at the branch tip are reported as stale (warning, non-gating).
#
# Legacy name: .pushgate-allow, from before the skill was renamed push-gate ->
# push-preflight. Other repos have it committed, so it is still read, with a
# one-line deprecation notice on stderr. When BOTH files exist their entries
# are COMBINED, never ranked: each entry is a reviewed, committed decision
# whichever file holds it, so a half-finished migration must not start
# refusing pushes that passed before, and a precedence rule would leave the
# losing file's entries silently dead. Retiring the fallback is a breaking
# change for those repos — CHANGELOG it.
TOPLEVEL="$(git rev-parse --show-toplevel)"
ALLOW_NAME=".push-preflight-allow"
LEGACY_ALLOW_NAME=".pushgate-allow"
ALLOW_SRCS=()     # which allowlist file each entry came from (for warnings)
ALLOW_PATHS=()
ALLOW_REGEXES=()

if [ -f "$TOPLEVEL/$LEGACY_ALLOW_NAME" ]; then
  if [ -f "$TOPLEVEL/$ALLOW_NAME" ]; then
    echo "push-preflight: DEPRECATED ${LEGACY_ALLOW_NAME} - move its entries into ${ALLOW_NAME} (both are read now; entries combined)" >&2
  else
    echo "push-preflight: DEPRECATED ${LEGACY_ALLOW_NAME} - rename it to ${ALLOW_NAME} (still read for now)" >&2
  fi
fi

for src in "$ALLOW_NAME" "$LEGACY_ALLOW_NAME"; do
  [ -f "$TOPLEVEL/$src" ] || continue
  prev_comment=0
  allow_lineno=0
  while IFS= read -r al || [ -n "$al" ]; do
    allow_lineno=$((allow_lineno + 1))
    al="${al%$'\r'}"
    case "$al" in
      '') continue ;;
      \#*) prev_comment=1; continue ;;
    esac
    case "$al" in
      *:*) : ;;
      *)
        echo "push-preflight: WARN ${src}:${allow_lineno} malformed (want <path>:<regex>): $al" >&2
        prev_comment=0
        continue
        ;;
    esac
    if [ "$prev_comment" -eq 0 ]; then
      echo "push-preflight: WARN ${src}:${allow_lineno} entry has no reason comment above it: ${al%%:*}" >&2
    fi
    prev_comment=0
    ALLOW_SRCS+=("$src")
    ALLOW_PATHS+=("${al%%:*}")
    ALLOW_REGEXES+=("${al#*:}")
  done < "$TOPLEVEL/$src"
done

# Stale-entry check against the branch tip (not just this diff): an entry
# whose file is gone, or whose regex matches no line of that file anymore,
# documents a hit that was since removed — prune it. A malformed regex also
# lands here (rg errors are treated as no-match).
for i in "${!ALLOW_PATHS[@]}"; do
  ap="${ALLOW_PATHS[$i]}"; ar="${ALLOW_REGEXES[$i]}"; as="${ALLOW_SRCS[$i]}"
  if ! git cat-file -e "${BRANCH}:${ap}" 2>/dev/null; then
    echo "push-preflight: WARN stale ${as} entry — ${ap} does not exist at ${BRANCH} tip"
  elif ! git show "${BRANCH}:${ap}" 2>/dev/null | rg -e "$ar" >/dev/null 2>&1; then
    echo "push-preflight: WARN stale ${as} entry — no line in ${ap} matches: ${ar}"
  fi
done

# ── Per-hit verdicts: FP filter → allowlist → refuse ─────────────────────────
FILTERED_HITS=""
SUGGESTIONS=""
if [ -n "$RAW_HITS" ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    n="${hit%%:*}"
    content="${hit#*:}"
    if grep -qiE "$FP_FILTER" <<<"$content"; then
      continue
    fi
    hit_path="$(sed -n "${n}p" "$PATHS_FILE")"
    allowed=0
    for i in "${!ALLOW_PATHS[@]}"; do
      if [ "$hit_path" = "${ALLOW_PATHS[$i]}" ] \
         && rg -e "${ALLOW_REGEXES[$i]}" >/dev/null 2>&1 <<<"$content"; then
        allowed=1
        break
      fi
    done
    [ "$allowed" -eq 1 ] && continue
    FILTERED_HITS+="${hit_path}: ${content}"$'\n'
    # Ready-made anchored allowlist entry: escape Rust-regex metacharacters in
    # the line content so the suggestion matches it literally and exactly.
    esc="$(sed 's/[][\\.^$*+?(){}|]/\\&/g' <<<"$content")"
    SUGGESTIONS+="  ${hit_path}:^${esc}"'$'$'\n'
  done <<<"$RAW_HITS"
fi

rm -f "$ADDED_FILE" "$PATHS_FILE" "$DIFF_FILE"

if [ -n "$FILTERED_HITS" ]; then
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  SECRET-PATTERN MATCH (regex layer)"
  echo "═══════════════════════════════════════════════════════════════"
  printf '%s' "$FILTERED_HITS" | head -40
  echo ""
  echo "Refusing push. These are added lines matching secret-shape patterns."
  echo "If a hit is a REAL secret: rotate it now, then rewrite history."
  echo "If a hit is confirmed safe (test fixture, deliberate example), add an"
  echo "entry to .push-preflight-allow at the repo root with a reason comment"
  echo "above it, commit, and re-run push-preflight. Ready-made entries:"
  echo ""
  echo "  # reason: <why this line is not a live credential>"
  printf '%s' "$SUGGESTIONS" | awk '!seen[$0]++'
  echo ""
  echo "See SKILL.md §False-positive handling."
  exit 1
fi

echo "push-preflight: secret scan CLEAN (gitleaks + regex layer)"
exit 0
