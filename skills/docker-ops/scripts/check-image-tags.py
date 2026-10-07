#!/usr/bin/env python3
"""Check that the container images a repo (or a skill's docs) names still exist, for every
platform it needs.

Image tags vanish quietly: a distroless family drops its -debian12 builds, an EOL language
line stops getting tags, a vendor moves registries. Nothing fails until someone builds. This
script inventories every image reference and, with --live, asks each registry whether the
tag is still there and serves both linux/amd64 and linux/arm64.

  --offline (default): no network. Lists every FROM, COPY --from=<image> and Compose or
    Kubernetes `image:` reference in Dockerfiles, Compose files and the dockerfile/yaml code
    fences of Markdown files, with its status: pinned, floating (no tag, or :latest),
    variable (has ${...}), placeholder (an obvious example name) or malformed.
  --live: also asks the registry for every pinned reference. Docker Hub is asked through
    its tags API, which does not count against pull limits. ghcr.io, gcr.io and its
    regional hosts, quay.io, cgr.dev, mcr.microsoft.com, public.ecr.aws and registry.k8s.io
    go through the registry API with an anonymous token. Any other registry is listed as
    unsupported and not contacted. Only those hosts and their known token endpoints are
    ever connected to, redirects are never followed, and a response body is capped at 1 MB.

A result is ok, missing (404, or a required platform absent) or uncertain (429 rate limits,
network errors, anything unexpected). Docker Hub rate-limits anonymous callers, so expect
some uncertain results on a big sweep. On Windows, a Python whose trust store rejects Let's
Encrypt's newer chain reports "certificate has expired" for Docker Hub; set SSL_CERT_FILE to
certifi's bundle, or run from WSL or CI.

Usage:   check-image-tags.py [PATH]... [--offline | --live] [--platforms LIST] [--ignore-ref GLOB]...
                             [--fixtures FILE] [--json] [--timeout S] [-q]
Input:   PATHs (default "."): directories are walked (skipping .git, node_modules, vendor and
         build output), files are read as given. --fixtures (live only) reads canned registry
         answers from a JSON file instead of the network, which is how tests exercise the
         live classification offline.
Output:  stdout = rows status<TAB>reference<TAB>file:line<TAB>detail, or the --json envelope
         (schema claude-mods.docker-ops.image-tags/v1). Data only.
Stderr:  the verdict line, notices.
Exit:    0 ok (offline: inventory built), 2 usage, 3 a PATH is missing,
         4 a malformed reference (offline), 7 live: nothing missing but at least one
         reference could not be verified (advisory), 10 live: a tag or required platform
         is missing

Examples:
  check-image-tags.py                                   # offline inventory of this repo
  check-image-tags.py --live Dockerfile compose.yaml    # do these tags still exist, amd64+arm64?
  check-image-tags.py skills/docker-ops --live --json | jq '.data[] | select(.status=="missing")'
  check-image-tags.py --live --platforms linux/amd64    # an amd64-only fleet
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_MALFORMED = 4
EX_UNAVAILABLE = 7
EX_MISSING = 10
SCHEMA = "claude-mods.docker-ops.image-tags/v1"
MAX_BODY = 1024 * 1024

SKIP_DIRS = {".git", "node_modules", "vendor", ".venv", "venv", "__pycache__", "dist", "build", "target",
             ".claude", ".next", ".terraform", "fixtures"}
DOCKERFILE_RE = re.compile(r"^(Dockerfile|Containerfile)(\..+)?$|.+\.(Dockerfile|dockerfile)$")
YAML_RE = re.compile(r".+\.ya?ml$", re.I)
FENCE_RE = re.compile(r"^\s*(```|~~~)\s*([\w+-]*)")
FROM_RE = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?", re.I)
COPY_FROM_RE = re.compile(r"^\s*COPY\s+(?:--\S+\s+)*?--from=(\S+)", re.I)
IMAGE_RE = re.compile(r"""^\s*-?\s*image:\s*["']?([^\s"'#]+)""")
# A reference grammar loose enough for real use, strict enough to catch typos:
# [registry[:port]/]path[:tag][@sha256:hex]
REF_RE = re.compile(r"^(?:[a-z0-9.-]+(?::\d+)?/)?[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*"
                    r"(?::[\w][\w.-]{0,127})?(?:@sha256:[a-f0-9]{64})?$")
PLACEHOLDER_RE = re.compile(
    r"(^|/)(my-?app|my-?image|myorg|myregistry|my-?service|app|image|example|your-?\w*|acme|foo|bar|svc|x)"
    r"([/:@]|$)|example\.(com|org)|registry\.local|localhost[:/]|<[^>]+>", re.I)

# registry host -> (API base, token realm host or None). Nothing else is ever contacted.
REGISTRIES = {
    "ghcr.io": ("https://ghcr.io", "ghcr.io"),
    "gcr.io": ("https://gcr.io", "gcr.io"),
    "quay.io": ("https://quay.io", "quay.io"),
    "cgr.dev": ("https://cgr.dev", "cgr.dev"),
    "mcr.microsoft.com": ("https://mcr.microsoft.com", None),
    "public.ecr.aws": ("https://public.ecr.aws", "public.ecr.aws"),
    "registry.k8s.io": ("https://registry.k8s.io", None),
}
for _r in ("us.gcr.io", "eu.gcr.io", "asia.gcr.io"):
    REGISTRIES[_r] = (f"https://{_r}", _r)
HUB_TAGS = "https://hub.docker.com/v2/namespaces/{ns}/repositories/{repo}/tags/{tag}"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])


