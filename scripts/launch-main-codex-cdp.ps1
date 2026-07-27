param(
  [string]$CodexExe = "",
  [int]$CdpPort = 39252,
  [string]$CdpAddress = "127.0.0.1",
  [string]$UserDataDir = "",
  [int]$ReadyTimeoutSeconds = 35,
  [switch]$OpenAfterPrepare,
  [switch]$AllowIsolatedProfile,
  [switch]$NoWaitForReady,
  [switch]$ForceRestart,
  [switch]$ImmediateFreshLaunch
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptRoot

try {
  if (-not ("CodexMini.User32" -as [type])) {
    Add-Type -Namespace CodexMini -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);'
  }
} catch {}

function Test-LoopbackPortOpen {
  param([int]$Port, [int]$TimeoutMs = 150)
  if ($Port -le 0) { return $false }
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync("127.0.0.1", $Port)
    if (-not $task.Wait($TimeoutMs)) { return $false }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Test-CodexCdpPageReady {
  param([int]$Port)
  if (-not (Test-LoopbackPortOpen -Port $Port -TimeoutMs 150)) { return $false }
  $hosts = @("127.0.0.1", "localhost")
  foreach ($hostName in $hosts) {
    try {
      $targets = Invoke-RestMethod -Uri "http://$hostName`:$Port/json/list" -TimeoutSec 1
      foreach ($target in @($targets)) {
        if ($target.type -eq "page" -and $target.webSocketDebuggerUrl -and [string]$target.url -like "app://-/index.html*") {
          return $true
        }
      }
    } catch {
    }
  }
  return $false
}

function Get-CodexDesktopProcessInfo {
  $items = @()
  foreach ($name in @("ChatGPT.exe", "Codex.exe")) {
    try { $items += @(Get-CimInstance Win32_Process -Filter "name = '$name'") } catch {}
  }
  return @($items | Where-Object {
    $exe = ([string]$_.ExecutablePath) -replace '/', '\'
    $exe -and (
      ($exe -match '\\app\\(?:ChatGPT|Codex)\.exe$') -or
      ($exe -match '\\Programs\\Codex\\Codex\.exe$')
    )
  })
}

function Test-CodexCdpWindowVisible {
  param([int]$Port)
  try {
    $items = @(Get-CodexDesktopProcessInfo |
      Where-Object {
        $cmd = [string]$_.CommandLine
        $cmd -and ($cmd -notmatch '\s--type=') -and
          ($cmd -match "--remote-debugging-port=$Port")
    })
    foreach ($item in $items) {
      $process = Get-Process -Id ([int]$item.ProcessId) -ErrorAction SilentlyContinue
      if ($process -and $process.MainWindowHandle -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
        try {
          if (("CodexMini.User32" -as [type]) -and -not [CodexMini.User32]::IsWindowVisible($process.MainWindowHandle)) { continue }
        } catch {}
        return $true
      }
    }
  } catch {
  }
  return $false
}

function Test-CodexCdpReady {
  param([int]$Port)
  # Electron 主窗口句柄可能临时挂在另一个进程、最小化时也可能为 0。
  # 只要主页面 target 与 webSocketDebuggerUrl 有效，CDP 就仍可控制；窗口可见性仅用于辅助恢复残留进程。
  return (Test-CodexCdpPageReady -Port $Port)
}

function Find-CodexExe {
  param([string]$Explicit)

  # 后台监听刚捕获到官方 GPT 新进程时会把它的真实路径直接传进来。
  # 先返回显式路径，避免退出窗口前后再等待 WMI / Appx 全量发现。
  if ($Explicit) {
    $normalizedExplicit = ([string]$Explicit) -replace '/', '\'
    if (Test-Path -LiteralPath $Explicit -PathType Leaf) {
      return (Resolve-Path -LiteralPath $Explicit).Path
    }
    if ($normalizedExplicit -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(?:ChatGPT|Codex)\.exe$') {
      return [string]$Explicit
    }
  }

  $candidates = @()
  if ($env:CODEX_DESKTOP_EXECUTABLE_PATH) { $candidates += $env:CODEX_DESKTOP_EXECUTABLE_PATH }

  try {
    $runningDesktop = Get-CodexDesktopProcessInfo |
      Select-Object -First 1 -ExpandProperty ExecutablePath
    if ($runningDesktop) { $candidates += $runningDesktop }
  } catch {
  }

  try {
    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq "OpenAI.Codex" -or
          $_.PackageFamilyName -like "OpenAI.Codex_*" -or
          (($_.Name -like "*Codex*") -and $_.InstallLocation -and (
            (Test-Path -LiteralPath (Join-Path $_.InstallLocation "app\ChatGPT.exe") -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $_.InstallLocation "app\Codex.exe") -PathType Leaf)
          ))
      })
    foreach ($package in $packages) {
      if ($package.InstallLocation) {
        $candidates += Join-Path $package.InstallLocation "app\ChatGPT.exe"
        $candidates += Join-Path $package.InstallLocation "app\Codex.exe"
      }
    }
  } catch {
  }

  if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA "Programs\Codex\Codex.exe"
    $candidates += Join-Path $env:LOCALAPPDATA "Codex\Codex.exe"
  }
  if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles "Codex\Codex.exe" }
  if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} "Codex\Codex.exe" }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not $candidate) { continue }
    $normalized = ([string]$candidate) -replace '/', '\'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
    # WindowsApps 包路径在某些机器上即使真实存在也可能因权限导致 Test-Path 返回 false；
    # 只要能识别出 Codex Appx 安装路径，后续会走 AUMID 激活，不直接执行该路径。
    if ($normalized -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(?:ChatGPT|Codex)\.exe$') {
      return [string]$candidate
    }
  }

  return ""
}

