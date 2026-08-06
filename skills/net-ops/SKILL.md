---
name: net-ops
description: "Cross-platform network troubleshooting (Windows, macOS, Linux) via local or remote shell. Use for: DNS broken, can't resolve hostnames, nslookup/dig works but apps fail, NRPT, WFP, scutil, /etc/resolver, systemd-resolved, /etc/resolv.conf, NetworkManager, VPN DNS leak residue (ProtonVPN/Mullvad/WireGuard/AnyConnect), AV/firewall blocking DNS or DoH, Tailscale DNS interaction, intermittent connectivity, remote diagnostics over SSH, mapped network drive Disconnected, SMB share unreachable, \\\\server\\share, NAS by hostname fails but IP works, single-label hostname, LLMNR/NetBIOS, VPN blocks LAN DNS, System error 5 on net use."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: debug-ops
---

# Network Operations

Diagnose network problems on Windows, macOS, or Linux with a layered ladder that isolates faults to the smallest possible scope, then pattern-match against OS-specific culprits. Designed for the common case: someone reports "internet broken" on a box you can shell into (locally or via SSH).

## The Universal Insight

**Bypass-tool succeeds while OS-resolver fails is a smoking gun on every platform.** It means DNS infrastructure is healthy but the operating system's name-resolution path is hooked or misconfigured. The bypass tool differs per OS but the discriminator is identical:

| OS | Bypass tool | OS resolver tool | If bypass works but resolver fails |
|---|---|---|---|
| Windows | `nslookup` | `Resolve-DnsName`, browsers | NRPT, WFP, HOSTS, LSP, local 127.0.0.1:53 proxy |
| macOS | `dig @1.1.1.1` | `dscacheutil -q host`, browsers | `/etc/resolver/*`, scutil DNS, profiles, mDNSResponder, kext |
| Linux | `dig @1.1.1.1` | `getent hosts`, `resolvectl query` | systemd-resolved, `/etc/resolv.conf`, NetworkManager, dnsmasq, NSS |

The bypass tool implements its own resolver and talks straight to UDP/53. The OS resolver tool goes through the full system name-service path including all hooks. Comparing the two narrows the suspect list dramatically.

## The Diagnostic Ladder

Walk down the layers in order. **Do not skip rungs.** Each rung has a binary outcome that eliminates everything above it. Per-OS tools are in `references/diagnostic-ladder.md`; the structure is universal.

```
1. Link layer        — interface up, valid IP, gateway present
2. IP reachability   — ping public IPs over ICMP
3. Socket reach.     — TCP/443 + UDP/53 to known destinations (raw socket DNS)
3.5 LAN services     — parallel track: mapped drives, SMB, mDNS/.local,
                       single-label hostnames (see below — internet OK ≠ LAN OK)
4. DNS infrastructure — bypass tool: nslookup / dig @<server>
5. OS resolver path  — the hook layer (most interesting on modern systems)
6. Application       — real HTTP request to a real hostname
```

The most common mistake: jumping to rung 6 ("HTTPS doesn't work, must be a cert / proxy") when rung 5 is the actual problem (an orphan VPN DNS rule on Windows, a stale `/etc/resolver/` file on macOS, a misconfigured systemd-resolved on Linux). Discipline prevents this.

## The LAN Services Track (Rung 3.5)

Rungs 1–6 are framed around reaching the *public internet*. A mapped drive showing `Disconnected` while browsing works fine is a different fault domain: **local-network service reachability**. Symptoms: SMB shares, printers, `\\NAS\share`, `.local` names, single-label hostnames.

The load-bearing concept is the **single-label hostname resolution path**:

```
HOSTS file → NRPT match → DNS (suffix search) → LLMNR → NetBIOS-NS
```

An NRPT `.` catch-all (live VPN or orphan) short-circuits everything below it: the single-label name goes to the VPN resolver (NXDOMAIN) **and** the LLMNR/NetBIOS broadcast fallback that LAN names normally rely on is suppressed. VPN DNS-leak-protection often also blocks UDP/53 to the LAN router, so there's no fallback resolver either. Full chain, per-OS tools, and the credential-target gotcha: `references/diagnostic-ladder.md` (rung 3.5).

