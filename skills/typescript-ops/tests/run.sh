#!/usr/bin/env bash
# Self-test for the typescript-ops skill.
#
# Offline-deterministic (no network, no TypeScript compiler required). Asserts
# structural integrity (frontmatter, references present + linked) and — the
# load-bearing check — the staleness verifier contract (SKILL-RESOURCE-PROTOCOL
# §7, §10): the catalogued version-bearing facts (TypeScript major, zod,
# valibot) stay named in the prose and the dated currency note stays present.
# Resolves paths relative to itself so it works in the repo and once installed
# to ~/.claude/skills/typescript-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
DOC="$SKILL/SKILL.md"
REF="$SKILL/references"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
has() { case "$2" in *"$1"*) ok "$3";; *) no "$3 (missing '$1')";; esac; }

echo "=== typescript-ops self-test ==="

# ── SKILL.md frontmatter ───────────────────────────────────────────────────
echo "-- frontmatter --"
[[ -f "$DOC" ]] && ok "SKILL.md present" || { no "SKILL.md missing"; echo "=== $PASS passed, $FAIL failed ==="; exit 1; }
[[ "$(sed -n '1p' "$DOC")" == "---" ]] && ok "frontmatter fence opens at line 1" || no "no opening frontmatter fence"
doc="$(cat "$DOC")"
has 'name: typescript-ops' "$doc" "frontmatter declares name: typescript-ops"
has 'description:'        "$doc" "frontmatter has description"
has 'license: MIT'        "$doc" "frontmatter declares license"
has 'author: claude-mods' "$doc" "frontmatter declares metadata.author"

# ── references: the 5 documented files exist ───────────────────────────────
echo "-- references present --"
EXPECT=(type-system utility-types generics-patterns config-strict ecosystem)
for r in "${EXPECT[@]}"; do
  f="$REF/$r.md"
  [[ -f "$f" ]] && ok "$r.md present" || no "$r.md missing"
done

# ── every references/ citation in SKILL.md resolves (no ghost refs) ────────
# typescript-ops cites its references as inline code spans (`./references/x.md`),
# not markdown links — extract those spans and confirm each file exists.
echo "-- cited references resolve --"
linked=0; broken=0
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  linked=$((linked+1))
  [[ -f "$SKILL/$rel" ]] || { no "SKILL.md cites missing file: $rel"; broken=$((broken+1)); }
done < <(grep -oE '`(\./)?references/[^`#]+\.md`' "$DOC" | sed -E 's/^`//; s/`$//; s/^\.\///' | sort -u)
[[ "$linked" -gt 0 ]] && ok "SKILL.md cites its references ($linked unique)" || no "SKILL.md cites no references"
[[ "$broken" -eq 0 ]] && ok "all cited reference files resolve" || no "$broken reference citation(s) broken"

# ── dated currency note present (verifier depends on it) ───────────────────
echo "-- currency note --"
grep -qE 'as of 20[0-9]{2}' "$DOC" && ok "dated 'as of 20XX' currency note present" || no "no dated currency note"

# ── staleness verifier: offline contract (SKILL-RESOURCE-PROTOCOL §7) ───────
echo "-- check-typescript-facts.py (offline) --"
VERIFIER="$SKILL/scripts/check-typescript-facts.py"
CATALOG="$SKILL/assets/typescript-facts.json"
ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
       [[ "$got" == "$want" ]] && ok "$lbl (exit $got)" || no "$lbl (want $want got $got)"; }
# Pick a python that actually executes — skips the Windows Store python3 stub.
PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -f "$VERIFIER" ]] && ok "verifier present" || no "verifier missing"
[[ -f "$CATALOG"  ]] && ok "facts catalog present" || no "catalog missing"
has "scripts/check-typescript-facts.py" "$doc" "verifier cited from SKILL.md"
if [[ -n "$PY" ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ec 0 "py_compile"            "$PY" -m py_compile "$VERIFIER"
  ec 0 "--help"                "$PY" "$VERIFIER" --help
  ec 0 "--offline consistent"  "$PY" "$VERIFIER" --offline
  ec 2 "bad flag -> 2"         "$PY" "$VERIFIER" --bogus
  ec 2 "conflicting modes -> 2" "$PY" "$VERIFIER" --offline --live
  jout="$("$PY" "$VERIFIER" --offline --json 2>/dev/null)"
  has 'claude-mods.typescript-ops.facts/v1' "$jout" "--json envelope schema"
  ec 3 "missing catalog -> 3"  "$PY" "$VERIFIER" --offline --catalog "$TMP/nope.json"
  printf '{"packages":"x"}' > "$TMP/bad.json"
  ec 4 "malformed catalog -> 4" "$PY" "$VERIFIER" --offline --catalog "$TMP/bad.json"
  printf '{"packages":[{"name":"zzznotreal","documented_major":3}]}' > "$TMP/drift.json"
  ec 10 "uncited package -> 10" "$PY" "$VERIFIER" --offline --catalog "$TMP/drift.json"
else
  no "no working python to exercise the verifier"
fi

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
