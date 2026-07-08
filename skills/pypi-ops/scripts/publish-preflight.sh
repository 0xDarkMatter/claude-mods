#!/usr/bin/env bash
# Pre-release readiness check for a PyPI package — catch mechanical failures before tagging.
#
# Verifies the things that silently break a release: version skew across
# pyproject/__init__/lockfile, a version that is ALREADY on PyPI (uploads are
# immutable — you cannot re-push 1.2.3), a git tag that disagrees with the
# version, and a publish workflow that uses a stored token instead of OIDC.
# Read-only; queries the public PyPI JSON API (no auth).
#
# Usage:   publish-preflight.sh [--json] [--build] [-q] [<repo-root>]
# Input:   repo root as an optional positional (default "."); reads pyproject.toml,
#          the package __init__.py, uv.lock, and .github/workflows/*.yml.
#          --build additionally builds the dist and runs `twine check` (slower).
# Output:  stdout = per-check records (TSV: check<TAB>ok<TAB>detail, or --json envelope)
# Stderr:  headers, progress, the human summary
# Exit:    0 ready (all checks pass/skip), 2 usage, 3 no pyproject, 5 missing-dep,
#          7 pypi-unreachable, 10 not-ready (>=1 check failed)
#
# Examples:
#   publish-preflight.sh .
#   publish-preflight.sh --build .                 # also verify it builds + twine check
#   publish-preflight.sh --json ~/code/mypkg | jq '.data[] | select(.ok==false)'
#   publish-preflight.sh -q . && echo "ready to tag"

set -uo pipefail

EXIT_OK=0; EXIT_USAGE=2; EXIT_NOPROJ=3; EXIT_MISSING_DEP=5; EXIT_UNAVAIL=7; EXIT_NOTREADY=10

JSON=0; QUIET=0; BUILD=0; ROOT="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)     JSON=1 ;;
    --build)    BUILD=1 ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "$EXIT_OK" ;;
    -*) echo "ERROR: unknown flag: $1 (try --help)" >&2; exit "$EXIT_USAGE" ;;
    *)  ROOT="$1" ;;
  esac
  shift
done

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required" >&2; exit "$EXIT_MISSING_DEP"; }
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
if [[ "$JSON" -eq 1 && "$HAS_JQ" -eq 0 ]]; then
  echo '{"error":{"code":"MISSING_DEPENDENCY","message":"jq required for --json"}}'
  echo "ERROR: jq required for --json" >&2; exit "$EXIT_MISSING_DEP"
fi

ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || { echo "ERROR: no such directory" >&2; exit "$EXIT_NOPROJ"; }
PYPROJECT="$ROOT/pyproject.toml"
[[ -f "$PYPROJECT" ]] || { echo "ERROR: no pyproject.toml in $ROOT" >&2; exit "$EXIT_NOPROJ"; }

emit() { [[ "$QUIET" -eq 1 ]] && return; printf '%s\n' "$*" >&2; }

# --- minimal TOML field reads (regex; avoids a tomllib/py3.11 dependency) ------
toml_field() {  # key  -> first  key = "value"  at column 0
  sed -n -E "s/^$1[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" "$PYPROJECT" | head -1
}
NAME="$(toml_field name)"
VERSION="$(toml_field version)"
DYNAMIC_VERSION=0
grep -Eq '^dynamic[[:space:]]*=.*version' "$PYPROJECT" && DYNAMIC_VERSION=1

# hatch-vcs / setuptools-scm: the version is the VCS tag, not a literal. Derive it
# from a version tag on HEAD so dynamic-versioned projects get real checks too.
VCS_VERSION=0
if [[ -z "$VERSION" && "$DYNAMIC_VERSION" -eq 1 ]] && command -v git >/dev/null 2>&1; then
  _ht="$(git -C "$ROOT" tag --points-at HEAD 2>/dev/null | grep -E '^v?[0-9]' | head -1)"
  [[ -n "$_ht" ]] && { VERSION="${_ht#v}"; VCS_VERSION=1; }
fi

# --- check accumulator ---------------------------------------------------------
NOTREADY=0; UNAVAIL=0; RECORDS=()
add() {  # check  ok(true/false/skip)  detail
  local ok="$2"
  [[ "$ok" == "false" ]] && NOTREADY=1
  RECORDS+=("$(printf '%s\t%s\t%s' "$1" "$ok" "$3")")
  if [[ "$QUIET" -ne 1 ]]; then
    local mark="·"; [[ "$ok" == "true" ]] && mark="ok"; [[ "$ok" == "false" ]] && mark="XX"; [[ "$ok" == "skip" ]] && mark="--"
    printf '  [%s] %-22s %s\n' "$mark" "$1" "$3" >&2
  fi
}

