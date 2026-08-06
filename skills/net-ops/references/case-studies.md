# Case Studies

Worked examples of network diagnostics that motivated this skill. Each case includes the initial symptoms, the diagnostic path, the dead ends, and the final cause. Identifying details are scrubbed; technical details that reproduce the diagnostic value are preserved.

## Case 1: The Proton VPN Ghost (Windows)

### Initial Report

> "Internet not working on my Windows desktop. It wasn't working on wifi earlier today so I switched to ethernet — but problems persisted."

That last sentence is a load-bearing clue: switching physical interface didn't help. That rules out the NIC, driver, cable, and wifi association in a single observation. Whatever is broken lives at the OS layer or above.

### Diagnostic Path

**Rung 1 (link):** Ethernet `Up`, valid private IP, valid default gateway. ✓

**Rung 2 (ICMP):** Ping `1.1.1.1`, `8.8.8.8`, gateway — all <5ms. ✓

**Rung 3 (sockets):** First test misread — `Resolve-DnsName -Server 1.1.1.1` timed out, which felt like UDP/53 was blocked. **Mistake.** Should have gone straight to raw UDP to disambiguate. When raw UDP/53 was eventually tested, it returned a 124-byte DNS response in milliseconds. Lesson: `Resolve-DnsName` uses the Windows DNS Client API even when `-Server` is specified — it's not a clean probe of the network.

**Rung 3 (sockets, second pass):**
- TCP/53 to 1.1.1.1 → works
- Raw UDP/53 to 1.1.1.1 → works (124-byte reply)
- TCP/443 to 1.1.1.1 → **fails**
- TCP/443 to 8.8.8.8 → **fails**
- TCP/443 to 140.82.114.4 (github.com) → works
- TCP/443 to 13.107.42.14 (microsoft.com) → works

**Discriminator:** Destination-specific HTTPS block. Known public DoH resolver IPs are firewalled on 443; everything else works. **Smell of AV "Encrypted DNS Detection."** Confirmed by `Get-CimInstance -Namespace root/SecurityCenter2`: ESET Security + ESET Firewall both active, and `epfwwfp` WFP callout driver loaded.

This was filed as a **secondary concern** — not the cause of the main symptom (general DNS failure for browsers). Important not to chase the first interesting finding when it doesn't match the headline symptom.

**Rung 4 (nslookup):** `nslookup google.com` against router, 1.1.1.1, and 8.8.8.8 — all returned addresses immediately. ✓

**Rung 5 (DNS Client API):** `Resolve-DnsName google.com -Type A` → timeout. `Invoke-WebRequest https://www.google.com` → "The remote name could not be resolved."

**The smoking gun.** Rung 4 passed perfectly; rung 5 failed identically across all targets. Everything app-level fails because every app uses the DNS Client API. nslookup works because it has its own resolver.

### The False Lead

First suspicion: ICS. Port 53 was held by `svchost` PID `3928`, which turned out to be the `SharedAccess` service. Stopped it; the service bounced back on a new PID, and DNS resolution did not recover. ICS was a red herring — it was running but its sharing configuration was empty, meaning it wasn't actually doing anything harmful. Lesson: **don't disable a service just because it looks suspicious; verify it's actually causing the symptom first.**

### The Second False Lead

Next suspicion: ESET's WFP driver. The driver was present and active, and the destination-specific HTTPS block looked like classic AV protocol filtering. But: AV protocol filtering normally affects HTTPS, not DNS Client API calls. Before pausing ESET, ran `Get-DnsClientNrptRule`.

### The Answer

```
Namespace                         NameServers
---------                         -----------
.                                 10.2.0.1
```

A catch-all NRPT rule routing every DNS query to `10.2.0.1`. The rule's `Comment` field: **"Force all DNS requests via Proton VPN"** — verbatim from Proton's source code. The IP `10.2.0.1` is Proton's in-tunnel DNS gateway, only reachable while connected to their VPN.

Removed the single rule. Flushed DNS cache. Re-tested:
- `Resolve-DnsName google.com` → instant success, returned A records
- `Invoke-WebRequest https://www.google.com` → HTTP 200, full page body

### Forensics

Checked `C:\Program Files\Proton\VPN\Install.log.txt`: Proton VPN installation confirmed (current Inno Setup log entry showed the latest installed version). Service binaries present (`ProtonVPNService.exe`, `ProtonVPN.WireGuardService.exe`), all in `Stopped` state at time of diagnosis. The last active VPN session timestamp (per `ServiceData\WireGuard\log.bin`) predated the issue report by several days — DNS had been silently broken since the last disconnect, masked by occasional cache hits and apps that handle DNS failure gracefully.

**Likely trigger:** Sleep or hibernate during an active Proton WireGuard session. Proton's disconnect cleanup hook didn't fire, and the NRPT rule outlived the tunnel.

### Lessons

