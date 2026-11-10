#!/usr/bin/env bash
# Offline self-test for shadcn-ops: skill shape, the pinned-runner resolver, the project
# audit's fixture matrix, the facts verifier, and copy-alone portability
# (SKILL-RESOURCE-PROTOCOL.md sections 2, 5, 7, 10).
#
# The bugs this suite exists to catch:
#   - the resolver hands back an unpinned runner (`@latest`, an unversioned dlx), skips the
#     project's own locked CLI, or ignores the pin in assets/shadcn-facts.json;
#   - the audit misses a landmine, or flags a correct project (each clean case is the
#     false-positive guard), or prints a credential (a registry, an MCP command line, a
#     dependency spec) it should only name;
#   - the resolver and the audit disagree on the install root (a stray parent lockfile, the
#     git root) or the package manager (packageManager first, then the lockfile);
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
# `allowed-tools:` that pre-approves shadcn only for read-only verbs on local runners (no
# download, no write). A frontmatter edit must keep these, or update this block.
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
  *@latest*|*"dlx shadcn"*|*"shadcn@"*) bad "allowed-tools pre-approves a shadcn download: $tools" ;;
  *"Bash(shadcn add *)"*|*" shadcn add *)"*|*" shadcn init"*|*" shadcn apply"*|*" shadcn eject"*|*" shadcn migrate"*)
    bad "allowed-tools pre-approves a shadcn write: $tools" ;;
  *"shadcn info *)"*) ok "allowed-tools pre-approves shadcn read-only, with no download" ;;
  *) bad "allowed-tools grants no read-only shadcn command" ;;
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
  printf 'packages:\n  - "apps/*"\n' > "$tmp/ra/pnpm-workspace.yaml"
  out="$(R "$none" --cwd "$tmp/ra/apps/web" --prefix)"
  [ "$out" = "pnpm exec shadcn" ] && ok "a workspace finds the root's declaration up to the lockfile" || bad "workspace walk-up: $out"
  # A lockfile above the project is its install root only inside its git repo AND as a
  # workspace root listing it: a stray one (a home folder, a parent checkout) once chose
  # the package manager for an unrelated project.
  stub "$tmp/bin-pn" pnpm x; stub "$tmp/bin-pn" npx x
  mkdir -p "$tmp/stray/proj"; : > "$tmp/stray/pnpm-lock.yaml"; printf '{"name":"p"}\n' > "$tmp/stray/proj/package.json"
  out="$(R "$tmp/bin-pn" --cwd "$tmp/stray/proj" --prefix)"
  [ "$out" = "npx shadcn@$PIN" ] && ok "a stray lockfile above the project is ignored -> npm" || bad "stray lockfile chose the runner: $out"
  mkdir -p "$tmp/stray-git/proj/.git"; : > "$tmp/stray-git/pnpm-lock.yaml"
  printf '{"name":"outer","workspaces":["proj"]}\n' > "$tmp/stray-git/package.json"; printf '{"name":"p"}\n' > "$tmp/stray-git/proj/package.json"
  out="$(R "$tmp/bin-pn" --cwd "$tmp/stray-git/proj" --prefix)"
  [ "$out" = "npx shadcn@$PIN" ] && ok "the git root stops the lockfile walk" || bad "lockfile walk crossed the git root: $out"
  # Git Bash: MSYS_NO_PATHCONV=1 hands node.exe a POSIX /x/... path unconverted, so the
  # script must pass node Windows-form paths itself (a no-op on Linux and macOS).
  out="$(MSYS_NO_PATHCONV=1 R "$none" --cwd "$tmp/ra" --prefix)"
  [ "$out" = "pnpm exec shadcn" ] && ok "MSYS_NO_PATHCONV=1 -> still the project's runner" || bad "MSYS_NO_PATHCONV=1 project case: $out"
  out="$(MSYS_NO_PATHCONV=1 R "$tmp/bin-all" --cwd "$tmp/ra/apps/web" --prefix)"
  [ "$out" = "pnpm exec shadcn" ] && ok "MSYS_NO_PATHCONV=1 -> the workspace walk still finds the root" || bad "MSYS_NO_PATHCONV=1 workspace case: $out"
  # A workspace without shadcn in a monorepo where apps/web declares it: the JSON names the
  # workspace to run from (the one whose components.json routes components into this one
  # beats one that merely declares shadcn).
  mm="$tmp/rmono"; mkdir -p "$mm/apps/web" "$mm/apps/docs" "$mm/packages/ui"; : > "$mm/pnpm-lock.yaml"
  printf 'packages:\n  - "apps/*"\n  - "packages/*"\n' > "$mm/pnpm-workspace.yaml"; printf '{"name":"root"}\n' > "$mm/package.json"
  printf '{"name":"docs","devDependencies":{"shadcn":"^4.1.0"}}\n' > "$mm/apps/docs/package.json"
  printf '{"name":"web","devDependencies":{"shadcn":"^4.1.0"}}\n' > "$mm/apps/web/package.json"
  printf '{"style":"base-nova","aliases":{"ui":"@ws/ui/components","utils":"@ws/ui/lib/utils"}}\n' > "$mm/apps/web/components.json"
  printf '{"name":"@ws/ui"}\n' > "$mm/packages/ui/package.json"
  stub "$tmp/bin-gh" shadcn "$PIN"
  out="$(R "$tmp/bin-gh" --cwd "$mm/packages/ui")"; rc=$?
  [ "$rc" = 0 ] && [ "$(field "$out" workspace)" = apps/web ] && [ "$(field "$out" source)" = global ] \
    && ok "workspace hint names apps/web (routes into packages/ui), not apps/docs" || bad "workspace hint: rc=$rc out=$out"
  out="$(R "$tmp/bin-gh" --cwd "$tmp/stray/proj")"
  [ "$(field "$out" workspace)" = None ] && ok "no monorepo sibling -> workspace null" || bad "workspace should be null: $out"
  # A UTF-8 BOM (Windows editors write one) once made JSON.parse throw inside a swallowed
  # catch: the declared CLI vanished (dlx, or exit 5 under --no-dlx) and a BOM facts file gave 4.
  mkproj "$tmp/rbom" pnpm-lock.yaml
  printf '\xef\xbb\xbf{"name":"p","devDependencies":{"shadcn":"%s"}}\n' "$PIN" > "$tmp/rbom/package.json"
  mkdir -p "$tmp/rbom/node_modules/shadcn"; printf '\xef\xbb\xbf{"version":"%s"}\n' "$PIN" > "$tmp/rbom/node_modules/shadcn/package.json"
  out="$(R "$none" --cwd "$tmp/rbom" --no-dlx)"; rc=$?
  [ "$rc" = 0 ] && [ "$(field "$out" source)" = project ] && [ "$(field "$out" version)" = "$PIN" ] \
    && ok "a BOM package.json still declares shadcn -> project" || bad "BOM package.json: rc=$rc out=$out"
  # Yarn PnP keeps packages in .pnp.cjs and the cache, never node_modules; the frozen
  # install advice never creates node_modules, so "installed" must come from yarn.lock.
  mkdir -p "$tmp/rpnp"; : > "$tmp/rpnp/.pnp.cjs"; : > "$tmp/rpnp/.yarnrc.yml"
  printf '{"name":"p","packageManager":"yarn@4.5.0","devDependencies":{"shadcn":"%s"}}\n' "$PIN" > "$tmp/rpnp/package.json"
  printf '__metadata:\n  version: 8\n\n"shadcn@npm:%s":\n  version: %s\n  resolution: "shadcn@npm:%s"\n' "$PIN" "$PIN" "$PIN" > "$tmp/rpnp/yarn.lock"
  out="$(R "$none" --cwd "$tmp/rpnp")"; rc=$?
  [ "$rc" = 0 ] && [ "$(field "$out" prefix)" = "yarn run shadcn" ] && [ "$(field "$out" installed)" = True ] \
    && [ "$(field "$out" version)" = "$PIN" ] \
    && ok "Yarn PnP (.pnp.cjs, no node_modules) -> 'yarn run shadcn', version from yarn.lock" || bad "Yarn PnP: rc=$rc out=$out"

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
  { printf '\xef\xbb\xbf'; cat "$facts"; } > "$tmp/facts-bom.json"
  out="$(R "$tmp/bin-p" --cwd "$tmp/rc" --facts "$tmp/facts-bom.json" --prefix)"
  [ "$out" = "pnpm dlx shadcn@$PIN" ] && ok "a facts file with a BOM still parses" || bad "BOM facts file: $out"
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
# The fix names the project's OWN runner: an npm project was once told to use `pnpm exec shadcn`.
# The manager comes from package.json "packageManager" first, then the lockfile, the same
# precedence as shadcn-cmd.sh (the two once disagreed).
cp -r "$tmp/cases/unpinned-docs" "$tmp/unpinned-npm"
rm -f "$tmp/unpinned-npm/pnpm-lock.yaml" "$tmp/unpinned-npm/yarn.lock" "$tmp/unpinned-npm/bun.lock" "$tmp/unpinned-npm/bun.lockb"
grep -v '"packageManager"' "$tmp/cases/unpinned-docs/package.json" > "$tmp/unpinned-npm/package.json"
printf '{"lockfileVersion":3,"packages":{}}\n' > "$tmp/unpinned-npm/package-lock.json"
# Capture first: the audit exits 10 on findings, and under pipefail `audit | grep` would fail anyway.
npm_out="$("${run_py[@]}" "$audit" "$tmp/unpinned-npm" --json 2>/dev/null)"
printf '%s' "$npm_out" | grep -q 'runner (npx --no shadcn' \
  && ok "unpinned-docs fix names npm's local runner (npx --no shadcn), not pnpm" || bad "npm project's unpinned-cli fix does not name npx --no shadcn"
