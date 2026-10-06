<#
.SYNOPSIS
    Install claude-mods extensions to ~/.claude/ (or diagnose an existing install).

.DESCRIPTION
    Copies commands, skills, agents, rules, output styles and hooks to the
    global Claude Code config. Handles cleanup of deprecated items and
    command-to-skill migrations.

    WHY THE GUARD AND THE DOCTOR EXIST
    ~/.claude is a single shared mutable resource, but this installer is run
    from whatever tree the session happens to be sitting in. There is no
    ordering discipline between parallel lanes, so a session installing from a
    checkout that predates another lane's landed work silently overwrites it.

    Observed 2026-08-31: the installed loop-ops SKILL.md was 343 lines while
    main had 454. Six skills had been reverted by an older tree's install -
    exactly the set touched by main's most recent commits. Nothing errored and
    nothing warned; the only symptom was a skill description quietly reading
    wrong in a session's skill listing. It is worse than a clean revert,
    because the installer deliberately keeps dest-only files (see the SKILLS
    section below), so the NEW files survive while the SKILL.md documenting
    them reverts - a half-updated state that is harder to spot.

    So: a staleness guard refuses an install that would revert landed work
    (-Force overrides), and -Doctor reports the drift read-only.

    NOTE ON COMPARISON: every repo-vs-installed comparison here is
    line-ending-insensitive. Many SKILL.md files are committed CRLF while the
    installed copies land LF, so a naive byte compare flags most of the skill
    tree as drifted when nothing is wrong. A guard that cries wolf on scores of
    false positives gets disabled within a day and is worse than no guard.

.PARAMETER Statusline
    Opt in to installing the context-usage statusline. Off by default so a
    shared install never changes the user's prompt UI without being asked.

.PARAMETER Doctor
    Read-only. Report staleness of the source tree plus per-file drift between
    the repo and the install target. Writes nothing. Exit 0 clean, 10 when
    stale or missing content is found.

.PARAMETER Force
    Install even when the staleness guard fires. Use when you knowingly want
    this tree's content to win.

.PARAMETER Json
    With -Doctor, emit a machine-readable envelope on stdout instead of a
    human report. Schema: claude-mods.install.doctor/v1.

.PARAMETER Help
    Print usage and examples to stdout, then exit 0.

.NOTES
    Install target is $env:CLAUDE_DIR when set, else ~/.claude.

    Exit codes: 0 success, 2 usage, 5 precondition, 10 domain signal
    (guard fired / drift found).

.EXAMPLE
    .\scripts\install.ps1
    Install from the current tree, refusing if it would revert landed work.

.EXAMPLE
    .\scripts\install.ps1 -Statusline
    Install and opt in to the context-usage statusline.

.EXAMPLE
    .\scripts\install.ps1 -Doctor
    Report what differs between this tree and the install target. Writes nothing.

.EXAMPLE
    .\scripts\install.ps1 -Doctor -Json
    Same, as JSON on stdout, for a pre-flight check or a hook.

.EXAMPLE
    .\scripts\install.ps1 -Force
    Install even though the guard says this tree is behind main.
#>

