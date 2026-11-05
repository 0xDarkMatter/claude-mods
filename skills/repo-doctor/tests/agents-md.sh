#!/usr/bin/env bash
# agents-md behavioural suite: offline, self-contained, run by tests/run.sh.
#
# scaffold: archetype choice, commands only from declared scripts (each cites a real
#   file), landmine candidates as owner questions, no secret leaks, --write creates
#   and never overwrites.
# audit: every finding (dead commands, shadowing in all its forms, over-ceiling with a
#   split plan, missing sections, staleness, draft markers) on fixture repos, a clean
#   control with zero findings, and the --diff patch: it applies, preserves the
#   Landmines section byte for byte, keeps CRLF files CRLF, and is idempotent.
# survey: a fake gh (tests/fake-gh.py) serves an org; asserts each row, the roll-up,
#   GET-only calls and that nothing is written anywhere.
# SCRIPTS_DIR=<dir> runs against another copy of the scripts (assets/ must sit beside
# it as ../assets); KEEP_TMP=1 keeps fixtures. Exit 0 all pass, 1 any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPTS_DIR:-$HERE/../scripts}"
AM="$SCRIPTS/agents-md.py"

PY=""
for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
        PY="$cand"; break
    fi
done
if [ -z "$PY" ] || ! command -v git >/dev/null 2>&1; then
    echo "SKIP: working python/git not available"; exit 0
fi
. "$HERE/fixtures.sh"

TMP="$(mktemp -d)"
if [ -n "${KEEP_TMP:-}" ]; then echo "fixtures kept in $TMP"; else trap 'rm -rf "$TMP"' EXIT; fi
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1 - $2"; fail=$((fail+1)); }
check() {   # NAME PYTHON-EXPR over $OUT (d = envelope, D = data)
    local got
    got="$(printf '%s' "$OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);D=d['data'];print('ok' if ($2) else 'no')" 2>&1)"
    [ "$got" = "ok" ] && ok "$1" || no "$1" "$got"
}
ids() { printf '%s' "$OUT" | "$PY" -c "import json,sys;print(' '.join(sorted(f['id'] for f in json.load(sys.stdin)['data']['findings'])))"; }
good_agents() {   # a protocol-complete AGENTS.md whose commands all exist
    cat > "$1/AGENTS.md" <<'EOF'
# Agent Instructions - fixture

A small fixture service: it builds one bundle that the test suite consumes.

## Commands

```bash
npm run build
npm test
```

## Landmines

1. **The bundle name is load-bearing** - tests import it by path; rename both together.

## Structure

| Path | What lives there |
|---|---|
| `src/` | the bundle source |

## Conventions

- Two-space indentation everywhere.
EOF
    echo '{"name":"fixture","scripts":{"build":"node build.js","test":"node test.js"}}' > "$1/package.json"
}

# ============================== SCAFFOLD ======================================
S="$TMP/site"; make_site "$S"
DRAFT="$("$PY" "$AM" scaffold --repo "$S" 2>"$TMP/err")"
ERR="$(cat "$TMP/err")"
case "$ERR" in *"archetype php-cms"*) ok "PHP site gets the php-cms archetype" ;; *) no "archetype" "$ERR" ;; esac
miss=""
for c in "ddev start" "ddev sync-db" "ddev composer install" "ddev composer run-script test" "npm ci" "npm run build"; do
    printf '%s\n' "$DRAFT" | grep -q "^$c  *# .*\[untested\]" || miss="$miss|$c"
done
[ -z "$miss" ] && ok "draft lists declared commands, each tagged [untested]" || no "commands" "missing:$miss"
printf '%s' "$DRAFT" | "$PY" -c "
import re,sys,os
lines=sys.stdin.read().split('\n'); fence=False; bad=[]
for l in lines:
    if l.startswith('\`\`\`'): fence=not fence; continue
    if fence and l.strip() and not l.startswith('#'):
        m=re.search(r'\(([^()]+?)(?::\d+)?\) \[untested\]$', l)
        if not m or not os.path.exists(os.path.join(sys.argv[1], m.group(1))): bad.append(l)
print('ok' if not bad else bad)" "$S" | grep -qx ok \
    && ok "every command cites a file that exists (nothing invented)" || no "command sources" "a command lacks a real source"
case "$DRAFT" in *SENTINEL_*) no "no secrets in the draft" "a sentinel leaked" ;; *) ok "no secret value in the draft" ;; esac
printf '%s' "$DRAFT" | grep -q 'TODO(owner): `modules/a.php` and `modules/b.php` changed together' \
    && ok "history candidates land under Landmines as owner questions" || no "landmine candidates" "coupling question missing"
printf '%s' "$DRAFT" | grep -q '`AfterInstall` runs `scripts/after_install.sh`' \
    && ok "deploy notes follow the appspec hook" || no "deploy notes" "appspec hook missing"
n="$(printf '%s\n' "$DRAFT" | wc -l)"
[ "$n" -le 200 ] && ok "draft stays under the 200-line ceiling ($n lines)" || no "draft size" "$n lines"
OUT="$("$PY" "$AM" scaffold --repo "$S" --json 2>/dev/null)"
check "scaffold --json envelope" "d['meta']['schema']=='claude-mods.repo-doctor.agents-md-scaffold/v1' and D['archetype']=='php-cms'"

"$PY" "$AM" scaffold --repo "$S" --write 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ -f "$S/AGENTS.md" ] && ok "--write creates AGENTS.md" || no "--write" "exit $rc"
echo "1. **OWNER-LANDMINE** - mine." >> "$S/AGENTS.md"
before="$(cksum < "$S/AGENTS.md")"
"$PY" "$AM" scaffold --repo "$S" --write 2>/dev/null; rc=$?
[ "$rc" -eq 5 ] && [ "$(cksum < "$S/AGENTS.md")" = "$before" ] \
    && ok "--write refuses an existing AGENTS.md (exit 5, file untouched)" || no "no overwrite" "exit $rc"
commit "$S" "docs: draft AGENTS.md"
OUT="$("$PY" "$AM" audit --repo "$S" --no-parents --json 2>/dev/null)"
case " $(ids) " in *" owner-todos "*" draft-header "*|*" draft-header "*" owner-todos "*) ok "an unfinished draft fails its own audit" ;;
    *) no "draft markers" "$(ids)" ;; esac

for kind in node python static; do
    R="$TMP/arch-$kind"; mkdir -p "$R"
    case "$kind" in
        node)   echo '{"name":"n","scripts":{"dev":"next dev"},"dependencies":{"next":"14"}}' > "$R/package.json"; want=node-app ;;
        python) printf '[project]\nname = "svc"\ndependencies = ["fastapi>=0.1"]\n\n[tool.pytest.ini_options]\naddopts = "-q"\n' > "$R/pyproject.toml"
                echo "" > "$R/uv.lock"; want=python-service ;;
        static) echo "<h1>hi</h1>" > "$R/index.html"; want=static-site ;;
    esac
    OUT="$("$PY" "$AM" scaffold --repo "$R" --json 2>/dev/null)"
    check "$kind repo gets the $want archetype" "D['archetype']=='$want'"
done
OUT="$("$PY" "$AM" scaffold --repo "$TMP/arch-python" --json 2>/dev/null)"
check "python draft uses the repo's own manager (uv)" \
      "{'uv sync','uv run pytest'} <= {c['command'] for c in D['commands']}"
R="$TMP/arch-mkdocs"; mkdir -p "$R/docs"; echo "site_name: x" > "$R/mkdocs.yml"; echo "# x" > "$R/docs/index.md"
OUT="$("$PY" "$AM" scaffold --repo "$R" --json 2>/dev/null)"
check "an mkdocs site gets the static-site archetype" "D['archetype']=='static-site'"
# A repo with no web manifest used to fall back to static-site and get publishing
# questions; tooling and script repos get the generic archetype instead.
R="$TMP/arch-generic"; init_repo "$R"; mkdir -p "$R/tests"
echo 'echo hi' > "$R/tool.sh"; echo 'bash tool.sh' > "$R/tests/run.sh"
printf 'default:\n\tjust --list\n\ncheck:\n\tbash tests/run.sh\n' > "$R/justfile"
for d in 01 02 03 04 05 06 07 08 09 10 11 12 13; do mkdir -p "$R/d$d"; echo "# $d" > "$R/d$d/README.md"; done
mkdir -p "$R/media"; for i in $(seq 1 40); do echo "$i" > "$R/media/f$i.bin"; done
commit "$R" "feat: tool"
OUT="$("$PY" "$AM" scaffold --repo "$R" --json 2>/dev/null)"
check "a script repo with no web manifest gets the generic archetype" \
      "D['archetype']=='generic' and 'directory is published' not in D['draft']"
check "the Structure table keeps the largest area past 12 rows" "'| \`media/\` |' in D['draft']"
check "a just 'default' recipe is not listed as a command" \
      "'just default' not in D['draft'] and 'just check' in D['draft']"
init_repo "$TMP/shadowed"; good_agents "$TMP/shadowed"; rm "$TMP/shadowed/AGENTS.md"
echo "# Claude notes" > "$TMP/shadowed/CLAUDE.md"
"$PY" "$AM" scaffold --repo "$TMP/shadowed" 2>"$TMP/err" >/dev/null
grep -q "CLAUDE.md will shadow" "$TMP/err" && ok "scaffold warns that an existing CLAUDE.md will shadow it" \
    || no "scaffold shadow warning" "$(cat "$TMP/err")"

