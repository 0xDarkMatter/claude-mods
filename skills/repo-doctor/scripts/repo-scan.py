#!/usr/bin/env python3
"""repo-scan - deterministic, read-only deep scan of a local checkout into sourced facts.

Usage:   repo-scan.py [--repo PATH] [--only SECTIONS] [--max-commits N] [--no-tokei]
                      [--dir FOLDER ...] [--json]
Input:   a local directory. A git checkout gets the full scan; a plain directory skips
         history. No network. Never writes anything.
Output:  --json: {"data": {...}, "meta": {"schema": "claude-mods.repo-doctor.repo-scan/v1",
         "sections": [...]}} on stdout. Every fact carries a "source": "path:line",
         "path", or "cmd: <command>". data.candidates[] holds landmine CANDIDATES: owner
         questions mined from history and layout, never asserted facts. Without --json:
         a plain-text summary of the same facts.
Stderr:  progress and warnings only (never data)
Exit:    0 scanned, 2 usage, 3 repo path not found

Sections (--only takes a comma list; default: all):
  repo languages manifests ddev deploy ci tests generated areas outliers docs env history
  nesting gates architecture
  (candidates are always derived from whichever sections ran)
  --dir FOLDER adds that folder to data.manifests_by_dir (repeatable); workspace members
  and nesting recommendations are always in it. agents-md.py scaffold --dir uses it.

Safety:  reads git-tracked files only (a plain directory: everything but vendor and
         build dirs). Never opens secret-like files (.env, auth.json, .npmrc, keys,
         credentials); from .env.example-style files it takes variable NAMES only.
         Redacts password/secret/token/key values in every extracted command. Never
         executes repo tooling: Composer plugins, justfile backticks and make $(shell)
         all run repo code even when "listing" (agents-md-protocol.md section 9).

Examples:
  repo-scan.py --repo path/to/site --json > facts.json
  repo-scan.py --json | jq -r '.data.candidates[].question'
  repo-scan.py --only manifests,ddev,deploy --json
  repo-scan.py --max-commits 1000 --no-tokei

Doctrine: references/agents-md-protocol.md (repo-doctor skill). Consumer:
scripts/agents-md.py (scaffold, audit) reads this JSON contract.
"""
# Deliberately one file: the scan is copied standalone into other plugins and must run
# with nothing beside it. Do not split it into modules. tests/run.sh copies this file
# alone into a temp dir and runs it (the gate for that invariant).
#
# Section map (grep "=== NAME ==="):
#   CONSTANTS       thresholds, secret denylist, generated-path rules, tool tables
#   HELPERS         source grammar, redaction, the git/subprocess runner
#   MINI YAML       stdlib block-YAML subset (appspec, DDEV, CI)
#   MINI TOML       stdlib pyproject subset
#   SCAN INVENTORY  tracked-file list, the one guarded file reader, repo + languages
#   SCAN MANIFESTS  package.json, composer.json, Python, Makefile, justfile, workspaces
#   SCAN DDEV DEPLOY CI   DDEV config/hooks/commands, appspec hooks + their scripts, CI
#   SCAN LAYOUT     tests, generated output, code areas, size outliers, docs, env names
#   SCAN HISTORY    co-change coupling, hot spots, fix/revert clusters, config follow-ups
#   SCAN ENTRY DOCS nesting advice, invariant gates, architecture map, generated docs
#   CANDIDATES      landmine questions derived from all of the above
#   CLI             text summary, argument parsing

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from itertools import combinations
from pathlib import Path

# === CONSTANTS ===

SCHEMA = "claude-mods.repo-doctor.repo-scan/v1"
SECTIONS = ("repo", "languages", "manifests", "ddev", "deploy", "ci", "tests",
            "generated", "areas", "outliers", "docs", "env", "history", "nesting",
            "gates", "architecture")
MAX_READ_BYTES = 2_000_000
OUTLIER_LINES = 800          # agentic-quality: >800 lines needs a split or a guard comment
HISTORY_BULK = 40            # commits touching more files are reformat/merge noise
COUPLING_SUPPORT = 3         # min commits a pair must share
COUPLING_JACCARD = 0.70      # together / commits touching either
FOLLOWUP_WINDOW = 3          # a config edit "is followed by" changes within N commits
# These thresholds encode the protocol's bias toward local contracts, not folder size:
# changing them alters when a generated root router delegates to nested entry docs.
MIN_NEST_FILES = 15
MIN_NEST_CONTRACT_POINTS = 4
MIN_NEST_CONTRACT_SIGNALS = 2
FARM_MIN_SIBLINGS = 8
NEST_CHURN_RATIO = 0.15

# Secret-like basenames are never opened, even when tracked. .env.example-style files
# are read for variable NAMES only (ENV_EXAMPLE_RE wins over SECRET_NAME_RE).
SECRET_NAME_RE = re.compile(r"""(?ix)^(
    \.env(\..+)? | auth\.json | \.npmrc | \.yarnrc(\.yml)? | \.pypirc | \.netrc |
    \.pgpass | \.htpasswd | \.git-credentials | \.dockercfg |
    id_(rsa|dsa|ecdsa|ed25519)(\.pub)? | credentials(\.json|\.ya?ml)? |
    secrets?\.(json|ya?ml|toml|php|env|ini) | service[-_]account.*\.json |
    config\.local\.ya?ml |
    .+\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk|tfvars|tfstate) )$""")
ENV_EXAMPLE_RE = re.compile(r"(?i)^\.env\.(example|dist|sample|template|defaults)(\..+)?$")

_SECRET_WORD = r"[\w.-]*(?:pass(?:word|wd)?|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth)[\w.-]*"
REDACT_ASSIGN = re.compile(r"(?i)\b(" + _SECRET_WORD + r")(=|:[ \t]*)([\"']?)(?![$%{<])([^\s\"']+)\3")
REDACT_FLAG = re.compile(r"(?i)(--?" + _SECRET_WORD + r")([ \t]+)([\"']?)(?![$%{<-])([^\s\"']+)\3")

LOCKFILES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
             "composer.lock", "poetry.lock", "uv.lock", "Pipfile.lock", "Gemfile.lock",
             "Cargo.lock", "go.sum", "npm-shrinkwrap.json"}
SOURCE_EXTS = {".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte",
               ".php", ".twig", ".go", ".rs", ".rb", ".java", ".cs", ".c", ".cc", ".cpp",
               ".h", ".hpp", ".sh", ".ps1", ".sql", ".css", ".scss", ".sass", ".less",
               ".pcss", ".html", ".astro", ".kt", ".swift"}
EXT_LANG = {".py": "Python", ".ts": "TypeScript", ".tsx": "TypeScript", ".js": "JavaScript",
            ".jsx": "JavaScript", ".mjs": "JavaScript", ".cjs": "JavaScript", ".vue": "Vue",
            ".svelte": "Svelte", ".php": "PHP", ".twig": "Twig", ".go": "Go", ".rs": "Rust",
            ".rb": "Ruby", ".java": "Java", ".cs": "C#", ".c": "C", ".cc": "C++",
            ".cpp": "C++", ".h": "C", ".hpp": "C++", ".sh": "Shell", ".ps1": "PowerShell",
            ".sql": "SQL", ".css": "CSS", ".scss": "Sass", ".sass": "Sass", ".less": "Less",
            ".pcss": "CSS", ".html": "HTML", ".astro": "Astro", ".kt": "Kotlin",
            ".swift": "Swift", ".md": "Markdown", ".yml": "YAML", ".yaml": "YAML",
            ".json": "JSON", ".toml": "TOML", ".xml": "XML"}
GENERATED_MARK = re.compile(r"@generated|do not edit|don'?t hand-edit|auto-?generated|generated by",
                            re.I)
# Path families that are build output, vendored code or tool state. Each rule:
# (regex on the repo-relative path, group-root regex, reason).
GENERATED_RULES = (
    (r"(^|/)node_modules/", r"^(.*?node_modules/)", "vendored dependencies (node_modules)"),
    (r"(^|/)vendor/", r"^(.*?vendor/)", "vendored dependencies (vendor)"),
    (r"(^|/)mix-manifest\.json$", r"^(.*mix-manifest\.json)$", "Laravel Mix manifest"),
    (r"(^|/)\.vite/manifest\.json$", r"^(.*\.vite/manifest\.json)$", "Vite manifest"),
    (r"^(web|public|static|wwwroot|www|html)/(dist|build|bundles?)/",
     r"^([^/]+/[^/]+/)", "build output dir"),
    (r"^(dist|build|out|_site|\.next|\.nuxt|\.output|storybook-static)/",
     r"^([^/]+/)", "build output dir"),
    (r"\.min\.(js|css)$", r"^(.*/)?", "minified asset"),
    (r"\.(js|css)\.map$", r"^(.*/)?", "source map"),
)
BUILD_IGNORE_RE = re.compile(r"(?i)^/?(node_modules|vendor|dist|build|out|_site|\.next|\.nuxt|"
                             r"\.vite|mix-manifest\.json|(web|public|static)/(dist|build|bundles?|"
                             r"assets/dist|cpresources))/?\*?$")
MIGRATION_RE = re.compile(r"(^|/)(migrations?|database/migrations|db/migrate)/", re.I)
PROJECT_CONFIG_RE = re.compile(r"^config/project/")
CONFIG_RE = re.compile(
    r"(^|/)(webpack\.mix|vite\.config|webpack\.config|tailwind\.config|postcss\.config|"
    r"babel\.config|svelte\.config|nuxt\.config|next\.config|astro\.config|tsconfig[^/]*)"
    r"\.[a-z]+$|^(package\.json|composer\.json|pyproject\.toml|\.nvmrc|\.ddev/config\.yaml|"
    r"docker-compose[^/]*\.ya?ml|config/[^/]+\.php|\.env\.(example|dist|sample))$")
FIX_RE = re.compile(r"(?i)^(fix|hotfix|bugfix)\b|\b(fix(es|ed)?|hotfix|bugfix)\b")
REVERT_RE = re.compile(r"(?i)^revert\b|\brevert(s|ed)?\b")
DEPLOY_STEP_RE = re.compile(r"(?i)\b(deploy|codedeploy|create-deployment|rsync|scp|"
                            r"s3 sync|kubectl|helm|wrangler|vercel|netlify|flyctl|dep deploy)\b")
CHECKISH_RE = re.compile(r"(?i)\b(test|lint|check|phpstan|phpunit|codecept|pest|pytest|vitest|"
                         r"jest|tsc|eslint|stylelint|ecs|rector|mypy|ruff|playwright|cypress)\b")
CONTAINER_DIRS = ("modules", "plugins", "packages", "apps", "services", "src", "lib",
                  "web/themes/custom", "web/modules/custom", "wp-content/themes",
                  "wp-content/plugins", "templates")
DEPLOY_SURFACES = (
    (r"^appspec\.ya?ml$", "AWS CodeDeploy"), (r"^Dockerfile$", "Docker image"),
    (r"^docker-compose[^/]*\.ya?ml$", "Docker Compose"), (r"^fly\.toml$", "Fly.io"),
    (r"^vercel\.json$", "Vercel"), (r"^netlify\.toml$", "Netlify"),
    (r"^wrangler\.(toml|jsonc?)$", "Cloudflare Workers"), (r"^Procfile$", "Procfile host"),
    (r"^serverless\.ya?ml$", "Serverless Framework"), (r"^app\.ya?ml$", "Google App Engine"),
    (r"^\.platform\.app\.yaml$", "Platform.sh"), (r"^\.upsun/config\.yaml$", "Upsun"),
    (r"^deploy\.php$", "Deployer"), (r"^Capfile$", "Capistrano"), (r"^render\.yaml$", "Render"),
    (r"^railway\.json$", "Railway"), (r"^\.elasticbeanstalk/", "Elastic Beanstalk"),
    (r"^cdk\.json$", "AWS CDK"), (r"(^|/)Chart\.yaml$", "Helm chart"),
    (r"^buddy\.ya?ml$", "Buddy"), (r"(^|/)[^/]+\.tf$", "Terraform"),
)
OTHER_CI = ((".gitlab-ci.yml", "GitLab CI"), ("bitbucket-pipelines.yml", "Bitbucket Pipelines"),
            (".circleci/config.yml", "CircleCI"), ("azure-pipelines.yml", "Azure Pipelines"),
            ("Jenkinsfile", "Jenkins"), (".travis.yml", "Travis CI"), ("buddy.yml", "Buddy"))
JS_TOOLS = {"next": "Next.js", "nuxt": "Nuxt", "astro": "Astro", "@sveltejs/kit": "SvelteKit",
            "svelte": "Svelte", "react": "React", "vue": "Vue", "@angular/core": "Angular",
            "express": "Express", "fastify": "Fastify", "hono": "Hono", "@nestjs/core": "NestJS",
            "@11ty/eleventy": "Eleventy", "gatsby": "Gatsby", "alpinejs": "Alpine.js",
            "vite": "Vite", "laravel-mix": "Laravel Mix", "webpack": "webpack",
            "parcel": "Parcel", "esbuild": "esbuild", "rollup": "Rollup", "gulp": "gulp",
            "tailwindcss": "Tailwind CSS", "typescript": "TypeScript", "jest": "Jest",
            "vitest": "Vitest", "mocha": "Mocha", "@playwright/test": "Playwright",
            "cypress": "Cypress", "eslint": "ESLint", "prettier": "Prettier",
            "stylelint": "Stylelint", "@biomejs/biome": "Biome", "husky": "husky",
            "lint-staged": "lint-staged"}
