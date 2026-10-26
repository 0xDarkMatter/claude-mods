<#
.SYNOPSIS
    Read-only check of this Windows machine (and its default WSL distribution) against a
    CA distrust event: does any client or CA bundle here still trust a chain built on the
    incident's listed keys?

.DESCRIPTION
    Output: one line per check, `STATUS id detail[ - fix: step]` with STATUS PASS, FAIL or
    UNKNOWN, then `RESULT  ca-trust-ops 1 <incident> windows <date>: <verdict> (<n> pass,
    <n> fail, <n> unknown)`. -List prints `<id>  <as_of>  <title>` per incident pack.
    Stderr carries usage and incident-pack errors only.

    Contract (the reasons, and the landmines, are in ..\AGENTS.md):
      - Read-only: writes no file, needs no admin rights. Every environment variable and the
        .NET TLS setting it changes is restored on exit, because people run it inside their
        own session. Change environment variables only through Set-ProcessEnv.
      - Network: only the pack's control and path hosts, direct (no proxy, no redirect),
        curl -q, git with no credential helper, extra header or cookie file, a fixed
        User-Agent.
      - A client's refusal is PASS only when the same client opened the control page, this
        script's own handshake saw a listed key in the chain on a current leaf that names
        the host, and the client's error was a certificate error. Anything else is UNKNOWN.
      - Runs under Windows PowerShell 5.1 and pwsh 7, so this file stays ASCII, and inline
        Python, Node and PHP snippets use single quotes (5.1 mangles double quotes in
        arguments to native programs).

.PARAMETER Incident
    The incident pack to check against: ..\assets\incidents\<Incident>.conf (see -List).

.PARAMETER Bundle
    Check only these CA bundle files, offline. Comma-separated or repeated.

.PARAMETER Scan
    Also look for Python certifi bundles under these folders.

.PARAMETER Offline
    Skip the network tests (the result is then UNKNOWN at best).

.PARAMETER SkipWsl
    Do not look inside WSL.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File check-ca-trust.ps1 -List

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File check-ca-trust.ps1 -Incident emudhra-2026-10

.EXAMPLE
    pwsh -NoProfile -File check-ca-trust.ps1 -Incident emudhra-2026-10 -Bundle .\image-ca.crt

.NOTES
    Exit codes: 0 every line PASS, 10 any FAIL, 11 no FAIL but an UNKNOWN, 2 usage error,
    3 no such incident pack, 4 malformed incident pack.
    Sections: SETUP, OUTPUT, INCIDENT PACK, BUNDLES, PROBES, PATH CONFIRMATION, CHECKS, MAIN.
    One file on purpose: every process, network call and environment change it can make is
    reviewable in one place against the contract above, and nothing dot-sources by path.
#>
param(
    [string]$Incident,
    [string[]]$Bundle,
    [string[]]$Scan,
    [switch]$Offline,
    [switch]$SkipWsl,
    [switch]$List,
    [switch]$Help
)

# === SETUP ===

Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Tool = 'ca-trust-ops 1'
# One fixed User-Agent for every probe: disclosure sites count connections per
# User-Agent. $PyProbe and $NodeProbe repeat it.
$Agent = 'ca-trust-ops/1'
$PackDir = [IO.Path]::Combine($PSScriptRoot, '..', 'assets', 'incidents')

# urllib with no proxy and no redirect. 'rejected' only for a verification error whose
# OpenSSL verify code means untrusted issuer or revoked; an expired or wrong-name leaf is
# a different code and must not read as a refusal.
$PyProbe = @'
import ssl, sys, urllib.request, urllib.error
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
bad = getattr(ssl, 'SSLCertVerificationError', ssl.SSLError)
trust = (2, 19, 20, 21, 23, 27, 28)
req = urllib.request.Request(sys.argv[1], headers={'User-Agent': 'ca-trust-ops/1'})
try:
    urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(req, timeout=20).close()
    print('connected')
except urllib.error.HTTPError:
    print('connected')
except Exception as e:
    x = e if isinstance(e, bad) else getattr(e, 'reason', None)
    print('rejected' if isinstance(x, bad) and getattr(x, 'verify_code', None) in trust else 'neterr')
'@

$NodeProbe = @'
const trust = /^(UNABLE_TO_GET_ISSUER_CERT|UNABLE_TO_GET_ISSUER_CERT_LOCALLY|SELF_SIGNED_CERT_IN_CHAIN|UNABLE_TO_VERIFY_LEAF_SIGNATURE|CERT_UNTRUSTED|CERT_REJECTED|CERT_REVOKED)$/;
const req = require('https').get(process.argv[1], {headers: {'user-agent': 'ca-trust-ops/1'}, timeout: 20000}, (res) => { console.log('connected'); res.destroy(); process.exit(0); });
req.on('timeout', () => { console.log('neterr'); process.exit(0); });
req.on('error', (e) => { console.log(trust.test(String(e.code || '')) ? 'rejected' : 'neterr'); process.exit(0); });
'@

$script:Counts = @{ PASS = 0; FAIL = 0; UNKNOWN = 0 }
$script:Seen = @{}
$script:Platform = 'bundles'
$script:ExitCode = 0
$script:PathsConfirmed = $false
$script:PackFile = ''
$OnWindows = ($env:OS -eq 'Windows_NT')

# === OUTPUT ===

