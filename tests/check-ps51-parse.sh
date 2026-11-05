#!/usr/bin/env bash
# Gate: every tracked PowerShell file must parse under Windows PowerShell 5.1, not just pwsh 7.
#
# WHY THIS EXISTS
#   Windows PowerShell 5.1 (powershell.exe, still the default shell on Windows) reads a
#   script that has no byte-order mark in the system ANSI code page (CP1252 on most
#   machines), not UTF-8. Each UTF-8 multi-byte character then decodes as 2-4 junk
#   characters, and some of those junk characters are smart quotes, which PowerShell
#   accepts as string delimiters:
#       em dash   U+2014  = E2 80 94     -> 0x94 = U+201D right double quote
#       box rule  U+2500  = E2 94 80     -> 0x94 again
#       emoji     U+1F464 = F0 9F 91 A4  -> 0x91 = U+2018 left single quote
#   One of those inside a quoted string ends the string early, and the parse fails,
#   often dozens of lines away from the real cause. pwsh 7 reads UTF-8 by default, so
#   the bug cannot be seen there.
#
# THE RULE: tracked PowerShell files (.ps1, .psm1, .psd1) are 7-bit ASCII.
#   - A decorative character becomes its ASCII equivalent, in comments and strings
#     alike: box rules `- = | +`, em/en dash `-`, separator dot `|`, arrow `->`,
#     ellipsis `...` (the proxies registered in docs/TERMINAL-DESIGN.md).
#   - A glyph that IS the output (skills/_lib/term.ps1's icons, connectors, spinners)
#     is built from its code point: [char]0x2500, or [char]::ConvertFromUtf32(0x1F528)
#     for characters outside the BMP. The bytes stay ASCII and the output is unchanged.
#   A UTF-8 BOM would also make 5.1 decode correctly, but it is not the rule here: a
#   script with a `#!` line cannot carry one, files created by tools start without
#   one, and every copier and template renderer would have to keep it. ASCII keeps
#   all of those working. A leading BOM is tolerated, but non-ASCII after it still fails.
#
# TWO HALVES
#   1. Static (runs everywhere, Linux CI included): any byte >= 0x80 fails the file.
#   2. Real parse (only where a Windows PowerShell 5.1 host exists): every file goes
#      through 5.1's own parser in ONE powershell.exe run, and any parse error fails.
#      The host is detected by powershell.exe being on PATH AND reporting
#      PSEdition=Desktop. pwsh is never used: it is on GitHub's Linux runners too, and
#      it reads UTF-8, so it would not reproduce the bug.
#
# Usage:   bash tests/check-ps51-parse.sh [--require-parse] [--help]
# Output:  stdout = findings, one per line; stderr = summary
# Exit:    0 clean, 1 findings, 2 usage error / broken scan / --require-parse without a 5.1 host
set -u

usage() {
    cat <<'EOF'
Usage: tests/check-ps51-parse.sh [--require-parse] [--help]

Fail on tracked PowerShell files (.ps1 .psm1 .psd1) that Windows PowerShell 5.1
would mis-read: any non-ASCII byte fails (the rule: these files are ASCII). Where
a Windows PowerShell 5.1 host exists, also run its parser over every file and fail
on any parse error. Elsewhere that half is skipped, and the summary says so.

Fix a finding by replacing a decorative character with its ASCII equivalent, or
by building an output glyph from its code point: [char]0x2014, or
[char]::ConvertFromUtf32(0x1F528) outside the BMP.

  --require-parse   exit 2 if the 5.1 parse cannot run (use on Windows CI)

EXAMPLES
  bash tests/check-ps51-parse.sh
  bash tests/check-ps51-parse.sh --require-parse
  bash tests/check-ps51-parse.sh --help

Exit codes: 0 clean, 1 findings, 2 usage error, broken scan, or --require-parse
without a 5.1 host.
EOF
}

require_parse=0
for arg in "$@"; do
    case "$arg" in
        --require-parse) require_parse=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-ps51-parse: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# procsub guard: a loop fed by `< <(git ls-files)` never sees git's exit status, so a git
# that died part-way would end the loop early and report clean. Capture, check, loop.
# Keep the call spelled `git ls-files ...`: tests/procsub-guard.sh breaks it by that shape.
rc=0; files="$(git ls-files -- '*.ps1' '*.psm1' '*.psd1')" || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "check-ps51-parse: git ls-files failed (exit $rc) - scan incomplete" >&2
    exit 2
fi

findings=0
candidates=0
# One awk over every file finds the non-ASCII lines: head|od + tail|grep|cut per file was
# ~8 process starts each (~450 a run), which is what made this gate slow on Git Bash.
# LC_ALL=C makes awk match raw bytes; \200-\377 is 0x80-0xFF. A leading UTF-8 BOM is
# tolerated (see header): stripped from line 1 only, so line numbers are unaffected.
# Rows: "<path>\037<first bad line>\037<bad line count>". \037 because paths may hold tabs.
existing=()
while IFS= read -r path; do
    case "$path" in ''|\"*) continue ;; esac
    [ -f "$path" ] && existing+=("$path")
done <<< "$files"
declare -A HIGH_FIRST=() HIGH_COUNT=()
if [ "${#existing[@]}" -gt 0 ]; then
    rc=0
    rows="$(LC_ALL=C awk '
        FNR == 1 { sub(/^\357\273\277/, "") }
        /[\200-\377]/ { n[FILENAME]++; if (!(FILENAME in first)) first[FILENAME] = FNR }
        END { for (f in n) printf "%s\037%d\037%d\n", f, first[f], n[f] }
    ' "${existing[@]}")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-ps51-parse: non-ASCII scan failed (awk exit $rc) - scan incomplete" >&2
        exit 2
    fi
    while IFS=$'\037' read -r p first n; do
        [ -n "$p" ] || continue
        HIGH_FIRST[$p]="$first"; HIGH_COUNT[$p]="$n"
    done <<< "$rows"
