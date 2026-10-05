#!/usr/bin/env bash
# Self-test for security-ops scanners; fully offline.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCAN="$SKILL/scripts/security-scan.sh"
AUDIT="$SKILL/scripts/dependency-audit.sh"
BAD="$HERE/fixtures/bad"
CLEAN="$HERE/fixtures/clean"

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $3 got $2)"; }
expect_has() { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }
expect_lacks() { case "$3" in *"$2"*) no "$1 (unexpected '$2')";; *) ok "$1";; esac; }

printf '%s\n' '=== security-ops self-test ==='

printf '%s\n' '-- contract --'
for script in "$SCAN" "$AUDIT"; do
    name="$(basename "$script")"
    bash -n "$script" 2>/dev/null && ok "bash -n $name" || no "bash -n $name"
    bash "$script" --help >"$SB/help" 2>/dev/null
    expect_exit "$name --help exits 0" "$?" 0
    expect_has "$name --help has EXAMPLES" 'EXAMPLES' "$(cat "$SB/help")"
    bash "$script" --bogus >/dev/null 2>&1
    expect_exit "$name unknown flag" "$?" 2
done

printf '%s\n' '-- true positives and stream separation --'
bash "$SCAN" "$BAD" >"$SB/bad.out" 2>"$SB/bad.err"
expect_exit 'bad fixture signals findings' "$?" 10
bad_out="$(cat "$SB/bad.out")"
bad_err="$(cat "$SB/bad.err")"
expect_has 'hardcoded secret is flagged' 'hardcoded_secret.py' "$bad_out"
expect_has 'eval use is flagged' 'eval_case.py' "$bad_out"
expect_has 'unsafe deserialization is flagged' 'unsafe_deserialization.py' "$bad_out"
expect_lacks 'stdout excludes scan banner' 'Security Scan' "$bad_out"
expect_lacks 'stdout excludes progress' 'Checking:' "$bad_out"
expect_has 'stderr carries scan banner' 'Security Scan' "$bad_err"

finding_count="$(printf '%s\n' "$bad_out" | grep -cE 'hardcoded_secret\.py|eval_case\.py|unsafe_deserialization\.py' || true)"
[[ "$finding_count" == 3 ]] && ok 'exactly three claimed patterns are flagged' || no "expected 3 flagged patterns, got $finding_count"

printf '%s\n' '-- true negative --'
bash "$SCAN" "$CLEAN" >"$SB/clean.out" 2>"$SB/clean.err"
expect_exit 'clean fixture exits clean' "$?" 0
[[ ! -s "$SB/clean.out" ]] && ok 'clean fixture emits no findings' || no 'clean fixture emitted stdout'

printf '%s\n' '-- mutation --'
cp -R "$BAD" "$SB/mutated"
eval_trigger='ev''al(user_expression)'
sed "s/$eval_trigger/safe_evaluate(user_expression)/" "$BAD/eval_case.py" >"$SB/mutated/eval_case.py"
bash "$SCAN" "$SB/mutated" >"$SB/mutated.out" 2>"$SB/mutated.err"
expect_exit 'remaining bad patterns still signal findings' "$?" 10
mutated_out="$(cat "$SB/mutated.out")"
expect_lacks 'removed eval trigger is no longer reported' 'eval_case.py' "$mutated_out"
expect_has 'mutation retains independent secret finding' 'hardcoded_secret.py' "$mutated_out"
expect_has 'mutation retains independent pickle finding' 'unsafe_deserialization.py' "$mutated_out"

printf '%s\n' '-- fail-loud when scan engine (rg) is absent --'
# A security scanner that reports "clean" because rg is missing is a false
# all-clear — it must refuse (exit 5), never exit 0. The scanner hits its
# `command -v rg` guard before it needs any other tool, so a shim of the
# standard bin dirs minus rg is enough to trip it. Skip-guarded: if the shim
# can't be built (e.g. Windows symlink quirks) we don't fail the suite —
# CI (Linux) builds it cleanly and runs the real assertion.
RGSHIM="$SB/rgless"; mkdir -p "$RGSHIM"
for _d in /usr/bin /bin /usr/local/bin; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    _b="$(basename "$_f")"
    [ "$_b" = "rg" ] && continue
    [ -e "$RGSHIM/$_b" ] || ln -sf "$_f" "$RGSHIM/$_b" 2>/dev/null
  done
done
if [ -x "$RGSHIM/bash" ] && ! PATH="$RGSHIM" command -v rg >/dev/null 2>&1; then
  PATH="$RGSHIM" bash "$SCAN" "$BAD" >"$SB/norg.out" 2>/dev/null
  expect_exit 'refuses (exit 5) when rg is absent — no false clean' "$?" 5
