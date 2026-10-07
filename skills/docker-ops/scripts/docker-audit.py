#!/usr/bin/env python3
"""Audit a repo's Dockerfiles and Compose files for the mistakes that ship quietly.

The mistakes: secrets baked into layers, TLS verification switched off, root containers,
unpinned or end-of-life bases, datastores published on every interface, host escapes
(docker.sock, privileged, host namespaces), and build contexts that copy .env and .git.

Run `docker build --check .` first when Docker is present: those are BuildKit's own build
checks, and they need the daemon. This auditor covers what they can't: Compose files,
secret files copied in, integrity bypasses, build-context leaks, healthcheck tooling a slim
or distroless base lacks, and a few silent parser traps (a `# syntax=` directive that is
not on line 1 is just a comment). It is read-only and stdlib-only. It uses no network, runs
nothing (no docker, no git), and never prints a secret value, only its key or file name.

Each check carries the matching IDs of hadolint (DL), BuildKit build checks, Trivy (DS)
and Checkov (CKV), so a finding can be cross-referenced or suppressed with the other tool's
pragma. Only the IDs are reused. hadolint is GPL-licensed, so none of its rule text is.
`--list-checks` prints the table.

Usage:   docker-audit.py [PATH]... [--json] [--ignore CHECK]... [--min-severity LEVEL]
                         [--production] [--allow-registry HOST]... [--show-suppressed]
                         [--catalog FILE] [--today YYYY-MM-DD] [--list-checks] [-q]
Input:   PATHs (default "."). A directory is walked to depth 6, skipping .git, node_modules,
         vendor, .ddev (DDEV's compose files are ddev-ops' job) and build output. A file is
         taken as given and must be named like a Dockerfile (Dockerfile, Dockerfile.*,
         *.Dockerfile, Containerfile) or a Compose file (compose*.y[a]ml or
         docker-compose*.y[a]ml). Dockerfiles that a Compose `build:` names are audited too,
         against the build context Compose gives them. No stdin.
Output:  stdout = findings sorted high, medium, low, info: severity<TAB>check<TAB>file:line
         <TAB>detail, or the --json envelope (schema claude-mods.docker-ops.audit/v1).
         Data only. info findings appear only with --min-severity info.
Stderr:  the verdict line, notices (unreadable files), errors.
Exit:    0 clean, 2 usage, 3 nothing to audit (a PATH is missing, no Dockerfile or Compose
         file found, or the facts catalog is missing), 4 every file found was unreadable
         or the catalog is malformed, 10 findings reported

Suppressing a finding: put `# docker-audit ignore=CHECK[,CHECK] reason="why" until=YYYY-MM-DD`
on the line directly above the instruction (Dockerfile) or key (Compose). Compose also takes
it at the end of the line. `until=` is optional. With no reason, an unknown check or a bad
date, the pragma suppresses nothing and is reported as `ignore-invalid`. An expired pragma
suppresses nothing either. Also honoured: `# hadolint ignore=DL3008,...` on the line above,
`# hadolint global ignore=...` anywhere in the file, and BuildKit's `# check=skip=Name,...`
(or `skip=all`) parser directive. --show-suppressed lists what was suppressed and does
not change the exit code.

Examples:
  docker-audit.py                                    # audit the repo in the current directory
  docker-audit.py services/api compose.yaml --json | jq '.data[] | select(.severity=="high")'
  docker-audit.py . --production --allow-registry ghcr.io --allow-registry docker.io
  docker-audit.py --list-checks                      # every check, its family, severity and IDs
"""
# === SECTION MAP ===
#   CATALOG       check table: family, severity, summary, cross-tool IDs
#   YAML          Compose reader (block + flow YAML, anchors, merge keys, line numbers)
#   DOCKERFILE    parser: directives, continuations, heredocs, stages
#   IMAGES        image-reference parsing and base-image classification
#   IGNOREFILE    .dockerignore matching (Go filepath.Match plus **, last match wins)
#   PRAGMAS       inline suppressions
#   DF-CHECKS     Dockerfile families D1-D11 (Audit.dockerfile and helpers)
#   COMPOSE       Compose families C1-C9 (Audit.compose and helpers)
#   MAIN          discovery, suppression, output, exit codes
#
# Why one ~1,900-line file: everything under scripts/ is a runnable tool under the Skill
# Resource Protocol (exec bit, --help, exit contract), so a helper module there would break
# that contract, and a stdlib-only single file is what the agent can run by path from any
# project. Navigate by the section markers; tests/run.sh pins every check's behaviour, so a
# split must keep that suite green.
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shlex
import sys
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNREADABLE = 4
EX_FINDINGS = 10

SCHEMA = "claude-mods.docker-ops.audit/v1"
FACTS_SCHEMA = "claude-mods.docker-ops.facts/v1"
DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "assets" / "docker-facts.json"
SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2, "info": 3}

# === CATALOG ===
# check -> (family, default severity, summary, {tool: [IDs]}). The IDs are facts for
# cross-referencing (hadolint DLxxxx, BuildKit build-check names, Trivy DS-xxxx, Checkov
# CKV_*), checked against each tool's published rule list on 2026-10-07. A finding may raise
# or lower its own severity (a CA .pem is medium, a private key high).
CHECKS: dict[str, tuple[str, str, str, dict[str, list[str]]]] = {}


def _check(name, family, severity, summary, **ids):
    CHECKS[name] = (family, severity, summary, {k: v for k, v in ids.items() if v})


# D1 base pinning
_check("base-untagged", "D1", "medium", "FROM without a tag or digest floats with whatever the registry serves",
       hadolint=["DL3006"])
_check("base-latest", "D1", "medium", "FROM ...:latest floats; pin a version (and a digest for production)",
       hadolint=["DL3007"], trivy=["DS-0001"], checkov=["CKV_DOCKER_7"])
_check("base-arg-unresolved", "D1", "medium", "FROM uses an ARG with no default, so the base is whatever --build-arg says",
       buildkit=["InvalidDefaultArgInFrom", "UndefinedArgInFrom"])
_check("base-eol", "D1", "medium", "the base image's language runtime is past end of life")
_check("base-registry", "D1", "medium", "base image from a registry outside --allow-registry", hadolint=["DL3026"])
_check("base-not-digest", "D1", "low", "production base pinned by tag only, not by digest")
# D2 user
_check("final-user-root", "D2", "high", "the final stage explicitly runs as root",
       hadolint=["DL3002"], trivy=["DS-0002"], checkov=["CKV_DOCKER_8"])
_check("final-user-unset", "D2", "medium", "the final stage never sets USER, so it runs as root",
       trivy=["DS-0002"], checkov=["CKV_DOCKER_3"])
# D3 secrets
_check("secret-in-arg-env", "D3", "high", "a credential-named ARG or ENV is recorded in the image or its history",
       buildkit=["SecretsUsedInArgOrEnv"])
_check("secret-file-copied", "D3", "high", "COPY/ADD brings a credential file into a layer")
_check("secret-mount-optional", "D3", "low", "a secret mount without required=true builds silently when the secret is missing")
# D4 integrity bypass
_check("tls-verify-off", "D4", "high", "a download or package step switches off TLS or signature verification",
       checkov=["CKV2_DOCKER_2", "CKV2_DOCKER_3", "CKV2_DOCKER_4", "CKV2_DOCKER_5", "CKV2_DOCKER_6",
                "CKV2_DOCKER_7", "CKV2_DOCKER_8", "CKV2_DOCKER_9", "CKV2_DOCKER_10", "CKV2_DOCKER_11",
                "CKV2_DOCKER_12", "CKV2_DOCKER_13", "CKV2_DOCKER_14", "CKV2_DOCKER_15", "CKV2_DOCKER_16"])
_check("pipe-to-shell", "D4", "medium", "a downloaded script is piped straight into a shell, unverified")
_check("add-url-unverified", "D4", "medium", "ADD of a URL without --checksum trusts whatever the server returns")
_check("ssh-hostkey-off", "D4", "high", "SSH host-key checking is disabled (or keys are scanned blind) at build time")
# D5 package hygiene
_check("apt-update-alone", "D5", "medium", "apt-get update in its own RUN caches a stale index into later builds",
       trivy=["DS-0017"], checkov=["CKV_DOCKER_5"])
_check("apt-no-recommends", "D5", "low", "apt-get install without --no-install-recommends pulls extra packages",
       hadolint=["DL3015"])
_check("apt-not-apt-get", "D5", "low", "apt (the interactive CLI) has no stable scripting interface; use apt-get",
       hadolint=["DL3027"], checkov=["CKV_DOCKER_9"])
_check("sudo-in-run", "D5", "medium", "sudo in RUN: the build already runs as the stage's user",
       hadolint=["DL3004"], checkov=["CKV2_DOCKER_1"])
_check("lockfile-not-enforced", "D5", "medium", "a dependency install that may rewrite or ignore the lockfile")
_check("package-cache-in-layer", "D5", "low", "a package manager's download cache is left in the layer",
       hadolint=["DL3019", "DL3042"])
_check("apt-cache-mount-wiped", "D5", "low", "an apt cache mount that the same image then defeats")
# D6 instruction semantics
_check("cmd-shell-form", "D6", "low", "shell-form CMD/ENTRYPOINT runs under /bin/sh -c, which does not forward signals",
       hadolint=["DL3025"], buildkit=["JSONArgsRecommended"])
_check("multiple-cmd", "D6", "low", "only the last CMD/ENTRYPOINT in a stage takes effect",
       hadolint=["DL4003", "DL4004"], buildkit=["MultipleInstructionsDisallowed"], trivy=["DS-0016"])
_check("add-local-file", "D6", "low", "ADD for a local file: COPY says what it does; ADD also unpacks and fetches",
       hadolint=["DL3020"], trivy=["DS-0005"], checkov=["CKV_DOCKER_4"])
_check("cd-in-run", "D6", "low", "cd in RUN does not persist; use WORKDIR", hadolint=["DL3003"], trivy=["DS-0013"])
_check("maintainer-deprecated", "D6", "low", "MAINTAINER is deprecated; use a LABEL",
       hadolint=["DL4000"], buildkit=["MaintainerDeprecated"], trivy=["DS-0022"])
_check("duplicate-stage-name", "D6", "medium", "two stages share a name, so --target and COPY --from are ambiguous",
       hadolint=["DL3024"], buildkit=["DuplicateStageName"], checkov=["CKV_DOCKER_11"])
_check("expose-ssh", "D6", "medium", "EXPOSE 22: an SSH daemon in a container", trivy=["DS-0004"], checkov=["CKV_DOCKER_1"])
_check("workdir-relative", "D6", "low", "a relative WORKDIR depends on every earlier WORKDIR",
       hadolint=["DL3000"], buildkit=["WorkdirRelativePath"], checkov=["CKV_DOCKER_10"])
# D7 pipes
_check("pipe-no-pipefail", "D7", "low", "a pipe in RUN without pipefail hides a failing left side", hadolint=["DL4006"])
# D8 build context
_check("dockerignore-missing", "D8", "medium", "COPY of the whole context with no .dockerignore")
_check("dockerignore-gap", "D8", "high", "a .env, credential file or .git directory in the context is not ignored")
_check("copy-ignored-file", "D8", "low", "COPY names a path the .dockerignore excludes; the build fails to find it",
       buildkit=["CopyIgnoredFile"])
