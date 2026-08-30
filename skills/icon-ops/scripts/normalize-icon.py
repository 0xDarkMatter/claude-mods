#!/usr/bin/env python3
"""Normalize an SVG icon or brand mark for inline, themeable, collision-free use.

Strips editor cruft, namespaces internal ids so inlined SVGs cannot clobber each
other, applies accessibility attributes, and applies exactly ONE deliberate
colour treatment. Optionally emits a <symbol> for a sprite sheet.

Colour is never guessed. A single-colour source rebinds to currentColor; a
MULTI-COLOUR source (a brand mark) is refused unless you name what should happen
to it, because silently flattening a mark is both lossy and a trademark
modification.

Usage:   normalize-icon.py [OPTIONS] <FILE|->
Input:   an SVG file path, or - to read from stdin
Output:  stdout - the normalized SVG (or a JSON envelope under --json)
Stderr:  notes, warnings, errors
Exit:    0 ok, 2 usage, 3 not-found, 4 validation (not parseable SVG),
         10 --check found changes that normalization would make,
         11 multi-colour source refused (pick a colour mode)

Sanitises on the way through: <script>, <foreignObject>, on* event handlers and
javascript:/vbscript:/data:text hrefs are removed, because an INLINED svg runs
script in the host page's origin while an <img src="x.svg"> does not.

Examples:
  normalize-icon.py icon.svg                        # mono icon -> currentColor
  normalize-icon.py --keep-colour logo.svg          # brand mark, colours untouched
  normalize-icon.py --greyscale logo.svg            # luminance-mapped grey variant
  normalize-icon.py --tint '#fff' logo.svg          # knockout / reverse-out
  normalize-icon.py --symbol --id i-search icon.svg >> sprite.svg
  normalize-icon.py --check src/icons/*.svg || echo needs-normalizing
"""

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"

EXIT_OK, EXIT_ERROR, EXIT_USAGE = 0, 1, 2
EXIT_NOT_FOUND, EXIT_VALIDATION = 3, 4
EXIT_CHANGES = 10
EXIT_MULTICOLOUR = 11

DROP_TAGS = {"metadata", "namedview", "foreignObject", "script"}
CRUFT_NS_HINTS = ("sodipodi", "inkscape", "figma", "sketch", "adobe", "serif",
                  "krita", "vectornator", "affinity")
PAINT_KEEP = {"none", "inherit", "currentcolor", "transparent"}
PAINT_ATTRS = ("fill", "stroke", "stop-color", "flood-color", "lighting-color")
GRADIENT_TAGS = {"linearGradient", "radialGradient", "pattern"}
# Attributes whose value may be a url(#id) or #id reference needing namespacing.
REF_ATTRS = ("fill", "stroke", "clip-path", "mask", "filter", "href", "xlink:href",
             "marker-start", "marker-mid", "marker-end", "stop-color")


def log(msg):
    print(msg, file=sys.stderr)


def local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) and "}" in tag else tag


def is_literal_paint(value):
    if value is None:
        return False
    v = value.strip().lower()
    return bool(v) and v not in PAINT_KEEP and not v.startswith("url(")


def canon_colour(value):
    """Normalise a colour string for counting distinct values."""
    v = value.strip().lower()
    m = re.fullmatch(r"#([0-9a-f]{3})", v)
    if m:
        return "#" + "".join(c * 2 for c in m.group(1))
    return v


def to_greyscale(value):
    """Rec.709 luminance-mapped grey. Non-hex values pass through unchanged."""
    v = canon_colour(value)
    m = re.fullmatch(r"#([0-9a-f]{6})", v)
    if not m:
        return None
    r, g, b = (int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4))
    y = round(0.2126 * r + 0.7152 * g + 0.0722 * b)
    y = max(0, min(255, y))
    return "#%02x%02x%02x" % (y, y, y)


