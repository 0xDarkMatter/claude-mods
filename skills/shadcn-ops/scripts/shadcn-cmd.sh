#!/usr/bin/env bash
# Print the pinned shadcn CLI prefix to use in a project; never resolves to @latest.
#
# Usage:   shadcn-cmd.sh [--cwd DIR] [--prefix | --json] [--pm npm|pnpm|yarn|bun]
#                        [--no-dlx] [--facts FILE]
# Input:   argv only. Reads DIR's package.json chain, lockfile, node_modules (or, under
#          Yarn PnP, .pnp.cjs and yarn.lock), the pin in assets/shadcn-facts.json
#          (cli.version), and PATH.
# Output:  stdout = one JSON object {prefix, source, version, pm, pin, installed,
#          workspace, schema} (default); --prefix prints the bare prefix for
#          SHADCN="$(...)"; --json prints the protocol envelope {data:[{...}],
#          meta:{count, schema}}. `workspace` is null, or - when DIR does not declare
#          shadcn but another workspace of its monorepo does - that workspace's folder
#          relative to the monorepo root (run the CLI from there).
#          On error with --json, the error envelope {error:{code,message}} instead.
# Stderr:  notes (version differs from the pin, install first, a sibling workspace), errors.
# Exit:    0 resolved, 2 usage, 3 DIR or facts file missing, 4 facts unparseable or
#          the pin is not an exact x.y.z, 5 no pinned CLI available (no node, no
#          project dependency, no matching global, and no package manager for dlx or
#          --no-dlx), 10 the project declares shadcn but it is not installed: run the
#          project's frozen install, then use the printed prefix.
#
# Resolution order (the first that applies wins):
#   a) project   shadcn in dependencies/devDependencies of DIR's package.json or an
#                ancestor up to the install root: <pm>'s local-only runner
#                (npx --no shadcn | pnpm exec shadcn | yarn run shadcn | bunx --no-install shadcn).
#                Installed means node_modules/shadcn, or under Yarn PnP (.pnp.cjs, no
#                node_modules) a shadcn@npm:x.y.z resolution in yarn.lock.
#   b) global    a `shadcn` on PATH whose major matches the pin: `shadcn`
#   c) dlx       <pm>'s one-off runner at the exact pin
#                (npx shadcn@X | pnpm dlx shadcn@X | yarn dlx shadcn@X | bunx shadcn@X)
# The install root is the nearest folder with a lockfile that really locks DIR: DIR
# itself, its package folder, or a workspace root whose patterns (pnpm-workspace.yaml
# packages, package.json workspaces) list that package. The walk never crosses the git
# root (a .git folder or file): a stray lockfile above once picked the package manager.
# The package manager comes from --pm, else package.json "packageManager", else the
# install root's lockfile, else npm; shadcn-audit.py uses the same precedence. Yarn 1
# has no dlx, so it falls back to npx for (c).
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

# GUARD: node.exe on Windows cannot read Git Bash's POSIX paths (/x/repo). MSYS converts
# them on the way to a native program, unless MSYS_NO_PATHCONV=1 is set (users set it to
# stop other rewrites), and then node got /x/... verbatim: exit 4 or a wrong dlx. So the
# paths node sees are converted here: cygpath -m on Git Bash/Cygwin, else `pwd -W` (MSYS
# without cygpath); on Linux and macOS neither exists and the path passes unchanged.
native_paths=()  # [0] = DIR, [1] = the facts file; node takes them as facts, DIR
if command -v cygpath >/dev/null 2>&1; then
  conv="$(cygpath -m -- "$start" "$facts" 2>/dev/null)" || conv=""
  while IFS= read -r line; do [ -n "$line" ] && native_paths+=("$line"); done <<< "$conv"
