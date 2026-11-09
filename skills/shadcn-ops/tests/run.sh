#!/usr/bin/env bash
# Offline self-test for shadcn-ops: skill shape, the pinned-runner resolver, the project
# audit's fixture matrix, the facts verifier, and copy-alone portability
# (SKILL-RESOURCE-PROTOCOL.md sections 2, 5, 7, 10).
#
# The bugs this suite exists to catch:
#   - the resolver hands back an unpinned runner (`@latest`, an unversioned dlx), skips the
#     project's own locked CLI, or ignores the pin in assets/shadcn-facts.json;
#   - the audit misses a landmine, or flags a correct project (each clean case is the
#     false-positive guard), or prints a registry credential it should only name;
#   - the verifier stops noticing drift, so a stale pin or an unpinned code block looks fine;
#   - a reference grows unlinked, oversized or loses its Contents list.
#
# FIXTURES: tests/fixtures/ holds `.fx` files only (see tests/audit-cases.py for why and how
# a case is laid over its base). Resolver cases are built here at run time.
#
# Usage:   tests/run.sh
#          SHADCN_OPS_DIR=<copy-of-skill> tests/run.sh   # run against a copy, e.g. a
#                                                         # deliberately broken one
# Input:   none (no network, no shadcn, no package manager: fake ones go on PATH)
# Output:  progress on stderr; a final PASS/FAIL line.
# Exit:    0 all pass (or no Python 3.8+: script checks skipped), 1 any failure.
#
# Examples:
#   bash skills/shadcn-ops/tests/run.sh
#   SHADCN_OPS_DIR=/tmp/shadcn-ops-mutant bash skills/shadcn-ops/tests/run.sh
set -uo pipefail

# cd + pwd normalises a Windows-style SHADCN_OPS_DIR (X:\...) to a colon-free POSIX path.
here="$(cd "${SHADCN_OPS_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
suite="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$suite/fixtures"
skill="$here/SKILL.md"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }
finish() {
  echo "shadcn-ops tests: $pass passed, $fail failed" >&2
  [ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
}

tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/shadcn-ops-test.$$")"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# === 1. Layout + frontmatter house rules ===
# CONTRACT (asserts on SKILL.md's own frontmatter): `name: shadcn-ops`, `license: MIT`,
# `metadata.author: claude-mods`, a SINGLE-LINE quoted `description:` and a single-line
# `allowed-tools:` that runs shadcn only in pinned or local forms. A frontmatter edit must
# keep these, or update this block.
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done
[ -f "$skill" ] || { bad "SKILL.md missing"; finish; }
grep -q '^name: shadcn-ops$' "$skill" && ok "name matches directory" || bad "name != shadcn-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
desc_line="$(grep -m1 '^description: ' "$skill" || true)"
desc="${desc_line#description: }"; desc="${desc#\"}"; desc="${desc%\"}"
[ -n "$desc" ] && [ "${#desc}" -le 1000 ] && ok "description ${#desc} chars (<=1000)" || bad "description missing, multi-line or >1000 chars"
tools="$(grep -m1 '^allowed-tools: ' "$skill" || true)"
case "$tools" in
  *@latest*|*"dlx shadcn "*|*"dlx shadcn)"*) bad "allowed-tools pre-approves an unpinned shadcn: $tools" ;;
  *"shadcn@"*) ok "allowed-tools runs shadcn only pinned or local" ;;
  *) bad "allowed-tools has no pinned shadcn form" ;;
esac
# The official skill's form must not come back through a later "sync with upstream" edit.
grep -q 'npx shadcn@latest' "$skill" && bad "SKILL.md tells the agent to run npx shadcn@latest" || ok "SKILL.md never instructs npx shadcn@latest"

# === 2. Size, references, links ===
body="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$skill")"
body_lines="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
body_tokens=$(( $(printf '%s' "$body" | wc -c | tr -d ' ') * 10 / 36 ))
[ "$body_lines" -lt 500 ] && ok "body $body_lines lines (<500)" || bad "body $body_lines lines (>=500)"
[ "$body_tokens" -le 5000 ] && ok "body ~$body_tokens tokens (<=5000)" || bad "body ~$body_tokens tokens (>5000)"
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
for a in assets/shadcn-facts.json assets/mcp.json.example scripts/shadcn-cmd.sh scripts/shadcn-audit.py \
         scripts/check-shadcn-facts.py scripts/run-python.sh; do
  grep -qF "$a" "$skill" && ok "SKILL.md names $a" || bad "SKILL.md never names $a (orphan)"
