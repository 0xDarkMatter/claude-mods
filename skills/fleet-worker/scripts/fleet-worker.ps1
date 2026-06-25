#!/usr/bin/env pwsh
# fleet-worker.ps1 - run a cheap headless Claude Code worker on a non-Anthropic model (PowerShell).
#
# Thin launcher: points Claude Code (`claude -p`) at any Anthropic-compatible
# endpoint (default: z.ai / GLM) via env, inside an ISOLATED config dir, then
# runs it. The result is a headless agent with Claude Code's full tool harness
# but a cheaper "grunt" brain. See ../SKILL.md.
#
# Usage:   fleet-worker.ps1 [-Help] [claude-flags...] "PROMPT"
# Output:  whatever `claude -p` emits (text, or --output-format json/stream-json)
# Exit:    0 ok; 1 worker/API error; 5 missing dep / no key resolved
#
# Config (env, all optional - defaults target the z.ai GLM Coding Plan):
#   FLEET_WORKER_CONFIG_DIR   isolated CLAUDE_CONFIG_DIR (default ~/.fleet-worker/cfg)
#   FLEET_WORKER_BASE_URL     Anthropic-compatible endpoint (default z.ai)
#   FLEET_WORKER_MODEL        main model      (default GLM-5.2)
#   FLEET_WORKER_SMALL_MODEL  background model (default GLM-4.5-Air)
#   FLEET_WORKER_EFFORT       seeded effortLevel (default high)
#   FLEET_WORKER_PERMISSION_MODE  worker --permission-mode (default bypassPermissions).
#                             Use dontAsk + an allowlist to spawn FROM an auto-mode
#                             orchestrator - a bypassPermissions launch is hard-denied
#                             there as "Create Unsafe Agents". See ../SKILL.md.
# Key resolution order (the key is never printed):
#   1. ANTHROPIC_AUTH_TOKEN (already set)                  -> used as-is
#   2. FLEET_WORKER_KEYRING_SERVICE + FLEET_WORKER_KEYRING_KEY -> `keyring get svc key`
#   3. ZHIPU_API_KEY / GLM_API_KEY                         -> used as-is
#
# Examples:
#   ./fleet-worker.ps1 "List the TODOs under src/ and summarize them"
#   ./fleet-worker.ps1 --output-format json "Refactor utils.py"
$ErrorActionPreference = 'Stop'

if ($args.Count -ge 1 -and ($args[0] -eq '-Help' -or $args[0] -eq '--help' -or $args[0] -eq '-h')) {
  Get-Content $PSCommandPath | Select-Object -Skip 1 |
    ForEach-Object { if ($_ -match '^#') { $_ -replace '^# ?', '' } else { return } }
  exit 0
}

# Auth isolation (LOAD-BEARING; see references/fleet-worker-spec.md sec 4): a dedicated
# config dir => the worker inherits no host Claude.ai OAuth account, so our token
# is the only credential and actually reaches the endpoint (else 401).
$cfg = if ($env:FLEET_WORKER_CONFIG_DIR) { $env:FLEET_WORKER_CONFIG_DIR } `
       else { Join-Path $HOME '.fleet-worker/cfg' }
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
$settings = Join-Path $cfg 'settings.json'
if (-not (Test-Path $settings)) {
  $effort = if ($env:FLEET_WORKER_EFFORT) { $env:FLEET_WORKER_EFFORT } else { 'high' }
  "{ ""hooks"": {}, ""effortLevel"": ""$effort"" }" | Set-Content -Path $settings -Encoding utf8
}
$env:CLAUDE_CONFIG_DIR = $cfg

# Resolve the API key (never printed). .Trim() strips trailing CRLF from `keyring get`.
function Resolve-GlmKey {
  if ($env:ANTHROPIC_AUTH_TOKEN) { return $env:ANTHROPIC_AUTH_TOKEN }
  if ($env:FLEET_WORKER_KEYRING_SERVICE -and $env:FLEET_WORKER_KEYRING_KEY -and (Get-Command keyring -ErrorAction SilentlyContinue)) {
    $k = (keyring get $env:FLEET_WORKER_KEYRING_SERVICE $env:FLEET_WORKER_KEYRING_KEY 2>$null)
    if ($k) { return ($k | Out-String).Trim() }
  }
  if ($env:ZHIPU_API_KEY) { return $env:ZHIPU_API_KEY }
  if ($env:GLM_API_KEY)   { return $env:GLM_API_KEY }
  return $null
}
$key = Resolve-GlmKey
if (-not $key) {
  Write-Error @'
fleet-worker: no API key resolved. Provide one of:
  - $env:ANTHROPIC_AUTH_TOKEN = '<key>'
  - $env:FLEET_WORKER_KEYRING_SERVICE / FLEET_WORKER_KEYRING_KEY  (uses `keyring get`)
  - $env:ZHIPU_API_KEY = '<key>'   (or GLM_API_KEY)
'@
  exit 5
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Error "fleet-worker: 'claude' (Claude Code) not found on PATH"; exit 5
}

$env:ANTHROPIC_BASE_URL          = if ($env:FLEET_WORKER_BASE_URL) { $env:FLEET_WORKER_BASE_URL } else { 'https://api.z.ai/api/anthropic' }
$env:ANTHROPIC_AUTH_TOKEN        = $key
$env:ANTHROPIC_DEFAULT_OPUS_MODEL   = if ($env:FLEET_WORKER_MODEL) { $env:FLEET_WORKER_MODEL } else { 'GLM-5.2' }
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = $env:ANTHROPIC_DEFAULT_OPUS_MODEL
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = if ($env:FLEET_WORKER_SMALL_MODEL) { $env:FLEET_WORKER_SMALL_MODEL } else { 'GLM-4.5-Air' }

# Permission mode: default bypassPermissions (back-compat; safety = the cage). When
# spawned FROM an auto-mode orchestrator, a bypassPermissions launch is hard-denied as
# "Create Unsafe Agents" - use dontAsk + an allowlist instead. See ../SKILL.md.
$permMode = if ($env:FLEET_WORKER_PERMISSION_MODE) { $env:FLEET_WORKER_PERMISSION_MODE } else { 'bypassPermissions' }
if ($permMode -notin @('default','acceptEdits','plan','auto','dontAsk','bypassPermissions')) {
  # Direct stderr (not Write-Error) so exit 2 is honored under $ErrorActionPreference='Stop'.
  [Console]::Error.WriteLine("fleet-worker: invalid FLEET_WORKER_PERMISSION_MODE: $permMode (expected default|acceptEdits|plan|auto|dontAsk|bypassPermissions)")
  exit 2
}
if ($permMode -eq 'dontAsk') {
  $hasAllow = ($args -contains '--allowedTools') -or ($args -contains '--allowed-tools') -or `
              ((Test-Path $settings) -and ((Get-Content -Raw $settings) -match '"allow"'))
  if (-not $hasAllow) {
    [Console]::Error.WriteLine("fleet-worker: permission-mode dontAsk with no allowlist - worker will auto-deny most tools; pass --allowedTools '...' or set permissions.allow in $settings")
  }
}

claude -p --model sonnet --permission-mode $permMode @args
exit $LASTEXITCODE
