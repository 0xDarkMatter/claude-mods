#!/usr/bin/env bash
# Offline self-test for package-manager-ops: skill shape, the pm-audit fixture matrix,
# the version-range parser, the facts verifier contract, and copy-alone portability
# (SKILL-RESOURCE-PROTOCOL.md §2, §7, §10).
#
# Offline-deterministic: no network, no npm/composer install. Resolves paths relative
# to itself so it runs in the repo and once installed to ~/.claude/skills/.
#
# FIXTURES (tests/fixtures/<case>/): every fixture file ends in `.fx` and the suite
# strips the suffix when it materialises a case into a temp dir. Guard: do NOT rename
# them to bare package.json / composer.lock / .npmrc - Dependabot, Socket and npm
# itself would treat the fixture manifests (node-sass, bower, fake tokens) as real.
# A case = the `clean` control + the case's own files on top, minus each path in
# `_delete`; `_expect` lists the exact finding ids pm-audit must report (empty = the
# case is a clean control and must exit 0). An optional `_lines` pins the exact
# `id file:line` rows for every id it names, for cases whose point is WHICH line fires
# (the per-job deploy scope). It is coupled to the fixture's line numbers: after
# editing a fixture, re-read its `_lines` (rg -n), never re-count by hand.
# A fake secret in a fixture is spelled FIXTURE-LITERAL-VALUE or FIXTURE-URL-SECRET: the
# leak check runs every fixture holding one in both output modes and fails if the string
# appears anywhere. A secret spelled any other way is never looked for.
#
# FRONTMATTER CONTRACT - this suite asserts on SKILL.md's own frontmatter shape:
#   * top-level keys limited to the six Agent Skills spec fields (portable as one unit)
#   * description starts "Use when " and is <= 500 chars
# A trim or spec-alignment pass that edits the frontmatter must keep these, or change
# this suite in the same commit (docs/SKILL-CREATION-PROTOCOL.md, Step 5).
#
# Usage:   bash tests/run.sh
#          SKILL_DIR=/path/to/copy bash tests/run.sh        # prove a guard fails on a broken copy
#          PM_AUDIT=/path/to/stub.py bash tests/run.sh      # run the matrix against another audit
# Input:   none
# Output:  PASS/FAIL rows on stderr; final tally line.
# Exit:    0 all pass, 1 any failure
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${SKILL_DIR:-$(dirname "$HERE")}"
DOC="$SKILL/SKILL.md"
AUDIT="${PM_AUDIT:-$SKILL/scripts/pm-audit.py}"
V="$SKILL/scripts/check-pm-facts.py"
FACTS="$SKILL/assets/package-manager-facts.json"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1" >&2; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; }
finish() { echo "=== $PASS passed, $FAIL failed ===" >&2; [[ "$FAIL" -eq 0 ]] || exit 1; exit 0; }

