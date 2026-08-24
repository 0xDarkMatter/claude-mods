<#
.SYNOPSIS
    Resilient recursive folder copy on Windows. Never stops on errors; writes a
    readable failed-files log. Three presets: Copy (default), Rescue, Mirror.

.DESCRIPTION
    A robocopy wrapper with sane, non-destructive defaults. Robocopy already
    logs failures and carries on rather than aborting — this script's job is to
    pick the right flags for the situation, then turn robocopy's bitmask exit
    and wall-of-text log into a verdict plus a failed-files list you can act on.

    THE ROBOCOPY DEFAULT THAT BITES EVERYONE: bare `robocopy` uses
    /R:1000000 /W:30 — a single locked file retries a million times with 30s
    waits (~347 days) and looks exactly like a hang. Every mode below sets /R
    and /W explicitly.

    Modes (-Mode):

      Copy    DEFAULT. Healthy source, everyday copy.
              /E /R:1 /W:1 /MT:16 — additive, never deletes at destination.
              One retry absorbs transiently-locked files without stalling.

      Rescue  Failing/suspect drive. /E /R:0 /W:0 /MT:1 — additive.
              Zero retries because every re-read of a bad sector stresses a
              dying drive further and can finish it off. Single-threaded so
              the head isn't thrashed across the platter. Skips the recursive
              size preflight for the same reason (see -SkipSpaceCheck).

      Mirror  DESTRUCTIVE. /MIR — makes destination identical to source,
              which means DELETING anything at the destination that isn't in
              the source. Prompts for confirmation unless -Force. A mistyped
              destination in this mode is a mass deletion, which is why it is
              not, and must never become, the default.

    All modes: /XJ (skip junctions — no recursive mount loops), /COPY:DAT
    (data+attributes+timestamps; ACLs cost time — add -CopyAcl if you need
    them), /DCOPY:T (directory timestamps).

    Resumable: re-run after a crash or Ctrl-C and robocopy skips what already
    matches at the destination. Copy and Mirror are both idempotent.

.PARAMETER Source
    Source directory. Required. Must be a directory, not a file.

.PARAMETER Destination
    Destination directory. Created if absent. Required.

.PARAMETER Mode
    Copy (default, additive) | Rescue (failing drive) | Mirror (destructive).
    See DESCRIPTION. Overrides for -MaxRetries / -Threads still apply.

.PARAMETER MaxRetries
    Retry budget per file, overriding the mode default (Copy 1, Rescue 0,
    Mirror 1). Keep at 0 on a failing drive — retries accelerate its death.

.PARAMETER Threads
    Robocopy /MT thread count, overriding the mode default (Copy/Mirror 16,
    Rescue 1). Ignored with -Backup, which robocopy runs single-threaded.

.PARAMETER CopyAcl
    Copy security descriptors too (/COPY:DATSOU). Slower, and Owner/Auditing
    need an elevated shell. Default omits ACLs — the destination inherits from
    its parent, which is usually what you want for a plain copy.

.PARAMETER Backup
    Use restartable + backup mode (/ZB). Lets an elevated shell read files
    whose ACLs would otherwise deny access, and resumes partially-copied large
    files. Slower; robocopy disables multithreading with it.

.PARAMETER Exclude
    One or more file/directory name patterns to skip (robocopy /XF and /XD).
    e.g. -Exclude node_modules,*.tmp,.git

.PARAMETER LogDir
    Where to write the transfer log and failed-files log. Default: TEMP.

.PARAMETER SkipSpaceCheck
    Skip the pre-copy capacity check. That check walks the source tree to sum
    its size, which on a huge tree takes minutes (and looks like a hang) and on
    a failing drive is extra stress. Implied by -Mode Rescue.

.PARAMETER DryRun
    Enumerate without copying (robocopy /L). Shows what would transfer.

.PARAMETER Force
    Skip the confirmation prompt in Mirror mode. Nothing else consults it.

.PARAMETER Json
    Emit a single JSON result object on stdout instead of the panel. Stdout
    stays data-only; framing and logs go to stderr.

.PARAMETER Help
    Show usage and exit 0.

.EXAMPLE
    scripts/copy-tree.ps1 X:\Source X:\Dest
    Everyday copy. Additive, one retry per file, 16 threads, failed-files log.

.EXAMPLE
    scripts/copy-tree.ps1 Y:\ Z:\rescue -Mode Rescue
    Salvage a failing drive: zero retries, single-threaded, no size preflight.