# ============================== NESTED SCAFFOLD ===============================
# scaffold --dir drafts <folder>/AGENTS.md: a scope line, the folder's own commands in
# the form that runs from the root, its own landmine candidates, nothing the root says.
MO="$TMP/mono"; make_monorepo "$MO" >/dev/null 2>&1
echo '- `npm -w packages/engine run test` runs the engine suite.' >> "$MO/AGENTS.md"
printf '{ "name": "@fixture/tool-01", "scripts": { "build": "node b.js" } }\n' > "$MO/tools/t01/package.json"
commit "$MO" "docs: root names the engine suite"
OUT="$("$PY" "$AM" scaffold --repo "$MO" --dir packages/engine --json 2>/dev/null)"
check "nested_scaffold_holds_only_deltas_and_a_scope_line" \
      "'packages/engine/' + chr(96) + ' and below; extends the root [AGENTS.md](../../AGENTS.md).' in D['draft'] and 'npm -w packages/engine run test' not in D['draft'] and 'packages/engine/src/parse.ts' in D['draft'] and not ({l.strip() for l in D['draft'].splitlines() if len(l.strip())>=12 and not l.startswith('#')} & {l.strip() for l in open(r'$(winpath "$MO/AGENTS.md")', encoding='utf-8')}) and D['lines']<=40"
check "nested_commands_use_workspace_form" \
      "'npm -w packages/engine run check:deps' in D['draft'] and 'cd packages/engine' not in D['draft'] and D['workspace_form']"
OUT="$("$PY" "$AM" scaffold --repo "$MO" --dir tools/t01 --json 2>/dev/null)"
check "nested_commands_outside_a_workspace_say_where_to_run" \
      "'Run from ' + chr(96) + 'tools/t01/' in D['draft'] and 'npm run build' in D['draft'] and not D['workspace_form']"
echo "# UI notes" > "$MO/packages/ui/CLAUDE.md"
"$PY" "$AM" scaffold --repo "$MO" --dir packages/ui 2>"$TMP/err" >/dev/null
grep -q "packages/ui/CLAUDE.md will shadow" "$TMP/err" && ok "nested_scaffold_warns_when_claude_md_shadows" \
    || no "nested_scaffold_warns_when_claude_md_shadows" "$(cat "$TMP/err")"
"$PY" "$AM" scaffold --repo "$MO" --dir packages/engine --write 2>/dev/null; rc1=$?
"$PY" "$AM" scaffold --repo "$MO" --dir packages/engine --write 2>/dev/null; rc2=$?
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 5 ] && grep -q 'and below; extends the root' "$MO/packages/engine/AGENTS.md" \
    && ok "nested_write_creates_once_then_refuses" || no "nested_write_creates_once_then_refuses" "exits $rc1 then $rc2"
"$PY" "$AM" scaffold --repo "$MO" --dir ../outside >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "nested_dir_outside_the_repo_exits_3" || no "nested_dir_outside_the_repo_exits_3" "exit $rc"

# ============================== AUDIT =========================================
A="$TMP/aud"; init_repo "$A"; mkdir -p "$A/web/themes/site" "$A/scripts" "$A/src"
echo '{"name":"aud","version":"1.0.0","scripts":{"build":"node b.js","test":"node t.js"}}' > "$A/package.json"
echo '{"name":"acme/aud","scripts":{"lint":"ecs check"}}' > "$A/composer.json"
printf 'check:\n\techo ok\n' > "$A/Makefile"
printf 'version: 0.0\nos: linux\nhooks: {}\n' > "$A/appspec.yml"
echo "echo ok" > "$A/scripts/ok.sh"; echo "x" > "$A/web/themes/site/base.twig"
echo "# Claude only" > "$A/CLAUDE.md"
"$PY" - "$A/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - aud", "", "Fixture repo for the agents-md audit suite.", "",
     "## Commands", "", "```bash", "npm run build", "npm run legacy-build",
     "composer run-script missing", "composer run-script lint", "make check", "make deploy",
     "bash scripts/ok.sh", "bash scripts/gone.sh", "```", "",
     "Never run `npm run old-thing` here; `npm test` is the gate.", "",
     "## Landmines", "", "1. **LANDMINE-SENTINEL** - the cache key must include the locale."]
L += [f"{i}. **Rule {i}** - keep invariant {i} intact." for i in range(2, 101)]
L += ["", "## Setup", ""] + [f"Step {i}: install prerequisite {i} on your laptop." for i in range(40)]
L += ["", "## Frontend notes", ""] + [f"- `web/themes/site/part{i}.twig` holds partial {i}." for i in range(35)]
L += ["", "## Background", ""] + [f"Paragraph {i} of history about why the site exists." for i in range(30)]
L += [""]
open(sys.argv[1], "w", newline="\n").write("\n".join(L))
EOF
commit "$A" "docs: agents"
for i in $(seq 1 16); do
    "$PY" -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d['version']='1.0.$i';json.dump(d,open(p,'w'))" "$A/package.json"
    commit "$A" "chore: bump $i"
done
OUT="$("$PY" "$AM" audit --repo "$A" --no-parents --json 2>/dev/null)"; rc=$?
[ "$rc" -eq 10 ] && ok "audit with findings exits 10" || no "audit exit" "$rc"
check "exactly the 4 dead commands are flagged" \
      "sorted(f['msg'].split('\`')[1] for f in D['findings'] if f['id']=='dead-command')==['bash scripts/gone.sh','composer run-script missing','make deploy','npm run legacy-build']"
check "a standalone CLAUDE.md shadowing AGENTS.md is crit" \
      "any(f['id']=='shadowed-standalone' and f['severity']=='crit' for f in D['findings'])"
check "over the 200-line ceiling is a warning" "any(f['id']=='over-ceiling' for f in D['findings'])"
check "split plan: setup to README, subsystem to a nested AGENTS.md, background to docs/" \
      "{p['section']:p['destination'] for p in D['split_plan']}=={'Setup':'README.md','Frontend notes':'web/AGENTS.md','Background':'docs/agents/background.md'}"
check "the Landmines and Commands sections are never in the split plan" \
      "not {'Landmines','Commands'} & {p['section'] for p in D['split_plan']}"
check "missing deploy section is a warning when deploy config exists" \
      "any(f['id']=='missing-section-deploy' and f['severity']=='warn' for f in D['findings'])"
check "staleness counted in commits, with manifest commits" \
      "D['commits_since']==16 and D['manifest_commits_since']==16 and any(f['id']=='stale' for f in D['findings'])"
check "human setup prose is flagged" "any(f['id']=='human-setup-prose' for f in D['findings'])"

"$PY" "$AM" audit --repo "$A" --no-parents --diff > "$TMP/p1.patch" 2>/dev/null
landmines_before="$("$PY" -c "import sys,re;t=open(sys.argv[1]).read();print(re.search(r'(?ms)^## Landmines\n.*?(?=^## )',t).group(0))" "$A/AGENTS.md")"
if gitq "$A" apply --check "$(winpath "$TMP/p1.patch")" 2>/dev/null && gitq "$A" apply "$(winpath "$TMP/p1.patch")"; then
    ok "--diff patch applies cleanly with git apply"
else
    no "--diff patch" "git apply failed"
fi
landmines_after="$("$PY" -c "import sys,re;t=open(sys.argv[1]).read();print(re.search(r'(?ms)^## Landmines\n.*?(?=^## )',t).group(0))" "$A/AGENTS.md")"
[ "$landmines_before" = "$landmines_after" ] && ok "the Landmines section survives byte for byte" \
    || no "landmines preserved" "the section changed"
head -1 "$A/CLAUDE.md" | grep -qx '@AGENTS.md' && ok "CLAUDE.md now imports @AGENTS.md first" || no "import fix" "$(head -1 "$A/CLAUDE.md")"
grep -q '^## Frontend notes' "$A/web/AGENTS.md" 2>/dev/null && grep -q '^## Setup' "$A/README.md" 2>/dev/null \
    && grep -q '^Paragraph 3 ' "$A/docs/agents/background.md" 2>/dev/null \
    && ok "moved sections land in README, the nested AGENTS.md and docs/" || no "split moves" "a destination is missing content"
grep -q 'npm run legacy-build  # agents-md: no "legacy-build" script' "$A/AGENTS.md" \
    && ok "dead commands are annotated, not deleted" || no "annotation" "not found"
n="$(wc -l < "$A/AGENTS.md")"
[ "$n" -le 200 ] && ok "upgraded AGENTS.md is back under the ceiling ($n lines)" || no "post-split size" "$n"
grep -qF 'Moved to [docs/agents/background.md](docs/agents/background.md); read it before work on background.' "$A/AGENTS.md" \
    && ok "split_pointer_names_a_task_trigger" || no "split_pointer_names_a_task_trigger" "$(grep -F 'background.md' "$A/AGENTS.md")"
commit "$A" "docs: apply agents-md upgrade"
OUT="$("$PY" "$AM" audit --repo "$A" --no-parents --json 2>/dev/null)"
check "re-audit: shadowing, size and deploy findings are gone" \
      "not {'shadowed-standalone','over-ceiling','missing-section-deploy'} & {f['id'] for f in D['findings']}"
check "split_pointers_are_not_bare" "'bare-pointer' not in {f['id'] for f in D['findings']}"
"$PY" "$AM" audit --repo "$A" --no-parents --diff > "$TMP/p2.patch" 2>/dev/null
grep -q 'legacy-build' "$TMP/p2.patch" && no "idempotent --diff" "annotation proposed twice" \
    || ok "a second --diff never re-annotates"