echo "=== package-manager-ops self-test ($SKILL) ===" >&2
PY="$(bash "$SKILL/scripts/run-python.sh" --which 2>/dev/null)" || { no "no Python 3.8+ (run-python.sh --which)"; finish; }
ok "python launcher picked: $PY"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# -- 1. skill shape: frontmatter, budgets, references, citations, links ---------------
if [[ -f "$DOC" ]]; then
  while IFS='|' read -r verdict msg; do
    [[ "$verdict" == PASS ]] && ok "$msg" || no "$msg"
  done < <("$PY" - "$SKILL" <<'PY'
import re, sys
from pathlib import Path
skill = Path(sys.argv[1])
text = (skill / "SKILL.md").read_text(encoding="utf-8")
def row(ok, msg): print(f"{'PASS' if ok else 'FAIL'}|{msg}")
parts = text.split("---", 2)
fm, body = (parts[1], parts[2]) if len(parts) == 3 else ("", text)
keys = re.findall(r"^([A-Za-z_-]+):", fm, re.M)
spec = {"name", "description", "license", "compatibility", "allowed-tools", "metadata"}
row(set(keys) <= spec, f"frontmatter keys are Agent Skills spec only ({', '.join(keys)})")
row(re.search(r"^name: package-manager-ops\s*$", fm, re.M) is not None, "name: package-manager-ops")
row(re.search(r"^license: MIT\s*$", fm, re.M) is not None, "license: MIT")
m = re.search(r'^description: "(.*)"\s*$', fm, re.M)
desc = m.group(1) if m else ""
row(desc.startswith("Use when ") and len(desc) <= 500, f'description starts "Use when " and is <= 500 chars ({len(desc)})')
# Portability: the target plugin's leak check rejects this host suffix.
row(".ddev" + ".site" not in text, "no DDEV site-suffix placeholder in SKILL.md")
lines = body.splitlines()
est = round(len(body) / 3.6)
row(len(lines) < 500 and est <= 5000, f"SKILL.md body < 500 lines and <= ~5000 est. tokens ({len(lines)} lines, ~{est})")
row(re.search(r"as of 20\d\d", body) is not None, "dated 'as of <year>' currency note")
refs = sorted((skill / "references").glob("*.md"))
row(len(refs) > 0, f"{len(refs)} reference file(s)")
for ref in refs:
    rt = ref.read_text(encoding="utf-8")
    rl = rt.splitlines()
    row(len(rl) <= 300, f"{ref.name} <= 300 lines ({len(rl)})")
    if len(rl) > 100:
        # The repo size rule (tests/reference-contents.sh): the list sits in the first 15
        # lines and links every `## ` heading below it. Checked here, hard, without
        # borrowing another skill's parser, so the folder still runs copied alone.
        row(any(l.strip() == "## Contents" for l in rl[:15]), f"{ref.name} has '## Contents' in its first 15 lines")
        heads, fence, listed, in_toc = [], False, set(), False
        for l in rl:
            if l.lstrip().startswith("```"):
                fence = not fence
            if fence:
                continue
            if l.startswith("## "):
                in_toc = l.strip() == "## Contents"
                if not in_toc:
                    heads.append(re.sub(r"[^\w\- ]", "", l[3:].strip().lower()).replace(" ", "-"))
            elif in_toc:
                listed.update(re.findall(r"\]\(#([^)]+)\)", l))
        gone = [h for h in heads if h not in listed]
        row(not gone, f"{ref.name} Contents links every ## heading" + (f" - missing: {gone}" if gone else ""))
    row(f"references/{ref.name}" in text, f"{ref.name} cited from SKILL.md")
    row(".ddev" + ".site" not in rt, f"{ref.name} has no DDEV site-suffix placeholder")
def slugs(md):
    return {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-") for h in re.findall(r"^#{1,6} (.+)$", md, re.M)}
bad = []
for f in [skill / "SKILL.md", *refs]:
    md = f.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)\s]+)\)", md):
        if re.match(r"[a-z]+:", target):
            continue
        path, _, anchor = target.partition("#")
        dest = (f.parent / path).resolve() if path else f
        if not dest.exists():
            bad.append(f"{f.name} -> {target} (missing file)")
        elif anchor and dest.suffix == ".md" and anchor not in slugs(dest.read_text(encoding="utf-8")):
            bad.append(f"{f.name} -> {target} (missing anchor)")
row(not bad, "all relative links + anchors resolve" + (f": {bad}" if bad else ""))
PY
)
  for res in scripts/pm-audit.py scripts/check-pm-facts.py scripts/run-python.sh assets/package-manager-facts.json; do
    [[ -f "$SKILL/$res" ]] && ok "resource present: $res" || no "missing resource: $res"
    grep -q "$res" "$DOC" && ok "cited from SKILL.md: $res" || no "uncited: $res"
  done
else
  no "SKILL.md missing"
fi

# -- 2. pm-audit CLI contract --------------------------------------------------------
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [[ "$got" == "$want" ]] && ok "$lbl (exit $got)" || no "$lbl (want $want got $got)"; }
ec 0 "pm-audit py_compile"     "$PY" -m py_compile "$AUDIT"
ec 0 "pm-audit --help"         "$PY" "$AUDIT" --help
ec 2 "pm-audit bad flag -> 2"  "$PY" "$AUDIT" --bogus "$HERE"
ec 2 "pm-audit no path -> 2"   "$PY" "$AUDIT"
ec 2 "pm-audit bad --as-of -> 2" "$PY" "$AUDIT" --as-of 05/10/2026 "$HERE"
ec 3 "pm-audit missing path -> 3" "$PY" "$AUDIT" "$TMP/does-not-exist"
ec 3 "pm-audit missing facts -> 3" "$PY" "$AUDIT" --facts "$TMP/nope.json" "$HERE"
"$PY" "$AUDIT" --help 2>/dev/null | grep -q "Examples:" && ok "pm-audit --help lists Examples" || no "pm-audit --help lacks Examples"

# -- 3. fixture matrix: clean controls exit 0, every finding id is produced ----------
while IFS='|' read -r verdict msg; do
  [[ "$verdict" == PASS ]] && ok "$msg" || no "$msg"