function Show-Usage {
    @"
Usage: check-ca-trust.ps1 -Incident NAME [-Offline] [-SkipWsl] [-Scan DIR[,DIR]] [-Bundle FILE[,FILE]]
       check-ca-trust.ps1 -List

Read-only check of this Windows machine (and its default WSL distribution) against a
CA distrust event: does any client or CA bundle here still trust a chain built on the
incident's listed keys? Each line reads PASS, FAIL or UNKNOWN; a FAIL or UNKNOWN line
ends with a one-line fix. The last line, RESULT, holds no host, user or path: it is
the line to share. On macOS and Linux, run check-ca-trust.sh instead.

  -Incident  the incident pack to check against (required; see -List)
  -List      list the incident packs this copy carries
  -Offline   skip the network tests (the result is then UNKNOWN at best)
  -SkipWsl   do not look inside WSL
  -Scan      also look for Python certifi bundles under these folders
  -Bundle    check only these CA bundle files, offline
  -Help      print this text (with -Incident, also that pack's hosts)

It contacts only the hosts its incident pack names, changes nothing, needs no admin
rights and writes only to stdout.

EXAMPLES
  powershell -NoProfile -ExecutionPolicy Bypass -File check-ca-trust.ps1 -List
  powershell -NoProfile -ExecutionPolicy Bypass -File check-ca-trust.ps1 -Incident emudhra-2026-10
  pwsh -NoProfile -File check-ca-trust.ps1 -Incident emudhra-2026-10 -Bundle .\image-ca.crt

Exit: 0 every line PASS, 10 any FAIL, 11 no FAIL but an UNKNOWN, 2 usage error,
3 no such incident pack, 4 malformed incident pack.
"@
}

function Stop-Usage([string]$Why) {
    [Console]::Error.WriteLine("check-ca-trust: $Why")
    [Console]::Error.WriteLine('Run with -Help for usage.')
    exit 2
}

# Paths under the home folder print as ~, so a pasted line names no user.
function Hide-Home([string]$Text) {
    foreach ($h in @($env:USERPROFILE, $env:HOME)) {
        if ($h -and $h.Length -gt 3) {
            $Text = [regex]::Replace($Text, [regex]::Escape($h), '~', 'IgnoreCase')
        }
    }
    return $Text
}

function Write-Result([string]$Status, [string]$Id, [string]$Detail, [string]$Fix) {
    $script:Counts[$Status]++
    $line = '{0,-7} {1,-22} {2}' -f $Status, $Id, (Hide-Home $Detail)
    if ($Status -ne 'PASS' -and $Fix) { $line += ' - fix: ' + (Hide-Home $Fix) }
    Write-Output $line
}

# The RESULT line is what people paste into a thread to sign a machine off: no host, user
# or path, and its fields stay in this order (tests/run.sh pins the format).
function Complete-Run {
    $verdict = 'PASS'; $code = 0
    if ($script:Counts['FAIL'] -gt 0) { $verdict = 'FAIL'; $code = 10 }
    elseif ($script:Counts['UNKNOWN'] -gt 0) { $verdict = 'UNKNOWN'; $code = 11 }
    Write-Output ('RESULT  {0} {1} {2} {3}: {4} ({5} pass, {6} fail, {7} unknown)' -f $Tool, $script:Pack.Id, $script:Platform, (Get-Date -Format 'yyyy-MM-dd'), $verdict, $script:Counts['PASS'], $script:Counts['FAIL'], $script:Counts['UNKNOWN'])
    $script:ExitCode = $code
}

# === INCIDENT PACK ===
# Format and field rules: ..\references\incident-packs.md. Everything a pack says is
# validated, because hosts and commands from it reach the network and the PATH. These
# rules match check-ca-trust.sh's load_pack line for line: a pack one script accepts,
# the other must accept too.

function Get-PackNames {
    $names = @(Get-ChildItem -LiteralPath $PackDir -Filter '*.conf' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.BaseName })
    if ($names.Count -eq 0) { return 'none' }
    return ($names -join ', ')
}

function Show-Packs {
    $files = @(Get-ChildItem -LiteralPath $PackDir -Filter '*.conf' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { [Console]::Error.WriteLine("check-ca-trust: no incident packs in $PackDir"); exit 3 }
    foreach ($f in $files) {
        $id = '?'; $title = '?'; $asOf = '?'
        foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
            $parts = $line.Split([char]'|')
            if ($parts.Count -lt 2) { continue }
            switch -CaseSensitive ($parts[0]) {
                'id' { $id = $parts[1] }
                'title' { $title = $parts[1] }
                'as_of' { $asOf = $parts[1] }
            }
        }
        Write-Output ('{0}  {1}  {2}' -f $id, $asOf, $title)
    }
}

function Stop-Pack([string]$Why) {
    [Console]::Error.WriteLine("check-ca-trust: $($script:PackFile): $Why")
    exit 4
}

