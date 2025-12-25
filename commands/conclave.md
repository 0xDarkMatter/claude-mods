---
description: "[DEPRECATED] Use the standalone Conclave CLI instead: https://github.com/0xDarkMatter/conclave"
---

# Conclave - DEPRECATED

> **This command has been deprecated.** Conclave is now a standalone CLI tool.

---

## Migration

The `/conclave` command has been replaced by the **Conclave CLI** - a standalone, universal multi-LLM consensus tool that works from any context (Claude Code, OpenCode, Gemini CLI, terminal, CI/CD).

### Install

```bash
# macOS/Linux
curl -fsSL https://raw.githubusercontent.com/0xDarkMatter/conclave/main/install.sh | bash

# Or with Go
go install github.com/0xDarkMatter/conclave@latest
```

### Usage

```bash
# Query multiple LLMs with a judge for synthesis
conclave gemini,openai,glm "Is this code secure?" --judge claude

# Pipe file content
cat src/auth.ts | conclave gemini,openai "Review this" --judge claude

# Multiple files
conclave gemini,openai "Compare these" --file a.go --file b.go --judge claude

# Raw results (no synthesis)
conclave gemini,openai "Analyze this" --no-judge --json
```

### Why the change?

The original `/conclave` command was 877 lines of documentation that Claude had to parse and manually execute every time. The new CLI:

- **Self-contained** - Handles orchestration and synthesis internally
- **Universal** - Works from any LLM tool, not just Claude Code
- **Faster** - Single binary, parallel execution, structured output
- **Configurable judge** - Any LLM can synthesize the verdict

---

## Repository

**GitHub:** [https://github.com/0xDarkMatter/conclave](https://github.com/0xDarkMatter/conclave)

See the repository for full documentation, configuration options, and provider support.
