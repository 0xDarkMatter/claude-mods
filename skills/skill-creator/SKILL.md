---
name: skill-creator
description: Guide for creating effective skills. This skill should be used when users want to create a new skill (or update an existing skill) that extends Claude's capabilities with specialized knowledge, workflows, or tool integrations.
license: Complete terms in LICENSE.txt
metadata:
  author: claude-mods
---

# Skill Creator

Skills are modular, self-contained packages that extend Claude's capabilities by providing
specialized knowledge, workflows, and tools. Think of them as "onboarding guides" for specific
domains or tasks—they transform Claude from a general-purpose agent into a specialized agent
equipped with procedural knowledge that no model can fully possess. A skill provides
specialized workflows, tool integrations, domain expertise, and bundled resources (scripts,
references, assets) for complex and repetitive tasks.

The procedure comes first below; design detail lives in `references/` (see
[Reference files](#reference-files)).

## Skill Creation Process

Skill creation involves these steps:

1. Understand the skill with concrete examples
2. Plan reusable skill contents (scripts, references, assets)
3. Initialize the skill directory
4. Edit the skill (implement resources and write SKILL.md)
5. Package the skill (only when a distributable `.skill` file is needed)
6. Iterate based on real usage

Follow these steps in order, skipping only if there is a clear reason why they are not applicable.

### Step 1: Understanding the Skill with Concrete Examples

Skip this step only when the skill's usage patterns are already clearly understood. It remains valuable even when working with an existing skill.

To create an effective skill, clearly understand concrete examples of how the skill will be used. This understanding can come from either direct user examples or generated examples that are validated with user feedback.

For example, when building an image-editor skill, relevant questions include:

- "What functionality should the image-editor skill support? Editing, rotating, anything else?"
- "Can you give some examples of how this skill would be used?"
- "I can imagine users asking for things like 'Remove the red-eye from this image' or 'Rotate this image'. Are there other ways you imagine this skill being used?"
- "What would a user say that should trigger this skill?"

To avoid overwhelming users, avoid asking too many questions in a single message. Start with the most important questions and follow up as needed for better effectiveness.

Conclude this step when there is a clear sense of the functionality the skill should support.

### Step 2: Planning the Reusable Skill Contents

To turn concrete examples into an effective skill, analyze each example by:

1. Considering how to execute on the example from scratch
2. Identifying what scripts, references, and assets would be helpful when executing these workflows repeatedly

Examples:

- A `pdf-editor` skill ("Help me rotate this PDF"): rotating a PDF means re-writing the same code each time, so store a `scripts/rotate_pdf.py`.
- A `frontend-webapp-builder` skill ("Build me a todo app"): every webapp needs the same boilerplate, so store an `assets/hello-world/` template project.
- A `big-query` skill ("How many users have logged in today?"): every query re-discovers the table schemas, so store a `references/schema.md`.

To establish the skill's contents, analyze each concrete example to create a list of the reusable resources to include: scripts, references, and assets. What each kind is for, and what to leave out: [references/skill-anatomy.md](references/skill-anatomy.md).

### Step 3: Initializing the Skill

Skip this step if the skill already exists and only iteration or packaging is needed.

This copy of skill-creator bundles no scripts (Anthropic's upstream skill-creator has since dropped its `init_skill.py`). Create the skeleton by hand:

```bash
mkdir -p <skill-name>/scripts <skill-name>/references <skill-name>/assets
```

Then write `<skill-name>/SKILL.md`: frontmatter with `name` (matching the directory: lowercase letters, digits and hyphens, at most 64 characters) and `description`, then the body. Keep only the resource directories the skill uses, unless the host repository requires all three (some keep them with a `.gitkeep`).

### Step 4: Edit the Skill

When editing the (newly-generated or existing) skill, remember that the skill is being created for another instance of Claude to use. Include information that would be beneficial and non-obvious to Claude. Consider what procedural knowledge, domain-specific details, or reusable assets would help another Claude instance execute these tasks more effectively.

#### Learn Proven Design Patterns

Consult these helpful guides based on your skill's needs:

- **SKILL.md growing, or several variants/frameworks/domains**: See [references/progressive-disclosure.md](references/progressive-disclosure.md) for the size limits and splitting patterns
- **Multi-step processes**: See [references/workflows.md](references/workflows.md) for sequential workflows, conditional logic, and subagent delegation patterns
- **Specific output formats or quality standards**: See [references/output-patterns.md](references/output-patterns.md) for template and example patterns
- **Official examples**: Browse [Anthropic's skills repository](https://github.com/anthropics/skills/tree/main/skills) for production-ready examples

**Pro tips for complex tasks:**
- **Use subagents** - Append "use subagents" to requests needing heavy computation or parallel exploration
- **Keep context clean** - Offload individual subtasks to subagents to prevent context window pollution
- **Visualize complexity** - Ask Claude to draw ASCII diagrams of new protocols and codebases for better understanding

#### Start with Reusable Skill Contents

To begin implementation, start with the reusable resources identified above: `scripts/`, `references/`, and `assets/` files. Note that this step may require user input. For example, when implementing a `brand-guidelines` skill, the user may need to provide brand assets or templates to store in `assets/`, or documentation to store in `references/`.

Added scripts must be tested by actually running them to ensure there are no bugs and that the output matches what is expected. If there are many similar scripts, only a representative sample needs to be tested to ensure confidence that they all work while balancing time to completion.

#### Update SKILL.md

**Writing Guidelines:** Always use imperative/infinitive form.

##### Frontmatter

Write the YAML frontmatter with `name` and `description`:

- `name`: The skill name
- `description`: This is the primary triggering mechanism for your skill, and helps Claude understand when to use the skill.
  - Include both what the Skill does and specific triggers/contexts for when to use it.
  - Include all "when to use" information here - Not in the body. The body is only loaded after triggering, so "When to Use This Skill" sections in the body are not helpful to Claude.
  - Example description for a `docx` skill: "Comprehensive document creation, editing, and analysis with support for tracked changes, comments, formatting preservation, and text extraction. Use when Claude needs to work with professional documents (.docx files) for: (1) Creating new documents, (2) Modifying or editing content, (3) Working with tracked changes, (4) Adding comments, or any other document tasks"

Do not include any other fields in YAML frontmatter.

##### Body

Write instructions for using the skill and its bundled resources. Keep the body **under 500 lines and under ~5,000 tokens**: after auto-compaction Claude Code keeps only the first 5,000 tokens of an invoked skill, so put the procedure and hard rules first and move detail into references.

### Step 5: Packaging a Skill

Package only when the user needs a distributable `.skill` file (for example, to upload to claude.ai). Skills follow the [Agent Skills open standard](https://agentskills.io/specification) for portability across AI platforms. A `.skill` file is a zip archive of the skill folder with a `.skill` extension, named after the skill (e.g., `my-skill.skill`).

Validate before zipping:

- YAML frontmatter parses, with `name` and `description` present
- `name` matches the folder name; `description` is non-empty and at most 1,024 characters
- Only the six spec fields appear at the top level (`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`) - claude.ai uploads and the Skills API reject any other key, so strip extras from the packaged copy
- Every file SKILL.md references exists

The spec's reference validator checks the frontmatter: `skills-ref validate <path/to/skill-folder>` ([skills-ref](https://github.com/agentskills/agentskills/tree/main/skills-ref)). Anthropic's upstream skill-creator ships a `scripts/package_skill.py` that validates and zips in one step; this copy does not bundle it.

### Step 6: Iterate

After testing the skill, users may request improvements. Often this happens right after using the skill, with fresh context of how the skill performed.

**Iteration workflow:**

1. Use the skill on real tasks
2. Notice struggles or inefficiencies
3. Identify how SKILL.md or bundled resources should be updated
4. Implement changes and test again

## Core Principles

**Concise is key.** The context window is a public good. Skills share the context window with everything else Claude needs: system prompt, conversation history, other Skills' metadata, and the actual user request. **Default assumption: Claude is already very smart.** Only add context Claude doesn't already have. Challenge each piece of information: "Does Claude really need this explanation?" and "Does this paragraph justify its token cost?" Prefer concise examples over verbose explanations.

**Set appropriate degrees of freedom.** Match the level of specificity to the task's fragility and variability:

- **High freedom (text-based instructions)**: multiple approaches are valid, decisions depend on context, or heuristics guide the approach.
- **Medium freedom (pseudocode or scripts with parameters)**: a preferred pattern exists, some variation is acceptable, or configuration affects behavior.
- **Low freedom (specific scripts, few parameters)**: operations are fragile and error-prone, consistency is critical, or a specific sequence must be followed.

Think of Claude as exploring a path: a narrow bridge with cliffs needs specific guardrails (low freedom), while an open field allows many routes (high freedom).

## Reference files

| File | Read when |
|------|-----------|
| [references/skill-anatomy.md](references/skill-anatomy.md) | Planning contents (Step 2): the layout, what scripts, references and assets are each for, what not to include |
| [references/progressive-disclosure.md](references/progressive-disclosure.md) | SKILL.md nears 500 lines or ~5,000 tokens, or the skill covers several variants: loading levels, size limits, three splitting patterns |
| [references/workflows.md](references/workflows.md) | The skill encodes a multi-step process: sequential, conditional, parallel, subagent and checklist patterns |
| [references/output-patterns.md](references/output-patterns.md) | The skill must produce a specific format or quality bar: templates, examples, layered verbosity |

**Official resources:** [Agent Skills repository](https://github.com/anthropics/skills) ·
[Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices) ·
[Agent Skills specification](https://agentskills.io/specification) ·
[Claude Code skills](https://code.claude.com/docs/en/skills) ·
[Creating custom skills](https://support.claude.com/en/articles/12512198-creating-custom-skills) ·
[The Complete Guide to Building Skills for Claude (PDF)](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf)

Adapted from Anthropic's skill-creator (github.com/anthropics/skills, Apache-2.0, see
`LICENSE.txt`). Changed for claude-mods: procedure moved first and design detail moved to
references to fit the size budget; Steps 3 and 5 rewritten because no scripts are bundled;
Contents lists added to the longer references.