done < <("$PY" - "$HERE/fixtures" "$AUDIT" "$TMP" "$SKILL/references/diagnostics.md" <<'PY'
import json, os, shutil, subprocess, sys
from pathlib import Path
fixtures, audit, tmp, diagnostics = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
def row(ok, msg): print(f"{'PASS' if ok else 'FAIL'}|{msg}")

def materialise(src: Path, dest: Path):
    for f in src.rglob("*.fx"):
        out = dest / f.relative_to(src).with_suffix("")
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, out)

cases = sorted(p for p in fixtures.iterdir() if p.is_dir())
row(len(cases) >= 30, f"{len(cases)} fixture case(s)")
covered = set()
for case in cases:
    dest = tmp / "m" / case.name
    materialise(fixtures / "clean", dest)
    if case.name != "clean":
        materialise(case, dest)
    for d in (case / "_delete").read_text().split() if (case / "_delete").is_file() else []:
        (dest / d).unlink()
    want = sorted(set((case / "_expect").read_text().split()))
    proc = subprocess.run([sys.executable, audit, "--json", "--as-of", "2026-10-05", str(dest)],
                          capture_output=True, text=True)
    try:
        data = json.loads(proc.stdout)["data"]
        got = sorted({f["id"] for f in data})
    except Exception as exc:  # noqa: BLE001 - any parse failure is a test failure
        row(False, f"{case.name}: unparseable --json output ({exc}); stderr={proc.stderr.strip()[-200:]}")
        continue
    code_ok = proc.returncode == (10 if want else 0)
    row(got == want and code_ok,
        f"{case.name}: ids {got or '[]'} exit {proc.returncode}" + ("" if got == want and code_ok else f" (want {want or '[]'} exit {10 if want else 0})"))
    covered.update(want)
    if (case / "_lines").is_file():
        want_rows = sorted(l.strip() for l in (case / "_lines").read_text().splitlines() if l.strip())
        pinned = {r.split()[0] for r in want_rows}
        got_rows = sorted(f"{f['id']} {f['file']}:{f['line']}" for f in data if f["id"] in pinned)
        row(got_rows == want_rows, f"{case.name}: lines {got_rows}" + ("" if got_rows == want_rows else f" (want {want_rows})"))

# Every id the audit documents must have a fixture that produces it.
doc_ids = set()
for line in Path(audit).read_text(encoding="utf-8").splitlines():
    s = line.strip()
    if s and all(tok.count(".") >= 1 and tok.replace(".", "").replace("-", "").isalnum() for tok in s.split()) \
            and s.split()[0].split(".")[0] in {"js", "php", "node", "ddev", "npx", "legacy", "registry", "deploy"}:
        doc_ids.update(s.split())
row(doc_ids and doc_ids <= covered, f"every documented finding id has a fixture ({len(doc_ids)} ids)"
    + ("" if doc_ids <= covered else f" - uncovered: {sorted(doc_ids - covered)}"))
# ...and a row in the diagnostics table, which the docstring promises explains each id.
# A new id can otherwise ship with a fixture but nothing telling the reader what to fix.
diag_text = diagnostics.read_text(encoding="utf-8") if diagnostics.is_file() else ""
rowless = sorted(i for i in doc_ids if f"| `{i}` |" not in diag_text)
row(doc_ids and not rowless, f"every documented finding id has a diagnostics.md row ({len(doc_ids)} ids)"
    + (f" - missing: {rowless}" if rowless else ""))

# pm-audit never prints a secret. Every fixture that holds a fake one (a committed token,
# credentials in a registry or tarball URL) runs in both output modes, and the value must
# appear nowhere in stdout or stderr.
SECRETS = ("FIXTURE-LITERAL-VALUE", "FIXTURE-URL-SECRET")
leaky = [c for c in cases if any(s in f.read_text(encoding="utf-8", errors="replace")
                                 for f in c.rglob("*.fx") for s in SECRETS)]
row(len(leaky) >= 3, f"{len(leaky)} fixture case(s) carry a fake secret")
for case in leaky:
    for mode in (["--json"], []):
        proc = subprocess.run([sys.executable, audit, *mode, "--as-of", "2026-10-05", str(tmp / "m" / case.name)],
                              capture_output=True, encoding="utf-8", errors="replace")
        shown = [s for s in SECRETS if s in proc.stdout + proc.stderr]
        row(proc.returncode in (0, 10) and not shown,
            f"{case.name}: no secret printed ({'json' if mode else 'tsv'}, exit {proc.returncode})"
            + (f" - printed {shown}" if shown else ""))
