# Dev Servers — always via a registered service stack

Companion to the [`process-compose-ops`](../skills/process-compose-ops/SKILL.md) and
[`portless-ops`](../skills/portless-ops/SKILL.md) skills. This file is the *directive* —
what to do every time a local server is about to be started, in any project.

> **Template rule.** The pattern — registered services, one port registry, no ad-hoc
> servers — is the portable part. The concrete values are yours: where your stack
> lives (`<stack-dir>`), where its port registry is (`<stack-dir>/ports.yaml`), your
> local URL scheme, and the script or skill that registers a service. Record them in
> your private `CLAUDE.md` so an agent on your machine knows them; keep this file
> generic.

## The rule

**Never start a local dev server, preview server, or daemon ad-hoc.** Every local web
server runs under your supervised stack — a process manager such as Process Compose for
lifecycle, plus a named-URL proxy such as portless for routing (`https://<name>.<tld>`).
Before binding ANY port, check the port registry.

When a task needs a server — serving an app, previewing a build, spinning up an API,
adding an MCP server — **register it with the stack**; don't reach for `npm run dev` /
`python -m http.server` / `uvicorn` on a made-up port.

## Why this matters

Ad-hoc servers are how a workstation gets port clashes and orphaned processes. In one
real case an orphaned dev process kept holding a registered service's pinned port, and
the supervisor restarted that service into a silent crash-loop — thousands of restarts
over several hours before anyone noticed. Every unregistered `localhost:<random>` server
is a future collision with a pinned-port service, an untracked process that survives its
session, and a URL the user can't find again. Registered services get a stable named
URL, health checks, bounded restarts, logs, and a place on the stack's dashboard — for
free.

## Directives

| Situation | Directive |
|---|---|
| Task needs any server the user will open, or that outlives the task | Register it with the stack's add-service script or skill. Take the port from the registry's ranges. |
| Quick throwaway check (serve → curl → kill, same task) | Use the registry's reserved throwaway range (e.g. 8190–8199) only, and kill it before the task ends. Never leave it running. |
| Service misbehaving / needs restart, pause, logs | Use the process manager's CLI (`process restart/stop/start`, per-service logs). Don't mix in a second process manager. |
| Done with a service | Deregister it — don't let dead entries rot in the stack. |
| Port already in use | Find the holder (`Get-NetTCPConnection -LocalPort <p> -State Listen` on Windows, `lsof -iTCP:<p> -sTCP:LISTEN` on macOS/Linux), reap orphans — don't just increment the port number. |
| Tempted to tear down the whole stack or start the proxy by hand | Don't. Stop individual processes; the proxy belongs to its own supervisor (service, launchd/systemd unit, or scheduled task). |

## When to bend the rule

- Unit/integration test servers managed by a test runner (pytest, vitest, playwright)
  — those live and die inside the runner, run them normally.
- Explicit user instruction to run something outside the stack.
- Work inside WSL/containers with isolated networking.

## Cross-reference

- `process-compose-ops` / `portless-ops` skills — tool depth for the stack itself
- Your private `CLAUDE.md` — the concrete stack location, registry, and register/remove
  commands for this machine
