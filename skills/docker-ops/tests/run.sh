#!/usr/bin/env bash
# Offline self-test for docker-ops: the auditor's findings and exit contract, the
# skill's layout, and the resource protocol for every script it ships
# (SKILL-RESOURCE-PROTOCOL sections 2, 4, 5, 7, 10).
#
# The bugs this suite exists to catch:
#   - the auditor stops reporting a landmine, or starts flagging a correct project
#     (the clean fixture is the false-positive guard);
#   - a check exists in the catalog that no fixture can trigger (dead code that
#     looks like coverage);
#   - a secret value reaches stdout, in text or --json;
#   - a suppression pragma suppresses without a reason, or an expired one still works;
#   - an exit code drifts, so a caller branching on 10 / 3 / 4 reads the wrong verdict.
#
# Usage:   tests/run.sh
#          DOCKER_OPS_DIR=<copy-of-skill> tests/run.sh   # run against a copy,
#                                                         # e.g. to prove a mutation fails
# Input:   none (self-contained: no network, no Docker needed)
# Output:  progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass (or no working Python: skipped), 1 any failure.
#
# Examples:
#   bash skills/docker-ops/tests/run.sh
#   DOCKER_OPS_DIR=/tmp/docker-ops-copy bash skills/docker-ops/tests/run.sh
set -uo pipefail

here="${DOCKER_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
skill="$here/SKILL.md"
audit="$here/scripts/docker-audit.py"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }
finish() {
  echo "docker-ops tests: $pass passed, $fail failed" >&2
  [ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
}
expect_exit() { [ "$2" = "$3" ] && ok "$1 (exit $3)" || bad "$1 (want exit $2, got $3)"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing: $3)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (found: $3)" ;; *) ok "$1" ;; esac; }

# A *working* python: on Windows `python3` can be a Microsoft Store stub that exits nonzero.
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no working python interpreter on this platform" >&2; exit 0; }

tmp="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/docker-ops-test.$$")"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

# === 1. Layout + frontmatter ===
# CONTRACT: `name: docker-ops`, `license: MIT`, `metadata.author: claude-mods`.
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done
[ -f "$skill" ] || { bad "SKILL.md missing"; finish; }
grep -q '^name: docker-ops$' "$skill" && ok "name matches directory" || bad "name != docker-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
# The fold decision (2026-10-07) keeps the engine layer in this skill and splits only when
# the body breaks the compaction budget - so the budget is measured here, not assumed.
body="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$skill")"
body_lines="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
body_tokens=$(( $(printf '%s' "$body" | wc -c | tr -d ' ') * 10 / 36 ))
[ "$body_lines" -lt 500 ] && ok "body $body_lines lines (<500)" || bad "body $body_lines lines (>=500)"
[ "$body_tokens" -le 5000 ] && ok "body ~$body_tokens tokens (<=5000)" || bad "body ~$body_tokens tokens (>5000)"

