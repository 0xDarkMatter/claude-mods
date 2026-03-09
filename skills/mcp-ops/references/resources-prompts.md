# Resources and Prompts

## Resource Overview

Resources provide **read-only data** to the LLM. They are identified by URIs and can be static or dynamic.

```
Resource URI format:  scheme://authority/path
Examples:
  file:///workspace/readme.md
  db://myapp/users
  config://settings
  api://github/repos/user/repo
```

## Resource URIs

### URI Scheme Design

| Scheme | Use Case | Example |
|--------|----------|---------|
| `file://` | Local filesystem | `file:///workspace/src/main.py` |
| `db://` | Database objects | `db://myapp/tables/users` |
| `config://` | Configuration | `config://app/settings` |
| `api://` | External API data | `api://github/repos` |
| `schema://` | Schema definitions | `schema://db/users` |
| `log://` | Log files/entries | `log://app/errors/today` |
| `docs://` | Documentation | `docs://api/endpoints` |

### URI Templates

URI templates allow parameterized resources:

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("resource-server")

# Static URI - single resource
@mcp.resource("config://app/settings")
def get_settings() -> str:
    """Return application settings."""
    return json.dumps(load_settings(), indent=2)

# URI template - parameterized resource
@mcp.resource("db://app/tables/{table_name}")
def get_table_data(table_name: str) -> str:
    """Return data from a database table."""
    if table_name not in ALLOWED_TABLES:
        raise ValueError(f"Table {table_name} not accessible")
    rows = db.query(f"SELECT * FROM {table_name} LIMIT 100")
    return json.dumps(rows, default=str, indent=2)

# Template with multiple parameters
@mcp.resource("api://github/{owner}/{repo}/info")
def get_repo_info(owner: str, repo: str) -> str:
    """Return GitHub repository information."""
    resp = httpx.get(f"https://api.github.com/repos/{owner}/{repo}")
    return resp.text
```

### TypeScript Resources

```typescript
// Static resource
server.resource("settings", "config://app/settings", async (uri) => ({
  contents: [{
    uri: uri.href,
    mimeType: "application/json",
    text: JSON.stringify(loadSettings(), null, 2),
  }],
}));

// Resource template
server.resource(
  "table_data",
  new ResourceTemplate("db://app/tables/{table_name}", { list: undefined }),
  async (uri, { table_name }) => ({
    contents: [{
      uri: uri.href,
      mimeType: "application/json",
      text: JSON.stringify(await db.query(`SELECT * FROM ${table_name} LIMIT 100`)),
    }],
  })
);
```

## Static Resources

Resources backed by files, configs, or constant data:

```python
import os
import json

@mcp.resource("config://app/environment")
def get_environment() -> str:
    """Return current environment configuration."""
    return json.dumps({
        "node_env": os.environ.get("NODE_ENV", "development"),
        "debug": os.environ.get("DEBUG", "false"),
        "version": "1.0.0",
    }, indent=2)

@mcp.resource("docs://api/openapi")
def get_openapi_spec() -> str:
    """Return the OpenAPI specification."""
    with open("openapi.yaml") as f:
        return f.read()

@mcp.resource("schema://database/migrations")
def get_migration_status() -> str:
    """Return database migration status."""
    migrations = get_applied_migrations()
    pending = get_pending_migrations()
    return json.dumps({
        "applied": [m.name for m in migrations],
        "pending": [m.name for m in pending],
        "current_version": migrations[-1].version if migrations else "none",
    }, indent=2)
```

## Dynamic Resources

Resources that fetch data on-demand from external sources:

```python
import httpx