emit "=== publish preflight: ${NAME:-?} ${VERSION:-?} ($ROOT) ==="

# 1. name present
[[ -n "$NAME" ]] && add "name" true "$NAME" || add "name" false "pyproject [project].name not found"

# 2. version resolvable
if [[ -n "$VERSION" && "$VCS_VERSION" -eq 1 ]]; then
  add "pyproject-version" true "$VERSION (dynamic, from VCS tag)"
elif [[ -n "$VERSION" ]]; then
  add "pyproject-version" true "$VERSION"
elif [[ "$DYNAMIC_VERSION" -eq 1 ]]; then
  add "pyproject-version" skip "dynamic version, no tag on HEAD — tag first, then re-run"
else
  add "pyproject-version" false "no [project].version and not declared dynamic"
fi

# 3. __init__ __version__ agreement (find the literal assignment, skip vendored trees)
INIT_FILE="$(grep -rIlE --include='__init__.py' '^__version__[[:space:]]*=' "$ROOT/src" "$ROOT" 2>/dev/null \
  | grep -vE '/(\.venv|venv|site-packages|\.tox|build|dist|node_modules)/' | head -1)"
if [[ -n "$INIT_FILE" ]]; then
  IVER="$(sed -n -E "s/^__version__[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" "$INIT_FILE" | head -1)"
  REF="${VERSION:-}"
  if [[ "$DYNAMIC_VERSION" -eq 1 && -z "$REF" ]]; then REF="$IVER"; fi
  if [[ -z "$IVER" ]]; then
    add "init-version" skip "no __version__ literal in $(basename "$INIT_FILE")"
  elif [[ "$IVER" == "$REF" ]]; then
    add "init-version" true "$IVER matches"
  else
    add "init-version" false "__version__=$IVER != pyproject=$REF"
  fi
else
  add "init-version" skip "no __init__.py with __version__ found"
fi

# 4. lockfile self-version (uv.lock) agreement
EFFVER="${VERSION:-${IVER:-}}"
if [[ -f "$ROOT/uv.lock" && -n "$NAME" && -n "$EFFVER" ]]; then
  LVER="$(awk -v n="\"$NAME\"" '
    $1=="name" && $3==n {f=1; next}
    f==1 && $1=="version" {gsub(/"/,"",$3); print $3; exit}' \
    FS=' ' "$ROOT/uv.lock" 2>/dev/null)"
  if [[ -z "$LVER" ]]; then
    add "lock-version" skip "package not pinned in uv.lock"
  elif [[ "$LVER" == "$EFFVER" ]]; then
    add "lock-version" true "$LVER matches"
  else
    add "lock-version" false "uv.lock has $LVER != $EFFVER (run: uv lock)"
  fi
else
  add "lock-version" skip "no uv.lock"
fi

# 5. version not already on PyPI (immutable); flag a brand-new project (first publish)
if [[ -n "$NAME" && -n "$EFFVER" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 \
    "https://pypi.org/pypi/${NAME}/${EFFVER}/json" 2>/dev/null)"
  case "$code" in
    404)
      add "not-on-pypi" true "${EFFVER} is free to publish"
      # distinguish "new version of an existing project" from "first ever publish"
      pcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 \
        "https://pypi.org/pypi/${NAME}/json" 2>/dev/null)"
      if [[ "$pcode" == "404" ]]; then
        add "first-publish" skip "NEW project — register a PENDING publisher on PyPI BEFORE tagging, or the publish fails 'invalid-publisher' (SKILL.md)"
      fi
      ;;
    200) add "not-on-pypi" false "${NAME}==${EFFVER} ALREADY on PyPI — bump the version" ;;
    000) UNAVAIL=1; add "not-on-pypi" skip "PyPI unreachable (advisory)" ;;
    *)   UNAVAIL=1; add "not-on-pypi" skip "PyPI returned HTTP $code (advisory)" ;;
  esac
else
  add "not-on-pypi" skip "need name+version to query"
fi

