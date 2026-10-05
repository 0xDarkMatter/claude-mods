#!/usr/bin/env pwsh
# Outbound-connection ("phone-home") monitor for Windows - exfiltration tripwire.
#
# Maps every outbound TCP connection to its owning process, parent chain, and
# Authenticode signing status, then flags the patterns the 2026 npm-worm family
# (Shai-Hulud) exhibits after stealing credentials: interpreters (node/python)
# phoning out, processes living under node_modules or Temp, children of package
# managers, raw-IP destinations with no DNS name, and known IOC endpoints
# (assets/network-ioc.json). Prefers Sysmon Event ID 3 as the capture source
# when installed (-Sysmon); falls back to Get-NetTCPConnection polling.
#
# Usage:   phone-home-monitor.ps1 [MODE] [OPTIONS]
# Input:   live system state, or -InputJson <file> (replay/test fixture)
# Output:  stdout = findings only (TSV: severity rule process pid remote detail;
#          JSON envelope with -Json, schema claude-mods.supply-chain-defense.phone-home-monitor/v1)
# Stderr:  headers, progress, capture-source notes, errors
# Exit:    0 clean, 2 usage, 3 input-not-found, 5 missing-dep (Sysmon absent),
#          10 at-least-one-finding (medium+ severity; -Strict counts low too)
#
# Examples:
#   pwsh -NoProfile -File phone-home-monitor.ps1                  # one snapshot, rules applied
#   pwsh -NoProfile -File phone-home-monitor.ps1 -Json | jq '.data.findings[]'
#   pwsh -NoProfile -File phone-home-monitor.ps1 -Watch -IntervalSeconds 30 -DurationMinutes 60
#   pwsh -NoProfile -File phone-home-monitor.ps1 -Sysmon -MaxEvents 500   # preferred source
#   pwsh -NoProfile -File phone-home-monitor.ps1 -Status            # which capture sources exist?
#   pwsh -NoProfile -File phone-home-monitor.ps1 -InstallTask       # logon scheduled task (-Watch daemon)
#   pwsh -NoProfile -File phone-home-monitor.ps1 -InputJson fixtures/evil.json   # offline replay

