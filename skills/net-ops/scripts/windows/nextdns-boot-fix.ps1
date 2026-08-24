<#
.SYNOPSIS
    Durably remove the NextDNS boot-order symptom by flushing the DNS cache
    once, at logon, after NextDNS interception is confirmed active - replacing
    the manual `ipconfig /flushdns` a human otherwise runs after every reboot.

.DESCRIPTION
    Companion remedy to nextdns-audit.ps1. Read that script's DESCRIPTION for
    the mechanism; the short version:

      The NextDNS profile ID lives only in the per-user tray config, so
      NextDNSService starts at BOOT with no profile and cannot intercept until
      NextDNS.exe hands it over at LOGON. In that gap DNS resolves via DHCP -
      typically the router, possibly running a more restrictive NextDNS
      profile - and Windows CACHES those answers, blocks included. Once the
      client takes over, the resolver path is correct but the poisoned cache
      entries survive their TTL.

    Because the surviving fault is a STALE CACHE and not a broken resolver, the
    minimal correct remedy is to invalidate the cache once, after interception
    is up. This script installs a per-user logon scheduled task that does
    exactly that and nothing more.

    WHY NOT the other candidate fixes:

      - Automatic (Delayed Start) on NextDNSService: WRONG DIRECTION. The race
        is not against the network stack, it is against USER LOGON. Delaying
        the service lengthens the unprotected window.
      - A service dependency on the network stack: irrelevant for the same
        reason - the missing prerequisite is the per-user tray handing over a
        profile, not link-up.
      - Pinning static adapter DNS at the client's resolver: there IS no local
        resolver. The client intercepts via a WFP callout, never binds 53.
        Adapter DNS is cosmetic while interception is active.

    ELEVATION: none required. Clear-DnsClientCache and `ipconfig /flushdns`
    both succeed unelevated, and the task is registered for the current user at
    LeastPrivilege.

    A machine-scope alternative that removes the exposure window entirely
    (rather than cleaning up after it) is documented in
    references/common-culprits.md - it needs admin, so it is deliberately not
    automated here.

    Installs the runner to a STABLE location, %LOCALAPPDATA%\net-ops\, on
    purpose: this skill is often checked out in a disposable git worktree, and
    a scheduled task must not point into a directory that can vanish.

.PARAMETER Apply
    Actually install. Without this the script is a DRY RUN and only reports
    what it would do (house convention for repair scripts in this skill).

.PARAMETER Remove
    Uninstall the scheduled task and delete the installed runner.

.PARAMETER MaxWaitSec
    How long the logon task waits for NextDNS interception to be confirmed
    before flushing anyway. Default: 180.

.PARAMETER TaskName
    Scheduled task name. Default: 'net-ops NextDNS boot flush'.

.EXAMPLE
    scripts/windows/nextdns-boot-fix.ps1
    Dry run - show what would be installed.

.EXAMPLE
    scripts/windows/nextdns-boot-fix.ps1 -Apply
    Install the logon task.

.EXAMPLE
    scripts/windows/nextdns-boot-fix.ps1 -Remove -Apply
    Uninstall the task and remove the runner.

.NOTES
    Exit codes (per docs/SKILL-RESOURCE-PROTOCOL.md):
      0  nothing to do, or -Apply succeeded
      1  unexpected error
      2  usage error
      10 dry run: changes are pending (re-run with -Apply)

    Verification after install:
      Get-ScheduledTask 'net-ops NextDNS boot flush' | Get-ScheduledTaskInfo
      Start-ScheduledTask 'net-ops NextDNS boot flush'   # exercise it now
      Get-Content "$env:LOCALAPPDATA\net-ops\nextdns-boot-flush.log" -Tail 20

    Full verification requires a real reboot: the boot..logon window cannot be
    faithfully simulated from a running session.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $Remove,
    [int]    $MaxWaitSec = 180,
    [string] $TaskName = 'net-ops NextDNS boot flush'
)

$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_USAGE = 2; $EXIT_PENDING = 10

if ($MaxWaitSec -lt 10 -or $MaxWaitSec -gt 900) {
    Write-Error "MaxWaitSec must be 10..900"
    exit $EXIT_USAGE
}
if ([string]::IsNullOrWhiteSpace($TaskName)) {
    Write-Error "TaskName must not be empty"
    exit $EXIT_USAGE
}

$InstallDir = Join-Path $env:LOCALAPPDATA 'net-ops'
$RunnerPath = Join-Path $InstallDir 'nextdns-boot-flush.ps1'
$LogPath    = Join-Path $InstallDir 'nextdns-boot-flush.log'

function Say { param([string]$S, [string]$M) Write-Output ("  [{0,-4}] {1}" -f $S, $M) }

# The runner. Kept deliberately small and dependency-free: it waits for
# evidence that NextDNS owns the query path, then invalidates the cache once.
$RunnerBody = @'
# net-ops :: NextDNS boot flush runner  (installed by nextdns-boot-fix.ps1)
#
# WHY THIS EXISTS
#   The NextDNS profile ID lives only in the per-user tray config, so
#   NextDNSService starts at boot with no profile and cannot intercept DNS
#   until NextDNS.exe hands it over at logon. Queries in that window resolve
#   via DHCP (the router, possibly a stricter NextDNS profile) and Windows
#   caches the answers - blocks included. The resolver path self-corrects; the
#   CACHE does not. This flushes it once, after interception is confirmed.
#
# Do not "optimise" the wait away: flushing before interception is up simply
# re-poisons the cache from the router on the next query.
param([int] $MaxWaitSec = __MAXWAIT__)

