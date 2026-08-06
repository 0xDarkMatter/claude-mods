---
name: windows-ops
description: "Comprehensive Windows workstation operations - diagnose slow boot, failing drives, BSOD crashes, startup bloat, event logs. Use for: Windows is slow, slow bootup, won't boot, blue screen, BSOD, kernel crash, drive failing, SMART errors, disk errors, Event 41, Event 129, storahci reset, BugCheck, CRITICAL_PROCESS_DIED, crash dump, MEMORY.DMP, minidump, msconfig, services.msc, registry Run keys, StartupApproved, scheduled tasks at logon, slow login, high CPU at boot, disable startup app, unexplained UAC prompt, what asked for admin, prefetch forensics, BAM, process attribution, Security 4688. A drive letter alone does not name the skill: mapped network drive, SMB, UNC, NAS route to net-ops."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: net-ops, debug-ops, perf-ops
---

# windows-ops

## Helps with

Slow boot on a Windows machine that used to be fast — bloat accumulation across the five startup mechanisms (registry Run keys, services, scheduled tasks, startup folders, group policy). The same machine still boots fast once those are inventoried and trimmed.

Failing drives that nobody's spotted yet. The signal lives in System log Events `7` / `52` / `153` / `154` (disk bad block, paging error, retry, hardware error) and `storahci` Event `129` ("Reset to device, \Device\RaidPortN, was issued"). Healthy drives produce zero of these — hundreds in a month means active failure even when SMART still claims "Healthy."

Crashes with no obvious cause. Event 41 (Kernel-Power) carries the BugCheck code at `Properties[0]` and four parameters at `Properties[1-4]`. A `0xEF` (CRITICAL_PROCESS_DIED), `0xD1` (DRIVER_IRQL), `0x124` (WHEA uncorrectable), or `0x0` (no bugcheck recorded → hard power loss) each implies a completely different fix.

"My PC is slow" diagnosed by chasing the wrong symptom. Task Manager shows what's running NOW; the System log shows what failed at boot, what's been crashing, and what storage events preceded each crash. Always audit before treating.

Unable to disable an HKLM startup entry because the user isn't an Administrator. The `StartupApproved` registry mechanism — what Task Manager's "Disable" button actually does — flips one byte in `HKCU\...\Explorer\StartupApproved\Run` and works without elevation, even for HKLM entries.

BSOD analysis without a dump file. Pagefile too small, or hard power loss skipped the dump-write. `CrashDumpEnabled` registry key + pagefile size + free space on system drive determine whether the next crash gets diagnosed at all.

Pre-crash timeline correlation. The events in the 10 minutes BEFORE Event 41 are where the story is. `storahci` resets before a crash → storage failure cascade. `nvlddmkm` / `igdkmd64` warnings before crash → GPU driver hang. WHEA events before crash → hardware fault.

Identifying which physical drive is failing when the symptom is "Disk 1" or "\Device\Harddisk1" in an event message. Maps physical disk number ↔ drive letter ↔ controller port ↔ model + firmware, so the user knows which SATA cable to unplug.

Adobe Creative Cloud / Docker Desktop / Slack / Electron app bloat eating boot time. Each ships with multiple startup entries (registry + services + scheduled tasks) that all need disabling to fully stop the auto-launch.

"Is it safe to physically disconnect drive X?" — finding every system mechanism that references a drive letter before pulling the cable. Pagefile location, Windows Search index, scheduled tasks, services, user-profile junctions / symlinks, startup folder shortcuts, registry Run keys, and volume mount points. The wrong answer destroys uptime; the right answer is a one-line verdict.

Cloning data off a failing drive without finishing it off. `robocopy /R:0 /W:0` (no retries) avoids the "every retry on a bad sector kills the drive faster" trap. For severely damaged drives, `ddrescue` with a resumable map file is the next tier. NEVER `chkdsk /f` a failing drive — repair operations write to bad sectors and accelerate failure.

Recovery from no-boot scenarios — boot configuration data (BCD) repair via `bootrec`, UEFI bootloader rebuild via `bcdboot`, Safe Mode access from a failing system, System Restore from Windows RE, and the boot-sequence triage layers (POST → boot device → boot driver → service load → shell).

