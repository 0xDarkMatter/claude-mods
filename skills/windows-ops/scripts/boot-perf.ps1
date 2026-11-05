<#
.SYNOPSIS
    Measure Windows boot performance from the Diagnostics-Performance
    log. Surfaces which boots were slow and what specifically dragged
    each one down.

.DESCRIPTION
    The Microsoft-Windows-Diagnostics-Performance/Operational log records
    detailed timing for every boot event (boot main path, post-boot,
    total) and flags individual components that exceeded the system's
    "fast boot" threshold:

      Event 100 - "Windows successfully booted in X ms"
                  Contains: BootTime, BootMainPathTime, BootPostBootTime,
                  IsDegradation, IncidentTime
      Event 101 - "App took longer than usual to start"
      Event 102 - "Driver took longer than usual to start"
      Event 103 - "Service took longer than usual to start"

    Reading this log requires Administrator. Without admin, the script
    falls back to a kernel-event-based inference using Event 12 (kernel
    start) and Event 6005 (event log service started) - coarser but
    still useful for trend detection.

.PARAMETER LastN
    Number of recent boots to report. Default: 10.

.PARAMETER Json
    Machine-readable JSON output.

.EXAMPLE
    scripts/boot-perf.ps1
    Show the last 10 boots with their durations and degradation flags.

.EXAMPLE
    scripts/boot-perf.ps1 -LastN 30 -Json | jq '.boots[] | select(.degraded)'
    Filter to only degraded boots from machine-readable output.

.NOTES
    Exit codes:
      0 success
      5 precondition (no boot events found at all)
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 100)][int]$LastN = 10,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"
. (Join-Path $PSScriptRoot '..\..\_lib\term.ps1')
Initialize-Term

$elevated = Test-IsElevated
$boots = New-Object System.Collections.Generic.List[hashtable]
$slowComponents = New-Object System.Collections.Generic.List[hashtable]
$source = 'diagnostics-perf'

# ---------------------------------------------------------------------
# Primary: Diagnostics-Performance log (requires admin)
# ---------------------------------------------------------------------
try {
    $perfEvents = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' `
        -ErrorAction Stop |
        Where-Object { $_.Id -in @(100, 101, 102, 103) }

    foreach ($e in $perfEvents | Where-Object { $_.Id -eq 100 }) {
        # Properties layout (Event 100):
        #   [1] BootTime
        #   [4] BootMainPathTime
        #   [5] BootPostBootTime
        #   [6] BootIsDegradation
        try {
            $bootTotal = [int64]$e.Properties[1].Value
            $bootMain  = [int64]$e.Properties[4].Value
            $bootPost  = [int64]$e.Properties[5].Value
            $degraded  = [bool]$e.Properties[6].Value
        } catch {
            $bootTotal = -1; $bootMain = -1; $bootPost = -1; $degraded = $false
        }
        $boots.Add(@{
            time            = $e.TimeCreated.ToString('o')
            bootTotalSec    = if ($bootTotal -gt 0) { [math]::Round($bootTotal / 1000, 1) } else { -1 }
            bootMainSec     = if ($bootMain  -gt 0) { [math]::Round($bootMain  / 1000, 1) } else { -1 }
            bootPostSec     = if ($bootPost  -gt 0) { [math]::Round($bootPost  / 1000, 1) } else { -1 }
            degraded        = $degraded
        })
    }

    # Slow components - events 101/102/103
    foreach ($e in $perfEvents | Where-Object { $_.Id -in @(101, 102, 103) }) {
        $kind = switch ($e.Id) { 101 {'app'} 102 {'driver'} 103 {'service'} }
        # Property layout varies by event id; the friendly name + delay are
        # usually accessible by reading the rendered message string.
        $msg = ($e.Message -replace '\s+', ' ')
        $delaySec = $null
        if ($msg -match '(\d+) ms') {
            $delaySec = [math]::Round([int]$matches[1] / 1000, 1)
        }
        # Name extraction varies; try common patterns
        $name = '(unknown)'
        if ($msg -match '"([^"]+)"') { $name = $matches[1] }
        elseif ($msg -match 'Name\s*:\s*(\S+)') { $name = $matches[1] }
        $slowComponents.Add(@{
            time     = $e.TimeCreated.ToString('o')
            kind     = $kind
            name     = $name
            delaySec = $delaySec
            message  = (Format-EventMessage -Message $msg -MaxLength 200)
        })
    }
}
catch {
    $source = 'kernel-events'
    if (-not $elevated) {
        Write-Log -Level WARN -Message "Cannot read Diagnostics-Performance log (admin required). Falling back to coarse kernel-event timing."
    } else {
        Write-Log -Level WARN -Message "Diagnostics-Performance log unavailable: $_"
    }

    # -----------------------------------------------------------------
    # Fallback: kernel event 12 (start) + 6005 (event log started)
    # Gap = approximate "kernel -> services running" time. Not full boot
    # to usable desktop but a useful trend metric.
    # -----------------------------------------------------------------
    try {
        $kernelStarts = Get-WinEvent -FilterHashtable @{
            LogName='System'; Id=12; ProviderName='Microsoft-Windows-Kernel-General'
        } -MaxEvents 30 -ErrorAction SilentlyContinue
        $logStarts = Get-WinEvent -FilterHashtable @{
            LogName='System'; Id=6005
        } -MaxEvents 30 -ErrorAction SilentlyContinue

        foreach ($k in $kernelStarts) {
            # Find the 6005 closest after this 12 (within 5 min)
            $matchingLog = $logStarts | Where-Object {
                $_.TimeCreated -gt $k.TimeCreated -and ($_.TimeCreated - $k.TimeCreated).TotalSeconds -lt 300
            } | Sort-Object TimeCreated | Select-Object -First 1

            if ($matchingLog) {
                $delta = ($matchingLog.TimeCreated - $k.TimeCreated).TotalSeconds
                $boots.Add(@{
                    time           = $k.TimeCreated.ToString('o')
                    bootTotalSec   = -1   # not available without diagnostics-perf
                    bootMainSec    = [math]::Round($delta, 1)
                    bootPostSec    = -1
                    degraded       = $false
                    note           = 'inferred from kernel start -> event log start; not full boot duration'
                })
            }
        }
    } catch {}
}

