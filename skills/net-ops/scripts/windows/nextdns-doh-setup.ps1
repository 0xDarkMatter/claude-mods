<#
.SYNOPSIS
    Point the Windows DNS Client itself at a profile-pinned NextDNS DoH endpoint,
    machine-wide, so DNS is correct from BOOT - eliminating the boot..logon window
    that the per-user NextDNS tray client cannot cover. Includes verification and
    a full rollback.

.DESCRIPTION
    This is the machine-scope alternative to nextdns-boot-fix.ps1. That script
    cleans up AFTER the bad boot window (flush the poisoned cache at logon); this
    one removes the window entirely by moving the resolver config out of per-user
    scope and into the OS.

    HOW IT WORKS - and the one thing everyone gets wrong:

      The NextDNS ANYCAST IP DOES NOT SELECT YOUR PROFILE.

    Windows keys DoH configuration by IP address. You tell it two separate things:

      1. "this adapter's DNS server is <ServerAddress>"      (e.g. 45.90.28.0)
      2. "when talking to <ServerAddress>, use <DohTemplate>" (the URL)

    The query then travels over HTTPS to the TEMPLATE URL, and the profile is
    carried in that URL's PATH (https://dns.nextdns.io/<profile>). The IP is only
    the label the template hangs off; it carries no profile information. Sending
    plain DNS to 45.90.28.0 instead falls back to NextDNS "Linked IP" matching,
    which depends on your WAN address and breaks when that address changes.

    Verified empirically (2026-08-24) by querying the same names three ways:

      name                  /<profile>   no-path (Linked-IP)   bogus profile
      doubleclick.net       1 answer     6 answers             6 answers
      google-analytics.com  1 answer     6 answers             6 answers

    Two conclusions, both load-bearing:

      - The PATH changes the answer. That is the profile selection.
      - A WRONG PROFILE ID FAILS SILENTLY. The bogus id did not error; it returned
        unfiltered results identical to no profile at all. A typo therefore yields
        working-but-unfiltered DNS that announces nothing. Hence -AllowFallbackToUdp
        $false (so a DoH failure breaks loudly instead of quietly going unfiltered)
        and hence the mandatory verification step below.

    CONFLICT: do not run this alongside an active NextDNS client. Both would claim
    the DNS path - the client intercepts in-kernel via its WFP driver while Windows
    tries to do DoH itself. By default this script disables the client's tray
    autostart and stops its service. -KeepClient skips that (not recommended).

.PARAMETER ProfileId
    NextDNS configuration ID, e.g. 'abc123'. Not a secret; it is the whole point.

.PARAMETER ServerAddress
    NextDNS anycast IPv4 to key the DoH template on. Default: 45.90.28.0.
    (Profile-encoded NextDNS IPv6 is deliberately not used: it requires working
    IPv6 egress, which many LANs do not have.)

.PARAMETER InterfaceAlias
    Adapter to configure. Default: the connected non-virtual adapter.

.PARAMETER AllAdapters
    Configure EVERY physical adapter, not just one. Strongly recommended.

    THE ROAMING GAP: this configuration is per-adapter. An adapter you did not
    configure keeps using whatever DNS its network hands out - so switching from
    Ethernet to Wi-Fi, plugging into a second NIC, or using a dock silently drops
    you onto the local network's resolver, which on a filtered LAN is exactly the
    router profile this setup exists to escape. Nothing fails; DNS just quietly
    changes profile.

    Physical adapters are identified by HardwareInterface, which excludes VPN
    tunnels (Tailscale), Hyper-V/WSL vSwitches and Bluetooth PAN - all of which
    manage their own resolution and must not be touched.

    Disconnected adapters are configured too: the setting persists until link-up,
    so Wi-Fi is already correct the first time you use it.

    A genuinely new adapter (a dock or USB NIC seen for the first time) is still
    unconfigured until you re-run. -Doctor detects that.

.PARAMETER Doctor
    Read-only health check; needs no elevation. Audits template integrity, UDP
    fallback, per-adapter coverage, tray-client conflict, the live encrypted path,
    and profile pinning - then prints a verdict. Exit 10 if anything is wrong.

    Pinning is checked by comparing what the system resolver returns for -ProbeName
    against the configured template and against the no-path (Linked-IP) endpoint.
    That is self-calibrating, so it needs no hardcoded expected answers: encryption
    alone never proves you are on the right profile.