done
# Every relative markdown link in SKILL.md and the references resolves. One grep per file,
# so no "file:match" prefix has to be split (a drive-letter path holds a colon).
broken=""
for src in "$skill" "$here"/references/*.md; do
  links="$(grep -oE '\]\([A-Za-z0-9_./-]+\.md(#[^)]*)?\)' "$src")" || true   # 1 = no links
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    target="${l#](}"; target="${target%)}"; target="${target%%#*}"
    [ -e "$(dirname "$src")/$target" ] || broken="$broken ${src##*/}->$target"
  done <<< "$links"
done
[ -z "$broken" ] && ok "relative links resolve" || bad "broken links:$broken"

# === 3. Python and script protocol ===
run_py=(bash "$here/scripts/run-python.sh")
if ! "${run_py[@]}" --which >/dev/null 2>&1; then
  note "skip" "no Python 3.8+ - script checks skipped"
  finish
fi
ok "run-python.sh found a Python 3.8+"
resolver="$here/scripts/shadcn-cmd.sh"
audit="$here/scripts/shadcn-audit.py"
verify="$here/scripts/check-shadcn-facts.py"
facts="$here/assets/shadcn-facts.json"
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [ "$got" = "$want" ] && ok "$lbl (exit $got)" || bad "$lbl (want $want got $got)"; }
# The expected prefixes follow the pin in the asset, so bumping the pin needs no edit here.
PIN="$("${run_py[@]}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["cli"]["version"])' "$facts" 2>/dev/null)"
[ -n "$PIN" ] && ok "pin read from the facts asset: $PIN" || bad "could not read cli.version from $facts"
bash -n "$resolver" && ok "bash -n shadcn-cmd.sh" || bad "bash -n shadcn-cmd.sh"
for s in "$audit" "$verify"; do
  "${run_py[@]}" -m py_compile "$s" && ok "py_compile $(basename "$s")" || bad "py_compile $(basename "$s")"
done
for s in "$resolver" "$audit" "$verify"; do
  b="$(basename "$s")"
  grep -qE '^#? ?Examples:$' "$s" && ok "$b: Examples block" || bad "$b: no Examples block"
  grep -qF "scripts/$b" "$skill" && ok "$b cited from SKILL.md" || bad "$b not cited"
done
ec 0 "shadcn-cmd.sh --help" bash "$resolver" --help
# Capture, then match: `--help | grep -q` under pipefail fails when grep exits early (SIGPIPE).
help_out="$(bash "$resolver" --help 2>/dev/null)"
case "$help_out" in *Examples:*) ok "shadcn-cmd.sh --help prints Examples" ;; *) bad "shadcn-cmd.sh --help lacks Examples" ;; esac
ec 2 "shadcn-cmd.sh unknown flag -> 2" bash "$resolver" --bogus
ec 2 "shadcn-cmd.sh --pm yarnpkg -> 2" bash "$resolver" --pm yarnpkg
ec 3 "shadcn-cmd.sh missing dir -> 3" bash "$resolver" --cwd "$tmp/no-such-dir"
for s in "$audit" "$verify"; do
  ec 0 "$(basename "$s") --help" "${run_py[@]}" "$s" --help
  ec 2 "$(basename "$s") unknown flag -> 2" "${run_py[@]}" "$s" --bogus
done

# === 4. Resolver: project -> global -> dlx, each pinned ===
real_node="$(command -v node || true)"
if [ -z "$real_node" ]; then
  note "skip" "no node on PATH - resolver checks skipped"