# === 2. References: linked from SKILL.md, one H1, a Contents list past 100 lines ===
for f in "$here"/references/*.md; do
  [ -e "$f" ] || continue
  n="$(basename "$f")"
  grep -q "references/$n" "$skill" && ok "SKILL.md links $n" || bad "SKILL.md never links references/$n"
  h1="$(awk '/^(```|~~~)/{fence=!fence; next} !fence && /^# /{c++} END{print c+0}' "$f")"
  [ "$h1" = "1" ] && ok "$n has one H1" || bad "$n has $h1 H1 lines"
  if [ "$(wc -l < "$f" | tr -d ' ')" -gt 100 ]; then
    grep -q '^## Contents' "$f" && ok "$n has ## Contents" || bad "$n is over 100 lines without ## Contents"
  fi
done
for f in "$here"/assets/*; do
  [ -e "$f" ] || continue
  n="$(basename "$f")"
  grep -q "$n" "$skill" "$here"/references/*.md "$here"/scripts/* 2>/dev/null \
    && ok "asset $n is cited" || bad "asset $n is cited nowhere"
done

# === 3. Script contract (every script) ===
for s in "$here"/scripts/*; do
  [ -f "$s" ] || continue
  n="$(basename "$s")"
  grep -q "scripts/$n" "$skill" && ok "SKILL.md cites scripts/$n" || bad "SKILL.md never cites scripts/$n"
  head -60 "$s" | grep -q 'Examples:' && ok "$n header has Examples" || bad "$n header lacks Examples"
  case "$n" in
    *.py)
      "$PY" -m py_compile "$s" 2>/dev/null && ok "$n compiles" || bad "$n does not compile"
      out="$("$PY" "$s" --help 2>/dev/null)"; rc=$?
      expect_exit "$n --help" 0 "$rc"
      has "$n --help lists EXAMPLES" "$out" "EXAMPLES"
      "$PY" "$s" --no-such-flag >/dev/null 2>&1; expect_exit "$n unknown flag" 2 $? ;;
  esac
done
rm -rf "$here"/scripts/__pycache__

# === 4. Auditor: clean fixture is silent (false-positive guard) ===
out="$("$PY" "$audit" "$fixtures/clean" 2>/dev/null)"; rc=$?
expect_exit "clean fixture" 0 "$rc"
[ -z "$out" ] && ok "clean fixture prints no findings" || bad "clean fixture printed: $out"
out="$("$PY" "$audit" "$fixtures/clean" --min-severity info 2>/dev/null)"; rc=$?
expect_exit "clean fixture at info" 0 "$rc"

# === 5. Auditor: the bad fixture reports every landmine it holds ===
"$PY" "$audit" "$fixtures/bad" > "$tmp/bad.txt" 2>"$tmp/bad.err"; rc=$?
expect_exit "bad fixture" 10 "$rc"
out="$(cat "$tmp/bad.txt")"
for want in \
  "high	secret-in-arg-env	Dockerfile:8" "medium	secret-in-arg-env	Dockerfile:7" \
  "tls-verify-off	Dockerfile:13" "tls-verify-off	Dockerfile:14" "secret-file-copied	Dockerfile:16" \
  "ssh-hostkey-off	Dockerfile:20" "directive-ignored	Dockerfile:2" "base-eol	Dockerfile:4" \
  "base-eol	Dockerfile:29" "dockerignore-missing	Dockerfile:9" "lockfile-not-enforced	Dockerfile:10" \
  "apt-update-alone	Dockerfile:11" "pipe-to-shell	Dockerfile:13" "add-url-unverified	Dockerfile:17" \
  "add-local-file	Dockerfile:18" "sudo-in-run	Dockerfile:19" "expose-ssh	Dockerfile:23" \
  "base-arg-unresolved	Dockerfile:27" "duplicate-stage-name	Dockerfile:29" "final-user-unset	Dockerfile:29" \
  "healthcheck-tool-missing	Dockerfile:31" "workdir-relative	Dockerfile:5" "maintainer-deprecated	Dockerfile:6" \
  "copy-all-before-install	Dockerfile:9" "apt-no-recommends	Dockerfile:12" "apt-not-apt-get	Dockerfile:12" \
  "package-cache-in-layer	Dockerfile:15" "pipe-no-pipefail	Dockerfile:13" "cd-in-run	Dockerfile:14" \
  "secret-mount-optional	Dockerfile:21" "apt-cache-mount-wiped	Dockerfile:22" "cmd-shell-form	Dockerfile:24" \
  "multiple-cmd	Dockerfile:25" \
  "compose-version-obsolete	compose.yaml:2" "build-and-image	compose.yaml:9" "port-all-interfaces	compose.yaml:11" \
  "high	compose-literal-secret	compose.yaml:13" "high	compose-literal-secret	compose.yaml:27" \
  "depends-on-unordered	compose.yaml:15" "high	host-escape	compose.yaml:19" "undeclared-resource	compose.yaml:21" \
  "image-untagged	compose.yaml:23" "high	datastore-published	compose.yaml:25" "image-latest	compose.yaml:29" \
  "high	host-escape	compose.yaml:30" "high	host-escape	compose.yaml:31" "healthy-without-healthcheck	compose.yaml:34" \
  "high	host-escape	compose.yaml:37" "high	host-escape	compose.yaml:38" "medium	host-escape	compose.yaml:41" \
  "undeclared-resource	compose.yaml:42"; do
  has "bad fixture reports: $want" "$out" "$want"
done
hasnt "the env-provided LOG_LEVEL is not a secret" "$out" "LOG_LEVEL"
has "verdict line on stderr" "$(cat "$tmp/bad.err")" "docker-audit: "
hasnt "stdout carries no verdict" "$out" "docker-audit: "
# sorted high -> medium -> low
order="$(cut -f1 "$tmp/bad.txt" | uniq | tr '\n' ' ')"
[ "$order" = "high medium low " ] && ok "findings sorted by severity" || bad "severity order: $order"

# === 6. Secrets: the value is never printed, only the name ===
cp -r "$fixtures/bad" "$tmp/gap"
printf 'API_KEY=changeme-fixture-value\n' > "$tmp/gap/.env"
mkdir -p "$tmp/gap/.git"
printf 'not a key\n' > "$tmp/gap/id_rsa"
all="$("$PY" "$audit" "$tmp/gap" 2>&1; "$PY" "$audit" "$tmp/gap" --json 2>&1)"
hasnt "no secret value in text or --json output" "$all" "changeme-fixture-value"
out="$("$PY" "$audit" "$tmp/gap" 2>/dev/null)"
has "unignored .env in context is high" "$out" "high	dockerignore-gap	Dockerfile:9	.env"
has "unignored id_rsa in context is high" "$out" "high	dockerignore-gap	Dockerfile:9	id_rsa"
has "unignored .git in context is medium" "$out" "medium	dockerignore-gap	Dockerfile:9	.git"
printf '.git\n.env\nid_rsa\n' > "$tmp/gap/.dockerignore"
out="$("$PY" "$audit" "$tmp/gap" 2>/dev/null)"
hasnt "a .dockerignore closes the gaps" "$out" "dockerignore-gap"
hasnt "a .dockerignore satisfies dockerignore-missing" "$out" "dockerignore-missing"
rm -f "$tmp/gap/.dockerignore"   # section 11 needs the gaps open again

# === 7. Suppression pragmas and other tools' skips (edge fixture) ===
out="$("$PY" "$audit" "$fixtures/edge" --today 2026-10-07 2>/dev/null)"; rc=$?
expect_exit "edge fixture" 10 "$rc"
hasnt "a reasoned pragma suppresses (sudo, line 7)" "$out" "sudo-in-run	Dockerfile:7"
has "a pragma without reason suppresses nothing (line 9)" "$out" "sudo-in-run	Dockerfile:9"
has "...and is reported as ignore-invalid" "$out" "ignore-invalid	Dockerfile:8"
has "an unknown check in a pragma is ignore-invalid" "$out" "ignore-invalid	Dockerfile:12"
has "an expired pragma suppresses nothing, and says so" "$out" "expired on 2020-01-01"
hasnt "hadolint ignore=DL3019 suppresses package-cache-in-layer" "$out" "package-cache-in-layer"
hasnt "BuildKit check=skip suppresses cmd-shell-form" "$out" "cmd-shell-form"
hasnt "a Compose pragma above a list item suppresses (docker.sock)" "$out" "host-escape"
hasnt "a trailing Compose pragma suppresses (9230)" "$out" "9230"
has "an unsuppressed long-syntax port is reported (9229)" "$out" "port-all-interfaces	compose.yaml:18"
hasnt "a host_ip-bound long-syntax port is fine (8080)" "$out" "8080"
hasnt "an [::1]-bound port is fine (9000)" "$out" "9000"
has "a \${VAR:-literal} fallback is a literal secret" "$out" "compose-literal-secret	compose.yaml:13"
hasnt "a quoted \${VAR} reference is not a literal" "$out" "GITHUB_TOKEN"
has "explicit USER root is high" "$out" "high	final-user-root	Dockerfile:16"
hasnt "alpine ships busybox wget for its HEALTHCHECK" "$out" "Dockerfile:17"
has "shell-form HEALTHCHECK on distroless needs a shell" "$out" "healthcheck-tool-missing	skip.Dockerfile:4"
hasnt "a distroless :nonroot base needs no USER" "$out" "final-user-unset"
has "a .dockerignore'd COPY source is reported" "$out" "copy-ignored-file	Dockerfile:15"
has "credentials in a URL are redacted" "$out" "https://***@example.com"
hasnt "the URL password is never printed" "$out" "hunter2"
out="$("$PY" "$audit" "$fixtures/edge" --today 2026-10-07 --show-suppressed 2>/dev/null)"
has "--show-suppressed lists pragma suppressions" "$out" "suppressed(docker-audit pragma)	sudo-in-run	Dockerfile:7"
has "--show-suppressed names the hadolint pragma" "$out" "suppressed(hadolint ignore)"
"$PY" "$audit" "$fixtures/edge" --today 2019-12-31 2>/dev/null | grep -q 'cd-in-run' \
  && bad "a pragma still inside its until= date suppresses" || ok "a pragma still inside its until= date suppresses"

# === 8. --json envelope ===
"$PY" "$audit" "$fixtures/bad" --json > "$tmp/bad.json" 2>/dev/null
"$PY" - "$tmp/bad.json" <<'EOF' && ok "--json envelope matches the protocol" || bad "--json envelope malformed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["meta"]["schema"] == "claude-mods.docker-ops.audit/v1"
assert d["meta"]["count"] == len([f for f in d["data"] if not f["suppressed"]]) > 0
assert d["meta"]["dockerfiles"] == ["Dockerfile"] and d["meta"]["compose_files"] == ["compose.yaml"]
for f in d["data"]:
    assert set(f) == {"severity", "check", "family", "file", "line", "detail", "ids", "suppressed", "suppressed_by"}
    assert isinstance(f["line"], int) and f["severity"] in ("high", "medium", "low", "info")
EOF

# === 9. Exit contract ===
mkdir -p "$tmp/empty" "$tmp/broken"
printf 'services:\n\tweb:\n    image: x:1\n' > "$tmp/broken/compose.yaml"
printf 'x\n' > "$tmp/notes.txt"
"$PY" "$audit" "$tmp/empty" >/dev/null 2>&1;            expect_exit "no Dockerfile or Compose file" 3 $?
"$PY" "$audit" "$tmp/does-not-exist" >/dev/null 2>&1;   expect_exit "missing path" 3 $?
"$PY" "$audit" "$tmp/broken" >/dev/null 2>&1;           expect_exit "only an unreadable file" 4 $?
"$PY" "$audit" "$tmp/notes.txt" >/dev/null 2>&1;        expect_exit "a file not named like either" 2 $?
"$PY" "$audit" "$fixtures/clean" --ignore nope >/dev/null 2>&1; expect_exit "unknown --ignore" 2 $?
"$PY" "$audit" "$fixtures/clean" --today 07/10/2026 >/dev/null 2>&1; expect_exit "bad --today" 2 $?
"$PY" "$audit" "$fixtures/clean" --catalog "$tmp/none.json" >/dev/null 2>&1; expect_exit "missing catalog" 3 $?
printf '{"schema": "wrong"}' > "$tmp/badcat.json"
"$PY" "$audit" "$fixtures/clean" --catalog "$tmp/badcat.json" >/dev/null 2>&1; expect_exit "malformed catalog" 4 $?
"$PY" "$audit" "$fixtures/bad" --ignore host-escape 2>/dev/null | grep -q host-escape \
  && bad "--ignore drops a check" || ok "--ignore drops a check"

# === 10. Flags that widen the audit ===
out="$("$PY" "$audit" "$fixtures/clean" --production 2>/dev/null)"
has "--production wants digest-pinned bases" "$out" "base-not-digest"
has "--production wants Compose hardening" "$out" "hardening-missing"
out="$("$PY" "$audit" "$fixtures/clean" --allow-registry ghcr.io 2>/dev/null)"
has "--allow-registry flags Docker Hub bases" "$out" "registry docker.io is not in --allow-registry"
out="$("$PY" "$audit" "$fixtures/clean" --allow-registry docker.io 2>/dev/null)"
hasnt "--allow-registry docker.io accepts Hub bases" "$out" "base-registry"

# === 11. Every catalogued check can fire (no dead checks) ===
"$PY" "$audit" --list-checks > "$tmp/checks.txt" 2>/dev/null
cut -f1 "$tmp/checks.txt" | sort -u > "$tmp/catalog.txt"
{ "$PY" "$audit" "$tmp/gap" "$fixtures/edge" --production --allow-registry ghcr.io --min-severity info --today 2026-10-07 2>/dev/null
  "$PY" "$audit" "$fixtures/coverage" --production --min-severity info 2>/dev/null; } | cut -f2 | sort -u > "$tmp/fired.txt"
dead="$(comm -23 "$tmp/catalog.txt" "$tmp/fired.txt" | tr '\n' ' ')"
[ -z "$dead" ] && ok "every catalogued check fires on some fixture" || bad "checks no fixture triggers: $dead"
n_checks="$(wc -l < "$tmp/catalog.txt" | tr -d ' ')"
[ "$n_checks" -ge 50 ] && ok "--list-checks lists $n_checks checks" || bad "--list-checks lists only $n_checks"
grep -q $'^base-latest\tD1\tmedium\thadolint:DL3007' "$tmp/checks.txt" && ok "--list-checks carries cross-tool IDs" \
  || bad "--list-checks lost the cross-tool IDs"

finish