def all_achromatic(colours, tolerance=16):
    """True when every colour is a grey/near-grey (R, G and B within tolerance).

    Discriminates a mono icon drawn with several near-black values from a real
    brand mark, which carries chroma. Used only to choose the wording of a
    refusal - never to decide the refusal itself.
    """
    for c in colours:
        m = re.fullmatch(r"#([0-9a-f]{6})", canon_colour(c))
        if not m:
            return False
        ch = [int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4)]
        if max(ch) - min(ch) > tolerance:
            return False
    return True


def iter_style_decls(style):
    for decl in style.split(";"):
        if ":" in decl:
            prop, _, val = decl.partition(":")
            yield prop.strip(), val.strip()
        elif decl.strip():
            yield decl.strip(), None


# === ANALYSIS (runs before any mutation, so refusals are decided on the source) ===

def analyse(root):
    """Collect the facts the colour decision depends on."""
    colours, ids, refs = set(), set(), set()
    has_gradient = False
    for el in root.iter():
        if local(el.tag) in GRADIENT_TAGS:
            has_gradient = True
        for name, value in el.attrib.items():
            lname = local(name).lower()
            if lname == "id":
                ids.add(value)
            if lname in PAINT_ATTRS and is_literal_paint(value):
                colours.add(canon_colour(value))
            if lname == "style":
                for prop, val in iter_style_decls(value):
                    if prop.lower() in PAINT_ATTRS and val and is_literal_paint(val):
                        colours.add(canon_colour(val))
            for m in re.finditer(r"url\(#([^)]+)\)", value or ""):
                refs.add(m.group(1))
            if lname in ("href", "xlink:href") and (value or "").startswith("#"):
                refs.add(value[1:])
    return {"colours": colours, "ids": ids, "refs": refs, "has_gradient": has_gradient}


# === MUTATION ===

def paint_for(value, mode, tint):
    """Map one literal paint to its replacement under the chosen colour mode."""
    if mode == "keep":
        return None
    if mode == "grey":
        return to_greyscale(value)
    if mode == "tint":
        return tint
    return "currentColor"


def clean_element(el, mode, tint, stats):
    doomed = [c for c in el if local(c.tag) in DROP_TAGS]
    for d in doomed:
        el.remove(d)
        stats["dropped_elements"] += 1
    for child in list(el):
        clean_element(child, mode, tint, stats)

    for name in list(el.attrib):
        lname = local(name).lower()
        # Active content. An inlined SVG runs script in the host page's origin -
        # an <img src="x.svg"> does not - so anything that normalizes a
        # third-party SVG *for inlining* is a sanitiser whether it meant to be
        # or not. <script>/<foreignObject> go via DROP_TAGS; handlers and
        # scheme-bearing hrefs have to be stripped here.
        if lname.startswith("on"):
            del el.attrib[name]
            stats["stripped_active"] += 1
            continue
        if lname in ("href", "xlink:href"):
            scheme = el.attrib[name].strip().lower().replace("\t", "").replace("\n", "")
            if scheme.startswith(("javascript:", "vbscript:")) or scheme.startswith("data:text"):
                del el.attrib[name]
                stats["stripped_active"] += 1
                continue
        if "}" in name and not name.startswith("{%s}" % SVG_NS):
            if any(h in name.lower() for h in CRUFT_NS_HINTS):
                del el.attrib[name]
                stats["dropped_attrs"] += 1
                continue
        if lname in PAINT_ATTRS and is_literal_paint(el.attrib[name]):
            new = paint_for(el.attrib[name], mode, tint)
            if new and new != el.attrib[name]:
                el.attrib[name] = new
                stats["recoloured"] += 1
        elif lname == "style":
            out, changed = [], 0
            for prop, val in iter_style_decls(el.attrib[name]):
                if val is None:
                    out.append(prop)
                    continue
                if prop.lower() in PAINT_ATTRS and is_literal_paint(val):
                    new = paint_for(val, mode, tint)
                    if new and new != val:
                        out.append("%s:%s" % (prop, new))
                        changed += 1
                        continue
                out.append("%s:%s" % (prop, val))
            stats["recoloured"] += changed
            joined = ";".join(p for p in out if p)
            if joined:
                el.attrib[name] = joined
            else:
                del el.attrib[name]


