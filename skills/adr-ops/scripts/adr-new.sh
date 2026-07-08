#!/usr/bin/env bash
# Scaffold the next Architecture Decision Record from the canonical template.
#
# Usage:   adr-new.sh --title "Title Text" [OPTIONS]
# Input:   argv flags only (no stdin).
# Output:  stdout = the created file path (or, under --dry-run, the path then the
#          full rendered content). Data only.
# Stderr:  headers, reminders (e.g. supersession flip), warnings, errors.
# Exit:    0 created (or dry-run rendered), 2 usage, 3 dir not found,
#          5 precondition (target already exists)
#
# Computes the next number as (highest existing ADR-NNN in --dir) + 1, zero-padded
# to three digits, and writes ADR-NNN-slug.md with frontmatter filled in. Never
# overwrites an existing file. Atomic write (tmp + mv).
#
# Examples:
#   adr-new.sh --title "OAuth-only auth"
#   adr-new.sh --dir docs/decisions --title "Per-trial container" --slug per-trial-container
#   adr-new.sh --title "Replace router" --supersedes ADR-002 --apply-supersede
#   adr-new.sh --title "Draft idea" --status proposed --dry-run
set -uo pipefail

# ── exit-code constants ────────────────────────────────────────────────────
readonly EX_OK=0 EX_USAGE=2 EX_NOTFOUND=3 EX_PRECOND=5

# Terminal design system (skills/_lib/term.sh). stdout = the created file path
# (data); the creation summary + supersession reminders frame on stderr, so detect
# color on fd 2. Degrade to plain stderr lines if the shared lib is unreachable.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init 2
else
  term_panel_open() { :; }; term_panel_close() { :; }; term_panel_vert() { :; }
  term_status_row() { shift; printf '  - %s %s\n' "$1" "${2:-}"; }
  term_alert() { shift; printf '  ! %s\n' "$*"; }
  term_color() { shift; printf '%s' "$*"; }; TERM_DOT="|"
fi

# ── defaults ───────────────────────────────────────────────────────────────
DIR="docs/adr"
TITLE=""
SLUG=""
STATUS="accepted"
SUPERSEDES=""
APPLY_SUPERSEDE=0
DATE=""
NUMBER=""        # explicit override; default is highest+1
DRY_RUN=0

# Resolve the bundled template relative to this script (works in repo + installed).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/../assets/ADR-template.md"

usage() {
  cat <<'EOF'
adr-new.sh — scaffold the next ADR from the canonical template.

Usage:
  adr-new.sh --title "Title Text" [OPTIONS]

Options:
  --dir DIR              ADR directory (default: docs/adr)
  --title TEXT           ADR title (required). Used in the `# ADR-NNN: Title` line.
  --slug SLUG            kebab-case slug for the filename. Derived from --title if omitted.
  --status STATUS        proposed|accepted|superseded|deprecated (default: accepted)
  --number N             Force the ADR number instead of computing highest+1
                         (for backfilling or coordination). Sequential discipline
                         is the default; use sparingly. The overwrite guard still
                         applies.
  --supersedes ADR-NNN   Mark this ADR as superseding ADR-NNN. Prints a reminder to
                         flip the old record. Repeatable.
  --apply-supersede      With --supersedes: also flip the OLD file's frontmatter
                         (status: superseded, superseded-by: [this ADR]) in place.
  --date YYYY-MM-DD      Decision date (default: today via `date +%F`).
  --dry-run              Print the target path and full content; write nothing.
  -h, --help             Show this help and exit 0.

Exit codes:
  0 created (or dry-run rendered)   2 usage   3 dir not found   5 target exists

Examples:
  adr-new.sh --title "OAuth-only auth"
  adr-new.sh --dir docs/decisions --title "Per-trial container" --slug per-trial-container
  adr-new.sh --title "Replace router" --supersedes ADR-002 --apply-supersede
  adr-new.sh --title "Draft idea" --status proposed --dry-run
EOF
}

die_usage() { printf 'error: %s\n' "$1" >&2; echo >&2; usage >&2; exit "$EX_USAGE"; }

