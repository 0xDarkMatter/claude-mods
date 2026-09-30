# Remote Windows Diagnostics

Load this when troubleshooting a Windows box you can't sit at — the family member's PC, a server, a colleague's machine across the office. PowerShell remoting (WS-Management or SSH) lets every script in this skill run against a remote target with no installation on the target side.

Companion to `net-ops`'s SSH bootstrap — same pattern, different transport layer.

## Contents

1. [Quick start — single-shot command](#quick-start--single-shot-command)
2. [The two transports](#the-two-transports) — WS-Man vs SSH
3. [Authentication models](#authentication-models)
4. [Enabling PSRemoting on the target](#enabling-psremoting-on-the-target)
5. [Workgroup setup — TrustedHosts](#workgroup-setup--trustedhosts)
6. [Running this skill's scripts remotely](#running-this-skills-scripts-remotely)
7. [Reading event logs without entering a session](#reading-event-logs-without-entering-a-session)
8. [The double-hop problem](#the-double-hop-problem)
9. [Common errors and fixes](#common-errors-and-fixes)
10. [Worked example: full audit on a remote box](#worked-example-full-audit-on-a-remote-box)

## Quick start — single-shot command

When everything is already set up (same domain, PSRemoting enabled), this works directly:

```powershell
# Single command, single result
Invoke-Command -ComputerName REMOTE-PC -ScriptBlock { Get-Disk } -Credential (Get-Credential)

# Interactive session
Enter-PSSession -ComputerName REMOTE-PC -Credential (Get-Credential)

# Persistent session for repeated commands (saves auth overhead)
$s = New-PSSession -ComputerName REMOTE-PC -Credential (Get-Credential)
Invoke-Command -Session $s -ScriptBlock { Get-Service WinDefend }
Invoke-Command -Session $s -ScriptBlock { Get-Process | Sort CPU -Descending | Select -First 5 }
Remove-PSSession $s
```

If this doesn't work, the setup steps below address every common reason it fails.

## The two transports

PowerShell remoting runs over either WS-Management (the original) or SSH (modern alternative on Win10 1809+ / Server 2019+).

| Transport | Port | When |
|-----------|------|------|
| WS-Man (HTTP) | 5985 | Default. Same domain, internal network. |
| WS-Man (HTTPS) | 5986 | Across network boundaries, untrusted networks. Needs certificate. |
| SSH | 22 | Cross-OS (Linux ↔ Windows). Authentication you already have. Use this when target also runs OpenSSH Server. |

For everything in this doc the default WS-Man (5985, HTTP) path is assumed. SSH transport is covered in [SSH transport](#ssh-transport) section near the end.

## Authentication models

What credentials work depend on the target's domain situation:

| Target | Caller | Auth that works |
|--------|--------|-----------------|
| Domain member | Domain user | Kerberos (default, automatic) |
| Domain member | Local admin of target | Negotiate→NTLM (after TrustedHosts) |
| Workgroup | Local admin of target | Negotiate→NTLM (after TrustedHosts) |
| Workgroup | Same local username + password on both | Negotiate→NTLM, sometimes auto |
| Internet-reachable | Anyone | Basic over HTTPS (NEVER over HTTP) |
| Anything | Anyone with SSH key | SSH transport |

If a fresh `Enter-PSSession` fails with "Access is denied" or "Kerberos authentication error", the auth model probably doesn't match.

## Enabling PSRemoting on the target

This runs on the **target** (the machine to be controlled), as Administrator:

```powershell
Enable-PSRemoting -Force
# That does all of:
#   - Starts WinRM service, sets to auto-start
#   - Configures HTTP listener on port 5985
#   - Adds Windows Firewall exception for WinRM (private/domain networks only by default)
#   - Registers default endpoints
```

Verification (from caller or target):

```powershell
Test-WSMan -ComputerName REMOTE-PC
# Returns wsmid + ProductVendor on success
```

If the target is on a public network (e.g. a laptop on a coffee-shop Wi-Fi), `Enable-PSRemoting` won't open the firewall for public profiles by default. Either change the network profile to private, or:

```powershell
Set-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -RemoteAddress Any -Profile Public -Enabled True
```

(Be deliberate about exposing WinRM to public networks — usually not what you want.)

## Workgroup setup — TrustedHosts

Without Kerberos (i.e. not on a domain), the caller has to declare which targets it trusts for NTLM auth. On the **caller**:

```powershell
# Add a single host
Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'REMOTE-PC' -Force

# Or multiple, comma-separated
Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'REMOTE-PC,SERVER1,LAPTOP4' -Force

# Or all hosts (lazy, use only for short troubleshooting windows)
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force

# Inspect current setting
Get-Item WSMan:\localhost\Client\TrustedHosts
```

Then auth with local credentials of the target:

```powershell
$cred = Get-Credential REMOTE-PC\admin   # username = TARGET\user, password = TARGET's user password
Enter-PSSession -ComputerName REMOTE-PC -Credential $cred
```

The `TARGET\user` format is what makes Windows look up the user against the target's local SAM database instead of trying domain auth.

## Running this skill's scripts remotely

Three patterns, picking by use case:

### Pattern 1: Inline script block (no file transfer)

When the script is short or you've embedded the logic:

```powershell
$cred = Get-Credential
Invoke-Command -ComputerName REMOTE-PC -Credential $cred -ScriptBlock {
    Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; StartTime=(Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated,
            @{N='BugCheck';E={'0x{0:X}' -f $_.Properties[0].Value}},
            @{N='Param1';E={'0x{0:X}' -f $_.Properties[1].Value}}
}
```

### Pattern 2: Send a script file (preferred for windows-ops scripts)

When the script lives in this skill's `scripts/` dir, `Invoke-Command -FilePath` ships it to the target and executes there:

```powershell
$cred = Get-Credential
Invoke-Command -ComputerName REMOTE-PC -Credential $cred `
    -FilePath "C:\Users\Me\.claude\skills\windows-ops\scripts\health-audit.ps1" `
    -ArgumentList @('-Days', 30)
```

Limitation: `-FilePath` doesn't ship dependent files. If the script dot-sources `_lib/common.ps1` (which all of windows-ops's scripts do), this fails. Use Pattern 3 instead.

### Pattern 3: Stage the skill on the target, run via Invoke-Command

For scripts with file dependencies, copy the skill folder to the target first:

```powershell
$s = New-PSSession -ComputerName REMOTE-PC -Credential (Get-Credential)

# Push the entire skill (one-time setup)
Copy-Item -ToSession $s `
    -Path "$HOME\.claude\skills\windows-ops" `
    -Destination "C:\Temp\windows-ops" `
    -Recurse -Force

# Then run any script
Invoke-Command -Session $s -ScriptBlock {
    & C:\Temp\windows-ops\scripts\health-audit.ps1 -Days 30 -Json
} | ConvertFrom-Json

# Or grab raw text
$report = Invoke-Command -Session $s -ScriptBlock {
    & C:\Temp\windows-ops\scripts\health-audit.ps1 -Days 30 2>&1
}
$report

Remove-PSSession $s
```

This is the canonical pattern for serious remote troubleshooting: stage once, run many scripts.

## Reading event logs without entering a session

For single-purpose log queries, `Get-WinEvent -ComputerName` works without setting up sessions:

```powershell
# Pull System log entries from a remote box
Get-WinEvent -ComputerName REMOTE-PC -Credential $cred -FilterHashtable @{
    LogName='System'
    ProviderName='storahci'
    Id=129
    StartTime=(Get-Date).AddDays(-7)
}
```

This uses RPC under the hood (different port: 135 + dynamic high ports), not WinRM. It works without `Enable-PSRemoting` but the Remote Event Log Management firewall rule must be enabled on the target:

```powershell
# On the target, one-time
Set-NetFirewallRule -DisplayGroup 'Remote Event Log Management' -Enabled True
```

When this works, it's the fastest path for "just give me the events from that machine". When WinRM and RPC are both available, prefer WinRM for cleaner auth semantics.

## The double-hop problem

If you enter a session on REMOTE-A and try to access a network resource (file share, another machine) from inside, you'll get `Access is denied` because credentials don't forward by default.

Three solutions:

### Solution 1: CredSSP delegation (full credential forwarding)

On the caller:
```powershell
Enable-WSManCredSSP -Role Client -DelegateComputer 'REMOTE-A'
```

On the target REMOTE-A:
```powershell
Enable-WSManCredSSP -Role Server
```

Then use `-Authentication CredSSP`:
```powershell
Enter-PSSession -ComputerName REMOTE-A -Credential $cred -Authentication CredSSP
# From inside, can now hop to REMOTE-B with same credentials
```

Security note: CredSSP exposes credentials to the target. Not for use against untrusted machines.

### Solution 2: Resource-Based Constrained Delegation (Kerberos, domain-only)

Modern domain alternative — set on REMOTE-B (the second hop), allowing REMOTE-A to delegate to it:

```powershell
Set-ADComputer REMOTE-B -PrincipalsAllowedToDelegateToAccount (Get-ADComputer REMOTE-A)
```

Per-resource, doesn't expose credentials to REMOTE-A.

### Solution 3: Run scripts that don't need a hop

The simplest: design the diagnostic to not need to hop. Every script in this skill reads local-only system state — no network resources needed.

## SSH transport

Modern alternative on Win10 1809+ / Server 2019+. PowerShell remoting over OpenSSH instead of WinRM.

Target side (one-time):
```powershell
# Install OpenSSH Server (if not already)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

# Configure pwsh as a remoting subsystem
$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
Add-Content $sshdConfig 'Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -NoLogo'
Restart-Service sshd
```

Caller side:
```powershell
Enter-PSSession -HostName REMOTE-PC -UserName admin
# Same as SSH — uses ~\.ssh\id_rsa, ~/.ssh/config, known_hosts
```

Advantages over WS-Man:
- Single port (22), works through more firewalls
- Same auth as ssh proper (keys, ssh-agent, jump hosts via ProxyJump)
- Cross-OS: from macOS/Linux, just use `Enter-PSSession -HostName` against a Windows target with this configured
- No TrustedHosts gymnastics

## Common errors and fixes

| Error message | Cause | Fix |
|---------------|-------|-----|
| "Cannot find the computer X" | DNS or netbios resolution | Use FQDN or IP; `nslookup X` to check |
| "The WinRM client cannot process the request" | TrustedHosts not configured | `Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'X' -Force` |
| "Access is denied" | Wrong credentials or wrong auth model | Use `TARGET\user` format for local; `Get-Credential` to retype |
| "The user name or password is incorrect" | Same as above usually | Verify by logging into target directly first |
| "Kerberos error" workgroup target | Trying Kerberos against non-domain target | Use `-Authentication Negotiate` explicitly, plus TrustedHosts |
| "The client cannot connect to the destination" | WinRM not enabled or firewall blocks | On target: `Enable-PSRemoting -Force`; check firewall |
| "Connecting to remote server failed with HTTP status 401" | Auth handshake failed | Wrong cred, wrong auth scheme, or no listener |
| "The PowerShell version is not allowed" | Target language mode locked down (corp environment) | Use constrained-endpoint flow or skip remoting |
| Hangs forever, no error | Listener port blocked at network level | `Test-NetConnection -ComputerName X -Port 5985` |

## Worked example: full audit on a remote box

Scenario: your colleague's PC across town is crashing. They give you Administrator credentials on it. WinRM was enabled by IT.

```powershell
# 1. Verify connectivity
$target = 'COLLEAGUE-PC.corp.local'
Test-WSMan -ComputerName $target
# Expect: wsmid + ProductVendor lines

# 2. Auth
$cred = Get-Credential -Message "Admin on $target"
# Type: CORP\admin   (domain) or COLLEAGUE-PC\admin (local)

# 3. Stage the skill on target
$s = New-PSSession -ComputerName $target -Credential $cred
Copy-Item -ToSession $s -Path "$HOME\.claude\skills\windows-ops" -Destination 'C:\Temp\windows-ops' -Recurse -Force

# 4. Run the audit, capture JSON
$json = Invoke-Command -Session $s -ScriptBlock {
    & C:\Temp\windows-ops\scripts\health-audit.ps1 -Days 30 -Json
} -Verbose
$audit = $json | ConvertFrom-Json

# 5. Pull crash triage for any recent Event 41
$triage = Invoke-Command -Session $s -ScriptBlock {
    & C:\Temp\windows-ops\scripts\crash-triage.ps1 -Json
} | ConvertFrom-Json
$triage.bugcheckName

# 6. If failing drive detected, check dependencies before recommending disconnect
if ($audit.findings | Where-Object level -eq 'fail' | Where-Object subject -like '*Disk*') {
    $diskNum = ($audit.findings | Where-Object level -eq 'fail' | Select -First 1).data.diskNumber
    $deps = Invoke-Command -Session $s -ScriptBlock {
        & C:\Temp\windows-ops\scripts\drive-dependencies.ps1 -DiskNumber $using:diskNum -Json
    } | ConvertFrom-Json
    $deps.verdict
}

# 7. Cleanup
Invoke-Command -Session $s -ScriptBlock { Remove-Item C:\Temp\windows-ops -Recurse -Force }
Remove-PSSession $s
```

The same pattern works for: a server in a datacenter, a kiosk PC, a remote tunnel-accessed home machine. Anything you can `Enter-PSSession` into, this skill works against.

## Cross-reference

When the remote box is unreachable at all:
- Networking diagnostics → `net-ops`
- The target has SSH but not WinRM → use Pattern 3 with SSH transport
- The target won't even POST / boot → no remote help; needs physical access for Windows RE

This skill is for "I can shell into it but Windows isn't healthy". For "I can't shell into it", that's a different problem domain.
