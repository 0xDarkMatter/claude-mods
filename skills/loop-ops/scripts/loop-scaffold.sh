#!/usr/bin/env bash
# Scaffold an outer-loop state spine (loop.config.yaml + STATE.md + run-log.md).
#
# Usage:   loop-scaffold.sh --name NAME [OPTIONS]
# Input:   argv flags only (no stdin).
# Output:  stdout = the created loop.config.yaml path (data). Under --dry-run, the
#          path then the rendered config. Data only.
# Stderr:  the creation panel, reminders, warnings, errors.
# Exit:    0 created (or dry-run rendered), 2 usage, 3 template/dir not found,
#          5 precondition (target dir already populated, no --force)
#
# Creates <dir>/<name>/ from the bundled templates, substituting name/pattern/tier/
# cadence/permission_mode. Never clobbers a populated loop dir. Atomic writes.
# Next step: fill the config, then `loop-check.sh <dir>/<name>/loop.config.yaml`.
#
# Examples:
#   loop-scaffold.sh --name pr-watch --pattern pr-watch --tier L1
#   loop-scaffold.sh --name dep-bump --pattern dep-bump --tier L2 --cadence 1d
#   loop-scaffold.sh --name nightly --cadence "0 3 * * *" --dry-run
set -uo pipefail

readonly EX_OK=0 EX_USAGE=2 EX_NOTFOUND=3 EX_PRECOND=5

# Terminal design system (skills/_lib/term.sh). stdout = the created path (data);
# the creation panel frames on stderr, so detect color on fd 2. Degrade to plain
# stderr lines if the shared lib is unreachable.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2
else
  term_panel_open() { :; }; term_panel_close() { :; }; term_panel_vert() { :; }
  term_status_row() { shift; printf '  - %s %s\n' "$1" "${2:-}"; }
  term_alert() { shift; printf '  ! %s\n' "$*"; }
  term_color() { shift; printf '%s' "$*"; }; TERM_DOT="|"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
CFG_TPL="$ASSETS/loop.config.template.yaml"
STATE_TPL="$ASSETS/STATE.template.md"
RUN_TPL="$ASSETS/run.template.md"
RUN_SH_TPL="$ASSETS/run.sh.template"

# ── defaults ────────────────────────────────────────────────────────────────
NAME=""
PATTERN="custom"
TIER="L1"
CADENCE="1h"
DIR=".loops"
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
loop-scaffold.sh — scaffold an outer-loop state spine.

Usage:
  loop-scaffold.sh --name NAME [OPTIONS]

Options:
  --name NAME        loop identifier, kebab-case (required). Names the directory.
  --pattern KEY      catalog key (pr-watch, ci-watch, dep-bump,
                     changelog-gen, merge-hygiene, issue-sort,
                     daily-scan) or "custom" (default: custom).
  --tier L1|L2|L3    starting autonomy tier (default: L1).
  --cadence STR      10m | 1h | 6h | 1d, or a cron string (default: 1h).
  --dir DIR          parent directory for the loop (default: .loops).
  --dry-run          print the target path + rendered config; write nothing.
  --force            overwrite an already-populated <dir>/<name>/ directory.
  -h, --help         show this help and exit 0.

Exit codes:
  0 created (or dry-run)   2 usage   3 template/dir not found   5 dir populated

Examples:
  loop-scaffold.sh --name pr-watch --pattern pr-watch --tier L1
  loop-scaffold.sh --name dep-bump --pattern dep-bump --tier L2 --cadence 1d
  loop-scaffold.sh --name nightly --cadence "0 3 * * *" --dry-run
EOF
}

die_usage() { printf 'error: %s\n' "$1" >&2; echo >&2; usage >&2; exit "$EX_USAGE"; }

# ── parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    [[ $# -ge 2 ]] || die_usage "--name needs a value"; NAME="$2"; shift 2 ;;
    --pattern) [[ $# -ge 2 ]] || die_usage "--pattern needs a value"; PATTERN="$2"; shift 2 ;;
    --tier)    [[ $# -ge 2 ]] || die_usage "--tier needs a value"; TIER="$2"; shift 2 ;;
    --cadence) [[ $# -ge 2 ]] || die_usage "--cadence needs a value"; CADENCE="$2"; shift 2 ;;
    --dir)     [[ $# -ge 2 ]] || die_usage "--dir needs a value"; DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) usage; exit "$EX_OK" ;;
    -*)        die_usage "unknown flag: $1" ;;
    *)         die_usage "unexpected positional argument: $1" ;;
  esac
done

# ── validate ────────────────────────────────────────────────────────────────
[[ -n "$NAME" ]] || die_usage "--name is required"
[[ "$NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die_usage "--name must be kebab-case (got '$NAME')"
[[ "$PATTERN" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die_usage "--pattern must be kebab-case (got '$PATTERN')"
case "$TIER" in L1|L2|L3) ;; *) die_usage "--tier must be L1|L2|L3 (got '$TIER')" ;; esac
# cadence: Nm/Nh/Nd OR a cron-ish string (digits, spaces, * / , -)
[[ "$CADENCE" =~ ^[0-9]+[mhd]$ || "$CADENCE" =~ ^[-0-9*/,\ ]+$ ]] \
  || die_usage "--cadence must be like 10m/1h/1d or a cron string (got '$CADENCE')"

[[ -f "$CFG_TPL" ]]   || { printf 'error: config template not found at %s\n' "$CFG_TPL" >&2; exit "$EX_NOTFOUND"; }
[[ -f "$STATE_TPL" ]] || { printf 'error: STATE template not found at %s\n' "$STATE_TPL" >&2; exit "$EX_NOTFOUND"; }
[[ -f "$RUN_TPL" ]]   || { printf 'error: run template not found at %s\n' "$RUN_TPL" >&2; exit "$EX_NOTFOUND"; }
[[ -f "$RUN_SH_TPL" ]] || { printf 'error: run.sh template not found at %s\n' "$RUN_SH_TPL" >&2; exit "$EX_NOTFOUND"; }

# Default permission_mode from tier (the workhorse mapping; see references/risk-tiers.md).
case "$TIER" in
  L1|L2) PMODE="dontAsk" ;;
  L3)    PMODE="bypassPermissions" ;;
esac

# ── pattern presets ─────────────────────────────────────────────────────────
# Seed a near-ready config for a known --pattern (the user reviews, doesn't start
# from blank placeholders). Doctrine: always scaffold at the chosen tier; report/
# propose/draft patterns carry no gate (VERIFY_SEED empty), code-changing ones do.
SEEDED=0; SCOPE_SEED=""; GOAL_SEED=""; ESCAL_SEED=""; VERIFY_SEED=""; GUARD_SEED=""
case "$PATTERN" in
  daily-scan) SEEDED=1
    SCOPE_SEED="src/**"
    GOAL_SEED="Sweep the backlog/issues/alerts and write the day's STATE.md priority list; report only."
    ESCAL_SEED="everything - a human decides what to action; this loop never changes code" ;;
  pr-watch) SEEDED=1
    SCOPE_SEED="src/**"
    GOAL_SEED="Watch open PRs; flag stuck/failing/conflicted; post a summary comment at most; never merge."
    ESCAL_SEED="a human reviews and merges; never merge to main" ;;
  ci-watch) SEEDED=1
    SCOPE_SEED="src/**"
    GOAL_SEED="Detect red CI; classify the failure; at L2 propose a fix in a worktree; never auto-merge to main."
    ESCAL_SEED="flaky/infra failures, anything touching deploy/secrets, ambiguous root cause"
    VERIFY_SEED="npm test"; GUARD_SEED="npm run typecheck" ;;
  dep-bump) SEEDED=1
    SCOPE_SEED="package.json"
    GOAL_SEED="Patch-only dependency bumps behind the release cooldown + guard; open a PR; never minor/major."
    ESCAL_SEED="minor/major bumps, guard failures, any flagged advisory"
    VERIFY_SEED="npm test"; GUARD_SEED="npm run build && npm test" ;;
  changelog-gen) SEEDED=1
    SCOPE_SEED="CHANGELOG.md"
    GOAL_SEED="Summarize merged PRs since the last tag into RELEASE_NOTES_DRAFT.md; never publish a release."
    ESCAL_SEED="the human edits and publishes; never run gh release create" ;;
  merge-hygiene) SEEDED=1
    SCOPE_SEED="src/**"
    GOAL_SEED="Find merged-deletable branches / stale flags / orphaned artifacts; report; never delete unmerged work."
    ESCAL_SEED="anything ambiguous; never delete a branch with unmerged commits" ;;
  issue-sort) SEEDED=1
    SCOPE_SEED="src/**"
    GOAL_SEED="Classify new issues and suggest labels + priority; propose only; never close or set priority unattended."
    ESCAL_SEED="priority calls, dupe-closing, anything needing product judgment" ;;
esac

TARGET_DIR="$DIR/$NAME"
CFG_OUT="$TARGET_DIR/loop.config.yaml"
STATE_OUT="$TARGET_DIR/STATE.md"
LOG_OUT="$TARGET_DIR/run-log.md"
RUN_OUT="$TARGET_DIR/run.md"
RUN_SH_OUT="$TARGET_DIR/loop-run.sh"

# Refuse a populated target unless --force.
if [[ -d "$TARGET_DIR" ]] && [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]] && [[ "$FORCE" -ne 1 ]]; then
  printf 'error: loop directory already populated: %s (use --force to overwrite)\n' "$TARGET_DIR" >&2
  exit "$EX_PRECOND"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── render config from template ─────────────────────────────────────────────
# Line-anchored sed substitutions: identity placeholders globally, the three
# tunable scalar lines by their default value. Kill-switch path carries <loop-name>.
render_config() {
  sed -E \
    -e "s|<loop-name>|$NAME|g" \
    -e "s|<pattern-key>|$PATTERN|" \
    -e "s|^tier: L1|tier: $TIER|" \
    -e "s|^cadence: 1h|cadence: $CADENCE|" \
    -e "s|^permission_mode: dontAsk|permission_mode: $PMODE|" \
    "$CFG_TPL"
}

