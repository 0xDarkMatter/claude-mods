<#
.SYNOPSIS
    PowerShell port of the Terminal Panel Design System (docs/TERMINAL-DESIGN.md).

.DESCRIPTION
    Mirror of skills/_lib/term.sh for PowerShell scripts in the claude-mods
    family. Provides chrome rendering (panels, sections, leaves), glyph
    registries (brand, health, diagram icon), color tokens, and width-aware
    text utilities so PowerShell-based skills produce output that's visually
    coherent with bash and Python siblings (fleet-ops, summon, etc.).

    Source from any PowerShell skill script:

        $LibDir = Join-Path $PSScriptRoot '..\..\_lib'
        . (Join-Path $LibDir 'term.ps1')
        Initialize-Term

    All component helpers return strings. The caller decides where to write
    them (stderr for chrome via [Console]::Error.WriteLine, stdout for data
    payloads). This keeps the ATP stream-separation contract intact.

    Honors: $env:NO_COLOR, $env:FORCE_COLOR, $env:TERM_ASCII, $env:TERM=dumb.
    Spec: ../docs/TERMINAL-DESIGN.md.

    Encoding: this file is 7-bit ASCII on purpose, and must stay that way.
    Windows PowerShell 5.1 reads a script without a byte-order mark in the
    ANSI code page, so a single raw glyph byte here broke the parse of this
    file and of every script that dot-sources it. Each glyph is spelled as
    its code point (ConvertFrom-TermCodePoint 0x2500), which keeps the
    strings in memory identical. Never type a glyph literal into this file;
    tests/check-ps51-parse.sh fails on one.
#>

# Guard against double-sourcing. Test-Path keeps this safe under
# Set-StrictMode -Version Latest, where reading an unset variable throws (this
# lib is dot-sourced into strict-mode consumer scripts, e.g. phone-home-monitor).
if ((Test-Path Variable:Script:__TermPs1Loaded) -and $Script:__TermPs1Loaded) { return }
$Script:__TermPs1Loaded = $true

# --- Code points (see "Encoding" above) --------------------------------------
function ConvertFrom-TermCodePoint {
    <#
    .SYNOPSIS
        Return the string for one or more Unicode code points, e.g.
        ConvertFrom-TermCodePoint 0x251C 0x2500 is the tree branch connector.
        Code points above U+FFFF (emoji) become surrogate pairs.
    #>
    param([Parameter(Mandatory, ValueFromRemainingArguments)][int[]]$CodePoint)
    -join ($CodePoint | ForEach-Object { [char]::ConvertFromUtf32($_) })
}

# --- Globals (populated by Initialize-Term) ----------------------------------
$Script:TermTty       = $false
$Script:TermColor     = $false
$Script:TermAsciiMode = $false
$Script:TermWidth     = 100   # claude-mods default (TERMINAL-DESIGN open question #1)

# ANSI escape codes (empty when color disabled)
$Script:TC_Green   = ''
$Script:TC_Yellow  = ''
$Script:TC_Orange  = ''
$Script:TC_Red     = ''
$Script:TC_Cyan    = ''
$Script:TC_Magenta = ''
$Script:TC_Dim     = ''
$Script:TC_Off     = ''

# Tree connectors (set by Initialize-Term; Unicode code points / ASCII fallback)
$Script:T_Branch = ''   # U+251C U+2500 tee + rule   / +-
$Script:T_Last   = ''   # U+2514 U+2500 corner + rule / `-
$Script:T_Vert   = ''   # U+2502 vertical            / |

# Panel chrome
$Script:P_TL     = ''   # U+256D rounded top-left    / +
$Script:P_BL     = ''   # U+2570 rounded bottom-left / +
$Script:P_HRule  = ''   # U+2500 horizontal          / -
$Script:P_Term   = ''   # U+25CF black circle        / *

# Header / alert / tip glyphs
$Script:G_Branch = ''   # U+2387 branch symbol / (b)
$Script:G_Alert  = ''   # U+25B2 up triangle   / !
$Script:G_Tip    = ''   # U+1F4A1 light bulb   / (i)

