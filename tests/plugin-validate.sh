#!/usr/bin/env bash
# Run `claude plugin validate` on a directory, waiving ONE known error: the reserved plugin name.
#
# Usage:   tests/plugin-validate.sh <dir>        validate a plugin or marketplace directory
#          tests/plugin-validate.sh --self-test  prove the waiver logic against fixtures first
# Input:   argv only.
# Output:  stdout: one verdict line (PASS / WAIVED / FAIL). The validator's own report goes to
#          stderr when the verdict is not PASS.
# Exit:    0 pass, 3 passed only because the reserved-name error was waived, 1 fail,
#          2 usage, 5 claude CLI missing.
# Examples:
#   tests/plugin-validate.sh .
#   tests/plugin-validate.sh --self-test && tests/plugin-validate.sh .
#
# WHY THIS EXISTS (temporary): Claude Code 2.1.287 launched "Claude Mods" and reserved plugin
# names that pass as Anthropic's own, naming "claude-mods" explicitly (plugins-reference, `name`
# field). `claude plugin validate`, `init` and `tag` reject it; install and load still work.
# That turned every gate red. TODO(rename): rename the plugin, then delete this waiver and
# call `claude plugin validate` directly again. The waiver EXPIRES on WAIVER_UNTIL and fails
# after it, so the rename cannot be forgotten.
#
# WAIVER RULE: waive only when EVERY reported error is the reserved-name error for
# "claude-mods". Any other error, or any change in the CLI's message format, fails. A real
# schema error suppresses the reserved-name check entirely (verified 2.1.288), so counting
# errors and matching them all is the safe test.

set -uo pipefail

WAIVER_UNTIL="20261031"
RESERVED_RE='Plugin name "claude-mods" is reserved: it passes as one of Anthropic'

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# verdict <dir> [until]  -> echoes PASS|WAIVED|FAIL, returns 0|3|1
verdict() {
    local dir="$1" until="${2:-$WAIVER_UNTIL}" out rc errors reserved today
    out="$(claude plugin validate "$dir" 2>&1 | strip_ansi)"; rc=${PIPESTATUS[0]}
    if [[ "$rc" -eq 0 ]]; then echo "PASS"; return 0; fi
    errors="$(printf '%s\n' "$out" | sed -nE 's/.*Found ([0-9]+) errors?:.*/\1/p' | head -n 1)"
    reserved="$(printf '%s\n' "$out" | grep -cE "$RESERVED_RE" || true)"
    today="$(date +%Y%m%d)"
    if [[ -n "$errors" && "$errors" -ge 1 && "$errors" == "$reserved" ]]; then
        if [[ "$today" -le "$until" ]]; then
            echo "WAIVED"; printf '%s\n' "$out" >&2; return 3
        fi
        echo "FAIL (reserved-name waiver expired on $until: rename the plugin)"; printf '%s\n' "$out" >&2; return 1
    fi
    echo "FAIL"; printf '%s\n' "$out" >&2; return 1
}

self_test() {
    local t fails=0 got
    t="$(mktemp -d)"
    mk() { mkdir -p "$t/$1/.claude-plugin"; printf '%s' "$2" > "$t/$1/.claude-plugin/plugin.json"; }
    mk reserved '{"name":"claude-mods","version":"1.0.0","description":"x"}'
    mk mixed    '{"name":"claude-mods","version":123,"description":"x"}'
    mk clean    '{"name":"tool-kit","version":"1.0.0","description":"x"}'
    check() {  # name fixture until expected-rc
        verdict "$t/$2" "$3" >/dev/null 2>&1; got=$?
        if [[ "$got" -eq "$4" ]]; then echo "  ok   $1"; else echo "  FAIL $1 (exit $got, want $4)"; fails=$((fails+1)); fi
    }
    echo "plugin-validate self-test:"
    check "reserved name alone is waived"           reserved "$WAIVER_UNTIL" 3
    check "reserved name plus a real error fails"   mixed    "$WAIVER_UNTIL" 1
    check "a valid manifest passes"                 clean    "$WAIVER_UNTIL" 0
    check "an expired waiver fails"                 reserved "20000101"      1
    rm -rf "$t"
    [[ "$fails" -eq 0 ]]
}

command -v claude >/dev/null 2>&1 || { echo "FAIL: claude CLI not found" >&2; exit 5; }
case "${1:-}" in
    --self-test) self_test; exit $? ;;
    ""|-h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; [[ -z "${1:-}" ]] && exit 2; exit 0 ;;
    *) [[ -d "$1" ]] || { echo "FAIL: not a directory: $1" >&2; exit 2; }
       verdict "$1"; exit $? ;;
esac