[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$Json,
    [switch]$Quiet,
    [switch]$Strict,            # low-severity findings also trigger exit 10
    [switch]$Sysmon,            # tail Sysmon Event ID 3 instead of polling the TCP table
    [switch]$Status,            # report which capture sources are available on this host
    [switch]$Watch,             # continuous polling loop with ring-buffer JSONL log
    [switch]$InstallTask,       # register a logon scheduled task running -Watch
    [switch]$UninstallTask,
    [switch]$CheckDomainAge,    # RDAP lookup for recently-registered domains (network)
    [int]$IntervalSeconds = 30,
    [int]$DurationMinutes = 0,  # 0 = until Ctrl+C
    [int]$MaxEvents = 200,      # Sysmon mode: how many recent EID-3 events to read
    [int]$DomainAgeDays = 30,
    [string]$InputJson = '',
    [string]$Ioc = '',          # override assets/network-ioc.json
    [string]$LogPath = '',
    [int]$LogMaxMB = 10,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EXIT_OK = 0; $EXIT_USAGE = 2; $EXIT_NOT_FOUND = 3; $EXIT_MISSING_DEP = 5; $EXIT_FINDING = 10
$SCHEMA = 'claude-mods.supply-chain-defense.phone-home-monitor/v1'
$TASK_NAME = 'SupplyChain-PhoneHomeMonitor'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Shared terminal design system (skills/_lib/term.ps1) - colorized, ASCII-aware
# stderr framing; the TSV/--json data product stays plain on stdout. term.ps1
# honors NO_COLOR / FORCE_COLOR / TERM_ASCII. Degrade to plain if the lib is gone:
# this skill is copied standalone into other plugins with no skills/_lib beside it
# (pinned by the "standalone" block in tests/run.sh), so never dot-source it blindly.
$__scTermLib = Join-Path $ScriptDir '..\..\_lib\term.ps1'
if (Test-Path $__scTermLib) { . $__scTermLib; Initialize-Term }
else { function Get-TermColor { param($Token, $Text) return $Text } }

function Write-Info([string]$msg) { if (-not $Quiet) { [Console]::Error.WriteLine($msg) } }

function Show-Help {
    # Emit the first comment block (the contract) as help text.
    Get-Content $MyInvocation.PSCommandPath -TotalCount 28 |
        Where-Object { $_ -match '^#' -and $_ -notmatch '^#!' } |
        ForEach-Object { $_ -replace '^# ?', '' }
}

if ($Help) { Show-Help; exit $EXIT_OK }
if ($Rest) {
    if ($Rest -contains '--help' -or $Rest -contains '-h') { Show-Help; exit $EXIT_OK }
    [Console]::Error.WriteLine("ERROR: unknown argument(s): $($Rest -join ' ') (try --help)")
    exit $EXIT_USAGE
}
$modes = @(@($Sysmon, $Status, $Watch, $InstallTask, $UninstallTask, [bool]$InputJson) | Where-Object { $_ })
if ($modes.Count -gt 1) {
    [Console]::Error.WriteLine('ERROR: -Sysmon/-Status/-Watch/-InstallTask/-UninstallTask/-InputJson are mutually exclusive')
    exit $EXIT_USAGE
}
if (-not $LogPath) { $LogPath = Join-Path $env:LOCALAPPDATA 'supply-chain-defense\phone-home.jsonl' }

# ── IOC catalog ──────────────────────────────────────────────────────────────
$iocPath = if ($Ioc) { $Ioc } else { Join-Path (Split-Path -Parent $ScriptDir) 'assets\network-ioc.json' }
$iocDomains = @(); $iocIps = @()
if (Test-Path $iocPath) {
    try {
        $cat = Get-Content $iocPath -Raw | ConvertFrom-Json
        foreach ($e in $cat.entries) {
            if ($e.PSObject.Properties['domains']) { $iocDomains += @($e.domains | ForEach-Object { @{ value = $_.ToLower(); id = $e.id } }) }
            if ($e.PSObject.Properties['ips'])     { $iocIps     += @($e.ips     | ForEach-Object { @{ value = $_; id = $e.id } }) }
        }
    } catch {
        [Console]::Error.WriteLine("ERROR: IOC catalog unparseable: $iocPath - $($_.Exception.Message)")
        if ($Json) { Write-Output (@{ error = @{ code = 'VALIDATION'; message = "IOC catalog unparseable: $iocPath" } } | ConvertTo-Json -Compress) }
        exit 4
    }
} elseif ($Ioc) {
    [Console]::Error.WriteLine("ERROR: IOC catalog not found: $iocPath")
    exit $EXIT_NOT_FOUND
}

# ── classification constants ────────────────────────────────────────────────
$Interpreters = @('node', 'node.exe', 'python', 'python.exe', 'pythonw.exe', 'python3', 'deno', 'deno.exe', 'bun', 'bun.exe')
$PackageManagers = @('npm', 'npm.cmd', 'npx', 'npx.cmd', 'pnpm', 'pnpm.cmd', 'yarn', 'yarn.cmd', 'bun', 'bun.exe',
                     'pip', 'pip.exe', 'pip3.exe', 'uv', 'uv.exe', 'cargo', 'cargo.exe', 'composer', 'composer.bat',
                     'gem', 'gem.cmd', 'corepack', 'corepack.cmd')
$SuspiciousPathRe = '(?i)\\node_modules\\|\\AppData\\Local\\Temp\\|\\AppData\\Roaming\\npm-cache\\|\\Windows\\Temp\\'

function Test-PrivateIp([string]$ip) {
    if ($ip -match '^(127\.|10\.|192\.168\.|169\.254\.|0\.|255\.)' ) { return $true }
    if ($ip -match '^172\.(1[6-9]|2\d|3[01])\.') { return $true }
    if ($ip -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.') { return $true }  # CGNAT / Tailscale 100.64.0.0/10
    if ($ip -in @('::1', '::') -or $ip -match '^(fe80:|fc|fd)') { return $true }
    return $false
}

$sigCache = @{}
function Get-SignedStatus([string]$path) {
    if (-not $path -or -not (Test-Path $path)) { return 'unknown' }
    if ($sigCache.ContainsKey($path)) { return $sigCache[$path] }
    $s = try { (Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop).Status.ToString() } catch { 'unknown' }
    $v = if ($s -eq 'Valid') { 'signed' } elseif ($s -eq 'unknown') { 'unknown' } else { 'unsigned' }
    $sigCache[$path] = $v
    return $v
}

$rdapCache = @{}
function Get-DomainAgeDays([string]$hostname) {
    # Best-effort RDAP registration-age lookup; naive registrable-domain = last two labels.
    if (-not $hostname -or $hostname -notmatch '\.') { return $null }
    $labels = $hostname.ToLower().Split('.')
    $domain = ($labels | Select-Object -Last 2) -join '.'
    if ($rdapCache.ContainsKey($domain)) { return $rdapCache[$domain] }
    $age = $null
    try {
        $r = Invoke-RestMethod -Uri "https://rdap.org/domain/$domain" -TimeoutSec 5
        $reg = $r.events | Where-Object { $_.eventAction -eq 'registration' } | Select-Object -First 1
        if ($reg) { $age = [int]((Get-Date).ToUniversalTime() - [datetime]$reg.eventDate).TotalDays }
    } catch { Write-Info "  [rdap unavailable] $domain - domain age unknown (advisory only)" }
    $rdapCache[$domain] = $age
    return $age
}

# ── rules engine ─────────────────────────────────────────────────────────────
function Get-Findings($conn) {
    # $conn: processName, path, pid, parentChain (string[]), remoteAddress,
    #        remotePort, remoteHost, signed
    $f = [System.Collections.Generic.List[object]]::new()
    $name = ($conn.processName ?? '').ToLower()
    $path = $conn.path ?? ''
    $remote = "$($conn.remoteAddress):$($conn.remotePort)"
    $isInterp = $Interpreters -contains $name
    $parentHit = @($conn.parentChain | Where-Object { $PackageManagers -contains ($_ ?? '').ToLower() })
    $isPrivate = Test-PrivateIp $conn.remoteAddress

    $add = { param($sev, $rule, $detail)
        $f.Add([pscustomobject]@{
            time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            severity = $sev; rule = $rule
            process = $conn.processName; pid = $conn.pid; path = $path
            parent_chain = @($conn.parentChain)
            remote = $remote; remote_host = $conn.remoteHost
            signed = $conn.signed; detail = $detail
        })
    }

    # IOC endpoints match even on private/odd destinations
    $hostLower = ($conn.remoteHost ?? '').ToLower()
    foreach ($d in $iocDomains) {
        if ($hostLower -and ($hostLower -eq $d.value -or $hostLower.EndsWith('.' + $d.value))) {
            & $add 'high' 'ioc-endpoint' "destination matches IOC catalog entry $($d.id) ($($d.value))"
        }
    }
    foreach ($i in $iocIps) {
        if ($conn.remoteAddress -eq $i.value) { & $add 'high' 'ioc-endpoint' "destination IP matches IOC catalog entry $($i.id)" }
    }
    if ($isPrivate) { return $f }   # loopback/LAN: IOC check only

    if ($path -match $SuspiciousPathRe) {
        & $add 'high' 'suspicious-path' 'outbound connection from a binary under node_modules / Temp'
    }
    if ($parentHit.Count -gt 0) {
        & $add 'high' 'package-manager-child' "spawned by package manager: $($parentHit -join ' -> ') (lifecycle-script behaviour)"
    }
    if ($isInterp -and -not $conn.remoteHost) {
        & $add 'medium' 'interpreter-raw-ip' 'interpreter connecting to a raw public IP with no DNS name in cache'
    } elseif ($isInterp) {
        & $add 'low' 'interpreter-outbound' "interpreter outbound to $($conn.remoteHost) (informational; review if unexpected)"
    }
    if ($conn.signed -eq 'unsigned' -and $path -match '(?i)\\AppData\\|\\Downloads\\|\\node_modules\\') {
        & $add 'medium' 'unsigned-userland' 'unsigned binary in a user-writable path making outbound connections'
    }
    if ($CheckDomainAge -and $conn.remoteHost) {
        $age = Get-DomainAgeDays $conn.remoteHost
        if ($null -ne $age -and $age -lt $DomainAgeDays) {
            & $add 'high' 'young-domain' "domain registered ${age}d ago (< ${DomainAgeDays}d)"
        }
    }
    return $f
}

# ── capture sources ──────────────────────────────────────────────────────────
function Get-DnsMap {
    $m = @{}
    try {
        foreach ($e in (Get-DnsClientCache -ErrorAction Stop | Where-Object { $_.Type -in 1, 28 -and $_.Data })) {
            if (-not $m.ContainsKey($e.Data)) { $m[$e.Data] = $e.Entry.TrimEnd('.') }
        }
    } catch { }
    return $m
}

function Get-ProcMap {
    $m = @{}
    foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath)) {
        $m[[int]$p.ProcessId] = $p
    }
    return $m
}

