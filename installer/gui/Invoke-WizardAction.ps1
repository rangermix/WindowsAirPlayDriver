# Windows PowerShell 5.1 bridge for the compiled GUI; no interactive prompts.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Probe', 'Install', 'Uninstall')][string]$Action,
    [ValidateSet('Install', 'Uninstall')][string]$Mode = 'Install',
    [string]$BundleDirectory,
    [string]$ExpectedSignedManifestSha256,
    [string]$ExpectedSignerThumbprint,
    [switch]$InstallDependencies,
    [switch]$EnableTestSigning,
    [switch]$AcknowledgeBootConfigurationChange,
    [switch]$AcknowledgeBitLockerRecoveryRisk,
    [switch]$TrustTestCertificate,
    [switch]$AcceptCleanReinstall,
    [switch]$ConfirmRemoval,
    [switch]$RemoveTestCertificate,
    [switch]$DisableTestSigning,
    [switch]$AcknowledgeOtherTestDrivers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-WinAirPlayWizardStatus {
    param([Parameter(Mandatory)][string]$Message)
    # Console output is the GUI protocol. Keep it outside the success pipeline
    # so the orchestration function can return only its numeric exit code.
    [Console]::Out.WriteLine($Message.Replace("`r", ' ').Replace("`n", ' '))
}

