[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Enable', 'Disable')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [switch]$AcknowledgeBootConfigurationChange,

    [switch]$AcknowledgeBitLockerRecoveryRisk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $AcknowledgeBootConfigurationChange) {
    throw 'Changing TESTSIGNING requires -AcknowledgeBootConfigurationChange.'
}
if (-not $AcknowledgeBitLockerRecoveryRisk) {
    throw @'
Changing Windows boot policy can trigger BitLocker recovery even when the
BitLocker management cmdlet is unavailable. Confirm that the recovery key is
available and rerun with -AcknowledgeBitLockerRecoveryRisk.
'@
}

Assert-WinAirPlayTarget
Assert-WinAirPlayAdministrator -WhatIfOnly:$WhatIfPreference

if ($Mode -eq 'Enable' -and -not $WhatIfPreference) {
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) {
            throw @'
Secure Boot is enabled. Windows boot policy normally blocks TESTSIGNING
changes in this state. This script will not disable Secure Boot automatically.
Plan BitLocker recovery-key handling, then make the firmware change manually.
'@
        }
    }
    catch [PlatformNotSupportedException] {
        # Legacy firmware/non-UEFI machines do not expose this cmdlet.
    }
}

if (-not $WhatIfPreference) {
    $getBitLockerVolume = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if ($getBitLockerVolume) {
        $systemVolumePath = [IO.Path]::GetPathRoot(
            $script:WinAirPlayWindowsDirectory).TrimEnd('\')
        $systemVolume = Get-BitLockerVolume -MountPoint $systemVolumePath -ErrorAction Stop
        if ($systemVolume.ProtectionStatus -eq 'On') {
            Write-Warning @'
BitLocker protection is on for the system volume. The explicit recovery-risk
acknowledgement was accepted; keep the recovery key available before rebooting.
'@
        }
    }
}

$value = if ($Mode -eq 'Enable') { 'on' } else { 'off' }
$bcdedit = Join-Path $script:WinAirPlaySystemDirectory 'bcdedit.exe'

if (-not $PSCmdlet.ShouldProcess(
        'the {current} Windows boot entry',
        "Set TESTSIGNING $value")) {
    return
}

Invoke-WinAirPlayNative `
    -FilePath $bcdedit `
    -ArgumentList @('/set', '{current}', 'testsigning', $value) |
    ForEach-Object { Write-Host $_ }

Write-Warning 'The boot-policy change takes effect after a reboot; this script never reboots automatically.'
if ($Mode -eq 'Enable') {
    Write-Warning 'HVCI still requires every kernel binary to carry a valid test signature.'
}
