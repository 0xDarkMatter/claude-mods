# The Diagnostic Ladder

A layered methodology for isolating network faults from the wire up, applicable to Windows, macOS, and Linux. Each rung has a binary outcome that eliminates everything above it — walk in order, do not skip.

## Why Layered Probing Beats Pattern Matching

When a user says "internet is broken," there are roughly 30 plausible causes spanning seven OSI-ish layers. Guessing wastes time. The ladder is a binary-search through the stack: each test eliminates roughly half the remaining suspects.

The most common mistake is jumping straight to layer 6 ("HTTPS doesn't work, must be a cert / proxy / SNI thing") when the real issue is layer 5 (the OS resolver is being hijacked by an orphaned VPN config from a tunnel that hasn't been connected in four days). Discipline prevents this.

## Per-OS Tool Reference

| Rung | Windows | macOS | Linux |
|---|---|---|---|
| 1. Link | `Get-NetAdapter` / `Get-NetIPConfiguration` | `ifconfig` / `networksetup -listallhardwareports` | `ip -br link` / `ip -br addr` |
| 2. ICMP | `Test-Connection 1.1.1.1` | `ping -c 2 1.1.1.1` | `ping -c 2 1.1.1.1` |
| 3. TCP/UDP | `Test-NetConnection -Port 443` + raw UDP via .NET | `nc -zv` + `dig @<ip>` | `bash </dev/tcp/<ip>/443` + `dig @<ip>` |
| 4. DNS infra | `nslookup google.com 1.1.1.1` | `dig @1.1.1.1 google.com` | `dig @1.1.1.1 google.com` |
| 5. OS resolver | `Resolve-DnsName` | `dscacheutil -q host -a name google.com` | `getent hosts google.com` / `resolvectl query` |
| 6. App layer | `Invoke-WebRequest` | `curl -v` | `curl -v` |

## Rung 1 — Link Layer

**Question:** Is there a physical / wireless connection with a valid IP and gateway?

**Pass criteria:** At least one adapter `Up` / `active` / `UP`, has an IPv4 address, has a default gateway.

**Fail → check:** Driver state, cable, wifi association, DHCP lease, static config typo.

**Common gotchas across all OSes:**
- A `169.254.x.x` address (Windows/Linux) or `self-assigned` (macOS) means DHCP failed silently
- Multiple `Up` adapters can have competing default routes; check route metric / priority

## Rung 2 — IP / ICMP Reachability

**Question:** Can packets leave the box and reach the public internet?

**Pass criteria:** Replies in single-digit to low-double-digit milliseconds for at least one public anycast IP.

**Fail → check:** Routing table, firewall rules blocking ICMP outbound, ISP outage, captive portal.

**Watch for:** Some ISPs and corporate firewalls block ICMP entirely while allowing TCP/UDP. If ICMP fails but TCP socket tests pass on rung 3, ICMP is the *only* thing blocked — rare but real, especially on enterprise networks.

## Rung 3 — TCP/UDP Socket Reachability

**Question:** Can specific transport-layer connections complete?

**Critical discriminator:** Test multiple destinations on the same port. If `1.1.1.1:443` fails but `140.82.114.4:443` (github.com) succeeds, the block is **destination-specific**, not a general firewall. Strongly suggests AV with "Encrypted DNS Detection" or per-IP blocklist.

**Raw UDP/53 test is essential.** Most OS-level DNS probes (`Resolve-DnsName`, `dscacheutil`, `getent`) go through the system resolver and inherit every hook in the path. To test UDP/53 itself, use:
- Windows: `dig` (if installed) or a custom `UdpClient` (see `probe.ps1`)
- macOS / Linux: `dig +tries=1 @<server> <host>`

`dig` explicitly bypasses the OS resolver chain. This is what makes it the killer discriminator on Unix systems — same role as `nslookup` on Windows.

## Rung 3.5 — LAN Services (parallel track)

**Question:** Can this box reach services on its OWN network, by name? Mapped drives, SMB shares, printers, NAS admin pages, `.local` names, single-label hostnames.

Rungs 1–6 are framed around the public internet, and a box can pass all of them while every LAN name is dead. The reverse also holds: a `Disconnected` mapped drive proves nothing about internet health. Treat LAN services as a parallel track entered whenever the complaint names a share, a NAS, a printer, or a `\\hostname` path.

**Windows one-shot:** `scripts/windows/smb-audit.ps1` runs this whole rung per mapped drive.

### The single-label hostname resolution path (Windows)

A name like `NAS` (no dots) is resolved through a chain most people never see:

```
1. HOSTS file          %windir%\System32\drivers\etc\hosts — always consulted FIRST
2. NRPT match          policy table; a Namespace='.' rule captures EVERYTHING —
                       including single-label names — and pins the nameserver
3. DNS + suffix search single-label names get the connection-specific suffix appended
4. LLMNR               multicast to the local subnet (UDP/5355)
5. NetBIOS-NS          broadcast (UDP/137) — the legacy path that makes bare
                       \\NAS work on flat home LANs
```

**The load-bearing insight: an NRPT `.` catch-all short-circuits everything below it.** Once a name matches an NRPT rule, the query goes to that rule's nameserver and *the LLMNR/NetBIOS broadcast fallback is suppressed* — Windows considers the name "handled." So a live VPN with a catch-all (ProtonVPN, Mullvad, corporate DirectAccess) sends `NAS` to the tunnel resolver, gets NXDOMAIN, and never falls back to the broadcast mechanisms that made the name work before the VPN. The share dies by name while the host answers by IP.

Check the *effective* policy, not just configured rules:

```powershell
Get-DnsClientNrptPolicy -Effective | Where-Object Namespace -eq '.'
```

**Tool honesty note:** on a single-label name that fails, `Resolve-DnsName NAS` throws the misleading `"The filename, directory name, or volume label syntax is incorrect"` — it looks like you typed the command wrong. `nslookup NAS` gives the honest `Non-existent domain`. **Prefer `nslookup` for single-label diagnosis by hand.** (Scripted, `Resolve-DnsName -DnsOnly` / `-LlmnrNetbiosOnly` are still useful because the switches isolate individual mechanisms — just don't trust the error text.)

### VPN DNS-leak-protection: no fallback resolver either

Privacy VPNs (ProtonVPN confirmed; Mullvad similar) don't just install the NRPT rule — their leak protection **blocks UDP/53 egress to anything but the tunnel resolver**, including the LAN router. Signature: raw UDP/53 DNS query to the default gateway times out while ICMP and TCP to the same gateway succeed. This means pointing an interface at the router's DNS won't help while the VPN is up.

### The credential-target-keying trap

Windows Credential Manager keys stored credentials on the **target string**. A credential stored for target `NAS` does not apply to `\\192.168.50.11\vault` — so the obvious workaround "just remap by IP" fails with `System error 5 / Access is denied`, which reads as a permissions problem but isn't. Check with `cmdkey /list`; fix with `cmdkey /add:192.168.50.11 /user:<user> /pass:<pw>` (or pin the hostname in HOSTS and keep using the name, which also keeps the existing credential valid).

### Fix decision rule (VPN + LAN coexistence)

| VPN state | Correct fix |
|---|---|
| **Live and wanted** | Coexistence, not cleanup: pin the name in HOSTS (`<ip>  <name>`, admin required — HOSTS is consulted before NRPT so it wins in every VPN state), OR remap by IP + `cmdkey /add:<ip>` |
| **Disconnected / orphaned rule** | `scripts/windows/nrpt-clean.ps1 -Apply` |

Never point `nrpt-clean.ps1` at a live VPN's catch-all: the rule is doing its intended job, the VPN client will re-create it, and deleting it mid-session can leak DNS.

### macOS / Linux equivalents

| Concern | macOS | Linux |
|---|---|---|
| Single-label / LAN names | mDNS (`.local`) via mDNSResponder; `dns-sd -q <name>` | LLMNR via systemd-resolved (`resolvectl query <name>`), avahi for `.local` |
| VPN capture check | `scutil --dns` — resolver #1 pointing at the tunnel for `domain :` (default) | `resolvectl status` — `~.` routing domain on the VPN link captures everything |
| SMB reachability | `nc -zv <ip> 445`, `smbutil view //<ip>` | `nc -zv <ip> 445`, `smbclient -L <ip>` |
| Pin that beats VPN | `/etc/hosts` | `/etc/hosts` |

## Rung 4 — DNS Infrastructure

**Question:** Does a DNS server actually answer queries?

**Pass criteria:** All three resolvers (default + two public) return a name and address. The IPs may differ (different anycast points) — that's fine.

**Fail → check:** UDP/53 outbound blocked (back to rung 3 raw test), router's DNS forwarder broken, ISP DNS hijack misconfigured.

**Subtle bugs:**
- If the resolver returns only IPv6 (AAAA) records for a site that should have IPv4, the resolver may be misconfigured for record-type ordering — apps preferring A records will hang
- If different resolvers return wildly different IPs (different from anycast variation), you may be facing DNS poisoning or split-horizon weirdness

## Rung 5 — OS Resolver Path (THE INTERESTING LAYER)

**Question:** Does the operating system's name-resolution chain actually return correct addresses?

**THE SMOKING GUN:** Rung 4 passes (bypass tool works) but rung 5 fails (OS resolver times out). The DNS infrastructure is healthy but **something is hooking the system resolver path.**

### Windows suspects

| Hook | Detection |
|---|---|
| **NRPT (Name Resolution Policy Table)** | `Get-DnsClientNrptRule \| Where Namespace -eq '.'` |
| **HOSTS file** | `Get-Content $env:windir\System32\drivers\etc\hosts` |
| **WFP callout driver** | `Get-CimInstance Win32_SystemDriver \| Where Name -match 'wfp\|epfw'` |
| **DNS Client service hooked** | Third-party LSP catalog entries, dependent services |
| **Local 127.0.0.1:53 proxy** | `Get-NetUDPEndpoint -LocalPort 53` |

### macOS suspects

| Hook | Detection |
|---|---|
| **`/etc/resolver/<domain>` files** | `ls /etc/resolver/` — per-domain overrides, classic VPN residue |
| **scutil DNS state** | `scutil --dns` — shows "resolver #N" entries; extras = potential hook |
| **Configuration profiles (MDM)** | `profiles list -type configuration` — can install DNS overrides |
| **mDNSResponder state** | `pgrep -x mDNSResponder` — if dead, all DNS dies |
| **Third-party kext** | `kextstat \| grep -iE 'cisco\|anyconnect\|proton\|mullvad'` |
| **PAC file / proxy** | `scutil --proxy` |

### Linux suspects

| Hook | Detection |
|---|---|
| **`/etc/nsswitch.conf` hosts line** | NSS order excludes `resolve` or `dns` → bypass entirely |
| **systemd-resolved state** | `resolvectl status` — per-link DNS / search domains |
| **`/etc/resolv.conf` symlink** | `readlink /etc/resolv.conf` — should point at the stub on systemd systems |
| **NetworkManager DNS mode** | `/etc/NetworkManager/NetworkManager.conf` `[main] dns=` |
| **dnsmasq instance** | `pgrep -x dnsmasq` + `/etc/dnsmasq.d/` |
| **Local 127.x:53 listener** | `ss -tulnp \| grep :53` |

## Rung 6 — Application Layer

**Question:** Can a real application make a real HTTP request to a real hostname?

**Fail BUT rung 5 passed → check:**

| OS | Most common causes |
|---|---|
| Windows | WinHTTP proxy (`netsh winhttp show proxy`), cert store, TLS, IPv6 preference, app-specific config |
| macOS | System proxy (`scutil --proxy`), keychain cert issues, IPv6 preference, app-specific config |
| Linux | `http_proxy` / `https_proxy` env vars, CA bundle path, IPv6 preference, app-specific config |

## Discriminator Cheat Sheet

| Symptoms | Diagnosis |
|---|---|
| Rung 1 fails | Hardware / driver / wifi association |
| Rungs 1 pass, 2 fails | Routing or ISP |
| Rungs 1-2 pass, 3 fails for all dests | Outbound firewall blocking the port |
| Rungs 1-2 pass, 3 fails for specific dests | Destination-specific filter (AV "Encrypted DNS Detection") |
| Rungs 1-3 pass, 4 fails | DNS server / forwarder broken upstream |
| Rungs 1-4 pass, 5 fails | **OS resolver hook — go to per-OS dns-audit script** |
| Rungs 1-5 pass, 6 fails | Proxy, cert store, TLS, IPv6 preference, app-specific |
| All internet rungs pass, LAN name fails (host answers by IP) | **Rung 3.5 track — NRPT catch-all / suppressed LLMNR / credential keying (`smb-audit.ps1`)** |

## When the Ladder Doesn't Help

Some failures are stateful or intermittent and won't show on a single probe pass:

- **Time-based:** DNS works for 30s then breaks. Loop the probe; watch for transition timestamps.
- **Per-network:** Fails on wifi, works on ethernet. Compare per-interface resolver config on each OS.
- **Per-application:** Browsers fail, system tools work. Look at app-specific resolvers — Chrome / Firefox have their own DoH paths, curl has its own resolver, etc.

For these, augment the ladder with continuous probing and per-interface comparison.
