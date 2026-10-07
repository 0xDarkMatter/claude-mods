#!/usr/bin/env bash
# Offline self-test for kubernetes-ops: layout, reference hygiene, and the doctrine the
# examples must keep (SKILL-RESOURCE-PROTOCOL section 10).
#
# The bugs this suite exists to catch:
#   - an example drifts back to the retired ingress-nginx annotations, or to a pod spec
#     that the restricted Pod Security Standard rejects;
#   - an example uses a floating `:latest` image, or a malformed image reference;
#   - the version facts docker-ops' check-docker-facts.py tracks for this skill
#     (Kubernetes minor, Helm major, Gateway API minor) stop being stated;
#   - a reference goes unlinked from SKILL.md, or grows past 100 lines without a Contents list.
#
# Usage:   tests/run.sh
#          KUBERNETES_OPS_DIR=<copy-of-skill> tests/run.sh   # run against a copy
# Input:   none (no cluster, no network)
# Output:  progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass, 1 any failure.
#
# Examples:
#   bash skills/kubernetes-ops/tests/run.sh
set -uo pipefail

here="${KUBERNETES_OPS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
skill="$here/SKILL.md"
fail=0
pass=0
note() { printf '  %s %s\n' "$1" "$2" >&2; }
ok()   { pass=$((pass+1)); note "ok  " "$1"; }
bad()  { fail=$((fail+1)); note "FAIL" "$1"; }
finish() {
  echo "kubernetes-ops tests: $pass passed, $fail failed" >&2
  [ "$fail" = "0" ] && { echo "PASS" >&2; exit 0; } || { echo "FAIL" >&2; exit 1; }
}

# === 1. Layout + frontmatter ===
for d in scripts references assets tests; do
  [ -d "$here/$d" ] && ok "dir $d/ exists" || bad "missing dir $d/"
done
[ -f "$skill" ] || { bad "SKILL.md missing"; finish; }
grep -q '^name: kubernetes-ops$' "$skill" && ok "name matches directory" || bad "name != kubernetes-ops"
grep -q '^license: MIT$' "$skill" && ok "license: MIT" || bad "missing license: MIT"
grep -q '^  author: claude-mods$' "$skill" && ok "metadata.author" || bad "missing metadata.author"
body="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$skill")"
body_tokens=$(( $(printf '%s' "$body" | wc -c | tr -d ' ') * 10 / 36 ))
[ "$body_tokens" -le 5000 ] && ok "body ~$body_tokens tokens (<=5000)" || bad "body ~$body_tokens tokens (>5000)"

# === 2. References ===
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
shipped=("$skill" "$here"/references/*.md)

# === 3. Doctrine the examples keep ===
# ingress-nginx is retired (2026-03): its annotations may appear only in gateway-api.md's
# translation table, never in an example someone copies.
hits="$(grep -l 'nginx.ingress.kubernetes.io' "${shipped[@]}" 2>/dev/null | grep -v 'gateway-api.md' || true)"
[ -z "$hits" ] && ok "no ingress-nginx annotations outside the migration table" || bad "ingress-nginx annotations in: $hits"
grep -q 'kind: Ingress$' "${shipped[@]}" && bad "an example still uses kind: Ingress" || ok "examples route with Gateway API, not Ingress"
# Restricted Pod Security: the workload example sets each required field.
for field in 'runAsNonRoot: true' 'seccompProfile: {type: RuntimeDefault}' 'allowPrivilegeEscalation: false' 'drop: \[ALL\]'; do
  grep -q "$field" "$skill" && ok "SKILL.md workload sets $field" || bad "SKILL.md workload lacks $field"
done
grep -nE 'image: [^ ]+:latest\b' "${shipped[@]}" >/dev/null && bad "an example image uses :latest" || ok "no :latest images in examples"
grep -q 'readOnlyRootFilesystem.*not.*require\|Restricted does not require it' "$skill" \
  && ok "SKILL.md does not claim Restricted requires readOnlyRootFilesystem" || bad "readOnlyRootFilesystem caveat missing"

# === 4. Facts docker-ops' verifier tracks for this skill ===
all="$(cat "${shipped[@]}")"
for token in "Kubernetes 1.37" "Helm 4" "Gateway API v1.6"; do
  case "$all" in *"$token"*) ok "states '$token'" ;; *) bad "no longer states '$token' (update assets/docker-facts.json in docker-ops too)" ;; esac
done

# === 5. Image references are well formed (needs the sibling docker-ops checker) ===
checker="$here/../docker-ops/scripts/check-image-tags.py"
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" --version >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -n "$PY" ] && [ -f "$checker" ]; then
  out="$("$PY" "$checker" "$here" 2>/dev/null)"; rc=$?
  [ "$rc" = "0" ] && ok "every image reference is well formed" || bad "malformed image references: $(printf '%s\n' "$out" | grep '^malformed' | tr '\n' ' ')"
else
  note "skip" "no python or no sibling docker-ops: image-reference check skipped"
fi

finish
