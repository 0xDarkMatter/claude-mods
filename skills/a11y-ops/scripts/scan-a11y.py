#!/usr/bin/env python3
"""Static pre-flight for high-confidence WCAG failures in HTML/JSX/Vue source.

Catches the recurring, mechanically-detectable failures that appear on most
sites - missing alt text, unlabelled inputs, click handlers on non-interactive
elements, positive tabindex, heading-level skips, aria-hidden over focusable
content.

THIS IS NOT AN AUDIT. Automated tooling detects a minority of WCAG failures even
against a rendered DOM, and this runs against SOURCE, so it sees less again. It
exists to clear the cheap findings before a human spends time on the keyboard
and screen-reader passes that find the rest. A clean run means "nothing obvious
in the markup", never "accessible".

Usage:   scan-a11y.py [OPTIONS] <PATH>...
Input:   files or directories; .html/.htm/.jsx/.tsx/.vue/.svelte/.astro are scanned
Output:  stdout - one finding per line (TSV), or a JSON envelope under --json
Stderr:  progress, warnings, errors
Exit:    0 no findings, 2 usage, 3 path not found, 5 nothing scannable,
         10 findings (the DOMAIN SIGNAL a CI gate branches on)

Examples:
  scan-a11y.py src/
  scan-a11y.py --min-severity serious src/ --json | jq '.data[]'
  scan-a11y.py index.html || echo "fix the findings above"
"""

import argparse
import json
import os
import re
import sys

EXIT_OK, EXIT_ERROR, EXIT_USAGE = 0, 1, 2
EXIT_NOT_FOUND, EXIT_PRECONDITION = 3, 5
EXIT_FINDINGS = 10

SCAN_EXT = {".html", ".htm", ".jsx", ".tsx", ".vue", ".svelte", ".astro"}
SKIP_DIRS = {"node_modules", ".git", "dist", "build", ".next", ".nuxt", "vendor",
             "__pycache__", "coverage", ".svelte-kit", ".astro", "out"}
SEVERITY_ORDER = {"minor": 0, "moderate": 1, "serious": 2, "critical": 3}

# Elements that are focusable/interactive without any extra attributes.
INTERACTIVE = r"a|button|input|select|textarea|summary|details|label|option"
# Void + text-bearing elements we treat as "has an accessible name" sources.
NAME_ATTRS = ("aria-label", "aria-labelledby", "title")


def log(msg):
    print(msg, file=sys.stderr)


def strip_comments(text):
    """Remove HTML and JSX block comments so commented-out markup is not flagged."""
    text = re.sub(r"<!--.*?-->", lambda m: " " * len(m.group(0)), text, flags=re.S)
    text = re.sub(r"\{\s*/\*.*?\*/\s*\}", lambda m: " " * len(m.group(0)), text, flags=re.S)
    return text


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def attrs_of(tag_text):
    """Parse an opening tag's attributes. Handles quoted, unquoted and JSX braces."""
    out = {}
    for m in re.finditer(
            r"""([:@a-zA-Z_][-\w:.]*)\s*=\s*("([^"]*)"|'([^']*)'|\{([^}]*)\}|([^\s>]+))""",
            tag_text):
        name = m.group(1).lower()
        value = m.group(3) or m.group(4) or m.group(5) or m.group(6) or ""
        out[name] = value.strip()
    # Valueless (boolean) attributes.
    for m in re.finditer(r"(?<![-\w:.=])([a-zA-Z_][-\w:.]*)(?=[\s/>])", tag_text):
        out.setdefault(m.group(1).lower(), "")
    return out


def has_name(a, inner_text=""):
    """Does this element carry an accessible name from any usual source?"""
    if inner_text and re.sub(r"<[^>]+>", "", inner_text).strip():
        return True
    for k in NAME_ATTRS:
        if a.get(k, "").strip():
            return True
    # JSX/Vue dynamic bindings - we cannot evaluate them, so treat as named
    # rather than emit a false positive.
    for k in list(a):
        if k.lstrip(":@").replace("v-bind:", "") in NAME_ATTRS and a[k].strip():
            return True
    if a.get("aria-hidden", "") == "true":
        return True
    return False