else
  # PATH holds only: fake tools, a node wrapper and the system dirs. A real shadcn, pnpm
  # or npx on this machine must not leak in, or the global and dlx cases test nothing.
  fb="$tmp/fakebin"; mkdir -p "$fb"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_node" > "$fb/node"; chmod +x "$fb/node"
  stub() { mkdir -p "$1"; printf '#!/bin/sh\necho "%s"\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }   # dir name output
  SYS="/usr/bin:/bin"
  leak="$(PATH="$SYS" command -v shadcn 2>/dev/null || true)"
  [ -z "$leak" ] || note "warn" "a shadcn in $SYS ($leak) may shadow the global/dlx cases"
  R() { local path="$1"; shift; PATH="$path:$fb:$SYS" bash "$resolver" "$@" 2>/dev/null; }   # extra-PATH args...
  field() { printf '%s' "$1" | "${run_py[@]}" -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2" 2>/dev/null; }
  mkproj() { # dir lockfile [shadcn-spec]
    mkdir -p "$1"; : > "$1/$2"
    if [ -n "${3:-}" ]; then printf '{"name":"p","devDependencies":{"shadcn":"%s"}}\n' "$3" > "$1/package.json"
    else printf '{"name":"p"}\n' > "$1/package.json"; fi
  }
  none="$tmp/empty-bin"; mkdir -p "$none"

  # a) the project's own locked CLI wins, even with a global and a pnpm on PATH
  mkproj "$tmp/ra" pnpm-lock.yaml "$PIN"
  mkdir -p "$tmp/ra/node_modules/shadcn"; printf '{"version":"%s"}\n' "$PIN" > "$tmp/ra/node_modules/shadcn/package.json"
  stub "$tmp/bin-all" shadcn "$PIN"; stub "$tmp/bin-all" pnpm x
  out="$(R "$tmp/bin-all" --cwd "$tmp/ra")"; rc=$?
  [ "$rc" = 0 ] && [ "$(field "$out" source)" = project ] && [ "$(field "$out" prefix)" = "pnpm exec shadcn" ] \
    && ok "project devDependency (pnpm) -> 'pnpm exec shadcn' beats global and dlx" || bad "project case: rc=$rc out=$out"
  out="$(R "$none" --cwd "$tmp/ra" --pm npm --prefix)"
  [ "$out" = "npx --no shadcn" ] && ok "project + npm -> 'npx --no shadcn' (local only, never fetches)" || bad "project npm prefix: $out"
  mkdir -p "$tmp/ra/apps/web"; printf '{"name":"web"}\n' > "$tmp/ra/apps/web/package.json"
  out="$(R "$none" --cwd "$tmp/ra/apps/web" --prefix)"
  [ "$out" = "pnpm exec shadcn" ] && ok "a workspace finds the root's declaration up to the lockfile" || bad "workspace walk-up: $out"

  # a') declared but not installed: still the project's runner, exit 10 (install first)
  mkproj "$tmp/rb" pnpm-lock.yaml "$PIN"
  out="$(R "$tmp/bin-all" --cwd "$tmp/rb")"; rc=$?
  [ "$rc" = 10 ] && [ "$(field "$out" installed)" = False ] && [ "$(field "$out" source)" = project ] \
    && ok "declared, not installed -> exit 10, project runner, installed:false" || bad "not-installed case: rc=$rc out=$out"

  # b) no dependency: a global shadcn of the pin's major
  mkproj "$tmp/rc" pnpm-lock.yaml
  stub "$tmp/bin-g" shadcn "$PIN"
  out="$(R "$tmp/bin-g" --cwd "$tmp/rc")"; rc=$?
  [ "$rc" = 0 ] && [ "$(field "$out" source)" = global ] && [ "$(field "$out" prefix)" = shadcn ] \
    && ok "global shadcn 4.x -> prefix 'shadcn'" || bad "global case: rc=$rc out=$out"
  # b') a stale global (another major) is skipped for the pinned dlx
  stub "$tmp/bin-old" shadcn 2.10.0; stub "$tmp/bin-old" pnpm x
  out="$(R "$tmp/bin-old" --cwd "$tmp/rc" --prefix)"
  [ "$out" = "pnpm dlx shadcn@$PIN" ] && ok "stale global 2.x skipped -> pinned dlx" || bad "stale global: $out"

  # c) the package manager's one-off runner at the exact pin
  stub "$tmp/bin-p" pnpm x
  out="$(R "$tmp/bin-p" --cwd "$tmp/rc")"; rc=$?
  [ "$rc" = 0 ] && [ "$(field "$out" source)" = dlx ] && [ "$(field "$out" prefix)" = "pnpm dlx shadcn@$PIN" ] \
    && ok "no dependency, no global -> 'pnpm dlx shadcn@$PIN'" || bad "dlx case: rc=$rc out=$out"
  mkdir -p "$tmp/rn"; printf '{"name":"p"}\n' > "$tmp/rn/package.json"; stub "$tmp/bin-n" npx x
  out="$(R "$tmp/bin-n" --cwd "$tmp/rn" --prefix)"
  [ "$out" = "npx shadcn@$PIN" ] && ok "no lockfile -> npm -> 'npx shadcn@$PIN'" || bad "npm dlx: $out"
  mkproj "$tmp/ry" yarn.lock; : > "$tmp/ry/.yarnrc.yml"; stub "$tmp/bin-y" yarn x
  out="$(R "$tmp/bin-y" --cwd "$tmp/ry" --prefix)"
  [ "$out" = "yarn dlx shadcn@$PIN" ] && ok "Yarn 2+ (.yarnrc.yml) -> 'yarn dlx shadcn@$PIN'" || bad "yarn berry dlx: $out"
  mkproj "$tmp/ry1" yarn.lock
  out="$(R "$tmp/bin-n" --cwd "$tmp/ry1" --prefix)"
  [ "$out" = "npx shadcn@$PIN" ] && ok "Yarn 1 (no dlx) -> 'npx shadcn@$PIN'" || bad "yarn classic dlx: $out"
  mkproj "$tmp/rbun" bun.lock; stub "$tmp/bin-b" bunx x
  out="$(R "$tmp/bin-b" --cwd "$tmp/rbun" --prefix)"
  [ "$out" = "bunx shadcn@$PIN" ] && ok "Bun -> 'bunx shadcn@$PIN'" || bad "bun dlx: $out"

  # The pin comes from the asset, never a constant in the script; a non-exact pin is refused.
  sed "s/\"version\": \"$PIN\"/\"version\": \"9.9.9\"/" "$facts" > "$tmp/facts-999.json"
  out="$(R "$tmp/bin-p" --cwd "$tmp/rc" --facts "$tmp/facts-999.json" --prefix)"
  [ "$out" = "pnpm dlx shadcn@9.9.9" ] && ok "the dlx pin is read from assets/shadcn-facts.json" || bad "pin not from the asset: $out"
  sed "s/\"version\": \"$PIN\"/\"version\": \"latest\"/" "$facts" > "$tmp/facts-latest.json"
  ec 4 "a facts pin of 'latest' is refused -> 4" R "$tmp/bin-p" --cwd "$tmp/rc" --facts "$tmp/facts-latest.json"
  ec 5 "no dependency, no global, no pnpm -> 5" R "$none" --cwd "$tmp/rc"
  ec 5 "--no-dlx with nothing local -> 5" R "$tmp/bin-p" --cwd "$tmp/rc" --no-dlx
  out="$(R "$tmp/bin-p" --cwd "$tmp/rc" --json)"
  printf '%s' "$out" | "${run_py[@]}" -c 'import json,sys
d = json.load(sys.stdin); r = d["data"][0]
assert d["meta"]["schema"] == "claude-mods.shadcn-ops.cmd/v1" and d["meta"]["count"] == 1
assert r["prefix"] == "pnpm dlx shadcn@" + sys.argv[1] and r["pin"] == sys.argv[1]' "$PIN" \
    && ok "--json envelope parses (stdout data only)" || bad "--json envelope broken: $out"
  # The scripts' own words must never put @latest in a prefix, whatever the inputs above did.
  grep -n 'shadcn@latest' "$resolver" | grep -v '^[0-9]*:#' >/dev/null && bad "shadcn-cmd.sh code mentions shadcn@latest" || ok "shadcn-cmd.sh code never builds shadcn@latest"
fi

# === 5. Audit: the fixture matrix, then the edges ===
rows="$("${run_py[@]}" "$suite/audit-cases.py" "$here" "$fixtures" "$tmp")"; rc=$?
[ "$rc" = 0 ] || bad "audit-cases.py exited $rc (harness crashed part-way)"
n_rows=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  n_rows=$((n_rows+1))
  case "$r" in PASS\|*) ok "${r#PASS|}" ;; *) bad "${r#FAIL|}" ;; esac
