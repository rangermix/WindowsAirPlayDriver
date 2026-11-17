[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [switch]$ConfirmRemoval,

    [switch]$ForcePackageRemoval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfirmRemoval) {
    throw 'Uninstall requires the explicit -ConfirmRemoval switch.'
}

Assert-WinAirPlayTarget
Assert-WinAirPlayAdministrator -WhatIfOnly:$WhatIfPreference

if (-not $PSCmdlet.ShouldProcess(
        $env:COMPUTERNAME,
        'Permanently remove the WinAirPlayAudio service, scoped Windows Firewall rule, devnodes, Driver Store packages, runtime, configuration, credentials, logs, and installer/tool snapshots')) {
    return
}

$installerMutex = Enter-WinAirPlayInstallerMutex
try {
    if (-not (Test-WinAirPlayInstallationPresent) -and
        -not (Test-Path -LiteralPath $script:WinAirPlaySigningToolRoot)) {
        Write-Host 'WinAirPlayAudio is already fully removed.'
        return
    }

    Remove-WinAirPlayInstallation `
        -ForcePackageRemoval:$ForcePackageRemoval `
        -RemoveToolCaches

    Write-Host 'WinAirPlayAudio service, scoped Windows Firewall rule, files, configuration, logs, devices, and driver packages are removed.'
    Write-Host 'A reboot is only required if PnPUtil reports one.'
}
catch {
    Write-Warning 'Uninstall did not reach a verified clean state. The user service is intentionally not restarted.'
    throw
}
finally {
    Exit-WinAirPlayInstallerMutex -Mutex $installerMutex
}
