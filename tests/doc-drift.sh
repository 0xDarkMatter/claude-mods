#!/usr/bin/env bash
# Doc-drift gate: documentation must describe what is actually on disk.
#
# Checks:
#   1. Component counts on disk vs claims in README.md header, AGENTS.md
#      overview bullets, docs/PLAN.md inventory table, and selected README prose
#   2. Every skill directory has a row in a README skill table
#   3. Every repo-relative markdown link in README.md / AGENTS.md resolves
#      to an existing file or directory (no ghost references)
#   4. Skill frontmatter references only skills that exist on disk
#
# Exit 0 = clean, exit 1 = drift detected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

errors=0
err() { echo "DRIFT: $*"; errors=$((errors + 1)); }

# --- 1. Counts on disk ------------------------------------------------------
skills_disk=0
for d in skills/*/; do
    [ -f "$d/SKILL.md" ] && skills_disk=$((skills_disk + 1))
done
agents_disk=$(find agents -maxdepth 1 -name '*.md' | wc -l)
hooks_disk=$(find hooks -maxdepth 1 -name '*.sh' | wc -l)
rules_disk=$(find rules -maxdepth 1 -name '*.md' | wc -l)
styles_disk=$(find output-styles -maxdepth 1 -name '*.md' | wc -l)
commands_disk=$(find commands -maxdepth 1 -name '*.md' | wc -l)

echo "Disk: agents=$agents_disk skills=$skills_disk styles=$styles_disk hooks=$hooks_disk rules=$rules_disk commands=$commands_disk"

# --- README header claim: "**N agents. N skills. N styles. N hooks. N rules. ...**"
header="$(grep -oE '\*\*[0-9]+ agents\. [0-9]+ skills\. [0-9]+ styles\. [0-9]+ hooks\. [0-9]+ rules\.' README.md | head -1)"
if [ -z "$header" ]; then
    err "README.md: count header line not found (expected '**N agents. N skills. ...**')"
else
    read -r r_agents r_skills r_styles r_hooks r_rules <<< \
        "$(echo "$header" | grep -oE '[0-9]+' | tr '\n' ' ')"
    [ "$r_agents" = "$agents_disk" ] || err "README header: $r_agents agents claimed, $agents_disk on disk"
    [ "$r_skills" = "$skills_disk" ] || err "README header: $r_skills skills claimed, $skills_disk on disk"
    [ "$r_styles" = "$styles_disk" ] || err "README header: $r_styles styles claimed, $styles_disk on disk"
    [ "$r_hooks"  = "$hooks_disk"  ] || err "README header: $r_hooks hooks claimed, $hooks_disk on disk"
    [ "$r_rules"  = "$rules_disk"  ] || err "README header: $r_rules rules claimed, $rules_disk on disk"
fi

# --- Selected README prose count claims -------------------------------------
# These five known count-bearing patterns are intentionally exhaustive; newly
# introduced prose patterns must be added explicitly if they should be gated.
check_readme_prose() { # $1=regex $2=disk-count $3=label
    local line claim matched=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        matched=$((matched + 1))
        claim="$(echo "$line" | grep -oE '[0-9]+' | head -1)"
        [ "$claim" = "$2" ] || err "README.md: $claim $3 claimed, $2 on disk"
    done < <(grep -E "$1" README.md || true)
    # Zero matches = the count-bearing line was deleted or reworded, which is
    # drift too — a guard that finds nothing to check must not stay silent.
    [ "$matched" -ge 1 ] || err "README.md: prose pattern for '$3' matched no lines (deleted/reworded?)"
}
check_readme_prose '[0-9]+ specialized skills' "$skills_disk" "specialized skills"
check_readme_prose '[0-9]+ on-demand skills' "$skills_disk" "on-demand skills"
check_readme_prose 'Custom skills \([0-9]+\)' "$skills_disk" "custom skills"
check_readme_prose 'Slash commands \([0-9]+\)' "$commands_disk" "slash commands"
check_readme_prose 'Expert subagents \([0-9]+\)' "$agents_disk" "expert subagents"

# --- AGENTS.md overview bullets ---------------------------------------------
check_agents_md() { # $1=regex $2=disk-count $3=label
    local claim
    claim="$(grep -oE "$1" AGENTS.md | head -1 | grep -oE '[0-9]+')"
    if [ -z "$claim" ]; then
        err "AGENTS.md: no '$3' count bullet found"
    elif [ "$claim" != "$2" ]; then
        err "AGENTS.md: $claim $3 claimed, $2 on disk"
    fi
}
check_agents_md '\*\*[0-9]+ expert agents\*\*' "$agents_disk" "agents"
check_agents_md '\*\*[0-9]+ skills\*\*' "$skills_disk" "skills"
check_agents_md '\*\*[0-9]+ output styles\*\*' "$styles_disk" "output styles"
check_agents_md '\*\*[0-9]+ hooks\*\*' "$hooks_disk" "hooks"
check_agents_md '\*\*[0-9]+ commands\*\*' "$commands_disk" "commands"

# --- docs/PLAN.md inventory table -------------------------------------------
check_plan() { # $1=row-label $2=disk-count
    local claim
    claim="$(grep -E "^\| $1 \|" docs/PLAN.md | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
    if [ -n "$claim" ] && [ "$claim" != "$2" ]; then
        err "docs/PLAN.md: $1 = $claim claimed, $2 on disk"
    fi
}
check_plan "Agents" "$agents_disk"
check_plan "Skills" "$skills_disk"
check_plan "Commands" "$commands_disk"
check_plan "Rules" "$rules_disk"
check_plan "Output Styles" "$styles_disk"
check_plan "Hooks" "$hooks_disk"

# --- 2. Every skill has a README row ----------------------------------------
for d in skills/*/; do
    n="$(basename "$d")"
    [ -f "$d/SKILL.md" ] || continue
    grep -q "skills/$n/" README.md || err "README.md: skill '$n' has no table row"
