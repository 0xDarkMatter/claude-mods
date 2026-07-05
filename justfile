# claude-mods root justfile — `just check` is THE gate (rules/agentic-quality.md:
# "every repo has one check entry point; if it isn't one command, agents won't
# run it"). Task recipes beyond the gate live in tests/justfile.

# Default: list available tasks
default:
    @just --list

# THE gate: frontmatter/naming + doc-drift + resource contracts + skill suites
check:
    @bash tests/validate.sh
    @bash tests/doc-drift.sh
    @bash tests/check-resources.sh
    @bash tests/run-skill-tests.sh

# Fast gate: everything except the per-skill behavioural suites
check-fast:
    @bash tests/validate.sh
    @bash tests/doc-drift.sh
    @bash tests/check-resources.sh

# Everything in tests/justfile is reachable from root too
test:
    @just --justfile tests/justfile test
