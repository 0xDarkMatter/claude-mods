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
init_repo "$TMP/shadowed"; good_agents "$TMP/shadowed"; rm "$TMP/shadowed/AGENTS.md"
echo "# Claude notes" > "$TMP/shadowed/CLAUDE.md"
"$PY" "$AM" scaffold --repo "$TMP/shadowed" 2>"$TMP/err" >/dev/null
grep -q "CLAUDE.md will shadow" "$TMP/err" && ok "scaffold warns that an existing CLAUDE.md will shadow it" \
    || no "scaffold shadow warning" "$(cat "$TMP/err")"

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
commit "$A" "docs: apply agents-md upgrade"
OUT="$("$PY" "$AM" audit --repo "$A" --no-parents --json 2>/dev/null)"
check "re-audit: shadowing, size and deploy findings are gone" \
      "not {'shadowed-standalone','over-ceiling','missing-section-deploy'} & {f['id'] for f in D['findings']}"
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
M="$TMP/missing"; init_repo "$M"; echo x > "$M/f"; commit "$M" "x"
OUT="$("$PY" "$AM" audit --repo "$M" --no-parents --json 2>/dev/null)"; rc=$?
check "no AGENTS.md is crit" "D['findings'][0]['id']=='missing-agents-md'"
[ "$rc" -eq 10 ] && ok "no AGENTS.md exits 10" || no "missing exit" "$rc"

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
repo("local", {"AGENTS.md": (good, F), "CLAUDE.local.md": ("mine\n", F)})
repo("empty", {}, branch=None)
repo("old", {"AGENTS.md": (good, F)}, archived=True)
api["repos/acme/good"] = {"default_branch": "main"}
json.dump({"repos": {"acme": repos}, "api": api}, open(sys.argv[1], "w"))
EOF
EMPTY="$TMP/survey-cwd"; mkdir -p "$EMPTY"
export AGENTS_MD_GH FAKE_GH_FIXTURE FAKE_GH_LOG
AGENTS_MD_GH="$(winpath "$HERE/fake-gh.py")"; FAKE_GH_FIXTURE="$(winpath "$FX")"; FAKE_GH_LOG="$(winpath "$LOG")"
OUT="$(cd "$EMPTY" && "$PY" "$AM" survey --org acme --json 2>/dev/null)"; rc=$?
check "survey envelope and repo count (archived excluded)" \
      "d['meta']['schema']=='claude-mods.repo-doctor.agents-md-survey/v1' and d['meta']['repos']==9"
check "per-repo status" \
      "{r['repo'].split('/')[1]:r['status'] for r in D}=={'good':'ok','shadow':'shadowed','imports':'ok','symlink':'ok','none':'missing','claudeonly':'claude-only','big':'over-200,stale','local':'shadowed,claude-local-committed','empty':'empty'}"
check "line count, staleness and coverage reported" \
      "[(r['lines'],r['commits_since'],r['coverage']) for r in D if r['repo']=='acme/good']==[(24,2,'OCL-SV')]"
check "roll-up counts" \
      "(d['meta']['agents_md_only'],d['meta']['claude_md_only'],d['meta']['both'],d['meta']['neither'],d['meta']['shadowed'])==(2,1,4,1,2)"
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
    && [ "$(printf '%s\n' "$TABLE" | wc -l)" -eq 10 ] && ok "table: header plus one row per repo" || no "table" "$TABLE"
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