fi
if [ "${#native_paths[@]}" != 2 ]; then
  native_paths=("$start" "$facts")
  w="$(cd "$start" 2>/dev/null && pwd -W 2>/dev/null)" && [ -n "$w" ] && native_paths[0]="$w"
  fdir="$(dirname "$facts")"
  w="$(cd "$fdir" 2>/dev/null && pwd -W 2>/dev/null)" && [ -n "$w" ] && native_paths[1]="$w/$(basename "$facts")"
fi

# --- one node call finds the install root and reads every JSON value we need (paths go
#     in as argv, never as code). Rows (TAB-separated):
#     pin x | pin-bad why | lockfile name | declared spec | pmfield name@ver |
#     installed ver | berry 1 | workspace rel spec
read_js='
const fs = require("fs"), path = require("path");
const facts = process.argv[1], start = path.resolve(process.argv[2]);
const LOCKS = ["pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", "package-lock.json", "npm-shrinkwrap.json"];
const out = [];
// A UTF-8 BOM (Windows editors write one) makes JSON.parse throw; strip it before every parse.
const parse = p => JSON.parse(fs.readFileSync(p, "utf8").replace(/^\uFEFF/, ""));
const readJson = p => { try { return parse(p); } catch (e) { return null; } };
const isFile = p => { try { return fs.statSync(p).isFile(); } catch (e) { return false; } };
function* up(d, stop) { for (;;) { yield d; if (stop && d === stop) return; const p = path.dirname(d); if (p === d) return; d = p; } }
try {
  const f = parse(facts);
  const v = f && f.cli && f.cli.version;
  if (typeof v === "string" && /^\d+\.\d+\.\d+$/.test(v)) out.push(["pin", v]);
  else out.push(["pin-bad", "cli.version must be an exact x.y.z, got " + JSON.stringify(v)]);
} catch (e) { out.push(["pin-bad", "cannot parse " + facts + ": " + e.message]); }

