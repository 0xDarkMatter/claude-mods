---
description: "Generate Claude Code ecosystem news digest. Fetches blogs, repos, and community sources via Firecrawl. Output to news/{date}_pulse.md."
---

# Pulse - Claude Code News Feed

Fetch and summarize the latest developments in the Claude Code ecosystem.

## What This Command Does

1. **Fetches** content from blogs, official repos, and community sources
2. **Deduplicates** against previously seen URLs (stored in `news/state.json`)
3. **Summarizes** each item with an engaging precis + relevance assessment
4. **Writes** digest to `news/{YYYY-MM-DD}_pulse.md`
5. **Updates** state to prevent duplicate entries in future runs

## Arguments

- `--force` - Regenerate digest even if today's already exists
- `--days N` - Look back N days instead of 1 (default: 1)
- `--dry-run` - Show sources that would be fetched without actually fetching

## Sources

### Official (Priority: Critical)

```json
[
  {"name": "Anthropic Engineering", "url": "https://www.anthropic.com/engineering", "type": "blog"},
  {"name": "Claude Blog", "url": "https://claude.com/blog", "type": "blog"},
  {"name": "Claude Code Docs", "url": "https://code.claude.com", "type": "docs"},
  {"name": "anthropics/claude-code", "url": "https://github.com/anthropics/claude-code", "type": "repo"},
  {"name": "anthropics/skills", "url": "https://github.com/anthropics/skills", "type": "repo"},
  {"name": "anthropics/claude-code-action", "url": "https://github.com/anthropics/claude-code-action", "type": "repo"},
  {"name": "anthropics/claude-agent-sdk-demos", "url": "https://github.com/anthropics/claude-agent-sdk-demos", "type": "repo"}
]
```

### Community Blogs (Priority: High)

```json
[
  {"name": "Simon Willison", "url": "https://simonwillison.net", "type": "blog"},
  {"name": "Every", "url": "https://every.to", "type": "blog"},
  {"name": "SSHH Blog", "url": "https://blog.sshh.io", "type": "blog"},
  {"name": "Lee Han Chung", "url": "https://leehanchung.github.io", "type": "blog"},
  {"name": "Nick Nisi", "url": "https://nicknisi.com", "type": "blog"},
  {"name": "HumanLayer", "url": "https://www.humanlayer.dev/blog", "type": "blog"},
  {"name": "Chris Dzombak", "url": "https://www.dzombak.com/blog", "type": "blog"},
  {"name": "GitButler", "url": "https://blog.gitbutler.com", "type": "blog"},
  {"name": "Docker Blog", "url": "https://www.docker.com/blog", "type": "blog"},
  {"name": "Nx Blog", "url": "https://nx.dev/blog", "type": "blog"},
  {"name": "Yee Fei Ooi", "url": "https://medium.com/@ooi_yee_fei", "type": "blog"}
]
```

### Community Indexes (Priority: Medium)

```json
[
  {"name": "Awesome Claude Skills", "url": "https://github.com/travisvn/awesome-claude-skills", "type": "repo"},
  {"name": "Awesome Claude Code", "url": "https://github.com/hesreallyhim/awesome-claude-code", "type": "repo"},
  {"name": "Awesome Claude", "url": "https://github.com/alvinunreal/awesome-claude", "type": "repo"},
  {"name": "SkillsMP", "url": "https://skillsmp.com", "type": "marketplace"},
  {"name": "Awesome Claude AI", "url": "https://awesomeclaude.ai", "type": "directory"}
]
```

### Tools (Priority: Medium)

```json
[
  {"name": "Worktree", "url": "https://github.com/agenttools/worktree", "type": "repo"}
]
```

### GitHub Search Queries (Priority: High)

Use `gh search repos` and `gh search code` for discovery:

