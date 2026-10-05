#!/usr/bin/env bash
# Run a Python script with the first interpreter that really is Python 3.8+.
#
# Usage:   run-python.sh <script.py | -c CODE | -> [ARGS...]
#          run-python.sh --which
# Input:   argv: everything after the launcher passes to python verbatim; stdin
#          is inherited (so `cmd | run-python.sh script.py` works)
# Output:  the interpreter's own stdout, untouched; --which prints the chosen
#          command name (python3, python or py)
# Stderr:  the interpreter's stderr; one ERROR line if no Python 3.8+ is found
# Exit:    the script's own exit code; 0 --help/--which, 2 usage,
#          5 no Python 3.8+ on PATH
#
# Why it exists: on Windows `python3` is often the Microsoft Store app-execution
# alias, which prints an install hint and exits 49 without running anything;
# `python` is missing on stock macOS and many Linux images; `py` is the Windows
# launcher. `command -v` finds the Store alias, so each candidate is asked to run
# a version check instead. The .py scripts' `#!/usr/bin/env python3` shebang hits
# the same alias, which is why this skill's docs launch them through this file.
#
# Examples:
#   bash scripts/run-python.sh scripts/exposure-check.py --root .
#   bash scripts/run-python.sh --which
#   PY="$(bash scripts/run-python.sh --which)" && "$PY" -m py_compile scripts/*.py
#
# Deliberately duplicated: an identical copy ships in each skill that has .py
# scripts (supply-chain-defense, prompt-injection-defense), because each skill
# folder must run when copied alone. Keep the copies byte-identical -
# tests/check-resources.sh compares them.
set -uo pipefail

EXIT_USAGE=2
EXIT_NO_PYTHON=5
CANDIDATES="python3 python py"
# Asks the interpreter itself; a stub or a pre-3.8 build exits non-zero.
PROBE='import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'

usage() {  # print the header comment block (minus the shebang) as help
  local line
  while IFS= read -r line; do
    case "$line" in
      '#!'*) ;;
      '#'*) line="${line#\#}"; printf '%s\n' "${line# }" ;;
      *) break ;;
    esac
  done < "${BASH_SOURCE[0]}"
}

pick() {  # echo the first candidate that runs the probe; return 1 if none does
  local c
  for c in $CANDIDATES; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c "$PROBE" </dev/null >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

no_python() {
  printf 'ERROR: no Python 3.8+ found (tried: %s). Install Python 3.8 or newer;\n' "$CANDIDATES" >&2
  printf '       on Windows, if python3 is the Microsoft Store alias, turn it off under\n' >&2
  printf '       Settings > Apps > Advanced app settings > App execution aliases.\n' >&2
  exit "$EXIT_NO_PYTHON"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --which)
    [[ $# -eq 1 ]] || { echo "ERROR: --which takes no arguments (try --help)" >&2; exit "$EXIT_USAGE"; }
    PY="$(pick)" || no_python
    printf '%s\n' "$PY"; exit 0 ;;
  "") echo "ERROR: missing script to run (try --help)" >&2; exit "$EXIT_USAGE" ;;
esac

PY="$(pick)" || no_python
exec "$PY" "$@"