# Spinner frame banks
$Script:Spin_Working   = @()
$Script:Spin_Heartbeat = @()

# --- Registries (Unicode | ASCII fallback) ----------------------------------
$Script:TermBrand = @{
    fleet         = (ConvertFrom-TermCodePoint 0x26A1)  + '|[F]'   # high voltage
    forge         = (ConvertFrom-TermCodePoint 0x1F528) + '|[B]'   # hammer
    psql          = (ConvertFrom-TermCodePoint 0x1F418) + '|[P]'   # elephant
    watch         = (ConvertFrom-TermCodePoint 0x1F4E1) + '|[M]'   # satellite antenna
    deploy        = (ConvertFrom-TermCodePoint 0x1F680) + '|[D]'   # rocket
    git           = (ConvertFrom-TermCodePoint 0x1F33F) + '|[G]'   # herb
    'windows-ops' = (ConvertFrom-TermCodePoint 0x1FA7A) + '|[H]'   # stethoscope - diagnostics is the verb
}

$Script:TermHealthGlyph = @{
    healthy  = (ConvertFrom-TermCodePoint 0x2022) + '|(+)'   # bullet
    pending  = (ConvertFrom-TermCodePoint 0x2022) + '|(.)'
    warning  = (ConvertFrom-TermCodePoint 0x2022) + '|(!)'
    critical = (ConvertFrom-TermCodePoint 0x2022) + '|(!!)'
    busted   = (ConvertFrom-TermCodePoint 0x2B24) + '|(X)'    # black large circle
    unknown  = (ConvertFrom-TermCodePoint 0x2022) + '|(?)'
}

$Script:TermDiagramIcon = @{
    user     = (ConvertFrom-TermCodePoint 0x1F464) + '|(U)'   # bust in silhouette
    web      = (ConvertFrom-TermCodePoint 0x1F310) + '|(W)'   # globe with meridians
    mobile   = (ConvertFrom-TermCodePoint 0x1F4F1) + '|(M)'   # mobile phone
    auth     = (ConvertFrom-TermCodePoint 0x1F510) + '|(A)'   # closed lock with key
    database = (ConvertFrom-TermCodePoint 0x1F5C4) + '|(D)'   # file cabinet
    cache    = (ConvertFrom-TermCodePoint 0x26A1)  + '|(C)'   # high voltage
    queue    = (ConvertFrom-TermCodePoint 0x1F4E8) + '|(Q)'   # incoming envelope
    storage  = (ConvertFrom-TermCodePoint 0x1F4E6) + '|(P)'   # package
    service  = (ConvertFrom-TermCodePoint 0x2699)  + '|*'     # gear
    api      = (ConvertFrom-TermCodePoint 0x1F50C) + '|(I)'   # electric plug
    search   = (ConvertFrom-TermCodePoint 0x1F50D) + '|(S)'   # magnifying glass
    timer    = (ConvertFrom-TermCodePoint 0x23F1)  + '|(T)'   # stopwatch
    build    = (ConvertFrom-TermCodePoint 0x1F528) + '|(B)'   # hammer
    hook     = (ConvertFrom-TermCodePoint 0x1FA9D) + '|(H)'   # hook
    log      = (ConvertFrom-TermCodePoint 0x1F4C4) + '|(F)'   # page facing up
}

