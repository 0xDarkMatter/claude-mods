#!/usr/bin/env bash
# Skill hygiene gate: a ratchet against new orphan side files, related-skills the body never
# names, scripts run relative to the cwd, and duplicate metadata.owns tokens.
#
# Why: each is a way a skill silently stops working as written. An unnamed reference is
# never loaded; a related skill listed only in frontmatter is never handed off to (the model
# does not see metadata); `python scripts/x.py` run from a project root exits 127 or runs
# the project's own script (docker/skills #102); two skills owning one topic misroute.
# Debt that predates the gate lives in tests/skill-hygiene-baseline.txt and may only shrink.
# The logic is in tests/skill-hygiene.py; its docstring explains each check.
#
# Modes:
#   bash tests/skill-hygiene.sh              the gate
#   bash tests/skill-hygiene.sh --report     also list every current violation
#
# Every run first proves the gate can see: a self-test builds a throwaway skills tree and
# must flag each violation, accept a matching baseline, and fail on a stale baseline line
# and on a duplicate owns token.
#
# Exit 0 = no new violations, 1 = new violations / stale baseline lines / duplicate owns,
# 2 = the gate itself is broken (no Python, self-test failed).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/tests/skill-hygiene.py"

PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "skill-hygiene: no working python, cannot run the gate" >&2; exit 2; }

selftest_fail() { echo "skill-hygiene: self-test failed - $1; the gate cannot be trusted" >&2; exit 2; }

tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/skill-hygiene.$$")"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# === self-test: a tree with one of each violation ===
mk() { mkdir -p "$(dirname "$tmp/skills/$1")"; printf '%s\n' "$2" > "$tmp/skills/$1"; }
mk alpha-ops/SKILL.md $'---\nname: alpha-ops\ndescription: "x"\nmetadata:\n  owns: "widgets"\n  related-skills: "beta-ops"\n---\n# Alpha\nHands off to beta-ops. Read references/guide.md, then run:\n    python "<skill-dir>/scripts/tool.py"'
mk alpha-ops/references/guide.md '# Guide'
mk alpha-ops/scripts/tool.py 'print(1)'
mk beta-ops/SKILL.md $'---\nname: beta-ops\ndescription: "x"\nmetadata:\n  owns: "gadgets"\n  related-skills: "alpha-ops, ghost-ops"\n---\n# Beta\nSee alpha-ops. Run `python scripts/run.py --all`.'
mk beta-ops/scripts/run.py 'print(2)'
mk beta-ops/references/unnamed.md '# Never linked'
: > "$tmp/baseline.txt"
out="$("$PY" "$GATE" --skills "$tmp/skills" --baseline "$tmp/baseline.txt" 2>/dev/null)"; rc=$?
[ "$rc" = "1" ] || selftest_fail "a tree with violations exited $rc, not 1"
for want in $'NEW\tbeta-ops\torphan-side-file\treferences/unnamed.md' \
            $'NEW\tbeta-ops\trelated-not-named\tghost-ops' \
            $'NEW\tbeta-ops\trelative-script-call\tscripts/run.py'; do
    case "$out" in *"$want"*) ;; *) selftest_fail "missed: $want" ;; esac
done
case "$out" in *alpha-ops*) selftest_fail "flagged the clean alpha-ops" ;; esac
printf 'beta-ops\torphan-side-file\treferences/unnamed.md\nbeta-ops\trelated-not-named\tghost-ops\nbeta-ops\trelative-script-call\tscripts/run.py\n' > "$tmp/baseline.txt"
"$PY" "$GATE" --skills "$tmp/skills" --baseline "$tmp/baseline.txt" >/dev/null 2>&1 \
    || selftest_fail "a baseline listing every violation did not pass"
printf 'alpha-ops\torphan-side-file\treferences/gone.md\n' >> "$tmp/baseline.txt"
out="$("$PY" "$GATE" --skills "$tmp/skills" --baseline "$tmp/baseline.txt" 2>/dev/null)"; rc=$?
[ "$rc" = "1" ] || selftest_fail "a stale baseline line exited $rc, not 1"
case "$out" in *$'FIXED\talpha-ops\torphan-side-file\treferences/gone.md'*) ;; *) selftest_fail "stale line not reported" ;; esac
sed -i.bak '$d' "$tmp/baseline.txt"
mk beta-ops/SKILL.md $'---\nname: beta-ops\ndescription: "x"\nmetadata:\n  owns: "widgets"\n  related-skills: "alpha-ops, ghost-ops"\n---\n# Beta\nSee alpha-ops. Run `python scripts/run.py --all`.'
out="$("$PY" "$GATE" --skills "$tmp/skills" --baseline "$tmp/baseline.txt" 2>/dev/null)"; rc=$?
[ "$rc" = "1" ] || selftest_fail "a duplicate owns token exited $rc, not 1"
case "$out" in *$'DUPLICATE\towns\twidgets'*) ;; *) selftest_fail "duplicate owns not reported" ;; esac

# === the gate ===
"$PY" "$GATE" "$@"
