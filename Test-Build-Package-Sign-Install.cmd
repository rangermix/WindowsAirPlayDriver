@echo off
setlocal

where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh.exe^) is required.
    echo Install PowerShell 7, open a new terminal, and run this launcher again.
    pause
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Invoke-TestBuildPackageSignInstall.ps1" -Pause %*
set "PIPELINE_EXIT_CODE=%ERRORLEVEL%"

if not "%PIPELINE_EXIT_CODE%"=="0" (
    echo.
    echo WinAirPlayAudio test deployment failed with exit code %PIPELINE_EXIT_CODE%.
)

exit /b %PIPELINE_EXIT_CODE%
