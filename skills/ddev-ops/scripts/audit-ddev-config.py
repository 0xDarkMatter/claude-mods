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
(DDEV then empties the upload directory), secrets in committed env files, per-developer
.local files committed to git - come from DDEV's documentation and source. The
files_pull_command case and the untracked .ddev/.gitignore behind the .local-file check
were also reproduced in throwaway projects on DDEV v1.25.4 (2026-10-06).

How DDEV reads config, mirrored here: config.yaml first, then every committed
config.*.yaml / config.*.yml (not *.local.*) in name order. Since v1.25.2 it merges them
with Viper: scalars override, LISTS APPEND unless that file sets `override_config: true`,
and unknown keys are ignored rather than rejected (so retired keys silently do nothing).

Facts (defaults, end-of-life floors, obsolete keys, built-in command names) are read
from assets/ddev-facts.json - the one place they live; check-ddev-facts.py keeps that
file current. Read-only, and it runs no code the audited repository supplies: it never
writes to the project; it runs git by its absolute PATH location, never a git inside the
project or the current directory (find_git); and every git call disables core.fsmonitor,
the setting through which a repository could make git run a command of its choosing.

Round 3 (2026-10-14) adds the routes by which a DDEV project reaches past its containers,
which matter most when an agent drives DDEV: `exec-host` hook tasks and project host
commands run on the developer's machine, not in a container (hooks.md and
custom-commands.md at v1.25.4); a compose mount of the Docker socket or of the home
directory hands the container the host; an agent add-on's login stored under .ddev/ is
readable by every process in web, since the project (.ddev/ included) is mounted there.
committed-secret now also reads committed web_environment, compose `environment:` blocks
and web-server snippets. unknown-key compares top-level keys with DDEV's own config
schema (pkg/ddevapp/schema.json, additionalProperties false; the key list lives in the
catalog), because DDEV ignores a key it doesn't know instead of rejecting it.

The YAML reader is deliberately minimal (stdlib only, so the skill folder runs when
copied alone): top-level `key: value`, block and flow lists of scalars, and one level
of nested map (`database: {type, version}`). That covers .ddev/config.yaml; anything
it cannot read is reported, not guessed. Compose files and web-server snippets are
scanned line by line for the few shapes the checks need (volume sources, environment
entries, docker.sock), never parsed in full.

