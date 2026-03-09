#!/bin/bash
# hooks/dangerous-cmd-warn.sh
# PreToolUse hook - warns before destructive or irreversible commands
# Matcher: Bash
#
# Configuration in .claude/settings.json:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "hooks": ["bash hooks/dangerous-cmd-warn.sh $TOOL_INPUT"]
#     }]
#   }
# }
#
# Exit codes:
#   0 = allow (safe or not matched)
#   2 = block with message (dangerous command detected)

INPUT="$1"

if [[ -z "$INPUT" ]]; then
  exit 0
fi

# -------------------------------------------------------------------
# Dangerous patterns and their risk descriptions
# -------------------------------------------------------------------

declare -A PATTERNS

# Git destructive operations
PATTERNS["git\s+push\s+.*--force"]="Force push can overwrite remote history and lose others' commits"
PATTERNS["git\s+push\s+-f\b"]="Force push can overwrite remote history and lose others' commits"
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
PATTERNS["UPDATE\s+\w+\s+SET\s+.*(?!WHERE)"]="UPDATE without WHERE clause modifies all rows"

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

# Environment/secrets
PATTERNS["printenv"]="Prints all environment variables (may contain secrets)"
PATTERNS["env\s*$"]="Prints all environment variables (may contain secrets)"
PATTERNS["cat\s+.*\\.env"]="Displaying .env file may expose secrets"

# -------------------------------------------------------------------
# Check each pattern
# -------------------------------------------------------------------

for pattern in "${!PATTERNS[@]}"; do
  if echo "$INPUT" | grep -qEi "$pattern"; then
    echo "WARNING: Potentially dangerous command detected"
    echo "Pattern: $pattern"
    echo "Risk: ${PATTERNS[$pattern]}"
    echo ""
    echo "The command has been blocked. If you're certain this is safe,"
    echo "ask the user to confirm before proceeding."
    exit 2
  fi
done

exit 0