function Get-CodexAumid {
  try {
    $package = Get-AppxPackage -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq "OpenAI.Codex" -or $_.PackageFamilyName -like "OpenAI.Codex_*" } |
      Select-Object -First 1
    if ($package -and $package.PackageFamilyName) {
      return "$($package.PackageFamilyName)!App"
    }
  } catch {
  }
  return ""
}

function Start-CodexPackagedApp {
  param(
    [string]$Aumid,
    [string[]]$Arguments
  )

  if (-not $Aumid) { throw "ChatGPT/Codex Appx AUMID was not found." }

  if (-not ("CodexMini.ApplicationActivationManager" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace CodexMini {
  [Flags]
  public enum ActivateOptions {
    None = 0,
    DesignMode = 1,
    NoErrorUI = 2,
    NoSplashScreen = 4
  }

  [ComImport]
  [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IApplicationActivationManager {
    int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      ActivateOptions options,
      out uint processId
    );

    int ActivateForFile(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      IntPtr itemArray,
      [MarshalAs(UnmanagedType.LPWStr)] string verb,
      out uint processId
    );

    int ActivateForProtocol(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      IntPtr itemArray,
      out uint processId
    );
  }

  [ComImport]
  [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  public class ApplicationActivationManager {
  }

  public static class PackagedApp {
    public static int Activate(string appUserModelId, string arguments, out uint processId) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      return manager.ActivateApplication(appUserModelId, arguments, ActivateOptions.None, out processId);
    }
  }
}
"@
  }

  $argumentString = ($Arguments | ForEach-Object { [string]$_ }) -join " "
  $activatedProcessId = [uint32]0
  $hr = [CodexMini.PackagedApp]::Activate($Aumid, $argumentString, [ref]$activatedProcessId)
  if ($hr -ne 0) {
    throw ("ActivateApplication failed for {0}, HRESULT 0x{1:X8}" -f $Aumid, ($hr -band 0xffffffff))
  }
  Write-Host "Activated packaged ChatGPT Codex app: $Aumid pid=$activatedProcessId"
}

function Start-CodexDesktop {
  param(
    [string]$ExecutablePath,
    [string[]]$Arguments
  )

  $normalized = ([string]$ExecutablePath) -replace '/', '\'
  if ($normalized -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(?:ChatGPT|Codex)\.exe$') {
    # WindowsApps 版 ChatGPT（Codex） 通过 AUMID 激活时，如果普通 Codex 已经运行，
    # remote-debugging 参数会被现有实例吞掉，结果只激活普通窗口而不开 39252。
    # 路径可执行时优先直接 Start-Process，只有权限不允许时再退回 AUMID。
    if (Test-Path -LiteralPath $ExecutablePath -PathType Leaf) {
      try {
        Start-Process -FilePath $ExecutablePath -ArgumentList $Arguments -WindowStyle Normal
        Write-Host "Started packaged ChatGPT Codex executable directly with launch arguments"
        return
      } catch {
        Write-Host "Direct WindowsApps launch failed, falling back to AUMID: $($_.Exception.Message)"
      }
    }
    $aumid = Get-CodexAumid
    Start-CodexPackagedApp -Aumid $aumid -Arguments $Arguments
    return
  }

  Start-Process -FilePath $ExecutablePath -ArgumentList $Arguments -WindowStyle Normal
}

function Get-CodexProcessCommandLines {
  try {
    return @(Get-CodexDesktopProcessInfo |
      Where-Object {
        $cmd = [string]$_.CommandLine
        $cmd -and ($cmd -notmatch '\s--type=')
      } |
      Select-Object -ExpandProperty CommandLine |
      Where-Object { $_ })
  } catch {
    return @()
  }
}

function Stop-StaleCodexCdpProcesses {
  param(
    [int]$Port,
    [string]$ProfileDir
  )

  $normalizedProfile = ([string]$ProfileDir) -replace '/', '\'
  try {
    $targets = @(Get-CodexDesktopProcessInfo |
      Where-Object {
        $command = [string]$_.CommandLine
        if (-not $command) { return $false }
        if ($command -match "--remote-debugging-port=$Port") { return $true }
        if ($normalizedProfile -and (($command -replace '/', '\').Contains($normalizedProfile))) { return $true }
        return $false
      })
    $mainTargets = @($targets | Where-Object {
      $command = [string]$_.CommandLine
      $command -and $command -notmatch '\s--type='
    })
    if ($mainTargets.Count -eq 0) { $mainTargets = $targets }
    foreach ($target in $mainTargets) {
      & taskkill.exe /PID $target.ProcessId /T /F > $null 2> $null
      if ($LASTEXITCODE -ne 0) {
        Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
    if ($targets.Count -gt 0) {
      Write-Host "Stopped stale ChatGPT Codex CDP processes: $($targets.Count)"
      Start-Sleep -Milliseconds 1500
    }
  } catch {
  }
}

function Stop-CodexDesktopProcesses {
  try {
    $targets = @(Get-CodexDesktopProcessInfo)
    $mainTargets = @($targets | Where-Object {
      $command = [string]$_.CommandLine
      $command -and $command -notmatch '\s--type='
    })
    if ($mainTargets.Count -eq 0) { $mainTargets = $targets }
    foreach ($target in $mainTargets) {
      & taskkill.exe /PID $target.ProcessId /T /F > $null 2> $null
      if ($LASTEXITCODE -ne 0) {
        Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
      }
    }
    if ($targets.Count -gt 0) {
      Write-Host "Closed existing ChatGPT Codex windows before starting controlled GPT: $($targets.Count)"
      Start-Sleep -Milliseconds 1800
    }
  } catch {
  }
}

$codexPath = Find-CodexExe -Explicit $CodexExe
Write-Host "CDP: http://127.0.0.1:$CdpPort/json/list"

if (-not $OpenAfterPrepare) {
  if ($codexPath) {
    Write-Host "Prepared Windows ChatGPT Codex CDP launcher"
    Write-Host "Executable: $codexPath"
    $aumid = Get-CodexAumid
    if ($aumid) { Write-Host "Appx AUMID: $aumid" }
  } else {
    Write-Host "Prepared Windows ChatGPT Codex CDP launcher, but ChatGPT.exe/Codex.exe was not found"
    Write-Host "Pass -CodexExe or set CODEX_DESKTOP_EXECUTABLE_PATH before opening"
  }
  exit 0
}

$defaultCdpProfileDir = if ($UserDataDir) { [string]$UserDataDir } else { Join-Path $ProjectRoot ".runtime\codex-cdp-profile" }
if (-not $ImmediateFreshLaunch -and (Test-CodexCdpPageReady -Port $CdpPort)) {
  Write-Host "ChatGPT Codex CDP target already ready"
  if (-not (Test-CodexCdpWindowVisible -Port $CdpPort)) {
    Write-Host "Window handle is temporarily unavailable; keeping the healthy CDP target"
  }
  exit 0
}

$runningCommands = if ($ImmediateFreshLaunch) { @() } else { Get-CodexProcessCommandLines }
$launchUserDataDir = [string]$UserDataDir
if ($runningCommands.Count -gt 0) {
  $hasNonCdpDesktop = $runningCommands | Where-Object { $_ -notmatch "--remote-debugging-port=$CdpPort" }
  if ($hasNonCdpDesktop) {
    if ($ForceRestart) {
      Stop-CodexDesktopProcesses
      $runningCommands = @()
      $hasNonCdpDesktop = @()
    }
  }
}

if ($runningCommands.Count -gt 0) {
  $hasNonCdpDesktop = $runningCommands | Where-Object { $_ -notmatch "--remote-debugging-port=$CdpPort" }
  if ($hasNonCdpDesktop) {
    if (-not $AllowIsolatedProfile) {
      [Console]::Error.WriteLine("ChatGPT is already running without CDP. Quit ChatGPT completely, then rerun this script.")
      exit 3
    }
    if (-not $launchUserDataDir) {
      $launchUserDataDir = if ($env:CODEX_MINI_WINDOWS_CDP_PROFILE_DIR) {
        $env:CODEX_MINI_WINDOWS_CDP_PROFILE_DIR
      } else {
        Join-Path $ProjectRoot ".runtime\codex-cdp-profile"
      }
    }
    New-Item -ItemType Directory -Force -Path $launchUserDataDir | Out-Null
    Write-Host "ChatGPT is already running without CDP; opening an isolated CDP profile."
    Write-Host "CDP profile: $launchUserDataDir"
  }
}

if (-not $codexPath) {
  [Console]::Error.WriteLine("ChatGPT.exe/Codex.exe was not found. Pass -CodexExe or set CODEX_DESKTOP_EXECUTABLE_PATH.")
  exit 1
}

$arguments = @(
  "--remote-debugging-address=$CdpAddress",
  "--remote-debugging-port=$CdpPort",
  "--remote-allow-origins=http://$CdpAddress`:$CdpPort",
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--disable-backgrounding-occluded-windows",
  "--disable-features=CalculateNativeWinOcclusion,IntensiveWakeUpThrottling",
  "--window-size=980,650"
)

if ($launchUserDataDir) {
  Stop-StaleCodexCdpProcesses -Port $CdpPort -ProfileDir $launchUserDataDir
  $arguments = @("--user-data-dir=`"$launchUserDataDir`"") + $arguments
}

Start-CodexDesktop -ExecutablePath $codexPath -Arguments $arguments

if ($NoWaitForReady) {
  Write-Host "Controlled GPT is opening; it will connect after ChatGPT finishes loading"
  exit 0
}

$deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
$lastPhase = ""
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 750
  if (Test-CodexCdpReady -Port $CdpPort) {
    Write-Host "Opened ChatGPT with Codex CDP and verified target ready"
    exit 0
  }
  $phase = if (Test-LoopbackPortOpen -Port $CdpPort -TimeoutMs 120) { "port" } elseif (@(Get-Process -Name "ChatGPT","Codex" -ErrorAction SilentlyContinue).Count -gt 0) { "process" } else { "launch" }
  if ($phase -ne $lastPhase) {
    $lastPhase = $phase
    if ($phase -eq "port") {
      Write-Host "ChatGPT debug port is listening; waiting for the main page target"
    } elseif ($phase -eq "process") {
      Write-Host "ChatGPT process is running; waiting for debug port $CdpPort"
    } else {
      Write-Host "Waiting for the ChatGPT process to appear"
    }
  }
}

[Console]::Error.WriteLine("ChatGPT was launched, but Codex CDP did not become ready within $ReadyTimeoutSeconds seconds")
exit 2