1. **Always run `Get-DnsClientNrptRule` before suspecting WFP/AV.** It's a one-line check that resolves 90% of "DNS infrastructure works but apps fail" cases.
2. **Don't conflate `Resolve-DnsName` with a network probe.** It uses the system DNS Client API and inherits every hook in the path. Use raw UDP for actual network-layer DNS testing.
3. **Multiple anomalies don't mean multiple bugs.** ESET's DoH IP block was a real and separate finding, but it wasn't the cause of the headline symptom. Stay focused on what matches the user's actual complaint.
4. **The `Comment` field on NRPT rules is gold.** VPN clients tend to write self-identifying strings. Read them before assuming malice.
5. **Interface-switch ineffective = OS-layer cause.** When wifi → ethernet doesn't fix it, the diagnostic search space contracts dramatically.

## Case 2: The NAS That Vanished by Name (Windows, live ProtonVPN)

### Initial Report

> "Mapped drive Z: → \\NAS\vault shows Disconnected." (TITAN, 2026-08-06; the NAS is a Synology DiskStation at 192.168.50.11.)

Internet was fine — which is exactly why the existing rungs 1–6 couldn't express the fault: every rung is framed around reaching the public internet. This case created the rung 3.5 LAN-services track.

### Diagnostic Path

**Rung 3.5 (LAN reachability by IP):** The LAN itself was completely healthy — ICMP to 192.168.50.11 OK, TCP/445 OK, TCP/5000 OK (DSM login page title "NAS - Synology DiskStation"). So the host is up and serving SMB; only the *name* is dead.

**Name resolution:** `Resolve-DnsName NAS` failed with `"The filename, directory name, or volume label syntax is incorrect"` — a misleading error that reads like a typo in the command. `nslookup NAS` gave the honest `Non-existent domain`. (Lesson banked: prefer nslookup for single-label diagnosis.)

**NRPT:** `Get-DnsClientNrptPolicy -Effective` showed a catch-all `Namespace='.'` → NameServers `10.2.0.1` — ProtonVPN's in-tunnel DNS gateway, installed by the live WireGuard session (interface metric lower than Ethernet). The catch-all captures single-label names too, and the NRPT match suppresses the LLMNR/NetBIOS-NS broadcast fallback that bare `NAS` relied on before the VPN.

**Fallback resolver check:** a raw UdpClient DNS query to the LAN router (192.168.50.1) on UDP/53 **timed out**, while ICMP and TCP to the same router succeeded — ProtonVPN's DNS-leak-protection blocks UDP/53 egress to anything but the tunnel resolver. So no fallback resolver existed either.

### The False Lead

"Just remap by IP": `\\192.168.50.11\vault` returned `System error 5 / Access is denied`. Looks like a permissions problem; isn't. The Credential Manager entry was keyed to target `NAS` (the hostname), and credentials don't apply across target forms. `cmdkey /list` exposed it.

### The Answer

The VPN was **live and wanted** — so `nrpt-clean.ps1` (built for *orphan* rules from disconnected VPNs) was the wrong tool. The correct fix is coexistence: pin the name in the HOSTS file, which is consulted before NRPT/DNS and therefore wins regardless of VPN state:

```powershell
Add-Content $env:windir\System32\drivers\etc\hosts "192.168.50.11  NAS"   # admin
```

Drive reconnected by name; existing `NAS`-keyed credential kept working; VPN untouched.

### Lessons

1. **"Internet OK" proves nothing about LAN names.** Mapped drives / SMB / single-label hostnames are their own track (rung 3.5) with their own resolution chain: HOSTS → NRPT → DNS suffix search → LLMNR → NetBIOS-NS.
2. **An NRPT `.` catch-all short-circuits everything below it** — including the broadcast fallbacks. And leak protection can remove the LAN router as a fallback resolver too. Two independent mechanisms, one symptom.
3. **Live vs orphan decides the fix.** Orphan rule → nrpt-clean.ps1. Live wanted VPN → HOSTS pin or IP-remap + matching `cmdkey` target. Never delete a live VPN's catch-all.
4. **`System error 5` after an IP remap is a credential-target miss, not permissions.** Check `cmdkey /list` before touching share ACLs.
5. **Don't trust `Resolve-DnsName`'s single-label error text.** `nslookup` tells the truth.

## Case 3: Template for Future Entries

When you diagnose a new case worth remembering, add a section here with:
- Initial report (verbatim if possible)
- Diagnostic path (rung-by-rung)
- False leads (the ones you chased before finding the real cause — these are the educational part)
- The actual cause
- Forensics (how/when/why it got into that state)
- Lessons (1-3 reusable observations)

Cases worth adding:
- A Mullvad-residue case (different IP, otherwise structurally identical to Proton)
- A corporate AnyConnect leak case
- A genuine ESET "Encrypted DNS Detection" case where pausing AV was the fix
- An IPv6-preference-with-broken-v6 slowness case
- A Winsock LSP corruption case
