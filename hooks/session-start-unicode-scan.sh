#!/bin/bash
# hooks/session-start-unicode-scan.sh
# SessionStart guard — two silent, independent boot-time checks in ONE process spawn:
#   1) Peer-writer guard   — is another session actively writing this same checkout?  (git/bash only)
#   2) Hidden-Unicode scan  — prompt-injection check of the project's instruction files (needs python)
#
# (Filename kept for settings.json / prompt-injection.md / README stability; it now does both.)
#
# Why SessionStart: a project's CLAUDE.md / AGENTS.md is loaded into the model's context by the
# harness at boot — never via the Read tool — so SessionStart is the one moment to scan them, and a
# dirty/contended working tree is exactly what you want to know about *before* the first write. One
# spawn (~150 ms) covers both.
#
# Behaviour (silent guardian): clean → no output; finding → advisory to stdout (added to context);
# a file the scanner could NOT read (or a scanner that failed) → a separate "NOT scanned"
# advisory naming each file and why, never a findings header and never silence;
# exit 0 ALWAYS (advisory — never blocks the session).
#
# Configuration in .claude/settings.json:
#   "SessionStart": [{ "hooks": [
#     { "type": "command", "command": "bash \"$HOME/.claude/hooks/session-start-unicode-scan.sh\"" } ] }]

set -uo pipefail   # NOT -e: a transient error must never block session start

