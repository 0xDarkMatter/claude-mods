<#
.SYNOPSIS
    Tier 2 recovery: image a failing block device with GNU ddrescue, supervised
    so a single fatal read does not end the run.

.DESCRIPTION
    Tier 1 (copy-tree.ps1) copies FILES and is right for a mostly-healthy drive.
    It reads in directory order, so it meets every bad sector head-on and pays
    the full device timeout each time. On a drive with DENSE damage that is
    fatal to throughput — a measured real-world case managed 118 MB in 3.6 hours
    and permanently lost 23 files.

    ddrescue reads in LBA order and SKIPS ahead on error, capturing the healthy
    majority fast and returning to damaged regions afterwards. The same drive
    then yielded 99.6% of 8 TB with zero unrecovered sectors. Use this script
    when copy-tree reports many CRC errors, or when throughput collapses.

    WHY A SUPERVISOR: under Cygwin, some hard read errors surface as EACCES
    ("Permission denied") rather than EIO, because Windows returns a misleading
    error code for the raw device. ddrescue treats that as fatal and exits — in
    testing, roughly every 9 minutes while otherwise sustaining 70 MB/s. It is
    NOT a permissions fault and elevation does not prevent it. Because the
    mapfile makes ddrescue resumable, the correct response is simply to relaunch,
    which this script does automatically until the pass completes or progress
    genuinely stops.

    WHY A WATCHDOG: exit-code logic cannot see a process that is alive but
    wedged. Progress is therefore judged by IMAGE GROWTH, not process liveness.

    PASSES
      first  ddrescue -n -r0   grab everything that reads easily, defer damage
      retry  ddrescue -d -r3 -R  revisit only the deferred regions, in reverse
      both   first, then retry

.PARAMETER Device
    Source device as ddrescue sees it. Under Cygwin these are /dev/sdX (whole
    disk) or /dev/sdXN (partition). Run with -ListDevices to map them to Windows
    disks before guessing — imaging the wrong device wastes hours.

.PARAMETER Image
    Output image file. Needs free space >= the device size. Never place it on
    the failing device.

.PARAMETER Mapfile
    ddrescue mapfile. Defaults to "<Image>.map". THIS IS THE RESUME RECORD —
    keep it with the image; deleting it forces a full re-read.

.PARAMETER Pass
    first (default) | retry | both. See DESCRIPTION.

.PARAMETER ListDevices
    Print the ddrescue-device -> Windows-volume mapping and exit. Always do this
    first.

.PARAMETER MaxAttempts
    Relaunch budget per pass. Default 2000 (a backstop, not a target).

.PARAMETER StallMinutes
    Watchdog threshold: kill and relaunch a child whose image has not grown in
    this many minutes. Default 25.

.PARAMETER DdrescuePath
    Explicit ddrescue.exe path. Auto-discovered from PATH and common Cygwin
    install roots when omitted.

.PARAMETER Json
    Emit a single JSON result object on stdout instead of the panel.

.EXAMPLE
    scripts/rescue-image.ps1 -ListDevices
    Map ddrescue device names to Windows volumes. Do this before imaging.

.EXAMPLE
    scripts/rescue-image.ps1 -Device /dev/sdX1 -Image R:\rescue.img
    First pass: capture everything readable, defer damaged regions.

.EXAMPLE
    scripts/rescue-image.ps1 -Device /dev/sdX1 -Image R:\rescue.img -Pass retry
    Second pass: retry only the regions the first pass deferred.

.NOTES
    REQUIRES ELEVATION for raw device access; without it ddrescue reports
    "Permission denied" on open (distinct from the mid-read EACCES above).

    REQUIRES GNU ddrescue. On Windows the practical options are Cygwin
    (setup-x86_64.exe -q -P ddrescue) or a Linux live environment. Note that a
    live USB costs a power cycle, which a marginal drive may not survive — a
    drive that has already failed once may never spin up again. Prefer the
    in-session route while the device is readable.

    NEVER run chkdsk /f against a failing drive. Image first, repair the image.

    Exit codes:
      0  pass complete
      1  error
      2  usage
      3  device or output path not found
      4  destination free space < device size
      5  ddrescue not found, or not elevated
      7  stopped: no progress across repeated attempts
