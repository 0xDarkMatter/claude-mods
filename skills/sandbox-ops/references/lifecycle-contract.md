# The lifecycle contract: one set of verbs, each provider's commands

fleetflow's host-driver contract names the verbs a remote-lane host must provide: `up`,
`exec`, `put` / `get`, `stream` (stdin forwarded, live output), `down` with a confirm,
`list` and `extend`. They are a good checklist for any provider, whether or not
fleetflow drives it. Each card ends with its own map; this page puts them side by side
and states what each verb must guarantee.

## What each verb must guarantee

| Verb | Guarantee |
|---|---|
| up | the box exists, is ready, has a lifetime above the job, and its id is captured exactly once (one create, never retried blind) |
| exec | the real remote exit code comes back, not the CLI's own |
| put / get | the bytes arrive whole: check a sha256 on both ends, write to `<dest>.part` then `mv` |
| stream | stdin reaches the process and output arrives live; a dropped stream is reattached, not restarted |
| extend | sets a lifetime you read back; never shortens a box someone else is using |
| down + confirm | two reads in the create's account and org scope agree the box is gone |
| list | shows stopped and paused boxes too, not just running ones |

## Side by side

| Verb | boat | E2B | Modal | Vercel | Daytona | Fly |
|---|---|---|---|---|---|---|
| up | `boat new --json` (JSONL) | SDK `Sandbox.create` | SDK `Sandbox.create` | `sandbox create` | `daytona create` | `fly machine run --rm` |
| exec | `boat exec --json` | SDK `commands.run` | SDK `sb.exec` | `sandbox exec` | `daytona ssh` | `fly ssh console -C` |
| put / get | `boat ssh` stdin, `push`, `scp` | SDK `files.write` / `read` | SDK filesystem | `sandbox copy` | SDK upload / download | `fly ssh sftp` |
| stream | `boat ssh` (exec drops stdin) | SDK, reattach by pid | SDK shim | `exec --interactive` | `daytona ssh` | `fly ssh console` |
| extend | `boat extend --ttl` (sets) | `setTimeout` (sets) | none | `extendTimeout` | wall-clock TTL | not needed |
| down | `boat delete --yes` | `e2b sandbox kill` | `sb.terminate()` | `sandbox remove` | `daytona delete` | `fly machine destroy --force` |
| confirm | `info` not_found + `list --all` | `sandbox list --state running,paused` | `poll()` / `Sandbox.list` | `sandbox list -a` | `daytona list -f json` | `machine list` / `include_deleted` |

`confirm-gone.sh --provider boat|e2b|vercel|daytona|fly` runs the confirm column for the
providers whose CLI can list boxes; Modal is confirmed in the SDK.

## Before a second provider carries real work

Run one measured smoke test per provider and record it: the env key overrides the stored
login, delete-and-confirm works end to end, and the default timeout behaves as the card
says. The docs could not settle E2B's env precedence, Vercel's standalone CLI env
support, Modal's root and E2B's paused-storage billing.
