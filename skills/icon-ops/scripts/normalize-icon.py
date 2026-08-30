#!/usr/bin/env python3
"""Normalize a downloaded SVG icon for inline, themeable use.

Strips editor cruft, rebinds hardcoded colours to currentColor, drops fixed
width/height so CSS controls size, and applies the correct accessibility
attributes. Optionally emits a <symbol> for a sprite sheet.

Usage:   normalize-icon.py [OPTIONS] <FILE|->
Input:   an SVG file path, or - to read from stdin
Output:  stdout - the normalized SVG (or a JSON envelope under --json)
Stderr:  notes, warnings, errors
Exit:    0 ok, 2 usage, 3 not-found, 4 validation (not parseable SVG),
         10 --check found changes that normalization would make

Examples:
  normalize-icon.py download.svg > icon.svg
  normalize-icon.py --stroke --title "Search" search.svg
  normalize-icon.py --check vendor.svg || echo "needs normalizing"
  normalize-icon.py --symbol --id i-search search.svg >> sprite.svg
  cat raw.svg | normalize-icon.py - --json | jq .meta
"""

import argparse
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
XLINK_NS = "http://www.w3.org/1999/xlink"

EXIT_OK, EXIT_ERROR, EXIT_USAGE = 0, 1, 2
EXIT_NOT_FOUND, EXIT_VALIDATION = 3, 4
EXIT_CHANGES = 10

# Elements that carry no rendering value in a shipped icon. <metadata> and the
# editor namedview blocks routinely account for more bytes than the artwork.
DROP_TAGS = {"metadata", "namedview", "foreignObject", "script"}

# Attributes in these namespaces are editor bookkeeping, never rendering.
CRUFT_NS_HINTS = ("sodipodi", "inkscape", "figma", "sketch", "adobe", "serif",
                  "krita", "vectornator", "affinity")

# A paint value that is none/inherit/currentColor/a url() reference is already
# doing the right thing; anything else is a literal colour we should rebind.
PAINT_KEEP = {"none", "inherit", "currentcolor", "transparent"}


def log(msg):
    print(msg, file=sys.stderr)


def local(tag):
    """Strip any {namespace} prefix from an ElementTree tag."""
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) and "}" in tag else tag


def is_literal_paint(value):
    if value is None:
        return False
    v = value.strip().lower()
    if not v or v in PAINT_KEEP or v.startswith("url("):
        return False
    return True


def clean_element(el, stats, stroke_mode):
    """Recursively drop cruft and rebind paints. Returns children to remove."""
    doomed = []
    for child in list(el):
        if local(child.tag) in DROP_TAGS:
            doomed.append(child)
            stats["dropped_elements"] += 1
            continue
        clean_element(child, stats, stroke_mode)
    for d in doomed:
        el.remove(d)

    for name in list(el.attrib):
        lname = local(name).lower()
        # Editor-namespace bookkeeping, and the id/class churn that ships with it.
        if "}" in name and not name.startswith("{%s}" % SVG_NS):
            if any(h in name.lower() for h in CRUFT_NS_HINTS):
                del el.attrib[name]
                stats["dropped_attrs"] += 1
                continue
        if lname in ("fill", "stroke"):
            if is_literal_paint(el.attrib[name]):
                el.attrib[name] = "currentColor"
                stats["recoloured"] += 1
        elif lname == "style":
            new, n = rebind_style(el.attrib[name])
            if n:
                stats["recoloured"] += n
            if new.strip():
                el.attrib[name] = new
            else:
                del el.attrib[name]


def rebind_style(style):
    """Rewrite literal fill/stroke inside a style="" attribute."""
    out, changed = [], 0
    for decl in style.split(";"):
        if ":" not in decl:
            if decl.strip():
                out.append(decl.strip())
            continue
        prop, _, val = decl.partition(":")
        if prop.strip().lower() in ("fill", "stroke") and is_literal_paint(val):
            out.append("%s:currentColor" % prop.strip())
            changed += 1
        else:
            out.append("%s:%s" % (prop.strip(), val.strip()))
    return ";".join(p for p in out if p), changed


def derive_viewbox(root):
    """Build a viewBox from width/height when the source omitted one."""
    w, h = root.get("width"), root.get("height")
    if not w or not h:
        return None
    num = re.compile(r"^\s*([0-9.]+)\s*(px)?\s*$", re.I)
    mw, mh = num.match(w), num.match(h)
    if not (mw and mh):
        return None
    return "0 0 %s %s" % (mw.group(1), mh.group(1))


