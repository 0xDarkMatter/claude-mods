---
name: python-env
description: Fast Python environment management with uv. 10-100x faster than pip for installs, venv creation, and dependency resolution. Triggers on: install Python package, create venv, pip install, setup Python project, manage dependencies, Python environment.
---

# Python Environment

## Purpose
Manage Python packages and virtual environments with extreme speed using uv (Rust-based, 10-100x faster than pip).

## Tools

| Tool | Command | Use For |
|------|---------|---------|
| uv | `uv pip install pkg` | Fast package installation |
| uv | `uv venv` | Virtual environment creation |
| uv | `uv pip compile` | Lock file generation |

## Usage Examples

### Package Installation

```bash
# Install package (10-100x faster than pip)
uv pip install requests

# Install multiple packages
uv pip install flask sqlalchemy pytest

# Install from requirements.txt
uv pip install -r requirements.txt

# Install with extras
uv pip install "fastapi[all]"

# Install specific version
uv pip install "django>=4.0,<5.0"
```

### Virtual Environments

```bash
# Create venv (fastest venv creation)
uv venv

# Create with specific Python version
uv venv --python 3.11

# Activate (still uses standard activation)
# Windows: .venv\Scripts\activate
# Unix: source .venv/bin/activate
```

### Dependency Management

```bash
# Generate lockfile from requirements.in
uv pip compile requirements.in -o requirements.txt

# Sync environment to lockfile
uv pip sync requirements.txt

# Show installed packages
uv pip list

# Uninstall package
uv pip uninstall requests
```

### Run Commands

```bash
# Run script in project environment
uv run python script.py

# Run with specific Python
uv run --python 3.11 python script.py
```

## When to Use

- Installing Python packages (always prefer over pip)
- Creating virtual environments
- Setting up new Python projects
- Managing dependencies
- Syncing development environments
