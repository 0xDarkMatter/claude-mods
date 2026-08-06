# Common Culprits Catalog

Field guide to known causes of network weirdness on Windows, macOS, and Linux. Ordered within each OS by frequency in observed cases. Each entry: detection command, signature in probe output, and the safe fix.

---

# WINDOWS

## W1. Orphaned NRPT Catch-All (VPN residue)

**Frequency:** Very common — most likely cause of "DNS works in nslookup but not browsers."

**Mechanism:** VPN clients (Proton, Mullvad, Cisco AnyConnect, NordVPN, DirectAccess) set an NRPT rule with `Namespace = "."` pointing at their in-tunnel DNS gateway. Buggy disconnect cleanup → rule outlives the tunnel → every DNS query goes into a void.

**Detection:** `Get-DnsClientNrptRule | Where Namespace -eq '.'`

**Telltale IPs:**
- `10.2.0.x` → Proton VPN
- `10.64.0.x` → Mullvad
- `10.211.x.x` → Cisco AnyConnect (varies by enterprise)
- `10.5.0.x` → NordVPN

**Fix:** `scripts/windows/nrpt-clean.ps1 -Apply` (preserves Tailscale rules). **Only for orphans** — if the VPN is live and wanted, this is the wrong tool; see W1b.

## W1b. LIVE VPN Catch-All Swallowing LAN Names (ProtonVPN/WireGuard pattern)

**Frequency:** Common on any box that runs a privacy VPN *and* has LAN services (NAS, mapped drives, printers).

**Mechanism:** Same NRPT `Namespace='.'` rule as W1, but the VPN is **connected and doing its job** — internet DNS works fine through the tunnel. The casualty is the LAN: the catch-all captures **single-label** hostnames (`NAS`) too, sends them to the in-tunnel resolver (NXDOMAIN), and the NRPT match suppresses the LLMNR/NetBIOS broadcast fallback those names rely on. ProtonVPN's DNS-leak-protection additionally blocks UDP/53 egress to the LAN router — proven by a raw UdpClient query timing out while ICMP and TCP to the same router succeed — so there is no fallback resolver at all. Mapped drives show `Disconnected`; the host is perfectly reachable by IP (ICMP, TCP/445, TCP/5000 all fine).

**Detection:**
```powershell
Get-DnsClientNrptPolicy -Effective | Where-Object Namespace -eq '.'   # rule present
Get-NetAdapter | Where-Object Status -eq 'Up'                          # VPN interface Up = LIVE, not orphan
scripts/windows/smb-audit.ps1                                          # full audit + verdict
```
Use `nslookup NAS` (honest `Non-existent domain`) rather than `Resolve-DnsName NAS`, whose single-label failure text — `"The filename, directory name, or volume label syntax is incorrect"` — is misleading.