$log = Join-Path $env:LOCALAPPDATA 'net-ops\nextdns-boot-flush.log'
function Log { param([string]$m) "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m | Add-Content -Path $log -Encoding UTF8 }

Log "--- run start (MaxWaitSec=$MaxWaitSec) ---"

$deadline  = (Get-Date).AddSeconds($MaxWaitSec)
$confirmed = $false
$reason    = 'timeout'

while ((Get-Date) -lt $deadline) {
    $svc = Get-Service NextDNSService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        # Local signal: the service holds an established outbound TLS session,
        # i.e. its DoH upstream is actually up (not merely "service started").
        $proc = Get-Process NextDNSService -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $est = Get-NetTCPConnection -OwningProcess $proc.Id -State Established -ErrorAction SilentlyContinue |
                   Where-Object { $_.RemotePort -eq 443 }
            if ($est) { $confirmed = $true; $reason = 'DoH upstream established'; break }
        }
    }
    Start-Sleep -Seconds 3
}

if ($confirmed) { Log "interception confirmed ($reason)" }
else            { Log "WARN: interception NOT confirmed within ${MaxWaitSec}s - flushing anyway (harmless)" }

try {
    Clear-DnsClientCache -ErrorAction Stop
    Log 'DNS cache flushed (Clear-DnsClientCache)'
} catch {
    Log "Clear-DnsClientCache failed: $($_.Exception.Message) - falling back to ipconfig"
    & ipconfig /flushdns | Out-Null
    Log 'DNS cache flushed (ipconfig /flushdns)'
}

# Best-effort confirmation of which profile now owns the query path. Never
# fatal: no network at logon is normal and must not fail the task.
try {
    $ab = '0123456789abcdefghijklmnopqrstuvwxyz'
    $r  = -join ((1..20) | ForEach-Object { $ab[(Get-Random -Maximum $ab.Length)] })
    $j  = (Invoke-WebRequest -Uri "https://$r.test.nextdns.io/" -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
    Log ("effective: protocol={0} clientName={1} profile={2}" -f $j.protocol, $j.clientName, $j.profile)
} catch {
    Log "effective-profile probe skipped/failed: $($_.Exception.Message)"
}

Log '--- run end ---'
exit 0
'@ -replace '__MAXWAIT__', $MaxWaitSec

try {
    Write-Output "=== net-ops :: NextDNS boot-order fix ==="
    Write-Output ""

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    # ----------------------------------------------------------------- remove
    if ($Remove) {
        if (-not $existing -and -not (Test-Path $RunnerPath)) {
            Say 'INFO' 'Nothing installed - nothing to remove.'
            exit $EXIT_OK
        }
        if (-not $Apply) {
            if ($existing)               { Say 'WARN' "DRY RUN: would unregister scheduled task '$TaskName'" }
            if (Test-Path $RunnerPath)   { Say 'WARN' "DRY RUN: would delete $RunnerPath" }
            Write-Output ""
            Say 'INFO' 'Re-run with -Remove -Apply to perform the removal.'
            exit $EXIT_PENDING
        }
        if ($existing) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Say 'PASS' "Unregistered scheduled task '$TaskName'"
        }
        if (Test-Path $RunnerPath) {
            Remove-Item $RunnerPath -Force
            Say 'PASS' "Deleted $RunnerPath"
        }
        Say 'INFO' "Log retained at $LogPath (delete by hand if unwanted)."
        exit $EXIT_OK
    }

    # ---------------------------------------------------------------- install
    Say 'INFO' "Runner  : $RunnerPath"
    Say 'INFO' "Log     : $LogPath"
    Say 'INFO' "Task    : $TaskName  (trigger: AtLogOn, principal: $env:USERNAME, LeastPrivilege)"
    Say 'INFO' "MaxWait : ${MaxWaitSec}s"

    if ($existing) {
        Say 'INFO' "Task already exists - it will be replaced."
    }

    if (-not $Apply) {
        Write-Output ""
        Say 'WARN' 'DRY RUN - nothing written.'
        Say 'INFO' 'Re-run with -Apply to install.'
        exit $EXIT_PENDING
    }

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Say 'PASS' "Created $InstallDir"
    }

    Set-Content -Path $RunnerPath -Value $RunnerBody -Encoding UTF8
    Say 'PASS' "Wrote runner ($((Get-Item $RunnerPath).Length) bytes)"

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $RunnerPath)
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

    if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'net-ops: flush the DNS cache once at logon, after NextDNS interception is confirmed, to clear router-profile answers cached during the boot..logon window.' | Out-Null

    Say 'PASS' "Registered scheduled task '$TaskName'"
    Write-Output ""
    Say 'INFO' ("Exercise it now:  Start-ScheduledTask '{0}'" -f $TaskName)
    Say 'INFO' "Then read:        Get-Content '$LogPath' -Tail 20"
    Say 'INFO' 'Full verification still requires a real reboot.'

    exit $EXIT_OK
}
catch {
    Write-Error $_
    exit $EXIT_ERROR
}
