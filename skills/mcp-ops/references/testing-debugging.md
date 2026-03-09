# Testing and Debugging

## MCP Inspector

The MCP Inspector is an interactive debugging tool for testing MCP servers without a full client setup.

### Installation and Usage

```bash
# Run directly with npx (no install needed)
npx @modelcontextprotocol/inspector

# Connect to a stdio server
npx @modelcontextprotocol/inspector -- uv run python server.py

# Connect to a stdio server with env vars
npx @modelcontextprotocol/inspector -e API_KEY=sk-key -- uv run python server.py

# Connect to an SSE server
npx @modelcontextprotocol/inspector --url http://localhost:8000/sse

# Connect to a Streamable HTTP server
npx @modelcontextprotocol/inspector --url http://localhost:8000/mcp
```

### What You Can Do with Inspector

| Feature | How |
|---------|-----|
| List tools | Click "Tools" tab to see all registered tools |
| Call tools | Fill in arguments and click "Call" |
| List resources | Click "Resources" tab |
| Read resources | Click any resource to see its contents |
| List prompts | Click "Prompts" tab |
| Get prompts | Fill in arguments and see rendered prompt |
| View messages | "Messages" tab shows raw JSON-RPC traffic |
| Test notifications | See server notifications in real-time |

### Inspecting Protocol Messages

The Inspector shows raw JSON-RPC messages. Use this to verify:

- Request format matches the MCP specification
- Response content is properly structured
- Error codes and messages are correct
- Notifications are sent at the right times

```
Example Inspector message log:

→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
← {"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{}},...}}
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search",...}]}}
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"test"}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"..."}]}}
```

## Unit Testing Tools (Python)

### Testing with pytest

```python
# test_tools.py
import pytest
import json
from unittest.mock import AsyncMock, patch, MagicMock

# Test tool functions directly (they're just functions)
from my_server.server import search_docs, create_ticket

class TestSearchDocs:
    def test_basic_search(self):
        """Test search returns formatted results."""
        with patch("my_server.server.perform_search") as mock_search:
            mock_search.return_value = [
                MagicMock(title="Doc 1", snippet="First result"),
                MagicMock(title="Doc 2", snippet="Second result"),
            ]
            result = search_docs("test query")
            assert "Doc 1" in result
            assert "Doc 2" in result
            mock_search.assert_called_once_with("test query")

    def test_empty_search(self):
        """Test search with no results."""
        with patch("my_server.server.perform_search") as mock_search:
            mock_search.return_value = []
            result = search_docs("nonexistent")
            assert result == ""

    def test_search_error(self):
        """Test search handles errors gracefully."""
        with patch("my_server.server.perform_search") as mock_search:
            mock_search.side_effect = ConnectionError("API down")
            with pytest.raises(ConnectionError):
                search_docs("test")


class TestCreateTicket:
    def test_create_ticket(self):
        """Test ticket creation returns confirmation."""
        with patch("my_server.server.api") as mock_api:
            mock_api.create.return_value = MagicMock(id=42, url="https://example.com/42")
            result = create_ticket("Bug report", "Something broke", "high")
            assert "#42" in result
            assert "https://example.com/42" in result

    def test_create_ticket_validation(self):
        """Test ticket creation validates required fields."""
        # FastMCP validates types before calling the function
        # Test the function's own validation
        with pytest.raises(ValueError):
            create_ticket("", "body", "medium")  # Empty title
```

### Testing Async Tools

```python
import pytest
import asyncio

@pytest.mark.asyncio
async def test_async_tool():
    """Test an async tool handler."""
    with patch("my_server.server.httpx.AsyncClient") as mock_client:
        mock_response = AsyncMock()
        mock_response.text = '{"data": "test"}'
        mock_response.raise_for_status = MagicMock()
        mock_client.return_value.__aenter__ = AsyncMock(return_value=mock_response)
        mock_client.return_value.__aexit__ = AsyncMock(return_value=False)

        # Better: use a real mock client
        mock_instance = AsyncMock()
        mock_instance.get.return_value = mock_response

        with patch("my_server.server.httpx.AsyncClient") as MockClient:
            MockClient.return_value.__aenter__.return_value = mock_instance
            MockClient.return_value.__aexit__.return_value = False

            result = await fetch_data("https://example.com/api")
            assert "test" in result
```

### Testing with FastMCP Test Client