_check("copy-all-before-install", "D8", "low", "COPY of the whole context before the dependency install busts the cache on every edit")
# D9 modernisation
_check("directive-ignored", "D9", "medium", "a parser directive after line 1 (or after a comment) is only a comment")
_check("syntax-directive-missing", "D9", "info", "no `# syntax=docker/dockerfile:1` on line 1")
_check("cache-mount-missing", "D9", "info", "a package install without a BuildKit cache mount")
# D10 healthcheck tooling
_check("healthcheck-tool-missing", "D10", "medium", "HEALTHCHECK calls a tool (or a shell) the final image does not contain")
# D11 labels
_check("oci-labels-missing", "D11", "info", "no org.opencontainers.image.* labels on the final stage")
# C1-C9 Compose
_check("compose-version-obsolete", "C1", "low", "top-level `version:` is obsolete; Compose ignores it and warns")
_check("compose-legacy-filename", "C1", "info", "docker-compose.yml is the legacy name; compose.yaml is canonical")
_check("build-and-image", "C2", "medium", "build: plus an unqualified image: lets `docker compose pull` fetch a stranger's image of that name")
_check("image-untagged", "C3", "medium", "a service image without a tag or digest floats")
_check("image-latest", "C3", "medium", "a service image pinned to :latest floats")
_check("compose-literal-secret", "C4", "high", "a credential-named variable has a literal value in the Compose file")
_check("port-all-interfaces", "C5", "medium", "a published port without a host IP listens on every interface")
_check("datastore-published", "C5", "high", "a datastore port is published on every interface")
_check("host-escape", "C6", "high", "the service can reach the host: privileged, a host namespace, a dangerous capability, or a host path")
_check("hardening-missing", "C7", "low", "a production service lacks the hardening defaults")
_check("depends-on-unordered", "C8", "low", "depends_on a datastore without a health condition: started is not ready")
_check("healthy-without-healthcheck", "C8", "medium", "condition: service_healthy on a service that has no healthcheck")
_check("undeclared-resource", "C9", "medium", "a named volume, network, secret or config is used but never declared")
# the auditor's own
_check("ignore-invalid", "audit", "low", "a docker-audit pragma without a reason, with an unknown check, or a bad date")

PRODUCTION_ONLY = {"base-not-digest", "hardening-missing"}

# Credential-looking names. Specific suffixes, not bare KEY or AUTH: those would flag
# REDIS_KEY_PREFIX or GIT_AUTHOR_NAME. Names that point AT a secret (FOO_PASSWORD_FILE) are not one.
SECRET_KEY_RE = re.compile(
    r"(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY|SECURITY_KEY|ACCESS_KEY|AUTH_KEY|CREDENTIALS?)", re.I)
SECRET_KEY_EXEMPT_RE = re.compile(r"(_FILE|_PATH|_DIR|_ID|_URL|_URI|_ENDPOINT|_NAME)$", re.I)
# Variable references: plain $VAR / ${VAR}, and ${VAR<op>x} whose x is a literal fallback.
REF_RE = re.compile(r"\$\{[A-Za-z_]\w*\}|\$[A-Za-z_]\w*")
REF_OP_RE = re.compile(r"\$\{[A-Za-z_]\w*(:?[-+?=])([^{}$]*)\}")

# === YAML ===
# Compose files are YAML, and the stdlib has no YAML reader. This one covers what Compose
# files use: block maps and sequences (including a sequence at its key's indent), flow
# collections, quoted and plain scalars, block scalars, anchors, aliases, merge keys and the
# !reset / !override tags (dropped). Anything else raises YamlError and the file is
# reported as unreadable, never guessed at. Every map and sequence keeps its source lines.


class YamlError(Exception):
    def __init__(self, message: str, line: int):
        super().__init__(f"line {line}: {message}")
        self.line = line


class YMap(dict):
    """A mapping that remembers the line each key was written on."""

    def __init__(self):
        super().__init__()
        self.lines: dict = {}


class YSeq(list):
    """A sequence that remembers the line each item was written on."""

    def __init__(self):
        super().__init__()
        self.lines: list = []


def _strip_comment(s: str) -> str:
    """Drop a YAML comment: '#' at the start or after whitespace, outside quotes."""
    out = []
    quote = None
    prev = " "
    i = 0
    while i < len(s):
        ch = s[i]
        if quote:
            if quote == '"' and ch == "\\":
                out.append(s[i:i + 2])
                i += 2
                continue
            if ch == quote:
                if quote == "'" and s[i + 1:i + 2] == "'":
                    out.append("''")
                    i += 2
                    continue
                quote = None
        else:
            if ch == "#" and prev in " \t":
                break
            if ch in "'\"" and prev in " \t[{,:-":
                quote = ch
        out.append(ch)
        prev = ch
        i += 1
    return "".join(out).rstrip()


def _unescape(s: str) -> str:
    table = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "/": "/", "r": "\r", "0": "\0"}
    return re.sub(r"\\(u[0-9a-fA-F]{4}|.)",
                  lambda m: chr(int(m.group(1)[1:], 16)) if m.group(1)[0] == "u" and len(m.group(1)) == 5
                  else table.get(m.group(1), m.group(1)), s)


def _scalar(raw: str):
    s = raw.strip()
    if len(s) >= 2 and s[0] == s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == s[-1] == '"':
        return _unescape(s[1:-1])
    low = s.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if low in ("null", "~", ""):
        return None
    return s


def _depth(s: str) -> int:
    depth, quote = 0, None
    for ch in s:
        if quote:
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
    return depth


def _skip_ws(s: str, pos: int) -> int:
    while pos < len(s) and s[pos] in " \t":
        pos += 1
    return pos


def _flow_scalar(s: str, pos: int, stops: str, line: int):
    if pos < len(s) and s[pos] in "'\"":
        q = s[pos]
        j = pos + 1
        while j < len(s):
            if q == '"' and s[j] == "\\":
                j += 2
                continue
            if s[j] == q:
                if q == "'" and s[j + 1:j + 2] == "'":
                    j += 2
                    continue
                break
            j += 1
        if j >= len(s):
            raise YamlError("unclosed quote in flow collection", line)
        return _scalar(s[pos:j + 1]), j + 1
    j = pos
    while j < len(s):
        ch = s[j]
        if ch in stops and (ch != ":" or s[j + 1:j + 2] in ("", " ", ",", "}", "]")):
            break
        j += 1
    return _scalar(s[pos:j]), j


def _parse_flow(s: str, pos: int, line: int, anchors: dict):
    pos = _skip_ws(s, pos)
    if pos >= len(s):
        raise YamlError("flow collection ends early", line)
    ch = s[pos]
    if ch == "[":
        out = YSeq()
        pos += 1
        while True:
            pos = _skip_ws(s, pos)
            if s[pos:pos + 1] == "]":
                return out, pos + 1
            item, pos = _parse_flow(s, pos, line, anchors)
            out.append(item)
            out.lines.append(line)
            pos = _skip_ws(s, pos)
            if s[pos:pos + 1] == ",":
                pos += 1
            elif s[pos:pos + 1] == "]":
                return out, pos + 1
            else:
                raise YamlError("expected , or ] in a flow sequence", line)
    if ch == "{":
        out = YMap()
        pos += 1
        while True:
            pos = _skip_ws(s, pos)
            if s[pos:pos + 1] == "}":
                return out, pos + 1
            key, pos = _flow_scalar(s, pos, ":,}", line)
            pos = _skip_ws(s, pos)
            val = None
            if s[pos:pos + 1] == ":":
                pos = _skip_ws(s, pos + 1)
                if s[pos:pos + 1] not in (",", "}"):
                    val, pos = _parse_flow(s, pos, line, anchors)
            out[str(key)] = val
            out.lines[str(key)] = line
            pos = _skip_ws(s, pos)
            if s[pos:pos + 1] == ",":
                pos += 1
            elif s[pos:pos + 1] == "}":
                return out, pos + 1
            else:
                raise YamlError("expected , or } in a flow mapping", line)
    if ch == "*":
        m = re.match(r"\*([^\s,\]}]+)", s[pos:])
        if not m or m.group(1) not in anchors:
            raise YamlError("unknown alias", line)
        return anchors[m.group(1)], pos + m.end()
    return _flow_scalar(s, pos, ",]}", line)


