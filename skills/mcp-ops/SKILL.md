---
name: mcp-ops
description: "MCP server development, tool design, resource handling, transport configuration. Use for: mcp, model context protocol, mcp server, mcp tool, mcp resource, fastmcp, mcp transport, stdio, sse, streamable http, mcp inspector, tool handler, mcp prompt."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: claude-code-ops, typescript-ops, python-fastapi-ops
---

# MCP Operations

Comprehensive patterns for building, testing, and deploying Model Context Protocol servers in Python and TypeScript.

> Ecosystem facts verified as of 2026-10-22: spec revision **2026-07-28**, Python SDK `mcp` **2.x**, standalone FastMCP **4**, TypeScript SDK **v2** (split packages). Porting v1 / FastMCP 3 code? Read [`references/v2-migration.md`](references/v2-migration.md) first.

## MCP Architecture Quick Reference

```
MCP Host (Claude Desktop, Claude Code, custom app)
  ├─ Client A ── stdio ─────────── Server A  (tools, resources)
  ├─ Client B ── Streamable HTTP ─ Server B  (resources, prompts)
  └─ Client C ── SSE (legacy) ──── Server C  (prompts, tools)

Protocol: JSON-RPC 2.0 over the chosen transport
2026-07-28: no initialize handshake, no session; every request carries its
            protocol version + client capabilities in _meta; discovery is
            server/discover; the server can no longer call the client mid-request
```

## Server Type Decision Tree

```
What transport does your MCP server need?
│
├─ Local CLI tool / single-user desktop integration?
│  └─ stdio
│     - Simplest setup, no networking; host owns the process lifecycle
│     - Claude Desktop, Claude Code native support
│
├─ Remote / multi-tenant / cloud deployment?
│  └─ Streamable HTTP
│     - 2026-07-28 requests are sessionless: any replica behind a plain
│       load balancer can answer them
│     - 2025-era clients still open Mcp-Session-Id sessions (keep stickiness)
│     - Full OAuth support; the production default
│
└─ Old client that only speaks HTTP+SSE?
   └─ SSE (legacy)
      - Superseded by Streamable HTTP; TS v2 moved it to
        @modelcontextprotocol/server-legacy, Python v2 keeps sse_app()
```

## Tool vs Resource vs Prompt Decision Tree

```
What does the LLM need to do?
│
├─ Perform an action or computation?
│  └─ TOOL - side effects, structured input, e.g. run_query, create_issue
│
├─ Read data or context?
│  └─ RESOURCE - read-only, identified by URI, e.g. config://app, schema://users
│
└─ Guide the LLM's behavior or workflow?
   └─ PROMPT - templated instructions with arguments, e.g. code_review(language, file)
```

## Python SDK Quick Start

```python
import json

from mcp.server import MCPServer  # v2. v1 was: from mcp.server.fastmcp import FastMCP

mcp = MCPServer("my-server")

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

@mcp.resource("schema://db/{table}")  # RFC 6570 template, matched exactly
def get_table_schema(table: str) -> str:
    """Return the schema for a database table."""
    return json.dumps(get_schema(table), indent=2)

@mcp.prompt()
def code_review(language: str, filepath: str) -> str:
    """Generate a code review prompt for the given file."""
    return f"Review this {language} code in {filepath} for bugs, style issues, and performance."

if __name__ == "__main__":
    mcp.run()  # stdio; HTTP: mcp.run(transport="streamable-http", port=3001)
```

**Install and run:**

```bash
uv init my-mcp-server && cd my-mcp-server
uv add "mcp[cli]"
uv run mcp run server.py   # or: uv run python server.py
uv run mcp dev server.py   # under the MCP Inspector
```

The decorators are unchanged from v1; what moved is around them. Transport settings
(`host`, `port`, `stateless_http`, `json_response`) go to `run()`, not the constructor
(`MCPServer("x", port=9000)` is a `TypeError`). Declare a `ctx: Context` parameter
(`from mcp.server.mcpserver import Context`) instead of `get_context()`. Sync `def`
handlers run on a worker thread. To stay on v1, pin `mcp>=1.28,<2` (1.x gets security
fixes only).

**Official `MCPServer` or standalone FastMCP 4?** The SDK's class was `FastMCP` in v1
and is `MCPServer` in v2 (the `mcp.server.fastmcp` path raises `ModuleNotFoundError`).
The standalone `fastmcp` package (gofastmcp.com) keeps the `FastMCP` name, is at
**major 4**, and builds on SDK v2. It has the same decorators, plus composition
(`mount`), proxies (`create_proxy`), OpenAPI providers, auth providers and a test `Client`:

