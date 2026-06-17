#!/usr/bin/env bash
# net-ops :: tests/run.sh
# Lightweight self-tests. Run from the repo root:
#   bash skills/net-ops/tests/run.sh
#
# These verify structural and output invariants of the probe scripts WITHOUT
# trying to simulate broken network state. They catch regressions in:
#  - bash syntax / unbound vars / set -u trips
#  - section labels and ordering
#  - --redact actually masking private addrs / tailnet names
#  - --json producing parseable NDJSON
#  - summary block format
#  - dispatcher routing to the right per-OS script

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

assert() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS+1))
        printf "  [PASS] %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name")
        printf "  [FAIL] %s\n" "$name"
    fi
}

contains() { local hay="$1" needle="$2"; [[ "$hay" == *"$needle"* ]]; }
not_contains() { local hay="$1" needle="$2"; [[ "$hay" != *"$needle"* ]]; }

# Locate skill root regardless of invocation dir
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

echo "=== net-ops self-tests ==="
echo "Root: $root"

# ---------------------------------------------------------------------------
echo
echo "--- terminal design system (term.sh panel adoption) ---"
# ---------------------------------------------------------------------------
# OS-independent: drives _lib/output.sh directly (no live probe), so it runs on
# every platform including Windows where the probe ladder is skipped below.
OUTLIB="$root/scripts/_lib/output.sh"
TERMLIB="$root/../_lib/term.sh"

assert "output.sh sources shared term.sh" contains "$(cat "$OUTLIB")" '_lib/term.sh'
assert "probe scripts set a PANEL_TITLE" \
    bash -c 'grep -q "PANEL_TITLE=" "$1"' _ "$root/scripts/linux/probe.sh"

# Exercise the public output API in one of the three modes.
_drive() {
    bash -c '
        OUT="$1"; shift
        . "$OUT"
        PANEL_TITLE="linux probe"
        parse_output_flags "$@"
        section "1. LINK LAYER"; pass "iface up" "eth0"; fail "carrier" "no link"
        emit_summary
    ' _ "$OUTLIB" "$@"
}

# Panel path (FORCE_COLOR forces the render): the enclosing frame appears and is
# pure ASCII under TERM_ASCII=1.
panel_ascii="$(TERM_ASCII=1 FORCE_COLOR=1 _drive 2>/dev/null)"
assert "panel renders the enclosing frame" contains "$panel_ascii" "+-- "
assert "panel footer carries a health indicator" contains "$panel_ascii" "fail"
assert "panel is pure ASCII under TERM_ASCII=1" \
    bash -c '! printf "%s" "$1" | LC_ALL=C grep -q "[^[:print:][:cntrl:]]"' _ "$panel_ascii"

# Legacy text path (piped / non-TTY): the greppable [PASS]/[FAIL]/SUMMARY contract
# is byte-stable, so humans, LLMs, tests, and the --watch dispatcher keep working.
legacy="$(_drive 2>/dev/null)"
assert "piped text keeps [PASS] anchor" contains "$legacy" "[PASS]"
assert "piped text keeps [FAIL] anchor" contains "$legacy" "[FAIL]"
assert "piped text keeps SUMMARY block" contains "$legacy" "=== SUMMARY ==="
assert "piped text carries no ANSI" not_contains "$legacy" $'\033'

# JSON unaffected by the panel.
js="$(_drive --json 2>/dev/null)"
assert "json mode still emits a summary record" contains "$js" '"type":"summary"'
assert "json mode carries no panel chrome" not_contains "$js" "+-- "

# term.sh primitives are pure ASCII under TERM_ASCII=1.
if [[ -f "$TERMLIB" ]]; then
    prim="$(TERM_ASCII=1 LT="$TERMLIB" bash -c '. "$LT"; term_init; printf "%s%s%s%s" \
        "$(term_mark ok)" "$(term_status_row ok a b)" "$(term_panel_open net-ops x)" "$TERM_DOT"')"
    assert "term.sh primitives pure ASCII under TERM_ASCII=1" \
        bash -c '! printf "%s" "$1" | LC_ALL=C grep -q "[^[:print:][:cntrl:]]"' _ "$prim"
fi

# Determine the local OS probe for testing
case "$(uname -s)" in
    Darwin) probe="$root/scripts/macos/probe.sh"; audit="$root/scripts/macos/dns-audit.sh" ;;
    Linux)  probe="$root/scripts/linux/probe.sh"; audit="$root/scripts/linux/dns-audit.sh" ;;
    *) echo "Skipping: unsupported OS for local probe tests." ; exit 0 ;;
esac

# ---------------------------------------------------------------------------
echo
echo "--- Probe structural tests ---"
# ---------------------------------------------------------------------------

out=$(bash "$probe" 2>&1)

assert "probe runs without bash error" \
    not_contains "$out" "syntax error"
assert "probe runs without unbound variable error" \
    not_contains "$out" "unbound variable"
assert "probe emits summary block" \
    contains "$out" "=== SUMMARY ==="