class _Yaml:
    def __init__(self, text: str):
        self.raw = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        self.i = 0
        self.anchors: dict = {}
        # A "- key: value" line is re-read as the first line of a nested map at the
        # column of "key"; override holds that virtual (indent, text) for line j.
        self.override: dict = {}

    def peek(self):
        j = self.i
        while j < len(self.raw):
            if j in self.override:
                ind, txt = self.override[j]
                return j, ind, txt
            line = self.raw[j]
            lead = line[:len(line) - len(line.lstrip(" \t"))]
            content = _strip_comment(line)
            if content.strip() in ("", "---", "..."):
                j += 1
                continue
            if "\t" in lead:
                raise YamlError("tab in indentation", j + 1)
            return j, len(content) - len(content.lstrip(" ")), content.strip()
        return None

    def consume(self, j: int):
        self.override.pop(j, None)
        self.i = j + 1

    @staticmethod
    def split_key(txt: str):
        """'key: rest' -> (key, rest), or None when the line is not a mapping entry."""
        if txt[:1] in "[{?" or txt.startswith("- ") or txt == "-":
            return None
        quote, depth = None, 0
        for k, ch in enumerate(txt):
            if quote:
                if ch == quote:
                    quote = None
                continue
            if ch in "'\"" and k == 0:
                quote = ch
            elif ch in "[{":
                depth += 1
            elif ch in "]}":
                depth -= 1
            elif ch == ":" and depth == 0 and txt[k + 1:k + 2] in ("", " "):
                key = txt[:k].strip()
                if key[:1] in "'\"":
                    key = _scalar(key)
                return str(key), txt[k + 1:].strip()
        return None

    def block(self, min_indent: int):
        p = self.peek()
        if p is None or p[1] < min_indent:
            return None
        j, ind, txt = p
        if txt == "-" or txt.startswith("- "):
            return self.seq(ind)
        if self.split_key(txt) is not None:
            return self.mapping(ind)
        self.consume(j)
        return self.value(txt, ind - 1, j)

    def mapping(self, ind: int):
        m = YMap()
        merges = []
        while True:
            p = self.peek()
            if p is None or p[1] < ind:
                break
            j, cur, txt = p
            if cur > ind:
                raise YamlError("unexpected indentation", j + 1)
            if txt == "-" or txt.startswith("- "):
                break
            kv = self.split_key(txt)
            if kv is None:
                raise YamlError("expected `key: value`", j + 1)
            key, rest = kv
            self.consume(j)
            val = self.value(rest, ind, j)
            if key == "<<":
                merges.append((val, j))
                continue
            m[key] = val
            m.lines[key] = j + 1
        for val, j in merges:
            for src in (val if isinstance(val, list) else [val]):
                if isinstance(src, dict):
                    for k, v in src.items():
                        if k not in m:
                            m[k] = v
                            m.lines[k] = j + 1
        return m

    def seq(self, ind: int):
        s = YSeq()
        while True:
            p = self.peek()
            if p is None or p[1] != ind or not (p[2] == "-" or p[2].startswith("- ")):
                break
            j, _, txt = p
            rest = txt[1:].lstrip(" ")
            col = ind + (len(txt) - len(rest))
            if not rest:
                self.consume(j)
                nxt = self.peek()
                item = self.block(ind + 1) if nxt and nxt[1] > ind else None
            elif rest == "-" or rest.startswith("- ") or self.split_key(rest) is not None:
                self.override[j] = (col, rest)
                item = self.block(col)
            else:
                self.consume(j)
                item = self.value(rest, ind, j)
            s.append(item)
            s.lines.append(j + 1)
        return s

    def value(self, rest: str, ind: int, j: int):
        anchor = None
        if rest.startswith("&"):
            parts = rest.split(None, 1)
            anchor, rest = parts[0][1:], (parts[1] if len(parts) > 1 else "")
        if rest.startswith("!"):
            parts = rest.split(None, 1)
            rest = parts[1] if len(parts) > 1 else ""
        if rest == "":
            p = self.peek()
            if p and p[1] > ind:
                val = self.block(p[1])
            elif p and p[1] == ind and (p[2] == "-" or p[2].startswith("- ")):
                val = self.seq(ind)
            else:
                val = None
        elif rest[0] in "|>":
            val = self.block_scalar(rest, ind)
        elif rest[0] in "[{":
            buf = rest
            while _depth(buf) > 0:
                if self.i >= len(self.raw):
                    raise YamlError("unclosed flow collection", j + 1)
                buf += " " + _strip_comment(self.raw[self.i]).strip()
                self.i += 1
            val, pos = _parse_flow(buf, 0, j + 1, self.anchors)
            if buf[pos:].strip():
                raise YamlError("text after a flow collection", j + 1)
        elif rest.startswith("*"):
            name = rest[1:].strip()
            if name not in self.anchors:
                raise YamlError(f"unknown alias *{name}", j + 1)
            val = self.anchors[name]
        else:
            text = rest
            if text[0] in "'\"" and (len(text) < 2 or text[-1] != text[0]):
                while self.i < len(self.raw):
                    nxt = self.raw[self.i].strip()
                    self.i += 1
                    text += " " + nxt
                    if nxt.endswith(rest[0]):
                        break
            else:
                while True:
                    p = self.peek()
                    if not p or p[1] <= ind or self.split_key(p[2]) is not None or p[2].startswith("- "):
                        break
                    self.consume(p[0])
                    text += " " + p[2]
            val = _scalar(text)
        if anchor:
            self.anchors[anchor] = val
        return val

    def block_scalar(self, indicator: str, ind: int):
        lines, k, content = [], self.i, None
        while k < len(self.raw):
            line = self.raw[k]
            if not line.strip():
                lines.append("")
                k += 1
                continue
            lead = len(line) - len(line.lstrip(" "))
            if content is None:
                if lead <= ind:
                    break
                content = lead
            if lead < content:
                break
            lines.append(line[content:])
            k += 1
        self.i = k
        while lines and lines[-1] == "":
            lines.pop()
        return ("\n" if indicator.startswith("|") else " ").join(lines)


def parse_yaml(text: str):
    y = _Yaml(text)
    doc = y.block(0)
    rest = y.peek()
    if rest is not None:
        raise YamlError("content after the document", rest[0] + 1)
    return doc


# === DOCKERFILE ===