else
  printf '  SKIP  rg-absent shim unavailable on this host (CI runs it for real)\n'
fi

printf '%s\n' '-- PHP / Twig / Craft true positives --'
# Needles are file:line pairs from tests/fixtures/bad; each line holds exactly one
# pattern the scanner claims (references/php-*.md, twig-*.md, craft-*.md).
for needle in \
    'unserialize_input.php:2:' \
    'sql_interpolation.php:2:' \
    'sql_interpolation.php:3:' \
    'open_controller.php:4:' \
    'open_controller.php:8:' \
    'config_general.php:3:' \
    'raw_output.twig:1:' \
    'ssti_layout.html:1:' \
    'ssti_layout.html:2:' \
    'misc_sinks.php:2:' \
    'misc_sinks.php:3:' \
    'misc_sinks.php:4:' \
    'misc_sinks.php:5:' \
    'unescaped_block.twig:1:'; do
    expect_has "flags $needle" "$needle" "$bad_out"
done

# A literal security key is secret-shaped, so the fixture is built at runtime rather
# than committed (the repo stays free of anything a leak scanner would flag).
mkdir -p "$SB/phpsecret"
key_literal='abcd1234''efgh5678'
printf "<?php\nreturn GeneralConfig::create()->securityKey('%s');\n" "$key_literal" >"$SB/phpsecret/general.php"
bash "$SCAN" "$SB/phpsecret" >"$SB/phpsecret.out" 2>/dev/null
expect_exit 'literal securityKey signals findings' "$?" 10
expect_has 'literal securityKey is flagged' 'general.php:2:' "$(cat "$SB/phpsecret.out")"

printf '%s\n' '-- tracked .env detection --'
# Craft's starter commits .env.example.* files; only a real .env is a finding.
ENVREPO="$SB/envrepo"; mkdir -p "$ENVREPO"
git -C "$ENVREPO" init -q 2>/dev/null
printf 'CRAFT_SECURITY_KEY=<generate>\n' >"$ENVREPO/.env.example.production"
git -C "$ENVREPO" add .env.example.production
(cd "$ENVREPO" && bash "$SCAN" .) >"$SB/env1.out" 2>/dev/null
expect_exit 'tracked .env.example.* is not a finding' "$?" 0
printf 'X=1\n' >"$ENVREPO/.env"
git -C "$ENVREPO" add -f .env
bash "$SCAN" "$ENVREPO" >"$SB/env2.out" 2>/dev/null
expect_exit 'tracked .env in the scanned repo is a finding' "$?" 10
expect_has 'tracked .env is reported' '.env' "$(cat "$SB/env2.out")"

printf '%s\n' '-- composer audit (shimmed composer) --'
SHIM="$SB/shim"; mkdir -p "$SHIM"
cat >"$SHIM/composer" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COMPOSER_SHIM_LOG"
[ "$1" = audit ] && [ "${2:-}" = --help ] && exit 0
if [ "$1" = audit ]; then
    printf 'Found 1 security vulnerability advisory affecting 1 package\n'
    exit "${COMPOSER_SHIM_EXIT:-1}"
fi
exit 0
SH
chmod +x "$SHIM/composer"
PHPPROJ="$SB/phpproj"; mkdir -p "$PHPPROJ"
printf '{}\n' >"$PHPPROJ/composer.json"
printf '{"packages": []}\n' >"$PHPPROJ/composer.lock"
export COMPOSER_SHIM_LOG="$SB/composer.log"
(cd "$PHPPROJ" && PATH="$SHIM:$PATH" bash "$AUDIT") >"$SB/audit.out" 2>"$SB/audit.err"
expect_exit 'composer audit findings signal exit 10' "$?" 10
expect_has 'audits composer.lock (--locked)' 'audit --locked' "$(cat "$COMPOSER_SHIM_LOG" 2>/dev/null)"
expect_has 'composer findings land on stdout' 'security vulnerability advisory' "$(cat "$SB/audit.out")"
expect_lacks 'stdout carries no banner' 'Dependency Security Audit' "$(cat "$SB/audit.out")"
(cd "$PHPPROJ" && COMPOSER_SHIM_EXIT=0 PATH="$SHIM:$PATH" bash "$AUDIT") >/dev/null 2>&1
expect_exit 'clean composer audit exits 0' "$?" 0