assert "probe emits PASS/FAIL counts" \
    contains "$out" "PASS:"
check_all_sections() {
    local out="$1"
    for s in "1. LINK LAYER" "2. IP / ICMP" "3. TCP/UDP SOCKET" "4. DNS INFRASTRUCTURE" "6. APPLICATION" "7. KNOWN VPN"; do
        contains "$out" "=== $s" || return 1
    done
    # Section 5 has OS-specific naming; match on the common anchor.
    contains "$out" "(the hook layer)" || return 1
    return 0
}
assert "probe contains all 7 sections" check_all_sections "$out"

# ---------------------------------------------------------------------------
echo
echo "--- --redact tests ---"
# ---------------------------------------------------------------------------

redacted=$(bash "$probe" --redact 2>&1)

# Common private patterns that should NEVER appear in redacted output.
# (We use specific octets that are unlikely to appear in unrelated contexts.)
assert "--redact masks 192.168.x.x" \
    bash -c '! grep -E "\b192\.168\.[0-9]+\.[0-9]+\b" <<< "$0" | grep -v "192.168.X.X" >/dev/null' "$redacted"
assert "--redact masks .ts.net tailnet names" \
    bash -c '! grep -E "\b[a-z0-9-]+\.ts\.net\b" <<< "$0" | grep -v "REDACTED.ts.net" >/dev/null' "$redacted"
assert "--redact preserves 100.100.100.100 anchor" \
    bash -c '[[ "$0" != *"100.X.X.X"* ]] || grep -q "100.100.100.100" <<< "$0"' "$redacted"
assert "--redact preserves 1.1.1.1 public anchor" \
    contains "$redacted" "1.1.1.1"

# ---------------------------------------------------------------------------
echo
echo "--- --json tests ---"
# ---------------------------------------------------------------------------

json_out=$(bash "$probe" --json 2>&1)

assert "--json emits at least one section record" \
    contains "$json_out" '"type":"section"'
assert "--json emits at least one check record" \
    contains "$json_out" '"type":"check"'
assert "--json emits a summary record" \
    contains "$json_out" '"type":"summary"'
assert "--json summary contains pass count" \
    bash -c 'grep -q "\"type\":\"summary\".*\"pass\":[0-9]" <<< "$0"' "$json_out"

# ---------------------------------------------------------------------------
echo
echo "--- Dispatcher test ---"
# ---------------------------------------------------------------------------

disp_out=$("$root/scripts/probe" 2>&1 | tail -5)
assert "dispatcher routes to per-OS probe (summary present)" \
    contains "$disp_out" "PASS:"

# ---------------------------------------------------------------------------
echo
echo "--- dns-audit smoke test ---"
# ---------------------------------------------------------------------------

audit_out=$(bash "$audit" 2>&1)
assert "dns-audit runs without error" \
    not_contains "$audit_out" "syntax error"
assert "dns-audit emits attribution hints section" \
    contains "$audit_out" "ATTRIBUTION HINTS"

# ---------------------------------------------------------------------------
echo
echo "--- Edge cases ---"
# ---------------------------------------------------------------------------

# --json should emit ONLY JSON (no chatter leaking through)
json_pure=$(bash "$probe" --json 2>&1)
non_json=$(echo "$json_pure" | grep -vc '^{')
assert "--json produces pure NDJSON (no non-JSON chatter)" \
    bash -c '[[ "$0" -eq 0 ]]' "$non_json"

# --json + --redact: redacted private addrs AND only JSON
combo=$(bash "$probe" --json --redact 2>&1)
combo_non_json=$(echo "$combo" | grep -vc '^{')
combo_leaks=$(echo "$combo" | grep -E "\b192\.168\.[0-9]+\.[0-9]+\b" | grep -v "192.168.X.X")
assert "--json + --redact produces pure NDJSON" \
    bash -c '[[ "$0" -eq 0 ]]' "$combo_non_json"
assert "--json + --redact has no private-IP leaks" \
    bash -c '[[ -z "$0" ]]' "$combo_leaks"

# Unknown flag should not crash
assert "unknown --frobnicate flag does not crash" \
    bash -c 'bash "$0" --frobnicate 2>&1 | grep -q "PASS\\|FAIL"' "$probe"

# Help flag prints usage and exits cleanly
help_out=$(bash "$probe" --help 2>&1)
assert "--help mentions --redact" \
    contains "$help_out" "--redact"
assert "--help mentions --json" \
    contains "$help_out" "--json"
assert "--help mentions --quick" \
    contains "$help_out" "--quick"

# Dispatcher works from a different cwd
disp_remote=$(cd /tmp && "$root/scripts/probe" 2>&1 | tail -5)
assert "dispatcher works from /tmp (cwd-independent)" \
    contains "$disp_remote" "PASS:"

# ---------------------------------------------------------------------------
echo
echo "=== TOTAL: $PASS pass, $FAIL fail ==="
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
exit 0
