# Security and residency: what a box is, where it runs, what may go on it

Provider-neutral. boat's detail is in [boat-security](boat-security.md); other providers'
sources are in their cards.

## A box is readable by everything on it

- Assume root inside: boat gives passwordless sudo and extra read capabilities to exec
  children, Vercel full root, E2B root per command, Fly your image's user (usually
  root). Any process on the box can read every file and environment variable.
- Containers inside a box share its kernel. gVisor (Modal) and container-class sandboxes
  (Daytona) isolate less than a microVM per box (E2B, Vercel, Fly, boat's VMs).
- So: no production data on a box, no long-lived credentials left on it, and every
  secret that must be there is one you would rotate if the box leaked.

## Ephemeral is the argument for private code

The case for putting private or client code on a hosted box is that nothing of it
outlives the job:
- ship a credential-free git bundle or archive, not a clone with a token;
- keep production databases and their dumps off;
- turn off whatever the provider keeps by default (boat's `--no-env --no-snapshots
  --no-monitoring`; Vercel's persistence; E2B's pause);
- delete the box, confirm it is gone, and hunt the leftovers in
  [ttl-traps](ttl-traps.md#what-outlives-the-box).

If any of those cannot hold for a provider, it is not a place for client code until a
person with the authority to decide says it is. A team's own vendor-review state
belongs in its own docs, not in this skill.

## Residency

| Provider | Regions | Australia? | Notes |
|---|---|---|---|
| boat | Germany, Finland, France; not selectable | no | snapshot copies can be stored outside the EU |
| E2B | US default; EU and Singapore on request; BYOC | no | |
| Modal | `au`, `ap-melbourne`, `ap-southeast`, `eu-*`, ... | yes | a region costs 1.15x (broad) or 1.75x (narrow) |
| Vercel | 19 regions incl. `syd1` | yes | snapshots stay in their region |
| Daytona | `us`, `eu`; BYOC | no | |
| Fly | 17 incl. `syd` | yes | |

Check the data-residency clause of any contract before client code goes on a box, and
remember that snapshots and backups may live somewhere the box did not.

## Network

| Provider | Outbound default | Controls |
|---|---|---|
| boat | open | none in the docs; firewall inside the box |
| E2B | open | `allowInternetAccess`, `allowOut` / `denyOut` |
| Modal | open | `block_network`, CIDR and (beta) domain allowlists |
| Vercel | allow-all | deny-all or allowlist firewall with credential injection |
| Daytona | Tiers 1-2: fixed allowlist | Tiers 3-4: open, allowlists and a proxy |
| Fly | open | none documented |

A token URL that publishes a port (boat `host`, E2B, Daytona previews) is a password:
anyone with the full URL gets in. Daytona's standard preview token cannot be revoked.

## Picking a provider

- Cheapest per hour and already wired into fleetflow: boat (EU only).
- Australian residency: Vercel `syd1`, Modal `au`, or Fly `syd`.
- Credentials that never enter the box: Vercel's firewall injection.
- A ready agent template and pause/resume with memory: E2B.
- Not on a Tier 1-2 Daytona account if the job needs a registry off its allowlist.
