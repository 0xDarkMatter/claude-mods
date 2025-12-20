---
name: python-env
description: "Fast Python environment management with uv (10-100x faster than pip). Triggers on: uv, venv, pip, pyproject, python environment, install package, dependencies."
compatibility: "Requires uv CLI tool. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"
allowed-tools: "Bash"
---

# Python Environment

Fast Python environment management with uv (10-100x faster than pip).

## Quick Commands

| Task | Command |
|------|---------|
| Create venv | `uv venv` |
| Install package | `uv pip install requests` |
| Install from requirements | `uv pip install -r requirements.txt` |
| Run script | `uv run python script.py` |
| Show installed | `uv pip list` |

## Virtual Environment

```bash
# Create venv (instant)
uv venv

# Create with specific Python
uv venv --python 3.11

# Activate
# Windows: .venv\Scripts\activate
# Unix: source .venv/bin/activate

# Or skip activation and use uv run
uv run python script.py
```

## Package Installation

```bash
# Single package
uv pip install requests

# Multiple packages
uv pip install flask sqlalchemy pytest

# With extras
uv pip install "fastapi[all]"

# Version constraints
uv pip install "django>=4.0,<5.0"

# From requirements
uv pip install -r requirements.txt

# Uninstall
uv pip uninstall requests
```

## pyproject.toml Configuration

### Minimal Project
```toml
[project]
name = "my-project"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = [
    "httpx>=0.25",
    "pydantic>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=7.0",
    "ruff>=0.1",
]
```

### With Build System
```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "my-package"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = [
    "httpx>=0.25",
]

[project.optional-dependencies]
dev = ["pytest", "ruff", "mypy"]
docs = ["mkdocs", "mkdocs-material"]

[project.scripts]
my-cli = "my_package.cli:main"
```

### With Tool Configuration
```toml
[tool.ruff]
line-length = 100
target-version = "py310"

[tool.ruff.lint]
select = ["E", "F", "I", "UP"]

[tool.pytest.ini_options]
testpaths = ["tests"]
asyncio_mode = "auto"

[tool.mypy]
python_version = "3.10"
strict = true
```

## Dependency Management

### Lock File Workflow
```bash
# Create requirements.in with loose constraints
echo "flask>=2.0" > requirements.in
echo "sqlalchemy>=2.0" >> requirements.in

# Generate locked requirements.txt
uv pip compile requirements.in -o requirements.txt

# Install exact versions
uv pip sync requirements.txt

# Update locks
uv pip compile requirements.in -o requirements.txt --upgrade
```

### Dev Dependencies Pattern
```bash
# requirements.in (production)
flask>=2.0
sqlalchemy>=2.0

# requirements-dev.in
-r requirements.in
pytest>=7.0
ruff>=0.1

# Compile both
uv pip compile requirements.in -o requirements.txt
uv pip compile requirements-dev.in -o requirements-dev.txt
```

## Workspace/Monorepo

```toml
# pyproject.toml (root)
[tool.uv.workspace]
members = ["packages/*"]

# packages/core/pyproject.toml
[project]
name = "my-core"
version = "0.1.0"

# packages/api/pyproject.toml
[project]
name = "my-api"
version = "0.1.0"
dependencies = ["my-core"]
```

```bash
# Install all workspace packages
uv pip install -e packages/core -e packages/api
```

## Running Scripts

```bash
# Run with project's Python
uv run python script.py

# Run with specific Python version
uv run --python 3.11 python script.py

# Run module
uv run python -m pytest

# Run installed CLI
uv run ruff check .
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No Python found" | `uv python install 3.11` or install from python.org |
| Wrong Python version | `uv venv --python 3.11` to force version |
| Conflicting deps | `uv pip compile --resolver=backtracking` |
| Cache issues | `uv cache clean` |
| SSL errors | `uv pip install --cert /path/to/cert pkg` |

## Project Setup Checklist

```bash
# 1. Create project structure
mkdir my-project && cd my-project
mkdir src tests

# 2. Create venv
uv venv

# 3. Create pyproject.toml (see templates above)

# 4. Install dependencies
uv pip install -e ".[dev]"

# 5. Verify
uv pip list
uv run python -c "import my_package"
```

## When to Use

- **Always** use uv over pip for speed
- Creating virtual environments
- Installing packages
- Managing dependencies
- Running scripts in project context
- Compiling lockfiles
