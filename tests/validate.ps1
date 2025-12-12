# claude-mods validation script (PowerShell)
# Validates YAML frontmatter, required fields, and naming conventions

param(
    [switch]$YamlOnly,
    [switch]$NamesOnly
)

$ErrorActionPreference = "Stop"

# Counters
$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

# Get project directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

function Write-Pass {
    param([string]$Message)
    Write-Host "PASS" -ForegroundColor Green -NoNewline
    Write-Host ": $Message"
    $script:Pass++
}

function Write-Fail {
    param([string]$Message)
    Write-Host "FAIL" -ForegroundColor Red -NoNewline
    Write-Host ": $Message"
    $script:Fail++
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN" -ForegroundColor Yellow -NoNewline
    Write-Host ": $Message"
    $script:Warn++
}

function Test-YamlFrontmatter {
    param([string]$FilePath)

    $content = Get-Content -Path $FilePath -Raw

    # Check for opening ---
    if (-not $content.StartsWith("---")) {
        Write-Fail "$FilePath - Missing YAML frontmatter (no opening ---)"
        return $false
    }

    # Check for closing ---
    $lines = $content -split "`n"
    $foundClosing = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") {
            $foundClosing = $true
            break
        }
    }

    if (-not $foundClosing) {
        Write-Fail "$FilePath - Invalid YAML frontmatter (no closing ---)"
        return $false
    }

    return $true
}

function Get-YamlField {
    param(
        [string]$FilePath,
        [string]$Field
    )

    $content = Get-Content -Path $FilePath -Raw
    $lines = $content -split "`n"

    $inFrontmatter = $false
    foreach ($line in $lines) {
        if ($line.Trim() -eq "---") {
            if ($inFrontmatter) { break }
            $inFrontmatter = $true
            continue
        }

        if ($inFrontmatter -and $line -match "^${Field}:\s*(.+)$") {
            $value = $matches[1].Trim()
            # Remove quotes
            $value = $value -replace '^["'']|["'']$', ''
            return $value
        }
    }

    return $null
}

function Test-RequiredFields {
    param(
        [string]$FilePath,
        [string]$Type
    )

    $name = Get-YamlField -FilePath $FilePath -Field "name"
    $description = Get-YamlField -FilePath $FilePath -Field "description"

    if (-not $name) {
        Write-Fail "$FilePath - Missing required field: name"
        return $false
    }

    if (-not $description) {
        Write-Fail "$FilePath - Missing required field: description"
        return $false
    }

    return $true
}

function Test-Naming {
    param([string]$FilePath)

    $basename = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

    # Check if filename is kebab-case
    if ($basename -notmatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$") {
        Write-Warn "$FilePath - Filename not kebab-case: $basename"
        return $false
    }

    # Check if name field matches filename
    $name = Get-YamlField -FilePath $FilePath -Field "name"
    if ($name -and $name -ne $basename) {
        Write-Warn "$FilePath - Name field '$name' doesn't match filename '$basename'"
        return $false
    }

    return $true
}

function Test-Agents {
    Write-Host ""
    Write-Host "=== Validating Agents ===" -ForegroundColor Cyan

    $agentDir = Join-Path $ProjectDir "agents"
    if (-not (Test-Path $agentDir)) {
        Write-Warn "agents/ directory not found"
        return
    }

    $files = Get-ChildItem -Path $agentDir -Filter "*.md" -File
    foreach ($file in $files) {
        if (-not $NamesOnly) {
            if (Test-YamlFrontmatter -FilePath $file.FullName) {
                if (Test-RequiredFields -FilePath $file.FullName -Type "agent") {
                    Write-Pass "$($file.FullName) - Valid agent"
                }
            }
        }

        if (-not $YamlOnly) {
            Test-Naming -FilePath $file.FullName | Out-Null
        }
    }
}

function Test-Commands {
    Write-Host ""
    Write-Host "=== Validating Commands ===" -ForegroundColor Cyan

    $cmdDir = Join-Path $ProjectDir "commands"
    if (-not (Test-Path $cmdDir)) {
        Write-Warn "commands/ directory not found"
        return
    }

    # Check .md files directly in commands/
    $files = Get-ChildItem -Path $cmdDir -Filter "*.md" -File
    foreach ($file in $files) {
        if (-not $NamesOnly) {
            if (Test-YamlFrontmatter -FilePath $file.FullName) {
                if (Test-RequiredFields -FilePath $file.FullName -Type "command") {
                    Write-Pass "$($file.FullName) - Valid command"
                }
            }
        }

        if (-not $YamlOnly) {
            Test-Naming -FilePath $file.FullName | Out-Null
        }
    }

    # Check subdirectories
    $subdirs = Get-ChildItem -Path $cmdDir -Directory
    foreach ($subdir in $subdirs) {
        $subFiles = Get-ChildItem -Path $subdir.FullName -Filter "*.md" -File
        foreach ($file in $subFiles) {
            if (-not $NamesOnly) {
                if (Test-YamlFrontmatter -FilePath $file.FullName) {
                    $desc = Get-YamlField -FilePath $file.FullName -Field "description"
                    if ($desc) {
                        Write-Pass "$($file.FullName) - Valid subcommand"
                    } else {
                        Write-Warn "$($file.FullName) - Missing description"
                    }
                }
            }
        }
    }
}

function Test-Skills {
    Write-Host ""
    Write-Host "=== Validating Skills ===" -ForegroundColor Cyan

    $skillsDir = Join-Path $ProjectDir "skills"
    if (-not (Test-Path $skillsDir)) {
        Write-Warn "skills/ directory not found"
        return
    }

    $subdirs = Get-ChildItem -Path $skillsDir -Directory
    foreach ($subdir in $subdirs) {
        $skillFile = Join-Path $subdir.FullName "SKILL.md"

        if (-not (Test-Path $skillFile)) {
            Write-Fail "$($subdir.FullName) - Missing SKILL.md"
            continue
        }

        if (-not $NamesOnly) {
            if (Test-YamlFrontmatter -FilePath $skillFile) {
                $name = Get-YamlField -FilePath $skillFile -Field "name"
                $desc = Get-YamlField -FilePath $skillFile -Field "description"

                if ($name -and $desc) {
                    Write-Pass "$skillFile - Valid skill"
                } else {
                    if (-not $name) { Write-Fail "$skillFile - Missing name" }
                    if (-not $desc) { Write-Fail "$skillFile - Missing description" }
                }
            }
        }
    }
}

# Main
Write-Host "claude-mods Validation"
Write-Host "======================"
Write-Host "Project: $ProjectDir"

Test-Agents
Test-Commands
Test-Skills

Write-Host ""
Write-Host "======================"
Write-Host "Results: " -NoNewline
Write-Host "$script:Pass passed" -ForegroundColor Green -NoNewline
Write-Host ", " -NoNewline
Write-Host "$script:Fail failed" -ForegroundColor Red -NoNewline
Write-Host ", " -NoNewline
Write-Host "$script:Warn warnings" -ForegroundColor Yellow

if ($script:Fail -gt 0) {
    exit 1
}

exit 0
