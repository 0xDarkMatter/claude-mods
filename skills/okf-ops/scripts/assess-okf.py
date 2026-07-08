#!/usr/bin/env python3
# Read-only OKF-readiness scanner for a markdown doc-tree. NEVER writes.
#
# Usage:   assess-okf.py [OPTIONS] [DOC_TREE]
# Input:   argv only. DOC_TREE is a directory of markdown files (default ".").
# Output:  stdout = data. Default = human-readable summary; --json = envelope
#          {"data":{...},"meta":{"schema":"claude-mods.okf-ops.assess-okf/v1",...}}.
# Stderr:  progress + the scan header.
# Exit:    0 on a successful scan (readiness is DATA, not a failure), 2 usage, 3 not-found.
#
# Reports: total .md, how many have frontmatter, how many have non-empty `type`,
# a histogram of frontmatter KEYS, a histogram of `type` VALUES, reserved files
# present, files that would need a `type` to become conformant, OKF-readiness %,
# and which OKF recommended fields already commonly appear.
#
# Examples:
#   assess-okf.py /path/to/docs
#   assess-okf.py --json /path/to/docs | jq '.data.readiness_pct'
#   assess-okf.py --top 10 .
import argparse
import json
import sys
from collections import Counter
from pathlib import Path

SCHEMA = "claude-mods.okf-ops.assess-okf/v1"
SKIP_DIRS = {".git", "node_modules", ".claude", ".venv", "dist", "build"}
RESERVED = {"index.md", "log.md"}
RECOMMENDED = ("title", "description", "resource", "tags", "timestamp")

try:
    import yaml  # type: ignore
    _HAVE_YAML = True
except Exception:
    yaml = None
    _HAVE_YAML = False


def log(msg=""):
    print(msg, file=sys.stderr)


def split_frontmatter(text):
    if text.startswith("﻿"):
        text = text[1:]
    lines = text.splitlines()
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    if i >= len(lines) or lines[i].strip() != "---":
        return None
    for j in range(i + 1, len(lines)):
        if lines[j].strip() == "---":
            return "\n".join(lines[i + 1:j])
    return None


