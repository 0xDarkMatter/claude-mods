#!/usr/bin/env python3
"""check-tool-profiles - validator and staleness tripwire for tool-profiles.json.

Usage:   check-tool-profiles.py [--offline | --live] [--file PATH] [--json]
Input:   --offline (default): assets/agents-md/tool-profiles.json beside this skill (or
         --file PATH, for negative tests): structure only. --live: fetches every
         profile and fact source over HTTPS and looks for each non-null live_phrase.
Output:  plain "ok"/"DRIFT"/"unpinned"/"unreachable" lines on stdout, or --json:
         {"data": [{"id", "status", "detail"}], "meta": {"mode", "drift", "unpinned",
         "unreachable", "schema": "claude-mods.repo-doctor.check-tool-profiles/v1"}}
Stderr:  fetch progress and errors
Exit:    0 ok, 2 usage, 7 live only: EVERY source unreachable (advisory, never a failure),
         10 invalid structure (offline) or a live_phrase gone from its page (live)

The contract is 1.2 in docs/plans/REPO-DOCTOR-ABC-2026-10.md. Offline runs in PR CI
(tests/check-resources.sh); live runs on a schedule (.github/workflows/freshness.yml),
never as a PR gate (SKILL-RESOURCE-PROTOCOL.md 7). Follows check-memory-docs.py.
A fact with live_phrase null is "unpinned": reported, never drift - it records a claim
that no fetched page could confirm. A source that cannot be fetched is "unreachable",
also never drift, so one flaky site cannot fail the run.
When live reports drift: re-read the source, fix the profile, then the phrase and the
verified date together.

Examples:
  check-tool-profiles.py --offline
  check-tool-profiles.py --live --json | jq '.data[] | select(.status == "drift")'
  check-tool-profiles.py --offline --file /tmp/broken-copy.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROFILES = HERE.parent / "assets" / "agents-md" / "tool-profiles.json"
SCHEMA_ID = "claude-mods.repo-doctor.tool-profiles/v1"
SCHEMA = "claude-mods.repo-doctor.check-tool-profiles/v1"

# Allowed values per enum field (contract 1.2). Add a value here and in the contract together.
PER_DIR = {"claude-md-shadows-agents-md", "first-match", "all"}
ANCESTORS = {"launch", "none"}
SUBDIRS = {"on-read", "launch-path-only", "always", "never"}
PRECEDENCE = {"concatenate", "nearest-wins"}
RULE_MODES = {"always", "scoped", "description", "manual", "frontmatter"}
SCOPE_KEYS = {"paths", "applyTo", "globs", "fileMatchPattern", None}
CAP_SCOPES = {"chain", "file"}
CAP_BEHAVIOURS = {"drop-deepest", "per-file", "advice"}
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# A live_phrase is matched verbatim after norm(); long phrases break on any rewording.
MAX_PHRASE_WORDS = 12


def norm(text: str) -> str:
    # Same normalisation as check-memory-docs.py so phrases are copied the same way.
    text = re.sub(r"<[^>]+>", " ", text).replace("`", "").replace("&quot;", '"').replace("&#x27;", "'")
    text = text.replace("&amp;", "&")
    return re.sub(r"\s+", " ", text)


def _url(v) -> bool:
    return isinstance(v, str) and v.startswith(("https://", "http://"))


def validate(doc) -> list[dict]:
    """Structure checks. Returns one row per problem, plus one 'ok' row when clean."""
    bad: list[dict] = []

    def err(where: str, msg: str) -> None:
        bad.append({"id": where, "status": "drift", "detail": msg})

    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA_ID:
        err("schema", f"top-level schema must be {SCHEMA_ID}")
    profiles = doc.get("profiles") if isinstance(doc, dict) else None
    if not isinstance(profiles, list) or not profiles:
        err("profiles", "profiles must be a non-empty list")
        return bad
    seen: set = set()
    for i, p in enumerate(profiles):
        pid = p.get("id") if isinstance(p, dict) else None
        w = f"profile[{i}]" if not isinstance(pid, str) else pid
        if not isinstance(p, dict):
            err(w, "profile must be an object")
            continue
        if not isinstance(pid, str) or not pid:
            err(w, "missing id")
        elif pid in seen:
            err(w, "duplicate id")
        seen.add(pid)
        if not p.get("name"):
            err(w, "missing name")
        if not DATE.match(str(p.get("verified", ""))):
            err(w, "verified must be YYYY-MM-DD")
        srcs = p.get("sources")
        if not isinstance(srcs, list) or not srcs or not all(_url(s) for s in srcs):
            err(w, "sources must be a non-empty list of URLs")
        for f in ("entry_files", "targets_when"):
            if not isinstance(p.get(f), list):
                err(w, f"{f} must be a list")
        if not p.get("entry_files"):
            err(w, "entry_files must not be empty")
        for key, allowed in (("per_dir", PER_DIR), ("ancestors", ANCESTORS),
                             ("subdirs", SUBDIRS), ("precedence", PRECEDENCE)):
            if p.get(key) not in allowed:
                err(w, f"{key}={p.get(key)!r} not in {sorted(allowed)}")
        if p.get("per_dir") == "first-match":
            fmo = p.get("first_match_order")
            if not isinstance(fmo, list) or not fmo:
                err(w, "first-match needs a non-empty first_match_order")
        elif "first_match_order" in p:
            err(w, "first_match_order is only for per_dir first-match")
        imp = p.get("imports")
        if imp is not None:
            need = {"syntax", "max_depth", "skip_code", "relative_to"}
            if not isinstance(imp, dict) or set(imp) != need:
                err(w, f"imports must be null or an object with exactly {sorted(need)}")
            elif not isinstance(imp["max_depth"], int) or not isinstance(imp["skip_code"], bool):
                err(w, "imports.max_depth must be an int and skip_code a bool")
        for j, rs in enumerate(p.get("rule_sets") or []):
            if not isinstance(rs, dict) or not rs.get("glob"):
                err(w, f"rule_sets[{j}] needs a glob")
                continue
            if rs.get("mode") not in RULE_MODES:
                err(w, f"rule_sets[{j}].mode {rs.get('mode')!r} not in {sorted(RULE_MODES)}")
            if rs.get("scope_key") not in SCOPE_KEYS:
                err(w, f"rule_sets[{j}].scope_key {rs.get('scope_key')!r} not allowed")
            if not isinstance(rs.get("always_when_scope_missing"), bool):
                err(w, f"rule_sets[{j}].always_when_scope_missing must be a bool")
        if not isinstance(p.get("rule_sets"), list):
            err(w, "rule_sets must be a list")
        if not isinstance(p.get("caps"), list):
            err(w, "caps must be a list")
        for j, c in enumerate(p.get("caps") or []):
            if not isinstance(c, dict):
                err(w, f"caps[{j}] must be an object")
                continue
            if c.get("scope") not in CAP_SCOPES:
                err(w, f"caps[{j}].scope {c.get('scope')!r} not in {sorted(CAP_SCOPES)}")
            if c.get("behaviour") not in CAP_BEHAVIOURS:
                err(w, f"caps[{j}].behaviour {c.get('behaviour')!r} not in {sorted(CAP_BEHAVIOURS)}")
            sizes = [c.get(k) for k in ("bytes", "chars", "lines")]
            if sum(isinstance(s, int) and not isinstance(s, bool) for s in sizes) != 1 \
                    or any(s is not None and not isinstance(s, int) for s in sizes):
                err(w, f"caps[{j}] needs exactly one of bytes/chars/lines as an int, the rest null")
            if not _url(c.get("source")):
                err(w, f"caps[{j}] needs a source URL")
        facts = p.get("facts")
        if not isinstance(facts, list) or not facts:
            err(w, "facts must be a non-empty list")
            continue
        fids: set = set()
        for j, f in enumerate(facts):
            fw = f"{w}/{f.get('id') if isinstance(f, dict) else j}"
            if not isinstance(f, dict):
                err(fw, "fact must be an object")
                continue
            if not f.get("id") or f["id"] in fids:
                err(fw, "fact id missing or duplicate within the profile")
            fids.add(f.get("id"))
            if not f.get("claim"):
                err(fw, "fact needs a claim")
            if not _url(f.get("source")):
                err(fw, "fact needs a source URL")
            elif isinstance(srcs, list) and f["source"] not in srcs:
                err(fw, "fact source must be one of the profile's sources")
            lp = f.get("live_phrase", False)
            if lp is False:
                err(fw, "fact needs live_phrase (a string, or null when no page could confirm it)")
            elif lp is not None and (not isinstance(lp, str) or not lp.strip()
                                     or len(lp.split()) > MAX_PHRASE_WORDS):
                err(fw, f"live_phrase must be null or a string of at most {MAX_PHRASE_WORDS} words")
    return bad


class _Redirect(urllib.request.HTTPRedirectHandler):
    # urllib before 3.11 does not follow 308, which cursor.com answers for its old URL.
    def http_error_308(self, req, fp, code, msg, headers):
        return self.http_error_302(req, fp, 302, msg, headers)


def fetch(url: str) -> str | None:
    opener = urllib.request.build_opener(_Redirect)
    for u in (url + ".md", url) if url.startswith("https://code.claude.com/") else (url,):
        print(f"check-tool-profiles: fetching {u}", file=sys.stderr)
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "claude-mods-freshness"})
            with opener.open(req, timeout=25) as r:
                return norm(r.read().decode("utf-8", errors="replace"))
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
            print(f"check-tool-profiles: {u}: {exc}", file=sys.stderr)
    return None


def live(doc) -> tuple[list[dict], bool]:
    """Returns (rows, any_source_reachable)."""
    pages: dict[str, str | None] = {}
    rows: list[dict] = []
    for p in doc["profiles"]:
        for s in p["sources"]:
            if s not in pages:
                pages[s] = fetch(s)
        for f in p["facts"]:
            rid = f"{p['id']}/{f['id']}"
            page = pages.get(f["source"])
            if f["live_phrase"] is None:
                rows.append({"id": rid, "status": "unpinned", "detail": "no live_phrase; claim not confirmed by a page"})
            elif page is None:
                rows.append({"id": rid, "status": "unreachable", "detail": f["source"]})
            elif norm(f["live_phrase"]).lower() in page.lower():
                rows.append({"id": rid, "status": "ok", "detail": f["claim"]})
            else:
                rows.append({"id": rid, "status": "drift", "detail": f"phrase gone from {f['source']}: {f['live_phrase']}"})
    return rows, any(v is not None for v in pages.values())


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validate tool-profiles.json and check its facts against their sources.",
        epilog="EXAMPLES:\n  check-tool-profiles.py --offline\n"
               "  check-tool-profiles.py --live --json\n"
               "  check-tool-profiles.py --offline --file /tmp/broken-copy.json\n",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structure only (default)")
    mode.add_argument("--live", action="store_true", help="fetch every source (network)")
    ap.add_argument("--file", type=Path, default=PROFILES, help="profiles file (default: the shipped one)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    try:
        doc = json.loads(args.file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"check-tool-profiles: cannot read {args.file}: {exc}", file=sys.stderr)
        return 10
    rows = validate(doc)
    if rows:
        out_rows, reachable = rows, True  # a broken file is never worth fetching against
    elif args.live:
        out_rows, reachable = live(doc)
    else:
        out_rows, reachable = [{"id": "structure", "status": "ok",
                                "detail": f"{len(doc['profiles'])} profiles valid"}], True
    if not reachable:
        print("check-tool-profiles: every source unreachable; skipped (advisory)", file=sys.stderr)
        return 7
    count = lambda s: sum(r["status"] == s for r in out_rows)  # noqa: E731
    if args.json:
        print(json.dumps({"data": out_rows, "meta": {
            "mode": "live" if args.live else "offline", "drift": count("drift"),
            "unpinned": count("unpinned"), "unreachable": count("unreachable"),
            "schema": SCHEMA}}, indent=2))
    else:
        label = {"ok": "ok   ", "drift": "DRIFT", "unpinned": "unpin", "unreachable": "unrch"}
        for r in out_rows:
            print(f"{label[r['status']]}  {r['id']}: {r['detail']}")
    return 10 if count("drift") else 0


if __name__ == "__main__":
    sys.exit(main())
