# Transport and Authentication

## stdio Transport

### How It Works

The stdio transport communicates via **stdin** (client-to-server) and **stdout** (server-to-client). Each message is a JSON-RPC 2.0 object, one per line (newline-delimited).

```
Host Process                    MCP Server Process
┌──────────┐                    ┌──────────┐
│          │ ─── stdin ──────→  │          │
│  Client  │                    │  Server  │
│          │ ←── stdout ─────── │          │
└──────────┘                    └──────────┘
                                stderr → logs
```

**Key characteristics:**
- One client per server process (1:1 mapping)
- Host manages process lifecycle (spawn, restart, kill)
- No networking - everything is local
- stderr is used for logging (not protocol messages)
- Simplest transport, best for CLI tools and desktop integrations

### Python stdio Server

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("my-server")

@mcp.tool()
def hello(name: str) -> str:
    """Say hello."""
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run()  # stdio is the default transport
```

### TypeScript stdio Server

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

const server = new McpServer({ name: "my-server", version: "1.0.0" });
// ... register tools ...

const transport = new StdioServerTransport();
await server.connect(transport);
```

### Claude Desktop Configuration

Location: `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%/Claude/claude_desktop_config.json` (Windows)

```json
{
  "mcpServers": {
    "my-python-server": {
      "command": "uv",
      "args": ["run", "--directory", "/absolute/path/to/server", "python", "server.py"],
      "env": {
        "API_KEY": "sk-your-key",
        "LOG_LEVEL": "INFO"
      }
    },
    "my-node-server": {
      "command": "npx",
      "args": ["tsx", "/absolute/path/to/server/index.ts"],
      "env": {
        "API_KEY": "sk-your-key"
      }
    },
    "published-server": {
      "command": "uvx",
      "args": ["my-published-mcp-server"],
      "env": {}
    }
  }
}
```

### Claude Code Configuration

```json
// .claude/settings.json (project-level)
{
  "mcpServers": {
    "my-server": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/server", "python", "server.py"],
      "env": {
        "API_KEY": "sk-your-key"
      }
    }
  }
}
```

CLI shortcuts:

```bash
# Add a server
claude mcp add my-server -- uv run --directory /path/to/server python server.py

# Add with environment variables
claude mcp add my-server -e API_KEY=sk-key -- uv run python server.py

# List configured servers
claude mcp list

# Remove a server
claude mcp remove my-server
```

## SSE Transport

### How It Works

SSE (Server-Sent Events) uses HTTP for client-to-server requests and an EventSource stream for server-to-client messages.

```
Client                              Server
┌──────────┐                        ┌──────────┐
│          │ ── HTTP POST /sse ───→  │          │
│          │ ←── SSE event stream ── │          │
│          │                         │          │
│          │ ── HTTP POST /msg ───→  │          │
│          │ ←── (via SSE stream) ── │          │
└──────────┘                        └──────────┘
```

**Key characteristics:**
- HTTP-based, works through firewalls and proxies
- Server pushes events to client via EventSource
- Client sends requests via HTTP POST
- Multiple clients can connect simultaneously
- Good for development servers and internal tools

### Python SSE Server

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("sse-server")

@mcp.tool()
def hello(name: str) -> str:
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run(transport="sse", host="0.0.0.0", port=8000)
```

### TypeScript SSE Server

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import express from "express";

const app = express();
const server = new McpServer({ name: "sse-server", version: "1.0.0" });

// ... register tools ...

app.get("/sse", async (req, res) => {
  const transport = new SSEServerTransport("/messages", res);
  await server.connect(transport);
});

app.post("/messages", async (req, res) => {
  // Handle incoming messages from client
  await transport.handlePostMessage(req, res);
});

app.listen(8000, () => console.log("SSE server running on port 8000"));
```

### SSE Reconnection

SSE connections can drop. The EventSource API handles automatic reconnection:

```typescript
// Client-side: EventSource handles reconnection automatically
const eventSource = new EventSource("http://localhost:8000/sse");
eventSource.onopen = () => console.log("Connected");
eventSource.onerror = (e) => console.log("Connection lost, reconnecting...");
```

Server-side, send keepalive comments to prevent connection timeout:

```python
# FastMCP handles this internally when using SSE transport
# For custom implementations, send periodic comments:
# : keepalive\n\n
```

