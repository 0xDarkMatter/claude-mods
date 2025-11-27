---
description: Generate Claude Code expert agent prompts for any technology platform
---

# Agent Genesis - Expert Agent Prompt Generator

Generate high-quality, comprehensive expert agent prompts for Claude Code.

## Usage Modes

### Mode 1: Single Agent Generation
Generate one expert agent prompt for a specific technology platform.

**Prompt for:**
- Technology platform/framework name
- Scope (project-level or global/user-level)
- Focus areas (optional: specific features, patterns, use cases)
- Output format (markdown file or clipboard-ready text)

### Mode 2: Batch Agent Generation
Create multiple agent prompts from a list of technology platforms.

**Accept:**
- Multi-line list of technology platforms
- Scope (project-level or global/user-level)
- Common focus areas (optional)
- Output format (individual .md files or consolidated text)

### Mode 3: Architecture Analysis
Analyze a tech stack or architecture description and suggest relevant agents.

**Process:**
1. Read architecture description (from user input or file)
2. Identify all technology platforms/services
3. Ask for scope (project or global)
4. Present checkbox selector for agent creation
5. Generate selected agents

## Agent File Format

All agents MUST be created as Markdown files with **YAML frontmatter**:
- **Project-level**: `.claude/agents/` (current project only)
- **Global/User-level**: `~/.claude/agents/` or `C:\Users\[username]\.claude\agents\` (all projects)

**File Structure:**
```markdown
---
name: technology-name-expert
description: When this agent should be used. Can include examples and use cases. No strict length limit - be clear and specific. Include "use PROACTIVELY" for automatic invocation.
model: inherit
color: blue
---

[Agent system prompt content here]
```

**YAML Frontmatter Fields:**
- `name` (required): Unique identifier, lowercase-with-hyphens (e.g., "asus-router-expert")
- `description` (required): Clear, specific description of when to use this agent
  - No strict length limit - prioritize clarity over brevity
  - Can include examples, use cases, and context
  - Use "use PROACTIVELY" or "MUST BE USED" to encourage automatic invocation
  - Multi-line YAML string format is fine for lengthy descriptions
- `tools` (optional): Comma-separated list of allowed tools (e.g., "Read, Grep, Glob, Bash")
  - If omitted, agent inherits all tools from main session
  - **Best practice**: Only grant tools necessary for the agent's purpose (improves security and focus)
- `model` (optional): Specify model ("sonnet", "opus", "haiku", or "inherit" to use main session model)
- `color` (optional): Visual identifier in UI ("blue", "green", "purple", etc.)

**File Creation:**
Agents can be created programmatically using the Write tool:
```
Project-level: .claude/agents/[platform]-expert.md
Global/User-level: ~/.claude/agents/[platform]-expert.md (or C:\Users\[username]\.claude\agents\ on Windows)
```

**Choosing Scope:**
- **Project Agent** (`.claude/agents/`): Specific to the current project, can be version controlled and shared with team
- **Global Agent** (`~/.claude/agents/`): Available across all projects on your machine

After creation, the agent is immediately available for use with the Task tool.

## Claude Code Agent Documentation

**Essential Reading:**
- **Subagents Overview**: https://docs.claude.com/en/docs/claude-code/sub-agents
- **Subagents in SDK**: https://docs.claude.com/en/api/agent-sdk/subagents
- **Agent SDK Overview**: https://docs.claude.com/en/api/agent-sdk/overview
- **Agent Skills Guide**: https://docs.claude.com/en/docs/claude-code/skills
- **Agent Skills in SDK**: https://docs.claude.com/en/api/agent-sdk/skills
- **Skill Authoring Best Practices**: https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices
- **Using Agent Skills with API**: https://docs.claude.com/en/api/skills-guide
- **Agent Skills Quickstart**: https://docs.claude.com/en/docs/agents-and-tools/agent-skills/quickstart
- **Claude Code Settings**: https://docs.claude.com/en/docs/claude-code/settings
- **Common Workflows**: https://docs.claude.com/en/docs/claude-code/common-workflows
- **Claude Code Overview**: https://docs.claude.com/en/docs/claude-code/overview
- **Plugins Reference**: https://docs.claude.com/en/docs/claude-code/plugins-reference

**Key Concepts from Documentation:**
- Subagents operate in separate context windows with customized system prompts
- Each subagent can have restricted tool access for focused capabilities
- Multiple subagents can run concurrently for parallel processing
- User-level agents (`~/.claude/agents/`) are available across all projects
- Project-level agents (`.claude/agents/`) are project-specific and shareable
- Use `/agents` command for the recommended UI to manage agents
- Start with Claude-generated agents, then customize for best results
- Version control project-level subagents for team collaboration

## Generation Requirements

For each agent, create a comprehensive expert prompt with:

**Agent Content Structure:**
```markdown
# [Technology Platform] Expert Agent

