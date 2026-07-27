@echo off
set "APP_ROOT=%~dp0"
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%APP_ROOT%scripts\windows-wpf-control-panel.ps1"