function Get-ParentChain([int]$processId, $procMap) {
    $chain = [System.Collections.Generic.List[string]]::new()
    $cur = $processId; $seen = @{}
    for ($i = 0; $i -lt 6; $i++) {
        if (-not $procMap.ContainsKey($cur) -or $seen.ContainsKey($cur)) { break }
        $seen[$cur] = $true
        $ppid = [int]$procMap[$cur].ParentProcessId
        if (-not $procMap.ContainsKey($ppid) -or $ppid -eq $cur) { break }
        $chain.Add($procMap[$ppid].Name)
        $cur = $ppid
    }
    return $chain
}

function Get-SnapshotConnections {
    $procMap = Get-ProcMap
    $dnsMap = Get-DnsMap
    $out = [System.Collections.Generic.List[object]]::new()
    $tcp = Get-NetTCPConnection -State Established, SynSent -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -and $_.RemoteAddress -notin @('0.0.0.0', '::', '127.0.0.1', '::1') }
    $dedupe = @{}
    foreach ($c in $tcp) {
        $procId = [int]$c.OwningProcess
        $key = "$procId|$($c.RemoteAddress)|$($c.RemotePort)"
        if ($dedupe.ContainsKey($key)) { continue }
        $dedupe[$key] = $true
        $p = $procMap[$procId]
        $path = if ($p) { $p.ExecutablePath } else { '' }
        $out.Add([pscustomobject]@{
            processName = if ($p) { $p.Name } else { "pid:$procId" }
            path = $path; pid = $procId
            parentChain = @(Get-ParentChain $procId $procMap)
            remoteAddress = $c.RemoteAddress; remotePort = [int]$c.RemotePort
            remoteHost = $dnsMap[$c.RemoteAddress]
            signed = Get-SignedStatus $path
        })
    }
    return $out
}

