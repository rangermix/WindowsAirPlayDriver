[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ExpectedSignedManifestSha256,
    [Parameter(Mandatory)][string]$ExpectedSignerThumbprint,
    [switch]$EnableTestSigning,
    [switch]$AcknowledgeBootConfigurationChange,
    [switch]$AcknowledgeBitLockerRecoveryRisk,
    [switch]$TrustTestCertificate,
    [switch]$AcceptCleanReinstall,
    [switch]$NonInteractive,
    [switch]$Plan
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup.Common.ps1')
. (Join-Path $PSScriptRoot 'Setup-Dependencies.ps1')
. (Join-Path $PSScriptRoot 'Common.ps1')
$code = 1
$scratch = $null
$mutex = $null
$locked = $false
$scriptHashes = @{}
foreach ($name in @('Common.ps1', 'Install-Driver.ps1', 'Set-TestSigning.ps1')) {
    $scriptHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash
}
try {
    Assert-WinAirPlayTarget
    $bundle = Split-Path $PSScriptRoot -Parent
    $null = Assert-WinAirPlaySetupInputs $bundle $ExpectedSignedManifestSha256 $ExpectedSignerThumbprint
    $null = Resolve-WinAirPlayPackage -PackageDirectory (Join-Path $bundle 'package')
    $boot = Get-WinAirPlaySetupBootState
    if ($Plan -or $WhatIfPreference) {
        Get-WinAirPlaySetupDependencyStatus | Format-List | Out-Host
        $boot | Format-List | Out-Host
        Write-Host 'Verified input. Setup will require explicit boot/trust/reinstall acknowledgements and elevation. No machine state changed.'
        $code = 0
    } else {
        Assert-WinAirPlayAdministrator
        $status = Get-WinAirPlaySetupDependencyStatus
        if (-not $status.PowerShellInstalled -or -not $status.VcRuntimeInstalled) {
            throw 'Run Setup.cmd to provision missing runtime dependencies first.'
        }
        $mutex = [Threading.Mutex]::new($false, 'Global\WinAirPlayAudio.Setup')
        try { $locked = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another WinAirPlayAudio setup is running.' }
        $scratch = New-WinAirPlaySetupScratch
        $protectedScripts = New-WinAirPlaySetupScriptSnapshot -SourceDirectory $PSScriptRoot -Destination (Join-Path $scratch 'installer') -ExpectedHashes $scriptHashes
        if (-not $boot.TestSigningActive) {
            Confirm-WinAirPlaySetupAction ([bool]$EnableTestSigning) ([bool]$NonInteractive) 'Enable Windows test mode for this experimental test-signed driver?'
            Confirm-WinAirPlaySetupAction ([bool]$AcknowledgeBootConfigurationChange) ([bool]$NonInteractive) 'Acknowledge changing the current Windows boot entry to allow test-signed drivers?'
            Confirm-WinAirPlaySetupAction ([bool]$AcknowledgeBitLockerRecoveryRisk) ([bool]$NonInteractive) 'Confirm you have recovery access and your BitLocker recovery key before changing boot policy?'
            & (Join-Path $protectedScripts 'Set-TestSigning.ps1') -Mode Enable -AcknowledgeBootConfigurationChange -AcknowledgeBitLockerRecoveryRisk -Confirm:$false
            if (-not $?) { throw 'Test-mode configuration failed.' }
            Write-Warning 'TESTSIGNING was requested for the next boot. Restart Windows manually, then rerun the same Setup.cmd command. No certificate was trusted and no driver was installed.'
            $code = 3010
        } else {
            Confirm-WinAirPlaySetupAction ([bool]$TrustTestCertificate) ([bool]$NonInteractive) "Trust public test certificate $ExpectedSignerThumbprint in this machine's Root and TrustedPublisher stores?"
            Confirm-WinAirPlaySetupAction ([bool]$AcceptCleanReinstall) ([bool]$NonInteractive) 'Install WinAirPlayAudio using a clean reinstall, permanently removing any existing product configuration, credentials and logs?'
            # Authenticated payloads and public DER are rechecked after copying into
            # an admin-only directory, before importing trust or invoking install.
            $packageDirectory = Join-Path $scratch 'package'
            New-WinAirPlaySecureDirectory -Path $packageDirectory
            foreach ($name in @(Get-WinAirPlayPackageFileNames)) {
                Copy-Item -LiteralPath (Join-Path $bundle "package\$name") -Destination (Join-Path $packageDirectory $name) -ErrorAction Stop
            }
            Copy-Item -LiteralPath (Join-Path $bundle 'test-signing.cer') -Destination (Join-Path $scratch 'test-signing.cer') -ErrorAction Stop
            $null = Assert-WinAirPlaySetupInputs $scratch $ExpectedSignedManifestSha256 $ExpectedSignerThumbprint
            $package = Resolve-WinAirPlayPackage -PackageDirectory $packageDirectory
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes((Join-Path $scratch 'test-signing.cer')))
            $addedStores = [Collections.Generic.List[string]]::new()
            $installSucceeded = $false
            $trustFailure = $null
            try {
                Add-WinAirPlaySetupCertificateTrust -Certificate $certificate -AddedStores $addedStores
                Assert-WinAirPlayPackageSignature -Package $package -ExpectedCatalogSignerThumbprint $ExpectedSignerThumbprint -ExpectedExecutableSignerThumbprint $ExpectedSignerThumbprint
                # Recheck the live kernel immediately before installation, too.
                if (-not (Get-WinAirPlaySetupBootState).TestSigningActive) { throw 'Current-boot TESTSIGNING is not active.' }
                & (Join-Path $protectedScripts 'Install-Driver.ps1') -PackageDirectory $packageDirectory -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 -ExpectedSignerThumbprint $ExpectedSignerThumbprint -Confirm:$false
                if (-not $?) { throw 'Driver installation failed.' }
                $installSucceeded = $true
                Write-Host 'Setup completed: driver package, running service and scoped firewall rule verified.' -ForegroundColor Green
                Write-Host 'Receiver discovery and physical audio playback still require a compatible receiver and separate validation.'
                $code = 0
            } catch {
                $trustFailure = $_
                throw
            } finally {
                try {
                    if (-not $installSucceeded) {
                        Remove-WinAirPlaySetupCertificateTrust -Certificate $certificate -StoreNames @($addedStores)
                    }
                } catch {
                    if ($trustFailure) {
                        throw [InvalidOperationException]::new(
                            "Setup failed: $($trustFailure.Exception.Message) Certificate cleanup also failed: $($_.Exception.Message)",
                            $trustFailure.Exception)
                    }
                    throw
                } finally { $certificate.Dispose() }
            }
        }
    }
} catch {
    [Console]::Error.WriteLine("WinAirPlayAudio installation failed: $($_.Exception.Message)")
    $code = 1
} finally {
    try { if ($scratch) { Remove-WinAirPlaySetupScratch $scratch } }
    catch { [Console]::Error.WriteLine("Setup scratch cleanup failed: $($_.Exception.Message)"); $code = 1 }
    if ($mutex) {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
exit $code