```python
import pytest
from mcp.server.fastmcp import FastMCP

# Create a test server
mcp = FastMCP("test-server")

@mcp.tool()
def add(a: int, b: int) -> str:
    """Add two numbers."""
    return str(a + b)

@mcp.resource("config://test")
def get_config() -> str:
    return '{"key": "value"}'

@pytest.mark.asyncio
async def test_tool_via_mcp():
    """Test tools through the MCP protocol layer."""
    async with mcp.test_client() as client:
        # List tools
        tools = await client.list_tools()
        assert any(t.name == "add" for t in tools)

        # Call a tool
        result = await client.call_tool("add", {"a": 2, "b": 3})
        assert result[0].text == "5"

@pytest.mark.asyncio
async def test_resource_via_mcp():
    """Test resources through the MCP protocol layer."""
    async with mcp.test_client() as client:
        resources = await client.list_resources()
        assert any(r.uri == "config://test" for r in resources)

        content = await client.read_resource("config://test")
        assert '"key"' in content[0].text
```

## Unit Testing Tools (TypeScript)

### Testing with vitest

```typescript
// tools.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { z } from "zod";

describe("search tool", () => {
  let server: McpServer;
  let client: Client;

  beforeEach(async () => {
    server = new McpServer({ name: "test", version: "1.0.0" });

    server.tool("search", "Search docs", { query: z.string() }, async ({ query }) => {
      // In real code, this calls an external service
      const results = await mockSearch(query);
      return {
        content: [{ type: "text", text: results.join("\n") }],
      };
    });

    // Connect via in-memory transport
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);

    client = new Client({ name: "test-client", version: "1.0.0" });
    await client.connect(clientTransport);
  });

  it("should return search results", async () => {
    const result = await client.callTool({ name: "search", arguments: { query: "test" } });
    expect(result.content).toHaveLength(1);
    expect(result.content[0].type).toBe("text");
  });

  it("should list tools", async () => {
    const tools = await client.listTools();
    expect(tools.tools).toHaveLength(1);
    expect(tools.tools[0].name).toBe("search");
  });
});
```

### Testing Error Handling

```typescript
describe("error handling", () => {
  it("should return isError for invalid input", async () => {
    const result = await client.callTool({
      name: "query_db",
      arguments: { sql: "DELETE FROM users" },
    });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Only SELECT queries");
  });

  it("should handle tool not found", async () => {
    await expect(
      client.callTool({ name: "nonexistent", arguments: {} })
    ).rejects.toThrow();
  });
});
```

## Integration Testing

### Full Server Integration Test (Python)

```python
import pytest
import asyncio
from mcp import ClientSession
from mcp.client.stdio import stdio_client

@pytest.mark.asyncio
async def test_server_integration():
    """Test the full server by spawning it as a subprocess."""
    async with stdio_client(
        command="uv",
        args=["run", "python", "server.py"],
        env={"API_KEY": "test-key"},
    ) as (read, write):
        async with ClientSession(read, write) as session:
            # Initialize
            await session.initialize()

            # List tools
            tools = await session.list_tools()
            tool_names = [t.name for t in tools.tools]
            assert "search" in tool_names

            # Call a tool
            result = await session.call_tool("search", {"query": "test"})
            assert len(result.content) > 0
            assert result.content[0].type == "text"

            # List resources
            resources = await session.list_resources()
            assert len(resources.resources) > 0

            # Read a resource
            content = await session.read_resource("config://app")
            assert len(content.contents) > 0
```

### Integration Test with HTTP Transport

```python
import pytest
import httpx
import subprocess
import time

@pytest.fixture(scope="module")
def server_process():
    """Start the MCP server as a subprocess."""
    proc = subprocess.Popen(
        ["uv", "run", "python", "server.py", "--transport", "streamable-http", "--port", "8765"],
        env={**os.environ, "API_KEY": "test-key"},
    )
    time.sleep(2)  # Wait for server to start
    yield proc
    proc.terminate()
    proc.wait()

@pytest.mark.asyncio
async def test_http_server(server_process):
    """Test the server via HTTP transport."""
    async with httpx.AsyncClient(base_url="http://localhost:8765") as client:
        # Initialize
        resp = await client.post("/mcp", json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1.0.0"},
            },
        })
        assert resp.status_code == 200
        result = resp.json()["result"]
        assert "capabilities" in result

        # List tools
        resp = await client.post("/mcp", json={
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        })
        tools = resp.json()["result"]["tools"]
        assert len(tools) > 0
```

## Mock Clients

### Python Mock Client