.EXAMPLE
    scripts/copy-tree.ps1 X:\Site X:\Backup -Mode Mirror -Force
    Make Backup identical to Site, DELETING extras at Backup. No prompt.

.EXAMPLE
    scripts/copy-tree.ps1 X:\Proj X:\Proj-copy -Exclude node_modules,.git,*.tmp
    Copy skipping heavy build/VCS directories.

.EXAMPLE
    scripts/copy-tree.ps1 X:\A X:\B -DryRun
    List what would be copied; check capacity and counts first.

.EXAMPLE
    scripts/copy-tree.ps1 X:\A X:\B -Json | ConvertFrom-Json
    Machine-readable result: verdict, counts, log paths, failed files.

.NOTES
    Exit codes:
      0   complete — everything copied (or nothing needed copying)
      10  partial  — copy ran, but some files failed; see the failed-files log
      1   fatal    — robocopy could not run the job at all
      2   usage    — bad arguments
      3   not found — source missing, or source is a file not a directory
      4   validation — destination has less free space than the source
      5   precondition — robocopy.exe not on PATH

    Exit 10 (not 1) for partial means a caller can distinguish "some files
    were locked" from "the copy never happened" — the older version of this
    script collapsed both to 1.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position=0)][string]$Source,
    [Parameter(Position=1)][string]$Destination,
    [ValidateSet('Copy','Rescue','Mirror')][string]$Mode = 'Copy',
    [ValidateRange(0,5)][int]$MaxRetries = -1,
    [ValidateRange(1,128)][int]$Threads = -1,
    [switch]$CopyAcl,
    [switch]$Backup,
    [string[]]$Exclude,
    [string]$LogDir = $env:TEMP,
    [switch]$SkipSpaceCheck,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Json,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"
. (Join-Path $PSScriptRoot '..\..\_lib\term.ps1')
Initialize-Term

if ($Help -or -not $Source -or -not $Destination) {
    Get-Help $PSCommandPath -Detailed | Out-String | ForEach-Object {
        [Console]::Error.WriteLine($_)
    }
    if ($Help) { exit $script:EXIT_OK }
    Write-Log -Level FAIL -Message "Source and Destination are required"
    exit $script:EXIT_USAGE
}

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
    Write-Log -Level FAIL -Message "robocopy.exe not on PATH (ships with every Windows install)"
    exit $script:EXIT_PRECONDITION
}

if (-not (Test-Path $Source)) {
    Write-Log -Level FAIL -Message "Source not found: $Source"
    exit $script:EXIT_NOT_FOUND
}
if (-not (Test-Path $Source -PathType Container)) {
    Write-Log -Level FAIL -Message "Source is a file, not a directory: $Source. robocopy copies trees; use Copy-Item for a single file."
    exit $script:EXIT_NOT_FOUND
}