param(
    [switch]$Statusline,
    [switch]$Doctor,
    [switch]$Force,
    [switch]$Json,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
# INVARIANT: every path derived from $projectRoot or $claudeDir is passed as
# -LiteralPath, never -Path. `[` and `]` are PowerShell wildcard
# metacharacters, and both roots are attacker-free but bracket-prone: a git
# worktree at `.claude\worktrees\lane[1]\` makes every -Path enumeration
# glob-expand to NOTHING and return an empty set with no error - the
# installer prints its whole banner and installs zero skills, agents and
# rules. -Filter and -Recurse are unaffected (they walk children through the
# provider); only the enumeration ROOT expands, so -LiteralPath is a drop-in.
# New-Item -Path is the one exception left: it creates, so it is already
# literal, and it has no -LiteralPath parameter.
# tests/install-guard.sh section 11 asserts this behaviourally; the grep in
# tests/check-resources.sh is the Linux-CI backstop.
# SECOND INVARIANT: relative paths come only from Get-FilesUnder, never from
# FullName.Substring against a root string - see RELATIVE PATHS below for the
# 8.3 short-name trap that made every CI doctor run report phantom drift.
if ($env:CLAUDE_DIR) {
    $claudeDir = $env:CLAUDE_DIR
} else {
    $claudeDir = "$env:USERPROFILE\.claude"
}

# Paths this installer copies FROM the repo. Both the guard (which commits
# would be reverted) and the doctor (which files differ) are scoped to these -
# a README-only commit on main cannot revert anything installable.
$installablePaths = @("skills", "agents", "rules", "commands", "output-styles", "hooks")

# Commands migrated to skills; the installer never copies them, so the doctor
# must not report them as missing either. Keep in step with $skipCommands below.
$skipCommandFiles = @("review.md", "testgen.md")

# =============================================================================
# HELP
# =============================================================================
if ($Help) {
    @'
install.ps1 - install claude-mods extensions to the global Claude Code config.

USAGE
  install.ps1 [-Statusline] [-Force]
  install.ps1 -Doctor [-Json]
  install.ps1 -Help

OPTIONS
  -Statusline   Also install the context-usage statusline (opt-in).
  -Force        Install even when the staleness guard fires.
  -Doctor       Read-only drift report. Writes nothing.
  -Json         With -Doctor, emit JSON on stdout instead of a human report.
  -Help         This text.

ENVIRONMENT
  CLAUDE_DIR    Install target. Defaults to ~/.claude.

EXIT CODES
  0   Success / no drift found.
  2   Usage error.
  5   Precondition failed (install target unreadable).
  10  Domain signal: staleness guard fired, or doctor found stale/missing files.

EXAMPLES
  install.ps1
  install.ps1 -Statusline
  install.ps1 -Doctor
  install.ps1 -Doctor -Json
  install.ps1 -Force
'@
    exit 0
}

if ($Json -and -not $Doctor) {
    # Write-Error would terminate under ErrorActionPreference=Stop and mask
    # the semantic exit code, so write to stderr directly.
    [Console]::Error.WriteLine("install.ps1: -Json is only meaningful with -Doctor.")
    exit 2
}

# =============================================================================
# GIT HELPERS
#
# Every git failure here degrades to "unknown" rather than aborting: a missing
# git, a tarball download, a detached HEAD or a repo without main are all
# legitimate ways to run this installer, and none of them should block it.
# =============================================================================
function Invoke-GitRaw {
    param([string[]]$GitArgs)

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # PS 7.4+ turns a non-zero native exit into a terminating error under
    # ErrorActionPreference=Stop. `merge-base --is-ancestor` answers "no" with
    # exit 1, which is data, not a fault - so opt out for the duration.
    $prevNative = $null
    if (Test-Path Variable:\PSNativeCommandUseErrorActionPreference) {
        $prevNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $out = @()
    $code = 127
    try {
        $out = @(& git -C $projectRoot @GitArgs 2>$null)
        $code = $LASTEXITCODE
    } catch {
        $out = @()
        $code = 127
    } finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNative) { $PSNativeCommandUseErrorActionPreference = $prevNative }
    }
    return [PSCustomObject]@{ Ok = ($code -eq 0); Code = $code; Out = $out }
}