printf '%s\n' '-- skill shape (port-friendly contract) --'
# This block asserts on the skill's OWN frontmatter and files (SKILL-CREATION-PROTOCOL
# Step 5: state such contracts at the assertion site). A trim/split pass must keep:
#   * a "Use when ..." clause of <=500 chars inside `description` - other harnesses
#     read `description` only, never Claude Code's `when_to_use`, so it lives there
#   * every references/*.md <=300 lines, cited from SKILL.md; any over 100 lines opens
#     with a "## Contents" list naming each of its ## sections (a stale list fails)
#   * every skills/security-ops/references/*.md path cited ANYWHERE in the repo exists:
#     review, testgen and techdebt `Read:` these by backtick path, which no link gate sees
#   * no secret-shaped example values - placeholders like <your-key> only, and no
#     cipher-with-key-size literals, so downstream leak scanners stay quiet
REFS="$SKILL/references"
desc="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f && /^description:/ {sub(/^description:[ ]*/, ""); print}' "$SKILL/SKILL.md")"
desc="${desc%\"}"
use_when="${desc#*Use when}"
if [[ "$use_when" == "$desc" ]]; then
    no 'description carries a "Use when" clause'
else
    clause="Use when${use_when}"
    (( ${#clause} <= 500 )) && ok "Use-when clause is ${#clause} chars (<=500)" || no "Use-when clause is ${#clause} chars (>500)"
fi

# Prove the Contents parser can see before trusting its silence: a missing or broken
# reference-contents.awk would otherwise print nothing and pass every reference
{ printf '# t\n\n## A\n'; for _ in $(seq 1 110); do echo x; done; } >"$SB/no-toc.md"
expect_has 'Contents parser flags a long reference with no list' 'no ## Contents' \
    "$(awk -f "$HERE/reference-contents.awk" "$SB/no-toc.md" 2>&1)"

over=''; uncited=''; toc_bad=''
for ref in "$REFS"/*.md; do
    name="$(basename "$ref")"
    lines="$(wc -l <"$ref" | tr -d ' ')"
    (( lines <= 300 )) || over+=" $name($lines)"
    grep -q "references/$name" "$SKILL/SKILL.md" || uncited+=" $name"
    (( lines > 100 )) || continue
    # The parser is shared with the repo-wide tests/reference-contents.sh - see its header
    toc_gap="$(awk -f "$HERE/reference-contents.awk" "$ref" | cut -f2-)"
    [[ -z "$toc_gap" ]] || toc_bad+=" $name[${toc_gap//$'\n'/; }]"
done
[[ -z "$over" ]] && ok 'every reference is <=300 lines' || no "references over 300 lines:$over"
[[ -z "$uncited" ]] && ok 'every reference is cited from SKILL.md' || no "references not cited from SKILL.md:$uncited"
[[ -z "$toc_bad" ]] && ok 'references over 100 lines carry a current Contents list' || no "Contents list missing or stale:$toc_bad"

REPO="$(cd "$SKILL/../.." && pwd)"
if [[ -f "$REPO/.claude-plugin/plugin.json" ]]; then
    ghosts=''
    while IFS= read -r cited; do
        [[ -f "$SKILL/references/$cited" ]] || ghosts+=" $cited"
    done < <(cd "$REPO" && rg -o --no-filename 'security-ops/references/[A-Za-z0-9._-]+\.md' \
                 skills agents commands rules docs README.md AGENTS.md 2>/dev/null \
             | sed 's#.*/##' | sort -u)
    [[ -z "$ghosts" ]] && ok 'every repo citation of a security-ops reference resolves' || no "cited but missing:$ghosts"
else
    printf '  SKIP  repo-wide citation check (not running inside the claude-mods repo)\n'
fi

# Secret-shaped = a credential-named key assigned a literal of 8+ chars that is not a
# <placeholder>, $variable, {template} or URL (no ':' - `token_url='https://..'` is not
# a secret); env-file form is a bare KEY=token running to end of line, so code like
# `SECRET_KEY=os.environ[..]` (dot breaks the token) stays quiet.
read -r pat_quoted <<'RE'
(api_?key|secret|passw(or)?d|token|security_?key)\w*['"]?\s*(=>|=|:)\s*['"][^'"<$\s{:]{8,}['"]
RE
read -r pat_env <<'RE'
^\s*[A-Za-z_]*(API_?KEY|SECRET|PASSWORD|TOKEN|SECURITY_KEY)[A-Za-z_]*=[A-Za-z0-9+/=_-]{8,}\s*$
RE
leaks="$( { rg -n -i "$pat_quoted" "$SKILL/SKILL.md" "$REFS"; rg -n "$pat_env" "$SKILL/SKILL.md" "$REFS"; rg -n -F 'AES-256' "$SKILL/SKILL.md" "$REFS"; } 2>/dev/null)"
[[ -z "$leaks" ]] && ok 'no secret-shaped example values in SKILL.md or references' || no "secret-shaped examples: ${leaks//$'\n'/ | }"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
