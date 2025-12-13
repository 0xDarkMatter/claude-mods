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

Read `news/state.json` to get:
- `last_run` timestamp
- `seen_urls` array for deduplication
- `seen_commits` object for repo tracking

If today's digest exists AND `--force` not specified:
```
Pulse digest already exists for today: news/2025-12-12_pulse.md
Use --force to regenerate.
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

Create `news/{YYYY-MM-DD}_pulse.md` with format:

```markdown
# Pulse: {date}

> Claude Code ecosystem digest

**Generated**: {timestamp} | **Sources**: {count} | **New Items**: {count}

---

## Critical Updates

[Items from official Anthropic sources - releases, major announcements]

### [{title}]({url})
**Source**: {source_name} | **Type**: {release/post/commit}
> {precis}

**Why it matters**: {relevance}

---

## Official

[Other items from official sources]

---

## Community

[Items from community blogs and indexes]

---

## Stats

| Category | Items |
|----------|-------|
| Official releases | {n} |
| Blog posts | {n} |
| Repo updates | {n} |
| Community | {n} |

---

*Generated by `/pulse`*
```

### Step 6: Update State

Update `news/state.json`:

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

```markdown
# Pulse: 2025-12-12

> Claude Code ecosystem digest

**Generated**: 2025-12-12 08:00 UTC | **Sources**: 23 | **New Items**: 8

---

## Critical Updates

### [Claude Code 1.2.0 Released](https://github.com/anthropics/claude-code/releases/tag/v1.2.0)
**Source**: anthropics/claude-code | **Type**: Release
> New MCP server auto-discovery feature enables Claude to find and connect to local MCP servers without manual configuration. Also includes 40% faster tool execution and improved subagent context handling.

**Why it matters**: May require updates to our hook patterns; the MCP auto-discovery could simplify our tool-discovery skill.

---

## Official

### [Building Production Skills](https://claude.com/blog/production-skills)
**Source**: Claude Blog | **Type**: Post
> Comprehensive guide to designing skills that scale, including caching strategies, permission scoping, and testing patterns. Covers common pitfalls and performance optimization.

**Why it matters**: Validates our skill structure; consider adding the caching patterns to tool-discovery.

---

## Community

### [Multi-Agent Orchestration Patterns](https://blog.sshh.io/p/multi-agent-patterns)
**Source**: SSHH Blog | **Type**: Post
> Practical patterns for coordinating multiple Claude instances on complex tasks, including the "conductor" pattern and parallel execution strategies.

**Why it matters**: Could inform improvements to our firecrawl-expert parallel processing approach.

### [15 New Skills Added to Awesome Claude Skills](https://github.com/travisvn/awesome-claude-skills/commits/main)
**Source**: travisvn/awesome-claude-skills | **Type**: Commits
> Batch of community-contributed skills covering Docker, Kubernetes, and database management. Notable additions include a Postgres optimizer and K8s deployment helper.

**Why it matters**: Review for quality patterns; potential additions to our agent roster.

---

## Stats

| Category | Items |
|----------|-------|
| Official releases | 1 |
| Blog posts | 4 |
| Repo updates | 2 |
| Community | 1 |

---

*Generated by `/pulse`*
```

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

- Run manually when you want ecosystem updates: `/pulse`
- Use `--force` to regenerate today's digest with fresh data
- Use `--days 7` for weekly catchup after vacation
- Digests are git-trackable for historical reference
