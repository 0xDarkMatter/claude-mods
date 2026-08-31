#!/usr/bin/env bash
# Offline self-test for github-ops scripts. No network required — exercises the
# contract + the gate-safety skip paths (graceful exit 7), not live GitHub data.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts"
CI="$SCRIPTS/check-issues.sh"
SP="$SCRIPTS/check-security-posture.sh"

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else no "$1 (want $2 got $3)"; fi; }

echo "-- check-issues.sh (offline contract + skip paths) --"

bash -n "$CI" && ok "bash -n clean" || no "bash -n"

bash "$CI" --help >/dev/null 2>&1; expect "--help" 0 $?
bash "$CI" --frobnicate >/dev/null 2>&1; expect "unknown flag -> usage" 2 $?

# Non-github remote must skip with exit 7 and NEVER hit the network.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
git -C "$T" remote add origin "/some/local/path.git"
( cd "$T" && bash "$CI" --remote origin >/dev/null 2>&1 ); expect "non-github remote -> unavailable" 7 $?

# Advisory mode on a non-github remote must be SILENT (no stderr) and exit 7 —
# this is the gate-safety contract: an unusable check never disturbs a push.
out="$( cd "$T" && bash "$CI" --advisory --remote origin 2>&1 )"; rc=$?
if [ "$rc" -eq 7 ] && [ -z "$out" ]; then ok "advisory non-github -> silent exit 7"
else no "advisory non-github (rc=$rc, stderr='$out')"; fi

# Missing remote -> skip 7 (git remote get-url fails; no network).
( cd "$T" && bash "$CI" --remote nope-xyz >/dev/null 2>&1 ); expect "missing remote -> unavailable" 7 $?

echo
echo "-- check-security-posture.sh (offline contract + skip paths) --"

bash -n "$SP" && ok "sp: bash -n clean" || no "sp: bash -n"

bash "$SP" --help >/dev/null 2>&1; expect "sp: --help" 0 $?
# --help must advertise EXAMPLES so the tool is discoverable.
# Never assert via `producer | grep -q` in this suite: under `set -o pipefail`,
# grep -q exits at the first match and the producer dies with SIGPIPE (141),
# flaking the pipeline non-zero even when the pattern is present. Capture the
# output once, then grep the variable (a here-string can't SIGPIPE).
sp_help="$(bash "$SP" --help 2>&1)"
if grep -q "Examples:" <<<"$sp_help"; then ok "sp: --help has EXAMPLES"
else no "sp: --help missing EXAMPLES"; fi

bash "$SP" --frobnicate >/dev/null 2>&1; expect "sp: unknown flag -> usage" 2 $?
# Malformed OWNER/REPO is a usage error, never a network call.
bash "$SP" --repo "not-a-valid-spec" >/dev/null 2>&1; expect "sp: bad --repo shape -> usage" 2 $?
# --repo and --org are mutually exclusive.
bash "$SP" --repo a/b --org c >/dev/null 2>&1; expect "sp: --repo + --org -> usage" 2 $?

# Non-github remote must skip with exit 7 and NEVER hit the network.
( cd "$T" && bash "$SP" --remote origin >/dev/null 2>&1 ); expect "sp: non-github remote -> unavailable" 7 $?
# Advisory mode on a non-github remote must be SILENT and exit 7.
out="$( cd "$T" && bash "$SP" --advisory --remote origin 2>&1 )"; rc=$?
if [ "$rc" -eq 7 ] && [ -z "$out" ]; then ok "sp: advisory non-github -> silent exit 7"
else no "sp: advisory non-github (rc=$rc, stderr='$out')"; fi
# Missing remote -> skip 7.
( cd "$T" && bash "$SP" --remote nope-xyz >/dev/null 2>&1 ); expect "sp: missing remote -> unavailable" 7 $?

# --commands emits the review banner on stderr (offline path: banner prints before
# any network work would, on a non-github remote it still skips — so assert the
# banner via the bundled help text instead, which is fully offline).
# The review banner string must be present in the source contract.
if grep -q "review before running — these change repo settings" "$SP"; then ok "sp: review banner string present"
else no "sp: review banner missing"; fi

# The SECURITY.md template asset must exist and be non-trivial.
if [ -s "$ROOT/assets/SECURITY.md.template" ] && grep -q "Reporting a Vulnerability" "$ROOT/assets/SECURITY.md.template"; then
  ok "sp: SECURITY.md.template asset present"
else no "sp: SECURITY.md.template asset missing/empty"; fi