## Streamable HTTP Transport

### How It Works

Streamable HTTP uses standard HTTP POST for requests and SSE for streaming responses. It supports both stateful (session-based) and stateless modes.

```
Client                              Server
┌──────────┐                        ┌──────────┐
│          │ ── POST /mcp ────────→ │          │
│          │    (JSON-RPC request)   │          │
│          │                         │          │
│          │ ←── SSE stream ──────── │          │
│          │    (JSON-RPC response)  │          │
│          │    (+ notifications)    │          │
└──────────┘                        └──────────┘

Session management via Mcp-Session-Id header
```

**Key characteristics:**
- Single HTTP endpoint for all communication
- Responses can be regular HTTP or SSE streams
- Session IDs for stateful operation, or fully stateless
- Load balancer and CDN friendly
- Full authentication support
- Recommended for production deployments

### Python Streamable HTTP Server

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("http-server")

@mcp.tool()
def hello(name: str) -> str:
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
```

### TypeScript Streamable HTTP Server

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import express from "express";

const app = express();
app.use(express.json());

const server = new McpServer({ name: "http-server", version: "1.0.0" });
// ... register tools ...

app.post("/mcp", async (req, res) => {
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => crypto.randomUUID(),
  });
  await server.connect(transport);
  await transport.handleRequest(req, res);
});

app.listen(8000);
```

### Stateless Mode

For serverless or horizontally scaled deployments:

```typescript
const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: undefined,  // No session tracking
});
```

In stateless mode:
- No `Mcp-Session-Id` header
- Each request is independent
- Server reconstructs state from request context
- Works with any load balancer without sticky sessions

## Transport Selection Guide

| Scenario | Transport | Why |
|----------|-----------|-----|
| Claude Desktop integration | stdio | Native support, simplest setup |
| Claude Code tool | stdio | Direct process management |
| VS Code extension backend | stdio | Process managed by extension |
| Internal dashboard | SSE | Browser-friendly, real-time updates |
| Development/testing | SSE | Easy to inspect with browser |
| Production API | Streamable HTTP | Auth, scaling, load balancing |
| Serverless (Lambda, Workers) | Streamable HTTP (stateless) | No persistent connections needed |
| Multi-tenant SaaS | Streamable HTTP | Session isolation, auth per tenant |
| Mobile app backend | Streamable HTTP | Standard HTTP, auth support |

## Session Management

### Session IDs

For stateful HTTP transports, each client gets a unique session:

```typescript
const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: () => crypto.randomUUID(),
  // Optional: validate session IDs
  sessionValidator: async (sessionId) => {
    return await sessionStore.exists(sessionId);
  },
});
```

### Session State

```python
# Store per-session state
class SessionState:
    def __init__(self):
        self.user_id: str | None = None
        self.preferences: dict = {}
        self.history: list = []

# In FastMCP, access via context
@mcp.tool()
async def set_preference(key: str, value: str, ctx: Context) -> str:
    session = ctx.request_context.session
    if not hasattr(session, "state"):
        session.state = SessionState()
    session.state.preferences[key] = value
    return f"Set {key} = {value}"
```

### Session Cleanup

```python
from contextlib import asynccontextmanager
import asyncio

@asynccontextmanager
async def lifespan(server: FastMCP):
    # Start cleanup task
    cleanup_task = asyncio.create_task(cleanup_expired_sessions())
    try:
        yield
    finally:
        cleanup_task.cancel()

async def cleanup_expired_sessions():
    while True:
        await asyncio.sleep(300)  # Every 5 minutes
        expired = session_store.get_expired(max_age_seconds=3600)
        for session_id in expired:
            session_store.remove(session_id)
```

## Authentication

### API Keys in Environment Variables

The simplest auth pattern - pass credentials via environment configuration:

```python
import os

@mcp.tool()
async def call_api(endpoint: str) -> str:
    """Call an authenticated API."""
    api_key = os.environ.get("API_KEY")
    if not api_key:
        raise RuntimeError("API_KEY environment variable not set")

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"https://api.example.com/{endpoint}",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=30.0,
        )
        resp.raise_for_status()
        return resp.text
```

Client config passes the key:

