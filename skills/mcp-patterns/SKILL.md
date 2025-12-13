# MCP Patterns Skill

Model Context Protocol (MCP) server patterns for building integrations with Claude Code.

## Triggers

mcp server, model context protocol, tool handler, mcp resource, mcp tool

## Server Structure

### Basic MCP Server (Python)
```python
from mcp.server import Server
from mcp.server.stdio import stdio_server

app = Server("my-server")

@app.list_tools()
async def list_tools():
    return [
        {
            "name": "my_tool",
            "description": "Does something useful",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"}
                },
                "required": ["query"]
            }
        }
    ]

@app.call_tool()
async def call_tool(name: str, arguments: dict):
    if name == "my_tool":
        result = await do_something(arguments["query"])
        return {"content": [{"type": "text", "text": result}]}
    raise ValueError(f"Unknown tool: {name}")

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
```

### Project Layout
```
my-mcp-server/
├── src/
│   └── my_server/
│       ├── __init__.py
│       ├── server.py       # Main server logic
│       ├── tools.py        # Tool handlers
│       └── resources.py    # Resource handlers
├── pyproject.toml
└── README.md
```

## Tool Patterns

### Tool with Validation
```python
from pydantic import BaseModel, Field

class SearchInput(BaseModel):
    query: str = Field(..., min_length=1, max_length=500)
    limit: int = Field(default=10, ge=1, le=100)

@app.call_tool()
async def call_tool(name: str, arguments: dict):
    if name == "search":
        # Pydantic validates and parses
        params = SearchInput(**arguments)
        results = await search(params.query, params.limit)
        return {"content": [{"type": "text", "text": json.dumps(results)}]}
```

### Tool with Error Handling
```python
@app.call_tool()
async def call_tool(name: str, arguments: dict):
    try:
        if name == "fetch_data":
            data = await fetch_data(arguments["url"])
            return {"content": [{"type": "text", "text": data}]}
    except httpx.HTTPStatusError as e:
        return {
            "content": [{"type": "text", "text": f"HTTP error: {e.response.status_code}"}],
            "isError": True
        }
    except Exception as e:
        return {
            "content": [{"type": "text", "text": f"Error: {str(e)}"}],
            "isError": True
        }
```

### Multiple Tool Registration
```python
TOOLS = {
    "list_items": {
        "description": "List all items",
        "schema": {"type": "object", "properties": {}},
        "handler": handle_list_items
    },
    "get_item": {
        "description": "Get specific item",
        "schema": {
            "type": "object",
            "properties": {"id": {"type": "string"}},
            "required": ["id"]
        },
        "handler": handle_get_item
    },
    "create_item": {
        "description": "Create new item",
        "schema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "data": {"type": "object"}
            },
            "required": ["name"]
        },
        "handler": handle_create_item
    }
}

@app.list_tools()
async def list_tools():
    return [
        {"name": name, "description": t["description"], "inputSchema": t["schema"]}
        for name, t in TOOLS.items()
    ]

@app.call_tool()
async def call_tool(name: str, arguments: dict):
    if name not in TOOLS:
        raise ValueError(f"Unknown tool: {name}")
    return await TOOLS[name]["handler"](arguments)
```

## Resource Patterns

### Static Resource
```python
@app.list_resources()
async def list_resources():
    return [
        {
            "uri": "config://settings",
            "name": "Application Settings",
            "mimeType": "application/json"
        }
    ]

@app.read_resource()
async def read_resource(uri: str):
    if uri == "config://settings":
        return json.dumps({"theme": "dark", "lang": "en"})
    raise ValueError(f"Unknown resource: {uri}")
```

### Dynamic Resources
```python
@app.list_resources()
async def list_resources():
    # List available resources dynamically
    items = await get_all_items()
    return [
        {
            "uri": f"item://{item.id}",
            "name": item.name,
            "mimeType": "application/json"
        }
        for item in items
    ]

@app.read_resource()
async def read_resource(uri: str):
    if uri.startswith("item://"):
        item_id = uri.replace("item://", "")
        item = await get_item(item_id)
        return json.dumps(item.to_dict())
    raise ValueError(f"Unknown resource: {uri}")
```