```bash
uv add fastmcp
```

```python
from fastmcp import FastMCP   # standalone FastMCP 4, not the SDK's MCPServer

mcp = FastMCP("my-server")    # identity only; transport config goes to run()
mcp.run(transport="http", host="127.0.0.1", port=8000)
```

FastMCP 4 breaking changes (from 3.x):
- Server-pushed `ctx.sample()`, `ctx.sample_step()` and `ctx.list_roots()` are removed.
- `ctx.elicit()` raises on 2026-07-28 connections (which the default `Client(mode="auto")`
  negotiates) and now requires `response_type=`.
- `task=True` tools need `fastmcp[tasks]` plus `mcp.add_extension(TasksExtension())`.
- The 3.x deprecations are gone: `as_proxy` → `create_proxy`, `import_server` → `mount`
  (a live composition, not a snapshot), `mount(prefix=)` → `namespace=`.
- httpx → httpx2, and MCP model fields are snake_case (camelCase reads still work, with
  a warning).

## TypeScript SDK Quick Start

```typescript
import { McpServer } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import * as z from "zod/v4";

function createServer(): McpServer {
  const server = new McpServer({ name: "my-server", version: "1.0.0" });

  server.registerTool(
    "search_docs",
    {
      description: "Search documentation by keyword",
      inputSchema: z.object({ query: z.string().describe("Search query") }),
    },
    async ({ query }) => {
      const results = await performSearch(query);
      return { content: [{ type: "text", text: results.join("\n") }] };
    }
  );

  server.registerResource(
    "config",
    "config://app",
    { description: "Current application configuration", mimeType: "application/json" },
    async (uri) => ({
      contents: [{ uri: uri.href, mimeType: "application/json", text: JSON.stringify(loadConfig(), null, 2) }],
    })
  );

  server.registerPrompt(
    "code_review",
    {
      description: "Generate a code review prompt",
      argsSchema: z.object({ language: z.string(), filepath: z.string() }),
    },
    ({ language, filepath }) => ({
      messages: [{
        role: "user",
        content: { type: "text", text: `Review this ${language} code in ${filepath} for bugs and style issues.` },
      }],
    })
  );

  return server;
}

void serveStdio(createServer);          // HTTP: createMcpHandler(createServer)
console.error("my-server on stdio");    // stdout is the protocol channel
```

**Install and run:**

```bash
npm init -y
npm pkg set type=module
npm install @modelcontextprotocol/server zod
npx tsx server.ts
```

v2 splits the old `@modelcontextprotocol/sdk` monolith into `@modelcontextprotocol/server`,
`@modelcontextprotocol/client`, optional HTTP adapters (`/node`, `/express`, `/hono`,
`/fastify`) and `/core` (raw Zod wire schemas). It needs Node 20+ and zod ^4.2. The
variadic `server.tool()` / `.resource()` / `.prompt()` are removed: use `registerTool` /
`registerResource` / `registerPrompt` with a config object. Port v1 code with
`npx @modelcontextprotocol/codemod@latest v1-to-v2 .` (run it at the package root). The
1.x line is still published as `@modelcontextprotocol/sdk`.

## Transport Selection Matrix

| Feature | stdio | SSE (legacy) | Streamable HTTP |
|---------|-------|--------------|-----------------|
| **Use case** | Local CLI tools, desktop | Old HTTP+SSE clients only | Production APIs |
| **Protocol** | stdin/stdout pipes | HTTP + EventSource | HTTP POST (+ SSE stream when needed) |
| **Auth support** | Env vars only | Bearer tokens | Full OAuth 2.1 |
| **Deployment** | Local process | Single server | Load balanced |
| **State** | Process lifetime | Connection lifetime | Sessionless (2026-07-28) or session (2025-era clients) |
| **Multi-client** | 1:1 only | Multiple clients | Horizontally scalable |
| **SDK status** | Both SDKs | TS: `server-legacy` only; Py: `sse_app()` | Both SDKs, the default |

## Authentication Patterns Quick Reference

```python
# Pattern 1: API keys from environment
import os

import httpx
from mcp.server import MCPServer

mcp = MCPServer("api-server")

@mcp.tool()
def call_api(endpoint: str) -> str:
    """Call external API with configured credentials."""
    api_key = os.environ["MY_API_KEY"]  # Set in client config
    resp = httpx.get(f"https://api.example.com/{endpoint}",
                     headers={"Authorization": f"Bearer {api_key}"})
    return resp.text
```

