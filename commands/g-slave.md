---
description: Dispatch Gemini CLI to analyze large codebases. Gemini does the grunt work with its 1M token context, returns distilled intel to Claude.
---

# G-SLAVE: Gemini Large-context Analysis & Verification Engine

You are dispatching Gemini CLI as a subordinate tool to analyze code that would bloat your context window. Gemini does the heavy lifting; you receive distilled intelligence.

## Target

$ARGUMENTS

If no arguments provided, analyze current working directory.

## Execution Protocol

### Step 1: Verify Gemini CLI is Available

```bash
which gemini || echo "ERROR: Gemini CLI not installed. Install: https://github.com/google-gemini/gemini-cli"
```

### Step 2: Check for Agent Configuration Files

Before analysis, check if the project has any agent instruction files that Gemini should respect:

```bash
# Check for common agent config files
ls -la AGENTS.md GEMINI.md CLAUDE.md WARP.md COPILOT.md CURSOR.md CODEX.md README.md CONTRIBUTING.md .github/AGENTS.md .claude/CLAUDE.md 2>/dev/null
```

If found, inform the user:
- **GEMINI.md**: Gemini CLI will automatically use this
- **Other agent files**: Suggest including them in the prompt with `@AGENTS.md` etc. so Gemini respects the project conventions

### Step 3: Parse Arguments & Determine Mode

**Modes:**

| Pattern | Mode | Description |
|---------|------|-------------|
| `/g-slave <path>` | **Analyze** | Full analysis of target |
| `/g-slave ask "<question>"` | **Ask** | Direct question about codebase |
| `/g-slave verify "<statement>"` | **Verify** | Yes/no verification check |
| `/g-slave compare <path1> <path2>` | **Compare** | Diff analysis between two targets |

**Flags:**

| Flag | Effect |
|------|--------|
| `--arch` | Focus: Architecture, structure, design patterns |
| `--security` | Focus: Security vulnerabilities, auth, injection risks |
| `--deps` | Focus: Dependencies, imports, coupling analysis |
| `--quality` | Focus: Code quality, tech debt, antipatterns |
| `--test` | Focus: Test coverage, testing patterns, gaps |
| `--perf` | Focus: Performance bottlenecks, optimization opportunities |
| `--brief` | Output: ~500 char summary |
| `--detailed` | Output: ~5000 char comprehensive breakdown |
| `--raw` | Output: Unfiltered Gemini response (no distillation) |
| `--save <file>` | Export: Save analysis to specified file |
| `--exclude <patterns>` | Ignore: Comma-separated patterns (e.g., `node_modules,dist,.git`) |
| `--prompt "<custom>"` | Custom: Use provided prompt instead of default |
| `--all` | Scope: Use `--all_files` flag for entire project |

### Step 4: Construct Default Exclusions

Always recommend excluding these token-wasters unless user specifically needs them:
- `node_modules/`, `vendor/`, `venv/`, `.venv/`, `__pycache__/`
- `.git/`, `.svn/`, `.hg/`
- `dist/`, `build/`, `out/`, `target/`
- `*.lock`, `*.log`, `coverage/`

Use the `--exclude` flag or advise user to add exclusions to their GEMINI.md.

### Step 5: Execute Gemini Command

**CRITICAL: Gemini must operate in READ-ONLY mode. No code execution, no file modifications.**

Add to all prompts: `"IMPORTANT: This is a read-only analysis. Do not execute code or modify files."`

---

#### Mode: Analyze (default)

```bash
gemini -p "@<path>/ IMPORTANT: Read-only analysis only. Analyze this codebase. Focus: <focus_area>. Provide: 1) Architecture overview 2) Key patterns 3) Notable issues 4) Recommendations. Be thorough but concise."
```

#### Mode: Ask

```bash
gemini -p "@<path>/ IMPORTANT: Read-only analysis only. <user_question> Provide a direct, specific answer with file paths and line references where applicable."
```

#### Mode: Verify

```bash
gemini -p "@<path>/ IMPORTANT: Read-only analysis only. Verify: <statement>. Answer with: YES/NO followed by evidence (file paths, code snippets) supporting your answer."
```

#### Mode: Compare

```bash
gemini -p "@<path1>/ @<path2>/ IMPORTANT: Read-only analysis only. Compare these two codebases/directories. Identify: 1) Structural differences 2) Logic changes 3) Added/removed features 4) Potential issues from changes."
```

#### With Custom Prompt

```bash
gemini -p "@<path>/ IMPORTANT: Read-only analysis only. <custom_prompt>"
```

#### Full Project Scan

