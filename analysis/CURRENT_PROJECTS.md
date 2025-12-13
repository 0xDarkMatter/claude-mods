# Current Projects Overview

> Context file for claude-architect and Pulse. Last updated: 2025-12-13

## Active Development (Touch Weekly)

### Claude Code Ecosystem

| Project | Purpose | Stack |
|---------|---------|-------|
| **claude-mods** | Extension toolkit - 23 agents, 11 skills, 11 commands | Markdown, Python, Bash |
| **dev-shell-tools** | Modern CLI tools (ripgrep, fd, bat, eza) | Rust/Go binaries |
| **TerminalBench** | AI benchmark runner with 100+ domain skills | Python, Harbor, Docker |
| **expert-graph** | 590+ expert knowledge graph | Markdown, YAML |

### MCP Servers (Model Context Protocol)

| Project | Integration | Status |
|---------|-------------|--------|
| **AsanaMCP** | Asana project management | Active |
| **HarvestMCP** | Harvest time tracking | Active |
| **GmailMCP** | Gmail with AI summaries | Active |
| **Azimuth** | Raindrop.io bookmarks | Active |
| **DialpadMCP** | Dialpad phone system | In dev |
| **PandaMCP** | (Unknown) | In dev |

### Web Scraping & Content

| Project | Purpose | Stack |
|---------|---------|-------|
| **Firecrawl** | Python scraping suite with change detection | Python, Firecrawl API |
| **Roamcrawler** | SEO tools for destination marketing | Python, BeautifulSoup |
| **Praxis** | AI concierge prompt framework for Chatbase | Markdown, Python |

### Parental Safety Suite

| Project | Purpose | Stack |
|---------|---------|-------|
| **Vordr** | Windows monitoring + LLM domain triage | Python, Claude API |
| **Aegis** | AI-assisted blocklist curation tooling | Python, SQLite |
| **aegis-blocklist** | Child safety DNS blocklist (900+ domains) | Text, Batch |

---

## Tech Stack Summary

**Primary Languages:**
- Python (80% of active projects)
- JavaScript/TypeScript (web frontends, Workers)
- Markdown (agents, skills, prompts)

**Key APIs & Services:**
- Claude API (Anthropic)
- Firecrawl API
- NextDNS API
- Asana, Harvest, Gmail, Raindrop.io
- Cloudflare Workers

**Common Patterns:**
- MCP servers for tool integration
- SQLite for local state/caching
- Async Python (httpx, asyncio)
- Markdown-based agent definitions

---

## Domain Expertise Needed

Based on active projects, the most valuable expertise areas:

| Domain | Projects Using It |
|--------|-------------------|
| **Python async/httpx** | All MCP servers, Firecrawl, Vordr |
| **Claude API** | Vordr, Aegis, Praxis, claude-mods |
| **Web scraping** | Firecrawl, Roamcrawler, Vordr |
| **DNS/Networking** | Vordr, Aegis, aegis-blocklist |
| **SQLite** | GmailMCP, Aegis, Firecrawl |
| **Cloudflare Workers** | CFWorker, Elevenlabs-worker |
| **MCP Protocol** | 6 active MCP servers |

---

## TerminalBench Skills Relevance

TerminalBench has 100+ PhD-level domain skills. Most are **not relevant** to our common work:

### Irrelevant (Benchmark-specific)
- Bioinformatics (gibson-assembly, protein-folding, dna-*)
- Scientific computing (sympy, scipy, astropy)
- Game theory (chess, corewars)
- Cryptanalysis (feal, password-cracking)
- Low-level (mips, vm-emulation, gcc-optimization)

### Potentially Useful
| Skill | Relevance |
|-------|-----------|
| `pytorch-*` | If doing ML work |
| `django-*` | If building Django apps |
| `sqlite-expert` | Our MCP servers use SQLite |
| `nginx-expert` | Server configuration |
| `http-expert` | API debugging |
| `constraint-preservation` | Could adapt for our rules |

### Verdict
**Don't import TerminalBench skills.** They're tuned for benchmark tasks (DNA assembly, cryptanalysis, chess engines), not our actual work (MCP servers, web scraping, parental safety).

The skill routing system is overkill at our scale (23 agents vs 100+ skills).

---

## Recommendations for claude-architect

### When user mentions these projects, load context:

```
"Vordr" or "parental" or "monitoring" → Parental safety domain
"MCP" or "Asana" or "Harvest" or "Gmail" → MCP server patterns
"scraping" or "Firecrawl" or "crawl" → Web scraping tools
"blocklist" or "Aegis" or "NextDNS" → DNS filtering
"benchmark" or "TerminalBench" → Agent evaluation (separate domain)
```

### Priority expertise for common tasks:

1. **Python async** - Every active project uses it
2. **MCP protocol** - 6 servers and growing
3. **Claude API** - Core to Vordr, Aegis, Praxis
4. **SQLite** - State management across projects
5. **Web scraping** - Firecrawl patterns reused everywhere

### Don't prioritize:
- Heavy ML/PyTorch (no active ML projects)
- Scientific computing (no active science projects)
- Game development (ArchMagi is archived)
- PHP/Laravel (CraftCMS is archived)

---

## Project Health

| Status | Count | Examples |
|--------|-------|----------|
| **Active** | 15 | claude-mods, Vordr, MCP servers |
| **Maintenance** | 20 | CFWorker, DProbe, Asus |
| **Archived** | 25+ | ArchMagi, CraftCMS, Payload |

**Focus areas for 2025:**
1. Claude Code tooling (claude-mods, dev-shell-tools)
2. MCP server ecosystem
3. Parental safety suite (Vordr + Aegis)
4. AI concierge (Praxis)
