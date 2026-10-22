<#
.SYNOPSIS
    Download, verify, and install a specific Process Compose version on Windows.

.DESCRIPTION
    1. Downloads the release zip and checksums file from GitHub.
    2. Verifies SHA-256 against the published checksums.txt.
    3. Extracts the .exe.
    4. Records the .exe's own hash for future re-verification.
    5. Writes VERIFICATION.md.

    The result is a verified binary in <target>/bin/, ready to commit to your repo.

.PARAMETER Version
    Version tag (e.g. "v1.110.0"). Required - never auto-pick latest.

.PARAMETER TargetDir
    Where to put bin/. Defaults to current directory.

.EXAMPLE
    .\install-process-compose.ps1 -Version v1.110.0 -TargetDir X:\my-stack
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$TargetDir = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$binDir = Join-Path $TargetDir 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$base = "https://github.com/F1bonacc1/process-compose/releases/download/$Version"
$zipName = "process-compose_windows_amd64.zip"
$checksumsName = "process-compose_checksums.txt"

$zipPath = Join-Path $binDir $zipName
$checksumsPath = Join-Path $binDir $checksumsName

Write-Host "Downloading Process Compose $Version..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "$base/$zipName"       -OutFile $zipPath
Invoke-WebRequest -Uri "$base/$checksumsName" -OutFile $checksumsPath

Write-Host "Verifying SHA-256..." -ForegroundColor Cyan
$expected = (Select-String -Pattern $zipName -Path $checksumsPath).Line.Split()[0].ToLower()
$actual   = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()

if ($expected -ne $actual) {
    Remove-Item $zipPath -Force
    throw "CHECKSUM MISMATCH - aborting install. Expected $expected, got $actual."
}
Write-Host "  Match: $actual" -ForegroundColor Green

Write-Host "Extracting..." -ForegroundColor Cyan
Expand-Archive $zipPath -DestinationPath $binDir -Force

# Clean up bundled docs (we don't ship upstream's LICENSE/README in our repo)
Remove-Item (Join-Path $binDir 'LICENSE')   -ErrorAction SilentlyContinue
Remove-Item (Join-Path $binDir 'README.md') -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force

# Record version
$Version | Out-File -FilePath (Join-Path $binDir 'VERSION') -NoNewline -Encoding ascii

# Record the .exe's hash for re-verification
$exePath = Join-Path $binDir 'process-compose.exe'
$exeHash = (Get-FileHash $exePath -Algorithm SHA256).Hash.ToLower()
$exeHash | Out-File -FilePath (Join-Path $binDir 'EXE_HASH') -NoNewline -Encoding ascii

Write-Host "Runtime check..." -ForegroundColor Cyan
$versionOutput = & $exePath version 2>&1 | Where-Object { $_ -notmatch 'level.*debug' }
Write-Host $versionOutput

# Write VERIFICATION.md
$verifPath = Join-Path $binDir 'VERIFICATION.md'
@"
# Process Compose Binary Verification

## $Version

| Field | Value |
|---|---|
| Pinned | $(Get-Date -Format 'yyyy-MM-dd') |
| Source | https://github.com/F1bonacc1/process-compose/releases/tag/$Version |
| ZIP SHA-256 | ``$actual`` |
| EXE SHA-256 | ``$exeHash`` |
| Runtime check | ``$($versionOutput -join '; ')`` |

Trust anchor: GitHub Releases (HTTPS, requires repo write access to tamper).
Note: Process Compose releases are not GPG-signed.

## Re-verify

``````powershell
`$expected = (Get-Content bin/EXE_HASH).Trim()
`$actual   = (Get-FileHash bin/process-compose.exe -Algorithm SHA256).Hash.ToLower()
if (`$expected -ne `$actual) { throw "binary tampered" }
``````
"@ | Out-File -FilePath $verifPath -Encoding utf8

Write-Host ""
Write-Host "Done. Binary committed to: $binDir" -ForegroundColor Green
Write-Host "Files: process-compose.exe, $checksumsName, VERSION, EXE_HASH, VERIFICATION.md"
Write-Host ""
Write-Host "Next: git add bin/; git commit -m 'feat: pin process-compose $Version, verified'"