Remote Windows diagnostics across the network. PowerShell remoting via WS-Man (the default WinRM transport) or SSH (modern alternative on Win10 1809+). Authentication for in-domain (Kerberos), workgroup (NTLM via `TrustedHosts`), and cross-OS (SSH key) scenarios. The double-hop problem and CredSSP. Running this skill's diagnostic scripts against a remote box by staging the skill folder via `Copy-Item -ToSession`.

Unexplained UAC prompts attributed to their caller. A declined elevation still executes the requesting binary unelevated, so Prefetch run times (PECmd), BAM last-execution FILETIMEs, the npx `_npx` cache, and Security 4688 (if auditing is on) identify exactly what asked for admin and when — see `references/uac-attribution.md` for the playbook and the one-elevated-pass forensic ladder.

Boot duration measurement and slow-startup-component identification. The `Microsoft-Windows-Diagnostics-Performance/Operational` log (admin-only) records per-boot timing — `BootMainPathTime`, `BootPostBootTime`, total, and degradation flag — plus calls out specific apps, drivers, or services that exceeded the system's fast-boot threshold. Without admin, kernel-event fallback gives coarser but still useful timing.

## The Universal Insight

**Windows tells you what's wrong if you ask the right log in the right way.** Most users (and most tutorials) reach for Task Manager. The actual diagnostic signal lives in the Event Log, the Registry's StartupApproved key, the storage driver's reset events, and the kernel's bugcheck records. This skill packages the queries that turn noise into a verdict.

The most common diagnostic failure: treating symptoms in isolation. "Slow boot" → disable startup apps. "BSOD" → reinstall drivers. "Random crashes" → memtest. These are reasonable last resorts, but the data to identify the *actual* cause is sitting in the System log untouched. Always audit before treating.

## The Diagnostic Ladder

Walk down the layers in order. Each rung has a binary outcome:

```
0. Is it even local?  — a "drive" that is a network mapping belongs to net-ops
1. Hardware errors    — WHEA-Logger events (CPU/RAM/PCIe-level faults)
2. Storage health     — disk events 7/52/153/154, storahci 129 (controller reset)
3. Crash record       — Event 41 (Kernel-Power) + BugCheck code + dump files
4. Pre-crash timeline — events in N minutes before each crash
5. Boot inventory     — all 5 startup mechanisms (registry, services, tasks, folders, group policy)
6. Resource pressure  — top CPU/RAM/IO consumers
7. Verdict            — what's failing, what to do
```

The most interesting failures cluster at rung 2 (storage) and rung 5 (startup bloat). The least interesting (but most-treated) is rung 6.

## Workflow

### 0. Disambiguate the drive letter first

A user saying "drive Z: is broken" cannot know whether that is a failing physical disk (this skill) or an SMB/name-resolution fault (`net-ops`) — the drive letter looks identical either way. Settle it before running anything else:

```powershell
Get-SmbMapping                            # network mappings + Status (Connected / Disconnected / Unavailable)
Get-PSDrive -PSProvider FileSystem | Where-Object DisplayRoot   # non-empty DisplayRoot = UNC-backed
```

**If the letter appears in either result, it is a network mapping — stop here and hand off to `net-ops` (`scripts/windows/smb-audit.ps1`).** Do not run the physical-disk ladder: `disk-health.ps1` and `drive-dependencies.ps1` only see local disks, so they will report a clean bill of health on a drive that is genuinely broken, which is worse than reporting nothing.

Everything below assumes a local, physically-attached drive.

### 1. Run the comprehensive audit

```powershell
scripts/health-audit.ps1
```

Produces a verdict block: hardware errors, storage health per disk, recent crashes, top resource consumers, startup inventory. Scan for `[FAIL]` markers — that's where to drill.

### 2. Drill into the failing layer

