# Dev Servers — always via the Process Compose stack

Companion to the generic [`process-compose-ops`](../skills/process-compose-ops/SKILL.md)
and [`portless-ops`](../skills/portless-ops/SKILL.md) skills (shipped with this plugin)
and a machine-local `pcserve` skill (the author's playbook — not shipped). This file is
the *directive* — what to do every time a local server is about to be started, in any
project on this machine.

> **Portability note:** the stack location (`X:\00_Orchestration\compose-portless`),
> port registry, `.lab` URLs, and the `pcserve` skill are specific to the author's
> machine. Treat this rule as a template: point it at your own process-compose +
> portless setup (or equivalent process manager and port registry). The pattern —
> registered services, one port registry, no ad-hoc servers — is the portable part.

## The rule

**Never start a local dev server, preview server, or daemon ad-hoc.** Every local web
server on this machine runs under the Process Compose stack at
`X:\00_Orchestration\compose-portless` (lifecycle) + portless (HTTPS routing,
`https://<name>.lab`). Before binding ANY port, check the registry at
`X:\00_Orchestration\shared\ports.yaml`.

When a task needs a server — serving an app, previewing a build, spinning up an API,
adding an MCP server — **invoke the `pcserve` skill** and register it, don't reach for
`npm run dev` / `python -m http.server` / `uvicorn` on a made-up port.

## Why this matters

Ad-hoc servers are how this machine gets port clashes and orphaned processes. On
2026-07-03 an orphaned dev process holding port 8113 put the registered `glyph`
service into a silent 5-second crash-loop — **3,603 restarts over 5.5 hours**. Every
unregistered `localhost:<random>` server is a future collision with a pinned-port
service, an untracked process that survives its session, and a URL the user can't
find again. Registered services get a stable `.lab` URL, health checks, bounded
restarts, logs, and show up on the `https://home.lab` dashboard — for free.

## Directives

| Situation | Directive |
|---|---|
| Task needs any server the user will open, or that outlives the task | Register it: `pcserve` skill → `add-service.ps1`. Port from `shared/ports.yaml` ranges. |
| Quick throwaway check (serve → curl → kill, same task) | Bind **8190–8199** only, and kill it before the task ends. Never leave it running. |
| Service misbehaving / needs restart, pause, logs | PC CLI via `pcserve` — `process restart/stop/start`, read `logs\<name>.log`. Never `pm2 *`. |
| Done with a service | `remove-service.ps1` — don't let dead entries rot in the stack. |
| Port already in use | Find the holder (`Get-NetTCPConnection -LocalPort <p> -State Listen`), reap orphans — don't just increment the port number. |
| Tempted to `process-compose down` or `portless proxy start` | Don't. Individual `process stop`; proxy is the `Portless Proxy` scheduled task. |

## When to bend the rule

- Unit/integration test servers managed by a test runner (pytest, vitest, playwright)
  — those live and die inside the runner, run them normally.
- Explicit user instruction to run something outside the stack.
- Work inside WSL/containers with isolated networking.

## Cross-reference

- `~/.claude/skills/pcserve/SKILL.md` — the workflow playbook (machine-local, not shipped)
- `X:\00_Orchestration\compose-portless\AGENTS.md` — stack golden rules (machine-local)
- `process-compose-ops` / `portless-ops` skills — generic tool depth (shipped)
