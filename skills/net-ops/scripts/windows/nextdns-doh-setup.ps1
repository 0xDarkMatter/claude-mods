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
    scripts/windows/nextdns-doh-setup.ps1 -ProfileId abc123 -Apply
    Apply, then verify. MUST be run from an ELEVATED PowerShell.

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
    [switch] $KeepClient,
    [switch] $Apply,
    [switch] $Rollback,
    [switch] $VerifyOnly
)

$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_USAGE = 2; $EXIT_PENDING = 10

function Say { param([string]$S,[string]$M) Write-Output ("  [{0,-4}] {1}" -f $S,$M) }
function Head { param([string]$N) Write-Output ""; Write-Output "--- $N ---" }

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ResetServerAddresses
        Say 'PASS' 'Adapter DNS reset to DHCP'

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
    Say 'INFO' "Adapter        : $InterfaceAlias  (currently: $current)"
    Say 'INFO' "DNS server     : $ServerAddress   (a label for the template - it does NOT select the profile)"
    Say 'INFO' "DoH template   : $template        (<- the PATH is what selects the profile)"
    Say 'INFO' 'UDP fallback   : DISABLED (a DoH failure must break loudly, never silently go unfiltered)'
    Say 'INFO' ("NextDNS client : {0}" -f $(if ($KeepClient) { 'left running (NOT recommended - both will fight)' } else { 'will be stopped + tray autostart removed' }))
    Say 'INFO' "Breadcrumb     : $BreadcrumbPath"

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

    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $ServerAddress
    Say 'PASS' "Adapter '$InterfaceAlias' DNS -> $ServerAddress"

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