| Symptom | Script |
|---|---|
| Storage errors flagged | `scripts/disk-health.ps1 -DiskNumber N` (or `-DriveLetter X` or `-Model 'HGST'`) — focused per-drive deep dive: SMART, all event IDs, controller resets attributable to the drive, verdict |
| Recent crash | `scripts/crash-triage.ps1 -CrashTime <datetime>` (or omit for most recent) — pre-crash timeline + BugCheck decode with smoking-gun detection |
| "Is it safe to disconnect drive X?" | `scripts/drive-dependencies.ps1 -DriveLetter X` — finds pagefile, search index, scheduled tasks, services, symlinks, startup shortcuts, run-key refs pointing at drive |
| "Why is boot taking so long?" | `scripts/boot-perf.ps1` — per-boot durations from Diagnostics-Performance log (admin) or kernel-event fallback (non-admin), with slow-component flags |

### 3. Apply the minimum reversible fix

| Action | Script |
|---|---|
| Disable startup app — Run keys (HKCU + HKLM + WOW64) | `scripts/safe-disable-startup.ps1 -Name <pattern>` (no admin needed; supports wildcards) |
| Disable startup folder shortcut | `scripts/safe-disable-startup.ps1 -Name '*.lnk'` (covered by same script via StartupFolder variant) |
| List current state of all startup entries | `scripts/safe-disable-startup.ps1 -List` |
| Re-enable previously disabled | `scripts/safe-disable-startup.ps1 -Name <pattern> -Enable` |
| Set service to Manual (admin) | `Set-Service <name> -StartupType Manual; Stop-Service <name>` |
| Disable scheduled task | `Disable-ScheduledTask -TaskName <name>` |
| Safe clone from failing drive | `scripts/recover-clone.ps1 -Source <path> -Destination <path>` — robocopy with `/R:0` to avoid pounding bad sectors |

All disables are reversible — the StartupApproved registry mechanism flips one byte; re-enabling is the inverse.

## Storage Health & Failure Detection

The single highest-yield audit. Failing drives cause slow boots (Windows times out probing them), instability (controller resets cascade into kernel hangs), and crashes (I/O failures kill critical processes). Three independent data sources to cross-reference:

### Disk error events

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk'; StartTime=(Get-Date).AddDays(-30)} |
    Group-Object Id | Select-Object Count, Name
```

Event ID catalog (full reference in `references/storage-events.md`):

| ID | Meaning | Severity |
|----|---------|----------|
| **7** | "The device, \Device\HarddiskN\DR1, has a bad block" | **High** — sectors going bad |
| **51** | "An error was detected on device during a paging operation" | High |
| **52** | "Write cache enabled" | Informational |
| **153** | "IO operation at LBA X was retried" | Medium |
| **154** | "IO operation at LBA X failed due to a hardware error" | **High** — Windows' explicit hardware verdict |

Even 10 events of ID 7 or 154 in a month is a strong failure signal. Hundreds = drive replacement is urgent.

### Storage controller resets

```powershell
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='storahci'; Id=129; StartTime=(Get-Date).AddDays(-60)}
```

`storahci` Event 129 ("Reset to device, \Device\RaidPortN, was issued") means the drive stopped responding and the driver had to reset the controller. **Healthy = zero events.** Any non-zero count warrants investigation. >5 in a month = active failure.

### Disk → drive letter mapping

The error message identifies `\Device\HarddiskN` — to find the actual drive:

```powershell
Get-Disk | Select-Object Number, FriendlyName, BusType, HealthStatus, FirmwareVersion,
    @{N='SizeGB';E={[math]::Round($_.Size/1GB,0)}}
