#!/usr/bin/env bash
# Self-test for claude-api-ops — fully offline: no network, no Anthropic API.
#
# Wraps the skill's §7 staleness verifier (scripts/check-model-table.py), which
# guards the two fast-moving fact tables (SKILL.md "Current Models" and
# references/caching-and-cost.md cache-minimums) against silent drift. Contract
# (py_compile + --help), offline happy path against the shipped skill, the
# --json §7 envelope, and a NEGATIVE proving the verifier actually rejects a bad
# model id (a date-suffixed alias — exactly what SKILL.md forbids). --live is
# NEVER invoked: it hits the Models API, and a network blip must never fail a PR.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
V="$SKILL/scripts/check-model-table.py"

# Pick a python that actually executes (the Windows Store python3 stub exists
# on PATH but exits non-zero; probe by running it).
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

echo "=== claude-api-ops self-test ==="

if [[ -z "$PYTHON" ]]; then
  echo "  SKIP  no working python (verifier is python) — cannot test"
  [[ "$FAIL" -eq 0 ]] || exit 1
  exit 0
fi

# ── contract ──────────────────────────────────────────────────────────────────
echo "-- contract --"
"$PYTHON" -m py_compile "$V" 2>/dev/null && ok "py_compile check-model-table.py" || no "py_compile check-model-table.py"
"$PYTHON" "$V" --help >/dev/null 2>&1; expect_exit "--help exits 0" 0 $?
out="$("$PYTHON" "$V" --help 2>&1)"
expect_has "--help has EXAMPLES" "EXAMPLES" "$out"
"$PYTHON" "$V" --bogus >/dev/null 2>&1; expect_exit "unknown flag -> 2" 2 $?

# ── offline structural mode (§7 seam: --offline default, --live advisory) ─────
echo "-- offline structural --"
"$PYTHON" "$V" --offline >/dev/null 2>&1; expect_exit "--offline clean on shipped skill" 0 $?
out="$("$PYTHON" "$V" --offline --json 2>/dev/null)"
expect_has "--offline --json envelope schema" '"schema": "claude-mods.claude-api-ops.model-table/v1"' "$out"
expect_has "--offline --json consistent" '"consistent": true' "$out"

# ── negative: a date-suffixed alias must be rejected (exit 4 VALIDATION) ──────
# Run the verifier from a doctored copy; never mutate the shipped skill.
echo "-- negative --"
cp -r "$SKILL" "$SB/copy"
# Append the date suffix SKILL.md explicitly forbids ("Never append date
# suffixes"). The verifier's DATE_SUFFIX_RE must flag it as VALIDATION drift.
# Target the table cell uniquely (the prose never pairs "Opus 4.8 |" with the
# backticked id) so the edit is surgical.
"$PYTHON" - "$SB/copy/SKILL.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
t = t.replace("Opus 4.8 | `claude-opus-4-8`", "Opus 4.8 | `claude-opus-4-8-20251114`")
p.write_text(t, encoding="utf-8")
PY
"$PYTHON" "$SB/copy/scripts/check-model-table.py" --offline >"$SB/neg.out" 2>&1
expect_exit "--offline flags date-suffixed id -> 4" 4 $?
expect_has "finding names the date suffix" "date suffix" "$(cat "$SB/neg.out")"

# ── context-engineering layer (offline cross-file tripwires) ─────────────────
# The verifier also guards the cache-economics constants that are now stated in
# more than one file, the verification date stamps on the doctrine references,
# and SKILL.md <-> references/ citation integrity. Each gets a NEGATIVE below:
# a passing check proves nothing unless it can be made to fail.
echo "-- context-engineering checks --"
out="$("$PYTHON" "$V" --offline --json -q 2>/dev/null)"
expect_has "--json reports cache_constants" '"cache_constants"' "$out"
expect_has "--json reports date_stamps" '"date_stamps"' "$out"
expect_has "--json reports reference_files" '"reference_files"' "$out"
expect_has "--json names the context-management beta" 'context-management-2025-06-27' "$out"

# Fresh sandbox copy per negative: validate_offline runs the model-table checks
# BEFORE these, so a copy poisoned by an earlier negative would exit 4 on the
# wrong finding and the assertion would pass for the wrong reason.
n=0
fresh_copy() { n=$((n+1)); rm -rf "$SB/c$n"; cp -r "$SKILL" "$SB/c$n"; echo "$SB/c$n"; }

# NEGATIVE 1: desync a cache constant in exactly one file (0.1x -> 0.15x in
# compaction.md). The real drift this guards: someone updates a multiplier in
# the doc they happen to be editing and leaves the other three stale.
C="$(fresh_copy)"
"$PYTHON" - "$C/references/compaction.md" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8")
# Cover every spelling the verifier's pattern accepts: "0.1x", "0.1×", "0.1 ×".
p.write_text(re.sub(r"0\.1(\s*)([x×])", r"0.15\1\2", t), encoding="utf-8")
PY
"$PYTHON" "$C/scripts/check-model-table.py" --offline >"$SB/n1.out" 2>&1
expect_exit "desynced cache multiplier -> 4" 4 $?
expect_has "finding names the constant" "cache_read_multiplier" "$(cat "$SB/n1.out")"