# Read-only guarantee. The ONLY executor in this script is `runner gh api …`
# (every -X PUT/PATCH lives inside an emitted *_cmd string, never executed). Assert
# no `runner gh api` invocation carries a mutating verb.
sp_api_calls="$(grep -E 'runner gh api' "$SP")"   # captured, not piped — see SIGPIPE note above
if grep -Eq '\-X (PUT|PATCH|POST|DELETE)' <<<"$sp_api_calls"; then
  no "sp: found an executed mutating gh api call (must be read-only)"
else ok "sp: no executed mutating gh api call (read-only)"; fi
# And every mutating verb that DOES appear must be inside a quoted command string
# (assigned to a *_cmd var), proving it is emitted-as-text only.
# Inverted greps (-v) need the emptiness guard: an empty capture would feed the
# here-string's single empty line to grep -v, which would wrongly match.
sp_mut="$(grep -nE '\-X (PUT|PATCH|POST|DELETE)' "$SP")"
if [ -n "$sp_mut" ] && grep -vqE '_cmd=' <<<"$sp_mut"; then
  no "sp: a mutating verb appears outside an emitted *_cmd string"
else ok "sp: all mutating verbs are emitted text only"; fi

echo
echo "-- repo-scorecard.sh (offline contract + orchestration + read-only proof) --"

RS="$SCRIPTS/repo-scorecard.sh"

bash -n "$RS" && ok "rs: bash -n clean" || no "rs: bash -n"

bash "$RS" --help >/dev/null 2>&1; expect "rs: --help" 0 $?
rs_help="$(bash "$RS" --help 2>&1)"   # captured, not piped — see SIGPIPE note above
if grep -q "Examples:" <<<"$rs_help"; then ok "rs: --help has EXAMPLES"
else no "rs: --help missing EXAMPLES"; fi
# The scoring rubric must be documented in the header (transparent, auditable).
if grep -q "SCORING MODEL" <<<"$rs_help"; then ok "rs: --help documents SCORING MODEL"
else no "rs: --help missing SCORING MODEL"; fi

bash "$RS" --frobnicate >/dev/null 2>&1; expect "rs: unknown flag -> usage" 2 $?
# Malformed OWNER/REPO is a usage error, never a network call.
bash "$RS" --repo "not-a-valid-spec" >/dev/null 2>&1; expect "rs: bad --repo shape -> usage" 2 $?
# --repo and --org are mutually exclusive.
bash "$RS" --repo a/b --org c >/dev/null 2>&1; expect "rs: --repo + --org -> usage" 2 $?
# --min-score must be an integer.
bash "$RS" --min-score xx >/dev/null 2>&1; expect "rs: bad --min-score -> usage" 2 $?

# Non-github remote must skip with exit 7 and NEVER hit the network.
( cd "$T" && bash "$RS" --remote origin >/dev/null 2>&1 ); expect "rs: non-github remote -> unavailable" 7 $?
# Missing remote -> skip 7.
( cd "$T" && bash "$RS" --remote nope-xyz >/dev/null 2>&1 ); expect "rs: missing remote -> unavailable" 7 $?

# Orchestration: it MUST call the sibling auditors by name (the reuse is the point).
if grep -q "check-security-posture.sh" "$RS"; then ok "rs: references check-security-posture.sh"
else no "rs: does not reference check-security-posture.sh"; fi
if grep -q "check-issues.sh" "$RS"; then ok "rs: references check-issues.sh"
else no "rs: does not reference check-issues.sh"; fi

# Read-only guarantee: no executed mutating gh verb anywhere. Every gh call must
# be a GET (the remediation pointers it prints are text, not executed). Assert no
# `gh api -X PUT/PATCH/POST/DELETE` and no `gh repo edit`/`gh release create` etc.
rs_mut="$(grep -E '\bgh (api )?-X (PUT|PATCH|POST|DELETE)' "$RS")"   # captured — SIGPIPE note above
if [ -n "$rs_mut" ] && grep -vqE '^\s*#' <<<"$rs_mut"; then
  no "rs: found an executed mutating gh -X call (must be read-only)"
else ok "rs: no executed mutating gh -X call (read-only)"; fi
# Belt-and-braces: every `runner gh …` (the only network executor) is a read-only
# subcommand — `gh api <GET path>` or `gh repo list`. No mutating subcommand runs.
rs_runner="$(grep -nE 'runner gh ' "$RS")"
if [ -n "$rs_runner" ] && grep -Evq 'runner gh (api|repo list)' <<<"$rs_runner"; then
  no "rs: a 'runner gh' call uses a non-read-only subcommand"