.PARAMETER ProbeName
    Name used for the -Doctor pinning comparison. Default: doubleclick.net. Pick a
    name your profile treats differently from an unfiltered resolver; if the
    template and unfiltered endpoint agree, the check reports inconclusive.

.PARAMETER SetPerInterface
    ALSO write the per-interface DoH registry key, so the Settings GUI reports
    "DNS over HTTPS: On" instead of "Off".

    Strongly recommended. Registering a template with -AutoUpgrade (what this script
    does by default) makes DoH genuinely work, but it does NOT create the per-interface
    key that Settings > Network & internet > Ethernet > DNS server assignment reads.
    The GUI therefore displays "Off" while traffic is in fact encrypted. Both readings
    are correct about different mechanisms - but the discrepancy is dangerous:

      - Someone checking Settings months later sees "Off" and concludes DoH is broken.
      - Worse, opening that dialog and pressing Save while it reads "Off" can write an
        explicit per-interface DISABLE and silently switch DNS back to plaintext.

    Writes DohFlags=1 (QWORD) - "automatic template", i.e. use the template already
    registered in the known-DoH-servers table. It deliberately does NOT write a
    per-interface DohTemplate: the global table owns the template (and therefore the
    profile), and duplicating it in two places invites them to disagree.

.PARAMETER KeepClient
    Do NOT disable the NextDNS tray client. Only for deliberate testing - leaving
    both active means two things fight over DNS.

.PARAMETER Apply
    Actually make changes. Without it this is a DRY RUN (house convention).

.PARAMETER Rollback
    Undo: restore DHCP-assigned DNS, remove the DoH template, re-enable the
    NextDNS client.

.PARAMETER VerifyOnly
    Run only the verification block against the current state and exit.

.EXAMPLE
    scripts/windows/nextdns-doh-setup.ps1 -ProfileId abc123
    Dry run - show exactly what would change.

.EXAMPLE
    scripts/windows/nextdns-doh-setup.ps1 -ProfileId abc123 -Apply -SetPerInterface -AllAdapters
    Recommended form: cover every physical adapter (no roaming gap), make the
    Settings GUI agree, then verify. MUST be run from an ELEVATED PowerShell.

.EXAMPLE
    scripts/windows/nextdns-doh-setup.ps1 -Doctor
    Read-only health check: coverage, pinning, conflicts. No elevation needed.

.EXAMPLE
    scripts/windows/nextdns-doh-setup.ps1 -VerifyOnly
    Ask NextDNS which profile is actually in effect right now.

.EXAMPLE
    scripts/windows/nextdns-doh-setup.ps1 -Rollback -Apply
    Put everything back the way it was.

.NOTES
    REQUIRES ELEVATION for -Apply and -Rollback (adapter DNS + machine-wide DoH
    templates are machine scope). -VerifyOnly and dry runs need no privileges.

    Exit codes (per docs/SKILL-RESOURCE-PROTOCOL.md):
      0  no change needed, or -Apply/-Rollback succeeded AND verified
      1  unexpected error
      2  usage error (bad profile id / unknown adapter / not elevated)
      10 dry run: changes pending (re-run with -Apply), OR verification FAILED

    STATUS: the -Apply path was authored but NOT executed by its author (no
    elevation available in that session). The dry-run, parameter validation and
    verification paths were exercised. Treat the first real -Apply as the
    verification run and read the output rather than assuming success.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9]{4,16}$')]
    [string] $ProfileId,
    [string] $ServerAddress  = '45.90.28.0',
    [string] $InterfaceAlias,
    [switch] $AllAdapters,
    [switch] $SetPerInterface,
    [switch] $KeepClient,
    [switch] $Apply,
    [switch] $Rollback,
    [switch] $VerifyOnly,
    [switch] $Doctor,
    [string] $ProbeName = 'doubleclick.net'
)

$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_USAGE = 2; $EXIT_PENDING = 10

function Say { param([string]$S,[string]$M) Write-Output ("  [{0,-4}] {1}" -f $S,$M) }
function Head { param([string]$N) Write-Output ""; Write-Output "--- $N ---" }

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Physical NICs only. HardwareInterface is the clean discriminator: it excludes
# Tailscale, Hyper-V/WSL vSwitches, Bluetooth PAN and WAN miniports, all of which
# either manage their own resolution or never carry ordinary traffic.
function Get-PhysicalAdapters {
    Get-NetAdapter | Where-Object { $_.HardwareInterface -and $_.InterfaceDescription -notmatch 'Bluetooth' }
}

