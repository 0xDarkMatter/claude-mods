<#
.SYNOPSIS
    Install claude-mods extensions to ~/.claude/

.DESCRIPTION
    Copies commands, skills, agents, and rules to the global Claude Code config.
    Handles cleanup of deprecated items and command-to-skill migrations.

.NOTES
    Run from the claude-mods directory:
    .\scripts\install.ps1
#>

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "           claude-mods Installer (Windows)                      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$claudeDir = "$env:USERPROFILE\.claude"

# Ensure ~/.claude directories exist
$dirs = @("commands", "skills", "agents", "rules", "output-styles")
foreach ($dir in $dirs) {
    $path = Join-Path $claudeDir $dir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Host "  Created $path" -ForegroundColor Green
    }
}

# =============================================================================
# DEPRECATED ITEMS - Remove these from user config
# =============================================================================
$deprecated = @(
    "$claudeDir\commands\review.md",
    "$claudeDir\commands\testgen.md",
    "$claudeDir\commands\conclave.md",
    "$claudeDir\commands\pulse.md",
    "$claudeDir\skills\conclave",
    "$claudeDir\skills\claude-code-templates"   # Replaced by skill-creator
)

# Renamed skills: -patterns -> -ops (March 2026)
$renamedSkills = @(
    "cli-patterns",
    "mcp-patterns",
    "python-async-patterns",
    "python-cli-patterns",
    "python-database-patterns",
    "python-fastapi-patterns",
    "python-observability-patterns",
    "python-pytest-patterns",
    "python-typing-patterns",
    "rest-patterns",
    "security-patterns",
    "sql-patterns",
    "tailwind-patterns",
    "testing-patterns"
)

foreach ($oldSkill in $renamedSkills) {
    $oldPath = "$claudeDir\skills\$oldSkill"
    if (Test-Path $oldPath) {
        Remove-Item -Path $oldPath -Recurse -Force
        $newName = $oldSkill -replace '-patterns$', '-ops'
        Write-Host "  Removed renamed: $oldSkill (now $newName)" -ForegroundColor Red
    }
}

Write-Host "Cleaning up deprecated items..." -ForegroundColor Yellow
foreach ($item in $deprecated) {
    if (Test-Path $item) {
        Remove-Item -Path $item -Recurse -Force
        Write-Host "  Removed: $item" -ForegroundColor Red
    }
}
Write-Host ""

# =============================================================================
# COMMANDS - Only copy commands that have not been migrated to skills
# =============================================================================
Write-Host "Installing commands..." -ForegroundColor Cyan

$skipCommands = @("review.md", "testgen.md")

$commandsDir = Join-Path $projectRoot "commands"
Get-ChildItem -Path $commandsDir -Filter "*.md" | ForEach-Object {
    if ($_.Name -notin $skipCommands -and $_.Name -notlike "archive*") {
        Copy-Item $_.FullName -Destination "$claudeDir\commands\" -Force
        Write-Host "  $($_.Name)" -ForegroundColor Green
    }
}
Write-Host ""

# =============================================================================
# SKILLS - Copy all skill directories
# =============================================================================
Write-Host "Installing skills..." -ForegroundColor Cyan

$skillsDir = Join-Path $projectRoot "skills"
Get-ChildItem -Path $skillsDir -Directory | ForEach-Object {
    $dest = "$claudeDir\skills\$($_.Name)"
    if (Test-Path $dest) {
        Remove-Item -Path $dest -Recurse -Force
    }
    Copy-Item $_.FullName -Destination $dest -Recurse -Force
    Write-Host "  $($_.Name)/" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# AGENTS - Copy all agent files
# =============================================================================
Write-Host "Installing agents..." -ForegroundColor Cyan

$agentsDir = Join-Path $projectRoot "agents"
Get-ChildItem -Path $agentsDir -Filter "*.md" | ForEach-Object {
    Copy-Item $_.FullName -Destination "$claudeDir\agents\" -Force
    Write-Host "  $($_.Name)" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# RULES - Copy all rule files
# =============================================================================
Write-Host "Installing rules..." -ForegroundColor Cyan

$rulesDir = Join-Path $projectRoot "rules"
Get-ChildItem -Path $rulesDir -Filter "*.md" | ForEach-Object {
    Copy-Item $_.FullName -Destination "$claudeDir\rules\" -Force
    Write-Host "  $($_.Name)" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# OUTPUT STYLES - Copy all output style files
# =============================================================================
Write-Host "Installing output styles..." -ForegroundColor Cyan

$stylesDir = Join-Path $projectRoot "output-styles"
if (Test-Path $stylesDir) {
    Get-ChildItem -Path $stylesDir -Filter "*.md" | ForEach-Object {
        Copy-Item $_.FullName -Destination "$claudeDir\output-styles\" -Force
        Write-Host "  $($_.Name)" -ForegroundColor Green
    }
}
Write-Host ""

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Restart Claude Code to load the new extensions." -ForegroundColor Yellow
Write-Host ""