# ── parse args ─────────────────────────────────────────────────────────────
SUPERSEDES_LIST=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)           [[ $# -ge 2 ]] || die_usage "--dir needs a value"; DIR="$2"; shift 2 ;;
    --title)         [[ $# -ge 2 ]] || die_usage "--title needs a value"; TITLE="$2"; shift 2 ;;
    --slug)          [[ $# -ge 2 ]] || die_usage "--slug needs a value"; SLUG="$2"; shift 2 ;;
    --status)        [[ $# -ge 2 ]] || die_usage "--status needs a value"; STATUS="$2"; shift 2 ;;
    --number)        [[ $# -ge 2 ]] || die_usage "--number needs a value"; NUMBER="$2"; shift 2 ;;
    --supersedes)    [[ $# -ge 2 ]] || die_usage "--supersedes needs a value"; SUPERSEDES_LIST+=("$2"); shift 2 ;;
    --apply-supersede) APPLY_SUPERSEDE=1; shift ;;
    --date)          [[ $# -ge 2 ]] || die_usage "--date needs a value"; DATE="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit "$EX_OK" ;;
    -*)              die_usage "unknown flag: $1" ;;
    *)               die_usage "unexpected positional argument: $1" ;;
  esac
done

# ── validate ───────────────────────────────────────────────────────────────
[[ -n "$TITLE" ]] || die_usage "--title is required"

case "$STATUS" in
  proposed|accepted|superseded|deprecated) ;;
  *) die_usage "--status must be one of proposed|accepted|superseded|deprecated (got '$STATUS')" ;;
esac

if [[ -n "$DATE" ]]; then
  [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die_usage "--date must be YYYY-MM-DD (got '$DATE')"
else
  DATE="$(date +%F)"
fi

[[ -f "$TEMPLATE" ]] || { printf 'error: template not found at %s\n' "$TEMPLATE" >&2; exit "$EX_NOTFOUND"; }
[[ -d "$DIR" ]] || { printf 'error: ADR directory not found: %s\n' "$DIR" >&2; exit "$EX_NOTFOUND"; }

# Derive slug from title if not supplied: lowercase, non-alnum -> '-', squeeze, trim.
if [[ -z "$SLUG" ]]; then
  SLUG="$(printf '%s' "$TITLE" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
fi
[[ -n "$SLUG" ]] || die_usage "could not derive a slug from --title; pass --slug explicitly"
[[ "$SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die_usage "--slug must be kebab-case (got '$SLUG')"

# ── compute next number ────────────────────────────────────────────────────
# Default: highest existing ADR-NNN in --dir, +1. Sequential, never reused/reordered.
# --number N overrides this (for backfilling or cross-session coordination); the
# overwrite guard below still protects against clobbering an existing record.
if [[ -n "$NUMBER" ]]; then
  [[ "$NUMBER" =~ ^[0-9]+$ ]] || die_usage "--number must be a non-negative integer (got '$NUMBER')"
  next=$((10#$NUMBER))
else
  highest=0
  shopt -s nullglob
  for f in "$DIR"/ADR-*.md; do
    base="$(basename "$f")"
    if [[ "$base" =~ ^ADR-([0-9]+) ]]; then
      n=$((10#${BASH_REMATCH[1]}))
      (( n > highest )) && highest=$n
    fi
  done
  shopt -u nullglob
  next=$((highest + 1))
fi
NNN="$(printf '%03d' "$next")"

TARGET="$DIR/ADR-$NNN-$SLUG.md"

# Never overwrite (precondition).
if [[ -e "$TARGET" ]]; then
  printf 'error: target already exists: %s (refusing to overwrite)\n' "$TARGET" >&2
  exit "$EX_PRECOND"
fi

# ── render content from template ───────────────────────────────────────────
# Build the supersedes YAML list value.
supersedes_yaml="[]"
if [[ ${#SUPERSEDES_LIST[@]} -gt 0 ]]; then
  joined=""
  for s in "${SUPERSEDES_LIST[@]}"; do
    [[ "$s" =~ ^ADR-[0-9]+$ ]] || die_usage "--supersedes value must look like ADR-NNN (got '$s')"
    joined+="${joined:+, }$s"
  done
  supersedes_yaml="[$joined]"
fi

# Render from template via line-exact awk substitution (avoids bash ${//}
# footguns: a leading '#' anchors the match, and a title with regex metachars
# would otherwise need escaping). Each placeholder line is matched whole.
content="$(awk \
  -v status="status: $STATUS" \
  -v date="date: $DATE" \
  -v supersedes="supersedes: $supersedes_yaml" \
  -v title="# ADR-$NNN: $TITLE" '
  $0 == "status: accepted"             { print status;     next }
  $0 == "date: YYYY-MM-DD"             { print date;       next }
  $0 == "supersedes: []"               { print supersedes; next }
  $0 == "# ADR-NNN: Title in Title Case" { print title;    next }
  { print }
' "$TEMPLATE")"

# ── dry-run: print and stop ────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$TARGET"
  {
    term_panel_open adr "adr ${TERM_DOT} new (dry-run)" "ADR-$NNN"
    term_panel_vert
    term_status_row skip "would write  $(basename "$TARGET")" "status: $STATUS ${TERM_DOT} $DATE"
    if [[ ${#SUPERSEDES_LIST[@]} -gt 0 ]]; then
      term_alert warning "supersedes ${SUPERSEDES_LIST[*]} — flip status: superseded + superseded-by: [ADR-$NNN] in the same commit"
    fi
    term_panel_vert
    term_panel_close "nothing written" ""
  } >&2
  printf '%s\n' "$content"
  exit "$EX_OK"
fi

# ── atomic write ───────────────────────────────────────────────────────────
tmp="$TARGET.tmp.$$"
printf '%s\n' "$content" > "$tmp" || { printf 'error: failed to write %s\n' "$tmp" >&2; exit 1; }
mv -f "$tmp" "$TARGET" || { rm -f "$tmp"; printf 'error: failed to move into place: %s\n' "$TARGET" >&2; exit 1; }

printf '%s\n' "$TARGET"

# ── supersession handling ──────────────────────────────────────────────────
# Apply the flips first (collecting outcome rows), then frame the whole event as a
# single status panel on stderr. stdout already carries the created path (data).
sup_rows=()    # "state\tlabel\tvalue" — rendered as term_status_row
sup_alerts=()  # plain text — rendered as term_alert warning
if [[ ${#SUPERSEDES_LIST[@]} -gt 0 ]]; then
  for old in "${SUPERSEDES_LIST[@]}"; do
    oldfile=""
    shopt -s nullglob
    for f in "$DIR/$old"-*.md; do oldfile="$f"; break; done
    shopt -u nullglob

    if [[ "$APPLY_SUPERSEDE" -eq 1 ]]; then
      if [[ -z "$oldfile" || ! -f "$oldfile" ]]; then
        sup_alerts+=("--apply-supersede: could not find $old in $DIR — flip it by hand")
        continue
      fi
      # Flip frontmatter ONLY: status -> superseded, superseded-by -> [ADR-NNN].
      otmp="$oldfile.tmp.$$"
      if sed -E \
        -e "0,/^status: .*/s//status: superseded/" \
        -e "0,/^superseded-by: .*/s//superseded-by: [ADR-$NNN]/" \
        "$oldfile" > "$otmp" && mv -f "$otmp" "$oldfile"; then
        sup_rows+=("ok"$'\t'"flipped $(basename "$oldfile")"$'\t'"-> superseded, superseded-by: [ADR-$NNN]")
      else
        rm -f "$otmp"
        sup_alerts+=("failed to flip $oldfile — do it by hand")
      fi
    else
      sup_alerts+=("supersedes $old — in the SAME commit flip ${oldfile:-$old} to status: superseded + superseded-by: [ADR-$NNN] (or re-run with --apply-supersede)")
    fi
  done
fi

{
  term_panel_open adr "adr ${TERM_DOT} new" "ADR-$NNN"
  term_panel_vert
  term_status_row ok "created  $(basename "$TARGET")" "status: $STATUS ${TERM_DOT} $DATE"
  for row in "${sup_rows[@]:-}"; do
    [[ -z "$row" ]] && continue
    IFS=$'\t' read -r st lbl val <<<"$row"
    term_status_row "$st" "$lbl" "$val"
  done
  for a in "${sup_alerts[@]:-}"; do
    [[ -z "$a" ]] && continue
    term_alert warning "$a"
  done
  term_panel_vert
  term_panel_close "then: adr-lint before committing" ""
} >&2

exit "$EX_OK"
