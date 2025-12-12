# claude-mods installer for Windows
# Creates symlinks to Claude Code directories (requires admin or developer mode)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"

Write-Host "Installing claude-mods..." -ForegroundColor Cyan
Write-Host "Source: $ScriptDir"
Write-Host "Target: $ClaudeDir"
Write-Host ""

# Create Claude directories if they don't exist
$dirs = @("commands", "skills", "agents")
foreach ($dir in $dirs) {
    $path = Join-Path $ClaudeDir $dir
    if (!(Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# Install commands
Write-Host "Installing commands..." -ForegroundColor Yellow
$commandsDir = Join-Path $ScriptDir "commands"
if (Test-Path $commandsDir) {
    Get-ChildItem -Path $commandsDir -Directory | ForEach-Object {
        $cmdName = $_.Name
        $cmdFile = Join-Path $_.FullName "$cmdName.md"
        if (Test-Path $cmdFile) {
            $target = Join-Path $ClaudeDir "commands\$cmdName.md"
            if (Test-Path $target) {
                Write-Host "  Updating: $cmdName.md"
                Remove-Item $target -Force
            } else {
                Write-Host "  Installing: $cmdName.md"
            }
            # Try symlink first, fall back to copy
            try {
                New-Item -ItemType SymbolicLink -Path $target -Target $cmdFile -Force | Out-Null
            } catch {
                Copy-Item $cmdFile $target -Force
                Write-Host "    (copied - enable Developer Mode for symlinks)" -ForegroundColor DarkGray
            }
        }
    }
}

# Install skills
Write-Host "Installing skills..." -ForegroundColor Yellow
$skillsDir = Join-Path $ScriptDir "skills"
if (Test-Path $skillsDir) {
    Get-ChildItem -Path $skillsDir -Directory | ForEach-Object {
        $skillName = $_.Name
        $target = Join-Path $ClaudeDir "skills\$skillName"
        if (Test-Path $target) {
            Write-Host "  Updating: $skillName"
            Remove-Item $target -Recurse -Force
        } else {
            Write-Host "  Installing: $skillName"
        }
        # Try symlink first, fall back to copy
        try {
            New-Item -ItemType SymbolicLink -Path $target -Target $_.FullName -Force | Out-Null
        } catch {
            Copy-Item $_.FullName $target -Recurse -Force
            Write-Host "    (copied - enable Developer Mode for symlinks)" -ForegroundColor DarkGray
        }
    }
}

# Install agents
Write-Host "Installing agents..." -ForegroundColor Yellow
$agentsDir = Join-Path $ScriptDir "agents"
if (Test-Path $agentsDir) {
    Get-ChildItem -Path $agentsDir -Filter "*.md" | ForEach-Object {
        $agentName = $_.Name
        $target = Join-Path $ClaudeDir "agents\$agentName"
        if (Test-Path $target) {
            Write-Host "  Updating: $agentName"
            Remove-Item $target -Force
        } else {
            Write-Host "  Installing: $agentName"
        }
        # Try symlink first, fall back to copy
        try {
            New-Item -ItemType SymbolicLink -Path $target -Target $_.FullName -Force | Out-Null
        } catch {
            Copy-Item $_.FullName $target -Force
            Write-Host "    (copied - enable Developer Mode for symlinks)" -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Installed to:"
Write-Host "  Commands: $ClaudeDir\commands\"
Write-Host "  Skills:   $ClaudeDir\skills\"
Write-Host "  Agents:   $ClaudeDir\agents\"