def normalize(source_text, args, stats):
    try:
        root = ET.fromstring(source_text)
    except ET.ParseError as exc:
        log("[FAIL] not parseable as XML: %s" % exc)
        return None
    if local(root.tag) != "svg":
        log("[FAIL] root element is <%s>, expected <svg>" % local(root.tag))
        return None

    vb = root.get("viewBox") or derive_viewbox(root)
    if not vb:
        log("[FAIL] no viewBox and none derivable from width/height")
        return None
    stats["viewBox"] = vb

    clean_element(root, stats, args.stroke)

    # Rebuild the root attribute set explicitly. Whitelisting is the only
    # reliable way to shed vendor attributes we have not enumerated.
    kept = {"viewBox": vb}
    for name, value in root.attrib.items():
        lname = local(name).lower()
        if lname in ("fill", "stroke", "stroke-width", "stroke-linecap",
                     "stroke-linejoin", "stroke-miterlimit", "fill-rule",
                     "clip-rule", "preserveaspectratio"):
            kept[lname if lname != "preserveaspectratio" else "preserveAspectRatio"] = value
    if args.keep_size:
        for dim in ("width", "height"):
            val = root.get(dim)
            if val:
                kept[dim] = val
    else:
        stats["size_stripped"] = bool(root.get("width") or root.get("height"))

    # Stroke icons must not inherit a fill, or the glyph floods solid.
    if args.stroke:
        kept["fill"] = "none"
        kept.setdefault("stroke", "currentColor")
        kept.setdefault("stroke-width", "1.5")
        kept.setdefault("stroke-linecap", "round")
        kept.setdefault("stroke-linejoin", "round")
    elif "fill" not in kept:
        kept["fill"] = "currentColor"

    root.attrib.clear()
    for k, v in kept.items():
        root.set(k, v)

    # Accessibility: a decorative icon must be hidden from the tree; a
    # meaningful one needs a name. There is no correct third option, so the
    # script always emits one or the other rather than leaving it to chance.
    if args.title:
        root.set("role", "img")
        t = ET.Element("title")
        t.text = args.title
        root.insert(0, t)
        stats["a11y"] = "labelled"
    else:
        root.set("aria-hidden", "true")
        root.set("focusable", "false")
        stats["a11y"] = "decorative"

    if args.symbol:
        root.tag = "symbol"
        root.set("id", args.id or "icon")
        for drop in ("aria-hidden", "focusable"):
            root.attrib.pop(drop, None)
        stats["form"] = "symbol"
    else:
        root.tag = "svg"
        root.set("xmlns", SVG_NS)
        stats["form"] = "svg"
        if args.id:
            root.set("id", args.id)

    # Strip residual namespace prefixes from every descendant tag so output is
    # plain SVG rather than ET's ns0: form.
    for el in root.iter():
        el.tag = local(el.tag)
        for name in list(el.attrib):
            if "}" in name:
                el.attrib[local(name)] = el.attrib.pop(name)

    return ET.tostring(root, encoding="unicode")


def main():
    ap = argparse.ArgumentParser(
        prog="normalize-icon.py", add_help=True,
        description="Normalize an SVG icon for inline, themeable use.",
        epilog=("EXAMPLES:\n"
                "  normalize-icon.py download.svg > icon.svg\n"
                "  normalize-icon.py --stroke --title \"Search\" search.svg\n"
                "  normalize-icon.py --check vendor.svg || echo needs-normalizing\n"
                "  normalize-icon.py --symbol --id i-search search.svg >> sprite.svg\n"
                "  cat raw.svg | normalize-icon.py - --json | jq .meta\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", help="SVG file path, or - for stdin")
    ap.add_argument("--stroke", action="store_true",
                    help="stroke icon: fill=none, stroke=currentColor")
    ap.add_argument("--title", help="accessible name; omit for a decorative icon")
    ap.add_argument("--id", help="id for the output element (required by --symbol)")
    ap.add_argument("--symbol", action="store_true",
                    help="emit a <symbol> for a sprite sheet instead of an <svg>")
    ap.add_argument("--keep-size", action="store_true",
                    help="keep width/height instead of letting CSS size it")
    ap.add_argument("--check", action="store_true",
                    help="report only; exit 10 if normalization would change the file")
    ap.add_argument("--json", action="store_true", help="emit a JSON envelope")
    ap.add_argument("-o", "--output", help="write to this path atomically")
    args = ap.parse_args()

    if args.symbol and not args.id:
        log("[FAIL] --symbol requires --id")
        return EXIT_USAGE
    if args.check and args.output:
        log("[FAIL] --check is report-only and cannot be combined with -o")
        return EXIT_USAGE

    if args.file == "-":
        source = sys.stdin.read()
        origin = "<stdin>"
    else:
        path = os.path.realpath(args.file)
        if not os.path.isfile(path):
            log("[FAIL] no such file: %s" % args.file)
            return EXIT_NOT_FOUND
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            source = fh.read()
        origin = path

    stats = {"dropped_elements": 0, "dropped_attrs": 0, "recoloured": 0,
             "size_stripped": False, "viewBox": None, "a11y": None, "form": None}
    result = normalize(source, args, stats)
    if result is None:
        if args.json:
            print(json.dumps({"error": {"code": "VALIDATION",
                                        "message": "input is not a usable SVG icon",
                                        "details": {"source": origin}}}))
        return EXIT_VALIDATION

    changed = (stats["dropped_elements"] or stats["dropped_attrs"]
               or stats["recoloured"] or stats["size_stripped"])

    if args.json:
        print(json.dumps({
            "data": [{"source": origin, "svg": None if args.check else result,
                      "changed": bool(changed), **stats}],
            "meta": {"count": 1, "changed": bool(changed),
                     "schema": "claude-mods.icon-ops.normalize-icon/v1"}}))
    elif not args.check:
        if args.output:
            # Atomic write: a half-written icon in a sprite is worse than none.
            d = os.path.dirname(os.path.realpath(args.output)) or "."
            fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(result)
            os.replace(tmp, args.output)
            log("[PASS] wrote %s" % args.output)
        else:
            print(result)

    if not args.json and args.check:
        log("[%s] %s: %s" % ("WARN" if changed else "PASS", origin,
                             "normalization would change this file" if changed
                             else "already normalized"))

    if args.check and changed:
        return EXIT_CHANGES
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(EXIT_ERROR)
