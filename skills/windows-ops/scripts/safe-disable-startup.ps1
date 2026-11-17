<#
.SYNOPSIS
    Disable (or re-enable) Windows startup entries via the StartupApproved
    registry mechanism - the flag Task Manager's Startup tab writes. Reversible.

.DESCRIPTION
    Equivalent of Task Manager's "Disable" button: writes a 12-byte binary
    flag to Explorer\StartupApproved\{Run,Run32,StartupFolder} so Explorer
    skips the entry at next logon. Nothing is deleted.

    The flag goes in the SAME hive as the entry, as Task Manager does:
      - HKCU Run, the user's Startup folder        -> HKCU overlay, no admin
      - HKLM Run, HKLM WOW6432Node Run (Run32),
        the all-users Startup folder               -> HKLM overlay, ADMIN
    A batch that includes a machine-wide entry is refused as a whole, with
    exit 5 and nothing written, unless the shell is elevated. Elevate from the
    same account (UAC consent), not as a different administrator: HKCU then
    means that administrator's hive, not yours.

    Services and scheduled tasks are NOT touched by this script - those
    need Set-Service / Disable-ScheduledTask respectively.

.PARAMETER Name
    The Run-key value name (or Startup-folder file name, e.g. 'Tailscale.lnk')
    to disable. Wildcards expand against the actual entries. Multiple names
    accepted (positional or via pipeline).

.PARAMETER Enable
    Re-enable instead of disable (writes status 0x02, as Task Manager does).

.PARAMETER List
    List current state of all StartupApproved entries and exit. Ignores -Name.
    Needs no admin.

.PARAMETER Json
    Emit machine-readable JSON (one object per line) of the rows or actions.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -List
    Show current enabled/disabled state of every Run-key and Startup-folder entry.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -Name 'Granola','CometUpdaterTask*'
    Disable user (HKCU) entries; wildcards expand against actual Run-key entries.

.EXAMPLE
    Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-NoExit','-File','scripts\safe-disable-startup.ps1','-Name','MuseHub'
    Disable a machine-wide (HKLM Run) entry: needs an elevated shell.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -Name 'Adobe Creative Cloud' -WhatIf
    Preview which overlay key would be written. Needs no admin.

.EXAMPLE
    scripts/safe-disable-startup.ps1 -Name 'Granola' -Enable
    Re-enable a previously-disabled entry.

.NOTES
    Exit codes:
      0 success
      2 usage (no names given and not -List)
      3 not found (no matching Run-key or Startup-folder entry)
      5 precondition: a matched entry is machine-wide and the shell is not elevated
#>

# GUARD: machine entries are flagged in HKLM on purpose. An earlier version wrote every
# flag to HKCU so it ran without admin, on the belief that Explorer honours an HKCU value
# for an HKLM entry. Task Manager never writes that, and nothing shows Explorer reading
# it, so entries it "disabled" may have kept starting. Do not route a machine entry to HKCU to
# avoid elevation; evidence in references/startup-mechanisms.md. Every registry path
# comes from _lib/common.ps1 (Get-StartupApprovedSources / -OverlayPath); the suite fails
# if this file spells a hive path itself.

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(ValueFromPipeline, Position=0)][string[]]$Name,
    [switch]$Enable,
    [switch]$List,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"
. (Join-Path $PSScriptRoot '..\..\_lib\term.ps1')
Initialize-Term

function Get-RunEntries {
    # Every Run-key value and Startup-folder shortcut, each carrying the source row it
    # came from (that row decides which overlay governs it).
    $entries = @()
    foreach ($s in (Get-StartupApprovedSources)) {
        if (-not (Test-Path -LiteralPath $s.Path)) { continue }
        if ($s.Kind -eq 'Run') {
            $item = Get-Item -LiteralPath $s.Path
            foreach ($n in $item.GetValueNames()) {
                if (-not $n) { continue }   # the (Default) value is not a startup entry
                $entries += [PSCustomObject]@{
                    Name    = $n
                    Command = [string]$item.GetValue($n)
                    Label   = $s.Label
                    Source  = $s
                }
            }
        } else {
            Get-ChildItem -LiteralPath $s.Path -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
                $entries += [PSCustomObject]@{
                    Name    = $_.Name        # full filename, e.g. "Comet.lnk"
                    Command = $_.FullName
                    Label   = $s.Label
                    Source  = $s
                }
            }
        }
    }
    return $entries
}

