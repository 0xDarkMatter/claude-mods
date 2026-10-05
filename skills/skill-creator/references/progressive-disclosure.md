# Progressive Disclosure

How skills load in stages, the size limits that follow from it, and three patterns for
splitting content out of SKILL.md. Read it in Step 4 when SKILL.md grows, or when a skill
covers several variants, frameworks or domains.

> Adapted from Anthropic's skill-creator (github.com/anthropics/skills, Apache-2.0, see
> `../LICENSE.txt`). Changed for claude-mods: moved out of SKILL.md; sizes stated in
> tokens per the Agent Skills spec, with Claude Code's compaction budget added.

## Contents

- Three loading levels
- Size limits
- Pattern 1: High-level guide with references
- Pattern 2: Domain-specific organization
- Pattern 3: Conditional details
- Guidelines

## Three loading levels

1. **Metadata (name + description)** - Always in context (~100 tokens)
2. **SKILL.md body** - When skill triggers (under 5,000 tokens)
3. **Bundled resources** - As needed by Claude (unlimited, because scripts can be executed without reading into context window)

## Size limits

Keep the SKILL.md body to the essentials: **under 500 lines and under ~5,000 tokens**
(characters / 3.6 is a fair estimate). Both limits bind. After auto-compaction Claude
Code re-attaches only the first 5,000 tokens of each invoked skill (25,000 across all
skills), so anything past that point silently drops mid-session: put the procedure and
hard rules first. Split content into separate files when approaching either limit. When
splitting, reference each file from SKILL.md and say clearly when to read it, so the
reader of the skill knows it exists and when to use it.

Sources: agentskills.io/specification ("Progressive disclosure"),
code.claude.com/docs/en/skills, and Anthropic's skill authoring best practices.

**Key principle:** When a skill supports multiple variations, frameworks, or options, keep only the core workflow and selection guidance in SKILL.md. Move variant-specific details (patterns, examples, configuration) into separate reference files.

## Pattern 1: High-level guide with references

```markdown
# PDF Processing

## Quick start

Extract text with pdfplumber:
[code example]

## Advanced features

- **Form filling**: See [FORMS.md](FORMS.md) for complete guide
- **API reference**: See [REFERENCE.md](REFERENCE.md) for all methods
- **Examples**: See [EXAMPLES.md](EXAMPLES.md) for common patterns
```

Claude loads FORMS.md, REFERENCE.md, or EXAMPLES.md only when needed.

## Pattern 2: Domain-specific organization

For Skills with multiple domains, organize content by domain to avoid loading irrelevant context:

```
bigquery-skill/
├── SKILL.md (overview and navigation)
└── reference/
    ├── finance.md (revenue, billing metrics)
    ├── sales.md (opportunities, pipeline)
    ├── product.md (API usage, features)
    └── marketing.md (campaigns, attribution)
```

When a user asks about sales metrics, Claude only reads sales.md.

Similarly, for skills supporting multiple frameworks or variants, organize by variant:

```
cloud-deploy/
├── SKILL.md (workflow + provider selection)
└── references/
    ├── aws.md (AWS deployment patterns)
    ├── gcp.md (GCP deployment patterns)
    └── azure.md (Azure deployment patterns)
```

When the user chooses AWS, Claude only reads aws.md.

## Pattern 3: Conditional details

Show basic content, link to advanced content:

```markdown
# DOCX Processing

## Creating documents

Use docx-js for new documents. See [DOCX-JS.md](DOCX-JS.md).

## Editing documents

For simple edits, modify the XML directly.

**For tracked changes**: See [REDLINING.md](REDLINING.md)
**For OOXML details**: See [OOXML.md](OOXML.md)
```

Claude reads REDLINING.md or OOXML.md only when the user needs those features.

## Guidelines

- **Avoid deeply nested references** - Keep references one level deep from SKILL.md. All reference files should link directly from SKILL.md.
- **Structure longer reference files** - For files longer than 100 lines, include a table of contents at the top so Claude can see the full scope when previewing.