function Test-SysmonPresent {
    try { $null = Get-WinEvent -ListLog 'Microsoft-Windows-Sysmon/Operational' -ErrorAction Stop; return $true } catch { return $false }
}

function Get-SysmonConnections {
    $procMap = Get-ProcMap
    $out = [System.Collections.Generic.List[object]]::new()
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Sysmon/Operational'; Id = 3 } -MaxEvents $MaxEvents -ErrorAction SilentlyContinue
    foreach ($ev in ($events ?? @())) {
        $x = [xml]$ev.ToXml()
        $d = @{}; foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
        if ($d['Initiated'] -ne 'true') { continue }
        $procId = [int]$d['ProcessId']
        $hostName = $d['DestinationHostname']
        $out.Add([pscustomobject]@{
            processName = Split-Path -Leaf ($d['Image'] ?? '')
            path = $d['Image']; pid = $procId
            parentChain = @(Get-ParentChain $procId $procMap)
            remoteAddress = $d['DestinationIp']; remotePort = [int]$d['DestinationPort']
            remoteHost = if ($hostName) { $hostName.TrimEnd('.') } else { $null }
            signed = Get-SignedStatus $d['Image']
        })
    }
    return $out
}

# ── output ───────────────────────────────────────────────────────────────────
function Write-Report($findings, [string]$source, [int]$connCount) {
    $counted = @($findings | Where-Object { $_.severity -in @('high', 'medium') -or ($Strict -and $_.severity -eq 'low') })
    if ($Json) {
        $env = @{
            data = @{ findings = @($findings); source = $source; connections_seen = $connCount }
            meta = @{ count = @($findings).Count; flagged = $counted.Count; strict = [bool]$Strict
                      schema = $SCHEMA; generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        }
        Write-Output ($env | ConvertTo-Json -Depth 6)
    } else {
        foreach ($f in $findings) {
            Write-Output ("{0}`t{1}`t{2}({3})`t{4}`t{5}" -f $f.severity, $f.rule, $f.process, $f.pid, $f.remote, $f.detail)
        }
    }
    Write-Info ''
    Write-Info "Source: $source - $connCount outbound connection(s) examined, $(@($findings).Count) finding(s), $($counted.Count) at medium+ severity."
    if ($counted.Count -gt 0) {
        Write-Info 'Triage: confirm the process is something you launched; check parent chain; if it is a'
        Write-Info 'package-manager child or IOC hit, treat as an incident - isolate, rotate credentials,'
        Write-Info 'run integrity-audit.sh + exposure-check.py. See references/phone-home-monitoring.md.'
    }
    if ($counted.Count -gt 0) { exit $EXIT_FINDING } else { exit $EXIT_OK }
}

# ── log ring buffer (2-file ring: .jsonl + .jsonl.1) ─────────────────────────
function Write-FindingLog($finding) {
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt $LogMaxMB * 1MB)) {
        Move-Item -Force $LogPath "$LogPath.1"
    }
    Add-Content -Path $LogPath -Value ($finding | ConvertTo-Json -Compress -Depth 6)
}

