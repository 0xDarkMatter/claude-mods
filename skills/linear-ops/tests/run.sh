#!/usr/bin/env bash
# Offline self-test for linear-ops: structure, the magic-word table, the facts verifier and the
# GraphQL client's traps, against a loopback stand-in for Linear (SKILL-RESOURCE-PROTOCOL 2, 5, 7).
#
# Usage:   tests/run.sh
# Input:   none. No network and no Linear token: fake values only, sent only to loopback.
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or skipped when no python exists), 1 any failure.
#
# Examples:
#   tests/run.sh
#   bash skills/linear-ops/tests/run.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }

# A *working* python: on Windows `python3` can be a Store stub that exits nonzero.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then echo "SKIP: no working python interpreter on this platform" >&2; exit 0; fi

GQL="$here/scripts/linear-gql.py"
MW="$here/scripts/scan-magic-words.py"
FACTS="$here/scripts/check-linear-facts.py"
tmp="$(mktemp -d)"
server_pid=""
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
unset LINEAR_API_KEY LINEAR_OAUTH_TOKEN

ec() { local want="$1" lbl="$2"; shift 2; "$@" >"$tmp/out" 2>"$tmp/err"; local got=$?
  if [ "$got" = "$want" ]; then ok "$lbl (exit $got)"; else bad "$lbl: exit $got, wanted $want: $(head -c 300 "$tmp/out") $(tail -c 300 "$tmp/err")"; fi; }
has() { local lbl="$1" needle="$2"; if grep -qF -- "$needle" "$tmp/out"; then ok "$lbl"; else bad "$lbl: no '$needle' in: $(head -c 300 "$tmp/out")"; fi; }
hasnt() { local lbl="$1" needle="$2"; if grep -qF -- "$needle" "$tmp/out"; then bad "$lbl: found '$needle'"; else ok "$lbl"; fi; }

