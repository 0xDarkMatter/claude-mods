# Manual Skill Trigger Test

Run these tests in a **fresh Claude Code session** to verify skills are invoked naturally.

## Instructions

1. Start a new session: `claude`
2. Say each test phrase exactly as written
3. Record the result in the Result column

## Test Matrix

| # | Test Phrase | Expected Skill | Expected Tool | Result |
|---|-------------|----------------|---------------|--------|
| 1 | "How many lines of code in this project?" | code-stats | tokei | |
| 2 | "Show me a semantic diff between README.md and AGENTS.md" | code-stats | difft | |
| 3 | "Parse the dependencies from package.json" | data-processing | jq | |
| 4 | "What services are in docker-compose.yml?" | data-processing | yq | |
| 5 | "Extract the name from config.yaml" | data-processing | yq | |
| 6 | "Find all calls to console.log in the codebase" | structural-search | ast-grep (sg) | |
| 7 | "Search for function declarations using AST" | structural-search | sg | |
| 8 | "Find all TypeScript files" | file-search | fd | |
| 9 | "Fuzzy find the config file" | file-search | fzf | |
| 10 | "Batch replace newName with newName across all files" | find-replace | sd | |
| 11 | "Create a PR for this branch" | git-workflow | gh | |
| 12 | "Show git diff with syntax highlighting" | git-workflow | delta | |
| 13 | "Set up a Python environment with uv" | python-env | uv | |
| 14 | "Install these Python dependencies" | python-env | uv pip | |
| 15 | "Run the project tests" | task-runner | just | |
| 16 | "What tasks are available in this project?" | task-runner | just | |
| 17 | "Scan for project documentation files" | doc-scanner | glob/read | |
| 18 | "Help me design a REST API endpoint" | rest-patterns | (reference) | |
| 19 | "What HTTP status code for resource created?" | rest-patterns | (reference) | |
| 20 | "Write a SQL query with a CTE" | sql-patterns | (reference) | |
| 21 | "Set up SQLite with WAL mode" | sqlite-ops | sqlite3 | |
| 22 | "How do I build an MCP server?" | mcp-patterns | (reference) | |
| 23 | "Which agent should I use for this task?" | tool-discovery | (meta) | |

## Result Key

| Symbol | Meaning |
|--------|---------|
| ✅ | Skill invoked, correct tool used |
| ⚠️ | Correct tool used WITHOUT invoking skill |
| ❌ | Inferior built-in approach used |
| 🚫 | Skill not invoked, wrong tool used |

## Expected Behavior

For each test, Claude should:
1. Recognize the trigger phrase
2. Invoke the skill via `Skill` tool
3. Use the superior CLI tool from the skill

## Notes

Record observations here:

```
Test #:
Date:
Observations:
```
