# MCP Server Architecture

Samples target the v2 SDKs (Python `mcp` 2.x `MCPServer`, TypeScript
`@modelcontextprotocol/server` 2.x). For v1 → v2 renames and the 2026-07-28 protocol
changes, see [v2-migration.md](v2-migration.md).

## Protocol Overview

MCP uses **JSON-RPC 2.0** as its wire protocol. Every message is a JSON object with:

- **Requests**: `{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}`
- **Responses**: `{"jsonrpc": "2.0", "id": 1, "result": {...}}`
- **Notifications**: `{"jsonrpc": "2.0", "method": "notifications/progress", "params": {...}}` (no `id`, no response expected)

The protocol is transport-agnostic. The same JSON-RPC messages flow over stdio pipes,
Streamable HTTP, or (legacy) SSE streams.

## Server Lifecycle: Two Protocol Eras

A v2 server answers both eras from the same object, with nothing to configure:

```
2025-era (protocol <= 2025-11-25)          2026-era (protocol 2026-07-28)
──────────────────────────────────         ──────────────────────────────────
initialize ──→ capabilities                no handshake, no session
notifications/initialized                  every request carries protocol version
requests on one session                      + client capabilities in _meta
(Mcp-Session-Id over HTTP)                 server/discover = optional discovery call
server may call the client                 server can NOT call the client:
  (sampling, elicitation, roots)             tools return InputRequiredResult instead
transport close = shutdown                 any replica can answer any request
```

### 2025-era: initialize handshake

Client sends `initialize` with its capabilities and protocol version; the server answers
with its own. The client then sends `notifications/initialized`.

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": { "name": "claude-code", "version": "1.0.0" }
  }
}

// Server → Client
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-11-25",
    "capabilities": {
      "tools": { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "prompts": { "listChanged": true }
    },
    "serverInfo": { "name": "my-server", "version": "1.0.0" }
  }
}
```

### 2026-era: per-request metadata

There is no `initialize`. Every request carries the negotiated protocol version and the
client's capabilities in `_meta` (client identity is optional). `server/discover` is an
ordinary request a client can use to learn the server's capabilities, and servers stamp
their `serverInfo` into each result's `_meta`. The SDK `Client` probes `server/discover`
once and falls back to `initialize` against an older server. Exact `_meta` key names are
in the [specification](https://modelcontextprotocol.io/specification/latest); the SDKs
build them for you.

### Serving

Requests: `tools/list`, `tools/call`, `resources/list`, `resources/read`,
`prompts/list`, `prompts/get`, `completion/complete`. On 2026-era connections,
change notifications travel on a client-opened `subscriptions/listen` stream.

## Capability Negotiation

| Capability | Meaning | Sub-capabilities |
|-----------|---------|------------------|
| `tools` | Server offers tools | `listChanged` - notify on tool list changes |
| `resources` | Server offers resources | `subscribe`, `listChanged` |
| `prompts` | Server offers prompts | `listChanged` - notify on prompt list changes |
| `logging` | Server can emit log messages | Deprecated by SEP-2577 (still works on 2025-era sessions) |
| `extensions` | Optional capability bundles under reverse-DNS IDs (SEP-2133), e.g. MCP Apps, `io.modelcontextprotocol/tasks` | Per extension |

`MCPServer` (Python) and `McpServer` (TypeScript) derive the capability set from what you
register. The low-level `Server` in both SDKs needs the capabilities declared up front.

## MCPServer Setup (Python)

`MCPServer` is the official SDK's high-level API (it was `FastMCP` in v1). The standalone
`fastmcp` package (FastMCP 4, `from fastmcp import FastMCP`) has the same decorator
surface plus composition, proxies and OpenAPI generation. Its differences are listed in
[v2-migration.md](v2-migration.md#standalone-fastmcp-3-to-4).

### Basic Server

```python
from mcp.server import MCPServer

# name is positional; pass everything else by keyword (the v2 order changed)
mcp = MCPServer(
    "my-server",
    version="1.0.0",
    description="A server that does useful things",
)

@mcp.tool()
def greet(name: str) -> str:
    """Greet a user by name."""
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run()  # stdio by default
```

### Server with Dependencies

```python
import httpx
from mcp.server import MCPServer

mcp = MCPServer("api-server")

@mcp.tool()
async def fetch_data(url: str) -> str:
    """Fetch data from a URL."""
    async with httpx.AsyncClient() as client:   # HTTP inside your own tools is yours to choose
        resp = await client.get(url, timeout=30.0)
        resp.raise_for_status()
        return resp.text