def iter_tags(text, names):
    """Yield (name, attrs, start_index, raw) for each opening tag in `names`."""
    pattern = re.compile(r"<(%s)(\s[^<>]*?)?/?>" % names, re.I | re.S)
    for m in pattern.finditer(text):
        yield m.group(1).lower(), attrs_of(m.group(2) or ""), m.start(), m.group(0)


def inner_after(text, index, tag):
    """Best-effort inner content of the element opening at `index`."""
    close = re.search(r"</%s\s*>" % tag, text[index:], re.I)
    if not close:
        return ""
    open_end = text.find(">", index)
    return text[open_end + 1: index + close.start()] if open_end != -1 else ""


# === CHECKS =================================================================
# Each returns a list of (rule, severity, wcag, line, message).
# Rules are deliberately conservative: a linter that cries wolf gets muted, and
# a muted linter is worse than no linter. Anything requiring a rendered DOM or
# a judgement call belongs in the manual passes, not here.

def check_images(text, findings):
    for name, a, idx, raw in iter_tags(text, "img"):
        if "alt" not in a and not any(k.lstrip(":@").endswith("alt") for k in a):
            findings.append(("img-missing-alt", "critical", "1.1.1", line_of(text, idx),
                             "<img> has no alt attribute; decorative images need alt=\"\""))


def check_lang_and_title(text, findings, is_html):
    if not is_html:
        return
    for name, a, idx, raw in iter_tags(text, "html"):
        if not a.get("lang", "").strip():
            findings.append(("html-missing-lang", "serious", "3.1.1", line_of(text, idx),
                             "<html> has no lang attribute; screen readers pick the wrong voice"))
    if re.search(r"<html", text, re.I) and not re.search(r"<title\s*>\s*\S", text, re.I):
        findings.append(("missing-title", "serious", "2.4.2", 1,
                         "document has no non-empty <title>"))


def check_inputs(text, findings):
    labelled_ids = {m.group(1) for m in re.finditer(r"<label[^>]*\bfor=[\"']([^\"']+)", text, re.I)}
    for name, a, idx, raw in iter_tags(text, "input|select|textarea"):
        if a.get("type", "").lower() in ("hidden", "submit", "button", "reset", "image"):
            continue
        el_id = a.get("id", "")
        if el_id and el_id in labelled_ids:
            continue
        if has_name(a):
            continue
        if a.get("placeholder", "").strip():
            findings.append(("placeholder-as-label", "serious", "3.3.2", line_of(text, idx),
                             "placeholder is not a label; it disappears on input and many SRs ignore it"))
        else:
            findings.append(("input-missing-label", "critical", "3.3.2", line_of(text, idx),
                             "<%s> has no associated label or accessible name" % name))


def check_empty_interactive(text, findings):
    for name, a, idx, raw in iter_tags(text, "a|button"):
        if raw.rstrip().endswith("/>"):
            continue
        inner = inner_after(text, idx, name)
        # An icon-only control is named by aria-label on the control itself.
        if has_name(a, inner):
            continue
        if re.search(r"<(svg|img|i|span)\b", inner, re.I):
            findings.append(("icon-only-control-unnamed", "critical", "4.1.2", line_of(text, idx),
                             "icon-only <%s> has no accessible name; put aria-label on the control" % name))
        else:
            findings.append(("empty-interactive", "critical", "4.1.2", line_of(text, idx),
                             "<%s> has no text content and no accessible name" % name))
    for name, a, idx, raw in iter_tags(text, "a"):
        if "href" not in a and not any(k.lstrip(":@") == "href" for k in a) and "role" not in a:
            findings.append(("anchor-without-href", "serious", "2.1.1", line_of(text, idx),
                             "<a> without href is not focusable or activatable; use <button>"))


