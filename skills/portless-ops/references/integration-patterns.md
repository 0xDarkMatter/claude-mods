# Integration Patterns

Portless is a routing layer. It pairs with a process supervisor that owns lifecycle. Three common combos:

## Pattern A — Portless + Process Compose (recommended for local dev)

The whole stack speaks YAML and gives you health checks, restart policies, dependencies, and an MCP server.

```yaml
# process-compose.yaml — supervisor owns processes
processes:
  myapp:
    command: "uv run python -m myapp"
    working_dir: "X:/path/to/myapp"
    readiness_probe:
      http_get: { host: localhost, port: 8000, path: / }
    availability: { restart: always }
```

```powershell
# Portless owns routing — aliases derive from supervisor config
portless proxy start --tld test
portless alias myapp 8000   # https://myapp.test → :8000
```

**Single source of truth:** `process-compose.yaml`. Aliases derive from it. See the [`process-compose-ops`](../../process-compose-ops/SKILL.md) skill for the supervisor side.

## Pattern B — Portless + Docker

When some services run in containers (databases, n8n, custom containers) and others run locally.

```bash
# Container started independently, listening on host port 5678
docker run -d -p 5678:5678 --name n8n n8nio/n8n

# Make it reachable at a named URL
portless alias n8n 5678
# → https://n8n.test
```

This decouples container lifecycle from portless. `docker stop n8n` doesn't affect portless's alias (URL just stops resolving until container's back up).

## Pattern C — Portless + PM2 (legacy, when migration isn't worth it)

Same shape as Pattern A:

```javascript
// ecosystem.config.js
module.exports = {
  apps: [
    { name: 'myapp', script: 'python', args: '-m myapp', cwd: 'X:/path/myapp' }
  ]
};
```

```powershell
# PM2 owns processes
pm2 start ecosystem.config.js

# Portless owns routing
portless alias myapp 8000
```

**Note:** PM2 5.x has 15+ known CVEs in its transitive npm dependencies (axios, lodash, tar, minimist...). Process Compose's Go-binary attack model is much narrower. New stacks should pick Pattern A.

## Pattern D — Portless Spawning the Process (no separate supervisor)

For zero-config / one-off / monorepo cases, portless can spawn the process itself:

```bash
# Run a Next.js dev server through the proxy
portless myapp next dev
# → https://myapp.test, with auto-assigned port

# From a monorepo root, run all packages' dev scripts
portless
```

Limitations:
- **No crash recovery** — if the process dies, portless does NOT restart it
- **No health checks** — only "process exists" matters
- **No dependencies** between processes

Good for: short-lived dev sessions, monorepos where everything is JS/TS and Vercel-like ergonomics matter.

Bad for: long-running services, dependency chains, anything you want supervised through a reboot. Use Pattern A instead.

## Pattern E — Portless + Tailscale (team sharing)

Share local dev with teammates without a public deployment:

```bash
# Start the proxy
portless proxy start --tld test

# Run with --tailscale to register a tailnet URL too
portless myapp --tailscale next dev
# → https://myapp.test                    (you, local)
# → https://yourdevbox.your-team.ts.net   (teammates, tailnet)
```

Requirements:
- `tailscale` CLI installed and connected
- HTTPS enabled on the tailnet (Tailscale admin console)
- For public sharing: Funnel enabled (`--funnel` instead of `--tailscale`)

See upstream docs (`references/upstream-portless.md`, section "Tailscale sharing") for the full setup.

## Pattern F — Subdomain Routing in a Monorepo

```bash
portless myapp next dev          # → https://myapp.test
portless api.myapp pnpm start    # → https://api.myapp.test
portless docs.myapp next dev     # → https://docs.myapp.test
```

Add `--wildcard` so any unregistered subdomain falls back to the parent:

```bash
portless proxy start --wildcard --tld test
# Now tenant1.myapp.test → routes to myapp (whatever's registered)
```

Useful for multi-tenant apps where you want to test tenant resolution locally.

## Pattern G — Git Worktrees with Per-Branch URLs

Portless auto-detects git worktrees and prepends the branch name as a subdomain:

```bash
# Main worktree
cd D:/code/myapp
portless run next dev
# → https://myapp.test

# Linked worktree on branch "fix-ui"
cd D:/code/myapp/.worktrees/fix-ui
portless run next dev
# → https://fix-ui.myapp.test
```

No config — just works. Each worktree gets its own URL automatically, avoiding browser cookie/storage cross-contamination between branches.

## Common Anti-Patterns

```
BAD:  use portless's spawn mode for production-equivalent local services
GOOD: use Pattern A (Process Compose supervisor + portless routing)

BAD:  let two different stacks fight over the same TLD
GOOD: pick TLD per machine, document it; or use different ports

BAD:  hardcode portless URLs in service config (e.g. CORS allowlists)
GOOD: read PORTLESS_URL env var that portless injects into spawned processes
      (Pattern D only); or use SERVICE_URL env injection in your supervisor

BAD:  install portless globally without pinning a version
GOOD: pin version: npm install -g portless@0.13.0; record in your repo
```

## See Also

- `process-compose-ops` skill for the supervisor side of Pattern A
- `references/upstream-portless.md` for full CLI reference (auto-port assignment, etc.)
- `references/tld-selection.md` for picking the right TLD up front
