---
name: asus-router-ops
description: "ASUS router configuration and hardening - Asuswrt-Merlin firmware, security hardening, encrypted DNS (DoT/DoH), VPN (WireGuard/OpenVPN), guest networks, VLAN/IoT isolation, AiMesh, AiProtection, JFFS scripts, QoS. Use for: asus router, asuswrt, merlin, asuswrt-merlin, router hardening, DNS Director, AiProtection, AiMesh, guest network, VPN Director, wireguard router, openvpn router, nvram, jffs, DoT, DoH, port forwarding, IoT isolation."
when_to_use: "Use when configuring or hardening an ASUS router (stock Asuswrt or Asuswrt-Merlin) — e.g. 'harden my ASUS router', 'set up WireGuard or DoT', 'isolate IoT on a VLAN', 'configure AiMesh or guest networking'. Covers VPN Director, AiProtection, DNS, and JFFS scripts."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: net-ops
---

# ASUS Router Operations

> Facts verified as of 2026-07.

Authoritative guidance for configuring and hardening ASUS routers — stock **Asuswrt** and **Asuswrt-Merlin** firmware — via the web UI and SSH/nvram. Covers security hardening, encrypted DNS, VPN, network segmentation, AiMesh, AiProtection, and JFFS scripting.

> **Safety first.** Changes here can lock you out or drop the network. Test during low-usage windows, document the before value, and know how to undo. Cite official docs, not folklore.

---

## Stock Asuswrt vs Asuswrt-Merlin

| | Stock Asuswrt | Asuswrt-Merlin |
|---|---|---|
| Base | ASUS official | Community fork of ASUS source (same core, more control) |
| Scripting | Limited | **JFFS custom scripts**, cron, `services-start`, `firewall-start`, nat-start |
| DNS control | Basic | **DNS Director** (per-client/global DNS redirection, DoT) |
| VPN | OpenVPN/WireGuard server+client | + **VPN Director** (policy/split-tunnel routing) |
| Best for | Most users | Power users wanting scripts, fine-grained DNS/VPN routing |

**Never mix stock and Merlin nodes in the same AiMesh network.** Keep the firmware family consistent across mesh nodes.

---

## Security hardening checklist

Do these on every new router, in order:

1. **Change defaults immediately** — both the admin/login password *and* the WiFi password.
2. **Disable WPS** — it's a brute-force surface.
3. **Disable UPnP** unless an app genuinely needs it (it creates unpredictable port forwards).
4. **Use explicit port forwarding, never DMZ** — DMZ exposes the entire device.
5. **Disable remote WAN admin access** — use a VPN to manage remotely instead.
6. **Enable AiProtection** (two-way IPS + malicious-site blocking) where available.
7. **Set up a guest network** with intranet access disabled (proper isolation).
8. **Enable firewall logging** for security monitoring; forward to syslog if you have a collector.
9. **Apply ingress filtering** (BCP38/84 anti-spoofing) where supported.
10. **Keep firmware current** — security fixes land in point releases.

See `references/hardening-and-network.md` for the full hardening rationale, VLAN/IoT
segmentation, AiMesh backhaul tuning, QoS, and dual-WAN.

---

## DNS privacy stack

| Layer | What | Notes |
|-------|------|-------|
| **Transport** | DoT (DNS over TLS) or DoH (DNS over HTTPS) | Stops plaintext port-53 hijacking. Merlin DNS Director can enforce DoT |
| **Provider** | Cloudflare (1.1.1.1), NextDNS, ControlD, AdGuard | Choose for filtering/analytics needs |
| **Validation** | DNSSEC | Validates record authenticity |
| **Per-client policy** | DNS Director (Merlin) | Different DNS per device/profile; split-horizon |
| **Rebinding protection** | On by default | **Can break local services** (Plex, smart home) — whitelist specific domains rather than disabling wholesale |

**Avoid plain DNS (port 53)** — unencrypted and hijackable. Move to DoT/DoH.

---

## VPN decision table

| Need | Use |
|------|-----|
| Fast modern tunnel, low overhead | **WireGuard** server/client (preferred where supported) |
| Maximum compatibility / legacy clients | **OpenVPN** server/client |
| Route only *some* clients/traffic through VPN | **VPN Director** (Merlin) — policy-based split tunnel |
| Remote admin of the router | VPN in, then manage on LAN (never expose WAN admin) |