def check_tabindex(text, findings):
    for m in re.finditer(r"tabindex\s*=\s*[\"'{]?\s*(\d+)", text, re.I):
        if int(m.group(1)) > 0:
            findings.append(("positive-tabindex", "serious", "2.4.3", line_of(text, m.start()),
                             "positive tabindex=%s overrides DOM order and breaks tab sequence" % m.group(1)))


def check_click_handlers(text, findings):
    """A click handler on a non-interactive element is keyboard-inaccessible."""
    for m in re.finditer(r"<(\w[-\w]*)((?:\s[^<>]*?)?)/?>", text):
        tag = m.group(1).lower()
        if re.fullmatch(INTERACTIVE, tag):
            continue
        a = attrs_of(m.group(2) or "")
        has_click = any(k in ("onclick", "@click", "v-on:click", "on:click") for k in a)
        if not has_click:
            continue
        has_key = any("keydown" in k or "keypress" in k or "keyup" in k for k in a)
        if not (a.get("role") and "tabindex" in a and has_key):
            findings.append(("click-on-non-interactive", "serious", "2.1.1", line_of(text, m.start()),
                             "<%s> has a click handler but is not keyboard-operable; "
                             "use <button>, or add role + tabindex + a key handler" % tag))


def check_headings(text, findings):
    levels = [(int(m.group(1)), m.start()) for m in re.finditer(r"<h([1-6])\b", text, re.I)]
    prev = None
    for lvl, idx in levels:
        if prev is not None and lvl > prev + 1:
            findings.append(("heading-skip", "moderate", "1.3.1", line_of(text, idx),
                             "heading jumps h%d -> h%d; levels convey structure and must not skip" % (prev, lvl)))
        prev = lvl


def check_aria_hidden_focusable(text, findings):
    for m in re.finditer(r"<(\w[-\w]*)((?:\s[^<>]*?)?)/?>", text):
        a = attrs_of(m.group(2) or "")
        if a.get("aria-hidden", "") != "true":
            continue
        tag = m.group(1).lower()
        focusable = re.fullmatch(INTERACTIVE, tag) or ("tabindex" in a and not a.get("tabindex", "").startswith("-"))
        if focusable:
            findings.append(("aria-hidden-focusable", "critical", "4.1.2", line_of(text, m.start()),
                             "aria-hidden=\"true\" on a focusable <%s> creates a focusable "
                             "element with no accessible name" % tag))


def check_iframe_title(text, findings):
    for name, a, idx, raw in iter_tags(text, "iframe"):
        if not has_name(a):
            findings.append(("iframe-missing-title", "serious", "4.1.2", line_of(text, idx),
                             "<iframe> has no title; it is announced as an unlabelled frame"))


def check_autoplay(text, findings):
    for name, a, idx, raw in iter_tags(text, "video|audio"):
        if "autoplay" in a and "muted" not in a:
            findings.append(("autoplay-unmuted", "serious", "1.4.2", line_of(text, idx),
                             "<%s autoplay> without muted; audio over 3s needs a stop control" % name))


def check_duplicate_ids(text, findings):
    seen = {}
    for m in re.finditer(r"\bid\s*=\s*[\"']([^\"']+)[\"']", text):
        seen.setdefault(m.group(1), []).append(m.start())
    for val, spots in seen.items():
        if len(spots) > 1:
            findings.append(("duplicate-id", "moderate", "4.1.2", line_of(text, spots[1]),
                             "id=\"%s\" appears %d times; label/aria references resolve to the first only"
                             % (val, len(spots))))


CHECKS = (check_images, check_inputs, check_empty_interactive, check_tabindex,
          check_click_handlers, check_headings, check_aria_hidden_focusable,
          check_iframe_title, check_autoplay, check_duplicate_ids)