# Returns: status ok|behind|unknown, plus the files an install would revert.
#
# "behind" means specifically: main contains commits this tree does not, AND
# those commits touch installable paths. A branch that is merely AHEAD of an
# up-to-date main is the normal lane workflow and must stay silent - a guard
# that fires on every feature branch gets deleted within a day.
function Get-StalenessReport {
    $report = [PSCustomObject]@{
        status        = 'unknown'
        branch        = $null
        base          = $null
        revertedFiles = @()
        reason        = ''
    }

    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        $report.reason = 'git is not on PATH'
        return $report
    }

    $inside = Invoke-GitRaw @('rev-parse', '--is-inside-work-tree')
    if (-not $inside.Ok) {
        $report.reason = 'not a git working tree'
        return $report
    }

    $branch = Invoke-GitRaw @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($branch.Ok -and $branch.Out.Count -gt 0) {
        $report.branch = $branch.Out[0]
    } else {
        # Detached HEAD is still comparable - only the label is missing.
        $report.branch = '(detached HEAD)'
    }

    foreach ($candidate in @('main', 'origin/main')) {
        $verify = Invoke-GitRaw @('rev-parse', '--verify', '--quiet', "$candidate^{commit}")
        if ($verify.Ok -and $verify.Out.Count -gt 0) {
            $report.base = $candidate
            break
        }
    }
    if (-not $report.base) {
        $report.reason = 'no main or origin/main branch to compare against'
        return $report
    }

    $ancestor = Invoke-GitRaw @('merge-base', '--is-ancestor', $report.base, 'HEAD')
    if ($ancestor.Ok) {
        $report.status = 'ok'
        $report.reason = "$($report.base) is fully contained in HEAD"
        return $report
    }
    if ($ancestor.Code -ne 1) {
        $report.reason = "git merge-base failed (exit $($ancestor.Code))"
        return $report
    }

    $logArgs = @('log', "HEAD..$($report.base)", '--name-only', '--pretty=format:', '--') + $installablePaths
    $log = Invoke-GitRaw $logArgs
    if (-not $log.Ok) {
        $report.reason = "git log failed (exit $($log.Code))"
        return $report
    }

    $files = @($log.Out | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($files.Count -eq 0) {
        $report.status = 'ok'
        $report.reason = "behind $($report.base), but no installable paths are affected"
        return $report
    }

    $report.status = 'behind'
    $report.revertedFiles = $files
    $report.reason = "$($report.base) has commits this tree lacks that touch installable paths"
    return $report
}

# =============================================================================
# RELATIVE PATHS - the only place this script turns a full path into a
# path relative to a root.
#
# Never write $f.FullName.Substring($root.Length + 1) against a root spelled
# by the caller. The FileSystem provider (5.1 and 7.x alike) hands children
# back under ITS canonical spelling of the root: 8.3 short names expanded,
# `..` collapsed, doubled separators dropped. Each of those changes the prefix
# LENGTH, so the substring silently shifts by the difference. A GitHub Windows
# runner's %TEMP% is C:\Users\RUNNER~1\... ("runneradmin", three characters
# longer), so an installed skills/alpha/SKILL.md read back as
# skills/ls/alpha/SKILL.md: the doctor called every installed skill file both
# missing and orphaned, and the merge-copy listed every dest file as dest-only.
# Resolving the root through the same provider and enumerating FROM that
# spelling makes the prefix match by construction. tests/install-guard.sh
# section 12 proves it; tests/check-resources.sh greps for the old pattern.
# =============================================================================
function Get-FilesUnder {
    param([string]$Root, [switch]$SkipUnreadable)

    $base = (Get-Item -LiteralPath $Root -Force).FullName
    $prefix = if ($base.EndsWith('\')) { $base } else { $base + '\' }
    $onError = if ($SkipUnreadable) { 'SilentlyContinue' } else { 'Stop' }
    foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction $onError)) {
        if (-not $f.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            # Unreachable while the provider is self-consistent. If it ever is
            # not, a loud failure beats relative paths that are silently wrong.
            throw "install.ps1: enumerated '$($f.FullName)' outside its root '$base'"
        }
        [PSCustomObject]@{ Rel = $f.FullName.Substring($prefix.Length); FullName = $f.FullName }
    }
}

# =============================================================================
# CONTENT COMPARISON (line-ending-insensitive - see the note in .DESCRIPTION)
# =============================================================================
function Get-ContentFingerprint {
    param([string]$Path)

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        return $null
    }

    # A NUL byte in the head means binary: hash it raw. Text is decoded and
    # CR-stripped so CRLF-vs-LF alone never reads as drift.
    $probe = [Math]::Min($bytes.Length, 8192)
    $isBinary = $false
    for ($i = 0; $i -lt $probe; $i++) {
        if ($bytes[$i] -eq 0) { $isBinary = $true; break }
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if (-not $isBinary) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes).Replace("`r", "")
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        }
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes))
    } finally {
        $sha.Dispose()
    }
}