done <<< "$rows"
[ "$n_rows" -ge 30 ] && ok "audit matrix produced $n_rows rows" || bad "audit matrix produced only $n_rows rows"

mono="$tmp/mono-root"; mkdir -p "$mono"
"${run_py[@]}" -c 'import shutil,sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
for f in src.rglob("*.fx"):
    o = dst / f.relative_to(src).with_suffix(""); o.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(f, o)' \
  "$fixtures/monorepo" "$mono"
err="$("${run_py[@]}" "$audit" "$mono" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$err" | grep -q 'apps/web' && printf '%s' "$err" | grep -q 'packages/ui' \
  && ok "monorepo root -> exit 3 naming apps/web and packages/ui" || bad "monorepo root: rc=$rc err=$err"
mkdir -p "$tmp/badjson"; printf '{ "style": ' > "$tmp/badjson/components.json"
ec 4 "components.json not JSON -> 4" "${run_py[@]}" "$audit" "$tmp/badjson"
ec 2 "--ignore an unknown id -> 2" "${run_py[@]}" "$audit" --ignore no-such-check "$mono/apps/web"
ec 0 "--ignore third-party-registry clears that case" "${run_py[@]}" "$audit" --ignore third-party-registry "$tmp/cases/third-party-registry"
txt="$("${run_py[@]}" "$audit" "$tmp/cases/unpinned-docs" 2>/dev/null)"
printf '%s\n' "$txt" | grep -q $'^medium\tunpinned-cli\tREADME.md:4\t' \
  && ok "text rows carry severity, id and file:line" || bad "text row shape wrong: $txt"