# Lowercase letters, digits, dots and hyphens, at least one dot, no empty label at either
# end: nothing that could carry a path, port, credential or second URL into a probe.
function Test-HostName([string]$Name) {
    return ($Name -cmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') -and $Name.Contains('.') -and -not $Name.Contains('..')
}

# The same shape check as check-ca-trust.sh's SCAN_AWK: SEQUENCE { SEQUENCE, BIT STRING }
# with at least 16 key bytes. This script hashes certificates itself and needs only the
# hash, but a pack bash would refuse must be refused here too.
function Test-SpkiShape([string]$Text) {
    try {
        $der = [Convert]::FromBase64String($Text)
        if ($der.Length -lt 5 -or $der[0] -ne 0x30) { return $false }
        $h = Read-DerHeader $der 0
        $p = $h[0]
        if ($der[$p] -ne 0x30) { return $false }
        $x = Read-DerHeader $der $p
        $p += $x[0] + $x[1]
        if ($p -ge $der.Length -or $der[$p] -ne 0x03) { return $false }
        $x = Read-DerHeader $der $p
        return ((($p + $x[0] + $x[1]) -le $der.Length) -and (($x[1] - 1) -ge 16))
    } catch {
        return $false
    }
}

function Read-Pack([string]$Path, [string]$Expected) {
    $pack = @{
        Id = ''; Name = ''; Title = ''; AsOf = ''; Control = ''; ControlUrl = ''
        Listed = @{}; Paths = (New-Object System.Collections.Generic.List[object])
        Versions = (New-Object System.Collections.Generic.List[object]); Fixed = @{}
    }
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $n++
        $line = $raw.TrimEnd([char]13)
        if ($line.StartsWith('#')) { continue }
        $f = $line.Split([char]'|')
        $kind = $f[0]
        if ($kind -eq '') {
            if (@($f | Where-Object { $_ -ne '' }).Count -eq 0) { continue }
            Stop-Pack "line ${n}: a record starts with its type"
        }
        $used = @{ 'id' = 1; 'name' = 1; 'title' = 1; 'reference' = 1; 'as_of' = 1; 'control' = 1; 'key' = 3; 'path' = 2; 'fixed' = 2; 'version' = 5 }
        if (-not $used.ContainsKey($kind) -or -not ($kind -cmatch '^[a-z_]+$')) { Stop-Pack "line ${n}: unknown record type '$kind'" }
        $v = @()
        for ($i = 1; $i -le 5; $i++) { if ($i -lt $f.Count) { $v += $f[$i] } else { $v += '' } }
        for ($i = $used[$kind] + 1; $i -lt $f.Count; $i++) {
            if ($f[$i] -ne '') { Stop-Pack "line ${n}: '$kind' takes $($used[$kind]) field(s) after its type" }
        }
        switch -CaseSensitive ($kind) {
            { $_ -in 'id', 'name', 'title', 'reference' } {
                if (-not $v[0]) { Stop-Pack "line ${n}: '$kind' is empty" }
                if ($kind -eq 'id') { $pack.Id = $v[0] }
                if ($kind -eq 'name') { $pack.Name = $v[0] }
                if ($kind -eq 'title') { $pack.Title = $v[0] }
            }
            'as_of' {
                if ($v[0] -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') { Stop-Pack "line ${n}: as_of must be YYYY-MM-DD" }
                $pack.AsOf = $v[0]
            }
            'key' {
                if ($v[0] -cnotmatch '^[0-9A-F]{64}$') { Stop-Pack "line ${n}: a key is 64 upper-case hex digits (SPKI SHA-256)" }
                if (-not $v[1]) { Stop-Pack "line ${n}: a key needs the name of its certificate" }
                if ($v[2] -cnotmatch '^[A-Za-z0-9+/=]+$') { Stop-Pack "line ${n}: a key needs its SPKI in base64 (scripts/pack-keys.sh prints it)" }
                if (-not (Test-SpkiShape $v[2])) { Stop-Pack "a key's SPKI is not a SubjectPublicKeyInfo (scripts/pack-keys.sh prints it)" }
                if ($pack.Listed.ContainsKey($v[0])) { Stop-Pack "line ${n}: key $($v[0]) is listed twice" }
                $pack.Listed[$v[0]] = $v[1]
            }
            'control' {
                if (-not (Test-HostName $v[0])) { Stop-Pack "line ${n}: '$($v[0])' is not a host name" }
                $pack.Control = $v[0]
            }
            'path' {
                if ($v[0] -cnotmatch '^[A-Za-z0-9 ._-]+$') { Stop-Pack "line ${n}: a path label is letters, digits, spaces, dots, hyphens" }
                if (-not (Test-HostName $v[1])) { Stop-Pack "line ${n}: '$($v[1])' is not a host name" }
                foreach ($p in $pack.Paths) {
                    if ($p.Label -ceq $v[0] -or $p.Host -ceq $v[1]) { Stop-Pack "line ${n}: path '$($v[0])' repeats a label or host" }
                }
                $pack.Paths.Add(@{ Label = $v[0]; Host = $v[1]; Url = "https://$($v[1])/"; State = $null })
            }
            'version' {
                if ($v[0] -cnotmatch '^[a-z0-9-]+$') { Stop-Pack "line ${n}: a version id is lower-case letters, digits, hyphens" }
                if ($v[1] -cnotmatch '^[A-Za-z0-9._][A-Za-z0-9._-]*$') { Stop-Pack "line ${n}: '$($v[1])' is not a command name" }
                if (-not $v[2] -or -not $v[4]) { Stop-Pack "line ${n}: a version record needs a label and a fix" }
                if ($v[3] -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Stop-Pack "line ${n}: a minimum version is N.N.N" }
                $pack.Versions.Add(@{ Id = $v[0]; Command = $v[1]; Label = $v[2]; Minimum = $v[3]; Fix = $v[4] })
            }
            'fixed' {
                if (-not $v[1]) { Stop-Pack "line ${n}: 'fixed' needs the first fixed versions" }
                if ($v[0] -cnotin 'node', 'python', 'certifi', 'pip', 'git-for-windows', 'composer-ca-bundle') { Stop-Pack "line ${n}: unknown 'fixed' slot '$($v[0])'" }
                $pack.Fixed[$v[0]] = $v[1]
            }
        }
    }
    if ($pack.Id -cne $Expected) { Stop-Pack "its id is '$($pack.Id)', not the file name '$Expected'" }
    if (-not $pack.Name -or -not $pack.Title -or -not $pack.AsOf) { Stop-Pack 'it needs a name, a title and an as_of date' }
    if ($pack.Listed.Count -eq 0) { Stop-Pack 'it lists no key' }
    if (-not $pack.Control) { Stop-Pack 'it names no control host' }
    if ($pack.Paths.Count -eq 0) { Stop-Pack 'it names no trust path' }
    foreach ($p in $pack.Paths) { if ($p.Host -ceq $pack.Control) { Stop-Pack 'the control host is also a path host' } }
    $pack.ControlUrl = "https://$($pack.Control)/"
    return $pack
}

# An upgrade target for a fix hint: the pack's first fixed versions when it names them.
function Get-UpgradeHint([string]$What, [string]$Slot) {
    $versions = $script:Pack.Fixed[$Slot]
    if ($versions) { return "$What to $versions or later" }
    return "$What to a release with the $($script:Pack.Name) fix"
}

# === BUNDLES ===
# A bundle is judged by the SHA-256 of each certificate's SubjectPublicKeyInfo, so a
# cross-signed or re-issued certificate on a listed key is caught like the original.

function Read-DerHeader([byte[]]$Der, [int]$Pos) {
    $first = [int]$Der[$Pos + 1]
    if ($first -lt 0x80) { return @(2, $first) }
    $n = $first -band 0x7F
    $len = 0
    for ($i = 0; $i -lt $n; $i++) { $len = ($len * 256) + [int]$Der[$Pos + 2 + $i] }
    return @((2 + $n), $len)
}

# Walks Certificate -> TBSCertificate -> [0] version (optional), serial, signature,
# issuer, validity, subject -> subjectPublicKeyInfo (RFC 5280 section 4.1).
function Get-SpkiHash([byte[]]$Der) {
    try {
        $outer = Read-DerHeader $Der 0
        $p = $outer[0]
        $tbs = Read-DerHeader $Der $p
        $p += $tbs[0]
        if ($Der[$p] -eq 0xA0) { $x = Read-DerHeader $Der $p; $p += $x[0] + $x[1] }
        for ($k = 0; $k -lt 5; $k++) { $x = Read-DerHeader $Der $p; $p += $x[0] + $x[1] }
        if ($Der[$p] -ne 0x30) { return $null }
        $x = Read-DerHeader $Der $p
        $total = $x[0] + $x[1]
        $spki = New-Object byte[] $total
        [Array]::Copy($Der, $p, $spki, 0, $total)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($spki)) -replace '-', '')
    } catch {
        return $null
    }
}

