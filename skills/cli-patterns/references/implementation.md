# Implementation Templates

Complete Python implementation patterns for CLI tools.

## CLI Skeleton (Typer)

```python
# src/<package>/cli.py
from __future__ import annotations

import json
from typing import Annotated, Optional

import typer
from rich.console import Console
from rich.table import Table

from . import __version__
from .client import Client
from .config import get_token

app = typer.Typer(
    name="<tool>",
    help="<description>",
    no_args_is_help=True,
)

# stderr for human output
console = Console(stderr=True)

# Exit codes
EXIT_SUCCESS = 0
EXIT_ERROR = 1
EXIT_AUTH_REQUIRED = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_FORBIDDEN = 5
EXIT_RATE_LIMITED = 6
EXIT_CONFLICT = 7


def _output_json(data) -> None:
    """Output JSON to stdout."""
    print(json.dumps(data, indent=2, default=str))


def _error(
    message: str,
    code: str = "ERROR",
    exit_code: int = EXIT_ERROR,
    details: dict = None,
    as_json: bool = False,
):
    """Output error and exit."""
    error_obj = {"error": {"code": code, "message": message}}
    if details:
        error_obj["error"]["details"] = details

    if as_json:
        _output_json(error_obj)

    console.print(f"[red]Error:[/red] {message}")
    raise typer.Exit(exit_code)


def _require_auth(as_json: bool = False):
    """Check authentication, exit if not authenticated."""
    if not get_token():
        _error(
            "Not authenticated. Run: <tool> auth login",
            "AUTH_REQUIRED",
            EXIT_AUTH_REQUIRED,
            as_json=as_json,
        )


# Version callback
def version_callback(value: bool):
    if value:
        print(f"<tool> {__version__}")
        raise typer.Exit()


@app.callback()
def main(
    version: Annotated[
        Optional[bool],
        typer.Option("--version", "-V", callback=version_callback, is_eager=True),
    ] = None,
):
    """<description>"""
    pass


# ============================================================
# AUTH COMMANDS
# ============================================================
auth_app = typer.Typer(help="Authentication")
app.add_typer(auth_app, name="auth")


@auth_app.command("login")
def auth_login():
    """Authenticate with service."""
    # Implementation...
    console.print("[green]Authenticated[/green]")


@auth_app.command("status")
def auth_status(
    json_output: Annotated[bool, typer.Option("--json")] = False,
):
    """
    Check authentication status.

    Examples:
        <tool> auth status
        <tool> auth status --json
    """
    token = get_token()
    status = {"authenticated": token is not None}

    if json_output:
        _output_json(status)
        return

    if status["authenticated"]:
        console.print("Authenticated: [green]yes[/green]")
    else:
        console.print("Authenticated: [red]no[/red]")


@auth_app.command("logout")
def auth_logout():
    """Clear stored credentials."""
    # Implementation...
    console.print("[green]Logged out[/green]")


# ============================================================
# RESOURCE COMMANDS
# ============================================================
items_app = typer.Typer(help="Item operations")
app.add_typer(items_app, name="items")


@items_app.command("list")
def items_list(
    status: Annotated[
        Optional[str],
        typer.Option("--status", "-s", help="Filter by status"),
    ] = None,
    limit: Annotated[
        int,
        typer.Option("--limit", "-n", help="Max results"),
    ] = 20,
    json_output: Annotated[bool, typer.Option("--json")] = False,
):
    """
    List items with optional filtering.

    Examples:
        <tool> items list
        <tool> items list --status active
        <tool> items list --limit 50 --json
        <tool> items list --json | jq '.data[].name'
    """
    _require_auth(json_output)

    client = Client()
    items = client.list_items(status=status, limit=limit)

    if json_output:
        _output_json({
            "data": items,
            "meta": {"count": len(items)},
        })
        return

    table = Table(title="Items")
    table.add_column("ID")
    table.add_column("Name")
    table.add_column("Status")

    for item in items:
        table.add_row(item["id"], item["name"], item.get("status", ""))

    console.print(table)


@items_app.command("get")
def items_get(
    item_id: Annotated[str, typer.Argument(help="Item ID")],
    json_output: Annotated[bool, typer.Option("--json")] = False,
):
    """
    Get a specific item by ID.

    Examples:
        <tool> items get abc123
        <tool> items get abc123 --json
    """
    _require_auth(json_output)

    client = Client()
    item = client.get_item(item_id)

    if item is None:
        _error(
            f"Item not found: {item_id}",
            "NOT_FOUND",
            EXIT_NOT_FOUND,
            {"item_id": item_id},
            json_output,
        )

    if json_output:
        _output_json({"data": item})
        return

    console.print(f"[bold]{item['name']}[/bold]")
    console.print(f"  ID:     {item['id']}")
    console.print(f"  Status: {item.get('status', 'N/A')}")


if __name__ == "__main__":
    app()
```

