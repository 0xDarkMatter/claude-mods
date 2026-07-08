---
name: process-compose-ops
description: "Process Compose orchestration for non-containerized local services: process-compose.yaml schema, health checks, restart policies, dependencies, TUI/REST/MCP control, scheduling, and boot persistence. Use as a PM2/supervisord/Foreman replacement for local dev service management."
license: MIT
allowed-tools: "Read Write Bash Edit"
metadata:
  author: claude-mods
  related-skills: portless-ops, docker-ops, cli-ops
  upstream: https://github.com/F1bonacc1/process-compose
---

# Process Compose Operations

Process Compose is a Go-based supervisor for non-containerized services. Single binary, YAML config, built-in TUI, REST API, **MCP server**, and proper Windows support. Replacement for PM2/supervisord/Foreman in the local-dev role.

**Why not PM2:** PM2 5.x has 15+ known CVEs (axios/lodash/tar/minimist transitive npm exposure). PC compiles all deps in at build time with `go.sum` hashes — structurally resistant to TanStack-style npm worm attacks.

**Why not Docker Compose:** Container overhead is unnecessary for local Python/Node/Go dev servers running directly. PC gives you health checks, dependencies, and restart policies without the container layer.

## Install (verified)

```bash
# Pin a specific version, verify SHA-256 against upstream checksums
VER="v1.110.0"
BASE="https://github.com/F1bonacc1/process-compose/releases/download/$VER"

curl -fsSL -o pc.zip "$BASE/process-compose_windows_amd64.zip"
curl -fsSL -o checksums.txt "$BASE/process-compose_checksums.txt"

EXPECTED=$(grep "process-compose_windows_amd64.zip" checksums.txt | awk '{print $1}')
ACTUAL=$(sha256sum pc.zip | awk '{print $1}')
[ "$EXPECTED" = "$ACTUAL" ] || { echo "HASH MISMATCH"; exit 1; }

unzip pc.zip
# Commit process-compose.exe to your repo's bin/ directory
```

Record the binary's hash in your repo's `SUPPLY-CHAIN.md` for re-verification on next upgrade.

## process-compose.yaml Quick Reference

```yaml
version: "0.5"

log_level: info
log_length: 1000

processes:

  my-service:
    command: "pythonw -m uvicorn main:app --host 127.0.0.1 --port 8000"
    working_dir: "X:/path/to/repo"
    environment:
      - "DJANGO_SETTINGS_MODULE=myapp.settings"
      - "PYTHONUNBUFFERED=1"
    readiness_probe:
      http_get:
        host: localhost
        port: 8000
        path: /
      initial_delay_seconds: 5
      period_seconds: 10
      timeout_seconds: 3
      failure_threshold: 3
    availability:
      restart: always           # always | exit_on_failure | on_failure | no
      backoff_seconds: 5
      max_restarts: 20
    depends_on:
      database:
        condition: process_healthy   # process_started | process_healthy | process_completed
    shutdown:
      signal: 15                # SIGTERM
      timeout_seconds: 30
    log_location: "logs/my-service.log"

  scheduled-job:
    command: "python backup.py"
    schedule: "0 2 * * *"       # 2am daily cron
    availability:
      restart: exit_on_failure
```

## Restart Policies

| Policy | Restarts on... |
|---|---|
| `always` | Any exit (success or failure) — best for long-running daemons |
| `on_failure` | Non-zero exit codes only |
| `exit_on_failure` | Stops PC entirely if this process fails — use for critical deps |
| `no` | Never restart |

## Dependency Conditions

| Condition | Wait until... |
|---|---|
| `process_started` | Dependency spawned (PID exists). Fastest, weakest guarantee. |
| `process_healthy` | Dependency's readiness_probe passes. Strong guarantee. |
| `process_completed` | Dependency exited successfully (for init/setup processes). |

## CLI Reference

