#!/usr/bin/env python3
"""Scan build-config & editor-task files for trusted-repo (config-as-code) poisoning.

The PolinRider / EtherHiding class (DPRK UNC5342) does NOT enter as a poisoned
npm dependency — the dependency tree stays clean. It appends an obfuscated
blockchain-C2 loader to first-party BUILD CONFIG files (vite.config.js,
tailwind.config.js, webpack/next/rollup/postcss/svelte/astro configs) or plants a
.vscode/tasks.json that auto-runs on folderOpen. On build it reads an XOR/Base64
payload from a blockchain dead-drop (EtherHiding) and runs it. Dependency scanners
(Socket / depscore / cooldown / exposure-check) are structurally blind to this.

This scans those config files for the injection signatures and exits 10 on a
finding: blockchain explorer-API / RPC dead-drop endpoints, eval / new Function /
shell-exec, Buffer-XOR decode loops, outbound network in a config that shouldn't
have any, hex-var (_0x..) / long-escape obfuscation, an obfuscated appended blob,
and tasks.json runOn:folderOpen auto-run. Zero-dependency (Python stdlib),
read-only. Built to run as a pre-commit hook (--staged) AND in CI (--root .).

Usage: config-drift-check.py [--root DIR]... [--staged] [FILE ...]
                             [--json] [--findings-only] [--catalog PATH]

Input:   --root dirs (default: cwd), or --staged (git staged configs), or FILEs
Output:  stdout = findings report (JSON envelope with --json)
Stderr:  progress, summary, errors
Exit:    0 clean, 2 usage, 3 root/file-not-found, 5 missing-dep (--staged w/o git),
         10 FINDINGS

Examples:
  config-drift-check.py --root .
  config-drift-check.py --staged              # pre-commit: only staged config files
  config-drift-check.py vite.config.js tailwind.config.js
  config-drift-check.py --root . --json | jq '.data.findings[]'
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

# Windows consoles default to cp1252 — non-ASCII in output crashes or mangles.
for _stream in (sys.stdout, sys.stderr):
    _reconfig = getattr(_stream, "reconfigure", None)
    if _reconfig:
        _reconfig(encoding="utf-8", errors="replace")

EXIT_OK, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_MISSING_DEP, EXIT_FINDINGS = 0, 2, 3, 5, 10
SKIP_DIRS = {".git", ".hg", ".svn", "node_modules", "worktrees", "__pycache__",
             "dist", "build", ".next", ".svelte-kit", ".astro", "vendor"}
SCHEMA = "claude-mods.supply-chain-defense.config-drift-check/v1"


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

# Build-config filename stems (any of these extensions). A loader appended here
# runs at build time — the Stage-2 EtherHiding execution vector.
CONFIG_STEMS = {
    "vite.config", "tailwind.config", "webpack.config", "next.config",
    "rollup.config", "postcss.config", "svelte.config", "astro.config",
    "vue.config", "nuxt.config", "remix.config", "craco.config",
    "babel.config", "metro.config", "snowpack.config",
}
CONFIG_EXTS = {".js", ".cjs", ".mjs", ".ts", ".cts", ".mts"}

# Detection patterns. A build config legitimately imports plugins and exports an
# object — it does NOT eval, XOR-decode, hit the network, or talk to a blockchain.
# Each of these in a config file is high-signal on its own (low false-positive).

# Blockchain dead-drop endpoints (EtherHiding). Explorer APIs are what GTIG
# documented UNC5342 using (centralized, blockable); public RPC nodes are the
# variant. A build config reaching any of these on a non-web3 project is the tell.
BLOCKCHAIN_RE = re.compile(
    r"ethplorer|blockchair|blockcypher|binplorer"            # explorer APIs (GTIG)
    r"|trongrid|tronscan|tron-rpc"                            # Tron
    r"|bsc-dataseed|bscscan|bsc-rpc|binance\.org/?|bnbchain\.org"  # BSC
    r"|aptoslabs\.com|fullnode\.\w+\.aptos|aptos-rpc"         # Aptos
    r"|cloudflare-eth|llamarpc|rpc\.ankr\.com|infura\.io|alchemy\.com/v2"  # ETH public RPC
    r"|eth_call|eth_getlogs|eth_gettransaction|getLogs\b"     # JSON-RPC read methods
    r"|web3\.eth|ethers\.providers|JsonRpcProvider", re.I)

EVAL_RE = re.compile(r"\beval\s*\(|new\s+Function\s*\(|\bFunction\s*\(\s*['\"`]", re.I)
EXEC_RE = re.compile(
    r"child_process|require\(\s*['\"]child_process['\"]\)|execSync|execFileSync"
    r"|spawnSync|\bspawn\s*\(|\bexec\s*\(|cp\.exec|\.execSync"
    r"|process\.binding", re.I)
# XOR-decrypt loop / hex-buffer + xor — the EtherHiding payload decode.
XOR_RE = re.compile(
    r"charCodeAt\([^)]*\)\s*\^|\^\s*\w+\.charCodeAt|fromCharCode\([^)]*\^"
    r"|Buffer\.from\([^)]{1,120}['\"]hex['\"]\)|\^\s*0x[0-9a-f]{1,2}\b"
    r"|String\.fromCharCode\([^)]*\^", re.I)
# Outbound network from a config file (configs are static — they don't fetch).
NET_RE = re.compile(
    r"\bfetch\s*\(|require\(\s*['\"]https?['\"]\)|require\(\s*['\"]node:https?['\"]\)"
    r"|https?\.get\s*\(|https?\.request\s*\(|XMLHttpRequest|new\s+WebSocket"
    r"|require\(\s*['\"]net['\"]\)|net\.connect|axios\.|got\(\s*['\"]https?", re.I)
# Obfuscation markers (hex-name vars, long \x escape runs, marshal/zlib decode).
OBFUS_RE = re.compile(
    r"_0x[0-9a-f]{4,}|(?:\\x[0-9a-f]{2}){12,}|(?:\\u[0-9a-f]{4}){12,}"
    r"|atob\s*\(\s*['\"][A-Za-z0-9+/=]{120,}", re.I)
# Base64-ish long blob (no whitespace) — a packed payload.
BLOB_RE = re.compile(r"['\"`][A-Za-z0-9+/=]{200,}['\"`]")
# Downloader / shell red-flags in a package.json or tasks.json command string.
SHELL_RED = re.compile(
    r"curl\s|wget\s|iwr\s|invoke-webrequest|invoke-expression|certutil|bitsadmin"
    r"|powershell|pwsh|\|\s*sh\b|\|\s*bash\b|bash\s+-c|sh\s+-c|cmd\s*/c|node\s+-e"
    r"|python\s+-c|base64\s+-d|/dev/tcp|nc\s+-e", re.I)


def log(msg):
    print(msg, file=sys.stderr)


def die(msg, code) -> NoReturn:
    log(f"ERROR: {msg}")
    sys.exit(code)


def read_text_tolerant(path: Path) -> str:
    try:
        raw = path.read_bytes()
    except OSError:
        return ""
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def is_config_file(p: Path) -> bool:
    name = p.name
    if name == "tasks.json" and p.parent.name == ".vscode":
        return True
    if name == "package.json":
        return True
    stem = name
    for ext in CONFIG_EXTS:
        if name.endswith(ext):
            stem = name[: -len(ext)]
            if stem in CONFIG_STEMS:
                return True
    return False


def load_extra_endpoints(catalog: Path):
    """Pull blockchain dead-drop domains from network-ioc.json if present (extends
    the embedded regex). Tolerant: missing/garbled catalog is not fatal."""
    domains = []
    try:
        doc = json.loads(catalog.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return domains
    for entry in doc.get("entries", []):
        cat = (entry.get("category") or "") + " " + (entry.get("id") or "")
        if "blockchain" in cat.lower() or "etherhiding" in cat.lower():
            domains.extend(entry.get("domains", []))
    return [d for d in domains if d]


def scan_js_config(text: str):
    """Findings for a JS/TS build-config file."""
    findings = []
    lines = text.splitlines()

    def evidence(rx):
        m = rx.search(text)
        return m.group(0)[:80] if m else ""

    if BLOCKCHAIN_RE.search(text):
        findings.append(("critical", "blockchain-c2",
                         f"blockchain dead-drop / RPC reference in a build config "
                         f"({evidence(BLOCKCHAIN_RE)!r}) — EtherHiding payload read"))
    if EVAL_RE.search(text):
        findings.append(("high", "eval-exec",
                         f"eval / new Function in a build config ({evidence(EVAL_RE)!r})"))
    if EXEC_RE.search(text):
        findings.append(("high", "shell-exec",
                         f"child_process / shell exec in a build config ({evidence(EXEC_RE)!r})"))
    if XOR_RE.search(text):
        findings.append(("high", "xor-decode",
                         f"XOR / hex-buffer decode loop ({evidence(XOR_RE)!r}) — payload decryptor"))
    if NET_RE.search(text):
        findings.append(("high", "outbound-network",
                         f"outbound network call in a build config ({evidence(NET_RE)!r})"))
    if OBFUS_RE.search(text):
        findings.append(("high", "obfuscation",
                         f"obfuscation markers ({evidence(OBFUS_RE)!r})"))
    # Appended obfuscated blob: a very long line that ALSO looks packed/obfuscated.
    # Plain-long lines (legit minified vendored config) don't fire — needs a payload tell.
    for i, ln in enumerate(lines):
        if len(ln) > 1500 and (OBFUS_RE.search(ln) or BLOB_RE.search(ln)
                               or EVAL_RE.search(ln) or XOR_RE.search(ln)):
            where = "tail" if i >= len(lines) - 3 else f"line {i + 1}"
            findings.append(("high", "appended-blob",
                             f"obfuscated {len(ln)}-char blob at {where} — appended loader"))
            break
    return findings


def scan_tasks_json(text: str):
    """Findings for a .vscode/tasks.json — the folderOpen auto-run vector."""
    findings = []
    try:
        doc = json.loads(re.sub(r"//.*", "", text))  # tolerate // line comments
    except json.JSONDecodeError:
        doc = None
    autorun = False
    cmd_red = False
    if isinstance(doc, dict):
        for task in doc.get("tasks", []) or []:
            if not isinstance(task, dict):
                continue
            ro = task.get("runOptions") or {}
            if isinstance(ro, dict) and ro.get("runOn") == "folderOpen":
                autorun = True
                blob = json.dumps(task)
                if SHELL_RED.search(blob):
                    cmd_red = True
    else:
        # Fallback to text scan if JSON didn't parse.
        if re.search(r'"runOn"\s*:\s*"folderOpen"', text):
            autorun = True
        if SHELL_RED.search(text):
            cmd_red = True
    if autorun and cmd_red:
        findings.append(("critical", "tasks-autorun-shell",
                         "tasks.json runOn:folderOpen auto-runs a shell/downloader command"))
    elif autorun:
        findings.append(("high", "tasks-autorun",
                         "tasks.json runOn:folderOpen auto-executes a task when the folder opens"))
    if SHELL_RED.search(text) and not autorun:
        findings.append(("medium", "tasks-shell",
                         "tasks.json task invokes a shell/downloader command"))
    return findings


def scan_package_json(text: str):
    """Findings for package.json scripts with downloader/shell red-flags."""
    findings = []
    try:
        doc = json.loads(text)
    except json.JSONDecodeError:
        return findings
    scripts = doc.get("scripts") or {}
    if isinstance(scripts, dict):
        for key, cmd in scripts.items():
            if isinstance(cmd, str) and SHELL_RED.search(cmd):
                findings.append(("high", "script-shell",
                                 f"scripts.{key}: {cmd[:120]}"))
            if isinstance(cmd, str) and BLOCKCHAIN_RE.search(cmd):
                findings.append(("critical", "script-blockchain",
                                 f"scripts.{key} references a blockchain endpoint: {cmd[:100]}"))
    return findings


def scan_file(p: Path):
    text = read_text_tolerant(p)
    if not text:
        return []
    name = p.name
    if name == "tasks.json" and p.parent.name == ".vscode":
        return scan_tasks_json(text)
    if name == "package.json":
        return scan_package_json(text)
    return scan_js_config(text)


def collect_from_roots(roots):
    files = []
    for root in roots:
        base = Path(root).expanduser()
        if not base.exists():
            log(TERM.c("orange", f"[warn] root does not exist: {base}"))
            continue
        if base.is_file():
            if is_config_file(base):
                files.append(base)
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for f in filenames:
                fp = Path(dirpath) / f
                if is_config_file(fp):
                    files.append(fp)
    return files


def collect_staged():
    if not _which("git"):
        die("--staged requires git on PATH", EXIT_MISSING_DEP)
    try:
        out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
                             capture_output=True, text=True, timeout=30)
    except (subprocess.SubprocessError, OSError) as e:
        die(f"git failed: {e}", EXIT_MISSING_DEP)
    if out.returncode != 0:
        die(f"not a git repo or git error: {out.stderr.strip()}", EXIT_MISSING_DEP)
    files = []
    for line in out.stdout.splitlines():
        p = Path(line.strip())
        if p.name and is_config_file(p) and p.is_file():
            files.append(p)
    return files


def _which(name):
    from shutil import which
    return which(name)


def main():
    ap = argparse.ArgumentParser(
        description="Scan build-config / editor-task files for config-as-code poisoning.",
        epilog="Examples:\n"
               "  config-drift-check.py --root .\n"
               "  config-drift-check.py --staged\n"
               "  config-drift-check.py vite.config.js --json | jq '.data.findings[]'\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", action="append", default=None, metavar="DIR")
    ap.add_argument("--staged", action="store_true",
                    help="scan only git-staged config files (pre-commit mode)")
    ap.add_argument("files", nargs="*", metavar="FILE")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--findings-only", action="store_true")
    ap.add_argument("--catalog", type=Path, default=None, metavar="PATH",
                    help="network-ioc.json to extend blockchain endpoints (optional)")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        sys.exit(EXIT_OK if e.code == 0 else EXIT_USAGE)

    # Extend the blockchain regex from the IOC catalog if available.
    catalog = args.catalog or (Path(__file__).resolve().parent.parent / "assets" / "network-ioc.json")
    extra = load_extra_endpoints(catalog)
    if extra:
        global BLOCKCHAIN_RE
        BLOCKCHAIN_RE = re.compile(BLOCKCHAIN_RE.pattern + "|" +
                                   "|".join(re.escape(d) for d in extra), re.I)

    # Resolve the file set from exactly one source of truth, in precedence order.
    if args.staged:
        files = collect_staged()
    elif args.files:
        files = []
        for f in args.files:
            p = Path(f).expanduser()
            if not p.exists():
                die(f"file not found: {p}", EXIT_NOT_FOUND)
            files.append(p)
    else:
        roots = args.root or [os.getcwd()]
        if not any(Path(r).expanduser().exists() for r in roots):
            die(f"no root exists among: {roots}", EXIT_NOT_FOUND)
        files = collect_from_roots(roots)

    findings = []
    scanned = 0
    for p in files:
        scanned += 1
        for sev, kind, detail in scan_file(p):
            findings.append({"file": str(p), "severity": sev, "kind": kind, "detail": detail})

    log(TERM.c("cyan", f"=== config-drift-check: {scanned} config file(s) scanned - {len(findings)} finding(s) ==="))

    if args.json:
        print(json.dumps({
            "data": {"findings": findings,
                     "scanned": [] if args.findings_only else [str(p) for p in files]},
            "meta": {"count": len(findings), "files": scanned, "schema": SCHEMA}}, indent=2))
    else:
        for fobj in findings:
            print(f"{fobj['file']}")
            print(f"   [{fobj['severity']}] {fobj['kind']}: {fobj['detail']}")
        if not findings and not args.findings_only:
            print(f"clean: no config-drift findings in {scanned} config file(s)")

    sys.exit(EXIT_FINDINGS if findings else EXIT_OK)


if __name__ == "__main__":
    main()
