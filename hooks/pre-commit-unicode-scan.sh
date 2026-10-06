#!/bin/bash
# hooks/pre-commit-unicode-scan.sh
# Git pre-commit hook — refuse commits that ADD hidden Unicode to instruction files.
#
# This is a GIT hook (not a Claude Code hook). It catches the one case nothing at
# read-time can: a poisoned CLAUDE.md / AGENTS.md / SKILL.md / .cursorrules entering
# the repo via your own commit (PR, template, or pasted-from-untrusted-source content).
#
# It scans the INDEX copy of each staged instruction file (the blob the commit
# records), never the file on disk, which can differ: staged poisoned, then
# rewritten clean or deleted. Names come from `git diff --cached -z`, so renamed
# files and non-ASCII / odd filenames are scanned too.
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
#   clean               → no output, exit 0 (commit proceeds)
#   high/medium finding → warning to stderr, exit 0 (commit proceeds — legit in
#                         multilingual files; you decide)
#   critical finding    → block message to stderr, exit 1 (commit refused — tag-block /
#                         bidi override are never legitimate; sanitise first)
#   NOT scanned         → block message to stderr, exit 1: a staged instruction file
#                         could not be read, or the scanner failed (see "Unscanned
#                         blocks" below)
#   python 3.8+ missing → silent, exit 0 (opt-in tooling: a machine without it
#                         must still be able to commit)
#   scanner not found   → warning to stderr, exit 0 (a broken install: the hook runs
#                         only because someone installed it, so silence would look
#                         like a clean commit)
#
# Override a block once (you've confirmed it's intentional, e.g. a doc demonstrating
# an attack as a literal, or a scanner you know is broken): PROMPT_INJECTION_ALLOW=1 git commit ...
#
# Exit codes:
#   0 = allow commit (clean, advisory-only finding, or python/scanner not installed)
#   1 = block commit (critical finding, or a staged instruction file NOT scanned;
#       not overridden)

set -uo pipefail   # NOT -e: every block below is an explicit decision, never a stray error

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

# ── Staged instruction files: NAMES from the diff ─────────────────────────────
# -z: NUL-separated and never quoted. Without it git C-quotes a non-ASCII name
#   ("docs/r\303\250gles.md"), which matched neither this filter nor a file.
# --no-renames: a moved file is listed as delete + add, so its new path is scanned.
#   With rename detection (git's default) it is status R, which the old A/M filter
#   dropped: rename an instruction file, poison it, commit.
# ACMRT: every status that puts content in the commit (T = type change, e.g. a
#   symlink replaced by a file); only deletions are skipped.
INSTR_RE='\.(md|mdc)$|(^|/)(CLAUDE|AGENTS|GEMINI|COPILOT|CURSOR|WARP)\.md$|(^|/)\.(cursorrules|windsurfrules|clinerules)$'
NAMES=()
shopt -s nocasematch   # INSTR_RE is case-insensitive (it was `grep -iE`)
while IFS= read -r -d '' f; do
  [[ "$f" =~ $INSTR_RE ]] && NAMES+=("$f")
done < <(git diff --cached --name-only -z --no-renames --diff-filter=ACMRT 2>/dev/null)
shopt -u nocasematch
[ "${#NAMES[@]}" -eq 0 ] && exit 0   # no instruction files staged → silent

# ── CONTENT from the index, one scanner run for the whole commit ──────────────
# Each staged blob is copied to $TMP/<position> (0, 1, ...): one scanner start
# covers the commit (a python start is ~100 ms on Windows, so per-file `--stdin`
# runs made a 100-file sweep take ~15 s), and no staged name, however odd, ever
# becomes a path. The summary maps <position> back to its name in $TMP/names.
# `:0:<name>` is the stage-0 index entry, resolved from the top of the work tree (the
# form diff --cached prints). The explicit 0 keeps a name like `1:x.md` from reading
# as "stage 1 of x.md". cat-file, not show, so no textconv or filter runs.
# A blob cat-file cannot produce leaves $TMP/<position>.unread holding git's error.
TMP="$(mktemp -d 2>/dev/null)"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  if [ "${PROMPT_INJECTION_ALLOW:-0}" = "1" ]; then
    echo "prompt-injection: no temp dir, ${#NAMES[@]} staged instruction file(s) NOT scanned - commit ALLOWED by PROMPT_INJECTION_ALLOW=1." >&2
    exit 0
  fi
  echo "COMMIT BLOCKED - prompt-injection-defense: no temp dir to copy staged instruction" >&2
  echo "files into, so ${#NAMES[@]} file(s) were NOT scanned. Override: PROMPT_INJECTION_ALLOW=1 git commit ..." >&2
  exit 1
fi
trap 'rm -rf "$TMP"' EXIT

BLOBS=()
: > "$TMP/names"
for i in "${!NAMES[@]}"; do
  printf '%s\0' "${NAMES[$i]}" >> "$TMP/names"
  if git cat-file blob ":0:${NAMES[$i]}" > "$TMP/$i" 2> "$TMP/$i.err"; then
    BLOBS+=("$TMP/$i")
  else
    mv -f "$TMP/$i.err" "$TMP/$i.unread"
  fi
done

RC=0
if [ "${#BLOBS[@]}" -gt 0 ]; then
  "$PY" "$SCANNER" --json --quiet "${BLOBS[@]}" > "$TMP/scan.json" 2> "$TMP/scan.err" || RC=$?