```bash
# Lifecycle
process-compose up -f config.yaml          # Start (foreground TUI by default)
process-compose up -f config.yaml -t=false # Headless (no TUI)
process-compose up -f config.yaml --dry-run  # Validate config without starting
process-compose down                       # Stop all processes + project

# Inspection (against running PC)  (example values — substitute your own port/dir)
process-compose -p <your-pc-port> process list       # all processes + status
process-compose -p <your-pc-port> process logs <name> --follow
process-compose -p <your-pc-port> attach             # TUI for running project

# Process control
process-compose -p <your-pc-port> process restart <name>
process-compose -p <your-pc-port> process stop <name>
process-compose -p <your-pc-port> process start <name>

# Reload config without stopping (hot update)
process-compose -p <your-pc-port> project update -f config.yaml

# Standalone inspection (no running PC)
process-compose info                       # config home info
process-compose graph -f config.yaml       # dependency graph
process-compose analyze -f config.yaml     # startup timing analysis
```

**Key flag gotcha:** there's no `--detached` flag. To run in background:
- Linux/Mac: `process-compose up -t=false &` (shell backgrounding)
- Windows: launch via Task Scheduler or `Start-Process` with `-WindowStyle Hidden`

## TUI Navigation

Launch: `process-compose attach` (or `up` without `-t=false`).

| Key | Action |
|---|---|
| `↑` `↓` or `j` `k` | Navigate process list |
| `Tab` | Switch focus between process list and log pane |
| `F4` | Maximize current pane (toggle) |
| `F5` | Unfollow logs (lets you scroll history) |
| `F6` | Unwrap log lines |
| `r` | Restart selected process |
| `s` | Stop selected process |
| `t` | Start selected process |
| `/` | Filter process list |
| `?` | Help overlay |
| `q` | Quit TUI (PC keeps running in background) |

## MCP Server Integration

PC ships a built-in MCP server exposing processes as tools for AI agents. Enable via the config or CLI flag. With the MCP server on, a Claude Code agent can directly:

- List running processes
- Get process status/health
- Restart/stop/start processes
- Read process logs

This replaces shell-based glue scripts (the old PM2-broker pattern).

## API Port Selection

Default API port is 8080. Common collisions:

| Port 8080 user | Workaround |
|---|---|
| Dagu dashboard | Use `-p <your-pc-port>` until Dagu decommissioned |
| Tomcat / Spring Boot dev | Use `-p <your-pc-port>` |
| Other dev tool defaults | Pick anything free in 8000–9999 range |

If you change the API port, every subsequent CLI call needs `-p <port>`:

```bash
process-compose -p <your-pc-port> process list
process-compose -p <your-pc-port> process logs axiom --follow
```

## Windows Boot Persistence Pattern

Task Scheduler runs with minimal PATH. Use a wrapper script that sets PATH explicitly before launching PC.

```powershell
# scripts/boot-start.ps1
$root = "<your-process-compose-dir>"
$pcExe = "$root\bin\process-compose.exe"

# Explicit PATH for managed services (Python, uv, Git tools, cloudflared, etc.)
$env:PATH = (@(
    "$root\bin"
    "C:\Program Files\Git\usr\bin"          # openssl, bash
    "C:\Users\<user>\AppData\Local\Programs\Python\Python313\Scripts"
    "$env:PATH"
) -join ';')

# Optional: source secrets from gitignored .env
$envFile = "$root\.env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}

# Launch headless
& $pcExe -p <your-pc-port> -t=false -L "$root\logs\process-compose.log" up -f "$root\process-compose.yaml"
```

Register as a Task Scheduler entry with `LogonType S4U` (runs at boot, no password, no interactive logon needed):

```powershell
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\scripts\boot-start.ps1`""
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "ProcessCompose-Boot" `
    -Action $action -Trigger $trigger -Principal $principal -Force
```

## YAML Gotchas

| Gotcha | Symptom | Fix |
|---|---|---|
| Windows PATH with backslashes in double-quoted YAML | `yaml: found unknown escape character` | Use single quotes: `- 'PATH=C:\Program Files\Git\usr\bin;...'` |
| `command` with quoted paths containing spaces | First arg eaten | Wrap whole command in single quotes, inner paths in double: `'"C:/Program Files/foo.exe" arg1 arg2'` |
| Forgot `working_dir` | Process starts in PC's cwd, can't find files | Always specify absolute `working_dir` |
| Health probe wrong port | Process restart-loops with `Not Ready` | Match `readiness_probe.http_get.port` to where the process actually binds |
| Secrets in YAML | Committed to git | Use `environment` to pass-through; set in shell env or gitignored `.env` |

