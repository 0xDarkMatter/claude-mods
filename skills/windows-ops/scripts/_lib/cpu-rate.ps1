# cpu-rate.ps1 - CPU rate from two process snapshots (windows-ops, process-triage.ps1).
# Dot-source: . "$PSScriptRoot\_lib\cpu-rate.ps1"
#
# Contract:
#   - Get-CpuSnapshot is the ONLY function here that touches processes: one Get-Process
#     enumeration per snapshot, never Get-Process -Id per PID. Each -Id lookup costs time
#     proportional to the whole process table, so a per-PID second pass on a ~1,200-process
#     box ran far longer than the sampling window.
#   - Measure-CpuRate is pure (snapshots in, rows out), so tests feed it synthetic snapshots
#     on any OS, including the Linux runners that skip the Windows runtime tier.
#   - The rate divides by each process's OWN elapsed time, measured with a stopwatch read
#     right before its CPU read, never by the nominal -Sample window. Dividing by -Sample
#     reported 5,135% of one core on a 32-thread machine (2026-10-26).
#   - A PID whose start time changed between snapshots is a different process (Windows
#     reuses PIDs quickly under churn) and is never reported.
# Snapshot shape: hashtable PID -> [pscustomobject]@{ Name; Cpu (s or $null); StartTicks
# (DateTime ticks or $null); Ts (Stopwatch ticks) }. Cpu and StartTicks are $null when
# access is denied (protected or elevated processes); such PIDs are skipped, not guessed.

function Get-CpuSnapshot {
    param([string[]]$Name)
    $procs = if ($Name) { Get-Process -Name $Name -ErrorAction SilentlyContinue } else { Get-Process -ErrorAction SilentlyContinue }
    $snap = @{}
    foreach ($p in $procs) {
        $start = $null; $cpu = $null
        try { $start = $p.StartTime.Ticks } catch { }
        # Timestamp immediately before the read: Process.TotalProcessorTime is live
        # (GetProcessTimes on each access), so this is the instant the value belongs to.
        $ts = [System.Diagnostics.Stopwatch]::GetTimestamp()
        try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch { }
        $snap[[int]$p.Id] = [pscustomobject]@{ Name = $p.ProcessName; Cpu = $cpu; StartTicks = $start; Ts = $ts }
    }
    return $snap
}

function Measure-CpuRate {
    # Rows: pid, core_pct (percent of ONE core), window_s (this PID's real elapsed
    # seconds), cpu_total_s. PIDs missing from After (exited), unreadable, reused, or
    # with a negative delta are skipped.
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][hashtable]$After,
        [long]$Frequency = [System.Diagnostics.Stopwatch]::Frequency
    )
    foreach ($id in @($Before.Keys)) {
        $a = $Before[$id]
        $b = $After[$id]
        if (-not $b) { continue }
        if ($null -eq $a.Cpu -or $null -eq $b.Cpu) { continue }
        if ($null -eq $a.StartTicks -or $a.StartTicks -ne $b.StartTicks) { continue }
        $window = ([double]$b.Ts - [double]$a.Ts) / $Frequency
        if ($window -le 0) { continue }
        $delta = [double]$b.Cpu - [double]$a.Cpu
        if ($delta -lt 0) { continue }
        [pscustomobject]@{
            pid         = [int]$id
            core_pct    = [math]::Round(($delta / $window) * 100, 1)
            window_s    = [math]::Round($window, 1)
            cpu_total_s = [double]$b.Cpu
        }
    }
}