// Workspace globs: pnpm-workspace.yaml `packages` (block or flow list) and package.json
// "workspaces" (a list, or Yarn 1 {packages}). Same rules as shadcn-audit.py.
const unq = s => { s = s.trim(); return /^(["\x27]).*\1$/.test(s) ? s.slice(1, -1) : s; };
const noComment = s => s.replace(/\s+#.*$/, "");
function yamlPackages(text) {
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = /^packages\s*:(.*)$/.exec(lines[i]); if (!m) continue;
    const rest = noComment(m[1]).trim();
    if (rest.startsWith("[")) {
      let buf = rest, j = i;
      while (!buf.includes("]") && j + 1 < lines.length) buf += " " + noComment(lines[++j]);
      return buf.slice(1, buf.includes("]") ? buf.indexOf("]") : undefined).split(",").map(unq).filter(Boolean);
    }
    const res = [];
    for (const l of lines.slice(i + 1)) {
      if (!l.trim() || /^\s*#/.test(l)) continue;
      const mm = /^\s*-\s*(.+)$/.exec(l);
      if (mm) res.push(unq(noComment(mm[1])));
      else if (!/^\s/.test(l)) break;
    }
    return res.filter(Boolean);
  }
  return [];
}
function globs(root) {
  let ps = [];
  try { ps = yamlPackages(fs.readFileSync(path.join(root, "pnpm-workspace.yaml"), "utf8")); } catch (e) {}
  const j = readJson(path.join(root, "package.json"));
  let w = j && j.workspaces; if (w && !Array.isArray(w)) w = w.packages;
  if (Array.isArray(w)) ps = ps.concat(w.filter(x => typeof x === "string"));
  const norm = p => p.trim().replace(/^(\.\/)+/, "").replace(/\/+$/, "");
  return { inc: ps.filter(p => !p.startsWith("!")).map(norm), exc: ps.filter(p => p.startsWith("!")).map(p => norm(p.slice(1))) };
}
function globRe(g) {
  let r = "";
  for (let i = 0; i < g.length;) {
    if (g.startsWith("**/", i)) { r += "(?:.*/)?"; i += 3; }
    else if (g.startsWith("**", i)) { r += ".*"; i += 2; }
    else if (g[i] === "*") { r += "[^/]*"; i++; }
    else if (g[i] === "?") { r += "[^/]"; i++; }
    else { r += g[i].replace(/[.+^$(){}|[\]\\]/g, "\\$&"); i++; }
  }
  return new RegExp("^" + r + "$");
}
const relOf = (root, d) => path.relative(root, d).split(path.sep).join("/");
const listed = (g, rel) => g.inc.some(p => globRe(p).test(rel)) && !g.exc.some(p => globRe(p).test(rel));
function lists(root, member) {
  const rel = relOf(root, member);
  return !!rel && !rel.startsWith("..") && listed(globs(root), rel);
}

let gitRoot = null;
for (const d of up(start)) if (fs.existsSync(path.join(d, ".git"))) { gitRoot = d; break; }
let pkgRoot = null;
for (const d of up(start, gitRoot)) if (isFile(path.join(d, "package.json"))) { pkgRoot = d; break; }
let lockdir = "", lockfile = "";
outer: for (const d of up(start, gitRoot)) {
  for (const lf of LOCKS) {
    if (!isFile(path.join(d, lf))) continue;
    if (d === start || d === pkgRoot || (pkgRoot && lists(d, pkgRoot))) { lockdir = d; lockfile = lf; break outer; }
    break;
  }
}
if (lockfile) out.push(["lockfile", lockfile]);
const top = lockdir || pkgRoot || start;

// package.json chain to the install root (no lockfile: the package folder only), nearest first
const chain = lockdir ? [...up(start, lockdir)].filter(d => isFile(path.join(d, "package.json"))) : (pkgRoot ? [pkgRoot] : []);
let declared = "";
for (const d of chain) {
  const j = readJson(path.join(d, "package.json")); if (!j) continue;
  const spec = (j.devDependencies && j.devDependencies.shadcn) || (j.dependencies && j.dependencies.shadcn);
  if (spec && !declared) { declared = String(spec); out.push(["declared", declared]); }
  if (typeof j.packageManager === "string" && !out.some(r => r[0] === "pmfield")) out.push(["pmfield", j.packageManager]);
}
let installed = "";
for (const d of up(start, top)) {
  const j = readJson(path.join(d, "node_modules", "shadcn", "package.json"));
  if (j && j.version) { installed = String(j.version); break; }
}
// Yarn PnP: no node_modules; yarn.lock resolution of the declared range is what runs.
if (!installed && declared && lockfile === "yarn.lock" && (isFile(path.join(top, ".pnp.cjs")) || isFile(path.join(top, ".pnp.js")))) {
  let text = ""; try { text = fs.readFileSync(path.join(lockdir, "yarn.lock"), "utf8"); } catch (e) {}
  let first = "";
  for (const block of text.split(/\r?\n(?=\S)/)) {
    const m = /resolution: "?shadcn@npm:(\d+\.\d+\.\d+)/.exec(block); if (!m) continue;
    const keys = block.split(/\r?\n/, 1)[0].replace(/:\s*$/, "").split(",").map(unq);
    if (keys.includes("shadcn@npm:" + declared) || keys.includes("shadcn@" + declared)) { installed = m[1]; break; }
    first = first || m[1];
  }
  installed = installed || first;
}
if (installed) out.push(["installed", installed]);
if (isFile(path.join(top, ".yarnrc.yml"))) out.push(["berry", "1"]);

// Not declared here: does another workspace of this monorepo declare it? (packages/ui
// rarely holds the CLI; apps/web often does.) Walks the globs, skipping node_modules and
// dot folders, at most 6 levels deep. Preferred, as in shadcn-audit.py: a workspace whose
// components.json aliases point into this package, then any with a components.json.
if (!declared && lockdir) {
  const me = pkgRoot && readJson(path.join(pkgRoot, "package.json"));
  const myName = me && typeof me.name === "string" ? me.name : null;
  const g = globs(lockdir), segs = g.inc.map(p => p.split("/"));
  const could = (s, parts) => {
    for (let i = 0; i < parts.length; i++) {
      if (i >= s.length) return false;
      if (s[i] === "**") return true;
      if (!globRe(s[i]).test(parts[i])) return false;
    }
    return s.length > parts.length;
  };
  const own = new Set(chain);
  let hit = null;
  const walk = (d, parts) => {
    let ents = []; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    ents.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const e of ents) {
      if (!e.isDirectory() || e.name === "node_modules" || e.name.startsWith(".")) continue;
      const ps = parts.concat(e.name), full = path.join(d, e.name);
      if (listed(g, ps.join("/")) && !own.has(full)) {
        const j = readJson(path.join(full, "package.json"));
        const spec = j && ((j.devDependencies && j.devDependencies.shadcn) || (j.dependencies && j.dependencies.shadcn));
        if (spec) {
          const cj = readJson(path.join(full, "components.json"));
          const vals = cj && cj.aliases && typeof cj.aliases === "object" ? Object.values(cj.aliases).map(String) : [];
          const routes = !!myName && vals.some(v => v === myName || v.startsWith(myName + "/"));
          const rank = routes ? 0 : cj ? 1 : 2;
          if (!hit || rank < hit[0]) hit = [rank, ps.join("/"), String(spec), routes ? "" : path.relative(full, start).split(path.sep).join("/")];
        }
      }
      if (ps.length < 6 && segs.some(s => could(s, ps))) walk(full, ps);
    }
  };
  if (g.inc.length) walk(lockdir, []);
  if (hit) out.push(["workspace", hit[1], hit[2], hit[3]]);
}
process.stdout.write(out.map(r => r.join("\t")).join("\n") + "\n");
'
rows="$(node -e "$read_js" "${native_paths[1]}" "${native_paths[0]}")" \
  || fail PRECONDITION "node failed while reading package.json files"
pin=""; pin_bad=""; lockfile=""; declared=""; pmfield=""; installed=""; berry=0; ws_dir=""; ws_spec=""; ws_back=""
while IFS=$'\t' read -r k v v2 v3; do
  case "$k" in
    pin) pin="$v" ;; pin-bad) pin_bad="$v" ;; lockfile) lockfile="$v" ;; declared) declared="$v" ;;
    pmfield) pmfield="$v" ;; installed) installed="$v" ;; berry) berry=1 ;;
    workspace) ws_dir="$v"; ws_spec="$v2"; ws_back="$v3" ;;
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
  [ "$berry" = 1 ] && yarn_berry=1
