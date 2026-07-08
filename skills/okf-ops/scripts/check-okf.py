#!/usr/bin/env python3
# Validate an Open Knowledge Format (OKF v0.1) bundle for conformance.
#
# Usage:   check-okf.py [OPTIONS] [BUNDLE_DIR]
# Input:   argv only. BUNDLE_DIR is a directory of markdown files (default ".").
# Output:  stdout = data only. Default = TSV of findings (file<TAB>severity<TAB>message);
#          --json = envelope {"data":[...],"meta":{"schema":"claude-mods.okf-ops.check-okf/v1",...}}.
# Stderr:  headers, progress, the human-readable verdict, errors.
# Exit:    0 conformant, 2 usage, 3 not-found, 4 frontmatter-present-but-unparseable,
#          10 non-conformant (hard conformance failures, or soft warnings under --strict).
#
# OKF rules enforced (hard): every non-reserved .md has parseable YAML frontmatter
# with a non-empty `type`. Reserved files (index.md, log.md) get light structural
# sanity only. Per the permissive-consumption rule, broken links / missing optional
# fields are INFO and never cause a conformance failure (unless --strict).
#
# Examples:
#   check-okf.py ./my-bundle
#   check-okf.py --json ./my-bundle | jq '.data[] | select(.severity=="error")'
#   check-okf.py --strict .          # soft warnings also fail (exit 10)
import argparse
import json
import sys
from pathlib import Path

SCHEMA = "claude-mods.okf-ops.check-okf/v1"
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
    """Return (frontmatter_str_or_None, found_fences_bool).

    A document has frontmatter iff it starts (after optional BOM/whitespace-free
    leading newlines) with a line that is exactly '---' and has a closing '---'.
    """
    # Normalise leading BOM
    if text.startswith("﻿"):
        text = text[1:]
    lines = text.splitlines()
    # Allow leading blank lines before the opening fence
    i = 0
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    if i >= len(lines) or lines[i].strip() != "---":
        return None, False
    # find closing fence
    for j in range(i + 1, len(lines)):
        if lines[j].strip() == "---":
            return "\n".join(lines[i + 1:j]), True
    # opening fence with no close
    return None, True


