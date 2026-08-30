<#
.SYNOPSIS
    Triage runaway, orphaned and stale processes by CPU RATE, not by lineage.

.DESCRIPTION
    Samples every process's CPU twice across a window and reports the ones
    actually burning cycles right now, alongside commit/working-set cost and
    dead-parent orphans.

    Why rate and not lineage: a hung child of a LIVE parent is invisible to
    every "orphaned process" check, because its parent is alive. That is the
    normal shape of a stuck agent or editor session - it keeps its supervisor
    and spins forever. Rate finds it; lineage never will. See
    references/process-triage.md for the incident this encodes.

    This script NEVER terminates anything. It reports, and -Tree emits a
    leaves-first ordered list for the caller to act on deliberately. The
    process chain of THIS session is resolved up front and marked PROTECTED,
    so a caller cannot be walked into killing its own shell or agent host.

    Stdout is data only (a text table, or a JSON envelope under -Json).
    Stderr carries headers, progress and warnings.

.PARAMETER Name
    Limit sampling to these process names (no .exe). Default: all processes.

.PARAMETER Sample
    Seconds to sample CPU over. Default 10. Below 3 the rate is sampling noise.

.PARAMETER Threshold
    Flag a process burning at least this percent of ONE core. Default 20.

.PARAMETER Tree
    Enumerate the descendant tree of this PID instead of sampling. Emits
    leaves-first order with a commit total - the safe termination sequence.

.PARAMETER IncludeIdle
    Also emit processes below the threshold (survey mode).

.PARAMETER Json
    Emit the JSON envelope on stdout instead of a text table.

.PARAMETER Quiet
    Suppress stderr headers. Data still emits on stdout.

.PARAMETER Help
    Print usage with EXAMPLES to stdout and exit 0.

.EXAMPLE
    scripts/process-triage.ps1
    Sample every process for 10s; report anything above 20% of a core.

.EXAMPLE
    scripts/process-triage.ps1 -Name claude,node -Threshold 50
    Hunt hard-spinning agent processes only.

.EXAMPLE
    scripts/process-triage.ps1 -Json | ConvertFrom-Json
    Machine-readable findings for downstream triage.

.EXAMPLE
    scripts/process-triage.ps1 -Tree 35736
    Show what terminating PID 35736 would take with it, leaves-first.

.NOTES
    Exit codes (reflect whether triage RAN, plus one domain signal):
      0  ran clean, nothing at/above threshold
      2  usage error
      3  -Tree target not running
      5  precondition (not Windows / CIM unavailable)
     10  DOMAIN SIGNAL - flagged processes found
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [int]$Sample = 10,
    [double]$Threshold = 20,
    [int]$Tree = 0,
    [switch]$IncludeIdle,
    [switch]$Json,
    [switch]$Quiet,
    [switch]$Help
)

. "$PSScriptRoot\_lib\common.ps1"

if ($Help) {
    Write-Output 'process-triage.ps1 - find processes burning CPU now, by rate not lineage.'
    Write-Output ''
    Write-Output 'Usage:'
    Write-Output '  process-triage.ps1 [-Name <names>] [-Sample <sec>] [-Threshold <pct>]'
    Write-Output '                     [-IncludeIdle] [-Json] [-Quiet]'
    Write-Output '  process-triage.ps1 -Tree <pid> [-Json]'
    Write-Output '  process-triage.ps1 -Help'
    Write-Output ''
    Write-Output 'Options:'
    Write-Output '  -Name <n1,n2>     Limit to these process names (no .exe). Default: all.'
    Write-Output '  -Sample <sec>     CPU sampling window in seconds. Default 10, minimum 3.'
    Write-Output '  -Threshold <pct>  Flag at/above this percent of ONE core. Default 20.'
    Write-Output '  -Tree <pid>       Enumerate a descendant tree, leaves-first, with commit total.'
    Write-Output '  -IncludeIdle      Emit below-threshold rows too (survey mode).'
    Write-Output '  -Json             JSON envelope on stdout instead of a table.'
    Write-Output '  -Quiet            No stderr headers.'
    Write-Output ''
    Write-Output 'Exit:  0 clean | 2 usage | 3 no such tree | 5 precondition | 10 findings'
    Write-Output ''
    Write-Output 'EXAMPLES:'
    Write-Output '  process-triage.ps1'
    Write-Output '  process-triage.ps1 -Name claude,node -Threshold 50'
    Write-Output '  process-triage.ps1 -Json | ConvertFrom-Json'
    Write-Output '  process-triage.ps1 -Tree 35736'
    exit $script:EXIT_OK
}

