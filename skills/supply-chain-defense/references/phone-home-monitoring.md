# Phone-home monitoring — watching outbound connections on a dev workstation

The gap this closes: every other control in this skill fires at *install time*
(cooldown, behavioural score, lifecycle-script interception) or at *rest*
(exposure-check, integrity-audit). None of them watches what already-running code
**does on the network**. A credential stealer that landed before the controls were
wired — or that slipped past them — does its damage as an *outbound connection*:
the Shai-Hulud family steals credentials and then phones home (the Sept 2025 wave
exfiltrated to attacker-created `webhook.site` URLs). Outbound monitoring is the
last tripwire, and the one that works even when you don't know what landed.

`scripts/phone-home-monitor.ps1` is the operational tool. This reference is the
tooling evaluation behind it and the wiring guide for the preferred capture source.

## Contents

1. [Tooling evaluation (tool-first: what already exists)](#tooling-evaluation-tool-first-what-already-exists)
2. [Wiring Sysmon (one-time, elevated)](#wiring-sysmon-one-time-elevated)
3. [What the script flags (rules → severity)](#what-the-script-flags-rules--severity)
4. [Continuous capture (the daemon question)](#continuous-capture-the-daemon-question)
5. [Triage — a finding is not yet an incident](#triage--a-finding-is-not-yet-an-incident)
6. [Known limitations (honest list)](#known-limitations-honest-list)

## Tooling evaluation (tool-first: what already exists)

| Source | What it gives | Cost / friction | Verdict |
|---|---|---|---|
| **Sysmon Event ID 3** + curated config | Every TCP/UDP connect event, with image path, PID, user, destination IP **and resolved hostname**, kernel-side — nothing is missed | One elevated install; config tuning decides noise | **Preferred.** Install with a community-tuned config (below) rather than writing rules from scratch |
| **WFP audit (Event 5156)** | Every allowed connection via Windows Filtering Platform — built-in, no install | Enormous volume (all loopback + inbound too), no hostname, audit policy churns the Security log | Viable fallback where Sysmon is prohibited; too noisy as a default |
| **`Get-NetTCPConnection` polling** | Current TCP table + owning PID — zero install, works everywhere | Polling: connections shorter than the interval are missed; no UDP remote | **Default source** for the script because it needs nothing; honest about its blind spot |
| **Wireshark / tshark** | Full packet capture | Heavy install, no process attribution without extra correlation | Forensics tool, not a monitor — use during an incident, not continuously |
| **Firewall logging** (`Set-NetFirewallProfile -LogAllowed True`) | pfirewall.log of allowed/blocked flows | No process attribution in the log; W3C text parsing | Cheap corroboration only |
| Commercial EDR / Little-Snitch-class agents (Portmaster, Safing) | Per-app prompts, allow/deny | Another agent, another supply chain | Out of scope for this skill's $0 posture; consider independently |

**Decision:** wire **Sysmon with the SwiftOnSecurity config** as the continuous
source (it ships sane Event ID 3 filters that exclude known-chatty Windows
processes), and use the script's TCP-table polling as the zero-install default
until that's done. The script consumes either: `-Sysmon` reads EID 3; default mode
polls. `-Status` tells you which sources are live on the host.

## Wiring Sysmon (one-time, elevated)

```powershell
winget install Microsoft.Sysinternals.Sysmon
curl -o sysmonconfig.xml https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml
sysmon64 -accepteula -i sysmonconfig.xml
```

- Config alternatives: `olafhartong/sysmon-modular` (finer-grained, MITRE-mapped)
  if SwiftOnSecurity's defaults prove too quiet or too loud for this machine.
- Verify: `phone-home-monitor.ps1 -Status` → `sysmon_eid3: available`.
- Then prefer `phone-home-monitor.ps1 -Sysmon -MaxEvents 500` for review passes —
  it sees the short-lived connections polling misses, and EID 3 carries
  `DestinationHostname` so IOC domain matching works without a DNS-cache hit.
- Update cadence: Sysmon itself via winget; re-check the config repo occasionally
  (it is versioned, changes are reviewable diffs).

## What the script flags (rules → severity)

| Rule | Signal | Severity |
|---|---|---|
| `ioc-endpoint` | Destination hostname/IP matches `assets/network-ioc.json` (webhook.site = the cited Shai-Hulud exfil endpoint; plus anonymous request-capture services) | high |
| `suspicious-path` | The connecting binary lives under `node_modules`, `AppData\Local\Temp`, `npm-cache`, `Windows\Temp` | high |
| `package-manager-child` | Parent chain contains npm/pnpm/yarn/bun/pip/uv/cargo/composer/gem — lifecycle-script behaviour | high |
| `young-domain` | (`-CheckDomainAge`, network) RDAP registration < 30 days | high |
| `interpreter-raw-ip` | node/python/deno/bun connecting to a raw public IP with no DNS name in the client cache | medium |
| `unsigned-userland` | Unsigned binary in a user-writable path making outbound connections | medium |
| `interpreter-outbound` | Any other interpreter outbound connection (informational — dev servers do this constantly) | low |

Exit `10` on any **medium+** finding; `-Strict` counts `low` too. Loopback and
RFC1918 destinations are skipped except for IOC matching. The catalog is meant to
be extended from advisories exactly like `exposure-catalog.json`.

## Continuous capture (the daemon question)

Three tiers, cheapest first:

1. **On-demand snapshot** — run the script when something feels off (the gsudo-class
   "unexplained prompt" moment): `phone-home-monitor.ps1` or `-Sysmon`.
2. **Watch mode** — `-Watch -IntervalSeconds 30` polls continuously, dedupes by
   (pid, raddr, rport), and appends medium+ findings to a ring-buffer JSONL log
   (`%LOCALAPPDATA%\supply-chain-defense\phone-home.jsonl`, 10 MB × 2 files).
3. **Scheduled task** — `-InstallTask` registers a logon task running watch mode
   hidden for the current user (`-UninstallTask` removes it). With Sysmon wired,
   the task is belt-and-braces: Sysmon records everything regardless; the task
   gives you the *triage* layer continuously.

Review the log with: `Get-Content $env:LOCALAPPDATA\supply-chain-defense\phone-home.jsonl | ConvertFrom-Json`
or `jq -s 'group_by(.rule) | map({rule: .[0].rule, n: length})' phone-home.jsonl`.

## Triage — a finding is not yet an incident

1. **Identify the process**: is it something you launched (dev server, test run)?
   `interpreter-outbound` low-severity findings are usually exactly that.
2. **Check the parent chain**: `package-manager-child` during an `npm install` you
   just ran is *expected* (that's what lifecycle scripts do) — the question is
   whether the destination makes sense for the package.
3. **IOC hit or suspicious-path hit you can't explain** → treat as an incident:
   disconnect, `integrity-audit.sh` (persistence hooks), `exposure-check.py`
   (named-bad packages), rotate every credential the process could read
   (`~/.npmrc`, `~/.aws`, gh tokens, SSH keys), then investigate the binary.
4. **Capture before you kill**: note PID, path, and remote endpoint; if Sysmon is
   wired the history is already in the event log.

## Known limitations (honest list)

- TCP-table polling misses connections shorter than the interval — that is the
  argument for Sysmon, restated. UDP remotes aren't visible in polling mode at all.
- DNS-cache hostname mapping is best-effort: a stealer using DoH or hardcoded IPs
  shows as `interpreter-raw-ip` (which is itself the signal).
- `-CheckDomainAge` uses naive registrable-domain extraction (last two labels) —
  `foo.co.uk`-style names resolve to `co.uk` and return no age. Advisory only.
- Signing status of a process whose binary was deleted after launch reads
  `unknown` — suspicious in itself when combined with other signals.
- A kernel-level or already-elevated implant can evade any user-mode monitor; this
  is a tripwire for the commodity-stealer class, not an EDR replacement.