# --- Initialize-Term ---------------------------------------------------------
function Initialize-Term {
    <#
    .SYNOPSIS
        Detect terminal capabilities and populate global glyph/color state.
        Idempotent - safe to call multiple times.
    #>
    [CmdletBinding()]
    param()

    # TTY detection - stdout (not stderr; rendering targets stdout-ish)
    try {
        $Script:TermTty = -not [Console]::IsOutputRedirected
    } catch {
        $Script:TermTty = $false
    }

    # ASCII fallback: explicit env, or non-UTF environment
    $asciiEnv = $env:TERM_ASCII -eq '1' -or $env:FLEET_ASCII -eq '1'
    $lang = if ($env:LC_ALL) { $env:LC_ALL } elseif ($env:LANG) { $env:LANG } else { '' }
    $nonUtf = $lang -and ($lang -notmatch '[Uu][Tt][Ff]') -and ($env:TERM -eq 'dumb')
    $Script:TermAsciiMode = $asciiEnv -or $nonUtf

    # Color: TTY + not NO_COLOR, or FORCE_COLOR overrides
    if ($env:FORCE_COLOR) {
        $Script:TermColor = $true
    } elseif ($env:NO_COLOR -or -not $Script:TermTty -or $env:TERM -eq 'dumb') {
        $Script:TermColor = $false
    } else {
        $Script:TermColor = $true
    }

    # Terminal width - fall back to 100 (claude-mods default)
    if ($Script:TermTty) {
        try {
            $cols = [Console]::WindowWidth
            if ($cols -ge 40) { $Script:TermWidth = $cols }
        } catch {
            # WindowWidth throws when no console attached; keep default
        }
    }

    # Allow explicit override
    if ($env:TERM_WIDTH -match '^\d+$' -and [int]$env:TERM_WIDTH -ge 40) {
        $Script:TermWidth = [int]$env:TERM_WIDTH
    }

    # Glyphs by mode
    if ($Script:TermAsciiMode) {
        $Script:T_Branch = '+-'
        $Script:T_Last   = '`-'
        $Script:T_Vert   = '|'
        $Script:P_TL     = '+'
        $Script:P_BL     = '+'
        $Script:P_HRule  = '-'
        $Script:P_Term   = '*'
        $Script:G_Branch = '(b)'
        $Script:G_Alert  = '!'
        $Script:G_Tip    = '(i)'
        $Script:Spin_Working   = @('|', '/', '-', '\')
        $Script:Spin_Heartbeat = @('.', ':', '*', ':')
    } else {
        # Code points, never literals (see "Encoding" in the header)
        $Script:T_Branch = ConvertFrom-TermCodePoint 0x251C 0x2500
        $Script:T_Last   = ConvertFrom-TermCodePoint 0x2514 0x2500
        $Script:T_Vert   = ConvertFrom-TermCodePoint 0x2502
        $Script:P_TL     = ConvertFrom-TermCodePoint 0x256D
        $Script:P_BL     = ConvertFrom-TermCodePoint 0x2570
        $Script:P_HRule  = ConvertFrom-TermCodePoint 0x2500
        $Script:P_Term   = ConvertFrom-TermCodePoint 0x25CF
        $Script:G_Branch = ConvertFrom-TermCodePoint 0x2387
        $Script:G_Alert  = ConvertFrom-TermCodePoint 0x25B2
        $Script:G_Tip    = ConvertFrom-TermCodePoint 0x1F4A1
        # braille dots, one frame per code point
        $Script:Spin_Working   = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F |
                                   ForEach-Object { ConvertFrom-TermCodePoint $_ })
        # middle dot, bullet operator, bullet, black circle, bullet, bullet operator
        $Script:Spin_Heartbeat = @(0x00B7, 0x2219, 0x2022, 0x25CF, 0x2022, 0x2219 |
                                   ForEach-Object { ConvertFrom-TermCodePoint $_ })
    }

    # ANSI escapes
    if ($Script:TermColor) {
        $esc = [char]27
        $Script:TC_Green   = "${esc}[32m"
        $Script:TC_Yellow  = "${esc}[33m"
        $Script:TC_Orange  = "${esc}[38;5;208m"
        $Script:TC_Red     = "${esc}[31m"
        $Script:TC_Cyan    = "${esc}[36m"
        $Script:TC_Magenta = "${esc}[35m"
        $Script:TC_Dim     = "${esc}[2m"
        $Script:TC_Off     = "${esc}[0m"

        # On Windows, ensure VT processing is enabled so ANSI works in PS 5.1
        if ($PSVersionTable.PSVersion.Major -le 5) {
            try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
        }
    } else {
        $Script:TC_Green = ''; $Script:TC_Yellow = ''; $Script:TC_Orange = ''
        $Script:TC_Red = ''; $Script:TC_Cyan = ''; $Script:TC_Magenta = ''
        $Script:TC_Dim = ''; $Script:TC_Off = ''
    }
}