**Fix (coexistence — do NOT run nrpt-clean.ps1 on a live VPN's rule):**
1. Pin the name in HOSTS (admin): `Add-Content $env:windir\System32\drivers\etc\hosts "192.168.50.11  NAS"` — HOSTS is consulted before NRPT/DNS, so it wins regardless of VPN state.
2. Or remap by IP **plus** a credential keyed to the IP: `cmdkey /add:192.168.50.11 /user:<user> /pass` — without the cmdkey step you hit W1c.

## W1c. Credential Manager Target Keyed to Hostname, Not IP

**Frequency:** Bites exactly when working around W1b by remapping to the raw IP.

**Mechanism:** Credential Manager keys stored credentials on the **target string**. A credential stored for target `NAS` does not apply to `\\192.168.50.11\vault`, so the IP-based remap returns `System error 5 / Access is denied` — which looks like a share-permission problem but is a credential-lookup miss.

**Detection:** `cmdkey /list` — compare the `Target:` entries against the host form actually in the UNC path (hostname vs IP).

**Fix:** `cmdkey /add:<ip> /user:<user> /pass:<pw>`, or keep using the hostname and fix resolution instead (W1b's HOSTS pin keeps the existing credential valid).

## W2. AV WFP Hooks (ESET / Kaspersky / Bitdefender / Norton)

**Frequency:** Common on machines with full security suites.

**Mechanism:** AV products install Windows Filtering Platform callout drivers. Features like "Encrypted DNS Detection," "SSL/TLS Protocol Filtering," "Web Access Protection" can block public DoH resolver IPs on 443 and intercept DNS Client API calls.

**Detection:** `Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct` and `Get-CimInstance Win32_SystemDriver | Where Name -match 'epfwwfp|wfpcap|symefa|mfewfpk|bdfwfpf'`

**Signature in probe:** `TCP/443 -> 1.1.1.1` FAIL but `TCP/443 -> 140.82.114.4` (github.com) PASS.

**Fix:** Pause AV via tray → re-probe → if confirmed, disable "Encrypted DNS Detection" in AV settings or add the public resolver IPs to allowed addresses.

## W3. Internet Connection Sharing (ICS) Stuck

**Frequency:** Occasional, often a side effect of Mobile Hotspot or Hyper-V.

**Mechanism:** `SharedAccess` service binds DNS proxy on `0.0.0.0:53`. Usually a red herring — its presence doesn't cause failures alone, but it can mask the underlying culprit.

**Detection:** `Get-Service SharedAccess` + `Get-NetUDPEndpoint -LocalPort 53`

**Fix (if confirmed unwanted):** `Set-Service SharedAccess -StartupType Disabled; Stop-Service SharedAccess -Force`

## W4. Local 127.0.0.1:53 Proxy (NextDNS / AdGuard / Pi-hole client / Cloudflare WARP)

**Frequency:** Increasing as DoH-via-proxy adoption grows.

**Detection:** `Get-NetUDPEndpoint -LocalPort 53 | Where LocalAddress -eq '127.0.0.1'`

**Fix:** Restart the proxy service, or temporarily reconfigure DNS to a public resolver and verify:
```powershell
Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses 1.1.1.1,8.8.8.8
```

## W5. Consumer Router DoH IP Blocking (also affects macOS, Linux)

**Frequency:** Growing rapidly. Most prosumer routers from 2023+ ship with this enabled by default.

**Mechanism:** Consumer routers with "parental controls" / "safe browsing" / "advanced threat protection" features maintain blocklists of known public DoH (DNS-over-HTTPS) resolver IPs and silently drop TCP/443 to them. Goal: prevent DoH from bypassing the router's DNS filtering. Affects:

- **Asus AiProtection / Trend Micro filtering**
- **TP-Link HomeShield / HomeCare**
- **Eero Secure / Secure+**
- **Netgear Armor**
- **Synology Safe Access**
- **OPNsense/pfSense with custom blocklists**
- **Pi-hole upstream config blocking DoH**

**Detection (cross-platform — this is a network-level block, not OS-specific):**
- `TCP/443 -> 1.1.1.1` FAIL **and** `TCP/443 -> 8.8.8.8` FAIL **and** `TCP/443 -> 9.9.9.9` FAIL
- `TCP/443 -> <github.com IP>` PASS (control: any non-DoH 443 destination)
- Failure pattern is **identical across multiple devices on the same LAN**

Confirmed via this skill's dogfooding: a single Asus AiProtection-enabled LAN blocked 1.1.1.1:443 and 8.8.8.8:443 from both a Windows desktop and a macOS laptop, while github.com:443 worked from both. The discriminator (different destinations, same port) immediately localized the block to the router/LAN rather than per-device AV.

**Fix:**
1. Router admin UI → disable parental controls / safe browsing / threat protection for the affected client, OR for the entire LAN
2. If you need DoH but can't change router config: use Cloudflare's `1.1.1.1` on port 853 (DoT, often unblocked) or via WARP client which uses non-standard ports
3. Many routers allow per-device exemption — exclude the diagnostic machine if you don't want to disable network-wide

**Important:** This is not a malicious block. It's a working-as-intended security feature, often beneficial. Only override if you have a specific reason to bypass it (e.g., legitimate use of DoH for privacy).

## W6. HOSTS File Pollution / Winsock LSP Corruption

**Frequency:** Rare but quick to check / nuclear to fix.

**Detection:** `Get-Content $env:windir\System32\drivers\etc\hosts` + `netsh winsock show catalog`

**Nuclear fix (requires reboot):** `netsh winsock reset; netsh int ip reset`

---

# macOS

## M1. Orphan `/etc/resolver/<domain>` Files (VPN residue)

**Frequency:** Very common — macOS equivalent of the Windows NRPT bug.

**Mechanism:** Some VPN clients (especially Cisco AnyConnect / Secure Client, Proton VPN, occasional Mullvad) write per-domain resolver files to `/etc/resolver/`. Each file points a specific DNS suffix at the VPN gateway. On disconnect, cleanup is supposed to remove them. It often doesn't.

**Detection:**
```bash
ls /etc/resolver/
scutil --dns | head -40
```

**Telltale IPs in `/etc/resolver/<file>`:**
- `10.2.0.x` → Proton VPN
- `10.64.0.x` → Mullvad
- `10.211.x.x` → Cisco AnyConnect
- `127.0.0.1` → local DNS proxy (NextDNS, AdGuard)

**Signature:** `dig @1.1.1.1 google.com` works but `dscacheutil -q host -a name google.com` fails OR returns wrong addresses. `scutil --dns` shows extra "resolver #N" entries with `domain :` lines naming corporate or VPN-specific zones.

**Fix:** `scripts/macos/resolver-clean.sh --apply` (protects Tailscale's MagicDNS).

## M2. Configuration Profile DNS Override (MDM-installed)

**Frequency:** Common on managed Macs.

**Mechanism:** MDM (Jamf, Intune, Kandji, Mosyle) can push DNS configuration via a `.mobileconfig` profile that overrides the resolver chain. If the profile points at an internal corporate DNS that's unreachable from your current network, all resolution dies.

**Detection:**
```bash
profiles list -type configuration
sudo profiles show -type configuration   # full payloads
```

**Fix:** Coordinate with IT — removing an MDM-managed profile may violate policy and may be re-applied automatically. The fix usually involves connecting to corporate VPN to make the internal DNS reachable, or asking IT to amend the profile.

## M3. mDNSResponder Crashed / Hung

**Frequency:** Rare but catastrophic when it happens.

**Detection:** `pgrep -x mDNSResponder`

**Fix:**
```bash
sudo killall -HUP mDNSResponder     # gentle nudge
sudo killall mDNSResponder          # force restart (launchd auto-respawns)
sudo dscacheutil -flushcache
```

## M4. Stale `scutil --dns` State After Network Change

**Frequency:** Occasional, especially after sleep/wake or switching wifi networks.

**Mechanism:** macOS's resolver cache can hang on to settings from a previous network. New connection has fresh DNS servers but the resolver chain still has entries from the previous network.

**Detection:** `scutil --dns` shows multiple resolvers with different IPs that don't match the current network's actual DNS.

**Fix:**
```bash
sudo killall -HUP mDNSResponder
sudo dscacheutil -flushcache
```

If persistent: cycle the active network interface in System Settings → Network → Details → Renew DHCP Lease.

## M5. Third-Party Network Kext / System Extension

**Frequency:** Decreasing (Apple has deprecated kexts in favor of system extensions).

**Mechanism:** Cisco AnyConnect, Little Snitch, Lulu, some legacy AV products. Can hook the network stack at kernel level.

**Detection:** `kextstat | grep -iE 'cisco|anyconnect|proton|mullvad|nord|littlesnitch|lulu'`

**Fix:** Disable via the app's GUI, not by force-unloading the kext.

## M6. PAC File / Proxy Set System-Wide

**Frequency:** Common in corporate environments.

**Detection:** `scutil --proxy`

**Fix:** System Settings → Network → Details → Proxies → toggle off the relevant proxy (or check that the PAC URL is reachable).

---

# LINUX

## L1. `/etc/resolv.conf` No Longer Symlinked to systemd-resolved Stub

**Frequency:** Common — happens when VPN clients or DHCP scripts overwrite the symlink.

**Mechanism:** systemd-resolved expects `/etc/resolv.conf` to be a symlink to `/run/systemd/resolve/stub-resolv.conf`. If a VPN script (or an Old-School Sysadmin) replaces it with a plain file containing static nameservers, the file becomes a stale snapshot — apps using libc's resolver hit the static file while `resolvectl` operates independently.

**Detection:**
```bash
readlink /etc/resolv.conf
# Expected on systemd-resolved hosts:
# /run/systemd/resolve/stub-resolv.conf
# Or:
# ../run/systemd/resolve/stub-resolv.conf
```

**Fix:**
```bash
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

## L2. systemd-resolved Per-Link DNS Stuck After VPN Disconnect

**Frequency:** Very common — Linux equivalent of the Windows NRPT bug.

**Mechanism:** VPN clients (OpenVPN, WireGuard, Mullvad, Proton CLI) push per-link DNS via `resolvectl dns <iface> <servers>` when connecting. Cleanup on disconnect should revert the link's DNS, but many scripts forget. Result: queries route to a dead per-link DNS server.

**Detection:** `resolvectl status` shows DNS servers configured on a VPN interface that's no longer routing, OR a global fallback that no longer applies.

**Fix:** `scripts/linux/resolved-reset.sh --apply`

## L3. `/etc/nsswitch.conf` hosts Line Excludes Resolver

**Frequency:** Rare but devastating.

**Mechanism:** If `/etc/nsswitch.conf` has `hosts: files dns` on a systemd-resolved system, glibc bypasses `resolve` (the systemd-resolved NSS module) and goes straight to whatever `/etc/resolv.conf` says. If that's broken, all libc-based name resolution fails — even though `resolvectl query` may still work.

**Detection:**
```bash
grep "^hosts:" /etc/nsswitch.conf
# Healthy on systemd-resolved system:
# hosts: files mymachines resolve [!UNAVAIL=return] dns myhostname
```

**Fix:** Restore the canonical line per your distro's defaults. On Ubuntu/Debian:
```bash
sudo sed -i 's/^hosts:.*/hosts: files mymachines resolve [!UNAVAIL=return] dns myhostname/' /etc/nsswitch.conf
```

## L4. NetworkManager `dns=` Mode Conflicts With systemd-resolved

**Frequency:** Occasional on desktop Linux.

**Mechanism:** NetworkManager has its own opinions about DNS. Settings include `none` (NM doesn't touch DNS), `dnsmasq` (NM starts a local dnsmasq), `systemd-resolved` (NM hands off to systemd-resolved). Mismatch between NM's mode and what's actually running creates a fight.

**Detection:**
```bash
awk '/\[main\]/,/\[/{if(/^dns/)print}' /etc/NetworkManager/NetworkManager.conf
ls /etc/NetworkManager/conf.d/
```

**Fix:** Pick one strategy and stick with it. The modern recommended setup is `dns=systemd-resolved` on systemd distros.

## L5. dnsmasq Local Instance Bound to 127.0.0.1:53

**Frequency:** Occasional, especially with old NetworkManager configs or libvirt installs.

**Mechanism:** A local dnsmasq listens on 127.0.0.1:53 and `/etc/resolv.conf` points at 127.0.0.1. If dnsmasq's upstream config is broken or stale, all DNS fails despite the infrastructure being fine.

**Detection:** `ss -tulnp | grep ':53'`

**Fix:** Check dnsmasq's actual upstream config (`/etc/dnsmasq.d/*`, `/etc/NetworkManager/dnsmasq.d/*`) and restart: `sudo systemctl restart dnsmasq` or `sudo systemctl restart NetworkManager`.

## L6. WireGuard / OpenVPN PostUp DNS Hook Failure

**Frequency:** Common with hand-rolled VPN configs.

**Mechanism:** WireGuard configs often have `PostUp = resolvectl dns %i 10.0.0.1` and `PostDown = resolvectl revert %i`. If `wg-quick down` is killed before `PostDown` runs (sleep, SIGKILL, crash), the DNS state is never reverted.

**Detection:** `resolvectl status` shows DNS on a `wg*` interface that no longer exists, or `ip link` shows no `wg*` interface but `resolvectl` still has DNS configured for one.

**Fix:** `scripts/linux/resolved-reset.sh --apply` cleans most of this. For lingering interface entries: `sudo resolvectl revert <ifname>`.

## L7. Container / WSL2 Special Cases

**Frequency:** Occasional.

**Mechanism:**
- **Docker containers** inherit DNS from the host. If host DNS is broken, containers inherit the breakage. Containers using `--network=host` follow host config exactly.
- **WSL2** has its own resolver chain. `/etc/resolv.conf` inside WSL2 is auto-generated by `wsl.conf`. Windows-side DNS hooks (NRPT, AV) don't affect WSL2 unless `wsl.conf` is configured to share them.

**Detection:**
- Docker: `docker exec <container> cat /etc/resolv.conf`
- WSL2: `cat /etc/resolv.conf` inside WSL + `cat /etc/wsl.conf`

**Fix:**
- Docker: fix host DNS first, then `docker restart`
- WSL2: configure `/etc/wsl.conf` with `[network]\ngenerateResolvConf = false` and write a custom `/etc/resolv.conf`

---

## Cross-OS Process-of-Elimination Summary

```
Apps fail, bypass tool (nslookup / dig) works
    ↓
Check OS-specific catch-all DNS hook:
    Windows → Get-DnsClientNrptRule | Where Namespace -eq '.'
    macOS   → ls /etc/resolver/ + scutil --dns
    Linux   → resolvectl status (per-link DNS) + readlink /etc/resolv.conf
    ↓ clean
Check HOSTS / nsswitch:
    Windows → C:\Windows\System32\drivers\etc\hosts
    macOS   → /etc/hosts
    Linux   → /etc/hosts + /etc/nsswitch.conf hosts line
    ↓ clean
Check local 127.0.0.x:53 listener (DNS proxy):
    Windows → Get-NetUDPEndpoint -LocalPort 53
    macOS   → lsof -i UDP:53
    Linux   → ss -tulnp | grep :53
    ↓ clean
Check security software / kernel hooks:
    Windows → WFP drivers (epfwwfp et al.)
    macOS   → kextstat / system extensions
    Linux   → iptables -L OUTPUT / nft list ruleset
    ↓ clean
Welcome to the long tail — start reading per-OS resolver logs.
```
