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

# NEGATIVE 5: an uncited script/asset (same protocol rule as references, but
# those are cited by basename in prose rather than by markdown link).
C="$(fresh_copy)"
printf '# orphan\n' > "$C/assets/orphan-asset.py"
"$PYTHON" "$C/scripts/check-model-table.py" --offline >"$SB/n5.out" 2>&1
expect_exit "uncited asset -> 4" 4 $?
expect_has "finding names the uncited asset" "orphan-asset.py" "$(cat "$SB/n5.out")"

# ── context-budget calculator ────────────────────────────────────────────────
# The doctrine's break-even arithmetic, executable. Its VERDICT is the contract:
# exit 0 = append wins, exit 10 = cost favours compaction. Both directions are
# asserted, because a calculator that can only say one thing is not a calculator.
echo "-- context-budget --"
CB="$SKILL/scripts/context-budget.py"
"$PYTHON" -m py_compile "$CB" 2>/dev/null && ok "py_compile context-budget.py" || no "py_compile context-budget.py"
"$PYTHON" "$CB" --help >/dev/null 2>&1; expect_exit "context-budget --help exits 0" 0 $?
expect_has "context-budget --help has EXAMPLES" "EXAMPLES" "$("$PYTHON" "$CB" --help 2>&1)"
"$PYTHON" "$CB" --bogus >/dev/null 2>&1; expect_exit "context-budget unknown flag -> 2" 2 $?

# Short session: the doctrine's default answer. Must be exit 0 (append).
"$PYTHON" "$CB" --history-tokens 25000 --turns-remaining 5 --base-rate 0.30 -q >/dev/null 2>&1
expect_exit "short session -> append (0)" 0 $?
# Deep session: enough remaining turns to repay the rewrite. Must be exit 10.
"$PYTHON" "$CB" --history-tokens 120000 --turns-remaining 40 --base-rate 2.00 -q >/dev/null 2>&1
expect_exit "deep session -> compaction indicated (10)" 10 $?
# Context ceiling binds regardless of cost.
"$PYTHON" "$CB" --history-tokens 900000 --turns-remaining 10 --growth-per-turn 50000 \
  --context-window 1000000 -q >/dev/null 2>&1
expect_exit "context ceiling -> 10" 10 $?

out="$("$PYTHON" "$CB" --history-tokens 25000 --turns-remaining 5 --base-rate 0.30 --json -q 2>/dev/null)"
expect_has "context-budget --json envelope schema" '"schema": "claude-mods.claude-api-ops.context-budget/v1"' "$out"
expect_has "context-budget --json verdict" '"verdict": "append"' "$out"
# The recall caveat must ride along in the machine-readable output: an agent
# acting on the verdict alone would otherwise treat "cheaper" as "better".
expect_has "context-budget --json carries the recall caveat" 'recall loss' "$out"

# Input validation (resource protocol §6 - agents fabricate plausible inputs).
for bad in "--history-tokens -5 --turns-remaining 10" \
           "--history-tokens 1000 --turns-remaining -1" \
           "--history-tokens 1000 --turns-remaining 5 --base-rate 0" \
           "--history-tokens 1000 --turns-remaining 5 --summary-tokens 5000"; do
  "$PYTHON" "$CB" $bad >/dev/null 2>&1
  expect_exit "rejects bad input ($bad)" 4 $?
done

# ── cache-correct loop asset ─────────────────────────────────────────────────
# The asset's only real logic is breakpoint placement, and getting it wrong is
# silent (a missed cache costs money and raises no error). Exercise it directly
# with the anthropic SDK stubbed out - no network, no SDK install needed.
echo "-- cached-agent-loop --"
"$PYTHON" -m py_compile "$SKILL/assets/cached-agent-loop.py" 2>/dev/null \
  && ok "py_compile cached-agent-loop.py" || no "py_compile cached-agent-loop.py"
"$PYTHON" -m py_compile "$SKILL/assets/recall-probe.py" 2>/dev/null \
  && ok "py_compile recall-probe.py" || no "py_compile recall-probe.py"

"$PYTHON" - "$SKILL/assets/cached-agent-loop.py" >"$SB/bp.out" 2>&1 <<'PY'
import sys, types, importlib.util
stub = types.ModuleType("anthropic"); stub.Anthropic = lambda *a, **k: None
sys.modules["anthropic"] = stub
spec = importlib.util.spec_from_file_location("loop", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def marks(msgs):
    return [(i, j) for i, msg in enumerate(msgs)
            for j, b in enumerate(msg["content"])
            if isinstance(b, dict) and "cache_control" in b]

# The newest turn must always carry a breakpoint, or hits never accrue.
msgs = [{"role": "user", "content": [{"type": "text", "text": "hi"}]}]
m.place_message_breakpoints(msgs)
assert marks(msgs) == [(0, 0)], f"short: {marks(msgs)}"

# A tool-heavy turn appending 40 blocks must not exceed the API's 4-breakpoint
# limit (one is spent on the system block) and must keep consecutive anchors
# inside the 20-block backward search, or the lookback silently misses.
msgs = [{"role": "user", "content": [{"type": "text", "text": f"b{i}"} for i in range(40)]}]
m.place_message_breakpoints(msgs)
got = marks(msgs)
assert len(got) <= m.MAX_BREAKPOINTS - 1, f"too many breakpoints: {got}"
assert got[-1] == (0, 39), f"newest block unmarked: {got}"
gaps = [got[i + 1][1] - got[i][1] for i in range(len(got) - 1)]
assert all(g <= m.LOOKBACK_BLOCKS for g in gaps), f"anchor gap exceeds lookback: {gaps}"
assert m.BREAKPOINT_EVERY < m.LOOKBACK_BLOCKS, "anchor spacing must fit the window"

# Idempotent: called every turn, it must not accumulate stale markers.
before = marks(msgs); m.place_message_breakpoints(msgs)
assert marks(msgs) == before, "not idempotent"

# Tool output is capped at the boundary (the cache-preserving lever).
assert len(m.capped("x" * 99999)) < 99999, "capped() did not truncate"
assert m.capped("short") == "short", "capped() mangled a short result"
print("OK")
PY
expect_has "breakpoint placement, capping and idempotence" "OK" "$(cat "$SB/bp.out")"

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
