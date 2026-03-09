#!/bin/bash
# hooks/pre-commit-lint.sh
# PreToolUse hook - runs linter on staged files before commit
# Matcher: Bash (when command contains "git commit")
#
# Configuration in .claude/settings.json:
# {
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "Bash",
#       "hooks": ["bash hooks/pre-commit-lint.sh $TOOL_INPUT"]
#     }]
#   }
# }

INPUT="$1"

# Only trigger on git commit commands
if ! echo "$INPUT" | grep -qE 'git\s+commit'; then
  exit 0
fi

# Collect staged files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)

if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

ERRORS=0

lint_js() {
  local files
  files=$(echo "$STAGED_FILES" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs)$')
  if [[ -n "$files" ]]; then
    if command -v npx &>/dev/null && [[ -f "node_modules/.bin/eslint" ]]; then
      echo "Linting JS/TS files..."
      echo "$files" | xargs npx eslint --max-warnings 0 2>/dev/null
      return $?
    elif command -v biome &>/dev/null; then
      echo "Linting JS/TS files with Biome..."
      echo "$files" | xargs biome check 2>/dev/null
      return $?
    fi
  fi
  return 0
}

lint_python() {
  local files
  files=$(echo "$STAGED_FILES" | grep -E '\.py$')
  if [[ -n "$files" ]]; then
    if command -v ruff &>/dev/null; then
      echo "Linting Python files..."
      echo "$files" | xargs ruff check 2>/dev/null
      return $?
    elif command -v flake8 &>/dev/null; then
      echo "$files" | xargs flake8 2>/dev/null
      return $?
    fi
  fi
  return 0
}

lint_go() {
  local files
  files=$(echo "$STAGED_FILES" | grep -E '\.go$')
  if [[ -n "$files" ]]; then
    if command -v golangci-lint &>/dev/null; then
      echo "Linting Go files..."
      golangci-lint run --new-from-rev=HEAD 2>/dev/null
      return $?
    elif command -v go &>/dev/null; then
      go vet ./... 2>/dev/null
      return $?
    fi
  fi
  return 0
}

lint_rust() {
  local files
  files=$(echo "$STAGED_FILES" | grep -E '\.rs$')
  if [[ -n "$files" ]]; then
    if command -v cargo &>/dev/null && [[ -f "Cargo.toml" ]]; then
      echo "Linting Rust files..."
      cargo clippy --all-targets -- -D warnings 2>/dev/null
      return $?
    fi
  fi
  return 0
}

lint_php() {
  local files
  files=$(echo "$STAGED_FILES" | grep -E '\.php$')
  if [[ -n "$files" ]]; then
    if command -v ./vendor/bin/pint &>/dev/null; then
      echo "Linting PHP files..."
      echo "$files" | xargs ./vendor/bin/pint --test 2>/dev/null
      return $?
    elif command -v php &>/dev/null; then
      for f in $files; do
        php -l "$f" 2>/dev/null || return 1
      done
    fi
  fi
  return 0
}

# Run all applicable linters
lint_js || ERRORS=$((ERRORS + 1))
lint_python || ERRORS=$((ERRORS + 1))
lint_go || ERRORS=$((ERRORS + 1))
lint_rust || ERRORS=$((ERRORS + 1))
lint_php || ERRORS=$((ERRORS + 1))

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "LINT FAILED: $ERRORS linter(s) reported issues."
  echo "Fix the issues above before committing."
  exit 1
fi

exit 0