fi

ws_json="null"
if [ -n "$ws_dir" ]; then
  ws_json="\"$(json_escape "$ws_dir")\""
  printf 'shadcn-cmd: note: %s declares shadcn (%s) in this monorepo; run the CLI from there%s\n' \
    "$ws_dir" "$ws_spec" "${ws_back:+ with --cwd $ws_back}" >&2
fi
emit() {  # prefix source version installed(true|false)
  local p="$1" s="$2" v="$3" i="$4" obj
  obj="$(printf '{"prefix":"%s","source":"%s","version":"%s","pm":"%s","pin":"%s","installed":%s,"workspace":%s,"schema":"%s"}' \
    "$(json_escape "$p")" "$s" "$(json_escape "$v")" "$pm" "$pin" "$i" "$ws_json" "$SCHEMA")"
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
  printf 'shadcn-cmd: the project declares shadcn (%s) but it is not installed; run the frozen install (npm ci, pnpm install --frozen-lockfile, yarn install --immutable, bun ci) first\n' "$declared" >&2
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
case "$pm" in
  pnpm) install_cmd="pnpm add -D -E" ;; yarn) install_cmd="yarn add -D -E" ;;
  bun) install_cmd="bun add -d --exact" ;; *) install_cmd="npm install -D -E" ;;
esac
[ "$no_dlx" = 1 ] && fail PRECONDITION "no project dependency and no matching global shadcn, and --no-dlx forbids a one-off download; add it: $install_cmd shadcn@$pin"
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
