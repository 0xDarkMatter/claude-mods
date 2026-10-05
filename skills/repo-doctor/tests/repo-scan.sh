#!/usr/bin/env bash
# repo-scan behavioural suite: offline, self-contained, run by tests/run.sh.
#
# Builds fixture repos in a temp dir (fixtures.sh make_site: a PHP CMS site with DDEV,
# CodeDeploy, CI and a synthetic git history holding a coupled pair, a hot spot, a fix
# cluster and a config-then-rebuild pattern, plus planted secret sentinels), runs
# scripts/repo-scan.py --json and asserts each fact, its source, and that no secret
# value ever reaches the output. A clean control repo must yield no candidates.
# SCRIPTS_DIR=<dir> runs the suite against another copy of the scripts (to watch a
# test fail on a deliberately broken scanner); KEEP_TMP=1 keeps the fixtures.
# Exit 0 all pass, 1 any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPTS_DIR:-$HERE/../scripts}"
SCAN="$SCRIPTS/repo-scan.py"

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
# check NAME PYTHON-EXPR: the expression sees the parsed envelope as `d`, data as `D`.
check() {
    local got
    got="$(printf '%s' "$OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);D=d['data'];print('ok' if ($2) else 'no')" 2>&1)"
    [ "$got" = "ok" ] && ok "$1" || no "$1" "$got"
}

S="$TMP/site"
make_site "$S"
OUT="$("$PY" "$SCAN" --repo "$S" --json --no-tokei 2>/dev/null)"
TEXT="$("$PY" "$SCAN" --repo "$S" --no-tokei 2>/dev/null)"

# 1-4. contract and secrets
check "envelope carries the repo-scan/v1 schema" "d['meta']['schema']=='claude-mods.repo-doctor.repo-scan/v1'"
leak=0
for s in SENTINEL_ENV_SECRET SENTINEL_AUTH SENTINEL_EXAMPLE_VALUE SENTINEL_DDEV_VALUE SENTINEL_PW SENTINEL_TOKEN SENTINEL_SUBJECT; do
    case "$OUT$TEXT" in *"$s"*) leak=1; no "secret value never in output" "$s leaked" ;; esac
done
[ "$leak" -eq 0 ] && ok "no secret value reaches JSON or text output (7 sentinels)"
check "tracked .env and auth.json are listed as skipped, never read" \
      "sorted(x['path'] for x in D['secrets_skipped'])==['.env','auth.json']"
check ".env.example yields variable NAMES only" \
      "[n['name'] for n in D['env'][0]['names']]==['DB_PASSWORD','APP_ENV']"

# 5-8. manifests, with exact sources
check "package.json script cites its line" \
      "{s['name']:s['source'] for s in D['manifests']['package_json']['scripts']}['build']=='package.json:6'"
check "npm is the package manager, from the lockfile" \
      "D['manifests']['package_json']['package_manager']=={'name':'npm','source':'package-lock.json'}"
check "composer script vs event hook are told apart" \
      "{s['name']:s['kind'] for s in D['manifests']['composer_json']['scripts']}=={'test':'script','post-install-cmd':'event hook'}"
check "Craft CMS detected from composer.json with a line" \
      "any(t['name']=='Craft CMS' and t['source']=='composer.json:4' for t in D['manifests']['composer_json']['tools'])"

# 9-12. DDEV
check "DDEV type with its config line" "D['ddev']['config']['type']=={'value':'craftcms','source':'.ddev/config.yaml:2'}"
check "DDEV database type and version" "D['ddev']['config']['database']['value']=='mysql 8.0'"
check "DDEV post-start hook command" \
      "D['ddev']['hooks']==[{'event':'post-start','kind':'exec','command':'php craft migrate/all','source':'.ddev/config.yaml:13'}]"
check "DDEV custom command with its description" \
      "D['ddev']['commands'][0]['name']=='sync-db' and D['ddev']['commands'][0]['description']=='Pull the shared database'"

# 13-17. deploy and CI
check "appspec hook follows into the script it calls" \
      "any(c['command'].startswith('php craft migrate/all') and c['source']=='scripts/after_install.sh:4' for c in D['deploy']['appspec']['hooks'][0]['commands'])"