```

`Number` matches the `N` in `\Device\HarddiskN`. Cross-reference with `Get-Partition -DiskNumber N` for drive letter.

### SMART reliability counters

```powershell
Get-PhysicalDisk | ForEach-Object {
    $_ | Get-StorageReliabilityCounter | Select-Object Temperature, Wear, ReadErrorsTotal, WriteErrorsTotal, PowerOnHours
}
```

Returns blank on some NVMe drives due to Windows driver limitations — fall back to vendor tools (Samsung Magician, CrystalDiskInfo) or `smartctl` from smartmontools if installed.

## Boot Performance & Startup Management

Windows has **five separate startup mechanisms**, each requiring different tooling. Task Manager only shows two of them. Full inventory in `references/startup-mechanisms.md`.

| Mechanism | Where | How to inspect | How to disable |
|-----------|-------|----------------|----------------|
| Registry Run keys | `HKCU/HKLM\...\Run` (+ WOW6432) | `Get-ItemProperty` | `StartupApproved` binary flag |
| Services | Service Control Manager | `Get-Service` | `Set-Service -StartupType Manual` (admin) |
| Scheduled Tasks at logon | Task Scheduler | `Get-ScheduledTask` | `Disable-ScheduledTask` |
| Startup folder shortcuts | `%APPDATA%\...\Startup\` + AllUsers | `Get-ChildItem` | Delete or rename .lnk |
| Group Policy startup scripts | `HKLM\...\Policies\Scripts` | Group Policy Editor / `gpresult` | (rare on workstations) |

### The StartupApproved trick (disable HKLM entries without admin)

Task Manager's "Disable" button writes a binary flag to:

```
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run    (HKLM 64-bit entries)
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32  (HKLM WOW6432 entries)
HKCU\...\StartupApproved\StartupFolder                                          (startup folder shortcuts)
```

The value is 12 bytes: `[status byte] [00 00 00] [8-byte FILETIME timestamp]`. Status = `0x02` enabled, `0x03` disabled. Writing this to HKCU lets a non-admin user disable HKLM startup entries for themselves. The script `scripts/safe-disable-startup.ps1` automates this.

### Boot duration measurement

Windows 11 stores boot performance in `Microsoft-Windows-Diagnostics-Performance/Operational` log (admin to read). Without admin, infer from the gap between Event 12 (`The operating system started at...`) and Event 6005 (`The Event log service was started`), then to first user-mode event. Typically:

- Healthy SSD system: 15–25 seconds to login screen
- Healthy + many startup apps: 30–60 seconds to usable desktop
- Failing storage: 60+ seconds, with stalls

## Crash Analysis & Dump Triage

### Event 41 (Kernel-Power) decoding

This is **the** crash record. Properties array layout:

| Index | Field | What it means |
|-------|-------|---------------|
| 0 | BugcheckCode | The stop code (0x0 = no bugcheck recorded → hard power loss or hang) |
| 1 | BugcheckParameter1 | First parameter (often a memory address) |
| 2-4 | BugcheckParameter2-4 | Additional parameters |
| 5 | SleepInProgress | True if crash during sleep transition |
| 6 | PowerButtonTimestamp | Non-zero = power button was held |

Common BugCheck codes (full reference in `references/bugcheck-codes.md`):

| Code | Name | Typical cause |
|------|------|---------------|
| `0x0` | (no bugcheck) | Hard power loss, total hang, hardware-level failure |
| `0xEF` | CRITICAL_PROCESS_DIED | A critical system process (csrss/services/wininit) was killed |
| `0xD1` | DRIVER_IRQL_NOT_LESS_OR_EQUAL | Bad driver accessed bad memory address |
| `0x50` | PAGE_FAULT_IN_NONPAGED_AREA | Bad memory or storage I/O for pagefile |
| `0x124` | WHEA_UNCORRECTABLE_ERROR | Hardware-level CPU/cache/PCIe error |
| `0x7E` | SYSTEM_THREAD_EXCEPTION_NOT_HANDLED | Driver crashed |
| `0x9F` | DRIVER_POWER_STATE_FAILURE | Driver hung during sleep/wake |

### Pre-crash timeline correlation

The crash record alone rarely tells you the cause. The **events in the 10 minutes before the crash** are where the story is. Use:

```powershell
scripts/crash-triage.ps1 -CrashTime '2026-05-15 00:57:50' -WindowMinutes 10
```

Look for:
- `storahci` Event 129 (drive reset) before crash → storage failure cascade
- `nvlddmkm` / `igdkmd64` warnings before crash → GPU driver hang
- `WHEA-Logger` events before crash → hardware-level fault
- Sudden silence (no events for >30s before crash) → total system hang

### Dump configuration audit

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' |
    Select-Object CrashDumpEnabled, DumpFile, MinidumpDir, AutoReboot
```

