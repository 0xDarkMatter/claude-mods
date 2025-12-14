---
description: Summon external LLM CLIs (Gemini, OpenAI Codex, Claude, Perplexity) for analysis, research, and consensus. Use Gemini's 2M context, OpenAI's deep reasoning, Claude's coding expertise, Perplexity's web search, or convene multiple models for verdicts.
---

# Conclave - Multi-LLM Council

> Convene a council of AI models. Use each model's strengths: Gemini's massive context, OpenAI's reasoning depth, Claude's coding excellence, Perplexity's web-grounded answers, or summon them all for consensus verdicts.

```
/conclave [provider] [target] [--flags]
    |
    +-> Step 1: Detect Provider
    |     +- gemini (default) -> Gemini CLI
    |     +- openai / codex   -> OpenAI Codex CLI
    |     +- claude           -> Claude Code CLI (headless)
    |     +- perplexity / pplx -> Perplexity CLI (web search)
    |     +- --all            -> Multiple providers (consensus mode)
    |
    +-> Step 2: Select Mode
    |     +- analyze (default) -> Codebase analysis
    |     +- ask "<question>"  -> Direct question
    |     +- verify "<stmt>"   -> Yes/no verification
    |     +- compare <a> <b>   -> Diff analysis
    |
    +-> Step 3: Configure Autonomy
    |     +- --auto            -> Enable autonomous mode
    |     +- --thinking        -> Extended reasoning (where supported)
    |     +- --quiet           -> Non-interactive, parseable output
    |
    +-> Step 4: Execute & Distill
          +- Run conclaved command
          +- Parse structured output
          +- Return distilled results to Claude
```

---

## Quick Start

```bash
# Basic usage (Gemini, analyze current directory)
/conclave .

# Ask Gemini a question about the codebase
/conclave ask "Where is authentication implemented?"

# Use OpenAI Codex for deep reasoning
/conclave openai . --thinking

# Use Claude CLI for another perspective
/conclave claude "Review this authentication flow"

# Use Perplexity for web-grounded research
/conclave perplexity "What are the latest React 19 breaking changes?"

# Get consensus from multiple models
/conclave --all "Is this code secure?"
```

---

## Arguments

```
$ARGUMENTS

Providers:
- (none) / gemini    -> Gemini CLI (default, 2M context)
- openai / codex     -> OpenAI Codex CLI (deep reasoning)
- claude             -> Claude Code CLI (coding expertise, headless mode)
- perplexity / pplx  -> Perplexity CLI (web search + citations)
- --all              -> Multiple providers (consensus mode)

Modes:
- <path>             -> Analyze target (default mode)
- ask "<question>"   -> Direct question about codebase
- verify "<stmt>"    -> Yes/no verification with evidence
- compare <a> <b>    -> Compare two paths/branches

Flags:
- --auto             -> Enable autonomous mode (no prompts)
- --thinking         -> Extended reasoning mode
- --quiet            -> Non-interactive output (JSON where supported)
- --model <name>     -> Override default model
- --save <file>      -> Save output to file
- --raw              -> Return unprocessed output
- --brief            -> ~500 char summary
- --detailed         -> ~5000 char comprehensive breakdown
- --setup            -> Interactive configuration wizard

Focus flags:
- --arch             -> Architecture, patterns, structure
- --security         -> Vulnerabilities, auth, injection
- --perf             -> Performance bottlenecks
- --quality          -> Code quality, tech debt
- --test             -> Test coverage, gaps
```

---

## Configuration

### Configuration File (Preferred)

Create `~/.claude/conclave.yaml` for all settings including API keys:

