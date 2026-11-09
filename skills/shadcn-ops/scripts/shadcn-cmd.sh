#!/usr/bin/env bash
# Print the pinned shadcn CLI prefix to use in a project; never resolves to @latest.
#
# Usage:   shadcn-cmd.sh [--cwd DIR] [--prefix | --json] [--pm npm|pnpm|yarn|bun]
#                        [--no-dlx] [--facts FILE]
# Input:   argv only. Reads DIR's package.json chain, lockfile and node_modules, the
#          pin in assets/shadcn-facts.json (cli.version), and PATH.
# Output:  stdout = one JSON object {prefix, source, version, pm, pin, installed,
#          schema} (default); --prefix prints the bare prefix for SHADCN="$(...)";
#          --json prints the protocol envelope {data:[{...}], meta:{count, schema}}.
#          On error with --json, the error envelope {error:{code,message}} instead.
# Stderr:  notes (version differs from the pin, install first), errors.
# Exit:    0 resolved, 2 usage, 3 DIR or facts file missing, 4 facts unparseable or
#          the pin is not an exact x.y.z, 5 no pinned CLI available (no node, no
#          project dependency, no matching global, and no package manager for dlx or
#          --no-dlx), 10 the project declares shadcn but node_modules lacks it: run
#          the project's frozen install, then use the printed prefix.
#
# Resolution order (the first that applies wins):
#   a) project   shadcn in dependencies/devDependencies of DIR's package.json or an
#                ancestor up to the lockfile's folder: <pm>'s local-only runner
#                (npx --no shadcn | pnpm exec shadcn | yarn run shadcn | bunx --no-install shadcn)
#   b) global    a `shadcn` on PATH whose major matches the pin: `shadcn`
#   c) dlx       <pm>'s one-off runner at the exact pin
#                (npx shadcn@X | pnpm dlx shadcn@X | yarn dlx shadcn@X | bunx shadcn@X)
# The package manager comes from --pm, else package.json "packageManager", else the
# nearest lockfile, else npm. Yarn 1 has no dlx, so it falls back to npx for (c).
#
# Why a script: the official shadcn skill runs `npx shadcn@latest`, which executes
# whatever was published that hour (shadcn ships several releases a month). The pin
# lives in one asset so a bump is one reviewed edit (references/cli-and-pinning.md).
#
# Examples:
#   shadcn-cmd.sh                                   # {"prefix":"pnpm exec shadcn",...}
#   SHADCN="$(bash shadcn-cmd.sh --prefix)" && $SHADCN info --json
#   shadcn-cmd.sh --cwd apps/web --json | jq -r '.data[0].source'
#   shadcn-cmd.sh --no-dlx || echo "add shadcn as a devDependency first"
set -uo pipefail

EX_USAGE=2; EX_NOTFOUND=3; EX_INVALID=4; EX_PRECOND=5; EX_INSTALL=10
SCHEMA="claude-mods.shadcn-ops.cmd/v1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {  # the header comment block (minus the shebang) is the help text
  local line
  while IFS= read -r line; do
    case "$line" in
      '#!'*) ;;
      '#'*) line="${line#\#}"; printf '%s\n' "${line# }" ;;
      *) break ;;
    esac
  done < "${BASH_SOURCE[0]}"
}

mode="object"; dir="."; pm_flag=""; no_dlx=0; facts="$HERE/../assets/shadcn-facts.json"
json_escape() {  # minimal JSON string escaping for paths and messages (no control chars expected)
  local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"
}
fail() {  # code, message
  if [ "$mode" = "json" ]; then
    printf '{"error":{"code":"%s","message":"%s"}}\n' "$1" "$(json_escape "$2")"
  fi
  printf 'shadcn-cmd: %s\n' "$2" >&2
  case "$1" in
    USAGE) exit "$EX_USAGE" ;; NOT_FOUND) exit "$EX_NOTFOUND" ;;
    VALIDATION) exit "$EX_INVALID" ;; *) exit "$EX_PRECOND" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cwd) [ $# -ge 2 ] || fail USAGE "--cwd needs a directory"; dir="$2"; shift 2 ;;
    --facts) [ $# -ge 2 ] || fail USAGE "--facts needs a file"; facts="$2"; shift 2 ;;
    --pm) [ $# -ge 2 ] || fail USAGE "--pm needs npm, pnpm, yarn or bun"; pm_flag="$2"; shift 2 ;;
    --prefix) mode="prefix"; shift ;;
    --json) mode="json"; shift ;;
    --no-dlx) no_dlx=1; shift ;;
    *) fail USAGE "unknown argument: $1 (try --help)" ;;
  esac
