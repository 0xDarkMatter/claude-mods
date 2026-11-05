<!-- Recorded excerpt of https://docs.boat.dev/security.md, fetched 2026-10-27. Test input for check-boat-facts.py --live --fixtures; lines are verbatim, the rest of the page is cut. -->
# Security and isolation

* The `user` account has passwordless `sudo`. Anyone with a shell in a sandbox is root in that sandbox.

| Direction | Default | How to change it |
| - | - | - |
| Inbound | Refused, except SSH and the ports that boat uses | `host <port>` for a public URL. `ufw allow` for a raw port. Read [Public URLs](https://docs.boat.dev/hosting#raw-tcp-or-udp-ports). |
| Outbound | Open to the internet | Firewall rules inside the sandbox. Read [Block outbound internet](https://docs.boat.dev/hosting/firewall.md#block-outbound-internet-for-untrusted-code). |

| Where data is stored | Machines in Germany, Finland and France. Snapshot copies can be stored outside the EU. | [Compliance and uptime](https://docs.boat.dev/compliance.md#data-location) |