# Relative-path -> full-path map for one installable category, on one side.
# Mirrors exactly what the install sections below copy, so the doctor cannot
# report a file as "missing" that the installer was never going to write.
function Get-CategoryFiles {
    param([string]$Root, [string]$Category)

    $dir = Join-Path $Root $Category
    $map = @{}
    # -LiteralPath throughout: `[` and `]` are PowerShell wildcard
    # metacharacters, so -Path silently drops a bracketed name such as a
    # Next.js dynamic-route fixture (`app/shop/[slug]/page.tsx`) with no error.
    # In a DOCTOR that is the worst possible failure - it would read clean while
    # the very files it exists to notice were invisible to it. Same bug the
    # skill-sync copy hit on 2026-08-31.
    if (-not (Test-Path -LiteralPath $dir)) { return $map }

    if ($Category -eq 'skills') {
        foreach ($f in (Get-FilesUnder -Root $dir -SkipUnreadable)) {
            $map["skills/" + ($f.Rel -replace '\\', '/')] = $f.FullName
        }
        return $map
    }

    $filter = if ($Category -eq 'hooks') { '*.sh' } else { '*.md' }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter $filter -File -ErrorAction SilentlyContinue)) {
        if ($Category -eq 'commands') {
            if ($f.Name -in $skipCommandFiles -or $f.Name -like 'archive*') { continue }
        }
        $map["$Category/$($f.Name)"] = $f.FullName
    }
    return $map
}

function Get-DriftReport {
    $stale = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $orphan = New-Object System.Collections.Generic.List[string]

    foreach ($category in $installablePaths) {
        $src = Get-CategoryFiles -Root $projectRoot -Category $category
        $dst = Get-CategoryFiles -Root $claudeDir -Category $category

        foreach ($rel in $src.Keys) {
            if (-not $dst.ContainsKey($rel)) {
                $missing.Add($rel)
                continue
            }
            $a = Get-ContentFingerprint -Path $src[$rel]
            $b = Get-ContentFingerprint -Path $dst[$rel]
            if ($null -eq $a -or $null -eq $b -or $a -ne $b) { $stale.Add($rel) }
        }
        foreach ($rel in $dst.Keys) {
            if (-not $src.ContainsKey($rel)) { $orphan.Add($rel) }
        }
    }

    return [PSCustomObject]@{
        stale   = @($stale | Sort-Object)
        missing = @($missing | Sort-Object)
        orphan  = @($orphan | Sort-Object)
    }
}