done
case "$pm_flag" in ""|npm|pnpm|yarn|bun) ;; *) fail USAGE "--pm must be npm, pnpm, yarn or bun, got: $pm_flag" ;; esac
[ -d "$dir" ] || fail NOT_FOUND "directory not found: $dir"
[ -f "$facts" ] || fail NOT_FOUND "facts file not found: $facts"
command -v node >/dev/null 2>&1 || fail PRECONDITION "node is not on PATH; the shadcn CLI needs Node.js"
start="$(cd "$dir" && pwd)"

# --- find the lockfile folder (the install root) and the package.json chain to it ---
lockdir=""; lockfile=""; d="$start"
while :; do
  for lf in pnpm-lock.yaml yarn.lock bun.lock bun.lockb package-lock.json npm-shrinkwrap.json; do
    if [ -f "$d/$lf" ]; then lockdir="$d"; lockfile="$lf"; break 2; fi
  done
  parent="${d%/*}"; [ -n "$parent" ] || parent="/"
  [ "$parent" = "$d" ] && break
  d="$parent"
done
chain=(); d="$start"
while :; do
  [ -f "$d/package.json" ] && chain+=("$d/package.json")
  [ -n "$lockdir" ] && [ "$d" = "$lockdir" ] && break
  parent="${d%/*}"; [ -n "$parent" ] || parent="/"
  [ "$parent" = "$d" ] && break
  [ -z "$lockdir" ] && [ "${#chain[@]}" -gt 0 ] && break   # no lockfile: the nearest package.json only
  d="$parent"
done
mods=(); d="$start"
while :; do
  mods+=("$d/node_modules/shadcn/package.json")
  [ -n "$lockdir" ] && [ "$d" = "$lockdir" ] && break
  parent="${d%/*}"; [ -n "$parent" ] || parent="/"
  [ "$parent" = "$d" ] && break
  [ -z "$lockdir" ] && break
  d="$parent"
done

# --- one node call reads every JSON value we need (paths go in as argv, never as code) ---
# Rows: pin<TAB>x | pin-bad<TAB>why | declared<TAB>spec | pmfield<TAB>name@ver | installed<TAB>ver
read_js='
const fs = require("fs");
const [facts, nMods, ...rest] = process.argv.slice(1);
const mods = rest.slice(0, Number(nMods)), pkgs = rest.slice(Number(nMods));
const out = [];
try {
  const f = JSON.parse(fs.readFileSync(facts, "utf8"));
  const v = f && f.cli && f.cli.version;
  if (typeof v === "string" && /^\d+\.\d+\.\d+$/.test(v)) out.push(["pin", v]);
  else out.push(["pin-bad", "cli.version must be an exact x.y.z, got " + JSON.stringify(v)]);
} catch (e) { out.push(["pin-bad", "cannot parse " + facts + ": " + e.message]); }
for (const p of pkgs) {
  let j; try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { continue; }
  const spec = (j.devDependencies && j.devDependencies.shadcn) || (j.dependencies && j.dependencies.shadcn);
  if (spec && !out.some(r => r[0] === "declared")) out.push(["declared", String(spec)]);
  if (typeof j.packageManager === "string" && !out.some(r => r[0] === "pmfield")) out.push(["pmfield", j.packageManager]);
}
for (const m of mods) {
  try { const j = JSON.parse(fs.readFileSync(m, "utf8")); if (j.version) { out.push(["installed", String(j.version)]); break; } } catch (e) {}
}
process.stdout.write(out.map(r => r.join("\t")).join("\n") + "\n");
'
rows="$(node -e "$read_js" "$facts" "${#mods[@]}" "${mods[@]}" "${chain[@]+"${chain[@]}"}")" \
  || fail PRECONDITION "node failed while reading package.json files"
pin=""; pin_bad=""; declared=""; pmfield=""; installed=""
while IFS=$'\t' read -r k v; do
  case "$k" in
    pin) pin="$v" ;; pin-bad) pin_bad="$v" ;; declared) declared="$v" ;;
    pmfield) pmfield="$v" ;; installed) installed="$v" ;;
  esac
