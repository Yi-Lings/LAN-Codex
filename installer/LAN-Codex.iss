#ifndef MyAppVersion
  #define MyAppVersion "1.0.1"
#endif
#ifndef SourceRoot
  #define SourceRoot "..\.runtime\release-stage\LAN Codex"
#endif

#define MyAppName "LAN Codex"
#define MyAppPublisher "翎羽"
#define MyAppExeName "LAN Codex.exe"

[Setup]
AppId={{A79334F2-DF7A-4A58-BDDD-429A4B2E7D21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/Yi-Lings/LAN-Codex
AppSupportURL=https://github.com/Yi-Lings/LAN-Codex/issues
AppUpdatesURL=https://github.com/Yi-Lings/LAN-Codex/releases
DefaultDirName={autopf}\LAN Codex
DefaultGroupName=LAN Codex
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=LAN-Codex-Setup-{#MyAppVersion}
SetupIconFile=..\assets\windows\LAN-Codex.ico
UninstallDisplayName=LAN Codex
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile=..\LICENSE
InfoBeforeFile=..\NOTICE.md
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=LAN Codex Setup
VersionInfoProductName=LAN Codex
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式:"; Flags: unchecked

[Files]
Source: "{#SourceRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\LAN Codex\LAN Codex"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autoprograms}\LAN Codex\Uninstall LAN Codex"; Filename: "{uninstallexe}"
Name: "{autodesktop}\LAN Codex"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\windows-installer-lifecycle.ps1"" -Stop -StateDir ""{localappdata}\LAN Codex"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LAN Codex"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""LAN Codex"" dir=in action=allow program=""{app}\.runtime\node\node.exe"" protocol=TCP localport=8787 profile=private enable=yes"; Flags: runhidden waituntilterminated
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\windows-wpf-control-panel.ps1"" -Start"; Flags: runhidden waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "启动 LAN Codex"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\windows-installer-lifecycle.ps1"" -Stop -StateDir ""{localappdata}\LAN Codex"""; Flags: runhidden waituntilterminated; RunOnceId: "StopLanCodex"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""LAN Codex"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveLanCodexFirewallRule"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\LAN Codex"