# NEGATIVE 2: strip the verification date stamp from a doctrine reference.
C="$(fresh_copy)"
"$PYTHON" - "$C/references/context-engineering.md" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text(encoding="utf-8")
p.write_text(re.sub(r"(?i)verified", "checked", t), encoding="utf-8")
PY
"$PYTHON" "$C/scripts/check-model-table.py" --offline >"$SB/n2.out" 2>&1
expect_exit "missing verification date stamp -> 4" 4 $?
expect_has "finding names the undated file" "context-engineering.md" "$(cat "$SB/n2.out")"

# NEGATIVE 3: an uncited reference file (dead weight the router never finds --
# SKILL-RESOURCE-PROTOCOL.md §1).
C="$(fresh_copy)"
printf '# orphan\n' > "$C/references/orphan-doc.md"
"$PYTHON" "$C/scripts/check-model-table.py" --offline >"$SB/n3.out" 2>&1
expect_exit "uncited reference file -> 4" 4 $?
expect_has "finding names the orphan" "orphan-doc.md" "$(cat "$SB/n3.out")"

# NEGATIVE 4: a cited-but-missing reference (broken link in SKILL.md).
C="$(fresh_copy)"
rm -f "$C/references/compaction.md"
"$PYTHON" "$C/scripts/check-model-table.py" --offline >"$SB/n4.out" 2>&1
expect_exit "cited-but-missing reference -> 4" 4 $?

# ── SKILL.md sanity ───────────────────────────────────────────────────────────
echo "-- SKILL.md --"
# CONTRACT (frontmatter shape): this suite asserts that SKILL.md's frontmatter
# keeps `name: claude-api-ops` and a `when_to_use:` field, and that
# len(description) + len(when_to_use) stays within the repo's 1000-char per-skill
# cap enforced by tests/validate.sh. A description-trim or frontmatter cleanup
# lane that removes `when_to_use` from this skill WILL break CI here -- that is
# deliberate, and stated here so the edit site is not the first place you find out.
grep -q '^name: claude-api-ops$' "$SKILL/SKILL.md" && ok "frontmatter name" || no "frontmatter name"
grep -q '^when_to_use: ' "$SKILL/SKILL.md" && ok "frontmatter when_to_use present" || no "frontmatter when_to_use present"
grep -q 'check-model-table.py' "$SKILL/SKILL.md" && ok "verifier cited from SKILL.md" || no "verifier cited from SKILL.md"

# Description budget: mirrors tests/validate.sh's hard cap so this skill fails
# in its own suite rather than only in the catalog-wide gate.
combined="$("$PYTHON" - "$SKILL/SKILL.md" <<'PY'
import pathlib, re, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
fm = t.split("---")[1]
def field(k):
    m = re.search(r'^%s: "(.*)"$' % k, fm, re.M)
    return m.group(1) if m else ""
print(len(field("description")) + len(field("when_to_use")))
PY
)"
if [[ "$combined" -gt 0 && "$combined" -le 1000 ]]; then
  ok "description + when_to_use within 1000-char cap ($combined)"
else
  no "description + when_to_use out of range (got '$combined', cap 1000)"
fi

# Body-size limit: SKILL-CREATION-PROTOCOL.md Step 3 caps the body at 500 lines;
# depth belongs in references/*.md.
lines="$(wc -l < "$SKILL/SKILL.md" | tr -d ' ')"
[[ "$lines" -lt 500 ]] && ok "SKILL.md body under 500 lines ($lines)" \
                       || no "SKILL.md body is $lines lines (limit 500)"

# The context-engineering content itself is cited and reachable.
echo "-- context-engineering content --"
grep -q '^## Context Engineering$' "$SKILL/SKILL.md" \
  && ok "Context Engineering section present" || no "Context Engineering section present"
for r in context-engineering compaction; do
  [[ -f "$SKILL/references/$r.md" ]] && ok "references/$r.md exists" || no "references/$r.md exists"
  grep -q "(references/$r.md)" "$SKILL/SKILL.md" \
    && ok "references/$r.md cited from SKILL.md" || no "references/$r.md cited from SKILL.md"
done
# The load-bearing, counter-intuitive claim must survive edits: compaction is a
# response to a NAMED constraint, not a default.
grep -qi 'named constraint' "$SKILL/references/compaction.md" \
  && ok "compaction doctrine states the named-constraint rule" \
  || no "compaction doctrine states the named-constraint rule"
grep -q 'clear_at_least' "$SKILL/references/compaction.md" \
  && ok "context_management params documented" || no "context_management params documented"
# The three tiers are the spine of the doctrine reference.
grep -q 'Tier 1' "$SKILL/references/context-engineering.md" \
  && ok "three-tier model documented" || no "three-tier model documented"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