# A certificate that cannot be read is counted, never skipped: a bundle of unreadable
# certificates must not read as one with no listed key.
function Test-BundleText([string]$Text) {
    $total = 0; $bad = 0; $hits = New-Object System.Collections.Generic.List[string]
    $pattern = '-----BEGIN (?:TRUSTED )?CERTIFICATE-----([A-Za-z0-9+/=\s]+?)-----END (?:TRUSTED )?CERTIFICATE-----'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        $total++
        $key = $null
        try { $key = Get-SpkiHash ([Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))) } catch { $key = $null }
        if (-not $key) { $bad++; continue }
        if ($script:Pack.Listed.ContainsKey($key) -and -not $hits.Contains($script:Pack.Listed[$key])) { $hits.Add($script:Pack.Listed[$key]) }
    }
    return @{ Total = $total; Bad = $bad; Hits = ($hits -join '; ') }
}

function Submit-Scan([string]$Id, [string]$What, $Result, [string]$Fix) {
    if ($Result.Total -eq 0) { Write-Result UNKNOWN $Id "no certificates could be read from $What" 'check that it is a PEM bundle' }
    elseif ($Result.Hits) { Write-Result FAIL $Id "$What trusts $($Result.Hits)" $Fix }
    elseif ($Result.Bad -gt 0) { Write-Result UNKNOWN $Id "${What}: $($Result.Bad) of $($Result.Total) certificates could not be read" 'check the file is a PEM bundle' }
    else { Write-Result PASS $Id "${What}: none of the $($script:Pack.Listed.Count) listed keys in $($Result.Total) certificates" }
}

function Test-BundleFile([string]$Id, [string]$Path, [string]$Fix) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Result UNKNOWN $Id "$Path does not exist" 'point it at a CA bundle that exists'
        return
    }
    try { $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath) } catch {
        Write-Result UNKNOWN $Id "$Path cannot be read" 're-run as a user who can read it'
        return
    }
    # Identical content (a copied bundle) is scanned once per run.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sum = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
    if (-not $script:Seen.ContainsKey($sum)) { $script:Seen[$sum] = Test-BundleText $text }
    Submit-Scan $Id $Path $script:Seen[$sum] $Fix
}

# === PROBES ===
# Each probe returns connected, rejected (a certificate error), cafail (curl could not read
# its CA file) or neterr (anything else), and goes direct to one URL.

