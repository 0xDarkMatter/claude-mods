#!/usr/bin/env bash
# claude-mods :: tests/agnostic.sh
#
# WHY THIS EXISTS
#   claude-mods is public. Authoring happens on one specific machine, so the
#   author's hostname, account, drive layout and private project names leak into
#   examples and sample output very easily - and none of it is useful to anyone
#   else. A 2026-08-25 sweep found leaks in nine files, including a username in a
#   supply-chain reference and real project paths in summon's --help text. Prose
#   asking people to "keep it agnostic" had not prevented any of it; this gate is
#   the enforcement layer.
#
#   Modelled on the per-skill guard in skills/windows-ops/tests/run.sh, promoted
#   to repo scope.
#
# WHAT IS DELIBERATELY ALLOWED
#   - Files that self-describe as machine-specific templates and say so in a
#     portability note (rules/dev-servers.md).
#   - CHANGELOG.md and docs/plans/ - historical records; rewriting them would
#     falsify the history that explains why things moved.
#   - Placeholder paths whose segments are obviously generic (X:/path/to/app).
#     The drive letter alone identifies nobody.
#
# Usage:  bash tests/agnostic.sh
# Exit :  0 clean, 1 leak found
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1

FAIL=0
hit() { printf "  [LEAK] %s\n" "$1"; FAIL=1; }

# Paths excluded from every check (see WHAT IS DELIBERATELY ALLOWED).
EXCLUDES=(
  --glob '!.git/**'
  --glob '!.claude/**'
  --glob '!CHANGELOG.md'
  --glob '!docs/plans/**'
  --glob '!tests/agnostic.sh'
)

echo "=== claude-mods :: agnostic gate ==="

# --- 1. Identity: hostname, account, user profile paths, secret-store handles ---
# These identify a person or a machine and are never legitimate in a public repo.
if out=$(rg -n --no-heading -S \
        -e 'Users[\\/]Mack' \
        -e '\bTITAN\b' \
        -e 'mknv74' \
        -e 'agent-01@' \
        -e '\.keeper-agent' \
        "${EXCLUDES[@]}" . 2>/dev/null); then
  hit "identity / hostname / account"
  echo "$out" | sed 's/^/         /'
else
  echo "  [ok] no identity, hostname or account references"
fi

# --- 2. Private project names ---
# Repos and folders that are not part of this project and mean nothing publicly.
if out=$(rg -n --no-heading -S \
        -e '\bSimulacra\b' -e '\bGlyphWeb\b' -e '\bLCMap\b' -e '\bMaplab\b' \
        -e '\bBlockLab\b' -e '\bEvolution7\b' -e 'X:[\\/]DnD' \
        "${EXCLUDES[@]}" . 2>/dev/null); then
  hit "private project name"
  echo "$out" | sed 's/^/         /'
else
  echo "  [ok] no private project names"
fi

# --- 3. Author-specific absolute paths ---
# A concrete personal directory tree, as opposed to an obvious placeholder.
# rules/dev-servers.md is exempt: it opens with a portability note declaring
# itself a machine-specific template, which is the documented way to keep one.
if out=$(rg -n --no-heading \
        -e 'X:[\\/]Forge' -e 'X:[\\/]Roam' -e 'X:[\\/]Lab' -e 'X:[\\/]00_Orchestration' \
        "${EXCLUDES[@]}" --glob '!rules/dev-servers.md' . 2>/dev/null); then
  hit "author-specific absolute path"
  echo "$out" | sed 's/^/         /'
else
  echo "  [ok] no author-specific absolute paths"
fi

# --- 4. Real private LAN addressing ---
# 192.168.1.x and 10.x doc examples are fine; this catches the author's own
# subnet, which appeared verbatim in case studies before the 2026-08-25 sweep.
# The asus-router-ops firewall asset is exempt: its 192.168.50.0/24 is a
# commented-out, explicitly "ADAPT"-labelled example of the ASUS default subnet.
if out=$(rg -n --no-heading -e '192\.168\.50\.' \
        "${EXCLUDES[@]}" --glob '!skills/asus-router-ops/assets/firewall-start.sh' . 2>/dev/null); then
  hit "author LAN addressing"
  echo "$out" | sed 's/^/         /'
else
  echo "  [ok] no author LAN addressing"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== PASS: repo is agnostic ==="
else
  echo "=== FAIL: replace the values above with placeholders, or exempt the file"
  echo "    here with a comment saying why it is legitimately machine-specific ==="
fi
exit "$FAIL"
