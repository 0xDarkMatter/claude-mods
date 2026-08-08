#!/usr/bin/env bash
# Self-test for sqlite-ops: frontmatter contract, reference wiring, script behaviour.
#
# Fully offline and self-contained - the only external need is a working Python
# (stdlib sqlite3), which every supported platform has. Fixtures are synthesized
# in a temp dir, so no binary fixtures live in the repo.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
S="$SKILL/scripts"
R="$SKILL/references"
MD="$SKILL/SKILL.md"

# Windows Store python3 is a stub that exits non-zero - probe for one that runs.
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
if [[ -z "$PYTHON" ]]; then
  echo "  SKIP  no working python found - sqlite-ops suite not run" >&2
  exit 0
fi

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

# Case-insensitive literal file search WITHOUT grep. GNU grep 3.0 (the build
# shipped with Git Bash on Windows) ABORTS with SIGABRT on `-i` combined with
# `-F` - it exits 134, which reads as "no match" and silently fails every
# assertion. Pure-bash matching sidesteps the bug and is portable.
file_has() { # $1=label $2=needle $3=file
  local hay needle
  hay="$(tr '[:upper:]' '[:lower:]' < "$3")"
  needle="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  case "$hay" in *"$needle"*) ok "$1";; *) no "$1 (missing '$2')";; esac
}

echo "=== sqlite-ops self-test ==="

# ── frontmatter contract ────────────────────────────────────────────────────
# CONTRACT: these assertions police this skill's OWN frontmatter. The skill was
# de-Pythonised on 2026-08-04 precisely because a Python-pinned description and
# compatibility line suppressed it in TypeScript/Worker contexts. If you edit the
# frontmatter, keep it engine-agnostic or these fail on purpose.
echo "-- frontmatter --"
fm="$(sed -n '2,/^---$/p' "$MD")"

expect_has "name is sqlite-ops"            "name: sqlite-ops" "$fm"
expect_has "license MIT"                   "license: MIT"     "$fm"
expect_has "metadata.author claude-mods"   "author: claude-mods" "$fm"

# related-skills must be a comma-separated STRING under metadata, never an array
# (naming-conventions.md + SKILL-SUBAGENT-REFERENCE.md). doc-drift.sh also checks
# that every skill named here exists on disk.
expect_has "related-skills present"        "related-skills:" "$fm"
case "$fm" in
  *"related-skills: \""*) ok "related-skills is a quoted string, not an array";;
  *"related-skills: ["*)  no "related-skills is a YAML array (must be a comma-separated string)";;
  *) no "related-skills not in the expected string form";;
esac
for peer in sql-ops perf-ops cloudflare-ops postgres-ops; do
  expect_has "related-skills names $peer" "$peer" "$fm"
done

# The de-Pythonisation guard: description and compatibility must NOT scope the
# skill to Python. A Python-only description hides this skill from Worker/TS work.
case "$fm" in
  *"in Python projects"*) no "description still scopes the skill to Python projects";;
  *)                      ok "description is not scoped to Python projects";;
esac
case "$fm" in
  *"compatibility: \"Requires Python"*) no "compatibility still pins the skill to Python";;
  *)                                    ok "compatibility does not pin the skill to Python";;
esac
expect_has "compatibility states engine-agnostic guidance" "engine-agnostic" "$fm"

# Description budget: tests/validate.sh HARD-FAILS over 700 chars for
# description + when_to_use combined. Catch it here rather than at the repo gate.
budget="$("$PYTHON" - "$MD" <<'PY'
import sys, pathlib
lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8-sig").splitlines()
marks = [i for i, l in enumerate(lines) if l.strip() == "---"]
body = "\n".join(lines[marks[0] + 1:marks[1]])
try:
    import yaml
    fm = yaml.safe_load(body) or {}
    total = len(str(fm.get("description") or "")) + len(str(fm.get("when_to_use") or ""))