# Under pwsh 7, [Environment]::SetEnvironmentVariable($n, $null) leaves the variable set to
# an empty string (PowerShell binds $null to a [string] parameter as ''), and git turns
# curl tracing on when GIT_CURL_VERBOSE merely exists. [NullString]::Value is a real null.
function Set-ProcessEnv([string]$Name, $Value) {
    if ($null -eq $Value) { [Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
    else { [Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}

# WindowsApps holds App Execution Alias stubs (python.exe that opens the Store).
function Find-Command([string]$Name) {
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
    $out = & $Exe @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out }
}

# HttpWebRequest with no revocation check: tests the Windows store and Microsoft's
# distrust lists (CTL), which reach every Schannel and .NET client on the machine.
function Get-ProbeDotNet([string]$Url) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $Agent
        $req.Timeout = 20000
        $req.AllowAutoRedirect = $false
        $req.Proxy = $null
        $resp = $req.GetResponse()
        $resp.Close()
        return 'connected'
    } catch {
        $e = $_.Exception
        while ($e) {
            if ($e -is [System.Security.Authentication.AuthenticationException] -and $e.Message -match '(?i)remote certificate|certificate chain|UntrustedRoot|PartialChain|NotTrusted|ExplicitDistrust|Revoked') { return 'rejected' }
            if ($e -is [Net.WebException] -and $e.Response) { $e.Response.Close(); return 'connected' }
            if ($e -is [Net.WebException] -and $e.Status -eq [Net.WebExceptionStatus]::TrustFailure) { return 'rejected' }
            $e = $e.InnerException
        }
        return 'neterr'
    }
}

# 35 is any TLS handshake failure, a reset included: a refusal only when the message says
# revoked or untrusted root, which is how Schannel's curl.exe reports distrust.
function Resolve-CurlResult($Result) {
    switch ($Result.Code) {
        0 { return 'connected' }
        { $_ -in 51, 60 } { return 'rejected' }
        35 {
            if ($Result.Text -match '(?i)revok|CRYPT_E_REVOKED|SEC_E_UNTRUSTED_ROOT|CERT_E_UNTRUSTEDROOT') { return 'rejected' }
            return 'neterr'
        }
        77 { return 'cafail' }
        default { return 'neterr' }
    }
}

function Get-ProbeCurl([string]$Exe, [string]$Url) {
    return Resolve-CurlResult (Invoke-Quiet $Exe @('-q', '-sS', '--noproxy', '*', '-o', 'NUL', '--max-time', '20', '-A', $Agent, $Url))
}

function Get-ProbeGit([string]$Exe, [string]$Url) {
    $saved = @{}
    foreach ($n in 'GIT_ASKPASS', 'SSH_ASKPASS', 'GIT_TERMINAL_PROMPT') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    Set-ProcessEnv 'GIT_ASKPASS' $null
    Set-ProcessEnv 'SSH_ASKPASS' $null
    Set-ProcessEnv 'GIT_TERMINAL_PROMPT' '0'
    try {
        $r = Invoke-Quiet $Exe @('-c', 'credential.helper=', '-c', 'http.extraHeader=', '-c', 'http.cookieFile=', '-c', 'core.askPass=', '-c', 'http.proxy=', '-c', 'http.followRedirects=false', '-c', "http.userAgent=$Agent", '-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=20', 'ls-remote', '--heads', $Url)
    } finally {
        foreach ($n in $saved.Keys) { Set-ProcessEnv $n $saved[$n] }
    }
    # Order matters: an untrusted-issuer message is a refusal, any other TLS message is not,
    # and an HTTP-level error (no repository there) means the handshake succeeded.
    if ($r.Code -eq 0) { return 'connected' }
    if ($r.Text -match '(?i)local issuer|issuer certificate|self.signed certificate in|certificate verification failed|unable to verify the first|revok|untrusted|not trusted') { return 'rejected' }
    if ($r.Text -match '(?i)certificate|ssl|tls|schannel') { return 'neterr' }
    if ($r.Text -match '(?i)not found|not valid|returned error|authentication failed|git repository|dumb http|redirect') { return 'connected' }
    return 'neterr'
}

function Get-ProbePython([string]$Exe, [string]$Url) {
    $r = Invoke-Quiet $Exe @('-I', '-c', $PyProbe, $Url)
    $last = ($r.Text.Trim() -split "`r?`n")[-1]
    if ($last -in 'connected', 'rejected') { return $last }
    return 'neterr'
}

function Get-ProbeNode([string]$Exe, [string]$Url) {
    $r = Invoke-Quiet $Exe @('-e', $NodeProbe, $Url)
    $last = ($r.Text.Trim() -split "`r?`n")[-1]
    if ($last -in 'connected', 'rejected') { return $last }
    return 'neterr'
}

function Get-ProbeWslCurl([string]$Url) {
    return Resolve-CurlResult (Invoke-Quiet 'wsl.exe' @('-e', 'env', '-u', 'https_proxy', '-u', 'HTTPS_PROXY', '-u', 'all_proxy', '-u', 'ALL_PROXY', 'curl', '-q', '-sS', '--noproxy', '*', '-o', '/dev/null', '--max-time', '20', '-A', $Agent, $Url))
}

# === PATH CONFIRMATION ===

# The dNSName entries ([2] IA5String, tag 0x82) of the subjectAltName extension, read from
# its DER (RFC 5280 section 4.2.1.6): X509Extension.Format() is localized, so its
# "DNS Name=" prefix exists on English Windows only.
function Get-DnsNames($Leaf) {
    $names = @()
    try {
        foreach ($ext in @($Leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })) {
            $der = $ext.RawData
            if ($der.Length -lt 2 -or $der[0] -ne 0x30) { continue }
            $h = Read-DerHeader $der 0
            $p = $h[0]
            $end = $h[0] + $h[1]
            while ($p -lt $end -and $p -lt $der.Length) {
                $x = Read-DerHeader $der $p
                if ($der[$p] -eq 0x82) { $names += [Text.Encoding]::ASCII.GetString($der, $p + $x[0], $x[1]) }
                $p += $x[0] + $x[1]
            }
        }
    } catch { }
    return $names
}
# Before any client's refusal counts, this script makes its own handshake with each path
# host and requires a listed key in the chain, on a current leaf that names the host. A
# DNS filter, block page, intercepting proxy, reset or expired leaf all make a client fail
# to connect, which would otherwise read as a safe refusal. The callback is a scriptblock,
# which works only because AuthenticateAsClient is synchronous.
function Get-PathState([string]$TargetHost, [int]$Port) {
    $script:PathLeaf = $null
    $script:PathChain = @()
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $pending = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(20000)) { return 'it could not be reached' }
        $tcp.EndConnect($pending)
        $callback = [Net.Security.RemoteCertificateValidationCallback] {
            param($s, $cert, $chain, $errors)
            if ($cert) { $script:PathLeaf = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $cert }
            if ($chain) { $script:PathChain = @($chain.ChainElements | ForEach-Object { , $_.Certificate.RawData }) }
            return $true
        }
        $ssl = New-Object Net.Security.SslStream -ArgumentList $tcp.GetStream(), $false, $callback
        $ssl.ReadTimeout = 20000
        $ssl.WriteTimeout = 20000
        try { $ssl.AuthenticateAsClient($TargetHost) } catch { }
        $ssl.Dispose()
    } catch {
    } finally {
        $tcp.Close()
    }
    if (-not $script:PathLeaf) { return 'it could not be reached' }
    $found = $false
    foreach ($raw in $script:PathChain) {
        $key = Get-SpkiHash $raw
        if ($key -and $script:Pack.Listed.ContainsKey($key)) { $found = $true }
    }
    if (-not $found) { return 'it did not present a chain with a listed key, so a proxy or filter may be in the way' }
    $now = [DateTime]::Now
    if ($script:PathLeaf.NotAfter -lt $now) { return 'its certificate has expired' }
    if ($script:PathLeaf.NotBefore -gt $now) { return "its certificate is not valid yet, so this machine's clock may be wrong" }
    # Whole names only: a name that merely starts with the host is not the host.
    $names = @(Get-DnsNames $script:PathLeaf)
    $wild = '*.' + ($TargetHost -replace '^[^.]+\.', '')
    if ($names -contains $TargetHost -or $names -contains $wild) { return 'ok' }
    return "its certificate does not name $TargetHost"
}

function Confirm-Paths {
    if ($script:PathsConfirmed) { return }
    foreach ($p in $script:Pack.Paths) { $p.State = Get-PathState $p.Host 443 }
    $script:PathsConfirmed = $true
}