## Authentication Patterns

### Environment Variables
```python
import os

API_KEY = os.environ.get("MY_API_KEY")
if not API_KEY:
    raise ValueError("MY_API_KEY environment variable required")

async def make_api_call(endpoint: str):
    async with httpx.AsyncClient() as client:
        response = await client.get(
            f"https://api.example.com/{endpoint}",
            headers={"Authorization": f"Bearer {API_KEY}"}
        )
        response.raise_for_status()
        return response.json()
```

### OAuth Token Refresh
```python
from datetime import datetime, timedelta

class TokenManager:
    def __init__(self):
        self.token = None
        self.expires_at = None

    async def get_token(self) -> str:
        if self.token and self.expires_at > datetime.now():
            return self.token

        # Refresh token
        async with httpx.AsyncClient() as client:
            response = await client.post(
                "https://auth.example.com/token",
                data={"grant_type": "client_credentials", ...}
            )
            data = response.json()
            self.token = data["access_token"]
            self.expires_at = datetime.now() + timedelta(seconds=data["expires_in"] - 60)
            return self.token

token_manager = TokenManager()
```

## State Management

### SQLite for Persistence
```python
import aiosqlite

DB_PATH = Path.home() / ".my-mcp-server" / "state.db"

async def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS cache (
                key TEXT PRIMARY KEY,
                value TEXT,
                expires_at TEXT
            )
        """)
        await db.commit()

async def get_cached(key: str) -> str | None:
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT value FROM cache WHERE key = ? AND expires_at > datetime('now')",
            (key,)
        )
        row = await cursor.fetchone()
        return row[0] if row else None

async def set_cached(key: str, value: str, ttl_seconds: int = 3600):
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT OR REPLACE INTO cache (key, value, expires_at) VALUES (?, ?, datetime('now', '+' || ? || ' seconds'))",
            (key, value, ttl_seconds)
        )
        await db.commit()
```

### In-Memory Cache
```python
from functools import lru_cache
from cachetools import TTLCache

# Simple TTL cache
cache = TTLCache(maxsize=100, ttl=300)  # 5 minute TTL

async def get_data(key: str):
    if key in cache:
        return cache[key]
    data = await fetch_from_api(key)
    cache[key] = data
    return data
```

## Claude Desktop Configuration

### claude_desktop_config.json
```json
{
  "mcpServers": {
    "my-server": {
      "command": "python",
      "args": ["-m", "my_server"],
      "env": {
        "MY_API_KEY": "your-key-here"
      }
    }
  }
}
```

### With uv (Recommended)
```json
{
  "mcpServers": {
    "my-server": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/my-server", "python", "-m", "my_server"],
      "env": {
        "MY_API_KEY": "your-key-here"
      }
    }
  }
}
```

## Testing Patterns

### Manual Test Script
```python
# test_server.py
import asyncio
from my_server.server import app

async def test_tools():
    tools = await app.list_tools()
    print(f"Available tools: {[t['name'] for t in tools]}")

    result = await app.call_tool("my_tool", {"query": "test"})
    print(f"Result: {result}")

if __name__ == "__main__":
    asyncio.run(test_tools())
```

### pytest with Async
```python
import pytest
from my_server.tools import handle_search

@pytest.mark.asyncio
async def test_search_returns_results():
    result = await handle_search({"query": "test", "limit": 5})
    assert "content" in result
    assert len(result["content"]) > 0

@pytest.mark.asyncio
async def test_search_handles_empty():
    result = await handle_search({"query": "xyznonexistent123"})
    assert result["content"][0]["text"] == "No results found"
```

## Common Issues

| Issue | Solution |
|-------|----------|
| Server not starting | Check `command` path, ensure dependencies installed |
| Tool not appearing | Verify `list_tools()` returns valid schema |
| Auth failures | Check env vars are set in config, not shell |
| Timeout errors | Add timeout to httpx calls, use async properly |
| JSON parse errors | Ensure `call_tool` returns proper content structure |
