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
| 1 | Registry Run keys | User or Machine | Logon | Yes | Yes (user, HKCU StartupApproved); No (machine: the HKLM flag needs admin) |
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

For HKCU entries: set the HKCU StartupApproved flag (reversible), or delete the registry value. Neither needs admin.
For HKLM entries: set the HKLM StartupApproved flag (reversible, all users), or delete the value. Both need admin. An HKCU flag is not a per-user, no-admin alternative: nothing shows Explorer honouring it for an HKLM entry (see [The StartupApproved mechanism](#the-startupapproved-mechanism)).

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
For all-users folder: needs admin either way. Delete the `.lnk`, or set its flag in `HKLM\...\StartupApproved\StartupFolder` (Task Manager's choice). An HKCU flag is not a per-user, no-admin alternative.

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

How Task Manager's "Disable" button works. Explorer runs the Run keys and Startup folders at logon and skips any entry whose StartupApproved value of the same name says disabled. Nothing is deleted, so it is fully reversible.

### Locations: the flag lives in the entry's own hive

| Entry lives in | Its flag goes in | Admin to write? |
|----------------|------------------|-----------------|
| `HKCU\...\CurrentVersion\Run` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run` | No |
| User Startup folder (`%APPDATA%\...\Startup`) | `HKCU\...\Explorer\StartupApproved\StartupFolder` | No |
| `HKLM\...\CurrentVersion\Run` (64-bit) | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run` | **Yes** |
| `HKLM\SOFTWARE\WOW6432Node\...\Run` (32-bit) | `HKLM\...\Explorer\StartupApproved\Run32` | **Yes** |
| All-users Startup folder (`%ProgramData%\...\StartUp`) | `HKLM\...\Explorer\StartupApproved\StartupFolder` | **Yes** |

The value name is the Run value's name, or the shortcut's file name (`Tailscale.lnk`). A Run entry with no StartupApproved value runs: "no value" means enabled. A value added by hand with RegEdit or `reg.exe` gets no StartupApproved entry, and deleting a Run value leaves its StartupApproved value behind as an orphan (H. Carvey, [windowsir, 2022-07-17](https://windowsir.blogspot.com/2022/07/startupapprovedrun-pt-ii.html)).

### Value layout

The value is 12 bytes of REG_BINARY:

```
Offset  Length  Meaning
0       1       Status: low bit set = disabled, clear = enabled
1       3       Reserved (00 00 00)
4       8       FILETIME of the disable (all zero on an enable)
```

| First byte | Meaning | Where it comes from |
|------------|---------|---------------------|
| `0x02` | enabled | What Task Manager writes on re-enable, with eleven zero bytes |
| `0x03` | disabled | What Task Manager writes on disable, with a FILETIME |
| `0x01` | disabled | Seen in the wild with a FILETIME, in both hives. Which component writes `0x01` rather than `0x03` is not established. Explorer skips it (measured below) |
| `0x04`, `0x06` | enabled | `0x04` seen on `SecurityHealth`, which Explorer starts; `0x06` per H. Carvey ([windowsir, 2022-07-09](https://windowsir.blogspot.com/2022/07/does-autostart-really-mean-autostart.html)) |

Decode by the low bit, not by `0x02`/`0x03` alone: a decoder that knows only those two reports every `0x01` entry as unknown. Lansweeper's startup-status report uses the same rule (first digit 2, 4, 6 enabled; 1, 3, 5, 9 disabled). Write an enable as `02` plus eleven zero bytes, as Task Manager does. Velociraptor's `Windows.Sys.StartupItems` treats any non-zero tail as disabled, so an enable that carries a timestamp reads as disabled there.

### Writing the flag

`scripts/safe-disable-startup.ps1` picks the hive per entry, and refuses (exit 5, nothing written) when a batch includes a machine entry and the shell is not elevated. By hand:

```powershell
# Disable: 03 + FILETIME. Machine entry -> HKLM (elevated shell); user entry -> HKCU.
$disabled = [byte[]](@(0x03, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()))
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'   # entry is in HKLM\...\Run
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name 'MuseHub' -Value $disabled -Type Binary -Force

# Re-enable: 02 + eleven zero bytes.
Set-ItemProperty -Path $key -Name 'MuseHub' -Value ([byte[]](@(0x02) + (,0 * 11))) -Type Binary -Force
```

Elevate from the same account (UAC consent). Over-the-shoulder elevation as a different administrator makes `HKCU` that administrator's hive.

### Evidence, and the open question

**Measured: the HKLM flag governs HKLM entries.** On a Windows 11 22H2 workstation, one sitting of disables in the Windows startup UI wrote the flags for HKLM Run, WOW64 Run and all-users Startup-folder entries to `HKLM\...\StartupApproved\{Run,Run32,StartupFolder}`, and the flags for HKCU entries to HKCU, seconds apart. So the UI routes by hive. `Microsoft-Windows-Shell-Core/Operational` event 9707 logs each Run entry Explorer launches at logon. Over five logons it showed every HKLM entry flagged `0x01` in HKLM being skipped, while entries flagged `0x02`/`0x04`, and unflagged ones, started. Read it yourself:

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Shell-Core/Operational'; Id = 9707 } -MaxEvents 60 |
    ForEach-Object { '{0:u} {1}' -f $_.TimeCreated, $_.Properties[0].Value }
```

**Unproven: an HKCU flag for an HKLM entry.** No Microsoft document, DFIR write-up or test found shows Explorer honouring an HKCU value for a machine entry. Carvey's tests were HKCU-only, and Hexacorn ("Beyond good ol' Run key, Part 104") shows Explorer checking the list without naming the hive. Task Manager never writes such a value. An earlier version of this skill wrote all flags to HKCU on the belief that it worked, and its "disabled" HKLM entries may have kept starting. Treat it as not working.

**Settling it takes one logon.** Use three harmless HKLM Run probes (for example `conhost.exe --headless cmd.exe /d /c echo %TIME%>"%LOCALAPPDATA%\probe-X.txt"`):
- **Control:** no flag. It must start, which proves the probe works.
- **HKLM:** an HKLM `03` flag. It should be skipped.
- **HKCU:** an HKCU `03` flag. This is the question.

Sign out and back in, wait two minutes, then check the marker files and event 9707 since the last logon. Winlogon event 7001 in the System log gives the logon time. If the control starts and the HKLM probe is skipped, the HKCU probe's result answers the question. Remove all three Run values and both flags afterwards.

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

Cross-reference each entry with the StartupApproved flag in its own hive (mechanisms 1 and 4 only) to determine current enabled/disabled state.

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