# --- Color helper ------------------------------------------------------------
function Get-TermColor {
    <#
    .SYNOPSIS
        Wrap text in an ANSI color escape. Returns plain text when color disabled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('green','yellow','orange','red','cyan','magenta','dim')]
        [string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    if (-not $Script:TermColor) { return $Text }
    $code = switch ($Token) {
        'green'   { $Script:TC_Green }
        'yellow'  { $Script:TC_Yellow }
        'orange'  { $Script:TC_Orange }
        'red'     { $Script:TC_Red }
        'cyan'    { $Script:TC_Cyan }
        'magenta' { $Script:TC_Magenta }
        'dim'     { $Script:TC_Dim }
    }
    return "${code}${Text}$($Script:TC_Off)"
}

# --- Registry lookup ---------------------------------------------------------
function Get-TermGlyph {
    <#
    .SYNOPSIS
        Return registered Unicode glyph (or ASCII fallback when in ASCII mode).
    .PARAMETER Registry
        Which registry to consult: Brand | Health | Diagram
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Brand','Health','Diagram')]$Registry,
        [Parameter(Mandatory)][string]$Key
    )
    $map = switch ($Registry) {
        'Brand'   { $Script:TermBrand }
        'Health'  { $Script:TermHealthGlyph }
        'Diagram' { $Script:TermDiagramIcon }
    }
    $entry = $map[$Key]
    if (-not $entry) { return '?' }
    $parts = $entry -split '\|', 2
    if ($Script:TermAsciiMode) { return $parts[1] } else { return $parts[0] }
}

# --- Display-width helpers ---------------------------------------------------
function Get-TermDisplayWidth {
    <#
    .SYNOPSIS
        Approximate display column count for a string, accounting for emoji
        double-width and ignoring ANSI color escapes.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Text = '')
    process {
        if (-not $Text) { return 0 }
        # Strip ANSI escapes (CSI sequences)
        $esc = [char]27
        $clean = $Text -replace "${esc}\[[0-9;]*m", ''
        $width = 0
        # EnumerateRunes handles surrogate pairs correctly
        foreach ($rune in [System.Globalization.StringInfo]::GetTextElementEnumerator($clean)) {
            $cp = if ([string]$rune.Current.Length -gt 0) { [int][char]([string]$rune.Current)[0] } else { 0 }
            # Simple wide-emoji heuristic: rune length >1 (surrogate pair) OR in known wide ranges
            $s = [string]$rune.Current
            if ($s.Length -gt 1) {
                $width += 2   # surrogate pair - almost always wide
            } elseif (($cp -ge 0x2600 -and $cp -le 0x27BF) -or
                      ($cp -ge 0x2B00 -and $cp -le 0x2BFF) -or
                      $cp -eq 0x26A1 -or         # high voltage
                      $cp -eq 0x2728 -or         # sparkles
                      $cp -eq 0x2B24) {          # black large circle
                $width += 2
            } else {
                $width += 1
            }
        }
        return $width
    }
}

function Get-TermTruncated {
    <#
    .SYNOPSIS
        Ellipsis-truncate text to fit in MaxCols display columns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory, Position=1)][int]$MaxCols
    )
    $w = Get-TermDisplayWidth $Text
    if ($w -le $MaxCols) { return $Text }
    $ell = if ($Script:TermAsciiMode) { '..' } else { ConvertFrom-TermCodePoint 0x2026 }   # ellipsis
    $ellW = Get-TermDisplayWidth $ell
    # Naive truncation by character count - close enough for our needs
    $maxChars = $MaxCols - $ellW
    if ($maxChars -lt 0) { $maxChars = 0 }
    if ($Text.Length -le $maxChars) { return $Text + $ell }
    return $Text.Substring(0, $maxChars) + $ell
}

