# MCP Server Architecture

## Protocol Overview

MCP uses **JSON-RPC 2.0** as its wire protocol. Every message is a JSON object with:

- **Requests**: `{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}`
- **Responses**: `{"jsonrpc": "2.0", "id": 1, "result": {...}}`
- **Notifications**: `{"jsonrpc": "2.0", "method": "notifications/progress", "params": {...}}` (no `id`, no response expected)

The protocol is transport-agnostic. The same JSON-RPC messages flow over stdio pipes, SSE streams, or HTTP requests.

## Server Lifecycle

```
┌──────────────┐     ┌──────────────────────┐     ┌─────────┐
│ Uninitialized │────→│    Initializing       │────→│  Ready  │
└──────────────┘     │                      │     └────┬────┘
                     │ Client sends          │          │
                     │ initialize request    │     ┌────┴────┐
                     │ Server responds with  │     │ Serving │
                     │ capabilities          │     │ requests│
                     │ Client sends          │     └────┬────┘
                     │ initialized notif     │          │
                     └──────────────────────┘     ┌────┴────┐
                                                  │Shutdown │
                                                  └─────────┘
```

### Phase 1: Initialization

Client sends `initialize` with its capabilities and protocol version. Server responds with its own capabilities.

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": { "name": "claude-code", "version": "1.0.0" }
  }
}

// Server → Client
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "capabilities": {
      "tools": { "listChanged": true },
      "resources": { "subscribe": true, "listChanged": true },
      "prompts": { "listChanged": true },
      "logging": {}
    },
    "serverInfo": { "name": "my-server", "version": "1.0.0" }
  }
}
```

### Phase 2: Initialized Notification

Client sends `notifications/initialized` to confirm. Server transitions to ready state.

### Phase 3: Serving

Server handles requests: `tools/list`, `tools/call`, `resources/list`, `resources/read`, `prompts/list`, `prompts/get`, `completion/complete`.

### Phase 4: Shutdown

Transport closes (process exit for stdio, connection close for HTTP/SSE). Server cleans up resources.

## Capability Negotiation

Servers declare what they support during initialization:

| Capability | Meaning | Sub-capabilities |
|-----------|---------|------------------|
| `tools` | Server offers tools | `listChanged` - notify on tool list changes |
| `resources` | Server offers resources | `subscribe` - clients can subscribe to changes; `listChanged` |
| `prompts` | Server offers prompts | `listChanged` - notify on prompt list changes |
| `logging` | Server can emit log messages | (none) |
| `experimental` | Experimental features | Varies by implementation |

## FastMCP Server Setup (Python)

FastMCP is the recommended high-level API for Python MCP servers.

### Basic Server

```python
from mcp.server.fastmcp import FastMCP