function Get-CurrentState {
    param([Parameter(Mandatory)]$Entry)
    $key = Get-StartupApprovedOverlayPath -Source $Entry.Source
    $val = $null
    if (Test-Path $key) { $val = (Get-Item $key).GetValue($Entry.Name) }
    return (ConvertFrom-StartupApprovedStatus -Value $val)
}

# ---------------------------------------------------------------------
# Mode: List
# ---------------------------------------------------------------------
if ($List) {
    $allEntries = Get-RunEntries
    $rows = foreach ($e in $allEntries) {
        [PSCustomObject]@{
            Name    = $e.Name
            State   = (Get-CurrentState -Entry $e)
            Scope   = $e.Source.Scope
            Variant = $e.Source.Variant
            Source  = $e.Label
            Overlay = (Get-StartupApprovedOverlayPath -Source $e.Source)
            Command = $e.Command -replace '"',''
        }
    }

    if ($Json) {
        foreach ($r in $rows) {
            [Console]::Out.WriteLine(($r | ConvertTo-Json -Compress))
        }
        exit $script:EXIT_OK
    }

    # Group by state for the panel
    $enabled  = @($rows | Where-Object { $_.State -eq 'enabled' -or $_.State -eq 'unmanaged' })
    $disabled = @($rows | Where-Object { $_.State -eq 'disabled' })
    $unknown  = @($rows | Where-Object { $_.State -like 'unknown*' })

    Write-TermLine (New-TermPanelOpen -Brand 'windows-ops' -Name 'windows-ops' -Subtitle 'safe-disable-startup' -Indicator "$(@($rows).Count) entries")
    Write-TermLine (New-TermPanelVert)
    $summary = "$($enabled.Count) active | $($disabled.Count) disabled"
    if ($unknown.Count -gt 0) { $summary += " | $($unknown.Count) unknown" }
    Write-TermLine (New-TermSummary -Text $summary)
    Write-TermLine (New-TermPanelVert)

    if ($enabled) {
        Write-TermLine (New-TermSection -State 'PASS' -Label 'active' -Count $enabled.Count)
        $last = $enabled[-1]
        foreach ($e in $enabled) {
            Write-TermLine (New-TermLeaf -Name $e.Name -Meta $e.Source -IsLast:($e -eq $last))
        }
        Write-TermLine (New-TermPanelVert)
    }

    if ($disabled) {
        Write-TermLine (New-TermSection -State 'WARN' -Label 'disabled' -Count $disabled.Count)
        $last = $disabled[-1]
        foreach ($e in $disabled) {
            Write-TermLine (New-TermLeaf -Name $e.Name -Meta $e.Source -IsLast:($e -eq $last))
        }
        Write-TermLine (New-TermPanelVert)
    }

    if ($unknown) {
        Write-TermLine (New-TermSection -State 'FAILING' -Label 'unknown state' -Count $unknown.Count)
        $last = $unknown[-1]
        foreach ($e in $unknown) {
            Write-TermLine (New-TermLeaf -Name $e.Name -Meta $e.Source -Age $e.State -IsLast:($e -eq $last))
            Write-TermLine (New-TermAlert -Severity warning -Text 'partial/corrupt StartupApproved entry - verify with Task Manager')
        }
        Write-TermLine (New-TermPanelVert)
    }

    $hk = @(
        (New-TermHotkey -Key 'E' -Verb 'enable')
        (New-TermHotkey -Key 'D' -Verb 'disable')
        (New-TermHotkey -Key '?' -Verb 'help')
    ) | Join-TermHotkeys
    $hl = @(
        (New-TermHealth -State 'healthy' -Text "$($enabled.Count) active")
    ) | Join-TermHealths
    Write-TermLine (New-TermPanelClose -Hotkeys $hk -Healths $hl)

    exit $script:EXIT_OK
}

