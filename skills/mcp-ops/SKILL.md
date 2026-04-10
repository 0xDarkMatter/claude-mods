---
name: mcp-ops
description: "Model Context Protocol server development, tool design, resource handling, and transport configuration. Use for: mcp, model context protocol, mcp server, mcp tool, mcp resource, fastmcp, mcp transport, stdio, sse, streamable http, mcp inspector, tool handler, mcp prompt."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: claude-code-hooks, claude-code-debug, typescript-ops, python-fastapi-ops
---

# MCP Operations

Comprehensive patterns for building, testing, and deploying Model Context Protocol servers in Python and TypeScript.

## MCP Architecture Quick Reference

```
┌─────────────────────────────────────────────────────────┐
│                     MCP Host                            │
│  (Claude Desktop, Claude Code, Custom App)              │
│                                                         │
│  ┌───────────┐   ┌───────────┐   ┌───────────┐        │
│  │  Client A  │   │  Client B  │   │  Client C  │       │
│  └─────┬─────┘   └─────┬─────┘   └─────┬─────┘        │
└────────┼───────────────┼───────────────┼────────────────┘
         │               │               │
    ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
    │Transport│     │Transport│     │Transport│
    │ (stdio) │     │  (SSE)  │     │ (HTTP)  │
    └────┬────┘     └────┬────┘     └────┬────┘
         │               │               │
┌────────┴──┐     ┌──────┴────┐   ┌──────┴────┐
│  Server A  │     │  Server B  │   │  Server C  │
│            │     │            │   │            │
│ ┌────────┐ │     │ ┌────────┐ │   │ ┌────────┐ │
│ │ Tools  │ │     │ │Resources│ │   │ │Prompts │ │
│ └────────┘ │     │ └────────┘ │   │ └────────┘ │
│ ┌────────┐ │     │ ┌────────┐ │   │ ┌────────┐ │
│ │Resources│ │     │ │Prompts │ │   │ │ Tools  │ │
│ └────────┘ │     │ └────────┘ │   │ └────────┘ │
└────────────┘     └────────────┘   └────────────┘

Protocol: JSON-RPC 2.0 over chosen transport
Flow:     Client → request → Server → response → Client
```

## Server Type Decision Tree

```
What transport does your MCP server need?
│
├─ Local CLI tool / single-user desktop integration?
│  └─ stdio
│     - Simplest setup, no networking
│     - Claude Desktop, Claude Code native support
│     - Process lifecycle managed by host
│
├─ Web dashboard / browser-based client?
│  └─ SSE (Server-Sent Events)
│     - HTTP-based, works through firewalls
│     - Persistent connection for server→client events
│     - Good for development and internal tools
│
└─ Production API / multi-tenant / cloud deployment?
   └─ Streamable HTTP
      - HTTP POST for requests, SSE for streaming responses
      - Supports stateless and stateful modes
      - Full auth support, load balancer friendly
      - Recommended for production deployments
```

## Tool vs Resource vs Prompt Decision Tree

```
What does the LLM need to do?
│
├─ Perform an action or computation?
│  └─ TOOL
│     - Has side effects (API calls, file writes, DB mutations)
│     - Accepts structured input, returns results
│     - Examples: run_query, create_issue, send_email
│
├─ Read data or context?
│  └─ RESOURCE
│     - Read-only data retrieval
│     - Identified by URI (file://, db://, api://)
│     - Examples: config://app, schema://users, file://readme.md
│
└─ Guide the LLM's behavior or workflow?
   └─ PROMPT
      - Templated instructions with arguments
      - Suggests conversation starters or workflows
      - Examples: code_review(language, file), summarize(topic)
```

## Python SDK Quick Start

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("my-server")

@mcp.tool()
def search_docs(query: str) -> str:
    """Search documentation by keyword."""
    results = perform_search(query)
    return "\n".join(f"- {r.title}: {r.snippet}" for r in results)

@mcp.tool()
def create_ticket(title: str, body: str, priority: str = "medium") -> str:
    """Create a support ticket."""
    ticket = api.create(title=title, body=body, priority=priority)
    return f"Created ticket #{ticket.id}: {ticket.url}"

@mcp.resource("config://app")
def get_config() -> str:
    """Return current application configuration."""
    return json.dumps(load_config(), indent=2)

@mcp.resource("schema://db/{table}")
def get_table_schema(table: str) -> str:
    """Return the schema for a database table."""
    return json.dumps(get_schema(table), indent=2)

@mcp.prompt()
def code_review(language: str, filepath: str) -> str:
    """Generate a code review prompt for the given file."""
    return f"Review this {language} code in {filepath} for bugs, style issues, and performance."

if __name__ == "__main__":
    mcp.run()  # Defaults to stdio transport
```

**Install and run:**

```bash
uv init my-mcp-server && cd my-mcp-server
uv add mcp[cli]
# Run with: uv run python server.py
# Or:       uv run mcp run server.py
```

## TypeScript SDK Quick Start

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({
  name: "my-server",
  version: "1.0.0",
});

// Register a tool
server.tool(
  "search_docs",
  "Search documentation by keyword",
  { query: z.string().describe("Search query") },
  async ({ query }) => {
    const results = await performSearch(query);
    return {
      content: [{ type: "text", text: results.join("\n") }],
    };
  }
);

// Register a resource
server.resource(
  "config",
  "config://app",
  { description: "Current application configuration" },
  async (uri) => ({
    contents: [{
      uri: uri.href,
      mimeType: "application/json",
      text: JSON.stringify(loadConfig(), null, 2),
    }],
  })
);

// Register a prompt
server.prompt(
  "code_review",
  "Generate a code review prompt",
  { language: z.string(), filepath: z.string() },
  async ({ language, filepath }) => ({
    messages: [{
      role: "user",
      content: {
        type: "text",
        text: `Review this ${language} code in ${filepath} for bugs and style issues.`,
      },
    }],
  })
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
main().catch(console.error);
```