C="$TMP/crlf"; init_repo "$C"
echo '{"name":"c","scripts":{"build":"node b.js"}}' > "$C/package.json"
printf '# Agent Instructions - crlf\r\n\r\nA CRLF fixture.\r\n\r\n## Commands\r\n\r\n```bash\r\nnpm run build\r\n```\r\n' > "$C/AGENTS.md"
commit "$C" "docs: crlf agents"
"$PY" "$AM" audit --repo "$C" --no-parents --diff > "$TMP/crlf.patch" 2>/dev/null
gitq "$C" apply "$(winpath "$TMP/crlf.patch")" 2>/dev/null \
    && "$PY" -c "import sys;b=open(sys.argv[1],'rb').read();sys.exit(0 if b.count(b'\n')==b.count(b'\r\n') and b'## Landmines' in b else 1)" "$C/AGENTS.md" \
    && ok "a CRLF AGENTS.md stays CRLF through the patch" || no "CRLF" "mixed line endings or patch failed"

G="$TMP/good"; init_repo "$G"; good_agents "$G"; commit "$G" "docs: good agents"
OUT="$("$PY" "$AM" audit --repo "$G" --no-parents --json 2>/dev/null)"; rc=$?
check "clean control: no warn or crit findings" "not [f for f in D['findings'] if f['severity'] in ('warn','crit')]"
[ "$rc" -eq 0 ] && ok "clean control exits 0" || no "clean exit" "$rc"
[ -z "$("$PY" "$AM" audit --repo "$G" --no-parents --diff 2>/dev/null)" ] && ok "clean control: --diff is empty" \
    || no "clean diff" "patch not empty"
BP="$TMP/pointers"; init_repo "$BP"; good_agents "$BP"
n="$(wc -l < "$BP/AGENTS.md")"
{ echo "See [docs/x.md](docs/x.md)."
  echo "See [the wire doc](docs/wire.md) before changing the wire format."
  echo "See [When to deploy](docs/deploy.md)."
  echo "Moved to [docs/y.md](docs/y.md); read it when this topic matters."
  echo '```'; echo "see \`docs/in-a-fence.md\`"; echo '```'; } >> "$BP/AGENTS.md"
commit "$BP" "docs: pointers"
OUT="$("$PY" "$AM" audit --repo "$BP" --no-parents --json 2>/dev/null)"; rc=$?
check "bare_see_pointer_is_flagged" \
      "sorted(int(f['path'].split(':')[1]) for f in D['findings'] if f['id']=='bare-pointer')==[$((n+1)),$((n+3)),$((n+4))]"
[ "$rc" -eq 0 ] && ok "  ...an info finding, so the audit still exits 0" || no "bare-pointer exit" "$rc"

shadow_case() {   # SLUG NAME FILE CONTENT EXPECTED-ID [commit]
    local R="$TMP/sh-$1"; init_repo "$R"; good_agents "$R"; mkdir -p "$R/.claude"
    printf '%s' "$4" > "$R/$3"
    if [ "${6:-}" = commit ]; then commit "$R" "docs"; else gitq "$R" add AGENTS.md package.json; gitq "$R" commit -qm docs; fi
    OUT="$("$PY" "$AM" audit --repo "$R" --no-parents --json 2>/dev/null)"
    check "$2" "'$5' in {f['id'] for f in D['findings']}"
}
shadow_case prose "a prose pointer CLAUDE.md is crit" CLAUDE.md "See AGENTS.md for everything." shadowed-pointer-prose commit
shadow_case symtext "a symlink checked out as text is crit" CLAUDE.md "AGENTS.md" shadowed-symlink-text commit
"$PY" "$AM" audit --repo "$TMP/sh-symtext" --no-parents --diff 2>/dev/null | grep -qx '+@AGENTS.md' \
    && ok "  ...and the patch replaces it with an import" || no "symlink-text patch" "no +@AGENTS.md line"
shadow_case dotclaude ".claude/CLAUDE.md importing @../AGENTS.md is fine" .claude/CLAUDE.md "@../AGENTS.md" claude-imports commit
check "  ...and raises no crit" "not [f for f in D['findings'] if f['severity']=='crit']"
shadow_case local "an untracked CLAUDE.local.md warns (personal shadow)" CLAUDE.local.md "my notes" shadowed-by-claude-local
shadow_case localc "a committed CLAUDE.local.md is crit" CLAUDE.local.md "my notes" claude-local-committed commit
# A CLAUDE.md that copies AGENTS.md (what `/import` writes) must become the import plus
# the lines that differ. Prepending the import to the copy loads the content twice.
CP="$TMP/copy"; init_repo "$CP"; good_agents "$CP"
{ cat "$CP/AGENTS.md"; echo; echo "Use plan mode for anything under src/."; } > "$CP/CLAUDE.md"
commit "$CP" "docs: claude copy"
OUT="$("$PY" "$AM" audit --repo "$CP" --no-parents --json 2>/dev/null)"
check "claude_md_copy_is_flagged_as_a_copy" "'shadowed-copy' in {f['id'] for f in D['findings']}"
"$PY" "$AM" audit --repo "$CP" --no-parents --diff > "$TMP/copy.patch" 2>/dev/null
gitq "$CP" apply "$(winpath "$TMP/copy.patch")" 2>/dev/null
"$PY" - "$CP/CLAUDE.md" <<'EOF' && ok "claude_md_copy_is_replaced_not_imported_twice" || no "copy fix" "$(head -3 "$CP/CLAUDE.md")"
import sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
sys.exit(0 if lines == ["@AGENTS.md", "Use plan mode for anything under src/."] else 1)
EOF
CI2="$TMP/import-copy"; init_repo "$CI2"; good_agents "$CI2"
{ echo "@AGENTS.md"; echo; cat "$CI2/AGENTS.md"; } > "$CI2/CLAUDE.md"
commit "$CI2" "docs: import plus copy"
OUT="$("$PY" "$AM" audit --repo "$CI2" --no-parents --json 2>/dev/null)"
check "import_plus_copy_is_flagged" "'claude-imports-duplicate' in {f['id'] for f in D['findings']}"
"$PY" "$AM" audit --repo "$CI2" --no-parents --diff > "$TMP/import-copy.patch" 2>/dev/null
gitq "$CI2" apply "$(winpath "$TMP/import-copy.patch")" 2>/dev/null
[ "$(grep -cv '^[[:space:]]*$' "$CI2/CLAUDE.md")" = "1" ] && ok "import_plus_copy_keeps_only_the_import" \
    || no "import+copy fix" "$(cat "$CI2/CLAUDE.md" | head -3)"
N="$TMP/nested"; init_repo "$N"; good_agents "$N"; mkdir -p "$N/sub"
echo "# Sub rules" > "$N/sub/AGENTS.md"; echo "# Sub claude" > "$N/sub/CLAUDE.md"; commit "$N" "docs"
OUT="$("$PY" "$AM" audit --repo "$N" --no-parents --json 2>/dev/null)"
check "a nested CLAUDE.md shadowing sub/AGENTS.md warns" "'nested-shadowed' in {f['id'] for f in D['findings']}"
O="$TMP/outer"; mkdir -p "$O"; echo "# parent" > "$O/CLAUDE.md"; init_repo "$O/repo"; good_agents "$O/repo"; commit "$O/repo" "docs"
OUT="$("$PY" "$AM" audit --repo "$O/repo" --json 2>/dev/null)"
check "a CLAUDE.md in a parent directory warns" \
      "any(f['id']=='shadowed-by-parent' and 'outer' in f['path'] for f in D['findings'])"
OUT="$("$PY" "$AM" audit --repo "$O/repo" --no-parents --json 2>/dev/null)"
check "--no-parents skips the parent walk" "'shadowed-by-parent' not in {f['id'] for f in D['findings']}"
B="$TMP/bulky"; init_repo "$B"; echo '{"name":"b","scripts":{"build":"node b.js"}}' > "$B/package.json"
"$PY" - "$B/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - bulky", "", "A fixture whose bulk is all landmines.", "",
     "## Commands", "", "```bash", "npm run build", "```", "", "## Landmines", ""]
L += [f"{i}. **Rule {i}** - keep invariant {i} intact." for i in range(1, 231)]
open(sys.argv[1], "w", newline="\n").write("\n".join(L) + "\n")
EOF
commit "$B" "docs: bulky agents"
OUT="$("$PY" "$AM" audit --repo "$B" --no-parents --json 2>/dev/null)"
check "a doc that can't be split under target says so (landmines stay)" \
      "D['split_plan']==[] and any(f['id']=='split-insufficient' for f in D['findings'])"
# Size, not just lines: 199 lines can hold 16,744 characters when lines run long. The ceiling
# also counts characters (200 lines at 80 characters).
W="$TMP/wide"; init_repo "$W"; echo '{"name":"w","scripts":{"build":"node b.js"}}' > "$W/package.json"
"$PY" - "$W/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - wide", "", "A fixture whose lines run long. " + "word " * 400, "",
     "## Commands", "", "```bash", "npm run build", "```", "", "## Landmines", "",
     "1. **Rule** - keep it.", "", "## Setup", "", "Install the toolchain first.", "",
     "## Background", ""] + ["History of the project, told at length. " * 15 for _ in range(25)]
L += ["", "## Structure", "", "| Path | What |", "|---|---|"] + [f"| `d{i}/` | part {i} |" for i in range(10)]
open(sys.argv[1], "w", newline="\n").write("\n".join(L) + "\n")
EOF
commit "$W" "docs: wide agents"
OUT="$("$PY" "$AM" audit --repo "$W" --no-parents --json 2>/dev/null)"
check "a short file past 16,000 characters is over the ceiling" \
      "D['lines']<100 and D['chars']>16000 and any(f['id']=='over-ceiling' and 'characters' in f['msg'] for f in D['findings'])"
check "very long lines are reported with the longest line number" \
      "any(f['id']=='long-lines' and 'line 3' in f['msg'] for f in D['findings'])"
check "size split: setup first, the structure map stays" \
      "[p['section'] for p in D['split_plan']]==['Setup','Background']"