```json
{
  "mcpServers": {
    "api-server": {
      "command": "python",
      "args": ["server.py"],
      "env": {
        "API_KEY": "sk-your-api-key-here"
      }
    }
  }
}
```

### Bearer Token Authentication (HTTP transports)

For SSE and Streamable HTTP, authenticate incoming requests:

```python
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Skip auth for health checks
        if request.url.path == "/health":
            return await call_next(request)

        auth_header = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return JSONResponse({"error": "Missing or invalid Authorization header"}, status_code=401)

        token = auth_header[7:]
        if not await validate_token(token):
            return JSONResponse({"error": "Invalid token"}, status_code=403)

        # Attach user info to request state
        request.state.user = await get_user_from_token(token)
        return await call_next(request)
```

### OAuth2 PKCE Flow

For MCP servers that need user-level authentication:

```python
import secrets
import hashlib
import base64
from urllib.parse import urlencode

class OAuth2PKCEFlow:
    def __init__(self, client_id: str, auth_url: str, token_url: str, redirect_uri: str):
        self.client_id = client_id
        self.auth_url = auth_url
        self.token_url = token_url
        self.redirect_uri = redirect_uri

    def generate_auth_url(self) -> tuple[str, str]:
        """Generate authorization URL with PKCE challenge."""
        code_verifier = secrets.token_urlsafe(64)
        code_challenge = base64.urlsafe_b64encode(
            hashlib.sha256(code_verifier.encode()).digest()
        ).rstrip(b"=").decode()

        params = urlencode({
            "response_type": "code",
            "client_id": self.client_id,
            "redirect_uri": self.redirect_uri,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
            "scope": "read write",
        })
        return f"{self.auth_url}?{params}", code_verifier

    async def exchange_code(self, code: str, code_verifier: str) -> dict:
        """Exchange authorization code for tokens."""
        async with httpx.AsyncClient() as client:
            resp = await client.post(self.token_url, data={
                "grant_type": "authorization_code",
                "client_id": self.client_id,
                "code": code,
                "redirect_uri": self.redirect_uri,
                "code_verifier": code_verifier,
            })
            resp.raise_for_status()
            return resp.json()

    async def refresh_token(self, refresh_token: str) -> dict:
        """Refresh an expired access token."""
        async with httpx.AsyncClient() as client:
            resp = await client.post(self.token_url, data={
                "grant_type": "refresh_token",
                "client_id": self.client_id,
                "refresh_token": refresh_token,
            })
            resp.raise_for_status()
            return resp.json()
```

### Token Management

```python
import time
import asyncio

class TokenManager:
    """Manage OAuth2 tokens with automatic refresh."""

    def __init__(self, oauth: OAuth2PKCEFlow):
        self.oauth = oauth
        self._tokens: dict = {}
        self._lock = asyncio.Lock()

    async def get_token(self) -> str:
        """Get a valid access token, refreshing if needed."""
        async with self._lock:
            if self._is_valid():
                return self._tokens["access_token"]

            if "refresh_token" in self._tokens:
                self._tokens = await self.oauth.refresh_token(self._tokens["refresh_token"])
                self._tokens["obtained_at"] = time.time()
                return self._tokens["access_token"]

            raise RuntimeError("No valid token available. User must re-authenticate.")

    def _is_valid(self) -> bool:
        if "access_token" not in self._tokens:
            return False
        expires_at = self._tokens.get("obtained_at", 0) + self._tokens.get("expires_in", 0)
        return time.time() < expires_at - 60  # 60s buffer

    def set_tokens(self, tokens: dict):
        """Store tokens after initial authorization."""
        self._tokens = {**tokens, "obtained_at": time.time()}
```

## Rate Limiting

### Per-Client Rate Limiting