else ok "rs: every executed 'runner gh' is read-only (api / repo list)"; fi
# And mutating gh subcommands, where they appear, are inside printed fix strings only
# (the remediation pointers), never executed. Verify they sit on addfix/echo lines.
rs_ghsub="$(grep -nE 'gh (release create|repo edit|release delete|secret set|pr merge)' "$RS")"
if [ -n "$rs_ghsub" ] && grep -vqE 'addfix|→' <<<"$rs_ghsub"; then
  no "rs: a mutating gh subcommand appears outside a printed remediation string"
else ok "rs: mutating gh subcommands only appear as printed remediation text"; fi

echo
echo "-- README landing-page reference (existence, citation, contract) --"

# CONTRACT NOTE for future edit lanes: these assertions bind SKILL.md's *content*,
# not just the reference file. If you move or rename references/readme-landing-page.md,
# or drop its citations from the conventions table / mode new / mode update / mode audit,
# this block fails on purpose — an uncited reference is dead weight the router never finds.
LP="$ROOT/references/readme-landing-page.md"
SK="$ROOT/SKILL.md"

if [ -s "$LP" ]; then ok "landing-page reference exists and is non-empty"
else no "references/readme-landing-page.md missing or empty"; fi

# It must actually cover the four things it owns; a stub that only exists to satisfy
# the citation check would pass a bare -s test.
lp_body="$(cat "$LP" 2>/dev/null)"   # captured, not piped — see SIGPIPE note above
for topic in "Two registers" "Badge row" "Features as benefits" "Screenshots and demo media" "Anti-patterns"; do
  if grep -qF "$topic" <<<"$lp_body"; then ok "reference covers: $topic"
  else no "reference missing section: $topic"; fi
done

# The badge guidance is worthless without the brand-pairing lever and the
# most-common misconfiguration; both are named failure modes in the brief.
if grep -qF "labelColor" <<<"$lp_body"; then ok "reference documents labelColor"
else no "reference does not mention labelColor"; fi
if grep -qF "docs/screenshots/" <<<"$lp_body"; then ok "reference pins screenshots to docs/screenshots/"
else no "reference does not name docs/screenshots/"; fi
if grep -qF "prefers-color-scheme" <<<"$lp_body"; then ok "reference documents the <picture> dark-mode pattern"
else no "reference missing prefers-color-scheme guidance"; fi

# Register axis: both registers must be named, AND the reference must state the
# guard that keeps "Showcase" from becoming a licence for marketing fluff. Without
# that boundary the register choice silently reopens readme-description.md's
# anti-patterns, which is the whole risk of offering the choice at all.
for r in "Showcase" "Reference"; do
  if grep -qF "$r" <<<"$lp_body"; then ok "reference names the $r register"
  else no "reference does not name the $r register"; fi
done
if grep -qF "What does NOT vary" <<<"$lp_body"; then ok "reference fences what register does NOT change"
else no "reference missing the register invariants section (fluff guard)"; fi

# Public-repo hygiene (hard rule 7 + tests/agnostic.sh): no local machine paths.
if grep -Eq '[A-Za-z]:[\\/]Users[\\/]|/home/[a-z]|/Users/[A-Za-z]' <<<"$lp_body"; then
  no "reference contains a machine-specific local path"
else ok "reference has no machine-specific local paths"; fi

# Citation reachability: SKILL.md must point at it from the conventions table AND
# from each mode that acts on it, or the router never loads it.
sk_body="$(cat "$SK" 2>/dev/null)"
cites="$(grep -c "references/readme-landing-page.md" <<<"$sk_body")"
if [ "${cites:-0}" -ge 4 ]; then ok "SKILL.md cites the reference $cites times (>=4: table + new + update + audit)"
else no "SKILL.md cites the reference only ${cites:-0} times (want >=4)"; fi

# It must be listed in the Files table, like every other reference.
if grep -qE '^\| `references/readme-landing-page\.md` \|' <<<"$sk_body"; then
  ok "SKILL.md Files table lists the reference"
else no "SKILL.md Files table missing the reference row"; fi

