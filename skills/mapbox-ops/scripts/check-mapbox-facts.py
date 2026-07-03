#!/usr/bin/env python3
# Staleness verifier for the fast-moving facts the mapbox-ops skill encodes.
#
# Two modes (SKILL-RESOURCE-PROTOCOL.md §7):
#   --offline (default): NO network. Asserts the skill is internally consistent —
#                        style-catalog.json parses, the v3 Standard config enums
#                        (lightPreset/theme) agree between catalog and references,
#                        the terrain tileset IDs and the weather >= 3.7 version gate
#                        are stated consistently, no reference attributes camera roll
#                        to Mapbox GL JS (roll is MapLibre GL JS v5 — Mapbox has none,
#                        and freeCameraOptions orientation must be pitch+bearing-
#                        representable), every classic style url matches its id,
#                        every third-party entry is
#                        addressable. Runs in PR CI and MAY block.
#   --live:              network. Resolves the concrete third-party style-JSON URLs
#                        and probes whether Mapbox GL JS has shipped a major beyond
#                        v3 (which would mean the whole skill needs a review pass).
#                        Runs in the scheduled freshness workflow and NEVER blocks a
#                        PR: a transient network failure is UNAVAILABLE (exit 7), only
#                        a confirmed change is DRIFT (exit 10).
#
# Usage:   check-mapbox-facts.py [--offline|--live] [--json] [-q] [--timeout SEC]
# Input:   none (reads the skill's own assets/ + references/ relative to this file)
# Output:  stdout = data only (text findings, or the --json envelope)
# Stderr:  headers, progress, warnings, errors
# Exit:    0 ok, 2 usage, 3 not-found (skill files missing), 4 validation
#          (offline inconsistency), 5 missing-dep, 7 unavailable (live network),
#          10 drift (live: a URL 404'd, or GL JS major bumped past v3)
#
# Examples:
#   check-mapbox-facts.py --offline
#   check-mapbox-facts.py --offline --json | jq '.data[] | select(.status!="ok")'
#   check-mapbox-facts.py --live --timeout 15
"""Staleness verifier for mapbox-ops (see header comment)."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_MISSING_DEP = 5
EXIT_UNAVAILABLE = 7
EXIT_DRIFT = 10

SCHEMA = "claude-mods.mapbox-ops.facts/v1"

SKILL_ROOT = Path(__file__).resolve().parent.parent
CATALOG = SKILL_ROOT / "assets" / "style-catalog.json"
REFS = SKILL_ROOT / "references"
SKILL_MD = SKILL_ROOT / "SKILL.md"

# Facts the skill commits to. Changing these is a deliberate edit; the verifier
# asserts the skill states them consistently across catalog + references.
EXPECTED_LIGHT_PRESET = {"dawn", "day", "dusk", "night"}
EXPECTED_THEME = {"default", "faded", "monochrome"}
TERRAIN_DEM_ID = "mapbox.mapbox-terrain-dem-v1"
TERRAIN_VECTOR_ID = "mapbox.mapbox-terrain-v2"
GLJS_MAJOR = 3  # the skill is scoped to mapbox-gl-js v3.x


class Finding:
    __slots__ = ("check", "status", "detail")

    def __init__(self, check: str, status: str, detail: str) -> None:
        self.check = check
        self.status = status  # ok | fail | drift | unavailable
        self.detail = detail

    def as_dict(self) -> dict:
        return {"check": self.check, "status": self.status, "detail": self.detail}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# --------------------------------------------------------------------------- #
# Offline checks                                                              #
# --------------------------------------------------------------------------- #
def run_offline(findings: list[Finding]) -> None:
    # Required files present (else NOT_FOUND, distinct from inconsistency).
    missing = [p for p in (CATALOG, SKILL_MD, REFS) if not p.exists()]
    if missing:
        for p in missing:
            findings.append(Finding("files-present", "fail", f"missing: {p}"))
        raise _NotFound()

    # O1 — catalog parses.
    try:
        catalog = json.loads(read_text(CATALOG))
        findings.append(Finding("catalog-json", "ok", "style-catalog.json parses"))
    except json.JSONDecodeError as exc:
        findings.append(Finding("catalog-json", "fail", f"invalid JSON: {exc}"))
        return  # nothing else is checkable

    presets = catalog.get("standard_presets", {})
    v3_md = read_text(REFS / "v3-standard-style.md") if (REFS / "v3-standard-style.md").exists() else ""

    # O2 — lightPreset enum: catalog matches the committed set AND each value is
    # documented in v3-standard-style.md.
    light = set(presets.get("lightPreset", []))
    if light != EXPECTED_LIGHT_PRESET:
        findings.append(Finding("lightPreset-enum", "fail",
                                f"catalog {sorted(light)} != expected {sorted(EXPECTED_LIGHT_PRESET)}"))
    else:
        undoc = [v for v in EXPECTED_LIGHT_PRESET if v not in v3_md]
        if undoc:
            findings.append(Finding("lightPreset-enum", "fail",
                                    f"values not documented in v3-standard-style.md: {undoc}"))
        else:
            findings.append(Finding("lightPreset-enum", "ok", "dawn|day|dusk|night consistent"))

    # O3 — theme enum.
    theme = set(presets.get("theme", []))
    if theme != EXPECTED_THEME:
        findings.append(Finding("theme-enum", "fail",
                                f"catalog {sorted(theme)} != expected {sorted(EXPECTED_THEME)}"))
    else:
        findings.append(Finding("theme-enum", "ok", "default|faded|monochrome consistent"))

    # O4 — terrain tileset IDs present in terrain.md.
    terrain_md = read_text(REFS / "terrain.md") if (REFS / "terrain.md").exists() else ""
    for tid in (TERRAIN_DEM_ID, TERRAIN_VECTOR_ID):
        if tid in terrain_md:
            findings.append(Finding(f"terrain-id:{tid}", "ok", "present in terrain.md"))
        else:
            findings.append(Finding(f"terrain-id:{tid}", "fail", "absent from terrain.md"))

    # O5 — weather version gate agrees between catalog effects comment and dataviz ref.
    effects_comment = catalog.get("effects", {}).get("_comment", "")
    dataviz_md = read_text(REFS / "dataviz-and-3d.md") if (REFS / "dataviz-and-3d.md").exists() else ""
    cat_ver = _first_gl_gate(effects_comment)
    ref_ver = _first_gl_gate(dataviz_md, near="setRain") or _first_gl_gate(dataviz_md, near="Weather")
    if cat_ver and ref_ver and cat_ver == ref_ver == "3.7":
        findings.append(Finding("weather-gate", "ok", "GL JS >= 3.7 consistent (catalog + dataviz-and-3d.md)"))
    else:
        findings.append(Finding("weather-gate", "fail",
                                f"weather version gate mismatch (catalog={cat_ver!r}, ref={ref_ver!r}, want 3.7)"))

    # O6 — no native camera roll. Mapbox GL JS has no roll on any camera API
    # (FreeCameraOptions orientation "must be representable using only pitch and
    # bearing"); true roll is MapLibre GL JS v5. The reference must not attribute
    # a roll camera option / setRoll to Mapbox, and must keep the MapLibre pointer
    # for anyone who needs real roll.
    camera_md = read_text(REFS / "camera-and-animation.md") if (REFS / "camera-and-animation.md").exists() else ""
    cam_lines = camera_md.splitlines()
    roll_api = re.compile(r"setRoll|\{[^}]*\broll\b|\broll\s*:")
    misattributed = []
    for i, ln in enumerate(cam_lines):
        if roll_api.search(ln):
            context = " ".join(cam_lines[max(0, i - 2):i + 2])
            if "maplibre" not in context.lower():
                misattributed.append(ln.strip())
    if misattributed:
        findings.append(Finding("no-native-roll", "fail",
                                "roll API attributed to Mapbox GL JS (it has none): "
                                + " | ".join(misattributed[:3])))
    elif "maplibre" not in camera_md.lower():
        findings.append(Finding("no-native-roll", "fail",
                                "MapLibre-v5 roll pointer missing from camera-and-animation.md"))
    else:
        findings.append(Finding("no-native-roll", "ok",
                                "no Mapbox roll claim; MapLibre v5 pointer present"))

    # O7 — GL JS major scope: SKILL.md says v3.
    skill_md = read_text(SKILL_MD)
    if re.search(rf"v{GLJS_MAJOR}\.x", skill_md) and re.search(rf"v{GLJS_MAJOR}\b", skill_md):
        findings.append(Finding("gljs-major", "ok", f"skill scoped to v{GLJS_MAJOR}.x"))
    else:
        findings.append(Finding("gljs-major", "fail", f"SKILL.md no longer clearly scopes v{GLJS_MAJOR}.x"))

    # O8 — every classic style url tail matches its id.
    bad_urls = []
    for s in catalog.get("styles", []):
        sid, url = s.get("id", ""), s.get("url", "")
        if not url.endswith("/" + sid) and not url.endswith(sid):
            bad_urls.append(f"{sid} -> {url}")
    if bad_urls:
        findings.append(Finding("style-url-id", "fail", "url/id mismatch: " + "; ".join(bad_urls)))
    else:
        findings.append(Finding("style-url-id", "ok", f"{len(catalog.get('styles', []))} style urls match ids"))

    # O9 — every third-party entry is addressable (has a url or an explanatory note).
    unaddressable = [t.get("id", "?") for t in catalog.get("third_party", [])
                     if not t.get("url") and not t.get("note")]
    if unaddressable:
        findings.append(Finding("third-party-addressable", "fail",
                                "no url and no note: " + ", ".join(unaddressable)))
    else:
        findings.append(Finding("third-party-addressable", "ok",
                                f"{len(catalog.get('third_party', []))} third-party entries addressable"))


def _first_gl_gate(text: str, near: str | None = None) -> str | None:
    """Return the first 'GL JS >= 3.N' version found, optionally on a line mentioning `near`."""
    pat = re.compile(r"(?:GL JS\s*)?[>≥]=?\s*(3\.\d+)")
    if near:
        for line in text.splitlines():
            if near in line:
                m = pat.search(line)
                if m:
                    return m.group(1)
        return None
    m = pat.search(text)
    return m.group(1) if m else None


class _NotFound(Exception):
    pass


# --------------------------------------------------------------------------- #
# Live checks                                                                 #
# --------------------------------------------------------------------------- #
def run_live(findings: list[Finding], timeout: float) -> None:
    import urllib.error
    import urllib.request

    try:
        catalog = json.loads(read_text(CATALOG))
    except (OSError, json.JSONDecodeError) as exc:
        findings.append(Finding("catalog-json", "fail", f"cannot read catalog: {exc}"))
        raise _NotFound()

    def probe(url: str) -> str:
        """Return resolved | notfound | unavailable for a URL (HEAD, GET fallback)."""
        for method in ("HEAD", "GET"):
            req = urllib.request.Request(url, method=method,
                                         headers={"User-Agent": "mapbox-ops-staleness/1"})
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    return "resolved" if resp.status < 400 else "unavailable"
            except urllib.error.HTTPError as e:
                if e.code in (404, 410):
                    return "notfound"
                if e.code in (403, 405, 429):
                    # forbidden/method-not-allowed/rate-limited: exists or can't tell.
                    if method == "HEAD":
                        continue  # retry with GET
                    return "unavailable" if e.code == 429 else "resolved"
                return "unavailable"
            except (urllib.error.URLError, TimeoutError, OSError):
                return "unavailable"
        return "unavailable"

    # L1 — concrete third-party style URLs (skip templated/keyed ones).
    for t in catalog.get("third_party", []):
        url = t.get("url")
        if not url or "<" in url or "key=" in url:
            continue
        res = probe(url)
        status = {"resolved": "ok", "notfound": "drift", "unavailable": "unavailable"}[res]
        findings.append(Finding(f"url:{t.get('id', url)}", status, url))

    # L2 — has Mapbox GL JS shipped a major beyond v3? A live v4.0.0 on the CDN
    # means the skill's scope assumption needs a human review pass (drift, not error).
    cdn = "https://api.mapbox.com/mapbox-gl-js/v{}.0.0/mapbox-gl.js"
    v3 = probe(cdn.format(GLJS_MAJOR))
    if v3 == "unavailable":
        findings.append(Finding("gljs-cdn", "unavailable", "Mapbox CDN unreachable"))
    else:
        nxt = probe(cdn.format(GLJS_MAJOR + 1))
        if nxt == "resolved":
            findings.append(Finding("gljs-major-bump", "drift",
                                    f"mapbox-gl-js v{GLJS_MAJOR + 1}.0.0 is live — review skill scope"))
        elif nxt == "unavailable":
            findings.append(Finding("gljs-major-bump", "unavailable",
                                    f"could not probe v{GLJS_MAJOR + 1} (network)"))
        else:
            findings.append(Finding("gljs-major-bump", "ok",
                                    f"v{GLJS_MAJOR} current; no v{GLJS_MAJOR + 1} GA"))


# --------------------------------------------------------------------------- #
# Main                                                                        #
# --------------------------------------------------------------------------- #
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True, description="mapbox-ops staleness verifier")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="structural/internal-consistency only (default)")
    mode.add_argument("--live", action="store_true", help="resolve URLs + probe GL JS major (network)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")
    ap.add_argument("-q", "--quiet", action="store_true", help="suppress stderr progress")
    ap.add_argument("--timeout", type=float, default=10.0, help="per-request timeout for --live (seconds)")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        # argparse exits 2 on bad args (matches USAGE); 0 on --help.
        return EXIT_USAGE if e.code not in (0, None) else EXIT_OK

    live = args.live
    mode_name = "live" if live else "offline"

    def emit(msg: str) -> None:
        if not args.quiet:
            print(msg, file=sys.stderr)

    findings: list[Finding] = []
    emit(f"== check-mapbox-facts ({mode_name}) ==")
    try:
        if live:
            run_live(findings, args.timeout)
        else:
            run_offline(findings)
    except _NotFound:
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND",
                                        "message": "skill files missing",
                                        "details": [f.as_dict() for f in findings]}}))
        for f in findings:
            emit(f"  [{f.status.upper()}] {f.check}: {f.detail}")
        return EXIT_NOT_FOUND

    n_fail = sum(1 for f in findings if f.status == "fail")
    n_drift = sum(1 for f in findings if f.status == "drift")
    n_unavail = sum(1 for f in findings if f.status == "unavailable")

    # Output: stdout is data only.
    if args.json:
        print(json.dumps({
            "data": [f.as_dict() for f in findings],
            "meta": {"mode": mode_name, "count": len(findings),
                     "fail": n_fail, "drift": n_drift, "unavailable": n_unavail,
                     "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print(f"{f.check}\t{f.status}\t{f.detail}")

    # Progress summary to stderr.
    for f in findings:
        if f.status != "ok":
            emit(f"  [{f.status.upper()}] {f.check}: {f.detail}")
    emit(f"-- {len(findings)} checks: {n_fail} fail, {n_drift} drift, {n_unavail} unavailable")

    # Exit precedence: a real inconsistency (offline) or 404 (live) is the loudest
    # signal; an unavailable network is advisory and must never mask a clean run as
    # failing — but if the ONLY non-ok results are unavailable, exit 7, never 0.
    if n_fail:
        return EXIT_VALIDATION
    if n_drift:
        return EXIT_DRIFT
    if n_unavail:
        return EXIT_UNAVAILABLE
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
