# Testing and Debugging

Samples target the v2 SDKs (Python `mcp` 2.x, TypeScript `@modelcontextprotocol/server`
and `/client` 2.x) and MCP Inspector 2.x; v1 differences are in
[v2-migration.md](v2-migration.md).

## MCP Inspector

The MCP Inspector is an interactive debugging tool for testing MCP servers without a
full client setup. v2 (one package, Node `>=22.19.0`) has three modes: web UI (default),
`--cli` (scriptable), and `--tui`. The v1 line is `@modelcontextprotocol/inspector@v1-latest`.

### Installation and Usage

```bash
# Web UI (no install needed); pass the stdio server command after the package
npx @modelcontextprotocol/inspector uv run python server.py
npx @modelcontextprotocol/inspector npx tsx src/index.ts

# Python SDK shortcut: runs your server under the Inspector
uv run mcp dev server.py

# Stdio server with env vars
npx @modelcontextprotocol/inspector -e API_KEY=sk-key uv run python server.py

# CLI mode: connect-only probe, then list tools as JSON
npx @modelcontextprotocol/inspector --cli uv run python server.py --method initialize
npx @modelcontextprotocol/inspector --cli uv run python server.py --method tools/list --format json

# CLI mode against a Streamable HTTP (or legacy SSE) server
npx @modelcontextprotocol/inspector --cli --transport http --server-url http://localhost:8000/mcp --method tools/list
npx @modelcontextprotocol/inspector --cli --transport sse --server-url http://localhost:8000/sse --method tools/list

# Call a tool with JSON arguments (no key=value coercion)
npx @modelcontextprotocol/inspector --cli uv run python server.py \
  --method tools/call --tool-name search --tool-args-json '{"query":"test"}' --format json
```