# --- Panel chrome ------------------------------------------------------------
function New-TermPanelOpen {
    <#
    .SYNOPSIS
        Render the panel header bar. In ASCII mode:
            +-- [H] name . subtitle --- INDICATOR ---*
        The dot before the subtitle is U+00B7 in both modes. The Unicode
        rendering is drawn in docs/TERMINAL-DESIGN.md.
    .PARAMETER Brand
        Brand key from the registry (e.g. 'windows-ops').
    .PARAMETER Name
        Tool name shown after the brand emoji (e.g. 'windows-ops').
    .PARAMETER Subtitle
        Optional subtitle after the name (e.g. 'health-audit').
    .PARAMETER Indicator
        Optional right-side context indicator (e.g. 'WORKSTATION', 'Y / Disk 1').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Brand,
        [Parameter(Mandatory)][string]$Name,
        [string]$Subtitle = '',
        [string]$Indicator = ''
    )
    $emoji = Get-TermGlyph -Registry Brand -Key $Brand
    $dot = ConvertFrom-TermCodePoint 0x00B7   # middle dot
    $title = if ($Subtitle) {
        "$Name $(Get-TermColor dim "$dot $Subtitle")"
    } else {
        $Name
    }
    $titleVis = if ($Subtitle) { "$Name $dot $Subtitle" } else { $Name }

    $leftRaw = "$($Script:P_TL)$($Script:P_HRule)$($Script:P_HRule) $emoji "
    $left = "$leftRaw$(Get-TermColor cyan $title) "
    $leftVis = "$leftRaw${titleVis} "

    if ($Indicator) {
        $right = " $(Get-TermColor dim $Indicator) $($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$(Get-TermColor cyan $Script:P_Term)"
        $rightVis = " $Indicator $($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$($Script:P_Term)"
    } else {
        $right = "$($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$(Get-TermColor cyan $Script:P_Term)"
        $rightVis = "$($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$($Script:P_Term)"
    }

    $leftW  = Get-TermDisplayWidth $leftVis
    $rightW = Get-TermDisplayWidth $rightVis
    $fill = $Script:TermWidth - $leftW - $rightW
    if ($fill -lt 4) { $fill = 4 }
    $rule = Get-TermColor cyan ($Script:P_HRule * $fill)
    return "${left}${rule}${right}"
}

function New-TermPanelClose {
    <#
    .SYNOPSIS
        Render the panel footer bar (ASCII mode): +-- hotkeys --- health1  health2 ---*
    .PARAMETER Hotkeys
        Pre-rendered hotkey string (use New-TermHotkey + joining with ' | ').
    .PARAMETER Healths
        Pre-rendered health-indicator string (use New-TermHealth + joining with '  ').
    #>
    [CmdletBinding()]
    param(
        [string]$Hotkeys = '',
        [string]$Healths = ''
    )
    $leftRaw = "$($Script:P_BL)$($Script:P_HRule)$($Script:P_HRule) "
    $left = "$leftRaw$Hotkeys "
    # For width calc strip ANSI from the rendered hotkeys/healths
    $hotkeysVis = ($Hotkeys -replace "$([char]27)\[[0-9;]*m", '')
    $leftVis = "$leftRaw$hotkeysVis "

    if ($Healths) {
        $right = " $Healths $($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$(Get-TermColor cyan $Script:P_Term)"
        $healthsVis = ($Healths -replace "$([char]27)\[[0-9;]*m", '')
        $rightVis = " $healthsVis $($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$($Script:P_Term)"
    } else {
        $right = "$($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$(Get-TermColor cyan $Script:P_Term)"
        $rightVis = "$($Script:P_HRule)$($Script:P_HRule)$($Script:P_HRule)$($Script:P_Term)"
    }

    $leftW  = Get-TermDisplayWidth $leftVis
    $rightW = Get-TermDisplayWidth $rightVis
    $fill = $Script:TermWidth - $leftW - $rightW
    if ($fill -lt 4) { $fill = 4 }
    $rule = Get-TermColor cyan ($Script:P_HRule * $fill)
    return "${left}${rule}${right}"
}

function New-TermPanelVert {
    <# Body-line spacer: a single | on its own line. #>
    [CmdletBinding()]
    param()
    return Get-TermColor dim $Script:T_Vert
}

