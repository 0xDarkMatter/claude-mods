<#
.SYNOPSIS
    Install claude-mods extensions to ~/.claude/

.DESCRIPTION
    Copies commands, skills, agents, and rules to the global Claude Code config.
    Handles cleanup of deprecated items and command-to-skill migrations.

.PARAMETER Statusline
    Opt in to installing the context-usage statusline. Off by default so a
    shared install never changes the user's prompt UI without being asked.

.NOTES
    Run from the claude-mods directory:
    .\scripts\install.ps1
    .\scripts\install.ps1 -Statusline
#>

param(
    [switch]$Statusline
)

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "           claude-mods Installer (Windows)                      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
if ($env:CLAUDE_DIR) {
    $claudeDir = $env:CLAUDE_DIR
} else {
    $claudeDir = "$env:USERPROFILE\.claude"
}

# Ensure ~/.claude directories exist
$dirs = @("commands", "skills", "agents", "rules", "output-styles", "hooks")
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
    "$claudeDir\skills\claude-code-templates",  # Replaced by skill-creator
    "$claudeDir\skills\agentmail",              # Renamed to pigeon (v2.3.0)
    "$claudeDir\skills\claude-code-debug",      # Merged into claude-code-ops (v3.0)
    "$claudeDir\skills\claude-code-headless",   # Merged into claude-code-ops (v3.0)
    "$claudeDir\skills\claude-code-hooks",      # Merged into claude-code-ops (v3.0)
    "$claudeDir\skills\dsp-launch",             # Superseded by fleet-worker + native background agents (2026-07)

    # Deprecated agents (v3.0): folded into their -ops skill twins
    "$claudeDir\agents\python-expert.md",
    "$claudeDir\agents\typescript-expert.md",
    "$claudeDir\agents\javascript-expert.md",
    "$claudeDir\agents\go-expert.md",
    "$claudeDir\agents\rust-expert.md",
    "$claudeDir\agents\react-expert.md",
    "$claudeDir\agents\vue-expert.md",
    "$claudeDir\agents\astro-expert.md",
    "$claudeDir\agents\laravel-expert.md",
    "$claudeDir\agents\sql-expert.md",
    "$claudeDir\agents\postgres-expert.md",
    "$claudeDir\agents\cypress-expert.md",        # -> skills/cypress-ops
    "$claudeDir\agents\cloudflare-expert.md",     # -> skills/cloudflare-ops
    "$claudeDir\agents\wrangler-expert.md",       # -> skills/cloudflare-ops
    "$claudeDir\agents\bash-expert.md",           # -> skills/bash-ops
    "$claudeDir\agents\claude-architect.md",      # -> skills/claude-code-ops
    "$claudeDir\agents\aws-fargate-ecs-expert.md", # -> skills/container-orchestration
    "$claudeDir\agents\craftcms-expert.md",       # -> skills/craftcms-ops
    "$claudeDir\agents\payloadcms-expert.md",     # -> skills/payloadcms-ops
    "$claudeDir\agents\asus-router-expert.md"     # -> skills/asus-router-ops
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
        try {
            Remove-Item -Path $oldPath -Recurse -Force -ErrorAction Stop
            $newName = $oldSkill -replace '-patterns$', '-ops'
            Write-Host "  Removed renamed: $oldSkill (now $newName)" -ForegroundColor Red
        } catch {
            Write-Host "  WARNING: could not remove $oldPath ($($_.Exception.Message)) - continuing" -ForegroundColor Yellow
        }
    }
}