render_state() {
  sed -E \
    -e "s|<loop-name>|$NAME|g" \
    -e "s|<ISO-8601 Z>|$NOW|" \
    "$STATE_TPL"
}

render_log() {
  cat <<EOF
# $NAME — run log (append-only; one line per run)
# format: <ISO-Z>  run#N  action=<reported|proposed|none>  <key=val…>  outcome=<…>  tokens=<N>
EOF
}

render_run() {
  sed -E \
    -e "s|<loop-name>|$NAME|g" \
    -e "s|tier <L1\\|L2\\|L3>|tier $TIER|g" \
    "$RUN_TPL"
}

# The runner-agnostic tick wrapper any scheduler invokes (cron / Task Scheduler /
# systemd / process-compose / by hand) — no GitHub Actions required.
render_run_sh() {
  sed -E \
    -e "s|<loop-name>|$NAME|g" \
    -e "s|<permission-mode>|$PMODE|g" \
    "$RUN_SH_TPL"
}

# Seeded config for a known pattern. L1 stays report-only (gate fields are a
# commented graduation block); L2/L3 emit verify/guard/worktree/land_via — using
# the pattern's gate if it has one, else a <fill:…> placeholder the audit will flag.
render_seeded_config() {
  cat <<EOF
# loop.config.yaml - $PATTERN (seeded by loop-scaffold at $TIER; REVIEW before scheduling)
# Full field semantics: skills/loop-ops/references/state-spine.md
name: $NAME
pattern: $PATTERN
tier: $TIER
permission_mode: $PMODE
cadence: $CADENCE
goal: "$GOAL_SEED"
scope:
  - "$SCOPE_SEED"
escalation: "$ESCAL_SEED"
budget_tokens: 200000
kill_switch: ".loops/$NAME/PAUSED exists, OR the loop-pause label is set"
EOF
  if [[ "$TIER" == "L1" ]]; then
    cat <<EOF

# ── graduate to L2 (assisted): set tier: L2, uncomment + fill, re-run loop-check + loop-doctor --live ──
# verify: "${VERIFY_SEED:-<fill: the gate command, e.g. npm test>}"
# guard: "${GUARD_SEED:-<fill: a must-always-pass command>}"
# worktree: true
# land_via: fleet-ops
EOF
  else
    cat <<EOF
verify: "${VERIFY_SEED:-<fill: the gate command for this loop>}"
guard: "${GUARD_SEED:-<fill: a must-always-pass command>}"
worktree: true
land_via: fleet-ops
EOF
  fi
}

# Pick the seeded renderer for a known pattern, else the generic template.
emit_config() { if [[ "$SEEDED" -eq 1 ]]; then render_seeded_config; else render_config; fi; }

# ── dry-run: print and stop ─────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$CFG_OUT"
  {
    term_panel_open loop "loop ${TERM_DOT} init (dry-run)" "$NAME"
    term_panel_vert
    term_status_row skip "would create  $TARGET_DIR/" "tier $TIER ${TERM_DOT} $PATTERN ${TERM_DOT} $CADENCE"
    term_status_row skip "  loop.config.yaml" "permission_mode: $PMODE"
    term_status_row skip "  STATE.md / run-log.md / run.md / loop-run.sh" ""
    term_panel_vert
    term_panel_close "nothing written" ""
  } >&2
  emit_config
  exit "$EX_OK"
fi

# ── atomic writes ───────────────────────────────────────────────────────────
mkdir -p "$TARGET_DIR" || { printf 'error: could not create %s\n' "$TARGET_DIR" >&2; exit 1; }

write_atomic() {  # write_atomic <dest> <content>
  local dest="$1" content="$2" tmp
  tmp="$dest.tmp.$$"
  printf '%s\n' "$content" > "$tmp" || { printf 'error: failed to write %s\n' "$tmp" >&2; exit 1; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; printf 'error: failed to move into place: %s\n' "$dest" >&2; exit 1; }
}

write_atomic "$CFG_OUT"   "$(emit_config)"
write_atomic "$STATE_OUT" "$(render_state)"
write_atomic "$LOG_OUT"   "$(render_log)"
write_atomic "$RUN_OUT"   "$(render_run)"
write_atomic "$RUN_SH_OUT" "$(render_run_sh)"
chmod +x "$RUN_SH_OUT" 2>/dev/null || true

printf '%s\n' "$CFG_OUT"

{
  term_panel_open loop "loop ${TERM_DOT} init" "$NAME"
  term_panel_vert
  term_status_row ok "created  $TARGET_DIR/" "tier $TIER ${TERM_DOT} $PATTERN ${TERM_DOT} $CADENCE"
  term_status_row ok "  loop.config.yaml" "permission_mode: $PMODE"
  term_status_row ok "  STATE.md / run-log.md / run.md / loop-run.sh" ""
  if [[ "$TIER" != "L1" ]]; then
    term_alert warning "tier $TIER needs a verify gate, guard, worktree, escalation + land_via — fill them before auditing"
  fi
  term_panel_vert
  term_panel_close "then: fill the config ${TERM_DOT} loop-check.sh $CFG_OUT" ""
} >&2

exit "$EX_OK"