class Uncertain(Exception):
    pass


class Missing(Exception):
    pass


# === Inventory ===

def walk(paths):
    for p in paths:
        if p.is_file():
            yield p
            continue
        for root, dirs, files in os.walk(p):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for f in sorted(files):
                if DOCKERFILE_RE.match(f) or YAML_RE.match(f) or f.lower().endswith(".md"):
                    yield Path(root) / f


def extract(path: Path):
    """-> [(line, ref, kind)] from a Dockerfile, a YAML file, or a Markdown file's code fences."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    name = path.name
    if name.lower().endswith(".md"):
        out, lang = [], None
        stages: set = set()
        for n, line in enumerate(lines, 1):
            m = FENCE_RE.match(line)
            if m:
                lang = None if lang is not None else (m.group(2).lower() or "text")
                stages = set()
                continue
            if lang in ("dockerfile", "docker", "containerfile"):
                out += _from_dockerfile_line(n, line, stages)
            elif lang in ("yaml", "yml", "compose"):
                m2 = IMAGE_RE.match(line)
                if m2:
                    out.append((n, m2.group(1), "image"))
        return out
    if DOCKERFILE_RE.match(name):
        stages = set()
        out = []
        for n, line in enumerate(lines, 1):
            out += _from_dockerfile_line(n, line, stages)
        return out
    out = []
    for n, line in enumerate(lines, 1):
        m = IMAGE_RE.match(line)
        if m:
            out.append((n, m.group(1), "image"))
    return out


def _from_dockerfile_line(n, line, stages):
    m = FROM_RE.match(line)
    if m:
        ref, alias = m.group(1), m.group(2)
        if alias:
            stages.add(alias.lower())
        if ref.lower() in stages or ref.lower() == "scratch":
            return []
        return [(n, ref, "from")]
    m = COPY_FROM_RE.match(line)
    if m and m.group(1).lower() not in stages and not m.group(1).isdigit():
        return [(n, m.group(1), "copy-from")]
    return []


def split_ref(ref: str):
    """-> (registry or 'docker.io', path, tag, digest)."""
    digest = ""
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    tag = ""
    if ":" in ref.rsplit("/", 1)[-1]:
        ref, tag = ref.rsplit(":", 1)
    parts = ref.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0] or parts[0] == "localhost"):
        return parts[0].lower(), "/".join(parts[1:]), tag, digest
    return "docker.io", ref if "/" in ref else f"library/{ref}", tag, digest


def classify_offline(ref: str, ignores):
    if any(fnmatch.fnmatch(ref, g) for g in ignores):
        return "ignored", "--ignore-ref"
    if "$" in ref or "{{" in ref:
        return "variable", "resolved at build or deploy time"
    if PLACEHOLDER_RE.search(ref):
        return "placeholder", "an example name, not a real image"
    if not REF_RE.match(ref):
        return "malformed", "not a valid image reference"
    _, _, tag, digest = split_ref(ref)
    if not tag and not digest:
        return "floating", "no tag: means :latest"
    if tag == "latest" and not digest:
        return "floating", ":latest"
    return "pinned", ""


# === Live ===

class Fetcher:
    def __init__(self, timeout: float, fixtures: dict | None):
        self.timeout, self.fixtures = timeout, fixtures
        self.tokens: dict = {}

    def check(self, ref: str, platforms):
        """-> detail string; raises Missing or Uncertain."""
        if self.fixtures is not None:
            return self._fixture(ref, platforms)
        registry, path, tag, digest = split_ref(ref)
        if registry == "docker.io" and not digest:
            try:
                return self._hub(path, tag, platforms)
            except Uncertain as exc:
                # The tags API (hub.docker.com) and the registry (registry-1.docker.io) sit
                # behind different certificates and limits: a TLS or network failure on one
                # is worth one try on the other. The registry GET counts as an anonymous pull.
                if not str(exc).startswith("network error"):
                    raise
                return self._registry("https://registry-1.docker.io", "auth.docker.io", registry, path, tag,
                                      platforms)
        if registry == "docker.io":
            base, realm = "https://registry-1.docker.io", "auth.docker.io"
        elif registry in REGISTRIES:
            base, realm = REGISTRIES[registry]
        else:
            raise Uncertain(f"registry {registry} is not on the supported list, so it was not contacted")
        return self._registry(base, realm, registry, path, digest or tag, platforms)

    def _fixture(self, ref, platforms):
        ans = self.fixtures.get(ref)
        if ans is None:
            raise Uncertain("no fixture answer")
        if ans.get("status") == 404:
            raise Missing("the registry has no such tag")
        if ans.get("status") != 200:
            raise Uncertain(f"HTTP {ans.get('status')}")
        return self._platforms(ans.get("platforms"), platforms)

    @staticmethod
    def _platforms(have, want):
        if not want or have is None:
            return "exists"
        lacking = [p for p in want if p not in have]
        if lacking:
            raise Missing(f"no {', '.join(lacking)} image (has {', '.join(sorted(have)) or 'none'})")
        return f"exists for {', '.join(want)}"

    def _get(self, url, headers=None, method="GET"):
        host = urllib.parse.urlsplit(url).hostname or ""
        allowed = {"hub.docker.com", "registry-1.docker.io", "auth.docker.io"} | set(REGISTRIES)
        if host not in allowed:
            raise Uncertain(f"refusing to contact {host}")
        req = urllib.request.Request(url, headers=dict(headers or {}, **{"User-Agent": "claude-mods-check-image-tags"}),
                                     method=method)
        opener = urllib.request.build_opener(_NoRedirect)
        try:
            with opener.open(req, timeout=self.timeout) as r:
                body = r.read(MAX_BODY + 1)
                if len(body) > MAX_BODY:
                    raise Uncertain("response over 1 MB")
                return r.status, _Headers(r.headers), body
        except urllib.error.HTTPError as e:
            # Registries differ in header case (ghcr.io sends www-authenticate), so keep lookups case-blind.
            return e.code, _Headers(e.headers), b""
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise Uncertain(f"network error: {getattr(e, 'reason', e)}")

    def _hub(self, path, tag, platforms):
        ns, repo = path.split("/", 1)
        status, _, body = self._get(HUB_TAGS.format(ns=ns, repo=urllib.parse.quote(repo), tag=urllib.parse.quote(tag)))
        if status == 404:
            raise Missing("Docker Hub has no such tag")
        if status != 200:
            raise Uncertain(f"Docker Hub answered HTTP {status}")
        try:
            images = json.loads(body).get("images") or []
        except ValueError:
            raise Uncertain("Docker Hub sent unreadable JSON")
        have = {f"{i.get('os')}/{i.get('architecture')}" + (f"/{i['variant']}" if i.get("variant") and i.get("architecture") == "arm" else "")
                for i in images if i.get("os") and i.get("architecture")}
        return self._platforms(have, platforms)

    def _token(self, realm_host, path, challenge):
        m = re.search(r'realm="([^"]+)"', challenge or "")
        if not m:
            raise Uncertain("no token challenge")
        realm = m.group(1)
        if urllib.parse.urlsplit(realm).hostname != realm_host:
            raise Uncertain(f"token realm {realm} is not the registry's own")
        svc = re.search(r'service="([^"]+)"', challenge)
        q = {"scope": f"repository:{path}:pull"}
        if svc:
            q["service"] = svc.group(1)
        status, _, body = self._get(realm + "?" + urllib.parse.urlencode(q))
        if status != 200:
            raise Uncertain(f"anonymous token refused (HTTP {status})")
        try:
            data = json.loads(body)
            return data.get("token") or data.get("access_token")
        except ValueError:
            raise Uncertain("token endpoint sent unreadable JSON")

    def _registry(self, base, realm_host, registry, path, ref, platforms):
        url = f"{base}/v2/{path}/manifests/{ref}"
        headers = {"Accept": ACCEPT}
        status, hdrs, body = self._get(url, headers)
        if status == 401 and realm_host:
            token = self._token(realm_host, path, hdrs.get("www-authenticate"))
            headers["Authorization"] = f"Bearer {token}"
            status, hdrs, body = self._get(url, headers)
        if status == 404 or (status == 401 and registry == "docker.io"):
            raise Missing("the registry has no such tag")
        if status != 200:
            raise Uncertain(f"HTTP {status}")
        ctype = hdrs.get("content-type").split(";")[0]
        try:
            doc = json.loads(body)
        except ValueError:
            raise Uncertain("unreadable manifest")
        if "index" in ctype or "manifest.list" in ctype or "manifests" in doc:
            have = {f"{m['platform'].get('os')}/{m['platform'].get('architecture')}"
                    for m in doc.get("manifests", []) if isinstance(m.get("platform"), dict)}
            return self._platforms(have, platforms)
        if platforms:
            raise Missing("a single-platform image; no multi-arch index")
        return "exists"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise Uncertain("the registry answered with a redirect (not followed)")


class _Headers:
    """Case-blind header lookup that always returns a string."""

    def __init__(self, msg):
        self._h = {k.lower(): v for k, v in (msg.items() if msg is not None else [])}

    def get(self, name: str) -> str:
        return self._h.get(name.lower(), "")


# === Main ===

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="check-image-tags.py", description=(__doc__ or "").split("\n\n", 1)[0],
        epilog="EXAMPLES:\n  check-image-tags.py\n  check-image-tags.py --live Dockerfile compose.yaml\n"
               "  check-image-tags.py --live --platforms linux/amd64",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["."], metavar="PATH")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="inventory only (default)")
    mode.add_argument("--live", action="store_true", help="also ask each registry")
    ap.add_argument("--platforms", default="linux/amd64,linux/arm64",
                    help='platforms a tag must serve (default linux/amd64,linux/arm64; "" checks existence only)')
    ap.add_argument("--ignore-ref", action="append", default=[], metavar="GLOB", help="skip references matching GLOB")
    ap.add_argument("--fixtures", type=Path, help="live mode: canned registry answers (tests)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")
    ap.add_argument("--timeout", type=float, default=15.0, help="seconds per request (default 15)")
    ap.add_argument("-q", "--quiet", action="store_true", help="no verdict line on stderr")
    opts = ap.parse_args(argv)
    if opts.fixtures and not opts.live:
        print("error: --fixtures needs --live", file=sys.stderr)
        return EX_USAGE
    platforms = [p.strip() for p in opts.platforms.split(",") if p.strip()]
    paths = [Path(p) for p in opts.paths]
    for p in paths:
        if not p.exists():
            print(f"error: no such path: {p}", file=sys.stderr)
            return EX_NOTFOUND
    fixtures = None
    if opts.fixtures:
        try:
            fixtures = json.loads(opts.fixtures.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"error: --fixtures {opts.fixtures}: {exc}", file=sys.stderr)
            return EX_USAGE
    base = paths[0].resolve() if len(paths) == 1 and paths[0].is_dir() else Path.cwd().resolve()
    rows = []
    for f in walk(paths):
        for line, ref, kind in extract(f):
            try:
                rel = Path(os.path.relpath(f.resolve(), base)).as_posix()
            except ValueError:
                rel = f.as_posix()
            status, detail = classify_offline(ref, opts.ignore_ref)
            rows.append({"status": status, "ref": ref, "kind": kind, "file": rel, "line": line, "detail": detail})
    if opts.live:
        fetcher = Fetcher(opts.timeout, fixtures)
        cache: dict = {}
        for r in rows:
            if r["status"] != "pinned":
                continue
            if r["ref"] not in cache:
                try:
                    cache[r["ref"]] = ("ok", fetcher.check(r["ref"], platforms))
                except Missing as e:
                    cache[r["ref"]] = ("missing", str(e))
                except Uncertain as e:
                    cache[r["ref"]] = ("uncertain", str(e))
            r["status"], r["detail"] = cache[r["ref"]]
    if opts.json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "schema": SCHEMA, "live": opts.live,
                                                  "platforms": platforms if opts.live else []}}, indent=2))
    else:
        for r in rows:
            print(f"{r['status']}\t{r['ref']}\t{r['file']}:{r['line']}\t{r['detail']}")
    counts: dict = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    if not opts.quiet:
        summary = ", ".join(f"{n} {s}" for s, n in sorted(counts.items())) or "no image references"
        print(f"check-image-tags ({'live' if opts.live else 'offline'}): {summary}", file=sys.stderr)
    if opts.live:
        if counts.get("missing"):
            return EX_MISSING
        if counts.get("uncertain"):
            return EX_UNAVAILABLE
        return EX_OK
    return EX_MALFORMED if counts.get("malformed") else EX_OK


if __name__ == "__main__":
    sys.exit(main())