# --- structure ---
# CONTRACT: these require `name: linear-ops`, `license: MIT` and `metadata.author: claude-mods`. A
# trim lane editing the frontmatter must keep them or change these assertions in the same commit.
skill="$here/SKILL.md"
grep -q '^name: linear-ops$' "$skill" && ok "name matches directory" || bad "name != linear-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
for d in scripts references assets tests; do [ -d "$here/$d" ] && ok "dir $d/" || bad "missing dir $d/"; done
for ref in "$here"/references/*.md; do
  base="references/$(basename "$ref")"
  grep -qF "$base" "$skill" && ok "cited: $base" || bad "uncited reference: $base"
done
for asset in agent-standing-rules.md linear-facts.json queries/ground.graphql queries/create-issue.graphql \
             queries/comment.graphql queries/relation.graphql queries/link-github-pr.graphql \
             queries/project-update.graphql queries/team-issues.graphql queries/issue-batch-update.graphql; do
  grep -qF "$(basename "$asset")" "$skill" && [ -f "$here/assets/$asset" ] && ok "asset cited and present: $asset" \
    || bad "asset missing or uncited: $asset"
done

# This repo is public and the skill is workspace-agnostic: its standing template must stay a template.
grep -q '<the workspace member' "$here/assets/agent-standing-rules.md" && ok "standing rules keep placeholders" \
  || bad "standing rules lost their placeholders"

# --- scan-magic-words: named for what a wrong answer would do to someone's issue ---
ec 0 "scan --help" "$PY" "$MW" --help
ec 3 "scan missing file" "$PY" "$MW" /no/such/file
ec 10 "closing_word_signals_exit_10" "$PY" "$MW" --json "$here/tests/fixtures/pr-body.md"
"$PY" - "$tmp/out" <<'EOF' >"$tmp/table" || bad "scan JSON unparseable"
import json, sys
for r in json.load(open(sys.argv[1], encoding="utf-8"))["data"]:
    print(r["id"], r["effect"])
EOF
row() { if grep -qx "$1 $2" "$tmp/table"; then ok "$3"; else bad "$3: wanted '$1 $2' in: $(tr '\n' ';' < "$tmp/table")"; fi; }
row ENG-123 closing "closes_first_id_in_list"
row DES-5 closing "closes_second_id_in_list"
row ENG-256 closing "closes_id_after_and"
row ENG-9 non-closing "part_of_does_not_close"
row ENG-10 relation "related_to_is_relation_only"
row ENG-11 bare "bare_id_does_not_link"
row ENG-12 opt-out "skip_is_opt_out"
row ENG-13 negated-closing "does_not_fix_is_flagged_not_trusted"
row SHA-256 bare "hash_name_is_not_closed"
row ENG-14 non-closing "contributes_to_with_trailing_dot"
row DOC-NEW closing "fixes_new_creates_and_closes_on_merge"
row OPS-NEW create "part_of_new_creates_without_closing"
row QA-NEW create "bare_new_creates_an_issue"
printf 'Part of ENG-1\n' >"$tmp/safe.md"
ec 0 "non_closing_text_exits_0" "$PY" "$MW" "$tmp/safe.md"
printf 'Fixes ENG-1\n' >"$tmp/comment.md"
ec 0 "words_in_a_pr_comment_do_not_link" "$PY" "$MW" --kind comment "$tmp/comment.md"
has "comment reference marked ignored" "ignored"
printf 'Updates ENG-1\n' >"$tmp/gl.md"
ec 0 "gitlab_updates_word_links" "$PY" "$MW" --gitlab "$tmp/gl.md"
has "updates is non-closing on gitlab" "non-closing"
ec 0 "github_updates_text_exits_0" "$PY" "$MW" "$tmp/gl.md"
has "github_updates_word_is_bare" "bare"

# --- facts verifier, offline ---
ec 0 "facts --help" "$PY" "$FACTS" --help
ec 0 "facts --offline consistent" "$PY" "$FACTS" --offline
drift_copy() { rm -rf "$tmp/skill"; mkdir -p "$tmp/skill"; cp -r "$here/SKILL.md" "$here/references" "$tmp/skill/"; }
drift_copy
"$PY" - "$tmp/skill/references" <<'EOF'
import pathlib, re, sys
for f in pathlib.Path(sys.argv[1]).glob("*.md"):
    f.write_text(re.sub(r"get_release_note", "gone_tool", f.read_text(encoding="utf-8")), encoding="utf-8")
EOF
ec 10 "tool_dropped_from_prose_is_drift" "$PY" "$FACTS" --offline --skill "$tmp/skill"
has "names the missing tool" "get_release_note"
drift_copy
"$PY" - "$tmp/skill/SKILL.md" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text(encoding="utf-8").replace("Verified against the Linear MCP", "Checked"), encoding="utf-8")
EOF
ec 10 "missing_currency_note_is_drift" "$PY" "$FACTS" --offline --skill "$tmp/skill"
drift_copy
"$PY" - "$tmp/skill/SKILL.md" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text(encoding="utf-8").replace("all 84", "all 83"), encoding="utf-8")
EOF
ec 10 "wrong_tool_count_is_drift" "$PY" "$FACTS" --offline --skill "$tmp/skill"
ec 3 "missing_catalog_exit_3" "$PY" "$FACTS" --catalog "$tmp/nope.json"
printf '{"schema":"wrong"}' >"$tmp/badcat.json"
ec 4 "wrong_schema_exit_4" "$PY" "$FACTS" --catalog "$tmp/badcat.json"

# --- GraphQL client, no server needed ---
ec 0 "gql --help" "$PY" "$GQL" --help
ec 2 "gql needs a document" "$PY" "$GQL"
ec 2 "refuses_mutation_without_flag" "$PY" "$GQL" --dry-run --query 'mutation M { issueCreate(input: {}) { success } }'
ec 0 "mutation_word_in_a_comment_is_not_a_mutation" "$PY" "$GQL" --dry-run --query '# mutation here
{ viewer { id } }'
ec 0 "mutation_word_in_a_string_is_not_a_mutation" "$PY" "$GQL" --dry-run --query '{ issues(first: 1, filter: {title: {eq: "mutation x"}}) { nodes { id } } }'
ec 0 "allow_flag_permits_mutation" "$PY" "$GQL" --dry-run --allow-mutation --query 'mutation M { x }'
ec 2 "refuses_second_operation_mutation" "$PY" "$GQL" --dry-run --query 'query A { a } mutation B { b }'
ec 2 "token_cannot_go_to_another_host" "$PY" "$GQL" --dry-run --endpoint https://evil.example/graphql --query '{ a }'
ec 2 "lookalike_host_refused" "$PY" "$GQL" --dry-run --endpoint https://linear.app.evil.example/graphql --query '{ a }'
ec 2 "plain_http_to_linear_refused" "$PY" "$GQL" --dry-run --endpoint http://api.linear.app/graphql --query '{ a }'
ec 3 "missing_query_file" "$PY" "$GQL" --query-file /no/such.graphql
ec 4 "bad_vars_json" "$PY" "$GQL" --dry-run --query '{ a }' --vars '{nope'
ec 5 "no_token_exit_5" "$PY" "$GQL" --query '{ a }'
ec 2 "paginate_needs_after_variable" "$PY" "$GQL" --dry-run --paginate issues --query '{ issues { nodes { id } } }'
ec 0 "dry_run_works_on_shipped_query" "$PY" "$GQL" --dry-run --query-file "$here/assets/queries/team-issues.graphql" --vars '{"teamKey":"ENG"}'
hasnt "dry run prints no secret" "fake-secret"

# --- GraphQL client against the loopback stand-in ---
"$PY" "$here/tests/fixtures/mock-linear.py" >"$tmp/port" &
server_pid=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
port="$(tr -d '\r\n' <"$tmp/port")"
if [ -z "$port" ]; then
  bad "mock server did not start"
else
  URL="http://127.0.0.1:$port/graphql"
  q() { printf '# scenario: %s\n{ a }' "$1"; }

  LINEAR_API_KEY=fake-secret ec 0 "api key request succeeds" "$PY" "$GQL" --endpoint "$URL" --query "$(q whoami)"
  has "api_key_sent_raw_without_bearer" '"auth": "fake-secret"'
  LINEAR_OAUTH_TOKEN=fake-secret ec 0 "oauth request succeeds" "$PY" "$GQL" --endpoint "$URL" --query "$(q whoami)"
  has "oauth_token_sent_with_bearer" '"auth": "Bearer fake-secret"'
  LINEAR_API_KEY=a LINEAR_OAUTH_TOKEN=b ec 2 "both_tokens_refused" "$PY" "$GQL" --endpoint "$URL" --query "$(q whoami)"

  export LINEAR_API_KEY=fake-secret
  ec 10 "http_200_with_errors_is_a_failure" "$PY" "$GQL" --endpoint "$URL" --query "$(q partial)"
  has "partial data is kept for the caller" '"a": 1'
  ec 7 "http_429_is_rate_limited" "$PY" "$GQL" --endpoint "$URL" --query "$(q limited429)"
  has "retry_after_reported" '"retryAfter": "42"'
  ec 7 "http_400_ratelimited_code_is_rate_limited" "$PY" "$GQL" --endpoint "$URL" --query "$(q limited400)"
  ec 5 "rejected_token_exit_5" "$PY" "$GQL" --endpoint "$URL" --query "$(q badtoken)"
  # A generous timeout: Windows retries a refused connection for about 2 seconds before reporting it.
  ec 7 "unreachable_exit_7" "$PY" "$GQL" --endpoint "http://127.0.0.1:9/graphql" --timeout 15 --query '{ a }'

  PAGES='# scenario: pages
query P($after: String) { issues(first: 1, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } } }'
  ec 0 "paginate_exits_0" "$PY" "$GQL" --endpoint "$URL" --query "$PAGES" --paginate issues
  has "paginate_walks_every_page" '"count": 3'
  has "complete_walk_not_truncated" '"truncated": false'
  ec 0 "max_pages_exits_0" "$PY" "$GQL" --endpoint "$URL" --query "$PAGES" --paginate issues --max-pages 2
  has "max_pages_reports_truncated" '"truncated": true'
  ec 2 "paginate_wrong_path_refused" "$PY" "$GQL" --endpoint "$URL" --query "$PAGES" --paginate nope

  # The mock answers with data if any credential arrives, so exit 0 here proves none was sent.
  ec 0 "validate_sends_no_credentials_even_with_key_set" "$PY" "$GQL" --validate --endpoint "$URL" --query "$(q validate)"
  has "valid shape reported" '"valid": true'
  ec 10 "validate_reports_invalid_shape" "$PY" "$GQL" --validate --endpoint "$URL" --query '# scenario: validate
{ viewer { nope } }'
  unset LINEAR_API_KEY
  ec 0 "validate_needs_no_token" "$PY" "$GQL" --validate --endpoint "$URL" --query "$(q validate)"
  ec 0 "validate_does_not_require_allow_mutation" "$PY" "$GQL" --validate --endpoint "$URL" --query '# scenario: validate
mutation M { a }'
  ec 0 "schema_type_needs_no_token" "$PY" "$GQL" --schema-type IssueRelationCreateInput --endpoint "$URL"
  has "schema fields returned" '"issueId"'
  ec 3 "schema_type_unknown_exit_3" "$PY" "$GQL" --schema-type Nope --endpoint "$URL"
  ec 2 "schema_type_rejects_non_name" "$PY" "$GQL" --schema-type 'a b' --endpoint "$URL"

  # --- facts verifier, live, pointed at the stand-in ---
  base="http://127.0.0.1:$port"
  # No leading slash on the page name: Git Bash would rewrite "/ok" into a Windows path.
  mkcat() { # $1 = path of one docs page, $2 = tripwire needle
    "$PY" - "$tmp/live.json" "$base" "$1" "$2" <<'EOF'
import json, sys
out, base, doc, needle = sys.argv[1:5]
json.dump({"schema": "claude-mods.linear-ops.facts/v1", "as_of": "2026-11-05",
  "packages": [{"key": "sdk", "prose_token": "x", "package": "@linear/sdk"}],
  "endpoints": [{"key": "mcp", "prose_token": "x", "url": base + "/auth"}],
  "schema_sdl": {"url": base + "/schema", "assert_contains": ["alpha"]},
  "docs_liveness": [base + "/" + doc],
  "docs_tripwires": [{"url": base + "/page", "contains": [needle]}],
  "mcp_tools": []}, open(out, "w", encoding="utf-8"))
EOF
  }
  mkcat ok alpha
  ec 0 "live_all_true_exit_0" "$PY" "$FACTS" --live --catalog "$tmp/live.json" --npm-registry "$base" --timeout 5
  mkcat gone alpha
  ec 10 "live_dead_docs_page_is_drift" "$PY" "$FACTS" --live --catalog "$tmp/live.json" --npm-registry "$base" --timeout 5
  mkcat ok missing-needle
  ec 10 "live_tripwire_fact_gone_is_drift" "$PY" "$FACTS" --live --catalog "$tmp/live.json" --npm-registry "$base" --timeout 5
  mkcat down alpha
  ec 7 "live_server_error_is_not_drift" "$PY" "$FACTS" --live --catalog "$tmp/live.json" --npm-registry "$base" --timeout 5
  mkcat ok alpha
  ec 10 "live_package_gone_is_drift" "$PY" "$FACTS" --live --catalog "$tmp/live.json" --npm-registry "$base/gone" --timeout 5
fi

printf 'linear-ops: %s passed, %s failed\n' "$pass" "$fail" >&2
if [ "$fail" -gt 0 ]; then echo "FAIL" >&2; exit 1; fi
echo "PASS" >&2