dest = tmp / "m" / "registry-token-committed"
proc = subprocess.run([sys.executable, audit, "--as-of", "2026-10-05", str(dest)], capture_output=True, text=True)
rows = [r for r in proc.stdout.splitlines() if r]
row(rows and all(len(r.split("\t")) == 5 for r in rows), f"plain output: {len(rows)} TSV row(s), 5 columns each")

# --no-docs must still read package.json scripts but skip the docs walk.
dest = tmp / "m" / "npx-unpinned-docs"
proc = subprocess.run([sys.executable, audit, "--json", "--no-docs", "--as-of", "2026-10-05", str(dest)], capture_output=True, text=True)
row(proc.returncode == 0, f"--no-docs skips README npx (exit {proc.returncode})")
dest = tmp / "m" / "npx-unpinned-script"
proc = subprocess.run([sys.executable, audit, "--json", "--no-docs", "--as-of", "2026-10-05", str(dest)], capture_output=True, text=True)
row(proc.returncode == 10, f"--no-docs still checks package.json scripts (exit {proc.returncode})")
# The engine-strict note is npm advice: present for an npm repo without it, absent for pnpm.
def notes_of(case):
    d = tmp / "m" / case
    (d / ".npmrc").unlink(missing_ok=True)
    p = subprocess.run([sys.executable, audit, "--json", "--as-of", "2026-10-05", str(d)], capture_output=True, text=True)
    return {n["id"] for n in json.loads(p.stdout)["meta"]["notes"]} if p.stdout.strip().startswith("{") else set()
row("js.engines.unenforced" in notes_of("clean"), "engines note fires for an npm repo without engine-strict")
row("js.engines.unenforced" not in notes_of("clean-pnpm"), "engines note stays silent for a pnpm repo (.npmrc advice is npm's)")
# A project that pins config.platform.php gets a missing require.php as a note, not a finding.
row("php.require.missing" in notes_of("clean-php-require-platform-pinned"), "missing require.php is a note when config.platform.php is set")
def audit_json(case):
    d = tmp / "m" / case
    p = subprocess.run([sys.executable, audit, "--json", "--as-of", "2026-10-05", str(d)], capture_output=True, text=True)
    return json.loads(p.stdout) if p.stdout.strip().startswith("{") else {"data": [], "meta": {}}
def found(case, fid):
    return [f for f in audit_json(case)["data"] if f["id"] == fid]
# A Yarn freeze flag on npm is an error: npm 12 refuses the command (EUNKNOWNCONFIG).
yf = found("deploy-npm-frozen-flag", "deploy.npm.yarn-flag")
row(yf and all(f["severity"] == "error" and "npm 12 refuses" in f["message"] and "installs unfrozen" in f["message"]
               and "use npm ci" in f["fix"] for f in yf),
    "npm install --frozen-lockfile: an error - npm 12 refuses it, npm up to 11 installs unfrozen, fix npm ci")
ci = [f for f in found("deploy-npm-ci-yarn-flag", "deploy.npm.yarn-flag") if "npm ci" in f["message"]]
row(ci and all("already frozen" in f["fix"] for f in ci), "npm ci --frozen-lockfile: drop the flag, npm ci is already frozen")
# A bare name and an `@latest`/`@next` spec run what that dist-tag names, which need not be
# the newest published version (a release published under another tag never moves latest).
bare = [f["message"] for f in found("npx-unpinned-docs", "npx.unpinned") if f["message"].startswith("`npx create-vite` ")]
tag = [f["message"] for f in found("npx-unpinned-script", "npx.unpinned") if "eslint@latest" in f["message"]]
row(bare and tag and all("dist-tag" in m and "newest" not in m for m in bare + tag),
    f"npx.unpinned names the dist-tag for a bare name and for @latest, never 'newest' ({bare + tag})")
plain = found("deploy-npm-install", "deploy.install.unfrozen")
row(plain and not any("Yarn flag" in f["message"] for f in plain), "plain npm install keeps the generic unfrozen message")
# CI that builds in a subfolder: the finding names that package root, and the root's
# missing lockfile is only a note when nothing in CI installs the root.
sub = found("deploy-ci-subfolder-unfrozen", "deploy.install.unfrozen")
row(sub and all("(in theme/)" in f["message"] for f in sub), "an install under working-directory: names the package root it runs in")
for case in ("deploy-ci-subfolder-unfrozen", "clean-ci-subfolder-cd", "clean-ci-subfolder-env"):
    row("js.lockfile.missing" in notes_of(case), f"{case}: root js.lockfile.missing is a note when CI builds only a nested root with a lockfile")