[ "$(printf '%s\n' "$txt" | grep -c 'unpinned-cli')" = 4 ] \
  && ok "unpinned-docs: @latest, unversioned dlx, retired shadcn-ui and a range all reported" || bad "unpinned-docs hits: $txt"

# === 6. Verifier: offline consistency, live drift through recorded sources ===
ec 0 "verifier --offline consistent" "${run_py[@]}" "$verify" --offline --skill "$here" --catalog "$facts"
ec 2 "--offline --live -> 2" "${run_py[@]}" "$verify" --offline --live
ec 2 "--fixtures without --live -> 2" "${run_py[@]}" "$verify" --offline --fixtures "$fixtures/live"
ec 3 "missing catalog -> 3" "${run_py[@]}" "$verify" --offline --catalog "$tmp/no-such.json"
printf 'not json' > "$tmp/bad.json"
ec 4 "malformed catalog -> 4" "${run_py[@]}" "$verify" --offline --catalog "$tmp/bad.json"
sed "s/\"version\": \"$PIN\"/\"version\": \"latest\"/" "$facts" > "$tmp/c0.json"
ec 4 "a tag as the pin -> 4" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c0.json" --skill "$here"
sed 's/"as_of": "[0-9-]*"/"as_of": "2026-10-30"/' "$facts" > "$tmp/c1.json"
ec 10 "pin recorded inside its own cooldown -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c1.json" --skill "$here"
# Moving as_of also trips the currency note, so the exit code alone can't show WHICH check
# fired: assert the pin-cooled row itself (captured first: exit 10 under pipefail).
c1_json="$("${run_py[@]}" "$verify" --offline --catalog "$tmp/c1.json" --skill "$here" --json 2>/dev/null)"
printf '%s' "$c1_json" | "${run_py[@]}" -c 'import json,sys
d = {r["check"]: r["status"] for r in json.load(sys.stdin)["data"]}
assert d["pin-cooled"] == "drift", d' \
  && ok "pin 3 days old at as_of -> the pin-cooled row is drift" || bad "pin-cooled did not report a pin recorded inside its cooldown"
sed 's/"token": "Recharts v3"/"token": "Recharts v3 forever"/' "$facts" > "$tmp/c2.json"
ec 10 "prose token no longer stated -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c2.json" --skill "$here"
# Mutated copies of the skill text: an @latest in allowed-tools, and one in a code block.
mut() { rm -rf "$tmp/m-$1"; mkdir -p "$tmp/m-$1"; cp -R "$here/SKILL.md" "$here/references" "$here/assets" "$tmp/m-$1/"; }
mut tools; sed "s/Bash(pnpm dlx shadcn@$PIN \\*)/Bash(pnpm dlx shadcn@latest *)/" "$here/SKILL.md" > "$tmp/m-tools/SKILL.md"
cmp -s "$here/SKILL.md" "$tmp/m-tools/SKILL.md" && bad "allowed-tools mutation did not apply (pattern drifted)" || ok "allowed-tools mutation applied"
ec 10 "allowed-tools with @latest -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-tools"
mut fence; printf '\n```bash\nnpx shadcn@latest add button\n```\n' >> "$tmp/m-fence/references/forms.md"
ec 10 "@latest in a reference code block -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-fence"