# Trailing-backslash footgun: PowerShell hands native exes a raw string, so
# "C:\dir\" arrives at robocopy as C:\dir" and it fails with a baffling parse
# error. Strip the trailing separator unless the path IS a root (X:\, \\srv\shr).
function Format-RoboPath {
    param([string]$Path)
    $p = $Path.Trim()
    if ($p -match '^[A-Za-z]:\\$') { return $p }          # drive root — keep
    if ($p -match '^\\\\[^\\]+\\[^\\]+\\?$') { return $p.TrimEnd('\') + '\' }  # UNC share root
    return $p.TrimEnd('\')
}
$srcArg = Format-RoboPath $Source
$dstArg = Format-RoboPath $Destination

# Mode presets. Explicit -MaxRetries / -Threads win over the preset.
$preset = switch ($Mode) {
    'Copy'   { @{ Retries = 1; Wait = 1; Threads = 16; Mirror = $false } }
    'Rescue' { @{ Retries = 0; Wait = 0; Threads = 1;  Mirror = $false } }
    'Mirror' { @{ Retries = 1; Wait = 1; Threads = 16; Mirror = $true  } }
}
$retries = if ($MaxRetries -ge 0) { $MaxRetries } else { $preset.Retries }
$wait    = if ($retries -eq 0) { 0 } else { $preset.Wait }
$threads = if ($Threads -ge 1) { $Threads } else { $preset.Threads }

# ── Capacity preflight ───────────────────────────────────────────────────────
# Summing the source tree means walking every file. On a big tree that is
# minutes of apparent hang; on a dying drive it is stress we exist to avoid.
$skipSpace = $SkipSpaceCheck -or ($Mode -eq 'Rescue')
$srcUsedGB = -1
if (-not $skipSpace) {
    Write-Log -Level INFO -Message "Sizing source tree (skip with -SkipSpaceCheck)..."
    try {
        $sum = (Get-ChildItem $Source -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($sum) { $srcUsedGB = [math]::Round($sum / 1GB, 1) }
    } catch { $srcUsedGB = -1 }
}

# Free space: only meaningful for a local drive-letter destination. UNC paths
# have no PSDrive to interrogate — report unknown rather than silently
# mis-parsing "\\server\share" as drive "\" (the old bug).
$destFreeGB = -1
if ($dstArg -match '^([A-Za-z]):') {
    try {
        $di = New-Object System.IO.DriveInfo ($matches[1] + ':\')
        if ($di.IsReady) { $destFreeGB = [math]::Round($di.AvailableFreeSpace / 1GB, 1) }
    } catch { $destFreeGB = -1 }
}

if ($srcUsedGB -gt 0 -and $destFreeGB -ge 0 -and $destFreeGB -lt $srcUsedGB) {
    Write-Log -Level FAIL -Message "Destination has $destFreeGB GB free; source is $srcUsedGB GB. Insufficient space."
    exit $script:EXIT_VALIDATION
}

# ── Build the robocopy invocation ────────────────────────────────────────────
$stamp     = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$transferLog = Join-Path $LogDir "copy-tree-$stamp.log"
$failedLog   = Join-Path $LogDir "copy-tree-$stamp-errors.log"

$roboArgs = @($srcArg, $dstArg)
$roboArgs += if ($preset.Mirror) { '/MIR' } else { '/E' }
$roboArgs += '/XJ'
$roboArgs += if ($CopyAcl) { '/COPY:DATSOU' } else { '/COPY:DAT' }
$roboArgs += '/DCOPY:T'
$roboArgs += "/R:$retries"
$roboArgs += "/W:$wait"
if ($Backup) {
    $roboArgs += '/ZB'          # restartable, fall back to backup mode
} else {
    $roboArgs += "/MT:$threads" # /MT is incompatible with /ZB
}
foreach ($x in $Exclude) {
    $roboArgs += '/XF'; $roboArgs += $x
    $roboArgs += '/XD'; $roboArgs += $x
}
$roboArgs += '/V'               # verbose — name skipped files too
$roboArgs += '/BYTES'
$roboArgs += '/NP'              # no per-file percentage (keeps the log parseable)
$roboArgs += "/LOG:$transferLog"
if (-not $Json) { $roboArgs += '/TEE' }
if ($DryRun)    { $roboArgs += '/L' }

# ── Preflight panel ──────────────────────────────────────────────────────────
$indicator = if ($DryRun) { "$($Mode.ToLower()) · dry-run" } else { $Mode.ToLower() }
if (-not $Json) {
    Write-TermLine (New-TermPanelOpen -Brand 'windows-ops' -Name 'windows-ops' -Subtitle 'copy-tree' -Indicator $indicator)
    Write-TermLine (New-TermPanelVert)
    $srcDisplay = if ($srcUsedGB -gt 0) { "$srcUsedGB GB" } elseif ($skipSpace) { 'size not measured' } else { 'size unknown' }
    $dstDisplay = if ($destFreeGB -ge 0) { "$destFreeGB GB free" } else { 'free space unknown' }
    Write-TermLine (New-TermSummary -Text "$srcArg → $dstArg · $srcDisplay · destination has $dstDisplay")
    Write-TermLine (New-TermPanelVert)

    Write-TermLine (New-TermSection -State 'INFO' -Label 'plan' -Count -1)
    $modeMeta = switch ($Mode) {
        'Copy'   { '/E — additive, nothing at the destination is deleted' }
        'Rescue' { '/E — additive, tuned to not stress a failing drive' }
        'Mirror' { '/MIR — DELETES destination files missing from source' }
    }
    Write-TermLine (New-TermLeaf -Name 'mode' -Meta $modeMeta)
    Write-TermLine (New-TermLeaf -Name 'retries per file' -Meta "$retries (wait ${wait}s)")
    Write-TermLine (New-TermLeaf -Name 'threads' -Meta $(if ($Backup) { '1 (/ZB backup mode)' } else { "$threads" }))
    if ($Exclude) { Write-TermLine (New-TermLeaf -Name 'excluding' -Meta ($Exclude -join ', ')) }
    Write-TermLine (New-TermLeaf -Name 'transfer log' -Meta $transferLog -IsLast)

    if ($Mode -eq 'Mirror') {
        Write-TermLine (New-TermAlert -Severity warning -Text "MIRROR — files under $dstArg that are absent from the source will be DELETED")
    }
    if ($DryRun) {
        Write-TermLine (New-TermAlert -Severity warning -Text 'DRY-RUN — robocopy /L enumerates without copying')
    }
    Write-TermLine (New-TermPanelVert)
    Write-TermLine (New-TermPanelClose -Hotkeys (New-TermHotkey -Key '?' -Verb 'help') -Healths (New-TermHealth -State 'pending' -Text 'starting'))
}

# Mirror deletes. Make the operator say so out loud unless -Force or -WhatIf.
if ($preset.Mirror -and -not $DryRun -and -not $Force) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("Mirror mode will DELETE files under $dstArg that are not in $srcArg.")
    $answer = Read-Host "Type the word MIRROR to proceed"
    if ($answer -cne 'MIRROR') {
        Write-Log -Level INFO -Message "Aborted — destination untouched."
        exit $script:EXIT_OK
    }
}

if (-not $PSCmdlet.ShouldProcess("$srcArg -> $dstArg", "robocopy $Mode")) {
    Write-Log -Level INFO -Message "WhatIf: no changes made"
    exit $script:EXIT_OK
}

# ── Run ──────────────────────────────────────────────────────────────────────
$start = Get-Date
& robocopy.exe @roboArgs | Out-Null
$roboExit = $LASTEXITCODE
$elapsedSec = ((Get-Date) - $start).TotalSeconds

# Robocopy's exit is a bitmask: 1 copied · 2 extras · 4 mismatches ·
# 8 FAILURES · 16 fatal. Anything >=8 carries real failures.
$hasFailures = ($roboExit -band 8) -ne 0
$isFatal     = ($roboExit -band 16) -ne 0

# ── Failed-files extraction ──────────────────────────────────────────────────
# Robocopy's error record is TWO lines and the reason is on the second:
#   2026/08/16 18:16:44 ERROR 32 (0x00000020) Copying File X:\src\locked.txt
#   The process cannot access the file because it is being used by another process.
# Capturing only line 1 (what this script used to do) yields a list of hex
# codes with no explanation. Pair them up instead. Verified against robocopy
# 10.0.22621 on 2026-08-16.
$failures = @()
if (Test-Path $transferLog) {
    $hits = Select-String -Path $transferLog -Pattern '^\s*\d{4}/\d{2}/\d{2}.*ERROR (\d+) \(0x[0-9A-Fa-f]+\)\s*(.*)$' -Context 0,1 -ErrorAction SilentlyContinue
    foreach ($h in $hits) {
        $code   = $h.Matches[0].Groups[1].Value
        $what   = $h.Matches[0].Groups[2].Value.Trim()
        $reason = ($h.Context.PostContext | Where-Object { $_.Trim() } | Select-Object -First 1)
        $failures += [PSCustomObject]@{
            code   = [int]$code
            path   = ($what -replace '^(Copying File|Copying Dir|Accessing Source Directory|Deleting File)\s*', '')
            action = if ($what -match '^(Copying File|Copying Dir|Accessing Source Directory|Deleting File)') { $matches[1] } else { 'Unknown' }
            reason = if ($reason) { $reason.Trim() } else { "error $code" }
        }
    }
    # Each retry logs its own ERROR record, so /R:1 yields two entries for one
    # unreadable file. Report files, not attempts — keep the last outcome per path.
    if ($failures.Count -gt 0) {
        $failures = $failures | Group-Object path | ForEach-Object { $_.Group[-1] }
    }
    if ($failures.Count -gt 0) {
        $header = @(
            "copy-tree failed files — $stamp",
            "$srcArg -> $dstArg (mode: $Mode, retries: $retries)",
            "$($failures.Count) file(s) could not be copied. Transfer log: $transferLog",
            ""
        )
        $body = $failures | ForEach-Object { "[$($_.code)] $($_.path)`r`n      $($_.reason)" }
        ($header + $body) | Set-Content -Path $failedLog -Encoding UTF8
    }
}

$verdict = if ($isFatal) { 'fatal' } elseif ($hasFailures) { 'partial' } else { 'complete' }
$elapsedText = if ($elapsedSec -lt 90) { "$([math]::Round($elapsedSec, 1)) s" }
               elseif ($elapsedSec -lt 5400) { "$([math]::Round($elapsedSec / 60, 1)) min" }
               else { "$([math]::Round($elapsedSec / 3600, 1)) h" }

# ── Output ───────────────────────────────────────────────────────────────────
if ($Json) {
    $result = [PSCustomObject]@{
        schema       = 'claude-mods.windows-ops.copy-tree/v1'
        verdict      = $verdict
        mode         = $Mode
        dryRun       = [bool]$DryRun
        source       = $srcArg
        destination  = $dstArg
        robocopyExit = $roboExit
        elapsedSec   = [math]::Round($elapsedSec, 1)
        failedCount  = $failures.Count
        transferLog  = $transferLog
        failedLog    = $(if ($failures.Count -gt 0) { $failedLog } else { $null })
        failures     = @($failures)
    }
    # Write-Output, not [Console]::Out — the latter writes straight to the console
    # handle, so `copy-tree.ps1 -Json | ConvertFrom-Json` would silently capture
    # nothing when dot-called inside a session. Still stdout-only either way.
    Write-Output ($result | ConvertTo-Json -Depth 5)
} else {
    $verdictState = switch ($verdict) { 'fatal' { 'FAILING' } 'partial' { 'WARN' } 'complete' { 'PASS' } }
    $verdictText  = switch ($verdict) {
        'fatal'    { 'fatal robocopy error — nothing reliable was transferred' }
        'partial'  { 'copy finished, some files could not be read' }
        'complete' { if ($DryRun) { 'dry-run complete' } else { 'copy complete' } }
    }

    Write-TermLine ''
    Write-TermLine (New-TermPanelOpen -Brand 'windows-ops' -Name 'windows-ops' -Subtitle 'copy-tree · results' -Indicator $elapsedText)
    Write-TermLine (New-TermPanelVert)
    Write-TermLine (New-TermSummary -Text "$verdictText · robocopy exit $roboExit")
    Write-TermLine (New-TermPanelVert)

    Write-TermLine (New-TermSection -State $verdictState -Label $verdict -Count -1)
    Write-TermLine (New-TermLeaf -Name 'elapsed' -Meta $elapsedText)
    Write-TermLine (New-TermLeaf -Name 'failed files' -Meta "$($failures.Count)")
    Write-TermLine (New-TermLeaf -Name 'transfer log' -Meta $transferLog -IsLast:($failures.Count -eq 0))
    if ($failures.Count -gt 0) {
        Write-TermLine (New-TermLeaf -Name 'error log' -Meta $failedLog -IsLast)
        # Name the first few inline — an operator should not have to open a file
        # to learn whether the failures matter.
        foreach ($f in ($failures | Select-Object -First 3)) {
            Write-TermLine (New-TermAlert -Severity warning -Text "$($f.path) — $($f.reason)")
        }
        if ($failures.Count -gt 3) {
            Write-TermLine (New-TermAlert -Severity warning -Text "...and $($failures.Count - 3) more — full list in $failedLog")
        }
        if ($Mode -eq 'Rescue') {
            Write-TermLine (New-TermAlert -Severity warning -Text 'Unreadable on a failing drive — consider ddrescue for bit-level recovery (see references/recovery-patterns.md)')
        } elseif ($failures | Where-Object { $_.code -in 5, 32 }) {
            Write-TermLine (New-TermAlert -Severity warning -Text 'Locked or access-denied files — retry with -Backup from an elevated shell, or close the holding process')
        }
    }
    Write-TermLine (New-TermPanelVert)

    $footerHealth = switch ($verdict) {
        'fatal'    { New-TermHealth -State 'critical' -Text 'fatal' }
        'partial'  { New-TermHealth -State 'warning' -Text "$($failures.Count) failed" }
        'complete' { New-TermHealth -State 'healthy' -Text 'complete' }
    }
    Write-TermLine (New-TermPanelClose -Hotkeys (New-TermHotkey -Key '?' -Verb 'help') -Healths $footerHealth)
}

# Distinct codes so a caller can tell "some files were locked" (10) from
# "the copy never happened" (1).
if ($isFatal)          { exit $script:EXIT_ERROR }
elseif ($hasFailures)  { exit 10 }
else                   { exit $script:EXIT_OK }