ul = found("deploy-ci-subfolder-unlocked", "deploy.install.unlocked")
row(ul and "runs in app/client/" in ul[0]["message"], "an install in a nested folder with no lockfile names that folder")
# Two root lockfiles: when CI installs with one manager, say which file is live.
conf = found("js-lockfile-conflict-ci-yarn", "js.lockfile.conflict")
row(conf and "`yarn install --frozen-lockfile`" in conf[0]["message"] and "package-lock.json is unused" in conf[0]["message"]
    and conf[0]["fix"].startswith("delete package-lock.json"), "lockfile conflict names the one CI installs with and the unused one")
nocif = found("js-lockfile-conflict", "js.lockfile.conflict")
row(nocif and "CI installs" not in nocif[0]["message"], "without CI the lockfile conflict names no live lockfile")
stale = found("php-lockfile-stale-dev-only", "php.lockfile.stale")
row(stale and "fixture/tool (locked only in packages-dev)" in stale[0]["message"],
    "a require locked only in packages-dev is named as such (Composer reads require from packages)")
# `composer update --lock` must read the old lock and rethrows its parse error; only a full
# update regenerates an unparseable one (Installer::doUpdate, Composer 2.10.3).
broken = found("php-lockfile-invalid", "php.lockfile.stale")
row(broken and all("--lock" not in f["fix"] and "`composer update`" in f["fix"] for f in broken),
    f"an unparseable composer.lock is fixed from git or a full update, never update --lock ({[f['fix'] for f in broken]})")
# EOL findings say what the repo pins, not what production runs.
for case, fid in (("php-eol", "php.eol"), ("js-node-eol", "js.node.eol"), ("php-eol-ci", "php.eol"), ("js-node-eol-ci", "js.node.eol")):
    fs = found(case, fid)
    row(fs and all("confirm the server's" in f["message"] for f in fs), f"{case}: {fid} asks to confirm the server's version")
pins = audit_json("php-eol-ci")["meta"].get("php_pins", {})
row(pins.get(".github/workflows/test.yml:11 php-version") == "7.1", f"CI setup-php php-version '7.1' is read as a pin ({pins})")
row("js.node.floating" not in notes_of("clean-ci-pins"), "CI lts/* and matrix node-version values are skipped, not noted as floating pins")
# The EOL check is date-driven: Node 22 is fine on 2026-10-05 and dead after 2027-04-30.
dest = tmp / "m" / "node-pin-disagree-nvmrc"
proc = subprocess.run([sys.executable, audit, "--json", "--as-of", "2027-05-01", str(dest)], capture_output=True, text=True)
ids = {f["id"] for f in json.loads(proc.stdout)["data"]} if proc.stdout.strip().startswith("{") else set()
row("js.node.eol" in ids, "--as-of moves the EOL line (Node 22 dead on 2027-05-01)")
# npx of a bin that is not a package name: the advice names the package that provides it.
adv = found("npx-unpinned-bin-advice", "npx.unpinned")
row(adv and "typescript" in adv[0]["fix"] and "add tsc " not in adv[0]["fix"],
    "npx tsc advice names typescript, the package that provides tsc" + (f" (fix: {adv[0]['fix']!r})" if adv else ""))
# DDEV's own end-of-life pin is ddev-ops' fact: pm-audit names it only as a pointer.
for case, fid in (("php-eol", "php.eol"), ("js-node-eol", "js.node.eol")):
    fs = found(case, fid)
    row(fs and all(not f["file"].startswith(".ddev") and "ddev-ops" in f["message"] for f in fs),
        f"{case}: {fid} lists the repo's own pins and leaves DDEV's to ddev-ops")

def fresh(name):
    d = tmp / "d" / name
    materialise(fixtures / "clean", d)
    return d
def run(d, *args, env=None):
    return subprocess.run([sys.executable, audit, *args, "--as-of", "2026-10-05", str(d)],
                          capture_output=True, env=env)
def ids_of(p):
    try:
        return {f["id"] for f in json.loads(p.stdout.decode("utf-8"))["data"]}
    except Exception:  # noqa: BLE001 - any parse failure reads as "no ids"
        return None
