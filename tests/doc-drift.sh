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
#   5. Every file-relative markdown link inside skills/**/*.md resolves
#      to an existing path (links inside skills are relative to the file,
#      not the repo root; exclusions documented at the check itself)
#
# Exit 0 = clean, exit 1 = drift detected.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

errors=0
err() { echo "DRIFT: $*"; errors=$((errors + 1)); }

# True only if the path exists with EXACTLY this spelling, component by
# component. `[ -e ]` is case-insensitive on Windows and macOS filesystems, so a
# link to docs/auto-mode-classifier.md passed locally while the file was
# docs/AUTO-MODE-CLASSIFIER.md - and failed on case-sensitive Linux CI.
# Each directory is listed once and cached, and the comparison is pure bash:
# spawning ls+grep per component per link took this gate from seconds to minutes
# under Git Bash, where process start-up is expensive.
declare -A DIR_LS=()
exists_exact() {
    local p="$1" cur="" part dir
    [ -e "$p" ] || return 1
    local IFS='/'
    for part in $p; do
        case "$part" in
            ''|'.') continue ;;
            '..') cur="${cur:+$cur/}.."; continue ;;
        esac
        dir="${cur:-.}"
        if [ -z "${DIR_LS[$dir]+set}" ]; then
            DIR_LS[$dir]=$'\n'"$(ls -a -- "$dir" 2>/dev/null)"$'\n'
        fi
        [[ "${DIR_LS[$dir]}" == *$'\n'"$part"$'\n'* ]] || return 1
        cur="${cur:+$cur/}$part"
    done
}

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
# Only TOTALS are gated here: subset counts in the same prose ("58 skills ship
# real scripts", "21 skills ship a verifier") are not the skill total, so never
# widen a pattern to a bare '[0-9]+ skills' — it would flag every one of them.
check_readme_prose() { # $1=regex $2=disk-count $3=label
    local span claim matched=0
    while IFS= read -r span; do
        [ -n "$span" ] || continue
        matched=$((matched + 1))
        # The claim is read from the MATCHED SPAN, not the whole line: README
        # prose is number-dense ("~100 tokens per skill ... 108 skills cost"),
        # and the first number on the line is often not the one being claimed.
        claim="$(echo "$span" | grep -oE '[0-9]+' | head -1)"
        [ "$claim" = "$2" ] || err "README.md: $claim $3 claimed, $2 on disk"
    done < <(grep -oE "$1" README.md || true)
    # Zero matches = the count-bearing line was deleted or reworded, which is
    # drift too — a guard that finds nothing to check must not stay silent.
    [ "$matched" -ge 1 ] || err "README.md: prose pattern for '$3' matched no lines (deleted/reworded?)"
}
check_readme_prose 'Its [0-9]+ skills' "$skills_disk" "skills (intro paragraph)"
check_readme_prose '[0-9]+ skills cost' "$skills_disk" "skills (token-cost bullet)"
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
        exists_exact "$path" || err "$doc: link target does not exist (or wrong case): $path"
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

# --- 5. Skill-internal link check (skills/**/*.md) --------------------------
# Links inside a skill are FILE-relative (`../../rules/x.md`, `../color-ops/SKILL.md`),
# unlike the repo-root-relative links check 3 handles — so each is resolved against
# the directory of the file containing it. Only NON-RESOLVING links are flagged:
# climbing out of the skill directory is intentional and common (cross-skill and
# rule cross-references), and failing those would bury real breakage in noise.
#
# Exclusions, and why each one is not a loophole:
#   - skills/*/assets/**   templates copied INTO another repo; their links are meant
#                          to resolve at the destination, never here.
#   - fenced code blocks   ``` / ~~~ regions are examples, not navigation. This also
#                          removes generic signatures like `Map[K, V](m map[K]V, ...)`
#                          which look exactly like a markdown link to a regex.
#   - inline code spans    same reason, e.g. `* [Title](url) - description`.
#   - http/https/mailto    external; not this gate's business.
#   - / and ~/ prefixes    absolute and home-relative (`~/.claude/rules/...`) paths
#                          deliberately name the INSTALLED location, not a repo path.
#   - #anchor-only         intra-document.
#   - <, {, $, or a space  template placeholders and prose, not real paths.
while IFS= read -r skill_doc; do
    case "$skill_doc" in */assets/*) continue ;; esac
    skill_dir="$(dirname "$skill_doc")"
    while IFS= read -r link; do
        case "$link" in
            http://*|https://*|mailto:*|/*|'~/'*|'#'*|'') continue ;;
            *'<'*|*'{'*|*'$'*|*' '*) continue ;;
        esac
        link="${link%%#*}"   # strip anchors
        [ -z "$link" ] && continue
        exists_exact "$skill_dir/$link" || err "$skill_doc: link target does not exist (or wrong case): $link"
    done < <(awk '
        /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
        fence { next }
        { gsub(/`[^`]*`/, ""); print }
    ' "$skill_doc" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//')
done < <(find skills -name '*.md' | sort)


echo
if [ "$errors" -eq 0 ]; then
    echo "doc-drift: clean"
    exit 0
else
    echo "doc-drift: $errors issue(s) found"
    exit 1
fi
