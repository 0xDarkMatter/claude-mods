# Vercel Sandbox: Firecracker microVMs, `syd1`, credential injection

Facts verified 2026-11-05. `scripts/check-sandbox-facts.py --provider vercel` re-checks
the catalogued ones in `assets/facts-providers.json`.

Tags: **[docs]** a Vercel docs page read 2026-11-05; **[report]** the 2026-11-05 provider
research; **[inferred]** our own reading. Nothing here was measured on a real account.

## What it is

- Each sandbox runs in its own Firecracker microVM with a dedicated kernel, booting
  Ubuntu 26.04, a custom image or a saved snapshot, with full root access (`sandbox exec
  --sudo`) [docs: https://vercel.com/docs/sandbox/concepts].
- Drive it with the standalone `sandbox` CLI, `vercel sandbox`, the JS or Python SDK, or
  REST `/v2/sandboxes` [report].
- About $0.68 an hour for 4 vCPU / 8 GB at 100% CPU and about $0.22 at 10% in `iad1`;
  `syd1` about $0.96 / $0.31 [report: https://vercel.com/docs/sandbox/pricing]. Active
  CPU is billed, so an idle agent costs less.

## The lifetime trap

- **The default timeout is 5 minutes**; set `timeout` at create and extend with
  `sandbox.extendTimeout()` [docs: https://vercel.com/docs/sandbox/pricing].
- Max session duration: Hobby 45 minutes, Pro and Enterprise 24 hours [docs].
- **Sandboxes are persistent by default:** a stop snapshots the filesystem so the next
  call resumes it [docs: concepts]. Snapshots expire 30 days after their last use by
  default, and snapshot storage is billed per GB-month [docs: pricing].
- `sandbox list` hides stopped sandboxes; `sandbox remove` and `--rm` leave snapshots
  until they expire [report]. Hunt snapshots with `sandbox snapshots list`.
- Deleting a sandbox, snapshot or drive is limited to 20 requests per second per team
  [docs: pricing]. Pace bulk cleanups.

## Keys and scope

- SDK: `VERCEL_TOKEN` with `VERCEL_TEAM_ID` and `VERCEL_PROJECT_ID`, or a
  `VERCEL_OIDC_TOKEN` from `vercel env pull`, which expires after 12 hours
  [docs: https://vercel.com/docs/sandbox/concepts/authentication].
- `vercel` reads `VERCEL_TOKEN`. **Whether the standalone `sandbox` CLI reads it is not
  documented** (its order is `--token`, stored login, prompt) [report]. Use the SDK or
  `vercel sandbox` for per-process keys, and never pass `--token` in argv.

## Residency and network

- 19 regions including `syd1` (Sydney), `sin1`, `fra1`, `lhr1`
  [docs: https://vercel.com/docs/sandbox/concepts/regions].
- A snapshot is stored in the region of the sandbox it came from and cannot be moved
  [docs: regions].
- Outbound allow-all by default; a live deny-all or allowlist firewall can **inject
  credentials** into matching requests, so a token never enters the box; matching is by
  SNI only [report: https://vercel.com/docs/sandbox/concepts/firewall]. The firewall's CA
  is not passed to containers [report].
- Up to 15 published ports [report].

## Delete and confirm

- `sandbox remove <id>`, then `sandbox list -a` must no longer show it [report].
- `confirm-gone.sh --provider vercel <id>` runs that list for you and treats any
  appearance of the id in its output as present. Its test fake copies the documented
  command, not a recorded run, so run it once by hand against your CLI version.

## Driver verbs on Vercel

| fleetflow verb | Vercel |
|---|---|
| up | `sandbox create --name <name>` or SDK `Sandbox.create({ timeout, region })` |
| exec | `sandbox exec <name> -- <cmd>` or SDK `runCommand` |
| put / get | `sandbox copy`, or SDK `writeFiles` / `readFile` |
| stream | `sandbox exec --interactive --tty`, or SDK command logs |
| extend | SDK `extendTimeout(ms)` |
| down + confirm | `sandbox remove <id>`, then `confirm-gone.sh --provider vercel <id>` |
| list | `sandbox list -a` |

For self-hosted CI runners Vercel points at a separate product, Daemons
[report: https://vercel.com/changelog/vercel-daemons-is-now-in-public-beta]; a one-shot
`sandbox run --rm` fits a single job.

## Sources

- https://vercel.com/docs/sandbox/concepts, https://vercel.com/docs/sandbox/pricing,
  https://vercel.com/docs/sandbox/concepts/authentication,
  https://vercel.com/docs/sandbox/concepts/regions (read 2026-11-05).
- Research report 2026-11-05: prices, CLI auth order, firewall, list and remove rows.