fi
while IFS= read -r path; do
    [ -n "$path" ] || continue
    candidates=$((candidates + 1))
    case "$path" in
        \"*)  # git C-quotes a non-ASCII file name; the name itself breaks the rule
            echo "$path: non-ASCII file name (rename it to ASCII)"
            findings=$((findings + 1)); continue ;;
    esac
    if [ ! -f "$path" ]; then
        echo "$path: tracked but missing from the working tree (restore it or stage the deletion)"
        findings=$((findings + 1)); continue
    fi
    if [ -n "${HIGH_FIRST[$path]+set}" ]; then
        echo "$path:${HIGH_FIRST[$path]}: non-ASCII byte(s) on ${HIGH_COUNT[$path]} line(s) (use an ASCII equivalent, or [char]0xNNNN for an output glyph)"
        findings=$((findings + 1))
    fi
done <<< "$files"

# A gate that checked nothing must not report clean.
if [ "$candidates" -eq 0 ]; then
    echo "check-ps51-parse: self-check failed - zero PowerShell files found (broken scan?)" >&2
    exit 2
fi

# --- Real parse under Windows PowerShell 5.1 ----------------------------------------------
# One powershell.exe for all files (it takes about a second to start). Protocol on its
# stdout: `PARSED <n> <path>` per file, then `ERR <path>:<line>: <message>` per error,
# `UNREADABLE <path>: <why>`, and a final `DONE`. A run without DONE, or with fewer
# PARSED rows than files, died part-way: that is a broken scan, never a clean one.
parse_note=""
PS51="$(command -v powershell.exe 2>/dev/null || true)"
to_win() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"
    elif command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"
    else return 1; fi
}
if [ -z "$PS51" ]; then
    parse_note="5.1 parse SKIPPED (no powershell.exe on PATH)"
elif ! win_root="$(to_win "$ROOT")"; then
    parse_note="5.1 parse SKIPPED (powershell.exe found, but no cygpath/wslpath to hand it Windows paths)"
else
    list="$(mktemp)"; trap 'rm -f "$list"' EXIT
    printf '%s\n' "$files" > "$list"
    win_list="$(to_win "$list")"
    probe='
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne "Desktop") { "EDITION " + $PSVersionTable.PSEdition; "DONE"; exit 0 }
foreach ($rel in [IO.File]::ReadAllLines($env:PS51_LIST)) {
    if (-not $rel) { continue }
    $t = $null; $e = $null
    try {
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $env:PS51_ROOT $rel), [ref]$t, [ref]$e) | Out-Null
        "PARSED " + $e.Count + " " + $rel
        foreach ($x in $e) { "ERR " + $rel + ":" + $x.Extent.StartLineNumber + ": " + $x.Message }
    } catch { "UNREADABLE " + $rel + ": " + $_.Exception.Message }
}
"DONE"'
    rc=0
    out="$(PS51_ROOT="$win_root" PS51_LIST="$win_list" "$PS51" -NoProfile -NonInteractive -Command "$probe" 2>&1 | tr -d '\r')" || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx 'DONE'; then
        echo "check-ps51-parse: powershell.exe probe failed (exit $rc) - parse incomplete" >&2
        printf '%s\n' "$out" | tail -n 5 >&2
        exit 2
    fi
    edition="$(printf '%s\n' "$out" | sed -n 's/^EDITION //p')"
    if [ -n "$edition" ]; then
        parse_note="5.1 parse SKIPPED (powershell.exe reports PSEdition=$edition, not Desktop 5.1)"
    else
        parsed="$(printf '%s\n' "$out" | grep -c '^PARSED ' || true)"
        while read -r _ n p; do               # PARSED <n> <path>
            [ -n "${p-}" ] || continue
            [ "$n" = "0" ] && continue
            first="$(printf '%s\n' "$out" | grep -F -m1 "ERR $p:" | sed 's/^ERR //')"
            echo "$p: $n parse error(s) under Windows PowerShell 5.1 (first at line ${first#"$p":})"
            findings=$((findings + 1))
        done <<< "$(printf '%s\n' "$out" | grep '^PARSED ' || true)"
        while IFS= read -r row; do
            [ -n "$row" ] || continue
            echo "${row#UNREADABLE }"
            findings=$((findings + 1))
        done <<< "$(printf '%s\n' "$out" | grep '^UNREADABLE ' || true)"
        unreadable="$(printf '%s\n' "$out" | grep -c '^UNREADABLE ' || true)"
        if [ "$((parsed + unreadable))" -ne "$candidates" ]; then
            echo "check-ps51-parse: 5.1 probe reported $parsed of $candidates files - parse incomplete" >&2
            exit 2
        fi
        parse_note="$parsed parsed under Windows PowerShell 5.1"
    fi
fi

case "$parse_note" in
    *SKIPPED*)
        if [ "$require_parse" -eq 1 ]; then
            echo "check-ps51-parse: --require-parse, but $parse_note" >&2
            exit 2
        fi ;;
esac

if [ "$findings" -eq 0 ]; then
    echo "check-ps51-parse: clean ($candidates ASCII-checked; $parse_note)" >&2
    exit 0
fi
echo "check-ps51-parse: $findings finding(s) ($candidates ASCII-checked; $parse_note)" >&2
exit 1