def namespace_ids(root, prefix, stats):
    """Prefix every internal id and the references pointing at it.

    Two SVGs inlined into one document that both declare id="a" collide: the
    LAST definition wins for the whole page, so the first icon silently renders
    with the wrong gradient/clip/mask. Brand marks hit this constantly because
    they carry gradients. Namespacing on the way in is the only fix that does
    not depend on whoever assembles the page.
    """
    mapping = {}
    for el in root.iter():
        for name in list(el.attrib):
            if local(name).lower() == "id":
                old = el.attrib[name]
                if old and not old.startswith(prefix + "-"):
                    mapping[old] = "%s-%s" % (prefix, old)
    if not mapping:
        return
    for el in root.iter():
        for name in list(el.attrib):
            lname = local(name).lower()
            value = el.attrib[name]
            if lname == "id" and value in mapping:
                el.attrib[name] = mapping[value]
                continue
            if lname in REF_ATTRS or lname == "style":
                def rep(m):
                    return "url(#%s)" % mapping.get(m.group(1), m.group(1))
                new = re.sub(r"url\(#([^)]+)\)", rep, value)
                if lname in ("href", "xlink:href") and value.startswith("#"):
                    new = "#" + mapping.get(value[1:], value[1:])
                if new != value:
                    el.attrib[name] = new
    stats["namespaced_ids"] = len(mapping)


def derive_viewbox(root):
    w, h = root.get("width"), root.get("height")
    if not (w and h):
        return None
    num = re.compile(r"^\s*([0-9.]+)\s*(px)?\s*$", re.I)
    mw, mh = num.match(w), num.match(h)
    return "0 0 %s %s" % (mw.group(1), mh.group(1)) if (mw and mh) else None


def normalize(source_text, args, stats, mode, prefix):
    try:
        root = ET.fromstring(source_text)
    except ET.ParseError as exc:
        log("[FAIL] not parseable as XML: %s" % exc)
        return None, None
    if local(root.tag) != "svg":
        log("[FAIL] root element is <%s>, expected <svg>" % local(root.tag))
        return None, None

    facts = analyse(root)
    vb = root.get("viewBox") or derive_viewbox(root)
    if not vb:
        log("[FAIL] no viewBox and none derivable from width/height")
        return None, facts
    stats["viewBox"] = vb
    stats["source_colours"] = sorted(facts["colours"])
    stats["has_gradient"] = facts["has_gradient"]

    clean_element(root, mode, args.tint, stats)
    if not args.no_namespace:
        namespace_ids(root, prefix, stats)

    kept = {"viewBox": vb}
    for name, value in root.attrib.items():
        lname = local(name).lower()
        if lname in ("fill", "stroke", "stroke-width", "stroke-linecap",
                     "stroke-linejoin", "stroke-miterlimit", "fill-rule", "clip-rule"):
            kept[lname] = value
        elif lname == "preserveaspectratio":
            kept["preserveAspectRatio"] = value
    if args.keep_size:
        for dim in ("width", "height"):
            val = root.get(dim)
            if val:
                kept[dim] = val
    else:
        stats["size_stripped"] = bool(root.get("width") or root.get("height"))

    if args.stroke:
        kept["fill"] = "none"
        kept.setdefault("stroke", "currentColor")
        kept.setdefault("stroke-width", "1.5")
        kept.setdefault("stroke-linecap", "round")
        kept.setdefault("stroke-linejoin", "round")
    elif mode == "current" and "fill" not in kept:
        kept["fill"] = "currentColor"

    root.attrib.clear()
    for k, v in kept.items():
        root.set(k, v)

    # Accessibility: decorative or named. Never neither.
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

    for el in root.iter():
        el.tag = local(el.tag)
        for name in list(el.attrib):
            if "}" in name:
                el.attrib[local(name)] = el.attrib.pop(name)

    return ET.tostring(root, encoding="unicode"), facts