KNOWN_DIRECTIVES = ("syntax", "escape", "check")
DIRECTIVE_RE = re.compile(r"^#\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(.*?)\s*$")
INSTR_RE = re.compile(r"^\s*([A-Za-z]+)(?:\s+(.*))?$", re.S)
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)(-?)\s*([\"']?)([A-Za-z_][\w.-]*)\2")
FLAG_RE = re.compile(r"--([a-z][a-z-]*)(?:=(\"[^\"]*\"|'[^']*'|\S*))?\s*")


class Instr:
    __slots__ = ("cmd", "args", "line", "heredoc", "comments", "flags", "rest", "stage")

    def __init__(self, cmd, args, line, heredoc, comments):
        self.cmd, self.args, self.line, self.heredoc, self.comments = cmd, args, line, heredoc, comments
        self.flags, self.rest = split_flags(args) if cmd in ("RUN", "COPY", "ADD", "FROM", "HEALTHCHECK") else ([], args)
        self.stage = None

    def flag(self, name):
        return [v for k, v in self.flags if k == name]

    @property
    def text(self):
        """Everything a shell would run: the instruction's arguments plus any heredoc bodies."""
        return self.rest + ("\n" + self.heredoc if self.heredoc else "")


def split_flags(args: str):
    flags, rest = [], args
    while True:
        m = FLAG_RE.match(rest)
        if not m:
            return flags, rest
        flags.append((m.group(1), (m.group(2) or "").strip("\"'")))
        rest = rest[m.end():]


def parse_dockerfile(text: str) -> dict:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    directives: dict = {}
    late: list = []
    i = 0
    # Parser directives count only at the very top. The first line that is not a known,
    # not-yet-seen directive (a comment, a blank, an instruction) ends that section; after
    # it a `# syntax=` line is a plain comment, and BuildKit ignores it without a word.
    while i < len(lines):
        m = DIRECTIVE_RE.match(lines[i].strip())
        if not m or m.group(1).lower() not in KNOWN_DIRECTIVES or m.group(1).lower() in directives:
            break
        directives[m.group(1).lower()] = m.group(2)
        i += 1
    escape = "`" if directives.get("escape") == "`" else "\\"
    instrs: list = []
    comments: list = []
    all_comments: list = []
    n = i
    while n < len(lines):
        s = lines[n].strip()
        if not s:
            comments = []
            n += 1
            continue
        if s.startswith("#"):
            m = DIRECTIVE_RE.match(s)
            if m and m.group(1).lower() in KNOWN_DIRECTIVES:
                late.append((n + 1, m.group(1).lower()))
            comments.append((n + 1, s))
            all_comments.append((n + 1, s))
            n += 1
            continue
        start = n
        parts = []
        while n < len(lines):
            cur = lines[n].rstrip()
            n += 1
            if cur.endswith(escape):
                parts.append(cur[:-1])
                # comment and empty lines inside a continuation are dropped by the parser
                while n < len(lines) and (not lines[n].strip() or lines[n].strip().startswith("#")):
                    n += 1
                continue
            parts.append(cur)
            break
        logical = " ".join(p.strip() for p in parts)
        m = INSTR_RE.match(logical)
        if not m:
            comments = []
            continue
        cmd, args = m.group(1).upper(), (m.group(2) or "").strip()
        bodies = []
        if cmd in ("RUN", "COPY", "ADD") and "<<" in args:
            for hm in HEREDOC_RE.finditer(args):
                strip_tabs, delim = hm.group(1) == "-", hm.group(3)
                body = []
                while n < len(lines):
                    line = lines[n]
                    n += 1
                    if (line.lstrip("\t") if strip_tabs else line).rstrip() == delim:
                        break
                    body.append(line)
                bodies.append("\n".join(body))
        instrs.append(Instr(cmd, args, start + 1, "\n".join(bodies), comments))
        comments = []
    stages, global_args, names = [], {}, {}
    for ins in instrs:
        if ins.cmd == "FROM":
            toks = ins.rest.split()
            name = toks[2] if len(toks) >= 3 and toks[1].lower() == "as" else None
            stage = {"index": len(stages), "image": toks[0] if toks else "", "name": name,
                     "line": ins.line, "instrs": [], "from": ins}
            if name:
                names.setdefault(name.lower(), []).append(stage)
            stages.append(stage)
        elif not stages:
            if ins.cmd == "ARG":
                for k, v in kv_pairs(ins.args):
                    global_args[k] = v
            continue
        ins.stage = stages[-1] if stages else None
        if stages and ins.cmd != "FROM":
            stages[-1]["instrs"].append(ins)
    return {"directives": directives, "late": late, "instrs": instrs, "stages": stages,
            "global_args": global_args, "names": names, "comments": all_comments}


def kv_pairs(args: str):
    """ENV/ARG/LABEL arguments -> [(key, value or None)]. Handles the legacy `ENV key value` form."""
    try:
        toks = shlex.split(args, posix=True)
    except ValueError:
        toks = args.split()
    if not toks:
        return []
    if "=" not in toks[0] and len(toks) > 1 and all("=" not in t for t in toks[1:2]):
        return [(toks[0], " ".join(toks[1:]))]
    out = []
    for t in toks:
        if "=" in t:
            k, v = t.split("=", 1)
            out.append((k, v))
        else:
            out.append((t, None))
    return out


def exec_tokens(rest: str):
    """COPY/ADD/CMD arguments as a list: JSON form if it parses, else shell words."""
    s = rest.strip()
    if s.startswith("["):
        try:
            val = json.loads(s)
            if isinstance(val, list) and all(isinstance(x, str) for x in val):
                return val, True
        except json.JSONDecodeError:
            pass
    try:
        return shlex.split(s, posix=True), False
    except ValueError:
        return s.split(), False


# === IMAGES ===

def parse_image_ref(ref: str):
    """'registry/ns/repo:tag@sha256:...' -> (registry or '', path, tag or '', digest or '')."""
    digest = ""
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    tag = ""
    if ":" in ref.rsplit("/", 1)[-1]:
        ref, tag = ref.rsplit(":", 1)
    parts = ref.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        return parts[0].lower(), "/".join(parts[1:]), tag, digest
    return "", ref, tag, digest


def repo_basename(path: str) -> str:
    return path.rsplit("/", 1)[-1].lower()


def resolve_vars(text: str, args: dict):
    """Substitute global ARG defaults into a FROM reference -> (resolved, unresolved names, undeclared names)."""
    unresolved, undeclared = [], []

    def sub(m):
        name = m.group(1) or m.group(3)
        op, fallback = m.group(2), m.group(4) if m.group(2) else None
        val = args.get(name)
        if name not in args:
            undeclared.append(name)
        if val:
            return val
        if op and op.lstrip(":") == "-" and fallback is not None:
            return fallback
        if name in args:
            unresolved.append(name)
        return ""

    out = re.sub(r"\$\{([A-Za-z_]\w*)(?:(:?[-+])([^}]*))?\}|\$([A-Za-z_]\w*)",
                 lambda m: sub(_VarMatch(m)), text)
    return out, unresolved, undeclared


class _VarMatch:
    """Normalise the two alternatives of the FROM variable regex to one shape."""

    def __init__(self, m):
        self._g = (m.group(1), m.group(2), m.group(4), m.group(3))

    def group(self, i):
        return self._g[i - 1]


def base_kind(ref: str) -> str:
    """'distroless' (no shell, no curl/wget), 'slim' (no curl/wget), 'alpine' (busybox wget,
    no curl), 'nonroot-distroless', or '' when unknown (assume a full image)."""
    if ref.lower() == "scratch":
        return "distroless"
    reg, path, tag, _ = parse_image_ref(ref)
    low = f"{reg}/{path}:{tag}".lower()
    if "distroless" in low or (reg == "cgr.dev" and not tag.endswith("-dev")):
        return "distroless"
    if "slim" in tag.lower():
        return "slim"
    if "alpine" in tag.lower() or repo_basename(path) == "alpine":
        return "alpine"
    return ""


def base_runs_nonroot(ref: str) -> bool:
    reg, path, tag, _ = parse_image_ref(ref)
    if "nonroot" in tag.lower() or "nonroot" in path.lower():
        return True
    # Chainguard images default to a non-root user; their -dev variants run as root.
    return reg == "cgr.dev" and not tag.endswith("-dev")


# === IGNOREFILE ===

def _ignore_regex(pattern: str):
    p = pattern.strip().lstrip("/")
    while p.startswith("./"):
        p = p[2:]
    p = p.rstrip("/")
    out, i = [], 0
    while i < len(p):
        c = p[i]
        if p[i:i + 3] == "**/":
            out.append("(?:.*/)?")
            i += 3
        elif p[i:i + 2] == "**":
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "[":
            j = p.find("]", i + 1)
            if j < 0:
                out.append(re.escape(c))
                i += 1
            else:
                body = p[i + 1:j].replace("\\", "\\\\")
                out.append("[" + ("^" + body[1:] if body.startswith("!") else body) + "]")
                i = j + 1
        elif c == "\\" and i + 1 < len(p):
            out.append(re.escape(p[i + 1]))
            i += 2
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def load_ignore(path: Path):
    rules = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        neg = s.startswith("!")
        rules.append((neg, _ignore_regex(s[1:] if neg else s)))
    return rules


def is_ignored(rel: str, rules) -> bool:
    """Docker's rule: a path is excluded when the LAST matching pattern (against the path or
    any of its parent directories) is not a `!` exception."""
    rel = rel.strip().lstrip("./") if rel.startswith("./") else rel.strip().lstrip("/")
    parts = rel.split("/")
    candidates = ["/".join(parts[:k]) for k in range(1, len(parts) + 1)]
    result = False
    for neg, rx in rules:
        if any(rx.match(c) for c in candidates):
            result = not neg
    return result


def find_ignore_file(dockerfile: Path, context: Path):
    # BuildKit reads <Dockerfile-name>.dockerignore next to the Dockerfile before the
    # context root's .dockerignore.
    specific = dockerfile.with_name(dockerfile.name + ".dockerignore")
    if specific.is_file():
        return specific
    general = context / ".dockerignore"
    return general if general.is_file() else None


# === PRAGMAS ===

PRAGMA_RE = re.compile(r"#\s*docker-audit\s+ignore=([^\s]*)(.*)$", re.I)
HADOLINT_RE = re.compile(r"#\s*hadolint\s+ignore=([A-Za-z0-9,]+)", re.I)
HADOLINT_GLOBAL_RE = re.compile(r"#\s*hadolint\s+global\s+ignore=([A-Za-z0-9,]+)", re.I)
REASON_RE = re.compile(r"reason=(\"[^\"]*\"|'[^']*'|\S+)")
UNTIL_RE = re.compile(r"until=(\S+)")


def parse_pragma(comment: str, today: dt.date):
    """-> None (not a pragma) or dict(checks, error, expired)."""
    m = PRAGMA_RE.search(comment)
    if not m:
        return None
    checks = [c for c in m.group(1).split(",") if c]
    tail = m.group(2)
    reason = REASON_RE.search(tail)
    until = UNTIL_RE.search(tail)
    error, expired = None, None
    unknown = [c for c in checks if c not in CHECKS]
    if not checks:
        error = "names no check"
    elif unknown:
        error = f"names an unknown check ({', '.join(unknown)})"
    elif not reason or not reason.group(1).strip("\"'").strip():
        error = 'has no reason="..."'
    if until and not error:
        try:
            end = dt.date.fromisoformat(until.group(1))
            if end < today:
                expired = end.isoformat()
        except ValueError:
            error = f"has a bad until= date {until.group(1)!r}"
    return {"checks": checks, "error": error, "expired": expired}


def hadolint_ids(comment: str):
    m = HADOLINT_RE.search(comment)
    return set(m.group(1).upper().split(",")) if m and not HADOLINT_GLOBAL_RE.search(comment) else set()


def checks_for(tool: str, ids) -> set:
    want = {i.lower() for i in ids}
    return {name for name, (_, _, _, refs) in CHECKS.items()
            if "all" in want or any(x.lower() in want for x in refs.get(tool, []))}


# === DF-CHECKS ===

INSTALL_RE = re.compile(
    r"\b(npm\s+(ci|install|i)\b|yarn(\s+install)?\b|pnpm\s+(install|i)\b|bun\s+install\b|"
    r"pip3?\s+install\s+(-r|--requirement)\b|uv\s+(sync|pip\s+install)\b|poetry\s+install\b|"
    r"composer\s+install\b|bundle\s+install\b|go\s+mod\s+download\b)")
PKG_INSTALL_RE = re.compile(r"\b(apt-get\s+(-\S+\s+)*install|apk\s+add|pip3?\s+install|dnf\s+install|yum\s+install|microdnf\s+install)\b")
TLS_OFF = [
    (re.compile(r"\bcurl\b[^\n;&|]*\s(--insecure\b|-[A-Za-z]*k[A-Za-z]*\b)"), "curl -k/--insecure"),
    (re.compile(r"--no-check-certificate\b"), "wget --no-check-certificate"),
    (re.compile(r"http\.sslverify[\s=]+(false|0)\b", re.I), "git http.sslVerify=false"),
    (re.compile(r"\bGIT_SSL_NO_VERIFY\b"), "GIT_SSL_NO_VERIFY"),
    (re.compile(r"--trusted-host\b|\bPIP_TRUSTED_HOST\b"), "pip --trusted-host"),
    (re.compile(r"\bPYTHONHTTPSVERIFY\s*=\s*0"), "PYTHONHTTPSVERIFY=0"),
    (re.compile(r"\bNODE_TLS_REJECT_UNAUTHORIZED\s*=\s*['\"]?0"), "NODE_TLS_REJECT_UNAUTHORIZED=0"),
    (re.compile(r"strict-ssl[\s=]+false\b|\bNPM_CONFIG_STRICT_SSL\s*=\s*['\"]?false", re.I), "npm/yarn strict-ssl false"),
    (re.compile(r"--allow-unauthenticated\b|--allow-insecure-repositories\b|\[trusted=yes\]|AllowUnauthenticated", re.I),
     "apt without signature checks"),
    (re.compile(r"--allow-untrusted\b"), "apk --allow-untrusted"),
    (re.compile(r"--nogpgcheck\b|\bgpgcheck\s*=\s*0\b|--no-gpg-checks\b"), "rpm-family package without GPG check"),
    (re.compile(r"\bsslverify\s*=\s*(0|false)\b", re.I), "yum/dnf sslverify off"),
    (re.compile(r"--nosignature\b|--nodigest\b"), "rpm --nosignature/--nodigest"),
    (re.compile(r"disable-tls\b|secure-http[\s=]+false\b"), "composer TLS off"),
    (re.compile(r"\bGOINSECURE\b|\bGOSUMDB\s*=\s*['\"]?off\b"), "Go module verification off"),
]
PIPE_TO_SHELL_RE = re.compile(
    r"\b(curl|wget)\b[^\n;&]*\|\s*(sudo\s+)?(-?\s*)?(ba|z|da|a|k)?sh\b|"
    r"\b(curl|wget)\b[^\n;&]*\|\s*(sudo\s+)?(python3?|perl|ruby|node)\b|"
    r"\b(ba)?sh\s+(-c\s+)?[\"']?\$\(\s*(curl|wget)\b|\b(ba)?sh\s+<\(\s*(curl|wget)\b")
SECRET_FILES = [
    (re.compile(r"(^|/)\.env(\.(?!example$|sample$|dist$|template$|defaults?$)[\w.-]+)?$", re.I), "high"),
    (re.compile(r"(^|/)(\.npmrc|\.pypirc|\.netrc|\.git-credentials|auth\.json|kubeconfig)$", re.I), "high"),
    (re.compile(r"(^|/)\.(aws/credentials|docker/config\.json|kube/config)$", re.I), "high"),
    (re.compile(r"(^|/)id_(rsa|dsa|ecdsa|ed25519)$", re.I), "high"),
    (re.compile(r"\.(key|p12|pfx|jks|keystore)$", re.I), "high"),
    (re.compile(r"\.pem$", re.I), "medium"),
]


def _sev(check: str) -> str:
    return CHECKS[check][1]


def _strip_quoted(s: str) -> str:
    return re.sub(r"'[^']*'|\"(?:\\.|[^\"\\])*\"", "''", s)


def _secret_name(name: str) -> bool:
    return bool(SECRET_KEY_RE.search(name)) and not SECRET_KEY_EXEMPT_RE.search(name)


def _literal(value) -> bool:
    """True when a value carries literal text, not only ${VAR} references."""
    if value is None or isinstance(value, bool):
        return False
    s = str(value).replace("$$", "")
    if not s.strip():
        return False
    if REF_OP_RE.search(s):
        if any(op.lstrip(":") in ("-", "+", "=") and lit.strip() for op, lit in REF_OP_RE.findall(s)):
            return True
        s = REF_OP_RE.sub("", s)
    return bool(REF_RE.sub("", s).strip())


class Audit:
    def __init__(self, cat: dict, opts):
        self.cat, self.opts = cat, opts
        self.findings: list = []

    def add(self, check, file, line, detail, severity=None, origin=None):
        self.findings.append({"severity": severity or _sev(check), "check": check, "family": CHECKS[check][0],
                              "file": file, "line": line, "detail": detail, "origin": origin})

    # --- Dockerfile ---
    def dockerfile(self, rel: str, df: dict, path: Path, context: Path):
        stages = df["stages"]
        if not stages:
            return
        for line, name in df["late"]:
            self.add("directive-ignored", rel, line,
                     f"`# {name}=` is not on the first lines of the file, so BuildKit reads it as a comment; "
                     "parser directives must come before any comment, blank line or instruction")
        if "syntax" not in df["directives"]:
            self.add("syntax-directive-missing", rel, 1,
                     "add `# syntax=docker/dockerfile:1` as line 1 to get the current Dockerfile frontend")
        seen_names: dict = {}
        for st in stages:
            if st["name"]:
                key = st["name"].lower()
                if key in seen_names:
                    self.add("duplicate-stage-name", rel, st["line"],
                             f"stage name {st['name']!r} is also used on line {seen_names[key]}")
                seen_names.setdefault(key, st["line"])
        for st in stages:
            self._base(rel, df, st)
        final = stages[-1]
        self._user(rel, df, final)
        self._healthcheck(rel, df, final)
        if not any(i.cmd == "LABEL" and "org.opencontainers.image." in i.args for i in self._chain(df, final)):
            self.add("oci-labels-missing", rel, final["line"],
                     "add LABEL org.opencontainers.image.source=... (and .version, .revision) to the final stage",
                     severity="low" if self.opts.production else None)
        shell_pipefail = {}
        for st in stages:
            pf = False
            for ins in st["instrs"]:
                if ins.cmd == "SHELL" and "pipefail" in ins.args:
                    pf = True
                self._instr(rel, df, st, ins, pf)
            shell_pipefail[st["index"]] = pf
        self._context(rel, df, path, context)

    def _chain(self, df: dict, st: dict):
        """Instructions of a stage plus those of the stages it is built FROM."""
        out, seen = [], set()
        while st and st["index"] not in seen:
            seen.add(st["index"])
            out = st["instrs"] + out
            parent = df["names"].get(st["image"].lower())
            parent = [p for p in parent if p["index"] < st["index"]] if parent else []
            st = parent[-1] if parent else None
        return out

    def _base_ref(self, df: dict, st: dict):
        """The external image a stage ultimately starts from (following FROM <stage>), or None."""
        seen = set()
        while st and st["index"] not in seen:
            seen.add(st["index"])
            parent = df["names"].get(st["image"].lower())
            parent = [p for p in parent if p["index"] < st["index"]] if parent else []
            if not parent:
                ref, unresolved, _ = resolve_vars(st["image"], df["global_args"])
                return None if unresolved or "$" in ref else ref
            st = parent[-1]
        return None

    def _base(self, rel, df, st):
        image = st["image"]
        earlier = df["names"].get(image.lower())
        if earlier and any(p["index"] < st["index"] for p in earlier):
            return None
        if image.lower() == "scratch":
            return "scratch"
        ref, unresolved, undeclared = resolve_vars(image, df["global_args"])
        if undeclared:
            self.add("base-arg-unresolved", rel, st["line"],
                     f"FROM {image}: ARG {', '.join(sorted(set(undeclared)))} is not declared before the first FROM")
            return None
        if unresolved or not ref:
            self.add("base-arg-unresolved", rel, st["line"],
                     f"FROM {image}: ARG {', '.join(sorted(set(unresolved)))} has no default, so the base is "
                     "whatever --build-arg passes; give it a pinned default")
            return None
        reg, path, tag, digest = parse_image_ref(ref)
        shown = ref if ref == image else f"{image} (= {ref})"
        if not tag and not digest:
            self.add("base-untagged", rel, st["line"], f"FROM {shown}: no tag, so it means :latest")
        elif tag.lower() == "latest" and not digest:
            self.add("base-latest", rel, st["line"], f"FROM {shown}: pin a version tag")
        self._eol(rel, st["line"], shown, path, tag)
        if self.opts.allow_registry:
            effective = reg or "docker.io"
            if effective not in self.opts.allow_registry:
                self.add("base-registry", rel, st["line"],
                         f"FROM {shown}: registry {effective} is not in --allow-registry")
        if self.opts.production and not digest:
            self.add("base-not-digest", rel, st["line"], f"FROM {shown}: add @sha256:<digest> for a reproducible base")
        return ref

    def _eol(self, rel, line, shown, path, tag, family="base-eol"):
        name = repo_basename(path)
        if path.lower() not in (name, f"library/{name}"):
            return
        floor = self.cat.get("eol_floor", {}).get(name)
        m = re.match(r"^(\d+)(?:\.(\d+))?", tag or "")
        if not floor or not m:
            return
        have = (int(m.group(1)), int(m.group(2) or 0))
        fparts = floor.split(".")
        want = (int(fparts[0]), int(fparts[1]) if len(fparts) > 1 else 0)
        if len(fparts) == 1:
            have = (have[0], 0)
        elif m.group(2) is None:
            return  # python:3 floats to the newest 3.x
        if have < want:
            self.add(family, rel, line, f"{shown}: {name} {m.group(0)} is past end of life "
                     f"(the oldest supported line is {floor}); see assets/docker-facts.json")

    def _user(self, rel, df, final):
        chain = self._chain(df, final)
        users = [i for i in chain if i.cmd == "USER"]
        base = self._base_ref(df, final)
        if users:
            last = users[-1]
            name = last.args.split(":")[0].strip().strip("\"'")
            if name in ("root", "0"):
                self.add("final-user-root", rel, last.line, f"USER {last.args}: the container runs as root; "
                         "switch to a non-root user after the steps that need root")
            return
        if base and base_runs_nonroot(base):
            return
        self.add("final-user-unset", rel, final["line"],
                 f"the final stage (FROM {final['image']}) never sets USER, so the container runs as root")

    def _healthcheck(self, rel, df, final):
        chain = self._chain(df, final)
        hcs = [i for i in chain if i.cmd == "HEALTHCHECK"]
        if not hcs:
            return
        hc = hcs[-1]
        rest = hc.rest.strip()
        if rest.upper().startswith("NONE"):
            return
        m = re.match(r"(?i)CMD\s+(.*)$", rest, re.S)
        if not m:
            return
        cmd = m.group(1).strip()
        base = self._base_ref(df, final)
        kind = base_kind(base) if base else ""
        if not kind:
            return
        tokens, is_exec = exec_tokens(cmd)
        installed = " ".join(i.text for i in chain if i.cmd == "RUN")
        copied = " ".join(i.rest for i in chain if i.cmd in ("COPY", "ADD"))
        if kind == "distroless" and not is_exec:
            self.add("healthcheck-tool-missing", rel, hc.line,
                     f"shell-form HEALTHCHECK needs /bin/sh, which {base} does not have; use the exec form "
                     "with a binary the image ships (often the app's own health subcommand)")
            return
        tool = None
        joined = " ".join(tokens)
        for t in ("curl", "wget"):
            if re.search(rf"(^|[\s/]){t}\b", joined):
                tool = t
                break
        if not tool:
            return
        if re.search(rf"\b(apt-get|apk|dnf|yum|microdnf)\b[^\n]*\b{tool}\b", installed) or re.search(rf"\b{tool}\b", copied):
            return
        if kind == "alpine" and tool == "wget":
            return  # busybox wget ships in alpine
        self.add("healthcheck-tool-missing", rel, hc.line,
                 f"HEALTHCHECK runs {tool}, which {base} does not ship; install it in this stage, "
                 "or probe with the app's own binary")

    def _instr(self, rel, df, st, ins, shell_pipefail):
        c = ins.cmd
        if c in ("ARG", "ENV"):
            for k, v in kv_pairs(ins.args):
                if not _secret_name(k):
                    continue
                if v is not None and _literal(v):
                    self.add("secret-in-arg-env", rel, ins.line,
                             f"{c} {k} has a literal value, which is stored in the image "
                             f"{'history' if c == 'ARG' else 'config'}; use RUN --mount=type=secret,id={k.lower()}")
                elif c == "ARG" or (v is not None and v.strip()):
                    self.add("secret-in-arg-env", rel, ins.line,
                             f"{c} {k}: a value passed in lands in the image "
                             f"{'history of every RUN that uses it' if c == 'ARG' else 'config'}; "
                             "use a secret mount instead", severity="medium")
            if c == "ENV":
                for rx, what in TLS_OFF:
                    if rx.search(ins.args):
                        self.add("tls-verify-off", rel, ins.line, f"ENV turns verification off for every later step: {what}")
            return
        if c in ("COPY", "ADD"):
            self._copy(rel, ins)
            return
        if c in ("CMD", "ENTRYPOINT"):
            _, is_exec = exec_tokens(ins.rest)
            if not is_exec and ins.rest.strip():
                self.add("cmd-shell-form", rel, ins.line,
                         f'{c} {ins.rest.strip()[:60]}: write it as {c} ["executable", "arg"] so the process gets SIGTERM')
            same = [i for i in st["instrs"] if i.cmd == c]
            if len(same) > 1 and ins is same[-1]:
                self.add("multiple-cmd", rel, ins.line,
                         f"{len(same)} {c} instructions in this stage; only this last one takes effect")
            return
        if c == "MAINTAINER":
            self.add("maintainer-deprecated", rel, ins.line, 'use LABEL org.opencontainers.image.authors="..."')
            return
        if c == "EXPOSE":
            if re.search(r"(^|\s)22(/tcp)?(\s|$)", ins.args):
                self.add("expose-ssh", rel, ins.line, "EXPOSE 22: use `docker exec` instead of an SSH daemon")
            return
        if c == "WORKDIR":
            w = ins.args.strip().strip("\"'")
            if w and not w.startswith(("/", "$")) and not re.match(r"^[A-Za-z]:[\\/]", w):
                self.add("workdir-relative", rel, ins.line, f"WORKDIR {w}: use an absolute path")
            return
        if c != "RUN":
            return
        self._run(rel, df, st, ins, shell_pipefail)

    def _copy(self, rel, ins):
        tokens, _ = exec_tokens(ins.rest)
        if ins.heredoc or len(tokens) < 2:
            return
        sources = tokens[:-1]
        if ins.flag("from"):
            return
        if ins.cmd == "ADD":
            for src in sources:
                if re.match(r"https?://", src):
                    if not ins.flag("checksum"):
                        self.add("add-url-unverified", rel, ins.line,
                                 f"ADD {src}: add --checksum=sha256:<hash>, or download with curl and verify")
                elif not re.search(r"\.(tar|tgz|tbz2?|txz|tar\.(gz|bz2|xz|zst))$", src) and not src.startswith("git@"):
                    self.add("add-local-file", rel, ins.line, f"ADD {src}: use COPY for local files")
                    break
        for src in sources:
            clean = src.strip("/")
            for rx, sev in SECRET_FILES:
                if rx.search(clean):
                    self.add("secret-file-copied", rel, ins.line,
                             f"{ins.cmd} {src}: a credential file in a layer stays in the image even if a later "
                             "step deletes it; use RUN --mount=type=secret"
                             + (" (if this is a public CA certificate, suppress with a reason)" if sev == "medium" else ""),
                             severity=sev)
                    break

    def _run(self, rel, df, st, ins, shell_pipefail):
        text = ins.text
        bare = _strip_quoted(text)
        mounts = ins.flag("mount")
        cache_mounts = [m for m in mounts if "type=cache" in m]
        for m in mounts:
            if "type=secret" in m and not re.search(r"required=(true|1)\b", m):
                self.add("secret-mount-optional", rel, ins.line,
                         f"--mount={m}: add required=true so a missing secret fails the build instead of "
                         "building without it")
        for rx, what in TLS_OFF:
            if rx.search(text):
                self.add("tls-verify-off", rel, ins.line, f"{what}: the download is no longer authenticated")
        if PIPE_TO_SHELL_RE.search(text):
            self.add("pipe-to-shell", rel, ins.line,
                     "a fetched script goes straight to an interpreter; download it, check its sha256, then run it")
        if re.search(r"StrictHostKeyChecking\s*[= ]\s*no|UserKnownHostsFile\s*[= ]\s*/dev/null", text):
            self.add("ssh-hostkey-off", rel, ins.line,
                     "SSH host-key checking is off; bake the host's known_hosts line into the build instead")
        elif re.search(r"\bssh-keyscan\b", text):
            self.add("ssh-hostkey-off", rel, ins.line,
                     "ssh-keyscan at build time trusts whatever key answers; pin the known_hosts line instead",
                     severity="low")
        if re.search(r"\bsudo\b", bare):
            self.add("sudo-in-run", rel, ins.line, "drop sudo; switch USER around the steps that need it")
        if re.search(r"(^|[;&|]\s*|\s)cd\s+\S", bare) and not re.search(r"\(\s*cd\b", bare):
            self.add("cd-in-run", rel, ins.line, "use WORKDIR, or keep the cd inside a subshell")
        if re.search(r"\bapt\s+(-\S+\s+)*(install|update|upgrade|remove|purge|dist-upgrade)\b", bare):
            self.add("apt-not-apt-get", rel, ins.line, "use apt-get in scripts")
        has_update = re.search(r"\bapt(-get)?\s+(-\S+\s+)*update\b", bare)
        has_install = re.search(r"\bapt(-get)?\s+(-\S+\s+)*install\b", bare)
        if has_update and not has_install:
            self.add("apt-update-alone", rel, ins.line,
                     "run apt-get update in the same RUN as apt-get install, or the cached index goes stale")
        if has_install and not re.search(r"--no-install-recommends|Install-Recommends\s*=?\s*(false|0)", bare):
            self.add("apt-no-recommends", rel, ins.line, "add --no-install-recommends")
        apt_cache = [m for m in cache_mounts if re.search(r"target=/var/(cache|lib)/apt", m)]
        if apt_cache:
            if re.search(r"rm\s+-[a-zA-Z]*\s+/var/lib/apt/lists|apt-get\s+clean", bare):
                self.add("apt-cache-mount-wiped", rel, ins.line,
                         "this RUN mounts an apt cache and then deletes it; drop the rm/clean when using cache mounts")
            elif any("/var/cache/apt" in m for m in apt_cache) and not self._docker_clean_removed(df, st, ins):
                self.add("apt-cache-mount-wiped", rel, ins.line,
                         "Debian/Ubuntu images ship /etc/apt/apt.conf.d/docker-clean, which empties /var/cache/apt "
                         "after every install; remove it (rm -f /etc/apt/apt.conf.d/docker-clean) before this RUN")
        elif has_install and not re.search(r"/var/lib/apt/lists", bare):
            self.add("package-cache-in-layer", rel, ins.line,
                     "apt lists stay in the layer; use cache mounts (--mount=type=cache,target=/var/lib/apt,"
                     "sharing=locked and target=/var/cache/apt) or clean up in the same RUN")
        if re.search(r"\bapk\s+(-\S+\s+)*add\b", bare) and "--no-cache" not in bare and not any(
                "/var/cache/apk" in m or "/etc/apk/cache" in m for m in cache_mounts):
            self.add("package-cache-in-layer", rel, ins.line, "apk add without --no-cache (or a cache mount)")
        if re.search(r"\bpip3?\s+install\b", bare) and "--no-cache-dir" not in bare and \
                not re.search(r"\buv\s+pip\b", bare) and not any("pip" in m or ".cache" in m for m in cache_mounts) \
                and not self._env_set(df, st, "PIP_NO_CACHE_DIR"):
            self.add("package-cache-in-layer", rel, ins.line, "pip install without --no-cache-dir (or a cache mount)")
        self._lockfile(rel, ins, bare)
        if PKG_INSTALL_RE.search(bare) and not cache_mounts:
            self.add("cache-mount-missing", rel, ins.line,
                     "a --mount=type=cache for the package manager keeps downloads between builds and out of the layer")
        if not shell_pipefail and not ins.rest.strip().startswith("[") and re.search(r"(?<!\|)\|(?!\|)", bare) \
                and not re.search(r"set\s+-[a-zA-Z]*o\s+pipefail|-o\s+pipefail", text):
            self.add("pipe-no-pipefail", rel, ins.line,
                     'a failure on the left of | is ignored; add `set -o pipefail &&` (bash) or '
                     'SHELL ["/bin/bash", "-o", "pipefail", "-c"]')

    def _lockfile(self, rel, ins, bare):
        for seg in re.split(r"&&|\|\||;|\n", bare):
            seg = seg.strip()
            m = re.search(r"\bnpm\s+(install|i)\b(.*)$", seg)
            if m and not [a for a in m.group(2).split() if not a.startswith("-")]:
                self.add("lockfile-not-enforced", rel, ins.line,
                         "npm install can rewrite package-lock.json; use npm ci (see package-manager-ops)")
                return
            if re.search(r"\byarn(\s+install)?\s*$|\byarn\s+install\b", seg) and \
                    not re.search(r"--frozen-lockfile|--immutable", seg) and not re.search(r"\byarn\s+(add|run|build|global)\b", seg):
                self.add("lockfile-not-enforced", rel, ins.line, "yarn install without --immutable (Berry) / --frozen-lockfile (v1)")
                return
            if re.search(r"\bpnpm\s+(install|i)\b", seg) and "--frozen-lockfile" not in seg:
                self.add("lockfile-not-enforced", rel, ins.line, "pnpm install without --frozen-lockfile")
                return
            if re.search(r"\bbun\s+install\b", seg) and "--frozen-lockfile" not in seg:
                self.add("lockfile-not-enforced", rel, ins.line, "bun install without --frozen-lockfile")
                return
            if re.search(r"\bcomposer\s+update\b", seg):
                self.add("lockfile-not-enforced", rel, ins.line, "composer update resolves fresh versions; use composer install")
                return
            if re.search(r"\buv\s+sync\b", seg) and not re.search(r"--locked|--frozen", seg):
                self.add("lockfile-not-enforced", rel, ins.line, "uv sync without --locked can rewrite uv.lock",
                         severity="low")
                return

    def _env_set(self, df, st, name) -> bool:
        return any(i.cmd == "ENV" and any(k == name for k, _ in kv_pairs(i.args)) for i in self._chain(df, st))

    def _docker_clean_removed(self, df, st, ins) -> bool:
        for i in self._chain(df, st):
            if i is ins:
                break
            if i.cmd == "RUN" and "docker-clean" in i.text and re.search(r"\brm\b", i.text):
                return True
        return "docker-clean" in ins.text and bool(re.search(r"\brm\b", ins.text))

    def _context(self, rel, df, path: Path, context: Path):
        ignore_file = find_ignore_file(path, context)
        rules = load_ignore(ignore_file) if ignore_file else []
        whole = []
        for ins in df["instrs"]:
            if ins.cmd in ("COPY", "ADD") and not ins.flag("from") and not ins.heredoc:
                tokens, _ = exec_tokens(ins.rest)
                for src in tokens[:-1]:
                    s = src.strip()
                    if s in (".", "./", "*", "./*"):
                        whole.append(ins)
                    elif rules and not re.match(r"https?://", s) and "*" not in s and "$" not in s \
                            and is_ignored(s, rules):
                        self.add("copy-ignored-file", rel, ins.line,
                                 f"{ins.cmd} {s}: {ignore_file.name} excludes it, so the build cannot find it")
        for st in df["stages"]:
            copied_all = None
            for ins in st["instrs"]:
                if ins in whole and copied_all is None:
                    copied_all = ins
                elif ins.cmd == "RUN" and copied_all is not None and INSTALL_RE.search(ins.text):
                    self.add("copy-all-before-install", rel, copied_all.line,
                             f"{copied_all.cmd} {copied_all.rest.strip()} comes before the install on line {ins.line}; "
                             "copy the manifests and lockfile first, install, then copy the rest")
                    break
        if not whole:
            return
        if not ignore_file:
            self.add("dockerignore-missing", rel, whole[0].line,
                     f"{whole[0].cmd} {whole[0].rest.strip()} sends the whole context, and there is no "
                     f".dockerignore in {context.name or '.'}/ (at least: .git, .env*, node_modules, secrets)")
        try:
            entries = sorted(os.listdir(context))
        except OSError:
            return
        for name in entries:
            full = context / name
            if name == ".git" and not is_ignored(".git", rules):
                self.add("dockerignore-gap", rel, whole[0].line,
                         ".git is copied into the build: the whole history ships, and every commit busts the cache",
                         severity="medium")
            elif full.is_file() and not is_ignored(name, rules):
                for rx, sev in SECRET_FILES:
                    if rx.search(name):
                        self.add("dockerignore-gap", rel, whole[0].line,
                                 f"{name} sits in the build context and {whole[0].cmd} {whole[0].rest.strip()} "
                                 "copies it into a layer; add it to .dockerignore", severity=sev)
                        break

# === COMPOSE ===
    def compose(self, rel: str, doc: YMap, project: dict, dockerfiles: dict):
        if "version" in doc:
            self.add("compose-version-obsolete", rel, doc.lines.get("version", 1),
                     "delete the top-level `version:` line; Compose ignores it")
        if Path(rel).name.lower().startswith("docker-compose"):
            self.add("compose-legacy-filename", rel, 1, "rename to compose.yaml (Compose reads both)")
        services = doc.get("services")
        if not isinstance(services, dict):
            return
        for name, svc in services.items():
            if not isinstance(svc, dict):
                continue
            line = services.lines.get(name, 1)
            self._service(rel, name, svc, line, project, dockerfiles)

    def _service(self, rel, name, svc, sline, project, dockerfiles):
        L = svc.lines.get
        image = svc.get("image") if isinstance(svc.get("image"), str) else None
        build = svc.get("build")
        if image and "$" not in image:
            reg, path, tag, digest = parse_image_ref(image)
            if build:
                if not reg and "/" not in path and svc.get("pull_policy") not in ("build", "never"):
                    self.add("build-and-image", rel, L("image", sline),
                             f"service {name}: image {image} also names a Docker Hub library image, so "
                             "`docker compose pull` fetches that instead of building; add `pull_policy: build` "
                             "or a registry-qualified name")
            elif not tag and not digest:
                self.add("image-untagged", rel, L("image", sline), f"service {name}: image {image} has no tag")
            elif tag.lower() == "latest" and not digest:
                self.add("image-latest", rel, L("image", sline), f"service {name}: image {image}")
            if not build:
                self._eol(rel, L("image", sline), f"service {name}: image {image}", path, tag)
        self._env(rel, name, svc.get("environment"), svc.lines.get("environment", sline), "environment")
        if isinstance(build, dict):
            self._env(rel, name, build.get("args"), build.lines.get("args", sline), "build.args")
        self._ports(rel, name, svc, image)
        self._escapes(rel, name, svc, sline)
        if self.opts.production:
            missing = []
            if svc.get("read_only") is not True:
                missing.append("read_only: true")
            if not any(str(c).upper() == "ALL" for c in (svc.get("cap_drop") or [])):
                missing.append("cap_drop: [ALL]")
            if not any("no-new-privileges" in str(o) for o in (svc.get("security_opt") or [])):
                missing.append("security_opt: [no-new-privileges:true]")
            limits = ((svc.get("deploy") or {}).get("resources") or {}).get("limits") if isinstance(svc.get("deploy"), dict) else None
            if not svc.get("mem_limit") and not (isinstance(limits, dict) and limits.get("memory")):
                missing.append("a memory limit")
            if not svc.get("restart") and not (isinstance(svc.get("deploy"), dict) and svc["deploy"].get("restart_policy")):
                missing.append("restart:")
            if missing:
                self.add("hardening-missing", rel, sline, f"service {name}: missing {', '.join(missing)}")
        self._depends(rel, name, svc, sline, project, dockerfiles)
        self._resources(rel, name, svc, project)

    def _env(self, rel, name, env, line, where):
        if isinstance(env, dict):
            items = [(k, v, env.lines.get(k, line)) for k, v in env.items()]
        elif isinstance(env, list):
            items = []
            for idx, entry in enumerate(env):
                if isinstance(entry, str) and "=" in entry:
                    k, v = entry.split("=", 1)
                    items.append((k, v, env.lines[idx] if idx < len(env.lines) else line))
        else:
            return
        for k, v, ln in items:
            if _secret_name(str(k)) and _literal(v):
                self.add("compose-literal-secret", rel, ln,
                         f"service {name}: {where} {k} is set to a literal; read it from the environment "
                         f"(${{{k}}}), an env_file kept out of git, or a Compose secret")

    def _ports(self, rel, name, svc, image):
        ports = svc.get("ports")
        if not isinstance(ports, list):
            return
        store = image and repo_basename(parse_image_ref(image)[1]) in DATASTORES
        for idx, p in enumerate(ports):
            ln = ports.lines[idx] if idx < len(ports.lines) else svc.lines.get("ports", 1)
            host_ip, shown = None, str(p)
            if isinstance(p, dict):
                host_ip = p.get("host_ip")
                shown = f"{p.get('published', '')}:{p.get('target', '')}"
            else:
                s = str(p).split("/")[0]
                if s.startswith("["):
                    host_ip = s[1:s.index("]")] if "]" in s else None
                else:
                    parts = s.split(":")
                    host_ip = parts[0] if len(parts) == 3 else None
            if host_ip and host_ip not in ("0.0.0.0", "::", ""):
                continue
            if store:
                self.add("datastore-published", rel, ln,
                         f"service {name}: {shown} publishes the {repo_basename(parse_image_ref(image)[1])} port on "
                         "every interface (on Docker Desktop that includes your LAN); bind 127.0.0.1:... or drop "
                         "the port and reach it over the Compose network")
            else:
                self.add("port-all-interfaces", rel, ln,
                         f"service {name}: {shown} listens on every interface; write 127.0.0.1:{shown} for local-only")

    def _escapes(self, rel, name, svc, sline):
        L = svc.lines.get
        if svc.get("privileged") is True:
            self.add("host-escape", rel, L("privileged", sline), f"service {name}: privileged: true is root on the host")
        for key in ("network_mode", "pid", "ipc", "userns_mode", "uts"):
            if str(svc.get(key, "")).lower() == "host":
                self.add("host-escape", rel, L(key, sline), f"service {name}: {key}: host shares the host's namespace")
        for cap in svc.get("cap_add") or []:
            if str(cap).upper().removeprefix("CAP_") in ("ALL", "SYS_ADMIN", "SYS_PTRACE", "SYS_MODULE", "DAC_READ_SEARCH", "NET_ADMIN"):
                self.add("host-escape", rel, L("cap_add", sline), f"service {name}: cap_add {cap}")
        for opt in svc.get("security_opt") or []:
            if re.search(r"unconfined|label[:=]disable", str(opt)):
                self.add("host-escape", rel, L("security_opt", sline), f"service {name}: security_opt {opt}")
        vols = svc.get("volumes")
        if not isinstance(vols, list):
            return
        for idx, v in enumerate(vols):
            ln = vols.lines[idx] if idx < len(vols.lines) else L("volumes", sline)
            src = v.get("source") if isinstance(v, dict) else str(v).split(":")[0] if not re.match(r"^[A-Za-z]:[\\/]", str(v)) else str(v)[:2]
            if not src:
                continue
            src = str(src)
            if re.search(r"(docker|podman|containerd)\.sock$", src):
                self.add("host-escape", rel, ln, f"service {name}: mounts {src}, which is root on the host")
            elif src.rstrip("/") in ("", "/etc", "/root", "/proc", "/sys", "/dev", "/var/run", "/run", "/var/lib/docker") or src == "/":
                self.add("host-escape", rel, ln, f"service {name}: mounts host path {src}")
            elif re.match(r"^(~|\$HOME|\$\{HOME\})/?$", src):
                self.add("host-escape", rel, ln, f"service {name}: mounts the whole home directory")
            elif re.match(r"^(~|\$HOME|\$\{HOME\})/\.(ssh|aws|kube|docker|gnupg|config/gcloud|azure)\b", src):
                self.add("host-escape", rel, ln, f"service {name}: mounts host credentials {src}", severity="medium")

    def _depends(self, rel, name, svc, sline, project, dockerfiles):
        dep = svc.get("depends_on")
        if isinstance(dep, list):
            deps = {str(d): None for d in dep}
        elif isinstance(dep, dict):
            deps = {k: (v or {}).get("condition") if isinstance(v, dict) else None for k, v in dep.items()}
        else:
            return
        ln = svc.lines.get("depends_on", sline)
        for d, cond in deps.items():
            target = project["services"].get(d)
            if not isinstance(target, dict):
                continue
            timg = target.get("image") if isinstance(target.get("image"), str) else ""
            if cond == "service_healthy":
                hc = target.get("healthcheck")
                has = isinstance(hc, dict) and not hc.get("disable") and hc.get("test") not in (None, ["NONE"], "NONE")
                if not has and not self._built_with_healthcheck(target, project, dockerfiles):
                    self.add("healthy-without-healthcheck", rel, ln,
                             f"service {name} waits for {d} to be healthy, but {d} has no healthcheck in Compose"
                             + (" (unless its image defines one)" if timg else ""))
            elif timg and repo_basename(parse_image_ref(timg)[1]) in DATASTORES:
                self.add("depends-on-unordered", rel, ln,
                         f"service {name} depends on {d} without condition: service_healthy, so it can start "
                         f"before {d} accepts connections; add a healthcheck to {d} and the condition here")

    def _built_with_healthcheck(self, target, project, dockerfiles) -> bool:
        build = target.get("build")
        if not build:
            return False
        df_path = compose_dockerfile(project["dir"], build)
        df = dockerfiles.get(df_path) if df_path else None
        if not df or not df["stages"]:
            return False
        return any(i.cmd == "HEALTHCHECK" and not i.rest.strip().upper().startswith("NONE")
                   for i in self._chain(df, df["stages"][-1]))

    def _resources(self, rel, name, svc, project):
        if svc.get("network_mode"):
            nets = []
        else:
            n = svc.get("networks")
            nets = list(n.keys()) if isinstance(n, dict) else [str(x) for x in n] if isinstance(n, list) else []
        checks = [("network", nets, project["networks"], svc.lines.get("networks"))]
        vols = svc.get("volumes") if isinstance(svc.get("volumes"), list) else []
        named = []
        for v in vols:
            if isinstance(v, dict):
                if v.get("type", "volume") == "volume" and v.get("source"):
                    named.append(str(v["source"]))
            else:
                src = str(v).split(":")[0]
                if ":" in str(v) and src and not re.match(r"^([./~$]|[A-Za-z]:)", src):
                    named.append(src)
        checks.append(("volume", named, project["volumes"], svc.lines.get("volumes")))
        for kind in ("secrets", "configs"):
            items = svc.get(kind) if isinstance(svc.get(kind), list) else []
            refs = [str(x.get("source")) if isinstance(x, dict) else str(x) for x in items]
            checks.append((kind[:-1], refs, project[kind], svc.lines.get(kind)))
        for kind, used, declared, ln in checks:
            for u in used:
                if u != "default" and u not in declared:
                    self.add("undeclared-resource", rel, ln or 1,
                             f"service {name} uses {kind} {u!r}, which no top-level `{kind}s:` in this project declares")


DATASTORES = {"postgres", "postgis", "mysql", "mariadb", "percona", "redis", "valkey", "keydb", "mongo", "mongodb",
              "elasticsearch", "opensearch", "memcached", "rabbitmq", "cassandra", "scylla", "couchdb", "couchbase",
              "neo4j", "clickhouse-server", "clickhouse", "influxdb", "etcd", "mssql-server", "cockroach", "nats",
              "kafka", "zookeeper", "minio", "dragonfly", "timescaledb", "questdb", "surrealdb"}


def compose_dockerfile(project_dir: Path, build):
    """Resolve a Compose build: entry to its Dockerfile path (or None for dockerfile_inline / a URL)."""
    if isinstance(build, str):
        ctx, name = build, "Dockerfile"
    elif isinstance(build, dict):
        if build.get("dockerfile_inline"):
            return None
        ctx, name = str(build.get("context") or "."), str(build.get("dockerfile") or "Dockerfile")
    else:
        return None
    if "://" in ctx or ctx.startswith("git@") or "$" in ctx or "$" in name:
        return None
    ctx_path = (project_dir / ctx).resolve()
    return (ctx_path / name).resolve(), ctx_path


# === MAIN ===

SKIP_DIRS = {".git", "node_modules", "vendor", ".venv", "venv", "__pycache__", "dist", "build", "target",
             ".ddev", ".claude", ".next", ".nuxt", ".terraform", ".tox", ".mypy_cache", ".pytest_cache", "coverage"}
DOCKERFILE_RE = re.compile(r"^(Dockerfile|Containerfile)(\..+)?$|.+\.(Dockerfile|dockerfile)$")
COMPOSE_RE = re.compile(r"^(docker-)?compose(\.[\w.-]+)?\.ya?ml$", re.I)


def classify(name: str):
    if name.endswith(".dockerignore"):
        return None
    if DOCKERFILE_RE.match(name):
        return "dockerfile"
    if COMPOSE_RE.match(name):
        return "compose"
    return None


def discover(paths, max_depth=6):
    dockerfiles, composes = [], []
    for p in paths:
        if p.is_file():
            kind = classify(p.name)
            if kind is None:
                raise SystemExit(f"usage:{p}")
            (dockerfiles if kind == "dockerfile" else composes).append(p.resolve())
            continue
        base_depth = len(p.resolve().parts)
        for root, dirs, files in os.walk(p):
            depth = len(Path(root).resolve().parts) - base_depth
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and depth < max_depth)
            for f in sorted(files):
                kind = classify(f)
                if kind:
                    (dockerfiles if kind == "dockerfile" else composes).append((Path(root) / f).resolve())
    return list(dict.fromkeys(dockerfiles)), list(dict.fromkeys(composes))