# ── modes ────────────────────────────────────────────────────────────────────
if ($Status) {
    $sysmonOk = Test-SysmonPresent
    $wfp = 'unknown (auditpol requires admin)'
    try {
        $a = auditpol /get /subcategory:'Filtering Platform Connection' 2>$null
        if ($LASTEXITCODE -eq 0 -and $a) { $wfp = (($a | Select-String 'Filtering Platform') -replace '\s{2,}', ' ').ToString().Trim() }
    } catch { }
    $fwLog = try { @(Get-NetFirewallProfile | Where-Object { $_.LogAllowed -eq 'True' }).Count } catch { 'unknown' }
    $task = try { [bool](Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue) } catch { $false }
    $rows = [ordered]@{
        sysmon_eid3        = if ($sysmonOk) { 'available (preferred source - use -Sysmon)' } else { 'not installed (see references/phone-home-monitoring.md to wire it)' }
        wfp_audit_5156     = $wfp
        firewall_log_allowed_profiles = $fwLog
        tcp_table_polling  = 'available (default source)'
        scheduled_task     = if ($task) { "installed ($TASK_NAME)" } else { 'not installed (-InstallTask)' }
        ioc_catalog        = "$iocPath ($(@($iocDomains).Count) domains, $(@($iocIps).Count) ips)"
        log_path           = $LogPath
    }
    if ($Json) {
        Write-Output (@{ data = $rows; meta = @{ count = $rows.Count; schema = $SCHEMA } } | ConvertTo-Json -Depth 4)
    } else {
        foreach ($k in $rows.Keys) { Write-Output ("{0}`t{1}" -f $k, $rows[$k]) }
    }
    exit $EXIT_OK
}

