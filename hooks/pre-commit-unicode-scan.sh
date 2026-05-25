#!/bin/bash
# hooks/pre-commit-unicode-scan.sh
# Git pre-commit hook — refuse commits that ADD hidden Unicode to instruction files.
#
# This is a GIT hook (not a Claude Code hook). It catches the one case nothing at
# read-time can: a poisoned CLAUDE.md / AGENTS.md / SKILL.md / .cursorrules entering
# the repo via your own commit (PR, template, or pasted-from-untrusted-source content).
#
# Install (per repo):
#   ln -sf ../../hooks/pre-commit-unicode-scan.sh .git/hooks/pre-commit
#   # or, if combining with other pre-commit logic, call it from your existing hook:
#   #   bash hooks/pre-commit-unicode-scan.sh || exit 1
#
# Behaviour (silent guardian, severity-graded):
#   clean              → no output, exit 0 (commit proceeds)
#   high/medium finding→ warning to stderr, exit 0 (commit proceeds — legit in
#                        multilingual files; you decide)
#   critical finding   → block message to stderr, exit 1 (commit refused — tag-block /
#                        bidi override are never legitimate; sanitise first)
#
# Override a block once (you've confirmed it's intentional, e.g. a doc demonstrating
# an attack as a literal): PROMPT_INJECTION_ALLOW=1 git commit ...
#
# Exit codes:
#   0 = allow commit (clean, advisory-only finding, or scanner/python unavailable)
#   1 = block commit (critical finding, not overridden)

set -uo pipefail   # NOT -e: only an explicit critical finding should block

# ── Locate the scanner (repo + installed layouts share the hooks/ ↔ skills/ sibling) ─
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SCANNER=""
for cand in \
  "$SELF_DIR/../skills/prompt-injection-defense/scripts/scan-hidden-unicode.py" \
  "$HOME/.claude/skills/prompt-injection-defense/scripts/scan-hidden-unicode.py"; do
  [ -f "$cand" ] && { SCANNER="$cand"; break; }
done
[ -n "$SCANNER" ] || exit 0   # scanner not installed → don't break commits

PY=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || exit 0

# ── Staged added/modified instruction files ───────────────────────────────────
INSTR_RE='\.(md|mdc)$|(^|/)(CLAUDE|AGENTS|GEMINI|COPILOT|CURSOR|WARP)\.md$|(^|/)\.(cursorrules|windsurfrules|clinerules)$'
mapfile -t FILES < <(git diff --cached --name-only --diff-filter=AM 2>/dev/null | grep -iE "$INSTR_RE" || true)
[ "${#FILES[@]}" -eq 0 ] && exit 0   # no instruction files staged → silent

# Only scan files that exist in the working tree (staged content on disk).
EXIST=()
for f in "${FILES[@]}"; do [ -f "$f" ] && EXIST+=("$f"); done
[ "${#EXIST[@]}" -eq 0 ] && exit 0

# ── Scan with --json to read the worst severity ───────────────────────────────
JSON="$("$PY" "$SCANNER" --json "${EXIST[@]}" 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] && exit 0   # clean → silent, commit proceeds

WORST="$(printf '%s' "$JSON" | "$PY" -c 'import sys,json
try: print(json.load(sys.stdin)["meta"]["worst_severity"])
except Exception: print("unknown")' 2>/dev/null)"

# Human-readable finding lines (file:line:col band) for the message.
DETAIL="$("$PY" "$SCANNER" "${EXIST[@]}" 2>/dev/null | head -20)"

if [ "$WORST" = "critical" ]; then
  if [ "${PROMPT_INJECTION_ALLOW:-0}" = "1" ]; then
    echo "prompt-injection: CRITICAL hidden-Unicode in staged instruction files —" >&2
    echo "  allowed by PROMPT_INJECTION_ALLOW=1. Make sure this is intentional." >&2
    exit 0
  fi
  {
    echo "COMMIT BLOCKED — prompt-injection-defense"
    echo "Critical hidden-Unicode (tag-block ASCII smuggling or bidi override) in staged"
    echo "instruction files. These render as nothing / reorder text — never legitimate here:"
    echo ""
    printf '%s\n' "$DETAIL"
    echo ""
    echo "Fix:  python <skills>/prompt-injection-defense/scripts/sanitize-content.py <file> -o <file>"
    echo "Then re-stage and commit. Override (only if intentional, e.g. an attack-demo doc):"
    echo "  PROMPT_INJECTION_ALLOW=1 git commit ..."
  } >&2
  exit 1
fi

# high / medium → advisory, allow the commit
{
  echo "prompt-injection ADVISORY: ${WORST}-severity hidden-Unicode in staged instruction files."
  echo "Legitimate in genuinely multilingual text; suspicious otherwise. Commit allowed."
  printf '%s\n' "$DETAIL" | head -8
} >&2
exit 0
