# Transport and Authentication

Samples target the v2 SDKs (Python `mcp` 2.x `MCPServer`, TypeScript
`@modelcontextprotocol/server` 2.x) and spec revision 2026-07-28; v1 differences are in
[v2-migration.md](v2-migration.md).

## Contents

- [stdio Transport](#stdio-transport)
- [SSE Transport (Legacy)](#sse-transport-legacy)
- [Streamable HTTP Transport](#streamable-http-transport)
- [Transport Selection Guide](#transport-selection-guide)
- [Session Management](#session-management)
- [Authentication](#authentication)
- [Rate Limiting](#rate-limiting)
- [CORS Configuration](#cors-configuration)
- [TLS/HTTPS for Production](#tlshttps-for-production)
- [Proxy Patterns](#proxy-patterns)

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
- stderr is used for logging (not protocol messages). Python v2 diverts stray `print()`
  output to stderr while serving and keeps handler subprocesses off the wire. In
  TypeScript, one `console.log` still corrupts the stream, so use `console.error`.
- Simplest transport, best for CLI tools and desktop integrations

### Python stdio Server

```python
from mcp.server import MCPServer

mcp = MCPServer("my-server")

@mcp.tool()
def hello(name: str) -> str:
    """Say hello."""
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run()  # stdio is the default transport
```

### TypeScript stdio Server

```typescript
import { McpServer } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";

function createServer(): McpServer {
  const server = new McpServer({ name: "my-server", version: "1.0.0" });
  // ... registerTool / registerResource / registerPrompt ...
  return server;
}

const handle = serveStdio(createServer);   // handle.close() tears down server + transport
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

Python v2 no longer reads `MCP_*` environment variables or `.env` files for server
settings. Pass configuration explicitly (constructor or `run()` arguments), and read
your own variables with `os.environ`.

### Claude Code Configuration

Project-scoped servers live in `.mcp.json` at the repo root (`settings.json` has no
`mcpServers` key):

```json
// .mcp.json
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

## SSE Transport (Legacy)

### How It Works

The HTTP+SSE transport predates Streamable HTTP. It uses one `GET` that opens an
EventSource stream for server-to-client messages, plus `POST`s to a message endpoint.
Keep it only for clients that cannot speak Streamable HTTP.

```
Client                              Server
┌──────────┐                        ┌──────────┐
│          │ ── GET /sse ─────────→  │          │
│          │ ←── SSE event stream ── │          │
│          │                         │          │
│          │ ── HTTP POST /messages→ │          │
│          │ ←── (via SSE stream) ── │          │
└──────────┘                        └──────────┘
```

### Python SSE Server

Python v2 still ships the SSE transport (`run(transport="sse")`, `sse_app()`):

```python
from mcp.server import MCPServer

mcp = MCPServer("sse-server")

@mcp.tool()
def hello(name: str) -> str:
    return f"Hello, {name}!"

if __name__ == "__main__":
    # transport settings live on run() in v2; mount_path was removed (mount the ASGI app instead)
    mcp.run(transport="sse", host="127.0.0.1", port=8000, sse_path="/sse")
```

### TypeScript SSE Server

`SSEServerTransport` was **removed** from the TypeScript SDK in v2. A frozen copy of the
v1 class is published as `@modelcontextprotocol/server-legacy/sse`. It is a temporary
bridge for v1 deployments, so plan the move to Streamable HTTP. New servers should not
use it.

### SSE Reconnection

SSE connections can drop. The EventSource API reconnects automatically on the client;
behind a reverse proxy, disable response buffering (see the nginx config below) so
events are not held back.

## Streamable HTTP Transport

### How It Works

Streamable HTTP uses one endpoint. Requests are HTTP POSTs, and a response is either a
single JSON body or an SSE stream when the server emits notifications (progress,
logging) before the result.

```
Client                              Server
┌──────────┐                        ┌──────────┐
│          │ ── POST /mcp ────────→ │          │
│          │    (JSON-RPC request)   │          │
│          │                         │          │
│          │ ←── JSON or SSE ─────── │          │
│          │    (result             │          │
│          │     + notifications)    │          │
└──────────┘                        └──────────┘

2026-07-28 requests: no Mcp-Session-Id; Mcp-Method / Mcp-Name headers for routing
2025-era requests:   Mcp-Session-Id header ties the client to a session
```

**Key characteristics:**
- Single HTTP endpoint for all communication
- 2026-07-28 traffic is **sessionless**, so any replica behind a plain round-robin load
  balancer can answer
- 2025-era clients (most clients in 2026) still open sessions and still need whatever
  stickiness they needed before
- Change notifications on 2026 connections use a client-opened `subscriptions/listen`
  stream
- Full OAuth 2.1 support; the recommended production transport

### Python Streamable HTTP Server

```python
from mcp.server import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

mcp = MCPServer("http-server")

@mcp.tool()
def hello(name: str) -> str:
    return f"Hello, {name}!"

if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=8000,
        # A non-loopback host must allowlist the names clients actually send
        transport_security=TransportSecuritySettings(
            allowed_hosts=["mcp.example.com"],
            allowed_origins=["https://app.example.com"],
        ),
    )
```

- DNS-rebinding protection auto-enables when `host` is `127.0.0.1`, `localhost` or
  `::1`. The allowlist uses `host:port` patterns, so a `Host` header without a port is
  rejected with `421`.
- Request bodies over 4 MiB get HTTP 413 (`max_request_body_size=` adjusts it).
- The lifespan runs once at startup and is shared by every request.
- Scaled out, 2026-era multi-round-trip retries carry a sealed `request_state`. Its
  default key is minted per process, so pass `RequestStateSecurity(keys=[...])` to every
  replica.

### TypeScript Streamable HTTP Server

`createMcpHandler` takes a factory and returns a web-standard `fetch` handler. The factory
runs **once per request**, so register everything inside it and keep pools at module
scope.

```typescript
import { createServer } from "node:http";
import { createMcpHandler, McpServer } from "@modelcontextprotocol/server";
import { localhostHostValidation, localhostOriginValidation, toNodeHandler } from "@modelcontextprotocol/node";
import * as z from "zod/v4";

const handler = createMcpHandler(() => {
  const server = new McpServer({ name: "http-server", version: "1.0.0" });
  server.registerTool(
    "hello",
    { description: "Say hello", inputSchema: z.object({ name: z.string() }) },
    async ({ name }) => ({ content: [{ type: "text", text: `Hello, ${name}!` }] })
  );
  return server;
});

// node:http: the handler validates neither Host nor Origin, so put the guards in front
const nodeHandler = toNodeHandler(handler);
const validateHost = localhostHostValidation();
const validateOrigin = localhostOriginValidation();

createServer((req, res) => {
  if (!validateHost(req, res) || !validateOrigin(req, res)) return;
  void nodeHandler(req, res);
}).listen(3000, "127.0.0.1");
```

- On Cloudflare Workers, Deno or Bun, `export default handler` is the entire mount.
- Under Express, Hono or Fastify, use the adapter package (`@modelcontextprotocol/express`
  and friends). Its `createMcp*App` factories arm the localhost Host/Origin guards by
  default.
- `createMcpHandler(factory, { responseMode: "json" })` never streams: mid-call
  notifications are dropped.
- `handler.close()` shuts the handler down.

### Stateless Mode

- **TypeScript v2:** `createMcpHandler` is stateless as-is, since nothing lives on the
  per-request instance. Sessions, resumability and multi-node fan-out are opt-in. See
  the SDK's
  [Sessions, state, and scaling](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/serving/sessions-state-scaling.md)
  page.
- **Python v2:** `mcp.run(transport="streamable-http", stateless_http=True)`. This flag
  only affects how **2025-era** clients are served, because 2026-07-28 traffic is
  sessionless regardless.

In stateless operation:
- No `Mcp-Session-Id` header
- Each request is independent, so the server keeps no per-client memory
- Works with any load balancer without sticky sessions
- No server-to-client back-channel: on Python, `stateless_http=True` or
  `json_response=True` removes it for 2025-era clients too

## Transport Selection Guide

| Scenario | Transport | Why |
|----------|-----------|-----|
| Claude Desktop integration | stdio | Native support, simplest setup |
| Claude Code tool | stdio | Direct process management |
| VS Code extension backend | stdio | Process managed by extension |
| Internal dashboard | Streamable HTTP | Browser-friendly; SSE responses when needed |
| Client that only speaks HTTP+SSE | SSE (legacy) | Compatibility only |
| Production API | Streamable HTTP | Auth, scaling, load balancing |
| Serverless (Lambda, Workers) | Streamable HTTP (stateless) | No persistent connections needed |
| Multi-tenant SaaS | Streamable HTTP | Per-request auth, no shared session state |
| Mobile app backend | Streamable HTTP | Standard HTTP, auth support |

## Session Management

### What a session still means

| Connection | Session? | Where per-client state lives |
|---|---|---|
| stdio | The process is the session | Process memory |
| Streamable HTTP, 2025-era client | Yes, `Mcp-Session-Id` (Python: session manager + optional `EventStore` for resumability, unchanged in v2) | Session object, or an external store keyed by session ID |
| Streamable HTTP, 2026-07-28 client | **No** | An external store keyed by something the request carries (OAuth client, an argument) |

Because one server answers both eras, write handlers as if there were no session. Key
state by caller identity, and keep it in a store every replica can reach.

### Per-Caller State

```python
import json

from mcp.server import MCPServer
from mcp.server.auth.middleware.auth_context import get_access_token

mcp = MCPServer("prefs-server")

def caller_id() -> str:
    token = get_access_token()          # set when the server runs with token_verifier=/auth=
    return token.client_id if token else "anonymous"

@mcp.tool()
async def set_preference(key: str, value: str) -> str:
    await store.hset(f"prefs:{caller_id()}", key, value)     # Redis/DB, not process memory
    return f"Set {key} = {value}"

@mcp.tool()
async def get_preferences() -> str:
    return json.dumps(await store.hgetall(f"prefs:{caller_id()}"))
```

Standalone FastMCP 4 adds `UserSession` / `SessionId` for this. On 2026 connections,
`ctx.set_state()` does not persist across calls.

### Background Cleanup

```python
import asyncio
from contextlib import asynccontextmanager

from mcp.server import MCPServer

async def cleanup_expired_entries():
    while True:
        await asyncio.sleep(300)  # Every 5 minutes
        for key in await store.expired(max_age_seconds=3600):
            await store.delete(key)

@asynccontextmanager
async def lifespan(server: MCPServer):
    cleanup_task = asyncio.create_task(cleanup_expired_entries())
    try:
        yield
    finally:
        cleanup_task.cancel()

mcp = MCPServer("state-server", lifespan=lifespan)
```

## Authentication

### API Keys in Environment Variables

The simplest auth pattern - pass credentials via environment configuration:

```python
import os

import httpx
from mcp.server.mcpserver.exceptions import ToolError

@mcp.tool()
async def call_api(endpoint: str) -> str:
    """Call an authenticated API."""
    api_key = os.environ.get("API_KEY")
    if not api_key:
        raise ToolError("API_KEY environment variable not set - check the server's env config")

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

### Bearer Tokens with the SDK's Resource Server (Python)

The SDK protects HTTP transports itself. Implement `TokenVerifier` (one async method)
and pass it with `AuthSettings`. The two travel together: passing one without the other
raises `ValueError`. The server then serves RFC 9728 Protected Resource Metadata and
rejects bad tokens before your tools run. stdio is never protected this way, because a
pipe has no `Authorization` header.

```python
from pydantic import AnyHttpUrl

from mcp.server import MCPServer
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings

RESOURCE = "http://127.0.0.1:8000/mcp"

class IntrospectionVerifier(TokenVerifier):
    async def verify_token(self, token: str) -> AccessToken | None:
        claims = await introspect(token)            # your IdP's introspection / JWT check
        if not claims or not claims["active"]:
            return None
        return AccessToken(token=token, client_id=claims["client_id"],
                           scopes=claims["scope"].split(), resource=RESOURCE)

mcp = MCPServer(
    "Notes",
    token_verifier=IntrospectionVerifier(),
    auth=AuthSettings(
        issuer_url=AnyHttpUrl("https://auth.example.com"),
        resource_server_url=AnyHttpUrl(RESOURCE),
        required_scopes=["notes:read"],
        validate_token_resource=True,
    ),
)
```

Inside a tool, `get_access_token()` (`mcp.server.auth.middleware.auth_context`) returns
the verified `AccessToken`. Source: [Python SDK Authorization](https://py.sdk.modelcontextprotocol.io/run/authorization/).

### Bearer Tokens in TypeScript

`authInfo` is pass-through in v2: `createMcpHandler` never reads headers or verifies a
token. Verify in front of the handler (`requireBearerAuth` from
`@modelcontextprotocol/express`, or `verifyBearerToken` from
`@modelcontextprotocol/server` on fetch runtimes). Then hand the result to
`handler.fetch(request, { authInfo })`; the factory receives it as `authInfo`, and tool
handlers read it as `ctx.http.authInfo`. The v1 Authorization-Server helpers
(`mcpAuthRouter`, `ProxyOAuthServerProvider`) are frozen in
`@modelcontextprotocol/server-legacy/auth`. The SDK's guidance is to run the
authorization server on a dedicated IdP/OAuth library.

### Hand-Rolled Bearer Middleware (Starlette)

For a custom ASGI host or a non-OAuth shared secret:

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

        request.state.user = await get_user_from_token(token)
        return await call_next(request)
```

### OAuth2 PKCE Flow

For MCP servers that call an upstream API on the user's behalf:

```python
import base64
import hashlib
import secrets
from urllib.parse import urlencode

import httpx

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

The SDK's *client* side does this for you when connecting to a protected MCP server:
`OAuthClientProvider` (`mcp.client.auth`). In v2 its `callback_handler` returns an
`AuthorizationCodeResult`, and it validates the RFC 9207 `iss` on the authorization
response.

### Token Management (Refresh with an In-Memory Cache)

```python
import asyncio
import time

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

Key the limiter by the authenticated caller, not by a session object: 2026-07-28
connections have no session, and replicas do not share memory. Move the counters to
Redis when you run more than one replica.

```python
import time
from collections import defaultdict

from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.mcpserver.exceptions import ToolError

class SlidingWindowRateLimiter:
    def __init__(self, max_requests: int, window_seconds: int):
        self.max_requests = max_requests
        self.window = window_seconds
        self.requests: dict[str, list[float]] = defaultdict(list)

    def allow(self, client_id: str) -> bool:
        now = time.time()
        self.requests[client_id] = [t for t in self.requests[client_id] if now - t < self.window]
        if len(self.requests[client_id]) >= self.max_requests:
            return False
        self.requests[client_id].append(now)
        return True

    def remaining(self, client_id: str) -> int:
        now = time.time()
        active = [t for t in self.requests[client_id] if now - t < self.window]
        return max(0, self.max_requests - len(active))

rate_limiter = SlidingWindowRateLimiter(max_requests=100, window_seconds=60)

@mcp.tool()
async def rate_limited_tool(query: str) -> str:
    """A rate-limited tool."""
    token = get_access_token()
    client_id = token.client_id if token else "anonymous"
    if not rate_limiter.allow(client_id):
        raise ToolError(f"Rate limit exceeded. Try again in {rate_limiter.window}s.")
    return await process(query)
```

### Per-Tool Rate Limiting

```python
import asyncio
from functools import wraps

from mcp.server.mcpserver.exceptions import ToolError

def rate_limit(max_calls: int, window: int):
    """Decorator to rate-limit individual tools."""
    limiter = SlidingWindowRateLimiter(max_calls, window)

    def decorator(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            tool_name = func.__name__
            if not limiter.allow(tool_name):
                raise ToolError(f"Tool {tool_name} rate limit exceeded ({max_calls}/{window}s)")
            return await func(*args, **kwargs) if asyncio.iscoroutinefunction(func) else func(*args, **kwargs)
        return wrapper
    return decorator

@mcp.tool()
@rate_limit(max_calls=10, window=60)
async def expensive_api_call(query: str) -> str:
    """Call an expensive API (limited to 10 calls/minute)."""
    ...
```

Gateways can rate-limit without parsing bodies: 2026-07-28 requests carry `Mcp-Method`
and (for tool, resource and prompt calls) `Mcp-Name` headers (SEP-2243).

## CORS Configuration

For browser-based clients connecting to HTTP servers. Allow the MCP request headers and
expose the session header to 2025-era clients:

```python
from starlette.middleware.cors import CORSMiddleware

# On the Starlette/FastAPI app that mounts mcp.streamable_http_app()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "https://myapp.example.com"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Mcp-Session-Id",
                   "Mcp-Protocol-Version", "Mcp-Method", "Mcp-Name"],
    expose_headers=["Mcp-Session-Id"],
)
```

```typescript
// Express CORS
import cors from "cors";
app.use(cors({
  origin: ["http://localhost:3000", "https://myapp.example.com"],
  credentials: true,
  allowedHeaders: ["Authorization", "Content-Type", "Mcp-Session-Id",
                   "Mcp-Protocol-Version", "Mcp-Method", "Mcp-Name"],
  exposedHeaders: ["Mcp-Session-Id"],
}));
```

The `Mcp-Method` / `Mcp-Name` entries are inferred from SEP-2243. If a browser client
sends `Mcp-Param-*` headers (schema properties marked `x-mcp-header`), allow those too.

## TLS/HTTPS for Production

Always use HTTPS for non-stdio transports in production:

```python
# Using uvicorn with TLS on the ASGI app
import uvicorn

app = mcp.streamable_http_app()

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
        proxy_set_header Host $host;   # must match the server's allowed_hosts
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;  # Important for SSE responses
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

A single MCP server that routes tool calls to backend MCP servers. Use the SDK `Client`
rather than hand-written JSON-RPC: it negotiates the protocol era per backend (a 2025-era
backend needs the `initialize` handshake, and a 2026 one needs per-request `_meta`).

```python
from mcp import Client
from mcp.server import MCPServer
from mcp.server.mcpserver.exceptions import ToolError

mcp = MCPServer("gateway")

BACKENDS = {
    "db_": "http://localhost:8001/mcp",
    "file_": "http://localhost:8002/mcp",
    "api_": "http://localhost:8003/mcp",
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
            async with Client(backend_url) as client:      # Streamable HTTP; era negotiated
                result = await client.call_tool(tool_name, arguments)
            if result.is_error:
                raise ToolError(result.content[0].text)
            return result.content[0].text
    raise ToolError(f"No backend found for tool: {tool_name}")
```

For a full proxy that mirrors the backend's tools, resources and prompts, standalone
FastMCP 4 has `create_proxy(...)` and `mount(..., namespace=...)`. Its proxy mirrors the
frontend's protocol era on the backend connection.
