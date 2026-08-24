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

# ---------------------------------------------------------------------------
echo
echo "--- smb-audit.ps1 structural tests (OS-independent, static) ---"
# ---------------------------------------------------------------------------
# Windows-only at runtime, so on mac/linux we assert the contract statically:
# comment-block help, -Json mode, semantic exit codes, and the guard rails
# the SKILL text promises (live-VPN vs orphan distinction, credential check).
SMB="$root/scripts/windows/smb-audit.ps1"
smb_src="$(cat "$SMB")"
assert "smb-audit has comment-based help with EXAMPLEs" \
    bash -c 'grep -q "^\.SYNOPSIS" <<<"$0" && grep -qc "^\.EXAMPLE" <<<"$0"' "$smb_src"
assert "smb-audit documents exit codes incl. domain signal 10" \
    bash -c 'grep -q "10 audit ran and found" <<<"$0"' "$smb_src"
assert "smb-audit ships -Json with schema id" \
    contains "$smb_src" 'claude-mods.net-ops.smb-audit/v1'
assert "smb-audit checks EFFECTIVE NRPT policy" \
    contains "$smb_src" 'Get-DnsClientNrptPolicy -Effective'
assert "smb-audit distinguishes live VPN from orphan rule" \
    contains "$smb_src" 'ORPHANED'
assert "smb-audit inspects credential targets via cmdkey" \
    contains "$smb_src" 'cmdkey /list'
assert "smb-audit probes TCP/445" \
    contains "$smb_src" '445'
assert "smb-audit warns about misleading Resolve-DnsName single-label error" \
    contains "$smb_src" 'volume label syntax'

# ---------------------------------------------------------------------------
echo
echo "--- nextdns-audit.ps1 / nextdns-boot-fix.ps1 structural tests (OS-independent) ---"
# ---------------------------------------------------------------------------
# Windows-only at runtime. Statically assert the contract AND the load-bearing
# doctrine, because the whole value of these two scripts is that they stop the
# next reader chasing the two false leads that cost the original investigation
# an hour each: adapter DNS, and port-53 ownership.
NDA="$root/scripts/windows/nextdns-audit.ps1"
NDF="$root/scripts/windows/nextdns-boot-fix.ps1"
assert "nextdns-audit exists"    test -f "$NDA"
assert "nextdns-boot-fix exists" test -f "$NDF"
nda_src="$(cat "$NDA")"
ndf_src="$(cat "$NDF")"

assert "nextdns-audit has comment-based help with EXAMPLEs" \
    bash -c 'grep -q "^\.SYNOPSIS" <<<"$0" && grep -q "^\.EXAMPLE" <<<"$0"' "$nda_src"
assert "nextdns-audit documents exit codes incl. domain signal 10" \
    bash -c 'grep -q "10 audit ran and found" <<<"$0"' "$nda_src"
assert "nextdns-audit ships -Json with schema id" \
    contains "$nda_src" 'claude-mods.net-ops.nextdns-audit/v1'
assert "nextdns-audit uses test.nextdns.io as ground truth (not adapter config)" \
    contains "$nda_src" 'test.nextdns.io'
assert "nextdns-audit keys the verdict on clientName" \
    contains "$nda_src" 'nextdns-windows'
assert "nextdns-audit labels adapter DNS a red herring" \
    contains "$nda_src" 'RED HERRING'
assert "nextdns-audit states NextDNS never binds port 53" \
    contains "$nda_src" 'never binds 53'
assert "nextdns-audit inspects the per-user config scope" \
    contains "$nda_src" 'user.config'
assert "nextdns-audit checks for absent machine-wide config" \
    contains "$nda_src" 'HKLM:\SOFTWARE\NextDNS'
assert "nextdns-audit measures the boot->logon exposure window" \
    contains "$nda_src" 'exposureWindowSec'
assert "nextdns-audit warns that DelayedAutostart is the wrong lever" \
    contains "$nda_src" 'LENGTHENS'
assert "nextdns-audit offers -SkipNetwork for no-egress boxes" \
    contains "$nda_src" 'SkipNetwork'

