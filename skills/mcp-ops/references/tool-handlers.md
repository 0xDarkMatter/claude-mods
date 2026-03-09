# Tool Handlers

## Tool Schema Design

Every MCP tool has an `inputSchema` that follows JSON Schema. The schema tells the LLM what arguments the tool accepts.

### Basic Schema

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("tools-demo")

# FastMCP generates the schema from type hints and docstring
@mcp.tool()
def search(query: str, max_results: int = 10) -> str:
    """Search for documents matching a query.

    Args:
        query: The search query string
        max_results: Maximum number of results to return (default: 10)
    """
    results = perform_search(query, limit=max_results)
    return "\n".join(f"- {r.title}: {r.snippet}" for r in results)
```

Generated schema:

```json
{
  "name": "search",
  "description": "Search for documents matching a query.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The search query string"
      },
      "max_results": {
        "type": "integer",
        "description": "Maximum number of results to return (default: 10)",
        "default": 10
      }
    },
    "required": ["query"]
  }
}
```

### Complex Schemas with Pydantic

```python
from pydantic import BaseModel, Field
from enum import Enum
from typing import Optional

class Priority(str, Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"

class CreateTicket(BaseModel):
    title: str = Field(description="Short summary of the issue")
    body: str = Field(description="Detailed description")
    priority: Priority = Field(default=Priority.MEDIUM, description="Ticket priority level")
    labels: list[str] = Field(default_factory=list, description="Labels to apply")
    assignee: Optional[str] = Field(default=None, description="GitHub username to assign")

@mcp.tool()
def create_ticket(ticket: CreateTicket) -> str:
    """Create a new support ticket."""
    result = api.create_ticket(
        title=ticket.title,
        body=ticket.body,
        priority=ticket.priority.value,
        labels=ticket.labels,
        assignee=ticket.assignee,
    )
    return f"Created ticket #{result.id}: {result.url}"
```

### TypeScript Schema with Zod

```typescript
import { z } from "zod";

const PriorityEnum = z.enum(["low", "medium", "high", "critical"]);

server.tool(
  "create_ticket",
  "Create a new support ticket",
  {
    title: z.string().describe("Short summary of the issue"),
    body: z.string().describe("Detailed description"),
    priority: PriorityEnum.default("medium").describe("Ticket priority level"),
    labels: z.array(z.string()).default([]).describe("Labels to apply"),
    assignee: z.string().optional().describe("GitHub username to assign"),
  },
  async ({ title, body, priority, labels, assignee }) => {
    const result = await api.createTicket({ title, body, priority, labels, assignee });
    return {
      content: [{ type: "text", text: `Created ticket #${result.id}: ${result.url}` }],
    };
  }
);
```

### Schema Best Practices

| Practice | Why | Example |
|----------|-----|---------|
| Always add `description` to every field | LLM uses descriptions to decide what values to pass | `"description": "SQL query to execute"` |
| Use `enum` for fixed choices | Constrains LLM to valid values | `"enum": ["asc", "desc"]` |
| Set sensible `default` values | Reduces required arguments | `"default": 10` |
| Mark truly required fields only | Optional fields with defaults reduce friction | Only `query` required, not `max_results` |
| Use nested objects sparingly | Flat schemas are easier for LLMs | Prefer `title, body` over `ticket: {title, body}` |
| Keep descriptions under 100 chars | Long descriptions waste context | "Search query" not "The string to use for searching..." |

## Input Validation

### Python with Pydantic (FastMCP)

FastMCP automatically validates inputs against type hints:

```python
from pydantic import Field, field_validator

@mcp.tool()
def query_database(
    sql: str,
    limit: int = Field(default=100, ge=1, le=1000),
) -> str:
    """Execute a read-only SQL query.

    Args:
        sql: SQL SELECT query to execute
        limit: Maximum rows to return (1-1000)
    """
    if not sql.strip().upper().startswith("SELECT"):
        raise ValueError("Only SELECT queries are allowed")
    results = db.execute(f"{sql} LIMIT {limit}")
    return json.dumps(results, default=str)
```

### Custom Validators

```python
from pydantic import BaseModel, field_validator

class FileReadArgs(BaseModel):
    path: str
    encoding: str = "utf-8"

    @field_validator("path")
    @classmethod
    def validate_path(cls, v: str) -> str:
        import os
        # Prevent directory traversal
        resolved = os.path.realpath(v)
        allowed_root = os.path.realpath("/workspace")
        if not resolved.startswith(allowed_root):
            raise ValueError(f"Path must be within /workspace, got: {v}")
        return resolved

    @field_validator("encoding")
    @classmethod
    def validate_encoding(cls, v: str) -> str:
        allowed = {"utf-8", "ascii", "latin-1", "utf-16"}
        if v not in allowed:
            raise ValueError(f"Encoding must be one of: {allowed}")
        return v

@mcp.tool()
def read_file(args: FileReadArgs) -> str:
    """Read a file from the workspace."""
    with open(args.path, encoding=args.encoding) as f:
        return f.read()
```

### TypeScript with Zod

```typescript
server.tool(
  "query_database",
  "Execute a read-only SQL query",
  {
    sql: z.string()
      .refine((s) => s.trim().toUpperCase().startsWith("SELECT"), {
        message: "Only SELECT queries are allowed",
      }),
    limit: z.number().int().min(1).max(1000).default(100),
  },
  async ({ sql, limit }) => {
    const results = await db.query(`${sql} LIMIT ${limit}`);
    return {
      content: [{ type: "text", text: JSON.stringify(results) }],
    };
  }
);
```

## Return Types

### Text Content (Most Common)

```python
@mcp.tool()
def get_user(user_id: str) -> str:
    """Look up a user by ID."""
    user = db.get_user(user_id)
    return json.dumps({
        "id": user.id,
        "name": user.name,
        "email": user.email,
        "created_at": user.created_at.isoformat(),
    }, indent=2)
```

### Image Content

```python
import base64

@mcp.tool()
def generate_chart(data: str, chart_type: str = "bar") -> list:
    """Generate a chart image from data."""
    # Generate chart with matplotlib
    import matplotlib.pyplot as plt
    import io

    fig, ax = plt.subplots()
    parsed = json.loads(data)
    ax.bar(parsed["labels"], parsed["values"])
    ax.set_title(parsed.get("title", "Chart"))

    buf = io.BytesIO()
    fig.savefig(buf, format="png")
    buf.seek(0)
    plt.close(fig)

    image_b64 = base64.b64encode(buf.read()).decode("utf-8")

    # Return both image and text description
    return [
        {"type": "image", "data": image_b64, "mimeType": "image/png"},
        {"type": "text", "text": f"Generated {chart_type} chart with {len(parsed['labels'])} data points."},
    ]
```

### Embedded Resources

```python
@mcp.tool()
def analyze_file(path: str) -> list:
    """Analyze a file and return results with the file content as an embedded resource."""
    content = open(path).read()
    analysis = perform_analysis(content)

    return [
        {
            "type": "resource",
            "resource": {
                "uri": f"file://{path}",
                "mimeType": "text/plain",
                "text": content,
            },
        },
        {"type": "text", "text": f"Analysis:\n{analysis}"},
    ]
```

### Multiple Content Items

```python
@mcp.tool()
def compare_files(path_a: str, path_b: str) -> list:
    """Compare two files and show differences."""
    content_a = open(path_a).read()
    content_b = open(path_b).read()
    diff = compute_diff(content_a, content_b)

    return [
        {"type": "text", "text": f"## File A: {path_a}\n```\n{content_a}\n```"},
        {"type": "text", "text": f"## File B: {path_b}\n```\n{content_b}\n```"},
        {"type": "text", "text": f"## Differences\n```diff\n{diff}\n```"},
    ]
```

## Progress Notifications

For long-running operations, report progress so the client can display updates:

```python
@mcp.tool()
async def batch_process(items: list[str], ctx: Context) -> str:
    """Process a batch of items with progress reporting."""
    results = []
    total = len(items)

    for i, item in enumerate(items):
        await ctx.report_progress(i, total)
        await ctx.info(f"Processing item {i+1}/{total}: {item}")

        try:
            result = await process_single_item(item)
            results.append({"item": item, "status": "success", "result": result})
        except Exception as e:
            results.append({"item": item, "status": "error", "error": str(e)})

    await ctx.report_progress(total, total)

    succeeded = sum(1 for r in results if r["status"] == "success")
    return json.dumps({
        "summary": f"{succeeded}/{total} items processed successfully",
        "results": results,
    }, indent=2)
```

## Error Responses

### Returning Errors to the LLM

```python
@mcp.tool()
def delete_item(item_id: str) -> str:
    """Delete an item by ID."""
    try:
        item = db.get(item_id)
        if item is None:
            # Raise to signal error - FastMCP sets isError=True
            raise ValueError(f"Item {item_id} not found")
        if item.protected:
            raise PermissionError(f"Item {item_id} is protected and cannot be deleted")
        db.delete(item_id)
        return f"Deleted item {item_id}"
    except (ValueError, PermissionError):
        raise  # Re-raise known errors for the LLM
    except Exception as e:
        raise RuntimeError(f"Failed to delete item: {e}")
```

### TypeScript Error Responses

```typescript
server.tool("delete_item", "Delete an item", { item_id: z.string() }, async ({ item_id }) => {
  try {
    const item = await db.get(item_id);
    if (!item) {
      return {
        content: [{ type: "text", text: `Item ${item_id} not found` }],
        isError: true,
      };
    }
    await db.delete(item_id);
    return {
      content: [{ type: "text", text: `Deleted item ${item_id}` }],
    };
  } catch (error) {
    return {
      content: [{ type: "text", text: `Failed to delete: ${error.message}` }],
      isError: true,
    };
  }
});
```

### Error Best Practices

| Practice | Why |
|----------|-----|
| Always include actionable message | LLM can report to user or retry differently |
| Distinguish user errors from system errors | User errors: "Invalid SQL syntax"; system: "Database unavailable" |
| Never expose stack traces | Security risk; use structured error messages |
| Return `isError: true` for failures | Clients and LLMs can distinguish success from failure |
| Log internal details server-side | Use `ctx.error()` or logging for debugging |

## Tool Composition

### Tools Calling Other Tools

```python
@mcp.tool()
async def analyze_and_fix(filepath: str, ctx: Context) -> str:
    """Analyze code for issues and apply fixes."""
    # Read the file using a resource
    content = await ctx.read_resource(f"file://{filepath}")

    # Analyze
    issues = analyze_code(content)
    if not issues:
        return "No issues found"

    # Apply fixes
    fixed = apply_fixes(content, issues)

    # Write back (side effect)
    with open(filepath, "w") as f:
        f.write(fixed)

    return f"Fixed {len(issues)} issues in {filepath}:\n" + "\n".join(
        f"- {issue.description}" for issue in issues
    )
```

### Dependency Injection

```python
from dataclasses import dataclass

@dataclass
class AppDependencies:
    db: DatabasePool
    http: httpx.AsyncClient
    cache: dict

@asynccontextmanager
async def lifespan(server: FastMCP):
    deps = AppDependencies(
        db=await create_pool(),
        http=httpx.AsyncClient(),
        cache={},
    )
    server.state["deps"] = deps
    try:
        yield
    finally:
        await deps.http.aclose()
        await deps.db.close()

mcp = FastMCP("di-server", lifespan=lifespan)

@mcp.tool()
async def search_and_cache(query: str, ctx: Context) -> str:
    """Search with caching."""
    deps: AppDependencies = ctx.server.state["deps"]

    if query in deps.cache:
        return deps.cache[query]

    results = await deps.db.fetch("SELECT * FROM docs WHERE content LIKE $1", f"%{query}%")
    formatted = json.dumps(results, default=str)
    deps.cache[query] = formatted
    return formatted
```

## Batch Operations

```python
@mcp.tool()
async def bulk_update(
    updates: list[dict],
    continue_on_error: bool = True,
    ctx: Context = None,
) -> str:
    """Apply multiple updates, optionally continuing past errors.

    Args:
        updates: List of {id, field, value} objects
        continue_on_error: If true, skip failed items and continue
    """
    results = {"succeeded": [], "failed": []}

    for i, update in enumerate(updates):
        if ctx:
            await ctx.report_progress(i, len(updates))
        try:
            db.update(update["id"], {update["field"]: update["value"]})
            results["succeeded"].append(update["id"])
        except Exception as e:
            if continue_on_error:
                results["failed"].append({"id": update["id"], "error": str(e)})
            else:
                return json.dumps({
                    "error": f"Failed on item {update['id']}: {e}",
                    "completed": results["succeeded"],
                })

    return json.dumps({
        "summary": f"{len(results['succeeded'])} succeeded, {len(results['failed'])} failed",
        **results,
    }, indent=2)
```

## Idempotency

Design tools that are safe to retry:

```python
@mcp.tool()
def upsert_config(key: str, value: str) -> str:
    """Set a configuration value (idempotent - safe to retry).

    Args:
        key: Configuration key
        value: Configuration value
    """
    # Use upsert instead of insert to make retries safe
    db.execute(
        "INSERT INTO config (key, value) VALUES ($1, $2) "
        "ON CONFLICT (key) DO UPDATE SET value = $2",
        key, value,
    )
    return f"Config {key} = {value}"

@mcp.tool()
def create_item_idempotent(idempotency_key: str, title: str, body: str) -> str:
    """Create an item with an idempotency key (safe to retry).

    Args:
        idempotency_key: Unique key for this operation (e.g., UUID)
        title: Item title
        body: Item body
    """
    existing = db.get_by_idempotency_key(idempotency_key)
    if existing:
        return f"Item already exists: #{existing.id} (idempotent match)"
    item = db.create(title=title, body=body, idempotency_key=idempotency_key)
    return f"Created item #{item.id}"
```

## Side Effects and Confirmation

### Read-Only vs Mutating Tools

```python
# Read-only: no confirmation needed
@mcp.tool()
def list_users(role: str = "all") -> str:
    """List users, optionally filtered by role."""
    users = db.list_users(role=role if role != "all" else None)
    return json.dumps(users, default=str)

# Mutating: include clear description of what will change
@mcp.tool()
def delete_user(user_id: str, confirm: bool = False) -> str:
    """Permanently delete a user and all their data.

    WARNING: This action is irreversible. Set confirm=true to proceed.

    Args:
        user_id: The user ID to delete
        confirm: Must be true to actually perform the deletion
    """
    if not confirm:
        user = db.get_user(user_id)
        return (
            f"This will permanently delete user {user.name} ({user.email}) "
            f"and {user.data_count} associated records. "
            f"Call again with confirm=true to proceed."
        )
    db.delete_user(user_id)
    return f"User {user_id} has been permanently deleted."
```

### Dry Run Pattern

```python
@mcp.tool()
def refactor_imports(directory: str, dry_run: bool = True) -> str:
    """Reorganize import statements in Python files.

    Args:
        directory: Directory to process
        dry_run: If true, show what would change without modifying files
    """
    changes = analyze_imports(directory)

    if dry_run:
        summary = "\n".join(f"  {c.file}: {c.description}" for c in changes)
        return f"Dry run - {len(changes)} files would be modified:\n{summary}\n\nRun with dry_run=false to apply."

    for change in changes:
        apply_change(change)
    return f"Applied {len(changes)} import reorganizations."
```

## Schema Evolution

### Backwards-Compatible Changes

```python
# v1: Original tool
@mcp.tool()
def search_v1(query: str) -> str:
    """Search documents."""
    ...

# v2: Added optional fields (backwards compatible)
@mcp.tool()
def search(
    query: str,
    max_results: int = 10,        # New in v2
    include_archived: bool = False, # New in v2
) -> str:
    """Search documents with optional filters.

    Args:
        query: Search query
        max_results: Maximum results to return
        include_archived: Include archived documents in results
    """
    ...

# v3: Deprecated field (still accepted, but ignored)
@mcp.tool()
def search(
    query: str,
    max_results: int = 10,
    include_archived: bool = False,
    sort_by: str = "relevance",  # New in v3
    # Deprecated: use sort_by instead
    sort_order: str | None = None,  # Deprecated in v3
) -> str:
    """Search documents.

    Args:
        query: Search query
        max_results: Maximum results to return
        include_archived: Include archived documents
        sort_by: Sort results by: relevance, date, title
        sort_order: DEPRECATED - use sort_by instead
    """
    if sort_order is not None:
        # Handle deprecated parameter gracefully
        sort_by = sort_order
    ...
```

## Real-World Tool Examples

### File System Tools

```python
import os
import stat

@mcp.tool()
def read_file(path: str, encoding: str = "utf-8") -> str:
    """Read the contents of a file.

    Args:
        path: Absolute path to the file
        encoding: File encoding (default: utf-8)
    """
    path = os.path.realpath(path)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"File not found: {path}")

    file_size = os.path.getsize(path)
    if file_size > 10 * 1024 * 1024:  # 10MB limit
        raise ValueError(f"File too large ({file_size} bytes). Maximum is 10MB.")

    with open(path, encoding=encoding) as f:
        return f.read()

