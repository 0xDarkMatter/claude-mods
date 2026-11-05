# E2B: Firecracker sandboxes with an agent template

Facts verified 2026-11-05. `scripts/check-sandbox-facts.py --provider e2b` re-checks the
catalogued ones in `assets/facts-providers.json`.

Tags: **[docs]** an E2B docs page read 2026-11-05 (URL on the line or in Sources);
**[report]** the 2026-11-05 provider research, which read the page named; **[inferred]**
our own reading. Nothing here was measured on a real E2B account.

## What it is

- A Firecracker microVM per sandbox. The default user is `user`; root is per command,
  and templates can grant sudo [report: https://docs.e2b.dev/template/user-and-workdir.md].
- A ready `claude` template runs Claude Code in a sandbox
  [docs: https://docs.e2b.dev/agents/claude-code.md].
- Drive it from the JS/TS or Python SDK (the key can also be passed per call), the REST
  API or the `e2b` CLI.

## Plans and limits [docs: https://docs.e2b.dev/billing.md]

| | Hobby | Pro |
|---|---|---|
| Price | $0/month, $100 credit once | $150/month |
| Max continuous runtime | 1 hour | 24 hours |
| Concurrent sandboxes | 20 | 100 - 1,100 |
| vCPU / memory / disk | 8 / 8 GiB / 10 GiB | 8+ / 8+ GiB / 20+ GiB |
| Creation rate | 1 / sec | 5 / sec |

- About $0.331 an hour for 4 vCPU / 8 GB ($0.0504 per vCPU-hour plus $0.0162 per
  GiB-hour) [report: https://e2b.dev/pricing].
- "Max continuous runtime" is time without a pause; pausing and resuming resets it.
- For 1-4 h lanes, Pro is the real entry price [inferred].

## The lifetime trap

- Every sandbox has a timeout that defaults to **5 minutes**
  [docs: https://docs.e2b.dev/faq/sandbox-lifetime.md]. Set `timeoutMs` (JS) or
  `timeout` (Python, seconds) at create, or `setTimeout()` / `set_timeout()` later,
  which resets the clock from that moment.
- **The default is destructive:** `onTimeout: 'kill'` (the default) terminates the
  sandbox, which cannot be resumed [docs].
- `onTimeout: 'pause'` saves filesystem and memory instead, and paused sandboxes have
  **no time-to-live**: E2B never kills one on its own [docs]. A paused sandbox you forget
  is a leftover. Whether paused storage is billed is not stated: the billing FAQ says
  compute billing stops on pause [docs: billing].
- A stream (exec, watch, pty) normally stays open past an hour on keepalive pings, but no
  single connection is guaranteed; reconnect with `commands.connect(pid)` [docs].

## Keys and scope

- `E2B_API_KEY` in the environment authenticates the CLI with no `e2b auth login`, from
  CLI 2.12.1 [docs: https://docs.e2b.dev/cli/auth.md]. That it **beats** a stored
  `~/.e2b/config.json` login comes from the CLI source, not the docs [report]: check it
  once before relying on it.
- The SDKs take the key per call as well, which is the cleanest per-process scope.
- `E2B_DOMAIN` selects the region's endpoint [report].

## Residency and network

- US by default; EU and Singapore on request with a payment method; BYOC on Enterprise;
  **no Australian region** [report: https://docs.e2b.dev/faq/egress-ip-ranges.md].
- Outbound open by default; `allowInternetAccess`, and `allowOut` / `denyOut` with
  wildcards, restrict it [report].
- Inbound: `<port>-<id>.e2b.app` URLs, **private by default since 2026-10-30** for new
  projects [report].

## Delete and confirm

- `e2b sandbox kill <id>`, then `e2b sandbox list --state running,paused --format json`
  must no longer show it [report]. List paused sandboxes too: they never expire.
- `confirm-gone.sh --provider e2b <id>` does that read for you (list only; E2B has no
  per-id read the script relies on).

## Driver verbs on E2B

| fleetflow verb | E2B |
|---|---|
| up | SDK `Sandbox.create(template, { timeoutMs, ... })`; set the timeout above the job |
| exec | SDK `sandbox.commands.run(cmd)` |
| put / get | SDK `sandbox.files.write(path, data)` / `sandbox.files.read(path)` |
| stream | SDK `commands.run(cmd, { onStdout })`, reattach with `commands.connect(pid)` |
| extend | SDK `setTimeout(ms)` (SETS the remaining time from now) |
| down + confirm | `e2b sandbox kill <id>`, then `confirm-gone.sh --provider e2b <id>` |
| list | `e2b sandbox list --state running,paused --format json` |

There is no SSH in the base product; a websocat SSH template exists [report]. A
fleetflow driver would need a small SDK shim for `stream` [inferred].

## Sources

- https://docs.e2b.dev/faq/sandbox-lifetime.md, https://docs.e2b.dev/billing.md,
  https://docs.e2b.dev/cli/auth.md, https://docs.e2b.dev/agents/claude-code.md (read
  2026-11-05).
- Research report 2026-11-05: pricing, template user, egress and inbound rows.
