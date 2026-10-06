#!/usr/bin/env bash
# Behavioural self-test for push-preflight's secret scanner. Fully offline.

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

# Use a byte-identical scanner in a temporary skill mirror, normalising only the
# regex corpus so Git-for-Windows CRLF checkouts behave like Ubuntu CI.
mkdir -p "$SB/skill/scripts" "$SB/skill/references"
cp "$SOURCE_SCANNER" "$SB/skill/scripts/scan-secrets.sh"
cp "$SKILL/references/secret-patterns.txt" "$SB/skill/references/secret-patterns.txt"
sed -i 's/\r$//' "$SB/skill/references/secret-patterns.txt"
cp "$SKILL/references/gitleaks-config.toml" "$SB/skill/references/gitleaks-config.toml"
SCANNER="$SB/skill/scripts/scan-secrets.sh"

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
  local repo="$1" output_file="$2"
  (cd "$repo" && TMPDIR="$SB" PATH="$STUB_PATH" bash "$SCANNER" origin main) >"$output_file" 2>&1
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

echo "-- gitleaks integration --"
if command -v gitleaks >/dev/null 2>&1; then
  repo="$SB/gitleaks"
  new_repo "$repo"
  commit_file "$repo" "$(printf '%s%s' 'ghp_' '9xQ7zRtY2wodFb3KpL8mN0aBcDeFgHiJkLmN')"
  (cd "$repo" && TMPDIR="$SB" bash "$SCANNER" origin main) >"$SB/gitleaks.out" 2>&1; rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q "SECRET DETECTED (gitleaks)" "$SB/gitleaks.out"; then
    ok "known-bad blob is caught by installed gitleaks"
  else
    no "known-bad blob is caught by installed gitleaks (exit $rc)"
  fi
else
  echo "  SKIP  gitleaks integration (gitleaks not installed)"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
