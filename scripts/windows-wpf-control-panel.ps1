param(
  [int]$Port = 8787,
  [switch]$Start,
  [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$StateDir = Join-Path $env:LOCALAPPDATA "LAN Codex"
$ConfigPath = Join-Path $StateDir "config.json"
$GuardScript = Join-Path $ProjectRoot "scripts\lan-only-guard.js"
$ServerScript = Join-Path $ProjectRoot "server.js"
$CdpScript = Join-Path $ProjectRoot "scripts\launch-main-codex-cdp.ps1"
$QrScript = Join-Path $ProjectRoot "scripts\make-qr.js"
$StdoutLog = Join-Path $StateDir "server.out.log"
$StderrLog = Join-Path $StateDir "server.err.log"
$ServerStateDir = Join-Path $env:USERPROFILE ".codex-mini"

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function New-MobileToken {
  $bytes = New-Object byte[] 24
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-Config {
  try {
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
      $value = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
      if ($value.token) {
        return [ordered]@{
          token = [string]$value.token
          port = if ($value.port) { [int]$value.port } else { $Port }
          serverPid = if ($value.serverPid) { [int]$value.serverPid } else { 0 }
        }
      }
    }
  } catch {}
  return [ordered]@{ token = New-MobileToken; port = $Port; serverPid = 0 }
}

function Save-Config {
  $script:Config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Test-NodeExe {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try { return [string](& $Path --version 2>$null) -match '^v(2[0-9]|[3-9][0-9])\.' } catch { return $false }
}

function Get-NodeExe {
  $pathNode = Get-Command node -ErrorAction SilentlyContinue
  if ($pathNode -and (Test-NodeExe $pathNode.Source)) { return $pathNode.Source }
  foreach ($candidate in @(
    (Join-Path $ProjectRoot ".runtime\node\node.exe"),
    (Join-Path $ProjectRoot "bin\node\node.exe")
  )) {
    if (Test-NodeExe $candidate) { return $candidate }
  }
  throw "未找到 Node.js 20 或更高版本。请先安装 Node.js。"
}

function Test-PrivateIPv4 {
  param([string]$Address)
  $parts = @($Address -split '\.')
  if ($parts.Count -ne 4) { return $false }
  try { $numbers = @($parts | ForEach-Object { [int]$_ }) } catch { return $false }
  return $numbers[0] -eq 10 -or
    ($numbers[0] -eq 172 -and $numbers[1] -ge 16 -and $numbers[1] -le 31) -or
    ($numbers[0] -eq 192 -and $numbers[1] -eq 168)
}

function Get-LanAddress {
  try {
    $address = Get-NetIPConfiguration -ErrorAction Stop |
      Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -and $_.IPv4Address } |
      ForEach-Object { $_.IPv4Address.IPAddress } |
      Where-Object { Test-PrivateIPv4 $_ } |
      Select-Object -First 1
    if ($address) { return [string]$address }
  } catch {}

  try {
    $address = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
      Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and (Test-PrivateIPv4 $_.IPAddressToString) } |
      Select-Object -First 1
    if ($address) { return [string]($address.IPAddressToString) }
  } catch {}
  return "127.0.0.1"
}

function Get-LanUrl {
  $token = [Uri]::EscapeDataString([string]$script:Config.token)
  return "http://$(Get-LanAddress):$($script:Config.port)/?token=$token"
}

function Get-LoopbackUrl {
  $token = [Uri]::EscapeDataString([string]$script:Config.token)
  return "http://127.0.0.1:$($script:Config.port)/?token=$token"
}

function Test-TcpPort {
  param([int]$TargetPort, [int]$TimeoutMs = 250)
  $client = New-Object Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync("127.0.0.1", $TargetPort)
    return $task.Wait($TimeoutMs) -and $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Test-ServerHealth {
  try {
    $token = [Uri]::EscapeDataString([string]$script:Config.token)
    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:Config.port)/codex/health?token=$token" -TimeoutSec 1
    return [bool]$result.ok
  } catch {
    return $false
  }
}

function Test-CdpReady {
  if (-not (Test-TcpPort -TargetPort 39252 -TimeoutMs 120)) { return $false }
  try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:39252/json/list" -TimeoutSec 1
    return [bool](@($targets) | Where-Object {
      $_.type -eq 'page' -and $_.webSocketDebuggerUrl -and [string]$_.url -like 'app://-/index.html*'
    } | Select-Object -First 1)
  } catch {
    return $false
  }
}

