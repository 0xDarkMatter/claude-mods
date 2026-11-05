# Windows Startup Mechanisms

Load this when auditing what auto-launches on a Windows system at boot or login. Windows has **five distinct mechanisms** plus a few edge cases. Task Manager's Startup tab shows only two of them. A proper startup audit must walk all five.

## Contents

1. [The five mechanisms](#the-five-mechanisms) — overview
2. [Registry Run keys](#1-registry-run-keys) — the most common
3. [Services](#2-services) — auto-start at boot
4. [Scheduled Tasks](#3-scheduled-tasks-at-logon) — at logon, at startup, at event
5. [Startup folder shortcuts](#4-startup-folder-shortcuts) — `.lnk` files
6. [Group Policy startup scripts](#5-group-policy-startup-scripts) — domain / corp scenario
7. [The StartupApproved mechanism](#the-startupapproved-mechanism) — how Task Manager disables things
8. [Edge cases](#edge-cases) — WMI consumers, ActiveSetup, AppInit_DLLs, RunOnce
9. [Full audit query patterns](#full-audit-query-patterns)
10. [Why disabling-by-mechanism matters](#why-disabling-by-mechanism-matters) — apps register in multiple places

## The five mechanisms

| # | Mechanism | Scope | Trigger | Visible in Task Manager? | Disable without admin? |
|---|-----------|-------|---------|--------------------------|------------------------|
| 1 | Registry Run keys | User or Machine | Logon | Yes | Yes (StartupApproved trick) |
| 2 | Services | Machine | Boot | No | No (admin required) |
| 3 | Scheduled Tasks at logon/boot | Variable | Logon or boot or event | No (mostly) | Yes (for user tasks); No for system |
| 4 | Startup folder shortcuts | User or All Users | Logon | Yes (user-folder ones) | Yes (user); No (all-users without admin) |
| 5 | Group Policy startup scripts | Machine | Boot | No | No (admin/GPO required) |

## 1. Registry Run keys

The classic startup mechanism. Four registry locations Windows checks at logon.

| Path | Scope | Architecture |
|------|-------|--------------|
| `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` | Current user | Both 32-bit and 64-bit |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` | All users, machine-wide | 64-bit (on 64-bit Windows) |
| `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run` | All users, machine-wide | 32-bit redirect |
| `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce` | Current user | Runs once then deletes itself |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce` | All users | Runs once then deletes itself |
| `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce` | All users | 32-bit, runs once |

Each is a registry key containing a flat list of named string values. Each value's name is the entry's "friendly name"; its data is the command line to execute:

```
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
├── Slack (REG_SZ) = "C:\Users\X\AppData\Local\slack\slack.exe" --process-start-args --startup
├── Docker Desktop (REG_SZ) = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
└── BingWallpaperApp (REG_SZ) = "C:\Users\X\AppData\Local\Microsoft\BingWallpaperApp\BingWallpaperApp.exe"
```

### Enumeration

```powershell
$paths = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($p in $paths) {
    if (Test-Path $p) {
        (Get-ItemProperty $p).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object { [PSCustomObject]@{ Path=$p; Name=$_.Name; Command=$_.Value } }
    }
}
```

### Disable

For HKCU entries: delete the registry value (user has permission to write their own hive).
For HKLM entries: either use the StartupApproved mechanism (no admin needed, works for the current user only) or delete the value (needs admin, affects all users).

## 2. Services

Auto-starting services run before any user logs in. They contribute to "boot time to login screen" rather than "login to usable desktop."

### Start types

| Type | Meaning | Boot impact |
|------|---------|-------------|
| `Automatic` | Starts at boot, before logon | High — directly extends boot time |
| `Automatic (Delayed Start)` | Starts ~2 minutes after boot, low priority | Low — runs after login |
| `Manual` | Only starts when something requests it | None at boot |
| `Disabled` | Can't be started at all | None |

### Enumeration

```powershell
# Auto-start services currently running
Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' } |
    Select-Object Name, DisplayName, StartType

# Get the binary path (Win32_Service) — useful for identifying bloat
Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State='Running'" |
    Select-Object Name, DisplayName, PathName
```

### Disable

Always requires admin. For workstation tuning, prefer `Manual` over `Disabled`:

```powershell
# Set to manual (won't auto-start, but can run on demand)
Set-Service <name> -StartupType Manual
Stop-Service <name> -Force  # stop the currently running instance

# Fully disable (NEVER runs)
Set-Service <name> -StartupType Disabled
Stop-Service <name> -Force
```

`Manual` is reversible by any process requesting the service. `Disabled` requires another `Set-Service` to re-enable.

### Vendor patterns

Common auto-start services that ship with consumer apps and rarely need to be Automatic:

| Service | Application | Typical recommendation |
|---------|-------------|------------------------|
| `AdobeARMservice` | Adobe Acrobat | Manual — Acrobat starts it on demand for update checks |
| `AdobeUpdateService` | Adobe Creative Cloud | Manual |
| `ClickToRunSvc` | Microsoft Office | Disable if Office is rarely used; otherwise leave |
| `Bonjour Service` | Apple iTunes / Adobe Bridge | Manual unless using mDNS |
| `LGHUBUpdaterService` | Logitech G Hub | Manual |
| `DSAService` / `DSAUpdateService` | Intel Driver Support Assistant | Manual or disable |
| `WMPNetworkSvc` | Windows Media Player | Disable (legacy) |

Note: don't disable security-related services (`ekrn`, `SecurityHealthService`, `WinDefend`, `BFE`). Antivirus needing early loading is by design.

## 3. Scheduled Tasks at logon

Task Scheduler can trigger tasks at:
- System boot
- User logon (specific user or any user)
- Specific event (e.g., user idle for N minutes)
- Specific time / schedule

The "AtLogon" and "AtStartup" triggers are the startup-relevant ones.

### Enumeration

```powershell
# All tasks with logon trigger
Get-ScheduledTask | Where-Object { $_.Triggers.CimClass.CimClassName -like '*LogonTrigger*' } |
    Select-Object TaskName, TaskPath, State, @{N='Action';E={$_.Actions.Execute}}

# All tasks with boot trigger
Get-ScheduledTask | Where-Object { $_.Triggers.CimClass.CimClassName -like '*BootTrigger*' } |
    Select-Object TaskName, TaskPath, State, @{N='Action';E={$_.Actions.Execute}}

# Both
Get-ScheduledTask | Where-Object {
    $_.Triggers.CimClass.CimClassName -match 'Logon|Boot'
} | Select-Object TaskName, State, @{N='Trigger';E={$_.Triggers.CimClass.CimClassName -join ','}},
    @{N='Action';E={$_.Actions.Execute}}
```

### Why they're easy to miss

- Don't appear in Task Manager Startup tab
- Often installed by third-party apps without telling the user (Adobe, Google Update, Microsoft Edge, Spotify, Syncthing)
- Frequently in the `\Microsoft\...` task path which most audit tools skip

Real-world example from this morning's session: **Syncthing's "Start Syncthing at logon" task** was the launch mechanism. Nothing in Run keys, nothing in Startup folder, nothing in services — only in Task Scheduler.

### Disable

```powershell
Disable-ScheduledTask -TaskName 'task name' -TaskPath '\optional\subpath\'

# Fully remove
Unregister-ScheduledTask -TaskName 'task name' -Confirm:$false
```

User-scope tasks (under `\Users\` or stored in user's profile) can be disabled by the user. System-scope tasks need admin.

## 4. Startup folder shortcuts

The least sophisticated mechanism: drop a `.lnk` file in a magic folder, Windows launches it at logon.

| Folder | Scope |
|--------|-------|
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` | Current user |
| `%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\StartUp` | All users (note capital U) |

These are file system locations, not registry entries. Items here also appear in Task Manager Startup tab.

### Enumeration

```powershell
$startupDirs = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp"
)
$shell = New-Object -ComObject WScript.Shell
foreach ($d in $startupDirs) {
    if (Test-Path $d) {
        Get-ChildItem $d -Filter *.lnk | ForEach-Object {
            $sc = $shell.CreateShortcut($_.FullName)
            [PSCustomObject]@{
                Folder = $d
                Shortcut = $_.Name
                Target = $sc.TargetPath
                Arguments = $sc.Arguments
                WorkingDir = $sc.WorkingDirectory
            }
        }
    }
}
```

### Disable

For user folder: delete the `.lnk` file (user has write permission to their own folder).
For all-users folder: needs admin to modify; OR use StartupApproved mechanism via `HKCU\...\StartupApproved\StartupFolder` to disable for current user only.

## 5. Group Policy startup scripts

Domain-joined or locally-configured policy scripts that run at boot (machine) or logon (user). On consumer workstations these are usually empty; on corporate machines they're frequently used for drive mappings, software deployment, registry configuration.

| Path | Scope |
|------|-------|
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Startup` | Machine boot scripts |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Shutdown` | Machine shutdown scripts |
| `HKCU\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Logon` | User logon scripts |
| `HKCU\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Logoff` | User logoff scripts |

Plus the filesystem locations:
- `C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\`
- `C:\Windows\System32\GroupPolicy\User\Scripts\Logon\`

### Inspection

```powershell
# Effective policy applied to this machine
gpresult /h gpreport.html
Start-Process gpreport.html
```

For audit purposes the registry paths and filesystem locations are usually the fastest check. On a consumer machine, an unexpected non-empty result here is a strong "what is this and who put it here" signal.

## The StartupApproved mechanism

How Task Manager's "Disable" button works — and why a non-admin user can disable HKLM entries for themselves.

### Locations

| Path | Disables entries in |
|------|---------------------|
| `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run` | HKCU\...\Run AND HKLM\...\Run (64-bit) |
| `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32` | HKLM\...\WOW6432Node\Run (32-bit) |
| `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder` | Startup folder shortcuts |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\...` | Machine-wide disables (admin only) |

The value name matches the original Run key entry name. The value is 12 bytes binary:

```
Offset  Length  Meaning
0       1       Status: 0x02 = enabled, 0x03 = disabled
1       3       Reserved (00 00 00)
4       8       FILETIME timestamp of last enable/disable
```

### Writing the disable marker

```powershell
$timestamp = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
$disabledValue = [byte[]]@(0x03, 0x00, 0x00, 0x00) + $timestamp

# Ensure the StartupApproved\Run key exists
$key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }

# Write disable marker (matches the value name in the original Run key)
Set-ItemProperty -Path $key -Name 'Slack' -Value $disabledValue -Type Binary -Force
```

Re-enable: change first byte to `0x02`:

```powershell
$enabledValue = [byte[]]@(0x02, 0x00, 0x00, 0x00) + $timestamp
Set-ItemProperty -Path $key -Name 'Slack' -Value $enabledValue -Type Binary -Force
```

### Why this works without admin

The StartupApproved key under HKCU is writable by the current user. Windows' Explorer reads both the Run keys and the StartupApproved overlay at logon — if the StartupApproved entry says `0x03` for an entry name, that entry is skipped, regardless of which Run key (HKCU or HKLM) it lives in.

This means: a non-admin user can disable any HKLM startup entry for their own session, even ones an administrator installed for all users. Useful for cleaning up vendor bloat without going through "Run as Administrator."

## Edge cases

Less common but worth knowing about:

### WMI permanent event consumers

```powershell
Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer
Get-CimInstance -Namespace root\subscription -ClassName __EventFilter
Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding
```

Used legitimately by some monitoring tools, infamously by malware for persistence. A consumer machine should usually have zero or one (Windows Defender's). Unexpected entries warrant investigation.

### ActiveSetup

`HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components` — designed for per-user setup-on-first-logon. Rarely used today.

### AppInit_DLLs

`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows\AppInit_DLLs` — DLLs injected into every user32-loading process. Deprecated since Windows 8, blocked by default when Secure Boot is enabled. Empty on modern workstations; a non-empty value is suspicious.

### Image File Execution Options (IFEO) "Debugger"

`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\<exe>` with a `Debugger` value will replace `<exe>` with the debugger command whenever Windows tries to launch it. Used legitimately for debugging; used by malware to redirect execution. Audit:

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' |
    ForEach-Object {
        $debugger = (Get-ItemProperty $_.PSPath -Name Debugger -ErrorAction SilentlyContinue).Debugger
        if ($debugger) {
            [PSCustomObject]@{ Image = $_.PSChildName; Debugger = $debugger }
        }
    }
```

### Shell extensions / context menu handlers

Not strictly "startup" but they load into Explorer.exe at logon and can drag boot performance. Audited via `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers` and similar paths. NirSoft's `ShellExView` is the canonical tool.

### Print providers

Print provider DLLs load into spoolsv at boot. A failing or slow provider can delay print spooler initialization which (because spoolsv is a delayed-start service in some configs) can ripple into other delayed-start services. Rare cause but real.

## Full audit query patterns

No bundled script runs all of these: `scripts/health-audit.ps1` counts the five mechanisms in its startup section, and `scripts/safe-disable-startup.ps1 -List` lists the Run-key and Startup-folder entries. For the full picture, run the queries by hand:

```powershell
# Mechanism 1: Run keys (all 6 paths)
$runPaths = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
)

# Mechanism 2: Services (Auto, Auto-Delayed)
Get-Service | Where-Object { $_.StartType -in @('Automatic','AutomaticDelayedStart') }

# Mechanism 3: Tasks (Logon or Boot trigger)
Get-ScheduledTask | Where-Object {
    $_.Triggers.CimClass.CimClassName -match 'Logon|Boot'
}

# Mechanism 4: Startup folders (user + all-users)
@(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp"
)

# Mechanism 5: Group Policy scripts
@(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Startup',
    'HKCU:\SOFTWARE\Policies\Microsoft\Windows\System\Scripts\Logon'
)
```

Cross-reference each entry with the StartupApproved overlay (mechanisms 1 and 4 only) to determine current enabled/disabled state.

## Why disabling-by-mechanism matters

Vendors don't ship a single auto-launch entry. The common pattern: **one app installs three or four separate startup hooks**, and disabling one leaves the others firing. Example from a real audit (Adobe ecosystem):

| Mechanism | Entry |
|-----------|-------|
| Run (HKLM-WOW) | "Adobe Creative Cloud" |
| Run (HKLM-WOW) | "Adobe CCXProcess" |
| Run (HKLM) | "AdobeAAMUpdater-1.0" |
| Run (HKCU) | "Adobe Acrobat Synchronizer" |
| Service (Auto) | `AdobeARMservice` (Acrobat update service) |
| Service (Auto) | `AdobeUpdateService` (Creative Cloud update service) |

To fully stop Adobe auto-launching, all six need to be addressed. Disabling only the visible Task Manager startup entries leaves the two services running unattended.

**Audit recipe**: search across mechanisms for the vendor name to find every hook they've installed:

```powershell
$vendor = 'Adobe'

# Run keys
foreach ($p in $runPaths) {
    (Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties |
        Where-Object { $_.Value -like "*$vendor*" -or $_.Name -like "*$vendor*" }
}

# Services
Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*$vendor*" -or $_.DisplayName -like "*$vendor*" }

# Tasks
Get-ScheduledTask | Where-Object { $_.Actions.Execute -like "*$vendor*" }
```

Run it once per vendor you suspect; the usual offenders are Adobe, Docker, Slack, NVIDIA, Microsoft Office and Intel.