cp -r "$tmp/cases/unpinned-docs" "$tmp/unpinned-pmfield"
sed 's/"packageManager": "pnpm@[^"]*"/"packageManager": "npm@10.9.0"/' "$tmp/cases/unpinned-docs/package.json" > "$tmp/unpinned-pmfield/package.json"
pmf_out="$("${run_py[@]}" "$audit" "$tmp/unpinned-pmfield" --json 2>/dev/null)"
printf '%s' "$pmf_out" | grep -q 'runner (npx --no shadcn' \
  && ok "packageManager npm beats a pnpm-lock.yaml (shadcn-cmd.sh's precedence)" || bad "unpinned-cli fix ignores packageManager: $pmf_out"
# The install advice names the real command for the detected manager, never `<pm> add`.
for pair in "npm@10.9.0|npm install -D -E shadcn@$PIN" "yarn@4.5.0|yarn add -D -E shadcn@$PIN" \
            "bun@1.3.0|bun add -d --exact shadcn@$PIN"; do
  pmv="${pair%%|*}"; want="${pair#*|}"; d="$tmp/no-cli-${pmv%%@*}"
  rm -rf "$d"; cp -r "$tmp/cases/no-cli" "$d"
  sed "s/\"packageManager\": \"pnpm@[^\"]*\"/\"packageManager\": \"$pmv\"/" "$tmp/cases/no-cli/package.json" > "$d/package.json"
  o="$("${run_py[@]}" "$audit" --json "$d" 2>/dev/null)"
  case "$o" in *"$want"*) ok "cli-not-installed fix for ${pmv%%@*}: $want" ;; *) bad "cli-not-installed fix for ${pmv%%@*} lacks '$want': $o" ;; esac
