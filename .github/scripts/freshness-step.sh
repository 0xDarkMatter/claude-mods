#!/usr/bin/env bash
# Run one live staleness verifier as a freshness.yml step and turn its exit code
# into the step's result (docs/SKILL-RESOURCE-PROTOCOL.md sections 5 and 7).
#
# Why one helper: each step used to map only 10 (fail) and 7 (warn) and then end
# in a bare `exit 0`, so every OTHER code passed green with no annotation - an
# uncaught exception (1), a usage slip (2), facts missing or unparseable (3/4), a
# missing tool (5, 127). A verifier that died before comparing anything reported
# "no drift" every week while checking nothing. Keeping the mapping here makes it
# identical across steps; tests/check-resources.sh pins this contract and fails
# if a step reads `$?` itself again.
#
# Usage:   freshness-step.sh --name SKILL --drift MSG --unavailable MSG -- CMD [ARG...]
# Mapping: CMD exit 0      -> pass, no annotation
#          CMD exit 7      -> ::warning::MSG, pass (UNAVAILABLE: retry next run)
#          CMD exit 10     -> ::error::MSG, fail (confirmed drift)
#          any other exit  -> ::error::SKILL verifier crashed or was misused (exit N), fail
# Output:  stdout = CMD's own stdout, then the annotation. GitHub reads workflow
#          commands (::error:: / ::warning::) from stdout, so they go there.
# Stderr:  CMD's own stderr; this helper's usage errors.
# Exit:    0 pass, 1 fail, 2 usage (bad arguments to this helper)
#
# Examples:
#   freshness-step.sh --name hono-ops --drift "hono-ops drift - hono shipped v5" \
#     --unavailable "hono-ops live check unreachable - skipped" \
#     -- python skills/hono-ops/scripts/check-hono-facts.py --live

set -uo pipefail

# Workflow-command data escaping: a raw % or line break in MSG would truncate or
# corrupt the annotation (GitHub's escapeData: % -> %25, CR -> %0D, LF -> %0A).
esc() {
    local s="$1"
    s="${s//'%'/%25}"; s="${s//$'\r'/%0D}"; s="${s//$'\n'/%0A}"
    printf '%s' "$s"
}

usage() {
    echo "::error::freshness-step.sh: $(esc "$1")"
    echo "ERROR: $1 (try --help)" >&2
    exit 2
}

name=""; drift=""; unavailable=""; sep=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --name|--drift|--unavailable)
            [ $# -ge 2 ] || usage "$1 needs a value"
            case "$1" in
                --name) name="$2" ;; --drift) drift="$2" ;; --unavailable) unavailable="$2" ;;
            esac
            shift 2 ;;
        --) shift; sep=1; break ;;
        *) usage "unknown argument: $1" ;;
    esac
done
[ -n "$name" ] && [ -n "$drift" ] && [ -n "$unavailable" ] \
    || usage "--name, --drift and --unavailable are all required"
[ "$sep" -eq 1 ] && [ $# -gt 0 ] || usage "no verifier command after --"

rc=0
"$@" || rc=$?

case "$rc" in
    0)  exit 0 ;;
    7)  echo "::warning::$(esc "$unavailable")"; exit 0 ;;
    10) echo "::error::$(esc "$drift")"; exit 1 ;;
esac

# Name the protocol class (section 5) so the annotation says where to look.
case "$rc" in
    1)   hint="ERROR: uncategorised, e.g. an uncaught exception; see the log above" ;;
    2)   hint="USAGE: bad arguments" ;;
    3)   hint="NOT_FOUND: a facts file or input is missing" ;;
    4)   hint="VALIDATION: facts or an upstream source could not be parsed" ;;
    5)   hint="PRECONDITION: a required tool is missing on the runner" ;;
    6)   hint="TIMEOUT" ;;
    126) hint="command not executable" ;;
    127) hint="command not found" ;;
    *)   if [ "$rc" -gt 128 ]; then hint="killed by signal $((rc - 128))"; else hint=""; fi ;;
esac
echo "::error::$(esc "$name verifier crashed or was misused (exit $rc)${hint:+ - $hint}")"
exit 1
