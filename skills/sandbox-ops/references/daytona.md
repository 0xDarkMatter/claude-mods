# Daytona: agent sandboxes with SSH, and their traps

Facts verified 2026-11-05. `scripts/check-sandbox-facts.py --provider daytona` re-checks
the catalogued ones in `assets/facts-providers.json`.

Tags: **[docs]** a Daytona docs page read 2026-11-05; **[report]** the 2026-11-05 provider
research; **[inferred]** our own reading. Nothing here was measured on a real account.

Daytona is in this skill mainly so its traps are written down: a small per-box ceiling,
an auto-stop that ignores background work, an env-auth trap, and tier-locked egress.

## What it is

- Container sandboxes by default (Daytona claims a dedicated kernel); Linux VM and
  Windows classes exist [docs: https://www.daytona.io/docs/en/sandboxes.md]. Native
  `daytona ssh`; Claude Code preinstalled [report]. Sudo is not stated.
- A sandbox gets 1 vCPU, 1 GB RAM and 3 GiB disk by default, and an organization's
  maximum per sandbox is **4 vCPUs, 8 GB RAM and 10 GB disk** [docs: sandboxes]. 10 GB is
  too small for a repo plus `node_modules` plus caches [report].
- About $0.331 an hour for 4 vCPU / 8 GB plus disk past 5 GiB; $0 with $200 credit;
  tiers unlock by top-ups [report: https://www.daytona.io/pricing].
- Tier 1 (email verified) pools 10 vCPU across the organization
  [docs: https://www.daytona.io/docs/en/limits.md].

## The lifetime trap

- **Daytona sandboxes auto-stop after 15 minutes of inactivity**, and a long-running
  process does not count as activity, so a headless agent can be stopped mid-run [docs:
  sandboxes]. Create with `--auto-stop 0` and bound it with a wall-clock TTL instead.
- The wall-clock TTL destroys a sandbox after a fixed deadline, whatever its state
  [docs: sandboxes].
- Ephemeral sandboxes (or `--auto-delete 0`) are deleted when they stop [docs]. Without
  that, **auto-delete is off**: a stopped container sandbox keeps its disk until it is
  archived, and bills for it [report: https://www.daytona.io/docs/en/billing].
- Snapshots bill after the sandbox is deleted [report]. Hunt them.

## Keys and scope

- **The trap:** the CLI uses `DAYTONA_API_KEY` over its saved profile only **when both
  `DAYTONA_API_KEY` and `DAYTONA_API_URL` are set** in the environment
  [docs: https://www.daytona.io/docs/en/authentication.md]. A key alone silently runs
  under the profile's account. Set both, or give each process its own
  `DAYTONA_CONFIG_DIR` [report].
- The SDKs resolve code, then the process environment, then `.env`; a
  `DAYTONA_API_URL` in a `.env` file is ignored [docs: authentication].
- The standard preview-URL token cannot be revoked [report].

## Residency and network

- Shared regions `us` and `eu`, plus bring-your-own-compute; **no APAC region**
  [docs: https://www.daytona.io/docs/en/regions.md].
- **Tiers 1-2 get a fixed outbound allowlist** (GitHub, npm, PyPI and Anthropic are on
  it); Tiers 3-4 are open, with allowlists and a proxy [report]. A registry not on the
  list fails on a low tier.

## Delete and confirm

- `daytona delete <id>`, then `daytona list -f json` must no longer show it [report].
- `confirm-gone.sh --provider daytona <id>` runs that list for you, with both auth
  variables set as above.

## Driver verbs on Daytona

| fleetflow verb | Daytona |
|---|---|
| up | `daytona create --auto-stop 0` with a wall-clock TTL, or ephemeral |
| exec | `daytona ssh <id> -- <cmd>` [inferred], or SDK `sandbox.process.exec` |
| put / get | SDK filesystem upload / download, or ssh stdin / stdout |
| stream | `daytona ssh` |
| extend | move the wall-clock TTL; signal activity to reset the idle timer [docs] |
| down + confirm | `daytona delete <id>`, then `confirm-gone.sh --provider daytona <id>` |
| list | `daytona list -f json` |

## Sources

- https://www.daytona.io/docs/en/sandboxes.md, https://www.daytona.io/docs/en/limits.md,
  https://www.daytona.io/docs/en/authentication.md,
  https://www.daytona.io/docs/en/regions.md (read 2026-11-05).
- Research report 2026-11-05: pricing, billing, egress tiers and CLI rows.