Usage:   audit-ddev-config.py [PROJECT_DIR] [--json] [--ignore CHECK]... [--catalog FILE] [-q]
Input:   PROJECT_DIR (default "."), which must contain .ddev/config.yaml. No stdin.
Output:  stdout = findings sorted high, medium, low; one per line:
         severity<TAB>check<TAB>file[:line]<TAB>detail (":line" when the finding sits
         on one line; a file-level finding has none), or the --json envelope (schema
         claude-mods.ddev-ops.audit/v1; each finding's `line` is a number or null).
         Data only. Secret values are never printed - only the key name.
Stderr:  the verdict line, notices, errors.
Exit:    0 clean, 2 usage, 3 no .ddev/config.yaml or catalog missing,
         4 config or catalog unreadable, 10 findings reported

Checks:  php-unpinned php-out-of-range php-eol db-unpinned node-eol composer-v1
         obsolete-key unknown-key perf-mode-committed router-ports-committed
         xdebug-committed name-in-worktree upload-dir-misplaced upload-dir-outside
         shadowed-command crlf-command host-command host-hook ssh-agent-forwarded
         docker-socket-mounted home-mounted provider-push provider-files-noop
         committed-secret credential-file local-file-committed

Git is asked by local-file-committed, which runs when PROJECT_DIR is inside a git
checkout (its own .git or a parent's) and is skipped silently outside one, where nothing
can be tracked. Git missing or failing inside a checkout skips it with a notice naming
the reason. --ignore local-file-committed skips that git call. credential-file asks git
only after it has found a file, and only to choose its severity (tracked = high); if git
can't answer, the finding stays medium and says to check.

Examples:
  audit-ddev-config.py                         # audit the project in the current directory
  audit-ddev-config.py ~/sites/shop --json | jq '.data[] | select(.severity=="high")'
  audit-ddev-config.py . --ignore shadowed-command   # a deliberate command override
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

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
    "obsolete-key", "unknown-key", "perf-mode-committed", "router-ports-committed", "xdebug-committed",
    "name-in-worktree", "upload-dir-misplaced", "upload-dir-outside", "shadowed-command",
    "crlf-command", "host-command", "host-hook", "ssh-agent-forwarded", "docker-socket-mounted",
    "home-mounted", "provider-push", "provider-files-noop", "committed-secret", "credential-file",
    "local-file-committed",
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
# Variable references in an env value (see only_references): plain $VAR / ${VAR}, and the
# ${VAR<op>x} forms whose x may be a literal. Single quotes switch interpolation off.
REF_RE = re.compile(r"\$\{[A-Za-z_]\w*\}|\$[A-Za-z_]\w*")
REF_OP_RE = re.compile(r"\$\{[A-Za-z_]\w*(:?[-+?])([^{}$]*)\}")
# Paths a shell takes unquoted; anything else gets no ready-to-paste command.
SAFE_PATH_RE = re.compile(r"^[\w./-]+$")
# A compose file SETTING SSH_AUTH_SOCK to a path other than DDEV's own agent socket. Not a
# `$SSH_AUTH_SOCK:` / `${SSH_AUTH_SOCK}:` bind, which reads the variable but leaves it alone.
REPOINT_RE = re.compile(r"(?<![\w${])SSH_AUTH_SOCK\s*[=:]\s*['\"]?(?!/home/\.ssh-agent)/")
GENERATED = "#ddev-generated"
# A compose volume source under the host user's home: the home itself, or a credential
# store in it. Caches (~/.composer/cache, ~/.npm) are a normal speed-up and not listed.
HOME_SRC_RE = re.compile(r"^(?:~|\$HOME|\$\{HOME\})(?:/(.*))?$")
HOME_CRED_PARTS = (
    ".ssh", ".aws", ".azure", ".config/gcloud", ".kube", ".docker", ".gnupg", ".npmrc", ".netrc",
    ".git-credentials", ".composer/auth.json", ".config/composer/auth.json", ".config/gh",
    ".claude", ".claude.json", ".codex",
)
HOME_CRED_OK = (".ssh/known_hosts",)   # public host keys, the usual reason to mount .ssh
# Folders under .ddev/ that credential-file does not walk: DDEV's own build and download
# output, and snapshots (database dumps, sized in gigabytes, never a credential file).
CRED_WALK_SKIP = frozenset({"db_snapshots", ".downloads", ".webimageBuild", ".dbimageBuild", "traefik"})
# Web-server snippets that can carry a literal credential: nginx `fastcgi_param KEY value;`,
# Apache `SetEnv KEY value`, and an Authorization header set to a literal Basic/Bearer value.
SNIPPET_GLOBS = ("nginx/*.conf", "nginx_full/*.conf", "apache/*.conf")
SNIPPET_PARAM_RE = re.compile(r"^\s*(?:fastcgi_param|SetEnv)\s+([A-Za-z_]\w*)\s+(.+?)\s*;?\s*$")
SNIPPET_AUTH_RE = re.compile(r"Authorization\s+['\"]?(?:Basic|Bearer)\s+[^\s'\";$]", re.I)
# Per-developer files DDEV's generated .ddev/.gitignore lists (pkg/ddevapp/config.go,
# v1.25.4), lower-case for a case-insensitive match. Only directly in .ddev/: that is
# where DDEV reads them from.
LOCAL_PATTERNS = ("config.local.y*ml", "config.*.local.y*ml", ".env.local", ".env.*.local")
# The repository-selection variables `git rev-parse --local-env-vars` lists. An auditor
# started from a git hook inherits GIT_DIR / GIT_INDEX_FILE, which `git -C` does NOT
# override, so they are dropped from the git call's environment.
GIT_LOCAL_ENV = frozenset((
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
    "GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
))


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
        keys = cat.get("config_keys")
        if not isinstance(keys, list) or not keys or not all(isinstance(k, str) and k for k in keys):
            raise ValueError("config_keys must be a non-empty list of key names")
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


def only_references(value: str) -> bool:
    """VALUE is built only from $VAR / ${VAR} references and separators, no literal text.

    ${VAR:-x}, ${VAR-x}, ${VAR:+x} and ${VAR+x} count only when x is harmless (empty, db,
    root) or itself a reference, since x is a literal Compose may hand the container;
    ${VAR:?msg} never supplies a value. Nested defaults unwind from the inside out."""
    v = value
    for _ in range(8):
        nxt = REF_OP_RE.sub(lambda m: "" if m.group(1).endswith("?") or m.group(2) in HARMLESS_VALUES
                            else m.group(0), REF_RE.sub("", v))
        if nxt == v:
            break
        v = nxt
    return v != value and not re.search(r"[A-Za-z0-9$]", v)


def looks_like_credential(key: str, raw_value: str) -> bool:
    """A credential-named key with a literal value: not DDEV's db/root, not only references."""
    if not SECRET_KEY_RE.search(key):
        return False
    raw = raw_value.strip()
    value = _scalar(raw)
    if value in HARMLESS_VALUES:
        return False
    # Single quotes make dotenv and Compose read the value literally - no interpolation.
    return raw.startswith("'") or not only_references(value)


def env_credential_keys(text: str) -> list[str]:
    """Names (never values) of env-file keys holding a credential."""
    keys = []
    for line in text.splitlines():
        m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][\w]*)\s*=\s*(.*)$", line)
        if m and looks_like_credential(m.group(1), m.group(2)):
            keys.append(m.group(1))
    return sorted(set(keys))


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def local_config_facts(text: str, name: str) -> tuple[list[str], bool, bool]:
    """(credential names in web_environment, sets name:, fully read) for a config.*.local file.

    "Fully read" is False when the minimal YAML reader can't take a web_environment entry
    apart (a block scalar, a quoted flow list) or can't parse the file: then a credential
    may hide where this can't see, and the caller says so instead of guessing."""
    try:
        data: dict | None = parse_yaml_subset(text, name)
    except ConfigError:
        data = None
    complete = data is not None and not re.search(r"^web_environment:\s*\[[^\n]*['\"]", text, re.M)
    sets_name = bool(re.search(r"^name:\s*\S", text, re.M))
    env = data.get("web_environment") if data else None
    keys = []
    for item in env if isinstance(env, list) else []:
        if str(item).strip() in ("|", "|-", "|+", ">", ">-", ">+"):
            complete = False
            continue
        key, sep, value = str(item).partition("=")
        if sep and looks_like_credential(key.strip(), value):
            keys.append(key.strip())
    return sorted(set(keys)), sets_name, complete