# =============================================================================
# DOCTOR - read-only diagnosis. Writes nothing, anywhere.
# =============================================================================
if ($Doctor) {
    if (-not (Test-Path -LiteralPath $claudeDir)) {
        if ($Json) {
            @{ error = @{ code = 'PRECONDITION'; message = "install target does not exist: $claudeDir"; details = @{ claudeDir = $claudeDir } } } | ConvertTo-Json -Depth 5
        }
        [Console]::Error.WriteLine("install.ps1: install target does not exist: $claudeDir")
        exit 5
    }

    $staleness = Get-StalenessReport
    $drift = Get-DriftReport
    $problems = $drift.stale.Count + $drift.missing.Count
    $exitCode = if ($problems -gt 0 -or $staleness.status -eq 'behind') { 10 } else { 0 }

    if ($Json) {
        # stdout carries the data product only; the human report below is
        # suppressed entirely under -Json.
        [PSCustomObject]@{
            data = [PSCustomObject]@{
                staleness = $staleness
                stale     = $drift.stale
                missing   = $drift.missing
                orphan    = $drift.orphan
            }
            meta = [PSCustomObject]@{
                count     = $problems
                schema    = 'claude-mods.install.doctor/v1'
                claudeDir = $claudeDir
            }
        } | ConvertTo-Json -Depth 6
        exit $exitCode
    }

    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "           claude-mods Install Doctor (read-only)               " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Source: $projectRoot" -ForegroundColor DarkGray
    Write-Host "  Target: $claudeDir" -ForegroundColor DarkGray
    Write-Host ""

    switch ($staleness.status) {
        'behind' {
            Write-Host "  Source tree: BEHIND $($staleness.base) on $($staleness.branch)" -ForegroundColor Red
            Write-Host "    Installing from here would revert $($staleness.revertedFiles.Count) file(s)." -ForegroundColor Red
        }
        'ok' {
            Write-Host "  Source tree: up to date ($($staleness.reason))" -ForegroundColor Green
        }
        default {
            Write-Host "  Source tree: unknown ($($staleness.reason))" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    if ($drift.stale.Count -gt 0) {
        Write-Host "  STALE - installed copy differs from this repo ($($drift.stale.Count)):" -ForegroundColor Red
        foreach ($f in $drift.stale) { Write-Host "    $f" -ForegroundColor Red }
        Write-Host ""
    }
    if ($drift.missing.Count -gt 0) {
        Write-Host "  MISSING - in repo, absent from target ($($drift.missing.Count)):" -ForegroundColor Yellow
        foreach ($f in $drift.missing) { Write-Host "    $f" -ForegroundColor Yellow }
        Write-Host ""
    }
    if ($drift.orphan.Count -gt 0) {
        # Informational only. The installer deliberately keeps dest-only files,
        # so an orphan is usually machine-local content, not a fault.
        Write-Host "  ORPHAN - in target, absent from repo ($($drift.orphan.Count), informational):" -ForegroundColor DarkGray
        foreach ($f in $drift.orphan) { Write-Host "    $f" -ForegroundColor DarkGray }
        Write-Host ""
    }

    if ($exitCode -eq 0) {
        Write-Host "  Clean - installed content matches this repo." -ForegroundColor Green
    } else {
        Write-Host "  Run scripts/install.ps1 to sync (rebase on main first if the tree is behind)." -ForegroundColor Yellow
    }
    Write-Host ""
    exit $exitCode
}

# =============================================================================
# STALENESS GUARD - runs before the installer writes anything
#
# Refuses rather than warns. The 2026-08-31 revert was silent for an unknown
# number of days; a warning in a 200-line install log scrolls past unread,
# which is exactly how it went unnoticed. Refusal costs one -Force flag and is
# instantly recoverable; a silent revert costs a hunt. The normal-workflow
# false positive (a branch merely AHEAD of main) is excluded by the ancestor
# test in Get-StalenessReport, so this should essentially never fire wrongly.
# =============================================================================
$staleness = Get-StalenessReport
if ($staleness.status -eq 'behind') {
    Write-Host ""
    Write-Host "  STALE SOURCE TREE - install refused" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Branch '$($staleness.branch)' is missing commits on '$($staleness.base)'" -ForegroundColor Red
    Write-Host "  that touch installable paths. Installing from here would revert" -ForegroundColor Red
    Write-Host "  $($staleness.revertedFiles.Count) file(s) another lane already landed:" -ForegroundColor Red
    Write-Host ""
    foreach ($f in $staleness.revertedFiles) { Write-Host "    $f" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Fix it one of these ways:" -ForegroundColor Yellow
    Write-Host "    git rebase $($staleness.base)      # bring this branch up to date, then re-run" -ForegroundColor Yellow
    Write-Host "    ...or run the installer from the $($staleness.base) checkout instead" -ForegroundColor Yellow
    Write-Host "    ...or re-run with -Force if this tree's content should win" -ForegroundColor Yellow
    Write-Host ""
    if (-not $Force) { exit 10 }
    Write-Host "  -Force given: continuing anyway." -ForegroundColor Yellow
    Write-Host ""
} elseif ($staleness.status -eq 'unknown') {
    Write-Host "  Staleness check skipped: $($staleness.reason)" -ForegroundColor DarkGray
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "           claude-mods Installer (Windows)                      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure ~/.claude directories exist
$dirs = @("commands", "skills", "agents", "rules", "output-styles", "hooks")
foreach ($dir in $dirs) {
    $path = Join-Path $claudeDir $dir
    if (-not (Test-Path -LiteralPath $path)) {
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
    "$claudeDir\skills\push-gate",              # Renamed to push-preflight (2026-10)

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
    if (Test-Path -LiteralPath $oldPath) {
        try {
            Remove-Item -LiteralPath $oldPath -Recurse -Force -ErrorAction Stop
            $newName = $oldSkill -replace '-patterns$', '-ops'
            Write-Host "  Removed renamed: $oldSkill (now $newName)" -ForegroundColor Red
        } catch {
            Write-Host "  WARNING: could not remove $oldPath ($($_.Exception.Message)) - continuing" -ForegroundColor Yellow
        }
    }
}

Write-Host "Cleaning up deprecated items..." -ForegroundColor Yellow
foreach ($item in $deprecated) {
    if (Test-Path -LiteralPath $item) {
        try {
            Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop
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
Get-ChildItem -LiteralPath $commandsDir -Filter "*.md" | ForEach-Object {
    if ($_.Name -notin $skipCommands -and $_.Name -notlike "archive*") {
        Copy-Item -LiteralPath $_.FullName -Destination "$claudeDir\commands\" -Force
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
foreach ($skill in (Get-ChildItem -LiteralPath $skillsDir -Directory)) {
    $src = $skill.FullName
    $dest = "$claudeDir\skills\$($skill.Name)"
    try {
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force -ErrorAction Stop
            Write-Host "  $($skill.Name)/" -ForegroundColor Green
            continue
        }

        # Merge copy: overwrite file-by-file so a locked destination still syncs.
        #
        # -LiteralPath everywhere, deliberately. `-Path` glob-expands, and `[` and
        # `]` are PowerShell wildcard metacharacters - so a Next.js dynamic-route
        # fixture like `app/shop/[slug]/page.tsx` matches nothing, copies nothing,
        # and raises NO error. The file is simply absent from the installed skill.
        # Found 2026-08-31 when nextjs-ops' clean-app fixture arrived two files
        # short and its own test suite still passed, vacuously.
        $srcRel = @{}
        $fileErrors = @()
        foreach ($f in (Get-FilesUnder -Root $src)) {
            $rel = $f.Rel
            $srcRel[$rel] = $true
            try {
                $destFile = Join-Path $dest $rel
                $destFileDir = Split-Path -Parent $destFile
                if (-not (Test-Path -LiteralPath $destFileDir)) {
                    New-Item -ItemType Directory -Path $destFileDir -Force -ErrorAction Stop | Out-Null
                }
                Copy-Item -LiteralPath $f.FullName -Destination $destFile -Force -ErrorAction Stop
            } catch {
                $fileErrors += "$rel ($($_.Exception.Message))"
            }
        }

        # Dest-only files are machine-local (unversioned) or stale. Surface
        # them, never delete them - deleting is the 2026-08-01 data loss.
        # $dest is spelled from $claudeDir as given (CLAUDE_DIR may be an 8.3
        # short path), so its relative paths must come from Get-FilesUnder too.
        $destOnly = @(Get-FilesUnder -Root $dest | Where-Object { -not $srcRel.ContainsKey($_.Rel) })

        if ($fileErrors.Count -gt 0) {
            $failedSkills += $skill.Name
            Write-Host "  $($skill.Name)/ - $($fileErrors.Count) file(s) failed to sync:" -ForegroundColor Red
            foreach ($e in $fileErrors) { Write-Host "    $e" -ForegroundColor Red }
        } elseif ($destOnly.Count -gt 0) {
            Write-Host "  $($skill.Name)/ (kept $($destOnly.Count) dest-only file(s) not in repo)" -ForegroundColor Yellow
            foreach ($f in $destOnly) {
                Write-Host "    $($f.Rel)" -ForegroundColor Yellow
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
Get-ChildItem -LiteralPath $agentsDir -Filter "*.md" | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination "$claudeDir\agents\" -Force
    Write-Host "  $($_.Name)" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# RULES - Copy all rule files
# =============================================================================
Write-Host "Installing rules..." -ForegroundColor Cyan

$rulesDir = Join-Path $projectRoot "rules"
Get-ChildItem -LiteralPath $rulesDir -Filter "*.md" | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination "$claudeDir\rules\" -Force
    Write-Host "  $($_.Name)" -ForegroundColor Green
}
Write-Host ""

# =============================================================================
# OUTPUT STYLES - Copy all output style files
# =============================================================================
Write-Host "Installing output styles..." -ForegroundColor Cyan

$stylesDir = Join-Path $projectRoot "output-styles"
if (Test-Path -LiteralPath $stylesDir) {
    Get-ChildItem -LiteralPath $stylesDir -Filter "*.md" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination "$claudeDir\output-styles\" -Force
        Write-Host "  $($_.Name)" -ForegroundColor Green
    }
}
Write-Host ""

# =============================================================================
# HOOKS - Copy scripts and merge plugin-equivalent wiring into settings.json
# =============================================================================
Write-Host "Installing hooks..." -ForegroundColor Cyan

$hooksDir = Join-Path $projectRoot "hooks"
Get-ChildItem -LiteralPath $hooksDir -Filter "*.sh" | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination "$claudeDir\hooks\" -Force
}

$settingsPath = Join-Path $claudeDir "settings.json"
if (Test-Path -LiteralPath $settingsPath) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}
if (-not $settings.PSObject.Properties["hooks"]) {
    $settings | Add-Member -MemberType NoteProperty -Name hooks -Value ([PSCustomObject]@{})
}

$desired = Get-Content -LiteralPath (Join-Path $hooksDir "hooks.json") -Raw | ConvertFrom-Json
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
        if (Test-Path -LiteralPath $statuslineTemplate) {
            $tpl = Get-Content -LiteralPath $statuslineTemplate -Raw | ConvertFrom-Json
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

$settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
Write-Host "  Security and peer-guard hooks wired in settings.json" -ForegroundColor Green
Write-Host ""

# =============================================================================
# PIGEON - Global install (scripts + hook config hint)
# =============================================================================
Write-Host "Installing pigeon (pmail)..." -ForegroundColor Cyan

# Clean up old agentmail install if present
$oldAgentmailDir = Join-Path $claudeDir "agentmail"
if (Test-Path -LiteralPath $oldAgentmailDir) {
    Remove-Item -LiteralPath $oldAgentmailDir -Recurse -Force
    Write-Host "  Removed old agentmail/ (renamed to pigeon/)" -ForegroundColor Red
}

$pigeonDir = Join-Path $claudeDir "pigeon"
New-Item -ItemType Directory -Force -Path $pigeonDir | Out-Null

$mailDbSrc = Join-Path $projectRoot "skills\pigeon\scripts\mail-db.sh"
$checkMailSrc = Join-Path $projectRoot "hooks\check-mail.sh"

if (Test-Path -LiteralPath $mailDbSrc) {
    Copy-Item -LiteralPath $mailDbSrc -Destination "$pigeonDir\" -Force
    Write-Host "  mail-db.sh" -ForegroundColor Green
}
if (Test-Path -LiteralPath $checkMailSrc) {
    Copy-Item -LiteralPath $checkMailSrc -Destination "$pigeonDir\" -Force
    Write-Host "  check-mail.sh" -ForegroundColor Green
}

$settingsPath = Join-Path $claudeDir "settings.json"

# Migrate stale agentmail hook path -> pigeon
if ((Test-Path -LiteralPath $settingsPath) -and (Select-String -LiteralPath $settingsPath -Pattern "agentmail/check-mail\.sh" -Quiet)) {
    $content = Get-Content -LiteralPath $settingsPath -Raw
    $content = $content -replace 'agentmail/check-mail\.sh', 'pigeon/check-mail.sh'
    Set-Content -LiteralPath $settingsPath -Value $content -NoNewline
    Write-Host "  Migrated agentmail hook -> pigeon in settings.json" -ForegroundColor Green
}

# Check if hook is already configured (pigeon path)
if ((Test-Path -LiteralPath $settingsPath) -and (Select-String -LiteralPath $settingsPath -Pattern "pigeon/check-mail\.sh" -Quiet)) {
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
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination "$autoSkillDir\" -Force
        Write-Host "  $script" -ForegroundColor Green
    }
}

$settingsPath = Join-Path $claudeDir "settings.json"
if ((Test-Path -LiteralPath $settingsPath) -and (Select-String -LiteralPath $settingsPath -Pattern "auto-skill" -Quiet)) {
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
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
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
