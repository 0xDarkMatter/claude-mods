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
#   # The hook follows that link to the skills/ beside its real path. Git Bash's
#   # `ln -s` copies unless symlinks are enabled: the copy still finds this repo's
#   # scanner but keeps the hook code it was copied with, so there use a wrapper:
#   #   printf '#!/bin/sh\nexec bash hooks/pre-commit-unicode-scan.sh\n' > .git/hooks/pre-commit
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
# Resolve this file's REAL path first. The documented install is a symlink, and git
# runs it as .git/hooks/pre-commit: BASH_SOURCE names the link, not its target, so
# the sibling lookup searched .git/skills/, found nothing, and the gate allowed
# every commit. `readlink -f` where it exists; macOS before 12.3 has no -f, so
# there follow the chain by hand (a relative target is relative to the link's dir).
SELF="${BASH_SOURCE[0]}"
SELF_REAL="$(readlink -f -- "$SELF" 2>/dev/null)" || SELF_REAL=""
if [ -z "$SELF_REAL" ]; then
  SELF_REAL="$SELF"; hops=0
  while [ -L "$SELF_REAL" ] && [ "$hops" -lt 40 ]; do   # bounded: a link loop must not hang the commit
    link="$(readlink -- "$SELF_REAL")" || break
    case "$link" in /*) SELF_REAL="$link" ;; *) SELF_REAL="$(dirname -- "$SELF_REAL")/$link" ;; esac
    hops=$((hops + 1))
  done
fi
SELF_DIR="$(cd "$(dirname -- "$SELF_REAL")" 2>/dev/null && pwd)"
REL="skills/prompt-injection-defense/scripts/scan-hidden-unicode.py"
SCANNER=""
for cand in "$SELF_DIR/../$REL" "$HOME/.claude/$REL"; do
  [ -f "$cand" ] && { SCANNER="$cand"; break; }
done
# A COPY in .git/hooks/ has no link to follow, and Git Bash's `ln -s` copies unless
# symlinks are enabled. So last, the repo being committed to, and only when it
# ships this hook beside the scanner: the layout the documented
# `ln -sf ../../hooks/...` points into, whose hook code you already chose to run.
# It runs the work tree's scanner, so it comes after the installed copy and never
# for a repo that merely has a skills/ folder.
if [ -z "$SCANNER" ]; then
  TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
  [ -n "$TOP" ] && [ -f "$TOP/hooks/pre-commit-unicode-scan.sh" ] && [ -f "$TOP/$REL" ] && SCANNER="$TOP/$REL"
fi
# Not found → warn and allow, never a silent exit 0. A git hook runs only because
# someone installed it, so a missing scanner is a broken install, and silence looked
# exactly like a clean commit (how the symlink bug above went unnoticed). Not a
# block: the gate is opt-in, and a machine without the skill must still commit.
if [ -z "$SCANNER" ]; then
  echo "prompt-injection pre-commit: scanner not found, so staged instruction files were NOT" >&2
  echo "  scanned (looked beside $SELF_REAL, in ~/.claude/skills and in this repo). Install" >&2
  echo "  the prompt-injection-defense skill, or remove this hook. Commit allowed." >&2
  exit 0
fi

# First of python3/python/py that really runs 3.8+ (same probe as the skill's
# scripts/run-python.sh). A bare "import sys" also passes a pre-3.8 interpreter,
# which then fails the scanner and let a critical finding through as "unknown".
PY=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 \
    && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' </dev/null >/dev/null 2>&1 \
    && { PY="$c"; break; }
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
    echo "Fix:  S=<skills>/prompt-injection-defense/scripts"
    echo "      bash \$S/run-python.sh \$S/sanitize-content.py <file> -o <file>"
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
