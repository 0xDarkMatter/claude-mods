# net-ops :: windows/probe.ps1
# Full layered diagnostic ladder for Windows network troubleshooting.
# Designed to be invoked over SSH via -EncodedCommand. Outputs structured
# sections so a human or LLM can scan for the first FAIL and drill in.

param(
    [string]$TestHost = "google.com",
    [string[]]$TestIPs = @("1.1.1.1","8.8.8.8"),
    [int]$Timeout = 5,
    [switch]$Redact,
    [switch]$JsonOutput
)

# If -Redact, self-reinvoke without the switch and pipe output through a
# regex-driven redactor. Preserves Tailscale's well-known 100.100.100.100
# anchor and public DoH IPs as diagnostic landmarks.
if ($Redact) {
    $cleanArgs = @(
        '-TestHost', $TestHost,
        '-TestIPs', ($TestIPs -join ',')
        '-Timeout', $Timeout
    )
    if ($JsonOutput) { $cleanArgs += '-JsonOutput' }
    & powershell -NoProfile -File $PSCommandPath @cleanArgs |
        ForEach-Object {
            $line = $_
            $line = $line -replace '100\.100\.100\.100','__TS_MAGIC__'
            $line = $line -replace '\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b','10.X.X.X'
            $line = $line -replace '\b172\.(1[6-9]|2[0-9]|3[01])\.\d{1,3}\.\d{1,3}\b','172.X.X.X'
            $line = $line -replace '\b192\.168\.\d{1,3}\.\d{1,3}\b','192.168.X.X'
            $line = $line -replace '\b100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b','100.X.X.X'
            $line = $line -replace '\b169\.254\.\d{1,3}\.\d{1,3}\b','169.254.X.X'
            $line = $line -replace '\b[0-9a-fA-F]{2}([:-])[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\1[0-9a-fA-F]{2}\b','XX:XX:XX:XX:XX:XX'
            $line = $line -replace '\b[a-z0-9-]+\.ts\.net\b','REDACTED.ts.net'
            $line = $line -replace '__TS_MAGIC__','100.100.100.100'
            Write-Output $line
        }
    exit $LASTEXITCODE
}

$script:PASS_COUNT = 0
$script:FAIL_COUNT = 0
$script:FIRST_FAIL = ""
$script:CURRENT_SECTION = ""

function Section($name) {
    $script:CURRENT_SECTION = $name
    Write-Output ""
    Write-Output ("=== " + $name + " ===")
}
function Result($label, $ok, $detail = "") {
    if ($ok) {
        $script:PASS_COUNT++
        $tag = "PASS"
    } else {
        $script:FAIL_COUNT++
        if (-not $script:FIRST_FAIL) {
            $script:FIRST_FAIL = "[" + $script:CURRENT_SECTION + "] " + $label
        }
        $tag = "FAIL"
    }
    Write-Output ("[" + $tag + "] " + $label + $(if ($detail) { " :: " + $detail } else { "" }))
}

# ---------------------------------------------------------------------------
Section "1. LINK LAYER"
# ---------------------------------------------------------------------------
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
if (!$adapters) {
    Result "Any interface up" $false "No interfaces in Up state"
} else {
    $adapters | ForEach-Object {
        Result ("Interface " + $_.Name) $true ($_.LinkSpeed + ", MAC " + $_.MacAddress)
    }
}
$cfg = Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq "Up" }
$cfg | Format-Table InterfaceAlias, IPv4Address, IPv4DefaultGateway -AutoSize | Out-String | Write-Output