Write-Host "Cleaning up deprecated items..." -ForegroundColor Yellow
foreach ($item in $deprecated) {
    if (Test-Path $item) {
        try {
            Remove-Item -Path $item -Recurse -Force -ErrorAction Stop
            Write-Host "  Removed: $item" -ForegroundColor Red
        } catch {
            Write-Host "  WARNING: could not remove $item ($($_.Exception.Message)) - continuing" -ForegroundColor Yellow
        }
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
# SKILLS - Merge-sync each skill directory (NEVER delete-then-copy)
#
# A registered service can hold a skill dir as its CWD (e.g. Process Compose
# "fleetflow" runs python ff-serve.py with CWD ~/.claude/skills/fleetflow),
# which locks the directory handle on Windows. On 2026-08-01 the old
# Remove-Item pass half-deleted that dir (destroying machine-local unversioned
# files) before failing, then aborted the run, leaving every skill after it
# unsynced. So: file-level overwrite copy (works while the dir is locked),
# dest-only files are reported but never deleted, and a failure on one skill
# continues to the next.
# =============================================================================
Write-Host "Installing skills..." -ForegroundColor Cyan

$skillsDir = Join-Path $projectRoot "skills"
$failedSkills = @()
foreach ($skill in (Get-ChildItem -Path $skillsDir -Directory)) {
    $src = $skill.FullName
    $dest = "$claudeDir\skills\$($skill.Name)"
    try {
        if (-not (Test-Path $dest)) {
            Copy-Item -Path $src -Destination $dest -Recurse -Force -ErrorAction Stop
            Write-Host "  $($skill.Name)/" -ForegroundColor Green
            continue
        }

        # Merge copy: overwrite file-by-file so a locked destination still syncs.
        $srcRel = @{}
        $fileErrors = @()
        foreach ($f in (Get-ChildItem -Path $src -Recurse -File)) {
            $rel = $f.FullName.Substring($src.Length + 1)
            $srcRel[$rel] = $true
            try {
                $destFile = Join-Path $dest $rel
                $destFileDir = Split-Path -Parent $destFile
                if (-not (Test-Path $destFileDir)) {
                    New-Item -ItemType Directory -Path $destFileDir -Force -ErrorAction Stop | Out-Null
                }
                Copy-Item -Path $f.FullName -Destination $destFile -Force -ErrorAction Stop
            } catch {
                $fileErrors += "$rel ($($_.Exception.Message))"
            }
        }

        # Dest-only files are machine-local (unversioned) or stale. Surface
        # them, never delete them - deleting is the 2026-08-01 data loss.
        $destOnly = @(Get-ChildItem -Path $dest -Recurse -File | Where-Object {
            -not $srcRel.ContainsKey($_.FullName.Substring($dest.Length + 1))
        })

        if ($fileErrors.Count -gt 0) {
            $failedSkills += $skill.Name
            Write-Host "  $($skill.Name)/ - $($fileErrors.Count) file(s) failed to sync:" -ForegroundColor Red
            foreach ($e in $fileErrors) { Write-Host "    $e" -ForegroundColor Red }
        } elseif ($destOnly.Count -gt 0) {
            Write-Host "  $($skill.Name)/ (kept $($destOnly.Count) dest-only file(s) not in repo)" -ForegroundColor Yellow
            foreach ($f in $destOnly) {
                Write-Host "    $($f.FullName.Substring($dest.Length + 1))" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  $($skill.Name)/" -ForegroundColor Green
        }
    } catch {
        $failedSkills += $skill.Name
        Write-Host "  WARNING: $($skill.Name)/ failed to sync ($($_.Exception.Message)) - continuing" -ForegroundColor Red
    }
}
if ($failedSkills.Count -gt 0) {
    Write-Host ""
    Write-Host "  $($failedSkills.Count) skill(s) had sync failures: $($failedSkills -join ', ')" -ForegroundColor Red
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
# HOOKS - Copy scripts and merge plugin-equivalent wiring into settings.json
# =============================================================================
Write-Host "Installing hooks..." -ForegroundColor Cyan

$hooksDir = Join-Path $projectRoot "hooks"
Get-ChildItem -Path $hooksDir -Filter "*.sh" | ForEach-Object {
    Copy-Item $_.FullName -Destination "$claudeDir\hooks\" -Force
}

$settingsPath = Join-Path $claudeDir "settings.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}
if (-not $settings.PSObject.Properties["hooks"]) {
    $settings | Add-Member -MemberType NoteProperty -Name hooks -Value ([PSCustomObject]@{})
}

$desired = Get-Content (Join-Path $hooksDir "hooks.json") -Raw | ConvertFrom-Json
foreach ($eventProperty in $desired.hooks.PSObject.Properties) {
    $eventName = $eventProperty.Name
    if (-not $settings.hooks.PSObject.Properties[$eventName]) {
        $settings.hooks | Add-Member -MemberType NoteProperty -Name $eventName -Value @()
    }
    $eventGroups = @($settings.hooks.$eventName)
    foreach ($group in @($eventProperty.Value)) {
        $missingHooks = @()
        foreach ($hook in @($group.hooks)) {
            $command = $hook.command.Replace('${CLAUDE_PLUGIN_ROOT}/hooks', (Join-Path $claudeDir "hooks"))
            # Dedup on the script NAME under hooks/, not the resolved path: a
            # hook wired by a plugin install carries the
            # ${CLAUDE_PLUGIN_ROOT}/hooks/ form and must still count as
            # already-wired (mixed-method double-fire). Separator-tolerant:
            # Join-Path yields \hooks while plugin form uses /hooks.
            $hookName = ($command -replace '^.*hooks[/\\]', '') -replace '"$', ''
            $alreadyWired = $false
            foreach ($existingGroup in $eventGroups) {
                foreach ($existingHook in @($existingGroup.hooks)) {
                    if ($existingHook.command -and ($existingHook.command.Contains("hooks/$hookName") -or $existingHook.command.Contains("hooks\$hookName"))) {
                        $alreadyWired = $true
                    }
                }
            }
            if (-not $alreadyWired) {
                $copy = $hook.PSObject.Copy()
                $copy.command = $command
                $missingHooks += $copy
            }
        }
        if ($missingHooks.Count -gt 0) {
            $newGroup = $group.PSObject.Copy()
            $newGroup.hooks = $missingHooks
            $eventGroups += $newGroup
        }
    }
    $settings.hooks.$eventName = $eventGroups
}

# STATUSLINE - opt-in only (-Statusline). Even when opted in we add it ONLY if
# the user has none: a statusline is a whole-config key, so we never clobber
# one the user already set, and we touch nothing else.
if ($Statusline) {
    if (-not $settings.PSObject.Properties["statusLine"]) {
        $statuslineTemplate = Join-Path $projectRoot "templates\settings.json"
        if (Test-Path $statuslineTemplate) {
            $tpl = Get-Content $statuslineTemplate -Raw | ConvertFrom-Json
            if ($tpl.PSObject.Properties["statusLine"]) {
                $settings | Add-Member -MemberType NoteProperty -Name statusLine -Value $tpl.statusLine
                Write-Host "  Context-usage statusline added to settings.json" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  Existing statusline preserved (remove it first to use the claude-mods one)" -ForegroundColor Green
    }
} else {
    Write-Host "  Statusline skipped (re-run with -Statusline to install it)" -ForegroundColor DarkGray
}

$settings | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding UTF8
Write-Host "  Security and peer-guard hooks wired in settings.json" -ForegroundColor Green
Write-Host ""

# =============================================================================
# PIGEON - Global install (scripts + hook config hint)
# =============================================================================
Write-Host "Installing pigeon (pmail)..." -ForegroundColor Cyan

# Clean up old agentmail install if present
$oldAgentmailDir = Join-Path $claudeDir "agentmail"
if (Test-Path $oldAgentmailDir) {
    Remove-Item -Path $oldAgentmailDir -Recurse -Force
    Write-Host "  Removed old agentmail/ (renamed to pigeon/)" -ForegroundColor Red
}

$pigeonDir = Join-Path $claudeDir "pigeon"
New-Item -ItemType Directory -Force -Path $pigeonDir | Out-Null

$mailDbSrc = Join-Path $projectRoot "skills\pigeon\scripts\mail-db.sh"
$checkMailSrc = Join-Path $projectRoot "hooks\check-mail.sh"

if (Test-Path $mailDbSrc) {
    Copy-Item $mailDbSrc -Destination "$pigeonDir\" -Force
    Write-Host "  mail-db.sh" -ForegroundColor Green
}
if (Test-Path $checkMailSrc) {
    Copy-Item $checkMailSrc -Destination "$pigeonDir\" -Force
    Write-Host "  check-mail.sh" -ForegroundColor Green
}

$settingsPath = Join-Path $claudeDir "settings.json"

# Migrate stale agentmail hook path -> pigeon
if ((Test-Path $settingsPath) -and (Select-String -Path $settingsPath -Pattern "agentmail/check-mail\.sh" -Quiet)) {
    $content = Get-Content $settingsPath -Raw
    $content = $content -replace 'agentmail/check-mail\.sh', 'pigeon/check-mail.sh'
    Set-Content $settingsPath -Value $content -NoNewline
    Write-Host "  Migrated agentmail hook -> pigeon in settings.json" -ForegroundColor Green
}

# Check if hook is already configured (pigeon path)
if ((Test-Path $settingsPath) -and (Select-String -Path $settingsPath -Pattern "pigeon/check-mail\.sh" -Quiet)) {
    Write-Host "  Hook already configured in settings.json" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host '  To enable automatic pmail notifications, add this to ~/.claude/settings.json:' -ForegroundColor Yellow
    Write-Host ""
    Write-Host '  "hooks": {'
    Write-Host '    "PreToolUse": [{'
    Write-Host '      "matcher": "*",'
    Write-Host '      "hooks": [{'
    Write-Host '        "type": "command",'
    Write-Host '        "command": "bash \"$HOME/.claude/pigeon/check-mail.sh\"",'
    Write-Host '        "timeout": 5'
    Write-Host '      }]'
    Write-Host '    }]'
    Write-Host '  }'
    Write-Host ""
    Write-Host "  Without this, pigeon works but you must check manually (pigeon read)." -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# AUTO-SKILL - Global install (tracking + evaluation hooks)
# =============================================================================
Write-Host "Installing auto-skill..." -ForegroundColor Cyan

$autoSkillDir = Join-Path $claudeDir "auto-skill"
New-Item -ItemType Directory -Force -Path $autoSkillDir | Out-Null

$scripts = @("track-tools.sh", "evaluate.sh")
foreach ($script in $scripts) {
    $src = Join-Path $projectRoot "skills\auto-skill\scripts\$script"
    if (Test-Path $src) {
        Copy-Item $src -Destination "$autoSkillDir\" -Force
        Write-Host "  $script" -ForegroundColor Green
    }
}

$settingsPath = Join-Path $claudeDir "settings.json"
if ((Test-Path $settingsPath) -and (Select-String -Path $settingsPath -Pattern "auto-skill" -Quiet)) {
    Write-Host "  Hooks already configured in settings.json" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host '  To enable automatic skill suggestions, add these hooks to ~/.claude/settings.json:' -ForegroundColor Yellow
    Write-Host ""
    Write-Host '  "PostToolUse": [{ "matcher": "*", "hooks": [{'
    Write-Host '    "type": "command",'
    Write-Host '    "command": "bash \"$HOME/.claude/auto-skill/track-tools.sh\"", "timeout": 2'
    Write-Host '  }] }],'
    Write-Host '  "Stop": [{ "hooks": [{'
    Write-Host '    "type": "command",'
    Write-Host '    "command": "bash \"$HOME/.claude/auto-skill/evaluate.sh\"", "timeout": 5'
    Write-Host '  }] }]'
    Write-Host ""
    Write-Host "  Without this, /auto-skill still works but won't suggest automatically." -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# LINE ENDINGS - Strip CRs from every installed shell script
#
# bash refuses CRLF: `$'\r': command not found`, and a `#!/bin/bash\r` shebang
# exits 127 ("No such file or directory"). .gitattributes pins *.sh to LF at
# checkout, but a clone that predates it (or any tool that rewrote endings)
# still carries CRLF - on 2026-08-08 that broke the installed
# ~/.claude/hooks/pre-commit-unicode-scan.sh and with it the repo's own
# pre-commit gate. Normalizing here makes the installed copy runnable
# regardless of the source tree's line endings.
# =============================================================================
Write-Host "Normalizing shell-script line endings..." -ForegroundColor Cyan

$crFixed = 0
foreach ($d in @("hooks", "skills", "pigeon", "auto-skill")) {
    $root = Join-Path $claudeDir $d
    if (-not (Test-Path $root)) { continue }
    foreach ($f in (Get-ChildItem -Path $root -Recurse -File)) {
        $isShell = $f.Name -match '\.sh(\.template)?$'
        if (-not $isShell -and -not $f.Extension) {
            # Extension-less files are shell iff they open with a shebang.
            try {
                $fs = [System.IO.File]::OpenRead($f.FullName)
                $buf = New-Object byte[] 2
                $n = $fs.Read($buf, 0, 2)
                $fs.Close()
                $isShell = ($n -eq 2 -and $buf[0] -eq 0x23 -and $buf[1] -eq 0x21)
            } catch { $isShell = $false }
        }
        if (-not $isShell) { continue }
        try {
            $raw = [System.IO.File]::ReadAllText($f.FullName)
            if ($raw.Contains("`r")) {
                [System.IO.File]::WriteAllText($f.FullName, ($raw -replace "`r", ""))
                $crFixed++
            }
        } catch {
            Write-Host "  WARNING: could not normalize $($f.FullName) ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }
}
if ($crFixed -gt 0) {
    Write-Host "  Converted $crFixed script(s) from CRLF to LF" -ForegroundColor Green
} else {
    Write-Host "  All shell scripts already LF" -ForegroundColor Green
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
