<#
.SYNOPSIS
    Audit the NextDNS Windows client for the boot-order pattern where the PC
    silently inherits the ROUTER's NextDNS profile for the first minutes of
    every boot, poisoning the DNS cache with that profile's blocks.

.DESCRIPTION
    The NextDNS Windows client (v3.x) does NOT bind port 53. It intercepts DNS
    in the kernel with a WFP callout driver (NextDNSEngine.sys) and rewrites
    queries to DoH. Two consequences drive this whole audit:

      - Adapter DNS is a RED HERRING. Get-DnsClientServerAddress will happily
        show the DHCP router address while every query is in fact leaving over
        DoH. Do not "fix" the adapter; it is not the signal.
      - There is no local resolver. Querying 127.0.0.1 times out BY DESIGN.
        That timeout is not the fault either.

    The real fault is a CONFIG SCOPE MISMATCH:

      - NextDNSService starts at BOOT, as LocalSystem, with NO profile ID.
      - The profile ID lives ONLY in the per-user tray config at
        %LOCALAPPDATA%\NextDNS\NextDNS.exe_Url_*\*\user.config
        (.NET MachineToLocalUser scope). There is no HKLM:\SOFTWARE\NextDNS.
      - NextDNS.exe (tray) starts at LOGON from a Run key and only THEN hands
        Enabled + Configuration to the service.

    So between boot and logon-plus-tray-init, interception is inert and every
    query goes to the DHCP resolver - typically the router, which may run its
    own, more restrictive NextDNS profile. Those answers (including blocks and
    NXDOMAIN) get CACHED. Interception then comes up correctly, but the
    poisoned entries survive their TTL. That is why a bare `ipconfig /flushdns`
    appears to "fix DNS", and why it is needed again after every single reboot.

    Discriminator that proves the config is already correct by the time you
    flush: query https://<random>.test.nextdns.io/ and read `clientName`.
    `nextdns-windows` means the client owns the query path RIGHT NOW, so the
    resolver config is fine and only the CACHE was stale. A router-shaped
    answer instead means interception genuinely is not active yet.

    Because the fault is a stale cache and not a broken resolver, the correct
    remedy is NOT delayed service start - that LENGTHENS the exposure window.
    See nextdns-boot-fix.ps1.

.PARAMETER SkipNetwork
    Do not contact test.nextdns.io. Local signals only. Use on a box where
    egress is untrusted, or when you only want the config-scope verdict.

.PARAMETER TimeoutSec
    Per-request timeout in seconds for the effective-profile probe. Default: 20.

.PARAMETER Json
    Emit a single machine-readable JSON envelope on stdout instead of
    [PASS]/[FAIL]/[WARN]/[INFO] rows.
    Schema: claude-mods.net-ops.nextdns-audit/v1

.EXAMPLE
    scripts/windows/nextdns-audit.ps1
    Full audit with the effective-profile probe.

.EXAMPLE
    scripts/windows/nextdns-audit.ps1 -SkipNetwork
    Config-scope + boot-window audit only, no egress.

.EXAMPLE
    scripts/windows/nextdns-audit.ps1 -Json | jq '.data.verdict'
    Machine-readable verdict only.

.NOTES
    Exit codes (per docs/SKILL-RESOURCE-PROTOCOL.md - they reflect whether the
    audit RAN and whether it FOUND anything, not whether DNS currently works):
      0  audit ran, no findings - no boot-order exposure detected
      1  unexpected error
      2  usage error
      10 audit ran and found the boot-order exposure pattern

    Self-contained by design (no dot-sourced libs): like probe.ps1 it must
    survive being shipped to a remote box as a single file over SSH via
    -EncodedCommand. Do not "refactor" it to source _lib/term.ps1.

    Never prints the NextDNS API key. The profile / configuration ID is NOT a
    secret and is shown deliberately - it is the whole point of the audit.
#>
[CmdletBinding()]
param(
    [switch] $SkipNetwork,
    [int]    $TimeoutSec = 20,
    [switch] $Json
)

$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_USAGE = 2; $EXIT_FINDINGS = 10

if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 120) {
    Write-Error "TimeoutSec must be 1..120"
    exit $EXIT_USAGE
}

$script:Findings = 0
$script:Rows     = New-Object System.Collections.Generic.List[object]
$script:Data     = [ordered]@{}

function Emit {
    param([string]$State, [string]$Section, [string]$Message)
    if ($State -eq 'FAIL' -or $State -eq 'WARN') { $script:Findings++ }
    $script:Rows.Add([ordered]@{ state = $State; section = $Section; message = $Message })
    if (-not $Json) { Write-Output ("  [{0,-4}] {1}" -f $State, $Message) }
}
function Section {
    param([string]$Name)
    if (-not $Json) { Write-Output ""; Write-Output "--- $Name ---" }
}

