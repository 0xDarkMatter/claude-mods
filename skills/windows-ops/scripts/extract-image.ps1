<#
.SYNOPSIS
    Extract files from a raw disk/partition image, read-only, without mounting.

.DESCRIPTION
    Companion to rescue-image.ps1: once a failing device has been imaged, the
    data must come back OUT of the image. On Windows that is harder than it
    looks — the native Mount-DiskImage handles VHD/VHDX/ISO only, and a raw
    PARTITION image has no partition table, so the usual "append a VHD footer"
    trick presents an uninitialised disk rather than a volume. Third-party
    volume mounters exist but are another install.

    7-Zip parses NTFS as an archive format: read-only, no driver, no mount, no
    write to the image, and it is already present on most systems. Measured at
    30-107 MB/s against a 7 TB image, which is adequate — the alternative was
    assumed to be faster without evidence.

    MODES
      -Plan      Per-subtree manifest (CSV) so a human can choose what to pull.
      -Extract   Extract -Include to -Dest. Supervised and resumable.
      -Verify    Reconcile the image's contents against what actually landed.

    RESUMABILITY: extraction passes 7z -aos (skip existing), so re-running the
    same command continues rather than restarting. The caveat that matters:
    -aos skips on EXISTENCE, not content, so a file interrupted mid-write is
    treated as done. -Verify detects those by size mismatch — run it before
    trusting a resumed extraction.

    PRIVACY: 7-Zip prints file names as it works. Every invocation is redirected
    to a log file and only aggregates reach stdout, so this can be driven by an
    agent or shared session without leaking the contents of someone's disk.
    Preserve that invariant if you extend it.

.PARAMETER Image
    Raw image produced by ddrescue/dd. Read-only throughout.

.PARAMETER Dest
    Extraction destination. Must not be inside the image's own volume if space
    is tight.

.PARAMETER Include
    7-Zip include patterns, image-relative (e.g. 'Users\*'). Required for
    -Extract; refuses to run bare so a whole image is never pulled by accident.

.PARAMETER ExcludeDirs
    Directory names excluded at ANY depth. See the LANDMINE note in the code —
    these are emitted as -xr! with bare names for a reason.

.PARAMETER ExcludeFiles
    Filename patterns excluded at any depth.

.PARAMETER StallMinutes
    Watchdog: relaunch a child whose destination has not grown in this long.

.EXAMPLE
    scripts/extract-image.ps1 -Image R:\rescue.img -Plan
    Build the subtree manifest, then read the CSV to decide what to extract.

.EXAMPLE
    scripts/extract-image.ps1 -Image R:\rescue.img -Dest R:\recovered -Include 'Users\*'
    Extract one subtree, resumable, with junk and credential exports excluded.

.EXAMPLE
    scripts/extract-image.ps1 -Image R:\rescue.img -Dest R:\recovered -Verify
    List what the image holds but the destination lacks (or holds short).

.NOTES
    Exit codes:
      0  ok        3 image/7-Zip/destination missing   4 nothing to do
      5  7-Zip not found                               9 7-Zip reported errors
#>
[CmdletBinding()]
param(
    # Not [Parameter(Mandatory)] — that makes a non-interactive run prompt, then
    # die with a generic exit 1. Validated below so a missing argument returns
    # the documented usage code instead.
    [string]$Image,
    [string]$Dest,
    [string]$WorkDir,
    [string[]]$Include = @(),
    # LANDMINE: emitted as -xr! with BARE names, never as '*\name\*'. The
    # wildcard form requires a leading path component, so it silently matches
    # nothing for directories at the image ROOT — which is exactly where this
    # kind of junk lives. That bug let 835,360 files through a run whose pattern
    # list looked perfectly correct. Verify any change against a root-level
    # entry, not just a nested one.
    [string[]]$ExcludeDirs = @(
        '$RECYCLE.BIN', 'System Volume Information', 'WindowsApps', 'WpSystem',
        'WUDownloadCache', '.dropbox.cache'
    ),
    # Plaintext credential exports. Excluded by default so a bulk extraction
    # cannot silently re-create secrets onto a new volume. If you need them,
    # pass -ExcludeFiles @() and handle the result as compromised material.
    [string[]]$ExcludeFiles = @(
        '*1password*export*', '*keepass*export*', '*bitwarden*export*',
        '*lastpass*export*', '*dashlane*export*'
    ),
    [switch]$Plan,
    [switch]$Extract,
    [switch]$Verify,
    [ValidateRange(1,1440)][int]$StallMinutes = 25,
    [ValidateRange(1,1000)][int]$MaxAttempts = 40,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib\common.ps1"

# ── locate 7-Zip (probe, never assume an install path) ───────────────────────
$sevenZip = $null
$cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
if ($cmd) { $sevenZip = $cmd.Source }
if (-not $sevenZip) {
    foreach ($c in @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\7zip\current\7z.exe')
    )) { if ($c -and (Test-Path $c)) { $sevenZip = $c; break } }
}
if (-not $sevenZip) { Write-Log -Level FAIL -Message '7z.exe not found (install 7-Zip, or add it to PATH)'; exit $script:EXIT_PRECONDITION }
if (-not $Image) {
    Write-Log -Level FAIL -Message '-Image is required. Usage: extract-image.ps1 -Image <raw.img> [-Plan | -Extract -Dest <dir> -Include <pattern> | -Verify -Dest <dir>]'
    exit $script:EXIT_USAGE
}
if (-not (Test-Path $Image)) { Write-Log -Level FAIL -Message "image not found: $Image"; exit $script:EXIT_NOT_FOUND }