## Client Pattern

```python
# src/<package>/client.py
from typing import Optional

import httpx

from .config import get_token


class Client:
    """API client."""

    BASE_URL = "https://api.example.com/v1"
    TIMEOUT = 30

    def __init__(self):
        self.token = get_token()

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def _get(self, endpoint: str, params: dict = None) -> Optional[dict]:
        """Make GET request."""
        response = httpx.get(
            f"{self.BASE_URL}/{endpoint}",
            headers=self._headers(),
            params=params,
            timeout=self.TIMEOUT,
        )
        response.raise_for_status()
        return response.json()

    def _post(self, endpoint: str, data: dict) -> Optional[dict]:
        """Make POST request."""
        response = httpx.post(
            f"{self.BASE_URL}/{endpoint}",
            headers=self._headers(),
            json=data,
            timeout=self.TIMEOUT,
        )
        response.raise_for_status()
        return response.json()

    def list_items(self, status: str = None, limit: int = 20) -> list:
        """List items with optional filters."""
        params = {"limit": limit}
        if status:
            params["status"] = status

        data = self._get("items", params)
        return data.get("items", [])

    def get_item(self, item_id: str) -> Optional[dict]:
        """Get single item by ID."""
        try:
            data = self._get(f"items/{item_id}")
            return data.get("item")
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            raise
```

## Config & Token Storage

```python
# src/<package>/config.py
import os
from pathlib import Path


def get_token() -> str | None:
    """Get API token from environment or config file."""
    # 1. Environment variable (highest priority)
    token = os.getenv("MYTOOL_API_TOKEN")
    if token:
        return token

    # 2. Config file
    config_file = Path.home() / ".config" / "mytool" / "token"
    if config_file.exists():
        return config_file.read_text().strip()

    return None


def save_token(token: str) -> None:
    """Save API token to config file."""
    config_dir = Path.home() / ".config" / "mytool"
    config_dir.mkdir(parents=True, exist_ok=True)

    config_file = config_dir / "token"
    config_file.write_text(token)
    config_file.chmod(0o600)  # Restrict permissions


def clear_token() -> None:
    """Remove stored token."""
    config_file = Path.home() / ".config" / "mytool" / "token"
    if config_file.exists():
        config_file.unlink()
```

## Testing Pattern

```python
# tests/test_cli.py
import json

from typer.testing import CliRunner

from <package>.cli import app

runner = CliRunner()


def test_help():
    """--help shows usage."""
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    assert "<tool>" in result.stdout


def test_version():
    """--version shows version."""
    result = runner.invoke(app, ["--version"])
    assert result.exit_code == 0
    assert "0.1.0" in result.stdout


def test_list_json():
    """list --json outputs valid JSON."""
    result = runner.invoke(app, ["items", "list", "--json"])
    assert result.exit_code == 0
    data = json.loads(result.stdout)
    assert "data" in data


def test_not_found():
    """get nonexistent returns exit code 3."""
    result = runner.invoke(app, ["items", "get", "nonexistent-id"])
    assert result.exit_code == 3


def test_json_error():
    """Errors output valid JSON with --json."""
    result = runner.invoke(app, ["items", "get", "bad-id", "--json"])
    assert result.exit_code == 3
    data = json.loads(result.stdout)
    assert "error" in data
    assert data["error"]["code"] == "NOT_FOUND"
```

## Project Structure

```
<tool>/
├── README.md              # User documentation
├── pyproject.toml         # Package config
├── src/<package>/
│   ├── __init__.py        # Version
│   ├── cli.py             # Typer CLI entry point
│   ├── client.py          # API client
│   ├── config.py          # Settings & token storage
│   └── models.py          # Pydantic models (optional)
└── tests/
    ├── conftest.py
    ├── test_cli.py
    └── test_client.py
```

## pyproject.toml

```toml
[project]
name = "<tool>-cli"
version = "0.1.0"
description = "What this tool does"
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "typer>=0.9.0",
    "rich>=13.0.0",
    "httpx>=0.25.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "ruff>=0.3.0",
]

[project.scripts]
<tool> = "<package>.cli:app"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/<package>"]

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP"]

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"
```
