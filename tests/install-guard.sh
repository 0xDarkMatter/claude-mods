#!/usr/bin/env bash
# claude-mods :: tests/install-guard.sh
#
# WHY THIS EXISTS
#   ~/.claude is one shared mutable directory that every lane's install.ps1
#   writes to, from whatever tree that lane happens to sit in. On 2026-08-31 an
#   install from an older checkout silently reverted six skills that another
#   lane had already landed - the installed loop-ops SKILL.md was 343 lines
#   against main's 454. Nothing errored. The only symptom was a skill
#   description quietly reading wrong.
#
#   scripts/install.ps1 grew two defences for that: a staleness guard that
#   refuses an install which would revert landed work, and a read-only -Doctor
#   mode that reports drift. This suite defends BOTH against the two ways they
#   would die:
#
#     1. FALSE POSITIVES KILL GUARDS. Installing from a feature branch is the
#        normal lane workflow. A guard that fires merely because HEAD != main
#        breaks everyone and gets ripped out within a day. The
#        "branch-ahead-of-main stays silent" assertion is the single most
#        important test in this file.
#     2. CRLF NOISE KILLS DOCTORS. Many SKILL.md files are committed CRLF while
#        the installed copies land LF. A naive byte compare flags most of the
#        skill tree as drifted. Every comparison must be line-ending-insensitive,
#        and the fixture below proves it on a file whose ONLY difference is its
#        line endings.
#
#   It also covers the installer proper on one axis the guard and doctor share:
#   bracketed paths. `[`/`]` are PowerShell wildcards, so a -Path enumeration
#   rooted at a worktree like `.claude/worktrees/lane[1]/` matches nothing and
#   returns cleanly - the installer installs zero of everything and exits 0.
#   Sections 8 and 11 assert the doctor and the install side see through that.
#
#   And one more: root SPELLING. The provider canonicalises a root (8.3 short
#   names expanded, `..` collapsed) before handing back its children, so a
#   relative path cut by string length against the caller's spelling shifts
#   silently. A GitHub Windows runner's %TEMP% is an 8.3 short path, which made
#   this suite fail on every CI run while passing on machines without 8.3
#   names. Section 12 pins it on any volume with a `..` spelling.
#
# Usage:  bash tests/install-guard.sh
# Input:  none (builds throwaway git repos under a mktemp dir)
# Output: human progress lines on stdout
# Stderr: nothing on success
# Exit:   0 all assertions pass, 1 an assertion failed, 5 pwsh unavailable
#
# Examples:
#   bash tests/install-guard.sh
#   bash tests/install-guard.sh --help
#
# NOTE: this suite never touches the real ~/.claude - every install target is a
# temporary directory handed to install.ps1 via CLAUDE_DIR.
set -u

usage() {
    cat <<'EOF'
Usage: tests/install-guard.sh [--help]

Behavioural tests for scripts/install.ps1's staleness guard and -Doctor mode.
Builds throwaway git repositories and throwaway install targets; the real
~/.claude is never read or written.

EXAMPLES
  bash tests/install-guard.sh
  bash tests/install-guard.sh --help

Exit codes: 0 all pass, 1 assertion failed, 2 usage error, 5 pwsh not found.
EOF
}

case "${1-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install-guard: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "install-guard: pwsh (PowerShell 7+) is required to test install.ps1" >&2
    echo "install-guard: install it, or run this suite on a host that has it" >&2
    exit 5
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "install-guard: jq is required" >&2
    exit 5
fi

