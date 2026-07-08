#!/usr/bin/env bash
# Self-test for terraform-ops — fully offline: no network, no GitHub API.
#
# Wraps the skill's §7 staleness verifier (scripts/check-action-refs.sh), which
# lints `uses: owner/repo@ref` lines in GitHub Actions workflow YAML. Contract
# (bash -n + --help), offline happy path against the shipped
# assets/github-actions-terraform.yml, the --json §7 envelope (jq-guarded), and a
# NEGATIVE proving the verifier rejects a malformed uses (a ref with no @ ->
# exit 4 MALFORMED). --live is NEVER invoked (it resolves refs against the GitHub
# API); a network blip must never fail a PR.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/check-action-refs.sh"
DEFAULT="$SKILL/assets/github-actions-terraform.yml"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== terraform-ops self-test ==="

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
bash -n "$V" && ok "bash -n check-action-refs.sh" || no "bash -n check-action-refs.sh"
bash "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
out="$(bash "$V" --help 2>&1)"
expect_has "--help has Examples" "xamples" "$out"
bash "$V" --bogus >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?

# ── offline structural mode (§7 seam: --offline default, --live advisory) ─────
echo "-- offline structural --"
[[ -f "$DEFAULT" ]] && ok "shipped workflow present" || no "shipped workflow present"
bash "$V" --offline >/dev/null 2>&1; expect_exit "--offline clean on shipped skill" 0 $?
# --json needs jq; SKIP the envelope checks where jq is absent (a no-jq runner is
# legitimate, and the verifier itself exits 5 for --json without jq).
if command -v jq >/dev/null 2>&1; then
  out="$(bash "$V" --offline --json 2>/dev/null)"
  expect_has "--offline --json envelope schema" '"schema": "claude-mods.terraform-ops.action-refs/v1"' "$out"
  expect_has "--offline --json mode" '"mode": "offline"' "$out"
else
  echo "  SKIP  --json envelope (no jq on this runner)"
fi

# ── negative: a uses with no @ref must be flagged malformed (exit 4) ──────────
echo "-- negative --"
cat > "$SB/bad.yml" <<'EOF'
name: bad
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: hashicorp/setup-terraform
EOF
bash "$V" --offline "$SB/bad.yml" >"$SB/neg.out" 2>&1
expect_exit "--offline flags missing @ref -> 4" 4 $?
expect_has "finding names the malformed ref" "malformed" "$(cat "$SB/neg.out")"

# ── SKILL.md sanity ───────────────────────────────────────────────────────────
echo "-- SKILL.md --"
grep -q '^name: terraform-ops$' "$SKILL/SKILL.md" && ok "frontmatter name" || no "frontmatter name"
grep -q 'check-action-refs.sh' "$SKILL/SKILL.md" && ok "verifier cited from SKILL.md" || no "verifier cited from SKILL.md"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