def scan_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        log("[WARN] cannot read %s: %s" % (path, exc))
        return []
    text = strip_comments(raw)
    findings = []
    for fn in CHECKS:
        fn(text, findings)
    check_lang_and_title(text, findings, path.lower().endswith((".html", ".htm")))
    return [{"file": path, "rule": r, "severity": s, "wcag": w, "line": ln, "message": msg}
            for (r, s, w, ln, msg) in findings]


def collect(paths):
    out = []
    for p in paths:
        if os.path.isfile(p):
            out.append(p)
        elif os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
                for f in sorted(files):
                    if os.path.splitext(f)[1].lower() in SCAN_EXT:
                        out.append(os.path.join(root, f))
        else:
            log("[FAIL] no such path: %s" % p)
            return None
    return out


def main():
    ap = argparse.ArgumentParser(
        prog="scan-a11y.py", add_help=True,
        description="Static pre-flight for high-confidence WCAG failures in markup.",
        epilog=("This is a PRE-FILTER, not an audit. Automated tools catch a minority of\n"
                "WCAG failures against a rendered DOM, and this reads source, so it sees\n"
                "less again. A clean run means 'nothing obvious in the markup'.\n\n"
                "EXAMPLES:\n"
                "  scan-a11y.py src/\n"
                "  scan-a11y.py --min-severity serious src/\n"
                "  scan-a11y.py --json src/ | jq '.data[] | select(.severity==\"critical\")'\n"
                "  scan-a11y.py index.html || echo 'findings above'\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="files or directories to scan")
    ap.add_argument("--min-severity", choices=sorted(SEVERITY_ORDER, key=lambda k: SEVERITY_ORDER[k]),
                    default="minor", help="suppress findings below this severity")
    ap.add_argument("--rule", action="append", metavar="ID",
                    help="only report this rule (repeatable)")
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope")
    ap.add_argument("--quiet", action="store_true", help="suppress stderr progress")
    args = ap.parse_args()

    files = collect(args.paths)
    if files is None:
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": "path does not exist",
                                        "details": {"paths": args.paths}}}))
        return EXIT_NOT_FOUND
    if not files:
        log("[FAIL] no scannable files found (looked for: %s)" % ", ".join(sorted(SCAN_EXT)))
        if args.json:
            print(json.dumps({"error": {"code": "PRECONDITION", "message": "no scannable files",
                                        "details": {"extensions": sorted(SCAN_EXT)}}}))
        return EXIT_PRECONDITION

    floor = SEVERITY_ORDER[args.min_severity]
    findings = []
    for f in files:
        for item in scan_file(f):
            if SEVERITY_ORDER[item["severity"]] < floor:
                continue
            if args.rule and item["rule"] not in args.rule:
                continue
            findings.append(item)
    findings.sort(key=lambda d: (-SEVERITY_ORDER[d["severity"]], d["file"], d["line"]))

    if args.json:
        counts = {}
        for f in findings:
            counts[f["severity"]] = counts.get(f["severity"], 0) + 1
        print(json.dumps({"data": findings,
                          "meta": {"count": len(findings), "files_scanned": len(files),
                                   "by_severity": counts,
                                   "schema": "claude-mods.a11y-ops.scan-a11y/v1"}}))
    else:
        for f in findings:
            print("%s\t%d\t%s\t%s\t%s\t%s"
                  % (f["file"], f["line"], f["severity"], f["wcag"], f["rule"], f["message"]))

    if not args.quiet:
        if findings:
            log("[WARN] %d finding(s) across %d file(s). Automated checks are a floor, "
                "not a ceiling - the keyboard and screen-reader passes find the rest."
                % (len(findings), len(files)))
        else:
            log("[PASS] no static findings in %d file(s). This is not a conformance claim."
                % len(files))

    return EXIT_FINDINGS if findings else EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(EXIT_ERROR)