Common clients: NordVPN, Surfshark, Mullvad via OpenVPN/WireGuard config import.

---

## Network segmentation

| Goal | Approach |
|------|----------|
| Visitor isolation | Guest network with "Access Intranet" **off** |
| IoT containment | Dedicated guest/VLAN SSID; block lateral movement to main LAN |
| Consistent guest across mesh | Enable guest on AiMesh deliberately; mind "Access Intranet" per node |
| Smart-home discovery | mDNS/Bonjour may need controlled cross-VLAN allowances — scope narrowly |
| Segmented routing | VLAN segmentation + routing policies (capability varies by model) |

---

## Patterns to avoid

| Anti-pattern | Why | Instead |
|--------------|-----|---------|
| DMZ mode | Exposes the whole device to the internet | Explicit per-port forwarding |
| UPnP globally on | Unpredictable auto port forwards | Enable only when required, understand the risk |
| Plain DNS (port 53) | Plaintext, hijackable | DoT/DoH |
| Mixing stock + Merlin in AiMesh | Inconsistent behavior | Keep firmware family uniform |
| Disabling DNS rebind protection wholesale | Reopens rebinding attacks | Whitelist the specific local domains that break |
| Wireless mesh backhaul on congested channels | Throughput collapse | Wired backhaul or dedicated DFS 5GHz channel |
| Default admin/WiFi credentials | Trivial compromise | Change both immediately |
| Remote WAN admin enabled | Major attack surface | Manage via VPN |

---

## Operating principles

1. **Reversibility** — record the current value before changing; know the undo path.
2. **Testability** — change during low-usage windows; verify before walking away.
3. **Trade-offs** — note privacy-vs-functionality costs (rebind protection vs local services).
4. **Verification** — confirm via system log, client-side test (e.g. DNS leak test), or `nvram get`.
5. **Cite official docs** — avoid unverified tweaks.

---

## SSH / JFFS scripting (Merlin)

Merlin runs user scripts from JFFS at lifecycle points. Enable **JFFS custom scripts and
configs** (Administration → System) first.

| Script | Runs at | Use for |
|--------|---------|---------|
| `services-start` | After services start | Start custom daemons |
| `firewall-start` | After firewall (re)builds | Add custom iptables rules (survives firewall restarts) |
| `nat-start` | After NAT rules load | Custom NAT/port rules |
| `dnsmasq.postconf` | Before dnsmasq starts | Inject dnsmasq config |

Inspect/set persistent config with `nvram get <key>` / `nvram set <key>=<val>` + `nvram commit`
(commit sparingly — it writes flash).

The `assets/firewall-start.sh` template shows the canonical safe shape for custom firewall
rules. See `references/hardening-and-network.md` for placement and gotchas.

---

## Assets

| File | Use |
|------|-----|
| `assets/firewall-start.sh` | Annotated Merlin `/jffs/scripts/firewall-start` template — idempotent custom iptables rules with safe-by-default examples |

---

## See also

- `net-ops` — general networking: subnets, DNS, TLS, firewalls, packet inspection

### Key external resources

- [Asuswrt-Merlin project](https://www.asuswrt-merlin.net/) · [docs](https://www.asuswrt-merlin.net/docs) · [wiki](https://github.com/RMerl/asuswrt-merlin.ng/wiki)
- [Merlin features (DNS Director, VPN Director)](https://www.asuswrt-merlin.net/features)
- [ASUS router security hardening FAQ](https://www.asus.com/support/faq/1039292/)
- [ASUS firewall intro](https://www.asus.com/us/support/faq/1013630/) · [Network Services Filter](https://www.asus.com/support/faq/1013636/) · [IPv6 firewall](https://www.asus.com/support/faq/1013638/)
- [AiProtection overview](https://www.asus.com/au/content/aiprotection/) · [setup](https://www.asus.com/support/faq/1008719/)
- [Cloudflare DoH](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/) · [ControlD ASUS setup](https://docs.controld.com/docs/asus-router-setup)
- [SNBForums community](https://www.snbforums.com/)