def first_line(lines: list[str], pattern: str) -> int | None:
    """1-based number of the first line matching PATTERN, or None."""
    rx = re.compile(pattern)
    return next((n for n, ln in enumerate(lines, 1) if rx.search(ln)), None)


def exec_host_tasks(lines: list[str]) -> list[tuple[int, str]]:
    """(line, hook name) of each `- exec-host:` task under a top-level `hooks:` block."""
    out: list[tuple[int, str]] = []
    in_hooks, hook = False, ""
    for n, ln in enumerate(lines, 1):
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if ln[0] not in " \t":
            in_hooks, hook = ln.startswith("hooks:"), ""
            continue
        if not in_hooks:
            continue
        m = re.match(r"^\s+([\w-]+):\s*$", ln)
        if m:
            hook = m.group(1)
        elif re.match(r"^\s+-\s*exec-host:", ln):
            out.append((n, hook or "hooks"))
    return out


def volume_source(item: str) -> str | None:
    """The host side of a compose volume: `source: X` (long form) or `- X:/target` (short).

    ${...} is masked before looking for the colon, so ${VAR:-default} stays whole."""
    m = re.match(r"^source:\s*(.+)$", item)
    if m:
        return _scalar(m.group(1))
    m = re.match(r"^-\s*(.+)$", item)
    if not m:
        return None
    value = _scalar(m.group(1))
    masked = re.sub(r"\$\{[^}]*\}", lambda x: "_" * len(x.group(0)), value)
    cut = masked.find(":")
    return value[:cut] if cut > 0 else None


def scan_compose(lines: list[str]) -> list[tuple[int, str, str, object]]:
    """(line, service, kind, value) for what the checks need from a compose file.

    kind "sock": a line naming docker.sock; "home": a volume source under the home
    directory (value = the source); "env": an `environment:` entry (value = (KEY, value),
    YAML quotes removed - Compose interpolates ${VAR} whatever the YAML quoting).
    Line-based by design (see the module docstring): services are the keys one indent
    under `services:`, and an environment block is every deeper line below the key."""
    out: list[tuple[int, str, str, object]] = []
    top, svc, svc_indent, env_indent = "", "", None, None
    for n, ln in enumerate(lines, 1):
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        code = re.split(r"\s+#", stripped, maxsplit=1)[0]
        if env_indent is not None and indent <= env_indent:
            env_indent = None
        if indent == 0:
            top, svc, svc_indent = code.split(":", 1)[0].strip(), "", None
            continue
        if top == "services":
            svc_indent = indent if svc_indent is None else svc_indent
            m = re.match(r"^['\"]?([\w.-]+)['\"]?:\s*$", code)
            if indent == svc_indent and m:
                svc = m.group(1)
                continue
        if "docker.sock" in code:
            out.append((n, svc, "sock", ""))
        src = volume_source(code)
        if src and HOME_SRC_RE.match(src):
            out.append((n, svc, "home", src))
        if env_indent is not None:
            m = (re.match(r"^-\s*(['\"]?)([A-Za-z_]\w*)=(.*?)\1$", code)
                 or re.match(r"^()['\"]?([A-Za-z_]\w*)['\"]?:\s*(.*)$", code))
            if m:
                out.append((n, svc, "env", (m.group(2), _scalar(m.group(3)) if m.group(3) else "")))
        if re.match(r"^environment:\s*$", code):
            env_indent = indent
    return out


def home_credential(src: str) -> str | None:
    """What a home-directory volume source exposes, or None for a harmless subpath."""
    m = HOME_SRC_RE.match(src)
    rest = (m.group(1) or "").strip("/") if m else None
    if rest is None:
        return None
    if not rest:
        return "your whole home directory"
    if rest in HOME_CRED_OK:
        return None
    part = next((p for p in HOME_CRED_PARTS if rest == p or rest.startswith(p + "/")), None)
    return f"~/{part}" if part else None


