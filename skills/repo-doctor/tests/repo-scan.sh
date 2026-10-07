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

# ---- candidate noise, test suites, repo name ----------------------------------
# Each pattern below once raised a landmine question an owner had to delete by hand
# (dogfood on this repo, 2026-10-06), or hid a fact the draft needed.
N="$TMP/noise"; init_repo "$N"
mkdir -p "$N"/{pkg/tests,old,cfg,core,tests/fixtures/app,tests/unit,cmd}
echo "x = 1" > "$N/pkg/lib.py"; echo "def test(): pass" > "$N/pkg/tests/test_lib.py"
echo "a" > "$N/old/gone.py"; echo "b" > "$N/old/gone2.py"
echo "a: 1" > "$N/cfg/a.yml"; echo "b: 1" > "$N/cfg/b.yml"
echo "e = 0" > "$N/core/engine.py"; echo "K=fixture" > "$N/tests/fixtures/app/.env"
printf '#!/bin/bash\nfor t in tests/unit/*.sh; do bash "$t"; done\n' > "$N/tests/run.sh"
echo 'echo ok' > "$N/tests/unit/check_one.sh"; echo '@test "x" { true; }' > "$N/tests/smoke.bats"
printf 'module example.com/n\n' > "$N/go.mod"; echo "package main" > "$N/cmd/main_test.go"
commit "$N" "feat: initial"
for i in 1 2 3 4; do
    echo "# $i" >> "$N/pkg/lib.py"; echo "# $i" >> "$N/pkg/tests/test_lib.py"; commit "$N" "feat: lib $i"
    echo "# $i" >> "$N/old/gone.py"; echo "# $i" >> "$N/old/gone2.py"; commit "$N" "feat: old $i"
    echo "# $i" >> "$N/cfg/a.yml"; echo "# $i" >> "$N/cfg/b.yml"; commit "$N" "feat: cfg $i"
done
for i in 1 2 3 4 5 6; do
    echo "# $i" >> "$N/core/engine.py"
    if [ "$i" -le 3 ]; then commit "$N" "fix: engine bug $i"; else commit "$N" "feat: engine $i"; fi
done
gitq "$N" rm -rq old; gitq "$N" commit -qm "chore: drop old"
OUT="$("$PY" "$SCAN" --repo "$N" --json --no-tokei 2>/dev/null)"
check "a deleted file raises no question" \
      "not any('old/gone' in c['question'] for c in D['candidates'])"
check "a test fixture's secret-like file is skipped but raises no question" \
      "'tests/fixtures/app/.env' in [s['path'] for s in D['secrets_skipped']] and not [c for c in D['candidates'] if c['kind']=='tracked-secret']"
check "code changing with its own test is not a coupling question" \
      "not any('pkg/lib.py' in c['question'] and 'test_lib.py' in c['question'] for c in D['candidates'])"
check "  ...while a real coupled pair still is" \
      "any(c['kind']=='coupling' and 'cfg/a.yml' in c['question'] for c in D['candidates'])"
check "a file that is fragile and a hot spot gets one question" \
      "[c['kind'] for c in D['candidates'] if 'core/engine.py' in c['question']]==['fragile'] and any('most-changed' in c['question'] for c in D['candidates'] if c['kind']=='fragile')"
check "every history candidate names the paths it asks about" \
      "all(c.get('paths') for c in D['candidates'] if c['kind'] in ('coupling','fragile','hotspot','outlier'))"
check "shell, Bats and Go suites are found without a config file" \
      "{'Shell scripts','Bats','go test'} <= {t['framework'] for t in D['tests']}"
check "  ...and the shell runner is named" \
      "[t['config'] for t in D['tests'] if t['framework']=='Shell scripts']==['tests/run.sh']"
gitq "$N" worktree add -q "$TMP/noise-wt" -b wt 2>/dev/null
OUT="$("$PY" "$SCAN" --repo "$TMP/noise-wt" --only repo --json 2>/dev/null)"
check "a worktree is named after its main checkout, not its own folder" "D['repo']['name']=='noise'"
gitq "$N" remote add origin "https://example.com/acme/widget.git"
OUT="$("$PY" "$SCAN" --repo "$N" --only repo --json 2>/dev/null)"
check "the origin remote names the repo when there is one" \
      "D['repo']['name']=='widget' and D['repo']['name_source'].startswith('cmd: git remote')"

# ---- nested entry docs, invariant gates and architecture ----------------------
M="$TMP/monorepo"
make_monorepo "$M"
OUT="$("$PY" "$SCAN" --repo "$M" --json --no-tokei 2>/dev/null)"
check "recommends_nesting_for_package_with_own_contract" \
      "'packages/engine/' in {r['dir'] for r in D['nesting']['recommend']}"
check "never_recommends_nesting_for_size_alone" \
      "'assets/' not in {r['dir'] for r in D['nesting']['recommend']}"
check "one_contract_signal_is_not_enough" \
      "'packages/ui/' not in {r['dir'] for r in D['nesting']['recommend']}"
check "tool_farm_gets_one_protocol_doc" \
      "[f['parent'] for f in D['nesting']['farms']]==['tools/'] and not any(r['dir'].startswith('tools/t') for r in D['nesting']['recommend'])"
