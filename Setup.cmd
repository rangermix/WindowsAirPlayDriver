@echo off
setlocal
set "SETUP_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "SETUP_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%SETUP_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Start-Setup.ps1" -Pause %*
set "SETUP_RESULT=%ERRORLEVEL%"
exit /b %SETUP_RESULT%
