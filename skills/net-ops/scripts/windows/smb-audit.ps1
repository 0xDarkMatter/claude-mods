<#
.SYNOPSIS
    Audit mapped SMB drives end-to-end: mapping state, name resolution
    mechanism, host reachability, credential targeting, and the VPN
    interference patterns (NRPT catch-all, DNS-leak-protection) that
    break LAN names while the internet keeps working.

.DESCRIPTION
    Companion to probe.ps1 for the "LAN services" track of the ladder
    (rung 3.5). probe.ps1 asks "can this box reach the internet?"; this
    script asks "can this box reach its own LAN by NAME?" — a different
    failure domain that internet-focused probing cannot express.

    For each mapped drive (or one selected with -DriveLetter) it reports:

      - Get-SmbMapping status + the HKCU:\Network\<letter> persistent entry
      - WHICH mechanism resolves the remote host (HOSTS / DNS / LLMNR-NetBIOS),
        or that all of them fail
      - if resolution fails: ICMP + TCP/445 against a last-known IP
        (from the DNS client cache, or supplied via -FallbackIp)
      - whether Credential Manager holds an entry whose TARGET matches the
        host actually in the UNC path — and flags the hostname-vs-IP
        target mismatch that presents as "System error 5 / Access denied"
      - an active NRPT '.' catch-all (Get-DnsClientNrptPolicy -Effective)
        with attribution and the owning VPN interface, live or orphaned
      - the DNS-leak-protection signature: raw UDP/53 to the LAN default
        gateway times out while ICMP/TCP to the same gateway succeeds
      - a verdict naming the specific fix (HOSTS pin vs nrpt-clean vs
        cmdkey re-target vs plain share/permission problem)

    Self-contained by design (no dot-sourced libs): like probe.ps1 it must
    survive being shipped to a remote box as a single file over SSH via
    -EncodedCommand. Do not "refactor" it to source _lib/term.ps1.

.PARAMETER DriveLetter
    Audit a single drive letter (e.g. 'Z'). Default: every SMB mapping.

.PARAMETER FallbackIp
    'HOST=IP' pairs giving a last-known IP for hosts that no longer
    resolve, e.g. -FallbackIp 'NAS=192.168.50.11'. Used for the
    ICMP/TCP-445 reachability test when every resolution mechanism fails
    and the DNS client cache has no stale answer to reuse.

.PARAMETER TimeoutSec
    Per-socket timeout in seconds. Default: 3.

.PARAMETER Json
    Emit a single machine-readable JSON envelope on stdout instead of
    [PASS]/[FAIL]/[WARN]/[INFO] rows.
    Schema: claude-mods.net-ops.smb-audit/v1

.EXAMPLE
    scripts/windows/smb-audit.ps1
    Audit every mapped drive.

.EXAMPLE
    scripts/windows/smb-audit.ps1 -DriveLetter Z -FallbackIp 'NAS=192.168.50.11'
    Audit Z: and, if 'NAS' no longer resolves, probe 192.168.50.11 directly.

.EXAMPLE
    scripts/windows/smb-audit.ps1 -Json | jq '.data.verdicts[]'
    Machine-readable verdicts only.

.NOTES
    Exit codes (per docs/SKILL-RESOURCE-PROTOCOL.md — they reflect whether
    the audit RAN and whether it FOUND anything, not share permissions):
      0  audit ran, no findings — mappings healthy
      1  unexpected error
      2  usage error (bad -DriveLetter / -FallbackIp syntax)
      10 audit ran and found at least one problem (see verdicts)

    Diagnosis notes baked in:
      - Resolve-DnsName on a SINGLE-LABEL name ('NAS') that fails reports
        the misleading "The filename, directory name, or volume label
        syntax is incorrect". That is a resolution failure, not a syntax
        problem. nslookup gives the honest "Non-existent domain" — prefer
        it when eyeballing single-label failures by hand.
      - An NRPT '.' catch-all captures single-label names too, and NRPT
        matching suppresses the LLMNR/NetBIOS broadcast fallback those
        names normally rely on. See references/diagnostic-ladder.md
        (rung 3.5) for the full resolution-order chain.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,
    [string[]]$FallbackIp = @(),
    [ValidateRange(1, 60)]
    [int]$TimeoutSec = 3,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_USAGE = 2; $EXIT_FINDINGS = 10