def parse_frontmatter(fm_str):
    """Parse frontmatter into a dict. Returns (dict_or_None, used_fallback_bool).

    dict is None when the block is genuinely unparseable.
    """
    _yaml = yaml  # local alias narrows cleanly (module global won't)
    if _yaml is not None:
        try:
            data = _yaml.safe_load(fm_str)
            if data is None:
                return {}, False
            if not isinstance(data, dict):
                return None, False
            return data, False
        except Exception:
            return None, False
    # Fallback: minimal key: value line parser. Good enough to detect `type`.
    data = {}
    for raw in fm_str.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # only treat top-level (non-indented) key: value lines as keys
        if line[0] in (" ", "\t", "-"):
            continue
        if ":" not in line:
            return None, True  # not a simple key:value block -> unparseable in fallback
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        # strip surrounding quotes
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key:
            data[key] = val
    return data, True


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="check-okf.py",
        description="Validate an OKF v0.1 bundle for conformance.",
        add_help=True,
    )
    p.add_argument("bundle", nargs="?", default=".", help="bundle directory (default .)")
    p.add_argument("--json", action="store_true", help="emit JSON envelope to stdout")
    p.add_argument("--strict", action="store_true",
                   help="soft warnings also count toward non-conformance (exit 10)")
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        # argparse exits 0 on --help, 2 on error — both acceptable per protocol
        raise

    root = Path(args.bundle)
    if not root.exists() or not root.is_dir():
        msg = f"bundle path not found or not a directory: {args.bundle}"
        log(f"error: {msg}")
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": msg, "details": {}}}))
        return 3

    if not _HAVE_YAML:
        log("note: PyYAML not available — using minimal fallback frontmatter parser.")

    root = root.resolve()
    log(f"OKF conformance check: {root}")

    findings = []          # list of {file, severity, message}
    unparseable = False    # any frontmatter-present-but-unparseable
    md_total = 0
    concept_total = 0
    okf_version = None

    for path in sorted(root.rglob("*.md")):
        # skip excluded dirs
        if any(part in SKIP_DIRS or part == "worktrees" for part in path.parts):
            # only skip 'worktrees' when under a .claude dir
            if "worktrees" in path.parts:
                idx = path.parts.index("worktrees")
                if idx > 0 and path.parts[idx - 1] == ".claude":
                    continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
        md_total += 1
        rel = path.relative_to(root).as_posix()
        name = path.name.lower()

        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            findings.append({"file": rel, "severity": "error",
                             "message": f"could not read file: {e}"})
            continue

        fm_str, found_fences = split_frontmatter(text)

        if name in RESERVED:
            # Light structural sanity only.
            is_root_index = (name == "index.md" and path.parent == root)
            if found_fences and fm_str is not None and name == "index.md":
                # allowed exception: root index.md may declare okf_version
                data, _ = parse_frontmatter(fm_str)
                if data and "okf_version" in data:
                    okf_version = data.get("okf_version")
                if not is_root_index and data is not None:
                    findings.append({"file": rel, "severity": "warning",
                                     "message": "non-root index.md has frontmatter "
                                                "(only root index.md may declare okf_version)"})
            if found_fences and fm_str is None:
                findings.append({"file": rel, "severity": "warning",
                                 "message": "reserved file opens '---' fence but never closes it"})
            # very light content sanity
            if name == "log.md":
                import re as _re
                if not _re.search(r"(?m)^#{1,6}\s*\d{4}-\d{2}-\d{2}", text) and text.strip():
                    findings.append({"file": rel, "severity": "info",
                                     "message": "log.md has no ISO-8601 (YYYY-MM-DD) date headings"})
            continue

        # Non-reserved => concept document. Hard requirements apply.
        concept_total += 1

        if not found_fences or fm_str is None:
            if found_fences and fm_str is None:
                # fence opened but unparseable / unclosed
                findings.append({"file": rel, "severity": "error",
                                 "message": "frontmatter fence present but block is unparseable "
                                            "(no closing '---')"})
                unparseable = True
            else:
                findings.append({"file": rel, "severity": "error",
                                 "message": "missing YAML frontmatter (no leading '---' block)"})
            continue

        data, _ = parse_frontmatter(fm_str)
        if data is None:
            findings.append({"file": rel, "severity": "error",
                             "message": "frontmatter present but not parseable as YAML"})
            unparseable = True
            continue

        type_val = data.get("type")
        if type_val is None or (isinstance(type_val, str) and type_val.strip() == ""):
            findings.append({"file": rel, "severity": "error",
                             "message": "frontmatter missing non-empty `type` field"})
            continue

        # Soft INFO: note missing recommended fields (never a hard failure).
        missing = [k for k in RECOMMENDED if k not in data]
        if missing:
            findings.append({"file": rel, "severity": "info",
                             "message": "missing recommended fields: " + ", ".join(missing)})

    errors = [f for f in findings if f["severity"] == "error"]
    warnings = [f for f in findings if f["severity"] == "warning"]
    infos = [f for f in findings if f["severity"] == "info"]

    # Determine exit code.
    if unparseable:
        exit_code = 4
    elif errors:
        exit_code = 10
    elif args.strict and warnings:
        exit_code = 10
    else:
        exit_code = 0

    conformant = (exit_code == 0)

    meta = {
        "schema": SCHEMA,
        "bundle": str(root),
        "okf_version": okf_version,
        "md_total": md_total,
        "concept_total": concept_total,
        "errors": len(errors),
        "warnings": len(warnings),
        "infos": len(infos),
        "conformant": conformant,
        "yaml_parser": "PyYAML" if _HAVE_YAML else "fallback",
        "strict": args.strict,
    }

    # Human verdict to stderr.
    log("")
    log(f"  markdown files scanned : {md_total}")
    log(f"  concept documents      : {concept_total}")
    log(f"  errors                 : {len(errors)}")
    log(f"  warnings               : {len(warnings)}")
    log(f"  info                   : {len(infos)}")
    if okf_version:
        log(f"  declared okf_version   : {okf_version}")
    if exit_code == 0:
        log("  verdict                : CONFORMANT")
    elif exit_code == 4:
        log("  verdict                : INVALID (unparseable frontmatter present)")
    else:
        log("  verdict                : NON-CONFORMANT")

    # Data product.
    if args.json:
        print(json.dumps({"data": findings, "meta": meta}, ensure_ascii=False))
    else:
        # TSV: file<TAB>severity<TAB>message  (data only, no header line on stdout)
        for f in findings:
            print(f"{f['file']}\t{f['severity']}\t{f['message']}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
