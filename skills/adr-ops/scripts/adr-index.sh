#!/usr/bin/env bash
# Emit the ADR index — one row per record, in number order. Read-only.
#
# Usage:   adr-index.sh [--dir DIR] [--json] [--output FILE]
# Input:   argv flags only (no stdin).
# Output:  stdout = the index. Plain: "number | status | date | title" rows.
#          --json: {"data":[...],"meta":{...,"schema":"claude-mods.adr-ops.index/v1"}}
#          --output FILE: write a generated Markdown index (heading + marker +
#          table) to FILE atomically instead of stdout. Data only — the directory
#          IS the index; this is just a parse of it.
# Stderr:  headers, warnings (e.g. yq absent -> fallback parser), errors.
# Exit:    0 ok, 2 usage, 3 dir not found
#
# Prefers `yq --front-matter=extract` for frontmatter parsing; degrades to a
# sed/grep parser when yq is absent (announced on stderr).
#
# Examples:
#   adr-index.sh
#   adr-index.sh --dir docs/decisions
#   adr-index.sh --json | jq '.data[] | select(.status=="accepted")'
#   adr-index.sh --output docs/adr/INDEX.md
set -uo pipefail

readonly EX_OK=0 EX_USAGE=2 EX_NOTFOUND=3

# Terminal design system (skills/_lib/term.sh). The index IS this tool's stdout
# data product (pipeable rows / --json / --output), so framing rides fd 1 and is
# only rendered as a full panel when stdout is a TTY (or FORCE_COLOR is set for a
# render check). Piped or --json/--output stays plain. Degrade if the lib is gone.
__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd || true)"
if [ -n "${__lib:-}" ] && [ -f "$__lib/term.sh" ]; then . "$__lib/term.sh"; term_init
else
  term_init() { :; }; term_color() { shift; printf '%s' "$*"; }
  term_panel_open() { :; }; term_panel_close() { :; }; term_panel_vert() { :; }
  term_section() { :; }; term_summary_line() { :; }; term_leaf_line() { :; }
  term_health() { shift; printf '%s' "$*"; }; TERM_DOT="|"
  TERM_TREE_BRANCH="+-"; TERM_TREE_LAST="\`-"
fi

DIR="docs/adr"
JSON=0
OUTPUT=""

usage() {
  cat <<'EOF'
adr-index.sh — emit the ADR index (number | status | date | title), in order.

Usage:
  adr-index.sh [--dir DIR] [--json]

Options:
  --dir DIR      ADR directory (default: docs/adr)
  --json         Emit a JSON envelope (schema claude-mods.adr-ops.index/v1)
  --output FILE  Write a generated Markdown index to FILE (atomic) instead of stdout
  -h, --help     Show this help and exit 0.

Exit codes:
  0 ok   2 usage   3 dir not found

Examples:
  adr-index.sh
  adr-index.sh --dir docs/decisions
  adr-index.sh --json | jq '.data[] | select(.status=="accepted")'
  adr-index.sh --output docs/adr/INDEX.md
EOF
}

