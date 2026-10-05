#!/usr/bin/env python3
"""Audit a project's .ddev/ directory for the configuration landmines that break teams.

Each check is a quiet failure with its reason sourced from DDEV's docs or source
(v1.25.4), and most were seen in a 2026-10-05 read of 36 DDEV-based agency
repositories: a taken-over `craft` command shadowing DDEV's built-in (19 repos), router
ports and performance_mode committed for the whole team (18 and 14), host SSH-agent
forwarding into containers (15), upload_dirs written relative to the project root when
DDEV resolves them from the docroot (8), a committed `name:` (all 36 - a collision as
soon as a second git worktree starts), and keys DDEV no longer reads. The rest -
unpinned PHP or database versions that move with DDEV's defaults, CRLF command files
DDEV skips, push stanzas in provider recipes, a files_pull_command that fetches nothing
(DDEV then empties the upload directory - read from its source, not runtime-tested),
secrets in committed env files - come from DDEV's documentation and source.

How DDEV reads config, mirrored here: config.yaml first, then every committed
config.*.yaml / config.*.yml (not *.local.*) in name order. Since v1.25.2 it merges them
with Viper: scalars override, LISTS APPEND unless that file sets `override_config: true`,
and unknown keys are ignored rather than rejected (so retired keys silently do nothing).

Facts (defaults, end-of-life floors, obsolete keys, built-in command names) are read
from assets/ddev-facts.json - the one place they live; check-ddev-facts.py keeps that
file current. Read-only: the script never writes to the project.

The YAML reader is deliberately minimal (stdlib only, so the skill folder runs when
copied alone): top-level `key: value`, block and flow lists of scalars, and one level
of nested map (`database: {type, version}`). That covers .ddev/config.yaml; anything
it cannot read is reported, not guessed.

Usage:   audit-ddev-config.py [PROJECT_DIR] [--json] [--ignore CHECK]... [--catalog FILE] [-q]
Input:   PROJECT_DIR (default "."), which must contain .ddev/config.yaml. No stdin.
Output:  stdout = findings sorted high, medium, low; one per line:
         severity<TAB>check<TAB>file<TAB>detail, or the --json envelope
         (schema claude-mods.ddev-ops.audit/v1). Data only. Secret values are never
         printed - only the key name.
Stderr:  the verdict line, notices, errors.
Exit:    0 clean, 2 usage, 3 no .ddev/config.yaml or catalog missing,
         4 config or catalog unreadable, 10 findings reported

Checks:  php-unpinned php-out-of-range php-eol db-unpinned node-eol composer-v1
         obsolete-key perf-mode-committed router-ports-committed xdebug-committed
         name-in-worktree upload-dir-misplaced upload-dir-outside shadowed-command
         crlf-command ssh-agent-forwarded provider-push provider-files-noop
         committed-secret

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
    "name-in-worktree", "upload-dir-misplaced", "upload-dir-outside", "shadowed-command",
    "crlf-command", "ssh-agent-forwarded", "provider-push", "provider-files-noop", "committed-secret",
)
SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}

KEY_RE = re.compile(r"^([A-Za-z_][\w-]*):(?:\s+(.*))?$")
ITEM_RE = re.compile(r"^\s+-\s*(.*)$")
NESTED_RE = re.compile(r"^\s+([A-Za-z_][\w-]*):\s*(.*)$")
# A committed env-file key whose value is likely a credential. Values are never printed.
# Specific suffixes, not bare KEY/AUTH: those would flag REDIS_KEY_PREFIX or GIT_AUTHOR_NAME.
SECRET_KEY_RE = re.compile(
    r"(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY|SECURITY_KEY|ACCESS_KEY|AUTH_KEY|CREDENTIALS?)", re.I)
# DDEV's own local-only credentials (db/db, root/root) are not secrets; nor is a ${VAR} reference.
HARMLESS_VALUES = {"", "db", "root"}
GENERATED = "#ddev-generated"


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


def is_local(p: Path) -> bool:
    return ".local." in p.name


NOOP_LINE = re.compile(r"^(#.*|set\s+-.*|true|:|exit\s+0)?$")


def files_pull_body(recipe_text: str) -> list[str] | None:
    """Meaningful lines of a recipe's files_pull_command script, or None when absent.

    Comments, `set -...`, `true`, `:` and `exit 0` count as nothing, so [] means a stanza
    that downloads nothing."""
    m = re.search(r"^files_pull_command:\s*\n((?:[ \t]+.*\n?|\s*\n)*)", recipe_text, re.M)
    if not m:
        return None
    block = m.group(1)
    cmd = re.search(r"^\s+command:\s*(.*)$", block, re.M)
    if not cmd:
        return []
    inline = cmd.group(1).strip()
    if inline and inline not in ("|", ">", "|-", ">-"):
        lines = [inline.strip("'\"")]
    else:
        after = block[cmd.end():].splitlines()
        lines = []
        for ln in after:
            if re.match(r"^\s{2}[A-Za-z_]+:", ln) and not re.match(r"^\s{4,}", ln):
                break  # next key of the stanza (e.g. service:)
            lines.append(ln.strip())
    return [ln for ln in lines if not NOOP_LINE.match(ln)]


def read_config_files(project: Path, files: list[Path], strict: bool) -> list[tuple[Path, dict]]:
    out = []
    for f in files:
        try:
            out.append((f, parse_yaml_subset(f.read_text(encoding="utf-8", errors="replace"), rel(f, project))))
        except ConfigError as exc:
            if strict:
                print(f"error: {exc}", file=sys.stderr)
                raise SystemExit(EX_UNPARSEABLE)
            # a local file is the developer's own business; never fail on it
    return out


def merge(configs: list[tuple[Path, dict]]) -> tuple[dict, dict]:
    """DDEV's merge: scalars override, lists append unless the file sets override_config.

    Returns (merged values, source file per key; for lists, a parallel list of sources)."""
    merged: dict = {}
    source: dict = {}
    for f, d in configs:
        replace = str(d.get("override_config", "")).strip().lower() == "true"
        for k, v in d.items():
            if isinstance(v, list) and isinstance(merged.get(k), list) and not replace:
                merged[k] = merged[k] + v
                source[k] = source[k] + [f] * len(v)
            else:
                merged[k] = v
                source[k] = [f] * len(v) if isinstance(v, list) else f
    return merged, source


# === Audit ===

def audit(project: Path, cat: dict) -> list[dict]:
    ddev = project / ".ddev"
    findings: list[dict] = []

    def add(sev: str, check: str, path: Path, detail: str) -> None:
        findings.append({"severity": sev, "check": check, "file": rel(path, project), "detail": detail})

    main_cfg = ddev / "config.yaml"
    overrides = sorted(p for p in ddev.glob("config.*.y*ml") if not is_local(p))
    committed = read_config_files(project, [main_cfg] + overrides, strict=True)
    local_files = sorted(p for p in ddev.glob("config.*.y*ml") if is_local(p) or p.stem == "config.local")
    local_cfg, _ = merge(read_config_files(project, local_files, strict=False))
    cfg, source = merge(committed)

    def pinned(key: str) -> tuple[Path, object] | None:
        val = cfg.get(key)
        if val in (None, "", [], {}):
            return None
        src = source[key]
        return (src[-1] if isinstance(src, list) else src), val

    defaults = cat["defaults"]

    # PHP
    php = pinned("php_version")
    if php is None and "php_version" not in local_cfg:
        add("high", "php-unpinned", main_cfg,
            f"no php_version: the project follows DDEV's default ({defaults['php_version']} today; it moved "
            "from 8.3 to 8.4 in v1.25.0). Pin production's minor, e.g. `php_version: \"8.3\"`.")
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
    if pinned("database") is None and "database" not in local_cfg:
        add("high", "db-unpinned", main_cfg,
            f"no database pinned: this project runs DDEV's default engine ({defaults['database']} today) "
            "whatever production uses, and switching engines later needs a data migration. Pin production's, "
            "e.g. `database: {type: mysql, version: \"8.0\"}`.")

    # Node
    node = pinned("nodejs_version")
    if node is not None:
        f, val = node
        major = node_major(str(val), cat["node_codenames"])
        if major is not None and major < int(cat["eol_floor"]["nodejs"]):
            add("medium", "node-eol", f,
                f"nodejs_version {val!r} is Node {major}, end of life upstream (oldest supported: "
                f"{cat['eol_floor']['nodejs']}). Old build chains often pin it; plan the upgrade.")

    comp = pinned("composer_version")
    if comp is not None and str(comp[1]).strip().startswith("1"):
        add("low", "composer-v1", comp[0], "composer_version 1 is end of life; set `composer_version: \"2\"`.")

    # Keys DDEV no longer reads
    for f, d in committed:
        for key, why in cat["obsolete_keys"].items():
            if not key.startswith("_") and key in d:
                add("medium", "obsolete-key", f, f"{key}: {why} Delete the line.")

    # Per-developer settings committed for the whole team
    for f, d in committed:
        pm = str(d.get("performance_mode", "")).strip()
        if pm and pm != "global":
            add("medium", "perf-mode-committed", f,
                f"performance_mode: {pm} is committed, so it applies to every teammate. Mutagen helps on macOS and "
                "traditional Windows, not on Linux/WSL2; move it to config.local.yaml or `ddev config global`.")
        ports = [k for k in ("router_http_port", "router_https_port") if str(d.get(k, "")).strip()]
        if ports:
            add("medium", "router-ports-committed", f,
                f"{', '.join(ports)} committed: project values override global config, so a teammate with a port "
                "clash cannot fix it with `ddev config global`. Delete them from the project.")
        if str(d.get("xdebug_enabled", "")).strip().lower() == "true":
            add("low", "xdebug-committed", f,
                "xdebug_enabled: true slows every request for everyone; delete it and use `ddev xdebug on` per session.")

    # A committed name: collides when this checkout is a git worktree of a repo whose other
    # checkout runs the same project name (DDEV project names are unique per machine).
    dotgit = project / ".git"
    if dotgit.is_file() and "name" not in local_cfg:
        gitdir = dotgit.read_text(encoding="utf-8", errors="replace")
        named = pinned("name")
        if re.search(r"gitdir:.*[/\\]worktrees[/\\]", gitdir) and named is not None:
            add("medium", "name-in-worktree", named[0],
                f"this checkout is a git worktree but config.yaml pins `name: {named[1]}`, so it collides with the "
                "repository's other checkouts. Set a unique `name:` in .ddev/config.local.yaml, or remove `name:` "
                "from the committed config (DDEV then uses the directory name).")

    # upload_dirs resolve from the DOCROOT (calculateHostUploadDirFullPath joins onto it).
    docroot = str(cfg.get("docroot", "") or "").strip().strip("/")
    base = project / docroot if docroot else project
    uploads = cfg.get("upload_dirs")
    if uploads not in (None, "", []):
        entries = uploads if isinstance(uploads, list) else [str(uploads)]
        srcs = source["upload_dirs"] if isinstance(source["upload_dirs"], list) else [source["upload_dirs"]] * len(entries)
        for entry, f in zip(entries, srcs):
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
                if cmd.name in builtins.get(svc_dir.name, set()) and GENERATED.encode() not in raw:
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
                "included) can sign with every key that agent holds. Delete the file and use "
                "`ddev auth ssh -f <one scoped key>` instead.")

    # Provider recipes that can push. DDEV writes acquia/lagoon/pantheon/platform/upsun.yaml
    # into every project (#ddev-generated, gitignored, push stanzas included): those are
    # DDEV's, regenerated on start and never committed, so only the team's own recipes count.
    prov = ddev / "providers"
    if prov.is_dir():
        for recipe in sorted(prov.glob("*.y*ml")):
            text = recipe.read_text(encoding="utf-8", errors="replace")
            if GENERATED in text:
                continue
            stanzas = [s for s in ("db_push_command", "files_push_command") if re.search(rf"^{s}:", text, re.M)]
            if stanzas:
                add("medium", "provider-push", recipe,
                    f"{' and '.join(stanzas)} present: `ddev push` overwrites the upstream database/files. Remove the "
                    "push stanzas from any recipe that can reach production.")
            # A files_pull_command that fetches nothing still makes DDEV import the (empty)
            # .downloads/files folder, and the import EMPTIES the upload directory first
            # (v1.25.4 provider.go doFilesPullCommand -> doFilesImport -> ImportFiles). With
            # no stanza at all DDEV skips files safely; a files_import_command takes over.
            body = files_pull_body(text)
            if body is not None and not body and not re.search(r"^files_import_command:", text, re.M):
                add("high", "provider-files-noop", recipe,
                    "files_pull_command fetches nothing (e.g. just `true`), so `ddev pull` imports an empty folder and "
                    "empties the project's upload directory. Delete the files_pull_command stanza (DDEV then skips "
                    "files), or make it always fetch a real archive.")

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
                f"to {env.name}.local (gitignored, DDEV v1.25.4+) and commit an {env.name}.example listing the keys "
                "with `git add -f` (DDEV's .ddev/.gitignore ignores *.example).")

    findings.sort(key=lambda x: SEVERITY_RANK.get(x["severity"], 9))  # stable: check order within a severity
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