done <<< "$rows"
[ -n "$pin_bad" ] && fail VALIDATION "$pin_bad"
pin_major="${pin%%.*}"

# --- package manager and yarn flavour ---
pm="$pm_flag"
if [ -z "$pm" ] && [ -n "$pmfield" ]; then
  case "${pmfield%%@*}" in npm|pnpm|yarn|bun) pm="${pmfield%%@*}" ;; esac
fi
if [ -z "$pm" ]; then
  case "$lockfile" in
    pnpm-lock.yaml) pm=pnpm ;; yarn.lock) pm=yarn ;; bun.lock|bun.lockb) pm=bun ;; *) pm=npm ;;
  esac
fi
yarn_berry=0
if [ "$pm" = yarn ]; then
  case "$pmfield" in yarn@[2-9]*) yarn_berry=1 ;; esac
  [ -n "$lockdir" ] && [ -f "$lockdir/.yarnrc.yml" ] && yarn_berry=1
fi

emit() {  # prefix source version installed(true|false)
  local p="$1" s="$2" v="$3" i="$4" obj
  obj="$(printf '{"prefix":"%s","source":"%s","version":"%s","pm":"%s","pin":"%s","installed":%s,"schema":"%s"}' \
    "$(json_escape "$p")" "$s" "$(json_escape "$v")" "$pm" "$pin" "$i" "$SCHEMA")"
  case "$mode" in
    prefix) printf '%s\n' "$p" ;;
    json) printf '{"data":[%s],"meta":{"count":1,"schema":"%s"}}\n' "$obj" "$SCHEMA" ;;
    *) printf '%s\n' "$obj" ;;
  esac
}

# --- a) the project's own dependency ---
if [ -n "$declared" ]; then
  case "$pm" in
    pnpm) prefix="pnpm exec shadcn" ;; yarn) prefix="yarn run shadcn" ;;
    bun) prefix="bunx --no-install shadcn" ;; *) prefix="npx --no shadcn" ;;
  esac
  if [ -n "$installed" ]; then
    [ "${installed%%.*}" = "$pin_major" ] \
      || printf 'shadcn-cmd: note: the project pins shadcn %s, the skill documents %s; the project wins\n' "$installed" "$pin" >&2
    emit "$prefix" project "$installed" true; exit 0
  fi
  printf 'shadcn-cmd: the project declares shadcn (%s) but node_modules lacks it; run the frozen install (npm ci, pnpm install --frozen-lockfile, yarn install --immutable, bun ci) first\n' "$declared" >&2
  emit "$prefix" project "$declared" false; exit "$EX_INSTALL"
fi

# --- b) a pinned global on PATH (its major must match the pin; a stale global is skipped) ---
if command -v shadcn >/dev/null 2>&1; then
  gv="$(shadcn --version 2>/dev/null)"; gv="${gv%%[[:space:]]*}"
  if [[ "$gv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "${gv%%.*}" = "$pin_major" ]; then
    [ "$gv" = "$pin" ] || printf 'shadcn-cmd: note: global shadcn is %s, the pin is %s\n' "$gv" "$pin" >&2
    emit "shadcn" global "$gv" true; exit 0
  fi
  printf 'shadcn-cmd: note: skipping global shadcn %s (major differs from the pin %s)\n' "${gv:-unknown}" "$pin" >&2
fi

# --- c) the package manager's one-off runner at the exact pin ---
[ "$no_dlx" = 1 ] && fail PRECONDITION "no project dependency and no matching global shadcn, and --no-dlx forbids a one-off download; add it: <pm> add -D -E shadcn@$pin"
case "$pm" in
  pnpm) runner=pnpm; prefix="pnpm dlx shadcn@$pin" ;;
  bun) runner=bunx; prefix="bunx shadcn@$pin" ;;
  yarn) if [ "$yarn_berry" = 1 ]; then runner=yarn; prefix="yarn dlx shadcn@$pin"
        else runner=npx; prefix="npx shadcn@$pin"; fi ;;
  *) runner=npx; prefix="npx shadcn@$pin" ;;
esac
command -v "$runner" >/dev/null 2>&1 \
  || fail PRECONDITION "no pinned shadcn available: no project dependency, no matching global, and '$runner' ($pm) is not on PATH"
emit "$prefix" dlx "$pin" false
exit 0
