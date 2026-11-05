# winnet-ops :: nrpt-clean.ps1
# Safely remove orphaned NRPT catch-all rules left behind by disconnected VPNs.
# NEVER removes Tailscale MagicDNS rules.
#
# Defaults to DRY RUN - pass -Apply to actually delete.
# Requires elevated PowerShell (Administrator).

param(
    [switch]$Apply,
    [string[]]$ProtectNameServers = @("100.100.100.100","fd7a:115c:a1e0::53")
)

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$isAdmin) {
    Write-Error "Must run as Administrator. Open elevated PowerShell."
    exit 1
}

Write-Output "=== BEFORE ==="
$all = Get-DnsClientNrptRule
$all | Format-Table Name, Namespace, NameServers, Comment -AutoSize -Wrap | Out-String | Write-Output

# Find catch-all rules NOT pointing at protected (Tailscale) servers
$targets = $all | Where-Object {
    $_.Namespace -eq "." -and
    (-not ($_.NameServers | Where-Object { $ProtectNameServers -contains $_ }))
}

if (!$targets) {
    Write-Output ""
    Write-Output "No orphaned catch-all rules found. Nothing to clean."
    exit 0
}

Write-Output ""
Write-Output "=== TARGETS FOR REMOVAL ==="
$targets | Format-List Name, Namespace, NameServers, Comment

if (!$Apply) {
    Write-Output ""
    Write-Output "DRY RUN - pass -Apply to actually remove the rules above."
    exit 0
}

Write-Output ""
Write-Output "=== REMOVING ==="
foreach ($t in $targets) {
    try {
        Remove-DnsClientNrptRule -Name $t.Name -Force -ErrorAction Stop
        Write-Output ("[OK] Removed " + $t.Name)
    } catch {
        Write-Output ("[FAIL] " + $t.Name + " :: " + $_.Exception.Message)
    }
}

Write-Output ""
Write-Output "=== FLUSHING DNS CACHE ==="
Clear-DnsClientCache
ipconfig /flushdns | Select-String "Successfully|Could" | Select-Object -First 1

Write-Output ""
Write-Output "=== VERIFICATION ==="
try {
    $r = Resolve-DnsName google.com -Type A -QuickTimeout -ErrorAction Stop
    $ips = ($r | Where-Object { $_.Type -eq "A" } | Select-Object -ExpandProperty IPAddress) -join ", "
    Write-Output ("[PASS] Resolve-DnsName google.com -> " + $ips)
} catch {
    Write-Output ("[FAIL] Resolve-DnsName still broken: " + $_.Exception.Message)
    Write-Output "       Drill into WFP filters / hosts file / DNS Client service."
}

try {
    $r = Invoke-WebRequest -Uri "https://www.google.com" -TimeoutSec 8 -UseBasicParsing
    Write-Output ("[PASS] HTTPS google.com -> HTTP " + $r.StatusCode)
} catch {
    Write-Output ("[FAIL] HTTPS still broken: " + $_.Exception.Message)
}

Write-Output ""
Write-Output "=== AFTER ==="
Get-DnsClientNrptRule | Format-Table Name, Namespace, NameServers, Comment -AutoSize -Wrap | Out-String | Write-Output
