# Security model: what a box is, reaches and keeps

## Contents

- Isolation and privilege
- What a box can reach
- Credentials on a box
- What boat keeps
- Which code and data may go on a box
- Policy and accounts
- Supply chain

Source tags as in SKILL.md; [docs] pages are `security`, `data-retention` and
`cli-reference`, read 2026-10-27.

## Isolation and privilege

- Each box is its own virtual machine, with its own kernel, disk and IP; boxes share no
  disk or processes and reach each other only over the network [docs].
- Inside a box, the `user` account has passwordless sudo: anyone with a shell is root
  there [docs]. Treat every file and env var on a box as readable by every process on it.
- Every process `boat exec` starts also inherits `CAP_DAC_READ_SEARCH` from boat's agent
  service (`AmbientCapabilities` in its drop-in), so file permissions do not stop reads
  [field, measured]. Drop it per process with `setpriv` when a job must not read
  everything; see [ci-runner](ci-runner.md#the-boxs-setup-script).
- Containers inside a box share its kernel and are not isolated from each other [docs].

## What a box can reach

| Direction | Default [docs] | Notes |
|---|---|---|
| Outbound | outbound open to the internet | model APIs, GitHub and npm answered in tens of ms from the box [bench]. Block it with firewall rules inside the box, run as a separate user without sudo, or the user can remove them; snapshots do not keep them |
| Inbound | inbound refused except SSH and the ports boat uses | `boat host <port>` publishes a token-gated URL (`--public` for none); anyone with the full URL gets in, so treat it as a password |

Every box has a public IPv6 address and outbound IPv4 [docs: pricing]. boat has no API
setting for network rules [docs].

## Credentials on a box

- `--no-env` (API `noEnv: true`) keeps the account's stored variables, secret files, git
  and GitHub logins, AI keys and the in-sandbox API key out of the box [docs]. A box
  still gets `ASCII_TOKEN`, which can only publish ports of its own box.
- Never leave a credential file on a box: reads are not confined between lanes, and the
  capability above defeats `chmod 600` against other processes. Pass a credential on
  stdin into one process's env (fleetflow's rule), or keep it on the CI side entirely.
- API keys: scope a CI key to what CI needs; a key without `account.admin` cannot create
  further keys [field]. Keys live 90 days by default [docs: limits].
- Org boxes are visible to every member of the org that pays for them, and usable by them
  when shared; `--visibility private` at create keeps one to you [docs, cli].

## What boat keeps

| Action | Data afterwards [docs: data-retention] |
|---|---|
| Delete | erased in the background; gone from lists at once; cannot be undone |
| Stop, snapshots on | disk kept 14 days, then deleted |
| Stop, `--no-snapshots` | nothing: a stop erases the sandbox |
| Exec with monitoring on | command history for 90 days; other process output 72 hours |
| `--no-monitoring` | no command or process output, process list or CPU/RAM samples |
| After any delete | billing, usage, machine and IP records, and security audit events |

Zero data retention (`boat data-retention enable`) deletes every box's data at its stop,
account-wide; with it on, the account cannot save snapshots [docs, field]. Data sits on
machines in Germany, Finland and France; snapshot copies can be stored outside the EU.
SOC 2 was in progress as of 2026-10-27 [docs].

## Which code and data may go on a box

The decisions this skill was written from [field, 2026-10-25 to 10-27], as a template:
- **Private and client repos may run on boat, because boxes are ephemeral.** The decision
  rests on the box being destroyed: delete it when the task ends and confirm the 404.
- Ship a credential-free git bundle or archive, never a working tree with `.env` files.
- **No production databases, and no dumps made from them, sanitised ones included.**
  Seeded or mock data is fine. Work that needs production data stays local.
- Deploys and anything a contract keeps in-country stay off boat. Boxes are EU-only; a
  residency clause can rule a repo out. One client's code was judged acceptable for
  build-only tests (third-party code, no data, no secrets) case by case.
- In CI, use boat for internal repos with no deploy secrets, never for deploy jobs.
- A repo that holds media or data under separate rights (audio, recordings) can go to a
  box with those files gitignored: they never leave the machine.

## Policy and accounts

- **Vendor review is still open.** Under the source org's InfoSec policy a new service
  needs a vendor review before client data reaches it (its section 08.2), and a written,
  time-boxed exception (08.3) covers the trial meanwhile. As of 2026-10-27 the exception
  was recorded and the review was due within about 30 days. Check your own policy's
  equivalent before you treat boat use as settled.
- **Know whose account you are on.** One machine's CLI was signed in to another company's
  boat account; work for a second company ran there unnoticed, because nothing in the CLI
  or on a box says whose account it is [field]. Run `boat status`, `boat org` and
  `boat api-key list` first; keep one account per company.

## Supply chain

- `--no-update` on every call, and never `boat self-update`: the CLI otherwise updates itself
  after a command ends, at most every 6 hours [docs: cli-reference], which defeats a 7-day cooldown.
- In CI, call the REST API with curl rather than downloading the CLI, which has no
  pinned version or checksum [field].
- Anything you download onto a box (a runner, a Node build) is pinned and checked
  against a published SHA-256.
