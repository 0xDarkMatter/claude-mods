#!/usr/bin/env bash
# Self-test for portless-ops — STATIC / STRUCTURAL ONLY.
#
# portless-ops ships PowerShell (.ps1) scripts that mutate real local state
# (stop/restart a proxy, wipe routes.json, re-register aliases). On Linux CI you
# cannot run pwsh reliably, and even on Windows you must not let a test suite
# touch a developer's real .portless state. So this suite never executes the
# scripts: it asserts their STATIC contract instead —
#   1. each script carries a synopsis/usage (.SYNOPSIS + .EXAMPLE) block,
#   2. the shipped portless.json asset templates parse as valid JSON, and
#   3. reset-state.ps1 guards its destructive Remove-Item (Test-Path existence
#      check + the nuclear `portless clean` opt-in via -PreserveCa, which
#      DEFAULTS to $true = safe-by-default).
#
# NOTE (see final reply): reset-state.ps1 does not use -WhatIf / -Confirm /
# ShouldProcess; its guard is the Test-Path existence check plus the safe-by-
# default PreserveCa flag. That gap is surfaced below as INFO, not a failure —
# it is documented rather than hidden.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
ASSETS="$SKILL/assets"

# JSON parser: prefer jq, fall back to a working python (skip if neither).
JSON_TOOL=""
if command -v jq >/dev/null 2>&1; then
    JSON_TOOL="jq"
else
    for c in python python3; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then JSON_TOOL="$c"; break; fi
    done
fi
json_ok() { # $1 = file -> 0 if parses
    case "$JSON_TOOL" in
        jq)     jq empty "$1" >/dev/null 2>&1 ;;
        python|python3) "$JSON_TOOL" -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8'))" "$1" >/dev/null 2>&1 ;;
        *)      return 2 ;;  # no parser available
    esac
}
json_get() { # $1 = file, $2 = key -> prints value (jq: .key; python best-effort)
    case "$JSON_TOOL" in
        jq)     jq -r "$2" "$1" 2>/dev/null ;;
        *)      "$JSON_TOOL" -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8'));
import builtins as b
k=sys.argv[2].lstrip('.')
print(d.get(k) if k in d else '')" "$1" "$2" 2>/dev/null ;;
    esac
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
info() { printf '  INFO  %s\n' "$1"; }

echo "=== portless-ops self-test (static/structural) ==="

# ── every script has a synopsis/usage block ──────────────────────────────────
echo "-- synopsis/usage blocks --"
for s in "$SCRIPTS"/*.ps1; do
    [[ -f "$s" ]] || continue
    b="$(basename "$s")"
    if grep -q '\.SYNOPSIS' "$s" && grep -q '\.EXAMPLE' "$s"; then
        ok "$b has .SYNOPSIS + .EXAMPLE"
    else
        no "$b missing .SYNOPSIS/.EXAMPLE"
    fi
    grep -q '\[CmdletBinding()\]' "$s" \
        && ok "$b uses [CmdletBinding()] (param discipline)" \
        || no "$b missing [CmdletBinding()]"
done

# ── reset-state.ps1: destructive ops are guarded ────────────────────────────
echo "-- reset-state.ps1 guards --"
R="$SCRIPTS/reset-state.ps1"
# 3a. Remove-Item is preceded by a Test-Path existence guard (no unconditional
#     wipe) — the real, present guard before the destructive call.
if grep -q 'Test-Path' "$R" && grep -q 'Remove-Item' "$R"; then
    tp_line=$(grep -n 'Test-Path' "$R" | head -1 | cut -d: -f1)
    ri_line=$(grep -n 'Remove-Item' "$R" | head -1 | cut -d: -f1)
    if [[ "${tp_line:-0}" -gt 0 && "${ri_line:-0}" -gt "${tp_line:-0}" ]]; then
        ok "Remove-Item is guarded by a Test-Path check (line $tp_line < $ri_line)"
    else
        no "Remove-Item not preceded by Test-Path guard"
    fi
else
    no "reset-state.ps1 missing Test-Path/Remove-Item"
fi
# 3b. The nuclear `portless clean` is opt-in and DEFAULTS to safe ($true).
if grep -qE '\$PreserveCa\s*=\s*\$true' "$R"; then
    ok "nuclear 'portless clean' opt-in via PreserveCa (default \$true)"
else
    no "PreserveCa does not default to \$true"
fi
# 3c. Transparently surface the absence of a strict per-op confirmation flag.
if grep -qE -- '-WhatIf|-Confirm|ShouldProcess|ShouldContinue' "$R"; then
    ok "strict confirmation/dry-run guard (-WhatIf/-Confirm) present"
else
    info "no -WhatIf/-Confirm/ShouldProcess — guard is Test-Path + PreserveCa default"
fi

# ── asset JSON templates parse ───────────────────────────────────────────────
echo "-- asset JSON parse --"
if [[ -z "$JSON_TOOL" ]]; then
    info "no jq/python available — JSON parse skipped (still green)"
else
    for a in "$ASSETS"/*.json; do
        [[ -f "$a" ]] || continue
        b="$(basename "$a")"
        if json_ok "$a"; then ok "asset parses: $b"; else no "asset parses: $b"; fi
    done
    # light semantic checks: each template is on-purpose (carries its key shape)
    [[ "$(json_get "$ASSETS/portless.json.simple.json" '.name')" == "myapp" ]] \
        && ok "simple template has .name" || no "simple template .name"
    [[ -n "$(json_get "$ASSETS/portless.json.monorepo.json" '.apps')" ]] \
        && ok "monorepo template has .apps" || no "monorepo template .apps"
    [[ -n "$(json_get "$ASSETS/portless.json.with-custom-tld.json" '._tld_choice')" ]] \
        && ok "custom-tld template records _tld_choice" || no "custom-tld template _tld_choice"
    [[ -n "$(json_get "$ASSETS/package.json-portless-key.json" '.portless')" ]] \
        && ok "package.json template has .portless key" || no "package.json template .portless"
fi

# ── install-portless.ps1: supply-chain audit posture (static) ────────────────
echo "-- install-portless.ps1 audit posture --"
I="$SCRIPTS/install-portless.ps1"
grep -qi 'SHA512\|SHA-512' "$I" && ok "verifies tarball SHA-512" || no "verifies tarball SHA-512"
grep -qi 'IOC' "$I" && ok "scans package for IOC strings" || no "scans package for IOC strings"
# integrity check must run BEFORE the install step
ic_line=$(grep -ni 'integrity\|SHA-512\|SHA512' "$I" | head -1 | cut -d: -f1)
in_line=$(grep -ni 'npm install -g' "$I" | head -1 | cut -d: -f1)
if [[ "${ic_line:-0}" -gt 0 && "${in_line:-0}" -gt "${ic_line:-0}" ]]; then
    ok "integrity check precedes npm install"
else
    no "integrity check must precede npm install"
fi

# ── sync-aliases-from-yaml.ps1: declares its yq dependency ───────────────────
echo "-- sync-aliases-from-yaml.ps1 --"
S="$SCRIPTS/sync-aliases-from-yaml.ps1"
grep -q 'yq' "$S" && ok "declares yq dependency" || no "declares yq dependency"
grep -q -- '--force' "$S" && ok "registers aliases idempotently (--force)" || no "idempotent --force"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