```python
import time
from collections import defaultdict

class SlidingWindowRateLimiter:
    def __init__(self, max_requests: int, window_seconds: int):
        self.max_requests = max_requests
        self.window = window_seconds
        self.requests: dict[str, list[float]] = defaultdict(list)

    def allow(self, client_id: str) -> bool:
        now = time.time()
        # Remove expired entries
        self.requests[client_id] = [
            t for t in self.requests[client_id]
            if now - t < self.window
        ]
        if len(self.requests[client_id]) >= self.max_requests:
            return False
        self.requests[client_id].append(now)
        return True

    def remaining(self, client_id: str) -> int:
        now = time.time()
        active = [t for t in self.requests[client_id] if now - t < self.window]
        return max(0, self.max_requests - len(active))

# Usage in tools
rate_limiter = SlidingWindowRateLimiter(max_requests=100, window_seconds=60)

@mcp.tool()
async def rate_limited_tool(query: str, ctx: Context) -> str:
    """A rate-limited tool."""
    client_id = str(id(ctx.request_context.session))
    if not rate_limiter.allow(client_id):
        remaining_wait = rate_limiter.window
        raise RuntimeError(f"Rate limit exceeded. Try again in {remaining_wait}s.")
    return await process(query)
```

### Per-Tool Rate Limiting

```python
from functools import wraps

def rate_limit(max_calls: int, window: int):
    """Decorator to rate-limit individual tools."""
    limiter = SlidingWindowRateLimiter(max_calls, window)

    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            tool_name = func.__name__
            if not limiter.allow(tool_name):
                raise RuntimeError(f"Tool {tool_name} rate limit exceeded ({max_calls}/{window}s)")
            return await func(*args, **kwargs) if asyncio.iscoroutinefunction(func) else func(*args, **kwargs)
        return wrapper
    return decorator

@mcp.tool()
@rate_limit(max_calls=10, window=60)
async def expensive_api_call(query: str) -> str:
    """Call an expensive API (limited to 10 calls/minute)."""
    ...
```

## CORS Configuration

For web-based clients connecting to SSE or HTTP servers:

```python
from starlette.middleware.cors import CORSMiddleware

# If using Starlette/FastAPI alongside FastMCP
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "https://myapp.example.com"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Mcp-Session-Id"],
)
```

```typescript
// Express CORS
import cors from "cors";
app.use(cors({
  origin: ["http://localhost:3000", "https://myapp.example.com"],
  credentials: true,
  allowedHeaders: ["Authorization", "Content-Type", "Mcp-Session-Id"],
}));
```

## TLS/HTTPS for Production

Always use HTTPS for non-stdio transports in production:

```python
# Using uvicorn with TLS
import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=443,
        ssl_keyfile="/path/to/key.pem",
        ssl_certfile="/path/to/cert.pem",
    )
```

Or terminate TLS at a reverse proxy (recommended):

```nginx
# nginx reverse proxy for MCP server
server {
    listen 443 ssl;
    server_name mcp.example.com;

    ssl_certificate /etc/letsencrypt/live/mcp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/mcp.example.com/privkey.pem;

    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;  # Important for SSE
        proxy_cache off;      # Don't cache SSE streams
    }
}
```

## Proxy Patterns

### Reverse Proxy for Multiple MCP Servers

Route requests to different MCP servers based on path:

```nginx
# Serve multiple MCP servers from one domain
server {
    listen 443 ssl;
    server_name mcp.example.com;

    # Server A: database tools
    location /db/ {
        proxy_pass http://localhost:8001/;
        proxy_buffering off;
    }

    # Server B: file system tools
    location /files/ {
        proxy_pass http://localhost:8002/;
        proxy_buffering off;
    }

    # Server C: API integration tools
    location /api/ {
        proxy_pass http://localhost:8003/;
        proxy_buffering off;
    }
}
```

### Gateway Pattern

A single MCP server that routes to backend services:

```python
from mcp.server.fastmcp import FastMCP
import httpx

mcp = FastMCP("gateway")

# Route tool calls to backend MCP servers
BACKENDS = {
    "db_": "http://localhost:8001",
    "file_": "http://localhost:8002",
    "api_": "http://localhost:8003",
}

@mcp.tool()
async def gateway_call(tool_name: str, arguments: dict) -> str:
    """Route a tool call to the appropriate backend.

    Args:
        tool_name: Full tool name (e.g., db_query, file_read)
        arguments: Tool arguments as a JSON object
    """
    for prefix, backend_url in BACKENDS.items():
        if tool_name.startswith(prefix):
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    f"{backend_url}/mcp",
                    json={
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "tools/call",
                        "params": {"name": tool_name, "arguments": arguments},
                    },
                )
                return resp.json()["result"]["content"][0]["text"]
    raise ValueError(f"No backend found for tool: {tool_name}")
```
