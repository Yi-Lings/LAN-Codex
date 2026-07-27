param(
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Package = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot "package.json") | ConvertFrom-Json
if (-not $Version) { $Version = [string]$Package.version }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must use semantic version format, for example 1.0.0." }

$DistDir = Join-Path $ProjectRoot "dist"
$RuntimeDir = Join-Path $ProjectRoot ".runtime"
$StageDir = Join-Path $RuntimeDir "release-stage\LAN Codex"
$SourceStageDir = Join-Path $RuntimeDir "source-stage\LAN-Codex-$Version"
$IconPath = Join-Path $ProjectRoot "assets\windows\LAN-Codex.ico"
$LauncherSource = Join-Path $ProjectRoot "windows\LanCodexLauncher.cs"
$NodeLicense = Join-Path $ProjectRoot "licenses\Node.js-LICENSE.txt"
$AndroidApk = Join-Path $ProjectRoot "lan_gpt_android.apk"

foreach ($path in @($DistDir, (Split-Path -Parent $StageDir), (Split-Path -Parent $SourceStageDir))) {
  $fullPath = [IO.Path]::GetFullPath($path)
  if (-not $fullPath.StartsWith([IO.Path]::GetFullPath($ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify path outside the project: $fullPath"
  }
}

foreach ($path in @($DistDir, $StageDir, $SourceStageDir)) {
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
  New-Item -ItemType Directory -Path $path -Force | Out-Null
}

foreach ($directory in @("public", "licenses", "docs", "assets")) {
  Copy-Item -LiteralPath (Join-Path $ProjectRoot $directory) -Destination (Join-Path $StageDir $directory) -Recurse
}
New-Item -ItemType Directory -Path (Join-Path $StageDir "scripts") -Force | Out-Null
foreach ($scriptName in @(
  "lan-only-guard.js",
  "launch-main-codex-cdp.ps1",
  "make-qr.js",
  "windows-installer-lifecycle.ps1",
  "windows-wpf-control-panel.ps1"
)) {
  Copy-Item -LiteralPath (Join-Path $ProjectRoot "scripts\$scriptName") -Destination (Join-Path $StageDir "scripts\$scriptName")
}
foreach ($fileName in @("LICENSE", "NOTICE.md", "README.md", "TECHNICAL_ROUTE.md", "package.json", "server.js")) {
  Copy-Item -LiteralPath (Join-Path $ProjectRoot $fileName) -Destination (Join-Path $StageDir $fileName)
}

$NodeCommand = Get-Command node -ErrorAction SilentlyContinue
if (-not $NodeCommand -or -not (Test-Path -LiteralPath $NodeCommand.Source -PathType Leaf)) { throw "Node.js 20 or newer is required to build the release." }
$NodeVersion = [string](& $NodeCommand.Source --version)
if ($NodeVersion -notmatch '^v(2[0-9]|[3-9][0-9])\.') { throw "Node.js 20 or newer is required to build the release." }
if (-not (Test-Path -LiteralPath $NodeLicense -PathType Leaf)) { throw "Missing Node.js license: $NodeLicense" }
$BundledNodeDir = Join-Path $StageDir ".runtime\node"
New-Item -ItemType Directory -Path $BundledNodeDir -Force | Out-Null
Copy-Item -LiteralPath $NodeCommand.Source -Destination (Join-Path $BundledNodeDir "node.exe")
Copy-Item -LiteralPath $NodeLicense -Destination (Join-Path $BundledNodeDir "LICENSE")

$Csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $Csc -PathType Leaf)) { throw "The .NET Framework C# compiler was not found." }
if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) { throw "Missing Windows icon: $IconPath" }
$LauncherPath = Join-Path $StageDir "LAN Codex.exe"
& $Csc /nologo /target:winexe /optimize+ "/win32icon:$IconPath" "/out:$LauncherPath" /reference:System.Windows.Forms.dll $LauncherSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) { throw "LAN Codex launcher compilation failed." }

$InnoCandidates = @(
  (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
  "C:\Program Files\Inno Setup 6\ISCC.exe"
)
$Iscc = $InnoCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $Iscc) { throw "Inno Setup 6 was not found." }
& $Iscc "/DMyAppVersion=$Version" "/DSourceRoot=$StageDir" (Join-Path $ProjectRoot "installer\LAN-Codex.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed." }

$PortablePath = Join-Path $DistDir "LAN-Codex-Portable-$Version.zip"
Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $PortablePath -CompressionLevel Optimal

$sourceFiles = @(& git -C $ProjectRoot ls-files --cached --others --exclude-standard)
if (-not $sourceFiles) { throw "No source files were found." }
foreach ($relativePath in $sourceFiles) {
  $sourcePath = Join-Path $ProjectRoot $relativePath
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
  $destinationPath = Join-Path $SourceStageDir $relativePath
  New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
  Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}
$SourceArchivePath = Join-Path $DistDir "LAN-Codex-Source-$Version.zip"
Compress-Archive -Path $SourceStageDir -DestinationPath $SourceArchivePath -CompressionLevel Optimal

$Artifacts = @(
  (Join-Path $DistDir "LAN-Codex-Setup-$Version.exe"),
  $PortablePath,
  $SourceArchivePath
)
if (Test-Path -LiteralPath $AndroidApk -PathType Leaf) {
  $ReleaseApk = Join-Path $DistDir "Lan-gpt.apk"
  Copy-Item -LiteralPath $AndroidApk -Destination $ReleaseApk
  $Artifacts += $ReleaseApk
}
foreach ($artifact in $Artifacts) {
  if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "Missing release artifact: $artifact" }
}
$ChecksumLines = foreach ($artifact in $Artifacts) {
  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $artifact
  "$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($artifact))"
}
$ChecksumLines | Set-Content -LiteralPath (Join-Path $DistDir "SHA256SUMS.txt") -Encoding ASCII

[ordered]@{
  version = $Version
  node = $NodeVersion
  setup = [IO.Path]::GetFileName($Artifacts[0])
  portable = [IO.Path]::GetFileName($PortablePath)
  source = [IO.Path]::GetFileName($SourceArchivePath)
} | ConvertTo-Json