check "appspec hook location cites appspec.yml" "D['deploy']['appspec']['hooks'][0]['source']=='appspec.yml:8'"
check "CI push branches parsed from a flow list" "D['ci']['workflows'][0]['triggers']['push_branches']==['main']"
check "compact step lists (- at key indent) parse" \
      "[s['run'] for s in D['ci']['workflows'][0]['jobs'][0]['steps']]==[None,'composer test']"
check "CI deploy step detected with its branches" \
      "D['deploy']['ci_deploy_steps'][0]['job']=='deploy' and D['deploy']['ci_deploy_steps'][0]['push_branches']==['main']"

# 18-20. tests, generated, outliers
check "PHPUnit suite from phpunit.xml.dist" \
      "any(t['framework']=='PHPUnit' and t['suites'][0]['name']=='unit' for t in D['tests'])"
check "tracked web/dist is generated, declared by vite.config.js" \
      "any(g['path']=='web/dist/' and g.get('declared_by')=='vite.config.js:2' for g in D['generated']['tracked'])"
check "900-line file is a size outlier" "[o['path'] for o in D['outliers']]==['src/Big.php']"

# 21-24. history
check "coupled pair found (Jaccard 1.0)" \
      "D['history']['coupling'][0]['files']==['modules/a.php','modules/b.php'] and D['history']['coupling'][0]['jaccard']==1.0"
check "hot spot ranks first" "D['history']['hotspots'][0]['path']=='modules/hot.php'"
check "fix cluster found" "[f['path'] for f in D['history']['fragile']]==['modules/fragile.php']"
check "config edit followed by a rebuild" \
      "D['history']['config_followups'][0]['config']=='vite.config.js' and D['history']['config_followups'][0]['family']=='build output'"

# 25-26. candidates are questions, and every planted pattern raises one
check "landmine candidates cover every planted pattern" \
      "{c['kind'] for c in D['candidates']}>={'tracked-secret','deploy','generated','coupling','config-followup','fragile','ddev-hook','hotspot','outlier'}"
check "every candidate is phrased as a question" "all(c['question'].rstrip().endswith('?') for c in D['candidates'])"

# ---- clean control -----------------------------------------------------------
C="$TMP/clean"; init_repo "$C"; mkdir -p "$C/src"
echo "# Clean" > "$C/README.md"; echo "print(1)" > "$C/src/app.py"; commit "$C" "feat: one"
echo "print(2)" >> "$C/src/app.py"; commit "$C" "feat: two"
OUT="$("$PY" "$SCAN" --repo "$C" --json --no-tokei 2>/dev/null)"
check "clean control: no candidates, no skipped secrets" "D['candidates']==[] and D['secrets_skipped']==[]"

# ---- plain directory, exit codes, standalone copy ----------------------------
P="$TMP/plain"; mkdir -p "$P"; echo '{"name":"p","scripts":{"go":"node x"}}' > "$P/package.json"
OUT="$("$PY" "$SCAN" --repo "$P" --json --no-tokei 2>/dev/null)"
check "plain directory: not git, no history, manifests still read" \
      "D['repo']['is_git'] is False and D['history'] is None and D['manifests']['package_json']['scripts'][0]['name']=='go'"
"$PY" "$SCAN" --help 2>/dev/null | grep -q "EXAMPLES" && ok "--help lists EXAMPLES" || no "--help" "no EXAMPLES"
"$PY" "$SCAN" --only bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown section exits 2" || no "usage exit" "got $rc"
"$PY" "$SCAN" --repo "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "missing repo exits 3" || no "not-found exit" "got $rc"
mkdir -p "$TMP/alone"; cp "$SCAN" "$TMP/alone/"
"$PY" "$TMP/alone/repo-scan.py" --repo "$S" --json --no-tokei 2>/dev/null \
    | "$PY" -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
    && ok "runs standalone (copied alone, no sibling files)" || no "standalone" "failed"

echo
echo "repo-scan tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
