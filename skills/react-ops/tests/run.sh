#!/usr/bin/env bash
# Offline self-test for the react-ops skill — structure, frontmatter, and the
# staleness-verifier contract (SKILL-RESOURCE-PROTOCOL.md §7, §10).
#
# Offline-deterministic (no network, no React install). Resolves paths relative
# to itself so it works in the repo and once installed to ~/.claude/skills/.
#
# Usage:   bash tests/run.sh
# Input:   none (self-contained; no network)
# Output:  TAP-ish progress on stderr; final PASS/FAIL line.
# Exit:    0 all pass, 1 any failure
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
DOC="$SKILL/SKILL.md"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1" >&2; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1" >&2; }

# Resolve a *working* python (python3, else python). The bare `command -v` is
# not enough on Windows, where `python3` is a Microsoft Store stub that exits
# nonzero. Skip the whole verifier block if none works.
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PY="$c"; break; fi
done

echo "=== react-ops self-test ===" >&2

# ── SKILL.md frontmatter ───────────────────────────────────────────────────
[[ -f "$DOC" ]] && ok "SKILL.md present" || { no "SKILL.md missing"; echo "=== $PASS passed, $FAIL failed ===" >&2; exit 1; }
doc="$(cat "$DOC")"
case "$doc" in *"name: react-ops"*) ok "frontmatter declares name: react-ops";; *) no "frontmatter name != react-ops";; esac
case "$doc" in *"license: MIT"*) ok "frontmatter declares license: MIT";; *) no "missing license: MIT";; esac
case "$doc" in *"as of 20"*) ok "currency note carries a year";; *) no "no dated 'as of <year>' currency note";; esac

# ── resources present + cited ──────────────────────────────────────────────
for res in assets/react-facts.json scripts/check-react-facts.py; do
  [[ -f "$SKILL/$res" ]] && ok "resource present: $res" || no "missing resource: $res"
done
case "$doc" in *"scripts/check-react-facts.py"*) ok "verifier cited from SKILL.md";; *) no "verifier uncited";; esac

# ── staleness verifier: offline contract (§7) ───────────────────────────────
if [[ -n "$PY" ]]; then
  V="$SKILL/scripts/check-react-facts.py"
  F="$SKILL/assets/react-facts.json"
  ec() { local want="$1" lbl="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?
         [[ "$got" == "$want" ]] && ok "$lbl (exit $got)" || no "$lbl (want $want got $got)"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ec 0 "py_compile"            "$PY" -m py_compile "$V"
  ec 0 "--help"                "$PY" "$V" --help
  ec 0 "--offline consistent"  "$PY" "$V" --offline
  ec 2 "bad flag -> 2"         "$PY" "$V" --bogus
  ec 2 "conflicting modes -> 2" "$PY" "$V" --offline --live
  jout="$("$PY" "$V" --offline --json 2>/dev/null)"
  case "$jout" in *"claude-mods.react-ops.facts/v1"*) ok "--json envelope schema";; *) no "--json envelope schema missing";; esac
  ec 3 "missing facts -> 3"    "$PY" "$V" --offline --facts "$TMP/nope.json"
  printf '{"schema":"claude-mods.react-ops.facts/v1","packages":{"zzz":{"documented_major":1,"prose":["zzznotreal"]}}}' > "$TMP/drift.json"
  ec 10 "uncited package -> 10" "$PY" "$V" --offline --facts "$TMP/drift.json"
else
  no "no working python to exercise the verifier"
fi

echo "=== $PASS passed, $FAIL failed ===" >&2
[[ "$FAIL" -eq 0 ]] || exit 1