assert "nextdns-boot-fix has comment-based help with EXAMPLEs" \
    bash -c 'grep -q "^\.SYNOPSIS" <<<"$0" && grep -q "^\.EXAMPLE" <<<"$0"' "$ndf_src"
assert "nextdns-boot-fix documents exit codes incl. pending signal 10" \
    bash -c 'grep -q "10 dry run" <<<"$0"' "$ndf_src"
assert "nextdns-boot-fix defaults to dry run (-Apply gates writes)" \
    contains "$ndf_src" 'DRY RUN'
assert "nextdns-boot-fix supports -Remove" \
    contains "$ndf_src" '$Remove'
assert "nextdns-boot-fix registers a logon-triggered task" \
    contains "$ndf_src" 'New-ScheduledTaskTrigger -AtLogOn'
assert "nextdns-boot-fix uses the correct settings cmdlet name" \
    contains "$ndf_src" 'New-ScheduledTaskSettingsSet'
assert "nextdns-boot-fix runs unelevated (LeastPrivilege / Limited)" \
    contains "$ndf_src" 'Limited'
assert "nextdns-boot-fix installs outside the repo (worktrees are disposable)" \
    contains "$ndf_src" 'LOCALAPPDATA'
assert "nextdns-boot-fix waits for interception before flushing" \
    contains "$ndf_src" 'interception confirmed'
assert "nextdns-boot-fix flushes via Clear-DnsClientCache with ipconfig fallback" \
    bash -c 'grep -q "Clear-DnsClientCache" <<<"$0" && grep -q "ipconfig /flushdns" <<<"$0"' "$ndf_src"
assert "nextdns-boot-fix records WHY delayed start is rejected" \
    contains "$ndf_src" 'WRONG DIRECTION'

# --- nextdns-doh-setup.ps1: the machine-scope alternative ---
NDD="$root/scripts/windows/nextdns-doh-setup.ps1"
assert "nextdns-doh-setup exists" test -f "$NDD"
ndd_src="$(cat "$NDD")"
assert "nextdns-doh-setup has comment-based help with EXAMPLEs" \
    bash -c 'grep -q "^\.SYNOPSIS" <<<"$0" && grep -q "^\.EXAMPLE" <<<"$0"' "$ndd_src"
assert "nextdns-doh-setup documents exit codes" \
    bash -c 'grep -q "10 dry run" <<<"$0"' "$ndd_src"
assert "nextdns-doh-setup defaults to dry run" \
    contains "$ndd_src" 'DRY RUN'
assert "nextdns-doh-setup ships a -Rollback path" \
    contains "$ndd_src" '$Rollback'
assert "nextdns-doh-setup ships a -VerifyOnly path" \
    contains "$ndd_src" '$VerifyOnly'
assert "nextdns-doh-setup refuses to apply unelevated" \
    contains "$ndd_src" 'needs an ELEVATED PowerShell'
assert "nextdns-doh-setup validates the profile id" \
    contains "$ndd_src" 'ValidatePattern'
# The single most important doctrine in the file: the IP is not the profile.
assert "nextdns-doh-setup states the anycast IP does NOT select the profile" \
    contains "$ndd_src" 'DOES NOT SELECT YOUR PROFILE'
assert "nextdns-doh-setup disables UDP fallback (silent-unfiltered guard)" \
    contains "$ndd_src" 'AllowFallbackToUdp $false'
assert "nextdns-doh-setup records that a wrong profile id fails silently" \
    contains "$ndd_src" 'FAILS SILENTLY'
assert "nextdns-doh-setup verifies via test.nextdns.io rather than trusting config" \
    contains "$ndd_src" 'test.nextdns.io'
assert "nextdns-doh-setup writes an on-disk breadcrumb for future readers" \
    contains "$ndd_src" 'README-dns-setup.md'
assert "nextdns-doh-setup handles the tray-client conflict" \
    contains "$ndd_src" 'KeepClient'
assert "nextdns-doh-setup flags the now-redundant logon flush task" \
    contains "$ndd_src" 'nextdns-boot-fix.ps1 -Remove -Apply'
assert "nextdns-doh-setup is honest that the -Apply path is unverified" \
    contains "$ndd_src" 'NOT executed by its author'