PHP_TOOLS = {"craftcms/cms": "Craft CMS", "drupal/core": "Drupal",
             "drupal/core-recommended": "Drupal", "laravel/framework": "Laravel",
             "statamic/cms": "Statamic", "roots/wordpress": "WordPress",
             "johnpbloch/wordpress": "WordPress", "symfony/framework-bundle": "Symfony",
             "silverstripe/framework": "Silverstripe", "typo3/cms-core": "TYPO3",
             "nystudio107/craft-vite": "craft-vite", "phpunit/phpunit": "PHPUnit",
             "codeception/codeception": "Codeception", "pestphp/pest": "Pest",
             "phpstan/phpstan": "PHPStan", "rector/rector": "Rector",
             "symplify/easy-coding-standard": "ECS", "friendsofphp/php-cs-fixer": "PHP-CS-Fixer",
             "squizlabs/php_codesniffer": "PHP_CodeSniffer"}
PY_TOOLS = {"django": "Django", "flask": "Flask", "fastapi": "FastAPI", "starlette": "Starlette",
            "celery": "Celery", "sqlalchemy": "SQLAlchemy", "alembic": "Alembic",
            "pytest": "pytest", "ruff": "Ruff", "mypy": "mypy", "black": "Black", "tox": "tox",
            "nox": "nox", "uvicorn": "Uvicorn", "gunicorn": "Gunicorn"}
TOOLING_CONFIGS = (
    (r"^\.prettierrc(\..+)?$|^prettier\.config\.", "Prettier"),
    (r"^eslint\.config\.|^\.eslintrc(\..+)?$", "ESLint"),
    (r"^\.stylelintrc(\..+)?$|^stylelint\.config\.", "Stylelint"), (r"^biome\.jsonc?$", "Biome"),
    (r"^phpstan\.neon(\.dist)?$", "PHPStan"), (r"^ecs\.php$", "ECS"), (r"^rector\.php$", "Rector"),
    (r"^\.php-cs-fixer(\.dist)?\.php$", "PHP-CS-Fixer"),
    (r"^\.?phpcs\.xml(\.dist)?$", "PHP_CodeSniffer"), (r"^\.?ruff\.toml$", "Ruff"),
    (r"^\.?mypy\.ini$", "mypy"), (r"^\.pre-commit-config\.yaml$", "pre-commit"),
    (r"^commitlint\.config\.|^\.commitlintrc", "commitlint"),
    (r"^\.husky/[^/_][^/]*$", "husky git hook"),
    (r"^\.lintstagedrc|^lint-staged\.config\.", "lint-staged"), (r"^tsconfig\.json$", "TypeScript"),
)
CMS_LABELS = {"Craft CMS", "Drupal", "Laravel", "Statamic", "WordPress", "Symfony",
              "Silverstripe", "TYPO3"}
# Root files that mark a static site. agents-md.py picks its static-site archetype only
# on one of these; any other repo with no web manifest gets the generic archetype.
STATIC_SITE_FILES = ((r"index\.html?", "plain HTML"), (r"mkdocs\.ya?ml", "MkDocs"),
                     (r"hugo\.(toml|ya?ml|json)", "Hugo"),
                     (r"\.eleventy\.js|eleventy\.config\.[cm]?js", "Eleventy"),
                     (r"docusaurus\.config\.(js|ts)", "Docusaurus"),
                     (r"gatsby-config\.(js|ts)", "Gatsby"))
# Test suites declared by convention, not config: shell scripts under a tests/ or
# spec/ folder, and the runner among them (run.sh, run-<x>.sh, all.sh, test.sh).
TESTS_DIR_RE = re.compile(r"(^|/)(tests?|spec)/")
SHELL_RUNNER_RE = re.compile(r"(^|/)(run([-_][\w-]+)?|all|test)\.sh$")
TEST_FILE_RE = re.compile(r"(^|/)(test_[^/]+\.py|[^/]+_test\.(py|go|rs)|[^/]+\.(test|spec)\.[jt]sx?|"
                          r"[^/]+Test\.php|[^/]+\.bats)$")
# Fixture folders hold deliberate fakes: a secret-like name there is a test input.
FIXTURE_DIR_RE = re.compile(r"(^|/)(fixtures?|__fixtures__|testdata|test[-_]data)/", re.I)

# === HELPERS ===


def eecho(msg: str) -> None:
    print(msg, file=sys.stderr)


def src(path: str, line: int | None = None) -> str:
    """Fact source grammar: 'path:line', 'path', or 'cmd: <command>'."""
    return f"{path}:{line}" if line else path


def redact(text: str) -> str:
    """Mask values after password/secret/token/key words; keeps $VAR references."""
    text = REDACT_ASSIGN.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}<redacted>{m.group(3)}", text)
    return REDACT_FLAG.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}<redacted>{m.group(3)}", text)


def is_secret_path(rel: str) -> bool:
    base = rel.rsplit("/", 1)[-1]
    return bool(SECRET_NAME_RE.match(base)) and not ENV_EXAMPLE_RE.match(base)


def line_of(text: str, needle: str, start: int = 0) -> int | None:
    """1-based line of the first occurrence of needle at/after char offset start."""
    i = text.find(needle, start)
    return text.count("\n", 0, i) + 1 if i >= 0 else None


def json_key_line(text: str, key: str, after: str | None = None) -> int | None:
    start = 0
    if after:
        m = re.search(r'"' + re.escape(after) + r'"\s*:', text)
        start = m.end() if m else 0
    m = re.compile(r'"' + re.escape(key) + r'"\s*:').search(text, start)
    return text.count("\n", 0, m.start()) + 1 if m else None


def run(cmd: list[str], cwd: Path | None = None, timeout: int = 60) -> str | None:
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def glob_match(rel: str, pattern: str) -> bool:
    return bool(re.search(pattern, rel))


# === MINI YAML ===
# A block-YAML subset parser (mappings, sequences, scalars, | and > block scalars,
# simple flow lists/maps), enough for appspec.yml, .ddev/config.yaml and CI files.
# Stdlib only on purpose: PyYAML is not guaranteed, and two parsers on two machines
# would make the scan non-deterministic. Scalars carry their 1-based source line.


class YStr(str):
    line = 0


def _ys(text: str, line: int) -> YStr:
    s = YStr(text)
    s.line = line
    return s


def yline(node) -> int | None:
    """Source line of a parsed scalar; None for anything the parser didn't produce."""
    return getattr(node, "line", None) or None


_YKEY = re.compile(r"""^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s#'"\[\]{}|>][^#]*?)\s*:(?:\s|$)""")


def _ystrip(s: str) -> str:
    quote = None
    for i, ch in enumerate(s):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'" and (i == 0 or s[i - 1] in " \t[{,:"):
            quote = ch
        elif ch == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip()
    return s.rstrip()


def _yflow_split(s: str) -> list[str]:
    parts, depth, quote, cur = [], 0, None, ""
    for ch in s:
        if quote:
            quote = None if ch == quote else quote
        elif ch in "\"'":
            quote = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
            continue
        cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def _yscalar(raw: str, line: int):
    v = raw.strip()
    while v and v[0] in "&!" and " " in v:
        v = v.split(None, 1)[1]
    if v and v[0] in "&!":
        return None
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        inner = v[1:-1]
        inner = inner.replace("''", "'") if v[0] == "'" else inner.replace('\\"', '"')
        return _ys(inner, line)
    if v.startswith("[") and v.endswith("]"):
        return [_yscalar(x, line) for x in _yflow_split(v[1:-1])]
    if v.startswith("{") and v.endswith("}"):
        out = {}
        for part in _yflow_split(v[1:-1]):
            k, _, val = part.partition(":")
            out[_yscalar(k, line)] = _yscalar(val, line)
        return out
    if v in ("", "~", "null", "Null", "NULL"):
        return None
    return _ys(v, line)


class _YParser:
    def __init__(self, text: str):
        self.lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        self.n = len(self.lines)

    def skip(self, i: int) -> int:
        while i < self.n:
            s = self.lines[i].strip()
            if s and not s.startswith("#") and s not in ("---", "..."):
                return i
            i += 1
        return i

    def ind(self, i: int) -> int:
        return len(self.lines[i]) - len(self.lines[i].lstrip(" "))

    def doc(self):
        i = self.skip(0)
        return self.block(i, self.ind(i))[0] if i < self.n else None

    def block(self, i: int, ind: int):
        s = self.lines[i].strip()
        return self.seq(i, ind) if s == "-" or s.startswith("- ") else self.mapping(i, ind)

    def seq(self, i: int, ind: int):
        out = []
        while True:
            i = self.skip(i)
            if i >= self.n or self.ind(i) != ind:
                return out, i
            s = self.lines[i].strip()
            if not (s == "-" or s.startswith("- ")):
                return out, i
            rest = s[1:].lstrip()
            if _ystrip(rest) and _YKEY.match(_ystrip(rest)):
                col = ind + (len(s) - len(rest))
                self.lines[i] = " " * col + rest
                val, i = self.mapping(i, col)
            else:
                val, i = self.value(rest, i, ind, same_indent_seq=False)
            out.append(val)

    def mapping(self, i: int, ind: int):
        out = {}
        while True:
            i = self.skip(i)
            if i >= self.n or self.ind(i) < ind:
                return out, i
            if self.ind(i) > ind:          # stray deeper line: tolerate, skip
                i += 1
                continue
            s = self.lines[i].strip()
            m = _YKEY.match(s)
            if s.startswith("- ") or not m:
                return out, i
            key = _yscalar(m.group(1), i + 1)
            val, i = self.value(s[m.end():], i, ind, same_indent_seq=True)
            out[key if key is not None else ""] = val

    def value(self, rest: str, i: int, ind: int, same_indent_seq: bool):
        r = _ystrip(rest).strip()
        if r.startswith("&") and " " not in r:
            r = ""
        if r[:1] in ("|", ">"):
            return self.block_scalar(i, ind, r[0] == "|")
        if r:
            return _yscalar(r, i + 1), i + 1
        j = self.skip(i + 1)
        if j < self.n and self.ind(j) > ind:
            return self.block(j, self.ind(j))
        if same_indent_seq and j < self.n and self.ind(j) == ind \
                and self.lines[j].strip().startswith("- "):
            return self.seq(j, ind)
        return None, i + 1

    def block_scalar(self, i: int, ind: int, literal: bool):
        j, buf, first, bind = i + 1, [], None, None
        while j < self.n:
            raw = self.lines[j]
            if not raw.strip():
                buf.append("")
                j += 1
                continue
            li = len(raw) - len(raw.lstrip(" "))
            if li <= ind or (bind is not None and li < bind):
                break
            if bind is None:
                bind, first = li, j + 1
            buf.append(raw[bind:])
            j += 1
        while buf and not buf[-1]:
            buf.pop()
        text = "\n".join(buf) if literal else " ".join(x for x in buf if x)
        return _ys(text, first or i + 1), j


def yaml_load(text: str):
    """Parse a block-YAML subset; returns None instead of raising on input it can't read."""
    try:
        return _YParser(text).doc()
    except (IndexError, ValueError, RecursionError):
        return None


def ywalk(node, key: str):
    """Yield every value stored under `key` anywhere in a parsed YAML tree."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from ywalk(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from ywalk(v, key)


def ystrings(node) -> list:
    if node is None:
        return []
    if isinstance(node, list):
        return [x for x in node if isinstance(x, str)]
    return [node] if isinstance(node, str) else []


# === MINI TOML ===
# Just enough TOML for pyproject.toml facts (tables, key lines, string arrays).
# tomllib is 3.11+ only, and one parser everywhere keeps output identical.


def toml_tables(text: str) -> dict:
    tables: dict = defaultdict(dict)
    table, pending, pkey, pline = "", None, "", 0
    for n, raw in enumerate(text.splitlines(), 1):
        line = _ystrip(raw).strip()
        if pending is not None:
            pending += " " + line
            if pending.count("[") <= pending.count("]"):
                tables[table][pkey] = (pending, pline)
                pending = None
            continue
        if not line:
            continue
        m = re.match(r"^\[\[?\s*([^\]]+?)\s*\]\]?$", line)
        if m:
            table = m.group(1).strip().replace('"', "")
            tables[table]
            continue
        m = re.match(r"""^("[^"]+"|'[^']+'|[A-Za-z0-9_.\-]+)\s*=\s*(.*)$""", line)
        if not m:
            continue
        key, val = m.group(1).strip("\"'"), m.group(2)
        if val.startswith("[") and val.count("[") > val.count("]"):
            pending, pkey, pline = val, key, n
            continue
        tables[table][key] = (val, n)
    return tables


def toml_strings(val: str) -> list[str]:
    return [a or b for a, b in re.findall(r'"([^"]*)"|\'([^\']*)\'', val)]


