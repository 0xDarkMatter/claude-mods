# Pulse · {{DATE_WORDS}}

{{INTRO}}

---

## The Signal

{{#LEAD_STORIES}}
### [{{TITLE}}]({{URL}})

**[{{SOURCE_NAME}}]({{SOURCE_URL}})** · {{DATE}}

{{SUMMARY_P1}}

{{SUMMARY_P2}}

**Pulse insights:** {{INSIGHTS}}

---
{{/LEAD_STORIES}}

## Official Updates

{{#OFFICIAL}}
### [{{TITLE}}]({{URL}})

**[{{SOURCE_NAME}}]({{SOURCE_URL}})** · {{DATE}}

{{SUMMARY}}

**Pulse insights:** {{INSIGHTS}}

---
{{/OFFICIAL}}

## GitHub Discoveries

{{GITHUB_INTRO}}

{{#GITHUB_REPOS}}
### [{{REPO_NAME}}]({{URL}})

**{{AUTHOR}}** · {{ONE_LINER}}

{{DESCRIPTION}}

**Pulse insights:** {{INSIGHTS}}

---
{{/GITHUB_REPOS}}

## Community Radar

{{#COMMUNITY}}
### [{{ARTICLE_TITLE}}]({{ARTICLE_URL}})

**[{{SOURCE_NAME}}]({{SOURCE_URL}})** · {{DATE}}

{{SUMMARY}}

**Pulse insights:** {{INSIGHTS}}

---
{{/COMMUNITY}}

## Quick Hits

{{#QUICK_HITS}}
- **[{{TITLE}}]({{URL}})**: {{ONE_LINER}}
{{/QUICK_HITS}}

---

## The Hit List

{{#ACTION_ITEMS}}
{{INDEX}}. **{{ACTION}}** — {{REASON}}
{{/ACTION_ITEMS}}

---

*{{FOOTER}}*

---

## Template Variables Reference

### Global
- `{{DATE_WORDS}}` - e.g., "December 12, 2025"
- `{{DATE_ISO}}` - e.g., "2025-12-12"
- `{{SOURCE_COUNT}}` - Total sources fetched
- `{{INTRO}}` - Opening 2-paragraph hook (see BRAND_VOICE.md)
- `{{FOOTER}}` - Randomised sign-off (see BRAND_VOICE.md footer variations)

### The Signal (1-3 items)
- `{{TITLE}}` - Article/post title
- `{{URL}}` - Direct link to content
- `{{SOURCE_NAME}}` - e.g., "Anthropic Engineering"
- `{{SOURCE_URL}}` - Parent site URL
- `{{DATE}}` - Publication date
- `{{SUMMARY_P1}}` - First paragraph (hook + context)
- `{{SUMMARY_P2}}` - Second paragraph (substance + implications)
- `{{INSIGHTS}}` - 2-3 sentence Pulse insights

### Official Updates
Same as Lead Stories but with single `{{SUMMARY}}` paragraph.

### GitHub Discoveries
- `{{GITHUB_INTRO}}` - Brief intro to the section
- `{{REPO_NAME}}` - Repository name
- `{{AUTHOR}}` - GitHub username
- `{{ONE_LINER}}` - Brief description
- `{{DESCRIPTION}}` - 1 paragraph explanation
- `{{INSIGHTS}}` - 1-2 sentence insights

### Community Radar
- `{{ARTICLE_TITLE}}` - Specific article title (not just blog name)
- `{{ARTICLE_URL}}` - Direct article link
- `{{SOURCE_NAME}}` - Blog/publication name
- `{{SOURCE_URL}}` - Blog homepage
- `{{DATE}}` - Article date
- `{{SUMMARY}}` - 1 paragraph summary
- `{{INSIGHTS}}` - 1-2 sentence insights

### Quick Hits (4-6 items)
- `{{TITLE}}` - Item title
- `{{URL}}` - Link
- `{{ONE_LINER}}` - Pithy description (max 15 words)

### The Hit List (3-5 items)
- `{{INDEX}}` - Number (1, 2, 3...)
- `{{ACTION}}` - What to do
- `{{REASON}}` - Why it matters (brief)

---

## Section Guidelines

### Intro ({{INTRO}})
Two paragraphs. First hooks with a question or surprising observation. Second expands with "here's what we found" energy. Should feel like the opening of a really good newsletter—makes you want to keep reading. Be cheeky, be specific, avoid clichés.

### The Signal
Reserve for genuinely important items:
- Breaking news from Anthropic
- Major ecosystem shifts
- Tools/patterns that change how people work

### Community Radar
**Must include specific recent articles**, not just blog links. Each entry should be a piece of content published in the last 7 days, with its own summary and insights.

### Quick Hits
Rapid-fire items that don't need full treatment but are worth knowing. Good for:
- Minor updates
- Interesting repos without much to say
- Things to bookmark for later

### The Hit List
Formerly "Actionable Items." Should feel like marching orders, not homework. Frame as opportunities, not obligations.
