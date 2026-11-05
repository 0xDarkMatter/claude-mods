#!/usr/bin/env bash
# Change-aware check for DEVELOPMENT: run only the gates and suites that cover what changed.
#
# The full gate (`just check`) runs everything and takes many minutes on Windows. This
# maps each changed path to the checks that can see it (tests/changed-map.tsv owns the
# mapping and explains it), then runs those, up to -j at a time. It is NOT a landing gate:
# suites assert on sibling files in ways no map fully captures, so `just check` and the
# fleet-ops landing queue keep running the full sweep (AGENTS.md Landmines).
#
# Changed paths = `git diff --name-only <base>...HEAD` (committed on this branch) + `git diff
# --name-only HEAD` (staged and unstaged) + untracked files. Renames count as delete + add.
# A path no rule in the map covers, or a FULL rule, runs the full sweep instead.
#
# Parallelism: targets are independent processes that each work in their own mktemp dir, so
# they run -j at a time (default 4). @serial targets in the map (fleet-ops) run alone after
# the parallel batch, because two heavy suites at once flake on a loaded machine.
#
# Usage:  bash tests/check-changed.sh [--list] [-j N] [base]
# Exit:   0 every selected check passed, 1 a check failed, 2 usage or setup error.
set -u

usage() {
    cat <<'EOF'
Usage: tests/check-changed.sh [--list] [-j N] [base]

Run only the checks that cover paths changed since <base> (default: main, then
origin/main) plus uncommitted and untracked files. Mapping: tests/changed-map.tsv.
Development only: `just check` is still the landing gate.

  --list   print the changed paths and the selected checks, run nothing
  -j N     run up to N checks at once (default 4; env CHECK_JOBS)

EXAMPLES
  just check-changed
  just check-changed origin/main
  bash tests/check-changed.sh --list HEAD~3
  bash tests/check-changed.sh -j 1

Exit codes: 0 all selected checks passed, 1 a check failed, 2 usage or setup error.
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
MAP="tests/changed-map.tsv"

LIST=0; JOBS="${CHECK_JOBS:-4}"; BASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1 ;;
        -j) shift; JOBS="${1:-}" ;;
        -j*) JOBS="${1#-j}" ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "check-changed: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) [ -z "$BASE" ] || { echo "check-changed: one base only" >&2; exit 2; }; BASE="$1" ;;
    esac
    shift
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "check-changed: -j wants a positive number, got '$JOBS'" >&2; exit 2; }
[ -f "$MAP" ] || { echo "check-changed: $MAP missing" >&2; exit 2; }

if [ -z "$BASE" ]; then
    for b in main origin/main; do
        git rev-parse -q --verify "$b^{commit}" >/dev/null && { BASE="$b"; break; }
    done
    [ -n "$BASE" ] || { echo "check-changed: no main or origin/main; pass a base" >&2; exit 2; }
fi
git rev-parse -q --verify "$BASE^{commit}" >/dev/null || { echo "check-changed: unknown base '$BASE'" >&2; exit 2; }

# --- changed paths ---------------------------------------------------------------
rc=0
changed="$( {
    git diff --name-only --no-renames "$BASE...HEAD" &&
    git diff --name-only --no-renames HEAD &&
    git ls-files --others --exclude-standard
} | sort -u)" || rc=$?
[ "$rc" -eq 0 ] || { echo "check-changed: git could not list changes (exit $rc)" >&2; exit 2; }

# --- the map -----------------------------------------------------------------------
ALWAYS=""; SERIAL=" "
pats=(); tgts=()
while IFS=$'\t' read -r pat targets; do
    case "$pat" in ''|'#'*) continue ;; esac
    case "$pat" in
        @always) ALWAYS="$targets" ;;
        @serial) SERIAL=" $targets " ;;
        *) pats+=("$pat"); tgts+=("$targets") ;;
    esac
done < "$MAP"
[ -n "$ALWAYS" ] || { echo "check-changed: $MAP has no @always line" >&2; exit 2; }

declare -A want=()     # target -> why
FULL=""
skills_changed=()
add() { [ -n "${want[$1]+set}" ] || want[$1]="$2"; }

while IFS= read -r path; do
    [ -n "$path" ] || continue
    matched=0
    for i in "${!pats[@]}"; do
        # shellcheck disable=SC2053  # the pattern is a glob on purpose
        [[ "$path" == ${pats[i]} ]] || continue
        matched=1
        for t in ${tgts[i]}; do
            case "$t" in
                FULL) FULL="${FULL:-$path}" ;;
                -) ;;
                own)
                    s="${path#skills/}"; s="${s%%/*}"
                    [ -f "skills/$s/tests/run.sh" ] && add "suite:$s" "$path"
                    [ -f "tests/skills/functional/$s/e2e.sh" ] && add "e2e:$s" "$path"
                    skills_changed+=("$s") ;;
                *) add "$t" "$path" ;;
            esac
        done
    done
    [ "$matched" -eq 1 ] || FULL="${FULL:-$path (unmapped)}"
done <<< "$changed"