check "apps_need_deploy_or_cluster_to_nest" \
      "any(r['dir']=='apps/web/' and {'own-manifest','own-deploy'} <= {s['kind'] for s in r['signals']} for r in D['nesting']['recommend'])"
check "gate_detection_credits_dependency_cruiser" \
      "any(g['tool']=='dependency-cruiser' and g['scope']=='packages/engine/' and g['config']=='.dependency-cruiser.cjs' for g in D['gates'])"
check "go_internal_dir_counts_as_gate" \
      "any(g['tool']=='Go internal' and g['scope']=='packages/engine/' for g in D['gates'])"
check "partial_gate_reports_baseline_size" \
      "any(g['tool']=='dependency-cruiser' and g['partial']=={'kind':'baseline','path':'packages/engine/.dependency-cruiser-baseline.json','entries':3} for g in D['gates'])"
check "architecture_warranted_for_monorepo" \
      "D['architecture']['warranted'] is True and D['architecture']['reasons']"
check "layout_fingerprint_is_stable_and_sorted" \
      "D['architecture']['layout']==sorted(D['architecture']['layout']) and D['architecture']['layout_fingerprint']==__import__('hashlib').sha1(('\\n'.join(D['architecture']['layout'])).encode()).hexdigest()"
check "entry_points_are_named_with_sources" \
      "any(e['name']=='packages/engine/src/index.ts' and e['kind']=='manifest-main' and e['source'].startswith('packages/engine/package.json:') for e in D['architecture']['entry_points']) and all(e['source'] for e in D['architecture']['entry_points'])"
# packages/ holds engine's tests and landmines; its own doc would restate engine's.
check "nesting_skips_a_parent_whose_signals_come_from_a_nested_child" \
      "'packages/engine/' in {r['dir'] for r in D['nesting']['recommend']} and 'packages/' not in {r['dir'] for r in D['nesting']['recommend']}"
check "manifests_by_dir_has_engine_scripts" \
      "{s['name'] for s in D['manifests_by_dir']['packages/engine/']['package_json']['scripts']}=={'test','check:deps'}"
check "generated_entry_doc_detects_ruler" \
      "any(x['path']=='AGENTS.md' and x['generator']=='ruler' and x['source_of_truth']=='.ruler/' for x in D['generated_entry_docs'])"
# --dir reads one more folder's manifests (agents-md.py scaffold --dir); a path that
# leaves the repo is refused rather than read.
OUT="$("$PY" "$SCAN" --repo "$M" --only manifests --dir tools/t01 --json --no-tokei 2>/dev/null)"
check "dir_flag_adds_a_folder_to_manifests_by_dir" \
      "D['manifests_by_dir']['tools/t01/']['package_json']['name']=='@fixture/tool-01'"
"$PY" "$SCAN" --repo "$M" --only manifests --dir ../elsewhere --json >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "dir_outside_the_repo_exits_3" || no "dir_outside_the_repo_exits_3" "exit $rc"
OUT="$("$PY" "$SCAN" --repo "$M" --only nesting,gates,architecture --json --no-tokei 2>/dev/null)"
check "new_sections_are_selectable" \
      "d['meta']['sections']==['nesting','gates','architecture'] and set(D)=={'nesting','gates','architecture','secrets_skipped','candidates'}"
# A check-* script deep in a package is often a tool the package ships, not a gate of
# this repo (dogfood, 2026-10-07: skill tools like check-issues.sh were counted).
# It is a gate only at the repo root's scripts/ or when the check entry point runs it.
GT="$TMP/gates"; init_repo "$GT"; mkdir -p "$GT/scripts" "$GT/pkg/scripts" "$GT/lib/scripts"
echo 'echo ok' > "$GT/scripts/check-root.sh"; echo 'echo tool' > "$GT/pkg/scripts/check-tool.sh"
echo 'echo ok' > "$GT/lib/scripts/check-wired.sh"
printf 'check:\n\tbash lib/scripts/check-wired.sh\n' > "$GT/justfile"
commit "$GT" "feat: gates"
OUT="$("$PY" "$SCAN" --repo "$GT" --only gates --json --no-tokei 2>/dev/null)"
check "shipped_check_script_is_not_a_repo_gate" \
      "sorted(g['scope']+g['config'] for g in D['gates'] if g['tool']=='invariant test')==['lib/scripts/check-wired.sh','scripts/check-root.sh']"

# ---- clean control -----------------------------------------------------------
C="$TMP/clean"; init_repo "$C"; mkdir -p "$C/src"
echo "# Clean" > "$C/README.md"; echo "print(1)" > "$C/src/app.py"; commit "$C" "feat: one"
echo "print(2)" >> "$C/src/app.py"; commit "$C" "feat: two"
OUT="$("$PY" "$SCAN" --repo "$C" --json --no-tokei 2>/dev/null)"
check "clean control: no candidates, no skipped secrets" "D['candidates']==[] and D['secrets_skipped']==[]"
check "architecture_silent_for_small_repo" \
      "D['architecture']['warranted'] is False and D['architecture']['reasons']==[]"

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
