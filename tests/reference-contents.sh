#!/usr/bin/env bash
# Reference-contents gate: warn when a skill reference over 100 lines does not open
# with a current `## Contents` list.
#
# Why: the size rule (docs/SKILL-SUBAGENT-REFERENCE.md, "The size rule") says a
# reference over 100 lines opens with a `## Contents` list, so an agent that reads
# only the top of a long file still sees the whole map (Anthropic's skill authoring
# best practices: a table of contents once a reference passes 100 lines). "Current"
# means the list names every `## ` heading below it; a stale list hides a section.
#
# Parser: skills/security-ops/tests/reference-contents.awk, shared with that skill's
# own suite (which fails hard on it) so the two checks cannot drift apart. It lives
# inside security-ops because that skill is copied standalone into other plugins;
# if it moves, this gate exits 2 instead of passing blind.
#
# Warn-only by design: most long references predate the rule, and a hard gate would
# block every unrelated change until all of them are fixed. Add the list when you
# touch a skill. --strict is for the day the count reaches zero. For the same reason
# this gate stays out of the fail-fast landing chain.
#
# Modes:
#   bash tests/reference-contents.sh             one summary line, exit 0
#   bash tests/reference-contents.sh --report    also list each flagged file and why
#   bash tests/reference-contents.sh --strict    exit 1 if any reference is flagged
#   bash tests/reference-contents.sh DIR         scan DIR/*/references/*.md, not skills/
#   REFERENCE_CONTENTS_MIN_LINES=150 bash tests/reference-contents.sh   other threshold
#
# Every run first proves the gate can see: a self-test builds fixtures and must flag
# a long reference with no list and one with a stale list, and must pass a current
# list (bulleted or numbered), a short file, a CRLF file and a `## ` line in a fence.
#
# Exit 0 = clean or warnings only, 1 = --strict and something flagged, 2 = the gate
# itself is broken (self-test failed, parser missing, or no references to scan).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT/skills/security-ops/tests/reference-contents.awk"
MIN_LINES="${REFERENCE_CONTENTS_MIN_LINES:-100}"
STRICT=0
REPORT=0
SKILLS_DIR="$ROOT/skills"

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --report) REPORT=1 ;;
        -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "reference-contents: unknown option $arg" >&2; exit 2 ;;
        *) SKILLS_DIR="$arg" ;;
    esac
done

if [ ! -f "$PARSER" ]; then
    echo "reference-contents: parser not found at $PARSER - refusing to pass blind" >&2
    exit 2
fi

# One awk process for every reference: a spawn per file costs minutes on Windows.
# Output is the parser's TSV: `<file>\tchecked` per long file, then one line per problem.
scan() {
    local dir="$1"
    printf '%s\0' "$dir"/*/references/*.md \
        | xargs -0 awk -v min_lines="$MIN_LINES" -v emit_checked=1 -f "$PARSER"
}

# --- self-test: the gate must flag missing and stale lists, and nothing else -------
self_test() {
    local tmp out refs filler
    tmp=$(mktemp -d) || return 1
    refs="$tmp/fx/references"
    mkdir -p "$refs"
    filler=$(for i in $(seq 1 110); do echo "line $i"; done)
    printf '# No list\n\n## Alpha\n%s\n' "$filler" > "$refs/no-list.md"
    printf '# Stale\n\n## Contents\n\n- [Alpha](#alpha)\n\n## Alpha\n%s\n## Beta\nx\n' "$filler" > "$refs/stale.md"
    printf '# Current\n\n## Contents\n\n- [Alpha](#alpha)\n- [Beta](#beta)\n\n## Alpha\n```md\n## Fenced\n```\n%s\n## Beta\nx\n' "$filler" > "$refs/current.md"
    # Git Bash's gawk already drops CR in text mode, so this fixture only bites on
    # Linux/macOS awk (seen failing there under WSL with the parser's CR strip removed)
    sed 's/$/\r/' "$refs/current.md" > "$refs/crlf.md"
    # numbered list whose link text omits the heading's number: still current
    printf '# Numbered\n\n## Contents\n\n1. [Alpha](#1-alpha)\n\n## 1. Alpha\n%s\n' "$filler" > "$refs/numbered.md"
    printf '# Short\n\n## Alpha\nx\n' > "$refs/short.md"
    out=$(scan "$tmp")
    rm -rf "$tmp"
    local checked flagged
    checked=$(grep -c $'\tchecked$' <<<"$out")
    flagged=$(grep -v $'\tchecked$' <<<"$out" | sed 's#.*/##' | sort | tr '\n' '|')
    if [ "$checked" -ne 5 ]; then
        echo "reference-contents: SELF-TEST FAILED - expected 5 long fixtures checked, got $checked" >&2
        return 1
    fi
    if [ "$flagged" != $'no-list.md\tno ## Contents in first 15 lines|stale.md\tmissing: Beta|' ]; then
        echo "reference-contents: SELF-TEST FAILED - wrong verdicts: ${flagged:-nothing flagged}" >&2
        return 1
    fi
}

self_test || exit 2

set -- "$SKILLS_DIR"/*/references/*.md
if [ ! -f "$1" ]; then
    echo "reference-contents: no */references/*.md found under $SKILLS_DIR - refusing to pass blind" >&2
    exit 2
fi

out=$(scan "$SKILLS_DIR")
checked=$(grep -c $'\tchecked$' <<<"$out")
problems=$(grep -v $'\tchecked$' <<<"$out")
no_list=$(grep -c $'\tno ## Contents' <<<"$problems")
stale=$(grep $'\tmissing: ' <<<"$problems" | cut -f1 | sort -u | grep -c .)
flagged=$((no_list + stale))
skills=$(cut -f1 <<<"$problems" | grep . | sed 's#/references/.*##; s#.*/##' | sort -u | grep -c .)

if [ "$REPORT" -eq 1 ] && [ "$flagged" -gt 0 ]; then
    # one line per file: skill/references/name.md: why
    awk -F'\t' '
        { f = $1; if (match(f, /[^\/]+\/references\/[^\/]+$/)) f = substr(f, RSTART)
          if ($2 ~ /^no /) why[f] = "no Contents list"
          else why[f] = (f in why ? why[f] "; " : "stale Contents, ") $2 }
        END { for (f in why) print f ": " why[f] }' <<<"$problems" | sort
    echo
fi

if [ "$flagged" -eq 0 ]; then
    echo "reference-contents: clean ($checked references over $MIN_LINES lines, all open with a current Contents list)"
    exit 0
fi
echo "reference-contents: $flagged of $checked references over $MIN_LINES lines lack a current Contents list ($no_list no list, $stale stale) in $skills skill(s)$([ "$STRICT" -eq 1 ] && echo ' (strict: failing)' || echo ' (warn only; --report lists them)')"
[ "$STRICT" -eq 1 ] && exit 1
exit 0
