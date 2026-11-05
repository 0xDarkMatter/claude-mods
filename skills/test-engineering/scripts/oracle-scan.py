#!/usr/bin/env python3
"""Find tests that replicate the code's logic instead of checking it (S3, S15): advisory.

Usage:   oracle-scan.py [--repo DIR] [--src DIR]... [--tests DIR]... [--min-tokens N] [--json]
Input:   source and test trees. Defaults: tests are files under tests/, test/, __tests__/,
         spec/ or named *_test.* / *.test.* / *.spec.* / test_*.*; source is every other
         file with a known extension (.py .js .jsx .ts .tsx .mjs .cjs .php .go .rs .rb).
         vendor/, node_modules/, .git/, dist/ and build/ are skipped.
Output:  one row per finding: rule, test file:line, source file:line, the shared text.
         TSV, or --json (schema claude-mods.test-engineering.oracle-scan/v1).
Stderr:  summary, errors.
Exit:    0 nothing found, 2 usage, 3 --repo/--src/--tests not found, 10 findings.

Rules. A test that copies the code agrees with the code, bugs included: it goes red only
when the copy drifts, so it pins the implementation and protects no behaviour.
  O1 replicated expression  a test line computes the same expression as a source line
                            (after dropping the assignment target, `return`, `self.`/`this.`/
                            `$this->`, whitespace and comments). The expected value should be
                            hand-derived or from the spec: `== 107.5`, not the formula again.
  O2 shadow definition      a test file defines a function or class with the same name as a
                            top-level one in the source (S15): it may be testing its own copy.
  O3 self-oracle            one assertion line makes the same call to a source function on
                            both sides (`assert f(x) == f(x)`): it cannot fail. Differing
                            arguments (`f("A") == f("a")`) are an equivalence test, not flagged.
These are heuristics: a QUESTION for a reader or the test-review-agent, never a gate
(gate.md: static slop checks are about 13% precise). The fix is the same every time:
replace the copied logic with a literal from the requirement, and watch the test fail on
a planted mutant.

Examples:
  oracle-scan.py --repo .
  oracle-scan.py --src app --tests tests/Unit --json | jq '.data[] | .rule'
  oracle-scan.py --min-tokens 8        # stricter: only long copied expressions
"""
import argparse
import json
import os
import re
import sys

