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

# === 12. Doctor: scenarios against a stub docker CLI and a fake host ===
# run_doctor.py gives every scenario its own HOME, DOCKER_CONFIG and Windows folders, the
# stub CLI (fixtures/doctor/docker_stub.py) and a fake process/port/WSL picture, so these
# run the same on any OS with no Docker installed.
doctor="$here/scripts/docker-doctor.py"
runner="$fixtures/doctor/run_doctor.py"
export STUB_LOG="$tmp/stub.log"
: > "$STUB_LOG"
doc() { "$PY" "$runner" "$1" "$doctor" "${@:2}" 2>&1; }
out="$(doc healthy)"; rc=$?
expect_exit "doctor: healthy colima" 0 "$rc"
has "provider comes from the endpoint path" "$out" $'fact\tprovider\tcolima'
has "the context source is named" "$out" $'fact\tendpoint_source\tdocker context use'
has "engine version is reported" "$out" $'fact\tengine\tup (29.8.2)'
out="$(doc bloat)"; rc=$?
expect_exit "doctor: VM disk far above engine data" 10 "$rc"
has "disk-bloat names both sizes" "$out" "30.0 GiB on disk but the engine holds only 4.7 GiB"
out="$(doc down)"; rc=$?
expect_exit "doctor: engine down" 10 "$rc"
has "engine-down gives the provider's own start command" "$out" "run \`colima start\` yourself"
has "engine-down promises not to start it" "$out" "the doctor never starts engines"
out="$(doc multi)"
has "two providers running is a finding" "$out" $'medium\tmultiple-providers'
out="$(doc creds)"
has "a credsStore helper missing from PATH is a finding" "$out" "docker-credential-nosuchhelper-fixture is not on PATH"
hasnt "auths are never read out (base64)" "$out" "c2VjcmV0"
hasnt "auths are never read out (decoded)" "$out" "secret-fixture"
out="$(doc missing-socket)"
has "a DOCKER_HOST socket that is gone is high" "$out" $'high\tendpoint-missing'
has "DOCKER_HOST beating a stored context is named" "$out" $'low\tdocker-host-overrides-context'
out="$(doc windows-ports --ports 50010,5432,8080,3000,9999)"; rc=$?
expect_exit "doctor: Windows port checks" 10 "$rc"
has "a port inside a Windows-reserved range is high" "$out" "port 50010 is inside a range Windows has reserved (50000-50059"
has "a port held by another process" "$out" "port 5432 is held by postgres.exe"
has "a port held by Docker's own backend is a published container" "$out" $'info\tport-published\tport 8080'
has "a port held inside running WSL is reported" "$out" $'medium\tport-in-use-wsl\tport 3000'
has "a free port is a fact" "$out" $'fact\tport:9999\tfree'
has "the legacy docker_engine pipe is ambiguous" "$out" $'info\tendpoint-ambiguous'
out="$(doc admin)"; rc=$?
expect_exit "doctor: info-only findings do not set exit 10" 0 "$rc"
has "admin-locked names the key" "$out" "exposeDockerAPIOnTCP2375"
hasnt "admin-locked skips unlocked keys" "$out" "proxy"
out="$(doc winctr)"
has "Windows-containers mode is reported" "$out" $'low\twindows-containers'
out="$(doc hang --timeout 1)"; rc=$?
expect_exit "doctor: docker hangs on every probe" 7 "$rc"
doc none >/dev/null; expect_exit "doctor: no runtime at all" 3 $?
# The socket check goes through the fake host: a runner with Docker installed (GitHub's
# Ubuntu images) has a real /var/run/docker.sock, which turned "none" into exit 10 on CI only.
out="$(doc socket-present)"; rc=$?
expect_exit "doctor: no CLI but the default socket exists" 10 "$rc"
has "a socket without a CLI is cli-missing, not no-runtime" "$out" $'medium\tcli-missing'
doc badcfg >/dev/null; expect_exit "doctor: unreadable config.json" 4 $?
doc healthy --ports 80,nope >/dev/null; expect_exit "doctor: bad --ports" 2 $?
doc healthy --timeout 0 >/dev/null; expect_exit "doctor: bad --timeout" 2 $?
"$PY" "$runner" bloat "$doctor" --json > "$tmp/doctor.json" 2>/dev/null
"$PY" - "$tmp/doctor.json" <<'EOF' && ok "doctor --json envelope" || bad "doctor --json envelope malformed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["meta"]["schema"] == "claude-mods.docker-ops.doctor/v1"
assert d["meta"]["facts"]["provider"] == "colima" and d["meta"]["count"] == len(d["data"]) == 1
assert set(d["data"][0]) == {"severity", "check", "detail"}
EOF
# The read-only promise, checked: across every scenario above, the doctor asked docker
# for nothing but these four probes.
other="$(grep -vE '^(context inspect|version --format|info --format|system df --format) ' "$STUB_LOG" || true)"
[ -s "$STUB_LOG" ] && ok "the stub saw $(wc -l < "$STUB_LOG" | tr -d ' ') docker calls" || bad "the stub saw no docker calls"
[ -z "$other" ] && ok "doctor only ever runs read-only docker probes" || bad "doctor ran: $other"
unset STUB_LOG
# ...and the guard behind that promise refuses anything else, even if a later edit asks.
"$PY" - "$doctor" "$fixtures/doctor/docker_stub.py" <<'EOF' && ok "doctor's guard refuses destructive docker calls" || bad "doctor's guard let a destructive call through"
import importlib.util, os, sys
os.environ["DOCKER_DOCTOR_DOCKER"] = sys.argv[2]
os.environ.pop("DOCKER_DOCTOR_FAKE_HOST", None)
spec = importlib.util.spec_from_file_location("doctor", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
probe = mod.Probe(5)
for call in (("system", "prune", "-f"), ("rm", "-f", "x"), ("desktop", "start"), ("run", "alpine"), ("volume", "rm", "v")):
    try:
        probe.docker_cmd(*call)
    except RuntimeError:
        continue
    raise SystemExit(f"allowed: docker {' '.join(call)}")
EOF

# === 13. Image-tag verifier: offline inventory, live classification on canned answers ===
tags="$here/scripts/check-image-tags.py"
itf="$fixtures/image-tags"
out="$("$PY" "$tags" "$itf" 2>/dev/null)"; rc=$?
expect_exit "image-tags offline with a malformed reference" 4 "$rc"
has "FROM is inventoried" "$out" $'pinned\tnode:24-slim\tDockerfile:2'
has "COPY --from=<image> is inventoried" "$out" $'pinned\tghcr.io/astral-sh/uv:0.9.0\tDockerfile:5'
hasnt "COPY --from=<stage> is not an image" "$out" $'\tbuild\t'
has "a \${VAR} reference is variable" "$out" $'variable\tpython:${PY_VERSION}-slim'
has "no tag is floating" "$out" $'floating\tubuntu'
has "an example name is a placeholder" "$out" $'placeholder\tmyapp:1.0'
has "an upper-case repository is malformed" "$out" $'malformed\tNode:24'
has "Compose image: is inventoried" "$out" $'pinned\tpostgres:99-bookworm\tcompose.yaml:3'
has "Markdown dockerfile fences are read" "$out" $'pinned\tgolang:1.27-trixie\tnotes.md:6'
has "Markdown yaml fences are read" "$out" $'pinned\tregistry.k8s.io/pause:3.10\tnotes.md:16'
hasnt "Markdown prose outside fences is not" "$out" "ignored:1.0"
hasnt "a FROM <stage> inside a fence is not an image" "$out" $'\tbuild\tnotes.md'
out="$("$PY" "$tags" "$itf" --live --fixtures "$itf/answers.json" 2>/dev/null)"; rc=$?
expect_exit "image-tags live: a missing tag wins over uncertain" 10 "$rc"
has "a 404 is missing" "$out" $'missing\tpostgres:99-bookworm'
has "a 429 is uncertain, not missing" "$out" $'uncertain\tredis:8.2-alpine\tcompose.yaml:5\tHTTP 429'
has "an absent arm64 image is missing" "$out" "no linux/arm64 image (has linux/amd64)"
has "a multi-arch tag is ok" "$out" $'ok\tnode:24-slim'
out="$("$PY" "$tags" "$itf" --live --fixtures "$itf/answers.json" --platforms linux/amd64 --ignore-ref 'postgres:*' 2>/dev/null)"; rc=$?
expect_exit "image-tags live: only uncertain left is advisory" 7 "$rc"
has "--platforms narrows the platform check" "$out" $'ok\tquay.io/acmecorp/tool:2.1'
has "--ignore-ref skips a reference" "$out" $'ignored\tpostgres:99-bookworm'
"$PY" "$tags" "$itf" --fixtures "$itf/answers.json" >/dev/null 2>&1; expect_exit "--fixtures without --live" 2 $?
"$PY" "$tags" "$tmp/nope" >/dev/null 2>&1; expect_exit "image-tags missing path" 3 $?
"$PY" "$tags" "$fixtures/clean" --json 2>/dev/null | "$PY" -c \
  "import json,sys; d=json.load(sys.stdin); assert d['meta']['schema']=='claude-mods.docker-ops.image-tags/v1' and d['data']" \
  && ok "image-tags --json envelope" || bad "image-tags --json envelope malformed"

# === 14. Facts verifier: offline prose consistency, live drift on canned sources ===
facts="$here/scripts/check-docker-facts.py"
ff="$fixtures/facts"
mkdir -p "$tmp/fskill/docker-ops/references" "$tmp/fskill/kubernetes-ops"
"$PY" - "$here/assets/docker-facts.json" "$tmp/fskill" <<'EOF'
import json, sys, pathlib
cat = json.load(open(sys.argv[1])); root = pathlib.Path(sys.argv[2])
own = [t["token"] for t in cat["prose_tokens"] if t.get("skill", "docker-ops") == "docker-ops"]
k8s = [t["token"] for t in cat["prose_tokens"] if t.get("skill") == "kubernetes-ops"]
(root / "docker-ops" / "SKILL.md").write_text(f"Versions verified {cat['as_of']}.\n" + "\n".join(own) + "\n")
(root / "kubernetes-ops" / "SKILL.md").write_text("\n".join(k8s) + "\n")
EOF
"$PY" "$facts" --offline --skill "$tmp/fskill/docker-ops" >/dev/null 2>&1; expect_exit "facts offline: every token stated" 0 $?
"$PY" - "$tmp/fskill/docker-ops/SKILL.md" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("Compose v5", "Compose v2"))
EOF
out="$("$PY" "$facts" --offline --skill "$tmp/fskill/docker-ops" 2>/dev/null)"; rc=$?
expect_exit "facts offline: a dropped token is drift" 10 "$rc"
has "the dropped token is named" "$out" $'token:compose-major\tdrift'
rm -rf "$tmp/fskill/kubernetes-ops"
out="$("$PY" "$facts" --offline --skill "$tmp/fskill/docker-ops" 2>/dev/null)"
has "kubernetes-ops tokens are skipped when that skill is absent" "$out" $'token:k8s-minor\tskipped'
out="$("$PY" "$facts" --live --fixtures "$ff" --today 2026-10-07 2>/dev/null)"; rc=$?
expect_exit "facts live: canned sources match the catalog" 0 "$rc"
has "a newer release candidate is not drift" "$out" $'release:compose\tok'
has "the EOL floor is read from endoflife.date" "$out" $'eol:python\tok\toldest supported python line 3.11'
has "the Desktop compaction watch reads the notes" "$out" "no release from 4.59 to 4.94.0 mentions compaction"
cp -r "$ff" "$tmp/ffd"
printf '[{"tag_name": "v6.0.0", "draft": false, "prerelease": false}]\n' > "$tmp/ffd/releases-compose.json"
printf '## 4.95.0\n\n- Re-enabled VHDX compaction for the WSL data disk.\n\n' | cat - "$ff/desktop-release-notes.md" > "$tmp/ffd/desktop-release-notes.md"
out="$("$PY" "$facts" --live --fixtures "$tmp/ffd" --today 2026-10-07 2>/dev/null)"; rc=$?
expect_exit "facts live: upstream moved" 10 "$rc"
has "a new Compose major is drift" "$out" $'release:compose\tdrift'
has "a release that mentions compaction is drift" "$out" $'desktop:compaction\tdrift'
out="$("$PY" "$facts" --live --fixtures "$ff" --today 2027-05-01 2>/dev/null)"
has "time passing moves an EOL floor (Node 22 ends 2027-04-30)" "$out" $'eol:node\tdrift'
rm -f "$tmp/ffd/eol-php.json"; cp "$ff/releases-compose.json" "$ff/desktop-release-notes.md" "$tmp/ffd/"
out="$("$PY" "$facts" --live --fixtures "$tmp/ffd" --today 2026-10-07 2>/dev/null)"; rc=$?
expect_exit "facts live: an unreachable source is advisory" 7 "$rc"
has "the unreachable source is named" "$out" $'eol:php\tunavailable'
"$PY" "$facts" --fixtures "$ff" >/dev/null 2>&1; expect_exit "facts --fixtures without --live" 2 $?
printf '{"schema": "claude-mods.docker-ops.facts/v1", "as_of": "2026-10-07"}' > "$tmp/thin.json"
"$PY" "$facts" --catalog "$tmp/thin.json" >/dev/null 2>&1; expect_exit "facts: a catalog without its tables" 4 $?
"$PY" "$facts" --catalog "$tmp/none.json" >/dev/null 2>&1; expect_exit "facts: a missing catalog" 3 $?

# === 15. The shipped starters pass the auditor (they promise to in their headers) ===
mkdir -p "$tmp/tpl"
cp "$here/assets/Dockerfile.template" "$tmp/tpl/Dockerfile"
cp "$here/assets/compose.template.yaml" "$tmp/tpl/compose.yaml"
printf '.git\n.env*\nsecrets\n' > "$tmp/tpl/.dockerignore"
out="$("$PY" "$audit" "$tmp/tpl" 2>/dev/null)"; rc=$?
expect_exit "templates: no findings" 0 "$rc"
[ -z "$out" ] || note "    " "$out"
out="$("$PY" "$audit" "$tmp/tpl" --production 2>/dev/null)"
other="$(printf '%s\n' "$out" | grep -v $'\tbase-not-digest\t' | grep . || true)"
[ -z "$other" ] && ok "templates: --production adds only base-digest notes" || bad "templates under --production: $other"
# And the facts the skill states are still stated (the PR-CI half of the staleness pattern).
"$PY" "$facts" --offline >/dev/null 2>&1; expect_exit "this skill's prose matches assets/docker-facts.json" 0 $?

finish
