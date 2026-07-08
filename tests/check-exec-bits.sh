#!/usr/bin/env bash
# Check git index modes, not filesystem permissions (Git Bash can fake those).
# Root tests/*.sh and scripts/*.sh are excluded because tracked 100644 files
# there are legitimate today; this gate covers skill-bundled scripts only.
set -u

usage() {
    cat <<'EOF'
Usage: tests/check-exec-bits.sh [--help]

Print tracked skill scripts whose git mode is not 100755, one per line.

EXAMPLES
  bash tests/check-exec-bits.sh
  bash tests/check-exec-bits.sh --help

Exit codes: 0 clean, 1 findings, 2 usage error.
EOF
}

case "${1-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-exec-bits: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "check-exec-bits: too many arguments" >&2; usage >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

findings=0
while read -r mode object stage path; do
    case "$path" in
        skills/*/scripts/*.sh|skills/*/scripts/*.py|skills/*/scripts/*.mjs)
            if [ "$mode" != "100755" ]; then
                echo "$path"
                findings=$((findings + 1))
            fi
            ;;
    esac
done < <(git ls-files -s -- skills)

if [ "$findings" -eq 0 ]; then
    echo "check-exec-bits: clean" >&2
    exit 0
fi

echo "check-exec-bits: $findings file(s) are not tracked as 100755" >&2
exit 1