# --- validation (agents fabricate plausible inputs) --------------------------
if ($Tree -le 0 -and $Sample -lt 3) {
    Write-Log FAIL '-Sample must be >= 3 seconds; below that the rate is sampling noise'
    exit $script:EXIT_USAGE
}
if ($Threshold -lt 0 -or $Threshold -gt 3200) {
    Write-Log FAIL '-Threshold must be between 0 and 3200 (percent of one core)'
    exit $script:EXIT_USAGE
}
if ($Tree -lt 0) {
    Write-Log FAIL '-Tree must be a positive PID'
    exit $script:EXIT_USAGE
}

try {
    $procTable = @(Get-CimInstance Win32_Process -ErrorAction Stop)
} catch {
    Write-Log FAIL 'Win32_Process unavailable - this script requires Windows with CIM/WMI'
    exit $script:EXIT_PRECONDITION
}

$byPid = @{}
foreach ($p in $procTable) { $byPid[[int]$p.ProcessId] = $p }

# --- self-ancestry: the guard that makes this output safe to act on ----------
# Walk THIS process up to the root and mark every ancestor PROTECTED. Killing an
# ancestor kills the session reading this output. That is the one mistake the
# tool must make structurally impossible rather than merely warn about, so the
# chain is computed before any reporting path can run.
$selfChain = New-Object 'System.Collections.Generic.HashSet[int]'
$cursor = $PID
for ($i = 0; $i -lt 32; $i++) {
    [void]$selfChain.Add($cursor)
    $node = $byPid[$cursor]
    if (-not $node) { break }
    $parent = [int]$node.ParentProcessId
    if ($parent -le 0 -or $parent -eq $cursor) { break }
    $cursor = $parent
}

function Get-Descendants {
    param([int]$Root)
    $out = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $frontier = @($Root)
    while ($frontier.Count -gt 0) {
        $next = New-Object System.Collections.ArrayList
        foreach ($proc in $procTable) {
            if ($frontier -contains [int]$proc.ParentProcessId) {
                $childPid = [int]$proc.ProcessId
                if ($seen.Add($childPid)) {
                    [void]$out.Add($proc)
                    [void]$next.Add($childPid)
                }
            }
        }
        $frontier = $next.ToArray()
    }
    return $out
}

function Get-TreeDepth {
    param([int]$Target, [int]$Root)
    $d = 0
    $c = $Target
    while ($c -ne $Root -and $d -lt 64) {
        $node = $byPid[$c]
        if (-not $node) { break }
        $c = [int]$node.ParentProcessId
        $d++
    }
    return $d
}

function Format-Cmd {
    param($Text, [int]$Max = 70)
    if (-not $Text) { return '' }
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -le $Max) { return $flat }
    return $flat.Substring(0, $Max)
}

$rows = New-Object System.Collections.ArrayList

