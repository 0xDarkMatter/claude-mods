<#
.SYNOPSIS
    Decode an Event 41 crash record and surface the events in the N
    minutes leading up to it. The pre-crash timeline is where the
    actual cause lives.

.DESCRIPTION
    Reads Event 41 (Kernel-Power) and properly decodes:
      Properties[0] = BugCheckCode (the stop code; NOT Properties[1])
      Properties[1-4] = BugcheckParameter1-4
      Properties[6] = PowerButtonTimestamp (non-zero = forced shutdown)
    Then walks events in the configurable window before the crash from
    System log providers that matter for crash correlation: storage
    drivers, GPU drivers, WHEA hardware errors, kernel-power.

    BugCheck = 0x0 with no power-button = hard power loss or hardware
    lockup. BugCheck = 0x0 with power-button = user force-shutdown of a
    hung machine. Non-zero codes are decoded against the known catalog
    (see references/bugcheck-codes.md).

.PARAMETER CrashTime
    Specific crash time (datetime) to triage. If omitted, the most
    recent Event 41 within -DaysBack is used.

.PARAMETER WindowMinutes
    Minutes before the crash to scan for correlated events. Default: 10.

.PARAMETER DaysBack
    When -CrashTime is omitted, how far back to look for the most recent
    crash. Default: 30.

.PARAMETER Json
    Emit machine-readable JSON.

.EXAMPLE
    scripts/crash-triage.ps1
    Triage the most recent crash in the last 30 days.

.EXAMPLE
    scripts/crash-triage.ps1 -CrashTime '2026-05-15 00:57:50'
    Triage a specific crash by timestamp.

.EXAMPLE
    scripts/crash-triage.ps1 -CrashTime '2026-05-15 00:57:50' -WindowMinutes 30
    Widen the pre-crash window to 30 minutes (default 10).

.EXAMPLE
    scripts/crash-triage.ps1 -Json | jq '.bugcheck'
    Pull just the BugCheck code from machine-readable output.

.NOTES
    Exit codes:
      0 success
      3 not found (no crashes in window)
      4 validation
#>

[CmdletBinding()]
param(
    [datetime]$CrashTime,
    [ValidateRange(1, 240)][int]$WindowMinutes = 10,
    [ValidateRange(1, 365)][int]$DaysBack = 30,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"
. (Join-Path $PSScriptRoot '..\..\_lib\term.ps1')
Initialize-Term

# BugCheck quick-lookup (most common codes; full catalog in references/bugcheck-codes.md)
$bugCheckNames = @{
    0x0   = '(no bugcheck recorded - hard power loss / total hang / hardware lockup)'
    0x1E  = 'KMODE_EXCEPTION_NOT_HANDLED'
    0x1A  = 'MEMORY_MANAGEMENT'
    0x3B  = 'SYSTEM_SERVICE_EXCEPTION'
    0x50  = 'PAGE_FAULT_IN_NONPAGED_AREA  (often storage I/O failure for pagefile)'
    0x77  = 'KERNEL_STACK_INPAGE_ERROR  (storage paging failure)'
    0x7A  = 'KERNEL_DATA_INPAGE_ERROR  (storage paging failure)'
    0x7E  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED  (often GPU/network driver)'
    0x9F  = 'DRIVER_POWER_STATE_FAILURE  (driver hung during sleep/wake)'
    0xA   = 'IRQL_NOT_LESS_OR_EQUAL'
    0xC1  = 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION  (Driver Verifier)'
    0xC2  = 'BAD_POOL_CALLER'
    0xC4  = 'DRIVER_VERIFIER_DETECTED_VIOLATION'
    0xD1  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL  (driver accessed bad memory at high IRQL)'
    0xEF  = 'CRITICAL_PROCESS_DIED  (critical system process killed)'
    0xF4  = 'CRITICAL_OBJECT_TERMINATION  (often storage-induced)'
    0x101 = 'CLOCK_WATCHDOG_TIMEOUT  (CPU stall - chipset or hardware)'
    0x124 = 'WHEA_UNCORRECTABLE_ERROR  (hardware-level fault)'
    0x139 = 'KERNEL_SECURITY_CHECK_FAILURE  (stack/pool corruption)'
}

# ---------------------------------------------------------------------
# Find the target crash
# ---------------------------------------------------------------------
if (-not $CrashTime) {
    Write-Log -Level INFO -Message "No -CrashTime given; finding most recent Event 41 in last $DaysBack days"
    $crash = Get-WinEvent -FilterHashtable @{
        LogName='System'
        Id=41
        StartTime=(Get-Date).AddDays(-$DaysBack)
    } -MaxEvents 1 -ErrorAction SilentlyContinue
    if (-not $crash) {
        Write-Log -Level INFO -Message "No Event 41 crashes found in last $DaysBack days. System has been stable."
        exit $script:EXIT_NOT_FOUND
    }
    $CrashTime = $crash.TimeCreated
} else {
    # Find the Event 41 closest to the given time (within +/-60 seconds)
    $low  = $CrashTime.AddMinutes(-1)
    $high = $CrashTime.AddMinutes(1)
    $crash = Get-WinEvent -FilterHashtable @{
        LogName='System'
        Id=41
        StartTime=$low
        EndTime=$high
    } -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $crash) {
        Write-Log -Level FAIL -Message "No Event 41 found within +/-60s of $CrashTime"
        exit $script:EXIT_NOT_FOUND
    }
}