def load_catalog(path: Path) -> dict:
    if not path.is_file():
        print(f"error: facts catalog not found: {path}", file=sys.stderr)
        raise SystemExit(EX_NOTFOUND)
    try:
        cat = json.loads(path.read_text(encoding="utf-8"))
        if cat.get("schema") != FACTS_SCHEMA or not isinstance(cat.get("eol_floor"), dict):
            raise ValueError(f"schema must be {FACTS_SCHEMA!r} with an eol_floor object")
        for k, v in cat["eol_floor"].items():
            if not re.match(r"^\d+(\.\d+)?$", str(v)):
                raise ValueError(f"eol_floor.{k} must look like 22 or 3.10")
        return cat
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"error: facts catalog {path} is malformed: {exc}", file=sys.stderr)
        raise SystemExit(EX_UNREADABLE)


# One redaction path for everything printed. Details are built from key and file names,
# never values; this is the backstop for an image reference or path that embeds a credential.
_REDACT = [
    (re.compile(r"(\w+://)[^/@\s:]+:[^/@\s]+@"), r"\1***@"),
    (re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bglpat-[A-Za-z0-9_-]{20,}"
                r"|\bxox[abprs]-[A-Za-z0-9-]{10,}|\bnpm_[A-Za-z0-9]{30,}|\bAKIA[0-9A-Z]{16}\b|\bsk-[A-Za-z0-9_-]{20,}"),
     "***"),
]