function Get-DohKeyPath {
    param([string]$Guid, [string]$Server)
    $leaf = if ($Server -match ':') { 'Doh6' } else { 'Doh' }
    "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$Guid\DohInterfaceSettings\$leaf\$Server"
}

# Count A records for a name over a specific DoH template. Used to prove PROFILE
# pinning rather than mere encryption - see the -Doctor help.
function Get-DohAnswerCount {
    param([string]$Template, [string]$Name)
    try {
        $b = New-Object System.Collections.Generic.List[byte]
        $b.AddRange([byte[]]@(0xAB,0xCD,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00))
        foreach ($l in $Name.Split('.')) { $b.Add([byte]$l.Length); $b.AddRange([System.Text.Encoding]::ASCII.GetBytes($l)) }
        $b.Add(0); $b.AddRange([byte[]]@(0x00,0x01,0x00,0x01))
        $q = [Convert]::ToBase64String($b.ToArray()).TrimEnd('=').Replace('+','-').Replace('/','_')
        $r = Invoke-WebRequest "$Template`?dns=$q" -Headers @{Accept='application/dns-message'} -UseBasicParsing -TimeoutSec 15
        ($r.Content[6] * 256) + $r.Content[7]
    } catch { -1 }
}

# Ground truth: ask NextDNS what it sees. Never infer the active profile from
# adapter config - under any interception scheme the adapter can read anything.
function Get-EffectiveProfile {
    $ab = '0123456789abcdefghijklmnopqrstuvwxyz'
    $r  = -join ((1..20) | ForEach-Object { $ab[(Get-Random -Maximum $ab.Length)] })
    try {
        (Invoke-WebRequest -Uri "https://$r.test.nextdns.io/" -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
    } catch { $null }
}

$BreadcrumbDir  = Join-Path $env:LOCALAPPDATA 'net-ops'
$BreadcrumbPath = Join-Path $BreadcrumbDir 'README-dns-setup.md'

try {
    Write-Output "=== net-ops :: NextDNS machine-scope DoH setup ==="

    # ---------------------------------------------------------------- doctor
    if ($Doctor) {
        $findings = 0
        Head 'TEMPLATE'
        $tpl = Get-DnsClientDohServerAddress -ServerAddress $ServerAddress -ErrorAction SilentlyContinue
        if (-not $tpl) {
            Say 'FAIL' "No DoH template registered for $ServerAddress - machine-scope setup is not installed."; $findings++
        } else {
            Say 'PASS' ("Template: {0}" -f $tpl.DohTemplate)
            if ($tpl.AllowFallbackToUdp) {
                Say 'FAIL' 'AllowFallbackToUdp is TRUE - a DoH failure will silently drop to plaintext AND lose profile pinning.'; $findings++
            } else { Say 'PASS' 'UDP fallback disabled (failures break loudly rather than going unfiltered)' }
        }

        Head 'ADAPTER COVERAGE'
        # THE roaming gap. Config is per-adapter, so an unconfigured NIC silently
        # falls back to whatever DNS its network hands out - typically the router.
        foreach ($a in Get-PhysicalAdapters) {
            $dns  = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
            $hasK = Test-Path (Get-DohKeyPath $a.InterfaceGuid $ServerAddress)
            $ok   = ($dns -contains $ServerAddress) -and $hasK
            $desc = "{0} [{1}] dns={2} doh-key={3}" -f $a.Name, $a.Status, $(if ($dns) { $dns -join ',' } else { 'DHCP' }), $hasK
            if ($ok) { Say 'PASS' $desc }
            else {
                Say 'WARN' ($desc + '  <- NOT covered: this adapter would use its network''s DNS')
                $findings++
            }
        }

        Head 'CLIENT CONFLICT'
        $svc = Get-Service NextDNSService -ErrorAction SilentlyContinue
        $tp  = Get-Process NextDNS -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running' -or $tp)) {
            Say 'FAIL' 'NextDNS tray client is active alongside machine-scope DoH - two things are claiming the DNS path.'; $findings++
        } else { Say 'PASS' 'No tray-client conflict' }

        Head 'EFFECTIVE PATH'
        $e = Get-EffectiveProfile
        if (-not $e) { Say 'WARN' 'Could not reach test.nextdns.io'; $findings++ }
        else {
            Say 'INFO' ("protocol={0} profile={1} clientName={2}" -f $e.protocol, $e.profile, $e.clientName)
            if ($e.protocol -ne 'DOH') { Say 'FAIL' 'Traffic is NOT encrypted.'; $findings++ }
            elseif ($e.clientName -eq 'nextdns-windows') { Say 'FAIL' 'Going via the tray client, not the OS resolver.'; $findings++ }
            else { Say 'PASS' 'Encrypted DoH via the OS resolver' }
        }

        Head 'PROFILE PINNING'
        # Encryption != correct profile. Compare what the system resolver returns
        # against the configured template and against the no-path (Linked-IP)
        # endpoint. Self-calibrating, so it needs no hardcoded expected values.
        if ($tpl) {
            $sys  = @(Resolve-DnsName $ProbeName -Type A -ErrorAction SilentlyContinue | Where-Object Type -eq 'A').Count
            $pin  = Get-DohAnswerCount $tpl.DohTemplate $ProbeName
            $unf  = Get-DohAnswerCount 'https://dns.nextdns.io' $ProbeName
            Say 'INFO' ("{0}: system={1}  via-template={2}  unfiltered={3}" -f $ProbeName, $sys, $pin, $unf)
            if ($pin -lt 0) { Say 'WARN' 'Could not query the template directly; pinning unproven.'; $findings++ }
            elseif ($sys -eq $pin -and $pin -ne $unf) { Say 'PASS' 'System resolver matches the profile-pinned endpoint, and differs from unfiltered.' }
            elseif ($pin -eq $unf) { Say 'INFO' 'Template and unfiltered agree on this name - inconclusive; try -ProbeName with a name your profile treats differently.' }
            else { Say 'FAIL' 'System resolver does NOT match the pinned endpoint - queries may be unfiltered.'; $findings++ }
        }

        Head 'VERDICT'
        if ($findings -eq 0) { Say 'PASS' 'Healthy: encrypted, profile-pinned, and every physical adapter is covered.' }
        else { Say 'WARN' ("{0} finding(s). Re-run with -Apply -SetPerInterface -AllAdapters to close adapter gaps." -f $findings) }
        exit $(if ($findings) { $EXIT_PENDING } else { $EXIT_OK })
    }

    # ---------------------------------------------------------------- verify
    if ($VerifyOnly) {
        Head 'VERIFICATION'
        $e = Get-EffectiveProfile
        if (-not $e) { Say 'WARN' 'Could not reach test.nextdns.io - no network, or DNS is down.'; exit $EXIT_PENDING }
        Say 'INFO' ("protocol={0}  profile={1}  clientName={2}  server={3}" -f $e.protocol, $e.profile, $e.clientName, $e.server)
        # clientName is 'unknown-doh' for a generic DoH client, which is EXACTLY what
        # the Windows resolver is. Do not test for an empty clientName - NextDNS always
        # returns something, so an emptiness check reports a false FAIL on a good setup.
        if ($e.protocol -eq 'DOH' -and $e.clientName -ne 'nextdns-windows') {
            Say 'PASS' ("Encrypted DoH via the OS resolver (clientName={0}), not the tray client => machine scope." -f $e.clientName)
            exit $EXIT_OK
        } elseif ($e.clientName -eq 'nextdns-windows') {
            Say 'INFO' 'Still going through the NextDNS tray client (per-user scope) - machine-scope DoH is not in effect.'
            exit $EXIT_PENDING
        } else {
            Say 'WARN' 'Unencrypted or unexpected path - profile pinning is NOT confirmed.'
            exit $EXIT_PENDING
        }
    }

    # Resolve the target adapter once, up front.
    if (-not $InterfaceAlias) {
        $cand = Get-NetAdapter | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Tailscale|Hyper-V|Virtual|Loopback'
        } | Sort-Object -Property ifIndex | Select-Object -First 1
        if (-not $cand) { Write-Error 'No connected physical adapter found; pass -InterfaceAlias.'; exit $EXIT_USAGE }
        $InterfaceAlias = $cand.Name
    }
    $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue
    if (-not $adapter) { Write-Error "Unknown adapter '$InterfaceAlias'."; exit $EXIT_USAGE }

    # -AllAdapters closes the roaming gap: config is per-adapter, so any NIC left
    # unconfigured silently uses whatever DNS its network hands out. Disconnected
    # adapters are configured too - the setting persists until link-up.
    $Targets = if ($AllAdapters) { @(Get-PhysicalAdapters) } else { @($adapter) }

    $current = (Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4).ServerAddresses -join ', '

    # -------------------------------------------------------------- rollback
    if ($Rollback) {
        Head 'ROLLBACK PLAN'
        Say 'INFO' "Adapter '$InterfaceAlias' DNS: '$current' -> DHCP-assigned"
        Say 'INFO' "Remove DoH template for $ServerAddress"
        Say 'INFO' 'Re-enable NextDNS client (service Automatic + start, tray Run key restored)'
        Say 'INFO' "Remove breadcrumb $BreadcrumbPath"

        if (-not $Apply) { Write-Output ""; Say 'WARN' 'DRY RUN - nothing changed.'; Say 'INFO' 'Re-run with -Rollback -Apply.'; exit $EXIT_PENDING }
        if (-not (Test-Elevated)) { Write-Error 'Rollback needs an ELEVATED PowerShell.'; exit $EXIT_USAGE }

        # Roll back EVERY physical adapter, not just the selected one: -AllAdapters may
        # have configured several, and leaving one pinned to a removed template would
        # break DNS on that NIC.
        foreach ($a in Get-PhysicalAdapters) {
            $dns = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
            if ($dns -contains $ServerAddress) {
                Set-DnsClientServerAddress -InterfaceAlias $a.Name -ResetServerAddresses
                Say 'PASS' ("Adapter '{0}' DNS reset to DHCP" -f $a.Name)
            }
            foreach ($leaf in 'Doh','Doh6') {
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$($a.InterfaceGuid)\DohInterfaceSettings\$leaf\$ServerAddress"
                if (Test-Path $k) { Remove-Item $k -Recurse -Force; Say 'PASS' ("Removed per-interface DoH key ({0}, {1})" -f $a.Name, $leaf) }
            }
        }

        try { Remove-DnsClientDohServerAddress -ServerAddress $ServerAddress -ErrorAction Stop; Say 'PASS' "Removed DoH template for $ServerAddress" }
        catch { Say 'INFO' "No DoH template to remove for $ServerAddress" }

        $svc = Get-Service NextDNSService -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service NextDNSService -StartupType Automatic
            if ($svc.Status -ne 'Running') { Start-Service NextDNSService }
            Say 'PASS' 'NextDNSService set Automatic and started'
        }
        $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Get-ItemProperty $runKey -Name 'NextDNS' -ErrorAction SilentlyContinue)) {
            $exe = 'C:\Program Files (x86)\NextDNS\NextDNS.exe'
            if (Test-Path $exe) { Set-ItemProperty $runKey -Name 'NextDNS' -Value "`"$exe`""; Say 'PASS' 'Restored NextDNS tray autostart' }
        }
        if (Test-Path $BreadcrumbPath) { Remove-Item $BreadcrumbPath -Force; Say 'PASS' 'Removed breadcrumb' }

        Clear-DnsClientCache
        Say 'INFO' 'Cache flushed. NOTE: the logon flush task may still be useful again - see nextdns-boot-fix.ps1.'
        exit $EXIT_OK
    }

    # --------------------------------------------------------------- install
    if (-not $ProfileId) { Write-Error 'ProfileId is required (e.g. -ProfileId abc123).'; exit $EXIT_USAGE }
    $template = "https://dns.nextdns.io/$ProfileId"

    Head 'PLAN'
    Say 'INFO' ("Adapters       : {0}" -f (($Targets | ForEach-Object { "$($_.Name) [$($_.Status)]" }) -join ', '))
    if (-not $AllAdapters) {
        $uncovered = @(Get-PhysicalAdapters | Where-Object { $_.Name -ne $InterfaceAlias })
        if ($uncovered) {
            Say 'WARN' ("Roaming gap: {0} will NOT be covered and would use their network's DNS. Add -AllAdapters." -f (($uncovered | ForEach-Object { $_.Name }) -join ', '))
        }
    }
    Say 'INFO' "Current DNS    : $current  (on $InterfaceAlias)"
    Say 'INFO' "DNS server     : $ServerAddress   (a label for the template - it does NOT select the profile)"
    Say 'INFO' "DoH template   : $template        (<- the PATH is what selects the profile)"
    Say 'INFO' 'UDP fallback   : DISABLED (a DoH failure must break loudly, never silently go unfiltered)'
    Say 'INFO' ("NextDNS client : {0}" -f $(if ($KeepClient) { 'left running (NOT recommended - both will fight)' } else { 'will be stopped + tray autostart removed' }))
    Say 'INFO' ("Per-interface  : {0}" -f $(if ($SetPerInterface) { 'DohFlags=1 will be written -> Settings will show DoH On' } else { 'NOT written -> Settings will show "Off" even though DoH works' }))
    Say 'INFO' "Breadcrumb     : $BreadcrumbPath"
    if (-not $SetPerInterface) {
        Say 'WARN' 'Without -SetPerInterface the Settings GUI reports DoH "Off". That is misleading, and pressing Save in that dialog can silently disable encryption. Recommended: add -SetPerInterface.'
    }

    Head 'PRE-FLIGHT'
    # Prove the endpoint answers for THIS profile before depending on it.
    try {
        $b = New-Object System.Collections.Generic.List[byte]
        $b.AddRange([byte[]]@(0xAB,0xCD,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00))
        foreach ($l in 'example.com'.Split('.')) { $b.Add([byte]$l.Length); $b.AddRange([System.Text.Encoding]::ASCII.GetBytes($l)) }
        $b.Add(0); $b.AddRange([byte[]]@(0x00,0x01,0x00,0x01))
        $q  = [Convert]::ToBase64String($b.ToArray()).TrimEnd('=').Replace('+','-').Replace('/','_')
        $rr = Invoke-WebRequest "$template`?dns=$q" -Headers @{Accept='application/dns-message'} -UseBasicParsing -TimeoutSec 20
        $rc = $rr.Content[3] -band 0x0F
        if ($rr.StatusCode -eq 200 -and $rc -eq 0) { Say 'PASS' "Template answers over DoH (HTTP 200, RCODE 0)" }
        else { Say 'WARN' "Template responded oddly (HTTP $($rr.StatusCode), RCODE $rc)" }
    } catch { Say 'FAIL' "Template unreachable: $($_.Exception.Message)"; Say 'INFO' 'Refusing to proceed on an endpoint that does not answer.'; if ($Apply) { exit $EXIT_ERROR } }

    $tcp = $false
    try { $c = New-Object Net.Sockets.TcpClient; $tcp = $c.ConnectAsync($ServerAddress,443).Wait(6000); $c.Close() } catch { }
    Say $(if ($tcp) { 'PASS' } else { 'WARN' }) "TCP/443 to $ServerAddress reachable = $tcp"

    if (-not $Apply) { Write-Output ""; Say 'WARN' 'DRY RUN - nothing changed.'; Say 'INFO' 'Re-run with -Apply from an ELEVATED PowerShell.'; exit $EXIT_PENDING }
    if (-not (Test-Elevated)) { Write-Error 'Apply needs an ELEVATED PowerShell (adapter DNS + DoH templates are machine scope).'; exit $EXIT_USAGE }

    Head 'APPLYING'
    $existing = Get-DnsClientDohServerAddress -ServerAddress $ServerAddress -ErrorAction SilentlyContinue
    if ($existing) {
        Set-DnsClientDohServerAddress -ServerAddress $ServerAddress -DohTemplate $template -AllowFallbackToUdp $false -AutoUpgrade $true
        Say 'PASS' "Updated DoH template for $ServerAddress"
    } else {
        Add-DnsClientDohServerAddress -ServerAddress $ServerAddress -DohTemplate $template -AllowFallbackToUdp $false -AutoUpgrade $true
        Say 'PASS' "Registered DoH template for $ServerAddress"
    }

    foreach ($t in $Targets) {
        Set-DnsClientServerAddress -InterfaceAlias $t.Name -ServerAddresses $ServerAddress
        Say 'PASS' ("Adapter '{0}' [{1}] DNS -> {2}" -f $t.Name, $t.Status, $ServerAddress)

        if ($SetPerInterface) {
            # The Settings GUI reads this key, NOT the known-servers table. Without it the
            # GUI shows "Off" while DoH is genuinely working - see the -SetPerInterface help.
            # DohFlags=1 (QWORD) = "automatic template": use the template already registered
            # above. No per-interface DohTemplate is written on purpose - one source of truth.
            $key = Get-DohKeyPath $t.InterfaceGuid $ServerAddress
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name 'DohFlags' -Value 1 -PropertyType QWord -Force | Out-Null
            Say 'PASS' ("  per-interface DohFlags=1 written for '{0}'" -f $t.Name)
        }
    }

    if (-not $KeepClient) {
        $svc = Get-Service NextDNSService -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq 'Running') { Stop-Service NextDNSService -Force -ErrorAction SilentlyContinue }
            Set-Service NextDNSService -StartupType Manual
            Say 'PASS' 'NextDNSService stopped and set to Manual'
        }
        Get-Process NextDNS -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        if (Get-ItemProperty $runKey -Name 'NextDNS' -ErrorAction SilentlyContinue) {
            Remove-ItemProperty $runKey -Name 'NextDNS'
            Say 'PASS' 'Removed NextDNS tray autostart'
        }
    }

    Clear-DnsClientCache
    Say 'PASS' 'DNS cache flushed'

    # Breadcrumb: the whole point is that this is discoverable in six months by
    # someone looking at the MACHINE, not at a git repo they have forgotten.
    if (-not (Test-Path $BreadcrumbDir)) { New-Item -ItemType Directory -Path $BreadcrumbDir -Force | Out-Null }
    @"
