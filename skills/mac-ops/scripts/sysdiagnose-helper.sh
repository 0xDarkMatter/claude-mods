#!/usr/bin/env bash
# mac-ops :: sysdiagnose-helper.sh
# Run Apple's sysdiagnose tool, inspect its output, and prepare a sanitized
# version for sharing.
#
# sysdiagnose captures the WORKS — unified log dumps, system_profiler, kext
# inventory, process listings, network state, IOReg, accessibility config,
# spindump, etc. The output is huge (often 500MB-2GB compressed) and contains
# personal data, hostnames, paths under /Users/, network info. Don't share
# without inspection.

set -u

ACTION="run"

# Saved because the loop below shifts $@ empty; restored after it so the
# standard flags still reach parse_common_flags and maybe_filter_self.
SAVED_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --inspect) ACTION="inspect"; shift ;;
        --inspect=*) ACTION="inspect"; BUNDLE="${1#--inspect=}"; shift ;;
        --list) ACTION="list"; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

  (no args)            Trigger sysdiagnose; report where the bundle is written
  --list               List existing sysdiagnose bundles on this machine
  --inspect[=PATH]     Inspect a bundle and report what it contains
  --json, --redact, --quiet, --verbose

Apple's sysdiagnose:
  Bundle location: /var/tmp/sysdiagnose_*.tar.gz
  Trigger via:
    sudo sysdiagnose                   CLI, prompts for trigger
    Option-Cmd-Ctrl-Shift-.            Keyboard chord (system-wide)

What's in a sysdiagnose bundle (high level):
  - Full unified log dump (last few hours / days)
  - system_profiler full report
  - kextstat / kext info
  - Process listing + memory usage
  - Network state (ifconfig, netstat, route, scutil)
  - pmset state and log
  - DiskUtil and APFS state
  - DiagnosticReports/ (crashes + panics)
  - Spindump (samples of running processes)
  - IORegistry dump
  - Configuration profiles

Privacy: bundles contain hostnames, usernames, paths under /Users/, IP
addresses, sometimes app-specific identifiers. Inspect before sharing.
EOF
            exit 0 ;;
        *) shift ;;
    esac
done
# Without this restore every standard flag was silently ignored (--redact
# output meant for sharing went out unredacted). ${a[@]+...} is the bash
# 3.2-safe expansion of a possibly empty array under set -u.
set -- ${SAVED_ARGS[@]+"${SAVED_ARGS[@]}"}

source "$(dirname "$0")/_lib/common.sh"
parse_common_flags "$@"
maybe_filter_self "$@"

case "$ACTION" in
    list)
        section "1. EXISTING SYSDIAGNOSE BUNDLES"
        bundles=$(ls -lt /var/tmp/sysdiagnose_*.tar.gz 2>/dev/null | head -10)
        if [[ -z "$bundles" ]]; then
            log_info "Sysdiagnose bundles" "none found in /var/tmp"
        else
            count=$(echo "$bundles" | wc -l | tr -d ' ')
            log_info "Sysdiagnose bundles" "$count found"
            echo "$bundles" | sed 's/^/  /'
        fi
        ;;

    inspect)
        section "1. BUNDLE INSPECTION"
        BUNDLE="${BUNDLE:-$(ls -t /var/tmp/sysdiagnose_*.tar.gz 2>/dev/null | head -1)}"
        if [[ -z "$BUNDLE" ]] || [[ ! -f "$BUNDLE" ]]; then
            log_fail "Bundle" "not found: $BUNDLE"
            exit 3
        fi
        log_pass "Bundle" "$BUNDLE"
        size=$(ls -lh "$BUNDLE" 2>/dev/null | awk '{print $5}')
        note "  Size: $size"

        # Probe contents without extracting
        note ""
        note "  Top-level contents:"
        tar tzf "$BUNDLE" 2>/dev/null | awk -F/ '{print $1"/"$2}' | sort -u | head -20 | sed 's/^/    /'

        # Sensitive contents inventory
        note ""
        note "  Potentially sensitive contents:"
        for pattern in "logarchive" "DiagnosticReports" "system_profiler" "ifconfig" "scutil" "profiles" "TCC"; do
            count=$(tar tzf "$BUNDLE" 2>/dev/null | grep -c "$pattern" || echo 0)
            count="${count:-0}"
            if [[ "$count" -gt 0 ]]; then
                printf "    %-25s %s files\n" "$pattern" "$count"
            fi
        done

        note ""
        note "  Before sharing this bundle:"
        note "    1. Extract: tar xzf $BUNDLE -C /tmp/inspect"
        note "    2. Review: less /tmp/inspect/sysdiagnose_*/system_profiler.spx"
        note "    3. Search for sensitive content: grep -r 'private-data-pattern' /tmp/inspect"
        note "    4. If sharing publicly: use redaction tools (BBEdit, sed) on extracted log files first"
        ;;

    run)
        section "1. PRECONDITION CHECK"
        # sysdiagnose needs sudo
        if ! sudo -n true 2>/dev/null; then
            log_warn "sudo" "this script needs sudo to invoke sysdiagnose"
            note "  Run with: sudo bash $0"
            note "  Or trigger via keyboard chord: Option-Cmd-Ctrl-Shift-."
            note "  Or: sudo sysdiagnose -f /tmp/   (saves to /tmp instead of /var/tmp)"
            emit_summary
            exit 5
        fi

        log_pass "sudo" "available"

        # Free space check
        free_mb=$(df -m /var/tmp 2>/dev/null | awk 'NR==2{print $4}')
        if [[ "${free_mb:-0}" -lt 2048 ]]; then
            log_warn "Free space on /var/tmp" "${free_mb} MB — sysdiagnose may need 1-2 GB"
        else
            log_pass "Free space on /var/tmp" "${free_mb} MB"
        fi

        section "2. RUNNING SYSDIAGNOSE"
        note "  This takes 5-15 minutes and produces a large bundle in /var/tmp."
        note "  Skipping the privacy prompt with -u (no UI) and not generating a profile (-Q):"
        note ""
        sudo sysdiagnose -u -Q -A "macops-helper" 2>&1 | tail -10 | sed 's/^/    /'

        bundle=$(ls -t /var/tmp/sysdiagnose_*.tar.gz 2>/dev/null | head -1)
        if [[ -n "$bundle" ]] && [[ -f "$bundle" ]]; then
            log_pass "Bundle written" "$bundle"
            size=$(ls -lh "$bundle" | awk '{print $5}')
            note "  Size: $size"
            note ""
            note "  Next:"
            note "    bash $0 --inspect           # see what's in the bundle"
            note "    bash $0 --list              # all bundles on this machine"
            note "  To share with Apple support, upload directly via Apple Feedback Assistant."
        else
            log_warn "Bundle" "not found after sysdiagnose ran"
        fi
        ;;
esac

emit_summary
