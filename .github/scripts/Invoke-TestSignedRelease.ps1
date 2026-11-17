[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$ChecksumPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{40}$')][string]$ExpectedSignerThumbprint,
    [switch]$ProbeCleanupAfterImport
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'CiSigning.psm1') -Force
Assert-WinAirPlayCiSigningContext -Version $Version -SourceCommit $SourceCommit
. (Join-Path $repo 'installer/Common.ps1')
Import-Module (Join-Path $repo 'scripts/ReleaseLayout.psm1') -Force
Assert-WinAirPlaySigningHost
Assert-WinAirPlayAdministrator

$pin = $ExpectedSignerThumbprint
$cleanupErrors = [Collections.Generic.List[string]]::new()
$ownedCertificates = [Collections.Generic.List[string]]::new()
$bytes=$null; $password=$null; $certificate=$null; $publicCertificate=$null
$mutex=$null; $signed=$null; $gui=$null; $bundle=$null; $failure=$null
$imported = @()
$stateOwned=$false; $secretOwned=$false; $diagnosticOwned=$false
$id = [Guid]::NewGuid().ToString('N')
$localRoot = Join-Path $repo '.local'
$secretRoot = Join-Path $localRoot 'secrets'
$diagnosticRoot = Join-Path $localRoot 'diagnostics'
$secretScratch = Join-Path $secretRoot "ci-sign-$id"
$diagnosticScratch = Join-Path $diagnosticRoot "ci-sign-$id"
$stateRoots = @($script:WinAirPlayInstallerStagingRoot, $script:WinAirPlaySigningToolRoot,
    $script:WinAirPlaySignedPackageRoot)