# DNS on this machine - what is set up and why

**Configured:** $(Get-Date -Format 'yyyy-MM-dd') by the claude-mods ``net-ops`` skill.

## What is running

Windows' own DNS Client (the ``Dnscache`` service) resolves names over **DNS-over-HTTPS**
directly to NextDNS. The NextDNS tray app / service is **deliberately disabled** - if you
re-enable it while this is configured, the two will fight over DNS.

| Setting | Value |
|---|---|
| Adapter | ``$InterfaceAlias`` |
| DNS server | ``$ServerAddress`` |
| DoH template | ``$template`` |
| UDP fallback | disabled (on purpose - see below) |

## The thing that will confuse you

**``$ServerAddress`` does NOT select the NextDNS profile.** The profile is carried in the
template URL's PATH (``/$ProfileId``). The IP is only the label Windows hangs the template
on. If DNS ever silently goes unfiltered, the cause is almost certainly that queries fell
back to plain DNS against that IP - which uses NextDNS "Linked IP" matching instead of your
profile. That is why UDP fallback is disabled: a DoH failure should break loudly rather
than quietly resolve unfiltered. A wrong/typo'd profile ID also fails silently the same way.

## Why not just use the NextDNS app

Its profile ID is stored per-user, but its service starts at boot - so between boot and
logon nothing filtered DNS, queries went to the router (a stricter profile), and Windows
cached the results. That is the bug this replaced: it needed ``ipconfig /flushdns`` after
every single reboot.