# --- output plumbing -------------------------------------------------------
# Text mode prints rows as it goes; JSON mode stays silent and dumps one
# envelope at the end. Findings (FAIL/WARN) drive the exit-10 domain signal.
$script:Rows = New-Object System.Collections.Generic.List[object]
$script:Findings = 0
$script:Section = ''

function Section($name) {
    $script:Section = $name
    if (-not $Json) { Write-Output ""; Write-Output ("=== " + $name + " ===") }
}
function Row($tag, $label, $detail = "") {
    if ($tag -in @('FAIL', 'WARN')) { $script:Findings++ }
    $script:Rows.Add([pscustomobject]@{
        section = $script:Section; tag = $tag; label = $label; detail = $detail
    })
    if (-not $Json) {
        Write-Output ("[" + $tag + "] " + $label + $(if ($detail) { " :: " + $detail } else { "" }))
    }
}

# --- parse -FallbackIp 'HOST=IP' pairs -------------------------------------
$fallbackMap = @{}
foreach ($pair in $FallbackIp) {
    if ($pair -notmatch '^([^=]+)=(\d{1,3}(\.\d{1,3}){3})$') {
        [Console]::Error.WriteLine("Bad -FallbackIp entry '$pair' — expected HOST=IPv4, e.g. NAS=192.168.50.11")
        exit $EXIT_USAGE
    }
    $fallbackMap[$Matches[1].ToUpper()] = $Matches[2]
}

# --- socket helpers ---------------------------------------------------------
function Test-TcpPort($ip, $port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutSec * 1000) -and $c.Connected
        $c.Close()
        return $ok
    } catch { return $false }
}
function Test-RawUdpDns($server) {
    # Hand-rolled DNS query (google.com A) over raw UDP — bypasses the DNS
    # Client API entirely, so it tests the WIRE, not the resolver policy.
    try {
        $u = New-Object System.Net.Sockets.UdpClient
        $u.Client.ReceiveTimeout = $TimeoutSec * 1000
        $u.Client.SendTimeout = $TimeoutSec * 1000
        $u.Connect($server, 53)
        $q = [byte[]](0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x06,0x67,0x6f,0x6f,0x67,0x6c,0x65,0x03,0x63,0x6f,0x6d,0x00,0x00,0x01,0x00,0x01)
        [void]$u.Send($q, $q.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $u.Receive([ref]$ep)
        $u.Close()
        return ($resp.Length -gt 0)
    } catch { return $false }
}

$verdicts = New-Object System.Collections.Generic.List[string]

try {

# ---------------------------------------------------------------------------
Section "ENVIRONMENT: NRPT / VPN"
# ---------------------------------------------------------------------------
# -Effective is the load-bearing flag: it shows what the resolver is USING
# right now (GPO + local + app-set merged), not just what is configured.
$nrptCatchAll = $null
try {
    $nrptCatchAll = Get-DnsClientNrptPolicy -Effective -ErrorAction Stop |
        Where-Object { $_.Namespace -eq '.' }
} catch {
    try { $nrptCatchAll = Get-DnsClientNrptRule | Where-Object { $_.Namespace -eq '.' } } catch {}
}

$vpnAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq 'Up' -and
    ($_.InterfaceDescription -match 'WireGuard|OpenVPN|TAP-|TUN|Proton|Mullvad|Nord|AnyConnect|Tailscale' -or
     $_.Name -match 'Proton|Mullvad|Nord|WireGuard|Tailscale|VPN')
})