def snippet_credentials(lines: list[str]) -> list[tuple[int, str]]:
    """(line, name) of literal credentials in an nginx/Apache snippet: a credential-named
    fastcgi_param/SetEnv with a literal value, or a literal Authorization header."""
    out = []
    for n, ln in enumerate(lines, 1):
        if ln.lstrip().startswith("#"):
            continue
        m = SNIPPET_PARAM_RE.match(ln)
        if m and looks_like_credential(m.group(1), _scalar(m.group(2))):
            out.append((n, m.group(1)))
        elif SNIPPET_AUTH_RE.search(ln):
            out.append((n, "Authorization header"))
    return out


def credential_file_kind(rel_path: PurePosixPath, path: Path) -> str | None:
    """What credential a file under .ddev/ holds, judged by its name and place, or None.

    The places a credential lands under .ddev/: an agent add-on's login (Claude Code keeps
    it in .credentials.json; one add-on stores it at .ddev/claude-code/.claude/, another
    snapshots it to .ddev/.claude/), and homeadditions/, which DDEV copies into the
    container user's home on start."""
    parts = [p.lower() for p in rel_path.parts]
    name, joined = parts[-1], "/".join(parts)
    if name == ".credentials.json":
        return "an AI agent's login"
    if joined.endswith(".aws/credentials"):
        return "AWS credentials"
    if len(parts) > 1 and parts[-2] == ".ssh" and name.startswith("id_") and not name.endswith(".pub"):
        return "an SSH private key"
    if name in (".netrc", ".git-credentials"):
        return "stored passwords for git or HTTP"
    if joined.endswith("composer/auth.json"):
        return "Composer repository tokens"
    if joined.endswith(".config/gh/hosts.yml"):
        return "a GitHub CLI token"
    if name == ".npmrc" and re.search(r"_auth(?:Token)?\s*=", read_text(path) or ""):
        return "an npm registry token"
    return None


def in_git_checkout(project: Path) -> bool:
    """PROJECT or a parent holds .git (dir, or a worktree's/submodule's file)."""
    return any((d / ".git").exists() for d in (project, *project.parents))


def find_git(project: Path) -> str | None:
    """Absolute path of the git on PATH - never one in the current directory or PROJECT.

    A bare "git" lets Windows' CreateProcess try the current directory before PATH (unless
    NoDefaultCurrentDirectoryInExePath is set), so a git.exe committed to the audited
    repository would run: reproduced 2026-10-06 on a stock environment. Only absolute PATH
    entries outside the project count, and on Windows only git.exe (no .bat/.cmd shims,
    whose argument handling cmd.exe rewrites)."""
    names = ("git.exe",) if os.name == "nt" else ("git",)
    try:
        cwd: Path | None = Path.cwd().resolve()
    except OSError:
        cwd = None
    proj = project.resolve()
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        try:
            d = Path(entry).resolve()
        except OSError:
            continue
        if d == cwd or d == proj or proj in d.parents:
            continue
        for n in names:
            cand = d / n
            if cand.is_file() and os.access(str(cand), os.X_OK):
                return str(cand)
    return None


def run_git(git: str, project: Path, *args: str) -> subprocess.CompletedProcess:
    """git ARGS in PROJECT, sealed from what the audited repo or the caller could inject.

    - core.fsmonitor=false: the setting names a command git RUNS while reading the index.
    - GIT_LOCAL_ENV dropped: an inherited GIT_DIR / GIT_INDEX_FILE would aim git at
      another repository, and `-C` does not override them.
    Raises OSError / subprocess.SubprocessError (incl. TimeoutExpired) to the caller."""
    env = {k: v for k, v in os.environ.items() if k not in GIT_LOCAL_ENV}
    return subprocess.run([git, "-c", "core.fsmonitor=false", "-C", str(project), *args],
                          capture_output=True, timeout=30, env=env)


def tracked_paths(project: Path) -> tuple[str | None, set[str] | None, str]:
    """(git, .ddev/ paths git tracks relative to PROJECT and posix-style, reason when None).

    The index, not HEAD: a staged file is already on its way into a commit. Run from
    PROJECT, `ls-files` prints paths relative to it, also for a project in a
    subdirectory of its repository."""
    git = find_git(project)
    if git is None:
        return None, None, "no git on PATH outside the project"
    try:
        res = run_git(git, project, "ls-files", "-z", "--", ".ddev")
    except subprocess.TimeoutExpired:
        return git, None, "git did not answer within 30s"
    except (OSError, subprocess.SubprocessError) as exc:
        return git, None, f"git could not run ({exc})"
    if res.returncode != 0:
        lines = res.stderr.decode("utf-8", errors="replace").strip().splitlines()
        return git, None, lines[0] if lines else f"git exited {res.returncode}"
    # fsdecode keeps an odd byte in a file name round-trippable instead of replacing it.
    return git, {os.fsdecode(p) for p in res.stdout.split(b"\0") if p}, ""


def staged_text(git: str, project: Path, path: str) -> str | None:
    """The index's copy of PATH (relative to PROJECT): what the next commit will contain."""
    try:
        res = run_git(git, project, "cat-file", "blob", f":./{path}")
    except (OSError, subprocess.SubprocessError):
        return None
    return res.stdout.decode("utf-8", errors="replace") if res.returncode == 0 else None


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