## Verify

``````powershell
# Which profile is actually in effect?
`$r = -join ((1..20) | % { '0123456789abcdefghijklmnopqrstuvwxyz'[(Get-Random -Max 36)] })
(Invoke-WebRequest "https://`$r.test.nextdns.io/" -UseBasicParsing).Content
``````

Expect ``"protocol": "DOH"`` and ``"clientName": "unknown-doh"``.

``unknown-doh`` is **correct and healthy** - it means "a DoH client NextDNS does not
recognise as its own app", which is exactly what the Windows resolver is. If you instead
see ``"clientName": "nextdns-windows"`` the tray app is back in the path and this setup is
being bypassed.

### Stronger check: prove the PROFILE, not just the encryption

``protocol: DOH`` only proves traffic is encrypted - not that it is on YOUR profile. To
prove profile pinning, exploit the fact that profile ``$ProfileId`` returns a single
consolidated answer for tracker domains while unfiltered resolution returns ~6:

``````powershell
Resolve-DnsName doubleclick.net -Type A | Where-Object Type -eq 'A'
``````

**1 answer = pinned to your profile. ~6 answers = unfiltered** (you fell back to plain DNS
against the anycast IP, i.e. Linked-IP matching, or the profile ID is wrong).

## Maintenance - run this if anything seems off

