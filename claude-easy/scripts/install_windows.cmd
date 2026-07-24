@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
exit /b %ERRORLEVEL%
