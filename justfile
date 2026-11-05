# claude-mods root justfile — `just check` is THE gate (rules/agentic-quality.md:
# "every repo has one check entry point; if it isn't one command, agents won't
# run it"). Task recipes beyond the gate live in tests/justfile.

# Default: list available tasks
default:
    @just --list

# THE gate: frontmatter/naming + Agent Skills spec + doc-drift + agnostic + skill hygiene (ratchet) + hook contracts + resource contracts + PowerShell 5.1 parse + skill size (warn) + reference contents (warn) + skill suites + e2e suites + procsub-guard mutations
check:
    @bash tests/validate.sh
    @bash tests/spec.sh
    @bash tests/doc-drift.sh
    @bash tests/agnostic.sh
    @bash tests/skill-hygiene.sh
    @bash tests/hooks.sh
    @bash tests/check-resources.sh
    @bash tests/check-ps51-parse.sh
    @bash tests/skill-size.sh
    @bash tests/reference-contents.sh
    @bash tests/run-skill-tests.sh
    @bash tests/procsub-guard.sh

# Fast gate: everything except the behavioural suites (per-skill and e2e)
check-fast:
    @bash tests/validate.sh
    @bash tests/spec.sh
    @bash tests/doc-drift.sh
    @bash tests/agnostic.sh
    @bash tests/skill-hygiene.sh
    @bash tests/hooks.sh
    @bash tests/check-resources.sh
    @bash tests/check-ps51-parse.sh
    @bash tests/skill-size.sh
    @bash tests/reference-contents.sh

# Map: tests/changed-map.tsv; shared or unmapped paths run everything; `--list` previews.
# NOT a landing gate: `just check` still runs the full sweep.
# Dev gate: only the checks covering what changed vs [base] (default main), 4 at a time
check-changed *args:
    @bash tests/check-changed.sh {{args}}

# Everything in tests/justfile is reachable from root too
test:
    @just --justfile tests/justfile test
