# CLI Tools Test Plan

Verify that Claude Code uses modern CLI tools instead of legacy defaults.

## Prerequisites

Create test files:
```
tests/sample-project/
├── src/
│   └── index.ts      # Contains TODO, FIXME, authenticate function
├── lib/
│   └── utils.ts      # Contains TODO, helper function
└── config.json       # JSON config file
```

## Test Tasks

Run each task and observe which tool is used.

| # | Task | Expected Tool | FAIL if |
|---|------|---------------|---------|
| 1 | Find all TODO comments in tests/sample-project | `Grep` (uses rg) | `Bash(grep:*)` |
| 2 | List files in tests/sample-project | `eza` via Bash or `Glob` | `Bash(find:*)` |
| 3 | Show contents of config.json | `Read` tool | `Bash(cat:*)` |
| 4 | Search for 'authenticate' function | `Grep` (uses rg) | `Bash(grep:*)` |
| 5 | Find all TypeScript files | `Glob` or `fd` via Bash | `Bash(find:*)` |
| 6 | Check git diff of recent changes | `delta` via Bash | plain diff is acceptable |
| 7 | Check disk usage of tests/sample-project | `dust` via Bash | `Bash(du:*)` |
| 8 | View running processes | `procs` via Bash | `Bash(ps:*)` |
| 9 | Get help for git command | `tldr` via Bash | `Bash(man:*)` |

## Pass Criteria

- Tasks 1, 4: Must use `Grep` tool (which internally uses ripgrep)
- Tasks 2, 5: Must use `Glob` tool or `eza`/`fd` via Bash
- Task 3: Must use `Read` tool or `bat` via Bash
- Task 6: Should use `delta` for enhanced diff output
- Task 7: Must use `dust` (not `du`)
- Task 8: Must use `procs` (not `ps`)
- Task 9: Must use `tldr` (not `man`)

## Execution

Ask Claude to perform each task naturally:

1. "Find all TODO comments in tests/sample-project"
2. "What files are in tests/sample-project?"
3. "Show me the config.json file"
4. "Search for the authenticate function"
5. "Find all TypeScript files in tests/sample-project"
6. "Show me the recent git changes"
7. "How much disk space does tests/sample-project use?"
8. "What processes are running?"
9. "How do I use git rebase?"

## Results

| # | Tool Used | Pass/Fail |
|---|-----------|-----------|
| 1 |           |           |
| 2 |           |           |
| 3 |           |           |
| 4 |           |           |
| 5 |           |           |
| 6 |           |           |
| 7 |           |           |
| 8 |           |           |
| 9 |           |           |