# Order of moves: excluded content (setup) first even when small, the structure map
# last; a generic "Quick reference" heading is not a Commands section.
T="$TMP/tiers"; init_repo "$T"; echo '{"name":"t","scripts":{"build":"node b.js"}}' > "$T/package.json"
mkdir -p "$T/src"; echo "x" > "$T/src/hooks.js"
"$PY" - "$T/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - tiers", "", "Fixture for the order of split moves.", "",
     "## Commands", "", "```bash", "npm run build", "```", "", "## Landmines", ""]
L += [f"{i}. **Rule {i}** - keep invariant {i} intact." for i in range(1, 96)]
L += ["", "## Install", ""] + [f"Step {i}: install tool {i}." for i in range(6)]
L += ["", "## Quick reference", ""] + [f"- Tip {i}: prefer the modern tool." for i in range(55)]
L += ["- Hooks live in `src/hooks.js` and `src/more.js`; `origin/main` is a ref, not a folder."]
L += ["", "## Structure", "", "| Path | What |", "|---|---|"] + [f"| `d{i}/` | part {i} |" for i in range(27)]
open(sys.argv[1], "w", newline="\n").write("\n".join(L) + "\n")
EOF
commit "$T" "docs: tiers agents"
OUT="$("$PY" "$AM" audit --repo "$T" --no-parents --json 2>/dev/null)"
check "split order: small setup section first, structure map kept" \
      "{p['section']:p['destination'] for p in D['split_plan']}=={'Install':'README.md','Quick reference':'docs/agents/quick-reference.md'}"
"$PY" "$AM" audit --repo "$T" --no-parents --diff 2>/dev/null \
    | grep -qF '+Moved to [docs/agents/quick-reference.md](docs/agents/quick-reference.md); read it before editing `src/**`.' \
    && ok "split_pointer_names_a_path_trigger" || no "split_pointer_names_a_path_trigger" "no src/** trigger in the patch"
# Landmine candidates the doc doesn't mention yet are listed (info), so an upgrade
# shows which git-history questions the Landmines section never answered.
U="$TMP/uncov"; init_repo "$U"; good_agents "$U"; echo "x" > "$U/x.js"; echo "y" > "$U/y.js"; echo "z" > "$U/z.js"
commit "$U" "feat: init"
for i in 1 2 3 4; do echo "$i" >> "$U/x.js"; echo "$i" >> "$U/y.js"; commit "$U" "feat: xy $i"; done
for i in 1 2 3; do echo "$i" >> "$U/z.js"; commit "$U" "fix: z bug $i"; done
echo "2. **x.js and y.js** - change them together." >> "$U/AGENTS.md"; commit "$U" "docs: landmine"
OUT="$("$PY" "$AM" audit --repo "$U" --no-parents --json 2>/dev/null)"; rc=$?
check "uncovered candidates: the fragile file, not the documented pair" \
      "[c['paths'] for c in D['uncovered_candidates']]==[['z.js']] and any(f['id']=='uncovered-candidates' and f['severity']=='info' for f in D['findings'])"
[ "$rc" -eq 0 ] && ok "  ...an info finding, so the audit still exits 0" || no "uncovered exit" "$rc"
# The ruled-out record (docs/agents/ruled-out.md, contract 1.4 of REPO-DOCTOR-ABC):
# one line per decision, honoured only while the evidence stays at or below its @count.
# z.js is fragile with 3 fix commits.
mkdir -p "$U/docs/agents"
ruled() { printf '%s\n' "$1" > "$U/docs/agents/ruled-out.md"; OUT="$("$PY" "$AM" audit --repo "$U" --no-parents --json 2>/dev/null)"; }
ruled '- [fragile] `z.js` @3: legacy parser, replaced next quarter'
check "ruled_out_line_silences_its_candidate" \
      "D['uncovered_candidates']==[] and D['ruled_out']==1"
ruled '- [fragile] `z.js` @2: legacy parser'
check "ruled_out_lapses_when_evidence_grows" \
      "[c['paths'] for c in D['uncovered_candidates']]==[['z.js']] and 'ruled-out-lapsed' in {f['id'] for f in D['findings']}"
ruled '- [coupling] `gone.js` `other.js` @4: a pair that no longer exists'
check "stale_ruled_out_line_is_reported" "'ruled-out-stale' in {f['id'] for f in D['findings']}"
ruled '- [fragile] `z.js` @3: maybe it is fine (proposed)'
check "proposed_line_is_not_honoured" \
      "D['ruled_out']==0 and [c['paths'] for c in D['uncovered_candidates']]==[['z.js']]"
ruled '- [fragile] `z.js` @3: was fine until 2000-01-01'
check "expired_line_is_not_honoured" \
      "D['ruled_out']==0 and 'ruled-out-expired' in {f['id'] for f in D['findings']}"
rm -rf "$U/docs/agents"
# Every tracked AGENTS.md is audited, nested ones against their own folder: budget,
# a root pointer, a scope line, no copy of the root, commands checked against the
# folder's manifest and the root, staleness counted on the folder's own commits.
NA="$TMP/nestaud"; make_monorepo "$NA" >/dev/null 2>&1; rm -rf "$NA/.ruler"
"$PY" - "$NA" <<'EOF'
import sys
r = sys.argv[1]
shared = ["- Every package exports through its own src/index.ts entry point only.",
          "- Shared types live in the engine and are re-exported, never redefined.",
          "- Each package keeps its own tests beside its source files today."]
root = ["# Agent Instructions - monorepo", "", "A fixture monorepo: an engine, a UI package and a web app.", "",
        "## Commands", "", "```bash", "npm run check", "```", "", "## Landmines", "",
        "1. **The parser shim** - `packages/engine/src/fragile.ts` keeps its compatibility shim.", "",
        "## Structure", "", "- Before editing `packages/engine/**`, read [packages/engine/AGENTS.md](packages/engine/AGENTS.md).",
        "", "## Conventions", ""] + shared
engine = ["# Engine", "", "Applies to `packages/engine/` and below; extends the root [AGENTS.md](../../AGENTS.md).", "",
          "## Commands", "", "```bash", "npm -w packages/engine run check:deps", "npm run check:deps", "npm run nope", "```"]
ui = ["# UI", "", "Notes for the user interface package.", ""] + shared + [f"- Note {i}: keep components small." for i in range(64)]
for path, lines in (("AGENTS.md", root), ("packages/engine/AGENTS.md", engine), ("packages/ui/AGENTS.md", ui)):
    open(f"{r}/{path}", "w", newline="\n").write("\n".join(lines) + "\n")
EOF
commit "$NA" "docs: nested agents"
for i in $(seq 1 16); do echo "$i" >> "$NA/README.md"; commit "$NA" "docs: readme $i"; done
for i in $(seq 1 16); do echo "// $i" >> "$NA/packages/ui/src/u01.ts"; commit "$NA" "feat: ui $i"; done
OUT="$("$PY" "$AM" audit --repo "$NA" --no-parents --json 2>/dev/null)"
nf() { printf "any(f['id']=='%s' and f['path'].split(':')[0]=='%s' for f in D['findings'])" "$1" "$2"; }
check "data_docs_lists_every_entry_doc" \
      "{x['path']:x['kind'] for x in D['docs']}=={'AGENTS.md':'root','packages/engine/AGENTS.md':'nested','packages/ui/AGENTS.md':'nested'}"
check "nested_doc_over_budget_warns" \
      "any(f['id']=='nested-over-budget' and f['severity']=='warn' and f['path']=='packages/ui/AGENTS.md' for f in D['findings']) and not $(nf nested-over-budget packages/engine/AGENTS.md)"
check "unlinked_nested_doc_warns" \
      "$(nf nested-unlinked packages/ui/AGENTS.md) and not $(nf nested-unlinked packages/engine/AGENTS.md)"
check "nested_staleness_counts_only_its_subtree" \
      "$(nf nested-stale packages/ui/AGENTS.md) and not $(nf nested-stale packages/engine/AGENTS.md)"
check "nested_dead_command_checked_against_own_manifest" \
      "[f['msg'].split(chr(96))[1] for f in D['findings'] if f['id']=='nested-dead-command']==['npm run nope']"
check "nested_doc_that_never_names_its_folder_is_flagged" \
      "$(nf nested-no-scope packages/ui/AGENTS.md) and not $(nf nested-no-scope packages/engine/AGENTS.md)"
check "nested_doc_restating_the_root_is_flagged" "$(nf nested-restates-root packages/ui/AGENTS.md)"
"$PY" "$AM" audit --repo "$NA" --no-parents --diff > "$TMP/na.patch" 2>/dev/null
grep -qxF '+- Before editing `packages/ui/**`, read [packages/ui/AGENTS.md](packages/ui/AGENTS.md).' "$TMP/na.patch" \
    && gitq "$NA" apply "$(winpath "$TMP/na.patch")" 2>/dev/null \
    && ok "unlinked_nested_doc_gets_a_trigger_pointer" || no "unlinked_nested_doc_gets_a_trigger_pointer" "$(grep '^+' "$TMP/na.patch" | head -5)"
commit "$NA" "docs: link the ui doc"
OUT="$("$PY" "$AM" audit --repo "$NA" --no-parents --json 2>/dev/null)"
check "  ...and the re-audit finds it linked" "not $(nf nested-unlinked packages/ui/AGENTS.md)"
# Routing: a candidate is answered by the deepest AGENTS.md whose folder holds all of its
# paths. The engine doc covers parse.ts, so the root is not asked about it; the a01/a02
# pair is the engine doc's open question, not the root's.
echo '- `packages/engine/src/parse.ts` keeps breaking: run the suite after every edit.' >> "$NA/packages/engine/AGENTS.md"
commit "$NA" "docs: engine landmine"
OUT="$("$PY" "$AM" audit --repo "$NA" --no-parents --json 2>/dev/null)"
check "candidate_inside_nested_dir_is_owned_by_nested_doc" \
      "[(c['doc'],c['paths']) for c in D['uncovered_candidates'] if c['paths'][0].startswith('packages/engine/')]==[('packages/engine/AGENTS.md',['packages/engine/src/a01.ts','packages/engine/src/a02.ts'])] and not any(f['id']=='uncovered-candidates' and f['path']=='AGENTS.md' and 'packages/engine/' in f['msg'] for f in D['findings'])"
