<#
.SYNOPSIS
    Derive portless aliases from a process-compose.yaml and register them.

.DESCRIPTION
    Reads every process from process-compose.yaml, looks at its
    readiness_probe.http_get.port, and registers a portless alias mapping
    the process name to that port.

    Idempotent: uses --force to overwrite existing aliases.

    Requires yq (https://github.com/mikefarah/yq) on PATH.

.PARAMETER YamlPath
    Path to process-compose.yaml. Defaults to ./process-compose.yaml.

.EXAMPLE
    .\sync-aliases-from-yaml.ps1
    .\sync-aliases-from-yaml.ps1 -YamlPath X:\my-stack\process-compose.yaml
#>

[CmdletBinding()]
param(
    [string]$YamlPath = (Join-Path (Get-Location) 'process-compose.yaml')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $YamlPath)) {
    throw "YAML file not found: $YamlPath"
}

if (-not (Get-Command yq -ErrorAction SilentlyContinue)) {
    throw "yq not found on PATH. Install: scoop install yq"
}

Write-Host "Syncing aliases from: $YamlPath" -ForegroundColor Cyan
Write-Host ""

$services = & yq '.processes | keys | .[]' $YamlPath
$count = 0

foreach ($svc in $services) {
    $port = & yq ".processes.$svc.readiness_probe.http_get.port" $YamlPath

    if (-not $port -or $port -eq "null") {
        Write-Host "  $svc -- no http_get probe, skipping (background process?)"
        continue
    }

    Write-Host "  $svc -> $port"
    & portless alias $svc $port --force 2>&1 | Out-Null
    $count++
}

Write-Host ""
Write-Host "Registered $count aliases." -ForegroundColor Green
Write-Host ""
portless list