except ImportError:
    # Fallback: measure the raw single-line values without a YAML parser.
    total = 0
    for line in body.splitlines():
        for key in ("description:", "when_to_use:"):
            if line.startswith(key):
                total += len(line[len(key):].strip().strip('"').strip("'"))
print(total)
PY
)"
if [[ -n "$budget" && "$budget" -le 700 ]]; then
  ok "description budget ${budget}/700 chars"
else
  no "description budget ${budget}/700 chars (validate.sh hard-fails over 700)"
fi

# ── trigger keywords ────────────────────────────────────────────────────────
# These are the terms that must route a performance/D1 question here. They were
# absent before 2026-08-04, which is why a live D1 investigation never loaded
# this skill. Removing one silently un-routes that class of question.
echo "-- description triggers --"
desc_line="$(grep -m1 '^description:' "$MD")"
for trigger in "EXPLAIN QUERY PLAN" "covering index" "rows_read" "sql_duration_ms" \
               "D1" "wrangler d1" "node:sqlite" "better-sqlite3" "fts5" "trigram" \
               "sqlite_stat1" "ANALYZE" "SQLITE_BUSY" "WAL" "STRICT tables"; do
  case "$desc_line" in
    *"$trigger"*) ok "trigger: $trigger";;
    *)            no "trigger MISSING from description: $trigger";;
  esac
done

# ── references exist and are cited ──────────────────────────────────────────
echo "-- references --"
for ref in query-performance d1-edge d1-production-patterns concurrency-durability \
           schema-design schema-patterns migration-patterns feature-modules hosts \
           async-patterns operations testing; do
  if [[ -f "$R/$ref.md" ]]; then ok "reference exists: $ref.md"; else no "reference MISSING: $ref.md"; fi
  # SKILL-RESOURCE-PROTOCOL: an uncited reference is dead weight the router never finds.
  file_has "SKILL.md cites $ref.md" "references/$ref.md" "$MD"
done

# ── measured facts that must not silently vanish ────────────────────────────
# These numbers come from a live D1 investigation (2026-08-04) and are the
# evidence behind the skill's core lesson. They are labelled as one database's
# worked example, NOT as constants - but if an edit drops them, the reasoning
# loses its grounding, so they are pinned here.
echo "-- worked-example facts --"
file_has "covering-index before figure (171.83 ms)" "171.83" "$R/query-performance.md"
file_has "covering-index after figure (6.75 ms)"    "6.75"   "$R/query-performance.md"
file_has "invisible-aggregate figure (28.09 ms)"    "28.09"  "$R/query-performance.md"
file_has "numbers labelled as a worked example"     "worked example" "$R/query-performance.md"
file_has "read-only proof technique documented"     "read-only proof" "$R/query-performance.md"
file_has "SCAN vs SEARCH distinction"               "COVERING INDEX" "$R/query-performance.md"
file_has "sqlite_stat1 with/without check"          "sqlite_stat1" "$R/query-performance.md"

echo "-- d1 facts --"
file_has "rows_read documented"          "rows_read"          "$R/d1-edge.md"
file_has "sql_duration_ms documented"    "sql_duration_ms"    "$R/d1-edge.md"
file_has "one-line statement rule"       "SQLITE_ERROR 7500"  "$R/d1-edge.md"
file_has "100 bound-parameter cap"       "100"                "$R/d1-edge.md"
file_has "SQLITE_AUTH introspection block" "SQLITE_AUTH"      "$R/d1-edge.md"
# FTS5 on D1 was NOT confirmable read-only. Recording it as unknown is the honest
# result; an edit that replaces this with a confident claim is a regression.
file_has "FTS5-on-D1 recorded as unknown" "could not be confirmed read-only" "$R/d1-edge.md"
file_has "d1 insights covered"           "d1 insights"        "$R/d1-edge.md"
file_has "Sessions API / replication"    "withSession"        "$R/d1-edge.md"
file_has "Time Travel covered"           "time-travel"        "$R/d1-edge.md"
file_has "cold-run variance figure"      "2,495"              "$R/d1-edge.md"