**Install and run:**

```bash
npm init -y
npm install @modelcontextprotocol/sdk zod
npx tsx server.ts
```

## Transport Selection Matrix

| Feature | stdio | SSE | Streamable HTTP |
|---------|-------|-----|-----------------|
| **Use case** | Local CLI tools, desktop | Web dashboards, dev | Production APIs |
| **Protocol** | stdin/stdout pipes | HTTP + EventSource | HTTP POST + SSE |
| **Auth support** | Env vars only | Bearer tokens | Full OAuth2/PKCE |
| **Deployment** | Local process | Single server | Load balanced |
| **Reconnection** | Process restart | Auto-reconnect | Stateless resilient |
| **Multi-client** | 1:1 only | Multiple clients | Horizontally scalable |
| **Firewall** | N/A (local) | HTTP-friendly | HTTP-friendly |
| **State** | Process lifetime | Connection lifetime | Session or stateless |
| **Best for** | Claude Desktop/Code | Internal tools | Cloud/enterprise |

## Authentication Patterns Quick Reference

```python
# Pattern 1: API keys from environment
import os
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("api-server")

@mcp.tool()
def call_api(endpoint: str) -> str:
    """Call external API with configured credentials."""
    api_key = os.environ["MY_API_KEY"]  # Set in client config
    resp = httpx.get(f"https://api.example.com/{endpoint}",
                     headers={"Authorization": f"Bearer {api_key}"})
    return resp.text
```

```python
# Pattern 2: OAuth2 token refresh (in-memory cache)
import time

_token_cache: dict = {}

async def get_valid_token() -> str:
    if _token_cache.get("expires_at", 0) > time.time() + 60:
        return _token_cache["access_token"]
    resp = await httpx.AsyncClient().post("https://auth.example.com/token", data={
        "grant_type": "refresh_token",
        "refresh_token": os.environ["REFRESH_TOKEN"],
        "client_id": os.environ["CLIENT_ID"],
    })
    data = resp.json()
    _token_cache.update({
        "access_token": data["access_token"],
        "expires_at": time.time() + data["expires_in"],
    })
    return data["access_token"]
```

```json
// Claude Desktop config with env vars
{
  "mcpServers": {
    "my-server": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/server", "python", "server.py"],
      "env": {
        "MY_API_KEY": "sk-...",
        "DATABASE_URL": "postgresql://..."
      }
    }
  }
}
```

## Common Gotchas

| Gotcha | Why | Fix |
|--------|-----|-----|
| Tool not appearing in client | `inputSchema` has invalid JSON Schema | Validate schema with jsonschema library; use Pydantic/Zod to generate |
| Tool returns raw object | Results must be `content` list with typed items | Always return `{"content": [{"type": "text", "text": "..."}]}` |
| Timeout on long operations | Default client timeout is often 30-60s | Add progress notifications; break into smaller operations |
| Concurrent requests fail | Tool handler uses shared mutable state | Use asyncio locks, or make handlers stateless |
| Large response crashes client | MCP messages have practical size limits | Paginate results; return summaries with detail-fetch tools |
| Error swallowed silently | Exception in handler returns generic error | Set `isError: true` in response; include error message in content |
| SSE connection drops | No keep-alive or reconnection logic | Implement heartbeat; client auto-reconnects on SSE |
| Client ignores new tools | Capabilities not updated after tool change | Call `server.request_context.session.send_resource_list_changed()` |
| Tool name collision | Two servers register same tool name | Namespace tools: `myserver_search` not just `search` |
| Resource URI too generic | `data://info` is ambiguous | Use specific schemes: `db://myapp/users`, `config://myapp/settings` |
| `async def` missing on handler | FastMCP tools can be sync or async, but I/O should be async | Use `async def` for any handler doing network/file I/O |
| Server works locally, fails in Claude Desktop | Different working directory or PATH | Use absolute paths; log `os.getcwd()` on startup |

## Reference Files

| File | Lines | Content |
|------|-------|---------|
| `references/server-architecture.md` | ~700 | Server lifecycle, FastMCP/TS SDK setup, capabilities, middleware, error handling |
| `references/tool-handlers.md` | ~650 | Schema design, validation, return types, composition, side effects, examples |
| `references/resources-prompts.md` | ~550 | Resource URIs, static/dynamic resources, templates, prompts, subscriptions |
| `references/transport-auth.md` | ~550 | stdio/SSE/HTTP transports, session management, OAuth2, rate limiting, TLS |
| `references/testing-debugging.md` | ~550 | MCP Inspector, unit/integration testing, protocol debugging, CI, performance |

## See Also

- **MCP Specification**: https://spec.modelcontextprotocol.io
- **Python SDK**: https://github.com/modelcontextprotocol/python-sdk
- **TypeScript SDK**: https://github.com/modelcontextprotocol/typescript-sdk
- **Official MCP Servers**: https://github.com/modelcontextprotocol/servers
- **MCP Inspector**: `npx @modelcontextprotocol/inspector`
- **FastMCP Documentation**: https://gofastmcp.com
- **Related skills**: `claude-code-hooks` (hook into Claude Code), `claude-code-debug` (debug Claude Code issues)