# --- Body components ---------------------------------------------------------
function New-TermSection {
    <#
    .SYNOPSIS
        Section header: +-- LABEL (n)  with label colored by state.
    .PARAMETER State
        State token (FAILING/WARN/PASS/INFO or fleet-style RUNNING/READY/FAILED/CONFLICT).
    .PARAMETER Label
        Section label text.
    .PARAMETER Count
        Item count. Pass -1 to omit the (n).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Label,
        [int]$Count = -1
    )
    $color = switch -Regex ($State) {
        '^(RUNNING|PENDING|WARN|warning|WATCHLIST)$' { 'yellow' }
        '^(READY|PASS|LANDED|DONE|OK|healthy)$'      { 'green' }
        '^(FAILING|FAILED|ERROR|CRITICAL|critical|alarm|busted)$' { 'red' }
        '^(CONFLICT)$' { 'magenta' }
        default { '' }
    }
    $renderedLabel = if ($color) { Get-TermColor $color $Label } else { $Label }
    # Section is a panel-edge attachment - '+--' IS the left edge, no leading '|' prefix.
    $conn = Get-TermColor dim "$($Script:T_Branch)$($Script:P_HRule)"
    $countStr = if ($Count -ge 0) { ' ' + (Get-TermColor dim "($Count)") } else { '' }
    return "${conn} ${renderedLabel}${countStr}"
}

function New-TermSummary {
    <#
    .SYNOPSIS
        Summary line: +-- text  (all dim, metadata-only branch).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    # Summary attaches at the panel edge like a section.
    $conn = Get-TermColor dim "$($Script:T_Branch)$($Script:P_HRule)"
    $body = Get-TermColor dim $Text
    return "${conn} ${body}"
}