# Audit-mode behaviour: the new rows are WARN-level and the screenshot row is
# CONDITIONAL on the project having something to show. Both are the whole point —
# a hard fail or an unconditional nag would make the audit noise.
if grep -qF "LANDING-PAGE CHECKS" <<<"$sk_body"; then ok "audit mode has a landing-page check block"
else no "audit mode missing the landing-page check block"; fi
lp_block="$(awk '/LANDING-PAGE CHECKS/,/^$/' "$SK")"
if grep -qE 'WARN-level, never a hard fail' <<<"$lp_block"; then ok "audit rows declared WARN-level, not hard fails"
else no "audit landing-page rows not declared WARN-level"; fi
if grep -qF "CONDITIONAL" <<<"$lp_block"; then ok "screenshot row is conditional on a visual surface"
else no "screenshot audit row is not conditional (would nag CLI libraries)"; fi
# Audit must judge against the README's OWN register, or it flags a Reference
# README for declining a hero — the exact false positive the axis exists to avoid.
if grep -qF "REGISTER" <<<"$lp_block"; then ok "audit infers the register before judging rows"
else no "audit rows are register-blind (would flag Reference READMEs for missing a hero)"; fi

# FRONTMATTER CONTRACT — this suite requires README trigger phrases in the skill's
# `description:` field. The description IS the router's trigger: github-ops owns the
# README intro, the landing page and Recent Updates, but a request like "write me a
# README" reaches none of it unless the description says so. A description-trim lane
# that strips these phrases silently un-routes three references, so the assertion
# lives here and this comment says why. Keep the phrases; trim elsewhere if needed.
sk_desc="$(grep -m1 '^description:' "$SK")"
for cue in "write a README" "README badges"; do
  if grep -qF "$cue" <<<"$sk_desc"; then ok "description carries the '$cue' trigger"
  else no "description missing README trigger: '$cue' (skill unreachable for README work)"; fi
done
# Per-skill description cap is 1000 chars (tests/validate.sh) and the catalog-wide
# budget is already tight — assert we stayed well inside it.
desc_len=${#sk_desc}
if [ "$desc_len" -le 1000 ]; then ok "description within the 1000-char cap ($desc_len)"
else no "description is $desc_len chars (cap 1000)"; fi

# Mode new must offer the register as a user-flippable choice, not decide silently.
if grep -qE "say 'showcase' to flip" <<<"$sk_body"; then ok "mode new surfaces register as a flippable line"
else no "mode new does not surface the register choice to the user"; fi

# The scorecard is deliberately NOT extended — assert the decision stayed put, so a
# later lane that adds scoring has to update the rubric in --help at the same time.
if grep -qF "readme-landing-page" "$RS"; then
  no "rs: scorecard now references the landing page — its --help SCORING MODEL must be updated in the same commit"
else ok "rs: scorecard left unscored for landing-page signals (documented decision)"; fi

echo
echo "-- terminal design system (term.sh adoption + ASCII fallback) --"

# All three auditors must source the shared toolkit, not hand-roll ANSI.
for s in "$CI" "$SP" "$RS"; do
  b="$(basename "$s")"
  if grep -q '_lib/term.sh' "$s"; then ok "$b sources _lib/term.sh"
  else no "$b does not source _lib/term.sh"; fi
done

LIBTERM="$ROOT/../_lib/term.sh"
if [ -f "$LIBTERM" ]; then
  ok "term.sh present"
  # Under TERM_ASCII=1 every framing primitive must fall back to pure ASCII
  # (design principle #3: every glyph has a registered ASCII proxy).
  marks="$(TERM_ASCII=1 LT="$LIBTERM" bash -c '. "$LT"; term_init; printf "%s%s%s%s%s%s%s%s%s%s%s" \
    "$(term_mark ok)" "$(term_mark bad)" "$(term_mark warn)" "$(term_mark na)" \
    "$(term_mark unknown)" "$(term_header hdr)" "$TERM_ARROW" \
    "$(term_panel_open github-ops PANEL meta)" "$(term_panel_line body)" \
    "$(term_section "" sect 3)" "$(term_panel_close hk "$(term_health warning x)")"')"
  if LC_ALL=C grep -q '[^[:print:][:cntrl:]]' <<<"$marks"; then
    no "term.sh TERM_ASCII=1 still emits non-ASCII bytes"
  else ok "term.sh TERM_ASCII=1 primitives are pure ASCII"; fi
  # A fallback that silently drops the glyph (empty) is a bug, not a fallback.
  m="$(TERM_ASCII=1 LT="$LIBTERM" bash -c '. "$LT"; term_init; term_mark ok')"
  [ -n "$m" ] && ok "term_mark renders non-empty in ASCII mode" || no "term_mark ok is empty"
else
  no "term.sh missing at $LIBTERM"
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