def redact(s: str) -> str:
    for rx, rep in _REDACT:
        s = rx.sub(rep, s)
    return s


def suppress(findings, file_texts, file_kinds, dfs, opts, today):
    """Mark findings suppressed by --ignore or a pragma; add ignore-invalid findings."""
    extra = []
    for rel, text in file_texts.items():
        lines = text.replace("\r\n", "\n").split("\n")
        for n, line in enumerate(lines, 1):
            if "#" not in line:
                continue
            pr = parse_pragma(line[line.index("#"):], today)
            if pr and pr["error"]:
                extra.append({"severity": "low", "check": "ignore-invalid", "family": "audit", "file": rel, "line": n,
                              "detail": f"this docker-audit pragma {pr['error']}, so it suppresses nothing", "origin": None})
    findings.extend(extra)
    global_off: dict = {}
    for rel, text in file_texts.items():
        off = set()
        for m in HADOLINT_GLOBAL_RE.finditer(text):
            off |= checks_for("hadolint", m.group(1).upper().split(","))
        df = dfs.get(rel)
        if df and "check" in df["directives"]:
            m = re.search(r"skip=([\w,]+)", df["directives"]["check"])
            if m:
                off |= checks_for("buildkit", m.group(1).split(","))
        global_off[rel] = off
    for f in findings:
        f["suppressed_by"] = None
        if f["check"] in opts.ignore:
            f["suppressed_by"] = "--ignore"
            continue
        if f["check"] in global_off.get(f["file"], ()):
            f["suppressed_by"] = "file-wide hadolint/BuildKit skip"
            continue
        comments = _comments_for(f, file_texts, file_kinds, dfs)
        for c in comments:
            pr = parse_pragma(c, today)
            if pr and not pr["error"] and f["check"] in pr["checks"]:
                if pr["expired"]:
                    f["detail"] += f" (a docker-audit ignore for this expired on {pr['expired']})"
                else:
                    f["suppressed_by"] = "docker-audit pragma"
                break
            if f["check"] in checks_for("hadolint", hadolint_ids(c)):
                f["suppressed_by"] = "hadolint ignore"
                break
    return findings


