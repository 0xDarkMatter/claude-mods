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

    # Agents require both name and description
    if ($Type -eq "agent") {
        if (-not $name) {
            Write-Fail "$FilePath - Missing required field: name"
            return $false
        }
        if (-not $description) {
            Write-Fail "$FilePath - Missing required field: description"
            return $false
        }
    }

    # Commands only require description
    if ($Type -eq "command") {
        if (-not $description) {
            Write-Fail "$FilePath - Missing required field: description"
            return $false
        }
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
            # Skip README and LICENSE files
            if ($file.Name -eq "README.md" -or $file.Name -eq "LICENSE.md") {
                continue
            }

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
        # Skip shared helper dirs (e.g. _lib) - not skills, no SKILL.md expected.
        if ($subdir.Name -like "_*") { continue }

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

function Test-Rules {
    Write-Host ""
    Write-Host "=== Validating Rules ===" -ForegroundColor Cyan

    $rulesDir = Join-Path $ProjectDir "templates\rules"
    if (-not (Test-Path $rulesDir)) {
        Write-Host "  (no templates/rules/ directory - skipping)"
        return
    }

    $files = Get-ChildItem -Path $rulesDir -Filter "*.md" -File -Recurse
    foreach ($file in $files) {
        # Rules should be .md files
        if ($file.Extension -ne ".md") {
            Write-Warn "$($file.FullName) - Rule file should be .md"
            continue
        }

        # Check if file has content
        if ($file.Length -eq 0) {
            Write-Fail "$($file.FullName) - Empty rule file"
            continue
        }

        $content = Get-Content -Path $file.FullName -Raw

        # Check for valid YAML frontmatter if present
        if ($content.StartsWith("---")) {
            $lines = $content -split "`n"
            $foundClosing = $false
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq "---") {
                    $foundClosing = $true
                    break
                }
            }

            if (-not $foundClosing) {
                Write-Fail "$($file.FullName) - Invalid YAML frontmatter (no closing ---)"
                continue
            }

            # If paths field exists, check it's not empty
            $paths = Get-YamlField -FilePath $file.FullName -Field "paths"
            if ($content -match "^paths:" -and -not $paths) {
                Write-Warn "$($file.FullName) - paths field is empty"
            }
        }

        # Check naming convention (kebab-case)
        $basename = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($basename -notmatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$") {
            Write-Warn "$($file.FullName) - Filename not kebab-case: $basename"
        }

        Write-Pass "$($file.FullName) - Valid rule"
    }
}

function Test-Settings {
    Write-Host ""
    Write-Host "=== Validating Settings ===" -ForegroundColor Cyan

    $settingsFile = Join-Path $ProjectDir "templates\settings.local.json"
    if (-not (Test-Path $settingsFile)) {
        Write-Host "  (no templates/settings.local.json - skipping)"
        return
    }

    # Check if valid JSON
    try {
        $settings = Get-Content -Path $settingsFile -Raw | ConvertFrom-Json
    } catch {
        Write-Fail "$settingsFile - Invalid JSON"
        return
    }

    # Check for permissions structure
    if (-not $settings.permissions) {
        Write-Fail "$settingsFile - Missing 'permissions' key"
    } else {
        # Check permissions has allow array
        if (-not ($settings.permissions.allow -is [array])) {
            Write-Fail "$settingsFile - permissions.allow should be an array"
        } else {
            Write-Pass "$settingsFile - Valid permissions structure"
        }
    }

    # Check for hooks structure (optional but if present should be object)
    if ($settings.hooks) {
        $validEvents = @("PreToolUse", "PostToolUse", "PermissionRequest", "Notification",
                         "UserPromptSubmit", "Stop", "SubagentStop", "PreCompact",
                         "SessionStart", "SessionEnd")

        $hookEvents = $settings.hooks.PSObject.Properties.Name
        foreach ($event in $hookEvents) {
            if ($event -notin $validEvents) {
                Write-Warn "$settingsFile - Unknown hook event: $event"
            }
        }

        if ($hookEvents.Count -gt 0) {
            Write-Pass "$settingsFile - Valid hooks structure"
        } else {
            Write-Pass "$settingsFile - Hooks defined (empty)"
        }
    }
}

function Test-Plugin {
    Write-Host ""
    Write-Host "=== Validating Plugin Manifests ===" -ForegroundColor Cyan

    $pluginDir = Join-Path $ProjectDir ".claude-plugin"

    # --- plugin.json ---
    $pluginFile = Join-Path $pluginDir "plugin.json"
    if (-not (Test-Path $pluginFile)) {
        Write-Fail ".claude-plugin/plugin.json - Missing"
    } else {
        try {
            $plugin = Get-Content -Path $pluginFile -Raw | ConvertFrom-Json
            if ($plugin.name -is [string] -and $plugin.name) {
                Write-Pass "$pluginFile - Valid plugin manifest"
            } else {
                Write-Fail "$pluginFile - Missing required field: name"
            }
        } catch {
            Write-Fail "$pluginFile - Invalid JSON"
        }
    }

    # --- marketplace.json location guard ---
    # The spec mandates .claude-plugin/marketplace.json. A copy at the repo
    # root is the regression that caused /plugin marketplace add to fail (#4).
    if (Test-Path (Join-Path $ProjectDir "marketplace.json")) {
        Write-Fail "marketplace.json found at repo root - must live at .claude-plugin/marketplace.json"
    }

    $mktFile = Join-Path $pluginDir "marketplace.json"
    if (-not (Test-Path $mktFile)) {
        Write-Fail ".claude-plugin/marketplace.json - Missing (required for /plugin marketplace add)"
        return
    }

    try {
        $mkt = Get-Content -Path $mktFile -Raw | ConvertFrom-Json
    } catch {
        Write-Fail "$mktFile - Invalid JSON"
        return
    }

    $ok = $true

    if (-not ($mkt.name -is [string] -and $mkt.name)) {
        Write-Fail "$mktFile - Missing required field: name (string)"
        $ok = $false
    }

    # owner must be an object with a name - this is the field whose absence
    # produced "owner: expected object, received undefined" (#4).
    if ($null -eq $mkt.owner -or $mkt.owner -isnot [PSCustomObject]) {
        Write-Fail "$mktFile - Missing required field: owner (object with a name)"
        $ok = $false
    } elseif (-not ($mkt.owner.name -is [string] -and $mkt.owner.name)) {
        Write-Fail "$mktFile - owner.name missing (owner must be an object with a name)"
        $ok = $false
    }

    if ($mkt.plugins -isnot [array]) {
        Write-Fail "$mktFile - Missing required field: plugins (array)"
        $ok = $false
    } else {
        $bad = 0
        foreach ($p in $mkt.plugins) {
            if (-not ($p.name -is [string] -and $p.name) -or $null -eq $p.source) { $bad++ }
        }
        if ($bad -gt 0) {
            Write-Fail "$mktFile - $bad plugin entry/entries missing name or source"
            $ok = $false
        }
    }

    if ($ok) {
        Write-Pass "$mktFile - Valid marketplace manifest"
    }
}

# Main
Write-Host "claude-mods Validation"
Write-Host "======================"
Write-Host "Project: $ProjectDir"

Test-Agents
Test-Commands
Test-Skills
Test-Rules
Test-Settings
Test-Plugin

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