If a server flag collides with an Inspector flag, put `--` before the Inspector flags
that follow the server command. In v2 the Inspector keeps secrets (OAuth tokens, stdio
`env:` values) in the OS keychain, or falls back to `~/.mcp-inspector/secrets.json` on
headless machines. Source: [Inspector README](https://github.com/modelcontextprotocol/inspector)
and its [CLI smoke-testing guide](https://github.com/modelcontextprotocol/inspector/blob/main/docs/cli-smoke-testing.md).

### What You Can Do with Inspector

| Feature | How |
|---------|-----|
| List tools | Click "Tools" tab to see all registered tools |
| Call tools | Fill in arguments and click "Call" |
| List resources | Click "Resources" tab |
| Read resources | Click any resource to see its contents |
| List prompts | Click "Prompts" tab |
| Get prompts | Fill in arguments and see rendered prompt |
| View messages | The message log shows raw JSON-RPC traffic |
| Test notifications | See server notifications in real-time |
| Script it | `--cli ... --format json`, then `jq -e` to assert; exit codes 0-5 map to failure classes |

### Inspecting Protocol Messages

The Inspector shows raw JSON-RPC messages. Use this to verify:

- Request format matches the MCP specification
- Response content is properly structured
- Error codes and messages are correct
- Notifications are sent at the right times

```
2025-era session (handshake):

→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25",...}}
← {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{}},...}}
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search",...}]}}
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"test"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"..."}]}}

2026-07-28 (no handshake): every request carries protocol version + client
capabilities in params._meta; server/discover is an optional first call.
```

## Unit Testing Tools (Python)

### Testing Tool Functions Directly

Decorated tool functions are still plain functions, so test the logic directly and
mock only external services (never the unit under test):

```python
# test_tools.py
from unittest.mock import MagicMock, patch

import pytest

from my_server.server import create_ticket, search_docs

class TestSearchDocs:
    def test_basic_search(self):
        """Search returns formatted results."""
        with patch("my_server.server.perform_search") as mock_search:
            mock_search.return_value = [
                MagicMock(title="Doc 1", snippet="First result"),
                MagicMock(title="Doc 2", snippet="Second result"),
            ]
            result = search_docs("test query")
            assert "Doc 1" in result
            assert "Doc 2" in result

    def test_empty_search(self):
        """Search with no results."""
        with patch("my_server.server.perform_search", return_value=[]):
            assert search_docs("nonexistent") == ""

    def test_search_error(self):
        """Upstream failure propagates."""
        with patch("my_server.server.perform_search", side_effect=ConnectionError("API down")):
            with pytest.raises(ConnectionError):
                search_docs("test")


class TestCreateTicket:
    def test_create_ticket(self):
        """Ticket creation returns confirmation."""
        with patch("my_server.server.api") as mock_api:
            mock_api.create.return_value = MagicMock(id=42, url="https://example.com/42")
            result = create_ticket("Bug report", "Something broke", "high")
            assert "#42" in result
            assert "https://example.com/42" in result

    def test_create_ticket_rejects_empty_title(self):
        """The function's own validation (MCPServer validates types before the call)."""
        from mcp.server.mcpserver.exceptions import ToolError
        with pytest.raises(ToolError):
            create_ticket("", "body", "medium")
```

### Testing Through the Protocol: the in-memory `Client`

`Client(mcp)` connects to the server object in process, with no transport. It replaces
v1's `create_connected_server_and_client_session()`. It negotiates **2026-07-28** by
default, so a tool that still calls `ctx.elicit()` fails here (`NoBackChannelError`);
pass `mode="legacy"` to test 2025-era behaviour. The SDK docs run tests on anyio:

```python
# test_server.py
import pytest
from mcp import Client

from server import mcp


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def client():
    async with Client(mcp, raise_exceptions=True) as c:
        yield c


@pytest.mark.anyio
async def test_add_tool(client: Client):
    result = await client.call_tool("add", {"a": 2, "b": 3})
    assert not result.is_error
    assert result.content[0].text == "5"
    assert result.structured_content == {"result": 5}


@pytest.mark.anyio
async def test_tool_is_listed(client: Client):
    tools = await client.list_tools()
    assert any(t.name == "add" for t in tools.tools)


@pytest.mark.anyio
async def test_resource(client: Client):
    content = await client.read_resource("config://test")
    assert '"key"' in content.contents[0].text


@pytest.mark.anyio
async def test_tool_error_reaches_model(client: Client):
    result = await client.call_tool("get_author", {"title": "Nothing"})
    assert result.is_error                       # a ToolError, not an exception
```

Results are v2 types with snake_case attributes (`is_error`, `structured_content`).
Assert on the outcome, not on the `_meta` server-identity stamp, which every 2026-era
result carries. Source: [Python SDK Testing](https://py.sdk.modelcontextprotocol.io/get-started/testing/).

### Testing Async Tools

```python
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

@pytest.mark.anyio
async def test_async_tool():
    """Test an async tool handler with a mocked HTTP client."""
    mock_response = MagicMock(text='{"data": "test"}')
    mock_response.raise_for_status = MagicMock()
    mock_instance = AsyncMock()
    mock_instance.get.return_value = mock_response

    with patch("my_server.server.httpx.AsyncClient") as MockClient:
        MockClient.return_value.__aenter__.return_value = mock_instance
        MockClient.return_value.__aexit__.return_value = False

        result = await fetch_data("https://example.com/api")
        assert "test" in result
```

## Unit Testing Tools (TypeScript)

### Testing with vitest: in-process HTTP handler (both eras)

The SDK's own testing guide drives `createMcpHandler` in process through a
`StreamableHTTPClientTransport` whose `fetch` never touches the network:

```typescript
// tools.test.ts
import { describe, it, expect, beforeEach } from "vitest";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { createMcpHandler, McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";

function createServer() {
  const server = new McpServer({ name: "test", version: "1.0.0" });
  server.registerTool(
    "search",
    { description: "Search docs", inputSchema: z.object({ query: z.string() }) },
    async ({ query }) => ({ content: [{ type: "text", text: (await mockSearch(query)).join("\n") }] })
  );
  return server;
}

describe("search tool", () => {
  let client: Client;

  beforeEach(async () => {
    const handler = createMcpHandler(createServer);
    const transport = new StreamableHTTPClientTransport(new URL("http://test.local/mcp"), {
      fetch: (url, init) => handler.fetch(new Request(url, init)),
    });
    client = new Client({ name: "test-client", version: "1.0.0" }, { versionNegotiation: { mode: "auto" } });
    await client.connect(transport);
  });

  it("returns search results", async () => {
    const result = await client.callTool({ name: "search", arguments: { query: "test" } });
    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe("text");
  });

  it("lists tools", async () => {
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name)).toEqual(["search"]);
  });
});
```

For 2025-era-only tests, `InMemoryTransport.createLinkedPair()` still works. Take
**both** halves from the same package (`@modelcontextprotocol/server` or `/client`), since
the two packages bundle separate copies. Source:
[TS SDK Test a server](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/testing.md).

### Testing Error Handling

```typescript
describe("error handling", () => {
  it("returns isError for invalid input", async () => {
    const result = await client.callTool({ name: "query_db", arguments: { sql: "DELETE FROM users" } });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Only SELECT queries");
  });

  it("rejects an unknown tool", async () => {
    await expect(client.callTool({ name: "nonexistent", arguments: {} })).rejects.toThrow();
  });
});
```

## Integration Testing

### Full Server Integration Test (Python, stdio subprocess)

`Client` takes `StdioServerParameters` to spawn the server as a subprocess. It replaces
v1's `stdio_client` + `ClientSession` + `initialize()` layering:

```python
import pytest
from mcp import Client, StdioServerParameters

@pytest.mark.anyio
async def test_server_integration():
    """Test the full server by spawning it as a subprocess."""
    params = StdioServerParameters(command="uv", args=["run", "python", "server.py"],
                                   env={"API_KEY": "test-key"})
    async with Client(params) as client:
        tools = await client.list_tools()
        assert "search" in [t.name for t in tools.tools]

        result = await client.call_tool("search", {"query": "test"})
        assert result.content and result.content[0].type == "text"

        resources = await client.list_resources()
        assert resources.resources

        content = await client.read_resource("config://app")
        assert content.contents
```

### Integration Test with HTTP Transport

Use the SDK `Client` against the URL rather than hand-written JSON-RPC. It negotiates
the era and sends the required headers, which raw `httpx` posts get wrong:

```python
import os
import subprocess
import time

import httpx
import pytest
from mcp import Client

PORT = 8765

@pytest.fixture(scope="module")
def server_process():
    """Start the MCP server (it calls mcp.run(transport="streamable-http", port=PORT))."""
    proc = subprocess.Popen(["uv", "run", "python", "server.py"],
                            env={**os.environ, "API_KEY": "test-key", "PORT": str(PORT)})
    deadline = time.time() + 15
    while time.time() < deadline:          # poll instead of a fixed sleep
        try:
            httpx.get(f"http://127.0.0.1:{PORT}/mcp", timeout=0.5)
            break
        except httpx.TransportError:
            time.sleep(0.2)
    yield proc
    proc.terminate()
    proc.wait()

@pytest.mark.anyio
async def test_http_server(server_process):
    async with Client(f"http://127.0.0.1:{PORT}/mcp") as client:
        tools = await client.list_tools()
        assert tools.tools
        assert client.protocol_version            # negotiated era, e.g. "2026-07-28"
```

## Mock Clients

### Python Mock Client

For code that *consumes* an MCP client (a gateway, an agent loop), mock the client
with real v2 result types:

```python
from unittest.mock import AsyncMock

from mcp.types import CallToolResult, ListToolsResult, TextContent, Tool

def create_mock_client():
    """Create a mock MCP client for testing code that calls MCP servers."""
    client = AsyncMock()
    client.list_tools.return_value = ListToolsResult(tools=[
        Tool(name="search", description="Search docs", input_schema={
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        }),
    ])

    async def mock_call_tool(name, arguments):
        if name == "search":
            return CallToolResult(content=[TextContent(type="text", text="Mock result for: " + arguments["query"])])
        return CallToolResult(content=[TextContent(type="text", text=f"Unknown tool: {name}")], is_error=True)

    client.call_tool = AsyncMock(side_effect=mock_call_tool)
    return client
```

## Protocol Debugging

### Logging JSON-RPC Messages

```python
import json
import logging
import sys

# stdio servers: log to stderr only
logging.basicConfig(stream=sys.stderr, level=logging.DEBUG)
logger = logging.getLogger("mcp.protocol")

class MessageLogger:
    def log_request(self, method: str, params: dict, id: int):
        logger.debug(f"→ [{id}] {method}: {json.dumps(params, indent=2)}")

    def log_response(self, id: int, result: dict):
        logger.debug(f"← [{id}] Result: {json.dumps(result, indent=2, default=str)[:500]}")

    def log_notification(self, method: str, params: dict):
        logger.debug(f"→ (notif) {method}: {json.dumps(params, indent=2)}")

    def log_error(self, id: int, error: dict):
        logger.error(f"← [{id}] Error: {json.dumps(error, indent=2)}")
```

Python v2 also traces every request with OpenTelemetry by default (a server span per
request, joined to the client's span when both ends run the SDK). Configure an exporter
to see them.

### Capturing Messages for Replay

```python
import json
from datetime import datetime, timezone

class MessageCapture:
    """Capture MCP messages for debugging and replay."""

    def __init__(self, output_file: str = "mcp_capture.jsonl"):
        self.output_file = output_file
        self.messages = []

    def capture(self, direction: str, message: dict):
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "direction": direction,  # "sent" or "received"
            "message": message,
        }
        self.messages.append(entry)
        with open(self.output_file, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def replay(self) -> list[dict]:
        """Load captured messages for analysis."""
        with open(self.output_file) as f:
            return [json.loads(line) for line in f]
```

### Common Protocol Issues

| Issue | Symptom | Diagnosis |
|-------|---------|-----------|
| Missing `jsonrpc` field | Server returns parse error | Check all messages include `"jsonrpc": "2.0"` |
| Wrong method name | `-32601` Method not found | Verify against spec: `tools/call` not `tool/call` (v2 returns `-32601` for any unknown method) |
| Missing `id` on request | No response received | All requests need unique `id`; notifications don't |
| `params` vs `arguments` | Tool gets empty args | `tools/call` uses `params.arguments` for tool args; v2 low-level handlers may receive `None` |
| Content format wrong | Result fails validation | v2 validates results before sending: `{"content": [{"type": "text", "text": "..."}]}` |
| Protocol version mismatch | `-32022` unsupported protocol version | 2025-era: `"2025-11-25"` in `initialize`; 2026: `"2026-07-28"` per request. Let the SDK `Client` negotiate |
| `421 Invalid Host header` | HTTP server rejects the request | DNS-rebinding protection: add the host to `transport_security` allowed hosts, include the port |
| `-32021` missing client capability | Elicitation/sampling call rejected | The client never declared `elicitation` / `sampling`; set the callback on the client |
| Resource not found code | Client expects `-32002` | v2 returns `-32602` with the URI in `error.data` |
| `ping` fails on a modern connection | `Method not found` | `ping` was removed at 2026-07-28. Pin `mode="legacy"` for health checks that need it |

## Common Issues and Solutions

### Server Not Starting

```bash
# Check 1: Can you run the server directly?
uv run python server.py
# If this fails, fix the Python/dependency issues first

# Check 2: Does the command path exist?
which uv    # or: which python, which npx

# Check 3: Which SDK major is installed? (v2 renamed FastMCP to MCPServer)
uv pip show mcp

# Check 4: Check stderr for errors (stdio servers)
# Add to server.py:
#   import sys; print("Server starting...", file=sys.stderr)
```

`ModuleNotFoundError: No module named 'mcp.server.fastmcp'` means v1 code met a v2
install. Port it (`from mcp.server import MCPServer`) or pin `mcp<2`.

### Tool Not Appearing in Client

```python
# Check 1: Does tools/list work? Use the Inspector:
#   npx @modelcontextprotocol/inspector --cli uv run python server.py --method tools/list

# Check 2: Is the tool registered correctly? Verify with a trivial tool:
@mcp.tool()
def test_tool() -> str:
    """A test tool that always works."""
    return "Tool is working!"

# Check 3: Invalid inputSchema on a hand-built Tool
# v2 fails tools/list if a schema lacks "type": "object"
# BAD:  {"type": "str"} or {}
# GOOD: {"type": "object", "properties": {"q": {"type": "string"}}}
```

### Auth Failures

```python
# Check 1: Are env vars set in the CLIENT config, not just your shell?
# Claude Desktop reads env from claude_desktop_config.json, NOT your shell profile.
# Python v2 no longer reads MCP_* variables or .env files for server settings.

# Check 2: Verify env vars are accessible (debugging only; never return secret values)
@mcp.tool()
def debug_env() -> str:
    """Show which app env vars are set."""
    import os
    return json.dumps({k: "set" for k in os.environ if k.startswith("MY_")})

# Check 3: Token expiration - log refresh times to stderr
```

`token_verifier=` and `auth=` must be passed together, or `MCPServer(...)` raises
`ValueError` at startup.

### Timeout Errors

```python
# Check 1: Add timeouts to all external calls
async with httpx.AsyncClient(timeout=30.0) as client:
    resp = await client.get(url)

# Check 2: Break long operations into steps, with progress
@mcp.tool()
async def process_large_dataset(dataset_id: str, ctx: Context) -> str:
    """Process a large dataset in chunks with progress."""
    chunks = get_chunks(dataset_id)
    results = []
    for i, chunk in enumerate(chunks):
        await ctx.report_progress(i, len(chunks))
        results.append(await process_chunk(chunk))
    return json.dumps({"processed": len(results)})

# Check 3: Return a summary instead of full data
@mcp.tool()
def query_large_table(table: str) -> str:
    """Query a table, returning summary + sample."""
    count = db.count(table)
    sample = db.query(f"SELECT * FROM {table} LIMIT 10")
    return json.dumps({
        "total_rows": count,
        "sample": sample,
        "message": f"Showing 10 of {count} rows. Use pagination for more.",
    }, default=str)
```

Client timeouts are `float` seconds in Python v2 (not `timedelta`). A timed-out request
now cancels the server-side handler and raises `-32001` (`REQUEST_TIMEOUT`).

### JSON Parse Errors

```python
# Check 1: Don't print to stdout in stdio servers - stdout IS the protocol channel.
# (Python v2 diverts stray prints to stderr while serving; TypeScript does not.)
import sys
print("Debug info", file=sys.stderr)  # Correct

# Check 2: Ensure tool results are serializable
@mcp.tool()
def get_data() -> str:
    result = db.query("SELECT * FROM users")
    return json.dumps(result, default=str)   # datetimes etc. need default=str
```

## CI Testing

### GitHub Actions

```yaml
# .github/workflows/test-mcp.yml
name: Test MCP Server
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install uv
        uses: astral-sh/setup-uv@v4

      - name: Install dependencies
        run: uv sync

      - name: Run unit + in-memory protocol tests
        run: uv run pytest tests/ -v

      - name: Run integration tests
        run: uv run pytest tests/integration/ -v
        env:
          API_KEY: ${{ secrets.TEST_API_KEY }}

      - uses: actions/setup-node@v4
        with:
          node-version: "22"

      - name: Smoke-test with the Inspector CLI (pin an exact version in CI)
        run: |
          npx --yes @modelcontextprotocol/inspector@2.12.0 --cli uv run python server.py \
            --method tools/list --format json | jq -e '.result.tools | length > 0'
```

`--yes` suppresses the first-run install prompt that would hang an unattended job. A
range like `@2` is not a pin. The Inspector CLI exits `0`-`5` by failure class, so
branch on the code rather than parsing stderr. `2.12.0` was the latest release on
2026-10-22.

### Docker-Based Testing

```dockerfile
# Dockerfile.test
FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/
WORKDIR /app
COPY . .
RUN uv sync
RUN uv run pytest tests/ -v
```

```yaml
# docker-compose.test.yml
services:
  test:
    build:
      context: .
      dockerfile: Dockerfile.test
    environment:
      - API_KEY=test-key
      - DATABASE_URL=postgresql://postgres:test@db:5432/testdb
    depends_on:
      - db
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: test
      POSTGRES_DB: testdb
```

```bash
docker compose -f docker-compose.test.yml up --build --abort-on-container-exit
```

The Python SDK v2 verifies TLS through the OS trust store (`truststore`). A minimal image
with no CA store fails outbound HTTPS from the SDK client, so install `ca-certificates`
or set `SSL_CERT_FILE`.

## Performance Testing

### Concurrent Tool Calls

```python
import asyncio
import time

import pytest
from mcp import Client

@pytest.mark.anyio
async def test_concurrent_tool_calls():
    """Server handles concurrent requests correctly."""
    async with Client(mcp) as client:
        start = time.time()
        results = await asyncio.gather(*[
            client.call_tool("search", {"query": f"test-{i}"}) for i in range(20)
        ])
        elapsed = time.time() - start

        assert len(results) == 20
        assert all(not r.is_error for r in results)
        print(f"20 concurrent calls completed in {elapsed:.2f}s")
```

v2 runs sync `def` tools on worker threads, so they can now run concurrently with each
other. A thread-unsafe tool that passed this test on v1 can fail it on v2.

### Large Payload Handling

```python
import json

@pytest.mark.anyio
async def test_large_response():
    """Server handles large responses without issues."""
    async with Client(mcp) as client:
        result = await client.call_tool("generate_report", {"size": "large"})
        text = result.content[0].text
        assert len(text) > 10000
        assert "report" in json.loads(text)

@pytest.mark.anyio
async def test_response_size_limit():
    """Server paginates or truncates oversized responses."""
    async with Client(mcp) as client:
        result = await client.call_tool("get_all_data", {})
        assert len(result.content[0].text) < 1_000_000  # Under 1MB
```

The Python v2 Streamable HTTP server also rejects **request** bodies over 4 MiB (HTTP 413).

### Memory Usage

```python
import tracemalloc

@pytest.mark.anyio
async def test_memory_usage():
    """Tool calls don't leak memory."""
    tracemalloc.start()

    async with Client(mcp) as client:
        snapshot1 = tracemalloc.take_snapshot()
        for i in range(100):
            await client.call_tool("search", {"query": f"test-{i}"})
        snapshot2 = tracemalloc.take_snapshot()
        stats = snapshot2.compare_to(snapshot1, "lineno")

        for stat in stats[:5]:
            assert stat.size_diff < 10 * 1024 * 1024, f"Memory leak detected: {stat}"

    tracemalloc.stop()
```

## Debugging Tools

### Claude Desktop Logs

```bash
# macOS
tail -f ~/Library/Logs/Claude/mcp-server-*.log
```

```powershell
# Windows
Get-Content "$env:APPDATA\Claude\Logs\mcp-server-*.log" -Wait
```

Look for server startup errors, tool call failures, and transport disconnections.

### Custom Debug Tool

Add a debug tool to your server for troubleshooting:

```python
import json
import os
import platform
import sys

@mcp.tool()
def server_debug_info() -> str:
    """Return server diagnostic information (remove in production)."""
    return json.dumps({
        "python_version": sys.version,
        "platform": platform.platform(),
        "cwd": os.getcwd(),
        "env_vars": {k: "***" for k in os.environ if k.startswith("MY_")},
        "pid": os.getpid(),
        "argv": sys.argv,
    }, indent=2)
```

### Stderr Logging for stdio Servers

Since stdout is the protocol channel, use stderr for all debugging:

```python
import logging
import sys

logging.basicConfig(
    stream=sys.stderr,
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("my-server")

@mcp.tool()
def my_tool(query: str) -> str:
    logger.debug(f"my_tool called with query={query!r}")
    try:
        result = process(query)
        logger.info(f"my_tool succeeded: {len(result)} chars")
        return result
    except Exception:
        logger.exception("my_tool failed")
        raise
```

## Error Reproduction

### Capturing and Replaying Protocol Messages

```python
import json
import time

class ProtocolRecorder:
    """Record MCP protocol messages for reproduction."""

    def __init__(self, output_path: str = "mcp_recording.jsonl"):
        self.output_path = output_path
        self._file = open(output_path, "w")

    def record(self, direction: str, message: dict):
        self._file.write(json.dumps({
            "direction": direction,
            "message": message,
            "timestamp": time.time(),
        }) + "\n")
        self._file.flush()

    def close(self):
        self._file.close()


class ProtocolReplayer:
    """Replay recorded tools/call requests against a server via an SDK Client."""

    def __init__(self, recording_path: str):
        with open(recording_path) as f:
            self.entries = [json.loads(line) for line in f]

    async def replay(self, client):
        sent = [e["message"] for e in self.entries if e["direction"] == "sent"]
        received = {e["message"].get("id"): e["message"]
                    for e in self.entries if e["direction"] == "received"}

        for msg in sent:
            if msg.get("method") == "tools/call":
                params = msg.get("params", {})
                result = await client.call_tool(params["name"], params.get("arguments") or {})
                expected = received.get(msg.get("id"))
                if expected:
                    got = result.model_dump(by_alias=True, exclude_none=True)   # camelCase wire shape
                    print(f"[tools/call {params['name']}] match: {got == expected.get('result')}")
```

Responses are matched by JSON-RPC `id`, not by list position. Strip `_meta` before
comparing 2026-era results, because they carry a server-identity stamp.

### Minimal Reproduction Script

When filing bug reports, create a minimal reproduction:

```python
#!/usr/bin/env python3
"""Minimal reproduction for MCP issue #XXX.

Run:  uv run python repro.py
Test: npx @modelcontextprotocol/inspector uv run python repro.py
Env:  mcp==<exact version from `uv pip show mcp`>
"""
from mcp.server import MCPServer

mcp = MCPServer("repro-server")

@mcp.tool()
def trigger_bug(input: str) -> str:
    """This tool demonstrates the bug."""
    return problematic_operation(input)

if __name__ == "__main__":
    mcp.run()
```