**One-shot audit:** `scripts/windows/smb-audit.ps1` walks every mapped drive through mapping state → resolution mechanism → ICMP/TCP-445 → credential targeting → NRPT/leak-protection detection, and emits a verdict naming the fix.

**VPN + LAN coexistence — decision rule.** Is the VPN *live and wanted*?

- **Yes** → do NOT touch the NRPT rule. Pin the name in the HOSTS file (consulted before NRPT, so it wins regardless of VPN state; needs admin), or remap by IP *and* add a credential keyed to that IP (`cmdkey /add:<ip>`).
- **No** (VPN gone, rule orphaned) → `scripts/windows/nrpt-clean.ps1 -Apply`.

**`nrpt-clean.ps1` must never be pointed at a live VPN's catch-all** — it exists for orphans only. Deleting a wanted VPN's rule breaks its DNS routing and the client will just re-create it.

## Workflow

### 1. Identify the target OS

If local: `uname -s` (Unix) or check shell environment. If remote over SSH, the bootstrap script auto-detects:

```bash
scripts/ssh-bootstrap.sh <user>@<host>
```

### 2. Run the OS-appropriate probe

| OS | Script |
|---|---|
| Windows | `scripts/windows/probe.ps1` (via `-EncodedCommand` over SSH) |
| macOS | `scripts/macos/probe.sh` |
| Linux | `scripts/linux/probe.sh` |

Each prints structured `[PASS]/[FAIL]` per rung. Scan for the first FAIL — that's where to drill in.

### 3. Drill into the failing layer

The interesting failures are almost always rung 5. Per-OS deep-dive scripts:

