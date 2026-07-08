#!/usr/bin/env python3
"""Behavioural scan of packages ALREADY on disk — the post-install gap.

The pre-install gate (socket wrapper, preinstall-check cooldown) can miss a
poisoned release; this scans what actually landed. Walks node_modules trees and
Python site-packages under --root dirs and flags behavioural red flags per
package: lifecycle scripts that spawn shells/downloaders, eval-of-base64 and
obfuscation markers, reads of credential paths (.npmrc, .aws, .claude, browser
profiles), exfil endpoints (webhook/paste/raw-IP URLs) paired with env
harvesting, and files modified after the package was installed (tamper).
Incremental: per-package fingerprint cache means a daily re-run only rescans
changed trees. Optional --deep confirms flagged npm packages with GuardDog when
installed (never a false-clean: absent engine = loud skip). Optional --live
checks each flagged npm version still exists on the registry (an unpublished
version is a takedown IOC); network errors exit 7, never fake a finding.

Usage: postinstall-audit.py [--root DIR]... [--json] [--findings-only]
                            [--cache PATH|--no-cache] [--min-severity LEVEL]
                            [--deep] [--live] [--max-file-kb N] [--max-files N]

Input:   --root dirs (default: cwd)
Output:  stdout = findings report (JSON envelope with --json)
Stderr:  progress, summary, errors
Exit:    0 clean, 2 usage, 3 root-not-found, 5 missing-dep (--deep w/o engine
         is a loud SKIP not an error), 7 registry unavailable (--live only),
         10 FINDINGS at/above --min-severity

Examples:
  postinstall-audit.py --root ~/code
  postinstall-audit.py --root X:/Forge --root X:/Lab --json | jq '.data.findings[]'
  postinstall-audit.py --root . --min-severity high --findings-only
  postinstall-audit.py --root . --deep          # confirm flags with GuardDog
  postinstall-audit.py --root . --live          # registry-unpublished check
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Windows consoles default to cp1252 — non-ASCII in output crashes or mangles.
for _stream in (sys.stdout, sys.stderr):
    _reconfig = getattr(_stream, "reconfigure", None)
    if _reconfig:
        _reconfig(encoding="utf-8", errors="replace")

EXIT_OK, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_MISSING_DEP, EXIT_UNAVAILABLE, EXIT_FINDINGS = 0, 2, 3, 5, 7, 10
SKIP_DIRS = {".git", ".hg", ".svn", "worktrees", "__pycache__"}
SEVERITIES = ("low", "medium", "high")
SCHEMA = "claude-mods.supply-chain-defense.postinstall-audit/v1"


class Term:
    """Inline ANSI helper mirroring skills/_lib/term.sh (bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline). Honors FORCE_COLOR /
    NO_COLOR / TERM_ASCII; ASCII-glyph fallback on a non-UTF stream encoding."""

    _C = {"green": "\033[32m", "orange": "\033[38;5;208m", "red": "\033[31m",
          "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}
    _G = {"ok": "✓", "bad": "✗", "warn": "▲", "unknown": "?"}
    _A = {"ok": "+", "bad": "x", "warn": "!", "unknown": "?"}
    _MC = {"ok": "green", "bad": "red", "warn": "orange", "unknown": "cyan"}

    def __init__(self, stream): self.s = stream

    @property
    def ascii(self):
        enc = (getattr(self.s, "encoding", "") or "").lower()
        return (os.environ.get("TERM_ASCII") == "1" or os.environ.get("FLEET_ASCII") == "1"
                or "utf" not in enc)

    @property
    def color(self):
        if os.environ.get("FORCE_COLOR"):
            return True
        if (os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb"
                or not getattr(self.s, "isatty", lambda: False)()):
            return False
        return True

    def c(self, n, t):
        return f"{self._C.get(n, '')}{t}{self._C['off']}" if self.color else t

    def mark(self, st):
        return self.c(self._MC.get(st, ""), (self._A if self.ascii else self._G).get(st, "."))


TERM = Term(sys.stderr)

# Lifecycle script verbs that download or spawn a shell — the Shai-Hulud entry.
LIFECYCLE_KEYS = ("preinstall", "install", "postinstall", "prepare")
LIFECYCLE_RED = re.compile(
    r"curl |wget |iwr |invoke-webrequest|invoke-expression|certutil|bitsadmin"
    r"|powershell|pwsh|\| ?sh\b|\| ?bash\b|bash -c|sh -c|cmd /c|cmd\.exe"
    r"|node -e|python -c|base64|/dev/tcp|nc -e|\bcurl$|\bwget$", re.I)
# Packages whose *benign* lifecycle scripts are expected (presence != finding;
# red-flag content in them still fires).
LIFECYCLE_KNOWN = {
    "esbuild", "sharp", "puppeteer", "playwright", "playwright-core", "husky",
    "core-js", "cypress", "fsevents", "node-pty", "@lydell/node-pty", "protobufjs",
    "bcrypt", "sqlite3", "better-sqlite3", "canvas", "node-sass", "swc",
}

# Content patterns, grouped. A finding needs either one "solo" pattern or a
# combo (cred+net, env+net, eval+b64) — singles like a long minified line are
# too noisy on real node_modules to report alone.
PAT_EVAL = re.compile(r"\beval\s*\(|new Function\s*\(|Function\s*\(\s*['\"]", re.I)
PAT_B64 = re.compile(r"atob\s*\(|b64decode|Buffer\.from\s*\([^)]{1,200}['\"]base64['\"]|base64\.decode", re.I)
PAT_CRED = re.compile(
    r"\.npmrc|\.pypirc|\.aws[/\\]credentials|\.config[/\\]gcloud|\.kube[/\\]config"
    r"|\.ssh[/\\]id_|\.claude[/\\]|\.claude\.json|claude_desktop_config"
    r"|Login Data|Local State|keychain|wallet\.dat|\.docker[/\\]config\.json", re.I)
PAT_NET = re.compile(
    r"webhook\.site|discord(app)?\.com/api/webhooks|api\.telegram\.org"
    r"|pastebin\.com|hastebin|transfer\.sh|requestbin|burpcollaborator|oast\."
    r"|interactsh|https?://\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}", re.I)
PAT_ENV = re.compile(r"JSON\.stringify\s*\(\s*process\.env\s*\)|Object\.(entries|keys)\s*\(\s*process\.env\s*\)"
                     r"|dict\s*\(\s*os\.environ\s*\)|os\.environ\.items\s*\(\)", re.I)
PAT_PERSIST = re.compile(r"settings\.json|\.claude[/\\]settings|mcpServers|\.bashrc|\.zshrc"
                         r"|Microsoft\\Windows\\CurrentVersion\\Run", re.I)
PAT_OBFUS = re.compile(r"_0x[0-9a-f]{4,}|\\x[0-9a-f]{2}(\\x[0-9a-f]{2}){15,}|marshal\.loads|zlib\.decompress\s*\(\s*base64", re.I)
SRC_EXT = {".js", ".cjs", ".mjs", ".ts", ".py", ".sh", ".ps1"}


def log(msg):
    print(msg, file=sys.stderr)


def die(msg, code):
    log(f"ERROR: {msg}")
    sys.exit(code)


def read_text_tolerant(path: Path) -> str:
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def default_cache() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "supply-chain-defense" / "postinstall-audit-cache.json"


def load_cache(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_cache(path: Path, cache: dict):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(cache), encoding="utf-8")
        tmp.replace(path)
    except OSError as e:
        log(TERM.c("orange", f"[warn] could not save cache: {e}"))


def iter_package_dirs(roots):
    """Yield ('npm', pkg_dir, install_marker_mtime) / ('pypi', dist_info_dir, None)."""
    for root in roots:
        base = Path(root).expanduser()
        if not base.exists():
            log(TERM.c("orange", f"[warn] root does not exist: {base}"))
            continue
        for dirpath, dirnames, _ in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            p = Path(dirpath)
            if p.name == "node_modules":
                marker = None
                mk = p / ".package-lock.json"
                if mk.is_file():
                    marker = mk.stat().st_mtime
                for child in sorted(p.iterdir()):
                    if not child.is_dir() or child.name.startswith("."):
                        continue
                    if child.name.startswith("@"):
                        for scoped in sorted(child.iterdir()):
                            if scoped.is_dir() and (scoped / "package.json").is_file():
                                yield "npm", scoped, marker
                    elif (child / "package.json").is_file():
                        yield "npm", child, marker
                dirnames[:] = []  # don't recurse into node_modules ourselves
            elif p.name == "site-packages":
                for child in sorted(p.iterdir()):
                    if child.is_dir() and child.name.endswith(".dist-info"):
                        yield "pypi", child, None
                dirnames[:] = []


def fingerprint(pkg_dir: Path, max_files: int):
    """Cheap stat-walk: (n_files, total_size, max_mtime). No content reads."""
    n = size = 0
    max_mtime = 0.0
    src = []
    for dirpath, dirnames, filenames in os.walk(pkg_dir):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != "node_modules"]
        for f in filenames:
            fp = Path(dirpath) / f
            try:
                st = fp.stat()
            except OSError:
                continue
            n += 1
            size += st.st_size
            max_mtime = max(max_mtime, st.st_mtime)
            if fp.suffix.lower() in SRC_EXT and len(src) < max_files:
                src.append((fp, st))
    return {"files": n, "size": size, "max_mtime": round(max_mtime, 2)}, src


def scan_npm_manifest(pkg_dir: Path):
    """Returns (name, version, lifecycle_findings)."""
    findings = []
    try:
        doc = json.loads(read_text_tolerant(pkg_dir / "package.json"))
    except (OSError, json.JSONDecodeError):
        return pkg_dir.name, "?", findings
    name = doc.get("name") or pkg_dir.name
    version = str(doc.get("version") or "?")
    scripts = doc.get("scripts") or {}
    for key in LIFECYCLE_KEYS:
        cmd = scripts.get(key)
        if not cmd:
            continue
        if LIFECYCLE_RED.search(str(cmd)):
            findings.append(("high", "lifecycle-shell",
                             f"{key}: {str(cmd)[:160]}"))
        elif name not in LIFECYCLE_KNOWN:
            findings.append(("low", "lifecycle-present", f"{key}: {str(cmd)[:120]}"))
    return name, version, findings


def scan_pypi_dist_info(dist_dir: Path):
    name = ver = "?"
    try:
        for line in read_text_tolerant(dist_dir / "METADATA").splitlines():
            if line.startswith("Name:"):
                name = line.split(":", 1)[1].strip()
            elif line.startswith("Version:"):
                ver = line.split(":", 1)[1].strip()
            if name != "?" and ver != "?":
                break
    except OSError:
        pass
    # the actual package dirs live beside the dist-info
    pkg_dirs = []
    top = dist_dir / "top_level.txt"
    if top.is_file():
        try:
            for mod in read_text_tolerant(top).split():
                cand = dist_dir.parent / mod
                if cand.is_dir():
                    pkg_dirs.append(cand)
        except OSError:
            pass
    return name, ver, pkg_dirs


def scan_sources(src_files, max_kb: int):
    """Combo-scored content scan. Returns list of (severity, kind, detail)."""
    findings = []
    hits = {"cred": [], "net": [], "env": [], "persist": [], "obfus": []}
    eval_b64_files = []  # eval AND base64 in the SAME small non-minified file
    for fp, st in src_files:
        if st.st_size > max_kb * 1024 or st.st_size == 0:
            continue
        try:
            text = fp.read_bytes().decode("utf-8", errors="replace")
        except OSError:
            continue
        minified = fp.name.endswith(".min.js") or (
            text.count("\n") < 5 and len(text) > 5000)
        rel = fp.name
        if PAT_CRED.search(text):
            hits["cred"].append(rel)
        if PAT_NET.search(text):
            hits["net"].append(rel)
        if PAT_ENV.search(text):
            hits["env"].append(rel)
        if PAT_PERSIST.search(text):
            hits["persist"].append(rel)
        if not minified and PAT_OBFUS.search(text):
            hits["obfus"].append(rel)
        # eval+base64 is rampant in legit bundlers/source-maps/wasm loaders, so it
        # is only weakly suspicious: require co-occurrence in ONE small, non-minified
        # file and report it low (below the default medium gate — visible with
        # --min-severity low or --json, not in routine runs).
        if not minified and st.st_size < 50 * 1024 and PAT_EVAL.search(text) and PAT_B64.search(text):
            eval_b64_files.append(rel)
    def first(k):
        return ", ".join(sorted(set(hits[k]))[:3])
    if hits["cred"] and hits["net"]:
        findings.append(("high", "cred-exfil",
                         f"credential-path read ({first('cred')}) + exfil endpoint ({first('net')})"))
    if hits["env"] and hits["net"]:
        findings.append(("high", "env-exfil",
                         f"env harvesting ({first('env')}) + exfil endpoint ({first('net')})"))
    if eval_b64_files:
        findings.append(("low", "eval-base64",
                         f"eval/Function + base64 decode in same file ({', '.join(sorted(set(eval_b64_files))[:3])})"))
    if hits["obfus"]:
        findings.append(("medium", "obfuscation",
                         f"obfuscation markers in non-minified source ({first('obfus')})"))
    if hits["persist"] and (hits["net"] or eval_b64_files):
        findings.append(("medium", "persistence-write",
                         f"agent/editor settings reference + payload marker ({first('persist')})"))
    if hits["cred"] and not hits["net"]:
        findings.append(("low", "cred-path-reference",
                         f"references credential paths ({first('cred')})"))
    return findings


def tamper_check(fp_info: dict, marker_mtime):
    """Files modified well after install time = post-install tamper signal."""
    if not marker_mtime:
        return []
    grace = 120  # npm touches files during extract; allow 2 min
    if fp_info["max_mtime"] > marker_mtime + grace:
        when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(fp_info["max_mtime"]))
        return [("medium", "modified-after-install",
                 f"newest file mtime {when} postdates install marker by "
                 f"{int(fp_info['max_mtime'] - marker_mtime)}s")]
    return []


def deep_confirm(pkg_dir: Path, eco: str):
    """GuardDog confirmation for a flagged package. Loud skip if absent."""
    if not (shutil.which("guarddog") and shutil.which("semgrep")):
        return None  # caller logs the loud skip once
    env = dict(os.environ, PYTHONUTF8="1")  # Windows: silent false-clean without it
    sub = "npm" if eco == "npm" else "pypi"
    try:
        r = subprocess.run(["guarddog", sub, "scan", str(pkg_dir)],
                           capture_output=True, text=True, timeout=300, env=env)
        out = (r.stdout or "") + (r.stderr or "")
        m = re.search(r"(\d+)\s+potentially malicious indicators", out)
        n = int(m.group(1)) if m else 0
        return {"indicators": n, "raw": out[-800:]}
    except (subprocess.SubprocessError, OSError) as e:
        return {"indicators": -1, "raw": f"guarddog failed: {e}"}


def live_check(name: str, version: str):
    """Does the registry still serve this exact version? Unpublished = IOC."""
    import urllib.request
    import urllib.error
    url = f"https://registry.npmjs.org/{name.replace('/', '%2F')}/{version}"
    try:
        req = urllib.request.Request(url, method="GET",
                                     headers={"Accept": "application/vnd.npm.install-v1+json"})
        with urllib.request.urlopen(req, timeout=10):
            return "present"
    except urllib.error.HTTPError as e:
        return "absent" if e.code == 404 else "unavailable"
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unavailable"


def main():
    ap = argparse.ArgumentParser(
        description="Behavioural scan of installed npm/PyPI packages (post-install gap).",
        epilog="Examples:\n"
               "  postinstall-audit.py --root ~/code\n"
               "  postinstall-audit.py --root X:/Forge --json | jq '.data.findings[]'\n"
               "  postinstall-audit.py --root . --deep --min-severity high\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", action="append", default=None, metavar="DIR")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--findings-only", action="store_true")
    ap.add_argument("--cache", type=Path, default=None, metavar="PATH")
    ap.add_argument("--no-cache", action="store_true")
    ap.add_argument("--min-severity", choices=SEVERITIES, default="medium")
    ap.add_argument("--deep", action="store_true",
                    help="confirm flagged packages with GuardDog if installed")
    ap.add_argument("--live", action="store_true",
                    help="check flagged npm versions still exist on the registry")
    ap.add_argument("--max-file-kb", type=int, default=512)
    ap.add_argument("--max-files", type=int, default=120)
    try:
        args = ap.parse_args()
    except SystemExit as e:
        sys.exit(EXIT_OK if e.code == 0 else EXIT_USAGE)

    roots = args.root or [os.getcwd()]
    if not any(Path(r).expanduser().exists() for r in roots):
        die(f"no root exists among: {roots}", EXIT_NOT_FOUND)

    cache_path = args.cache or default_cache()
    cache = {} if args.no_cache else load_cache(cache_path)
    min_idx = SEVERITIES.index(args.min_severity)

    deep_engine = bool(shutil.which("guarddog") and shutil.which("semgrep"))
    if args.deep and not deep_engine:
        log("[deep] SKIPPED — guarddog/semgrep not installed; heuristics only.")
        log("[deep] install on demand:  uv tool install guarddog semgrep")

    t0 = time.time()
    scanned = cached = 0
    packages = []
    findings = []
    live_unavailable = False

    for eco, pkg_dir, marker in iter_package_dirs(roots):
        if eco == "npm":
            name, version, pkg_findings = scan_npm_manifest(pkg_dir)
            scan_dirs = [pkg_dir]
        else:
            name, version, scan_dirs = scan_pypi_dist_info(pkg_dir)
            pkg_findings = []
            if not scan_dirs:
                continue
        key = str(pkg_dir.resolve())
        fp_info, src = fingerprint(scan_dirs[0], args.max_files)
        for extra in scan_dirs[1:]:
            fi2, src2 = fingerprint(extra, args.max_files - len(src))
            fp_info["files"] += fi2["files"]
            fp_info["size"] += fi2["size"]
            fp_info["max_mtime"] = max(fp_info["max_mtime"], fi2["max_mtime"])
            src.extend(src2)
        fpid = f"{name}@{version}:{fp_info['files']}:{fp_info['size']}:{fp_info['max_mtime']}"
        entry = cache.get(key)
        if entry and entry.get("fpid") == fpid:
            pkg_findings = [tuple(f) for f in entry.get("findings", [])]
            cached += 1
        else:
            pkg_findings += scan_sources(src, args.max_file_kb)
            pkg_findings += tamper_check(fp_info, marker)
            cache[key] = {"fpid": fpid, "findings": pkg_findings,
                          "scanned": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            scanned += 1
        packages.append({"ecosystem": eco, "name": name, "version": version,
                         "path": str(pkg_dir)})
        reportable = [f for f in pkg_findings if SEVERITIES.index(f[0]) >= min_idx]
        if not reportable:
            continue
        rec = {"ecosystem": eco, "name": name, "version": version,
               "path": str(pkg_dir),
               "findings": [{"severity": s, "kind": k, "detail": d} for s, k, d in reportable]}
        if args.deep and deep_engine:
            rec["guarddog"] = deep_confirm(pkg_dir, eco)
        if args.live and eco == "npm":
            status = live_check(name, version)
            rec["registry"] = status
            if status == "absent":
                rec["findings"].append({"severity": "high", "kind": "registry-unpublished",
                                        "detail": f"{name}@{version} no longer served by registry (takedown IOC)"})
            elif status == "unavailable":
                live_unavailable = True
        findings.append(rec)

    if not args.no_cache:
        save_cache(cache_path, cache)

    elapsed = round(time.time() - t0, 1)
    log(TERM.c("cyan", f"=== postinstall-audit: {len(packages)} packages ({scanned} scanned, "
                       f"{cached} cache hits) in {elapsed}s - {len(findings)} flagged ==="))

    if args.json:
        print(json.dumps({"data": {"findings": findings,
                                   "packages": [] if args.findings_only else packages},
                          "meta": {"count": len(findings), "packages": len(packages),
                                   "scanned": scanned, "cache_hits": cached,
                                   "elapsed_s": elapsed, "schema": SCHEMA}}, indent=2))
    else:
        for rec in findings:
            print(f"{rec['ecosystem']}:{rec['name']}@{rec['version']}  {rec['path']}")
            for f in rec["findings"]:
                print(f"   [{f['severity']}] {f['kind']}: {f['detail']}")
            if rec.get("guarddog"):
                print(f"   [deep] guarddog indicators: {rec['guarddog']['indicators']}")
        if not findings and not args.findings_only:
            print("clean: no behavioural findings at/above "
                  f"severity '{args.min_severity}'")

    if findings:
        sys.exit(EXIT_FINDINGS)
    if args.live and live_unavailable:
        sys.exit(EXIT_UNAVAILABLE)
    sys.exit(EXIT_OK)


if __name__ == "__main__":
    main()
