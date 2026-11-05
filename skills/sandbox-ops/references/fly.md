# Fly Machines: plain Firecracker VMs, the cheap Australian fallback

Facts verified 2026-11-05. `scripts/check-sandbox-facts.py --provider fly` re-checks the
catalogued ones in `assets/facts-providers.json`.

Tags: **[docs]** a Fly docs page read 2026-11-05; **[report]** the 2026-11-05 provider
research; **[inferred]** our own reading. Nothing here was measured on a real account.

Fly is the lighter card: a do-it-yourself box rather than an agent-sandbox product. It is
the first alternate if Australian residency becomes a hard requirement. Fly's agent
product, Sprites, was not researched [report: https://docs.fly.io/sprites/index.md].

## What it is

- A Firecracker VM per Machine, running your image's user, usually root
  [report: https://docs.fly.io/reference/architecture].
- Plain SSH (`fly ssh console`) and a documented REST API at `api.machines.dev`; no
  official SDK [report].
- shared-cpu-4x with 8 GB about $0.071 an hour in `iad`; performance-4x about $0.233 in
  `syd` [report: https://docs.fly.io/about/pricing].
- No free tier: a $1 trial credit lasts 7 days [docs: https://docs.fly.io/about/pricing.md].
- Root filesystem 8 GiB, one volume, no Docker daemon in the official guide, and no
  documented outbound firewall [report].

## The lifetime trap

- The restart policy defaults to `always` unless the Machine runs with `--rm`, so a
  one-shot job restarts [report]. Use `fly machine run --rm` (sets `auto_destroy`).
- A stopped Machine still bills its root filesystem, and a volume bills for its
  provisioned size even when detached [docs: pricing]. Delete both.
- The root filesystem resets on start unless `persist_rootfs` is set [report].

## Keys and scope

- Set `FLY_API_TOKEN` and flyctl uses it for every command; **it takes precedence over the
  token saved by a prior `fly auth login`** [docs: https://docs.fly.io/flyctl/integrating].
  If `FLY_ACCESS_TOKEN` is also set, it wins [docs].
- Scoped tokens are valid for **20 years** by default
  [docs: https://docs.fly.io/security/tokens]. Always pass `--expiry` with the
  shortest duration that works.

## Residency and network

- 17 regions including `syd`, `sin`, `nrt` and the EU [report].
- Inbound through Fly Proxy `--port`; no outbound controls are documented [report].

## Delete and confirm

- `fly machine run --rm ...` destroys the Machine when it exits; otherwise
  `fly machine destroy <id> --force`.
- Confirm with `GET /v1/apps/{app}/machines?include_deleted` [report], or `fly machine
  list --json` no longer showing it. `FLY_APP=<app> confirm-gone.sh --provider fly <id>`
  runs that list for you (flyctl reads the app from `FLY_APP`).

## Driver verbs on Fly

| fleetflow verb | Fly |
|---|---|
| up | `fly machine run <image> --rm --app <app> --region syd` |
| exec | `fly ssh console --app <app> --machine <id> -C '<cmd>'` |
| put / get | `fly ssh sftp`, or ssh stdin / stdout |
| stream | `fly ssh console` |
| extend | none needed: a Machine has no lifetime limit, so you must delete it |
| down + confirm | `fly machine destroy <id> --force`, then `confirm-gone.sh --provider fly` |
| list | `fly machine list --app <app> --json` |

## Sources

- https://docs.fly.io/flyctl/integrating, https://docs.fly.io/security/tokens,
  https://docs.fly.io/about/pricing (read 2026-11-05).
- Research report 2026-11-05: architecture, regions, restart policy, rootfs rows.