| OS | Script | What it does |
|---|---|---|
| Windows | `scripts/windows/nrpt-audit.ps1` | Dump NRPT rules with attribution + registry forensics |
| Windows (LAN/SMB) | `scripts/windows/smb-audit.ps1` | Mapped-drive audit: resolution mechanism, reachability, credential targets, NRPT/leak-protection, verdict |
| macOS | `scripts/macos/dns-audit.sh` | Dump scutil --dns, /etc/resolver/*, mDNSResponder state, profiles |
| Linux | `scripts/linux/dns-audit.sh` | Dump systemd-resolved status, resolv.conf chain, NM config, NSS order |

### 4. Apply the minimum reversible fix

Repair scripts default to **dry-run** and protect known-good config (Tailscale MagicDNS, MDM-managed entries). Apply only when the dry-run output matches expectation.

| OS | Repair script |
|---|---|
| Windows | `scripts/windows/nrpt-clean.ps1` (removes orphan NRPT catch-alls, protects Tailscale) |
| macOS | `scripts/macos/resolver-clean.sh` (removes orphan `/etc/resolver/*` from disconnected VPNs) |
| Linux | `scripts/linux/resolved-reset.sh` (resets systemd-resolved per-link config) |

## Quick Reference: Smoking Guns

| Platform | Symptom | Most likely cause | Quick test |
|---|---|---|---|
| Windows | `nslookup` works, browsers fail | Orphan NRPT catch-all (VPN residue) | `Get-DnsClientNrptRule \| Where Namespace -eq '.'` |
| Windows | Public DoH resolver IPs blocked on 443, other 443 works | AV "Encrypted DNS Detection" | `Get-CimInstance -Ns root/SecurityCenter2 -Class AntiVirusProduct` |
| macOS | `dig` works, browsers fail | Stale `/etc/resolver/*` from disconnected VPN | `ls /etc/resolver/ && scutil --dns \| head -40` |
| macOS | All DNS fails post-VPN install | Configuration profile with DNS override | `profiles list -type configuration` |
| Linux | `dig` works, `getent hosts` fails | systemd-resolved misconfigured | `resolvectl status` |
| Linux | DNS works on some apps, not others | NSS order in `/etc/nsswitch.conf` excludes `resolve` | `grep ^hosts /etc/nsswitch.conf` |
| All | DNS suddenly broken after sleep/wake | VPN client failed disconnect cleanup | OS-specific (see above) |
| Windows | Mapped drive `Disconnected`, host pings by IP but not by name, VPN active | NRPT `.` catch-all swallowing single-label names (+ suppressing LLMNR/NetBIOS fallback) | `Get-DnsClientNrptPolicy -Effective \| ? Namespace -eq '.'` |
| Windows | `net view \\<ip>` returns `System error 5` while the same share worked by hostname | Credential Manager target keyed to hostname, not IP | `cmdkey /list` |
| All | LAN hosts reachable by IP but router's DNS times out on UDP/53 while TCP to it succeeds | VPN DNS-leak-protection egress filter | `scripts/windows/smb-audit.ps1` (LAN DNS EGRESS section) |

## SSH Transport Patterns

### Windows targets

PowerShell-over-SSH has notorious escaping issues. Always pass scripts via `-EncodedCommand` with UTF-16LE base64:

```bash
B64=$(printf '%s' "$PS_SCRIPT" | iconv -t UTF-16LE | base64)
ssh <target> "powershell -NoProfile -EncodedCommand $B64"
```

### Unix targets (macOS, Linux)

Heredoc works cleanly; no special encoding needed:

```bash
ssh <target> 'bash -s' < scripts/linux/probe.sh
# or, with arguments:
ssh <target> "bash -s -- arg1 arg2" < scripts/linux/probe.sh
```

For consistency, `scripts/ssh-bootstrap.sh` handles both transports based on detected OS.

## Pattern Recognition

After a few sessions, certain symptom triplets become instantly diagnosable. See `references/case-studies.md` for worked examples. Hall-of-fame entries:

**Windows:** `nslookup` works, `Resolve-DnsName` times out identically across all servers, `Invoke-WebRequest` says "remote name could not be resolved" → orphan NRPT catch-all from a disconnected VPN. Common gateway IP patterns are listed in `references/common-culprits.md`.

**macOS:** `dig <host>` works, browsers say "cannot find server," `scutil --dns` shows extra "resolver #N" entries pointing at private-range gateways with `domain :` listed → leftover `/etc/resolver/<domain>` files from a disconnected VPN.

**Linux:** `dig @<public-resolver> <host>` works, `getent hosts <host>` fails → `/etc/nsswitch.conf` may have an NSS chain that skips `resolve`, OR `/etc/resolv.conf` is no longer symlinked to the systemd-resolved stub.

## Safety Notes

- **Read before write.** Always dump current state before modifying a resolver config. The forensics may be load-bearing for explaining what happened.
- **Don't disable security tools without consent.** AV / firewall hooks are intrusive but legitimate. Pause is preferred over uninstall.
- **Tailscale's name-resolution config looks like junk but is essential.** Always filter on protected nameserver patterns (`100.100.100.100` on all OSes) before bulk-deleting.
- **Resolver config persists across reboots.** Removing a rule is forever (until the VPN re-creates it). Confirm the source/comment before deletion.
- **macOS profile DNS overrides may be MDM-managed.** Removing them may violate enterprise policy and may be re-applied automatically. Coordinate with IT.

## References

- `references/diagnostic-ladder.md` — full ladder methodology with per-OS commands per rung
- `references/common-culprits.md` — detection + fix catalog for Windows / macOS / Linux
- `references/case-studies.md` — worked examples and template for adding new ones

## Scripts

- `scripts/ssh-bootstrap.sh` — establish SSH session, auto-detect target OS, emit usable invocation
- `scripts/windows/probe.ps1` — full layered diagnostic for Windows
- `scripts/windows/nrpt-audit.ps1` — NRPT forensics with attribution
- `scripts/windows/nrpt-clean.ps1` — safe NRPT cleanup (orphans ONLY — never point it at a live VPN's catch-all; protects Tailscale)
- `scripts/windows/smb-audit.ps1` — mapped-drive / SMB / LAN-name audit with per-drive verdicts (`-DriveLetter Z -FallbackIp 'NAS=192.168.50.11'`, `-Json`)
- `scripts/macos/probe.sh` — full layered diagnostic for macOS
- `scripts/macos/dns-audit.sh` — scutil + /etc/resolver + profile + mDNSResponder dump
- `scripts/macos/resolver-clean.sh` — remove orphan /etc/resolver/* files
- `scripts/linux/probe.sh` — full layered diagnostic for Linux
- `scripts/linux/dns-audit.sh` — systemd-resolved + NM + NSS + resolv.conf dump
- `scripts/linux/resolved-reset.sh` — reset systemd-resolved per-link state