if ($InstallTask) {
    $pwshExe = (Get-Command pwsh).Source
    $scriptPath = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute $pwshExe `
        -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`" -Watch -Quiet -IntervalSeconds $IntervalSeconds -LogPath `"$LogPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger -Force | Out-Null
    Write-Info "Scheduled task '$TASK_NAME' registered (at logon, current user)."
    Write-Info "Findings ring-buffer: $LogPath (max ${LogMaxMB}MB x2). Start now: Start-ScheduledTask -TaskName $TASK_NAME"
    exit $EXIT_OK
}
if ($UninstallTask) {
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Write-Info "Scheduled task '$TASK_NAME' removed (if it existed)."
    exit $EXIT_OK
}

if ($InputJson) {
    if (-not (Test-Path $InputJson)) {
        [Console]::Error.WriteLine("ERROR: input file not found: $InputJson")
        exit $EXIT_NOT_FOUND
    }
    $fixture = Get-Content $InputJson -Raw | ConvertFrom-Json
    $conns = @($fixture.connections)
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $conns) { foreach ($f in (Get-Findings $c)) { $findings.Add($f) } }
    Write-Report $findings 'replay' $conns.Count
}

if ($Sysmon) {
    if (-not (Test-SysmonPresent)) {
        Write-Info 'ERROR: Sysmon is not installed - Event ID 3 (network connections) unavailable.'
        Write-Info 'Install it with a curated config (the preferred continuous source):'
        Write-Info '  winget install Microsoft.Sysinternals.Sysmon'
        Write-Info '  curl -o sysmonconfig.xml https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml'
        Write-Info '  sysmon64 -accepteula -i sysmonconfig.xml    # elevated prompt'
        Write-Info 'See references/phone-home-monitoring.md for the full evaluation.'
        exit $EXIT_MISSING_DEP
    }
    Write-Info (Get-TermColor cyan "=== phone-home monitor (Sysmon EID 3, last $MaxEvents events) ===")
    $conns = Get-SysmonConnections
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $conns) { foreach ($f in (Get-Findings $c)) { $findings.Add($f) } }
    Write-Report $findings 'sysmon-eid3' $conns.Count
}

if ($Watch) {
    Write-Info (Get-TermColor cyan "=== phone-home monitor (watch mode, every ${IntervalSeconds}s$(if ($DurationMinutes) { ", for ${DurationMinutes}m" })) ===")
    Write-Info "Findings log: $LogPath"
    $seen = @{}; $total = 0
    $deadline = if ($DurationMinutes -gt 0) { (Get-Date).AddMinutes($DurationMinutes) } else { [datetime]::MaxValue }
    while ((Get-Date) -lt $deadline) {
        foreach ($c in (Get-SnapshotConnections)) {
            $key = "$($c.pid)|$($c.remoteAddress)|$($c.remotePort)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            foreach ($f in (Get-Findings $c)) {
                if ($f.severity -in @('high', 'medium') -or $Strict) {
                    $total++
                    Write-FindingLog $f
                    Write-Info ("[{0}] {1} {2} {3}({4}) -> {5} : {6}" -f $f.time, $f.severity.ToUpper(), $f.rule, $f.process, $f.pid, $f.remote, $f.detail)
                }
            }
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    Write-Info "Watch ended: $total finding(s) logged to $LogPath"
    if ($total -gt 0) { exit $EXIT_FINDING } else { exit $EXIT_OK }
}

# default: one snapshot
Write-Info '=== phone-home monitor (TCP-table snapshot) ==='
if (-not (Test-SysmonPresent)) {
    Write-Info 'note: Sysmon not installed - polling misses short-lived connections. Prefer -Sysmon once wired.'
}
$conns = Get-SnapshotConnections
$findings = [System.Collections.Generic.List[object]]::new()
foreach ($c in $conns) { foreach ($f in (Get-Findings $c)) { $findings.Add($f) } }
Write-Report $findings 'tcp-table' $conns.Count
