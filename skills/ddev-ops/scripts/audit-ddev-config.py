#!/usr/bin/env python3
"""Audit a project's .ddev/ directory for the configuration landmines that break teams.

Each check is a quiet failure with its reason sourced from DDEV's docs or source
(v1.25.4), and most were seen in a 2026-10-05 read of 36 DDEV-based agency
repositories: a taken-over `craft` command shadowing DDEV's built-in (19 repos), router
ports and performance_mode committed for the whole team (18 and 14), host SSH-agent
forwarding into containers (13), upload_dirs written relative to the project root when
DDEV resolves them from the docroot (8), and keys DDEV no longer reads (it parses
config.yaml non-strictly, so they are ignored, not rejected). The rest - unpinned PHP
or database versions that move with DDEV's defaults, CRLF command files DDEV skips,
push stanzas in provider recipes, secrets in committed env files - come from DDEV's
documentation.

Facts (defaults, end-of-life floors, obsolete keys, built-in command names) are read
from assets/ddev-facts.json - the one place they live; check-ddev-facts.py keeps that
file current. Read-only: the script never writes to the project.

The YAML reader is deliberately minimal (stdlib only, so the skill folder runs when
copied alone): top-level `key: value`, block and flow lists of scalars, and one level
of nested map (`database: {type, version}`). That covers .ddev/config.yaml; anything
it cannot read is reported, not guessed.

Usage:   audit-ddev-config.py [PROJECT_DIR] [--json] [--ignore CHECK]... [--catalog FILE] [-q]
Input:   PROJECT_DIR (default "."), which must contain .ddev/config.yaml. No stdin.
Output:  stdout = findings, one per line: severity<TAB>check<TAB>file<TAB>detail,
         or the --json envelope (schema claude-mods.ddev-ops.audit/v1). Data only.
         Secret values are never printed - only the key name.
Stderr:  the verdict line, notices, errors.
Exit:    0 clean, 2 usage, 3 no .ddev/config.yaml or catalog missing,
         4 config or catalog unreadable, 10 findings reported

Checks:  php-unpinned php-out-of-range php-eol db-unpinned node-eol composer-v1
         obsolete-key perf-mode-committed router-ports-committed xdebug-committed
         upload-dir-misplaced upload-dir-outside shadowed-command crlf-command
         ssh-agent-forwarded provider-push committed-secret

Examples:
  audit-ddev-config.py                         # audit the project in the current directory
  audit-ddev-config.py ~/sites/shop --json | jq '.data[] | select(.severity=="high")'
  audit-ddev-config.py . --ignore shadowed-command   # a deliberate command override
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_FINDINGS = 10

SCHEMA = "claude-mods.ddev-ops.audit/v1"
FACTS_SCHEMA = "claude-mods.ddev-ops.facts/v1"
DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "assets" / "ddev-facts.json"

CHECKS = (
    "php-unpinned", "php-out-of-range", "php-eol", "db-unpinned", "node-eol", "composer-v1",
    "obsolete-key", "perf-mode-committed", "router-ports-committed", "xdebug-committed",
    "upload-dir-misplaced", "upload-dir-outside", "shadowed-command", "crlf-command",
    "ssh-agent-forwarded", "provider-push", "committed-secret",
)

KEY_RE = re.compile(r"^([A-Za-z_][\w-]*):(?:\s+(.*))?$")
ITEM_RE = re.compile(r"^\s+-\s*(.*)$")
NESTED_RE = re.compile(r"^\s+([A-Za-z_][\w-]*):\s*(.*)$")
# A committed env-file key whose value is likely a credential. Values are never printed.
# Specific suffixes, not bare KEY/AUTH: those would flag REDIS_KEY_PREFIX or GIT_AUTHOR_NAME.
SECRET_KEY_RE = re.compile(
    r"(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY|SECURITY_KEY|ACCESS_KEY|AUTH_KEY|CREDENTIALS?)", re.I)
# DDEV's own local-only credentials (db/db, root/root) are not secrets; nor is a ${VAR} reference.
HARMLESS_VALUES = {"", "db", "root"}


class ConfigError(Exception):
    pass


# === YAML subset ===

def _scalar(raw: str) -> str:
    """Strip quotes and a trailing comment from a scalar."""
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        q = raw[0]
        end = raw.find(q, 1)
        return raw[1:end] if end > 0 else raw[1:]
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip()


def parse_yaml_subset(text: str, name: str) -> dict:
    """Top-level keys of a DDEV config file -> {key: str | list[str] | dict[str, str]}."""
    data: dict = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#") or line.startswith("---"):
            i += 1
            continue
        if line[0] in " \t":
            raise ConfigError(f"{name}: unexpected indented line {i + 1} outside a block")
        m = KEY_RE.match(line.rstrip())
        if not m:
            raise ConfigError(f"{name}: cannot read line {i + 1}")
        key, rest = m.group(1), (m.group(2) or "")
        rest_clean = _scalar(rest) if rest else ""
        if rest_clean.startswith("[") and rest_clean.endswith("]"):
            inner = rest_clean[1:-1].strip()
            data[key] = [_scalar(x) for x in inner.split(",") if x.strip()] if inner else []
            i += 1
            continue
        if rest_clean:
            data[key] = rest_clean
            i += 1
            continue
        # Empty value: a block (list or one-level map) or a genuinely empty key.
        block_items: list[str] = []
        block_map: dict[str, str] = {}
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or lines[j][0] in " \t" or lines[j].lstrip().startswith("#")):
            sub = lines[j]
            if sub.strip() and not sub.lstrip().startswith("#"):
                im = ITEM_RE.match(sub)
                nm = NESTED_RE.match(sub)
                if im:
                    block_items.append(_scalar(im.group(1)))
                elif nm:
                    block_map[nm.group(1)] = _scalar(nm.group(2))
            j += 1
        data[key] = block_items if block_items else (block_map if block_map else "")
        i = j
    return data


# === Helpers ===

def load_catalog(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalog not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        cat = json.loads(path.read_text(encoding="utf-8"))
        if cat.get("schema") != FACTS_SCHEMA:
            raise ValueError(f"schema must be {FACTS_SCHEMA!r}")
        for k in ("defaults", "eol_floor", "node_codenames", "obsolete_keys", "builtin_commands"):
            if not isinstance(cat.get(k), dict):
                raise ValueError(f"{k} must be an object")
        return cat
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"error: could not parse catalog {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def version_tuple(v: str) -> tuple[int, ...] | None:
    m = re.match(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?", str(v).strip())
    if not m:
        return None
    return tuple(int(x) for x in m.groups() if x is not None)


def node_major(value: str, codenames: dict) -> int | None:
    """Major from a nodejs_version value; None when DDEV resolves it elsewhere (auto, engine, "")."""
    v = value.strip().lower()
    if not v or v in ("auto", "engine") or v.startswith("lts"):
        return None
    if v in codenames:
        return int(codenames[v])
    t = version_tuple(v)
    return t[0] if t else None


def rel(p: Path, root: Path) -> str:
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        return p.as_posix()


def inside(child: Path, root: Path) -> bool:
    try:
        child.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


# === Audit ===

def audit(project: Path, cat: dict) -> list[dict]:
    ddev = project / ".ddev"
    findings: list[dict] = []

    def add(sev: str, check: str, path: Path, detail: str) -> None:
        findings.append({"severity": sev, "check": check, "file": rel(path, project), "detail": detail})

    # Committed config = config.yaml plus every config.*.yaml that is not *.local.yaml
    # (DDEV's generated .ddev/.gitignore excludes config.local.yaml and config.*.local.yaml).
    committed: list[tuple[Path, dict]] = []
    main_cfg = ddev / "config.yaml"
    files = [main_cfg] + sorted(p for p in ddev.glob("config.*.yaml") if not p.name.endswith(".local.yaml"))
    for f in files:
        try:
            committed.append((f, parse_yaml_subset(f.read_text(encoding="utf-8", errors="replace"), rel(f, project))))
        except ConfigError as exc:
            print(f"error: {exc}", file=sys.stderr)
            raise SystemExit(EX_UNPARSEABLE)
    local_files = [ddev / "config.local.yaml"] + sorted(ddev.glob("config.*.local.yaml"))
    local_cfg: dict = {}
    for f in local_files:
        if f.is_file():
            try:
                local_cfg.update(parse_yaml_subset(f.read_text(encoding="utf-8", errors="replace"), rel(f, project)))
            except ConfigError:
                pass  # a local file is the developer's own business; never fail on it

    def first(key: str) -> tuple[Path, object] | None:
        found = None
        for f, d in committed:  # later override files win, as in DDEV's merge
            if key in d and d[key] not in ("", [], {}):
                found = (f, d[key])
        return found

    cfg = committed[0][1]
    defaults = cat["defaults"]

    # PHP
    php = first("php_version")
    if php is None and "php_version" not in local_cfg:
        add("high", "php-unpinned", main_cfg,
            f"no php_version: the project follows DDEV's default ({defaults['php_version']} today; it moved "
            "from 8.3 to 8.4 in v1.25.0). Pin production's PHP minor.")
    elif php is not None:
        f, val = php
        pv = version_tuple(str(val))
        lo, hi = version_tuple(cat["php_range"]["min"]), version_tuple(cat["php_range"]["max"])
        floor = version_tuple(cat["eol_floor"]["php"])
        if pv is None or (lo and pv[:2] < lo) or (hi and pv[:2] > hi):
            add("high", "php-out-of-range", f,
                f"php_version {val!r} is outside what DDEV ships ({cat['php_range']['min']}-{cat['php_range']['max']}, major.minor only)")
        elif floor and pv[:2] < floor:
            add("medium", "php-eol", f,
                f"php_version {val} is end of life upstream (oldest supported line: {cat['eol_floor']['php']}). "
                "Check production runs the same minor and plan the upgrade.")

    # Database
    if first("database") is None and "database" not in local_cfg:
        add("medium", "db-unpinned", main_cfg,
            f"no database pinned: the engine comes from DDEV's defaults ({defaults['database']} generally; "
            "mysql:8.0 for craftcms when written by `ddev config`), and switching engines later needs a migration.")

    # Node
    node = first("nodejs_version")
    if node is not None:
        f, val = node
        major = node_major(str(val), cat["node_codenames"])
        if major is not None and major < int(cat["eol_floor"]["nodejs"]):
            add("medium", "node-eol", f,
                f"nodejs_version {val!r} is Node {major}, end of life upstream (oldest supported: "
                f"{cat['eol_floor']['nodejs']}). Old build chains often pin it; plan the upgrade.")

    comp = first("composer_version")
    if comp is not None and str(comp[1]).strip().startswith("1"):
        add("low", "composer-v1", comp[0], "composer_version 1 is end of life; move to 2 (`composer_version: \"2\"`).")

    # Keys DDEV no longer reads
    for f, d in committed:
        for key, why in cat["obsolete_keys"].items():
            if not key.startswith("_") and key in d:
                add("medium", "obsolete-key", f, f"{key}: {why}")

    # Per-developer settings committed for the whole team
    for f, d in committed:
        pm = str(d.get("performance_mode", "")).strip()
        if pm and pm != "global":
            add("medium", "perf-mode-committed", f,
                f"performance_mode: {pm} is committed, so it applies to every teammate. Mutagen helps on macOS and "
                "traditional Windows, not on Linux/WSL2; set it in config.local.yaml or `ddev config global`.")
        ports = [k for k in ("router_http_port", "router_https_port") if str(d.get(k, "")).strip()]
        if ports:
            add("low", "router-ports-committed", f,
                f"{', '.join(ports)} committed: project values override global config, so a teammate with a port "
                "clash cannot fix it with `ddev config global`. Remove them from the project.")
        if str(d.get("xdebug_enabled", "")).strip().lower() == "true":
            add("low", "xdebug-committed", f,
                "xdebug_enabled: true slows every request for everyone; toggle per session with `ddev xdebug on`.")

    # upload_dirs resolve from the DOCROOT (calculateHostUploadDirFullPath joins onto it).
    docroot = str(cfg.get("docroot", "") or "").strip().strip("/")
    base = project / docroot if docroot else project
    uploads = first("upload_dirs")
    if uploads is not None:
        f, val = uploads
        for entry in (val if isinstance(val, list) else [str(val)]):
            entry = entry.strip()
            if not entry:
                continue
            target = Path(os.path.normpath(base / entry))
            if not inside(target, project):
                add("high", "upload-dir-outside", f,
                    f"upload_dirs entry {entry!r} resolves outside the project; DDEV requires it inside.")
            elif docroot and not target.exists() and (project / entry).exists():
                add("medium", "upload-dir-misplaced", f,
                    f"upload_dirs entry {entry!r} resolves from the docroot to {rel(target, project)}, which does not "
                    f"exist, while {entry}/ exists at the project root. Write it as ../{entry}.")

    # Custom commands
    builtins = {k: set(v) for k, v in cat["builtin_commands"].items() if not k.startswith("_")}
    cmd_root = ddev / "commands"
    if cmd_root.is_dir():
        for svc_dir in sorted(p for p in cmd_root.iterdir() if p.is_dir() and not p.name.startswith(".")):
            for cmd in sorted(p for p in svc_dir.iterdir() if p.is_file()):
                if cmd.name.startswith(("README", ".")) or cmd.name.endswith(".example"):
                    continue
                raw = cmd.read_bytes()
                if b"\r\n" in raw:
                    add("high", "crlf-command", cmd,
                        "CRLF line endings: DDEV skips this command with a warning. Convert to LF and pin "
                        "`.ddev/commands/** text eol=lf` in .gitattributes.")
                if cmd.name in builtins.get(svc_dir.name, set()) and b"#ddev-generated" not in raw:
                    add("medium", "shadowed-command", cmd,
                        f"shadows DDEV's built-in `ddev {cmd.name}` (project commands register first), freezing an "
                        "old copy. Delete it unless the override is deliberate.")

    # Compose overrides that forward the host SSH agent
    for comp_file in sorted(ddev.glob("docker-compose.*.y*ml")):
        text = comp_file.read_text(encoding="utf-8", errors="replace")
        hit = "ssh-auth.sock" in text or re.search(r"\$\{?SSH_AUTH_SOCK", text) or re.search(
            r"SSH_AUTH_SOCK\s*[=:]\s*['\"]?(?!/home/\.ssh-agent)/", text)
        if hit:
            add("high", "ssh-agent-forwarded", comp_file,
                "forwards the host SSH agent into a container: every process there (Composer and npm scripts "
                "included) can sign with every key that agent holds. Use `ddev auth ssh -f <one scoped key>` instead.")

    # Provider recipes that can push
    prov = ddev / "providers"
    if prov.is_dir():
        for recipe in sorted(prov.glob("*.y*ml")):
            text = recipe.read_text(encoding="utf-8", errors="replace")
            stanzas = [s for s in ("db_push_command", "files_push_command") if re.search(rf"^{s}:", text, re.M)]
            if stanzas:
                add("medium", "provider-push", recipe,
                    f"{' and '.join(stanzas)} present: `ddev push` overwrites the upstream database/files. Remove the "
                    "push stanzas from any recipe that can reach production.")

    # Credentials in committed env files (.local twins are gitignored from v1.25.4)
    for env in sorted(ddev.glob(".env*")):
        if not env.is_file() or env.name.endswith((".local", ".example")):
            continue
        keys = []
        for line in env.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][\w]*)\s*=\s*(.*)$", line)
            if not m or not SECRET_KEY_RE.search(m.group(1)):
                continue
            value = _scalar(m.group(2))
            if value not in HARMLESS_VALUES and not value.startswith("$"):
                keys.append(m.group(1))
        if keys:
            add("medium", "committed-secret", env,
                f"credential-looking value(s) for {', '.join(sorted(set(keys)))} in a committed env file. Move them "
                f"to {env.name}.local (gitignored, DDEV v1.25.4+) and commit an .example listing the keys.")
    return findings


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="audit-ddev-config.py",
        description="Audit a project's .ddev/ directory for configuration landmines (read-only).",
        epilog=(
            "Examples:\n"
            "  audit-ddev-config.py\n"
            "  audit-ddev-config.py ~/sites/shop --json | jq '.data[] | select(.severity==\"high\")'\n"
            "  audit-ddev-config.py . --ignore shadowed-command\n"
            "\nChecks: " + " ".join(CHECKS)
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("project", nargs="?", default=".", help="project directory containing .ddev/ (default .)")
    p.add_argument("--json", action="store_true", help="emit the JSON envelope")
    p.add_argument("--ignore", action="append", default=[], metavar="CHECK", help="suppress a check (repeatable)")
    p.add_argument("--catalog", default=str(DEFAULT_CATALOG), help="facts catalog (assets/ddev-facts.json)")
    p.add_argument("-q", "--quiet", action="store_true", help="suppress the stderr verdict line")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    unknown = [c for c in args.ignore if c not in CHECKS]
    if unknown:
        print(f"error: unknown check(s) for --ignore: {', '.join(unknown)} (see --help)", file=sys.stderr)
        return EX_USAGE

    project = Path(args.project).expanduser().resolve()
    if not (project / ".ddev" / "config.yaml").is_file():
        print(f"error: no .ddev/config.yaml under {args.project}", file=sys.stderr)
        return EX_NOTFOUND
    cat = load_catalog(Path(args.catalog))
    findings = [f for f in audit(project, cat) if f["check"] not in args.ignore]

    if args.json:
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings), "schema": SCHEMA,
                                   "facts_as_of": cat.get("as_of", "")}}, indent=2))
    else:
        for f in findings:
            print(f"{f['severity']}\t{f['check']}\t{f['file']}\t{f['detail']}")
    if not args.quiet:
        by = {s: sum(1 for f in findings if f["severity"] == s) for s in ("high", "medium", "low")}
        verdict = "FINDINGS" if findings else "CLEAN"
        print(f"audit-ddev-config: {verdict} ({by['high']} high, {by['medium']} medium, {by['low']} low)",
              file=sys.stderr)
    return EX_FINDINGS if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