# A root landmine about one package is reported against the nested doc that owns the
# folder; the patch leaves it where it is (moving landmines is the owner's call).
check "root_landmine_about_one_package_is_flagged_not_moved" \
      "any(f['id']=='landmine-belongs-nested' and f['path']=='AGENTS.md:13' and 'packages/engine/AGENTS.md' in f['msg'] for f in D['findings']) and not any(l.startswith('-') and 'The parser shim' in l for l in (D['diff'] or '').splitlines())"
# A root with an Ownership table gets a row there, in the table's own columns.
OW="$TMP/owner"; init_repo "$OW"; good_agents "$OW"; mkdir -p "$OW/eng" "$OW/lib"
printf '\n## Ownership\n\n| Area | Path | Entry doc | Gate |\n|---|---|---|---|\n| eng | `eng/` | [eng/AGENTS.md](eng/AGENTS.md) | `npm test` |\n' >> "$OW/AGENTS.md"
printf '# Eng\n\nApplies to `eng/`.\n' > "$OW/eng/AGENTS.md"; printf '# Lib\n\nApplies to `lib/`.\n' > "$OW/lib/AGENTS.md"
commit "$OW" "docs: ownership"
"$PY" "$AM" audit --repo "$OW" --no-parents --diff 2>/dev/null \
    | grep -qxF '+| lib | `lib/` | [lib/AGENTS.md](lib/AGENTS.md) |  |' \
    && ok "pointer_lands_in_the_ownership_table" || no "pointer_lands_in_the_ownership_table" "no table row in the patch"
M="$TMP/missing"; init_repo "$M"; echo x > "$M/f"; commit "$M" "x"
OUT="$("$PY" "$AM" audit --repo "$M" --no-parents --json 2>/dev/null)"; rc=$?
check "no AGENTS.md is crit" "D['findings'][0]['id']=='missing-agents-md'"
[ "$rc" -eq 10 ] && ok "no AGENTS.md exits 10" || no "missing exit" "$rc"

# ============================== EXPLAIN =======================================
# explain <folder> lists what each tool loads for work there, in order, with the reason,
# from assets/agents-md/tool-profiles.json. Imports resolve from the importing file,
# skip code spans and fences, stop at a cycle.
EX="$TMP/explain"; make_monorepo "$EX" >/dev/null 2>&1
printf '# Engine\n\nApplies to `packages/engine/`.\n' > "$EX/packages/engine/AGENTS.md"
printf '# Extra\n\n@cyc.md\n' > "$EX/docs/agents/extra.md"; printf '@extra.md\n' > "$EX/docs/agents/cyc.md"
printf 'x\n' > "$EX/docs/agents/code.md"; printf 'x\n' > "$EX/docs/agents/fenced.md"
printf '\nNot an import: `see @docs/agents/code.md`.\n\n```\n@docs/agents/fenced.md\n```\n' >> "$EX/AGENTS.md"
commit "$EX" "docs: explain fixture"
OUT="$("$PY" "$AM" explain --repo "$EX" packages/engine --json 2>/dev/null)"
tool() { printf "next(x for x in D['tools'] if x['tool']=='%s')" "$1"; }
check "explain_lists_files_in_load_order_with_reasons" \
      "[(x['path'],x['reason']) for x in $(tool claude-code)['files']]==[('AGENTS.md','ancestor'),('docs/agents/extra.md','import'),('docs/agents/cyc.md','import'),('packages/engine/AGENTS.md','nested-on-read')] and $(tool claude-code)['totals']['chars']==sum(x['chars'] for x in $(tool claude-code)['files']) and d['meta']['schema']=='claude-mods.repo-doctor.agents-md-explain/v1'"
check "import_in_code_span_is_not_counted" \
      "not {'docs/agents/code.md','docs/agents/fenced.md'} & {x['path'] for x in $(tool claude-code)['files']}"
check "import_cycle_is_reported" "any('cycle' in n for n in $(tool claude-code)['notes'])"
printf '# Override\n\nApplies to `packages/engine/`.\n' > "$EX/packages/engine/AGENTS.override.md"
OUT="$("$PY" "$AM" explain --repo "$EX" packages/engine --tool codex --json 2>/dev/null)"
check "explain_codex_prefers_override_and_one_file_per_dir" \
      "[(x['path'],x['reason']) for x in $(tool codex)['files']]==[('AGENTS.md','ancestor'),('packages/engine/AGENTS.override.md','ancestor')]"
printf '# Engine notes for Claude\n' > "$EX/packages/engine/CLAUDE.md"
OUT="$("$PY" "$AM" explain --repo "$EX" packages/engine --json 2>/dev/null)"
check "explain_claude_skips_agents_md_beside_claude_md" \
      "'packages/engine/CLAUDE.md' in [x['path'] for x in $(tool claude-code)['files']] and 'packages/engine/AGENTS.md' not in [x['path'] for x in $(tool claude-code)['files']]"
OUT="$("$PY" "$AM" explain --repo "$EX" packages/engine --tool all --json 2>/dev/null)"
check "explain --tool all covers every profile" "len(D['tools'])>=9"
"$PY" "$AM" explain --repo "$EX" no/such/dir >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "explain on a missing folder exits 3" || no "explain missing folder" "exit $rc"
"$PY" "$AM" explain --repo "$EX" packages/engine --tool nosuch >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "explain with an unknown tool exits 2" || no "explain unknown tool" "exit $rc"
# The audit runs the same engine over the root and every nested folder (data.load[]).
RS="$TMP/starve"; init_repo "$RS"; mkdir -p "$RS/sub"
"$PY" - "$RS" <<'EOF'
import sys
r = sys.argv[1]
body = ["# Agent Instructions - big", "", "A fixture whose root fills the Codex budget.", "",
        "## Commands", "", "```bash", "make check", "```", "", "## Landmines", "",
        "1. **Rule** - keep it."] + ["- " + "padding text for the budget " * 10 for _ in range(105)]
open(f"{r}/AGENTS.md", "w", newline="\n").write("\n".join(body) + "\n")
open(f"{r}/sub/AGENTS.md", "w", newline="\n").write("# Sub\n\nApplies to `sub/`.\n\n" + "- sub note words here\n" * 150)
open(f"{r}/Makefile", "w", newline="\n").write("check:\n\techo ok\n")
EOF
echo "- Before editing \`sub/**\`, read [sub/AGENTS.md](sub/AGENTS.md)." >> "$RS/AGENTS.md"
commit "$RS" "docs: big root"
OUT="$("$PY" "$AM" audit --repo "$RS" --no-parents --json 2>/dev/null)"
check "root_starves_nested_under_codex_cap" \
      "$(nf root-starves-nested sub/AGENTS.md) and $(nf root-starves-nested AGENTS.md)"
check "load_chain_over_budget_warns" \
      "any(f['id']=='load-over-budget' and f['severity']=='warn' for f in D['findings']) and any(x['dir']=='sub/' and x['claude_code_chars']>20800 for x in D['load'])"
# A tool's caps apply only when the repo visibly targets it (.windsurf/ for Windsurf).
TC="$TMP/toolcap"; init_repo "$TC"; good_agents "$TC"
"$PY" -c "import sys;open(sys.argv[1],'a',newline='\n').write(''.join(f'- Note {i}: '+'context words '*8+'\n' for i in range(115)))" "$TC/AGENTS.md"
commit "$TC" "docs: 15k agents"
OUT="$("$PY" "$AM" audit --repo "$TC" --no-parents --json 2>/dev/null)"
check "tool_cap_only_for_targeted_tools" "'tool-cap' not in {f['id'] for f in D['findings']}"
mkdir -p "$TC/.windsurf"
OUT="$("$PY" "$AM" audit --repo "$TC" --no-parents --json 2>/dev/null)"
check "  ...and reported once the repo targets that tool" \
      "any(f['id']=='tool-cap' and 'Windsurf' in f['msg'] and '12000' in f['msg'] for f in D['findings']) and not any('6000' in f['msg'] for f in D['findings'])"

# ============================== ARCHITECTURE ==================================
# scaffold --architecture drafts ARCHITECTURE.md in matklad's shape: entry points and a
# codemap NAMED from facts (never linked: links rot), owner questions for the rest, and a
# layout fingerprint the audit later compares against the tree.
AR="$TMP/arch"; make_monorepo "$AR" >/dev/null 2>&1; rm -rf "$AR/.ruler"; commit "$AR" "chore: drop ruler"
OUT="$("$PY" "$AM" scaffold --repo "$AR" --architecture --json 2>/dev/null)"
check "architecture_draft_names_entry_points_without_links" \
      "chr(96)+'packages/engine/src/index.ts'+chr(96) in D['draft'] and chr(96)+'packages/engine/'+chr(96) in D['draft'] and not __import__('re').search(r'\]\([^)]*\.(ts|js|py)\b', D['draft']) and __import__('re').search(r'<!-- layout: [0-9a-f]{40}', D['draft']) and 'TODO(owner)' in D['draft'] and D['lines']<=200"