@mcp.tool()
def write_file(path: str, content: str, create_dirs: bool = False) -> str:
    """Write content to a file.

    Args:
        path: Absolute path to write to
        content: Content to write
        create_dirs: Create parent directories if they don't exist
    """
    path = os.path.realpath(path)
    if create_dirs:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    return f"Wrote {len(content)} bytes to {path}"

@mcp.tool()
def list_directory(path: str, show_hidden: bool = False) -> str:
    """List files and directories at the given path.

    Args:
        path: Directory path to list
        show_hidden: Include hidden files (starting with .)
    """
    path = os.path.realpath(path)
    entries = []
    for entry in sorted(os.listdir(path)):
        if not show_hidden and entry.startswith("."):
            continue
        full_path = os.path.join(path, entry)
        info = os.stat(full_path)
        entry_type = "dir" if stat.S_ISDIR(info.st_mode) else "file"
        size = info.st_size if entry_type == "file" else ""
        entries.append(f"{'[D]' if entry_type == 'dir' else '[F]'} {entry} {size}")
    return "\n".join(entries) if entries else "(empty directory)"
```

### Database Query Tool

```python
import sqlite3
import json

@mcp.tool()
def query_sqlite(
    db_path: str,
    sql: str,
    params: list = None,
) -> str:
    """Execute a read-only SQL query against a SQLite database.

    Args:
        db_path: Path to the SQLite database file
        sql: SQL query (SELECT only)
        params: Optional query parameters for parameterized queries
    """
    sql_stripped = sql.strip().upper()
    if not sql_stripped.startswith("SELECT") and not sql_stripped.startswith("WITH"):
        raise ValueError("Only SELECT and WITH (CTE) queries are allowed")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        cursor = conn.execute(sql, params or [])
        rows = [dict(row) for row in cursor.fetchall()]
        columns = [desc[0] for desc in cursor.description] if cursor.description else []
        return json.dumps({
            "columns": columns,
            "rows": rows,
            "row_count": len(rows),
        }, indent=2, default=str)
    finally:
        conn.close()
