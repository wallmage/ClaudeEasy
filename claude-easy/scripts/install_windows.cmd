@echo off
if not exist "%~dp0install_windows.ps1" goto incomplete_package
if exist "%~dp0install_windows.ps1\NUL" goto incomplete_package
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
exit /b %ERRORLEVEL%

:incomplete_package
set "CLAUDE_EASY_WRAPPER_JSON=0"
:scan_incomplete_package_arguments
if "%~1"=="" goto emit_incomplete_package
if /I "%~1"=="-Json" set "CLAUDE_EASY_WRAPPER_JSON=1"
shift
goto scan_incomplete_package_arguments

:emit_incomplete_package
if "%CLAUDE_EASY_WRAPPER_JSON%"=="1" (
  echo {"schema":"claude-easy.result","version":1,"command":"install","platform":"windows","client":"clash-verge-rev","operation":"install","ok":false,"status":"failed","code":"incomplete_package","exit_code":6,"summary_zh":"\u5b89\u88c5\u5305\u4e0d\u5b8c\u6574\u3002","profile":null,"changes":[],"checks":[],"items":[],"messages":[],"warnings":[]}
) else (
  1>&2 echo [ClaudeEasy] 安装包不完整。
)
exit /b 6
