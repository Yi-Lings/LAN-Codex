param(
  [switch]$Stop,
  [string]$StateDir = (Join-Path $env:LOCALAPPDATA "LAN Codex")
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ServerScript = Join-Path $ProjectRoot "server.js"
$ConfigPath = Join-Path $StateDir "config.json"

if (-not $Stop -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { exit 0 }

try {
  $config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
} catch {
  exit 0
}

$serverPid = if ($config.serverPid) { [int]$config.serverPid } else { 0 }
if ($serverPid) {
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $serverPid" -ErrorAction SilentlyContinue
  if ($process) {
    $commandLine = [string]$process.CommandLine
    $isInstalledServer = $commandLine.IndexOf($ServerScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $isLanCodexServer = $commandLine -match 'lan-only-guard\.js' -and $commandLine -match 'server\.js'
    if ($isInstalledServer -or $isLanCodexServer) {
      Stop-Process -Id $serverPid -Force -ErrorAction Stop
      Wait-Process -Id $serverPid -Timeout 5 -ErrorAction SilentlyContinue
    }
  }
}

$config.serverPid = 0
$config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