**Purpose**: [1-2 sentence description]

**Core Capabilities**:
- [Key capability 1]
- [Key capability 2]
- [Key capability 3]

**Official Documentation & Resources**:
- [Official Docs URL]
- [Best Practices URL]
- [Architecture Patterns URL]
- [API Reference URL]
- [GitHub/Examples URL]
- [Community Resources URL]
- [Blog/Articles URL]
- [Video Tutorials URL]
- [Troubleshooting Guide URL]
- [Migration Guide URL]
- [Minimum 10 authoritative URLs]

**Expertise Areas**:
- [Specific feature/pattern 1]
- [Specific feature/pattern 2]
- [Specific feature/pattern 3]

**When to Use This Agent**:
- [Scenario 1]
- [Scenario 2]
- [Scenario 3]

**Integration Points**:
- [How this tech integrates with common tools/platforms]

**Common Patterns**:
- [Pattern 1 with canonical reference]
- [Pattern 2 with canonical reference]

**Anti-Patterns to Avoid**:
- [What NOT to do]

---

*Refer to canonical resources for code samples and detailed implementations.*
```

**Requirements:**
- YAML frontmatter at top with required fields (name, description)
- Concise, actionable system prompt (not verbose)
- Minimum 10 official/authoritative URLs
- No code samples in prompt (agent will generate as needed)
- Focus on patterns, best practices, architecture
- Include canonical references for expansion
- Markdown formatted for direct use
- Description field can be lengthy with examples if needed for clarity

## Output Options

**Ask user to choose scope:**
1. **Project Agent** - Save to `.claude/agents/` (project-specific, version controlled)
2. **Global Agent** - Save to `~/.claude/agents/` or `C:\Users\[username]\.claude\agents\` (all projects)

**Ask user to choose format:**
1. **Clipboard-ready** - Output complete markdown (with YAML frontmatter) in code block
2. **File creation** - Use Write tool to save to appropriate agents directory based on scope
3. **Both** - Create file using Write tool AND show complete content in chat for review

**File Creation Process:**
When creating files programmatically:
1. Generate complete agent content with YAML frontmatter
2. Determine path based on scope selection:
   - Project: `.claude/agents/[platform-name]-expert.md`
   - Global: `~/.claude/agents/[platform-name]-expert.md` (or Windows equivalent)
3. Use Write tool with appropriate path
4. Verify file was created successfully
5. Agent is immediately available for use

## Examples

### Example 1: Single Agent
```
User: /agent-genesis
Agent: [Shows multi-tab AskUserQuestion with 5 tabs]
  Tab 1 (Mode): Single Agent / Batch Generation / Architecture Analysis
  Tab 2 (Scope): Project Agent / Global Agent
  Tab 3 (Output): Create File / Show in Chat / Both
  Tab 4 (Platform): Custom Platform / [or popular options]
  Tab 5 (Focus): [Multi-select] General Coverage / Caching Patterns / Pub/Sub / etc.
User: [Selects all answers and submits once]
  Mode: Single Agent
  Scope: Global Agent
  Output: Both
  Platform: Redis (via Other field)
  Focus: General Coverage, Caching Patterns, Pub/Sub
Agent: [Generates Redis expert prompt and saves to ~/.claude/agents/redis-expert.md]
```

### Example 2: Batch Generation
```
User: /agent-genesis
Agent: [Shows multi-tab AskUserQuestion with 3 tabs]
  Tab 1 (Mode): Single Agent / Batch Generation / Architecture Analysis
  Tab 2 (Scope): Project Agent / Global Agent
  Tab 3 (Output): Create Files / Show in Chat / Both
User: [Submits]
  Mode: Batch Generation
  Scope: Project Agent
  Output: Create Files
Agent: Please provide platforms (one per line):
User: PostgreSQL
Redis
RabbitMQ

