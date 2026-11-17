# Inbox PowerShell bootstrap. Removal never downloads or installs prerequisites.
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ExpectedSignerThumbprint,
    [switch]$ConfirmRemoval,
    [switch]$RemoveTestCertificate,
    [switch]$KeepTestCertificate,
    [switch]$DisableTestSigning,
    [switch]$KeepTestSigning,
    [switch]$AcknowledgeBootConfigurationChange,
    [switch]$AcknowledgeBitLockerRecoveryRisk,
    [switch]$AcknowledgeOtherTestDrivers,
    [switch]$ForcePackageRemoval,
    [switch]$NonInteractive,
    [switch]$Plan,
    [switch]$Pause
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
. (Join-Path $PSScriptRoot 'Setup-Dependencies.ps1')
$resultCode = 1
try {
    Assert-WinAirPlaySetupPlatform
    if (($DisableTestSigning -and $KeepTestSigning) -or ($RemoveTestCertificate -and $KeepTestCertificate)) {
        throw 'Choose one of DisableTestSigning/KeepTestSigning and one of RemoveTestCertificate/KeepTestCertificate.'
    }
    if ($ExpectedSignerThumbprint -and $ExpectedSignerThumbprint -cnotmatch '^[0-9A-Fa-f]{40}$') {
        throw 'Expected signer thumbprint must contain exactly 40 hexadecimal characters.'
    }
    if ($Plan -or $WhatIfPreference) {
        Write-Host 'Plan: request elevation and removal consent; verify product ownership; remove and verify service, firewall rule, devices, Driver Store packages, runtime, configuration, credentials, logs and installer/tool caches.'
        Write-Host 'After successful removal: optionally remove dedicated public test-certificate trust, then optionally disable TESTSIGNING with explicit recovery/other-driver acknowledgements. Restart manually if requested (exit 3010).'
        Get-WinAirPlaySetupBootState | Format-List | Out-Host
        Write-Host 'No removal, downloads, certificate or boot-policy changes performed. Shared runtimes and private signing keys are retained.'
        $resultCode = 0
    } else {
        $status = Get-WinAirPlaySetupDependencyStatus -PowerShellOnly
        if (-not $status.PowerShellInstalled) {
            throw 'Uninstall requires the supported native x64 PowerShell 7 runtime. Restore it using the verified Microsoft prerequisite described in installer/README.md, then rerun. Uninstall never downloads or installs prerequisites.'
        }
        $forward = @{
            ConfirmRemoval = [bool]$ConfirmRemoval
            RemoveTestCertificate = [bool]$RemoveTestCertificate
            KeepTestCertificate = [bool]$KeepTestCertificate
            DisableTestSigning = [bool]$DisableTestSigning
            KeepTestSigning = [bool]$KeepTestSigning
            AcknowledgeBootConfigurationChange = [bool]$AcknowledgeBootConfigurationChange
            AcknowledgeBitLockerRecoveryRisk = [bool]$AcknowledgeBitLockerRecoveryRisk
            AcknowledgeOtherTestDrivers = [bool]$AcknowledgeOtherTestDrivers
            ForcePackageRemoval = [bool]$ForcePackageRemoval
            NonInteractive = [bool]$NonInteractive
        }
        if ($ExpectedSignerThumbprint) { $forward.ExpectedSignerThumbprint = $ExpectedSignerThumbprint }
        if (-not (Test-WinAirPlaySetupAdministrator)) {
            $forward.Pause = [bool]$Pause
            $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
            $resultCode = Invoke-WinAirPlaySetupHost $windowsPowerShell $PSCommandPath $forward -Elevate
            $Pause = $false
        } else {
            $resultCode = Invoke-WinAirPlaySetupHost $status.PowerShellPath (Join-Path $PSScriptRoot 'Uninstall.ps1') $forward
        }
    }
} catch {
    [Console]::Error.WriteLine("WinAirPlayAudio uninstall failed: $($_.Exception.Message)")
    $resultCode = 1
} finally {
    if ($Pause -and -not $NonInteractive) { $null = Read-Host 'Press Enter to close uninstall' }
}
exit $resultCode