# ---------------------------------------------------------------------
# Decode the crash record
# ---------------------------------------------------------------------
$bcCode  = [int64]$crash.Properties[0].Value
$param1  = [int64]$crash.Properties[1].Value
$param2  = [int64]$crash.Properties[2].Value
$param3  = [int64]$crash.Properties[3].Value
$param4  = [int64]$crash.Properties[4].Value
$pwrBtn  = if ($crash.Properties.Count -gt 6) { [int64]$crash.Properties[6].Value } else { 0 }
$bcHex   = '0x{0:X}' -f $bcCode
$bcName  = if ($bugCheckNames.ContainsKey([int]$bcCode)) { $bugCheckNames[[int]$bcCode] } else { '(unknown - consult references/bugcheck-codes.md)' }

# Cause discrimination for BugCheck = 0
$causeHint = if ($bcCode -eq 0) {
    if ($pwrBtn -ne 0) { 'Power button was held -> user force-shutdown of a hung machine' }
    else                { 'No power button press recorded -> hard power loss / hardware lockup / thermal trip' }
} else { $null }

# ---------------------------------------------------------------------
# Walk the pre-crash window
# ---------------------------------------------------------------------
$windowStart = $CrashTime.AddMinutes(-$WindowMinutes)
$preEvents = Get-WinEvent -FilterHashtable @{
    LogName='System'
    StartTime=$windowStart
    EndTime=$CrashTime
    Level=@(1,2,3)
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated

# Smoking-gun detection
$smokingGuns = @()
foreach ($e in $preEvents) {
    if ($e.ProviderName -eq 'storahci' -and $e.Id -eq 129) {
        $smokingGuns += "STORAGE: storahci controller reset at $($e.TimeCreated.ToString('HH:mm:ss')) - drive stopped responding"
    } elseif ($e.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -and $e.Level -le 2) {
        $smokingGuns += "HARDWARE: WHEA error at $($e.TimeCreated.ToString('HH:mm:ss')) - CPU/RAM/PCIe-level fault"
    } elseif ($e.ProviderName -match 'nvlddmkm|igdkmd|amdkmdag' -and $e.Level -le 2) {
        $smokingGuns += "GPU: $($e.ProviderName) error at $($e.TimeCreated.ToString('HH:mm:ss')) - GPU driver issue"
    } elseif ($e.ProviderName -eq 'disk' -and $e.Id -in @(7,51,153,154)) {
        $smokingGuns += "STORAGE: disk Event $($e.Id) at $($e.TimeCreated.ToString('HH:mm:ss')) - bad block or hardware error"
    }
}

# ---------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------
if ($Json) {
    @{
        crashTime         = $CrashTime.ToString('o')
        bugcheck          = $bcHex
        bugcheckName      = $bcName
        param1            = '0x{0:X}' -f $param1
        param2            = '0x{0:X}' -f $param2
        param3            = '0x{0:X}' -f $param3
        param4            = '0x{0:X}' -f $param4
        powerButtonHeld   = ($pwrBtn -ne 0)
        causeHint         = $causeHint
        windowMinutes     = $WindowMinutes
        preCrashEvents    = $preEvents.Count
        smokingGuns       = $smokingGuns
        timeline          = $preEvents | ForEach-Object {
            @{
                time     = $_.TimeCreated.ToString('o')
                provider = $_.ProviderName
                id       = $_.Id
                level    = $_.LevelDisplayName
                message  = (Format-EventMessage -Message $_.Message -MaxLength 200)
            }
        }
    } | ConvertTo-Json -Depth 5 | ForEach-Object { [Console]::Out.WriteLine($_) }
} else {
    $indicator = $CrashTime.ToString('yyyy-MM-dd HH:mm:ss')
    Write-TermLine (New-TermPanelOpen -Brand 'windows-ops' -Name 'windows-ops' -Subtitle 'crash-triage' -Indicator $indicator)
    Write-TermLine (New-TermPanelVert)
    Write-TermLine (New-TermSummary -Text "BugCheck $bcHex | $bcName")
    Write-TermLine (New-TermPanelVert)

    # PARAMETERS section
    Write-TermLine (New-TermSection -State 'INFO' -Label 'parameters' -Count -1)
    Write-TermLine (New-TermLeaf -Name 'Param1' -Meta ('0x{0:X}' -f $param1))
    Write-TermLine (New-TermLeaf -Name 'Param2' -Meta ('0x{0:X}' -f $param2))
    Write-TermLine (New-TermLeaf -Name 'Param3' -Meta ('0x{0:X}' -f $param3))
    Write-TermLine (New-TermLeaf -Name 'Param4' -Meta ('0x{0:X}' -f $param4))
    $pwrText = if ($pwrBtn -ne 0) { 'held (forced shutdown)' } else { 'not pressed' }
    Write-TermLine (New-TermLeaf -Name 'PowerButton' -Meta $pwrText -IsLast)
    if ($causeHint) {
        Write-TermLine (New-TermAlert -Severity warning -Text $causeHint)
    }
    Write-TermLine (New-TermPanelVert)

    # TIMELINE section
    if ($preEvents) {
        Write-TermLine (New-TermSection -State 'WARN' -Label "pre-crash timeline" -Count $preEvents.Count)
        $idxLast = $preEvents.Count - 1
        for ($i = 0; $i -lt $preEvents.Count; $i++) {
            $e = $preEvents[$i]
            $deltaSec = [int]($CrashTime - $e.TimeCreated).TotalSeconds
            $deltaStr = if ($deltaSec -ge 60) {
                "T-{0}m{1:00}s" -f ([math]::Floor($deltaSec/60)), ($deltaSec % 60)
            } else {
                "T-{0}s" -f $deltaSec
            }
            $msg = Format-EventMessage -Message $e.Message -MaxLength 50
            Write-TermLine (New-TermLeaf -Name "$($e.ProviderName) $($e.Id)" -Meta $msg -Age $deltaStr -IsLast:($i -eq $idxLast) -NameColWidth 24 -MetaColWidth 50)
        }
        Write-TermLine (New-TermPanelVert)
    } else {
        Write-TermLine (New-TermSection -State 'WARN' -Label "pre-crash timeline" -Count 0)
        Write-TermLine (New-TermHint -Text 'no warning/error events in window - sudden hang or instant fault')
        Write-TermLine (New-TermPanelVert)
    }

    # SMOKING GUNS section
    if ($smokingGuns) {
        Write-TermLine (New-TermSection -State 'FAILING' -Label 'smoking guns' -Count $smokingGuns.Count)
        $idxLast = $smokingGuns.Count - 1
        for ($i = 0; $i -lt $smokingGuns.Count; $i++) {
            Write-TermLine (New-TermLeaf -Name $smokingGuns[$i] -IsLast:($i -eq $idxLast) -NameColWidth 80 -RailColWidth 0 -MetaColWidth 0)
        }
        Write-TermLine (New-TermPanelVert)
    }

    # Footer
    $health = if ($smokingGuns) {
        New-TermHealth -State 'busted' -Text 'cascade'
    } elseif ($bcCode -eq 0) {
        New-TermHealth -State 'critical' -Text 'no bugcheck'
    } else {
        New-TermHealth -State 'warning' -Text 'decoded'
    }
    $hk = @(
        (New-TermHotkey -Key 'D' -Verb 'drill')
        (New-TermHotkey -Key '?' -Verb 'help')
    ) | Join-TermHotkeys
    Write-TermLine (New-TermPanelClose -Hotkeys $hk -Healths $health)
}

exit $script:EXIT_OK