if ($Tree -gt 0) {
    # --- TREE MODE ----------------------------------------------------------
    if (-not $byPid.ContainsKey($Tree)) {
        Write-Log FAIL "PID $Tree is not running"
        exit $script:EXIT_NOT_FOUND
    }
    if (-not $Quiet) { Write-Section "PROCESS TREE $Tree" }

    $members = @(Get-Descendants -Root $Tree) + @($byPid[$Tree])
    # Leaves-first: deepest descendants terminate before their supervisor, so a
    # still-live parent cannot respawn a child that was already reaped.
    $ordered = $members | Sort-Object @{ Expression = { Get-TreeDepth -Target ([int]$_.ProcessId) -Root $Tree } } -Descending

    $protectedHit = $false
    foreach ($m in $ordered) {
        $mp = [int]$m.ProcessId
        $isProtected = $selfChain.Contains($mp)
        if ($isProtected) { $protectedHit = $true }
        [void]$rows.Add([pscustomobject]@{
            pid        = $mp
            parent     = [int]$m.ParentProcessId
            name       = $m.Name
            commit_mb  = [math]::Round($m.PageFileUsage / 1KB, 0)
            depth      = (Get-TreeDepth -Target $mp -Root $Tree)
            protected  = $isProtected
            kill_order = ($rows.Count + 1)
            command    = (Format-Cmd $m.CommandLine)
        })
    }

    if (-not $Quiet) {
        $totalMb = ($rows | Measure-Object commit_mb -Sum).Sum
        Write-Log INFO ("tree of {0}: {1} process(es), {2} MB commit" -f $Tree, $rows.Count, $totalMb)
        if ($protectedHit) {
            Write-Log WARN "this tree contains THIS session's own process chain - rows with protected=True must not be terminated"
        }
    }
} else {
    # --- SAMPLE MODE --------------------------------------------------------
    if (-not $Quiet) { Write-Section "CPU RATE SAMPLE (${Sample}s)" }

    if ($Name) {
        $target = Get-Process -Name $Name -ErrorAction SilentlyContinue
    } else {
        $target = Get-Process -ErrorAction SilentlyContinue
    }
    if (-not $target) {
        Write-Log WARN 'no matching processes'
        if ($Json) {
            Write-Output '{"data":[],"meta":{"count":0,"findings":0,"mode":"sample","schema":"claude-mods.windows-ops.process-triage/v1"}}'
        }
        exit $script:EXIT_OK
    }

    $first = @{}
    foreach ($p in $target) { try { $first[$p.Id] = $p.CPU } catch { } }
    Start-Sleep -Seconds $Sample

    foreach ($id in @($first.Keys)) {
        $now = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $now) { continue }
        $before = $first[$id]
        if ($null -eq $before -or $null -eq $now.CPU) { continue }

        $delta = [double]$now.CPU - [double]$before
        $pct   = [math]::Round(($delta / $Sample) * 100, 1)
        $cim   = $byPid[$id]
        $ppid  = if ($cim) { [int]$cim.ParentProcessId } else { 0 }
        # A dead parent is reported but is never the primary signal: the spinner
        # class this tool exists for keeps a LIVE parent the whole time.
        $orphan = ($ppid -gt 0 -and -not $byPid.ContainsKey($ppid))
        $hot    = ($pct -ge $Threshold)
        if (-not ($hot -or $orphan -or $IncludeIdle)) { continue }

        $ageH = $null
        if ($cim -and $cim.CreationDate) {
            $ageH = [math]::Round(((Get-Date) - $cim.CreationDate).TotalHours, 1)
        }

        [void]$rows.Add([pscustomobject]@{
            pid         = $id
            parent      = $ppid
            name        = $now.ProcessName
            core_pct    = $pct
            cpu_total_s = [math]::Round([double]$now.CPU, 0)
            commit_mb   = $(if ($cim) { [math]::Round($cim.PageFileUsage / 1KB, 0) } else { 0 })
            age_hours   = $ageH
            orphan      = $orphan
            protected   = $selfChain.Contains($id)
            flagged     = ($hot -or $orphan)
            command     = $(if ($cim) { (Format-Cmd $cim.CommandLine) } else { '' })
        })
    }
    $rows = [System.Collections.ArrayList]@($rows | Sort-Object core_pct -Descending)
}

# --- output (stdout is the data product only) -------------------------------
$findings = @($rows | Where-Object { $_.PSObject.Properties['flagged'] -and $_.flagged })

if ($Json) {
    $envelope = [ordered]@{
        data = @($rows)
        meta = [ordered]@{
            count    = $rows.Count
            findings = $findings.Count
            mode     = $(if ($Tree -gt 0) { 'tree' } else { 'sample' })
            schema   = 'claude-mods.windows-ops.process-triage/v1'
        }
    }
    Write-Output ($envelope | ConvertTo-Json -Depth 5 -Compress)
} elseif ($Tree -gt 0) {
    Write-Data ('{0,-5} {1,-7} {2,-8} {3,-20} {4,9} {5,-9} {6}' -f 'ORDER', 'PID', 'PARENT', 'NAME', 'COMMITMB', 'PROTECTED', 'COMMAND')
    foreach ($r in $rows) {
        Write-Data ('{0,-5} {1,-7} {2,-8} {3,-20} {4,9} {5,-9} {6}' -f $r.kill_order, $r.pid, $r.parent, $r.name, $r.commit_mb, $r.protected, $r.command)
    }
} else {
    Write-Data ('{0,-7} {1,-8} {2,-18} {3,8} {4,9} {5,7} {6,-7} {7,-9} {8}' -f 'PID', 'PARENT', 'NAME', 'CORE%', 'COMMITMB', 'AGEH', 'ORPHAN', 'PROTECTED', 'COMMAND')
    foreach ($r in $rows) {
        Write-Data ('{0,-7} {1,-8} {2,-18} {3,8} {4,9} {5,7} {6,-7} {7,-9} {8}' -f $r.pid, $r.parent, $r.name, $r.core_pct, $r.commit_mb, $r.age_hours, $r.orphan, $r.protected, $r.command)
    }
}

if (-not $Quiet -and $Tree -le 0) {
    if ($findings.Count -gt 0) {
        Write-Log WARN ('{0} process(es) flagged at/above {1}% of a core' -f $findings.Count, $Threshold)
    } else {
        Write-Log PASS 'no process above threshold'
    }
}

if ($Tree -gt 0) { exit $script:EXIT_OK }
if ($findings.Count -gt 0) { exit 10 }
exit $script:EXIT_OK
