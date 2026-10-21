# winnet-ops :: nrpt-audit.ps1
# Dump every NRPT rule with full forensics. Use when probe.ps1 shows
# layer 4 (nslookup) PASS but layer 5 (Resolve-DnsName) FAIL - that's the
# textbook signature of a rogue NRPT entry.

Write-Output "=== NRPT RULES (PowerShell view) ==="
$rules = Get-DnsClientNrptRule
if (!$rules) {
    Write-Output "No NRPT rules configured."
    return
}
$rules | Format-Table Name, Namespace, NameServers, Comment -AutoSize -Wrap | Out-String | Write-Output

Write-Output ""
Write-Output "=== SUSPICIOUS RULES (catch-all or non-Tailscale) ==="
$bad = $rules | Where-Object {
    $_.Namespace -eq "." -or
    ($_.NameServers -and ($_.NameServers | Where-Object { $_ -notmatch "^100\.100\.100\.100$|^fd7a:115c:a1e0::53$" }))
}
if ($bad) {
    $bad | Format-List Name, Namespace, NameServers, Comment, DohTemplate
} else {
    Write-Output "None - only Tailscale MagicDNS rules present (normal)."
}

Write-Output ""
Write-Output "=== REGISTRY FORENSICS (creation source, timestamps) ==="
# NRPT lives in two possible locations:
#   1. HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\DnsPolicyConfig (Group Policy)
#   2. HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig (local, set by apps)
$paths = @(
    @{Path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\DnsPolicyConfig"; Source="Group Policy"},
    @{Path="HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig"; Source="Local (app-set)"}
)
foreach ($p in $paths) {
    if (!(Test-Path $p.Path)) { continue }
    Write-Output ("--- " + $p.Source + " :: " + $p.Path + " ---")
    Get-ChildItem $p.Path -ErrorAction SilentlyContinue | ForEach-Object {
        $values = Get-ItemProperty $_.PSPath
        # LastWriteTime via reg.exe (.NET doesn't expose it for subkeys in older PS)
        $regOut = reg query $($_.Name -replace "HKEY_LOCAL_MACHINE","HKLM") 2>&1
        Write-Output ("Rule:    " + $_.PSChildName)
        Write-Output ("  Comment:   " + $values.Comment)
        Write-Output ("  DNSServers:" + ($values.GenericDNSServers -join "; "))
        Write-Output ("  Namespaces:" + (($values.Name | Select-Object -First 3) -join "; ") + $(if ($values.Name.Count -gt 3) { " ... (+" + ($values.Name.Count - 3) + " more)" } else { "" }))
        Write-Output ""
    }
}

Write-Output "=== ATTRIBUTION HINTS ==="
# Match comments / DNS IPs to known VPN clients
$rules | ForEach-Object {
    $hint = switch -Regex ($_.Comment + " " + ($_.NameServers -join " ")) {
        "Proton"          { "Proton VPN" }
        "Mullvad"         { "Mullvad" }
        "AnyConnect|Cisco" { "Cisco AnyConnect" }
        "Nord"            { "NordVPN" }
        "DirectAccess"    { "Windows DirectAccess (corporate)" }
        "10\.2\.0\."      { "Proton VPN (default DNS gateway)" }
        "10\.64\.0\."     { "Mullvad (default DNS gateway)" }
        "100\.100\.100\.100" { "Tailscale MagicDNS (expected)" }
        default { "" }
    }
    if ($hint) {
        Write-Output ("  " + $_.Name + " :: likely " + $hint)
    }
}
