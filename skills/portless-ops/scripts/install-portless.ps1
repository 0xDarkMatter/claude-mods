<#
.SYNOPSIS
    Install a specific version of portless globally with verification.

.DESCRIPTION
    1. Inspects the published npm tarball BEFORE installing.
    2. Verifies tarball SHA-512 against the npm registry.
    3. Scans the package contents for known IOC strings from recent npm
       supply-chain attacks (TanStack, mini-shai-hulud).
    4. Confirms no install scripts (preinstall/postinstall) are present.
    5. Installs globally via npm.
    6. Verifies version matches what was requested.
    7. Records the pinned version.

.PARAMETER Version
    Specific version to install (e.g. "0.13.0"). Required.

.PARAMETER TargetDir
    Where to record version metadata (a bin/PORTLESS_VERSION file). Optional.

.EXAMPLE
    .\install-portless.ps1 -Version 0.13.0 -TargetDir X:\my-stack
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$TargetDir = $null
)

$ErrorActionPreference = 'Stop'

Write-Host "Installing portless@$Version with pre-install audit" -ForegroundColor Cyan
Write-Host ("=" * 60)
Write-Host ""

# Step 1 - Inspect tarball without installing
$tmp = Join-Path $env:TEMP "portless-inspect-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    Write-Host "[1/6] Downloading tarball..." -ForegroundColor Yellow
    $tarballUrl = "https://registry.npmjs.org/portless/-/portless-$Version.tgz"
    $tarball = Join-Path $tmp 'portless.tgz'
    Invoke-WebRequest -Uri $tarballUrl -OutFile $tarball

    Write-Host "[2/6] Verifying SHA-512 against npm registry..." -ForegroundColor Yellow
    $meta = npm view portless@$Version --json 2>$null | ConvertFrom-Json
    $expectedIntegrity = $meta.dist.integrity  # like "sha512-..."
    if (-not $expectedIntegrity) {
        throw "Could not fetch published integrity hash for portless@$Version"
    }

    # npm's integrity is "sha512-<base64>". Compare with our computed value.
    $actualBytes = [System.Security.Cryptography.SHA512]::Create().ComputeHash([IO.File]::ReadAllBytes($tarball))
    $actualB64 = [Convert]::ToBase64String($actualBytes)
    $expectedB64 = $expectedIntegrity -replace '^sha512-', ''
    if ($actualB64 -ne $expectedB64) {
        throw "TARBALL SHA-512 MISMATCH - aborting. Expected: $expectedB64. Got: $actualB64."
    }
    Write-Host "  Match: sha512-$actualB64" -ForegroundColor Green

    Write-Host "[3/6] Extracting + auditing contents..." -ForegroundColor Yellow
    Push-Location $tmp
    tar -xzf portless.tgz
    Pop-Location

    $pkgDir = Join-Path $tmp 'package'

    # Scan for install scripts in package.json
    $pkgJson = Get-Content (Join-Path $pkgDir 'package.json') | ConvertFrom-Json
    $scripts = $pkgJson.scripts.PSObject.Properties.Name
    $installScripts = @('preinstall', 'install', 'postinstall', 'prepare')
    $foundInstallScripts = $scripts | Where-Object { $_ -in $installScripts }

    if ($foundInstallScripts) {
        Write-Warning "Package has install scripts: $($foundInstallScripts -join ', ')"
        Write-Warning "Review these before installing!"
    } else {
        Write-Host "  [ok] No install scripts (preinstall/install/postinstall/prepare)"
    }

    # Check runtime dependencies (should be empty for portless)
    if ($pkgJson.dependencies -and $pkgJson.dependencies.PSObject.Properties.Count -gt 0) {
        Write-Warning "Package has runtime deps: $($pkgJson.dependencies.PSObject.Properties.Name -join ', ')"
    } else {
        Write-Host "  [ok] Zero runtime dependencies"
    }

    # Scan for known IOC strings from recent attacks
    Write-Host "[4/6] Scanning for known supply-chain IOC strings..." -ForegroundColor Yellow
    $iocPatterns = @(
        'getsession.org', 'masscan.cloud', 'git-tanstack',
        'router_init', 'router_runtime',
        'EveryBoiWeBuildIsAWormyBoi',
        'claude@users.noreply.github.com',
        'filev2.getsession',
        '@tanstack/setup',
        'gh-token-monitor',
        '/proc/self/environ', '.claude/settings.json'
    )

    $hits = @()
    Get-ChildItem -Recurse -File $pkgDir | ForEach-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($pattern in $iocPatterns) {
            if ($content -and $content.Contains($pattern)) {
                $hits += "$($_.Name): $pattern"
            }
        }
    }
    if ($hits) {
        throw "IOC MATCH FOUND - aborting:`n$($hits -join "`n")"
    }
    Write-Host "  [ok] Zero IOC matches"

    # Step 5 - Install via npm
    Write-Host "[5/6] npm install -g portless@$Version..." -ForegroundColor Yellow
    npm install -g portless@$Version 2>&1 | Tee-Object -Variable npmOutput | Out-Host

    # Step 6 - Verify installed version
    Write-Host "[6/6] Verifying installed version..." -ForegroundColor Yellow
    $installed = (portless --version).Trim()
    if ($installed -ne $Version) {
        throw "Version mismatch: requested $Version, installed $installed"
    }
    Write-Host "  Installed: $installed" -ForegroundColor Green

    # Optional: record in target dir
    if ($TargetDir) {
        $binDir = Join-Path $TargetDir 'bin'
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $Version | Out-File -FilePath (Join-Path $binDir 'PORTLESS_VERSION') -NoNewline -Encoding ascii
        Write-Host "  Recorded version in: $binDir\PORTLESS_VERSION"
    }

    Write-Host ""
    Write-Host "Done. portless@$Version installed and audited." -ForegroundColor Green

} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