def parse_frontmatter(fm_str):
    """Return dict (possibly empty) or None if unparseable."""
    _yaml = yaml  # local alias narrows cleanly (module global won't)
    if _yaml is not None:
        try:
            data = _yaml.safe_load(fm_str)
            if data is None:
                return {}
            if not isinstance(data, dict):
                return None
            return data
        except Exception:
            return None
    data = {}
    for raw in fm_str.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0] in (" ", "\t", "-"):
            continue
        if ":" not in line:
            return None
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key:
            data[key] = val
    return data


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="assess-okf.py",
        description="Read-only OKF-readiness scanner (never writes).",
        add_help=True,
    )
    p.add_argument("tree", nargs="?", default=".", help="doc-tree directory (default .)")
    p.add_argument("--json", action="store_true", help="emit JSON envelope to stdout")
    p.add_argument("--top", type=int, default=20, metavar="N",
                   help="cap histogram rows (default 20)")
    args = p.parse_args(argv)

    if args.top < 1:
        log("error: --top must be >= 1")
        return 2

    root = Path(args.tree)
    if not root.exists() or not root.is_dir():
        msg = f"doc-tree path not found or not a directory: {args.tree}"
        log(f"error: {msg}")
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": msg, "details": {}}}))
        return 3

    if not _HAVE_YAML:
        log("note: PyYAML not available — using minimal fallback frontmatter parser.")

    root = root.resolve()
    log(f"OKF-readiness scan: {root}")

    md_total = 0
    concept_total = 0
    have_frontmatter = 0
    have_type = 0
    unparseable = 0
    reserved_index = 0
    reserved_log = 0
    need_type = 0  # non-reserved concept docs lacking a non-empty type

    key_hist = Counter()
    type_hist = Counter()
    recommended_present = Counter()

    for path in sorted(root.rglob("*.md")):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        md_total += 1
        name = path.name.lower()
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            text = ""

        if name == "index.md":
            reserved_index += 1
        if name == "log.md":
            reserved_log += 1

        fm_str = split_frontmatter(text)
        has_fm = fm_str is not None
        data = parse_frontmatter(fm_str) if has_fm else None

        if has_fm and data is not None:
            have_frontmatter += 1
            for k in data.keys():
                key_hist[str(k)] += 1
            for rk in RECOMMENDED:
                if rk in data:
                    recommended_present[rk] += 1
            tv = data.get("type")
            if tv is not None and not (isinstance(tv, str) and tv.strip() == ""):
                have_type += 1
                type_hist[str(tv).strip()] += 1
        elif has_fm and data is None:
            unparseable += 1

        if name not in RESERVED:
            concept_total += 1
            tv = data.get("type") if isinstance(data, dict) else None
            conformant = (data is not None and tv is not None
                          and not (isinstance(tv, str) and tv.strip() == ""))
            if not conformant:
                need_type += 1

    conformant_concepts = concept_total - need_type
    readiness_pct = round(100.0 * conformant_concepts / concept_total, 1) if concept_total else 0.0

    def top(counter):
        return [{"key": k, "count": c} for k, c in counter.most_common(args.top)]

    data_out = {
        "md_total": md_total,
        "concept_total": concept_total,
        "have_frontmatter": have_frontmatter,
        "have_frontmatter_pct": round(100.0 * have_frontmatter / md_total, 1) if md_total else 0.0,
        "have_nonempty_type": have_type,
        "have_type_pct": round(100.0 * have_type / md_total, 1) if md_total else 0.0,
        "unparseable_frontmatter": unparseable,
        "reserved_index_md": reserved_index,
        "reserved_log_md": reserved_log,
        "concepts_needing_type": need_type,
        "conformant_concepts": conformant_concepts,
        "readiness_pct": readiness_pct,
        "key_histogram": top(key_hist),
        "type_value_histogram": top(type_hist),
        "recommended_fields_present": [
            {"field": k, "count": recommended_present.get(k, 0)} for k in RECOMMENDED
        ],
    }

    meta = {
        "schema": SCHEMA,
        "tree": str(root),
        "top": args.top,
        "yaml_parser": "PyYAML" if _HAVE_YAML else "fallback",
        "distinct_keys": len(key_hist),
        "distinct_type_values": len(type_hist),
    }

    if args.json:
        print(json.dumps({"data": data_out, "meta": meta}, ensure_ascii=False))
        return 0

    # Human-readable summary to stdout.
    out = []
    out.append("OKF-readiness summary")
    out.append("=" * 60)
    out.append(f"  doc-tree                 : {root}")
    out.append(f"  yaml parser              : {meta['yaml_parser']}")
    out.append("")
    out.append(f"  markdown files (.md)     : {md_total}")
    out.append(f"  reserved index.md        : {reserved_index}")
    out.append(f"  reserved log.md          : {reserved_log}")
    out.append(f"  concept documents        : {concept_total}  (non-reserved)")
    out.append("")
    out.append(f"  with parseable frontmatter : {have_frontmatter}  "
               f"({data_out['have_frontmatter_pct']}% of all .md)")
    out.append(f"  with non-empty `type`      : {have_type}  "
               f"({data_out['have_type_pct']}% of all .md)")
    out.append(f"  unparseable frontmatter    : {unparseable}")
    out.append("")
    out.append(f"  concepts needing a `type`  : {need_type}")
    out.append(f"  conformant concepts        : {conformant_concepts} / {concept_total}")
    out.append(f"  OKF-READINESS              : {readiness_pct}%")
    out.append("")
    out.append(f"  Frontmatter KEYS (top {args.top}, {meta['distinct_keys']} distinct):")
    if key_hist:
        for k, c in key_hist.most_common(args.top):
            out.append(f"     {c:6d}  {k}")
    else:
        out.append("     (none)")
    out.append("")
    out.append(f"  `type` VALUES (top {args.top}, {meta['distinct_type_values']} distinct):")
    if type_hist:
        for k, c in type_hist.most_common(args.top):
            out.append(f"     {c:6d}  {k}")
    else:
        out.append("     (none — no `type` keys present yet)")
    out.append("")
    out.append("  OKF recommended fields already present:")
    for k in RECOMMENDED:
        out.append(f"     {recommended_present.get(k, 0):6d}  {k}")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