```

### Lifespan Handlers

The lifespan yields a state object; handlers read it from
`ctx.request_context.lifespan_context`. Over Streamable HTTP the v2 lifespan runs
**once** at startup and is shared by every session and request (v1 ran it per session).

```python
import json
from contextlib import asynccontextmanager
from dataclasses import dataclass

from mcp.server import MCPServer
from mcp.server.mcpserver import Context

@dataclass
class AppState:
    db: "DbPool"

@asynccontextmanager
async def lifespan(server: MCPServer):
    db = await create_db_pool()      # startup: pools, config
    try:
        yield AppState(db=db)
    finally:
        await db.close()             # shutdown

mcp = MCPServer("db-server", lifespan=lifespan)

@mcp.tool()
async def query_db(sql: str, ctx: Context) -> str:
    """Run a read-only SQL query."""
    db = ctx.request_context.lifespan_context.db
    results = await db.fetch(sql)
    return json.dumps(results, default=str)
```

### The Context Object

Declare a `ctx: Context` parameter. It is injected, hidden from the tool schema, and
replaces v1's `mcp.get_context()`:

```python
import json

from mcp.server import MCPServer
from mcp.server.mcpserver import Context

mcp = MCPServer("context-demo")

@mcp.tool()
async def long_operation(items: list[str], ctx: Context) -> str:
    """Process items with progress reporting."""
    results = []
    for i, item in enumerate(items):
        await ctx.report_progress(i, len(items))   # absolute value, not a delta
        results.append(await process_item(item))
    return json.dumps(results)
```

Context provides:
- `ctx.report_progress(progress, total=None, message=None)` - progress notifications
- `ctx.read_resource(uri)` - read another resource from within a tool
- `ctx.request_id`, `ctx.session`, `ctx.request_context` (including `lifespan_context`)
- `ctx.mcp_server` - the server instance (was `ctx.fastmcp`)
- `ctx.notify_tools_changed()`, `ctx.notify_resource_updated(uri)` - change notifications
- `ctx.elicit(...)` - legacy-session only; prefer a `Resolve(...)` parameter (see [v2-migration.md](v2-migration.md#behaviour-that-changes-without-an-import-error))
- `ctx.info()` / `ctx.debug()` / `ctx.warning()` / `ctx.error()` - deprecated (SEP-2577), emit `MCPDeprecationWarning`; log with `logging` instead

### Running with Different Transports

```python
# stdio (default) - for Claude Desktop / Claude Code
mcp.run()
mcp.run(transport="stdio")

# Streamable HTTP - for production (transport settings live on run() in v2)
mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)

# SSE - legacy clients only
mcp.run(transport="sse", host="0.0.0.0", port=8000)
```

A non-loopback `host` needs `transport_security=TransportSecuritySettings(...)` to accept
your real hostname. DNS-rebinding protection auto-enables only for loopback hosts. See
[transport-auth.md](transport-auth.md).

## TypeScript SDK Server Setup

### Basic Server with McpServer

```typescript
import { McpServer } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import * as z from "zod/v4";

function createServer(): McpServer {
  const server = new McpServer({ name: "my-server", version: "1.0.0" });

  server.registerTool(
    "greet",
    { description: "Greet a user", inputSchema: z.object({ name: z.string() }) },
    async ({ name }) => ({ content: [{ type: "text", text: `Hello, ${name}!` }] })
  );

  return server;
}

void serveStdio(createServer);   // owns the stdio transport; builds the server per connection
```

`serveStdio` replaces v1's `new StdioServerTransport()` + `server.connect(transport)`.
`StdioServerTransport` is still exported from `@modelcontextprotocol/server/stdio`.

### Low-Level Server API

For maximum control, use the `Server` class. It infers nothing: declare capabilities,
and validate arguments yourself (only `arguments`-is-an-object is checked).

```typescript
import { ProtocolError, ProtocolErrorCode, Server } from "@modelcontextprotocol/server";

const server = new Server(
  { name: "low-level-server", version: "1.0.0" },
  { capabilities: { tools: { listChanged: true } } }
);

server.setRequestHandler("tools/list", async () => ({
  tools: [
    {
      name: "greet",
      description: "Greet a user",
      inputSchema: {
        type: "object",
        properties: { name: { type: "string", description: "User name" } },
        required: ["name"],
      },
    },
  ],
}));