```

### API Wrapper Tool

```python
import httpx
import os

@mcp.tool()
async def github_search(
    query: str,
    search_type: str = "repositories",
    per_page: int = 10,
) -> str:
    """Search GitHub for repositories, code, or issues.

    Args:
        query: GitHub search query
        search_type: Type of search: repositories, code, issues
        per_page: Results per page (1-100)
    """
    if search_type not in ("repositories", "code", "issues"):
        raise ValueError(f"Invalid search type: {search_type}")
    if not 1 <= per_page <= 100:
        raise ValueError("per_page must be between 1 and 100")

    token = os.environ.get("GITHUB_TOKEN")
    headers = {"Accept": "application/vnd.github.v3+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"https://api.github.com/search/{search_type}",
            params={"q": query, "per_page": per_page},
            headers=headers,
            timeout=30.0,
        )
        resp.raise_for_status()
        data = resp.json()

    items = data.get("items", [])
    if search_type == "repositories":
        results = [
            f"- [{item['full_name']}]({item['html_url']}) "
            f"({item['stargazers_count']} stars): {item.get('description', 'No description')}"
            for item in items
        ]
    elif search_type == "issues":
        results = [
            f"- [{item['title']}]({item['html_url']}) "
            f"({item['state']}): {item['repository_url'].split('/')[-1]}"
            for item in items
        ]
    else:
        results = [f"- {item['path']} in {item['repository']['full_name']}" for item in items]

    return f"Found {data['total_count']} results:\n" + "\n".join(results)
