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
    [switch]$Plan
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
. (Join-Path $PSScriptRoot 'Uninstall.Common.ps1')
$resultCode = 1
try {
    $arguments = @{} + $PSBoundParameters
    $null = $arguments.Remove('WhatIf')
    $null = $arguments.Remove('Confirm')
    $arguments.Plan = [bool]($Plan -or $WhatIfPreference)
    $resultCode = Invoke-WinAirPlayGuidedUninstall -ScriptDirectory $PSScriptRoot @arguments
} catch {
    [Console]::Error.WriteLine("WinAirPlayAudio uninstall failed: $($_.Exception.Message)")
}
exit $resultCode