```yaml
# ~/.claude/conclave.yaml

# API Keys (preferred storage method)
# These take precedence over environment variables
api_keys:
  gemini: "your-gemini-api-key-here"
  openai: "your-openai-api-key-here"
  anthropic: "your-anthropic-api-key-here"  # For Claude CLI
  perplexity: "your-perplexity-api-key-here"

# Provider Configuration
providers:
  gemini:
    model: gemini-2.5-pro       # Strongest: gemini-2.5-pro
    default_flags:              # Flash: gemini-2.5-flash (faster, cheaper)
      - --output-format
      - json

  openai:
    model: gpt-5.2               # Strongest (requires ChatGPT login)
    default_flags:               # Alternatives: gpt-5.1-codex-max, gpt-4o
      - --quiet

  claude:
    model: sonnet                # Options: sonnet, opus, haiku
    default_flags:               # Uses Claude Code CLI in headless mode
      - --print
      - --output-format
      - json
    # Note: Uses ANTHROPIC_API_KEY env var or Claude Code login

  perplexity:
    model: sonar-pro             # Best balance: complex queries, more citations
    default_flags:               # Alternatives: sonar, sonar-reasoning, sonar-reasoning-pro
      - --citations
    # Unique: returns web citations with every response

# Consensus Mode (--all) Settings
consensus:
  providers: [gemini, openai, claude]  # Which providers participate
  require_consensus: true              # All must agree for YES/NO verdicts
```

### Default Models (Tested \& Working)