#>
[CmdletBinding()]
param(
    [string]$Device,
    [string]$Image,
    [string]$Mapfile,
    [ValidateSet('first','retry','both')][string]$Pass = 'first',
    [switch]$ListDevices,
    [ValidateRange(1,10000)][int]$MaxAttempts = 2000,
    [ValidateRange(1,1440)][int]$StallMinutes = 25,
    [string]$DdrescuePath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

# ── locate ddrescue ──────────────────────────────────────────────────────────
function Find-Ddrescue {
    param([string]$Explicit)
    if ($Explicit) { if (Test-Path $Explicit) { return $Explicit }; return $null }
    $cmd = Get-Command ddrescue.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Common Cygwin roots. Deliberately not machine-specific: probe every fixed
    # drive rather than assuming an install location.
    foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        foreach ($sub in 'cygwin64\bin\ddrescue.exe','cygwin\bin\ddrescue.exe','Tools\cygwin64\bin\ddrescue.exe') {
            $p = Join-Path $d.RootDirectory.FullName $sub
            if (Test-Path $p) { return $p }
        }
    }
    return $null
}

$dd = Find-Ddrescue -Explicit $DdrescuePath
if (-not $dd) {
    Write-Log -Level FAIL -Message "GNU ddrescue not found. Install via Cygwin (setup-x86_64.exe -q -P ddrescue) or pass -DdrescuePath."
    exit $script:EXIT_PRECONDITION
}
$ddDir  = Split-Path $dd -Parent
$ddlog  = Join-Path $ddDir 'ddrescuelog.exe'
$cygBash = Join-Path $ddDir 'bash.exe'

# ── -ListDevices: map ddrescue names to Windows volumes ──────────────────────
# Cygwin exposes /proc/partitions with a win-mounts column; that mapping is the
# only safe way to pick a device. Guessing sdX from disk numbers is how people
# image the wrong drive.
if ($ListDevices) {
    if (Test-Path $cygBash) {
        Write-Log -Level INFO -Message "ddrescue device -> Windows volume mapping (from Cygwin /proc/partitions):"
        & $cygBash -c "cat /proc/partitions" 2>&1 | Write-Data
    } else {
        Write-Log -Level WARN -Message "Cygwin bash not found beside ddrescue; falling back to the Windows view only."
    }
    # Get-Disk needs the Storage module and can fail on locked-down hosts; the
    # Cygwin mapping above is the load-bearing half, so a failure here must not
    # turn an informational listing into a non-zero exit.
    Write-Log -Level INFO -Message "Windows disks (cross-check by size and serial):"
    try {
        Get-DiskMap | Select-Object Number, Model, SizeGB, DriveLetters, SerialNumber, HealthStatus | Write-Data
    } catch {
        Write-Log -Level WARN -Message "Windows disk enumeration unavailable: $($_.Exception.Message.Split([char]10)[0])"
    }
    exit $script:EXIT_OK
}

# ── validate ─────────────────────────────────────────────────────────────────
if (-not $Device -or -not $Image) {
    Write-Log -Level FAIL -Message "-Device and -Image are required (run -ListDevices first to map devices)"
    exit $script:EXIT_USAGE
}
if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log -Level FAIL -Message "raw device access requires an elevated shell"
    exit $script:EXIT_PRECONDITION
}
if (-not $Mapfile) { $Mapfile = "$Image.map" }

$imageDir = Split-Path $Image -Parent
if ($imageDir -and -not (Test-Path $imageDir)) { New-Item -ItemType Directory $imageDir -Force | Out-Null }