done
# `shadcn-audit.py .` inside a workspace: a relative "." has no parent to walk to, so the
# lockfile at the monorepo root was once never found (and a range read as cli-unlocked).
o="$(cd "$tmp/cases/monorepo-web/apps/web" && "${run_py[@]}" "$audit" --json . 2>/dev/null)"
printf '%s' "$o" | "${run_py[@]}" -c 'import json,sys; assert json.load(sys.stdin)["meta"]["project"]["shadcn_locked"] == sys.argv[1]' "$PIN" 2>/dev/null \
  && ok "audit of '.' inside a workspace walks up to the root lockfile" || bad "audit of '.' did not walk up: $o"
# A components.json that is not shadcn's (another tool's manifest) is not audited as one.
mkdir -p "$tmp/notshadcn"
printf '{"schemaVersion":"other-tool/v1","components":[{"id":"Button","path":"components/Button.json"}]}\n' > "$tmp/notshadcn/components.json"
err="$("${run_py[@]}" "$audit" "$tmp/notshadcn" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 3 ] && case "$err" in *"not a shadcn components.json"*) true ;; *) false ;; esac \
  && ok "another tool's components.json -> exit 3, not a shadcn components.json" || bad "foreign components.json: rc=$rc err=$err"
# A facts file missing a key the audit reads is a VALIDATION error (4), never a traceback (1).
for k in cli.major legacy_styles; do
  "${run_py[@]}" -c 'import json,sys
d = json.load(open(sys.argv[1], encoding="utf-8")); node = d; *path, last = sys.argv[3].split(".")
for p in path: node = node[p]
del node[last]; open(sys.argv[2], "w").write(json.dumps(d))' "$facts" "$tmp/facts-no-$k.json" "$k"
  ec 4 "audit: facts without $k -> 4" "${run_py[@]}" "$audit" --facts "$tmp/facts-no-$k.json" "$tmp/cases/style-default"
