#!/usr/bin/env bash
# repo-doctor behavioural suite — offline, self-contained.
#
# Builds a throwaway git repo seeded with known defects (no entry doc → then a
# weak one, monster file, un-indexed docs/, root junk, no tests/check), runs
# scripts/repo-doctor.py --json against it, and asserts each defect is detected
# and the envelope schema holds. Then seeds the fixes and asserts the grade
# improves and findings clear. Exit 0 = all pass, 1 = failure, 0 + skip message
# when python3/git are unavailable.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$HERE/../scripts/repo-doctor.py"

# Windows: `python3` on PATH is often the Microsoft Store shim, which prints an
# install nag and exits nonzero. A candidate only counts if it actually RUNS.
PY=""
for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 \
            && "$cand" -c "import sys" >/dev/null 2>&1; then
        PY="$cand"; break
    fi
done

if [ -z "$PY" ] || ! command -v git >/dev/null 2>&1; then
    echo "SKIP: working python/git not available"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---- fixture: a repo with seeded defects ------------------------------------
cd "$TMP" || exit 1
git init -q -b main .
git config user.email t@t.local; git config user.name t

mkdir -p src docs
# monster file: 1600 lines, no contract block, no section markers
"$PY" -c "print('\n'.join('x = %d' % i for i in range(1600)))" > src/monster.py
# 8 docs, no index
for i in 1 2 3 4 5 6 7 8; do echo "# doc $i" > "docs/d$i.md"; done
# root junk: scratch-pattern file + fake >1MB media
echo x > tmp_probe.py
"$PY" -c "open('scratch.png','wb').write(b'0'*1100000)"
git add -A; git commit -qm "feat: seed"

run_json() { "$PY" "$DOCTOR" --repo "$TMP" --json 2>/dev/null; }

OUT="$(run_json)"
get() { echo "$OUT" | "$PY" -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

# 1. envelope schema
[ "$(get '"ok" if d["meta"]["schema"]=="claude-mods.repo-doctor/v1" else "no"')" = "ok" ] \
    && ok "envelope carries repo-doctor/v1 schema" || no "schema" "$(get 'd["meta"]')"

# 2. missing entry doc is a crit, entry_docs scores 0
[ "$(get 'd["data"]["scores"]["entry_docs"]')" = "0" ] \
    && ok "missing AGENTS.md scores entry_docs=0" \
    || no "missing entry doc" "score=$(get 'd["data"]["scores"]["entry_docs"]')"

# 3. monster file detected as crit with path
[ "$(get 'sum(1 for f in d["data"]["findings"] if f["severity"]=="crit" and "monster.py" in f["path"])')" = "1" ] \
    && ok "1600-line file flagged crit" || no "monster detection" "not found"

# 4. un-indexed docs/ flagged
[ "$(get 'sum(1 for f in d["data"]["findings"] if "no index" in f["msg"])')" = "1" ] \
    && ok "8-file docs/ without index flagged" || no "docs index" "not flagged"

# 5. root junk flagged (both scratch pattern and big media)
[ "$(get 'sum(1 for f in d["data"]["findings"] if "repo-root junk" in f["msg"])')" = "1" ] \
    && ok "root junk flagged" || no "root junk" "not flagged"

# 6. no check entry point flagged
[ "$(get 'sum(1 for f in d["data"]["findings"] if "check" in f["msg"] and "entry point" in f["msg"])')" = "1" ] \
    && ok "missing check entry point flagged" || no "check entry" "not flagged"

# 7. strict mode gates: low grade → exit 10
"$PY" "$DOCTOR" --repo "$TMP" --strict >/dev/null 2>&1
[ $? -eq 10 ] && ok "--strict exits 10 below grade B" || no "--strict" "exit $?"

# ---- seed the fixes, assert improvement --------------------------------------
cat > AGENTS.md <<'EOF'
# Agent Instructions — fixture
Tiny fixture repo for the repo-doctor suite.
## Commands
just check
## Landmines
1. **monster.py is generated-style filler** — never hand-edit, regenerate via tests.
## Structure
| src/ | code |
EOF
cat > docs/00_INDEX.md <<'EOF'
# Docs Index
> Maintenance: update in the same commit as any docs/ change.
| [d1.md](d1.md) | doc |
EOF
rm tmp_probe.py scratch.png
mkdir -p tests .github/workflows
echo "echo ok" > tests/run.sh
echo "name: ci" > .github/workflows/ci.yml
printf 'check:\n\techo ok\n' > Makefile
# generated-marker on the monster: exempts it from the monster penalty
{ echo "# @generated — filler fixture, do not edit"; cat src/monster.py; } > src/m2 \
    && mv src/m2 src/monster.py
git add -A; git commit -qm "fix: remediate per repo-doctor + docs: index"

OUT="$(run_json)"
# 8. entry_docs recovers (presence+landmines+lean; freshness=commit 0 lag)
ENT="$(get 'd["data"]["scores"]["entry_docs"]')"
"$PY" -c "exit(0 if float('$ENT')>=4 else 1)" \
    && ok "remediated entry_docs >= 4 (got $ENT)" || no "entry recovery" "$ENT"

# 9. generated marker exempts the monster
[ "$(get 'sum(1 for f in d["data"]["findings"] if "monster.py" in f["path"] and f["severity"]=="crit")')" = "0" ] \
    && ok "@generated header exempts monster file" || no "generated exempt" "still crit"

# 10. grade improved to A/B and --strict passes
GR="$(get 'd["data"]["grade"]')"
"$PY" "$DOCTOR" --repo "$TMP" --strict >/dev/null 2>&1 \
    && ok "remediated repo passes --strict (grade $GR)" || no "strict pass" "grade $GR exit $?"

echo
echo "repo-doctor tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
