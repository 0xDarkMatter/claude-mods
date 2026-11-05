# Xdebug, Profiling, Mail and Sharing

Facts from DDEV's step-debugging, profiling, developer-tools, sharing and command docs at
DDEV v1.25.4, checked 2026-10-05. The security side of sharing and of local-versus-
production PHP settings is owned by security-ops (`ddev-config-drift.md`).

## Contents

- [Xdebug](#xdebug)
- [Profiling](#profiling)
- [Mail](#mail)
- [Sharing a project](#sharing-a-project)
- [URLs and hostnames](#urls-and-hostnames)

## Xdebug

```bash
ddev xdebug on        # also: off, toggle, status, info
ddev xdebug off       # when done: it slows every request
```

- `ddev xdebug on` lasts until the next `ddev start` or `ddev restart`, which turns it
  off again.
- Xdebug is a network protocol: PHP in the web container calls out to your IDE, which
  listens on **port 9003**. Most IDEs default to it.
- **PhpStorm:** start listening, load a page with Xdebug on, accept the incoming
  connection. Map the project root to `/var/www/html`; the auto-created "server" is named
  after the project's primary URL (`ddev describe`).
- **VS Code (and forks):** the PHP Debug extension with DDEV's "Listen for Xdebug"
  `launch.json` snippet: `hostname: "0.0.0.0"`, `port: 9003`, and `pathMappings`
  `{"/var/www/html": "${workspaceFolder}"}`. On WSL2, DDEV's docs require both the PHP Debug and
  the WSL extensions to be enabled *inside the distro*, not only on the Windows side.
- **CLI scripts:** `PHP_IDE_CONFIG` is preset in the container, so `ddev exec php <script>`
  or a framework console command breaks at your breakpoints once a web request has created
  the PhpStorm server.
- **Not connecting:** `ddev utility xdebug-diagnose` (`--interactive` for the full check),
  then `ddev logs` for "Could not connect to debugging client". With the IDE listening,
  `ddev exec nc -vz -w2 host.docker.internal 9003` shows whether the container can reach
  it at all. Usual causes: a firewall
  or corporate endpoint security blocking the container-to-host connection on 9003, a VPN,
  or a global `xdebug_ide_location` someone set (reset it to `""`; only an IDE running
  inside WSL2 or a container needs `wsl2`/`container`).
- **Never commit `xdebug_enabled: true`:** every teammate pays for it on every request.
- `ddev describe -j` no longer reports Xdebug (v1.25.4); scripts must use
  `ddev xdebug status`.

## Profiling

- XHGui is the default profiler mode since v1.25.0: `ddev xhgui on`, load the slow page,
  `ddev xhgui launch` to open the UI; `ddev xhgui off` when done.
- `ddev config global --xhprof-mode=prepend` restores the old prepend mode
  (`ddev xhprof on`).
- Blackfire: `ddev blackfire on|off|status`, once the Blackfire credentials are set up
  per DDEV's Blackfire profiling page.
- Profile with production-like data and Xdebug off - Xdebug distorts timings.

## Mail

- Mailpit is built in and catches mail that PHP sends through DDEV's default mail setup:
  `ddev mailpit` opens it (or `ddev launch -m`).
- It does **not** catch mail an application sends through its own SMTP server or a mail
  API. A database pulled from production may carry that transport configuration and send
  real email from a laptop - security-ops covers the risk; the fix is mail settings per
  environment, read from env vars.

## Sharing a project

| Method | How | Reach |
|---|---|---|
| `ddev share` (ngrok, the default) | ngrok account + `ngrok config add-authtoken`; free accounts get one stable domain | Internet |
| `ddev share --provider=cloudflared` | `cloudflared` installed; no account; random `trycloudflare.com` URL, or a named tunnel on a Cloudflare-managed domain for a stable one | Internet |
| Local network | `bind_all_interfaces: true` + a fixed `host_webserver_port` in `config.local.yaml` | LAN |

- Set a default with `ddev config global --share-default-provider=cloudflared`; pass tunnel
  arguments with `share_provider_args` or `--provider-args`. Custom providers go in
  `.ddev/share-providers/`.
- **Base URL:** CMSs that store or configure one base URL (WordPress, Magento, Craft's
  `PRIMARY_SITE_URL`) send visitors back to the local URL. DDEV sets `DDEV_SHARE_URL`
  before running `pre-share` hooks, so a hook can switch the URL for the session and a
  `post-share` hook can switch it back (DDEV's docs show a WordPress `wp search-replace`
  example).
- **Build front-end assets first** (`ddev npm run build`). The tunnel forwards the site's
  own URL, so pages that load assets from a dev server on another port (Vite) break for
  the visitor.
- **While shared, everything local is public:** debug modes and stack traces, Xdebug,
  `display_errors`, and whatever data sits in the local database. Before sharing, follow
  security-ops' checklist (debug off, sanitised data); stop the tunnel when the demo ends.
- `bind_all_interfaces` belongs in `config.local.yaml`, never in the team config.

## URLs and hostnames

- `ddev describe` lists every URL and port; `ddev launch` opens the site
  (`ddev launch --print-url` prints it instead, v1.25.4 - useful over SSH and in scripts).
- Extra names: `additional_hostnames` (under DDEV's TLD) and `additional_fqdns` (any full
  name). Changing them needs `ddev restart`; offline or with DNS disabled DDEV edits the
  hosts file (`ddev hostname`), which needs admin rights on Windows.
- A router or DNS that blocks rebinding to 127.0.0.1 breaks DDEV's default name
  resolution; see the troubleshooting docs' "DNS Rebinding" section or use a different
  DNS server.
