#!/usr/bin/env bash
# Skill-size gate: warn when a SKILL.md body outgrows what Claude Code keeps
# after auto-compaction.
#
# Why this budget: after compaction Claude Code re-attaches each invoked skill
# but keeps only the FIRST 5,000 tokens of it (25,000 combined across skills) -
# https://code.claude.com/docs/en/skills, "Auto-compaction carries invoked
# skills forward within a token budget". Anything past that point silently
# vanishes mid-session, so the procedure, decision tables and hard rules must
# sit inside it and long material belongs in references/ (loaded on demand,
# not re-attached). The Agent Skills spec (agentskills.io/specification) gives
# the same 5,000-token ceiling for instructions.
#
# Measure: estimated tokens = body characters / 3.6, rounded. The body is
# everything after the closing frontmatter fence; frontmatter is excluded
# because it is loaded separately (the description budget is validate.sh's
# job). Characters, not bytes: counted under a UTF-8 locale, else an em dash
# would count three times. Lines are a poor proxy - a 266-line skill can carry
# 6,800 tokens.
#
# Modes:
#   bash tests/skill-size.sh              warn on over-budget skills, exit 0
#   bash tests/skill-size.sh --strict     same, but exit 1 if any warn
#   bash tests/skill-size.sh --report     print every skill's estimate, largest first
#   bash tests/skill-size.sh DIR          scan DIR/*/SKILL.md instead of skills/
#   SKILL_SIZE_WARN_TOKENS=4500 bash tests/skill-size.sh   override the threshold
#
# Every run first proves the gate can see: a built-in self-test scans a
# temporary oversized fixture and must warn on it, and must NOT warn on a
# small body under a huge frontmatter. A gate that passes while blind is worse
# than none (see the agnostic-gate landmine in AGENTS.md).
#
# Exit 0 = clean or warnings only, 1 = --strict and over budget, 2 = the gate
# itself is broken (self-test failed, or no skills found to scan).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARN_TOKENS="${SKILL_SIZE_WARN_TOKENS:-5000}"
STRICT=0
REPORT=0
SKILLS_DIR="$ROOT/skills"

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --report) REPORT=1 ;;
        -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "skill-size: unknown option $arg" >&2; exit 2 ;;
        *) SKILLS_DIR="$arg" ;;
    esac
done

# Body of a SKILL.md: drop the leading ----fenced frontmatter block only.
skill_body() {
    awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next}
         fm==1 && /^---[[:space:]]*$/ {fm=2; next}
         fm!=1 {print}' "$1"
}

# Estimated tokens, rounded: round(chars / 3.6) == (chars*10 + 18) / 36.
estimate_tokens() {
    local chars
    chars=$(skill_body "$1" | LC_ALL=C.UTF-8 wc -m)
    echo $(( (chars * 10 + 18) / 36 ))
}

# Prints "tokens<TAB>name" for every skill in $1, largest first.
scan() {
    local dir="$1" f name
    for f in "$dir"/*/SKILL.md; do
        [ -f "$f" ] || continue
        name=$(basename "$(dirname "$f")")
        printf '%s\t%s\n' "$(estimate_tokens "$f")" "$name"
    done | sort -rn
}

# --- self-test: the gate must see an oversized body, and ignore frontmatter --
self_test() {
    local tmp out
    tmp=$(mktemp -d) || return 1
    mkdir -p "$tmp/too-big" "$tmp/big-frontmatter"
    {
        printf -- '---\nname: too-big\ndescription: fixture\n---\n'
        # 24,000 chars of body ~ 6,667 tokens: over any sane threshold
        for _ in $(seq 1 300); do printf '%079d\n' 0; done
    } > "$tmp/too-big/SKILL.md"
    {
        printf -- '---\nname: big-frontmatter\ndescription: "'
        for _ in $(seq 1 300); do printf '%079d' 0; done
        printf '"\n---\nsmall body\n'
    } > "$tmp/big-frontmatter/SKILL.md"
    out=$(scan "$tmp")
    rm -rf "$tmp"
    local big small
    big=$(awk -F'\t' '$2=="too-big" {print $1}' <<<"$out")
    small=$(awk -F'\t' '$2=="big-frontmatter" {print $1}' <<<"$out")
    if [ -z "$big" ] || [ "$big" -le "$WARN_TOKENS" ]; then
        echo "skill-size: SELF-TEST FAILED - oversized fixture measured '${big:-nothing}' tokens, not above $WARN_TOKENS" >&2
        return 1
    fi
    if [ -z "$small" ] || [ "$small" -gt 10 ]; then
        echo "skill-size: SELF-TEST FAILED - frontmatter leaked into the body estimate ('${small:-nothing}' tokens)" >&2
        return 1
    fi
}

self_test || exit 2

results=$(scan "$SKILLS_DIR")
if [ -z "$results" ]; then
    echo "skill-size: no */SKILL.md found under $SKILLS_DIR - refusing to pass blind" >&2
    exit 2
fi

total=$(wc -l <<<"$results")
over=0
if [ "$REPORT" -eq 1 ]; then
    printf '%8s  %s\n' "~tokens" "skill"
    while IFS=$'\t' read -r tok name; do printf '%8s  %s\n' "$tok" "$name"; done <<<"$results"
    echo
fi
while IFS=$'\t' read -r tok name; do
    if [ "$tok" -gt "$WARN_TOKENS" ]; then
        echo "WARN: $name SKILL.md body ~$tok tokens (> $WARN_TOKENS) - compaction keeps only the first 5,000; move detail into references/"
        over=$((over + 1))
    fi
done <<<"$results"

if [ "$over" -eq 0 ]; then
    echo "skill-size: clean ($total skills, all bodies <= ~$WARN_TOKENS tokens)"
    exit 0
fi
echo "skill-size: $over of $total skill(s) over ~$WARN_TOKENS tokens$([ "$STRICT" -eq 1 ] && echo ' (strict: failing)' || echo ' (warn only)')"
[ "$STRICT" -eq 1 ] && exit 1
exit 0