# ---------------------------------------------------------------------------
Section "2. IP / ICMP REACHABILITY"
# ---------------------------------------------------------------------------
$gateway = ($cfg | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
if ($gateway) {
    $r = Test-Connection $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
    Result ("Ping gateway $gateway") $r
}
foreach ($ip in $TestIPs) {
    $r = Test-Connection $ip -Count 2 -Quiet -ErrorAction SilentlyContinue
    Result ("Ping $ip") $r
}

# ---------------------------------------------------------------------------
Section "3. TCP/UDP SOCKET REACHABILITY"
# ---------------------------------------------------------------------------
foreach ($ip in $TestIPs) {
    $tcp53 = Test-NetConnection $ip -Port 53 -InformationLevel Quiet -WarningAction SilentlyContinue
    $tcp443 = Test-NetConnection $ip -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    Result ("TCP/53 -> $ip") $tcp53
    Result ("TCP/443 -> $ip") $tcp443
}

# Raw UDP/53 - bypasses DNS Client API, proves whether DNS protocol itself works.
foreach ($ip in $TestIPs) {
    try {
        $u = New-Object System.Net.Sockets.UdpClient
        $u.Client.ReceiveTimeout = ($Timeout * 1000)
        $u.Client.SendTimeout = ($Timeout * 1000)
        $u.Connect($ip, 53)
        # Minimal DNS query for google.com A record
        $q = [byte[]](0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x06,0x67,0x6f,0x6f,0x67,0x6c,0x65,0x03,0x63,0x6f,0x6d,0x00,0x00,0x01,0x00,0x01)
        [void]$u.Send($q, $q.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $u.Receive([ref]$ep)
        Result ("Raw UDP/53 -> $ip") $true ($resp.Length.ToString() + " bytes")
        $u.Close()
    } catch {
        Result ("Raw UDP/53 -> $ip") $false $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
Section "4. DNS INFRASTRUCTURE (bypass tools)"
# ---------------------------------------------------------------------------
foreach ($srv in @("default") + $TestIPs) {
    $cmd = if ($srv -eq "default") { "nslookup $TestHost" } else { "nslookup $TestHost $srv" }
    $out = Invoke-Expression $cmd 2>&1 | Out-String
    $resolved = $out -match "Addresses?:\s+(\d+\.\d+\.\d+\.\d+|[0-9a-f:]+)"
    Result ("nslookup via $srv") $resolved
    if (!$resolved) { Write-Output "  --- output ---"; $out | Select-String -Pattern "." | Select-Object -First 6 | ForEach-Object { Write-Output ("  " + $_) } }
}

# ---------------------------------------------------------------------------
Section "5. WINDOWS DNS CLIENT API (the hook layer)"
# ---------------------------------------------------------------------------
try {
    $r = Resolve-DnsName $TestHost -Type A -QuickTimeout -ErrorAction Stop
    $ips = ($r | Where-Object { $_.Type -eq "A" } | Select-Object -ExpandProperty IPAddress) -join ", "
    Result "Resolve-DnsName (system API)" $true $ips
} catch {
    Result "Resolve-DnsName (system API)" $false $_.Exception.Message
}

# If layer 4 passed but layer 5 failed, dump the NRPT - that's the prime suspect.
$nrptRules = Get-DnsClientNrptRule -ErrorAction SilentlyContinue
$catchAll = $nrptRules | Where-Object { $_.Namespace -eq "." }
if ($catchAll) {
    Write-Output "  !! Catch-all NRPT rule(s) detected (likely culprit):"
    $catchAll | Format-Table Name, NameServers, Comment -AutoSize | Out-String | Write-Output
}

# DNS Client service status
$dnsClient = Get-Service Dnscache -ErrorAction SilentlyContinue
Result "DNS Client (Dnscache) service running" ($dnsClient.Status -eq "Running")

# Port 53 listeners on the box itself
$listeners = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
if ($listeners) {
    Write-Output "  Port 53 listeners on localhost:"
    $listeners | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        $svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -eq $_.OwningProcess } | Select-Object -First 1
        Write-Output ("    " + $_.LocalAddress + ":53  PID=" + $_.OwningProcess + "  " + $p.ProcessName + $(if ($svc) { " (" + $svc.Name + ")" } else { "" }))
    }
}

# ---------------------------------------------------------------------------
Section "6. APPLICATION LAYER (real HTTP request)"
# ---------------------------------------------------------------------------
foreach ($url in @("https://www.google.com","https://github.com")) {
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec $Timeout -UseBasicParsing -ErrorAction Stop
        Result ("GET $url") $true ("HTTP " + $r.StatusCode + ", " + $r.RawContentLength + " bytes")
    } catch {
        Result ("GET $url") $false $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
Section "7. KNOWN VPN / DNS CLIENT FOOTPRINT"
# ---------------------------------------------------------------------------
# AV products (drives "Encrypted DNS Detection" type blocks)
$av = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
if ($av) { $av | Select-Object displayName, productState | Format-Table -AutoSize | Out-String | Write-Output }

# WFP-callout drivers (third-party kernel hooks on network stack)
$wfp = Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.State -eq "Running" -and ($_.Name -match "epfwwfp|wfpcap|netbtsmb|pctcore|symefa|mfewfpk|kvfwwfp|bdfwfpf|cbfsfilter")
}
if ($wfp) {
    Write-Output "  Third-party WFP/network drivers active:"
    $wfp | Format-Table Name, State, PathName -AutoSize | Out-String | Write-Output
}

# Known VPN clients (common NRPT rule creators)
$vpnPaths = @(
    "C:\Program Files\Proton\VPN",
    "C:\Program Files\Mullvad VPN",
    "C:\Program Files (x86)\OpenVPN",
    "C:\Program Files\WireGuard",
    "C:\Program Files (x86)\Cisco\Cisco AnyConnect Secure Mobility Client",
    "C:\Program Files\NordVPN",
    "C:\Program Files (x86)\NextDNS"
)
$found = $vpnPaths | Where-Object { Test-Path $_ }
if ($found) {
    Write-Output "  VPN / DNS clients installed:"
    $found | ForEach-Object { Write-Output ("    " + $_) }
}

Write-Output ""
Write-Output "=== SUMMARY ==="
Write-Output ("  PASS: " + $script:PASS_COUNT + "    FAIL: " + $script:FAIL_COUNT)
if ($script:FIRST_FAIL) {
    Write-Output ("  First failure: " + $script:FIRST_FAIL)
    $next = switch -Wildcard ($script:FIRST_FAIL) {
        "*LINK LAYER*"    { "check Get-NetAdapter, Get-NetIPConfiguration, DHCP state" }
        "*SOCKET*"        { "check Windows Firewall outbound rules; AV protocol filtering; consumer router DoH IP blocking" }
        "*ICMP*"          { "check Get-NetRoute, ISP/upstream connectivity" }
        "*DNS INFRASTRUCTURE*" { "check UDP/53 outbound, router DNS forwarder" }
        "*DNS CLIENT API*" { "scripts\\windows\\nrpt-audit.ps1   # drill rung 5 (the hook layer)" }
        "*RESOLVER PATH*"  { "scripts\\windows\\nrpt-audit.ps1   # drill rung 5 (the hook layer)" }
        "*APPLICATION*"   { "check netsh winhttp show proxy, cert store, IPv6 preference" }
        default { "re-run with -Verbose; check references/common-culprits.md" }
    }
    Write-Output ("  Next: " + $next)
} else {
    Write-Output "  No failures. If user still reports issues, see rung 7 footprint and time-based notes in references/diagnostic-ladder.md."
}
Write-Output ""
Write-Output "=== END PROBE ==="