`CrashDumpEnabled` values: `0` = None, `1` = Complete, `2` = Kernel, `3` = Small (minidump), `7` = Automatic.

If `0` or no dumps exist after recent crashes:
- Pagefile may be too small (needs >RAM size for complete dump, or >256MB for minidump)
- Power loss crashes can't write dumps regardless — RAM contents are gone before disk write
- Some BSODs in early boot also skip dump-writing

## Event Log Query Patterns

`Get-WinEvent` with `-FilterHashtable` is dramatically faster than `Where-Object` filtering. Keys that work:

| Key | Type | Example |
|-----|------|---------|
| `LogName` | string or array | `'System'`, `@('System','Application')` |
| `ProviderName` | string or array | `'storahci'`, `'Microsoft-Windows-Kernel-Power'` |
| `Id` | int or array | `41`, `@(7,153,154)` |
| `Level` | int or array | `1`=Critical, `2`=Error, `3`=Warning, `4`=Information |
| `StartTime` | DateTime | `(Get-Date).AddDays(-7)` |
| `EndTime` | DateTime | `(Get-Date)` |

Use `scripts/event-search.ps1` for common patterns (events in time window, by provider, correlated across logs).

## Common Failure Modes

| Symptom | First check | Common cause |
|---------|-------------|--------------|
| Mapped drive shows `Disconnected` / UNC path unreachable | Is this a network mapping? `Get-SmbMapping` | Hand to `net-ops` — not a local storage fault |
| Slow boot, used to be fast | `startup-audit.ps1` | Bloat accumulation (Docker, Adobe CC, Electron apps) |
| Slow boot, getting worse | `disk-health.ps1` | Failing drive — Windows waiting on probe timeouts |
| Random freezes + hard restarts | `disk-health.ps1` + `crash-triage.ps1` | storahci resets cascading into kernel hang |
| BSOD on wake from sleep | `crash-triage.ps1` (BugCheck `0x9F`) | Driver power state failure (often GPU, USB) |
| BSOD with WHEA before it | `crash-triage.ps1` (BugCheck `0x124`) | Hardware fault — RAM, CPU, PCIe lane |
| Sluggish but not crashing | `health-audit.ps1` performance section | Background process pileup |
| Login takes minutes | `startup-audit.ps1` | Slow startup item synchronously blocking shell |

## Recovery Patterns

### Cloning from a failing drive

**Never run `chkdsk /f` on a failing drive** — repair operations write to bad sectors and can finish the drive off. Image first, repair the image second.

```powershell
# Healthy-side clone with no retries (fast, skips bad sectors)
robocopy "Y:\important" "Z:\backup\important" /MIR /R:0 /W:0 /XJ /NDL /LOG:clone.log
```

For bit-level recovery from a drive with many bad sectors, use `ddrescue` (via WSL or live Linux USB) with a map file so the operation is resumable. Documented in `references/storage-events.md`.

### Physically removing a failing drive

If a drive is causing boot stalls or crashes:
1. Identify it via `disk-health.ps1`
2. Verify nothing critical points at it (`scripts/disk-health.ps1 -CheckDependencies <drive-letter>`)
3. Physically disconnect SATA cable OR disable in BIOS OR set offline in `diskpart`
4. Reboot — boot time should drop significantly, controller resets should stop

## Voice & Output Style

Output follows the claude-mods diagnostic convention:

- `[PASS]` / `[FAIL]` / `[WARN]` / `[INFO]` prefixes for scan rows
- Verdict block at the bottom with specific findings + recommended actions
- Drive identifications include physical disk number, model, capacity, drive letter
- Crash references include UTC timestamp, BugCheck code, primary parameter, suspected cause
- No marketing language, no emojis in scripts (reserved for SKILL.md prose where useful)

## What This Skill Doesn't Cover