# --- cross-readers: suites and gates that name a changed skill --------------------
# One grep over every suite file, gate and suite helper, not one per pair: per-pair
# greps were thousands of process starts. Text match on purpose - a false positive just
# runs one extra suite; dynamic paths it cannot see are why landing runs everything.
GATES="validate spec doc-drift agnostic skill-hygiene hooks check-resources check-ps51-parse skill-size reference-contents procsub-guard check-exec-bits"
if [ -z "$FULL" ] && [ "${#skills_changed[@]}" -gt 0 ]; then
    alt="$(printf '%s\n' "${skills_changed[@]}" | sort -u | paste -sd'|')"
    files=()
    for f in skills/*/tests/* tests/skills/functional/*/e2e.sh; do [ -f "$f" ] && files+=("$f"); done
    for g in $GATES; do files+=("tests/$g.sh"); done
    rc=0
    hits="$(grep -lE -- "(skills/|\.\./)($alt)/" "${files[@]}" 2>/dev/null)" || rc=$?
    [ "$rc" -le 1 ] || { echo "check-changed: cross-reader scan failed (grep exit $rc)" >&2; exit 2; }
    while IFS= read -r f; do
        case "$f" in
            skills/*/tests/*) s="${f#skills/}"; s="${s%%/*}"
                              [ -f "skills/$s/tests/run.sh" ] && add "suite:$s" "reads ${alt//|/,}" ;;
            tests/skills/functional/*/e2e.sh) s="${f#tests/skills/functional/}"; add "e2e:${s%%/*}" "reads ${alt//|/,}" ;;
            tests/*.sh) g="${f#tests/}"; add "gate:${g%.sh}" "reads ${alt//|/,}" ;;
        esac
    done <<< "$hits"
fi

if [ -n "$FULL" ]; then
    want=()
    for g in $GATES; do [ "$g" = check-exec-bits ] || add "gate:$g" "full sweep"; done
    for f in skills/*/tests/run.sh; do s="${f#skills/}"; add "suite:${s%%/*}" "full sweep"; done
    for f in tests/skills/functional/*/e2e.sh; do s="${f#tests/skills/functional/}"; add "e2e:${s%%/*}" "full sweep"; done
fi
for t in $ALWAYS; do add "$t" "always"; done

target_cmd() {  # target -> script path
    case "$1" in
        gate:*)  echo "tests/${1#gate:}.sh" ;;
        suite:*) echo "skills/${1#suite:}/tests/run.sh" ;;
        e2e:*)   echo "tests/skills/functional/${1#e2e:}/e2e.sh" ;;
    esac
}

par=(); ser=()
for t in $(printf '%s\n' "${!want[@]}" | sort); do
    [ -f "$(target_cmd "$t")" ] || { echo "check-changed: $t has no script ($(target_cmd "$t"))" >&2; exit 2; }
    if [[ "$SERIAL" == *" $t "* ]]; then ser+=("$t"); else par+=("$t"); fi
done

n_changed=$(grep -c . <<< "$changed")
echo "check-changed: $n_changed path(s) changed vs $BASE${FULL:+ - full sweep (first trigger: $FULL)}"
if [ "$LIST" -eq 1 ]; then
    [ "$n_changed" -eq 0 ] || sed 's/^/  changed  /' <<< "$changed"
    for t in "${par[@]}" "${ser[@]}"; do printf '  run      %-28s %s\n' "$t" "${want[$t]}"; done
    exit 0
fi

# --- run ----------------------------------------------------------------------------
LOGS="$(mktemp -d)"
fails=()
start=$EPOCHSECONDS
run_one() {  # target -> exit code; log in $LOGS
    local t="$1" s=$EPOCHSECONDS rc=0
    bash "$(target_cmd "$t")" > "$LOGS/${t//[:\/]/_}.log" 2>&1 || rc=$?
    echo "$rc $((EPOCHSECONDS - s))" > "$LOGS/${t//[:\/]/_}.rc"
    return "$rc"
}
report() {
    local t="$1" rc secs
    read -r rc secs < "$LOGS/${t//[:\/]/_}.rc"
    if [ "$rc" -eq 0 ]; then
        printf '  PASS  %-28s %4ss\n' "$t" "$secs"
    else
        printf '  FAIL  %-28s %4ss  (exit %s)\n' "$t" "$secs" "$rc"
        tail -n 30 "$LOGS/${t//[:\/]/_}.log" | sed 's/^/        /'
        fails+=("$t")
    fi
}

running=()
for t in "${par[@]}"; do
    while [ "${#running[@]}" -ge "$JOBS" ]; do
        wait -n 2>/dev/null || true
        still=()
        for r in "${running[@]}"; do
            if [ -f "$LOGS/${r//[:\/]/_}.rc" ]; then report "$r"; else still+=("$r"); fi
        done
        running=("${still[@]}")
    done
    run_one "$t" &
    running+=("$t")
done
wait
for r in "${running[@]}"; do report "$r"; done
for t in "${ser[@]}"; do run_one "$t"; report "$t"; done

total=$(( ${#par[@]} + ${#ser[@]} ))
echo "check-changed: $(( total - ${#fails[@]} ))/$total passed in $((EPOCHSECONDS - start))s${fails[*]:+ - FAILED: ${fails[*]}}"
if [ "${#fails[@]}" -eq 0 ]; then rm -rf "$LOGS"; exit 0; fi
echo "check-changed: full logs in $LOGS"
exit 1
