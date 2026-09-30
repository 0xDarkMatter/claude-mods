#!/bin/bash
# hooks/post-edit-format.sh
# PostToolUse hook - auto-formats files after Write or Edit operations
# Matcher: Write|Edit
#
# Configuration in .claude/settings.json (Claude Code sends the tool call as JSON
# on stdin; a positional path is still accepted for older wiring):
# {
#   "hooks": {
#     "PostToolUse": [{
#       "matcher": "Write|Edit",
#       "hooks": [{ "type": "command", "command": "bash hooks/post-edit-format.sh" }]
#     }]
#   }
# }
# Contract tests: tests/hooks.sh

FILE="${1:-}"
# Read the path from the stdin JSON when no argument was given. Without this the
# hook received an empty path under modern Claude Code and silently formatted
# nothing, ever.
if [[ -z "$FILE" && ! -t 0 ]]; then
  RAW="$(cat 2>/dev/null)"
  if [[ -n "$RAW" ]] && command -v jq >/dev/null 2>&1; then
    FILE="$(printf '%s' "$RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
  fi
fi

# Skip if no file path provided
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  exit 0
fi

EXT="${FILE##*.}"
FORMATTED=false

format_js_ts() {
  if command -v npx &>/dev/null; then
    if [[ -f "node_modules/.bin/prettier" ]]; then
      npx prettier --write "$FILE" 2>/dev/null && FORMATTED=true
      return 0
    elif [[ -f "node_modules/.bin/biome" ]]; then
      npx biome format --write "$FILE" 2>/dev/null && FORMATTED=true
      return 0
    fi
  fi
  # Fallback: dprint if available
  if command -v dprint &>/dev/null; then
    dprint fmt "$FILE" 2>/dev/null && FORMATTED=true
  fi
}

format_python() {
  if command -v ruff &>/dev/null; then
    ruff format "$FILE" 2>/dev/null && FORMATTED=true
  elif command -v black &>/dev/null; then
    black --quiet "$FILE" 2>/dev/null && FORMATTED=true
  fi
  # Also fix import sorting
  if command -v ruff &>/dev/null; then
    ruff check --fix --select I "$FILE" 2>/dev/null
  elif command -v isort &>/dev/null; then
    isort --quiet "$FILE" 2>/dev/null
  fi
}

format_go() {
  if command -v goimports &>/dev/null; then
    goimports -w "$FILE" 2>/dev/null && FORMATTED=true
  elif command -v gofmt &>/dev/null; then
    gofmt -w "$FILE" 2>/dev/null && FORMATTED=true
  fi
}

format_rust() {
  if command -v rustfmt &>/dev/null; then
    rustfmt "$FILE" 2>/dev/null && FORMATTED=true
  fi
}

format_php() {
  if [[ -f "vendor/bin/pint" ]]; then
    ./vendor/bin/pint "$FILE" 2>/dev/null && FORMATTED=true
  elif command -v php-cs-fixer &>/dev/null; then
    php-cs-fixer fix "$FILE" --quiet 2>/dev/null && FORMATTED=true
  fi
}

format_css() {
  if command -v npx &>/dev/null && [[ -f "node_modules/.bin/prettier" ]]; then
    npx prettier --write "$FILE" 2>/dev/null && FORMATTED=true
  fi
}

format_json_yaml() {
  if command -v npx &>/dev/null && [[ -f "node_modules/.bin/prettier" ]]; then
    npx prettier --write "$FILE" 2>/dev/null && FORMATTED=true
  elif command -v dprint &>/dev/null; then
    dprint fmt "$FILE" 2>/dev/null && FORMATTED=true
  fi
}

case "$EXT" in
  ts|tsx|js|jsx|mjs|cjs)
    format_js_ts
    ;;
  py|pyi)
    format_python
    ;;
  go)
    format_go
    ;;
  rs)
    format_rust
    ;;
  php)
    format_php
    ;;
  css|scss|less)
    format_css
    ;;
  json|yaml|yml)
    format_json_yaml
    ;;
  md)
    # Markdown formatting is optional and sometimes unwanted
    # Uncomment to enable:
    # if command -v npx &>/dev/null && [[ -f "node_modules/.bin/prettier" ]]; then
    #   npx prettier --write --prose-wrap preserve "$FILE" 2>/dev/null && FORMATTED=true
    # fi
    ;;
esac

# Silent success - only output on format to keep context clean
if [[ "$FORMATTED" == "true" ]]; then
  echo "Formatted: $(basename "$FILE")"
fi

exit 0
