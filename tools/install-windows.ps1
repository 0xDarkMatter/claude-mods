#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install modern CLI tools for token-efficient AI coding assistants.

.DESCRIPTION
    Installs Rust-based CLI tools that replace verbose legacy commands.
    These tools produce cleaner output, saving tokens in AI contexts.

.NOTES
    Run as Administrator: Right-click PowerShell > Run as Administrator
#>

$ErrorActionPreference = "Stop"

Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Modern CLI Toolkit Installer (Windows)                 ║" -ForegroundColor Cyan
Write-Host "║       Token-efficient tools for AI coding assistants         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: winget not found. Please install App Installer from Microsoft Store." -ForegroundColor Red
    exit 1
}

# Tool definitions: [PackageId, DisplayName, Binary]
$tools = @(
    # File Search & Navigation
    @("sharkdp.fd", "fd (find replacement)", "fd"),
    @("BurntSushi.ripgrep.MSVC", "ripgrep (grep replacement)", "rg"),
    @("eza-community.eza", "eza (ls replacement)", "eza"),
    @("sharkdp.bat", "bat (cat replacement)", "bat"),
    @("ajeetdsouza.zoxide", "zoxide (cd replacement)", "zoxide"),
    @("Canop.broot", "broot (tree replacement)", "broot"),

    # Data Processing
    @("chmln.sd", "sd (sed replacement)", "sd"),
    @("jqlang.jq", "jq (JSON processor)", "jq"),
    @("MikeFarah.yq", "yq (YAML processor)", "yq"),

    # Git Operations
    @("dandavison.delta", "delta (git diff)", "delta"),
    @("Wilfred.difftastic", "difft (semantic diff)", "difft"),
    @("JesseDuffield.lazygit", "lazygit (git TUI)", "lazygit"),
    @("GitHub.cli", "gh (GitHub CLI)", "gh"),

    # System Monitoring
    @("bootandy.dust", "dust (du replacement)", "dust"),
    @("ClementTsang.bottom", "bottom (top replacement)", "btm"),
    @("dalance.procs", "procs (ps replacement)", "procs"),

    # Code Analysis
    @("XAMPPRocky.Tokei", "tokei (line counter)", "tokei"),
    @("ast-grep.ast-grep", "ast-grep (AST search)", "sg"),
    @("sharkdp.hyperfine", "hyperfine (benchmarking)", "hyperfine"),

    # Interactive Selection
    @("junegunn.fzf", "fzf (fuzzy finder)", "fzf"),

    # Documentation
    @("dbrgn.tealdeer", "tldr (man replacement)", "tldr"),

    # Python
    @("astral-sh.uv", "uv (pip replacement)", "uv"),

    # Task Running
    @("Casey.Just", "just (make replacement)", "just")
)

$installed = 0
$skipped = 0
$failed = 0

foreach ($tool in $tools) {
    $packageId = $tool[0]
    $displayName = $tool[1]
    $binary = $tool[2]

    Write-Host "  Installing $displayName... " -NoNewline

    # Check if already installed
    if (Get-Command $binary -ErrorAction SilentlyContinue) {
        Write-Host "SKIP (already installed)" -ForegroundColor Yellow
        $skipped++
        continue
    }

    try {
        $result = winget install $packageId --accept-package-agreements --accept-source-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "OK" -ForegroundColor Green
            $installed++
        } else {
            Write-Host "FAILED" -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Results: $installed installed, $skipped skipped, $failed failed" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Post-install: Update tldr cache
if (Get-Command tldr -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "Updating tldr cache..." -NoNewline
    tldr --update 2>&1 | Out-Null
    Write-Host " OK" -ForegroundColor Green
}

# Post-install: Initialize zoxide
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "To enable zoxide, add to your PowerShell profile ($PROFILE):"
    Write-Host '  Invoke-Expression (& { (zoxide init powershell | Out-String) })' -ForegroundColor Yellow
}

# Post-install: fzf integration
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "To enable fzf integration, install PSFzf module:"
    Write-Host '  Install-Module PSFzf -Scope CurrentUser' -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Then add to your PowerShell profile:"
    Write-Host '  Import-Module PSFzf' -ForegroundColor Yellow
    Write-Host '  Set-PsFzfOption -PSReadlineChordProvider "Ctrl+t" -PSReadlineChordReverseHistory "Ctrl+r"' -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Verify installation with:" -ForegroundColor Cyan
Write-Host '  which fd rg eza bat zoxide delta difft jq yq sd lazygit gh tokei uv just fzf dust btm procs tldr' -ForegroundColor Yellow
Write-Host ""