function Invoke-Cleanup([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { $cleanupErrors.Add($_.Exception.Message) }
}
try {
    if ([string]::IsNullOrEmpty($env:WINAIRPLAY_TEST_PFX_BASE64) -or
        [string]::IsNullOrEmpty($env:WINAIRPLAY_TEST_PFX_PASSWORD) -or
        $env:WINAIRPLAY_TEST_PFX_BASE64.Length -gt 1MB) { throw 'Missing or oversized signing inputs; see docs/releasing.md.' }
    $bytes = [Convert]::FromBase64String($env:WINAIRPLAY_TEST_PFX_BASE64)
    $password = ConvertTo-SecureString $env:WINAIRPLAY_TEST_PFX_PASSWORD -AsPlainText -Force
    Remove-Item Env:WINAIRPLAY_TEST_PFX_BASE64, Env:WINAIRPLAY_TEST_PFX_PASSWORD
    $certificate = Get-WinAirPlayCiSigningCertificate -Bytes $bytes -Password $password -ExpectedThumbprint $pin
    $mutex = Enter-WinAirPlayInstallerMutex
    foreach ($root in $stateRoots) {
        if (Test-Path -LiteralPath $root) { throw 'Preexisting signing state prevents exclusive CI ownership.' }
    }
    foreach ($store in @('My', 'Root', 'TrustedPublisher')) {
        if (Test-Path -LiteralPath "Cert:\LocalMachine\$store\$pin") { throw 'Signer already exists on this runner.' }
    }
    $stateOwned = $true
    foreach ($directory in @($localRoot, $diagnosticRoot)) {
        if (-not (Test-Path -LiteralPath $directory)) { [void][IO.Directory]::CreateDirectory($directory) }
        $item = Get-Item -LiteralPath $directory -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Local scratch ancestor is unsafe.'
        }
    }
    if (-not (Test-Path -LiteralPath $secretRoot)) { New-WinAirPlaySecureDirectory -Path $secretRoot }
    Assert-WinAirPlayTrustedDirectory -Path $secretRoot -RequireProtectedDacl
    $secretOwned = $true
    New-WinAirPlaySecureDirectory -Path $secretScratch
    $diagnosticOwned = $true
    New-WinAirPlaySecureDirectory -Path $diagnosticScratch
    $destination = Join-Path $diagnosticScratch 'input'
    $null = Expand-WinAirPlayReleaseArchive -ArchivePath $ArchivePath -ChecksumPath $ChecksumPath `
        -Destination $destination -Version $Version -SourceCommit $SourceCommit -SigningState unsigned
    $package = Join-Path $destination 'package'
    $unsignedHash = (Get-FileHash -LiteralPath (Join-Path $package 'package-manifest.json') -Algorithm SHA256).Hash
    $pfxPath = Join-Path $secretScratch 'signer.pfx'
    [IO.File]::WriteAllBytes($pfxPath, $bytes)
    # Mark store ownership before writes to cover partially successful imports.
    $ownedCertificates.Add("Cert:\LocalMachine\My\$pin")
    $imported = @(Import-PfxCertificate -FilePath $pfxPath -Password $password -CertStoreLocation 'Cert:\LocalMachine\My')
    if ($imported.Count -ne 1 -or $imported[0].Thumbprint -cne $pin -or -not $imported[0].HasPrivateKey) {
        throw 'Persistent signing import did not match its preflight certificate.'
    }
    $imported[0].FriendlyName = 'WinAirPlayAudio driver test signing'
    $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate.RawData)
    $publicCertificate.FriendlyName = 'WinAirPlayAudio driver test signing'
    foreach ($storeName in @('Root', 'TrustedPublisher')) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $ownedCertificates.Add("Cert:\LocalMachine\$storeName\$pin")
            $store.Add($publicCertificate)
        } finally { $store.Close() }
    }
    $publicPath = Join-Path $diagnosticScratch 'test-signing.cer'
    [IO.File]::WriteAllBytes($publicPath, $publicCertificate.RawData)
    if ($ProbeCleanupAfterImport) {
        throw 'CI cleanup probe: deliberate failure after certificate import.'
    }
    $signed = & (Join-Path $repo 'installer/Sign-TestPackage.ps1') -PackageDirectory $package `
        -CertificateThumbprint $pin -ExpectedManifestSha256 $unsignedHash -Confirm:$false
    $guiInput = Join-Path $diagnosticScratch 'gui-input'
    New-WinAirPlaySecureDirectory -Path $guiInput
    $guiPackage = Join-Path $guiInput 'package'
    New-WinAirPlaySecureDirectory -Path $guiPackage
    foreach ($name in @(Get-WinAirPlayPackageFileNames)) {
        Copy-Item -LiteralPath (Join-Path $signed.PackageDirectory $name) -Destination (Join-Path $guiPackage $name) -ErrorAction Stop
    }
    Copy-Item -LiteralPath $publicPath -Destination (Join-Path $guiInput 'test-signing.cer') -ErrorAction Stop
    $gui = & (Join-Path $repo '.github/scripts/Sign-GuiWizards.ps1') -BundleDirectory $guiInput `
        -OutputDirectory (Join-Path $diagnosticScratch 'gui-signed') -Version $Version `
        -SourceCommit $SourceCommit -ExpectedSignedManifestSha256 $signed.SignedManifestSha256 `
        -ExpectedSignerThumbprint $pin
    # The complete signed bundle is authenticated internal input. Only the
    # final two-file installer archive may leave the isolated signing job.
    $internalBundle = & (Join-Path $repo 'scripts/New-ReleaseBundle.ps1') -Configuration Release `
        -OutputDirectory (Join-Path $diagnosticScratch 'internal-bundle') -PackageDirectory $signed.PackageDirectory `
        -SigningState test-signed -ExpectedSignerThumbprint $pin `
        -ExpectedSignedManifestSha256 $signed.SignedManifestSha256 -PublicCertificatePath $publicPath `
        -GuiDirectory $gui.Directory
    $bundle = & (Join-Path $repo 'scripts/New-InstallerRelease.ps1') `
        -ArchivePath $internalBundle.Archive -ChecksumPath $internalBundle.ChecksumFile `
        -OutputDirectory $OutputDirectory -Version $Version -SourceCommit $SourceCommit `
        -ExpectedSignerThumbprint $pin
}
catch { $failure = $_ }
finally {
    Remove-Item Env:WINAIRPLAY_TEST_PFX_BASE64, Env:WINAIRPLAY_TEST_PFX_PASSWORD -ErrorAction SilentlyContinue
    foreach ($item in $imported) { $item.Dispose() }
    if ($certificate) { $certificate.Dispose() }
    if ($publicCertificate) { $publicCertificate.Dispose() }
    if ($password) { $password.Dispose() }
    if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    for ($index = $ownedCertificates.Count - 1; $index -ge 0; $index--) {
        $path = $ownedCertificates[$index]
        Invoke-Cleanup {
            if (Test-Path -LiteralPath $path) {
                if ($path -like 'Cert:\LocalMachine\My\*') { Remove-Item -LiteralPath $path -DeleteKey -Force }
                else { Remove-Item -LiteralPath $path -Force }
            }
            if (Test-Path -LiteralPath $path) { throw 'Runner certificate cleanup was incomplete.' }
        }
    }
    if ($stateOwned) {
        Invoke-Cleanup { Remove-WinAirPlayInstallerSnapshots -RemoveRoot }
        Invoke-Cleanup { Remove-WinAirPlaySigningToolSnapshots -RemoveRoot }
        Invoke-Cleanup {
            if (Test-Path -LiteralPath $script:WinAirPlaySignedPackageRoot) {
                Assert-WinAirPlayTrustedDirectory -Path $script:WinAirPlaySignedPackageRoot -RequireProtectedDacl
                foreach ($item in Get-ChildItem -LiteralPath $script:WinAirPlaySignedPackageRoot -Force) {
                    Remove-WinAirPlayDirectorySafe -Path $item.FullName -AllowedParent $script:WinAirPlaySignedPackageRoot -AllowedLeafPattern '^[0-9a-f]{32}$'
                }
                Remove-WinAirPlayDirectorySafe -Path $script:WinAirPlaySignedPackageRoot -AllowedParent $script:WinAirPlayProgramData -AllowedLeafPattern '^WinAirPlayAudioSignedPackages$'
            }
        }
        Invoke-Cleanup { foreach ($root in $stateRoots) { if (Test-Path -LiteralPath $root) { throw 'Signing state remains after cleanup.' } } }
    }
    if ($secretOwned) { Invoke-Cleanup { Remove-WinAirPlayDirectorySafe -Path $secretScratch -AllowedParent $secretRoot -AllowedLeafPattern '^ci-sign-[0-9a-f]{32}$' } }
    if ($diagnosticOwned) { Invoke-Cleanup { Remove-WinAirPlayDirectorySafe -Path $diagnosticScratch -AllowedParent $diagnosticRoot -AllowedLeafPattern '^ci-sign-[0-9a-f]{32}$' } }
    if ($mutex) { Invoke-Cleanup { Exit-WinAirPlayInstallerMutex -Mutex $mutex } }
}
if ($cleanupErrors.Count) { throw "CI signing cleanup failed: $($cleanupErrors -join '; ')" }
if ($failure) { throw $failure }
if ($null -eq $bundle) { throw 'Signing produced no release bundle.' }
$bundle
