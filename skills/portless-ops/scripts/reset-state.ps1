<#
.SYNOPSIS
    Cleanly reset portless state (stop proxy, wipe routes, restart with new config).

.DESCRIPTION
    Use this when:
    - Changing TLDs (portless alias --remove appends active TLD, so cleaning
      old aliases is impossible without a full reset)
    - Routes are corrupted or have stale entries
    - You want to start fresh with a different proxy port / TLS mode

.PARAMETER Tld
    TLD to start the new proxy with. Defaults to current saved value.

.PARAMETER Port
    Proxy port. Defaults to 443.

.PARAMETER PreserveCa
    Keep the existing local CA. Default true (avoids re-trusting in browsers).

.PARAMETER Aliases
    Hashtable of name -> port pairs to re-register after reset. Optional.

.EXAMPLE
    # Change TLD and re-register aliases
    .\reset-state.ps1 -Tld test -Aliases @{
        myapp = 8000
        api   = 8001
        db    = 5432
    }
#>

[CmdletBinding()]
param(
    [string]$Tld,
    [int]$Port = 443,
    [bool]$PreserveCa = $true,
    [hashtable]$Aliases = @{}
)

$ErrorActionPreference = 'Stop'

Write-Host "Resetting portless state" -ForegroundColor Cyan

# 1. Stop proxy
Write-Host "[1/4] Stopping proxy..."
portless proxy stop 2>&1 | Out-Null

# 2. Wipe routes.json
$routesFile = Join-Path $env:USERPROFILE '.portless\routes.json'
if (Test-Path $routesFile) {
    Write-Host "[2/4] Removing routes.json..."
    Remove-Item $routesFile -Force
} else {
    Write-Host "[2/4] No routes.json to remove."
}

# Optional: nuke CA + everything (use `portless clean` for nuclear option)
if (-not $PreserveCa) {
    Write-Host "  Also clearing CA + /etc/hosts (will need re-trust)..."
    portless clean 2>&1 | Out-Null
}

# 3. Start proxy with new TLD/port
Write-Host "[3/4] Starting proxy: --tld $Tld --port $Port..."
$args = @("proxy", "start", "--port", $Port)
if ($Tld) { $args += @("--tld", $Tld) }
& portless @args
Start-Sleep -Seconds 2

# 4. Re-register aliases if provided
if ($Aliases.Count -gt 0) {
    Write-Host "[4/4] Re-registering $($Aliases.Count) aliases..."
    foreach ($name in $Aliases.Keys) {
        $port = $Aliases[$name]
        Write-Host "  alias: $name -> $port"
        & portless alias $name $port --force 2>&1 | Out-Null
    }
} else {
    Write-Host "[4/4] No aliases to register."
}

Write-Host ""
Write-Host "Done. Current state:" -ForegroundColor Green
portless list