# === SCAN INVENTORY ===


# Manifests that are not this repo's contracts: dependency trees and test fixtures.
NOT_A_CONTRACT_RE = re.compile(r"(^|/)(node_modules|vendor|bower_components|tests?|spec|__tests__|fixtures?|"
                               r"__fixtures__|testdata|examples?)/")


def glob_member(path: str, glob: str) -> bool:
    """Workspace globs match one path segment per `*`, as npm, pnpm and yarn do; only
    `**` crosses folders. (fnmatch's `*` crosses `/`, which made a fixture deep inside a
    member a member too.)"""
    parts, gparts = path.strip("/").split("/"), glob.strip("/").split("/")
    if "**" in gparts:
        return fnmatch.fnmatchcase(path.strip("/"), glob.strip("/").replace("**", "*"))
    return len(parts) == len(gparts) and all(fnmatch.fnmatchcase(a, b) for a, b in zip(parts, gparts))


class Scan:
    def __init__(self, repo: Path, max_commits: int, use_tokei: bool):
        self.repo = repo
        self.max_commits = max_commits
        self.use_tokei = use_tokei
        self.is_git = (repo / ".git").exists() and run(["git", "-C", str(repo), "rev-parse",
                                                        "--git-dir"]) is not None
        self._files: list[str] | None = None
        self._lines: dict[str, int] | None = None
        self._marked: list[str] = []
        self._cache: dict = {}
        self.secrets_skipped: list[dict] = []
        self.extra_dirs: list[str] = []   # --dir: more folders for manifests_by_dir

    def git(self, *args: str) -> str | None:
        return run(["git", "-c", "core.quotepath=false", "-C", str(self.repo), *args])

    @property
    def files(self) -> list[str]:
        if self._files is None:
            if self.is_git:
                out = self.git("ls-files", "-z") or ""
                files = [f for f in out.split("\0") if f]
            else:
                files = []
                for root, dirs, names in os.walk(self.repo):
                    dirs[:] = sorted(d for d in dirs if d not in (".git", "node_modules",
                                                                  "vendor", ".venv", "venv"))
                    for n in names:
                        rel = os.path.relpath(os.path.join(root, n), self.repo)
                        files.append(rel.replace("\\", "/"))
            self._files = sorted(files)
            self.secrets_skipped = [{"path": f, "source": src(f)}
                                    for f in self._files if is_secret_path(f)]
        return self._files

    def has(self, rel: str) -> bool:
        return rel in self.fileset

    @property
    def fileset(self) -> set:
        if "fileset" not in self._cache:
            self._cache["fileset"] = set(self.files)
        return self._cache["fileset"]

    def read(self, rel: str) -> str | None:
        """The ONLY way the scan opens a repo file: tracked, not secret-like, bounded."""
        if is_secret_path(rel) or rel not in self.fileset:
            return None
        p = self.repo / rel
        try:
            if p.is_symlink() or p.stat().st_size > MAX_READ_BYTES:
                return None
            data = p.read_bytes()
        except OSError:
            return None
        if b"\0" in data[:4096]:
            return None
        return data.decode("utf-8", errors="replace")

    @staticmethod
    def _join(root: str, name: str) -> str:
        return f"{root.rstrip('/')}/{name}" if root else name

    def _files_under(self, root: str) -> list[tuple[str, str]]:
        """Return (repo path, path relative to root); root always names a directory."""
        prefix = root.rstrip("/") + "/" if root else ""
        return [(rel, rel[len(prefix):]) for rel in self.files if rel.startswith(prefix)]

    def generated_kind(self, rel: str) -> str | None:
        for pat, _, reason in GENERATED_RULES:
            if re.search(pat, rel):
                return reason
        return None

    def line_counts(self) -> dict[str, int]:
        """One bounded pass over tracked source files: line counts + generated markers."""
        if self._lines is None:
            self._lines = {}
            for rel in self.files:
                ext = os.path.splitext(rel)[1].lower()
                if ext not in EXT_LANG or rel.rsplit("/", 1)[-1] in LOCKFILES \
                        or self.generated_kind(rel):
                    continue
                text = self.read(rel)
                if text is None:
                    continue
                self._lines[rel] = text.count("\n") + (0 if text.endswith("\n") or not text else 1)
                if ext in SOURCE_EXTS and any(GENERATED_MARK.search(l)
                                              for l in text.splitlines()[:3]):
                    self._marked.append(rel)
        return self._lines

    # -- repo ---------------------------------------------------------------------
    def s_repo(self) -> dict:
        name, name_source = self._repo_name()
        out = {"name": name, "name_source": name_source, "is_git": self.is_git,
               "tracked_files": len(self.files),
               "source": "cmd: git ls-files" if self.is_git else "filesystem walk"}
        if self.is_git:
            out["head"] = (self.git("rev-parse", "--short", "HEAD") or "").strip() or None
            out["branch"] = (self.git("rev-parse", "--abbrev-ref", "HEAD") or "").strip() or None
            count = (self.git("rev-list", "--count", "HEAD") or "").strip()
            out["commits"] = int(count) if count.isdigit() else 0
        return out

    def _repo_name(self) -> tuple[str, str]:
        """The origin remote's name, else the main checkout's folder. A linked worktree's
        own folder is a lane name (the scaffold once titled a draft after one). Only the
        URL's last segment is kept: a remote URL can embed credentials."""
        if self.is_git:
            url = (self.git("remote", "get-url", "origin") or "").strip()
            m = re.search(r"([^/:\\]+?)(?:\.git)?/*$", url)
            if url and m:
                return m.group(1), "cmd: git remote get-url origin"
            common = (self.git("rev-parse", "--git-common-dir") or "").strip()
            if common:
                p = Path(common)
                p = (p if p.is_absolute() else self.repo / p).resolve()
                name = p.parent.name if p.name == ".git" else re.sub(r"\.git$", "", p.name)
                if name:
                    return name, "cmd: git rev-parse --git-common-dir"
        return self.repo.name, "directory name"

    # -- languages ------------------------------------------------------------------
    def s_languages(self) -> dict:
        tokei = shutil.which("tokei") if self.use_tokei else None
        if tokei:
            raw = run([tokei, "--output", "json", str(self.repo)], timeout=120)
            try:
                data = json.loads(raw) if raw else None
            except json.JSONDecodeError:
                data = None
            if isinstance(data, dict):
                rows = [{"language": k, "files": len(v.get("reports", [])),
                         "lines": int(v.get("code", 0))}
                        for k, v in data.items() if k != "Total" and isinstance(v, dict)]
                rows = [r for r in rows if r["lines"] > 0]
                rows.sort(key=lambda r: (-r["lines"], r["language"]))
                return {"metric": "code lines", "by_language": rows[:15],
                        "source": "cmd: tokei --output json"}
        agg: dict = defaultdict(lambda: [0, 0])
        for rel, n in self.line_counts().items():
            lang = EXT_LANG.get(os.path.splitext(rel)[1].lower())
            if lang:
                agg[lang][0] += 1
                agg[lang][1] += n
        rows = [{"language": k, "files": v[0], "lines": v[1]} for k, v in agg.items()]
        rows.sort(key=lambda r: (-r["lines"], r["language"]))
        return {"metric": "physical lines", "by_language": rows[:15],
                "source": "tracked files by extension (tokei not used)"}

    # === SCAN MANIFESTS ===
    def s_manifests(self) -> dict:
        return self._manifests_at("")

    def _manifests_at(self, root: str) -> dict:
        out: dict = {}
        pkg = self._package_json(root)
        if pkg:
            out["package_json"] = pkg
        comp = self._composer_json(root)
        if comp:
            out["composer_json"] = comp
        py = self._python(root)
        if py:
            out["python"] = py
        for name in ("Makefile", "makefile", "GNUmakefile"):
            path = self._join(root, name)
            if self.has(path):
                out["makefile"] = {"path": path, "targets": self._make_targets(path)}
                break
        for name in ("justfile", "Justfile", ".justfile"):
            path = self._join(root, name)
            if self.has(path):
                out["justfile"] = {"path": path, "recipes": self._just_recipes(path)}
                break
        ws = self._workspaces(root)
        if ws:
            out["workspaces"] = ws
        static = self._static_site(root)
        if static:
            out["static_site"] = static
        out["tooling_configs"] = [{"tool": tool, "path": rel, "source": src(rel)}
                                  for rel, local in self._files_under(root)
                                  for pat, tool in TOOLING_CONFIGS if re.search(pat, local)]
        editorconfig = self._join(root, ".editorconfig")
        ec = self.read(editorconfig)
        if ec:
            section, facts = "", []
            for n, line in enumerate(ec.splitlines(), 1):
                s = line.strip()
                if s.startswith("["):
                    section = s
                elif section == "[*]" and re.match(r"^indent_(style|size)\s*=", s):
                    k, v = (x.strip() for x in s.split("=", 1))
                    facts.append({"key": k, "value": v, "source": src(editorconfig, n)})
            out["editorconfig"] = facts
        return out

    def _package_json(self, root: str = "") -> dict | None:
        path = self._join(root, "package.json")
        text = self.read(path)
        if text is None:
            return None
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return {"path": path, "error": "invalid JSON"}
        if not isinstance(data, dict):
            return None
        pm, pm_src = "npm", None
        for lock, name in (("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"),
                           ("bun.lockb", "bun"), ("bun.lock", "bun"),
                           ("package-lock.json", "npm")):
            lock_path = self._join(root, lock)
            if self.has(lock_path):
                pm, pm_src = name, src(lock_path)
                break
        declared = data.get("packageManager")
        if isinstance(declared, str) and "@" in declared:
            pm = declared.split("@", 1)[0]
            pm_src = src(path, json_key_line(text, "packageManager"))
        scripts = []
        for name, cmd in (data.get("scripts") or {}).items():
            if isinstance(cmd, str):
                scripts.append({"name": name, "command": redact(cmd),
                                "source": src(path,
                                              json_key_line(text, name, after="scripts"))})
        deps = {}
        for block in ("dependencies", "devDependencies", "peerDependencies"):
            for name in (data.get(block) or {}):
                deps.setdefault(name, block)
        tools = [{"name": label, "package": dep,
                  "source": src(path, json_key_line(text, dep, after=deps[dep]))}
                 for dep, label in JS_TOOLS.items() if dep in deps]
        node = None
        for f in (".nvmrc", ".node-version"):
            node_path = self._join(root, f)
            t = self.read(node_path)
            if t and t.strip():
                node = {"version": t.strip().splitlines()[0][:20], "source": src(node_path, 1)}
                break
        engines = data.get("engines") or {}
        if not node and isinstance(engines, dict) and isinstance(engines.get("node"), str):
            node = {"version": engines["node"], "source": src(path,
                                                             json_key_line(text, "node", after="engines"))}
        return {"path": path, "name": data.get("name"),
                "description": data.get("description"),
                "package_manager": {"name": pm, "source": pm_src or "default (no lockfile)"},
                "scripts": scripts, "dependencies": sorted(deps), "tools": tools, "node": node}

    def _composer_json(self, root: str = "") -> dict | None:
        path = self._join(root, "composer.json")
        text = self.read(path)
        if text is None:
            return None
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return {"path": path, "error": "invalid JSON"}
        if not isinstance(data, dict):
            return None
        scripts = []
        for name, cmd in (data.get("scripts") or {}).items():
            if name.startswith("pre-") or name.startswith("post-"):
                kind = "event hook"
            else:
                kind = "script"
            if isinstance(cmd, list):
                cmd = " && ".join(str(c) for c in cmd)
            scripts.append({"name": name, "command": redact(str(cmd)), "kind": kind,
                            "source": src(path, json_key_line(text, name, after="scripts"))})
        req = {}
        for block in ("require", "require-dev"):
            for name in (data.get(block) or {}):
                req.setdefault(name, block)
        tools = [{"name": label, "package": dep,
                  "source": src(path, json_key_line(text, dep, after=req[dep]))}
                 for dep, label in PHP_TOOLS.items() if dep in req]
        php = (data.get("require") or {}).get("php")
        return {"path": path, "name": data.get("name"),
                "description": data.get("description"), "scripts": scripts,
                "tools": tools, "packages": sorted(req),
                "php": {"constraint": php, "source": src(path,
                                                          json_key_line(text, "php", after="require"))}
                if isinstance(php, str) else None,
                "lockfile": self.has(self._join(root, "composer.lock"))}

    def _python(self, root: str = "") -> dict | None:
        out: dict = {}
        deps: dict = {}
        path = self._join(root, "pyproject.toml")
        text = self.read(path)
        if text is not None:
            t = toml_tables(text)
            proj = t.get("project", {})
            for key in ("name", "description"):
                if key in proj:
                    out[key] = toml_strings(proj[key][0])[:1] or None
                    out[key] = out[key][0] if out[key] else None
            for table, key in (("project", "dependencies"), ("project.optional-dependencies", None),
                               ("dependency-groups", None), ("tool.poetry.dependencies", None),
                               ("tool.poetry.group.dev.dependencies", None)):
                for k, (val, line) in t.get(table, {}).items():
                    if key and k != key:
                        continue
                    names = toml_strings(val) if val.startswith("[") else [k]
                    for d in names:
                        dn = re.split(r"[\s<>=!~\[;]", d, 1)[0].lower()
                        if dn and dn != "python":
                            deps.setdefault(dn, src(path, line))
            out["scripts"] = [{"name": k, "target": toml_strings(v)[0] if toml_strings(v) else v,
                               "source": src(path, line)}
                              for k, (v, line) in sorted(t.get("project.scripts", {}).items())]
            out["tool_tables"] = sorted(k for k in t if k.startswith("tool."))
            out["path"] = path
        for f, local in self._files_under(root):
            if re.match(r"^requirements[^/]*\.(txt|in)$", local):
                for n, line in enumerate((self.read(f) or "").splitlines(), 1):
                    m = re.match(r"^\s*([A-Za-z0-9_.\-]+)", line)
                    if m and not line.lstrip().startswith(("#", "-")):
                        deps.setdefault(m.group(1).lower(), src(f, n))
        if not out and not deps and not any(self.has(self._join(root, f))
                                            for f in ("setup.py", "setup.cfg", "Pipfile",
                                                      "manage.py")):
            return None
        mgr = next(((m, src(self._join(root, f)))
                    for f, m in (("uv.lock", "uv"), ("poetry.lock", "poetry"),
                                 ("Pipfile.lock", "pipenv"), ("Pipfile", "pipenv"),
                                 ("pdm.lock", "pdm"))
                    if self.has(self._join(root, f))), None)
        out["manager"] = {"name": mgr[0], "source": mgr[1]} if mgr else None
        out["tools"] = [{"name": PY_TOOLS[d], "package": d, "source": s}
                        for d, s in sorted(deps.items()) if d in PY_TOOLS]
        out["manage_py"] = self.has(self._join(root, "manage.py"))
        out["dependencies"] = sorted(deps)
        return out

    def _make_targets(self, path: str) -> list[dict]:
        out = []
        for n, line in enumerate((self.read(path) or "").splitlines(), 1):
            m = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.\-/]*)\s*:(?![:=])", line)
            if m and "%" not in m.group(1):
                out.append({"name": m.group(1), "source": src(path, n)})
        return out

    def _just_recipes(self, path: str) -> list[dict]:
        out = []
        for n, line in enumerate((self.read(path) or "").splitlines(), 1):
            m = re.match(r"^alias\s+([\w-]+)\s*:=\s*([\w-]+)", line)
            if m:
                out.append({"name": m.group(1), "alias_of": m.group(2), "source": src(path, n)})
                continue
            m = re.match(r"^@?([A-Za-z0-9_][\w-]*)(\s+[^:=]*)?:(?!=)", line)
            if m and m.group(1) not in ("set", "export", "import", "mod"):
                out.append({"name": m.group(1), "source": src(path, n)})
        return out

    def _workspaces(self, root: str = "") -> list[dict]:
        out = []
        package_json = self._join(root, "package.json")
        text = self.read(package_json)
        if text:
            try:
                ws = json.loads(text).get("workspaces")
            except (json.JSONDecodeError, AttributeError):
                ws = None
            if isinstance(ws, dict):
                ws = ws.get("packages")
            if isinstance(ws, list) and ws:
                out.append({"tool": "npm/yarn workspaces", "globs": [str(w) for w in ws],
                            "source": src(package_json, json_key_line(text, "workspaces"))})
        pnpm_workspace = self._join(root, "pnpm-workspace.yaml")
        pw = self.read(pnpm_workspace)
        if pw:
            doc = yaml_load(pw)
            globs = ystrings(doc.get("packages") if isinstance(doc, dict) else None)
            out.append({"tool": "pnpm workspaces", "globs": list(globs),
                        "source": src(pnpm_workspace, 1)})
        for f, tool in (("lerna.json", "Lerna"), ("nx.json", "Nx"), ("turbo.json", "Turborepo"),
                        ("go.work", "Go workspace")):
            path = self._join(root, f)
            if self.has(path):
                out.append({"tool": tool, "globs": [], "source": src(path)})
        cargo_path = self._join(root, "Cargo.toml")
        cargo = self.read(cargo_path)
        if cargo and "[workspace]" in cargo:
            out.append({"tool": "Cargo workspace", "globs": [],
                        "source": src(cargo_path, line_of(cargo, "[workspace]"))})
        return out

    def _static_site(self, root: str = "") -> list[dict]:
        root_files = [(f, local) for f, local in self._files_under(root) if "/" not in local]
        out = []
        for pat, tool in STATIC_SITE_FILES:
            hit = next((f for f, local in root_files if re.fullmatch(pat, local, re.I)), None)
            if hit:
                out.append({"tool": tool, "source": src(hit)})
        # _config.yml alone is too generic a name; Jekyll also has layouts or posts.
        config = self._join(root, "_config.yml")
        if self.has(config) and any(local.startswith(("_layouts/", "_posts/"))
                                    for _, local in self._files_under(root)):
            out.append({"tool": "Jekyll", "source": src(config)})
        return out

    # === SCAN DDEV DEPLOY CI ===
    def s_ddev(self) -> dict | None:
        text = self.read(".ddev/config.yaml")
        if text is None and not any(f.startswith(".ddev/") for f in self.files):
            return None
        out: dict = {"config": None, "hooks": [], "commands": [], "web_environment_names": []}
        cfg = yaml_load(text) if text else None
        if isinstance(cfg, dict):
            facts = {}
            for key in ("name", "type", "docroot", "php_version", "webserver_type",
                        "nodejs_version", "composer_version", "corepack_enable"):
                v = cfg.get(key)
                if isinstance(v, str):
                    facts[key] = {"value": str(v), "source": src(".ddev/config.yaml", yline(v))}
            db = cfg.get("database")
            if isinstance(db, dict):
                t, v = db.get("type"), db.get("version")
                if isinstance(t, str):
                    facts["database"] = {"value": f"{t} {v or ''}".strip(),
                                         "source": src(".ddev/config.yaml", yline(t))}
            out["config"] = facts
            for name in ystrings(cfg.get("web_environment")):
                out["web_environment_names"].append(
                    {"name": name.split("=", 1)[0], "source": src(".ddev/config.yaml", yline(name))})
            hooks = cfg.get("hooks")
            if isinstance(hooks, dict):
                for event, steps in hooks.items():
                    for step in (steps if isinstance(steps, list) else []):
                        if not isinstance(step, dict):
                            continue
                        for kind, cmd in step.items():
                            if isinstance(cmd, str):
                                out["hooks"].append({"event": str(event), "kind": str(kind),
                                                     "command": redact(cmd),
                                                     "source": src(".ddev/config.yaml", yline(cmd))})
        out["other_configs"] = [f for f in self.files
                                if re.match(r"^\.ddev/config\.[^/]+\.ya?ml$", f)]
        for f in self.files:
            m = re.match(r"^\.ddev/commands/(host|web|db|[\w-]+)/([\w.\-]+)$", f)
            if not m or f.endswith((".example", ".md", ".txt")) or m.group(2).startswith("."):
                continue
            body = self.read(f) or ""
            cmd = {"name": re.sub(r"\.sh$", "", m.group(2)), "scope": m.group(1),
                   "ddev_generated": "#ddev-generated" in body, "source": src(f)}
            for n, line in enumerate(body.splitlines()[:30], 1):
                dm = re.match(r"^##\s*(Description|Usage):\s*(.*)$", line)
                if dm:
                    cmd[dm.group(1).lower()] = redact(dm.group(2).strip())
                    cmd.setdefault("source", src(f, n))
            out["commands"].append(cmd)
        return out

    def _script_commands(self, rel: str, limit: int = 30) -> list[dict]:
        body = self.read(rel)
        if body is None:
            return []
        out = []
        for n, line in enumerate(body.splitlines(), 1):
            s = line.strip()
            if not s or s.startswith(("#", "//", "REM ", "::")) or s in (
                    "fi", "then", "else", "done", "do", "esac", "{", "}", ";;") \
                    or re.match(r"^(set -|set -o|cd \"?\$\(dirname|if |elif |for |while |case |"
                                r"echo |printf |exit|return|function |local |export [A-Z_]+=\$)", s):
                continue
            out.append({"command": redact(s), "source": src(rel, n)})
            if len(out) >= limit:
                break
        return out

    def s_deploy(self) -> dict:
        out: dict = {"appspec": None, "surfaces": [], "ci_deploy_steps": []}
        for name in ("appspec.yml", "appspec.yaml"):
            text = self.read(name)
            if text is None:
                continue
            spec = yaml_load(text) or {}
            hooks = []
            for event, entries in (spec.get("hooks") or {}).items() if isinstance(spec, dict) else []:
                for e in entries if isinstance(entries, list) else []:
                    loc = e.get("location") if isinstance(e, dict) else None
                    if not isinstance(loc, str):
                        continue
                    script = loc.lstrip("/").lstrip("./")
                    hooks.append({"event": str(event), "location": str(loc),
                                  "runas": str(e.get("runas")) if e.get("runas") else None,
                                  "timeout": str(e.get("timeout")) if e.get("timeout") else None,
                                  "source": src(name, yline(loc)),
                                  "script_exists": self.has(script),
                                  "commands": self._script_commands(script)})
            files = []
            for f in (spec.get("files") or []) if isinstance(spec, dict) else []:
                if isinstance(f, dict) and isinstance(f.get("destination"), str):
                    files.append({"source_dir": str(f.get("source") or ""),
                                  "destination": str(f["destination"]),
                                  "source": src(name, yline(f["destination"]))})
            out["appspec"] = {"path": name, "hooks": hooks, "files": files}
            break
        for rel in self.files:
            for pat, kind in DEPLOY_SURFACES:
                if re.search(pat, rel):
                    out["surfaces"].append({"kind": kind, "path": rel})
                    break
        for wf in self.s_ci()["workflows"]:
            for job in wf["jobs"]:
                for step in job["steps"]:
                    text = " ".join(x for x in (step.get("uses"), step.get("run"),
                                                step.get("name")) if x)
                    if DEPLOY_STEP_RE.search(text):
                        out["ci_deploy_steps"].append({
                            "workflow": wf["path"], "job": job["id"],
                            "step": step.get("name") or step.get("uses") or step.get("run", "")[:60],
                            "push_branches": wf["triggers"].get("push_branches", []),
                            "source": step["source"]})
        return out

    def s_ci(self) -> dict:
        if "ci" in self._cache:
            return self._cache["ci"]
        workflows = []
        for rel in self.files:
            if not re.match(r"^\.github/workflows/[^/]+\.ya?ml$", rel):
                continue
            text = self.read(rel)
            doc = yaml_load(text) if text else None
            if not isinstance(doc, dict):
                workflows.append({"path": rel, "error": "unparsed", "jobs": [], "triggers": {}})
                continue
            on = doc.get("on", doc.get("true"))
            triggers: dict = {"events": []}
            if isinstance(on, str):
                triggers["events"] = [str(on)]
            elif isinstance(on, list):
                triggers["events"] = [str(x) for x in on if x]
            elif isinstance(on, dict):
                triggers["events"] = [str(k) for k in on]
                for ev in ("push", "pull_request"):
                    spec = on.get(ev)
                    if isinstance(spec, dict) and spec.get("branches") is not None:
                        triggers[f"{ev}_branches"] = [str(b) for b in ystrings(spec.get("branches"))]
            jobs = []
            for jid, job in (doc.get("jobs") or {}).items() if isinstance(doc.get("jobs"), dict) else []:
                if not isinstance(job, dict):
                    continue
                steps = []
                for st in (job.get("steps") or [])[:40]:
                    if not isinstance(st, dict):
                        continue
                    run_v, uses_v, name_v = st.get("run"), st.get("uses"), st.get("name")
                    anchor = run_v if isinstance(run_v, str) else uses_v if isinstance(uses_v, str) \
                        else name_v
                    steps.append({"name": str(name_v) if isinstance(name_v, str) else None,
                                  "uses": str(uses_v) if isinstance(uses_v, str) else None,
                                  "run": redact(str(run_v)) if isinstance(run_v, str) else None,
                                  "source": src(rel, yline(anchor))})
                runs_on = job.get("runs-on")
                jobs.append({"id": str(jid), "name": str(job.get("name")) if isinstance(job.get("name"), str) else None,
                             "runs_on": str(runs_on) if isinstance(runs_on, str) else None,
                             "steps": steps, "source": src(rel, yline(jid))})
            workflows.append({"path": rel, "name": str(doc.get("name")) if isinstance(doc.get("name"), str) else None,
                              "triggers": triggers, "jobs": jobs})
        other = []
        for path, kind in OTHER_CI:
            text = self.read(path)
            if text is None:
                continue
            doc = yaml_load(text) if path.endswith(".yml") else None
            scripts = []
            for node in ywalk(doc, "script"):
                for cmd in (node if isinstance(node, list) else [node]):
                    if isinstance(cmd, str):
                        scripts.append({"command": redact(str(cmd)), "source": src(path, yline(cmd))})
            other.append({"kind": kind, "path": path, "scripts": scripts[:30]})
        self._cache["ci"] = {"workflows": workflows, "other": other}
        return self._cache["ci"]

    # === SCAN LAYOUT ===
    def s_tests(self) -> list[dict]:
        out = []
        for name in ("phpunit.xml", "phpunit.xml.dist"):
            text = self.read(name)
            if text is not None:
                suites = [{"name": m.group(1), "source": src(name, line_of(text, m.group(0)))}
                          for m in re.finditer(r'<testsuite\s+name="([^"]+)"', text)]
                out.append({"framework": "PHPUnit", "config": name, "suites": suites})
        cc = self.read("codeception.yml") or self.read("codeception.dist.yml")
        if cc is not None:
            cfg = "codeception.yml" if self.has("codeception.yml") else "codeception.dist.yml"
            suites = [{"name": re.sub(r"\.suite(\.dist)?\.yml$", "", f.rsplit("/", 1)[-1]),
                       "source": src(f)} for f in self.files
                      if re.search(r"(^|/)[\w-]+\.suite(\.dist)?\.yml$", f)]
            out.append({"framework": "Codeception", "config": cfg, "suites": suites})
        if self.has("tests/Pest.php"):
            out.append({"framework": "Pest", "config": "tests/Pest.php", "suites": []})
        for rel in (f for f in self.files if "/" not in f):
            base = rel
            for pat, fw in ((r"^jest\.config\.", "Jest"), (r"^vitest\.config\.", "Vitest"),
                            (r"^vitest\.workspace\.", "Vitest"),
                            (r"^playwright\.config\.", "Playwright"),
                            (r"^cypress\.config\.|^cypress\.json$", "Cypress"),
                            (r"^karma\.conf\.", "Karma"), (r"^\.mocharc\.", "Mocha"),
                            (r"^pytest\.ini$|^conftest\.py$", "pytest"),
                            (r"^tox\.ini$", "tox"), (r"^noxfile\.py$", "nox")):
                if re.search(pat, base):
                    entry = {"framework": fw, "config": rel, "suites": []}
                    text = self.read(rel) or ""
                    m = re.search(r"testDir\s*:\s*['\"]([^'\"]+)", text)
                    if m:
                        entry["test_dir"] = {"value": m.group(1), "source": src(rel, line_of(text, m.group(0)))}
                    out.append(entry)
        py = self.read("pyproject.toml")
        if py and "[tool.pytest.ini_options]" in py:
            out.append({"framework": "pytest", "config": src("pyproject.toml",
                                                             line_of(py, "[tool.pytest.ini_options]")),
                        "suites": []})
        out += self._convention_tests()
        out.sort(key=lambda t: (t["framework"], t["config"]))
        return out

    def _convention_tests(self) -> list[dict]:
        """Suites no config file declares. `config` is the file that stands for the suite:
        the shallowest shell runner, the first .bats file, go.mod, Cargo.toml."""
        out = []

        def depth(f: str) -> tuple:
            return f.count("/"), f
        sh = [f for f in self.files if f.endswith(".sh") and TESTS_DIR_RE.search(f)]
        if sh:
            runners = sorted((f for f in sh if SHELL_RUNNER_RE.search(f)), key=depth)
            out.append({"framework": "Shell scripts", "config": (runners or sorted(sh, key=depth))[0],
                        "files": len(sh), "suites": [{"name": r, "source": src(r)} for r in runners[:8]],
                        "runners": len(runners)})
        bats = sorted(f for f in self.files if f.endswith(".bats"))
        if bats:
            out.append({"framework": "Bats", "config": bats[0], "files": len(bats), "suites": []})
        go = [f for f in self.files if f.endswith("_test.go")]
        if go:
            out.append({"framework": "go test", "config": "go.mod" if self.has("go.mod") else sorted(go)[0],
                        "files": len(go), "suites": []})
        if self.has("Cargo.toml") and any(re.search(r"(^|/)tests/[^/]+\.rs$", f) for f in self.files):
            out.append({"framework": "cargo test", "config": "Cargo.toml", "suites": []})
        return out

    def s_generated(self) -> dict:
        if "generated" in self._cache:
            return self._cache["generated"]
        groups: dict = {}
        for rel in self.files:
            for pat, root, reason in GENERATED_RULES:
                if re.search(pat, rel):
                    m = re.match(root, rel)
                    key = m.group(1) if m and m.group(1) else rel
                    g = groups.setdefault((key, reason), {"path": key, "reason": reason, "files": 0})
                    g["files"] += 1
                    break
        declared = []
        for rel in self.files:
            base = rel.rsplit("/", 1)[-1]
            if "/" in rel and not rel.startswith("config/"):
                continue
            text = None
            if re.match(r"^vite\.config\.", base):
                text = self.read(rel) or ""
                for m in re.finditer(r"outDir\s*:\s*['\"]([^'\"]+)", text):
                    declared.append({"path": m.group(1), "tool": "Vite",
                                     "source": src(rel, line_of(text, m.group(0)))})
            elif base == "webpack.mix.js":
                text = self.read(rel) or ""
                for m in re.finditer(r"setPublicPath\(\s*['\"]([^'\"]+)", text):
                    declared.append({"path": m.group(1), "tool": "Laravel Mix",
                                     "source": src(rel, line_of(text, m.group(0)))})
            elif re.match(r"^webpack\.config\.", base):
                text = self.read(rel) or ""
                for m in re.finditer(r"path\s*:\s*path\.(?:resolve|join)\([^,]+,\s*['\"]([^'\"]+)", text):
                    declared.append({"path": m.group(1), "tool": "webpack",
                                     "source": src(rel, line_of(text, m.group(0)))})
        ignored = []
        gi = self.read(".gitignore") or ""
        for n, line in enumerate(gi.splitlines(), 1):
            if BUILD_IGNORE_RE.match(line.strip()):
                ignored.append({"pattern": line.strip(), "source": src(".gitignore", n)})
        tracked = sorted(groups.values(), key=lambda g: (-g["files"], g["path"]))
        for g in tracked:
            g["source"] = "cmd: git ls-files" if self.is_git else "filesystem walk"
            for d in declared:
                norm = d["path"].lstrip("./").replace("../", "").rstrip("/") + "/"
                if g["path"].startswith(norm) or norm.startswith(g["path"]):
                    g["declared_by"] = d["source"]
        self.line_counts()
        self._cache["generated"] = {
            "tracked": tracked[:20], "declared_outputs": declared, "ignored": ignored,
            "marked_files": [{"path": p, "source": src(p, 1)} for p in sorted(self._marked)[:20]]}
        return self._cache["generated"]

    def s_areas(self) -> list[dict]:
        counts: dict = defaultdict(Counter)
        for rel in self.files:
            if "/" not in rel:
                continue
            key = rel.split("/", 1)[0] + "/"
            for c in CONTAINER_DIRS:
                if rel.startswith(c + "/") and rel.count("/") > c.count("/") + 1:
                    key = "/".join(rel.split("/")[: c.count("/") + 2]) + "/"
                    break
            counts[key][os.path.splitext(rel)[1].lower() or "(none)"] += 1
        out = []
        for path, exts in sorted(counts.items()):
            total = sum(exts.values())
            src_files = sum(n for e, n in exts.items() if e in SOURCE_EXTS)
            docs_files = exts.get(".md", 0) + exts.get(".mdx", 0) + exts.get(".rst", 0)
            kind = self._area_kind(path, src_files, total, docs_files)
            out.append({"path": path, "files": total, "kind": kind,
                        "top_extensions": [e for e, _ in sorted(exts.items(),
                                                                key=lambda x: (-x[1], x[0]))[:3]],
                        "source": "cmd: git ls-files" if self.is_git else "filesystem walk"})
        out.sort(key=lambda a: (a["kind"] != "source", -a["files"], a["path"]))
        return out[:40]

    def _area_kind(self, path: str, src_files: int, total: int, docs_files: int) -> str:
        p = path.rstrip("/")
        if any(re.search(pat, path) for pat, _, _ in GENERATED_RULES[:6]):
            return "generated"
        if re.match(r"^(tests?|spec|__tests__|e2e|cypress|playwright)$", p, re.I):
            return "tests"
        if re.match(r"^(docs?|documentation)$", p, re.I):
            return "docs"
        if p in (".github", ".circleci", ".gitlab", ".buildkite"):
            return "ci"
        if p in (".ddev", ".docker", "docker", "config", ".vscode", ".husky", ".claude", "deploy",
                 "scripts", "bin"):
            return "tooling" if p in ("scripts", "bin", "deploy", ".husky") else "config"
        if src_files * 2 >= total and src_files:
            return "source"
        return "docs" if docs_files * 2 >= total else "assets"

    def s_outliers(self) -> list[dict]:
        rows = [{"path": p, "lines": n, "source": src(p)}
                for p, n in self.line_counts().items()
                if n > OUTLIER_LINES and os.path.splitext(p)[1].lower() in SOURCE_EXTS
                and p not in self._marked]
        rows.sort(key=lambda r: (-r["lines"], r["path"]))
        return rows[:20]

    def s_docs(self) -> list[dict]:
        out = []
        instr = re.compile(r"(^|/)(AGENTS|CLAUDE|CLAUDE\.local|GEMINI)\.md$|^\.cursorrules$|"
                           r"^\.github/copilot-instructions\.md$|^\.windsurfrules$")
        docs_seen = 0
        for rel in self.files:
            is_instr = bool(instr.search(rel))
            if not is_instr:
                if "/" not in rel and rel.lower().endswith(".md"):
                    pass
                elif rel.startswith("docs/") and rel.endswith(".md") and docs_seen < 60:
                    docs_seen += 1
                else:
                    continue
            text = self.read(rel)
            if text is None:
                continue
            heads, fence = [], False
            for n, line in enumerate(text.splitlines(), 1):
                if line.lstrip().startswith(("```", "~~~")):
                    fence = not fence
                    continue
                m = re.match(r"^(#{1,3})\s+(.+?)\s*#*\s*$", line)
                if m and not fence:
                    heads.append({"level": len(m.group(1)), "text": m.group(2), "line": n})
            out.append({"path": rel, "lines": text.count("\n") + (0 if text.endswith("\n") else 1),
                        "instruction_file": is_instr, "headings": heads[:40], "source": src(rel)})
        return out

    def s_env(self) -> list[dict]:
        out = []
        for rel in self.files:
            if not ENV_EXAMPLE_RE.match(rel.rsplit("/", 1)[-1]):
                continue
            text = self.read(rel) or ""
            names = []
            for n, line in enumerate(text.splitlines(), 1):
                m = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
                if m:
                    names.append({"name": m.group(1), "source": src(rel, n)})
            out.append({"path": rel, "names": names})
        return out

    # === SCAN HISTORY ===
    def s_history(self) -> dict | None:
        if "history" in self._cache:
            return self._cache["history"]
        if not self.is_git:
            return None
        fmt = "--format=%x01%H%x02%s"
        raw = self.git("log", "--no-merges", "--no-renames", f"-n{self.max_commits}",
                       "--numstat", fmt) or ""
        commits = []
        for block in raw.split("\x01"):
            lines = block.strip("\n").split("\n")
            if not lines or "\x02" not in lines[0]:
                continue
            sha, subject = lines[0].split("\x02", 1)
            files, churn = [], {}
            for l in lines[1:]:
                parts = l.split("\t")
                if len(parts) != 3:
                    continue
                a, d, p = parts
                files.append(p)
                churn[p] = (int(a) if a.isdigit() else 0) + (int(d) if d.isdigit() else 0)
            commits.append({"sha": sha[:10], "subject": redact(subject), "files": files,
                            "churn": churn})
        commits.reverse()  # oldest first, so "followed by" means later
        gen_roots = [g["path"] for g in self.s_generated()["tracked"]]
        tracked = self.fileset

        def noise(p: str) -> bool:
            # A file no longer tracked (deleted, renamed away) can't hold a landmine today.
            return p not in tracked or p.rsplit("/", 1)[-1] in LOCKFILES or bool(self.generated_kind(p))

        def prose(p: str) -> bool:
            # Docs churn with every change by design: as hot spots or "fragile" files
            # they are noise. They still count for coupling (a doc paired with code).
            return p.lower().endswith((".md", ".mdx", ".rst", ".txt"))

        cmd = f"cmd: git log --no-merges --no-renames -n{self.max_commits} --numstat"
        usable = [c for c in commits if 0 < len(c["files"]) <= HISTORY_BULK]
        n_commits, touch, churn_sum = len(usable), Counter(), Counter()
        for c in usable:
            for p in c["files"]:
                if not noise(p):
                    touch[p] += 1
                    churn_sum[p] += c["churn"].get(p, 0)
        # Co-change coupling: Jaccard over the commits touching either file.
        eligible = {p for p, n in touch.items() if n >= COUPLING_SUPPORT}
        pairs: Counter = Counter()
        for c in usable:
            for a, b in combinations(sorted(set(c["files"]) & eligible), 2):
                pairs[(a, b)] += 1
        coupling = []
        for (a, b), co in pairs.items():
            union = touch[a] + touch[b] - co
            jac = co / union if union else 0
            if co >= COUPLING_SUPPORT and jac >= COUPLING_JACCARD:
                coupling.append({"files": [a, b], "together": co, "either": union,
                                 "jaccard": round(jac, 2), "source": cmd})
        coupling.sort(key=lambda x: (-x["together"], -x["jaccard"], x["files"]))
        parent: dict = {}

        def find(x):
            while parent.get(x, x) != x:
                x = parent[x]
            return x
        for c in coupling:
            ra, rb = find(c["files"][0]), find(c["files"][1])
            if ra != rb:
                parent[max(ra, rb)] = min(ra, rb)
        comp: dict = defaultdict(set)
        for c in coupling:
            for f in c["files"]:
                comp[find(f)].add(f)
        groups = sorted((sorted(g) for g in comp.values() if len(g) >= 3), key=lambda g: (-len(g), g))
        hotspots = [{"path": p, "commits": n, "churn": churn_sum[p], "source": cmd}
                    for p, n in sorted(touch.items(), key=lambda x: (-x[1], -churn_sum[x[0]], x[0]))
                    if n >= 5 and not prose(p)][:10]
        fix, rev, examples = Counter(), Counter(), defaultdict(list)
        for c in usable:
            is_rev, is_fix = bool(REVERT_RE.search(c["subject"])), bool(FIX_RE.search(c["subject"]))
            for p in c["files"]:
                if noise(p) or prose(p) or not (is_rev or is_fix):
                    continue
                rev[p] += is_rev
                fix[p] += is_fix and not is_rev
                if len(examples[p]) < 3:
                    examples[p].append(f"{c['sha']} {c['subject'][:72]}")
        fragile = [{"path": p, "fix_commits": fix[p], "reverts": rev[p], "examples": examples[p],
                    "source": cmd}
                   for p in sorted(set(fix) | set(rev))
                   if fix[p] >= 3 or (rev[p] >= 1 and fix[p] + rev[p] >= 2)]
        fragile.sort(key=lambda x: (-(x["fix_commits"] + 2 * x["reverts"]), x["path"]))
        followups = self._followups(usable, gen_roots, cmd)
        self._cache["history"] = {
            "commits_scanned": len(commits), "commits_used": n_commits,
            "window": f"last {self.max_commits} non-merge commits",
            "coupling": coupling[:15], "groups": groups[:5], "hotspots": hotspots,
            "fragile": fragile[:8], "config_followups": followups, "source": cmd}
        return self._cache["history"]

    def _followups(self, commits: list, gen_roots: list, cmd: str) -> list[dict]:
        def family(p: str) -> str | None:
            if p.rsplit("/", 1)[-1] in LOCKFILES:
                return None
            if MIGRATION_RE.search(p):
                return "migrations"
            if PROJECT_CONFIG_RE.match(p):
                return "project config"
            if self.generated_kind(p) or any(p.startswith(r) for r in gen_roots):
                return "build output"
            return None
        edits, followed, fams, example = Counter(), Counter(), defaultdict(Counter), {}
        for i, c in enumerate(commits):
            for cfg in (p for p in c["files"] if CONFIG_RE.search(p) and p in self.fileset):
                edits[cfg] += 1
                hit = None
                for later in commits[i: i + FOLLOWUP_WINDOW + 1]:
                    for p in later["files"]:
                        f = family(p)
                        if f and p != cfg:
                            hit = (f, p)
                            break
                    if hit:
                        break
                if hit:
                    followed[cfg] += 1
                    fams[cfg][hit[0]] += 1
                    example.setdefault(cfg, hit[1])
        out = []
        for cfg, n in edits.items():
            k = followed[cfg]
            if n >= 3 and k / n >= 0.5:
                fam = sorted(fams[cfg].items(), key=lambda x: (-x[1], x[0]))[0][0]
                out.append({"config": cfg, "edits": n, "followed": k, "family": fam,
                            "example": example[cfg], "window": FOLLOWUP_WINDOW, "source": cmd})
        out.sort(key=lambda x: (-x["followed"], x["config"]))
        return out[:8]

    # === SCAN ENTRY DOCS ===
    def _workspace_dirs(self) -> list[str]:
        """Expand declared workspace globs against tracked manifest directories only."""
        manifests = {rel.rsplit("/", 1)[0] for rel in self.files
                     if "/" in rel and rel.rsplit("/", 1)[-1] in
                     ("package.json", "composer.json", "pyproject.toml", "go.mod", "Cargo.toml")}
        out = set()
        for workspace in self._workspaces(""):
            for pattern in workspace.get("globs", []):
                out.update(d for d in manifests if glob_member(d, pattern))
        return [d + "/" for d in sorted(out)]

    @staticmethod
    def _scope_dir(path: str, workspaces: list[str]) -> str:
        hits = [w for w in workspaces if path.startswith(w)]
        return max(hits, key=len) if hits else ""

    def _manifest_dirs(self) -> list[str]:
        """Folders with their own manifest. A vendored package or a test fixture's manifest
        is not a contract of this repo, so neither counts (nor do their entry points)."""
        names = {"package.json", "composer.json", "pyproject.toml", "go.mod", "Cargo.toml"}
        return sorted({rel.rsplit("/", 1)[0] + "/" for rel in self.files
                       if "/" in rel and rel.rsplit("/", 1)[-1] in names and not self.generated_kind(rel)
                       and not NOT_A_CONTRACT_RE.search(rel)})

    def s_manifests_by_dir(self) -> dict:
        dirs = set(self._workspace_dirs())
        dirs.update(r["dir"] for r in self.s_nesting()["recommend"])
        dirs.update(self.extra_dirs)
        return {d: self._manifests_at(d) for d in sorted(dirs)}

    def _partial_gate(self, config: str) -> dict | None:
        text = self.read(config) or ""
        base = config.rsplit("/", 1)[0] + "/" if "/" in config else ""
        # The backreference keeps a closing quote from becoming the next opener;
        # otherwise code between two literals can masquerade as a baseline path.
        quoted = [value for _, value in re.findall(r"(['\"])([^'\"]+)\1", text)]
        matches = [value for value in quoted if re.search(r"baseline|freeze|skip", value, re.I)]
        for raw in matches:
            # Only "./" is a relative-path marker; lstrip would corrupt legitimate
            # dotfiles such as .dependency-cruiser-baseline.json.
            relative = raw[2:] if raw.startswith("./") else raw
            candidate = posixpath.normpath(base + relative)
            if candidate not in self.fileset:
                continue
            body = self.read(candidate) or ""
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, list):
                entries = len(parsed)
            elif isinstance(parsed, dict):
                entries = len(parsed)
            else:
                entries = len([line for line in body.splitlines()
                               if line.strip() and not line.lstrip().startswith(("#", "//"))])
            lower = candidate.lower()
            kind = "freeze" if "freeze" in lower else "skip" if "skip" in lower else "baseline"
            return {"kind": kind, "path": candidate, "entries": entries}
        return None

    def _gate_check_text(self) -> str:
        chunks = []
        roots = [""] + self._manifest_dirs()
        for root in roots:
            manifests = self._manifests_at(root)
            for key in ("package_json", "composer_json"):
                for script in (manifests.get(key) or {}).get("scripts", []):
                    if CHECKISH_RE.search(script["name"]):
                        chunks.append(script.get("command", ""))
            # Recipe bodies, not just names: `check: bash scripts/check-x.sh` wires the
            # gate through its body. The whole file is read once a check-ish recipe exists.
            for key, sub, names in (("makefile", "targets", ("Makefile", "makefile", "GNUmakefile")),
                                    ("justfile", "recipes", ("justfile", "Justfile", ".justfile"))):
                if any(CHECKISH_RE.search(r["name"]) for r in (manifests.get(key) or {}).get(sub, [])):
                    chunks.extend(self.read(root + n) or "" for n in names)
        for workflow in self.s_ci()["workflows"]:
            for job in workflow.get("jobs", []):
                for step in job.get("steps", []):
                    chunks.extend(str(step.get(k) or "") for k in ("name", "run", "uses"))
        # One level of indirection: a check recipe or CI step that runs a script (say
        # tests/check-resources.sh) wires every gate that script runs. Deeper chains are
        # not followed, so a gate three hops away reads as unwired, never the reverse.
        first = "\n".join(chunks)
        for rel in sorted(set(re.findall(r"[\w./-]+\.(?:sh|py|mjs|cjs|js|ts)\b", first))):
            rel = rel[2:] if rel.startswith("./") else rel
            if rel in self.fileset:
                chunks.append(self.read(rel) or "")
        return "\n".join(chunks).lower()

    def s_gates(self) -> list[dict]:
        if "gates" in self._cache:
            return self._cache["gates"]
        out: list[dict] = []
        seen: set[tuple[str, str]] = set()
        workspaces = self._workspace_dirs()
        check_text = self._gate_check_text()

        def add(tool: str, config: str, source: str | None = None,
                tokens: tuple[str, ...] = (), wired: bool | None = None) -> None:
            key = (tool, config)
            if key in seen:
                return
            seen.add(key)
            if wired is None:
                wired = any(token in check_text for token in tokens) if tokens else None
            scope = self._scope_dir(config, workspaces)
            # A boundary checker's config governs the folder it sits in (a db/ dependency-
            # cruiser config checks db/'s imports), workspace member or not. Invariant
            # tests and ArchUnit suites check the whole tree wherever they live.
            if not scope and "/" in config and tool not in ("invariant test", "ArchUnit"):
                scope = config.rsplit("/", 1)[0] + "/"
            display_config = config[len(scope):] if scope and config.startswith(scope) else config
            out.append({"tool": tool, "config": display_config, "scope": scope,
                        "partial": self._partial_gate(config), "wired": wired,
                        "source": source or src(config)})

        for rel in self.files:
            base = rel.rsplit("/", 1)[-1]
            # Read only files whose content decides a gate; reading every tracked file
            # here cost one bounded read per file on every scan.
            needs_text = (base in ("pyproject.toml", "project.json")
                          or re.match(r"eslint\.config\.|\.eslintrc", base)
                          or re.fullmatch(r"\.golangci\.(yml|yaml|toml|json)", base)
                          or (is_test(rel) and rel.endswith((".java", ".kt"))))
            text = (self.read(rel) or "") if needs_text else ""
            lower = text.lower()
            if base == ".importlinter":
                add("import-linter", rel, tokens=("lint-imports", "import-linter"))
            elif base == "pyproject.toml" and "[tool.importlinter]" in text:
                add("import-linter", rel, src(rel, line_of(text, "[tool.importlinter]")),
                    ("lint-imports", "import-linter"))
            if base == "tach.toml":
                add("tach", rel, tokens=("tach check", "tach"))
            if re.fullmatch(r"\.dependency-cruiser\.(js|cjs|json)", base):
                add("dependency-cruiser", rel, tokens=("depcruise", "dependency-cruiser"))
            if (re.match(r"eslint\.config\.|\.eslintrc", base)
                    and ("boundaries/" in lower or "@nx/enforce-module-boundaries" in lower)):
                tool = "Nx module boundaries" if "@nx/enforce-module-boundaries" in lower \
                    else "eslint-plugin-boundaries"
                add(tool, rel, tokens=("eslint",))
            if base == "project.json" and re.search(r'"tags"\s*:', text):
                add("Nx module boundaries", rel, tokens=("nx",))
            if base in ("deptrac.php", "deptrac.yaml", "deptrac.yml"):
                add("deptrac", rel, tokens=("deptrac",))
            if base == "archunit.properties" or (is_test(rel) and
                                                  re.search(r"@(ArchTest|AnalyzeClasses)\b", text)):
                add("ArchUnit", rel, tokens=("gradle", "mvn", "test"))
            if re.fullmatch(r"\.golangci\.(yml|yaml|toml|json)", base) and "depguard" in lower:
                add("depguard", rel, tokens=("golangci", "depguard"))
            if re.search(r"(^|/)scripts/check-[^/]+$", rel):
                # A check-* script inside a package is often a tool that package ships to
                # its users, not a gate of this repo. It counts at the root's scripts/,
                # or anywhere once the check entry point or CI runs it.
                tokens = (base.lower(), rel.lower())
                if rel.startswith("scripts/") or any(t in check_text for t in tokens):
                    add("invariant test", rel, tokens=tokens)
        internal_roots = sorted({rel.split("/internal/", 1)[0] + "/"
                                 for rel in self.files if "/internal/" in rel})
        for root in internal_roots:
            first = next(rel for rel in self.files if rel.startswith(root + "internal/"))
            config = root + "internal/"
            add("Go internal", config, src(first), wired=True)
            out[-1]["scope"] = root
            out[-1]["config"] = "internal/"
            out[-1]["partial"] = None
        out.sort(key=lambda gate: (gate["scope"], gate["tool"], gate["config"]))
        self._cache["gates"] = out
        return out

    def _nest_candidates(self) -> list[str]:
        dirs = set(self._workspace_dirs())
        for rel in self.files:
            if os.path.splitext(rel)[1].lower() not in SOURCE_EXTS or "/" not in rel:
                continue
            parts = rel.split("/")
            dirs.add(parts[0] + "/")
            for container in CONTAINER_DIRS:
                prefix = container.rstrip("/") + "/"
                if rel.startswith(prefix) and len(parts) > len(container.split("/")):
                    dirs.add("/".join(parts[:len(container.split("/")) + 1]) + "/")
        excluded = re.compile(r"(^|/)(docs?|tests?|spec|assets?|public|static|dist|build|vendor|node_modules|"
                              r"\.github|\.circleci|\.gitlab)(/|$)", re.I)
        generated = [g["path"] for g in self.s_generated()["tracked"]]
        return sorted(d for d in dirs if not d.startswith(".") and not excluded.search(d)
                      and not any(d.startswith(g) or g.startswith(d) for g in generated)
                      and sum(1 for rel in self.files if rel.startswith(d)) >= MIN_NEST_FILES)

    def _history_landmines(self) -> list[dict]:
        history = self.s_history() or {}
        return [c for c in candidates({"history": history}) if c.get("paths")]

    def _landmines_in(self, directory: str) -> list[dict]:
        return [c for c in self._history_landmines()
                if c["paths"] and all(path.startswith(directory) for path in c["paths"])]

    def _churn_dirs(self, directories: list[str]) -> set[str]:
        if not self.is_git or not directories:
            return set()
        raw = self.git("log", "--no-merges", f"-n{self.max_commits}", "--format=%x01", "--name-only") or ""
        commits = [{line for line in block.splitlines() if line and line != "\x01"}
                   for block in raw.split("\x01") if block.strip()]
        if not commits:
            return set()
        return {d for d in directories
                if sum(any(path.startswith(d) for path in commit) for commit in commits) / len(commits)
                >= NEST_CHURN_RATIO}

    def _farm_shape(self, child: str) -> tuple[str, str] | None:
        direct = sorted({local.split("/", 1)[0] + ("/" if "/" in local else "")
                         for _, local in self._files_under(child)})
        # SKILL.md is a protocol manifest for farm grouping only; it is deliberately
        # absent from own-manifest scoring, whose frozen signal list is package/runtime based.
        manifest_names = ("package.json", "composer.json", "pyproject.toml", "go.mod",
                          "Cargo.toml", "SKILL.md")
        manifests = [name for name in manifest_names if self.has(child + name)]
        if not manifests:
            return None
        parent = child.split("/", 1)[0] + "/"
        return parent, f"{'+'.join(manifests)} + roots({', '.join(direct)})"

    def _farm_groups(self) -> list[tuple[str, str, list[str]]]:
        shapes: dict[tuple[str, str], list[str]] = defaultdict(list)
        children: set[str] = set()
        for rel in self.files:
            parts = rel.split("/")
            if len(parts) >= 3:
                children.add("/".join(parts[:2]) + "/")
        for child in sorted(children):
            farm_shape = self._farm_shape(child)
            if not farm_shape:
                continue
            parent, shape = farm_shape
            shapes[(parent, shape)].append(child)
        return [(parent, shape, members) for (parent, shape), members in sorted(shapes.items())
                if len(members) >= FARM_MIN_SIBLINGS]

    def _farm_rows(self, groups: list[tuple[str, str, list[str]]]) -> list[dict]:
        source = "cmd: git ls-files" if self.is_git else "filesystem walk"
        by_parent: dict[str, list[tuple[str, list[str]]]] = defaultdict(list)
        for parent, shape, members in groups:
            by_parent[parent].append((shape, members))
        rows = []
        for parent, shaped_members in sorted(by_parent.items()):
            members = sorted({member for _, group in shaped_members for member in group})
            shape = shaped_members[0][0] if len(shaped_members) == 1 else "; ".join(
                f"{len(group)}x {group_shape}" for group_shape, group in shaped_members)
            rows.append({"parent": parent, "members": len(members), "shape": shape,
                         "nest_also": [m for m in members if len(self._landmines_in(m)) >= 2],
                         "source": source})
        return rows

    def s_nesting(self) -> dict:
        if "nesting" in self._cache:
            return self._cache["nesting"]
        directories = self._nest_candidates()
        churned = self._churn_dirs(directories)
        gates = self.s_gates()
        repo_exts = Counter(os.path.splitext(f)[1].lower() for f in self.files
                            if os.path.splitext(f)[1].lower() in SOURCE_EXTS)
        repo_lang = repo_exts.most_common(1)[0][0] if repo_exts else None
        recommend = []
        farm_groups = self._farm_groups()
        farm_rows = self._farm_rows(farm_groups)
        farm_members = {member for _, _, members in farm_groups for member in members}
        # Farm members are reconstructed from their parent+shape below; keeping them out of
        # ordinary recommendations is what prevents one stamped doc per identical sibling.
        weights = {"own-manifest": 2, "own-tests": 2, "own-deploy": 2,
                   "landmine-cluster": 2, "own-gate": 1, "stack-differs": 1, "churn": 1}

        def assess(directory: str, inner: list[str]) -> tuple[list[dict], bool]:
            """(signals, recommended?). inner: recommended folders below this one, whose
            files and landmines are not this folder's evidence."""
            signals = []

            def signal(kind: str, detail: str, source: str) -> None:
                signals.append({"kind": kind, "detail": detail, "source": source})

            def mine(rel: str) -> bool:
                return not any(rel.startswith(d) for d in inner)

            under = [(rel, local) for rel, local in self._files_under(directory) if mine(rel)]
            manifests = [name for name in ("package.json", "composer.json", "pyproject.toml",
                                            "go.mod", "Cargo.toml") if self.has(directory + name)]
            if manifests:
                signal("own-manifest", ", ".join(manifests), src(directory + manifests[0]))
            test_files = [rel for rel, local in under
                          if (SHELL_RUNNER_RE.search(local) and TESTS_DIR_RE.search(local))
                          or re.search(r"(^|/)(pytest\.ini|phpunit\.xml(\.dist)?|vitest\.config\.[^/]+|"
                                       r"jest\.config\.[^/]+|playwright\.config\.[^/]+)$", local)]
            if test_files:
                signal("own-tests", test_files[0], src(test_files[0]))
            deploy = [(rel, kind) for rel, local in under
                      for pattern, kind in DEPLOY_SURFACES if re.search(pattern, local)]
            if deploy:
                signal("own-deploy", deploy[0][1], src(deploy[0][0]))
            local_landmines = [c for c in self._landmines_in(directory) if any(mine(x) for x in c["paths"])]
            if len(local_landmines) >= 2:
                evidence = local_landmines[0]["evidence"][0]
                signal("landmine-cluster", f"{len(local_landmines)} history candidates", evidence)
            local_gates = [gate for gate in gates if gate["scope"] == directory]
            if local_gates:
                signal("own-gate", local_gates[0]["tool"], local_gates[0]["source"])
            local_exts = Counter(os.path.splitext(rel)[1].lower() for rel, _ in under
                                 if os.path.splitext(rel)[1].lower() in SOURCE_EXTS)
            local_lang = local_exts.most_common(1)[0][0] if local_exts else None
            if local_lang and repo_lang and EXT_LANG.get(local_lang, local_lang) != EXT_LANG.get(repo_lang, repo_lang):
                signal("stack-differs", f"{EXT_LANG.get(local_lang, local_lang)} vs repo "
                       f"{EXT_LANG.get(repo_lang, repo_lang)}", "cmd: git ls-files")
            if directory in churned:
                signal("churn", f">={int(NEST_CHURN_RATIO * 100)}% of scanned commits",
                       f"cmd: git log --no-merges -n{self.max_commits} --name-only")
            contract = [s for s in signals if s["kind"] != "churn"]
            contract_points = sum(weights[s["kind"]] for s in contract)
            in_farm = directory in farm_members
            app_ok = not directory.startswith("apps/") or any(
                s["kind"] in ("own-deploy", "landmine-cluster") for s in contract)
            return signals, (contract_points >= MIN_NEST_CONTRACT_POINTS
                             and len({s["kind"] for s in contract}) >= MIN_NEST_CONTRACT_SIGNALS
                             and app_ok and (not in_farm or len(local_landmines) >= 2))

        first = {d: assess(d, []) for d in directories}
        qualified = [d for d in directories if first[d][1]]
        for directory in qualified:
            # A parent (packages/) collects its children's tests and landmines. It earns a
            # doc of its own only on evidence left after its recommended children take
            # theirs; otherwise it would get a second doc for engine's contract.
            inner = [d for d in qualified if d != directory and d.startswith(directory)]
            signals, ok = assess(directory, inner) if inner else first[directory]
            if ok:
                recommend.append({"dir": directory, "points": sum(weights[s["kind"]] for s in signals),
                                  "signals": signals,
                                  "existing": {"agents_md": self.has(directory + "AGENTS.md"),
                                               "claude_md": self.has(directory + "CLAUDE.md")}})
        self._cache["nesting"] = {"recommend": recommend, "farms": farm_rows,
                                  "considered": len(directories)}
        return self._cache["nesting"]

    def s_generated_entry_docs(self) -> list[dict]:
        instr = re.compile(r"(^|/)(AGENTS|CLAUDE|CLAUDE\.local|GEMINI)\.md$")
        ruler_source = next((f for f in self.files if f.startswith(".ruler/")), None)
        rulesync_source = next((f for f in self.files if f.startswith(".rulesync/")), None)
        out = []
        for rel in self.files:
            if not instr.search(rel):
                continue
            text = self.read(rel) or ""
            head = "\n".join(text.splitlines()[:8])
            header = re.search(r"<!--\s*Source:\s*([^>]*?)\s*-->", head, re.I)
            if header:
                named = posixpath.normpath(header.group(1).strip().replace("\\", "/"))
                inside = not (named == ".." or named.startswith(("../", "/")) or re.match(r"^[A-Za-z]:", named))
                resolved = named if inside and (named in self.fileset or any(
                    f.startswith(named.rstrip("/") + "/") for f in self.files)) else None
                out.append({"path": rel, "generator": "source-header",
                            "source_of_truth": resolved, "source": src(rel, line_of(text, header.group(0)))})
            elif ruler_source and (rel == "AGENTS.md" or re.search(r"generated.*ruler|ruler.*generated", head, re.I)):
                out.append({"path": rel, "generator": "ruler", "source_of_truth": ".ruler/",
                            "source": src(ruler_source)})
            elif rulesync_source and (rel == "AGENTS.md" or re.search(r"generated.*rulesync|rulesync.*generated", head, re.I)):
                out.append({"path": rel, "generator": "rulesync", "source_of_truth": ".rulesync/",
                            "source": src(rulesync_source)})
        return out

    def _entry_points(self) -> list[dict]:
        out = []
        roots = [""] + self._manifest_dirs()

        def add(name: str, kind: str, source: str) -> None:
            row = {"name": name, "kind": kind, "source": source}
            if row not in out:
                out.append(row)

        def strings(value) -> list[str]:
            if isinstance(value, str):
                return [value]
            if isinstance(value, dict):
                return [s for child in value.values() for s in strings(child)]
            if isinstance(value, list):
                return [s for child in value for s in strings(child)]
            return []

        for root in roots:
            path = self._join(root, "package.json")
            text = self.read(path)
            if not text:
                continue
            try:
                data = json.loads(text)
            except json.JSONDecodeError:
                continue
            for key, kind in (("main", "manifest-main"), ("bin", "manifest-bin"),
                              ("exports", "manifest-exports")):
                for value in strings(data.get(key)):
                    name = posixpath.normpath((root.rstrip("/") + "/" if root else "") + value)
                    add(name, kind, src(path, line_of(text, value) or json_key_line(text, key)))
        for rel in self.files:
            if self.generated_kind(rel) or NOT_A_CONTRACT_RE.search(rel):
                continue   # a vendored package's index is not this repo's entry point
            base = rel.rsplit("/", 1)[-1]
            if re.match(r"^index\.[A-Za-z0-9]+$", base) and os.path.splitext(rel)[1].lower() in SOURCE_EXTS:
                add(rel, "index", src(rel))
            if re.search(r"(^|/)cmd/[^/]+/", rel) and os.path.splitext(rel)[1].lower() in SOURCE_EXTS:
                add(rel, "cmd", src(rel))
            if base == "__main__.py":
                add(rel, "dunder-main", src(rel))
        return sorted(out, key=lambda row: (row["name"], row["kind"], row["source"]))

    def s_architecture(self) -> dict:
        architecture_path = None
        if self.has("ARCHITECTURE.md"):
            architecture_path = "ARCHITECTURE.md"
        elif self.has("docs/ARCHITECTURE.md"):
            text = self.read("docs/ARCHITECTURE.md") or ""
            if re.search(r"^#{1,3}\s+code\s*map\b", text, re.I | re.M):
                architecture_path = "docs/ARCHITECTURE.md"
        nesting = self.s_nesting()
        workspaces = self._workspace_dirs()
        reasons = []
        if len(nesting["recommend"]) >= 2:
            reasons.append(f"{len(nesting['recommend'])} nesting recommendations")
        contract_areas = len({d for d in self._manifest_dirs() if self._manifests_at(d)})
        if contract_areas >= 4:
            reasons.append(f"{contract_areas} code areas with contract signals")
        if len(workspaces) >= 3:
            reasons.append(f"{len(workspaces)} workspace members")
        root_doc = self.read("AGENTS.md") or self.read(".claude/AGENTS.md") or self.read("CLAUDE.md") or ""
        structure = re.search(r"^#{1,3}\s+[^\n]*\b(?:structure|layout|director(?:y|ies)|folders?|code ?map)\b"
                              r"[^\n]*$([\s\S]*?)(?=^#{1,3}\s|\Z)", root_doc, re.I | re.M)
        if structure:
            body = structure.group(1).strip("\n")
            if len(body.splitlines()) > 25 or len(body) > 2000:
                reasons.append("root Structure section exceeds 25 lines or 2000 characters")
        top = {rel.split("/", 1)[0] + "/" for rel in self.files if "/" in rel
               and not rel.startswith(".") and not self.generated_kind(rel)}
        layout = sorted(top | set(workspaces))
        fingerprint = hashlib.sha1("\n".join(layout).encode("utf-8")).hexdigest()
        return {"path": architecture_path, "warranted": bool(reasons), "reasons": reasons,
                "layout": layout, "layout_fingerprint": fingerprint,
                "entry_points": self._entry_points()}