# REGRESSION GUARD (bit for real on first live -Apply, 2026-08-24): the original
# verification tested for an EMPTY clientName and so reported [FAIL] on a perfectly
# good machine-scope setup. NextDNS always returns a clientName; for the Windows
# resolver it is 'unknown-doh'. The predicate must key on "is it the tray app?",
# never on emptiness.
assert "nextdns-doh-setup knows 'unknown-doh' is the healthy machine-scope value" \
    contains "$ndd_src" 'unknown-doh'
assert "nextdns-doh-setup verification does NOT test for an empty clientName" \
    bash -c '! grep -q -- "-not \$e.clientName" <<<"$0"' "$ndd_src"
assert "nextdns-doh-setup keys verification on clientName -ne nextdns-windows" \
    contains "$ndd_src" '$e.clientName -ne ' "'nextdns-windows'"
assert "nextdns-doh-setup breadcrumb teaches the profile-pinning check, not just DOH" \
    contains "$ndd_src" 'prove the PROFILE, not just the encryption'
# --- -SetPerInterface: make the Settings GUI agree with reality ---
# Registering a template with AutoUpgrade makes DoH WORK but leaves the GUI reading
# "Off", because the GUI reads a per-interface key instead of the known-servers table.
# That mismatch is the hazard: pressing Save in that dialog can silently disable
# encryption. DohFlags=1 (QWORD) = "automatic template" - verified against a working
# public implementation, not guessed.
assert "nextdns-doh-setup offers -SetPerInterface" \
    contains "$ndd_src" '$SetPerInterface'
assert "nextdns-doh-setup writes DohFlags as a QWORD" \
    contains "$ndd_src" "-PropertyType QWord"
assert "nextdns-doh-setup uses DohFlags value 1 (automatic template)" \
    contains "$ndd_src" "-Name 'DohFlags' -Value 1"
assert "nextdns-doh-setup targets the interface-specific DoH path" \
    contains "$ndd_src" 'DohInterfaceSettings'
assert "nextdns-doh-setup handles both Doh and Doh6 families" \
    contains "$ndd_src" "'Doh','Doh6'"
assert "nextdns-doh-setup does NOT duplicate DohTemplate per-interface" \
    bash -c '! grep -q "Name .DohTemplate." <<<"$0"' "$ndd_src"
assert "nextdns-doh-setup warns when applying without -SetPerInterface" \
    contains "$ndd_src" 'Settings GUI reports DoH "Off"'
assert "nextdns-doh-setup rollback removes the per-interface key" \
    contains "$ndd_src" 'Removed per-interface DoH key'
assert "nextdns-doh-setup verification reports what the GUI will show" \
    contains "$ndd_src" 'Settings GUI will report DoH ON'

# The SKILL text and culprit catalog must carry the pattern, not just the scripts.
skill_src="$(cat "$root/SKILL.md")"
culprits_src="$(cat "$root/references/common-culprits.md")"
cases_src="$(cat "$root/references/case-studies.md")"
assert "SKILL.md documents the interception-layer adapter-DNS trap" \
    contains "$skill_src" 'Interception-Layer DNS Clients'
assert "SKILL.md lists nextdns-audit in the scripts index" \
    contains "$skill_src" 'nextdns-audit.ps1'
assert "SKILL.md lists nextdns-boot-fix in the scripts index" \
    contains "$skill_src" 'nextdns-boot-fix.ps1'
assert "SKILL.md description carries the flush-every-reboot trigger" \
    contains "$skill_src" 'flushdns needed after every reboot'
assert "common-culprits has the W4b boot-order entry" \
    contains "$culprits_src" 'W4b. NextDNS Boot-Order Profile Inheritance'
assert "common-culprits W4 no longer misattributes a 127.0.0.1:53 proxy to NextDNS" \
    contains "$culprits_src" 'NOT NextDNS (v3.x)'
assert "common-culprits records the rejected-fix table" \
    contains "$culprits_src" 'Fixes that do NOT work'
assert "case-studies has the NextDNS case with its false leads" \
    contains "$cases_src" 'The Profile That Only Existed After Logon'

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
