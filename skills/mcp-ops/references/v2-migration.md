# MCP v2 Migration: the 2026-07-28 Version Boundary

What changed when the MCP spec, both official SDKs and standalone FastMCP all moved a
major version in July-August 2026, and how to port v1 code. Verified 2026-10-22 against
the official release notes and migration guides cited in each section; anything not
verified is marked so in [What was not verified](#what-was-not-verified).

## Contents

- [The release boundary at a glance](#the-release-boundary-at-a-glance)
- [Spec revision 2026-07-28](#spec-revision-2026-07-28)
- [Python SDK: mcp 1.x to 2.x](#python-sdk-mcp-1x-to-2x)
- [Standalone FastMCP 3 to 4](#standalone-fastmcp-3-to-4)
- [TypeScript SDK: @modelcontextprotocol/sdk to the v2 packages](#typescript-sdk-modelcontextprotocolsdk-to-the-v2-packages)
- [Staying on v1](#staying-on-v1)
- [What was not verified](#what-was-not-verified)

## The release boundary at a glance

| Component | v1 line (maintenance) | v2 line (current) | First v2 release |
|---|---|---|---|
| MCP spec | 2025-11-25 and earlier | 2026-07-28 | 2026-07-28 |
| Python SDK (PyPI `mcp`) | 1.x on the `v1.x` branch, security and critical fixes only (1.30.0, 2026-09-07) | 2.x (2.3.0, 2026-10-02) | 2.0.0, 2026-07-28 |
| TypeScript SDK | `@modelcontextprotocol/sdk` 1.x (1.32.1, 2026-10-05) | `@modelcontextprotocol/server` / `client` 2.x (2.3.1, 2026-10-05) | 2.0.0, 2026-07-27 |
| Standalone FastMCP (PyPI `fastmcp`) | 3.4.x (3.4.11, 2026-10-20) | 4.x (4.1.3, 2026-10-20) | 4.0.0, 2026-08-31 |

Release dates and versions are from GitHub Releases (python-sdk, typescript-sdk,
PrefectHQ/fastmcp) and the PyPI JSON API. Both v2 SDKs serve **both** protocol eras from
one server, so upgrading the server does not strand 2025-era clients.

## Spec revision 2026-07-28

Sources: [Python SDK "What's new in v2"](https://py.sdk.modelcontextprotocol.io/whats-new/),
[TS SDK migration guides](https://ts.sdk.modelcontextprotocol.io/v2/migration/).

- **No handshake, no session.** Each request carries its protocol version and client
  capabilities in `_meta`; discovery is a plain `server/discover` request. Over
  Streamable HTTP the 2026 path has no `Mcp-Session-Id`, so any replica behind a
  round-robin load balancer can answer. 2025-era clients still open sessions.
- **The server cannot call the client.** Pushed elicitation, sampling and `roots/list`
  are gone on 2026 connections. Instead a tool *returns* the question
  (`InputRequiredResult`), the client answers, and the call is retried with the answers
  attached ("multi-round-trip requests").
- **Deprecated capabilities (SEP-2577):** roots, sampling and MCP-level logging,
  deprecated on every protocol version. `ping` and `logging/setLevel` are removed at
  2026-07-28.
- **Change notifications** travel on one client-opened `subscriptions/listen` stream,
  which replaces the standalone HTTP GET stream and `resources/subscribe`.
- **Routing headers:** `Mcp-Method` and `Mcp-Name` (SEP-2243), so gateways route without
  parsing bodies.
- **Cache hints:** results carry `ttlMs`/`cacheScope` (SEP-2549).
- **Extensions:** extensions are first class, under reverse-DNS IDs (SEP-2133). Tasks
  left the core spec and became the `io.modelcontextprotocol/tasks` extension (SEP-2663).
- **Error codes:** resource-not-found is `-32602` (was `-32002`). New reserved codes are
  `-32020` (header mismatch), `-32021` (missing client capability) and `-32022`
  (unsupported protocol version).

## Python SDK: mcp 1.x to 2.x

Sources: [v2.0.0 release notes](https://github.com/modelcontextprotocol/python-sdk/releases/tag/v2.0.0),
[Migration Guide](https://py.sdk.modelcontextprotocol.io/migration/) (every breaking
change with before/after code), [Versioning policy](https://github.com/modelcontextprotocol/python-sdk/blob/main/VERSIONING.md).

### Renames almost every project hits

| v1 | v2 | First symptom |
|---|---|---|
| `from mcp.server.fastmcp import FastMCP` | `from mcp.server import MCPServer` (submodules: `mcp.server.mcpserver.*`) | `ModuleNotFoundError` (the old path is gone, not deprecated) |
| `ctx.fastmcp`, `FastMCPError` | `ctx.mcp_server`, `MCPServerError` | `AttributeError` / `ImportError` |
| `mcp.get_context()` | declare `ctx: Context` (`from mcp.server.mcpserver import Context`) | `AttributeError` |
| camelCase fields (`tool.inputSchema`, `result.isError`) | snake_case (`tool.input_schema`, `result.is_error`); wire JSON unchanged | `AttributeError` |
| `McpError(ErrorData(...))` | `MCPError(code, message, data)` | `ImportError` |
| `mcp.types` (in-package) | standalone `mcp-types` package; `mcp.types` stays a permanent alias | none |
| `streamablehttp_client` | `streamable_http_client` (yields two streams; no `get_session_id`) | `ImportError` |
| `httpx` / `httpx-sse` | `httpx2` (TLS verifies through the OS trust store via `truststore`) | `ModuleNotFoundError: httpx` |
| `create_connected_server_and_client_session()` | `async with Client(mcp) as client:` (in memory) | `ImportError` |
| Resource URI `AnyUrl` | `str` | `AttributeError: 'str' object has no attribute 'host'` |

### MCPServer constructor and run()

```python
# v1
from mcp.server.fastmcp import FastMCP
mcp = FastMCP("Demo", host="0.0.0.0", port=9000, json_response=True, stateless_http=True)
mcp.run(transport="streamable-http")

# v2
from mcp.server import MCPServer
mcp = MCPServer("Demo", instructions="...")   # name positional, everything else by keyword
mcp.run(transport="streamable-http", host="0.0.0.0", port=9000,
        json_response=True, stateless_http=True)
```

- Moved to `run()` / `streamable_http_app()` / `sse_app()`: `host`, `port`, `sse_path`,
  `message_path`, `streamable_http_path`, `json_response`, `stateless_http`,
  `max_request_body_size`, `event_store`, `retry_interval`, `transport_security`.
- Removed: `mount_path` (mount the ASGI app instead).
- The positional order changed to `name, title, description, instructions, ...`, so a
  v1 call passing `instructions` positionally silently lands it in `title`.
- The default name is `mcp-server` (was `FastMCP`), and an unversioned server reports an
  empty version.
- `MCP_*` env vars and `.env` files are no longer read (pydantic-settings was dropped).
- Streamable HTTP rejects bodies over 4 MiB (HTTP 413), and its lifespan runs **once**
  at startup, shared by every session. In v1 it ran per session, and per request under
  `stateless_http=True`.
- DNS-rebinding protection auto-enables for `127.0.0.1` / `localhost` / `::1` hosts.
  Serve a real hostname with
  `transport_security=TransportSecuritySettings(allowed_hosts=[...], allowed_origins=[...])`.

Mounted in Starlette, the host app's lifespan must still enter `mcp.session_manager.run()`:

```python
import contextlib
from starlette.applications import Starlette
from starlette.routing import Mount

@contextlib.asynccontextmanager
async def lifespan(app: Starlette):
    async with mcp.session_manager.run():
        yield

app = Starlette(routes=[Mount("/", app=mcp.streamable_http_app(json_response=True))],
                lifespan=lifespan)
```

### Behaviour that changes without an import error

- **Sync `def` handlers run on a worker thread** (`anyio.to_thread.run_sync`), so
  `asyncio.get_running_loop()` inside one raises. Use `async def` to stay on the loop.
- **Errors split three ways.** `ToolError` (`mcp.server.mcpserver.exceptions`) gives the
  model your message with `is_error=True`. `MCPError` propagates as a JSON-RPC error that
  the model never sees. Any other exception becomes `Error executing tool <name>`, with
  the traceback in the server log.
- **Results are validated before they leave.** A hand-built `Tool` with
  `input_schema={}` fails `tools/list`.
- **Clients validate what they receive** against the negotiated version, so a lenient v1
  peer can now raise `pydantic.ValidationError`.
- **URI templates are real RFC 6570.** `{+path}` and `{?query}` work, matching is exact,
  and path traversal in extracted values is rejected by default.
- **`ctx.elicit()` fails on 2026 connections** with `NoBackChannelError`. `Client(mcp)`
  negotiates 2026-07-28 by default, so tests hit this first. Move the question into a
  `Resolve(fn)` parameter (it works on both eras), or pin the test client to
  `mode="legacy"`.
- **Logging helpers take `data=`, not `message=`,** and `ctx.info()` and friends emit
  `MCPDeprecationWarning` (SEP-2577). Log with the standard `logging` module instead.
- **`ProgressContext` / `progress()` are removed.** Use
  `ctx.report_progress(progress, total, message)`, which takes an absolute value, not a
  delta.
- **List-changed notifications:** `await ctx.notify_tools_changed()` and
  `await ctx.notify_resource_updated(uri)` from a handler.

### Low-level Server

The decorators (`@server.list_tools()`, `@server.call_tool()`) and `server.request_context`
are gone. Handlers are `async (ctx, params) -> result` callables passed to the
constructor, and they return the full result type. The SDK no longer validates tool
arguments against the schema before your handler runs, so check them yourself.

```python
from mcp import MCPError
from mcp.server import Server, ServerRequestContext
from mcp.types import (INVALID_PARAMS, CallToolRequestParams, CallToolResult,
                       ListToolsResult, PaginatedRequestParams, TextContent, Tool)

SEARCH = Tool(name="search_books", description="Search the catalog.",
              input_schema={"type": "object", "properties": {"query": {"type": "string"}},
                            "required": ["query"]})

async def list_tools(ctx: ServerRequestContext, params: PaginatedRequestParams | None) -> ListToolsResult:
    return ListToolsResult(tools=[SEARCH])

async def call_tool(ctx: ServerRequestContext, params: CallToolRequestParams) -> CallToolResult:
    if params.name != "search_books":
        raise MCPError(INVALID_PARAMS, f"Unknown tool: {params.name}")
    args = params.arguments or {}          # may be None now: v1 defaulted it to {}
    return CallToolResult(content=[TextContent(type="text", text=f"Matches for {args.get('query')!r}")])

server = Server("Bookshop", on_list_tools=list_tools, on_call_tool=call_tool)
```

An unexpected exception in a low-level handler becomes a sanitized `-32603` error;
return `CallToolResult(is_error=True, ...)` for failures the model should read. Custom
methods register with `add_request_handler(method, params_type, handler)`. Source:
[What's new: the low-level Server was rebuilt](https://py.sdk.modelcontextprotocol.io/whats-new/).

### Removed outright

- The WebSocket transport and the `mcp[ws]` extra. WebSocket was never in the spec.
- The experimental Tasks API (`mcp.*.experimental`). The tasks extension is not
  implemented in 2.x yet.
- `mcp.shared.version`, `mcp.shared.progress` and `mcp.shared.session`.
- `Context.client_id`. Read the OAuth client from `get_access_token()` instead.

## Standalone FastMCP 3 to 4

Sources: [v4.0.0 release notes](https://github.com/PrefectHQ/fastmcp/releases/tag/v4.0.0),
[Upgrading from FastMCP 3](https://gofastmcp.com/getting-started/upgrading/from-fastmcp-3).
The repository moved from `jlowin/fastmcp` to `PrefectHQ/fastmcp`.

FastMCP 4 builds on SDK v2, and its import stays `from fastmcp import FastMCP`. An
import of `FastMCP` from `mcp.server.fastmcp` is the SDK's bundled FastMCP 1.0, not
standalone FastMCP. Gofastmcp.com has a separate guide for that path,
[from MCP SDK v1](https://gofastmcp.com/getting-started/upgrading/from-mcp-sdk-v1).

| Area | FastMCP 3 | FastMCP 4 |
|---|---|---|
| Environment | | pydantic >= 2.12; Starlette >= 1.0.1 (FastAPI >= 0.133.0) |
| Sampling / roots | `ctx.sample()`, `ctx.sample_step()`, `ctx.list_roots()`, `FastMCP(sampling_handler=)` | removed. Call an LLM server-side, or ask via the guard pattern (return `InputRequiredResult`) |
| Elicitation | `ctx.elicit(msg)` | handshake-era only. It raises on 2026-07-28, and `response_type=` is required |
| Background tasks | `@mcp.tool(task=True)` built in | `fastmcp[tasks]` plus `mcp.add_extension(TasksExtension())`; tools only; client `call_tool(..., task=True)` → `call_tool_task(...)` |
| Composition | `as_proxy`, `import_server`, `mount(prefix=)` | `create_proxy`, `mount` (live: runs the child's lifespan and middleware), `mount(namespace=)` |
| Moved imports | `fastmcp.server.proxy`, `fastmcp.server.openapi` | `fastmcp.server.providers.proxy`, `fastmcp.server.providers.openapi` (`OpenAPIProvider`) |
| Tool params | `serializer=`, `exclude_args=` | return a `ToolResult`; hide args with a `Depends(...)` default |
| HTTP stack | httpx | httpx2. An `except httpx.` around FastMCP calls silently never matches |
| Model fields | camelCase | snake_case. camelCase reads warn via a compatibility bridge (`mcp_camelcase_compat`) |
| Client default | | `Client(mode="auto")` negotiates 2026-07-28. `Client("server.py")` (a bare str) is deprecated: pass a `Path` |
| Errors | `McpError(ErrorData(...))` | `McpError(code=..., message=...)` |
| Resource not found | `-32002` | `-32602` |

On 2026-07-28 connections, `Middleware.on_initialize` never runs and `ctx.set_state()`
does not persist across calls, because every request is a fresh connection. The guide
says that a server whose purpose is to borrow the caller's model through sampling
should stay on FastMCP 3.x.

## TypeScript SDK: @modelcontextprotocol/sdk to the v2 packages

Sources: [Upgrading from v1.x to v2](https://ts.sdk.modelcontextprotocol.io/v2/migration/upgrade-to-v2),
[Packages](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/get-started/packages.md),
[Serve over HTTP](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/serving/http.md).

**Start with the codemod**, run at the package root so it also rewrites `package.json`,
tests and fixtures:

```bash
npx @modelcontextprotocol/codemod@latest v1-to-v2 .
grep -rn '@mcp-codemod-error' .   # sites it recognized but could not rewrite
npx tsc --noEmit
```

| v1 | v2 |
|---|---|
| `@modelcontextprotocol/sdk` (one package, deep `/server/mcp.js` paths) | `@modelcontextprotocol/server`, `/client`, `/core` (Zod wire schemas), adapters `/node` `/express` `/hono` `/fastify`; `exports` maps only |
| `server.tool(name, desc, shape, cb)` / `.resource()` / `.prompt()` | `registerTool(name, { description, inputSchema: z.object(...) }, cb)` / `registerResource(name, uri, metadata, cb)` / `registerPrompt(name, { argsSchema }, cb)` |
| raw Zod shapes | Standard Schema objects (`z.object()`, ArkType, Valibot, `fromJsonSchema()`). zod ^4.2 required; zod 3 unsupported |
| `new StdioServerTransport()` + `server.connect()` | `serveStdio(createServer)` from `@modelcontextprotocol/server/stdio` (the transport class still exists there) |
| `StreamableHTTPServerTransport` + `connect()` per request | `createMcpHandler(createServer)` (web-standard `fetch`), `toNodeHandler` from `@modelcontextprotocol/node`, or `createMcpExpressApp` / Hono / Fastify factories |
| `SSEServerTransport` | removed; frozen copy in `@modelcontextprotocol/server-legacy/sse` |
| `WebSocketClientTransport` | removed |
| `McpError`, `ErrorCode` | `ProtocolError`, `ProtocolErrorCode`; local-only codes → `SdkError` / `SdkErrorCode` |
| `setRequestHandler(CallToolRequestSchema, ...)` | `setRequestHandler('tools/call', ...)` (method strings) |
| `RequestHandlerExtra` (`extra`) | `ServerContext` / `ClientContext` (`ctx.mcpReq.*`, `ctx.http?.*`) |
| `InMemoryTransport` from `sdk/inMemory.js` | `InMemoryTransport` from `@modelcontextprotocol/server` or `/client`; take both halves from the same package |
| OAuth AS helpers (`mcpAuthRouter`, `ProxyOAuthServerProvider`) | `@modelcontextprotocol/server-legacy/auth` (frozen); RS helpers (`requireBearerAuth`) → `@modelcontextprotocol/express` |

- **Packaging:** Node 20+, ESM-first, with a CommonJS build alongside. Framework adapters
  declare `express` / `hono` / `fastify` as peer dependencies, so install the framework
  yourself.
- **The factory is per request.** `createMcpHandler` builds a fresh `McpServer` for every
  HTTP request, so register inside the factory and keep pools at module scope.
- **Host and Origin are not validated by the handler.** The framework factories arm
  localhost guards by default; on plain `node:http`, compose
  `localhostHostValidation()` / `localhostOriginValidation()` in front.
- **Staged migration:** v1 and v2 have different package names, so both can be
  installed at once. Objects must not cross between v1-imported and v2-imported code
  (`instanceof` fails).
- **Adopting 2026-07-28 specifics** (multi-round-trip, `versionNegotiation`) is separate
  from the package upgrade. See
  [support-2026-07-28](https://ts.sdk.modelcontextprotocol.io/v2/migration/support-2026-07-28.md).

## Staying on v1

- **Python:** pin `mcp>=1.28,<2`. The 1.x line gets critical and security fixes from the
  `v1.x` branch, documented at https://py.sdk.modelcontextprotocol.io/v1/.
- **TypeScript:** stay on `@modelcontextprotocol/sdk@^1`. It was still releasing in
  October 2026, and the v2 packages have different names, so nothing upgrades you by
  accident.
- **FastMCP:** pin `fastmcp<4` if you depend on server-pushed sampling or roots.

## What was not verified

- The TypeScript SDK's long-term support window for the 1.x line: no maintenance policy
  statement was found in the sources above. The release cadence (1.32.1 on 2026-10-05)
  is measured, and how long it continues is not known.
- The code samples in this file and in the other references were checked against the
  official docs and examples, but **not executed** against installed 2.x / 4.x packages
  when this was written.
- The tasks extension (SEP-2663) on the Python SDK side: the 2.0.0 notes list it as a
  known gap, and it was not checked whether 2.1-2.3 closed it.
- Client-side DPoP (SEP-1932) and the workload-identity `jwt-bearer` grant were listed
  as not implemented in Python 2.0.0. Their status in later 2.x releases was not checked.
