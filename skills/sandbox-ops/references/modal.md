# Modal Sandboxes: SDK-driven containers with an Australian region

Facts verified 2026-11-05. `scripts/check-sandbox-facts.py --provider modal` re-checks
the catalogued ones in `assets/facts-providers.json`.

Tags: **[docs]** a Modal docs page read 2026-11-05; **[report]** the 2026-11-05 provider
research; **[inferred]** our own reading. Nothing here was measured on a real account.

## What it is

- gVisor containers by default, or `runtime="vm"` for its own kernel, which is also how
  you get a Docker daemon [report: https://modal.com/docs/guide/sandboxes]. Root in
  practice [inferred].
- Driven from the Python, JS or Go SDK; no public REST API is stated [report]. `modal
  shell sb-<id>` opens a shell on a running sandbox [report]. **No SSH.**
- About $0.476 an hour for 4 vCPU / 8 GB; Starter $0 (+$30/month credit), Team $250
  [report: https://modal.com/pricing].

## The lifetime trap

- Sandboxes have a default maximum lifetime of **5 minutes**; pass a `timeout` of up to
  24 hours to `Sandbox.create(...)` [docs: https://modal.com/docs/guide/sandboxes].
- Past 24 hours you must snapshot the filesystem and restore into a new sandbox [docs].
- `idle_timeout` terminates after inactivity; a running exec counts as activity [docs].
- Filesystem snapshots are kept 30 days; memory snapshots are alpha, 7 days; there is no
  API that lists snapshots [report], so record every snapshot id you make.

## Keys and scope

- Configuration comes from the active profile in `.modal.toml`, and **each setting can be
  overridden by an environment variable named `MODAL_<SETTING>`**
  [docs: https://modal.com/docs/reference/modal.config]. API tokens are
  `MODAL_TOKEN_ID` and `MODAL_TOKEN_SECRET`.
- `MODAL_CONFIG_PATH` moves the `.toml` file and `MODAL_PROFILE` picks a section [docs].
  So one key per process works without touching the machine login.

## Residency, price and network

- Regions include `au`, `ap-melbourne`, `ap-southeast` and the `eu-*` set
  [docs: https://modal.com/docs/guide/region-selection].
- **A region costs extra:** 1.15x for a broad region such as `us`, 1.75x for a narrow one
  [docs]. The research put `au` at 1.75x, about $0.833 an hour for 4 vCPU / 8 GB [report].
- Outbound open; `block_network`, CIDR allowlists and a beta domain allowlist (SNI)
  restrict it; inbound through tunnels, connect tokens and a CIDR allowlist [report].

## Delete and confirm

- `sb.terminate(wait=True)`, then `poll()` / `returncode` shows it finished, or
  `Sandbox.list` by tags no longer returns it [report].
- `confirm-gone.sh` does not support Modal: there is no CLI command that lists sandboxes
  by id [inferred]. Confirm in the SDK.

## Driver verbs on Modal

| fleetflow verb | Modal |
|---|---|
| up | `modal.Sandbox.create(app=..., timeout=..., region=...)` |
| exec | `sb.exec("bash", "-c", cmd)` |
| put / get | SDK filesystem calls, or `exec` with stdin / stdout |
| stream | iterate the exec process's stdout; a driver needs a small SDK shim [inferred] |
| extend | not after create: plan the `timeout`; snapshot and restore past 24 h |
| down + confirm | `sb.terminate()`, then `poll()` or `Sandbox.list` by tags |
| list | `modal.Sandbox.list(app_id=..., tags=...)` |

## Sources

- https://modal.com/docs/guide/sandboxes, https://modal.com/docs/reference/modal.config,
  https://modal.com/docs/guide/region-selection (read 2026-11-05).
- Research report 2026-11-05: pricing, runtime, network and terminate rows.