fi

# ── Decide ────────────────────────────────────────────────────────────────────
# Unscanned blocks: once python and the scanner are present, every staged
# instruction file must come back scanned, or the commit is refused. The commit
# records these exact blobs, and "could not read it" is the case nobody checks:
# an unreadable blob (corrupt object store, a submodule named *.md), a file the
# scanner lists in meta.unscanned (exit 3/5), or a scanner that crashed or lost its
# catalog. Waving those through reads as clean when nothing looked - the fail-open
# this hook had when it skipped files missing on disk. Legitimate commits almost
# never hit it, and PROMPT_INJECTION_ALLOW=1 overrides once. Python or the scanner
# being absent is different: opt-in tooling not installed, allowed above (exit 0;
# a missing scanner with a warning).
"$PY" - "$TMP" "$RC" "${#NAMES[@]}" <<'PY'
import json, os, sys

tmp, rc, total = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
allow = os.environ.get("PROMPT_INJECTION_ALLOW", "0") == "1"
err = sys.stderr
try:
    err.reconfigure(encoding="utf-8", errors="replace")   # non-ASCII names on a cp1252 console
except Exception:
    pass

def read(name):
    try:
        with open(os.path.join(tmp, name), "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""

names = read("names").split("\0")[:total]

def shown(s):                      # one record per line, whatever is in the name
    return str(s).replace("\r", "\\r").replace("\n", "\\n")

def staged_name(path):             # scanner's temp path -> the staged name it holds
    base = str(path).replace("\\", "/").rsplit("/", 1)[-1]
    return names[int(base)] if base.isdigit() and int(base) < len(names) else str(path)

unscanned = []                     # (staged name, reason)
passed = []                        # positions handed to the scanner
for i, name in enumerate(names):
    if os.path.exists(os.path.join(tmp, f"{i}.unread")):
        why = read(f"{i}.unread").strip().splitlines()
        unscanned.append((name, "could not read the staged blob: " + (why[-1] if why else "git cat-file failed")))
    else:
        passed.append(i)

findings = []
if passed:
    try:
        env = json.loads(read("scan.json"))
    except ValueError:
        env = None
    meta = env.get("meta") if isinstance(env, dict) else None
    if isinstance(meta, dict):     # a result envelope: findings and/or unscanned files
        findings = env.get("data") or []
        unscanned += [(staged_name(u.get("file", "")), u.get("reason", "not scanned"))
                      for u in meta.get("unscanned") or []]
    else:                          # no envelope: the scanner died before scanning
        e = env.get("error") if isinstance(env, dict) else None
        msg = e.get("message") if isinstance(e, dict) else None
        if not msg:
            tail = read("scan.err").strip().splitlines()
            msg = tail[-1] if tail else "no output"
        unscanned += [(names[i], f"scanner exited {rc}: {msg}") for i in passed]
    if rc != 0 and not findings and not unscanned:   # a failure that names nothing is not clean
        unscanned += [(names[i], f"scanner exited {rc} without a result") for i in passed]

SEV = {"benign": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
worst = max(findings, key=lambda f: SEV.get(f.get("severity"), 0), default={}).get("severity")

def tsv(f):                        # the scanner's own TSV columns, name restored
    return "\t".join(shown(x) for x in (staged_name(f.get("file", "")), f.get("line", ""),
                     f.get("col", ""), f.get("codepoint") or "-", f.get("severity", ""),
                     f.get("band", ""), f.get("context", "")))

if worst == "critical" or unscanned:
    if allow:
        print("prompt-injection: commit ALLOWED by PROMPT_INJECTION_ALLOW=1 despite"
              + (" CRITICAL hidden-Unicode" if worst == "critical" else "")
              + (" and" if worst == "critical" and unscanned else "")
              + (f" {len(unscanned)} staged instruction file(s) NOT scanned" if unscanned else "")
              + ". Make sure this is intentional.", file=err)
        sys.exit(0)
    print("COMMIT BLOCKED - prompt-injection-defense", file=err)
    if worst == "critical":
        print("Critical hidden-Unicode (tag-block ASCII smuggling or bidi override) in staged\n"
              "instruction files. These render as nothing / reorder text - never legitimate here:\n", file=err)
        for f in findings[:20]:
            print(tsv(f), file=err)
        print("\nFix:  S=<skills>/prompt-injection-defense/scripts\n"
              "      bash $S/run-python.sh $S/sanitize-content.py <file> -o <file>\n"
              "Then re-stage and commit.", file=err)
    if unscanned:
        if worst == "critical":
            print("", file=err)
        print("Staged instruction file(s) NOT scanned - not checked, so not known clean:", file=err)
        for name, why in unscanned[:20]:
            print(f"  {shown(name)}: {shown(why)}", file=err)
        print("Fix the cause (a broken skill install, an unreadable object), then commit again.", file=err)
    print("Override (only if intentional, e.g. an attack-demo doc):\n"
          "  PROMPT_INJECTION_ALLOW=1 git commit ...", file=err)
    sys.exit(1)

if findings:                       # high / medium / low → advisory, allow the commit
    print(f"prompt-injection ADVISORY: {worst}-severity hidden-Unicode in staged instruction files.\n"
          "Legitimate in genuinely multilingual text; suspicious otherwise. Commit allowed.", file=err)
    for f in findings[:8]:
        print(tsv(f), file=err)
sys.exit(0)
PY
exit $?
