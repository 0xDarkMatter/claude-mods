# Skill Trigger Tests

Test cases to verify skills activate on expected keywords.

## How to Test

1. Start a new Claude Code session
2. Say one of the test prompts
3. Verify the expected skill appears in the response (skill name shown in status)

---

## code-stats

**Triggers:** how big is codebase, count lines of code, what languages, show semantic diff, compare files, code statistics

| Test Prompt | Should Activate |
|-------------|-----------------|
| "How big is this codebase?" | Yes |
| "Count lines of code in this project" | Yes |
| "What languages are used here?" | Yes |
| "Show me a semantic diff between these files" | Yes |
| "Compare file1.ts and file2.ts" | Yes |
| "Give me code statistics" | Yes |
| "What's the weather like?" | No |

---

## data-processing

**Triggers:** parse JSON, extract from YAML, query config, Docker Compose, K8s manifests, GitHub Actions workflows, package.json, filter data

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Parse this JSON file" | Yes |
| "Extract the version from package.json" | Yes |
| "Query the Docker Compose config" | Yes |
| "What services are in this K8s manifest?" | Yes |
| "Filter the data to show only active users" | Yes |
| "Extract values from this YAML" | Yes |
| "What's in the GitHub Actions workflow?" | Yes |
| "Read this Python file" | No |

---

## doc-scanner

**Triggers:** review codebase, understand project, explore codebase, conventions, agents, documentation context, AGENTS.md, CLAUDE.md

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Help me understand this codebase" | Yes |
| "What are the project conventions?" | Yes |
| "Explore this new project" | Yes |
| "Is there an AGENTS.md file?" | Yes |
| "Review the documentation" | Yes |
| "Consolidate the platform docs" | Yes |
| "What color is the sky?" | No |

---

## file-search

**Triggers:** fd, ripgrep, rg, find files, search code, fzf, fuzzy find, search codebase

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Find all TypeScript files" | Yes |
| "Search the codebase for 'TODO'" | Yes |
| "Use fd to find config files" | Yes |
| "Fuzzy find the login component" | Yes |
| "Search code for authentication logic" | Yes |
| "Write a new function" | No |

---

## find-replace

**Triggers:** sd, find replace, batch replace, sed replacement, string replacement, rename

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Find and replace 'newName' with 'newName'" | Yes |
| "Batch replace across all files" | Yes |
| "Use sd to update the imports" | Yes |
| "Rename this variable everywhere" | Yes |
| "String replacement in config files" | Yes |
| "What does this function do?" | No |

---

## git-workflow

**Triggers:** stage changes, create PR, review PR, check issues, git diff, commit interactively, GitHub operations, rebase, stash, bisect

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Stage my changes" | Yes |
| "Create a PR for this branch" | Yes |
| "Review this PR" | Yes |
| "Check open issues" | Yes |
| "Show git diff" | Yes |
| "Commit these changes interactively" | Yes |
| "Rebase onto main" | Yes |
| "Stash my current work" | Yes |
| "Use git bisect to find the bug" | Yes |
| "What's in this file?" | No |

---

## mcp-patterns

**Triggers:** mcp server, model context protocol, tool handler, mcp resource, mcp tool

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Help me build an MCP server" | Yes |
| "What's the Model Context Protocol?" | Yes |
| "How do I write a tool handler?" | Yes |
| "Create an MCP resource" | Yes |
| "Add an MCP tool" | Yes |
| "Write a REST API" | No |

---

## project-planner

**Triggers:** sync plan, update plan, check status, plan is stale, track progress, project planning

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Sync the plan" | Yes |
| "Update the project plan" | Yes |
| "Check plan status" | Yes |
| "Is the plan stale?" | Yes |
| "Track my progress" | Yes |
| "Help with project planning" | Yes |
| "Write some code" | No |

---

## python-env

**Triggers:** uv, venv, pip, pyproject, python environment, install package, dependencies

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Set up a Python environment with uv" | Yes |
| "Create a new venv" | Yes |
| "Install package with pip" | Yes |
| "Update pyproject.toml" | Yes |
| "Manage Python dependencies" | Yes |
| "Write a JavaScript function" | No |

---

## rest-patterns

**Triggers:** rest api, http methods, status codes, api design, endpoint design, api versioning, rate limiting, caching

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Design a REST API" | Yes |
| "What HTTP methods should I use?" | Yes |
| "What status code for not found?" | Yes |
| "Help with API endpoint design" | Yes |
| "Implement API versioning" | Yes |
| "Add rate limiting" | Yes |
| "What caching headers should I use?" | Yes |
| "Fix this CSS" | No |

---

## sql-patterns

**Triggers:** sql patterns, cte example, window functions, sql join, index strategy, pagination sql

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Show me SQL patterns" | Yes |
| "Write a CTE example" | Yes |
| "How do window functions work?" | Yes |
| "Which SQL join should I use?" | Yes |
| "What's the index strategy here?" | Yes |
| "Implement pagination in SQL" | Yes |
| "Write a Python script" | No |

---

## sqlite-ops

**Triggers:** sqlite, sqlite3, aiosqlite, local database, database schema, migration, wal mode

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Set up SQLite for this project" | Yes |
| "Use sqlite3 to query data" | Yes |
| "Configure aiosqlite for async" | Yes |
| "Create a local database" | Yes |
| "Define the database schema" | Yes |
| "Run a database migration" | Yes |
| "Enable WAL mode" | Yes |
| "Connect to PostgreSQL" | No |

---

## structural-search

**Triggers:** find all calls to X, search for pattern, refactor usages, find where function is used, structural search

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Find all calls to console.log" | Yes |
| "Search for this pattern in the AST" | Yes |
| "Refactor all usages of this function" | Yes |
| "Find where this function is used" | Yes |
| "Do a structural search" | Yes |
| "Use ast-grep to find imports" | Yes |
| "What's the current time?" | No |

---

## tailwind-patterns

**Triggers:** tailwind, utility classes, responsive design, tailwind config, dark mode css, tw classes

| Test Prompt | Should Activate |
|-------------|-----------------|
| "What Tailwind classes for flexbox?" | Yes |
| "Add responsive design classes" | Yes |
| "Update tailwind.config.js" | Yes |
| "Implement dark mode with CSS" | Yes |
| "Which tw classes for shadows?" | Yes |
| "Explain these utility classes" | Yes |
| "Write a React component" | No |

---

## task-runner

**Triggers:** run tests, build project, list tasks, check available commands, run script, project commands

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Run the tests" | Yes |
| "Build this project" | Yes |
| "List available tasks" | Yes |
| "What commands are available?" | Yes |
| "Run the lint script" | Yes |
| "Show project commands" | Yes |
| "What's in this file?" | No |

---

## tool-discovery

**Triggers:** which agent, which skill, what tool should I use, help me choose, recommend agent, find the right tool

| Test Prompt | Should Activate |
|-------------|-----------------|
| "Which agent should I use for this?" | Yes |
| "Which skill handles JSON?" | Yes |
| "What tool should I use for code review?" | Yes |
| "Help me choose the right agent" | Yes |
| "Recommend an agent for testing" | Yes |
| "Find the right tool for this task" | Yes |
| "Write a function" | No |