FAIL=0
pass() { printf '  [ok]   %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

# pwsh is a native Windows binary under Git Bash, so it cannot resolve a
# /tmp-style path. Translate when cygpath exists; pass through on Linux/macOS.
wp() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# git is a native Windows binary here too, and its MSYS argument translator
# mangles a bracketed POSIX path: `git -C '/tmp/x/lane[1]'` dies with "cannot
# change to ... No such file or directory" even though the directory exists.
# Feeding it the Windows form works. Section 11 depends on this - without it the
# bracketed fixture is silently not a git repo, which sends install.ps1 down its
# no-git degradation path and tests something other than what it claims to.
g() { local d="$1"; shift; git -C "$(wp "$d")" "$@"; }

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# --- fixture builders -------------------------------------------------------

# A minimal but COMPLETE installable tree: every directory install.ps1
# enumerates must exist, or the installer errors before reaching what we test.
new_repo() {
    local d="$1"
    mkdir -p "$d/scripts" "$d/skills/alpha" "$d/agents" "$d/rules" \
             "$d/commands" "$d/output-styles" "$d/hooks" "$d/.github"
    cp "$ROOT/scripts/install.ps1" "$d/scripts/install.ps1"
    printf -- '---\nname: alpha\ndescription: "alpha"\n---\n\n# Alpha\n' > "$d/skills/alpha/SKILL.md"
    printf -- '# demo agent\n' > "$d/agents/demo-expert.md"
    printf -- '# demo rule\n' > "$d/rules/demo.md"
    printf -- '# demo command\n' > "$d/commands/demo.md"
    printf -- '# demo style\n' > "$d/output-styles/demo.md"
    printf '#!/usr/bin/env bash\necho demo\n' > "$d/hooks/demo.sh"
    printf '{ "hooks": {} }\n' > "$d/hooks/hooks.json"
    printf -- '# readme\n' > "$d/README.md"
    printf -- 'name: ci\n' > "$d/.github/workflow.yml"
    g "$d" init -q -b main
    g "$d" config user.email "test@example.invalid"
    g "$d" config user.name "install-guard test"
    g "$d" config commit.gpgsign false
    # Pin line endings off. The CRLF fixture below depends on the working tree
    # holding exactly the bytes this script writes; autocrlf would rewrite them
    # on checkout and silently invalidate the most important comparison test.
    g "$d" config core.autocrlf false
    g "$d" config core.safecrlf false
    commit_all "$d" "init"
}

commit_all() {
    g "$1" add -A
    g "$1" commit -q --no-verify -m "$2"
}

# --- runners ----------------------------------------------------------------

# Each runner has a *_spelled twin that hands CLAUDE_DIR to install.ps1
# byte-for-byte, bypassing wp(): cygpath normalises paths, and section 12 needs
# a deliberately non-canonical spelling to reach the installer intact.
DOC_JSON=""
DOC_EXIT=0
doctor() {  # repo, claude_dir
    doctor_spelled "$1" "$(wp "$2")"
}
doctor_spelled() {  # repo, claude_dir exactly as install.ps1 receives it
    DOC_JSON="$(CLAUDE_DIR="$2" pwsh -NoProfile -File "$(wp "$1/scripts/install.ps1")" -Doctor -Json 2>/dev/null)"
    DOC_EXIT=$?
}

INSTALL_EXIT=0
INSTALL_OUT=""
install_run() {  # repo, claude_dir, extra args...
    local repo="$1" dir="$2"; shift 2
    install_spelled "$repo" "$(wp "$dir")" "$@"
}
install_spelled() {  # repo, claude_dir exactly as install.ps1 receives it, extra args...
    local repo="$1" dir="$2"; shift 2
    INSTALL_OUT="$(CLAUDE_DIR="$dir" pwsh -NoProfile -File "$(wp "$repo/scripts/install.ps1")" "$@" 2>&1)"
    INSTALL_EXIT=$?
}

jqd() { printf '%s' "$DOC_JSON" | jq -r "$1" 2>/dev/null; }

echo "=== claude-mods :: install guard + doctor ==="

# ---------------------------------------------------------------------------
# 1. THE MOST IMPORTANT TEST.
#    A branch that is merely AHEAD of an up-to-date main is the normal lane
#    workflow. If the guard fires here it will be deleted, so this must stay
#    silent even though HEAD != main and the branch touches skills/.
# ---------------------------------------------------------------------------
R1="$TMPROOT/ahead"; C1="$TMPROOT/ahead-dest"; mkdir -p "$C1"
new_repo "$R1"
g "$R1" switch -q -c feat/ahead
printf -- '---\nname: beta\ndescription: "beta"\n---\n\n# Beta\n' > "$R1/skills/alpha/extra.md"
commit_all "$R1" "feat(skills): add extra"
doctor "$R1" "$C1"
if [ "$(jqd '.data.staleness.status')" = "ok" ]; then
    pass "guard silent for a branch merely ahead of main (normal workflow)"
else
    fail "guard fired on an ahead-of-main branch: status=$(jqd '.data.staleness.status') reason=$(jqd '.data.staleness.reason')"
fi

# ---------------------------------------------------------------------------
# 2. The real failure: branch missing a main commit that touches skills/.
# ---------------------------------------------------------------------------
R2="$TMPROOT/behind"; C2="$TMPROOT/behind-dest"; mkdir -p "$C2"
new_repo "$R2"
g "$R2" branch lane/stale
printf -- '---\nname: alpha\ndescription: "alpha v2"\n---\n\n# Alpha v2\n' > "$R2/skills/alpha/SKILL.md"
commit_all "$R2" "feat(skills): land alpha v2"
g "$R2" switch -q lane/stale
doctor "$R2" "$C2"
if [ "$(jqd '.data.staleness.status')" = "behind" ]; then
    pass "guard fires for a branch missing a main commit touching skills/"
else
    fail "guard missed a real revert: status=$(jqd '.data.staleness.status')"
fi
if [ "$(jqd '.data.staleness.revertedFiles | index("skills/alpha/SKILL.md")')" != "null" ]; then
    pass "guard names the specific file that would be reverted"
else
    fail "guard did not name skills/alpha/SKILL.md; got $(jqd '.data.staleness.revertedFiles')"
fi

# ---------------------------------------------------------------------------
# 3. Behind main, but only on paths the installer never copies. Nothing can be
#    reverted, so the guard must stay silent.
# ---------------------------------------------------------------------------
R3="$TMPROOT/behind-noninstallable"; C3="$TMPROOT/bni-dest"; mkdir -p "$C3"
new_repo "$R3"
g "$R3" branch lane/docs
printf -- '# readme v2\n' > "$R3/README.md"
printf -- 'name: ci v2\n' > "$R3/.github/workflow.yml"
commit_all "$R3" "docs: update readme and ci"
g "$R3" switch -q lane/docs
doctor "$R3" "$C3"
if [ "$(jqd '.data.staleness.status')" = "ok" ]; then
    pass "guard silent when the missing main commit touches nothing installable"
else
    fail "guard fired on a README/.github-only commit: status=$(jqd '.data.staleness.status')"
fi

# ---------------------------------------------------------------------------
# 4. Install mode actually refuses, and writes nothing when it does. -Force
#    overrides.
# ---------------------------------------------------------------------------
C4="$TMPROOT/refuse-dest"; mkdir -p "$C4"
install_run "$R2" "$C4"
if [ "$INSTALL_EXIT" -eq 10 ]; then
    pass "install refuses a stale tree with exit 10"
else
    fail "stale install exited $INSTALL_EXIT, expected 10"
fi
if [ -z "$(ls -A "$C4")" ]; then
    pass "refused install wrote nothing to the target"
else
    fail "refused install left files behind: $(ls -A "$C4" | tr '\n' ' ')"
fi

C5="$TMPROOT/force-dest"; mkdir -p "$C5"
install_run "$R2" "$C5" -Force
if [ "$INSTALL_EXIT" -eq 0 ] && [ -f "$C5/skills/alpha/SKILL.md" ]; then
    pass "-Force overrides the guard and installs"
else
    fail "-Force did not install (exit $INSTALL_EXIT)"
fi

# ---------------------------------------------------------------------------
# 5. Doctor is clean immediately after a successful install.
# ---------------------------------------------------------------------------
R6="$TMPROOT/clean"; C6="$TMPROOT/clean-dest"; mkdir -p "$C6"
new_repo "$R6"
install_run "$R6" "$C6"
if [ "$INSTALL_EXIT" -ne 0 ]; then
    fail "baseline install failed (exit $INSTALL_EXIT); later assertions unreliable"
fi
doctor "$R6" "$C6"
if [ "$DOC_EXIT" -eq 0 ] && [ "$(jqd '.data.stale | length')" = "0" ] && [ "$(jqd '.data.missing | length')" = "0" ]; then
    pass "doctor reports clean immediately after install (exit 0)"
else
    fail "doctor dirty after a fresh install: exit=$DOC_EXIT stale=$(jqd '.data.stale') missing=$(jqd '.data.missing')"
fi

# ---------------------------------------------------------------------------
# 6. THE CRLF TRAP. Rewrite the repo's SKILL.md with CRLF endings and nothing
#    else. The installed copy stays LF. Identical content, different bytes -
#    the doctor must still call it clean.
# ---------------------------------------------------------------------------
to_crlf() {  # file -> rewrite in place with CRLF endings, content unchanged
    local f="$1"
    local tmp="$f.crlf"
    sed 's/$/\r/' "$f" > "$tmp" && mv "$tmp" "$f"
}
to_crlf "$R6/skills/alpha/SKILL.md"
if cmp -s "$R6/skills/alpha/SKILL.md" "$C6/skills/alpha/SKILL.md"; then
    fail "CRLF fixture is broken - the two files are still byte-identical"
else
    doctor "$R6" "$C6"
    if [ "$DOC_EXIT" -eq 0 ] && [ "$(jqd '.data.stale | length')" = "0" ]; then
        pass "doctor is not fooled by CRLF-vs-LF alone"
    else
        fail "doctor flagged a CRLF-only difference: stale=$(jqd '.data.stale')"
    fi
fi
# restore LF so the following assertions start from a known-clean state
tr -d '\r' < "$R6/skills/alpha/SKILL.md" > "$R6/skills/alpha/SKILL.md.lf"
mv "$R6/skills/alpha/SKILL.md.lf" "$R6/skills/alpha/SKILL.md"

# ---------------------------------------------------------------------------
# 7. stale / missing / orphan are three distinct states.
# ---------------------------------------------------------------------------
printf -- '# tampered\n' > "$C6/rules/demo.md"                    # stale
rm -f "$C6/agents/demo-expert.md"                                 # missing
mkdir -p "$C6/skills/ghost"
printf -- '# ghost\n' > "$C6/skills/ghost/SKILL.md"               # orphan
doctor "$R6" "$C6"
if [ "$(jqd '.data.stale | index("rules/demo.md")')" != "null" ]; then
    pass "doctor reports a changed installed file as stale"
else
    fail "doctor missed a stale file; stale=$(jqd '.data.stale')"
fi
if [ "$(jqd '.data.missing | index("agents/demo-expert.md")')" != "null" ]; then
    pass "doctor reports a repo file absent from the target as missing"
else
    fail "doctor missed a missing file; missing=$(jqd '.data.missing')"
fi
if [ "$(jqd '.data.orphan | index("skills/ghost/SKILL.md")')" != "null" ]; then
    pass "doctor reports a target-only file as orphan"
else
    fail "doctor missed an orphan; orphan=$(jqd '.data.orphan')"
fi
if [ "$DOC_EXIT" -eq 10 ]; then
    pass "doctor exits 10 when stale or missing content is found"
else
    fail "doctor exited $DOC_EXIT with stale+missing findings, expected 10"
fi

# An orphan on its own is informational - the installer deliberately keeps
# dest-only files - so it must NOT fail the exit code.
R8="$TMPROOT/orphan-only"; C8="$TMPROOT/orphan-only-dest"; mkdir -p "$C8"
new_repo "$R8"
install_run "$R8" "$C8"
mkdir -p "$C8/skills/local-only"
printf -- '# machine local\n' > "$C8/skills/local-only/SKILL.md"
doctor "$R8" "$C8"
if [ "$DOC_EXIT" -eq 0 ] && [ "$(jqd '.data.orphan | length')" != "0" ]; then
    pass "an orphan alone does not fail the doctor"
else
    fail "orphan-only run exited $DOC_EXIT (orphans=$(jqd '.data.orphan | length'))"
fi

# ---------------------------------------------------------------------------
# 8. Bracketed paths. `[` and `]` are PowerShell wildcard metacharacters, so an
#    enumeration using -Path silently skips a Next.js-style dynamic-route
#    fixture with no error at all (the 2026-08-31 skill-sync bug). A doctor with
#    that flaw is worse than useless: it reports CLEAN precisely because the
#    files it exists to notice are invisible to it. So assert the doctor SEES a
#    bracketed file, both when it is missing and when it is stale.
# ---------------------------------------------------------------------------
#    What matters is the ENUMERATION ROOT, not the child name: -Recurse walks
#    children through the provider, so a bracketed leaf is found either way, but
#    a bracketed ROOT (a worktree at `.../lane[1]/`) glob-expands to nothing and
#    the whole source side reads as empty. The install target is populated by
#    hand here rather than by install.ps1, so this isolates the doctor's own
#    enumeration from the installer's separate handling of bracketed paths.
RB="$TMPROOT/lane[1]"; CB="$TMPROOT/lane[1]-dest"
mkdir -p "$RB/scripts" "$RB/skills/alpha/assets/app/shop/[slug]" \
         "$RB/agents" "$RB/rules" "$RB/commands" "$RB/output-styles" "$RB/hooks"
cp "$ROOT/scripts/install.ps1" "$RB/scripts/install.ps1"
printf -- '---\nname: alpha\ndescription: "alpha"\n---\n\n# Alpha\n' > "$RB/skills/alpha/SKILL.md"
printf -- 'export default function Page() {}\n' > "$RB/skills/alpha/assets/app/shop/[slug]/page.tsx"
mkdir -p "$CB"
cp -r "$RB/skills" "$RB/agents" "$RB/rules" "$RB/commands" "$RB/output-styles" "$RB/hooks" "$CB/"
doctor "$RB" "$CB"
if [ "$DOC_EXIT" -eq 0 ] && [ "$(jqd '.data.orphan | length')" = "0" ]; then
    pass "doctor enumerates a bracketed repo root (clean, no phantom orphans)"
else
    fail "bracketed root not enumerated: exit=$DOC_EXIT orphan=$(jqd '.data.orphan | length') missing=$(jqd '.data.missing | length')"
fi
rm -f "$CB/skills/alpha/assets/app/shop/[slug]/page.tsx"
doctor "$RB" "$CB"
if [ "$(jqd '.data.missing | index("skills/alpha/assets/app/shop/[slug]/page.tsx")')" != "null" ]; then
    pass "doctor sees a deleted bracketed path under a bracketed root"
else
    fail "doctor is blind to bracketed paths; missing=$(jqd '.data.missing')"
fi

# ---------------------------------------------------------------------------
# 9. Contract surface: -Help, and the -Json/-Doctor usage error.
# ---------------------------------------------------------------------------
help_out="$(pwsh -NoProfile -File "$(wp "$R6/scripts/install.ps1")" -Help 2>/dev/null)"
help_exit=$?
if [ "$help_exit" -eq 0 ] && printf '%s' "$help_out" | grep -q 'EXAMPLES'; then
    pass "-Help exits 0 and documents EXAMPLES on stdout"
else
    fail "-Help exit=$help_exit or missing EXAMPLES section"
fi

pwsh -NoProfile -File "$(wp "$R6/scripts/install.ps1")" -Json >/dev/null 2>&1
if [ "$?" -eq 2 ]; then
    pass "-Json without -Doctor is a usage error (exit 2)"
else
    fail "-Json without -Doctor did not exit 2"
fi

# ---------------------------------------------------------------------------
# 10. Degradation: a source tree that is not a git repo must still install.
# ---------------------------------------------------------------------------
R9="$TMPROOT/nogit"; C9="$TMPROOT/nogit-dest"; mkdir -p "$C9"
new_repo "$R9"
rm -rf "$R9/.git"
install_run "$R9" "$C9"
if [ "$INSTALL_EXIT" -eq 0 ] && [ -f "$C9/skills/alpha/SKILL.md" ]; then
    pass "a non-git source tree degrades to a warning and still installs"
else
    fail "non-git tree failed to install (exit $INSTALL_EXIT)"
fi
doctor "$R9" "$C9"
if [ "$(jqd '.data.staleness.status')" = "unknown" ]; then
    pass "doctor reports staleness 'unknown' outside a git repo"
else
    fail "expected staleness unknown outside git, got $(jqd '.data.staleness.status')"
fi

# ---------------------------------------------------------------------------
# 11. Bracketed paths, INSTALL side. Section 8 proved the doctor sees them;
#     this proves the installer actually copies. The top-level enumeration roots
#     ($projectRoot/skills, /agents, /rules, ...) and the CLAUDE_DIR target both
#     come from bracket-prone locations - a git worktree at `.../lane[1]/` is the
#     realistic one - and a -Path loop over a bracketed root returns an EMPTY set
#     with no error. The installer then prints its whole banner, every section
#     header, exits 0, and installs nothing at all.
#
#     So the assertion is content, not exit code: exit 0 is exactly what the
#     broken installer produces. Revert any one -LiteralPath in install.ps1 to
#     -Path and this section must go red - a bracket test that passes either way
#     is worthless, which is the mistake section 8 was corrected for.
# ---------------------------------------------------------------------------
RI="$TMPROOT/inst[2]"; CI="$TMPROOT/inst[2]-dest"; mkdir -p "$CI"
new_repo "$RI"
install_run "$RI" "$CI"
if [ "$INSTALL_EXIT" -eq 0 ]; then
    pass "install from a bracketed repo root exits 0"
else
    fail "install from a bracketed root exited $INSTALL_EXIT"
fi
# One assertion per top-level loop: each has its own Get-ChildItem root, so a
# single missed -LiteralPath silences exactly one of these and nothing else.
for landed in \
    "skills/alpha/SKILL.md" \
    "agents/demo-expert.md" \
    "rules/demo.md" \
    "commands/demo.md" \
    "output-styles/demo.md" \
    "hooks/demo.sh"
do
    if [ -f "$CI/$landed" ]; then
        pass "bracketed-root install landed $landed"
    else
        fail "bracketed-root install did NOT land $landed (silent no-op)"
    fi
done
# The doctor agreeing is the cross-check: a broken installer plus a doctor that
# also cannot see the target would both report clean and cancel each other out.
doctor "$RI" "$CI"
if [ "$DOC_EXIT" -eq 0 ] && [ "$(jqd '.data.missing | length')" = "0" ]; then
    pass "doctor confirms a bracketed-root install is complete"
else
    fail "doctor found gaps after a bracketed-root install: missing=$(jqd '.data.missing')"
fi

# ---------------------------------------------------------------------------
# 12. A non-canonical spelling of the install target. The FileSystem provider
#     returns children under ITS canonical spelling of a root, so relative paths
#     cut by string length against the caller's spelling shift silently. This is
#     why this suite failed on every GitHub Windows run while passing locally:
#     the runner's %TEMP% sits under the 8.3 short name RUNNER~1, three
#     characters shorter than the canonical account name, so an
#     installed skills/alpha/SKILL.md read back as skills/ls/alpha/SKILL.md -
#     "missing" and "orphan" at once, on every run.
#
#     8.3 names can be disabled per volume (they often are on dev drives, which
#     is how the bug hid), so this section uses a `..` segment instead: it is
#     non-canonical on every volume and every OS. Before the fix, both the
#     doctor AND the installer's dest-only report went wrong here.
# ---------------------------------------------------------------------------
RN="$TMPROOT/noncanon"; CN="$TMPROOT/noncanon-dest"
mkdir -p "$CN" "$TMPROOT/decoy"
new_repo "$RN"
if command -v cygpath >/dev/null 2>&1; then
    CN_SPELLED="$(wp "$TMPROOT")\\decoy\\..\\noncanon-dest"
else
    CN_SPELLED="$TMPROOT/decoy/../noncanon-dest"
fi
# First install takes the fresh-directory copy; the second takes the merge-copy
# branch, whose dest-only report is one of the two sites under test.
install_spelled "$RN" "$CN_SPELLED"
install_spelled "$RN" "$CN_SPELLED"
if [ "$INSTALL_EXIT" -eq 0 ] && ! printf '%s' "$INSTALL_OUT" | grep -qiE 'dest-only|failed'; then
    pass "re-install via a non-canonical target path reports no phantom dest-only files"
else
    fail "re-install via '$CN_SPELLED' exited $INSTALL_EXIT or misreported: $(printf '%s' "$INSTALL_OUT" | grep -iE 'dest-only|failed|^ +[^ ]' | head -5 | tr '\n' '|')"
fi
doctor_spelled "$RN" "$CN_SPELLED"
if [ "$DOC_EXIT" -eq 0 ] && [ "$(jqd '.data.missing | length')" = "0" ] && [ "$(jqd '.data.orphan | length')" = "0" ]; then
    pass "doctor is clean via a non-canonical target path (no phantom missing/orphan)"
else
    fail "doctor misread a non-canonical target: exit=$DOC_EXIT missing=$(jqd '.data.missing') orphan=$(jqd '.data.orphan')"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "install-guard: all assertions passed"
else
    echo "install-guard: FAILURES above"
fi
exit "$FAIL"