```

### Web Scraping Tool

```python
import httpx
from html.parser import HTMLParser

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text_parts = []
        self._skip = False
        self._skip_tags = {"script", "style", "noscript"}

    def handle_starttag(self, tag, attrs):
        if tag in self._skip_tags:
            self._skip = True

    def handle_endtag(self, tag):
        if tag in self._skip_tags:
            self._skip = False

    def handle_data(self, data):
        if not self._skip:
            text = data.strip()
            if text:
                self.text_parts.append(text)

@mcp.tool()
async def fetch_webpage(url: str, extract_text: bool = True) -> str:
    """Fetch a webpage and optionally extract its text content.

    Args:
        url: URL to fetch
        extract_text: If true, extract text only; if false, return raw HTML
    """
    if not url.startswith(("http://", "https://")):
        raise ValueError("URL must start with http:// or https://")

    async with httpx.AsyncClient(follow_redirects=True) as client:
        resp = await client.get(url, timeout=30.0, headers={
            "User-Agent": "MCP-Server/1.0 (compatible; tool-fetch)"
        })
        resp.raise_for_status()

    if not extract_text:
        return resp.text[:50000]  # Limit raw HTML size

    extractor = TextExtractor()
    extractor.feed(resp.text)
    text = "\n".join(extractor.text_parts)

    # Truncate if too long
    if len(text) > 30000:
        text = text[:30000] + "\n\n[Truncated - content exceeds 30KB]"

    return text
```
