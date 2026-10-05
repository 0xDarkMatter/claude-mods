# Manual Queries and Decoding Tables

The queries, event catalogues and decoding tables behind SKILL.md's storage, boot, crash and event-log sections. The scripts automate all of this; use these when running a query by hand or reading raw output.

## Contents

- [Storage](#storage)
  - [Disk error events](#disk-error-events)
  - [Storage controller resets](#storage-controller-resets)
  - [Disk → drive letter mapping](#disk--drive-letter-mapping)
  - [SMART reliability counters](#smart-reliability-counters)
- [Boot](#boot)
  - [The StartupApproved trick (disable HKLM entries without admin)](#the-startupapproved-trick-disable-hklm-entries-without-admin)
  - [Boot duration measurement](#boot-duration-measurement)
- [Crash](#crash)
  - [Event 41 (Kernel-Power) decoding](#event-41-kernel-power-decoding)
  - [Pre-crash timeline correlation](#pre-crash-timeline-correlation)
  - [Dump configuration audit](#dump-configuration-audit)
- [Event Log Query Patterns](#event-log-query-patterns)

## Storage

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

## Boot

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

## Crash

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

There is no bundled event-search wrapper: build the query from the keys above (time window, provider, ID, several logs at once). `scripts/crash-triage.ps1` and `scripts/disk-health.ps1` already run the common crash and storage queries.
