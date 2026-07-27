param(
  [int]$Port = 8787,
  [string]$Token = "",
  [string]$CodexExe = "",
  [switch]$OpenCodexCdp,
  [switch]$ForceRestartCodex
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$GuardScript = Join-Path $ProjectRoot "scripts\lan-only-guard.js"
$ServerScript = Join-Path $ProjectRoot "server.js"
$ServerStateDir = Join-Path $env:USERPROFILE ".codex-mini"

function Test-NodeExe {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $version = [string](& $Path --version 2>$null)
    return $version -match '^v(2[0-9]|[3-9][0-9])\.'
  } catch {
    return $false
  }
}

function Get-NodeExe {
  $pathNode = Get-Command node -ErrorAction SilentlyContinue
  if ($pathNode -and (Test-NodeExe $pathNode.Source)) { return $pathNode.Source }

  $candidates = @(
    (Join-Path $ProjectRoot ".runtime\node\node.exe"),
    (Join-Path $ProjectRoot "bin\node\node.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-NodeExe $candidate) { return $candidate }
  }
  throw "Node.js 20 or newer was not found. Install Node.js, then reopen this command."
}

function New-MobileToken {
  $bytes = New-Object byte[] 24
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }
if (-not (Test-Path -LiteralPath $GuardScript -PathType Leaf)) { throw "LAN-only guard is missing: $GuardScript" }
if (-not (Test-Path -LiteralPath $ServerScript -PathType Leaf)) { throw "Local server is missing: $ServerScript" }
New-Item -ItemType Directory -Path $ServerStateDir -Force | Out-Null
if (-not $Token) { $Token = New-MobileToken }

if ($OpenCodexCdp) {
  $launchArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $ProjectRoot "scripts\launch-main-codex-cdp.ps1"),
    "-CdpPort", "39252",
    "-OpenAfterPrepare"
  )
  if ($CodexExe) { $launchArgs += @("-CodexExe", $CodexExe) }
  if ($ForceRestartCodex) { $launchArgs += "-ForceRestart" }
  & powershell.exe @launchArgs
  if ($LASTEXITCODE -ne 0) { throw "Controlled ChatGPT/Codex did not start successfully." }
}

$env:PORT = [string]$Port
$env:HOST = "0.0.0.0"
$env:MOBILE_TYPER_TOKEN = $Token
$env:CODEX_MINI_APP_NAME = "LAN Codex"
$env:CODEX_MINI_LOCAL_ONLY = "1"
$env:CODEX_MINI_DISABLE_A1_TUNNEL = "1"
$env:CODEX_MINI_DISABLE_IMESSAGE_NOTIFY = "1"
$env:CODEX_MINI_CDP_PORT = "39252"
if ($CodexExe) { $env:CODEX_DESKTOP_EXECUTABLE_PATH = $CodexExe }
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = $env:NO_PROXY

$nodeExe = Get-NodeExe
Set-Location -LiteralPath $ProjectRoot
Write-Host "LAN Codex listening on port $Port"
Write-Host "Only loopback and private-network outbound connections are permitted."
& $nodeExe --require $GuardScript $ServerScript
exit $LASTEXITCODE
