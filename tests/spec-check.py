"""claude-mods :: tests/spec-check.py - the Agent Skills spec gate (run via tests/spec.sh).

WHAT THIS ENFORCES
  Every skills/*/SKILL.md must pass the Agent Skills spec's own reference validator,
  skills-ref (https://github.com/agentskills/agentskills/tree/main/skills-ref), with
  exactly one documented deviation: Claude Code's own frontmatter fields
  (CLAUDE_CODE_FIELDS) are allowed at the top level. The policy and the trade-off
  behind it live in docs/SKILL-SUBAGENT-REFERENCE.md.

WHY IT CALLS THE LIBRARY, NOT THE `skills-ref validate` CLI
  The CLI rejects every key outside the spec's six. This repo targets Claude Code,
  which reads its own fields ONLY at the top level - moving them under `metadata`
  silently disables them. So this script calls the same functions the CLI calls
  (parse_frontmatter, then validate_metadata) and removes only CLAUDE_CODE_FIELDS in
  between. No spec rule is reimplemented here, and a misspelt field such as
  `when-to-use` is still rejected, because it is not on the list.

SUPPLEMENTS (clearly not skills-ref rules)
  - metadata values must be strings. This IS a spec rule, but skills-ref 0.1.1 cannot
    see it: its parser stringifies every metadata value, so a block list passes as the
    text "['a', 'b']".
  - size WARN when a body exceeds ~5,000 tokens (chars / 3.6). After auto-compaction
    Claude Code keeps only the first 5,000 tokens of each invoked skill, so a longer
    skill silently loses its tail. Warn only - it never fails the gate.
  - docs sync: every CLAUDE_CODE_FIELDS entry must have a row in the field table in
    docs/SKILL-SUBAGENT-REFERENCE.md, so the doc and the gate cannot drift apart.

SELF-TEST FIRST
  Each tests/fixtures/spec/<case>/ is checked before the real scan. A case with an
  expect.txt must fail with that substring among its findings; a case without one must
  pass. A gate that passes everything is broken, so either violation fails the run.

Usage: python tests/spec-check.py <repo-root>    (normally via: bash tests/spec.sh)
Exit:  0 clean (size warnings allowed), 10 findings or self-test failure, 2 usage
"""

import importlib.metadata
import sys
from pathlib import Path

import strictyaml
from skills_ref.errors import ParseError
from skills_ref.parser import find_skill_md, parse_frontmatter
from skills_ref.validator import validate_metadata

# Claude Code's documented SKILL.md fields that are NOT in the Agent Skills spec.
# Source: https://code.claude.com/docs/en/skills, frontmatter table (verified 2026-10-05).
# Every one is read ONLY at the top level. Keep this set in step with that table - and
# with the table in docs/SKILL-SUBAGENT-REFERENCE.md, which check_docs_sync() enforces.
CLAUDE_CODE_FIELDS = frozenset({
    "when_to_use",
    "argument-hint",
    "arguments",
    "disable-model-invocation",
    "user-invocable",
    "disallowed-tools",
    "model",
    "effort",
    "context",
    "agent",
    "background",
    "hooks",
    "paths",
    "shell",
})

TOKEN_WARN = 5000       # Claude Code's per-skill re-attach budget after compaction
CHARS_PER_TOKEN = 3.6   # rough English-prose estimate; a warning threshold, not a count

REFERENCE_DOC = Path("docs/SKILL-SUBAGENT-REFERENCE.md")
FIXTURES = Path("tests/fixtures/spec")

EXIT_FINDINGS = 10


def metadata_string_errors(content: str) -> list[str]:
    """Spec rule skills-ref cannot see: metadata maps string keys to string values.

    Re-parses with strictyaml (skills-ref's own parser) and the same `---` split
    parse_frontmatter uses, because parse_frontmatter has already stringified the values.
    """
    raw = strictyaml.load(content.split("---", 2)[1]).data
    if "metadata" not in raw:
        return []
    metadata = raw["metadata"]
    if not isinstance(metadata, dict):
        return ["Field 'metadata' must be a map of string keys to string values"]
    bad = sorted(key for key, value in metadata.items() if not isinstance(value, str))
    if bad:
        return [
            f"metadata values must be strings, not lists or maps: {', '.join(bad)} "
            "(write a comma-separated string)"
        ]
    return []