| Provider | Default Model | Context | Strengths |
|----------|---------------|---------|-----------|
| **Gemini** | `gemini-2.5-pro` | 1M tokens | **Agentic coding assistant** - best for code analysis (refuses non-code tasks) |
| **Gemini** | `gemini-2.5-flash` | 1M tokens | General-purpose, fast, answers any question |
| **Gemini** | `gemini-3-pro` | 1M tokens | Most intelligent (requires [Ultra subscription](https://ai.google.dev/gemini-api/docs/models)) |
| **OpenAI** | gpt-5.2 | 128K tokens | Deep reasoning, best knowledge (ChatGPT login) |
| **Claude** | `sonnet` | 200K tokens | **Coding excellence** - best for code review, refactoring, security analysis |
| **Claude** | `opus` | 200K tokens | Most capable - complex reasoning, nuanced analysis |
| **Claude** | `haiku` | 200K tokens | Fast, efficient - quick analysis, simple tasks |
| **Perplexity** | `sonar-pro` | 200K tokens | **Real-time web search** - best for research, current info, fact-checking |

> **Notes:**
> - `gemini-2.5-pro` is tuned as a "CLI agent for software engineering" - it deliberately refuses non-coding questions. Perfect for `/conclave` code analysis.
> - `gemini-2.5-flash` answers general questions but is less capable for complex code tasks.
> - Gemini 3 Pro requires Google AI Ultra subscription. Free tier users can [join the waitlist](https://developers.googleblog.com/en/5-things-to-try-with-gemini-3-pro-in-gemini-cli/).
> - Claude CLI uses your existing Claude Code authentication or `ANTHROPIC_API_KEY` environment variable.

### API Key Resolution Order

Keys are resolved in this priority order:

1. **Config file** - `~/.claude/conclave.yaml` (recommended)
2. **Environment variables** - `GEMINI_API_KEY`, `OPENAI_API_KEY`
3. **Interactive prompt** - If missing, prompt user in interactive mode

```
Key Resolution:
    ~/.claude/conclave.yaml (api_keys.gemini)
        ↓ (not found)
    Environment: GEMINI_API_KEY
        ↓ (not found)
    Interactive: "Enter Gemini API key: ___"
        ↓ (entered)
    Save to config? [y/N]
```

### First-Time Setup

When `/conclave` is run without configuration:

1. Check for `~/.claude/conclave.yaml`
2. If missing or incomplete, prompt:
   ```
   Gemini API key not found.
   Enter key (or press Enter to skip Gemini): ___

   OpenAI API key not found.
   Enter key (or press Enter to skip OpenAI): ___

   Save to ~/.claude/conclave.yaml? [Y/n]
   ```
3. Create config file with entered keys
4. Inform user: "Config saved. Future runs will use stored keys."

### Environment Variables (Fallback)

If you prefer environment variables over config file:

| Variable | Purpose |
|----------|---------|
| `GEMINI_API_KEY` | Gemini CLI authentication |
| `OPENAI_API_KEY` | OpenAI Codex authentication |
| `ANTHROPIC_API_KEY` | Claude CLI authentication |
| `PERPLEXITY_API_KEY` | Perplexity CLI authentication |

```bash
# Add to ~/.bashrc or ~/.zshrc
export GEMINI_API_KEY="your-key-here"
export OPENAI_API_KEY="your-key-here"
export ANTHROPIC_API_KEY="your-key-here"
export PERPLEXITY_API_KEY="your-key-here"
```

### Security Notes

- Config file is stored in user's `.claude/` directory (not in project)
- Never commit API keys to git
- The `conclave.yaml` should be in `.gitignore` by default
- Keys in config file take precedence over environment variables

---

## Provider-Specific Flags

### Gemini CLI

| Flag | Mapped From | Effect |
|------|-------------|--------|
| `-p "<prompt>"` | (default) | One-off prompt execution |
| `--yolo` / `-y` | `--auto` | Auto-approve all operations |
| `--output-format json` | `--quiet` | Structured JSON output |
| `--output-format text` | (default) | Plain text output |
| `-m <model>` | `--model` | Specify model |

**Gemini Command Template:**
```bash
# Pipe file content via stdin and use positional prompt arg
cat file.md | gemini -m gemini-2.5-pro "Analyze this code" [--output-format json]

# Or for simple prompts without file content
gemini -m gemini-2.5-pro "Your prompt here"
```

> **⚠️ Important Notes:**
> - Always specify model: `-m gemini-2.5-pro` (recommended) or `-m gemini-2.5-flash` (faster)
> - Use stdin piping for file content: `cat file.md | gemini -m gemini-2.5-pro "prompt"`
> - The `-p` flag is deprecated - use positional argument for prompts
> - DO NOT use `@file.md` syntax - it requires GCP auth (`GOOGLE_CLOUD_PROJECT` env var)

### OpenAI Codex CLI

**Authentication Modes:**

| Auth Method | Command | Default Model | Billing |
|-------------|---------|---------------|---------|
| **ChatGPT Login** | `codex login --device-auth` | `gpt-5.2` | Subscription |
| **API Key** | `codex login --with-api-key` | `gpt-4o` | Pay per token |

> **Recommended:** Use ChatGPT login for subscription-based access. API key mode doesn't support `gpt-5.x-codex` models.

**Available Models (ChatGPT Login):**

| Model | Capability |
|-------|------------|
| `gpt-5.2` | Latest frontier - best knowledge, reasoning, coding |
| `gpt-5.1-codex-max` | Default - flagship for deep/fast reasoning |
| `gpt-5.1-codex` | Optimized for codex |
| `gpt-5.1-codex-mini` | Cheaper, faster, less capable |
| `gpt-5.1` | Broad world knowledge, general reasoning |

| Flag | Mapped From | Effect |
|------|-------------|--------|
| `--full-auto` | `--auto` | Autonomous sandboxed execution |
| `--json` | `--quiet` | JSONL output for parsing |
| `-m <model>` | `--model` | Specify model |
| `codex exec` | (CI mode) | Non-interactive runs |
| `-s read-only` | (default) | Read-only sandbox |

**Codex Command Template:**
```bash
codex exec "<prompt>" [--full-auto] [--json] [-m <model>] --skip-git-repo-check
```

### Perplexity CLI

**Authentication:**

| Auth Method | Setup | Notes |
|-------------|-------|-------|
| **Environment Variable** | `export PERPLEXITY_API_KEY="key"` | Standard approach |
| **Config File** | Add to `~/.claude/conclave.yaml` | Preferred for persistence |

> Get your API key at [perplexity.ai/settings/api](https://www.perplexity.ai/settings/api)

**Available Models:**

| Model | Use Case |
|-------|----------|
| `sonar` | Fast, cost-effective for quick facts |
| `sonar-pro` | Complex queries, more citations (default) |
| `sonar-reasoning` | Multi-step problem solving |
| `sonar-reasoning-pro` | Deep reasoning (DeepSeek-R1 based) |

| Flag | Mapped From | Effect |
|------|-------------|--------|
| `-m <model>` | `--model` | Specify model |
| `--no-citations` | (n/a) | Disable citation output |
| `--json` | `--quiet` | Output raw JSON response |
| `-s <prompt>` | (n/a) | System prompt |

**Perplexity Command Template:**
```bash
# Direct question with citations
perplexity "What are the latest React 19 breaking changes?"

# Pipe content and analyze
cat code.py | perplexity -m sonar-pro "Review this code for security issues"

# Use reasoning model for complex analysis
perplexity -m sonar-reasoning "Explain the tradeoffs of microservices vs monolith"
```

**Unique Capability:** Every response includes web citations. Use Perplexity when you need:
- Current information (not in Claude/Gemini training data)
- Verification with sources
- Research questions requiring web search
- Fact-checking claims with citations

### Claude Code CLI

**Authentication:**

| Auth Method | Setup | Notes |
|-------------|-------|-------|
| **Claude Code Login** | `claude` (interactive first use) | Uses existing login |
| **API Key** | `export ANTHROPIC_API_KEY="key"` | Direct API access |

> Claude CLI uses your existing Claude Code authentication. If not logged in, it will prompt on first use.

**Available Models:**

| Model | Capability |
|-------|------------|
| `sonnet` | Best balance of speed and capability (default) |
| `opus` | Most capable - complex reasoning, nuanced analysis |
| `haiku` | Fastest - quick analysis, simple tasks |

| Flag | Mapped From | Effect |
|------|-------------|--------|
| `-p` / `--print` | (required) | Headless mode - print and exit |
| `--output-format json` | `--quiet` | JSON output for parsing |
| `--output-format text` | (default) | Plain text output |
| `--model <model>` | `--model` | Specify model (sonnet/opus/haiku) |
| `--dangerously-skip-permissions` | `--auto` | Bypass permission checks (sandbox only) |
| `--system-prompt <prompt>` | (n/a) | Custom system prompt |

**Claude CLI Command Template:**
```bash
# Basic headless query
claude -p "Analyze this code for security issues" --output-format json

# With specific model
claude -p --model opus "Review this architecture decision"

# Pipe content and analyze
cat src/auth.ts | claude -p "Review this authentication code"

# With custom system prompt
claude -p --system-prompt "You are a security auditor" "Check for vulnerabilities"
```

**Unique Capability:** Claude Code CLI has full access to Claude's coding expertise in headless mode. Use when you need:
- Code review with Claude's understanding of best practices
- Security analysis with nuanced reasoning
- A different perspective from Gemini/OpenAI on the same problem
- Fast iteration with `haiku` for simple checks

---

## Consensus Mode (--all)

The `--all` flag dispatches tasks to multiple LLMs and has **Claude arbitrate** the results.

```
/conclave --all "<query>"
    │
    ├─→ Step 1: Dispatch (parallel)
    │     ├─ Gemini: detailed analysis request
    │     ├─ Codex:  detailed analysis request
    │     └─ Claude: detailed analysis request
    │
    ├─→ Step 2: Collect Raw Responses
    │     ├─ Gemini returns: analysis, evidence, reasoning
    │     ├─ Codex returns:  analysis, evidence, reasoning
    │     └─ Claude returns: analysis, evidence, reasoning
    │
    └─→ Step 3: Synthesize & Arbitrate
          ├─ Parse all full responses
          ├─ Identify agreements & disagreements
          ├─ Evaluate reasoning quality
          ├─ Weigh evidence strength
          └─ Synthesize final verdict
```

### Claude's Arbitration Role

Claude doesn't just pattern-match YES/NO. Claude:

1. **Reads both full responses** - understands reasoning, not just conclusions
2. **Identifies agreements** - shared facts, common ground
3. **Identifies disagreements** - conflicting claims, different interpretations
4. **Evaluates argument quality** - which reasoning is more sound? more evidence-backed?
5. **Synthesizes a verdict** - may agree with one, take parts from both, or note uncertainty

### Expert Prompt Template

Request rich, detailed output from each model:

```markdown
Analyze the following and provide a detailed response:

<query>

Structure your response:
1. **Assessment** - Your conclusion/finding
2. **Evidence** - Specific facts, code references, documentation
3. **Reasoning** - How you reached this conclusion
4. **Confidence** - How certain (high/medium/low) and why
5. **Caveats** - What could change this assessment
```

### Conclave Output Format

```markdown
## Conclave Analysis: <query>

### Expert Responses

**Gemini's Analysis:**
<full response with assessment, evidence, reasoning>

**OpenAI's Analysis:**
<full response with assessment, evidence, reasoning>

**Claude's Analysis:**
<full response with assessment, evidence, reasoning>

---

### Synthesis

**Agreements:**
- All models concur that...
- Shared evidence: ...

**Disagreements:**
- Gemini argues: ... (because...)
- OpenAI argues: ... (because...)
- Claude argues: ... (because...)

**Evaluation of Reasoning:**
- Gemini's strength: ... / weakness: ...
- OpenAI's strength: ... / weakness: ...
- Claude's strength: ... / weakness: ...

---

### Verdict

<Synthesized conclusion drawing on strongest arguments from all models>

**Confidence:** HIGH / MEDIUM / LOW
**Primary basis:** <which reasoning was most convincing>
**Caveat:** <remaining uncertainty, if any>
```

### Usage Examples

```bash
# Security review with arbitration
/conclave --all "Is this authentication implementation secure?"

# Architecture decision
/conclave --all "Should we use microservices or monolith for this project?"

# Code quality assessment
/conclave --all . --quality "Evaluate the test coverage and error handling"

# Verify a claim with multiple perspectives
/conclave --all verify "All database queries are properly parameterized"
```

### When to Use Conclave

| Scenario | Use Conclave? |
|----------|---------------|
| High-stakes security review | ✅ Yes |
| Architecture decisions | ✅ Yes |
| Resolving ambiguous requirements | ✅ Yes |
| Routine code analysis | ❌ Single model sufficient |
| Simple questions | ❌ Overkill |

---

## Execution Protocol

### Step 1: Verify CLI Availability

```bash
# Check Gemini
which gemini || echo "Install: https://github.com/google-gemini/gemini-cli"

# Check OpenAI Codex
which codex || echo "Install: https://github.com/openai/codex"

# Check Perplexity (included in claude-mods toolkit)
which perplexity || echo "Install: Run tools/install-*.sh from claude-mods"
```

### Step 2: Parse Provider & Mode

| Input Pattern | Provider | Mode |
|---------------|----------|------|
| `/conclave .` | gemini | analyze |
| `/conclave openai .` | openai | analyze |
| `/conclave perplexity "..."` | perplexity | ask |
| `/conclave ask "..."` | gemini | ask |
| `/conclave codex ask "..."` | openai | ask |
| `/conclave pplx ask "..."` | perplexity | ask |
| `/conclave --all .` | configured | analyze |
| `/conclave verify "..."` | gemini | verify |

### Step 3: Construct Command

**Always add read-only instruction:**
> "IMPORTANT: This is a read-only analysis. Do not execute code or modify files."

**Map flags to provider-specific equivalents:**

| Generic Flag | Gemini | OpenAI Codex | Perplexity |
|--------------|--------|--------------|------------|
| `--auto` | `--yolo` | `--full-auto` | (n/a) |
| `--quiet` | `--output-format json` | `--json` | `--json` |
| `--thinking` | (n/a) | (use default `gpt-5.2`) | `-m sonar-reasoning-pro` |
| `--model X` | `-m X` | `-m X` | `-m X` |

> **Safety note:** Default mode is read-only analysis. `--auto` explicitly opts into tool execution - use with caution.

### Step 4: Execute

**Important:** Claude reads files using Read tool, then passes content via stdin.

```bash
# Gemini example: pipe content via stdin
cat src/main.ts | gemini -m gemini-2.5-pro "IMPORTANT: Read-only analysis. Analyze architecture and patterns."

# OpenAI example (ChatGPT subscription)
codex exec "Analyze @src/ - architecture and patterns. Read-only, no modifications." --skip-git-repo-check

# Perplexity example: web-grounded research
perplexity -m sonar-pro "What are the security best practices for JWT tokens in 2025?"
```

> **Notes:**
> - For Gemini: Use stdin piping with explicit model (`-m gemini-2.5-pro`)
> - For Codex: The `@` syntax works (Codex handles file references internally)
> - Claude should use Read tool to fetch file content for Gemini, pass via stdin

### Step 5: Distill Results

**Brief (~500 chars):** Executive summary only
**Default (~2000 chars):** Architecture, patterns, issues, recommendations
**Detailed (~5000 chars):** Full breakdown with file references

---

## Usage Examples

### Basic Analysis

```bash
# Analyze with Gemini (default)
/conclave src/

# Analyze with OpenAI Codex
/conclave openai src/

# Quick architecture overview
/conclave . --arch --brief
```

### Questions & Verification

```bash
# Ask a question (Gemini)
/conclave ask "How does the authentication flow work?"

# Ask with deep reasoning (OpenAI)
/conclave openai ask "What are the security implications of this design?" --thinking

# Ask with web-grounded research (Perplexity)
/conclave perplexity "What are the latest OWASP Top 10 vulnerabilities for 2025?"

# Verify a claim
/conclave verify "All database queries use parameterized statements"
```

### Research & Current Info (Perplexity)

```bash
# Get current information with sources
/conclave pplx "Is this npm package actively maintained?"

# Research best practices with citations
/conclave perplexity "What are the recommended JWT token expiration times in 2025?"

# Fact-check a claim
/conclave pplx "Does React 19 remove support for class components?"
```

### Autonomous Mode

```bash
# Let Gemini run without prompts
/conclave . --auto --security

# Full autonomous with OpenAI
/conclave openai . --auto --detailed
```

### Conclave (Multi-Model)

```bash
# Get consensus on architecture
/conclave --all . --arch

# Security verification with multiple opinions
/conclave --all verify "This code is safe from SQL injection"

# Compare complex analysis
/conclave --all ask "What's the biggest technical debt in this codebase?"
```

### Saving Output

```bash
# Save analysis to file
/conclave . --detailed --save analysis.md

# Save conclave results
/conclave --all . --security --save security-audit.md
```

---

## Error Handling

| Error | Action |
|-------|--------|
| CLI not found | Provide install instructions with links |
| API key missing (interactive) | Prompt for key, offer to save to config |
| API key missing (non-interactive) | Error with config setup instructions |
| Rate limited | Suggest waiting or reducing scope |
| Timeout | Suggest narrower target or `--brief` |
| Provider unavailable | Fall back to available provider |
| Config file invalid | Show YAML parse error, suggest fix |

### Missing API Key Flow

**Interactive Mode:**
```
Gemini API key not found.

Options:
  1. Enter key now (will save to ~/.claude/conclave.yaml)
  2. Set env: export GEMINI_API_KEY="your-key"
  3. Edit config: ~/.claude/conclave.yaml

Enter key (or 'skip' for OpenAI only): ___
```

**Non-Interactive Mode (--quiet, CI):**
```
ERROR: Gemini API key not found.

Configure in ~/.claude/conclave.yaml:
  api_keys:
    gemini: "your-key"

Or set: export GEMINI_API_KEY="your-key"
```

---

## Migration from /g-slave

The `/conclave` command is the successor to `/g-slave` with expanded capabilities:

| Old | New | Notes |
|-----|-----|-------|
| `/g-slave .` | `/conclave .` | Same behavior |
| `/g-slave ask "..."` | `/conclave ask "..."` | Same behavior |
| `/g-slave --raw` | `/conclave --raw` | Same behavior |
| (n/a) | `/conclave openai .` | NEW: OpenAI support |
| (n/a) | `/conclave --all .` | NEW: Multi-model consensus |
| (n/a) | `/conclave --thinking` | NEW: Extended reasoning |

---

## Remember

1. **Claude commands, LLMs execute.** You conclave heavy lifting, receive distilled intel.
2. **Read-only always.** Never let conclaves modify files (unless explicitly autonomous).
3. **Default to strongest.** Use best available model unless user specifies otherwise.
4. **Distill by default.** Only pass raw output when requested.
5. **Conclave for confidence.** When stakes are high, get multiple opinions.

---

## Sources

- [Gemini CLI Headless Mode](https://geminicli.com/docs/cli/headless/)
- [Gemini CLI GitHub](https://github.com/google-gemini/gemini-cli)
- [OpenAI Codex CLI Reference](https://developers.openai.com/codex/cli/reference)
- [OpenAI Codex GitHub](https://github.com/openai/codex)
- [Perplexity API Docs](https://docs.perplexity.ai/)
- [Perplexity Model Cards](https://docs.perplexity.ai/guides/model-cards)