if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetDirectoryName((Resolve-Path $Image).Path)) 'extract-work' }
New-Item -ItemType Directory $WorkDir -Force | Out-Null
$stamp    = (Get-Date).ToString('yyyyMMdd-HHmmss')
$listing  = Join-Path $WorkDir 'listing.txt'

function Get-Listing {
    # 7z `l` is cheap relative to extraction and only reads metadata, but it is
    # still a full MFT parse — cache it rather than re-running per mode.
    if (-not (Test-Path $listing) -or (Get-Item $listing).Length -eq 0) {
        Write-Log -Level INFO -Message 'building image listing (names go to the work dir, not stdout)'
        & $sevenZip l $Image > $listing 2>&1
    }
    return $listing
}

# 7z `l` fixed columns: 0..18 datetime | 20..24 attr | 26..37 size | 53.. name
function Read-Rows {
    param([string]$Path, [switch]$NonZeroOnly)
    $r = [IO.StreamReader]::new($Path)
    try {
        while ($null -ne ($l = $r.ReadLine())) {
            if ($l.Length -lt 54) { continue }
            if ($l[4] -ne '-' -or $l[7] -ne '-') { continue }
            $isDir = $l.Substring(20,5).Contains('D')
            $size = [long]0
            [void][long]::TryParse($l.Substring(26,12).Trim(), [ref]$size)
            if ($NonZeroOnly -and ($isDir -or $size -eq 0)) { continue }
            [PSCustomObject]@{ IsDir=$isDir; Size=$size; Path=$l.Substring(53) }
        }
    } finally { $r.Close() }
}

# ── PLAN ─────────────────────────────────────────────────────────────────────
if ($Plan) {
    $src = Get-Listing
    $agg = @{}
    foreach ($row in (Read-Rows -Path $src)) {
        $top = ($row.Path -split '\\')[0]
        if (-not $agg.ContainsKey($top)) { $agg[$top] = [PSCustomObject]@{ Subtree=$top; Files=0; Bytes=[long]0 } }
        if (-not $row.IsDir) { $agg[$top].Files++; $agg[$top].Bytes += $row.Size }
    }
    $csv = Join-Path $WorkDir 'manifest-subtrees.csv'
    $agg.Values | Sort-Object Bytes -Descending |
        Select-Object Subtree, Files, Bytes, @{n='GB';e={[math]::Round($_.Bytes/1GB,2)}} |
        Export-Csv $csv -NoTypeInformation -Encoding UTF8
    Write-Section 'plan'
    Write-Data "subtrees : $($agg.Count)"
    Write-Data "totalGB  : $([math]::Round((($agg.Values | Measure-Object Bytes -Sum).Sum)/1GB,2))"
    Write-Data "manifest : $csv   <- open this to choose subtrees"
    exit $script:EXIT_OK
}