```bash
# Repos with recent Claude Code activity (last 7 days)
gh search repos "claude code" --pushed=">$(date -d '7 days ago' +%Y-%m-%d)" --sort=updated --limit=10

# Hooks and skills hotspots
gh search repos "claude code hooks" --pushed=">$(date -d '7 days ago' +%Y-%m-%d)" --sort=updated
gh search repos "claude code skills" --pushed=">$(date -d '7 days ago' +%Y-%m-%d)" --sort=updated
gh search repos "CLAUDE.md agent" --pushed=">$(date -d '7 days ago' +%Y-%m-%d)" --sort=updated

# Topic-based discovery (often better signal)
gh search repos --topic=claude-code --sort=updated --limit=10
gh search repos --topic=model-context-protocol --sort=updated --limit=10

# Code search for specific patterns
gh search code "PreToolUse" --language=json --limit=5
gh search code "PostToolUse" --language=json --limit=5
```

### Reddit Search (Priority: Medium)

Use Firecrawl or web search for Reddit threads:

```
site:reddit.com/r/ClaudeAI "Claude Code" (hooks OR skills OR worktree OR tmux)
```

### Official Docs Search (Priority: High)

Check for documentation updates:

```
site:code.claude.com hooks
site:code.claude.com skills
site:code.claude.com github-actions
site:code.claude.com mcp
```

## Execution Steps

### Step 1: Check State

Read `pulse/state.json` to get:
- `last_run` timestamp
- `seen_urls` array for deduplication
- `seen_commits` object for repo tracking

If today's digest exists AND `--force` not specified:
```
Pulse digest already exists for today: news/{date}_pulse.md
Use --force to regenerate.
```

### Fetch Script

Run the parallel fetcher:
```bash
python pulse/fetch.py --sources all --max-workers 15 --output pulse/fetch_cache.json
```

### Step 2: Fetch Sources

**For Blogs** - Use Firecrawl to fetch and extract recent articles:

```bash
# Fetch blog content via firecrawl
firecrawl https://simonwillison.net --format markdown
```

Look for articles with dates in the last N days (default 1).

**For GitHub Repos** - Use `gh` CLI:

```bash
# Get latest release
gh api repos/anthropics/claude-code/releases/latest --jq '.tag_name, .published_at, .body'

# Get recent commits
gh api repos/anthropics/claude-code/commits --jq '.[:5] | .[] | {sha: .sha[:7], message: .commit.message, date: .commit.author.date}'

# Get recent discussions (if enabled)
gh api repos/anthropics/claude-code/discussions --jq '.[:3]'
```

**For Marketplaces/Directories** - Use Firecrawl:

```bash
firecrawl https://skillsmp.com --format markdown
firecrawl https://awesomeclaude.ai --format markdown
```

### Step 3: Filter & Deduplicate

For each item found:
1. Check if URL is in `seen_urls` - skip if yes
2. Check if date is within lookback window - skip if older
3. For repos, check if commit SHA matches `seen_commits[repo]` - skip if same

### Step 4: Generate Summaries

For each new item, generate:

**Precis** (2-3 sentences):
> Engaging summary that captures the key points and why someone would want to read this.

**Relevance** (1 sentence):
> How this specifically relates to or could improve our claude-mods project.

Use this prompt pattern for each item:
```
Article: [title]
URL: [url]
Content: [extracted content]

Generate:
1. A 2-3 sentence engaging summary (precis)
2. A 1-sentence assessment of relevance to "claude-mods" (a collection of Claude Code extensions including agents, skills, and commands)

Format:
PRECIS: [summary]
RELEVANCE: [assessment]
```

### Step 5: Write Digest

**IMPORTANT**: Read `pulse/BRAND_VOICE.md` before writing. Follow the voice guidelines.

Create `news/{YYYY-MM-DD}_pulse.md` with format:

