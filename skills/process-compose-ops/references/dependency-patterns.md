# Dependency Patterns (depends_on)

How to express startup ordering and runtime dependencies between processes.

## The Four Conditions

| Condition | Meaning | Best for |
|---|---|---|
| `process_started` | Dependency has spawned (PID exists, may not be ready) | Coarse ordering when readiness doesn't matter |
| `process_healthy` | Dependency's `readiness_probe` passes | Runtime services that must be queryable |
| `process_completed` | Dependency exited (any code) | One-shot tasks that may fail |
| `process_completed_successfully` | Dependency exited with code 0 | One-shot init that must succeed |

## Pattern 1 — Web app + companion daemon

A common pattern: a web service + a worker daemon that talks to the same DB or queue. Daemon should start AFTER the web app has its DB connection pool warm.

```yaml
processes:
  webapp:
    command: "uv run python manage.py serve --port 8000"
    working_dir: "D:/code/MyApp"
    readiness_probe:
      http_get: { host: localhost, port: 8000, path: / }
      initial_delay_seconds: 10
    availability: { restart: always }

  worker:
    command: "uv run python -m myapp.worker"
    working_dir: "D:/code/MyApp"
    depends_on:
      webapp:
        condition: process_healthy
    availability: { restart: always }
```

Result: `worker` doesn't start until `webapp`'s readiness probe passes. If `webapp` restarts, `worker` keeps running (depends_on is a startup ordering rule, not a runtime tether).

## Pattern 2 — Three-tier chain

Web app + background daemon + audit watcher (Axiom pattern):

```yaml
processes:
  app:
    command: "..."
    readiness_probe: { ... }

  app-daemon:
    command: "..."
    depends_on:
      app:
        condition: process_healthy

  app-feedback:
    command: "..."
    depends_on:
      app:
        condition: process_started   # weaker — just needs app's pid to exist
```

## Pattern 3 — Database before app

Postgres in the same PC stack, app depends on it:

```yaml
processes:
  postgres:
    command: "postgres -D /var/lib/pg"
    readiness_probe:
      tcp_socket: { host: localhost, port: 5432 }
      initial_delay_seconds: 3

  migrate:
    command: "alembic upgrade head"
    working_dir: "X:/MyApp"
    depends_on:
      postgres:
        condition: process_healthy
    availability:
      restart: exit_on_failure   # one-shot; if it fails, the whole stack fails

  app:
    command: "uvicorn main:app"
    working_dir: "X:/MyApp"
    depends_on:
      migrate:
        condition: process_completed_successfully
      postgres:
        condition: process_healthy
    availability: { restart: always }
```

`migrate` runs once, must succeed. `app` waits for both `migrate` (success) and `postgres` (healthy).

## Pattern 4 — Tunnel that depends on the service it tunnels

E.g. Cloudflare tunnel exposing a local service:

```yaml
processes:
  mcp-server:
    command: "fastmcp serve --port 8000"
    readiness_probe:
      http_get: { host: localhost, port: 8000, path: / }
      initial_delay_seconds: 5

  mcp-tunnel:
    command: '"C:/Program Files/cloudflared/cloudflared.exe" tunnel run my-tunnel'
    depends_on:
      mcp-server:
        condition: process_healthy   # don't open tunnel until server is ready
    availability:
      restart: always
      backoff_seconds: 5
      max_restarts: 50               # tunnels can disconnect, allow many retries
```

## Pattern 5 — Static (one-time) setup task

```yaml
processes:
  fetch-secrets:
    command: "python scripts/fetch_secrets.py"
    availability:
      restart: exit_on_failure   # must complete; stop the project if it fails
    # No readiness_probe — task either completes or doesn't

  app:
    command: "..."
    depends_on:
      fetch-secrets:
        condition: process_completed_successfully
```

## Cycle Detection

PC detects cycles at startup. This fails immediately:

```yaml
processes:
  a: { depends_on: { b: { condition: process_started } } }
  b: { depends_on: { a: { condition: process_started } } }
# Error: dependency cycle detected: a -> b -> a
```

## What `depends_on` Does NOT Do

- **Does not** restart dependents when a dependency restarts. If `webapp` crashes and recovers, `worker` doesn't automatically restart.
- **Does not** stop a dependent when the dependency stops. You'll need to model this with `restart: exit_on_failure` and probes.
- **Does not** enforce shutdown order (PC shuts down in any order unless `--ordered-shutdown` flag is used).

For runtime coupling, the dependent process needs application-level reconnect/retry logic.

## Shutdown Ordering

By default PC shuts processes down in any order. For services with stateful deps, use:

```bash
process-compose down --ordered-shutdown
# Stops in reverse dependency order: dependents first, then dependencies
```

## See Also

- `probe-patterns.md` for crafting good `readiness_probe`s (without these, `process_healthy` is useless)
- `schema-reference.md` for full availability/shutdown field semantics