function New-TermLeaf {
    <#
    .SYNOPSIS
        Single leaf row (ASCII mode): |   +-- name              *-*-@    meta    age
    .PARAMETER Name
        Leaf name (ellipsis-truncated to fit name column).
    .PARAMETER Rail
        Pre-rendered leaf-glyph string (rail or pip bar or plain text).
    .PARAMETER Meta
        Meta column content (e.g. 'M4 ?1', 'clean', error count).
    .PARAMETER Age
        Age column content (right-aligned, e.g. '12m', '2h').
    .PARAMETER IsLast
        Use `-- connector instead of +-- (for last sibling in a section).
    .PARAMETER NameColWidth
        Override name column width (default 32).
    .PARAMETER RailColWidth
        Override rail column width (default 14).
    .PARAMETER MetaColWidth
        Override meta column width (default 12).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Rail = '',
        [string]$Meta = '',
        [string]$Age  = '',
        [switch]$IsLast,
        [int]$NameColWidth = 32,
        [int]$RailColWidth = 14,
        [int]$MetaColWidth = 12
    )
    $vert = Get-TermColor dim $Script:T_Vert
    $connRaw = if ($IsLast) { $Script:T_Last } else { $Script:T_Branch }
    $conn = Get-TermColor dim "$connRaw$($Script:P_HRule)"

    $truncName = Get-TermTruncated -Text $Name -MaxCols $NameColWidth
    $nameW = Get-TermDisplayWidth $truncName
    $namePad = ' ' * [Math]::Max(0, $NameColWidth - $nameW)

    $railW = Get-TermDisplayWidth ($Rail -replace "$([char]27)\[[0-9;]*m", '')
    $railPad = ' ' * [Math]::Max(0, $RailColWidth - $railW)

    $metaColored = if ($Meta) { Get-TermColor dim $Meta } else { '' }
    $metaW = Get-TermDisplayWidth $Meta
    $metaPad = ' ' * [Math]::Max(0, $MetaColWidth - $metaW)

    $ageColored = if ($Age) { Get-TermColor dim $Age } else { '' }

    return "${vert}   ${conn} ${truncName}${namePad}  ${Rail}${railPad}  ${metaColored}${metaPad}  ${ageColored}"
}

function New-TermAlert {
    <#
    .SYNOPSIS
        Inline alert sub-row (ASCII mode): |   |   ! message  (orange/red).
    .PARAMETER Severity
        warning (orange) or critical (red).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('warning','critical')]$Severity,
        [Parameter(Mandatory)][string]$Text
    )
    $color = if ($Severity -eq 'critical') { 'red' } else { 'orange' }
    $vert  = Get-TermColor dim $Script:T_Vert
    $vert2 = Get-TermColor dim $Script:T_Vert
    $tri = Get-TermColor $color $Script:G_Alert
    # Per design section 4.7: panel-vert, 3-space section indent, leaf-continuation vert,
    # 3-space sub-indent (aligns the alert under the leaf's tree connector).
    return "${vert}   ${vert2}   ${tri} ${Text}"
}

function New-TermHint {
    <#
    .SYNOPSIS
        Hint row with the tip glyph (ASCII mode): |   (i) text  (dim, no tree connector).
        Used for "to get started" / "did you know" rows in empty states.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $vert = Get-TermColor dim $Script:T_Vert
    $tip = $Script:G_Tip
    return "${vert}   ${tip} $(Get-TermColor dim $Text)"
}

function New-TermToast {
    <#
    .SYNOPSIS
        Toast row (ASCII mode): +-- [H] message  (dim cyan emoji + default fg text).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Brand,
        [Parameter(Mandatory)][string]$Text
    )
    $emoji = Get-TermGlyph -Registry Brand -Key $Brand
    $vert = Get-TermColor dim $Script:T_Vert
    $conn = Get-TermColor dim "$($Script:T_Branch)$($Script:P_HRule)"
    $msg = "$(Get-TermColor cyan $emoji) $Text"
    return "${vert}${conn} ${msg}"
}

# --- Leaf-glyph builders -----------------------------------------------------
function New-TermRail {
    <#
    .SYNOPSIS
        Build a commit-graph rail (ASCII mode): *-*-*-@ (HEAD) or *-*-X (CONFLICT).
    .PARAMETER Commits
        Number of landed commits (including the HEAD position).
    .PARAMETER Head
        HEAD | CONFLICT | EMPTY
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0,99)][int]$Commits,
        [ValidateSet('HEAD','CONFLICT','EMPTY')][string]$Head = 'HEAD'
    )
    $commit   = if ($Script:TermAsciiMode) { '*' } else { ConvertFrom-TermCodePoint 0x25CF }   # black circle
    $link     = if ($Script:TermAsciiMode) { '-' } else { ConvertFrom-TermCodePoint 0x2500 }   # box horizontal
    $headg    = if ($Script:TermAsciiMode) { '@' } else { ConvertFrom-TermCodePoint 0x25C9 }   # fisheye
    $conflict = if ($Script:TermAsciiMode) { 'X' } else { ConvertFrom-TermCodePoint 0x2297 }   # circled times

    if ($Commits -le 0 -and $Head -eq 'EMPTY') {
        return $link
    }

    $out = ''
    for ($i = 0; $i -lt ($Commits - 1); $i++) {
        $out += "$(Get-TermColor green $commit)$link"
    }
    switch ($Head) {
        'HEAD' {
            if ($Commits -ge 1) { $out += "$(Get-TermColor green $commit)$link" }
            $out += Get-TermColor yellow $headg
        }
        'CONFLICT' {
            if ($Commits -ge 1) { $out += "$(Get-TermColor green $commit)$link" }
            $out += Get-TermColor red $conflict
        }
        'EMPTY' {
            if ($Commits -ge 1) { $out += Get-TermColor green $commit }
        }
    }
    return $out
}

function New-TermPipBar {
    <#
    .SYNOPSIS
        Build a pip bar (ASCII mode): ####------  with state-color based on metric type.
    .PARAMETER Type
        progress | score | capacity (drives color selection per design section 4.10).
    .PARAMETER Filled
        Filled count.
    .PARAMETER Total
        Total / denominator.
    .PARAMETER Width
        Pip count (default 10 = clean 10% increments).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('progress','score','capacity')]$Type,
        [Parameter(Mandatory)][int]$Filled,
        [Parameter(Mandatory)][int]$Total,
        [int]$Width = 10
    )
    $pipFull  = if ($Script:TermAsciiMode) { '#' } else { ConvertFrom-TermCodePoint 0x25B0 }   # black parallelogram
    $pipEmpty = if ($Script:TermAsciiMode) { '-' } else { ConvertFrom-TermCodePoint 0x25B1 }   # white parallelogram

    # Natural denominator override: if total <= 12 and not 100, use total as width
    if ($Total -ne 100 -and $Total -gt 0 -and $Total -le 12) {
        $Width = $Total
    }

    $pct = if ($Total -gt 0) { [int](100 * $Filled / $Total) } else { 0 }
    $pips = if ($Total -eq 100) { [int]($Filled / 10) } else { $Filled }
    if ($pips -lt 0)      { $pips = 0 }
    if ($pips -gt $Width) { $pips = $Width }

    $color = switch ($Type) {
        'progress' {
            if ($pct -ge 100) { 'green' } else { 'yellow' }
        }
        'score' {
            if ($pct -lt 33)      { 'red' }
            elseif ($pct -lt 66)  { 'yellow' }
            else                  { 'green' }
        }
        'capacity' {
            if ($pct -ge 80)      { 'red' }
            elseif ($pct -ge 60)  { 'yellow' }
            else                  { 'green' }
        }
    }

    $out = ''
    for ($i = 0; $i -lt $pips;  $i++) { $out += Get-TermColor $color $pipFull }
    for ($i = $pips; $i -lt $Width; $i++) { $out += Get-TermColor dim $pipEmpty }
    return $out
}

# --- Right-side furniture ----------------------------------------------------
function New-TermHealth {
    <#
    .SYNOPSIS
        Health indicator (ASCII mode): (+) text  (busted uses the large circle, (X)).
    .PARAMETER State
        healthy | pending | warning | critical | busted | unknown
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('healthy','pending','warning','critical','busted','unknown')]$State,
        [Parameter(Mandatory)][string]$Text
    )
    $glyph = Get-TermGlyph -Registry Health -Key $State
    $color = switch ($State) {
        'healthy'  { 'green' }
        'pending'  { 'yellow' }
        'warning'  { 'orange' }
        'critical' { 'red' }
        'busted'   { 'dim' }
        default    { 'dim' }
    }
    return "$(Get-TermColor $color $glyph) $Text"
}

function New-TermHotkey {
    <#
    .SYNOPSIS
        Hotkey hint: "R refresh" with R in cyan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Verb
    )
    return "$(Get-TermColor cyan $Key) $Verb"
}

function Join-TermHotkeys {
    <# Combine hotkeys with the dot separator. Accumulates from pipeline OR -InputObject array. #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline, Position=0)][string]$InputObject)
    begin { $items = New-Object System.Collections.Generic.List[string] }
    process { if ($InputObject) { $items.Add($InputObject) } }
    end { return ($items -join " $(ConvertFrom-TermCodePoint 0x00B7) ") }   # middle dot
}

function Join-TermHealths {
    <# Combine health indicators with two-space separator (per design section 4.3). #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline, Position=0)][string]$InputObject)
    begin { $items = New-Object System.Collections.Generic.List[string] }
    process { if ($InputObject) { $items.Add($InputObject) } }
    end { return ($items -join '  ') }
}

# --- Spinners ----------------------------------------------------------------
function Get-TermSpinnerFrame {
    <#
    .SYNOPSIS
        Return the spinner glyph for the given tick (frame index).
    .PARAMETER Family
        working (fast, task-progress) or heartbeat (slow, daemon-alive).
    .PARAMETER Tick
        Frame index; modded by family frame count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('working','heartbeat')]$Family,
        [Parameter(Mandatory)][int]$Tick
    )
    $frames = switch ($Family) {
        'working'   { $Script:Spin_Working }
        'heartbeat' { $Script:Spin_Heartbeat }
    }
    if (-not $frames) { return '?' }
    return $frames[$Tick % $frames.Count]
}

# --- Convenience: Write a panel-block to stderr ------------------------------
function Write-TermLine {
    <#
    .SYNOPSIS
        Write a pre-rendered chrome line to stderr. Use for panel rows so
        stdout remains data-only (ATP stream separation).
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Line)
    process { [Console]::Error.WriteLine($Line) }
}

function Write-TermData {
    <#
    .SYNOPSIS
        Write payload data to stdout (the data product of the script).
        Use for JSON, machine-readable records, anything downstream tooling
        will consume.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Line)
    process { [Console]::Out.WriteLine($Line) }
}