# Encodings: a UTF-8 BOM manifest parses (npm accepts it), a UTF-16 PowerShell script is
# read, and a non-ASCII file name prints on a cp1252 stdout instead of a traceback.
d = fresh("bom")
(d / "package.json").write_bytes(b"\xef\xbb\xbf" + (d / "package.json").read_bytes())
p = run(d, "--json")
row(p.returncode == 0, f"a UTF-8 BOM package.json parses (exit {p.returncode}, ids {ids_of(p)})")
d = fresh("utf16")
(d / "build.ps1").write_bytes("﻿npx eslint .\r\n".encode("utf-16-le"))
p = run(d, "--json")
row(ids_of(p) == {"npx.unpinned"}, f"a UTF-16LE PowerShell script is read (ids {ids_of(p)})")
d = fresh("cp1252")
(d / "构建.sh").write_text("npx eslint .\n", encoding="utf-8")
env = {k: v for k, v in os.environ.items() if k != "PYTHONUTF8"}
env["PYTHONIOENCODING"] = "cp1252"
p = run(d, env=env)
row(p.returncode == 10 and b"Traceback" not in p.stderr,
    f"a non-ASCII file name prints on a cp1252 stdout (exit {p.returncode})")
# JSON of the wrong shape inside a valid manifest or lock: findings, never a traceback.
d = fresh("shapes")
(d / "package.json").write_text(json.dumps({"name": "x", "dependencies": ["eslint"], "scripts": ["npx eslint"],
                                            "engines": "24", "bin": ["x"], "workspaces": "packages/*"}))
(d / "package-lock.json").write_text(json.dumps({"lockfileVersion": 3, "packages": []}))
(d / "composer.json").write_text(json.dumps({"name": "x/y", "require": ["php"], "require-dev": "x", "config": []}))
(d / "composer.lock").write_text(json.dumps({"packages": {}, "platform-overrides": []}))
p = run(d, "--json")
row(p.returncode in (0, 10) and ids_of(p) is not None and b"Traceback" not in p.stderr,
    f"maps of the wrong type in valid JSON are skipped (exit {p.returncode})")
for body in ("[]", "null"):
    (tmp / "facts-bad.json").write_text(body)
    p = run(fresh("facts-" + body), "--facts", str(tmp / "facts-bad.json"))
    row(p.returncode == 4 and b"Traceback" not in p.stderr, f"--facts holding {body} exits 4 (exit {p.returncode})")
# A tracked auth.json is committed even when .gitignore lists it (git is the authority).
if shutil.which("git"):
    d = fresh("git-tracked-authjson")
    (d / "auth.json").write_text('{"http-basic": {}}\n')
    subprocess.run(["git", "init", "-q", str(d)], capture_output=True)
    subprocess.run(["git", "-C", str(d), "add", "-f", "auth.json"], capture_output=True)
    p = run(d, "--json")
    hit = [f for f in (json.loads(p.stdout.decode("utf-8"))["data"] if ids_of(p) is not None else [])
           if f["id"] == "registry.authjson.committed"]
    row(hit and "tracked by git" in hit[0]["message"] and "git rm --cached" in hit[0]["fix"],
        f"a git-tracked auth.json is reported as tracked although .gitignore lists it (ids {ids_of(p)})")
else:
    row(True, "git-tracked auth.json case skipped: no git on PATH")
PY
)

