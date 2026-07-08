#!/usr/bin/env python3
"""Headless screenshot + marker-alignment verifier for a served Mapbox GL JS page.

Usage:   screenshot_map.py [OPTIONS] <URL> <OUT.png>
Input:   URL of a *served* map page (http://…, not file://); PNG output path.
         Optional --expect LNG LAT to project a coordinate to its on-canvas pixel.
Output:  stdout = data only — a human result line, or the --json envelope (§4).
Stderr:  progress, warnings, console-error dumps, stack-trace-free diagnostics.
Exit:    0 ok (map ready, no console errors)
         2 usage (bad/missing args)
         5 precondition (playwright not installed / browser missing)
         7 unavailable (map never signalled ready within --timeout)
         10 domain signal (page/console errors were captured) — caller branches on this

Examples:
  screenshot_map.py http://localhost:8777/preview/index.html out.png
  screenshot_map.py http://localhost:8777/index.html out.png --expect 146.9 -36.1
  screenshot_map.py http://localhost:8777/index.html out.png --json | jq '.data'

First run only:  uv run --with playwright python -m playwright install chromium

Why served (not file://): a page that fetches GeoJSON/photos at runtime needs an HTTP
origin and a same-origin canvas (else createImageBitmap taints). Serve one with:
  python -m http.server 8777 --directory <site-dir>
"""
from __future__ import annotations

import argparse
import json
import sys

# Semantic exit codes (SKILL-RESOURCE-PROTOCOL §5).
EX_OK, EX_USAGE, EX_PRECONDITION, EX_UNAVAILABLE, EX_DOMAIN = 0, 2, 5, 7, 10

READY_JS = """
() => {
  try {
    if (window.__mapReady === true) return true;
    const m = window.map;
    if (!m) return false;
    if (typeof m.loaded === 'function' && m.loaded()) return true;
    if (typeof m.isStyleLoaded === 'function' && m.isStyleLoaded()) return true;
    return false;
  } catch (e) { return false; }
}
"""

PROJECT_JS = """
([lng, lat]) => {
  const m = window.map;
  if (!m) return null;
  const r = m.getCanvas().getBoundingClientRect();
  const p = m.project([lng, lat]);
  return { canvas: {x: p.x, y: p.y},
           page: {x: r.left + p.x, y: r.top + p.y},
           size: {w: r.width, h: r.height} };
}
"""

SCHEMA = "claude-mods.mapbox-ops.screenshot_map/v1"


def emit_json(data: dict, code: int) -> int:
    """Print the §4 success/error envelope to stdout and return the exit code."""
    if code in (EX_OK, EX_DOMAIN):
        print(json.dumps({"data": data, "meta": {"schema": SCHEMA, "exit": code}}))
    else:
        print(json.dumps({"error": {"code": data.get("code", "ERROR"),
                                    "message": data.get("message", ""),
                                    "details": data}}))
    return code


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="screenshot_map.py", add_help=True,
        description="Headless screenshot + marker-alignment verifier for a served Mapbox GL JS page.")
    ap.add_argument("url", help="served map page URL (http://…, not file://)")
    ap.add_argument("out", help="screenshot output path (.png)")
    ap.add_argument("--expect", nargs=2, type=float, metavar=("LNG", "LAT"),
                    help="project this lng/lat and report its pixel")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=800)
    ap.add_argument("--timeout", type=int, default=20000, help="readiness timeout (ms)")
    ap.add_argument("--json", action="store_true", help="emit the structured §4 envelope")
    args = ap.parse_args()

    as_json = args.json
    if not args.url.startswith(("http://", "https://")):
        msg = "URL must be http(s):// (the page must be served, not file://)"
        print(f"error: {msg}", file=sys.stderr)
        return emit_json({"code": "USAGE", "message": msg}, EX_USAGE) if as_json else EX_USAGE

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        msg = ("playwright not installed — run: uv run --with playwright "
               "python -m playwright install chromium")
        print(f"error: {msg}", file=sys.stderr)
        return emit_json({"code": "PRECONDITION", "message": msg}, EX_PRECONDITION) if as_json else EX_PRECONDITION

    errors: list[str] = []
    ready = False
    projection: dict | None = None

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch()
        except Exception as e:                       # browser binary not installed
            msg = f"chromium launch failed — run: python -m playwright install chromium ({e})"
            print(f"error: {msg}", file=sys.stderr)
            return emit_json({"code": "PRECONDITION", "message": msg}, EX_PRECONDITION) if as_json else EX_PRECONDITION

        page = browser.new_page(viewport={"width": args.width, "height": args.height},
                                device_scale_factor=2)
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))

        page.goto(args.url, wait_until="networkidle")
        try:
            page.wait_for_function(READY_JS, timeout=args.timeout)
            ready = True
        except Exception:
            print(f"warn: map not ready within {args.timeout}ms "
                  "(set window.__mapReady=true at end of init() for an exact signal)",
                  file=sys.stderr)

        page.screenshot(path=args.out, full_page=False)
        print(f"screenshot → {args.out}", file=sys.stderr)   # status → stderr, not data

        if args.expect:
            projection = page.evaluate(PROJECT_JS, args.expect)
            if not projection:
                print("warn: window.map not found (expose it: `window.map = map`)", file=sys.stderr)

        browser.close()

    # Result assembly
    data = {"out": args.out, "ready": ready, "errorCount": len(errors), "errors": errors[:20]}
    if projection:
        cx, cy = projection["canvas"]["x"], projection["canvas"]["y"]
        w, h = projection["size"]["w"], projection["size"]["h"]
        projection["inside"] = bool(0 <= cx <= w and 0 <= cy <= h)
        data["projection"] = projection

    # Decide exit code: console/page errors are the domain signal (10); never-ready is 7.
    code = EX_DOMAIN if errors else (EX_UNAVAILABLE if not ready else EX_OK)

    if as_json:
        return emit_json(data, code)

    # plain-text data product on stdout
    line = f"ready={ready} errors={len(errors)} out={args.out}"
    if projection:
        line += (f" project={tuple(args.expect)}→canvas("
                 f"{projection['canvas']['x']:.0f},{projection['canvas']['y']:.0f}) "
                 f"{'inside' if projection['inside'] else 'OUTSIDE'}")
    print(line)
    if errors:
        print(f"\n{len(errors)} console/page error(s):", file=sys.stderr)
        for e in errors[:20]:
            print("  - " + e, file=sys.stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