"$PY" "$AM" scaffold --repo "$AR" --architecture --write 2>/dev/null; rc1=$?
"$PY" "$AM" scaffold --repo "$AR" --architecture --write 2>/dev/null; rc2=$?
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 5 ] && ok "architecture --write creates once, then refuses" || no "architecture write" "exits $rc1 then $rc2"
commit "$AR" "docs: architecture"
OUT="$("$PY" "$AM" audit --repo "$AR" --no-parents --json 2>/dev/null)"
check "a fresh architecture doc is not stale" \
      "not {'architecture-stale-layout','architecture-stale-name'} & {f['id'] for f in D['findings']} and 'architecture' in [x['kind'] for x in D['docs']]"
check "unlinked_architecture_doc_gets_a_root_pointer" \
      "any(f['id']=='architecture-unlinked' for f in D['findings']) and '+- Read [ARCHITECTURE.md](ARCHITECTURE.md) before adding a module or moving code between packages.' in (D['diff'] or '').splitlines()"
mkdir -p "$AR/libs/core"; echo 'export const core = 1' > "$AR/libs/core/x.ts"
gitq "$AR" mv packages/ui packages/widgets; commit "$AR" "refactor: rename ui to widgets, add libs"
OUT="$("$PY" "$AM" audit --repo "$AR" --no-parents --json 2>/dev/null)"
check "architecture_stale_layout_from_fingerprint" \
      "any(f['id']=='architecture-stale-layout' and 'libs/' in f['msg'] and 'packages/ui/' in f['msg'] for f in D['findings'])"
check "architecture_stale_name_suggests_rename" \
      "any(f['id']=='architecture-stale-name' and 'packages/ui/' in f['msg'] and 'packages/widgets/' in f['msg'] for f in D['findings'])"
printf '\nThis section is outdated.\nSee [the parser](packages/engine/src/parse.ts#L10).\n' >> "$AR/ARCHITECTURE.md"; commit "$AR" "docs: rot"
OUT="$("$PY" "$AM" audit --repo "$AR" --no-parents --json 2>/dev/null)"
check "architecture_marker_and_code_links_are_info" \
      "{f['severity'] for f in D['findings'] if f['id'] in ('architecture-stale-marker','architecture-links-code')}=={'info'} and {'architecture-stale-marker','architecture-links-code'} <= {f['id'] for f in D['findings']}"
# When ARCHITECTURE.md exists, an overflowing Structure section moves to its codemap,
# not to docs/agents/structure.md.
SO="$TMP/overflow"; init_repo "$SO"; echo '{"name":"so","scripts":{"build":"node b.js"}}' > "$SO/package.json"
printf '# Architecture - so\n\n## Codemap\n\n- `src/`: the code.\n' > "$SO/ARCHITECTURE.md"
"$PY" - "$SO/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - so", "", "Fixture for the structure overflow.", "",
     "## Commands", "", "```bash", "npm run build", "```", "", "## Landmines", ""]
L += [f"{i}. **Rule {i}** - keep invariant {i} intact." for i in range(1, 101)]
L += ["", "## Background", ""] + [f"Paragraph {i} of history about the project." for i in range(40)]
L += ["", "## Structure", "", "| Path | What |", "|---|---|"] + [f"| `d{i}/` | part {i} |" for i in range(70)]
L += ["", "Read [ARCHITECTURE.md](ARCHITECTURE.md) before adding a module."]
open(sys.argv[1], "w", newline="\n").write("\n".join(L) + "\n")
EOF
commit "$SO" "docs: overflow"
OUT="$("$PY" "$AM" audit --repo "$SO" --no-parents --json 2>/dev/null)"
check "structure_overflow_moves_to_architecture" \
      "{p['section']:p['destination'] for p in D['split_plan']}.get('Structure')=='ARCHITECTURE.md'"

# A prose invariant ("X never imports Y", "only X touches Y", an ARCHITECTURE.md callout)
# is reported when no detected gate covers the folders it names: db/ has a
# dependency-cruiser config, core/ and ui/ have nothing enforcing the rule.
IG="$TMP/invariant"; init_repo "$IG"; mkdir -p "$IG/core" "$IG/ui" "$IG/db"
echo '{"name":"inv","scripts":{"test":"node t.js"}}' > "$IG/package.json"
for d in core ui db; do echo "export const $d = 1" > "$IG/$d/index.js"; done
printf 'module.exports = { forbidden: [] }\n' > "$IG/db/.dependency-cruiser.cjs"
"$PY" - "$IG/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - inv", "", "A fixture for prose invariants.", "", "## Commands", "",
     "```bash", "npm test", "```", "", "## Landmines", "",
     "1. **Layering** - `core/` never imports `ui/`.",
     "2. **Storage** - only `db/` touches the database.", "", "## Conventions", "", "- Keep functions short."]
open(sys.argv[1], "w", newline="\n").write("\n".join(L) + "\n")
EOF
printf '# Architecture - inv\n\n## Invariants\n\nArchitecture Invariant: `ui/` never calls `db/` directly.\n' > "$IG/ARCHITECTURE.md"
commit "$IG" "docs: invariants"
OUT="$("$PY" "$AM" audit --repo "$IG" --no-parents --json 2>/dev/null)"
check "prose_invariant_without_gate_is_flagged" \
      "sorted(f['path'] for f in D['findings'] if f['id']=='invariant-ungated')==['AGENTS.md:13','ARCHITECTURE.md:5'] and all(f['severity']=='info' for f in D['findings'] if f['id']=='invariant-ungated')"

# ============================== HYGIENE =======================================
# A generated AGENTS.md (ruler, rulesync, a Source header) is reported against its source,
# and the patch edits the source, never the output the next sync overwrites.
GR="$TMP/ruler"; make_monorepo "$GR" >/dev/null 2>&1
OUT="$("$PY" "$AM" audit --repo "$GR" --no-parents --json 2>/dev/null)"
check "generated_entry_doc_patches_the_source" \
      "any(f['id']=='generated-entry-doc' and '.ruler/' in f['msg'] for f in D['findings']) and 'diff --git a/AGENTS.md' not in (D['diff'] or '')"
GS="$TMP/srchdr"; init_repo "$GS"; good_agents "$GS"; mkdir -p "$GS/docs"
"$PY" - "$GS" <<'EOF'
import sys
r = sys.argv[1]
body = open(f"{r}/AGENTS.md").read().replace("npm test\n", "npm test\nnpm run gone\n")
open(f"{r}/docs/agents-src.md", "w", newline="\n").write(body)
open(f"{r}/AGENTS.md", "w", newline="\n").write("<!-- Source: docs/agents-src.md -->\n" + body)
EOF
commit "$GS" "docs: generated agents"
OUT="$("$PY" "$AM" audit --repo "$GS" --no-parents --json 2>/dev/null)"
check "  ...and a Source header's file gets the patch instead" \
      "'diff --git a/docs/agents-src.md' in (D['diff'] or '') and 'diff --git a/AGENTS.md' not in (D['diff'] or '') and 'agents-md: no ' in (D['diff'] or '')"
# A backticked path git once tracked and no longer has is dead; the annotation names the
# path history renamed it to.
DP="$TMP/deadpath"; init_repo "$DP"; good_agents "$DP"; mkdir -p "$DP/src"; echo "x" > "$DP/src/old.js"
echo "- The parser lives in \`src/old.js\`; \`dist/out.js\` is built." >> "$DP/AGENTS.md"; commit "$DP" "docs: parser"
gitq "$DP" mv src/old.js src/new.js; commit "$DP" "refactor: rename the parser"
OUT="$("$PY" "$AM" audit --repo "$DP" --no-parents --json 2>/dev/null)"
check "dead_path_suggests_rename" \
      "[f['msg'] for f in D['findings'] if f['id']=='dead-path']==['\`src/old.js\` is gone: git history renamed it to \`src/new.js\`'] and 'renamed to \`src/new.js\`' in (D['diff'] or '')"
# audit --explain <finding-id> prints the rule, where it comes from, and this repo's evidence.
EXPL="$("$PY" "$AM" audit --repo "$DP" --no-parents --explain dead-path 2>/dev/null)"; rc=$?
printf '%s' "$EXPL" | grep -q '^rule: ' && printf '%s' "$EXPL" | grep -q '^source: ' \
    && printf '%s' "$EXPL" | grep -q 'src/new.js' && [ "$rc" -eq 0 ] \
    && ok "explain_finding_prints_rule_and_source" || no "explain_finding_prints_rule_and_source" "$EXPL (exit $rc)"
"$PY" "$AM" audit --repo "$DP" --no-parents --explain no-such-finding >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "  ...and an unknown finding id exits 2" || no "explain unknown id" "exit $rc"

# scaffold --json splits the owner questions (Lane C): guided ones the facts can answer
# carry a recommended answer with its source; assisted ones need the owner and carry only
# their evidence. Only assisted questions should ever reach the owner.
QJ="$TMP/questions"; init_repo "$QJ"; mkdir -p "$QJ/src" "$QJ/.github/workflows"
echo '{"name":"q","description":"A queue worker for billing events.","scripts":{"build":"node b.js","test":"node t.js"}}' > "$QJ/package.json"
printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm test\n' > "$QJ/.github/workflows/ci.yml"
echo "x" > "$QJ/src/x.js"; commit "$QJ" "feat: init"
for i in 1 2 3; do echo "$i" >> "$QJ/src/x.js"; commit "$QJ" "fix: x bug $i"; done
OUT="$("$PY" "$AM" scaffold --repo "$QJ" --json 2>/dev/null)"
q() { printf "next(x for x in D['questions'] if x['id']=='%s')" "$1"; }
check "scaffold_json_splits_guided_from_assisted" \
      "$(q overview)['answerable']=='guided' and $(q overview)['recommended']=={'answer':'A queue worker for billing events.','source':'package.json'} and $(q check-command)['answerable']=='guided' and 'npm test' in $(q check-command)['recommended']['answer'] and any(x['id'].startswith('landmine:') and x['answerable']=='assisted' and x['evidence'] and 'recommended' not in x for x in D['questions']) and all(x['answerable'] in ('guided','assisted') for x in D['questions']) and (D['guided'],D['assisted'])==(sum(x['answerable']=='guided' for x in D['questions']),sum(x['answerable']=='assisted' for x in D['questions']))"