```python
from unittest.mock import AsyncMock
from mcp.types import TextContent, CallToolResult

def create_mock_session():
    """Create a mock MCP session for testing."""
    session = AsyncMock()

    # Mock tool listing
    session.list_tools.return_value = MockToolList(tools=[
        MockTool(name="search", description="Search docs", inputSchema={
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        }),
    ])

    # Mock tool calls
    async def mock_call_tool(name, arguments):
        if name == "search":
            return CallToolResult(
                content=[TextContent(type="text", text="Mock result for: " + arguments["query"])]
            )
        raise ValueError(f"Unknown tool: {name}")

    session.call_tool = AsyncMock(side_effect=mock_call_tool)
    return session
```

## Protocol Debugging

### Logging JSON-RPC Messages

```python
import logging
import json

# Enable protocol-level logging
logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger("mcp.protocol")

# Custom message logger
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

### Capturing Messages for Replay

```python
import json
from datetime import datetime

class MessageCapture:
    """Capture MCP messages for debugging and replay."""

    def __init__(self, output_file: str = "mcp_capture.jsonl"):
        self.output_file = output_file
        self.messages = []

    def capture(self, direction: str, message: dict):
        entry = {
            "timestamp": datetime.utcnow().isoformat(),
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
| Wrong method name | Method not found error | Verify against spec: `tools/call` not `tool/call` |
| Missing `id` on request | No response received | All requests need unique `id`; notifications don't |
| `params` vs `arguments` | Tool gets empty args | `tools/call` uses `params.arguments` for tool args |
| Content format wrong | Client shows raw object | Must be `[{"type": "text", "text": "..."}]` |
| Protocol version mismatch | Initialize fails | Use `"2025-03-26"` (check spec for latest) |

## Common Issues and Solutions

### Server Not Starting

```bash
# Check 1: Can you run the server directly?
uv run python server.py
# If this fails, fix the Python/dependency issues first

# Check 2: Does the command path exist?
which uv    # or: which python, which npx
# Ensure the command is on PATH

# Check 3: Are dependencies installed?
cd /path/to/server && uv pip list | grep mcp

# Check 4: Check stderr for errors (stdio servers)
# Add to server.py:
import sys
print("Server starting...", file=sys.stderr)
```

### Tool Not Appearing in Client

```python
# Check 1: Does list_tools work?
# Use MCP Inspector to verify
npx @modelcontextprotocol/inspector -- uv run python server.py

# Check 2: Is the tool registered correctly?
# Verify with a simple test:
@mcp.tool()
def test_tool() -> str:
    """A test tool that always works."""
    return "Tool is working!"

# Check 3: Invalid inputSchema
# Ensure schema is valid JSON Schema
# Common mistake: using Python types instead of JSON Schema types
# BAD: {"type": "str"}
# GOOD: {"type": "string"}
```

### Auth Failures

```python
# Check 1: Are env vars set in the CLIENT config, not just your shell?
# Claude Desktop reads env from claude_desktop_config.json, NOT your shell profile

# Check 2: Verify env vars are accessible
@mcp.tool()
def debug_env() -> str:
    """Show environment variables (for debugging only)."""
    import os
    return json.dumps({
        k: v[:5] + "..." if len(v) > 5 else v
        for k, v in os.environ.items()
        if k.startswith("MY_")  # Only show your app's vars
    })

# Check 3: Token expiration
# Add logging to token refresh:
import sys
print(f"Token expires at: {expires_at}", file=sys.stderr)
```

### Timeout Errors

```python
# Check 1: Add timeouts to all external calls
async with httpx.AsyncClient(timeout=30.0) as client:
    resp = await client.get(url)

# Check 2: Break long operations into steps
@mcp.tool()
async def process_large_dataset(dataset_id: str, ctx: Context) -> str:
    """Process a large dataset in chunks with progress."""
    chunks = get_chunks(dataset_id)
    results = []
    for i, chunk in enumerate(chunks):
        await ctx.report_progress(i, len(chunks))
        results.append(await process_chunk(chunk))
    return json.dumps({"processed": len(results)})

# Check 3: Use streaming for large responses
# Return a summary instead of full data
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

### JSON Parse Errors

```python
# Check 1: Don't print to stdout in stdio servers!
# stdout IS the protocol channel. Use stderr for logging.
import sys
print("Debug info", file=sys.stderr)  # Correct
# print("Debug info")  # WRONG - corrupts protocol stream

# Check 2: Ensure tool results are serializable
@mcp.tool()
def get_data() -> str:
    result = db.query("SELECT * FROM users")
    # BAD: datetime objects aren't JSON serializable by default
    # return json.dumps(result)

    # GOOD: handle non-serializable types
    return json.dumps(result, default=str)
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

      - name: Run unit tests
        run: uv run pytest tests/ -v

      - name: Run integration tests
        run: uv run pytest tests/integration/ -v
        env:
          API_KEY: ${{ secrets.TEST_API_KEY }}

      - name: Test server starts
        run: |
          uv run python server.py &
          SERVER_PID=$!
          sleep 3
          # Verify server is running
          kill -0 $SERVER_PID 2>/dev/null && echo "Server started successfully"
          kill $SERVER_PID

      - name: Test with MCP Inspector
        run: |
          npx @modelcontextprotocol/inspector --test -- uv run python server.py
```

### Docker-Based Testing

```dockerfile
# Dockerfile.test
FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN pip install uv && uv sync
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

## Performance Testing

### Concurrent Tool Calls

```python
import pytest
import asyncio
import time

@pytest.mark.asyncio
async def test_concurrent_tool_calls():
    """Test server handles concurrent requests correctly."""
    async with mcp.test_client() as client:
        start = time.time()

        # Fire 20 concurrent tool calls
        tasks = [
            client.call_tool("search", {"query": f"test-{i}"})
            for i in range(20)
        ]
        results = await asyncio.gather(*tasks)
        elapsed = time.time() - start

        assert len(results) == 20
        assert all(len(r) > 0 for r in results)
        print(f"20 concurrent calls completed in {elapsed:.2f}s")
```

### Large Payload Handling

```python
@pytest.mark.asyncio
async def test_large_response():
    """Test server handles large responses without issues."""
    async with mcp.test_client() as client:
        result = await client.call_tool("generate_report", {
            "size": "large",  # Generates a multi-KB response
        })
        assert len(result[0].text) > 10000
        # Verify it's valid JSON
        data = json.loads(result[0].text)
        assert "report" in data

@pytest.mark.asyncio
async def test_response_size_limit():
    """Verify server truncates oversized responses."""
    async with mcp.test_client() as client:
        result = await client.call_tool("get_all_data", {})
        text = result[0].text
        # Server should paginate or truncate
        assert len(text) < 1_000_000  # Under 1MB
```

### Memory Usage

```python
import tracemalloc

@pytest.mark.asyncio
async def test_memory_usage():
    """Test that tool calls don't leak memory."""
    tracemalloc.start()

    async with mcp.test_client() as client:
        snapshot1 = tracemalloc.take_snapshot()

        # Run 100 tool calls
        for i in range(100):
            await client.call_tool("search", {"query": f"test-{i}"})

        snapshot2 = tracemalloc.take_snapshot()
        stats = snapshot2.compare_to(snapshot1, "lineno")

        # Check no single allocation grew more than 10MB
        for stat in stats[:5]:
            assert stat.size_diff < 10 * 1024 * 1024, f"Memory leak detected: {stat}"

    tracemalloc.stop()
```

## Debugging Tools

### Claude Desktop Logs

```bash
# macOS
tail -f ~/Library/Logs/Claude/mcp-server-*.log

# Windows
Get-Content "$env:APPDATA\Claude\Logs\mcp-server-*.log" -Wait

# Look for:
# - Server startup errors
# - Tool call failures
# - Transport disconnections
```

### Custom Debug Server

Add a debug tool to your server for troubleshooting:

```python
import sys
import os
import platform

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
import sys
import logging

# Configure logging to stderr
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
    """Replay recorded messages against a server."""

    def __init__(self, recording_path: str):
        with open(recording_path) as f:
            self.entries = [json.loads(line) for line in f]

    async def replay(self, session):
        """Replay recorded messages and compare responses."""
        sent = [e for e in self.entries if e["direction"] == "sent"]
        received = [e for e in self.entries if e["direction"] == "received"]

        for i, entry in enumerate(sent):
            msg = entry["message"]
            if "id" in msg:
                # It's a request
                method = msg["method"]
                params = msg.get("params", {})
                if method == "tools/call":
                    result = await session.call_tool(
                        params["name"],
                        params.get("arguments", {}),
                    )
                    # Compare with recorded response
                    expected = received[i] if i < len(received) else None
                    if expected:
                        print(f"[{method}] Match: {result == expected['message']['result']}")
```

### Minimal Reproduction Script

When filing bug reports, create a minimal reproduction:

```python
#!/usr/bin/env python3
"""Minimal reproduction for MCP issue #XXX.

Run: uv run python repro.py
Test: npx @modelcontextprotocol/inspector -- uv run python repro.py
"""
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("repro-server")

@mcp.tool()
def trigger_bug(input: str) -> str:
    """This tool demonstrates the bug."""
    # Minimal code that triggers the issue
    result = problematic_operation(input)
    return result

if __name__ == "__main__":
    mcp.run()
```