- **Network diagnostics, including anything storage-shaped that turns out to live on the network** → use `net-ops`. Concretely: a mapped network drive, a mapping stuck `Disconnected` / `Unavailable`, a UNC path (`\\server\share`) that won't open, SMB itself, a NAS or Synology box, `net use` failures, and "access is denied" on a share. A drive letter does not make it local.
- **Specific application performance profiling** → use `perf-ops`
- **Source-code-level debugging** → use `debug-ops`
- **Kernel dump file analysis with WinDbg** — too specialised for this skill; covered by reference doc pointers only
- **Group Policy diagnostics** — relevant for enterprise but rare on workstations
- **Linux-on-Windows (WSL) issues** — separate domain

## Cross-References

| When | Use |
|------|-----|
| The failing "drive" is a network mapping / NAS share (SMB, UNC, `Disconnected`) | `net-ops` owns it — `scripts/windows/smb-audit.ps1` for the mapping + SMB/LAN ladder |
| Need to triage a remote Windows box | `net-ops` reverse-probe pattern adapts directly |
| Crash is networking-related | Combine with `net-ops` for DNS / VPN driver issues |
| Multiple machines exhibit same pattern | Run `health-audit.ps1` on each, diff the outputs |

## References

- `references/storage-events.md` — full event ID catalog for `disk`, `storahci`, `Ntfs`, `partmgr`, `volmgr` providers. Load when investigating disk errors, mapping `\Device\Harddisk N` references, or interpreting LBA-level I/O failures. Includes severity triage thresholds (per-month counts that indicate failure for HDD vs SSD) and the query recipes the audit script uses.

- `references/bugcheck-codes.md` — Windows BSOD stop-code catalog covering the codes that actually appear on workstations. Load when decoding a non-trivial Event 41, analyzing a minidump's stop code, or matching a symptom ("crashes during sleep", "random reboot no dump", "crashes during file copy") to a likely cause. Covers `0xEF`, `0xD1`, `0x124`, `0x50`, `0x7A`, `0x9F` and the special `0x0` case.

- `references/startup-mechanisms.md` — Deep dive on all five Windows startup mechanisms: registry Run keys, services, scheduled tasks, startup folders, group policy. Load when doing a full startup audit, hunting vendor-installed auto-launch hooks across multiple mechanisms, or implementing the StartupApproved disable trick. Includes vendor-pattern checklists (Adobe, Docker, NVIDIA) and edge cases like WMI permanent event consumers and IFEO Debugger redirects.

- `references/recovery-patterns.md` — Drive-failure data recovery (robocopy `/R:0`, ddrescue with map files), filesystem repair (chkdsk decision tree — when NEVER to `/f`), system file integrity (`sfc`, `DISM /Online /Cleanup-Image /RestoreHealth`), boot configuration repair (BCD, `bootrec`, UEFI bootloader rebuild), pagefile relocation, drive removal procedures (software offline → BIOS-disable → physical disconnect → destruction), and no-boot recovery (Windows RE, Safe Mode, System Restore). Load when responding to "my drive is dying" or any irreversible/destructive operation.

- `references/uac-attribution.md` — Attributing an unexplained UAC prompt to its caller: the 30-second in-the-moment playbook (Show details → note command line → decline → check Security 4688), the after-the-fact forensic ladder (Prefetch/PECmd run times, BAM FILETIME decode, npx `_npx` cache, agent-transcript time correlation — all in one elevated pass, never elevated via gsudo itself), the process-creation auditing countermeasure, and the `npx` auto-install footgun. Load when responding to "what asked for admin?", an unexpected elevation prompt, or post-incident process attribution.

- `references/remote-diagnostics.md` — PowerShell remoting patterns (WS-Man and SSH transports) for running this skill against a remote Windows box. Authentication models (Kerberos, NTLM, CredSSP, SSH keys), `TrustedHosts` setup for workgroup machines, the double-hop problem, common error catalog, and a complete worked example: stage the skill on the target via `Copy-Item -ToSession`, then invoke each script remotely and parse the JSON output. Load when troubleshooting "my dad's PC across town", a server in a datacenter, or any Windows machine where physical access isn't available.

## Worked example