function Get-OwnedServerProcess {
  if (-not $script:Config.serverPid) { return $null }
  try {
    $item = Get-CimInstance Win32_Process -Filter "ProcessId = $($script:Config.serverPid)"
    if (-not $item) { return $null }
    $command = [string]$item.CommandLine
    if ($command -and $command.IndexOf($ServerScript, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $item }
  } catch {}
  return $null
}

function Set-ChildEnvironment {
  param([hashtable]$Values)
  $saved = @{}
  foreach ($name in $Values.Keys) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, [string]$Values[$name], 'Process')
  }
  return $saved
}

function Restore-ChildEnvironment {
  param([hashtable]$Values)
  foreach ($name in $Values.Keys) {
    [Environment]::SetEnvironmentVariable($name, $Values[$name], 'Process')
  }
}

function Protect-ServerLogs {
  foreach ($path in @($StdoutLog, $StderrLog)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
      $text = Get-Content -Raw -LiteralPath $path
      if ($text -and $script:Config.token) {
        $safe = $text.Replace([string]$script:Config.token, '[REDACTED]')
        if ($safe -ne $text) { Set-Content -LiteralPath $path -Value $safe -Encoding UTF8 }
      }
    } catch {}
  }
}

function Start-LanServer {
  if (Test-ServerHealth) { return }
  if (Test-TcpPort -TargetPort $script:Config.port) {
    throw "端口 $($script:Config.port) 已被其他程序占用。请关闭占用程序或使用其他端口启动面板。"
  }
  if (-not (Test-Path -LiteralPath $GuardScript -PathType Leaf)) { throw "缺少 LAN 网络守卫。" }
  if (-not (Test-Path -LiteralPath $ServerScript -PathType Leaf)) { throw "缺少本地服务。" }
  New-Item -ItemType Directory -Path $ServerStateDir -Force | Out-Null

  $node = Get-NodeExe
  $environment = @{
    PORT = [string]$script:Config.port
    HOST = '0.0.0.0'
    MOBILE_TYPER_TOKEN = [string]$script:Config.token
    CODEX_MINI_APP_NAME = 'LAN Codex'
    CODEX_MINI_LOCAL_ONLY = '1'
    CODEX_MINI_DISABLE_A1_TUNNEL = '1'
    CODEX_MINI_DISABLE_IMESSAGE_NOTIFY = '1'
    CODEX_MINI_CDP_PORT = '39252'
    NO_PROXY = 'localhost,127.0.0.1,::1'
  }
  $saved = Set-ChildEnvironment -Values $environment
  try {
    $arguments = "--require `"$GuardScript`" `"$ServerScript`""
    $process = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $ProjectRoot `
      -WindowStyle Hidden -PassThru -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog
  } finally {
    Restore-ChildEnvironment -Values $saved
  }

  $script:Config.serverPid = [int]$process.Id
  Save-Config
  for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
    Start-Sleep -Milliseconds 200
    if (Test-ServerHealth) { Protect-ServerLogs; return }
    if ($process.HasExited) { break }
  }
  Protect-ServerLogs
  $detail = if (Test-Path -LiteralPath $StderrLog) { (Get-Content -LiteralPath $StderrLog -Tail 8) -join "`n" } else { "" }
  $script:Config.serverPid = 0
  Save-Config
  throw "局域网服务启动失败。$([Environment]::NewLine)$detail"
}

function Stop-LanServer {
  $process = Get-OwnedServerProcess
  if ($process) { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop }
  $script:Config.serverPid = 0
  Save-Config
}

function Start-ControlledCodex {
  $answer = [Windows.MessageBox]::Show(
    $window,
    "启动受控 GPT 需要关闭当前 ChatGPT/Codex 窗口并重新打开。未发送的输入可能丢失。是否继续？",
    "LAN Codex",
    [Windows.MessageBoxButton]::YesNo,
    [Windows.MessageBoxImage]::Warning
  )
  if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }

  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$CdpScript`"",
    '-CdpPort', '39252', '-OpenAfterPrepare', '-ForceRestart'
  )
  Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden | Out-Null
  $controls.Notice.Text = "正在重新打开受控 GPT，状态会自动更新"
}

function Show-QrCode {
  if (-not (Test-ServerHealth)) { throw "请先启动局域网服务。" }
  $node = Get-NodeExe
  $output = Join-Path $StateDir "lan-codex-entry.gif"
  & $node $QrScript (Get-LanUrl) $output 7 M | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw "二维码生成失败。" }

  $image = New-Object Windows.Controls.Image
  $bitmap = New-Object Windows.Media.Imaging.BitmapImage
  $bitmap.BeginInit()
  $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bitmap.UriSource = New-Object Uri($output)
  $bitmap.EndInit()
  $image.Source = $bitmap
  $image.Width = 300
  $image.Height = 300
  $image.Margin = 22

  $dialog = New-Object Windows.Window
  $dialog.Title = "扫描局域网入口"
  $dialog.Width = 360
  $dialog.Height = 400
  $dialog.ResizeMode = 'NoResize'
  $dialog.WindowStartupLocation = 'CenterOwner'
  $dialog.Owner = $window
  $dialog.Background = [Windows.Media.Brushes]::White
  $dialog.Content = $image
  [void]$dialog.ShowDialog()
}

function Run-UiAction {
  param([scriptblock]$Action)
  try {
    $window.IsEnabled = $false
    & $Action
  } catch {
    [Windows.MessageBox]::Show($window, $_.Exception.Message, "LAN Codex", 'OK', 'Error') | Out-Null
  } finally {
    $window.IsEnabled = $true
    Refresh-Status
  }
}

$script:Config = Read-Config
if ($Port -ne 8787) { $script:Config.port = $Port }
if (-not (Get-OwnedServerProcess)) { $script:Config.serverPid = 0 }
Save-Config

if ($Start) {
  Start-LanServer
  [ordered]@{
    serverReady = [bool](Test-ServerHealth)
    cdpReady = [bool](Test-CdpReady)
    port = [int]$script:Config.port
    url = [string](Get-LanUrl)
    serverPid = [int]$script:Config.serverPid
  } | ConvertTo-Json
  exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LAN Codex" Width="640" Height="535" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#F4F6F4" FontFamily="Segoe UI, Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Height" Value="40"/><Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="#137A55"/><Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Height" Value="40"/><Setter Property="Padding" Value="14,0"/>
      <Setter Property="Background" Value="#FFFFFF"/><Setter Property="Foreground" Value="#17201B"/>
      <Setter Property="BorderBrush" Value="#D8DDDA"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="116"/><RowDefinition Height="*"/><RowDefinition Height="48"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#17201B">
      <Grid Margin="28,20">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="LAN Codex" Foreground="White" FontSize="27" FontWeight="Bold"/>
          <TextBlock Text="Windows 局域网控制端" Foreground="#B8C4BD" FontSize="13" Margin="0,5,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Ellipse x:Name="ServerDot" Width="9" Height="9" Fill="#D9664A" Margin="0,0,8,0"/>
            <TextBlock x:Name="ServerStatus" Text="服务未启动" Foreground="#E8EEEA" FontSize="13"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Ellipse x:Name="CdpDot" Width="9" Height="9" Fill="#D9664A" Margin="0,0,8,0"/>
            <TextBlock x:Name="CdpStatus" Text="GPT 未受控" Foreground="#E8EEEA" FontSize="13"/>
          </StackPanel>
        </StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Row="1" Margin="28,24,28,18">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <TextBlock Text="手机局域网入口" Foreground="#17201B" FontSize="13" FontWeight="SemiBold"/>
      <TextBox x:Name="UrlBox" Grid.Row="1" Height="46" Margin="0,8,0,0" IsReadOnly="True"
               Padding="12,0" VerticalContentAlignment="Center" Background="White" Foreground="#25302A"
               BorderBrush="#D8DDDA" BorderThickness="1" FontFamily="Consolas" FontSize="12"/>
      <Grid Grid.Row="2" Margin="0,10,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Button x:Name="CopyButton" Grid.Column="0" Content="复制地址" Style="{StaticResource SecondaryButton}" Margin="0,0,6,0"/>
        <Button x:Name="QrButton" Grid.Column="1" Content="显示二维码" Style="{StaticResource SecondaryButton}" Margin="6,0"/>
        <Button x:Name="OpenButton" Grid.Column="2" Content="电脑打开" Style="{StaticResource SecondaryButton}" Margin="6,0,0,0"/>
      </Grid>
      <Grid Grid.Row="3" Margin="0,24,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Button x:Name="StartButton" Grid.Column="0" Content="启动局域网服务" Style="{StaticResource PrimaryButton}" Margin="0,0,6,0"/>
        <Button x:Name="StopButton" Grid.Column="1" Content="停止" Style="{StaticResource SecondaryButton}" Width="76" Margin="6,0"/>
        <Button x:Name="CdpButton" Grid.Column="2" Content="启动受控 GPT" Style="{StaticResource SecondaryButton}" Margin="6,0,0,0"/>
      </Grid>
      <TextBlock x:Name="Notice" Grid.Row="4" Text="仅允许同一局域网访问；Windows 防火墙请选择专用网络。"
                 Foreground="#68706B" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </Grid>
    <Border Grid.Row="2" BorderBrush="#D8DDDA" BorderThickness="0,1,0,0">
      <Grid Margin="28,0">
        <TextBlock Text="by 翎羽" Foreground="#68706B" FontSize="11" VerticalAlignment="Center"/>
        <TextBlock Text="LAN only" Foreground="#137A55" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$windowIcon = Join-Path $ProjectRoot "assets\windows\LAN-Codex.ico"
if (Test-Path -LiteralPath $windowIcon -PathType Leaf) {
  $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$windowIcon)
}
$controls = @{}
foreach ($name in @('ServerDot','ServerStatus','CdpDot','CdpStatus','UrlBox','CopyButton','QrButton','OpenButton','StartButton','StopButton','CdpButton','Notice')) {
  $controls[$name] = $window.FindName($name)
}

function Set-StatusDot {
  param($Dot, [bool]$Ready)
  $Dot.Fill = if ($Ready) { [Windows.Media.BrushConverter]::new().ConvertFromString('#24A36B') } else { [Windows.Media.BrushConverter]::new().ConvertFromString('#D9664A') }
}

function Refresh-Status {
  $serverReady = Test-ServerHealth
  $cdpReady = Test-CdpReady
  Set-StatusDot $controls.ServerDot $serverReady
  Set-StatusDot $controls.CdpDot $cdpReady
  $controls.ServerStatus.Text = if ($serverReady) { "服务运行中" } else { "服务未启动" }
  $controls.CdpStatus.Text = if ($cdpReady) { "GPT 已受控" } else { "GPT 未受控" }
  $controls.UrlBox.Text = Get-LanUrl
  $controls.StartButton.IsEnabled = -not $serverReady
  $controls.StopButton.IsEnabled = [bool](Get-OwnedServerProcess)
  $controls.CopyButton.IsEnabled = $serverReady
  $controls.QrButton.IsEnabled = $serverReady
  $controls.OpenButton.IsEnabled = $serverReady
}

$controls.StartButton.Add_Click({ Run-UiAction { Start-LanServer; $controls.Notice.Text = "局域网服务已启动，可在手机扫码连接" } })
$controls.StopButton.Add_Click({ Run-UiAction { Stop-LanServer; $controls.Notice.Text = "局域网服务已停止" } })
$controls.CdpButton.Add_Click({ Run-UiAction { Start-ControlledCodex } })
$controls.CopyButton.Add_Click({ [Windows.Clipboard]::SetText((Get-LanUrl)); $controls.Notice.Text = "局域网地址已复制" })
$controls.QrButton.Add_Click({ Run-UiAction { Show-QrCode } })
$controls.OpenButton.Add_Click({ Start-Process (Get-LoopbackUrl) | Out-Null })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2.5)
$timer.Add_Tick({ Refresh-Status })
$window.Add_ContentRendered({ Refresh-Status; $timer.Start() })
$window.Add_Closed({ $timer.Stop() })

if ($SmokeTest) {
  Refresh-Status
  [ordered]@{
    serverReady = [bool](Test-ServerHealth)
    cdpReady = [bool](Test-CdpReady)
    port = [int]$script:Config.port
    windowTitle = [string]$window.Title
  } | ConvertTo-Json
  exit 0
}

[void]$window.ShowDialog()