function Test-Client([string]$Id, [string]$Label, [string]$Fix, [scriptblock]$Probe) {
    if ($Offline) { return }
    Confirm-Paths
    $c = & $Probe $script:Pack.ControlUrl
    if ($c -eq 'neterr') { $c = & $Probe $script:Pack.ControlUrl }
    if ($c -ne 'connected') {
        if ($c -eq 'cafail') { Write-Result UNKNOWN $Id "$Label cannot read its CA bundle, so it trusts nothing" 'point it at a bundle that exists' }
        else { Write-Result UNKNOWN $Id "$Label could not open the control page ($c), so its tests would prove nothing" "re-run on a network that allows HTTPS to $($script:Pack.Control)" }
        return
    }
    $why = @(); $open = @(); $seen = @(); $names = @(); $allRejected = $true
    foreach ($p in $script:Pack.Paths) {
        $names += $p.Label
        if ($p.State -eq 'ok') { $r = & $Probe $p.Url }
        else {
            # Not probed: without a confirmed chain neither a refusal nor a connection means anything.
            $r = 'unconfirmed'
            $why += "the $($p.Label) test site: $($p.State)"
        }
        if ($r -eq 'connected') { $open += "$($p.Label) path" }
        if ($r -ne 'rejected') { $allRejected = $false }
        $seen += "$($p.Label) test $r"
    }
    if ($open.Count -gt 0) { Write-Result FAIL $Id "$Label accepts a certificate chained to a listed $($script:Pack.Name) key ($($open -join ' and '))" $Fix }
    elseif ($allRejected) { Write-Result PASS $Id "$Label rejects every test chain ($($names -join ', '))" }
    elseif ($why.Count -gt 0) { Write-Result UNKNOWN $Id "$Label could not be tested: $($why -join '; ')" 're-run on another network, without a VPN, proxy or DNS filter' }
    else { Write-Result UNKNOWN $Id "${Label}: $($seen -join ', ')" "re-run; if it repeats, open $($script:Pack.Paths[0].Url) with $Label by hand" }
}

# === CHECKS ===

function Test-WindowsStore {
    Test-Client 'windows-store' 'Windows certificate checks (.NET, no revocation check)' 'run Windows Update and make sure automatic root certificate updates are allowed: Microsoft ships distrust through its certificate trust lists' { param($u) Get-ProbeDotNet $u }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        Test-Client 'windows-curl' 'curl.exe (Schannel)' 'run Windows Update' ({ param($u) Get-ProbeCurl $curl $u }.GetNewClosure())
    }
}

function Test-TlsEnv {
    $bad = @()
    if ($env:NODE_TLS_REJECT_UNAUTHORIZED -eq '0') { $bad += 'NODE_TLS_REJECT_UNAUTHORIZED=0' }
    if ($env:PYTHONHTTPSVERIFY -eq '0') { $bad += 'PYTHONHTTPSVERIFY=0' }
    if ($env:GIT_SSL_NO_VERIFY) { $bad += 'GIT_SSL_NO_VERIFY' }
    if ($bad.Count -gt 0) { Write-Result FAIL 'tls-env' "$($bad -join ', ') turns certificate checks off for everything started from here" 'remove it from your user environment variables and open a new terminal' }
    else { Write-Result PASS 'tls-env' 'no environment variable turns certificate checks off' }
    foreach ($name in 'SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'PIP_CERT', 'NODE_EXTRA_CA_CERTS', 'GIT_SSL_CAINFO') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { Test-BundleFile "env-$name" $value "point $name at a current bundle" }
    }
}

function Test-Git {
    $git = Find-Command 'git'
    if (-not $git) { Write-Result PASS 'git' 'git is not installed'; return }
    $version = ((& $git --version 2>$null) -replace '^git version ', '').Trim()
    $backend = ((& $git config --get http.sslBackend 2>$null) | Out-String).Trim()
    if (-not $backend) { $backend = 'default' }
    $verify = ((& $git config --get --type=bool http.sslVerify 2>$null) | Out-String).Trim()
    if ($verify -eq 'false') { Write-Result FAIL 'git-sslverify' 'git config sets http.sslVerify false, so git checks no certificate' 'git config --global --unset http.sslVerify' }
    $fix = "update $(Get-UpgradeHint 'Git for Windows' 'git-for-windows') (installed: $version)"
    $bundles = New-Object System.Collections.Generic.List[string]
    $exec = ((& $git --exec-path 2>$null) | Out-String).Trim()
    if ($exec) {
        $mingw = Split-Path (Split-Path $exec -Parent) -Parent
        $own = Join-Path $mingw 'etc\ssl\certs\ca-bundle.crt'
        if (Test-Path -LiteralPath $own) { $bundles.Add((Resolve-Path -LiteralPath $own).ProviderPath) }
    }
    $cainfo = ((& $git config --get --type=path http.sslCAInfo 2>$null) | Out-String).Trim()
    if ($cainfo) {
        $native = $cainfo -replace '/', '\'
        if (Test-Path -LiteralPath $native) { $native = (Resolve-Path -LiteralPath $native).ProviderPath }
        if (-not ($bundles | Where-Object { $_ -ieq $native })) { $bundles.Add($native) }
    }
    foreach ($b in $bundles) { Test-BundleFile 'git-bundle' $b $fix }
    Test-Client 'git' "git $version ($backend backend)" $fix ({ param($u) Get-ProbeGit $git $u }.GetNewClosure())
}