@mcp.resource("api://weather/{city}")
async def get_weather(city: str) -> str:
    """Return current weather for a city."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            "https://api.weather.example.com/current",
            params={"city": city},
            timeout=10.0,
        )
        return resp.text

@mcp.resource("db://app/stats")
def get_app_stats() -> str:
    """Return application statistics."""
    stats = {
        "total_users": db.count("users"),
        "active_sessions": db.count("sessions", {"active": True}),
        "requests_today": db.count("requests", {"date": today()}),
        "error_rate": db.query_scalar(
            "SELECT COUNT(*) FILTER (WHERE status >= 500)::float / COUNT(*) FROM requests WHERE date = $1",
            today(),
        ),
    }
    return json.dumps(stats, indent=2)

@mcp.resource("log://app/errors/recent")
def get_recent_errors() -> str:
    """Return the most recent application errors."""
    errors = db.query(
        "SELECT timestamp, level, message, stack_trace FROM logs "
        "WHERE level = 'ERROR' ORDER BY timestamp DESC LIMIT 20"
    )
    return json.dumps(errors, default=str, indent=2)
```

## MIME Types

| MIME Type | Use For | Example |
|-----------|---------|---------|
| `text/plain` | Plain text, logs | Default if unspecified |
| `application/json` | Structured data | API responses, configs |
| `text/markdown` | Formatted docs | README, documentation |
| `text/html` | Web content | Rendered pages |
| `image/png` | PNG images | Charts, screenshots (base64) |
| `image/jpeg` | JPEG images | Photos (base64) |
| `application/pdf` | PDF documents | Reports (base64) |

### Setting MIME Types

```python
# Python - FastMCP infers from return type, or specify explicitly
@mcp.resource("docs://readme", mime_type="text/markdown")
def get_readme() -> str:
    """Return the project README."""
    with open("README.md") as f:
        return f.read()

# Binary content with base64
@mcp.resource("images://logo")
def get_logo() -> bytes:
    """Return the application logo."""
    with open("logo.png", "rb") as f:
        return f.read()  # FastMCP handles base64 encoding
```

```typescript
// TypeScript - specify mimeType in contents
server.resource("readme", "docs://readme", async (uri) => ({
  contents: [{
    uri: uri.href,
    mimeType: "text/markdown",
    text: await fs.readFile("README.md", "utf-8"),
  }],
}));

// Binary content
server.resource("logo", "images://logo", async (uri) => ({
  contents: [{
    uri: uri.href,
    mimeType: "image/png",
    blob: (await fs.readFile("logo.png")).toString("base64"),
  }],
}));
```

## Resource Subscriptions

Clients can subscribe to resource changes and receive notifications:

```python
from mcp.server.fastmcp import FastMCP, Context

mcp = FastMCP("subscription-demo")

# Track subscriptions
_config_version = 0

@mcp.resource("config://app/settings")
def get_settings() -> str:
    return json.dumps(load_settings(), indent=2)

@mcp.tool()
async def update_setting(key: str, value: str, ctx: Context) -> str:
    """Update a configuration setting."""
    global _config_version
    save_setting(key, value)
    _config_version += 1

    # Notify subscribed clients that the resource changed
    await ctx.request_context.session.send_resource_updated("config://app/settings")
    return f"Updated {key} = {value}"
```

## Resource Listing

Servers expose available resources via `resources/list`:

```python
# FastMCP handles listing automatically for registered resources.
# For dynamic resources, implement custom listing:

@mcp.resource("db://app/tables/{table_name}")
def get_table(table_name: str) -> str:
    """Read data from a database table."""
    return json.dumps(db.query(f"SELECT * FROM {table_name} LIMIT 50"), default=str)

# Override resource listing to show available tables
# (FastMCP's resource template handles this automatically when
#  the template is registered with a list callback)
```

### Pagination for Large Resource Lists

When you have many resources, consider chunking or metadata:

```python
@mcp.resource("db://app/tables/{table}/page/{page}")
def get_table_page(table: str, page: str) -> str:
    """Read a page of data from a database table.

    Args:
        table: Table name
        page: Page number (1-based)
    """
    page_num = int(page)
    offset = (page_num - 1) * 50
    rows = db.query(f"SELECT * FROM {table} LIMIT 50 OFFSET {offset}")
    total = db.count(table)
    return json.dumps({
        "rows": rows,
        "page": page_num,
        "total_pages": (total + 49) // 50,
        "total_rows": total,
    }, default=str, indent=2)
```

---

## Prompt Templates

Prompts are pre-written templates that suggest how the LLM should approach a task.

### Basic Prompts

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("prompt-server")

@mcp.prompt()
def code_review(language: str, filepath: str) -> str:
    """Generate a code review prompt for the given file."""
    return (
        f"Please review the following {language} code from {filepath}. "
        f"Focus on:\n"
        f"1. Bug risks and edge cases\n"
        f"2. Performance issues\n"
        f"3. Code style and readability\n"
        f"4. Security concerns\n"
        f"5. Suggestions for improvement\n"
    )

@mcp.prompt()
def explain_error(error_message: str, context: str = "") -> str:
    """Generate a prompt to explain an error message."""
    prompt = f"Explain this error message and suggest how to fix it:\n\n```\n{error_message}\n```"
    if context:
        prompt += f"\n\nContext:\n{context}"
    return prompt
```

### TypeScript Prompts

```typescript
server.prompt(
  "code_review",
  "Generate a code review prompt",
  {
    language: z.string().describe("Programming language"),
    filepath: z.string().describe("Path to the file to review"),
  },
  async ({ language, filepath }) => ({
    messages: [{
      role: "user",
      content: {
        type: "text",
        text: `Review this ${language} code from ${filepath}. Check for bugs, performance, style, and security.`,
      },
    }],
  })
);
```

### Prompt Arguments

```python
from typing import Optional

@mcp.prompt()
def sql_query_help(
    task: str,
    database_type: str = "postgresql",
    tables: Optional[str] = None,
) -> str:
    """Help write a SQL query for the given task.

    Args:
        task: What the query should do
        database_type: Target database (postgresql, mysql, sqlite)
        tables: Comma-separated list of relevant tables
    """
    prompt = f"Write a {database_type} SQL query to: {task}\n"
    if tables:
        prompt += f"\nRelevant tables: {tables}"
        prompt += "\nPlease query the table schemas first if you need to understand the structure."
    prompt += "\n\nRequirements:\n"
    prompt += "- Use parameterized queries (no string interpolation)\n"
    prompt += "- Include appropriate indexes if suggesting schema changes\n"
    prompt += "- Add comments explaining complex joins or subqueries\n"
    return prompt
```

### Multi-Turn Prompts

Prompts can include multiple messages for conversation setup:

```python
@mcp.prompt()
def debug_session(error_type: str, language: str) -> list[dict]:
    """Start a debugging session for a specific error type."""
    return [
        {
            "role": "system",
            "content": f"You are a {language} debugging expert. Help the user systematically debug their {error_type} error.",
        },
        {
            "role": "user",
            "content": (
                f"I'm encountering a {error_type} in my {language} code. "
                "Please help me debug it step by step. "
                "Start by asking me for the error message and relevant code."
            ),
        },
    ]
```

```typescript
server.prompt(
  "debug_session",
  "Start a debugging session",
  {
    error_type: z.string().describe("Type of error (e.g., TypeError, ConnectionError)"),
    language: z.string().describe("Programming language"),
  },
  async ({ error_type, language }) => ({
    messages: [
      {
        role: "assistant",
        content: {
          type: "text",
          text: `I'll help you debug your ${error_type} in ${language}. Let's work through this systematically.\n\nFirst, can you share:\n1. The full error message and stack trace\n2. The relevant code section\n3. What you've already tried`,
        },
      },
    ],
  })
);
```

### Prompts that Reference Resources

Combine prompts with resources for context-aware interactions:

```python
@mcp.resource("schema://db/{table}")
def get_table_schema(table: str) -> str:
    """Return the schema for a database table."""
    schema = db.get_schema(table)
    return json.dumps(schema, indent=2)

@mcp.prompt()
def optimize_query(table: str, slow_query: str) -> list[dict]:
    """Help optimize a slow SQL query with schema context."""
    return [
        {
            "role": "user",
            "content": [
                {
                    "type": "resource",
                    "resource": {
                        "uri": f"schema://db/{table}",
                        "text": get_table_schema(table),
                        "mimeType": "application/json",
                    },
                },
                {
                    "type": "text",
                    "text": (
                        f"This query against the `{table}` table is slow:\n\n"
                        f"```sql\n{slow_query}\n```\n\n"
                        "Please suggest optimizations, including index recommendations."
                    ),
                },
            ],
        },
    ]
```

### Guided Workflows

Use prompts to define multi-step workflows:

```python
@mcp.prompt()
def migration_workflow(source_db: str, target_db: str) -> list[dict]:
    """Guide through a database migration workflow."""
    return [
        {
            "role": "user",
            "content": (
                f"I need to migrate data from {source_db} to {target_db}. "
                "Please guide me through these steps:\n\n"
                "1. Analyze the source schema\n"
                "2. Create the target schema (with any needed transformations)\n"
                "3. Write the migration script\n"
                "4. Create validation queries to verify the migration\n"
                "5. Suggest a rollback plan\n\n"
                "Let's start with step 1."
            ),
        },
    ]

@mcp.prompt()
def api_design(service_name: str, endpoints: str = "") -> str:
    """Help design a REST API."""
    prompt = f"Help me design a REST API for the {service_name} service.\n"
    if endpoints:
        prompt += f"\nPlanned endpoints:\n{endpoints}\n"
    prompt += (
        "\nFor each endpoint, specify:\n"
        "- HTTP method and path\n"
        "- Request/response schemas\n"
        "- Authentication requirements\n"
        "- Rate limiting considerations\n"
        "- Error responses\n"
    )
    return prompt
```

## Prompt Best Practices

| Practice | Why |
|----------|-----|
| Use descriptive argument names | LLM and client UIs show argument names |
| Provide defaults for optional args | Reduces friction for common cases |
| Include structured instructions | Numbered lists guide the LLM's approach |
| Reference resources when relevant | Gives the LLM concrete data to work with |
| Keep prompts focused | One task per prompt, not multi-purpose |
| Test with real LLM conversations | Prompts that read well may not work well |

## Combining Resources and Tools

A common pattern: resources provide context, tools perform actions:

```python
# Resource: provides data for the LLM to understand
@mcp.resource("db://app/tables/{table}/schema")
def get_schema(table: str) -> str:
    """Return the schema for a database table."""
    return json.dumps(db.get_schema(table), indent=2)

@mcp.resource("db://app/tables/{table}/stats")
def get_stats(table: str) -> str:
    """Return statistics for a database table."""
    return json.dumps({
        "row_count": db.count(table),
        "size_bytes": db.table_size(table),
        "last_modified": db.last_modified(table).isoformat(),
    }, indent=2)

# Tool: performs actions using the context from resources
@mcp.tool()
def optimize_table(table: str, strategy: str = "auto") -> str:
    """Optimize a database table.

    Args:
        table: Table name to optimize
        strategy: Optimization strategy: auto, vacuum, reindex, analyze
    """
    if strategy == "auto":
        stats = json.loads(get_stats(table))
        if stats["row_count"] > 1_000_000:
            strategy = "vacuum"
        else:
            strategy = "analyze"

    result = db.optimize(table, strategy)
    return f"Optimized {table} using {strategy}: {result}"

# Prompt: guides the LLM to use resources and tools together
@mcp.prompt()
def db_health_check() -> str:
    """Run a database health check."""
    return (
        "Please check the health of the database:\n"
        "1. Read the schema for each table\n"
        "2. Check the stats for each table\n"
        "3. Identify any tables that need optimization\n"
        "4. Run optimize_table on any that need it\n"
        "5. Summarize the results\n"
    )
```