# === CANDIDATES ===
# Landmine CANDIDATES are questions for the repo owner, never facts. Each carries the
# evidence that raised it; the scaffold lists them under Landmines as TODO(owner).


def is_test(path: str) -> bool:
    return bool(TESTS_DIR_RE.search(path) or TEST_FILE_RE.search(path))


def own_test(test: str, other: str) -> bool:
    """True when `test` tests code that `other` belongs to: its owner is the folder above
    tests/ (or the test file's own folder), and `other` lives under it. A test changing
    with its code is how test-first work looks, not a coupling rule worth asking about."""
    m = TESTS_DIR_RE.search(test)
    if m:
        owner = test[:m.start()] + m.group(1)
    elif TEST_FILE_RE.search(test):
        owner = test.rsplit("/", 1)[0] + "/" if "/" in test else ""
    else:
        return False
    return not is_test(other) and other.startswith(owner)


def candidates(d: dict) -> list[dict]:
    out: list[dict] = []

    def add(kind: str, question: str, evidence: list[str], paths: list[str] | None = None,
            count: int | None = None) -> None:
        # paths: the repo files the question is about; agents-md.py audit uses them to
        # tell which questions an existing AGENTS.md already answers.
        # count: the evidence size (shared commits for coupling, fix plus revert commits
        # for fragile, commits for a hot spot, lines for an outlier, follow-ups for a
        # config edit; None where no number applies). A ruled-out line records it, and
        # the question returns once the evidence grows past it.
        out.append({"kind": kind, "question": question, "evidence": evidence, "paths": paths or [],
                    "count": count})
    for s in [s for s in d.get("secrets_skipped", []) if not FIXTURE_DIR_RE.search(s["path"])][:3]:
        add("tracked-secret", f"`{s['path']}` is tracked and looks like a secrets file (the scan "
            "did not open it). Should it be ignored, and have its values been rotated?", [s["source"]],
            [s["path"]])
    dep = d.get("deploy") or {}
    for h in ((dep.get("appspec") or {}).get("hooks") or [])[:3]:
        cmds = "; ".join(c["command"] for c in h["commands"][:2])
        add("deploy", f"Deploys run `{h['location']}` at {h['event']}"
            + (f" (it runs `{cmds}`)" if cmds else "")
            + ". Which branch triggers a deployment (a merge to it is a deploy)?",
            [h["source"]] + [c["source"] for c in h["commands"][:2]], [h["location"]])
    for s in (dep.get("ci_deploy_steps") or [])[:2]:
        br = ", ".join(s["push_branches"]) or "the configured triggers"
        add("deploy", f"CI job `{s['job']}` in `{s['workflow']}` deploys on push to {br}. Is that "
            "branch protected, and may agents ever merge to it?", [s["source"]], [s["workflow"]])
    gen = d.get("generated") or {}
    for g in [g for g in gen.get("tracked", []) if g["reason"] not in ("minified asset", "source map")][:3]:
        why = f"declared by {g['declared_by']}" if g.get("declared_by") else g["reason"]
        add("generated", f"`{g['path']}` ({g['files']} files) is tracked but looks like build "
            f"output or vendored code ({why}). Is it committed on purpose, and must it be "
            "regenerated rather than hand-edited?", [g["source"]] + ([g["declared_by"]] if g.get("declared_by") else []),
            [g["path"]])
    hist = d.get("history") or {}
    grouped: set = set()
    asked = 0
    for g in hist.get("groups", []):
        members = [f for f in g if not any(own_test(f, o) for o in g if o != f)]
        if len(members) < 3 or asked == 2:
            continue
        asked += 1
        grouped.update(g)
        add("coupling", f"{len(members)} files keep changing together: " + ", ".join(f"`{f}`" for f in members[:5])
            + ". Is that a rule (a generated set, a registry, mirrored config)?", [hist["source"]], members,
            max((c["together"] for c in hist.get("coupling", []) if set(c["files"]) <= set(g)), default=None))
    pairs = [c for c in hist.get("coupling", []) if not set(c["files"]) <= grouped
             and not own_test(*c["files"]) and not own_test(*reversed(c["files"]))]
    for c in pairs[:4]:
        a, b = c["files"]
        add("coupling", f"`{a}` and `{b}` changed together in {c['together']} of the {c['either']} "
            "commits that touched either. Must one change whenever the other does?", [c["source"]], [a, b],
            c["together"])
    for f in hist.get("config_followups", [])[:3]:
        add("config-followup", f"Edits to `{f['config']}` were followed by {f['family']} changes "
            f"(e.g. `{f['example']}`) within {f['window']} commits in {f['followed']} of "
            f"{f['edits']} cases. Is a rebuild, migration or sync required after changing it?",
            [f["source"]], [f["config"]], f["followed"])
    # One question per file: a fragile file that is also a hot spot says so here instead
    # of raising a second, near-identical hot-spot question.
    hot = {h["path"]: h for h in hist.get("hotspots", [])}
    fragile_paths = set()
    for f in hist.get("fragile", [])[:3]:
        h = hot.get(f["path"])
        also = (f" It is also among the most-changed files ({h['commits']} of "
                f"{hist.get('commits_used', 0)} commits).") if h else ""
        fragile_paths.add(f["path"])
        add("fragile", f"`{f['path']}` was touched by {f['fix_commits']} fix commit(s) and "
            f"{f['reverts']} revert(s) in the scanned history.{also} What keeps breaking here, and "
            "how is it checked?", [f["source"]] + [f"git: {e}" for e in f["examples"][:2]], [f["path"]],
            f["fix_commits"] + f["reverts"])
    ddev = d.get("ddev") or {}
    for h in (ddev.get("hooks") or [])[:2]:
        add("ddev-hook", f"DDEV runs `{h['command']}` on {h['event']}. Does it have side effects "
            "an agent should know about (database import, migrations, a rebuild)?", [h["source"]])
    for h in [h for h in hist.get("hotspots", []) if h["path"] not in fragile_paths][:2]:
        add("hotspot", f"`{h['path']}` is among the most-changed files ({h['commits']} of "
            f"{hist.get('commits_used', 0)} commits). What must an agent know before editing it?",
            [h["source"]], [h["path"]], h["commits"])
    for o in (d.get("outliers") or [])[:2]:
        add("outlier", f"`{o['path']}` is {o['lines']} lines. Must it stay one file (then say why "
            "in a guard comment), or is it due a split?", [o["source"]], [o["path"]], o["lines"])
    for w in ((d.get("manifests") or {}).get("workspaces") or [])[:1]:
        globs = ", ".join(w["globs"][:4]) or w["tool"]
        add("workspaces", f"The repo declares workspaces ({globs}). Does any package have its own "
            "contract that needs a nested AGENTS.md?", [w["source"]])
    return out[:16]


