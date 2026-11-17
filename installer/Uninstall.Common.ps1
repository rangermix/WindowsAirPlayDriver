Set-StrictMode -Version Latest

function Select-WinAirPlayUninstallOption {
    param([bool]$Selected, [bool]$Keep, [bool]$NonInteractive, [string]$Description)
    if ($Selected -and $Keep) { throw 'Conflicting uninstall options.' }
    if ($Selected) { return $true }
    if ($Keep -or $NonInteractive) { return $false }
    return (Read-Host "$Description Type YES to select, or press Enter to keep the current setting") -ceq 'YES'
}

function Get-WinAirPlayUninstallCertificatePin {
    param([string]$ExpectedSignerThumbprint)
    if (-not (Test-Path -LiteralPath $script:WinAirPlayStateFile)) {
        if ($ExpectedSignerThumbprint) { return $ExpectedSignerThumbprint.ToUpperInvariant() }
        return $null
    }
    try {
        Assert-WinAirPlayStateTree
        $record = Assert-WinAirPlayInstallStateRecord -Path $script:WinAirPlayStateFile -PassThru
        if ($record.CatalogSignerThumbprint -cne $record.ExecutableSignerThumbprint) {
            throw 'Installed package uses split signer identities; dedicated test-certificate cleanup cannot be inferred.'
        }
        if ($ExpectedSignerThumbprint -and $record.CatalogSignerThumbprint -ine $ExpectedSignerThumbprint) {
            throw 'The supplied release signer differs from the installed signer.'
        }
        return [string]$record.CatalogSignerThumbprint
    } catch {
        Write-Warning "Certificate identity could not be established; product removal can continue, but public trust will be retained: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-WinAirPlayGuidedUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptDirectory,
        [string]$ExpectedSignerThumbprint = '',
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
    Assert-WinAirPlayTarget
    if (($DisableTestSigning -and $KeepTestSigning) -or ($RemoveTestCertificate -and $KeepTestCertificate)) {
        throw 'Choose one of DisableTestSigning/KeepTestSigning and one of RemoveTestCertificate/KeepTestCertificate.'
    }
    if ($ExpectedSignerThumbprint -and $ExpectedSignerThumbprint -cnotmatch '^[0-9A-Fa-f]{40}$') {
        throw 'Expected signer thumbprint must contain exactly 40 hexadecimal characters.'
    }
    if ($Plan) {
        Write-Host 'Plan: verify ownership, remove product and prove it absent, then offer public trust removal and test-mode exit. No privileged inventory or machine changes performed.'
        Get-WinAirPlaySetupBootState | Format-List | Out-Host
        return 0
    }
    Assert-WinAirPlayAdministrator
    if ($NonInteractive -and $DisableTestSigning -and
        (-not $AcknowledgeBootConfigurationChange -or -not $AcknowledgeBitLockerRecoveryRisk -or -not $AcknowledgeOtherTestDrivers)) {
        throw 'Disabling test mode unattended requires explicit boot-change, BitLocker recovery and other-test-driver acknowledgements.'
    }
    Confirm-WinAirPlaySetupAction ([bool]$ConfirmRemoval) ([bool]$NonInteractive) 'Permanently remove WinAirPlayAudio, including its driver, service, devices, firewall rule, configuration, credentials and logs?'
    $names = @('Common.ps1', 'Remove-TestCertificate.ps1', 'Set-TestSigning.ps1')
    $hashes = @{}
    foreach ($name in $names) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $ScriptDirectory $name) -Algorithm SHA256).Hash
    }
    $setupMutex = $null
    $installerMutex = $null
    $locked = $false
    $scratch = $null
    $result = 0
    $primaryFailure = $null
    try {
        # Keep lock order consistent with setup, and hold the installer lock
        # through final policy selection so an installation cannot race removal.
        $setupMutex = [Threading.Mutex]::new($false, 'Global\WinAirPlayAudio.Setup')
        try { $locked = $setupMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another WinAirPlayAudio setup/uninstall is running.' }
        $installerMutex = Enter-WinAirPlayInstallerMutex
        $certificatePin = Get-WinAirPlayUninstallCertificatePin -ExpectedSignerThumbprint $ExpectedSignerThumbprint
        $scratch = New-WinAirPlaySetupScratch
        $scripts = New-WinAirPlaySetupScriptSnapshot -SourceDirectory $ScriptDirectory -Destination (Join-Path $scratch 'installer') -ExpectedHashes $hashes -FileNames $names
        Remove-WinAirPlayInstallation -RemoveToolCaches -ForcePackageRemoval:$ForcePackageRemoval
        Assert-WinAirPlayInstallationAbsent -RequireToolCachesAbsent
        Write-Host 'WinAirPlayAudio driver packages, devices, service, scoped firewall rule, files, configuration, credentials, logs and installer/tool caches are verified removed.' -ForegroundColor Green
        if ($certificatePin) {
            $removeTrust = Select-WinAirPlayUninstallOption ([bool]$RemoveTestCertificate) ([bool]$KeepTestCertificate) ([bool]$NonInteractive) "Remove dedicated public test-certificate trust for ${certificatePin}? Private signing keys will be retained."
            if ($removeTrust) {
                & (Join-Path $scripts 'Remove-TestCertificate.ps1') -CertificateThumbprint $certificatePin -ConfirmRemoval -Confirm:$false
                if (-not $?) { throw 'Public certificate trust removal failed; test mode has not been changed.' }
            }
        } elseif ($RemoveTestCertificate) {
            throw 'Product removal succeeded, but no verified matching certificate identity is available. Trust and test mode remain unchanged. Rerun with the trusted signer pin or use -KeepTestCertificate.'
        } else {
            Write-Host 'No verified certificate identity available; public certificate trust retained.'
        }
        $disable = Select-WinAirPlayUninstallOption ([bool]$DisableTestSigning) ([bool]$KeepTestSigning) ([bool]$NonInteractive) 'Exit Windows test mode after this removal?'
        if ($disable) {
            Confirm-WinAirPlaySetupAction ([bool]$AcknowledgeOtherTestDrivers) ([bool]$NonInteractive) 'Confirm no other installed test-signed driver needs Windows test mode?'
            Confirm-WinAirPlaySetupAction ([bool]$AcknowledgeBootConfigurationChange) ([bool]$NonInteractive) 'Acknowledge changing the current Windows boot entry to disable TESTSIGNING?'
            Confirm-WinAirPlaySetupAction ([bool]$AcknowledgeBitLockerRecoveryRisk) ([bool]$NonInteractive) 'Confirm you have recovery access and your BitLocker recovery key before changing boot policy?'
            # Always request off, including when the current boot is already
            # normal: a pending BCD change could otherwise enable it next boot.
            & (Join-Path $scripts 'Set-TestSigning.ps1') -Mode Disable -AcknowledgeBootConfigurationChange -AcknowledgeBitLockerRecoveryRisk -Confirm:$false
            if (-not $?) { throw 'Product removal succeeded, but TESTSIGNING could not be disabled.' }
            Write-Warning 'TESTSIGNING is configured off for the next boot. Restart Windows manually to exit test mode; this uninstaller never reboots automatically.'
            $result = 3010
        } else { Write-Host 'Windows test-signing boot policy was retained.' }
    } catch {
        $primaryFailure = $_
    } finally {
        $cleanup = [Collections.Generic.List[string]]::new()
        try { if ($scratch) { Remove-WinAirPlaySetupScratch $scratch } }
        catch { $cleanup.Add("Scratch: $($_.Exception.Message)") }
        try { if ($installerMutex) { Exit-WinAirPlayInstallerMutex $installerMutex } }
        catch { $cleanup.Add("Installer lock: $($_.Exception.Message)") }
        if ($setupMutex) {
            try { if ($locked) { $setupMutex.ReleaseMutex() } }
            catch { $cleanup.Add("Setup lock: $($_.Exception.Message)") }
            finally { $setupMutex.Dispose() }
        }
        if ($cleanup.Count) {
            $detail = if ($primaryFailure) { $primaryFailure.Exception.Message + ' ' } else { '' }
            throw "${detail}Uninstall cleanup failed: $($cleanup -join '; ')"
        }
    }
    if ($primaryFailure) { throw $primaryFailure }
    return $result
}
