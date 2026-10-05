#!/usr/bin/env bash
# claude-mods :: tests/spec.sh
#
# WHY THIS EXISTS
#   Skill frontmatter must follow the Agent Skills spec (https://agentskills.io/specification),
#   and the gate must be the spec's OWN reference validator, skills-ref - not a
#   hand-rolled allowlist (an earlier awk allowlist and a "claude plugin validate" claim
#   both looked authoritative; plugin validate does not read SKILL.md frontmatter at all).
#   The one deliberate deviation - Claude Code's own fields allowed at the top level - is
#   applied in tests/spec-check.py, which also explains why. Policy:
#   docs/SKILL-SUBAGENT-REFERENCE.md.
#
# PINS (rules/supply-chain.md: exact versions, all past a 7-day cooldown)
#   skills-ref 0.1.1 - PyPI 2026-01-10, wheel sha256
#     d35db5bb8de71ae301daf5ca9cb71f8a555e8c6f83a6d40e46a5bc09f8f461b5. Its code matches
#     agentskills/agentskills main apart from read_text(encoding='utf-8') and the version
#     string (verified 2026-10-05). The direct deps are pinned below, and
#     --exclude-newer freezes every transitive dep at a fixed date, so nothing
#     published after that date can reach this gate. Bump the whole set together, deliberately, then re-run this gate:
#     its fixture self-test shows whether the new validator still behaves.
#
# FAILURE MODES THIS GATE REFUSES TO HIDE
#   - No uv, or the pinned validator can't be fetched (offline): FAIL with a fix hint,
#     never a silent skip.
#   - A validator that passes everything: spec-check.py's fixture self-test
#     (tests/fixtures/spec/) fails first.
#   - Zero skills found: FAIL, not a vacuous pass.
#
# Usage:  bash tests/spec.sh
# Exit :  0 clean (size warnings allowed), 1 spec violation or the gate could not run

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SKILLS_REF_VERSION="0.1.1"
EXCLUDE_NEWER="2026-09-28T00:00:00Z"

if ! command -v uv >/dev/null 2>&1; then
    echo "FAIL: uv not found - the spec gate runs skills-ref through uv (https://docs.astral.sh/uv/)"
    exit 1
fi

uv run --quiet --no-project --exclude-newer "$EXCLUDE_NEWER" \
    --with "skills-ref==$SKILLS_REF_VERSION" \
    --with "strictyaml==1.7.3" \
    --with "click==8.5.0" \
    python "$SCRIPT_DIR/spec-check.py" "$PROJECT_DIR"
rc=$?

case "$rc" in
    0)  exit 0 ;;
    10) exit 1 ;;
    *)  echo "FAIL: could not run skills-ref $SKILLS_REF_VERSION through uv (exit $rc) - offline, or uv too old for --exclude-newer?"
        exit 1 ;;
esac
