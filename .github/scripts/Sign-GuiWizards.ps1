[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedSignedManifestSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{40}$')][string]$ExpectedSignerThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'installer/Common.ps1')
. (Join-Path $repo 'installer/Setup.Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'CiSigning.psm1') -Force

function Get-WinAirPlayGuiFileVersion {
    param([Parameter(Mandatory)][string]$Path)
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart,
        $info.FileBuildPart, $info.FilePrivatePart
}

function Get-WinAirPlayGuiDescription {
    param([Parameter(Mandatory)][string]$Path)
    return [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileDescription
}

function Invoke-WinAirPlayGuiSigning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$BundleDirectory,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$ExpectedSignedManifestSha256,
        [Parameter(Mandatory)][string]$ExpectedSignerThumbprint
    )
    Assert-WinAirPlayCiSigningContext -Version $Version -SourceCommit $SourceCommit
    Assert-WinAirPlaySigningHost
    Assert-WinAirPlayAdministrator
    if ($ExpectedSignedManifestSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        $ExpectedSignerThumbprint -cnotmatch '^[0-9A-F]{40}$') {
        throw 'GUI signing requires the exact signed payload hash and dedicated signer pin.'
    }
    Assert-WinAirPlaySetupNoLinks -Path $OutputDirectory
    $outputParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputDirectory))
    Assert-WinAirPlayTrustedDirectory -Path $outputParent -RequireProtectedDacl
    if (Test-Path -LiteralPath $OutputDirectory) {
        throw 'GUI signing output already exists; no existing files were changed.'
    }
    Assert-WinAirPlayTrustedDirectory -Path $BundleDirectory -RequireProtectedDacl
    Assert-WinAirPlayTrustedDirectory -Path (Join-Path $BundleDirectory 'package') -RequireProtectedDacl
    $payload = Assert-WinAirPlaySetupInputs -BundleDirectory $BundleDirectory `
        -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 `
        -ExpectedSignerThumbprint $ExpectedSignerThumbprint
    if ([string]$payload.SourceCommit -cne $SourceCommit -or
        $payload.SourceTreeDirty -isnot [bool] -or $payload.SourceTreeDirty) {
        throw 'GUI signing payload must match the exact clean tagged source.'
    }
    $versionState = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'version.json') -Raw | ConvertFrom-Json
    if ([string]$versionState.version -cne $Version) { throw 'GUI signing source version differs from the tag.' }
    $coreVersion = ($Version -split '[-+]', 2)[0]
    $fileVersion = "$coreVersion.$($versionState.driver_revision)"
    $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$ExpectedSignerThumbprint" -ErrorAction Stop
    try {
        $eku = @($certificate.Extensions | Where-Object {
            $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
        } | ForEach-Object { $_.EnhancedKeyUsages } | Where-Object Value -CEQ '1.3.6.1.5.5.7.3.3')
        if (-not $certificate.HasPrivateKey -or $certificate.Thumbprint -cne $ExpectedSignerThumbprint -or
            $certificate.FriendlyName -cne 'WinAirPlayAudio driver test signing' -or
            $certificate.Subject -cne $certificate.Issuer -or $eku.Count -ne 1 -or
            $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
            $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) {
            throw 'GUI signing requires the imported dedicated valid test identity and private key.'
        }
    } finally { $certificate.Dispose() }
    New-WinAirPlaySecureDirectory -Path $OutputDirectory
    $toolSnapshot = $null
    $failure = $null
    try {
        # Compiler acquisition runs in the preceding secret-free workflow step.
        # The build binds the inner signed payload and locks its bytes throughout
        # compilation; no certificate trust is imported by the builder.
        $build = Join-Path $RepositoryRoot 'installer/gui/Build-Wizards.ps1'
        $null = & $build -BundleDirectory $BundleDirectory -OutputDirectory $OutputDirectory `
            -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 `
            -ExpectedSignerThumbprint $ExpectedSignerThumbprint -NoBootstrap
        if (-not $?) { throw 'GUI compilation did not complete successfully.' }
        Assert-WinAirPlayTrustedDirectory -Path $OutputDirectory -RequireProtectedDacl
        Assert-WinAirPlayTreeHasNoReparsePoints -Path $OutputDirectory
        $names = @("WinAirPlayAudio-$Version-Setup.exe", "WinAirPlayAudio-$Version-Uninstall.exe")
        $expected = @($names + 'wizard-build.json')
        $entries = @(Get-ChildItem -LiteralPath $OutputDirectory -Force -ErrorAction Stop)
        if ($entries.Count -ne 3 -or @($entries | Where-Object {
            $_.PSIsContainer -or $_.Name -cnotin $expected
        }).Count) { throw 'GUI compilation did not produce the exact two-wizard inventory.' }
        $inventoryPath = Join-Path $OutputDirectory 'wizard-build.json'
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
        if ($inventory.SchemaVersion -ne 1 -or [string]$inventory.Version -cne $Version -or
            $inventory.PreviewOnly -isnot [bool] -or $inventory.PreviewOnly -or
            $null -ne $inventory.PreviewOutcome -or
            [string]$inventory.PayloadManifestSha256 -cne $ExpectedSignedManifestSha256 -or
            [string]$inventory.SignerThumbprint -cne $ExpectedSignerThumbprint -or
            [string]$inventory.CompilerVersion -cne '7.1.1') {
            throw 'GUI compilation metadata is not the authenticated non-preview release build.'
        }
        $declared = @($inventory.Files)
        if ($declared.Count -ne 2 -or @($names | Where-Object { $_ -cnotin @($declared.Name) }).Count) {
            throw 'GUI compilation inventory does not name the exact wizard pair.'
        }
        foreach ($name in $names) {
            $path = Join-Path $OutputDirectory $name
            Assert-WinAirPlayRegularFile -Path $path
            Assert-WinAirPlayPeX64 -Path $path
            $record = @($declared | Where-Object Name -CEQ $name)
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($record.Count -ne 1 -or [int64]$record[0].Bytes -ne (Get-Item -LiteralPath $path).Length -or
                [string]$record[0].Sha256 -cne (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -or
                $record[0].SignatureStatus -cne 'NotSigned' -or
                $signature.Status.ToString() -cne 'NotSigned' -or $signature.SignerCertificate -or
                (Get-WinAirPlayGuiFileVersion -Path $path) -cne $fileVersion -or
                (Get-WinAirPlayGuiDescription -Path $path) -match 'Preview') {
                throw "GUI unsigned preimage/hash/version contract failed: $name"
            }
        }
        $toolSnapshot = New-WinAirPlaySigningToolSnapshot
        foreach ($name in $names) {
            $path = Join-Path $OutputDirectory $name
            Invoke-WinAirPlayAuthenticatedTool -FilePath $toolSnapshot.SignToolPath `
                -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
                -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
                -ArgumentList @('sign', '/v', '/fd', 'SHA256', '/sha1', $ExpectedSignerThumbprint,
                    '/s', 'My', '/sm', $path) | ForEach-Object { Write-Host $_ }
            Invoke-WinAirPlayAuthenticatedTool -FilePath $toolSnapshot.SignToolPath `
                -WorkingDirectory $toolSnapshot.SignToolWorkingDirectory `
                -TemporaryDirectory $toolSnapshot.TemporaryDirectory `
                -ArgumentList @('verify', '/v', '/pa', $path) | ForEach-Object { Write-Host $_ }
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            Assert-WinAirPlayPeX64 -Path $path
            if ($signature.Status.ToString() -cne 'Valid' -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Thumbprint -cne $ExpectedSignerThumbprint -or
                (Get-WinAirPlayGuiFileVersion -Path $path) -cne $fileVersion) {
                throw "GUI signature or version postcondition failed: $name"
            }
        }
        $finalFiles = foreach ($name in $names) {
            $path = Join-Path $OutputDirectory $name
            [pscustomobject]@{
                Name = $name
                Bytes = (Get-Item -LiteralPath $path).Length
                Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                SignatureStatus = 'Valid'
                SignerThumbprint = $ExpectedSignerThumbprint
            }
        }
        $inventory.GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        $inventory.Files = @($finalFiles)
        $inventory | Add-Member -NotePropertyName SourceCommit -NotePropertyValue $SourceCommit -Force
        $inventory | Add-Member -NotePropertyName SigningState -NotePropertyValue 'test-signed' -Force
        $inventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $inventoryPath -Encoding utf8
    } catch { $failure = $_ }
    finally {
        if ($toolSnapshot) {
            try { Remove-WinAirPlaySigningToolSnapshot -SnapshotDirectory $toolSnapshot.SnapshotDirectory }
            catch {
                $prefix = if ($failure) { $failure.Exception.Message + ' ' } else { '' }
                throw "${prefix}GUI signing-tool cleanup failed: $($_.Exception.Message)"
            }
        }
    }
    if ($failure) { throw $failure }
    return [pscustomobject]@{
        Directory = $OutputDirectory
        ManifestSha256 = (Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'wizard-build.json') -Algorithm SHA256).Hash
    }
}

Invoke-WinAirPlayGuiSigning -RepositoryRoot $repo -BundleDirectory $BundleDirectory `
    -OutputDirectory $OutputDirectory -Version $Version -SourceCommit $SourceCommit `
    -ExpectedSignedManifestSha256 $ExpectedSignedManifestSha256 `
    -ExpectedSignerThumbprint $ExpectedSignerThumbprint