done

# --- 3. Ghost-link check (README.md + AGENTS.md) ----------------------------
for doc in README.md AGENTS.md; do
    while IFS= read -r path; do
        path="${path%%#*}"   # strip anchors
        [ -z "$path" ] && continue
        [ -e "$path" ] || err "$doc: link target does not exist: $path"
    done < <(grep -oE '\]\((skills|agents|hooks|rules|output-styles|commands|docs|tools|tests|scripts)/[^)]*\)' "$doc" \
             | sed -E 's/^\]\(//; s/\)$//')
done

# --- 4. Skill frontmatter ghost references ---------------------------------
# These are Claude-Code-bundled skills, not skills shipped by this repo.
# Keep this allowlist narrow: every other unknown reference is a failure.
external_skills="frontend-design"

for skill_file in skills/*/SKILL.md; do
    while IFS= read -r refs; do
        refs="${refs#*:}"
        refs="${refs#"${refs%%[![:space:]]*}"}"
        refs="${refs%"${refs##*[![:space:]]}"}"
        refs="${refs#\"}"; refs="${refs%\"}"
        IFS=',' read -ra names <<< "$refs"
        for name in "${names[@]}"; do
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            [ -z "$name" ] && continue
            case " $external_skills " in *" $name "*) continue ;; esac
            [ -d "skills/$name" ] || err "$skill_file: unknown skill reference '$name'"
        done
    done < <(awk '
        NR == 1 && $0 == "---" { frontmatter=1; next }
        frontmatter && $0 == "---" { exit }
        frontmatter && /^metadata:/ { metadata=1; next }
        metadata && /^[^ ]/ { metadata=0 }
        metadata && /^  (related-skills|depends-on):/ { print }
    ' "$skill_file")
done

echo
if [ "$errors" -eq 0 ]; then
    echo "doc-drift: clean"
    exit 0
else
    echo "doc-drift: $errors issue(s) found"
    exit 1
fi