SCHEMA = "claude-mods.test-engineering.oracle-scan/v1"
EXTS = {".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".php", ".go", ".rs", ".rb"}
SKIP = {".git", "node_modules", "vendor", "dist", "build", ".venv", "venv", "__pycache__", "target", ".next"}
TEST_DIRS = {"tests", "test", "__tests__", "spec", "specs"}
TEST_NAME = re.compile(r"(^test_.*|.*_test\.\w+$|.*\.(test|spec)\.\w+$|.*Test\.php$)")
# Logic operators. Arrows (->, =>) are not logic, and strings are masked before this runs
# (a pilot matched URLs, UUIDs and header values: shared constants, not copied logic).
OPS = re.compile(r"(?<![-=])[-+*/%](?!>)|<=|>=|==|!=|(?<![-=\w])[<>](?![=>])|&&|\|\||\?\?|\band\b|\bor\b|\bnot\b")
STRINGS = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`")
SIGNATURE = re.compile(r"^(?:def |async def |function |func |fn |class |\)|\]|\})")
TOKEN = re.compile(r"[A-Za-z_$][\w$]*|\d+(?:\.\d+)?|==|!=|<=|>=|&&|\|\||\*\*|->|=>|[-+*/%<>?:()\[\].,!]")
DEF = re.compile(r"^\s*(?:export\s+)?(?:async\s+)?(?:def|function|func|fn|class|(?:public|private|protected|static|\s)*function)\s+([A-Za-z_]\w*)"
                 r"|^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_]\w*)\s*=\s*(?:async\s*)?(?:\(|function)")
ASSERT = re.compile(r"\b(assert\w*|expect|should|assertThat|require\.Equal|assert_eq!?)\b")
CALL = re.compile(r"([A-Za-z_]\w*)\s*\(")
CALLTEXT = re.compile(r"([A-Za-z_]\w*)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)")  # one nesting level
NOT_LOGIC = re.compile(r"^(import|from|use|require|include|package|namespace|#|//|/\*|\*|@)")


def err(msg):
    print(f"oracle-scan: {msg}", file=sys.stderr)


def is_test(rel):
    parts = rel.replace("\\", "/").split("/")
    return bool(TEST_DIRS & set(parts[:-1])) or bool(TEST_NAME.match(parts[-1]))


def walk(roots):
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in SKIP and not x.startswith(".")]
            for f in files:
                if os.path.splitext(f)[1] in EXTS:
                    yield os.path.join(d, f)


def strip_comment(line, ext):
    marks = ["#"] if ext in (".py", ".rb") else ["//"]
    if ext == ".php":
        marks = ["//", "#"]
    for m in marks:
        i = line.find(m)
        if i >= 0 and line[:i].count('"') % 2 == 0 and line[:i].count("'") % 2 == 0:
            line = line[:i]
    return line


def normalise(line, ext):
    """The expression a line computes, or None when the line is not logic worth comparing."""
    s = strip_comment(line, ext).strip().rstrip(";,{").strip()
    if not s or NOT_LOGIC.match(s) or ASSERT.search(s):
        return None  # assertion lines are compared side by side instead (sides())
    s = re.sub(r"^return\s+", "", s)
    # drop an assignment target: `expected = ...`, `const total = ...`, `$x = ...`, `x := ...`
    s = re.sub(r"^(?:(?:const|let|var|final|val|auto)\s+)?[\w$.\[\]'\"->]+\s*(?::[^=]+)?(?::=|=(?!=))\s*", "", s)
    s = re.sub(r"\b(self|this|cls)\.|\$this->|\$", "", s)
    return s


def sides(line, ext):
    """The operands of an assertion: `assert f(x) == <copied formula>` is the commonest copy."""
    s = strip_comment(line, ext).strip().rstrip(";")
    s = re.sub(r"^(assert\w*|expect)\s*\(?", "", s)
    s = re.sub(r"(self|this|cls)\.|\$this->|\$", "", s)
    if "==" in s or "toBe" in s or "toEqual" in s:
        parts = re.split(r"==|!=|\)\.(?:toBe|toEqual|toStrictEqual|toBeCloseTo)\(", s)
    else:  # assertEquals(expected, actual): split on the top-level comma only
        depth, cut = 0, None
        for i, ch in enumerate(s):
            depth += ch in "([{"
            depth -= ch in ")]}"
            if ch == "," and depth == 0:
                cut = i
                break
        parts = [s[:cut], s[cut + 1:]] if cut else [s]
    out = []
    for p in parts:
        p = p.strip()
        while p.endswith(")") and p.count(")") > p.count("("):  # the wrapper's paren, not the formula's
            p = p[:-1].rstrip()
        if p:
            out.append(p)
    return out


def logic(expr):
    """The expression with strings masked, when it is logic worth comparing; else None.
    Needs an operator and at least two identifiers outside strings; skips signatures."""
    if not expr or SIGNATURE.match(expr):
        return None
    masked = STRINGS.sub("S", expr)
    idents = [w for w in re.findall(r"[A-Za-z_]\w*", masked) if w not in ("S", "as", "await", "new")]
    if not OPS.search(masked) or len(idents) < 2:
        return None
    return masked


def tokens(expr):
    return TOKEN.findall(expr)


def scan(src_files, test_files, min_tokens):
    src_expr, src_defs = {}, {}
    for f in src_files:
        ext = os.path.splitext(f)[1]
        for n, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            m = DEF.match(line)
            if m:
                name = m.group(1) or m.group(2)
                # Top-level definitions only: a local helper named `body` in some function is
                # not the module's API, and matching it was the pilot's commonest false hit.
                top = not line[:1].isspace() or re.match(r"\s*(export|public|module\.exports)", line)
                if name and top and not name.startswith("_") and len(name) > 3:
                    src_defs.setdefault(name, f"{f}:{n}")
            e = logic(normalise(line, ext))
            if e:
                t = tokens(e)
                if len(t) >= min_tokens:
                    src_expr.setdefault(" ".join(t), f"{f}:{n}")
    out = []
    for f in test_files:
        ext = os.path.splitext(f)[1]
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        for n, line in enumerate(lines, 1):
            m = DEF.match(line)
            if m:
                name = m.group(1) or m.group(2)
                if name in src_defs and not name.lower().startswith("test"):
                    out.append({"rule": "O2", "test": f"{f}:{n}", "source": src_defs[name], "text": name})
            if ASSERT.search(line):
                # Same function, same arguments, both sides: a tautology. f("BASH") == f("bash")
                # is an equivalence test, not a copy, so differing arguments are not flagged.
                full = [m.group(0) for m in CALLTEXT.finditer(line) if m.group(1) in src_defs]
                dup = sorted({c.split("(")[0].strip() for c in full if full.count(c) > 1})
                if dup:
                    out.append({"rule": "O3", "test": f"{f}:{n}", "source": src_defs[dup[0]],
                                "text": line.strip()[:160]})
            exprs = sides(line, ext) if ASSERT.search(line) else [normalise(line, ext)]
            for e in exprs:
                e = logic(e)
                if e:
                    key = " ".join(tokens(e))
                    if key in src_expr:
                        out.append({"rule": "O1", "test": f"{f}:{n}", "source": src_expr[key], "text": e[:160]})
                        break
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", default=".")
    p.add_argument("--src", action="append", default=[])
    p.add_argument("--tests", action="append", default=[])
    p.add_argument("--min-tokens", type=int, default=6)
    p.add_argument("--json", action="store_true")
    a = p.parse_args()
    if a.min_tokens < 3:
        p.error("--min-tokens must be >= 3: shorter expressions match by coincidence")
    for d in [a.repo] + a.src + a.tests:
        if not os.path.isdir(d):
            err(f"not a directory: {d}")
            return 3
    if a.src or a.tests:
        src = list(walk(a.src or [a.repo]))
        tst = list(walk(a.tests)) if a.tests else [f for f in src if is_test(os.path.relpath(f, a.repo))]
        src = [f for f in src if f not in set(tst)]
    else:
        files = list(walk([a.repo]))
        tst = [f for f in files if is_test(os.path.relpath(f, a.repo))]
        src = [f for f in files if f not in set(tst)]
    out = scan(src, tst, a.min_tokens)
    rel = lambda loc: os.path.relpath(loc.rsplit(":", 1)[0], a.repo).replace("\\", "/") + ":" + loc.rsplit(":", 1)[1]
    for r in out:
        r["test"], r["source"] = rel(r["test"]), rel(r["source"])
    if a.json:
        print(json.dumps({"data": out, "meta": {"schema": SCHEMA, "source_files": len(src),
                                                "test_files": len(tst), "count": len(out)}}, indent=2))
    else:
        for r in out:
            print(f"{r['rule']}\t{r['test']}\t{r['source']}\t{r['text']}")
    err(f"{len(out)} finding(s) in {len(tst)} test files against {len(src)} source files: "
        "each is a question for a reader, not a verdict")
    return 10 if out else 0


if __name__ == "__main__":
    sys.exit(main())