$attribution = ''
if ($nrptCatchAll) {
    $ns = @($nrptCatchAll | ForEach-Object { $_.NameServers }) -join ', '
    $attribution = switch -Regex ($ns) {
        '^100\.100\.100\.100' { 'Tailscale MagicDNS' }
        '10\.2\.0\.'          { 'Proton VPN' }
        '10\.64\.0\.'         { 'Mullvad' }
        '10\.5\.0\.'          { 'NordVPN' }
        default               { 'unknown VPN' }
    }
    $ifaceNote = if ($vpnAdapters) {
        'owning interface likely: ' + (($vpnAdapters | ForEach-Object { $_.Name }) -join ', ') + ' (VPN is LIVE)'
    } else {
        'no VPN interface Up (ORPHANED rule — nrpt-clean.ps1 territory)'
    }
    # WARN not FAIL: a live, wanted VPN catch-all is legitimate — it only
    # becomes the culprit when a LAN name below fails to resolve.
    Row 'WARN' "NRPT '.' catch-all active" ("-> " + $ns + " (" + $attribution + "); " + $ifaceNote)
} else {
    Row 'PASS' "No NRPT '.' catch-all" "single-label names free to fall through to LLMNR/NetBIOS"
}

# ---------------------------------------------------------------------------
Section "ENVIRONMENT: LAN DNS EGRESS"
# ---------------------------------------------------------------------------
# The DNS-leak-protection signature: the VPN filters UDP/53 to anything but
# its own tunnel resolver. Gateway answers ICMP and TCP, but raw UDP/53
# times out — so there is NO fallback resolver even if you point at one.
# Filter unspecified next-hops: a live WireGuard/Proton tunnel installs an
# on-link default route with NextHop 0.0.0.0 that would otherwise win the
# metric sort. We want the REAL LAN gateway, whatever the VPN thinks.
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -notin '0.0.0.0', '::' } |
    Sort-Object RouteMetric | Select-Object -First 1).NextHop
$leakBlock = $false
if ($gw) {
    $gwIcmp = Test-Connection $gw -Count 1 -Quiet -ErrorAction SilentlyContinue
    $gwTcp = (Test-TcpPort $gw 53) -or (Test-TcpPort $gw 80) -or (Test-TcpPort $gw 443)
    $gwUdp53 = Test-RawUdpDns $gw
    if ($gwUdp53) {
        Row 'PASS' "UDP/53 to gateway $gw" "router DNS answers — fallback resolution available"
    } elseif ($gwIcmp -or $gwTcp) {
        $leakBlock = $true
        Row 'FAIL' "UDP/53 to gateway $gw BLOCKED (ICMP/TCP to it succeed)" "VPN DNS-leak-protection signature — LAN resolver unreachable"
    } else {
        Row 'WARN' "Gateway $gw unreachable entirely" "check link/routing first (probe.ps1 rungs 1-2)"
    }
} else {
    Row 'WARN' "No default gateway" "cannot test LAN DNS egress"
}

# ---------------------------------------------------------------------------
Section "SMB MAPPINGS"
# ---------------------------------------------------------------------------
$mappings = @(Get-SmbMapping -ErrorAction SilentlyContinue)
if ($DriveLetter) {
    $mappings = @($mappings | Where-Object { $_.LocalPath -eq ($DriveLetter.ToUpper() + ':') })
    if (-not $mappings) {
        [Console]::Error.WriteLine("No SMB mapping found for drive $($DriveLetter.ToUpper()):")
        exit $EXIT_USAGE
    }
}
if (-not $mappings) {
    Row 'INFO' 'No SMB mappings present' 'nothing to audit'
}

# cmdkey /list once, up front — targets look like "Target: Domain:target=NAS"
$credTargets = @()
try {
    $credTargets = @(cmdkey /list 2>$null | Select-String 'Target:' | ForEach-Object {
        ($_ -replace '^\s*Target:\s*', '') -replace '^(Domain|LegacyGeneric|WindowsLive):target=', ''
    })
} catch {}

$hostsFile = "$env:windir\System32\drivers\etc\hosts"
$hostsLines = @()
if (Test-Path $hostsFile) {
    $hostsLines = @(Get-Content $hostsFile | Where-Object { $_ -match '^\s*[^#]' })
}