A user reports "my PC takes minutes to boot and crashes sometimes." Running `scripts/health-audit.ps1` produces a panel that follows the [Terminal Panel Design System](../../docs/TERMINAL-DESIGN.md):

```
╭── 🩺 windows-ops · health-audit ──────────────────────────────────────────── TITAN ───●
│
├── 4 disks · 1 failing · 2 unclean shutdowns
│
├── failing (5)
│   ├── [storage] Disk 1 (HGST HDN728080ALE6…   Failing: Event7=1943, Event154=1646 …
│   ├── [storage] Controller resets             20 storahci controller resets in 60d
│   ├── [crash] 2026-05-15 00:57                BugCheck=0x0 — hard power loss
│   ├── [crash] 2026-05-11 00:12                BugCheck=0x0 — power button held
│   └── [crash] Pattern                         2 unclean shutdowns — investigate PSU
│   │   ▲ back up + disconnect Disk 1 (Y) — see recover-clone.ps1 and drive-deps.ps1
│
├── warn (2) · pass (7) · info (4)
│
╰── R refresh · D drill · ? help ──────────────────────── ⬤ storage  • 2 crashes ───●
```

The verdict reads at a glance: storage is busted (⬤ — large, unmissable), two crashes recent (•), specific drive identified by `[Y]`, action items inlined under the critical alert with cross-script wayfinding. Drill into the suspect:

```
╭── 🩺 windows-ops · disk-health ──────────────────────────────────── Disk 1 / Y ───●
│
├── HGST HDN728080ALE604 · A4GNW91X · 7452 GB · HDD/SATA
│
├── FAILING (3)
│   ├── Event 7 (bad block)              ▰▰▰▰▰▰▰▰▰▰      1943x
│   ├── Event 154 (hw error)             ▰▰▰▰▰▰▰▰▰▰      1646x
│   └── Controller resets                ▰▰▰▰▰▰▰▰▱▱      20x
│   │   ▲ back up data, run drive-dependencies.ps1, then replace
│
╰── B back · C clone · ? help ────────────────────────────────────── ⬤ failing ───●
```

Pip bars show how many times over threshold each indicator runs. Before disconnecting, audit dependencies:

```
╭── 🩺 windows-ops · drive-dependencies ─────────────────────────────────── Y ───●
│
├── 0 system references · safe to disconnect
│
│   💡 no system mechanism references this drive
│
╰── B back · ? help ────────────────────────────────────────────────── • safe ───●
```

Three commands, three panels, complete decision tree. Then the same loop: `crash-triage.ps1` decodes the most recent crash with a T-relative pre-crash timeline; `safe-disable-startup.ps1 -List` panel-displays every Run-key / StartupFolder entry grouped by state; `recover-clone.ps1 -Source Y:\important -Destination Z:\rescue` clones with `robocopy /R:0` so retries don't accelerate the drive's death; `boot-perf.ps1` quantifies boot duration with capacity pip bars.

The data was always there in the System log — this skill just asks for it correctly *and renders it like a proper instrument*.

### Legacy workflow notes

For non-panel verbose tracing add `-Verbose`. For machine-readable consumers add `-Json` (all scripts emit NDJSON / JSON suitable for `jq`). For piped contexts (no TTY) chrome rendering disables itself automatically and JSON-only output is appropriate.

Full command sequence:

```powershell
scripts/health-audit.ps1                            # diagnose
scripts/disk-health.ps1 -DriveLetter Y              # drill into suspect
scripts/crash-triage.ps1                            # decode most recent crash
scripts/drive-dependencies.ps1 -DriveLetter Y       # verify safe to disconnect
scripts/recover-clone.ps1 -Source Y:\ -Destination Z:\rescue  # salvage data
scripts/safe-disable-startup.ps1 -List              # audit startup state
scripts/safe-disable-startup.ps1 -Name 'Adobe*','Granola','MuseHub'  # cull bloat
Set-Service AdobeARMservice -StartupType Manual     # service-tier (admin)
# (physical) disconnect failing drive, reboot
scripts/health-audit.ps1                            # verify clean
```