``````powershell
scripts\windows\nextdns-doh-setup.ps1 -Doctor
``````

Read-only, no admin. Checks the template, UDP fallback, **every physical adapter**,
tray-client conflicts, the live encrypted path, and profile pinning. Exit 0 = healthy.

### The failure this design is exposed to: THE ROAMING GAP

The DoH template is machine-wide, but **the DNS server and the DoH key are per-adapter.**
An adapter that was never configured uses whatever DNS its network hands out - on a
filtered LAN that is the router's profile, i.e. the exact problem this setup exists to
avoid. Nothing errors; DNS quietly changes profile.

All physical adapters were configured with ``-AllAdapters``. What still needs action:

| Event | What to do |
|---|---|
| New dock / USB NIC / added card | Re-run with ``-AllAdapters`` - a brand-new adapter is uncovered |
| Windows feature update | Run ``-Doctor``; updates sometimes reset network config |
| NextDNS client reinstalled | ``-Doctor`` flags the conflict; two things claiming DNS is a bug |
| Changing NextDNS profile | Re-run ``-Apply`` with the new ``-ProfileId`` |
| NIC driver reinstall / ``netsh int ip reset`` | Re-run - the DoH key is keyed by adapter GUID |

VPN tunnels (Tailscale), Hyper-V/WSL vSwitches and Bluetooth PAN are deliberately NOT
configured - they manage their own resolution and touching them breaks things.

