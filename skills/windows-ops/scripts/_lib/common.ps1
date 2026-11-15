# windows-ops common helpers
# Dot-source from any script: . "$PSScriptRoot\_lib\common.ps1"

# Semantic exit codes (matches ATP section 7.8)
$script:EXIT_OK           = 0
$script:EXIT_ERROR        = 1
$script:EXIT_USAGE        = 2
$script:EXIT_NOT_FOUND    = 3
$script:EXIT_VALIDATION   = 4
$script:EXIT_PRECONDITION = 5
$script:EXIT_TIMEOUT      = 6
$script:EXIT_UNAVAILABLE  = 7

# Shared terminal design system (skills/_lib/term.ps1) - colorized, ASCII-aware
# framing on stderr (data stays plain on stdout via Write-Data). term.ps1 honors
# NO_COLOR / FORCE_COLOR / TERM_ASCII. Degrade to plain text if the lib is gone.
$script:__WinTermLib = Join-Path $PSScriptRoot '..\..\..\_lib\term.ps1'
if (Test-Path $script:__WinTermLib) {
    . $script:__WinTermLib
    Initialize-Term
    $script:__WinHaveTerm = $true
} else {
    $script:__WinHaveTerm = $false
    function Get-TermColor { param($Token, $Text) return $Text }
}

function Write-Log {
    # All logs to stderr - never pollute stdout. Colorized via term.ps1 (the [TAG]
    # text stays literal/greppable; color is amplification, never the only signal).
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','PASS','FAIL','DEBUG')]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $token = switch ($Level) {
        'PASS'  { 'green' }
        'FAIL'  { 'red' }
        'ERROR' { 'red' }
        'WARN'  { 'orange' }
        'INFO'  { 'cyan' }
        'DEBUG' { 'dim' }
    }
    [Console]::Error.WriteLine((Get-TermColor $token "[$Level]") + " $Message")
}

function Write-Section {
    # Cyan section header (no long === rules - design principle #4: whitespace,
    # not rules, separates sections). ASCII-aware via term.ps1.
    param([Parameter(Mandatory)][string]$Title)
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine((Get-TermColor cyan "== $Title =="))
}

function Write-Data {
    # Plain data row to stdout - only thing that should go there
    param([Parameter(Mandatory, ValueFromPipeline)][object]$Object)
    process { $Object | Out-String -Stream | Where-Object { $_ -ne '' } | ForEach-Object { [Console]::Out.WriteLine($_) } }
}

# === STARTUPAPPROVED ===
# Explorer skips a Run-key or Startup-folder entry at logon when the StartupApproved value
# of the same name says "disabled". The overlay lives in the SAME hive as the entry:
# machine entries (HKLM Run, HKLM WOW6432Node Run, the all-users Startup folder) are
# governed by HKLM\...\Explorer\StartupApproved, user entries by HKCU. Task Manager routes
# its writes that way, and Explorer was measured skipping HKLM-flagged machine entries at
# logon. No source or test shows an HKCU value disabling a machine entry, so never route a
# machine entry to HKCU to dodge the admin requirement. Evidence and the logon test:
# references/startup-mechanisms.md, "The StartupApproved mechanism".