# Capacity preflight against the destination volume.
$destQual = Split-Path $Image -Qualifier
if ($destQual) {
    $free = (New-Object System.IO.DriveInfo "$destQual\").AvailableFreeSpace
    $existing = if (Test-Path $Image) { (Get-Item $Image).Length } else { 0 }
    Write-Log -Level INFO -Message "destination free: $([math]::Round($free/1GB,1)) GB; image so far: $([math]::Round($existing/1GB,1)) GB"
}

function Get-ImageBytes { if (Test-Path $Image) { (Get-Item $Image).Length } else { 0 } }

function Invoke-DdrescuePass {
    param([string]$Flavour)   # 'first' | 'retry'
    $args = if ($Flavour -eq 'first') { @('-n','-r0') } else { @('-d','-r3','-R') }
    $attempt = 0; $stalls = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        $before = Get-ImageBytes
        # Start-Process + polling, NOT `& cmd 2>&1`: capturing a child's stream
        # can block indefinitely on a handle after the child exits, which turns
        # the supervisor into the outage it exists to prevent.
        $p = Start-Process -FilePath $dd -ArgumentList (@($args) + @($Device, $Image, $Mapfile)) `
                           -PassThru -NoNewWindow -RedirectStandardError "$Image.stderr.log"
        $lastBytes = $before; $lastMove = Get-Date
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 30
            $now = Get-ImageBytes
            if ($now -ne $lastBytes) { $lastBytes = $now; $lastMove = Get-Date }
            elseif (((Get-Date) - $lastMove).TotalMinutes -ge $StallMinutes) {
                Write-Log -Level WARN -Message "watchdog: image static for $StallMinutes min — relaunching"
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
                break
            }
        }
        try { $p.WaitForExit(30000) | Out-Null } catch {}
        $rc = try { $p.ExitCode } catch { -1 }
        $gain = (Get-ImageBytes) - $before
        Write-Log -Level INFO -Message "attempt $attempt ($Flavour): exit=$rc gained=$([math]::Round($gain/1MB,1)) MB"
        if ($rc -eq 0) { return $true }
        # A fatal Cygwin EACCES is expected and retryable; only give up when
        # several consecutive attempts recover nothing.
        if ($gain -lt 1MB) { $stalls++ } else { $stalls = 0 }
        if ($stalls -ge 5) { return $false }
        Start-Sleep -Seconds 3
    }
    return $false
}

$start = Get-Date
$okFirst = $true; $okRetry = $true
if ($Pass -in 'first','both') { $okFirst = Invoke-DdrescuePass -Flavour 'first' }
if ($Pass -in 'retry','both') { $okRetry = Invoke-DdrescuePass -Flavour 'retry' }
$elapsed = ((Get-Date) - $start).TotalMinutes

# ── report ───────────────────────────────────────────────────────────────────
$stats = if (Test-Path $ddlog) { (& $ddlog -t $Mapfile 2>&1 | Out-String).Trim() } else { '' }
$imageGB = [math]::Round((Get-ImageBytes)/1GB,2)

if ($Json) {
    [PSCustomObject]@{
        schema   = 'claude-mods.windows-ops.rescue-image/v1'
        device   = $Device; image = $Image; mapfile = $Mapfile; pass = $Pass
        imageGB  = $imageGB; elapsedMin = [math]::Round($elapsed,1)
        complete = ($okFirst -and $okRetry)
        mapSummary = $stats
    } | ConvertTo-Json -Depth 4 | Write-Data
} else {
    Write-Section "rescue-image ($Pass)"
    Write-Data "image      : $imageGB GB"
    Write-Data "elapsedMin : $([math]::Round($elapsed,1))"
    Write-Data "mapfile    : $Mapfile"
    if ($stats) { Write-Data ''; Write-Data $stats }
}

if (-not ($okFirst -and $okRetry)) { exit $script:EXIT_UNAVAILABLE }
exit $script:EXIT_OK