server.setRequestHandler("tools/call", async (request) => {
  if (request.params.name !== "greet") {
    throw new ProtocolError(ProtocolErrorCode.InvalidParams, `Unknown tool: ${request.params.name}`);
  }
  const { name } = request.params.arguments as { name: string };
  return { content: [{ type: "text", text: `Hello, ${name}!` }] };
});
```

v1 passed Zod request schemas (`setRequestHandler(CallToolRequestSchema, ...)`); v2 takes
method strings, and the codemod rewrites them. An exception thrown in a low-level
handler is a protocol error (`-32603`), not an `isError` tool result.

### ProtocolError for Typed Errors

```typescript
import { ProtocolError, ProtocolErrorCode } from "@modelcontextprotocol/server";

// Standard JSON-RPC error codes (v1: McpError + ErrorCode)
throw new ProtocolError(ProtocolErrorCode.InvalidParams, "Missing required field: query");
throw new ProtocolError(ProtocolErrorCode.MethodNotFound, "Unknown method: foo");
throw new ProtocolError(ProtocolErrorCode.InternalError, "Database connection failed");
```

A protocol error fails the whole request and the model never reads it. For a failure the
model should see and recover from, return `isError: true` from a tool, or simply throw
inside an `McpServer` tool handler: the SDK converts that into an `isError` result.
Local-only conditions (request timeout, connection closed) are `SdkError` /
`SdkErrorCode`.

## Multi-Tool Server Organization

### By Domain (Recommended)

```python
# tools/files.py
import os

from mcp.server import MCPServer

def register_file_tools(mcp: MCPServer):
    @mcp.tool()
    def read_file(path: str) -> str:
        """Read contents of a file."""
        with open(path) as f:
            return f.read()

    @mcp.tool()
    def write_file(path: str, content: str) -> str:
        """Write content to a file."""
        with open(path, "w") as f:
            f.write(content)
        return f"Wrote {len(content)} bytes to {path}"

    @mcp.tool()
    def list_files(directory: str) -> str:
        """List files in a directory."""
        return "\n".join(os.listdir(directory))

# tools/database.py
def register_db_tools(mcp: MCPServer):
    @mcp.tool()
    def query(sql: str) -> str:
        """Execute a read-only SQL query."""
        ...

    @mcp.tool()
    def list_tables() -> str:
        """List all database tables."""
        ...

# server.py
from mcp.server import MCPServer
from tools.files import register_file_tools
from tools.database import register_db_tools

mcp = MCPServer("multi-tool-server")
register_file_tools(mcp)
register_db_tools(mcp)

if __name__ == "__main__":
    mcp.run()
```

Standalone FastMCP 4 adds server composition for this: `parent.mount(child, namespace="files")`
runs the child's lifespan and middleware live.

### Tool Namespacing

Prefix tool names to avoid collisions when multiple servers are active:

```python
@mcp.tool(name="myapp_search")  # Not just "search"
def search(query: str) -> str:
    ...

@mcp.tool(name="myapp_create_item")  # Not just "create"
def create_item(title: str) -> str:
    ...
```

## Middleware Patterns

Python SDK v2 has a `middleware` list on `MCPServer` and the low-level `Server` that wraps
every inbound message. It is marked **provisional**, so its shape may change in a minor
release. The decorator patterns below need nothing from the SDK.

### Request Logging

```python
import asyncio
import functools
import logging

logger = logging.getLogger("mcp-server")   # stdio servers: log to stderr, never stdout

def logged_tool(func):
    @functools.wraps(func)                  # keeps name, docstring and annotations for the schema
    async def wrapper(*args, **kwargs):
        logger.info("Tool called: %s with %s", func.__name__, kwargs)
        try:
            result = await func(*args, **kwargs) if asyncio.iscoroutinefunction(func) else func(*args, **kwargs)
            logger.info("Tool %s succeeded", func.__name__)
            return result
        except Exception:
            logger.exception("Tool %s failed", func.__name__)
            raise
    return wrapper
```

### Rate Limiting

```python
import time
from collections import defaultdict

import httpx
from mcp.server.mcpserver.exceptions import ToolError

class RateLimiter:
    def __init__(self, max_calls: int, window_seconds: int):
        self.max_calls = max_calls
        self.window = window_seconds
        self.calls: dict[str, list[float]] = defaultdict(list)

    def check(self, key: str) -> bool:
        now = time.time()
        self.calls[key] = [t for t in self.calls[key] if now - t < self.window]
        if len(self.calls[key]) >= self.max_calls:
            return False
        self.calls[key].append(now)
        return True

rate_limiter = RateLimiter(max_calls=60, window_seconds=60)

@mcp.tool()
async def rate_limited_api_call(endpoint: str) -> str:
    """Call an API with rate limiting."""
    if not rate_limiter.check("api"):
        raise ToolError("Rate limit exceeded. Wait before making more requests.")
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"https://api.example.com/{endpoint}")
        return resp.text