```bash
gemini --all_files -p "IMPORTANT: Read-only analysis only. <prompt>"
```

### Step 6: Detect Framework & Tailor Analysis

Before executing, quickly identify the stack and adjust analysis focus:

| Detected | Tailor Prompt To Include |
|----------|--------------------------|
| `package.json` | React/Vue/Node patterns, npm security |
| `requirements.txt` / `pyproject.toml` | Django/Flask/FastAPI patterns, Python idioms |
| `Cargo.toml` | Rust ownership patterns, unsafe usage |
| `go.mod` | Go concurrency patterns, error handling |
| `composer.json` | Laravel/Symfony patterns, PHP security |
| `Gemfile` | Rails patterns, Ruby idioms |
| `pom.xml` / `build.gradle` | Spring patterns, Java architecture |

### Step 7: Distill Results

**If `--raw` flag: Skip distillation, return full Gemini output.**

Otherwise, extract and present based on verbosity:

**--brief (~500 chars):**
```markdown
## Gemini Analysis: <target>
<3-4 sentence executive summary covering architecture, main issues, top recommendation>
```

**Default (~2000 chars):**
```markdown
## Gemini Analysis: <target>

**Scope:** <what was analyzed>
**Focus:** <focus area or "general">

### Architecture
<concise 3-5 line summary>

### Key Patterns
- Pattern 1
- Pattern 2

### Issues (prioritized)
1. **High:** <critical issue>
2. **Medium:** <notable concern>
3. **Low:** <minor item>

### Recommendations
1. <actionable recommendation>
2. <actionable recommendation>

---
*Analysis via Gemini CLI (1M token context) | Distilled for Claude*
```

**--detailed (~5000 chars):**
Include all of the above plus:
- Detailed file-by-file breakdown of key components
- Dependency analysis with version concerns
- Security considerations
- Performance observations
- Testing gaps
- Technical debt inventory

### Step 8: Handle --save Flag

If `--save <filename>` provided:
1. Write the analysis output to the specified file
2. Confirm save location to user
3. Still display summary in conversation

```bash
# Example save
echo "<analysis_output>" > <filename>
```

## Response Templates

### For Ask Mode
```markdown
## Answer: <question summary>

<direct answer>

**Evidence:**
- `path/to/file.py:42` - <relevant code/context>
- `path/to/other.js:17` - <relevant code/context>

---
*Via Gemini CLI | Read-only analysis*
```

### For Verify Mode
```markdown
## Verification: <statement>

**Result:** YES / NO / PARTIAL

**Evidence:**
- <supporting finding 1>
- <supporting finding 2>

**Location(s):** `file:line`, `file:line`

---
*Via Gemini CLI | Read-only analysis*
```

### For Compare Mode
```markdown
## Comparison: <path1> vs <path2>

### Structural Differences
- <difference 1>
- <difference 2>

### Logic Changes
- <change 1>
- <change 2>

### Added/Removed
| Added | Removed |
|-------|---------|
| <item> | <item> |

### Risk Assessment
<potential issues from changes>

---
*Via Gemini CLI | Read-only analysis*
```

## Error Handling

| Error | Action |
|-------|--------|
| Gemini CLI not found | Provide install link: https://github.com/google-gemini/gemini-cli |
| Path doesn't exist | Report error, ask for correct path |
| Analysis timeout | Suggest narrower scope or `--exclude` patterns |
| Output too large | Summarize more aggressively (unless `--raw`) |
| Rate limited | Inform user, suggest waiting or reducing scope |
| Permission denied | Check file permissions, suggest alternatives |

## Usage Examples

```bash
# Basic analysis
/g-slave src/

# Direct question
/g-slave ask "Where is user authentication implemented?"

# Verification check
/g-slave verify "All API endpoints have rate limiting"

# Security audit with exclusions
/g-slave . --security --exclude node_modules,dist,coverage

# Compare branches (checkout both first)
/g-slave compare ./main-branch ./feature-branch

# Custom analysis saved to file
/g-slave . --prompt "Find all API endpoints and document their HTTP methods, parameters, and auth requirements" --save api-docs.md

# Quick overview
/g-slave . --brief

# Full deep-dive
/g-slave . --detailed --save full-analysis.md

# Raw Gemini output (no distillation)
/g-slave . --arch --raw
```

## Remember

1. **You are the commander.** Gemini is the grunt. Extract value, don't relay noise.
2. **Read-only always.** Never let Gemini execute or modify.
3. **Distill by default.** Only pass raw output when explicitly requested.
4. **Check for agent files.** Respect project conventions.
5. **Exclude junk.** Don't waste the 1M context on node_modules.