$driveReports = New-Object System.Collections.Generic.List[object]

foreach ($m in $mappings) {
    $letter = ($m.LocalPath -replace ':', '')
    $remoteHost = ($m.RemotePath -split '\\')[2]
    $isIp = [ref]$null; $hostIsIp = [System.Net.IPAddress]::TryParse($remoteHost, $isIp)
    $singleLabel = (-not $hostIsIp) -and ($remoteHost -notmatch '\.')

    Section ("DRIVE " + $m.LocalPath + " -> " + $m.RemotePath)

    # -- mapping state + persistent registry entry ---------------------------
    if ($m.Status -eq 'OK') {
        Row 'PASS' "SmbMapping status" "$($m.Status)"
    } else {
        Row 'FAIL' "SmbMapping status" "$($m.Status)"
    }
    $regPath = "HKCU:\Network\$letter"
    $regRemote = $null
    if (Test-Path $regPath) {
        $regRemote = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).RemotePath
        $match = if ($regRemote -eq $m.RemotePath) { 'matches mapping' } else { "DIFFERS: '$regRemote'" }
        Row 'INFO' "Persistent entry $regPath" $match
    } else {
        Row 'INFO' "No HKCU:\Network\$letter entry" "mapping is non-persistent (session-only)"
    }

    # -- name resolution: WHICH mechanism works ------------------------------
    $resolvedVia = ''; $resolvedIp = $null
    if ($hostIsIp) {
        $resolvedVia = 'literal-ip'; $resolvedIp = $remoteHost
        Row 'PASS' "Host is a literal IP" $remoteHost
    } else {
        # 1. HOSTS — consulted before NRPT/DNS, so a pin here wins over any VPN
        $hostsHit = $hostsLines | Where-Object { $_ -match ('\s' + [regex]::Escape($remoteHost) + '(\s|$)') } | Select-Object -First 1
        if ($hostsHit) {
            $resolvedVia = 'HOSTS'
            $resolvedIp = ($hostsHit -split '\s+')[0]
            Row 'PASS' "Resolved via HOSTS file" ($resolvedIp + "  (wins over NRPT/DNS — VPN-proof)")
        }
        # 2. DNS proper (no HOSTS, no LLMNR/NetBIOS). Note: on failure for a
        #    single-label name this cmdlet throws the misleading "filename,
        #    directory name, or volume label syntax is incorrect" — that is a
        #    resolution failure, not bad syntax.
        if (-not $resolvedVia) {
            try {
                $r = Resolve-DnsName $remoteHost -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
                    Where-Object { $_.Type -in 'A', 'AAAA' } | Select-Object -First 1
                if ($r) {
                    $resolvedVia = 'DNS'; $resolvedIp = $r.IPAddress
                    Row 'PASS' "Resolved via DNS" $resolvedIp
                }
            } catch {
                Row 'INFO' "DNS resolution failed" $(if ($singleLabel) { "single-label name; error text is misleading — use nslookup for the honest NXDOMAIN" } else { $_.Exception.Message })
            }
        }
        # 3. LLMNR / NetBIOS broadcast — the fallback single-label LAN names
        #    normally rely on, and exactly what an NRPT '.' match suppresses.
        if (-not $resolvedVia) {
            try {
                $r = Resolve-DnsName $remoteHost -LlmnrNetbiosOnly -QuickTimeout -ErrorAction Stop |
                    Where-Object { $_.Type -in 'A', 'AAAA' } | Select-Object -First 1
                if ($r) {
                    $resolvedVia = 'LLMNR/NetBIOS'; $resolvedIp = $r.IPAddress
                    Row 'PASS' "Resolved via LLMNR/NetBIOS broadcast" $resolvedIp
                }
            } catch {}
        }
        if (-not $resolvedVia) {
            $detail = "HOSTS, DNS, and LLMNR/NetBIOS all failed"
            if ($nrptCatchAll -and $singleLabel) {
                $detail += " — NRPT '.' catch-all ($attribution) is swallowing this single-label name AND suppressing broadcast fallback"
            }
            Row 'FAIL' "Name '$remoteHost' does not resolve by ANY mechanism" $detail
        }
    }

    # -- reachability: resolved IP, or last-known IP when resolution failed --
    $probeIp = $resolvedIp
    $probeSource = 'resolved'
    if (-not $probeIp) {
        if ($fallbackMap.ContainsKey($remoteHost.ToUpper())) {
            $probeIp = $fallbackMap[$remoteHost.ToUpper()]; $probeSource = '-FallbackIp'
        } else {
            $cached = $null
            try {
                $cached = Get-DnsClientCache -Name $remoteHost -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
            } catch {}
            if ($cached) { $probeIp = $cached.Data; $probeSource = 'DNS cache (stale)' }
        }
    }
    $lanAlive = $false
    if ($probeIp) {
        $icmp = Test-Connection $probeIp -Count 1 -Quiet -ErrorAction SilentlyContinue
        $smb = Test-TcpPort $probeIp 445
        $lanAlive = $icmp -or $smb
        Row $(if ($icmp) { 'PASS' } else { 'WARN' }) "ICMP -> $probeIp ($probeSource)" ''
        Row $(if ($smb) { 'PASS' } else { 'FAIL' }) "TCP/445 (SMB) -> $probeIp" $(if ($smb) { 'share host is serving SMB' } else { 'SMB unreachable — host down, firewall, or wrong IP' })
    } elseif (-not $hostIsIp) {
        Row 'WARN' "No IP to probe" "resolution failed and no -FallbackIp '$remoteHost=<ip>' given; check arp -a for candidates"
    }

    # -- credential targeting -------------------------------------------------
    # Credential Manager keys on the TARGET string. A credential stored for
    # 'NAS' does NOT apply to '\\192.168.50.11\...' — remapping by IP then
    # fails with "System error 5 / Access is denied", which looks like a
    # permissions problem but is a credential-target-keying mismatch.
    $credForHost = $credTargets | Where-Object { $_ -ieq $remoteHost } | Select-Object -First 1
    $credForIp = if ($probeIp) { $credTargets | Where-Object { $_ -eq $probeIp } | Select-Object -First 1 } else { $null }
    if ($credForHost) {
        Row 'PASS' "Credential target matches host in UNC path" "'$credForHost'"
    } elseif ($credTargets.Count -gt 0) {
        $near = $credTargets | Where-Object { $_ -match [regex]::Escape($remoteHost) -or ($probeIp -and $_ -match [regex]::Escape($probeIp)) }
        if ($credForIp -and -not $hostIsIp) {
            Row 'WARN' "Credential keyed to IP '$credForIp', path uses name '$remoteHost'" "target mismatch — access by name will prompt/deny"
        } elseif ($near) {
            Row 'WARN' "No exact credential target for '$remoteHost'" ("near-misses: " + ($near -join ', '))
        } else {
            Row 'INFO' "No stored credential targets '$remoteHost'" "fine if the share allows the logged-in user or guest"
        }
    } else {
        Row 'INFO' "Credential Manager has no stored targets" ""
    }
    if ($hostIsIp -and $credTargets.Count -gt 0 -and -not $credForHost) {
        $byName = $credTargets | Where-Object { $_ -notmatch '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 3
        if ($byName) {
            Row 'WARN' "Path uses IP '$remoteHost' but credentials are keyed to hostnames" ("(" + ($byName -join ', ') + ") — the System-error-5 mismatch; fix: cmdkey /add:$remoteHost /user:<user> /pass")
        }
    }

    # -- per-drive verdict -----------------------------------------------------
    $verdict =
        if ($m.Status -eq 'OK' -and ($resolvedVia -or $hostIsIp)) {
            "$($m.LocalPath) healthy."
        } elseif (-not $hostIsIp -and -not $resolvedVia -and $nrptCatchAll -and $singleLabel -and $vpnAdapters -and $lanAlive) {
            "$($m.LocalPath): LIVE VPN ($attribution) NRPT catch-all is swallowing '$remoteHost'. LAN host is fine at $probeIp. Fix (coexistence, NOT nrpt-clean.ps1): pin in HOSTS as admin -> Add-Content `$env:windir\System32\drivers\etc\hosts '$probeIp  $remoteHost'  — or remap by IP AND add a matching credential: cmdkey /add:$probeIp"
        } elseif (-not $hostIsIp -and -not $resolvedVia -and $nrptCatchAll -and -not $vpnAdapters) {
            "$($m.LocalPath): ORPHANED NRPT catch-all (no VPN interface up) killing resolution of '$remoteHost'. Fix: scripts/windows/nrpt-clean.ps1 -Apply"
        } elseif (-not $hostIsIp -and -not $resolvedVia -and $lanAlive) {
            "$($m.LocalPath): '$remoteHost' unresolvable but host alive at $probeIp. Pin in HOSTS or remap by IP (add cmdkey for the IP first)."
        } elseif (-not $hostIsIp -and -not $resolvedVia) {
            "$($m.LocalPath): '$remoteHost' unresolvable and no live IP found. Confirm host is powered on; supply -FallbackIp '$remoteHost=<ip>' to retest."
        } elseif ($probeIp -and -not $lanAlive) {
            "$($m.LocalPath): resolves but $probeIp does not answer ICMP or TCP/445 — host down or SMB blocked, not a name problem."
        } else {
            "$($m.LocalPath): mapping $($m.Status) with name+network healthy — investigate credentials/permissions on the share side."
        }
    $verdicts.Add($verdict)

    $driveReports.Add([pscustomobject]@{
        drive = $m.LocalPath; remotePath = $m.RemotePath; status = "$($m.Status)"
        persistentEntry = $regRemote; host = $remoteHost; singleLabel = $singleLabel
        resolvedVia = $resolvedVia; resolvedIp = $resolvedIp
        probedIp = $probeIp; probeSource = $probeSource; lanAlive = $lanAlive
        credentialTargetMatch = [bool]$credForHost
    })
}

