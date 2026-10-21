<#
.SYNOPSIS
    TEMPLATE: Boot-time launcher for Process Compose with explicit PATH setup.

.DESCRIPTION
    Copy to <your-stack>/scripts/boot-start.ps1 and adapt the $pathParts array
    for your machine. Invoked by Task Scheduler at boot (see
    boot-task-install.template.ps1).

    Why a wrapper: Task Scheduler runs with a minimal PATH, so services that
    rely on python/uv/openssl/cloudflared would otherwise fail at boot.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root      = (Resolve-Path (Join-Path $scriptDir '..')).Path
$pcExe     = Join-Path $root 'bin\process-compose.exe'
$pcYaml    = Join-Path $root 'process-compose.yaml'
$logFile   = Join-Path $root 'logs\process-compose.log'
$bootLog   = Join-Path $root 'logs\boot-start.log'

New-Item -ItemType Directory -Force -Path (Join-Path $root 'logs') | Out-Null

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] boot-start invoked. User: $env:USERNAME" | Out-File -FilePath $bootLog -Append

# --- CUSTOMIZE PATH HERE ---------------------------------------------------
# Add directories for binaries that your managed services need (python, uv,
# git tools, cloudflared, language SDKs, etc.). Test by running this script
# manually before relying on it at boot.
$pathParts = @(
    "$root\bin"                                                                  # PC + committed binaries
    "C:\Program Files\Git\usr\bin"                                              # openssl, bash, coreutils
    "C:\Program Files\Git\bin"                                                  # git
    "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313"            # python, pythonw
    "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313\Scripts"    # uv, pip, etc.
    # Add more as needed:
    # "C:\Program Files (x86)\cloudflared"
    # "C:\Program Files\nodejs"
    "C:\Windows\System32"
    "C:\Windows"
    $env:PATH
)
$env:PATH = ($pathParts -join ';')

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] PATH set, $($pathParts.Count) entries" | Out-File -FilePath $bootLog -Append

# --- OPTIONAL: load secrets from gitignored .env --------------------------
$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
    "[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] Loading .env" | Out-File -FilePath $bootLog -Append
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+?)\s*$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
}

# --- OPTIONAL: explicitly UNSET env vars that conflict with services ------
# Example: if a daemon enforces OAuth-only and refuses to start with stale API keys
# [Environment]::SetEnvironmentVariable('SOME_API_KEY', $null, 'Process')

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] Starting process-compose..." | Out-File -FilePath $bootLog -Append

# --- LAUNCH ---------------------------------------------------------------
# -p 8888    API port (avoid common collisions on 8080; pick what's free)
# -t=false   no TUI (headless background daemon mode)
# -L         PC's own log file
& $pcExe -p 8888 -t=false -L $logFile up -f $pcYaml

"[$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')] process-compose exited code $LASTEXITCODE" | Out-File -FilePath $bootLog -Append