## Common Operations

```bash
# Validate config before applying
process-compose up --dry-run -f process-compose.yaml

# Hot-reload after editing config
process-compose -p <your-pc-port> project update -f process-compose.yaml

# Restart one service after code change
process-compose -p <your-pc-port> process restart axiom

# Watch logs of a misbehaving service
process-compose -p <your-pc-port> process logs axiom --follow

# Stop one service temporarily for debugging
process-compose -p <your-pc-port> process stop axiom
# Now run it manually with your debugger, then:
process-compose -p <your-pc-port> process start axiom
```

## When to Use Process Compose vs Alternatives

| Need | Tool |
|---|---|
| Local non-containerized services with health/dependencies/MCP | **Process Compose** |
| Production node.js process supervision | PM2 (despite age) |
| Container-based stack | Docker Compose |
| Job queue with cron + DAGs | Dagu, Temporal, Airflow |
| System service supervision | systemd (Linux), Windows Services |
| One-shot Procfile run | Foreman / Overmind / Hivemind (Unix-only) |

## Worked Example

See `<your-process-compose-dir>\` for an 11-process production stack:
- `process-compose.yaml` — health-checked services with depends_on chains
- `scripts/boot-start.ps1` — PATH-aware boot wrapper
- `docs/MIGRATION-LOG.md` — full migration from PM2 + Caddy, every gotcha documented
- `docs/SUPPLY-CHAIN.md` — binary verification procedure

## Anti-Patterns

```
BAD:  process-compose up --detached       # flag does not exist
GOOD: process-compose up -t=false &       # background via shell

BAD:  put secrets in process-compose.yaml (commits to git)
GOOD: source from gitignored .env in boot wrapper

BAD:  use API port 8080 (clashes with Dagu, Tomcat, others)
GOOD: -p <your-pc-port> (or any free port), document the choice

BAD:  ignore readiness_probe and just hope services come up
GOOD: configure http_get probe on a real endpoint; depends_on uses process_healthy

BAD:  upgrade PC by running an installer (npm install -g, scoop install, brew install)
GOOD: download specific version, verify SHA-256 against upstream checksums.txt, commit binary
```

## Resources in this skill

### `references/`
- `schema-reference.md` — full process-compose.yaml schema with field semantics, defaults, and command-quoting gotchas
- `probe-patterns.md` — readiness probe recipes by stack (Python, Go, Node, TCP-only, daemons)
- `dependency-patterns.md` — `depends_on` patterns: companion daemons, DB-before-app, tunnel-after-service, one-shot init
- `tui-shortcuts.md` — TUI cheatsheet (keys, status legend, search/sort/filter)
- `boot-persistence-windows.md` — Task Scheduler setup with S4U logon, PATH-aware wrapper
- `supply-chain-verification.md` — full SHA-256 verification procedure for the binary

### `scripts/`
- `install-process-compose.ps1` — download + verify + extract a pinned version, writes VERIFICATION.md
- `verify-binary.ps1` — re-verify committed binary hash (monthly / pre-commit)
- `boot-start.template.ps1` — PATH-aware boot wrapper (copy + adapt per machine)
- `boot-task-install.template.ps1` — Task Scheduler entry registration (S4U logon)

### `assets/`
- `python-uvicorn.yaml` — uvicorn/FastAPI/Django basic service template
- `django-with-companions.yaml` — Django + queue daemon + audit watcher chain
- `go-binary-service.yaml` — Go binary with HTTP or TCP probe
- `tunnel-with-dependency.yaml` — Cloudflare tunnel waiting on its target service
- `cron-job.yaml` — scheduled task patterns

## Related Skills

- `portless-ops` — the routing layer we pair with PC (replaces Caddy)
- `docker-ops` — container alternative for the same role
- `mcp-ops` — PC's MCP server fits this ecosystem
- `cli-ops` — general CLI tool patterns