# === CLI ===


def summary(d: dict) -> list[str]:
    lines = []
    r = d.get("repo") or {}
    if r:
        lines.append(f"repo        {r['name']} ({'git' if r['is_git'] else 'plain dir'}, "
                     f"{r['tracked_files']} files, {r.get('commits', 0)} commits)")
    m = d.get("manifests") or {}
    stack = [t["name"] + f" ({t['source']})" for key in ("composer_json", "package_json", "python")
             for t in (m.get(key) or {}).get("tools", [])
             if t["name"] in CMS_LABELS | {"Vite", "Laravel Mix", "Next.js", "Django", "FastAPI",
                                           "Flask", "Astro", "Nuxt"}]
    if stack:
        lines.append("stack       " + ", ".join(stack[:6]))
    n_cmd = sum(len((m.get(k) or {}).get("scripts", [])) for k in ("package_json", "composer_json"))
    if n_cmd:
        lines.append(f"scripts     {n_cmd} declared in package.json/composer.json")
    dd = d.get("ddev")
    if dd:
        lines.append(f"ddev        {len(dd['commands'])} custom commands, {len(dd['hooks'])} hooks")
    dep = d.get("deploy") or {}
    if dep.get("appspec"):
        lines.append(f"deploy      {dep['appspec']['path']}: {len(dep['appspec']['hooks'])} hooks")
    ci = d.get("ci") or {}
    if ci.get("workflows"):
        lines.append(f"ci          {len(ci['workflows'])} GitHub workflow(s)")
    for t in d.get("tests") or []:
        lines.append(f"tests       {t['framework']} ({t['config']})")
    if d.get("outliers"):
        lines.append(f"outliers    {len(d['outliers'])} file(s) over {OUTLIER_LINES} lines")
    if d.get("secrets_skipped"):
        lines.append(f"secrets     {len(d['secrets_skipped'])} secret-like tracked file(s), not opened")
    nesting = d.get("nesting") or {}
    if nesting.get("recommend") or nesting.get("farms"):
        lines.append(f"nesting     {len(nesting.get('recommend', []))} recommendation(s), "
                     f"{len(nesting.get('farms', []))} farm(s)")
    if d.get("gates"):
        partial = sum(g.get("partial") is not None for g in d["gates"])
        lines.append(f"gates       {len(d['gates'])} detected ({partial} partially enforced)")
    architecture = d.get("architecture") or {}
    if architecture:
        state = architecture.get("path") or ("warranted" if architecture.get("warranted") else "not warranted")
        lines.append(f"architecture {state}; {len(architecture.get('entry_points', []))} entry point(s)")
    if d.get("generated_entry_docs"):
        lines.append(f"generated   {len(d['generated_entry_docs'])} generated entry doc(s)")
    for c in d.get("candidates", []):
        lines.append(f"question    [{c['kind']}] {c['question']}")
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Deterministic, read-only deep scan of a checkout into sourced facts.",
        epilog="EXAMPLES:\n"
               "  repo-scan.py --repo path/to/site --json > facts.json\n"
               "  repo-scan.py --json | jq -r '.data.candidates[].question'\n"
               "  repo-scan.py --only manifests,ddev,deploy --json\n"
               "  repo-scan.py --only nesting,gates,architecture --json\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", help="checkout to scan (default: cwd)")
    ap.add_argument("--only", default="", help="comma list of sections (default: all)")
    ap.add_argument("--max-commits", type=int, default=500, help="history window (default 500)")
    ap.add_argument("--no-tokei", action="store_true", help="count languages without tokei")
    ap.add_argument("--dir", action="append", default=[], metavar="FOLDER",
                    help="also read the manifests in FOLDER (repeatable)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")  # type: ignore[attr-defined]
    except (AttributeError, ValueError):
        pass
    only = [s.strip() for s in args.only.split(",") if s.strip()] or list(SECTIONS)
    bad = [s for s in only if s not in SECTIONS]
    if bad or args.max_commits < 1:
        eecho(f"repo-scan: unknown section(s): {', '.join(bad)} (known: {' '.join(SECTIONS)})"
              if bad else "repo-scan: --max-commits must be >= 1")
        return 2
    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        eecho(f"repo-scan: not a directory: {repo}")
        return 3
    scan = Scan(repo, args.max_commits, not args.no_tokei)
    for d in args.dir:
        d = d.replace("\\", "/").strip("/")
        if not d or d.startswith("..") or not (repo / d).is_dir():
            eecho(f"repo-scan: --dir {d!r} is not a folder inside the repo")
            return 3
        scan.extra_dirs.append(d + "/")
    eecho(f"repo-scan: scanning {repo.name} ({', '.join(only)})")
    data: dict = {}
    for name in only:
        data[name] = getattr(scan, f"s_{name}")()
        if name == "manifests":
            data["manifests_by_dir"] = scan.s_manifests_by_dir()
        elif name == "docs":
            data["generated_entry_docs"] = scan.s_generated_entry_docs()
    _ = scan.files
    data["secrets_skipped"] = scan.secrets_skipped
    data["candidates"] = candidates(data)
    if args.json:
        print(json.dumps({"data": data, "meta": {"schema": SCHEMA, "sections": only,
                                                 "repo_path": str(repo)}}, indent=2))
    else:
        print("\n".join(summary(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