def audit(project: Path, cat: dict, skip: frozenset = frozenset(), skipped: list | None = None) -> list[dict]:
    """Findings for PROJECT. SKIP: checks not to run (git is not even called for
    local-file-committed). SKIPPED: filled with {check, reason} for checks that could not run."""
    ddev = project / ".ddev"
    skipped = [] if skipped is None else skipped
    findings: list[dict] = []

    def add(sev: str, check: str, path: Path, detail: str, line: int | None = None) -> None:
        findings.append({"severity": sev, "check": check, "file": rel(path, project), "line": line,
                         "detail": detail})

    line_cache: dict[Path, list[str]] = {}

    def lines_of(p: Path) -> list[str]:
        if p not in line_cache:
            t = read_text(p)
            line_cache[p] = t.splitlines() if t is not None else []
        return line_cache[p]

    def key_line(p: Path, key: str) -> int | None:
        return first_line(lines_of(p), rf"^{re.escape(key)}:")

    def generated(p: Path) -> bool:
        return any(GENERATED in ln for ln in lines_of(p))

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
                f"php_version {val!r} is outside what DDEV ships ({cat['php_range']['min']}-{cat['php_range']['max']}, major.minor only)",
                key_line(f, "php_version"))
        elif floor and pv[:2] < floor:
            add("medium", "php-eol", f,
                f"php_version {val} is end of life upstream (oldest supported line: {cat['eol_floor']['php']}). "
                "Check production runs the same minor and plan the upgrade.", key_line(f, "php_version"))

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
                f"{cat['eol_floor']['nodejs']}). Old build chains often pin it; plan the upgrade.",
                key_line(f, "nodejs_version"))

    comp = pinned("composer_version")
    if comp is not None and str(comp[1]).strip().startswith("1"):
        add("low", "composer-v1", comp[0], "composer_version 1 is end of life; set `composer_version: \"2\"`.",
            key_line(comp[0], "composer_version"))

    # Keys DDEV no longer reads, and keys it never read. Its schema (catalog config_keys)
    # is closed (additionalProperties false), but the loader ignores what it doesn't know,
    # so a typo like `php_verison` silently leaves the default in force.
    obsolete = {k: why for k, why in cat["obsolete_keys"].items() if not k.startswith("_")}
    known = set(cat["config_keys"])
    tag = str(cat.get("release", {}).get("tag", "")) or "the documented release"
    for f, d in committed:
        for key in d:
            if key in obsolete:
                add("medium", "obsolete-key", f, f"{key}: {obsolete[key]} Delete the line.", key_line(f, key))
            elif key not in known:
                add("medium", "unknown-key", f,
                    f"`{key}` is not a key DDEV {tag} reads (its config schema lists {len(known)}), and DDEV ignores "
                    "unknown keys instead of rejecting them, so this line does nothing. Fix the spelling against "
                    "the config docs, or delete it.", key_line(f, key))

    # Per-developer settings committed for the whole team
    for f, d in committed:
        pm = str(d.get("performance_mode", "")).strip()
        if pm and pm != "global":
            add("medium", "perf-mode-committed", f,
                f"performance_mode: {pm} is committed, so it applies to every teammate. Mutagen helps on macOS and "
                "traditional Windows, not on Linux/WSL2; move it to config.local.yaml or `ddev config global`.",
                key_line(f, "performance_mode"))
        ports = [k for k in ("router_http_port", "router_https_port") if str(d.get(k, "")).strip()]
        if ports:
            add("medium", "router-ports-committed", f,
                f"{', '.join(ports)} committed: project values override global config, so a teammate with a port "
                "clash cannot fix it with `ddev config global`. Delete them from the project.", key_line(f, ports[0]))
        if str(d.get("xdebug_enabled", "")).strip().lower() == "true":
            add("low", "xdebug-committed", f,
                "xdebug_enabled: true slows every request for everyone; delete it and use `ddev xdebug on` per session.",
                key_line(f, "xdebug_enabled"))

    # Host execution from config: exec-host hook tasks run on the developer's machine with
    # their user's rights (hooks.md: "Execute a shell command on the host system"), and
    # pre-start ones run before any container exists - so the first `ddev start` of a
    # fresh clone runs them. The developer's own config.local.yaml is their business.
    for f, _ in committed:
        tasks = exec_host_tasks(lines_of(f))
        if tasks:
            hooks = ", ".join(sorted({h for _, h in tasks}))
            add("medium", "host-hook", f,
                f"{len(tasks)} exec-host hook task(s) ({hooks}) run on your machine with your user's rights, not in a "
                "container, whenever those hooks fire; a pre-start one runs on the first `ddev start` of a fresh "
                "clone. Read each before starting a project you didn't write; an agent should report them to the "
                "user rather than start the project.", tasks[0][0])

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
                "from the committed config (DDEV then uses the directory name).", key_line(named[0], "name"))

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
            # the entry's own line in a block list, else the key's line (flow list, scalar)
            at = (first_line(lines_of(f), rf"^\s+-\s*['\"]?{re.escape(entry)}['\"]?\s*(#.*)?$")
                  or key_line(f, "upload_dirs"))
            if not inside(target, project):
                add("high", "upload-dir-outside", f,
                    f"upload_dirs entry {entry!r} resolves outside the project; DDEV requires it inside.", at)
            elif docroot and not target.exists() and (project / entry).exists():
                add("medium", "upload-dir-misplaced", f,
                    f"upload_dirs entry {entry!r} resolves from the docroot to {rel(target, project)}, which does not "
                    f"exist, while {entry}/ exists at the project root. Write it as ../{entry}.", at)

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
                # A project host command is the repository's code running on the developer's
                # machine (custom-commands.md: host commands run "on the host"), so an agent
                # must not treat `ddev <name>` as sandboxed. Add-on copies carry #ddev-generated
                # and were reviewed at install time (Hard rule 9).
                if svc_dir.name == "host" and GENERATED.encode() not in raw:
                    usage = re.search(rb"^## Usage:\s*(\S+)", raw, re.M)  # DDEV names it from Usage
                    name = usage.group(1).decode("utf-8", "replace") if usage else cmd.name
                    add("low", "host-command", cmd,
                        f"`ddev {name}` runs this script on your machine with your user's rights, not in a "
                        "container. Read it before running it, as you would any script from the repository.")

    # Compose overrides that forward the host SSH agent
    for comp_file in sorted(ddev.glob("docker-compose.*.y*ml")):
        text = comp_file.read_text(encoding="utf-8", errors="replace")
        hit = "ssh-auth.sock" in text or re.search(r"\$\{?SSH_AUTH_SOCK", text) or re.search(
            r"SSH_AUTH_SOCK\s*[=:]\s*['\"]?(?!/home/\.ssh-agent)/", text)
        hit_line = first_line(lines_of(comp_file),
                              r"ssh-auth\.sock|\$\{?SSH_AUTH_SOCK|SSH_AUTH_SOCK\s*[=:]\s*['\"]?(?!/home/\.ssh-agent)/")
        if hit:
            # Both outcomes argue for deleting it: a live socket hands out signing, and a
            # dead one still breaks SSH when the file also repoints SSH_AUTH_SOCK (Docker
            # Desktop for Windows mounts an empty root-owned directory there, seen on
            # v1.25.4). A bare `${SSH_AUTH_SOCK}:/path` bind leaves SSH_AUTH_SOCK alone.
            detail = ("forwards the host SSH agent into a container: wherever that socket exists (Docker Desktop on "
                      "macOS and Linux and OrbStack serve /run/host-services/ssh-auth.sock; a ${SSH_AUTH_SOCK} bind "
                      "forwards on native Linux Docker), every process there - Composer and npm scripts included - can "
                      "sign with every key that agent holds.")
            if REPOINT_RE.search(text):
                detail += (" It also repoints SSH_AUTH_SOCK, so where the socket is missing (seen on Docker Desktop "
                           "for Windows) SSH in the container stops using keys loaded with `ddev auth ssh`.")
            add("high", "ssh-agent-forwarded", comp_file,
                detail + " Delete the file and use `ddev auth ssh -f <one scoped key>`.", hit_line)

    # Compose mounts that hand a container the host, and literal credentials in compose
    # environment blocks. Mounts count in every file, add-on ones included: whoever wrote
    # it, the container still holds the host. Credentials count only in the team's own
    # files - an add-on's #ddev-generated compose carries its local-only defaults.
    for comp_file in sorted(ddev.glob("docker-compose.*.y*ml")):
        hits = scan_compose(lines_of(comp_file))
        origin = " (an add-on's file: review the add-on)" if generated(comp_file) else ""
        socks = [(n, s) for n, s, kind, _ in hits if kind == "sock"]
        if socks:
            svcs = ", ".join(sorted({s or "?" for _, s in socks}))
            add("high", "docker-socket-mounted", comp_file,
                f"mounts the Docker socket into {svcs}{origin}: anything running there can start a container that "
                "mounts your machine's filesystem, which is full control of the host. Delete the mount unless the "
                "service exists to manage Docker, and never give it to web.", socks[0][0])
        homes = [(n, s, what) for n, s, kind, v in hits if kind == "home" and (what := home_credential(str(v)))]
        if homes:
            mounts = "; ".join(f"{what} into {s or '?'}" for _, s, what in homes)
            add("high", "home-mounted", comp_file,
                f"mounts {mounts}{origin}: every process in that container - Composer and npm scripts, CMS plugin "
                "code, an agent - can read the credentials there, on every teammate's machine. Delete the mount and "
                "give the container only the one scoped credential it needs (`ddev auth ssh -f <key>` for SSH).",
                homes[0][0])
        if not generated(comp_file):
            creds = [(n, s, v[0]) for n, s, kind, v in hits
                     if kind == "env" and isinstance(v, tuple) and looks_like_credential(v[0], v[1])]
            if creds:
                names = ", ".join(sorted({k for _, _, k in creds}))
                svc = creds[0][1] or "<service>"
                add("high", "committed-secret", comp_file,
                    f"credential-looking value(s) for {names} in a compose `environment:` block, which is committed. If "
                    f"it was ever committed or pushed, rotate them. Move them to .ddev/.env.{svc}.local (DDEV hands "
                    f".ddev/.env.{svc} files to that container; the .local twin stays out of git once the project "
                    "root's .gitignore lists `.ddev/.env*.local`) and delete them here.", creds[0][0])

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
                    "push stanzas from any recipe that can reach production.", key_line(recipe, stanzas[0]))
            # A files_pull_command that fetches nothing still makes DDEV import the (empty)
            # .downloads/files folder, and the import EMPTIES the upload directory first
            # (v1.25.4 provider.go doFilesPullCommand -> doFilesImport -> ImportFiles). With
            # no stanza at all DDEV skips files safely; a files_import_command takes over.
            body = files_pull_body(text)
            if body is not None and not body and not re.search(r"^files_import_command:", text, re.M):
                add("high", "provider-files-noop", recipe,
                    "files_pull_command fetches nothing (e.g. just `true`), so `ddev pull` imports an empty folder and "
                    "empties the project's upload directory. Delete the files_pull_command stanza (DDEV then skips "
                    "files), or make it always fetch a real archive.", key_line(recipe, "files_pull_command"))

    # Credentials in committed env files. The .local twins are skipped here: whether one is
    # in git is local-file-committed's question, answered from the index below.
    for env in sorted(ddev.glob(".env*")):
        if not env.is_file() or env.name.endswith((".local", ".example")):
            continue
        text = read_text(env)
        if text is None:
            print(f"notice: could not read {rel(env, project)}; committed-secret not checked for it", file=sys.stderr)
            skipped.append({"check": "committed-secret", "reason": f"could not read {rel(env, project)}"})
            continue
        keys = env_credential_keys(text)
        if keys:
            # high, like a tracked .local twin: either way the value travels with the repository
            add("high", "committed-secret", env,
                f"credential-looking value(s) for {', '.join(keys)} in an env file meant to be committed. If it "
                f"was ever committed or pushed, rotate them. Move them to {env.name}.local, keep that out of git "
                "(add `.ddev/.env*.local` to the project root's .gitignore: DDEV's own rule exists only once it "
                f"has run in that checkout), and commit an {env.name}.example listing the keys with `git add -f` "
                "(DDEV's .ddev/.gitignore ignores *.example).",
                min(filter(None, (first_line(text.splitlines(), rf"^\s*(?:export\s+)?{re.escape(k)}\s*=")
                                  for k in keys)), default=None))

    # Credentials in committed config: web_environment entries in config.yaml and the
    # team's config.*.yaml (an add-on's #ddev-generated config carries local-only defaults).
    for f, d in committed:
        env_list = d.get("web_environment")
        if generated(f) or not isinstance(env_list, list):
            continue
        names = sorted({k.strip() for k, sep, v in (str(i).partition("=") for i in env_list)
                        if sep and looks_like_credential(k.strip(), v)})
        if names:
            add("high", "committed-secret", f,
                f"credential-looking value(s) for {', '.join(names)} in `web_environment` of a committed config file. "
                "If it was ever committed or pushed, rotate them. Move them to .ddev/.env.web.local (or "
                ".ddev/config.local.yaml), which stay out of git once the project root's .gitignore lists "
                "`.ddev/.env*.local` and `.ddev/config*.local.y*ml`.",
                min(filter(None, (first_line(lines_of(f), rf"\b{re.escape(k)}=") for k in names)), default=None))

    # Credentials in the team's web-server snippets (nginx, nginx_full, apache). DDEV's own
    # generated site config carries #ddev-generated and is skipped.
    for pattern in SNIPPET_GLOBS:
        for snip in sorted(ddev.glob(pattern)):
            if not snip.is_file() or generated(snip):
                continue
            hits = snippet_credentials(lines_of(snip))
            if hits:
                add("high", "committed-secret", snip,
                    f"credential-looking value(s) for {', '.join(sorted({h for _, h in hits}))} written into a "
                    "committed web-server snippet. If it was ever committed or pushed, rotate them. Put the value in "
                    ".ddev/.env.web.local and have the application read it from the environment instead.",
                    hits[0][0])

    # Credential files under .ddev/: an agent add-on's login, or keys and tokens placed in
    # homeadditions/. The project (.ddev/ included) is mounted into web, so every process
    # there can read them. Severity follows git: tracked means the value left the machine.
    cred_files: list[tuple[Path, str]] = []
    if "credential-file" not in skip:
        for root, dirs, files in os.walk(ddev):
            dirs[:] = sorted(x for x in dirs if x not in CRED_WALK_SKIP)
            for name in sorted(files):
                p = Path(root) / name
                what = credential_file_kind(PurePosixPath(rel(p, ddev)), p)
                if what:
                    cred_files.append((p, what))
    if cred_files:
        _, cred_tracked, _ = tracked_paths(project) if in_git_checkout(project) else (None, set(), "")
        for p, what in cred_files:
            path_in_repo = rel(p, project)
            if cred_tracked is not None and path_in_repo in cred_tracked:
                add("high", "credential-file", p,
                    f"holds {what} and git tracks it, so the value travels with the repository: rotate it, then "
                    f"`git rm --cached` it and list it in the project root's .gitignore.")
            else:
                known = "" if cred_tracked is not None else " (git could not say whether it is tracked: check)"
                add("medium", "credential-file", p,
                    f"holds {what}{known}. The project, .ddev/ included, is mounted into the web container, so every "
                    "process there - Composer and npm scripts included - can read it, and a `git add -A` commits it "
                    "unless git ignores it (`git check-ignore -v` on the path says). Keep credentials out of the "
                    "project tree: log the agent in where it runs, and load SSH keys with `ddev auth ssh -f <key>`.")

    # Per-developer files in git. Git ignores them through DDEV's generated .ddev/.gitignore,
    # but that file is untracked itself: a fresh clone or worktree has none until `ddev config`
    # or a successful `ddev start` writes it, so a `git add -A` before then commits them
    # (reproduced on v1.25.4, where a start that failed on a name clash wrote nothing).
    # Tracked, they stop being local: every checkout inherits the overrides, a `name:` among
    # them collides again, and credentials travel with the repository.
    # Walks git's own list, not the disk: that catches case-only renames and files deleted
    # from the working tree but still in the index. Contents come from the index AND the
    # disk: the staged copy is what the next commit carries, whatever the disk now says.
    if "local-file-committed" not in skip and in_git_checkout(project):
        git, tracked, why = tracked_paths(project)
        if tracked is None:
            print(f"notice: local-file-committed not checked: {why}", file=sys.stderr)
            skipped.append({"check": "local-file-committed", "reason": why})
        for path in sorted(tracked or ()):
            pp = PurePosixPath(path)
            if pp.parent != PurePosixPath(".ddev") or not any(
                    fnmatch.fnmatchcase(pp.name.lower(), pat) for pat in LOCAL_PATTERNS):
                continue
            f = project / pp
            texts = [t for t in (staged_text(git, project, path) if git else None, read_text(f)) if t is not None]
            keys: list[str] = []
            sets_name, complete = False, True
            is_env = pp.name.lower().startswith(".env")
            for t in texts:
                if is_env:
                    keys += env_credential_keys(t)
                else:
                    k, named, full = local_config_facts(t, pp.name)
                    keys, sets_name, complete = keys + k, sets_name or named, complete and full
            keys = sorted(set(keys))
            kind = ("a per-developer env file" if is_env
                    else "a per-developer config override, which now applies to every checkout")
            if keys:
                sev, what = "high", (f"holds credential-looking value(s) for {', '.join(keys)}. If it was ever "
                                     "committed or pushed, rotate them.")
            elif not texts:
                sev, what = "medium", "could not be read from git's index or the disk to check it for credentials."
            elif not complete:
                sev, what = "medium", (f"is {kind}, and part of it uses YAML this auditor can't read: check it for "
                                       "credentials by hand.")
            else:
                sev, what = "medium", f"is {kind}."
            if sets_name:
                what += " It sets `name:`, so every checkout claims the same DDEV project."
            remove = (f"run `git rm --cached -- {path}`" if SAFE_PATH_RE.match(path)
                      else "run `git rm --cached` on it (quote the name for your shell)")
            add(sev, "local-file-committed", f,
                f"tracked by git (staged or committed), but it {what} Git ignores it only once DDEV has written "
                f".ddev/.gitignore, which a fresh clone or worktree lacks. From the project directory, {remove}, "
                "and add `.ddev/config*.local.y*ml` and `.ddev/.env*.local` to the project root's .gitignore.")

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
    skipped: list[dict] = []
    findings = [f for f in audit(project, cat, frozenset(args.ignore), skipped) if f["check"] not in args.ignore]

    if args.json:
        # meta.skipped: checks that could not run, so a JSON reader can't mistake them for clean
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings), "schema": SCHEMA,
                                   "facts_as_of": cat.get("as_of", ""), "skipped": skipped}}, indent=2))
    else:
        for f in findings:
            # file:line, as docker-ops' auditor prints it, so an editor or agent can jump there
            where = f"{f['file']}:{f['line']}" if f.get("line") else f["file"]
            print(f"{f['severity']}\t{f['check']}\t{where}\t{f['detail']}")
    if not args.quiet:
        by = {s: sum(1 for f in findings if f["severity"] == s) for s in ("high", "medium", "low")}
        verdict = "FINDINGS" if findings else "CLEAN"
        unchecked = f"; NOT CHECKED: {', '.join(sorted({s['check'] for s in skipped}))}" if skipped else ""
        print(f"audit-ddev-config: {verdict} ({by['high']} high, {by['medium']} medium, {by['low']} low){unchecked}",
              file=sys.stderr)
    return EX_FINDINGS if findings else EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
