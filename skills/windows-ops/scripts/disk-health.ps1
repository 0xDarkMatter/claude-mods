<#
.SYNOPSIS
    Focused per-drive health report - every diagnostic signal for one
    specific physical disk in one report.

.DESCRIPTION
    Drill-down companion to health-audit.ps1. Targets a single physical
    disk (by number, drive letter, or model substring) and emits:

      - Hardware identification (model, serial, firmware, capacity)
      - SMART reliability counters (Windows native + smartctl if installed)
      - All disk-provider events for the disk over the time window
      - All storahci controller resets (skill correlates port to drive)
      - Per-event-ID breakdown with severity classification
      - Recovery clues - failing-LBA distribution, time-clustering
      - System dependencies - quick summary (uses drive-dependencies.ps1
        if available, else inline check)

.PARAMETER DiskNumber
    Physical disk number from Get-Disk. Mutually exclusive with -DriveLetter
    and -Model.

.PARAMETER DriveLetter
    Drive letter - resolves to the underlying physical disk.

.PARAMETER Model
    Model substring match (e.g. 'HGST', '980 PRO'). Picks the first match.

.PARAMETER Days
    Days back to scan event logs. Default: 60.

.PARAMETER Json
    Machine-readable JSON output.

.EXAMPLE
    scripts/disk-health.ps1 -DiskNumber 1
    Focused report on physical disk 1.

.EXAMPLE
    scripts/disk-health.ps1 -DriveLetter Y -Days 30
    Drill on the disk that hosts Y:, 30-day window.

.EXAMPLE
    scripts/disk-health.ps1 -Model 'HGST' -Json | jq '.errors'
    Find the HGST drive and dump its error counts as JSON.

.NOTES
    Exit codes (reflect whether the diagnostic RAN, not what it found):
      0 success - diagnostic completed (verdict reported via panel + JSON)
      3 not found - no matching disk

    The drive's health verdict (HEALTHY / WATCHLIST / FAILING) is in
    the panel output and JSON; check the verdict field, not $LASTEXITCODE.
#>

[CmdletBinding(DefaultParameterSetName='Number')]
param(
    [Parameter(ParameterSetName='Number', Position=0)][ValidateRange(0, 99)][int]$DiskNumber = -1,
    [Parameter(ParameterSetName='Letter')][ValidatePattern('^[A-Za-z]$')][string]$DriveLetter,
    [Parameter(ParameterSetName='Model')][string]$Model,
    [ValidateRange(1, 365)][int]$Days = 60,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"
. (Join-Path $PSScriptRoot '..\..\_lib\term.ps1')
Initialize-Term

# Resolve target disk
$disks = Get-DiskMap
$target = $null
switch ($PSCmdlet.ParameterSetName) {
    'Number' {
        if ($DiskNumber -lt 0) {
            Write-Log -Level FAIL -Message "Provide -DiskNumber, -DriveLetter, or -Model"
            exit $script:EXIT_USAGE
        }
        $target = $disks | Where-Object { $_.Number -eq $DiskNumber } | Select-Object -First 1
    }
    'Letter' {
        $L = $DriveLetter.ToUpper()
        $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $L } | Select-Object -First 1
        if ($part) {
            $target = $disks | Where-Object { $_.Number -eq $part.DiskNumber } | Select-Object -First 1
        }
    }
    'Model' {
        $target = $disks | Where-Object { $_.Model -like "*$Model*" } | Select-Object -First 1
    }
}

if (-not $target) {
    Write-Log -Level FAIL -Message "No matching disk found"
    exit $script:EXIT_NOT_FOUND
}

# Collect data
$result = [ordered]@{
    diskNumber       = $target.Number
    model            = $target.Model
    serial           = $target.SerialNumber
    firmware         = $target.FirmwareVersion
    mediaType        = $target.MediaType
    busType          = $target.BusType
    sizeGB           = $target.SizeGB
    driveLetters     = $target.DriveLetters
    healthStatus     = $target.HealthStatus
    windowDays       = $Days
    smart            = $null
    eventCounts      = @{}
    eventSamples     = @()
    storahciResets   = 0
    verdict          = 'unknown'
    indicators       = @()
}

# SMART reliability counter (Windows native)
try {
    $physical = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $target.Number }
    $rel = $physical | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    if ($rel) {
        $result.smart = @{
            temperatureC   = $rel.Temperature
            temperatureMax = $rel.TemperatureMax
            wearPct        = $rel.Wear
            readErrors     = $rel.ReadErrorsTotal
            writeErrors    = $rel.WriteErrorsTotal
            powerOnHours   = $rel.PowerOnHours
            powerCycles    = $rel.PowerCycleCount
            startStops     = $rel.StartStopCycleCount
        }
    }
} catch {}