# -- 4. version-range parser (npm semver vs Composer dialects) -----------------------
rng="$(cd "$(dirname "$AUDIT")" && "$PY" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("a", sys.argv[1])
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
N = lambda m: ((m, 0, 0), (m + 1, 0, 0))
P = lambda x, y: ((x, y, 0), (x, y + 1, 0))
V = lambda x, y, z: ((x, y, z), (x, y, z + 1))
cases = [
  ("^24.1.0", N(24), "npm", True), ("^24.1.0", N(25), "npm", False),
  (">=22 <25", N(24), "npm", True), (">=22 <25", N(25), "npm", False),
  ("22.x || 24.x", N(24), "npm", True), ("22.x || 24.x", N(23), "npm", False),
  ("20 - 22", N(22), "npm", True), ("20 - 22", N(23), "npm", False),
  (">= 18.17", N(24), "npm", True), ("18.x", N(20), "npm", False),
  ("~8.2", P(8, 3), "composer", True), ("~8.2", P(8, 3), "npm", False),
  ("^8.2", P(8, 4), "composer", True), (">=8.1 <8.4", P(8, 4), "composer", False),
  ("8.2.* || 8.3.*", P(8, 3), "composer", True), ("^7.4 | ^8.0", P(8, 1), "composer", True),
  ("^7.4", P(8, 1), "composer", False), (">=8.2,<8.5", P(8, 4), "composer", True),
  ("^8.4@dev", P(8, 4), "composer", True), ("^0.3", N(0), "npm", True),
  # Composer pads a partial version for a plain comparator (>8.2 is >8.2.0.0, admitting
  # 8.2.1) where npm reads an X-range (>8.2 is >=8.3.0); a bare 8.2 is exactly 8.2.0.
  (">8.2", P(8, 2), "composer", True), (">8.2", P(8, 2), "npm", False),
  ("<=8.2", P(8, 2), "composer", True), ("<=8.2", V(8, 2, 5), "composer", False), ("<=8.2", V(8, 2, 5), "npm", True),
  ("8.2", V(8, 2, 3), "composer", False), ("8.2", V(8, 2, 3), "npm", True),
  # != excludes one version (Composer only), and <> is its alias.
  ("!=8.3.0", V(8, 3, 0), "composer", False), ("!=8.3.0", P(8, 3), "composer", True),
  ("8.3.0 !=8.3.0", P(8, 3), "composer", False), ("<>8.3.0", V(8, 3, 0), "composer", False),
  (">=8.2 !=8.2.5", V(8, 2, 5), "composer", False),
]
bad = [f"{s!r}/{d}" for s, iv, d, want in cases if a.admits(s, iv[0], iv[1], d) is not want]
bad += ["unparseable returns None"] if a.admits("banana", (1,0,0), (2,0,0)) is not None else []
bad += ["npm has no != (None)"] if a.admits("!=1.0.0", (1,0,0), (2,0,0), "npm") is not None else []
print("ok" if not bad else "bad:" + "; ".join(bad))' "$AUDIT" 2>&1)"
[[ "$rng" == ok ]] && ok "range parser: npm + Composer dialects (32 cases)" || no "range parser: $rng"

# -- 5. facts verifier contract (§7) -------------------------------------------------
if [[ -f "$V" ]]; then
  ec 0 "verifier py_compile"           "$PY" -m py_compile "$V"
  ec 0 "verifier --help"               "$PY" "$V" --help
  ec 0 "verifier --offline consistent" "$PY" "$V" --offline --skill "$SKILL" --facts "$FACTS"
  ec 2 "verifier bad flag -> 2"        "$PY" "$V" --bogus
  ec 2 "verifier conflicting modes -> 2" "$PY" "$V" --offline --live
  ec 3 "verifier missing facts -> 3"   "$PY" "$V" --offline --facts "$TMP/nope.json"
  jout="$("$PY" "$V" --offline --json --skill "$SKILL" 2>/dev/null)"
  case "$jout" in *'"claude-mods.package-manager-ops.facts/v1"'*) ok "verifier --json envelope schema";; *) no "verifier --json envelope schema missing";; esac
  "$PY" - "$FACTS" "$TMP" <<'PY'
import json, sys
from pathlib import Path
facts = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tmp = Path(sys.argv[2])
uncited = json.loads(json.dumps(facts)); uncited["packages"]["zzz-not-real"] = {"registry": "npm", "documented_major": 1, "prose": ["zzznotreal"]}
(tmp / "uncited.json").write_text(json.dumps(uncited))
dated = json.loads(json.dumps(facts)); dated["dated_facts"]["x"] = "31 Smarch 1999"
(tmp / "dated.json").write_text(json.dumps(dated))
badtype = json.loads(json.dumps(facts)); badtype["packages"]["npm"]["documented_major"] = "12"
(tmp / "badtype.json").write_text(json.dumps(badtype))
order = json.loads(json.dumps(facts)); order["php"]["releases"]["8.4"]["active_end"] = "2030-01-01"
(tmp / "order.json").write_text(json.dumps(order))
def variant(name, edit):
    d = json.loads(json.dumps(facts)); edit(d)
    (tmp / name).write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
