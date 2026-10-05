#!/usr/bin/env bash
# Offline self-test for ddev-ops: the auditor's findings, the facts verifier's
# drift detection, the reference set, and the limits of the team-plugin format
# this skill is ported into (SKILL-RESOURCE-PROTOCOL sections 2, 5, 7, 10).
#
# The bugs this suite exists to catch:
#   - the auditor stops reporting a landmine (or starts flagging a correct
#     config - the clean fixture is the false-positive guard), or prints a
#     secret value it should only name;
#   - the verifier stops noticing drift, so stale DDEV facts look current;
#   - the skill drifts past the port format's limits (see PORT LIMITS below).
#
# Usage:   tests/run.sh
#          DDEV_OPS_DIR=<copy-of-skill> tests/run.sh   # run against a copy,
#                                                       # e.g. to prove a mutation fails
# Input:   none (self-contained: no network, no DDEV or Docker needed)
# Output:  progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or no Python 3.8+: skipped), 1 any failure.
#
# Examples:
#   bash skills/ddev-ops/tests/run.sh
#   DDEV_OPS_DIR=/tmp/ddev-ops-copy bash skills/ddev-ops/tests/run.sh
set -uo pipefail

here="${DDEV_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
skill="$here/SKILL.md"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }
finish() {
  echo "ddev-ops tests: $pass passed, $fail failed" >&2
  [ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
}

tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ddev-ops-test.$$")"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# === 1. Layout + frontmatter house rules ===
# CONTRACT: requires `name: ddev-ops`, `license: MIT`, `metadata.author: claude-mods`,
# a SINGLE-LINE quoted `description:` (the checks below read one line), and no
# `when_to_use:` field. A frontmatter trim must keep these or update this block.
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done
[ -f "$skill" ] || { bad "SKILL.md missing"; finish; }
grep -q '^name: ddev-ops$' "$skill" && ok "name matches directory" || bad "name != ddev-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"

# === 2. PORT LIMITS ===
# CONTRACT (the team-plugin format this skill is ported into):
#  - description <= 500 chars and STARTS with "Use when "; no separate
#    `when_to_use:` (the port format has only `description`);
#  - exactly one "**Why:**" line in the body;
#  - SKILL.md body < 500 lines and <= ~5,000 tokens (chars / 3.6): after
#    auto-compaction Claude Code keeps only the first 5,000 tokens of a skill;
#  - every reference <= 300 lines, a "## Contents" list past 100 lines, one H1;
#  - no hostname under DDEV's default TLD anywhere shipped (the port's leak check
#    rejects it, even as a placeholder - so this file builds the needle at runtime
#    rather than spelling it) and no bare standards-style IDs - capitals, a hyphen,
#    digits - because its ticket-key check false-positives on them.
desc_line="$(grep -m1 '^description: ' "$skill" || true)"
desc="${desc_line#description: }"; desc="${desc#\"}"; desc="${desc%\"}"
[ -n "$desc" ] && ok "description present" || bad "description missing or not single-line"
[ "${#desc}" -le 500 ] && ok "description ${#desc} chars (<=500)" || bad "description ${#desc} chars (>500)"
case "$desc" in "Use when "*) ok "description starts 'Use when '" ;; *) bad "description does not start 'Use when '" ;; esac
grep -q '^when_to_use:' "$skill" && bad "when_to_use: present (port format has description only)" || ok "no when_to_use field"
why="$(grep -c '^\*\*Why:\*\*' "$skill" || true)"
[ "$why" = "1" ] && ok "exactly one **Why:** line" || bad "$why **Why:** lines (want 1)"
body="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$skill")"
body_lines="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
body_tokens=$(( $(printf '%s' "$body" | wc -c | tr -d ' ') * 10 / 36 ))
[ "$body_lines" -lt 500 ] && ok "body $body_lines lines (<500)" || bad "body $body_lines lines (>=500)"
[ "$body_tokens" -le 5000 ] && ok "body ~$body_tokens tokens (<=5000)" || bad "body ~$body_tokens tokens (>5000)"