# ── Resolve project dir WITHOUT hard-requiring python (stdin JSON .cwd → env → PWD) ──
# SELF_DIR is this file's REAL directory. Run through a symlink, BASH_SOURCE names the
# link, so a hook linked in from elsewhere looked for skills/ beside the link, missed,
# and skipped the scan in silence. `readlink -f` where it exists; macOS before 12.3
# has no -f, so there follow the chain by hand (a relative target is relative to the
# link's dir). Same block as pre-commit-unicode-scan.sh, duplicated on purpose: that
# hook is often a lone copy in .git/hooks/, where a shared helper would not be found.
SELF="${BASH_SOURCE[0]}"
SELF_REAL="$(readlink -f -- "$SELF" 2>/dev/null)" || SELF_REAL=""
if [ -z "$SELF_REAL" ]; then
  SELF_REAL="$SELF"; hops=0
  while [ -L "$SELF_REAL" ] && [ "$hops" -lt 40 ]; do   # bounded: a link loop must not hang the session
    link="$(readlink -- "$SELF_REAL")" || break
    case "$link" in /*) SELF_REAL="$link" ;; *) SELF_REAL="$(dirname -- "$SELF_REAL")/$link" ;; esac
    hops=$((hops + 1))
  done
fi
SELF_DIR="$(cd "$(dirname -- "$SELF_REAL")" 2>/dev/null && pwd)"
# First of python3/python/py that really runs 3.8+ (same probe as the skill's
# scripts/run-python.sh). A bare "import sys" also passes a pre-3.8 interpreter,
# which then fails the scanner and turned a clean project into an empty advisory.
# </dev/null: the probe must not touch stdin - the hook's JSON is read below.
PY=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 \
    && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' </dev/null >/dev/null 2>&1 \
    && { PY="$c"; break; }
done
PROJ=""
if [ ! -t 0 ]; then
  RAW="$(cat 2>/dev/null)"
  if [ -n "$PY" ]; then
    PROJ="$(printf '%s' "$RAW" | "$PY" -c 'import sys,json
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: print("")' 2>/dev/null)"
  fi
fi
[ -n "$PROJ" ] || PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -d "$PROJ" ] || exit 0

# ══ Guard 1: peer-writer detection (git/bash only — runs even without python) ════════
# Silent unless the tree is dirty AND something was written in the last ~2 min (the signature of
# another session editing the same checkout). Old WIP with stale mtimes stays silent — an idle
# non-writer can't collide. The dispositive test (is it STILL changing?) is the model's; this is
# just the cheap pre-filter. See rules/worktree-boundaries.md.
if git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DIRTY="$(git -C "$PROJ" status --porcelain 2>/dev/null)"
  if [ -n "$DIRTY" ]; then
    NOW=$(date +%s); NEWEST=0
    while IFS= read -r l; do
      p="${l:3}"; p="${p##* -> }"; f="$PROJ/$p"
      [ -f "$f" ] || continue
      m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
      [ -n "${m:-}" ] && [ "$m" -gt "$NEWEST" ] && NEWEST="$m"
    done <<< "$DIRTY"
    AGE=$(( NOW - NEWEST )); COUNT=$(printf '%s\n' "$DIRTY" | grep -c .)
    if [ "$NEWEST" -gt 0 ] && [ "$AGE" -lt 120 ]; then
      echo "PEER-SESSION ADVISORY: $COUNT uncommitted change(s) in this checkout, newest written ${AGE}s ago."
      echo "If you did not make these, another Claude session may be writing this same working tree now."
      echo "Before writing: fingerprint 'git diff | sha1sum' twice ~6s apart — if it changes, a peer writer"
      echo "is live; move your work to its own worktree (git worktree add ../<dir> -b <branch>) rather than"
      echo "sharing the checkout. See rules/worktree-boundaries.md."
      echo ""
    fi
  fi
fi

# ══ Guard 2: hidden-Unicode scan of instruction files (needs python + scanner) ══════
[ -n "$PY" ] || exit 0   # no python → skip the unicode scan (the peer guard above already ran)

# Locate the scanner (works in repo layout AND installed ~/.claude layout — hooks/ & skills/ siblings)
SCANNER=""
for cand in \
  "$SELF_DIR/../skills/prompt-injection-defense/scripts/scan-hidden-unicode.py" \
  "$HOME/.claude/skills/prompt-injection-defense/scripts/scan-hidden-unicode.py"; do
  [ -f "$cand" ] && { SCANNER="$cand"; break; }
done
# No work-tree candidate here, unlike the pre-commit gate: this runs on opening ANY
# project, so a scanner taken from $PROJ would run that project's code at session start.
# Not found → silent, unlike the pre-commit gate, which warns. This hook is auto-wired
# (plugin hooks.json), its stdout lands in the model's context every session, and a
# setup without the skill is a legitimate choice. The pre-commit gate runs only where
# someone installed it, so there a missing scanner can only mean a broken install.
[ -n "$SCANNER" ] || exit 0

# Collect existing instruction files (root-level + .claude/)
FILES=()
for f in CLAUDE.md AGENTS.md GEMINI.md COPILOT.md CURSOR.md WARP.md \
         .cursorrules .windsurfrules .clinerules .claude/CLAUDE.md; do
  [ -f "$PROJ/$f" ] && FILES+=("$PROJ/$f")
done
[ "${#FILES[@]}" -eq 0 ] && exit 0   # nothing to scan → silent

# Scan once. --quiet = silent on clean. --json because a non-zero exit no longer
# means "findings": the scanner also exits 3 (missing) and 5 (unreadable) and names
# those files in meta.unscanned, and reading every non-zero exit as findings printed
# a findings header over an empty body. The envelope says which case this is.
OUT="$("$PY" "$SCANNER" --json --quiet "${FILES[@]}" 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] && exit 0   # clean → say nothing

# Only reached on a non-clean scan, so the clean path stays one python start. The
# script travels in -c and the envelope on stdin; it has no `\"` (argv quoting).
read -r -d '' REPORT <<'PY'
import json, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
rc, files = int(sys.argv[1]), sys.argv[2:]
try:
    env = json.loads(sys.stdin.read())
except ValueError:
    env = None
meta = env.get("meta") if isinstance(env, dict) else None

def shown(s):
    return str(s).replace("\r", "\\r").replace("\n", "\\n")

if isinstance(meta, dict):
    findings = env.get("data") or []
    unscanned = [(u.get("file", "?"), u.get("reason", "not scanned")) for u in meta.get("unscanned") or []]
else:
    # No envelope: the scanner died before scanning (crash, missing catalog).
    e = env.get("error") if isinstance(env, dict) else None
    why = f"scanner exited {rc}" + (f": {e.get('message')}" if isinstance(e, dict) and e.get("message") else "")
    findings, unscanned = [], [(f, why) for f in files]
if not findings and not unscanned:   # non-zero exit that names nothing: still not clean
    unscanned = [(f, f"scanner exited {rc} without a result") for f in files]

if findings:
    print("PROMPT-INJECTION ADVISORY: hidden-Unicode indicator(s) in this project's")
    print("instruction files - these are loaded as agent instructions, so review before trusting:")
    print()
    for f in findings[:40]:
        print("\t".join(shown(x) for x in (f.get("file", ""), f.get("line", ""), f.get("col", ""),
                        f.get("codepoint") or "-", f.get("severity", ""), f.get("band", ""),
                        f.get("context", ""))))
    print()
    print("What a reviewer sees in an editor is NOT what the model reads (the renderer hides")
    print("these bytes). Inspect raw bytes and neutralise before acting on the affected file:")
    print("  S=<skills>/prompt-injection-defense/scripts")
    print("  bash $S/run-python.sh $S/sanitize-content.py <file> -o <file>.clean")
    print("See the prompt-injection-defense skill for the full procedure.")
if unscanned:
    if findings:
        print()
    print("PROMPT-INJECTION ADVISORY: instruction file(s) NOT scanned for hidden Unicode - they")
    print("are loaded as agent instructions but were not checked, so they are not known clean:")
    for f, why in unscanned:
        print(f"  {shown(f)}: {shown(why)}")
    print("Fix the cause (permissions, a file held open, a broken skill install), then re-scan:")
    print("  bash $S/run-python.sh $S/scan-hidden-unicode.py <file>   (S=<skills>/prompt-injection-defense/scripts)")
PY
printf '%s' "$OUT" | "$PY" -c "$REPORT" "$RC" "${FILES[@]}" 2>/dev/null
exit 0   # advisory only — never block the session