# 6. git tag agreement (if HEAD is tagged, or a v<version> tag exists)
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  HEADTAG="$(git -C "$ROOT" tag --points-at HEAD 2>/dev/null | grep -E '^v?[0-9]' | head -1)"
  if [[ -n "$HEADTAG" && -n "$EFFVER" ]]; then
    if [[ "$HEADTAG" == "v$EFFVER" || "$HEADTAG" == "$EFFVER" ]]; then
      add "git-tag" true "HEAD tagged $HEADTAG"
    else
      add "git-tag" false "HEAD tag $HEADTAG != v$EFFVER"
    fi
  else
    add "git-tag" skip "HEAD not tagged (tag after preflight passes)"
  fi
else
  add "git-tag" skip "not a git repo"
fi

# 7. publish workflow uses OIDC, not a stored token
WF=""
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
  [[ -f "$f" ]] || continue
  if grep -Eq 'pypi|gh-action-pypi-publish|twine upload|uv publish' "$f"; then WF="$f"; break; fi
done
if [[ -n "$WF" ]]; then
  if grep -Eq 'id-token:[[:space:]]*write' "$WF"; then
    if grep -Eq '^[[:space:]]*password:|PYPI_API_TOKEN|PYPI_TOKEN' "$WF"; then
      add "workflow-oidc" false "$(basename "$WF") has OIDC but ALSO a stored token — drop the token"
    else
      add "workflow-oidc" true "$(basename "$WF") uses OIDC trusted publishing"
    fi
  elif grep -Eq '^[[:space:]]*password:|PYPI_API_TOKEN|PYPI_TOKEN' "$WF"; then
    add "workflow-oidc" false "$(basename "$WF") uses a stored token — migrate to OIDC (id-token: write)"
  else
    add "workflow-oidc" skip "$(basename "$WF") found but no OIDC/token marker recognised"
  fi
else
  add "workflow-oidc" skip "no PyPI publish workflow found under .github/workflows/"
fi

# 8. (opt-in) the package actually builds + passes twine check
if [[ "$BUILD" -eq 1 ]]; then
  BUILDER=""
  command -v uv >/dev/null 2>&1 && BUILDER="uv"
  if [[ -z "$BUILDER" ]] && command -v python >/dev/null 2>&1 && python -c "import build" >/dev/null 2>&1; then BUILDER="build"; fi
  if [[ -z "$BUILDER" ]]; then
    add "build" skip "no uv or python-build (pip install build) — skipping build check"
  else
    BOUT="$(mktemp -d)"; bok=0
    if [[ "$BUILDER" == "uv" ]]; then
      ( cd "$ROOT" && uv build --out-dir "$BOUT" ) >/dev/null 2>&1 && bok=1
    else
      ( cd "$ROOT" && python -m build --outdir "$BOUT" ) >/dev/null 2>&1 && bok=1
    fi
    if [[ "$bok" -ne 1 ]]; then
      add "build" false "build failed — run '$BUILDER build' directly to see why"
    else
      TW=""
      command -v twine >/dev/null 2>&1 && TW="twine"
      [[ -z "$TW" ]] && command -v uvx >/dev/null 2>&1 && TW="uvx twine"
      if [[ -n "$TW" ]]; then
        if $TW check "$BOUT"/* >/dev/null 2>&1; then add "build" true "builds + twine check ok"
        else add "build" false "built, but twine check failed (fix packaging metadata)"; fi
      else
        add "build" true "builds ok (no twine to validate metadata)"
      fi
    fi
    rm -rf "$BOUT"
  fi
fi

# --- output --------------------------------------------------------------------
if [[ "$JSON" -eq 1 ]]; then
  printf '%s\n' "${RECORDS[@]}" | jq -R 'split("\t") | {check:.[0], ok:(.[1]=="true"), status:.[1], detail:.[2]}' \
    | jq -s --arg name "$NAME" --arg version "$EFFVER" \
        '{data: ., meta:{name:$name, version:$version, count:length, ready:(any(.[]; .status=="false")|not), schema:"claude-mods.pypi-ops.publish-preflight/v1"}}'
else
  printf '%s\n' "${RECORDS[@]}"
fi

if [[ "$NOTREADY" -eq 1 ]]; then
  emit "=== NOT READY — resolve the [XX] checks before tagging ==="
  exit "$EXIT_NOTREADY"
fi
[[ "$UNAVAIL" -eq 1 ]] && { emit "=== checks passed; PyPI lookup was advisory (unreachable) ==="; exit "$EXIT_UNAVAIL"; }
emit "=== READY to tag $EFFVER ==="
exit "$EXIT_OK"