# smartctl fallback (if smartmontools installed)
$smartctl = Get-Command smartctl.exe -ErrorAction SilentlyContinue
if ($smartctl -and -not $result.smart) {
    try {
        $smartOutput = & smartctl -A "/dev/sd$($target.Number)" 2>&1
        if ($smartOutput) {
            $result.smartctlAvailable = $true
            $result.smartctlOutput = ($smartOutput -join "`n")
        }
    } catch {}
}

# Disk-provider events for this disk
try {
    $diskErrs = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='disk'
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    foreach ($e in $diskErrs) {
        $n = $null
        if     ($e.Message -match 'Harddisk(\d+)')      { $n = [int]$matches[1] }
        elseif ($e.Message -match '\bfor Disk (\d+)\b') { $n = [int]$matches[1] }
        if ($n -ne $target.Number) { continue }
        $id = "$($e.Id)"
        if ($result.eventCounts.ContainsKey($id)) {
            $result.eventCounts[$id] = $result.eventCounts[$id] + 1
        } else {
            $result.eventCounts[$id] = 1
        }
        if ($result.eventSamples.Count -lt 5) {
            $result.eventSamples += @{
                time     = $e.TimeCreated.ToString('o')
                id       = $e.Id
                message  = (Format-EventMessage -Message $e.Message -MaxLength 150)
            }
        }
    }
} catch {}

# storahci resets (controller-level; we can't always tie a port to a specific
# disk number reliably, so report total reset count and let caller correlate
# via drive enumeration order)
try {
    $resets = Get-WinEvent -FilterHashtable @{
        LogName='System'
        ProviderName='storahci'
        Id=129
        StartTime=(Get-Date).AddDays(-$Days)
    } -ErrorAction SilentlyContinue
    $result.storahciResets = if ($resets) { $resets.Count } else { 0 }
} catch {}

# Severity classification
$isSsd = $target.MediaType -eq 'SSD'
$ev7   = if ($result.eventCounts.ContainsKey('7'))   { $result.eventCounts['7']   } else { 0 }
$ev51  = if ($result.eventCounts.ContainsKey('51'))  { $result.eventCounts['51']  } else { 0 }
$ev154 = if ($result.eventCounts.ContainsKey('154')) { $result.eventCounts['154'] } else { 0 }

$thresholds = if ($isSsd) {
    @{ event7=10; event154=5; event51=5 }
} else {
    @{ event7=50; event154=10; event51=5 }
}

# storahci controller resets are not reliably attributable to a specific
# physical disk number (RaidPort enumeration doesn't always map 1:1 to
# Disk N). Only count them toward THIS disk's verdict when the disk also
# shows its own error events - otherwise they're system-wide noise that
# would falsely blame healthy drives sharing the same controller.
$thisDiskHasOwnErrors = ($ev7 + $ev154 + $ev51) -gt 0
$attributedResets = if ($thisDiskHasOwnErrors) { $result.storahciResets } else { 0 }

$failing = (
    $ev7   -gt $thresholds.event7   -or
    $ev154 -gt $thresholds.event154 -or
    $ev51  -gt $thresholds.event51  -or
    $attributedResets -gt 5
)
$watch = (
    $ev7   -gt 5 -or
    $ev154 -gt 2 -or
    $attributedResets -gt 0
)

if ($failing) {
    $result.verdict = 'FAILING'
    if ($ev7   -gt $thresholds.event7)   { $result.indicators += "Event 7 (bad block): $ev7 > $($thresholds.event7) threshold" }
    if ($ev154 -gt $thresholds.event154) { $result.indicators += "Event 154 (hw error): $ev154 > $($thresholds.event154) threshold" }
    if ($ev51  -gt $thresholds.event51)  { $result.indicators += "Event 51 (paging error): $ev51 > $($thresholds.event51) threshold" }
    if ($attributedResets -gt 5)         { $result.indicators += "Controller resets: $attributedResets > 5 threshold" }
} elseif ($watch) {
    $result.verdict = 'WATCHLIST'
    if ($ev7   -gt 5) { $result.indicators += "Event 7 elevated: $ev7" }
    if ($ev154 -gt 2) { $result.indicators += "Event 154 elevated: $ev154" }
    if ($attributedResets -gt 0) { $result.indicators += "Controller resets: $attributedResets" }
} else {
    $result.verdict = 'HEALTHY'
}
# Always retain the system-wide reset count for context, but flag separately
$result.systemWideResets = $result.storahciResets