function Get-Pythons {
    $found = New-Object System.Collections.Generic.List[string]
    $py = Find-Command 'py'
    if ($py) {
        foreach ($line in (& $py -0p 2>$null)) {
            if ($line -match '([A-Za-z]:\\.*?pythonw?\.exe)\s*$') { $found.Add($Matches[1]) }
        }
    }
    foreach ($name in 'python', 'python3') {
        foreach ($c in @(Get-Command $name -All -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($c.Source -notmatch '\\WindowsApps\\') { $found.Add($c.Source) }
        }
    }
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($f in $found) { if (-not ($unique | Where-Object { $_ -ieq $f })) { $unique.Add($f) } }
    return $unique
}

# Both the plain import and one with the user site added: python -I drops the user site.
function Get-CertifiFiles([string[]]$Pythons) {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Pythons) {
        foreach ($mod in 'certifi', 'pip._vendor.certifi') {
            foreach ($prefix in '', 'import site, sys; sys.path.insert(0, site.getusersitepackages()); ') {
                $r = Invoke-Quiet $p @('-I', '-c', "${prefix}import $mod as c; print(c.where())")
                $last = ($r.Text.Trim() -split "`r?`n")[-1]
                if ($r.Code -eq 0 -and $last -and (Test-Path -LiteralPath $last)) { $files.Add($last) }
            }
        }
    }
    $roots = @()
    if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'uv\tools'); $roots += (Join-Path $env:APPDATA 'Python') }
    if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE 'pipx\venvs'); $roots += (Join-Path $env:USERPROFILE '.virtualenvs') }
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'pipx\pipx\venvs'); $roots += (Join-Path $env:LOCALAPPDATA 'pypoetry\Cache\virtualenvs') }
    if ($Scan) { $roots += $Scan }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -Depth 8 -Filter 'cacert.pem' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\certifi\\' } | ForEach-Object { $files.Add($_.FullName) }
    }
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) { if (-not ($unique | Where-Object { $_ -ieq $f })) { $unique.Add($f) } }
    return $unique
}

function Get-CertifiFix([string]$Path) {
    if ($Path -match '\\uv\\tools\\([^\\]+)\\') { return "uv tool upgrade $($Matches[1]) (or uv tool upgrade --all)" }
    if ($Path -match '\\pipx\\venvs\\([^\\]+)\\') { return "pipx runpip $($Matches[1]) install -U certifi" }
    if ($Path -match '\\pip\\_vendor\\certifi\\') { return "update $(Get-UpgradeHint 'pip' 'pip') in that Python: python -m pip install -U pip" }
    return "update $(Get-UpgradeHint 'certifi' 'certifi') in that environment: python -m pip install -U certifi"
}

# Python's urllib on Windows loads the Windows root store into OpenSSL, which does not
# apply Microsoft's distrust lists: python can FAIL while windows-store passes. Real.
function Test-Python {
    $pythons = @(Get-Pythons)
    if ($pythons.Count -eq 0) { Write-Result PASS 'python' 'Python is not installed' }
    foreach ($p in $pythons) {
        $r = Invoke-Quiet $p @('-I', '-c', "import sys; print('%d.%d.%d' % sys.version_info[:3])")
        $version = ($r.Text.Trim() -split "`r?`n")[-1]
        Test-Client 'python' "Python $version urllib (Windows store)" "update $(Get-UpgradeHint 'Python' 'python')" ({ param($u) Get-ProbePython $p $u }.GetNewClosure())
    }
    $files = @(Get-CertifiFiles $pythons)
    if ($files.Count -eq 0) { Write-Result PASS 'certifi' 'no Python certifi bundle found in the usual places (add -Scan DIR for project venvs)' }
    foreach ($f in $files) { Test-BundleFile 'certifi' $f (Get-CertifiFix $f) }
}

function Test-Node {
    $node = Find-Command 'node'
    if (-not $node) { Write-Result PASS 'node' 'node is not installed'; return }
    $version = ((& $node --version 2>$null) | Out-String).Trim()
    $fix = "update $(Get-UpgradeHint 'Node.js' 'node')"
    $roots = (& $node -p "require('tls').rootCertificates.join('\n')" 2>$null) | Out-String
    if ($roots.Trim()) { Submit-Scan 'node-roots' "Node.js $version bundled roots" (Test-BundleText $roots) $fix }
    else { Write-Result UNKNOWN 'node-roots' "could not read Node.js $version bundled roots" 'check node runs: node -p process.version' }
    Test-Client 'node' "Node.js $version https" "$fix, and check NODE_EXTRA_CA_CERTS" ({ param($u) Get-ProbeNode $node $u }.GetNewClosure())
}

# [version] compares numerically, field by field: 2.1.1000 is later than 2.1.303.
function Test-ToolVersion([string]$Id, [string]$Command, [string]$Label, [string]$Minimum, [string]$Fix) {
    $exe = Find-Command $Command
    if (-not $exe) { Write-Result PASS $Id "$Label is not on the PATH"; return }
    $text = ((& $exe --version 2>$null) | Select-Object -First 1 | Out-String).Trim()
    if ($text -notmatch '(?:^|\s)v?(\d+)\.(\d+)\.(\d+)') { Write-Result UNKNOWN $Id "could not read the version of $exe" "run: $Command --version"; return }
    $version = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
    if ($version -lt [version]$Minimum) { Write-Result FAIL $Id "$Label $version predates $Minimum, the first release with the $($script:Pack.Name) fix" $Fix }
    else { Write-Result PASS $Id "$Label $version is $Minimum or later" }
}

