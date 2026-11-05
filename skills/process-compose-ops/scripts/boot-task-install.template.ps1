<#
.SYNOPSIS
    TEMPLATE: Register a Windows Task Scheduler entry to launch Process Compose at boot.

.DESCRIPTION
    Copy to <your-stack>/scripts/boot-task-install.ps1, customise $taskName, and
    run as Administrator.

    Pairs with boot-start.template.ps1 (the wrapper script that this task launches).
    Uses LogonType S4U so the task runs at boot without storing a password or
    requiring interactive logon.

.EXAMPLE
    # In elevated PowerShell:
    .\boot-task-install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Admin check
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator. Task Scheduler creation requires it."
}

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root       = (Resolve-Path (Join-Path $scriptDir '..')).Path
$bootScript = Join-Path $scriptDir 'boot-start.ps1'

if (-not (Test-Path $bootScript)) {
    throw "boot-start.ps1 not found at $bootScript - copy boot-start.template.ps1 and customise"
}

# --- CUSTOMIZE TASK NAME --------------------------------------------------
$taskName = "ProcessCompose-MyStack"   # rename per project

Write-Host "Registering Task Scheduler entry: $taskName" -ForegroundColor Cyan

# Idempotent: remove existing if present
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Removing existing task..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Launch via PowerShell, hidden window, running boot-start.ps1
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$bootScript`"" `
    -WorkingDirectory $root

$trigger = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# S4U: runs at boot as current user, no password stored, no interactive logon needed.
# Sufficient for local services with no GUI or network-share requirements.
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType S4U `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $taskPrincipal `
    -Description "Starts Process Compose at boot."

Write-Host ""
Write-Host "Done. Task registered." -ForegroundColor Green
Write-Host ""
Write-Host "Verify:"
Write-Host "  Get-ScheduledTask -TaskName '$taskName'"
Write-Host ""
Write-Host "Test before reboot:"
Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "  Start-Sleep 10"
Write-Host "  process-compose -p 8888 process list"
Write-Host ""
Write-Host "Uninstall:"
Write-Host "  Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