```

### Caching Middleware

```python
import asyncio
import time
from functools import wraps

def cached(ttl_seconds: int = 300):
    """Cache tool results for the given TTL."""
    cache: dict[str, tuple[float, str]] = {}

    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            key = f"{func.__name__}:{args}:{kwargs}"
            if key in cache:
                cached_at, result = cache[key]
                if time.time() - cached_at < ttl_seconds:
                    return result
            result = await func(*args, **kwargs) if asyncio.iscoroutinefunction(func) else func(*args, **kwargs)
            cache[key] = (time.time(), result)
            return result
        return wrapper
    return decorator

@mcp.tool()
@cached(ttl_seconds=60)
async def get_weather(city: str) -> str:
    """Get current weather for a city (cached for 60s)."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"https://weather.api/current?city={city}")
        return resp.text
```

2026-07-28 results can also carry protocol-level cache hints (`ttlMs`, `cacheScope`), set
per method with `MCPServer(cache_hints=...)`, which clients honour themselves.

## Error Handling

### Python Error Handling

v2 splits tool failures three ways. Pick the one that matches who should react:

```python
import json
import logging

import httpx
from mcp import MCPError
from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import INVALID_PARAMS

logger = logging.getLogger(__name__)
mcp = MCPServer("robust-server")

@mcp.tool()
async def safe_operation(input: str) -> str:
    """Perform an operation with proper error handling."""
    if not input:
        # Protocol error: the request itself is invalid; the HOST sees it, the model does not
        raise MCPError(INVALID_PARAMS, "input must be non-empty")
    try:
        result = await do_something(input)
        return json.dumps({"status": "success", "data": result})
    except ValueError as e:
        # Tool error: the MODEL reads this (is_error=True) and can retry with better args
        raise ToolError(f"Invalid input: {e}")
    except httpx.HTTPError as e:
        raise ToolError(f"API request failed: {e}. Try again shortly.")
    # Anything else: the model sees only "Error executing tool safe_operation",
    # and the traceback goes to the server log
```

Never `return` an error string: it arrives with `is_error=False` and looks like success.

### TypeScript Error Handling

```typescript
server.registerTool(
  "safe_operation",
  { description: "Do something safely", inputSchema: z.object({ input: z.string() }) },
  async ({ input }) => {
    try {
      const result = await doSomething(input);
      return { content: [{ type: "text", text: JSON.stringify(result) }] };
    } catch (error) {
      // Visible to the LLM; throwing here would produce the same isError shape
      return { content: [{ type: "text", text: `Error: ${(error as Error).message}` }], isError: true };
    }
  }
);
```

### Error Categories

| Error Type | Handling | Example |
|-----------|----------|---------|
| Invalid input the model can fix | Tool error (`ToolError` / `isError: true`) | "Missing required field: query" |
| Request the host must reject | Protocol error (`MCPError` / `ProtocolError`) | Missing client capability, unknown method |
| Auth failure | Tool error suggesting a config check | "API key invalid. Check MY_API_KEY env var" |
| External API error | Tool error with status + retry hint | "GitHub API returned 503. Try again in 30s" |
| Internal error | Let it raise; log details server-side | "Error executing tool <name>" |
| Timeout | Return partial results if available | "Operation timed out. Partial results: ..." |

## Logging

### Python Logging

MCP-level client logging (`ctx.info()` and friends) is deprecated by SEP-2577, emits
`MCPDeprecationWarning`, and v2 renamed its `message=` argument to `data=`. Log with
the standard library instead. A stdio server must log to **stderr**, because stdout is
the protocol channel.

```python
import json
import logging
import sys

from mcp.server import MCPServer
from mcp.server.mcpserver import Context

logging.basicConfig(stream=sys.stderr, level=logging.INFO)
logger = logging.getLogger("logged-server")
mcp = MCPServer("logged-server", log_level="INFO")

@mcp.tool()
async def debug_tool(data: str, ctx: Context) -> str:
    """A tool with comprehensive logging."""
    logger.debug("request %s received data: %s", ctx.request_id, data[:100])
    try:
        result = process(data)
        logger.info("processing complete: %d items", len(result))
        await ctx.report_progress(1, 1, message="done")   # progress the client should see
        return json.dumps(result)
    except Exception:
        logger.exception("processing failed")
        raise
```

### Log Levels

| Level | Use For |
|-------|---------|
| `debug` | Detailed diagnostic info, request/response bodies |
| `info` | Normal operations, progress updates |
| `warning` | Recoverable issues, deprecation notices |
| `error` | Failures that affect the current operation |

Python v2 OpenTelemetry tracing is on by default (a server span per request, no cost
until an exporter is configured).

## Graceful Shutdown

```python
import logging
from contextlib import asynccontextmanager
from dataclasses import dataclass

import httpx
from mcp.server import MCPServer

logger = logging.getLogger(__name__)

@dataclass
class Resources:
    db: "DbPool"
    http: httpx.AsyncClient

@asynccontextmanager
async def lifespan(server: MCPServer):
    db_pool = await create_pool()
    http_client = httpx.AsyncClient()
    try:
        yield Resources(db=db_pool, http=http_client)
    finally:
        await http_client.aclose()    # close connections, flush buffers
        await db_pool.close()
        logger.info("Server shutdown complete")

mcp = MCPServer("graceful-server", lifespan=lifespan)
```

## Connection and Session Management

### Session Isolation and State

On 2025-era connections each client has a session. On 2026-07-28 connections there is
**no session**: every request is self-contained and may land on any replica. So do not
keep per-client state on the session object. Key it explicitly (an argument, the OAuth
client from the access token) and store it somewhere shared.

```python
import asyncio

# BAD: shared mutable state without locks; also wrong across replicas
results_cache = {}

# GOOD (single process): shared state with proper locking
_lock = asyncio.Lock()
_shared_cache: dict = {}

@mcp.tool()
async def cached_lookup(key: str) -> str:
    async with _lock:
        if key not in _shared_cache:
            _shared_cache[key] = await expensive_lookup(key)
        return _shared_cache[key]

# GOOD (multi-replica): put state in Redis/DB keyed by caller identity
from mcp.server.auth.middleware.auth_context import get_access_token

@mcp.tool()
async def track_calls() -> str:
    token = get_access_token()
    caller = token.client_id if token else "anonymous"
    count = await redis.incr(f"calls:{caller}")
    return f"{caller} has made {count} calls"
```

Standalone FastMCP 4 adds a stateless session-state API (`UserSession` / `SessionId`) for
this; `ctx.set_state()` does not persist across calls on 2026-era connections.

### Notifying Clients of Changes

When your server's available tools, resources, or prompts change at runtime:

```python
from mcp.server.mcpserver import Context

def sprint_report() -> str:
    return "3 tasks done"

@mcp.tool()
async def enable_reports(ctx: Context) -> str:
    """Register a tool at runtime and tell the client."""
    mcp.add_tool(sprint_report)
    await ctx.notify_tools_changed()            # also: ctx.notify_resource_updated(uri)
    return "reporting is live"
```

On 2026-era connections, notifications reach only clients that opened a
`subscriptions/listen` stream. A multi-replica deployment plugs in a shared
`SubscriptionBus` so a notification published on one replica reaches listeners on
another.

## Project Structure

### Python (Recommended Layout)

```
my-mcp-server/
├── pyproject.toml
├── src/
│   └── my_server/
│       ├── __init__.py
│       ├── server.py          # MCPServer instance + main()
│       ├── tools/
│       │   ├── __init__.py
│       │   ├── files.py       # File operation tools
│       │   └── api.py         # API wrapper tools
│       ├── resources/
│       │   ├── __init__.py
│       │   └── config.py      # Configuration resources
│       └── prompts/
│           ├── __init__.py
│           └── workflows.py   # Prompt templates
└── tests/
    ├── test_tools.py
    └── test_resources.py
```

### TypeScript (Recommended Layout)

```
my-mcp-server/
├── package.json               # "type": "module"
├── tsconfig.json
├── src/
│   ├── index.ts               # createServer() factory + serveStdio / createMcpHandler
│   ├── tools/
│   │   ├── files.ts
│   │   └── api.ts
│   ├── resources/
│   │   └── config.ts
│   └── prompts/
│       └── workflows.ts
└── tests/
    ├── tools.test.ts
    └── resources.test.ts
```

## Claude Desktop Configuration

```json
{
  "mcpServers": {
    "my-python-server": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/my-server", "python", "-m", "my_server"],
      "env": {
        "API_KEY": "your-key",
        "DATABASE_URL": "postgresql://localhost/mydb"
      }
    },
    "my-ts-server": {
      "command": "npx",
      "args": ["tsx", "/path/to/my-server/src/index.ts"],
      "env": {
        "API_KEY": "your-key"
      }
    }
  }
}
```

## Claude Code Configuration

In a project-scoped `.mcp.json` at the repo root (`settings.json` has no `mcpServers` key), or via the CLI below:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/server", "python", "server.py"],
      "env": {
        "API_KEY": "your-key"
      }
    }
  }
}
```

Or via CLI:

```bash
claude mcp add my-server -- uv run --directory /path/to/server python server.py
```