def main():
    ap = argparse.ArgumentParser(
        prog="normalize-icon.py", add_help=True,
        description="Normalize an SVG icon or brand mark for inline, themeable use.",
        epilog=("COLOUR MODES (choose at most one; multi-colour input requires one):\n"
                "  default        single-colour source -> currentColor\n"
                "  --keep-colour  leave every colour untouched (correct for a brand mark)\n"
                "  --flatten      force a multi-colour source to currentColor (lossy)\n"
                "  --greyscale    luminance-map each colour to grey\n"
                "  --tint COLOUR  flatten every paint to COLOUR (--tint '#fff' = knockout)\n\n"
                "EXAMPLES:\n"
                "  normalize-icon.py icon.svg\n"
                "  normalize-icon.py --keep-colour logo.svg -o src/logos/acme.svg\n"
                "  normalize-icon.py --greyscale logo.svg > acme-grey.svg\n"
                "  normalize-icon.py --tint '#fff' logo.svg > acme-knockout.svg\n"
                "  normalize-icon.py --symbol --id i-search icon.svg >> sprite.svg\n"
                "  normalize-icon.py --check vendor.svg || echo needs-normalizing\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", help="SVG file path, or - for stdin")
    ap.add_argument("--stroke", action="store_true", help="stroke icon: fill=none, stroke=currentColor")
    ap.add_argument("--title", help="accessible name; omit for a decorative icon")
    ap.add_argument("--id", help="id for the output element (required by --symbol)")
    ap.add_argument("--symbol", action="store_true", help="emit a <symbol> for a sprite sheet")
    ap.add_argument("--keep-size", action="store_true", help="keep width/height instead of CSS sizing")
    ap.add_argument("--keep-colour", "--keep-color", dest="keep_colour", action="store_true",
                    help="leave all colours untouched (brand marks)")
    ap.add_argument("--flatten", action="store_true",
                    help="force a multi-colour source to currentColor (lossy)")
    ap.add_argument("--greyscale", "--grayscale", dest="greyscale", action="store_true",
                    help="luminance-map every colour to grey")
    ap.add_argument("--tint", metavar="COLOUR",
                    help="flatten every paint to COLOUR (use '#fff' for a knockout)")
    ap.add_argument("--id-prefix", help="prefix for internal ids (default: derived from --id/filename)")
    ap.add_argument("--no-namespace", action="store_true",
                    help="do not prefix internal ids (risks collisions when inlining)")
    ap.add_argument("--check", action="store_true", help="report only; exit 10 if it would change")
    ap.add_argument("--json", action="store_true", help="emit a JSON envelope")
    ap.add_argument("-o", "--output", help="write to this path atomically")
    args = ap.parse_args()

    chosen = [n for n, v in (("--keep-colour", args.keep_colour), ("--flatten", args.flatten),
                             ("--greyscale", args.greyscale), ("--tint", bool(args.tint))) if v]
    if len(chosen) > 1:
        log("[FAIL] colour modes are mutually exclusive; got %s" % ", ".join(chosen))
        return EXIT_USAGE
    if args.symbol and not args.id:
        log("[FAIL] --symbol requires --id")
        return EXIT_USAGE
    if args.check and args.output:
        log("[FAIL] --check is report-only and cannot be combined with -o")
        return EXIT_USAGE
    if args.tint is not None and not args.tint.strip():
        log("[FAIL] --tint needs a colour value")
        return EXIT_USAGE

    mode = ("keep" if args.keep_colour else "grey" if args.greyscale
            else "tint" if args.tint else "current")

    if args.file == "-":
        source, origin = sys.stdin.read(), "<stdin>"
    else:
        path = os.path.realpath(args.file)
        if not os.path.isfile(path):
            log("[FAIL] no such file: %s" % args.file)
            return EXIT_NOT_FOUND
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            source = fh.read()
        origin = path

    # id prefix must be deterministic: same input + same flags => same output,
    # so a --check in CI never disagrees with the write that follows it.
    prefix = (args.id_prefix or args.id
              or (os.path.splitext(os.path.basename(origin))[0] if origin != "<stdin>" else None)
              or "i" + hashlib.sha1(source.encode("utf-8")).hexdigest()[:6])
    prefix = re.sub(r"[^A-Za-z0-9_-]", "-", prefix).strip("-") or "icon"

    stats = {"dropped_elements": 0, "dropped_attrs": 0, "recoloured": 0,
             "stripped_active": 0, "namespaced_ids": 0, "size_stripped": False, "viewBox": None,
             "a11y": None, "form": None, "source_colours": [], "has_gradient": False,
             "colour_mode": mode}

    result, facts = normalize(source, args, stats, mode, prefix)
    if result is None or facts is None:
        if args.json:
            print(json.dumps({"error": {"code": "VALIDATION",
                                        "message": "input is not a usable SVG icon",
                                        "details": {"source": origin}}}))
        return EXIT_VALIDATION

    # The refusal: a multi-colour source has no safe default. Flattening a brand
    # mark to one colour is lossy AND a trademark modification, so the caller
    # must say which they want rather than discovering it after the fact.
    multi = len(facts["colours"]) > 1 or facts["has_gradient"]
    if multi and mode == "current" and not args.flatten:
        detail = "%d distinct colours%s" % (len(facts["colours"]),
                                            " + gradient/pattern" if facts["has_gradient"] else "")
        if args.json:
            print(json.dumps({"error": {"code": "MULTICOLOUR",
                                        "message": "multi-colour source needs an explicit colour mode",
                                        "details": {"source": origin, "colours": sorted(facts["colours"]),
                                                    "has_gradient": facts["has_gradient"]}}}))
        elif all_achromatic(facts["colours"]) and not facts["has_gradient"]:
            # Several near-black/grey values is a sloppily-drawn MONO icon, not a
            # mark. Still refuse rather than guess - losing a two-tone grey is a
            # real loss - but lead with the option the caller almost certainly wants.
            log("[FAIL] %s has %s, all achromatic - most likely a mono icon drawn"
                % (origin, detail))
            log("       with several greys rather than a brand mark.")
            log("         --flatten       collapse them to currentColor (probably this)")
            log("         --keep-colour   keep the grey steps exactly as drawn")
        else:
            log("[FAIL] %s looks like a brand mark (%s)." % (origin, detail))
            log("       Rebinding it to currentColor would flatten it to a silhouette,")
            log("       which is lossy and counts as modifying the mark. Choose one:")
            log("         --keep-colour   keep it exactly as published (usually correct)")
            log("         --greyscale     luminance-mapped grey variant")
            log("         --tint '#fff'   knockout / reverse-out variant")
            log("         --flatten       yes, really flatten it to currentColor")
        return EXIT_MULTICOLOUR

    changed = bool(stats["dropped_elements"] or stats["dropped_attrs"]
                   or stats["recoloured"] or stats["size_stripped"]
                   or stats["namespaced_ids"] or stats["stripped_active"])

    if args.json:
        print(json.dumps({
            "data": [dict({"source": origin, "svg": None if args.check else result,
                           "changed": changed}, **stats)],
            "meta": {"count": 1, "changed": changed,
                     "schema": "claude-mods.icon-ops.normalize-icon/v1"}}))
    elif not args.check:
        if args.output:
            d = os.path.dirname(os.path.realpath(args.output)) or "."
            fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(result)
            os.replace(tmp, args.output)
            log("[PASS] wrote %s" % args.output)
        else:
            print(result)
    else:
        log("[%s] %s: %s" % ("WARN" if changed else "PASS", origin,
                             "normalization would change this file" if changed
                             else "already normalized"))

    return EXIT_CHANGES if (args.check and changed) else EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(EXIT_ERROR)
