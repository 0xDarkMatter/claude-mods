#!/bin/bash
# hooks/enforce-uv.sh
# PreToolUse hook - enforces uv over pip / bare tools inside uv-managed projects
# Matcher: Bash
#
# Turns the "modern-tools" guidance (a should-do prompt) into a deterministic
# must-do guard. Redirects:
#   pip install <pkg>        -> uv add <pkg>   (or `uv pip ...` for unmanaged envs)
#   pytest / ruff / mypy ... -> uv run <tool>
#
# Configuration in .claude/settings.json (the tool call arrives as JSON on stdin):
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "hooks": [{ "type": "command", "command": "bash hooks/enforce-uv.sh" }]
#     }]
#   }
# }
#
# Exit codes:
#   0 = allow (not a Python project, already uv, or no violation)
#   2 = block; the guidance goes to STDERR, which Claude Code feeds to the model
# Contract tests: tests/hooks.sh
#
# Scope guards:
#   - Only activates when a pyproject.toml exists in the working directory
#     (i.e. a uv-managed project). Outside one, pip/bare tools pass through.
#   - Honors ENFORCE_UV=0 to disable for a single command or session.

INPUT="$1"
# Modern Claude Code delivers the tool call as JSON on stdin
# ({"tool_input":{"command":"..."}}); older configs pass it as $TOOL_INPUT/$1.
# Support both so the hook works regardless of harness version.
if [[ -z "$INPUT" && ! -t 0 ]]; then
  RAW="$(cat 2>/dev/null)"
  if [[ -n "$RAW" ]] && command -v jq >/dev/null 2>&1; then
    INPUT="$(printf '%s' "$RAW" | jq -r '.tool_input.command // .tool_input // empty' 2>/dev/null)"
  fi
  [[ -z "$INPUT" ]] && INPUT="$RAW"
fi
[[ -z "$INPUT" ]] && exit 0
[[ "$ENFORCE_UV" == "0" ]] && exit 0

# Only enforce inside a uv-managed project
[[ -f "pyproject.toml" ]] || exit 0

# Claude Code feeds a blocking hook's STDERR back to the model; stdout is not
# shown ("Exit code 2" in https://code.claude.com/docs/en/hooks). On stdout the
# agent is blocked with no idea why or what to run instead.
block() {   # $1 = what matched, $2 = the uv equivalent
  {
    echo "BLOCKED (enforce-uv): $1"
    echo "Use instead:        $2"
    echo ""
    echo "This project has a pyproject.toml — prefer the uv workflow."
    echo "To bypass for one command, prefix it with ENFORCE_UV=0."
  } >&2
  exit 2
}

# --- pip install (mask the allowed `uv pip` compatibility layer first) -------
MASKED=$(printf '%s' "$INPUT" | sed -E 's/\buv pip\b/UV_PIP/g')
if printf '%s' "$MASKED" | grep -qE '\bpip[0-9.]*[[:space:]]+install\b'; then
  block "bare 'pip install'" "uv add <pkg>   (or 'uv pip install ...' for an unmanaged venv)"
fi

# --- bare dev tools that should run inside the project env -------------------
# Skip if the command already routes through uv (uv run / uvx).
if ! printf '%s' "$INPUT" | grep -qE '\b(uv run|uvx)\b'; then
  if printf '%s' "$INPUT" | grep -qE '(^|[;&|][[:space:]]*)(pytest|ruff|mypy|pyright|black|isort|flake8)\b'; then
    TOOL=$(printf '%s' "$INPUT" | grep -oE '(pytest|ruff|mypy|pyright|black|isort|flake8)' | head -1)
    block "bare '$TOOL' in a uv project" "uv run $TOOL ..."
  fi
fi

exit 0
