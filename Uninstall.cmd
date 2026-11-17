@echo off
setlocal
set "UNINSTALL_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "UNINSTALL_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%UNINSTALL_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Start-Uninstall.ps1" -Pause %*
set "UNINSTALL_RESULT=%ERRORLEVEL%"
exit /b %UNINSTALL_RESULT%