```markdown
# Pulse · {date in words}

{Opening paragraph: Set the scene. What's the throughline this week? What should readers care about? Write conversationally, as if explaining to a smart friend.}

---

## The Signal

{1-3 most important/newsworthy items. These get:}
- 2-paragraph summaries (150-200 words)
- Extended "Pulse insights:" (2-3 sentences)
- Source name linked to parent site

### [{title}]({url})

**[{source_name}]({source_parent_url})** · {date}

{Paragraph 1: Hook + context. Start with something interesting—a question, surprising fact, or reframing.}

{Paragraph 2: Substance + implications. What's actually in it and why it matters beyond the obvious.}

**Pulse insights:** {Opinionated take on relevance to Claude Code practitioners. Be direct, take a stance.}

---

## Official Updates

{Other items from Anthropic sources}

### [{title}]({url})

**[{source_name}]({source_parent_url})** · {date}

{1 paragraph summary (60-100 words). Hook + substance + implication in flowing narrative.}

**Pulse insights:** {1-2 sentences. Practical, specific.}

---

## GitHub Discoveries

{New repos from topic/keyword searches}

### [{repo_name}]({url})

**{author}** · {one-line description}

{1 paragraph on what it does and why it's interesting.}

**Pulse insights:** {1-2 sentences.}

---

## Community Radar

{Notable community sources, blogs, discussions}

### [{source_name}]({url}) — {pithy tagline}

{2-3 sentences on what makes this source valuable.}

---

## Quick Hits

- **[{title}]({url})**: {one-line description}
- ...

---

## The Hit List

1. **{Action}** — {Why}
2. ...

---

*{Randomised footer from BRAND_VOICE.md} · {date in words} · {suffix}*
```

### Step 6: Update State

Update `pulse/state.json`:

```json
{
  "version": "1.0",
  "last_run": "{ISO timestamp}",
  "seen_urls": [
    "...existing...",
    "...new urls from this run..."
  ],
  "seen_commits": {
    "anthropics/claude-code": "{latest_sha}",
    "anthropics/skills": "{latest_sha}",
    ...
  }
}
```

Keep only last 30 days of URLs to prevent unbounded growth.

### Step 7: Display Summary

```
Pulse: 2025-12-12

Fetched 23 sources
Found 8 new items (15 deduplicated)

Critical:
  - anthropics/claude-code v1.2.0 released

Digest written to: news/2025-12-12_pulse.md
```

## Fetching Strategy

**Priority Order**:
1. Try `WebFetch` first (fastest, built-in)
2. If 403/blocked/JS-heavy, use Firecrawl
3. For GitHub repos, always use `gh` CLI

**Parallel Fetching**:
- Fetch multiple sources simultaneously
- Use retry with exponential backoff (2s, 4s, 8s, 16s)
- Report progress: `[====------] 12/23 sources`

**Error Handling**:
- If source fails after 4 retries, log and continue
- Include failed sources in digest footer
- Don't fail entire run for single source failure

## Output Example

See `news/2025-12-12_pulse.md` for a complete example in the current format.

Key elements:
- Opening 2 paragraphs set the scene conversationally (see BRAND_VOICE.md)
- "The Signal" section gets 2 paragraphs + extended insights
- All source names link to parent sites
- "Pulse insights:" replaces "Why it matters"
- "The Hit List" for actionable items (not homework—marching orders)
- Randomised footer from BRAND_VOICE.md variations

## Edge Cases

### No New Items
```
Pulse: 2025-12-12

Fetched 23 sources
No new items found (all 12 items already seen)

Last digest: news/2025-12-11_pulse.md
```

### Source Failures
```
Pulse: 2025-12-12

Fetched 23 sources (2 failed)
Found 6 new items

Failed sources:
  - skillsmp.com (timeout after 4 retries)
  - every.to (403 Forbidden)

Digest written to: news/2025-12-12_pulse.md
```

### First Run (No State)
Initialize state.json with empty arrays/objects before proceeding.

## Integration

The `/pulse` command is standalone but integrates with:
- **claude-architect agent** - Reviews digests for actionable insights (configured in agent's startup)
- **news/state.json** - Persistent deduplication state
- **Firecrawl** - Primary fetching mechanism for blocked/JS sites
- **gh CLI** - GitHub API access for repo updates

## Notes

- Run manually when you want ecosystem updates: `Pulse`
- Use `--force` to regenerate today's digest with fresh data
- Use `--days 7` for weekly catchup after vacation
- Digests are git-trackable for historical reference
- **Always read `pulse/BRAND_VOICE.md`** before writing summaries