# Trim to LastN
$boots = $boots | Sort-Object { [DateTime]$_.time } -Descending | Select-Object -First $LastN

# ---------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------
if ($Json) {
    @{
        source         = $source
        elevated       = $elevated
        boots          = $boots
        slowComponents = $slowComponents | Sort-Object { [DateTime]$_.time } -Descending | Select-Object -First 30
    } | ConvertTo-Json -Depth 5 | ForEach-Object { [Console]::Out.WriteLine($_) }
    exit $script:EXIT_OK
}

if (-not $boots) {
    Write-Log -Level FAIL -Message "No boot events found"
    exit $script:EXIT_PRECONDITION
}

# Median + average for the summary line (whichever data we have)
$mainSecs = $boots | ForEach-Object { $_.bootMainSec } | Where-Object { $_ -gt 0 }
$median = if ($mainSecs.Count -ge 1) {
    $sorted = $mainSecs | Sort-Object
    $sorted[[math]::Floor($sorted.Count / 2)]
} else { 0 }
$avg = if ($mainSecs.Count -ge 1) {
    [math]::Round(($mainSecs | Measure-Object -Average).Average, 1)
} else { 0 }

$sourceLabel = if ($source -eq 'diagnostics-perf') { 'full data' } else { 'fallback mode' }
Write-TermLine (New-TermPanelOpen -Brand 'windows-ops' -Name 'windows-ops' -Subtitle 'boot-perf' -Indicator $sourceLabel)
Write-TermLine (New-TermPanelVert)
Write-TermLine (New-TermSummary -Text "$($boots.Count) boots | median ${median}s | avg ${avg}s")
if (-not $elevated -and $source -ne 'diagnostics-perf') {
    Write-TermLine (New-TermHint -Text 'run as Administrator for full Diagnostics-Performance log (boot phases + slow-component flags)')
}
Write-TermLine (New-TermPanelVert)

Write-TermLine (New-TermSection -State 'INFO' -Label 'boot timeline' -Count $boots.Count)
# Find slowest in window for highlighting
$slowestSec = ($mainSecs | Measure-Object -Maximum).Maximum
$idxLast = $boots.Count - 1
for ($i = 0; $i -lt $boots.Count; $i++) {
    $b = $boots[$i]
    $t = ([DateTime]$b.time).ToString('yyyy-MM-dd HH:mm')
    $secVal = if ($b.bootMainSec -gt 0) { $b.bootMainSec } else { 0 }
    # Capacity pip bar: relative to 20-second ceiling (anything >=80% = red)
    $bar = New-TermPipBar -Type capacity -Filled ([int]($secVal * 5)) -Total 100
    $meta = "${secVal}s"
    if ($b.degraded) { $meta += ' [DEGRADED]' }
    Write-TermLine (New-TermLeaf -Name $t -Rail $bar -Meta $meta -IsLast:($i -eq $idxLast) -NameColWidth 20)
    if ($secVal -eq $slowestSec -and $boots.Count -gt 3 -and $secVal -gt 0) {
        Write-TermLine (New-TermAlert -Severity warning -Text "slowest in window | ${secVal}s vs median ${median}s")
    }
}
Write-TermLine (New-TermPanelVert)

# Slow components section
$recentSlow = $slowComponents | Sort-Object { [DateTime]$_.time } -Descending | Select-Object -First 10
if ($recentSlow) {
    Write-TermLine (New-TermSection -State 'WARN' -Label 'slow components' -Count $recentSlow.Count)
    $idxLast = $recentSlow.Count - 1
    for ($i = 0; $i -lt $recentSlow.Count; $i++) {
        $s = $recentSlow[$i]
        $delay = if ($s.delaySec) { "$($s.delaySec)s" } else { '?' }
        $when = ([DateTime]$s.time).ToString('MM-dd HH:mm')
        Write-TermLine (New-TermLeaf -Name "[$($s.kind)] $($s.name)" -Meta $delay -Age $when -IsLast:($i -eq $idxLast) -NameColWidth 36)
    }
    Write-TermLine (New-TermAlert -Severity warning -Text 'repeat offenders -> safe-disable-startup.ps1 (apps) or Set-Service -StartupType Manual (services)')
    Write-TermLine (New-TermPanelVert)
}

# Footer
$health = if ($elevated -and $source -eq 'diagnostics-perf') {
    New-TermHealth -State 'healthy' -Text 'full data'
} else {
    New-TermHealth -State 'pending' -Text 'fallback'
}
$hk = (New-TermHotkey -Key '?' -Verb 'help')
Write-TermLine (New-TermPanelClose -Hotkeys $hk -Healths $health)

exit $script:EXIT_OK
