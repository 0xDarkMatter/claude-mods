# Skill Tests

Automated test suite for validating all 16 skills.

## Quick Start

```bash
# Run all tests
./tests/skills/run-tests.sh

# Run specific test suite
./tests/skills/run-tests.sh triggers
./tests/skills/run-tests.sh data-processing

# List available tests
./tests/skills/run-tests.sh --list
```

## Test Types

| Type | Script | Purpose |
|------|--------|---------|
| Trigger validation | `validate-triggers.sh` | Validates frontmatter and trigger keywords |
| Functional | `functional/*.sh` | Tests CLI tools work correctly |

## Directory Structure

```
tests/skills/
├── run-tests.sh              # Main test runner
├── validate-triggers.sh      # Trigger keyword validation
├── trigger-tests.md          # Manual trigger test cases (reference)
├── fixtures/                 # Test data files
│   ├── package.json
│   ├── config.yaml
│   ├── docker-compose.yml
│   └── example.js
└── functional/
    ├── data-processing.sh    # jq, yq tests
    ├── code-stats.sh         # tokei, difft tests
    ├── git-workflow.sh       # gh, delta, lazygit tests
    └── structural-search.sh  # ast-grep tests
```

## Running Tests

### All Tests

```bash
./tests/skills/run-tests.sh
```

Output:
```
╔══════════════════════════════════════════╗
║         Skill Test Runner                ║
╚══════════════════════════════════════════╝

═══════════════════════════════════
  Trigger Validation
═══════════════════════════════════

--- code-stats ---
✓ code-stats: 6 trigger keywords
...

═══════════════════════════════════
  data-processing
═══════════════════════════════════

--- jq tests ---
✓ jq: extract single field
✓ jq: extract nested field
...

════════════════════════════════════════
  Test Summary
════════════════════════════════════════
  Suites passed: 5
  Suites failed: 0

All tests passed!
```

### Specific Tests

```bash
# Only trigger validation
./tests/skills/run-tests.sh --triggers

# Only functional tests
./tests/skills/run-tests.sh --functional

# Specific skill
./tests/skills/run-tests.sh data-processing
./tests/skills/run-tests.sh code-stats

# Multiple skills
./tests/skills/run-tests.sh data-processing structural-search
```

## Test Details

### Trigger Validation

Validates each skill's frontmatter:

- `name` matches directory name
- `name` is lowercase alphanumeric with hyphens (1-64 chars)
- `description` is non-empty (max 1024 chars)
- `description` contains "Triggers on:" with keywords
- `compatibility` field exists if skill uses CLI tools
- `allowed-tools` field is present

### Functional Tests

Each functional test:

1. Checks prerequisites (required CLI tools)
2. Runs test cases with assertions
3. Uses fixtures from `fixtures/` directory
4. Reports pass/fail/skip for each test
5. Returns exit code 0 on success, 1 on failure

#### data-processing.sh
- 7 jq tests (extract, filter, transform)
- 5 yq tests (YAML, TOML, Docker Compose)

#### code-stats.sh
- 3 tokei tests (line counts, JSON output)
- 3 difft tests (file comparison, syntax-aware)

#### git-workflow.sh
- 4 gh tests (auth, repo, API)
- 3 delta tests (diff formatting)
- 1 lazygit test (version check)

#### structural-search.sh
- 8 ast-grep tests (patterns, multi-language)

## Prerequisites

Install required tools:

```bash
# All tools
brew install jq yq tokei difftastic ast-grep gh delta lazygit

# Minimum for data-processing
brew install jq yq

# Check what's installed
./tests/skills/run-tests.sh --list
```

## Adding New Tests

### New Functional Test

Create `functional/skill-name.sh`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/../fixtures"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

pass() { ((PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((FAILED++)); echo -e "${RED}✗${NC} $1: $2"; }

# Check prerequisites
check_prereqs() {
    command -v your-tool >/dev/null 2>&1 || {
        echo "Missing: your-tool"
        exit 1
    }
}

# Tests
test_example() {
    local result
    result=$(your-tool --version)
    if [[ -n "$result" ]]; then
        pass "your-tool works"
    else
        fail "your-tool" "no output"
    fi
}

main() {
    echo "=== skill-name functional tests ==="
    check_prereqs
    test_example

    echo ""
    echo "Passed: $PASSED"
    echo "Failed: $FAILED"
    [[ $FAILED -eq 0 ]]
}

main "$@"
```

### New Fixture

Add files to `fixtures/`:
- JSON: `fixtures/example.json`
- YAML: `fixtures/example.yaml`
- Code: `fixtures/example.{js,py,ts}`

## CI Integration

Add to your CI workflow:

```yaml
- name: Run skill tests
  run: |
    chmod +x tests/skills/run-tests.sh
    ./tests/skills/run-tests.sh
```

## Troubleshooting

### "Permission denied"

```bash
chmod +x tests/skills/*.sh tests/skills/functional/*.sh
```

### "Command not found"

Install missing tools:
```bash
brew install jq yq tokei difftastic ast-grep gh delta
```

### Tests skip with "not authenticated"

For gh tests, run:
```bash
gh auth login
```