echo "-- engine-agnostic coverage --"
file_has "concurrency: BUSY vs LOCKED"   "SQLITE_LOCKED"      "$R/concurrency-durability.md"
file_has "concurrency: BEGIN IMMEDIATE"  "BEGIN IMMEDIATE"    "$R/concurrency-durability.md"
file_has "schema: foreign_keys OFF by default" "OFF by default" "$R/schema-design.md"
file_has "schema: STRICT tables"         "STRICT"             "$R/schema-design.md"
file_has "migrations: 12-step dance"     "12-step"            "$R/migration-patterns.md"
file_has "features: trigram tokenizer"   "trigram"            "$R/feature-modules.md"
file_has "hosts: node:sqlite"            "node:sqlite"        "$R/hosts.md"
file_has "hosts: bun:sqlite"             "bun:sqlite"         "$R/hosts.md"
file_has "operations: VACUUM INTO"       "VACUUM INTO"        "$R/operations.md"
file_has "testing: deterministic seeding" "deterministic"     "$R/testing.md"

# ── script contract (SKILL-RESOURCE-PROTOCOL) ───────────────────────────────
echo "-- eqp-triage.py contract --"
"$PYTHON" -m py_compile "$S/eqp-triage.py" 2>/dev/null && ok "py_compile eqp-triage.py" \
                                                       || no "py_compile eqp-triage.py"
"$PYTHON" "$S/eqp-triage.py" --help >/dev/null 2>&1; expect_exit "--help" 0 $?
help_out="$("$PYTHON" "$S/eqp-triage.py" --help 2>/dev/null)"
expect_has "--help has EXAMPLES" "EXAMPLES" "$help_out"
file_has "SKILL.md cites the script with a worked invocation" "eqp-triage.py --db" "$MD"

echo "-- eqp-triage.py exit codes --"
"$PYTHON" "$S/eqp-triage.py" --bogus-flag </dev/null >/dev/null 2>&1
expect_exit "unknown flag -> 2" 2 $?
"$PYTHON" "$S/eqp-triage.py" --sql "SELECT 1" </dev/null >/dev/null 2>&1
expect_exit "--sql without --db -> 2" 2 $?
"$PYTHON" "$S/eqp-triage.py" --db "$SB/nope.db" --sql "SELECT 1" </dev/null >/dev/null 2>&1
expect_exit "missing database -> 3" 3 $?
"$PYTHON" "$S/eqp-triage.py" --plan-file "$SB/nope.txt" </dev/null >/dev/null 2>&1
expect_exit "missing plan file -> 3" 3 $?
printf 'not a plan at all\n' | "$PYTHON" "$S/eqp-triage.py" >/dev/null 2>&1
expect_exit "unparseable input -> 4" 4 $?

# ── behavioural: real plans against a synthesized database ──────────────────
echo "-- eqp-triage.py behaviour --"
"$PYTHON" - "$SB/t.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE q_product (id INTEGER PRIMARY KEY, org TEXT, "
             "product_id TEXT, pad TEXT)")
conn.execute("CREATE INDEX q_product_org ON q_product(org)")
conn.executemany("INSERT INTO q_product (org, product_id, pad) VALUES (?,?,?)",
                 [("org%d" % (i % 50), "p%d" % i, "x" * 200) for i in range(2000)])
conn.commit(); conn.close()
PY
[[ -f "$SB/t.db" ]] && ok "fixture database synthesized" || no "fixture database synthesized"

# Leading-wildcard LIKE over a non-covering index: the exact shape from the
# worked example. Must be flagged HIGH and exit 10.
out="$("$PYTHON" "$S/eqp-triage.py" --db "$SB/t.db" --quiet \
        --sql "SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%org1%'" 2>/dev/null)"
rc=$?
expect_exit "non-covering scan -> 10" 10 "$rc"
expect_has  "flags the scan as HIGH" "HIGH" "$out"