Pattern 2, OAuth token refresh with an in-memory cache, and the full OAuth 2.1 server
setup are in [`references/transport-auth.md`](references/transport-auth.md).

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
| `No module named 'mcp.server.fastmcp'` | Python SDK v2 renamed `FastMCP` to `MCPServer` | `from mcp.server import MCPServer`, or pin `mcp<2` |
| `TypeError: ... unexpected keyword argument 'port'` | v2 moved transport settings off the constructor | `mcp.run(transport="streamable-http", port=...)` |
| `ctx.elicit()` fails in a test that passed on v1 | `Client(mcp)` negotiates 2026-07-28, which has no server-to-client back-channel (`NoBackChannelError`) | Use a `Resolve(...)` parameter (both eras), or `Client(mcp, mode="legacy")` |
| Model never sees the error text | v2: only a `ToolError` message reaches the model. `MCPError` becomes a JSON-RPC error, and any other exception reads `Error executing tool <name>` | Raise `ToolError` (Py) or return `isError: true` (TS) for failures the model can fix |
| Tool not appearing in client | Invalid input schema (`{}` lacks `"type": "object"`) | Let Pydantic/Zod generate it; v2 validates results before sending |
| `TS2769: No overload matches this call` on `registerTool` | zod < 4.2 lacks `~standard.jsonSchema` | Upgrade to `zod ^4.2.0` |
| Low-level handler returns a bare list | v2 low-level `Server` no longer wraps results | Return the full `ListToolsResult` / `CallToolResult` |
| Timeout on long operations | Client timeout is often 30-60s | Report progress (`ctx.report_progress`); split the work |
| Concurrent requests fail | Shared mutable state, and v2 runs sync `def` handlers on worker threads | Use locks, or keep handlers stateless and `async def` |
| Large response crashes client | Practical message size limits (Py v2 HTTP rejects bodies over 4 MiB) | Paginate; return summaries plus detail-fetch tools |
| Client ignores new tools | No list-changed notification | Py: `await ctx.notify_tools_changed()`. TS: `registerTool` handles notify for you |
| Tool name collision | Two servers register the same name | Namespace tools: `myserver_search`, not `search` |
| Server works locally, fails in Claude Desktop | Different working directory or PATH | Use absolute paths; log `os.getcwd()` on startup |

## Reference Files

| File | Content |
|------|---------|
| `references/v2-migration.md` | The version boundary: spec 2026-07-28, Python SDK v1→v2, FastMCP 3→4, TS SDK v1→v2, and what was not verified |
| `references/server-architecture.md` | Server lifecycle, MCPServer/TS SDK setup, low-level servers, capabilities, error handling |
| `references/tool-handlers.md` | Schema design, validation, return types, composition, side effects, examples |
| `references/resources-prompts.md` | Resource URIs, static/dynamic resources, templates, prompts, subscriptions |
| `references/transport-auth.md` | stdio/SSE/HTTP transports, session management, OAuth2, rate limiting, TLS |
| `references/testing-debugging.md` | MCP Inspector, unit/integration testing, protocol debugging, CI, performance |

## Staleness verifier

This skill encodes fast-moving facts (the MCP SDK package names + spec URL). [`scripts/check-mcp-facts.py`](scripts/check-mcp-facts.py) guards them against silent drift:

```bash
# Structural (PR CI, no network): every catalogued package's prose_token is
# still named in this skill's prose, the spec URL is still cited, and the
# currency note still carries a year.
python scripts/check-mcp-facts.py --offline        # exit 0 consistent, 10 drift

# Live (freshness job, never blocks a PR): each SDK still resolves on
# npm/PyPI, no tracked major has moved off the sampled major, spec URL 200.
python scripts/check-mcp-facts.py --live            # exit 10 drift, 7 registries unreachable
```

The canonical fact set lives in [`assets/mcp-facts.json`](assets/mcp-facts.json); when you add or drop a package, update it to match or `--offline` fails CI.

## See Also

- **MCP Specification**: https://modelcontextprotocol.io/specification/latest (the old spec.modelcontextprotocol.io subdomain no longer resolves)
- **Python SDK**: https://github.com/modelcontextprotocol/python-sdk, docs https://py.sdk.modelcontextprotocol.io/ (v1 docs under `/v1/`)
- **TypeScript SDK**: https://github.com/modelcontextprotocol/typescript-sdk, docs https://ts.sdk.modelcontextprotocol.io/
- **Official MCP Servers**: https://github.com/modelcontextprotocol/servers
- **MCP Inspector**: `npx @modelcontextprotocol/inspector`
- **FastMCP Documentation**: https://gofastmcp.com
- **Related skills**: `claude-code-ops` (Claude Code hooks, MCP server debugging)