Agent: [Creates 3 .md files in .claude/agents/ (project directory)]
```

### Example 3: Architecture Analysis
```
User: /agent-genesis
Agent: [Shows multi-tab AskUserQuestion with 3 tabs]
  Tab 1 (Mode): Single Agent / Batch Generation / Architecture Analysis
  Tab 2 (Scope): Project Agent / Global Agent
  Tab 3 (Output): Create Files / Show in Chat / Both
User: [Submits]
  Mode: Architecture Analysis
  Scope: Global Agent
  Output: Both
Agent: Describe your architecture or provide file path:
User: E-commerce platform: Next.js frontend, Node.js API, PostgreSQL, Redis cache, Stripe payments, AWS S3 storage, SendGrid emails
Agent: Found platforms: Next.js, Node.js, PostgreSQL, Redis, Stripe, AWS S3, SendGrid
[Shows multi-select AskUserQuestion]
User: [Selects: nextjs-expert, postgres-expert, redis-expert, stripe-expert]
Agent: [Generates 4 selected agents in ~/.claude/agents/]
```

## Implementation Steps

1. **Ask All Questions at Once** using a single multi-question AskUserQuestion call:
   - **Question 1** (header: "Mode"): Single Agent / Batch Generation / Architecture Analysis
   - **Question 2** (header: "Scope"): Project Agent (this project only) / Global Agent (all projects)
   - **Question 3** (header: "Output"): Create File / Show in Chat / Both

   For Single Mode, also ask in the same call:
   - **Question 4** (header: "Platform"): Offer "Custom Platform" option (user types in Other field)
   - **Question 5** (header: "Focus", multiSelect: true): General Coverage / [2-3 common focus areas for that tech]

2. **For Single Mode:**
   - If user selected "Custom Platform", prompt for the platform name in chat
   - Generate comprehensive prompt based on answers
   - Create file and/or display based on output preference

3. **For Batch Mode:**
   - Ask user to provide multi-line platform list in chat
   - For each platform:
     - Generate expert prompt
     - Save to `.claude/agents/[platform]-expert.md`
   - Report completion with file paths

4. **For Architecture Analysis:**
   - Ask user for architecture description in chat
   - Parse and identify technologies
   - Present checkbox selector using AskUserQuestion (multiSelect: true)
   - Generate selected agents
   - Save to files based on output preference

5. **Generate Each Agent Prompt:**
   - Research official docs (WebSearch or WebFetch)
   - Find 10+ authoritative URLs
   - Structure according to template above
   - Focus on patterns and best practices
   - Keep concise (500-800 words)
   - Markdown formatted

6. **Output:**
   - Determine file path based on Scope selection:
     - **Project Agent**: `.claude/agents/[platform]-expert.md`
     - **Global Agent**: `~/.claude/agents/[platform]-expert.md` (Unix/Mac) or `C:\Users\[username]\.claude\agents\[platform]-expert.md` (Windows)
   - If "Create File" or "Both": Use Write tool with appropriate path and complete YAML frontmatter + system prompt
   - If "Show in Chat" or "Both": Display complete markdown (including frontmatter) in code block
   - Confirm creation with full file path
   - Remind user agent is immediately available via Task tool

**Important**: Always use a single AskUserQuestion call with multiple questions (2-4) to create the multi-tab interface. Never ask questions sequentially one at a time.

## Quality Checklist

Before outputting each agent prompt, verify:
- ✅ YAML frontmatter present with required fields (name, description)
- ✅ Name uses lowercase-with-hyphens format
- ✅ Description is clear and specific (length is flexible)
- ✅ Tools field specified if restricting access (best practice: limit to necessary tools)
- ✅ 10+ authoritative URLs included in system prompt
- ✅ No code samples (agent generates as needed)
- ✅ Concise and scannable system prompt
- ✅ Clear use cases defined
- ✅ Integration points identified
- ✅ Common patterns referenced
- ✅ Anti-patterns listed
- ✅ Proper markdown formatting throughout
- ✅ Filename matches name field: `[name].md`
- ✅ Follows Claude Code subagent best practices (see documentation links above)

## Post-Generation

After creating agents, remind user:
1. Review generated prompts
2. Test agent with sample questions
3. Refine based on actual usage
4. Add to version control if satisfied
5. Consult Claude Code documentation links above for advanced features and best practices

**Additional Resources:**
- Use `/agents` command to view and manage all available agents
- Refer to https://docs.claude.com/en/docs/claude-code/sub-agents for detailed subagent documentation
- Check https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices for authoring guidelines

---

**Execute this command to generate expert agent prompts on demand!**
