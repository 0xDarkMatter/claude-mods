#!/usr/bin/env bash
# Behavioural self-test for push-gate's secret scanner. Fully offline.

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
  git -C "$repo" config user.name push-gate-test
  git -C "$repo" config user.email push-gate-test@example.invalid
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

echo "=== push-gate behavioural self-test ==="

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