done
o="$("${run_py[@]}" "$audit" --json --facts "$tmp/facts-no-cli.major.json" "$tmp/cases/style-default" 2>/dev/null)"
printf '%s' "$o" | "${run_py[@]}" -c 'import json,sys; assert json.load(sys.stdin)["error"]["code"] == "VALIDATION"' 2>/dev/null \
  && ok "audit --json: a bad facts file gives the VALIDATION error envelope" || bad "audit --json bad facts envelope: $o"

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
# A value change that is a prefix of the stated number (60 -> 6, 19 -> 1) once passed as a
# substring of the token: the value must match on digit boundaries.
fmut() { # out-file, python statement on d (the catalog)
  "${run_py[@]}" -c "import json,sys; d=json.load(open(sys.argv[1], encoding='utf-8')); $2; open(sys.argv[2],'w').write(json.dumps(d))" "$facts" "$1"
}
fmut "$tmp/c-age.json" 'd["policy"]["max_pin_age_days"] = int(str(d["policy"]["max_pin_age_days"])[:-1])'
ec 10 "max_pin_age_days loses a digit (60 -> 6) -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c-age.json" --skill "$here"
fmut "$tmp/c-react.json" 'd["ecosystem"]["react"] = d["ecosystem"]["react"][:-1]'
ec 10 "ecosystem react loses a digit (19 -> 1) -> 10" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c-react.json" --skill "$here"
# A catalog missing a key the checks read is a VALIDATION error (4), never a traceback (1).
fmut "$tmp/c-nomajor.json" 'del d["cli"]["major"]'
ec 4 "catalog without cli.major -> 4" "${run_py[@]}" "$verify" --offline --catalog "$tmp/c-nomajor.json" --skill "$here"
o="$("${run_py[@]}" "$verify" --offline --json --catalog "$tmp/c-nomajor.json" --skill "$here" 2>/dev/null)"
printf '%s' "$o" | "${run_py[@]}" -c 'import json,sys; assert json.load(sys.stdin)["error"]["code"] == "VALIDATION"' 2>/dev/null \
  && ok "verifier --json: a bad catalog gives the VALIDATION error envelope" || bad "verifier --json bad catalog envelope: $o"
# Mutated copies of the skill text: an @latest, a pinned download and a write verb in
# allowed-tools, and an @latest in a code block.
mut() { rm -rf "$tmp/m-$1"; mkdir -p "$tmp/m-$1"; cp -R "$here/SKILL.md" "$here/references" "$here/assets" "$tmp/m-$1/"; }
mut tools; sed "s/Bash(pnpm exec shadcn info \\*)/Bash(pnpm dlx shadcn@latest info *)/" "$here/SKILL.md" > "$tmp/m-tools/SKILL.md"
cmp -s "$here/SKILL.md" "$tmp/m-tools/SKILL.md" && bad "allowed-tools mutation did not apply (pattern drifted)" || ok "allowed-tools mutation applied"
ec 10 "allowed-tools with @latest -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-tools"
mut pinned; sed "s/Bash(pnpm exec shadcn info \\*)/Bash(pnpm dlx shadcn@$PIN info *)/" "$here/SKILL.md" > "$tmp/m-pinned/SKILL.md"
cmp -s "$here/SKILL.md" "$tmp/m-pinned/SKILL.md" && bad "pinned-download mutation did not apply (pattern drifted)" || ok "pinned-download mutation applied"
ec 10 "allowed-tools pre-approving a pinned download -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-pinned"
mut write; sed "s/Bash(shadcn add --dry-run \\*)/Bash(shadcn add *)/" "$here/SKILL.md" > "$tmp/m-write/SKILL.md"
cmp -s "$here/SKILL.md" "$tmp/m-write/SKILL.md" && bad "write-grant mutation did not apply (pattern drifted)" || ok "write-grant mutation applied"
ec 10 "allowed-tools pre-approving add -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-write"
mut fence; printf '\n```bash\nnpx shadcn@latest add button\n```\n' >> "$tmp/m-fence/references/forms.md"
ec 10 "@latest in a reference code block -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-fence"
# Forms the checker once missed: the retired shadcn-ui package, a ~~~ fence, and an
# unversioned npx/bunx in allowed-tools (they fetch the newest release when none is local).
mut uiold; printf '\n```bash\nnpx shadcn-ui@latest init\n```\n' >> "$tmp/m-uiold/references/forms.md"
ec 10 "retired shadcn-ui@latest in a code block -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-uiold"
mut tilde; printf '\n~~~bash\nnpx shadcn@latest add button\n~~~\n' >> "$tmp/m-tilde/references/forms.md"
ec 10 "@latest in a ~~~ fence -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-tilde"
for r in npx bunx; do
  mut "$r"; sed -E "s/Bash\\($r --no(-install)? shadcn info \\*\\)/Bash($r shadcn info *)/" "$here/SKILL.md" > "$tmp/m-$r/SKILL.md"
  cmp -s "$here/SKILL.md" "$tmp/m-$r/SKILL.md" && bad "allowed-tools $r mutation did not apply (pattern drifted)" || ok "allowed-tools $r mutation applied"
  ec 10 "unversioned Bash($r shadcn info *) in allowed-tools -> 10" "${run_py[@]}" "$verify" --offline --catalog "$facts" --skill "$tmp/m-$r"
done

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
