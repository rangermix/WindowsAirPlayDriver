# This entry point runs with inbox Windows PowerShell; it bootstraps PowerShell 7.
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ExpectedSignedManifestSha256,
    [string]$ExpectedSignerThumbprint,
    [switch]$Plan,
    [switch]$InstallDependencies,
    [string]$PrerequisiteDirectory,
    [switch]$EnableTestSigning,
    [switch]$AcknowledgeBootConfigurationChange,
    [switch]$AcknowledgeBitLockerRecoveryRisk,
    [switch]$TrustTestCertificate,
    [switch]$AcceptCleanReinstall,
    [switch]$NonInteractive,
    [switch]$Pause
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
. (Join-Path $PSScriptRoot 'Setup-Dependencies.ps1')
$resultCode = 1
$scratch = $null
$mutex = $null
$locked = $false
try {
    Assert-WinAirPlaySetupPlatform
    $bundle = Split-Path $PSScriptRoot -Parent
    $status = Get-WinAirPlaySetupDependencyStatus
    if ($Plan -or $WhatIfPreference) {
        if ($ExpectedSignedManifestSha256 -or $ExpectedSignerThumbprint) {
            $null = Assert-WinAirPlaySetupInputs $bundle $ExpectedSignedManifestSha256 $ExpectedSignerThumbprint
            Write-Host 'Package hashes and public certificate match the supplied trust anchors.'
        } else { Write-Host 'Package identity NOT VERIFIED: supply the release manifest SHA-256 and signer thumbprint.' }
        $status | Format-List | Out-Host
        Get-WinAirPlaySetupBootState | Format-List | Out-Host
        Write-Host 'Plan: verify package; install missing Microsoft runtimes; explicitly enable TESTSIGNING if needed; stop for manual reboot; rerun, trust the pinned public certificate, clean reinstall and verify service/driver/firewall.'
        Write-Host 'No dependencies, certificates, boot settings or product files were changed.'
        $resultCode = 0
    } else {
        if (-not $ExpectedSignedManifestSha256 -and -not $NonInteractive) {
            $ExpectedSignedManifestSha256 = Read-Host 'Signed package manifest SHA-256 from the trusted release'
        }
        if (-not $ExpectedSignerThumbprint -and -not $NonInteractive) {
            $ExpectedSignerThumbprint = Read-Host 'Public test-certificate thumbprint from the trusted release'
        }
        $null = Assert-WinAirPlaySetupInputs $bundle $ExpectedSignedManifestSha256 $ExpectedSignerThumbprint
        $forward = @{
            ExpectedSignedManifestSha256 = $ExpectedSignedManifestSha256
            ExpectedSignerThumbprint = $ExpectedSignerThumbprint
            EnableTestSigning = [bool]$EnableTestSigning
            AcknowledgeBootConfigurationChange = [bool]$AcknowledgeBootConfigurationChange
            AcknowledgeBitLockerRecoveryRisk = [bool]$AcknowledgeBitLockerRecoveryRisk
            TrustTestCertificate = [bool]$TrustTestCertificate
            AcceptCleanReinstall = [bool]$AcceptCleanReinstall
            NonInteractive = [bool]$NonInteractive
        }
        if (-not (Test-WinAirPlaySetupAdministrator)) {
            $elevated = $forward.Clone()
            $elevated.InstallDependencies = [bool]$InstallDependencies
            $elevated.Pause = [bool]$Pause
            if ($PrerequisiteDirectory) { $elevated.PrerequisiteDirectory = (Resolve-Path -LiteralPath $PrerequisiteDirectory).Path }
            $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
            $resultCode = Invoke-WinAirPlaySetupHost $windowsPowerShell $PSCommandPath $elevated -Elevate
            # Only the elevated console pauses; the parent must propagate its exit.
            $Pause = $false
        } else {
            $needsDependencies = -not $status.PowerShellInstalled -or -not $status.VcRuntimeInstalled
            $dependencyReboot = $false
            if ($needsDependencies) {
                Confirm-WinAirPlaySetupAction ([bool]$InstallDependencies) ([bool]$NonInteractive) 'Install or update the missing Microsoft PowerShell 7 LTS and x64 VC++ runtimes?'
                $mutex = New-Object Threading.Mutex($false, 'Global\WinAirPlayAudio.Setup')
                try { $locked = $mutex.WaitOne(0) }
                catch [Threading.AbandonedMutexException] { $locked = $true }
                if (-not $locked) { throw 'Another WinAirPlayAudio setup is running.' }
                $scratch = New-WinAirPlaySetupScratch
                $dependencies = Install-WinAirPlaySetupDependencies -DownloadDirectory $scratch -PrerequisiteDirectory $PrerequisiteDirectory
                $dependencyReboot = [bool]$dependencies.RebootRequired
                $status = Get-WinAirPlaySetupDependencyStatus
                Remove-WinAirPlaySetupScratch $scratch
                $scratch = $null
                $mutex.ReleaseMutex()
                $mutex.Dispose()
                $mutex = $null
            }
            if ($dependencyReboot) {
                Write-Warning 'A runtime installer requires a restart. Restart Windows manually, then rerun the same Setup.cmd command. Driver installation has not started.'
                $resultCode = 3010
            } else {
                if (-not $status.PowerShellInstalled -or -not $status.VcRuntimeInstalled) {
                    throw 'Required runtimes are still missing after dependency provisioning.'
                }
                $resultCode = Invoke-WinAirPlaySetupHost $status.PowerShellPath (Join-Path $PSScriptRoot 'Setup.ps1') $forward
            }
        }
    }
} catch {
    [Console]::Error.WriteLine("WinAirPlayAudio setup failed: $($_.Exception.Message)")
    $resultCode = 1
} finally {
    try {
        if ($scratch) { Remove-WinAirPlaySetupScratch $scratch }
    } catch {
        [Console]::Error.WriteLine("Setup scratch cleanup failed: $($_.Exception.Message)")
        $resultCode = 1
    }
    if ($mutex) {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    if ($Pause -and -not $NonInteractive) { $null = Read-Host 'Press Enter to close setup' }
}
exit $resultCode
