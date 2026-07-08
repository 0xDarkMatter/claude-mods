#!/usr/bin/env bash
# Self-test for the summon skill (scripts/summon.py).
#
# Offline-deterministic: builds a throwaway Claude Desktop dir tree in a temp
# sandbox (HOME/USERPROFILE/APPDATA redirected), so no real account data is
# read or written. Covers the selection/confirmation flow (--yes, --select,
# piped stdin), the cp1252 UnicodeEncodeError regression, the toolbox modes
# (rebind/recover/pick/doctor, incl. the worktree-repair hint), and the
# distilled-handover flow (extraction skips tool blobs, cache hit/miss on
# mtime, --no-distill, degrade paths via a PATH-shimmed fake `claude` —
# no real LLM call is ever made by this suite), the pick --json inventory
# envelope, and the in-chat picker asset (present + cited from SKILL.md).
#
# The behavioural checks live in test_summon.py — its pass/fail summary is the
# primary signal. One shell-level check also runs after it (below): a
# section-map drift gate that pins the docstring 'Sections:' list against the
# body's `# ===` banner headers, so the deliberately-single-file script's map
# cannot silently rot as it grows.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pick a python that actually executes — skips the Windows Store python3 stub.
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }

# Run the full behavioural suite, then fall through to the shell-level
# section-map drift gate (we deliberately do NOT `exec` the python here — the
# gate must run afterwards and contribute to the combined exit code).
SUMMON_PY_RC=0
"$PYTHON" "$HERE/test_summon.py" || SUMMON_PY_RC=$?

# --- section-map drift gate (summon.py docstring 'Sections:' ↔ # === banners) ---
# summon.py is deliberately a single multi-thousand-line file
# (docs/SKILL-RESOURCE-PROTOCOL.md: skill scripts ship as self-contained
# portable units — do not split). Its module docstring carries a `Sections:`
# map of the `# ===` banner headers so the file stays navigable. This gate
# pins BOTH the docstring section count and the body banner count, so a
# section added or removed on either side fails the build until the map is
# reconciled. An empty parse on either side is a hard FAIL (never a silent
# pass) — that is the rot mode this guard exists to catch: a docstring/map
# format change that yields zero names.
#
# Strict name-equality matching is intentionally NOT used: the docstring and
# the banner headers carry different labels for several sections
# ("DESIGN(term)"↔"DESIGN", "Modes (…)"↔"Toolbox modes", "CLI entry"↔"Main")
# and the map lists "Transcript/Distill" with no banner of its own, so a
# name gate would false-fail on the current file. The count gate is the
# mechanical structural-sync check that stays green and still catches every
# add/remove mutation.
GP=0; GF=0
ok(){ GP=$((GP+1)); printf '  PASS  %s\n' "$1"; }
no(){ GF=$((GF+1)); printf '  FAIL  %s\n' "$1"; }

SRC="$HERE/../scripts/summon.py"

# docstring section names: from the first `Sections:` line to the next `"""`.
doc_sections="$(awk '
  !done && /Sections:/ { cap=1; sub(/.*Sections:[[:space:]]*/,"",$0); blob=blob $0 " "; next }
  cap { if (/"""/) { done=1; cap=0; next } blob=blob $0 " " }
  END { gsub(/·/,"\n",blob); n=split(blob,a,"\n");
        for (i=1;i<=n;i++){ s=a[i]; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); sub(/\.$/,"",s); if (s!="") print s } }
' "$SRC")"
dc="$(printf '%s\n' "$doc_sections" | grep -c . || true)"

# body banner sections: the `# ===…===` header pairs — the name line that
# sits between each opening banner and its closing banner.
ban_sections="$(awk '
  /^# ={20,}$/ { saw=1; next }
  saw && /^#  / { t=$0; sub(/^# +/,"",t); sub(/[[:space:]]+$/,"",t); print t }
  { saw=0 }
' "$SRC")"
bc="$(printf '%s\n' "$ban_sections" | grep -c . || true)"

# Expected counts — the docstring lists one more conceptual section than the
# body has banners ("Transcript/Distill" is implemented inline, banner-less).
# Bump EXPECT_DOC when the 'Sections:' map grows; EXPECT_BAN when a banner is
# added or removed. Both move together whenever the file's outline changes.
EXPECT_DOC=14
EXPECT_BAN=13

# forward direction (the map side): the declared section count is stable
if [[ "$dc" -eq 0 ]]; then
  no "section-map (docstring) EMPTY PARSE: 0 sections — 'Sections:' line missing or unparseable (expected $EXPECT_DOC)"
elif [[ "$dc" -eq "$EXPECT_DOC" ]]; then
  ok "section-map (docstring): $dc sections declared (expected $EXPECT_DOC)"
else
  no "section-map (docstring) DRIFT: parsed $dc, expected $EXPECT_DOC"
fi
# reverse direction (the body side): the banner section count is stable
if [[ "$bc" -eq 0 ]]; then
  no "section-map (body) EMPTY PARSE: 0 banners — banner format changed (expected $EXPECT_BAN)"
elif [[ "$bc" -eq "$EXPECT_BAN" ]]; then
  ok "section-map (body): $bc banner sections (expected $EXPECT_BAN)"
else
  no "section-map (body) DRIFT: parsed $bc, expected $EXPECT_BAN"
fi

echo "=== section-map drift gate: $GP passed, $GF failed ==="

# Combine: the Python behavioural suite AND the shell section-map gate pass.
[[ "$SUMMON_PY_RC" -eq 0 && "$GF" -eq 0 ]] || exit 1
exit 0