shipped=("$skill" "$here"/references/*.md "$here"/assets/* "$here"/scripts/*)
tld=".ddev"; tld="$tld.site"
if grep -lF "$tld" "${shipped[@]}" >/dev/null 2>&1; then
  bad "DDEV default-TLD hostname found in: $(grep -lF "$tld" "${shipped[@]}" | xargs -n1 basename | tr '\n' ' ')"
else ok "no DDEV default-TLD hostname in shipped files"; fi
ids="$(grep -ohE '\b[A-Z]{2,}-[0-9]+\b' "$skill" "$here"/references/*.md "$here"/assets/* 2>/dev/null | sort -u | tr '\n' ' ')"
[ -z "$ids" ] && ok "no standards-style IDs in prose" || bad "standards-style IDs in prose: $ids"

# === 3. References: linked, sized, one topic each, links resolve ===
for f in "$here"/references/*.md; do
  [ -e "$f" ] || continue
  rel="references/$(basename "$f")"
  grep -qF "]($rel)" "$skill" && ok "linked from SKILL.md: $rel" || bad "unlinked reference: $rel"
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -le 300 ] && ok "$rel $n lines (<=300)" || bad "$rel $n lines (>300)"
  if [ "$n" -gt 100 ]; then
    head -n 15 "$f" | grep -q '^## Contents' && ok "$rel has Contents" || bad "$rel is $n lines without '## Contents'"
  fi
  h1="$(awk '/^```/{fence=!fence; next} !fence && /^# /{n++} END{print n+0}' "$f")"
  [ "$h1" = "1" ] && ok "$rel has one H1" || bad "$rel has $h1 H1 headings"
done
for src in "$skill" "$here"/references/*.md; do
  dir="$(dirname "$src")"
  while IFS= read -r target; do
    target="${target%%#*}"
    [ -z "$target" ] && continue
    [ -e "$dir/$target" ] || bad "broken link in $(basename "$src"): $target"
  done < <(grep -oE '\]\([A-Za-z0-9_./-]+\.(md|example)(#[^)]*)?\)' "$src" | sed -E 's/^\]\(//; s/\)$//' | grep -v '^\.\./\.\./' || true)
done
ok "relative links checked"

# === 4. Python ===
run_py=(bash "$here/scripts/run-python.sh")
if ! "${run_py[@]}" --which >/dev/null 2>&1; then
  note "skip" "no Python 3.8+ - script checks skipped"
  finish
fi
ok "run-python.sh found a Python 3.8+"
audit="$here/scripts/audit-ddev-config.py"
verify="$here/scripts/check-ddev-facts.py"
catalog="$here/assets/ddev-facts.json"
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }
# Capture first, match second. Piping the auditor straight into grep is a trap under
# pipefail: its exit 10 ("findings") becomes the pipeline's status even when grep
# matched, which flips positive checks to FAIL and makes negative ones pass vacuously.
checks_of() { "${run_py[@]}" "$audit" "$@" 2>/dev/null | cut -f2 || true; }
has() { printf '%s\n' "$1" | grep -qx "$2"; }
for s in "$audit" "$verify"; do
  "${run_py[@]}" -m py_compile "$s" && ok "py_compile $(basename "$s")" || bad "py_compile $(basename "$s")"
  grep -qE '^Examples:$' "$s" && ok "$(basename "$s"): Examples block" || bad "$(basename "$s"): no Examples block"
  grep -qF "scripts/$(basename "$s")" "$skill" && ok "$(basename "$s") cited from SKILL.md" || bad "$(basename "$s") not cited"
  ec 0 "$(basename "$s") --help" "${run_py[@]}" "$s" --help
  ec 2 "$(basename "$s") unknown flag -> 2" "${run_py[@]}" "$s" --bogus
done

# === 5. Auditor: every landmine reported, the clean control stays clean ===
out="$("${run_py[@]}" "$audit" "$fixtures/minefield" 2>/dev/null)"; rc=$?
[ "$rc" = "10" ] && ok "minefield -> exit 10" || bad "minefield exit $rc (want 10)"
for id in php-unpinned db-unpinned node-eol composer-v1 obsolete-key perf-mode-committed \
          router-ports-committed xdebug-committed upload-dir-misplaced shadowed-command \
          ssh-agent-forwarded provider-push provider-files-noop; do
  printf '%s\n' "$out" | cut -f2 | grep -qx "$id" && ok "minefield reports $id" || bad "minefield misses $id"
done
ec 0 "clean fixture -> exit 0 (no false positives)" "${run_py[@]}" "$audit" "$fixtures/clean"

# Generated variants: files git would normalise (CRLF) or must never hold (credentials).
cp -R "$fixtures/minefield" "$tmp/mf"
printf '#!/usr/bin/env bash\r\n## Usage: assets\r\nnpm run build\r\n' > "$tmp/mf/.ddev/commands/web/assets"
fake="fixture-value-not-a-real-credential"
printf 'PAYMENT_API_TOKEN=%s\nCRAFT_DB_PASSWORD=db\n' "$fake" > "$tmp/mf/.ddev/.env.web"
printf 'OTHER_API_TOKEN=%s\n' "$fake" > "$tmp/mf/.ddev/.env.web.local"
out="$("${run_py[@]}" "$audit" "$tmp/mf" 2>/dev/null)"
printf '%s\n' "$out" | grep -q $'^high\tcrlf-command\t.ddev/commands/web/assets' && ok "CRLF command reported" || bad "CRLF command missed"
printf '%s\n' "$out" | grep -q $'committed-secret\t.ddev/.env.web\t.*PAYMENT_API_TOKEN' && ok "committed secret named" || bad "committed secret missed"
# DDEV's generated .ddev/.gitignore ignores *.example: the advice must say git add -f.
printf '%s\n' "$out" | grep $'committed-secret' | grep -qF 'git add -f' && ok "committed-secret says git add -f for the .example" || bad "committed-secret omits git add -f"
printf '%s\n' "$out" | grep -q 'CRAFT_DB_PASSWORD' && bad "DDEV's local db/db password flagged" || ok "local db/db password not flagged"
printf '%s\n' "$out" | cut -f3 | grep -qx '.ddev/.env.web.local' && bad ".local env file flagged (it is gitignored)" || ok ".local env file not flagged"
json="$("${run_py[@]}" "$audit" "$tmp/mf" --json 2>/dev/null)"
printf '%s\n%s' "$out" "$json" | grep -qF "$fake" && bad "secret VALUE printed" || ok "secret value never printed"
printf '%s' "$json" | "${run_py[@]}" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.ddev-ops.audit/v1" and d["meta"]["count"]==len(d["data"])>0' \
  && ok "--json envelope parses (stdout clean)" || bad "--json envelope broken"
ids="$(checks_of "$tmp/mf" --ignore shadowed-command)"
has "$ids" ssh-agent-forwarded && ! has "$ids" shadowed-command \
  && ok "--ignore suppresses only the named check" || bad "--ignore did not suppress (or suppressed everything)"
ec 2 "--ignore unknown-check -> 2" "${run_py[@]}" "$audit" "$tmp/mf" --ignore no-such-check

# Agent forwarding has three spellings; the minefield uses the Docker Desktop/OrbStack
# socket path. Prove the generic ${SSH_AUTH_SOCK} bind is caught too, and that DDEV's
# own ddev-ssh-agent socket (what `ddev auth ssh` uses) is not.
cp -R "$fixtures/clean" "$tmp/agent"
printf 'services:\n  web:\n    volumes:\n      - ${SSH_AUTH_SOCK}:/tmp/agent.sock\n' > "$tmp/agent/.ddev/docker-compose.fwd.yaml"
has "$(checks_of "$tmp/agent")" ssh-agent-forwarded && ok '${SSH_AUTH_SOCK} bind -> ssh-agent-forwarded' || bad '${SSH_AUTH_SOCK} bind not flagged'
printf 'services:\n  web:\n    environment:\n      - SSH_AUTH_SOCK=/home/.ssh-agent/socket\n' > "$tmp/agent/.ddev/docker-compose.fwd.yaml"
has "$(checks_of "$tmp/agent")" ssh-agent-forwarded && bad "DDEV's own agent socket flagged" || ok "DDEV's own agent socket not flagged"

cp -R "$fixtures/clean" "$tmp/php"
sed 's/^php_version: "8.3"/php_version: "7.4"/' "$fixtures/clean/.ddev/config.yaml" > "$tmp/php/.ddev/config.yaml"
has "$(checks_of "$tmp/php")" php-eol && ok "PHP 7.4 -> php-eol" || bad "PHP 7.4 not flagged"
sed 's/^php_version: "8.3"/php_version: "9.9"/' "$fixtures/clean/.ddev/config.yaml" > "$tmp/php/.ddev/config.yaml"
has "$(checks_of "$tmp/php")" php-out-of-range && ok "PHP 9.9 -> php-out-of-range" || bad "PHP 9.9 not flagged"
sed 's#^  - \.\./storage .*#  - ../../outside#' "$fixtures/clean/.ddev/config.yaml" > "$tmp/php/.ddev/config.yaml"
has "$(checks_of "$tmp/php")" upload-dir-outside && ok "escaping upload_dirs -> upload-dir-outside" || bad "escaping upload_dirs not flagged"

# DDEV writes acquia/lagoon/pantheon/platform/upsun.yaml into EVERY started project's
# .ddev/providers/ - #ddev-generated, gitignored, and carrying push stanzas. Flagging them
# would put five false findings on every real working tree (the fixtures lacked them).
cp -R "$fixtures/clean" "$tmp/gen"
printf '#ddev-generated\nauth_command:\n  command: true\ndb_push_command:\n  command: true\nfiles_push_command:\n  command: true\n' \
  > "$tmp/gen/.ddev/providers/upsun.yaml"
has "$(checks_of "$tmp/gen")" provider-push && bad "DDEV-generated provider recipe flagged" || ok "DDEV-generated provider recipe not flagged"

# A no-op files_pull_command wipes uploads only because DDEV then imports the empty
# download folder; a files_import_command takes over the import, so no finding then.
printf 'files_pull_command:\n  command: |\n    true\nfiles_import_command:\n  command: |\n    rsync -a /tmp/x/ /var/www/html/web/uploads/\n' \
  > "$tmp/gen/.ddev/providers/custom.yaml"
has "$(checks_of "$tmp/gen")" provider-files-noop && bad "no-op files pull flagged despite files_import_command" || ok "files_import_command suppresses provider-files-noop"

# The shipped recipe asset must stay pull-only with NO files stanza (an empty files pull
# empties the upload directory) and no push stanzas.
asset="$here/assets/sanitized-pull.yaml.example"
grep -qE '^(files_pull_command|db_push_command|files_push_command):' "$asset" \
  && bad "recipe asset has a files or push stanza" || ok "recipe asset is db-pull only"

# Output is ordered by severity, so "fix the high rows first" means the top rows.
sev="$("${run_py[@]}" "$audit" "$fixtures/minefield" 2>/dev/null | cut -f1 | sed 's/high/1/; s/medium/2/; s/low/3/' | tr '\n' ' ' || true)"
[ -n "$sev" ] && [ "$sev" = "$(printf '%s\n' $sev | sort -n | tr '\n' ' ')" ] \
  && ok "findings ordered high -> medium -> low" || bad "findings not ordered by severity ($sev)"
mf_out="$("${run_py[@]}" "$audit" "$fixtures/minefield" 2>/dev/null || true)"   # capture: exit 10 under pipefail
printf '%s\n' "$mf_out" | grep -q $'^high\tdb-unpinned\t' \
  && ok "db-unpinned is high (engine silently differs from production)" || bad "db-unpinned not high"

# A committed name: in a git WORKTREE collides with the main checkout (DDEV project names
# are unique per machine). Only worktrees: a submodule's .git file must not trigger it.
cp -R "$fixtures/clean" "$tmp/wt"
printf 'gitdir: /repos/site/.git/worktrees/feature-x\n' > "$tmp/wt/.git"
has "$(checks_of "$tmp/wt")" name-in-worktree && ok "committed name: in a worktree -> name-in-worktree" || bad "worktree name collision missed"
printf 'gitdir: /repos/site/.git/modules/theme\n' > "$tmp/wt/.git"
has "$(checks_of "$tmp/wt")" name-in-worktree && bad "submodule .git file flagged as worktree" || ok "submodule .git file not flagged"

# DDEV merges config.*.y*ml overrides by APPENDING lists unless override_config: true, and
# reads .yml as well as .yaml. A misplaced entry in config.yaml survives an override file.
cp -R "$fixtures/clean" "$tmp/merge"
sed 's#^  - \.\./storage .*#  - storage#' "$fixtures/clean/.ddev/config.yaml" > "$tmp/merge/.ddev/config.yaml"
printf 'upload_dirs:\n  - uploads2\n' > "$tmp/merge/.ddev/config.extra.yaml"
has "$(checks_of "$tmp/merge")" upload-dir-misplaced && ok "override lists append (misplaced entry kept)" || bad "override list replaced instead of appended"
printf 'override_config: true\nupload_dirs:\n  - uploads2\n' > "$tmp/merge/.ddev/config.extra.yaml"
has "$(checks_of "$tmp/merge")" upload-dir-misplaced && bad "override_config: true did not replace the list" || ok "override_config: true replaces the list"
rm -f "$tmp/merge/.ddev/config.extra.yaml"
cp "$fixtures/clean/.ddev/config.yaml" "$tmp/merge/.ddev/config.yaml"
printf 'upload_dirs:\n  - storage\n' > "$tmp/merge/.ddev/config.extra.yml"
has "$(checks_of "$tmp/merge")" upload-dir-misplaced && ok ".yml override files are read" || bad ".yml override file ignored"

# Facts come from the catalog, not constants in the script: raising the PHP floor
# must turn the clean fixture's 8.3 into a finding.
sed 's/"php": "8.2"/"php": "8.4"/' "$catalog" > "$tmp/cat-floor.json"
has "$(checks_of "$fixtures/clean" --catalog "$tmp/cat-floor.json")" php-eol \
  && ok "auditor reads eol_floor from the catalog" || bad "auditor ignores the catalog's eol_floor"

mkdir -p "$tmp/empty"
ec 3 "no .ddev/config.yaml -> 3" "${run_py[@]}" "$audit" "$tmp/empty"
mkdir -p "$tmp/broken/.ddev"
printf '   indented: first line\n' > "$tmp/broken/.ddev/config.yaml"
ec 4 "unreadable config -> 4" "${run_py[@]}" "$audit" "$tmp/broken"

# === 6. Verifier: offline consistency, live drift via fixtures ===
ec 0 "verifier --offline consistent" "${run_py[@]}" "$verify" --offline --skill "$here" --catalog "$catalog"
ec 2 "--offline --live -> 2" "${run_py[@]}" "$verify" --offline --live
ec 2 "--fixtures without --live -> 2" "${run_py[@]}" "$verify" --offline --fixtures "$fixtures/live"
ec 3 "missing catalog -> 3" "${run_py[@]}" "$verify" --offline --catalog "$tmp/no-such.json"
printf 'not json' > "$tmp/bad.json"
ec 4 "malformed catalog -> 4" "${run_py[@]}" "$verify" --offline --catalog "$tmp/bad.json" --skill "$here"
# Prose and catalog parting ways is drift: one of them is wrong.
sed 's/"token": "Node.js 24"/"token": "Node.js 24 LTS forever"/' "$catalog" > "$tmp/c1.json"
ec 10 "prose token no longer stated -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c1.json" --skill "$here"
sed 's/"nodejs_version": "24"/"nodejs_version": "26"/' "$catalog" > "$tmp/c2.json"
ec 10 "token no longer contains its value -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c2.json" --skill "$here"
sed 's/"as_of": "[0-9-]*"/"as_of": "1999-01-01"/' "$catalog" > "$tmp/c3.json"
ec 10 "'Versions verified' note != as_of -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c3.json" --skill "$here"

live=("${run_py[@]}" "$verify" --live --catalog "$catalog" --today 2026-10-05)
ec 0 "live fixtures in sync -> 0" "${live[@]}" --fixtures "$fixtures/live"
mutate() { # name, file, sed-expression: a copy of the live fixtures with one change
  rm -rf "$tmp/live-$1"; cp -R "$fixtures/live" "$tmp/live-$1"
  sed "$3" "$fixtures/live/$2" > "$tmp/live-$1/$2"
}
mutate rel releases.json 's/"v1.25.4", "prerelease": false/"v1.26.0", "prerelease": false/'
ec 10 "new DDEV minor -> 10" "${live[@]}" --fixtures "$tmp/live-rel"
mutate doc config.md 's/| `8.4` | Can be/| `8.5` | Can be/'
ec 10 "docs default PHP moved -> 10" "${live[@]}" --fixtures "$tmp/live-doc"
mutate cmd commands-web.json 's/{"name": "yarn", "type": "file"}/{"name": "yarn", "type": "file"}, {"name": "newcmd", "type": "file"}/'
ec 10 "new built-in command -> 10" "${live[@]}" --fixtures "$tmp/live-cmd"
ec 10 "PHP 8.2 past EOL (today 2027-01-15) -> 10" "${run_py[@]}" "$verify" --live --catalog "$catalog" --today 2027-01-15 --fixtures "$fixtures/live"
rm -rf "$tmp/live-gone"; cp -R "$fixtures/live" "$tmp/live-gone"; rm -f "$tmp/live-gone/eol-nodejs.json"
ec 7 "unreachable source -> 7 (advisory)" "${live[@]}" --fixtures "$tmp/live-gone"
"${live[@]}" --fixtures "$fixtures/live" --json -q 2>/dev/null \
  | "${run_py[@]}" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.ddev-ops.facts/v1"' \
  && ok "verifier --json envelope parses" || bad "verifier --json envelope broken"

# === 7. Portability: the skill folder runs when copied alone ===
mkdir -p "$tmp/alone"
cp -R "$here/SKILL.md" "$here/scripts" "$here/references" "$here/assets" "$tmp/alone/"
ec 10 "copied-alone auditor finds the minefield" bash "$tmp/alone/scripts/run-python.sh" "$tmp/alone/scripts/audit-ddev-config.py" "$fixtures/minefield"
ec 0 "copied-alone verifier --offline" bash "$tmp/alone/scripts/run-python.sh" "$tmp/alone/scripts/check-ddev-facts.py" --offline

finish