# ============================== REFUTE REGRESSIONS ============================
# From the 2026-10-07 adversarial review: each case below was a crash, a broken guarantee
# or a false finding the suites above passed.
# A tracked nested doc missing from disk (a sparse checkout) is skipped, not a traceback.
MN="$TMP/sparse"; init_repo "$MN"; good_agents "$MN"; mkdir -p "$MN/sub"; printf '# Sub\n\nApplies to `sub/`.\n' > "$MN/sub/AGENTS.md"
commit "$MN" "docs: nested"; rm "$MN/sub/AGENTS.md"
OUT="$("$PY" "$AM" audit --repo "$MN" --no-parents --json 2>/dev/null)"
check "missing_nested_doc_on_disk_does_not_crash" "d['meta']['schema']=='claude-mods.repo-doctor.agents-md-audit/v1'"
# A landmine block under a movable section never leaves AGENTS.md: the split skips a
# section holding a Gotchas/Landmines subsection.
LS="$TMP/subland"; init_repo "$LS"; echo '{"name":"ls","scripts":{"build":"node b.js"}}' > "$LS/package.json"
"$PY" - "$LS/AGENTS.md" <<'EOF'
import sys
L = ["# Agent Instructions - ls", "", "Fixture for landmines under a movable section.", "",
     "## Commands", "", "```bash", "npm run build", "```", "", "## Landmines", "", "1. **Rule** - keep it.", "",
     "## Background", ""] + [f"Paragraph {i} of history." for i in range(120)]
L += ["", "### Gotchas", "", "- **BG-LANDMINE-SENTINEL** - the cache key must include the locale.", ""]
L += ["## Notes", ""] + [f"- Note {i}: a tip." for i in range(80)]
open(sys.argv[1], "w", newline="\n").write("\n".join(L) + "\n")
EOF
commit "$LS" "docs: subsection landmine"
OUT="$("$PY" "$AM" audit --repo "$LS" --no-parents --json 2>/dev/null)"
check "landmine_subsection_never_moves" \
      "D['split_plan'] and 'Background' not in [x['section'] for x in D['split_plan']] and not any(l.startswith('-') and 'BG-LANDMINE-SENTINEL' in l for l in (D['diff'] or '').splitlines())"
# A generated CLAUDE.md is fixed at its source like a generated AGENTS.md.
GC="$TMP/rulerclaude"; init_repo "$GC"; good_agents "$GC"; mkdir -p "$GC/.ruler"; echo "# rules" > "$GC/.ruler/rules.md"
printf '<!-- Generated by Ruler -->\n# Claude\n' > "$GC/CLAUDE.md"; commit "$GC" "docs: ruler claude"
OUT="$("$PY" "$AM" audit --repo "$GC" --no-parents --json 2>/dev/null)"
check "generated_claude_md_is_not_patched" \
      "any(f['id']=='generated-entry-doc' and f['path']=='CLAUDE.md' for f in D['findings']) and 'diff --git a/CLAUDE.md' not in (D['diff'] or '')"
# A folder outside the repo is refused, absolute or not.
mkdir -p "$TMP/outside"
"$PY" "$AM" scaffold --repo "$MN" --dir "$(winpath "$TMP/outside")" --write >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && [ ! -f "$TMP/outside/AGENTS.md" ] && ok "absolute_dir_outside_the_repo_is_refused" \
    || no "absolute_dir_outside_the_repo_is_refused" "exit $rc"
"$PY" "$AM" explain --repo "$MN" "$(winpath "$TMP/outside")" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "  ...and explain refuses it too" || no "explain outside" "exit $rc"
# A .claude/AGENTS.md root is what Claude Code loads, and scaffold --write won't add a second root.
DC="$TMP/dotclaude"; init_repo "$DC"; good_agents "$DC"; mkdir -p "$DC/.claude"; mv "$DC/AGENTS.md" "$DC/.claude/AGENTS.md"
commit "$DC" "docs: dot-claude root"
OUT="$("$PY" "$AM" explain --repo "$DC" . --json 2>/dev/null)"
check "dot_claude_agents_md_is_loaded" "'.claude/AGENTS.md' in [x['path'] for x in D['tools'][0]['files']]"
"$PY" "$AM" scaffold --repo "$DC" --write >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && [ ! -f "$DC/AGENTS.md" ] && ok "  ...and scaffold --write refuses a second root" || no "dot-claude write" "exit $rc"
# Size is counted as LF text: a CRLF nested doc under the budget is not over it.
CN="$TMP/crlfnest"; init_repo "$CN"; good_agents "$CN"; mkdir -p "$CN/sub"
echo "- Before editing \`sub/**\`, read [sub/AGENTS.md](sub/AGENTS.md)." >> "$CN/AGENTS.md"
"$PY" -c "import sys;open(sys.argv[1],'w',newline='\r\n').write('# Sub\nApplies to \`sub/\`.\n'+''.join('- '+'n'*79+'\n' for _ in range(58)))" "$CN/sub/AGENTS.md"
commit "$CN" "docs: crlf nested"
OUT="$("$PY" "$AM" audit --repo "$CN" --no-parents --json 2>/dev/null)"
check "crlf_nested_doc_is_measured_like_lf" \
      "not any(f['id']=='nested-over-budget' and f['severity']=='warn' for f in D['findings']) and [x['chars'] for x in D['docs'] if x['path']=='sub/AGENTS.md'][0] <= 4800"
# A docs/ARCHITECTURE.md gets a root pointer to where it actually is.
DA="$TMP/docsarch"; init_repo "$DA"; good_agents "$DA"; mkdir -p "$DA/docs"
printf '# Architecture\n\n## Codemap\n\n- `src/`: code.\n' > "$DA/docs/ARCHITECTURE.md"; commit "$DA" "docs: arch in docs"
OUT="$("$PY" "$AM" audit --repo "$DA" --no-parents --json 2>/dev/null)"
check "docs_architecture_pointer_links_its_path" \
      "'+- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before adding a module or moving code between packages.' in (D['diff'] or '').splitlines()"
# A scope line may start with ./; a prose word that happens to be the folder name is not one.
NS="$TMP/scope"; init_repo "$NS"; good_agents "$NS"; mkdir -p "$NS/pkg/a" "$NS/tools"
printf '\n- [pkg/a/AGENTS.md](pkg/a/AGENTS.md) and [tools/AGENTS.md](tools/AGENTS.md) load when editing there.\n' >> "$NS/AGENTS.md"
printf '# A\n\nApplies to `./pkg/a/` and below.\n' > "$NS/pkg/a/AGENTS.md"; printf '# Tools\n\nThese tools are helpers.\n' > "$NS/tools/AGENTS.md"
commit "$NS" "docs: scopes"
OUT="$("$PY" "$AM" audit --repo "$NS" --no-parents --json 2>/dev/null)"
check "nested_scope_line_forms" \
      "sorted(f['path'] for f in D['findings'] if f['id']=='nested-no-scope')==['tools/AGENTS.md']"
# A codemap name git never tracked (a bare file name, a symbol) is not stale; a path git
# tracked and lost is.
AN="$TMP/archnames"; init_repo "$AN"; good_agents "$AN"; mkdir -p "$AN/src"; echo x > "$AN/src/gone.rs"; echo x > "$AN/src/lib.rs"
printf '# Architecture\n\n## Codemap\n\n- `lib.rs` holds `Config.load`; `src/gone.rs` parses.\n' > "$AN/ARCHITECTURE.md"
commit "$AN" "docs: names"; gitq "$AN" rm -q src/gone.rs; commit "$AN" "refactor: drop gone.rs"
OUT="$("$PY" "$AM" audit --repo "$AN" --no-parents --json 2>/dev/null)"
check "architecture_stale_name_needs_history" \
      "[f['msg'].split(chr(96))[1] for f in D['findings'] if f['id']=='architecture-stale-name']==['src/gone.rs']"
# One unrelated check script does not gate every invariant; a script that names the
# invariant's folders does.
GI="$TMP/gateinv"; init_repo "$GI"; mkdir -p "$GI/core" "$GI/ui" "$GI/scripts"
echo '{"name":"gi","scripts":{"test":"node t.js"}}' > "$GI/package.json"
for d in core ui; do echo "export const $d = 1" > "$GI/$d/index.js"; done
echo 'echo links ok' > "$GI/scripts/check-links.sh"
printf '# Agent Instructions - gi\n\nA fixture.\n\n## Commands\n\n```bash\nnpm test\n```\n\n## Landmines\n\n1. **Layering** - `core/` never imports `ui/`.\n' > "$GI/AGENTS.md"
commit "$GI" "docs: invariant"
OUT="$("$PY" "$AM" audit --repo "$GI" --no-parents --json 2>/dev/null)"
check "one_check_script_does_not_gate_every_invariant" "any(f['id']=='invariant-ungated' for f in D['findings'])"
echo 'rg -q "from .*ui/" core/ && exit 1' > "$GI/scripts/check-layers.sh"; commit "$GI" "test: layer gate"
OUT="$("$PY" "$AM" audit --repo "$GI" --no-parents --json 2>/dev/null)"
check "  ...but a script naming both folders does" "not any(f['id']=='invariant-ungated' for f in D['findings'])"
# The interview never re-asks a question the owner ruled out.
mkdir -p "$QJ/docs/agents"; echo '- [fragile] `src/x.js` @3: an old parser, retired soon' > "$QJ/docs/agents/ruled-out.md"
commit "$QJ" "docs: rule out x.js"
OUT="$("$PY" "$AM" scaffold --repo "$QJ" --json 2>/dev/null)"
check "scaffold_questions_skip_ruled_out" "not any(x['id']=='landmine:fragile:src/x.js' for x in D['questions'])"