function Get-StartupApprovedSources {
    # The startup sources the overlay governs, one row per source. Scope is whose entries
    # they are ('User' or 'Machine') and picks the overlay hive; Variant is the
    # StartupApproved subkey Explorer checks for that source (WOW6432Node Run -> Run32).
    # Folder paths are built by concatenation, not Join-Path, so the rows still load
    # where APPDATA/ALLUSERSPROFILE are unset (the suite runs this on Linux pwsh).
    $sm = 'Microsoft\Windows\Start Menu\Programs'
    @(
        [pscustomobject]@{ Kind = 'Run';    Scope = 'User';    Variant = 'Run';           Label = 'HKCU Run';                 Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
        [pscustomobject]@{ Kind = 'Run';    Scope = 'Machine'; Variant = 'Run';           Label = 'HKLM Run';                 Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
        [pscustomobject]@{ Kind = 'Run';    Scope = 'Machine'; Variant = 'Run32';         Label = 'HKLM WOW64 Run';           Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
        [pscustomobject]@{ Kind = 'Folder'; Scope = 'User';    Variant = 'StartupFolder'; Label = 'user Startup folder';      Path = "$env:APPDATA\$sm\Startup" }
        [pscustomobject]@{ Kind = 'Folder'; Scope = 'Machine'; Variant = 'StartupFolder'; Label = 'all-users Startup folder'; Path = "$env:ALLUSERSPROFILE\$sm\StartUp" }
    )
}

function Get-StartupApprovedOverlayPath {
    # The StartupApproved key Explorer checks for a source row from
    # Get-StartupApprovedSources: HKLM for Scope 'Machine' (admin to write), HKCU for 'User'.
    param([Parameter(Mandatory)]$Source)
    $hive = switch ($Source.Scope) {
        'User'    { 'HKCU' }
        'Machine' { 'HKLM' }
        default   { throw "Unknown startup source scope '$($Source.Scope)'" }
    }
    "${hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$($Source.Variant)"
}

function Get-StartupApprovedKey {
    # Ensure the overlay key for a source row exists; return its registry path.
    # Throws (access denied) for a Machine row in a non-elevated shell.
    param([Parameter(Mandatory)]$Source)
    $key = Get-StartupApprovedOverlayPath -Source $Source
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    }
    return $key
}

function ConvertFrom-StartupApprovedStatus {
    # Decode a StartupApproved value (the raw registry data, or $null when absent).
    # The low bit of the first byte decides: set = disabled, clear = enabled. Task Manager
    # writes 0x02 / 0x03 today. 0x01 (disabled, carrying a FILETIME) and 0x04 / 0x06
    # (enabled) also appear in the wild: Explorer skipped 0x01 entries and started 0x02 and
    # 0x04 ones at logon (measured with Shell-Core events 9707, Windows 11 22H2); 0x06 as
    # enabled is from H. Carvey, windowsir.blogspot.com, 2022-07-09. Other values follow
    # the same bit rule unobserved (Lansweeper's startup report maps 1/3/5/9 to disabled).
    # Returns 'unmanaged' (no value: the entry runs, the default), 'enabled', 'disabled',
    # or 'unknown(...)' for data that is not a status byte.
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'unmanaged' }
    if ($Value -isnot [byte[]] -or $Value.Length -lt 1) { return "unknown($($Value.GetType().Name))" }
    $b = $Value[0]
    if ($b -eq 0) { return 'unknown(0x00)' }
    if ($b -band 1) { return 'disabled' }
    return 'enabled'
}

function ConvertTo-Bytes12 {
    # Build a 12-byte StartupApproved value: [status][3-byte pad][8-byte FILETIME].
    # Matches what Task Manager writes: a disable (odd status) carries the FILETIME of the
    # disable, an enable (even status) is the status byte and eleven zero bytes. An enable
    # carrying a timestamp reads as disabled to tools that key on the zero tail
    # (Velociraptor's Windows.Sys.StartupItems artifact).
    param(
        [Parameter(Mandatory)][ValidateRange(0,255)][byte]$StatusByte
    )
    if ($StatusByte -band 1) {
        $tail = [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())
    } else {
        $tail = [byte[]]::new(8)
    }
    [byte[]](@($StatusByte, 0, 0, 0) + $tail)
}

function Test-IsElevated {
    # Returns true if running as Administrator
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DiskMap {
    # Map physical disk number -> friendly name / type / drive letters
    # Returns array of [PSCustomObject] with Number, Model, BusType, MediaType, FirmwareVersion, SizeGB, DriveLetters
    Get-Disk | ForEach-Object {
        $disk = $_
        $letters = (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter) -join ','
        $physical = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.Number } | Select-Object -First 1
        [PSCustomObject]@{
            Number           = $disk.Number
            Model            = $disk.FriendlyName
            BusType          = $disk.BusType
            MediaType        = if ($physical) { $physical.MediaType } else { 'Unknown' }
            FirmwareVersion  = $disk.FirmwareVersion
            SizeGB           = [math]::Round($disk.Size / 1GB, 0)
            DriveLetters     = $letters
            HealthStatus     = $disk.HealthStatus
            SerialNumber     = if ($physical) { $physical.SerialNumber } else { $null }
        }
    }
}

function Resolve-HarddiskRef {
    # Resolve a "\Device\HarddiskN" reference to a disk map row
    param([Parameter(Mandatory)][string]$Reference)
    if ($Reference -match 'Harddisk(\d+)' -or $Reference -match '^Disk\s*(\d+)' -or $Reference -match '^(\d+)$') {
        $num = [int]$matches[1]
        return Get-DiskMap | Where-Object { $_.Number -eq $num } | Select-Object -First 1
    }
    return $null
}

function Format-EventMessage {
    # Truncate + collapse whitespace for table display
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Message,
        [int]$MaxLength = 120
    )
    process {
        $cleaned = $Message -replace '\s+', ' '
        if ($cleaned.Length -le $MaxLength) { return $cleaned }
        return $cleaned.Substring(0, $MaxLength - 3) + '...'
    }
}

# Export common state for caller scripts
$script:CommonLoaded = $true