(tmp / "list.json").write_text("[]"); (tmp / "null.json").write_text("null")
variant("prose-int.json", lambda d: d["packages"]["npm"].__setitem__("prose", [123]))
variant("release-null.json", lambda d: d["node"]["releases"].__setitem__("22", None))
variant("node-equal.json", lambda d: d["node"]["releases"]["22"].__setitem__("maintenance", d["node"]["releases"]["22"]["lts"]))
variant("php-equal.json", lambda d: d["php"]["releases"]["8.4"].__setitem__("active_end", d["php"]["releases"]["8.4"]["initial"]))
variant("unicode.json", lambda d: d["packages"]["npm"]["prose"].append("安装"))
PY
  ec 10 "uncited package -> 10"        "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/uncited.json"
  ec 10 "unstated dated fact -> 10"    "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/dated.json"
  ec 10 "active_end after security_end -> 10" "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/order.json"
  ec 4 "non-integer major -> 4"        "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/badtype.json"
  ec 4 "facts holding [] -> 4"         "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/list.json"
  ec 4 "facts holding null -> 4"       "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/null.json"
  ec 4 "a prose token that is not a string -> 4" "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/prose-int.json"
  ec 4 "a null release entry -> 4"     "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/release-null.json"
  ec 10 "node lts == maintenance (strict order) -> 10" "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/node-equal.json"
  ec 10 "php initial == active_end (strict order) -> 10" "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/php-equal.json"
  ec 2 "--timeout -1 -> 2"             "$PY" "$V" --live --timeout -1
  ec 2 "--timeout 0 -> 2"              "$PY" "$V" --live --timeout 0
  out="$(PYTHONIOENCODING=cp1252 "$PY" "$V" --offline --skill "$SKILL" --facts "$TMP/unicode.json" 2>&1)"; rc=$?
  [[ "$rc" == 10 && "$out" != *Traceback* ]] && ok "a non-ASCII drift row prints on a cp1252 stdout (exit $rc)" \
    || no "a non-ASCII drift row on a cp1252 stdout (want 10, no traceback; got $rc)"
  # A directory named like a reference is not a reference: skipped, not a crash.
  mkdir -p "$TMP/dirref" && cp -R "$SKILL/SKILL.md" "$SKILL/references" "$TMP/dirref/" && mkdir -p "$TMP/dirref/references/zz-folder.md"
  ec 0 "a directory named *.md under references/ is skipped" "$PY" "$V" --offline --skill "$TMP/dirref" --facts "$FACTS"
  # Live classification without the network: a php.net page that is gone (404) is drift,
  # and a schedule.json date in a new format is drift with a message, not a traceback.
  live="$("$PY" - "$V" "$FACTS" <<'PY' 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("v", sys.argv[1])
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
facts = json.load(open(sys.argv[2], encoding="utf-8"))
bad = []
v.fetch = lambda url, timeout, accept="": ("notfound", 404)
d, u = v.live_php(facts, 1.0)
if not d or u:
    bad.append(f"php.net 404: drift={d} unreach={u}")
v.fetch_json = lambda url, timeout: ("ok", {"v24": {"start": "2024-04-24T00:00:00Z", "lts": "2024-10-29", "end": "2027-04-30"}})
try:
    d, u = v.live_node(facts, 1.0, v.dt.date(2026, 10, 5))
    if not any("format" in x["issue"] for x in d):
        bad.append(f"schedule date format: drift={d}")
except Exception as exc:  # noqa: BLE001 - the point is that nothing escapes
    bad.append(f"schedule date format raised {exc!r}")
print("ok" if not bad else "bad:" + "; ".join(bad))
PY
)"
  [[ "$live" == ok ]] && ok "live: php.net 404 is drift; an upstream date-format change is drift, not a traceback" \
    || no "live classification: $live"
else
  no "verifier missing: scripts/check-pm-facts.py"
fi

# -- 6. copy-alone portability: the folder runs with nothing beside it ---------------
ALONE="$TMP/alone/package-manager-ops"
mkdir -p "$TMP/alone" && cp -R "$SKILL" "$ALONE"
grep -rq '\.\./\.\./' "$ALONE/scripts" && no "scripts reach outside the skill folder (../../)" || ok "no ../../ dependency in scripts"
ec 0 "standalone run-python.sh --which"  bash "$ALONE/scripts/run-python.sh" --which
ec 0 "standalone pm-audit --help"        bash "$ALONE/scripts/run-python.sh" "$ALONE/scripts/pm-audit.py" --help
ec 0 "standalone pm-audit on clean copy" bash -c "mkdir -p '$TMP/alone/repo' && bash '$ALONE/scripts/run-python.sh' '$ALONE/scripts/pm-audit.py' --as-of 2026-10-05 '$TMP/alone/repo'"
if [[ -f "$ALONE/scripts/check-pm-facts.py" ]]; then
  ec 0 "standalone verifier --offline"   bash "$ALONE/scripts/run-python.sh" "$ALONE/scripts/check-pm-facts.py" --offline
fi

finish
