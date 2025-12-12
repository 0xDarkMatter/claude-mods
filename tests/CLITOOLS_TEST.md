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
| 8 | View shell processes | `ps` (standard) | N/A - ps is fine for shell |
| 9 | Get help for git command | `tldr` via Bash | `Bash(man:*)` |
| 10 | Fetch simple webpage content | `WebFetch` | Goes to Jina/Firecrawl first |
| 11 | Fetch JS-heavy/blocked page | Jina Reader (`r.jina.ai/`) or `firecrawl` | Gives up without trying fallbacks |
| 12 | Fetch when WebFetch returns 403 | `firecrawl` CLI | Doesn't escalate |
| 13 | Extract structured data from page | `firecrawl-expert` agent | Uses simpler tools |

## Pass Criteria

- Tasks 1, 4: Must use `Grep` tool (which internally uses ripgrep)
- Tasks 2, 5: Must use `Glob` tool or `eza`/`fd` via Bash
- Task 3: Must use `Read` tool or `bat` via Bash
- Task 6: Should use `delta` for enhanced diff output
- Task 7: Must use `dust` (not `du`)
- Task 8: `ps` is acceptable for shell process checks
- Task 9: Must use `tldr` (not `man`)
- Task 10: Must use `WebFetch` tool for simple pages
- Task 11: Must try `WebFetch` first, then fallback to Jina (`r.jina.ai/`) or `firecrawl`
- Task 12: Must escalate to `firecrawl` CLI when WebFetch fails with 403
- Task 13: Must use `firecrawl-expert` agent (Task tool) for structured extraction

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
10. "Fetch the content from https://example.com"
11. "Fetch the content from https://medium.com/@anthropic/introducing-claude-3-5-sonnet-229d8c80e2bc"
12. "Fetch content from [URL that returns 403]" (simulate blocked)
13. "Extract all product details (name, price, description) from https://www.amazon.com/dp/B0CX23V2ZK"

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
| 10 | `WebFetch` | PASS |
| 11 | `WebFetch` → 403 → `r.jina.ai/` | PASS |
| 12 | `WebFetch` → fail → `r.jina.ai/` → 403 → `firecrawl` | PASS |
| 13 | `Task(firecrawl-expert)` | PASS |
