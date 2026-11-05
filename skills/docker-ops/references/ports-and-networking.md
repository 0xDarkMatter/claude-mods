# Ports and Networking

Why a port won't publish, why a container can't reach the host (or the host can reach
something it shouldn't), and the subnet clashes that come with VPNs. Facts verified
2026-10-07. `docker-doctor.py --ports 80,5432` checks your ports read-only.

## Contents

- [Publishing ports](#publishing-ports)
- [Port already in use](#port-already-in-use)
- [Windows: reserved port ranges](#windows-reserved-port-ranges)
- [Reaching the host from a container](#reaching-the-host-from-a-container)
- [Subnets and VPNs](#subnets-and-vpns)
- [Linux firewalls](#linux-firewalls)
- [Rootless engines](#rootless-engines)

## Publishing ports

- `-p 8080:80` / `"8080:80"` binds **every interface** of the host. On Docker Desktop,
  OrbStack and Colima, the host side is forwarded from the VM, so the port is reachable from
  your LAN. Write `127.0.0.1:8080:80` for local-only. Datastores and debuggers always bind
  to loopback (hard rule 4).
- `docker port <container>` lists what a container publishes; `docker ps` shows the same
  in its PORTS column.
- A container port with no host port (`"80"`) gets a random host port on every interface.

## Port already in use

`Bind for 0.0.0.0:5432 failed: port is already allocated` means a container or a host
process holds the port.

```bash
python "<skill-dir>/scripts/docker-doctor.py" --ports 5432     # names the holder
docker ps --filter publish=5432                                 # a container?
lsof -nP -iTCP:5432 -sTCP:LISTEN                                # macOS/Linux host process
Get-NetTCPConnection -LocalPort 5432 -State Listen               # Windows (PowerShell)
```

Under WSL2 there are two sides. A process listening inside a running distro is invisible
to Windows-side checks, and the other way round. The doctor checks both sides, but only
probes a distro that is already running.

## Windows: reserved port ranges

`An attempt was made to access a socket in a way forbidden by its access permissions`
(WSAEACCES, 10013) has two causes: the port sits in a range Windows has reserved, or
another process bound it exclusively. Check the reservations:

```powershell
netsh interface ipv4 show excludedportrange protocol=tcp
```

Hyper-V, WSL and WinNAT reserve blocks, and the blocks can move after a reboot or an
update. The fix is to pick a port outside the ranges. Restarting WinNAT (`net stop winnat`,
`net start winnat`) or reserving your port first (`netsh int ipv4 add excludedportrange`)
are admin steps that change system state: propose them; never run them for the user.

## Reaching the host from a container

| Provider | Name for the host |
|---|---|
| Docker Desktop | `host.docker.internal` (and `gateway.docker.internal` for the VM gateway) |
| OrbStack | `host.docker.internal`, `host.orb.internal` |
| Colima, Lima | `host.lima.internal` (Lima's name; test `host.docker.internal` on your Colima version before relying on it) |
| Native Linux engine | nothing by default: add `--add-host=host.docker.internal:host-gateway` (`extra_hosts:` in Compose) |
| Podman | `host.containers.internal` |

A host service listening only on `127.0.0.1` is unreachable from containers on a native
Linux engine: bind it to the bridge address, or use `network_mode: host` (a host escape;
`docker-audit.py` reports it).

## Subnets and VPNs

- Docker Desktop's VM network defaults to `192.168.65.0/24`. A VPN or office network that
  routes the same range breaks container networking. Change it in Settings > Resources >
  Network ("Docker subnet").
- Bridge networks come from the engine's address pools (`172.17.0.0/16` for the default
  bridge, then more `172.x` and `192.168.x` ranges for Compose networks). On an engine you
  configure (Linux, Colima), set `default-address-pools` in `daemon.json` to a range your
  VPN doesn't use. Then recreate the networks (`docker compose down` and `up`).
- Symptom of a clash: containers lose DNS or can't reach a corporate host as soon as the VPN connects.

## Linux firewalls

On a native Linux engine, published ports are opened by Docker's own iptables/nftables
rules, ahead of UFW and firewalld rules. **A port UFW "blocks" is still reachable.** Bind
to `127.0.0.1`, or put your filtering rules in the `DOCKER-USER` chain, which Docker
evaluates first.

## Rootless engines

Rootless Podman (and rootless Docker) cannot bind ports below 1024 unless
`net.ipv4.ip_unprivileged_port_start` is lowered (a sysctl, an admin change). Publish
`8080` and front it with a proxy, or accept the sysctl.