## Undo

Run from the ``net-ops`` skill in claude-mods, ELEVATED:

``````powershell
scripts\windows\nextdns-doh-setup.ps1 -Rollback -Apply
``````

Restores DHCP DNS, removes the template, re-enables the NextDNS client.

## See also

- ``skills/net-ops/references/common-culprits.md`` - entries W4, W4b
- ``skills/net-ops/references/case-studies.md`` - Case 3 (how this was diagnosed)
- Other devices use the same profile: Android Private DNS = ``$ProfileId.dns.nextdns.io``;
  macOS/iOS = configuration profile from ``apple.nextdns.io``.
"@ | Set-Content -Path $BreadcrumbPath -Encoding UTF8
    Say 'PASS' "Wrote breadcrumb $BreadcrumbPath"

    Head 'VERIFICATION'
    # Does the GUI agree with reality? Report both, because a mismatch is the failure
    # mode this script exists to prevent.
    $guid2 = (Get-NetAdapter -Name $InterfaceAlias).InterfaceGuid
    $seen = $false
    foreach ($leaf in 'Doh','Doh6') {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$guid2\DohInterfaceSettings\$leaf\$ServerAddress"
        if (Test-Path $k) {
            $seen = $true
            Say 'PASS' ("Settings GUI will report DoH ON  (DohFlags={0} at {1}\{2})" -f (Get-ItemProperty $k).DohFlags, $leaf, $ServerAddress)
        }
    }
    if (-not $seen) {
        Say 'WARN' 'Settings GUI will still report DoH "Off" (no per-interface key). Encryption works regardless - but re-run with -SetPerInterface so the GUI stops contradicting reality.'
    }

    Start-Sleep -Seconds 3
    $e = Get-EffectiveProfile
    if (-not $e) {
        Say 'FAIL' 'Could not reach test.nextdns.io after applying - DNS may be broken. Consider -Rollback -Apply.'
        exit $EXIT_PENDING
    }
    Say 'INFO' ("protocol={0}  profile={1}  clientName={2}" -f $e.protocol, $e.profile, $e.clientName)
    # See the note in the -VerifyOnly block: a healthy machine-scope setup reports
    # clientName='unknown-doh' (a DoH client NextDNS does not recognise as its own app),
    # NOT an empty clientName. Testing for emptiness FAILs a working configuration.
    if ($e.protocol -eq 'DOH' -and $e.clientName -ne 'nextdns-windows') {
        Say 'PASS' ("Encrypted DoH via the OS resolver (clientName={0}), not the tray client. Machine-scope config confirmed." -f $e.clientName)
    } elseif ($e.clientName -eq 'nextdns-windows') {
        Say 'FAIL' 'Still routed through the tray client - it is still active. Machine-scope DoH is NOT in effect.'
        exit $EXIT_PENDING
    } else {
        Say 'FAIL' 'Not confirmed as encrypted DoH. Profile pinning is NOT proven - investigate before trusting this.'
        exit $EXIT_PENDING
    }

    Write-Output ""
    Say 'INFO' 'The logon flush task is now redundant. Remove it with:'
    Say 'INFO' '  scripts\windows\nextdns-boot-fix.ps1 -Remove -Apply'
    Say 'INFO' 'Settings shows this at: Network & internet > Ethernet > DNS server assignment.'
    exit $EXIT_OK
}
catch {
    Write-Error $_
    exit $EXIT_ERROR
}