def check(skill_dir: Path) -> tuple[list[str], list[str], set[str]]:
    """Validate one skill directory. Returns (errors, warnings, claude_code_fields_used)."""
    skill_md = find_skill_md(skill_dir)
    if skill_md is None:
        return ["Missing required file: SKILL.md"], [], set()

    # Same read as skills_ref.validator.validate() in the 0.1.1 wheel: utf-8, and a
    # BOM is NOT stripped, so a BOM-prefixed file fails here exactly as it does there.
    content = skill_md.read_text(encoding="utf-8")
    try:
        metadata, body = parse_frontmatter(content)
    except ParseError as error:
        return [str(error)], [], set()

    used = CLAUDE_CODE_FIELDS & metadata.keys()
    for field in used:
        del metadata[field]

    errors = validate_metadata(metadata, skill_dir)
    errors += metadata_string_errors(content)

    warnings = []
    est_tokens = len(body) / CHARS_PER_TOKEN
    if est_tokens > TOKEN_WARN:
        warnings.append(
            f"body is ~{est_tokens:,.0f} tokens (> {TOKEN_WARN:,}); after compaction "
            f"Claude Code keeps only the first {TOKEN_WARN:,}, so the tail drops"
        )
    return errors, warnings, used


def self_test(root: Path) -> list[str]:
    """Prove the gate can fail before trusting a clean scan."""
    fixtures = root / FIXTURES
    cases = sorted(p for p in fixtures.iterdir() if p.is_dir()) if fixtures.is_dir() else []
    failing = [c for c in cases if (c / "expect.txt").is_file()]
    passing = [c for c in cases if not (c / "expect.txt").is_file()]
    if not failing or not passing:
        return [f"{FIXTURES.as_posix()} needs at least one failing and one passing case"]

    problems = []
    for case in cases:
        errors, _, _ = check(case)
        expect = case / "expect.txt"
        if expect.is_file():
            needle = expect.read_text(encoding="utf-8").strip()
            if not any(needle in error for error in errors):
                problems.append(
                    f"{case.name}: expected a finding containing {needle!r}, got {errors or 'none'}"
                )
        elif errors:
            problems.append(f"{case.name}: expected to pass, got {errors}")
    return problems


def check_docs_sync(root: Path) -> list[str]:
    text = (root / REFERENCE_DOC).read_text(encoding="utf-8")
    missing = sorted(f for f in CLAUDE_CODE_FIELDS if f"| `{f}` |" not in text)
    if missing:
        return [
            f"{REFERENCE_DOC.as_posix()} has no table row for Claude Code field(s): "
            f"{', '.join(missing)} - the doc and this gate must list the same fields"
        ]
    return []


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: python tests/spec-check.py <repo-root>", file=sys.stderr)
        return 2
    root = Path(argv[1])
    version = importlib.metadata.version("skills-ref")
    print(f"=== Agent Skills spec (skills-ref {version}) + Claude Code fields ===")

    failures = 0
    problems = self_test(root)
    for problem in problems:
        print(f"FAIL: self-test {problem}")
    failures += len(problems)
    if not problems:
        print(f"PASS: self-test - every case under {FIXTURES.as_posix()} behaved as expected")

    for problem in check_docs_sync(root):
        print(f"FAIL: {problem}")
        failures += 1

    skills = sorted(
        p for p in (root / "skills").iterdir() if p.is_dir() and not p.name.startswith("_")
    )
    if not skills:
        print("FAIL: found zero skills under skills/ - broken path, not a pass")
        return EXIT_FINDINGS

    warned, claude_code_only = 0, []
    for skill in skills:
        errors, warnings, used = check(skill)
        for error in errors:
            print(f"FAIL: skills/{skill.name} - {error}")
            if error.startswith("Unexpected fields"):
                print(
                    "      (claude-mods also allows Claude Code's documented fields - see "
                    f"{REFERENCE_DOC.as_posix()}; anything else is a typo or belongs under metadata)"
                )
        failures += len(errors)
        for warning in warnings:
            print(f"WARN: skills/{skill.name} - {warning}")
        warned += len(warnings)
        if used:
            claude_code_only.append(skill.name)

    if claude_code_only:
        print(
            f"INFO: {len(claude_code_only)} of {len(skills)} skills use Claude Code fields, so "
            "claude.ai uploads and the Skills API would reject them as-is: "
            + ", ".join(claude_code_only)
        )
    print(f"Results: {len(skills)} skills, {failures} failed, {warned} size warnings")
    return EXIT_FINDINGS if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
