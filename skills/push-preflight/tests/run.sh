#!/usr/bin/env bash
# Behavioural self-test for push-preflight's secret scanner and push scope.
# Fully offline: a local bare repo stands in for the remote.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SOURCE_SCANNER="$SKILL/scripts/scan-secrets.sh"
SCANNER="$SOURCE_SCANNER"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
PASS=0
FAIL=0
SECRETS_CAUGHT=0

# Use byte-identical scripts in a temporary skill mirror, normalising only the
# regex corpus so Git-for-Windows CRLF checkouts behave like Ubuntu CI.
mkdir -p "$SB/skill/scripts" "$SB/skill/references"
cp "$SOURCE_SCANNER" "$SB/skill/scripts/scan-secrets.sh"
cp "$SKILL/references/secret-patterns.txt" "$SB/skill/references/secret-patterns.txt"
sed -i 's/\r$//' "$SB/skill/references/secret-patterns.txt"
cp "$SKILL/references/gitleaks-config.toml" "$SB/skill/references/gitleaks-config.toml"
for helper in "$SKILL"/scripts/*.sh; do
  [ "$helper" = "$SOURCE_SCANNER" ] || cp "$helper" "$SB/skill/scripts/"
done
SCANNER="$SB/skill/scripts/scan-secrets.sh"
PREFLIGHT="$SB/skill/scripts/preflight.sh"

ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() {
  if [[ "$2" == "$3" ]]; then ok "$1 (exit $3)"; else no "$1 (want $2 got $3)"; fi
}
expect_has() {
  case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac
}

mkdir -p "$SB/bin"
cat > "$SB/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SB/bin/gitleaks"
STUB_PATH="$SB/bin:$PATH"

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name push-preflight-test
  git -C "$repo" config user.email push-preflight-test@example.invalid
  printf '%s\n' 'baseline' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m 'test: baseline'
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

commit_file() {
  local repo="$1" content="$2"
  printf '%s\n' "$content" > "$repo/candidate.txt"
  git -C "$repo" add candidate.txt
  git -C "$repo" commit -q -m 'test: add candidate'
}

scan_stubbed() {
  local repo="$1" output_file="$2" branch="${3:-main}"
  (cd "$repo" && TMPDIR="$SB" PATH="$STUB_PATH" bash "$SCANNER" origin "$branch") >"$output_file" 2>&1
}

expect_lacks() {
  case "$3" in *"$2"*) no "$1 (unexpected '$2')";; *) ok "$1";; esac
}

# A repo whose origin is a real bare remote, so the remote-tracking refs are
# exactly what a push has published (unlike new_repo's hand-set origin/main).
# Nothing is pushed yet: an empty remote has no refs at all.
new_remote_repo() {
  local repo="$1"
  git init -q --bare -b main "$repo.remote.git"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name push-preflight-test
  git -C "$repo" config user.email push-preflight-test@example.invalid
  git -C "$repo" remote add origin "$repo.remote.git"
}

commit_path() {
  local repo="$1" path="$2" content="$3"
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "test: add $path"
}

# origin/main already holds <path> with <content>, published by an earlier PR.
published_main() {
  local repo="$1" path="$2" content="$3"
  new_remote_repo "$repo"
  commit_path "$repo" README.md 'baseline'
  commit_path "$repo" "$path" "$content"
  git -C "$repo" push -q origin main 2>/dev/null
}

echo "=== push-preflight behavioural self-test ==="

echo "-- contract --"
bash -n "$SCANNER" 2>/dev/null && ok "bash -n scan-secrets.sh" || no "bash -n scan-secrets.sh"

echo "-- clean diff --"
repo="$SB/clean"
new_repo "$repo"
commit_file "$repo" 'message = "ordinary configuration"'
scan_stubbed "$repo" "$SB/clean.out"; rc=$?
expect_exit "clean committed diff reports clean" 0 "$rc"
expect_has "clean verdict is reported" "secret scan CLEAN" "$(cat "$SB/clean.out")"

echo "-- planted secrets --"
names=("AWS access key" "generic password" "private-key header" "high-entropy token")
values=(
  "$(printf '%s%s' 'AKIA' 'IOSFODNN7EXAMPLZ')"
  "$(printf '%s%s%s' 'password = "correct-' 'horse-battery-staple' '"')"
  "$(printf '%s%s' '-----BEGIN RSA ' 'PRIVATE KEY-----')"
  "$(printf '%s%s' 'sk-' 'abcdefghijklmnopqrstuvwxyz0123456789')"
)

for i in "${!names[@]}"; do
  repo="$SB/secret-$i"
  new_repo "$repo"
  commit_file "$repo" "${values[$i]}"
  scan_stubbed "$repo" "$SB/secret-$i.out"; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q "SECRET-PATTERN MATCH" "$SB/secret-$i.out"; then
    SECRETS_CAUGHT=$((SECRETS_CAUGHT + 1))
    ok "${names[$i]} is caught by regex layer"
  else
    no "${names[$i]} is caught by regex layer (exit $rc)"
    sed 's/^/        /' "$SB/secret-$i.out"
  fi
done

echo "-- false-positive filter --"
repo="$SB/false-positives"
new_repo "$repo"
printf '%s\n' \
  'password = os.environ["PW"]' \
  'password = "..."' \
  'password = "${PASSWORD:-change-me-now}"' > "$repo/candidate.txt"
git -C "$repo" add candidate.txt
git -C "$repo" commit -q -m 'test: add references'
scan_stubbed "$repo" "$SB/false-positives.out"; rc=$?
expect_exit "env reference, placeholder, and shell fallback stay clean" 0 "$rc"

echo "-- repo-local allowlist (.push-preflight-allow) --"
secret_line="$(printf '%s%s' 'sk-' 'abcdefghijklmnopqrstuvwxyz0123456789')"

# Allowlisted hit in the right file → clean
repo="$SB/allow-hit"
new_repo "$repo"
printf '%s\n' \
  '# reason: test fixture token, not a live credential' \
  "candidate.txt:^${secret_line}\$" > "$repo/.push-preflight-allow"
printf '%s\n' "$secret_line" > "$repo/candidate.txt"
git -C "$repo" add .push-preflight-allow candidate.txt
git -C "$repo" commit -q -m 'test: allowlisted fixture'
scan_stubbed "$repo" "$SB/allow-hit.out"; rc=$?
expect_exit "allowlisted hit reports clean" 0 "$rc"
expect_has "allowlisted verdict is CLEAN" "secret scan CLEAN" "$(cat "$SB/allow-hit.out")"

# Entry scoped to another file → hit still refuses, and a ready-made entry is suggested
repo="$SB/allow-scope"
new_repo "$repo"
printf '%s\n' \
  '# reason: entry deliberately points at a different file' \
  "other.txt:^${secret_line}\$" > "$repo/.push-preflight-allow"
printf '%s\n' "$secret_line" > "$repo/candidate.txt"
printf '%s\n' 'nothing to see' > "$repo/other.txt"
git -C "$repo" add .push-preflight-allow candidate.txt other.txt
git -C "$repo" commit -q -m 'test: mis-scoped allowlist'
scan_stubbed "$repo" "$SB/allow-scope.out"; rc=$?
expect_exit "entry for another file does not suppress the hit" 1 "$rc"
expect_has "refusal names the hit file" "candidate.txt: " "$(cat "$SB/allow-scope.out")"
expect_has "refusal suggests a ready-made entry" "candidate.txt:^" "$(cat "$SB/allow-scope.out")"
expect_has "mis-scoped entry is reported stale" "stale .push-preflight-allow entry" "$(cat "$SB/allow-scope.out")"

# Stale entry (file gone) on an otherwise clean push → clean exit + warning
repo="$SB/allow-stale"
new_repo "$repo"
printf '%s\n' \
  '# reason: file was deleted after this entry was added' \
  'ghost.txt:^never-matches\$' > "$repo/.push-preflight-allow"
printf '%s\n' 'message = "ordinary configuration"' > "$repo/candidate.txt"
git -C "$repo" add .push-preflight-allow candidate.txt
git -C "$repo" commit -q -m 'test: stale allowlist entry'
scan_stubbed "$repo" "$SB/allow-stale.out"; rc=$?
expect_exit "stale entry does not gate a clean push" 0 "$rc"
expect_has "stale entry is warned about" "stale .push-preflight-allow entry" "$(cat "$SB/allow-stale.out")"

# Entry without a reason comment → warned, still honoured
repo="$SB/allow-noreason"
new_repo "$repo"
printf '%s\n' "candidate.txt:^${secret_line}\$" > "$repo/.push-preflight-allow"
printf '%s\n' "$secret_line" > "$repo/candidate.txt"
git -C "$repo" add .push-preflight-allow candidate.txt
git -C "$repo" commit -q -m 'test: entry without reason'
scan_stubbed "$repo" "$SB/allow-noreason.out"; rc=$?
expect_exit "comment-less entry still suppresses its hit" 0 "$rc"
expect_has "missing reason comment is warned about" "no reason comment" "$(cat "$SB/allow-noreason.out")"

echo "-- legacy allowlist name (.pushgate-allow, pre-rename) --"
# Repos committed .pushgate-allow before the skill was renamed from push-gate.
# It must keep suppressing its hits (a rename must not start refusing pushes
# that passed yesterday) and must say, on stderr, that it is deprecated.
repo="$SB/allow-legacy"
new_repo "$repo"
printf '%s\n' \
  '# reason: test fixture token, not a live credential' \
  "candidate.txt:^${secret_line}\$" > "$repo/.pushgate-allow"
printf '%s\n' "$secret_line" > "$repo/candidate.txt"
git -C "$repo" add .pushgate-allow candidate.txt
git -C "$repo" commit -q -m 'test: legacy-named allowlist'
(cd "$repo" && TMPDIR="$SB" PATH="$STUB_PATH" bash "$SCANNER" origin main) \
  >"$SB/allow-legacy.out" 2>"$SB/allow-legacy.err"; rc=$?
expect_exit "legacy .pushgate-allow still suppresses its hit" 0 "$rc"
expect_has "legacy name draws a deprecation notice on stderr" "DEPRECATED .pushgate-allow" "$(cat "$SB/allow-legacy.err")"
case "$(cat "$SB/allow-legacy.out")" in
  *DEPRECATED*) no "deprecation notice stays off stdout" ;;
  *) ok "deprecation notice stays off stdout" ;;
esac

# Both names present → entries are combined, so a half-finished migration
# (some entries moved, some not) keeps every committed allow working.
repo="$SB/allow-both"
new_repo "$repo"
other_line="$(printf '%s%s' 'sk-' 'zyxwvutsrqponmlkjihgfedcba9876543210')"
printf '%s\n' \
  '# reason: migrated entry, test fixture token' \
  "candidate.txt:^${secret_line}\$" > "$repo/.push-preflight-allow"
printf '%s\n' \
  '# reason: not yet migrated, test fixture token' \
  "other.txt:^${other_line}\$" > "$repo/.pushgate-allow"
printf '%s\n' "$secret_line" > "$repo/candidate.txt"
printf '%s\n' "$other_line" > "$repo/other.txt"
git -C "$repo" add .push-preflight-allow .pushgate-allow candidate.txt other.txt
git -C "$repo" commit -q -m 'test: both allowlist names'
scan_stubbed "$repo" "$SB/allow-both.out"; rc=$?
expect_exit "entries from both allowlist names are combined" 0 "$rc"
expect_has "both-names case says the entries are combined" "combined" "$(cat "$SB/allow-both.out")"

echo "-- new remote branch: scan only what the push sends --"
# The first push of a feature branch sends only the commits the remote lacks.
# origin/main already holds a secret-shaped line from an earlier merged PR;
# re-scanning it refused every new branch cut from main (2026-10-07).
repo="$SB/newbranch-clean"
published_main "$repo" legacy.txt "$secret_line"
git -C "$repo" switch -q -c feature
commit_path "$repo" candidate.txt 'message = "ordinary configuration"'
scan_stubbed "$repo" "$SB/newbranch-clean.out" feature; rc=$?
expect_exit "new branch off a main that already holds a hit passes" 0 "$rc"
expect_has "new-branch scan counts only the unsent commit" "1 commits via gitleaks (new remote branch" "$(cat "$SB/newbranch-clean.out")"
expect_lacks "new-branch scan is not a full-branch scan" "full branch" "$(cat "$SB/newbranch-clean.out")"

repo="$SB/newbranch-secret"
published_main "$repo" legacy.txt "$secret_line"
git -C "$repo" switch -q -c feature
commit_path "$repo" candidate.txt "$other_line"
scan_stubbed "$repo" "$SB/newbranch-secret.out" feature; rc=$?
expect_exit "secret-shaped line in the new commit still refuses" 1 "$rc"
expect_has "refusal names the new commit's file" "candidate.txt: " "$(cat "$SB/newbranch-secret.out")"
expect_lacks "refusal leaves the line already on origin alone" "legacy.txt" "$(cat "$SB/newbranch-secret.out")"

# Feature cut from an older main, then main (now holding the hit) merged in:
# both fork points are on origin, and only the newer one bounds the push.
repo="$SB/newbranch-merge"
published_main "$repo" README2.md 'second baseline'
git -C "$repo" switch -q -c feature
commit_path "$repo" feature-a.txt 'feature work, part one'
git -C "$repo" switch -q main
commit_path "$repo" legacy.txt "$secret_line"
git -C "$repo" push -q origin main 2>/dev/null
git -C "$repo" switch -q feature
git -C "$repo" merge -q --no-ff --no-edit main
commit_path "$repo" feature-b.txt 'feature work, part two'
scan_stubbed "$repo" "$SB/newbranch-merge.out" feature; rc=$?
expect_exit "merging origin's main into a new branch adds nothing to scan" 0 "$rc"
expect_has "merged branch counts its 3 unsent commits" "3 commits via gitleaks" "$(cat "$SB/newbranch-merge.out")"

repo="$SB/newbranch-empty"
published_main "$repo" legacy.txt "$secret_line"
git -C "$repo" switch -q -c feature
scan_stubbed "$repo" "$SB/newbranch-empty.out" feature; rc=$?
expect_exit "new branch with no unsent commits has nothing to scan" 0 "$rc"
expect_has "no-unsent-commits case says so" "already on origin" "$(cat "$SB/newbranch-empty.out")"

echo "-- first push to an empty remote: full scan --"
repo="$SB/empty-remote"
new_remote_repo "$repo"
commit_path "$repo" legacy.txt "$secret_line"
commit_path "$repo" candidate.txt 'message = "ordinary configuration"'
scan_stubbed "$repo" "$SB/empty-remote.out"; rc=$?
expect_exit "empty remote: a hit in the first commit refuses" 1 "$rc"
expect_has "empty remote: refusal names the first commit's file" "legacy.txt: " "$(cat "$SB/empty-remote.out")"
expect_has "empty remote: label says full branch, empty remote" "full branch - 2 commits via gitleaks (origin has no refs: first push to an empty remote" "$(cat "$SB/empty-remote.out")"

# The remote has refs but shares no history with the branch (a host-created
# README, then a local repo pushed to a new branch): everything is unsent.
repo="$SB/unrelated"
published_main "$repo" README2.md 'host-created readme'
git -C "$repo" switch -q --orphan local
commit_path "$repo" legacy.txt "$secret_line"
commit_path "$repo" candidate.txt 'message = "ordinary configuration"'
scan_stubbed "$repo" "$SB/unrelated.out" local; rc=$?
expect_exit "unrelated history: a hit in its first commit refuses" 1 "$rc"
expect_has "unrelated history: refusal names the first commit's file" "legacy.txt: " "$(cat "$SB/unrelated.out")"

echo "-- preflight.sh: new remote branch (Steps 4 and 7) --"
# Step 7 had the same full-branch scope: a forbidden path already on origin
# (a committed public CA bundle) refused every new branch.
preflight_stubbed() {
  local repo="$1" output_file="$2" branch="$3"
  (cd "$repo" && TMPDIR="$SB" PATH="$STUB_PATH" bash "$PREFLIGHT" origin "$branch") >"$output_file" 2>&1
}
repo="$SB/preflight-clean"
published_main "$repo" certs/ca.pem 'public CA bundle'
git -C "$repo" switch -q -c feature
commit_path "$repo" candidate.txt 'message = "ordinary configuration"'
preflight_stubbed "$repo" "$SB/preflight-clean.out" feature; rc=$?
expect_exit "preflight: forbidden path already on origin does not gate a new branch" 0 "$rc"
expect_has "preflight: Step 4 counts the unsent commit" "STEP 4  OK    1 commits pending (new remote branch" "$(cat "$SB/preflight-clean.out")"
expect_has "preflight: Step 7 passes" "STEP 7  OK" "$(cat "$SB/preflight-clean.out")"

repo="$SB/preflight-forbidden"
published_main "$repo" certs/ca.pem 'public CA bundle'
git -C "$repo" switch -q -c feature
commit_path "$repo" deploy/server.pem 'not a key, just a forbidden name'
preflight_stubbed "$repo" "$SB/preflight-forbidden.out" feature; rc=$?
expect_exit "preflight: forbidden path in the new commit still refuses" 2 "$rc"
expect_has "preflight: refusal names the new forbidden path" "deploy/server.pem" "$(cat "$SB/preflight-forbidden.out")"
expect_lacks "preflight: refusal leaves the path already on origin alone" "certs/ca.pem" "$(cat "$SB/preflight-forbidden.out")"

echo "-- preflight.sh: regex-layer false positives already on origin/main --"
# The 2026-10-07 refusal, end to end: a 2-commit branch cut from origin/main was
# reported as "42 commits will be pushed" and refused on regex-layer hits that
# main had published long before. These are those line shapes. Split with
# printf so this file never carries them whole for a scanner to trip on.
fp_code_line="$(printf '%s%s' '    token = str(fact["prose' '_token"])')"
fp_docs_line="$(printf '%s%s' 'SOCKET_API' '_KEY="your-api-key-here"')"
repo="$SB/preflight-published-fp"
published_main "$repo" scripts/render.py "$fp_code_line"
commit_path "$repo" docs/setup.md "$fp_docs_line"
git -C "$repo" push -q origin main 2>/dev/null
git -C "$repo" switch -q -c feature
commit_path "$repo" candidate.txt 'message = "ordinary configuration"'
preflight_stubbed "$repo" "$SB/preflight-published-fp.out" feature; rc=$?
expect_exit "preflight: hits already published on origin/main do not refuse a new branch" 0 "$rc"
expect_has "preflight: Step 4 counts only the branch's own commit" "STEP 4  OK    1 commits pending (new remote branch" "$(cat "$SB/preflight-published-fp.out")"
expect_lacks "preflight: main's history is not re-scanned" "SECRET-PATTERN MATCH" "$(cat "$SB/preflight-published-fp.out")"

# The same shapes in the branch's OWN commit are part of the push: the regex
# layer is unchanged inside the range, so they still refuse.
repo="$SB/preflight-own-fp"
published_main "$repo" README2.md 'second baseline'
git -C "$repo" switch -q -c feature
commit_path "$repo" scripts/render.py "$fp_code_line"
preflight_stubbed "$repo" "$SB/preflight-own-fp.out" feature; rc=$?
expect_exit "preflight: a hit in the new branch's own commit still refuses" 1 "$rc"
expect_has "preflight: refusal names the new commit's file" "scripts/render.py: " "$(cat "$SB/preflight-own-fp.out")"

echo "-- gitleaks integration --"
if command -v gitleaks >/dev/null 2>&1; then
  ghp_token="$(printf '%s%s' 'ghp_' '9xQ7zRtY2wodFb3KpL8mN0aBcDeFgHiJkLmN')"
  repo="$SB/gitleaks"
  new_repo "$repo"
  commit_file "$repo" "$ghp_token"
  (cd "$repo" && TMPDIR="$SB" bash "$SCANNER" origin main) >"$SB/gitleaks.out" 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q "SECRET DETECTED (gitleaks)" "$SB/gitleaks.out"; then
    ok "known-bad blob is caught by installed gitleaks"
  else
    no "known-bad blob is caught by installed gitleaks (exit $rc)"
  fi

  # New branch: gitleaks must skip origin's history (a token already published
  # is a history audit, security-ops' job) yet still see the unsent commits.
  repo="$SB/gitleaks-newbranch-clean"
  published_main "$repo" legacy.txt "$ghp_token"
  git -C "$repo" switch -q -c feature
  commit_path "$repo" candidate.txt 'message = "ordinary configuration"'
  (cd "$repo" && TMPDIR="$SB" bash "$SCANNER" origin feature) >"$SB/gitleaks-nb-clean.out" 2>&1; rc=$?
  expect_exit "gitleaks: new branch skips a token already on origin" 0 "$rc"

  repo="$SB/gitleaks-newbranch-secret"
  published_main "$repo" README2.md 'second baseline'
  git -C "$repo" switch -q -c feature
  commit_path "$repo" candidate.txt "$ghp_token"
  (cd "$repo" && TMPDIR="$SB" bash "$SCANNER" origin feature) >"$SB/gitleaks-nb-secret.out" 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q "SECRET DETECTED (gitleaks)" "$SB/gitleaks-nb-secret.out"; then
    ok "gitleaks: new branch still catches a token in an unsent commit"
  else
    no "gitleaks: new branch still catches a token in an unsent commit (exit $rc)"
  fi
else
  echo "  SKIP  gitleaks integration (gitleaks not installed)"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
