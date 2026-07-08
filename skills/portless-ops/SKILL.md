---
name: portless-ops
description: "Portless local-dev HTTPS proxy: replaces port numbers with named URLs (Caddy/nginx alternative for local dev). Triggers on: portless, local https proxy, named localhost URL, custom TLD, portless alias, portless.json, local CA trust, boot persistence, monorepo routing, Tailscale dev sharing."
license: MIT
allowed-tools: "Read Write Bash Edit"
metadata:
  author: claude-mods
  related-skills: process-compose-ops, mcp-ops, cli-ops
  upstream: https://github.com/vercel-labs/portless
---

# Portless Operations

Portless (Vercel Labs) is a local-dev HTTPS proxy that replaces port numbers with named URLs. Replacement for Caddy/nginx in the local-dev role; not for production.

**Upstream:** [vercel-labs/portless](https://github.com/vercel-labs/portless) (Apache-2.0). The portless repo ships canonical skills in its source tree (not in the npm package). Verbatim copies kept in `references/`:

- **[`references/upstream-portless.md`](references/upstream-portless.md)** — full CLI reference, integration patterns (zero-config, monorepo, turborepo, worktrees, Tailscale), HTTPS/LAN setup, troubleshooting
- **[`references/upstream-oauth.md`](references/upstream-oauth.md)** — OAuth provider compatibility (Google, Apple, Microsoft, Facebook, GitHub), TLD selection for OAuth, callback URI configuration

This SKILL.md adds **operational patterns** we've validated in production (Windows specifics, the static-alias-with-supervisor pattern, TLD-reset procedure, supply-chain hygiene). For canonical CLI usage, prefer the upstream reference files.

## Mental Model

| Layer | Portless owns | Portless does NOT own |
|---|---|---|
| Routing | hostname → port mapping, HTTPS termination, HTTP/2, CA trust | process supervision (use Process Compose or PM2) |
| Naming | `<name>.<tld>` shape — one TLD per proxy | per-service distinct TLDs (not supported) |
| Process spawning | when invoked as `portless myapp <cmd>` | crash recovery, restart policy, health checks |

**Key shape constraint:** portless always renders `<alias-name>.<tld>`. You can't mix two TLDs in one proxy because TLD is per-instance — a dotted alias like `portless alias api.<app> 8108` gets the TLD appended → `api.<app>.<tld>`.

## Install

```bash
# Pin a specific version (zero runtime deps, low supply-chain surface)
npm install -g portless@0.13.0

# Verify
portless --version
```

Record the pinned version in your repo. Upgrades are explicit PRs.

## CLI Quick Reference

```bash
# example values — substitute your own (TLD, app name, ports)
# Proxy lifecycle
portless proxy start --tld lab --port 443   # HTTPS proxy on 443, *.lab routes
portless proxy start --tld test --port 1355 # Non-privileged port for testing
portless proxy stop
portless trust                              # Add CA to system trust store

# Aliases (for services portless didn't spawn — PM2, Process Compose, Docker, etc.)
portless alias axiom 8108                   # https://axiom.lab → :8108
portless alias axiom 8108 --force           # Overwrite existing
portless alias --remove axiom               # Note: appends TLD! be careful

# Spawn-mode (portless manages the process)
portless myapp next dev                     # https://myapp.lab, auto port 4000-4999
portless run pnpm dev                       # Auto-infer name from package.json

# Discovery (agent-friendly)
portless list                               # Active routes
portless get axiom                          # Returns: https://axiom.lab

# Boot persistence
portless service install                    # OS-native startup task
portless service status
portless service uninstall
```

## The Static-Alias Pattern (portless + external process supervisor)

The common pattern: a process supervisor (Process Compose, PM2, Docker) runs your dev servers on fixed ports. Portless just routes named URLs to those ports.

```bash
# Started by Process Compose, listening on <your-port>
# Now make it reachable at https://<your-app>.<your-tld>
portless alias <your-app> <your-port>
```

Decoupling means:
- Restart the dev server (`pm2 restart <your-app>`, `process-compose process restart <your-app>`) → portless keeps routing transparently
- Swap one supervisor for another → portless layer is untouched

**Source of truth pattern:** keep alias registration in your supervisor config. Example `scripts/install.ps1`:

```powershell
$services = (yq '.processes | keys | .[]' process-compose.yaml)
foreach ($svc in $services) {
  $port = (yq ".processes.$svc.readiness_probe.http_get.port" process-compose.yaml)
  if ($port -and $port -ne "null") {
    portless alias $svc $port --force
  }
}
```

## TLD Selection

| TLD | When to use | Caveats |
|---|---|---|
| `.localhost` (default) | Quickest start | Auto-resolves to 127.0.0.1 on most systems |
| `.lab` | Personal/distinctive | Not IANA-reserved (no DNS collision in practice for local) |
| `.test` | OAuth-friendly | IANA-reserved; safe |
| `.dev` | OAuth (Google, Apple) | Google-owned, forces HTTPS — portless handles this fine |
| `.local` | Avoid | mDNS/Bonjour conflict |

OAuth providers reject `.localhost` subdomains (not in Public Suffix List). Switch to `--tld test` or `--tld dev` for OAuth dev work. See [`references/upstream-oauth.md`](references/upstream-oauth.md) for full per-provider setup.

## Reset (clean slate)

```bash
# Stop proxy
portless proxy stop

# Wipe all aliases (routes.json)
rm ~/.portless/routes.json    # Linux/macOS
Remove-Item "$env:USERPROFILE\.portless\routes.json"   # PowerShell

# Start fresh with desired TLD
portless proxy start --tld <tld> --port 443

# Re-register aliases from your supervisor config
```

This is the right pattern when you change TLD — `portless alias --remove` appends the active TLD which makes it fight you.

## Windows-Specific Notes

### `openssl` required on PATH

Portless uses OpenSSL to generate the local CA. Git for Windows ships it:

```powershell
# Persistent: add to user PATH
$gitBin = "C:\Program Files\Git\usr\bin"
$current = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($current -notlike "*$gitBin*") {
    [Environment]::SetEnvironmentVariable("PATH", "$gitBin;$current", "User")
}
```

Without it: `Error: openssl failed: spawnSync openssl ENOENT`

### Boot persistence

`portless service install` registers a Task Scheduler entry. Pair it with your supervisor's own boot task (e.g., for Process Compose, register a separate task via `scripts/boot-task-install.ps1`).

Verify both registered:

```powershell
Get-ScheduledTask | Where-Object {
    $_.TaskName -like "*ortless*" -or $_.TaskName -like "*ompose*"
}
```

### curl vs browser cert handling

curl on Windows uses its own bundled CA store, not the system one. So `curl https://<your-app>.<your-tld>/` returns code 000 (cert untrusted) even after `portless trust`. Browsers work fine because they use the system store.

Test from curl with `-k` (skip verify), or `--cacert ~/.portless/ca.pem`:

```bash
curl -k https://<your-app>.<your-tld>/        # quick test
curl --cacert ~/.portless/ca.pem https://<your-app>.<your-tld>/   # proper
```

## Common Errors

| Error | Cause | Fix |
|---|---|---|
| `openssl failed: spawnSync openssl ENOENT` | OpenSSL not on PATH | Add Git's `usr/bin` to PATH |
| `Error: No alias found for "foo.lab"` (you asked for `foo`) | `--remove` appends TLD; sometimes adds an extra | Wipe `routes.json` and re-register |
| Browser shows cert warning | CA not in system trust store | Re-run `portless trust` (may need admin) |
| `https://name.lab` shows "No app registered" | Alias not set or proxy stopped | `portless list` to confirm; re-register if needed |
| Safari can't resolve `*.lab` | Safari uses system DNS, not Node's resolver | `portless hosts sync` to write /etc/hosts |
| Port 443 conflict on `portless proxy start` | Another service bound (Caddy, IIS) | Stop the other service, or use `--port 1355` for testing |

## Worked Example: Replacing Caddy with portless

See `~/X/00_Orchestration/compose-portless/` for a worked migration from PM2+Caddy to Process Compose+portless. Key files:

- `process-compose.yaml` — supervisor config with health-checked services
- `scripts/cutover.ps1` — stops PM2/Caddy, starts portless+PC, registers aliases
- `docs/MIGRATION-LOG.md` — every issue hit during cutover and how it was solved
- `docs/SUPPLY-CHAIN.md` — pinning + verification procedures

## Anti-Patterns

```
BAD:  portless alias name 8000; portless alias name 8001   # second silently fails without --force
GOOD: portless alias name 8001 --force

BAD:  use portless as production reverse proxy
GOOD: keep portless as dev-only; production = nginx/Caddy/cloud LB

BAD:  rely on portless for crash recovery (it has none for spawned processes)
GOOD: pair portless with Process Compose / PM2 / supervisord for supervision

BAD:  change TLD by stopping/starting with different --tld and hoping aliases update
GOOD: stop proxy, wipe routes.json, start with new TLD, re-register from supervisor config
```

## Resources in this skill

### `references/`
- `upstream-portless.md` — canonical portless SKILL.md verbatim (CLI ref, monorepo, turborepo, worktrees, LAN, Tailscale, HTTPS, troubleshooting)
- `upstream-oauth.md` — canonical OAuth setup for Google/Apple/Microsoft/Facebook/GitHub
- `tld-selection.md` — decision tree for picking the right TLD; trade-offs of `.test`/`.dev`/`.localhost`/custom-owned
- `windows-specifics.md` — openssl PATH, certutil quirks, curl-vs-browser cert handling, PS 5.1 gotchas
- `integration-patterns.md` — combos with Process Compose / Docker / PM2 / Tailscale / git worktrees

### `scripts/`
- `install-portless.ps1` — verified install: inspect tarball, scan for IOCs from recent attacks, install only if clean
- `reset-state.ps1` — clean state reset (used when changing TLD; `--remove` can't clear old-TLD aliases)
- `sync-aliases-from-yaml.ps1` — derive portless aliases from a process-compose.yaml

### `assets/`
- `portless.json.simple.json` — single-app config template
- `portless.json.monorepo.json` — workspace monorepo with name overrides
- `portless.json.with-custom-tld.json` — documents TLD choice in repo
- `package.json-portless-key.json` — alternative: portless config inside package.json

## Related Skills

- `process-compose-ops` — the supervisor we pair with portless
- `mcp-ops` — agent-friendly tooling; portless `get <name>` provides URL discovery for agents
- `cli-ops` — general CLI tool patterns