try {
    if (-not $Json) { Write-Output "=== net-ops :: NextDNS boot-order audit ===" }

    # -----------------------------------------------------------------------
    Section 'INSTALL STATE'
    # -----------------------------------------------------------------------
    $svc  = Get-Service NextDNSService -ErrorAction SilentlyContinue
    $drv  = Get-Service NextDNSEngine  -ErrorAction SilentlyContinue
    $tray = Get-Process NextDNS -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $svc) {
        Emit 'INFO' 'install' 'NextDNSService not present - NextDNS client not installed; this audit does not apply.'
        $script:Data.installed = $false
        if ($Json) {
            [ordered]@{
                schema = 'claude-mods.net-ops.nextdns-audit/v1'
                ok     = $true
                data   = $script:Data
                rows   = $script:Rows
            } | ConvertTo-Json -Depth 6
        }
        exit $EXIT_OK
    }
    $script:Data.installed = $true

    $svcKey  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NextDNSService' -ErrorAction SilentlyContinue
    $delayed = [bool]$svcKey.DelayedAutostart
    Emit $(if ($svc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'install' (
        "NextDNSService: Status={0} StartType={1} DelayedAutostart={2}" -f $svc.Status, $svc.StartType, $delayed)
    $script:Data.serviceStatus    = [string]$svc.Status
    $script:Data.serviceStartType = [string]$svc.StartType
    $script:Data.delayedAutostart = $delayed

    if ($delayed) {
        Emit 'WARN' 'install' 'DelayedAutostart is ON - this LENGTHENS the unprotected boot window. Wrong lever for this fault.'
    }

    $drvKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NextDNSEngine'
    if (Test-Path $drvKey) {
        $drvState = if ($drv) { [string]$drv.Status } else { 'registered, state unknown' }
        Emit $(if ($drv -and $drv.Status -eq 'Running') { 'PASS' } else { 'WARN' }) 'install' (
            "NextDNSEngine WFP driver: {0} (kernel interception - this is how DNS is captured, NOT port 53)" -f $drvState)
        $script:Data.wfpDriver = $drvState
    } else {
        Emit 'FAIL' 'install' 'NextDNSEngine WFP driver not registered - interception cannot work at all.'
        $script:Data.wfpDriver = 'absent'
    }

    # Port 53 is EXPECTED to be held by someone else (often SharedAccess/ICS
    # serving the Hyper-V Default Switch). That is NOT this bug. Say so loudly
    # so the next reader does not burn an hour on it.
    $u53 = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($u53) {
        $owner = (Get-Process -Id $u53.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Emit 'INFO' 'install' (
            "UDP/53 held by '{0}' (pid {1}) - EXPECTED and unrelated. NextDNS never binds 53." -f $owner, $u53.OwningProcess)
        $script:Data.port53Owner = $owner
    }

    # -----------------------------------------------------------------------
    Section 'CONFIG SCOPE  (the actual root cause)'
    # -----------------------------------------------------------------------
    $hklm = (Test-Path 'HKLM:\SOFTWARE\NextDNS') -or (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\NextDNS')
    $script:Data.machineWideConfig = $hklm

    $cfgFile = Get-ChildItem "$env:LOCALAPPDATA\NextDNS" -Recurse -Filter 'user.config' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $profileId = $null
    $enabled   = $null
    if ($cfgFile) {
        try {
            $xml      = [xml](Get-Content $cfgFile.FullName -Raw)
            $settings = $xml.configuration.userSettings.'NextDNS.Properties.Settings'.setting
            $profileId = ($settings | Where-Object { $_.name -eq 'Configuration' }).value
            $enabled   = ($settings | Where-Object { $_.name -eq 'Enabled' }).value
        } catch { }
    }
    $script:Data.profileId   = $profileId
    $script:Data.trayEnabled = $enabled

    if (-not $hklm -and $profileId) {
        Emit 'FAIL' 'config-scope' (
            "ROOT CAUSE: profile '{0}' exists ONLY in the per-user tray config; no machine-wide HKLM:\SOFTWARE\NextDNS." -f $profileId)
        Emit 'INFO' 'config-scope' 'The boot-time service therefore starts with NO profile and cannot intercept until the tray hands it over at LOGON.'
    } elseif ($hklm) {
        Emit 'PASS' 'config-scope' 'Machine-wide NextDNS config present - service can self-configure at boot.'
    } else {
        Emit 'WARN' 'config-scope' 'No profile ID found in either scope - client may never have been configured.'
    }

    # Tray autostart fires at LOGON, not boot. That gap IS the exposure window.
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    $trayAuto = $false
    foreach ($rk in $runKeys) {
        if (Test-Path $rk) {
            $props = (Get-ItemProperty $rk).PSObject.Properties | Where-Object { "$($_.Value)" -match 'NextDNS' }
            if ($props) { $trayAuto = $true }
        }
    }
    $script:Data.trayAutostartsAtLogon = $trayAuto
    if ($trayAuto) {
        Emit 'INFO' 'config-scope' 'Tray autostarts from a Run key - that fires at LOGON, strictly after boot. Boot..logon is the unprotected window.'
    }

    # -----------------------------------------------------------------------
    Section 'BOOT WINDOW'
    # -----------------------------------------------------------------------
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $script:Data.lastBoot = $boot.ToString('s')
    if ($tray -and $tray.StartTime) {
        $gap = [int]($tray.StartTime - $boot).TotalSeconds
        $script:Data.trayStart         = $tray.StartTime.ToString('s')
        $script:Data.exposureWindowSec = $gap
        Emit $(if ($gap -gt 30) { 'WARN' } else { 'INFO' }) 'boot-window' (
            "Boot {0:HH:mm:ss} -> tray start {1:HH:mm:ss} = {2}s of DNS resolved WITHOUT NextDNS interception." -f $boot, $tray.StartTime, $gap)
    } else {
        Emit 'INFO' 'boot-window' 'Tray process not running (or start time unavailable) - cannot measure the window.'
    }

    # Adapter DNS: report it, but label it a red herring so nobody "fixes" it.
    $ad = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.ServerAddresses.Count -gt 0 -and $_.InterfaceAlias -notmatch 'Loopback' }
    $script:Data.adapterDns = @($ad | ForEach-Object {
        [ordered]@{ interface = $_.InterfaceAlias; servers = @($_.ServerAddresses) }
    })
    foreach ($a in $ad) {
        Emit 'INFO' 'boot-window' (
            "Adapter '{0}' DNS = {1}  (RED HERRING while WFP interception is active - do not 'fix' this)" -f $a.InterfaceAlias, ($a.ServerAddresses -join ', '))
    }

    # -----------------------------------------------------------------------
    Section 'EFFECTIVE PROFILE'
    # -----------------------------------------------------------------------
    if ($SkipNetwork) {
        Emit 'INFO' 'effective' '-SkipNetwork set; effective-profile probe skipped.'
    } else {
        $alphabet = '0123456789abcdefghijklmnopqrstuvwxyz'
        $rand = -join ((1..20) | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
        try {
            $resp = Invoke-WebRequest -Uri "https://$rand.test.nextdns.io/" -UseBasicParsing -TimeoutSec $TimeoutSec
            $j    = $resp.Content | ConvertFrom-Json
            $script:Data.effective = [ordered]@{
                protocol   = $j.protocol
                profile    = $j.profile
                clientName = $j.clientName
                server     = $j.server
            }
            if ($j.clientName -eq 'nextdns-windows') {
                Emit 'PASS' 'effective' (
                    "Client owns the query path NOW: protocol={0} clientName={1} profile={2}" -f $j.protocol, $j.clientName, $j.profile)
                Emit 'INFO' 'effective' 'Config is CORRECT at this moment, so any failure you are chasing is a STALE CACHE, not a broken resolver. Flush, do not reconfigure.'
            } else {
                Emit 'FAIL' 'effective' (
                    "Query path is NOT the Windows client (clientName={0} protocol={1}) - interception inactive; router profile likely in effect." -f $j.clientName, $j.protocol)
            }
        } catch {
            Emit 'WARN' 'effective' ("Effective-profile probe failed: {0}" -f $_.Exception.Message)
        }
    }

    # -----------------------------------------------------------------------
    Section 'VERDICT'
    # -----------------------------------------------------------------------
    if (-not $hklm -and $profileId -and $trayAuto) {
        $verdict = 'BOOT-ORDER EXPOSURE: profile is per-user and the tray starts at logon, so boot..logon DNS resolves via DHCP (the router) and those answers get cached. Fix = flush the cache once interception is confirmed active (nextdns-boot-fix.ps1), or move the resolver config to machine scope via native DoH.'
    } elseif ($hklm) {
        $verdict = 'No config-scope gap detected.'
    } else {
        $verdict = 'Inconclusive - NextDNS client present but profile config not located.'
    }
    $script:Data.verdict = $verdict
    if (-not $Json) { Write-Output ""; Write-Output "  $verdict" }

    if (-not $Json) {
        Write-Output ""
        Write-Output ("  Findings: " + $script:Findings + $(if ($script:Findings -gt 0) { "  (exit 10)" } else { "  (exit 0)" }))
    } else {
        [ordered]@{
            schema = 'claude-mods.net-ops.nextdns-audit/v1'
            ok     = $true
            data   = $script:Data
            rows   = $script:Rows
        } | ConvertTo-Json -Depth 6
    }

    exit $(if ($script:Findings -gt 0) { $EXIT_FINDINGS } else { $EXIT_OK })
}
catch {
    Write-Error $_
    exit $EXIT_ERROR
}