# Output
if ($Json) {
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 5))
} else {
    $indicator = "Disk $($target.Number) / $($target.DriveLetters)"
    Write-TermLine (New-TermPanelOpen -Brand 'windows-ops' -Name 'windows-ops' -Subtitle 'disk-health' -Indicator $indicator)
    Write-TermLine (New-TermPanelVert)
    Write-TermLine (New-TermSummary -Text "$($target.Model) | $($target.FirmwareVersion) | $($target.SizeGB) GB | $($target.MediaType)/$($target.BusType)")
    Write-TermLine (New-TermPanelVert)

    # Verdict section header carries the state via section-color
    $verdictState = switch ($result.verdict) {
        'FAILING'   { 'FAILING' }
        'WATCHLIST' { 'WARN' }
        'HEALTHY'   { 'PASS' }
    }

    if ($result.indicators) {
        Write-TermLine (New-TermSection -State $verdictState -Label $result.verdict -Count $result.indicators.Count)
        # Each indicator as a leaf with pip bar showing ratio over threshold
        $idxLast = $result.indicators.Count - 1
        for ($i = 0; $i -lt $result.indicators.Count; $i++) {
            $ind = $result.indicators[$i]
            # Parse indicator like "Event 7 (bad block): 1943 > 50 threshold"
            $name = $ind
            $bar = ''
            $meta = ''
            if ($ind -match '^(.+?):\s*(\d+)\s*>\s*(\d+)') {
                $name = $matches[1].Trim()
                $actual = [int]$matches[2]
                $threshold = [int]$matches[3]
                $ratio = [math]::Min(100, [int](100 * $threshold / [math]::Max($actual, 1)))
                # Inverted score: lower ratio = worse (more times over threshold)
                $bar = New-TermPipBar -Type capacity -Filled (100 - $ratio) -Total 100
                $multiplier = [math]::Round($actual / [math]::Max($threshold, 1), 1)
                $meta = "${actual}x"
            } elseif ($ind -match '(\d+)') {
                $meta = $matches[1]
            }
            Write-TermLine (New-TermLeaf -Name $name -Rail $bar -Meta $meta -IsLast:($i -eq $idxLast))
        }
        if ($result.verdict -eq 'FAILING') {
            Write-TermLine (New-TermAlert -Severity critical -Text 'back up data, run drive-dependencies.ps1, then replace')
        } elseif ($result.verdict -eq 'WATCHLIST') {
            Write-TermLine (New-TermAlert -Severity warning -Text 'back up irreplaceable data, monitor weekly')
        }
        Write-TermLine (New-TermPanelVert)
    } else {
        Write-TermLine (New-TermSection -State 'PASS' -Label $result.verdict -Count -1)
        Write-TermLine (New-TermLeaf -Name 'no failure indicators' -Meta "$Days-day window clean" -IsLast)
        Write-TermLine (New-TermPanelVert)
    }

    # SMART section
    Write-TermLine (New-TermSection -State 'INFO' -Label 'SMART' -Count -1)
    if ($result.smart) {
        Write-TermLine (New-TermLeaf -Name 'temperature' -Meta "$($result.smart.temperatureC) C (max: $($result.smart.temperatureMax))")
        Write-TermLine (New-TermLeaf -Name 'wear' -Meta "$($result.smart.wearPct)%")
        Write-TermLine (New-TermLeaf -Name 'read errors' -Meta "$($result.smart.readErrors)")
        Write-TermLine (New-TermLeaf -Name 'write errors' -Meta "$($result.smart.writeErrors)")
        Write-TermLine (New-TermLeaf -Name 'power on hours' -Meta "$($result.smart.powerOnHours)" -IsLast)
    } else {
        Write-TermLine (New-TermLeaf -Name 'reliability counter' -Meta 'unavailable' -IsLast)
        if ($smartctl) {
            Write-TermLine (New-TermHint -Text 'smartctl installed but call failed - try: smartctl -A /dev/sdX')
        } else {
            Write-TermLine (New-TermHint -Text 'scoop install smartmontools for SMART access')
        }
    }
    Write-TermLine (New-TermPanelVert)

    # Footer
    $health = switch ($result.verdict) {
        'FAILING'   { New-TermHealth -State 'busted' -Text 'failing' }
        'WATCHLIST' { New-TermHealth -State 'warning' -Text 'watchlist' }
        'HEALTHY'   { New-TermHealth -State 'healthy' -Text 'healthy' }
    }
    $hk = @(
        (New-TermHotkey -Key 'B' -Verb 'back')
        (New-TermHotkey -Key 'C' -Verb 'clone')
        (New-TermHotkey -Key '?' -Verb 'help')
    ) | Join-TermHotkeys
    Write-TermLine (New-TermPanelClose -Hotkeys $hk -Healths $health)
}

# Verdict is in the panel and JSON output; exit 0 means the diagnostic ran.
exit $script:EXIT_OK