# Add the covering index; the scan must be reclassified as LOW (acceptable).
"$PYTHON" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); \
c.execute('CREATE INDEX q_org_prod ON q_product(org, product_id)'); c.commit()" "$SB/t.db"
out="$("$PYTHON" "$S/eqp-triage.py" --db "$SB/t.db" --quiet \
        --sql "SELECT DISTINCT product_id FROM q_product WHERE org LIKE '%org1%'" 2>/dev/null)"
expect_has "covering scan classified LOW" "LOW	covering-scan" "$out"

# An indexed equality seek is clean: no actionable findings, exit 0.
"$PYTHON" "$S/eqp-triage.py" --db "$SB/t.db" --quiet \
  --sql "SELECT product_id FROM q_product WHERE org = 'x'" >/dev/null 2>&1
expect_exit "indexed seek -> 0" 0 $?

# Invalid SQL is a validation error, not a crash.
"$PYTHON" "$S/eqp-triage.py" --db "$SB/t.db" --sql "SELECT FROM WHERE" >/dev/null 2>&1
expect_exit "bad SQL -> 4" 4 $?

# The script must never be able to write to the database it analyses.
"$PYTHON" "$S/eqp-triage.py" --db "$SB/t.db" --quiet \
  --sql "DELETE FROM q_product" >/dev/null 2>&1
rc=$?
rows="$("$PYTHON" -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(
  'SELECT count(*) FROM q_product').fetchone()[0])" "$SB/t.db")"
[[ "$rows" == "2000" ]] && ok "read-only guard: rows intact after a DELETE statement" \
                        || no "read-only guard FAILED: row count now $rows (want 2000)"

echo "-- eqp-triage.py input formats --"
# Raw sqlite3 CLI text with tree-drawing characters
out="$(printf 'QUERY PLAN\n|--SCAN q_product\n`--USE TEMP B-TREE FOR GROUP BY\n' \
        | "$PYTHON" "$S/eqp-triage.py" --quiet 2>/dev/null)"
expect_has "parses raw sqlite3 tree output" "table-scan" "$out"
expect_has "detects temp B-tree for GROUP BY" "temp-btree-group" "$out"
# Legacy pipe-delimited format
out="$(printf '0|0|0|SCAN TABLE q_product\n' | "$PYTHON" "$S/eqp-triage.py" --quiet 2>/dev/null)"
expect_has "parses legacy 0|0|0| format" "table-scan" "$out"
# wrangler d1 execute --json shape
out="$(printf '[{"results":[{"id":2,"parent":0,"detail":"SCAN q_product USING INDEX q_product_org"}],"success":true,"meta":{"rows_read":58433}}]' \
        | "$PYTHON" "$S/eqp-triage.py" --json 2>/dev/null)"
expect_has "parses wrangler --json output" "noncovering-scan" "$out"
expect_has "--json emits the versioned schema" '"schema": "claude-mods.sqlite-ops.eqp/v1"' "$out"
expect_has "--json envelope has data key" '"data"' "$out"
expect_has "--json envelope has meta key" '"meta"' "$out"

# --strict promotes low-severity findings to actionable
printf 'SCAN t USING COVERING INDEX ix\n' | "$PYTHON" "$S/eqp-triage.py" --quiet >/dev/null 2>&1
expect_exit "covering scan alone -> 0 by default" 0 $?
printf 'SCAN t USING COVERING INDEX ix\n' | "$PYTHON" "$S/eqp-triage.py" --quiet --strict >/dev/null 2>&1
expect_exit "covering scan -> 10 under --strict" 10 $?

# Stream separation: with --quiet, stdout carries findings only.
so="$(printf 'SCAN t\n' | "$PYTHON" "$S/eqp-triage.py" --quiet 2>/dev/null)"
case "$so" in
  HIGH*) ok "stdout is data-only under --quiet";;
  *)     no "stdout polluted with non-data output: $so";;
esac

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