die_usage() { printf 'error: %s\n' "$1" >&2; echo >&2; usage >&2; exit "$EX_USAGE"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     [[ $# -ge 2 ]] || die_usage "--dir needs a value"; DIR="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    --output)  [[ $# -ge 2 ]] || die_usage "--output needs a value"; OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit "$EX_OK" ;;
    -*)        die_usage "unknown flag: $1" ;;
    *)         die_usage "unexpected positional argument: $1" ;;
  esac
done

[[ "$JSON" -eq 1 && -n "$OUTPUT" ]] && die_usage "--json and --output are mutually exclusive"

[[ -d "$DIR" ]] || { printf 'error: ADR directory not found: %s\n' "$DIR" >&2; exit "$EX_NOTFOUND"; }

HAVE_YQ=0
if command -v yq >/dev/null 2>&1; then HAVE_YQ=1; else
  printf 'note: yq not found — using built-in frontmatter parser.\n' >&2
fi

# Extract a scalar frontmatter field from a file.
#   field_of <file> <field>
field_of() {
  local file="$1" field="$2"
  if [[ "$HAVE_YQ" -eq 1 ]]; then
    local v
    v="$(yq --front-matter=extract ".$field" "$file" 2>/dev/null)"
    [[ "$v" == "null" ]] && v=""
    printf '%s' "$v"
  else
    # Read only the first frontmatter block (between the first two --- lines).
    awk -v f="$field" '
      NR==1 && $0=="---" { infm=1; next }
      infm && $0=="---" { exit }
      infm {
        if ($0 ~ "^" f ":[[:space:]]*") {
          sub("^" f ":[[:space:]]*", "")
          gsub(/^["'"'"']|["'"'"']$/, "")
          print
          exit
        }
      }
    ' "$file"
  fi
}

title_of() {
  # First "# ADR-NNN: Title" line, with the prefix stripped.
  sed -n 's/^# ADR-[0-9]*:[[:space:]]*//p' "$1" | head -1
}

# Collect ADR files in number order.
rows_num=(); rows_status=(); rows_date=(); rows_title=()
shopt -s nullglob
mapfile -t files < <(
  for f in "$DIR"/ADR-*.md; do
    base="$(basename "$f")"
    [[ "$base" =~ ^ADR-([0-9]+) ]] || continue
    printf '%010d\t%s\n' "$((10#${BASH_REMATCH[1]}))" "$f"
  done | sort | cut -f2-
)
shopt -u nullglob

for f in "${files[@]}"; do
  base="$(basename "$f")"
  [[ "$base" =~ ^(ADR-[0-9]+) ]] || continue
  num="${BASH_REMATCH[1]}"
  rows_num+=("$num")
  rows_status+=("$(field_of "$f" status)")
  rows_date+=("$(field_of "$f" date)")
  rows_title+=("$(title_of "$f")")
done

count="${#rows_num[@]}"

# Render the index as a full panel (grouped by lifecycle status) for a human at a
# TTY. Strictly a display layer over the same rows — never the data product.
render_panel() {
  local indicator
  indicator="$count $([ "$count" -eq 1 ] && echo record || echo records)"
  term_panel_open adr "adr" "$indicator"
  term_panel_vert
  term_summary_line "$DIR"
  term_panel_vert

  local st state i j idxs last conn nm
  # Canonical lifecycle order; a trailing pass catches any off-spec status so no
  # row is ever silently dropped from the view.
  for st in proposed accepted superseded deprecated __other__; do
    idxs=()
    for ((i=0; i<count; i++)); do
      case "$st" in
        __other__) case "${rows_status[$i]}" in proposed|accepted|superseded|deprecated) ;; *) idxs+=("$i") ;; esac ;;
        *)         [[ "${rows_status[$i]}" == "$st" ]] && idxs+=("$i") ;;
      esac
    done
    [[ ${#idxs[@]} -eq 0 ]] && continue
    case "$st" in
      accepted)   state=OK ;;       # green — in force
      proposed)   state=PENDING ;;  # yellow — under consideration
      *)          state=RETIRED ;;  # default fg — superseded / deprecated / off-spec
    esac
    local label="$st"; [[ "$st" == "__other__" ]] && label="other"
    term_section "$state" "$label" "${#idxs[@]}"
    last=$(( ${#idxs[@]} - 1 ))
    for j in "${!idxs[@]}"; do
      i="${idxs[$j]}"
      conn="$TERM_TREE_BRANCH"; [[ "$j" -eq "$last" ]] && conn="$TERM_TREE_LAST"
      nm="${rows_num[$i]}  ${rows_title[$i]}"
      term_leaf_line "$conn" "$nm" "" "" "${rows_date[$i]}"
    done
    term_panel_vert
  done

  term_panel_close "lint ${TERM_DOT} touching ${TERM_DOT} new" "$(term_health healthy "$indicator")"
}

# Decide whether the human panel applies: never for --json/--output; only when
# stdout is a terminal (or FORCE_COLOR forces a render for verification).
PANEL=0
if [[ "$JSON" -eq 0 && -z "$OUTPUT" ]] && { [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; }; then PANEL=1; fi

if [[ "$JSON" -eq 1 ]]; then
  # Build JSON without external deps (escape backslash + double-quote).
  esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
  printf '{"data":['
  for ((i=0; i<count; i++)); do
    [[ $i -gt 0 ]] && printf ','
    printf '{"number":"%s","status":"%s","date":"%s","title":"%s"}' \
      "$(esc "${rows_num[$i]}")" "$(esc "${rows_status[$i]}")" \
      "$(esc "${rows_date[$i]}")" "$(esc "${rows_title[$i]}")"
  done
  printf '],"meta":{"count":%d,"dir":"%s","schema":"claude-mods.adr-ops.index/v1"}}\n' \
    "$count" "$(esc "$DIR")"
elif [[ -n "$OUTPUT" ]]; then
  # Generated Markdown index, written atomically to $OUTPUT.
  tmp="$OUTPUT.tmp.$$"
  {
    printf '# ADR Index\n\n'
    printf '<!-- generated by adr-index.sh — do not hand-edit; the directory is the index -->\n\n'
    printf '| # | Status | Date | Title |\n'
    printf '|---|---|---|---|\n'
    for ((i=0; i<count; i++)); do
      printf '| %s | %s | %s | %s |\n' \
        "${rows_num[$i]}" "${rows_status[$i]}" "${rows_date[$i]}" "${rows_title[$i]}"
    done
  } > "$tmp" || { rm -f "$tmp"; printf 'error: failed to write %s\n' "$tmp" >&2; exit 1; }
  mv -f "$tmp" "$OUTPUT" || { rm -f "$tmp"; printf 'error: failed to move into place: %s\n' "$OUTPUT" >&2; exit 1; }
  printf 'wrote %d-row index to %s\n' "$count" "$OUTPUT" >&2
elif [[ "$PANEL" -eq 1 ]]; then
  render_panel
else
  for ((i=0; i<count; i++)); do
    printf '%s | %s | %s | %s\n' \
      "${rows_num[$i]}" "${rows_status[$i]}" "${rows_date[$i]}" "${rows_title[$i]}"
  done
fi

exit "$EX_OK"