function Invoke-WinAirPlayWizardAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerDirectory,
        [Parameter(Mandatory)][ValidateSet('Probe', 'Install', 'Uninstall')][string]$Action,
        [ValidateSet('Install', 'Uninstall')][string]$Mode = 'Install',
        [string]$BundleDirectory,
        [string]$ExpectedSignedManifestSha256,
        [string]$ExpectedSignerThumbprint,
        [switch]$InstallDependencies,
        [switch]$EnableTestSigning,
        [switch]$AcknowledgeBootConfigurationChange,
        [switch]$AcknowledgeBitLockerRecoveryRisk,
        [switch]$TrustTestCertificate,
        [switch]$AcceptCleanReinstall,
        [switch]$ConfirmRemoval,
        [switch]$RemoveTestCertificate,
        [switch]$DisableTestSigning,
        [switch]$AcknowledgeOtherTestDrivers
    )
    Assert-WinAirPlaySetupPlatform
    if (-not $BundleDirectory) { $BundleDirectory = Split-Path $InstallerDirectory -Parent }
    if ($BundleDirectory -notmatch '^[A-Za-z]:[\\/]') {
        throw 'The GUI bundle directory must be a fully qualified local drive path.'
    }
    $BundleDirectory = [IO.Path]::GetFullPath($BundleDirectory)
    if ($Action -ne 'Probe' -and $Action -cne $Mode) {
        throw 'The selected wizard mode does not match the requested action.'
    }
    if ($Action -ceq 'Probe') {
        Write-WinAirPlayWizardStatus 'PHASE|Checking Windows and required components'
        if ($Mode -ceq 'Install') {
            $null = Assert-WinAirPlaySetupInputs -BundleDirectory $BundleDirectory `
                -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 `
                -ExpectedSignerThumbprint $ExpectedSignerThumbprint
        }
        # Removal deliberately does not inspect package bytes or test DER.
        $dependencies = Get-WinAirPlaySetupDependencyStatus -PowerShellOnly:($Mode -ceq 'Uninstall')
        $boot = Get-WinAirPlaySetupBootState
        Write-WinAirPlayWizardStatus ('POWER_SHELL=' + [int][bool]$dependencies.PowerShellInstalled)
        Write-WinAirPlayWizardStatus ('VC_RUNTIME=' + [int][bool]$dependencies.VcRuntimeInstalled)
        Write-WinAirPlayWizardStatus ('TEST_MODE=' + [int][bool]$boot.TestSigningActive)
        $secureBoot = 'unknown'
        $secureBootCommand = Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        if ($secureBootCommand) {
            try { $secureBoot = [string][int][bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
            catch {
                Write-WinAirPlayWizardStatus "PHASE|Secure Boot status unavailable: $($_.Exception.Message)"
            }
        } else {
            Write-WinAirPlayWizardStatus 'PHASE|Secure Boot status cannot be queried by this Windows host'
        }
        Write-WinAirPlayWizardStatus ('SECURE_BOOT=' + $secureBoot)
        Write-WinAirPlayWizardStatus 'PHASE|Checks completed'
        return 0
    }
    if (-not (Test-WinAirPlaySetupAdministrator)) {
        throw 'The GUI must request administrator access before performing installation or removal.'
    }
    $backendDirectory = Join-Path $BundleDirectory 'installer'
    Assert-WinAirPlaySetupNoLinks -Path $backendDirectory
    if ($Action -ceq 'Install') {
        $backend = Join-Path $backendDirectory 'Start-Setup.ps1'
        $forward = @{
            ExpectedSignedManifestSha256 = $ExpectedSignedManifestSha256
            ExpectedSignerThumbprint = $ExpectedSignerThumbprint
            InstallDependencies = [bool]$InstallDependencies
            EnableTestSigning = [bool]$EnableTestSigning
            AcknowledgeBootConfigurationChange = [bool]$AcknowledgeBootConfigurationChange
            AcknowledgeBitLockerRecoveryRisk = [bool]$AcknowledgeBitLockerRecoveryRisk
            TrustTestCertificate = [bool]$TrustTestCertificate
            AcceptCleanReinstall = [bool]$AcceptCleanReinstall
            NonInteractive = $true
        }
    } else {
        $backend = Join-Path $backendDirectory 'Start-Uninstall.ps1'
        $forward = @{
            ConfirmRemoval = [bool]$ConfirmRemoval
            RemoveTestCertificate = [bool]$RemoveTestCertificate
            KeepTestCertificate = -not [bool]$RemoveTestCertificate
            DisableTestSigning = [bool]$DisableTestSigning
            KeepTestSigning = -not [bool]$DisableTestSigning
            AcknowledgeBootConfigurationChange = [bool]$AcknowledgeBootConfigurationChange
            AcknowledgeBitLockerRecoveryRisk = [bool]$AcknowledgeBitLockerRecoveryRisk
            AcknowledgeOtherTestDrivers = [bool]$AcknowledgeOtherTestDrivers
            NonInteractive = $true
        }
        if ($ExpectedSignerThumbprint) { $forward.ExpectedSignerThumbprint = $ExpectedSignerThumbprint }
    }
    Assert-WinAirPlaySetupNoLinks -Path $backend
    if (-not (Test-Path -LiteralPath $backend -PathType Leaf)) {
        throw "The GUI recovery payload is missing its $Action backend. Re-extract the verified wizard."
    }
    Write-WinAirPlayWizardStatus "PHASE|Starting verified $Action procedure"
    $global:LASTEXITCODE = 0
    & $backend @forward | ForEach-Object { [Console]::Out.WriteLine([string]$_) }
    $succeeded = $?
    $code = $global:LASTEXITCODE
    if (-not $succeeded -and $code -eq 0) { $code = 1 }
    if ($code -notin @(0, 1, 3010)) {
        throw "$Action backend returned an unexpected exit code: $code"
    }
    if ($code -eq 1) {
        Write-WinAirPlayWizardStatus "PHASE|$Action failed; review the error details"
        [Console]::Error.WriteLine("$Action did not complete successfully. The preceding backend error identifies the required recovery action.")
    } elseif ($code -eq 3010) {
        Write-WinAirPlayWizardStatus 'PHASE|A manual restart is required; save work, restart Windows and rerun setup if installation is pending'
    } else {
        Write-WinAirPlayWizardStatus "PHASE|$Action completed successfully"
    }
    return [int]$code
}

$resultCode = 1
try {
    $installerDirectory = Split-Path $PSScriptRoot -Parent
    . (Join-Path $installerDirectory 'Setup.Common.ps1')
    . (Join-Path $installerDirectory 'Setup-Dependencies.ps1')
    $arguments = @{} + $PSBoundParameters
    $resultCode = Invoke-WinAirPlayWizardAction -InstallerDirectory $installerDirectory @arguments
} catch {
    Write-WinAirPlayWizardStatus 'PHASE|The requested wizard action could not complete'
    [Console]::Error.WriteLine("WinAirPlayAudio wizard failed: $($_.Exception.Message)")
}
exit $resultCode
