#!/usr/bin/env python3
"""Read-only package-manager audit of one repo root: lockfiles, Node/PHP pins, npx use, legacy tools.

Usage:   pm-audit.py [--json] [--no-docs] [--as-of YYYY-MM-DD] [--facts FILE] [--limit N] PATH
Input:   argv only. PATH is a repo root. Root manifests are audited; nested package
         roots are only listed (and flagged when they use another manager, or when CI
         installs in one that has no lockfile). Docs, scripts, CI configs, Dockerfiles
         and appspec hook scripts are read too.
Output:  stdout = one TSV row per finding: severity, id, file[:line], message, fix.
         --json: {"data": [finding...], "meta": {...}} with schema
         claude-mods.package-manager-ops.pm-audit/v1. Data only.
Stderr:  header, notes (informational - never findings), verdict line, errors.
Exit:    0 clean, 2 usage, 3 PATH or facts missing, 4 facts unparseable,
         10 findings (data[] non-empty)

What it checks (finding ids - SKILL.md and references/diagnostics.md explain each):
  js.manifest.invalid  php.manifest.invalid
  js.lockfile.conflict  js.lockfile.missing  js.lockfile.stale  js.lockfile.v1
  js.lockfile.shrinkwrap  js.pnpm.field-ignored
  js.packagemanager.mismatch  js.node.unpinned  js.node.eol  node.pin.disagree
  ddev.node.unpinned  php.require.missing  php.platform.unset
  php.pin.disagree  php.eol  php.lockfile.missing  php.lockfile.stale
  npx.unpinned  npx.native-cli  legacy.bower  legacy.node-sass
  registry.token.committed  registry.authjson.committed  registry.credentials.image
  registry.pnpm.placeholder-ignored
  js.manager.mixed  deploy.install.unfrozen  deploy.composer.dev  php.composer.v1
  deploy.install.unlocked  deploy.npm.yarn-flag  deploy.global.unpinned

It never prints a secret: a committed or CI-written credential is reported as file:line only,
and every finding and note passes through redact() in Audit.add()/Audit.note() - the one
choke point - so credentials inside a quoted command or URL (https://user:token@host) are
masked whatever check quoted them. tests/run.sh greps all output of every fake-secret fixture.

Why one file: the skill folder must run when copied alone into another plugin, launched
through scripts/run-python.sh with nothing on sys.path, so this stays a single stdlib
module (Python 3.8+). Jump by section marker instead of splitting it:
  === version ranges ===   npm semver + Composer constraint intervals (admits())
  === small readers ===    BOM-aware text, JSON/JSONC, a block-mapping YAML subset, markdown
                           code lines, YAML CI commands as the shell gets them, Dockerfile
                           RUN and Jenkinsfile steps, shell words in command position
                           (simple_commands, command_tools, cli_parts, docker_build),
                           GitHub Actions job and step boundaries (workflow_jobs,
                           enclosing_item), CI working directories (join_dir), gitignore /
                           dockerignore matching, read-only git queries (git_says), redact()
  === the audit ===        Audit: js, nested, node_pins, php, npx, deploy (+ the credential
                           image check), legacy, secrets, pnpm_placeholders
  main()                   argv, output envelope, exit codes

Examples:
  bash scripts/run-python.sh scripts/pm-audit.py .
  bash scripts/run-python.sh scripts/pm-audit.py --json path/to/repo | jq -r '.data[].id'
  bash scripts/run-python.sh scripts/pm-audit.py --no-docs --as-of 2026-10-05 path/to/repo
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

EX_OK, EX_USAGE, EX_NOTFOUND, EX_UNPARSEABLE, EX_FINDINGS = 0, 2, 3, 4, 10
SCHEMA = "claude-mods.package-manager-ops.pm-audit/v1"
FACTS_SCHEMA = "claude-mods.package-manager-ops.facts/v1"
DEFAULT_FACTS = Path(__file__).resolve().parent.parent / "assets" / "package-manager-facts.json"

# Lockfile -> manager. Two of these at one root is always a conflict: each manager
# resolves from its own file and ignores the others, so they drift apart silently.
JS_LOCKFILES = {
    "package-lock.json": "npm",
    "npm-shrinkwrap.json": "npm",
    "yarn.lock": "yarn",
    "pnpm-lock.yaml": "pnpm",
    "bun.lock": "bun",
    "bun.lockb": "bun",
    "deno.lock": "deno",
}
DEP_TYPES = ("dependencies", "devDependencies", "optionalDependencies")
# Specs that never appear verbatim as yarn/pnpm lock keys; skip rather than guess.
LOCAL_SPEC = re.compile(r"^(workspace:|file:|link:|portal:|patch:|exec:|git[+:]|github:|https?:)")
COMPOSER_PLATFORM = re.compile(r"^(php(-64bit|-ipv6|-zts|-debug)?|hhvm|ext-.+|lib-.+|composer(-plugin-api|-runtime-api)?)$", re.I)
EXACT_SEMVER = re.compile(r"^v?\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?$")
# A dist-tag spec (`@latest`, `@next`, `@beta`). npm-package-arg calls a spec a tag when it
# is neither a semver version nor a range; approximated here as a leading letter that does
# not open a loose range (`v1`, `x`, `X.2`). npx resolves a tag on the registry every run,
# so a declared local copy never satisfies one either (npx() reports it).
DIST_TAG = re.compile(r"^(?![vV]\d)(?![xX](?:$|\.))[A-Za-z][\w.-]*$")
# Directories never worth walking for npx usage: dependencies, build output, VCS.
SKIP_DIRS = {".git", "node_modules", "vendor", "bower_components", ".yarn", ".pnpm-store",
             "dist", "build", "coverage", ".cache", ".next", ".nuxt", "storage", "cpresources",
             "db_snapshots", ".idea", ".vscode"}
# Dot-directories are skipped except these: CI, git hooks and DDEV commands run npx for
# real, while the rest (.cursor/, .claude/, .gemini/...) are usually vendored copies of
# agent config that would repeat one finding a dozen times.
DOT_DIRS_SCANNED = {".github", ".gitlab", ".circleci", ".buildkite", ".husky", ".ddev", ".devcontainer"}
HOOK_DIRS = {".husky", ".ddev"}
# CI configs: every install there must be frozen, in every job. A GitHub Actions job (any
# other CI file as a whole: see Audit._ship_scope) *ships* (production install, so
# `composer install` needs --no-dev) when it has a deploy marker and runs no tests; a test
# or lint job legitimately installs dev packages. Dockerfiles (not *dev*/*test*) and AWS
# CodeDeploy appspec hook scripts always build or run production.
CI_GLOBS = (".github/workflows/*.yml", ".github/workflows/*.yaml", ".gitlab-ci.yml",
            "bitbucket-pipelines.yml", "azure-pipelines.yml", ".circleci/config.yml",
            "buildspec*.yml", "Jenkinsfile")
# `aws s3 cp|mv` counts only as an upload (local source, s3:// target): a job that fetches
# its .env from S3 with `aws s3 cp s3://... .env` ships nothing.
DEPLOY_MARKERS = re.compile(
    r"docker\s+(?:buildx\s+)?(?:build|push)|aws\s+(?:ecr|deploy|s3\s+sync)|codedeploy|ansible-playbook|"
    r"aws\s+s3\s+(?:cp|mv)\s+(?:-\S+\s+)*[\"']?(?!s3://)[^\s\"'-][^\s\"']*[\"']?\s+(?:-\S+\s+)*[\"']?s3://|"
    r"action-ansible-playbook|ansistrano|\brsync\s|\bscp\s|wrangler\s+deploy|vercel\s+(?:deploy|--prod)|"
    r"netlify\s+deploy|kubectl\s+apply|helm\s+upgrade|(?:serverless|sls)\s+deploy|fly(?:ctl)?\s+deploy|"
    r"\bdep\s+deploy|envoy\s+run", re.I)
TEST_MARKERS = re.compile(r"phpunit|\bpest\b|codecept|artisan\s+test|composer\s+(?:run(?:-script)?\s+)?test\b", re.I)
# An install counts only where the shell runs it: the command word of a simple command
# (command_tools). `echo "npm install"` and `echo npm install` print text; neither installs.
TOOLS = {"npm": "npm", "yarn": "yarn", "pnpm": "pnpm", "bun": "bun", "composer": "composer",
         "composer.phar": "composer"}
# Words that run the command after them unchanged, so the word after them (past their own
# options) is still in command position: privilege and environment wrappers, shell
# keywords, Corepack's shims, `timeout <duration>`. ddev, php, sh -c and docker run/exec
# have their own rules in command_tools().
WRAPPERS = {"sudo", "env", "time", "exec", "command", "nice", "nohup", "corepack", "timeout",
            "if", "then", "else", "elif", "do", "while", "until", "!", "{"}
WRAPPER_VALUE_OPTS = {"sudo": {"-u", "-g", "-C", "-D", "-p", "-r", "-t", "-U"}, "env": {"-u", "-C", "-S"},
                      "nice": {"-n"}, "timeout": {"-s", "-k", "--signal", "--kill-after"}}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Package-manager options that take a separate value, so `npm --prefix client ci` reads
# `ci` as the subcommand, not `client`; and the option that moves the package root
# (npm -C is --prefix, pnpm -C is --dir, composer -d is --working-dir).
CLI_VALUE_OPTS = {
    "npm": {"--prefix", "-C", "--registry", "--cache", "--userconfig", "--globalconfig", "--loglevel",
            "-w", "--workspace", "--tag", "--omit", "--include", "--location", "--install-strategy"},
    "pnpm": {"--dir", "-C", "--filter", "-F", "--registry", "--reporter", "--store-dir", "--loglevel"},
    "yarn": {"--cwd", "--registry", "--cache-folder", "--modules-folder", "--network-timeout", "--mutex"},
    "bun": {"--cwd", "--registry", "--filter", "-c", "--config"},
    "composer": {"--working-dir", "-d"},
}
CLI_DIR_OPTS = {"npm": ("--prefix", "-C"), "pnpm": ("--dir", "-C"), "yarn": ("--cwd",), "bun": ("--cwd",),
                "composer": ("--working-dir", "-d")}
# `docker build` options that take a separate value, so it is not read as the context.
DOCKER_VALUE_OPTS = {"-f", "--file", "-t", "--tag", "--build-arg", "--target", "--platform", "--secret",
                     "--ssh", "--label", "--cache-from", "--cache-to", "--network", "--progress", "-o",
                     "--output", "--iidfile", "--add-host", "--build-context", "--shm-size", "--ulimit",
                     "--metadata-file", "--builder", "--annotation", "--attest", "--allow", "-m", "--memory"}
COMPOSER_V1 = re.compile(r"composer:v1\b|composer\s+self-update\s+--1\b|(?:FROM|--from=)\s*composer:1(?:[.\s]|$)", re.I)
# Group 1 = target path, group 2 = the credential file name.
CRED_WRITE = re.compile(r"(?:>{1,2}|\btee(?:\s+-a)?)\s*[\"']?([^\s\"'<>|;&]*?(auth\.json|\.npmrc))\b")
CRED_CONFIG = re.compile(r"composer\s+config\s+(?!-g\b|--global\b)(?:--\S+\s+)*(?:http-basic|bearer|github-oauth|gitlab-token|gitlab-oauth|bitbucket-oauth)\.")
# A COPY/ADD of the whole build context. Group 1 = its flags: `COPY --from=<stage> . /app`
# copies from another stage's filesystem, never the context (copies_context()).
COPY_CONTEXT = re.compile(r"^\s*(?:ADD|COPY)\s+((?:--\S+\s+)*)\.\/?\s", re.I)
# Credentials a command line can carry, masked by redact() before any finding or note is
# recorded: URL userinfo (scheme://user:pass@host or scheme://token@host; npm-package-arg
# accepts such a tarball URL as a package spec, and --registry takes one), an npm/Yarn auth
# key given a value (`--//host/:_authToken=X`, `npmAuthToken: X`), and token-like query
# parameters. The userinfo class is greedy up to the last @ before the host, so a raw @ in
# a password cannot leave its tail behind.
SECRET_SHAPES = (
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s'\"`]+@"), r"\1***@"),
    (re.compile(r"(?i)(_authToken|_auth|_password|npmAuthToken|npmAuthIdent)(\s*[=:]\s*)[^\s'\"`&;]+"), r"\1\2***"),
    (re.compile(r"(?i)([?&](?:access_token|token|auth|key|secret|password|sig|signature)=)[^&\s'\"`#]+"), r"\1***"),
)
# Nested lockfiles below these are test data or someone else's tree, not package roots.
NESTED_SKIP = {"fixtures", "__fixtures__", "test-fixtures"}
# CMS plugin trees put widget packages 8+ levels down (src/plugins/x/src/templates/...).
NESTED_MAX_DEPTH = 10
# In YAML CI configs only these keys hold commands the runner executes; anything else
# (a release `body:`, an `env:` value) is text, even when it quotes a command.
YAML_COMMAND_KEY = re.compile(r"^(\s*)(?:-\s+)?(run|script|before_script|after_script|commands|command)\s*:\s*(.*)$")
# Lockfile maintenance, not an install: refreshing the lock is the point of these.
LOCK_ONLY = ("--package-lock-only", "--lockfile-only", "--mode=update-lockfile", "--lock")
# Yarn's freeze flags. npm has no such option, so what happens is npm's unknown-flag rule,
# read in npm/cli's config loader at each tag: v11.1.0 has no unknown-config check (the
# flag is dropped silently); v11.2.0 added checkUnknown, which warns `Unknown cli config
# "--frozen-lockfile". This will stop working in the next major version of npm.` and runs
# on; v12 (BaseCommand.validateCli) throws EUNKNOWNCONFIG before the command runs
# (npm/cli#9276; #9729 later relaxed only unknown .npmrc keys). npm 12 is `latest` since
# 2026-07-08, so on npm ci or npm install this is a failed build, hence an error.
YARN_FREEZE_FLAGS = ("--frozen-lockfile", "--immutable")
NPM_INSTALL = ("install", "i", "in", "add")
NPM_CI = ("ci", "clean-install", "ic", "install-clean")  # npm ci and its documented aliases
# `npm install -g` options that take a value, so the value is not read as a package.
GLOBAL_FLAG_WITH_VALUE = {"--prefix", "-C", "--registry", "--cache", "--userconfig", "--tag", "--loglevel"}
# A registry package as typed on a command line: name or @scope/name, optional @version.
# The version may not hold '/', ':' or '@': `name@https://user:token@host/x.tgz`, `name@git+...`,
# `name@file:..` and `name@npm:alias` are not registry ranges, and splitting one at an '@'
# put part of a URL's credentials into the fix text (split_spec()).
PKG_SPEC = re.compile(r"^(@[a-z0-9][\w.-]*/)?[a-z0-9][\w.-]*(@[^\s/:@]+)?$", re.I)
# Bins whose name differs from the package that ships them, each the package's own
# package.json "bin" keys. Only the fallback: npx runs a local bin before it fetches
# anything (libnpmexec checks node_modules/.bin first), and the npm lockfile's
# packages[...].bin, Yarn 2+'s yarn.lock `bin:` and node_modules/<pkg>/package.json say
# which package owns a bin authoritatively (Audit._local_bins). pnpm and Yarn 1 locks
# record no bin names, and an audit clone has no node_modules/, hence this table.
BIN_ALIASES = {
    "typescript": ("tsc", "tsserver"), "laravel-mix": ("mix",), "@playwright/test": ("playwright",),
    "@commitlint/cli": ("commitlint",), "@angular/cli": ("ng",), "@vue/cli-service": ("vue-cli-service",),
    "npm-run-all": ("npm-run-all", "run-s", "run-p"), "@biomejs/biome": ("biome",),
    "@tailwindcss/cli": ("tailwindcss",), "postcss-cli": ("postcss",), "@babel/cli": ("babel",),
    "@11ty/eleventy": ("eleventy",), "@lhci/cli": ("lhci",), "concurrently": ("concurrently", "conc"),
    "grunt-cli": ("grunt",), "gulp-cli": ("gulp",),
}
# CI working directories: `${{ env.X }}` is resolved from the workflow/job env: block;
# GitHub's workspace (`${{ github.workspace }}`, $GITHUB_WORKSPACE) is the checkout root.
ENV_REF = re.compile(r"\$\{\{\s*env\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
WORKSPACE_ROOT = re.compile(r"^(?:\$\{\{\s*github\.workspace\s*\}\}|\$\{?GITHUB_WORKSPACE\}?)(?:/|$)")
DOC_SUFFIXES = {".md", ".markdown", ".sh", ".bash", ".ps1", ".yml", ".yaml", ".mk"}
DOC_NAMES = {"makefile", "justfile", "dockerfile", "procfile"}
MAX_DOC_BYTES = 512 * 1024
# npx-family launchers. Group 1 = launcher, group 2 = the rest of the command line.
# In markdown only code (fenced blocks, inline `spans`) is scanned, so prose such as
# "npx is handy" is never read as a command.
LAUNCHER = re.compile(r"(?:^|[\s;&|(`'\"$])(npx|pnpx|pnx|bunx|bun\s+x|pnpm\s+dlx|yarn\s+dlx|npm\s+exec)\s+([^\n;&|`]*)")
FLAG_WITH_VALUE = {"-p", "--package", "-c", "--call", "-w", "--workspace", "--cache", "--userconfig"}


# =============================================================================
# === version ranges (npm semver + Composer constraints) ===
# Just enough to answer "does this range admit some version inside [lo, hi)?".
# Versions are (major, minor, patch) tuples; every comparator becomes a half-open
# interval [lo, hi). Unknown syntax returns None so callers skip rather than accuse.
# npm grammar: https://github.com/npm/node-semver#ranges
# Composer grammar: https://getcomposer.org/doc/articles/versions.md, as implemented in
# composer/semver src/VersionParser.php (parseConstraint). The dialect differences:
#   ~1.2      Composer >=1.2 <2.0; npm >=1.2.0 <1.3.0.
#   >8.2      Composer pads a partial version for every plain comparator (normalize() ->
#   <=8.2     8.2.0.0), so >8.2 is >8.2.0 (admits 8.2.1) and <=8.2 is <=8.2.0; npm reads
#   8.2       an X-range (>8.2 is >=8.3.0). A bare 8.2 is exactly 8.2.0 in Composer
#             (its X-range regex needs a literal .* or .x), any 8.2.x in npm.
#   !=, <>    Composer only: every version but one. npm has no such comparator (None).
# =============================================================================
INF = (10**9, 0, 0)
PARTIAL = re.compile(r"^v?(\d+|[xX*])(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?(?:[-+][0-9A-Za-z.+-]*)?$")
WILDCARD = re.compile(r"(?:^v?|\.)[xX*](?:\.|$|[-+])")


def _partial(s: str):
    """'8.2' -> ([8, 2], 2 given parts); wildcard parts end the partial."""
    m = PARTIAL.match(s.strip())
    if not m:
        return None
    parts = []
    for g in m.groups():
        if g is None or g in ("x", "X", "*"):
            break
        parts.append(int(g))
    return parts


def _floor(parts):
    return tuple(parts + [0] * (3 - len(parts)))


def _bump(parts):
    """Smallest version above every version matching the partial: 8 -> 9.0.0, 8.2 -> 8.3.0."""
    if not parts:
        return INF
    p = list(parts)
    p[-1] += 1
    return _floor(p)


def _comparator(tok: str, dialect: str):
    """One comparator -> the list of (lo, hi) intervals whose union it admits (two for an
    exclusion), or None when unparseable."""
    m = re.match(r"^(>=|<=|<>|>|<|==|=|\^|~>|~|!=)?\s*(.+)$", tok)
    if not m:
        return None
    op, ver = m.group(1) or "", m.group(2)
    ver = ver.split("@")[0]  # Composer stability flag: ^8.2@dev
    parts = _partial(ver)
    if parts is None:
        return None
    if dialect == "composer" and op in ("", "=", "==", ">", ">=", "<", "<=", "!=", "<>") and not WILDCARD.search(ver):
        v = _floor(parts)
        nxt = (v[0], v[1], v[2] + 1)  # the next version: pins are x.y.z, a 4th part never matters
        return {"": [(v, nxt)], "=": [(v, nxt)], "==": [(v, nxt)], ">": [(nxt, INF)], ">=": [(v, INF)],
                "<": [((0, 0, 0), v)], "<=": [((0, 0, 0), nxt)],
                "!=": [((0, 0, 0), v), (nxt, INF)], "<>": [((0, 0, 0), v), (nxt, INF)]}[op]
    if op in ("!=", "<>"):
        return None  # npm has no exclusion; a Composer wildcard exclusion (!=8.2.*) is not modelled
    full = len(parts) == 3
    if op in ("", "=", "=="):
        return [(_floor(parts), _bump(parts) if not full else (parts[0], parts[1], parts[2] + 1)) if parts else ((0, 0, 0), INF)]
    if op == ">=":
        return [(_floor(parts), INF)]
    if op == ">":
        return [(_bump(parts) if not full else (parts[0], parts[1], parts[2] + 1), INF)]
    if op == "<":
        return [((0, 0, 0), _floor(parts))]
    if op == "<=":
        return [((0, 0, 0), _bump(parts) if not full else (parts[0], parts[1], parts[2] + 1))]
    if op == "^":
        if not parts:
            return [((0, 0, 0), INF)]
        lo = _floor(parts)
        nz = next((i for i, v in enumerate(parts) if v != 0), None)
        if nz is None:  # ^0, ^0.0, ^0.0.0
            return [(lo, _bump(parts))]
        return [(lo, _bump(parts[: nz + 1]))]
    if op in ("~", "~>"):
        if not parts:
            return [((0, 0, 0), INF)]
        lo = _floor(parts)
        if dialect == "composer" and len(parts) == 2:
            return [(lo, _bump(parts[:1]))]  # ~8.2 -> <9.0.0
        return [(lo, _bump(parts[:2]) if len(parts) >= 2 else _bump(parts[:1]))]
    return None


def parse_range(spec: str, dialect: str = "npm"):
    """Range string -> list of AND-sets, each a list of (lo, hi) intervals. None if unparseable.
    An exclusion (Composer !=) admits two intervals, so its AND-set splits in two."""
    if spec is None:
        return None
    spec = str(spec).strip()
    if spec in ("", "*", "x", "latest"):
        return [[((0, 0, 0), INF)]]
    alts = re.split(r"\s*\|\|?\s*", spec) if dialect == "composer" else re.split(r"\s*\|\|\s*", spec)
    out = []
    for alt in alts:
        alt = alt.strip()
        hyph = re.match(r"^(\S+)\s+-\s+(\S+)$", alt)
        if hyph:
            a, b = _partial(hyph.group(1)), _partial(hyph.group(2))
            if a is None or b is None:
                return None
            hi = (b[0], b[1], b[2] + 1) if len(b) == 3 else _bump(b)
            out.append([(_floor(a), hi)])
            continue
        alt = re.sub(r"(>=|<=|<>|>|<|==|=|\^|~>|~|!=)\s+", r"\1", alt)  # ">= 8.2" -> ">=8.2"
        toks = [t for t in re.split(r"[\s,]+", alt) if t]
        if not toks:
            out.append([((0, 0, 0), INF)])
            continue
        sets: list = [[]]
        for t in toks:
            ivs = _comparator(t, dialect)
            if ivs is None:
                return None
            sets = [s + [iv] for s in sets for iv in ivs]
        out.extend(sets)
    return out


def admits(spec: str, lo, hi, dialect: str = "npm"):
    """True/False: does the range admit any version in [lo, hi)? None if unparseable."""
    sets = parse_range(spec, dialect)
    if sets is None:
        return None
    for ivs in sets:
        a = max([lo] + [iv[0] for iv in ivs])
        b = min([hi] + [iv[1] for iv in ivs])
        if a < b:
            return True
    return False


# =============================================================================
# === small readers ===
# =============================================================================
def read_text(p: Path) -> str | None:
    """A file's text, honouring a BOM: UTF-16 when one says so (Windows PowerShell 5.1
    writes .ps1 files that way), else UTF-8 with any UTF-8 BOM dropped (npm and Composer
    both accept a BOM'd manifest, and json.loads rejects one). Undecodable bytes become
    U+FFFD rather than an error."""
    try:
        raw = p.read_bytes()
    except OSError:
        return None
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def obj(v) -> dict:
    """v when it is a JSON object, else {}: a valid manifest can still hold a list or a
    string where a map belongs (`"dependencies": ["eslint"]`), and .get/.items on it would
    end the audit with a traceback."""
    return v if isinstance(v, dict) else {}


def read_json(p: Path):
    t = read_text(p)
    if t is None:
        return None
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        return None


def read_jsonc(p: Path):
    """bun.lock is JSON with trailing commas."""
    t = read_text(p)
    if t is None:
        return None
    try:
        return json.loads(re.sub(r",(\s*[}\]])", r"\1", t))
    except json.JSONDecodeError:
        return None


def mini_yaml(text: str) -> dict:
    """Block-mapping subset of YAML: nested `key: value` by indentation. Sequences and
    flow collections are kept as raw strings. Enough for pnpm-lock importers and
    .ddev/config.yaml scalars; not a general parser."""
    root: dict = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith(("#", "- ")) or raw.strip() == "-":
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        m = re.match(r"^\s*('[^']*'|\"[^\"]*\"|[^:#][^:]*?)\s*:(?:\s+(.*))?$", raw)
        if not m:
            continue
        key = m.group(1).strip().strip("'\"")
        val = (m.group(2) or "").strip()
        nested = val == "" or val.startswith("#")  # `key:` alone opens a block; `key: ""` is a value
        if val and not val.startswith(("{", "[")):
            val = re.sub(r"\s+#.*$", "", val).strip().strip("'\"")
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1] if stack else root
        if nested:
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = val
    return root


def code_lines(text: str, markdown: bool):
    """Yield (line_no, text) worth scanning: every non-comment line of a script or YAML
    file (a `#` comment is prose), but only fenced code and inline code spans of a
    markdown file."""
    fence = None
    for n, line in enumerate(text.splitlines(), 1):
        if not markdown:
            if not line.lstrip().startswith("#"):
                yield n, line
            continue
        s = line.lstrip()
        if fence is None and s.startswith(("```", "~~~")):
            fence = s[:3]
            continue
        if fence is not None:
            if s.startswith(fence):
                fence = None
            elif not s.startswith("#"):
                yield n, line
            continue
        spans = re.findall(r"`([^`]+)`", line)
        if spans:
            yield n, " ; ".join(spans)


def _join_continued(rows):
    """[(line_no, text)] -> the same with backslash-newline continuations joined onto the
    line that starts them (the shell and Docker both join them before running anything).
    Blank and `#` comment lines are dropped; Docker drops comment lines inside a RUN
    continuation too."""
    out, buf, start = [], None, 0
    for n, s in rows:
        if not s.strip() or s.lstrip().startswith("#"):
            continue
        buf, start = (s.strip(), n) if buf is None else (buf + " " + s.strip(), start)
        if buf.endswith("\\"):
            buf = buf[:-1].rstrip()
            continue
        out.append((start, buf))
        buf = None
    if buf is not None:
        out.append((start, buf))
    return out


def _block_scalar(style: str, rows):
    """The lines of a YAML block scalar -> [(line_no, command)]: a literal block (|) is one
    shell script, read line by line with continuations joined; a folded block (>, >-)
    joins its lines with spaces, a blank line ending one command."""
    if style == "|":
        return _join_continued(rows)
    out, buf, start = [], [], 0
    for n, s in rows + [(0, "")]:
        if not s.strip():
            if buf:
                out.append((start, " ".join(buf)))
            buf = []
            continue
        if not buf:
            start = n
        buf.append(s.strip())
    return out


def _scalar_value(first: list, rows: list):
    """An inline YAML scalar plus any deeper lines it continues on -> [(line_no, text)].
    A block indicator (| or >) hands the rows to _block_scalar; a plain or quoted scalar
    folds its lines with spaces, as YAML does, then loses its quotes."""
    v = first[0][1].strip() if first else ""
    if v[:1] in ("|", ">"):
        return _block_scalar(v[0], rows)
    parts = [(n, s.strip()) for n, s in first + rows if s.strip() and not s.lstrip().startswith("#")]
    return [(parts[0][0], scalar(" ".join(s for _, s in parts)))] if parts else []


def yaml_command_lines(text: str):
    """Yield (line_no, command, key_line_no) from a YAML CI config, each command as the shell
    receives it: an inline value unquoted (`run: "npm ci"`), a folded (`>-`) or multi-line
    plain scalar joined into one line, a literal block (`|`) line by line with backslash
    continuations joined, and each item of a sequence (a `script:` list, its items quoted,
    folded or literal in turn). key_line_no is the command key's own line. Every command
    under one key runs in one shell (a `run: |` block on GitHub; GitLab and Bitbucket run a
    `script:` list as one shell script), so a `cd` carries to the lines after it within the
    key. Comments are skipped.

    A key's block is every line deeper than the key's own column, plus a sequence written at
    the key's column (`script:` followed by `- npm ci`, which YAML allows)."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = None if line.lstrip().startswith("#") else YAML_COMMAND_KEY.match(line)
        i += 1
        if not m:
            continue
        key_n, col, value = i, m.start(2), m.group(3)
        rows = []
        while i < len(lines):
            s = lines[i]
            if s.strip() and indent_of(s) <= col and not (
                    not value.strip() and indent_of(s) == col and s.lstrip().startswith("-")):
                break
            rows.append((i + 1, s))
            i += 1
        if value.strip():
            for n, cmd in _scalar_value([(key_n, value)], rows):
                yield n, cmd, key_n
            continue
        head = next((s for _, s in rows if s.strip() and not s.lstrip().startswith("#")), "")
        if re.match(r"^\s*[A-Za-z_][\w-]*\s*:(?:\s|$)", head):
            i = key_n  # a mapping, not a script (CircleCI `- run:` / `command: npm ci`): read its keys
            continue
        items, item_col = [], None
        for n, s in rows:
            if s.strip() and not s.lstrip().startswith("#") and item_col is None:
                item_col = indent_of(s) if s.lstrip().startswith("-") else -1
            if item_col == -1:  # not a sequence: a plain scalar on the following lines
                items = [[[], rows]]
                break
            if s.strip() and indent_of(s) == item_col and s.lstrip().startswith("-"):
                items.append([[(n, s.lstrip()[1:])], []])
            elif items:
                items[-1][1].append((n, s))
        for first, rest in items:
            for n, cmd in _scalar_value([(fn, fs) for fn, fs in first if fs.strip()], rest):
                yield n, cmd, key_n


def dockerfile_commands(text: str):
    """A Dockerfile's RUN instructions -> [(line_no, shell command)], as Docker runs them:
    continuations joined (comment lines inside one dropped), RUN's own flags (--mount=...,
    --network=...) removed, the exec form RUN ["composer", "install"] read as its words, and
    a BuildKit heredoc body (RUN <<EOF ... EOF) read line by line. Other instructions
    (FROM, COPY, CMD) install nothing at build time."""
    lines = text.splitlines()
    out, i = [], 0
    while i < len(lines):
        n, line = i + 1, lines[i]
        i += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        while line.rstrip().endswith("\\") and i < len(lines):
            nxt = lines[i]
            i += 1
            if not nxt.lstrip().startswith("#"):
                line = line.rstrip()[:-1] + " " + nxt.strip()
        m = re.match(r"^\s*(?:ONBUILD\s+)?RUN\s+(.*)$", line, re.I)
        if not m:
            continue
        body = re.sub(r"^(?:--\S+\s+)*", "", m.group(1).strip())
        doc = re.search(r"<<-?\s*[\"']?(\w+)[\"']?", body)
        if doc:
            end = doc.group(1)
            rows = []
            while i < len(lines) and lines[i].strip() != end:
                rows.append((i + 1, lines[i]))
                i += 1
            i += 1  # the closing delimiter
            out += _join_continued(rows)
            body = body[:doc.start()]
        elif body.startswith("["):
            try:
                words = json.loads(body)
                body = " ".join(shlex.quote(str(w)) for w in words) if isinstance(words, list) else body
            except json.JSONDecodeError:
                pass
        if body.strip():
            out.append((n, body))
    return out


def jenkins_commands(text: str):
    """A Jenkinsfile's `sh` / `bat` / `powershell` steps -> [(line_no, command)]: the string
    each runs, single- or double-quoted on one line, or a triple-quoted script read line by
    line. The Groovy around them is not a shell."""
    step = re.compile(r"\b(?:sh|bat|powershell|pwsh)\s*\(?\s*(?:script\s*:\s*)?('''|\"\"\"|'|\")")
    lines = text.splitlines()
    out, i = [], 0
    while i < len(lines):
        n, line = i + 1, lines[i]
        i += 1
        m = step.search(line)
        if not m:
            continue
        q, rest = m.group(1), line[m.end():]
        end = rest.find(q)
        if len(q) == 1 or end >= 0:
            out.append((n, rest[:end] if end >= 0 else rest))
            continue
        rows = [(n, rest)]
        while i < len(lines):
            s = lines[i]
            i += 1
            k = s.find(q)
            rows.append((i, s[:k] if k >= 0 else s))
            if k >= 0:
                break
        out += _join_continued(rows)
    return out


def _shell_tokens(line: str):
    """A shell line -> its words and operators (&&, ||, ;, |, &, (, ), redirections), quotes
    removed the way the shell removes them. GitHub `${{ expr }}` is first closed up into one
    word so a `cd ${{ env.DIR }}` stays two words. Unbalanced quotes (a line cut out of a
    longer script) fall back to a plain split."""
    line = re.sub(r"\$\{\{\s*(.*?)\s*\}\}", lambda m: "${{" + re.sub(r"\s+", "", m.group(1)) + "}}", line)
    lex = shlex.shlex(line, posix=True, punctuation_chars=True)
    lex.whitespace_split = True  # only whitespace and ();<>|& split words (Python 3.8+)
    try:
        return list(lex)
    except ValueError:
        return re.findall(r"&&|\|\||[;&|()]|[^\s;&|()]+", line)


def simple_commands(line: str):
    """A shell line -> its simple commands as word lists, in order. A subshell's ( and ) come
    back as one-word lists so the caller can undo a `cd` made inside it. Redirections and
    their targets are dropped (with a bare fd number before them: 2>&1)."""
    out, cur, toks, i = [], [], _shell_tokens(line), 0
    while i < len(toks):
        t = toks[i]
        i += 1
        if t in ("(", ")"):
            if cur:
                out.append(cur)
            out.append([t])
            cur = []
        elif t and set(t) <= set("<>&|") and ("<" in t or ">" in t):
            if cur and cur[-1].isdigit():
                cur.pop()
            i += 1  # the redirection's target
        elif t and set(t) <= set(";&|"):
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    return out


def command_tools(words):
    """One simple command -> [(tool, args)] for each package-manager run it makes, with the
    tool normalised (composer.phar -> composer). The tool must be in command position: the
    first word after variable assignments and transparent wrappers (WRAPPERS, past their own
    options), `ddev [exec]`, `php [-d k=v] composer.phar`, the command inside
    `docker run|exec` / `docker compose run|exec`, or a script given to `sh -c` (read
    recursively). Anything else that merely mentions npm is text, not an install."""
    i = 0
    while i < len(words):
        w = words[i]
        base = posixpath.basename(w).lower()
        if ASSIGNMENT.match(w):
            i += 1
        elif base in WRAPPERS:
            i += 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in WRAPPER_VALUE_OPTS.get(base, ()) else 1
            if base == "timeout" and i < len(words):
                i += 1  # the duration
        elif base == "ddev":
            i += 1
            if i < len(words) and words[i] in ("exec", "."):
                i += 1
                while i < len(words) and words[i].startswith("-"):
                    i += 2 if words[i] in ("-s", "--service", "-d", "--dir") else 1
        elif base in ("sh", "bash", "zsh", "dash"):
            j = next((j for j in range(i + 1, len(words) - 1) if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", words[j])), None)
            return [] if j is None else [t for cmd in simple_commands(words[j + 1]) for t in command_tools(cmd)]
        elif base in ("docker", "podman", "docker-compose") and any(x in ("run", "exec") for x in words[i + 1:]):
            j = next(k for k in range(i + 1, len(words)) if words[k] in ("run", "exec"))
            k = next((k for k in range(j + 1, len(words)) if posixpath.basename(words[k]).lower() in TOOLS), None)
            return [] if k is None else command_tools(words[k:])
        elif base == "php":
            i += 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-d", "-c") else 1
            if i < len(words) and posixpath.basename(words[i]).lower() in TOOLS:
                return [("composer", words[i + 1:])]
            return []
        elif base in TOOLS:
            return [(TOOLS[base], words[i + 1:])]
        else:
            return []
    return []


def cli_parts(tool: str, toks):
    """A package manager's arguments -> (subcommand, its index or None, the value of the
    option that moves the package root or None). Options are skipped wherever they sit, so
    `npm --silent install` is an install and `npm --prefix client ci` runs in client/."""
    vals, dirs = CLI_VALUE_OPTS.get(tool, set()), CLI_DIR_OPTS.get(tool, ())
    sub, idx, where, i = "", None, None, 0
    while i < len(toks):
        t = toks[i]
        name, eq, val = t.partition("=")
        if t.startswith("-") and t != "-":
            if name in dirs:
                where = val if eq else (toks[i + 1] if i + 1 < len(toks) else None)
            i += 2 if (name in vals and not eq) else 1
            continue
        if idx is None:
            sub, idx = t, i
        i += 1
    return sub, idx, where


def docker_build(words):
    """`docker build` / `docker buildx build` / `docker image build` words -> (context,
    dockerfile or None), or None when this is not a build or its context is not a local
    path (stdin `-`, a git or https URL). Docker reads -f relative to the current directory
    and defaults it to <context>/Dockerfile."""
    i = 0
    while i < len(words) and (ASSIGNMENT.match(words[i]) or words[i] in ("sudo", "time")):
        i += 1
    if i >= len(words) or posixpath.basename(words[i]).lower() not in ("docker", "podman"):
        return None
    rest = words[i + 1:]
    if rest[:1] == ["build"]:
        args = rest[1:]
    elif rest[:2] in (["buildx", "build"], ["image", "build"], ["builder", "build"]):
        args = rest[2:]
    else:
        return None
    ctx, dfile, j = None, None, 0
    while j < len(args):
        a = args[j]
        name, eq, val = a.partition("=")
        if a.startswith("-") and a != "-":
            if name in ("-f", "--file"):
                dfile = val if eq else (args[j + 1] if j + 1 < len(args) else None)
            j += 2 if (name in DOCKER_VALUE_OPTS and not eq) else 1
            continue
        if ctx is None:
            ctx = a
        j += 1
    if ctx is None or ctx == "-" or "://" in ctx or ctx.startswith("git@"):
        return None
    return ctx, dfile


def workflow_jobs(text: str):
    """GitHub Actions workflow -> [(first_line, last_line)], 1-based and inclusive, one per
    child of the top-level `jobs:` key. The job indent is read from the first child, not
    assumed: 2-space and 4-space workflows are both common. A block scalar's lines are
    always deeper than the key that owns them, so indentation alone finds every boundary.
    None when there is no block-style `jobs:` (the caller then judges the whole file)."""
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(r"^jobs\s*:\s*(?:#.*)?$", l)), None)
    if start is None:
        return None
    jobs: list = []
    indent = None
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        depth = len(line) - len(line.lstrip(" "))
        if depth == 0:
            break  # the next top-level key closes `jobs:`
        if indent is None:
            indent = depth
        if depth <= indent:
            jobs.append([i + 1, i + 1])
        elif jobs:
            jobs[-1][1] = i + 1
    return [tuple(j) for j in jobs] or None


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def scalar(v: str) -> str:
    """A YAML plain or quoted scalar as text: outer quotes and a trailing comment dropped.
    A quoted scalar ends at its closing quote (a '#' inside it is text); '' inside single
    quotes and \\" or \\\\ inside double quotes are unescaped."""
    v = v.strip()
    m = re.match(r"'((?:[^']|'')*)'", v) if v[:1] == "'" else re.match(r'"((?:[^"\\]|\\.)*)"', v) if v[:1] == '"' else None
    if m:
        return m.group(1).replace("''", "'") if v[0] == "'" else re.sub(r'\\(["\\/])', r"\1", m.group(1))
    return re.sub(r"(?:^|\s+)#.*$", "", v).strip()


def enclosing_item(lines, k):
    """0-based line k of a YAML file -> (first, last, key_col) of the innermost sequence
    item (`- key: ...`, a GitHub Actions step) holding it, 0-based and inclusive; key_col
    is the column of the item's own keys. None when no item holds the line. Indentation
    alone decides: a parent key (`with:`) is shallower than its children, and the item's
    dash is shallower than every key of the item."""
    col = indent_of(lines[k])
    start = k if lines[k].lstrip().startswith("- ") else None
    i = k
    while start is None:
        i -= 1
        if i < 0:
            return None
        s = lines[i]
        if not s.strip() or s.lstrip().startswith("#") or indent_of(s) >= col:
            continue
        if s.lstrip().startswith("- "):
            start = i
        else:
            col = indent_of(s)  # a parent mapping key: keep climbing
    key_col = len(lines[start]) - len(lines[start].lstrip()[1:].lstrip())  # first char after "- "
    end = start
    for j in range(start + 1, len(lines)):
        s = lines[j]
        if s.strip() and not s.lstrip().startswith("#"):
            if indent_of(s) < key_col:
                break
            end = j
    return start, end, key_col


def item_value(lines, item, key):
    """The scalar of the item's first `key:` line, or None. Asked only for step keys
    (`uses`, `working-directory`) that never also appear nested inside a step."""
    first, last, _ = item
    for j in range(first, last + 1):
        m = re.match(r"^(?:\s*-\s+|\s*)" + re.escape(key) + r"\s*:\s*(.*)$", lines[j])
        if m:
            return scalar(m.group(1))
    return None


def dig(d, *keys):
    """d[k1][k2]... when every step is a mapping and the end is a string, else None."""
    for k in keys:
        d = d.get(k) if isinstance(d, dict) else None
    return d if isinstance(d, str) else None


def join_dir(base, target, env):
    """A CI working directory or `cd` target, resolved against base (repo-relative, "" =
    the root) -> repo-relative path, or None when it cannot be known without running CI:
    an unknown base, an unset `${{ env.X }}`, any other variable or expression, an
    absolute path, or a path that leaves the repo."""
    if base is None:
        return None
    t = ENV_REF.sub(lambda m: env[m.group(1)] if isinstance(env.get(m.group(1)), str) else "$?", scalar(target))
    ws = WORKSPACE_ROOT.match(t)
    if ws:
        base, t = "", t[ws.end():]
    if not t:
        return base
    if "$" in t or "`" in t or t.startswith(("/", "~", "-")) or any(c in t for c in "*?"):
        return None
    p = posixpath.normpath(posixpath.join(base, t))
    if p == ".":
        return ""
    return None if p == ".." or p.startswith("../") else p


def split_spec(pkg: str):
    """'@scope/name@1.2' -> ('@scope/name', '1.2'); no version -> (pkg, ''). Splits at the
    first '@' after a scope: the last one was a URL's userinfo in `name@https://u:t@host`,
    which put the credentials into the fix text (PKG_SPEC now refuses such specs too)."""
    at = pkg.find("@", 1)
    return (pkg[:at], pkg[at + 1:]) if at > 0 else (pkg, "")


def redact(text) -> str:
    """text with every SECRET_SHAPES credential masked. Audit.add() and Audit.note() call it
    on every field they record: the one choke point behind "never prints a secret"."""
    text = "" if text is None else str(text)
    for pat, rep in SECRET_SHAPES:
        text = pat.sub(rep, text)
    return text


def yaml_list(text: str, key: str) -> list:
    """The string items of a top-level YAML sequence (`packages:` in pnpm-workspace.yaml),
    block or flow style; [] when absent."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^" + re.escape(key) + r"\s*:\s*(.*)$", line)
        if not m:
            continue
        v = m.group(1).strip()
        if v.startswith("["):
            return [scalar(x) for x in v.strip("[]").split(",") if x.strip()]
        out = []
        for s in lines[i + 1:]:
            if not s.strip() or s.lstrip().startswith("#"):
                continue
            item = re.match(r"^\s*-\s+(.*)$", s)
            if not item:
                break
            out.append(scalar(item.group(1)))
        return out
    return []


def glob_rx(pat: str):
    """A gitignore / dockerignore / workspace glob -> regex over a /-separated path: * and ?
    stay inside one segment, ** spans any number of segments (none included), [...] is a
    character class ([!...] negated), a backslash escapes."""
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pat.startswith("**", i):
            out, i = out + ".*", i + 2
        elif c == "*":
            out, i = out + "[^/]*", i + 1
        elif c == "?":
            out, i = out + "[^/]", i + 1
        elif c == "[" and pat.find("]", i + 2) > 0:
            j = pat.find("]", i + 2)
            body = pat[i + 1:j]
            out += "[" + ("^" + body[1:] if body.startswith("!") else body).replace("\\", "\\\\") + "]"
            i = j + 1
        elif c == "\\" and i + 1 < len(pat):
            out, i = out + re.escape(pat[i + 1]), i + 2
        else:
            out, i = out + re.escape(c), i + 1
    return re.compile(out + r"\Z")


def gitignored(lines, path: str) -> bool:
    """Is path (a repo-relative file) ignored by these root .gitignore lines? git's rules
    (git-scm.com/docs/gitignore): the last matching line wins and `!` re-includes; a
    pattern with a slash before its end is anchored at the root, one without matches the
    name at any depth; a trailing slash matches directories only (here a parent of path).
    The fallback when git cannot answer (git_says); git's "a file under an excluded
    directory cannot be re-included" rule is not modelled."""
    parts, ignored = path.split("/"), False
    for raw in lines:
        line = raw.rstrip()
        if not line or line.startswith("#"):
            continue
        neg = line.startswith("!")
        line = line[1:] if neg or line.startswith("\\") else line
        dir_only, line = line.endswith("/"), line.rstrip("/")
        if not line:
            continue
        anchored, rx = "/" in line, glob_rx(line.lstrip("/"))
        for k in range(1, len(parts) + 1):
            if dir_only and k == len(parts):
                continue
            cand = "/".join(parts[:k]) if anchored else parts[k - 1]
            if rx.match(cand):
                ignored = not neg
                break
    return ignored


def dockerignored(lines, path: str) -> bool:
    """Is path (relative to the build context) excluded by these .dockerignore lines?
    Docker's rules (docs.docker.com/build/concepts/context/#dockerignore-files and
    moby/patternmatcher): every pattern is anchored at the context root (a leading / is
    dropped, so `.npmrc` excludes only the root file and `**/.npmrc` any), the last matching
    line wins, `!` re-includes, and a pattern matching a parent directory excludes what is
    inside it (`*` excludes config/.npmrc; a later `!**` lets it back in)."""
    parts, excluded = path.split("/"), False
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        neg = line.startswith("!")
        line = posixpath.normpath(line[1:].strip() if neg else line).lstrip("/")
        if line in ("", "."):
            continue
        rx = glob_rx(line)
        if any(rx.match("/".join(parts[:k])) for k in range(1, len(parts) + 1)):
            excluded = not neg
    return excluded


def git_says(root: Path, *args):
    """Exit code (0 or 1) of a read-only git query run in root, or None when git is absent,
    root is not in a work tree, or git refuses (128: dubious ownership, no repo).
    core.fsmonitor is forced off: a repo's own .git/config may name a program git runs
    when it reads the index, and pm-audit audits repos it did not write."""
    git = shutil.which("git")
    if not git:
        return None
    try:
        p = subprocess.run([git, "-c", "core.fsmonitor=false", "-C", str(root), *args], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.returncode if p.returncode in (0, 1) else None


def copies_context(text) -> bool:
    """Does a Dockerfile COPY or ADD its whole build context (`COPY . /app`)? A copy from
    another stage (`COPY --from=builder . /app`) reads that stage's filesystem instead."""
    for line in (text or "").splitlines():
        m = COPY_CONTEXT.match(line)
        if m and not re.search(r"--from\b", m.group(1)):
            return True
    return False


def rel(root: Path, p: Path) -> str:
    try:
        return p.relative_to(root).as_posix()
    except ValueError:
        return p.as_posix()


# =============================================================================
# === the audit ===
# =============================================================================
class Audit:
    def __init__(self, root: Path, facts: dict, as_of: dt.date, docs: bool, limit: int):
        self.root, self.facts, self.as_of, self.docs, self.limit = root, facts, as_of, docs, limit
        self.findings: list[dict] = []
        self.notes: list[dict] = []
        self.meta: dict = {"managers": [], "lockfiles": [], "node_pins": {}, "php_pins": {}}
        # A manifest that is not a JSON object is unreadable to every check: None here, and
        # js()/php() report *.manifest.invalid for the file that exists.
        self.pkg = self._manifest("package.json")
        self.composer = self._manifest("composer.json")
        self.ddev = self._read_ddev()
        self.native = {str(n).lower() for n in obj(facts.get("native_cli_names")).get("names") or []}
        # Every install deploy() reads in CI and deploy files: {family, manager, cwd, kind,
        # file, line, cmd}. cwd is the package root it runs in ("" = root, None = unknown).
        self.installs: list[dict] = []

    def _manifest(self, name):
        data = read_json(self.root / name) if (self.root / name).is_file() else None
        return data if isinstance(data, dict) else None

    # WHY redaction lives here, not at each check: findings quote commands and specs from
    # the repo, and any of them can carry a credential (`npm ci --registry=https://u:t@host`
    # in the lockfile-conflict message, `yarn --registry=...` in an unfrozen-install one).
    # Masking every field of every record is the only way "never prints a secret" survives
    # the next check someone adds. Don't bypass these two methods to append a record.
    def add(self, sev, fid, file, msg, fix, line=None):
        self.findings.append({"id": fid, "severity": sev, "file": redact(file), "line": line,
                              "message": redact(msg), "fix": redact(fix)})

    def note(self, nid, file, msg):
        self.notes.append({"id": nid, "file": redact(file), "message": redact(msg)})

    # ---- DDEV: config.yaml, then config.*.yaml in name order (later files win) ----
    def _read_ddev(self):
        d = self.root / ".ddev"
        base = d / "config.yaml"
        if not base.is_file():
            return None
        merged: dict = {}
        for f in [base] + sorted(p for p in d.glob("config.*.yaml") if p.name != "config.yaml"):
            merged.update(mini_yaml(read_text(f) or ""))
        return merged

    def run(self):
        self.deploy()  # first: js() asks where CI installs (self.installs); output is sorted later
        self.js()
        self.nested()
        self.node_pins()
        self.php()
        self.npx()
        self.legacy()
        self.secrets()
        self.pnpm_placeholders()
        return self

    # ---- JS managers and lockfiles ----
    def js(self):
        present = [n for n in JS_LOCKFILES if (self.root / n).is_file()]
        self.meta["lockfiles"] = present + (["composer.lock"] if (self.root / "composer.lock").is_file() else [])
        managers = sorted({JS_LOCKFILES[n] for n in present})
        if self.composer is not None:
            managers.append("composer")
        self.meta["managers"] = managers
        if self.pkg is None:
            if (self.root / "package.json").is_file():
                self.add("error", "js.manifest.invalid", "package.json", "package.json is not valid JSON, or not a JSON object",
                         "fix the JSON before any install")
            return
        if len(present) > 1:
            msg = f"{len(present)} JS lockfiles at the root ({', '.join(present)}); each manager reads only its own"
            fix = "pick one manager, delete the other lockfile(s), reinstall with that manager, commit"
            live = self._ci_root_lockfile(present)
            if live:
                inst, keep = live
                gone = [p for p in present if p != keep]
                msg += (f" - CI installs with `{inst['cmd']}` ({inst['file']}:{inst['line']}), so {keep} is live and "
                        f"{' and '.join(gone)} {'is' if len(gone) == 1 else 'are'} unused")
                fix = f"delete {', '.join(gone)}, keep {keep}, and install with {inst['manager']} everywhere"
            self.add("error", "js.lockfile.conflict", ", ".join(present), msg, fix)
        if "npm-shrinkwrap.json" in present and "package-lock.json" not in present:
            self.add("warn", "js.lockfile.shrinkwrap", "npm-shrinkwrap.json",
                     "npm 12 no longer reads npm-shrinkwrap.json, so `npm ci` finds no lockfile",
                     "rename it to package-lock.json (applications) and commit")
        uses_pnpm = "pnpm-lock.yaml" in present or str(self.pkg.get("packageManager", "")).startswith("pnpm@")
        if uses_pnpm and isinstance(self.pkg.get("pnpm"), dict) and self.pkg["pnpm"]:
            self.add("warn", "js.pnpm.field-ignored", "package.json",
                     "package.json has a `pnpm` field (" + ", ".join(sorted(self.pkg["pnpm"])[:5])
                     + ") - pnpm 11+ no longer reads it, so those settings are silently dropped",
                     "move the settings into pnpm-workspace.yaml (references/scripts-and-workspaces.md)")
        has_deps = any(obj(self.pkg.get(t)) for t in DEP_TYPES)
        if not present and has_deps:
            built = self._nested_builds()
            if built:
                self.note("js.lockfile.missing", "package.json",
                          f"dependencies declared but no root lockfile; CI installs only in "
                          f"{', '.join(d + '/' for d in built)} (each with its own lockfile) - nothing in CI installs "
                          "this package.json, so commit a lockfile here only if something else does")
            else:
                self.add("warn", "js.lockfile.missing", "package.json",
                         "dependencies declared but no lockfile committed - every install resolves fresh",
                         "run the chosen manager's install once and commit its lockfile")
        pm = str(self.pkg.get("packageManager") or "")
        pm_name, _, pm_ver = pm.partition("@")
        if not pm:
            self.note("js.packagemanager.unset", "package.json",
                      "no packageManager field - nothing declares which manager (and version) this repo expects")
        elif present:
            owned = [n for n in present if JS_LOCKFILES[n] == pm_name]
            if not owned:
                self.add("error", "js.packagemanager.mismatch", "package.json",
                         f"packageManager says {pm} but the lockfile is {', '.join(present)}",
                         "make packageManager name the manager whose lockfile you keep")
        yarn_lock = self.root / "yarn.lock"
        flavour = None
        if yarn_lock.is_file():
            head = (read_text(yarn_lock) or "")[:2000]
            flavour = "berry" if "__metadata:" in head else "classic"
            if flavour == "classic":
                # Not "security fixes only": the README says that of contributions, but the
                # 1.22.20-1.22.22 hotfixes were not security fixes. No version here - a new
                # release would make it stale where check-pm-facts cannot see it.
                self.note("js.yarn.classic", "yarn.lock",
                          "Yarn 1 (classic) lockfile - Yarn 1 is in maintenance mode and ships only an occasional hotfix; plan a move to npm or Yarn 4 (references/legacy-exits.md)")
            ym = re.match(r"\d+", pm_ver) if pm_name == "yarn" else None
            if ym:
                major = int(ym.group(0))
                if (major >= 2) != (flavour == "berry"):
                    self.add("error", "js.packagemanager.mismatch", "package.json",
                             f"packageManager pins yarn@{pm_ver} but yarn.lock is in Yarn {'1' if flavour == 'classic' else '2+'} format",
                             "install once with the pinned Yarn to convert the lockfile, or fix the pin")
        for n in present:
            self._lock_consistency(n, flavour)

    def _ci_root_lockfile(self, present):
        """(first CI install at the root, its lockfile) when every root install in CI uses
        one manager and that manager owns exactly one of the present lockfiles, else None.
        Dockerfiles and installs whose directory is unknown never decide it."""
        root = [i for i in self.installs if i["kind"] == "ci" and i["cwd"] == "" and i["family"] == "js"]
        if len({i["manager"] for i in root}) != 1:
            return None
        owned = [p for p in present if JS_LOCKFILES[p] == root[0]["manager"]]
        return (root[0], owned[0]) if len(owned) == 1 else None

    def _nested_builds(self):
        """Nested package roots with a lockfile that CI and deploy files install in, when
        every JS install there is nested. A root install, or one whose directory pm-audit
        cannot place (a Dockerfile, a matrix path), returns [] so the root keeps its
        js.lockfile.missing warning."""
        js = [i for i in self.installs if i["family"] == "js"]
        if not js or any(not i["cwd"] for i in js):
            return []
        return sorted({i["cwd"] for i in js if any((self.root / i["cwd"] / f).is_file() for f in JS_LOCKFILES)})

    def _declared(self):
        out = {}
        if not self.pkg:
            return out
        for t in DEP_TYPES:
            for name, spec in obj(self.pkg.get(t)).items():
                out[name] = (t, str(spec))
        return out

    def _lock_entry(self, name):
        """The npm lockfile's top-level entry for a package (packages["node_modules/<name>"],
        lockfile v2/v3), or {}."""
        for f in ("package-lock.json", "npm-shrinkwrap.json"):
            if (self.root / f).is_file():
                return obj(obj(obj(read_json(self.root / f)).get("packages")).get("node_modules/" + name))
        return {}

    def _installed(self, name):
        """The version of a declared package the repo installs: the npm lockfile's, else
        node_modules/<name>/package.json's, else the declared spec when it is exact. None
        when unknown (a pnpm or Yarn lock, an uninstalled range)."""
        v = self._lock_entry(name).get("version") or obj(read_json(self.root / "node_modules" / name / "package.json")
                                                         if (self.root / "node_modules" / name / "package.json").is_file()
                                                         else None).get("version")
        if not v:
            spec = self._declared().get(name, ("", ""))[1]
            v = spec if EXACT_SEMVER.match(spec) else None
        m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", str(v or ""))
        return tuple(int(x) for x in m.groups()) if m else None

    def _local_bins(self):
        """bin name -> the declared package that provides it, for npx's local-first lookup.
        A declared package's own name always counts (as before); then, strongest first, the
        npm lockfile's packages[...].bin, Yarn 2+'s yarn.lock `bin:` blocks,
        node_modules/<pkg>/package.json "bin", and BIN_ALIASES. Declared packages only: a
        transitive bin that happens to be hoisted into node_modules/.bin is still worth
        declaring, so it keeps its finding."""
        declared = set(self._declared())
        out = {n: n for n in declared}

        def take(pkg, bin_field):
            if isinstance(bin_field, dict):
                for b in bin_field:
                    out.setdefault(str(b), pkg)
            elif isinstance(bin_field, str) and bin_field:
                out.setdefault(pkg.split("/")[-1], pkg)  # "bin": "cli.js" is named after the package

        for n in declared:
            take(n, self._lock_entry(n).get("bin"))
        berry = (read_text(self.root / "yarn.lock") or "") if (self.root / "yarn.lock").is_file() else ""
        if "__metadata:" in berry[:2000]:
            owner, in_bin = None, False
            for line in berry.splitlines():
                if line and not line[0].isspace():
                    key = line.rstrip(":").split(",")[0].strip().strip('"')
                    owner = key[:key.find("@", 1)] if key.find("@", 1) > 0 else None
                    in_bin = False
                elif re.match(r"^  bin:\s*$", line):
                    in_bin = True
                elif in_bin and re.match(r"^    \S", line) and owner in declared:
                    out.setdefault(line.strip().split(":")[0].strip('"'), owner)
                elif not re.match(r"^    ", line):
                    in_bin = False
        for n in declared:
            nm = self.root / "node_modules" / n / "package.json"
            if nm.is_file():
                take(n, obj(read_json(nm)).get("bin"))
        for n in declared:
            for b in BIN_ALIASES.get(n, ()):
                out.setdefault(b, n)
        return out

    def _lock_consistency(self, name: str, flavour):
        declared = self._declared()
        p = self.root / name
        missing, changed, extra = [], [], []
        if name in ("package-lock.json", "npm-shrinkwrap.json"):
            lock = read_json(p)
            if not isinstance(lock, dict):
                self.add("error", "js.lockfile.stale", name, "lockfile is not valid JSON", "regenerate it")
                return
            ver = lock.get("lockfileVersion", 1)
            if ver == 1:
                self.add("warn", "js.lockfile.v1", name,
                         "lockfileVersion 1 (written by npm 6 or older) - the toolchain that maintains this repo predates npm 7",
                         "install with a current npm and commit the upgraded lockfile (references/legacy-exits.md)")
                names = set(obj(lock.get("dependencies")).keys())
                missing = [n for n in declared if n not in names]
            else:
                rootpkg = obj(lock.get("packages")).get("")
                if not isinstance(rootpkg, dict):
                    return
                locked = {}
                for t in DEP_TYPES:
                    for n, s in obj(rootpkg.get(t)).items():
                        locked[n] = str(s)
                missing = [n for n in declared if n not in locked]
                changed = [n for n in declared if n in locked and locked[n] != declared[n][1]]
                extra = [n for n in locked if n not in declared]
        elif name == "yarn.lock":
            keys = set()
            for line in (read_text(p) or "").splitlines():
                if line and not line[0].isspace() and not line.startswith("#") and line.rstrip().endswith(":"):
                    for k in line.rstrip()[:-1].split(","):
                        keys.add(k.strip().strip('"'))
            for n, (_, spec) in declared.items():
                if LOCAL_SPEC.match(spec):
                    continue
                if f"{n}@{spec}" not in keys and f"{n}@npm:{spec}" not in keys:
                    missing.append(n)
        elif name == "pnpm-lock.yaml":
            doc = mini_yaml(read_text(p) or "")
            imp = (doc.get("importers") or {}).get(".") if isinstance(doc.get("importers"), dict) else doc
            if not isinstance(imp, dict):
                return
            locked = {}
            for t in DEP_TYPES:
                for n, v in (imp.get(t) or {}).items() if isinstance(imp.get(t), dict) else []:
                    locked[n] = v.get("specifier") if isinstance(v, dict) else None
            missing = [n for n in declared if n not in locked]
            changed = [n for n in declared if locked.get(n) not in (None, declared[n][1]) and n in locked]
            extra = [n for n in locked if n not in declared]
        elif name == "bun.lock":
            ws = obj(obj(read_jsonc(p)).get("workspaces")).get("")
            if not isinstance(ws, dict):
                return
            locked = {}
            for t in DEP_TYPES:
                for n, s in obj(ws.get(t)).items():
                    locked[n] = str(s)
            missing = [n for n in declared if n not in locked]
            changed = [n for n in declared if n in locked and locked[n] != declared[n][1]]
            extra = [n for n in locked if n not in declared]
        elif name == "bun.lockb":
            self.note("js.lockfile.binary", name, "binary bun.lockb cannot be checked; Bun now writes a text bun.lock")
            return
        else:
            return
        if missing or changed or extra:
            parts = []
            if missing:
                parts.append("not in lockfile: " + ", ".join(sorted(missing)[:8]))
            if changed:
                parts.append("range changed: " + ", ".join(sorted(changed)[:8]))
            if extra:
                parts.append("in lockfile but not package.json: " + ", ".join(sorted(extra)[:8]))
            self.add("warn", "js.lockfile.stale", name,
                     f"{name} disagrees with package.json ({'; '.join(parts)}) - a frozen install will fail",
                     "run a normal install with the repo's manager on a dev machine, review the lock diff, commit")

    # ---- Node version pins ----
    def node_pins(self):
        if self.pkg is None:
            return
        node = obj(self.facts.get("node"))
        codenames = {str(k).lower(): v for k, v in obj(node.get("lts_codenames")).items()}
        exact: dict[str, int] = {}
        ranges: dict[str, str] = {}

        def exact_from(src: str, raw: str, quiet: bool = False):
            """quiet: a CI setup-node value, where an alias (lts/*, latest) is a CI choice,
            not a repo pin to report."""
            v = raw.strip().splitlines()[0].strip() if raw.strip() else ""
            low = v.lower()
            if low.startswith("lts/"):
                cn = low[4:]
                if cn in codenames:
                    exact[src] = int(codenames[cn])
                elif not quiet:
                    self.note("js.node.floating", src, f"'{v}' floats to whatever LTS is newest - not a pin")
                return
            if src.startswith(".ddev") and low in ("auto", "engine"):
                return  # DDEV reads .node-version/.nvmrc/engines itself: agrees by construction
            if low in ("node", "stable", "latest", "current", "lts", "auto", "system"):
                if not quiet:
                    self.note("js.node.floating", src, f"'{v}' is an alias, not a version pin")
                return
            m = re.match(r"^v?(\d+)", v)
            if m:
                exact[src] = int(m.group(1))

        for f in (".nvmrc", ".node-version"):
            t = read_text(self.root / f) if (self.root / f).is_file() else None
            if t is not None:
                exact_from(f, t)
        tv = read_text(self.root / ".tool-versions") if (self.root / ".tool-versions").is_file() else None
        if tv:
            m = re.search(r"^\s*nodejs\s+(\S+)", tv, re.M)
            if m:
                exact_from(".tool-versions", m.group(1))
        for f in ("mise.toml", ".mise.toml"):
            mt = read_text(self.root / f) if (self.root / f).is_file() else None
            if mt:
                m = re.search(r"^\s*node\s*=\s*[\"']([^\"']+)[\"']", mt, re.M)
                if m:
                    exact_from(f, m.group(1))
        volta = self.pkg.get("volta")
        if isinstance(volta, dict) and volta.get("node"):
            exact_from("package.json volta.node", str(volta["node"]))
        eng = (self.pkg.get("engines") or {}).get("node") if isinstance(self.pkg.get("engines"), dict) else None
        if eng:
            ranges["package.json engines.node"] = str(eng)
        dev = self.pkg.get("devEngines")
        rt = dev.get("runtime") if isinstance(dev, dict) else None
        for r in (rt if isinstance(rt, list) else [rt] if isinstance(rt, dict) else []):
            if isinstance(r, dict) and str(r.get("name", "")).lower() == "node" and r.get("version"):
                ranges["package.json devEngines.runtime"] = str(r["version"])
        if self.ddev is not None:
            nv = self.ddev.get("nodejs_version")
            if isinstance(nv, str) and nv:
                exact_from(".ddev/config.yaml nodejs_version", nv)
            else:
                self.add("warn", "ddev.node.unpinned", ".ddev/config.yaml",
                         "no nodejs_version - the container runs DDEV's default Node, which moves with DDEV upgrades",
                         "set nodejs_version to the same major as .nvmrc (references/version-pinning.md)")
        self.meta["node_pins"] = {**{k: str(v) for k, v in exact.items()}, **ranges}

        if not exact and not ranges:
            self.add("warn", "js.node.unpinned", "package.json",
                     "no Node version pin (.nvmrc, .node-version, engines.node, devEngines, volta, .tool-versions)",
                     "add .nvmrc with the production major and engines.node to match")
            return
        # CI's setup-node versions join the agreement and end-of-life checks below, but never
        # count as the repo's own pin (above): a developer's machine does not read them.
        repo_exact = dict(exact)
        for src, tool, v in self._setup_pins():
            if tool == "node":
                exact_from(src, v, quiet=True)
        self.meta["node_pins"] = {**{k: str(v) for k, v in exact.items()}, **ranges}
        # engine-strict is npm's switch; pnpm and Yarn treat engines their own way, so
        # telling a pnpm repo to edit .npmrc would be wrong advice.
        pm_name = str(self.pkg.get("packageManager") or "").partition("@")[0]
        npm_repo = {m for m in self.meta["managers"] if m != "composer"} <= {"npm"} and pm_name in ("", "npm")
        if eng and npm_repo and not re.search(r"^\s*engine-strict\s*=\s*true\b", read_text(self.root / ".npmrc") or "", re.M):
            self.note("js.engines.unenforced", "package.json",
                      "engines.node is advisory to npm unless .npmrc sets engine-strict=true")

        problems = []
        majors = sorted(set(exact.values()))
        if len(majors) > 1:
            problems.append("exact pins differ: " + ", ".join(f"{k}={v}" for k, v in exact.items()))
        for src, spec in ranges.items():
            for esrc, major in exact.items():
                ok = admits(spec, (major, 0, 0), (major + 1, 0, 0))
                if ok is False:
                    problems.append(f"{src} '{spec}' excludes {esrc}={major}")
        if not repo_exact and len(ranges) > 1:
            specs = list(ranges.items())
            for i in range(len(specs)):
                for j in range(i + 1, len(specs)):
                    joint = [m for m in range(0, 60) if admits(specs[i][1], (m, 0, 0), (m + 1, 0, 0))
                             and admits(specs[j][1], (m, 0, 0), (m + 1, 0, 0))]
                    if not joint:
                        problems.append(f"{specs[i][0]} and {specs[j][0]} share no Node major")
        if problems:
            self.add("warn", "node.pin.disagree", ", ".join(sorted(set(list(exact) + list(ranges)))),
                     "Node pins disagree - " + "; ".join(problems),
                     "choose the production Node major and make every pin say it")

        # Unknown majors (a future line, a typo) are never called end-of-life.
        ends = {int(k): dt.date.fromisoformat(v["end"]) for k, v in obj(node.get("releases")).items()
                if str(k).isdigit() and isinstance(v, dict) and v.get("end")}
        # WHY DDEV's own pin is left out of the end-of-life finding: one owner per fact.
        # ddev-ops' audit-ddev-config.py reports an end-of-life nodejs_version (node-eol), so
        # here DDEV joins only the agreement check above, and is named as a pointer when the
        # repo's other pins are dead too.
        ddev_dead = [m for s, m in exact.items() if s.startswith(".ddev/") and m in ends and ends[m] < self.as_of]
        dead = [(s, m) for s, m in exact.items() if not s.startswith(".ddev/") and m in ends and ends[m] < self.as_of]
        aside = (f"; DDEV's nodejs_version {ddev_dead[0]} is end of life as well, which ddev-ops' audit-ddev-config reports"
                 if ddev_dead else "")
        # WHY "the repo pins" and the server hint: the production runtime is not in the
        # repo, so pm-audit can say only what the code targets; the server may differ.
        if dead:
            self.add("warn", "js.node.eol", dead[0][0],
                     "the repo pins end-of-life Node: " + ", ".join(f"{s}={m} (EOL {ends[m]})" for s, m in dead)
                     + " - confirm the server's Node version too" + aside,
                     "move to a supported LTS major (references/version-pinning.md)")
        elif not any(not s.startswith(".ddev/") for s in repo_exact):
            supported = [m for m, end in ends.items() if end >= self.as_of]
            for src, spec in ranges.items():
                if supported and not any(admits(spec, (m, 0, 0), (m + 1, 0, 0)) for m in supported):
                    self.add("warn", "js.node.eol", src,
                             f"{src} '{spec}' targets no supported Node release - confirm the server's Node version too"
                             + aside, "widen or move the range to a supported LTS major")

    # ---- Composer / PHP ----
    def php(self):
        c = self.composer
        if c is None:
            if (self.root / "composer.json").is_file():
                self.add("error", "php.manifest.invalid", "composer.json", "composer.json is not valid JSON, or not a JSON object",
                         "fix the JSON; `composer validate` shows where")
            return
        is_lib = str(c.get("type", "project")) not in ("project", "")
        req = obj(c.get("require"))
        req_dev = obj(c.get("require-dev"))
        pkgs = [n for n in list(req) + list(req_dev) if not COMPOSER_PLATFORM.match(n)]
        lock_p = self.root / "composer.lock"
        lock = read_json(lock_p) if lock_p.is_file() else None
        if not lock_p.is_file():
            if pkgs and not is_lib:
                self.add("warn", "php.lockfile.missing", "composer.json",
                         "composer.json has packages but no composer.lock - `composer install` resolves fresh every time",
                         "run `composer update` once (in DDEV: `ddev composer update`) and commit composer.lock")
        elif not isinstance(lock, dict):
            # Not `composer update --lock`: it must read the old lock and rethrows the parse
            # error. Only a full update ignores a broken lock (Installer::doUpdate, 2.10.3).
            self.add("error", "php.lockfile.stale", "composer.lock", "composer.lock is not valid JSON",
                     "take a valid copy from git (mid-merge: `git checkout --theirs composer.lock`, then re-run "
                     "the other branch's composer commands), or regenerate it with a full `composer update` "
                     "and review every version change")
        else:
            # WHY replace/provide and the require / require-dev split: this mirrors Composer's
            # own lock check (Locker::getMissingRequirementInfo). A root `require` is met from
            # the lock's `packages` only (getLockedRepository(false)), a `require-dev` from
            # `packages` + `packages-dev`, and either by a package of that name OR one that
            # lists it under `replace` or `provide` (findPackagesWithReplacersAndProviders):
            # a renamed plugin replacing its old name, symfony/symfony replacing the
            # component the root asks for, guzzle providing psr/http-client-implementation.
            # Composer refuses the install (exit 4) only when nothing qualifies (installer
            # fixture outdated-lock-file-fails-install.test). Presence only: constraints
            # are not compared.
            def met(entries):
                out = set()
                for p in entries if isinstance(entries, list) else []:
                    if isinstance(p, dict):
                        out.add(str(p.get("name", "")).lower())
                        for k in ("replace", "provide"):
                            if isinstance(p.get(k), dict):
                                out.update(str(x).lower() for x in p[k])
                return out
            prod = met(lock.get("packages"))
            dev = prod | met(lock.get("packages-dev"))
            missing = sorted({n for n in req if not COMPOSER_PLATFORM.match(n) and n.lower() not in prod}
                             | {n for n in req_dev if not COMPOSER_PLATFORM.match(n) and n.lower() not in dev})
            if missing:
                shown = [n + (" (locked only in packages-dev)" if n in req and n.lower() in dev else "") for n in missing]
                self.add("warn", "php.lockfile.stale", "composer.lock",
                         "composer.json requires packages missing from composer.lock: " + ", ".join(shown[:8]),
                         "run `composer update <package>` for the new requirement and commit composer.lock")
        php_req = req.get("php")
        # A composer.json that requires no packages (`{"name": ...}`, used to make a JS
        # asset repo installable through Composer) resolves nothing: PHP pins are noise.
        resolves = bool(pkgs)
        platform = obj(obj(c.get("config")).get("platform")).get("php")
        # WHY a project with config.platform.php gets a note, not a finding (Composer 2.10.3,
        # checked at the tag because getcomposer.org/doc is built from main): install and
        # update test the root require.php against the faked platform, not the real PHP
        # (doc/06-config.md "platform": on PHP 5.6 "it will install fine as it assumes
        # 7.0.3"), so it cannot stop an install on the wrong PHP. Every installed package's
        # own php constraint still binds resolution, and the generated platform_check.php
        # refuses to boot below the highest php floor of the root AND every non-dev package
        # (AutoloadGenerator::getPlatformCheck). A missing root require.php costs only the
        # stated range, and a floor above all the dependencies'. A library keeps the warn:
        # `config` is root-only, so to a consumer's resolver require.php is the only PHP
        # constraint the package has.
        if not php_req and resolves:
            if platform and not is_lib:
                self.note("php.require.missing", "composer.json",
                          f"no require.php - config.platform.php ({platform}) already sets the PHP Composer resolves for, "
                          "and platform_check.php still enforces the packages' PHP floor; add require.php to state the range")
            else:
                self.add("warn", "php.require.missing", "composer.json",
                         "no require.php - nothing stops installing on a PHP the code cannot run on",
                         'add "php": "^<production major.minor>" to require')
        if not platform and not is_lib and resolves:
            self.add("warn", "php.platform.unset", "composer.json",
                     "no config.platform.php - `composer update` resolves for whatever PHP runs it, not production",
                     'set config.platform.php to the production PHP version, e.g. "8.3.0" (references/version-pinning.md)')
        exact: dict[str, tuple] = {}

        def put(src, v):
            """Record a major.minor pin; False when v is not version-shaped."""
            m = re.match(r"^(\d+)\.(\d+)", str(v or "").strip())
            if m:
                exact[src] = (int(m.group(1)), int(m.group(2)))
            return bool(m)

        put("composer.json config.platform.php", platform)
        if isinstance(lock, dict):
            put("composer.lock platform-overrides.php", obj(lock.get("platform-overrides")).get("php"))
        if self.ddev is not None:
            # An unset or end-of-life php_version is ddev-ops' finding (audit-ddev-config.py
            # php-unpinned, php-eol); here DDEV's PHP feeds the agreement check below.
            put(".ddev/config.yaml php_version", self.ddev.get("php_version"))
        # CI's setup-php versions join the agreement and end-of-life checks, not the
        # range-only check below, which asks what the repo itself admits.
        repo_exact = dict(exact)
        for src, tool, v in self._setup_pins():
            if tool == "php":
                put(src, v)
        self.meta["php_pins"] = {**{k: f"{v[0]}.{v[1]}" for k, v in exact.items()},
                                 **({"composer.json require.php": str(php_req)} if php_req else {})}
        problems = []
        if len(set(exact.values())) > 1:
            problems.append("exact pins differ: " + ", ".join(f"{k}={v[0]}.{v[1]}" for k, v in exact.items()))
        if php_req:
            for src, (a, b) in exact.items():
                if admits(str(php_req), (a, b, 0), (a, b + 1, 0), "composer") is False:
                    problems.append(f"require.php '{php_req}' excludes {src}={a}.{b}")
        if problems:
            self.add("warn", "php.pin.disagree", ", ".join(sorted(set(exact) | ({"composer.json require.php"} if php_req else set()))),
                     "PHP pins disagree - " + "; ".join(problems),
                     "set DDEV php_version and config.platform.php to production PHP; make require.php admit it")
        # Unknown branches (8.6 before the table learns it) are never called end-of-life.
        ends = {tuple(map(int, str(k).split("."))): dt.date.fromisoformat(v["security_end"])
                for k, v in obj(obj(self.facts.get("php")).get("releases")).items()
                if re.match(r"^\d+\.\d+$", str(k)) and isinstance(v, dict) and v.get("security_end")}
        # WHY DDEV's pin is left out of php.eol: ddev-ops owns it (see node_pins()).
        ddev_dead = [v for s, v in exact.items() if s.startswith(".ddev/") and v in ends and ends[v] < self.as_of]
        dead = [(s, v) for s, v in exact.items() if not s.startswith(".ddev/") and v in ends and ends[v] < self.as_of]
        aside = (f"; DDEV's php_version {ddev_dead[0][0]}.{ddev_dead[0][1]} is end of life as well, which ddev-ops' "
                 "audit-ddev-config reports" if ddev_dead else "")
        # WHY "the repo pins" and the server hint: see the same wording in node_pins().
        if dead:
            self.add("warn", "php.eol", dead[0][0],
                     "the repo pins end-of-life PHP: "
                     + ", ".join(f"{s}={v[0]}.{v[1]} (security support ended {ends[v]})" for s, v in dead)
                     + " - confirm the server's PHP version too" + aside,
                     "plan the PHP upgrade: `composer why-not php <target>` lists the blockers (references/legacy-exits.md)")
        elif not any(not s.startswith(".ddev/") for s in repo_exact) and php_req:
            live = [v for v, end in ends.items() if end >= self.as_of]
            if live and not any(admits(str(php_req), (a, b, 0), (a, b + 1, 0), "composer") for a, b in live):
                self.add("warn", "php.eol", "composer.json",
                         f"require.php '{php_req}' targets no supported PHP release - confirm the server's PHP version too"
                         + aside, "raise the constraint to a supported PHP (references/legacy-exits.md)")

    # ---- npx / dlx / exec ----
    def npx(self):
        native = self.native
        # The repo's own package name and declared bins: docs showing them are the
        # publisher's instructions to users, not a dependency of this repo.
        own = {str(self.pkg.get("name", ""))} if self.pkg else set()
        bins = (self.pkg or {}).get("bin")
        own |= set(bins) if isinstance(bins, dict) else set()
        own.discard("")
        # An unreadable package.json hides which bins are local; guessing "remote" would
        # turn one js.manifest.invalid into a cascade of false npx.unpinned findings.
        locals_unknown = self.pkg is None and (self.root / "package.json").is_file()
        local_bins = self._local_bins() if self.pkg else {}
        provides = {b: p for p, bs in BIN_ALIASES.items() for b in bs if b != p}
        seen: set = set()

        def parse(toks):
            """A launcher's arguments -> (every -p/--package spec, the command word, refuses).
            refuses: --no / --no-install, with which npx and bunx run a bin only if it is
            already local, global or cached and never fetch one (references/npx-exec-safety.md)."""
            pkgs, refuses, i = [], False, 0
            while i < len(toks):
                t = toks[i]
                if t in ("-p", "--package"):
                    if i + 1 < len(toks):
                        pkgs.append(toks[i + 1])
                    i += 2
                elif t.startswith("--package="):
                    pkgs.append(t.split("=", 1)[1])
                    i += 1
                elif t in ("--no", "--no-install"):
                    refuses, i = True, i + 1
                elif t in FLAG_WITH_VALUE:
                    i += 2
                elif t.startswith("-"):
                    i += 1  # including `--`, which only ends the launcher's own options
                else:
                    return pkgs, t, refuses
            return pkgs, None, refuses

        def inspect(file: str, line_no, text: str, in_script: bool):
            for m in LAUNCHER.finditer(text):
                launcher = re.sub(r"\s+", " ", m.group(1))
                pkgs, cmd, refuses = parse(m.group(2).split())
                if refuses and launcher in ("npx", "npm exec", "bunx", "bun x"):
                    continue
                # With -p the command word is a bin of those packages; without, it is the package.
                for spec in pkgs or ([cmd] if cmd else []):
                    check(file, line_no, launcher, spec, in_script, bin_word=not pkgs)

        def check(file, line_no, launcher, pkg, in_script, bin_word):
            pkg = pkg.strip("'\"`),")
            if pkg.endswith((".", ":", ";")):
                return  # sentence punctuation: "...the pinned npx fallback." is prose
            if not PKG_SPEC.match(pkg):
                return  # prose like "npx is...", a placeholder, a URL/git/file/alias spec
            base, ver = split_spec(pkg)
            # Dedupe on the full spec: a pinned `x@1.2.3` must not hide a later bare `x`.
            key = (file, pkg.lower())
            if key in seen:
                return
            seen.add(key)
            if base.lower() in native:
                self.add("error", "npx.native-cli", file,
                         f"`{launcher} {pkg}` routes a native CLI through the npm registry - the npm name is not the tool's official channel",
                         f"install {base} from its own channel (winget/brew/apt/cargo) and call it directly",
                         line_no)
                return
            # `pkg@${VERSION}` / `pkg@$VERSION`: pinned by the variable, checked where it is set.
            if EXACT_SEMVER.match(ver) or ver.startswith("$") or locals_unknown:
                return
            # A bare command word runs a local bin when a declared package provides it (npx
            # tsc with typescript installed); a requested version names the package itself.
            local = local_bins.get(base) if (bin_word and not ver) else (base if base in local_bins.values() else None)
            limited = len([f for f in self.findings if f["id"] == "npx.unpinned"]) >= self.limit
            if local and not ver:
                if in_script:
                    self.note("npx.redundant", file, f"`{launcher} {base}` in a script: {local} is a local dependency; npm run already puts node_modules/.bin on PATH")
                return
            if local:
                # WHY a declared package is exempt only when the local copy satisfies the
                # request: npx compares the requested spec with the installed version and
                # fetches on a miss, and resolves a dist-tag on the registry every time.
                installed = self._installed(local)
                tag = DIST_TAG.match(ver) is not None
                if not tag:
                    if installed is not None:
                        if admits(ver, installed, (installed[0], installed[1], installed[2] + 1)) is not False:
                            return
                    else:
                        decl = parse_range(self._declared()[local][1]) or []
                        spans = [(max(iv[0] for iv in s), min(iv[1] for iv in s)) for s in decl]
                        if not decl or any(admits(ver, lo, hi) is not False for lo, hi in spans if lo < hi):
                            return  # unknown, or the declared range can satisfy it: don't accuse
                if limited:
                    return
                what = (f"runs whatever version the `{ver}` dist-tag names, which the local {local} does not pin" if tag else
                        f"asks for '{ver}', which the local {local} "
                        + (f"({'.'.join(map(str, installed))}) " if installed else "") + "does not satisfy, so it fetches one")
                self.add("warn", "npx.unpinned", file, f"`{launcher} {pkg}` {what}",
                         f"drop @{ver} to run the local {local}, or pin it: {launcher} {base}@<exact version>", line_no)
                return
            if base in own and not in_script:
                return  # the repo documenting its own published package for its users
            if limited:
                return
            # WHY "dist-tag", not "newest": a bare name resolves through the `latest`
            # dist-tag (npm-pick-manifest, pnpm's `tag` setting, `yarn add`, bunx), and a
            # release published under another tag never moves it. A range is no better
            # described as "newest in range": npm-pick-manifest prefers `latest` when it fits.
            if not ver:
                what = "runs whatever version the `latest` dist-tag names"
            elif DIST_TAG.match(ver):
                what = f"runs whatever version the `{ver}` dist-tag names"
            else:
                what = f"lets the registry pick any version in range '{ver}'"
            owner = provides.get(base) if bin_word and not ver else None
            fix = (f"add {owner} (it provides {base}) as a devDependency, or pin it: {launcher} -p {owner}@<exact version> {base}"
                   if owner else f"add {base} as a devDependency, or pin it: {launcher} {base}@<exact version>")
            self.add("warn", "npx.unpinned", file, f"`{launcher} {pkg}` {what} - not an exact version", fix, line_no)

        if self.pkg:
            for name, cmd in obj(self.pkg.get("scripts")).items():
                inspect(f"package.json scripts.{name}", None, str(cmd), True)
        if not self.docs:
            return
        scanned = 0
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS
                                 and (not d.startswith(".") or d in DOT_DIRS_SCANNED))
            for fn in sorted(filenames):
                p = Path(dirpath) / fn
                # Git hooks (.husky/pre-commit) and DDEV custom commands are extensionless
                # shell scripts, so inside those dirs a file with no suffix is read too.
                hook_script = not p.suffix and bool(HOOK_DIRS & set(Path(dirpath).relative_to(self.root).parts))
                if p.suffix.lower() not in DOC_SUFFIXES and fn.lower() not in DOC_NAMES \
                        and not fn.lower().startswith(("dockerfile", "readme")) and not hook_script:
                    continue
                try:
                    if p.stat().st_size > MAX_DOC_BYTES:
                        continue
                except OSError:
                    continue
                text = read_text(p)
                if text is None:
                    continue
                scanned += 1
                md = p.suffix.lower() in (".md", ".markdown") or fn.lower().startswith("readme")
                for n, line in code_lines(text, md):
                    if re.search(r"npx|dlx|bunx|bun x|npm exec", line):
                        inspect(rel(self.root, p), n, line, False)
        self.meta["files_scanned"] = scanned

    # ---- nested package roots (pm-audit audits the root; it only lists these) ----
    def nested(self):
        root_mgrs = {JS_LOCKFILES[n] for n in JS_LOCKFILES if (self.root / n).is_file()}
        found: list[tuple[str, str]] = []
        for dirpath, dirnames, filenames in os.walk(self.root):
            parts = Path(dirpath).relative_to(self.root).parts
            dirnames[:] = [] if len(parts) >= NESTED_MAX_DEPTH else sorted(
                d for d in dirnames if d not in SKIP_DIRS and d not in NESTED_SKIP and not d.startswith("."))
            if parts:
                found += [(Path(dirpath, f).relative_to(self.root).as_posix(), JS_LOCKFILES[f])
                          for f in sorted(filenames) if f in JS_LOCKFILES]
        self.meta["nested_lockfiles"] = [p for p, _ in found]
        if not found:
            return
        self.note("js.nested.roots", found[0][0],
                  f"{len(found)} nested package root(s) with their own lockfile ("
                  + ", ".join(f"{p} [{m}]" for p, m in found[:6])
                  + ") - pm-audit audits only the root; run it on each")
        base = root_mgrs or {found[0][1]}
        odd = [(p, m) for p, m in found if m not in base]
        if odd:
            self.add("warn", "js.manager.mixed", odd[0][0],
                     f"the root uses {', '.join(sorted(base))} but nested packages use another manager: "
                     + ", ".join(f"{p} [{m}]" for p, m in odd[:6]),
                     "one manager per repo: convert the odd ones out (references/detect-and-choose.md)")

    # ---- CI and deploy: frozen installs, --no-dev, Composer 1, credentials in images ----
    def deploy(self):
        files: list[tuple[Path, str]] = []  # (path, "ci" | "deploy")
        for g in CI_GLOBS:
            files += [(p, "ci") for p in sorted(self.root.glob(g)) if p.is_file()]
        dockerfiles = [p for p in sorted(self.root.glob("Dockerfile*"))
                       if p.is_file() and not re.search(r"dev|test", p.name, re.I)]
        files += [(p, "deploy") for p in dockerfiles]
        appspec = self.root / "appspec.yml"
        if appspec.is_file():
            for loc in re.findall(r"^\s*-?\s*location:\s*[\"']?([^\s\"'#]+)", read_text(appspec) or "", re.M):
                hook = (self.root / loc).resolve()
                if hook.is_file() and self.root in hook.parents:
                    files.append((hook, "deploy"))
        # Credential files CI writes: (file, line, name, repo-relative path or None when it
        # lands outside the repo or cannot be placed), and `docker build`s: (file, line,
        # context dir, Dockerfile path; None when unplaceable). _image_leaks() pairs them.
        writes: list = []
        builds: list = []
        scopes: dict = {}
        seen: set = set()

        def flag(fid, rel, n, msg, fix, sev="warn"):
            if (fid, rel, n) not in seen:
                seen.add((fid, rel, n))
                self.add(sev, fid, rel, msg, fix, n)

        for path, kind in files:
            text = read_text(path) or ""
            rel = path.relative_to(self.root).as_posix()
            ci = kind == "ci"
            ships = self._ship_scope(rel, kind, text)
            start_dir = self._start_dirs(rel, kind, text)
            every = list(code_lines(text, False))
            # Commands as the shell receives them: YAML command keys only (a command quoted in
            # a release body is text), Dockerfile RUN instructions, a Jenkinsfile's sh steps,
            # and otherwise (appspec hook scripts) each line with continuations joined. Setup
            # inputs (`tools: composer:v1`) are not commands, so Composer 1 is read from every
            # line. Outside YAML each command is its own block: a Jenkinsfile `sh` step is its
            # own shell, and Dockerfile and hook-script directories are never placed.
            if path.suffix in (".yml", ".yaml"):
                commands = list(yaml_command_lines(text))
            elif path.name.lower().startswith("dockerfile"):
                commands = [(n, c, n) for n, c in dockerfile_commands(text)]
            elif path.name == "Jenkinsfile":
                commands = [(n, c, n) for n, c in jenkins_commands(text)]
            else:
                commands = [(n, c, n) for n, c in _join_continued(list(enumerate(text.splitlines(), 1)))]
            if ci:
                scopes[rel] = self._job_scope(rel, text)
            block, cwd, env, stack = None, None, {}, []
            for n, line in every:
                if COMPOSER_V1.search(line):
                    end = obj(self.facts.get("composer")).get("v1_maintenance_until") or "2026-05-30"
                    flag("php.composer.v1", rel, n, f"Composer 1 in {rel} - it reached end of life ({end})",
                         "use Composer 2 (`tools: composer:v2`, the composer:2 image); see references/legacy-exits.md")
            for n, line, key_n in commands:
                if key_n != block:
                    block, stack = key_n, []
                    cwd, env = start_dir(key_n)
                # A credential write is placed where its block's shell stands; ~/.npmrc,
                # $HOME/..., absolute and ../ paths come back None (outside any context).
                m = CRED_WRITE.search(line) if ci else None
                if m:
                    writes.append((rel, n, m.group(2), join_dir(cwd, m.group(1), env)))
                elif ci and CRED_CONFIG.search(line):
                    writes.append((rel, n, "auth.json", join_dir(cwd, "auth.json", env)))
                # A `cd` moves the rest of its shell block (undone at the end of a subshell);
                # installs and builds run where it left off.
                for words in simple_commands(line):
                    if words == ["("]:
                        stack.append(cwd)
                        continue
                    if words == [")"]:
                        cwd = stack.pop() if stack else cwd
                        continue
                    if words[0] in ("cd", "pushd") and len(words) == 2:
                        cwd = join_dir(cwd, words[1], env)
                        continue
                    built = docker_build(words) if ci else None
                    if built:
                        ctx = join_dir(cwd, built[0], env)
                        dfile = (join_dir(cwd, built[1], env) if built[1]
                                 else posixpath.join(ctx, "Dockerfile") if ctx is not None else None)
                        builds.append((rel, n, ctx, dfile))
                    for tool, args in command_tools(words):
                        self._install_line(tool, args, rel, n, kind, ships(n), cwd, flag, env)
            if ci:
                self._ramsey(text, rel, ships, flag)
                builds += self._action_builds(rel, text, start_dir)
        self._image_leaks(writes, builds, scopes, flag)

    def _job_scope(self, rel, text):
        """line -> the GitHub Actions job holding it (its first line), or 0 for a file judged
        whole. Same split as _ship_scope: GitHub jobs share files only through artifacts,
        while GitLab and Bitbucket hand every earlier artifact to later jobs by default."""
        jobs = workflow_jobs(text) if rel.startswith(".github/workflows/") else None
        if not jobs:
            return lambda _n: 0
        return lambda n: next((a for a, b in jobs if a <= n <= b), -n)

    def _action_builds(self, rel, text, start_dir):
        """docker/build-push-action steps -> builds, like a `docker build` line. Its default
        context is the Git context (the commit fetched again, not the runner's workspace;
        github.com/docker/build-push-action "Git context"), so a file an earlier step wrote
        reaches the image only when `context:` names a path."""
        lines, out = text.splitlines(), []
        for i, line in enumerate(lines):
            if not re.search(r"uses:\s*[\"']?docker/build-push-action@", line):
                continue
            item = enclosing_item(lines, i)
            ctx = item_value(lines, item, "context") if item else None
            if ctx is None or "://" in ctx:
                continue
            env = start_dir(i + 1)[1]
            c = join_dir("", ctx, env)
            f = item_value(lines, item, "file")
            out.append((rel, i + 1, c, join_dir("", f, env) if f else
                        (posixpath.join(c, "Dockerfile") if c is not None else None)))
        return out

    def _image_leaks(self, writes, builds, scopes, flag):
        """registry.credentials.image: CI writes a credential file and a LATER build in the
        same job (same file outside GitHub) has it inside its context, uses a Dockerfile
        that copies the whole context, and has no .dockerignore line excluding it.

        WHY each link (each one a false finding seen in review): a job's files exist only
        on its own runner; a path outside the context (../.npmrc, ~/.npmrc) never reaches
        the daemon; `COPY --from=<stage> .` reads another stage; .dockerignore is matched
        on the path inside the context, root-anchored, last match winning (dockerignored()),
        and Docker prefers <Dockerfile>.dockerignore next to the Dockerfile (BuildKit)."""
        for rel, n, cred, path in writes:
            if path is None:
                continue
            scope = scopes.get(rel, lambda _n: 0)
            for brel, bn, ctx, dfile in builds:
                if brel != rel or bn <= n or ctx is None or dfile is None or scope(bn) != scope(n):
                    continue
                inside = path if ctx == "" else (path[len(ctx) + 1:] if path.startswith(ctx + "/") else None)
                df = self.root / dfile
                if inside is None or not df.is_file() or not copies_context(read_text(df)):
                    continue
                ign = self.root / (dfile + ".dockerignore")
                ign = ign if ign.is_file() else self.root / ctx / ".dockerignore"
                if dockerignored((read_text(ign) or "").splitlines() if ign.is_file() else [], inside):
                    continue
                flag("registry.credentials.image", rel, n,
                     f"CI writes {cred} into the Docker build context ({path}), the build at line {bn} copies the "
                     f"whole context ({dfile}) and .dockerignore does not exclude it - the credentials ship inside the image",
                     f"pass the credential as a step env (COMPOSER_AUTH / NODE_AUTH_TOKEN) instead of a file, "
                     f"add {inside} to .dockerignore, and rotate credentials already pushed in images", "error")
                break

    def _ship_scope(self, rel, kind, text):
        """line number -> does what that line installs ship? Only deploy.composer.dev asks.

        WHY per job for GitHub Actions: each job starts on a fresh runner and passes files
        to another job only through explicit artifact actions (docs.github.com, "workflow
        artifacts": they "pass files between jobs in a workflow"). A test or lint job's
        `composer install` therefore never becomes the vendor/ a deploy job ships. The
        common fed / bed ("Backend Test") / tag / deploy template lints in one job and ships
        from another with --no-dev; judging the file whole flagged the lint job in every
        repo that used it (27 of 27 in one sweep, all false).

        WHY GitLab CI, Bitbucket Pipelines and the rest stay whole-file: there a later job
        or step receives every earlier artifact by default (GitLab: "later jobs fetch a copy
        of all artifacts from jobs in earlier stages"; Bitbucket downloads all unless a step
        sets `download: false`), and jobs inherit commands through `extends:`, `default:`
        and YAML anchors, so a job's own block is not what it runs. Splitting those needs
        artifact and inheritance tracking, which is not worth it here.

        Known gap: a GitHub job that uploads vendor/ as an artifact for a shipping job is
        not followed - each job is read alone.
        """
        if kind == "deploy":
            return lambda _n: True  # Dockerfiles and appspec hooks always build production
        def ships_text(t):
            return bool(DEPLOY_MARKERS.search(t)) and not TEST_MARKERS.search(t)
        jobs = workflow_jobs(text) if rel.startswith(".github/workflows/") else None
        if jobs is None:
            whole = ships_text(text)
            return lambda _n: whole
        lines = text.splitlines()
        verdicts = [(a, b, ships_text("\n".join(lines[a - 1:b]))) for a, b in jobs]
        return lambda n: next((v for a, b, v in verdicts if a <= n <= b), False)

    def _start_dirs(self, rel, kind, text):
        """key line -> (directory its command block starts in, env) where the directory is
        repo-relative ("" = the root, None = unknown); a `cd` then moves it (deploy()).

        WHY only CI files are placed: a Dockerfile's WORKDIR and an appspec hook's working
        directory are paths in the image or on the server, not in the repo. GitHub Actions
        starts a step in its `working-directory:`, else the job's `defaults.run.working-
        directory`; every other CI system starts scripts at the checkout root. A value is
        resolved only when literal or `${{ env.X }}` from the workflow or job `env:` block
        (contexts those keys may use: docs.github.com, Contexts, "Context availability");
        anything else (matrix, inputs, step outputs) leaves the directory unknown, never
        guessed. Known gap: workflow-level `defaults.run` and step-level `env:` are not read.
        """
        if kind != "ci":
            return lambda _k: (None, {})
        if not rel.startswith(".github/workflows/"):
            return lambda _k: ("", {})
        lines = text.splitlines()
        doc = mini_yaml(text)
        top_env, job_cfg = obj(doc.get("env")), obj(doc.get("jobs"))
        jobs = workflow_jobs(text) or []

        def start(k):
            name = next((lines[a - 1].strip().rstrip(":").strip("'\"") for a, b in jobs if a <= k <= b), None)
            job = obj(job_cfg.get(name))
            env = {**top_env, **obj(job.get("env"))}
            item = enclosing_item(lines, k - 1)
            wd = item_value(lines, item, "working-directory") if item else None
            if wd is None:
                wd = dig(job, "defaults", "run", "working-directory")
            return ("" if wd is None else join_dir("", wd, env)), env
        return start

    def _setup_pins(self):
        """Literal versions handed to actions/setup-node (node-version) and
        shivammathur/setup-php (php-version) in GitHub workflows -> [(src, tool, value)].
        Only those keys of those actions: another action's look-alike input is not the
        runtime CI builds on. An expression (${{ matrix.node }}) or a list is not a pin, and
        node-version-file points at a file the pin checks already read."""
        out = []
        wanted = {"node-version": "actions/setup-node", "php-version": "shivammathur/setup-php"}
        for g in (".github/workflows/*.yml", ".github/workflows/*.yaml"):
            for p in sorted(self.root.glob(g)):
                lines = (read_text(p) or "").splitlines()
                for i, line in enumerate(lines):
                    m = re.match(r"^\s*(node-version|php-version)\s*:\s*(.*)$", line)
                    if not m:
                        continue
                    v = scalar(m.group(2))
                    if not v or v.startswith(("$", "[", "{")):
                        continue
                    item = enclosing_item(lines, i)
                    uses = (item_value(lines, item, "uses") or "") if item else ""
                    if uses.split("@")[0].lower() == wanted[m.group(1)]:
                        out.append((f"{rel(self.root, p)}:{i + 1} {m.group(1)}", m.group(1).split("-")[0], v))
        return out

    def _berry(self, d):
        """Is the Yarn of package root d (repo-relative) Yarn 2+? Its yarn.lock format
        decides, else its packageManager pin."""
        p = self.root / d
        lock = (read_text(p / "yarn.lock") or "") if (p / "yarn.lock").is_file() else ""
        pkg = self.pkg if not d else (read_json(p / "package.json") if (p / "package.json").is_file() else None)
        pm = str(pkg.get("packageManager") or "") if isinstance(pkg, dict) else ""
        return "__metadata:" in lock[:2000] or bool(re.match(r"yarn@[2-9]", pm))

    def _lock_root(self, d, family):
        """The package root (repo-relative) whose lockfile an install in d uses: d when it has
        one, else the nearest enclosing npm / Yarn / pnpm workspace root that lists d as a
        member and has a lockfile, else None. WHY: a workspace member shares the root's
        lockfile (npm and Yarn always; pnpm unless sharedWorkspaceLockfile is false), so
        asking it for its own reported every monorepo app as unlocked. Composer has no
        workspaces: a path repository keeps its own composer.lock."""
        locks = ("composer.lock",) if family == "php" else tuple(JS_LOCKFILES)
        has = lambda x: any((self.root / x / f).is_file() for f in locks)  # noqa: E731
        if has(d):
            return d
        parts = d.split("/") if d and family == "js" else []
        for k in range(len(parts) - 1, -1, -1):
            anc, member = "/".join(parts[:k]), "/".join(parts[k:])
            if has(anc) and self._workspace_member(anc, member):
                return anc
        return None

    def _workspace_member(self, anc, member):
        """Does the workspace rooted at anc list member (a path relative to anc)? pnpm reads
        pnpm-workspace.yaml `packages:`; npm and Yarn read package.json `workspaces` (a list,
        or {packages: [...]}). Globs as in those files, a leading ! excluding."""
        root = self.root / anc

        def listed(pats):
            hit = lambda p: bool(glob_rx(re.sub(r"^\./", "", p.strip()).rstrip("/")).match(member))  # noqa: E731
            pats = [p for p in pats if isinstance(p, str)]
            return (any(hit(p) for p in pats if not p.startswith("!"))
                    and not any(hit(p[1:]) for p in pats if p.startswith("!")))

        ws = root / "pnpm-workspace.yaml"
        if ws.is_file():
            text = read_text(ws) or ""
            shared = not re.search(r"^sharedWorkspaceLockfile\s*:\s*['\"]?false\b", text, re.M) and not re.search(
                r"^\s*shared-workspace-lockfile\s*=\s*false\b", read_text(root / ".npmrc") or "", re.M)
            if shared and listed(yaml_list(text, "packages")):
                return True
        w = obj(read_json(root / "package.json") if (root / "package.json").is_file() else None).get("workspaces")
        w = w if isinstance(w, list) else obj(w).get("packages")
        return isinstance(w, list) and listed(w)

    def _yarn_immutable_off(self, d):
        """Does Yarn 2+'s config turn CI's immutable default off for package root d?
        `enableImmutableInstalls: false` in a .yarnrc.yml there or in a parent (Yarn merges
        them, the nearest winning; yarnpkg.com/configuration/yarnrc#enableImmutableInstalls)."""
        parts = d.split("/") if d else []
        for k in range(len(parts), -1, -1):
            f = self.root.joinpath(*parts[:k], ".yarnrc.yml")
            m = re.search(r"^enableImmutableInstalls\s*:\s*(\S+)", read_text(f) or "", re.M) if f.is_file() else None
            if m:
                return scalar(m.group(1)).lower() == "false"
        return False

    def _install_line(self, tool, toks, rel, n, kind, ships, cwd, flag, env=None):
        """One package-manager invocation from a CI/deploy line -> findings. `ships`: this
        line's install ends up in what is deployed (see _ship_scope). `cwd`: the package
        root it runs in, repo-relative ("" = the root, None = unknown; see _start_dirs),
        moved by the tool's own --prefix / --dir / --cwd / --working-dir (cli_parts)."""
        # WHY deploy.install.unfrozen ignores `ships` (every CI job, not only shipping ones):
        # the managers document the frozen install for CI as a whole - npm ci is "meant to
        # be used in automated environments such as test platforms, continuous integration,
        # and deployment", Yarn 4 and pnpm freeze by default when they detect CI - and a
        # front-end job that uploads its build for the deploy job to download ships that
        # install with no deploy marker of its own. A per-job rule would miss exactly that.
        ci = kind == "ci"
        unfrozen = "deploy.install.unfrozen"
        fix = "use the frozen install: npm ci / yarn install --immutable / pnpm install --frozen-lockfile / " \
              "bun ci / composer install (references/install-semantics.md)"
        sub, idx, moved = cli_parts(tool, toks)
        if moved is not None:
            cwd = join_dir(cwd, moved, env or {})
        where = f" (in {cwd}/)" if cwd else ""
        if any(t in ("-v", "--version", "-h", "--help") for t in toks):
            return
        if any(t in LOCK_ONLY or t == "--no-install" for t in toks):
            return  # a deliberate lockfile refresh (version-bump or dependency-bot job)
        if tool == "npm" and idx is not None and sub in NPM_INSTALL and any(
                t in ("-g", "--global") or t.startswith("--location=global") for t in toks):
            # a tool install: never the project's lockfile
            self._global_install(sub, toks[:idx] + toks[idx + 1:], rel, n, flag)
            return
        family = "php" if tool == "composer" else "js"
        installs = {"npm": sub in NPM_INSTALL + NPM_CI, "yarn": sub in ("", "install"),
                    "pnpm": sub in ("install", "i", "ci"), "bun": sub in ("install", "i", "ci")
                    }.get(tool, sub in ("install", "i"))
        lock_root = self._lock_root(cwd, family) if cwd is not None else None
        if installs:
            self.installs.append({"family": family, "manager": "composer" if family == "php" else tool, "cwd": cwd,
                                  "kind": kind, "file": rel, "line": n, "cmd": " ".join([tool] + toks[:3])})
            manifest = "composer.json" if family == "php" else "package.json"
            pdir = self.root / cwd if cwd else None
            # WHY nested only: a root without its lockfile is already js/php.lockfile.missing.
            # Supersedes unfrozen: with no lockfile there, "use npm ci" would fail too.
            if pdir and (pdir / manifest).is_file() and lock_root is None:
                what = ("npm ci fails without one" if tool == "npm" and sub in NPM_CI
                        else "every run resolves its dependencies fresh")
                flag("deploy.install.unlocked", rel, n,
                     f"`{' '.join([tool] + ([sub] if sub else []))}` in {rel} runs in {cwd}/, which has a {manifest} but "
                     f"no lockfile - {what}",
                     f"install once in {cwd}/ with the repo's manager, commit the lockfile, then use the frozen install there "
                     "(references/install-semantics.md#the-one-table)")
                return
        if tool == "npm" and (sub in NPM_INSTALL or sub in NPM_CI):
            yarn_flag = next((t.split("=")[0] for t in toks if t.split("=")[0] in YARN_FREEZE_FLAGS), None)
            if yarn_flag:
                # Its own id, an error: npm 12 (`latest`) refuses the command outright.
                older = ("npm up to 11 ignores the flag (11.2+ warns \"Unknown cli config\") and installs unfrozen"
                         if sub in NPM_INSTALL else
                         "npm up to 11 ignores it (11.2+ warns \"Unknown cli config\"); npm ci is frozen without it")
                flag("deploy.npm.yarn-flag", rel, n,
                     f"`npm {sub} {yarn_flag}` in {rel}: {yarn_flag} is a Yarn flag, not npm's - npm 12 refuses the "
                     f"command (EUNKNOWNCONFIG), so the build fails; {older}",
                     ("use npm ci, which installs exactly package-lock.json" if sub in NPM_INSTALL
                      else f"drop {yarn_flag}: npm ci is already frozen to package-lock.json")
                     + " (references/install-semantics.md#npm-ci-versus-npm-install)", "error")
            elif sub in NPM_INSTALL:
                # Bare or `npm install <pkg>`: both resolve and can rewrite the lockfile.
                flag(unfrozen, rel, n, f"`npm {sub}` in {rel}{where} can rewrite the lockfile and resolve new versions", fix)
        elif tool == "yarn" and installs:
            # Yarn 2+ freezes by itself on CI unless --no-immutable or its own config says not to.
            home = lock_root if lock_root is not None else (cwd or "")
            off = self._yarn_immutable_off(home) or "--no-immutable" in toks
            frozen = any(t in ("--frozen-lockfile", "--immutable") for t in toks) or (ci and self._berry(home) and not off)
            if not frozen:
                cmd = ("yarn " + " ".join(toks[:2])).strip()
                why = (" - .yarnrc.yml sets enableImmutableInstalls: false, so CI does not freeze it"
                       if self._yarn_immutable_off(home) and self._berry(home) else "")
                flag(unfrozen, rel, n, f"`{cmd}` in {rel}{where} without --frozen-lockfile/--immutable{why}", fix)
        elif tool == "pnpm" and sub in ("install", "i"):
            if "--no-frozen-lockfile" in toks or (not ci and "--frozen-lockfile" not in toks):
                flag(unfrozen, rel, n, f"`pnpm {sub}` in {rel}{where} is not frozen here (pnpm freezes by default only on CI)", fix)
        elif tool == "bun" and sub in ("install", "i"):
            if not any(t in ("--frozen-lockfile", "--production") for t in toks):
                flag(unfrozen, rel, n, f"`bun {sub}` in {rel}{where} without --frozen-lockfile (Bun never freezes on its own)", fix)
        elif tool == "composer":
            if sub in ("update", "u", "upgrade", "require", "remove"):
                flag(unfrozen, rel, n, f"`composer {sub}` in {rel}{where} resolves new versions instead of installing the lock", fix)
            elif sub in ("install", "i") and ships and "--no-dev" not in toks:
                flag("deploy.composer.dev", rel, n, f"`composer {sub}` without --no-dev in a deploy ({rel}) ships dev packages",
                     "add --no-dev --optimize-autoloader (references/install-semantics.md#deploy-patterns)")

    def _global_install(self, sub, toks, rel, n, flag):
        """`npm install -g <pkg>...` in CI or a deploy. WHY flagged: it leaves the lockfile
        alone (so deploy.install.unfrozen rightly skips it), but each run installs whatever
        is newest for that spec - the exposure of an unpinned npx, with the same checks: an
        exact version or a $VARIABLE pin passes and a native CLI is npx.native-cli. PKG_SPEC
        rejects paths, tarball URLs (with or without credentials in them), git and alias
        specs, which are not registry fetches. toks: every argument but the subcommand."""
        pkgs, skip = [], False
        for t in toks:
            if skip or t in GLOBAL_FLAG_WITH_VALUE:
                skip = not skip  # the flag's value is not a package
                continue
            p = t.strip("'\"")
            if not p.startswith("-") and PKG_SPEC.match(p):
                pkgs.append(p)
        unpinned = []
        for p in pkgs:
            base, ver = split_spec(p)
            if base.lower() in self.native:
                flag("npx.native-cli", rel, n,
                     f"a global npm install of {p} in {rel} routes a native CLI through the npm registry - the npm name is not the tool's official channel",
                     f"install {base} from its own channel (winget/brew/apt/cargo) and call it directly", "error")
            elif not (EXACT_SEMVER.match(ver) or ver.startswith("$")):
                unpinned.append(p)
        if unpinned:
            flag("deploy.global.unpinned", rel, n,
                 f"a global npm install of {', '.join(unpinned)} in {rel} fetches the newest matching version on every run",
                 f"pin it: npm {sub} -g {split_spec(unpinned[0])[0]}@<exact version> (references/npx-exec-safety.md#the-rules)")

    def _ramsey(self, text, rel, ships, flag):
        """ramsey/composer-install is `composer install` (or update) behind action inputs."""
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if not re.search(r"uses:\s*[\"']?ramsey/composer-install", line):
                continue
            indent = len(line) - len(line.lstrip(" -"))
            opts, versions = "", "locked"
            for nxt in lines[i + 1:]:
                if nxt.strip() and (len(nxt) - len(nxt.lstrip(" "))) <= indent - 2 and nxt.lstrip().startswith("-"):
                    break
                m = re.match(r"\s*composer-options:\s*[\"']?(.*?)[\"']?\s*$", nxt)
                opts = m.group(1) if m else opts
                m = re.match(r"\s*dependency-versions:\s*[\"']?(\w+)", nxt)
                versions = m.group(1) if m else versions
            if versions in ("highest", "lowest"):
                flag("deploy.install.unfrozen", rel, i + 1,
                     f"ramsey/composer-install with dependency-versions: {versions} runs `composer update` in {rel}",
                     "drop dependency-versions (default: locked) so CI installs the lock")
            elif ships(i + 1) and "--no-dev" not in opts.split():
                flag("deploy.composer.dev", rel, i + 1,
                     f"ramsey/composer-install without --no-dev in a deploy ({rel}) ships dev packages",
                     'set composer-options: "--no-dev --optimize-autoloader" (references/install-semantics.md#deploy-patterns)')

    # ---- legacy tools ----
    def legacy(self):
        for f in ("bower.json", ".bowerrc"):
            if (self.root / f).is_file():
                self.add("warn", "legacy.bower", f, "Bower manifest - Bower is a legacy front-end manager",
                         "move each Bower package to npm (references/legacy-exits.md)")
                break
        if self.pkg and "node-sass" in self._declared():
            self.add("warn", "legacy.node-sass", "package.json",
                     "node-sass is deprecated and does not build on current Node",
                     "replace with sass (Dart Sass); sass-loader picks it up (references/legacy-exits.md)")

    # ---- committed registry credentials (values never printed) ----
    def secrets(self):
        for f, pat in ((".npmrc", r"(_authToken|_auth|_password)\s*=\s*(\S+)"),
                       (".yarnrc.yml", r"(npmAuthToken|npmAuthIdent)\s*:\s*(\S+)")):
            t = read_text(self.root / f) if (self.root / f).is_file() else None
            for n, line in enumerate((t or "").splitlines(), 1):
                if line.lstrip().startswith(("#", ";")):
                    continue
                m = re.search(pat, line)
                value = m.group(2).strip().strip("'\"") if m else ""
                # An empty value (`_authToken=""`) holds no token, and ${...} is a reference.
                if m and value and not value.startswith("${"):
                    self.add("error", "registry.token.committed", f, f"literal {m.group(1)} on line {n} (value not shown)",
                             "revoke the token, replace it with an env reference like ${NPM_TOKEN}", n)
        if (self.root / "auth.json").is_file():
            # WHY git decides when it can: a tracked file is committed whatever .gitignore
            # says, and git knows every ignore source (.git/info/exclude, the global
            # excludesFile). Outside a work tree (an export, a test fixture) the root
            # .gitignore is matched with git's own rules (gitignored()).
            tracked = git_says(self.root, "ls-files", "--error-unmatch", "--", "auth.json")
            ignored = git_says(self.root, "check-ignore", "-q", "--", "auth.json") if tracked != 0 else 1
            if ignored is None:
                ignored = 0 if gitignored((read_text(self.root / ".gitignore") or "").splitlines(), "auth.json") else 1
            if tracked == 0:
                self.add("error", "registry.authjson.committed", "auth.json",
                         "Composer auth.json at the repo root is tracked by git, so it is committed even if .gitignore lists it",
                         "revoke the credentials, `git rm --cached auth.json`, gitignore it, use COMPOSER_AUTH in CI")
            elif ignored == 0:
                self.note("registry.authjson.ignored", "auth.json", "auth.json present but gitignored (good)")
            else:
                self.add("error", "registry.authjson.committed", "auth.json",
                         "Composer auth.json at the repo root and not gitignored",
                         "revoke the credentials, gitignore auth.json, use COMPOSER_AUTH in CI")

    # ---- pnpm ignores ${...} in a registry or auth position of the project .npmrc ----
    # pnpm 11.5.3 (2026-06-10, backported to 10.34.2; GHSA-3qhv-2rgh-x77r, pnpm.io/npmrc)
    # stopped expanding env placeholders in a repository-controlled .npmrc in these
    # positions: registry, @scope:registry, proxy URLs, any //host/ key, and the credential
    # keys below. The setting is dropped with only a warning, so a committed
    # `//host/:_authToken=${NPM_TOKEN}` silently stops authenticating. npm still expands it,
    # so this fires only when pnpm is the repo's manager: pnpm-lock.yaml at the root, or
    # packageManager naming pnpm with no other JS lockfile (a mismatch is its own finding).
    # Keys compare lower-cased with '-' dropped (https-proxy == httpsProxy). A commented-out
    # line never matches: its key starts with '#' or ';'. Only the key name is reported,
    # never the line's value.
    def pnpm_placeholders(self):
        no_expand = {"registry", "proxy", "httpproxy", "httpsproxy", "_authtoken", "_auth",
                     "_password", "username", "tokenhelper", "cert", "key"}
        lockfiles = [n for n in self.meta["lockfiles"] if n in JS_LOCKFILES]
        pm = str(self.pkg.get("packageManager") or "") if isinstance(self.pkg, dict) else ""
        if "pnpm-lock.yaml" not in lockfiles and not (pm.startswith("pnpm@") and not lockfiles):
            return
        text = read_text(self.root / ".npmrc") if (self.root / ".npmrc").is_file() else None
        for n, line in enumerate((text or "").splitlines(), 1):
            s = line.strip()
            if "=" not in s or "${" not in s:
                continue
            key = s.split("=", 1)[0].strip()
            name = key.rsplit(":", 1)[-1] if key.startswith("//") else key
            norm = name.lower().replace("-", "")
            if key.startswith("//") or norm in no_expand or (key.startswith("@") and norm.endswith(":registry")):
                self.add("warn", "registry.pnpm.placeholder-ignored", ".npmrc",
                         f"`{name}` on line {n} uses a ${{...}} placeholder; pnpm 11.5.3+ and 10.34.2+ ignore it "
                         "in a project .npmrc with only a warning, so the setting silently drops out",
                         "move the token out of the repo: `pnpm config set //host/:_authToken \"$NPM_TOKEN\"`, "
                         "the user's ~/.npmrc, or a pnpm_config_ env var; write a non-secret registry or proxy URL "
                         "literally (references/registries-and-auth.md)", n)


def load_facts(path: Path) -> dict:
    """The facts catalogue, shape-checked: a JSON object with the facts/v1 schema whose
    sections the audit reads (node, php, composer, native_cli_names, and the two release
    tables) are objects. Exit 3 when missing or unreadable, 4 when not that shape."""
    if not path.is_file():
        print(f"error: facts file not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        print(f"error: cannot read facts {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        data = json.loads(text)
        if not isinstance(data, dict):
            raise ValueError(f"top level is {type(data).__name__}, not an object")
        if data.get("schema") != FACTS_SCHEMA:
            raise ValueError(f"schema {data.get('schema')!r} != {FACTS_SCHEMA!r}")
        for key in ("node", "php", "composer", "native_cli_names"):
            if key in data and not isinstance(data[key], dict):
                raise ValueError(f"{key} must be an object")
        for key in ("node", "php"):
            if "releases" in obj(data.get(key)) and not isinstance(data[key]["releases"], dict):
                raise ValueError(f"{key}.releases must be an object")
        return data
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"error: could not parse facts {path}: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNPARSEABLE)


def safe_streams():
    """WHY: stdout piped on Windows defaults to the ANSI code page (cp1252), and one finding
    naming a non-ASCII file raised UnicodeEncodeError halfway through the report. stdout
    is data, so it is UTF-8 always; stderr keeps the console's encoding but escapes what it
    cannot encode. Streams a caller replaced (io.StringIO) have no reconfigure."""
    for stream, kw in ((sys.stdout, {"encoding": "utf-8", "errors": "backslashreplace"}),
                       (sys.stderr, {"errors": "backslashreplace"})):
        reconfigure = getattr(stream, "reconfigure", None)
        try:
            if reconfigure:
                reconfigure(**kw)
        except ValueError:
            pass


def main(argv: list[str]) -> int:
    safe_streams()
    p = argparse.ArgumentParser(
        prog="pm-audit.py",
        description="Read-only package-manager audit of a repo root (lockfiles, Node/PHP pins, npx, legacy tools).",
        epilog="Examples:\n"
               "  bash scripts/run-python.sh scripts/pm-audit.py .\n"
               "  bash scripts/run-python.sh scripts/pm-audit.py --json path/to/repo | jq -r '.data[].id'\n"
               "  bash scripts/run-python.sh scripts/pm-audit.py --no-docs --as-of 2026-10-05 path/to/repo\n\n"
               "Exit: 0 clean, 2 usage, 3 path/facts missing, 4 facts unparseable, 10 findings",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("path", help="repo root to audit")
    p.add_argument("--json", action="store_true", help="emit the JSON envelope")
    p.add_argument("--no-docs", action="store_true", help="skip the npx scan of docs and scripts (package.json scripts still checked)")
    p.add_argument("--as-of", default=None, help="date for end-of-life checks (default: today, UTC)")
    p.add_argument("--facts", default=str(DEFAULT_FACTS), help="facts catalogue JSON (EOL tables, native CLI names)")
    p.add_argument("--limit", type=int, default=50, help="max npx.unpinned findings to report (default 50)")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    try:
        as_of = dt.date.fromisoformat(args.as_of) if args.as_of else dt.datetime.now(dt.timezone.utc).date()
    except ValueError:
        print(f"error: --as-of wants YYYY-MM-DD, got {args.as_of!r}", file=sys.stderr)
        return EX_USAGE
    if args.limit < 1:
        print("error: --limit must be >= 1", file=sys.stderr)
        return EX_USAGE
    root = Path(args.path).expanduser()
    if not root.is_dir():
        msg = f"not a directory: {args.path}"
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": msg, "details": {}}}))
        print(f"error: {msg}", file=sys.stderr)
        return EX_NOTFOUND
    root = root.resolve()
    facts = load_facts(Path(args.facts))
    a = Audit(root, facts, as_of, not args.no_docs, args.limit).run()
    sev_rank = {"error": 0, "warn": 1}
    a.findings.sort(key=lambda f: (sev_rank.get(f["severity"], 2), f["id"], f["file"]))
    print(f"pm-audit: {root.name} (as of {as_of.isoformat()})", file=sys.stderr)
    if args.json:
        print(json.dumps({"data": a.findings,
                          "meta": {"schema": SCHEMA, "root": root.name, "as_of": as_of.isoformat(),
                                   "count": len(a.findings), "notes": a.notes, **a.meta}}, indent=2))
    else:
        for f in a.findings:
            loc = f["file"] + (f":{f['line']}" if f.get("line") else "")
            print("\t".join([f["severity"], f["id"], loc, f["message"], f["fix"]]))
    for n in a.notes:
        print(f"  note  {n['id']}  {n['file']}: {n['message']}", file=sys.stderr)
    managers = ", ".join(a.meta["managers"]) or "none"
    if a.findings:
        print(f"pm-audit: {len(a.findings)} finding(s); managers: {managers}", file=sys.stderr)
        return EX_FINDINGS
    print(f"pm-audit: clean; managers: {managers}", file=sys.stderr)
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
