# claude-mods root justfile — `just check` is THE gate (rules/agentic-quality.md:
# "every repo has one check entry point; if it isn't one command, agents won't
# run it"). Task recipes beyond the gate live in tests/justfile.

# Default: list available tasks
default:
    @just --list

# THE gate: frontmatter/naming + Agent Skills spec + doc-drift + agnostic + hook contracts + resource contracts + skill size (warn) + reference contents (warn) + skill suites + e2e suites
check:
    @bash tests/validate.sh
    @bash tests/spec.sh
    @bash tests/doc-drift.sh
    @bash tests/agnostic.sh
    @bash tests/hooks.sh
    @bash tests/check-resources.sh
    @bash tests/skill-size.sh
    @bash tests/reference-contents.sh
    @bash tests/run-skill-tests.sh

# Fast gate: everything except the behavioural suites (per-skill and e2e)
check-fast:
    @bash tests/validate.sh
    @bash tests/spec.sh
    @bash tests/doc-drift.sh
    @bash tests/agnostic.sh
    @bash tests/hooks.sh
    @bash tests/check-resources.sh
    @bash tests/skill-size.sh
    @bash tests/reference-contents.sh

# Everything in tests/justfile is reachable from root too
test:
    @just --justfile tests/justfile test