function Test-Php {
    $php = Find-Command 'php'
    if (-not $php) { Write-Result PASS 'php' 'PHP is not installed'; return }
    $r = Invoke-Quiet $php @('-r', "echo ini_get('openssl.cafile'), PHP_EOL, ini_get('curl.cainfo'), PHP_EOL;")
    $named = @(($r.Text -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($named.Count -eq 0) { Write-Result PASS 'php-cafile' 'php.ini names no CA bundle (openssl.cafile and curl.cainfo are empty)' }
    foreach ($f in $named) { Test-BundleFile 'php-cafile' $f 'point openssl.cafile and curl.cainfo in php.ini at a current bundle' }
    $composer = Find-Command 'composer'
    if (-not $composer) { return }
    $dir = Split-Path $composer -Parent
    $candidates = @((Join-Path $dir 'composer.phar'))
    if ($composer -match '\.phar$') { $candidates = @($composer) + $candidates }
    if ($env:USERPROFILE -and $dir -match '\\scoop\\shims$') { $candidates += (Join-Path (Split-Path $dir -Parent) 'apps\composer\current\composer.phar') }
    $phar = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $phar) { Write-Result UNKNOWN 'composer-bundle' "could not find composer.phar next to $composer" 'composer self-update, then re-run'; return }
    $r = Invoke-Quiet $php @('-r', "echo @file_get_contents('phar://' . `$argv[1] . '/vendor/composer/ca-bundle/res/cacert.pem');", $phar.Replace('\', '/'))
    $fix = 'composer self-update'
    if ($script:Pack.Fixed['composer-ca-bundle']) { $fix += " (its ca-bundle must be $($script:Pack.Fixed['composer-ca-bundle']) or later)" }
    if ($r.Text -match 'BEGIN CERTIFICATE') { Submit-Scan 'composer-bundle' "Composer's bundled CA list ($phar)" (Test-BundleText $r.Text) $fix }
    else { Write-Result UNKNOWN 'composer-bundle' "could not read the CA list inside $phar" 'composer self-update, then re-run' }
}

function Test-Wsl {
    if ($SkipWsl) { return }
    $wsl = Find-Command 'wsl.exe'
    if (-not $wsl) { Write-Result PASS 'wsl' 'WSL is not installed'; return }
    $env:WSL_UTF8 = '1'
    $list = Invoke-Quiet $wsl @('--list', '--quiet')
    $names = @(($list.Text -replace "`0", '') -split "`r?`n" | Where-Object { $_.Trim() })
    if ($list.Code -ne 0 -or $names.Count -eq 0) { Write-Result PASS 'wsl' 'no WSL distribution is installed'; return }
    $version = (Invoke-Quiet $wsl @('-e', 'dpkg-query', '-W', '-f', '${Version}', 'ca-certificates')).Text.Trim()
    if (-not $version) { $version = 'unknown' }
    $fix = "inside WSL: sudo apt update && sudo apt install --only-upgrade ca-certificates (installed: $version), then run check-ca-trust.sh there"
    $read = $false
    foreach ($path in '/etc/ssl/certs/ca-certificates.crt', '/etc/pki/tls/certs/ca-bundle.crt', '/etc/ssl/cert.pem') {
        $r = Invoke-Quiet $wsl @('-e', 'cat', $path)
        if ($r.Code -eq 0 -and $r.Text -match 'BEGIN CERTIFICATE') {
            Submit-Scan 'wsl-bundle' "WSL $path" (Test-BundleText $r.Text) $fix
            $read = $true
            break
        }
    }
    if (-not $read) { Write-Result UNKNOWN 'wsl-bundle' 'could not read a CA bundle in the default WSL distribution' 'start WSL once, then re-run' }
    $has = Invoke-Quiet $wsl @('-e', 'curl', '--version')
    if ($has.Code -eq 0) { Test-Client 'wsl-curl' 'WSL curl' $fix { param($u) Get-ProbeWslCurl $u } }
}

# === MAIN ===

# Not an advanced script, so unknown parameters land in $args instead of failing to bind.
if ($args.Count -gt 0) { Stop-Usage "unknown argument: $($args[0])" }
if ($List) { Show-Packs; exit 0 }
if ($Help -and -not $Incident) { Show-Usage; exit 0 }
if (-not $Incident) { Stop-Usage "-Incident NAME is required; packs here: $(Get-PackNames)" }
# A name, never a path: it selects a reviewed pack from this skill's own assets.
if ($Incident -cnotmatch '^[a-z0-9][a-z0-9-]*$') { Stop-Usage "an incident name is lower-case letters, digits and hyphens; packs here: $(Get-PackNames)" }
$script:PackFile = Join-Path $PackDir "$Incident.conf"
if (-not (Test-Path -LiteralPath $script:PackFile -PathType Leaf)) {
    [Console]::Error.WriteLine("check-ca-trust: no incident pack named $Incident; packs here: $(Get-PackNames)")
    exit 3
}
$script:Pack = Read-Pack $script:PackFile $Incident
if ($Help) {
    Show-Usage
    Write-Output ''
    Write-Output "Hosts for $($script:Pack.Id) ($($script:Pack.Title), as of $($script:Pack.AsOf)):"
    Write-Output ('  control  {0}' -f $script:Pack.ControlUrl)
    foreach ($p in $script:Pack.Paths) { Write-Output ('  {0,-8} {1}' -f $p.Label, $p.Url) }
    exit 0
}
# pwsh -File passes "-Bundle a,b" as one string.
$Bundle = @($Bundle | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Scan = @($Scan | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

# Windows variable names ignore case, and so does a hashtable: save every variable before
# clearing any, in a case-sensitive dictionary, or clearing https_proxy first would save
# HTTPS_PROXY as already gone and restore it as deleted.
$saved = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$cleared = 'SSLKEYLOGFILE', 'WSL_UTF8', 'GIT_TRACE', 'GIT_TRACE_CURL', 'GIT_TRACE_PACKET', 'GIT_TRACE_SETUP', 'GIT_CURL_VERBOSE', 'GIT_HTTP_USER_AGENT', 'https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY', 'all_proxy', 'ALL_PROXY', 'NODE_USE_ENV_PROXY'
foreach ($name in $cleared) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
foreach ($name in $cleared) { Set-ProcessEnv $name $null }
$savedProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    if ($Bundle) {
        foreach ($b in $Bundle) { Test-BundleFile 'bundle' $b 'remove the listed certificates, or replace the bundle with a current one' }
    } elseif (-not $OnWindows) {
        $script:Platform = 'not-windows'
        Write-Result UNKNOWN 'platform' 'this is not Windows' 'on macOS and Linux, run check-ca-trust.sh'
    } else {
        $script:Platform = 'windows'
        Test-WindowsStore
        Test-TlsEnv
        Test-Git
        Test-Python
        Test-Node
        foreach ($v in $script:Pack.Versions) { Test-ToolVersion $v.Id $v.Command $v.Label $v.Minimum $v.Fix }
        Test-Php
        Test-Wsl
        if ($Offline) { Write-Result UNKNOWN 'network' 'the network tests were skipped (-Offline), so no client was tested' 're-run without -Offline' }
    }
    Complete-Run
} finally {
    foreach ($name in $saved.Keys) { Set-ProcessEnv $name $saved[$name] }
    [Net.ServicePointManager]::SecurityProtocol = $savedProtocol
}
exit $script:ExitCode
