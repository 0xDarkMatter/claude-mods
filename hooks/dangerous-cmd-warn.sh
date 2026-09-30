#!/bin/bash
# hooks/dangerous-cmd-warn.sh
# PreToolUse hook - warns before destructive or irreversible commands
# Matcher: Bash
#
# Configuration in .claude/settings.json (Claude Code sends the tool call as JSON
# on stdin; a positional argument is still accepted for older wiring):
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "hooks": [{ "type": "command", "command": "bash hooks/dangerous-cmd-warn.sh" }]
#     }]
#   }
# }
#
# Exit codes:
#   0 = allow (safe or not matched)
#   2 = block; the reason goes to STDERR, which Claude Code feeds back to the model
# Contract tests: tests/hooks.sh

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

# -------------------------------------------------------------------
# Dangerous patterns and their risk descriptions
# -------------------------------------------------------------------

declare -A PATTERNS

# Git destructive operations
# `--force([^-]|$)` so the SAFE variants (--force-with-lease, --force-if-includes)
# are not blocked - they refuse to overwrite commits you haven't seen.
PATTERNS["git\s+push\s+.*--force([^-]|$)"]="Force push can overwrite remote history and lose others' commits"
PATTERNS["git\s+push\s+(.*\s)?-f(\s|$)"]="Force push can overwrite remote history and lose others' commits"
PATTERNS["git\s+reset\s+--hard"]="Hard reset discards all uncommitted changes permanently"
PATTERNS["git\s+clean\s+-f"]="git clean -f permanently deletes untracked files"
PATTERNS["git\s+checkout\s+--\s+\."]="Discards all unstaged changes in working directory"
PATTERNS["git\s+branch\s+-D"]="Force-deletes a branch even if not fully merged"
PATTERNS["git\s+stash\s+drop"]="Permanently removes a stash entry"
PATTERNS["git\s+rebase\s+.*--force"]="Forced rebase can rewrite shared history"

# File system destructive operations
PATTERNS["rm\s+-rf\s+/"]="Recursive force delete from root - catastrophic data loss"
PATTERNS["rm\s+-rf\s+~"]="Recursive force delete of home directory"
PATTERNS["rm\s+-rf\s+\\."]="Recursive force delete of current directory"
PATTERNS["rm\s+-rf\s+\*"]="Recursive force delete with glob - likely unintended"
PATTERNS["rmdir\s+/"]="Attempting to remove root directory"
PATTERNS["> /dev/sda"]="Direct write to block device - destroys filesystem"
PATTERNS["mkfs\\."]="Formatting a filesystem destroys all data"
PATTERNS["dd\s+.*of=/dev/"]="Direct disk write - can destroy data"

# Database destructive operations
PATTERNS["DROP\s+DATABASE"]="Drops entire database - all data lost"
PATTERNS["DROP\s+TABLE"]="Drops table and all its data permanently"
PATTERNS["DROP\s+SCHEMA"]="Drops schema and all contained objects"
PATTERNS["TRUNCATE\s+TABLE"]="Removes all rows without logging - cannot rollback"
PATTERNS["DELETE\s+FROM\s+\w+\s*;"]="DELETE without WHERE clause removes all rows"
# UPDATE-without-WHERE is checked explicitly below: grep -E has no lookahead, and
# the old `(?!WHERE)` pattern silently never matched anything.

# Process/system operations
PATTERNS["kill\s+-9\s+1\b"]="Killing PID 1 (init/systemd) crashes the system"
PATTERNS["killall\s+-9"]="Force-kills all matching processes without cleanup"
PATTERNS["chmod\s+-R\s+777"]="World-writable recursive permissions - security risk"
PATTERNS["chown\s+-R\s+.*\s+/"]="Recursive ownership change from root"

# Container operations
PATTERNS["docker\s+system\s+prune\s+-a"]="Removes ALL unused Docker data (images, containers, volumes)"
PATTERNS["docker\s+volume\s+prune"]="Removes all unused Docker volumes (data loss)"
PATTERNS["kubectl\s+delete\s+namespace"]="Deletes entire Kubernetes namespace and all resources"
PATTERNS["kubectl\s+delete\s+.*--all"]="Deletes all resources of a type"

# Package/dependency operations
PATTERNS["npm\s+cache\s+clean\s+--force"]="Clears entire npm cache"
PATTERNS["pip\s+install\s+--force-reinstall"]="Force reinstalls all packages"

# Environment/secrets - only the BARE commands dump everything. `printenv HOME`,
# `env FOO=1 node app.js` and `uv venv` (which merely ends in "env") are fine.
PATTERNS["(^|[;&|(]\s*)printenv\s*($|[;&|)])"]="Prints all environment variables (may contain secrets)"
PATTERNS["(^|[;&|(]\s*)env\s*($|[;&|)])"]="Prints all environment variables (may contain secrets)"
# .env files are checked explicitly below so example/template files are allowed.

# -------------------------------------------------------------------
# Check each pattern
# -------------------------------------------------------------------

# Claude Code feeds a blocking hook's STDERR back to the model; stdout is not
# shown. The reason must go to stderr or the agent is blocked without knowing why.
block() {   # $1 = what matched, $2 = risk
  {
    echo "WARNING: Potentially dangerous command detected"
    echo "Pattern: $1"
    echo "Risk: $2"
    echo ""
    echo "The command has been blocked. If you're certain this is safe,"
    echo "ask the user to confirm before proceeding."
  } >&2
  exit 2
}

for pattern in "${!PATTERNS[@]}"; do
  if printf '%s\n' "$INPUT" | grep -qEi "$pattern"; then
    block "$pattern" "${PATTERNS[$pattern]}"
  fi
done

# UPDATE ... SET without a WHERE anywhere in the statement.
if printf '%s\n' "$INPUT" | grep -qEi 'UPDATE\s+\w+\s+SET\s' \
   && ! printf '%s\n' "$INPUT" | grep -qEi '\bWHERE\b'; then
  block "UPDATE ... SET without WHERE" "UPDATE without WHERE clause modifies all rows"
fi

# Reading a real .env file (not .env.example / .sample / .template / .dist).
if printf '%s\n' "$INPUT" | grep -qEi '(^|[;&|(]\s*)(cat|bat|less|more|head|tail)\s'; then
  set -f
  for tok in $INPUT; do
    t="${tok##*/}"; t="${t%%[;&|)\"\']*}"
    if [[ "$t" =~ ^\.env(\.[A-Za-z0-9_-]+)?$ ]] \
       && ! [[ "$t" =~ \.(example|sample|template|dist|defaults)$ ]]; then
      block "reading $t" "Displaying a .env file may expose secrets"
    fi
  done
  set +f
fi

exit 0