# Create server with metadata
mcp = FastMCP(
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
from mcp.server.fastmcp import FastMCP
import httpx

mcp = FastMCP("api-server")

# Dependencies are injected per-request via FastMCP's Context
@mcp.tool()
async def fetch_data(url: str) -> str:
    """Fetch data from a URL."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(url, timeout=30.0)
        resp.raise_for_status()
        return resp.text
```

### Lifespan Handlers

Use lifespan to manage resources that live for the server's entire lifetime:

```python
from contextlib import asynccontextmanager
from mcp.server.fastmcp import FastMCP

@asynccontextmanager
async def lifespan(server: FastMCP):
    """Initialize and cleanup server resources."""
    # Startup: create connection pools, load config
    db = await create_db_pool()
    server.state["db"] = db
    try:
        yield
    finally:
        # Shutdown: cleanup
        await db.close()

mcp = FastMCP("db-server", lifespan=lifespan)

@mcp.tool()
async def query_db(sql: str, ctx: Context) -> str:
    """Run a read-only SQL query."""
    db = ctx.server.state["db"]
    results = await db.fetch(sql)
    return json.dumps(results, default=str)
```

### FastMCP Context Object

The `Context` parameter gives tools access to server internals:

```python
from mcp.server.fastmcp import FastMCP, Context

mcp = FastMCP("context-demo")

@mcp.tool()
async def long_operation(items: list[str], ctx: Context) -> str:
    """Process items with progress reporting."""
    results = []
    for i, item in enumerate(items):
        await ctx.report_progress(i, len(items))
        result = await process_item(item)
        results.append(result)
        await ctx.info(f"Processed {item}")  # Log to client
    return json.dumps(results)
```

Context provides:
- `ctx.report_progress(current, total)` - send progress notifications
- `ctx.info(message)`, `ctx.debug(message)`, `ctx.warning(message)`, `ctx.error(message)` - logging
- `ctx.read_resource(uri)` - read another resource from within a tool
- `ctx.server` - access the FastMCP server instance and its state
- `ctx.request_context` - access the low-level request context and session

### Running with Different Transports

```python
# stdio (default) - for Claude Desktop / Claude Code
mcp.run()
mcp.run(transport="stdio")

# SSE - for web clients
mcp.run(transport="sse", host="0.0.0.0", port=8000)

# Streamable HTTP - for production
mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
```

## TypeScript SDK Server Setup

### Basic Server with McpServer

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({
  name: "my-server",
  version: "1.0.0",
});

// Tools, resources, and prompts registered via server methods
server.tool("greet", "Greet a user", { name: z.string() }, async ({ name }) => ({
  content: [{ type: "text", text: `Hello, ${name}!` }],
}));

const transport = new StdioServerTransport();
await server.connect(transport);
```

### Low-Level Server API

For maximum control, use the `Server` class directly:

```typescript
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "low-level-server", version: "1.0.0" },
  { capabilities: { tools: { listChanged: true } } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "greet",
      description: "Greet a user",
      inputSchema: {
        type: "object" as const,
        properties: {
          name: { type: "string", description: "User name" },
        },
        required: ["name"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name === "greet") {
    const { name } = request.params.arguments as { name: string };
    return {
      content: [{ type: "text", text: `Hello, ${name}!` }],
    };
  }
  throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${request.params.name}`);
});
```

### McpError for Typed Errors

```typescript
import { McpError, ErrorCode } from "@modelcontextprotocol/sdk/types.js";

// Standard JSON-RPC error codes
throw new McpError(ErrorCode.InvalidParams, "Missing required field: query");
throw new McpError(ErrorCode.MethodNotFound, "Unknown tool: foo");
throw new McpError(ErrorCode.InternalError, "Database connection failed");

// Custom error codes (use negative numbers per JSON-RPC spec)
throw new McpError(-32001, "Rate limit exceeded");
```

## Multi-Tool Server Organization

### By Domain (Recommended)

```python
# tools/files.py
from mcp.server.fastmcp import FastMCP

def register_file_tools(mcp: FastMCP):
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
        import os
        entries = os.listdir(directory)
        return "\n".join(entries)

# tools/database.py
def register_db_tools(mcp: FastMCP):
    @mcp.tool()
    def query(sql: str) -> str:
        """Execute a read-only SQL query."""
        ...

    @mcp.tool()
    def list_tables() -> str:
        """List all database tables."""
        ...

# server.py
from mcp.server.fastmcp import FastMCP
from tools.files import register_file_tools
from tools.database import register_db_tools

mcp = FastMCP("multi-tool-server")
register_file_tools(mcp)
register_db_tools(mcp)

if __name__ == "__main__":
    mcp.run()
```

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

### Request Logging

```python
from mcp.server.fastmcp import FastMCP
import logging

logger = logging.getLogger("mcp-server")
mcp = FastMCP("logged-server")

# Use lifespan for server-level middleware
@asynccontextmanager
async def lifespan(server: FastMCP):
    logger.info("Server starting up")
    yield
    logger.info("Server shutting down")

# For per-tool logging, use a decorator
def logged_tool(func):
    async def wrapper(*args, **kwargs):
        logger.info(f"Tool called: {func.__name__} with {kwargs}")
        try:
            result = await func(*args, **kwargs) if asyncio.iscoroutinefunction(func) else func(*args, **kwargs)
            logger.info(f"Tool {func.__name__} succeeded")
            return result
        except Exception as e:
            logger.error(f"Tool {func.__name__} failed: {e}")
            raise
    wrapper.__name__ = func.__name__
    wrapper.__doc__ = func.__doc__
    wrapper.__annotations__ = func.__annotations__
    return wrapper
```

### Rate Limiting

```python
import time
from collections import defaultdict

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
async def rate_limited_api_call(endpoint: str, ctx: Context) -> str:
    """Call an API with rate limiting."""
    if not rate_limiter.check("api"):
        return "Rate limit exceeded. Please wait before making more requests."
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"https://api.example.com/{endpoint}")
        return resp.text
```

### Caching Middleware

```python
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

## Error Handling

### Python Error Handling

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("robust-server")

@mcp.tool()
async def safe_operation(input: str) -> str:
    """Perform an operation with proper error handling."""
    try:
        result = await do_something(input)
        return json.dumps({"status": "success", "data": result})
    except ValueError as e:
        # User-facing error: return as tool result with error flag
        # FastMCP handles this by returning content with isError=True
        raise ValueError(f"Invalid input: {e}")
    except httpx.HTTPError as e:
        raise RuntimeError(f"API request failed: {e}")
    except Exception as e:
        # Log internally, return safe message
        logger.exception("Unexpected error in safe_operation")
        raise RuntimeError("An unexpected error occurred. Check server logs.")
```

### TypeScript Error Handling

```typescript
server.tool("safe_operation", "Do something safely", { input: z.string() }, async ({ input }) => {
  try {
    const result = await doSomething(input);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  } catch (error) {
    // Return error as tool result (visible to LLM)
    return {
      content: [{ type: "text", text: `Error: ${error.message}` }],
      isError: true,
    };
  }
});
```

### Error Categories

| Error Type | Handling | Example |
|-----------|----------|---------|
| Invalid input | Return clear message, `isError: true` | "Missing required field: query" |
| Auth failure | Return message suggesting config check | "API key invalid. Check MY_API_KEY env var" |
| External API error | Return status + retry suggestion | "GitHub API returned 503. Try again in 30s" |
| Internal error | Log details, return safe message | "Internal error. Check server logs" |
| Timeout | Return partial results if available | "Operation timed out. Partial results: ..." |

## Logging

### Python Logging

```python
from mcp.server.fastmcp import FastMCP, Context

mcp = FastMCP("logged-server")

@mcp.tool()
async def debug_tool(data: str, ctx: Context) -> str:
    """A tool with comprehensive logging."""
    await ctx.debug(f"Received data: {data[:100]}")
    await ctx.info("Processing started")

    try:
        result = process(data)
        await ctx.info(f"Processing complete: {len(result)} items")
        return json.dumps(result)
    except Exception as e:
        await ctx.error(f"Processing failed: {e}")
        raise
```

### Log Levels

| Level | Use For |
|-------|---------|
| `debug` | Detailed diagnostic info, request/response bodies |
| `info` | Normal operations, progress updates |
| `warning` | Recoverable issues, deprecation notices |
| `error` | Failures that affect the current operation |

## Graceful Shutdown

```python
import signal
from contextlib import asynccontextmanager
from mcp.server.fastmcp import FastMCP

@asynccontextmanager
async def lifespan(server: FastMCP):
    # Startup
    db_pool = await create_pool()
    http_client = httpx.AsyncClient()
    server.state["db"] = db_pool
    server.state["http"] = http_client

    try:
        yield
    finally:
        # Cleanup: close connections, flush buffers
        await http_client.aclose()
        await db_pool.close()
        logger.info("Server shutdown complete")

mcp = FastMCP("graceful-server", lifespan=lifespan)
```

## Connection and Session Management

### Session Isolation

Each client connection gets its own session. Do not share mutable state between sessions without synchronization:

```python
# BAD: Shared mutable state without locks
results_cache = {}  # All sessions share this dict unsafely

# GOOD: Per-session state via context
@mcp.tool()
async def track_calls(ctx: Context) -> str:
    """Track how many times this session called this tool."""
    session = ctx.request_context.session
    if not hasattr(session, "call_count"):
        session.call_count = 0
    session.call_count += 1
    return f"This session has made {session.call_count} calls"

# GOOD: Shared state with proper locking
import asyncio
_lock = asyncio.Lock()
_shared_cache: dict = {}

@mcp.tool()
async def cached_lookup(key: str) -> str:
    async with _lock:
        if key not in _shared_cache:
            _shared_cache[key] = await expensive_lookup(key)
        return _shared_cache[key]
```

### Notifying Clients of Changes

When your server's available tools, resources, or prompts change at runtime:

```python
@mcp.tool()
async def enable_advanced_tools(ctx: Context) -> str:
    """Dynamically register new tools and notify the client."""
    register_advanced_tools(ctx.server)
    # Notify client that tool list has changed
    await ctx.request_context.session.send_resource_list_changed()
    return "Advanced tools enabled"
```

## Project Structure

### Python (Recommended Layout)

```
my-mcp-server/
├── pyproject.toml
├── src/
│   └── my_server/
│       ├── __init__.py
│       ├── server.py          # FastMCP instance + main()
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
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts               # Server setup + transport
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

In `.claude/settings.json` or project settings:

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