# COUPLED GOLDEN FIXTURES: tests/fixtures/live was recorded from npm and the pinned CLI on
# 2026-11-10 (--today below). The dates and versions in these mutations (4.30.0, 5.0.0,
# 2027-...) are relative to that recording. Bumping the pin means re-recording the fixtures
# and moving --today here and in tests/check-resources.sh (cli-and-pinning.md#bumping-the-pin).
live=("${run_py[@]}" "$verify" --live --catalog "$facts" --today 2026-11-10)
ec 0 "live fixtures in sync -> 0" "${live[@]}" --fixtures "$fixtures/live"
lmut() { # name, file, python code run with argv[1] = the copied file, argv[2] = the pin
  rm -rf "$tmp/live-$1"; cp -R "$fixtures/live" "$tmp/live-$1"
  "${run_py[@]}" -c "$3" "$tmp/live-$1/$2" "$PIN"
}
lmut new npm-shadcn.json 'import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["dist-tags"]["latest"]="4.30.0"; d["time"]["4.30.0"]="2027-01-05T00:00:00.000Z"; d["versions"]["4.30.0"]={"version":"4.30.0","scripts":{}}
open(p,"w").write(json.dumps(d))'
ec 10 "pin 125 days old, 4.30.0 cooled -> 10" "${run_py[@]}" "$verify" --live --catalog "$facts" --today 2027-03-01 --fixtures "$tmp/live-new"
ec 0 "same pin, newer release still inside the cooldown -> 0" "${run_py[@]}" "$verify" --live --catalog "$facts" --today 2027-01-08 --fixtures "$tmp/live-new"
lmut maj npm-shadcn.json 'import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["dist-tags"]["latest"]="5.0.0"; d["time"]["5.0.0"]="2026-11-01T00:00:00.000Z"; d["versions"]["5.0.0"]={"version":"5.0.0","scripts":{}}
open(p,"w").write(json.dumps(d))'
ec 10 "new shadcn major -> 10" "${live[@]}" --fixtures "$tmp/live-maj"
lmut scr npm-shadcn.json 'import json,sys; p=sys.argv[1]; d=json.load(open(p))
d["versions"][sys.argv[2]]["scripts"]["postinstall"]="node evil.js"; open(p,"w").write(json.dumps(d))'
ec 10 "the pin gains a postinstall script -> 10" "${live[@]}" --fixtures "$tmp/live-scr"
lmut tst npm-latest-tanstack__react-table.json 'import json,sys; p=sys.argv[1]; open(p,"w").write(json.dumps({"name":"@tanstack/react-table","version":"10.0.0"}))'
ec 10 "TanStack Table ships v10 -> 10" "${live[@]}" --fixtures "$tmp/live-tst"
lmut cmd help.txt 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("  info [options]", "  doctor [options]  check things\n  info [options]"))'
ec 10 "a new CLI command in --help -> 10" "${live[@]}" --fixtures "$tmp/live-cmd"
lmut mig migrate-list.txt 'import sys; p=sys.argv[1]; open(p,"a").write("- tailwind-v5: migrate to tailwind v5.\n")'
ec 10 "a new migration -> 10" "${live[@]}" --fixtures "$tmp/live-mig"
lmut ver version.txt 'import sys; open(sys.argv[1],"w").write("4.24.0\n")'
ec 7 "the CLI on hand is not the pin -> 7 (advisory)" "${live[@]}" --fixtures "$tmp/live-ver"
rm -rf "$tmp/live-gone"; cp -R "$fixtures/live" "$tmp/live-gone"; rm -f "$tmp/live-gone/npm-shadcn.json"
ec 7 "unreachable source -> 7 (advisory)" "${live[@]}" --fixtures "$tmp/live-gone"
"${live[@]}" --fixtures "$fixtures/live" --json -q 2>/dev/null \
  | "${run_py[@]}" -c 'import json,sys; d=json.load(sys.stdin); assert d["meta"]["schema"]=="claude-mods.shadcn-ops.facts/v1" and d["meta"]["pin"]==sys.argv[1]' "$PIN" \
  && ok "verifier --json envelope parses" || bad "verifier --json envelope broken"

# === 7. Portability: the skill folder runs when copied alone ===
mkdir -p "$tmp/alone"
cp -R "$here/SKILL.md" "$here/scripts" "$here/references" "$here/assets" "$tmp/alone/"
ec 0 "copied-alone verifier --offline" bash "$tmp/alone/scripts/run-python.sh" "$tmp/alone/scripts/check-shadcn-facts.py" --offline
ec 10 "copied-alone audit finds a case" bash "$tmp/alone/scripts/run-python.sh" "$tmp/alone/scripts/shadcn-audit.py" "$tmp/cases/latest-in-scripts"
ec 0 "copied-alone resolver --help" bash "$tmp/alone/scripts/shadcn-cmd.sh" --help

finish