# ── VERIFY ───────────────────────────────────────────────────────────────────
if ($Verify) {
    if (-not $Dest -or -not (Test-Path $Dest)) { Write-Log -Level FAIL -Message '-Dest required and must exist'; exit $script:EXIT_NOT_FOUND }
    $src = Get-Listing
    $want = [Collections.Generic.Dictionary[string,long]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in (Read-Rows -Path $src -NonZeroOnly)) { $want[$row.Path] = $row.Size }

    $root = (Resolve-Path $Dest).Path.TrimEnd('\') + '\'
    $missing = 0; $short = 0; $missBytes = [long]0
    $report = Join-Path $WorkDir "verify-$stamp.csv"
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($kv in $want.GetEnumerator()) {
        $full = Join-Path $Dest $kv.Key
        if (-not (Test-Path $full)) {
            $rows.Add([PSCustomObject]@{ SizeBytes=$kv.Value; Actual=0; Reason='Missing'; RelPath=$kv.Key })
            $missing++; $missBytes += $kv.Value
        } else {
            $len = (Get-Item $full).Length
            if ($len -lt $kv.Value) {
                $rows.Add([PSCustomObject]@{ SizeBytes=$kv.Value; Actual=$len; Reason='Short'; RelPath=$kv.Key })
                $short++
            }
        }
    }
    $rows | Sort-Object SizeBytes -Descending | Export-Csv $report -NoTypeInformation -Encoding UTF8
    Write-Section 'verify'
    Write-Data "expectedFiles : $($want.Count)   (non-zero only)"
    Write-Data "missingFiles  : $missing"
    Write-Data "shortFiles    : $short   <- interrupted writes skipped by -aos"
    Write-Data "missingGB     : $([math]::Round($missBytes/1GB,2))"
    Write-Data "report        : $report   <- names are here, on disk only"
    exit $script:EXIT_OK
}

# ── EXTRACT ──────────────────────────────────────────────────────────────────
if (-not $Extract) { Write-Log -Level FAIL -Message 'specify one of -Plan, -Extract, -Verify'; exit $script:EXIT_USAGE }
if (-not $Dest)    { Write-Log -Level FAIL -Message '-Dest is required for -Extract'; exit $script:EXIT_USAGE }
if (-not $Include) { Write-Log -Level FAIL -Message "-Include is required (e.g. -Include 'Users\*'); refusing to extract an entire image implicitly"; exit $script:EXIT_USAGE }
New-Item -ItemType Directory $Dest -Force | Out-Null

# Progress is measured by destination VOLUME used-bytes: O(1). Do NOT enumerate
# the destination tree to measure progress — at ~840k files that took 30 minutes
# per sample and contended for I/O with the extraction it was measuring.
function Get-DestUsed {
    $i = New-Object System.IO.DriveInfo (Split-Path $Dest -Qualifier)
    return [double]($i.TotalSize - $i.AvailableFreeSpace)
}
function Test-DestReady {
    $i = New-Object System.IO.DriveInfo (Split-Path $Dest -Qualifier)
    if (-not $i.IsReady) { return "destination volume not mounted" }
    if (-not (Test-Path $Dest)) { return "destination path missing" }
    return $null
}

$xargs = @('x', $Image, "-o$Dest", '-aos', '-bb0', '-bsp0', '-y') + $Include
foreach ($e in $ExcludeDirs)  { $xargs += "-xr!$e" }
foreach ($e in $ExcludeFiles) { $xargs += "-xr!$e" }

$startUsed = Get-DestUsed
$start = Get-Date
$done = $false; $stalls = 0

for ($i = 1; $i -le $MaxAttempts -and -not $done; $i++) {
    # A vanished destination must halt, not silently consume the retry budget —
    # a dismounted volume reports zero, which is indistinguishable from "no
    # progress" unless checked explicitly.
    $why = Test-DestReady
    if ($why) { Write-Log -Level FAIL -Message "halted: $why"; exit $script:EXIT_NOT_FOUND }

    $before = Get-DestUsed
    $log = Join-Path $WorkDir "extract-$stamp-$i.log"
    $p = Start-Process -FilePath $sevenZip -ArgumentList $xargs -PassThru -NoNewWindow `
                       -RedirectStandardOutput $log -RedirectStandardError "$log.err"

    $lastUsed = $before; $lastMove = Get-Date
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 30
        $now = Get-DestUsed
        if ([math]::Abs($now - $lastUsed) -gt 16MB) { $lastUsed = $now; $lastMove = Get-Date }
        elseif (((Get-Date) - $lastMove).TotalMinutes -ge $StallMinutes) {
            Write-Log -Level WARN -Message "watchdog: no write progress for $StallMinutes min — relaunching"
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
            break
        }
    }
    try { $p.WaitForExit(30000) | Out-Null } catch {}
    $rc = try { $p.ExitCode } catch { -1 }
    $gain = (Get-DestUsed) - $before
    Write-Log -Level INFO -Message "attempt ${i}: exit=$rc gained=$([math]::Round($gain/1MB,1)) MB"

    if ($rc -eq 0) { $done = $true; break }
    if ($gain -lt 1MB) { $stalls++ } else { $stalls = 0 }
    if ($stalls -ge 3) { Write-Log -Level WARN -Message 'stopping: repeated attempts made no progress'; break }
    Start-Sleep -Seconds 5
}

$totalGB = [math]::Round(((Get-DestUsed) - $startUsed)/1GB,2)
$errCount = 0
foreach ($f in (Get-ChildItem (Join-Path $WorkDir "extract-$stamp-*.log*") -ErrorAction SilentlyContinue)) {
    $errCount += (Select-String -Path $f.FullName -Pattern '^ERROR|Cannot open|Data Error|CRC Failed' -ErrorAction SilentlyContinue).Count
}

if ($Json) {
    [PSCustomObject]@{
        schema='claude-mods.windows-ops.extract-image/v1'; image=$Image; dest=$Dest
        complete=$done; addedGB=$totalGB; elapsedMin=[math]::Round(((Get-Date)-$start).TotalMinutes,1)
        errorLines=$errCount; workDir=$WorkDir
    } | ConvertTo-Json -Depth 4 | Write-Data
} else {
    Write-Section 'extract'
    Write-Data "complete   : $done"
    Write-Data "addedGB    : $totalGB"
    Write-Data "elapsedMin : $([math]::Round(((Get-Date)-$start).TotalMinutes,1))"
    Write-Data "errorLines : $errCount"
    Write-Data "workDir    : $WorkDir   <- names and per-file errors are here"
    Write-Data ''
    Write-Data 'next: re-run with -Verify to catch files skipped short by -aos'
}

if ($errCount -gt 0 -and -not $done) { exit $script:EXIT_ERROR }
exit $script:EXIT_OK