def _comments_for(f, file_texts, file_kinds, dfs):
    rel, line = f["file"], f["line"]
    if file_kinds.get(rel) == "dockerfile":
        df = dfs.get(rel)
        for ins in (df["instrs"] if df else []):
            if ins.line == line:
                return [c for _, c in ins.comments]
        return []
    lines = file_texts[rel].replace("\r\n", "\n").split("\n")
    out = []
    if 0 < line <= len(lines) and "#" in lines[line - 1]:
        out.append(lines[line - 1][lines[line - 1].index("#"):])
    k = line - 2
    while k >= 0 and lines[k].strip().startswith("#"):
        out.append(lines[k].strip())
        k -= 1
    return out


def list_checks(as_json: bool):
    rows = [{"check": n, "family": fam, "severity": sev, "summary": s, "ids": refs,
             "production_only": n in PRODUCTION_ONLY} for n, (fam, sev, s, refs) in CHECKS.items()]
    if as_json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "schema": SCHEMA}}, indent=2))
    else:
        for r in rows:
            ids = " ".join(f"{t}:{','.join(v)}" for t, v in r["ids"].items())
            print(f"{r['check']}\t{r['family']}\t{r['severity']}\t{ids or '-'}\t{r['summary']}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="docker-audit.py", description=(__doc__ or "").split("\n\n", 1)[0],
        epilog="EXAMPLES:\n  docker-audit.py\n  docker-audit.py services/api compose.yaml --json\n"
               "  docker-audit.py . --production --allow-registry ghcr.io\n  docker-audit.py --list-checks",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["."], metavar="PATH")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")
    ap.add_argument("--ignore", action="append", default=[], metavar="CHECK", help="skip a check (repeatable)")
    ap.add_argument("--min-severity", choices=list(SEVERITY_RANK), default="low",
                    help="lowest severity to report (default low; info adds modernisation hints)")
    ap.add_argument("--production", action="store_true",
                    help="also require digest-pinned bases, OCI labels and Compose hardening")
    ap.add_argument("--allow-registry", action="append", default=[], metavar="HOST",
                    help="flag base images from any other registry (docker.io for Docker Hub)")
    ap.add_argument("--show-suppressed", action="store_true", help="also list suppressed findings")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG, help="facts catalog (default: assets/docker-facts.json)")
    ap.add_argument("--today", help="date for until= checks (YYYY-MM-DD; default today)")
    ap.add_argument("--list-checks", action="store_true", help="print the check table and exit")
    ap.add_argument("-q", "--quiet", action="store_true", help="no verdict line on stderr")
    opts = ap.parse_args(argv)
    for name in opts.ignore:
        if name not in CHECKS:
            print(f"error: --ignore {name}: unknown check (see --list-checks)", file=sys.stderr)
            return EX_USAGE
    try:
        today = dt.date.fromisoformat(opts.today) if opts.today else dt.date.today()
    except ValueError:
        print(f"error: --today {opts.today!r} is not YYYY-MM-DD", file=sys.stderr)
        return EX_USAGE
    opts.allow_registry = {h.lower() for h in opts.allow_registry}
    opts.ignore = set(opts.ignore)
    if opts.list_checks:
        list_checks(opts.json)
        return EX_OK
    cat = load_catalog(opts.catalog)

    paths = [Path(p) for p in opts.paths]
    for p in paths:
        if not p.exists():
            print(f"error: no such path: {p}", file=sys.stderr)
            return EX_NOTFOUND
    try:
        dockerfiles, composes = discover(paths)
    except SystemExit as exc:
        bad = str(exc).split(":", 1)[1]
        print(f"error: {bad}: not named like a Dockerfile or a Compose file", file=sys.stderr)
        return EX_USAGE
    base = paths[0].resolve() if len(paths) == 1 and paths[0].is_dir() else Path.cwd().resolve()

    def relname(p: Path) -> str:
        try:
            return Path(os.path.relpath(p, base)).as_posix()
        except ValueError:
            return p.as_posix()

    audit = Audit(cat, opts)
    unreadable, texts, kinds = [], {}, {}
    parsed_compose, contexts = [], {}
    for path in composes:
        rel = relname(path)
        try:
            text = path.read_text(encoding="utf-8")
            doc = parse_yaml(text)
            if doc is not None and not isinstance(doc, dict):
                raise YamlError("the top level is not a mapping", 1)
        except (OSError, UnicodeDecodeError, YamlError, RecursionError) as exc:
            unreadable.append({"file": rel, "reason": str(exc)})
            continue
        texts[rel], kinds[rel] = text, "compose"
        parsed_compose.append((rel, path, doc or YMap()))
        for svc in ((doc or {}).get("services") or {}).values():
            if isinstance(svc, dict) and svc.get("build"):
                got = compose_dockerfile(path.parent, svc["build"])
                if got and got[0].is_file():
                    contexts.setdefault(got[0], got[1])
                    if got[0] not in dockerfiles:
                        dockerfiles.append(got[0])
    dfs_by_path, dfs = {}, {}
    for path in dockerfiles:
        rel = relname(path)
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            unreadable.append({"file": rel, "reason": str(exc)})
            continue
        df = parse_dockerfile(text)
        texts[rel], kinds[rel], dfs[rel], dfs_by_path[path] = text, "dockerfile", df, df
        audit.dockerfile(rel, df, path, contexts.get(path, path.parent))
    projects: dict = {}
    for rel, path, doc in parsed_compose:
        pr = projects.setdefault(path.parent, {"dir": path.parent, "services": {}, "volumes": set(),
                                               "networks": set(), "secrets": set(), "configs": set()})
        for key in ("volumes", "networks", "secrets", "configs"):
            if isinstance(doc.get(key), dict):
                pr[key] |= set(doc[key].keys())
        if isinstance(doc.get("services"), dict):
            for n, s in doc["services"].items():
                if isinstance(s, dict):
                    pr["services"].setdefault(n, YMap()).update(s)
    for rel, path, doc in parsed_compose:
        audit.compose(rel, doc, projects[path.parent], dfs_by_path)

    for u in unreadable:
        print(f"notice: could not read {u['file']}: {u['reason']}", file=sys.stderr)
    if not dockerfiles and not composes:
        print("error: no Dockerfile or Compose file found", file=sys.stderr)
        return EX_NOTFOUND
    findings = suppress(audit.findings, texts, kinds, dfs, opts, today)
    floor = SEVERITY_RANK[opts.min_severity]
    findings = [f for f in findings if SEVERITY_RANK[f["severity"]] <= floor
                and (opts.production or f["check"] not in PRODUCTION_ONLY)]
    for f in findings:
        f["detail"] = redact(f["detail"])
        f["ids"] = CHECKS[f["check"]][3]
        f.pop("origin", None)
    findings.sort(key=lambda f: (SEVERITY_RANK[f["severity"]], f["file"], f["line"], f["check"]))
    # identical findings (same check, place and text) collapse to one
    findings = list({(f["check"], f["file"], f["line"], f["detail"]): f for f in findings}.values())
    active = [f for f in findings if not f["suppressed_by"]]
    suppressed = [f for f in findings if f["suppressed_by"]]
    shown = active + (suppressed if opts.show_suppressed else [])
    if opts.json:
        out = [{"severity": f["severity"], "check": f["check"], "family": f["family"], "file": f["file"],
                "line": f["line"], "detail": f["detail"], "ids": f["ids"], "suppressed": bool(f["suppressed_by"]),
                "suppressed_by": f["suppressed_by"]} for f in shown]
        print(json.dumps({"data": out, "meta": {
            "count": len(active), "suppressed": len(suppressed), "schema": SCHEMA,
            "dockerfiles": sorted(dfs), "compose_files": sorted(r for r, _, _ in parsed_compose),
            "unreadable": unreadable, "min_severity": opts.min_severity, "production": opts.production}}, indent=2))
    else:
        for f in shown:
            sev = f["severity"] if not f["suppressed_by"] else f"suppressed({f['suppressed_by']})"
            print(f"{sev}\t{f['check']}\t{f['file']}:{f['line']}\t{f['detail']}")
    if not opts.quiet:
        counts = {s: sum(1 for f in active if f["severity"] == s) for s in SEVERITY_RANK}
        summary = ", ".join(f"{n} {s}" for s, n in counts.items() if n)
        scope = f"{len(dfs)} Dockerfile(s), {len(parsed_compose)} Compose file(s)"
        tail = f"; {len(suppressed)} suppressed" if suppressed else ""
        if active:
            verdict = f"docker-audit: {len(active)} finding(s) ({summary}) in {scope}{tail}"
        elif unreadable and not dfs and not parsed_compose:
            verdict = f"docker-audit: nothing audited - {len(unreadable)} file(s) could not be read"
        else:
            verdict = f"docker-audit: clean - {scope}{tail}"
        print(verdict, file=sys.stderr)
    if active:
        return EX_FINDINGS
    if unreadable and not dfs and not parsed_compose:
        return EX_UNREADABLE
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())