# ============================== SURVEY ========================================
FX="$TMP/gh-fixture.json"; LOG="$TMP/gh-calls.jsonl"
"$PY" - "$FX" <<'EOF'
import base64, json, sys
good = open(sys.argv[1].replace("gh-fixture.json", "good/AGENTS.md")).read()
big = good + "".join(f"\nfiller line {i}" for i in range(230))
repos, api = [], {}
def repo(name, files, ahead=2, branch="main", archived=False):
    full = f"acme/{name}"
    repos.append({"nameWithOwner": full, "isArchived": archived,
                  "defaultBranchRef": {"name": branch} if branch else None})
    if not branch:
        return
    tree = []
    for path, (content, mode) in files.items():
        sha = f"{name}-{path}".replace("/", "_")
        tree.append({"path": path, "mode": mode, "type": "blob", "sha": sha})
        api[f"repos/{full}/git/blobs/{sha}"] = {"encoding": "base64",
                                                "content": base64.b64encode(content.encode()).decode()}
    api[f"repos/{full}/git/trees/{branch}?recursive=1"] = {"tree": tree, "truncated": False}
    if "AGENTS.md" in files:
        api[f"repos/{full}/commits?sha={branch}&path=AGENTS.md&per_page=1"] = [{"sha": f"{name}sha"}]
        api[f"repos/{full}/compare/{name}sha...{branch}"] = {"ahead_by": ahead}
F = "100644"
repo("good", {"AGENTS.md": (good, F)})
repo("shadow", {"AGENTS.md": (good, F), "CLAUDE.md": ("# Claude only\n", F)})
repo("imports", {"AGENTS.md": (good, F), "CLAUDE.md": ("@AGENTS.md\n\nPlan mode for src/.\n", F)})
repo("symlink", {"AGENTS.md": (good, F), "CLAUDE.md": ("AGENTS.md", "120000")})
repo("none", {"README.md": ("# none\n", F)})
repo("claudeonly", {"CLAUDE.md": ("# Claude\n", F)})
repo("big", {"AGENTS.md": (big, F)}, ahead=20)
repo("wide", {"AGENTS.md": (good + "\n" + "long line " * 1700 + "\n", F)})
repo("local", {"AGENTS.md": (good, F), "CLAUDE.local.md": ("mine\n", F)})
repo("empty", {}, branch=None)
repo("old", {"AGENTS.md": (good, F)}, archived=True)
# Monorepos: workspaces declared in package.json. "flat" has no nested docs and a root over
# its 150-line target; "mono" covers one of its two packages and has an ARCHITECTURE.md.
ws = '{"name": "m", "private": true, "workspaces": ["packages/*"]}'
pkg = lambda n: ('{"name": "%s"}' % n, F)
repo("flat", {"AGENTS.md": (good + "".join(f"\nnote {i}" for i in range(140)), F), "package.json": (ws, F),
              "packages/a/package.json": pkg("a"), "packages/b/package.json": pkg("b")})
repo("mono", {"AGENTS.md": (good, F), "package.json": (ws, F), "ARCHITECTURE.md": ("# Architecture\n", F),
              "packages/a/package.json": pkg("a"), "packages/a/AGENTS.md": ("# A\n\nApplies to `packages/a/`.\n", F),
              "packages/b/package.json": pkg("b")})
api["repos/acme/good"] = {"default_branch": "main"}
json.dump({"repos": {"acme": repos}, "api": api}, open(sys.argv[1], "w"))
EOF
EMPTY="$TMP/survey-cwd"; mkdir -p "$EMPTY"
export AGENTS_MD_GH FAKE_GH_FIXTURE FAKE_GH_LOG
AGENTS_MD_GH="$(winpath "$HERE/fake-gh.py")"; FAKE_GH_FIXTURE="$(winpath "$FX")"; FAKE_GH_LOG="$(winpath "$LOG")"
OUT="$(cd "$EMPTY" && "$PY" "$AM" survey --org acme --json 2>/dev/null)"; rc=$?
check "survey envelope and repo count (archived excluded)" \
      "d['meta']['schema']=='claude-mods.repo-doctor.agents-md-survey/v1' and d['meta']['repos']==12"
check "per-repo status" \
      "{r['repo'].split('/')[1]:r['status'] for r in D}=={'good':'ok','shadow':'shadowed','imports':'ok','symlink':'ok','none':'missing','claudeonly':'claude-only','big':'over-200,stale','wide':'over-size','local':'shadowed,claude-local-committed','empty':'empty','flat':'flat-monorepo','mono':'ok'}"
check "line count, staleness and coverage reported" \
      "[(r['lines'],r['commits_since'],r['coverage']) for r in D if r['repo']=='acme/good']==[(24,2,'OCL-SV')]"
check "the survey reports size and flags a short file that is too wide" \
      "[(r['lines'] < 200, r['chars'] > 16000) for r in D if r['repo']=='acme/wide']==[(True,True)]"
check "roll-up counts" \
      "(d['meta']['agents_md_only'],d['meta']['claude_md_only'],d['meta']['both'],d['meta']['neither'],d['meta']['shadowed'],d['meta']['over_size'])==(5,1,4,1,2,1)"
check "survey_flags_flat_monorepo" \
      "{r['repo'].split('/')[1]:(r['nested_coverage'],r['architecture_md']) for r in D if r['repo'] in ('acme/flat','acme/mono')}=={'flat':('0/2',None),'mono':('1/2','ARCHITECTURE.md')} and d['meta']['flat_monorepo']==1"
# The roll-up is the share at the bar (no issue at all) and the five weakest active repos,
# never an average: an average hides the worst repos.
check "survey_reports_share_at_bar" \
      "(d['meta']['at_bar'],d['meta']['active'])==(4,11) and d['meta']['weakest']==['acme/local','acme/claudeonly','acme/none','acme/shadow','acme/big']"
[ "$rc" -eq 10 ] && ok "survey with issues exits 10" || no "survey exit" "$rc"
"$PY" - "$LOG" <<'EOF' && ok "survey calls are GET-only (repo list + api, no write flags)" || no "GET-only" "a write-capable call was made"
import json, sys
bad = [a for a in map(json.loads, open(sys.argv[1])) if a[:2] != ["repo", "list"] and
       (a[:1] != ["api"] or any(x in ("-X", "--method", "-f", "-F", "--field", "--raw-field", "--input") for x in a))]
sys.exit(1 if bad else 0)
EOF
[ -z "$(ls -A "$EMPTY")" ] && ok "survey writes nothing (cwd still empty)" || no "no writes" "$(ls -A "$EMPTY")"
TABLE="$(cd "$EMPTY" && "$PY" "$AM" survey --org acme 2>/dev/null)"
printf '%s' "$TABLE" | head -1 | grep -q '^REPO .*AGENTS.*CLAUDE.*SHADOW.*LINES.*SINCE.*COVER.*STATUS' \
    && [ "$(printf '%s\n' "$TABLE" | wc -l)" -eq 13 ] && ok "table: header plus one row per repo" || no "table" "$TABLE"
OUT="$("$PY" "$AM" survey --remote acme/good --json 2>/dev/null)"; rc=$?
check "--remote surveys one repo" "len(D)==1 and D[0]['status']=='ok'"
[ "$rc" -eq 0 ] && ok "a clean single-repo survey exits 0" || no "remote exit" "$rc"
"$PY" -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d['fail_repo_list']=True;json.dump(d,open(p,'w'))" "$FX"
"$PY" "$AM" survey --org acme >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && ok "gh failure exits 7 (unavailable, not a finding)" || no "unavailable exit" "$rc"
unset AGENTS_MD_GH FAKE_GH_FIXTURE FAKE_GH_LOG

# ============================== CONTRACT ======================================
"$PY" "$AM" --help 2>/dev/null | grep -q EXAMPLES && ok "--help lists EXAMPLES" || no "--help" "no EXAMPLES"
"$PY" "$AM" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no subcommand exits 2" || no "usage" "no subcommand"
"$PY" "$AM" survey --org acme --remote acme/x >/dev/null 2>&1; [ $? -eq 2 ] && ok "--org with --remote exits 2" || no "usage" "mutex"
"$PY" "$AM" survey --org 'bad owner' >/dev/null 2>&1; [ $? -eq 2 ] && ok "an invalid owner exits 2" || no "usage" "owner"
"$PY" "$AM" audit --diff --json >/dev/null 2>&1; [ $? -eq 2 ] && ok "--diff with --json exits 2" || no "usage" "diff+json"
"$PY" "$AM" scaffold --repo "$TMP/nope" >/dev/null 2>&1; [ $? -eq 3 ] && ok "a missing repo exits 3" || no "not found" "scaffold"
mkdir -p "$TMP/port/scripts" "$TMP/port/assets"
cp "$SCRIPTS/agents-md.py" "$SCRIPTS/repo-scan.py" "$TMP/port/scripts/"; cp -r "$SCRIPTS/../assets/agents-md" "$TMP/port/assets/"
"$PY" "$TMP/port/scripts/agents-md.py" scaffold --repo "$TMP/arch-node" >/dev/null 2>&1 \
    && "$PY" "$TMP/port/scripts/agents-md.py" audit --repo "$G" --no-parents >/dev/null 2>&1 \
    && ok "runs from a copied scripts/ + assets/agents-md/ alone" || no "standalone" "the copied tool failed"

echo
echo "agents-md tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
