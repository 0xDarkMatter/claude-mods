#!/usr/bin/env bash
# preflight.sh — Full pre-push gate orchestration.
#
# Usage:   preflight.sh <remote> <branch>
# Exit codes:
#   0  all gates passed; ready to push
#   1  secret hit (gitleaks or regex)
#   2  forbidden file added
#   3  dirty working tree
#   4  non-ff divergence
#   5  missing dep (gitleaks / rg)
#   6  bad invocation (missing remote/branch or unknown remote)

set -euo pipefail

REMOTE="${1:-}"
BRANCH="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$REMOTE" ] || [ -z "$BRANCH" ]; then
  echo "push-gate: usage: preflight.sh <remote> <branch>" >&2
  exit 6
fi

divider() { printf '%.0s─' $(seq 1 63); echo; }

echo "push-gate preflight :: target = ${REMOTE}/${BRANCH}"
divider

# ── Step 1–2: verify remote, fetch ────────────────────────────────────────────
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "STEP 1  FAIL  remote '${REMOTE}' not configured"
  echo "          configured remotes:"
  git remote -v | sed 's/^/            /'
  exit 6
fi
REMOTE_URL="$(git remote get-url "$REMOTE")"
echo "STEP 1  OK    remote '${REMOTE}' = ${REMOTE_URL}"

# Reject local-path remotes (use `git push . HEAD:main` pattern directly, no gate needed)
case "$REMOTE_URL" in
  /*|[A-Za-z]:*|\.*|file:*)
    echo "STEP 1  INFO  '${REMOTE}' looks local-filesystem; push-gate is for network remotes"
    echo "          proceeding anyway (you can skip the gate for local updateInstead pushes)"
    ;;
esac

echo "STEP 2  RUN   git fetch ${REMOTE}"
if ! git fetch "$REMOTE" "$BRANCH" 2>&1 | sed 's/^/          /'; then
  echo "STEP 2  WARN  fetch failed; proceeding with cached ${REMOTE}/${BRANCH} ref"
fi

# ── Step 3: clean working tree ────────────────────────────────────────────────
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ]; then
  echo "STEP 3  FAIL  working tree dirty:"
  printf '%s\n' "$DIRTY" | head -20 | sed 's/^/            /'
  exit 3
fi
echo "STEP 3  OK    working tree clean"

# ── Step 4: pending commits ───────────────────────────────────────────────────
if ! git rev-parse --verify "${REMOTE}/${BRANCH}" >/dev/null 2>&1; then
  echo "STEP 4  INFO  ${REMOTE}/${BRANCH} does not exist yet (new remote branch)"
  COMMIT_COUNT="$(git rev-list --count "$BRANCH")"
  echo "          ${COMMIT_COUNT} commits will be pushed (creating the remote branch)"
else
  RANGE="${REMOTE}/${BRANCH}..${BRANCH}"
  COMMIT_COUNT="$(git rev-list --count "$RANGE")"
  echo "STEP 4  OK    ${COMMIT_COUNT} commits pending"
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "          nothing to push; exiting cleanly"
    exit 0
  fi
  git log --oneline "$RANGE" | head -20 | sed 's/^/            /'
  if [ "$COMMIT_COUNT" -gt 20 ]; then
    echo "            … and $((COMMIT_COUNT - 20)) more"
  fi

  # ── Step 5: divergence ──────────────────────────────────────────────────────
  BEHIND="$(git rev-list --count "${BRANCH}..${REMOTE}/${BRANCH}")"
  if [ "$BEHIND" -gt 0 ]; then
    echo "STEP 5  FAIL  non-ff: ${REMOTE}/${BRANCH} has ${BEHIND} commits not in local ${BRANCH}"
    echo "          rebase or merge first: git fetch ${REMOTE} && git rebase ${REMOTE}/${BRANCH}"
    exit 4
  fi
  echo "STEP 5  OK    clean fast-forward (local is strictly ahead)"
fi

divider

# ── Step 6: secret scan ───────────────────────────────────────────────────────
SCAN_EXIT=0
bash "$SCRIPT_DIR/scan-secrets.sh" "$REMOTE" "$BRANCH" || SCAN_EXIT=$?
if [ "$SCAN_EXIT" -ne 0 ]; then
  echo "STEP 6  FAIL  secret scan (exit=$SCAN_EXIT)"
  exit "$SCAN_EXIT"
fi
echo "STEP 6  OK    secret scan clean"

# ── Step 7: forbidden files ───────────────────────────────────────────────────
# Files that should never ship to a remote. Matched against added-file paths.
# Gitignore-style patterns would be nicer; for now, a small explicit list.
FORBIDDEN_REGEX='(^|/)\.env(\.|$)|(^|/)\.env\.(local|development|production|test)$|\.(pem|key|pfx|p12|asc|ppk|id_rsa|id_ed25519|id_ecdsa|id_dsa)$|(^|/)\.aws/credentials$|(^|/)\.ssh/(id_|config)|(^|/)\.claude/worktrees/|(^|/)secrets?\.(json|ya?ml|toml|ini)$'

if git rev-parse --verify "${REMOTE}/${BRANCH}" >/dev/null 2>&1; then
  ADDED_FILES="$(git diff --name-only --diff-filter=A "${REMOTE}/${BRANCH}..${BRANCH}")"
else
  ADDED_FILES="$(git ls-tree -r --name-only "$BRANCH")"
fi

FORBIDDEN_HITS="$(printf '%s\n' "$ADDED_FILES" | grep -iE "$FORBIDDEN_REGEX" || true)"
if [ -n "$FORBIDDEN_HITS" ]; then
  echo "STEP 7  FAIL  forbidden files in push:"
  printf '%s\n' "$FORBIDDEN_HITS" | sed 's/^/            /'
  echo "          if any are genuinely needed on the remote, remove them from"
  echo "          the push (git rm --cached) or relax the FORBIDDEN_REGEX in"
  echo "          scripts/preflight.sh — the default is intentionally strict."
  exit 2
fi
echo "STEP 7  OK    no forbidden file paths"

# ── Step 8: size advisory ─────────────────────────────────────────────────────
DIFF_BYTES=0
if git rev-parse --verify "${REMOTE}/${BRANCH}" >/dev/null 2>&1; then
  DIFF_BYTES="$(git diff --stat="10000,10000,10000" "${REMOTE}/${BRANCH}..${BRANCH}" \
    | tail -1 | awk '{print $4 + $6}' 2>/dev/null || echo 0)"
fi

if [ "$COMMIT_COUNT" -gt 50 ]; then
  echo "STEP 8  WARN  ${COMMIT_COUNT} commits in one push (>50). Consider whether"
  echo "          this should be split into logical pushes for reviewability."
elif [ "$COMMIT_COUNT" -gt 10 ]; then
  echo "STEP 8  INFO  ${COMMIT_COUNT} commits (moderate batch)"
else
  echo "STEP 8  OK    ${COMMIT_COUNT} commits"
fi

divider
echo "push-gate: ALL GATES PASSED"
echo ""
echo "Ready to push:"
echo "  git push ${REMOTE} ${BRANCH}"
echo ""
echo "push-gate does not execute the push itself. Run it explicitly to"
echo "preserve 'two-human-steps' separation between gate and action."
exit 0