# ---------------------------------------------------------------------------
Section "VERDICT"
# ---------------------------------------------------------------------------
if ($leakBlock) {
    $verdicts.Add("Gateway UDP/53 is blocked by VPN DNS-leak-protection: there is NO fallback LAN resolver while the VPN is up. HOSTS-file pins are the only name fix that survives this.")
}
if (-not $Json) {
    if ($verdicts.Count -eq 0) { Write-Output "  Nothing to report." }
    foreach ($v in $verdicts) { Write-Output ("  * " + $v) }
    Write-Output ""
    Write-Output ("=== SUMMARY ===")
    Write-Output ("  Findings: " + $script:Findings + $(if ($script:Findings -gt 0) { "  (exit 10)" } else { "  (exit 0)" }))
}

if ($Json) {
    $envelope = [pscustomobject]@{
        data = [pscustomobject]@{
            nrptCatchAll = [bool]$nrptCatchAll
            nrptAttribution = $attribution
            vpnInterfacesUp = @($vpnAdapters | ForEach-Object { $_.Name })
            gatewayUdp53Blocked = $leakBlock
            drives = $driveReports
            rows = $script:Rows
            verdicts = $verdicts
        }
        meta = [pscustomobject]@{
            count = $driveReports.Count
            findings = $script:Findings
            schema = 'claude-mods.net-ops.smb-audit/v1'
        }
    }
    $envelope | ConvertTo-Json -Depth 6
}

exit $(if ($script:Findings -gt 0) { $EXIT_FINDINGS } else { $EXIT_OK })

} catch {
    if ($Json) {
        [pscustomobject]@{ error = [pscustomobject]@{ code = 'ERROR'; message = $_.Exception.Message } } | ConvertTo-Json -Depth 3
    }
    [Console]::Error.WriteLine("smb-audit.ps1 error: $($_.Exception.Message)")
    exit $EXIT_ERROR
}