# ---------------------------------------------------------------------
# Mode: Disable/Enable
# ---------------------------------------------------------------------
if (-not $Name) {
    Write-Log -Level ERROR -Message "Must provide -Name or -List. See -? for help."
    exit $script:EXIT_USAGE
}

$statusByte = if ($Enable) { [byte]0x02 } else { [byte]0x03 }
$action     = if ($Enable) { 'enable' }   else { 'disable' }
$valueBytes = ConvertTo-Bytes12 -StatusByte $statusByte

# Resolve every target before writing anything, so the elevation check below can refuse
# the whole batch: a half-applied batch (user entries done, machine entries not) is
# harder to reason about than none.
$allEntries = Get-RunEntries
$targets    = @()
foreach ($pattern in $Name) {
    $hits = @($allEntries | Where-Object { $_.Name -like $pattern })
    if (-not $hits) {
        Write-Log -Level WARN -Message "No Run-key or Startup-folder entries match pattern: $pattern"
        continue
    }
    foreach ($h in $hits) {
        # Two patterns can match one entry; act on it once.
        if (-not ($targets | Where-Object { $_.Name -eq $h.Name -and $_.Label -eq $h.Label })) { $targets += $h }
    }
}

if (-not $targets) {
    Write-Log -Level ERROR -Message "No matching entries acted on."
    exit $script:EXIT_NOT_FOUND
}

$machine = @($targets | Where-Object { $_.Source.Scope -eq 'Machine' })
if ($machine -and -not $WhatIfPreference -and -not (Test-IsElevated)) {
    $names = ($machine | ForEach-Object { "$($_.Name) [$($_.Label)]" }) -join ', '
    Write-Log -Level ERROR -Message "Machine-wide entries need an elevated shell: $names"
    Write-Log -Level INFO -Message "Explorer reads their flag from HKLM\...\Explorer\StartupApproved, which only an administrator can write. Nothing was changed."
    $user = @($targets | Where-Object { $_.Source.Scope -eq 'User' })
    if ($user) {
        Write-Log -Level INFO -Message "User entries in this batch (no admin needed if run alone): $(($user | ForEach-Object { $_.Name }) -join ', ')"
    }
    Write-Log -Level INFO -Message "Re-run from an elevated PowerShell: Start-Process pwsh -Verb RunAs"
    exit $script:EXIT_PRECONDITION
}

$matched = @()
foreach ($e in $targets) {
    $key = Get-StartupApprovedOverlayPath -Source $e.Source
    if ($PSCmdlet.ShouldProcess("$($e.Name) [$($e.Label)]", "$action via $key")) {
        try {
            $null = Get-StartupApprovedKey -Source $e.Source
            Set-ItemProperty -Path $key -Name $e.Name -Value $valueBytes -Type Binary -Force
            $matched += $e
            $verified = Get-CurrentState -Entry $e
            Write-Log -Level PASS -Message "${action}d: $($e.Name)  [$($e.Label)] -> verified state: $verified"
            if ($Json) {
                [Console]::Out.WriteLine((@{
                    action   = $action
                    name     = $e.Name
                    scope    = $e.Source.Scope
                    variant  = $e.Source.Variant
                    overlay  = $key
                    verified = $verified
                } | ConvertTo-Json -Compress))
            }
        } catch {
            Write-Log -Level FAIL -Message "Failed to $action $($e.Name): $_"
        }
    }
}

if (-not $matched) {
    if ($WhatIfPreference) { exit $script:EXIT_OK }
    Write-Log -Level ERROR -Message "No matching entries acted on."
    exit $script:EXIT_NOT_FOUND
}

if (-not $Json -and -not $Quiet) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("$($matched.Count) entr$(if ($matched.Count -eq 1) {'y'} else {'ies'}) ${action}d. Effect applies at next user logon.")
    [Console]::Error.WriteLine("Re-run with -List to verify.")
}

exit $script:EXIT_OK
